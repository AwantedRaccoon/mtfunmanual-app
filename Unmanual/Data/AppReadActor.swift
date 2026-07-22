import Foundation
import SwiftData
import SwiftUI

enum AppReadDescriptors {
    static func profiles(limit: Int = 2) -> FetchDescriptor<HRTProfile> {
        var descriptor = FetchDescriptor<HRTProfile>(sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = limit
        return descriptor
    }

    static func activeCountdowns(limit: Int = 2) -> FetchDescriptor<CountdownRecord> {
        var descriptor = FetchDescriptor<CountdownRecord>(
            predicate: #Predicate { $0.archivedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    static func regimens(limit: Int = 128) -> FetchDescriptor<RegimenVersion> {
        var descriptor = FetchDescriptor<RegimenVersion>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    static func journeyEntries(limit: Int = 32) -> FetchDescriptor<JourneyEntry> {
        var descriptor = FetchDescriptor<JourneyEntry>(
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    static func labRecords(limit: Int = 1_500) -> FetchDescriptor<LabRecord> {
        var descriptor = FetchDescriptor<LabRecord>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }
}

struct AppArchiveSnapshot: Equatable, Sendable {
    static let empty = AppArchiveSnapshot(
        journeyCount: 0,
        labRecordCount: 0,
        regimenCount: 0,
        profileCount: 0,
        countdownCount: 0,
        developmentExportItemCount: 0,
        firstActivityDate: nil,
        latestActivityDate: nil
    )

    let journeyCount: Int
    let labRecordCount: Int
    let regimenCount: Int
    let profileCount: Int
    let countdownCount: Int
    let developmentExportItemCount: Int
    let firstActivityDate: Date?
    let latestActivityDate: Date?

    var storedItemCount: Int {
        journeyCount + labRecordCount + regimenCount + profileCount + countdownCount
    }

    var supportingDateCount: Int { profileCount + countdownCount }
    var hasContent: Bool { storedItemCount > 0 }

    var rangeLabel: String {
        guard let firstActivityDate, let latestActivityDate else {
            return "还没有记录范围"
        }
        let first = firstActivityDate.formatted(.dateTime.year().month(.twoDigits))
        let latest = latestActivityDate.formatted(.dateTime.year().month(.twoDigits))
        return first == latest ? first : "\(first) — \(latest)"
    }

    var latestActivityLabel: String {
        guard let latestActivityDate else { return "等待第一笔" }
        return "更新至 " + latestActivityDate.formatted(.dateTime.month().day())
    }
}

struct HRTProfileSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let startDate: Date
    let activePeriodStartDate: Date
    let createdAt: Date
}

struct CountdownRecordSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let gentleTitle: String?
    let targetDate: Date
    let createdAt: Date
    let archivedAt: Date?
    let continuesCountingUp: Bool
}

struct RegimenVersionSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let code: String
    let title: String
    let startedAt: Date
    let endedAt: Date?
    let note: String
    let createdAt: Date
}

struct TodaySnapshot: Equatable, Sendable {
    static let empty = TodaySnapshot(
        profile: nil,
        countdown: nil,
        regimens: [],
        labRecords: [],
        entries: []
    )

    let profile: HRTProfileSnapshot?
    let countdown: CountdownRecordSnapshot?
    let regimens: [RegimenVersionSnapshot]
    let labRecords: [LabRecordSnapshot]
    let entries: [JourneyEntrySnapshot]
}

struct RegimenOverviewSnapshot: Equatable, Sendable {
    static let empty = RegimenOverviewSnapshot(regimens: [], labRecords: [])

    let regimens: [RegimenVersionSnapshot]
    let labRecords: [LabRecordSnapshot]
}

struct CoreRegimenItemSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let catalogProductID: String?
    let catalogVersion: String?
    let displayName: String
    let genericName: String
    let dosageForm: String
    let route: String
    let doseOriginal: String
    let unitOriginal: String
    let productSnapshot: String
    let schedule: CoreScheduleRuleSnapshot?
    let scheduleSummary: String
}

struct CoreScheduleRuleSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: ScheduleRuleKind
    let localTimes: String
    let weekdays: String
    let intervalDays: Int?
    let timeZoneBehavior: ScheduleTimeZoneBehavior
    let fixedTimeZoneIdentifier: String?
    let reminderEnabled: Bool
    let defaultSnoozeMinutes: Int

