import CryptoKit
import Foundation

enum LocalNotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
}

struct LocalNotificationSettingsSnapshot: Equatable, Sendable {
    let authorization: LocalNotificationAuthorization
    let alertsEnabled: Bool
}

enum ReminderCoverageInvalidationResult: Equatable, Sendable {
    case schedule(coverageWasInvalidated: Bool)
    case countdown(coverageWasInvalidated: Bool)
}

struct LocalPendingNotificationRequest: Equatable, Sendable {
    let identifier: String
    let fireAt: Date?
}

struct LocalReminderCandidate: Equatable, Sendable {
    let occurrence: PlannedOccurrence
    let state: TodayExecutionState
    let isEnabled: Bool
    let snoozedUntil: Date?
}

struct CountdownReminderCandidate: Equatable, Sendable {
    let countdownID: UUID
    let semanticRevision: UUID
    let fireAt: Date
    let timeZoneIdentifier: String
    let contentVersion: String
}

enum CountdownReminderResolutionError: Error, Equatable, Sendable {
    case invalidInput
    case nonexistentLocalTime
}

enum CountdownReminderResolver {
    static func resolve(
        countdownID: UUID,
        targetDate: CivilDateFact,
        lifecycle: CountdownLifecycle,
        requiresReview: Bool,
        isEnabled: Bool,
        leadDays: Int,
        localHour: Int,
        localMinute: Int,
        semanticRevision: UUID,
        contentVersion: String,
        now: Date,
        timeZoneIdentifier: String
    ) throws -> CountdownReminderCandidate? {
        guard (0...365).contains(leadDays),
              (0...23).contains(localHour),
              (0...59).contains(localMinute),
              contentVersion == "neutralV1",
              now.timeIntervalSince1970.isFinite,
              let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw CountdownReminderResolutionError.invalidInput
        }
        guard lifecycle == .active, !requiresReview, isEnabled else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let targetNoon = calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: timeZone,
                year: targetDate.year,
                month: targetDate.month,
                day: targetDate.day,
                hour: 12
            )
        ),
        let reminderNoon = calendar.date(
            byAdding: .day,
            value: -leadDays,
            to: targetNoon
        ) else {
            throw CountdownReminderResolutionError.invalidInput
        }
        let reminderDate = calendar.dateComponents(
            [.year, .month, .day],
            from: reminderNoon
        )
        guard let year = reminderDate.year,
              let month = reminderDate.month,
              let day = reminderDate.day else {
            throw CountdownReminderResolutionError.invalidInput
        }
        let dayStart = calendar.startOfDay(for: reminderNoon)
        let matching = DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: localHour,
            minute: localMinute,
            second: 0
        )
        guard let fireAt = calendar.nextDate(
            after: dayStart.addingTimeInterval(-1),
            matching: matching,
            matchingPolicy: .strict,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else {
            throw CountdownReminderResolutionError.nonexistentLocalTime
        }
        let resolved = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireAt
        )
        guard resolved.year == year,
              resolved.month == month,
              resolved.day == day,
              resolved.hour == localHour,
              resolved.minute == localMinute else {
            throw CountdownReminderResolutionError.nonexistentLocalTime
        }
        guard fireAt > now else { return nil }
        return CountdownReminderCandidate(
            countdownID: countdownID,
            semanticRevision: semanticRevision,
            fireAt: fireAt,
            timeZoneIdentifier: timeZoneIdentifier,
            contentVersion: contentVersion
        )
    }
}

struct LocalReminderRequest: Equatable, Sendable {
    let identifier: String
    let occurrenceKey: String
    let scheduleRuleID: UUID
    let fireAt: Date
    let timeZoneIdentifier: String
    let title: String
    let body: String
    let userInfo: [String: String]
    let includesSound: Bool
    let includesBadge: Bool
}

struct LocalReminderPlan: Equatable, Sendable {
    let status: NotificationCoverageStatus
    let requests: [LocalReminderRequest]
    let scheduledThrough: Date?
    let countdownStatus: NotificationCoverageStatus
    let countdownScheduledFireAt: Date?
    let countdownDesiredCount: Int
    let countdownRequestIdentifiers: Set<String>
    let countdownHasEnabledIntent: Bool
    let countdownID: UUID?
    let countdownFailureCode: String?

