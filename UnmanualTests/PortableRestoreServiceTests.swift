import Darwin
import Foundation
import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class PortableRestoreServiceTests:
    XCTestCase {
    func testV13SemanticPreflightAcceptsCurrentPackage()
        async throws {
        let layout = try makeLayout()
        let source = try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        let inventory = try XCTUnwrap(
            DataInventoryProductionService(
                store: source,
                dataControlCoordinator:
                    AppDataControlCoordinator(
                        generationID: source.generationID
                    )
            )
        )
        let package = try await inventory.completeBackupPackage()
        addTeardownBlock {
            try? await inventory.discardTransferPackage(
                at: package.packageURL
            )
        }
        let audited = try PortableBackupPackageAuditor.audit(
            at: package.packageURL
        )
        let container = try AppModelContainerFactory
            .makeInMemoryContentFavoriteContainer()
        let context = ModelContext(container)
        let insertion = try PortableV13RecordAdapter.insert(
            audited.readableDocument,
            into: context,
            deviceObservationDate: Date(
                timeIntervalSince1970: 1_800_699_000
            )
        )
        try context.save()
        XCTAssertEqual(
            insertion.insertedRecordCount,
            audited.readableDocument.payload.records.count
        )
        let identity = try AppDataStoreBootstrapper(
            layout: layout
        ).validateV13DataInventoryFoundation(in: context)
        XCTAssertEqual(
            identity.factCount,
            audited.readableDocument.payload.records.count
        )
    }

    func testV12PackageFullReplaceColdLaunchActivatesV13WithZeroFavorites()
        async throws {
        let sourceLayout = try makeLayout()
        let source = try AppDataStoreBootstrapper(
            layout: sourceLayout,
            backupPolicy: .systemManaged,
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        let capture = try await
            DataInventoryDatabaseCaptureActor(
                modelContainer: source.container
            ).capture(
                layout: sourceLayout,
                schemaVersion:
                    PortableDataSchemaContract.v12.schemaVersion
            )
        let document = try DataInventoryProductionService
            .makePortableDocument(
                database: capture,
                generationID: source.generationID,
                capturedAt: Date(
                    timeIntervalSince1970:
                        1_800_698_000
                ),
                schemaVersion:
                    PortableDataSchemaContract.v12.schemaVersion
            )
        XCTAssertEqual(
            document.payload.schemaVersion,
            PortableDataSchemaContract.v12.schemaVersion
        )
        XCTAssertEqual(document.payload.modelCounts.count, 54)
        let package = try buildPackage(
            document,
            in: sourceLayout,
            name: "V12Package"
        )

        let targetLayout = try makeLayout()
        let reopened = try await fullReplace(
            package,
            into: targetLayout,
            now: Date(
                timeIntervalSince1970: 1_800_698_100
            )
        )

        let pointer = try GenerationPointerStore(
            layout: targetLayout
        ).read()
        XCTAssertEqual(
            pointer.schemaVersion,
            PortableDataSchemaContract.v13.schemaVersion
        )
        XCTAssertEqual(pointer.generationID, reopened.generationID)
        XCTAssertEqual(pointer.datasetID, document.payload.datasetID)
        let favorites = try await AppReadActor(
            modelContainer: reopened.container
        ).contentFavoriteSnapshots()
        XCTAssertEqual(favorites, [])
        let inventory = try XCTUnwrap(
            DataInventoryProductionService(
                store: reopened,
                dataControlCoordinator:
                    AppDataControlCoordinator(
                        generationID: reopened.generationID
                    )
            )
        )
        let restored = try await inventory.readableJSONV2(
            capturedAt: Date(
                timeIntervalSince1970: 1_800_698_200
            )
        )
        XCTAssertEqual(
            restored.payload.schemaVersion,
            PortableDataSchemaContract.v13.schemaVersion
        )
        XCTAssertEqual(restored.payload.modelCounts.count, 55)
        XCTAssertEqual(
            restored.payload.modelCounts.first {
                $0.modelType
                    == ContentFavoriteContract.recordType
            }?.rowCount,
            0
        )
        XCTAssertEqual(
            try PortableRestoreJournalStore(
                layout: targetLayout
            ).read().phase,
            .activated
        )
    }

    func testV13FavoritesFullReplaceColdLaunchPreservesActiveRemovedAndAudit()
        async throws {
        let sourceLayout = try makeLayout()
        let source = try AppDataStoreBootstrapper(
            layout: sourceLayout,
            backupPolicy: .systemManaged,
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        let writer = AppWriteActor(
            modelContainer: source.container
        )
        let version =
            "offline-contextual-content-candidate.1"
        let digest =
            String(repeating: "a", count: 64)
        let activeCommand = SetContentFavoriteCommand(
            operationID: UUID(),
            recordID: UUID(),
            contentID: "card.restore-active",
            contentVersion: version,
            cardDigest: digest,
            desiredFavorite: true,
            expectedLocalRevision: nil,
            expectedDigestHex: nil,
            committedAt: Date(
                timeIntervalSince1970: 1_800_698_300
            )
        )
        _ = try await writer.setContentFavorite(activeCommand)
        let removedCreate = SetContentFavoriteCommand(
            operationID: UUID(),
            recordID: UUID(),
            contentID: "card.restore-removed",
            contentVersion: version,
            cardDigest: digest,
            desiredFavorite: true,
            expectedLocalRevision: nil,
            expectedDigestHex: nil,
            committedAt: Date(
                timeIntervalSince1970: 1_800_698_310
            )
        )
        let beforeRemoval = try await writer
            .setContentFavorite(removedCreate).snapshot
        let removedCommand = SetContentFavoriteCommand(
            operationID: UUID(),
            recordID: removedCreate.recordID,
            contentID: removedCreate.contentID,
            contentVersion: version,
            cardDigest: digest,
            desiredFavorite: false,
            expectedLocalRevision:
                beforeRemoval.localRevision,
            expectedDigestHex: beforeRemoval.digestHex,
            committedAt: Date(
                timeIntervalSince1970: 1_800_698_320
            )
        )
        _ = try await writer.setContentFavorite(removedCommand)
        let sourceSnapshots = try await AppReadActor(
            modelContainer: source.container
        ).contentFavoriteSnapshots()
        XCTAssertEqual(sourceSnapshots.count, 2)
        XCTAssertEqual(
            sourceSnapshots.filter(\.isFavorite).count,
            1
        )

        let sourceInventory = try XCTUnwrap(
            DataInventoryProductionService(
                store: source,
                dataControlCoordinator:
                    AppDataControlCoordinator(
                        generationID: source.generationID
                    )
            )
        )
        let package = try await sourceInventory
            .completeBackupPackage(
                capturedAt: Date(
                    timeIntervalSince1970:
                        1_800_698_330
                )
            )
        addTeardownBlock {
            try? await sourceInventory
                .discardTransferPackage(
                    at: package.packageURL
                )
        }
        XCTAssertEqual(
            package.readableDocument.payload.schemaVersion,
            PortableDataSchemaContract.v13.schemaVersion
        )

        let targetLayout = try makeLayout()
        let reopened = try await fullReplace(
            package,
            into: targetLayout,
            now: Date(
                timeIntervalSince1970: 1_800_698_340
            )
        )

        let restoredSnapshots = try await AppReadActor(
            modelContainer: reopened.container
        ).contentFavoriteSnapshots()
        XCTAssertEqual(restoredSnapshots, sourceSnapshots)
        XCTAssertEqual(
            restoredSnapshots.filter(\.isFavorite).count,
            1
        )
        XCTAssertEqual(
            restoredSnapshots.filter {
                !$0.isFavorite
            }.count,
            1
        )
        let context = ModelContext(reopened.container)
        XCTAssertNoThrow(
            try ContentFavoriteRelationshipValidator
                .validate(in: context)
        )
        let operationIDs: Set<UUID> = [
            activeCommand.operationID,
            removedCreate.operationID,
            removedCommand.operationID
        ]
        XCTAssertEqual(
            try context.fetch(
                FetchDescriptor<OperationReceiptRecord>()
            ).filter {
                operationIDs.contains($0.operationID)
            }.count,
            3
        )
        XCTAssertEqual(
            try context.fetch(
                FetchDescriptor<RecordRevision>()
            ).filter {
                $0.recordType
                    == ContentFavoriteContract.recordType
            }.count,
            2
        )
        let pointer = try GenerationPointerStore(
            layout: targetLayout
        ).read()
        XCTAssertEqual(
            pointer.schemaVersion,
            PortableDataSchemaContract.v13.schemaVersion
        )
        XCTAssertEqual(
            pointer.datasetID,
            package.readableDocument.payload.datasetID
        )
        XCTAssertEqual(
            try PortableRestoreJournalStore(
                layout: targetLayout
            ).read().phase,
            .activated
        )
    }

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

        do {
            _ = try await PortableRestorePreparationService
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
            XCTFail("Expected staging ancestry rejection")
        } catch {
            XCTAssertEqual(
                error as? PortablePackageCleanupError,
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
        let movedQuarantine = movedRecovery
            .appending(
                path: "PortableImports/.cleanup-"
                    + journal.operationID
                        .uuidString.lowercased(),
                directoryHint: .isDirectory
            )
        XCTAssertEqual(
            try FileManager.default
                .contentsOfDirectory(
                    atPath: movedQuarantine.path
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
        let reopened: BootstrappedAppDataStore
        do {
            reopened = try await
                PortableRestoreColdLaunchCoordinator(
                    layout: layout,
                    notificationClient:
                        notificationClient,
                    verificationMode:
                        .simulatorTestHarness
                ).open()
        } catch {
            let storeURL = layout.storeURL(
                for:
                    prepared.journal
                    .targetGenerationID
            )
            let modes = ["", "-wal", "-shm"]
                .compactMap { suffix -> String? in
                    let path = storeURL.path + suffix
                    var value = stat()
                    guard Darwin.lstat(
                            path,
                            &value
                          ) == 0 else {
                        return nil
                    }
                    return suffix + "="
                        + String(
                            UInt32(value.st_mode)
                                & 0o777,
                            radix: 8
                        )
                }
            let directoryModes = [
                layout.rootURL,
                layout.generationsURL,
                layout.generationDirectoryURL(
                    for:
                        prepared.journal
                        .targetGenerationID
                ),
                storeURL.deletingLastPathComponent(),
                layout.generationDirectoryURL(
                    for:
                        prepared.journal
                        .targetGenerationID
                ).appending(
                    path: "Files",
                    directoryHint: .isDirectory
                )
            ].compactMap { url -> String? in
                var value = stat()
                guard Darwin.lstat(
                        url.path,
                        &value
                      ) == 0 else {
                    return nil
                }
                return url.lastPathComponent
                    + "="
                    + String(
                        UInt32(value.st_mode) & 0o777,
                        radix: 8
                    )
            }
            XCTFail(
                "cold activation failed with modes "
                    + modes.joined(separator: ",")
                    + " dirs="
                    + directoryModes
                        .joined(separator: ",")
                    + ": \(error)"
            )
            throw error
        }

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
            let cleanup =
                PortablePackageCleanupCoordinator(
                    layout: layout
                )
            let cleanupIntent = try await cleanup.register(
                kind: .restoreStaging,
                operationID: journal.operationID
            )
            _ = try await PortableRestorePreparationService
                .stageDurably(
                    package,
                    journal: journal,
                    layout: layout,
                    bindArtifact: {
                        anchorIdentity,
                        rootIdentity,
                        packageIdentity in
                        _ = try await cleanup.bind(
                            cleanupIntent,
                            anchorIdentity:
                                anchorIdentity,
                            rootIdentity: rootIdentity,
                            packageIdentity:
                                packageIdentity
                        )
                    }
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

            let reopened: BootstrappedAppDataStore
            do {
                reopened = try await
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
            } catch {
                XCTFail(
                    "cold launch failed from phase \(phase): \(String(reflecting: error))"
                )
                throw error
            }
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

    func testColdLaunchResumesTargetCreationCrashBeforeAndAfterIdentityWrite()
        async throws {
        for persistIdentity in [false, true] {
            let fixture =
                try await makeDurablePreparingFixture()
            let identity = try PortableManagedPathSecurity
                .createOrResumeEmptyGenerationRoot(
                    generationsURL:
                        fixture.layout.generationsURL,
                    generationName:
                        fixture.journal.targetGenerationID
                        .uuidString.lowercased()
                )
            if persistIdentity {
                var bound = fixture.journal
                bound.bindTargetRoot(identity)
                try PortableRestoreJournalStore(
                    layout: fixture.layout
                ).write(
                    bound,
                    replacing: fixture.journal
                )
            }

            let reopened = try await
                PortableRestoreColdLaunchCoordinator(
                    layout: fixture.layout,
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
                fixture.journal.targetGenerationID,
                "persistIdentity=\(persistIdentity)"
            )
            XCTAssertEqual(
                try PortableRestoreJournalStore(
                    layout: fixture.layout
                ).read().phase,
                .activated
            )
        }
    }

    func testColdLaunchResumesTargetResetWithoutChangingBoundIdentity()
        async throws {
        for crashAfterRemoval in [true, false] {
            let fixture =
                try await makeDurablePreparingFixture()
            let prepared = try await
                PortableRestoreTargetBuilder.advance(
                    fixture.journal,
                    layout: fixture.layout,
                    verificationMode:
                        .simulatorTestHarness,
                    stopAfterPhase:
                        .targetDirectoryPrepared
                )
            let identity = try XCTUnwrap(
                prepared.targetRootIdentity
            )

            do {
                _ = try await
                    PortableRestoreTargetBuilder.advance(
                        prepared,
                        layout: fixture.layout,
                        verificationMode:
                            .simulatorTestHarness,
                        afterTargetContentsRemoved: {
                            if crashAfterRemoval {
                                throw CocoaError(
                                    .fileWriteUnknown
                                )
                            }
                        },
                        beforeMaterializeDatabase: {
                            if !crashAfterRemoval {
                                throw CocoaError(
                                    .fileWriteUnknown
                                )
                            }
                        }
                    )
                XCTFail("Expected simulated crash")
            } catch {
                XCTAssertNotNil(error)
            }

            let durable = try PortableRestoreJournalStore(
                layout: fixture.layout
            ).read()
            XCTAssertEqual(
                durable.phase,
                .targetDirectoryPrepared
            )
            XCTAssertEqual(
                durable.targetRootIdentity,
                identity
            )
            XCTAssertEqual(
                try PortableManagedPathSecurity
                    .directoryIdentity(
                        at: fixture.layout
                            .generationDirectoryURL(
                                for:
                                    durable
                                    .targetGenerationID
                            )
                    ),
                identity
            )

            let reopened = try await
                PortableRestoreColdLaunchCoordinator(
                    layout: fixture.layout,
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
                durable.targetGenerationID,
                "crashAfterRemoval=\(crashAfterRemoval)"
            )
            XCTAssertEqual(
                try PortableRestoreJournalStore(
                    layout: fixture.layout
                ).read().phase,
                .activated
            )
        }
    }

    func testColdLaunchRejectsWholeTargetRootReplacementBeforePointerWrite()
        async throws {
        let fixture =
            try await makeDurablePreparingFixture()
        let prepared = try await
            PortableRestoreTargetBuilder.advance(
                fixture.journal,
                layout: fixture.layout,
                verificationMode:
                    .simulatorTestHarness
        )
        XCTAssertEqual(prepared.phase, .restartRequired)
        let mutationLease = try PortableManagedPathSecurity
            .GenerationTargetLease.acquire(
                layout: fixture.layout,
                generationName:
                    prepared.targetGenerationID
                    .uuidString.lowercased(),
                expectedTarget:
                    prepared.targetRootIdentity,
                expectedAncestry:
                    prepared.targetAncestry
            )
        try mutationLease.restoreNamespacePermissions()
        let target = fixture.layout
            .generationDirectoryURL(
                for: prepared.targetGenerationID
            )
        let original = fixture.layout.rootURL
            .appending(
                path: "displaced-target",
                directoryHint: .isDirectory
            )
        try FileManager.default.moveItem(
            at: target,
            to: original
        )
        try FileManager.default.copyItem(
            at: fixture.layout.generationDirectoryURL(
                for: prepared.sourceGenerationID
            ),
            to: target
        )
        let sourcePointer = try GenerationPointerStore(
            layout: fixture.layout
        ).read()

        do {
            _ = try await
                PortableRestoreColdLaunchCoordinator(
                    layout: fixture.layout,
                    notificationClient:
                        PortableRestoreNotificationFixture(
                            pending: [],
                            delivered: []
                        ),
                    verificationMode:
                        .simulatorTestHarness
                ).open()
            XCTFail("Expected root identity rejection")
        } catch {
            XCTAssertEqual(
                error as? PortableRestoreServiceError,
                .unsafeTarget
            )
        }
        XCTAssertEqual(
            try GenerationPointerStore(
                layout: fixture.layout
            ).read(),
            sourcePointer
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: target.path
            )
        )
    }

    func testNamespaceShieldBlocksGenerationAndChildReplacementDuringWrite()
        async throws {
        let fixture =
            try await makeDurablePreparingFixture()
        let target = fixture.layout
            .generationDirectoryURL(
                for: fixture.journal.targetGenerationID
            )
        let protectedEntries = [
            fixture.layout.generationsURL,
            target,
            target.appending(
                path: "Store",
                directoryHint: .isDirectory
            ),
            target.appending(
                path: "Files",
                directoryHint: .isDirectory
            )
        ]
        let replacements = protectedEntries.enumerated()
            .map { index, source in
                source.deletingLastPathComponent()
                    .appending(
                        path: ".shield-probe-\(index)",
                        directoryHint: .isDirectory
                    )
            }

        let prepared = try await
            PortableRestoreTargetBuilder.advance(
                fixture.journal,
                layout: fixture.layout,
                verificationMode:
                    .simulatorTestHarness,
                afterDatabaseNamespaceShield: {
                    for (source, replacement) in zip(
                        protectedEntries,
                        replacements
                    ) {
                        do {
                            try FileManager.default.moveItem(
                                at: source,
                                to: replacement
                            )
                            try? FileManager.default.moveItem(
                                at: replacement,
                                to: source
                            )
                            throw PortableRestoreServiceError
                                .unsafeTarget
                        } catch let error as
                            PortableRestoreServiceError {
                            throw error
                        } catch {
                            XCTAssertFalse(
                                FileManager.default.fileExists(
                                    atPath: replacement.path
                                )
                            )
                        }
                    }
                }
            )

        XCTAssertEqual(prepared.phase, .restartRequired)
        XCTAssertTrue(
            protectedEntries.allSatisfy {
                FileManager.default.fileExists(
                    atPath: $0.path
                )
            }
        )
        XCTAssertTrue(
            replacements.allSatisfy {
                !FileManager.default.fileExists(
                    atPath: $0.path
                )
            }
        )
    }

    func testColdActivationKeepsStoreAndFilesFrozenUntilPointerAndJournalAreDurable()
        async throws {
        let fixture =
            try await makeDurablePreparingFixture()
        let prepared = try await
            PortableRestoreTargetBuilder.advance(
                fixture.journal,
                layout: fixture.layout,
                verificationMode:
                    .simulatorTestHarness
            )
        XCTAssertEqual(prepared.phase, .restartRequired)
        let target = fixture.layout
            .generationDirectoryURL(
                for: prepared.targetGenerationID
            )
        let protectedEntries = [
            target.appending(
                path: "Store/user.sqlite"
            ),
            target.appending(
                path: "Files",
                directoryHint: .isDirectory
            ),
            target.appending(
                path: "Files/Attachments",
                directoryHint: .isDirectory
            )
        ]
        let replacements = protectedEntries.map {
            $0.deletingLastPathComponent().appending(
                path: ".activation-window-probe-"
                    + UUID().uuidString.lowercased()
            )
        }
        let sourcePointer = try GenerationPointerStore(
            layout: fixture.layout
        ).read()

        _ = try await PortableRestoreColdLaunchCoordinator(
            layout: fixture.layout,
            notificationClient:
                PortableRestoreNotificationFixture(
                    pending: [],
                    delivered: []
                ),
            verificationMode:
                .simulatorTestHarness,
            beforePointerWrite: {
                XCTAssertEqual(
                    try GenerationPointerStore(
                        layout: fixture.layout
                    ).read(),
                    sourcePointer
                )
                for (source, replacement) in zip(
                    protectedEntries,
                    replacements
                ) {
                    do {
                        try FileManager.default.moveItem(
                            at: source,
                            to: replacement
                        )
                        try? FileManager.default.moveItem(
                            at: replacement,
                            to: source
                        )
                        XCTFail(
                            "Namespace mutation unexpectedly succeeded: \(source.path)"
                        )
                    } catch {
                        XCTAssertFalse(
                            FileManager.default.fileExists(
                                atPath: replacement.path
                            )
                        )
                    }
                }
            }
        ).open()

        let active = try GenerationPointerStore(
            layout: fixture.layout
        ).read()
        XCTAssertEqual(
            active.generationID,
            prepared.targetGenerationID
        )
        XCTAssertEqual(
            try PortableRestoreJournalStore(
                layout: fixture.layout
            ).read().phase,
            .activated
        )
        let permissionProbe = target.appending(
            path: "Files/permission-restored"
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: permissionProbe.path,
                contents: Data()
            )
        )
    }

    func testColdActivationRejectsSameInodeStoreWriteThroughPreexistingDescriptor()
        async throws {
        let fixture =
            try await makeDurablePreparingFixture()
        let prepared = try await
            PortableRestoreTargetBuilder.advance(
                fixture.journal,
                layout: fixture.layout,
                verificationMode:
                    .simulatorTestHarness
            )
        let sourcePointer = try GenerationPointerStore(
            layout: fixture.layout
        ).read()
        let storeURL = fixture.layout.storeURL(
            for: prepared.targetGenerationID
        )
        let writer = try FileHandle(
            forUpdating: storeURL
        )
        defer { try? writer.close() }

        do {
            _ = try await PortableRestoreColdLaunchCoordinator(
                layout: fixture.layout,
                notificationClient:
                    PortableRestoreNotificationFixture(
                        pending: [],
                        delivered: []
                    ),
                verificationMode:
                    .simulatorTestHarness,
                beforePointerWrite: {
                    try writer.seek(toOffset: 32)
                    try writer.write(
                        contentsOf: Data([0x5a])
                    )
                    try writer.synchronize()
                }
            ).open()
            XCTFail(
                "Expected the activation content seal to reject the write"
            )
        } catch {
            XCTAssertEqual(
                error as? PortablePackageCleanupError,
                .unsafeTarget
            )
        }
        XCTAssertEqual(
            try GenerationPointerStore(
                layout: fixture.layout
            ).read(),
            sourcePointer
        )
        XCTAssertEqual(
            try PortableRestoreJournalStore(
                layout: fixture.layout
            ).read().phase,
            .restartRequired
        )
    }

    func testActivationContentSealRejectsSameInodeAttachmentPayloadWriteAndABA()
        async throws {
        let fixture =
            try await makeDurablePreparingFixture()
        let prepared = try await
            PortableRestoreTargetBuilder.advance(
                fixture.journal,
                layout: fixture.layout,
                verificationMode:
                    .simulatorTestHarness
            )
        do {
            let mutableLease = try
                PortableManagedPathSecurity
                .GenerationTargetLease.acquire(
                    layout: fixture.layout,
                    generationName:
                        prepared.targetGenerationID
                        .uuidString.lowercased(),
                    expectedTarget:
                        prepared.targetRootIdentity,
                    expectedAncestry:
                        prepared.targetAncestry
                )
            try mutableLease
                .restoreNamespacePermissions()
        }
        let targetFiles = fixture.layout
            .generationDirectoryURL(
                for: prepared.targetGenerationID
            )
            .appending(
                path: "Files",
                directoryHint: .isDirectory
            )
        let attachmentDirectory = targetFiles
            .appending(
                path:
                    "Attachments/"
                    + UUID().uuidString.lowercased(),
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: attachmentDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: attachmentDirectory.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath:
                attachmentDirectory
                .deletingLastPathComponent().path
        )
        let payloadURL = attachmentDirectory
            .appending(path: "payload.jpg")
        let original = Data("original-payload".utf8)
        try original.write(to: payloadURL)
        let writer = try FileHandle(
            forUpdating: payloadURL
        )
        defer { try? writer.close() }
        let lease = try PortableManagedPathSecurity
            .GenerationTargetLease.acquire(
                layout: fixture.layout,
                generationName:
                    prepared.targetGenerationID
                    .uuidString.lowercased(),
                expectedTarget:
                    prepared.targetRootIdentity,
                expectedAncestry:
                    prepared.targetAncestry
            )
        defer {
            try? lease.restoreNamespacePermissions()
        }
        try lease.beginNamespaceShield()
        try lease.sealFilesNamespace()
        try lease.sealActivationContents()

        try writer.seek(toOffset: 0)
        try writer.write(
            contentsOf: Data("modified-payload".utf8)
        )
        try writer.synchronize()
        XCTAssertThrowsError(
            try lease.verifyActivationContents()
        )

        try writer.truncate(atOffset: 0)
        try writer.write(contentsOf: original)
        try writer.synchronize()
        XCTAssertThrowsError(
            try lease.verifyActivationContents()
        )
    }

    func testActivationDirectorySealRejectsFilesRootAndNestedModeABAThenColdRestores()
        async throws {
        func checked<T>(
            _ label: String,
            _ operation: () throws -> T
        ) throws -> T {
            do {
                return try operation()
            } catch {
                XCTFail("\(label): \(error)")
                throw error
            }
        }
        let fixture =
            try await makeDurablePreparingFixture()
        let prepared = try await
            PortableRestoreTargetBuilder.advance(
                fixture.journal,
                layout: fixture.layout,
                verificationMode:
                    .simulatorTestHarness
            )
        do {
            let mutableLease = try checked(
                "preflight acquire"
            ) {
                try PortableManagedPathSecurity
                .GenerationTargetLease.acquire(
                    layout: fixture.layout,
                    generationName:
                        prepared.targetGenerationID
                        .uuidString.lowercased(),
                    expectedTarget:
                        prepared.targetRootIdentity,
                    expectedAncestry:
                        prepared.targetAncestry
                )
            }
            try checked("preflight cold restore") {
                try mutableLease
                    .restoreNamespacePermissions()
            }
        }
        let filesURL = fixture.layout
            .generationDirectoryURL(
                for: prepared.targetGenerationID
            )
            .appending(
                path: "Files",
                directoryHint: .isDirectory
            )
        let nestedURL = filesURL.appending(
            path: "Attachments/mode-aba",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: nestedURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: nestedURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath:
                nestedURL.deletingLastPathComponent()
                .path
        )

        for targetURL in [filesURL, nestedURL] {
            var lease: PortableManagedPathSecurity
                .GenerationTargetLease? = try checked(
                    "ABA acquire \(targetURL.lastPathComponent)"
                ) {
                try PortableManagedPathSecurity
                .GenerationTargetLease.acquire(
                    layout: fixture.layout,
                    generationName:
                        prepared.targetGenerationID
                        .uuidString.lowercased(),
                    expectedTarget:
                        prepared.targetRootIdentity,
                    expectedAncestry:
                        prepared.targetAncestry
                )
            }
            try checked(
                "ABA shield \(targetURL.lastPathComponent)"
            ) {
                try XCTUnwrap(lease)
                    .beginNamespaceShield()
            }
            try checked(
                "ABA files seal \(targetURL.lastPathComponent)"
            ) {
                try XCTUnwrap(lease)
                    .sealFilesNamespace()
            }
            try checked(
                "ABA content seal \(targetURL.lastPathComponent)"
            ) {
                try XCTUnwrap(lease)
                    .sealActivationContents()
            }
            let descriptor = targetURL.path.withCString {
                Darwin.open(
                    $0,
                    O_RDONLY | O_DIRECTORY
                        | O_NOFOLLOW | O_CLOEXEC
                )
            }
            XCTAssertGreaterThanOrEqual(
                descriptor,
                0
            )
            guard descriptor >= 0 else {
                throw CocoaError(.fileReadUnknown)
            }
            XCTAssertEqual(
                Darwin.fchmod(descriptor, 0o700),
                0
            )
            XCTAssertThrowsError(
                try lease?.verifyActivationContents()
            )
            XCTAssertEqual(
                Darwin.fchmod(descriptor, 0o500),
                0
            )
            XCTAssertThrowsError(
                try lease?.verifyActivationContents()
            )
            Darwin.close(descriptor)
            lease = nil

            let recoveryLease = try checked(
                "cold acquire \(targetURL.lastPathComponent)"
            ) {
                try PortableManagedPathSecurity
                .GenerationTargetLease.acquire(
                    layout: fixture.layout,
                    generationName:
                        prepared.targetGenerationID
                        .uuidString.lowercased(),
                    expectedTarget:
                        prepared.targetRootIdentity,
                    expectedAncestry:
                        prepared.targetAncestry
                )
            }
            try checked(
                "cold restore \(targetURL.lastPathComponent)"
            ) {
                try recoveryLease
                    .restoreNamespacePermissions()
            }
            var status = stat()
            XCTAssertEqual(
                Darwin.lstat(targetURL.path, &status),
                0
            )
            XCTAssertEqual(
                UInt32(status.st_mode) & 0o777,
                0o700
            )
        }
    }

    func testColdLaunchRejectsSelfConsistentTargetLogicalMutation()
        async throws {
        let fixture =
            try await makeDurablePreparingFixture()
        let prepared = try await
            PortableRestoreTargetBuilder.advance(
                fixture.journal,
                layout: fixture.layout,
                verificationMode:
                    .simulatorTestHarness
            )
        let mutationLease = try PortableManagedPathSecurity
            .GenerationTargetLease.acquire(
                layout: fixture.layout,
                generationName:
                    prepared.targetGenerationID
                    .uuidString.lowercased(),
                expectedTarget:
                    prepared.targetRootIdentity,
                expectedAncestry:
                    prepared.targetAncestry
            )
        try mutationLease.restoreNamespacePermissions()
        let original = fixture.package.readableDocument
        let privacy = try XCTUnwrap(
            original.payload.records.first {
                $0.modelType == "PrivacyControlRecord"
            }
        )
        let changedFields = privacy.fields.map { field in
            field.name == "appLockEnabled"
                ? PortableDataField(
                    name: field.name,
                    value: PortableDataValue(
                        kind: .bool,
                        boolValue: true
                    )
                )
                : field
        }
        let digestFields = try changedFields.map {
            RecordDigestV1.Field(
                $0.name,
                try $0.value.recordDigestValue()
            )
        }
        let changedPrivacy = PortableDataRecord(
            modelType: privacy.modelType,
            recordType: privacy.recordType,
            recordID: privacy.recordID,
            recordKey: privacy.recordKey,
            datasetID: privacy.datasetID,
            localRevision: privacy.localRevision,
            committedAtMicroseconds:
                privacy.committedAtMicroseconds,
            digestVersion: privacy.digestVersion,
            digestHex: try RecordDigestV1.sha256Hex(
                recordType: privacy.recordType,
                recordID: privacy.recordID,
                fields: digestFields
            ),
            fields: changedFields
        )
        let changed = try PortableDataV2Codec.makeDocument(
            payload: PortableDataV2Payload(
                schemaVersion:
                    original.payload.schemaVersion,
                datasetID: original.payload.datasetID,
                sourceGenerationID:
                    original.payload.sourceGenerationID,
                capturedAtMicroseconds:
                    original.payload.capturedAtMicroseconds,
                nextLocalRevision:
                    original.payload.nextLocalRevision,
                modelCounts:
                    original.payload.modelCounts,
                records: original.payload.records.map {
                    $0.recordKey == changedPrivacy.recordKey
                        ? changedPrivacy : $0
                },
                controls: original.payload.controls,
                activeAttachments:
                    original.payload.activeAttachments
            )
        )
        let storeDirectory = fixture.layout
            .storeDirectoryURL(
                for: prepared.targetGenerationID
            )
        for entry in try FileManager.default
            .contentsOfDirectory(
                at: storeDirectory,
                includingPropertiesForKeys: nil
            ) {
            try FileManager.default.removeItem(at: entry)
        }
        let container = try AppModelContainerFactory
            .makeContentFavoriteContainer(
                at: fixture.layout.storeURL(
                    for: prepared.targetGenerationID
                )
            )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        _ = try PortableV13RecordAdapter.insert(
            changed,
            into: context,
            deviceObservationDate: Date(
                timeIntervalSince1970:
                    TimeInterval(
                        prepared
                            .devicePolicyCommittedAtMicroseconds
                    ) / 1_000_000
            )
        )
        try context.save()
        let sourcePointer = try GenerationPointerStore(
            layout: fixture.layout
        ).read()

        do {
            _ = try await
                PortableRestoreColdLaunchCoordinator(
                    layout: fixture.layout,
                    notificationClient:
                        PortableRestoreNotificationFixture(
                            pending: [],
                            delivered: []
                        ),
                    verificationMode:
                        .simulatorTestHarness
                ).open()
            XCTFail("Expected full logical digest rejection")
        } catch {
            XCTAssertEqual(
                error as? PortableRestoreServiceError,
                .targetInvalid
            )
        }
        XCTAssertEqual(
            try GenerationPointerStore(
                layout: fixture.layout
            ).read(),
            sourcePointer
        )
    }

    private func makeDurablePreparingFixture()
        async throws -> (
            layout: AppDataStoreLayout,
            source: BootstrappedAppDataStore,
            inventory: DataInventoryProductionService,
            package: AuditedPortableBackup,
            journal: PortableRestoreJournal
        ) {
        let layout = try makeLayout()
        let source = try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        let coordinator = AppDataControlCoordinator(
            generationID: source.generationID
        )
        let inventory = try XCTUnwrap(
            DataInventoryProductionService(
                store: source,
                dataControlCoordinator: coordinator
            )
        )
        let package = try await inventory
            .completeBackupPackage()
        addTeardownBlock {
            try? await inventory.discardTransferPackage(
                at: package.packageURL
            )
        }
        let service = PortableRestorePreparationService(
            store: source,
            inventory: inventory,
            coordinator: coordinator,
            verificationMode: .simulatorTestHarness
        )
        let plan = try await service.makePlan(
            for: package,
            mode: .replace
        )
        let journal = try PortableRestorePreparationService
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
                        1_800_720_000
                )
            )
        let cleanup = PortablePackageCleanupCoordinator(
            layout: layout
        )
        let intent = try await cleanup.register(
            kind: .restoreStaging,
            operationID: journal.operationID
        )
        _ = try await PortableRestorePreparationService
            .stageDurably(
                package,
                journal: journal,
                layout: layout,
                bindArtifact: {
                    anchorIdentity,
                    rootIdentity,
                    packageIdentity in
                    _ = try await cleanup.bind(
                        intent,
                        anchorIdentity:
                            anchorIdentity,
                        rootIdentity: rootIdentity,
                        packageIdentity: packageIdentity
                    )
                }
            )
        try PortableRestoreJournalStore(
            layout: layout
        ).write(journal)
        return (
            layout,
            source,
            inventory,
            package,
            journal
        )
    }

    private func buildPackage(
        _ document: PortableDataV2Document,
        in layout: AppDataStoreLayout,
        name: String
    ) throws -> AuditedPortableBackup {
        let destination = layout.rootURL
            .deletingLastPathComponent()
            .appending(
                path:
                    name + "-"
                    + UUID().uuidString.lowercased(),
                directoryHint: .isDirectory
            )
        return try PortableBackupPackageBuilder.build(
            document: document,
            destinationURL: destination
        ) { _, _ in
            throw PortableBackupError.attachmentMismatch
        }
    }

    private func fullReplace(
        _ package: AuditedPortableBackup,
        into layout: AppDataStoreLayout,
        now: Date
    ) async throws -> BootstrappedAppDataStore {
        let current = try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        let coordinator = AppDataControlCoordinator(
            generationID: current.generationID
        )
        let inventory = try XCTUnwrap(
            DataInventoryProductionService(
                store: current,
                dataControlCoordinator: coordinator
            )
        )
        let service = PortableRestorePreparationService(
            store: current,
            inventory: inventory,
            coordinator: coordinator,
            verificationMode: .simulatorTestHarness
        )
        let plan = try await service.makePlan(
            for: package,
            mode: .replace
        )
        XCTAssertTrue(plan.canConfirm)
        let prepared = try await service.prepare(
            auditedPackage: package,
            plan: plan,
            now: now
        )
        XCTAssertEqual(
            try GenerationPointerStore(layout: layout)
                .read().generationID,
            current.generationID
        )
        XCTAssertEqual(
            prepared.journal.phase,
            .restartRequired
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
        return reopened
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
