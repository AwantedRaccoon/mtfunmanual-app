import Foundation
import SwiftData

struct CreateStatusMetricCommand: Sendable {
    let operationID: UUID
    let metricID: UUID
    let displayName: String
    let committedAt: Date

    init(
        operationID: UUID,
        metricID: UUID = UUID(),
        displayName: String,
        committedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.metricID = metricID
        self.displayName = displayName
        self.committedAt = committedAt
    }
}

struct StatusMetricCommitResult: Equatable, Sendable {
    let metricID: UUID
    let didCreate: Bool
}

struct NewStatusMetricInput: Equatable, Sendable {
    let operationID: UUID
    let metricID: UUID
    let displayName: String

    init(
        operationID: UUID,
        metricID: UUID,
        displayName: String
    ) {
        self.operationID = operationID
        self.metricID = metricID
        self.displayName = displayName
    }
}

struct RecordStatusObservationCommand: Sendable {
    let operationID: UUID
    let observationID: UUID
    let metricDefinitionID: UUID
    let newMetric: NewStatusMetricInput?
    let ordinalLevel: Int
    let note: String
    let timestamp: HistoricalTimestamp
    let attachments: [PreparedAttachmentMetadata]
    let committedAt: Date

    init(
        operationID: UUID,
        observationID: UUID = UUID(),
        metricDefinitionID: UUID,
        newMetric: NewStatusMetricInput? = nil,
        ordinalLevel: Int,
        note: String = "",
        timestamp: HistoricalTimestamp,
        attachments: [PreparedAttachmentMetadata] = [],
        committedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.observationID = observationID
        self.metricDefinitionID = metricDefinitionID
        self.newMetric = newMetric
        self.ordinalLevel = ordinalLevel
        self.note = note
        self.timestamp = timestamp
        self.attachments = attachments
        self.committedAt = committedAt
    }
}

struct StatusObservationCommitResult: Equatable, Sendable {
    let observationID: UUID
    let didCreate: Bool
}

struct StatusMetricSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let isArchived: Bool
}

struct ArchiveStatusMetricCommand: Sendable {
    let operationID: UUID
    let metricID: UUID
    let committedAt: Date

    init(
        operationID: UUID,
        metricID: UUID,
        committedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.metricID = metricID
        self.committedAt = committedAt
    }
}

struct StatusMetricArchiveResult: Equatable, Sendable {
    let metricID: UUID
    let didArchive: Bool
}

struct StatusObservationSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let metricDefinitionID: UUID
    let metricNameSnapshot: String
    let ordinalLevel: Int
    let note: String
    let timestamp: HistoricalTimestamp
    let regimenVersionID: UUID?
    let associationState: HistoricalAssociationState

    var levelDisplayText: String {
        "第 \(ordinalLevel) 级，共 4 级"
    }
}