    init(
        status: NotificationCoverageStatus,
        requests: [LocalReminderRequest],
        scheduledThrough: Date?,
        countdownStatus: NotificationCoverageStatus = .disabledByUser,
        countdownScheduledFireAt: Date? = nil,
        countdownDesiredCount: Int = 0,
        countdownRequestIdentifiers: Set<String> = [],
        countdownHasEnabledIntent: Bool = false,
        countdownID: UUID? = nil,
        countdownFailureCode: String? = nil
    ) {
        self.status = status
        self.requests = requests
        self.scheduledThrough = scheduledThrough
        self.countdownStatus = countdownStatus
        self.countdownScheduledFireAt = countdownScheduledFireAt
        self.countdownDesiredCount = countdownDesiredCount
        self.countdownRequestIdentifiers = countdownRequestIdentifiers
        self.countdownHasEnabledIntent = countdownHasEnabledIntent
        self.countdownID = countdownID
        self.countdownFailureCode = countdownFailureCode
    }
}

struct LocalReminderReconciliationObservation: Equatable, Sendable {
    let status: NotificationCoverageStatus
    let scheduledThrough: Date?
    let desiredCount: Int
    let confirmedPendingCount: Int
    let lastErrorCode: String?
    let observedAt: Date
    let countdownStatus: NotificationCoverageStatus
    let countdownScheduledFireAt: Date?
    let countdownDesiredCount: Int
    let countdownConfirmedPendingCount: Int
    let countdownID: UUID?
    let countdownLastErrorCode: String?
    let ownedCleanupWasVerified: Bool

    init(
        status: NotificationCoverageStatus,
        scheduledThrough: Date?,
        desiredCount: Int,
        confirmedPendingCount: Int,
        lastErrorCode: String?,
        observedAt: Date,
        countdownStatus: NotificationCoverageStatus = .disabledByUser,
        countdownScheduledFireAt: Date? = nil,
        countdownDesiredCount: Int = 0,
        countdownConfirmedPendingCount: Int = 0,
        countdownID: UUID? = nil,
        countdownLastErrorCode: String? = nil,
        ownedCleanupWasVerified: Bool = true
    ) {
        self.status = status
        self.scheduledThrough = scheduledThrough
        self.desiredCount = desiredCount
        self.confirmedPendingCount = confirmedPendingCount
        self.lastErrorCode = lastErrorCode
        self.observedAt = observedAt
        self.countdownStatus = countdownStatus
        self.countdownScheduledFireAt = countdownScheduledFireAt
        self.countdownDesiredCount = countdownDesiredCount
        self.countdownConfirmedPendingCount =
            countdownConfirmedPendingCount
        self.countdownID = countdownID
        self.countdownLastErrorCode = countdownLastErrorCode
            ?? (
                countdownStatus == .schedulingFailed
                    ? lastErrorCode
                    : nil
            )
        self.ownedCleanupWasVerified = ownedCleanupWasVerified
    }
}

protocol LocalNotificationClient: Sendable {
    func settings() async -> LocalNotificationSettingsSnapshot
    func requestAuthorization() async throws -> Bool
    func pendingRequests() async -> [LocalPendingNotificationRequest]
    func add(_ request: LocalReminderRequest) async throws
    func removePendingRequests(withIdentifiers identifiers: [String]) async
}

enum LocalReminderPlanner {
    static let requestPrefix = "unmanual.exec.v1."
    static let countdownRequestPrefix = "unmanual.countdown.v1."
    static let requestBudget = 60

