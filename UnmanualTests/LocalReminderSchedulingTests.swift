import Foundation
import XCTest
@testable import Unmanual

final class LocalReminderSchedulingTests: XCTestCase {
    func testPlannerMapsAuthorizationWithoutDiscardingReminderIntent() throws {
        let candidate = try makeCandidate(ruleIndex: 1, occurrenceIndex: 1)

        XCTAssertEqual(
            LocalReminderPlanner.plan(
                candidates: [candidate],
                settings: .init(authorization: .notDetermined, alertsEnabled: false),
                now: referenceDate
            ).status,
            .notDetermined
        )
        XCTAssertEqual(
            LocalReminderPlanner.plan(
                candidates: [candidate],
                settings: .init(authorization: .denied, alertsEnabled: false),
                now: referenceDate
            ).status,
            .blockedByPermission
        )
        XCTAssertEqual(
            LocalReminderPlanner.plan(
                candidates: [candidate],
                settings: .init(authorization: .authorized, alertsEnabled: false),
                now: referenceDate
            ).status,
            .limitedBySystemSettings
        )
    }

    func testPlannerUsesFairFirstPassThenStableOrderWithinSixtyRequestBudget() throws {
        var candidates: [LocalReminderCandidate] = []
        for ruleIndex in 0..<3 {
            for occurrenceIndex in 0..<30 {
                candidates.append(
                    try makeCandidate(
                        ruleIndex: ruleIndex,
                        occurrenceIndex: occurrenceIndex
                    )
                )
            }
        }

        let plan = LocalReminderPlanner.plan(
            candidates: candidates,
            settings: .init(authorization: .authorized, alertsEnabled: true),
            now: referenceDate
        )

        XCTAssertEqual(plan.status, .limitedByBudget)
        XCTAssertEqual(plan.requests.count, 60)
        XCTAssertEqual(Set(plan.requests.prefix(3).map(\.scheduleRuleID)).count, 3)
        XCTAssertEqual(
            plan.requests,
            LocalReminderPlanner.plan(
                candidates: candidates.reversed(),
                settings: .init(authorization: .authorized, alertsEnabled: true),
                now: referenceDate
            ).requests
        )
        XCTAssertTrue(plan.requests.allSatisfy { request in
            request.title == "给自己留一点时间"
                && request.body == "打开 App 查看今天的安排。"
                && request.userInfo.isEmpty
                && !request.includesSound
                && !request.includesBadge
        })
    }

    func testEnabledIntentWithoutEligibleCandidatesIsNotReportedDisabled() {
        let plan = LocalReminderPlanner.plan(
            candidates: [],
            settings: .init(authorization: .authorized, alertsEnabled: true),
            now: referenceDate,
            hasEnabledIntent: true
        )

        XCTAssertEqual(plan.status, .scheduledForWindow)
        XCTAssertTrue(plan.requests.isEmpty)
        XCTAssertNil(plan.scheduledThrough)
    }

    func testForeignPendingRequestsReduceOwnedBudgetAndExposeContinuousCutoff() throws {
        let candidates = try (0..<10).map {
            try makeCandidate(ruleIndex: $0, occurrenceIndex: $0 + 1)
        }
        let plan = LocalReminderPlanner.plan(
            candidates: candidates,
            settings: .init(authorization: .authorized, alertsEnabled: true),
            now: referenceDate,
            budget: 8,
            foreignPendingCount: 3
        )

        XCTAssertEqual(plan.status, .limitedByBudget)
        XCTAssertEqual(plan.requests.count, 5)
        XCTAssertEqual(plan.scheduledThrough, candidates[5].occurrence.instant)
    }

