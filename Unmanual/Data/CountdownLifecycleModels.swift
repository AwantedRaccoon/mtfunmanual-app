import Foundation
import SwiftData

enum CountdownLifecycleEventKind: String, Codable, CaseIterable, Equatable, Sendable {
    case migratedSnapshot
    case created
    case edited
    case visibilityChanged
    case reminderChanged
    case reviewResolved
    case continuedCountingUp
    case completed
    case archived
    case deleted
    case replaced
}

enum CountdownReminderTimeZoneBehavior: String, Codable, Equatable, Sendable {
    case floatingLocalV1
}

@Model
final class CountdownStateRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var gentleTitle: String?
    var targetYear: Int?
    var targetMonth: Int?
    var targetDay: Int?
    var lifecycleRawValue: String
    var overdueModeRawValue: String
    var showInToday: Bool
    var latestEventID: UUID
    var completedAt: Date?
    var archivedAt: Date?
    var deletedAt: Date?
    var terminalReminderWasEnabled: Bool?
    var terminalReminderLeadDays: Int?
    var terminalReminderLocalHour: Int?
    var terminalReminderLocalMinute: Int?
    var requiresReview: Bool
    var createdAt: Date
    var updatedAt: Date

    var targetDate: CivilDateFact? {
        guard let targetYear, let targetMonth, let targetDay else { return nil }
        return try? CivilDateFact(
            year: targetYear,
            month: targetMonth,
            day: targetDay
        )
    }

    var lifecycle: CountdownLifecycle? {
        CountdownLifecycle(rawValue: lifecycleRawValue)
    }

    var overdueMode: CountdownOverdueMode? {
        CountdownOverdueMode(rawValue: overdueModeRawValue)
    }

    init(
        id: UUID = UUID(),
        title: String,
        gentleTitle: String? = nil,
        targetDate: CivilDateFact?,
        lifecycle: CountdownLifecycle = .active,
        overdueMode: CountdownOverdueMode = .awaitingDecision,
        showInToday: Bool = true,
        latestEventID: UUID,
        completedAt: Date? = nil,
        archivedAt: Date? = nil,
        deletedAt: Date? = nil,
        terminalReminderWasEnabled: Bool? = nil,
        terminalReminderLeadDays: Int? = nil,
        terminalReminderLocalHour: Int? = nil,
        terminalReminderLocalMinute: Int? = nil,
        requiresReview: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.gentleTitle = gentleTitle
        self.targetYear = targetDate?.year
        self.targetMonth = targetDate?.month
        self.targetDay = targetDate?.day
        self.lifecycleRawValue = lifecycle.rawValue
        self.overdueModeRawValue = overdueMode.rawValue
        self.showInToday = showInToday
        self.latestEventID = latestEventID
        self.completedAt = completedAt
        self.archivedAt = archivedAt
        self.deletedAt = deletedAt
        self.terminalReminderWasEnabled = terminalReminderWasEnabled
        self.terminalReminderLeadDays = terminalReminderLeadDays
        self.terminalReminderLocalHour = terminalReminderLocalHour
        self.terminalReminderLocalMinute = terminalReminderLocalMinute
        self.requiresReview = requiresReview
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func setTargetDate(_ value: CivilDateFact?) {
        targetYear = value?.year
        targetMonth = value?.month
        targetDay = value?.day
    }

    func setTerminalReminderSnapshot(
        from reminder: CountdownReminderRuleRecord
    ) {
        terminalReminderWasEnabled = reminder.isEnabled
        terminalReminderLeadDays = reminder.leadDays
        terminalReminderLocalHour = reminder.localHour
        terminalReminderLocalMinute = reminder.localMinute
    }

    func clearTerminalReminderSnapshot() {
        terminalReminderWasEnabled = nil
        terminalReminderLeadDays = nil
        terminalReminderLocalHour = nil
        terminalReminderLocalMinute = nil
    }
}

@Model
final class CountdownLifecycleEventRecord {
    @Attribute(.unique) var id: UUID
    var countdownID: UUID
    var kindRawValue: String
    var previousEventID: UUID?
    var operationID: UUID
    var oldTargetYear: Int?
    var oldTargetMonth: Int?
    var oldTargetDay: Int?
    var newTargetYear: Int?
    var newTargetMonth: Int?
    var newTargetDay: Int?
    var replacementCountdownID: UUID?
    var occurredAt: Date
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

    var kind: CountdownLifecycleEventKind? {
        CountdownLifecycleEventKind(rawValue: kindRawValue)
    }

    var oldTargetDate: CivilDateFact? {
        Self.civilDate(year: oldTargetYear, month: oldTargetMonth, day: oldTargetDay)
    }

    var newTargetDate: CivilDateFact? {
        Self.civilDate(year: newTargetYear, month: newTargetMonth, day: newTargetDay)
    }

