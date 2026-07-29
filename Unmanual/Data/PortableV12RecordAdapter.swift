import Foundation
import SwiftData

enum PortableV12RecordAdapterError: Error, Equatable, Sendable {
    case unsupportedRecordType(String)
    case unsupportedControlType(String)
    case invalidField(String)
    case invalidIdentity(String)
    case invalidEnum(String)
    case invalidRange(String)
}

struct PortableV12InsertionResult: Equatable, Sendable {
    let recordModelTypes: Set<String>
    let controlModelTypes: Set<String>
    let insertedRecordCount: Int
    let insertedControlCount: Int
    let insertedRevisionCount: Int
}

enum PortableV12RecordAdapter {
    static let supportedRecordModelTypes = Set(
        PortableDataV2RecordSchema.fieldsByModelType.keys
    )

    static let supportedControlModelTypes = Set(
        PortableDataV2ControlSchema.contracts.keys
    )

    static func insert(
        _ document: PortableDataV2Document,
        into context: ModelContext,
        deviceObservationDate: Date
    ) throws -> PortableV12InsertionResult {
        try PortableDataV2Validator.validate(document)
        guard try RecordDigestV1.timestampMicroseconds(
            deviceObservationDate
        ) != Int64.min else {
            throw PortableV12RecordAdapterError
                .invalidRange("deviceObservationDate")
        }

        var controlTypes: Set<String> = []
        for control in document.payload.controls {
            try insertControl(
                control,
                payload: document.payload,
                deviceObservationDate: deviceObservationDate,
                into: context
            )
            controlTypes.insert(control.modelType)
        }

        let lifecycleOperationIDs =
            try countdownLifecycleOperationIDs(
                in: document.payload.records
            )
        var recordTypes: Set<String> = []
        for record in document.payload.records {
            try insertRecord(
                record,
                lifecycleOperationIDs:
                    lifecycleOperationIDs,
                into: context
            )
            context.insert(
                RecordRevision(
                    recordKey: record.recordKey,
                    recordType: record.recordType,
                    recordID: record.recordID,
                    datasetID: record.datasetID,
                    localRevision: record.localRevision,
                    digestVersion: record.digestVersion,
                    digestHex: record.digestHex,
                    committedAt: try date(
                        microseconds:
                            record.committedAtMicroseconds,
                        field: "committedAtMicroseconds"
                    )
                )
            )
            recordTypes.insert(record.modelType)
        }

        return PortableV12InsertionResult(
            recordModelTypes: recordTypes,
            controlModelTypes: controlTypes,
            insertedRecordCount: document.payload.records.count,
            insertedControlCount: document.payload.controls.count,
            insertedRevisionCount: document.payload.records.count
        )
    }

