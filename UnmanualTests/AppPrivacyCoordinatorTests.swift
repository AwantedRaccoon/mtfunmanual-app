import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class AppPrivacyCoordinatorTests: XCTestCase {
    func testColdGateDoesNotPermitSensitiveRootUntilVerified() async throws {
        let container = try makeReadyContainer()
        let client = ScriptedAuthenticationClient()
        let coordinator = AppPrivacyCoordinator(client: client)
        let generationID = UUID()

        coordinator.handleSceneState(.active)
        XCTAssertFalse(coordinator.permitsSensitiveRoot)
        await coordinator.bind(
            reader: AppReadActor(modelContainer: container),
            generationID: generationID
        )

        XCTAssertEqual(coordinator.gateState, .disabled)
        XCTAssertTrue(coordinator.permitsSensitiveRoot)
        XCTAssertFalse(coordinator.appLockEnabled)
    }

    func testEnabledLockRequiresSuccessAndBackgroundRelocks() async throws {
        let container = try await makeEnabledContainer()
        let client = ScriptedAuthenticationClient(
            outcomes: [.success, .success]
        )
        let coordinator = AppPrivacyCoordinator(client: client)
        coordinator.handleSceneState(.active)
        await coordinator.bind(
            reader: AppReadActor(modelContainer: container),
            generationID: UUID()
        )

        XCTAssertFalse(coordinator.permitsSensitiveRoot)
        XCTAssertEqual(coordinator.gateState, .locked(message: nil))
        await coordinator.unlock()
        XCTAssertEqual(coordinator.gateState, .unlocked)
        XCTAssertTrue(coordinator.permitsSensitiveRoot)

        coordinator.handleSceneState(.inactive)
        XCTAssertEqual(coordinator.gateState, .unlocked)
        XCTAssertFalse(coordinator.permitsSensitiveRoot)
        coordinator.handleSceneState(.active)
        XCTAssertTrue(coordinator.permitsSensitiveRoot)

        coordinator.handleSceneState(.background)
        XCTAssertEqual(coordinator.gateState, .locked(message: nil))
        coordinator.handleSceneState(.active)
        XCTAssertFalse(coordinator.permitsSensitiveRoot)
        await coordinator.unlock()
        XCTAssertTrue(coordinator.permitsSensitiveRoot)
    }

    func testAllAuthenticationFailuresRemainLocked() async throws {
        let failures: [DeviceOwnerAuthenticationFailure] = [
            .authenticationFailed,
            .userCancelled,
            .systemCancelled,
            .appCancelled,
            .notInteractive,
            .passcodeNotSet,
            .biometryUnavailable,
            .biometryNotEnrolled,
            .biometryLockedOut,
            .unknown
        ]
        for failure in failures {
            let container = try await makeEnabledContainer()
            let client = ScriptedAuthenticationClient(
                outcomes: [.failure(failure)]
            )
            let coordinator = AppPrivacyCoordinator(client: client)
            coordinator.handleSceneState(.active)
            await coordinator.bind(
                reader: AppReadActor(modelContainer: container),
                generationID: UUID()
            )

            await coordinator.unlock()

            guard case let .locked(message) = coordinator.gateState else {
                return XCTFail("\(failure) 不得解锁")
            }
            XCTAssertNotNil(message)
            XCTAssertFalse(coordinator.permitsSensitiveRoot)
        }
    }

    func testStaleSuccessAfterBackgroundCannotUnlock() async throws {
        let container = try await makeEnabledContainer()
        let client = ScriptedAuthenticationClient(suspends: true)
        let coordinator = AppPrivacyCoordinator(client: client)
        coordinator.handleSceneState(.active)
        await coordinator.bind(
            reader: AppReadActor(modelContainer: container),
            generationID: UUID()
        )

        let task = Task { await coordinator.unlock() }
        await Task.yield()
        let requestID = try XCTUnwrap(client.requestIDs.last)
        coordinator.handleSceneState(.background)
        coordinator.handleSceneState(.active)
        client.resume(requestID: requestID, with: .success)
        await task.value

        XCTAssertEqual(coordinator.gateState, .locked(message: nil))
        XCTAssertFalse(coordinator.permitsSensitiveRoot)
    }

    func testAuthenticationCallbackWhileInactiveReturnsToRetryableLock()
        async throws {
        let container = try await makeEnabledContainer()
        let client = ScriptedAuthenticationClient(suspends: true)
        let coordinator = AppPrivacyCoordinator(client: client)
        coordinator.handleSceneState(.active)
        await coordinator.bind(
            reader: AppReadActor(modelContainer: container),
            generationID: UUID()
        )

        let firstAttempt = Task { await coordinator.unlock() }
        await Task.yield()
        let firstRequestID = try XCTUnwrap(client.requestIDs.last)
        coordinator.handleSceneState(.inactive)
        client.resume(requestID: firstRequestID, with: .success)
        await firstAttempt.value

        XCTAssertEqual(coordinator.gateState, .locked(message: nil))
        XCTAssertFalse(coordinator.permitsSensitiveRoot)

        coordinator.handleSceneState(.active)
        let retry = Task { await coordinator.unlock() }
        await Task.yield()
        let retryRequestID = try XCTUnwrap(client.requestIDs.last)
        XCTAssertNotEqual(retryRequestID, firstRequestID)
        client.resume(requestID: retryRequestID, with: .success)
        await retry.value

        XCTAssertEqual(coordinator.gateState, .unlocked)
        XCTAssertTrue(coordinator.permitsSensitiveRoot)
    }

    func testOnlyNewestAuthenticationRequestCanUnlock() async throws {
        let container = try await makeEnabledContainer()
        let client = ScriptedAuthenticationClient(suspends: true)
        let coordinator = AppPrivacyCoordinator(client: client)
        coordinator.handleSceneState(.active)
        await coordinator.bind(
            reader: AppReadActor(modelContainer: container),
            generationID: UUID()
        )

        let first = Task { await coordinator.unlock() }
        await Task.yield()
        let firstID = try XCTUnwrap(client.requestIDs.last)
        let second = Task { await coordinator.unlock() }
        await Task.yield()
        let secondID = try XCTUnwrap(client.requestIDs.last)
        XCTAssertNotEqual(firstID, secondID)

        client.resume(requestID: firstID, with: .success)
        await first.value
        XCTAssertFalse(coordinator.permitsSensitiveRoot)
        client.resume(requestID: secondID, with: .success)
        await second.value
        XCTAssertTrue(coordinator.permitsSensitiveRoot)
    }

    func testCommittedEnableWhileBackgroundBecomesLockedOnReturn()
        async throws {
        let container = try makeReadyContainer()
        let coordinator = AppPrivacyCoordinator(
            client: ScriptedAuthenticationClient()
        )
        let generationID = UUID()
        coordinator.handleSceneState(.active)
        await coordinator.bind(
            reader: AppReadActor(modelContainer: container),
            generationID: generationID
        )
        XCTAssertTrue(
            coordinator.permitsSensitiveRoot(for: generationID)
        )

        coordinator.handleSceneState(.background)
        try coordinator.acceptCommitted(
            PrivacyControlSnapshot(
                appLockEnabled: true,
                localRevision: 10,
                digestHex: String(repeating: "a", count: 64),
                lastOperationID: UUID(),
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            generationID: generationID
        )

        XCTAssertEqual(coordinator.gateState, .locked(message: nil))
        coordinator.handleSceneState(.active)
        XCTAssertEqual(coordinator.gateState, .locked(message: nil))
        XCTAssertFalse(
            coordinator.permitsSensitiveRoot(for: generationID)
        )
    }

    func testSensitivePermissionIsBoundToExactGeneration() async throws {
        let container = try makeReadyContainer()
        let coordinator = AppPrivacyCoordinator(
            client: ScriptedAuthenticationClient()
        )
        let firstGenerationID = UUID()
        let replacementGenerationID = UUID()
        coordinator.handleSceneState(.active)
        await coordinator.bind(
            reader: AppReadActor(modelContainer: container),
            generationID: firstGenerationID
        )

        XCTAssertTrue(coordinator.permitsSensitiveRoot)
        XCTAssertTrue(
            coordinator.permitsSensitiveRoot(for: firstGenerationID)
        )
        XCTAssertFalse(
            coordinator.permitsSensitiveRoot(
                for: replacementGenerationID
            )
        )
    }

    func testSettingGrantUsesAuthenticationRequestIdentity() async throws {
        let container = try makeReadyContainer()
        let client = ScriptedAuthenticationClient(outcomes: [.success])
        let coordinator = AppPrivacyCoordinator(client: client)
        let generationID = UUID()
        coordinator.handleSceneState(.active)
        await coordinator.bind(
            reader: AppReadActor(modelContainer: container),
            generationID: generationID
        )

        let grant = try await coordinator.authorizeSettingChange(
            reason: "启用 App Lock"
        )

        XCTAssertEqual(grant.generationID, generationID)
        XCTAssertEqual(grant.operationID, client.requestIDs.last)
    }

    func testUnavailableSettingAuthenticationProducesNoGrant()
        async throws {
        let container = try makeReadyContainer()
        let client = ScriptedAuthenticationClient(
            availability: .unavailable(.passcodeNotSet)
        )
        let coordinator = AppPrivacyCoordinator(client: client)
        coordinator.handleSceneState(.active)
        await coordinator.bind(
            reader: AppReadActor(modelContainer: container),
            generationID: UUID()
        )

        do {
            _ = try await coordinator.authorizeSettingChange(
                reason: "启用 App Lock"
            )
            XCTFail("设备认证不可用时不得产生授权")
        } catch let error as AppPrivacyCoordinatorFailure {
            XCTAssertEqual(error, .unavailable)
        }
        XCTAssertTrue(client.requestIDs.isEmpty)
    }

    func testDeferredNavigationQueueRetainsOnlyNonsensitiveDestination() {
        let queue = DeferredAppNavigationQueue.shared
        _ = queue.consume()
        XCTAssertFalse(
            AppNotificationResponseRouter.route(
                identifier: "foreign.notification"
            )
        )
        XCTAssertNil(queue.consume())
        XCTAssertTrue(
            AppNotificationResponseRouter.route(
                identifier: "unmanual.exec.v1.fixture"
            )
        )
        XCTAssertEqual(queue.consume(), .today)
        XCTAssertNil(queue.consume())
    }

    private func makeReadyContainer() throws -> ModelContainer {
        let container = try AppModelContainerFactory
            .makeInMemoryPrivacyControlContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: "UTC"
        )
        _ = try TodayExecutionBackfill.run(in: container)
        _ = try PersonalTimelineBackfill.run(in: container)
        _ = try CountdownLifecycleBackfill.run(in: container)
        _ = try OnboardingBackfill.run(
            in: container,
            source: .newInstallV8
        )
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0"
        )
        _ = try ParentRecordLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0"
        )
        _ = try PrivacyControlBackfill.run(
            in: container,
            source: .bootstrapV11
        )
        return container
    }

    private func makeEnabledContainer() async throws -> ModelContainer {
        let container = try makeReadyContainer()
        let reader = AppReadActor(modelContainer: container)
        let initial = try await reader.privacyControlSnapshot()
        _ = try await AppWriteActor(
            modelContainer: container
        ).setAppLock(
            SetAppLockCommand(
                operationID: UUID(),
                expectedLocalRevision: initial.localRevision,
                expectedDigestHex: initial.digestHex,
                isEnabled: true
            )
        )
        return container
    }
}

