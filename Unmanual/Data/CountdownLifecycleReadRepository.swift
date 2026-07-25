import Foundation
import SwiftData

struct CountdownReminderSnapshot: Equatable, Sendable {
    let isEnabled: Bool
    let leadDays: Int
    let localHour: Int
    let localMinute: Int
    let contentVersion: String
}

struct GentleModeSnapshot: Equatable, Sendable {
    let isEnabled: Bool
}

struct CountdownEditorSnapshot: Equatable, Sendable {
    let current: CountdownCurrentSnapshot?
    let gentleModeEnabled: Bool
}

struct CountdownReminderCoverageSnapshot: Equatable, Sendable {
    let countdownID: UUID?
    let status: NotificationCoverageStatus
    let scheduledFireAt: Date?
    let desiredCount: Int
    let confirmedPendingCount: Int
    let lastErrorCode: String?
    let observedAt: Date
}

struct CountdownTerminalReminderSnapshot: Equatable, Sendable {
    let wasEnabled: Bool
    let leadDays: Int
    let localHour: Int
    let localMinute: Int
}

struct CountdownCurrentSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let gentleTitle: String?
    let displayTitle: String
    let gentleModeEnabled: Bool
    let targetDate: CivilDateFact
    let displayTargetDate: Date
    let lifecycle: CountdownLifecycle
    let overdueMode: CountdownOverdueMode
    let showInToday: Bool
    let latestEventID: UUID
    let completedAt: Date?
    let archivedAt: Date?
    let requiresReview: Bool
    let reminder: CountdownReminderSnapshot
    let coverage: CountdownReminderCoverageSnapshot
    let terminalReminder: CountdownTerminalReminderSnapshot?
    let createdAt: Date
    let updatedAt: Date
}

struct CountdownLedgerPage: Equatable, Sendable {
    let items: [CountdownCurrentSnapshot]
    let nextCursor: CountdownLedgerCursor?
    let activeReviewCount: Int
}

enum CountdownLedgerKind: Equatable, Sendable {
    case history
    case review
}

struct CountdownLedgerCursor: Equatable, Sendable {
    let kind: CountdownLedgerKind
    let sortDate: Date
    let recordID: UUID
}

struct CountdownTodaySnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayTitle: String
    let targetDate: CivilDateFact
    let displayTargetDate: Date
    let dayState: CountdownDayState
}

struct CountdownEventSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: CountdownLifecycleEventKind
    let previousEventID: UUID?
    let oldTargetDate: CivilDateFact?
    let newTargetDate: CivilDateFact?
    let replacementCountdownID: UUID?
    let timestamp: HistoricalTimestamp
}

struct CountdownDetailSnapshot: Equatable, Sendable {
    let current: CountdownCurrentSnapshot
    let events: [CountdownEventSnapshot]
}

extension AppReadActor {
    func gentleModeSnapshot() throws -> GentleModeSnapshot {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "-unmanual-gentle-mode-read-error"
        ) {
            throw AppDataFailure.corruptionSuspected
        }
#endif
        return GentleModeSnapshot(
            isEnabled: try countdownGentleModeEnabled()
        )
    }

    func countdownEditorSnapshot(
        displayTimeZoneIdentifier: String =
            TimeZone.autoupdatingCurrent.identifier
    ) throws -> CountdownEditorSnapshot {
        let gentleModeEnabled = try countdownGentleModeEnabled()
        return CountdownEditorSnapshot(
            current: try countdownCurrentSnapshot(
                displayTimeZoneIdentifier:
                    displayTimeZoneIdentifier
            ),
            gentleModeEnabled: gentleModeEnabled
        )
    }

    func countdownCurrentSnapshot(
        displayTimeZoneIdentifier: String = TimeZone.autoupdatingCurrent.identifier
    ) throws -> CountdownCurrentSnapshot? {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "-unmanual-countdown-read-error"
        ) {
            throw AppDataFailure.corruptionSuspected
        }
