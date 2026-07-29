import CryptoKit
import XCTest
@testable import Unmanual

final class PortableRestoreJournalTests: XCTestCase {
    func testLegacyV1SourceActivePartialTargetMigratesToBoundRebuild()
        throws {
        let fixture = try makeFixture()
        try seedPointer(
            generationID:
                fixture.journal.sourceGenerationID,
            datasetID: fixture.journal.sourceDatasetID,
            layout: fixture.layout
        )
        let target = fixture.layout
            .generationDirectoryURL(
                for: fixture.journal.targetGenerationID
            )
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        let legacy = try legacyData(
            fixture.journal,
            phase: .databaseWritten
        )
        try legacy.write(
            to: fixture.layout.portableRestoreJournalURL
        )

        let migrated = try fixture.store.read()

        XCTAssertEqual(
            migrated.formatVersion,
            PortableRestoreJournal.formatVersion
        )
        XCTAssertEqual(
            migrated.phase,
            .targetDirectoryPrepared
        )
        XCTAssertNotNil(migrated.targetRootIdentity)
        XCTAssertNil(migrated.targetAncestry)
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: fixture.layout
                        .portableRestoreJournalURL
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(
            persisted["formatVersion"] as? Int,
            PortableRestoreJournal.formatVersion
        )
    }

    func testLegacyV1TargetActiveRestartCapturesFullAncestry()
        throws {
        let fixture = try makeFixture()
        let target = fixture.layout
            .generationDirectoryURL(
                for: fixture.journal.targetGenerationID
            )
        try FileManager.default.createDirectory(
            at: target.appending(
                path: "Store",
                directoryHint: .isDirectory
            ),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: target.appending(
                path: "Files",
                directoryHint: .isDirectory
            ),
            withIntermediateDirectories: true
        )
        try seedPointer(
            generationID:
                fixture.journal.targetGenerationID,
            datasetID: fixture.journal.targetDatasetID,
            layout: fixture.layout
        )
        try legacyData(
            fixture.journal,
            phase: .restartRequired
        ).write(
            to: fixture.layout.portableRestoreJournalURL
        )

        let migrated = try fixture.store.read()

        XCTAssertEqual(migrated.phase, .restartRequired)
        XCTAssertEqual(
            migrated.targetRootIdentity,
            migrated.targetAncestry?.target
        )
        XCTAssertNotNil(migrated.targetAncestry)
    }

