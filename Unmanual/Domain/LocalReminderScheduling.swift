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
}

struct LocalReminderReconciliationObservation: Equatable, Sendable {
    let status: NotificationCoverageStatus
    let scheduledThrough: Date?
    let desiredCount: Int
    let confirmedPendingCount: Int
    let lastErrorCode: String?
    let observedAt: Date
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
    static let requestBudget = 60

    static func plan(
        candidates: some Collection<LocalReminderCandidate>,
        settings: LocalNotificationSettingsSnapshot,
        now: Date,
        budget: Int = requestBudget,
        hasEnabledIntent: Bool? = nil,
        foreignPendingCount: Int = 0
    ) -> LocalReminderPlan {
        let candidates = Array(candidates)
        let hasEnabledIntent = hasEnabledIntent ?? candidates.contains { $0.isEnabled }
        guard hasEnabledIntent else {
            return LocalReminderPlan(
                status: .disabledByUser,
                requests: [],
                scheduledThrough: nil
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
                status: permissionStatus,
                requests: [],
                scheduledThrough: nil
            )
        }

        let eligible = candidates.compactMap { candidate -> CandidateRequest? in
            guard candidate.isEnabled, candidate.state == .unrecorded else { return nil }
            let fireAt = candidate.snoozedUntil ?? candidate.occurrence.instant
            guard fireAt > now else { return nil }
            return CandidateRequest(candidate: candidate, fireAt: fireAt)
        }
        .sorted(by: stableCandidateOrder)

        let safeBudget = max(
            0,
            min(requestBudget, budget) - max(0, foreignPendingCount)
        )
        let grouped = Dictionary(grouping: eligible, by: { $0.candidate.occurrence.scheduleRuleID })
        let firstPass = grouped.values.compactMap(\.first).sorted(by: stableCandidateOrder)
        let selectedFirstPass = Array(firstPass.prefix(safeBudget))
        let selectedKeys = Set(selectedFirstPass.map { $0.candidate.occurrence.key })
        let remainingCapacity = safeBudget - selectedFirstPass.count
        let remaining = eligible
            .filter { !selectedKeys.contains($0.candidate.occurrence.key) }
            .prefix(remainingCapacity)
        let selected = selectedFirstPass + Array(remaining)
        let requests = selected.map(makeRequest)
        let selectedOccurrenceKeys = Set(selected.map { $0.candidate.occurrence.key })
        let firstUncovered = eligible.first {
            !selectedOccurrenceKeys.contains($0.candidate.occurrence.key)
        }
        let isBudgetLimited = firstUncovered != nil

        return LocalReminderPlan(
            status: isBudgetLimited ? .limitedByBudget : .scheduledForWindow,
            requests: requests,
            scheduledThrough: firstUncovered?.fireAt ?? requests.map(\.fireAt).max()
        )
    }

    private struct CandidateRequest {
        let candidate: LocalReminderCandidate
        let fireAt: Date
    }

    private static func stableCandidateOrder(
        _ lhs: CandidateRequest,
        _ rhs: CandidateRequest
    ) -> Bool {
        if lhs.fireAt != rhs.fireAt { return lhs.fireAt < rhs.fireAt }
        return lhs.candidate.occurrence.key < rhs.candidate.occurrence.key
    }

    private static func makeRequest(_ value: CandidateRequest) -> LocalReminderRequest {
        let occurrence = value.candidate.occurrence
        let canonicalFireAt = String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            value.fireAt.timeIntervalSince1970
        )
        let digestInput = occurrence.key + "|" + canonicalFireAt
        let digest = SHA256.hash(data: Data(digestInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return LocalReminderRequest(
            identifier: requestPrefix + digest,
            occurrenceKey: occurrence.key,
            scheduleRuleID: occurrence.scheduleRuleID,
            fireAt: value.fireAt,
            timeZoneIdentifier: occurrence.timeZoneIdentifier,
            title: "给自己留一点时间",
            body: "打开 App 查看今天的安排。",
            userInfo: [:],
            includesSound: false,
            includesBadge: false
        )
    }
}

struct LocalReminderReconciler: Sendable {
    let client: any LocalNotificationClient

    func reconcile(
        plan: LocalReminderPlan,
        observedAt: Date
    ) async -> LocalReminderReconciliationObservation {
        let pendingBefore = await client.pendingRequests()
        let ownedBefore = pendingBefore.filter {
            $0.identifier.hasPrefix(LocalReminderPlanner.requestPrefix)
        }
        let desiredByID = Dictionary(uniqueKeysWithValues: plan.requests.map {
            ($0.identifier, $0)
        })
        let staleIDs = ownedBefore.compactMap { pending -> String? in
            guard let desired = desiredByID[pending.identifier],
                  Self.pending(pending, matches: desired) else {
                return pending.identifier
            }
            return nil
        }
        if !staleIDs.isEmpty {
            await client.removePendingRequests(withIdentifiers: staleIDs)
        }

        var errorCode: String?
        if plan.status == .scheduledForWindow || plan.status == .limitedByBudget {
            let matchingIDs: Set<String> = Set(ownedBefore.compactMap { pending -> String? in
                guard let desired = desiredByID[pending.identifier],
                      Self.pending(pending, matches: desired) else { return nil }
                return pending.identifier
            })
            for request in plan.requests where !matchingIDs.contains(request.identifier) {
                do {
                    try await client.add(request)
                } catch {
                    errorCode = "add-request-failed"
                }
            }
        }

        let pendingAfter = await client.pendingRequests()
        let ownedAfter = pendingAfter.filter {
            $0.identifier.hasPrefix(LocalReminderPlanner.requestPrefix)
        }
        let confirmedIDs = Set(ownedAfter.compactMap { pending -> String? in
            guard let desired = desiredByID[pending.identifier],
                  Self.pending(pending, matches: desired) else { return nil }
            return pending.identifier
        })
        let ownedAfterIDs = Set(ownedAfter.map(\.identifier))
        let fullyConfirmed = ownedAfter.count == desiredByID.count
            && ownedAfterIDs == Set(desiredByID.keys)
            && confirmedIDs.count == desiredByID.count
        let finalStatus: NotificationCoverageStatus
        if errorCode != nil || !fullyConfirmed {
            finalStatus = .schedulingFailed
            if errorCode == nil { errorCode = "pending-readback-mismatch" }
        } else {
            finalStatus = plan.status
        }

        return LocalReminderReconciliationObservation(
            status: finalStatus,
            scheduledThrough: fullyConfirmed ? plan.scheduledThrough : nil,
            desiredCount: plan.requests.count,
            confirmedPendingCount: confirmedIDs.count,
            lastErrorCode: errorCode,
            observedAt: observedAt
        )
    }

    private static func pending(
        _ pending: LocalPendingNotificationRequest,
        matches desired: LocalReminderRequest
    ) -> Bool {
        guard let fireAt = pending.fireAt else { return false }
        return abs(fireAt.timeIntervalSince(desired.fireAt)) < 1
    }
}
