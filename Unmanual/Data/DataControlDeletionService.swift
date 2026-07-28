@preconcurrency import UserNotifications
import Foundation
import SwiftUI

struct DataControlNotificationObservation: Equatable, Sendable {
    let pending: [DataControlPendingNotificationEntry]
    let deliveredIdentifiers: Set<String>
}

protocol DataControlNotificationClient: Sendable {
    func pendingIdentifiers() async throws -> [String]
    func deliveredIdentifiers() async throws -> [String]
    func removePendingIdentifiers(_ identifiers: [String]) async throws
}

protocol DataControlManifestProvider: Sendable {
    func manifest() async throws -> DataInventoryManifest
}

extension DataInventoryProductionService:
    DataControlManifestProvider {}

actor SystemDataControlNotificationClient:
    DataControlNotificationClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func deliveredIdentifiers() async -> [String] {
        await center.deliveredNotifications()
            .map(\.request.identifier)
    }

    func removePendingIdentifiers(
        _ identifiers: [String]
    ) async {
        center.removePendingNotificationRequests(
            withIdentifiers: identifiers
        )
    }
}

struct DataControlDeletionPreview: Equatable, Sendable {
    let plan: DataControlDeletionPlan
    let operationID: UUID
    let timestamp: HistoricalTimestamp
    let manifestStateDigest: String
    let manifest: DataInventoryManifest
}

enum DataControlDeletionServiceFailure:
    Error,
    Equatable,
    Sendable {
    case unavailable
    case incompleteManifest
    case impactChanged
    case notificationObservationUnstable
    case notificationCleanupFailed
    case reminderReconciliationFailed
    case postAuditFailed
    case recoveryRequired
}

