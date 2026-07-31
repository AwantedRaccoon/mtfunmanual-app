import Foundation
import XCTest
@testable import Unmanual

@MainActor
final class DataInventoryManifestTests: XCTestCase {
    private let generationID = UUID(
        uuidString: "11111111-1111-4111-8111-111111111111"
    )!
    private let datasetID = UUID(
        uuidString: "22222222-2222-4222-8222-222222222222"
    )!

    func testTaxonomyPartitionsAll55V13ModelsWithoutOverlap() {
        XCTAssertTrue(DataInventoryTaxonomy.hasExactModelPartition)
        XCTAssertEqual(
            DataInventoryTaxonomy.allDatabaseModelNames.count,
            55
        )
        XCTAssertEqual(
            Set(DataInventoryTaxonomy.allDatabaseModelNames).count,
            55
        )

        let currentNames = Set(
            AppSchemaV13ContentFavorite.models.map {
                String(describing: $0)
            }
        )
        let frozenNames = Set(
            DataInventoryTaxonomy.allDatabaseModelNames
        )
        XCTAssertEqual(currentNames, frozenNames)
        XCTAssertEqual(
            DataInventoryTaxonomy.databaseModelsByCategory[
                "db.content"
            ],
            ["ContentFavoriteRecord"]
        )
    }

    func testCanonicalOrderingGoldenAndCapturedAtOnlyChangesManifestDigest()
        throws {
        let first = try DataInventoryManifestBuilder.makeManifest(
            generationID: generationID,
            datasetID: datasetID,
            nextLocalRevision: 42,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            snapshots: completeSnapshots().reversed()
        )
        let second = try DataInventoryManifestBuilder.makeManifest(
            generationID: generationID,
            datasetID: datasetID,
            nextLocalRevision: 42,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_100),
            snapshots: completeSnapshots()
        )

