import Foundation
import SwiftData

enum ParentRecordType: String, Codable, Equatable, Sendable {
    case labSample
    case statusObservation

    var sourceRecordType: String {
        switch self {
        case .labSample:
            "LabSampleRecord"
        case .statusObservation:
            "StatusObservationRecord"
        }
    }

    func recordKey(parentID: UUID) -> String {
        rawValue + ":" + parentID.uuidString.lowercased()
    }
}

enum ParentRecordLifecycle: String, Codable, Equatable, Sendable {
    case active
    case deleted
}

struct ParentRecordTerminalOverlay: Equatable, Sendable {
    let labSampleIDs: Set<UUID>
    let statusObservationIDs: Set<UUID>

    static let empty = ParentRecordTerminalOverlay(
        labSampleIDs: [],
        statusObservationIDs: []
    )

    var isEmpty: Bool {
        labSampleIDs.isEmpty && statusObservationIDs.isEmpty
    }
}

enum ParentRecordMutationEventKind: String, Codable, Equatable, Sendable {
    case migratedSnapshot
    case createdSnapshot
    case corrected
    case deleted
}

@Model
final class ParentRecordLifecycleHeadRecord {
    @Attribute(.unique) var parentKey: String
    var parentTypeRawValue: String
    var parentID: UUID
    var latestEventID: UUID
    var latestPayloadID: UUID?
    var eventCount: Int
    var lifecycleRawValue: String
    var effectiveInstant: Date
    var effectiveLocalYear: Int
    var effectiveLocalMonth: Int
    var effectiveLocalDay: Int
    var effectiveLocalHour: Int
    var effectiveLocalMinute: Int
    var effectiveLocalSecond: Int
    var effectiveLocalNanosecond: Int
    var effectiveTimeZoneIdentifier: String
    var effectiveUTCOffsetSeconds: Int
    var effectivePrecisionRawValue: String
    var effectiveProvenanceRawValue: String
    var updatedAt: Date

    var parentType: ParentRecordType? {
        ParentRecordType(rawValue: parentTypeRawValue)
    }

    var lifecycle: ParentRecordLifecycle? {
        ParentRecordLifecycle(rawValue: lifecycleRawValue)
    }

    var effectiveTimestamp: HistoricalTimestamp? {
        guard let localDate = try? CivilDateFact(
            year: effectiveLocalYear,
            month: effectiveLocalMonth,
            day: effectiveLocalDay
        ),
        let localTime = try? HistoricalLocalTime(
            hour: effectiveLocalHour,
            minute: effectiveLocalMinute,
            second: effectiveLocalSecond,
            nanosecond: effectiveLocalNanosecond
        ),
        let precision = HistoricalTimestampPrecision(
            rawValue: effectivePrecisionRawValue
        ),
        let provenance = HistoricalTimestampProvenance(
            rawValue: effectiveProvenanceRawValue
        ) else {
            return nil
        }
        return try? HistoricalTimestamp(
            validatingInstant: effectiveInstant,
            localDate: localDate,
            localTime: localTime,
            timeZoneIdentifier: effectiveTimeZoneIdentifier,
            utcOffsetSeconds: effectiveUTCOffsetSeconds,
            precision: precision,
            provenance: provenance
        )
    }

    init(
        parentType: ParentRecordType,
        parentID: UUID,
        latestEventID: UUID,
        latestPayloadID: UUID? = nil,
        eventCount: Int,
        lifecycle: ParentRecordLifecycle = .active,
        effectiveTimestamp: HistoricalTimestamp,
        updatedAt: Date
    ) {
        self.parentKey = parentType.recordKey(parentID: parentID)
        self.parentTypeRawValue = parentType.rawValue
        self.parentID = parentID
        self.latestEventID = latestEventID
        self.latestPayloadID = latestPayloadID
        self.eventCount = eventCount
        self.lifecycleRawValue = lifecycle.rawValue
        self.effectiveInstant = effectiveTimestamp.instant
        self.effectiveLocalYear = effectiveTimestamp.localDate.year
        self.effectiveLocalMonth = effectiveTimestamp.localDate.month
        self.effectiveLocalDay = effectiveTimestamp.localDate.day
        self.effectiveLocalHour = effectiveTimestamp.localTime.hour
        self.effectiveLocalMinute = effectiveTimestamp.localTime.minute
        self.effectiveLocalSecond = effectiveTimestamp.localTime.second
        self.effectiveLocalNanosecond =
            effectiveTimestamp.localTime.nanosecond
        self.effectiveTimeZoneIdentifier =
            effectiveTimestamp.timeZoneIdentifier
        self.effectiveUTCOffsetSeconds =
            effectiveTimestamp.utcOffsetSeconds
        self.effectivePrecisionRawValue =
            effectiveTimestamp.precision.rawValue
        self.effectiveProvenanceRawValue =
            effectiveTimestamp.provenance.rawValue
        self.updatedAt = updatedAt
    }