    static func isOwnedIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(requestPrefix)
            || identifier.hasPrefix(countdownRequestPrefix)
    }

    static func plan(
        candidates: some Collection<LocalReminderCandidate>,
        countdownCandidates: [CountdownReminderCandidate] = [],
        settings: LocalNotificationSettingsSnapshot,
        now: Date,
        budget: Int = requestBudget,
        hasEnabledIntent: Bool? = nil,
        countdownHasEnabledIntent: Bool? = nil,
        countdownID: UUID? = nil,
        countdownResolutionFailed: Bool = false,
        countdownFailureCode: String? = nil,
        foreignPendingCount: Int = 0
    ) -> LocalReminderPlan {
        let scheduleCandidates = Array(candidates)
        let hasScheduleIntent = hasEnabledIntent
            ?? scheduleCandidates.contains { $0.isEnabled }
        let hasCountdownIntent = countdownHasEnabledIntent
            ?? !countdownCandidates.isEmpty
        guard hasScheduleIntent || hasCountdownIntent else {
            return LocalReminderPlan(
                status: .disabledByUser,
                requests: [],
                scheduledThrough: nil,
                countdownStatus: .disabledByUser,
                countdownID: countdownID
            )
        }

        let permissionStatus: NotificationCoverageStatus? = switch settings.authorization {
        case .notDetermined:
            .notDetermined
        case .denied:
            .blockedByPermission
        case .authorized, .provisional, .ephemeral:
            settings.alertsEnabled ? nil : .limitedBySystemSettings
        }
        if let permissionStatus {
            return LocalReminderPlan(
                status: hasScheduleIntent ? permissionStatus : .disabledByUser,
                requests: [],
                scheduledThrough: nil,
                countdownStatus: hasCountdownIntent
                    ? permissionStatus
                    : .disabledByUser,
                countdownHasEnabledIntent: hasCountdownIntent,
                countdownID: countdownID
                    ?? countdownCandidates.first?.countdownID
            )
        }

        var eligible = scheduleCandidates.compactMap {
            candidate -> CandidateRequest? in
            guard candidate.isEnabled, candidate.state == .unrecorded else { return nil }
            let fireAt = candidate.snoozedUntil ?? candidate.occurrence.instant
            guard fireAt > now else { return nil }
            return CandidateRequest(
                source: .schedule(candidate),
                fireAt: fireAt,
                fairnessKey: "schedule:"
                    + candidate.occurrence.scheduleRuleID.uuidString.lowercased(),
                semanticKey: "schedule:" + candidate.occurrence.key
            )
        }
        eligible += countdownCandidates.compactMap {
            candidate -> CandidateRequest? in
            guard candidate.fireAt > now,
                  candidate.contentVersion == "neutralV1" else {
                return nil
            }
            return CandidateRequest(
                source: .countdown(candidate),
                fireAt: candidate.fireAt,
                fairnessKey: "countdown:"
                    + candidate.countdownID.uuidString.lowercased(),
                semanticKey: "countdown:"
                    + candidate.countdownID.uuidString.lowercased()
            )
        }
        eligible = eligible
        .sorted(by: stableCandidateOrder)

        let safeBudget = max(
            0,
            min(requestBudget, budget) - max(0, foreignPendingCount)
        )
        let grouped = Dictionary(grouping: eligible, by: \.fairnessKey)
        let firstPass = grouped.values.compactMap(\.first).sorted(by: stableCandidateOrder)
        let selectedFirstPass = Array(firstPass.prefix(safeBudget))
        let selectedKeys = Set(selectedFirstPass.map(\.semanticKey))
        let remainingCapacity = safeBudget - selectedFirstPass.count
        let remaining = eligible
            .filter { !selectedKeys.contains($0.semanticKey) }
            .prefix(remainingCapacity)
        let selected = selectedFirstPass + Array(remaining)
        let requests = selected.map(makeRequest)
        let selectedSemanticKeys = Set(selected.map(\.semanticKey))
        let firstUncoveredSchedule = eligible.first {
            $0.isSchedule && !selectedSemanticKeys.contains($0.semanticKey)
        }
        let selectedSchedule = selected.filter(\.isSchedule)
        let countdownRequestIdentifiers = Set(
            zip(selected, requests).compactMap { candidate, request in
                candidate.isCountdown ? request.identifier : nil
            }
        )
        let eligibleCountdown = eligible.filter(\.isCountdown)
        let selectedCountdown = selected.filter(\.isCountdown)
        let countdownWasBudgetLimited = eligibleCountdown.count
            > selectedCountdown.count

        return LocalReminderPlan(
            status: hasScheduleIntent
                ? (
                    firstUncoveredSchedule != nil
                        ? .limitedByBudget
                        : .scheduledForWindow
                )
                : .disabledByUser,
            requests: requests,
            scheduledThrough: firstUncoveredSchedule?.fireAt
                ?? selectedSchedule.map(\.fireAt).max(),
            countdownStatus: hasCountdownIntent
                ? (
                    countdownResolutionFailed
                        || countdownFailureCode != nil
                        ? .schedulingFailed
                        : countdownWasBudgetLimited
                        ? .limitedByBudget
                        : .scheduledForWindow
                )
                : .disabledByUser,
            countdownScheduledFireAt: selectedCountdown.first?.fireAt,
            countdownDesiredCount: selectedCountdown.count,
            countdownRequestIdentifiers: countdownRequestIdentifiers,
            countdownHasEnabledIntent: hasCountdownIntent,
            countdownID: countdownID
                ?? countdownCandidates.first?.countdownID,
            countdownFailureCode: countdownFailureCode
        )
    }

    private struct CandidateRequest {
        let source: Source
        let fireAt: Date
        let fairnessKey: String
        let semanticKey: String

        var isSchedule: Bool {
            if case .schedule = source { return true }
            return false
        }

        var isCountdown: Bool {
            if case .countdown = source { return true }
            return false
        }
    }

    private enum Source {
        case schedule(LocalReminderCandidate)
        case countdown(CountdownReminderCandidate)

        var stableOrder: Int {
            switch self {
            case .schedule: 0
            case .countdown: 1
            }
        }
    }

    private static func stableCandidateOrder(
        _ lhs: CandidateRequest,
        _ rhs: CandidateRequest
    ) -> Bool {
        if lhs.fireAt != rhs.fireAt { return lhs.fireAt < rhs.fireAt }
        if lhs.source.stableOrder != rhs.source.stableOrder {
            return lhs.source.stableOrder < rhs.source.stableOrder
        }
        return lhs.semanticKey < rhs.semanticKey
    }

    private static func makeRequest(_ value: CandidateRequest) -> LocalReminderRequest {
        let canonicalFireAt = String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            value.fireAt.timeIntervalSince1970
        )
        let digestInput: String
        let prefix: String
        let occurrenceKey: String
        let semanticID: UUID
        let timeZoneIdentifier: String
        let body: String
        switch value.source {
        case let .schedule(candidate):
            let occurrence = candidate.occurrence
            digestInput = occurrence.key + "|" + canonicalFireAt
            prefix = requestPrefix
            occurrenceKey = occurrence.key
            semanticID = occurrence.scheduleRuleID
            timeZoneIdentifier = occurrence.timeZoneIdentifier
            body = "打开 App 查看今天的安排。"
        case let .countdown(candidate):
            occurrenceKey = "countdown:"
                + candidate.countdownID.uuidString.lowercased()
            digestInput = [
                occurrenceKey,
                candidate.semanticRevision.uuidString.lowercased(),
                canonicalFireAt,
                candidate.contentVersion
            ].joined(separator: "|")
            prefix = countdownRequestPrefix
            semanticID = candidate.countdownID
            timeZoneIdentifier = candidate.timeZoneIdentifier
            body = "打开 App 查看下一件事。"
        }
        let digest = SHA256.hash(data: Data(digestInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return LocalReminderRequest(
            identifier: prefix + digest,
            occurrenceKey: occurrenceKey,
            scheduleRuleID: semanticID,
            fireAt: value.fireAt,
            timeZoneIdentifier: timeZoneIdentifier,
            title: "给自己留一点时间",
            body: body,
            userInfo: [:],
            includesSound: false,
            includesBadge: false
        )
    }
}

