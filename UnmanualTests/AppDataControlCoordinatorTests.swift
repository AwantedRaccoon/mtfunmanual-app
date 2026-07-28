import XCTest
@testable import Unmanual

final class AppDataControlCoordinatorTests: XCTestCase {
    func testReadLeaseBlocksMutationUntilSnapshotReleases()
        async throws {
        let coordinator = AppDataControlCoordinator(
            generationID: UUID()
        )
        let latch = CoordinatorTestLatch()
        let mutationState = CoordinatorTestFlag()

        let readTask = Task {
            try await coordinator.withReadLease {
                await latch.enterAndWait()
            }
        }
        await latch.waitUntilEntered()

        let mutationTask = Task {
            try await coordinator.withMutationLease {
                await mutationState.set()
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        let valueWhileReading = await mutationState.value
        XCTAssertFalse(valueWhileReading)

        await latch.release()
        try await readTask.value
        try await mutationTask.value
        let valueAfterRelease = await mutationState.value
        XCTAssertTrue(valueAfterRelease)
    }

    func testNestedReminderAndWriterMutationLeasesDoNotDeadlock()
        async throws {
        let coordinator = AppDataControlCoordinator(
            generationID: UUID()
        )
        let value = try await coordinator
            .withReminderReconciliationLease {
                try await coordinator.withMutationLease {
                    42
                }
            }
        XCTAssertEqual(value, 42)
    }

    func testPendingLeaseFailsWhenSessionIsInvalidated()
        async throws {
        let coordinator = AppDataControlCoordinator(
            generationID: UUID()
        )
        let latch = CoordinatorTestLatch()
        let readTask = Task {
            try await coordinator.withReadLease {
                await latch.enterAndWait()
            }
        }
        await latch.waitUntilEntered()
        let mutationTask = Task {
            try await coordinator.withMutationLease { true }
        }
        await coordinator.invalidate()

        do {
            _ = try await mutationTask.value
            XCTFail("waiting mutation must fail after invalidation")
        } catch {
            XCTAssertEqual(
                error as? AppDataControlCoordinatorFailure,
                .invalidated
            )
        }
        await latch.release()
        try await readTask.value
    }

    func testCancelledWaiterIsRemovedAndNeverRuns()
        async throws {
        let coordinator = AppDataControlCoordinator(
            generationID: UUID()
        )
        let latch = CoordinatorTestLatch()
        let mutationState = CoordinatorTestFlag()
        let readTask = Task {
            try await coordinator.withReadLease {
                await latch.enterAndWait()
            }
        }
        await latch.waitUntilEntered()

        let cancelledMutation = Task {
            try await coordinator.withMutationLease {
                await mutationState.set()
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        cancelledMutation.cancel()
        do {
            try await cancelledMutation.value
            XCTFail("cancelled waiter must not acquire a lease")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }

        await latch.release()
        try await readTask.value
        let readAfterCancellation = try await coordinator
            .withReadLease { true }
        XCTAssertTrue(readAfterCancellation)
        let mutationRan = await mutationState.value
        XCTAssertFalse(mutationRan)
    }

    func testAttachmentPreviewLeaseBlocksReadUntilPreviewEnds()
        async throws {
        let coordinator = AppDataControlCoordinator(
            generationID: UUID()
        )
        let lease = try await coordinator
            .beginAttachmentPreviewLease()
        let readState = CoordinatorTestFlag()
        let readTask = Task {
            try await coordinator.withReadLease {
                await readState.set()
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        let valueDuringPreview = await readState.value
        XCTAssertFalse(valueDuringPreview)

        await coordinator.endAttachmentPreviewLease(lease)
        try await readTask.value
        let valueAfterPreview = await readState.value
        XCTAssertTrue(valueAfterPreview)
    }

    func testNestedAttachmentWriterLeaseFinishesBeforeQueuedExclusive()
        async throws {
        let coordinator = AppDataControlCoordinator(
            generationID: UUID()
        )
        let latch = CoordinatorTestLatch()
        let order = CoordinatorTestOrder()

        let attachmentTask = Task {
            try await coordinator.withAttachmentLease {
                await latch.enterAndWait()
                _ = try await coordinator.withMutationLease {
                    await order.append("writer")
                    return true
                }
                await order.append("attachment")
            }
        }
        await latch.waitUntilEntered()

        let exclusiveTask = Task {
            try await coordinator.withExclusiveMutationLease {
                await order.append("exclusive")
            }
        }
        await latch.release()
        try await attachmentTask.value
        try await exclusiveTask.value
        let events = await order.values
        XCTAssertEqual(
            events,
            ["writer", "attachment", "exclusive"]
        )
    }

    func testEscapedTaskRetainsReusedLeaseUntilChildFinishes()
        async throws {
        let coordinator = AppDataControlCoordinator(
            generationID: UUID()
        )
        let childReadGate = CoordinatorTestLatch()
        let exclusiveState = CoordinatorTestFlag()

        let escapedTask = try await coordinator.withMutationLease {
            let task = Task {
                try await coordinator.withReadLease {
                    await childReadGate.enterAndWait()
                }
            }
            await childReadGate.waitUntilEntered()
            return task
        }
        let exclusiveTask = Task {
            try await coordinator.withExclusiveMutationLease {
                await exclusiveState.set()
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        let valueWhileEscapedReadIsActive =
            await exclusiveState.value
        XCTAssertFalse(valueWhileEscapedReadIsActive)

        await childReadGate.release()
        try await escapedTask.value
        try await exclusiveTask.value
        let valueAfterChildRead = await exclusiveState.value
        XCTAssertTrue(valueAfterChildRead)
    }

    func testProductionReaderFacadeParticipatesInReadLease()
        async throws {
        let container = try AppModelContainerFactory
            .makeInMemoryDataControlContainer()
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
        _ = try DataControlBackfill.run(
            in: container,
            source: .bootstrapV12
        )
        let coordinator = AppDataControlCoordinator(
            generationID: UUID()
        )
        let reader = AppDataReader(
            storage: AppReadActor(modelContainer: container),
            dataControlCoordinator: coordinator
        )
        let exclusiveGate = CoordinatorTestLatch()
        let readState = CoordinatorTestFlag()

        let exclusiveTask = Task {
            try await coordinator.withExclusiveMutationLease {
                await exclusiveGate.enterAndWait()
            }
        }
        await exclusiveGate.waitUntilEntered()
        let readTask = Task {
            _ = try await reader.archiveSnapshot()
            await readState.set()
        }
        try await Task.sleep(for: .milliseconds(30))
        let valueWhileExclusive = await readState.value
        XCTAssertFalse(valueWhileExclusive)

        await exclusiveGate.release()
        try await exclusiveTask.value
        try await readTask.value
        let valueAfterExclusive = await readState.value
        XCTAssertTrue(valueAfterExclusive)
    }

    func testInvalidatedSessionRejectsNewNestedRetain()
        async throws {
        let coordinator = AppDataControlCoordinator(
            generationID: UUID()
        )
        try await coordinator.withMutationLease {
            await coordinator.invalidate()
            do {
                _ = try await coordinator.withReadLease { true }
                XCTFail(
                    "invalidated session must reject nested work"
                )
            } catch {
                XCTAssertEqual(
                    error as? AppDataControlCoordinatorFailure,
                    .invalidated
                )
            }
        }
    }
}

private actor CoordinatorTestLatch {
    private var entered = false
    private var released = false
    private var enteredWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters:
        [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation {
            releaseWaiters.append($0)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation {
            enteredWaiters.append($0)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor CoordinatorTestFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}

private actor CoordinatorTestOrder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
