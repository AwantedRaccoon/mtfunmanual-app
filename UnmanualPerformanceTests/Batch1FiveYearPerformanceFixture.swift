import CryptoKit
import Foundation
import SwiftData
@testable import Unmanual

struct Batch1FiveYearFixtureSnapshot: Sendable {
    enum SnapshotError: Error, Equatable {
        case missingBundlePart(String)
        case hashChanged(String)
        case unexpectedLegacyCounts
    }

    let storeURL: URL
    let manifest: Batch1PerformanceFixtureManifest

    func verifyUnchanged() throws {
        for part in Self.parts {
            let url = Self.url(for: part.suffix, storeURL: storeURL)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SnapshotError.missingBundlePart(part.role)
            }
            let current = try Self.sha256(url)
            guard current == manifest.sha256[part.role] else {
                throw SnapshotError.hashChanged(part.role)
            }
        }
    }

    func copyBundle(to destinationStoreURL: URL) throws {
        try verifyUnchanged()
        try FileManager.default.createDirectory(
            at: destinationStoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        for part in Self.parts {
            let source = Self.url(for: part.suffix, storeURL: storeURL)
            let destination = Self.url(for: part.suffix, storeURL: destinationStoreURL)
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    fileprivate static let parts = [
        (role: "main", suffix: ""),
        (role: "wal", suffix: "-wal"),
        (role: "shm", suffix: "-shm")
    ]

    fileprivate static func url(for suffix: String, storeURL: URL) -> URL {
        URL(fileURLWithPath: storeURL.path + suffix)
    }

    fileprivate static func sha256(_ url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
enum Batch1FiveYearFixtureBuilder {
    static func makeSnapshot(at rootURL: URL) throws -> Batch1FiveYearFixtureSnapshot {
        let liveDirectory = rootURL.appending(path: "Live", directoryHint: .isDirectory)
        let snapshotDirectory = rootURL.appending(path: "Snapshot", directoryHint: .isDirectory)
        let liveStoreURL = liveDirectory.appending(path: "legacy.sqlite")
        let snapshotStoreURL = snapshotDirectory.appending(path: "legacy.sqlite")
        try FileManager.default.createDirectory(at: liveDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: snapshotDirectory,
            withIntermediateDirectories: true
        )

        let container = try LegacyUnversionedStoreFactory.makeContainer(at: liveStoreURL)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        try seed(context)
        try context.save()

        try withExtendedLifetime(container) {
            for part in Batch1FiveYearFixtureSnapshot.parts {
                let source = Batch1FiveYearFixtureSnapshot.url(
                    for: part.suffix,
                    storeURL: liveStoreURL
                )
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw Batch1FiveYearFixtureSnapshot.SnapshotError.missingBundlePart(part.role)
                }
                try FileManager.default.copyItem(
                    at: source,
                    to: Batch1FiveYearFixtureSnapshot.url(
                        for: part.suffix,
                        storeURL: snapshotStoreURL
                    )
                )
            }
        }

        var hashes: [String: String] = [:]
        for part in Batch1FiveYearFixtureSnapshot.parts {
            hashes[part.role] = try Batch1FiveYearFixtureSnapshot.sha256(
                Batch1FiveYearFixtureSnapshot.url(for: part.suffix, storeURL: snapshotStoreURL)
            )
        }
        let snapshot = Batch1FiveYearFixtureSnapshot(
            storeURL: snapshotStoreURL,
            manifest: Batch1PerformanceFixtureManifest(
                version: "batch1-five-year-logical-v1",
                sourceKind: "runtime source-reconstructed legacy V1 snapshot; immutable within this run; not a production user sample or cross-device frozen binary",
                counts: .legacySourceExpected,
                sha256: hashes
            )
        )
        try validateLegacySnapshot(snapshot, at: rootURL)
        try snapshot.verifyUnchanged()
        return snapshot
    }

    private static func seed(_ context: ModelContext) throws {
        let base = Date(timeIntervalSince1970: 1_609_459_200)
        context.insert(
            HRTProfile(
                id: fixedUUID(category: 1, index: 0),
                startDate: base,
                createdAt: base
            )
        )

        let regimenIDs = (0..<24).map { fixedUUID(category: 2, index: $0) }
        for index in 0..<24 {
            let startedAt = base.addingTimeInterval(TimeInterval(index * 75 * 86_400))
            let endedAt = index == 23
                ? nil
                : base.addingTimeInterval(TimeInterval((index + 1) * 75 * 86_400))
            context.insert(
                RegimenVersion(
                    id: regimenIDs[index],
                    code: String(format: "R-%02d", index + 1),
                    title: "方案 \(index + 1)",
                    startedAt: startedAt,
                    endedAt: endedAt,
                    note: "Batch 1 性能夹具",
                    createdAt: startedAt
                )
            )
        }

        for index in 0..<60 {
            context.insert(
                CountdownRecord(
                    id: fixedUUID(category: 3, index: index),
                    title: "日期 \(index + 1)",
                    targetDate: base.addingTimeInterval(TimeInterval((index + 1) * 30 * 86_400)),
                    createdAt: base.addingTimeInterval(TimeInterval(index)),
                    archivedAt: index < 59
                        ? base.addingTimeInterval(TimeInterval(index + 100))
                        : nil
                )
            )
        }

        for index in 0..<7_300 {
            let occurredAt = base.addingTimeInterval(TimeInterval(index * 21_600))
            context.insert(
                JourneyEntry(
                    id: fixedUUID(category: 4, index: index),
                    text: "五年旅程 \(index + 1)",
                    kind: JourneyEntryKind.allCases[index % JourneyEntryKind.allCases.count],
                    occurredAt: occurredAt,
                    createdAt: occurredAt,
                    regimenVersionID: index.isMultiple(of: 7)
                        ? regimenIDs[index % regimenIDs.count]
                        : nil
                )
            )
            if index.isMultiple(of: 500) { try context.save() }
        }

        for index in 0..<1_200 {
            let sampledAt = base.addingTimeInterval(TimeInterval(index * 129_600))
            context.insert(
                LabRecord(
                    id: fixedUUID(category: 5, index: index),
                    itemName: index.isMultiple(of: 2) ? "雌二醇" : "睾酮",
                    itemCode: index.isMultiple(of: 2) ? "E2" : "T",
                    rawValue: String(index + 1),
                    numericValue: Double(index + 1),
                    unit: "pmol/L",
                    sampledAt: sampledAt,
                    referenceRangeOriginal: nil,
                    contextNote: "",
                    regimenVersionID: index.isMultiple(of: 3)
                        ? regimenIDs[index % regimenIDs.count]
                        : nil,
                    createdAt: sampledAt
                )
            )
            if index.isMultiple(of: 300) { try context.save() }
        }
    }

    private static func validateLegacySnapshot(
        _ snapshot: Batch1FiveYearFixtureSnapshot,
        at rootURL: URL
    ) throws {
        let validationDirectory = rootURL.appending(
            path: "Validation",
            directoryHint: .isDirectory
        )
        let validationStoreURL = validationDirectory.appending(path: "legacy.sqlite")
        try snapshot.copyBundle(to: validationStoreURL)
        defer { try? FileManager.default.removeItem(at: validationDirectory) }
        let validationContainer = try LegacyUnversionedStoreFactory.makeContainer(
            at: validationStoreURL
        )
        let context = ModelContext(validationContainer)
        let counts = Batch1FixtureCounts(
            profiles: try context.fetchCount(FetchDescriptor<HRTProfile>()),
            regimens: try context.fetchCount(FetchDescriptor<RegimenVersion>()),
            countdowns: try context.fetchCount(FetchDescriptor<CountdownRecord>()),
            journeyEntries: try context.fetchCount(FetchDescriptor<JourneyEntry>()),
            labRecords: try context.fetchCount(FetchDescriptor<LabRecord>()),
            migrationIssues: 0,
            revisions: 8_585
        )
        guard counts == .legacySourceExpected else {
            throw Batch1FiveYearFixtureSnapshot.SnapshotError.unexpectedLegacyCounts
        }
    }

    private static func fixedUUID(category: UInt32, index: Int) -> UUID {
        UUID(
            uuidString: String(
                format: "%08x-0000-4000-8000-%012llx",
                category,
                UInt64(index + 1)
            )
        )!
    }
}

actor Batch1PerformanceWorker {
    enum WorkerError: Error, Equatable {
        case unexpectedCounts(
            expectedPrimary: Batch1FixtureCounts,
            observedPrimary: Batch1FixtureCounts,
            expectedCompanions: Batch1V3CompanionCounts,
            observedCompanions: Batch1V3CompanionCounts
        )
        case unexpectedOrigin
        case invalidTodaySnapshot
        case invalidArchiveSnapshot
        case invalidFoundationMetadata
        case quickWriteNotReadable
        case postWriteProtectionFailed
        case cleanupFailed
    }

    func runIteration(
        fixture: Batch1FiveYearFixtureSnapshot,
        rootURL: URL,
        sampleIndex: Int
    ) async throws -> Batch1PerformanceSample {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let legacyStoreURL = rootURL
            .appending(path: "Legacy", directoryHint: .isDirectory)
            .appending(path: "legacy.sqlite")
        try fixture.copyBundle(to: legacyStoreURL)
        let values = try await measureProductionBoundaries(
            layout: AppDataStoreLayout(
                rootURL: rootURL.appending(path: "Foundation", directoryHint: .isDirectory),
                legacyStoreURL: legacyStoreURL
            ),
            sampleIndex: sampleIndex
        )
        do {
            try FileManager.default.removeItem(at: rootURL)
        } catch {
            throw WorkerError.cleanupFailed
        }
        return Batch1PerformanceSample(
            sampleIndex: sampleIndex,
            migrationOpenNanoseconds: values.migration,
            todaySnapshotNanoseconds: values.today,
            archiveSnapshotNanoseconds: values.archive,
            quickJourneyWriteNanoseconds: values.write,
            cleanupSucceeded: true
        )
    }

    private func measureProductionBoundaries(
        layout: AppDataStoreLayout,
        sampleIndex: Int
    ) async throws -> (migration: Int64, today: Int64, archive: Int64, write: Int64) {
        let migrationStart = ContinuousClock.now
        let store = try AppDataStoreBootstrapper(
            layout: layout,
            backupPolicy: .production,
            fileProtectionVerificationMode: .simulatorTestHarness
        ).open()
        let migrationNanoseconds = nanoseconds(since: migrationStart)
        guard store.origin == .legacyAdoption else { throw WorkerError.unexpectedOrigin }

        try validateFoundation(store, layout: layout)
        let reader = AppReadActor(modelContainer: store.container)

        let todayStart = ContinuousClock.now
        let today = try await reader.todaySnapshot()
        let todayNanoseconds = nanoseconds(since: todayStart)
        guard today.profile != nil,
              today.countdown != nil,
              today.regimens.count == 24,
              today.labRecords.count == 32,
              today.entries.count == 8 else {
            throw WorkerError.invalidTodaySnapshot
        }

        let archiveStart = ContinuousClock.now
        let archive = try await reader.archiveSnapshot()
        let archiveNanoseconds = nanoseconds(since: archiveStart)
        guard archive.profileCount == 1,
              archive.regimenCount == 24,
              archive.countdownCount == 60,
              archive.journeyCount == 7_300,
              archive.labRecordCount == 1_200 else {
            throw WorkerError.invalidArchiveSnapshot
        }

        guard let plan = store.protectionPlan else {
            throw WorkerError.postWriteProtectionFailed
        }
        let verifier = Batch1PerformanceProtectionVerifier()
        let failureFlag = Batch1PerformanceProtectionFailureFlag()
        let writer = AppDataWriter(
            storage: AppWriteActor(modelContainer: store.container),
            verifyStoreProtection: { await verifier.verify(plan) },
            onProtectionFailure: { await failureFlag.markFailed() }
        )
        let writeID = UUID(uuidString: "ffffffff-ffff-4fff-8fff-000000000001")!
        let committedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let writeStart = ContinuousClock.now
        try await writer.addJourneyEntry(
            AddJourneyEntryCommand(
                recordID: writeID,
                text: "Batch 1 快速记录",
                kind: .moment,
                occurredAt: committedAt,
                regimenVersionID: nil,
                committedAt: committedAt
            )
        )
        let writeNanoseconds = nanoseconds(since: writeStart)
        guard !(await failureFlag.hasFailed) else {
            throw WorkerError.postWriteProtectionFailed
        }
        try validateQuickWrite(
            in: store.container,
            recordID: writeID,
            committedAt: committedAt
        )

        return (
            migration: migrationNanoseconds,
            today: todayNanoseconds,
            archive: archiveNanoseconds,
            write: writeNanoseconds
        )
    }

    private func validateFoundation(
        _ store: BootstrappedAppDataStore,
        layout: AppDataStoreLayout
    ) throws {
        let context = ModelContext(store.container)
        let counts = Batch1FixtureCounts(
            profiles: try context.fetchCount(FetchDescriptor<HRTProfile>()),
            regimens: try context.fetchCount(FetchDescriptor<RegimenVersion>()),
            countdowns: try context.fetchCount(FetchDescriptor<CountdownRecord>()),
            journeyEntries: try context.fetchCount(FetchDescriptor<JourneyEntry>()),
            labRecords: try context.fetchCount(FetchDescriptor<LabRecord>()),
            migrationIssues: try context.fetchCount(FetchDescriptor<MigrationIssue>()),
            revisions: try context.fetchCount(FetchDescriptor<RecordRevision>())
        )
        let companions = Batch1V3CompanionCounts(
            preferences: try context.fetchCount(FetchDescriptor<UserPreferencesRecord>()),
            journeyProfiles: try context.fetchCount(FetchDescriptor<HrtJourneyProfileRecord>()),
            hrtPeriods: try context.fetchCount(FetchDescriptor<HrtPeriodRecord>()),
            regimenVersions: try context.fetchCount(FetchDescriptor<RegimenPlanVersionRecord>()),
            regimenItems: try context.fetchCount(FetchDescriptor<RegimenItemRecord>()),
            scheduleRules: try context.fetchCount(FetchDescriptor<ScheduleRuleRecord>()),
            historicalTimes: try context.fetchCount(FetchDescriptor<HistoricalTimeRecord>())
        )
        guard counts == .expected, companions == .expected else {
            throw WorkerError.unexpectedCounts(
                expectedPrimary: .expected,
                observedPrimary: counts,
                expectedCompanions: .expected,
                observedCompanions: companions
            )
        }
        let metadata = try context.fetch(FetchDescriptor<DatasetMetadata>())
        let states = try context.fetch(FetchDescriptor<MigrationBackfillState>())
        let coreStates = try context.fetch(FetchDescriptor<CoreTimeRegimenBackfillState>())
        let pointer = try GenerationPointerStore(layout: layout).read()
        guard metadata.count == 1,
              states.count == 1,
              states.first?.phase == .complete,
              coreStates.count == 1,
              coreStates.first?.completedAt != nil,
              metadata.first?.nextLocalRevision == Batch1V3FoundationContract.nextLocalRevision,
              pointer.origin == .legacyAdoption,
              pointer.schemaVersion == "3.0.0",
              pointer.minimumFactCount == Batch1V3FoundationContract.activatedFactCount,
              pointer.minimumRevisionCount == Batch1V3FoundationContract.activatedRevisionCount,
              pointer.datasetID == metadata.first?.datasetID else {
            throw WorkerError.invalidFoundationMetadata
        }
    }

    private func validateQuickWrite(
        in container: ModelContainer,
        recordID: UUID,
        committedAt: Date
    ) throws {
        let context = ModelContext(container)
        var journeyDescriptor = FetchDescriptor<JourneyEntry>(
            predicate: #Predicate { $0.id == recordID }
        )
        journeyDescriptor.fetchLimit = 1
        var revisionDescriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate { $0.recordID == recordID }
        )
        revisionDescriptor.fetchLimit = 1
        let sourceRecordType = "JourneyEntry"
        var historicalDescriptor = FetchDescriptor<HistoricalTimeRecord>(
            predicate: #Predicate {
                $0.sourceRecordType == sourceRecordType && $0.sourceRecordID == recordID
            }
        )
        historicalDescriptor.fetchLimit = 1
        let journey = try context.fetch(journeyDescriptor).first
        let revision = try context.fetch(revisionDescriptor).first
        let historical = try context.fetch(historicalDescriptor).first
        let historicalRevisionID = historical.map {
            CoreTimeRegimenBackfill.stableUUID(for: $0.recordKey)
        }
        var historicalRevision: RecordRevision?
        if let historicalRevisionID {
            var descriptor = FetchDescriptor<RecordRevision>(
                predicate: #Predicate { $0.recordID == historicalRevisionID }
            )
            descriptor.fetchLimit = 1
            historicalRevision = try context.fetch(descriptor).first
        }
        let metadata = try context.fetch(FetchDescriptor<DatasetMetadata>()).first
        guard journey?.text == "Batch 1 快速记录",
              try context.fetchCount(FetchDescriptor<JourneyEntry>()) == 7_301,
              try context.fetchCount(FetchDescriptor<HistoricalTimeRecord>()) == 8_501,
              try context.fetchCount(FetchDescriptor<RecordRevision>())
                  == Batch1V3FoundationContract.postQuickWriteRevisionCount,
              revision?.recordKey == "JourneyEntry:" + recordID.uuidString.lowercased(),
              revision?.localRevision == Batch1V3FoundationContract.nextLocalRevision,
              revision?.datasetID == metadata?.datasetID,
              revision?.digestVersion == RecordDigestV1.version,
              revision?.digestHex.isEmpty == false,
              revision?.committedAt == committedAt,
              historical?.recordKey == "JourneyEntry:" + recordID.uuidString.lowercased(),
              historical?.instant == committedAt,
              historical?.associationStateRawValue == HistoricalAssociationState.resolved.rawValue,
              historicalRevision?.localRevision == Batch1V3FoundationContract.nextLocalRevision,
              historicalRevision?.datasetID == metadata?.datasetID,
              historicalRevision?.digestVersion == RecordDigestV1.version,
              historicalRevision?.digestHex.isEmpty == false,
              historicalRevision?.committedAt == committedAt,
              metadata?.lastCommittedAt == committedAt,
              metadata?.nextLocalRevision
                  == Batch1V3FoundationContract.postQuickWriteNextLocalRevision else {
            throw WorkerError.quickWriteNotReadable
        }
    }

    private func nanoseconds(since start: ContinuousClock.Instant) -> Int64 {
        let components = start.duration(to: .now).components
        return components.seconds * 1_000_000_000
            + components.attoseconds / 1_000_000_000
    }
}

private actor Batch1PerformanceProtectionVerifier {
    func verify(_ plan: StoreFileProtectionPlan) -> Bool {
        do {
            return try plan.audit().isAcceptableForCurrentPlatform
        } catch {
            return false
        }
    }
}

private actor Batch1PerformanceProtectionFailureFlag {
    private(set) var hasFailed = false

    func markFailed() {
        hasFailed = true
    }
}