struct LocalReminderReconciler: Sendable {
    let client: any LocalNotificationClient

    static func desiredRequestsHaveUniqueIdentifiers(
        _ requests: [LocalReminderRequest]
    ) -> Bool {
        Set(requests.map(\.identifier)).count == requests.count
    }

    func reconcile(
        plan: LocalReminderPlan,
        observedAt: Date,
        isCurrent: @escaping @Sendable () async -> Bool = { true }
    ) async -> LocalReminderReconciliationObservation {
        guard Self.desiredRequestsHaveUniqueIdentifiers(plan.requests) else {
            return await failClosedObservation(
                plan: plan,
                observedAt: observedAt,
                errorCode: "duplicate-desired-request-id"
            )
        }
        guard await isCurrent() else {
            return await failClosedObservation(
                plan: plan,
                observedAt: observedAt,
                errorCode: "reconciliation-superseded"
            )
        }
        let pendingBefore = await client.pendingRequests()
        guard await isCurrent() else {
            return await failClosedObservation(
                plan: plan,
                observedAt: observedAt,
                errorCode: "reconciliation-superseded"
            )
        }
        let ownedBefore = pendingBefore.filter {
            LocalReminderPlanner.isOwnedIdentifier($0.identifier)
        }
        let desiredByID = Dictionary(uniqueKeysWithValues: plan.requests.map {
            ($0.identifier, $0)
        })
        let foreignBeforeCount = pendingBefore.count - ownedBefore.count
        let initialForeignCountExceededBudget =
            foreignBeforeCount > LocalReminderPlanner.requestBudget
        let allowedBeforeCount = max(
            0,
            LocalReminderPlanner.requestBudget - foreignBeforeCount
        )
        let allowedRequests = Array(plan.requests.prefix(allowedBeforeCount))
        let allowedByID = Dictionary(uniqueKeysWithValues: allowedRequests.map {
            ($0.identifier, $0)
        })
        let staleIDs = ownedBefore.compactMap { pending -> String? in
            guard let desired = allowedByID[pending.identifier],
                  Self.pending(pending, matches: desired) else {
                return pending.identifier
            }
            return nil
        }
        if !staleIDs.isEmpty {
            guard await isCurrent() else {
                return await failClosedObservation(
                    plan: plan,
                    observedAt: observedAt,
                    errorCode: "reconciliation-superseded"
                )
            }
            await client.removePendingRequests(withIdentifiers: staleIDs)
            guard await isCurrent() else {
                return await failClosedObservation(
                    plan: plan,
                    observedAt: observedAt,
                    errorCode: "reconciliation-superseded"
                )
            }
        }

        var errorCode: String? = allowedRequests.count < plan.requests.count
            ? "notification-budget-changed"
            : nil
        if plan.status == .scheduledForWindow
            || plan.status == .limitedByBudget
            || plan.countdownStatus == .scheduledForWindow
            || plan.countdownStatus == .limitedByBudget {
            for request in allowedRequests {
                guard await isCurrent() else {
                    return await failClosedObservation(
                        plan: plan,
                        observedAt: observedAt,
                        errorCode: "reconciliation-superseded"
                    )
                }
                var canAdd = false
                var alreadyMatches = false
                for _ in 0..<3 {
                    let pendingNow = await client.pendingRequests()
                    guard await isCurrent() else {
                        return await failClosedObservation(
                            plan: plan,
                            observedAt: observedAt,
                            errorCode: "reconciliation-superseded"
                        )
                    }
                    let ownedNow = pendingNow.filter {
                        LocalReminderPlanner.isOwnedIdentifier($0.identifier)
                    }
                    let foreignNowCount = pendingNow.count - ownedNow.count
                    let allowedNowCount = max(
                        0,
                        LocalReminderPlanner.requestBudget - foreignNowCount
                    )
                    if allowedNowCount < plan.requests.count {
                        errorCode = "notification-budget-changed"
                    }
                    let allowedNowIDs = Set(
                        plan.requests.prefix(allowedNowCount).map(\.identifier)
                    )
                    let excessOwnedIDs = ownedNow.compactMap { pending -> String? in
                        allowedNowIDs.contains(pending.identifier) ? nil : pending.identifier
                    }
                    if !excessOwnedIDs.isEmpty {
                        await client.removePendingRequests(withIdentifiers: excessOwnedIDs)
                        guard await isCurrent() else {
                            return await failClosedObservation(
                                plan: plan,
                                observedAt: observedAt,
                                errorCode: "reconciliation-superseded"
                            )
                        }
                        continue
                    }
                    alreadyMatches = ownedNow.contains {
                        $0.identifier == request.identifier
                            && Self.pending($0, matches: request)
                    }
                    canAdd = !alreadyMatches
                        && allowedNowIDs.contains(request.identifier)
                        && pendingNow.count < LocalReminderPlanner.requestBudget
                    break
                }
                guard !alreadyMatches, canAdd else { continue }
                guard await isCurrent() else {
                    return await failClosedObservation(
                        plan: plan,
                        observedAt: observedAt,
                        errorCode: "reconciliation-superseded"
                    )
                }
                do {
                    try await client.add(request)
                } catch {
                    return await failClosedObservation(
                        plan: plan,
                        observedAt: observedAt,
                        errorCode: "add-request-failed"
                    )
                }
                guard await isCurrent() else {
                    return await failClosedObservation(
                        plan: plan,
                        observedAt: observedAt,
                        errorCode: "reconciliation-superseded"
                    )
                }
            }
        }

        var pendingAfter = await client.pendingRequests()
        guard await isCurrent() else {
            return await failClosedObservation(
                plan: plan,
                observedAt: observedAt,
                errorCode: "reconciliation-superseded"
            )
        }
        var ownedAfter = pendingAfter.filter {
            LocalReminderPlanner.isOwnedIdentifier($0.identifier)
        }
        for _ in 0..<3 {
            let foreignAfterCount = pendingAfter.count - ownedAfter.count
            let allowedOwnedCount = max(
                0,
                LocalReminderPlanner.requestBudget - foreignAfterCount
            )
            guard ownedAfter.count > allowedOwnedCount else { break }
            let allowedOwnedIDs = Set(
                plan.requests.prefix(allowedOwnedCount).map(\.identifier)
            )
            let excessOwnedIDs = ownedAfter.compactMap { request in
                allowedOwnedIDs.contains(request.identifier) ? nil : request.identifier
            }
            if !excessOwnedIDs.isEmpty {
                guard await isCurrent() else {
                    return await failClosedObservation(
                        plan: plan,
                        observedAt: observedAt,
                        errorCode: "reconciliation-superseded"
                    )
                }
                await client.removePendingRequests(withIdentifiers: excessOwnedIDs)
                pendingAfter = await client.pendingRequests()
                guard await isCurrent() else {
                    return await failClosedObservation(
                        plan: plan,
                        observedAt: observedAt,
                        errorCode: "reconciliation-superseded"
                    )
                }
                ownedAfter = pendingAfter.filter {
                    LocalReminderPlanner.isOwnedIdentifier($0.identifier)
                }
                errorCode = "notification-budget-changed"
            } else {
                break
            }
        }
        if pendingAfter.count > LocalReminderPlanner.requestBudget,
           !ownedAfter.isEmpty {
            guard await isCurrent() else {
                return await failClosedObservation(
                    plan: plan,
                    observedAt: observedAt,
                    errorCode: "reconciliation-superseded"
                )
            }
            await client.removePendingRequests(
                withIdentifiers: ownedAfter.map(\.identifier)
            )
            pendingAfter = await client.pendingRequests()
            guard await isCurrent() else {
                return await failClosedObservation(
                    plan: plan,
                    observedAt: observedAt,
                    errorCode: "reconciliation-superseded"
                )
            }
            ownedAfter = pendingAfter.filter {
                LocalReminderPlanner.isOwnedIdentifier($0.identifier)
            }
            errorCode = "notification-budget-changed"
        }
        guard pendingAfter.count <= LocalReminderPlanner.requestBudget else {
            return await failClosedObservation(
                plan: plan,
                observedAt: observedAt,
                errorCode: initialForeignCountExceededBudget
                    ? "notification-budget-exceeded"
                    : (errorCode ?? "notification-budget-changed")
            )
        }
        let foreignAfterCount = pendingAfter.count - ownedAfter.count
        let authoritativeRequestCount = max(
            0,
            min(
                plan.requests.count,
                LocalReminderPlanner.requestBudget - foreignAfterCount
            )
        )
        let authoritativeRequests = Array(
            plan.requests.prefix(authoritativeRequestCount)
        )
        let authoritativeByID = Dictionary(
            uniqueKeysWithValues: authoritativeRequests.map {
                ($0.identifier, $0)
            }
        )
        let confirmedIDs = Set(ownedAfter.compactMap { pending -> String? in
            guard let desired = authoritativeByID[pending.identifier],
                  Self.pending(pending, matches: desired) else { return nil }
            return pending.identifier
        })
        let ownedAfterIDs = Set(ownedAfter.map(\.identifier))
        let authoritativeIDs = Set(authoritativeByID.keys)
        let fullyConfirmed = ownedAfter.count == authoritativeByID.count
            && ownedAfterIDs == authoritativeIDs
            && confirmedIDs.count == authoritativeByID.count
        let countdownDesiredIDs = plan.countdownRequestIdentifiers
        let scheduleDesiredIDs = Set(desiredByID.keys)
            .subtracting(countdownDesiredIDs)
        let authoritativeCountdownIDs = authoritativeIDs.intersection(
            countdownDesiredIDs
        )
        let authoritativeScheduleIDs = authoritativeIDs.intersection(
            scheduleDesiredIDs
        )
        let countdownConfirmedIDs = confirmedIDs.intersection(
            authoritativeCountdownIDs
        )
        let scheduleConfirmedIDs = confirmedIDs.intersection(
            authoritativeScheduleIDs
        )
        let unexpectedOwnedIDs = ownedAfterIDs.subtracting(
            authoritativeIDs
        )
        let hasUnexpectedScheduleOwned = unexpectedOwnedIDs.contains {
            $0.hasPrefix(LocalReminderPlanner.requestPrefix)
        }
        let hasUnexpectedCountdownOwned = unexpectedOwnedIDs.contains {
            $0.hasPrefix(LocalReminderPlanner.countdownRequestPrefix)
        }
        let scheduleFullyConfirmed =
            scheduleConfirmedIDs == authoritativeScheduleIDs
        let countdownFullyConfirmed =
            countdownConfirmedIDs == authoritativeCountdownIDs
        let scheduleWasDynamicallyLimited =
            authoritativeScheduleIDs != scheduleDesiredIDs
        let countdownWasDynamicallyLimited =
            authoritativeCountdownIDs != countdownDesiredIDs
        let finalStatus: NotificationCoverageStatus =
            hasUnexpectedScheduleOwned
                ? .schedulingFailed
                : plan.status == .disabledByUser
                ? .disabledByUser
                : (
                    !scheduleFullyConfirmed
                        ? .schedulingFailed
                        : scheduleWasDynamicallyLimited
                            ? .limitedByBudget
                            : plan.status
                )
        let countdownFinalStatus: NotificationCoverageStatus =
            hasUnexpectedCountdownOwned
                ? .schedulingFailed
                : !plan.countdownHasEnabledIntent
                ? .disabledByUser
                : (
                    !countdownFullyConfirmed
                        ? .schedulingFailed
                        : countdownWasDynamicallyLimited
                            ? .limitedByBudget
                            : plan.countdownStatus
                )
        if !fullyConfirmed
            || (
                countdownWasDynamicallyLimited
                    && !authoritativeCountdownIDs.isEmpty
            ) {
            return await failClosedObservation(
                plan: plan,
                observedAt: observedAt,
                errorCode: errorCode ?? "pending-readback-mismatch"
            )
        }
        let scheduleLastErrorCode = finalStatus == .schedulingFailed
            ? (errorCode ?? "schedule-reconciliation-failed")
            : nil
        let countdownLastErrorCode =
            countdownFinalStatus == .schedulingFailed
                ? (
                    plan.countdownStatus == .schedulingFailed
                        ? (
                            plan.countdownFailureCode
                                ?? "countdown-local-time-invalid"
                        )
                        : (
                            errorCode
                                ?? "countdown-reconciliation-failed"
                        )
                )
                : nil
        let firstDynamicallyUncoveredSchedule = plan.requests
            .filter {
                scheduleDesiredIDs.contains($0.identifier)
                    && !authoritativeScheduleIDs.contains($0.identifier)
            }
            .map(\.fireAt)
            .min()
        let finalScheduledThrough: Date? = switch finalStatus {
        case .scheduledForWindow:
            plan.scheduledThrough
        case .limitedByBudget:
            [
                plan.status == .limitedByBudget
                    ? plan.scheduledThrough
                    : nil,
                firstDynamicallyUncoveredSchedule
            ]
            .compactMap { $0 }
            .min()
        default:
            nil
        }
        if finalStatus == .limitedByBudget,
           finalScheduledThrough == nil {
            return await failClosedObservation(
                plan: plan,
                observedAt: observedAt,
                errorCode: "schedule-budget-cutoff-missing"
            )
        }

        return LocalReminderReconciliationObservation(
            status: finalStatus,
            scheduledThrough: finalScheduledThrough,
            desiredCount: authoritativeScheduleIDs.count,
            confirmedPendingCount: scheduleConfirmedIDs.count,
            lastErrorCode: scheduleLastErrorCode,
            observedAt: observedAt,
            countdownStatus: countdownFinalStatus,
            countdownScheduledFireAt:
                countdownFinalStatus == .scheduledForWindow
                ? plan.countdownScheduledFireAt
                : nil,
            countdownDesiredCount: authoritativeCountdownIDs.count,
            countdownConfirmedPendingCount: countdownConfirmedIDs.count,
            countdownID: plan.countdownID,
            countdownLastErrorCode: countdownLastErrorCode
        )
    }