    func testLegacyV1MigrationPostPublishFailurePreservesOriginalJournal()
        throws {
        let fixture = try makeFixture()
        try seedPointer(
            generationID:
                fixture.journal.sourceGenerationID,
            datasetID: fixture.journal.sourceDatasetID,
            layout: fixture.layout
        )
        let legacy = try legacyData(
            fixture.journal,
            phase: .preparingTarget
        )
        try legacy.write(
            to: fixture.layout.portableRestoreJournalURL
        )
        let failingStore = PortableRestoreJournalStore(
            layout: fixture.layout,
            backupPolicy: .systemManaged,
            afterPublish: {
                throw NSError(
                    domain: "RestoreJournalTests",
                    code: 1
                )
            }
        )

        XCTAssertThrowsError(try failingStore.read())
        XCTAssertEqual(
            try Data(
                contentsOf:
                    fixture.layout
                    .portableRestoreJournalURL
            ),
            legacy
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.layout.recoveryURL.path
            ),
            ["portable-restore-journal.json"]
        )
    }

    func testLegacyV1RejectsTamperedContractAndTargetActiveEarlyPhase()
        throws {
        let sourceFixture = try makeFixture()
        try seedPointer(
            generationID:
                sourceFixture.journal.sourceGenerationID,
            datasetID:
                sourceFixture.journal.sourceDatasetID,
            layout: sourceFixture.layout
        )
        var tampered = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try legacyData(
                    sourceFixture.journal,
                    phase: .preparingTarget
                )
            ) as? [String: Any]
        )
        tampered["contractSHA256"] =
            String(repeating: "0", count: 64)
        try JSONSerialization.data(
            withJSONObject: tampered,
            options: [.sortedKeys]
        ).write(
            to: sourceFixture.layout
                .portableRestoreJournalURL
        )
        XCTAssertThrowsError(
            try sourceFixture.store.read()
        ) {
            XCTAssertEqual(
                $0 as? PortableRestoreJournalError,
                .invalid
            )
        }

        let targetFixture = try makeFixture()
        let target = targetFixture.layout
            .generationDirectoryURL(
                for:
                    targetFixture.journal
                    .targetGenerationID
            )
        try FileManager.default.createDirectory(
            at: target.appending(
                path: "Store",
                directoryHint: .isDirectory
            ),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: target.appending(
                path: "Files",
                directoryHint: .isDirectory
            ),
            withIntermediateDirectories: true
        )
        try seedPointer(
            generationID:
                targetFixture.journal.targetGenerationID,
            datasetID:
                targetFixture.journal.targetDatasetID,
            layout: targetFixture.layout
        )
        try legacyData(
            targetFixture.journal,
            phase: .targetPrepared
        ).write(
            to: targetFixture.layout
                .portableRestoreJournalURL
        )
        XCTAssertThrowsError(
            try targetFixture.store.read()
        ) {
            XCTAssertEqual(
                $0 as? PortableRestoreJournalError,
                .invalid
            )
        }
    }

    func testJournalRoundTripsAndRequiresMonotonicPhase()
        throws {
        let fixture = try makeFixture()
        var journal = fixture.journal
        try fixture.store.write(journal)
        XCTAssertEqual(try fixture.store.read(), journal)

        let preparing = journal
        let target = fixture.root.appending(
            path: "target",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        journal.bindTargetRoot(
            try PortableManagedPathSecurity
                .directoryIdentity(at: target)
        )
        journal.advanceState(
            to: .targetDirectoryPrepared,
            updatedAt: journal.updatedAt.addingTimeInterval(1)
        )
        try fixture.store.write(
            journal,
            replacing: preparing
        )
        XCTAssertEqual(try fixture.store.read(), journal)

        XCTAssertThrowsError(
            try fixture.store.write(
                preparing,
                replacing: journal
            )
        ) {
            XCTAssertEqual(
                $0 as? PortableRestoreJournalError,
                .invalidTransition
            )
        }
    }

    func testJournalRejectsPostPreparePhaseWithoutTargetIdentity()
        throws {
        let fixture = try makeFixture()
        let journal = PortableRestoreJournal(
            mode: .replace,
            sourceGenerationID:
                fixture.journal.sourceGenerationID,
            sourceDatasetID:
                fixture.journal.sourceDatasetID,
            targetGenerationID:
                fixture.journal.targetGenerationID,
            targetDatasetID:
                fixture.journal.targetDatasetID,
            packageRootDigest: digest("package"),
            confirmedLocalStateDigest: digest("local"),
            dryRunTokenSHA256: digest("token"),
            factCount: 1,
            revisionCount: 1,
            targetNextLocalRevision: 2,
            attachmentCount: 0,
            attachmentManifestDigest: digest("attachments"),
            devicePolicyCommittedAtMicroseconds: 2,
            phase: .targetDirectoryPrepared
        )
        XCTAssertThrowsError(try fixture.store.write(journal)) {
            XCTAssertEqual(
                $0 as? PortableRestoreJournalError,
                .invalid
            )
        }
    }

    func testJournalExtremeTimestampIsRejectedWithoutTrap()
        throws {
        let fixture = try makeFixture()
        let journal = PortableRestoreJournal(
            mode: .replace,
            sourceGenerationID:
                fixture.journal.sourceGenerationID,
            sourceDatasetID:
                fixture.journal.sourceDatasetID,
            targetGenerationID:
                fixture.journal.targetGenerationID,
            targetDatasetID:
                fixture.journal.targetDatasetID,
            packageRootDigest: digest("package"),
            confirmedLocalStateDigest: digest("local"),
            dryRunTokenSHA256: digest("token"),
            factCount: 1,
            revisionCount: 1,
            targetNextLocalRevision: 2,
            attachmentCount: 0,
            attachmentManifestDigest: digest("attachments"),
            devicePolicyCommittedAtMicroseconds: 2,
            updatedAt: Date(
                timeIntervalSince1970: 1e30
            )
        )
        XCTAssertThrowsError(try fixture.store.write(journal)) {
            XCTAssertEqual(
                $0 as? PortableRestoreJournalError,
                .invalid
            )
        }
    }

    func testJournalRejectsNonDerivedStagingPath()
        throws {
        let fixture = try makeFixture()
        let invalid = PortableRestoreJournal(
            mode: .replace,
            sourceGenerationID:
                fixture.journal.sourceGenerationID,
            sourceDatasetID:
                fixture.journal.sourceDatasetID,
            targetGenerationID:
                fixture.journal.targetGenerationID,
            targetDatasetID:
                fixture.journal.targetDatasetID,
            packageRootDigest: digest("package"),
            stagingRelativePath:
                "../outside.unmanualbackup",
            confirmedLocalStateDigest: digest("local"),
            dryRunTokenSHA256: digest("token"),
            factCount: 1,
            revisionCount: 1,
            targetNextLocalRevision: 2,
            attachmentCount: 0,
            attachmentManifestDigest: digest("attachments"),
            devicePolicyCommittedAtMicroseconds: 2
        )

        XCTAssertThrowsError(try fixture.store.write(invalid)) {
            XCTAssertEqual(
                $0 as? PortableRestoreJournalError,
                .invalid
            )
        }
    }

    func testDuplicateJournalKeyIsRejected() throws {
        let fixture = try makeFixture()
        try fixture.store.write(fixture.journal)
        var text = try String(
            contentsOf:
                fixture.layout.portableRestoreJournalURL,
            encoding: .utf8
        )
        text = text.replacingOccurrences(
            of:
                "\"formatVersion\":"
                + String(PortableRestoreJournal.formatVersion),
            with:
                "\"formatVersion\":"
                + String(PortableRestoreJournal.formatVersion)
                + ",\"formatVersion\":"
                + String(PortableRestoreJournal.formatVersion)
        )
        XCTAssertTrue(
            text.components(
                separatedBy: "\"formatVersion\""
            ).count == 3
        )
        try Data(text.utf8).write(
            to: fixture.layout.portableRestoreJournalURL
        )

        XCTAssertThrowsError(try fixture.store.read())
    }

    func testJournalRejectsPhaseTamperWithoutStateDigestUpdate()
        throws {
        let fixture = try makeFixture()
        try fixture.store.write(fixture.journal)
        let url = fixture.layout.portableRestoreJournalURL
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: url)
            ) as? [String: Any]
        )
        object["phase"] =
            PortableRestorePhase.databaseWritten.rawValue
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: url, options: [.atomic])

        XCTAssertThrowsError(try fixture.store.read()) {
            XCTAssertEqual(
                $0 as? PortableRestoreJournalError,
                .invalid
            )
        }
    }

    func testSymlinkedJournalIsRejectedBeforeColdLaunchUsesIt()
        async throws {
        let fixture = try makeFixture()
        try fixture.store.write(fixture.journal)
        let externalJournal = fixture.root
            .appending(path: "external-journal.json")
        try FileManager.default.moveItem(
            at: fixture.layout
                .portableRestoreJournalURL,
            to: externalJournal
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.layout
                .portableRestoreJournalURL,
            withDestinationURL: externalJournal
        )

        XCTAssertThrowsError(
            try fixture.store.read()
        ) {
            XCTAssertEqual(
                $0 as? PortableRestoreJournalError,
                .invalid
            )
        }
        do {
            try await PortablePackageCleanupCoordinator
                .recoverBeforeStoreOpen(
                    layout: fixture.layout
                )
            XCTFail("Expected journal symlink rejection")
        } catch {
            XCTAssertEqual(
                error as? PortableRestoreJournalError,
                .invalid
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: externalJournal.path
            )
        )
        XCTAssertNotNil(
            try? FileManager.default
                .destinationOfSymbolicLink(
                    atPath: fixture.layout
                        .portableRestoreJournalURL.path
                )
        )
    }

    func testJournalWriteRejectsRecoveryReplacementWithoutWritingOutside()
        throws {
        let fixture = try makeFixture()
        let originalRecovery = fixture.root
            .appending(
                path: "OriginalRecovery",
                directoryHint: .isDirectory
            )
        let externalRecovery = fixture.root
            .appending(
                path: "ExternalRecovery",
                directoryHint: .isDirectory
            )
        let store = PortableRestoreJournalStore(
            layout: fixture.layout,
            backupPolicy: .systemManaged,
            beforeWrite: {
                try FileManager.default.moveItem(
                    at: fixture.layout.recoveryURL,
                    to: originalRecovery
                )
                try FileManager.default
                    .createDirectory(
                        at: externalRecovery,
                        withIntermediateDirectories:
                            false
                    )
                try FileManager.default
                    .createSymbolicLink(
                        at: fixture.layout.recoveryURL,
                        withDestinationURL:
                            externalRecovery
                    )
            }
        )

        XCTAssertThrowsError(
            try store.write(fixture.journal)
        ) {
            XCTAssertEqual(
                $0 as? PortableRestoreJournalError,
                .invalid
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: externalRecovery
                    .appending(
                        path:
                            "portable-restore-journal.json"
                    ).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: originalRecovery
                    .appending(
                        path:
                            "portable-restore-journal.json"
                    ).path
            )
        )
    }

    private func seedPointer(
        generationID: UUID,
        datasetID: UUID,
        layout: AppDataStoreLayout
    ) throws {
        try GenerationPointerStore(
            layout: layout,
            backupPolicy: .systemManaged
        ).write(
            GenerationPointer(
                generationID: generationID,
                origin: .existingGeneration,
                datasetID: datasetID,
                minimumFactCount: 1,
                minimumRevisionCount: 1
            )
        )
    }

    private func legacyData(
        _ journal: PortableRestoreJournal,
        phase: PortableRestorePhase
    ) throws -> Data {
        let components = [
            "1",
            journal.operationID.uuidString.lowercased(),
            journal.mode.rawValue,
            journal.sourceGenerationID.uuidString.lowercased(),
            journal.sourceDatasetID.uuidString.lowercased(),
            journal.targetGenerationID.uuidString.lowercased(),
            journal.targetDatasetID.uuidString.lowercased(),
            journal.packageRootDigest,
            journal.stagingRelativePath,
            journal.confirmedLocalStateDigest,
            journal.dryRunTokenSHA256,
            String(journal.factCount),
            String(journal.revisionCount),
            String(journal.targetNextLocalRevision),
            String(journal.attachmentCount),
            journal.attachmentManifestDigest,
            journal.resetsAppLockForLocalConfirmation
                ? "1" : "0",
            journal.requiresNotificationReconciliation
                ? "1" : "0",
            journal.devicePolicyOperationID
                .uuidString.lowercased(),
            String(
                journal
                    .devicePolicyCommittedAtMicroseconds
            )
        ]
        let contract = SHA256.hash(
            data: Data(
                components.joined(
                    separator: "\u{001f}"
                ).utf8
            )
        )
        .map { String(format: "%02x", $0) }
        .joined()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime
        ]
        let object: [String: Any] = [
            "formatVersion": 1,
            "operationID": journal.operationID.uuidString,
            "mode": journal.mode.rawValue,
            "sourceGenerationID":
                journal.sourceGenerationID.uuidString,
            "sourceDatasetID":
                journal.sourceDatasetID.uuidString,
            "targetGenerationID":
                journal.targetGenerationID.uuidString,
            "targetDatasetID":
                journal.targetDatasetID.uuidString,
            "packageRootDigest":
                journal.packageRootDigest,
            "stagingRelativePath":
                journal.stagingRelativePath,
            "confirmedLocalStateDigest":
                journal.confirmedLocalStateDigest,
            "dryRunTokenSHA256":
                journal.dryRunTokenSHA256,
            "factCount": journal.factCount,
            "revisionCount": journal.revisionCount,
            "targetNextLocalRevision":
                journal.targetNextLocalRevision,
            "attachmentCount": journal.attachmentCount,
            "attachmentManifestDigest":
                journal.attachmentManifestDigest,
            "resetsAppLockForLocalConfirmation":
                journal
                    .resetsAppLockForLocalConfirmation,
            "requiresNotificationReconciliation":
                journal
                    .requiresNotificationReconciliation,
            "devicePolicyOperationID":
                journal.devicePolicyOperationID.uuidString,
            "devicePolicyCommittedAtMicroseconds":
                journal
                    .devicePolicyCommittedAtMicroseconds,
            "contractSHA256": contract,
            "phase": phase.rawValue,
            "updatedAt": formatter.string(
                from: journal.updatedAt
            )
        ]
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    private func makeFixture() throws -> (
        root: URL,
        layout: AppDataStoreLayout,
        store: PortableRestoreJournalStore,
        journal: PortableRestoreJournal
    ) {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "PortableRestoreJournalTests-"
                    + UUID().uuidString,
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let layout = AppDataStoreLayout(
            rootURL: root.appending(
                path: "Unmanual",
                directoryHint: .isDirectory
            ),
            legacyStoreURL: root.appending(
                path: "Legacy.sqlite"
            )
        )
        try FileManager.default.createDirectory(
            at: layout.recoveryURL,
            withIntermediateDirectories: true
        )
        return (
            root,
            layout,
            PortableRestoreJournalStore(
                layout: layout,
                backupPolicy: .systemManaged
            ),
            PortableRestoreJournal(
                mode: .replace,
                sourceGenerationID: UUID(),
                sourceDatasetID: UUID(),
                targetGenerationID: UUID(),
                targetDatasetID: UUID(),
                packageRootDigest: digest("package"),
                confirmedLocalStateDigest: digest("local"),
                dryRunTokenSHA256: digest("token"),
                factCount: 1,
                revisionCount: 1,
                targetNextLocalRevision: 2,
                attachmentCount: 0,
                attachmentManifestDigest:
                    digest("attachments"),
                devicePolicyCommittedAtMicroseconds: 2
            )
        )
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
