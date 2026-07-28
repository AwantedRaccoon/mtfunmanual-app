import Foundation
import XCTest
@testable import Unmanual

final class DataResetStateMachineTests: XCTestCase {
    func testFactoryFreezesExactShapeWholeSecondsDigestAndNotificationOrder()
        throws
    {
        let fixture = try Fixture()
        let journal = try fixture.makeJournal(
            notifications: [
                .init(
                    namespace: .execution,
                    deliveryState: .pending,
                    identifier: "unmanual.exec.v1.z"
                ),
                .init(
                    namespace: .countdown,
                    deliveryState: .delivered,
                    identifier: "unmanual.countdown.v1.a"
                ),
                .init(
                    namespace: .execution,
                    deliveryState: .delivered,
                    identifier: "unmanual.exec.v1.a"
                )
            ],
            now: Date(timeIntervalSince1970: 1_234.987)
        )

        XCTAssertEqual(journal.formatVersion, 1)
        XCTAssertEqual(
            journal.createdAt,
            Date(timeIntervalSince1970: 1_234)
        )
        XCTAssertEqual(journal.createdAt, journal.updatedAt)
        XCTAssertEqual(
            journal.legacyParts.map(\.roleRawValue),
            ["main", "wal", "shm"]
        )
        XCTAssertEqual(
            journal.ownedNotifications.map {
                [
                    $0.namespaceRawValue,
                    $0.deliveryStateRawValue,
                    $0.identifier
                ].joined(separator: "|")
            },
            [
                "countdown|delivered|unmanual.countdown.v1.a",
                "execution|delivered|unmanual.exec.v1.a",
                "execution|pending|unmanual.exec.v1.z"
            ]
        )
        XCTAssertEqual(
            journal.journalDigest,
            try DataResetJournalDigest.digest(journal)
        )
        XCTAssertNoThrow(
            try DataResetJournalValidator.validate(
                journal,
                layout: fixture.layout
            )
        )
    }

    func testFactoryRejectsDuplicateOrMismatchedOwnedNotification()
        throws
    {
        let fixture = try Fixture()
        let duplicate = DataResetNotificationV1(
            namespace: .execution,
            deliveryState: .pending,
            identifier: "unmanual.exec.v1.same"
        )
        XCTAssertThrowsError(
            try fixture.makeJournal(
                notifications: [duplicate, duplicate]
            )
        )

        let mismatched = DataResetNotificationV1(
            namespace: .countdown,
            deliveryState: .pending,
            identifier: "unmanual.exec.v1.wrong-namespace"
        )
        XCTAssertThrowsError(
            try fixture.makeJournal(notifications: [mismatched])
        )
    }

    func testCodecRejectsUnknownJSONKeyAndDigestTamper() throws {
        let fixture = try Fixture()
        let journal = try fixture.makeJournal()
        let codec = DataResetJournalCodec()
        let data = try codec.encode(journal)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )
        object["unknown"] = "must fail closed"
        let unknownKeyData = try JSONSerialization.data(
            withJSONObject: object
        )
        XCTAssertThrowsError(
            try codec.decode(unknownKeyData, layout: fixture.layout)
        )