    var historicalTimestamp: HistoricalTimestamp? {
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
        let precision = HistoricalTimestampPrecision(rawValue: precisionRawValue),
        let provenance = HistoricalTimestampProvenance(rawValue: provenanceRawValue) else {
            return nil
        }
        return try? HistoricalTimestamp(
            validatingInstant: occurredAt,
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
        countdownID: UUID,
        kind: CountdownLifecycleEventKind,
        previousEventID: UUID? = nil,
        operationID: UUID,
        oldTargetDate: CivilDateFact? = nil,
        newTargetDate: CivilDateFact? = nil,
        replacementCountdownID: UUID? = nil,
        timestamp: HistoricalTimestamp
    ) {
        self.id = id
        self.countdownID = countdownID
        self.kindRawValue = kind.rawValue
        self.previousEventID = previousEventID
        self.operationID = operationID
        self.oldTargetYear = oldTargetDate?.year
        self.oldTargetMonth = oldTargetDate?.month
        self.oldTargetDay = oldTargetDate?.day
        self.newTargetYear = newTargetDate?.year
        self.newTargetMonth = newTargetDate?.month
        self.newTargetDay = newTargetDate?.day
        self.replacementCountdownID = replacementCountdownID
        self.occurredAt = timestamp.instant
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
final class CountdownReminderRuleRecord {
    @Attribute(.unique) var ruleKey: String
    var id: UUID
    var countdownID: UUID
    var isEnabled: Bool
    var leadDays: Int
    var localHour: Int
    var localMinute: Int
    var timeZoneBehaviorRawValue: String
    var contentVersion: String
    var lastOperationID: UUID
    var updatedAt: Date

    var timeZoneBehavior: CountdownReminderTimeZoneBehavior? {
        CountdownReminderTimeZoneBehavior(rawValue: timeZoneBehaviorRawValue)
    }

    init(
        id: UUID = UUID(),
        countdownID: UUID,
        isEnabled: Bool,
        leadDays: Int = 0,
        localHour: Int = 9,
        localMinute: Int = 0,
        timeZoneBehavior: CountdownReminderTimeZoneBehavior = .floatingLocalV1,
        contentVersion: String = "neutralV1",
        lastOperationID: UUID,
        updatedAt: Date = Date()
    ) {
        self.ruleKey = Self.key(countdownID: countdownID)
        self.id = id
        self.countdownID = countdownID
        self.isEnabled = isEnabled
        self.leadDays = leadDays
        self.localHour = localHour
        self.localMinute = localMinute
        self.timeZoneBehaviorRawValue = timeZoneBehavior.rawValue
        self.contentVersion = contentVersion
        self.lastOperationID = lastOperationID
        self.updatedAt = updatedAt
    }

    static func key(countdownID: UUID) -> String {
        "countdown:" + countdownID.uuidString.lowercased()
    }
}

@Model
final class CountdownNotificationCoverageRecord {
    static let fixedKey = "local-countdown-reminder"

    @Attribute(.unique) var coverageKey: String
    var countdownID: UUID?
    var statusRawValue: String
    var scheduledFireAt: Date?
    var desiredCount: Int
    var confirmedPendingCount: Int
    var lastErrorCode: String?
    var observedAt: Date

    var status: NotificationCoverageStatus? {
        NotificationCoverageStatus(rawValue: statusRawValue)
    }

    init(
        coverageKey: String = CountdownNotificationCoverageRecord.fixedKey,
        countdownID: UUID? = nil,
        status: NotificationCoverageStatus,
        scheduledFireAt: Date? = nil,
        desiredCount: Int = 0,
        confirmedPendingCount: Int = 0,
        lastErrorCode: String? = nil,
        observedAt: Date = Date()
    ) {
        self.coverageKey = coverageKey
        self.countdownID = countdownID
        self.statusRawValue = status.rawValue
        self.scheduledFireAt = scheduledFireAt
        self.desiredCount = desiredCount
        self.confirmedPendingCount = confirmedPendingCount
        self.lastErrorCode = lastErrorCode
        self.observedAt = observedAt
    }
}

extension CountdownNotificationCoverageRecord {
    static func isConsistent(
        status: NotificationCoverageStatus,
        scheduledFireAt: Date?,
        desiredCount: Int,
        confirmedPendingCount: Int,
        lastErrorCode: String?
    ) -> Bool {
        guard desiredCount >= 0,
              confirmedPendingCount >= 0,
              confirmedPendingCount <= desiredCount,
              scheduledFireAt?.timeIntervalSince1970.isFinite != false else {
            return false
        }
        switch status {
        case .disabledByUser, .notDetermined, .blockedByPermission,
             .limitedBySystemSettings, .reconciliationPending,
             .staleObservation:
            return desiredCount == 0
                && confirmedPendingCount == 0
                && scheduledFireAt == nil
                && lastErrorCode == nil
        case .scheduledForWindow:
            return confirmedPendingCount == desiredCount
                && lastErrorCode == nil
                && (
                    desiredCount == 0
                        ? scheduledFireAt == nil
                        : scheduledFireAt != nil
                )
        case .limitedByBudget:
            return desiredCount == 0
                && confirmedPendingCount == 0
                && scheduledFireAt == nil
                && lastErrorCode == nil
        case .schedulingFailed:
            return confirmedPendingCount == 0
                && scheduledFireAt == nil
                && lastErrorCode?.isEmpty == false
        }
    }
}

@Model
final class CountdownLifecycleBackfillState {
    static let fixedKey = "v5-to-v6-countdown-lifecycle"

    @Attribute(.unique) var taskKey: String
    var assumedTimeZoneIdentifier: String
    var completedAt: Date?
    var updatedAt: Date

    init(
        taskKey: String = CountdownLifecycleBackfillState.fixedKey,
        assumedTimeZoneIdentifier: String,
        completedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.taskKey = taskKey
        self.assumedTimeZoneIdentifier = assumedTimeZoneIdentifier
        self.completedAt = completedAt
        self.updatedAt = updatedAt
    }
}