    private static func insertRecord(
        _ record: PortableDataRecord,
        lifecycleOperationIDs: [UUID: UUID],
        into context: ModelContext
    ) throws {
        try PortableDataV2RecordSchema.validate(
            modelType: record.modelType,
            recordType: record.recordType,
            fields: record.fields
        )
        let fields = try PortableV12FieldReader(record.fields)
        let committedAt = try date(
            microseconds: record.committedAtMicroseconds,
            field: "committedAtMicroseconds"
        )

        switch record.modelType {
        case "HRTProfile":
            context.insert(
                HRTProfile(
                    id: record.recordID,
                    startDate: try fields.date("startDate"),
                    activePeriodStartDate:
                        try fields.date("activePeriodStartDate"),
                    createdAt: try fields.date("createdAt")
                )
            )
        case "CountdownRecord":
            context.insert(
                CountdownRecord(
                    id: record.recordID,
                    title: try fields.string("title"),
                    gentleTitle:
                        try fields.optionalString("gentleTitle"),
                    targetDate: try fields.date("targetDate"),
                    createdAt: try fields.date("createdAt"),
                    archivedAt:
                        try fields.optionalDate("archivedAt"),
                    continuesCountingUp:
                        try fields.bool("continuesCountingUp")
                )
            )
        case "RegimenVersion":
            context.insert(
                RegimenVersion(
                    id: record.recordID,
                    code: try fields.string("code"),
                    title: try fields.string("title"),
                    startedAt: try fields.date("startedAt"),
                    endedAt: try fields.optionalDate("endedAt"),
                    note: try fields.string("note"),
                    createdAt: try fields.date("createdAt")
                )
            )
        case "JourneyEntry":
            context.insert(
                JourneyEntry(
                    id: record.recordID,
                    text: try fields.string("text"),
                    kind: try fields.enumeration(
                        "kindRawValue",
                        as: JourneyEntryKind.self
                    ),
                    occurredAt: try fields.date("occurredAt"),
                    createdAt: try fields.date("createdAt"),
                    regimenVersionID:
                        try fields.optionalUUID("regimenVersionID")
                )
            )
        case "LabRecord":
            context.insert(
                LabRecord(
                    id: record.recordID,
                    itemName: try fields.string("itemName"),
                    itemCode: try fields.string("itemCode"),
                    rawValue: try fields.string("rawValue"),
                    numericValue: try fields.double("numericValue"),
                    unit: try fields.string("unit"),
                    sampledAt: try fields.date("sampledAt"),
                    referenceRangeOriginal:
                        try fields.optionalString(
                            "referenceRangeOriginal"
                        ),
                    contextNote: try fields.string("contextNote"),
                    regimenVersionID:
                        try fields.optionalUUID("regimenVersionID"),
                    createdAt: try fields.date("createdAt")
                )
            )
        case "UserPreferencesRecord":
            try requireStableIdentity(
                record,
                key: UserPreferencesRecord.fixedKey
            )
            context.insert(
                UserPreferencesRecord(
                    singletonKey:
                        UserPreferencesRecord.fixedKey,
                    gentleModeEnabled:
                        try fields.bool("gentleModeEnabled"),
                    notificationContentLevel:
                        try fields.string(
                            "notificationContentLevel"
                        ),
                    preferredLanguage:
                        try fields.string("preferredLanguage"),
                    onboardingCompleted:
                        try fields.bool("onboardingCompleted"),
                    createdAt: committedAt
                )
            )
        case "HrtJourneyProfileRecord":
            try requireStableIdentity(
                record,
                key: HrtJourneyProfileRecord.fixedKey
            )
            context.insert(
                HrtJourneyProfileRecord(
                    singletonKey:
                        HrtJourneyProfileRecord.fixedKey,
                    firstEverStartDate: try fields.civilDate(
                        year: "firstEverStartYear",
                        month: "firstEverStartMonth",
                        day: "firstEverStartDay"
                    ),
                    createdAt: committedAt
                )
            )
        case "HrtPeriodRecord":
            context.insert(
                HrtPeriodRecord(
                    id: record.recordID,
                    startDate: try fields.civilDate(
                        year: "startYear",
                        month: "startMonth",
                        day: "startDay"
                    ),
                    endDate: try fields.optionalCivilDate(
                        year: "endYear",
                        month: "endMonth",
                        day: "endDay"
                    ),
                    note: try fields.string("note"),
                    createdAt: committedAt
                )
            )
        case "RegimenPlanVersionRecord":
            context.insert(
                RegimenPlanVersionRecord(
                    id: record.recordID,
                    code: try fields.string("code"),
                    title: try fields.string("title"),
                    effectiveStartDate: try fields.civilDate(
                        year: "effectiveStartYear",
                        month: "effectiveStartMonth",
                        day: "effectiveStartDay"
                    ),
                    effectiveEndDate:
                        try fields.optionalCivilDate(
                            year: "effectiveEndYear",
                            month: "effectiveEndMonth",
                            day: "effectiveEndDay"
                        ),
                    previousVersionID:
                        try fields.optionalUUID("previousVersionID"),
                    changeReason:
                        try fields.string("changeReason"),
                    editState: try fields.enumeration(
                        "editState",
                        as: RegimenEditState.self
                    ),
                    isArchived: try fields.bool("isArchived"),
                    requiresMigrationReview:
                        try fields.bool(
                            "requiresMigrationReview"
                        ),
                    legacySourceID:
                        try fields.optionalUUID("legacySourceID"),
                    createdAt: committedAt
                )
            )
        case "RegimenItemRecord":
            context.insert(
                RegimenItemRecord(
                    id: record.recordID,
                    regimenVersionID:
                        try fields.uuid("regimenVersionID"),
                    sortOrder: try fields.int("sortOrder"),
                    catalogProductID:
                        try fields.optionalString(
                            "catalogProductID"
                        ),
                    catalogVersion:
                        try fields.optionalString("catalogVersion"),
                    displayName: try fields.string("displayName"),
                    genericName: try fields.string("genericName"),
                    dosageForm: try fields.string("dosageForm"),
                    route: try fields.string("route"),
                    doseOriginal:
                        try fields.string("doseOriginal"),
                    unitOriginal:
                        try fields.string("unitOriginal"),
                    productSnapshot:
                        try fields.string("productSnapshot"),
                    createdAt: committedAt
                )
            )
        case "ScheduleRuleRecord":
            context.insert(
                ScheduleRuleRecord(
                    id: record.recordID,
                    regimenItemID:
                        try fields.uuid("regimenItemID"),
                    kind: try fields.enumeration(
                        "kind",
                        as: ScheduleRuleKind.self
                    ),
                    anchorDate: try fields.civilDate(
                        year: "anchorYear",
                        month: "anchorMonth",
                        day: "anchorDay"
                    ),
                    endDate: try fields.optionalCivilDate(
                        year: "endYear",
                        month: "endMonth",
                        day: "endDay"
                    ),
                    localTimes: try fields.string("localTimes"),
                    weekdays: try fields.string("weekdays"),
                    intervalDays:
                        try fields.optionalInt("intervalDays"),
                    timeZoneBehavior: try fields.enumeration(
                        "timeZoneBehavior",
                        as: ScheduleTimeZoneBehavior.self
                    ),
                    fixedTimeZoneIdentifier:
                        try fields.optionalString(
                            "fixedTimeZoneIdentifier"
                        ),
                    reminderEnabled:
                        try fields.bool("reminderEnabled"),
                    defaultSnoozeMinutes:
                        try fields.int("defaultSnoozeMinutes"),
                    revision: try fields.int(
                        "revision",
                        range: 1...Int.max
                    ),
                    createdAt: committedAt
                )
            )
        case "HistoricalTimeRecord":
            let timestamp = try fields.historicalTimestamp(
                instant: "instant",
                year: "localYear",
                month: "localMonth",
                day: "localDay",
                hour: "localHour",
                minute: "localMinute",
                second: "localSecond",
                nanosecond: "localNanosecond",
                timeZone: "timeZoneIdentifier",
                utcOffset: "utcOffsetSeconds",
                precision: "precision",
                provenance: "provenance"
            )
            let sourceType =
                try fields.string("sourceRecordType")
            let sourceID = try fields.uuid("sourceRecordID")
            try requireStableIdentity(
                record,
                key: sourceType + ":"
                    + sourceID.uuidString.lowercased()
            )
            context.insert(
                HistoricalTimeRecord(
                    sourceRecordType: sourceType,
                    sourceRecordID: sourceID,
                    timestamp: timestamp,
                    legacyAssociationID:
                        try fields.optionalUUID(
                            "legacyAssociationID"
                        ),
                    resolvedRegimenVersionID:
                        try fields.optionalUUID(
                            "resolvedRegimenVersionID"
                        ),
                    associationState: try fields.enumeration(
                        "associationState",
                        as: HistoricalAssociationState.self
                    )
                )
            )
        case "AdministrationEventRecord":
            context.insert(
                AdministrationEventRecord(
                    id: record.recordID,
                    occurrenceKey:
                        try fields.string("occurrenceKey"),
                    scheduleRuleID:
                        try fields.uuid("scheduleRuleID"),
                    scheduleRevision:
                        try fields.int("scheduleRevision"),
                    regimenVersionID:
                        try fields.uuid("regimenVersionID"),
                    regimenItemID:
                        try fields.uuid("regimenItemID"),
                    status: try fields.enumeration(
                        "status",
                        as: AdministrationStatus.self
                    ),
                    plannedInstant:
                        try fields.date("plannedInstant"),
                    supersedesEventID:
                        try fields.optionalUUID(
                            "supersedesEventID"
                        ),
                    note: try fields.string("note"),
                    operationID:
                        try fields.uuid("operationID"),
                    createdAt: committedAt
                )
            )
        case "OperationReceiptRecord":
            let operationID = try fields.uuid("operationID")
            try requireIdentity(record, equals: operationID)
            context.insert(
                OperationReceiptRecord(
                    operationID: operationID,
                    commandDigest:
                        try fields.string("commandDigest"),
                    resultRecordType:
                        try fields.string("resultRecordType"),
                    resultRecordID:
                        try fields.uuid("resultRecordID"),
                    committedAt:
                        try fields.date("committedAt")
                )
            )
        case "OperationReceiptLedgerRecord":
            try requireIdentity(
                record,
                equals: TodayExecutionDigestV1.receiptLedgerID
            )
            let ledgerKey = try fields.string("ledgerKey")
            guard ledgerKey
                    == OperationReceiptLedgerRecord.fixedKey else {
                throw PortableV12RecordAdapterError
                    .invalidIdentity(record.recordKey)
            }
            context.insert(
                OperationReceiptLedgerRecord(
                    ledgerKey: ledgerKey,
                    receiptCount: try fields.int(
                        "receiptCount",
                        range: 0...Int.max
                    ),
                    receiptSetDigest:
                        try fields.string("receiptSetDigest"),
                    updatedAt: committedAt
                )
            )
        case "ReminderOverrideRecord":
            context.insert(
                ReminderOverrideRecord(
                    id: record.recordID,
                    occurrenceKey:
                        try fields.string("occurrenceKey"),
                    scheduleRuleID:
                        try fields.uuid("scheduleRuleID"),
                    scheduleRevision:
                        try fields.int("scheduleRevision"),
                    fireAt: try fields.date("fireAt"),
                    plannedInstant:
                        try fields.date("plannedInstant"),
                    supersedesOverrideID:
                        try fields.optionalUUID(
                            "supersedesOverrideID"
                        ),
                    operationID:
                        try fields.uuid("operationID"),
                    createdAt: committedAt
                )
            )
        case "ReminderPreferenceRecord":
            let scheduleID = try fields.uuid("scheduleRuleID")
            let revision =
                try fields.int("expectedRuleRevision")
            let preferenceKey =
                try fields.string("preferenceKey")
            guard preferenceKey == ReminderPreferenceRecord.key(
                scheduleRuleID: scheduleID,
                revision: revision
            ) else {
                throw PortableV12RecordAdapterError
                    .invalidIdentity(record.recordKey)
            }
            context.insert(
                ReminderPreferenceRecord(
                    id: record.recordID,
                    scheduleRuleID: scheduleID,
                    expectedRuleRevision: revision,
                    isEnabled: try fields.bool("isEnabled"),
                    defaultSnoozeMinutes:
                        try fields.int("defaultSnoozeMinutes"),
                    contentVersion:
                        try fields.string("contentVersion"),
                    lastOperationID:
                        try fields.uuid("lastOperationID"),
                    updatedAt: committedAt
                )
            )
        case "LabItemDefinitionRecord":
            context.insert(
                LabItemDefinitionRecord(
                    id: record.recordID,
                    kind: try fields.enumeration(
                        "kind",
                        as: LabItemDefinitionKind.self
                    ),
                    bundledStableID:
                        try fields.optionalString(
                            "bundledStableID"
                        ),
                    displayName: try fields.string("displayName"),
                    code: try fields.string("code"),
                    isArchived: try fields.bool("isArchived"),
                    createdAt: try fields.date("createdAt")
                )
            )
        case "LabSampleRecord":
            context.insert(
                LabSampleRecord(
                    id: record.recordID,
                    operationID:
                        try fields.uuid("operationID"),
                    specimenOriginal:
                        try fields.string("specimenOriginal"),
                    contextNote:
                        try fields.string("contextNote"),
                    createdAt: try fields.date("createdAt")
                )
            )
        case "LabResultRecord":
            context.insert(
                LabResultRecord(
                    id: record.recordID,
                    sampleID: try fields.uuid("sampleID"),
                    sortOrder: try fields.int("sortOrder"),
                    itemDefinitionID:
                        try fields.uuid("itemDefinitionID"),
                    itemNameSnapshot:
                        try fields.string("itemNameSnapshot"),
                    itemCodeSnapshot:
                        try fields.string("itemCodeSnapshot"),
                    rawValueOriginal:
                        try fields.string("rawValueOriginal"),
                    comparator: try fields.optionalEnumeration(
                        "comparator",
                        as: LabValueComparator.self
                    ),
                    canonicalDecimalString:
                        try fields.string(
                            "canonicalDecimalString"
                        ),
                    unitOriginal:
                        try fields.string("unitOriginal"),
                    referenceRangeOriginal:
                        try fields.optionalString(
                            "referenceRangeOriginal"
                        ),
                    assayOrVariantOriginal:
                        try fields.optionalString(
                            "assayOrVariantOriginal"
                        ),
                    operationID:
                        try fields.uuid("operationID"),
                    createdAt: try fields.date("createdAt")
                )
            )
        case "StatusMetricDefinitionRecord":
            context.insert(
                StatusMetricDefinitionRecord(
                    id: record.recordID,
                    displayName: try fields.string("displayName"),
                    isArchived: try fields.bool("isArchived"),
                    operationID:
                        try fields.uuid("operationID"),
                    archiveOperationID:
                        try fields.optionalUUID(
                            "archiveOperationID"
                        ),
                    createdAt: try fields.date("createdAt")
                )
            )
        case "StatusObservationRecord":
            context.insert(
                StatusObservationRecord(
                    id: record.recordID,
                    metricDefinitionID:
                        try fields.uuid("metricDefinitionID"),
                    metricNameSnapshot:
                        try fields.string("metricNameSnapshot"),
                    ordinalLevel:
                        try fields.int("ordinalLevel"),
                    note: try fields.string("note"),
                    operationID:
                        try fields.uuid("operationID"),
                    createdAt: try fields.date("createdAt")
                )
            )
        case "AttachmentRecord":
            context.insert(
                AttachmentRecord(
                    id: record.recordID,
                    ownerType: try fields.enumeration(
                        "ownerType",
                        as: AttachmentOwnerType.self
                    ),
                    ownerID: try fields.uuid("ownerID"),
                    relativePath:
                        try fields.string("relativePath"),
                    originalFilename:
                        try fields.string("originalFilename"),
                    typeIdentifier:
                        try fields.string("typeIdentifier"),
                    byteCount: try fields.int64(
                        "byteCount",
                        range: 0...Int64.max
                    ),
                    sha256Hex:
                        try fields.string("sha256Hex"),
                    operationID:
                        try fields.uuid("operationID"),
                    deleteOperationID:
                        try fields.optionalUUID(
                            "deleteOperationID"
                        ),
                    createdAt: try fields.date("createdAt"),
                    deletedAt:
                        try fields.optionalDate("deletedAt")
                )
            )
        default:
            try insertAdvancedRecord(
                record,
                fields: fields,
                committedAt: committedAt,
                lifecycleOperationIDs:
                    lifecycleOperationIDs,
                into: context
            )
        }
    }

