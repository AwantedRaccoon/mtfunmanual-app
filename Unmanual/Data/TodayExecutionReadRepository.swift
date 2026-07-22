import Foundation
import SwiftData

enum TodayExecutionState: String, Equatable, Sendable {
    case unrecorded
    case taken
    case skipped
}

struct TodayExecutionItemSnapshot: Identifiable, Equatable, Sendable {
    var id: String { occurrence.key }

    let occurrence: PlannedOccurrence
    let state: TodayExecutionState
    let effectiveEventID: UUID?
    let actualTimestamp: HistoricalTimestamp?
    let effectiveOverrideID: UUID?
    let snoozedUntil: Date?
    let reminderEnabled: Bool
    let defaultSnoozeMinutes: Int
}

struct NotificationCoverageSnapshot: Equatable, Sendable {
    let status: NotificationCoverageStatus
    let scheduledThrough: Date?
    let desiredCount: Int
    let confirmedPendingCount: Int
    let lastErrorCode: String?
    let observedAt: Date
}

struct TodayExecutionSnapshot: Equatable, Sendable {
    static let empty = TodayExecutionSnapshot(
        items: [],
        coverage: NotificationCoverageSnapshot(
            status: .staleObservation,
            scheduledThrough: nil,
            desiredCount: 0,
            confirmedPendingCount: 0,
            lastErrorCode: nil,
            observedAt: .distantPast
        ),
        reviewIssues: []
    )

    let items: [TodayExecutionItemSnapshot]
    let coverage: NotificationCoverageSnapshot
    let reviewIssues: [ScheduleOccurrenceIssue]
}

struct ReminderPlanningSnapshot: Equatable, Sendable {
    let candidates: [LocalReminderCandidate]
    let hasEnabledIntent: Bool
}

private struct TodayExecutionProjection {
    let items: [TodayExecutionItemSnapshot]
    let issues: [ScheduleOccurrenceIssue]
    let hasEnabledIntent: Bool
}

extension AppReadActor {
    func todayExecutionSnapshot(
        now: Date,
        displayTimeZoneIdentifier: String
    ) throws -> TodayExecutionSnapshot {
        guard let displayZone = TimeZone(identifier: displayTimeZoneIdentifier) else {
            throw HistoricalTimeError.unknownTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = displayZone
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw AppDataFailure.corruptionSuspected
        }
        let projection = try executionProjection(
            interval: DateInterval(start: start, end: end),
            displayTimeZoneIdentifier: displayTimeZoneIdentifier
        )
        return TodayExecutionSnapshot(
            items: projection.items,
            coverage: try notificationCoverageSnapshot(),
            reviewIssues: projection.issues
        )
    }

    func reminderPlanningCandidates(
        now: Date,
        displayTimeZoneIdentifier: String,
        horizonLocalDays: Int = 14
    ) throws -> [LocalReminderCandidate] {
        try reminderPlanningSnapshot(
            now: now,
            displayTimeZoneIdentifier: displayTimeZoneIdentifier,
            horizonLocalDays: horizonLocalDays
        ).candidates
    }

