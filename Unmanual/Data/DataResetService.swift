@preconcurrency import UserNotifications
import Foundation
import SwiftData
import SwiftUI

enum DataResetServiceFailure: Error, Equatable, Sendable {
    case unavailable
    case incompleteManifest
    case impactChanged
    case notificationObservationUnstable
    case notificationManifestMismatch
    case quiesceTimedOut
    case resetAlreadyInProgress
    case recoveryRequired
    case postAuditFailed
}

protocol DataResetNotificationClient: Sendable {
    func pendingIdentifiers() async throws -> [String]
    func deliveredIdentifiers() async throws -> [String]
    func removePendingIdentifiers(_ identifiers: [String]) async throws
    func removeDeliveredIdentifiers(_ identifiers: [String]) async throws
}

actor SystemDataResetNotificationClient:
    DataResetNotificationClient {
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

    func removeDeliveredIdentifiers(
        _ identifiers: [String]
    ) async {
        center.removeDeliveredNotifications(
            withIdentifiers: identifiers
        )
    }
}

struct DataResetPreparedOperation: Sendable {
    let journal: DataResetJournalV1
    let store: DataResetJournalStore
    let coordinator: AppDataControlCoordinator
    let lease: AppDataControlCoordinator.ExclusiveResetLease
}

actor DataResetPreparationService {
    private let manifestProvider: any DataControlManifestProvider
    private let notificationClient: any DataResetNotificationClient
    private let coordinator: AppDataControlCoordinator
    private let pathLayout: DataResetPathLayout
    private let fileSystem: any DataResetFileSystem
    private let resetDrainTimeout: Duration

    init(
        store: BootstrappedAppDataStore,
        manifestProvider: any DataControlManifestProvider,
        coordinator: AppDataControlCoordinator,
        notificationClient:
            any DataResetNotificationClient =
                SystemDataResetNotificationClient(),
        fileSystem:
            any DataResetFileSystem =
                DataResetFoundationFileSystem(),
        resetDrainTimeout: Duration = .seconds(5)
    ) {
        precondition(store.layout != nil)
        let layout = store.layout!
        self.manifestProvider = manifestProvider
        self.notificationClient = notificationClient
        self.coordinator = coordinator
        self.pathLayout = DataResetPathLayout(
            applicationSupportURL:
                layout.rootURL.deletingLastPathComponent(),
            storeLayout: layout
        )
        self.fileSystem = fileSystem
        self.resetDrainTimeout = resetDrainTimeout
    }

    func prepare(
        confirmedStateDigest: String,
        now: Date = Date()
    ) async throws -> DataResetPreparedOperation {
        let operationID = UUID()
        let lease = try await beginExclusiveResetLease()
        do {
            let frozen = try await coordinator
                .withExclusiveResetLease(lease) {
                    let manifest = try await self
                        .manifestProvider.manifest()
                    guard manifest.destructiveActionsEnabled else {
                        throw DataResetServiceFailure
                            .incompleteManifest
                    }
                    guard manifest.stateDigest
                            == confirmedStateDigest else {
                        throw DataResetServiceFailure
                            .impactChanged
                    }
                    let notifications = try await self
                        .stableOwnedNotifications()
                    try Self.requireNotificationManifest(
                        notifications,
                        matches: manifest
                    )
                    let presence = try await self
                        .validatePreJournalPaths(
                            operationID: operationID
                        )
                    return (
                        manifest,
                        notifications,
                        presence
                    )
                }
            let journal = try DataResetJournalFactory
                .makeQuiesced(
                    operationID: operationID,
                    confirmedStateDigest:
                        confirmedStateDigest,
                    exclusiveManifestDigest:
                        frozen.0.manifestDigest,
                    now: now,
                    layout: pathLayout,
                    legacyPresence: frozen.2,
                    ownedNotifications: frozen.1,
                    freshGenerationID: UUID(),
                    freshDatasetID: UUID()
                )
            try await coordinator.invalidateForReset(lease)
            return DataResetPreparedOperation(
                journal: journal,
                store: DataResetJournalStore(
                    layout: pathLayout,
                    fileSystem: fileSystem
                ),
                coordinator: coordinator,
                lease: lease
            )
        } catch {
            await coordinator.endExclusiveResetLease(lease)
            throw error
        }
    }

    private func beginExclusiveResetLease() async throws
        -> AppDataControlCoordinator.ExclusiveResetLease {
        let timeout = resetDrainTimeout
        return try await withThrowingTaskGroup(
            of: AppDataControlCoordinator
                .ExclusiveResetLease.self
        ) { group in
            group.addTask {
                try await self.coordinator
                    .beginExclusiveResetLease()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw DataResetServiceFailure
                    .quiesceTimedOut
            }
            guard let first = try await group.next() else {
                throw DataResetServiceFailure
                    .quiesceTimedOut
            }
            group.cancelAll()
            return first
        }
    }

    private func stableOwnedNotifications() async throws
        -> [DataResetNotificationV1] {
        let firstPending = try await notificationClient
            .pendingIdentifiers()
        let firstDelivered = try await notificationClient
            .deliveredIdentifiers()
        let secondPending = try await notificationClient
            .pendingIdentifiers()
        let secondDelivered = try await notificationClient
            .deliveredIdentifiers()
        guard Set(firstPending) == Set(secondPending),
              Set(firstDelivered) == Set(secondDelivered),
              Set(secondPending).count == secondPending.count,
              Set(secondDelivered).count
                == secondDelivered.count else {
            throw DataResetServiceFailure
                .notificationObservationUnstable
        }
        return try Self.ownedNotifications(
            pending: secondPending,
            delivered: secondDelivered
        )
    }

    private func validatePreJournalPaths(
        operationID: UUID
    ) throws
        -> [DataResetLegacyRoleV1: Bool] {
        guard try fileSystem.kind(
            at: pathLayout.managedRootURL
        ) == .directory,
        try fileSystem.kind(
            at: pathLayout.quarantineRootURL(
                operationID: operationID
            )
        ) == .missing else {
            throw DataResetServiceFailure.recoveryRequired
        }
        let rootValues = try pathLayout.managedRootURL
            .resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ]
            )
        guard rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else {
            throw DataResetServiceFailure.recoveryRequired
        }
        var result: [DataResetLegacyRoleV1: Bool] = [:]
        for role in DataResetLegacyRoleV1.allCases {
            let source = pathLayout.legacySourceURL(role: role)
            let kind = try fileSystem.kind(at: source)
            guard kind == .missing || kind == .regularFile else {
                throw DataResetServiceFailure.recoveryRequired
            }
            result[role] = kind == .regularFile
        }
        return result
    }

    static func ownedNotifications(
        pending: [String],
        delivered: [String]
    ) throws -> [DataResetNotificationV1] {
        let pendingSet = Set(pending)
        let deliveredSet = Set(delivered)
        guard pendingSet.count == pending.count,
              deliveredSet.count == delivered.count,
              pendingSet.isDisjoint(with: deliveredSet) else {
            throw DataResetServiceFailure
                .notificationObservationUnstable
        }
        func notification(
            _ identifier: String,
            state: DataResetNotificationDeliveryStateV1
        ) -> DataResetNotificationV1? {
            let namespace:
                DataResetNotificationNamespaceV1
            if identifier.hasPrefix(
                DataInventoryNotificationNamespace
                    .execution.identifierPrefix
            ) {
                namespace = .execution
            } else if identifier.hasPrefix(
                DataInventoryNotificationNamespace
                    .countdown.identifierPrefix
            ) {
                namespace = .countdown
            } else {
                return nil
            }
            return DataResetNotificationV1(
                namespace: namespace,
                deliveryState: state,
                identifier: identifier
            )
        }
        return try DataResetJournalFactory
            .normalizedNotifications(
                pending.compactMap {
                    notification($0, state: .pending)
                }
                + delivered.compactMap {
                    notification($0, state: .delivered)
                }
            )
    }

    static func requireNotificationManifest(
        _ notifications: [DataResetNotificationV1],
        matches manifest: DataInventoryManifest
    ) throws {
        let observations =
            notifications.map { notification in
                DataInventoryNotificationRequestObservation(
                    identifier: notification.identifier,
                    deliveryState:
                        notification.deliveryState
                            == .pending
                            ? .pending
                            : .delivered
                )
            }
        let expected = try DataInventoryManifestBuilder
            .notificationCategories(
                observations: observations
            )
        let actual = manifest.categories
            .filter { $0.kind == .notification }
            .sorted { $0.key < $1.key }
        guard actual == expected else {
            throw DataResetServiceFailure
                .notificationManifestMismatch
        }
    }
}