    private static func requireIdentity(
        _ record: PortableDataRecord,
        equals expected: UUID
    ) throws {
        guard record.recordID == expected else {
            throw PortableV12RecordAdapterError
                .invalidIdentity(record.recordKey)
        }
    }

    private static func countdownLifecycleOperationIDs(
        in records: [PortableDataRecord]
    ) throws -> [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        for record in records
        where record.modelType
                == "CountdownLifecycleEventRecord" {
            let fields = try PortableV12FieldReader(
                record.fields
            )
            guard result.updateValue(
                try fields.uuid("operationID"),
                forKey: record.recordID
            ) == nil else {
                throw PortableV12RecordAdapterError
                    .invalidIdentity(record.recordKey)
            }
        }
        return result
    }

    private static func requireStableIdentity(
        _ record: PortableDataRecord,
        key: String
    ) throws {
        try requireIdentity(
            record,
            equals: CoreTimeRegimenBackfill.stableUUID(for: key)
        )
    }

    fileprivate static func date(
        microseconds: Int64,
        field: String
    ) throws -> Date {
        let value = Date(
            timeIntervalSince1970:
                TimeInterval(microseconds) / 1_000_000
        )
        guard value.timeIntervalSince1970.isFinite,
              try RecordDigestV1.timestampMicroseconds(value)
                == microseconds else {
            throw PortableV12RecordAdapterError
                .invalidRange(field)
        }
        return value
    }
}

