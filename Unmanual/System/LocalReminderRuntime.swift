import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class LocalReminderRuntime {
    private(set) var isReconciling = false
    private(set) var isSuspendedForRecovery = false
    private(set) var lastErrorCode: String?
    private var pendingWork: RuntimeWork?
    private var reconciliationEpoch = 0
    private var nextRequestSequence = 0
    private var latestRequestedSequence = 0
    private var reconciliationWaiters: [CheckedContinuation<Void, Never>] = []
    private var recoveryCleanupInProgress = false
    private var recoveryCleanupWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastRecoveryCleanupSucceeded = true

    private let client: any LocalNotificationClient
    private let nowProvider: @Sendable () async -> Date

    init(
        client: any LocalNotificationClient = UserNotificationClient(),
        now: @escaping @Sendable () async -> Date = { Date() }
    ) {
        self.client = client
        self.nowProvider = now
    }

    func reconcile(
        reader: AppReadActor,
        writer: AppDataWriter,
        now: Date? = nil,
        displayTimeZoneIdentifier: String = TimeZone.autoupdatingCurrent.identifier
    ) async {
        let sequence = allocateRequestSequence()
        let epoch = reconciliationEpoch
        guard !isSuspendedForRecovery else { return }

        let resolvedNow: Date
        if let now {
            resolvedNow = now
        } else {
            resolvedNow = await nowProvider()
        }
        guard !isSuspendedForRecovery,
              epoch == reconciliationEpoch,
              sequence == latestRequestedSequence else { return }
        let request = ReconciliationRequest(
            reader: reader,
            writer: writer,
            now: resolvedNow,
            displayTimeZoneIdentifier: displayTimeZoneIdentifier,
            epoch: epoch,
            sequence: sequence
        )
        await process(.reconciliation(request))
    }

    private func process(_ initialWork: RuntimeWork) async {
        if isReconciling {
            if initialWork.sequence > (pendingWork?.sequence ?? 0) {
                pendingWork = initialWork
            }
            await waitForReconciliationToStop()
            return
        }
        isReconciling = true
        defer {
            isReconciling = false
            let waiters = reconciliationWaiters
            reconciliationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        var currentWork: RuntimeWork? = initialWork
        while let current = currentWork {
            pendingWork = nil
            guard isCurrent(current) else {
                currentWork = pendingWork
                continue
            }
            switch current {
            case let .reconciliation(request):
                await performReconciliation(request)
            case let .failure(request):
                await performFailClosed(request)
            }
            currentWork = pendingWork
        }
    }

    private func performReconciliation(_ current: ReconciliationRequest) async {
        do {
            let planning = try await current.reader.reminderPlanningSnapshot(
                now: current.now,
                displayTimeZoneIdentifier: current.displayTimeZoneIdentifier,
                horizonLocalDays: 14
            )
            guard isCurrent(current) else { return }
            let settings = await client.settings()
            guard isCurrent(current) else { return }
            let pending = await client.pendingRequests()
            guard isCurrent(current) else { return }
            let foreignPendingCount = pending.count {
                !$0.identifier.hasPrefix(LocalReminderPlanner.requestPrefix)
            }
            let plan = LocalReminderPlanner.plan(
                candidates: planning.candidates,
                settings: settings,
                now: current.now,
                hasEnabledIntent: planning.hasEnabledIntent,
                foreignPendingCount: foreignPendingCount
            )
            let observation = await LocalReminderReconciler(client: client).reconcile(
                plan: plan,
                observedAt: current.now,
                isCurrent: { await self.isCurrent(current) }
            )
            guard isCurrent(current) else {
                _ = await clearOwnedPending(maxAttempts: 3)
                return
            }
            try await current.writer.updateNotificationCoverage(observation)
            if isCurrent(current) {
                lastErrorCode = observation.lastErrorCode
            }
        } catch {
            if isCurrent(current) {
                await performFailClosed(
                    FailureRequest(
                        writer: current.writer,
                        observedAt: current.now,
                        errorCode: "reconciliation-unavailable",
                        epoch: current.epoch,
                        sequence: current.sequence
                    )
                )
            }
        }
    }

    func noteReminderInputsChanged(coverageWasInvalidated: Bool) {
        if !coverageWasInvalidated {
            lastErrorCode = "coverage-invalidation-failed"
        }
    }

    @discardableResult
    func clearOwnedPending() async -> Bool {
        await clearOwnedPending(maxAttempts: 1)
    }

    @discardableResult
    func suspendForRecoveryAndClearOwnedPending() async -> Bool {
        isSuspendedForRecovery = true
        reconciliationEpoch += 1
        pendingWork = nil

        if recoveryCleanupInProgress {
            await waitForRecoveryCleanup()
            return lastRecoveryCleanupSucceeded
        }
        recoveryCleanupInProgress = true
        defer {
            recoveryCleanupInProgress = false
            let waiters = recoveryCleanupWaiters
            recoveryCleanupWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        _ = await clearOwnedPending(maxAttempts: 3)
        await waitForReconciliationToStop()
        let didClear = await clearOwnedPending(maxAttempts: 3)
        lastRecoveryCleanupSucceeded = didClear
        if !didClear {
            lastErrorCode = "recovery-owned-removal-unverified"
        }
        return didClear
    }

    func resumeAfterRecovery() async {
        await waitForRecoveryCleanup()
        guard isSuspendedForRecovery else { return }
        reconciliationEpoch += 1
        pendingWork = nil
        isSuspendedForRecovery = false
    }

    func requestAuthorizationAndReconcile(
        reader: AppReadActor,
        writer: AppDataWriter,
        now: Date? = nil,
        displayTimeZoneIdentifier: String = TimeZone.autoupdatingCurrent.identifier
    ) async {
        let epoch = reconciliationEpoch
        guard !isSuspendedForRecovery else { return }
        var authorizationRequestFailed = false
        do {
            let granted = try await client.requestAuthorization()
            authorizationRequestFailed = !granted
        } catch {
            authorizationRequestFailed = true
        }
        guard isCurrent(epoch: epoch) else { return }
        let settings = await client.settings()
        guard isCurrent(epoch: epoch) else { return }
        if authorizationRequestFailed {
            if settings.authorization == .notDetermined {
                let observedAt: Date
                if let now {
                    observedAt = now
                } else {
                    observedAt = await nowProvider()
                }
                guard isCurrent(epoch: epoch) else { return }
                let sequence = allocateRequestSequence()
                await process(
                    .failure(
                        FailureRequest(
                            writer: writer,
                            observedAt: observedAt,
                            errorCode: "authorization-request-failed",
                            epoch: epoch,
                            sequence: sequence
                        )
                    )
                )
                return
            }
        }
        let resolvedNow: Date
        if let now {
            resolvedNow = now
        } else {
            resolvedNow = await nowProvider()
        }
        guard isCurrent(epoch: epoch) else { return }
        let sequence = allocateRequestSequence()
        await process(
            .reconciliation(
                ReconciliationRequest(
                    reader: reader,
                    writer: writer,
                    now: resolvedNow,
                    displayTimeZoneIdentifier: displayTimeZoneIdentifier,
                    epoch: epoch,
                    sequence: sequence
                )
            )
        )
    }

    private func performFailClosed(_ request: FailureRequest) async {
        guard isCurrent(request) else { return }
        let didRemoveOwned = await clearOwnedPending(maxAttempts: 3)
        guard isCurrent(request) else { return }
        let finalErrorCode = didRemoveOwned
            ? request.errorCode
            : request.errorCode + "-owned-removal-unverified"
        lastErrorCode = finalErrorCode
        guard isCurrent(request) else { return }
        do {
            try await request.writer.updateNotificationCoverage(
                LocalReminderReconciliationObservation(
                    status: .schedulingFailed,
                    scheduledThrough: nil,
                    desiredCount: 0,
                    confirmedPendingCount: 0,
                    lastErrorCode: finalErrorCode,
                    observedAt: request.observedAt
                )
            )
        } catch {
            lastErrorCode = finalErrorCode
        }
    }

    private func isCurrent(_ request: ReconciliationRequest) -> Bool {
        isCurrent(epoch: request.epoch, sequence: request.sequence)
    }

    private func isCurrent(_ request: FailureRequest) -> Bool {
        isCurrent(epoch: request.epoch, sequence: request.sequence)
    }

    private func isCurrent(_ work: RuntimeWork) -> Bool {
        isCurrent(epoch: work.epoch, sequence: work.sequence)
    }

    private func isCurrent(epoch: Int, sequence: Int) -> Bool {
        !isSuspendedForRecovery
            && epoch == reconciliationEpoch
            && sequence == latestRequestedSequence
    }

    private func isCurrent(epoch: Int) -> Bool {
        !isSuspendedForRecovery && epoch == reconciliationEpoch
    }

    private func allocateRequestSequence() -> Int {
        nextRequestSequence += 1
        latestRequestedSequence = nextRequestSequence
        return nextRequestSequence
    }

    private func clearOwnedPending(maxAttempts: Int) async -> Bool {
        for _ in 0..<max(1, maxAttempts) {
            let pending = await client.pendingRequests()
            let ownedIDs = pending.compactMap { request in
                request.identifier.hasPrefix(LocalReminderPlanner.requestPrefix)
                    ? request.identifier
                    : nil
            }
            if ownedIDs.isEmpty { return true }
            await client.removePendingRequests(withIdentifiers: ownedIDs)
            let remaining = await client.pendingRequests()
            if !remaining.contains(where: {
                $0.identifier.hasPrefix(LocalReminderPlanner.requestPrefix)
            }) {
                return true
            }
        }
        return false
    }

    private func waitForReconciliationToStop() async {
        guard isReconciling else { return }
        await withCheckedContinuation { continuation in
            reconciliationWaiters.append(continuation)
        }
    }

    private func waitForRecoveryCleanup() async {
        guard recoveryCleanupInProgress else { return }
        await withCheckedContinuation { continuation in
            recoveryCleanupWaiters.append(continuation)
        }
    }

    private struct ReconciliationRequest {
        let reader: AppReadActor
        let writer: AppDataWriter
        let now: Date
        let displayTimeZoneIdentifier: String
        let epoch: Int
        let sequence: Int
    }

    private struct FailureRequest {
        let writer: AppDataWriter
        let observedAt: Date
        let errorCode: String
        let epoch: Int
        let sequence: Int
    }

    private enum RuntimeWork {
        case reconciliation(ReconciliationRequest)
        case failure(FailureRequest)

        var epoch: Int {
            switch self {
            case let .reconciliation(request): request.epoch
            case let .failure(request): request.epoch
            }
        }

        var sequence: Int {
            switch self {
            case let .reconciliation(request): request.sequence
            case let .failure(request): request.sequence
            }
        }
    }
}

private struct LocalReminderRuntimeEnvironmentKey: EnvironmentKey {
    static let defaultValue: LocalReminderRuntime? = nil
}

extension EnvironmentValues {
    var localReminderRuntime: LocalReminderRuntime? {
        get { self[LocalReminderRuntimeEnvironmentKey.self] }
        set { self[LocalReminderRuntimeEnvironmentKey.self] = newValue }
    }
}