actor DataResetCurrentProcessWorker {
    func advanceToRestartRequired(
        _ operation: DataResetPreparedOperation
    ) async throws -> DataResetJournalV1 {
        do {
            _ = try operation.store.writeAndReadback(
                operation.journal
            )
            let journal = try DataResetQuarantineExecutor(
                store: operation.store
            ).advanceBeforeRestart(from: operation.journal)
            await operation.coordinator
                .endExclusiveResetLease(operation.lease)
            return journal
        } catch {
            await operation.coordinator
                .endExclusiveResetLease(operation.lease)
            throw error
        }
    }
}

actor DataResetColdLaunchCoordinator {
    private let notificationClient:
        any DataResetNotificationClient
    private let fileSystem: any DataResetFileSystem
    private let layoutProvider:
        @Sendable () throws -> AppDataStoreLayout
    private let fileProtectionVerificationMode:
        StoreFileProtectionVerificationMode

    init(
        notificationClient:
            any DataResetNotificationClient =
                SystemDataResetNotificationClient(),
        fileSystem:
            any DataResetFileSystem =
                DataResetFoundationFileSystem(),
        layoutProvider:
            @escaping @Sendable () throws
                -> AppDataStoreLayout = {
                    try AppDataStoreLayout.production()
                },
        fileProtectionVerificationMode:
            StoreFileProtectionVerificationMode = .live
    ) {
        self.notificationClient = notificationClient
        self.fileSystem = fileSystem
        self.layoutProvider = layoutProvider
        self.fileProtectionVerificationMode =
            fileProtectionVerificationMode
    }

    func open() async throws -> BootstrappedAppDataStore {
        let layout = try layoutProvider()
        let resetLayout = DataResetPathLayout(
            applicationSupportURL:
                layout.rootURL.deletingLastPathComponent(),
            storeLayout: layout
        )
        let journalStore = DataResetJournalStore(
            layout: resetLayout,
            fileSystem: fileSystem
        )
        guard try fileSystem.kind(at: resetLayout.journalURL)
                != .missing else {
            try validateNoUnmatchedResetEvidence(
                layout: resetLayout
            )
            return try AppDataStoreBootstrapper(
                layout: layout,
                backupPolicy: .production,
                fileProtectionVerificationMode:
                    fileProtectionVerificationMode
            ).open()
        }
        var journal = try journalStore.read()
        let executor = DataResetQuarantineExecutor(
            store: journalStore
        )
        if let phase = journal.phase,
           phase.ordinal
                <= DataResetPhaseV1.restartRequired.ordinal {
            journal = try executor
                .resumeColdLaunchThroughPurge(from: journal)
        }
        if journal.phase == .quarantinePurged {
            journal = try persistTransition(
                journal,
                to: .freshStorePrepared,
                store: journalStore
            )
        }
        guard let phase = journal.phase,
              phase.ordinal
                >= DataResetPhaseV1.freshStorePrepared.ordinal
        else {
            throw DataResetServiceFailure.recoveryRequired
        }
        let startsNotificationRetryEpoch =
            journal.phase == .freshStoreOpened

        let opened = try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .production,
            mode: .freshAfterReset(
                expectedGenerationID:
                    journal.freshGenerationID,
                expectedDatasetID: journal.freshDatasetID
            ),
            fileProtectionVerificationMode:
                fileProtectionVerificationMode
        ).open()
        let verifier = DataResetFreshStoreVerifier(
            modelContainer: opened.container
        )
        let nextLocalRevision = try await verifier.verify(
            expectedDatasetID: journal.freshDatasetID
        )
        if journal.phase == .freshStorePrepared {
            journal = try persistTransition(
                journal,
                to: .freshStoreOpened,
                store: journalStore
            ) {
                $0.freshNextLocalRevision =
                    nextLocalRevision
            }
        }
        guard journal.freshNextLocalRevision
                == nextLocalRevision else {
            throw DataResetServiceFailure.postAuditFailed
        }
        if journal.phase == .freshStoreOpened {
            journal = try await convergeOwnedNotifications(
                journal,
                store: journalStore,
                startsNewRetryEpoch:
                    startsNotificationRetryEpoch
            )
        }
        if journal.phase
            == .ownedNotificationsConvergedToZero {
            try await postAudit(
                opened: opened,
                journal: journal,
                resetLayout: resetLayout,
                verifier: verifier
            )
            journal = try persistTransition(
                journal,
                to: .verifiedEmpty,
                store: journalStore
            )
        }
        if journal.phase == .verifiedEmpty {
            try await postAudit(
                opened: opened,
                journal: journal,
                resetLayout: resetLayout,
                verifier: verifier
            )
            journal = try persistTransition(
                journal,
                to: .complete,
                store: journalStore
            )
        }
        guard journal.phase == .complete else {
            throw DataResetServiceFailure.recoveryRequired
        }
        try await postAudit(
            opened: opened,
            journal: journal,
            resetLayout: resetLayout,
            verifier: verifier
        )
        try removeCompletedJournal(layout: resetLayout)
        return opened
    }

    private func convergeOwnedNotifications(
        _ initial: DataResetJournalV1,
        store: DataResetJournalStore,
        startsNewRetryEpoch: Bool
    ) async throws -> DataResetJournalV1 {
        var journal = initial
        if startsNewRetryEpoch {
            guard journal.notificationClearEpoch
                    < Int64.max else {
                throw DataResetServiceFailure
                    .recoveryRequired
            }
            journal = try persistTransition(
                journal,
                to: .freshStoreOpened,
                store: store
            ) {
                $0.notificationClearEpoch += 1
                $0.notificationClearRound = 0
            }
        }
        while journal.notificationClearRound < 3 {
            let before = try await stableOwnedNotifications()
            if before.isEmpty {
                return try persistTransition(
                    journal,
                    to:
                        .ownedNotificationsConvergedToZero,
                    store: store
                ) {
                    $0.ownedNotifications = []
                }
            }
            let pending = before
                .filter {
                    $0.deliveryState == .pending
                }
                .map(\.identifier)
            let delivered = before
                .filter {
                    $0.deliveryState == .delivered
                }
                .map(\.identifier)
            try await notificationClient
                .removePendingIdentifiers(pending)
            try await notificationClient
                .removeDeliveredIdentifiers(delivered)
            let after = try await stableOwnedNotifications()
            journal = try persistTransition(
                journal,
                to: .freshStoreOpened,
                store: store
            ) {
                $0.notificationClearRound += 1
                $0.ownedNotifications = after
            }
            if after.isEmpty {
                return try persistTransition(
                    journal,
                    to:
                        .ownedNotificationsConvergedToZero,
                    store: store
                ) {
                    $0.ownedNotifications = []
                }
            }
        }
        throw DataResetServiceFailure.recoveryRequired
    }

    private func stableOwnedNotifications() async throws
        -> [DataResetNotificationV1] {
        let firstPending = try await notificationClient
            .pendingIdentifiers()
        let firstDelivered = try await notificationClient
            .deliveredIdentifiers()
        let secondPending = try await notificationClient
            .pendingIdentifiers()
        let secondDelivered = try await notificationClient
            .deliveredIdentifiers()
        guard Set(firstPending) == Set(secondPending),
              Set(firstDelivered) == Set(secondDelivered),
              Set(secondPending).count == secondPending.count,
              Set(secondDelivered).count
                == secondDelivered.count else {
            throw DataResetServiceFailure
                .notificationObservationUnstable
        }
        return try DataResetPreparationService
            .ownedNotifications(
                pending: secondPending,
                delivered: secondDelivered
            )
    }

    private func postAudit(
        opened: BootstrappedAppDataStore,
        journal: DataResetJournalV1,
        resetLayout: DataResetPathLayout,
        verifier: DataResetFreshStoreVerifier
    ) async throws {
        guard opened.generationID
                == journal.freshGenerationID,
              try await verifier.verify(
                  expectedDatasetID:
                      journal.freshDatasetID
              ) == journal.freshNextLocalRevision,
              try await stableOwnedNotifications().isEmpty,
              opened.protectionReport.backupPolicy
                == .systemManaged,
              opened.protectionReport
                .isAcceptableForCurrentPlatform,
              try fileSystem.kind(
                  at: resetLayout.quarantineRootURL(
                      operationID: journal.operationID
                  )
              ) == .missing,
              try fileSystem.kind(
                  at: resetLayout.managedRootURL
              ) == .directory else {
            throw DataResetServiceFailure.postAuditFailed
        }
        for role in DataResetLegacyRoleV1.allCases {
            guard try fileSystem.kind(
                at: resetLayout.legacySourceURL(role: role)
            ) == .missing else {
                throw DataResetServiceFailure.postAuditFailed
            }
        }
        let controlChildren = try fileSystem.children(
            of: resetLayout.controlDirectoryURL
        )
        guard controlChildren.count == 1,
              controlChildren[0].standardizedFileURL
                == resetLayout.journalURL.standardizedFileURL,
              try fileSystem.kind(
                  at: resetLayout.journalURL
              ) == .regularFile else {
            throw DataResetServiceFailure.postAuditFailed
        }
        let managedRootChildren = try fileSystem.children(
            of: resetLayout.managedRootURL
        )
        guard Set(
            managedRootChildren.map(\.lastPathComponent)
        ) == Set([
            "Generations",
            "GenerationPointer",
            "Recovery"
        ]),
        managedRootChildren.allSatisfy({
            (try? fileSystem.kind(at: $0))
                == .directory
        }) else {
            throw DataResetServiceFailure.postAuditFailed
        }
        let generationsURL = resetLayout.managedRootURL
            .appending(
                path: "Generations",
                directoryHint: .isDirectory
            )
        let generationChildren = try fileSystem.children(
            of: generationsURL
        )
        guard generationChildren.count == 1,
              generationChildren[0].lastPathComponent
                == journal.freshGenerationID.uuidString
                    .lowercased(),
              try fileSystem.kind(
                  at: generationChildren[0]
              ) == .directory else {
            throw DataResetServiceFailure.postAuditFailed
        }
        try validateFreshResetLayout(
            generationURL: generationChildren[0],
            managedRootURL: resetLayout.managedRootURL
        )
        let appDataLayout = AppDataStoreLayout(
            rootURL: resetLayout.managedRootURL,
            legacyStoreURL:
                resetLayout.legacyStoreURL
        )
        let pointer = try GenerationPointerStore(
            layout: appDataLayout,
            backupPolicy: .systemManaged
        ).read()
        let migrationJournal: MigrationJournal
        do {
            migrationJournal = try MigrationJournalStore(
                layout: appDataLayout,
                backupPolicy: .systemManaged
            ).read()
        } catch {
            throw DataResetServiceFailure.postAuditFailed
        }
        guard pointer.generationID
                == journal.freshGenerationID,
              pointer.datasetID
                == journal.freshDatasetID,
              pointer.schemaVersion == "13.0.0",
              pointer.origin == .newInstall,
              migrationJournal.targetGenerationID
                == journal.freshGenerationID,
              migrationJournal.origin == .newInstall,
              migrationJournal.sourceGenerationID == nil,
              migrationJournal.sourceSchemaVersion == nil,
              migrationJournal.targetSchemaVersion == nil,
              migrationJournal.phase == .validated
                || migrationJournal.phase
                    == .activated else {
            throw DataResetServiceFailure.postAuditFailed
        }
    }

    private func validateFreshResetLayout(
        generationURL: URL,
        managedRootURL: URL
    ) throws {
        let generationChildren =
            try fileSystem.children(of: generationURL)
        guard Set(
            generationChildren.map(\.lastPathComponent)
        ) == Set(["Files", "Store"]),
        generationChildren.allSatisfy({
            (try? fileSystem.kind(at: $0))
                == .directory
        }) else {
            throw DataResetServiceFailure.postAuditFailed
        }

        let storeURL = generationURL.appending(
            path: "Store",
            directoryHint: .isDirectory
        )
        let storeChildren =
            try fileSystem.children(of: storeURL)
        let storeNames = Set(
            storeChildren.map(\.lastPathComponent)
        )
        guard storeNames.contains("user.sqlite"),
              storeNames.isSubset(
                  of: [
                      "user.sqlite",
                      "user.sqlite-shm",
                      "user.sqlite-wal"
                  ]
              ),
              storeChildren.allSatisfy({
                  (try? fileSystem.kind(at: $0))
                      == .regularFile
              }) else {
            throw DataResetServiceFailure.postAuditFailed
        }

        let filesURL = generationURL.appending(
            path: "Files",
            directoryHint: .isDirectory
        )
        let filesChildren =
            try fileSystem.children(of: filesURL)
        guard Set(
            filesChildren.map(\.lastPathComponent)
        ) == Set([
            ".staging",
            ".trash",
            "Attachments"
        ]),
        try filesChildren.allSatisfy({
            try fileSystem.kind(at: $0) == .directory
                && fileSystem.children(of: $0).isEmpty
        }) else {
            throw DataResetServiceFailure.postAuditFailed
        }

        let pointerDirectory = managedRootURL.appending(
            path: "GenerationPointer",
            directoryHint: .isDirectory
        )
        let pointerChildren =
            try fileSystem.children(of: pointerDirectory)
        guard pointerChildren.count == 1,
              pointerChildren[0].lastPathComponent
                == "active.json",
              try fileSystem.kind(
                  at: pointerChildren[0]
              ) == .regularFile else {
            throw DataResetServiceFailure.postAuditFailed
        }

        let recoveryDirectory = managedRootURL.appending(
            path: "Recovery",
            directoryHint: .isDirectory
        )
        let recoveryChildren =
            try fileSystem.children(of: recoveryDirectory)
        guard recoveryChildren.count == 1,
              recoveryChildren[0].lastPathComponent
                == "migration-journal.json",
              try fileSystem.kind(
                  at: recoveryChildren[0]
              ) == .regularFile else {
            throw DataResetServiceFailure.postAuditFailed
        }
    }

    private func persistTransition(
        _ journal: DataResetJournalV1,
        to phase: DataResetPhaseV1,
        store: DataResetJournalStore,
        mutate:
            (inout DataResetJournalV1) throws -> Void =
                { _ in }
    ) throws -> DataResetJournalV1 {
        let next = try DataResetStateMachine.transitioned(
            from: journal,
            to: phase,
            now: Date(),
            layout: store.layout,
            mutate: mutate
        )
        return try store.writeAndReadback(next)
    }

    private func validateNoUnmatchedResetEvidence(
        layout: DataResetPathLayout
    ) throws {
        let controlKind = try fileSystem.kind(
            at: layout.controlDirectoryURL
        )
        if controlKind != .missing {
            guard controlKind == .directory,
                  try fileSystem.children(
                      of: layout.controlDirectoryURL
                  ).isEmpty else {
                throw DataResetServiceFailure
                    .recoveryRequired
            }
            try fileSystem
                .verifyProtectedSystemManagedDirectory(
                    at: layout.controlDirectoryURL
                )
            try fileSystem.removeItem(
                at: layout.controlDirectoryURL
            )
            guard try fileSystem.kind(
                at: layout.controlDirectoryURL
            ) == .missing else {
                throw DataResetServiceFailure
                    .recoveryRequired
            }
        }
        for child in try fileSystem.children(
            of: layout.applicationSupportURL
        ) where child.lastPathComponent
            .hasPrefix("Unmanual.reset-") {
            throw DataResetServiceFailure.recoveryRequired
        }
    }

    private func removeCompletedJournal(
        layout: DataResetPathLayout
    ) throws {
        guard try fileSystem.kind(at: layout.journalURL)
                == .regularFile else {
            throw DataResetServiceFailure.postAuditFailed
        }
        try fileSystem.removeItem(at: layout.journalURL)
        guard try fileSystem.kind(at: layout.journalURL)
                == .missing,
              try fileSystem.children(
                  of: layout.controlDirectoryURL
              ).isEmpty else {
            throw DataResetServiceFailure.postAuditFailed
        }
        try fileSystem.removeItem(
            at: layout.controlDirectoryURL
        )
        guard try fileSystem.kind(
            at: layout.controlDirectoryURL
        ) == .missing else {
            throw DataResetServiceFailure.postAuditFailed
        }
    }
}

