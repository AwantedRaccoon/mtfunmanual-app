import Foundation
import SwiftData
import UniformTypeIdentifiers

struct PreparedAttachmentMetadata: Equatable, Sendable {
    let operationID: UUID
    let attachmentID: UUID
    let relativePath: String
    let originalFilename: String
    let typeIdentifier: String
    let byteCount: Int64
    let sha256Hex: String

    init(
        operationID: UUID,
        attachmentID: UUID,
        relativePath: String,
        originalFilename: String,
        typeIdentifier: String,
        byteCount: Int64,
        sha256Hex: String
    ) {
        self.operationID = operationID
        self.attachmentID = attachmentID
        self.relativePath = relativePath
        self.originalFilename = originalFilename
        self.typeIdentifier = typeIdentifier
        self.byteCount = byteCount
        self.sha256Hex = sha256Hex
    }

    init(_ staged: AttachmentStagedFile) {
        self.init(
            operationID: staged.operationID,
            attachmentID: staged.attachmentID,
            relativePath: staged.relativePath,
            originalFilename: staged.originalFilename,
            typeIdentifier: staged.typeIdentifier,
            byteCount: staged.byteCount,
            sha256Hex: staged.sha256Hex
        )
    }
}

struct AddAttachmentMetadataCommand: Sendable {
    let operationID: UUID
    let attachmentID: UUID
    let ownerType: AttachmentOwnerType
    let ownerID: UUID
    let relativePath: String
    let originalFilename: String
    let typeIdentifier: String
    let byteCount: Int64
    let sha256Hex: String
    let committedAt: Date

    init(
        operationID: UUID,
        attachmentID: UUID = UUID(),
        ownerType: AttachmentOwnerType,
        ownerID: UUID,
        relativePath: String,
        originalFilename: String,
        typeIdentifier: String,
        byteCount: Int64,
        sha256Hex: String,
        committedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.attachmentID = attachmentID
        self.ownerType = ownerType
        self.ownerID = ownerID
        self.relativePath = relativePath
        self.originalFilename = originalFilename
        self.typeIdentifier = typeIdentifier
        self.byteCount = byteCount
        self.sha256Hex = sha256Hex
        self.committedAt = committedAt
    }
}

struct AttachmentCommitResult: Equatable, Sendable {
    let attachmentID: UUID
    let didCreate: Bool
}

struct DeleteAttachmentCommand: Sendable {
    let operationID: UUID
    let attachmentID: UUID
    let committedAt: Date

    init(
        operationID: UUID,
        attachmentID: UUID,
        committedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.attachmentID = attachmentID
        self.committedAt = committedAt
    }
}

struct AttachmentDeletionResult: Equatable, Sendable {
    let attachment: AttachmentSnapshot
    let didDelete: Bool
}

struct AttachmentSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let ownerType: AttachmentOwnerType
    let ownerID: UUID
    let relativePath: String
    let originalFilename: String
    let typeIdentifier: String
    let byteCount: Int64
    let sha256Hex: String
    let createdAt: Date
}

