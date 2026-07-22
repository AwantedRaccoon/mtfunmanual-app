import Foundation
import XCTest
@testable import Unmanual

final class RecordDigestV1Tests: XCTestCase {
    func testGoldenVectorHasStableCanonicalBytesAndSHA256() throws {
        let recordID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let fields = [
            RecordDigestV1.Field("title", .string("e\u{301} 雌二醇")),
            RecordDigestV1.Field("enabled", .bool(true)),
            RecordDigestV1.Field("count", .integer(-2)),
            RecordDigestV1.Field("value", .double(123.5)),
            RecordDigestV1.Field("sampledAt", .timestampMicroseconds(1_700_000_000_123_456)),
            RecordDigestV1.Field("note", .null)
        ]

        let bytes = try RecordDigestV1.canonicalBytes(
            recordType: "LabRecord",
            recordID: recordID,
            fields: fields
        )

        XCTAssertEqual(
            bytes.hexString,
            "554e4d414e55414c2d5245434f52442d4449474553540001000000094c61625265636f726400112233445566778899aabbccddeeff0000000600000005636f756e7403fffffffffffffffe00000007656e61626c656402000000046e6f7465000000000973616d706c656441740700060a2418202240000000057469746c65050000000cc3a920e99b8ce4ba8ce986870000000576616c756504405ee00000000000"
        )
        XCTAssertEqual(
            try RecordDigestV1.sha256Hex(recordType: "LabRecord", recordID: recordID, fields: fields),
            "91e26abb738d400a2b848742c91ee3c19d05db0605c93dc7515783ff765db19a"
        )
    }

    func testFieldOrderUnicodeFormLocaleAndTimeZoneDoNotChangeDigest() throws {
        let id = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let composed = [
            RecordDigestV1.Field("label", .string("é")),
            RecordDigestV1.Field("instant", .timestampMicroseconds(0))
        ]
        let decomposedReordered = [
            RecordDigestV1.Field("instant", .timestampMicroseconds(0)),
            RecordDigestV1.Field("label", .string("e\u{301}"))
        ]

        let originalLocale = Locale.current
        let originalTimeZone = NSTimeZone.default
        defer {
            _ = originalLocale
            NSTimeZone.default = originalTimeZone
        }

        NSTimeZone.default = TimeZone(identifier: "Pacific/Kiritimati")!
        let first = try RecordDigestV1.sha256Hex(recordType: "Fact", recordID: id, fields: composed)
        NSTimeZone.default = TimeZone(identifier: "America/Adak")!
        let second = try RecordDigestV1.sha256Hex(recordType: "Fact", recordID: id, fields: decomposedReordered)

        XCTAssertEqual(first, second)
    }

    func testRejectsDuplicateNormalizedNamesAndNonFiniteNumbers() {
        let id = UUID()

        XCTAssertThrowsError(
            try RecordDigestV1.canonicalBytes(
                recordType: "Fact",
                recordID: id,
                fields: [
                    .init("e\u{301}", .string("one")),
                    .init("é", .string("two"))
                ]
            )
        )
        XCTAssertThrowsError(
            try RecordDigestV1.canonicalBytes(
                recordType: "Fact",
                recordID: id,
                fields: [.init("value", .double(.nan))]
            )
        )
    }

    func testFactDigestRejectsNonFiniteTimestampInsteadOfTrapping() {
        let profile = HRTProfile(
            startDate: Date(timeIntervalSince1970: .nan),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertThrowsError(try FactDigestV1.digest(profile)) { error in
            XCTAssertEqual(
                error as? RecordDigestV1.EncodingError,
                .timestampOutOfRange
            )
        }
    }

    func testSharedTimestampEncoderRejectsFiniteOutOfRangeDate() {
        let date = Date(timeIntervalSince1970: 1e20)
        XCTAssertTrue(date.timeIntervalSince1970.isFinite)

        XCTAssertThrowsError(try RecordDigestV1.timestampValue(date)) { error in
            XCTAssertEqual(
                error as? RecordDigestV1.EncodingError,
                .timestampOutOfRange
            )
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