@ModelActor
actor DataResetFreshStoreVerifier {
    func verify(
        expectedDatasetID: UUID
    ) throws -> Int64 {
        let foundation = try AppDataStoreBootstrapper(
            layout: AppDataStoreLayout(
                rootURL: URL(fileURLWithPath: "/unused"),
                legacyStoreURL:
                    URL(fileURLWithPath: "/unused-legacy")
            )
        ).validateV13DataInventoryFoundation(
            in: modelContext
        )
        let counts: [String: Int] = [
            "AttachmentRecord":
                try count(AttachmentRecord.self),
            "RecordRevision": try count(RecordRevision.self),
            "OperationReceiptRecord":
                try count(OperationReceiptRecord.self),
            "OperationReceiptLedgerRecord":
                try count(OperationReceiptLedgerRecord.self),
            "HistoricalTimeRecord":
                try count(HistoricalTimeRecord.self),
            "ParentRecordLifecycleHeadRecord":
                try count(ParentRecordLifecycleHeadRecord.self),
            "ParentRecordMutationEventRecord":
                try count(ParentRecordMutationEventRecord.self),
            "ParentRecordDeletionTombstoneRecord":
                try count(ParentRecordDeletionTombstoneRecord.self),
            "DataControlDeletionTombstoneRecord":
                try count(DataControlDeletionTombstoneRecord.self),
            "ContentFavoriteRecord":
                try count(ContentFavoriteRecord.self),
            "CountdownRecord":
                try count(CountdownRecord.self),
            "CountdownStateRecord":
                try count(CountdownStateRecord.self),
            "CountdownLifecycleEventRecord":
                try count(CountdownLifecycleEventRecord.self),
            "CountdownReminderRuleRecord":
                try count(CountdownReminderRuleRecord.self),
            "CountdownCommandAuditRecord":
                try count(CountdownCommandAuditRecord.self),
            "CountdownV6AuditCheckpointRecord":
                try count(CountdownV6AuditCheckpointRecord.self),
            "AdministrationEventRecord":
                try count(AdministrationEventRecord.self),
            "ReminderOverrideRecord":
                try count(ReminderOverrideRecord.self),
            "ReminderPreferenceRecord":
                try count(ReminderPreferenceRecord.self),
            "HRTProfile": try count(HRTProfile.self),
            "HrtJourneyProfileRecord":
                try count(HrtJourneyProfileRecord.self),
            "HrtPeriodRecord": try count(HrtPeriodRecord.self),
            "HrtJourneyLifecycleEventRecord":
                try count(HrtJourneyLifecycleEventRecord.self),
            "JourneyEntry": try count(JourneyEntry.self),
            "LabRecord": try count(LabRecord.self),
            "LabItemDefinitionRecord":
                try count(LabItemDefinitionRecord.self),
            "LabSampleRecord": try count(LabSampleRecord.self),
            "LabResultRecord": try count(LabResultRecord.self),
            "LabSampleCorrectionSnapshotRecord":
                try count(
                    LabSampleCorrectionSnapshotRecord.self
                ),
            "LabResultCorrectionSnapshotRecord":
                try count(
                    LabResultCorrectionSnapshotRecord.self
                ),
            "UserPreferencesRecord":
                try count(UserPreferencesRecord.self),
            "OnboardingProgressRecord":
                try count(OnboardingProgressRecord.self),
            "PrivacyControlRecord":
                try count(PrivacyControlRecord.self),
            "RegimenVersion": try count(RegimenVersion.self),
            "RegimenPlanVersionRecord":
                try count(RegimenPlanVersionRecord.self),
            "RegimenItemRecord":
                try count(RegimenItemRecord.self),
            "ScheduleRuleRecord":
                try count(ScheduleRuleRecord.self),
            "StatusMetricDefinitionRecord":
                try count(StatusMetricDefinitionRecord.self),
            "StatusObservationRecord":
                try count(StatusObservationRecord.self),
            "StatusObservationCorrectionSnapshotRecord":
                try count(
                    StatusObservationCorrectionSnapshotRecord.self
                ),
            "DatasetMetadata": try count(DatasetMetadata.self),
            "MigrationBackfillState":
                try count(MigrationBackfillState.self),
            "MigrationIssue": try count(MigrationIssue.self),
            "CoreTimeRegimenBackfillState":
                try count(CoreTimeRegimenBackfillState.self),
            "TodayExecutionBackfillState":
                try count(TodayExecutionBackfillState.self),
            "PersonalTimelineBackfillState":
                try count(PersonalTimelineBackfillState.self),
            "CountdownLifecycleBackfillState":
                try count(CountdownLifecycleBackfillState.self),
            "CountdownIntegrityBackfillState":
                try count(CountdownIntegrityBackfillState.self),
            "OnboardingBackfillState":
                try count(OnboardingBackfillState.self),
            "HrtJourneyLifecycleBackfillState":
                try count(HrtJourneyLifecycleBackfillState.self),
            "ParentRecordLifecycleBackfillState":
                try count(ParentRecordLifecycleBackfillState.self),
            "PrivacyControlBackfillState":
                try count(PrivacyControlBackfillState.self),
            "DataControlBackfillState":
                try count(DataControlBackfillState.self),
            "NotificationCoverageRecord":
                try count(NotificationCoverageRecord.self),
            "CountdownNotificationCoverageRecord":
                try count(
                    CountdownNotificationCoverageRecord.self
                )
        ]
        let requiredSingletons: Set<String> = [
            "DatasetMetadata",
            "MigrationBackfillState",
            "CoreTimeRegimenBackfillState",
            "TodayExecutionBackfillState",
            "PersonalTimelineBackfillState",
            "CountdownLifecycleBackfillState",
            "CountdownIntegrityBackfillState",
            "OnboardingBackfillState",
            "HrtJourneyLifecycleBackfillState",
            "ParentRecordLifecycleBackfillState",
            "PrivacyControlBackfillState",
            "DataControlBackfillState",
            "OperationReceiptLedgerRecord",
            "NotificationCoverageRecord",
            "CountdownNotificationCoverageRecord",
            "UserPreferencesRecord",
            "OnboardingProgressRecord",
            "PrivacyControlRecord"
        ]
        guard foundation.datasetID == expectedDatasetID,
              Set(counts.keys)
                == Set(
                    DataInventoryTaxonomy
                        .allDatabaseModelNames
                ),
              counts.allSatisfy({ name, value in
                  if name == "RecordRevision" {
                      return value
                          == foundation.revisionCount
                  }
                  return value
                      == (requiredSingletons.contains(name)
                          ? 1 : 0)
              }) else {
            throw DataResetServiceFailure.postAuditFailed
        }
        var onboardingDescriptor =
            FetchDescriptor<OnboardingProgressRecord>()
        onboardingDescriptor.fetchLimit = 2
        var preferencesDescriptor =
            FetchDescriptor<UserPreferencesRecord>()
        preferencesDescriptor.fetchLimit = 2
        var privacyDescriptor =
            FetchDescriptor<PrivacyControlRecord>()
        privacyDescriptor.fetchLimit = 2
        let onboarding = try modelContext.fetch(
            onboardingDescriptor
        )
        let preferences = try modelContext.fetch(
            preferencesDescriptor
        )
        let privacy = try modelContext.fetch(
            privacyDescriptor
        )
        guard onboarding.count == 1,
              onboarding[0].step == .privacy,
              onboarding[0].completedAt == nil,
              !onboarding[0].skippedStartDate,
              !onboarding[0].skippedReminder,
              !onboarding[0].skippedCountdown,
              preferences.count == 1,
              !preferences[0].onboardingCompleted,
              !preferences[0].gentleModeEnabled,
              preferences[0].notificationContentLevel
                == "gentle",
              preferences[0].preferredLanguage == "zh-Hans",
              privacy.count == 1,
              privacy[0].singletonKey
                == PrivacyControlRecord.fixedKey,
              privacy[0].contractVersion
                == PrivacyControlRecord.contractVersion,
              !privacy[0].appLockEnabled,
              privacy[0].lastOperationID == nil else {
            throw DataResetServiceFailure.postAuditFailed
        }
        return foundation.nextLocalRevision
    }

    private func count<T: PersistentModel>(
        _ type: T.Type
    ) throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<T>())
    }
}

