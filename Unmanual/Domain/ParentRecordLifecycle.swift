import Foundation

struct ParentRecordHeadToken: Equatable, Sendable {
    let latestEventID: UUID
    let eventCount: Int
    let localRevision: Int64
    let factsDigest: String
}

struct CorrectedLabResultInput: Equatable, Sendable {
    let logicalResultID: UUID
    let itemDefinitionID: UUID
    let rawValueOriginal: String
    let unitOriginal: String
    let referenceRangeOriginal: String?
    let assayOrVariantOriginal: String?

    init(
        logicalResultID: UUID = UUID(),
        itemDefinitionID: UUID,
        rawValueOriginal: String,
        unitOriginal: String,
        referenceRangeOriginal: String? = nil,
        assayOrVariantOriginal: String? = nil
    ) {
        self.logicalResultID = logicalResultID
        self.itemDefinitionID = itemDefinitionID
        self.rawValueOriginal = rawValueOriginal
        self.unitOriginal = unitOriginal
        self.referenceRangeOriginal = referenceRangeOriginal
        self.assayOrVariantOriginal = assayOrVariantOriginal
    }
}

struct CorrectLabSampleCommand: Equatable, Sendable {
    let operationID: UUID
    let correctionID: UUID
    let eventID: UUID
    let parentID: UUID
    let expectedHead: ParentRecordHeadToken
    let timestamp: HistoricalTimestamp
    let specimenOriginal: String
    let contextNote: String
    let results: [CorrectedLabResultInput]
    let committedAt: Date

    init(
        operationID: UUID = UUID(),
        correctionID: UUID = UUID(),
        eventID: UUID = UUID(),
        parentID: UUID,
        expectedHead: ParentRecordHeadToken,
        timestamp: HistoricalTimestamp,
        specimenOriginal: String,
        contextNote: String,
        results: [CorrectedLabResultInput],
        committedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.correctionID = correctionID
        self.eventID = eventID
        self.parentID = parentID
        self.expectedHead = expectedHead
        self.timestamp = timestamp
        self.specimenOriginal = specimenOriginal
        self.contextNote = contextNote
        self.results = results
        self.committedAt = committedAt
    }
}

struct CorrectStatusObservationCommand: Equatable, Sendable {
    let operationID: UUID
    let correctionID: UUID
    let eventID: UUID
    let parentID: UUID
    let expectedHead: ParentRecordHeadToken
    let metricDefinitionID: UUID
    let ordinalLevel: Int
    let note: String
    let timestamp: HistoricalTimestamp
    let committedAt: Date

    init(
        operationID: UUID = UUID(),
        correctionID: UUID = UUID(),
        eventID: UUID = UUID(),
        parentID: UUID,
        expectedHead: ParentRecordHeadToken,
        metricDefinitionID: UUID,
        ordinalLevel: Int,
        note: String,
        timestamp: HistoricalTimestamp,
        committedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.correctionID = correctionID
        self.eventID = eventID
        self.parentID = parentID
        self.expectedHead = expectedHead
        self.metricDefinitionID = metricDefinitionID
        self.ordinalLevel = ordinalLevel
        self.note = note
        self.timestamp = timestamp
        self.committedAt = committedAt
    }
}

struct ParentRecordDeletionAttachment: Equatable, Sendable {
    let attachment: AttachmentSnapshot
    let deletionOperationID: UUID
}

struct DeleteParentRecordCommand: Equatable, Sendable {
    let operationID: UUID
    let eventID: UUID
    let tombstoneID: UUID
    let parentType: ParentRecordType
    let parentID: UUID
    let expectedHead: ParentRecordHeadToken
    let expectedImpactDigest: String
    let attachments: [ParentRecordDeletionAttachment]
    let committedAt: Date

    init(
        operationID: UUID = UUID(),
        eventID: UUID = UUID(),
        tombstoneID: UUID = UUID(),
        parentType: ParentRecordType,
        parentID: UUID,
        expectedHead: ParentRecordHeadToken,
        expectedImpactDigest: String,
        attachments: [ParentRecordDeletionAttachment],
        committedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.eventID = eventID
        self.tombstoneID = tombstoneID
        self.parentType = parentType
        self.parentID = parentID
        self.expectedHead = expectedHead
        self.expectedImpactDigest = expectedImpactDigest
        self.attachments = attachments
        self.committedAt = committedAt
    }
}

struct ParentRecordMutationResult: Equatable, Sendable {
    let parentType: ParentRecordType
    let parentID: UUID
    let eventID: UUID
    let didApply: Bool
}

struct ParentRecordDeletionImpact: Equatable, Sendable {
    let parentType: ParentRecordType
    let parentID: UUID
    let expectedHead: ParentRecordHeadToken
    let effectiveResultCount: Int
    let correctionCount: Int
    let attachments: [AttachmentSnapshot]
    let attachmentByteCount: Int64
    let impactDigest: String
}

enum ParentRecordMutationFailure: Error, Equatable, Sendable {
    case invalidInput
    case staleHead
    case noEffectiveChange
    case alreadyDeleted
    case operationConflict
    case impactChanged
    case correctionLimitReached
    case corruptionSuspected
}