    func reminderPlanningSnapshot(
        now: Date,
        displayTimeZoneIdentifier: String,
        horizonLocalDays: Int = 14
    ) throws -> ReminderPlanningSnapshot {
        guard (1...31).contains(horizonLocalDays),
              let displayZone = TimeZone(identifier: displayTimeZoneIdentifier) else {
            throw HistoricalTimeError.unknownTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = displayZone
        let startOfToday = calendar.startOfDay(for: now)
        guard let lookbackStart = calendar.date(
            byAdding: .day,
            value: -1,
            to: startOfToday
        ), let end = calendar.date(
            byAdding: .day,
            value: horizonLocalDays,
            to: startOfToday
        ) else {
            throw AppDataFailure.corruptionSuspected
        }
        let projection = try executionProjection(
            interval: DateInterval(start: lookbackStart, end: end),
            displayTimeZoneIdentifier: displayTimeZoneIdentifier
        )
        let candidates = projection.items.compactMap { item -> LocalReminderCandidate? in
            guard item.occurrence.instant > now || item.snoozedUntil.map({ $0 > now }) == true else {
                return nil
            }
            return LocalReminderCandidate(
                occurrence: item.occurrence,
                state: item.state,
                isEnabled: item.reminderEnabled,
                snoozedUntil: item.snoozedUntil
            )
        }
        return ReminderPlanningSnapshot(
            candidates: candidates,
            hasEnabledIntent: projection.hasEnabledIntent
        )
    }

    private func executionProjection(
        interval: DateInterval,
        displayTimeZoneIdentifier: String
    ) throws -> TodayExecutionProjection {
        let versionRecords = try boundedFetch(
            FetchDescriptor<RegimenPlanVersionRecord>(),
            limit: 512
        )
            .filter {
                $0.editState == .sealed && !$0.isArchived && !$0.requiresMigrationReview
            }
        let timeline = versionRecords.compactMap { record -> RegimenTimelineVersion? in
            guard let start = record.effectiveStartDate else { return nil }
            return RegimenTimelineVersion(
                id: record.id,
                start: start,
                end: record.effectiveEndDate,
                editState: record.editState,
                requiresReview: record.requiresMigrationReview
            )
        }
        guard timeline.count == versionRecords.count,
              let normalizedTimeline = RegimenTimelineResolver.normalizedEligibleTimeline(timeline)
        else {
            throw AppDataFailure.corruptionSuspected
        }
        let items = try boundedFetch(FetchDescriptor<RegimenItemRecord>(), limit: 4_096)
        let rules = try boundedFetch(FetchDescriptor<ScheduleRuleRecord>(), limit: 4_096)
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let versionRecordsByID = Dictionary(
            uniqueKeysWithValues: versionRecords.map { ($0.id, $0) }
        )
        let timelineByID = Dictionary(
            uniqueKeysWithValues: normalizedTimeline.map { ($0.id, $0) }
        )
        var specs: [ScheduleRuleSpec] = []
        var issues: [ScheduleOccurrenceIssue] = []

        for rule in rules {
            guard let item = itemsByID[rule.regimenItemID],
                  let version = versionRecordsByID[item.regimenVersionID],
                  timelineByID[version.id] != nil else {
                continue
            }
            guard let kind = ScheduleRuleKind(rawValue: rule.kindRawValue),
                  let behavior = ScheduleTimeZoneBehavior(rawValue: rule.timeZoneBehaviorRawValue),
                  let anchor = try? CivilDateFact(
                    year: rule.anchorYear,
                    month: rule.anchorMonth,
                    day: rule.anchorDay
                  ) else {
                issues.append(.invalidRule(rule.id))
                continue
            }
            let endDate: CivilDateFact?
            if let year = rule.endYear,
               let month = rule.endMonth,
               let day = rule.endDay {
                guard let parsed = try? CivilDateFact(year: year, month: month, day: day) else {
                    issues.append(.invalidRule(rule.id))
                    continue
                }
                endDate = parsed
            } else {
                guard rule.endYear == nil, rule.endMonth == nil, rule.endDay == nil else {
                    issues.append(.invalidRule(rule.id))
                    continue
                }
                endDate = nil
            }
            specs.append(
                ScheduleRuleSpec(
                    id: rule.id,
                    regimenVersionID: version.id,
                    regimenItemID: item.id,
                    displayName: item.displayName,
                    kind: kind,
                    anchorDate: anchor,
                    endDate: endDate,
                    localTimes: rule.localTimes,
                    weekdays: rule.weekdays,
                    intervalDays: rule.intervalDays,
                    timeZoneBehavior: behavior,
                    fixedTimeZoneIdentifier: rule.fixedTimeZoneIdentifier,
                    revision: rule.revision
                )
            )
        }

        let resolution = try ScheduleOccurrenceResolver.occurrences(
            rules: specs,
            interval: interval,
            displayTimeZoneIdentifier: displayTimeZoneIdentifier
        )
        issues.append(contentsOf: resolution.issues)
        let eligibleOccurrences = resolution.occurrences.filter { occurrence in
            guard let version = timelineByID[occurrence.regimenVersionID] else { return false }
            return version.contains(occurrence.localDate)
        }

        let intervalStart = interval.start
        let intervalEnd = interval.end
        let allEvents = try boundedFetch(
            FetchDescriptor<AdministrationEventRecord>(
                predicate: #Predicate {
                    $0.plannedInstant >= intervalStart && $0.plannedInstant < intervalEnd
                }
            ),
            limit: 8_192
        )
        let eventsByKey = Dictionary(grouping: allEvents, by: \.occurrenceKey)
        let allOverrides = try boundedFetch(
            FetchDescriptor<ReminderOverrideRecord>(
                predicate: #Predicate {
                    $0.plannedInstant >= intervalStart && $0.plannedInstant < intervalEnd
                }
            ),
            limit: 8_192
        )
        let overridesByKey = Dictionary(grouping: allOverrides, by: \.occurrenceKey)
        let preferences = try boundedFetch(
            FetchDescriptor<ReminderPreferenceRecord>(),
            limit: 4_096
        )
        let preferenceByKey = Dictionary(uniqueKeysWithValues: preferences.map {
            ($0.preferenceKey, $0)
        })
        let validPreferenceKeys = Set(specs.map {
            ReminderPreferenceRecord.key(scheduleRuleID: $0.id, revision: $0.revision)
        })
        let hasEnabledIntent = preferences.contains {
            $0.isEnabled && validPreferenceKeys.contains($0.preferenceKey)
        }

