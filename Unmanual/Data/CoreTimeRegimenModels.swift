import Foundation
import SwiftData

enum ScheduleRuleKind: String, Codable, CaseIterable, Sendable {
    case dailyTimes
    case weekly
    case everyNDays
    case oneOff
}

enum ScheduleTimeZoneBehavior: String, Codable, CaseIterable, Sendable {
    case floatingLocal
    case fixedZone
}

enum HistoricalAssociationState: String, Codable, Sendable {
    case resolved
    case missing
    case ambiguous

    var reviewNotice: String? {
        switch self {
        case .resolved:
            nil
        case .missing:
            "未找到可关联的当时方案，需要核对。"
        case .ambiguous:
            "找到多个候选方案，需要核对。"
        }
    }
}

@Model
final class UserPreferencesRecord {
    static let fixedKey = "primary-user-preferences"

    @Attribute(.unique) var singletonKey: String
    var gentleModeEnabled: Bool
    var notificationContentLevel: String
    var preferredLanguage: String
    var onboardingCompleted: Bool
    var createdAt: Date

    init(
        singletonKey: String = UserPreferencesRecord.fixedKey,
        gentleModeEnabled: Bool = false,
        notificationContentLevel: String = "gentle",
        preferredLanguage: String = "zh-Hans",
        onboardingCompleted: Bool = false,
        createdAt: Date = Date()
    ) {
        self.singletonKey = singletonKey
        self.gentleModeEnabled = gentleModeEnabled
        self.notificationContentLevel = notificationContentLevel
        self.preferredLanguage = preferredLanguage
        self.onboardingCompleted = onboardingCompleted
        self.createdAt = createdAt
    }
}

@Model
final class HrtJourneyProfileRecord {
    static let fixedKey = "primary-hrt-journey"

    @Attribute(.unique) var singletonKey: String
    var firstEverStartYear: Int
    var firstEverStartMonth: Int
    var firstEverStartDay: Int
    var createdAt: Date

    var firstEverStartDate: CivilDateFact? {
        try? CivilDateFact(
            year: firstEverStartYear,
            month: firstEverStartMonth,
            day: firstEverStartDay
        )
    }

    init(
        singletonKey: String = HrtJourneyProfileRecord.fixedKey,
        firstEverStartDate: CivilDateFact,
        createdAt: Date = Date()
    ) {
        self.singletonKey = singletonKey
        self.firstEverStartYear = firstEverStartDate.year
        self.firstEverStartMonth = firstEverStartDate.month
        self.firstEverStartDay = firstEverStartDate.day
        self.createdAt = createdAt
    }
}

@Model
final class HrtPeriodRecord {
    @Attribute(.unique) var id: UUID
    var startYear: Int
    var startMonth: Int
    var startDay: Int
    var endYear: Int?
    var endMonth: Int?
    var endDay: Int?
    var note: String
    var createdAt: Date

    var startDate: CivilDateFact? {
        try? CivilDateFact(year: startYear, month: startMonth, day: startDay)
    }

    var endDate: CivilDateFact? {
        guard let endYear, let endMonth, let endDay else { return nil }
        return try? CivilDateFact(year: endYear, month: endMonth, day: endDay)
    }

    init(
        id: UUID = UUID(),
        startDate: CivilDateFact,
        endDate: CivilDateFact? = nil,
        note: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.startYear = startDate.year
        self.startMonth = startDate.month
        self.startDay = startDate.day
        self.endYear = endDate?.year
        self.endMonth = endDate?.month
        self.endDay = endDate?.day
        self.note = note
        self.createdAt = createdAt
    }
}

@Model
final class RegimenPlanVersionRecord {
    @Attribute(.unique) var id: UUID
    var code: String
    var title: String
    var effectiveStartYear: Int
    var effectiveStartMonth: Int
    var effectiveStartDay: Int
    var effectiveEndYear: Int?
    var effectiveEndMonth: Int?
    var effectiveEndDay: Int?
    var previousVersionID: UUID?
    var changeReason: String
    var editStateRawValue: String
    var isArchived: Bool
    var requiresMigrationReview: Bool
    var legacySourceID: UUID?
    var createdAt: Date

    var editState: RegimenEditState {
        get { RegimenEditState(rawValue: editStateRawValue) ?? .draft }
        set { editStateRawValue = newValue.rawValue }
    }

    var effectiveStartDate: CivilDateFact? {
        try? CivilDateFact(
            year: effectiveStartYear,
            month: effectiveStartMonth,
            day: effectiveStartDay
        )
    }

    var effectiveEndDate: CivilDateFact? {
        guard let effectiveEndYear, let effectiveEndMonth, let effectiveEndDay else { return nil }
        return try? CivilDateFact(
            year: effectiveEndYear,
            month: effectiveEndMonth,
            day: effectiveEndDay
        )
    }

    init(
        id: UUID = UUID(),
        code: String,
        title: String,
        effectiveStartDate: CivilDateFact,
        effectiveEndDate: CivilDateFact? = nil,
        previousVersionID: UUID? = nil,
        changeReason: String = "",
        editState: RegimenEditState,
        isArchived: Bool = false,
        requiresMigrationReview: Bool = false,
        legacySourceID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.code = code
        self.title = title
        self.effectiveStartYear = effectiveStartDate.year
        self.effectiveStartMonth = effectiveStartDate.month
        self.effectiveStartDay = effectiveStartDate.day
        self.effectiveEndYear = effectiveEndDate?.year
        self.effectiveEndMonth = effectiveEndDate?.month
        self.effectiveEndDay = effectiveEndDate?.day
        self.previousVersionID = previousVersionID
        self.changeReason = changeReason
        self.editStateRawValue = editState.rawValue
        self.isArchived = isArchived
        self.requiresMigrationReview = requiresMigrationReview
        self.legacySourceID = legacySourceID
        self.createdAt = createdAt
    }
}

