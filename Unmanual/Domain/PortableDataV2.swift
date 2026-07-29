import CryptoKit
import Foundation

struct PortableDataModelCount: Codable, Equatable, Sendable {
    let modelType: String
    let rowCount: Int64
}

enum PortableDataControlDisposition: String, Codable, Sendable {
    case embeddedInEnvelope
    case embeddedInRecordHeaders
    case rebuildOnRestore
    case deviceObservationOnly
}

struct PortableDataControl: Codable, Equatable, Sendable {
    let modelType: String
    let stableIdentity: String
    let disposition: PortableDataControlDisposition
    let fields: [PortableDataField]
}

struct PortableDataField: Codable, Equatable, Sendable {
    let name: String
    let value: PortableDataValue
}

struct PortableDataValue: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case null
        case bool
        case integer
        case double
        case string
        case uuid
        case timestampMicroseconds
    }

    let kind: Kind
    let boolValue: Bool?
    let integerValue: Int64?
    let doubleBitPatternHex: String?
    let stringValue: String?
    let uuidValue: UUID?

    init(_ value: RecordDigestV1.Value) {
        switch value {
        case .null:
            self.init(kind: .null)
        case let .bool(value):
            self.init(kind: .bool, boolValue: value)
        case let .integer(value):
            self.init(kind: .integer, integerValue: value)
        case let .double(value):
            self.init(
                kind: .double,
                doubleBitPatternHex: String(
                    format: "%016llx",
                    value.bitPattern
                )
            )
        case let .string(value):
            self.init(kind: .string, stringValue: value)
        case let .uuid(value):
            self.init(kind: .uuid, uuidValue: value)
        case let .timestampMicroseconds(value):
            self.init(
                kind: .timestampMicroseconds,
                integerValue: value
            )
        }
    }

    init(
        kind: Kind,
        boolValue: Bool? = nil,
        integerValue: Int64? = nil,
        doubleBitPatternHex: String? = nil,
        stringValue: String? = nil,
        uuidValue: UUID? = nil
    ) {
        self.kind = kind
        self.boolValue = boolValue
        self.integerValue = integerValue
        self.doubleBitPatternHex = doubleBitPatternHex
        self.stringValue = stringValue
        self.uuidValue = uuidValue
    }

    func recordDigestValue() throws -> RecordDigestV1.Value {
        let populated = [
            boolValue != nil,
            integerValue != nil,
            doubleBitPatternHex != nil,
            stringValue != nil,
            uuidValue != nil
        ].filter { $0 }.count
        switch kind {
        case .null:
            guard populated == 0 else {
                throw PortableDataV2Error.invalidValue
            }
            return .null
        case .bool:
            guard populated == 1, let boolValue else {
                throw PortableDataV2Error.invalidValue
            }
            return .bool(boolValue)
        case .integer:
            guard populated == 1, let integerValue else {
                throw PortableDataV2Error.invalidValue
            }
            return .integer(integerValue)
        case .double:
            guard populated == 1,
                  let doubleBitPatternHex,
                  doubleBitPatternHex.count == 16,
                  let bits = UInt64(
                      doubleBitPatternHex,
                      radix: 16
                  ) else {
                throw PortableDataV2Error.invalidValue
            }
            let value = Double(bitPattern: bits)
            guard value.isFinite else {
                throw PortableDataV2Error.invalidValue
            }
            return .double(value)
        case .string:
            guard populated == 1,
                  let stringValue,
                  stringValue.lengthOfBytes(using: .utf8)
                    <= PortableDataV2Limits.maximumStringBytes else {
                throw PortableDataV2Error.invalidValue
            }
            return .string(stringValue)
        case .uuid:
            guard populated == 1, let uuidValue else {
                throw PortableDataV2Error.invalidValue
            }
            return .uuid(uuidValue)
        case .timestampMicroseconds:
            guard populated == 1, let integerValue else {
                throw PortableDataV2Error.invalidValue
            }
            return .timestampMicroseconds(integerValue)
        }
    }
}

struct PortableDataRecord: Codable, Equatable, Sendable {
    let modelType: String
    let recordType: String
    let recordID: UUID
    let recordKey: String
    let datasetID: UUID
    let localRevision: Int64
    let committedAtMicroseconds: Int64
    let digestVersion: Int
    let digestHex: String
    let fields: [PortableDataField]
}

struct PortableDataRecordFieldContract: Equatable, Sendable {
    let name: String
    let kind: PortableDataValue.Kind
    let allowsNull: Bool

    init(
        _ name: String,
        _ kind: PortableDataValue.Kind,
        allowsNull: Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.allowsNull = allowsNull
    }

    func accepts(_ actualKind: PortableDataValue.Kind) -> Bool {
        actualKind == kind || (allowsNull && actualKind == .null)
    }
}