    func input(cloningIdentity: Bool) -> RegimenScheduleInput {
        RegimenScheduleInput(
            id: cloningIdentity ? UUID() : id,
            kind: kind,
            localTimes: localTimes,
            weekdays: weekdays,
            intervalDays: intervalDays,
            timeZoneBehavior: timeZoneBehavior,
            fixedTimeZoneIdentifier: fixedTimeZoneIdentifier,
            reminderEnabled: false,
            defaultSnoozeMinutes: defaultSnoozeMinutes
        )
    }
}

struct CoreRegimenVersionSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let code: String
    let title: String
    let effectiveStartDate: CivilDateFact
    let effectiveEndDate: CivilDateFact?
    let previousVersionID: UUID?
    let changeReason: String
    let editState: RegimenEditState
    let requiresReview: Bool
    let items: [CoreRegimenItemSnapshot]
}

struct CoreRegimenOverviewSnapshot: Equatable, Sendable {
    static let empty = CoreRegimenOverviewSnapshot(
        current: nil,
        upcoming: [],
        history: [],
        drafts: [],
        labRecords: [],
        reviewIssueCount: 0,
        isTimelineAmbiguous: false
    )

    let current: CoreRegimenVersionSnapshot?
    let upcoming: [CoreRegimenVersionSnapshot]
    let history: [CoreRegimenVersionSnapshot]
    let drafts: [CoreRegimenVersionSnapshot]
    let labRecords: [LabRecordSnapshot]
    let reviewIssueCount: Int
    let isTimelineAmbiguous: Bool

    var allVersions: [CoreRegimenVersionSnapshot] {
        ([current].compactMap { $0 } + upcoming + history + drafts)
            .reduce(into: [UUID: CoreRegimenVersionSnapshot]()) { $0[$1.id] = $1 }
            .values
            .sorted {
                $0.effectiveStartDate != $1.effectiveStartDate
                    ? $0.effectiveStartDate > $1.effectiveStartDate
                    : $0.id.uuidString > $1.id.uuidString
            }
    }
}

struct JourneyPageCursor: Equatable, Sendable {
    let occurredAt: Date
    let recordID: UUID
}

struct JourneyEntrySnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let kind: JourneyEntryKind
    let occurredAt: Date
    let historicalTimestamp: HistoricalTimestamp?
    let regimenVersionID: UUID?

    func recordedLocalDate(
        fallbackTimeZone: TimeZone = .autoupdatingCurrent
    ) -> CivilDateFact? {
        HistoricalDisplayDateResolver.localDate(
            canonicalTimestamp: historicalTimestamp,
            fallbackInstant: occurredAt,
            fallbackTimeZone: fallbackTimeZone
        )
    }

    var recordedShortDateText: String {
        recordedLocalDate()?.unmanualShortDateText ?? occurredAt.unmanualShortDateText
    }

    var recordedMonthDayText: String {
        recordedLocalDate()?.unmanualMonthDayText
            ?? occurredAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
    }

    var recordedWeekdayText: String {
        recordedLocalDate()?.unmanualWeekdayText
            ?? occurredAt.formatted(.dateTime.weekday(.abbreviated))
    }

    var recordedMonthDayWeekdayText: String {
        guard let date = recordedLocalDate() else {
            return occurredAt.formatted(.dateTime.month().day().weekday(.abbreviated))
        }
        return "\(date.month)月\(date.day)日 \(date.unmanualWeekdayText)"
    }

    var recordedFullDateText: String {
        recordedLocalDate()?.unmanualFullDateText
            ?? occurredAt.formatted(.dateTime.year().month().day())
    }
}

struct JourneyPage: Equatable, Sendable {
    let entries: [JourneyEntrySnapshot]
    let regimenCodes: [UUID: String]
    let nextCursor: JourneyPageCursor?
}