        var tampered = journal
        tampered.phaseRawValue =
            DataResetPhaseV1.quarantinePrepared.rawValue
        let tamperedData = try codec.encode(tampered)
        XCTAssertThrowsError(
            try codec.decode(tamperedData, layout: fixture.layout)
        )
    }

    func testJournalReadRejectsUnknownControlSibling()
        throws {
        let fixture = try Fixture()
        let journal = try fixture.makeJournal()
        _ = try fixture.store.writeAndReadback(journal)
        try Data("unknown".utf8).write(
            to: fixture.layout.controlDirectoryURL
                .appending(path: "unknown.json")
        )

        XCTAssertThrowsError(try fixture.store.read()) {
            guard case DataResetStateMachineError
                .unsafeFileSystemState = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }
    }

    func testJournalReadRejectsExcludedBackupPolicy()
        throws {
        let fixture = try Fixture()
        let journal = try fixture.makeJournal()
        _ = try fixture.store.writeAndReadback(journal)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var journalURL = fixture.layout.journalURL
        try journalURL.setResourceValues(values)

        XCTAssertThrowsError(try fixture.store.read()) {
            guard case DataResetStateMachineError
                .unsafeFileSystemState = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }
    }

    func testValidatorRejectsLegacyReorderingAndPathAuthorizationDrift()
        throws
    {
        let fixture = try Fixture()
        var reordered = try fixture.makeJournal()
        reordered.legacyParts.swapAt(0, 1)
        reordered.journalDigest =
            try DataResetJournalDigest.digest(reordered)
        XCTAssertThrowsError(
            try DataResetJournalValidator.validate(
                reordered,
                layout: fixture.layout
            )
        )

        var pathDrift = try fixture.makeJournal()
        pathDrift.managedRootSourcePath =
            fixture.layout.applicationSupportURL
            .appending(path: "Other").path
        pathDrift.journalDigest =
            try DataResetJournalDigest.digest(pathDrift)
        XCTAssertThrowsError(
            try DataResetJournalValidator.validate(
                pathDrift,
                layout: fixture.layout
            )
        )

        for (index, role) in
            DataResetLegacyRoleV1.allCases.enumerated()
        {
            var sourceDrift = try fixture.makeJournal()
            sourceDrift.legacyParts[index].sourcePath =
                fixture.layout.applicationSupportURL
                .appending(path: "other-\(role.rawValue)").path
            sourceDrift.journalDigest =
                try DataResetJournalDigest.digest(sourceDrift)
            XCTAssertThrowsError(
                try DataResetJournalValidator.validate(
                    sourceDrift,
                    layout: fixture.layout
                )
            ) {
                guard case DataResetStateMachineError.pathMismatch =
                    $0 else {
                    return XCTFail("unexpected error: \($0)")
                }
            }

            var quarantineDrift = try fixture.makeJournal()
            quarantineDrift.legacyParts[index].quarantinePath =
                fixture.layout.quarantineRootURL(
                    operationID: fixture.operationID
                ).appending(
                    path: "legacy",
                    directoryHint: .isDirectory
                ).appending(path: "other-\(role.rawValue)").path
            quarantineDrift.journalDigest =
                try DataResetJournalDigest.digest(quarantineDrift)
            XCTAssertThrowsError(
                try DataResetJournalValidator.validate(
                    quarantineDrift,
                    layout: fixture.layout
                )
            ) {
                guard case DataResetStateMachineError.pathMismatch =
                    $0 else {
                    return XCTFail("unexpected error: \($0)")
                }
            }
        }
    }

    func testEveryJournalPhaseRejectsRedigestedPathAuthorizationDrift()
        throws
    {
        let fixture = try Fixture()
        let journals = try everyJournalState(fixture: fixture)

        for journal in journals {
            var drift = journal
            drift.managedRootSourcePath =
                fixture.layout.applicationSupportURL
                .appending(path: "Other").path
            drift.journalDigest =
                try DataResetJournalDigest.digest(drift)

            XCTAssertThrowsError(
                try DataResetJournalValidator.validate(
                    drift,
                    layout: fixture.layout
                ),
                "phase \(journal.phaseRawValue)"
            ) {
                guard case DataResetStateMachineError.pathMismatch =
                    $0 else {
                    return XCTFail(
                        "unexpected \(journal.phaseRawValue) error: \($0)"
                    )
                }
            }
        }
    }

    func testPreparedMoveRejectsQuarantineRootParentSymlinkReplacement()
        throws
    {
        let fixture = try Fixture()
        var journal = try fixture.makeJournal()
        _ = try fixture.store.writeAndReadback(journal)
        let root = fixture.layout.quarantineRootURL(
            operationID: fixture.operationID
        )
        let legacy = root.appending(
            path: "legacy",
            directoryHint: .isDirectory
        )
        try fixture.fileSystem.createDirectory(at: root)
        try fixture.fileSystem.createDirectory(at: legacy)
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .quarantinePrepared,
            now: fixture.nextDate(),
            layout: fixture.layout
        ) {
            $0.quarantineStateRawValue =
                DataResetQuarantineStateV1.created.rawValue
        }
        _ = try fixture.store.writeAndReadback(journal)

        try FileManager.default.removeItem(at: root)
        let outside = fixture.temporaryURL.appending(
            path: "outside-root",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: root,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try DataResetQuarantineExecutor(
                store: fixture.store,
                now: fixture.nextDate
            ).advanceBeforeRestart(from: journal)
        ) {
            guard case DataResetStateMachineError
                .unsafeFileSystemState = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }
        XCTAssertEqual(
            try fixture.fileSystem.kind(
                at: fixture.layout.managedRootURL
            ),
            .directory
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: outside.path
            ).isEmpty
        )
    }

    func testLegacyMoveRejectsLegacyParentSymlinkReplacement()
        throws
    {
        let fixture = try Fixture()
        var journal = try fixture.makeJournal()
        _ = try fixture.store.writeAndReadback(journal)
        let root = fixture.layout.quarantineRootURL(
            operationID: fixture.operationID
        )
        let legacy = root.appending(
            path: "legacy",
            directoryHint: .isDirectory
        )
        try fixture.fileSystem.createDirectory(at: root)
        try fixture.fileSystem.createDirectory(at: legacy)
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .quarantinePrepared,
            now: fixture.nextDate(),
            layout: fixture.layout
        ) {
            $0.quarantineStateRawValue =
                DataResetQuarantineStateV1.created.rawValue
        }
        try fixture.fileSystem.moveItem(
            at: fixture.layout.managedRootURL,
            to: fixture.layout.managedRootQuarantineURL(
                operationID: fixture.operationID
            )
        )
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .managedRootQuarantined,
            now: fixture.nextDate(),
            layout: fixture.layout
        ) {
            $0.oldManagedRootStateRawValue =
                DataResetOldManagedRootStateV1.quarantined.rawValue
        }
        _ = try fixture.store.writeAndReadback(journal)

        try FileManager.default.removeItem(at: legacy)
        let outside = fixture.temporaryURL.appending(
            path: "outside-legacy",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: legacy,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try DataResetQuarantineExecutor(
                store: fixture.store,
                now: fixture.nextDate
            ).advanceBeforeRestart(from: journal)
        ) {
            guard case DataResetStateMachineError
                .unsafeFileSystemState = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }
        XCTAssertEqual(
            try fixture.fileSystem.kind(
                at: fixture.layout.legacySourceURL(role: .main)
            ),
            .regularFile
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: outside.path
            ).isEmpty
        )
    }

    func testEveryPreRestartJournalWriteDiskFullReopensAndContinues()
        throws
    {
        let allLegacyPresent = Dictionary(
            uniqueKeysWithValues:
                DataResetLegacyRoleV1.allCases.map { ($0, true) }
        )
        let transitionWriteCount = 7

        for failingWrite in 1...transitionWriteCount {
            let fixture = try Fixture(
                legacyPresence: allLegacyPresent
            )
            let initial = try fixture.makeJournal()
            _ = try fixture.store.writeAndReadback(initial)
            let failingFileSystem =
                FailingWriteDataResetFileSystem(
                    base: fixture.fileSystem,
                    failingWrite: failingWrite
                )
            let failingStore = DataResetJournalStore(
                layout: fixture.layout,
                fileSystem: failingFileSystem
            )

            XCTAssertThrowsError(
                try DataResetQuarantineExecutor(
                    store: failingStore,
                    now: fixture.nextDate
                ).advanceBeforeRestart(from: initial),
                "write \(failingWrite)"
            ) {
                XCTAssertEqual(
                    $0 as? DataResetStateMachineError,
                    .journalWriteFailed
                )
            }

            let persisted = try fixture.store.read()
            let recovered = try DataResetQuarantineExecutor(
                store: fixture.store,
                now: fixture.nextDate
            ).advanceBeforeRestart(from: persisted)
            XCTAssertEqual(
                recovered.phase,
                .restartRequired,
                "write \(failingWrite)"
            )
            XCTAssertEqual(
                try fixture.fileSystem.kind(
                    at: fixture.layout.managedRootURL
                ),
                .missing
            )
            XCTAssertEqual(
                try fixture.fileSystem.kind(
                    at: fixture.layout
                        .managedRootQuarantineURL(
                            operationID: fixture.operationID
                        )
                ),
                .directory
            )
            for role in DataResetLegacyRoleV1.allCases {
                XCTAssertEqual(
                    try fixture.fileSystem.kind(
                        at: fixture.layout.legacySourceURL(
                            role: role
                        )
                    ),
                    .missing
                )
                XCTAssertEqual(
                    try fixture.fileSystem.kind(
                        at: fixture.layout.legacyQuarantineURL(
                            operationID: fixture.operationID,
                            role: role
                        )
                    ),
                    .regularFile
                )
            }
        }
    }

    func testColdPurgeJournalDiskFullReopensAfterExactAction()
        throws
    {
        let allLegacyPresent = Dictionary(
            uniqueKeysWithValues:
                DataResetLegacyRoleV1.allCases.map { ($0, true) }
        )
        let fixture = try Fixture(
            legacyPresence: allLegacyPresent
        )
        let initial = try fixture.makeJournal()
        _ = try fixture.store.writeAndReadback(initial)
        let restartRequired = try DataResetQuarantineExecutor(
            store: fixture.store,
            now: fixture.nextDate
        ).advanceBeforeRestart(from: initial)
        XCTAssertEqual(
            restartRequired.phase,
            .restartRequired
        )

        let failingStore = DataResetJournalStore(
            layout: fixture.layout,
            fileSystem: FailingWriteDataResetFileSystem(
                base: fixture.fileSystem,
                failingWrite: 1
            )
        )
        XCTAssertThrowsError(
            try DataResetQuarantineExecutor(
                store: failingStore,
                now: fixture.nextDate
            ).resumeColdLaunchThroughPurge(
                from: restartRequired
            )
        ) {
            XCTAssertEqual(
                $0 as? DataResetStateMachineError,
                .journalWriteFailed
            )
        }
        XCTAssertEqual(
            try fixture.fileSystem.kind(
                at: fixture.layout.quarantineRootURL(
                    operationID: fixture.operationID
                )
            ),
            .missing
        )

        let persisted = try fixture.store.read()
        XCTAssertEqual(persisted.phase, .restartRequired)
        let recovered = try DataResetQuarantineExecutor(
            store: fixture.store,
            now: fixture.nextDate
        ).resumeColdLaunchThroughPurge(from: persisted)
        XCTAssertEqual(recovered.phase, .quarantinePurged)
    }

    func testPhaseMachineRejectsSkipAndAllowsOnlyFrozenMonotonicChain()
        throws
    {
        let fixture = try Fixture()
        var journal = try fixture.makeJournal(
            notifications: [
                .init(
                    namespace: .execution,
                    deliveryState: .pending,
                    identifier: "unmanual.exec.v1.pending"
                )
            ]
        )
        XCTAssertThrowsError(
            try DataResetStateMachine.transitioned(
                from: journal,
                to: .managedRootQuarantined,
                now: fixture.nextDate(),
                layout: fixture.layout
            )
        )

        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .quarantinePrepared,
            now: fixture.nextDate(),
            layout: fixture.layout
        ) {
            $0.quarantineStateRawValue =
                DataResetQuarantineStateV1.created.rawValue
        }
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .managedRootQuarantined,
            now: fixture.nextDate(),
            layout: fixture.layout
        ) {
            $0.oldManagedRootStateRawValue =
                DataResetOldManagedRootStateV1.quarantined.rawValue
        }
        for index in journal.legacyParts.indices
            where journal.legacyParts[index].wasPresent
        {
            journal = try DataResetStateMachine.transitioned(
                from: journal,
                to: .managedRootQuarantined,
                now: fixture.nextDate(),
                layout: fixture.layout
            ) {
                $0.legacyParts[index].stateRawValue =
                    DataResetLegacyStateV1.quarantined.rawValue
            }
        }
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .legacyPartsQuarantined,
            now: fixture.nextDate(),
            layout: fixture.layout
        )
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .restartRequired,
            now: fixture.nextDate(),
            layout: fixture.layout
        )
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .quarantinePurged,
            now: fixture.nextDate(),
            layout: fixture.layout
        ) {
            $0.oldManagedRootStateRawValue =
                DataResetOldManagedRootStateV1.purged.rawValue
            $0.quarantineStateRawValue =
                DataResetQuarantineStateV1.purged.rawValue
            for index in $0.legacyParts.indices
                where $0.legacyParts[index].wasPresent
            {
                $0.legacyParts[index].stateRawValue =
                    DataResetLegacyStateV1.purged.rawValue
            }
        }
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .freshStorePrepared,
            now: fixture.nextDate(),
            layout: fixture.layout
        )
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .freshStoreOpened,
            now: fixture.nextDate(),
            layout: fixture.layout
        ) {
            $0.freshNextLocalRevision = 1
        }
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .freshStoreOpened,
            now: fixture.nextDate(),
            layout: fixture.layout
        ) {
            $0.notificationClearRound = 1
            $0.ownedNotifications = []
        }
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .ownedNotificationsConvergedToZero,
            now: fixture.nextDate(),
            layout: fixture.layout
        )
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .verifiedEmpty,
            now: fixture.nextDate(),
            layout: fixture.layout
        )
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .complete,
            now: fixture.nextDate(),
            layout: fixture.layout
        )
        XCTAssertEqual(journal.phase, .complete)

        var frozenIdentityTamper = journal
        frozenIdentityTamper.freshDatasetID = UUID()
        frozenIdentityTamper.journalDigest =
            try DataResetJournalDigest.digest(frozenIdentityTamper)
        XCTAssertThrowsError(
            try DataResetJournalValidator.validateTransition(
                from: journal,
                to: frozenIdentityTamper,
                layout: fixture.layout
            )
        )
    }

    func testBeforeRestartQuarantinesExactSourcesAndNeverPurges()
        throws
    {
        let fixture = try Fixture(
            legacyPresence: [.main: true, .wal: true, .shm: false]
        )
        let initial = try fixture.makeJournal()
        let store = fixture.store
        try store.writeAndReadback(initial)
        let executor = DataResetQuarantineExecutor(
            store: store,
            now: fixture.nextDate
        )

        let result = try executor.advanceBeforeRestart(from: initial)

        XCTAssertEqual(result.phase, .restartRequired)
        XCTAssertEqual(
            try fixture.fileSystem.kind(
                at: fixture.layout.managedRootURL
            ),
            .missing
        )
        XCTAssertEqual(
            try fixture.fileSystem.kind(
                at: fixture.layout.quarantineRootURL(
                    operationID: initial.operationID
                )
            ),
            .directory
        )
        XCTAssertEqual(
            try fixture.fileSystem.kind(
                at: fixture.layout.legacyStoreURL
            ),
            .missing
        )
        XCTAssertEqual(
            try fixture.fileSystem.kind(
                at: fixture.layout.legacySourceURL(role: .wal)
            ),
            .missing
        )
    }

    func testPreparedMoveReplayAndColdLaunchPurgeAreIdempotent()
        throws
    {
        let fixture = try Fixture(
            legacyPresence: [.main: true, .wal: false, .shm: false]
        )
        let initial = try fixture.makeJournal()
        let root = fixture.layout.quarantineRootURL(
            operationID: initial.operationID
        )
        let legacy = root.appending(
            path: "legacy",
            directoryHint: .isDirectory
        )
        try fixture.fileSystem.createDirectory(at: root)
        try fixture.fileSystem.createDirectory(at: legacy)
        let prepared = try DataResetStateMachine.transitioned(
            from: initial,
            to: .quarantinePrepared,
            now: fixture.nextDate(),
            layout: fixture.layout
        ) {
            $0.quarantineStateRawValue =
                DataResetQuarantineStateV1.created.rawValue
        }
        try fixture.store.writeAndReadback(prepared)

        try fixture.fileSystem.moveItem(
            at: fixture.layout.managedRootURL,
            to: fixture.layout.managedRootQuarantineURL(
                operationID: initial.operationID
            )
        )
        let executor = DataResetQuarantineExecutor(
            store: fixture.store,
            now: fixture.nextDate
        )
        let restart = try executor.advanceBeforeRestart(from: prepared)
        XCTAssertEqual(restart.phase, .restartRequired)

        let purged = try executor.resumeColdLaunchThroughPurge(
            from: restart
        )
        XCTAssertEqual(purged.phase, .quarantinePurged)
        XCTAssertEqual(
            try fixture.fileSystem.kind(at: root),
            .missing
        )
        XCTAssertEqual(
            try executor.resumeColdLaunchThroughPurge(from: purged),
            purged
        )
    }

    func testColdLaunchAcceptsCrashAfterExactPurgeBeforeJournalUpdate()
        throws
    {
        let fixture = try Fixture()
        let initial = try fixture.makeJournal()
        try fixture.store.writeAndReadback(initial)
        let executor = DataResetQuarantineExecutor(
            store: fixture.store,
            now: fixture.nextDate
        )
        let restart = try executor.advanceBeforeRestart(from: initial)
        let quarantine = fixture.layout.quarantineRootURL(
            operationID: initial.operationID
        )
        try fixture.fileSystem.removeItem(at: quarantine)

        let result = try executor.resumeColdLaunchThroughPurge(
            from: restart
        )

        XCTAssertEqual(result.phase, .quarantinePurged)
    }

    func testReplayRejectsBothSourceAndTargetAndUnknownQuarantineLeaf()
        throws
    {
        let bothFixture = try Fixture()
        let initial = try bothFixture.makeJournal()
        let root = bothFixture.layout.quarantineRootURL(
            operationID: initial.operationID
        )
        try bothFixture.fileSystem.createDirectory(at: root)
        try bothFixture.fileSystem.createDirectory(
            at: root.appending(
                path: "legacy",
                directoryHint: .isDirectory
            )
        )
        try bothFixture.fileSystem.createDirectory(
            at: bothFixture.layout.managedRootQuarantineURL(
                operationID: initial.operationID
            )
        )
        let prepared = try DataResetStateMachine.transitioned(
            from: initial,
            to: .quarantinePrepared,
            now: bothFixture.nextDate(),
            layout: bothFixture.layout
        ) {
            $0.quarantineStateRawValue =
                DataResetQuarantineStateV1.created.rawValue
        }
        try bothFixture.store.writeAndReadback(prepared)
        XCTAssertThrowsError(
            try DataResetQuarantineExecutor(
                store: bothFixture.store,
                now: bothFixture.nextDate
            ).advanceBeforeRestart(from: prepared)
        )

        let unknownFixture = try Fixture()
        let unknownInitial = try unknownFixture.makeJournal()
        try unknownFixture.store.writeAndReadback(unknownInitial)
        let quarantine = unknownFixture.layout.quarantineRootURL(
            operationID: unknownInitial.operationID
        )
        try unknownFixture.fileSystem.createDirectory(at: quarantine)
        try unknownFixture.fileSystem.createDirectory(
            at: quarantine.appending(
                path: "legacy",
                directoryHint: .isDirectory
            )
        )
        try Data("unknown".utf8).write(
            to: quarantine.appending(path: "unexpected")
        )
        XCTAssertThrowsError(
            try DataResetQuarantineExecutor(
                store: unknownFixture.store,
                now: unknownFixture.nextDate
            ).advanceBeforeRestart(from: unknownInitial)
        )
    }

    private func everyJournalState(
        fixture: Fixture
    ) throws -> [DataResetJournalV1] {
        var snapshots: [DataResetJournalV1] = []
        var journal = try fixture.makeJournal(
            notifications: [
                DataResetNotificationV1(
                    namespace: .execution,
                    deliveryState: .pending,
                    identifier: "unmanual.exec.v1.pending"
                )
            ]
        )
        snapshots.append(journal)
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .quarantinePrepared,
            now: fixture.nextDate(),
            layout: fixture.layout
        ) {
            $0.quarantineStateRawValue =
                DataResetQuarantineStateV1.created.rawValue
        }
        snapshots.append(journal)
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .managedRootQuarantined,
            now: fixture.nextDate(),
            layout: fixture.layout
        ) {
            $0.oldManagedRootStateRawValue =
                DataResetOldManagedRootStateV1
                .quarantined.rawValue
        }
        snapshots.append(journal)
        for index in journal.legacyParts.indices
            where journal.legacyParts[index].wasPresent
        {
            journal = try DataResetStateMachine.transitioned(
                from: journal,
                to: .managedRootQuarantined,
                now: fixture.nextDate(),
                layout: fixture.layout
            ) {
                $0.legacyParts[index].stateRawValue =
                    DataResetLegacyStateV1
                    .quarantined.rawValue
            }
            snapshots.append(journal)
        }
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .legacyPartsQuarantined,
            now: fixture.nextDate(),
            layout: fixture.layout
        )
        snapshots.append(journal)
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .restartRequired,
            now: fixture.nextDate(),
            layout: fixture.layout
        )
        snapshots.append(journal)
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .quarantinePurged,
            now: fixture.nextDate(),
            layout: fixture.layout
        ) {
            $0.oldManagedRootStateRawValue =
                DataResetOldManagedRootStateV1.purged.rawValue
            $0.quarantineStateRawValue =
                DataResetQuarantineStateV1.purged.rawValue
            for index in $0.legacyParts.indices
                where $0.legacyParts[index].wasPresent
            {
                $0.legacyParts[index].stateRawValue =
                    DataResetLegacyStateV1.purged.rawValue
            }
        }
        snapshots.append(journal)
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .freshStorePrepared,
            now: fixture.nextDate(),
            layout: fixture.layout
        )
        snapshots.append(journal)
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .freshStoreOpened,
            now: fixture.nextDate(),
            layout: fixture.layout
        ) {
            $0.freshNextLocalRevision = 1
        }
        snapshots.append(journal)
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .freshStoreOpened,
            now: fixture.nextDate(),
            layout: fixture.layout
        ) {
            $0.notificationClearEpoch = 1
        }
        snapshots.append(journal)
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .freshStoreOpened,
            now: fixture.nextDate(),
            layout: fixture.layout
        ) {
            $0.notificationClearRound = 1
            $0.ownedNotifications = []
        }
        snapshots.append(journal)
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .ownedNotificationsConvergedToZero,
            now: fixture.nextDate(),
            layout: fixture.layout
        )
        snapshots.append(journal)
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .verifiedEmpty,
            now: fixture.nextDate(),
            layout: fixture.layout
        )
        snapshots.append(journal)
        journal = try DataResetStateMachine.transitioned(
            from: journal,
            to: .complete,
            now: fixture.nextDate(),
            layout: fixture.layout
        )
        snapshots.append(journal)
        return snapshots
    }
}

