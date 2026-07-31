import Foundation
import SwiftData

extension AppReadActor {
    func contentFavoriteSnapshots()
        throws -> [ContentFavoriteSnapshot] {
        try ContentFavoriteRelationshipValidator.snapshots(
            in: modelContext
        )
    }

    func contentFavoriteSnapshot(
        contentID: String
    ) throws -> ContentFavoriteSnapshot? {
        try ContentFavoriteRelationshipValidator.snapshot(
            contentID: contentID,
            in: modelContext
        )
    }

    func activeContentFavoriteIDs() throws -> Set<String> {
        Set(
            try contentFavoriteSnapshots()
                .filter(\.isFavorite)
                .map(\.contentID)
        )
    }
}

extension AppWriteActor {
    func setContentFavorite(
        _ command: SetContentFavoriteCommand,
        failureInjection: AppWriteFailureInjection? = nil
    ) throws -> SetContentFavoriteResult {
        try validateInput(command)
        try PrivacyControlRelationshipValidator.validate(
            in: modelContext,
            failure: .corruptionSuspected
        )
        try ContentFavoriteRelationshipValidator.validate(
            in: modelContext
        )
        let commandDigest =
            try ContentFavoriteDigestV1.command(command)
        if let replay = try favoriteReplay(
            command: command,
            commandDigest: commandDigest
        ) {
            return replay
        }
        try validateMonotonicCommit(command.committedAt)
        _ = try resolveTarget(command)

        modelContext.autosaveEnabled = false
        do {
            var result: SetContentFavoriteResult?
            try modelContext.transaction {
                try PrivacyControlRelationshipValidator.validate(
                    in: modelContext,
                    failure: .corruptionSuspected
                )
                try ContentFavoriteRelationshipValidator.validate(
                    in: modelContext
                )
                try validateMonotonicCommit(command.committedAt)
                let target = try resolveTarget(command)
                let reservation =
                    try reserveRevisionInCurrentTransaction(
                        committedAt: command.committedAt
                    )
                let record: ContentFavoriteRecord
                if let current = target {
                    current.updatedAt = command.committedAt
                    current.lastOperationID = command.operationID
                    if command.desiredFavorite {
                        current.contentVersion =
                            command.contentVersion
                        current.cardDigest = command.cardDigest
                        current.removedAt = nil
                    } else {
                        current.removedAt = command.committedAt
                    }
                    record = current
                } else {
                    let created = ContentFavoriteRecord(
                        id: command.recordID,
                        contentID: command.contentID,
                        contentVersion: command.contentVersion,
                        cardDigest: command.cardDigest,
                        createdAt: command.committedAt,
                        updatedAt: command.committedAt,
                        removedAt: nil,
                        lastOperationID: command.operationID
                    )
                    modelContext.insert(created)
                    record = created
                }
                try upsertRevision(
                    recordType:
                        ContentFavoriteContract.recordType,
                    recordID: record.id,
                    fields:
                        try ContentFavoriteDigestV1.record(record),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try insertOperationReceipt(
                    OperationReceiptRecord(
                        operationID: command.operationID,
                        commandDigest: commandDigest,
                        resultRecordType:
                            ContentFavoriteContract.recordType,
                        resultRecordID: record.id,
                        committedAt: command.committedAt
                    ),
                    reservation: reservation
                )
                if failureInjection == .beforeRevisionCommit {
                    throw AppWriteFailure.injected
                }
                try markCommitted(at: command.committedAt)
                try PrivacyControlRelationshipValidator.validate(
                    in: modelContext,
                    failure: .corruptionSuspected
                )
                let snapshots =
                    try ContentFavoriteRelationshipValidator
                        .snapshots(in: modelContext)
                guard let snapshot = snapshots.first(
                    where: { $0.id == record.id }
                ) else {
                    throw AppDataFailure.corruptionSuspected
                }
                result = SetContentFavoriteResult(
                    snapshot: snapshot,
                    didApply: true
                )
            }
            guard let result else {
                throw AppDataFailure.corruptionSuspected
            }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func validateInput(
        _ command: SetContentFavoriteCommand
    ) throws {
        guard ContentFavoriteContract.isValidContentID(
                command.contentID
              ),
              ContentFavoriteContract.isValidContentVersion(
                command.contentVersion
              ),
              ContentFavoriteContract.isCanonicalDigest(
                command.cardDigest
              ),
              command.committedAt.timeIntervalSince1970.isFinite,
              (try? RecordDigestV1.timestampMicroseconds(
                  command.committedAt
              )) != nil,
              (command.expectedLocalRevision == nil)
                == (command.expectedDigestHex == nil),
              command.expectedLocalRevision == nil
                || (
                    command.expectedLocalRevision ?? 0
                ) > 0,
              command.expectedDigestHex == nil
                || ContentFavoriteContract.isCanonicalDigest(
                    command.expectedDigestHex ?? ""
                ),
              command.desiredFavorite
                || command.expectedLocalRevision != nil else {
            throw ContentFavoriteWriteFailure.invalidInput
        }
    }

    private func validateMonotonicCommit(
        _ committedAt: Date
    ) throws {
        var descriptor = FetchDescriptor<DatasetMetadata>()
        descriptor.fetchLimit = 2
        let rows = try modelContext.fetch(descriptor)
        guard rows.count == 1, let metadata = rows.first else {
            throw AppDataFailure.corruptionSuspected
        }
        if let lastCommittedAt = metadata.lastCommittedAt,
           committedAt < lastCommittedAt {
            throw ContentFavoriteWriteFailure.invalidInput
        }
    }

    private func resolveTarget(
        _ command: SetContentFavoriteCommand
    ) throws -> ContentFavoriteRecord? {
        let recordID = command.recordID
        let contentID = command.contentID
        var idDescriptor = FetchDescriptor<ContentFavoriteRecord>(
            predicate: #Predicate { $0.id == recordID }
        )
        idDescriptor.fetchLimit = 2
        var contentDescriptor =
            FetchDescriptor<ContentFavoriteRecord>(
                predicate: #Predicate {
                    $0.contentID == contentID
                }
            )
        contentDescriptor.fetchLimit = 2
        let byID = try modelContext.fetch(idDescriptor)
        let byContent = try modelContext.fetch(contentDescriptor)
        guard byID.count <= 1, byContent.count <= 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        let idRecord = byID.first
        let contentRecord = byContent.first
        if let idRecord,
           idRecord.contentID != command.contentID {
            throw ContentFavoriteWriteFailure.operationConflict
        }
        if let contentRecord,
           contentRecord.id != command.recordID {
            throw ContentFavoriteWriteFailure.operationConflict
        }
        let record = idRecord ?? contentRecord

        if command.expectedLocalRevision == nil {
            guard record == nil else {
                throw ContentFavoriteWriteFailure.staleRecord
            }
            guard command.desiredFavorite else {
                throw ContentFavoriteWriteFailure.invalidInput
            }
            return nil
        }
        guard let record else {
            throw ContentFavoriteWriteFailure.staleRecord
        }
        guard let snapshot =
            try ContentFavoriteRelationshipValidator.snapshot(
                contentID: command.contentID,
                in: modelContext
            ),
            snapshot.id == command.recordID,
            snapshot.localRevision
                == command.expectedLocalRevision,
            snapshot.digestHex == command.expectedDigestHex else {
            throw ContentFavoriteWriteFailure.staleRecord
        }
        guard snapshot.isFavorite != command.desiredFavorite else {
            throw ContentFavoriteWriteFailure.staleRecord
        }
        guard command.committedAt >= record.updatedAt else {
            throw ContentFavoriteWriteFailure.invalidInput
        }
        if !command.desiredFavorite {
            guard command.contentVersion
                    == record.contentVersion,
                  command.cardDigest == record.cardDigest else {
                throw ContentFavoriteWriteFailure
                    .operationConflict
            }
        }
        return record
    }

    private func favoriteReplay(
        command: SetContentFavoriteCommand,
        commandDigest: String
    ) throws -> SetContentFavoriteResult? {
        let operationID = command.operationID
        var descriptor =
            FetchDescriptor<OperationReceiptRecord>(
                predicate: #Predicate {
                    $0.operationID == operationID
                }
            )
        descriptor.fetchLimit = 2
        let receipts = try modelContext.fetch(descriptor)
        guard receipts.count <= 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        guard let receipt = receipts.first else { return nil }
        guard receipt.commandDigest == commandDigest,
              receipt.resultRecordType
                == ContentFavoriteContract.recordType,
              receipt.resultRecordID == command.recordID else {
            throw ContentFavoriteWriteFailure.operationConflict
        }
        guard let snapshot =
            try ContentFavoriteRelationshipValidator
                .snapshots(in: modelContext)
                .first(where: {
                    $0.id == receipt.resultRecordID
                }) else {
            throw AppDataFailure.corruptionSuspected
        }
        return SetContentFavoriteResult(
            snapshot: snapshot,
            didApply: false
        )
    }
}
