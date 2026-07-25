import Foundation
import SwiftData

enum CountdownCommandAuditKind: String, Codable, CaseIterable, Sendable {
    case migratedSnapshot
    case create
    case update
    case review
    case continueCountingUp
    case complete
    case archive
    case delete
    case replace
    case replacementDeletion
}

enum CountdownCommandAuditSource: String, Codable, Sendable {
    case nativeV7
}

enum CountdownReminderAdmission: String, Codable, Sendable {
    case disabledAtUpgrade
    case needsUserConfirmation
}

@Model
final class CountdownCommandAuditRecord {
    @Attribute(.unique) var eventID: UUID
    var operationID: UUID
    var countdownID: UUID
    var commandKindRawValue: String
    var sourceRawValue: String
    var commandDigestVersion: String
    var commandDigest: String
    var expectedLatestEventID: UUID?
    var titleCommitment: String?
    var gentleTitleCommitment: String?
    var targetYear: Int?
    var targetMonth: Int?
    var targetDay: Int?
    var showInToday: Bool?
    var reminderIsEnabled: Bool?
    var reminderLeadDays: Int?
    var reminderLocalHour: Int?
    var reminderLocalMinute: Int?
    var todayYear: Int?
    var todayMonth: Int?
    var todayDay: Int?
    var reviewResolutionRawValue: String?
    var replacementCountdownID: UUID?
    var replacementEventID: UUID?
    var primaryCommandDigest: String?
    var eventTimestampCommitment: String
    var eventSemanticDigest: String
    var preFactsDigest: String
    var postFactsDigest: String
    var previousAuditDigest: String?
    var terminalReminderWasEnabled: Bool?
    var terminalReminderLeadDays: Int?
    var terminalReminderLocalHour: Int?
    var terminalReminderLocalMinute: Int?
    var committedAt: Date
    var auditDigest: String

    var commandKind: CountdownCommandAuditKind? {
        CountdownCommandAuditKind(rawValue: commandKindRawValue)
    }

    var source: CountdownCommandAuditSource? {
        CountdownCommandAuditSource(rawValue: sourceRawValue)
    }

    var targetDate: CivilDateFact? {
        Self.civilDate(year: targetYear, month: targetMonth, day: targetDay)
    }

    var today: CivilDateFact? {
        Self.civilDate(year: todayYear, month: todayMonth, day: todayDay)
    }

    init(
        eventID: UUID,
        operationID: UUID,
        countdownID: UUID,
        commandKind: CountdownCommandAuditKind,
        expectedLatestEventID: UUID? = nil,
        titleCommitment: String? = nil,
        gentleTitleCommitment: String? = nil,
        targetDate: CivilDateFact? = nil,
        showInToday: Bool? = nil,
        reminder: CountdownReminderInput? = nil,
        today: CivilDateFact? = nil,
        reviewResolution: CountdownReviewResolution? = nil,
        replacementCountdownID: UUID? = nil,
        replacementEventID: UUID? = nil,
        primaryCommandDigest: String? = nil,
        eventTimestampCommitment: String,
        eventSemanticDigest: String,
        preFactsDigest: String,
        postFactsDigest: String,
        previousAuditDigest: String? = nil,
        terminalReminderWasEnabled: Bool? = nil,
        terminalReminderLeadDays: Int? = nil,
        terminalReminderLocalHour: Int? = nil,
        terminalReminderLocalMinute: Int? = nil,
        committedAt: Date
    ) {
        self.eventID = eventID
        self.operationID = operationID
        self.countdownID = countdownID
        self.commandKindRawValue = commandKind.rawValue
        self.sourceRawValue = CountdownCommandAuditSource.nativeV7.rawValue
        self.commandDigestVersion = CountdownIntegrityDigest.commandVersion
        self.commandDigest = String(repeating: "0", count: 64)
        self.expectedLatestEventID = expectedLatestEventID
        self.titleCommitment = titleCommitment
        self.gentleTitleCommitment = gentleTitleCommitment
        self.targetYear = targetDate?.year
        self.targetMonth = targetDate?.month
        self.targetDay = targetDate?.day
        self.showInToday = showInToday
        self.reminderIsEnabled = reminder?.isEnabled
        self.reminderLeadDays = reminder?.leadDays
        self.reminderLocalHour = reminder?.localHour
        self.reminderLocalMinute = reminder?.localMinute
        self.todayYear = today?.year
        self.todayMonth = today?.month
        self.todayDay = today?.day
        self.reviewResolutionRawValue = reviewResolution?.rawValue
        self.replacementCountdownID = replacementCountdownID
        self.replacementEventID = replacementEventID
        self.primaryCommandDigest = primaryCommandDigest
        self.eventTimestampCommitment = eventTimestampCommitment
        self.eventSemanticDigest = eventSemanticDigest
        self.preFactsDigest = preFactsDigest
        self.postFactsDigest = postFactsDigest
        self.previousAuditDigest = previousAuditDigest
        self.terminalReminderWasEnabled = terminalReminderWasEnabled
        self.terminalReminderLeadDays = terminalReminderLeadDays
        self.terminalReminderLocalHour = terminalReminderLocalHour
        self.terminalReminderLocalMinute = terminalReminderLocalMinute
        self.committedAt = committedAt
        self.auditDigest = String(repeating: "0", count: 64)
    }

