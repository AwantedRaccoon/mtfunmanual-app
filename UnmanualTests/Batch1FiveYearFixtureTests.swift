import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class Batch1FiveYearFixtureTests: XCTestCase {
    func testFiveYearLegacyFixtureMigratesWithExactCountsAndBoundedFirstRead() async throws {
        let applicationSupport = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        var applicationSupportValues = URLResourceValues()
        applicationSupportValues.isExcludedFromBackup = false
        var mutableApplicationSupport = applicationSupport
        try mutableApplicationSupport.setResourceValues(applicationSupportValues)
        let directory = applicationSupport
            .appending(path: "UnmanualFiveYearFixture", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appending(path: "legacy.sqlite")
        try seedLegacyFixture(at: legacyURL)

        let layout = AppDataStoreLayout(
            rootURL: directory.appending(path: "Foundation", directoryHint: .isDirectory),
            legacyStoreURL: legacyURL
        )
        let store = try AppDataStoreBootstrapper(
            layout: layout,
            fileProtectionVerificationMode: .simulatorTestHarness
        ).open()
        let context = ModelContext(store.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HRTProfile>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RegimenVersion>()), 24)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CountdownRecord>()), 60)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<JourneyEntry>()), 7_300)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LabRecord>()), 1_200)
        // Each legacy lab adds definition/sample/result/time plus a sample receipt.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordRevision>()), 23_113)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LabSampleRecord>()), 1_200)
        let sampleReceiptCount = try context.fetch(
            FetchDescriptor<OperationReceiptRecord>(
                predicate: #Predicate {
                    $0.resultRecordType == "LabSampleRecord"
                }
            )
        ).count
        XCTAssertEqual(sampleReceiptCount, 1_200)
        let ledger = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<OperationReceiptLedgerRecord>()
            ).first
        )
        XCTAssertEqual(ledger.receiptCount, 1_200)

        let reader = AppReadActor(modelContainer: store.container)
        let firstPage = try await reader.journeyPage(after: nil, limit: 100)
        let snapshot = try await reader.archiveSnapshot()
        XCTAssertEqual(firstPage.entries.count, 100)
        XCTAssertNotNil(firstPage.nextCursor)
        XCTAssertEqual(snapshot.journeyCount, 7_300)
        XCTAssertEqual(snapshot.labRecordCount, 1_200)
    }

    private func seedLegacyFixture(at url: URL) throws {
        let container = try LegacyUnversionedStoreFactory.makeContainer(at: url)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let base = Date(timeIntervalSince1970: 1_609_459_200)
        context.insert(HRTProfile(startDate: base, createdAt: base))

        for index in 0..<24 {
            let startedAt = base.addingTimeInterval(TimeInterval(index * 75 * 86_400))
            let endedAt = index == 23
                ? nil
                : base.addingTimeInterval(TimeInterval((index + 1) * 75 * 86_400))
            context.insert(
                RegimenVersion(
                    code: String(format: "R-%02d", index + 1),
                    title: "方案 \(index + 1)",
                    startedAt: startedAt,
                    endedAt: endedAt,
                    createdAt: startedAt
                )
            )
        }

        for index in 0..<60 {
            context.insert(
                CountdownRecord(
                    title: "日期 \(index)",
                    targetDate: base.addingTimeInterval(TimeInterval((index + 1) * 30 * 86_400)),
                    createdAt: base.addingTimeInterval(TimeInterval(index)),
                    archivedAt: index < 59 ? base.addingTimeInterval(TimeInterval(index + 100)) : nil
                )
            )
        }

        for index in 0..<7_300 {
            let occurredAt = base.addingTimeInterval(TimeInterval(index * 21_600))
            context.insert(
                JourneyEntry(
                    text: "五年旅程 \(index)",
                    kind: JourneyEntryKind.allCases[index % JourneyEntryKind.allCases.count],
                    occurredAt: occurredAt,
                    createdAt: occurredAt
                )
            )
            if index.isMultiple(of: 500) { try context.save() }
        }

        for index in 0..<1_200 {
            let sampledAt = base.addingTimeInterval(TimeInterval(index * 129_600))
            context.insert(
                LabRecord(
                    itemName: index.isMultiple(of: 2) ? "雌二醇" : "睾酮",
                    itemCode: index.isMultiple(of: 2) ? "E2" : "T",
                    rawValue: "\(index + 1)",
                    numericValue: Double(index + 1),
                    unit: "pmol/L",
                    sampledAt: sampledAt,
                    createdAt: sampledAt
                )
            )
            if index.isMultiple(of: 300) { try context.save() }
        }
        try context.save()
    }
}
