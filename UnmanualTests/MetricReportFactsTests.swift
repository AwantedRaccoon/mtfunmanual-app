import XCTest
@testable import Unmanual

final class MetricReportFactsTests: XCTestCase {
    func testChartRecordsOnlyUseTheSelectedItemAndUnit() {
        let oldE2 = record(code: "E2", value: 140, unit: "pg/mL", day: 1)
        let newE2 = record(code: "E2", value: 170, unit: "pg/mL", day: 3)
        let convertedE2 = record(code: "E2", value: 624, unit: "pmol/L", day: 2)
        let testosterone = record(code: "T", value: 0.5, unit: "ng/mL", day: 4)

        let result = MetricReportFacts.chartRecords(
            from: [newE2, testosterone, convertedE2, oldE2],
            itemCode: "E2",
            unit: "pg/mL"
        )

        XCTAssertEqual(result.map(\.id), [oldE2.id, newE2.id])
    }

    func testOrderedItemCodesUseLatestSampleThenStableCodeOrder() {
        let records = [
            record(code: "E2", value: 170, unit: "pg/mL", day: 3),
            record(code: "T", value: 0.5, unit: "ng/mL", day: 4),
            record(code: "E2", value: 140, unit: "pg/mL", day: 1),
            record(code: "LH", value: 1.2, unit: "IU/L", day: 3)
        ]

        XCTAssertEqual(MetricReportFacts.orderedItemCodes(from: records), ["T", "E2", "LH"])
    }

    private func record(code: String, value: Double, unit: String, day: Int) -> LabRecord {
        LabRecord(
            itemName: code,
            itemCode: code,
            rawValue: String(value),
            numericValue: value,
            unit: unit,
            sampledAt: Date(timeIntervalSince1970: TimeInterval(day * 86_400))
        )
    }
}