    func replaceEffectiveTimestamp(_ timestamp: HistoricalTimestamp) {
        effectiveInstant = timestamp.instant
        effectiveLocalYear = timestamp.localDate.year
        effectiveLocalMonth = timestamp.localDate.month
        effectiveLocalDay = timestamp.localDate.day
        effectiveLocalHour = timestamp.localTime.hour
        effectiveLocalMinute = timestamp.localTime.minute
        effectiveLocalSecond = timestamp.localTime.second
        effectiveLocalNanosecond = timestamp.localTime.nanosecond
        effectiveTimeZoneIdentifier = timestamp.timeZoneIdentifier
        effectiveUTCOffsetSeconds = timestamp.utcOffsetSeconds
        effectivePrecisionRawValue = timestamp.precision.rawValue
        effectiveProvenanceRawValue = timestamp.provenance.rawValue
    }
}

@Model
final class ParentRecordMutationEventRecord {
    @Attribute(.unique) var id: UUID
    var parentTypeRawValue: String
    var parentID: UUID
    var kindRawValue: String
    var previousEventID: UUID?
    var payloadRecordType: String?
    var payloadID: UUID?
    @Attribute(.unique) var operationID: UUID
    var expectedHeadEventCount: Int?
    var expectedHeadLocalRevision: Int64?
    var commandDigest: String
    var preFactsDigest: String
    var postFactsDigest: String
    var committedAt: Date

    var parentType: ParentRecordType? {
        ParentRecordType(rawValue: parentTypeRawValue)
    }

    var kind: ParentRecordMutationEventKind? {
        ParentRecordMutationEventKind(rawValue: kindRawValue)
    }

    init(
        id: UUID = UUID(),
        parentType: ParentRecordType,
        parentID: UUID,
        kind: ParentRecordMutationEventKind,
        previousEventID: UUID?,
        payloadRecordType: String?,
        payloadID: UUID?,
        operationID: UUID,
        expectedHeadEventCount: Int? = nil,
        expectedHeadLocalRevision: Int64? = nil,
        commandDigest: String,
        preFactsDigest: String,
        postFactsDigest: String,
        committedAt: Date
    ) {
        self.id = id
        self.parentTypeRawValue = parentType.rawValue
        self.parentID = parentID
        self.kindRawValue = kind.rawValue
        self.previousEventID = previousEventID
        self.payloadRecordType = payloadRecordType
        self.payloadID = payloadID
        self.operationID = operationID
        self.expectedHeadEventCount = expectedHeadEventCount
        self.expectedHeadLocalRevision = expectedHeadLocalRevision
        self.commandDigest = commandDigest
        self.preFactsDigest = preFactsDigest
        self.postFactsDigest = postFactsDigest
        self.committedAt = committedAt
    }
}

