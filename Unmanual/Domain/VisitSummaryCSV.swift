import Foundation

struct VisitSummaryCSVFile: Identifiable, Equatable, Sendable {
    var id: String { filename }
    let filename: String
    let data: Data
}

enum VisitSummaryCSVEncoder {
    private static let lineBreak = "\r\n"

    static func encode(_ snapshot: VisitSummarySnapshot) -> [VisitSummaryCSVFile] {
        VisitSummaryDisclosureProjection(snapshot: snapshot)
            .csvTables.map {
                file(
                    $0.filename,
                    headers: $0.headers,
                    rows: $0.rows
                )
            }
    }

    static func string(headers: [String], rows: [[String]]) -> String {
        ([headers] + rows)
            .map { row in row.map(escaped).joined(separator: ",") }
            .joined(separator: lineBreak)
            + lineBreak
    }

    private static func file(
        _ filename: String,
        headers: [String],
        rows: [[String]]
    ) -> VisitSummaryCSVFile {
        VisitSummaryCSVFile(
            filename: filename,
            data: Data(string(headers: headers, rows: rows).utf8)
        )
    }

    private static func escaped(_ input: String) -> String {
        let spreadsheetSafe: String
        if let first = input.unicodeScalars.first,
           "=+-@\t\r".unicodeScalars.contains(first) {
            spreadsheetSafe = "'" + input
        } else {
            spreadsheetSafe = input
        }
        return "\""
            + spreadsheetSafe.replacingOccurrences(of: "\"", with: "\"\"")
            + "\""
    }

}