    func seal() throws {
        commandDigest = try CountdownIntegrityDigest.command(self)
        auditDigest = try CountdownIntegrityDigest.audit(self)
    }

    private static func civilDate(
        year: Int?,
        month: Int?,
        day: Int?
    ) -> CivilDateFact? {
        guard let year, let month, let day else { return nil }
        return try? CivilDateFact(year: year, month: month, day: day)
    }
}

@Model
final class CountdownV6AuditCheckpointRecord {
    @Attribute(.unique) var countdownID: UUID
    var boundaryEventID: UUID
    var prefixEventCount: Int
    var prefixChainDigest: String
    var postFactsDigest: String
    var reminderAdmissionRawValue: String
    var createdAt: Date
    var checkpointDigest: String

    var reminderAdmission: CountdownReminderAdmission? {
        CountdownReminderAdmission(rawValue: reminderAdmissionRawValue)
    }

    init(
        countdownID: UUID,
        boundaryEventID: UUID,
        prefixEventCount: Int,
        prefixChainDigest: String,
        postFactsDigest: String,
        reminderAdmission: CountdownReminderAdmission,
        createdAt: Date
    ) {
        self.countdownID = countdownID
        self.boundaryEventID = boundaryEventID
        self.prefixEventCount = prefixEventCount
        self.prefixChainDigest = prefixChainDigest
        self.postFactsDigest = postFactsDigest
        self.reminderAdmissionRawValue = reminderAdmission.rawValue
        self.createdAt = createdAt
        self.checkpointDigest = String(repeating: "0", count: 64)
    }

    func seal() throws {
        checkpointDigest = try CountdownIntegrityDigest.checkpoint(self)
    }
}

@Model
final class CountdownIntegrityBackfillState {
    static let fixedKey = "v6-to-v7-countdown-integrity"

    @Attribute(.unique) var taskKey: String
    var sourceSchemaVersion: String
    var initialAuditCount: Int
    var initialCheckpointCount: Int
    var initialIntegritySetDigest: String
    var completedAt: Date?
    var updatedAt: Date

    init(
        taskKey: String = CountdownIntegrityBackfillState.fixedKey,
        sourceSchemaVersion: String,
        initialAuditCount: Int,
        initialCheckpointCount: Int,
        initialIntegritySetDigest: String,
        completedAt: Date?,
        updatedAt: Date
    ) {
        self.taskKey = taskKey
        self.sourceSchemaVersion = sourceSchemaVersion
        self.initialAuditCount = initialAuditCount
        self.initialCheckpointCount = initialCheckpointCount
        self.initialIntegritySetDigest = initialIntegritySetDigest
        self.completedAt = completedAt
        self.updatedAt = updatedAt
    }
}

enum CountdownIntegrityDigest {
    static let commandVersion = "countdown-command-v2"

