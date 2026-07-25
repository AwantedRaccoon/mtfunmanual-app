import Foundation

enum CountdownLifecycle: String, Codable, CaseIterable, Equatable, Sendable {
    case active
    case completed
    case archived
    case deleted

    var isTerminal: Bool {
        self != .active
    }
}

enum CountdownOverdueMode: String, Codable, CaseIterable, Equatable, Sendable {
    case awaitingDecision
    case countingUp
}

enum CountdownDayState: Equatable, Sendable {
    case remaining(days: Int)
    case targetDay
    case overdueAwaitingDecision(days: Int)
    case countingUp(days: Int)
}

enum CountdownDayProjection {
    static func resolve(
        target: CivilDateFact,
        today: CivilDateFact,
        overdueMode: CountdownOverdueMode
    ) throws -> CountdownDayState {
        let difference = try dayDifference(from: today, to: target)
        if difference > 0 {
            return .remaining(days: difference)
        }
        if difference == 0 {
            return .targetDay
        }
        let elapsed = -difference
        return overdueMode == .countingUp
            ? .countingUp(days: elapsed)
            : .overdueAwaitingDecision(days: elapsed)
    }

    static func dayDifference(
        from start: CivilDateFact,
        to end: CivilDateFact
    ) throws -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let startDate = calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: start.year,
                month: start.month,
                day: start.day,
                hour: 12
            )
        ),
        let endDate = calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: end.year,
                month: end.month,
                day: end.day,
                hour: 12
            )
        ),
        let days = calendar.dateComponents(
            [.day],
            from: startDate,
            to: endDate
        ).day else {
            throw HistoricalTimeError.invalidCivilDate
        }
        return days
    }
}

enum CountdownLifecycleRules {
    static func canComplete(
        lifecycle: CountdownLifecycle,
        target: CivilDateFact,
        today: CivilDateFact
    ) -> Bool {
        lifecycle == .active && target <= today
    }

    static func canArchive(lifecycle: CountdownLifecycle) -> Bool {
        lifecycle == .active
    }

    static func canContinueCounting(
        lifecycle: CountdownLifecycle,
        target: CivilDateFact,
        today: CivilDateFact
    ) -> Bool {
        lifecycle == .active && target <= today
    }
}

enum CountdownReminderAuthorizationPolicy {
    static func shouldRequest(
        previousIntentEnabled: Bool?,
        newIntentEnabled: Bool
    ) -> Bool {
        newIntentEnabled && previousIntentEnabled != true
    }
}
