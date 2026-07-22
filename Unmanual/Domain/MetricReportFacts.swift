import Foundation

enum MetricReportFacts {
    static func orderedItemCodes(from records: [LabRecord]) -> [String] {
        orderedItemCodes(records: records, itemCode: \.itemCode, sampledAt: \.sampledAt)
    }

    static func orderedItemCodes(from records: [LabRecordSnapshot]) -> [String] {
        orderedItemCodes(records: records, itemCode: \.itemCode, sampledAt: \.sampledAt)
    }

    private static func orderedItemCodes<Record>(
        records: [Record],
        itemCode: KeyPath<Record, String>,
        sampledAt: KeyPath<Record, Date>
    ) -> [String] {
        Dictionary(grouping: records, by: { $0[keyPath: itemCode] })
            .compactMap { itemCode, itemRecords in
                itemRecords.map { $0[keyPath: sampledAt] }.max().map { (itemCode, $0) }
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