private final class Fixture: @unchecked Sendable {
    let temporaryURL: URL
    let layout: DataResetPathLayout
    let fileSystem = DataResetFoundationFileSystem()
    let operationID = UUID()
    let freshGenerationID = UUID()
    let freshDatasetID = UUID()
    let legacyPresence: [DataResetLegacyRoleV1: Bool]
    private var clock: TimeInterval = 10_000

    var store: DataResetJournalStore {
        DataResetJournalStore(
            layout: layout,
            fileSystem: fileSystem
        )
    }

    init(
        legacyPresence: [DataResetLegacyRoleV1: Bool] = [
            .main: true,
            .wal: false,
            .shm: false
        ]
    ) throws {
        self.legacyPresence = legacyPresence
        temporaryURL = FileManager.default.temporaryDirectory
            .appending(
                path: "DataResetStateMachineTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let support = temporaryURL.appending(
            path: "Application Support",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true
        )
        let managedRoot = support.appending(
            path: "Unmanual",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: false
        )
        try Data("managed".utf8).write(
            to: managedRoot.appending(path: "payload")
        )
        let legacy = support.appending(path: "default.store")
        layout = DataResetPathLayout(
            applicationSupportURL: support,
            managedRootURL: managedRoot,
            legacyStoreURL: legacy
        )
        for role in DataResetLegacyRoleV1.allCases
            where legacyPresence[role] == true
        {
            try Data(role.rawValue.utf8).write(
                to: layout.legacySourceURL(role: role)
            )
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    func nextDate() -> Date {
        clock += 1
        return Date(timeIntervalSince1970: clock)
    }

    func makeJournal(
        notifications: [DataResetNotificationV1] = [],
        now: Date? = nil
    ) throws -> DataResetJournalV1 {
        try DataResetJournalFactory.makeQuiesced(
            operationID: operationID,
            confirmedStateDigest: String(repeating: "a", count: 64),
            exclusiveManifestDigest: String(repeating: "b", count: 64),
            now: now ?? nextDate(),
            layout: layout,
            legacyPresence: legacyPresence,
            ownedNotifications: notifications,
            freshGenerationID: freshGenerationID,
            freshDatasetID: freshDatasetID
        )
    }
}

private final class FailingWriteDataResetFileSystem:
    DataResetFileSystem,
    @unchecked Sendable {
    private struct InjectedDiskFull: Error {}

    private let base: any DataResetFileSystem
    private let failingWrite: Int
    private let lock = NSLock()
    private var writeCount = 0

    init(
        base: any DataResetFileSystem,
        failingWrite: Int
    ) {
        self.base = base
        self.failingWrite = failingWrite
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
