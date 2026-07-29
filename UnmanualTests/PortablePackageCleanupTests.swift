import CryptoKit
import Foundation
import XCTest
@testable import Unmanual

final class PortablePackageCleanupTests: XCTestCase {
    func testRecoveryWriterRestoresExistingValueWhenPostPublishFails()
        throws {
        let fixture = try makeFixture()
        let fileName = "atomic-recovery.json"
        let previous = Data(
            "{\"version\":\"previous\"}".utf8
        )
        XCTAssertEqual(
            try PortableManagedPathSecurity
                .writeRecoveryRegularFile(
                    layout: fixture.layout,
                    fileName: fileName,
                    data: previous,
                    maximumBytes: 1_024,
                    backupPolicy: .systemManaged
                ),
            previous
        )

        XCTAssertThrowsError(
            try PortableManagedPathSecurity
                .writeRecoveryRegularFile(
                    layout: fixture.layout,
                    fileName: fileName,
                    data: Data(
                        "{\"version\":\"replacement\"}".utf8
                    ),
                    maximumBytes: 1_024,
                    backupPolicy: .systemManaged,
                    afterPublish: {
                        throw NSError(
                            domain:
                                "PortableCleanupTests",
                            code: 1
                        )
                    }
                )
        )
        let destination = fixture.layout.recoveryURL
            .appending(path: fileName)
        XCTAssertEqual(
            try Data(contentsOf: destination),
            previous
        )
        let escaped = fixture.root.appending(
            path: "escaped-recovery-new.json"
        )
        XCTAssertThrowsError(
            try PortableManagedPathSecurity
                .writeRecoveryRegularFile(
                    layout: fixture.layout,
                    fileName: fileName,
                    data: Data(
                        "{\"version\":\"escaped\"}".utf8
                    ),
                    maximumBytes: 1_024,
                    backupPolicy: .systemManaged,
                    afterPublish: {
                        try FileManager.default.moveItem(
                            at: destination,
                            to: escaped
                        )
                        throw NSError(
                            domain:
                                "PortableCleanupTests",
                            code: 2
                        )
                    }
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
                atPath: fixture.layout.recoveryURL.path
            ),
            [fileName]
        )
    }