    func testPlannerExcludesRecordedDisabledAndExpiredCandidatesAndUsesSnooze() throws {
        let future = try makeCandidate(ruleIndex: 0, occurrenceIndex: 1)
        let taken = LocalReminderCandidate(
            occurrence: try makeOccurrence(ruleIndex: 0, occurrenceIndex: 2),
            state: .taken,
            isEnabled: true,
            snoozedUntil: nil
        )
        let disabled = LocalReminderCandidate(
            occurrence: try makeOccurrence(ruleIndex: 0, occurrenceIndex: 3),
            state: .unrecorded,
            isEnabled: false,
            snoozedUntil: nil
        )
        let expired = LocalReminderCandidate(
            occurrence: try makeOccurrence(ruleIndex: 0, occurrenceIndex: -1),
            state: .unrecorded,
            isEnabled: true,
            snoozedUntil: nil
        )
        let snoozedFire = referenceDate.addingTimeInterval(7_200)
        let snoozed = LocalReminderCandidate(
            occurrence: try makeOccurrence(ruleIndex: 1, occurrenceIndex: 1),
            state: .unrecorded,
            isEnabled: true,
            snoozedUntil: snoozedFire
        )

        let plan = LocalReminderPlanner.plan(
            candidates: [future, taken, disabled, expired, snoozed],
            settings: .init(authorization: .authorized, alertsEnabled: true),
            now: referenceDate
        )

        XCTAssertEqual(plan.requests.count, 2)
        XCTAssertTrue(plan.requests.contains { $0.fireAt == snoozedFire })
    }

    func testReconcilerOnlyTouchesOwnedPrefixAndReportsVerifiedPendingCoverage() async throws {
        let plan = LocalReminderPlanner.plan(
            candidates: [try makeCandidate(ruleIndex: 0, occurrenceIndex: 1)],
            settings: .init(authorization: .authorized, alertsEnabled: true),
            now: referenceDate
        )
        let desired = try XCTUnwrap(plan.requests.first)
        let client = FakeLocalNotificationClient(
            pending: [
                LocalPendingNotificationRequest(
                    identifier: "foreign.calendar.reminder",
                    fireAt: referenceDate.addingTimeInterval(900)
                ),
                LocalPendingNotificationRequest(
                    identifier: LocalReminderPlanner.requestPrefix + "stale",
                    fireAt: referenceDate.addingTimeInterval(1_800)
                )
            ]
        )

        let observation = await LocalReminderReconciler(client: client).reconcile(
            plan: plan,
            observedAt: referenceDate
        )
        let finalPending = await client.pendingRequests()

        XCTAssertEqual(observation.status, .scheduledForWindow)
        XCTAssertEqual(observation.desiredCount, 1)
        XCTAssertEqual(observation.confirmedPendingCount, 1)
        XCTAssertEqual(observation.scheduledThrough, desired.fireAt)
        XCTAssertTrue(finalPending.contains { $0.identifier == "foreign.calendar.reminder" })
        XCTAssertTrue(finalPending.contains { $0.identifier == desired.identifier })
        XCTAssertFalse(finalPending.contains { $0.identifier.hasSuffix("stale") })
    }

    func testReconcilerDoesNotClaimDisabledWhenOwnedStaleRemovalIsNotObserved() async {
        let plan = LocalReminderPlanner.plan(
            candidates: [] as [LocalReminderCandidate],
            settings: .init(authorization: .authorized, alertsEnabled: true),
            now: referenceDate,
            hasEnabledIntent: false
        )
        let staleID = LocalReminderPlanner.requestPrefix + "stale-removal-no-op"
        let client = FakeLocalNotificationClient(
            pending: [
                LocalPendingNotificationRequest(
                    identifier: staleID,
                    fireAt: referenceDate.addingTimeInterval(1_800)
                )
            ],
            ignoresRemovals: true
        )

        let observation = await LocalReminderReconciler(client: client).reconcile(
            plan: plan,
            observedAt: referenceDate
        )

        XCTAssertEqual(observation.status, .schedulingFailed)
        XCTAssertEqual(observation.desiredCount, 0)
        XCTAssertEqual(observation.confirmedPendingCount, 0)
        XCTAssertNil(observation.scheduledThrough)
        XCTAssertEqual(observation.lastErrorCode, "pending-readback-mismatch")
        let pending = await client.pendingRequests()
        XCTAssertTrue(pending.contains { $0.identifier == staleID })
    }

    func testReconcilerReportsPartialAddFailureWithoutClaimingCoverage() async throws {
        let plan = LocalReminderPlanner.plan(
            candidates: [try makeCandidate(ruleIndex: 0, occurrenceIndex: 1)],
            settings: .init(authorization: .authorized, alertsEnabled: true),
            now: referenceDate
        )
        let desired = try XCTUnwrap(plan.requests.first)
        let client = FakeLocalNotificationClient(pending: [], failAddIdentifiers: [desired.identifier])

        let observation = await LocalReminderReconciler(client: client).reconcile(
            plan: plan,
            observedAt: referenceDate
        )

        XCTAssertEqual(observation.status, .schedulingFailed)
        XCTAssertEqual(observation.confirmedPendingCount, 0)
        XCTAssertNil(observation.scheduledThrough)
        XCTAssertEqual(observation.lastErrorCode, "add-request-failed")
    }

