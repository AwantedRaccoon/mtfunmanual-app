import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class LabImportServiceTests: XCTestCase {
    func testSaveStoresCompletedRowsAndSkipsBlankRows() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let sampledAt = Date(timeIntervalSince1970: 1_720_000_000)
        let regimenID = UUID()

        let savedCount = try LabImportService.save(
            entries: [
                LabImportEntry(itemName: "雌二醇", itemCode: "E2", rawValue: "172", unit: "pg/mL"),
                LabImportEntry(itemName: "睾酮", itemCode: "T", rawValue: "", unit: "")
            ],
            sampledAt: sampledAt,
            regimenVersionID: regimenID,
            in: context
        )

        let records = try context.fetch(FetchDescriptor<LabRecord>())
        XCTAssertEqual(savedCount, 1)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.itemCode, "E2")
        XCTAssertEqual(records.first?.rawValue, "172")
        XCTAssertEqual(records.first?.numericValue, 172)
        XCTAssertEqual(records.first?.unit, "pg/mL")
        XCTAssertEqual(records.first?.sampledAt, sampledAt)
        XCTAssertEqual(records.first?.regimenVersionID, regimenID)
    }

    func testSaveUpdatesAnExistingItemFromTheSameSampleDay() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let sampledAt = Date(timeIntervalSince1970: 1_720_000_000)
        let existing = LabRecord(
            itemName: "雌二醇",
            itemCode: "E2",
            rawValue: "165",
            numericValue: 165,
            unit: "pg/mL",
            sampledAt: sampledAt
        )
        context.insert(existing)
        try context.save()

        let savedCount = try LabImportService.save(
            entries: [
                LabImportEntry(itemName: "雌二醇", itemCode: "E2", rawValue: "172.5", unit: "pg/mL")
            ],
            sampledAt: sampledAt.addingTimeInterval(3_600),
            regimenVersionID: nil,
            in: context
        )

        let records = try context.fetch(FetchDescriptor<LabRecord>())
        XCTAssertEqual(savedCount, 1)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, existing.id)
        XCTAssertEqual(records.first?.rawValue, "172.5")
        XCTAssertEqual(records.first?.numericValue, 172.5)
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

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: LabRecord.self, configurations: configuration)
    }

    private func date(day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: day, hour: 12)) ?? Date()
    }
}
