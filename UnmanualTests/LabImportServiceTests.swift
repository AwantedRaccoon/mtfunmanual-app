import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class LabImportServiceTests: XCTestCase {
    func testSaveStoresCompletedRowsAndSkipsBlankRows() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let writer = AppWriteActor(modelContainer: container)
        let sampledAt = Date(timeIntervalSince1970: 1_720_000_000)

        let savedCount = try await writer.saveLabImport(
            SaveLabImportCommand(
                entries: [
                    LabImportEntry(itemName: "雌二醇", itemCode: "E2", rawValue: "172", unit: "pg/mL"),
                    LabImportEntry(itemName: "睾酮", itemCode: "T", rawValue: "", unit: "")
                ],
                sampledAt: sampledAt,
                regimenVersionID: nil,
                committedAt: sampledAt
            )
        )

        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LabRecord>())
        XCTAssertEqual(savedCount, 1)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.itemCode, "E2")
        XCTAssertEqual(records.first?.rawValue, "172")
        XCTAssertEqual(records.first?.numericValue, 172)
        XCTAssertEqual(records.first?.unit, "pg/mL")
        XCTAssertEqual(
            records.first?.sampledAt,
            Date(
                timeIntervalSinceReferenceDate:
                    floor(sampledAt.timeIntervalSinceReferenceDate / 60) * 60
            )
        )
        XCTAssertNil(records.first?.regimenVersionID)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordRevision>()), 3)
    }

    func testSavePreservesASecondSampleOfTheSameItemOnTheSameDay() async throws {
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(in: container, assumedTimeZoneIdentifier: "UTC")
        let writer = AppWriteActor(modelContainer: container)
        let sampledAt = Date(timeIntervalSince1970: 1_720_000_000)
        _ = try await writer.saveLabImport(
            SaveLabImportCommand(
                entries: [
                    LabImportEntry(itemName: "雌二醇", itemCode: "E2", rawValue: "165", unit: "pg/mL")
                ],
                sampledAt: sampledAt,
                regimenVersionID: nil,
                committedAt: sampledAt
            )
        )
        let context = ModelContext(container)
        let existingID = try XCTUnwrap(context.fetch(FetchDescriptor<LabRecord>()).first?.id)

        let savedCount = try await writer.saveLabImport(
            SaveLabImportCommand(
                entries: [
                    LabImportEntry(itemName: "雌二醇", itemCode: "E2", rawValue: "172.5", unit: "pg/mL")
                ],
                sampledAt: sampledAt.addingTimeInterval(3_600),
                regimenVersionID: nil,
                committedAt: sampledAt.addingTimeInterval(3_600)
            )
        )

        let records = try context.fetch(
            FetchDescriptor<LabRecord>(sortBy: [SortDescriptor(\.sampledAt)])
        )
        XCTAssertEqual(savedCount, 1)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.id, existingID)
        XCTAssertEqual(records.first?.rawValue, "165")
        XCTAssertEqual(records.first?.numericValue, 165)
        XCTAssertEqual(records.last?.rawValue, "172.5")
        XCTAssertEqual(records.last?.numericValue, 172.5)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordRevision>()), 5)
    }

    func testChineseDecimalSeparatorIsAccepted() {
        let entry = LabImportEntry(
            itemName: "雌二醇",
            itemCode: "E2",
            rawValue: "180。5",
            unit: "pg/mL"
        )

        XCTAssertEqual(entry.numericValue, 180.5)
        XCTAssertTrue(entry.isComplete)
    }

    func testRegimenAssociationUsesTheVersionActiveOnTheSampleDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let oldRegimen = RegimenVersion(
            code: "R-01",
            title: "旧方案",
            startedAt: date(day: 1, calendar: calendar),
            endedAt: date(day: 10, calendar: calendar)
        )
        let currentRegimen = RegimenVersion(
            code: "R-02",
            title: "当前方案",
            startedAt: date(day: 10, calendar: calendar)
        )

        let result = LabImportService.regimen(
            for: date(day: 5, calendar: calendar),
            among: [currentRegimen, oldRegimen],
            calendar: calendar
        )

        XCTAssertEqual(result?.id, oldRegimen.id)
    }

    private func date(day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: day, hour: 12)) ?? Date()
    }
}
