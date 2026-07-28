import Foundation
import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class DataResetServiceTests: XCTestCase {
    func testArchiveDataControlDismissPolicyLocksBothResetAndDeletionWork()
        throws {
        XCTAssertTrue(
            ArchiveDataControlInteractionPolicy
                .canDismiss(
                    isWorking: false,
                    isResetWorking: false
                )
        )
        XCTAssertFalse(
            ArchiveDataControlInteractionPolicy
                .canDismiss(
                    isWorking: true,
                    isResetWorking: false
                )
        )
        XCTAssertFalse(
            ArchiveDataControlInteractionPolicy
                .canDismiss(
                    isWorking: false,
                    isResetWorking: true
                )
        )
    }

    func testTwoLaunchResetQuarantinesThenCreatesFreshV12Store()
        async throws {
        let layout = try makeLayout()
        let original = try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        let context = ModelContext(original.container)
        let metadata = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        )
        let notificationClient =
            ResetNotificationClientFixture(
                pending: [
                    "unmanual.exec.v1.pending",
                    "foreign.pending"
                ],
                delivered: [
                    "unmanual.countdown.v1.delivered",
                    "foreign.delivered"
                ]
            )
        let coordinator = AppDataControlCoordinator(
            generationID: original.generationID
        )
        let manifest = DataInventoryManifest(
            generationID: original.generationID,
            datasetID: metadata.datasetID,
            nextLocalRevision:
                metadata.nextLocalRevision,
            capturedAt: Date(
                timeIntervalSince1970: 1_800_300_000
            ),
            completeness: .complete,
            categories: try notificationCategories(
                pending: [
                    "unmanual.exec.v1.pending"
                ],
                delivered: [
                    "unmanual.countdown.v1.delivered"
                ]
            ),
            unmanagedBoundaries: [],
            stateDigest: String(
                repeating: "a",
                count: 64
            ),
            manifestDigest: String(
                repeating: "b",
                count: 64
            )
        )
        let preparation =
            DataResetPreparationService(
                store: original,
                manifestProvider:
                    ResetManifestProviderFixture(
                        manifest: manifest
                    ),
                coordinator: coordinator,
                notificationClient:
                    notificationClient
            )

        let prepared = try await preparation.prepare(
            confirmedStateDigest:
                manifest.stateDigest,
            now: Date(
                timeIntervalSince1970: 1_700_300_001
            )
        )
        let freshGenerationID =
            prepared.journal.freshGenerationID
        let freshDatasetID =
            prepared.journal.freshDatasetID
        let operationID =
            prepared.journal.operationID
        let restartJournal = try await
            DataResetCurrentProcessWorker()
            .advanceToRestartRequired(prepared)

        XCTAssertEqual(
            restartJournal.phase,
            .restartRequired
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.rootURL.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: prepared.store.layout
                    .quarantineRootURL(
                        operationID: operationID
                    ).path
            )
        )

        let reopened = try await
            DataResetColdLaunchCoordinator(
                notificationClient:
                    notificationClient,
                layoutProvider: { layout },
                fileProtectionVerificationMode:
                    .simulatorTestHarness
            )
            .open()

        XCTAssertEqual(
            reopened.generationID,
            freshGenerationID
        )
        let pointer = try GenerationPointerStore(
            layout: layout,
            backupPolicy: .systemManaged
        ).read()
        XCTAssertEqual(
            pointer.datasetID,
            freshDatasetID
        )
        let freshContext = ModelContext(
            reopened.container
        )
        XCTAssertEqual(
            try freshContext.fetchCount(
                FetchDescriptor<JourneyEntry>()
            ),
            0
        )
        let onboarding = try XCTUnwrap(
            freshContext.fetch(
                FetchDescriptor<
                    OnboardingProgressRecord
                >()
            ).first
        )
        XCTAssertEqual(onboarding.step, .privacy)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prepared.store.layout
                    .journalURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prepared.store.layout
                    .controlDirectoryURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prepared.store.layout
                    .quarantineRootURL(
                        operationID: operationID
                    ).path
            )
        )
        let remaining = await notificationClient
            .snapshot()
        XCTAssertEqual(
            remaining.pending,
            ["foreign.pending"]
        )
        XCTAssertEqual(
            remaining.delivered,
            ["foreign.delivered"]
        )
    }

    func testEveryColdLaunchJournalWriteDiskFullReopensAndCompletes()
        async throws
    {
        for failingWrite in 1...7 {
            let layout = try makeLayout()
            let notificationClient =
                ResetNotificationClientFixture(
                    pending: [
                        "unmanual.exec.v1.pending",
                        "foreign.pending"
                    ],
                    delivered: [
                        "unmanual.countdown.v1.delivered",
                        "foreign.delivered"
                    ]
                )
            let prepared = try await prepareReset(
                layout: layout,
                notificationClient: notificationClient,
                manifestSeed: failingWrite
            )
            _ = try await DataResetCurrentProcessWorker()
                .advanceToRestartRequired(prepared)
            let failingFileSystem =
                ColdLaunchFaultInjectingDataResetFileSystem(
                    base: DataResetFoundationFileSystem(),
                    failingWrite: failingWrite
                )

            do {
                _ = try await DataResetColdLaunchCoordinator(
                    notificationClient: notificationClient,
                    fileSystem: failingFileSystem,
                    layoutProvider: { layout },
                    fileProtectionVerificationMode:
                        .simulatorTestHarness
                ).open()
                XCTFail(
                    "journal write \(failingWrite) must fail"
                )
            } catch {
                XCTAssertEqual(
                    error as? DataResetStateMachineError,
                    .journalWriteFailed,
                    "journal write \(failingWrite)"
                )
            }

            let reopened = try await
                DataResetColdLaunchCoordinator(
                    notificationClient: notificationClient,
                    layoutProvider: { layout },
                    fileProtectionVerificationMode:
                        .simulatorTestHarness
                ).open()
            try await assertCompletedReset(
                reopened,
                prepared: prepared,
                notificationClient: notificationClient
            )
        }
    }

    func testColdLaunchNotificationEpochWriteDiskFullReopensAndCompletes()
        async throws
    {
        let layout = try makeLayout()
        let notificationClient =
            ResetNotificationClientFixture(
                pending: [
                    "unmanual.exec.v1.pending",
                    "foreign.pending"
                ]
            )
        let prepared = try await prepareReset(
            layout: layout,
            notificationClient: notificationClient,
            manifestSeed: 30
        )
        _ = try await DataResetCurrentProcessWorker()
            .advanceToRestartRequired(prepared)

        do {
            _ = try await DataResetColdLaunchCoordinator(
                notificationClient:
                    ResetOneShotFailingNotificationClient(
                        base: notificationClient
                    ),
                layoutProvider: { layout },
                fileProtectionVerificationMode:
                    .simulatorTestHarness
            ).open()
            XCTFail("notification observation must fail")
        } catch is ResetInjectedObservationFailure {
        }
        XCTAssertEqual(
            try prepared.store.read().phase,
            .freshStoreOpened
        )

        do {
            _ = try await DataResetColdLaunchCoordinator(
                notificationClient: notificationClient,
                fileSystem:
                    ColdLaunchFaultInjectingDataResetFileSystem(
                        base: DataResetFoundationFileSystem(),
                        failingWrite: 1
                    ),
                layoutProvider: { layout },
                fileProtectionVerificationMode:
                    .simulatorTestHarness
            ).open()
            XCTFail("notification epoch journal write must fail")
        } catch {
            XCTAssertEqual(
                error as? DataResetStateMachineError,
                .journalWriteFailed
            )
        }

        let reopened = try await DataResetColdLaunchCoordinator(
            notificationClient: notificationClient,
            layoutProvider: { layout },
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        try await assertCompletedReset(
            reopened,
            prepared: prepared,
            notificationClient: notificationClient
        )
    }

    func testEveryColdLaunchCleanupFailureReopensAndCompletes()
        async throws
    {
        for failingRemove in 1...2 {
            let layout = try makeLayout()
            let notificationClient =
                ResetNotificationClientFixture()
            let prepared = try await prepareReset(
                layout: layout,
                notificationClient: notificationClient,
                manifestSeed: 20 + failingRemove
            )
            _ = try await DataResetCurrentProcessWorker()
                .advanceToRestartRequired(prepared)
            let failingFileSystem =
                ColdLaunchFaultInjectingDataResetFileSystem(
                    base: DataResetFoundationFileSystem(),
                    failingRemove: failingRemove
                )

            do {
                _ = try await DataResetColdLaunchCoordinator(
                    notificationClient: notificationClient,
                    fileSystem: failingFileSystem,
                    layoutProvider: { layout },
                    fileProtectionVerificationMode:
                        .simulatorTestHarness
                ).open()
                XCTFail(
                    "cleanup remove \(failingRemove) must fail"
                )
            } catch {
                // The first failure leaves a complete journal. The
                // second leaves an empty, protected control directory.
                // Both states must converge on the next cold launch.
            }

            let reopened = try await
                DataResetColdLaunchCoordinator(
                    notificationClient: notificationClient,
                    layoutProvider: { layout },
                    fileProtectionVerificationMode:
                        .simulatorTestHarness
                ).open()
            try await assertCompletedReset(
                reopened,
                prepared: prepared,
                notificationClient: notificationClient
            )
        }
    }

    func testInitialJournalDiskFullLeavesOldStoreAndColdLaunchRecovers()
        async throws
    {
        let layout = try makeLayout()
        let notificationClient =
            ResetNotificationClientFixture()
        let prepared = try await prepareReset(
            layout: layout,
            notificationClient: notificationClient,
            manifestSeed: 40,
            fileSystem:
                InitialJournalDiskFullDataResetFileSystem(
                    base: DataResetFoundationFileSystem()
                )
        )
        let oldPointer = try GenerationPointerStore(
            layout: layout,
            backupPolicy: .systemManaged
        ).read()

        do {
            _ = try await DataResetCurrentProcessWorker()
                .advanceToRestartRequired(prepared)
            XCTFail("initial quiesced journal write must fail")
        } catch {
            XCTAssertEqual(
                error as? DataResetStateMachineError,
                .journalWriteFailed
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.rootURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prepared.store.layout
                    .quarantineRootURL(
                        operationID:
                            prepared.journal.operationID
                    ).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prepared.store.layout.journalURL.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath:
                    prepared.store.layout.controlDirectoryURL.path
            )
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: prepared.store.layout.controlDirectoryURL,
                includingPropertiesForKeys: nil
            ).isEmpty
        )

        let reopened = try await DataResetColdLaunchCoordinator(
            notificationClient: notificationClient,
            layoutProvider: { layout },
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        XCTAssertEqual(
            reopened.generationID,
            oldPointer.generationID
        )
        XCTAssertEqual(
            try GenerationPointerStore(
                layout: layout,
                backupPolicy: .systemManaged
            ).read(),
            oldPointer
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    prepared.store.layout.controlDirectoryURL.path
            )
        )
    }

    func testOldTaskCannotEnterInvalidatedPreResetSession()
        async throws
    {
        let layout = try makeLayout()
        let notificationClient =
            ResetNotificationClientFixture()
        let original = try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        let context = ModelContext(original.container)
        let metadata = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        )
        let coordinator = AppDataControlCoordinator(
            generationID: original.generationID
        )
        let gate = ResetOldTaskGate()
        let oldTask = Task {
            await gate.wait()
            return try await coordinator.withReadLease {
                true
            }
        }
        let digest = String(repeating: "9", count: 64)
        let service = DataResetPreparationService(
            store: original,
            manifestProvider:
                ResetManifestProviderFixture(
                    manifest: DataInventoryManifest(
                        generationID:
                            original.generationID,
                        datasetID:
                            metadata.datasetID,
                        nextLocalRevision:
                            metadata.nextLocalRevision,
                        capturedAt: Date(),
                        completeness: .complete,
                        categories: try notificationCategories(
                            pending: [],
                            delivered: []
                        ),
                        unmanagedBoundaries: [],
                        stateDigest: digest,
                        manifestDigest: String(
                            repeating: "8",
                            count: 64
                        )
                    )
                ),
            coordinator: coordinator,
            notificationClient: notificationClient
        )
        let prepared = try await service.prepare(
            confirmedStateDigest: digest
        )

        await gate.release()
        do {
            _ = try await oldTask.value
            XCTFail("old task must not enter reset session")
        } catch {
            XCTAssertEqual(
                error as? AppDataControlCoordinatorFailure,
                .invalidated
            )
        }
        _ = try await DataResetCurrentProcessWorker()
            .advanceToRestartRequired(prepared)
    }

    func testResetPreparationRejectsChangedStateWithoutJournal()
        async throws {
        let layout = try makeLayout()
        let original = try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        let context = ModelContext(original.container)
        let metadata = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        )
        let coordinator = AppDataControlCoordinator(
            generationID: original.generationID
        )
        let service = DataResetPreparationService(
            store: original,
            manifestProvider:
                ResetManifestProviderFixture(
                    manifest: DataInventoryManifest(
                        generationID:
                            original.generationID,
                        datasetID:
                            metadata.datasetID,
                        nextLocalRevision:
                            metadata.nextLocalRevision,
                        capturedAt: Date(),
                        completeness: .complete,
                        categories: [],
                        unmanagedBoundaries: [],
                        stateDigest: String(
                            repeating: "c",
                            count: 64
                        ),
                        manifestDigest: String(
                            repeating: "d",
                            count: 64
                        )
                    )
                ),
            coordinator: coordinator,
            notificationClient:
                ResetNotificationClientFixture()
        )

        do {
            _ = try await service.prepare(
                confirmedStateDigest: String(
                    repeating: "e",
                    count: 64
                )
            )
            XCTFail("changed state must fail")
        } catch {
            XCTAssertEqual(
                error as? DataResetServiceFailure,
                .impactChanged
            )
        }
        let resetLayout = DataResetPathLayout(
            applicationSupportURL:
                layout.rootURL.deletingLastPathComponent(),
            storeLayout: layout
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: resetLayout.journalURL.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.rootURL.path
            )
        )
    }

    func testResetPreparationRejectsNotificationManifestDrift()
        async throws {
        let layout = try makeLayout()
        let original = try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        let context = ModelContext(original.container)
        let metadata = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        )
        let digest = String(repeating: "f", count: 64)
        let manifest = DataInventoryManifest(
            generationID: original.generationID,
            datasetID: metadata.datasetID,
            nextLocalRevision: metadata.nextLocalRevision,
            capturedAt: Date(),
            completeness: .complete,
            categories: try notificationCategories(
                pending: [],
                delivered: []
            ),
            unmanagedBoundaries: [],
            stateDigest: digest,
            manifestDigest: String(
                repeating: "0",
                count: 64
            )
        )
        let service = DataResetPreparationService(
            store: original,
            manifestProvider:
                ResetManifestProviderFixture(
                    manifest: manifest
                ),
            coordinator: AppDataControlCoordinator(
                generationID: original.generationID
            ),
            notificationClient:
                ResetNotificationClientFixture(
                    pending: [
                        "unmanual.exec.v1.changed"
                    ]
                )
        )

        do {
            _ = try await service.prepare(
                confirmedStateDigest: digest
            )
            XCTFail(
                "notification drift must fail before journal creation"
            )
        } catch {
            XCTAssertEqual(
                error as? DataResetServiceFailure,
                .notificationManifestMismatch
            )
        }
        let resetLayout = DataResetPathLayout(
            applicationSupportURL:
                layout.rootURL.deletingLastPathComponent(),
            storeLayout: layout
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: resetLayout.journalURL.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.rootURL.path
            )
        )
    }

    func testResetPreparationTimesOutWithoutJournalOrDeletion()
        async throws {
        let layout = try makeLayout()
        let original = try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        let coordinator = AppDataControlCoordinator(
            generationID: original.generationID
        )
        let retainedLease = try await coordinator
            .beginAttachmentPreviewLease()
        let context = ModelContext(original.container)
        let metadata = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        )
        let digest = String(repeating: "1", count: 64)
        let service = DataResetPreparationService(
            store: original,
            manifestProvider:
                ResetManifestProviderFixture(
                    manifest: DataInventoryManifest(
                        generationID:
                            original.generationID,
                        datasetID: metadata.datasetID,
                        nextLocalRevision:
                            metadata.nextLocalRevision,
                        capturedAt: Date(),
                        completeness: .complete,
                        categories:
                            try notificationCategories(
                                pending: [],
                                delivered: []
                            ),
                        unmanagedBoundaries: [],
                        stateDigest: digest,
                        manifestDigest: String(
                            repeating: "2",
                            count: 64
                        )
                    )
                ),
            coordinator: coordinator,
            notificationClient:
                ResetNotificationClientFixture(),
            resetDrainTimeout: .milliseconds(25)
        )

        do {
            _ = try await service.prepare(
                confirmedStateDigest: digest
            )
            XCTFail("undrained lease must time out")
        } catch {
            XCTAssertEqual(
                error as? DataResetServiceFailure,
                .quiesceTimedOut
            )
        }
        await coordinator.endAttachmentPreviewLease(
            retainedLease
        )
        let resetLayout = DataResetPathLayout(
            applicationSupportURL:
                layout.rootURL.deletingLastPathComponent(),
            storeLayout: layout
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: resetLayout.journalURL.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.rootURL.path
            )
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
        var supportValues = URLResourceValues()
        supportValues.isExcludedFromBackup = false
        var mutableSupport = applicationSupport
        try mutableSupport.setResourceValues(
            supportValues
        )
        let root = applicationSupport.appending(
            path: "UnmanualDataResetServiceTests-"
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
            legacyStoreURL: root.appending(path: "default.store")
        )
    }

    private func prepareReset(
        layout: AppDataStoreLayout,
        notificationClient: ResetNotificationClientFixture,
        manifestSeed: Int,
        fileSystem:
            any DataResetFileSystem =
                DataResetFoundationFileSystem()
    ) async throws -> DataResetPreparedOperation {
        let original = try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()
        let context = ModelContext(original.container)
        let metadata = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        )
        let nibble = String(manifestSeed % 16, radix: 16)
        let manifest = DataInventoryManifest(
            generationID: original.generationID,
            datasetID: metadata.datasetID,
            nextLocalRevision: metadata.nextLocalRevision,
            capturedAt: Date(
                timeIntervalSince1970:
                    1_800_400_000
                        + TimeInterval(manifestSeed)
            ),
            completeness: .complete,
            categories: try notificationCategories(
                pending: await notificationClient
                    .ownedPendingIdentifiers(),
                delivered: await notificationClient
                    .ownedDeliveredIdentifiers()
            ),
            unmanagedBoundaries: [],
            stateDigest: String(repeating: nibble, count: 64),
            manifestDigest: String(
                repeating: nibble == "f" ? "e" : "f",
                count: 64
            )
        )
        return try await DataResetPreparationService(
            store: original,
            manifestProvider:
                ResetManifestProviderFixture(
                    manifest: manifest
                ),
            coordinator: AppDataControlCoordinator(
                generationID: original.generationID
            ),
            notificationClient: notificationClient,
            fileSystem: fileSystem
        ).prepare(
            confirmedStateDigest: manifest.stateDigest
        )
    }

    private func assertCompletedReset(
        _ reopened: BootstrappedAppDataStore,
        prepared: DataResetPreparedOperation,
        notificationClient: ResetNotificationClientFixture
    ) async throws {
        XCTAssertEqual(
            reopened.generationID,
            prepared.journal.freshGenerationID
        )
        let metadata = try XCTUnwrap(
            ModelContext(reopened.container).fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        )
        XCTAssertEqual(
            metadata.datasetID,
            prepared.journal.freshDatasetID
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prepared.store.layout.journalURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    prepared.store.layout.controlDirectoryURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prepared.store.layout
                    .quarantineRootURL(
                        operationID:
                            prepared.journal.operationID
                    ).path
            )
        )
        let remaining = await notificationClient.snapshot()
        XCTAssertEqual(
            remaining.pending,
            remaining.pending.filter {
                !$0.hasPrefix("unmanual.")
            }
        )
        XCTAssertEqual(
            remaining.delivered,
            remaining.delivered.filter {
                !$0.hasPrefix("unmanual.")
            }
        )
    }

    private func notificationCategories(
        pending: [String],
        delivered: [String]
    ) throws -> [DataInventoryCategory] {
        try DataInventoryManifestBuilder
            .notificationCategories(
                observations:
                    pending.map {
                        DataInventoryNotificationRequestObservation(
                            identifier: $0,
                            deliveryState: .pending
                        )
                    }
                    + delivered.map {
                        DataInventoryNotificationRequestObservation(
                            identifier: $0,
                            deliveryState: .delivered
                        )
                    }
            )
    }
}

