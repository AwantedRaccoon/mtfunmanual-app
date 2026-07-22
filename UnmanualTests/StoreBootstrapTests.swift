import CryptoKit
import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class StoreBootstrapTests: XCTestCase {
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

    func testV2ActiveGenerationUpgradesThroughInactiveV3CopyBeforePointerSwitch() throws {
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
        XCTAssertEqual(pointer.schemaVersion, "3.0.0")
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
        XCTAssertEqual(pointer.schemaVersion, "3.0.0")
        XCTAssertEqual(opened.storeURL, layout.storeURL(for: opened.generationID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: opened.storeURL.path))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DatasetMetadata>()), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MigrationBackfillState>()).first?.phase, .complete)
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
        // V3 adds canonical preferences, journey-profile and period facts alongside
        // the preserved legacy HRTProfile revision.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordRevision>()), 4)
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
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordRevision>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<DatasetMetadata>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<MigrationBackfillState>()), 1)
            firstDatasetID = try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first).datasetID
        }

        try autoreleasepool {
            let reopened = try makeTestBootstrapper(layout: layout).open()
            let context = ModelContext(reopened.container)

            XCTAssertEqual(reopened.origin, .existingGeneration)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordRevision>()), 1)
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
        // Five preserved legacy revisions plus six V3 canonical companion facts.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordRevision>()), 11)
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
            let container = try AppModelContainerFactory.makeReadOnlyCoreContainer(at: storeURL)
            let context = ModelContext(container)
            datasetID = try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first).datasetID
            revisionCount = try context.fetchCount(FetchDescriptor<RecordRevision>())
            // The validated V3 generation has one revision for every business fact.
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
        try pointerStore.write(
            GenerationPointer(
                generationID: UUID(),
                origin: .newInstall,
                datasetID: UUID(),
                minimumFactCount: -1,
                minimumRevisionCount: 0,
                activatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
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
            let container = try AppModelContainerFactory.makeCoreContainer(at: storeURL)
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
            let container = try AppModelContainerFactory.makeCoreContainer(at: storeURL)
            let context = ModelContext(container)
            let profile = try XCTUnwrap(context.fetch(FetchDescriptor<HRTProfile>()).first)
            profile.startDate = Date(timeIntervalSince1970: 1_800_000_000)
            try context.save()
        }

        XCTAssertThrowsError(try bootstrapper.open()) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
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
            let container = try AppModelContainerFactory.makeCoreContainer(
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

    private func seedLegacyStore(at url: URL) throws {
        try autoreleasepool {
            let container = try LegacyUnversionedStoreFactory.makeContainer(at: url)
            let context = ModelContext(container)
            context.insert(
                HRTProfile(
                    id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_001)
                )
            )
            try context.save()
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

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func profileDigest(_ profile: HRTProfile) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "HRTProfile",
            recordID: profile.id,
            fields: [
                .init("activePeriodStartDate", timestamp(profile.activePeriodStartDate)),
                .init("createdAt", timestamp(profile.createdAt)),
                .init("startDate", timestamp(profile.startDate))
            ]
        )
    }

    private func timestamp(_ date: Date) -> RecordDigestV1.Value {
        .timestampMicroseconds(Int64((date.timeIntervalSince1970 * 1_000_000).rounded()))
    }

    private func directoryEntryNames(at url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }
}