private extension PortableV12RecordAdapter {
    static func insertAdvancedRecord(
        _ record: PortableDataRecord,
        fields: PortableV12FieldReader,
        committedAt: Date,
        lifecycleOperationIDs: [UUID: UUID],
        into context: ModelContext
    ) throws {
        switch record.modelType {
        case "CountdownStateRecord":
            context.insert(
                CountdownStateRecord(
                    id: record.recordID,
                    title: try fields.string("title"),
                    gentleTitle:
                        try fields.optionalString("gentleTitle"),
                    targetDate:
                        try fields.optionalCivilDate("target"),
                    lifecycle: try fields.enumeration(
                        "lifecycle",
                        as: CountdownLifecycle.self
                    ),
                    overdueMode: try fields.enumeration(
                        "overdueMode",
                        as: CountdownOverdueMode.self
                    ),
                    showInToday:
                        try fields.bool("showInToday"),
                    latestEventID:
                        try fields.uuid("latestEventID"),
                    completedAt:
                        try fields.optionalDate("completedAt"),
                    archivedAt:
                        try fields.optionalDate("archivedAt"),
                    deletedAt:
                        try fields.optionalDate("deletedAt"),
                    terminalReminderWasEnabled:
                        try fields.optionalBool(
                            "terminalReminderWasEnabled"
                        ),
                    terminalReminderLeadDays:
                        try fields.optionalInt(
                            "terminalReminderLeadDays"
                        ),
                    terminalReminderLocalHour:
                        try fields.optionalInt(
                            "terminalReminderLocalHour",
                            range: 0...23
                        ),
                    terminalReminderLocalMinute:
                        try fields.optionalInt(
                            "terminalReminderLocalMinute",
                            range: 0...59
                        ),
                    requiresReview:
                        try fields.bool("requiresReview"),
                    createdAt: try fields.date("createdAt"),
                    updatedAt: try fields.date("updatedAt")
                )
            )
        case "CountdownLifecycleEventRecord":
            context.insert(
                CountdownLifecycleEventRecord(
                    id: record.recordID,
                    countdownID:
                        try fields.uuid("countdownID"),
                    kind: try fields.enumeration(
                        "kind",
                        as: CountdownLifecycleEventKind.self
                    ),
                    previousEventID:
                        try fields.optionalUUID(
                            "previousEventID"
                        ),
                    operationID:
                        try fields.uuid("operationID"),
                    oldTargetDate:
                        try fields.optionalCivilDate("oldTarget"),
                    newTargetDate:
                        try fields.optionalCivilDate("newTarget"),
                    replacementCountdownID:
                        try fields.optionalUUID(
                            "replacementCountdownID"
                        ),
                    timestamp: try fields.historicalTimestamp(
                        instant: "occurredAt",
                        localDate: "localDate",
                        hour: "localHour",
                        minute: "localMinute",
                        second: "localSecond",
                        nanosecond: "localNanosecond",
                        timeZone: "timeZoneIdentifier",
                        utcOffset: "utcOffsetSeconds",
                        precision: "precision",
                        provenance: "provenance"
                    )
                )
            )
        case "CountdownReminderRuleRecord":
            let countdownID = try fields.uuid("countdownID")
            let ruleKey = try fields.string("ruleKey")
            guard ruleKey
                    == CountdownReminderRuleRecord.key(
                        countdownID: countdownID
                    ) else {
                throw PortableV12RecordAdapterError
                    .invalidIdentity(record.recordKey)
            }
            context.insert(
                CountdownReminderRuleRecord(
                    id: record.recordID,
                    countdownID: countdownID,
                    isEnabled: try fields.bool("isEnabled"),
                    leadDays: try fields.int(
                        "leadDays",
                        range: 0...Int.max
                    ),
                    localHour: try fields.int(
                        "localHour",
                        range: 0...23
                    ),
                    localMinute: try fields.int(
                        "localMinute",
                        range: 0...59
                    ),
                    timeZoneBehavior: try fields.enumeration(
                        "timeZoneBehavior",
                        as:
                            CountdownReminderTimeZoneBehavior
                            .self
                    ),
                    contentVersion:
                        try fields.string("contentVersion"),
                    lastOperationID:
                        try fields.uuid("lastOperationID"),
                    updatedAt: try fields.date("updatedAt")
                )
            )
        case "CountdownCommandAuditRecord":
            guard let operationID =
                    lifecycleOperationIDs[record.recordID] else {
                throw PortableV12RecordAdapterError
                    .invalidIdentity(record.recordKey)
            }
            try insertCountdownCommandAudit(
                record,
                fields: fields,
                operationID: operationID,
                into: context
            )
        case "CountdownV6AuditCheckpointRecord":
            let countdownID = record.recordID
            let value = CountdownV6AuditCheckpointRecord(
                countdownID: countdownID,
                boundaryEventID:
                    try fields.uuid("boundaryEventID"),
                prefixEventCount: try fields.int(
                    "prefixEventCount",
                    range: 0...Int.max
                ),
                prefixChainDigest:
                    try fields.string("prefixChainDigest"),
                postFactsDigest:
                    try fields.string("postFactsDigest"),
                reminderAdmission: try fields.enumeration(
                    "reminderAdmission",
                    as: CountdownReminderAdmission.self
                ),
                createdAt: try fields.date("createdAt")
            )
            try value.seal()
            guard value.checkpointDigest
                    == (try fields.string("checkpointDigest")) else {
                throw PortableV12RecordAdapterError
                    .invalidField("checkpointDigest")
            }
            context.insert(value)
        case "CountdownIntegrityBackfillState":
            let taskKey = try fields.string("taskKey")
            try requireStableIdentity(record, key: taskKey)
            context.insert(
                CountdownIntegrityBackfillState(
                    taskKey: taskKey,
                    sourceSchemaVersion:
                        try fields.string(
                            "sourceSchemaVersion"
                        ),
                    initialAuditCount: try fields.int(
                        "initialAuditCount",
                        range: 0...Int.max
                    ),
                    initialCheckpointCount: try fields.int(
                        "initialCheckpointCount",
                        range: 0...Int.max
                    ),
                    initialIntegritySetDigest:
                        try fields.string(
                            "initialIntegritySetDigest"
                        ),
                    completedAt:
                        try fields.optionalDate("completedAt"),
                    updatedAt: try fields.date("updatedAt")
                )
            )
        case "OnboardingProgressRecord":
            let singletonKey =
                try fields.string("singletonKey")
            try requireStableIdentity(
                record,
                key: singletonKey
            )
            context.insert(
                OnboardingProgressRecord(
                    singletonKey: singletonKey,
                    contractVersion: try fields.int(
                        "contractVersion",
                        range: 1...Int.max
                    ),
                    step: try fields.enumeration(
                        "step",
                        as: OnboardingStep.self
                    ),
                    skippedStartDate:
                        try fields.bool("skippedStartDate"),
                    skippedReminder:
                        try fields.bool("skippedReminder"),
                    skippedCountdown:
                        try fields.bool("skippedCountdown"),
                    completedAt:
                        try fields.optionalDate("completedAt"),
                    updatedAt: try fields.date("updatedAt")
                )
            )
        case "OnboardingBackfillState":
            let taskKey = try fields.string("taskKey")
            try requireStableIdentity(record, key: taskKey)
            context.insert(
                OnboardingBackfillState(
                    taskKey: taskKey,
                    source: try fields.enumeration(
                        "source",
                        as: OnboardingBackfillSource.self
                    ),
                    completedAt:
                        try fields.optionalDate("completedAt"),
                    updatedAt: try fields.date("updatedAt")
                )
            )
        case "HrtJourneyLifecycleEventRecord":
            context.insert(
                HrtJourneyLifecycleEventRecord(
                    id: record.recordID,
                    operationID:
                        try fields.uuid("operationID"),
                    kind: try fields.enumeration(
                        "kind",
                        as:
                            HrtJourneyLifecycleEventKind.self
                    ),
                    source: try fields.enumeration(
                        "source",
                        as:
                            HrtJourneyLifecycleEventSource.self
                    ),
                    previousEventID:
                        try fields.optionalUUID(
                            "previousEventID"
                        ),
                    periodID:
                        try fields.optionalUUID("periodID"),
                    transitionDate:
                        try fields.optionalCivilDate(
                            "transitionDate"
                        ),
                    noteSnapshot:
                        try fields.string("noteSnapshot"),
                    timestamp: try fields.historicalTimestamp(
                        instant: "occurredAt",
                        localDate: "localDate",
                        hour: "localHour",
                        minute: "localMinute",
                        second: "localSecond",
                        nanosecond: "localNanosecond",
                        timeZone: "timeZoneIdentifier",
                        utcOffset: "utcOffsetSeconds",
                        precision: "precision",
                        provenance: "provenance"
                    ),
                    preFactsDigest:
                        try fields.string("preFactsDigest"),
                    postFactsDigest:
                        try fields.string("postFactsDigest")
                )
            )
        case "HrtJourneyLifecycleBackfillState":
            try requireIdentity(
                record,
                equals: CoreTimeRegimenBackfill.stableUUID(
                    for:
                        HrtJourneyLifecycleBackfillState
                        .fixedKey
                )
            )
            context.insert(
                HrtJourneyLifecycleBackfillState(
                    sourceSchemaVersion:
                        try fields.string(
                            "sourceSchemaVersion"
                        ),
                    initialPeriodCount: try fields.int(
                        "initialPeriodCount",
                        range: 0...Int.max
                    ),
                    initialEventCount: try fields.int(
                        "initialEventCount",
                        range: 0...Int.max
                    ),
                    initialFactsDigest:
                        try fields.string("initialFactsDigest"),
                    completedAt:
                        try fields.optionalDate("completedAt"),
                    updatedAt: try fields.date("updatedAt")
                )
            )
        case "ParentRecordLifecycleHeadRecord":
            try insertParentLifecycleHead(
                record,
                fields: fields,
                into: context
            )
        case "ParentRecordMutationEventRecord":
            context.insert(
                ParentRecordMutationEventRecord(
                    id: record.recordID,
                    parentType: try fields.enumeration(
                        "parentType",
                        as: ParentRecordType.self
                    ),
                    parentID: try fields.uuid("parentID"),
                    kind: try fields.enumeration(
                        "kind",
                        as:
                            ParentRecordMutationEventKind.self
                    ),
                    previousEventID:
                        try fields.optionalUUID(
                            "previousEventID"
                        ),
                    payloadRecordType:
                        try fields.optionalString(
                            "payloadRecordType"
                        ),
                    payloadID:
                        try fields.optionalUUID("payloadID"),
                    operationID:
                        try fields.uuid("operationID"),
                    expectedHeadEventCount:
                        try fields.optionalInt(
                            "expectedHeadEventCount",
                            range: 0...Int.max
                        ),
                    expectedHeadLocalRevision:
                        try fields.optionalInt64(
                            "expectedHeadLocalRevision",
                            range: 1...Int64.max
                        ),
                    commandDigest:
                        try fields.string("commandDigest"),
                    preFactsDigest:
                        try fields.string("preFactsDigest"),
                    postFactsDigest:
                        try fields.string("postFactsDigest"),
                    committedAt:
                        try fields.date("committedAt")
                )
            )
        case "LabSampleCorrectionSnapshotRecord":
            context.insert(
                LabSampleCorrectionSnapshotRecord(
                    id: record.recordID,
                    eventID: try fields.uuid("eventID"),
                    parentID: try fields.uuid("parentID"),
                    specimenOriginal:
                        try fields.string("specimenOriginal"),
                    contextNote:
                        try fields.string("contextNote"),
                    timestamp: try fields.historicalTimestamp(
                        instant: "instant",
                        localDate: "localDate",
                        hour: "localHour",
                        minute: "localMinute",
                        second: "localSecond",
                        nanosecond: "localNanosecond",
                        timeZone: "timeZone",
                        utcOffset: "utcOffset",
                        precision: "precision",
                        provenance: "provenance"
                    ),
                    resolvedRegimenVersionID:
                        try fields.optionalUUID(
                            "resolvedRegimenVersionID"
                        ),
                    associationState: try fields.enumeration(
                        "associationState",
                        as: HistoricalAssociationState.self
                    ),
                    createdAt: try fields.date("createdAt")
                )
            )
        case "LabResultCorrectionSnapshotRecord":
            context.insert(
                LabResultCorrectionSnapshotRecord(
                    id: record.recordID,
                    correctionSnapshotID:
                        try fields.uuid(
                            "correctionSnapshotID"
                        ),
                    logicalResultID:
                        try fields.uuid("logicalResultID"),
                    sortOrder: try fields.int("sortOrder"),
                    itemDefinitionID:
                        try fields.uuid("itemDefinitionID"),
                    itemNameSnapshot:
                        try fields.string("itemNameSnapshot"),
                    itemCodeSnapshot:
                        try fields.string("itemCodeSnapshot"),
                    rawValueOriginal:
                        try fields.string("rawValueOriginal"),
                    comparator: try fields.optionalEnumeration(
                        "comparator",
                        as: LabValueComparator.self
                    ),
                    canonicalDecimalString:
                        try fields.string(
                            "canonicalDecimalString"
                        ),
                    unitOriginal:
                        try fields.string("unitOriginal"),
                    referenceRangeOriginal:
                        try fields.optionalString(
                            "referenceRangeOriginal"
                        ),
                    assayOrVariantOriginal:
                        try fields.optionalString(
                            "assayOrVariantOriginal"
                        )
                )
            )
        case "StatusObservationCorrectionSnapshotRecord":
            context.insert(
                StatusObservationCorrectionSnapshotRecord(
                    id: record.recordID,
                    eventID: try fields.uuid("eventID"),
                    parentID: try fields.uuid("parentID"),
                    metricDefinitionID:
                        try fields.uuid("metricDefinitionID"),
                    metricNameSnapshot:
                        try fields.string("metricNameSnapshot"),
                    ordinalLevel:
                        try fields.int("ordinalLevel"),
                    note: try fields.string("note"),
                    timestamp: try fields.historicalTimestamp(
                        instant: "instant",
                        localDate: "localDate",
                        hour: "localHour",
                        minute: "localMinute",
                        second: "localSecond",
                        nanosecond: "localNanosecond",
                        timeZone: "timeZone",
                        utcOffset: "utcOffset",
                        precision: "precision",
                        provenance: "provenance"
                    ),
                    resolvedRegimenVersionID:
                        try fields.optionalUUID(
                            "resolvedRegimenVersionID"
                        ),
                    associationState: try fields.enumeration(
                        "associationState",
                        as: HistoricalAssociationState.self
                    ),
                    createdAt: try fields.date("createdAt")
                )
            )
        case "ParentRecordDeletionTombstoneRecord":
            let parentType: ParentRecordType =
                try fields.enumeration(
                    "parentType",
                    as: ParentRecordType.self
                )
            let parentID = try fields.uuid("parentID")
            guard try fields.string("parentKey")
                    == parentType.recordKey(parentID: parentID)
            else {
                throw PortableV12RecordAdapterError
                    .invalidIdentity(record.recordKey)
            }
            context.insert(
                ParentRecordDeletionTombstoneRecord(
                    id: record.recordID,
                    eventID: try fields.uuid("eventID"),
                    parentType: parentType,
                    parentID: parentID,
                    priorFactsDigest:
                        try fields.string("priorFactsDigest"),
                    impactDigest:
                        try fields.string("impactDigest"),
                    attachmentManifest:
                        try fields.string("attachmentManifest"),
                    attachmentCount: try fields.int(
                        "attachmentCount",
                        range: 0...Int.max
                    ),
                    attachmentByteCount: try fields.int64(
                        "attachmentByteCount",
                        range: 0...Int64.max
                    ),
                    deletedAt: try fields.date("deletedAt")
                )
            )
        case "ParentRecordLifecycleBackfillState":
            let taskKey = try fields.string("taskKey")
            try requireStableIdentity(record, key: taskKey)
            context.insert(
                ParentRecordLifecycleBackfillState(
                    taskKey: taskKey,
                    sourceSchemaVersion:
                        try fields.string(
                            "sourceSchemaVersion"
                        ),
                    labParentCount: try fields.int(
                        "labParentCount",
                        range: 0...Int.max
                    ),
                    statusParentCount: try fields.int(
                        "statusParentCount",
                        range: 0...Int.max
                    ),
                    rootSetDigest:
                        try fields.string("rootSetDigest"),
                    completedAt:
                        try fields.optionalDate("completedAt"),
                    updatedAt: try fields.date("updatedAt")
                )
            )
        case "PrivacyControlRecord":
            let singletonKey =
                try fields.string("singletonKey")
            guard singletonKey == PrivacyControlRecord.fixedKey else {
                throw PortableV12RecordAdapterError
                    .invalidIdentity(record.recordKey)
            }
            try requireIdentity(
                record,
                equals: PrivacyControlRecord.stableID
            )
            context.insert(
                PrivacyControlRecord(
                    singletonKey: singletonKey,
                    contractVersion: try fields.int(
                        "contractVersion",
                        range: 1...Int.max
                    ),
                    appLockEnabled:
                        try fields.bool("appLockEnabled"),
                    lastOperationID:
                        try fields.optionalUUID(
                            "lastOperationID"
                        ),
                    createdAt: try fields.date("createdAt"),
                    updatedAt: try fields.date("updatedAt")
                )
            )
        case "PrivacyControlBackfillState":
            let taskKey = try fields.string("taskKey")
            guard taskKey
                    == PrivacyControlBackfillState.fixedKey else {
                throw PortableV12RecordAdapterError
                    .invalidIdentity(record.recordKey)
            }
            try requireIdentity(
                record,
                equals: PrivacyControlBackfillState.stableID
            )
            context.insert(
                PrivacyControlBackfillState(
                    taskKey: taskKey,
                    source: try fields.enumeration(
                        "source",
                        as: PrivacyControlBackfillSource.self
                    ),
                    initialPrivacyDigest:
                        try fields.string(
                            "initialPrivacyDigest"
                        ),
                    completedAt:
                        try fields.optionalDate("completedAt"),
                    updatedAt: try fields.date("updatedAt")
                )
            )
        case "DataControlDeletionTombstoneRecord":
            try insertDataControlTombstone(
                record,
                fields: fields,
                into: context
            )
        case "DataControlBackfillState":
            let taskKey = try fields.string("taskKey")
            guard taskKey == DataControlBackfillState.fixedKey else {
                throw PortableV12RecordAdapterError
                    .invalidIdentity(record.recordKey)
            }
            try requireIdentity(
                record,
                equals: DataControlBackfillState.stableID
            )
            context.insert(
                DataControlBackfillState(
                    taskKey: taskKey,
                    source: try fields.enumeration(
                        "source",
                        as: DataControlBackfillSource.self
                    ),
                    initialTombstoneCount: try fields.int(
                        "initialTombstoneCount",
                        range: 0...Int.max
                    ),
                    initialTombstoneSetDigest:
                        try fields.string(
                            "initialTombstoneSetDigest"
                        ),
                    completedAt:
                        try fields.optionalDate("completedAt"),
                    updatedAt: try fields.date("updatedAt")
                )
            )
        default:
            throw PortableV12RecordAdapterError
                .unsupportedRecordType(record.modelType)
        }
    }