actor DataControlDeletionService {
    private let generationID: UUID
    private let writer: AppDataWriter
    private let fileStore: AttachmentFileStore
    private let inventoryService:
        any DataControlManifestProvider
    private let notificationClient:
        any DataControlNotificationClient
    private let dataControlCoordinator: AppDataControlCoordinator
    private let recoveryLatch: AttachmentMutationRecoveryLatch
    private let onRecoveryRequired: @Sendable () async -> Void
    private let ioQueue = DataControlDeletionBlockingIOQueue()
    private var hasNotifiedRecovery = false

    init(
        generationID: UUID,
        writer: AppDataWriter,
        fileStore: AttachmentFileStore,
        inventoryService: any DataControlManifestProvider,
        notificationClient:
            any DataControlNotificationClient =
                SystemDataControlNotificationClient(),
        dataControlCoordinator: AppDataControlCoordinator,
        recoveryLatch: AttachmentMutationRecoveryLatch,
        onRecoveryRequired:
            @escaping @Sendable () async -> Void
    ) {
        self.generationID = generationID
        self.writer = writer
        self.fileStore = fileStore
        self.inventoryService = inventoryService
        self.notificationClient = notificationClient
        self.dataControlCoordinator = dataControlCoordinator
        self.recoveryLatch = recoveryLatch
        self.onRecoveryRequired = onRecoveryRequired
    }

    func preview(
        target: DataControlDeletionTarget,
        now: Date = Date(),
        timeZoneIdentifier: String =
            TimeZone.autoupdatingCurrent.identifier
    ) async throws -> DataControlDeletionPreview {
        guard !recoveryLatch.isInvalidated else {
            throw DataControlDeletionServiceFailure.recoveryRequired
        }
        return try await dataControlCoordinator.withReadLease {
            let manifest = try await self.completeManifest()
            let notificationObservation =
                target.kind.isPlannerTarget
                    ? try await self.stableNotificationObservation()
                    : DataControlNotificationObservation(
                        pending: [],
                        deliveredIdentifiers: []
                    )
            var operationIDs: [UUID: UUID] = [:]
            let plan: DataControlDeletionPlan
            do {
                plan = try await self.writer.dataControlDeletionPlan(
                    DataControlDeletionPlanRequest(
                        generationID: self.generationID,
                        target: target,
                        pendingNotifications:
                            notificationObservation.pending
                    )
                )
            } catch let failure as DataControlDeletionFailure {
                guard case let .attachmentOperationIDsRequired(ids) =
                        failure else {
                    throw failure
                }
                operationIDs = Dictionary(
                    uniqueKeysWithValues: ids.map { ($0, UUID()) }
                )
                plan = try await self.writer.dataControlDeletionPlan(
                    DataControlDeletionPlanRequest(
                        generationID: self.generationID,
                        target: target,
                        attachmentDeletionOperationIDs:
                            operationIDs,
                        pendingNotifications:
                            notificationObservation.pending
                    )
                )
            }
            let deletionIDs = Set(operationIDs.values)
            var operationID = UUID()
            while deletionIDs.contains(operationID) {
                operationID = UUID()
            }
            let timestamp = try HistoricalTimestamp.captured(
                instant: now,
                timeZoneIdentifier: timeZoneIdentifier,
                precision: .second,
                provenance: .userEntered
            )
            return DataControlDeletionPreview(
                plan: plan,
                operationID: operationID,
                timestamp: timestamp,
                manifestStateDigest: manifest.stateDigest,
                manifest: manifest
            )
        }
    }

    func confirm(
        _ preview: DataControlDeletionPreview,
        reconcileReminders:
            @escaping @MainActor @Sendable () async -> Bool = {
                true
            }
    ) async throws -> DataControlDeletionWriteResult {
        return try await dataControlCoordinator
            .withExclusiveMutationLease {
                try await self.confirmUnderExclusiveLease(
                    preview,
                    reconcileReminders: reconcileReminders
                )
            }
    }

    private func confirmUnderExclusiveLease(
        _ preview: DataControlDeletionPreview,
        reconcileReminders:
            @escaping @MainActor @Sendable () async -> Bool
    ) async throws -> DataControlDeletionWriteResult {
        let command = preview.plan.command(
            operationID: preview.operationID,
            timestamp: preview.timestamp
        )
        if let replay = try await writer
            .replayCommittedDataControlDeletion(
                impact: preview.plan.impact,
                command: command,
                activeGenerationID: generationID
            ) {
            return try await resumeCommittedDeletion(
                replay,
                preview: preview,
                reconcileReminders:
                    reconcileReminders
            )
        }
        guard !recoveryLatch.isInvalidated else {
            throw DataControlDeletionServiceFailure.recoveryRequired
        }
        let manifest = try await completeManifest()
        guard manifest.stateDigest == preview.manifestStateDigest,
              manifest.generationID == generationID,
              manifest.datasetID
                == preview.plan.impact.datasetID,
              manifest.nextLocalRevision
                == preview.plan.impact.expectedNextLocalRevision else {
            throw DataControlDeletionServiceFailure.impactChanged
        }
        let target = try target(from: preview.plan.impact)
        let attachmentEntries = try decodedAttachments(
            preview.plan.impact.attachmentManifest
        )
        let notificationObservation:
            DataControlNotificationObservation
        if target.kind.isPlannerTarget {
            notificationObservation =
                try await stableNotificationObservation()
            guard DataControlPendingNotificationManifest.encode(
                notificationObservation.pending
            ) == preview.plan.impact.notificationManifest else {
                throw DataControlDeletionServiceFailure
                    .impactChanged
            }
        } else {
            notificationObservation =
                DataControlNotificationObservation(
                    pending: [],
                    deliveredIdentifiers: []
                )
        }
        let operationIDs = Dictionary(
            uniqueKeysWithValues: attachmentEntries.map {
                ($0.attachmentID, $0.deletionOperationID)
            }
        )
        guard !Set(operationIDs.values).contains(
            preview.operationID
        ) else {
            throw DataControlDeletionServiceFailure.impactChanged
        }
        let currentPlan = try await writer.dataControlDeletionPlan(
            DataControlDeletionPlanRequest(
                generationID: generationID,
                target: target,
                attachmentDeletionOperationIDs: operationIDs,
                pendingNotifications:
                    notificationObservation.pending
            )
        )
        guard currentPlan == preview.plan else {
            throw DataControlDeletionServiceFailure.impactChanged
        }

        let staged = try await stageAttachments(attachmentEntries)
        let result: DataControlDeletionWriteResult
        do {
            result = try await writer.commitDataControlDeletion(
                impact: preview.plan.impact,
                command: command,
                activeGenerationID: generationID
            )
        } catch {
            do {
                try await rollbackAttachments(staged)
            } catch {
                await requireRecovery()
                throw DataControlDeletionServiceFailure
                    .recoveryRequired
            }
            throw error
        }

        do {
            try await finalizeAttachments(staged)
        } catch {
            await requireRecovery()
            throw DataControlDeletionServiceFailure.recoveryRequired
        }

        if target.kind.isPlannerTarget {
            do {
                try await removeAllOwnedPending()
                guard await reconcileReminders() else {
                    throw DataControlDeletionServiceFailure
                        .reminderReconciliationFailed
                }
                let post = try await stableNotificationObservation()
                guard post.deliveredIdentifiers
                        == notificationObservation
                            .deliveredIdentifiers else {
                    throw DataControlDeletionServiceFailure
                        .notificationCleanupFailed
                }
            } catch {
                await requireRecovery()
                throw DataControlDeletionServiceFailure.recoveryRequired
            }
        }
        do {
            _ = try await completeManifest()
        } catch {
            await requireRecovery()
            throw DataControlDeletionServiceFailure.recoveryRequired
        }
        guard !recoveryLatch.isInvalidated else {
            throw DataControlDeletionServiceFailure.recoveryRequired
        }
        return result
    }

    private func resumeCommittedDeletion(
        _ replay: DataControlDeletionWriteResult,
        preview: DataControlDeletionPreview,
        reconcileReminders:
            @escaping @MainActor @Sendable () async -> Bool
    ) async throws -> DataControlDeletionWriteResult {
        do {
            let evidence = try await writer
                .dataControlAttachmentRecoveryEvidence()
            _ = try await ioQueue.perform { [fileStore] in
                try fileStore.recover(
                    committedAttachments:
                        evidence.committedAttachments,
                    committedDeletions:
                        evidence.committedDeletions
                )
            }
            let target = try target(
                from: preview.plan.impact
            )
            if target.kind.isPlannerTarget {
                let before = try await
                    stableNotificationObservation()
                try await removeAllOwnedPending()
                guard await reconcileReminders() else {
                    throw DataControlDeletionServiceFailure
                        .reminderReconciliationFailed
                }
                let after = try await
                    stableNotificationObservation()
                guard after.deliveredIdentifiers
                        == before.deliveredIdentifiers else {
                    throw DataControlDeletionServiceFailure
                        .notificationCleanupFailed
                }
            }
            _ = try await completeManifest()
            return replay
        } catch {
            await requireRecovery()
            throw DataControlDeletionServiceFailure
                .recoveryRequired
        }
    }

    private func completeManifest()
        async throws -> DataInventoryManifest {
        let manifest = try await inventoryService.manifest()
        guard manifest.destructiveActionsEnabled,
              manifest.generationID == generationID else {
            throw DataControlDeletionServiceFailure
                .incompleteManifest
        }
        return manifest
    }

    private func stableNotificationObservation()
        async throws -> DataControlNotificationObservation {
        let firstPending =
            try await notificationClient.pendingIdentifiers()
        let firstDelivered =
            try await notificationClient.deliveredIdentifiers()
        let secondPending =
            try await notificationClient.pendingIdentifiers()
        let secondDelivered =
            try await notificationClient.deliveredIdentifiers()
        guard let first = try? ownedNotificationObservation(
            pending: firstPending,
            delivered: firstDelivered
        ),
        let second = try? ownedNotificationObservation(
            pending: secondPending,
            delivered: secondDelivered
        ),
        first == second else {
            throw DataControlDeletionServiceFailure
                .notificationObservationUnstable
        }
        return second
    }

    private func ownedNotificationObservation(
        pending: [String],
        delivered: [String]
    ) throws -> DataControlNotificationObservation {
        let pending = pending.filter(
            LocalReminderPlanner.isOwnedIdentifier
        )
        let delivered = delivered.filter(
            LocalReminderPlanner.isOwnedIdentifier
        )
        let pendingSet = Set(pending)
        let deliveredSet = Set(delivered)
        guard pendingSet.count == pending.count,
              deliveredSet.count == delivered.count,
              pendingSet.isDisjoint(with: deliveredSet) else {
            throw DataControlDeletionServiceFailure
                .notificationObservationUnstable
        }
        let entries = try pendingSet.map { identifier in
            if identifier.hasPrefix(
                DataControlNotificationNamespace
                    .execution.identifierPrefix
            ) {
                return DataControlPendingNotificationEntry(
                    namespace: .execution,
                    identifier: identifier
                )
            }
            if identifier.hasPrefix(
                DataControlNotificationNamespace
                    .countdown.identifierPrefix
            ) {
                return DataControlPendingNotificationEntry(
                    namespace: .countdown,
                    identifier: identifier
                )
            }
            throw DataControlDeletionServiceFailure
                .notificationObservationUnstable
        }
        guard let canonical =
                DataControlPendingNotificationManifest.encode(entries),
              let ordered =
                DataControlPendingNotificationManifest.decode(
                    canonical
                ) else {
            throw DataControlDeletionServiceFailure
                .notificationObservationUnstable
        }
        return DataControlNotificationObservation(
            pending: ordered,
            deliveredIdentifiers: deliveredSet
        )
    }

    private func removeAllOwnedPending() async throws {
        let pending =
            try await notificationClient.pendingIdentifiers()
        let owned = pending.filter(
            LocalReminderPlanner.isOwnedIdentifier
        )
        if !owned.isEmpty {
            try await notificationClient
                .removePendingIdentifiers(owned)
        }
        let remaining =
            try await notificationClient.pendingIdentifiers()
        guard !remaining.contains(
            where: LocalReminderPlanner.isOwnedIdentifier
        ) else {
            throw DataControlDeletionServiceFailure
                .notificationCleanupFailed
        }
    }

    private func stageAttachments(
        _ entries: [DataControlAttachmentManifestEntry]
    ) async throws -> [AttachmentStagedDeletion] {
        var staged: [AttachmentStagedDeletion] = []
        do {
            for entry in entries {
                guard let ownerType = AttachmentOwnerType(
                    rawValue: entry.ownerType
                ) else {
                    throw DataControlDeletionServiceFailure
                        .impactChanged
                }
                let attachment = AttachmentSnapshot(
                    id: entry.attachmentID,
                    ownerType: ownerType,
                    ownerID: entry.ownerID,
                    relativePath: entry.relativePath,
                    originalFilename: entry.originalFilename,
                    typeIdentifier: entry.contentType,
                    byteCount: entry.byteCount,
                    sha256Hex: entry.sha256Hex,
                    createdAt: entry.createdAt
                )
                staged.append(
                    try await ioQueue.perform { [fileStore] in
                        try fileStore.stageDeletion(
                            attachment: attachment,
                            operationID: entry.deletionOperationID
                        )
                    }
                )
            }
            return staged
        } catch {
            do {
                try await rollbackAttachments(staged)
            } catch {
                await requireRecovery()
                throw DataControlDeletionServiceFailure
                    .recoveryRequired
            }
            if requiresRecovery(error) {
                await requireRecovery()
                throw DataControlDeletionServiceFailure
                    .recoveryRequired
            }
            throw error
        }
    }

    private func rollbackAttachments(
        _ staged: [AttachmentStagedDeletion]
    ) async throws {
        var firstError: Error?
        for deletion in staged.reversed() {
            do {
                try await ioQueue.perform { [fileStore] in
                    try fileStore.rollbackDeletion(
                        operationID: deletion.operationID
                    )
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private func finalizeAttachments(
        _ staged: [AttachmentStagedDeletion]
    ) async throws {
        for deletion in staged {
            try await ioQueue.perform { [fileStore] in
                try fileStore.finalizeDeletion(deletion)
            }
        }
    }

    private func target(
        from impact: DeletionImpact
    ) throws -> DataControlDeletionTarget {
        guard let snapshot = DataControlTargetSnapshotManifest.decode(
            impact.targetSnapshotManifest
        ),
        snapshot.targetKind == impact.targetKind,
        snapshot.targetStableKey == impact.targetStableKey,
        snapshot.targetID == impact.targetID else {
            throw DataControlDeletionServiceFailure.impactChanged
        }
        switch snapshot.targetKind {
        case .journeyEntry:
            guard let id = snapshot.targetID else {
                throw DataControlDeletionServiceFailure.impactChanged
            }
            return .journeyEntry(id)
        case .administrationOccurrence:
            guard let occurrence = snapshot.occurrenceProjection else {
                throw DataControlDeletionServiceFailure.impactChanged
            }
            return .administrationOccurrence(occurrence)
        case .draftRegimenVersion:
            guard let id = snapshot.targetID else {
                throw DataControlDeletionServiceFailure.impactChanged
            }
            return .draftRegimenVersion(id)
        case .sealedRegimenVersion:
            guard let id = snapshot.targetID else {
                throw DataControlDeletionServiceFailure.impactChanged
            }
            return .sealedRegimenVersion(id)
        case .hrtJourney:
            return .hrtJourney
        }
    }

    private func decodedAttachments(
        _ manifest: String
    ) throws -> [DataControlAttachmentManifestEntry] {
        guard let entries = DataControlAttachmentManifest.decode(
            manifest
        ) else {
            throw DataControlDeletionServiceFailure.impactChanged
        }
        return entries
    }

    private func requiresRecovery(_ error: Error) -> Bool {
        switch error as? AttachmentFileStoreFailure {
        case .integrityMismatch, .inconsistentJournal, .unsafePath,
             .recoveryRequired:
            true
        case .invalidInput, .fileTooLarge, .ownerLimitReached,
             .simulatedInterruption, .none:
            false
        }
    }

    private func requireRecovery() async {
        recoveryLatch.invalidate()
        guard !hasNotifiedRecovery else { return }
        hasNotifiedRecovery = true
        await onRecoveryRequired()
    }
}

private final class DataControlDeletionBlockingIOQueue:
    @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.mtfbook.unmanual.data-control-deletion-io",
        qos: .userInitiated
    )

    func perform<Output: Sendable>(
        _ operation: @escaping @Sendable () throws -> Output
    ) async throws -> Output {
        try await withCheckedThrowingContinuation {
            continuation in
            queue.async {
                do {
                    continuation.resume(
                        returning: try operation()
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private struct DataControlDeletionServiceEnvironmentKey:
    EnvironmentKey {
    static let defaultValue: DataControlDeletionService? = nil
}

extension EnvironmentValues {
    var dataControlDeletionService:
        DataControlDeletionService? {
        get { self[DataControlDeletionServiceEnvironmentKey.self] }
        set {
            self[DataControlDeletionServiceEnvironmentKey.self] =
                newValue
        }
    }
}
