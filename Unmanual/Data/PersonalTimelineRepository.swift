import Foundation
import SwiftData

enum PersonalTimelineWriteFailure: Error, Equatable, Sendable {
    case invalidInput
    case operationConflict
    case activeMetricLimitReached
    case attachmentLimitReached
    case lastAttachmentRequired
    case staleRecord
}

struct LabItemDefinitionInput: Equatable, Sendable {
    let id: UUID
    let displayName: String
    let code: String

    init(id: UUID = UUID(), displayName: String, code: String = "") {
        self.id = id
        self.displayName = displayName
        self.code = code
    }
}

struct LabResultInput: Equatable, Sendable {
    let id: UUID
    let itemDefinitionID: UUID
    let rawValueOriginal: String
    let unitOriginal: String
    let referenceRangeOriginal: String?
    let assayOrVariantOriginal: String?

    init(
        id: UUID = UUID(),
        itemDefinitionID: UUID,
        rawValueOriginal: String,
        unitOriginal: String,
        referenceRangeOriginal: String? = nil,
        assayOrVariantOriginal: String? = nil
    ) {
        self.id = id
        self.itemDefinitionID = itemDefinitionID
        self.rawValueOriginal = rawValueOriginal
        self.unitOriginal = unitOriginal
        self.referenceRangeOriginal = referenceRangeOriginal
        self.assayOrVariantOriginal = assayOrVariantOriginal
    }
}

struct CreateLabSampleCommand: Sendable {
    let operationID: UUID
    let sampleID: UUID
    let timestamp: HistoricalTimestamp
    let specimenOriginal: String
    let contextNote: String
    let newDefinitions: [LabItemDefinitionInput]
    let results: [LabResultInput]
    let attachments: [PreparedAttachmentMetadata]
    let committedAt: Date

    init(
        operationID: UUID,
        sampleID: UUID = UUID(),
        timestamp: HistoricalTimestamp,
        specimenOriginal: String = "",
        contextNote: String = "",
        newDefinitions: [LabItemDefinitionInput],
        results: [LabResultInput],
        attachments: [PreparedAttachmentMetadata] = [],
        committedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.sampleID = sampleID
        self.timestamp = timestamp
        self.specimenOriginal = specimenOriginal
        self.contextNote = contextNote
        self.newDefinitions = newDefinitions
        self.results = results
        self.attachments = attachments
        self.committedAt = committedAt
    }
}

struct LabSampleCommitResult: Equatable, Sendable {
    let sampleID: UUID
    let didCreate: Bool
}

struct LabResultSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let itemDefinitionID: UUID
    let itemNameSnapshot: String
    let itemCodeSnapshot: String
    let rawValueOriginal: String
    let comparator: LabValueComparator?
    let canonicalDecimalString: String
    let unitOriginal: String
    let referenceRangeOriginal: String?
    let assayOrVariantOriginal: String?
}

struct LabItemDefinitionSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let code: String
    let isArchived: Bool
}

struct LabSampleSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: HistoricalTimestamp
    let regimenVersionID: UUID?
    let associationState: HistoricalAssociationState
    let specimenOriginal: String
    let contextNote: String
    let results: [LabResultSnapshot]
}