    static func insertCountdownCommandAudit(
        _ record: PortableDataRecord,
        fields: PortableV12FieldReader,
        operationID: UUID,
        into context: ModelContext
    ) throws {
        let eventID = try fields.uuid("eventID")
        try requireIdentity(record, equals: eventID)
        guard try fields.string("auditSource")
                == CountdownCommandAuditSource.nativeV7.rawValue,
              try fields.string("commandDigestVersion")
                == CountdownIntegrityDigest.commandVersion else {
            throw PortableV12RecordAdapterError
                .invalidEnum("auditSource")
        }
        let reminderParts = try (
            fields.optionalBool("reminderIsEnabled"),
            fields.optionalInt("reminderLeadDays"),
            fields.optionalInt(
                "reminderLocalHour",
                range: 0...23
            ),
            fields.optionalInt(
                "reminderLocalMinute",
                range: 0...59
            )
        )
        let reminder: CountdownReminderInput?
        if reminderParts.0 == nil,
           reminderParts.1 == nil,
           reminderParts.2 == nil,
           reminderParts.3 == nil {
            reminder = nil
        } else if let enabled = reminderParts.0,
                  let leadDays = reminderParts.1,
                  let hour = reminderParts.2,
                  let minute = reminderParts.3,
                  leadDays >= 0 {
            reminder = CountdownReminderInput(
                isEnabled: enabled,
                leadDays: leadDays,
                localHour: hour,
                localMinute: minute
            )
        } else {
            throw PortableV12RecordAdapterError
                .invalidRange("reminder")
        }
        let value = CountdownCommandAuditRecord(
            eventID: eventID,
            operationID: operationID,
            countdownID: try fields.uuid("countdownID"),
            commandKind: try fields.enumeration(
                "commandKind",
                as: CountdownCommandAuditKind.self
            ),
            expectedLatestEventID:
                try fields.optionalUUID("expectedLatestEventID"),
            titleCommitment:
                try fields.optionalString("titleCommitment"),
            gentleTitleCommitment:
                try fields.optionalString(
                    "gentleTitleCommitment"
                ),
            targetDate:
                try fields.optionalCivilDate("target"),
            showInToday:
                try fields.optionalBool("showInToday"),
            reminder: reminder,
            today: try fields.optionalCivilDate("today"),
            reviewResolution:
                try fields.optionalEnumeration(
                    "reviewResolution",
                    as: CountdownReviewResolution.self
                ),
            replacementCountdownID:
                try fields.optionalUUID(
                    "replacementCountdownID"
                ),
            replacementEventID:
                try fields.optionalUUID("replacementEventID"),
            primaryCommandDigest:
                try fields.optionalString(
                    "primaryCommandDigest"
                ),
            eventTimestampCommitment:
                try fields.string(
                    "eventTimestampCommitment"
                ),
            eventSemanticDigest:
                try fields.string("eventSemanticDigest"),
            preFactsDigest:
                try fields.string("preFactsDigest"),
            postFactsDigest:
                try fields.string("postFactsDigest"),
            previousAuditDigest:
                try fields.optionalString(
                    "previousAuditDigest"
                ),
            terminalReminderWasEnabled:
                try fields.optionalBool(
                    "terminalReminderWasEnabled"
                ),
            terminalReminderLeadDays:
                try fields.optionalInt(
                    "terminalReminderLeadDays"
                ),
            terminalReminderLocalHour:
                try fields.optionalInt(
                    "terminalReminderLocalHour",
                    range: 0...23
                ),
            terminalReminderLocalMinute:
                try fields.optionalInt(
                    "terminalReminderLocalMinute",
                    range: 0...59
                ),
            committedAt: try fields.date("committedAt")
        )
        try value.seal()
        guard value.commandDigest
                == (try fields.string("commandDigest")),
              value.auditDigest
                == (try fields.string("auditDigest")) else {
            throw PortableV12RecordAdapterError
                .invalidField("auditDigest")
        }
        context.insert(value)
    }