@MainActor
private final class ScriptedAuthenticationClient:
    DeviceOwnerAuthenticationClient {
    var availabilityValue: DeviceOwnerAuthenticationAvailability
    var outcomes: [DeviceOwnerAuthenticationOutcome]
    let suspends: Bool
    private(set) var requestIDs: [UUID] = []
    private var continuations: [
        UUID: CheckedContinuation<
            DeviceOwnerAuthenticationOutcome,
            Never
        >
    ] = [:]

    init(
        availability:
            DeviceOwnerAuthenticationAvailability = .available,
        outcomes: [DeviceOwnerAuthenticationOutcome] = [],
        suspends: Bool = false
    ) {
        availabilityValue = availability
        self.outcomes = outcomes
        self.suspends = suspends
    }

    func availability() -> DeviceOwnerAuthenticationAvailability {
        availabilityValue
    }

    func authenticate(
        requestID: UUID,
        reason _: String
    ) async -> DeviceOwnerAuthenticationOutcome {
        requestIDs.append(requestID)
        if suspends {
            return await withCheckedContinuation { continuation in
                continuations[requestID] = continuation
            }
        }
        return outcomes.isEmpty
            ? .failure(.unknown)
            : outcomes.removeFirst()
    }

    func cancel() {}

    func resume(
        requestID: UUID,
        with outcome: DeviceOwnerAuthenticationOutcome
    ) {
        continuations.removeValue(forKey: requestID)?.resume(
            returning: outcome
        )
    }
}
