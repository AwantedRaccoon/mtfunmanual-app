import Foundation
import SwiftUI

enum AppDataControlCoordinatorFailure: Error, Equatable, Sendable {
    case invalidated
    case nestedExclusiveLease
    case invalidExclusiveResetLease
    case exclusiveResetLeaseNotDrained
}

actor AppDataControlCoordinator {
    enum SharedLeaseKind: Equatable, Sendable {
        case read
        case mutation
        case attachment
        case reminderReconciliation
    }

    struct AttachmentPreviewLease: Equatable, Sendable {
        fileprivate let id: UUID
        fileprivate let generationID: UUID
        fileprivate let sessionEpoch: UUID
    }

    struct ExclusiveResetLease: Equatable, Sendable {
        fileprivate let id: UUID
        fileprivate let generationID: UUID
        fileprivate let sessionEpoch: UUID
    }

    private enum LeaseGroup: Sendable {
        case read
        case mutation
        case exclusive
    }

    private struct TaskLeaseContext: Sendable {
        let sessionEpoch: UUID
        let leaseID: UUID
        let group: LeaseGroup
    }

    private struct SharedLeaseToken: Sendable {
        let id: UUID
        let kind: SharedLeaseKind
    }

    private struct SharedWaiter {
        let token: SharedLeaseToken
        let continuation:
            CheckedContinuation<SharedLeaseToken, any Error>
    }

    private struct ExclusiveWaiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID, any Error>
    }

    private enum RetainedLease {
        case shared(SharedLeaseToken)
        case exclusive(UUID)
    }

    @TaskLocal
    private static var taskLeaseContext: TaskLeaseContext?

    let generationID: UUID
    let sessionEpoch: UUID

    private var isInvalidated = false
    private var activeReadLeaseCount = 0
    private var activeMutationLeaseCount = 0
    private var activeSharedLeases:
        [UUID: SharedLeaseKind] = [:]
    private var activeSharedLeaseRefCounts: [UUID: Int] = [:]
    private var activeExclusiveLeaseID: UUID?
    private var activeExclusiveLeaseRefCount = 0
    private var readWaiters: [SharedWaiter] = []
    private var mutationWaiters: [SharedWaiter] = []
    private var exclusiveWaiters: [ExclusiveWaiter] = []

    init(
        generationID: UUID,
        sessionEpoch: UUID = UUID()
    ) {
        self.generationID = generationID
        self.sessionEpoch = sessionEpoch
    }

    func withReadLease<Output: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        try await withSharedLease(.read, operation)
    }

    func withMutationLease<Output: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        try await withSharedLease(.mutation, operation)
    }

    func withAttachmentLease<Output: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        try await withSharedLease(.attachment, operation)
    }

    func withReminderReconciliationLease<Output: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        try await withSharedLease(
            .reminderReconciliation,
            operation
        )
    }

    func beginAttachmentPreviewLease() async throws
        -> AttachmentPreviewLease {
        let token = try await acquireSharedLease(.attachment)
        do {
            try Task.checkCancellation()
        } catch {
            releaseSharedLease(token)
            throw error
        }
        return AttachmentPreviewLease(
            id: token.id,
            generationID: generationID,
            sessionEpoch: sessionEpoch
        )
    }

    func endAttachmentPreviewLease(
        _ lease: AttachmentPreviewLease
    ) {
        guard lease.generationID == generationID,
              lease.sessionEpoch == sessionEpoch,
              activeSharedLeases[lease.id] == .attachment else {
            return
        }
        releaseSharedLease(
            SharedLeaseToken(id: lease.id, kind: .attachment)
        )
    }

    func withExclusiveMutationLease<Output: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        if Self.taskLeaseContext?.sessionEpoch == sessionEpoch {
            throw AppDataControlCoordinatorFailure
                .nestedExclusiveLease
        }
        let leaseID = try await acquireExclusiveLease()
        do {
            try Task.checkCancellation()
        } catch {
            releaseExclusiveLease(id: leaseID)
            throw error
        }
        do {
            let output = try await Self.$taskLeaseContext.withValue(
                TaskLeaseContext(
                    sessionEpoch: sessionEpoch,
                    leaseID: leaseID,
                    group: .exclusive
                )
            ) {
                try await operation()
            }
            releaseExclusiveLease(id: leaseID)
            return output
        } catch {
            releaseExclusiveLease(id: leaseID)
            throw error
        }
    }

    func beginExclusiveResetLease() async throws
        -> ExclusiveResetLease {
        if Self.taskLeaseContext?.sessionEpoch == sessionEpoch {
            throw AppDataControlCoordinatorFailure
                .nestedExclusiveLease
        }
        let leaseID = try await acquireExclusiveLease()
        do {
            try Task.checkCancellation()
        } catch {
            releaseExclusiveLease(id: leaseID)
            throw error
        }
        return ExclusiveResetLease(
            id: leaseID,
            generationID: generationID,
            sessionEpoch: sessionEpoch
        )
    }

    func withExclusiveResetLease<Output: Sendable>(
        _ lease: ExclusiveResetLease,
        _ operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        guard lease.generationID == generationID,
              lease.sessionEpoch == sessionEpoch,
              activeExclusiveLeaseID == lease.id,
              activeExclusiveLeaseRefCount > 0 else {
            throw AppDataControlCoordinatorFailure
                .invalidExclusiveResetLease
        }
        return try await Self.$taskLeaseContext.withValue(
            TaskLeaseContext(
                sessionEpoch: sessionEpoch,
                leaseID: lease.id,
                group: .exclusive
            )
        ) {
            try await operation()
        }
    }

    func invalidateForReset(
        _ lease: ExclusiveResetLease
    ) throws {
        guard lease.generationID == generationID,
              lease.sessionEpoch == sessionEpoch,
              activeExclusiveLeaseID == lease.id else {
            throw AppDataControlCoordinatorFailure
                .invalidExclusiveResetLease
        }
        guard activeExclusiveLeaseRefCount == 1 else {
            throw AppDataControlCoordinatorFailure
                .exclusiveResetLeaseNotDrained
        }
        invalidate()
    }

    func endExclusiveResetLease(
        _ lease: ExclusiveResetLease
    ) {
        guard lease.generationID == generationID,
              lease.sessionEpoch == sessionEpoch else {
            return
        }
        releaseExclusiveLease(id: lease.id)
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        let reads = readWaiters
        let mutations = mutationWaiters
        let exclusive = exclusiveWaiters
        readWaiters.removeAll()
        mutationWaiters.removeAll()
        exclusiveWaiters.removeAll()
        (reads + mutations).forEach {
            $0.continuation.resume(
                throwing:
                    AppDataControlCoordinatorFailure.invalidated
            )
        }
        exclusive.forEach {
            $0.continuation.resume(
                throwing:
                    AppDataControlCoordinatorFailure.invalidated
            )
        }
    }

    private func withSharedLease<Output: Sendable>(
        _ kind: SharedLeaseKind,
        _ operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        if let retainedLease = retainTaskLease(for: kind) {
            do {
                let output = try await operation()
                releaseRetainedLease(retainedLease)
                return output
            } catch {
                releaseRetainedLease(retainedLease)
                throw error
            }
        }
        let token = try await acquireSharedLease(kind)
        do {
            try Task.checkCancellation()
        } catch {
            releaseSharedLease(token)
            throw error
        }
        do {
            let output = try await Self.$taskLeaseContext.withValue(
                TaskLeaseContext(
                    sessionEpoch: sessionEpoch,
                    leaseID: token.id,
                    group: group(for: kind)
                )
            ) {
                try await operation()
            }
            releaseSharedLease(token)
            return output
        } catch {
            releaseSharedLease(token)
            throw error
        }
    }

    private func retainTaskLease(
        for kind: SharedLeaseKind
    ) -> RetainedLease? {
        guard !isInvalidated,
              let context = Self.taskLeaseContext,
              context.sessionEpoch == sessionEpoch else {
            return nil
        }
        switch context.group {
        case .exclusive:
            guard activeExclusiveLeaseID == context.leaseID,
                  activeExclusiveLeaseRefCount > 0 else {
                return nil
            }
            activeExclusiveLeaseRefCount += 1
            return .exclusive(context.leaseID)
        case .read, .mutation:
            guard let activeKind =
                    activeSharedLeases[context.leaseID],
                  let referenceCount =
                    activeSharedLeaseRefCounts[
                        context.leaseID
                    ],
                  referenceCount > 0 else {
                return nil
            }
            switch (context.group, group(for: kind)) {
            case (.read, .read),
                 (.mutation, .read),
                 (.mutation, .mutation):
                activeSharedLeaseRefCounts[
                    context.leaseID
                ] = referenceCount + 1
                return .shared(
                    SharedLeaseToken(
                        id: context.leaseID,
                        kind: activeKind
                    )
                )
            case (.read, .mutation),
                 (_, .exclusive),
                 (.exclusive, _):
                return nil
            }
        }
    }

    private func releaseRetainedLease(
        _ lease: RetainedLease
    ) {
        switch lease {
        case let .shared(token):
            releaseSharedLease(token)
        case let .exclusive(id):
            releaseExclusiveLease(id: id)
        }
    }

    private func group(
        for kind: SharedLeaseKind
    ) -> LeaseGroup {
        switch kind {
        case .read:
            .read
        case .mutation, .attachment, .reminderReconciliation:
            .mutation
        }
    }

    private func acquireSharedLease(
        _ kind: SharedLeaseKind
    ) async throws -> SharedLeaseToken {
        guard !isInvalidated else {
            throw AppDataControlCoordinatorFailure.invalidated
        }
        let token = SharedLeaseToken(id: UUID(), kind: kind)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation:
                    CheckedContinuation<
                        SharedLeaseToken,
                        any Error
                    >) in
                enqueueSharedLease(
                    token,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelSharedWaiter(id: token.id)
            }
        }
    }

    private func enqueueSharedLease(
        _ token: SharedLeaseToken,
        continuation:
            CheckedContinuation<SharedLeaseToken, any Error>
    ) {
        guard !isInvalidated else {
            continuation.resume(
                throwing:
                    AppDataControlCoordinatorFailure.invalidated
            )
            return
        }
        if canGrantSharedLease(token.kind) {
            reserveSharedLease(token)
            continuation.resume(returning: token)
            return
        }
        let waiter = SharedWaiter(
            token: token,
            continuation: continuation
        )
        switch token.kind {
        case .read:
            readWaiters.append(waiter)
        case .mutation, .attachment, .reminderReconciliation:
            mutationWaiters.append(waiter)
        }
    }

    private func canGrantSharedLease(
        _ kind: SharedLeaseKind
    ) -> Bool {
        guard activeExclusiveLeaseID == nil,
              exclusiveWaiters.isEmpty else {
            return false
        }
        switch kind {
        case .read:
            return activeMutationLeaseCount == 0
                && mutationWaiters.isEmpty
        case .mutation, .attachment, .reminderReconciliation:
            return activeReadLeaseCount == 0
        }
    }

    private func reserveSharedLease(
        _ token: SharedLeaseToken
    ) {
        precondition(activeSharedLeases[token.id] == nil)
        precondition(
            activeSharedLeaseRefCounts[token.id] == nil
        )
        activeSharedLeases[token.id] = token.kind
        activeSharedLeaseRefCounts[token.id] = 1
        switch token.kind {
        case .read:
            activeReadLeaseCount += 1
        case .mutation, .attachment, .reminderReconciliation:
            activeMutationLeaseCount += 1
        }
    }

    private func releaseSharedLease(
        _ token: SharedLeaseToken
    ) {
        guard activeSharedLeases[token.id] == token.kind,
              let referenceCount =
                activeSharedLeaseRefCounts[token.id],
              referenceCount > 0 else {
            return
        }
        if referenceCount > 1 {
            activeSharedLeaseRefCounts[token.id] =
                referenceCount - 1
            return
        }
        activeSharedLeases.removeValue(forKey: token.id)
        activeSharedLeaseRefCounts.removeValue(
            forKey: token.id
        )
        switch token.kind {
        case .read:
            precondition(activeReadLeaseCount > 0)
            activeReadLeaseCount -= 1
        case .mutation, .attachment, .reminderReconciliation:
            precondition(activeMutationLeaseCount > 0)
            activeMutationLeaseCount -= 1
        }
        scheduleWaiters()
    }

    private func cancelSharedWaiter(id: UUID) {
        if let index = readWaiters.firstIndex(
            where: { $0.token.id == id }
        ) {
            let waiter = readWaiters.remove(at: index)
            waiter.continuation.resume(
                throwing: CancellationError()
            )
            scheduleWaiters()
            return
        }
        if let index = mutationWaiters.firstIndex(
            where: { $0.token.id == id }
        ) {
            let waiter = mutationWaiters.remove(at: index)
            waiter.continuation.resume(
                throwing: CancellationError()
            )
            scheduleWaiters()
        }
    }

    private func acquireExclusiveLease() async throws -> UUID {
        guard !isInvalidated else {
            throw AppDataControlCoordinatorFailure.invalidated
        }
        let leaseID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation:
                    CheckedContinuation<UUID, any Error>) in
                enqueueExclusiveLease(
                    id: leaseID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelExclusiveWaiter(id: leaseID)
            }
        }
    }

    private func enqueueExclusiveLease(
        id: UUID,
        continuation: CheckedContinuation<UUID, any Error>
    ) {
        guard !isInvalidated else {
            continuation.resume(
                throwing:
                    AppDataControlCoordinatorFailure.invalidated
            )
            return
        }
        if activeExclusiveLeaseID == nil,
           activeReadLeaseCount == 0,
           activeMutationLeaseCount == 0,
           exclusiveWaiters.isEmpty {
            activeExclusiveLeaseID = id
            activeExclusiveLeaseRefCount = 1
            continuation.resume(returning: id)
            return
        }
        exclusiveWaiters.append(
            ExclusiveWaiter(
                id: id,
                continuation: continuation
            )
        )
    }

    private func releaseExclusiveLease(id: UUID) {
        guard activeExclusiveLeaseID == id,
              activeExclusiveLeaseRefCount > 0 else {
            return
        }
        if activeExclusiveLeaseRefCount > 1 {
            activeExclusiveLeaseRefCount -= 1
            return
        }
        activeExclusiveLeaseID = nil
        activeExclusiveLeaseRefCount = 0
        scheduleWaiters()
    }

    private func cancelExclusiveWaiter(id: UUID) {
        guard let index = exclusiveWaiters.firstIndex(
            where: { $0.id == id }
        ) else {
            return
        }
        let waiter = exclusiveWaiters.remove(at: index)
        waiter.continuation.resume(
            throwing: CancellationError()
        )
        scheduleWaiters()
    }

    private func scheduleWaiters() {
        guard !isInvalidated,
              activeExclusiveLeaseID == nil else {
            return
        }
        if activeReadLeaseCount == 0,
           activeMutationLeaseCount == 0,
           let waiter = exclusiveWaiters.first {
            exclusiveWaiters.removeFirst()
            activeExclusiveLeaseID = waiter.id
            activeExclusiveLeaseRefCount = 1
            waiter.continuation.resume(returning: waiter.id)
            return
        }
        guard exclusiveWaiters.isEmpty else { return }
        if activeReadLeaseCount == 0,
           !mutationWaiters.isEmpty {
            let waiters = mutationWaiters
            mutationWaiters.removeAll()
            for waiter in waiters {
                reserveSharedLease(waiter.token)
            }
            waiters.forEach {
                $0.continuation.resume(returning: $0.token)
            }
            return
        }
        if activeMutationLeaseCount == 0,
           mutationWaiters.isEmpty,
           !readWaiters.isEmpty {
            let waiters = readWaiters
            readWaiters.removeAll()
            for waiter in waiters {
                reserveSharedLease(waiter.token)
            }
            waiters.forEach {
                $0.continuation.resume(returning: $0.token)
            }
        }
    }
}

private struct AppDataControlCoordinatorEnvironmentKey:
    EnvironmentKey {
    static let defaultValue: AppDataControlCoordinator? = nil
}

extension EnvironmentValues {
    var appDataControlCoordinator: AppDataControlCoordinator? {
        get {
            self[AppDataControlCoordinatorEnvironmentKey.self]
        }
        set {
            self[AppDataControlCoordinatorEnvironmentKey.self] =
                newValue
        }
    }
}
