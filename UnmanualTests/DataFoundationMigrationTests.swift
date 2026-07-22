import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class DataFoundationMigrationTests: XCTestCase {
    func testV1SchemaFreezesExactlyTheFiveLegacyModels() {
        XCTAssertEqual(AppSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
        XCTAssertEqual(
            Set(AppSchemaV1.models.map { String(describing: $0) }),
            Set(["HRTProfile", "CountdownRecord", "RegimenVersion", "JourneyEntry", "LabRecord"])
        )
    }

    func testRealDiskV1StoreMigratesBackfillsAndReopens() throws {
        let storeURL = try makeStoreURL()
        try seedNormalV1Store(at: storeURL)

        var firstDatasetID: UUID?
        try autoreleasepool {
            let container = try AppModelContainerFactory.makeBridgeContainer(at: storeURL)
            let outcome = try LegacyV1Backfill.run(in: container, batchSize: 2)

            XCTAssertTrue(outcome.didComplete)
            XCTAssertEqual(outcome.processedRecordCount, 5)

            let context = ModelContext(container)
            let metadata = try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first)
            firstDatasetID = metadata.datasetID
            XCTAssertEqual(metadata.nextLocalRevision, 6)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordRevision>()), 5)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<MigrationIssue>()), 0)
        }

        try autoreleasepool {
            let reopened = try AppModelContainerFactory.makeBridgeContainer(at: storeURL)
            let outcome = try LegacyV1Backfill.run(in: reopened, batchSize: 2)
            let context = ModelContext(reopened)

            XCTAssertFalse(outcome.didChangeStore)
            XCTAssertEqual(try context.fetch(FetchDescriptor<DatasetMetadata>()).first?.datasetID, firstDatasetID)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordRevision>()), 5)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<JourneyEntry>()), 1)
        }
    }

    func testBackfillCheckpointResumesWithoutChangingDatasetOrDuplicatingRevisions() throws {
        let storeURL = try makeStoreURL()
        try seedNormalV1Store(at: storeURL)

        var interruptedDatasetID: UUID?
        try autoreleasepool {
            let container = try AppModelContainerFactory.makeBridgeContainer(at: storeURL)
            XCTAssertThrowsError(
                try LegacyV1Backfill.run(
                    in: container,
                    batchSize: 1,
                    interruptAfterCommittedBatches: 3
                )
            ) { error in
                XCTAssertEqual(error as? LegacyV1Backfill.Interruption, .injected)
            }
            interruptedDatasetID = ModelContext(container)
                .fetchOrNil(FetchDescriptor<DatasetMetadata>())?
                .first?
                .datasetID
        }

        try autoreleasepool {
            let reopened = try AppModelContainerFactory.makeBridgeContainer(at: storeURL)
            let outcome = try LegacyV1Backfill.run(in: reopened, batchSize: 1)
            let context = ModelContext(reopened)

            XCTAssertTrue(outcome.didComplete)
            XCTAssertEqual(context.fetchOrNil(FetchDescriptor<DatasetMetadata>())?.first?.datasetID, interruptedDatasetID)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordRevision>()), 5)
            XCTAssertEqual(try XCTUnwrap(context.fetch(FetchDescriptor<MigrationBackfillState>()).first).phase, .complete)
        }
    }

    func testAnomalousV1HistoryProducesIssuesWithoutGuessingOrDeletingFacts() throws {
        let storeURL = try makeStoreURL()
        try seedAnomalousV1Store(at: storeURL)

        var datasetID: UUID?
        var issueCount = 0
        try autoreleasepool {
            let container = try AppModelContainerFactory.makeBridgeContainer(at: storeURL)
            _ = try LegacyV1Backfill.run(in: container, batchSize: 2)
            let context = ModelContext(container)
            let issueKinds = Set(try context.fetch(FetchDescriptor<MigrationIssue>()).map(\.kind))

            XCTAssertTrue(issueKinds.contains(.duplicateProfile))
            XCTAssertTrue(issueKinds.contains(.overlappingRegimen))
            XCTAssertTrue(issueKinds.contains(.orphanedRegimenReference))
            XCTAssertTrue(issueKinds.contains(.implausibleTimestamp))
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<HRTProfile>()), 2)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<RegimenVersion>()), 2)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<JourneyEntry>()), 1)
            datasetID = try XCTUnwrap(context.fetch(FetchDescriptor<DatasetMetadata>()).first).datasetID
            issueCount = try context.fetchCount(FetchDescriptor<MigrationIssue>())
        }

        try autoreleasepool {
            let reopened = try AppModelContainerFactory.makeBridgeContainer(at: storeURL)
            let outcome = try LegacyV1Backfill.run(in: reopened, batchSize: 1)
            let context = ModelContext(reopened)

            XCTAssertFalse(outcome.didChangeStore)
            XCTAssertEqual(try context.fetch(FetchDescriptor<DatasetMetadata>()).first?.datasetID, datasetID)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<MigrationIssue>()), issueCount)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<HRTProfile>()), 2)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<RegimenVersion>()), 2)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<JourneyEntry>()), 1)
        }
    }

    private func seedNormalV1Store(at url: URL) throws {
        try autoreleasepool {
            let container = try LegacyUnversionedStoreFactory.makeContainer(at: url)
            let context = ModelContext(container)
            let regimenID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

            context.insert(
                HRTProfile(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_010)
                )
            )
            context.insert(
                CountdownRecord(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                    title: "复诊",
                    targetDate: Date(timeIntervalSince1970: 1_710_000_000),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_020)
                )
            )
            context.insert(
                RegimenVersion(
                    id: regimenID,
                    code: "R-01",
                    title: "当前方案",
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_030)
                )
            )
            context.insert(
                JourneyEntry(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                    text: "第一条",
                    kind: .moment,
                    occurredAt: Date(timeIntervalSince1970: 1_700_000_040),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_040),
                    regimenVersionID: regimenID
                )
            )
            context.insert(
                LabRecord(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                    itemName: "雌二醇",
                    itemCode: "E2",
                    rawValue: "123.4",
                    numericValue: 123.4,
                    unit: "pmol/L",
                    sampledAt: Date(timeIntervalSince1970: 1_700_000_050),
                    regimenVersionID: regimenID,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_050)
                )
            )
            try context.save()
        }
    }

    private func seedAnomalousV1Store(at url: URL) throws {
        try autoreleasepool {
            let container = try LegacyUnversionedStoreFactory.makeContainer(at: url)
            let context = ModelContext(container)
            let firstRegimenID = UUID(uuidString: "22222222-2222-2222-2222-222222222221")!

            context.insert(HRTProfile(startDate: Date(timeIntervalSince1970: 1_000), createdAt: Date(timeIntervalSince1970: 1_000)))
            context.insert(HRTProfile(startDate: Date(timeIntervalSince1970: 2_000), createdAt: Date(timeIntervalSince1970: 2_000)))
            context.insert(
                RegimenVersion(
                    id: firstRegimenID,
                    code: "R-01",
                    title: "重叠 A",
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    endedAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            )
            context.insert(
                RegimenVersion(
                    code: "R-02",
                    title: "重叠 B",
                    startedAt: Date(timeIntervalSince1970: 1_750_000_000)
                )
            )
            context.insert(
                JourneyEntry(
                    text: "孤立关系",
                    kind: .question,
                    occurredAt: Date(timeIntervalSince1970: 1_760_000_000),
                    regimenVersionID: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
                )
            )
            try context.save()
        }
    }

    private func makeStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "UnmanualDataFoundationTests", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appending(path: "fixture.store")
    }

}

private extension ModelContext {
    func fetchOrNil<T>(_ descriptor: FetchDescriptor<T>) -> [T]? where T: PersistentModel {
        try? fetch(descriptor)
    }
}