enum PortableDataV2RecordSchema {
    static let fieldsByModelType:
        [String: [PortableDataRecordFieldContract]] = [
            "AdministrationEventRecord": [
                field("note", .string),
                field("occurrenceKey", .string),
                field("operationID", .uuid),
                field("plannedInstant", .timestampMicroseconds),
                field("regimenItemID", .uuid),
                field("regimenVersionID", .uuid),
                field("scheduleRevision", .integer),
                field("scheduleRuleID", .uuid),
                field("status", .string),
                field("supersedesEventID", .uuid, nullable: true)
            ],
            "AttachmentRecord": [
                field("byteCount", .integer),
                field("createdAt", .timestampMicroseconds),
                field("deleteOperationID", .uuid, nullable: true),
                field(
                    "deletedAt",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field("operationID", .uuid),
                field("originalFilename", .string),
                field("ownerID", .uuid),
                field("ownerType", .string),
                field("relativePath", .string),
                field("sha256Hex", .string),
                field("typeIdentifier", .string)
            ],
            "CountdownCommandAuditRecord": [
                field("commandKind", .string),
                field("committedAt", .timestampMicroseconds),
                field("countdownID", .uuid),
                field("eventID", .uuid),
                field("eventTimestampCommitment", .string),
                field(
                    "expectedLatestEventID",
                    .uuid,
                    nullable: true
                ),
                field(
                    "gentleTitleCommitment",
                    .string,
                    nullable: true
                ),
                field(
                    "primaryCommandDigest",
                    .string,
                    nullable: true
                ),
                field(
                    "reminderIsEnabled",
                    .bool,
                    nullable: true
                ),
                field(
                    "reminderLeadDays",
                    .integer,
                    nullable: true
                ),
                field(
                    "reminderLocalHour",
                    .integer,
                    nullable: true
                ),
                field(
                    "reminderLocalMinute",
                    .integer,
                    nullable: true
                ),
                field(
                    "replacementCountdownID",
                    .uuid,
                    nullable: true
                ),
                field(
                    "replacementEventID",
                    .uuid,
                    nullable: true
                ),
                field(
                    "reviewResolution",
                    .string,
                    nullable: true
                ),
                field("showInToday", .bool, nullable: true),
                field("target", .string, nullable: true),
                field(
                    "titleCommitment",
                    .string,
                    nullable: true
                ),
                field("today", .string, nullable: true),
                field("auditSource", .string),
                field("commandDigest", .string),
                field("commandDigestVersion", .string),
                field("eventSemanticDigest", .string),
                field("postFactsDigest", .string),
                field("preFactsDigest", .string),
                field(
                    "previousAuditDigest",
                    .string,
                    nullable: true
                ),
                field(
                    "terminalReminderLeadDays",
                    .integer,
                    nullable: true
                ),
                field(
                    "terminalReminderLocalHour",
                    .integer,
                    nullable: true
                ),
                field(
                    "terminalReminderLocalMinute",
                    .integer,
                    nullable: true
                ),
                field(
                    "terminalReminderWasEnabled",
                    .bool,
                    nullable: true
                ),
                field("auditDigest", .string)
            ],
            "CountdownIntegrityBackfillState": [
                field("initialAuditCount", .integer),
                field("initialCheckpointCount", .integer),
                field(
                    "completedAt",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field("initialIntegritySetDigest", .string),
                field("sourceSchemaVersion", .string),
                field("taskKey", .string),
                field("updatedAt", .timestampMicroseconds)
            ],
            "CountdownLifecycleEventRecord": [
                field("countdownID", .uuid),
                field("kind", .string),
                field("newTarget", .string, nullable: true),
                field("oldTarget", .string, nullable: true),
                field("operationID", .uuid),
                field("previousEventID", .uuid, nullable: true),
                field(
                    "replacementCountdownID",
                    .uuid,
                    nullable: true
                ),
                field("occurredAt", .timestampMicroseconds),
                field("localDate", .string),
                field("localHour", .integer),
                field("localMinute", .integer),
                field("localSecond", .integer),
                field("localNanosecond", .integer),
                field("timeZoneIdentifier", .string),
                field("utcOffsetSeconds", .integer),
                field("precision", .string),
                field("provenance", .string)
            ],
            "HRTProfile": [
                field(
                    "activePeriodStartDate",
                    .timestampMicroseconds
                ),
                field("createdAt", .timestampMicroseconds),
                field("startDate", .timestampMicroseconds)
            ],
            "CountdownRecord": [
                field(
                    "archivedAt",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field("continuesCountingUp", .bool),
                field("createdAt", .timestampMicroseconds),
                field("gentleTitle", .string, nullable: true),
                field("targetDate", .timestampMicroseconds),
                field("title", .string)
            ],
            "CountdownReminderRuleRecord": [
                field("contentVersion", .string),
                field("countdownID", .uuid),
                field("isEnabled", .bool),
                field("lastOperationID", .uuid),
                field("leadDays", .integer),
                field("localHour", .integer),
                field("localMinute", .integer),
                field("ruleKey", .string),
                field("timeZoneBehavior", .string),
                field("updatedAt", .timestampMicroseconds)
            ],
            "CountdownStateRecord": [
                field(
                    "archivedAt",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field(
                    "completedAt",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field("createdAt", .timestampMicroseconds),
                field(
                    "deletedAt",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field("gentleTitle", .string, nullable: true),
                field("latestEventID", .uuid),
                field("lifecycle", .string),
                field("overdueMode", .string),
                field("requiresReview", .bool),
                field("showInToday", .bool),
                field("target", .string, nullable: true),
                field(
                    "terminalReminderWasEnabled",
                    .bool,
                    nullable: true
                ),
                field(
                    "terminalReminderLeadDays",
                    .integer,
                    nullable: true
                ),
                field(
                    "terminalReminderLocalHour",
                    .integer,
                    nullable: true
                ),
                field(
                    "terminalReminderLocalMinute",
                    .integer,
                    nullable: true
                ),
                field("title", .string),
                field("updatedAt", .timestampMicroseconds)
            ],
            "CountdownV6AuditCheckpointRecord": [
                field("boundaryEventID", .uuid),
                field("createdAt", .timestampMicroseconds),
                field("postFactsDigest", .string),
                field("prefixEventCount", .integer),
                field("prefixChainDigest", .string),
                field("reminderAdmission", .string),
                field("checkpointDigest", .string)
            ],
            "DataControlBackfillState": [
                field(
                    "completedAt",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field("initialTombstoneCount", .integer),
                field("initialTombstoneSetDigest", .string),
                field("source", .string),
                field("taskKey", .string),
                field("updatedAt", .timestampMicroseconds)
            ],
            "DataControlDeletionTombstoneRecord": [
                field("affectedReminderCount", .integer),
                field("attachmentManifest", .string),
                field("commandDigest", .string),
                field("committedAt", .timestampMicroseconds),
                field("deletedAttachmentBytes", .integer),
                field("deletedAttachmentCount", .integer),
                field("expectedDigestHex", .string),
                field("expectedLocalRevision", .integer),
                field("expectedRecordKey", .string),
                field("id", .uuid),
                field("impactDigest", .string),
                field("localDay", .integer),
                field("localHour", .integer),
                field("localMinute", .integer),
                field("localMonth", .integer),
                field("localNanosecond", .integer),
                field("localSecond", .integer),
                field("localYear", .integer),
                field("notificationManifest", .string),
                field("operationID", .uuid),
                field("precisionRawValue", .string),
                field("provenanceRawValue", .string),
                field("retainedRecordCount", .integer),
                field("sourceDatasetID", .uuid),
                field("sourceGenerationID", .uuid),
                field("sourceNextLocalRevision", .integer),
                field("targetID", .uuid, nullable: true),
                field("targetKey", .string),
                field("targetKindRawValue", .string),
                field("targetSnapshotManifest", .string),
                field("targetStableKey", .string),
                field("timeZoneIdentifier", .string),
                field("utcOffsetSeconds", .integer)
            ],
            "HistoricalTimeRecord": [
                field("associationState", .string),
                field("instant", .timestampMicroseconds),
                field(
                    "legacyAssociationID",
                    .uuid,
                    nullable: true
                ),
                field("localDay", .integer),
                field("localHour", .integer),
                field("localMinute", .integer),
                field("localMonth", .integer),
                field("localNanosecond", .integer),
                field("localSecond", .integer),
                field("localYear", .integer),
                field("precision", .string),
                field("provenance", .string),
                field(
                    "resolvedRegimenVersionID",
                    .uuid,
                    nullable: true
                ),
                field("sourceRecordID", .uuid),
                field("sourceRecordType", .string),
                field("timeZoneIdentifier", .string),
                field("utcOffsetSeconds", .integer)
            ],
            "HrtJourneyLifecycleBackfillState": [
                field(
                    "completedAt",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field("initialEventCount", .integer),
                field("initialFactsDigest", .string),
                field("initialPeriodCount", .integer),
                field("sourceSchemaVersion", .string),
                field("updatedAt", .timestampMicroseconds)
            ],
            "HrtJourneyLifecycleEventRecord": [
                field("kind", .string),
                field("localDate", .string),
                field("localHour", .integer),
                field("localMinute", .integer),
                field("localNanosecond", .integer),
                field("localSecond", .integer),
                field("noteSnapshot", .string),
                field("occurredAt", .timestampMicroseconds),
                field("operationID", .uuid),
                field("periodID", .uuid, nullable: true),
                field("precision", .string),
                field("previousEventID", .uuid, nullable: true),
                field("preFactsDigest", .string),
                field("postFactsDigest", .string),
                field("provenance", .string),
                field("source", .string),
                field("timeZoneIdentifier", .string),
                field("transitionDate", .string, nullable: true),
                field("utcOffsetSeconds", .integer)
            ],
            "HrtJourneyProfileRecord": [
                field("firstEverStartDay", .integer),
                field("firstEverStartMonth", .integer),
                field("firstEverStartYear", .integer)
            ],
            "HrtPeriodRecord": [
                field("endDay", .integer, nullable: true),
                field("endMonth", .integer, nullable: true),
                field("endYear", .integer, nullable: true),
                field("note", .string),
                field("startDay", .integer),
                field("startMonth", .integer),
                field("startYear", .integer)
            ],
            "JourneyEntry": [
                field("createdAt", .timestampMicroseconds),
                field("kindRawValue", .string),
                field("occurredAt", .timestampMicroseconds),
                field("regimenVersionID", .uuid, nullable: true),
                field("text", .string)
            ],
            "LabItemDefinitionRecord": [
                field("bundledStableID", .string, nullable: true),
                field("code", .string),
                field("createdAt", .timestampMicroseconds),
                field("displayName", .string),
                field("isArchived", .bool),
                field("kind", .string)
            ],
            "LabRecord": [
                field("contextNote", .string),
                field("createdAt", .timestampMicroseconds),
                field("itemCode", .string),
                field("itemName", .string),
                field("numericValue", .double),
                field("rawValue", .string),
                field(
                    "referenceRangeOriginal",
                    .string,
                    nullable: true
                ),
                field("regimenVersionID", .uuid, nullable: true),
                field("sampledAt", .timestampMicroseconds),
                field("unit", .string)
            ],
            "LabResultCorrectionSnapshotRecord": [
                field(
                    "assayOrVariantOriginal",
                    .string,
                    nullable: true
                ),
                field("canonicalDecimalString", .string),
                field("comparator", .string, nullable: true),
                field("correctionSnapshotID", .uuid),
                field("itemCodeSnapshot", .string),
                field("itemDefinitionID", .uuid),
                field("itemNameSnapshot", .string),
                field("logicalResultID", .uuid),
                field("rawValueOriginal", .string),
                field(
                    "referenceRangeOriginal",
                    .string,
                    nullable: true
                ),
                field("sortOrder", .integer),
                field("unitOriginal", .string)
            ],
            "LabResultRecord": [
                field(
                    "assayOrVariantOriginal",
                    .string,
                    nullable: true
                ),
                field("canonicalDecimalString", .string),
                field("comparator", .string, nullable: true),
                field("createdAt", .timestampMicroseconds),
                field("itemCodeSnapshot", .string),
                field("itemDefinitionID", .uuid),
                field("itemNameSnapshot", .string),
                field("operationID", .uuid),
                field("rawValueOriginal", .string),
                field(
                    "referenceRangeOriginal",
                    .string,
                    nullable: true
                ),
                field("sampleID", .uuid),
                field("sortOrder", .integer),
                field("unitOriginal", .string)
            ],
            "LabSampleCorrectionSnapshotRecord": [
                field("contextNote", .string),
                field("createdAt", .timestampMicroseconds),
                field("eventID", .uuid),
                field("instant", .timestampMicroseconds),
                field("localDate", .string),
                field("localHour", .integer),
                field("localMinute", .integer),
                field("localNanosecond", .integer),
                field("localSecond", .integer),
                field("parentID", .uuid),
                field("precision", .string),
                field("provenance", .string),
                field(
                    "resolvedRegimenVersionID",
                    .uuid,
                    nullable: true
                ),
                field("associationState", .string),
                field("specimenOriginal", .string),
                field("timeZone", .string),
                field("utcOffset", .integer)
            ],
            "LabSampleRecord": [
                field("contextNote", .string),
                field("createdAt", .timestampMicroseconds),
                field("operationID", .uuid),
                field("specimenOriginal", .string)
            ],
            "OnboardingBackfillState": [
                field(
                    "completedAt",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field("source", .string),
                field("taskKey", .string),
                field("updatedAt", .timestampMicroseconds)
            ],
            "OnboardingProgressRecord": [
                field(
                    "completedAt",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field("contractVersion", .integer),
                field("singletonKey", .string),
                field("skippedCountdown", .bool),
                field("skippedReminder", .bool),
                field("skippedStartDate", .bool),
                field("step", .string),
                field("updatedAt", .timestampMicroseconds)
            ],
            "OperationReceiptLedgerRecord": [
                field("ledgerKey", .string),
                field("receiptCount", .integer),
                field("receiptSetDigest", .string)
            ],
            "OperationReceiptRecord": [
                field("commandDigest", .string),
                field("committedAt", .timestampMicroseconds),
                field("operationID", .uuid),
                field("resultRecordID", .uuid),
                field("resultRecordType", .string)
            ],
            "ParentRecordDeletionTombstoneRecord": [
                field("attachmentByteCount", .integer),
                field("attachmentCount", .integer),
                field("deletedAt", .timestampMicroseconds),
                field("eventID", .uuid),
                field("attachmentManifest", .string),
                field("impactDigest", .string),
                field("parentID", .uuid),
                field("parentKey", .string),
                field("parentType", .string),
                field("priorFactsDigest", .string)
            ],
            "ParentRecordLifecycleBackfillState": [
                field(
                    "completedAt",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field("labParentCount", .integer),
                field("rootSetDigest", .string),
                field("sourceSchemaVersion", .string),
                field("statusParentCount", .integer),
                field("taskKey", .string),
                field("updatedAt", .timestampMicroseconds)
            ],
            "ParentRecordLifecycleHeadRecord": [
                field("effectiveInstant", .timestampMicroseconds),
                field("effectiveLocalDate", .string),
                field("effectiveLocalHour", .integer),
                field("effectiveLocalMinute", .integer),
                field("effectiveLocalSecond", .integer),
                field("effectiveLocalNanosecond", .integer),
                field("effectivePrecision", .string),
                field("effectiveProvenance", .string),
                field("effectiveTimeZone", .string),
                field("effectiveUTCOffset", .integer),
                field("eventCount", .integer),
                field("latestEventID", .uuid),
                field("latestPayloadID", .uuid, nullable: true),
                field("lifecycle", .string),
                field("parentID", .uuid),
                field("parentKey", .string),
                field("parentType", .string),
                field("updatedAt", .timestampMicroseconds)
            ],
            "ParentRecordMutationEventRecord": [
                field("commandDigest", .string),
                field("committedAt", .timestampMicroseconds),
                field("kind", .string),
                field("operationID", .uuid),
                field(
                    "expectedHeadEventCount",
                    .integer,
                    nullable: true
                ),
                field(
                    "expectedHeadLocalRevision",
                    .integer,
                    nullable: true
                ),
                field("parentID", .uuid),
                field("parentType", .string),
                field("payloadID", .uuid, nullable: true),
                field(
                    "payloadRecordType",
                    .string,
                    nullable: true
                ),
                field("postFactsDigest", .string),
                field("preFactsDigest", .string),
                field("previousEventID", .uuid, nullable: true)
            ],
            "PrivacyControlBackfillState": [
                field(
                    "completedAt",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field("initialPrivacyDigest", .string),
                field("source", .string),
                field("taskKey", .string),
                field("updatedAt", .timestampMicroseconds)
            ],
            "PrivacyControlRecord": [
                field("appLockEnabled", .bool),
                field("contractVersion", .integer),
                field("createdAt", .timestampMicroseconds),
                field("lastOperationID", .uuid, nullable: true),
                field("singletonKey", .string),
                field("updatedAt", .timestampMicroseconds)
            ],
            "RegimenItemRecord": [
                field("catalogProductID", .string, nullable: true),
                field("catalogVersion", .string, nullable: true),
                field("displayName", .string),
                field("dosageForm", .string),
                field("doseOriginal", .string),
                field("genericName", .string),
                field("productSnapshot", .string),
                field("regimenVersionID", .uuid),
                field("route", .string),
                field("sortOrder", .integer),
                field("unitOriginal", .string)
            ],
            "RegimenPlanVersionRecord": [
                field("changeReason", .string),
                field("code", .string),
                field("editState", .string),
                field(
                    "effectiveEndDay",
                    .integer,
                    nullable: true
                ),
                field(
                    "effectiveEndMonth",
                    .integer,
                    nullable: true
                ),
                field(
                    "effectiveEndYear",
                    .integer,
                    nullable: true
                ),
                field("effectiveStartDay", .integer),
                field("effectiveStartMonth", .integer),
                field("effectiveStartYear", .integer),
                field("isArchived", .bool),
                field("legacySourceID", .uuid, nullable: true),
                field("previousVersionID", .uuid, nullable: true),
                field("requiresMigrationReview", .bool),
                field("title", .string)
            ],
            "RegimenVersion": [
                field("code", .string),
                field("createdAt", .timestampMicroseconds),
                field("endedAt", .timestampMicroseconds, nullable: true),
                field("note", .string),
                field("startedAt", .timestampMicroseconds),
                field("title", .string)
            ],
            "ReminderOverrideRecord": [
                field("fireAt", .timestampMicroseconds),
                field("occurrenceKey", .string),
                field("operationID", .uuid),
                field("plannedInstant", .timestampMicroseconds),
                field("scheduleRevision", .integer),
                field("scheduleRuleID", .uuid),
                field(
                    "supersedesOverrideID",
                    .uuid,
                    nullable: true
                )
            ],
            "ReminderPreferenceRecord": [
                field("contentVersion", .string),
                field("defaultSnoozeMinutes", .integer),
                field("expectedRuleRevision", .integer),
                field("isEnabled", .bool),
                field("lastOperationID", .uuid),
                field("preferenceKey", .string),
                field("scheduleRuleID", .uuid)
            ],
            "ScheduleRuleRecord": [
                field("anchorDay", .integer),
                field("anchorMonth", .integer),
                field("anchorYear", .integer),
                field("defaultSnoozeMinutes", .integer),
                field("endDay", .integer, nullable: true),
                field("endMonth", .integer, nullable: true),
                field("endYear", .integer, nullable: true),
                field(
                    "fixedTimeZoneIdentifier",
                    .string,
                    nullable: true
                ),
                field("intervalDays", .integer, nullable: true),
                field("kind", .string),
                field("localTimes", .string),
                field("regimenItemID", .uuid),
                field("reminderEnabled", .bool),
                field("revision", .integer),
                field("timeZoneBehavior", .string),
                field("weekdays", .string)
            ],
            "StatusMetricDefinitionRecord": [
                field("createdAt", .timestampMicroseconds),
                field("displayName", .string),
                field("isArchived", .bool),
                field("operationID", .uuid),
                field("archiveOperationID", .uuid, nullable: true)
            ],
            "StatusObservationCorrectionSnapshotRecord": [
                field("createdAt", .timestampMicroseconds),
                field("eventID", .uuid),
                field("instant", .timestampMicroseconds),
                field("localDate", .string),
                field("localHour", .integer),
                field("localMinute", .integer),
                field("localNanosecond", .integer),
                field("localSecond", .integer),
                field("metricDefinitionID", .uuid),
                field("metricNameSnapshot", .string),
                field("note", .string),
                field("ordinalLevel", .integer),
                field("parentID", .uuid),
                field("precision", .string),
                field("provenance", .string),
                field(
                    "resolvedRegimenVersionID",
                    .uuid,
                    nullable: true
                ),
                field("associationState", .string),
                field("timeZone", .string),
                field("utcOffset", .integer)
            ],
            "StatusObservationRecord": [
                field("createdAt", .timestampMicroseconds),
                field("metricDefinitionID", .uuid),
                field("metricNameSnapshot", .string),
                field("note", .string),
                field("operationID", .uuid),
                field("ordinalLevel", .integer)
            ],
            "UserPreferencesRecord": [
                field("gentleModeEnabled", .bool),
                field("notificationContentLevel", .string),
                field("onboardingCompleted", .bool),
                field("preferredLanguage", .string)
            ]
        ]

    private static func field(
        _ name: String,
        _ kind: PortableDataValue.Kind,
        nullable: Bool = false
    ) -> PortableDataRecordFieldContract {
        PortableDataRecordFieldContract(
            name,
            kind,
            allowsNull: nullable
        )
    }

    static func validate(
        modelType: String,
        recordType: String,
        fields: [PortableDataField]
    ) throws {
        guard modelType == recordType,
              let expectedFields = fieldsByModelType[modelType],
              fields.count == expectedFields.count else {
            throw PortableDataV2Error.invalidRecord
        }
        var actualByName:
            [String: PortableDataValue.Kind] = [:]
        for field in fields {
            guard actualByName.updateValue(
                field.value.kind,
                forKey: field.name
            ) == nil else {
                throw PortableDataV2Error.invalidRecord
            }
        }
        guard actualByName.count == expectedFields.count,
              expectedFields.allSatisfy({
                  guard let actual = actualByName[$0.name] else {
                      return false
                  }
                  return $0.accepts(actual)
              }) else {
            throw PortableDataV2Error.invalidRecord
        }
    }
}

enum PortableDataV2ControlSchema {
    struct Contract: Sendable {
        let disposition: PortableDataControlDisposition
        let identityField: String
        let fields: [PortableDataRecordFieldContract]
    }

    static let contracts: [String: Contract] = [
        "DatasetMetadata": Contract(
            disposition: .embeddedInEnvelope,
            identityField: "singletonKey",
            fields: [
                field("createdAt", .timestampMicroseconds),
                field("datasetID", .uuid),
                field("digestVersion", .integer),
                field(
                    "lastCommittedAt",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field("nextLocalRevision", .integer),
                field("singletonKey", .string)
            ]
        ),
        "MigrationBackfillState": Contract(
            disposition: .rebuildOnRestore,
            identityField: "taskKey",
            fields: [
                field(
                    "completedAt",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field("phaseRawValue", .string),
                field("processedCountInPhase", .integer),
                field("taskKey", .string),
                field("updatedAt", .timestampMicroseconds)
            ]
        ),
        "MigrationIssue": Contract(
            disposition: .rebuildOnRestore,
            identityField: "issueKey",
            fields: [
                field("detectedAt", .timestampMicroseconds),
                field("issueKey", .string),
                field("kindRawValue", .string),
                field("recordID", .uuid, nullable: true),
                field("recordType", .string)
            ]
        ),
        "CoreTimeRegimenBackfillState": Contract(
            disposition: .rebuildOnRestore,
            identityField: "taskKey",
            fields: [
                field(
                    "assumedTimeZoneIdentifier",
                    .string
                ),
                field(
                    "completedAt",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field("taskKey", .string),
                field("updatedAt", .timestampMicroseconds)
            ]
        ),
        "NotificationCoverageRecord": Contract(
            disposition: .deviceObservationOnly,
            identityField: "coverageKey",
            fields: [
                field("confirmedPendingCount", .integer),
                field("coverageKey", .string),
                field("desiredCount", .integer),
                field(
                    "lastErrorCode",
                    .string,
                    nullable: true
                ),
                field("observedAt", .timestampMicroseconds),
                field(
                    "scheduledThrough",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field("statusRawValue", .string)
            ]
        ),
        "TodayExecutionBackfillState": Contract(
            disposition: .rebuildOnRestore,
            identityField: "taskKey",
            fields: [
                field(
                    "completedAt",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field("taskKey", .string),
                field("updatedAt", .timestampMicroseconds)
            ]
        ),
        "PersonalTimelineBackfillState": Contract(
            disposition: .rebuildOnRestore,
            identityField: "taskKey",
            fields: [
                field(
                    "completedAt",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field("taskKey", .string),
                field("updatedAt", .timestampMicroseconds)
            ]
        ),
        "CountdownNotificationCoverageRecord": Contract(
            disposition: .deviceObservationOnly,
            identityField: "coverageKey",
            fields: [
                field("confirmedPendingCount", .integer),
                field(
                    "countdownID",
                    .uuid,
                    nullable: true
                ),
                field("coverageKey", .string),
                field("desiredCount", .integer),
                field(
                    "lastErrorCode",
                    .string,
                    nullable: true
                ),
                field("observedAt", .timestampMicroseconds),
                field(
                    "scheduledFireAt",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field("statusRawValue", .string)
            ]
        ),
        "CountdownLifecycleBackfillState": Contract(
            disposition: .rebuildOnRestore,
            identityField: "taskKey",
            fields: [
                field(
                    "assumedTimeZoneIdentifier",
                    .string
                ),
                field(
                    "completedAt",
                    .timestampMicroseconds,
                    nullable: true
                ),
                field("taskKey", .string),
                field("updatedAt", .timestampMicroseconds)
            ]
        )
    ]

    static func validate(
        _ control: PortableDataControl
    ) throws {
        guard let contract = contracts[control.modelType],
              control.disposition == contract.disposition,
              control.fields.count == contract.fields.count else {
            throw PortableDataV2Error.invalidRecord
        }
        var actual:
            [String: PortableDataValue.Kind] = [:]
        for field in control.fields {
            guard actual.updateValue(
                field.value.kind,
                forKey: field.name
            ) == nil else {
                throw PortableDataV2Error.invalidRecord
            }
        }
        guard contract.fields.allSatisfy({
            guard let kind = actual[$0.name] else {
                return false
            }
            return $0.accepts(kind)
        }),
        let identity = control.fields.first(
            where: { $0.name == contract.identityField }
        ),
        case let .string(value) =
            try identity.value.recordDigestValue(),
        value == control.stableIdentity else {
            throw PortableDataV2Error.invalidRecord
        }
    }

    private static func field(
        _ name: String,
        _ kind: PortableDataValue.Kind,
        nullable: Bool = false
    ) -> PortableDataRecordFieldContract {
        PortableDataRecordFieldContract(
            name,
            kind,
            allowsNull: nullable
        )
    }
}

struct PortableDataAttachment: Codable, Equatable, Sendable {
    let attachmentID: UUID
    let ownerType: String
    let ownerID: UUID
    let originalFilename: String
    let typeIdentifier: String
    let byteCount: Int64
    let sha256Hex: String

    var packageRelativePath: String {
        "attachments/"
            + attachmentID.uuidString.lowercased()
            + "/payload"
    }
}

struct PortableDataV2Payload: Codable, Equatable, Sendable {
    static let format = "com.mtfbook.unmanual.portable-data"
    static let formatVersion = 2
    static let schemaVersion = "12.0.0"

    let format: String
    let formatVersion: Int
    let schemaVersion: String
    let datasetID: UUID
    let sourceGenerationID: UUID
    let capturedAtMicroseconds: Int64
    let nextLocalRevision: Int64
    let modelCounts: [PortableDataModelCount]
    let records: [PortableDataRecord]
    let controls: [PortableDataControl]
    let activeAttachments: [PortableDataAttachment]
    let deviceProjectionPolicy: String

    init(
        datasetID: UUID,
        sourceGenerationID: UUID,
        capturedAtMicroseconds: Int64,
        nextLocalRevision: Int64,
        modelCounts: [PortableDataModelCount],
        records: [PortableDataRecord],
        controls: [PortableDataControl],
        activeAttachments: [PortableDataAttachment]
    ) {
        self.format = Self.format
        self.formatVersion = Self.formatVersion
        self.schemaVersion = Self.schemaVersion
        self.datasetID = datasetID
        self.sourceGenerationID = sourceGenerationID
        self.capturedAtMicroseconds = capturedAtMicroseconds
        self.nextLocalRevision = nextLocalRevision
        self.modelCounts = modelCounts
        self.records = records
        self.controls = controls
        self.activeAttachments = activeAttachments
        self.deviceProjectionPolicy =
            "notification-coverage-and-app-lock-require-local-reconciliation"
    }
}

struct PortableDataV2Document: Codable, Equatable, Sendable {
    let payload: PortableDataV2Payload
    let transportSHA256: String
}

struct PortableExportStateIdentity: Equatable, Sendable {
    let sourceGenerationID: UUID
    let datasetID: UUID
    let nextLocalRevision: Int64
    let logicalStateDigest: String

    init(
        sourceGenerationID: UUID,
        datasetID: UUID,
        nextLocalRevision: Int64,
        logicalStateDigest: String
    ) {
        self.sourceGenerationID = sourceGenerationID
        self.datasetID = datasetID
        self.nextLocalRevision = nextLocalRevision
        self.logicalStateDigest = logicalStateDigest
    }

    init(_ document: PortableDataV2Document) throws {
        sourceGenerationID =
            document.payload.sourceGenerationID
        datasetID = document.payload.datasetID
        nextLocalRevision =
            document.payload.nextLocalRevision
        logicalStateDigest = try PortableDataV2Codec
            .logicalStateDigest(document.payload)
    }
}

enum PortableDataV2Limits {
    static let maximumJSONBytes = 64 * 1_024 * 1_024
    static let maximumStringBytes = 1_024 * 1_024
    static let maximumDepth = 64
    static let maximumAttachmentCount = 2_000
    static let maximumRecordsPerModel = 250_000
}

enum PortableDataV2Error: Error, Equatable, LocalizedError {
    case inputTooLarge
    case invalidJSON
    case duplicateJSONKey(String)
    case excessiveDepth
    case invalidEnvelope
    case unsupportedFormat
    case unsupportedVersion
    case invalidTaxonomy
    case invalidCount
    case duplicateRecordKey
    case duplicateControlKey
    case invalidRecord
    case invalidValue
    case digestMismatch
    case invalidAttachment

    var errorDescription: String? {
        switch self {
        case .inputTooLarge:
            "文件超过可安全读取的上限。"
        case .invalidJSON:
            "JSON 结构不完整或无效。"
        case let .duplicateJSONKey(key):
            "JSON 含有重复字段：\(key)。"
        case .excessiveDepth:
            "JSON 嵌套层级超过安全上限。"
        case .invalidEnvelope:
            "文件外层结构不符合 Readable JSON v2。"
        case .unsupportedFormat:
            "这不是 Unmanual Readable JSON v2。"
        case .unsupportedVersion:
            "这个文件版本当前无法读取。"
        case .invalidTaxonomy:
            "文件没有完整声明 54 类本地模型。"
        case .invalidCount:
            "文件中的模型数量与记录不一致。"
        case .duplicateRecordKey:
            "文件含有重复记录身份。"
        case .duplicateControlKey:
            "文件含有重复控制记录身份。"
        case .invalidRecord:
            "文件含有无效记录或版本信息。"
        case .invalidValue:
            "文件含有无效字段值。"
        case .digestMismatch:
            "文件内容与完整性摘要不一致。"
        case .invalidAttachment:
            "附件清单不完整或含有重复身份。"
        }
    }
}

enum PortableDataV2Codec {
    static func makeDocument(
        payload: PortableDataV2Payload
    ) throws -> PortableDataV2Document {
        try PortableDataV2Validator.validate(payload)
        return PortableDataV2Document(
            payload: payload,
            transportSHA256: try transportDigest(payload)
        )
    }

    static func encode(_ document: PortableDataV2Document) throws -> Data {
        try PortableDataV2Validator.validate(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        let data = try encoder.encode(document)
        guard data.count <= PortableDataV2Limits.maximumJSONBytes else {
            throw PortableDataV2Error.inputTooLarge
        }
        return data
    }

    static func decode(_ data: Data) throws -> PortableDataV2Document {
        guard data.count <= PortableDataV2Limits.maximumJSONBytes else {
            throw PortableDataV2Error.inputTooLarge
        }
        try StrictJSONDuplicateKeyScanner.validate(
            data,
            maximumDepth: PortableDataV2Limits.maximumDepth,
            maximumStringBytes:
                PortableDataV2Limits.maximumStringBytes
        )
        try PortableDataV2ShapeValidator.validate(data)
        let decoder = JSONDecoder()
        let document: PortableDataV2Document
        do {
            document = try decoder.decode(
                PortableDataV2Document.self,
                from: data
            )
        } catch {
            throw PortableDataV2Error.invalidJSON
        }
        try PortableDataV2Validator.validate(document)
        return document
    }

    static func transportDigest(
        _ payload: PortableDataV2Payload
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        let data = try encoder.encode(payload)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
        .joined()
    }

    static func logicalStateDigest(
        _ payload: PortableDataV2Payload
    ) throws -> String {
        let stable = PortableDataV2Payload(
            datasetID: payload.datasetID,
            sourceGenerationID:
                payload.sourceGenerationID,
            capturedAtMicroseconds: 0,
            nextLocalRevision:
                payload.nextLocalRevision,
            modelCounts: payload.modelCounts,
            records: payload.records,
            controls: payload.controls,
            activeAttachments:
                payload.activeAttachments
        )
        return try transportDigest(stable)
    }
}

enum PortableDataV2Validator {
    static func validate(
        _ document: PortableDataV2Document
    ) throws {
        try validate(document.payload)
        guard document.transportSHA256
                == (try PortableDataV2Codec.transportDigest(
                    document.payload
                )) else {
            throw PortableDataV2Error.digestMismatch
        }
    }

    static func validate(_ payload: PortableDataV2Payload) throws {
        guard payload.format == PortableDataV2Payload.format else {
            throw PortableDataV2Error.unsupportedFormat
        }
        guard payload.formatVersion
                == PortableDataV2Payload.formatVersion,
              payload.schemaVersion
                == PortableDataV2Payload.schemaVersion else {
            throw PortableDataV2Error.unsupportedVersion
        }
        guard payload.capturedAtMicroseconds != Int64.min,
              payload.nextLocalRevision > 0 else {
            throw PortableDataV2Error.invalidEnvelope
        }
        let expectedModels = DataInventoryTaxonomy
            .allDatabaseModelNames
        let expectedRecordModels = Set(expectedModels)
            .subtracting(
                DataInventoryTaxonomy
                    .allowedUnrevisionedControlModels
            )
            .subtracting(["RecordRevision"])
        guard expectedModels.count == 54,
              Set(
                  PortableDataV2RecordSchema
                    .fieldsByModelType.keys
              ) == expectedRecordModels,
              payload.modelCounts.count == 54,
              payload.modelCounts.map(\.modelType)
                == expectedModels.sorted(),
              payload.modelCounts.allSatisfy({
                  $0.rowCount >= 0
                      && $0.rowCount <= Int64(
                          PortableDataV2Limits
                              .maximumRecordsPerModel
                      )
              }) else {
            throw PortableDataV2Error.invalidTaxonomy
        }
        let counts = Dictionary(
            uniqueKeysWithValues: payload.modelCounts.map {
                ($0.modelType, $0.rowCount)
            }
        )
        var recordKeys: Set<String> = []
        var factCounts: [String: Int64] = [:]
        for record in payload.records {
            guard counts[record.modelType] != nil,
                  record.recordKey
                    == record.recordType + ":"
                        + record.recordID.uuidString.lowercased(),
                  record.datasetID == payload.datasetID,
                  record.localRevision > 0,
                  record.localRevision
                    < payload.nextLocalRevision,
                  record.committedAtMicroseconds != Int64.min,
                  record.digestVersion
                    == RecordDigestV1.version,
                  record.digestHex.count == 64 else {
                throw PortableDataV2Error.invalidRecord
            }
            guard recordKeys.insert(
                record.recordKey
            ).inserted else {
                throw PortableDataV2Error.duplicateRecordKey
            }
            try PortableDataV2RecordSchema.validate(
                modelType: record.modelType,
                recordType: record.recordType,
                fields: record.fields
            )
            var names: Set<String> = []
            let fields = try record.fields.map { field in
                guard !field.name.isEmpty,
                      names.insert(field.name).inserted else {
                    throw PortableDataV2Error.invalidRecord
                }
                return RecordDigestV1.Field(
                    field.name,
                    try field.value.recordDigestValue()
                )
            }
            let digest = try RecordDigestV1.sha256Hex(
                recordType: record.recordType,
                recordID: record.recordID,
                fields: fields
            )
            guard digest == record.digestHex else {
                throw PortableDataV2Error.digestMismatch
            }
            let nextCount =
                factCounts[record.modelType, default: 0] + 1
            try validateModelRecordCount(nextCount)
            factCounts[record.modelType] = nextCount
        }
        guard counts["RecordRevision"]
                == Int64(payload.records.count) else {
            throw PortableDataV2Error.invalidCount
        }
        var controlKeys: Set<String> = []
        var controlCounts: [String: Int64] = [:]
        for control in payload.controls {
            let key = control.modelType + ":" + control.stableIdentity
            guard counts[control.modelType] != nil,
                  DataInventoryTaxonomy
                    .allowedUnrevisionedControlModels
                    .contains(control.modelType),
                  !control.stableIdentity.isEmpty,
                  control.stableIdentity
                    .lengthOfBytes(using: .utf8)
                    <= PortableDataV2Limits.maximumStringBytes else {
                throw PortableDataV2Error.invalidRecord
            }
            guard controlKeys.insert(key).inserted else {
                throw PortableDataV2Error.duplicateControlKey
            }
            try PortableDataV2ControlSchema.validate(control)
            var fieldNames: Set<String> = []
            for field in control.fields {
                guard !field.name.isEmpty,
                      field.name.lengthOfBytes(using: .utf8)
                        <= PortableDataV2Limits
                            .maximumStringBytes,
                      fieldNames.insert(field.name).inserted else {
                    throw PortableDataV2Error.invalidRecord
                }
                _ = try field.value.recordDigestValue()
            }
            let nextCount =
                controlCounts[control.modelType, default: 0] + 1
            try validateModelRecordCount(nextCount)
            controlCounts[control.modelType] = nextCount
        }
        if let metadata = payload.controls.first(
            where: { $0.modelType == "DatasetMetadata" }
        ) {
            let fields = Dictionary(
                uniqueKeysWithValues: metadata.fields.map {
                    ($0.name, $0.value)
                }
            )
            guard let datasetField = fields["datasetID"],
                  let nextRevisionField =
                    fields["nextLocalRevision"],
                  let digestVersionField =
                    fields["digestVersion"],
                  case let .uuid(datasetID) =
                    try datasetField.recordDigestValue(),
                  case let .integer(nextRevision) =
                    try nextRevisionField.recordDigestValue(),
                  case let .integer(digestVersion) =
                    try digestVersionField.recordDigestValue(),
                  datasetID == payload.datasetID,
                  nextRevision == payload.nextLocalRevision,
                  digestVersion
                    == Int64(RecordDigestV1.version) else {
                throw PortableDataV2Error.invalidRecord
            }
        }
        for model in expectedModels {
            if model == "RecordRevision" { continue }
            let expected = counts[model, default: -1]
            let actual = factCounts[model, default: 0]
                + controlCounts[model, default: 0]
            guard expected == actual else {
                throw PortableDataV2Error.invalidCount
            }
        }
        guard payload.activeAttachments.count
                <= PortableDataV2Limits.maximumAttachmentCount else {
            throw PortableDataV2Error.invalidAttachment
        }
        var attachmentIDs: Set<UUID> = []
        var attachmentByteCountsByOwner:
            [String: [Int64]] = [:]
        for attachment in payload.activeAttachments {
            guard attachmentIDs.insert(
                    attachment.attachmentID
                  ).inserted,
                  attachment.byteCount >= 0,
                  attachment.byteCount
                    <= PortableBackupLimits
                        .maximumAttachmentBytes,
                  attachment.sha256Hex.count == 64,
                  AttachmentOwnerType(
                    rawValue: attachment.ownerType
                  ) != nil,
                  !attachment.typeIdentifier.isEmpty,
                  attachment.originalFilename
                    .lengthOfBytes(using: .utf8)
                    <= 1_024,
                  AttachmentPathFacts.relativePath(
                      attachmentID:
                        attachment.attachmentID,
                      typeIdentifier:
                        attachment.typeIdentifier
                  ) != nil else {
                throw PortableDataV2Error.invalidAttachment
            }
            let ownerKey =
                attachment.ownerType
                + ":"
                + attachment.ownerID.uuidString
                    .lowercased()
            attachmentByteCountsByOwner[
                ownerKey,
                default: []
            ].append(attachment.byteCount)
        }
        do {
            for byteCounts in
                attachmentByteCountsByOwner.values {
                try AttachmentOwnerCapacity.validate(
                    byteCounts: byteCounts
                )
            }
        } catch {
            throw PortableDataV2Error.invalidAttachment
        }
    }

    static func validateModelRecordCount(
        _ count: Int64
    ) throws {
        guard count >= 0,
              count <= Int64(
                  PortableDataV2Limits
                      .maximumRecordsPerModel
              ) else {
            throw PortableDataV2Error.invalidCount
        }
    }
}

private enum PortableDataV2ShapeValidator {
    static func validate(_ data: Data) throws {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        } catch {
            throw PortableDataV2Error.invalidJSON
        }
        guard let object = root as? [String: Any],
              Set(object.keys)
                == ["payload", "transportSHA256"],
              let payload = object["payload"]
                as? [String: Any],
              Set(payload.keys) == [
                  "format", "formatVersion", "schemaVersion",
                  "datasetID", "sourceGenerationID",
                  "capturedAtMicroseconds", "nextLocalRevision",
                  "modelCounts", "records", "controls",
                  "activeAttachments", "deviceProjectionPolicy"
              ],
              let modelCounts = payload["modelCounts"] as? [[String: Any]],
              modelCounts.allSatisfy({
                  Set($0.keys) == ["modelType", "rowCount"]
              }),
              let records = payload["records"] as? [[String: Any]],
              records.allSatisfy(validateRecord),
              let controls = payload["controls"] as? [[String: Any]],
              controls.allSatisfy(validateControl),
              let attachments =
                payload["activeAttachments"] as? [[String: Any]],
              attachments.allSatisfy({
                  Set($0.keys) == [
                      "attachmentID", "ownerType", "ownerID",
                      "originalFilename", "typeIdentifier",
                      "byteCount", "sha256Hex"
                  ]
              }) else {
            throw PortableDataV2Error.invalidEnvelope
        }
    }

    private static func validateRecord(
        _ value: [String: Any]
    ) -> Bool {
        guard Set(value.keys) == [
            "modelType", "recordType", "recordID", "recordKey",
            "datasetID", "localRevision",
            "committedAtMicroseconds", "digestVersion",
            "digestHex", "fields"
        ],
        let fields = value["fields"] as? [[String: Any]]
        else {
            return false
        }
        return fields.allSatisfy(validateField)
    }

    private static func validateControl(
        _ value: [String: Any]
    ) -> Bool {
        guard Set(value.keys) == [
            "modelType", "stableIdentity", "disposition",
            "fields"
        ],
        let fields = value["fields"] as? [[String: Any]]
        else {
            return false
        }
        return fields.allSatisfy(validateField)
    }

    private static func validateField(
        _ field: [String: Any]
    ) -> Bool {
        guard Set(field.keys) == ["name", "value"],
              let payload = field["value"]
                as? [String: Any] else {
            return false
        }
        return Set(payload.keys).isSubset(of: [
            "kind", "boolValue", "integerValue",
            "doubleBitPatternHex", "stringValue",
            "uuidValue"
        ]) && payload["kind"] != nil
    }
}

struct StrictJSONDuplicateKeyScanner {
    let bytes: [UInt8]
    let maximumDepth: Int
    let maximumStringBytes: Int
    var index = 0

    static func validate(
        _ data: Data,
        maximumDepth: Int,
        maximumStringBytes: Int
    ) throws {
        var scanner = StrictJSONDuplicateKeyScanner(
            bytes: Array(data),
            maximumDepth: maximumDepth,
            maximumStringBytes: maximumStringBytes
        )
        try scanner.parseValue(depth: 0)
        scanner.skipWhitespace()
        guard scanner.index == scanner.bytes.count else {
            throw PortableDataV2Error.invalidJSON
        }
    }

    mutating func parseValue(depth: Int) throws {
        guard depth <= maximumDepth else {
            throw PortableDataV2Error.excessiveDepth
        }
        skipWhitespace()
        guard index < bytes.count else {
            throw PortableDataV2Error.invalidJSON
        }
        switch bytes[index] {
        case 0x7B:
            try parseObject(depth: depth)
        case 0x5B:
            try parseArray(depth: depth)
        case 0x22:
            _ = try parseString()
        case 0x74:
            try consume("true")
        case 0x66:
            try consume("false")
        case 0x6E:
            try consume("null")
        default:
            try parseNumber()
        }
    }

    mutating func parseObject(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consumeIf(0x7D) { return }
        var keys: Set<String> = []
        while true {
            skipWhitespace()
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw PortableDataV2Error.duplicateJSONKey(key)
            }
            skipWhitespace()
            guard consumeIf(0x3A) else {
                throw PortableDataV2Error.invalidJSON
            }
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if consumeIf(0x7D) { return }
            guard consumeIf(0x2C) else {
                throw PortableDataV2Error.invalidJSON
            }
        }
    }

    mutating func parseArray(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consumeIf(0x5D) { return }
        while true {
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if consumeIf(0x5D) { return }
            guard consumeIf(0x2C) else {
                throw PortableDataV2Error.invalidJSON
            }
        }
    }

    mutating func parseString() throws -> String {
        guard consumeIf(0x22) else {
            throw PortableDataV2Error.invalidJSON
        }
        let start = index - 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
                continue
            }
            if byte == 0x5C {
                escaped = true
                continue
            }
            if byte == 0x22 {
                let count = index - start
                guard count <= maximumStringBytes + 2 else {
                    throw PortableDataV2Error.inputTooLarge
                }
                do {
                    return try JSONDecoder().decode(
                        String.self,
                        from: Data(bytes[start..<index])
                    )
                } catch {
                    throw PortableDataV2Error.invalidJSON
                }
            }
            guard byte >= 0x20 else {
                throw PortableDataV2Error.invalidJSON
            }
        }
        throw PortableDataV2Error.invalidJSON
    }

    mutating func parseNumber() throws {
        let start = index
        while index < bytes.count,
              ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D]
                .contains(bytes[index]) {
            index += 1
        }
        guard index > start else {
            throw PortableDataV2Error.invalidJSON
        }
    }

    mutating func consume(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)])
                == expected else {
            throw PortableDataV2Error.invalidJSON
        }
        index += expected.count
    }

    mutating func skipWhitespace() {
        while index < bytes.count,
              [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
    }

    mutating func consumeIf(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else {
            return false
        }
        index += 1
        return true
    }
}