extension AppWriteActor {
    func createLabSample(
        _ command: CreateLabSampleCommand
    ) throws -> LabSampleCommitResult {
        let normalized = try normalizedLabSample(command)
        let commandDigest = try PersonalTimelineDigestV1.labSampleCommand(command)
        if let replay = try labSampleReplay(
            operationID: command.operationID,
            digest: commandDigest
        ) {
            return replay
        }
        guard try fetchLabSample(id: command.sampleID) == nil else {
            throw PersonalTimelineWriteFailure.staleRecord
        }
        try validateNewLabDefinitions(normalized.definitions)
        try validateLabResultIDs(normalized.results.map(\.id))
        try validatePreparedAttachmentIDs(normalized.attachments)

        modelContext.autosaveEnabled = false
        let reservation = try reserveRevision(committedAt: command.committedAt)
        do {
            var result: LabSampleCommitResult?
            try modelContext.transaction {
                if let replay = try labSampleReplay(
                    operationID: command.operationID,
                    digest: commandDigest
                ) {
                    result = replay
                    return
                }
                guard try fetchLabSample(id: command.sampleID) == nil else {
                    throw PersonalTimelineWriteFailure.staleRecord
                }
                try validateNewLabDefinitions(normalized.definitions)
                try validateLabResultIDs(normalized.results.map(\.id))
                try validatePreparedAttachmentIDs(normalized.attachments)

                let association = try resolvedAssociationForWrite(timestamp: command.timestamp)
                let sample = LabSampleRecord(
                    id: command.sampleID,
                    operationID: command.operationID,
                    specimenOriginal: normalized.specimen,
                    contextNote: normalized.context,
                    createdAt: command.committedAt
                )
                modelContext.insert(sample)
                try upsertRevision(
                    recordType: "LabSampleRecord",
                    recordID: sample.id,
                    fields: try PersonalTimelineDigestV1.labSample(sample),
                    reservation: reservation,
                    committedAt: command.committedAt
                )

                for definition in normalized.definitions {
                    let record = LabItemDefinitionRecord(
                        id: definition.id,
                        displayName: definition.displayName,
                        code: definition.code,
                        createdAt: command.committedAt
                    )
                    modelContext.insert(record)
                    try upsertRevision(
                        recordType: "LabItemDefinitionRecord",
                        recordID: record.id,
                        fields: try PersonalTimelineDigestV1.labItemDefinition(record),
                        reservation: reservation,
                        committedAt: command.committedAt
                    )
                }

                for (index, input) in normalized.results.enumerated() {
                    guard let definition = normalized.definitionByID[input.itemDefinitionID] else {
                        throw PersonalTimelineWriteFailure.invalidInput
                    }
                    let record = LabResultRecord(
                        id: input.id,
                        sampleID: sample.id,
                        sortOrder: index,
                        itemDefinitionID: input.itemDefinitionID,
                        itemNameSnapshot: definition.displayName,
                        itemCodeSnapshot: definition.code,
                        rawValueOriginal: input.value.original,
                        comparator: input.value.comparator,
                        canonicalDecimalString: input.value.canonicalDecimal,
                        unitOriginal: input.unit,
                        referenceRangeOriginal: input.referenceRange,
                        assayOrVariantOriginal: input.variant,
                        operationID: command.operationID,
                        createdAt: command.committedAt
                    )
                    modelContext.insert(record)
                    try upsertRevision(
                        recordType: "LabResultRecord",
                        recordID: record.id,
                        fields: try PersonalTimelineDigestV1.labResult(record),
                        reservation: reservation,
                        committedAt: command.committedAt
                    )
                }

                for input in normalized.attachments {
                    let attachment = AttachmentRecord(
                        id: input.attachmentID,
                        ownerType: .labSample,
                        ownerID: sample.id,
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
                        ownerType: .labSample,
                        ownerID: sample.id,
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
                            commandDigest: try AttachmentDigestV1.command(attachmentCommand),
                            resultRecordType: "AttachmentRecord",
                            resultRecordID: attachment.id,
                            committedAt: command.committedAt
                        ),
                        reservation: reservation
                    )
                }

                try insertHistoricalTimeForWrite(
                    sourceRecordType: "LabSampleRecord",
                    sourceRecordID: sample.id,
                    timestamp: command.timestamp,
                    legacyAssociationID: nil,
                    resolvedAssociationID: association.id,
                    associationState: association.state,
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try insertOperationReceipt(
                    OperationReceiptRecord(
                        operationID: command.operationID,
                        commandDigest: commandDigest,
                        resultRecordType: "LabSampleRecord",
                        resultRecordID: sample.id,
                        committedAt: command.committedAt
                    ),
                    reservation: reservation
                )
                try markCommitted(at: command.committedAt)
                result = LabSampleCommitResult(sampleID: sample.id, didCreate: true)
            }
            guard let result else { throw PersonalTimelineWriteFailure.invalidInput }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private struct NormalizedLabResult {
        let id: UUID
        let itemDefinitionID: UUID
        let value: LabDecimalValue
        let unit: String
        let referenceRange: String?
        let variant: String?
    }

    private struct NormalizedLabSample {
        let specimen: String
        let context: String
        let definitions: [LabItemDefinitionInput]
        let definitionByID: [UUID: LabItemDefinitionInput]
        let results: [NormalizedLabResult]
        let attachments: [NormalizedPreparedAttachment]
    }

    private func normalizedLabSample(
        _ command: CreateLabSampleCommand
    ) throws -> NormalizedLabSample {
        guard (!command.results.isEmpty || !command.attachments.isEmpty),
              command.committedAt.timeIntervalSince1970.isFinite,
              command.results.count
                <= PersonalTimelineCapacity.maximumLabResultsPerSample,
              command.newDefinitions.count
                <= PersonalTimelineCapacity.maximumLabItemDefinitions,
              Set(command.newDefinitions.map(\.id)).count == command.newDefinitions.count,
              Set(command.results.map(\.id)).count == command.results.count,
              Set(command.attachments.map(\.attachmentID)).count == command.attachments.count,
              Set(command.attachments.map(\.operationID)).count == command.attachments.count,
              Set(command.attachments.map(\.relativePath)).count == command.attachments.count,
              command.attachments.count <= AttachmentFileStore.maximumOwnerFiles,
              !command.attachments.contains(where: { $0.operationID == command.operationID }) else {
            throw PersonalTimelineWriteFailure.invalidInput
        }
        let attachments = try command.attachments.map(AttachmentMetadataFacts.normalize)
        guard Set(attachments.map(\.relativePath)).count == attachments.count else {
            throw PersonalTimelineWriteFailure.invalidInput
        }
        let totalAttachmentBytes = attachments.reduce(Int64(0)) { partial, attachment in
            let addition = partial.addingReportingOverflow(attachment.byteCount)
            return addition.overflow ? Int64.max : addition.partialValue
        }
        guard totalAttachmentBytes <= AttachmentFileStore.maximumOwnerBytes else {
            throw PersonalTimelineWriteFailure.attachmentLimitReached
        }
        let definitions = try command.newDefinitions.map { input in
            guard !input.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else {
                throw PersonalTimelineWriteFailure.invalidInput
            }
            return input
        }
        var definitionByID = Dictionary(
            uniqueKeysWithValues: definitions.map { ($0.id, $0) }
        )
        let referencedIDs = Set(command.results.map(\.itemDefinitionID))
        let missingIDs = referencedIDs.subtracting(definitionByID.keys)
        if !missingIDs.isEmpty {
            var descriptor = FetchDescriptor<LabItemDefinitionRecord>()
            descriptor.fetchLimit =
                PersonalTimelineCapacity.maximumLabItemDefinitions + 1
            let stored = try modelContext.fetch(descriptor)
            guard stored.count
                    <= PersonalTimelineCapacity.maximumLabItemDefinitions else {
                throw PersonalTimelineWriteFailure.invalidInput
            }
            for record in stored
            where missingIDs.contains(record.id) && !record.isArchived {
                definitionByID[record.id] = LabItemDefinitionInput(
                    id: record.id,
                    displayName: record.displayName,
                    code: record.code
                )
            }
        }
        let results = try command.results.map { input in
            guard definitionByID[input.itemDefinitionID] != nil,
                  !input.unitOriginal
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty else {
                throw PersonalTimelineWriteFailure.invalidInput
            }
            return NormalizedLabResult(
                id: input.id,
                itemDefinitionID: input.itemDefinitionID,
                value: try LabDecimalValue.parse(input.rawValueOriginal),
                unit: input.unitOriginal,
                referenceRange: input.referenceRangeOriginal,
                variant: input.assayOrVariantOriginal
            )
        }
        return NormalizedLabSample(
            specimen: command.specimenOriginal,
            context: command.contextNote,
            definitions: definitions,
            definitionByID: definitionByID,
            results: results,
            attachments: attachments
        )
    }

    private func validateNewLabDefinitions(
        _ definitions: [LabItemDefinitionInput]
    ) throws {
        var totalDescriptor = FetchDescriptor<LabItemDefinitionRecord>()
        totalDescriptor.fetchLimit =
            PersonalTimelineCapacity.maximumLabItemDefinitions + 1
        let existingCount = try modelContext.fetch(totalDescriptor).count
        guard existingCount <= PersonalTimelineCapacity.maximumLabItemDefinitions,
              definitions.count
                <= PersonalTimelineCapacity.maximumLabItemDefinitions - existingCount else {
            throw PersonalTimelineWriteFailure.invalidInput
        }
        for definition in definitions {
            let id = definition.id
            var descriptor = FetchDescriptor<LabItemDefinitionRecord>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            guard try modelContext.fetch(descriptor).isEmpty else {
                throw PersonalTimelineWriteFailure.staleRecord
            }
        }
    }

    private func validateLabResultIDs(_ ids: [UUID]) throws {
        for id in ids {
            var descriptor = FetchDescriptor<LabResultRecord>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            guard try modelContext.fetch(descriptor).isEmpty else {
                throw PersonalTimelineWriteFailure.staleRecord
            }
        }
    }

    private func validatePreparedAttachmentIDs(
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
            let operationID = attachment.operationID
            var receiptDescriptor = FetchDescriptor<OperationReceiptRecord>(
                predicate: #Predicate { $0.operationID == operationID }
            )
            receiptDescriptor.fetchLimit = 1
            guard try modelContext.fetch(receiptDescriptor).isEmpty else {
                throw PersonalTimelineWriteFailure.operationConflict
            }
        }
    }

    private func fetchLabSample(id: UUID) throws -> LabSampleRecord? {
        var descriptor = FetchDescriptor<LabSampleRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func labSampleReplay(
        operationID: UUID,
        digest: String
    ) throws -> LabSampleCommitResult? {
        var descriptor = FetchDescriptor<OperationReceiptRecord>(
            predicate: #Predicate { $0.operationID == operationID }
        )
        descriptor.fetchLimit = 1
        guard let receipt = try modelContext.fetch(descriptor).first else { return nil }
        guard receipt.commandDigest == digest,
              receipt.resultRecordType == "LabSampleRecord",
              try fetchLabSample(id: receipt.resultRecordID) != nil else {
            throw PersonalTimelineWriteFailure.operationConflict
        }
        return LabSampleCommitResult(sampleID: receipt.resultRecordID, didCreate: false)
    }

}

extension AppReadActor {
    func labItemDefinitions() throws -> [LabItemDefinitionSnapshot] {
        var descriptor = FetchDescriptor<LabItemDefinitionRecord>(
            sortBy: [SortDescriptor(\.displayName), SortDescriptor(\.id)]
        )
        descriptor.fetchLimit =
            PersonalTimelineCapacity.maximumLabItemDefinitions + 1
        let definitions = try modelContext.fetch(descriptor)
        guard definitions.count
                <= PersonalTimelineCapacity.maximumLabItemDefinitions else {
            throw AppDataFailure.corruptionSuspected
        }
        return definitions.map {
            LabItemDefinitionSnapshot(
                id: $0.id,
                displayName: $0.displayName,
                code: $0.code,
                isArchived: $0.isArchived
            )
        }
    }

    func labSample(id: UUID) throws -> LabSampleSnapshot? {
        var sampleDescriptor = FetchDescriptor<LabSampleRecord>(
            predicate: #Predicate { $0.id == id }
        )
        sampleDescriptor.fetchLimit = 1
        guard let sample = try modelContext.fetch(sampleDescriptor).first else { return nil }

        let sourceType = "LabSampleRecord"
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
              let associationState = HistoricalAssociationState(
                  rawValue: time.associationStateRawValue
              ) else {
            throw AppDataFailure.corruptionSuspected
        }

        var resultDescriptor = FetchDescriptor<LabResultRecord>(
            predicate: #Predicate { $0.sampleID == id },
            sortBy: [
                SortDescriptor(\.sortOrder),
                SortDescriptor(\.id)
            ]
        )
        resultDescriptor.fetchLimit =
            PersonalTimelineCapacity.maximumLabResultsPerSample + 1
        let results = try modelContext.fetch(resultDescriptor)
        guard results.count
                <= PersonalTimelineCapacity.maximumLabResultsPerSample else {
            throw AppDataFailure.corruptionSuspected
        }

        return LabSampleSnapshot(
            id: sample.id,
            timestamp: timestamp,
            regimenVersionID: time.resolvedRegimenVersionID,
            associationState: associationState,
            specimenOriginal: sample.specimenOriginal,
            contextNote: sample.contextNote,
            results: results.map {
                LabResultSnapshot(
                    id: $0.id,
                    itemDefinitionID: $0.itemDefinitionID,
                    itemNameSnapshot: $0.itemNameSnapshot,
                    itemCodeSnapshot: $0.itemCodeSnapshot,
                    rawValueOriginal: $0.rawValueOriginal,
                    comparator: $0.comparator,
                    canonicalDecimalString: $0.canonicalDecimalString,
                    unitOriginal: $0.unitOriginal,
                    referenceRangeOriginal: $0.referenceRangeOriginal,
                    assayOrVariantOriginal: $0.assayOrVariantOriginal
                )
            }
        )
    }
}

enum PersonalTimelineDigestV1 {
    static func labSampleCommand(
        _ command: CreateLabSampleCommand
    ) throws -> String {
        var fields: [RecordDigestV1.Field] = [
            .init("committedAt", try RecordDigestV1.timestampValue(command.committedAt)),
            .init("contextNote", .string(command.contextNote)),
            .init("definitionCount", .integer(Int64(command.newDefinitions.count))),
            .init("attachmentCount", .integer(Int64(command.attachments.count))),
            .init("resultCount", .integer(Int64(command.results.count))),
            .init("sampleID", .uuid(command.sampleID)),
            .init("specimenOriginal", .string(command.specimenOriginal))
        ]
        fields += try historicalTimestampFields(prefix: "sample", command.timestamp)
        for (index, definition) in command.newDefinitions.enumerated() {
            let prefix = "definition\(index)"
            fields.append(.init(prefix + "ID", .uuid(definition.id)))
            fields.append(.init(prefix + "Name", .string(definition.displayName)))
            fields.append(.init(prefix + "Code", .string(definition.code)))
        }
        for (index, result) in command.results.enumerated() {
            let parsed = try LabDecimalValue.parse(result.rawValueOriginal)
            let prefix = "result\(index)"
            fields.append(.init(prefix + "ID", .uuid(result.id)))
            fields.append(.init(prefix + "DefinitionID", .uuid(result.itemDefinitionID)))
            fields.append(.init(prefix + "Original", .string(parsed.original)))
            fields.append(.init(prefix + "Comparator", optionalString(parsed.comparator?.rawValue)))
            fields.append(.init(prefix + "Canonical", .string(parsed.canonicalDecimal)))
            fields.append(.init(prefix + "Unit", .string(result.unitOriginal)))
            fields.append(.init(prefix + "Reference", optionalString(result.referenceRangeOriginal)))
            fields.append(.init(prefix + "Variant", optionalString(result.assayOrVariantOriginal)))
        }
        for (index, attachment) in command.attachments.enumerated() {
            let normalized = try AttachmentMetadataFacts.normalize(attachment)
            let prefix = "attachment\(index)"
            fields.append(.init(prefix + "OperationID", .uuid(normalized.operationID)))
            fields.append(.init(prefix + "ID", .uuid(normalized.attachmentID)))
            fields.append(.init(prefix + "Path", .string(normalized.relativePath)))
            fields.append(.init(prefix + "Filename", .string(normalized.filename)))
            fields.append(.init(prefix + "Type", .string(normalized.typeIdentifier)))
            fields.append(.init(prefix + "ByteCount", .integer(normalized.byteCount)))
            fields.append(.init(prefix + "SHA256", .string(normalized.sha256Hex)))
        }
        return try RecordDigestV1.sha256Hex(
            recordType: "CreateLabSampleCommand",
            recordID: command.operationID,
            fields: fields
        )
    }

    static func labItemDefinition(
        _ record: LabItemDefinitionRecord
    ) throws -> [RecordDigestV1.Field] {
        [
            .init("bundledStableID", optionalString(record.bundledStableID)),
            .init("code", .string(record.code)),
            .init("createdAt", try RecordDigestV1.timestampValue(record.createdAt)),
            .init("displayName", .string(record.displayName)),
            .init("isArchived", .bool(record.isArchived)),
            .init("kind", .string(record.kindRawValue))
        ]
    }

    static func labSample(_ record: LabSampleRecord) throws -> [RecordDigestV1.Field] {
        [
            .init("contextNote", .string(record.contextNote)),
            .init("createdAt", try RecordDigestV1.timestampValue(record.createdAt)),
            .init("operationID", .uuid(record.operationID)),
            .init("specimenOriginal", .string(record.specimenOriginal))
        ]
    }

    static func labResult(_ record: LabResultRecord) throws -> [RecordDigestV1.Field] {
        [
            .init("assayOrVariantOriginal", optionalString(record.assayOrVariantOriginal)),
            .init("canonicalDecimalString", .string(record.canonicalDecimalString)),
            .init("comparator", optionalString(record.comparatorRawValue)),
            .init("createdAt", try RecordDigestV1.timestampValue(record.createdAt)),
            .init("itemCodeSnapshot", .string(record.itemCodeSnapshot)),
            .init("itemDefinitionID", .uuid(record.itemDefinitionID)),
            .init("itemNameSnapshot", .string(record.itemNameSnapshot)),
            .init("operationID", .uuid(record.operationID)),
            .init("rawValueOriginal", .string(record.rawValueOriginal)),
            .init("referenceRangeOriginal", optionalString(record.referenceRangeOriginal)),
            .init("sampleID", .uuid(record.sampleID)),
            .init("sortOrder", .integer(Int64(record.sortOrder))),
            .init("unitOriginal", .string(record.unitOriginal))
        ]
    }

    private static func optionalString(_ value: String?) -> RecordDigestV1.Value {
        value.map(RecordDigestV1.Value.string) ?? .null
    }

    private static func historicalTimestampFields(
        prefix: String,
        _ timestamp: HistoricalTimestamp
    ) throws -> [RecordDigestV1.Field] {
        [
            .init(prefix + "Instant", try RecordDigestV1.timestampValue(timestamp.instant)),
            .init(prefix + "LocalDate", .string(timestamp.localDate.iso8601)),
            .init(prefix + "LocalHour", .integer(Int64(timestamp.localTime.hour))),
            .init(prefix + "LocalMinute", .integer(Int64(timestamp.localTime.minute))),
            .init(prefix + "LocalSecond", .integer(Int64(timestamp.localTime.second))),
            .init(prefix + "LocalNanosecond", .integer(Int64(timestamp.localTime.nanosecond))),
            .init(prefix + "TimeZone", .string(timestamp.timeZoneIdentifier)),
            .init(prefix + "UTCOffset", .integer(Int64(timestamp.utcOffsetSeconds))),
            .init(prefix + "Precision", .string(timestamp.precision.rawValue)),
            .init(prefix + "Provenance", .string(timestamp.provenance.rawValue))
        ]
    }
}