    func testReconcilerReplacesSameIdentifierWithWrongFireDate() async throws {
        let plan = LocalReminderPlanner.plan(
            candidates: [try makeCandidate(ruleIndex: 0, occurrenceIndex: 1)],
            settings: .init(authorization: .authorized, alertsEnabled: true),
            now: referenceDate
        )
        let desired = try XCTUnwrap(plan.requests.first)
        let client = FakeLocalNotificationClient(
            pending: [
                LocalPendingNotificationRequest(
                    identifier: desired.identifier,
                    fireAt: desired.fireAt.addingTimeInterval(60)
                )
            ]
        )

        let observation = await LocalReminderReconciler(client: client).reconcile(
            plan: plan,
            observedAt: referenceDate
        )
        let pending = await client.pendingRequests()

        XCTAssertEqual(observation.status, .scheduledForWindow)
        XCTAssertEqual(pending.first?.fireAt, desired.fireAt)
    }

    private let referenceDate = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeCandidate(
        ruleIndex: Int,
        occurrenceIndex: Int
    ) throws -> LocalReminderCandidate {
        LocalReminderCandidate(
            occurrence: try makeOccurrence(
                ruleIndex: ruleIndex,
                occurrenceIndex: occurrenceIndex
            ),
            state: .unrecorded,
            isEnabled: true,
            snoozedUntil: nil
        )
    }

    private func makeOccurrence(
        ruleIndex: Int,
        occurrenceIndex: Int
    ) throws -> PlannedOccurrence {
        let ruleID = UUID(uuidString: String(
            format: "00000000-0000-0000-%04x-%012x",
            ruleIndex + 1,
            ruleIndex + 1
        ))!
        let fireAt = referenceDate.addingTimeInterval(Double(occurrenceIndex + 1) * 3_600)
        let localTime = try HistoricalLocalTime(
            hour: max(0, min(23, occurrenceIndex + 1)),
            minute: 0,
            second: 0
        )
        return PlannedOccurrence(
            key: "occ:v1:\(ruleID.uuidString.lowercased()):1:20260722T\(String(format: "%02d00", max(0, occurrenceIndex + 1)))",
            scheduleRuleID: ruleID,
            scheduleRevision: 1,
            regimenVersionID: UUID(),
            regimenItemID: UUID(),
            displayName: "项目 \(ruleIndex)",
            localDate: try CivilDateFact(year: 2026, month: 7, day: 22),
            localTime: localTime,
            timeZoneIdentifier: "UTC",
            utcOffsetSeconds: 0,
            instant: fireAt
        )
    }
}

private actor FakeLocalNotificationClient: LocalNotificationClient {
    private var pending: [LocalPendingNotificationRequest]
    private let failAddIdentifiers: Set<String>
    private let ignoresRemovals: Bool

    init(
        pending: [LocalPendingNotificationRequest],
        failAddIdentifiers: Set<String> = [],
        ignoresRemovals: Bool = false
    ) {
        self.pending = pending
        self.failAddIdentifiers = failAddIdentifiers
        self.ignoresRemovals = ignoresRemovals
    }

    func settings() async -> LocalNotificationSettingsSnapshot {
        .init(authorization: .authorized, alertsEnabled: true)
    }

    func requestAuthorization() async throws -> Bool { true }

    func pendingRequests() async -> [LocalPendingNotificationRequest] {
        pending
    }

    func add(_ request: LocalReminderRequest) async throws {
        if failAddIdentifiers.contains(request.identifier) {
            throw FakeFailure.add
        }
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(
            LocalPendingNotificationRequest(
                identifier: request.identifier,
                fireAt: request.fireAt
            )
        )
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) async {
        guard !ignoresRemovals else { return }
        let set = Set(identifiers)
        pending.removeAll { set.contains($0.identifier) }
    }

    private enum FakeFailure: Error {
        case add
    }
}