private struct ResetManifestProviderFixture:
    DataControlManifestProvider {
    let manifestValue: DataInventoryManifest

    init(manifest: DataInventoryManifest) {
        manifestValue = manifest
    }

    func manifest() async throws
        -> DataInventoryManifest {
        manifestValue
    }
}

private actor ResetNotificationClientFixture:
    DataResetNotificationClient {
    private var pending: [String]
    private var delivered: [String]

    init(
        pending: [String] = [],
        delivered: [String] = []
    ) {
        self.pending = pending
        self.delivered = delivered
    }

    func pendingIdentifiers() async throws -> [String] {
        pending
    }

    func deliveredIdentifiers() async throws -> [String] {
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

    func ownedPendingIdentifiers() -> [String] {
        pending.filter { $0.hasPrefix("unmanual.") }
    }

    func ownedDeliveredIdentifiers() -> [String] {
        delivered.filter { $0.hasPrefix("unmanual.") }
    }
}

private actor ResetOldTaskGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation {
            waiters.append($0)
        }
    }

    func release() {
        isReleased = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private struct ResetInjectedObservationFailure: Error {}

private actor ResetOneShotFailingNotificationClient:
    DataResetNotificationClient {
    private let base: ResetNotificationClientFixture
    private var hasFailed = false

    init(base: ResetNotificationClientFixture) {
        self.base = base
    }

    func pendingIdentifiers() async throws -> [String] {
        if !hasFailed {
            hasFailed = true
            throw ResetInjectedObservationFailure()
        }
        return try await base.pendingIdentifiers()
    }

    func deliveredIdentifiers() async throws -> [String] {
        try await base.deliveredIdentifiers()
    }

    func removePendingIdentifiers(
        _ identifiers: [String]
    ) async throws {
        try await base.removePendingIdentifiers(identifiers)
    }

    func removeDeliveredIdentifiers(
        _ identifiers: [String]
    ) async throws {
        try await base.removeDeliveredIdentifiers(identifiers)
    }
}

private final class ColdLaunchFaultInjectingDataResetFileSystem:
    DataResetFileSystem,
    @unchecked Sendable {
    private struct InjectedDiskFull: Error {}
    private struct InjectedRemoveFailure: Error {}

    private let base: any DataResetFileSystem
    private let failingWrite: Int?
    private let failingRemove: Int?
    private let lock = NSLock()
    private var writeCount = 0
    private var removeCount = 0

    init(
        base: any DataResetFileSystem,
        failingWrite: Int? = nil,
        failingRemove: Int? = nil
    ) {
        self.base = base
        self.failingWrite = failingWrite
        self.failingRemove = failingRemove
    }

    func kind(at url: URL) throws -> DataResetItemKind {
        try base.kind(at: url)
    }

    func children(of url: URL) throws -> [URL] {
        try base.children(of: url)
    }

    func createDirectory(at url: URL) throws {
        try base.createDirectory(at: url)
    }

    func moveItem(at sourceURL: URL, to targetURL: URL) throws {
        try base.moveItem(at: sourceURL, to: targetURL)
    }

    func removeItem(at url: URL) throws {
        lock.lock()
        removeCount += 1
        let shouldFail = removeCount == failingRemove
        lock.unlock()
        if shouldFail {
            throw InjectedRemoveFailure()
        }
        try base.removeItem(at: url)
    }

    func readData(at url: URL) throws -> Data {
        try base.readData(at: url)
    }

    func writeProtectedAtomicData(
        _ data: Data,
        to url: URL
    ) throws {
        lock.lock()
        writeCount += 1
        let shouldFail = writeCount == failingWrite
        lock.unlock()
        if shouldFail {
            throw InjectedDiskFull()
        }
        try base.writeProtectedAtomicData(data, to: url)
    }

    func verifyProtectedSystemManagedFile(at url: URL) throws {
        try base.verifyProtectedSystemManagedFile(at: url)
    }

    func verifyProtectedSystemManagedDirectory(
        at url: URL
    ) throws {
        try base.verifyProtectedSystemManagedDirectory(at: url)
    }
}

private final class InitialJournalDiskFullDataResetFileSystem:
    DataResetFileSystem,
    @unchecked Sendable {
    private struct InjectedDiskFull: Error {}

    private let base: any DataResetFileSystem
    private let lock = NSLock()
    private var hasFailed = false

    init(base: any DataResetFileSystem) {
        self.base = base
    }

    func kind(at url: URL) throws -> DataResetItemKind {
        try base.kind(at: url)
    }

    func children(of url: URL) throws -> [URL] {
        try base.children(of: url)
    }

    func createDirectory(at url: URL) throws {
        try base.createDirectory(at: url)
    }

    func moveItem(at sourceURL: URL, to targetURL: URL) throws {
        try base.moveItem(at: sourceURL, to: targetURL)
    }

    func removeItem(at url: URL) throws {
        try base.removeItem(at: url)
    }

    func readData(at url: URL) throws -> Data {
        try base.readData(at: url)
    }

    func writeProtectedAtomicData(
        _ data: Data,
        to url: URL
    ) throws {
        lock.lock()
        let shouldFail = !hasFailed
        hasFailed = true
        lock.unlock()
        if shouldFail {
            let parent = url.deletingLastPathComponent()
            if try base.kind(at: parent) == .missing {
                try base.createDirectory(at: parent)
            }
            throw InjectedDiskFull()
        }
        try base.writeProtectedAtomicData(data, to: url)
    }

    func verifyProtectedSystemManagedFile(at url: URL) throws {
        try base.verifyProtectedSystemManagedFile(at: url)
    }

    func verifyProtectedSystemManagedDirectory(
        at url: URL
    ) throws {
        try base.verifyProtectedSystemManagedDirectory(at: url)
    }
}