        let snapshots = try eligibleOccurrences.map { occurrence in
            let leaf = try effectiveAdministrationLeaf(eventsByKey[occurrence.key] ?? [])
            let override = try effectiveOverrideLeaf(overridesByKey[occurrence.key] ?? [])
            let timestamp: HistoricalTimestamp?
            if let leaf {
                let key = "AdministrationEventRecord:" + leaf.id.uuidString.lowercased()
                var descriptor = FetchDescriptor<HistoricalTimeRecord>(
                    predicate: #Predicate { $0.recordKey == key }
                )
                descriptor.fetchLimit = 2
                let values = try modelContext.fetch(descriptor)
                guard values.count == 1,
                      let value = values.first?.historicalTimestamp else {
                    throw AppDataFailure.corruptionSuspected
                }
                timestamp = value
            } else {
                timestamp = nil
            }
            let preferenceKey = ReminderPreferenceRecord.key(
                scheduleRuleID: occurrence.scheduleRuleID,
                revision: occurrence.scheduleRevision
            )
            let preference = preferenceByKey[preferenceKey]
            let state: TodayExecutionState = switch leaf?.status {
            case .taken: .taken
            case .skipped: .skipped
            case nil: .unrecorded
            }
            return TodayExecutionItemSnapshot(
                occurrence: occurrence,
                state: state,
                effectiveEventID: leaf?.id,
                actualTimestamp: timestamp,
                effectiveOverrideID: override?.id,
                snoozedUntil: override?.fireAt,
                reminderEnabled: preference?.isEnabled ?? false,
                defaultSnoozeMinutes: preference?.defaultSnoozeMinutes ?? 10
            )
        }
        return TodayExecutionProjection(
            items: snapshots,
            issues: issues,
            hasEnabledIntent: hasEnabledIntent
        )
    }

    private func notificationCoverageSnapshot() throws -> NotificationCoverageSnapshot {
        var descriptor = FetchDescriptor<NotificationCoverageRecord>()
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count == 1,
              let record = records.first,
              let status = record.status else {
            throw AppDataFailure.corruptionSuspected
        }
        return NotificationCoverageSnapshot(
            status: status,
            scheduledThrough: record.scheduledThrough,
            desiredCount: record.desiredCount,
            confirmedPendingCount: record.confirmedPendingCount,
            lastErrorCode: record.lastErrorCode,
            observedAt: record.observedAt
        )
    }

    private func effectiveAdministrationLeaf(
        _ records: [AdministrationEventRecord]
    ) throws -> AdministrationEventRecord? {
        guard records.allSatisfy({ $0.status != nil }),
              SupersessionChainValidator.formsSingleChain(
                records.map {
                    SupersessionLink(id: $0.id, predecessorID: $0.supersedesEventID)
                }
              ) else {
            throw AppDataFailure.corruptionSuspected
        }
        let superseded = Set(records.compactMap(\.supersedesEventID))
        return records.first { !superseded.contains($0.id) }
    }

    private func effectiveOverrideLeaf(
        _ records: [ReminderOverrideRecord]
    ) throws -> ReminderOverrideRecord? {
        guard SupersessionChainValidator.formsSingleChain(
            records.map {
                SupersessionLink(id: $0.id, predecessorID: $0.supersedesOverrideID)
            }
        ) else {
            throw AppDataFailure.corruptionSuspected
        }
        let superseded = Set(records.compactMap(\.supersedesOverrideID))
        return records.first { !superseded.contains($0.id) }
    }

    private func boundedFetch<T: PersistentModel>(
        _ input: FetchDescriptor<T>,
        limit: Int
    ) throws -> [T] {
        var descriptor = input
        descriptor.fetchLimit = limit + 1
        let records = try modelContext.fetch(descriptor)
        guard records.count <= limit else {
            throw AppDataFailure.corruptionSuspected
        }
        return records
    }
}