    static func insertParentLifecycleHead(
        _ record: PortableDataRecord,
        fields: PortableV12FieldReader,
        into context: ModelContext
    ) throws {
        let parentType: ParentRecordType =
            try fields.enumeration(
                "parentType",
                as: ParentRecordType.self
            )
        let parentID = try fields.uuid("parentID")
        let parentKey = try fields.string("parentKey")
        guard parentKey
                == parentType.recordKey(parentID: parentID) else {
            throw PortableV12RecordAdapterError
                .invalidIdentity(record.recordKey)
        }
        try requireIdentity(
            record,
            equals:
                ParentRecordLifecycleBackfill
                .stableHeadID(for: parentKey)
        )
        context.insert(
            ParentRecordLifecycleHeadRecord(
                parentType: parentType,
                parentID: parentID,
                latestEventID:
                    try fields.uuid("latestEventID"),
                latestPayloadID:
                    try fields.optionalUUID("latestPayloadID"),
                eventCount: try fields.int(
                    "eventCount",
                    range: 1...Int.max
                ),
                lifecycle: try fields.enumeration(
                    "lifecycle",
                    as: ParentRecordLifecycle.self
                ),
                effectiveTimestamp:
                    try fields.historicalTimestamp(
                        instant: "effectiveInstant",
                        localDate: "effectiveLocalDate",
                        hour: "effectiveLocalHour",
                        minute: "effectiveLocalMinute",
                        second: "effectiveLocalSecond",
                        nanosecond:
                            "effectiveLocalNanosecond",
                        timeZone: "effectiveTimeZone",
                        utcOffset: "effectiveUTCOffset",
                        precision: "effectivePrecision",
                        provenance: "effectiveProvenance"
                    ),
                updatedAt: try fields.date("updatedAt")
            )
        )
    }

    static func insertDataControlTombstone(
        _ record: PortableDataRecord,
        fields: PortableV12FieldReader,
        into context: ModelContext
    ) throws {
        let id = try fields.uuid("id")
        try requireIdentity(record, equals: id)
        let targetKind: DataControlTargetKind =
            try fields.enumeration(
                "targetKindRawValue",
                as: DataControlTargetKind.self
            )
        let stableKey = try fields.string("targetStableKey")
        let targetID = try fields.optionalUUID("targetID")
        let targetKey = try fields.string("targetKey")
        guard targetKind.validates(
            stableKey: stableKey,
            targetID: targetID
        ),
        targetKey == targetKind.targetKey(stableKey: stableKey)
        else {
            throw PortableV12RecordAdapterError
                .invalidIdentity(record.recordKey)
        }
        context.insert(
            DataControlDeletionTombstoneRecord(
                targetKey: targetKey,
                id: id,
                operationID:
                    try fields.uuid("operationID"),
                targetKind: targetKind,
                targetStableKey: stableKey,
                targetID: targetID,
                sourceGenerationID:
                    try fields.uuid("sourceGenerationID"),
                sourceDatasetID:
                    try fields.uuid("sourceDatasetID"),
                sourceNextLocalRevision:
                    try fields.int64(
                        "sourceNextLocalRevision",
                        range: 1...Int64.max
                    ),
                expectedRecordKey:
                    try fields.string("expectedRecordKey"),
                expectedLocalRevision:
                    try fields.int64(
                        "expectedLocalRevision",
                        range: 1...Int64.max
                    ),
                expectedDigestHex:
                    try fields.string("expectedDigestHex"),
                targetSnapshotManifest:
                    try fields.string(
                        "targetSnapshotManifest"
                    ),
                impactDigest:
                    try fields.string("impactDigest"),
                attachmentManifest:
                    try fields.string("attachmentManifest"),
                notificationManifest:
                    try fields.string(
                        "notificationManifest"
                    ),
                retainedRecordCount: try fields.int(
                    "retainedRecordCount",
                    range: 0...Int.max
                ),
                deletedAttachmentCount: try fields.int(
                    "deletedAttachmentCount",
                    range: 0...Int.max
                ),
                deletedAttachmentBytes: try fields.int64(
                    "deletedAttachmentBytes",
                    range: 0...Int64.max
                ),
                affectedReminderCount: try fields.int(
                    "affectedReminderCount",
                    range: 0...Int.max
                ),
                timestamp: try fields.historicalTimestamp(
                    instant: "committedAt",
                    year: "localYear",
                    month: "localMonth",
                    day: "localDay",
                    hour: "localHour",
                    minute: "localMinute",
                    second: "localSecond",
                    nanosecond: "localNanosecond",
                    timeZone: "timeZoneIdentifier",
                    utcOffset: "utcOffsetSeconds",
                    precision: "precisionRawValue",
                    provenance: "provenanceRawValue"
                ),
                commandDigest:
                    try fields.string("commandDigest")
            )
        )
    }
}