@Model
final class RegimenItemRecord {
    @Attribute(.unique) var id: UUID
    var regimenVersionID: UUID
    var sortOrder: Int
    var catalogProductID: String?
    var catalogVersion: String?
    var displayName: String
    var genericName: String
    var dosageForm: String
    var route: String
    var doseOriginal: String
    var unitOriginal: String
    var productSnapshot: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        regimenVersionID: UUID,
        sortOrder: Int,
        catalogProductID: String? = nil,
        catalogVersion: String? = nil,
        displayName: String,
        genericName: String = "",
        dosageForm: String = "",
        route: String = "",
        doseOriginal: String = "",
        unitOriginal: String = "",
        productSnapshot: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.regimenVersionID = regimenVersionID
        self.sortOrder = sortOrder
        self.catalogProductID = catalogProductID
        self.catalogVersion = catalogVersion
        self.displayName = displayName
        self.genericName = genericName
        self.dosageForm = dosageForm
        self.route = route
        self.doseOriginal = doseOriginal
        self.unitOriginal = unitOriginal
        self.productSnapshot = productSnapshot
        self.createdAt = createdAt
    }
}

@Model
final class ScheduleRuleRecord {
    @Attribute(.unique) var id: UUID
    var regimenItemID: UUID
    var kindRawValue: String
    var anchorYear: Int
    var anchorMonth: Int
    var anchorDay: Int
    var endYear: Int?
    var endMonth: Int?
    var endDay: Int?
    var localTimes: String
    var weekdays: String
    var intervalDays: Int?
    var timeZoneBehaviorRawValue: String
    var fixedTimeZoneIdentifier: String?
    var reminderEnabled: Bool
    var defaultSnoozeMinutes: Int
    var revision: Int
    var createdAt: Date

    var kind: ScheduleRuleKind {
        get { ScheduleRuleKind(rawValue: kindRawValue) ?? .dailyTimes }
        set { kindRawValue = newValue.rawValue }
    }

    var timeZoneBehavior: ScheduleTimeZoneBehavior {
        get { ScheduleTimeZoneBehavior(rawValue: timeZoneBehaviorRawValue) ?? .floatingLocal }
        set { timeZoneBehaviorRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        regimenItemID: UUID,
        kind: ScheduleRuleKind,
        anchorDate: CivilDateFact,
        endDate: CivilDateFact? = nil,
        localTimes: String = "",
        weekdays: String = "",
        intervalDays: Int? = nil,
        timeZoneBehavior: ScheduleTimeZoneBehavior = .floatingLocal,
        fixedTimeZoneIdentifier: String? = nil,
        reminderEnabled: Bool = false,
        defaultSnoozeMinutes: Int = 10,
        revision: Int = 1,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.regimenItemID = regimenItemID
        self.kindRawValue = kind.rawValue
        self.anchorYear = anchorDate.year
        self.anchorMonth = anchorDate.month
        self.anchorDay = anchorDate.day
        self.endYear = endDate?.year
        self.endMonth = endDate?.month
        self.endDay = endDate?.day
        self.localTimes = localTimes
        self.weekdays = weekdays
        self.intervalDays = intervalDays
        self.timeZoneBehaviorRawValue = timeZoneBehavior.rawValue
        self.fixedTimeZoneIdentifier = fixedTimeZoneIdentifier
        self.reminderEnabled = reminderEnabled
        self.defaultSnoozeMinutes = defaultSnoozeMinutes
        self.revision = revision
        self.createdAt = createdAt
    }
}

@Model
final class HistoricalTimeRecord {
    @Attribute(.unique) var recordKey: String
    var sourceRecordType: String
    var sourceRecordID: UUID
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
    var legacyAssociationID: UUID?
    var resolvedRegimenVersionID: UUID?
    var associationStateRawValue: String

    var historicalTimestamp: HistoricalTimestamp? {
        guard let date = try? CivilDateFact(year: localYear, month: localMonth, day: localDay),
              let time = try? HistoricalLocalTime(
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
            validatingInstant: instant,
            localDate: date,
            localTime: time,
            timeZoneIdentifier: timeZoneIdentifier,
            utcOffsetSeconds: utcOffsetSeconds,
            precision: precision,
            provenance: provenance
        )
    }

    init(
        sourceRecordType: String,
        sourceRecordID: UUID,
        timestamp: HistoricalTimestamp,
        legacyAssociationID: UUID?,
        resolvedRegimenVersionID: UUID?,
        associationState: HistoricalAssociationState
    ) {
        self.recordKey = sourceRecordType + ":" + sourceRecordID.uuidString.lowercased()
        self.sourceRecordType = sourceRecordType
        self.sourceRecordID = sourceRecordID
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
        self.legacyAssociationID = legacyAssociationID
        self.resolvedRegimenVersionID = resolvedRegimenVersionID
        self.associationStateRawValue = associationState.rawValue
    }
}

@Model
final class CoreTimeRegimenBackfillState {
    static let fixedKey = "v2-to-v3-time-regimen"

    @Attribute(.unique) var taskKey: String
    var assumedTimeZoneIdentifier: String
    var completedAt: Date?
    var updatedAt: Date

    init(
        taskKey: String = CoreTimeRegimenBackfillState.fixedKey,
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