    static func absentFactsDigest() throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "CountdownFactsAbsentV1",
            recordID: UUID(
                uuid: (
                    0x79, 0x00, 0x00, 0x00,
                    0x00, 0x00,
                    0x00, 0x00,
                    0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x01
                )
            ),
            fields: [.init("value", .string("absent"))]
        )
    }

    static func privateCommitment(
        _ value: String?,
        operationID: UUID,
        label: String
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "CountdownPrivateCommitmentV1",
            recordID: operationID,
            fields: [
                .init("label", .string(label)),
                .init("value", value.map(RecordDigestV1.Value.string) ?? .null)
            ]
        )
    }

    static func eventSemantic(
        _ event: CountdownLifecycleEventRecord
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "CountdownLifecycleEventSemanticV1",
            recordID: event.id,
            fields: try CountdownDigestV1.event(event)
        )
    }

    static func timestampCommitment(
        _ timestamp: HistoricalTimestamp,
        operationID: UUID
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "CountdownEventTimestampCommitmentV1",
            recordID: operationID,
            fields: [
                .init(
                    "instant",
                    try RecordDigestV1.timestampValue(timestamp.instant)
                ),
                .init("localDate", .string(timestamp.localDate.iso8601)),
                .init(
                    "localHour",
                    .integer(Int64(timestamp.localTime.hour))
                ),
                .init(
                    "localMinute",
                    .integer(Int64(timestamp.localTime.minute))
                ),
                .init(
                    "localNanosecond",
                    .integer(Int64(timestamp.localTime.nanosecond))
                ),
                .init(
                    "localSecond",
                    .integer(Int64(timestamp.localTime.second))
                ),
                .init("precision", .string(timestamp.precision.rawValue)),
                .init("provenance", .string(timestamp.provenance.rawValue)),
                .init(
                    "timeZoneIdentifier",
                    .string(timestamp.timeZoneIdentifier)
                ),
                .init(
                    "utcOffsetSeconds",
                    .integer(Int64(timestamp.utcOffsetSeconds))
                )
            ]
        )
    }

    static func facts(
        state: CountdownStateRecord,
        reminder: CountdownReminderRuleRecord,
        legacy: CountdownRecord?
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "CountdownMaterializedFactsV1",
            recordID: state.id,
            fields: [
                .init(
                    "legacy",
                    .string(
                        try legacy.map(FactDigestV1.digest)
                            ?? absentFactsDigest()
                    )
                ),
                .init(
                    "reminder",
                    .string(
                        try RecordDigestV1.sha256Hex(
                            recordType: "CountdownReminderRuleRecord",
                            recordID: reminder.id,
                            fields: CountdownDigestV1.reminder(reminder)
                        )
                    )
                ),
                .init(
                    "state",
                    .string(
                        try RecordDigestV1.sha256Hex(
                            recordType: "CountdownStateRecord",
                            recordID: state.id,
                            fields: CountdownDigestV1.state(state)
                        )
                    )
                )
            ]
        )
    }

    static func command(
        _ value: CountdownCommandAuditRecord
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "CountdownCommandAuditV2",
            recordID: value.operationID,
            fields: commandFields(value)
        )
    }

    static func audit(
        _ value: CountdownCommandAuditRecord
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "CountdownCommandAuditRecord",
            recordID: value.eventID,
            fields: auditFields(value, includeAuditDigest: false)
        )
    }

    static func revisionFields(
        _ value: CountdownCommandAuditRecord
    ) throws -> [RecordDigestV1.Field] {
        try auditFields(value, includeAuditDigest: true)
    }

    static func checkpoint(
        _ value: CountdownV6AuditCheckpointRecord
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "CountdownV6AuditCheckpointRecord",
            recordID: value.countdownID,
            fields: checkpointFields(value, includeCheckpointDigest: false)
        )
    }

    static func checkpointRevisionFields(
        _ value: CountdownV6AuditCheckpointRecord
    ) throws -> [RecordDigestV1.Field] {
        try checkpointFields(value, includeCheckpointDigest: true)
    }

    static func backfillState(
        _ value: CountdownIntegrityBackfillState
    ) throws -> [RecordDigestV1.Field] {
        [
            .init(
                "initialAuditCount",
                .integer(Int64(value.initialAuditCount))
            ),
            .init(
                "initialCheckpointCount",
                .integer(Int64(value.initialCheckpointCount))
            ),
            .init(
                "completedAt",
                try value.completedAt.map(RecordDigestV1.timestampValue) ?? .null
            ),
            .init(
                "initialIntegritySetDigest",
                .string(value.initialIntegritySetDigest)
            ),
            .init("sourceSchemaVersion", .string(value.sourceSchemaVersion)),
            .init("taskKey", .string(value.taskKey)),
            .init("updatedAt", try RecordDigestV1.timestampValue(value.updatedAt))
        ]
    }

    static func integritySetDigest(
        audits: [CountdownCommandAuditRecord],
        checkpoints: [CountdownV6AuditCheckpointRecord]
    ) throws -> String {
        let rows =
            audits.map {
                "a:"
                    + $0.eventID.uuidString.lowercased()
                    + ":"
                    + $0.auditDigest
            }
            + checkpoints.map {
                "c:"
                    + $0.countdownID.uuidString.lowercased()
                    + ":"
                    + $0.checkpointDigest
            }
        return try RecordDigestV1.sha256Hex(
            recordType: "CountdownIntegritySetV1",
            recordID: UUID(
                uuid: (
                    0x79, 0x00, 0x00, 0x00,
                    0x00, 0x00,
                    0x00, 0x00,
                    0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x02
                )
            ),
            fields: rows.sorted().enumerated().map {
                .init(String(format: "row.%08d", $0.offset), .string($0.element))
            }
        )
    }

    static func prefixChain(
        events: [CountdownLifecycleEventRecord],
        receiptsByOperationID: [UUID: OperationReceiptRecord]
    ) throws -> String {
        let rows = try events.enumerated().map { offset, event in
            guard let receipt = receiptsByOperationID[event.operationID] else {
                throw AppDataFailure.migrationFailed
            }
            return RecordDigestV1.Field(
                String(format: "event.%08d", offset),
                .string(
                    try RecordDigestV1.sha256Hex(
                        recordType: "CountdownV6PrefixEventV1",
                        recordID: event.id,
                        fields: [
                            .init(
                                "eventSemanticDigest",
                                .string(try eventSemantic(event))
                            ),
                            .init(
                                "receiptCommandDigest",
                                .string(receipt.commandDigest)
                            ),
                            .init(
                                "receiptCommittedAt",
                                try RecordDigestV1.timestampValue(
                                    receipt.committedAt
                                )
                            )
                        ]
                    )
                )
            )
        }
        return try RecordDigestV1.sha256Hex(
            recordType: "CountdownV6PrefixChainV1",
            recordID: events.last?.countdownID
                ?? UUID(
                    uuid: (
                        0x79, 0x00, 0x00, 0x00,
                        0x00, 0x00,
                        0x00, 0x00,
                        0x00, 0x00,
                        0x00, 0x00, 0x00, 0x00, 0x00, 0x03
                    )
                ),
            fields: rows
        )
    }

    private static func commandFields(
        _ value: CountdownCommandAuditRecord
    ) throws -> [RecordDigestV1.Field] {
        [
            .init("commandKind", .string(value.commandKindRawValue)),
            .init(
                "committedAt",
                try RecordDigestV1.timestampValue(value.committedAt)
            ),
            .init("countdownID", .uuid(value.countdownID)),
            .init("eventID", .uuid(value.eventID)),
            .init(
                "eventTimestampCommitment",
                .string(value.eventTimestampCommitment)
            ),
            .init(
                "expectedLatestEventID",
                value.expectedLatestEventID.map(RecordDigestV1.Value.uuid)
                    ?? .null
            ),
            .init(
                "gentleTitleCommitment",
                value.gentleTitleCommitment.map(RecordDigestV1.Value.string)
                    ?? .null
            ),
            .init(
                "primaryCommandDigest",
                value.primaryCommandDigest.map(RecordDigestV1.Value.string)
                    ?? .null
            ),
            .init(
                "reminderIsEnabled",
                value.reminderIsEnabled.map(RecordDigestV1.Value.bool) ?? .null
            ),
            .init(
                "reminderLeadDays",
                value.reminderLeadDays.map {
                    .integer(Int64($0))
                } ?? .null
            ),
            .init(
                "reminderLocalHour",
                value.reminderLocalHour.map {
                    .integer(Int64($0))
                } ?? .null
            ),
            .init(
                "reminderLocalMinute",
                value.reminderLocalMinute.map {
                    .integer(Int64($0))
                } ?? .null
            ),
            .init(
                "replacementCountdownID",
                value.replacementCountdownID.map(RecordDigestV1.Value.uuid)
                    ?? .null
            ),
            .init(
                "replacementEventID",
                value.replacementEventID.map(RecordDigestV1.Value.uuid)
                    ?? .null
            ),
            .init(
                "reviewResolution",
                value.reviewResolutionRawValue.map(
                    RecordDigestV1.Value.string
                ) ?? .null
            ),
            .init(
                "showInToday",
                value.showInToday.map(RecordDigestV1.Value.bool) ?? .null
            ),
            .init(
                "target",
                value.targetDate.map {
                    .string($0.iso8601)
                } ?? .null
            ),
            .init(
                "titleCommitment",
                value.titleCommitment.map(RecordDigestV1.Value.string) ?? .null
            ),
            .init(
                "today",
                value.today.map {
                    .string($0.iso8601)
                } ?? .null
            )
        ]
    }

    private static func auditFields(
        _ value: CountdownCommandAuditRecord,
        includeAuditDigest: Bool
    ) throws -> [RecordDigestV1.Field] {
        var fields = try commandFields(value) + [
            .init("auditSource", .string(value.sourceRawValue)),
            .init("commandDigest", .string(value.commandDigest)),
            .init(
                "commandDigestVersion",
                .string(value.commandDigestVersion)
            ),
            .init(
                "eventSemanticDigest",
                .string(value.eventSemanticDigest)
            ),
            .init("postFactsDigest", .string(value.postFactsDigest)),
            .init("preFactsDigest", .string(value.preFactsDigest)),
            .init(
                "previousAuditDigest",
                value.previousAuditDigest.map(RecordDigestV1.Value.string)
                    ?? .null
            ),
            .init(
                "terminalReminderLeadDays",
                value.terminalReminderLeadDays.map {
                    .integer(Int64($0))
                } ?? .null
            ),
            .init(
                "terminalReminderLocalHour",
                value.terminalReminderLocalHour.map {
                    .integer(Int64($0))
                } ?? .null
            ),
            .init(
                "terminalReminderLocalMinute",
                value.terminalReminderLocalMinute.map {
                    .integer(Int64($0))
                } ?? .null
            ),
            .init(
                "terminalReminderWasEnabled",
                value.terminalReminderWasEnabled.map(
                    RecordDigestV1.Value.bool
                ) ?? .null
            )
        ]
        if includeAuditDigest {
            fields.append(.init("auditDigest", .string(value.auditDigest)))
        }
        return fields
    }

    private static func checkpointFields(
        _ value: CountdownV6AuditCheckpointRecord,
        includeCheckpointDigest: Bool
    ) throws -> [RecordDigestV1.Field] {
        var fields: [RecordDigestV1.Field] = [
            .init("boundaryEventID", .uuid(value.boundaryEventID)),
            .init(
                "createdAt",
                try RecordDigestV1.timestampValue(value.createdAt)
            ),
            .init("postFactsDigest", .string(value.postFactsDigest)),
            .init(
                "prefixEventCount",
                .integer(Int64(value.prefixEventCount))
            ),
            .init("prefixChainDigest", .string(value.prefixChainDigest)),
            .init(
                "reminderAdmission",
                .string(value.reminderAdmissionRawValue)
            )
        ]
        if includeCheckpointDigest {
            fields.append(
                .init("checkpointDigest", .string(value.checkpointDigest))
            )
        }
        return fields
    }
}
