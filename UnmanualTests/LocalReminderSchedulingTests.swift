import Foundation
import SwiftData
import UIKit
import XCTest
@testable import Unmanual

final class LocalReminderSchedulingTests: XCTestCase {
    func testAppTemporalChangePolicyIncludesEveryReminderReconciliationBoundary() {
        XCTAssertEqual(
            AppReminderLifecyclePolicy.temporalNotificationNames,
            [
                .NSCalendarDayChanged,
                UIApplication.significantTimeChangeNotification,
                .NSSystemTimeZoneDidChange
            ]
        )
        XCTAssertFalse(
            AppReminderLifecyclePolicy.shouldReconcile(
                notificationName: Notification.Name("unrelated")
            )
        )
    }

    @MainActor
    func testReadyReconciliationRefreshesOnlyAfterCoverageWriteCompletes() async {
        var events: [String] = []

        await AppReminderLifecycleFlow.reconcileThenRefresh(
            reconcile: {
                events.append("reconcile-start")
                await Task.yield()
                events.append("reconcile-complete")
            },
            refresh: {
                events.append("refresh")
            }
        )

        XCTAssertEqual(events, ["reconcile-start", "reconcile-complete", "refresh"])
    }

    @MainActor
    func testReminderInputInvalidationFailureImmediatelyOverridesStaleCoverage() {
        let runtime = LocalReminderRuntime(client: FakeLocalNotificationClient(pending: []))

        runtime.noteReminderInputsChanged(coverageWasInvalidated: false)

        XCTAssertEqual(runtime.lastErrorCode, "coverage-invalidation-failed")
    }

    @MainActor
    func testRecoveryCleanupRemovesOwnedPendingAndPreservesForeignRequests() async {
        let ownedID = LocalReminderPlanner.requestPrefix + "owned"
        let foreignID = "foreign.calendar.reminder"
        let client = FakeLocalNotificationClient(
            pending: [
                LocalPendingNotificationRequest(identifier: ownedID, fireAt: referenceDate),
                LocalPendingNotificationRequest(identifier: foreignID, fireAt: referenceDate)
            ]
        )
        let runtime = LocalReminderRuntime(client: client)

        let didClear = await runtime.clearOwnedPending()
        XCTAssertTrue(didClear)
        let pending = await client.pendingRequests()
        XCTAssertFalse(pending.contains { $0.identifier == ownedID })
        XCTAssertTrue(pending.contains { $0.identifier == foreignID })
    }

    @MainActor
    func testRecoveryCleanupRetriesAndReportsUnverifiedOwnedRemoval() async {
        let ownedID = LocalReminderPlanner.requestPrefix + "owned"
        let foreignID = "foreign.calendar.reminder"
        let client = FakeLocalNotificationClient(
            pending: [
                LocalPendingNotificationRequest(identifier: ownedID, fireAt: referenceDate),
                LocalPendingNotificationRequest(identifier: foreignID, fireAt: referenceDate)
            ],
            ignoresRemovals: true
        )
        let runtime = LocalReminderRuntime(client: client)

        let didClear = await runtime.suspendForRecoveryAndClearOwnedPending()

        XCTAssertFalse(didClear)
        XCTAssertEqual(runtime.lastErrorCode, "recovery-owned-removal-unverified")
        let pending = await client.pendingRequests()
        XCTAssertTrue(pending.contains { $0.identifier == ownedID })
        XCTAssertTrue(pending.contains { $0.identifier == foreignID })
    }

    @MainActor
    func testRecoverySuspensionClearsRequestAddedByInFlightReconcile() async throws {
        let store = try makeEnabledRuntimeStore()
        let client = BlockingAddNotificationClient()
        let runtime = LocalReminderRuntime(client: client)
        let reconcileTask = Task {
            await runtime.reconcile(
                reader: store.reader,
                writer: store.writer,
                now: referenceDate,
                displayTimeZoneIdentifier: "UTC"
            )
        }
        await client.waitUntilAddStarts()

        let recoveryTask = Task {
            await runtime.suspendForRecoveryAndClearOwnedPending()
        }
        for _ in 0..<100 where !runtime.isSuspendedForRecovery {
            await Task.yield()
        }
        XCTAssertTrue(runtime.isSuspendedForRecovery)
        await client.releaseAdd()
        await reconcileTask.value
        let didClear = await recoveryTask.value
        XCTAssertTrue(didClear)

        let pending = await client.pendingRequests()
        XCTAssertFalse(pending.contains {
            $0.identifier.hasPrefix(LocalReminderPlanner.requestPrefix)
        })
    }