    func testRecoveryWriterUsesIndependentRollbackWhenPriorTempIsDeletedAndNewIsCorrupted()
        throws {
        let fixture = try makeFixture()
        let fileName = "atomic-recovery.json"
        let destination = fixture.layout.recoveryURL
            .appending(path: fileName)
        let previous = Data(
            "{\"version\":\"previous\"}".utf8
        )
        _ = try PortableManagedPathSecurity
            .writeRecoveryRegularFile(
                layout: fixture.layout,
                fileName: fileName,
                data: previous,
                maximumBytes: 1_024,
                backupPolicy: .systemManaged
            )

        XCTAssertThrowsError(
            try PortableManagedPathSecurity
                .writeRecoveryRegularFile(
                    layout: fixture.layout,
                    fileName: fileName,
                    data: Data(
                        "{\"version\":\"replacement\"}".utf8
                    ),
                    maximumBytes: 1_024,
                    backupPolicy: .systemManaged,
                    afterPublish: {
                        let priorTemporary = try XCTUnwrap(
                            FileManager.default
                                .contentsOfDirectory(
                                    atPath:
                                        fixture.layout
                                        .recoveryURL.path
                                )
                                .first {
                                    $0.hasPrefix(
                                        ".\(fileName).atomic-new-v1-"
                                    )
                                }
                        )
                        try FileManager.default.removeItem(
                            at: fixture.layout.recoveryURL
                                .appending(
                                    path: priorTemporary
                                )
                        )
                        let handle = try FileHandle(
                            forWritingTo: destination
                        )
                        try handle.truncate(atOffset: 0)
                        try handle.write(
                            contentsOf:
                                Data("corrupt".utf8)
                        )
                        try handle.synchronize()
                        try handle.close()
                        throw NSError(
                            domain:
                                "PortableCleanupTests",
                            code: 3
                        )
                    }
                )
        )
        XCTAssertEqual(
            try Data(contentsOf: destination),
            previous
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.layout.recoveryURL.path
            ),
            [fileName]
        )
    }

    func testCleanupJournalColdRecoveryReplaysDeterministicTransactionArtifacts()
        throws {
        let fixture = try makeFixture()
        try PortableManagedPathSecurity
            .ensureRecoveryDirectory(
                layout: fixture.layout
            )
        let fileName =
            "portable-package-cleanup-v1.json"
        let destination = fixture.layout
            .recoveryURL.appending(path: fileName)
        let old = PortablePackageCleanupJournal(
            intents: []
        )
        let new = PortablePackageCleanupJournal(
            intents: [
                PortablePackageCleanupIntent(
                    operationID: UUID(),
                    kind: .backupTransfer
                )
            ]
        )
        let oldData = try JSONEncoder
            .unmanualFoundation.encode(old)
        let newData = try JSONEncoder
            .unmanualFoundation.encode(new)
        let newName =
            AtomicControlFileTransaction.newName(
                destinationName: fileName,
                data: newData
            )
        let oldName =
            AtomicControlFileTransaction.oldName(
                destinationName: fileName,
                data: oldData
            )
        let store =
            PortablePackageCleanupJournalStore(
                layout: fixture.layout
            )

        try oldData.write(to: destination)
        try newData.write(
            to: fixture.layout.recoveryURL
                .appending(path: newName)
        )
        try oldData.write(
            to: fixture.layout.recoveryURL
                .appending(path: oldName)
        )
        XCTAssertEqual(
            try store.readIfPresent(),
            old
        )
        XCTAssertEqual(
            try FileManager.default
                .contentsOfDirectory(
                    atPath:
                        fixture.layout.recoveryURL.path
                ),
            [fileName]
        )

        try FileManager.default.removeItem(
            at: destination
        )
        try newData.write(to: destination)
        try oldData.write(
            to: fixture.layout.recoveryURL
                .appending(path: newName)
        )
        try oldData.write(
            to: fixture.layout.recoveryURL
                .appending(path: oldName)
        )
        XCTAssertEqual(
            try store.readIfPresent(),
            new
        )
        XCTAssertEqual(
            try FileManager.default
                .contentsOfDirectory(
                    atPath:
                        fixture.layout.recoveryURL.path
                ),
            [fileName]
        )
    }

    func testLegacyV1JournalIsValidatedAndMigratedOnNextWrite()
        throws {
        let fixture = try makeFixture()
        try PortableManagedPathSecurity.ensureRecoveryDirectory(
            layout: fixture.layout
        )
        let operationID = UUID()
        let kind = PortablePackageArtifactKind.backupTransfer
        let state =
            PortablePackageCleanupIntentState.cleanupPending
        let relativePath =
            PortablePackageCleanupIntent.relativePath(
                operationID: operationID,
                kind: kind
            )
        let intentComponents = [
            "1",
            operationID.uuidString.lowercased(),
            kind.rawValue,
            state.rawValue,
            relativePath
        ]
        let intentDigest = sha256(
            intentComponents.joined(separator: "\u{001f}")
        )
        let journalDigest = sha256(
            [
                "1",
                operationID.uuidString.lowercased()
                    + "\u{001f}" + kind.rawValue
                    + "\u{001f}" + state.rawValue
                    + "\u{001f}" + relativePath
                    + "\u{001f}" + intentDigest
            ].joined(separator: "\u{001e}")
        )
        let legacy: [String: Any] = [
            "formatVersion": 1,
            "intents": [[
                "formatVersion": 1,
                "operationID": operationID.uuidString,
                "kind": kind.rawValue,
                "state": state.rawValue,
                "relativePath": relativePath,
                "contractSHA256": intentDigest
            ]],
            "contractSHA256": journalDigest
        ]
        try JSONSerialization.data(
            withJSONObject: legacy,
            options: [.sortedKeys]
        ).write(
            to: fixture.layout
                .portablePackageCleanupJournalURL
        )

        let store = PortablePackageCleanupJournalStore(
            layout: fixture.layout
        )
        let migrated = try XCTUnwrap(
            store.readIfPresent()
        )
        XCTAssertEqual(
            migrated.intents,
            [
                PortablePackageCleanupIntent(
                    operationID: operationID,
                    kind: kind,
                    state: state
                )
            ]
        )

        try store.write(migrated)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: fixture.layout
                        .portablePackageCleanupJournalURL
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(
            object["formatVersion"] as? Int,
            PortablePackageCleanupJournal.formatVersion
        )
    }

    func testColdRetryBindsAndDeletesUnboundEmptyTransfer()
        async throws {
        let fixture = try makeFixture()
        let coordinator = PortablePackageCleanupCoordinator(
            layout: fixture.layout,
            transferRootURL: fixture.transferRoot
        )
        let intent = try await coordinator.register(
            kind: .backupTransfer
        )
        let target = await coordinator.url(for: intent)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )

        try await coordinator.retryPending(
            includeActive: true
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: target.path
            )
        )
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            []
        )
    }

    func testColdRetryReleasesUnboundIntentWhenArtifactWasNeverCreated()
        async throws {
        let fixture = try makeFixture()
        let coordinator = PortablePackageCleanupCoordinator(
            layout: fixture.layout,
            transferRootURL: fixture.transferRoot
        )
        _ = try await coordinator.register(
            kind: .backupTransfer
        )

        try await coordinator.retryPending(
            includeActive: true
        )

        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            []
        )
    }

    func testColdRetryReconcilesLegacyUnboundPendingIntent()
        async throws {
        let fixture = try makeFixture()
        let intent = PortablePackageCleanupIntent(
            operationID: UUID(),
            kind: .backupTransfer,
            state: .cleanupPending
        )
        try PortablePackageCleanupJournalStore(
            layout: fixture.layout
        ).write(
            PortablePackageCleanupJournal(
                intents: [intent]
            )
        )
        let target = fixture.transferRoot.appending(
            path: intent.relativePath,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        let coordinator = PortablePackageCleanupCoordinator(
            layout: fixture.layout,
            transferRootURL: fixture.transferRoot
        )

        try await coordinator.retryPending()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: target.path
            )
        )
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            []
        )
    }

    func testColdRetryBindsAndDeletesUnboundEmptyRestore()
        async throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(
            at: fixture.layout.recoveryURL,
            withIntermediateDirectories: true
        )
        let coordinator = PortablePackageCleanupCoordinator(
            layout: fixture.layout,
            transferRootURL: fixture.transferRoot
        )
        let operationID = UUID()
        let intent = try await coordinator.register(
            kind: .restoreStaging,
            operationID: operationID
        )
        let package = await coordinator.url(for: intent)
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )

        try await coordinator.retryPending(
            includeActive: true
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    package.deletingLastPathComponent().path
            )
        )
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            []
        )
    }

    func testColdRetryRejectsUnboundNonemptyForeignTransfer()
        async throws {
        let fixture = try makeFixture()
        let coordinator = PortablePackageCleanupCoordinator(
            layout: fixture.layout,
            transferRootURL: fixture.transferRoot
        )
        let intent = try await coordinator.register(
            kind: .importTransfer
        )
        let target = await coordinator.url(for: intent)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        let sentinel = target.appending(path: "foreign")
        try Data("keep".utf8).write(to: sentinel)

        do {
            try await coordinator.retryPending(
                includeActive: true
            )
            XCTFail("Expected fail-closed recovery")
        } catch {
            XCTAssertEqual(
                error as? PortablePackageCleanupError,
                .unsafeTarget
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: sentinel),
            Data("keep".utf8)
        )
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            [intent]
        )
    }

    func testColdRetryStopsAtSecondUnexpectedRestoreEntry()
        async throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(
            at: fixture.layout.recoveryURL,
            withIntermediateDirectories: true
        )
        let coordinator = PortablePackageCleanupCoordinator(
            layout: fixture.layout,
            transferRootURL: fixture.transferRoot
        )
        let intent = try await coordinator.register(
            kind: .restoreStaging
        )
        let package = await coordinator.url(for: intent)
        let operation = package.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        let foreign = operation.appending(
            path: "second-unexpected-entry"
        )
        try Data("keep".utf8).write(to: foreign)

        do {
            try await coordinator.retryPending(
                includeActive: true
            )
            XCTFail("Expected bounded fail-closed recovery")
        } catch {
            XCTAssertEqual(
                error as? PortablePackageCleanupError,
                .unsafeTarget
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: foreign),
            Data("keep".utf8)
        )
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            [intent]
        )
    }

    func testDiscardResolvesDurablyBoundIntentFromStaleCallerValue()
        async throws {
        let fixture = try makeFixture()
        let coordinator = PortablePackageCleanupCoordinator(
            layout: fixture.layout,
            transferRootURL: fixture.transferRoot
        )
        let stale = try await coordinator.register(
            kind: .backupTransfer
        )
        let target = await coordinator.url(for: stale)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        _ = try await bindTransfer(
            coordinator: coordinator,
            intent: stale,
            target: target
        )

        try await coordinator.discard(stale)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: target.path
            )
        )
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            []
        )
    }

    func testBoundCleanupRejectsTreeBeyondMaximumDepth()
        async throws {
        let fixture = try makeFixture()
        let coordinator = PortablePackageCleanupCoordinator(
            layout: fixture.layout,
            transferRootURL: fixture.transferRoot
        )
        var intent = try await coordinator.register(
            kind: .backupTransfer
        )
        let target = await coordinator.url(for: intent)
        var nested = target
        for component in ["one", "two", "three", "four", "five"] {
            nested = nested.appending(
                path: component,
                directoryHint: .isDirectory
            )
        }
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        let sentinel = nested.appending(path: "keep")
        try Data("keep".utf8).write(to: sentinel)
        intent = try await bindTransfer(
            coordinator: coordinator,
            intent: intent,
            target: target
        )

        do {
            try await coordinator.discard(intent)
            XCTFail("Expected depth budget rejection")
        } catch {
            XCTAssertEqual(
                error as? PortablePackageCleanupError,
                .unsafeTarget
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: sentinel),
            Data("keep".utf8)
        )
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            [intent.updatingState(.cleanupPending)]
        )
    }

    func testBoundCleanupRejectsGlobalEntryLimitPlusOne()
        async throws {
        let fixture = try makeFixture()
        let coordinator = PortablePackageCleanupCoordinator(
            layout: fixture.layout,
            transferRootURL: fixture.transferRoot
        )
        var intent = try await coordinator.register(
            kind: .importTransfer
        )
        let target = await coordinator.url(for: intent)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        let limit =
            PortableBackupLimits.maximumEntryCount
            + PortableBackupLimits.maximumAttachmentCount
            + 8
        for index in 0...limit {
            let descriptor = target.appending(
                path: String(format: "%05d", index)
            )
            FileManager.default.createFile(
                atPath: descriptor.path,
                contents: Data()
            )
        }
        intent = try await bindTransfer(
            coordinator: coordinator,
            intent: intent,
            target: target
        )

        do {
            try await coordinator.discard(intent)
            XCTFail("Expected entry budget rejection")
        } catch {
            XCTAssertEqual(
                error as? PortablePackageCleanupError,
                .unsafeTarget
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: target.path
            )
        )
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            [intent.updatingState(.cleanupPending)]
        )
    }

    func testDeleteFailureRetainsIntentAndFreshCoordinatorRetries()
        async throws {
        let fixture = try makeFixture()
        let failing =
            PortablePackageCleanupCoordinator(
                layout: fixture.layout,
                transferRootURL:
                    fixture.transferRoot,
                beforeTransferQuarantine: { _ in
                    throw CocoaError(
                        .fileWriteUnknown
                    )
                }
            )
        var intent = try await failing.register(
            kind: .backupTransfer
        )
        let target = await failing.url(for: intent)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        intent = try await bindTransfer(
            coordinator: failing,
            intent: intent,
            target: target
        )
        let foreign = fixture.transferRoot
            .appending(
                path:
                    "Unmanual-Backup-"
                    + UUID().uuidString.lowercased()
                    + ".unmanualbackup",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: foreign,
            withIntermediateDirectories: false
        )

        do {
            try await failing.discard(intent)
            XCTFail("Expected durable cleanup requirement")
        } catch {
            XCTAssertEqual(
                error as? PortablePackageCleanupError,
                .cleanupRequired
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: target.path
            )
        )
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            [intent.updatingState(.cleanupPending)]
        )

        let fresh =
            PortablePackageCleanupCoordinator(
                layout: fixture.layout,
                transferRootURL:
                    fixture.transferRoot
            )
        try await fresh.retryPending()
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: target.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: foreign.path
            )
        )
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            []
        )
    }

    func testBoundCleanupRejectsChildSymlinkWithoutTouchingExternalData()
        async throws {
        let fixture = try makeFixture()
        let external = fixture.root.appending(
            path: "external-symlink-target",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: false
        )
        let sentinel = external.appending(path: "keep")
        try Data("external".utf8).write(to: sentinel)
        let coordinator = PortablePackageCleanupCoordinator(
            layout: fixture.layout,
            transferRootURL: fixture.transferRoot
        )
        var intent = try await coordinator.register(
            kind: .backupTransfer
        )
        let target = await coordinator.url(for: intent)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        let link = target.appending(path: "linked")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: external
        )
        intent = try await bindTransfer(
            coordinator: coordinator,
            intent: intent,
            target: target
        )

        await XCTAssertThrowsErrorAsync(
            try await coordinator.discard(intent)
        ) {
            XCTAssertEqual(
                $0 as? PortablePackageCleanupError,
                .unsafeTarget
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: sentinel),
            Data("external".utf8)
        )
        XCTAssertNotNil(
            try? FileManager.default
                .destinationOfSymbolicLink(
                    atPath: link.path
                )
        )
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            [intent.updatingState(.cleanupPending)]
        )
    }

    func testBoundCleanupRejectsPreexistingExternalHardLink()
        async throws {
        let fixture = try makeFixture()
        let coordinator = PortablePackageCleanupCoordinator(
            layout: fixture.layout,
            transferRootURL: fixture.transferRoot
        )
        var intent = try await coordinator.register(
            kind: .importTransfer
        )
        let target = await coordinator.url(for: intent)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        let payload = target.appending(path: "payload")
        let external = fixture.root.appending(
            path: "external-hardlink"
        )
        let bytes = Data("sensitive".utf8)
        try bytes.write(to: payload)
        try FileManager.default.linkItem(
            at: payload,
            to: external
        )
        intent = try await bindTransfer(
            coordinator: coordinator,
            intent: intent,
            target: target
        )

        await XCTAssertThrowsErrorAsync(
            try await coordinator.discard(intent)
        ) {
            XCTAssertEqual(
                $0 as? PortablePackageCleanupError,
                .unsafeTarget
            )
        }
        XCTAssertEqual(try Data(contentsOf: payload), bytes)
        XCTAssertEqual(try Data(contentsOf: external), bytes)
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            [intent.updatingState(.cleanupPending)]
        )
    }

    func testBoundCleanupRejectsHardLinkInsertedAfterPreflight()
        async throws {
        let fixture = try makeFixture()
        let external = fixture.root.appending(
            path: "late-hardlink"
        )
        let coordinator = PortablePackageCleanupCoordinator(
            layout: fixture.layout,
            transferRootURL: fixture.transferRoot,
            beforeTransferQuarantine: { candidate in
                try FileManager.default.linkItem(
                    at: candidate.appending(path: "payload"),
                    to: external
                )
            }
        )
        var intent = try await coordinator.register(
            kind: .backupTransfer
        )
        let target = await coordinator.url(for: intent)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        let payload = target.appending(path: "payload")
        let bytes = Data("sensitive".utf8)
        try bytes.write(to: payload)
        intent = try await bindTransfer(
            coordinator: coordinator,
            intent: intent,
            target: target
        )

        await XCTAssertThrowsErrorAsync(
            try await coordinator.discard(intent)
        ) {
            XCTAssertEqual(
                $0 as? PortablePackageCleanupError,
                .unsafeTarget
            )
        }
        XCTAssertEqual(try Data(contentsOf: payload), bytes)
        XCTAssertEqual(try Data(contentsOf: external), bytes)
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            [intent.updatingState(.cleanupPending)]
        )
    }

    func testColdRetryResumesAfterSanitizeBeforeDurableMarker()
        async throws {
        let fixture = try makeFixture()
        let failing = PortablePackageCleanupCoordinator(
            layout: fixture.layout,
            transferRootURL: fixture.transferRoot,
            beforeTransferQuarantine: { _ in
                throw CocoaError(.fileWriteUnknown)
            }
        )
        var intent = try await failing.register(
            kind: .backupTransfer
        )
        let target = await failing.url(for: intent)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        try Data("sensitive".utf8).write(
            to: target.appending(path: "payload")
        )
        intent = try await bindTransfer(
            coordinator: failing,
            intent: intent,
            target: target
        )
        await XCTAssertThrowsErrorAsync(
            try await failing.discard(intent)
        )
        let pending = intent.updatingState(
            .cleanupPending
        )
        try PortableManagedPathSecurity
            .sanitizeTransferPackage(
                transferRootURL: fixture.transferRoot,
                packageName: intent.relativePath,
                expectedAnchorIdentity:
                    intent.anchorIdentity,
                expectedPackageIdentity:
                    intent.packageIdentity
            )

        let fresh = PortablePackageCleanupCoordinator(
            layout: fixture.layout,
            transferRootURL: fixture.transferRoot
        )
        try await fresh.retryPending()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: target.path
            )
        )
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            []
        )
        XCTAssertEqual(pending.state, .cleanupPending)
    }

    func testSanitizedMarkerAuthorizesMissingCanonicalRoot()
        async throws {
        let fixture = try makeFixture()
        let coordinator = PortablePackageCleanupCoordinator(
            layout: fixture.layout,
            transferRootURL: fixture.transferRoot
        )
        var intent = try await coordinator.register(
            kind: .importTransfer
        )
        let target = await coordinator.url(for: intent)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        try Data("sensitive".utf8).write(
            to: target.appending(path: "payload")
        )
        intent = try await bindTransfer(
            coordinator: coordinator,
            intent: intent,
            target: target
        )
        try PortableManagedPathSecurity
            .sanitizeTransferPackage(
                transferRootURL: fixture.transferRoot,
                packageName: intent.relativePath,
                expectedAnchorIdentity:
                    intent.anchorIdentity,
                expectedPackageIdentity:
                    intent.packageIdentity
            )
        let sanitized = intent.updatingState(.sanitized)
        try PortablePackageCleanupJournalStore(
            layout: fixture.layout
        ).write(
            PortablePackageCleanupJournal(
                intents: [sanitized]
            )
        )
        let displaced = fixture.root.appending(
            path: "displaced-transfers",
            directoryHint: .isDirectory
        )
        try FileManager.default.moveItem(
            at: fixture.transferRoot,
            to: displaced
        )

        try await coordinator.retryPending()

        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            []
        )
        let quarantine = displaced.appending(
            path: ".cleanup-" + intent.relativePath,
            directoryHint: .isDirectory
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: quarantine.path
            ),
            []
        )
    }

    func testUnboundCleanupPendingMissingArtifactRetainsIntent()
        async throws {
        let fixture = try makeFixture()
        let intent = PortablePackageCleanupIntent(
            operationID: UUID(),
            kind: .backupTransfer,
            state: .cleanupPending
        )
        try PortablePackageCleanupJournalStore(
            layout: fixture.layout
        ).write(
            PortablePackageCleanupJournal(
                intents: [intent]
            )
        )
        let coordinator = PortablePackageCleanupCoordinator(
            layout: fixture.layout,
            transferRootURL: fixture.transferRoot
        )

        await XCTAssertThrowsErrorAsync(
            try await coordinator.retryPending()
        ) {
            XCTAssertEqual(
                $0 as? PortablePackageCleanupError,
                .unsafeTarget
            )
        }
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            [intent]
        )
    }

    func testUnregisteredUUIDLookingSiblingIsNeverDeleted()
        async throws {
        let fixture = try makeFixture()
        let coordinator =
            PortablePackageCleanupCoordinator(
                layout: fixture.layout,
                transferRootURL:
                    fixture.transferRoot
            )
        let foreign = fixture.transferRoot
            .appending(
                path:
                    "Unmanual-Import-"
                    + UUID().uuidString.lowercased()
                    + ".unmanualbackup",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: foreign,
            withIntermediateDirectories: true
        )

        do {
            try await coordinator
                .discardTransferPackage(at: foreign)
            XCTFail("Expected unregistered target rejection")
        } catch {
            XCTAssertEqual(
                error as? PortablePackageCleanupError,
                .unregisteredTarget
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: foreign.path
            )
        )
    }

    func testRetryPendingDoesNotDeleteActivePackage()
        async throws {
        let fixture = try makeFixture()
        let coordinator =
            PortablePackageCleanupCoordinator(
                layout: fixture.layout,
                transferRootURL:
                    fixture.transferRoot
            )
        var intent = try await coordinator.register(
            kind: .backupTransfer
        )
        let target = await coordinator.url(for: intent)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        try Data("active".utf8).write(
            to: target.appending(path: "payload")
        )
        intent = try await bindTransfer(
            coordinator: coordinator,
            intent: intent,
            target: target
        )

        try await coordinator.retryPending()

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: target.path
            )
        )
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            [intent]
        )

        try await coordinator.discard(intent)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: target.path
            )
        )
    }

    func testProtectedRestoreIntentSurvivesReplayThenDeletesExactly()
        async throws {
        let fixture = try makeFixture()
        let coordinator =
            PortablePackageCleanupCoordinator(
                layout: fixture.layout,
                transferRootURL:
                    fixture.transferRoot
            )
        let operationID = UUID()
        var intent = try await coordinator.register(
            kind: .restoreStaging,
            operationID: operationID
        )
        let package = await coordinator.url(
            for: intent
        )
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        intent = try await bindRestore(
            coordinator: coordinator,
            intent: intent,
            package: package
        )
        let foreign = fixture.layout
            .portableRestoreStagingRootURL
            .appending(
                path: UUID().uuidString.lowercased(),
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: foreign,
            withIntermediateDirectories: false
        )

        try await coordinator.retryPending(
            protectingRestoreOperationID: operationID,
            includeActive: true
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: package.path
            )
        )

        try await coordinator.retryPending(
            includeActive: true
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    package.deletingLastPathComponent()
                        .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: foreign.path
            )
        )
    }

    func testSymlinkedRegisteredTargetFailsClosed()
        async throws {
        let fixture = try makeFixture()
        let coordinator =
            PortablePackageCleanupCoordinator(
                layout: fixture.layout,
                transferRootURL:
                    fixture.transferRoot
            )
        let intent = try await coordinator.register(
            kind: .importTransfer
        )
        let target = await coordinator.url(for: intent)
        let outside = fixture.root.appending(
            path: "outside",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: target,
            withDestinationURL: outside
        )

        do {
            try await coordinator.discard(intent)
            XCTFail("Expected symlink rejection")
        } catch {
            XCTAssertEqual(
                error as? PortablePackageCleanupError,
                .unsafeTarget
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: outside.path
            )
        )
        XCTAssertNotNil(
            try? FileManager.default
                .destinationOfSymbolicLink(
                    atPath: target.path
                )
        )
    }

    func testRecoveryAncestorSymlinkFailsClosedWithoutDeletingExternalOperation()
        async throws {
        let fixture = try makeFixture()
        let coordinator =
            PortablePackageCleanupCoordinator(
                layout: fixture.layout,
                transferRootURL:
                    fixture.transferRoot
            )
        let operationID = UUID()
        var intent = try await coordinator.register(
            kind: .restoreStaging,
            operationID: operationID
        )
        let package = await coordinator.url(
            for: intent
        )
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        intent = try await bindRestore(
            coordinator: coordinator,
            intent: intent,
            package: package
        )

        let originalRecovery = fixture.root
            .appending(
                path: "OriginalRecovery",
                directoryHint: .isDirectory
            )
        try FileManager.default.moveItem(
            at: fixture.layout.recoveryURL,
            to: originalRecovery
        )
        let externalRecovery = fixture.root
            .appending(
                path: "ExternalRecovery",
                directoryHint: .isDirectory
            )
        let externalOperation = externalRecovery
            .appending(
                path: "PortableImports",
                directoryHint: .isDirectory
            )
            .appending(
                path: operationID.uuidString
                    .lowercased(),
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
            at: fixture.layout.recoveryURL,
            withDestinationURL: externalRecovery
        )

        do {
            try await coordinator.discard(intent)
            XCTFail("Expected ancestor symlink rejection")
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
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: originalRecovery
                    .appending(
                        path:
                            "portable-package-cleanup-v1.json"
                    ).path
            )
        )
    }

    func testSymlinkedRestorePackageRootFailsBeforeAnyDeletion()
        async throws {
        let fixture = try makeFixture()
        let coordinator =
            PortablePackageCleanupCoordinator(
                layout: fixture.layout,
                transferRootURL:
                    fixture.transferRoot
            )
        let intent = try await coordinator.register(
            kind: .restoreStaging
        )
        let package = await coordinator.url(
            for: intent
        )
        try FileManager.default.createDirectory(
            at: package.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let outside = fixture.root.appending(
            path: "outside-package",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false
        )
        let sentinel = outside
            .appending(path: "must-remain.txt")
        try Data("outside".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: package,
            withDestinationURL: outside
        )

        do {
            try await coordinator.discard(intent)
            XCTFail("Expected package symlink rejection")
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
                    atPath: package.path
                )
        )
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            [intent.updatingState(.cleanupPending)]
        )
    }

    func testRegularFileRestorePackageRootFailsBeforeAnyDeletion()
        async throws {
        let fixture = try makeFixture()
        let coordinator =
            PortablePackageCleanupCoordinator(
                layout: fixture.layout,
                transferRootURL:
                    fixture.transferRoot
            )
        let intent = try await coordinator.register(
            kind: .restoreStaging
        )
        let package = await coordinator.url(
            for: intent
        )
        try FileManager.default.createDirectory(
            at: package.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-a-package".utf8)
            .write(to: package)

        do {
            try await coordinator.discard(intent)
            XCTFail("Expected package type rejection")
        } catch {
            XCTAssertEqual(
                error as? PortablePackageCleanupError,
                .unsafeTarget
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: package.path
            )
        )
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            [intent.updatingState(.cleanupPending)]
        )
    }

    func testOperationReplacementAfterValidationFailsBeforeCleanupDeletesReplacement()
        async throws {
        let fixture = try makeFixture()
        let operationID = UUID()
        let operation = fixture.layout
            .portableRestoreStagingRootURL
            .appending(
                path: operationID.uuidString
                    .lowercased(),
                directoryHint: .isDirectory
            )
        let movedOperation = fixture.layout
            .portableRestoreStagingRootURL
            .appending(
                path: ".moved-original",
                directoryHint: .isDirectory
            )
        let outside = fixture.root.appending(
            path: "outside-race",
            directoryHint: .isDirectory
        )
        let sentinel = outside
            .appending(path: "must-remain.txt")
        let coordinator =
            PortablePackageCleanupCoordinator(
                layout: fixture.layout,
                transferRootURL:
                    fixture.transferRoot,
                beforeRestoreQuarantine: {
                    try FileManager.default.moveItem(
                        at: operation,
                        to: movedOperation
                    )
                    try FileManager.default
                        .createSymbolicLink(
                            at: operation,
                            withDestinationURL: outside
                        )
                }
            )
        var intent = try await coordinator.register(
            kind: .restoreStaging,
            operationID: operationID
        )
        let package = await coordinator.url(
            for: intent
        )
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        intent = try await bindRestore(
            coordinator: coordinator,
            intent: intent,
            package: package
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false
        )
        try Data("outside".utf8).write(to: sentinel)

        do {
            try await coordinator.discard(intent)
            XCTFail("Expected replaced operation rejection")
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
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: movedOperation.path
            )
        )
        XCTAssertNotNil(
            try? FileManager.default
                .destinationOfSymbolicLink(
                    atPath: operation.path
                )
        )
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            [intent.updatingState(.cleanupPending)]
        )
    }

    func testTransferReplacementAfterValidationNeverDeletesUnregisteredSibling()
        async throws {
        let fixture = try makeFixture()
        let movedRegistered = fixture.transferRoot
            .appending(
                path: ".moved-registered",
                directoryHint: .isDirectory
            )
        let unregistered = fixture.transferRoot
            .appending(
                path: "unregistered-package",
                directoryHint: .isDirectory
            )
        let sentinel = unregistered
            .appending(path: "must-remain.txt")
        let coordinator =
            PortablePackageCleanupCoordinator(
                layout: fixture.layout,
                transferRootURL:
                    fixture.transferRoot,
                beforeTransferQuarantine: {
                    candidate in
                    try FileManager.default.moveItem(
                        at: candidate,
                        to: movedRegistered
                    )
                    try FileManager.default.moveItem(
                        at: unregistered,
                        to: candidate
                    )
                }
            )
        var intent = try await coordinator.register(
            kind: .backupTransfer
        )
        let target = await coordinator.url(for: intent)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: unregistered,
            withIntermediateDirectories: false
        )
        try Data("foreign".utf8).write(
            to: sentinel
        )
        intent = try await bindTransfer(
            coordinator: coordinator,
            intent: intent,
            target: target
        )

        do {
            try await coordinator.discard(intent)
            XCTFail("Expected replacement rejection")
        } catch {
            XCTAssertEqual(
                error as? PortablePackageCleanupError,
                .unsafeTarget
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: movedRegistered.path
            )
        )
        XCTAssertEqual(
            try String(
                contentsOf: target.appending(
                    path: "must-remain.txt"
                ),
                encoding: .utf8
            ),
            "foreign"
        )
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            [intent.updatingState(.cleanupPending)]
        )
    }

    func testTransferChildReplacementAfterValidationIsNeverDeleted()
        async throws {
        let fixture = try makeFixture()
        let movedRegisteredChild =
            fixture.transferRoot.appending(
                path: ".moved-registered-child",
                directoryHint: .isDirectory
            )
        let unregisteredChild =
            fixture.transferRoot.appending(
                path: "foreign-child",
                directoryHint: .isDirectory
            )
        let coordinator =
            PortablePackageCleanupCoordinator(
                layout: fixture.layout,
                transferRootURL:
                    fixture.transferRoot,
                beforeTransferQuarantine: {
                    candidate in
                    try FileManager.default.moveItem(
                        at: candidate.appending(
                            path: "data",
                            directoryHint: .isDirectory
                        ),
                        to: movedRegisteredChild
                    )
                    try FileManager.default.moveItem(
                        at: unregisteredChild,
                        to: candidate.appending(
                            path: "data",
                            directoryHint: .isDirectory
                        )
                    )
                }
            )
        var intent = try await coordinator.register(
            kind: .backupTransfer
        )
        let target = await coordinator.url(for: intent)
        try FileManager.default.createDirectory(
            at: target.appending(
                path: "data",
                directoryHint: .isDirectory
            ),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: unregisteredChild,
            withIntermediateDirectories: false
        )
        let sentinel = unregisteredChild
            .appending(path: "must-remain.txt")
        try Data("foreign".utf8).write(to: sentinel)
        intent = try await bindTransfer(
            coordinator: coordinator,
            intent: intent,
            target: target
        )

        do {
            try await coordinator.discard(intent)
            XCTFail("Expected child replacement rejection")
        } catch {
            XCTAssertEqual(
                error as? PortablePackageCleanupError,
                .unsafeTarget
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: movedRegisteredChild.path
            )
        )
        XCTAssertEqual(
            try String(
                contentsOf: target.appending(
                    path: "data/must-remain.txt"
                ),
                encoding: .utf8
            ),
            "foreign"
        )
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            [intent.updatingState(.cleanupPending)]
        )
    }

    func testTransferReplacementBeforeDiscardNeverDeletesReplacement()
        async throws {
        let fixture = try makeFixture()
        let coordinator =
            PortablePackageCleanupCoordinator(
                layout: fixture.layout,
                transferRootURL: fixture.transferRoot
            )
        var intent = try await coordinator.register(
            kind: .importTransfer
        )
        let target = await coordinator.url(for: intent)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        intent = try await bindTransfer(
            coordinator: coordinator,
            intent: intent,
            target: target
        )
        let original = fixture.transferRoot.appending(
            path: ".original-bound-transfer",
            directoryHint: .isDirectory
        )
        try FileManager.default.moveItem(
            at: target,
            to: original
        )
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        let sentinel = target.appending(path: "must-remain.txt")
        try Data("replacement".utf8).write(to: sentinel)

        do {
            try await coordinator.discard(intent)
            XCTFail("Expected identity mismatch")
        } catch {
            XCTAssertEqual(
                error as? PortablePackageCleanupError,
                .unsafeTarget
            )
        }
        XCTAssertEqual(
            try String(contentsOf: sentinel, encoding: .utf8),
            "replacement"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: original.path)
        )
    }

    func testRestoreReplacementBeforeDiscardNeverDeletesReplacement()
        async throws {
        let fixture = try makeFixture()
        let coordinator =
            PortablePackageCleanupCoordinator(
                layout: fixture.layout,
                transferRootURL: fixture.transferRoot
            )
        var intent = try await coordinator.register(
            kind: .restoreStaging
        )
        let package = await coordinator.url(for: intent)
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        intent = try await bindRestore(
            coordinator: coordinator,
            intent: intent,
            package: package
        )
        let operation = package.deletingLastPathComponent()
        let original = fixture.layout
            .portableRestoreStagingRootURL.appending(
                path: ".original-bound-operation",
                directoryHint: .isDirectory
            )
        try FileManager.default.moveItem(
            at: operation,
            to: original
        )
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        let sentinel = package.appending(path: "must-remain.txt")
        try Data("replacement".utf8).write(to: sentinel)

        do {
            try await coordinator.discard(intent)
            XCTFail("Expected identity mismatch")
        } catch {
            XCTAssertEqual(
                error as? PortablePackageCleanupError,
                .unsafeTarget
            )
        }
        XCTAssertEqual(
            try String(contentsOf: sentinel, encoding: .utf8),
            "replacement"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: original.path)
        )
    }

    func testConcurrentCoordinatorsDoNotLoseRegisteredIntents()
        async throws {
        let fixture = try makeFixture()
        let operationIDs = (0..<32).map {
            _ in UUID()
        }
        let intents = try await
            withThrowingTaskGroup(
                of:
                    PortablePackageCleanupIntent.self
            ) {
                group in
                for (index, operationID)
                    in operationIDs.enumerated() {
                    group.addTask {
                        let coordinator =
                            PortablePackageCleanupCoordinator(
                                layout:
                                    fixture.layout,
                                transferRootURL:
                                    fixture.transferRoot
                            )
                        return try await coordinator
                            .register(
                                kind: index.isMultiple(
                                    of: 2
                                )
                                    ? .backupTransfer
                                    : .importTransfer,
                                operationID:
                                    operationID
                            )
                    }
                }
                var values:
                    [PortablePackageCleanupIntent] = []
                for try await value in group {
                    values.append(value)
                }
                return values
            }
        let durable = try XCTUnwrap(
            PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()
        )
        XCTAssertEqual(
            Set(durable.intents.map(\.operationID)),
            Set(operationIDs)
        )
        XCTAssertEqual(
            Set(durable.intents.map(\.operationID)),
            Set(intents.map(\.operationID))
        )
    }

    func testConcurrentRegisterAndRetryNeverLoseActiveIntents()
        async throws {
        let fixture = try makeFixture()
        let operationIDs = (0..<24).map {
            _ in UUID()
        }
        let registered = try await
            withThrowingTaskGroup(
                of:
                    PortablePackageCleanupIntent?.self
            ) {
                group in
                for operationID in operationIDs {
                    group.addTask {
                        let coordinator =
                            PortablePackageCleanupCoordinator(
                                layout:
                                    fixture.layout,
                                transferRootURL:
                                    fixture.transferRoot
                            )
                        return try await coordinator
                            .register(
                                kind: .backupTransfer,
                                operationID:
                                    operationID
                            )
                    }
                    group.addTask {
                        let coordinator =
                            PortablePackageCleanupCoordinator(
                                layout:
                                    fixture.layout,
                                transferRootURL:
                                    fixture.transferRoot
                            )
                        try await coordinator.retryPending()
                        return nil
                    }
                }
                var values:
                    [PortablePackageCleanupIntent] = []
                for try await value in group {
                    if let value {
                        values.append(value)
                    }
                }
                return values
            }
        let durable = try XCTUnwrap(
            PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()
        )
        XCTAssertEqual(
            Set(durable.intents.map(\.operationID)),
            Set(operationIDs)
        )
        XCTAssertEqual(
            Set(durable.intents.map(\.operationID)),
            Set(registered.map(\.operationID))
        )
        XCTAssertTrue(
            durable.intents.allSatisfy {
                $0.state == .active
            }
        )
    }

    func testCleanupJournalWriteRejectsRecoveryReplacementWithoutWritingOutside()
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
        let store = PortablePackageCleanupJournalStore(
            layout: fixture.layout,
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
        let value = PortablePackageCleanupJournal(
            intents: [
                PortablePackageCleanupIntent(
                    operationID: UUID(),
                    kind: .backupTransfer
                )
            ]
        )

        XCTAssertThrowsError(
            try store.write(value)
        ) {
            XCTAssertEqual(
                $0 as? PortablePackageCleanupError,
                .unsafeTarget
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: externalRecovery
                    .appending(
                        path:
                            "portable-package-cleanup-v1.json"
                    ).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: originalRecovery
                    .appending(
                        path:
                            "portable-package-cleanup-v1.json"
                    ).path
            )
        )
    }

    func testColdStartupReplayClearsRegisteredTransfer()
        async throws {
        let fixture = try makeFixture()
        let coordinator =
            PortablePackageCleanupCoordinator(
                layout: fixture.layout
            )
        var intent = try await coordinator.register(
            kind: .backupTransfer
        )
        let target = await coordinator.url(for: intent)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        intent = try await bindTransfer(
            coordinator: coordinator,
            intent: intent,
            target: target
        )
        addTeardownBlock {
            _ = try? await coordinator.retryPending()
            try? FileManager.default.removeItem(at: target)
        }

        try await PortablePackageCleanupCoordinator
            .recoverBeforeStoreOpen(
                layout: fixture.layout
            )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: target.path
            )
        )
        XCTAssertEqual(
            try PortablePackageCleanupJournalStore(
                layout: fixture.layout
            ).readIfPresent()?.intents,
            []
        )
    }

    private func makeFixture() throws -> (
        root: URL,
        layout: AppDataStoreLayout,
        transferRoot: URL
    ) {
        let root = FileManager.default
            .temporaryDirectory.appending(
                path:
                    "PortableCleanupTests-"
                    + UUID().uuidString.lowercased(),
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        let transferRoot = root.appending(
            path: "Transfers",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: transferRoot,
            withIntermediateDirectories: false
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return (
            root,
            AppDataStoreLayout(
                rootURL: root.appending(
                    path: "Unmanual",
                    directoryHint: .isDirectory
                ),
                legacyStoreURL:
                    root.appending(path: "legacy.sqlite")
            ),
            transferRoot
        )
    }

    private func bindTransfer(
        coordinator: PortablePackageCleanupCoordinator,
        intent: PortablePackageCleanupIntent,
        target: URL
    ) async throws -> PortablePackageCleanupIntent {
        let identity = try PortableManagedPathSecurity
            .directoryIdentity(at: target)
        let anchor = try PortableManagedPathSecurity
            .directoryIdentity(
                at: target.deletingLastPathComponent()
            )
        return try await coordinator.bind(
            intent,
            anchorIdentity: anchor,
            rootIdentity: identity,
            packageIdentity: identity
        )
    }

    private func bindRestore(
        coordinator: PortablePackageCleanupCoordinator,
        intent: PortablePackageCleanupIntent,
        package: URL
    ) async throws -> PortablePackageCleanupIntent {
        let operationIdentity =
            try PortableManagedPathSecurity.directoryIdentity(
                at: package.deletingLastPathComponent()
            )
        let packageIdentity =
            try PortableManagedPathSecurity.directoryIdentity(
                at: package
            )
        let anchorIdentity =
            try PortableManagedPathSecurity.directoryIdentity(
                at: package.deletingLastPathComponent()
                    .deletingLastPathComponent()
            )
        return try await coordinator.bind(
            intent,
            anchorIdentity: anchorIdentity,
            rootIdentity: operationIdentity,
            packageIdentity: packageIdentity
        )
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    _ verify: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail(
            "Expected expression to throw",
            file: file,
            line: line
        )
    } catch {
        verify(error)
    }
}
