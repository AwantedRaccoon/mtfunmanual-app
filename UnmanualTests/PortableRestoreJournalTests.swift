import CryptoKit
import XCTest
@testable import Unmanual

final class PortableRestoreJournalTests: XCTestCase {
    func testJournalRoundTripsAndRequiresMonotonicPhase()
        throws {
        let fixture = try makeFixture()
        var journal = fixture.journal
        try fixture.store.write(journal)
        XCTAssertEqual(try fixture.store.read(), journal)

        let preparing = journal
        journal.phase = .targetDirectoryPrepared
        journal.updatedAt = journal.updatedAt.addingTimeInterval(1)
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
            of: "\"formatVersion\":1",
            with:
                "\"formatVersion\":1,\"formatVersion\":1"
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
