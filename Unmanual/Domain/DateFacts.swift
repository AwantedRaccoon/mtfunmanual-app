import Foundation

enum DateFacts {
    static func hrtDay(
        startDate: Date,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> Int {
        let start = calendar.startOfDay(for: startDate)
        let today = calendar.startOfDay(for: now)
        let elapsed = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        return max(1, elapsed + 1)
    }

    static func countdownDays(
        targetDate: Date,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> Int {
        let today = calendar.startOfDay(for: now)
        let target = calendar.startOfDay(for: targetDate)
        return calendar.dateComponents([.day], from: today, to: target).day ?? 0
    }
}

extension Date {
    var unmanualShortDateText: String {
        formatted(
            Date.FormatStyle(date: .numeric, time: .omitted)
                .locale(Locale(identifier: "zh-Hans"))
        )
    }
}

extension CivilDateFact {
    var unmanualShortDateText: String {
        "\(year)/\(month)/\(day)"
    }

    var unmanualMonthDayText: String {
        String(format: "%02d/%02d", month, day)
    }

    var unmanualFullDateText: String {
        "\(year)年\(month)月\(day)日"
    }

    var unmanualWeekdayText: String {
        guard let weekday = gregorianUTCDate.map({ gregorianUTCCalendar.component(.weekday, from: $0) })
        else {
            return ""
        }
        let symbols = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return symbols[weekday - 1]
    }

    func days(since older: CivilDateFact) -> Int? {
        guard let newerDate = gregorianUTCDate,
              let olderDate = older.gregorianUTCDate else {
            return nil
        }
        return gregorianUTCCalendar.dateComponents([.day], from: olderDate, to: newerDate).day
    }

    private var gregorianUTCDate: Date? {
        gregorianUTCCalendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: 12)
        )
    }

    private var gregorianUTCCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