    @MainActor
    func testRecoverySuspensionInvalidatesAuthorizationRequestBeforeReconcile() async throws {
        let store = try makeEnabledRuntimeStore()
        let client = BlockingAuthorizationNotificationClient()
        let runtime = LocalReminderRuntime(client: client)
        let authorizationTask = Task {
            await runtime.requestAuthorizationAndReconcile(
                reader: store.reader,
                writer: store.writer,
                displayTimeZoneIdentifier: "UTC"
            )
        }
        await client.waitUntilAuthorizationStarts()

        let didClear = await runtime.suspendForRecoveryAndClearOwnedPending()
        XCTAssertTrue(didClear)
        await client.releaseAuthorization()
        await authorizationTask.value

        let pending = await client.pendingRequests()
        XCTAssertTrue(pending.isEmpty)
    }

    @MainActor
    func testPlanningFailurePersistsFailureAndRemovesOnlyOwnedPending() async throws {
        let container = try AppModelContainerFactory.makeInMemoryTodayContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        _ = try TodayExecutionBackfill.run(in: container)
        let storage = AppWriteActor(modelContainer: container)
        let writer = AppDataWriter(
            storage: storage,
            verifyStoreProtection: { true },
            onProtectionFailure: {}
        )
        try await writer.updateNotificationCoverage(
            LocalReminderReconciliationObservation(
                status: .scheduledForWindow,
                scheduledThrough: referenceDate.addingTimeInterval(86_400),
                desiredCount: 1,
                confirmedPendingCount: 1,
                lastErrorCode: nil,
                observedAt: referenceDate
            )
        )
        let ownedID = LocalReminderPlanner.requestPrefix + "stale"
        let foreignID = "foreign.calendar.reminder"
        let client = FakeLocalNotificationClient(
            pending: [
                LocalPendingNotificationRequest(identifier: ownedID, fireAt: referenceDate),
                LocalPendingNotificationRequest(identifier: foreignID, fireAt: referenceDate)
            ]
        )
        let runtime = LocalReminderRuntime(client: client)
        let reader = AppReadActor(modelContainer: container)

        await runtime.reconcile(
            reader: reader,
            writer: writer,
            now: referenceDate,
            displayTimeZoneIdentifier: "Invalid/TimeZone"
        )

        let snapshot = try await reader.todayExecutionSnapshot(
            now: referenceDate,
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertEqual(snapshot.coverage.status, .schedulingFailed)
        XCTAssertEqual(snapshot.coverage.lastErrorCode, "reconciliation-unavailable")
        let pending = await client.pendingRequests()
        XCTAssertFalse(pending.contains { $0.identifier == ownedID })
        XCTAssertTrue(pending.contains { $0.identifier == foreignID })
    }

    @MainActor
    func testReentrantReconcileUsesLatestRequestContext() async throws {
        let first = try makeRuntimeStore()
        let latest = try makeRuntimeStore()
        let client = BlockingSettingsNotificationClient()
        let runtime = LocalReminderRuntime(client: client)

        let firstTask = Task {
            await runtime.reconcile(
                reader: first.reader,
                writer: first.writer,
                now: referenceDate,
                displayTimeZoneIdentifier: "UTC"
            )
        }
        await client.waitUntilFirstSettingsReadStarts()

        let latestTask = Task {
            await runtime.reconcile(
                reader: latest.reader,
                writer: latest.writer,
                now: referenceDate.addingTimeInterval(3_600),
                displayTimeZoneIdentifier: "Invalid/LatestTimeZone"
            )
        }
        await Task.yield()
        await client.releaseFirstSettingsRead()
        await firstTask.value
        await latestTask.value

        let latestSnapshot = try await latest.reader.todayExecutionSnapshot(
            now: referenceDate,
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertEqual(latestSnapshot.coverage.status, .schedulingFailed)
        XCTAssertEqual(latestSnapshot.coverage.lastErrorCode, "reconciliation-unavailable")
    }

    @MainActor
    func testReconcileSupersededDuringAddStopsBeforeSubmittingMoreOwnedRequests() async throws {
        let first = try makeEnabledRuntimeStore()
        let latest = try makeRuntimeStore()
        let client = BlockingAddNotificationClient()
        let runtime = LocalReminderRuntime(client: client)
        let firstTask = Task {
            await runtime.reconcile(
                reader: first.reader,
                writer: first.writer,
                now: referenceDate,
                displayTimeZoneIdentifier: "UTC"
            )
        }
        await client.waitUntilAddStarts()

        let latestStarted = AsyncCompletionProbe()
        let latestTask = Task {
            await latestStarted.markStarted()
            await runtime.reconcile(
                reader: latest.reader,
                writer: latest.writer,
                now: referenceDate.addingTimeInterval(60),
                displayTimeZoneIdentifier: "UTC"
            )
            await latestStarted.markFinished()
        }
        await latestStarted.waitUntilStarted()
        await Task.yield()
        await client.releaseAdd()
        await firstTask.value
        await latestTask.value

        let addCallCount = await client.addCallCount()
        XCTAssertEqual(addCallCount, 1)
        let pending = await client.pendingRequests()
        XCTAssertFalse(pending.contains {
            $0.identifier.hasPrefix(LocalReminderPlanner.requestPrefix)
        })
    }

    @MainActor
    func testReconcileCallOrderWinsWhenEarlierClockReadCompletesLast() async throws {
        let store = try makeRuntimeStore()
        let latestDate = referenceDate.addingTimeInterval(3_600)
        let clock = ReorderingReminderClock(first: referenceDate, second: latestDate)
        let runtime = LocalReminderRuntime(
            client: FakeLocalNotificationClient(pending: []),
            now: { await clock.current() }
        )
        let earlierTask = Task {
            await runtime.reconcile(
                reader: store.reader,
                writer: store.writer,
                displayTimeZoneIdentifier: "Invalid/EarlierTimeZone"
            )
        }
        await clock.waitUntilFirstReadStarts()

        await runtime.reconcile(
            reader: store.reader,
            writer: store.writer,
            displayTimeZoneIdentifier: "UTC"
        )
        await clock.releaseFirstRead()
        await earlierTask.value

        let snapshot = try await store.reader.todayExecutionSnapshot(
            now: latestDate,
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertEqual(snapshot.coverage.status, .disabledByUser)
        XCTAssertEqual(snapshot.coverage.observedAt, latestDate)
    }

    @MainActor
    func testAuthorizationReconcileUsesClockAfterPromptReturns() async throws {
        let store = try makeRuntimeStore()
        let client = BlockingAuthorizationNotificationClient()
        let clock = MutableReminderClock(referenceDate)
        let runtime = LocalReminderRuntime(
            client: client,
            now: { await clock.current() }
        )
        let afterPrompt = referenceDate.addingTimeInterval(7_200)

        let task = Task {
            await runtime.requestAuthorizationAndReconcile(
                reader: store.reader,
                writer: store.writer,
                displayTimeZoneIdentifier: "UTC"
            )
        }
        await client.waitUntilAuthorizationStarts()
        await clock.set(afterPrompt)
        await client.releaseAuthorization()
        await task.value

        let snapshot = try await store.reader.todayExecutionSnapshot(
            now: afterPrompt,
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertEqual(snapshot.coverage.observedAt, afterPrompt)
    }

    @MainActor
    func testAuthorizationFailureIsNotOverwrittenByOrdinaryReconcile() async throws {
        let store = try makeRuntimeStore()
        let runtime = LocalReminderRuntime(client: AuthorizationFailureNotificationClient())

        await runtime.requestAuthorizationAndReconcile(
            reader: store.reader,
            writer: store.writer,
            now: referenceDate,
            displayTimeZoneIdentifier: "UTC"
        )

        let snapshot = try await store.reader.todayExecutionSnapshot(
            now: referenceDate,
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertEqual(snapshot.coverage.status, .schedulingFailed)
        XCTAssertEqual(snapshot.coverage.lastErrorCode, "authorization-request-failed")
        XCTAssertEqual(runtime.lastErrorCode, "authorization-request-failed")
    }

    @MainActor
    func testAuthorizationCompletionSupersedesAutomaticReconcileStartedDuringPrompt() async throws {
        let store = try makeEnabledRuntimeStore()
        let client = BlockingTransitionAuthorizationNotificationClient()
        let runtime = LocalReminderRuntime(client: client)

        let authorizationTask = Task {
            await runtime.requestAuthorizationAndReconcile(
                reader: store.reader,
                writer: store.writer,
                now: referenceDate,
                displayTimeZoneIdentifier: "UTC"
            )
        }
        await client.waitUntilAuthorizationStarts()

        await runtime.reconcile(
            reader: store.reader,
            writer: store.writer,
            now: referenceDate.addingTimeInterval(60),
            displayTimeZoneIdentifier: "UTC"
        )
        await client.releaseAuthorizationAsGranted()
        await authorizationTask.value

        let snapshot = try await store.reader.todayExecutionSnapshot(
            now: referenceDate,
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertEqual(snapshot.coverage.status, .scheduledForWindow)
        XCTAssertEqual(snapshot.coverage.observedAt, referenceDate)
        XCTAssertNil(snapshot.coverage.lastErrorCode)
        let pending = await client.pendingRequests()
        XCTAssertFalse(pending.isEmpty)
    }

    @MainActor
    func testQueuedReconcileDoesNotReturnBeforeItsWorkIsProcessed() async throws {
        let store = try makeRuntimeStore()
        let client = BlockingSettingsNotificationClient()
        let runtime = LocalReminderRuntime(client: client)
        let probe = AsyncCompletionProbe()
        let firstTask = Task {
            await runtime.reconcile(
                reader: store.reader,
                writer: store.writer,
                now: referenceDate,
                displayTimeZoneIdentifier: "UTC"
            )
        }
        await client.waitUntilFirstSettingsReadStarts()

        let queuedTask = Task {
            await probe.markStarted()
            await runtime.reconcile(
                reader: store.reader,
                writer: store.writer,
                now: referenceDate.addingTimeInterval(60),
                displayTimeZoneIdentifier: "UTC"
            )
            await probe.markFinished()
        }
        await probe.waitUntilStarted()
        for _ in 0..<100 where !(await probe.isFinished()) {
            await Task.yield()
        }
        let didFinishBeforeRelease = await probe.isFinished()
        XCTAssertFalse(didFinishBeforeRelease)

        await client.releaseFirstSettingsRead()
        await firstTask.value
        await queuedTask.value
        let didFinishAfterRelease = await probe.isFinished()
        XCTAssertTrue(didFinishAfterRelease)
    }

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

    func testReconcilerRejectsDuplicateDesiredIdentifiersAndClearsOwnedRequests() async throws {
        let candidate = try makeCandidate(ruleIndex: 0, occurrenceIndex: 1)
        let request = try XCTUnwrap(
            LocalReminderPlanner.plan(
                candidates: [candidate],
                settings: .init(authorization: .authorized, alertsEnabled: true),
                now: referenceDate
            ).requests.first
        )
        XCTAssertFalse(
            LocalReminderReconciler.desiredRequestsHaveUniqueIdentifiers([request, request])
        )
        let plan = LocalReminderPlan(
            status: .scheduledForWindow,
            requests: [request, request],
            scheduledThrough: request.fireAt
        )
        let foreign = LocalPendingNotificationRequest(
            identifier: "foreign.reminder",
            fireAt: referenceDate
        )
        let owned = LocalPendingNotificationRequest(
            identifier: LocalReminderPlanner.requestPrefix + "stale-owned",
            fireAt: referenceDate
        )
        let client = FakeLocalNotificationClient(pending: [foreign, owned])

        let observation = await LocalReminderReconciler(client: client).reconcile(
            plan: plan,
            observedAt: referenceDate
        )

        XCTAssertEqual(observation.status, .schedulingFailed)
        XCTAssertEqual(observation.lastErrorCode, "duplicate-desired-request-id")
        let pending = await client.pendingRequests()
        XCTAssertEqual(pending, [foreign])
    }

    func testReconcilerUsesLatestForeignCountBeforeAddingOwnedRequests() async throws {
        let candidates = try (0..<60).map {
            try makeCandidate(ruleIndex: $0, occurrenceIndex: $0 + 1)
        }
        let plan = LocalReminderPlanner.plan(
            candidates: candidates,
            settings: .init(authorization: .authorized, alertsEnabled: true),
            now: referenceDate
        )
        XCTAssertEqual(plan.requests.count, 60)
        let client = HardLimitNotificationClient(foreignCount: 59)

        let observation = await LocalReminderReconciler(client: client).reconcile(
            plan: plan,
            observedAt: referenceDate
        )
        let pending = await client.pendingRequests()
        let addCallCount = await client.addCallCount()
        let peakPendingCount = await client.peakPendingCount()

        XCTAssertEqual(addCallCount, 1)
        XCTAssertEqual(peakPendingCount, LocalReminderPlanner.requestBudget)
        XCTAssertEqual(pending.count, LocalReminderPlanner.requestBudget)
        XCTAssertEqual(
            pending.count { !$0.identifier.hasPrefix(LocalReminderPlanner.requestPrefix) },
            59
        )
        XCTAssertEqual(observation.status, .schedulingFailed)
        XCTAssertEqual(observation.lastErrorCode, "notification-budget-changed")
    }

    func testForeignPendingGrowthCannotLeaveOwnedRequestsOverSystemBudget() async throws {
        let candidates = try (0..<60).map {
            try makeCandidate(ruleIndex: $0, occurrenceIndex: $0 + 1)
        }
        let plan = LocalReminderPlanner.plan(
            candidates: candidates,
            settings: .init(authorization: .authorized, alertsEnabled: true),
            now: referenceDate
        )
        XCTAssertEqual(plan.requests.count, 60)
        let client = GrowingForeignNotificationClient(
            foreignCountInjectedAtFinalRead: 59
        )

        let observation = await LocalReminderReconciler(client: client).reconcile(
            plan: plan,
            observedAt: referenceDate
        )
        let pending = await client.pendingRequests()
        let ownedCount = pending.count {
            $0.identifier.hasPrefix(LocalReminderPlanner.requestPrefix)
        }
        let foreignCount = pending.count - ownedCount

        XCTAssertEqual(observation.status, .schedulingFailed)
        XCTAssertEqual(observation.lastErrorCode, "notification-budget-changed")
        XCTAssertLessThanOrEqual(pending.count, LocalReminderPlanner.requestBudget)
        XCTAssertEqual(foreignCount, 59)
        XCTAssertLessThanOrEqual(ownedCount, 1)
    }

    func testForeignPendingGrowthDuringCleanupCannotLeaveOwnedRequestsOverBudget() async throws {
        let candidates = try (0..<60).map {
            try makeCandidate(ruleIndex: $0, occurrenceIndex: $0 + 1)
        }
        let plan = LocalReminderPlanner.plan(
            candidates: candidates,
            settings: .init(authorization: .authorized, alertsEnabled: true),
            now: referenceDate
        )
        let client = GrowingForeignNotificationClient(
            foreignCountInjectedAtFinalRead: 59,
            additionalForeignInjectedAtCleanupRead: 1
        )

        let observation = await LocalReminderReconciler(client: client).reconcile(
            plan: plan,
            observedAt: referenceDate
        )
        let pending = await client.pendingRequests()

        XCTAssertEqual(observation.status, .schedulingFailed)
        XCTAssertEqual(observation.lastErrorCode, "notification-budget-changed")
        XCTAssertLessThanOrEqual(pending.count, LocalReminderPlanner.requestBudget)
        XCTAssertFalse(pending.contains {
            $0.identifier.hasPrefix(LocalReminderPlanner.requestPrefix)
        })
    }

    func testForeignGrowthOnEveryShrinkRoundFallsBackToRemovingAllOwnedRequests() async throws {
        let candidates = try (0..<60).map {
            try makeCandidate(ruleIndex: $0, occurrenceIndex: $0 + 1)
        }
        let plan = LocalReminderPlanner.plan(
            candidates: candidates,
            settings: .init(authorization: .authorized, alertsEnabled: true),
            now: referenceDate
        )
        let client = RepeatedlyGrowingForeignNotificationClient()

        let observation = await LocalReminderReconciler(client: client).reconcile(
            plan: plan,
            observedAt: referenceDate
        )
        let pending = await client.pendingRequests()

        XCTAssertEqual(observation.status, .schedulingFailed)
        XCTAssertEqual(observation.lastErrorCode, "notification-budget-changed")
        XCTAssertLessThanOrEqual(pending.count, LocalReminderPlanner.requestBudget)
        XCTAssertFalse(pending.contains {
            $0.identifier.hasPrefix(LocalReminderPlanner.requestPrefix)
        })
    }

    private let referenceDate = Date(timeIntervalSince1970: 1_790_000_000)

    @MainActor
    private func makeRuntimeStore() throws -> (
        reader: AppReadActor,
        writer: AppDataWriter
    ) {
        let container = try AppModelContainerFactory.makeInMemoryTodayContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        _ = try TodayExecutionBackfill.run(in: container)
        return (
            AppReadActor(modelContainer: container),
            AppDataWriter(
                storage: AppWriteActor(modelContainer: container),
                verifyStoreProtection: { true },
                onProtectionFailure: {}
            )
        )
    }

    @MainActor
    private func makeEnabledRuntimeStore() throws -> (
        reader: AppReadActor,
        writer: AppDataWriter
    ) {
        let container = try AppModelContainerFactory.makeInMemoryTodayContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        _ = try TodayExecutionBackfill.run(in: container)
        let context = ModelContext(container)
        let regimen = RegimenPlanVersionRecord(
            code: "R-RUNTIME",
            title: "提醒运行时测试",
            effectiveStartDate: try CivilDateFact(year: 2026, month: 9, day: 1),
            editState: .sealed
        )
        let item = RegimenItemRecord(
            regimenVersionID: regimen.id,
            sortOrder: 0,
            displayName: "运行时项目",
            doseOriginal: "原始用量",
            unitOriginal: "原始单位"
        )
        let rule = ScheduleRuleRecord(
            regimenItemID: item.id,
            kind: .dailyTimes,
            anchorDate: try CivilDateFact(year: 2026, month: 9, day: 1),
            localTimes: "16:00",
            timeZoneBehavior: .fixedZone,
            fixedTimeZoneIdentifier: "UTC"
        )
        context.insert(regimen)
        context.insert(item)
        context.insert(rule)
        context.insert(
            ReminderPreferenceRecord(
                scheduleRuleID: rule.id,
                expectedRuleRevision: rule.revision,
                isEnabled: true,
                lastOperationID: UUID(),
                updatedAt: referenceDate
            )
        )
        try context.save()
        return (
            AppReadActor(modelContainer: container),
            AppDataWriter(
                storage: AppWriteActor(modelContainer: container),
                verifyStoreProtection: { true },
                onProtectionFailure: {}
            )
        )
    }

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

private actor BlockingSettingsNotificationClient: LocalNotificationClient {
    private var didStartFirstSettingsRead = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilFirstSettingsReadStarts() async {
        if didStartFirstSettingsRead { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstSettingsRead() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func settings() async -> LocalNotificationSettingsSnapshot {
        if !didStartFirstSettingsRead {
            didStartFirstSettingsRead = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return .init(authorization: .authorized, alertsEnabled: true)
    }

    func requestAuthorization() async throws -> Bool { true }
    func pendingRequests() async -> [LocalPendingNotificationRequest] { [] }
    func add(_ request: LocalReminderRequest) async throws {}
    func removePendingRequests(withIdentifiers identifiers: [String]) async {}
}

private actor MutableReminderClock {
    private var value: Date

    init(_ value: Date) { self.value = value }
    func current() -> Date { value }
    func set(_ value: Date) { self.value = value }
}

private actor BlockingAuthorizationNotificationClient: LocalNotificationClient {
    private var didStartAuthorization = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilAuthorizationStarts() async {
        if didStartAuthorization { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseAuthorization() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func settings() async -> LocalNotificationSettingsSnapshot {
        .init(authorization: .authorized, alertsEnabled: true)
    }

    func requestAuthorization() async throws -> Bool {
        didStartAuthorization = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return true
    }

    private var pending: [LocalPendingNotificationRequest] = []

    func pendingRequests() async -> [LocalPendingNotificationRequest] { pending }
    func add(_ request: LocalReminderRequest) async throws {
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(
            LocalPendingNotificationRequest(
                identifier: request.identifier,
                fireAt: request.fireAt
            )
        )
    }
    func removePendingRequests(withIdentifiers identifiers: [String]) async {
        let identifiers = Set(identifiers)
        pending.removeAll { identifiers.contains($0.identifier) }
    }
}

private actor AuthorizationFailureNotificationClient: LocalNotificationClient {
    func settings() async -> LocalNotificationSettingsSnapshot {
        .init(authorization: .notDetermined, alertsEnabled: false)
    }

    func requestAuthorization() async throws -> Bool {
        throw AuthorizationFailure.deniedBySystem
    }

    func pendingRequests() async -> [LocalPendingNotificationRequest] { [] }
    func add(_ request: LocalReminderRequest) async throws {}
    func removePendingRequests(withIdentifiers identifiers: [String]) async {}

    private enum AuthorizationFailure: Error {
        case deniedBySystem
    }
}

private actor BlockingTransitionAuthorizationNotificationClient: LocalNotificationClient {
    private var didStartAuthorization = false
    private var authorizationResolved = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilAuthorizationStarts() async {
        if didStartAuthorization { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseAuthorizationAsGranted() {
        authorizationResolved = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func settings() async -> LocalNotificationSettingsSnapshot {
        authorizationResolved
            ? .init(authorization: .authorized, alertsEnabled: true)
            : .init(authorization: .notDetermined, alertsEnabled: false)
    }

    func requestAuthorization() async throws -> Bool {
        didStartAuthorization = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return true
    }

    private var pending: [LocalPendingNotificationRequest] = []

    func pendingRequests() async -> [LocalPendingNotificationRequest] { pending }
    func add(_ request: LocalReminderRequest) async throws {
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(
            LocalPendingNotificationRequest(
                identifier: request.identifier,
                fireAt: request.fireAt
            )
        )
    }
    func removePendingRequests(withIdentifiers identifiers: [String]) async {
        let identifiers = Set(identifiers)
        pending.removeAll { identifiers.contains($0.identifier) }
    }
}

private actor AsyncCompletionProbe {
    private var started = false
    private var finished = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func markFinished() { finished = true }
    func isFinished() -> Bool { finished }
}

private actor GrowingForeignNotificationClient: LocalNotificationClient {
    private var pending: [LocalPendingNotificationRequest] = []
    private var pendingReadCount = 0
    private var didInjectForeign = false
    private let foreignCountInjectedAtFinalRead: Int
    private let additionalForeignInjectedAtCleanupRead: Int

    init(
        foreignCountInjectedAtFinalRead: Int,
        additionalForeignInjectedAtCleanupRead: Int = 0
    ) {
        self.foreignCountInjectedAtFinalRead = foreignCountInjectedAtFinalRead
        self.additionalForeignInjectedAtCleanupRead = additionalForeignInjectedAtCleanupRead
    }

    func settings() async -> LocalNotificationSettingsSnapshot {
        .init(authorization: .authorized, alertsEnabled: true)
    }

    func requestAuthorization() async throws -> Bool { true }

    func pendingRequests() async -> [LocalPendingNotificationRequest] {
        pendingReadCount += 1
        if pendingReadCount >= 2, !didInjectForeign {
            didInjectForeign = true
            pending.append(contentsOf: (0..<foreignCountInjectedAtFinalRead).map { index in
                LocalPendingNotificationRequest(
                    identifier: "foreign.\(index)",
                    fireAt: nil
                )
            })
        }
        if pendingReadCount == 3, additionalForeignInjectedAtCleanupRead > 0 {
            pending.append(contentsOf: (0..<additionalForeignInjectedAtCleanupRead).map { index in
                LocalPendingNotificationRequest(
                    identifier: "foreign.cleanup.\(index)",
                    fireAt: nil
                )
            })
        }
        return pending
    }

    func add(_ request: LocalReminderRequest) async throws {
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(
            LocalPendingNotificationRequest(
                identifier: request.identifier,
                fireAt: request.fireAt
            )
        )
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) async {
        let identifiers = Set(identifiers)
        pending.removeAll { identifiers.contains($0.identifier) }
    }
}

private actor RepeatedlyGrowingForeignNotificationClient: LocalNotificationClient {
    private var pending: [LocalPendingNotificationRequest] = []
    private var pendingReadCount = 0

    func settings() async -> LocalNotificationSettingsSnapshot {
        .init(authorization: .authorized, alertsEnabled: true)
    }

    func requestAuthorization() async throws -> Bool { true }

    func pendingRequests() async -> [LocalPendingNotificationRequest] {
        pendingReadCount += 1
        if pendingReadCount == 2 {
            pending.append(contentsOf: (0..<57).map { index in
                LocalPendingNotificationRequest(identifier: "foreign.base.\(index)", fireAt: nil)
            })
        } else if (3...5).contains(pendingReadCount) {
            pending.append(
                LocalPendingNotificationRequest(
                    identifier: "foreign.growth.\(pendingReadCount)",
                    fireAt: nil
                )
            )
        }
        return pending
    }

    func add(_ request: LocalReminderRequest) async throws {
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(
            LocalPendingNotificationRequest(
                identifier: request.identifier,
                fireAt: request.fireAt
            )
        )
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) async {
        let identifiers = Set(identifiers)
        pending.removeAll { identifiers.contains($0.identifier) }
    }
}

private actor BlockingAddNotificationClient: LocalNotificationClient {
    private var pending: [LocalPendingNotificationRequest] = []
    private var addCalls = 0
    private var didStartAdd = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilAddStarts() async {
        if didStartAdd { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseAdd() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func settings() async -> LocalNotificationSettingsSnapshot {
        .init(authorization: .authorized, alertsEnabled: true)
    }

    func requestAuthorization() async throws -> Bool { true }
    func pendingRequests() async -> [LocalPendingNotificationRequest] { pending }

    func addCallCount() -> Int { addCalls }

    func add(_ request: LocalReminderRequest) async throws {
        addCalls += 1
        if !didStartAdd {
            didStartAdd = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
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
        let identifiers = Set(identifiers)
        pending.removeAll { identifiers.contains($0.identifier) }
    }
}

private actor HardLimitNotificationClient: LocalNotificationClient {
    private var pending: [LocalPendingNotificationRequest]
    private var addCalls = 0
    private var peakCount: Int

    init(foreignCount: Int) {
        pending = (0..<foreignCount).map { index in
            LocalPendingNotificationRequest(identifier: "foreign.hard-limit.\(index)", fireAt: nil)
        }
        peakCount = pending.count
    }

    func settings() async -> LocalNotificationSettingsSnapshot {
        .init(authorization: .authorized, alertsEnabled: true)
    }

    func requestAuthorization() async throws -> Bool { true }
    func pendingRequests() async -> [LocalPendingNotificationRequest] { pending }
    func addCallCount() -> Int { addCalls }
    func peakPendingCount() -> Int { peakCount }

    func add(_ request: LocalReminderRequest) async throws {
        addCalls += 1
        guard pending.count < LocalReminderPlanner.requestBudget else {
            throw CapacityFailure.full
        }
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(
            LocalPendingNotificationRequest(
                identifier: request.identifier,
                fireAt: request.fireAt
            )
        )
        peakCount = max(peakCount, pending.count)
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) async {
        let identifiers = Set(identifiers)
        pending.removeAll { identifiers.contains($0.identifier) }
    }

    private enum CapacityFailure: Error {
        case full
    }
}

private actor ReorderingReminderClock {
    private let firstValue: Date
    private let secondValue: Date
    private var readCount = 0
    private var didStartFirstRead = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(first: Date, second: Date) {
        self.firstValue = first
        self.secondValue = second
    }

    func waitUntilFirstReadStarts() async {
        if didStartFirstRead { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstRead() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func current() async -> Date {
        readCount += 1
        if readCount == 1 {
            didStartFirstRead = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
            return firstValue
        }
        return secondValue
    }
}