#endif
        let activeValue = CountdownLifecycle.active.rawValue
        var descriptor = FetchDescriptor<CountdownStateRecord>(
            predicate: #Predicate {
                $0.lifecycleRawValue == activeValue && !$0.requiresReview
            }
        )
        descriptor.fetchLimit = 2
        let active = try modelContext.fetch(descriptor)
        guard active.count <= 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        guard let state = active.first else { return nil }
        return try countdownSnapshot(
            state,
            displayTimeZoneIdentifier: displayTimeZoneIdentifier,
            gentleModeEnabled: try countdownGentleModeEnabled()
        )
    }

    func countdownTodaySnapshot(
        today: CivilDateFact,
        displayTimeZoneIdentifier: String
    ) throws -> CountdownTodaySnapshot? {
        guard let current = try countdownCurrentSnapshot(
            displayTimeZoneIdentifier: displayTimeZoneIdentifier
        ),
        current.showInToday else {
            return nil
        }
        return CountdownTodaySnapshot(
            id: current.id,
            displayTitle: current.displayTitle,
            targetDate: current.targetDate,
            displayTargetDate: current.displayTargetDate,
            dayState: try CountdownDayProjection.resolve(
                target: current.targetDate,
                today: today,
                overdueMode: current.overdueMode
            )
        )
    }

    func countdownHistoryPage(
        after cursor: CountdownLedgerCursor? = nil,
        limit: Int,
        displayTimeZoneIdentifier: String = TimeZone.autoupdatingCurrent.identifier
    ) throws -> CountdownLedgerPage {
        guard (1...50).contains(limit),
              cursor == nil || (
                  cursor?.kind == .history
                      && cursor?.sortDate.timeIntervalSince1970
                        .isFinite == true
              ) else {
            throw AppDataFailure.corruptionSuspected
        }
        let completed = CountdownLifecycle.completed.rawValue
        let archived = CountdownLifecycle.archived.rawValue
        var descriptor: FetchDescriptor<CountdownStateRecord>
        if let cursor {
            let sortDate = cursor.sortDate
            let recordID = cursor.recordID
            descriptor = FetchDescriptor<CountdownStateRecord>(
                predicate: #Predicate {
                    (
                        $0.lifecycleRawValue == completed
                            || $0.lifecycleRawValue == archived
                    )
                        && !$0.requiresReview
                        && $0.archivedAt != nil
                        && (
                            ($0.archivedAt ?? sortDate) < sortDate
                                || (
                                    $0.archivedAt == sortDate
                                        && $0.id > recordID
                                )
                        )
                },
                sortBy: [
                    SortDescriptor(\.archivedAt, order: .reverse),
                    SortDescriptor(\.id)
                ]
            )
        } else {
            descriptor = FetchDescriptor<CountdownStateRecord>(
                predicate: #Predicate {
                    (
                        $0.lifecycleRawValue == completed
                            || $0.lifecycleRawValue == archived
                    )
                        && !$0.requiresReview
                        && $0.archivedAt != nil
                },
                sortBy: [
                    SortDescriptor(\.archivedAt, order: .reverse),
                    SortDescriptor(\.id)
                ]
            )
        }
        descriptor.fetchLimit = limit + 1
        let selected = try modelContext.fetch(descriptor)
        let records = Array(selected.prefix(limit))
        let gentleModeEnabled = try countdownGentleModeEnabled()
        return CountdownLedgerPage(
            items: try records.map {
                try countdownSnapshot(
                    $0,
                    displayTimeZoneIdentifier: displayTimeZoneIdentifier,
                    gentleModeEnabled: gentleModeEnabled
                )
            },
            nextCursor: selected.count > limit
                ? records.last.flatMap {
                    guard let sortDate = $0.archivedAt else { return nil }
                    return CountdownLedgerCursor(
                        kind: .history,
                        sortDate: sortDate,
                        recordID: $0.id
                    )
                }
                : nil,
            activeReviewCount: 0
        )
    }

    func countdownReviewPage(
        after cursor: CountdownLedgerCursor? = nil,
        limit: Int,
        displayTimeZoneIdentifier: String = TimeZone.autoupdatingCurrent.identifier
    ) throws -> CountdownLedgerPage {
        guard (1...50).contains(limit),
              cursor == nil || (
                  cursor?.kind == .review
                      && cursor?.sortDate.timeIntervalSince1970
                        .isFinite == true
              ) else {
            throw AppDataFailure.corruptionSuspected
        }
        let deleted = CountdownLifecycle.deleted.rawValue
        var descriptor: FetchDescriptor<CountdownStateRecord>
        if let cursor {
            let sortDate = cursor.sortDate
            let recordID = cursor.recordID
            descriptor = FetchDescriptor<CountdownStateRecord>(
                predicate: #Predicate {
                    $0.requiresReview
                        && $0.lifecycleRawValue != deleted
                        && (
                            $0.createdAt > sortDate
                                || (
                                    $0.createdAt == sortDate
                                        && $0.id > recordID
                                )
                        )
                },
                sortBy: [
                    SortDescriptor(\.createdAt),
                    SortDescriptor(\.id)
                ]
            )
        } else {
            descriptor = FetchDescriptor<CountdownStateRecord>(
                predicate: #Predicate {
                    $0.requiresReview && $0.lifecycleRawValue != deleted
                },
                sortBy: [
                    SortDescriptor(\.createdAt),
                    SortDescriptor(\.id)
                ]
            )
        }
        descriptor.fetchLimit = limit + 1
        let selected = try modelContext.fetch(descriptor)
        let records = Array(selected.prefix(limit))
        let active = CountdownLifecycle.active.rawValue
        let activeReviewCount = try modelContext.fetchCount(
            FetchDescriptor<CountdownStateRecord>(
                predicate: #Predicate {
                    $0.requiresReview && $0.lifecycleRawValue == active
                }
            )
        )
        let gentleModeEnabled = try countdownGentleModeEnabled()
        return CountdownLedgerPage(
            items: try records.map {
                try countdownSnapshot(
                    $0,
                    displayTimeZoneIdentifier: displayTimeZoneIdentifier,
                    gentleModeEnabled: gentleModeEnabled
                )
            },
            nextCursor: selected.count > limit
                ? records.last.map {
                    CountdownLedgerCursor(
                        kind: .review,
                        sortDate: $0.createdAt,
                        recordID: $0.id
                    )
                }
                : nil,
            activeReviewCount: activeReviewCount
        )
    }

    func countdownDetail(
        id: UUID,
        displayTimeZoneIdentifier: String = TimeZone.autoupdatingCurrent.identifier
    ) throws -> CountdownDetailSnapshot? {
        var stateDescriptor = FetchDescriptor<CountdownStateRecord>(
            predicate: #Predicate { $0.id == id }
        )
        stateDescriptor.fetchLimit = 2
        let states = try modelContext.fetch(stateDescriptor)
        guard states.count <= 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        guard let state = states.first, state.lifecycle != .deleted else {
            return nil
        }
        var descriptor = FetchDescriptor<CountdownLifecycleEventRecord>(
            predicate: #Predicate { $0.countdownID == id }
        )
        descriptor.fetchLimit = 4_097
        let records = try modelContext.fetch(descriptor)
        guard !records.isEmpty, records.count <= 4_096 else {
            throw AppDataFailure.corruptionSuspected
        }
        let byID = try AppDataIndex.checkedUniqueMap(
            records,
            keyedBy: \.id,
            failure: .corruptionSuspected
        )
        var reversed: [CountdownLifecycleEventRecord] = []
        var visited: Set<UUID> = []
        var cursor: UUID? = state.latestEventID
        while let eventID = cursor {
            guard visited.insert(eventID).inserted,
                  let event = byID[eventID],
                  event.countdownID == state.id else {
                throw AppDataFailure.corruptionSuspected
            }
            reversed.append(event)
            cursor = event.previousEventID
        }
        guard visited.count == records.count else {
            throw AppDataFailure.corruptionSuspected
        }
        let events = try reversed.reversed().map { record in
            guard let kind = record.kind,
                  let timestamp = record.historicalTimestamp else {
                throw AppDataFailure.corruptionSuspected
            }
            return CountdownEventSnapshot(
                id: record.id,
                kind: kind,
                previousEventID: record.previousEventID,
                oldTargetDate: record.oldTargetDate,
                newTargetDate: record.newTargetDate,
                replacementCountdownID: record.replacementCountdownID,
                timestamp: timestamp
            )
        }
        return CountdownDetailSnapshot(
            current: try countdownSnapshot(
                state,
                displayTimeZoneIdentifier: displayTimeZoneIdentifier,
                gentleModeEnabled: try countdownGentleModeEnabled()
            ),
            events: events
        )
    }

    private func countdownSnapshot(
        _ state: CountdownStateRecord,
        displayTimeZoneIdentifier: String,
        gentleModeEnabled: Bool
    ) throws -> CountdownCurrentSnapshot {
        guard let targetDate = state.targetDate,
              let lifecycle = state.lifecycle,
              lifecycle != .deleted,
              let overdueMode = state.overdueMode,
              !state.title.isEmpty else {
            throw AppDataFailure.corruptionSuspected
        }
        let terminalReminder: CountdownTerminalReminderSnapshot?
        if lifecycle == .completed || lifecycle == .archived {
            guard let wasEnabled = state.terminalReminderWasEnabled,
                  let leadDays = state.terminalReminderLeadDays,
                  let localHour = state.terminalReminderLocalHour,
                  let localMinute = state.terminalReminderLocalMinute,
                  (0...365).contains(leadDays),
                  (0...23).contains(localHour),
                  (0...59).contains(localMinute) else {
                throw AppDataFailure.corruptionSuspected
            }
            terminalReminder = CountdownTerminalReminderSnapshot(
                wasEnabled: wasEnabled,
                leadDays: leadDays,
                localHour: localHour,
                localMinute: localMinute
            )
        } else {
            terminalReminder = nil
        }
        let countdownID = state.id
        var descriptor = FetchDescriptor<CountdownReminderRuleRecord>(
            predicate: #Predicate { $0.countdownID == countdownID }
        )
        descriptor.fetchLimit = 2
        let reminders = try modelContext.fetch(descriptor)
        guard reminders.count == 1,
              let reminder = reminders.first,
              reminder.timeZoneBehavior == .floatingLocalV1,
              reminder.contentVersion == "neutralV1" else {
            throw AppDataFailure.corruptionSuspected
        }
        return CountdownCurrentSnapshot(
            id: state.id,
            title: state.title,
            gentleTitle: state.gentleTitle,
            displayTitle: gentleModeEnabled
                ? state.gentleTitle.flatMap {
                    $0.isEmpty ? nil : $0
                } ?? "私人日期"
                : state.title,
            gentleModeEnabled: gentleModeEnabled,
            targetDate: targetDate,
            displayTargetDate: try countdownDisplayDate(
                targetDate,
                timeZoneIdentifier: displayTimeZoneIdentifier
            ),
            lifecycle: lifecycle,
            overdueMode: overdueMode,
            showInToday: state.showInToday,
            latestEventID: state.latestEventID,
            completedAt: state.completedAt,
            archivedAt: state.archivedAt,
            requiresReview: state.requiresReview,
            reminder: CountdownReminderSnapshot(
                isEnabled: reminder.isEnabled,
                leadDays: reminder.leadDays,
                localHour: reminder.localHour,
                localMinute: reminder.localMinute,
                contentVersion: reminder.contentVersion
            ),
            coverage: try countdownCoverageSnapshot(for: state),
            terminalReminder: terminalReminder,
            createdAt: state.createdAt,
            updatedAt: state.updatedAt
        )
    }

    private func countdownCoverageSnapshot(
        for state: CountdownStateRecord
    ) throws -> CountdownReminderCoverageSnapshot {
        guard state.lifecycle == .active else {
            return CountdownReminderCoverageSnapshot(
                countdownID: nil,
                status: .disabledByUser,
                scheduledFireAt: nil,
                desiredCount: 0,
                confirmedPendingCount: 0,
                lastErrorCode: nil,
                observedAt: state.updatedAt
            )
        }
        var descriptor =
            FetchDescriptor<CountdownNotificationCoverageRecord>()
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count == 1,
              let record = records.first,
              let status = record.status,
              record.observedAt.timeIntervalSince1970.isFinite,
              CountdownNotificationCoverageRecord.isConsistent(
                  status: status,
                  scheduledFireAt: record.scheduledFireAt,
                  desiredCount: record.desiredCount,
                  confirmedPendingCount: record.confirmedPendingCount,
                  lastErrorCode: record.lastErrorCode
              ) else {
            throw AppDataFailure.corruptionSuspected
        }
        if record.countdownID != state.id {
            return CountdownReminderCoverageSnapshot(
                countdownID: record.countdownID,
                status: .staleObservation,
                scheduledFireAt: nil,
                desiredCount: 0,
                confirmedPendingCount: 0,
                lastErrorCode: nil,
                observedAt: record.observedAt
            )
        }
        return CountdownReminderCoverageSnapshot(
            countdownID: record.countdownID,
            status: status,
            scheduledFireAt: record.scheduledFireAt,
            desiredCount: record.desiredCount,
            confirmedPendingCount: record.confirmedPendingCount,
            lastErrorCode: record.lastErrorCode,
            observedAt: record.observedAt
        )
    }

    private func countdownGentleModeEnabled() throws -> Bool {
        var descriptor = FetchDescriptor<UserPreferencesRecord>()
        descriptor.fetchLimit = 2
        let preferences = try modelContext.fetch(descriptor)
        guard preferences.count == 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        return preferences[0].gentleModeEnabled
    }

    private func countdownDisplayDate(
        _ value: CivilDateFact,
        timeZoneIdentifier: String
    ) throws -> Date {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw HistoricalTimeError.unknownTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: timeZone,
                year: value.year,
                month: value.month,
                day: value.day,
                hour: 12
            )
        ) else {
            throw AppDataFailure.corruptionSuspected
        }
        return date
    }
}
