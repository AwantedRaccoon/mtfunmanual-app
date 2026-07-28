import Foundation
import SwiftData

extension AppReadActor {
    func privacyControlSnapshot() throws -> PrivacyControlSnapshot {
        try PrivacyControlRelationshipValidator.snapshot(
            in: modelContext,
            failure: .corruptionSuspected
        )
    }
}

extension AppWriteActor {
    func setAppLock(
        _ command: SetAppLockCommand,
        failureInjection: AppWriteFailureInjection? = nil
    ) throws -> SetAppLockResult {
        guard command.expectedLocalRevision > 0,
              command.expectedDigestHex.count == 64,
              command.expectedDigestHex.allSatisfy({
                  $0.isHexDigit && !$0.isUppercase
              }),
              command.committedAt.timeIntervalSince1970.isFinite else {
            throw PrivacyControlWriteFailure.invalidInput
        }
        try PrivacyControlRelationshipValidator.validate(
            in: modelContext,
            failure: .corruptionSuspected
        )
        let commandDigest = try PrivacyControlDigestV1
            .setAppLockCommand(command)
        if let replay = try privacyReplay(
            operationID: command.operationID,
            commandDigest: commandDigest
        ) {
            return replay
        }

        let current = try requiredPrivacyControl()
        let currentRevision = try requiredPrivacyRevision()
        guard currentRevision.localRevision
                == command.expectedLocalRevision,
              currentRevision.digestHex == command.expectedDigestHex else {
            throw PrivacyControlWriteFailure.staleRecord
        }
        if current.appLockEnabled == command.isEnabled {
            throw PrivacyControlWriteFailure.staleRecord
        }

        modelContext.autosaveEnabled = false
        do {
            var result: SetAppLockResult?
            try modelContext.transaction {
                let checkedRevision = try requiredPrivacyRevision()
                guard checkedRevision.localRevision
                        == command.expectedLocalRevision,
                      checkedRevision.digestHex
                        == command.expectedDigestHex,
                      current.appLockEnabled != command.isEnabled else {
                    throw PrivacyControlWriteFailure.staleRecord
                }
                let reservation = try reserveRevisionInCurrentTransaction(
                    committedAt: command.committedAt
                )
                current.appLockEnabled = command.isEnabled
                current.lastOperationID = command.operationID
                current.updatedAt = command.committedAt
                try upsertRevision(
                    recordType: "PrivacyControlRecord",
                    recordID: PrivacyControlRecord.stableID,
                    fields: try PrivacyControlDigestV1.record(current),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try insertOperationReceipt(
                    OperationReceiptRecord(
                        operationID: command.operationID,
                        commandDigest: commandDigest,
                        resultRecordType: "PrivacyControlRecord",
                        resultRecordID: PrivacyControlRecord.stableID,
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
                result = SetAppLockResult(
                    snapshot: try PrivacyControlRelationshipValidator
                        .snapshot(
                            in: modelContext,
                            failure: .corruptionSuspected
                        ),
                    didApply: true
                )
            }
            guard let result else {
                throw PrivacyControlWriteFailure.corruptionSuspected
            }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func requiredPrivacyControl() throws -> PrivacyControlRecord {
        var descriptor = FetchDescriptor<PrivacyControlRecord>()
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count == 1, let record = records.first else {
            throw PrivacyControlWriteFailure.corruptionSuspected
        }
        return record
    }

    private func requiredPrivacyRevision() throws -> RecordRevision {
        let key = "PrivacyControlRecord:"
            + PrivacyControlRecord.stableID.uuidString.lowercased()
        var descriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate { $0.recordKey == key }
        )
        descriptor.fetchLimit = 2
        let revisions = try modelContext.fetch(descriptor)
        guard revisions.count == 1, let revision = revisions.first else {
            throw PrivacyControlWriteFailure.corruptionSuspected
        }
        return revision
    }

    private func privacyReplay(
        operationID: UUID,
        commandDigest: String
    ) throws -> SetAppLockResult? {
        var descriptor = FetchDescriptor<OperationReceiptRecord>(
            predicate: #Predicate { $0.operationID == operationID }
        )
        descriptor.fetchLimit = 2
        let receipts = try modelContext.fetch(descriptor)
        guard receipts.count <= 1 else {
            throw PrivacyControlWriteFailure.corruptionSuspected
        }
        guard let receipt = receipts.first else { return nil }
        guard receipt.commandDigest == commandDigest,
              receipt.resultRecordType == "PrivacyControlRecord",
              receipt.resultRecordID == PrivacyControlRecord.stableID else {
            throw PrivacyControlWriteFailure.operationConflict
        }
        return SetAppLockResult(
            snapshot: try PrivacyControlRelationshipValidator.snapshot(
                in: modelContext,
                failure: .corruptionSuspected
            ),
            didApply: false
        )
    }
}