extension AppWriteActor {
    func createStatusMetric(
        _ command: CreateStatusMetricCommand
    ) throws -> StatusMetricCommitResult {
        let cleanName = command.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              command.committedAt.timeIntervalSince1970.isFinite else {
            throw PersonalTimelineWriteFailure.invalidInput
        }
        let digest = try StatusDigestV1.createMetricCommand(command, cleanName: cleanName)
        if let replay = try statusMetricReplay(command.operationID, digest: digest) {
            return replay
        }
        try validateMetricCreation(id: command.metricID)
        modelContext.autosaveEnabled = false
        let reservation = try reserveRevision(committedAt: command.committedAt)
        do {
            var result: StatusMetricCommitResult?
            try modelContext.transaction {
                if let replay = try statusMetricReplay(command.operationID, digest: digest) {
                    result = replay
                    return
                }
                try validateMetricCreation(id: command.metricID)
                let metric = StatusMetricDefinitionRecord(
                    id: command.metricID,
                    displayName: cleanName,
                    operationID: command.operationID,
                    createdAt: command.committedAt
                )
                modelContext.insert(metric)
                try upsertRevision(
                    recordType: "StatusMetricDefinitionRecord",
                    recordID: metric.id,
                    fields: try StatusDigestV1.metric(metric),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try insertOperationReceipt(
                    OperationReceiptRecord(
                        operationID: command.operationID,
                        commandDigest: digest,
                        resultRecordType: "StatusMetricDefinitionRecord",
                        resultRecordID: metric.id,
                        committedAt: command.committedAt
                    ),
                    reservation: reservation
                )
                try markCommitted(at: command.committedAt)
                result = StatusMetricCommitResult(metricID: metric.id, didCreate: true)
            }
            guard let result else { throw PersonalTimelineWriteFailure.invalidInput }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func recordStatusObservation(
        _ command: RecordStatusObservationCommand
    ) throws -> StatusObservationCommitResult {
        let cleanNote = command.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNewMetricName = command.newMetric?.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preparedAttachments = try command.attachments.map(
            AttachmentMetadataFacts.normalize
        )
        guard (1...4).contains(command.ordinalLevel),
              command.committedAt.timeIntervalSince1970.isFinite,
              Set(command.attachments.map(\.attachmentID)).count
                == command.attachments.count,
              Set(command.attachments.map(\.operationID)).count
                == command.attachments.count,
              Set(preparedAttachments.map(\.relativePath)).count
                == preparedAttachments.count,
              preparedAttachments.count <= AttachmentFileStore.maximumOwnerFiles,
              !preparedAttachments.contains(where: {
                  $0.operationID == command.operationID
                      || $0.operationID == command.newMetric?.operationID
              }),
              command.newMetric.map({
                  $0.metricID == command.metricDefinitionID
                      && $0.operationID != command.operationID
                      && cleanNewMetricName?.isEmpty == false
              }) != false else {
            throw PersonalTimelineWriteFailure.invalidInput
        }
        let totalAttachmentBytes = preparedAttachments.reduce(Int64(0)) {
            partial,
            attachment in
            let sum = partial.addingReportingOverflow(attachment.byteCount)
            return sum.overflow ? Int64.max : sum.partialValue
        }
        guard totalAttachmentBytes <= AttachmentFileStore.maximumOwnerBytes else {
            throw PersonalTimelineWriteFailure.attachmentLimitReached
        }
        let digest = try StatusDigestV1.observationCommand(
            command,
            cleanNote: cleanNote,
            cleanNewMetricName: cleanNewMetricName
        )
        if let replay = try statusObservationReplay(command.operationID, digest: digest) {
            return replay
        }
        if let newMetric = command.newMetric {
            try validateMetricCreation(id: newMetric.metricID)
            try validateUnusedOperationID(newMetric.operationID)
        } else {
            _ = try requiredActiveMetric(id: command.metricDefinitionID)
        }
        guard try fetchStatusObservation(id: command.observationID) == nil else {
            throw PersonalTimelineWriteFailure.staleRecord
        }
        try validatePreparedStatusAttachments(preparedAttachments)

        modelContext.autosaveEnabled = false
        let reservation = try reserveRevision(committedAt: command.committedAt)
        do {
            var result: StatusObservationCommitResult?
            try modelContext.transaction {
                if let replay = try statusObservationReplay(command.operationID, digest: digest) {
                    result = replay
                    return
                }
                let transactionalMetric: StatusMetricDefinitionRecord
                if let newMetric = command.newMetric,
                   let cleanNewMetricName {
                    try validateMetricCreation(id: newMetric.metricID)
                    try validateUnusedOperationID(newMetric.operationID)
                    let metric = StatusMetricDefinitionRecord(
                        id: newMetric.metricID,
                        displayName: cleanNewMetricName,
                        operationID: newMetric.operationID,
                        createdAt: command.committedAt
                    )
                    modelContext.insert(metric)
                    try upsertRevision(
                        recordType: "StatusMetricDefinitionRecord",
                        recordID: metric.id,
                        fields: try StatusDigestV1.metric(metric),
                        reservation: reservation,
                        committedAt: command.committedAt
                    )
                    let metricCommand = CreateStatusMetricCommand(
                        operationID: newMetric.operationID,
                        metricID: newMetric.metricID,
                        displayName: newMetric.displayName,
                        committedAt: command.committedAt
                    )
                    try insertOperationReceipt(
                        OperationReceiptRecord(
                            operationID: newMetric.operationID,
                            commandDigest: try StatusDigestV1.createMetricCommand(
                                metricCommand,
                                cleanName: cleanNewMetricName
                            ),
                            resultRecordType: "StatusMetricDefinitionRecord",
                            resultRecordID: metric.id,
                            committedAt: command.committedAt
                        ),
                        reservation: reservation
                    )
                    transactionalMetric = metric
                } else {
                    transactionalMetric = try requiredActiveMetric(
                        id: command.metricDefinitionID
                    )
                }
                guard try fetchStatusObservation(id: command.observationID) == nil else {
                    throw PersonalTimelineWriteFailure.staleRecord
                }
                try validatePreparedStatusAttachments(preparedAttachments)
                let association = try resolvedAssociationForWrite(timestamp: command.timestamp)
                let observation = StatusObservationRecord(
                    id: command.observationID,
                    metricDefinitionID: transactionalMetric.id,
                    metricNameSnapshot: transactionalMetric.displayName,
                    ordinalLevel: command.ordinalLevel,
                    note: cleanNote,
                    operationID: command.operationID,
                    createdAt: command.committedAt
                )
                modelContext.insert(observation)
                try upsertRevision(
                    recordType: "StatusObservationRecord",
                    recordID: observation.id,
                    fields: try StatusDigestV1.observation(observation),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try insertHistoricalTimeForWrite(
                    sourceRecordType: "StatusObservationRecord",
                    sourceRecordID: observation.id,
                    timestamp: command.timestamp,
                    legacyAssociationID: nil,
                    resolvedAssociationID: association.id,
                    associationState: association.state,
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                for input in preparedAttachments {
                    let attachment = AttachmentRecord(
                        id: input.attachmentID,
                        ownerType: .statusObservation,
                        ownerID: observation.id,
                        relativePath: input.relativePath,
                        originalFilename: input.filename,
                        typeIdentifier: input.typeIdentifier,
                        byteCount: input.byteCount,
                        sha256Hex: input.sha256Hex,
                        operationID: input.operationID,
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
                    let attachmentCommand = AddAttachmentMetadataCommand(
                        operationID: input.operationID,
                        attachmentID: input.attachmentID,
                        ownerType: .statusObservation,
                        ownerID: observation.id,
                        relativePath: input.relativePath,
                        originalFilename: input.filename,
                        typeIdentifier: input.typeIdentifier,
                        byteCount: input.byteCount,
                        sha256Hex: input.sha256Hex,
                        committedAt: command.committedAt
                    )
                    try insertOperationReceipt(
                        OperationReceiptRecord(
                            operationID: input.operationID,
                            commandDigest: try AttachmentDigestV1.command(
                                attachmentCommand
                            ),
                            resultRecordType: "AttachmentRecord",
                            resultRecordID: attachment.id,
                            committedAt: command.committedAt
                        ),
                        reservation: reservation
                    )
                }
                try insertOperationReceipt(
                    OperationReceiptRecord(
                        operationID: command.operationID,
                        commandDigest: digest,
                        resultRecordType: "StatusObservationRecord",
                        resultRecordID: observation.id,
                        committedAt: command.committedAt
                    ),
                    reservation: reservation
                )
                try markCommitted(at: command.committedAt)
                result = StatusObservationCommitResult(
                    observationID: observation.id,
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

    func archiveStatusMetric(
        _ command: ArchiveStatusMetricCommand
    ) throws -> StatusMetricArchiveResult {
        guard command.committedAt.timeIntervalSince1970.isFinite else {
            throw PersonalTimelineWriteFailure.invalidInput
        }
        let digest = try StatusDigestV1.archiveMetricCommand(command)
        if let replay = try statusMetricArchiveReplay(
            command.operationID,
            digest: digest
        ) {
            return replay
        }
        let metric = try requiredActiveMetric(id: command.metricID)
        modelContext.autosaveEnabled = false
        let reservation = try reserveRevision(committedAt: command.committedAt)
        do {
            var result: StatusMetricArchiveResult?
            try modelContext.transaction {
                if let replay = try statusMetricArchiveReplay(
                    command.operationID,
                    digest: digest
                ) {
                    result = replay
                    return
                }
                guard !metric.isArchived else {
                    throw PersonalTimelineWriteFailure.staleRecord
                }
                metric.isArchived = true
                metric.archiveOperationID = command.operationID
                try upsertRevision(
                    recordType: "StatusMetricDefinitionRecord",
                    recordID: metric.id,
                    fields: try StatusDigestV1.metric(metric),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try insertOperationReceipt(
                    OperationReceiptRecord(
                        operationID: command.operationID,
                        commandDigest: digest,
                        resultRecordType: "StatusMetricDefinitionRecord",
                        resultRecordID: metric.id,
                        committedAt: command.committedAt
                    ),
                    reservation: reservation
                )
                try markCommitted(at: command.committedAt)
                result = StatusMetricArchiveResult(
                    metricID: metric.id,
                    didArchive: true
                )
            }
            guard let result else { throw PersonalTimelineWriteFailure.invalidInput }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func validateMetricCreation(id: UUID) throws {
        var idDescriptor = FetchDescriptor<StatusMetricDefinitionRecord>(
            predicate: #Predicate { $0.id == id }
        )
        idDescriptor.fetchLimit = 1
        guard try modelContext.fetch(idDescriptor).isEmpty else {
            throw PersonalTimelineWriteFailure.staleRecord
        }
        let activeCount = try modelContext.fetchCount(
            FetchDescriptor<StatusMetricDefinitionRecord>(
                predicate: #Predicate { !$0.isArchived }
            )
        )
        var totalDescriptor = FetchDescriptor<StatusMetricDefinitionRecord>()
        totalDescriptor.fetchLimit =
            PersonalTimelineCapacity.maximumStatusMetricDefinitions + 1
        let totalCount = try modelContext.fetch(totalDescriptor).count
        guard totalCount
                < PersonalTimelineCapacity.maximumStatusMetricDefinitions else {
            throw PersonalTimelineWriteFailure.invalidInput
        }
        guard activeCount < 5 else {
            throw PersonalTimelineWriteFailure.activeMetricLimitReached
        }
    }

    private func requiredActiveMetric(id: UUID) throws -> StatusMetricDefinitionRecord {
        var descriptor = FetchDescriptor<StatusMetricDefinitionRecord>(
            predicate: #Predicate { $0.id == id && !$0.isArchived }
        )
        descriptor.fetchLimit = 1
        guard let metric = try modelContext.fetch(descriptor).first else {
            throw PersonalTimelineWriteFailure.invalidInput
        }
        return metric
    }

    private func fetchStatusObservation(id: UUID) throws -> StatusObservationRecord? {
        var descriptor = FetchDescriptor<StatusObservationRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func validateUnusedOperationID(_ operationID: UUID) throws {
        var descriptor = FetchDescriptor<OperationReceiptRecord>(
            predicate: #Predicate { $0.operationID == operationID }
        )
        descriptor.fetchLimit = 1
        guard try modelContext.fetch(descriptor).isEmpty else {
            throw PersonalTimelineWriteFailure.operationConflict
        }
    }

    private func validatePreparedStatusAttachments(
        _ attachments: [NormalizedPreparedAttachment]
    ) throws {
        for attachment in attachments {
            let id = attachment.attachmentID
            var idDescriptor = FetchDescriptor<AttachmentRecord>(
                predicate: #Predicate { $0.id == id }
            )
            idDescriptor.fetchLimit = 1
            guard try modelContext.fetch(idDescriptor).isEmpty else {
                throw PersonalTimelineWriteFailure.staleRecord
            }
            let path = attachment.relativePath
            var pathDescriptor = FetchDescriptor<AttachmentRecord>(
                predicate: #Predicate { $0.relativePath == path }
            )
            pathDescriptor.fetchLimit = 1
            guard try modelContext.fetch(pathDescriptor).isEmpty else {
                throw PersonalTimelineWriteFailure.staleRecord
            }
            try validateUnusedOperationID(attachment.operationID)
        }
    }

    private func statusMetricReplay(
        _ operationID: UUID,
        digest: String
    ) throws -> StatusMetricCommitResult? {
        guard let receipt = try operationReceipt(operationID) else { return nil }
        let id = receipt.resultRecordID
        var descriptor = FetchDescriptor<StatusMetricDefinitionRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard receipt.commandDigest == digest,
              receipt.resultRecordType == "StatusMetricDefinitionRecord",
              try modelContext.fetch(descriptor).first?.operationID == operationID else {
            throw PersonalTimelineWriteFailure.operationConflict
        }
        return StatusMetricCommitResult(metricID: id, didCreate: false)
    }

    private func statusObservationReplay(
        _ operationID: UUID,
        digest: String
    ) throws -> StatusObservationCommitResult? {
        guard let receipt = try operationReceipt(operationID) else { return nil }
        let id = receipt.resultRecordID
        guard receipt.commandDigest == digest,
              receipt.resultRecordType == "StatusObservationRecord",
              try fetchStatusObservation(id: id)?.operationID == operationID else {
            throw PersonalTimelineWriteFailure.operationConflict
        }
        return StatusObservationCommitResult(observationID: id, didCreate: false)
    }

    private func statusMetricArchiveReplay(
        _ operationID: UUID,
        digest: String
    ) throws -> StatusMetricArchiveResult? {
        guard let receipt = try operationReceipt(operationID) else { return nil }
        let id = receipt.resultRecordID
        var descriptor = FetchDescriptor<StatusMetricDefinitionRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard receipt.commandDigest == digest,
              receipt.resultRecordType == "StatusMetricDefinitionRecord",
              let metric = try modelContext.fetch(descriptor).first,
              metric.isArchived,
              metric.archiveOperationID == operationID else {
            throw PersonalTimelineWriteFailure.operationConflict
        }
        return StatusMetricArchiveResult(metricID: id, didArchive: false)
    }

    private func operationReceipt(_ operationID: UUID) throws -> OperationReceiptRecord? {
        var descriptor = FetchDescriptor<OperationReceiptRecord>(
            predicate: #Predicate { $0.operationID == operationID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

extension AppReadActor {
    func statusMetrics() throws -> [StatusMetricSnapshot] {
        var descriptor = FetchDescriptor<StatusMetricDefinitionRecord>(
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
        )
        descriptor.fetchLimit =
            PersonalTimelineCapacity.maximumStatusMetricDefinitions + 1
        let metrics = try modelContext.fetch(descriptor)
        guard metrics.count
                <= PersonalTimelineCapacity.maximumStatusMetricDefinitions else {
            throw AppDataFailure.corruptionSuspected
        }
        return metrics.map {
            StatusMetricSnapshot(id: $0.id, displayName: $0.displayName, isArchived: $0.isArchived)
        }
    }

    func statusObservation(id: UUID) throws -> StatusObservationSnapshot? {
        var descriptor = FetchDescriptor<StatusObservationRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let observation = try modelContext.fetch(descriptor).first else { return nil }
        let sourceType = "StatusObservationRecord"
        var timeDescriptor = FetchDescriptor<HistoricalTimeRecord>(
            predicate: #Predicate {
                $0.sourceRecordType == sourceType && $0.sourceRecordID == id
            }
        )
        timeDescriptor.fetchLimit = 2
        let times = try modelContext.fetch(timeDescriptor)
        guard times.count == 1,
              let time = times.first,
              let timestamp = time.historicalTimestamp,
              let state = HistoricalAssociationState(rawValue: time.associationStateRawValue) else {
            throw AppDataFailure.corruptionSuspected
        }
        return StatusObservationSnapshot(
            id: observation.id,
            metricDefinitionID: observation.metricDefinitionID,
            metricNameSnapshot: observation.metricNameSnapshot,
            ordinalLevel: observation.ordinalLevel,
            note: observation.note,
            timestamp: timestamp,
            regimenVersionID: time.resolvedRegimenVersionID,
            associationState: state
        )
    }
}

enum StatusDigestV1 {
    static func createMetricCommand(
        _ command: CreateStatusMetricCommand,
        cleanName: String
    ) throws -> String {
        return try RecordDigestV1.sha256Hex(
            recordType: "CreateStatusMetricCommand",
            recordID: command.operationID,
            fields: [
                .init("committedAt", try RecordDigestV1.timestampValue(command.committedAt)),
                .init("displayName", .string(cleanName)),
                .init("metricID", .uuid(command.metricID))
            ]
        )
    }

    static func observationCommand(
        _ command: RecordStatusObservationCommand,
        cleanNote: String,
        cleanNewMetricName: String?
    ) throws -> String {
        var fields: [RecordDigestV1.Field] = [
            .init("committedAt", try RecordDigestV1.timestampValue(command.committedAt)),
            .init("instant", try RecordDigestV1.timestampValue(command.timestamp.instant)),
            .init("localDate", .string(command.timestamp.localDate.iso8601)),
            .init("metricDefinitionID", .uuid(command.metricDefinitionID)),
            .init(
                "newMetricID",
                command.newMetric.map { .uuid($0.metricID) } ?? .null
            ),
            .init(
                "newMetricName",
                cleanNewMetricName.map(RecordDigestV1.Value.string) ?? .null
            ),
            .init(
                "newMetricOperationID",
                command.newMetric.map { .uuid($0.operationID) } ?? .null
            ),
            .init("note", .string(cleanNote)),
            .init("observationID", .uuid(command.observationID)),
            .init("ordinalLevel", .integer(Int64(command.ordinalLevel))),
            .init("precision", .string(command.timestamp.precision.rawValue)),
            .init("provenance", .string(command.timestamp.provenance.rawValue)),
            .init("timeZoneIdentifier", .string(command.timestamp.timeZoneIdentifier)),
            .init("utcOffsetSeconds", .integer(Int64(command.timestamp.utcOffsetSeconds)))
        ]
        for (index, attachment) in command.attachments.enumerated() {
            let attachmentCommand = AddAttachmentMetadataCommand(
                operationID: attachment.operationID,
                attachmentID: attachment.attachmentID,
                ownerType: .statusObservation,
                ownerID: command.observationID,
                relativePath: attachment.relativePath,
                originalFilename: attachment.originalFilename,
                typeIdentifier: attachment.typeIdentifier,
                byteCount: attachment.byteCount,
                sha256Hex: attachment.sha256Hex,
                committedAt: command.committedAt
            )
            fields.append(
                .init(
                    String(format: "attachmentDigest-%03d", index),
                    .string(try AttachmentDigestV1.command(attachmentCommand))
                )
            )
        }
        return try RecordDigestV1.sha256Hex(
            recordType: "RecordStatusObservationCommand",
            recordID: command.operationID,
            fields: fields
        )
    }

    static func archiveMetricCommand(
        _ command: ArchiveStatusMetricCommand
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "ArchiveStatusMetricCommand",
            recordID: command.operationID,
            fields: [
                .init("committedAt", try RecordDigestV1.timestampValue(command.committedAt)),
                .init("metricID", .uuid(command.metricID))
            ]
        )
    }

    static func metric(
        _ record: StatusMetricDefinitionRecord
    ) throws -> [RecordDigestV1.Field] {
        [
            .init("createdAt", try RecordDigestV1.timestampValue(record.createdAt)),
            .init("displayName", .string(record.displayName)),
            .init("isArchived", .bool(record.isArchived)),
            .init("operationID", .uuid(record.operationID)),
            .init(
                "archiveOperationID",
                record.archiveOperationID.map(RecordDigestV1.Value.uuid)
                    ?? .null
            )
        ]
    }

    static func observation(
        _ record: StatusObservationRecord
    ) throws -> [RecordDigestV1.Field] {
        [
            .init("createdAt", try RecordDigestV1.timestampValue(record.createdAt)),
            .init("metricDefinitionID", .uuid(record.metricDefinitionID)),
            .init("metricNameSnapshot", .string(record.metricNameSnapshot)),
            .init("note", .string(record.note)),
            .init("operationID", .uuid(record.operationID)),
            .init("ordinalLevel", .integer(Int64(record.ordinalLevel)))
        ]
    }
}