@Model
final class LabSampleCorrectionSnapshotRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var eventID: UUID
    var parentID: UUID
    var specimenOriginal: String
    var contextNote: String
    var instant: Date
    var localYear: Int
    var localMonth: Int
    var localDay: Int
    var localHour: Int
    var localMinute: Int
    var localSecond: Int
    var localNanosecond: Int
    var timeZoneIdentifier: String
    var utcOffsetSeconds: Int
    var precisionRawValue: String
    var provenanceRawValue: String
    var resolvedRegimenVersionID: UUID?
    var associationStateRawValue: String
    var createdAt: Date

    var timestamp: HistoricalTimestamp? {
        guard let localDate = try? CivilDateFact(
            year: localYear,
            month: localMonth,
            day: localDay
        ),
        let localTime = try? HistoricalLocalTime(
            hour: localHour,
            minute: localMinute,
            second: localSecond,
            nanosecond: localNanosecond
        ),
        let precision = HistoricalTimestampPrecision(
            rawValue: precisionRawValue
        ),
        let provenance = HistoricalTimestampProvenance(
            rawValue: provenanceRawValue
        ) else {
            return nil
        }
        return try? HistoricalTimestamp(
            validatingInstant: instant,
            localDate: localDate,
            localTime: localTime,
            timeZoneIdentifier: timeZoneIdentifier,
            utcOffsetSeconds: utcOffsetSeconds,
            precision: precision,
            provenance: provenance
        )
    }

    init(
        id: UUID = UUID(),
        eventID: UUID,
        parentID: UUID,
        specimenOriginal: String,
        contextNote: String,
        timestamp: HistoricalTimestamp,
        resolvedRegimenVersionID: UUID?,
        associationState: HistoricalAssociationState,
        createdAt: Date
    ) {
        self.id = id
        self.eventID = eventID
        self.parentID = parentID
        self.specimenOriginal = specimenOriginal
        self.contextNote = contextNote
        self.instant = timestamp.instant
        self.localYear = timestamp.localDate.year
        self.localMonth = timestamp.localDate.month
        self.localDay = timestamp.localDate.day
        self.localHour = timestamp.localTime.hour
        self.localMinute = timestamp.localTime.minute
        self.localSecond = timestamp.localTime.second
        self.localNanosecond = timestamp.localTime.nanosecond
        self.timeZoneIdentifier = timestamp.timeZoneIdentifier
        self.utcOffsetSeconds = timestamp.utcOffsetSeconds
        self.precisionRawValue = timestamp.precision.rawValue
        self.provenanceRawValue = timestamp.provenance.rawValue
        self.resolvedRegimenVersionID = resolvedRegimenVersionID
        self.associationStateRawValue = associationState.rawValue
        self.createdAt = createdAt
    }
}

@Model
final class LabResultCorrectionSnapshotRecord {
    @Attribute(.unique) var id: UUID
    var correctionSnapshotID: UUID
    var logicalResultID: UUID
    var sortOrder: Int
    var itemDefinitionID: UUID
    var itemNameSnapshot: String
    var itemCodeSnapshot: String
    var rawValueOriginal: String
    var comparatorRawValue: String?
    var canonicalDecimalString: String
    var unitOriginal: String
    var referenceRangeOriginal: String?
    var assayOrVariantOriginal: String?

    var comparator: LabValueComparator? {
        comparatorRawValue.flatMap(LabValueComparator.init(rawValue:))
    }

    init(
        id: UUID = UUID(),
        correctionSnapshotID: UUID,
        logicalResultID: UUID,
        sortOrder: Int,
        itemDefinitionID: UUID,
        itemNameSnapshot: String,
        itemCodeSnapshot: String,
        rawValueOriginal: String,
        comparator: LabValueComparator?,
        canonicalDecimalString: String,
        unitOriginal: String,
        referenceRangeOriginal: String?,
        assayOrVariantOriginal: String?
    ) {
        self.id = id
        self.correctionSnapshotID = correctionSnapshotID
        self.logicalResultID = logicalResultID
        self.sortOrder = sortOrder
        self.itemDefinitionID = itemDefinitionID
        self.itemNameSnapshot = itemNameSnapshot
        self.itemCodeSnapshot = itemCodeSnapshot
        self.rawValueOriginal = rawValueOriginal
        self.comparatorRawValue = comparator?.rawValue
        self.canonicalDecimalString = canonicalDecimalString
        self.unitOriginal = unitOriginal
        self.referenceRangeOriginal = referenceRangeOriginal
        self.assayOrVariantOriginal = assayOrVariantOriginal
    }
}