extension AppWriteActor {
    func addAttachmentMetadata(
        _ command: AddAttachmentMetadataCommand
    ) throws -> AttachmentCommitResult {
        let normalized = try normalizedAttachment(command)
        let digest = try AttachmentDigestV1.command(command)
        if let replay = try attachmentReplay(command.operationID, digest: digest) {
            return replay
        }
        try validateAttachmentInsertion(normalized, command: command)
        modelContext.autosaveEnabled = false
        let reservation = try reserveRevision(committedAt: command.committedAt)
        do {
            var result: AttachmentCommitResult?
            try modelContext.transaction {
                if let replay = try attachmentReplay(command.operationID, digest: digest) {
                    result = replay
                    return
                }
                try validateAttachmentInsertion(normalized, command: command)
                let attachment = AttachmentRecord(
                    id: command.attachmentID,
                    ownerType: command.ownerType,
                    ownerID: command.ownerID,
                    relativePath: normalized.relativePath,
                    originalFilename: normalized.filename,
                    typeIdentifier: normalized.typeIdentifier,
                    byteCount: command.byteCount,
                    sha256Hex: normalized.sha256Hex,
                    operationID: command.operationID,
                    createdAt: command.committedAt
                )
                modelContext.insert(attachment)
                try upsertRevision(
                    recordType: "AttachmentRecord",
                    recordID: attachment.id,
                    fields: try AttachmentDigestV1.record(attachment),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try insertOperationReceipt(
                    OperationReceiptRecord(
                        operationID: command.operationID,
                        commandDigest: digest,
                        resultRecordType: "AttachmentRecord",
                        resultRecordID: attachment.id,
                        committedAt: command.committedAt
                    ),
                    reservation: reservation
                )
                try markCommitted(at: command.committedAt)
                result = AttachmentCommitResult(
                    attachmentID: attachment.id,
                    didCreate: true
                )
            }
            guard let result else { throw PersonalTimelineWriteFailure.invalidInput }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func deleteAttachment(
        _ command: DeleteAttachmentCommand
    ) throws -> AttachmentDeletionResult {
        guard command.committedAt.timeIntervalSince1970.isFinite else {
            throw PersonalTimelineWriteFailure.invalidInput
        }
        let digest = try AttachmentDigestV1.deleteCommand(command)
        if let replay = try attachmentDeletionReplay(
            operationID: command.operationID,
            digest: digest
        ) {
            return replay
        }
        let id = command.attachmentID
        var descriptor = FetchDescriptor<AttachmentRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first,
              record.deletedAt == nil,
              let snapshot = AttachmentSnapshot(record) else {
            throw PersonalTimelineWriteFailure.staleRecord
        }
        try validateAttachmentDeletion(record)
        modelContext.autosaveEnabled = false
        let reservation = try reserveRevision(committedAt: command.committedAt)
        do {
            var result: AttachmentDeletionResult?
            try modelContext.transaction {
                if let replay = try attachmentDeletionReplay(
                    operationID: command.operationID,
                    digest: digest
                ) {
                    result = replay
                    return
                }
                guard record.deletedAt == nil else {
                    throw PersonalTimelineWriteFailure.staleRecord
                }
                try validateAttachmentDeletion(record)
                record.deletedAt = command.committedAt
                record.deleteOperationID = command.operationID
                try upsertRevision(
                    recordType: "AttachmentRecord",
                    recordID: record.id,
                    fields: try AttachmentDigestV1.record(record),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try insertOperationReceipt(
                    OperationReceiptRecord(
                        operationID: command.operationID,
                        commandDigest: digest,
                        resultRecordType: "AttachmentRecord",
                        resultRecordID: record.id,
                        committedAt: command.committedAt
                    ),
                    reservation: reservation
                )
                try markCommitted(at: command.committedAt)
                result = AttachmentDeletionResult(
                    attachment: snapshot,
                    didDelete: true
                )
            }
            guard let result else { throw PersonalTimelineWriteFailure.invalidInput }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private struct NormalizedAttachment {
        let relativePath: String
        let filename: String
        let typeIdentifier: String
        let sha256Hex: String
    }

    private func normalizedAttachment(
        _ command: AddAttachmentMetadataCommand
    ) throws -> NormalizedAttachment {
        let normalized = try AttachmentMetadataFacts.normalize(
            PreparedAttachmentMetadata(
                operationID: command.operationID,
                attachmentID: command.attachmentID,
                relativePath: command.relativePath,
                originalFilename: command.originalFilename,
                typeIdentifier: command.typeIdentifier,
                byteCount: command.byteCount,
                sha256Hex: command.sha256Hex
            )
        )
        guard command.committedAt.timeIntervalSince1970.isFinite else {
            throw PersonalTimelineWriteFailure.invalidInput
        }
        return NormalizedAttachment(
            relativePath: normalized.relativePath,
            filename: normalized.filename,
            typeIdentifier: normalized.typeIdentifier,
            sha256Hex: normalized.sha256Hex
        )
    }

    private func validateAttachmentInsertion(
        _ normalized: NormalizedAttachment,
        command: AddAttachmentMetadataCommand
    ) throws {
        let id = normalized.relativePath
        var pathDescriptor = FetchDescriptor<AttachmentRecord>(
            predicate: #Predicate { $0.relativePath == id }
        )
        pathDescriptor.fetchLimit = 1
        guard try modelContext.fetch(pathDescriptor).isEmpty else {
            throw PersonalTimelineWriteFailure.staleRecord
        }
        try validateAttachmentOwner(command)

        let ownerType = command.ownerType.rawValue
        let ownerID = command.ownerID
        var activeDescriptor = FetchDescriptor<AttachmentRecord>(
            predicate: #Predicate {
                $0.ownerTypeRawValue == ownerType
                    && $0.ownerID == ownerID
                    && $0.deletedAt == nil
            }
        )
        activeDescriptor.fetchLimit =
            AttachmentFileStore.maximumOwnerFiles + 1
        let active = try modelContext.fetch(activeDescriptor)
        guard active.count <= AttachmentFileStore.maximumOwnerFiles else {
            throw AppDataFailure.corruptionSuspected
        }
        var total: Int64 = 0
        for record in active {
            guard let snapshot = AttachmentSnapshot(record),
                  snapshot.ownerType == command.ownerType,
                  snapshot.ownerID == command.ownerID,
                  snapshot.createdAt.timeIntervalSince1970.isFinite,
                  (try? AttachmentMetadataFacts.normalize(
                      PreparedAttachmentMetadata(
                          operationID: record.operationID,
                          attachmentID: record.id,
                          relativePath: record.relativePath,
                          originalFilename: record.originalFilename,
                          typeIdentifier: record.typeIdentifier,
                          byteCount: record.byteCount,
                          sha256Hex: record.sha256Hex
                      )
                  )) != nil else {
                throw AppDataFailure.corruptionSuspected
            }
            let addition = total.addingReportingOverflow(snapshot.byteCount)
            guard !addition.overflow,
                  addition.partialValue
                    <= AttachmentFileStore.maximumOwnerBytes else {
                throw AppDataFailure.corruptionSuspected
            }
            total = addition.partialValue
        }
        guard active.count < AttachmentFileStore.maximumOwnerFiles,
              total <= AttachmentFileStore.maximumOwnerBytes - command.byteCount else {
            throw PersonalTimelineWriteFailure.attachmentLimitReached
        }
    }

    private func validateAttachmentOwner(
        _ command: AddAttachmentMetadataCommand
    ) throws {
        let ownerID = command.ownerID
        let exists: Bool
        switch command.ownerType {
        case .labSample:
            var descriptor = FetchDescriptor<LabSampleRecord>(
                predicate: #Predicate { $0.id == ownerID }
            )
            descriptor.fetchLimit = 1
            exists = try !modelContext.fetch(descriptor).isEmpty
        case .statusObservation:
            var descriptor = FetchDescriptor<StatusObservationRecord>(
                predicate: #Predicate { $0.id == ownerID }
            )
            descriptor.fetchLimit = 1
            exists = try !modelContext.fetch(descriptor).isEmpty
        case .journeyEntry:
            var descriptor = FetchDescriptor<JourneyEntry>(
                predicate: #Predicate { $0.id == ownerID }
            )
            descriptor.fetchLimit = 1
            exists = try !modelContext.fetch(descriptor).isEmpty
        }
        guard exists else { throw PersonalTimelineWriteFailure.invalidInput }
    }

    private func validateAttachmentDeletion(
        _ attachment: AttachmentRecord
    ) throws {
        guard attachment.ownerType == .labSample else { return }
        let sampleID = attachment.ownerID
        let resultCount = try modelContext.fetchCount(
            FetchDescriptor<LabResultRecord>(
                predicate: #Predicate { $0.sampleID == sampleID }
            )
        )
        guard resultCount == 0 else { return }
        let ownerType = AttachmentOwnerType.labSample.rawValue
        let activeAttachmentCount = try modelContext.fetchCount(
            FetchDescriptor<AttachmentRecord>(
                predicate: #Predicate {
                    $0.ownerTypeRawValue == ownerType
                        && $0.ownerID == sampleID
                        && $0.deletedAt == nil
                }
            )
        )
        guard activeAttachmentCount > 1 else {
            throw PersonalTimelineWriteFailure.lastAttachmentRequired
        }
    }

    private func attachmentReplay(
        _ operationID: UUID,
        digest: String
    ) throws -> AttachmentCommitResult? {
        var receiptDescriptor = FetchDescriptor<OperationReceiptRecord>(
            predicate: #Predicate { $0.operationID == operationID }
        )
        receiptDescriptor.fetchLimit = 1
        guard let receipt = try modelContext.fetch(receiptDescriptor).first else { return nil }
        let id = receipt.resultRecordID
        var recordDescriptor = FetchDescriptor<AttachmentRecord>(
            predicate: #Predicate { $0.id == id }
        )
        recordDescriptor.fetchLimit = 1
        guard receipt.commandDigest == digest,
              receipt.resultRecordType == "AttachmentRecord",
              try modelContext.fetch(recordDescriptor).first?.operationID == operationID else {
            throw PersonalTimelineWriteFailure.operationConflict
        }
        return AttachmentCommitResult(attachmentID: id, didCreate: false)
    }

    private func attachmentDeletionReplay(
        operationID: UUID,
        digest: String
    ) throws -> AttachmentDeletionResult? {
        var receiptDescriptor = FetchDescriptor<OperationReceiptRecord>(
            predicate: #Predicate { $0.operationID == operationID }
        )
        receiptDescriptor.fetchLimit = 1
        guard let receipt = try modelContext.fetch(receiptDescriptor).first else { return nil }
        let id = receipt.resultRecordID
        var recordDescriptor = FetchDescriptor<AttachmentRecord>(
            predicate: #Predicate { $0.id == id }
        )
        recordDescriptor.fetchLimit = 1
        guard receipt.commandDigest == digest,
              receipt.resultRecordType == "AttachmentRecord",
              let record = try modelContext.fetch(recordDescriptor).first,
              record.deleteOperationID == operationID,
              record.deletedAt != nil,
              let snapshot = AttachmentSnapshot(record) else {
            throw PersonalTimelineWriteFailure.operationConflict
        }
        return AttachmentDeletionResult(
            attachment: snapshot,
            didDelete: false
        )
    }
}

struct NormalizedPreparedAttachment: Equatable, Sendable {
    let operationID: UUID
    let attachmentID: UUID
    let relativePath: String
    let filename: String
    let typeIdentifier: String
    let byteCount: Int64
    let sha256Hex: String
}

enum AttachmentMetadataFacts {
    static func normalize(
        _ input: PreparedAttachmentMetadata
    ) throws -> NormalizedPreparedAttachment {
        let relativePath = input.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = URL(fileURLWithPath: input.originalFilename).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawType = input.typeIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let hash = input.sha256Hex.lowercased()
        guard let contentType = UTType(rawType),
              contentType.conforms(to: .image)
                || contentType.conforms(to: .pdf),
              input.byteCount > 0,
              input.byteCount <= AttachmentFileStore.maximumFileBytes,
              !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains(".."),
              AttachmentPathFacts.isOpaquePath(
                  relativePath,
                  attachmentID: input.attachmentID,
                  typeIdentifier: contentType.identifier
              ),
              !filename.isEmpty,
              hash.count == 64,
              hash.allSatisfy(\.isHexDigit) else {
            throw PersonalTimelineWriteFailure.invalidInput
        }
        return NormalizedPreparedAttachment(
            operationID: input.operationID,
            attachmentID: input.attachmentID,
            relativePath: relativePath,
            filename: filename,
            typeIdentifier: contentType.identifier,
            byteCount: input.byteCount,
            sha256Hex: hash
        )
    }
}

extension AppReadActor {
    func attachments(
        ownerType: AttachmentOwnerType,
        ownerID: UUID
    ) throws -> [AttachmentSnapshot] {
        let rawType = ownerType.rawValue
        var descriptor = FetchDescriptor<AttachmentRecord>(
            predicate: #Predicate {
                $0.ownerTypeRawValue == rawType
                    && $0.ownerID == ownerID
                    && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
        )
        descriptor.fetchLimit = AttachmentFileStore.maximumOwnerFiles + 1
        let records = try modelContext.fetch(descriptor)
        guard records.count <= AttachmentFileStore.maximumOwnerFiles else {
            throw AppDataFailure.corruptionSuspected
        }
        var totalBytes: Int64 = 0
        var snapshots: [AttachmentSnapshot] = []
        snapshots.reserveCapacity(records.count)
        for record in records {
            guard let snapshot = AttachmentSnapshot(record),
                  snapshot.ownerType == ownerType,
                  snapshot.ownerID == ownerID,
                  snapshot.createdAt.timeIntervalSince1970.isFinite,
                  (try? AttachmentMetadataFacts.normalize(
                      PreparedAttachmentMetadata(
                          operationID: record.operationID,
                          attachmentID: record.id,
                          relativePath: record.relativePath,
                          originalFilename: record.originalFilename,
                          typeIdentifier: record.typeIdentifier,
                          byteCount: record.byteCount,
                          sha256Hex: record.sha256Hex
                      )
                  )) != nil else {
                throw AppDataFailure.corruptionSuspected
            }
            let addition = totalBytes.addingReportingOverflow(
                snapshot.byteCount
            )
            guard !addition.overflow,
                  addition.partialValue <= AttachmentFileStore.maximumOwnerBytes else {
                throw AppDataFailure.corruptionSuspected
            }
            totalBytes = addition.partialValue
            snapshots.append(snapshot)
        }
        return snapshots
    }

}

extension AttachmentSnapshot {
    init?(_ record: AttachmentRecord) {
        guard let ownerType = record.ownerType else { return nil }
        self.init(
            id: record.id,
            ownerType: ownerType,
            ownerID: record.ownerID,
            relativePath: record.relativePath,
            originalFilename: record.originalFilename,
            typeIdentifier: record.typeIdentifier,
            byteCount: record.byteCount,
            sha256Hex: record.sha256Hex,
            createdAt: record.createdAt
        )
    }
}

enum AttachmentDigestV1 {
    static func command(
        _ command: AddAttachmentMetadataCommand
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "AddAttachmentMetadataCommand",
            recordID: command.operationID,
            fields: [
                .init("attachmentID", .uuid(command.attachmentID)),
                .init("byteCount", .integer(command.byteCount)),
                .init("committedAt", try RecordDigestV1.timestampValue(command.committedAt)),
                .init("originalFilename", .string(URL(fileURLWithPath: command.originalFilename).lastPathComponent)),
                .init("ownerID", .uuid(command.ownerID)),
                .init("ownerType", .string(command.ownerType.rawValue)),
                .init("relativePath", .string(command.relativePath.trimmingCharacters(in: .whitespacesAndNewlines))),
                .init("sha256Hex", .string(command.sha256Hex.lowercased())),
                .init("typeIdentifier", .string(command.typeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)))
            ]
        )
    }

    static func deleteCommand(
        _ command: DeleteAttachmentCommand
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "DeleteAttachmentCommand",
            recordID: command.operationID,
            fields: [
                .init("attachmentID", .uuid(command.attachmentID)),
                .init(
                    "committedAt",
                    try RecordDigestV1.timestampValue(command.committedAt)
                )
            ]
        )
    }

    static func record(_ record: AttachmentRecord) throws -> [RecordDigestV1.Field] {
        [
            .init("byteCount", .integer(record.byteCount)),
            .init("createdAt", try RecordDigestV1.timestampValue(record.createdAt)),
            .init(
                "deleteOperationID",
                record.deleteOperationID.map(RecordDigestV1.Value.uuid) ?? .null
            ),
            .init("deletedAt", try record.deletedAt.map(RecordDigestV1.timestampValue) ?? .null),
            .init("operationID", .uuid(record.operationID)),
            .init("originalFilename", .string(record.originalFilename)),
            .init("ownerID", .uuid(record.ownerID)),
            .init("ownerType", .string(record.ownerTypeRawValue)),
            .init("relativePath", .string(record.relativePath)),
            .init("sha256Hex", .string(record.sha256Hex)),
            .init("typeIdentifier", .string(record.typeIdentifier))
        ]
    }
}
