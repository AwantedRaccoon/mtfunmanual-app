import CryptoKit
import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class StoreBootstrapTests: XCTestCase {
    func testAtomicJSONWriterRejectsParentReplacementAndScrubsHeldTemp()
        throws {
        let layout = try makeLayout()
        let parent = layout.rootURL.appending(
            path: "AtomicWriter",
            directoryHint: .isDirectory
        )
        let displaced = layout.rootURL.appending(
            path: "AtomicWriter-displaced",
            directoryHint: .isDirectory
        )
        let destination = parent.appending(
            path: "state.json"
        )
        let writer = ProtectedAtomicJSONWriter(
            backupPolicy: .systemManaged,
            beforePublish: {
                try FileManager.default.moveItem(
                    at: parent,
                    to: displaced
                )
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: false
                )
            }
        )

        XCTAssertThrowsError(
            try writer.write(
                ["secret": "sensitive"],
                to: destination
            )
        ) {
            XCTAssertEqual(
                $0 as? AppDataFailure,
                .storageUnavailable
            )
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: parent.path
            ),
            []
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: displaced.path
            ),
            []
        )
    }

    func testAtomicJSONWriterScrubsEscapedPublishedInodeWithoutDeletingReplacement()
        throws {
        let layout = try makeLayout()
        let parent = layout.rootURL.appending(
            path: "AtomicWriter",
            directoryHint: .isDirectory
        )
        let destination = parent.appending(
            path: "state.json"
        )
        let escaped = layout.rootURL.appending(
            path: "escaped-state.json"
        )
        let replacement = Data(
            "{\"attacker\":\"replacement\"}".utf8
        )
        let writer = ProtectedAtomicJSONWriter(
            backupPolicy: .systemManaged,
            afterPublish: {
                try FileManager.default.moveItem(
                    at: destination,
                    to: escaped
                )
                try replacement.write(to: destination)
            }
        )

        XCTAssertThrowsError(
            try writer.write(
                ["secret": "sensitive"],
                to: destination
            )
        ) {
            XCTAssertEqual(
                $0 as? AppDataFailure,
                .storageUnavailable
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: escaped),
            Data()
        )
        XCTAssertEqual(
            try Data(contentsOf: destination),
            replacement
        )
    }

    func testAtomicJSONWriterRestoresExistingValueWhenPostPublishFails()
        throws {
        let layout = try makeLayout()
        let parent = layout.rootURL.appending(
            path: "AtomicWriter",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let destination = parent.appending(
            path: "state.json"
        )
        let previous = Data(
            "{\"version\":\"previous\"}".utf8
        )
        try previous.write(to: destination)
        let writer = ProtectedAtomicJSONWriter(
            backupPolicy: .systemManaged,
            afterPublish: {
                throw NSError(
                    domain: "AtomicWriterTests",
                    code: 1
                )
            }
        )

        XCTAssertThrowsError(
            try writer.write(
                ["version": "replacement"],
                to: destination
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: destination),
            previous
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: parent.path
            ),
            ["state.json"]
        )
    }

    func testAtomicJSONWriterUsesIndependentRollbackWhenPriorTempIsDeletedAndNewIsCorrupted()
        throws {
        let layout = try makeLayout()
        let parent = layout.rootURL.appending(
            path: "AtomicWriter",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let destination = parent.appending(
            path: "state.json"
        )
        let previous = Data(
            "{\"version\":\"previous\"}".utf8
        )
        try previous.write(to: destination)
        let writer = ProtectedAtomicJSONWriter(
            backupPolicy: .systemManaged,
            afterPublish: {
                let priorTemporary = try XCTUnwrap(
                    FileManager.default
                        .contentsOfDirectory(
                            atPath: parent.path
                        )
                        .first {
                            $0.hasPrefix(
                                ".state.json.atomic-new-v1-"
                            )
                        }
                )
                try FileManager.default.removeItem(
                    at: parent.appending(
                        path: priorTemporary
                    )
                )
                let handle = try FileHandle(
                    forWritingTo: destination
                )
                try handle.truncate(atOffset: 0)
                try handle.write(
                    contentsOf: Data("corrupt".utf8)
                )
                try handle.synchronize()
                try handle.close()
                throw NSError(
                    domain: "AtomicWriterTests",
                    code: 3
                )
            }
        )

        XCTAssertThrowsError(
            try writer.write(
                ["version": "replacement"],
                to: destination
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: destination),
            previous
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: parent.path
            ),
            ["state.json"]
        )
    }

    func testAtomicJSONWriterRestoresExistingValueWhenPublishedNewInodeEscapes()
        throws {
        let layout = try makeLayout()
        let parent = layout.rootURL.appending(
            path: "AtomicWriter",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let destination = parent.appending(
            path: "state.json"
        )
        let escaped = layout.rootURL.appending(
            path: "escaped-new-state.json"
        )
        let previous = Data(
            "{\"version\":\"previous\"}".utf8
        )
        try previous.write(to: destination)
        let writer = ProtectedAtomicJSONWriter(
            backupPolicy: .systemManaged,
            afterPublish: {
                try FileManager.default.moveItem(
                    at: destination,
                    to: escaped
                )
                throw NSError(
                    domain: "AtomicWriterTests",
                    code: 2
                )
            }
        )

        XCTAssertThrowsError(
            try writer.write(
                ["secret": "replacement"],
                to: destination
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: destination),
            previous
        )
        XCTAssertEqual(
            try Data(contentsOf: escaped),
            Data()
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: parent.path
            ),
            ["state.json"]
        )
    }

    func testGenerationPointerColdRecoveryReplaysPreAndPostSwapStates()
        throws {
        let layout = try makeLayout()
        try FileManager.default.createDirectory(
            at: layout.pointerDirectoryURL,
            withIntermediateDirectories: true
        )
        let old = GenerationPointer(
            generationID: UUID(),
            origin: .newInstall,
            datasetID: UUID(),
            minimumFactCount: 0,
            minimumRevisionCount: 0,
            activatedAt: Date(
                timeIntervalSince1970: 1_800_000_000
            )
        )
        let new = GenerationPointer(
            generationID: UUID(),
            origin: .schemaUpgrade,
            datasetID: UUID(),
            minimumFactCount: 1,
            minimumRevisionCount: 1,
            activatedAt: Date(
                timeIntervalSince1970: 1_800_000_001
            )
        )
        let oldData = try JSONEncoder
            .unmanualFoundation.encode(old)
        let newData = try JSONEncoder
            .unmanualFoundation.encode(new)
        let newName =
            AtomicControlFileTransaction.newName(
                destinationName:
                    layout.pointerURL
                    .lastPathComponent,
                data: newData
            )
        let oldName =
            AtomicControlFileTransaction.oldName(
                destinationName:
                    layout.pointerURL
                    .lastPathComponent,
                data: oldData
            )
        let parent = layout.pointerDirectoryURL
        let store = GenerationPointerStore(
            layout: layout,
            backupPolicy: .systemManaged
        )

        try oldData.write(to: layout.pointerURL)
        try newData.write(
            to: parent.appending(path: newName)
        )
        try oldData.write(
            to: parent.appending(path: oldName)
        )
        XCTAssertEqual(try store.read(), old)
        XCTAssertEqual(
            try directoryEntryNames(at: parent),
            ["active.json"]
        )

        try FileManager.default.removeItem(
            at: layout.pointerURL
        )
        try newData.write(to: layout.pointerURL)
        try oldData.write(
            to: parent.appending(path: newName)
        )
        try oldData.write(
            to: parent.appending(path: oldName)
        )
        XCTAssertEqual(try store.read(), new)
        XCTAssertEqual(
            try directoryEntryNames(at: parent),
            ["active.json"]
        )

        try oldData.write(
            to: parent.appending(path: newName)
        )
        XCTAssertEqual(try store.read(), new)
        XCTAssertEqual(
            try directoryEntryNames(at: parent),
            ["active.json"]
        )
    }

    func testGenerationPointerColdRecoveryPreservesForeignDigestMismatch()
        throws {
        let layout = try makeLayout()
        try FileManager.default.createDirectory(
            at: layout.pointerDirectoryURL,
            withIntermediateDirectories: true
        )
        let old = GenerationPointer(
            generationID: UUID(),
            origin: .newInstall,
            datasetID: UUID(),
            minimumFactCount: 0,
            minimumRevisionCount: 0
        )
        let intended = GenerationPointer(
            generationID: UUID(),
            origin: .schemaUpgrade,
            datasetID: UUID(),
            minimumFactCount: 1,
            minimumRevisionCount: 1
        )
        let foreign = GenerationPointer(
            generationID: UUID(),
            origin: .existingGeneration,
            datasetID: UUID(),
            minimumFactCount: 2,
            minimumRevisionCount: 2
        )
        let oldData = try JSONEncoder
            .unmanualFoundation.encode(old)
        let intendedData = try JSONEncoder
            .unmanualFoundation.encode(intended)
        let foreignData = try JSONEncoder
            .unmanualFoundation.encode(foreign)
        let leaf = layout.pointerURL
            .lastPathComponent
        let newName =
            AtomicControlFileTransaction.newName(
                destinationName: leaf,
                data: intendedData
            )
        let oldName =
            AtomicControlFileTransaction.oldName(
                destinationName: leaf,
                data: oldData
            )
        try foreignData.write(to: layout.pointerURL)
        try intendedData.write(
            to: layout.pointerDirectoryURL
                .appending(path: newName)
        )
        try oldData.write(
            to: layout.pointerDirectoryURL
                .appending(path: oldName)
        )
        let before = try directoryEntryNames(
            at: layout.pointerDirectoryURL
        )

        XCTAssertThrowsError(
            try GenerationPointerStore(
                layout: layout,
                backupPolicy: .systemManaged
            ).read()
        )
        XCTAssertEqual(
            try Data(contentsOf: layout.pointerURL),
            foreignData
        )
        XCTAssertEqual(
            try directoryEntryNames(
                at: layout.pointerDirectoryURL
            ),
            before
        )
    }

    func testFreshAfterResetUsesFrozenGenerationAndDatasetIdentity() throws {
        let layout = try makeLayout()
        let expectedGenerationID = UUID()
        let expectedDatasetID = UUID()
        let bootstrapper = AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            mode: .freshAfterReset(
                expectedGenerationID: expectedGenerationID,
                expectedDatasetID: expectedDatasetID
            ),
            fileProtectionVerificationMode: .simulatorTestHarness
        )

        let opened = try bootstrapper.open()
        let pointer = try GenerationPointerStore(
            layout: layout,
            backupPolicy: .systemManaged
        ).read()
        let context = ModelContext(opened.container)
        let metadata = try XCTUnwrap(
            context.fetch(FetchDescriptor<DatasetMetadata>()).first
        )

        XCTAssertEqual(opened.generationID, expectedGenerationID)
        XCTAssertEqual(pointer.generationID, expectedGenerationID)
        XCTAssertEqual(pointer.datasetID, expectedDatasetID)
        XCTAssertEqual(pointer.schemaVersion, "12.0.0")
        XCTAssertEqual(pointer.origin, .newInstall)
        XCTAssertEqual(metadata.datasetID, expectedDatasetID)
        let journal = try XCTUnwrap(
            MigrationJournalStore(
                layout: layout,
                backupPolicy: .systemManaged
            ).readIfPresent()
        )
        XCTAssertEqual(journal.targetGenerationID, expectedGenerationID)
        XCTAssertEqual(journal.origin, .newInstall)
        XCTAssertEqual(journal.phase, .activated)

        let reopened = try bootstrapper.open()
        XCTAssertEqual(reopened.generationID, expectedGenerationID)
        XCTAssertEqual(
            try GenerationPointerStore(
                layout: layout,
                backupPolicy: .systemManaged
            ).read(),
            pointer
        )
    }

    func testFreshAfterResetRejectsCorruptRecoveryJournalBeforeReopen()
        throws {
        let layout = try makeLayout()
        let generationID = UUID()
        let datasetID = UUID()
        let bootstrapper = AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            mode: .freshAfterReset(
                expectedGenerationID: generationID,
                expectedDatasetID: datasetID
            ),
            fileProtectionVerificationMode:
                .simulatorTestHarness
        )
        _ = try bootstrapper.open()
        let pointerBefore = try Data(
            contentsOf: layout.pointerURL
        )
        let corruptBytes = Data(
            "{not-a-migration-journal".utf8
        )
        try corruptBytes.write(
            to: layout.journalURL,
            options: .atomic
        )

        XCTAssertThrowsError(
            try bootstrapper.open()
        ) {
            XCTAssertEqual(
                $0 as? AppDataFailure,
                .corruptionSuspected
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: layout.journalURL),
            corruptBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: layout.pointerURL),
            pointerBefore
        )
    }

    func testFreshAfterResetRejectsRecoveryJournalForDifferentGeneration()
        throws {
        let layout = try makeLayout()
        let generationID = UUID()
        let datasetID = UUID()
        let bootstrapper = AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            mode: .freshAfterReset(
                expectedGenerationID: generationID,
                expectedDatasetID: datasetID
            ),
            fileProtectionVerificationMode:
                .simulatorTestHarness
        )
        _ = try bootstrapper.open()
        try MigrationJournalStore(
            layout: layout,
            backupPolicy: .systemManaged
        ).write(
            MigrationJournal(
                targetGenerationID: UUID(),
                origin: .newInstall,
                phase: .activated
            )
        )
        let journalBefore = try Data(
            contentsOf: layout.journalURL
        )

        XCTAssertThrowsError(
            try bootstrapper.open()
        ) {
            XCTAssertEqual(
                $0 as? AppDataFailure,
                .corruptionSuspected
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: layout.journalURL),
            journalBefore
        )
    }

    func testFreshAfterResetRejectsMissingRecoveryJournalWhenPointerExists()
        throws {
        let layout = try makeLayout()
        let generationID = UUID()
        let bootstrapper = AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            mode: .freshAfterReset(
                expectedGenerationID: generationID,
                expectedDatasetID: UUID()
            ),
            fileProtectionVerificationMode:
                .simulatorTestHarness
        )
        _ = try bootstrapper.open()
        let pointerBefore = try Data(
            contentsOf: layout.pointerURL
        )
        try FileManager.default.removeItem(
            at: layout.journalURL
        )

        XCTAssertThrowsError(
            try bootstrapper.open()
        ) {
            XCTAssertEqual(
                $0 as? AppDataFailure,
                .corruptionSuspected
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.journalURL.path
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: layout.pointerURL),
            pointerBefore
        )
    }

    func testFreshAfterResetAcceptsValidatedJournalWithMatchingPointer()
        throws {
        let layout = try makeLayout()
        let generationID = UUID()
        let datasetID = UUID()
        let bootstrapper = AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            mode: .freshAfterReset(
                expectedGenerationID: generationID,
                expectedDatasetID: datasetID
            ),
            fileProtectionVerificationMode:
                .simulatorTestHarness
        )
        _ = try bootstrapper.open()
        let activated = try MigrationJournalStore(
            layout: layout,
            backupPolicy: .systemManaged
        ).read()
        try MigrationJournalStore(
            layout: layout,
            backupPolicy: .systemManaged
        ).write(
            MigrationJournal(
                operationID: activated.operationID,
                targetGenerationID: generationID,
                origin: .newInstall,
                phase: .validated,
                updatedAt: activated.updatedAt
            )
        )

        let reopened = try bootstrapper.open()

        XCTAssertEqual(
            reopened.generationID,
            generationID
        )
        XCTAssertEqual(
            try GenerationPointerStore(
                layout: layout,
                backupPolicy: .systemManaged
            ).read().datasetID,
            datasetID
        )
        XCTAssertEqual(
            try MigrationJournalStore(
                layout: layout,
                backupPolicy: .systemManaged
            ).read().phase,
            .validated
        )
    }

    func testFreshAfterResetAdoptsOnlyExactEmptyPreparingGeneration()
        throws {
        let layout = try makeLayout()
        let generationID = UUID()
        let generationURL = layout
            .generationDirectoryURL(for: generationID)
        try FileManager.default.createDirectory(
            at: layout.storeDirectoryURL(for: generationID),
            withIntermediateDirectories: true
        )

        let opened = try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            mode: .freshAfterReset(
                expectedGenerationID: generationID,
                expectedDatasetID: UUID()
            ),
            fileProtectionVerificationMode:
                .simulatorTestHarness
        ).open()

        XCTAssertEqual(opened.generationID, generationID)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: generationURL.path
            )
        )
    }

    func testFreshAfterResetRejectsUnknownPreparingGenerationLeafWithoutDeletingIt()
        throws {
        let layout = try makeLayout()
        let generationID = UUID()
        let generationURL = layout
            .generationDirectoryURL(for: generationID)
        try FileManager.default.createDirectory(
            at: generationURL,
            withIntermediateDirectories: true
        )
        let unknownURL = generationURL.appending(
            path: "unknown.bin"
        )
        let bytes = Data("must survive".utf8)
        try bytes.write(to: unknownURL)

        XCTAssertThrowsError(
            try AppDataStoreBootstrapper(
                layout: layout,
                backupPolicy: .systemManaged,
                mode: .freshAfterReset(
                    expectedGenerationID: generationID,
                    expectedDatasetID: UUID()
                ),
                fileProtectionVerificationMode:
                    .simulatorTestHarness
            ).open()
        ) {
            XCTAssertEqual(
                $0 as? AppDataFailure,
                .corruptionSuspected
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: unknownURL),
            bytes
        )
    }

    func testFreshAfterResetRejectsUnknownPreparedStoreLeafWithoutDeletingIt()
        throws {
        let layout = try makeLayout()
        let generationID = UUID()
        let datasetID = UUID()
        let bootstrapper = AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            mode: .freshAfterReset(
                expectedGenerationID: generationID,
                expectedDatasetID: datasetID
            ),
            fileProtectionVerificationMode:
                .simulatorTestHarness
        )
        XCTAssertThrowsError(
            try bootstrapper.open(
                failAt: .afterGenerationPrepared
            )
        ) {
            XCTAssertEqual(
                $0 as? StoreBootstrapInterruption,
                .injected
            )
        }
        let unknownURL = layout
            .storeDirectoryURL(for: generationID)
            .appending(path: "unknown.bin")
        let bytes = Data("must survive prepared replay".utf8)
        try bytes.write(to: unknownURL)

        XCTAssertThrowsError(
            try bootstrapper.open()
        ) {
            XCTAssertEqual(
                $0 as? AppDataFailure,
                .corruptionSuspected
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: unknownURL),
            bytes
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.pointerURL.path
            )
        )
    }

    func testFreshAfterResetRejectsUnknownActivatedStoreLeafWithoutDeletingIt()
        throws {
        let layout = try makeLayout()
        let generationID = UUID()
        let bootstrapper = AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            mode: .freshAfterReset(
                expectedGenerationID: generationID,
                expectedDatasetID: UUID()
            ),
            fileProtectionVerificationMode:
                .simulatorTestHarness
        )
        _ = try bootstrapper.open()
        let unknownURL = layout
            .storeDirectoryURL(for: generationID)
            .appending(path: "unknown.bin")
        let bytes = Data("must survive activated replay".utf8)
        try bytes.write(to: unknownURL)

        XCTAssertThrowsError(
            try bootstrapper.open()
        ) {
            XCTAssertEqual(
                $0 as? AppDataFailure,
                .corruptionSuspected
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: unknownURL),
            bytes
        )
    }

    func testFreshAfterResetRejectsUnknownValidatedFilesLeafWithoutDeletingIt()
        throws {
        let layout = try makeLayout()
        let generationID = UUID()
        let bootstrapper = AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            mode: .freshAfterReset(
                expectedGenerationID: generationID,
                expectedDatasetID: UUID()
            ),
            fileProtectionVerificationMode:
                .simulatorTestHarness
        )
        XCTAssertThrowsError(
            try bootstrapper.open(
                failAt: .afterValidationBeforePointer
            )
        ) {
            XCTAssertEqual(
                $0 as? StoreBootstrapInterruption,
                .injected
            )
        }
        let unknownURL = layout
            .generationDirectoryURL(for: generationID)
            .appending(path: "Files")
            .appending(path: "unknown.bin")
        let bytes = Data("must survive validated replay".utf8)
        try bytes.write(to: unknownURL)

        XCTAssertThrowsError(
            try bootstrapper.open()
        ) {
            XCTAssertEqual(
                $0 as? AppDataFailure,
                .corruptionSuspected
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: unknownURL),
            bytes
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.pointerURL.path
            )
        )
    }

    func testFreshAfterResetRejectsPointerReplayWithExtraGenerationWithoutDeletingIt()
        throws {
        let layout = try makeLayout()
        let generationID = UUID()
        let bootstrapper = AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            mode: .freshAfterReset(
                expectedGenerationID: generationID,
                expectedDatasetID: UUID()
            ),
            fileProtectionVerificationMode:
                .simulatorTestHarness
        )
        _ = try bootstrapper.open()
        let extraGenerationURL = layout.generationsURL
            .appending(
                path: UUID().uuidString.lowercased(),
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: extraGenerationURL,
            withIntermediateDirectories: false
        )
        let evidenceURL = extraGenerationURL
            .appending(path: "evidence.bin")
        let bytes = Data("must survive sibling rejection".utf8)
        try bytes.write(to: evidenceURL)

        XCTAssertThrowsError(
            try bootstrapper.open()
        ) {
            XCTAssertEqual(
                $0 as? AppDataFailure,
                .corruptionSuspected
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: evidenceURL),
            bytes
        )
    }

    func testFreshAfterResetRejectsKnownFilesDirectoryReplacedBySymlink()
        throws {
        let layout = try makeLayout()
        let generationID = UUID()
        let bootstrapper = AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            mode: .freshAfterReset(
                expectedGenerationID: generationID,
                expectedDatasetID: UUID()
            ),
            fileProtectionVerificationMode:
                .simulatorTestHarness
        )
        _ = try bootstrapper.open()
        let filesURL = layout
            .generationDirectoryURL(for: generationID)
            .appending(path: "Files")
        let trashURL = filesURL.appending(path: ".trash")
        let targetURL = layout.legacyStoreURL
            .deletingLastPathComponent()
            .appending(
                path: "symlink-target",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: targetURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.removeItem(at: trashURL)
        try FileManager.default.createSymbolicLink(
            at: trashURL,
            withDestinationURL: targetURL
        )

        XCTAssertThrowsError(
            try bootstrapper.open()
        ) {
            XCTAssertEqual(
                $0 as? AppDataFailure,
                .corruptionSuspected
            )
        }
        XCTAssertNotNil(
            try? FileManager.default
                .destinationOfSymbolicLink(
                    atPath: trashURL.path
                )
        )
    }

    func testFreshAfterResetRejectsUnknownRecoverySiblingBeforeStoreMutation()
        throws {
        let layout = try makeLayout()
        let generationID = UUID()
        let bootstrapper = AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            mode: .freshAfterReset(
                expectedGenerationID: generationID,
                expectedDatasetID: UUID()
            ),
            fileProtectionVerificationMode:
                .simulatorTestHarness
        )
        XCTAssertThrowsError(
            try bootstrapper.open(
                failAt: .afterGenerationPrepared
            )
        ) {
            XCTAssertEqual(
                $0 as? StoreBootstrapInterruption,
                .injected
            )
        }
        let unknownURL = layout.recoveryURL
            .appending(path: "unknown.bin")
        let bytes = Data("must survive control rejection".utf8)
        try bytes.write(to: unknownURL)

        XCTAssertThrowsError(
            try bootstrapper.open()
        ) {
            XCTAssertEqual(
                $0 as? AppDataFailure,
                .corruptionSuspected
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: unknownURL),
            bytes
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.pointerURL.path
            )
        )
        XCTAssertTrue(
            try FileManager.default
                .contentsOfDirectory(
                    at: layout.storeDirectoryURL(
                        for: generationID
                    ),
                    includingPropertiesForKeys: nil,
                    options: []
                )
                .isEmpty
        )
    }

    func testFreshAfterResetRejectsUnknownPointerSiblingWithoutDeletingIt()
        throws {
        let layout = try makeLayout()
        let generationID = UUID()
        let bootstrapper = AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            mode: .freshAfterReset(
                expectedGenerationID: generationID,
                expectedDatasetID: UUID()
            ),
            fileProtectionVerificationMode:
                .simulatorTestHarness
        )
        _ = try bootstrapper.open()
        let pointerBefore = try Data(
            contentsOf: layout.pointerURL
        )
        let unknownURL = layout.pointerDirectoryURL
            .appending(path: "unknown.bin")
        let bytes = Data("must survive pointer rejection".utf8)
        try bytes.write(to: unknownURL)

        XCTAssertThrowsError(
            try bootstrapper.open()
        ) {
            XCTAssertEqual(
                $0 as? AppDataFailure,
                .corruptionSuspected
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: unknownURL),
            bytes
        )
        XCTAssertEqual(
            try Data(contentsOf: layout.pointerURL),
            pointerBefore
        )
    }

    func testFreshAfterResetRejectsActivePointerSymlink()
        throws {
        let layout = try makeLayout()
        let generationID = UUID()
        let bootstrapper = AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged,
            mode: .freshAfterReset(
                expectedGenerationID: generationID,
                expectedDatasetID: UUID()
            ),
            fileProtectionVerificationMode:
                .simulatorTestHarness
        )
        _ = try bootstrapper.open()
        let targetURL = layout.legacyStoreURL
            .deletingLastPathComponent()
            .appending(path: "pointer-target.json")
        try FileManager.default.moveItem(
            at: layout.pointerURL,
            to: targetURL
        )
        try FileManager.default.createSymbolicLink(
            at: layout.pointerURL,
            withDestinationURL: targetURL
        )

        XCTAssertThrowsError(
            try bootstrapper.open()
        ) {
            XCTAssertEqual(
                $0 as? AppDataFailure,
                .corruptionSuspected
            )
        }
        XCTAssertNotNil(
            try? FileManager.default
                .destinationOfSymbolicLink(
                    atPath: layout.pointerURL.path
                )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: targetURL.path
            )
        )
    }

    func testCoreRelationshipValidationRejectsSkippedPreviousVersionChain() throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let context = ModelContext(container)
        let first = RegimenPlanVersionRecord(
            code: "R-01",
            title: "第一版",
            effectiveStartDate: try CivilDateFact(year: 2026, month: 1, day: 1),
            editState: .sealed
        )
        let second = RegimenPlanVersionRecord(
            code: "R-02",
            title: "第二版",
            effectiveStartDate: try CivilDateFact(year: 2026, month: 2, day: 1),
            previousVersionID: nil,
            editState: .sealed
        )
        context.insert(first)
        context.insert(second)
        try context.save()

        XCTAssertThrowsError(
            try CoreRelationshipValidator.validate(in: context, failure: .migrationFailed)
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .migrationFailed)
        }
    }

    func testCoreRelationshipValidationRejectsResolvedAssociationWithoutID() throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let context = ModelContext(container)
        let journey = JourneyEntry(
            text: "用户原始记录",
            kind: .moment,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_700_000_000),
            timeZoneIdentifier: "UTC"
        )
        context.insert(journey)
        context.insert(
            HistoricalTimeRecord(
                sourceRecordType: "JourneyEntry",
                sourceRecordID: journey.id,
                timestamp: timestamp,
                legacyAssociationID: nil,
                resolvedRegimenVersionID: nil,
                associationState: .resolved
            )
        )
        try context.save()

        XCTAssertThrowsError(
            try CoreRelationshipValidator.validate(in: context, failure: .migrationFailed)
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .migrationFailed)
        }
    }

    func testCoreRelationshipValidationRejectsHistoricalSidecarWithoutSource() throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let context = ModelContext(container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_700_000_000),
            timeZoneIdentifier: "UTC"
        )
        context.insert(
            HistoricalTimeRecord(
                sourceRecordType: "LabRecord",
                sourceRecordID: UUID(),
                timestamp: timestamp,
                legacyAssociationID: nil,
                resolvedRegimenVersionID: nil,
                associationState: .missing
            )
        )
        try context.save()

        XCTAssertThrowsError(
            try CoreRelationshipValidator.validate(in: context, failure: .migrationFailed)
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .migrationFailed)
        }
    }

    func testCoreRelationshipValidationRejectsMultipleSchedulesForOneItem() throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let context = ModelContext(container)
        let start = try CivilDateFact(year: 2026, month: 1, day: 1)
        let version = RegimenPlanVersionRecord(
            code: "R-01",
            title: "第一版",
            effectiveStartDate: start,
            editState: .sealed
        )
        let item = RegimenItemRecord(
            regimenVersionID: version.id,
            sortOrder: 0,
            displayName: "用户原始记录"
        )
        context.insert(version)
        context.insert(item)
        context.insert(
            ScheduleRuleRecord(
                regimenItemID: item.id,
                kind: .dailyTimes,
                anchorDate: start
            )
        )
        context.insert(
            ScheduleRuleRecord(
                regimenItemID: item.id,
                kind: .weekly,
                anchorDate: start
            )
        )
        try context.save()

        XCTAssertThrowsError(
            try CoreRelationshipValidator.validate(in: context, failure: .migrationFailed)
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .migrationFailed)
        }
    }

    func testV2ActiveGenerationUpgradesThroughInactiveCopiesBeforeLatestPointerSwitch() throws {
        let layout = try makeLayout()
        let sourceGenerationID = UUID()
        let sourceStoreURL = layout.storeURL(for: sourceGenerationID)
        try FileManager.default.createDirectory(
            at: sourceStoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var datasetID: UUID!
        var factCount = 0
        var revisionCount = 0
        try autoreleasepool {
            let container = try AppModelContainerFactory.makeBridgeContainer(at: sourceStoreURL)
            _ = try LegacyV1Backfill.run(in: container)
            let context = ModelContext(container)
            datasetID = try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first).datasetID
            factCount = try context.fetchCount(FetchDescriptor<HRTProfile>())
                + context.fetchCount(FetchDescriptor<CountdownRecord>())
                + context.fetchCount(FetchDescriptor<RegimenVersion>())
                + context.fetchCount(FetchDescriptor<JourneyEntry>())
                + context.fetchCount(FetchDescriptor<LabRecord>())
            revisionCount = try context.fetchCount(FetchDescriptor<RecordRevision>())
        }
        try GenerationPointerStore(layout: layout).write(
            GenerationPointer(
                generationID: sourceGenerationID,
                schemaVersion: "2.0.0",
                origin: .newInstall,
                datasetID: datasetID,
                minimumFactCount: factCount,
                minimumRevisionCount: revisionCount
            )
        )
        try MigrationJournalStore(layout: layout).write(
            MigrationJournal(
                targetGenerationID: sourceGenerationID,
                origin: .newInstall,
                phase: .activated
            )
        )
        let sourceProtection = try StoreFileProtectionAuditor(
            backupPolicy: .systemManaged,
            verificationMode: .simulatorTestHarness
        ).hardenAndInspect(
            storeURL: sourceStoreURL,
            resources: layout.protectionResources(for: sourceGenerationID)
        )
        XCTAssertTrue(sourceProtection.isAcceptableForCurrentPlatform)
        let sourceDigest = try sha256(of: sourceStoreURL)
        let sourceResourceValues = try sourceStoreURL.resourceValues(
            forKeys: [.fileProtectionKey, .isExcludedFromBackupKey]
        )

        let upgraded = try makeTestBootstrapper(layout: layout).open()
        let pointer = try GenerationPointerStore(layout: layout).read()
        let context = ModelContext(upgraded.container)

        XCTAssertNotEqual(upgraded.generationID, sourceGenerationID)
        XCTAssertEqual(pointer.schemaVersion, "12.0.0")
        XCTAssertEqual(pointer.generationID, upgraded.generationID)
        XCTAssertEqual(try sha256(of: sourceStoreURL), sourceDigest)
        let sourceResourceValuesAfterUpgrade = try sourceStoreURL.resourceValues(
            forKeys: [.fileProtectionKey, .isExcludedFromBackupKey]
        )
        XCTAssertEqual(
            sourceResourceValuesAfterUpgrade.fileProtection,
            sourceResourceValues.fileProtection
        )
        XCTAssertEqual(
            sourceResourceValuesAfterUpgrade.isExcludedFromBackup,
            sourceResourceValues.isExcludedFromBackup
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<CoreTimeRegimenBackfillState>()).first?.completedAt != nil,
            true
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<TodayExecutionBackfillState>()).first?.completedAt != nil,
            true
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<PersonalTimelineBackfillState>()).first?.completedAt != nil,
            true
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<NotificationCoverageRecord>()), 1)
    }

    func testV3ActiveGenerationUpgradesThroughInactiveV4CopyWithoutExecutionFacts() throws {
        let layout = try makeLayout()
        let sourceGenerationID = UUID()
        let sourceStoreURL = layout.storeURL(for: sourceGenerationID)
        try FileManager.default.createDirectory(
            at: sourceStoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var datasetID: UUID!
        var factCount = 0
        var revisionCount = 0
        try autoreleasepool {
            let container = try AppModelContainerFactory.makeCoreContainer(at: sourceStoreURL)
            _ = try LegacyV1Backfill.run(in: container)
            _ = try CoreTimeRegimenBackfill.run(
                in: container,
                assumedTimeZoneIdentifier: "UTC"
            )
            let context = ModelContext(container)
            datasetID = try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first).datasetID
            revisionCount = try context.fetchCount(FetchDescriptor<RecordRevision>())
            factCount = revisionCount
        }
        try GenerationPointerStore(layout: layout).write(
            GenerationPointer(
                generationID: sourceGenerationID,
                schemaVersion: "3.0.0",
                origin: .newInstall,
                datasetID: datasetID,
                minimumFactCount: factCount,
                minimumRevisionCount: revisionCount
            )
        )
        try MigrationJournalStore(layout: layout).write(
            MigrationJournal(
                targetGenerationID: sourceGenerationID,
                origin: .newInstall,
                phase: .activated
            )
        )
        let sourceProtection = try StoreFileProtectionAuditor(
            backupPolicy: .systemManaged,
            verificationMode: .simulatorTestHarness
        ).hardenAndInspect(
            storeURL: sourceStoreURL,
            resources: layout.protectionResources(for: sourceGenerationID)
        )
        XCTAssertTrue(sourceProtection.isAcceptableForCurrentPlatform)
        let sourceDigest = try sha256(of: sourceStoreURL)

        let upgraded = try makeTestBootstrapper(layout: layout).open()
        let pointer = try GenerationPointerStore(layout: layout).read()
        let context = ModelContext(upgraded.container)

        XCTAssertNotEqual(upgraded.generationID, sourceGenerationID)
        XCTAssertEqual(pointer.schemaVersion, "12.0.0")
        XCTAssertEqual(try sha256(of: sourceStoreURL), sourceDigest)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AdministrationEventRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReminderPreferenceRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<NotificationCoverageRecord>()), 1)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<TodayExecutionBackfillState>()).first?.completedAt != nil,
            true
        )
    }

    func testV4ActiveGenerationUpgradesThroughInactiveV5AndV7Copies() throws {
        let layout = try makeLayout()
        let sourceGenerationID = UUID()
        let sourceStoreURL = layout.storeURL(for: sourceGenerationID)
        try FileManager.default.createDirectory(
            at: sourceStoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var datasetID: UUID!
        var factCount = 0
        var revisionCount = 0
        try autoreleasepool {
            let container = try AppModelContainerFactory.makeTodayContainer(
                at: sourceStoreURL
            )
            _ = try LegacyV1Backfill.run(in: container)
            _ = try CoreTimeRegimenBackfill.run(
                in: container,
                assumedTimeZoneIdentifier: "UTC"
            )
            _ = try TodayExecutionBackfill.run(in: container)
            let context = ModelContext(container)
            datasetID = try XCTUnwrap(
                context.fetch(FetchDescriptor<DatasetMetadata>()).first
            ).datasetID
            revisionCount = try context.fetchCount(
                FetchDescriptor<RecordRevision>()
            )
            factCount = revisionCount
        }
        try GenerationPointerStore(layout: layout).write(
            GenerationPointer(
                generationID: sourceGenerationID,
                schemaVersion: "4.0.0",
                origin: .newInstall,
                datasetID: datasetID,
                minimumFactCount: factCount,
                minimumRevisionCount: revisionCount
            )
        )
        try MigrationJournalStore(layout: layout).write(
            MigrationJournal(
                targetGenerationID: sourceGenerationID,
                origin: .newInstall,
                phase: .activated
            )
        )
        let sourceProtection = try StoreFileProtectionAuditor(
            backupPolicy: .systemManaged,
            verificationMode: .simulatorTestHarness
        ).hardenAndInspect(
            storeURL: sourceStoreURL,
            resources: layout.protectionResources(for: sourceGenerationID)
        )
        XCTAssertTrue(sourceProtection.isAcceptableForCurrentPlatform)
        let sourceDigest = try sha256(of: sourceStoreURL)

        let upgraded = try makeTestBootstrapper(layout: layout).open()
        let pointer = try GenerationPointerStore(layout: layout).read()
        let context = ModelContext(upgraded.container)

        XCTAssertNotEqual(upgraded.generationID, sourceGenerationID)
        XCTAssertEqual(pointer.schemaVersion, "12.0.0")
        XCTAssertEqual(pointer.generationID, upgraded.generationID)
        XCTAssertEqual(try sha256(of: sourceStoreURL), sourceDigest)
        XCTAssertEqual(
            try context.fetch(
                FetchDescriptor<PersonalTimelineBackfillState>()
            ).first?.completedAt != nil,
            true
        )
        XCTAssertNoThrow(
            try PersonalTimelineRelationshipValidator.validate(
                in: context,
                failure: .migrationFailed
            )
        )
        XCTAssertEqual(
            try context.fetch(
                FetchDescriptor<CountdownLifecycleBackfillState>()
            ).first?.completedAt != nil,
            true
        )
    }

    func testV4ToV5CrashBeforePointerPreservesSourceThenContinuesToV7() throws {
        let layout = try makeLayout()
        let sourceGenerationID = UUID()
        let sourceStoreURL = layout.storeURL(for: sourceGenerationID)
        try FileManager.default.createDirectory(
            at: sourceStoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var datasetID: UUID!
        var factCount = 0
        var revisionCount = 0
        try autoreleasepool {
            let container = try AppModelContainerFactory.makeTodayContainer(
                at: sourceStoreURL
            )
            _ = try LegacyV1Backfill.run(in: container)
            _ = try CoreTimeRegimenBackfill.run(
                in: container,
                assumedTimeZoneIdentifier: "UTC"
            )
            _ = try TodayExecutionBackfill.run(in: container)
            let context = ModelContext(container)
            datasetID = try XCTUnwrap(
                context.fetch(FetchDescriptor<DatasetMetadata>()).first
            ).datasetID
            revisionCount = try context.fetchCount(
                FetchDescriptor<RecordRevision>()
            )
            factCount = revisionCount
        }
        try GenerationPointerStore(layout: layout).write(
            GenerationPointer(
                generationID: sourceGenerationID,
                schemaVersion: "4.0.0",
                origin: .newInstall,
                datasetID: datasetID,
                minimumFactCount: factCount,
                minimumRevisionCount: revisionCount
            )
        )
        try MigrationJournalStore(layout: layout).write(
            MigrationJournal(
                targetGenerationID: sourceGenerationID,
                origin: .newInstall,
                phase: .activated
            )
        )
        _ = try StoreFileProtectionAuditor(
            backupPolicy: .systemManaged,
            verificationMode: .simulatorTestHarness
        ).hardenAndInspect(
            storeURL: sourceStoreURL,
            resources: layout.protectionResources(for: sourceGenerationID)
        )
        let sourceBundleBefore = try durableStoreBundleHashes(
            at: sourceStoreURL
        )
        let bootstrapper = makeTestBootstrapper(layout: layout)

        XCTAssertThrowsError(
            try bootstrapper.open(failAt: .afterValidationBeforePointer)
        ) { error in
            XCTAssertEqual(error as? StoreBootstrapInterruption, .injected)
        }
        let interruptedPointer = try GenerationPointerStore(layout: layout).read()
        let interruptedJournal = try MigrationJournalStore(layout: layout).read()
        XCTAssertEqual(interruptedPointer.generationID, sourceGenerationID)
        XCTAssertEqual(interruptedPointer.schemaVersion, "4.0.0")
        XCTAssertEqual(interruptedJournal.sourceGenerationID, sourceGenerationID)
        XCTAssertEqual(interruptedJournal.phase, .validated)
        XCTAssertEqual(
            try durableStoreBundleHashes(at: sourceStoreURL),
            sourceBundleBefore
        )

        let resumed = try bootstrapper.open()
        let activatedPointer = try GenerationPointerStore(layout: layout).read()

        XCTAssertNotEqual(resumed.generationID, interruptedJournal.targetGenerationID)
        XCTAssertEqual(activatedPointer.generationID, resumed.generationID)
        XCTAssertEqual(activatedPointer.schemaVersion, "12.0.0")
        XCTAssertEqual(
            try durableStoreBundleHashes(at: sourceStoreURL),
            sourceBundleBefore
        )
    }

    func testV4ToV5PreparingInterruptsReuseTargetThenContinuesThroughV9() throws {
        for failpoint in [
            StoreBootstrapFailpoint.duringLegacyBundleCopyAfterMain,
            .afterGenerationPrepared,
        ] {
            let layout = try makeLayout()
            let source = try seedActiveV4Generation(in: layout)
            let bootstrapper = makeTestBootstrapper(layout: layout)

            XCTAssertThrowsError(
                try bootstrapper.open(failAt: failpoint)
            ) { error in
                XCTAssertEqual(error as? StoreBootstrapInterruption, .injected)
            }
            let interruptedPointer = try GenerationPointerStore(
                layout: layout
            ).read()
            let interruptedJournal = try MigrationJournalStore(
                layout: layout
            ).read()
            let targetID = interruptedJournal.targetGenerationID
            XCTAssertEqual(
                interruptedPointer.generationID,
                source.generationID
            )
            XCTAssertEqual(interruptedPointer.schemaVersion, "4.0.0")
            XCTAssertEqual(
                try durableStoreBundleHashes(at: source.storeURL),
                source.durableHashes
            )
            XCTAssertEqual(
                try directoryEntryNames(at: layout.generationsURL),
                [
                    source.generationID.uuidString.lowercased(),
                    targetID.uuidString.lowercased(),
                ].sorted()
            )

            let resumed = try bootstrapper.open()
            let generationNames = try directoryEntryNames(
                at: layout.generationsURL
            )
            let knownGenerationNames = Set([
                source.generationID.uuidString.lowercased(),
                targetID.uuidString.lowercased(),
                resumed.generationID.uuidString.lowercased(),
            ])

            XCTAssertNotEqual(resumed.generationID, targetID)
            XCTAssertEqual(
                try GenerationPointerStore(layout: layout).read().generationID,
                resumed.generationID
            )
            XCTAssertEqual(
                try durableStoreBundleHashes(at: source.storeURL),
                source.durableHashes
            )
            XCTAssertEqual(
                Set(generationNames).subtracting(knownGenerationNames).count,
                5,
                "V4→V12 must retain the V7, V8, V9, V10, and V11 intermediate generations"
            )
            XCTAssertEqual(generationNames.count, 8)
        }
    }

    func testV5ToV7CrashBeforePointerPreservesSourceReusesV7TargetThenCreatesV8()
        throws
    {
        let layout = try makeLayout()
        let source = try seedActiveV5Generation(in: layout)
        let bootstrapper = makeTestBootstrapper(layout: layout)

        XCTAssertThrowsError(
            try bootstrapper.open(failAt: .afterValidationBeforePointer)
        ) { error in
            XCTAssertEqual(error as? StoreBootstrapInterruption, .injected)
        }
        let interruptedPointer = try GenerationPointerStore(layout: layout).read()
        let interruptedJournal = try MigrationJournalStore(layout: layout).read()
        let targetID = interruptedJournal.targetGenerationID
        XCTAssertEqual(interruptedPointer.generationID, source.generationID)
        XCTAssertEqual(interruptedPointer.schemaVersion, "5.0.0")
        XCTAssertEqual(interruptedJournal.sourceGenerationID, source.generationID)
        XCTAssertEqual(interruptedJournal.sourceSchemaVersion, "5.0.0")
        XCTAssertEqual(interruptedJournal.targetSchemaVersion, "7.0.0")
        XCTAssertEqual(interruptedJournal.phase, .validated)
        XCTAssertEqual(
            try durableStoreBundleHashes(at: source.storeURL),
            source.durableHashes
        )

        let resumed = try bootstrapper.open()
        let activatedPointer = try GenerationPointerStore(layout: layout).read()

        XCTAssertNotEqual(resumed.generationID, targetID)
        XCTAssertEqual(activatedPointer.generationID, resumed.generationID)
        XCTAssertEqual(activatedPointer.schemaVersion, "12.0.0")
        XCTAssertEqual(
            try durableStoreBundleHashes(at: source.storeURL),
            source.durableHashes
        )
        let generationNames = try directoryEntryNames(
            at: layout.generationsURL
        )
        let knownGenerationNames = Set([
            source.generationID.uuidString.lowercased(),
            targetID.uuidString.lowercased(),
            resumed.generationID.uuidString.lowercased(),
        ])
        XCTAssertEqual(
            Set(generationNames).subtracting(knownGenerationNames).count,
            4,
            "V5→V12 must retain the V8, V9, V10, and V11 intermediate generations"
        )
        XCTAssertEqual(generationNames.count, 7)
    }

    func testV5ToV7CopiesAndAuditsAttachmentFilesBeforePointerActivation()
        async throws
    {
        let layout = try makeLayout()
        let source = try seedActiveV5Generation(in: layout)
        let payload = Data("%PDF-1.7\nv5 attachment\n".utf8)
        let metadata = try await addV5JourneyAttachment(
            payload: payload,
            generationID: source.generationID,
            storeURL: source.storeURL,
            layout: layout
        )
        let sourceBundleBefore = try durableStoreBundleHashes(
            at: source.storeURL
        )
        let sourceFileURL = layout.generationDirectoryURL(
            for: source.generationID
        )
        .appendingPathComponent("Files", isDirectory: true)
        .appendingPathComponent(metadata.relativePath)
        XCTAssertEqual(try Data(contentsOf: sourceFileURL), payload)

        let opened = try makeTestBootstrapper(layout: layout).open()
        let pointer = try GenerationPointerStore(layout: layout).read()
        let targetFileURL = layout.generationDirectoryURL(
            for: opened.generationID
        )
        .appendingPathComponent("Files", isDirectory: true)
        .appendingPathComponent(metadata.relativePath)
        let context = ModelContext(opened.container)
        let attachmentID = metadata.attachmentID
        let attachment = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<AttachmentRecord>(
                    predicate: #Predicate {
                        $0.id == attachmentID
                    }
                )
            ).first
        )
        let snapshot = try XCTUnwrap(AttachmentSnapshot(attachment))

        XCTAssertEqual(pointer.schemaVersion, "12.0.0")
        XCTAssertEqual(pointer.generationID, opened.generationID)
        XCTAssertNotEqual(opened.generationID, source.generationID)
        XCTAssertEqual(try Data(contentsOf: targetFileURL), payload)
        XCTAssertEqual(try Data(contentsOf: sourceFileURL), payload)
        XCTAssertEqual(
            try durableStoreBundleHashes(at: source.storeURL),
            sourceBundleBefore
        )
        XCTAssertNoThrow(
            try AttachmentFileStore(
                rootURL: layout.generationDirectoryURL(
                    for: opened.generationID
                )
                .appendingPathComponent("Files", isDirectory: true)
            )
            .audit([snapshot])
        )
    }

    func testV5ToV7RejectsAttachmentSymlinkBeforePointerActivation()
        throws
    {
        let layout = try makeLayout()
        let source = try seedActiveV5Generation(in: layout)
        let originalPointer = try GenerationPointerStore(
            layout: layout
        ).read()
        let filesURL = layout.generationDirectoryURL(
            for: source.generationID
        )
        .appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(
            at: filesURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: filesURL.appendingPathComponent("unsafe-link"),
            withDestinationURL: source.storeURL
        )
        let sourceBundleBefore = try durableStoreBundleHashes(
            at: source.storeURL
        )

        XCTAssertThrowsError(
            try makeTestBootstrapper(layout: layout).open()
        ) { error in
            XCTAssertEqual(
                error as? AppDataFailure,
                .corruptionSuspected
            )
        }
        XCTAssertEqual(
            try GenerationPointerStore(layout: layout).read(),
            originalPointer
        )
        XCTAssertEqual(
            try durableStoreBundleHashes(at: source.storeURL),
            sourceBundleBefore
        )
    }

    func testV6EnabledReminderRequiresExplicitV7ResaveBeforeScheduling()
        async throws
    {
        let layout = try makeLayout()
        let source = try seedActiveV6GenerationWithEnabledReminder(
            in: layout
        )
        let sourceBundleBefore = try durableStoreBundleHashes(
            at: source.storeURL
        )

        let bootstrapper = makeTestBootstrapper(layout: layout)
        do {
            _ = try bootstrapper.open(
                failAt: .afterGenerationPrepared
            )
            XCTFail("Expected the prepared-generation failpoint")
        } catch let error as StoreBootstrapInterruption {
            XCTAssertEqual(error, .injected)
        } catch {
            XCTFail(
                "V6 source validation/copy failed before failpoint: \(error)"
            )
            throw error
        }
        let opened = try v6FixtureStep("resume V6 to V7 upgrade") {
            try bootstrapper.open()
        }
        let pointer = try GenerationPointerStore(layout: layout).read()
        let context = ModelContext(opened.container)
        let countdownID = source.countdownID
        let checkpoint = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<CountdownV6AuditCheckpointRecord>(
                    predicate: #Predicate {
                        $0.countdownID == countdownID
                    }
                )
            ).first
        )
        let state = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<CountdownStateRecord>(
                    predicate: #Predicate {
                        $0.id == countdownID
                    }
                )
            ).first
        )
        let expectedLatestEventID = state.latestEventID
        let title = state.title
        let gentleTitle = state.gentleTitle
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reader = AppReadActor(modelContainer: opened.container)
        let blocked = try await reader.reminderPlanningSnapshot(
            now: now,
            displayTimeZoneIdentifier: "UTC"
        )

        XCTAssertEqual(pointer.schemaVersion, "12.0.0")
        XCTAssertNotEqual(pointer.generationID, source.generationID)
        XCTAssertEqual(
            checkpoint.reminderAdmission,
            .needsUserConfirmation
        )
        XCTAssertTrue(blocked.countdownHasEnabledIntent)
        XCTAssertEqual(blocked.countdownID, source.countdownID)
        XCTAssertTrue(blocked.countdownCandidates.isEmpty)
        XCTAssertEqual(
            blocked.countdownFailureCode,
            "countdown-needs-confirmation"
        )
        XCTAssertEqual(
            try durableStoreBundleHashes(at: source.storeURL),
            sourceBundleBefore
        )

        let timestamp = try HistoricalTimestamp.captured(
            instant: now,
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        _ = try await AppWriteActor(
            modelContainer: opened.container
        ).updateCountdown(
            UpdateCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: source.countdownID,
                expectedLatestEventID: expectedLatestEventID,
                title: title,
                gentleTitle: gentleTitle,
                targetDate: try CivilDateFact(
                    year: 2030,
                    month: 1,
                    day: 15
                ),
                showInToday: true,
                reminder: CountdownReminderInput(
                    isEnabled: true,
                    leadDays: 2,
                    localHour: 9,
                    localMinute: 30
                ),
                timestamp: timestamp
            )
        )
        let admitted = try await reader.reminderPlanningSnapshot(
            now: now,
            displayTimeZoneIdentifier: "UTC"
        )

        XCTAssertTrue(admitted.countdownHasEnabledIntent)
        XCTAssertEqual(admitted.countdownID, source.countdownID)
        XCTAssertEqual(admitted.countdownCandidates.count, 1)
        XCTAssertNil(admitted.countdownFailureCode)
    }

    func testV5ToV7PreservesFractionalCountdownFactsThroughReopen() throws {
        let layout = try makeLayout()
        let source = try seedActiveV5Generation(
            in: layout,
            includeFractionalCountdowns: true
        )
        let activeCountdownID = try XCTUnwrap(source.activeCountdownID)
        let archivedCountdownID = try XCTUnwrap(source.archivedCountdownID)
        let activeCreatedAt = try XCTUnwrap(source.activeCreatedAt)
        let archivedAt = try XCTUnwrap(source.archivedAt)
        let bootstrapper = makeTestBootstrapper(layout: layout)
        var activatedGenerationID: UUID?

        try autoreleasepool {
            let opened = try bootstrapper.open()
            activatedGenerationID = opened.generationID
            let pointer = try GenerationPointerStore(layout: layout).read()
            XCTAssertEqual(pointer.schemaVersion, "12.0.0")
            XCTAssertEqual(pointer.generationID, opened.generationID)
            let context = ModelContext(opened.container)
            let states = try context.fetch(
                FetchDescriptor<CountdownStateRecord>()
            )
            let activeState = try XCTUnwrap(
                states.first { $0.id == activeCountdownID }
            )
            let archivedState = try XCTUnwrap(
                states.first { $0.id == archivedCountdownID }
            )
            XCTAssertEqual(activeState.createdAt, activeCreatedAt)
            XCTAssertEqual(activeState.updatedAt, activeCreatedAt)
            XCTAssertEqual(archivedState.archivedAt, archivedAt)
            XCTAssertEqual(archivedState.updatedAt, archivedAt)

            let events = try context.fetch(
                FetchDescriptor<CountdownLifecycleEventRecord>()
            )
            let activeEvent = try XCTUnwrap(
                events.first { $0.countdownID == activeCountdownID }
            )
            let archivedEvent = try XCTUnwrap(
                events.first { $0.countdownID == archivedCountdownID }
            )
            XCTAssertEqual(activeEvent.kind, .migratedSnapshot)
            XCTAssertEqual(activeEvent.occurredAt, activeCreatedAt)
            XCTAssertEqual(activeEvent.historicalTimestamp?.precision, .subsecond)
            XCTAssertEqual(archivedEvent.kind, .migratedSnapshot)
            XCTAssertEqual(archivedEvent.occurredAt, archivedAt)
            XCTAssertEqual(
                archivedEvent.historicalTimestamp?.precision,
                .subsecond
            )

            let reminders = try context.fetch(
                FetchDescriptor<CountdownReminderRuleRecord>()
            )
            XCTAssertEqual(
                reminders.first {
                    $0.countdownID == activeCountdownID
                }?.updatedAt,
                activeCreatedAt
            )
            XCTAssertEqual(
                reminders.first {
                    $0.countdownID == archivedCountdownID
                }?.updatedAt,
                archivedAt
            )
            let receipts = try context.fetch(
                FetchDescriptor<OperationReceiptRecord>()
            )
            XCTAssertEqual(
                receipts.first {
                    $0.operationID == activeEvent.operationID
                }?.committedAt,
                activeCreatedAt
            )
            XCTAssertEqual(
                receipts.first {
                    $0.operationID == archivedEvent.operationID
                }?.committedAt,
                archivedAt
            )
            XCTAssertNoThrow(
                try CountdownLifecycleRelationshipValidator.validate(
                    in: context,
                    failure: .corruptionSuspected
                )
            )
        }

        XCTAssertEqual(
            try durableStoreBundleHashes(at: source.storeURL),
            source.durableHashes
        )
        try autoreleasepool {
            let reopened = try bootstrapper.open()
            XCTAssertEqual(reopened.generationID, activatedGenerationID)
            XCTAssertEqual(reopened.origin, .existingGeneration)
            let context = ModelContext(reopened.container)
            XCTAssertNoThrow(
                try CountdownLifecycleRelationshipValidator.validate(
                    in: context,
                    failure: .corruptionSuspected
                )
            )
            let states = try context.fetch(
                FetchDescriptor<CountdownStateRecord>()
            )
            XCTAssertEqual(
                states.first {
                    $0.id == activeCountdownID
                }?.createdAt,
                activeCreatedAt
            )
            XCTAssertEqual(
                states.first {
                    $0.id == archivedCountdownID
                }?.archivedAt,
                archivedAt
            )
            let events = try context.fetch(
                FetchDescriptor<CountdownLifecycleEventRecord>()
            )
            let activeEvent = try XCTUnwrap(
                events.first { $0.countdownID == activeCountdownID }
            )
            let archivedEvent = try XCTUnwrap(
                events.first { $0.countdownID == archivedCountdownID }
            )
            XCTAssertEqual(activeEvent.occurredAt, activeCreatedAt)
            XCTAssertEqual(
                activeEvent.historicalTimestamp?.precision,
                .subsecond
            )
            XCTAssertEqual(archivedEvent.occurredAt, archivedAt)
            XCTAssertEqual(
                archivedEvent.historicalTimestamp?.precision,
                .subsecond
            )
            let reminders = try context.fetch(
                FetchDescriptor<CountdownReminderRuleRecord>()
            )
            XCTAssertEqual(
                reminders.first {
                    $0.countdownID == activeCountdownID
                }?.updatedAt,
                activeCreatedAt
            )
            XCTAssertEqual(
                reminders.first {
                    $0.countdownID == archivedCountdownID
                }?.updatedAt,
                archivedAt
            )
            let receipts = try context.fetch(
                FetchDescriptor<OperationReceiptRecord>()
            )
            XCTAssertEqual(
                receipts.first {
                    $0.operationID == activeEvent.operationID
                }?.committedAt,
                activeCreatedAt
            )
            XCTAssertEqual(
                receipts.first {
                    $0.operationID == archivedEvent.operationID
                }?.committedAt,
                archivedAt
            )
        }
        XCTAssertEqual(
            try durableStoreBundleHashes(at: source.storeURL),
            source.durableHashes
        )
    }

    func testV5ToV7PreparingInterruptsReuseV7TargetThenCreatesOnlyV8Target()
        throws
    {
        for failpoint in [
            StoreBootstrapFailpoint.duringLegacyBundleCopyAfterMain,
            .afterGenerationPrepared,
        ] {
            let layout = try makeLayout()
            let source = try seedActiveV5Generation(in: layout)
            let bootstrapper = makeTestBootstrapper(layout: layout)

            XCTAssertThrowsError(
                try bootstrapper.open(failAt: failpoint)
            ) { error in
                XCTAssertEqual(error as? StoreBootstrapInterruption, .injected)
            }
            let interruptedPointer = try GenerationPointerStore(
                layout: layout
            ).read()
            let interruptedJournal = try MigrationJournalStore(
                layout: layout
            ).read()
            let targetID = interruptedJournal.targetGenerationID
            XCTAssertEqual(interruptedPointer.generationID, source.generationID)
            XCTAssertEqual(interruptedPointer.schemaVersion, "5.0.0")
            XCTAssertEqual(
                try durableStoreBundleHashes(at: source.storeURL),
                source.durableHashes
            )
            XCTAssertEqual(
                try directoryEntryNames(at: layout.generationsURL),
                [
                    source.generationID.uuidString.lowercased(),
                    targetID.uuidString.lowercased(),
                ].sorted()
            )

            let resumed = try bootstrapper.open()

            XCTAssertNotEqual(resumed.generationID, targetID)
            XCTAssertEqual(
                try GenerationPointerStore(layout: layout).read().generationID,
                resumed.generationID
            )
            XCTAssertEqual(
                try durableStoreBundleHashes(at: source.storeURL),
                source.durableHashes
            )
            let generationNames = try directoryEntryNames(
                at: layout.generationsURL
            )
            let knownGenerationNames = Set([
                source.generationID.uuidString.lowercased(),
                targetID.uuidString.lowercased(),
                resumed.generationID.uuidString.lowercased(),
            ])
            XCTAssertEqual(
                Set(generationNames).subtracting(knownGenerationNames).count,
                4,
                "V5→V12 must retain the V8, V9, V10, and V11 intermediate generations"
            )
            XCTAssertEqual(generationNames.count, 7)
        }
    }

    func testV7ToV8CrashBeforePointerPreservesSourceThenContinuesToV9()
        throws
    {
        let layout = try makeLayout()
        let source = try seedActiveV7Generation(in: layout)
        let bootstrapper = makeTestBootstrapper(layout: layout)

        XCTAssertThrowsError(
            try bootstrapper.open(failAt: .afterValidationBeforePointer)
        ) { error in
            XCTAssertEqual(error as? StoreBootstrapInterruption, .injected)
        }
        let interruptedPointer = try GenerationPointerStore(
            layout: layout
        ).read()
        let interruptedJournal = try MigrationJournalStore(
            layout: layout
        ).read()
        let targetID = interruptedJournal.targetGenerationID

        XCTAssertEqual(interruptedPointer.generationID, source.generationID)
        XCTAssertEqual(interruptedPointer.schemaVersion, "7.0.0")
        XCTAssertEqual(
            interruptedJournal.sourceGenerationID,
            source.generationID
        )
        XCTAssertEqual(interruptedJournal.sourceSchemaVersion, "7.0.0")
        XCTAssertEqual(interruptedJournal.targetSchemaVersion, "8.0.0")
        XCTAssertEqual(interruptedJournal.phase, .validated)
        XCTAssertEqual(
            try durableStoreBundleHashes(at: source.storeURL),
            source.durableHashes
        )
        XCTAssertEqual(
            try directoryEntryNames(at: layout.generationsURL),
            (
                source.preexistingGenerationNames
                    + [targetID.uuidString.lowercased()]
            ).sorted()
        )

        let resumed = try bootstrapper.open()
        let activatedPointer = try GenerationPointerStore(
            layout: layout
        ).read()
        let context = ModelContext(resumed.container)
        let preferences = try XCTUnwrap(
            context.fetch(FetchDescriptor<UserPreferencesRecord>()).first
        )
        let progress = try XCTUnwrap(
            context.fetch(FetchDescriptor<OnboardingProgressRecord>()).first
        )
        let backfill = try XCTUnwrap(
            context.fetch(FetchDescriptor<OnboardingBackfillState>()).first
        )

        XCTAssertNotEqual(resumed.generationID, targetID)
        XCTAssertEqual(activatedPointer.generationID, resumed.generationID)
        XCTAssertEqual(activatedPointer.schemaVersion, "12.0.0")
        XCTAssertTrue(preferences.onboardingCompleted)
        XCTAssertEqual(progress.step, .completed)
        XCTAssertNotNil(progress.completedAt)
        XCTAssertEqual(backfill.source, .schemaUpgradeV7)
        XCTAssertEqual(
            try durableStoreBundleHashes(at: source.storeURL),
            source.durableHashes
        )
        let generationNames = try directoryEntryNames(
            at: layout.generationsURL
        )
        let knownGenerationNames = Set(
            source.preexistingGenerationNames
                + [
                    targetID.uuidString.lowercased(),
                    resumed.generationID.uuidString.lowercased()
                ]
        )
        XCTAssertEqual(
            Set(generationNames).subtracting(knownGenerationNames).count,
            3,
            "V7→V12 must retain the V9, V10, and V11 intermediate generations"
        )
        XCTAssertEqual(
            generationNames.count,
            source.preexistingGenerationNames.count + 5
        )
    }

    func testV7ToV8ProtectionFailurePreservesV7ThenContinuesToV9()
        throws
    {
        let layout = try makeLayout()
        let source = try seedActiveV7Generation(in: layout)
        let bootstrapper = makeTestBootstrapper(layout: layout)
        let originalPointer = try GenerationPointerStore(
            layout: layout
        ).read()

        XCTAssertThrowsError(
            try bootstrapper.open(
                failAt: .duringFileProtectionValidationBeforePointer
            )
        ) { error in
            XCTAssertEqual(
                error as? StoreBootstrapInterruption,
                .injected
            )
        }
        let interruptedPointer = try GenerationPointerStore(
            layout: layout
        ).read()
        let interruptedJournal = try MigrationJournalStore(
            layout: layout
        ).read()
        let targetID = interruptedJournal.targetGenerationID

        XCTAssertEqual(interruptedPointer, originalPointer)
        XCTAssertEqual(interruptedJournal.phase, .prepared)
        XCTAssertEqual(
            try durableStoreBundleHashes(at: source.storeURL),
            source.durableHashes
        )

        let resumed = try bootstrapper.open()
        let activatedPointer = try GenerationPointerStore(
            layout: layout
        ).read()
        XCTAssertNotEqual(resumed.generationID, targetID)
        XCTAssertEqual(activatedPointer.generationID, resumed.generationID)
        XCTAssertEqual(activatedPointer.schemaVersion, "12.0.0")
    }

    func testV7ToV8CopiesAttachmentTreeAndPreservesSource()
        async throws
    {
        let layout = try makeLayout()
        let source = try seedActiveV7Generation(in: layout)
        let payload = Data("%PDF-1.7\nv7 attachment\n".utf8)
        let metadata = try await addV7JourneyAttachment(
            payload: payload,
            generationID: source.generationID,
            storeURL: source.storeURL,
            layout: layout
        )
        let sourceHashes = try durableStoreBundleHashes(
            at: source.storeURL
        )
        let sourceFileURL = layout.generationDirectoryURL(
            for: source.generationID
        )
        .appendingPathComponent("Files", isDirectory: true)
        .appendingPathComponent(metadata.relativePath)

        let opened = try makeTestBootstrapper(layout: layout).open()
        let targetFileURL = layout.generationDirectoryURL(
            for: opened.generationID
        )
        .appendingPathComponent("Files", isDirectory: true)
        .appendingPathComponent(metadata.relativePath)
        let context = ModelContext(opened.container)
        let attachmentID = metadata.attachmentID
        let attachment = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<AttachmentRecord>(
                    predicate: #Predicate {
                        $0.id == attachmentID
                    }
                )
            ).first
        )
        let attachmentSnapshot = try XCTUnwrap(
            AttachmentSnapshot(attachment)
        )

        XCTAssertEqual(try Data(contentsOf: sourceFileURL), payload)
        XCTAssertEqual(try Data(contentsOf: targetFileURL), payload)
        XCTAssertEqual(
            try durableStoreBundleHashes(at: source.storeURL),
            sourceHashes
        )
        XCTAssertNoThrow(
            try AttachmentFileStore(
                rootURL: layout.generationDirectoryURL(
                    for: opened.generationID
                )
                .appendingPathComponent("Files", isDirectory: true)
            )
            .audit([attachmentSnapshot])
        )
    }

    func testV8ToV9CrashBeforePointerPreservesSourceAndReusesTarget()
        async throws
    {
        let layout = try makeLayout()
        let source = try await seedActiveV8Generation(in: layout)
        let bootstrapper = makeTestBootstrapper(layout: layout)

        XCTAssertThrowsError(
            try bootstrapper.open(failAt: .afterValidationBeforePointer)
        ) { error in
            XCTAssertEqual(error as? StoreBootstrapInterruption, .injected)
        }
        let interruptedPointer = try GenerationPointerStore(
            layout: layout
        ).read()
        let interruptedJournal = try MigrationJournalStore(
            layout: layout
        ).read()
        let targetID = interruptedJournal.targetGenerationID

        XCTAssertEqual(interruptedPointer.generationID, source.generationID)
        XCTAssertEqual(interruptedPointer.schemaVersion, "8.0.0")
        XCTAssertEqual(
            interruptedJournal.sourceGenerationID,
            source.generationID
        )
        XCTAssertEqual(interruptedJournal.sourceSchemaVersion, "8.0.0")
        XCTAssertEqual(interruptedJournal.targetSchemaVersion, "9.0.0")
        XCTAssertEqual(interruptedJournal.phase, .validated)
        XCTAssertEqual(
            try durableStoreBundleHashes(at: source.storeURL),
            source.durableHashes
        )

        let resumed = try bootstrapper.open()
        let activatedPointer = try GenerationPointerStore(
            layout: layout
        ).read()
        let context = ModelContext(resumed.container)
        let backfill = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<HrtJourneyLifecycleBackfillState>()
            ).first
        )

        let finalGenerationID = resumed.generationID
        XCTAssertNotEqual(finalGenerationID, targetID)
        XCTAssertEqual(
            activatedPointer.generationID,
            finalGenerationID
        )
        XCTAssertEqual(activatedPointer.schemaVersion, "12.0.0")
        XCTAssertEqual(backfill.sourceSchemaVersion, "8.0.0")
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<HrtJourneyLifecycleEventRecord>()
            ),
            1
        )
        XCTAssertEqual(
            try durableStoreBundleHashes(at: source.storeURL),
            source.durableHashes
        )
        let generationNames = try directoryEntryNames(
            at: layout.generationsURL
        )
        let knownGenerationNames = Set([
            source.generationID.uuidString.lowercased(),
            targetID.uuidString.lowercased(),
            finalGenerationID.uuidString.lowercased()
        ])
        XCTAssertEqual(
            Set(generationNames).subtracting(knownGenerationNames).count,
            2,
            "V8→V12 must retain the V10 and V11 intermediate generations"
        )
        XCTAssertEqual(generationNames.count, 5)

        let reopened = try bootstrapper.open()
        XCTAssertEqual(reopened.generationID, finalGenerationID)
        XCTAssertEqual(reopened.origin, .existingGeneration)
    }

    func testV9ToV10CrashBeforePointerPreservesSourceAndReusesTarget()
        async throws
    {
        let layout = try makeLayout()
        let source = try await seedActiveV9Generation(in: layout)
        let bootstrapper = makeTestBootstrapper(layout: layout)

        XCTAssertThrowsError(
            try bootstrapper.open(failAt: .afterValidationBeforePointer)
        ) { error in
            XCTAssertEqual(
                error as? StoreBootstrapInterruption,
                .injected
            )
        }
        let interruptedPointer = try GenerationPointerStore(
            layout: layout
        ).read()
        let interruptedJournal = try MigrationJournalStore(
            layout: layout
        ).read()
        let targetID = interruptedJournal.targetGenerationID

        XCTAssertEqual(
            interruptedPointer.generationID,
            source.generationID
        )
        XCTAssertEqual(interruptedPointer.schemaVersion, "9.0.0")
        XCTAssertEqual(
            interruptedJournal.sourceGenerationID,
            source.generationID
        )
        XCTAssertEqual(
            interruptedJournal.sourceSchemaVersion,
            "9.0.0"
        )
        XCTAssertEqual(
            interruptedJournal.targetSchemaVersion,
            "10.0.0"
        )
        XCTAssertEqual(interruptedJournal.phase, .validated)
        XCTAssertEqual(
            try durableStoreBundleHashes(at: source.storeURL),
            source.durableHashes
        )

        try autoreleasepool {
            let target = try AppModelContainerFactory
                .makeParentRecordLifecycleContainer(
                    at: layout.storeURL(for: targetID)
                )
            let context = ModelContext(target)
            XCTAssertEqual(
                try context.fetchCount(
                    FetchDescriptor<ParentRecordLifecycleHeadRecord>()
                ),
                2
            )
            XCTAssertEqual(
                try context.fetchCount(
                    FetchDescriptor<ParentRecordMutationEventRecord>()
                ),
                2
            )
            XCTAssertNoThrow(
                try ParentRecordLifecycleValidator.validate(
                    in: context,
                    failure: .migrationFailed
                )
            )
        }

        let resumed = try bootstrapper.open()
        let activatedPointer = try GenerationPointerStore(
            layout: layout
        ).read()
        let finalGenerationID = resumed.generationID
        XCTAssertNotEqual(finalGenerationID, targetID)
        XCTAssertEqual(
            activatedPointer.generationID,
            finalGenerationID
        )
        XCTAssertEqual(activatedPointer.schemaVersion, "12.0.0")
        XCTAssertEqual(
            try durableStoreBundleHashes(at: source.storeURL),
            source.durableHashes
        )

        let reopened = try bootstrapper.open()
        XCTAssertEqual(reopened.generationID, finalGenerationID)
        XCTAssertEqual(reopened.origin, .existingGeneration)
    }

    func testV10ToV11CrashBeforePointerPreservesSourceThenAdvancesToV12()
        throws
    {
        let layout = try makeLayout()
        let source = try seedActiveV10Generation(in: layout)
        let bootstrapper = makeTestBootstrapper(layout: layout)

        XCTAssertThrowsError(
            try bootstrapper.open(failAt: .afterValidationBeforePointer)
        ) { error in
            XCTAssertEqual(error as? StoreBootstrapInterruption, .injected)
        }
        let interruptedPointer = try GenerationPointerStore(
            layout: layout
        ).read()
        let interruptedJournal = try MigrationJournalStore(
            layout: layout
        ).read()
        let targetID = interruptedJournal.targetGenerationID

        XCTAssertEqual(
            interruptedPointer.generationID,
            source.generationID
        )
        XCTAssertEqual(interruptedPointer.schemaVersion, "10.0.0")
        XCTAssertEqual(
            interruptedJournal.sourceGenerationID,
            source.generationID
        )
        XCTAssertEqual(
            interruptedJournal.sourceSchemaVersion,
            "10.0.0"
        )
        XCTAssertEqual(
            interruptedJournal.targetSchemaVersion,
            "11.0.0"
        )
        XCTAssertEqual(interruptedJournal.phase, .validated)
        XCTAssertEqual(
            try durableStoreBundleHashes(at: source.storeURL),
            source.durableHashes
        )

        try autoreleasepool {
            let target = try AppModelContainerFactory
                .makeReadOnlyPrivacyControlContainer(
                    at: layout.storeURL(for: targetID)
                )
            let context = ModelContext(target)
            let snapshot = try PrivacyControlRelationshipValidator
                .snapshot(in: context, failure: .migrationFailed)
            let state = try XCTUnwrap(
                context.fetch(
                    FetchDescriptor<PrivacyControlBackfillState>()
                ).first
            )
            XCTAssertFalse(snapshot.appLockEnabled)
            XCTAssertEqual(state.source, .schemaUpgradeV10)
        }
        let v11DurableHashes = try durableStoreBundleHashes(
            at: layout.storeURL(for: targetID)
        )

        let resumed = try bootstrapper.open()
        let activatedPointer = try GenerationPointerStore(
            layout: layout
        ).read()
        let finalGenerationID = resumed.generationID
        XCTAssertNotEqual(finalGenerationID, targetID)
        XCTAssertEqual(activatedPointer.generationID, finalGenerationID)
        XCTAssertEqual(activatedPointer.schemaVersion, "12.0.0")
        XCTAssertEqual(
            try durableStoreBundleHashes(at: source.storeURL),
            source.durableHashes
        )
        XCTAssertEqual(
            try durableStoreBundleHashes(
                at: layout.storeURL(for: targetID)
            ),
            v11DurableHashes
        )

        let reopened = try bootstrapper.open()
        XCTAssertEqual(reopened.generationID, finalGenerationID)
        XCTAssertEqual(reopened.origin, .existingGeneration)
    }

    func testV11ToV12CrashBeforePointerPreservesSourceAndReusesTarget()
        throws
    {
        let layout = try makeLayout()
        let source = try seedActiveV11Generation(in: layout)
        let bootstrapper = makeTestBootstrapper(layout: layout)

        XCTAssertThrowsError(
            try bootstrapper.open(failAt: .afterValidationBeforePointer)
        ) { error in
            XCTAssertEqual(error as? StoreBootstrapInterruption, .injected)
        }
        let interruptedPointer = try GenerationPointerStore(
            layout: layout
        ).read()
        let interruptedJournal = try MigrationJournalStore(
            layout: layout
        ).read()
        let targetID = interruptedJournal.targetGenerationID

        XCTAssertEqual(
            interruptedPointer.generationID,
            source.generationID
        )
        XCTAssertEqual(interruptedPointer.schemaVersion, "11.0.0")
        XCTAssertEqual(
            interruptedJournal.sourceGenerationID,
            source.generationID
        )
        XCTAssertEqual(
            interruptedJournal.sourceSchemaVersion,
            "11.0.0"
        )
        XCTAssertEqual(
            interruptedJournal.targetSchemaVersion,
            "12.0.0"
        )
        XCTAssertEqual(interruptedJournal.phase, .validated)
        XCTAssertEqual(
            try durableStoreBundleHashes(at: source.storeURL),
            source.durableHashes
        )

        try autoreleasepool {
            let target = try AppModelContainerFactory
                .makeReadOnlyDataControlContainer(
                    at: layout.storeURL(for: targetID)
                )
            let context = ModelContext(target)
            let state = try XCTUnwrap(
                context.fetch(
                    FetchDescriptor<DataControlBackfillState>()
                ).first
            )
            XCTAssertEqual(state.source, .schemaUpgradeV11)
            XCTAssertEqual(
                try context.fetchCount(
                    FetchDescriptor<DataControlDeletionTombstoneRecord>()
                ),
                0
            )
            XCTAssertNoThrow(
                try DataControlRelationshipValidator.validate(
                    in: context,
                    failure: .migrationFailed
                )
            )
        }

        let resumed = try bootstrapper.open()
        let activatedPointer = try GenerationPointerStore(
            layout: layout
        ).read()
        XCTAssertEqual(resumed.generationID, targetID)
        XCTAssertEqual(activatedPointer.generationID, targetID)
        XCTAssertEqual(activatedPointer.schemaVersion, "12.0.0")
        XCTAssertEqual(
            try durableStoreBundleHashes(at: source.storeURL),
            source.durableHashes
        )

        let reopened = try bootstrapper.open()
        XCTAssertEqual(reopened.generationID, targetID)
        XCTAssertEqual(reopened.origin, .existingGeneration)
    }

    func testV9RevisionTamperFailsClosedBeforePointerMoves()
        async throws
    {
        let layout = try makeLayout()
        let source = try await seedActiveV9Generation(in: layout)
        let originalPointer = try GenerationPointerStore(
            layout: layout
        ).read()
        try await tamperHrtEventRevision(at: source.storeURL)

        XCTAssertThrowsError(
            try makeTestBootstrapper(layout: layout).open()
        ) { error in
            XCTAssertEqual(
                error as? AppDataFailure,
                .corruptionSuspected
            )
        }
        XCTAssertEqual(
            try GenerationPointerStore(layout: layout).read(),
            originalPointer
        )
    }

    func testV10CorrectionAndDeletionReceiptsSurvivePersistentReopen()
        async throws
    {
        let layout = try makeLayout()
        let bootstrapper = makeTestBootstrapper(layout: layout)
        let opened = try bootstrapper.open()
        let writer = AppDataWriter(
            storage: AppWriteActor(modelContainer: opened.container),
            verifyStoreProtection: { true },
            onProtectionFailure: {}
        )
        let reader = AppReadActor(modelContainer: opened.container)
        let sampleID = UUID()
        let definitionID = UUID()
        let resultID = UUID()
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_767_225_600),
            timeZoneIdentifier: "UTC",
            precision: .second,
            provenance: .migrationAssumed
        )
        _ = try await writer.createLabSample(
            CreateLabSampleCommand(
                operationID: UUID(),
                sampleID: sampleID,
                timestamp: timestamp,
                newDefinitions: [
                    LabItemDefinitionInput(
                        id: definitionID,
                        displayName: "雌二醇"
                    )
                ],
                results: [
                    LabResultInput(
                        id: resultID,
                        itemDefinitionID: definitionID,
                        rawValueOriginal: "100",
                        unitOriginal: "pmol/L"
                    )
                ]
            )
        )
        let loadedInitialHead = try await reader.parentRecordHeadToken(
            type: .labSample,
            id: sampleID
        )
        let initialHead = try XCTUnwrap(loadedInitialHead)
        _ = try await writer.correctLabSample(
            CorrectLabSampleCommand(
                parentID: sampleID,
                expectedHead: initialHead,
                timestamp: timestamp,
                specimenOriginal: "",
                contextNote: "重启后仍可核对",
                results: [
                    CorrectedLabResultInput(
                        logicalResultID: resultID,
                        itemDefinitionID: definitionID,
                        rawValueOriginal: "101",
                        unitOriginal: "pmol/L"
                    )
                ]
            )
        )

        let correctedStore = try bootstrapper.open()
        let correctedReader = AppReadActor(
            modelContainer: correctedStore.container
        )
        let correctedSample = try await correctedReader.labSample(
            id: sampleID
        )
        XCTAssertEqual(correctedSample?.contextNote, "重启后仍可核对")
        let impact = try await correctedReader.parentRecordDeletionImpact(
            type: .labSample,
            id: sampleID
        )
        let correctedWriter = AppDataWriter(
            storage: AppWriteActor(
                modelContainer: correctedStore.container
            ),
            verifyStoreProtection: { true },
            onProtectionFailure: {}
        )
        _ = try await correctedWriter.deleteParentRecord(
            DeleteParentRecordCommand(
                parentType: .labSample,
                parentID: sampleID,
                expectedHead: impact.expectedHead,
                expectedImpactDigest: impact.impactDigest,
                attachments: []
            )
        )

        let deletedStore = try bootstrapper.open()
        let deletedReader = AppReadActor(
            modelContainer: deletedStore.container
        )
        let isDeleted = try await deletedReader.parentRecordIsDeleted(
            type: .labSample,
            id: sampleID
        )
        let deletedSample = try await deletedReader.labSample(
            id: sampleID
        )
        XCTAssertTrue(isDeleted)
        XCTAssertNil(deletedSample)
    }

    func testProductionBackupPolicyAllowsSystemManagedDeviceBackup() {
        XCTAssertEqual(SystemBackupPolicy.production, .systemManaged)
    }

    func testProductionBackupDisclosureExplainsLocalStorageAndSystemBackupBoundary() {
        let disclosure = [
            SystemBackupDisclosure.summary,
            SystemBackupDisclosure.networkBoundary,
            SystemBackupDisclosure.systemBackupBoundary
        ].joined(separator: " ")

        XCTAssertTrue(disclosure.contains("App 私有存储"))
        XCTAssertTrue(disclosure.contains("不主动上传"))
        XCTAssertTrue(disclosure.contains("不实时同步"))
        XCTAssertTrue(disclosure.contains("iOS"))
        XCTAssertTrue(disclosure.contains("系统备份"))
        XCTAssertTrue(disclosure.contains("不保证"))
        XCTAssertFalse(disclosure.contains("仅本机"))
        XCTAssertEqual(SystemBackupDisclosure.statusLabel, "本地保存")
    }

    func testSystemManagedOpenAuditsEveryContainerDirectoryAndClearsExclusion() throws {
        let layout = try makeLayout()
        let opened = try makeTestBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged
        ).open()
        let containerRoles: Set<StorePhysicalFileRole> = [
            .rootDirectory,
            .generationsDirectory,
            .pointerDirectory,
            .recoveryDirectory
        ]
        let containerEntries = opened.protectionReport.entries.filter {
            containerRoles.contains($0.role)
        }

        XCTAssertEqual(Set(containerEntries.map(\.role)), containerRoles)
        XCTAssertTrue(containerEntries.allSatisfy(\.exists))
        XCTAssertTrue(containerEntries.allSatisfy { $0.isExcludedFromBackup == false })
        XCTAssertTrue(opened.protectionReport.isAcceptableForCurrentPlatform)
    }

    func testFirstInstallCreatesValidatedExplicitGenerationAndPointer() throws {
        let layout = try makeLayout()
        let bootstrapper = makeTestBootstrapper(layout: layout)

        let opened = try bootstrapper.open()
        let pointer = try GenerationPointerStore(layout: layout).read()
        let context = ModelContext(opened.container)

        XCTAssertEqual(opened.origin, .newInstall)
        XCTAssertEqual(pointer.generationID, opened.generationID)
        XCTAssertEqual(pointer.schemaVersion, "12.0.0")
        XCTAssertEqual(opened.storeURL, layout.storeURL(for: opened.generationID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: opened.storeURL.path))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DatasetMetadata>()), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MigrationBackfillState>()).first?.phase, .complete)
        XCTAssertFalse(
            try XCTUnwrap(
                context.fetch(FetchDescriptor<UserPreferencesRecord>()).first
            ).onboardingCompleted
        )
        XCTAssertEqual(
            try XCTUnwrap(
                context.fetch(FetchDescriptor<OnboardingProgressRecord>()).first
            ).step,
            .privacy
        )
        XCTAssertEqual(
            try XCTUnwrap(
                context.fetch(FetchDescriptor<OnboardingBackfillState>()).first
            ).source,
            .newInstallV8
        )
        XCTAssertEqual(
            try XCTUnwrap(
                context.fetch(FetchDescriptor<DataControlBackfillState>()).first
            ).source,
            .bootstrapV12
        )
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<DataControlDeletionTombstoneRecord>()
            ),
            0
        )
    }

    func testLegacyAdoptionCopiesBundleMigratesTargetAndNeverMutatesSource() throws {
        let layout = try makeLayout()
        try seedLegacyStore(at: layout.legacyStoreURL)
        let sourceDigestBefore = try sha256(of: layout.legacyStoreURL)

        let opened = try makeTestBootstrapper(layout: layout).open()
        let sourceDigestAfter = try sha256(of: layout.legacyStoreURL)
        let context = ModelContext(opened.container)

        XCTAssertEqual(opened.origin, .legacyAdoption)
        XCTAssertEqual(sourceDigestAfter, sourceDigestBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.legacyStoreURL.path))
        XCTAssertNotEqual(opened.storeURL, layout.legacyStoreURL)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HRTProfile>()), 1)
        // Canonical/receipt-ledger facts, V7 integrity, V8 onboarding,
        // V10 parent lifecycle, V11 privacy control, and the V12 data-control
        // marker accompany the adopted fact.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordRevision>()), 14)
        XCTAssertTrue(
            try XCTUnwrap(
                context.fetch(FetchDescriptor<UserPreferencesRecord>()).first
            ).onboardingCompleted
        )
        XCTAssertEqual(
            try XCTUnwrap(
                context.fetch(FetchDescriptor<OnboardingProgressRecord>()).first
            ).step,
            .completed
        )
        XCTAssertEqual(
            try XCTUnwrap(
                context.fetch(FetchDescriptor<OnboardingBackfillState>()).first
            ).source,
            .legacyAdoption
        )
        XCTAssertEqual(
            try XCTUnwrap(
                context.fetch(FetchDescriptor<DataControlBackfillState>()).first
            ).source,
            .bootstrapV12
        )
    }

    func testEmptyUnversionedLegacyStoreAdoptsReopensAndKeepsSourceUntouched() throws {
        let layout = try makeLayout()
        try autoreleasepool {
            _ = try LegacyUnversionedStoreFactory.makeContainer(at: layout.legacyStoreURL)
        }
        let sourceDigestBefore = try sha256(of: layout.legacyStoreURL)

        var firstDatasetID: UUID?
        try autoreleasepool {
            let opened = try makeTestBootstrapper(layout: layout).open()
            let context = ModelContext(opened.container)

            XCTAssertEqual(opened.origin, .legacyAdoption)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordRevision>()), 10)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<DatasetMetadata>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<MigrationBackfillState>()), 1)
            firstDatasetID = try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first).datasetID
        }

        try autoreleasepool {
            let reopened = try makeTestBootstrapper(layout: layout).open()
            let context = ModelContext(reopened.container)

            XCTAssertEqual(reopened.origin, .existingGeneration)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordRevision>()), 10)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<DatasetMetadata>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<MigrationBackfillState>()), 1)
            XCTAssertEqual(try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first).datasetID, firstDatasetID)
        }

        XCTAssertEqual(try sha256(of: layout.legacyStoreURL), sourceDigestBefore)
    }

    func testFrozenPreFoundationBundleMigratesAndSourceBundleHashesRemainUnchanged() throws {
        let expectedHashes = [
            "": "d9146783c2ac547cb928d49575b413f5c809798b7966a25993b303bf076bc46c",
            "-wal": "3dd20dac4b7ce743b798659e569d6bd0536c171f87a35777213dcfcff2f5ed34",
            "-shm": "990cd5758c9452546266e8275e654a8d3487981ac4258a0ed3521dde716c50a0"
        ]
        for (suffix, hash) in expectedHashes {
            XCTAssertEqual(
                try sha256(of: frozenLegacyFixtureURL(suffix: suffix)),
                hash
            )
        }

        let layout = try makeLayout()
        try FileManager.default.createDirectory(
            at: layout.legacyStoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        for suffix in expectedHashes.keys {
            try FileManager.default.copyItem(
                at: frozenLegacyFixtureURL(suffix: suffix),
                to: URL(fileURLWithPath: layout.legacyStoreURL.path + suffix)
            )
        }

        let opened = try makeTestBootstrapper(layout: layout).open()
        let context = ModelContext(opened.container)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HRTProfile>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CountdownRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RegimenVersion>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<JourneyEntry>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LabRecord>()), 1)
        // V7 adds Countdown integrity, V8 onboarding, V10 the parent
        // lifecycle rollout plus the migrated lab root/head, V11 adds privacy
        // control, and V12 adds the data-control marker.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordRevision>()), 33)
        XCTAssertEqual(
            try context.fetch(
                FetchDescriptor<OperationReceiptRecord>(
                    predicate: #Predicate {
                        $0.resultRecordType == "LabSampleRecord"
                    }
                )
            ).count,
            1
        )
        for (suffix, hash) in expectedHashes {
            XCTAssertEqual(
                try sha256(of: frozenLegacyFixtureURL(suffix: suffix)),
                hash
            )
        }
    }

    func testCrashBeforePointerLeavesLegacyStoreAndResumeActivatesSameGeneration() throws {
        let layout = try makeLayout()
        try seedLegacyStore(at: layout.legacyStoreURL)
        let sourceDigestBefore = try sha256(of: layout.legacyStoreURL)
        let bootstrapper = makeTestBootstrapper(layout: layout)

        XCTAssertThrowsError(try bootstrapper.open(failAt: .afterValidationBeforePointer)) { error in
            XCTAssertEqual(error as? StoreBootstrapInterruption, .injected)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.pointerURL.path))
        let journal = try MigrationJournalStore(layout: layout).read()

        let resumed = try bootstrapper.open()

        XCTAssertEqual(resumed.generationID, journal.targetGenerationID)
        XCTAssertEqual(try GenerationPointerStore(layout: layout).read().generationID, journal.targetGenerationID)
        XCTAssertEqual(try sha256(of: layout.legacyStoreURL), sourceDigestBefore)
    }

    func testNewInstallCrashAfterPreparedResumesTheSameGeneration() throws {
        let layout = try makeLayout()
        let bootstrapper = makeTestBootstrapper(layout: layout)

        XCTAssertThrowsError(try bootstrapper.open(failAt: .afterGenerationPrepared)) { error in
            XCTAssertEqual(error as? StoreBootstrapInterruption, .injected)
        }
        let interruptedJournal = try MigrationJournalStore(layout: layout).read()
        XCTAssertEqual(interruptedJournal.origin, .newInstall)
        XCTAssertEqual(interruptedJournal.phase, .prepared)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.storeURL(for: interruptedJournal.targetGenerationID).path
            )
        )

        let resumed = try bootstrapper.open()

        XCTAssertEqual(resumed.generationID, interruptedJournal.targetGenerationID)
        XCTAssertEqual(resumed.origin, .newInstall)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resumed.storeURL.path))
        XCTAssertEqual(
            try GenerationPointerStore(layout: layout).read().generationID,
            interruptedJournal.targetGenerationID
        )
    }

    func testCrashDuringBundleCopyPreservesPartialGenerationAndResumeUsesFreshGeneration() throws {
        let layout = try makeLayout()
        try seedLegacyStore(at: layout.legacyStoreURL)
        let sourceDigestBefore = try sha256(of: layout.legacyStoreURL)
        let bootstrapper = makeTestBootstrapper(layout: layout)

        XCTAssertThrowsError(try bootstrapper.open(failAt: .duringLegacyBundleCopyAfterMain)) { error in
            XCTAssertEqual(error as? StoreBootstrapInterruption, .injected)
        }
        let interruptedJournal = try MigrationJournalStore(layout: layout).read()
        XCTAssertEqual(interruptedJournal.phase, .preparing)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.storeURL(for: interruptedJournal.targetGenerationID).path
            )
        )

        let resumed = try bootstrapper.open()

        XCTAssertNotEqual(resumed.generationID, interruptedJournal.targetGenerationID)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.storeURL(for: interruptedJournal.targetGenerationID).path
            )
        )
        XCTAssertEqual(try sha256(of: layout.legacyStoreURL), sourceDigestBefore)
        XCTAssertEqual(try ModelContext(resumed.container).fetchCount(FetchDescriptor<HRTProfile>()), 1)
    }

    func testInterruptedLegacyCopyDoesNotMutateSourceBeforeCompleteBundleExists() throws {
        let layout = try makeLayout()
        try seedLegacyStore(at: layout.legacyStoreURL)
        let sourceParts = ["", "-wal", "-shm"]
            .map { URL(fileURLWithPath: layout.legacyStoreURL.path + $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertFalse(sourceParts.isEmpty)
        for sourcePart in sourceParts {
            var values = URLResourceValues()
            values.isExcludedFromBackup = false
            var mutableSourcePart = sourcePart
            try mutableSourcePart.setResourceValues(values)
        }

        XCTAssertThrowsError(
            try makeTestBootstrapper(
                layout: layout,
                backupPolicy: .excluded
            ).open(failAt: .duringLegacyBundleCopyAfterMain)
        ) { error in
            XCTAssertEqual(error as? StoreBootstrapInterruption, .injected)
        }

        for sourcePart in sourceParts {
            let values = try sourcePart.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertNotEqual(
                values.isExcludedFromBackup,
                true,
                "A failed partial copy must not mutate the only preserved legacy source: \(sourcePart.lastPathComponent)"
            )
        }
    }

    func testCorruptPointerEntersRecoveryInsteadOfCreatingBlankStore() throws {
        let layout = try makeLayout()
        try FileManager.default.createDirectory(
            at: layout.pointerDirectoryURL,
            withIntermediateDirectories: true
        )
        try Data("{not-json".utf8).write(to: layout.pointerURL, options: .atomic)
        let generationsBefore = try directoryEntryNames(at: layout.generationsURL)

        XCTAssertThrowsError(try makeTestBootstrapper(layout: layout).open()) { error in
            XCTAssertEqual(error as? AppDataFailure, .invalidGenerationPointer)
        }
        XCTAssertEqual(try directoryEntryNames(at: layout.generationsURL), generationsBefore)
    }

    func testCorruptJournalEntersRecoveryWithoutCreatingGeneration() throws {
        let layout = try makeLayout()
        try FileManager.default.createDirectory(
            at: layout.recoveryURL,
            withIntermediateDirectories: true
        )
        try Data("{not-json".utf8).write(to: layout.journalURL, options: .atomic)

        XCTAssertThrowsError(try makeTestBootstrapper(layout: layout).open()) { error in
            XCTAssertEqual(error as? AppDataFailure, .migrationFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.pointerURL.path))
        XCTAssertTrue(try directoryEntryNames(at: layout.generationsURL).isEmpty)
    }

    func testMigrationJournalRejectsSameSourceAndTargetForEveryPhase()
        throws {
        let layout = try makeLayout()
        try FileManager.default.createDirectory(
            at: layout.recoveryURL,
            withIntermediateDirectories: true
        )
        let generationID = UUID()
        for phase in [
            MigrationJournalPhase.preparing,
            .prepared,
            .validated,
            .activated
        ] {
            let invalid = MigrationJournal(
                    targetGenerationID: generationID,
                    origin: .schemaUpgrade,
                    sourceGenerationID: generationID,
                    sourceSchemaVersion: "11.0.0",
                    targetSchemaVersion: "12.0.0",
                    phase: phase,
                    updatedAt: Date(
                        timeIntervalSince1970: 1_800_200_000
                    )
                )
            try JSONEncoder.unmanualFoundation
                .encode(invalid)
                .write(
                    to: layout.journalURL,
                    options: .atomic
                )
            XCTAssertThrowsError(
                try MigrationJournalStore(layout: layout).read()
            ) { error in
                XCTAssertEqual(
                    error as? AppDataFailure,
                    .migrationFailed
                )
            }
        }
    }

    func testMissingPointerRejectsSchemaUpgradeJournalWithoutMutation()
        throws {
        let layout = try makeLayout()
        let sourceGenerationID = UUID()
        let targetGenerationID = UUID()
        let targetStoreURL = layout.storeURL(
            for: targetGenerationID
        )
        try FileManager.default.createDirectory(
            at: targetStoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("preserved-target".utf8).write(to: targetStoreURL)
        let digestBefore = try sha256(of: targetStoreURL)
        try MigrationJournalStore(layout: layout).write(
            MigrationJournal(
                targetGenerationID: targetGenerationID,
                origin: .schemaUpgrade,
                sourceGenerationID: sourceGenerationID,
                sourceSchemaVersion: "10.0.0",
                targetSchemaVersion: "11.0.0",
                phase: .prepared,
                updatedAt: Date(
                    timeIntervalSince1970: 1_800_200_010
                )
            )
        )

        XCTAssertThrowsError(
            try makeTestBootstrapper(layout: layout).open()
        ) { error in
            XCTAssertEqual(
                error as? AppDataFailure,
                .migrationFailed
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.pointerURL.path
            )
        )
        XCTAssertEqual(try sha256(of: targetStoreURL), digestBefore)
        XCTAssertEqual(
            try MigrationJournalStore(layout: layout).read().phase,
            .prepared
        )
    }

    func testPointerToMissingGenerationEntersRecoveryWithoutReplacement() throws {
        let layout = try makeLayout()
        let pointer = GenerationPointer(
            generationID: UUID(),
            origin: .existingGeneration,
            datasetID: UUID(),
            minimumFactCount: 0,
            minimumRevisionCount: 0,
            activatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try GenerationPointerStore(layout: layout).write(pointer)

        XCTAssertThrowsError(try makeTestBootstrapper(layout: layout).open()) { error in
            XCTAssertEqual(error as? AppDataFailure, .invalidGenerationPointer)
        }
        XCTAssertEqual(try GenerationPointerStore(layout: layout).read(), pointer)
        XCTAssertTrue(try directoryEntryNames(at: layout.generationsURL).isEmpty)
    }

    func testPointerWrittenBeforeActivatedJournalIsAuthoritativeOnRestart() throws {
        let layout = try makeLayout()
        try seedLegacyStore(at: layout.legacyStoreURL)
        let bootstrapper = makeTestBootstrapper(layout: layout)
        XCTAssertThrowsError(try bootstrapper.open(failAt: .afterValidationBeforePointer))
        let journal = try MigrationJournalStore(layout: layout).read()
        XCTAssertEqual(journal.phase, .validated)

        let storeURL = layout.storeURL(for: journal.targetGenerationID)
        var datasetID: UUID!
        var factCount = 0
        var revisionCount = 0
        try autoreleasepool {
            let container = try AppModelContainerFactory
                .makeReadOnlyDataControlContainer(at: storeURL)
            let context = ModelContext(container)
            datasetID = try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first).datasetID
            revisionCount = try context.fetchCount(FetchDescriptor<RecordRevision>())
            // The validated V12 generation has one revision for every
            // business fact.
            factCount = revisionCount
        }
        let pointer = GenerationPointer(
            generationID: journal.targetGenerationID,
            origin: .legacyAdoption,
            datasetID: datasetID,
            minimumFactCount: factCount,
            minimumRevisionCount: revisionCount,
            activatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try GenerationPointerStore(layout: layout).write(pointer)

        let reopened = try bootstrapper.open()

        XCTAssertEqual(reopened.generationID, journal.targetGenerationID)
        XCTAssertEqual(reopened.origin, .existingGeneration)
        XCTAssertEqual(try MigrationJournalStore(layout: layout).read().phase, .validated)
        XCTAssertEqual(
            try ModelContext(reopened.container).fetchCount(FetchDescriptor<HRTProfile>()),
            1
        )
    }

    func testPointerRejectsNegativeOrMismatchedFrozenCounts() throws {
        let layout = try makeLayout()
        let pointerStore = GenerationPointerStore(layout: layout)
        try FileManager.default.createDirectory(
            at: layout.pointerDirectoryURL,
            withIntermediateDirectories: true
        )
        let invalid = GenerationPointer(
                generationID: UUID(),
                origin: .newInstall,
                datasetID: UUID(),
                minimumFactCount: -1,
                minimumRevisionCount: 0,
                activatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        try JSONEncoder.unmanualFoundation
            .encode(invalid)
            .write(
                to: layout.pointerURL,
                options: .atomic
            )

        XCTAssertThrowsError(try pointerStore.read()) { error in
            XCTAssertEqual(error as? AppDataFailure, .invalidGenerationPointer)
        }
    }

    func testMissingPointerAndJournalWithExistingGenerationFailsClosed() throws {
        let layout = try makeLayout()
        let bootstrapper = makeTestBootstrapper(layout: layout)
        var preservedStoreURL: URL!
        try autoreleasepool {
            let opened = try bootstrapper.open()
            preservedStoreURL = opened.storeURL
            let context = ModelContext(opened.container)
            let metadata = try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first)
            let profile = HRTProfile(
                id: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
                startDate: Date(timeIntervalSince1970: 1_700_000_000),
                createdAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
            context.insert(profile)
            context.insert(
                RecordRevision(
                    recordKey: "HRTProfile:" + profile.id.uuidString.lowercased(),
                    recordType: "HRTProfile",
                    recordID: profile.id,
                    datasetID: metadata.datasetID,
                    localRevision: 1,
                    digestVersion: RecordDigestV1.version,
                    digestHex: try profileDigest(profile),
                    committedAt: Date(timeIntervalSince1970: 1_700_000_002)
                )
            )
            metadata.nextLocalRevision = 2
            try context.save()
        }
        let preservedHash = try sha256(of: preservedStoreURL)
        let generationsBefore = try directoryEntryNames(at: layout.generationsURL)
        try FileManager.default.removeItem(at: layout.pointerURL)
        try FileManager.default.removeItem(at: layout.journalURL)

        XCTAssertThrowsError(try bootstrapper.open()) { error in
            XCTAssertEqual(error as? AppDataFailure, .invalidGenerationPointer)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.pointerURL.path))
        XCTAssertEqual(try directoryEntryNames(at: layout.generationsURL), generationsBefore)
        XCTAssertEqual(try sha256(of: preservedStoreURL), preservedHash)
    }

    func testHiddenOnlyGenerationsEntryDoesNotTurnFirstInstallIntoRecovery() throws {
        let layout = try makeLayout()
        try FileManager.default.createDirectory(
            at: layout.generationsURL,
            withIntermediateDirectories: true
        )
        let hiddenMetadata = layout.generationsURL.appending(path: ".DS_Store")
        try Data("finder metadata".utf8).write(to: hiddenMetadata, options: .atomic)

        let opened = try makeTestBootstrapper(layout: layout).open()

        XCTAssertEqual(opened.origin, .newInstall)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hiddenMetadata.path))
        XCTAssertEqual(try GenerationPointerStore(layout: layout).read().generationID, opened.generationID)
    }

    func testLegacySidecarWithoutMainStoreFailsClosed() throws {
        let layout = try makeLayout()
        let orphanedWAL = URL(fileURLWithPath: layout.legacyStoreURL.path + "-wal")
        let bytes = Data("preserved legacy sidecar".utf8)
        try bytes.write(to: orphanedWAL, options: .atomic)

        XCTAssertThrowsError(try makeTestBootstrapper(layout: layout).open()) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.pointerURL.path))
        XCTAssertEqual(try Data(contentsOf: orphanedWAL), bytes)
        XCTAssertTrue(try directoryEntryNames(at: layout.generationsURL).isEmpty)
    }

    func testActivePointerRejectsTruncatedStoreWithoutReinitializingIt() throws {
        let layout = try makeLayout()
        let bootstrapper = makeTestBootstrapper(layout: layout)
        var storeURL: URL!
        try autoreleasepool {
            let opened = try bootstrapper.open()
            storeURL = opened.storeURL
        }
        let originalPointer = try GenerationPointerStore(layout: layout).read()

        try Data().write(to: storeURL)

        XCTAssertThrowsError(try bootstrapper.open()) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
        XCTAssertEqual(try Data(contentsOf: storeURL).count, 0)
        XCTAssertEqual(try GenerationPointerStore(layout: layout).read(), originalPointer)
    }

    func testActiveStoreRejectsOrphanRevisionThatMasksMissingFactRevision() throws {
        let layout = try makeLayout()
        let bootstrapper = makeTestBootstrapper(layout: layout)
        var storeURL: URL!
        try autoreleasepool {
            let opened = try bootstrapper.open()
            storeURL = opened.storeURL
            let context = ModelContext(opened.container)
            let metadata = try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first)
            let profileID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
            context.insert(
                HRTProfile(
                    id: profileID,
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_001)
                )
            )
            context.insert(
                RecordRevision(
                    recordKey: "HRTProfile:" + profileID.uuidString.lowercased(),
                    recordType: "HRTProfile",
                    recordID: profileID,
                    datasetID: metadata.datasetID,
                    localRevision: 1,
                    digestVersion: RecordDigestV1.version,
                    digestHex: "valid-test-digest",
                    committedAt: Date(timeIntervalSince1970: 1_700_000_002)
                )
            )
            try context.save()
        }

        try autoreleasepool {
            let container = try AppModelContainerFactory
                .makeDataControlContainer(at: storeURL)
            let context = ModelContext(container)
            let metadata = try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first)
            let validRevision = try XCTUnwrap(context.fetch(FetchDescriptor<RecordRevision>()).first)
            context.delete(validRevision)
            let orphanID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
            context.insert(
                RecordRevision(
                    recordKey: "HRTProfile:" + orphanID.uuidString.lowercased(),
                    recordType: "HRTProfile",
                    recordID: orphanID,
                    datasetID: metadata.datasetID,
                    localRevision: 2,
                    digestVersion: RecordDigestV1.version,
                    digestHex: "orphan-test-digest",
                    committedAt: Date(timeIntervalSince1970: 1_700_000_003)
                )
            )
            try context.save()
        }

        XCTAssertThrowsError(try bootstrapper.open()) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testActivePointerRejectsLegacySchemaStoreWithoutBridgeTables() throws {
        let layout = try makeLayout()
        let generationID = UUID()
        let storeURL = layout.storeURL(for: generationID)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try seedLegacyStore(at: storeURL)
        let storeDigestBefore = try sha256(of: storeURL)
        let pointer = GenerationPointer(
            generationID: generationID,
            origin: .existingGeneration,
            datasetID: UUID(),
            minimumFactCount: 1,
            minimumRevisionCount: 1,
            activatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try GenerationPointerStore(layout: layout).write(pointer)

        XCTAssertThrowsError(try makeTestBootstrapper(layout: layout).open()) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
        XCTAssertEqual(try sha256(of: storeURL), storeDigestBefore)
        XCTAssertEqual(try GenerationPointerStore(layout: layout).read(), pointer)
    }

    func testActiveStoreRejectsRevisionAllocatorRollback() throws {
        let layout = try makeLayout()
        let bootstrapper = makeTestBootstrapper(layout: layout)
        try autoreleasepool {
            let opened = try bootstrapper.open()
            let context = ModelContext(opened.container)
            let metadata = try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first)
            let profileID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
            context.insert(
                HRTProfile(
                    id: profileID,
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_001)
                )
            )
            context.insert(
                RecordRevision(
                    recordKey: "HRTProfile:" + profileID.uuidString.lowercased(),
                    recordType: "HRTProfile",
                    recordID: profileID,
                    datasetID: metadata.datasetID,
                    localRevision: 1,
                    digestVersion: RecordDigestV1.version,
                    digestHex: "allocator-test-digest",
                    committedAt: Date(timeIntervalSince1970: 1_700_000_002)
                )
            )
            metadata.nextLocalRevision = 1
            try context.save()
        }

        XCTAssertThrowsError(try bootstrapper.open()) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testActiveStoreRejectsRevisionAllocatorAtInt64Maximum() throws {
        let layout = try makeLayout()
        let bootstrapper = makeTestBootstrapper(layout: layout)
        try autoreleasepool {
            let opened = try bootstrapper.open()
            let context = ModelContext(opened.container)
            let metadata = try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first)
            metadata.nextLocalRevision = Int64.max
            try context.save()
        }

        XCTAssertThrowsError(try bootstrapper.open()) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testActiveStoreRejectsFactWhoseFieldsNoLongerMatchRevisionDigest() throws {
        let layout = try makeLayout()
        let bootstrapper = makeTestBootstrapper(layout: layout)
        var storeURL: URL!
        try autoreleasepool {
            let opened = try bootstrapper.open()
            storeURL = opened.storeURL
            let context = ModelContext(opened.container)
            let metadata = try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first)
            let profile = HRTProfile(
                id: UUID(uuidString: "50000000-0000-0000-0000-000000000005")!,
                startDate: Date(timeIntervalSince1970: 1_700_000_000),
                createdAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
            context.insert(profile)
            context.insert(
                RecordRevision(
                    recordKey: "HRTProfile:" + profile.id.uuidString.lowercased(),
                    recordType: "HRTProfile",
                    recordID: profile.id,
                    datasetID: metadata.datasetID,
                    localRevision: 1,
                    digestVersion: RecordDigestV1.version,
                    digestHex: try profileDigest(profile),
                    committedAt: Date(timeIntervalSince1970: 1_700_000_002)
                )
            )
            metadata.nextLocalRevision = 2
            try context.save()
        }
        try autoreleasepool {
            let container = try AppModelContainerFactory
                .makeDataControlContainer(at: storeURL)
            let context = ModelContext(container)
            let profile = try XCTUnwrap(context.fetch(FetchDescriptor<HRTProfile>()).first)
            profile.startDate = Date(timeIntervalSince1970: 1_800_000_000)
            try context.save()
        }

        XCTAssertThrowsError(try bootstrapper.open()) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testActiveV5GenerationRejectsOrphanReceiptsForEveryV5Type() throws {
        for recordType in [
            "LabSampleRecord",
            "StatusMetricDefinitionRecord",
            "StatusObservationRecord",
            "AttachmentRecord"
        ] {
            let layout = try makeLayout()
            let bootstrapper = makeTestBootstrapper(layout: layout)
            var storeURL: URL!
            try autoreleasepool {
                let opened = try bootstrapper.open()
                storeURL = opened.storeURL
            }
            try autoreleasepool {
                let container = try AppModelContainerFactory
                    .makeDataControlContainer(at: storeURL)
                let context = ModelContext(container)
                let metadata = try XCTUnwrap(
                    context.fetch(FetchDescriptor<DatasetMetadata>()).first
                )
                let ledger = try XCTUnwrap(
                    context.fetch(
                        FetchDescriptor<OperationReceiptLedgerRecord>()
                    ).first
                )
                let committedAt = Date(
                    timeIntervalSince1970: 1_735_732_800
                )
                let receipt = OperationReceiptRecord(
                    operationID: UUID(),
                    commandDigest: String(repeating: "a", count: 64),
                    resultRecordType: recordType,
                    resultRecordID: UUID(),
                    committedAt: committedAt
                )
                let existingReceipts = try context.fetch(
                    FetchDescriptor<OperationReceiptRecord>()
                )
                let localRevision = metadata.nextLocalRevision
                metadata.nextLocalRevision += 1
                context.insert(receipt)
                context.insert(
                    RecordRevision(
                        recordKey: "OperationReceiptRecord:"
                            + receipt.operationID.uuidString.lowercased(),
                        recordType: "OperationReceiptRecord",
                        recordID: receipt.operationID,
                        datasetID: metadata.datasetID,
                        localRevision: localRevision,
                        digestVersion: RecordDigestV1.version,
                        digestHex: try RecordDigestV1.sha256Hex(
                            recordType: "OperationReceiptRecord",
                            recordID: receipt.operationID,
                            fields: try TodayExecutionDigestV1
                                .operationReceipt(receipt)
                        ),
                        committedAt: committedAt
                    )
                )
                let allReceipts = existingReceipts + [receipt]
                ledger.receiptCount = allReceipts.count
                ledger.receiptSetDigest = try TodayExecutionDigestV1
                    .receiptSetDigest(allReceipts)
                ledger.updatedAt = committedAt
                let ledgerKey = "OperationReceiptLedgerRecord:"
                    + TodayExecutionDigestV1.receiptLedgerID
                        .uuidString.lowercased()
                let ledgerRevision = try XCTUnwrap(
                    context.fetch(
                        FetchDescriptor<RecordRevision>(
                            predicate: #Predicate {
                                $0.recordKey == ledgerKey
                            }
                        )
                    ).first
                )
                ledgerRevision.localRevision = localRevision
                ledgerRevision.digestHex = try RecordDigestV1.sha256Hex(
                    recordType: "OperationReceiptLedgerRecord",
                    recordID: TodayExecutionDigestV1.receiptLedgerID,
                    fields: TodayExecutionDigestV1
                        .operationReceiptLedger(ledger)
                )
                ledgerRevision.committedAt = committedAt
                try context.save()
            }

            XCTAssertThrowsError(try bootstrapper.open(), recordType) {
                error in
                XCTAssertEqual(
                    error as? AppDataFailure,
                    .corruptionSuspected,
                    recordType
                )
            }
        }
    }

    func testActiveV7GenerationRejectsCountdownStateEventReminderAndReceiptTampering()
        throws
    {
        for tamper in CountdownTamper.allCases {
            let layout = try makeLayout()
            try seedLegacyStore(
                at: layout.legacyStoreURL,
                includeCountdown: true
            )
            let bootstrapper = makeTestBootstrapper(layout: layout)
            var originalPointer: GenerationPointer!
            try autoreleasepool {
                let opened = try bootstrapper.open()
                originalPointer = try GenerationPointerStore(
                    layout: layout
                ).read()
                let context = ModelContext(opened.container)
                switch tamper {
                case .state:
                    let state = try XCTUnwrap(
                        context.fetch(
                            FetchDescriptor<CountdownStateRecord>()
                        ).first
                    )
                    state.title = "tampered"
                case .event:
                    let event = try XCTUnwrap(
                        context.fetch(
                            FetchDescriptor<
                                CountdownLifecycleEventRecord
                            >()
                        ).first
                    )
                    event.previousEventID = event.id
                case .reminder:
                    let reminder = try XCTUnwrap(
                        context.fetch(
                            FetchDescriptor<
                                CountdownReminderRuleRecord
                            >()
                        ).first
                    )
                    reminder.contentVersion = "tampered"
                case .receipt:
                    let event = try XCTUnwrap(
                        context.fetch(
                            FetchDescriptor<
                                CountdownLifecycleEventRecord
                            >()
                        ).first
                    )
                    let operationID = event.operationID
                    let receipt = try XCTUnwrap(
                        context.fetch(
                            FetchDescriptor<OperationReceiptRecord>(
                                predicate: #Predicate {
                                    $0.operationID == operationID
                                }
                            )
                        ).first
                    )
                    receipt.resultRecordID = UUID()
                }
                try context.save()
            }

            XCTAssertThrowsError(try bootstrapper.open(), tamper.rawValue) {
                error in
                XCTAssertEqual(
                    error as? AppDataFailure,
                    .corruptionSuspected,
                    tamper.rawValue
                )
            }
            XCTAssertEqual(
                try GenerationPointerStore(layout: layout).read(),
                originalPointer
            )
        }
    }

    func testActiveV7GenerationRejectsSelfConsistentCountdownStateWhoseLatestEventTimeDisagrees()
        throws
    {
        let layout = try makeLayout()
        try seedLegacyStore(
            at: layout.legacyStoreURL,
            includeCountdown: true
        )
        let bootstrapper = makeTestBootstrapper(layout: layout)
        var originalPointer: GenerationPointer!
        try autoreleasepool {
            let opened = try bootstrapper.open()
            originalPointer = try GenerationPointerStore(
                layout: layout
            ).read()
            let context = ModelContext(opened.container)
            let state = try XCTUnwrap(
                context.fetch(
                    FetchDescriptor<CountdownStateRecord>()
                ).first
            )
            state.updatedAt = state.updatedAt.addingTimeInterval(60)
            let stateID = state.id
            let revision = try XCTUnwrap(
                context.fetch(
                    FetchDescriptor<RecordRevision>(
                        predicate: #Predicate {
                            $0.recordType == "CountdownStateRecord"
                                && $0.recordID == stateID
                        }
                    )
                ).first
            )
            revision.digestHex = try RecordDigestV1.sha256Hex(
                recordType: "CountdownStateRecord",
                recordID: state.id,
                fields: CountdownDigestV1.state(state)
            )
            try context.save()
        }

        XCTAssertThrowsError(try bootstrapper.open()) { error in
            XCTAssertEqual(
                error as? AppDataFailure,
                .corruptionSuspected
            )
        }
        XCTAssertEqual(
            try GenerationPointerStore(layout: layout).read(),
            originalPointer
        )
    }

    func testNestedProtectedDataFailureDuringMigrationKeepsItsClassification() throws {
        let layout = try makeLayout()

        XCTAssertThrowsError(
            try makeTestBootstrapper(layout: layout)
                .open(failAt: .duringValidationWithNestedProtectedDataError)
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .protectedDataUnavailable)
        }
    }

    func testValidatedGenerationWithMissingFactIsRejectedBeforePointerActivation() throws {
        let layout = try makeLayout()
        try seedLegacyStore(at: layout.legacyStoreURL)
        let bootstrapper = makeTestBootstrapper(layout: layout)
        XCTAssertThrowsError(try bootstrapper.open(failAt: .afterValidationBeforePointer))
        let journal = try MigrationJournalStore(layout: layout).read()

        try autoreleasepool {
            let container = try AppModelContainerFactory.makeDataControlContainer(
                at: layout.storeURL(for: journal.targetGenerationID)
            )
            let context = ModelContext(container)
            let profile = try XCTUnwrap(context.fetch(FetchDescriptor<HRTProfile>()).first)
            context.delete(profile)
            try context.save()
        }

        XCTAssertThrowsError(try bootstrapper.open()) { error in
            XCTAssertEqual(error as? AppDataFailure, .migrationFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.pointerURL.path))
    }

    func testSystemManagedBackupPolicyDoesNotSetExclusionAndAuditNamesPhysicalFiles() throws {
        let layout = try makeLayout()
        let opened = try makeTestBootstrapper(
            layout: layout,
            backupPolicy: .systemManaged
        ).open()

        let report = try StoreFileProtectionAuditor(
            backupPolicy: .systemManaged,
            verificationMode: .simulatorTestHarness
        ).hardenAndInspect(
            storeURL: opened.storeURL,
            resources: layout.protectionResources(for: opened.generationID)
        )

        XCTAssertTrue(report.entries.contains { $0.role == .store && $0.exists })
        XCTAssertTrue(report.entries.contains { $0.role == .pointer && $0.exists })
        XCTAssertFalse(report.entries.contains { $0.isExcludedFromBackup == true })
        XCTAssertTrue(report.isAcceptableForCurrentPlatform)
#if targetEnvironment(simulator)
        XCTAssertTrue(report.requiresPhysicalDeviceValidation)
#endif
    }

    func testExcludedBackupPolicyIsAppliedAndReadBackAcrossEveryRequiredPath() throws {
        let layout = try makeLayout()
        let opened = try makeTestBootstrapper(
            layout: layout,
            backupPolicy: .excluded
        ).open()
        let requiredRoles: Set<StorePhysicalFileRole> = [
            .rootDirectory,
            .generationsDirectory,
            .pointerDirectory,
            .recoveryDirectory,
            .store,
            .wal,
            .shm,
            .generationDirectory,
            .storeDirectory,
            .pointer,
            .journal
        ]
        let requiredEntries = opened.protectionReport.entries.filter {
            requiredRoles.contains($0.role)
        }

        XCTAssertEqual(Set(requiredEntries.map(\.role)), requiredRoles)
        XCTAssertTrue(requiredEntries.allSatisfy(\.exists))
        XCTAssertTrue(requiredEntries.allSatisfy { $0.isExcludedFromBackup == true })
        XCTAssertEqual(opened.protectionReport.backupPolicy, .excluded)
        XCTAssertTrue(opened.protectionReport.isAcceptableForCurrentPlatform)
    }

    func testSwitchingBackToSystemManagedClearsPriorBackupExclusion() throws {
        let layout = try makeLayout()
        let opened = try makeTestBootstrapper(
            layout: layout,
            backupPolicy: .excluded
        ).open()

        let report = try StoreFileProtectionAuditor(
            backupPolicy: .systemManaged,
            verificationMode: .simulatorTestHarness
        ).hardenAndInspect(
            storeURL: opened.storeURL,
            resources: layout.protectionResources(for: opened.generationID)
        )

        XCTAssertTrue(report.entries.filter(\.exists).allSatisfy { $0.isExcludedFromBackup != true })
        XCTAssertTrue(report.isAcceptableForCurrentPlatform)
    }

    func testExcludedLegacyAdoptionAlsoExcludesEveryPreservedSourceBundlePart() throws {
        let layout = try makeLayout()
        try seedLegacyStore(at: layout.legacyStoreURL)

        _ = try makeTestBootstrapper(
            layout: layout,
            backupPolicy: .excluded
        ).open()

        let sourceParts = ["", "-wal", "-shm"]
            .map { URL(fileURLWithPath: layout.legacyStoreURL.path + $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertFalse(sourceParts.isEmpty)
        for sourcePart in sourceParts {
            let values = try sourcePart.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true, sourcePart.lastPathComponent)
        }
    }

    func testSwitchingLegacyAdoptionToSystemManagedIncludesEveryPreservedSourceBundlePart() throws {
        let layout = try makeLayout()
        try seedLegacyStore(at: layout.legacyStoreURL)

        try autoreleasepool {
            _ = try makeTestBootstrapper(
                layout: layout,
                backupPolicy: .excluded
            ).open()
        }
        try autoreleasepool {
            _ = try makeTestBootstrapper(
                layout: layout,
                backupPolicy: .systemManaged
            ).open()
        }

        let sourceParts = ["", "-wal", "-shm"]
            .map { URL(fileURLWithPath: layout.legacyStoreURL.path + $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertFalse(sourceParts.isEmpty)
        for sourcePart in sourceParts {
            let values = try sourcePart.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, false, sourcePart.lastPathComponent)
        }
    }

    func testObservableProtectionFailureCannotPassTheReadinessGate() {
        let report = StoreFileProtectionReport(
            entries: [
                StoreFileAuditEntry(
                    role: .store,
                    exists: true,
                    usesCompleteProtection: false,
                    isExcludedFromBackup: false,
                    hardeningError: false
                )
            ],
            requiresPhysicalDeviceValidation: true
        )

        XCTAssertFalse(report.isAcceptableForCurrentPlatform)
    }

    func testProtectionReportMissingRequiredRolesCannotPassTheReadinessGate() {
        let completeEntry: (StorePhysicalFileRole) -> StoreFileAuditEntry = { role in
            StoreFileAuditEntry(
                role: role,
                exists: true,
                usesCompleteProtection: true,
                isExcludedFromBackup: false,
                hardeningError: false
            )
        }
        let report = StoreFileProtectionReport(
            entries: [
                completeEntry(.store),
                completeEntry(.generationDirectory),
                completeEntry(.storeDirectory),
                completeEntry(.pointer)
            ],
            requiresPhysicalDeviceValidation: true
        )

        XCTAssertFalse(report.isAcceptableForCurrentPlatform)
    }

    func testProtectionReportCannotPassBeforeWalAndShmArePresentAndAudited() {
        let completeEntry: (StorePhysicalFileRole) -> StoreFileAuditEntry = { role in
            StoreFileAuditEntry(
                role: role,
                exists: true,
                usesCompleteProtection: true,
                isExcludedFromBackup: false,
                hardeningError: false
            )
        }
        let missingEntry: (StorePhysicalFileRole) -> StoreFileAuditEntry = { role in
            StoreFileAuditEntry(
                role: role,
                exists: false,
                usesCompleteProtection: nil,
                isExcludedFromBackup: nil,
                hardeningError: false
            )
        }
        let report = StoreFileProtectionReport(
            entries: [
                completeEntry(.rootDirectory),
                completeEntry(.generationsDirectory),
                completeEntry(.pointerDirectory),
                completeEntry(.recoveryDirectory),
                completeEntry(.store),
                missingEntry(.wal),
                missingEntry(.shm),
                completeEntry(.generationDirectory),
                completeEntry(.storeDirectory),
                completeEntry(.pointer),
                completeEntry(.journal)
            ],
            requiresPhysicalDeviceValidation: true
        )

        XCTAssertFalse(report.isAcceptableForCurrentPlatform)
    }

    func testExcludedBackupPolicyCannotPassWhenAnyExistingPathReadsBackAsIncluded() {
        let completeExcludedEntry: (StorePhysicalFileRole) -> StoreFileAuditEntry = { role in
            StoreFileAuditEntry(
                role: role,
                exists: true,
                usesCompleteProtection: true,
                isExcludedFromBackup: true,
                hardeningError: false
            )
        }
        let report = StoreFileProtectionReport(
            entries: [
                completeExcludedEntry(.rootDirectory),
                completeExcludedEntry(.generationsDirectory),
                completeExcludedEntry(.pointerDirectory),
                completeExcludedEntry(.recoveryDirectory),
                completeExcludedEntry(.store),
                completeExcludedEntry(.wal),
                completeExcludedEntry(.shm),
                completeExcludedEntry(.generationDirectory),
                completeExcludedEntry(.storeDirectory),
                completeExcludedEntry(.pointer),
                StoreFileAuditEntry(
                    role: .journal,
                    exists: true,
                    usesCompleteProtection: true,
                    isExcludedFromBackup: false,
                    hardeningError: false
                )
            ],
            requiresPhysicalDeviceValidation: true,
            backupPolicy: .excluded
        )

        XCTAssertFalse(report.isAcceptableForCurrentPlatform)
    }

    func testSystemManagedBackupPolicyCannotPassWhenAnyExistingPathRemainsExcluded() {
        let requiredRoles: [StorePhysicalFileRole] = [
            .rootDirectory,
            .generationsDirectory,
            .pointerDirectory,
            .recoveryDirectory,
            .store,
            .wal,
            .shm,
            .generationDirectory,
            .storeDirectory,
            .pointer,
            .journal
        ]
        let report = StoreFileProtectionReport(
            entries: requiredRoles.map { role in
                StoreFileAuditEntry(
                    role: role,
                    exists: true,
                    usesCompleteProtection: true,
                    isExcludedFromBackup: true,
                    hardeningError: false
                )
            },
            requiresPhysicalDeviceValidation: true,
            backupPolicy: .systemManaged
        )

        XCTAssertFalse(report.isAcceptableForCurrentPlatform)
    }

    func testProtectionReadbackErrorCannotPassTheReadinessGate() {
        let requiredRoles: [StorePhysicalFileRole] = [
            .store, .generationDirectory, .storeDirectory, .pointer, .journal
        ]
        let report = StoreFileProtectionReport(
            entries: requiredRoles.map { role in
                StoreFileAuditEntry(
                    role: role,
                    exists: true,
                    usesCompleteProtection: nil,
                    isExcludedFromBackup: nil,
                    hardeningError: false,
                    inspectionError: true
                )
            },
            requiresPhysicalDeviceValidation: true
        )

        XCTAssertFalse(report.isAcceptableForCurrentPlatform)
    }

    private enum CountdownTamper: String, CaseIterable {
        case state
        case event
        case reminder
        case receipt
    }

    private func seedLegacyStore(
        at url: URL,
        includeCountdown: Bool = false
    ) throws {
        let stagingDirectory = url.deletingLastPathComponent()
            .appending(path: "Seed-" + UUID().uuidString, directoryHint: .isDirectory)
        let stagingURL = stagingDirectory.appending(path: url.lastPathComponent)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        try autoreleasepool {
            let container = try LegacyUnversionedStoreFactory.makeContainer(at: stagingURL)
            let context = ModelContext(container)
            context.insert(
                HRTProfile(
                    id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_001)
                )
            )
            if includeCountdown {
                context.insert(
                    CountdownRecord(
                        id: UUID(
                            uuidString:
                                "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
                        )!,
                        title: "迁移测试目标",
                        targetDate: Date(
                            timeIntervalSince1970: 1_800_000_000
                        ),
                        createdAt: Date(
                            timeIntervalSince1970: 1_700_000_002
                        )
                    )
                )
            }
            try context.save()

            // Snapshot while the seed container is still retained and idle.
            // Its eventual deinit may checkpoint WAL bytes into the staging
            // main file; the independent fixture must not inherit that race.
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: stagingURL.path + suffix)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let destination = URL(fileURLWithPath: url.path + suffix)
                try FileManager.default.copyItem(at: source, to: destination)
            }
        }
    }

    private func frozenLegacyFixtureURL(suffix: String) throws -> URL {
        let resourceExtension = "sqlite" + suffix
        return try XCTUnwrap(
            Bundle(for: StoreBootstrapTests.self).url(
                forResource: "legacy-unversioned",
                withExtension: resourceExtension
            ),
            "Missing frozen legacy fixture resource legacy-unversioned.\(resourceExtension)"
        )
    }

    private func makeLayout() throws -> AppDataStoreLayout {
        let applicationSupport = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        // Fresh Simulator XCTest containers mark their Application Support
        // ancestor as excluded. Production app containers do not rely on this
        // test-host quirk, so clear it before exercising `.systemManaged`.
        var applicationSupportValues = URLResourceValues()
        applicationSupportValues.isExcludedFromBackup = false
        var mutableApplicationSupport = applicationSupport
        try mutableApplicationSupport.setResourceValues(applicationSupportValues)
        let root = applicationSupport
            .appending(path: "UnmanualStoreBootstrapTests", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let legacy = root
            .appending(path: "Legacy", directoryHint: .isDirectory)
            .appending(path: "default.store")
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return AppDataStoreLayout(rootURL: root.appending(path: "Managed", directoryHint: .isDirectory), legacyStoreURL: legacy)
    }

    private func makeTestBootstrapper(
        layout: AppDataStoreLayout,
        backupPolicy: SystemBackupPolicy = .production
    ) -> AppDataStoreBootstrapper {
        AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: backupPolicy,
            fileProtectionVerificationMode: .simulatorTestHarness
        )
    }

    private struct V4SourceFixture {
        let generationID: UUID
        let storeURL: URL
        let durableHashes: [String: String]
    }

    private struct V5SourceFixture {
        let generationID: UUID
        let storeURL: URL
        let durableHashes: [String: String]
        let activeCountdownID: UUID?
        let archivedCountdownID: UUID?
        let activeCreatedAt: Date?
        let archivedAt: Date?
    }

    private struct V6SourceFixture {
        let generationID: UUID
        let storeURL: URL
        let countdownID: UUID
    }

    private struct V7SourceFixture {
        let generationID: UUID
        let storeURL: URL
        let durableHashes: [String: String]
        let preexistingGenerationNames: [String]
    }

    private struct V8SourceFixture {
        let generationID: UUID
        let storeURL: URL
        let durableHashes: [String: String]
    }

    private struct V9SourceFixture {
        let generationID: UUID
        let storeURL: URL
        let durableHashes: [String: String]
    }

    private struct V10SourceFixture {
        let generationID: UUID
        let storeURL: URL
        let durableHashes: [String: String]
    }

    private struct V11SourceFixture {
        let generationID: UUID
        let storeURL: URL
        let durableHashes: [String: String]
    }

    private func seedActiveV4Generation(
        in layout: AppDataStoreLayout
    ) throws -> V4SourceFixture {
        let generationID = UUID()
        let storeURL = layout.storeURL(for: generationID)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var datasetID: UUID!
        var factCount = 0
        var revisionCount = 0
        try autoreleasepool {
            let container = try AppModelContainerFactory.makeTodayContainer(
                at: storeURL
            )
            _ = try LegacyV1Backfill.run(in: container)
            _ = try CoreTimeRegimenBackfill.run(
                in: container,
                assumedTimeZoneIdentifier: "UTC"
            )
            _ = try TodayExecutionBackfill.run(in: container)
            let context = ModelContext(container)
            datasetID = try XCTUnwrap(
                context.fetch(FetchDescriptor<DatasetMetadata>()).first
            ).datasetID
            revisionCount = try context.fetchCount(
                FetchDescriptor<RecordRevision>()
            )
            factCount = revisionCount
        }
        try GenerationPointerStore(layout: layout).write(
            GenerationPointer(
                generationID: generationID,
                schemaVersion: "4.0.0",
                origin: .newInstall,
                datasetID: datasetID,
                minimumFactCount: factCount,
                minimumRevisionCount: revisionCount
            )
        )
        try MigrationJournalStore(layout: layout).write(
            MigrationJournal(
                targetGenerationID: generationID,
                origin: .newInstall,
                phase: .activated
            )
        )
        _ = try StoreFileProtectionAuditor(
            backupPolicy: .systemManaged,
            verificationMode: .simulatorTestHarness
        ).hardenAndInspect(
            storeURL: storeURL,
            resources: layout.protectionResources(for: generationID)
        )
        return V4SourceFixture(
            generationID: generationID,
            storeURL: storeURL,
            durableHashes: try durableStoreBundleHashes(at: storeURL)
        )
    }

    private func seedActiveV5Generation(
        in layout: AppDataStoreLayout,
        includeFractionalCountdowns: Bool = false
    ) throws -> V5SourceFixture {
        let generationID = UUID()
        let storeURL = layout.storeURL(for: generationID)
        let stagingDirectory = layout.rootURL
            .appending(
                path: "V5Seed-" + UUID().uuidString,
                directoryHint: .isDirectory
            )
        let stagingURL = stagingDirectory
            .appending(path: "user.sqlite")
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        var datasetID: UUID!
        var factCount = 0
        var revisionCount = 0
        let activeCountdownID = includeFractionalCountdowns ? UUID() : nil
        let archivedCountdownID = includeFractionalCountdowns ? UUID() : nil
        let activeCreatedAt = includeFractionalCountdowns
            ? Date(timeIntervalSince1970: 1_700_000_000.25)
            : nil
        let archivedAt = includeFractionalCountdowns
            ? Date(timeIntervalSince1970: 1_700_086_400.75)
            : nil
        try autoreleasepool {
            let container = try AppModelContainerFactory
                .makePersonalTimelineContainer(at: stagingURL)
            let context = ModelContext(container)
            if let activeCountdownID,
               let archivedCountdownID,
               let activeCreatedAt,
               let archivedAt {
                context.insert(
                    CountdownRecord(
                        id: activeCountdownID,
                        title: "V5 亚秒当前项",
                        targetDate: activeCreatedAt
                            .addingTimeInterval(172_800),
                        createdAt: activeCreatedAt
                    )
                )
                context.insert(
                    CountdownRecord(
                        id: archivedCountdownID,
                        title: "V5 亚秒归档项",
                        targetDate: archivedAt
                            .addingTimeInterval(-86_400),
                        createdAt: archivedAt
                            .addingTimeInterval(-172_800),
                        archivedAt: archivedAt
                    )
                )
                try context.save()
            }
            _ = try LegacyV1Backfill.run(in: container)
            _ = try CoreTimeRegimenBackfill.run(
                in: container,
                assumedTimeZoneIdentifier: "UTC"
            )
            _ = try TodayExecutionBackfill.run(in: container)
            _ = try PersonalTimelineBackfill.run(in: container)
            datasetID = try XCTUnwrap(
                context.fetch(FetchDescriptor<DatasetMetadata>()).first
            ).datasetID
            revisionCount = try context.fetchCount(
                FetchDescriptor<RecordRevision>()
            )
            factCount = revisionCount

            // Freeze an independent source while the writable seed container
            // is retained and idle. Its eventual deinit may checkpoint WAL
            // bytes into the staging main file, but cannot mutate this copy.
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(
                    fileURLWithPath: stagingURL.path + suffix
                )
                guard FileManager.default.fileExists(
                    atPath: source.path
                ) else {
                    continue
                }
                let destination = URL(
                    fileURLWithPath: storeURL.path + suffix
                )
                try FileManager.default.copyItem(
                    at: source,
                    to: destination
                )
            }
        }
        try GenerationPointerStore(layout: layout).write(
            GenerationPointer(
                generationID: generationID,
                schemaVersion: "5.0.0",
                origin: .newInstall,
                datasetID: datasetID,
                minimumFactCount: factCount,
                minimumRevisionCount: revisionCount
            )
        )
        try MigrationJournalStore(layout: layout).write(
            MigrationJournal(
                targetGenerationID: generationID,
                origin: .newInstall,
                phase: .activated
            )
        )
        _ = try StoreFileProtectionAuditor(
            backupPolicy: .systemManaged,
            verificationMode: .simulatorTestHarness
        ).hardenAndInspect(
            storeURL: storeURL,
            resources: layout.protectionResources(for: generationID)
        )
        return V5SourceFixture(
            generationID: generationID,
            storeURL: storeURL,
            durableHashes: try durableStoreBundleHashes(at: storeURL),
            activeCountdownID: activeCountdownID,
            archivedCountdownID: archivedCountdownID,
            activeCreatedAt: activeCreatedAt,
            archivedAt: archivedAt
        )
    }

    private func addV5JourneyAttachment(
        payload: Data,
        generationID: UUID,
        storeURL: URL,
        layout: AppDataStoreLayout
    ) async throws -> PreparedAttachmentMetadata {
        let fileStore = AttachmentFileStore(
            rootURL: layout.generationDirectoryURL(for: generationID)
                .appendingPathComponent("Files", isDirectory: true)
        )
        let staged = try fileStore.stage(
            data: payload,
            attachmentID: UUID(),
            originalFilename: "v5-report.pdf",
            typeIdentifier: "com.adobe.pdf"
        )
        _ = try fileStore.commit(staged)
        let metadata = PreparedAttachmentMetadata(staged)
        let container = try AppModelContainerFactory
            .makePersonalTimelineContainer(at: storeURL)
        let writer = AppWriteActor(modelContainer: container)
        try await writer.addJourneyEntry(
            AddJourneyEntryCommand(
                text: "V5 附件迁移",
                kind: .moment,
                occurredAt: Date(timeIntervalSince1970: 1_735_689_600),
                regimenVersionID: nil,
                timeZoneIdentifier: "UTC",
                committedAt: Date(timeIntervalSince1970: 1_735_689_601),
                attachments: [metadata]
            )
        )
        try fileStore.markMetadataCommitted(metadata)
        return metadata
    }

    private func addV7JourneyAttachment(
        payload: Data,
        generationID: UUID,
        storeURL: URL,
        layout: AppDataStoreLayout
    ) async throws -> PreparedAttachmentMetadata {
        let fileStore = AttachmentFileStore(
            rootURL: layout.generationDirectoryURL(for: generationID)
                .appendingPathComponent("Files", isDirectory: true)
        )
        let staged = try fileStore.stage(
            data: payload,
            attachmentID: UUID(),
            originalFilename: "v7-report.pdf",
            typeIdentifier: "com.adobe.pdf"
        )
        _ = try fileStore.commit(staged)
        let metadata = PreparedAttachmentMetadata(staged)
        let container = try AppModelContainerFactory
            .makeV7CountdownIntegrityContainer(at: storeURL)
        let writer = AppWriteActor(modelContainer: container)
        try await writer.addJourneyEntry(
            AddJourneyEntryCommand(
                text: "V7 附件迁移",
                kind: .moment,
                occurredAt: Date(timeIntervalSince1970: 1_735_689_600),
                regimenVersionID: nil,
                timeZoneIdentifier: "UTC",
                committedAt: Date(timeIntervalSince1970: 1_735_689_601),
                attachments: [metadata]
            )
        )
        try fileStore.markMetadataCommitted(metadata)
        return metadata
    }

    private func seedActiveV6GenerationWithEnabledReminder(
        in layout: AppDataStoreLayout
    ) throws -> V6SourceFixture {
        let generationID = UUID()
        let storeURL = layout.storeURL(for: generationID)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let countdownID = UUID()
        var datasetID: UUID!
        var factCount = 0
        var revisionCount = 0
        try autoreleasepool {
            let container = try v6FixtureStep("open frozen V6") {
                try AppModelContainerFactory
                    .makeV6CountdownLifecycleContainer(at: storeURL)
            }
            let seedContext = ModelContext(container)
            seedContext.insert(
                CountdownRecord(
                    id: countdownID,
                    title: "V6 已启用提醒",
                    targetDate: Date(
                        timeIntervalSince1970: 1_900_000_000
                    ),
                    createdAt: Date(
                        timeIntervalSince1970: 1_700_000_000.25
                    )
                )
            )
            try seedContext.save()
            _ = try v6FixtureStep("legacy backfill") {
                try LegacyV1Backfill.run(in: container)
            }
            _ = try v6FixtureStep("core backfill") {
                try CoreTimeRegimenBackfill.run(
                    in: container,
                    assumedTimeZoneIdentifier: "UTC"
                )
            }
            _ = try v6FixtureStep("today backfill") {
                try TodayExecutionBackfill.run(in: container)
            }
            _ = try v6FixtureStep("timeline backfill") {
                try PersonalTimelineBackfill.run(in: container)
            }
            _ = try v6FixtureStep("countdown backfill") {
                try CountdownLifecycleBackfill.run(
                    in: container,
                    now: Date(timeIntervalSince1970: 1_750_000_000),
                    includeIntegrityFacts: false
                )
            }
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let state = try XCTUnwrap(
                context.fetch(
                    FetchDescriptor<CountdownStateRecord>(
                        predicate: #Predicate { $0.id == countdownID }
                    )
                ).first
            )
            let eventID = state.latestEventID
            let event = try XCTUnwrap(
                context.fetch(
                    FetchDescriptor<CountdownLifecycleEventRecord>(
                        predicate: #Predicate { $0.id == eventID }
                    )
                ).first
            )
            let reminder = try XCTUnwrap(
                context.fetch(
                    FetchDescriptor<CountdownReminderRuleRecord>(
                        predicate: #Predicate {
                            $0.countdownID == countdownID
                        }
                    )
                ).first
            )
            let legacy = try XCTUnwrap(
                context.fetch(
                    FetchDescriptor<CountdownRecord>(
                        predicate: #Predicate { $0.id == countdownID }
                    )
                ).first
            )
            let operationID = event.operationID
            let receipt = try XCTUnwrap(
                context.fetch(
                    FetchDescriptor<OperationReceiptRecord>(
                        predicate: #Predicate {
                            $0.operationID == operationID
                        }
                    )
                ).first
            )
            reminder.isEnabled = true
            reminder.leadDays = 2
            reminder.localHour = 9
            reminder.localMinute = 30
            receipt.commandDigest = try CountdownLifecycleBackfill
                .migrationCommandDigest(
                    source: legacy,
                    state: state,
                    event: event,
                    reminder: reminder
                )
            try rewriteRevision(
                in: context,
                recordType: "CountdownReminderRuleRecord",
                recordID: reminder.id,
                fields: try CountdownDigestV1.reminder(reminder)
            )
            try rewriteRevision(
                in: context,
                recordType: "OperationReceiptRecord",
                recordID: receipt.operationID,
                fields: try TodayExecutionDigestV1
                    .operationReceipt(receipt)
            )
            let ledger = try XCTUnwrap(
                context.fetch(
                    FetchDescriptor<OperationReceiptLedgerRecord>()
                ).first
            )
            let receipts = try context.fetch(
                FetchDescriptor<OperationReceiptRecord>()
            )
            ledger.receiptCount = receipts.count
            ledger.receiptSetDigest = try TodayExecutionDigestV1
                .receiptSetDigest(receipts)
            try rewriteRevision(
                in: context,
                recordType: "OperationReceiptLedgerRecord",
                recordID: TodayExecutionDigestV1.receiptLedgerID,
                fields: TodayExecutionDigestV1
                    .operationReceiptLedger(ledger)
            )
            try context.save()
            try v6FixtureStep("V6 relationship validation") {
                try CountdownLifecycleRelationshipValidator.validate(
                    in: context,
                    failure: .migrationFailed,
                    includesIntegrityFacts: false
                )
            }
            datasetID = try XCTUnwrap(
                context.fetch(FetchDescriptor<DatasetMetadata>()).first
            ).datasetID
            revisionCount = try context.fetchCount(
                FetchDescriptor<RecordRevision>()
            )
            factCount = revisionCount
        }
        try GenerationPointerStore(layout: layout).write(
            GenerationPointer(
                generationID: generationID,
                schemaVersion: "6.0.0",
                origin: .schemaUpgrade,
                datasetID: datasetID,
                minimumFactCount: factCount,
                minimumRevisionCount: revisionCount
            )
        )
        try MigrationJournalStore(layout: layout).write(
            MigrationJournal(
                targetGenerationID: generationID,
                origin: .newInstall,
                phase: .activated
            )
        )
        _ = try StoreFileProtectionAuditor(
            backupPolicy: .systemManaged,
            verificationMode: .simulatorTestHarness
        ).hardenAndInspect(
            storeURL: storeURL,
            resources: layout.protectionResources(
                for: generationID
            )
        )
        return V6SourceFixture(
            generationID: generationID,
            storeURL: storeURL,
            countdownID: countdownID
        )
    }

    private func seedActiveV7Generation(
        in layout: AppDataStoreLayout
    ) throws -> V7SourceFixture {
        let v6 = try seedActiveV6GenerationWithEnabledReminder(in: layout)
        let bootstrapper = makeTestBootstrapper(layout: layout)
        do {
            _ = try bootstrapper.open(
                failAt: .afterValidationBeforePointer
            )
            XCTFail("Expected the V6→V7 activation failpoint to interrupt")
        } catch {
            guard error as? StoreBootstrapInterruption == .injected else {
                throw error
            }
        }
        let journal = try MigrationJournalStore(layout: layout).read()
        guard journal.sourceGenerationID == v6.generationID,
              journal.sourceSchemaVersion == "6.0.0",
              journal.targetSchemaVersion == "7.0.0",
              journal.phase == .validated else {
            throw AppDataFailure.migrationFailed
        }
        let generationID = journal.targetGenerationID
        let storeURL = layout.storeURL(for: generationID)
        let identity = try autoreleasepool {
            let container = try AppModelContainerFactory
                .makeV7CountdownIntegrityContainer(at: storeURL)
            let context = ModelContext(container)
            let metadata = try XCTUnwrap(
                context.fetch(FetchDescriptor<DatasetMetadata>()).first
            )
            let revisionCount = try context.fetchCount(
                FetchDescriptor<RecordRevision>()
            )
            return (
                datasetID: metadata.datasetID,
                factCount: revisionCount,
                revisionCount: revisionCount
            )
        }
        try GenerationPointerStore(layout: layout).write(
            GenerationPointer(
                generationID: generationID,
                schemaVersion: "7.0.0",
                origin: .schemaUpgrade,
                datasetID: identity.datasetID,
                minimumFactCount: identity.factCount,
                minimumRevisionCount: identity.revisionCount
            )
        )
        return V7SourceFixture(
            generationID: generationID,
            storeURL: storeURL,
            durableHashes: try durableStoreBundleHashes(at: storeURL),
            preexistingGenerationNames: try directoryEntryNames(
                at: layout.generationsURL
            )
        )
    }

    private func seedActiveV8Generation(
        in layout: AppDataStoreLayout
    ) async throws -> V8SourceFixture {
        let generationID = UUID()
        let storeURL = layout.storeURL(for: generationID)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let identity = try await { () async throws -> (
            datasetID: UUID,
            revisionCount: Int
        ) in
            let container = try AppModelContainerFactory
                .makeV8OnboardingContainer(at: storeURL)
            guard try LegacyV1Backfill.run(in: container).didComplete,
                  try CoreTimeRegimenBackfill.run(in: container).didComplete,
                  try TodayExecutionBackfill.run(in: container).didComplete,
                  try PersonalTimelineBackfill.run(in: container).didComplete,
                  try CountdownLifecycleBackfill.run(in: container)
                    .didComplete,
                  try CountdownIntegrityBackfill.run(in: container)
                    .didComplete,
                  try OnboardingBackfill.run(
                      in: container,
                      source: .schemaUpgradeV7
                  ).didComplete else {
                throw AppDataFailure.migrationFailed
            }
            let startDate = Date(timeIntervalSince1970: 1_767_225_600)
            try await AppWriteActor(modelContainer: container).setStartDate(
                SetStartDateCommand(
                    startDate: startDate,
                    timeZoneIdentifier: "UTC",
                    committedAt: startDate.addingTimeInterval(1)
                )
            )
            let context = ModelContext(container)
            return (
                datasetID: try XCTUnwrap(
                    context.fetch(FetchDescriptor<DatasetMetadata>()).first
                ).datasetID,
                revisionCount: try context.fetchCount(
                    FetchDescriptor<RecordRevision>()
                )
            )
        }()
        try GenerationPointerStore(layout: layout).write(
            GenerationPointer(
                generationID: generationID,
                schemaVersion: "8.0.0",
                origin: .schemaUpgrade,
                datasetID: identity.datasetID,
                minimumFactCount: identity.revisionCount,
                minimumRevisionCount: identity.revisionCount
            )
        )
        try MigrationJournalStore(layout: layout).write(
            MigrationJournal(
                targetGenerationID: generationID,
                origin: .newInstall,
                phase: .activated
            )
        )
        _ = try StoreFileProtectionAuditor(
            backupPolicy: .systemManaged,
            verificationMode: .simulatorTestHarness
        ).hardenAndInspect(
            storeURL: storeURL,
            resources: layout.protectionResources(for: generationID)
        )
        return V8SourceFixture(
            generationID: generationID,
            storeURL: storeURL,
            durableHashes: try durableStoreBundleHashes(at: storeURL)
        )
    }

    private func seedActiveV9Generation(
        in layout: AppDataStoreLayout
    ) async throws -> V9SourceFixture {
        let generationID = UUID()
        let storeURL = layout.storeURL(for: generationID)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let identity = try await { () async throws -> (
            datasetID: UUID,
            revisionCount: Int
        ) in
            let container = try AppModelContainerFactory
                .makeHrtJourneyLifecycleContainer(at: storeURL)
            guard try LegacyV1Backfill.run(in: container).didComplete,
                  try CoreTimeRegimenBackfill.run(in: container)
                    .didComplete,
                  try TodayExecutionBackfill.run(in: container)
                    .didComplete,
                  try PersonalTimelineBackfill.run(in: container)
                    .didComplete,
                  try CountdownLifecycleBackfill.run(in: container)
                    .didComplete,
                  try CountdownIntegrityBackfill.run(in: container)
                    .didComplete,
                  try OnboardingBackfill.run(
                      in: container,
                      source: .schemaUpgradeV7
                  ).didComplete,
                  try HrtJourneyLifecycleBackfill.run(
                      in: container,
                      sourceSchemaVersion: "8.0.0"
                  ).didComplete else {
                throw AppDataFailure.migrationFailed
            }
            let writer = AppWriteActor(modelContainer: container)
            let timestamp = try HistoricalTimestamp.captured(
                instant: Date(timeIntervalSince1970: 1_767_225_600),
                timeZoneIdentifier: "UTC",
                precision: .minute,
                provenance: .userEntered
            )
            let labDefinitionID = UUID()
            _ = try await writer.createLabSample(
                CreateLabSampleCommand(
                    operationID: UUID(),
                    sampleID: UUID(),
                    timestamp: timestamp,
                    newDefinitions: [
                        LabItemDefinitionInput(
                            id: labDefinitionID,
                            displayName: "雌二醇",
                            code: "E2"
                        )
                    ],
                    results: [
                        LabResultInput(
                            itemDefinitionID: labDefinitionID,
                            rawValueOriginal: "100",
                            unitOriginal: "pg/mL"
                        )
                    ]
                )
            )
            let metricID = UUID()
            _ = try await writer.createStatusMetric(
                CreateStatusMetricCommand(
                    operationID: UUID(),
                    metricID: metricID,
                    displayName: "精力"
                )
            )
            _ = try await writer.recordStatusObservation(
                RecordStatusObservationCommand(
                    operationID: UUID(),
                    observationID: UUID(),
                    metricDefinitionID: metricID,
                    ordinalLevel: 3,
                    timestamp: timestamp
                )
            )
            let context = ModelContext(container)
            return (
                datasetID: try XCTUnwrap(
                    context.fetch(
                        FetchDescriptor<DatasetMetadata>()
                    ).first
                ).datasetID,
                revisionCount: try context.fetchCount(
                    FetchDescriptor<RecordRevision>()
                )
            )
        }()
        try GenerationPointerStore(layout: layout).write(
            GenerationPointer(
                generationID: generationID,
                schemaVersion: "9.0.0",
                origin: .schemaUpgrade,
                datasetID: identity.datasetID,
                minimumFactCount: identity.revisionCount,
                minimumRevisionCount: identity.revisionCount
            )
        )
        try MigrationJournalStore(layout: layout).write(
            MigrationJournal(
                targetGenerationID: generationID,
                origin: .newInstall,
                phase: .activated
            )
        )
        _ = try StoreFileProtectionAuditor(
            backupPolicy: .systemManaged,
            verificationMode: .simulatorTestHarness
        ).hardenAndInspect(
            storeURL: storeURL,
            resources: layout.protectionResources(for: generationID)
        )
        return V9SourceFixture(
            generationID: generationID,
            storeURL: storeURL,
            durableHashes: try durableStoreBundleHashes(at: storeURL)
        )
    }

    private func seedActiveV10Generation(
        in layout: AppDataStoreLayout
    ) throws -> V10SourceFixture {
        let generationID = UUID()
        let storeURL = layout.storeURL(for: generationID)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var datasetID: UUID!
        var revisionCount = 0
        try autoreleasepool {
            let container = try AppModelContainerFactory
                .makeParentRecordLifecycleContainer(at: storeURL)
            guard try LegacyV1Backfill.run(in: container).didComplete,
                  try CoreTimeRegimenBackfill.run(in: container)
                    .didComplete,
                  try TodayExecutionBackfill.run(in: container)
                    .didComplete,
                  try PersonalTimelineBackfill.run(in: container)
                    .didComplete,
                  try CountdownLifecycleBackfill.run(in: container)
                    .didComplete,
                  try CountdownIntegrityBackfill.run(in: container)
                    .didComplete,
                  try OnboardingBackfill.run(
                      in: container,
                      source: .schemaUpgradeV7
                  ).didComplete,
                  try HrtJourneyLifecycleBackfill.run(
                      in: container,
                      sourceSchemaVersion: "9.0.0"
                  ).didComplete,
                  try ParentRecordLifecycleBackfill.run(
                      in: container,
                      sourceSchemaVersion: "9.0.0"
                  ).didComplete else {
                throw AppDataFailure.migrationFailed
            }
            let context = ModelContext(container)
            datasetID = try XCTUnwrap(
                context.fetch(FetchDescriptor<DatasetMetadata>()).first
            ).datasetID
            revisionCount = try context.fetchCount(
                FetchDescriptor<RecordRevision>()
            )
        }
        try GenerationPointerStore(layout: layout).write(
            GenerationPointer(
                generationID: generationID,
                schemaVersion: "10.0.0",
                origin: .schemaUpgrade,
                datasetID: datasetID,
                minimumFactCount: revisionCount,
                minimumRevisionCount: revisionCount
            )
        )
        try MigrationJournalStore(layout: layout).write(
            MigrationJournal(
                targetGenerationID: generationID,
                origin: .newInstall,
                phase: .activated
            )
        )
        _ = try StoreFileProtectionAuditor(
            backupPolicy: .systemManaged,
            verificationMode: .simulatorTestHarness
        ).hardenAndInspect(
            storeURL: storeURL,
            resources: layout.protectionResources(for: generationID)
        )
        return V10SourceFixture(
            generationID: generationID,
            storeURL: storeURL,
            durableHashes: try durableStoreBundleHashes(at: storeURL)
        )
    }

    private func seedActiveV11Generation(
        in layout: AppDataStoreLayout
    ) throws -> V11SourceFixture {
        let generationID = UUID()
        let storeURL = layout.storeURL(for: generationID)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var datasetID: UUID!
        var revisionCount = 0
        try autoreleasepool {
            let container = try AppModelContainerFactory
                .makePrivacyControlContainer(at: storeURL)
            guard try LegacyV1Backfill.run(in: container).didComplete,
                  try CoreTimeRegimenBackfill.run(in: container)
                    .didComplete,
                  try TodayExecutionBackfill.run(in: container)
                    .didComplete,
                  try PersonalTimelineBackfill.run(in: container)
                    .didComplete,
                  try CountdownLifecycleBackfill.run(in: container)
                    .didComplete,
                  try CountdownIntegrityBackfill.run(in: container)
                    .didComplete,
                  try OnboardingBackfill.run(
                      in: container,
                      source: .schemaUpgradeV7
                  ).didComplete,
                  try HrtJourneyLifecycleBackfill.run(
                      in: container,
                      sourceSchemaVersion: "9.0.0"
                  ).didComplete,
                  try ParentRecordLifecycleBackfill.run(
                      in: container,
                      sourceSchemaVersion: "9.0.0"
                  ).didComplete,
                  try PrivacyControlBackfill.run(
                      in: container,
                      source: .schemaUpgradeV10
                  ).didComplete else {
                throw AppDataFailure.migrationFailed
            }
            let context = ModelContext(container)
            datasetID = try XCTUnwrap(
                context.fetch(FetchDescriptor<DatasetMetadata>()).first
            ).datasetID
            revisionCount = try context.fetchCount(
                FetchDescriptor<RecordRevision>()
            )
        }
        try GenerationPointerStore(layout: layout).write(
            GenerationPointer(
                generationID: generationID,
                schemaVersion: "11.0.0",
                origin: .schemaUpgrade,
                datasetID: datasetID,
                minimumFactCount: revisionCount,
                minimumRevisionCount: revisionCount
            )
        )
        try MigrationJournalStore(layout: layout).write(
            MigrationJournal(
                targetGenerationID: generationID,
                origin: .newInstall,
                phase: .activated
            )
        )
        _ = try StoreFileProtectionAuditor(
            backupPolicy: .systemManaged,
            verificationMode: .simulatorTestHarness
        ).hardenAndInspect(
            storeURL: storeURL,
            resources: layout.protectionResources(for: generationID)
        )
        return V11SourceFixture(
            generationID: generationID,
            storeURL: storeURL,
            durableHashes: try durableStoreBundleHashes(at: storeURL)
        )
    }

    private func tamperHrtEventRevision(
        at storeURL: URL
    ) async throws {
        let container = try AppModelContainerFactory
            .makeHrtJourneyLifecycleContainer(at: storeURL)
        let writer = AppWriteActor(modelContainer: container)
        let result = try await writer.createHrtJourney(
            CreateHrtJourneyCommand(
                startDate: try CivilDateFact(
                    year: 2026,
                    month: 1,
                    day: 1
                ),
                timestamp: try HistoricalTimestamp.captured(
                    instant: Date(timeIntervalSince1970: 1_767_225_600),
                    timeZoneIdentifier: "UTC",
                    precision: .minute,
                    provenance: .userEntered
                )
            )
        )
        let context = ModelContext(container)
        let eventKey =
            "HrtJourneyLifecycleEventRecord:"
            + result.eventID.uuidString.lowercased()
        let stateKey =
            "HrtJourneyLifecycleBackfillState:"
            + CoreTimeRegimenBackfill.stableUUID(
                for: HrtJourneyLifecycleBackfillState.fixedKey
            ).uuidString.lowercased()
        let revisions = try context.fetch(
            FetchDescriptor<RecordRevision>()
        )
        let eventRevision = try XCTUnwrap(
            revisions.first { $0.recordKey == eventKey }
        )
        let stateRevision = try XCTUnwrap(
            revisions.first { $0.recordKey == stateKey }
        )
        XCTAssertNotEqual(
            eventRevision.localRevision,
            stateRevision.localRevision
        )
        eventRevision.localRevision = stateRevision.localRevision
        try context.save()
    }

    private func v6FixtureStep<T>(
        _ label: String,
        _ body: () throws -> T
    ) throws -> T {
        do {
            return try body()
        } catch {
            XCTFail("V6 fixture failed at \(label): \(error)")
            throw error
        }
    }

    private func rewriteRevision(
        in context: ModelContext,
        recordType: String,
        recordID: UUID,
        fields: [RecordDigestV1.Field]
    ) throws {
        let recordKey =
            recordType + ":" + recordID.uuidString.lowercased()
        let revision = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<RecordRevision>(
                    predicate: #Predicate {
                        $0.recordKey == recordKey
                    }
                )
            ).first
        )
        revision.digestHex = try RecordDigestV1.sha256Hex(
            recordType: recordType,
            recordID: recordID,
            fields: fields
        )
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func durableStoreBundleHashes(
        at storeURL: URL
    ) throws -> [String: String] {
        var hashes: [String: String] = [:]
        // SQLite may update the shared-memory lock table for a read-only
        // connection. The durable source facts live in main + WAL; those
        // bytes must remain identical through an inactive-generation upgrade.
        for suffix in ["", "-wal"] {
            let part = URL(fileURLWithPath: storeURL.path + suffix)
            if FileManager.default.fileExists(atPath: part.path) {
                hashes[suffix] = try sha256(of: part)
            }
        }
        return hashes
    }

    private func profileDigest(_ profile: HRTProfile) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "HRTProfile",
            recordID: profile.id,
            fields: [
                .init("activePeriodStartDate", try timestamp(profile.activePeriodStartDate)),
                .init("createdAt", try timestamp(profile.createdAt)),
                .init("startDate", try timestamp(profile.startDate))
            ]
        )
    }

    private func timestamp(_ date: Date) throws -> RecordDigestV1.Value {
        try RecordDigestV1.timestampValue(date)
    }

    private func directoryEntryNames(at url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }
}