@Model
final class StatusObservationCorrectionSnapshotRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var eventID: UUID
    var parentID: UUID
    var metricDefinitionID: UUID
    var metricNameSnapshot: String
    var ordinalLevel: Int
    var note: String
    var instant: Date
    var localYear: Int
    var localMonth: Int
    var localDay: Int
    var localHour: Int
    var localMinute: Int
    var localSecond: Int
    var localNanosecond: Int
    var timeZoneIdentifier: String
    var utcOffsetSeconds: Int
    var precisionRawValue: String
    var provenanceRawValue: String
    var resolvedRegimenVersionID: UUID?
    var associationStateRawValue: String
    var createdAt: Date

    var timestamp: HistoricalTimestamp? {
        guard let localDate = try? CivilDateFact(
            year: localYear,
            month: localMonth,
            day: localDay
        ),
        let localTime = try? HistoricalLocalTime(
            hour: localHour,
            minute: localMinute,
            second: localSecond,
            nanosecond: localNanosecond
        ),
        let precision = HistoricalTimestampPrecision(
            rawValue: precisionRawValue
        ),
        let provenance = HistoricalTimestampProvenance(
            rawValue: provenanceRawValue
        ) else {
            return nil
        }
        return try? HistoricalTimestamp(
            validatingInstant: instant,
            localDate: localDate,
            localTime: localTime,
            timeZoneIdentifier: timeZoneIdentifier,
            utcOffsetSeconds: utcOffsetSeconds,
            precision: precision,
            provenance: provenance
        )
    }

    init(
        id: UUID = UUID(),
        eventID: UUID,
        parentID: UUID,
        metricDefinitionID: UUID,
        metricNameSnapshot: String,
        ordinalLevel: Int,
        note: String,
        timestamp: HistoricalTimestamp,
        resolvedRegimenVersionID: UUID?,
        associationState: HistoricalAssociationState,
        createdAt: Date
    ) {
        self.id = id
        self.eventID = eventID
        self.parentID = parentID
        self.metricDefinitionID = metricDefinitionID
        self.metricNameSnapshot = metricNameSnapshot
        self.ordinalLevel = ordinalLevel
        self.note = note
        self.instant = timestamp.instant
        self.localYear = timestamp.localDate.year
        self.localMonth = timestamp.localDate.month
        self.localDay = timestamp.localDate.day
        self.localHour = timestamp.localTime.hour
        self.localMinute = timestamp.localTime.minute
        self.localSecond = timestamp.localTime.second
        self.localNanosecond = timestamp.localTime.nanosecond
        self.timeZoneIdentifier = timestamp.timeZoneIdentifier
        self.utcOffsetSeconds = timestamp.utcOffsetSeconds
        self.precisionRawValue = timestamp.precision.rawValue
        self.provenanceRawValue = timestamp.provenance.rawValue
        self.resolvedRegimenVersionID = resolvedRegimenVersionID
        self.associationStateRawValue = associationState.rawValue
        self.createdAt = createdAt
    }
}

@Model
final class ParentRecordDeletionTombstoneRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var eventID: UUID
    @Attribute(.unique) var parentKey: String
    var parentTypeRawValue: String
    var parentID: UUID
    var priorFactsDigest: String
    var impactDigest: String
    var attachmentManifest: String
    var attachmentCount: Int
    var attachmentByteCount: Int64
    var deletedAt: Date

    init(
        id: UUID = UUID(),
        eventID: UUID,
        parentType: ParentRecordType,
        parentID: UUID,
        priorFactsDigest: String,
        impactDigest: String,
        attachmentManifest: String,
        attachmentCount: Int,
        attachmentByteCount: Int64,
        deletedAt: Date
    ) {
        self.id = id
        self.eventID = eventID
        self.parentKey = parentType.recordKey(parentID: parentID)
        self.parentTypeRawValue = parentType.rawValue
        self.parentID = parentID
        self.priorFactsDigest = priorFactsDigest
        self.impactDigest = impactDigest
        self.attachmentManifest = attachmentManifest
        self.attachmentCount = attachmentCount
        self.attachmentByteCount = attachmentByteCount
        self.deletedAt = deletedAt
    }
}

@Model
final class ParentRecordLifecycleBackfillState {
    static let fixedKey = "v9-to-v10-parent-record-lifecycle"

    @Attribute(.unique) var taskKey: String
    var sourceSchemaVersion: String
    var labParentCount: Int
    var statusParentCount: Int
    var rootSetDigest: String
    var completedAt: Date?
    var updatedAt: Date

    init(
        taskKey: String = ParentRecordLifecycleBackfillState.fixedKey,
        sourceSchemaVersion: String,
        labParentCount: Int = 0,
        statusParentCount: Int = 0,
        rootSetDigest: String = "",
        completedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.taskKey = taskKey
        self.sourceSchemaVersion = sourceSchemaVersion
        self.labParentCount = labParentCount
        self.statusParentCount = statusParentCount
        self.rootSetDigest = rootSetDigest
        self.completedAt = completedAt
        self.updatedAt = updatedAt
    }
}
