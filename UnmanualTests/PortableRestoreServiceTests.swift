import Foundation
import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class PortableRestoreServiceTests:
    XCTestCase {
    func testStagingAncestryReplacementBeforeWriteDoesNotLeakData()
        async throws {
        let layout = try makeLayout()
        let source = try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        let coordinator =
            AppDataControlCoordinator(
                generationID: source.generationID
            )
        let inventory = try XCTUnwrap(
            DataInventoryProductionService(
                store: source,
                dataControlCoordinator:
                    coordinator
            )
        )
        let package = try await inventory
            .completeBackupPackage()
        addTeardownBlock {
            try? await inventory.discardTransferPackage(
                at: package.packageURL
            )
        }
        let service =
            PortableRestorePreparationService(
                store: source,
                inventory: inventory,
                coordinator: coordinator,
                verificationMode:
                    .simulatorTestHarness
            )
        let plan = try await service.makePlan(
            for: package,
            mode: .replace
        )
        let journal = try
            PortableRestorePreparationService
            .makeJournal(
                operationID: UUID(),
                plan: plan,
                package: package,
                currentPointer:
                    GenerationPointerStore(
                        layout: layout
                    ).read(),
                now: Date(
                    timeIntervalSince1970:
                        1_800_699_000
                )
            )
        let movedRecovery = layout.rootURL
            .appending(
                path: "MovedRecovery",
                directoryHint: .isDirectory
            )
        let externalRecovery = layout.rootURL
            .appending(
                path: "ExternalRecovery",
                directoryHint: .isDirectory
            )

        XCTAssertThrowsError(
            try PortableRestorePreparationService
                .stageDurably(
                    package,
                    journal: journal,
                    layout: layout,
                    beforeStagingWrite: {
                        try FileManager.default
                            .moveItem(
                                at: layout.recoveryURL,
                                to: movedRecovery
                            )
                        try FileManager.default
                            .createDirectory(
                                at: externalRecovery,
                                withIntermediateDirectories:
                                    false
                            )
                        try FileManager.default
                            .createSymbolicLink(
                                at: layout.recoveryURL,
                                withDestinationURL:
                                    externalRecovery
                            )
                    }
                )
        ) {
            XCTAssertEqual(
                $0 as? PortablePackageCleanupError,
                .unsafeTarget
            )
        }
        let externalOperation = externalRecovery
            .appending(
                path: "PortableImports/"
                    + journal.operationID
                    .uuidString.lowercased(),
                directoryHint: .isDirectory
            )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: externalOperation.path
            )
        )
        let movedPackage = movedRecovery
            .appending(
                path: "PortableImports/"
                    + journal.operationID
                    .uuidString.lowercased()
                    + "/package.unmanualbackup",
                directoryHint: .isDirectory
            )
        XCTAssertEqual(
            try FileManager.default
                .contentsOfDirectory(
                    atPath: movedPackage.path
                ),
            []
        )
    }

    func testReplaceBuildsInactiveGenerationThenColdLaunchActivatesPointerLast()
        async throws {
        let layout = try makeLayout()
        let source = try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        let sourceReader = AppReadActor(
            modelContainer: source.container
        )
        let initialPrivacy = try await sourceReader
            .privacyControlSnapshot()
        _ = try await AppWriteActor(
            modelContainer: source.container
        ).setAppLock(
            SetAppLockCommand(
                operationID: UUID(),
                expectedLocalRevision:
                    initialPrivacy.localRevision,
                expectedDigestHex:
                    initialPrivacy.digestHex,
                isEnabled: true,
                committedAt: Date(
                    timeIntervalSince1970:
                        1_800_700_000
                )
            )
        )

        let coordinator =
            AppDataControlCoordinator(
                generationID: source.generationID
            )
        let inventory = try XCTUnwrap(
            DataInventoryProductionService(
                store: source,
                dataControlCoordinator:
                    coordinator
            )
        )
        let package = try await inventory
            .completeBackupPackage(
                capturedAt: Date(
                    timeIntervalSince1970:
                        1_800_700_100
                )
            )
        addTeardownBlock {
            try? await inventory.discardTransferPackage(
                at: package.packageURL
            )
        }
        let service =
            PortableRestorePreparationService(
                store: source,
                inventory: inventory,
                coordinator: coordinator,
                verificationMode:
                    .simulatorTestHarness
            )
        let plan = try await service.makePlan(
            for: package,
            mode: .replace
        )
        XCTAssertTrue(plan.canConfirm)
        let sourcePointer =
            try GenerationPointerStore(
                layout: layout
            ).read()

        let prepared = try await service.prepare(
            auditedPackage: package,
            plan: plan,
            now: Date(
                timeIntervalSince1970:
                    1_800_700_200
            )
        )

        XCTAssertEqual(
            prepared.journal.phase,
            .restartRequired
        )
        XCTAssertEqual(
            try GenerationPointerStore(
                layout: layout
            ).read(),
            sourcePointer
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath:
                    layout.generationDirectoryURL(
                        for:
                            prepared.journal
                                .targetGenerationID
                    ).path
            )
        )

        let notificationClient =
            PortableRestoreNotificationFixture(
                pending: [
                    "unmanual.exec.v1.pending",
                    "foreign.pending"
                ],
                delivered: [
                    "unmanual.countdown.v1.delivered",
                    "foreign.delivered"
                ]
            )
        let reopened = try await
            PortableRestoreColdLaunchCoordinator(
                layout: layout,
                notificationClient:
                    notificationClient,
                verificationMode:
                    .simulatorTestHarness
            ).open()

        XCTAssertEqual(
            reopened.generationID,
            prepared.journal.targetGenerationID
        )
        let activePointer =
            try GenerationPointerStore(
                layout: layout
            ).read()
        XCTAssertEqual(
            activePointer.generationID,
            prepared.journal.targetGenerationID
        )
        XCTAssertEqual(
            activePointer.datasetID,
            prepared.journal.targetDatasetID
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath:
                    layout.generationDirectoryURL(
                        for: source.generationID
                    ).path
            )
        )
        let activated = try XCTUnwrap(
            PortableRestoreJournalStore(
                layout: layout
            ).readIfPresent()
        )
        XCTAssertEqual(activated.phase, .activated)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    activated.stagingURL(
                        in: layout
                    ).path
            )
        )

        let targetReader = AppReadActor(
            modelContainer: reopened.container
        )
        let targetPrivacy = try await targetReader
            .privacyControlSnapshot()
        XCTAssertFalse(targetPrivacy.appLockEnabled)
        XCTAssertNotNil(
            targetPrivacy.lastOperationID
        )
        let context = ModelContext(reopened.container)
        let notifications = try context.fetch(
            FetchDescriptor<
                NotificationCoverageRecord
            >()
        )
        let countdownNotifications = try context.fetch(
            FetchDescriptor<
                CountdownNotificationCoverageRecord
            >()
        )
        XCTAssertEqual(
            notifications.map(\.statusRawValue),
            [
                NotificationCoverageStatus
                    .staleObservation.rawValue
            ]
        )
        XCTAssertEqual(
            countdownNotifications
                .map(\.statusRawValue),
            [
                NotificationCoverageStatus
                    .staleObservation.rawValue
            ]
        )
        let reopenedInventory = try XCTUnwrap(
            DataInventoryProductionService(
                store: reopened,
                dataControlCoordinator:
                    AppDataControlCoordinator(
                        generationID:
                            reopened.generationID
                    )
            )
        )
        let manifest = try await
            reopenedInventory.manifest()
        XCTAssertEqual(
            manifest.completeness,
            .complete
        )
        let remaining =
            await notificationClient.snapshot()
        XCTAssertEqual(
            remaining.pending,
            ["foreign.pending"]
        )
        XCTAssertEqual(
            remaining.delivered,
            ["foreign.delivered"]
        )
    }

    func testStaleLocalPlanFailsBeforeJournalOrTargetWrite()
        async throws {
        let layout = try makeLayout()
        let source = try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        let coordinator =
            AppDataControlCoordinator(
                generationID: source.generationID
            )
        let inventory = try XCTUnwrap(
            DataInventoryProductionService(
                store: source,
                dataControlCoordinator:
                    coordinator
            )
        )
        let package = try await inventory
            .completeBackupPackage()
        addTeardownBlock {
            try? await inventory.discardTransferPackage(
                at: package.packageURL
            )
        }
        let service =
            PortableRestorePreparationService(
                store: source,
                inventory: inventory,
                coordinator: coordinator,
                verificationMode:
                    .simulatorTestHarness
            )
        let plan = try await service.makePlan(
            for: package,
            mode: .replace
        )
        let privacy = try await AppReadActor(
            modelContainer: source.container
        ).privacyControlSnapshot()
        _ = try await AppWriteActor(
            modelContainer: source.container
        ).setAppLock(
            SetAppLockCommand(
                operationID: UUID(),
                expectedLocalRevision:
                    privacy.localRevision,
                expectedDigestHex:
                    privacy.digestHex,
                isEnabled: true
            )
        )

        do {
            _ = try await service.prepare(
                auditedPackage: package,
                plan: plan
            )
            XCTFail("Expected stale plan rejection")
        } catch {
            XCTAssertNotNil(error)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    layout.portableRestoreJournalURL
                        .path
            )
        )
        let pointer = try GenerationPointerStore(
            layout: layout
        ).read()
        XCTAssertEqual(
            pointer.generationID,
            source.generationID
        )
        let generationEntries =
            try FileManager.default
                .contentsOfDirectory(
                    at: layout.generationsURL,
                    includingPropertiesForKeys: nil
                )
        XCTAssertEqual(generationEntries.count, 1)
    }

    func testColdLaunchReplaysEveryDurablePhaseIncludingPointerWrittenBeforeJournal()
        async throws {
        let phases: [PortableRestorePhase] = [
            .preparingTarget,
            .targetDirectoryPrepared,
            .databaseWritten,
            .attachmentsCopied,
            .targetPrepared,
            .targetValidated,
            .restartRequired
        ]
        for phase in phases {
            let layout = try makeLayout()
            let source = try AppDataStoreBootstrapper(
                layout: layout,
                backupPolicy: .systemManaged,
                fileProtectionVerificationMode:
                    .simulatorTestHarness
            ).open()
            let coordinator =
                AppDataControlCoordinator(
                    generationID:
                        source.generationID
                )
            let inventory = try XCTUnwrap(
                DataInventoryProductionService(
                    store: source,
                    dataControlCoordinator:
                        coordinator
                )
            )
            let package = try await inventory
                .completeBackupPackage()
            addTeardownBlock {
                try? await inventory
                    .discardTransferPackage(
                        at: package.packageURL
                    )
            }
            let service =
                PortableRestorePreparationService(
                    store: source,
                    inventory: inventory,
                    coordinator: coordinator,
                    verificationMode:
                        .simulatorTestHarness
                )
            let plan = try await service.makePlan(
                for: package,
                mode: .replace
            )
            let sourcePointer =
                try GenerationPointerStore(
                    layout: layout
                ).read()
            let journal =
                try PortableRestorePreparationService
                    .makeJournal(
                        operationID: UUID(),
                        plan: plan,
                        package: package,
                        currentPointer:
                            sourcePointer,
                        now: Date(
                            timeIntervalSince1970:
                                1_800_710_000
                        )
                    )
            _ = try PortableRestorePreparationService
                .stageDurably(
                    package,
                    journal: journal,
                    layout: layout
                )
            try PortableRestoreJournalStore(
                layout: layout
            ).write(journal)
            let stopped = try await
                PortableRestoreTargetBuilder.advance(
                    journal,
                    layout: layout,
                    verificationMode:
                        .simulatorTestHarness,
                    stopAfterPhase: phase
                )
            XCTAssertEqual(stopped.phase, phase)
            XCTAssertEqual(
                try GenerationPointerStore(
                    layout: layout
                ).read(),
                sourcePointer
            )

            if phase == .restartRequired {
                try GenerationPointerStore(
                    layout: layout
                ).write(
                    GenerationPointer(
                        generationID:
                            stopped
                                .targetGenerationID,
                        origin:
                            .existingGeneration,
                        datasetID:
                            stopped.targetDatasetID,
                        minimumFactCount:
                            stopped.factCount,
                        minimumRevisionCount:
                            stopped.revisionCount
                    )
                )
            }

            let reopened = try await
                PortableRestoreColdLaunchCoordinator(
                    layout: layout,
                    notificationClient:
                        PortableRestoreNotificationFixture(
                            pending: [],
                            delivered: []
                        ),
                    verificationMode:
                        .simulatorTestHarness
                ).open()
            XCTAssertEqual(
                reopened.generationID,
                stopped.targetGenerationID,
                "phase \(phase)"
            )
            XCTAssertEqual(
                try PortableRestoreJournalStore(
                    layout: layout
                ).readIfPresent()?.phase,
                .activated,
                "phase \(phase)"
            )
        }
    }

    func testDurableJournalFailureInvalidatesOldSessionAndColdLaunchReplays()
        async throws {
        let layout = try makeLayout()
        let source = try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        let coordinator =
            AppDataControlCoordinator(
                generationID: source.generationID
            )
        let inventory = try XCTUnwrap(
            DataInventoryProductionService(
                store: source,
                dataControlCoordinator:
                    coordinator
            )
        )
        let package = try await inventory
            .completeBackupPackage()
        addTeardownBlock {
            try? await inventory.discardTransferPackage(
                at: package.packageURL
            )
        }
        let service =
            PortableRestorePreparationService(
                store: source,
                inventory: inventory,
                coordinator: coordinator,
                verificationMode:
                    .simulatorTestHarness,
                targetAdvancer: {
                    _, _, _ in
                    throw PortableRestoreServiceError
                        .targetInvalid
                }
            )
        let plan = try await service.makePlan(
            for: package,
            mode: .replace
        )
        let sourcePointer =
            try GenerationPointerStore(
                layout: layout
            ).read()

        do {
            _ = try await service.prepare(
                auditedPackage: package,
                plan: plan
            )
            XCTFail("Expected durable-boundary failure")
        } catch {
            XCTAssertEqual(
                error as? PortableRestoreServiceError,
                .recoveryRequired
            )
        }
        XCTAssertNotNil(
            try PortableRestoreJournalStore(
                layout: layout
            ).readIfPresent()
        )
        XCTAssertEqual(
            try GenerationPointerStore(
                layout: layout
            ).read(),
            sourcePointer
        )
        do {
            _ = try await coordinator
                .withMutationLease { true }
            XCTFail("Expected invalidated coordinator")
        } catch {
            XCTAssertEqual(
                error as? AppDataControlCoordinatorFailure,
                .invalidated
            )
        }

        let reopened = try await
            PortableRestoreColdLaunchCoordinator(
                layout: layout,
                notificationClient:
                    PortableRestoreNotificationFixture(
                        pending: [],
                        delivered: []
                    ),
                verificationMode:
                    .simulatorTestHarness
            ).open()
        XCTAssertNotEqual(
            reopened.generationID,
            source.generationID
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath:
                    layout.generationDirectoryURL(
                        for: source.generationID
                    ).path
            )
        )
    }

    func testColdLaunchRejectsSourceMutationAfterDurableJournal()
        async throws {
        let layout = try makeLayout()
        let source = try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        let coordinator =
            AppDataControlCoordinator(
                generationID: source.generationID
            )
        let inventory = try XCTUnwrap(
            DataInventoryProductionService(
                store: source,
                dataControlCoordinator:
                    coordinator
            )
        )
        let package = try await inventory
            .completeBackupPackage()
        addTeardownBlock {
            try? await inventory.discardTransferPackage(
                at: package.packageURL
            )
        }
        let service =
            PortableRestorePreparationService(
                store: source,
                inventory: inventory,
                coordinator: coordinator,
                verificationMode:
                    .simulatorTestHarness
            )
        let plan = try await service.makePlan(
            for: package,
            mode: .replace
        )
        _ = try await service.prepare(
            auditedPackage: package,
            plan: plan
        )
        let privacy = try await AppReadActor(
            modelContainer: source.container
        ).privacyControlSnapshot()
        _ = try await AppWriteActor(
            modelContainer: source.container
        ).setAppLock(
            SetAppLockCommand(
                operationID: UUID(),
                expectedLocalRevision:
                    privacy.localRevision,
                expectedDigestHex:
                    privacy.digestHex,
                isEnabled: true
            )
        )
        let sourcePointer =
            try GenerationPointerStore(
                layout: layout
            ).read()

        do {
            _ = try await
                PortableRestoreColdLaunchCoordinator(
                    layout: layout,
                    notificationClient:
                        PortableRestoreNotificationFixture(
                            pending: [],
                            delivered: []
                        ),
                    verificationMode:
                        .simulatorTestHarness
                ).open()
            XCTFail("Expected changed source rejection")
        } catch {
            XCTAssertEqual(
                error as? PortableRestoreServiceError,
                .impactChanged
            )
        }
        XCTAssertEqual(
            try GenerationPointerStore(
                layout: layout
            ).read(),
            sourcePointer
        )
    }

    func testColdLaunchRetriesExactStagingCleanupBeforeActivation()
        async throws {
        let layout = try makeLayout()
        let source = try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        let coordinator =
            AppDataControlCoordinator(
                generationID: source.generationID
            )
        let inventory = try XCTUnwrap(
            DataInventoryProductionService(
                store: source,
                dataControlCoordinator:
                    coordinator
            )
        )
        let package = try await inventory
            .completeBackupPackage()
        addTeardownBlock {
            try? await inventory.discardTransferPackage(
                at: package.packageURL
            )
        }
        let service =
            PortableRestorePreparationService(
                store: source,
                inventory: inventory,
                coordinator: coordinator,
                verificationMode:
                    .simulatorTestHarness
            )
        let plan = try await service.makePlan(
            for: package,
            mode: .replace
        )
        let prepared = try await service.prepare(
            auditedPackage: package,
            plan: plan
        )
        let stagingPath = prepared.journal
            .stagingURL(in: layout).path
        let foreignSibling = layout
            .portableRestoreStagingRootURL
            .appending(
                path: "foreign-do-not-delete",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: foreignSibling,
            withIntermediateDirectories: false
        )

        do {
            _ = try await
                PortableRestoreColdLaunchCoordinator(
                    layout: layout,
                    notificationClient:
                        PortableRestoreNotificationFixture(
                            pending: [],
                            delivered: []
                        ),
                    verificationMode:
                        .simulatorTestHarness,
                    stagingDiscarder: {
                        _, _ in
                        throw CocoaError(
                            .fileWriteUnknown
                        )
                    }
                ).open()
            XCTFail("Expected cleanup failure")
        } catch {
            XCTAssertNotNil(error)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: stagingPath
            )
        )
        XCTAssertEqual(
            try PortableRestoreJournalStore(
                layout: layout
            ).read().phase,
            .activationCleanupPending
        )

        let reopened = try await
            PortableRestoreColdLaunchCoordinator(
                layout: layout,
                notificationClient:
                    PortableRestoreNotificationFixture(
                        pending: [],
                        delivered: []
                    ),
                verificationMode:
                    .simulatorTestHarness
            ).open()
        XCTAssertEqual(
            reopened.generationID,
            prepared.journal.targetGenerationID
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: stagingPath
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: foreignSibling.path
            )
        )
        XCTAssertEqual(
            try PortableRestoreJournalStore(
                layout: layout
            ).read().phase,
            .activated
        )

        let reopenedAgain = try await
            PortableRestoreColdLaunchCoordinator(
                layout: layout,
                notificationClient:
                    PortableRestoreNotificationFixture(
                        pending: [],
                        delivered: []
                    ),
                verificationMode:
                    .simulatorTestHarness
            ).open()
        XCTAssertEqual(
            reopenedAgain.generationID,
            prepared.journal.targetGenerationID
        )
    }

    func testColdLaunchRejectsSymlinkedStagingRootWithoutDeletingExternalDirectory()
        async throws {
        let layout = try makeLayout()
        let source = try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        let coordinator =
            AppDataControlCoordinator(
                generationID: source.generationID
            )
        let inventory = try XCTUnwrap(
            DataInventoryProductionService(
                store: source,
                dataControlCoordinator:
                    coordinator
            )
        )
        let package = try await inventory
            .completeBackupPackage()
        addTeardownBlock {
            try? await inventory.discardTransferPackage(
                at: package.packageURL
            )
        }
        let service =
            PortableRestorePreparationService(
                store: source,
                inventory: inventory,
                coordinator: coordinator,
                verificationMode:
                    .simulatorTestHarness
            )
        let plan = try await service.makePlan(
            for: package,
            mode: .replace
        )
        let prepared = try await service.prepare(
            auditedPackage: package,
            plan: plan
        )

        do {
            _ = try await
                PortableRestoreColdLaunchCoordinator(
                    layout: layout,
                    notificationClient:
                        PortableRestoreNotificationFixture(
                            pending: [],
                            delivered: []
                        ),
                    verificationMode:
                        .simulatorTestHarness,
                    stagingDiscarder: {
                        _, _ in
                        throw CocoaError(
                            .fileWriteUnknown
                        )
                    }
                ).open()
            XCTFail("Expected cleanup failure")
        } catch {
            XCTAssertNotNil(error)
        }
        XCTAssertEqual(
            try PortableRestoreJournalStore(
                layout: layout
            ).read().phase,
            .activationCleanupPending
        )

        let stagingRoot =
            layout.portableRestoreStagingRootURL
        try FileManager.default.removeItem(
            at: stagingRoot
        )
        let externalRoot = layout.rootURL
            .deletingLastPathComponent()
            .appending(
                path: "ExternalPortableImports",
                directoryHint: .isDirectory
            )
        let externalOperation = externalRoot
            .appending(
                path: prepared.journal.operationID
                    .uuidString.lowercased(),
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: externalOperation,
            withIntermediateDirectories: true
        )
        let sentinel = externalOperation
            .appending(path: "must-remain.txt")
        try Data("external".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: stagingRoot,
            withDestinationURL: externalRoot
        )

        do {
            _ = try await
                PortableRestoreColdLaunchCoordinator(
                    layout: layout,
                    notificationClient:
                        PortableRestoreNotificationFixture(
                            pending: [],
                            delivered: []
                        ),
                    verificationMode:
                        .simulatorTestHarness
                ).open()
            XCTFail("Expected unsafe staging rejection")
        } catch {
            XCTAssertEqual(
                error as? PortablePackageCleanupError,
                .unsafeTarget
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: sentinel.path
            )
        )
        XCTAssertNotNil(
            try? FileManager.default
                .destinationOfSymbolicLink(
                    atPath: stagingRoot.path
                )
        )
        XCTAssertEqual(
            try PortableRestoreJournalStore(
                layout: layout
            ).read().phase,
            .activationCleanupPending
        )
        XCTAssertTrue(
            try XCTUnwrap(
                PortablePackageCleanupJournalStore(
                    layout: layout
                ).readIfPresent()
            ).intents.contains {
                $0.kind == .restoreStaging
                    && $0.operationID
                        == prepared.journal.operationID
            }
        )
    }

    private func makeLayout() throws
        -> AppDataStoreLayout {
        let applicationSupport = try XCTUnwrap(
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        )
        let root = applicationSupport.appending(
            path:
                "UnmanualPortableRestoreTests-"
                + UUID().uuidString.lowercased(),
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: root
            )
        }
        return AppDataStoreLayout(
            rootURL: root.appending(
                path: "Unmanual",
                directoryHint: .isDirectory
            ),
            legacyStoreURL:
                root.appending(path: "default.store")
        )
    }
}

private actor PortableRestoreNotificationFixture:
    DataResetNotificationClient {
    private var pending: [String]
    private var delivered: [String]

    init(
        pending: [String],
        delivered: [String]
    ) {
        self.pending = pending
        self.delivered = delivered
    }

    func pendingIdentifiers() async throws -> [String] {
        pending
    }

    func deliveredIdentifiers() async throws
        -> [String] {
        delivered
    }

    func removePendingIdentifiers(
        _ identifiers: [String]
    ) async throws {
        let removed = Set(identifiers)
        pending.removeAll {
            removed.contains($0)
        }
    }

    func removeDeliveredIdentifiers(
        _ identifiers: [String]
    ) async throws {
        let removed = Set(identifiers)
        delivered.removeAll {
            removed.contains($0)
        }
    }

    func snapshot() -> (
        pending: [String],
        delivered: [String]
    ) {
        (pending, delivered)
    }
}
