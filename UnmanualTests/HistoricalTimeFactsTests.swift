import XCTest
@testable import Unmanual

final class HistoricalTimeFactsTests: XCTestCase {
    func testCivilDateHasNoTimeZoneConversionSemantics() throws {
        let fact = try CivilDateFact(year: 2026, month: 7, day: 21)

        XCTAssertEqual(fact.iso8601, "2026-07-21")
        XCTAssertEqual(fact, try CivilDateFact(year: 2026, month: 7, day: 21))
    }

    func testDSTGapLocalTimeIsRejectedInsteadOfNormalized() throws {
        let date = try CivilDateFact(year: 2024, month: 3, day: 10)
        let localTime = try HistoricalLocalTime(hour: 2, minute: 30, second: 0)
        let candidateInstant = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2024-03-10T07:30:00Z")
        )

        XCTAssertThrowsError(
            try HistoricalTimestamp(
                validatingInstant: candidateInstant,
                localDate: date,
                localTime: localTime,
                timeZoneIdentifier: "America/New_York",
                utcOffsetSeconds: -14_400,
                precision: .minute,
                provenance: .captured
            )
        ) { error in
            XCTAssertEqual(error as? HistoricalTimeError, .localComponentsDoNotMatchInstant)
        }
    }

    func testDSTOverlapUsesRecordedOffsetToDistinguishBothInstants() throws {
        let date = try CivilDateFact(year: 2024, month: 11, day: 3)
        let localTime = try HistoricalLocalTime(hour: 1, minute: 30, second: 0)
        let formatter = ISO8601DateFormatter()
        let first = try HistoricalTimestamp(
            validatingInstant: XCTUnwrap(formatter.date(from: "2024-11-03T05:30:00Z")),
            localDate: date,
            localTime: localTime,
            timeZoneIdentifier: "America/New_York",
            utcOffsetSeconds: -14_400,
            precision: .minute,
            provenance: .captured
        )
        let second = try HistoricalTimestamp(
            validatingInstant: XCTUnwrap(formatter.date(from: "2024-11-03T06:30:00Z")),
            localDate: date,
            localTime: localTime,
            timeZoneIdentifier: "America/New_York",
            utcOffsetSeconds: -18_000,
            precision: .minute,
            provenance: .captured
        )

        XCTAssertNotEqual(first.instant, second.instant)
        XCTAssertEqual(first.localDate, second.localDate)
        XCTAssertEqual(first.localTime, second.localTime)
    }

    func testLegacyFactoryMarksAssumedProvenance() throws {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let fact = try HistoricalTimestamp.legacyAssumed(
            instant: instant,
            assumedTimeZoneIdentifier: "Asia/Shanghai"
        )

        XCTAssertEqual(fact.provenance, .migrationAssumed)
        XCTAssertEqual(fact.timeZoneIdentifier, "Asia/Shanghai")
    }

    func testCapturedMinutePrecisionRemovesHiddenSecondsAndNanoseconds() throws {
        let wholeSecond = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-22T14:35:47Z")
        )
        let input = wholeSecond.addingTimeInterval(0.321)

        let fact = try HistoricalTimestamp.captured(
            instant: input,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )

        XCTAssertEqual(
            fact.instant,
            ISO8601DateFormatter().date(from: "2026-07-22T14:35:00Z")
        )
        XCTAssertEqual(fact.localTime.second, 0)
        XCTAssertEqual(fact.localTime.nanosecond, 0)
    }

    func testValidatingInitializerRejectsPrecisionThatHidesFinerFacts() throws {
        let wholeSecond = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-22T14:35:47Z")
        )
        let subsecond = try HistoricalTimestamp.captured(
            instant: wholeSecond.addingTimeInterval(0.5),
            timeZoneIdentifier: "UTC",
            precision: .subsecond
        )

        XCTAssertThrowsError(
            try HistoricalTimestamp(
                validatingInstant: subsecond.instant,
                localDate: subsecond.localDate,
                localTime: subsecond.localTime,
                timeZoneIdentifier: "UTC",
                utcOffsetSeconds: 0,
                precision: .minute,
                provenance: .userEntered
            )
        )
        XCTAssertThrowsError(
            try HistoricalTimestamp(
                validatingInstant: subsecond.instant,
                localDate: subsecond.localDate,
                localTime: subsecond.localTime,
                timeZoneIdentifier: "UTC",
                utcOffsetSeconds: 0,
                precision: .second,
                provenance: .userEntered
            )
        )
    }

    func testDecodingRejectsPrecisionThatHidesEncodedNanoseconds() throws {
        let base = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-22T14:35:47Z")
        )
        let valid = try HistoricalTimestamp.captured(
            instant: base.addingTimeInterval(0.5),
            timeZoneIdentifier: "UTC",
            precision: .subsecond
        )
        let encoded = try JSONEncoder().encode(valid)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["precision"] = HistoricalTimestampPrecision.second.rawValue
        let invalid = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(HistoricalTimestamp.self, from: invalid))
    }

    func testLegacyFactoryNormalizesToDeclaredPrecision() throws {
        let wholeSecond = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-22T14:35:47Z")
        )
        let input = wholeSecond.addingTimeInterval(0.5)

        let minute = try HistoricalTimestamp.legacyAssumed(
            instant: input,
            assumedTimeZoneIdentifier: "UTC",
            precision: .minute
        )
        let second = try HistoricalTimestamp.legacyAssumed(
            instant: input,
            assumedTimeZoneIdentifier: "UTC",
            precision: .second
        )

        XCTAssertEqual(
            minute.instant,
            ISO8601DateFormatter().date(from: "2026-07-22T14:35:00Z")
        )
        XCTAssertEqual(minute.localTime.second, 0)
        XCTAssertEqual(minute.localTime.nanosecond, 0)
        XCTAssertEqual(second.instant, wholeSecond)
        XCTAssertEqual(second.localTime.nanosecond, 0)
    }

    func testDecodingCannotBypassCivilDateValidation() {
        let invalid = Data(#"{"year":2026,"month":2,"day":30}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(CivilDateFact.self, from: invalid))
    }

    func testDecodingCannotBypassTimestampOffsetValidation() throws {
        let valid = try HistoricalTimestamp.legacyAssumed(
            instant: Date(timeIntervalSince1970: 1_700_000_000),
            assumedTimeZoneIdentifier: "Asia/Shanghai"
        )
        let encoded = try JSONEncoder().encode(valid)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["utcOffsetSeconds"] = 0
        let invalid = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(HistoricalTimestamp.self, from: invalid))
    }
}