struct LabRecordSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let itemName: String
    let itemCode: String
    let rawValue: String
    let numericValue: Double
    let unit: String
    let sampledAt: Date
    let historicalTimestamp: HistoricalTimestamp?
    let referenceRangeOriginal: String?
    let contextNote: String
    let regimenVersionID: UUID?
    let createdAt: Date

    func recordedLocalDate(
        fallbackTimeZone: TimeZone = .autoupdatingCurrent
    ) -> CivilDateFact? {
        HistoricalDisplayDateResolver.localDate(
            canonicalTimestamp: historicalTimestamp,
            fallbackInstant: sampledAt,
            fallbackTimeZone: fallbackTimeZone
        )
    }

    var recordedShortDateText: String {
        recordedLocalDate()?.unmanualShortDateText ?? sampledAt.unmanualShortDateText
    }
}

enum HistoricalDisplayDateResolver {
    static func localDate(
        canonicalTimestamp: HistoricalTimestamp?,
        fallbackInstant: Date,
        fallbackTimeZone: TimeZone
    ) -> CivilDateFact? {
        if let canonicalTimestamp {
            return canonicalTimestamp.localDate
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = fallbackTimeZone
        let components = calendar.dateComponents([.year, .month, .day], from: fallbackInstant)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return nil
        }
        return try? CivilDateFact(year: year, month: month, day: day)
    }
}

