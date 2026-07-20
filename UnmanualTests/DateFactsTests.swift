import XCTest
@testable import Unmanual

final class DateFactsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testHRTStartDateIsDayOne() throws {
        let date = try makeDate(year: 2026, month: 7, day: 18, hour: 20)

        XCTAssertEqual(
            DateFacts.hrtDay(startDate: date, now: date, calendar: calendar),
            1
        )
    }

    func testHRTDayUsesCalendarDaysInsteadOfTwentyFourHourPeriods() throws {
        let start = try makeDate(year: 2026, month: 7, day: 18, hour: 23)
        let nextMorning = try makeDate(year: 2026, month: 7, day: 19, hour: 1)

        XCTAssertEqual(
            DateFacts.hrtDay(startDate: start, now: nextMorning, calendar: calendar),
            2
        )
    }

    func testFutureCountdownReturnsRemainingCalendarDays() throws {
        let today = try makeDate(year: 2026, month: 7, day: 18, hour: 22)
        let target = try makeDate(year: 2026, month: 7, day: 21, hour: 2)

        XCTAssertEqual(
            DateFacts.countdownDays(targetDate: target, now: today, calendar: calendar),
            3
        )
    }

    func testCountdownTargetDateIsZero() throws {
        let morning = try makeDate(year: 2026, month: 7, day: 18, hour: 8)
        let evening = try makeDate(year: 2026, month: 7, day: 18, hour: 22)

        XCTAssertEqual(
            DateFacts.countdownDays(targetDate: evening, now: morning, calendar: calendar),
            0
        )
    }

    func testPastCountdownIsNegative() throws {
        let today = try makeDate(year: 2026, month: 7, day: 18, hour: 8)
        let past = try makeDate(year: 2026, month: 7, day: 15, hour: 22)

        XCTAssertEqual(
            DateFacts.countdownDays(targetDate: past, now: today, calendar: calendar),
            -3
        )
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int) throws -> Date {
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour
        )
        return try XCTUnwrap(calendar.date(from: components))
    }
}