private extension PortableV12RecordAdapter {
    static func insertControl(
        _ control: PortableDataControl,
        payload: PortableDataV2Payload,
        deviceObservationDate: Date,
        into context: ModelContext
    ) throws {
        try PortableDataV2ControlSchema.validate(control)
        let fields = try PortableV12FieldReader(control.fields)
        switch control.modelType {
        case "DatasetMetadata":
            let key = try fields.string("singletonKey")
            guard key == DatasetMetadata.fixedKey,
                  control.stableIdentity == key,
                  try fields.uuid("datasetID")
                    == payload.datasetID,
                  try fields.int64(
                      "nextLocalRevision",
                      range: 1...Int64.max
                  ) == payload.nextLocalRevision,
                  try fields.int(
                      "digestVersion",
                      range: 1...Int.max
                  ) == RecordDigestV1.version else {
                throw PortableV12RecordAdapterError
                    .invalidIdentity(control.stableIdentity)
            }
            context.insert(
                DatasetMetadata(
                    singletonKey: key,
                    datasetID: payload.datasetID,
                    nextLocalRevision:
                        payload.nextLocalRevision,
                    digestVersion: RecordDigestV1.version,
                    createdAt:
                        try fields.date("createdAt"),
                    lastCommittedAt:
                        try fields.optionalDate(
                            "lastCommittedAt"
                        )
                )
            )
        case "MigrationBackfillState":
            context.insert(
                MigrationBackfillState(
                    taskKey: try exactFixedKey(
                        fields.string("taskKey"),
                        expected:
                            MigrationBackfillState.fixedKey
                    ),
                    phase: try fields.enumeration(
                        "phaseRawValue",
                        as: MigrationBackfillPhase.self
                    ),
                    processedCountInPhase: try fields.int(
                        "processedCountInPhase",
                        range: 0...Int.max
                    ),
                    updatedAt: try fields.date("updatedAt"),
                    completedAt:
                        try fields.optionalDate("completedAt")
                )
            )
        case "MigrationIssue":
            context.insert(
                MigrationIssue(
                    issueKey: try fields.string("issueKey"),
                    kind: try fields.enumeration(
                        "kindRawValue",
                        as: MigrationIssueKind.self
                    ),
                    recordType:
                        try fields.string("recordType"),
                    recordID:
                        try fields.optionalUUID("recordID"),
                    detectedAt: try fields.date("detectedAt")
                )
            )
        case "CoreTimeRegimenBackfillState":
            let zone = try fields.string(
                "assumedTimeZoneIdentifier"
            )
            guard TimeZone(identifier: zone) != nil else {
                throw PortableV12RecordAdapterError
                    .invalidField(
                        "assumedTimeZoneIdentifier"
                    )
            }
            context.insert(
                CoreTimeRegimenBackfillState(
                    taskKey: try exactFixedKey(
                        fields.string("taskKey"),
                        expected:
                            CoreTimeRegimenBackfillState
                            .fixedKey
                    ),
                    assumedTimeZoneIdentifier: zone,
                    completedAt:
                        try fields.optionalDate("completedAt"),
                    updatedAt: try fields.date("updatedAt")
                )
            )
        case "TodayExecutionBackfillState":
            context.insert(
                TodayExecutionBackfillState(
                    taskKey: try exactFixedKey(
                        fields.string("taskKey"),
                        expected:
                            TodayExecutionBackfillState
                            .fixedKey
                    ),
                    completedAt:
                        try fields.optionalDate("completedAt"),
                    updatedAt: try fields.date("updatedAt")
                )
            )
        case "PersonalTimelineBackfillState":
            context.insert(
                PersonalTimelineBackfillState(
                    taskKey: try exactFixedKey(
                        fields.string("taskKey"),
                        expected:
                            PersonalTimelineBackfillState
                            .fixedKey
                    ),
                    completedAt:
                        try fields.optionalDate("completedAt"),
                    updatedAt: try fields.date("updatedAt")
                )
            )
        case "CountdownLifecycleBackfillState":
            let zone = try fields.string(
                "assumedTimeZoneIdentifier"
            )
            guard TimeZone(identifier: zone) != nil else {
                throw PortableV12RecordAdapterError
                    .invalidField(
                        "assumedTimeZoneIdentifier"
                    )
            }
            context.insert(
                CountdownLifecycleBackfillState(
                    taskKey: try exactFixedKey(
                        fields.string("taskKey"),
                        expected:
                            CountdownLifecycleBackfillState
                            .fixedKey
                    ),
                    assumedTimeZoneIdentifier: zone,
                    completedAt:
                        try fields.optionalDate("completedAt"),
                    updatedAt: try fields.date("updatedAt")
                )
            )
        case "NotificationCoverageRecord":
            try validateSourceNotificationCoverage(fields)
            context.insert(
                NotificationCoverageRecord(
                    coverageKey: try exactFixedKey(
                        fields.string("coverageKey"),
                        expected:
                            NotificationCoverageRecord.fixedKey
                    ),
                    status: .staleObservation,
                    scheduledThrough: nil,
                    desiredCount: 0,
                    confirmedPendingCount: 0,
                    lastErrorCode: nil,
                    observedAt: deviceObservationDate
                )
            )
        case "CountdownNotificationCoverageRecord":
            try validateSourceCountdownCoverage(fields)
            context.insert(
                CountdownNotificationCoverageRecord(
                    coverageKey: try exactFixedKey(
                        fields.string("coverageKey"),
                        expected:
                            CountdownNotificationCoverageRecord
                            .fixedKey
                    ),
                    countdownID:
                        try fields.optionalUUID("countdownID"),
                    status: .staleObservation,
                    scheduledFireAt: nil,
                    desiredCount: 0,
                    confirmedPendingCount: 0,
                    lastErrorCode: nil,
                    observedAt: deviceObservationDate
                )
            )
        default:
            throw PortableV12RecordAdapterError
                .unsupportedControlType(control.modelType)
        }
    }

    static func exactFixedKey(
        _ value: String,
        expected: String
    ) throws -> String {
        guard value == expected else {
            throw PortableV12RecordAdapterError
                .invalidIdentity(value)
        }
        return value
    }

    static func validateSourceNotificationCoverage(
        _ fields: PortableV12FieldReader
    ) throws {
        let status: NotificationCoverageStatus =
            try fields.enumeration(
                "statusRawValue",
                as: NotificationCoverageStatus.self
            )
        let desired = try fields.int(
            "desiredCount",
            range: 0...Int.max
        )
        let confirmed = try fields.int(
            "confirmedPendingCount",
            range: 0...Int.max
        )
        let scheduled = try fields.optionalDate(
            "scheduledThrough"
        )
        let error = try fields.optionalString("lastErrorCode")
        _ = try fields.date("observedAt")
        guard confirmed <= desired else {
            throw PortableV12RecordAdapterError
                .invalidRange("confirmedPendingCount")
        }
        let consistent: Bool = switch status {
        case .disabledByUser, .notDetermined,
             .blockedByPermission, .limitedBySystemSettings,
             .reconciliationPending, .staleObservation:
            desired == 0 && confirmed == 0
                && scheduled == nil && error == nil
        case .scheduledForWindow:
            confirmed == desired && error == nil
                && (desired == 0 || scheduled != nil)
        case .limitedByBudget:
            confirmed == desired && scheduled != nil
                && error == nil
        case .schedulingFailed:
            scheduled == nil && error?.isEmpty == false
        }
        guard consistent else {
            throw PortableV12RecordAdapterError
                .invalidField("statusRawValue")
        }
    }

    static func validateSourceCountdownCoverage(
        _ fields: PortableV12FieldReader
    ) throws {
        let status: NotificationCoverageStatus =
            try fields.enumeration(
                "statusRawValue",
                as: NotificationCoverageStatus.self
            )
        let scheduled =
            try fields.optionalDate("scheduledFireAt")
        let desired = try fields.int(
            "desiredCount",
            range: 0...Int.max
        )
        let confirmed = try fields.int(
            "confirmedPendingCount",
            range: 0...Int.max
        )
        let error = try fields.optionalString("lastErrorCode")
        _ = try fields.date("observedAt")
        guard CountdownNotificationCoverageRecord.isConsistent(
            status: status,
            scheduledFireAt: scheduled,
            desiredCount: desired,
            confirmedPendingCount: confirmed,
            lastErrorCode: error
        ) else {
            throw PortableV12RecordAdapterError
                .invalidField("statusRawValue")
        }
    }
}

private struct PortableV12FieldReader {
    private let values: [String: RecordDigestV1.Value]

    init(_ fields: [PortableDataField]) throws {
        var result: [String: RecordDigestV1.Value] = [:]
        for field in fields {
            guard result.updateValue(
                try field.value.recordDigestValue(),
                forKey: field.name
            ) == nil else {
                throw PortableV12RecordAdapterError
                    .invalidField(field.name)
            }
        }
        values = result
    }

    func string(_ name: String) throws -> String {
        guard case let .string(value)? = values[name] else {
            throw PortableV12RecordAdapterError.invalidField(name)
        }
        return value
    }

    func optionalString(_ name: String) throws -> String? {
        guard let value = values[name] else {
            throw PortableV12RecordAdapterError.invalidField(name)
        }
        switch value {
        case .null:
            return nil
        case let .string(value):
            return value
        default:
            throw PortableV12RecordAdapterError.invalidField(name)
        }
    }