        XCTAssertEqual(first.completeness, .complete)
        XCTAssertEqual(
            first.categories.map(\.key),
            DataInventoryTaxonomy.categorySpecifications
                .map(\.key)
                .sorted {
                    $0.utf8.lexicographicallyPrecedes($1.utf8)
                }
        )
        XCTAssertEqual(first.stateDigest, second.stateDigest)
        XCTAssertNotEqual(first.manifestDigest, second.manifestDigest)
        XCTAssertEqual(
            first.stateDigest,
            "f734e948eb0d92caec4f9a9dd4083abecc9efcfbc486573b110a5d4a9f3c62d7"
        )
        XCTAssertEqual(
            first.manifestDigest,
            "7838f6805c85ce11f932e4577bffa630ac5fa65b8944161e1157aa397c5fd3bb"
        )
    }

    func testInvalidGenerationSentinelFailsClosedWithoutPartialCounts()
        throws {
        var snapshots = completeSnapshots()
        let invalidIndex = try XCTUnwrap(
            snapshots.firstIndex {
                $0.key == "storage.generation.invalid"
            }
        )
        snapshots[invalidIndex] = DataInventoryCategorySnapshot(
            key: "storage.generation.invalid",
            kind: .generation,
            payload: .generations([
                DataInventoryGenerationSnapshot(
                    entryName: "not-a-uuid",
                    generationID: nil,
                    primaryClassification: .invalid,
                    journalRoles: [],
                    relativePath: "Unmanual/Generations/not-a-uuid",
                    scope: .closedFullTree,
                    files: []
                )
            ])
        )

        let manifest = try DataInventoryManifestBuilder.makeManifest(
            generationID: generationID,
            datasetID: datasetID,
            nextLocalRevision: 42,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            snapshots: snapshots
        )
        let invalid = try XCTUnwrap(
            manifest.categories.first {
                $0.key == "storage.generation.invalid"
            }
        )

        XCTAssertEqual(manifest.completeness, .incomplete)
        XCTAssertEqual(invalid.status, .failed)
        XCTAssertNil(invalid.itemCount)
        XCTAssertNil(invalid.byteCount)
        XCTAssertNil(invalid.retainedSensitiveCount)
        XCTAssertNil(invalid.identityDigest)
    }

    func testDatabaseFactAndRevisionEvidenceMustMatchBidirectionally()
        throws {
        let valid = try DataInventoryManifestBuilder.makeManifest(
            generationID: generationID,
            datasetID: datasetID,
            nextLocalRevision: 42,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            snapshots: snapshotsWithJourneyEvidence()
        )
        XCTAssertEqual(valid.completeness, .complete)

        let missingRevision = try DataInventoryManifestBuilder.makeManifest(
            generationID: generationID,
            datasetID: datasetID,
            nextLocalRevision: 42,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            snapshots: snapshotsWithJourneyEvidence(
                includeRevision: false
            )
        )
        XCTAssertEqual(missingRevision.completeness, .incomplete)
        XCTAssertTrue(
            missingRevision.categories
                .filter { $0.kind == .database }
                .allSatisfy { $0.status == .failed }
        )
    }

    func testDatabaseEvidenceRejectsWrongRecordTypeAndCategory()
        throws {
        let mismatchedType = try DataInventoryManifestBuilder.makeManifest(
            generationID: generationID,
            datasetID: datasetID,
            nextLocalRevision: 42,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            snapshots: snapshotsWithJourneyEvidence(
                factRecordType: "LabSampleRecord"
            )
        )
        XCTAssertEqual(mismatchedType.completeness, .incomplete)

        var wrongCategory = completeSnapshots()
        let statusIndex = wrongCategory.firstIndex {
            $0.key == "db.status"
        }!
        var statusCounts = DataInventoryTaxonomy
            .databaseModelsByCategory["db.status"]!
            .reduce(into: [String: Int64]()) {
                $0[$1] = 0
            }
        statusCounts["StatusObservationRecord"] = 1
        wrongCategory[statusIndex] = DataInventoryCategorySnapshot(
            key: "db.status",
            kind: .database,
            payload: .database(
                DataInventoryDatabaseSnapshot(
                    modelRowCounts: statusCounts,
                    entries: [
                        .fact(
                            modelType: "JourneyEntry",
                            recordType: "JourneyEntry",
                            recordID: generationID,
                            datasetID: datasetID,
                            recordKey: "JourneyEntry:wrong-category",
                            localRevision: 7,
                            digestVersion: 1,
                            digestHex: String(repeating: "a", count: 64)
                        )
                    ]
                )
            )
        )
        let misplaced = try DataInventoryManifestBuilder.makeManifest(
            generationID: generationID,
            datasetID: datasetID,
            nextLocalRevision: 42,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            snapshots: wrongCategory
        )
        XCTAssertEqual(misplaced.completeness, .incomplete)
        XCTAssertTrue(
            misplaced.categories
                .filter { $0.kind == .database }
                .allSatisfy { $0.status == .failed }
        )
    }

    func testSameSizeFileReplacementChangesStateDigest() throws {
        try withTemporaryDirectory { directory in
            let fileURL = directory.appending(path: "active.json")
            try Data("aaaa".utf8).write(to: fileURL)
            let firstFile = try DataInventoryRegularFileAudit.snapshot(
                at: fileURL,
                relativePath: "Unmanual/GenerationPointer/active.json"
            )
            try Data("bbbb".utf8).write(to: fileURL)
            let secondFile = try DataInventoryRegularFileAudit.snapshot(
                at: fileURL,
                relativePath: "Unmanual/GenerationPointer/active.json"
            )
            XCTAssertEqual(firstFile.byteCount, secondFile.byteCount)
            XCTAssertNotEqual(firstFile.sha256Hex, secondFile.sha256Hex)

            let first = try manifestReplacing(
                key: "storage.control",
                payload: .regularFiles([firstFile])
            )
            let second = try manifestReplacing(
                key: "storage.control",
                payload: .regularFiles([secondFile])
            )
            XCTAssertNotEqual(first.stateDigest, second.stateDigest)
        }
    }

    func testActiveGenerationDigestExcludesVolatileStoreAndFilesScope()
        throws {
        try withTemporaryDirectory { directory in
            let store = directory.appending(
                path: "Store",
                directoryHint: .isDirectory
            )
            let files = directory.appending(
                path: "Files",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: store,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: files,
                withIntermediateDirectories: true
            )
            try Data("db-a".utf8).write(
                to: store.appending(path: "user.sqlite")
            )
            try Data("payload-a".utf8).write(
                to: files.appending(path: "payload.bin")
            )
            try Data("provenance".utf8).write(
                to: directory.appending(path: "provenance.bin")
            )

            let firstFiles = try DataInventoryGenerationTreeAudit
                .regularFiles(
                    at: directory,
                    scope: .activeLogicalOverlay
                )
            try Data("db-b".utf8).write(
                to: store.appending(path: "user.sqlite")
            )
            try Data("payload-b".utf8).write(
                to: files.appending(path: "payload.bin")
            )
            let secondFiles = try DataInventoryGenerationTreeAudit
                .regularFiles(
                    at: directory,
                    scope: .activeLogicalOverlay
                )

            XCTAssertEqual(firstFiles, secondFiles)
            XCTAssertEqual(
                firstFiles.map(\.relativePath),
                ["provenance.bin"]
            )
            let first = try manifestWithActiveFiles(firstFiles)
            let second = try manifestWithActiveFiles(secondFiles)
            XCTAssertEqual(first.stateDigest, second.stateDigest)
        }
    }

    func testUnknownManagedRootLeafFailsControlAudit() throws {
        try withTemporaryDirectory { applicationSupport in
            let unmanual = applicationSupport.appending(
                path: "Unmanual",
                directoryHint: .isDirectory
            )
            for child in [
                "Generations",
                "GenerationPointer",
                "Recovery"
            ] {
                try FileManager.default.createDirectory(
                    at: unmanual.appending(
                        path: child,
                        directoryHint: .isDirectory
                    ),
                    withIntermediateDirectories: true
                )
            }
            try Data("{}".utf8).write(
                to: unmanual
                    .appending(path: "GenerationPointer")
                    .appending(path: "active.json")
            )
            try Data("unexpected".utf8).write(
                to: unmanual.appending(path: "surprise.bin")
            )

            XCTAssertThrowsError(
                try DataInventoryManagedRootAudit.validateReadyStructure(
                    applicationSupportURL: applicationSupport,
                    fileManager: .default
                )
            ) { error in
                XCTAssertEqual(
                    error as? DataInventoryFileAuditError,
                    .unknownManagedLeaf("Unmanual/surprise.bin")
                )
            }
        }
    }

    func testValidatedControlSnapshotBindsPointerRawBytesAndActiveLayout()
        throws {
        try withTemporaryDirectory { applicationSupport in
            let generationName = generationID.uuidString.lowercased()
            let generation = applicationSupport
                .appending(path: "Unmanual", directoryHint: .isDirectory)
                .appending(
                    path: "Generations",
                    directoryHint: .isDirectory
                )
                .appending(
                    path: generationName,
                    directoryHint: .isDirectory
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
                ),
                applicationSupport
                    .appending(path: "Unmanual")
                    .appending(
                        path: "GenerationPointer",
                        directoryHint: .isDirectory
                    ),
                applicationSupport
                    .appending(path: "Unmanual")
                    .appending(
                        path: "Recovery",
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
            let pointer = GenerationPointer(
                generationID: generationID,
                schemaVersion: "12.0.0",
                origin: .newInstall,
                datasetID: datasetID,
                minimumFactCount: 0,
                minimumRevisionCount: 0,
                activatedAt: Date(
                    timeIntervalSince1970: 1_800_000_000
                )
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let pointerURL = applicationSupport
                .appending(path: "Unmanual")
                .appending(path: "GenerationPointer")
                .appending(path: "active.json")
            try encoder.encode(pointer).write(to: pointerURL)
            try markSystemManagedTree(generation)

            let activeProof =
                try DataInventoryActiveGenerationLayoutAudit.validate(
                    applicationSupportURL: applicationSupport,
                    generationID: generationID
                )
            try setExcludedFromBackup(true, at: pointerURL)
            XCTAssertThrowsError(
                try DataInventoryManagedRootAudit
                    .validatedReadyControlSnapshot(
                        applicationSupportURL: applicationSupport,
                        expectedGenerationID: generationID,
                        expectedDatasetID: datasetID,
                        expectedSchemaVersion: "12.0.0",
                        expectedMinimumFactCount: 0,
                        expectedMinimumRevisionCount: 0,
                        activeGenerationLayout: activeProof
                    )
            )
            try markSystemManagedTree(pointerURL)
            XCTAssertThrowsError(
                try DataInventoryManagedRootAudit
                    .validatedReadyControlSnapshot(
                        applicationSupportURL: applicationSupport,
                        expectedGenerationID: generationID,
                        expectedDatasetID: UUID(),
                        expectedSchemaVersion: "12.0.0",
                        expectedMinimumFactCount: 0,
                        expectedMinimumRevisionCount: 0,
                        activeGenerationLayout: activeProof
                    )
            )

            let control = try DataInventoryManagedRootAudit
                .validatedReadyControlSnapshot(
                    applicationSupportURL: applicationSupport,
                    expectedGenerationID: generationID,
                    expectedDatasetID: datasetID,
                    expectedSchemaVersion: "12.0.0",
                    expectedMinimumFactCount: 0,
                    expectedMinimumRevisionCount: 0,
                    activeGenerationLayout: activeProof
                )
            XCTAssertEqual(control.pointer, pointer)
            guard case let .regularFiles(controlFiles) =
                    control.categorySnapshot.payload else {
                return XCTFail("validated control proof must expose exact files")
            }
            XCTAssertEqual(
                controlFiles.map(\.relativePath),
                ["Unmanual/GenerationPointer/active.json"]
            )

            let journal = MigrationJournal(
                targetGenerationID: generationID,
                origin: .newInstall,
                phase: .activated,
                updatedAt: Date(
                    timeIntervalSince1970: 1_800_000_001
                )
            )
            let journalURL = applicationSupport
                .appending(path: "Unmanual")
                .appending(path: "Recovery")
                .appending(path: "migration-journal.json")
            try encoder.encode(journal).write(to: journalURL)
            try setExcludedFromBackup(true, at: journalURL)
            XCTAssertThrowsError(
                try DataInventoryManagedRootAudit
                    .validatedReadyControlSnapshot(
                        applicationSupportURL: applicationSupport,
                        expectedGenerationID: generationID,
                        expectedDatasetID: datasetID,
                        expectedSchemaVersion: "12.0.0",
                        expectedMinimumFactCount: 0,
                        expectedMinimumRevisionCount: 0,
                        activeGenerationLayout: activeProof
                    )
            )
            try markSystemManagedTree(journalURL)
            let withJournal = try DataInventoryManagedRootAudit
                .validatedReadyControlSnapshot(
                    applicationSupportURL: applicationSupport,
                    expectedGenerationID: generationID,
                    expectedDatasetID: datasetID,
                    expectedSchemaVersion: "12.0.0",
                    expectedMinimumFactCount: 0,
                    expectedMinimumRevisionCount: 0,
                    activeGenerationLayout: activeProof
                )
            XCTAssertEqual(withJournal.migrationJournal, journal)
            guard case let .regularFiles(filesWithJournal) =
                    withJournal.categorySnapshot.payload else {
                return XCTFail("missing journal proof")
            }
            XCTAssertEqual(
                filesWithJournal.map(\.relativePath),
                [
                    "Unmanual/GenerationPointer/active.json",
                    "Unmanual/Recovery/migration-journal.json"
                ]
            )

            try Data("{\"formatVersion\":1}".utf8).write(
                to: journalURL
            )
            try markSystemManagedTree(journalURL)
            XCTAssertThrowsError(
                try DataInventoryManagedRootAudit
                    .validatedReadyControlSnapshot(
                        applicationSupportURL: applicationSupport,
                        expectedGenerationID: generationID,
                        expectedDatasetID: datasetID,
                        expectedSchemaVersion: "12.0.0",
                        expectedMinimumFactCount: 0,
                        expectedMinimumRevisionCount: 0,
                        activeGenerationLayout: activeProof
                    )
            )
        }
    }

    func testDatabaseEvidenceRejectsCrossCategoryDuplicateRecordKey()
        throws {
        var snapshots = snapshotsWithJourneyEvidence()
        let journeyIndex = try XCTUnwrap(
            snapshots.firstIndex { $0.key == "db.journey" }
        )
        guard case let .database(journeyDatabase) =
                snapshots[journeyIndex].payload,
              let duplicate = journeyDatabase.entries.first else {
            return XCTFail("missing journey proof")
        }
        let statusIndex = try XCTUnwrap(
            snapshots.firstIndex { $0.key == "db.status" }
        )
        var statusCounts = DataInventoryTaxonomy
            .databaseModelsByCategory["db.status"]!
            .reduce(into: [String: Int64]()) {
                $0[$1] = 0
            }
        statusCounts["StatusObservationRecord"] = 1
        snapshots[statusIndex] = DataInventoryCategorySnapshot(
            key: "db.status",
            kind: .database,
            payload: .database(
                DataInventoryDatabaseSnapshot(
                    modelRowCounts: statusCounts,
                    entries: [duplicate]
                )
            )
        )

        let manifest = try DataInventoryManifestBuilder.makeManifest(
            generationID: generationID,
            datasetID: datasetID,
            nextLocalRevision: 42,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            snapshots: snapshots
        )
        XCTAssertEqual(manifest.completeness, .incomplete)
        XCTAssertTrue(
            manifest.categories
                .filter { $0.kind == .database }
                .allSatisfy { $0.status == .failed }
        )
    }

    func testForeignNotificationsAreExcludedFromFixedBuckets() {
        let categories = DataInventoryNotificationSnapshotFactory
            .categories(
                observations: [
                    .init(
                        identifier: "foreign.request",
                        deliveryState: .pending
                    ),
                    .init(
                        identifier: "unmanual.exec.v1.a",
                        deliveryState: .pending
                    ),
                    .init(
                        identifier: "unmanual.countdown.v1.b",
                        deliveryState: .delivered
                    )
                ]
            )
        XCTAssertEqual(categories.count, 4)
        let requestCount = categories.reduce(into: 0) { count, category in
            guard case let .notifications(requests) = category.payload else {
                return
            }
            count += requests.count
        }
        XCTAssertEqual(requestCount, 2)
    }

    private func completeSnapshots(
        activeFiles: [DataInventoryRegularFileSnapshot] = []
    ) -> [DataInventoryCategorySnapshot] {
        DataInventoryTaxonomy.categorySpecifications.map { specification in
            switch specification.kind {
            case .database:
                let names = DataInventoryTaxonomy
                    .databaseModelsByCategory[specification.key]!
                return DataInventoryCategorySnapshot(
                    key: specification.key,
                    kind: .database,
                    payload: .database(
                        DataInventoryDatabaseSnapshot(
                            modelRowCounts: Dictionary(
                                uniqueKeysWithValues: names.map {
                                    ($0, Int64(0))
                                }
                            ),
                            entries: []
                        )
                    )
                )
            case .fileTree, .control:
                return DataInventoryCategorySnapshot(
                    key: specification.key,
                    kind: specification.kind,
                    payload: .regularFiles([])
                )
            case .notification:
                return DataInventoryCategorySnapshot(
                    key: specification.key,
                    kind: .notification,
                    payload: .notifications([])
                )
            case .generation:
                let generations: [DataInventoryGenerationSnapshot]
                if specification.key == "storage.generation.active" {
                    generations = [
                        DataInventoryGenerationSnapshot(
                            entryName: generationID.uuidString.lowercased(),
                            generationID: generationID,
                            primaryClassification: .active,
                            journalRoles: [],
                            relativePath:
                                "Unmanual/Generations/"
                                + generationID.uuidString.lowercased(),
                            scope: .activeLogicalOverlay,
                            files: activeFiles
                        )
                    ]
                } else {
                    generations = []
                }
                return DataInventoryCategorySnapshot(
                    key: specification.key,
                    kind: .generation,
                    payload: .generations(generations)
                )
            }
        }
    }

    private func manifestReplacing(
        key: String,
        payload: DataInventoryCategoryPayload
    ) throws -> DataInventoryManifest {
        var snapshots = completeSnapshots()
        let index = snapshots.firstIndex { $0.key == key }!
        snapshots[index] = DataInventoryCategorySnapshot(
            key: key,
            kind: snapshots[index].kind,
            payload: payload
        )
        return try DataInventoryManifestBuilder.makeManifest(
            generationID: generationID,
            datasetID: datasetID,
            nextLocalRevision: 42,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            snapshots: snapshots
        )
    }

    private func snapshotsWithJourneyEvidence(
        factRecordType: String = "JourneyEntry",
        includeRevision: Bool = true
    ) -> [DataInventoryCategorySnapshot] {
        var snapshots = completeSnapshots()
        let recordID = UUID(
            uuidString: "33333333-3333-4333-8333-333333333333"
        )!
        let recordKey = "JourneyEntry:"
            + recordID.uuidString.lowercased()
        let digest = String(repeating: "a", count: 64)

        let journeyIndex = snapshots.firstIndex {
            $0.key == "db.journey"
        }!
        snapshots[journeyIndex] = DataInventoryCategorySnapshot(
            key: "db.journey",
            kind: .database,
            payload: .database(
                DataInventoryDatabaseSnapshot(
                    modelRowCounts: ["JourneyEntry": 1],
                    entries: [
                        .fact(
                            modelType: "JourneyEntry",
                            recordType: factRecordType,
                            recordID: recordID,
                            datasetID: datasetID,
                            recordKey: recordKey,
                            localRevision: 7,
                            digestVersion: 1,
                            digestHex: digest
                        )
                    ]
                )
            )
        )

        if includeRevision {
            let auditIndex = snapshots.firstIndex {
                $0.key == "db.audit"
            }!
            var auditCounts = DataInventoryTaxonomy
                .databaseModelsByCategory["db.audit"]!
                .reduce(into: [String: Int64]()) {
                    $0[$1] = 0
                }
            auditCounts["RecordRevision"] = 1
            snapshots[auditIndex] = DataInventoryCategorySnapshot(
                key: "db.audit",
                kind: .database,
                payload: .database(
                    DataInventoryDatabaseSnapshot(
                        modelRowCounts: auditCounts,
                        entries: [
                            .revision(
                                recordKey: recordKey,
                                recordType: "JourneyEntry",
                                recordID: recordID,
                                datasetID: datasetID,
                                localRevision: 7,
                                digestVersion: 1,
                                committedAt: Date(
                                    timeIntervalSince1970:
                                        1_800_000_000
                                ),
                                digestHex: digest
                            )
                        ]
                    )
                )
            )
        }
        return snapshots
    }

    private func manifestWithActiveFiles(
        _ files: [DataInventoryRegularFileSnapshot]
    ) throws -> DataInventoryManifest {
        try DataInventoryManifestBuilder.makeManifest(
            generationID: generationID,
            datasetID: datasetID,
            nextLocalRevision: 42,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            snapshots: completeSnapshots(activeFiles: files)
        )
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "DataInventoryTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory)
    }

    private func markSystemManagedTree(_ root: URL) throws {
        var nodes = [root]
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) {
            while let url = enumerator.nextObject() as? URL {
                nodes.append(url)
            }
        }
        for node in nodes {
            var mutable = node
            var values = URLResourceValues()
            values.isExcludedFromBackup = false
            try mutable.setResourceValues(values)
        }
    }

    private func setExcludedFromBackup(
        _ value: Bool,
        at url: URL
    ) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = value
        try mutableURL.setResourceValues(values)
    }
}
