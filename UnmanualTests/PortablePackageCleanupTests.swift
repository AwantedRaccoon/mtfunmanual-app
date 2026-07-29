import Foundation
import XCTest
@testable import Unmanual

final class PortablePackageCleanupTests: XCTestCase {
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
        let intent = try await failing.register(
            kind: .backupTransfer
        )
        let target = await failing.url(for: intent)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
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
        let intent = try await coordinator.register(
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
        let intent = try await coordinator.register(
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
        let intent = try await coordinator.register(
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
        let intent = try await coordinator.register(
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
        let intent = try await coordinator.register(
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
        let intent = try await coordinator.register(
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
        let intent = try await coordinator.register(
            kind: .backupTransfer
        )
        let target = await coordinator.url(for: intent)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
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
}
