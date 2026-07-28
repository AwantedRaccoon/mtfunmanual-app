import CryptoKit
import Foundation
import SwiftData
import XCTest
@testable import Unmanual

final class DataInventoryProductionServiceTests: XCTestCase {
    func testV12DatabaseCaptureUsesExact54ModelPartition()
        async throws {
        let container = try makeReadyV12Container()
        let actor = DataInventoryDatabaseCaptureActor(
            modelContainer: container
        )
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "InventoryDB-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let capture = try await actor.capture(
            layout: AppDataStoreLayout(
                rootURL: root.appending(
                    path: "Unmanual",
                    directoryHint: .isDirectory
                ),
                legacyStoreURL: root.appending(path: "legacy.sqlite")
            )
        )
        let counts = capture.categorySnapshots.compactMap {
            snapshot -> [String: Int64]? in
            guard case let .database(database) = snapshot.payload else {
                return nil
            }
            return database.modelRowCounts
        }
        .reduce(into: [String: Int64]()) {
            for pair in $1 {
                XCTAssertNil($0.updateValue(pair.value, forKey: pair.key))
            }
        }
        XCTAssertEqual(counts.count, 54)
        XCTAssertEqual(
            Set(counts.keys),
            Set(DataInventoryTaxonomy.allDatabaseModelNames)
        )
        XCTAssertEqual(
            capture.factCount,
            capture.revisionCount
        )
        XCTAssertGreaterThan(capture.nextLocalRevision, 0)
    }

    func testV12DatabaseCaptureRejectsRevisionDigestTamper()
        async throws {
        let container = try makeReadyV12Container()
        let context = ModelContext(container)
        let revision = try XCTUnwrap(
            context.fetch(FetchDescriptor<RecordRevision>()).first
        )
        revision.digestHex = String(repeating: "0", count: 64)
        try context.save()
        let actor = DataInventoryDatabaseCaptureActor(
            modelContainer: container
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        do {
            _ = try await actor.capture(
                layout: AppDataStoreLayout(
                    rootURL: root.appending(path: "Unmanual"),
                    legacyStoreURL: root.appending(
                        path: "legacy.sqlite"
                    )
                )
            )
            XCTFail("tampered revision must fail closed")
        } catch {
            XCTAssertEqual(
                error as? AppDataFailure,
                .corruptionSuspected
            )
        }
    }

    func testBoundedFetchContractRejectsDriftAndOverLimit() {
        XCTAssertNoThrow(
            try DataInventoryBoundedFetchContract.validate(
                preflightCount: 4,
                fetchedCount: 4
            )
        )
        XCTAssertThrowsError(
            try DataInventoryBoundedFetchContract.validate(
                preflightCount: 4,
                fetchedCount: 3
            )
        )
        XCTAssertThrowsError(
            try DataInventoryBoundedFetchContract.validate(
                preflightCount:
                    DataInventoryTaxonomy.maximumRowsPerModel + 1,
                fetchedCount:
                    DataInventoryTaxonomy.maximumRowsPerModel + 1
            )
        )
    }

    func testAttachmentInventoryAcceptsExactEmptyTree() throws {
        try withAttachmentStore { store, _ in
            let snapshots = try store
                .dataInventoryCategorySnapshots(observations: [])
            XCTAssertEqual(snapshots.count, 4)
            XCTAssertTrue(
                snapshots.allSatisfy {
                    guard case let .regularFiles(files) = $0.payload else {
                        return false
                    }
                    return files.isEmpty
                }
            )
        }
    }

    func testAttachmentInventoryRejectsReplacementAndUnknownLeaf()
        throws {
        try withAttachmentStore { store, root in
            let id = UUID()
            let operationID = UUID()
            let relativePath = try XCTUnwrap(
                AttachmentPathFacts.relativePath(
                    attachmentID: id,
                    typeIdentifier: "public.png"
                )
            )
            let payloadURL = root.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: payloadURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("replacement".utf8).write(to: payloadURL)
            let expected = Data("expected".utf8)
            let observation = DataInventoryAttachmentObservation(
                operationID: operationID,
                attachment: AttachmentSnapshot(
                    id: id,
                    ownerType: .labSample,
                    ownerID: UUID(),
                    relativePath: relativePath,
                    originalFilename: "result.png",
                    typeIdentifier: "public.png",
                    byteCount: Int64(expected.count),
                    sha256Hex: sha256(expected),
                    createdAt: Date()
                ),
                deletedAt: nil,
                deleteOperationID: nil
            )
            XCTAssertThrowsError(
                try store.dataInventoryCategorySnapshots(
                    observations: [observation]
                )
            )
            try FileManager.default.removeItem(
                at: payloadURL.deletingLastPathComponent()
            )
            try Data("unknown".utf8).write(
                to: root.appending(path: "Attachments/unknown.bin")
            )
            XCTAssertThrowsError(
                try store.dataInventoryCategorySnapshots(
                    observations: []
                )
            )
        }
    }

    func testAttachmentInventoryRejectsMalformedJournal() throws {
        try withAttachmentStore { store, root in
            let journal = root
                .appending(path: ".staging")
                .appending(path: UUID().uuidString.lowercased() + ".json")
            try Data("{\"formatVersion\":999}".utf8).write(to: journal)
            XCTAssertThrowsError(
                try store.dataInventoryCategorySnapshots(
                    observations: []
                )
            )
        }
    }

    func testIncompleteManifestDisablesDestructiveActions() throws {
        let snapshots = DataInventoryTaxonomy.categorySpecifications.map {
            DataInventoryCategorySnapshot.failed(
                key: $0.key,
                kind: $0.kind
            )
        }
        let manifest = try DataInventoryManifestBuilder.makeManifest(
            generationID: UUID(),
            datasetID: UUID(),
            nextLocalRevision: 1,
            capturedAt: Date(timeIntervalSince1970: 1_800_200_000),
            snapshots: snapshots
        )
        XCTAssertEqual(manifest.completeness, .incomplete)
        XCTAssertFalse(manifest.destructiveActionsEnabled)
    }

    func testNotificationCaptureIgnoresForeignAndFailsAllFour()
        throws {
        let ownedExecution =
            DataInventoryNotificationNamespace.execution
            .identifierPrefix + "owned"
        let ownedCountdown =
            DataInventoryNotificationNamespace.countdown
            .identifierPrefix + "owned"
        let success = DataInventoryNotificationCategoryCapture
            .snapshots(
                .success([
                    .init(
                        identifier: ownedExecution,
                        deliveryState: .pending
                    ),
                    .init(
                        identifier: ownedCountdown,
                        deliveryState: .delivered
                    ),
                    .init(
                        identifier: "foreign.notification",
                        deliveryState: .pending
                    )
                ])
            )
        XCTAssertEqual(success.count, 4)
        let observations = success.flatMap {
            snapshot -> [DataInventoryNotificationSnapshot] in
            guard case let .notifications(values) = snapshot.payload else {
                return []
            }
            return values
        }
        XCTAssertEqual(
            Set(observations.map(\.identifier)),
            Set([ownedExecution, ownedCountdown])
        )

        let failed = DataInventoryNotificationCategoryCapture
            .snapshots(
                .failure(AppDataFailure.storageUnavailable)
            )
        XCTAssertEqual(failed.count, 4)
        XCTAssertTrue(
            failed.allSatisfy {
                if case .failed = $0.payload { return true }
                return false
            }
        )
    }

    func testStableNotificationObservationRejectsTransitionAndOverlap()
        throws {
        XCTAssertThrowsError(
            try DataInventoryStableNotificationObservation.make(
                firstPending: ["owned"],
                firstDelivered: [],
                secondPending: [],
                secondDelivered: ["owned"]
            )
        )
        XCTAssertThrowsError(
            try DataInventoryStableNotificationObservation.make(
                firstPending: ["owned"],
                firstDelivered: ["owned"],
                secondPending: ["owned"],
                secondDelivered: ["owned"]
            )
        )
        XCTAssertThrowsError(
            try DataInventoryStableNotificationObservation.make(
                firstPending: ["owned", "owned"],
                firstDelivered: [],
                secondPending: ["owned", "owned"],
                secondDelivered: []
            )
        )
    }

    func testStableNotificationObservationAcceptsStableUnorderedSets()
        throws {
        let observations = try DataInventoryStableNotificationObservation
            .make(
                firstPending: ["pending-b", "pending-a"],
                firstDelivered: ["delivered-b", "delivered-a"],
                secondPending: ["pending-a", "pending-b"],
                secondDelivered: ["delivered-a", "delivered-b"]
            )
        XCTAssertEqual(
            observations.map(\.identifier),
            [
                "pending-a", "pending-b",
                "delivered-a", "delivered-b"
            ]
        )
    }

    func testStorageCaptureClassifiesActiveUnprovenAndLegacy()
        async throws {
        let container = try makeReadyV12Container()
        let actor = DataInventoryDatabaseCaptureActor(
            modelContainer: container
        )
        try await withStorageFixture(
            databaseActor: actor,
            includeInactive: true,
            includeLegacy: true
        ) { fixture, database in
            let capture = try DataInventoryProductionStorageAudit
                .capture(
                    layout: fixture.layout,
                    generationID: fixture.generationID,
                    database: database
                )
            let byKey = Dictionary(
                uniqueKeysWithValues:
                    capture.categorySnapshots.map { ($0.key, $0) }
            )
            XCTAssertEqual(
                generationCount(
                    byKey["storage.generation.active"]
                ),
                1
            )
            XCTAssertEqual(
                generationCount(
                    byKey["storage.generation.unproven"]
                ),
                1
            )
            guard case let .regularFiles(legacyFiles) =
                    byKey["storage.legacy"]?.payload else {
                return XCTFail("missing typed legacy category")
            }
            XCTAssertEqual(legacyFiles.count, 1)
        }
    }

    func testStorageCaptureMarksInvalidGenerationFailed()
        async throws {
        let container = try makeReadyV12Container()
        let actor = DataInventoryDatabaseCaptureActor(
            modelContainer: container
        )
        try await withStorageFixture(
            databaseActor: actor
        ) { fixture, database in
            try Data("invalid".utf8).write(
                to: fixture.layout.generationsURL
                    .appending(path: "not-a-generation")
            )
            let capture = try DataInventoryProductionStorageAudit
                .capture(
                    layout: fixture.layout,
                    generationID: fixture.generationID,
                    database: database
                )
            let invalid = try XCTUnwrap(
                capture.categorySnapshots.first {
                    $0.key == "storage.generation.invalid"
                }
            )
            if case .failed = invalid.payload {
                XCTAssertTrue(true)
            } else {
                XCTFail("invalid direct child must fail closed")
            }
        }
    }

    func testStorageCaptureAcceptsCurrentCountsAbovePointerMinimum()
        async throws {
        let container = try makeReadyV12Container()
        let actor = DataInventoryDatabaseCaptureActor(
            modelContainer: container
        )
        try await withStorageFixture(
            databaseActor: actor
        ) { fixture, database in
            XCTAssertGreaterThan(database.factCount, 0)
            try writePointer(
                layout: fixture.layout,
                generationID: fixture.generationID,
                origin: .newInstall,
                datasetID: database.datasetID,
                minimumCount: database.factCount - 1
            )
            let capture = try DataInventoryProductionStorageAudit
                .capture(
                    layout: fixture.layout,
                    generationID: fixture.generationID,
                    database: database
                )
            XCTAssertEqual(
                generationCount(
                    capture.categorySnapshots.first {
                        $0.key == "storage.generation.active"
                    }
                ),
                1
            )
        }
    }

    func testStorageCaptureRejectsInactiveNestedUnknownLeaf()
        async throws {
        let container = try makeReadyV12Container()
        let actor = DataInventoryDatabaseCaptureActor(
            modelContainer: container
        )
        try await withStorageFixture(
            databaseActor: actor,
            includeInactive: true
        ) { fixture, database in
            let inactiveID = try XCTUnwrap(
                fixture.inactiveGenerationID
            )
            let unknown = fixture.layout
                .generationDirectoryURL(for: inactiveID)
                .appending(path: "Files/Attachments/not-a-uuid")
            try FileManager.default.createDirectory(
                at: unknown,
                withIntermediateDirectories: true
            )
            try Data("unknown".utf8).write(
                to: unknown.appending(path: "garbage.bin")
            )
            try markSystemManagedTree(
                fixture.layout.rootURL.deletingLastPathComponent()
            )
            let capture = try DataInventoryProductionStorageAudit
                .capture(
                    layout: fixture.layout,
                    generationID: fixture.generationID,
                    database: database
                )
            assertInvalidGenerationFailed(capture)
        }
    }

    func testStorageCaptureRejectsCrossGenerationHardlink()
        async throws {
        let container = try makeReadyV12Container()
        let actor = DataInventoryDatabaseCaptureActor(
            modelContainer: container
        )
        try await withStorageFixture(
            databaseActor: actor,
            includeInactive: true
        ) { fixture, database in
            let inactiveID = try XCTUnwrap(
                fixture.inactiveGenerationID
            )
            let activeStore = fixture.layout.storeURL(
                for: fixture.generationID
            )
            let inactiveStore = fixture.layout.storeURL(
                for: inactiveID
            )
            try FileManager.default.removeItem(at: inactiveStore)
            try FileManager.default.linkItem(
                at: activeStore,
                to: inactiveStore
            )
            let capture = try DataInventoryProductionStorageAudit
                .capture(
                    layout: fixture.layout,
                    generationID: fixture.generationID,
                    database: database
                )
            assertInvalidGenerationFailed(capture)
        }
    }

    func testGlobalFileIdentityAuditRejectsLegacyHardlinkToManagedFile()
        async throws {
        let container = try makeReadyV12Container()
        let actor = DataInventoryDatabaseCaptureActor(
            modelContainer: container
        )
        try await withStorageFixture(
            databaseActor: actor
        ) { fixture, _ in
            try FileManager.default.linkItem(
                at: fixture.layout.pointerURL,
                to: fixture.layout.legacyStoreURL
            )
            XCTAssertThrowsError(
                try DataInventoryGlobalFileIdentityAudit.validate(
                    layout: fixture.layout
                )
            ) { error in
                guard case DataInventoryFileAuditError
                    .duplicatePathOrInode = error else {
                    return XCTFail(
                        "unexpected global identity error: \(error)"
                    )
                }
            }
        }
    }

    func testStorageCaptureRejectsDanglingOptionalControlSymlinks()
        async throws {
        for relativePath in [
            "Unmanual/Recovery/migration-journal.json",
            "UnmanualResetControl"
        ] {
            let container = try makeReadyV12Container()
            let actor = DataInventoryDatabaseCaptureActor(
                modelContainer: container
            )
            try await withStorageFixture(
                databaseActor: actor
            ) { fixture, database in
                let applicationSupport =
                    fixture.layout.rootURL.deletingLastPathComponent()
                let link = applicationSupport.appending(
                    path: relativePath
                )
                try FileManager.default.createDirectory(
                    at: link.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.createSymbolicLink(
                    atPath: link.path,
                    withDestinationPath:
                        applicationSupport
                        .appending(path: "missing-target").path
                )
                XCTAssertThrowsError(
                    try DataInventoryProductionStorageAudit.capture(
                        layout: fixture.layout,
                        generationID: fixture.generationID,
                        database: database
                    )
                )
            }
        }
    }

    func testStorageCaptureRejectsJournalTargetSchemaMismatch()
        async throws {
        let container = try makeReadyV12Container()
        let actor = DataInventoryDatabaseCaptureActor(
            modelContainer: container
        )
        try await withStorageFixture(
            databaseActor: actor,
            includeInactive: true
        ) { fixture, database in
            let sourceID = try XCTUnwrap(
                fixture.inactiveGenerationID
            )
            try writePointer(
                layout: fixture.layout,
                generationID: fixture.generationID,
                origin: .schemaUpgrade,
                datasetID: database.datasetID,
                minimumCount: database.factCount
            )
            try writeMigrationJournal(
                layout: fixture.layout,
                sourceID: sourceID,
                targetID: fixture.generationID,
                targetSchemaVersion: "11.0.0"
            )
            XCTAssertThrowsError(
                try DataInventoryProductionStorageAudit.capture(
                    layout: fixture.layout,
                    generationID: fixture.generationID,
                    database: database
                )
            )
        }
    }

    func testStorageCaptureDoesNotProveGarbageJournalSource()
        async throws {
        let container = try makeReadyV12Container()
        let actor = DataInventoryDatabaseCaptureActor(
            modelContainer: container
        )
        try await withStorageFixture(
            databaseActor: actor,
            includeInactive: true
        ) { fixture, database in
            let sourceID = try XCTUnwrap(
                fixture.inactiveGenerationID
            )
            try writePointer(
                layout: fixture.layout,
                generationID: fixture.generationID,
                origin: .schemaUpgrade,
                datasetID: database.datasetID,
                minimumCount: database.factCount
            )
            try writeMigrationJournal(
                layout: fixture.layout,
                sourceID: sourceID,
                targetID: fixture.generationID,
                targetSchemaVersion: "12.0.0"
            )
            let capture = try DataInventoryProductionStorageAudit
                .capture(
                    layout: fixture.layout,
                    generationID: fixture.generationID,
                    database: database
                )
            XCTAssertEqual(
                generationCount(
                    capture.categorySnapshots.first {
                        $0.key
                            == "storage.generation.inactive-proven"
                    }
                ),
                0
            )
            assertInvalidGenerationFailed(capture)
        }
    }

    func testGenerationProvenanceRejectsDatasetMismatch()
        throws {
        let applicationSupport =
            FileManager.default.temporaryDirectory
            .appending(
                path: "InventoryProvenance-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer {
            try? FileManager.default.removeItem(at: applicationSupport)
        }
        let layout = AppDataStoreLayout(
            rootURL: applicationSupport.appending(
                path: "Unmanual",
                directoryHint: .isDirectory
            ),
            legacyStoreURL: applicationSupport.appending(
                path: "legacy.sqlite"
            )
        )
        let generationID = UUID()
        let storeURL = layout.storeURL(for: generationID)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let datasetID: UUID = try autoreleasepool {
            let container = try AppModelContainerFactory
                .makeDataControlContainer(at: storeURL)
            try seedReadyV12(container)
            let metadata = try ModelContext(container).fetch(
                FetchDescriptor<DatasetMetadata>()
            )
            return try XCTUnwrap(metadata.first).datasetID
        }
        let bootstrapper = AppDataStoreBootstrapper(layout: layout)
        XCTAssertEqual(
            try bootstrapper.validateGenerationForDataInventory(
                generationID: generationID,
                schemaVersion: "12.0.0",
                expectedDatasetID: datasetID
            ).datasetID,
            datasetID
        )
        XCTAssertThrowsError(
            try bootstrapper.validateGenerationForDataInventory(
                generationID: generationID,
                schemaVersion: "12.0.0",
                expectedDatasetID: UUID()
            )
        )
    }

    func testStorageCaptureRejectsResetControlAndQuarantine()
        async throws {
        for mutation in [0, 1] {
            let container = try makeReadyV12Container()
            let actor = DataInventoryDatabaseCaptureActor(
                modelContainer: container
            )
            try await withStorageFixture(
                databaseActor: actor
            ) { fixture, database in
                let applicationSupport =
                    fixture.layout.rootURL.deletingLastPathComponent()
                if mutation == 0 {
                    let reset = applicationSupport
                        .appending(
                            path: "UnmanualResetControl",
                            directoryHint: .isDirectory
                        )
                    try FileManager.default.createDirectory(
                        at: reset,
                        withIntermediateDirectories: true
                    )
                    try Data("{}".utf8).write(
                        to: reset.appending(
                            path: "reset-journal.json"
                        )
                    )
                } else {
                    try FileManager.default.createDirectory(
                        at: applicationSupport.appending(
                            path:
                                "Unmanual.reset-"
                                + UUID().uuidString.lowercased(),
                            directoryHint: .isDirectory
                        ),
                        withIntermediateDirectories: true
                    )
                }
                XCTAssertThrowsError(
                    try DataInventoryProductionStorageAudit.capture(
                        layout: fixture.layout,
                        generationID: fixture.generationID,
                        database: database
                    )
                )
            }
        }
    }

    func testProductionServiceCompleteThenInvalidGenerationIncomplete()
        async throws {
        let container = try makeReadyV12Container()
        let actor = DataInventoryDatabaseCaptureActor(
            modelContainer: container
        )
        try await withStorageFixture(
            databaseActor: actor
        ) { fixture, _ in
            let store = BootstrappedAppDataStore(
                container: container,
                generationID: fixture.generationID,
                storeURL: fixture.layout.storeURL(
                    for: fixture.generationID
                ),
                origin: .newInstall,
                protectionReport: StoreFileProtectionReport(
                    entries: [],
                    requiresPhysicalDeviceValidation: true
                ),
                attachmentRootURL: fixture.layout
                    .generationDirectoryURL(
                        for: fixture.generationID
                    )
                    .appending(
                        path: "Files",
                        directoryHint: .isDirectory
                    ),
                layout: fixture.layout
            )
            let service = try XCTUnwrap(
                DataInventoryProductionService(
                    store: store,
                    dataControlCoordinator:
                        AppDataControlCoordinator(
                            generationID: fixture.generationID
                        )
                )
            )
            let complete = try await service.manifest()
            XCTAssertEqual(complete.completeness, .complete)
            XCTAssertTrue(complete.destructiveActionsEnabled)

            try Data("invalid".utf8).write(
                to: fixture.layout.generationsURL
                    .appending(path: "unknown")
            )
            let incomplete = try await service.manifest()
            XCTAssertEqual(incomplete.completeness, .incomplete)
            XCTAssertFalse(incomplete.destructiveActionsEnabled)
        }
    }

    private func makeReadyV12Container() throws -> ModelContainer {
        let container = try AppModelContainerFactory
            .makeInMemoryDataControlContainer()
        try seedReadyV12(container)
        return container
    }

    private func seedReadyV12(
        _ container: ModelContainer
    ) throws {
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
    }

    private func withAttachmentStore(
        _ body: (AttachmentFileStore, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "InventoryFiles-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [
            root,
            root.appending(
                path: "Attachments",
                directoryHint: .isDirectory
            ),
            root.appending(
                path: ".staging",
                directoryHint: .isDirectory
            ),
            root.appending(
                path: ".trash",
                directoryHint: .isDirectory
            )
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try body(AttachmentFileStore(rootURL: root), root)
    }

    private struct StorageFixture {
        let layout: AppDataStoreLayout
        let generationID: UUID
        let inactiveGenerationID: UUID?
    }

    private func withStorageFixture(
        databaseActor: DataInventoryDatabaseCaptureActor,
        includeInactive: Bool = false,
        includeLegacy: Bool = false,
        _ body: (StorageFixture, DataInventoryDatabaseCapture)
            async throws -> Void
    ) async throws {
        let applicationSupport =
            FileManager.default.temporaryDirectory
            .appending(
                path: "InventoryStorage-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer {
            try? FileManager.default.removeItem(
                at: applicationSupport
            )
        }
        let layout = AppDataStoreLayout(
            rootURL: applicationSupport.appending(
                path: "Unmanual",
                directoryHint: .isDirectory
            ),
            legacyStoreURL: applicationSupport.appending(
                path: "legacy.sqlite"
            )
        )
        let database = try await databaseActor.capture(layout: layout)
        let generationID = UUID()
        try createGeneration(
            layout: layout,
            generationID: generationID
        )
        let inactiveGenerationID: UUID?
        if includeInactive {
            let value = UUID()
            try createGeneration(
                layout: layout,
                generationID: value
            )
            inactiveGenerationID = value
        } else {
            inactiveGenerationID = nil
        }
        try FileManager.default.createDirectory(
            at: layout.pointerDirectoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: layout.recoveryURL,
            withIntermediateDirectories: true
        )
        let pointer = GenerationPointer(
            generationID: generationID,
            schemaVersion: "12.0.0",
            origin: .newInstall,
            datasetID: database.datasetID,
            minimumFactCount: database.factCount,
            minimumRevisionCount: database.revisionCount,
            activatedAt: Date(
                timeIntervalSince1970: 1_800_200_100
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(pointer).write(to: layout.pointerURL)
        if includeLegacy {
            try Data("legacy".utf8).write(
                to: layout.legacyStoreURL
            )
        }
        try markSystemManagedTree(applicationSupport)
        try await body(
            StorageFixture(
                layout: layout,
                generationID: generationID,
                inactiveGenerationID: inactiveGenerationID
            ),
            database
        )
    }

    private func createGeneration(
        layout: AppDataStoreLayout,
        generationID: UUID
    ) throws {
        let generation = layout.generationDirectoryURL(
            for: generationID
        )
        let store = generation.appending(
            path: "Store",
            directoryHint: .isDirectory
        )
        let files = generation.appending(
            path: "Files",
            directoryHint: .isDirectory
        )
        for directory in [
            store,
            files.appending(
                path: "Attachments",
                directoryHint: .isDirectory
            ),
            files.appending(
                path: ".staging",
                directoryHint: .isDirectory
            ),
            files.appending(
                path: ".trash",
                directoryHint: .isDirectory
            )
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try Data("sqlite".utf8).write(
            to: store.appending(path: "user.sqlite")
        )
    }

    private func markSystemManagedTree(_ root: URL) throws {
        var rootURL = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try rootURL.setResourceValues(values)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return XCTFail("missing enumerator")
        }
        while let item = enumerator.nextObject() as? URL {
            var mutable = item
            var itemValues = URLResourceValues()
            itemValues.isExcludedFromBackup = false
            try mutable.setResourceValues(itemValues)
        }
    }

    private func generationCount(
        _ snapshot: DataInventoryCategorySnapshot?
    ) -> Int {
        guard let snapshot,
              case let .generations(values) = snapshot.payload else {
            return -1
        }
        return values.count
    }

    private func assertInvalidGenerationFailed(
        _ capture: DataInventoryStorageCapture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let invalid = capture.categorySnapshots.first(
            where: { $0.key == "storage.generation.invalid" }
        ) else {
            return XCTFail(
                "missing invalid generation category",
                file: file,
                line: line
            )
        }
        guard case .failed = invalid.payload else {
            return XCTFail(
                "invalid generation must fail closed",
                file: file,
                line: line
            )
        }
    }

    private func writePointer(
        layout: AppDataStoreLayout,
        generationID: UUID,
        origin: AppDataStoreOrigin,
        datasetID: UUID,
        minimumCount: Int
    ) throws {
        let pointer = GenerationPointer(
            generationID: generationID,
            schemaVersion: "12.0.0",
            origin: origin,
            datasetID: datasetID,
            minimumFactCount: minimumCount,
            minimumRevisionCount: minimumCount,
            activatedAt: Date(
                timeIntervalSince1970: 1_800_200_100
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(pointer).write(to: layout.pointerURL)
    }

    private func writeMigrationJournal(
        layout: AppDataStoreLayout,
        sourceID: UUID,
        targetID: UUID,
        targetSchemaVersion: String
    ) throws {
        let journal = MigrationJournal(
            targetGenerationID: targetID,
            origin: .schemaUpgrade,
            sourceGenerationID: sourceID,
            sourceSchemaVersion: "11.0.0",
            targetSchemaVersion: targetSchemaVersion,
            phase: .activated,
            updatedAt: Date(
                timeIntervalSince1970: 1_800_200_101
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(journal).write(
            to: layout.recoveryURL
                .appending(path: "migration-journal.json")
        )
        try markSystemManagedTree(
            layout.rootURL.deletingLastPathComponent()
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