    private func failClosedObservation(
        plan: LocalReminderPlan,
        observedAt: Date,
        errorCode: String
    ) async -> LocalReminderReconciliationObservation {
        let didClear = await clearOwnedPending(maxAttempts: 3)
        let countdownDesiredIDs = plan.countdownRequestIdentifiers
        let scheduleDesiredCount = plan.requests.count
            - countdownDesiredIDs.count
        return LocalReminderReconciliationObservation(
            status: didClear && plan.status == .disabledByUser
                ? .disabledByUser
                : .schedulingFailed,
            scheduledThrough: nil,
            desiredCount: scheduleDesiredCount,
            confirmedPendingCount: 0,
            lastErrorCode: didClear && plan.status == .disabledByUser
                ? nil
                : (
                    didClear
                        ? errorCode
                        : errorCode + "-owned-removal-unverified"
                ),
            observedAt: observedAt,
            countdownStatus:
                didClear && !plan.countdownHasEnabledIntent
                    ? .disabledByUser
                    : .schedulingFailed,
            countdownScheduledFireAt: nil,
            countdownDesiredCount: countdownDesiredIDs.count,
            countdownConfirmedPendingCount: 0,
            countdownID: plan.countdownID,
            countdownLastErrorCode:
                didClear && !plan.countdownHasEnabledIntent
                    ? nil
                    : (
                    didClear
                        ? errorCode
                        : errorCode + "-owned-removal-unverified"
                ),
            ownedCleanupWasVerified: didClear
        )
    }

    private func clearOwnedPending(maxAttempts: Int) async -> Bool {
        for _ in 0..<max(1, maxAttempts) {
            let pending = await client.pendingRequests()
            let ownedIDs = pending.compactMap { request in
                LocalReminderPlanner.isOwnedIdentifier(request.identifier)
                    ? request.identifier
                    : nil
            }
            if ownedIDs.isEmpty { return true }
            await client.removePendingRequests(withIdentifiers: ownedIDs)
            let remaining = await client.pendingRequests()
            if !remaining.contains(where: {
                LocalReminderPlanner.isOwnedIdentifier($0.identifier)
            }) {
                return true
            }
        }
        return false
    }

    private static func pending(
        _ pending: LocalPendingNotificationRequest,
        matches desired: LocalReminderRequest
    ) -> Bool {
        guard let fireAt = pending.fireAt else { return false }
        return abs(fireAt.timeIntervalSince(desired.fireAt)) < 1
    }
}