struct AppDataResetAction: Sendable {
    let begin:
        @MainActor @Sendable (_ confirmedStateDigest: String)
            async throws -> Void
}

private struct AppDataResetActionEnvironmentKey:
    EnvironmentKey {
    static let defaultValue: AppDataResetAction? = nil
}

extension EnvironmentValues {
    var appDataResetAction: AppDataResetAction? {
        get { self[AppDataResetActionEnvironmentKey.self] }
        set {
            self[AppDataResetActionEnvironmentKey.self] =
                newValue
        }
    }
}

@MainActor
struct DataResetStatusView: View {
    enum Kind {
        case preparing
        case restartRequired
        case recovery
    }

    @Environment(AppTheme.self) private var theme
    let kind: Kind

    var body: some View {
        ZStack {
            theme.rice.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("DATA / RESET")
                        .font(.caption.weight(.black))
                        .tracking(2)
                        .foregroundStyle(
                            theme.vermilionText
                        )
                    Text(title)
                        .font(.system(
                            size: 34,
                            weight: .black,
                            design: .serif
                        ))
                        .foregroundStyle(
                            theme.indigoDeep
                        )
                    Text(detail)
                        .font(.body)
                        .foregroundStyle(
                            theme.secondaryText
                        )
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                    if kind == .preparing {
                        ProgressView()
                            .tint(theme.indigo)
                            .accessibilityLabel(
                                "正在隔离旧资料"
                            )
                    }
                    Text(boundary)
                        .font(.caption)
                        .foregroundStyle(
                            theme.secondaryText
                        )
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                }
                .padding(24)
                .frame(
                    maxWidth: 560,
                    alignment: .leading
                )
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier(
            "dataReset."
                + identifier
        )
    }

    private var title: String {
        switch kind {
        case .preparing:
            "正在隔离旧资料"
        case .restartRequired:
            "请重新打开 App"
        case .recovery:
            "重置需要继续检查"
        }
    }

    private var detail: String {
        switch kind {
        case .preparing:
            "请暂时不要离开。旧资料正在转入受控隔离区；当前进程不会建立新的资料库。"
        case .restartRequired:
            "旧资料已经离开使用中的位置。完全退出并重新打开 App 后，系统会先完成清理与核对，再显示新的首次使用流程。"
        case .recovery:
            "App 已停止继续处理，避免把不完整状态误报为已清空。完全退出并重新打开后会从受控记录继续核对。"
        }
    }

    private var boundary: String {
        "这不会删除系统备份、Files/Photos 原件、截图，或已经导出和分享的副本。"
    }

    private var identifier: String {
        switch kind {
        case .preparing: "preparing"
        case .restartRequired: "restartRequired"
        case .recovery: "recovery"
        }
    }
}
