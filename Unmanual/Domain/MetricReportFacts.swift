import Foundation

enum MetricReportFacts {
    static func orderedItemCodes(from records: [LabRecord]) -> [String] {
        Dictionary(grouping: records, by: \.itemCode)
            .compactMap { itemCode, itemRecords in
                itemRecords.map(\.sampledAt).max().map { (itemCode, $0) }
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                return lhs.0.localizedStandardCompare(rhs.0) == .orderedAscending
            }
            .map(\.0)
    }

    static func chartRecords(
        from records: [LabRecord],
        itemCode: String,
        unit: String
    ) -> [LabRecord] {
        records
            .filter { $0.itemCode == itemCode && $0.unit == unit }
            .sorted { $0.sampledAt < $1.sampledAt }
    }
}
