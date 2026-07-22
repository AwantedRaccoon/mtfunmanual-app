import XCTest
@testable import Unmanual

final class ScheduleRuleInputNormalizerTests: XCTestCase {
    func testDailyTimesNormalizeToCanonicalSortedStorage() throws {
        let input = RegimenScheduleInput(
            kind: .dailyTimes,
            localTimes: "20:30， 8:00",
            timeZoneBehavior: .floatingLocal
        )

        let normalized = try XCTUnwrap(ScheduleRuleInputNormalizer.normalize(input))

        XCTAssertEqual(normalized.localTimes, "08:00,20:30")
        XCTAssertEqual(normalized.weekdays, "")
        XCTAssertNil(normalized.intervalDays)
        XCTAssertNil(normalized.fixedTimeZoneIdentifier)
        XCTAssertFalse(normalized.reminderEnabled)
    }

    func testWeeklyRequiresUniqueISOWeekdaysAndValidTimes() {
        XCTAssertNil(
            ScheduleRuleInputNormalizer.normalize(
                RegimenScheduleInput(
                    kind: .weekly,
                    localTimes: "08:00",
                    weekdays: "1,1,5"
                )
            )
        )
        XCTAssertNil(
            ScheduleRuleInputNormalizer.normalize(
                RegimenScheduleInput(
                    kind: .weekly,
                    localTimes: "08:00",
                    weekdays: "0,5"
                )
            )
        )
    }

    func testKindSpecificAndFixedZoneFieldsFailClosed() {
        XCTAssertNil(
            ScheduleRuleInputNormalizer.normalize(
                RegimenScheduleInput(kind: .dailyTimes, localTimes: "")
            )
        )
        XCTAssertNil(
            ScheduleRuleInputNormalizer.normalize(
                RegimenScheduleInput(
                    kind: .everyNDays,
                    localTimes: "08:00",
                    intervalDays: 0
                )
            )
        )
        XCTAssertNil(
            ScheduleRuleInputNormalizer.normalize(
                RegimenScheduleInput(
                    kind: .oneOff,
                    localTimes: "08:00,20:00"
                )
            )
        )
        XCTAssertNil(
            ScheduleRuleInputNormalizer.normalize(
                RegimenScheduleInput(
                    kind: .dailyTimes,
                    localTimes: "08:00",
                    timeZoneBehavior: .fixedZone,
                    fixedTimeZoneIdentifier: "Not/AZone"
                )
            )
        )
    }

    func testMoreThanMaximumLocalTimesFailsClosed() {
        let times = (0...ScheduleOccurrenceResolver.maximumTimesPerRule)
            .map { String(format: "00:%02d", $0) }
            .joined(separator: ",")

        XCTAssertNil(
            ScheduleRuleInputNormalizer.normalize(
                RegimenScheduleInput(
                    kind: .dailyTimes,
                    localTimes: times
                )
            )
        )
    }
}