@ModelActor
actor AppReadActor {
    func todaySnapshot() throws -> TodaySnapshot {
        let profiles = try modelContext.fetch(AppReadDescriptors.profiles(limit: 1))
        let countdowns = try modelContext.fetch(AppReadDescriptors.activeCountdowns(limit: 1))
        let regimens = try modelContext.fetch(AppReadDescriptors.regimens(limit: 32))
        let labRecords = try modelContext.fetch(AppReadDescriptors.labRecords(limit: 32))
        let entries = try modelContext.fetch(AppReadDescriptors.journeyEntries(limit: 8))

        return TodaySnapshot(
            profile: try canonicalProfileSnapshot(legacyProfile: profiles.first)
                ?? profiles.first.map(profileSnapshot),
            countdown: countdowns.first.map(countdownSnapshot),
            regimens: regimens.map(regimenSnapshot),
            labRecords: try labRecords.map {
                let historical = try canonicalHistoricalFacts(
                        sourceRecordType: "LabRecord",
                        sourceRecordID: $0.id,
                        fallback: $0.regimenVersionID
                    )
                return labSnapshot(
                    $0,
                    regimenVersionID: historical.regimenVersionID,
                    historicalTimestamp: historical.timestamp
                )
            },
            entries: try entries.map {
                let historical = try canonicalHistoricalFacts(
                        sourceRecordType: "JourneyEntry",
                        sourceRecordID: $0.id,
                        fallback: $0.regimenVersionID
                    )
                return journeySnapshot(
                    $0,
                    regimenVersionID: historical.regimenVersionID,
                    historicalTimestamp: historical.timestamp
                )
            }
        )
    }

    func regimenOverview() throws -> RegimenOverviewSnapshot {
        let regimens = try modelContext.fetch(AppReadDescriptors.regimens(limit: 128))
        let labRecords = try modelContext.fetch(AppReadDescriptors.labRecords(limit: 32))
        return RegimenOverviewSnapshot(
            regimens: regimens.map(regimenSnapshot),
            labRecords: try labRecords.map {
                let historical = try canonicalHistoricalFacts(
                        sourceRecordType: "LabRecord",
                        sourceRecordID: $0.id,
                        fallback: $0.regimenVersionID
                    )
                return labSnapshot(
                    $0,
                    regimenVersionID: historical.regimenVersionID,
                    historicalTimestamp: historical.timestamp
                )
            }
        )
    }

    func coreRegimenOverview(asOf date: CivilDateFact) throws -> CoreRegimenOverviewSnapshot {
        var recordDescriptor = FetchDescriptor<RegimenPlanVersionRecord>()
        recordDescriptor.fetchLimit = 513
        let fetchedRecords = try modelContext.fetch(recordDescriptor)
        guard fetchedRecords.count <= 512 else { throw AppDataFailure.corruptionSuspected }
        let records = fetchedRecords.filter { !$0.isArchived }
        var itemDescriptor = FetchDescriptor<RegimenItemRecord>()
        itemDescriptor.fetchLimit = 4_097
        let items = try modelContext.fetch(itemDescriptor)
        guard items.count <= 4_096 else { throw AppDataFailure.corruptionSuspected }
        var scheduleDescriptor = FetchDescriptor<ScheduleRuleRecord>()
        scheduleDescriptor.fetchLimit = 4_097
        let schedules = try modelContext.fetch(scheduleDescriptor)
        guard schedules.count <= 4_096 else { throw AppDataFailure.corruptionSuspected }
        let labRecords = try modelContext.fetch(AppReadDescriptors.labRecords(limit: 32))
        var issueDescriptor = FetchDescriptor<MigrationIssue>()
        issueDescriptor.fetchLimit = 1_025
        let issues = try modelContext.fetch(issueDescriptor)
        guard issues.count <= 1_024 else { throw AppDataFailure.corruptionSuspected }
        let timeline = records.compactMap { record -> RegimenTimelineVersion? in
            guard let start = record.effectiveStartDate else { return nil }
            return RegimenTimelineVersion(
                id: record.id,
                start: start,
                end: record.effectiveEndDate,
                editState: record.editState,
                requiresReview: record.requiresMigrationReview
            )
        }
        let projection = RegimenTimelineResolver.project(timeline, asOf: date)
        let scheduleByItemID = Dictionary(grouping: schedules, by: \.regimenItemID)
        let itemsByVersionID = Dictionary(grouping: items, by: \.regimenVersionID)
        let snapshots = records.compactMap { record -> CoreRegimenVersionSnapshot? in
            guard let start = record.effectiveStartDate else { return nil }
            let itemSnapshots = (itemsByVersionID[record.id] ?? [])
                .sorted {
                    $0.sortOrder != $1.sortOrder
                        ? $0.sortOrder < $1.sortOrder
                        : $0.id.uuidString < $1.id.uuidString
                }
                .map { item in
                    CoreRegimenItemSnapshot(
                        id: item.id,
                        catalogProductID: item.catalogProductID,
                        catalogVersion: item.catalogVersion,
                        displayName: item.displayName,
                        genericName: item.genericName,
                        dosageForm: item.dosageForm,
                        route: item.route,
                        doseOriginal: item.doseOriginal,
                        unitOriginal: item.unitOriginal,
                        productSnapshot: item.productSnapshot,
                        schedule: scheduleByItemID[item.id]?.first.map(scheduleSnapshot),
                        scheduleSummary: scheduleSummary(scheduleByItemID[item.id]?.first)
                    )
                }
            return CoreRegimenVersionSnapshot(
                id: record.id,
                code: record.code,
                title: record.title,
                effectiveStartDate: start,
                effectiveEndDate: record.effectiveEndDate,
                previousVersionID: record.previousVersionID,
                changeReason: record.changeReason,
                editState: record.editState,
                requiresReview: record.requiresMigrationReview,
                items: itemSnapshots
            )
        }
        let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        return CoreRegimenOverviewSnapshot(
            current: projection.current.flatMap { byID[$0.id] },
            upcoming: projection.upcoming.compactMap { byID[$0.id] },
            history: projection.history.reversed().compactMap { byID[$0.id] },
            drafts: snapshots
                .filter { $0.editState == .draft }
                .sorted { $0.effectiveStartDate > $1.effectiveStartDate },
            labRecords: try labRecords.map {
                let historical = try canonicalHistoricalFacts(
                        sourceRecordType: "LabRecord",
                        sourceRecordID: $0.id,
                        fallback: $0.regimenVersionID
                    )
                return labSnapshot(
                    $0,
                    regimenVersionID: historical.regimenVersionID,
                    historicalTimestamp: historical.timestamp
                )
            },
            reviewIssueCount: issues.filter {
                $0.kind == .overlappingCanonicalRegimen
                    || $0.kind == .missingCanonicalRegimenAssociation
                    || $0.kind == .ambiguousCanonicalRegimenAssociation
            }.count,
            isTimelineAmbiguous: projection.isAmbiguous
        )
    }

    func archiveSnapshot() throws -> AppArchiveSnapshot {
        let profileCount = try modelContext.fetchCount(FetchDescriptor<HRTProfile>())
        let countdownCount = try modelContext.fetchCount(FetchDescriptor<CountdownRecord>())
        let journeyCount = try modelContext.fetchCount(FetchDescriptor<JourneyEntry>())
        let legacyRegimenCount = try modelContext.fetchCount(FetchDescriptor<RegimenVersion>())
        let sealedState = RegimenEditState.sealed.rawValue
        let canonicalRegimenDescriptor = FetchDescriptor<RegimenPlanVersionRecord>(
            predicate: #Predicate {
                $0.editStateRawValue == sealedState && $0.isArchived == false
            }
        )
        let regimenCount = try modelContext.fetchCount(canonicalRegimenDescriptor)
        let labRecordCount = try modelContext.fetchCount(FetchDescriptor<LabRecord>())

        let extrema = try [
            profileExtremeDate(ascending: true),
            profileExtremeDate(ascending: false),
            journeyExtremeDate(ascending: true),
            journeyExtremeDate(ascending: false),
            canonicalRegimenExtremeDate(ascending: true),
            canonicalRegimenExtremeDate(ascending: false),
            labExtremeDate(ascending: true),
            labExtremeDate(ascending: false)
        ].compactMap { $0 }

        return AppArchiveSnapshot(
            journeyCount: journeyCount,
            labRecordCount: labRecordCount,
            regimenCount: regimenCount,
            profileCount: profileCount,
            countdownCount: countdownCount,
            developmentExportItemCount: profileCount
                + countdownCount
                + journeyCount
                + legacyRegimenCount
                + labRecordCount,
            firstActivityDate: extrema.min(),
            latestActivityDate: extrema.max()
        )
    }

    func journeyPage(after cursor: JourneyPageCursor?, limit: Int = 100) throws -> JourneyPage {
        precondition(limit > 0 && limit <= 200)
        var descriptor: FetchDescriptor<JourneyEntry>
        if let cursor {
            let occurredAt = cursor.occurredAt
            let recordID = cursor.recordID
            descriptor = FetchDescriptor<JourneyEntry>(
                predicate: #Predicate {
                    $0.occurredAt < occurredAt
                        || ($0.occurredAt == occurredAt && $0.id < recordID)
                },
                sortBy: [
                    SortDescriptor(\.occurredAt, order: .reverse),
                    SortDescriptor(\.id, order: .reverse)
                ]
            )
        } else {
            descriptor = FetchDescriptor<JourneyEntry>(
                sortBy: [
                    SortDescriptor(\.occurredAt, order: .reverse),
                    SortDescriptor(\.id, order: .reverse)
                ]
            )
        }
        descriptor.fetchLimit = limit + 1
        let selected = try modelContext.fetch(descriptor)
        let pageModels = Array(selected.prefix(limit))

        let entries = try pageModels.map {
            let historical = try canonicalHistoricalFacts(
                    sourceRecordType: "JourneyEntry",
                    sourceRecordID: $0.id,
                    fallback: $0.regimenVersionID
                )
            return journeySnapshot(
                $0,
                regimenVersionID: historical.regimenVersionID,
                historicalTimestamp: historical.timestamp
            )
        }

        var regimenCodes: [UUID: String] = [:]
        let referencedRegimenIDs = Set(entries.compactMap(\.regimenVersionID))
        for regimenID in referencedRegimenIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            var canonicalDescriptor = FetchDescriptor<RegimenPlanVersionRecord>(
                predicate: #Predicate { $0.id == regimenID }
            )
            canonicalDescriptor.fetchLimit = 1
            if let regimen = try modelContext.fetch(canonicalDescriptor).first {
                regimenCodes[regimen.id] = regimen.code
                continue
            }
            var legacyDescriptor = FetchDescriptor<RegimenVersion>(
                predicate: #Predicate { $0.id == regimenID }
            )
            legacyDescriptor.fetchLimit = 1
            if let regimen = try modelContext.fetch(legacyDescriptor).first {
                regimenCodes[regimen.id] = regimen.code
            }
        }
        let nextCursor: JourneyPageCursor?
        if selected.count > limit, let last = pageModels.last {
            nextCursor = JourneyPageCursor(occurredAt: last.occurredAt, recordID: last.id)
        } else {
            nextCursor = nil
        }
        return JourneyPage(entries: entries, regimenCodes: regimenCodes, nextCursor: nextCursor)
    }

    func labRecords(
        on localDate: CivilDateFact,
        fallbackTimeZone: TimeZone = .autoupdatingCurrent,
        limit: Int = 64
    ) throws -> [LabRecordSnapshot] {
        precondition(limit > 0 && limit <= 128)

        let sourceRecordType = "LabRecord"
        let targetYear = localDate.year
        let targetMonth = localDate.month
        let targetDay = localDate.day
        var canonicalDescriptor = FetchDescriptor<HistoricalTimeRecord>(
            predicate: #Predicate {
                $0.sourceRecordType == sourceRecordType
                    && $0.localYear == targetYear
                    && $0.localMonth == targetMonth
                    && $0.localDay == targetDay
            },
            sortBy: [SortDescriptor(\.instant, order: .reverse)]
        )
        canonicalDescriptor.fetchLimit = limit + 1
        let canonicalRecords = try modelContext.fetch(canonicalDescriptor)
        guard canonicalRecords.count <= limit else {
            throw AppDataFailure.corruptionSuspected
        }

        var snapshots: [LabRecordSnapshot] = []
        snapshots.reserveCapacity(canonicalRecords.count)
        var canonicalSourceIDs: Set<UUID> = []
        for historical in canonicalRecords {
            let canonical = try canonicalHistoricalFacts(
                sourceRecordType: sourceRecordType,
                sourceRecordID: historical.sourceRecordID,
                fallback: nil
            )
            guard canonicalSourceIDs.insert(historical.sourceRecordID).inserted else {
                throw AppDataFailure.corruptionSuspected
            }
            guard let timestamp = canonical.timestamp else {
                throw AppDataFailure.corruptionSuspected
            }
            let sourceID = historical.sourceRecordID
            var recordDescriptor = FetchDescriptor<LabRecord>(
                predicate: #Predicate { $0.id == sourceID }
            )
            recordDescriptor.fetchLimit = 2
            let records = try modelContext.fetch(recordDescriptor)
            guard records.count == 1, let record = records.first else {
                throw AppDataFailure.corruptionSuspected
            }
            snapshots.append(
                labSnapshot(
                    record,
                    regimenVersionID: canonical.regimenVersionID,
                    historicalTimestamp: timestamp
                )
            )
        }

        var fallbackCalendar = Calendar(identifier: .gregorian)
        fallbackCalendar.timeZone = fallbackTimeZone
        guard let dayStart = fallbackCalendar.date(
            from: DateComponents(
                year: localDate.year,
                month: localDate.month,
                day: localDate.day,
                hour: 0
            )
        ),
        let dayEnd = fallbackCalendar.date(byAdding: .day, value: 1, to: dayStart) else {
            throw AppDataFailure.corruptionSuspected
        }

        let legacyScanLimit = 1_024
        var legacyDescriptor = FetchDescriptor<LabRecord>(
            predicate: #Predicate { $0.sampledAt >= dayStart && $0.sampledAt < dayEnd },
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        legacyDescriptor.fetchLimit = legacyScanLimit + 1
        let legacyCandidates = try modelContext.fetch(legacyDescriptor)
        guard legacyCandidates.count <= legacyScanLimit else {
            throw AppDataFailure.corruptionSuspected
        }
        for record in legacyCandidates {
            let historical = try canonicalHistoricalFacts(
                sourceRecordType: sourceRecordType,
                sourceRecordID: record.id,
                fallback: record.regimenVersionID
            )
            guard historical.timestamp == nil else { continue }
            snapshots.append(
                labSnapshot(
                    record,
                    regimenVersionID: historical.regimenVersionID,
                    historicalTimestamp: nil
                )
            )
        }
        guard snapshots.count <= limit else {
            throw AppDataFailure.corruptionSuspected
        }
        return snapshots.sorted {
            $0.sampledAt != $1.sampledAt
                ? $0.sampledAt > $1.sampledAt
                : $0.id.uuidString > $1.id.uuidString
        }
    }

    private func profileSnapshot(_ profile: HRTProfile) -> HRTProfileSnapshot {
        HRTProfileSnapshot(
            id: profile.id,
            startDate: profile.startDate,
            activePeriodStartDate: profile.activePeriodStartDate,
            createdAt: profile.createdAt
        )
    }

    private func canonicalProfileSnapshot(
        legacyProfile: HRTProfile?
    ) throws -> HRTProfileSnapshot? {
        var profileDescriptor = FetchDescriptor<HrtJourneyProfileRecord>()
        profileDescriptor.fetchLimit = 2
        let profiles = try modelContext.fetch(profileDescriptor)
        guard profiles.count <= 1, let profile = profiles.first,
              let firstDate = profile.firstEverStartDate else {
            return nil
        }
        var periodDescriptor = FetchDescriptor<HrtPeriodRecord>()
        periodDescriptor.fetchLimit = 512
        let activePeriod = try modelContext.fetch(periodDescriptor)
            .filter { $0.endDate == nil }
            .sorted {
                guard let lhs = $0.startDate, let rhs = $1.startDate else {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return lhs != rhs ? lhs > rhs : $0.id.uuidString > $1.id.uuidString
            }
            .first
        let startDate = try displayDate(from: firstDate)
        let activeStart = try activePeriod?.startDate.map(displayDate) ?? startDate
        return HRTProfileSnapshot(
            id: legacyProfile?.id ?? CoreTimeRegimenBackfill.stableUUID(for: profile.singletonKey),
            startDate: startDate,
            activePeriodStartDate: activeStart,
            createdAt: profile.createdAt
        )
    }

    private func displayDate(from date: CivilDateFact) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        guard let value = calendar.date(
            from: DateComponents(year: date.year, month: date.month, day: date.day, hour: 12)
        ) else {
            throw AppDataFailure.corruptionSuspected
        }
        return value
    }

    private func countdownSnapshot(_ countdown: CountdownRecord) -> CountdownRecordSnapshot {
        CountdownRecordSnapshot(
            id: countdown.id,
            title: countdown.title,
            gentleTitle: countdown.gentleTitle,
            targetDate: countdown.targetDate,
            createdAt: countdown.createdAt,
            archivedAt: countdown.archivedAt,
            continuesCountingUp: countdown.continuesCountingUp
        )
    }

    private func regimenSnapshot(_ regimen: RegimenVersion) -> RegimenVersionSnapshot {
        RegimenVersionSnapshot(
            id: regimen.id,
            code: regimen.code,
            title: regimen.title,
            startedAt: regimen.startedAt,
            endedAt: regimen.endedAt,
            note: regimen.note,
            createdAt: regimen.createdAt
        )
    }

    private func scheduleSummary(_ schedule: ScheduleRuleRecord?) -> String {
        guard let schedule else { return "未设置时段" }
        switch schedule.kind {
        case .dailyTimes:
            return schedule.localTimes.isEmpty ? "每日" : schedule.localTimes
        case .weekly:
            return schedule.weekdays.isEmpty ? "每周" : schedule.weekdays
        case .everyNDays:
            return schedule.intervalDays.map { "每 \($0) 天" } ?? "按间隔"
        case .oneOff:
            return "单次"
        }
    }

    private func scheduleSnapshot(_ schedule: ScheduleRuleRecord) -> CoreScheduleRuleSnapshot {
        CoreScheduleRuleSnapshot(
            id: schedule.id,
            kind: schedule.kind,
            localTimes: schedule.localTimes,
            weekdays: schedule.weekdays,
            intervalDays: schedule.intervalDays,
            timeZoneBehavior: schedule.timeZoneBehavior,
            fixedTimeZoneIdentifier: schedule.fixedTimeZoneIdentifier,
            reminderEnabled: false,
            defaultSnoozeMinutes: schedule.defaultSnoozeMinutes
        )
    }

    private func canonicalHistoricalFacts(
        sourceRecordType: String,
        sourceRecordID: UUID,
        fallback: UUID?
    ) throws -> (regimenVersionID: UUID?, timestamp: HistoricalTimestamp?) {
        let recordKey = sourceRecordType + ":" + sourceRecordID.uuidString.lowercased()
        var descriptor = FetchDescriptor<HistoricalTimeRecord>(
            predicate: #Predicate {
                ($0.sourceRecordType == sourceRecordType
                    && $0.sourceRecordID == sourceRecordID)
                    || $0.recordKey == recordKey
            }
        )
        descriptor.fetchLimit = 2
        let matches = try modelContext.fetch(descriptor)
        guard matches.count <= 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        guard let historical = matches.first else {
            return (fallback, nil)
        }
        try validateHistoricalIdentity(
            historical,
            sourceRecordType: sourceRecordType,
            sourceRecordID: sourceRecordID
        )
        guard let timestamp = historical.historicalTimestamp else {
            throw AppDataFailure.corruptionSuspected
        }
        return (try canonicalAssociationID(for: historical), timestamp)
    }

    private func validateHistoricalIdentity(
        _ historical: HistoricalTimeRecord,
        sourceRecordType: String,
        sourceRecordID: UUID
    ) throws {
        let expectedRecordKey = sourceRecordType
            + ":"
            + sourceRecordID.uuidString.lowercased()
        guard historical.sourceRecordType == sourceRecordType,
              historical.sourceRecordID == sourceRecordID,
              historical.recordKey == expectedRecordKey else {
            throw AppDataFailure.corruptionSuspected
        }
    }

    private func canonicalAssociationID(
        for historical: HistoricalTimeRecord
    ) throws -> UUID? {
        guard let state = HistoricalAssociationState(
            rawValue: historical.associationStateRawValue
        ) else {
            throw AppDataFailure.corruptionSuspected
        }
        switch state {
        case .resolved:
            guard let resolved = historical.resolvedRegimenVersionID else {
                throw AppDataFailure.corruptionSuspected
            }
            return resolved
        case .missing, .ambiguous:
            guard historical.resolvedRegimenVersionID == nil else {
                throw AppDataFailure.corruptionSuspected
            }
            return nil
        }
    }

    private func journeySnapshot(
        _ entry: JourneyEntry,
        regimenVersionID: UUID?,
        historicalTimestamp: HistoricalTimestamp?
    ) -> JourneyEntrySnapshot {
        JourneyEntrySnapshot(
            id: entry.id,
            text: entry.text,
            kind: entry.kind,
            occurredAt: entry.occurredAt,
            historicalTimestamp: historicalTimestamp,
            regimenVersionID: regimenVersionID
        )
    }

    private func labSnapshot(
        _ record: LabRecord,
        regimenVersionID: UUID?,
        historicalTimestamp: HistoricalTimestamp?
    ) -> LabRecordSnapshot {
        LabRecordSnapshot(
            id: record.id,
            itemName: record.itemName,
            itemCode: record.itemCode,
            rawValue: record.rawValue,
            numericValue: record.numericValue,
            unit: record.unit,
            sampledAt: record.sampledAt,
            historicalTimestamp: historicalTimestamp,
            referenceRangeOriginal: record.referenceRangeOriginal,
            contextNote: record.contextNote,
            regimenVersionID: regimenVersionID,
            createdAt: record.createdAt
        )
    }

    private func profileExtremeDate(ascending: Bool) throws -> Date? {
        var descriptor = FetchDescriptor<HRTProfile>(
            sortBy: [SortDescriptor(\.startDate, order: ascending ? .forward : .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.startDate
    }

    private func journeyExtremeDate(ascending: Bool) throws -> Date? {
        var descriptor = FetchDescriptor<JourneyEntry>(
            sortBy: [SortDescriptor(\.occurredAt, order: ascending ? .forward : .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.occurredAt
    }

    private func canonicalRegimenExtremeDate(ascending: Bool) throws -> Date? {
        let sealedState = RegimenEditState.sealed.rawValue
        let order: SortOrder = ascending ? .forward : .reverse
        var descriptor = FetchDescriptor<RegimenPlanVersionRecord>(
            predicate: #Predicate {
                $0.editStateRawValue == sealedState && $0.isArchived == false
            },
            sortBy: [
                SortDescriptor(\.effectiveStartYear, order: order),
                SortDescriptor(\.effectiveStartMonth, order: order),
                SortDescriptor(\.effectiveStartDay, order: order)
            ]
        )
        descriptor.fetchLimit = 1
        guard let regimen = try modelContext.fetch(descriptor).first else {
            return nil
        }
        guard let startDate = regimen.effectiveStartDate else {
            throw AppDataFailure.corruptionSuspected
        }
        return try displayDate(from: startDate)
    }

    private func labExtremeDate(ascending: Bool) throws -> Date? {
        var descriptor = FetchDescriptor<LabRecord>(
            sortBy: [SortDescriptor(\.sampledAt, order: ascending ? .forward : .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.sampledAt
    }
}

private struct AppReadActorEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppReadActor? = nil
}

extension EnvironmentValues {
    var appReadActor: AppReadActor? {
        get { self[AppReadActorEnvironmentKey.self] }
        set { self[AppReadActorEnvironmentKey.self] = newValue }
    }
}