    func bool(_ name: String) throws -> Bool {
        guard case let .bool(value)? = values[name] else {
            throw PortableV12RecordAdapterError.invalidField(name)
        }
        return value
    }

    func optionalBool(_ name: String) throws -> Bool? {
        guard let value = values[name] else {
            throw PortableV12RecordAdapterError.invalidField(name)
        }
        switch value {
        case .null:
            return nil
        case let .bool(value):
            return value
        default:
            throw PortableV12RecordAdapterError.invalidField(name)
        }
    }

    func int64(
        _ name: String,
        range: ClosedRange<Int64> =
            Int64.min...Int64.max
    ) throws -> Int64 {
        guard case let .integer(value)? = values[name],
              range.contains(value) else {
            throw PortableV12RecordAdapterError.invalidRange(name)
        }
        return value
    }

    func optionalInt64(
        _ name: String,
        range: ClosedRange<Int64> =
            Int64.min...Int64.max
    ) throws -> Int64? {
        guard let value = values[name] else {
            throw PortableV12RecordAdapterError.invalidField(name)
        }
        switch value {
        case .null:
            return nil
        case let .integer(value):
            guard range.contains(value) else {
                throw PortableV12RecordAdapterError
                    .invalidRange(name)
            }
            return value
        default:
            throw PortableV12RecordAdapterError.invalidField(name)
        }
    }

    func int(
        _ name: String,
        range: ClosedRange<Int> = Int.min...Int.max
    ) throws -> Int {
        let value = try int64(name)
        guard let narrowed = Int(exactly: value),
              range.contains(narrowed) else {
            throw PortableV12RecordAdapterError.invalidRange(name)
        }
        return narrowed
    }

    func optionalInt(
        _ name: String,
        range: ClosedRange<Int> = Int.min...Int.max
    ) throws -> Int? {
        guard let value = try optionalInt64(name) else {
            return nil
        }
        guard let narrowed = Int(exactly: value),
              range.contains(narrowed) else {
            throw PortableV12RecordAdapterError.invalidRange(name)
        }
        return narrowed
    }

    func double(_ name: String) throws -> Double {
        guard case let .double(value)? = values[name],
              value.isFinite else {
            throw PortableV12RecordAdapterError.invalidField(name)
        }
        return value
    }

    func uuid(_ name: String) throws -> UUID {
        guard case let .uuid(value)? = values[name] else {
            throw PortableV12RecordAdapterError.invalidField(name)
        }
        return value
    }

    func optionalUUID(_ name: String) throws -> UUID? {
        guard let value = values[name] else {
            throw PortableV12RecordAdapterError.invalidField(name)
        }
        switch value {
        case .null:
            return nil
        case let .uuid(value):
            return value
        default:
            throw PortableV12RecordAdapterError.invalidField(name)
        }
    }

    func date(_ name: String) throws -> Date {
        guard case let .timestampMicroseconds(value)? =
                values[name] else {
            throw PortableV12RecordAdapterError.invalidField(name)
        }
        return try PortableV12RecordAdapter.date(
            microseconds: value,
            field: name
        )
    }

    func optionalDate(_ name: String) throws -> Date? {
        guard let value = values[name] else {
            throw PortableV12RecordAdapterError.invalidField(name)
        }
        switch value {
        case .null:
            return nil
        case let .timestampMicroseconds(value):
            return try PortableV12RecordAdapter.date(
                microseconds: value,
                field: name
            )
        default:
            throw PortableV12RecordAdapterError.invalidField(name)
        }
    }

    func enumeration<T>(
        _ name: String,
        as type: T.Type
    ) throws -> T where T: RawRepresentable, T.RawValue == String {
        let rawValue = try string(name)
        guard let result = T(rawValue: rawValue) else {
            throw PortableV12RecordAdapterError.invalidEnum(name)
        }
        return result
    }

    func optionalEnumeration<T>(
        _ name: String,
        as type: T.Type
    ) throws -> T? where T: RawRepresentable, T.RawValue == String {
        guard let rawValue = try optionalString(name) else {
            return nil
        }
        guard let result = T(rawValue: rawValue) else {
            throw PortableV12RecordAdapterError.invalidEnum(name)
        }
        return result
    }

    func civilDate(
        year: String,
        month: String,
        day: String
    ) throws -> CivilDateFact {
        do {
            return try CivilDateFact(
                year: int(year),
                month: int(month),
                day: int(day)
            )
        } catch {
            throw PortableV12RecordAdapterError
                .invalidRange(year)
        }
    }

    func optionalCivilDate(
        year: String,
        month: String,
        day: String
    ) throws -> CivilDateFact? {
        let values = try [
            optionalInt(year),
            optionalInt(month),
            optionalInt(day)
        ]
        if values.allSatisfy({ $0 == nil }) {
            return nil
        }
        guard let year = values[0],
              let month = values[1],
              let day = values[2] else {
            throw PortableV12RecordAdapterError
                .invalidRange("civilDate")
        }
        do {
            return try CivilDateFact(
                year: year,
                month: month,
                day: day
            )
        } catch {
            throw PortableV12RecordAdapterError
                .invalidRange("civilDate")
        }
    }

    func civilDate(_ name: String) throws -> CivilDateFact {
        let original = try string(name)
        let components = original.split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]),
              String(format: "%04d-%02d-%02d", year, month, day)
                == original else {
            throw PortableV12RecordAdapterError.invalidRange(name)
        }
        do {
            return try CivilDateFact(
                year: year,
                month: month,
                day: day
            )
        } catch {
            throw PortableV12RecordAdapterError.invalidRange(name)
        }
    }

    func optionalCivilDate(_ name: String) throws -> CivilDateFact? {
        guard let value = try optionalString(name) else {
            return nil
        }
        let components = value.split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]),
              String(format: "%04d-%02d-%02d", year, month, day)
                == value else {
            throw PortableV12RecordAdapterError.invalidRange(name)
        }
        do {
            return try CivilDateFact(
                year: year,
                month: month,
                day: day
            )
        } catch {
            throw PortableV12RecordAdapterError.invalidRange(name)
        }
    }

    func historicalTimestamp(
        instant: String,
        year: String,
        month: String,
        day: String,
        hour: String,
        minute: String,
        second: String,
        nanosecond: String,
        timeZone: String,
        utcOffset: String,
        precision: String,
        provenance: String
    ) throws -> HistoricalTimestamp {
        let date = try self.date(instant)
        do {
            return try HistoricalTimestamp(
                validatingInstant: date,
                localDate: try civilDate(
                    year: year,
                    month: month,
                    day: day
                ),
                localTime: try HistoricalLocalTime(
                    hour: int(hour),
                    minute: int(minute),
                    second: int(second),
                    nanosecond: int(nanosecond)
                ),
                timeZoneIdentifier: try string(timeZone),
                utcOffsetSeconds: try int(utcOffset),
                precision: try enumeration(
                    precision,
                    as: HistoricalTimestampPrecision.self
                ),
                provenance: try enumeration(
                    provenance,
                    as: HistoricalTimestampProvenance.self
                )
            )
        } catch let error as PortableV12RecordAdapterError {
            throw error
        } catch {
            throw PortableV12RecordAdapterError
                .invalidRange(instant)
        }
    }

    func historicalTimestamp(
        instant: String,
        localDate: String,
        hour: String,
        minute: String,
        second: String,
        nanosecond: String,
        timeZone: String,
        utcOffset: String,
        precision: String,
        provenance: String
    ) throws -> HistoricalTimestamp {
        let date = try self.date(instant)
        do {
            return try HistoricalTimestamp(
                validatingInstant: date,
                localDate: try civilDate(localDate),
                localTime: try HistoricalLocalTime(
                    hour: int(hour),
                    minute: int(minute),
                    second: int(second),
                    nanosecond: int(nanosecond)
                ),
                timeZoneIdentifier: try string(timeZone),
                utcOffsetSeconds: try int(utcOffset),
                precision: try enumeration(
                    precision,
                    as: HistoricalTimestampPrecision.self
                ),
                provenance: try enumeration(
                    provenance,
                    as: HistoricalTimestampProvenance.self
                )
            )
        } catch let error as PortableV12RecordAdapterError {
            throw error
        } catch {
            throw PortableV12RecordAdapterError
                .invalidRange(instant)
        }
    }
}
