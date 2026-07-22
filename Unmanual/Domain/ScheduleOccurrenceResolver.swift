import Foundation

struct ScheduleRuleSpec: Equatable, Sendable {
    let id: UUID
    let regimenVersionID: UUID
    let regimenItemID: UUID
    let displayName: String
    let kind: ScheduleRuleKind
    let anchorDate: CivilDateFact
    let endDate: CivilDateFact?
    let localTimes: String
    let weekdays: String
    let intervalDays: Int?
    let timeZoneBehavior: ScheduleTimeZoneBehavior
    let fixedTimeZoneIdentifier: String?
    let revision: Int
}

struct PlannedOccurrence: Identifiable, Equatable, Sendable {
    var id: String { key }

    let key: String
    let scheduleRuleID: UUID
    let scheduleRevision: Int
    let regimenVersionID: UUID
    let regimenItemID: UUID
    let displayName: String
    let localDate: CivilDateFact
    let localTime: HistoricalLocalTime
    let timeZoneIdentifier: String
    let utcOffsetSeconds: Int
    let instant: Date
}

enum ScheduleOccurrenceIssue: Equatable, Sendable {
    case invalidRule(UUID)
    case nonexistentLocalTime(UUID, CivilDateFact, String)
    case capacityExceeded
}

struct ScheduleOccurrenceResolution: Equatable, Sendable {
    let occurrences: [PlannedOccurrence]
    let issues: [ScheduleOccurrenceIssue]
}

enum ScheduleOccurrenceResolver {
    static let maximumTimesPerRule = 16
    static let maximumOccurrencesPerResolution = 4_096

    static func occurrences(
        rules: [ScheduleRuleSpec],
        interval: DateInterval,
        displayTimeZoneIdentifier: String
    ) throws -> ScheduleOccurrenceResolution {
        guard interval.duration > 0,
              let displayTimeZone = TimeZone(identifier: displayTimeZoneIdentifier) else {
            throw HistoricalTimeError.unknownTimeZone
        }

        guard rules.allSatisfy({ localTimeTokenCount($0.localTimes) <= maximumTimesPerRule }) else {
            return ScheduleOccurrenceResolution(
                occurrences: [],
                issues: [.capacityExceeded]
            )
        }

        var occurrences: [PlannedOccurrence] = []
        var issues: [ScheduleOccurrenceIssue] = []

        for rule in rules.sorted(by: stableRuleOrder) {
            let timeZone: TimeZone
            switch rule.timeZoneBehavior {
            case .floatingLocal:
                timeZone = displayTimeZone
            case .fixedZone:
                guard let identifier = rule.fixedTimeZoneIdentifier,
                      let resolved = TimeZone(identifier: identifier) else {
                    issues.append(.invalidRule(rule.id))
                    continue
                }
                timeZone = resolved
            }

            guard rule.revision > 0,
                  let times = normalizedTimes(rule.localTimes),
                  validate(rule: rule, times: times) else {
                issues.append(.invalidRule(rule.id))
                continue
            }

            let firstDate = try civilDate(containing: interval.start, in: timeZone)
            let lastInstant = interval.end.addingTimeInterval(-0.001)
            let lastDate = try civilDate(containing: lastInstant, in: timeZone)
            var civilDate = firstDate
            var examinedDays = 0

            while civilDate <= lastDate {
                examinedDays += 1
                guard examinedDays <= 3_662 else {
                    issues.append(.invalidRule(rule.id))
                    break
                }

                if civilDate >= rule.anchorDate,
                   rule.endDate.map({ civilDate < $0 }) ?? true,
                   matches(rule: rule, on: civilDate) {
                    for time in times {
                        let normalizedTime = String(format: "%02d:%02d", time.hour, time.minute)
                        guard let instant = strictInstant(
                            date: civilDate,
                            time: time,
                            timeZone: timeZone
                        ) else {
                            issues.append(.nonexistentLocalTime(rule.id, civilDate, normalizedTime))
                            continue
                        }
                        guard instant >= interval.start, instant < interval.end else { continue }
                        guard occurrences.count < maximumOccurrencesPerResolution else {
                            return ScheduleOccurrenceResolution(
                                occurrences: [],
                                issues: issues + [.capacityExceeded]
                            )
                        }
                        occurrences.append(
                            PlannedOccurrence(
                                key: occurrenceKey(
                                    ruleID: rule.id,
                                    revision: rule.revision,
                                    date: civilDate,
                                    time: time
                                ),
                                scheduleRuleID: rule.id,
                                scheduleRevision: rule.revision,
                                regimenVersionID: rule.regimenVersionID,
                                regimenItemID: rule.regimenItemID,
                                displayName: rule.displayName,
                                localDate: civilDate,
                                localTime: time,
                                timeZoneIdentifier: timeZone.identifier,
                                utcOffsetSeconds: timeZone.secondsFromGMT(for: instant),
                                instant: instant
                            )
                        )
                    }
                }
                civilDate = try addingDays(1, to: civilDate)
            }
        }

        return ScheduleOccurrenceResolution(
            occurrences: occurrences.sorted {
                $0.instant != $1.instant ? $0.instant < $1.instant : $0.key < $1.key
            },
            issues: issues
        )
    }

    static func occurrenceKey(
        ruleID: UUID,
        revision: Int,
        date: CivilDateFact,
        time: HistoricalLocalTime
    ) -> String {
        String(
            format: "occ:v1:%@:%d:%04d%02d%02dT%02d%02d",
            ruleID.uuidString.lowercased(),
            revision,
            date.year,
            date.month,
            date.day,
            time.hour,
            time.minute
        )
    }

    private static func stableRuleOrder(_ lhs: ScheduleRuleSpec, _ rhs: ScheduleRuleSpec) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }

    private static func validate(
        rule: ScheduleRuleSpec,
        times: [HistoricalLocalTime]
    ) -> Bool {
        guard !times.isEmpty,
              rule.endDate.map({ rule.anchorDate < $0 }) ?? true else {
            return false
        }
        switch rule.kind {
        case .dailyTimes:
            return rule.weekdays.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && rule.intervalDays == nil
        case .weekly:
            return normalizedWeekdays(rule.weekdays) != nil && rule.intervalDays == nil
        case .everyNDays:
            return rule.weekdays.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (rule.intervalDays.map { $0 > 0 } ?? false)
        case .oneOff:
            return times.count == 1
                && rule.weekdays.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && rule.intervalDays == nil
        }
    }

    private static func normalizedTimes(_ value: String) -> [HistoricalLocalTime]? {
        let tokens = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !tokens.isEmpty,
              tokens.count <= maximumTimesPerRule,
              tokens.allSatisfy({ !$0.isEmpty }) else { return nil }
        var parsed: [HistoricalLocalTime] = []
        for token in tokens {
            let parts = token.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].count == 2,
                  parts[1].count == 2,
                  let hour = Int(parts[0]),
                  let minute = Int(parts[1]),
                  let time = try? HistoricalLocalTime(
                    hour: hour,
                    minute: minute,
                    second: 0
                  ) else {
                return nil
            }
            parsed.append(time)
        }
        let sorted = parsed.sorted {
            ($0.hour, $0.minute) < ($1.hour, $1.minute)
        }
        guard Set(sorted.map { String(format: "%02d:%02d", $0.hour, $0.minute) }).count
                == sorted.count else {
            return nil
        }
        return sorted
    }

    private static func localTimeTokenCount(_ value: String) -> Int {
        value.split(separator: ",", omittingEmptySubsequences: false).count
    }

    private static func normalizedWeekdays(_ value: String) -> Set<Int>? {
        let tokens = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !tokens.isEmpty,
              tokens.allSatisfy({ !$0.isEmpty }),
              tokens.allSatisfy({ token in
                  guard let day = Int(token) else { return false }
                  return (1...7).contains(day)
              }) else {
            return nil
        }
        let days = tokens.compactMap(Int.init)
        guard Set(days).count == days.count else { return nil }
        return Set(days)
    }

    private static func matches(rule: ScheduleRuleSpec, on date: CivilDateFact) -> Bool {
        switch rule.kind {
        case .dailyTimes:
            return true
        case .weekly:
            guard let weekdays = normalizedWeekdays(rule.weekdays),
                  let weekday = isoWeekday(for: date) else { return false }
            return weekdays.contains(weekday)
        case .everyNDays:
            guard let intervalDays = rule.intervalDays,
                  let distance = dayDistance(from: rule.anchorDate, to: date) else {
                return false
            }
            return distance >= 0 && distance.isMultiple(of: intervalDays)
        case .oneOff:
            return date == rule.anchorDate
        }
    }

    private static func strictInstant(
        date: CivilDateFact,
        time: HistoricalLocalTime,
        timeZone: TimeZone
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let dayComponents = DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: date.year,
            month: date.month,
            day: date.day
        )
        guard let day = calendar.date(from: dayComponents),
              let candidate = calendar.nextDate(
                after: day.addingTimeInterval(-1),
                matching: DateComponents(
                    calendar: calendar,
                    timeZone: timeZone,
                    year: date.year,
                    month: date.month,
                    day: date.day,
                    hour: time.hour,
                    minute: time.minute,
                    second: 0
                ),
                matchingPolicy: .strict,
                repeatedTimePolicy: .first,
                direction: .forward
              ) else {
            return nil
        }
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: candidate
        )
        guard components.year == date.year,
              components.month == date.month,
              components.day == date.day,
              components.hour == time.hour,
              components.minute == time.minute,
              components.second == 0 else {
            return nil
        }
        return candidate
    }

    private static func civilDate(containing instant: Date, in timeZone: TimeZone) throws -> CivilDateFact {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: instant)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            throw HistoricalTimeError.invalidCivilDate
        }
        return try CivilDateFact(year: year, month: month, day: day)
    }

    private static func isoWeekday(for date: CivilDateFact) -> Int? {
        guard let value = utcCalendar.date(
            from: DateComponents(year: date.year, month: date.month, day: date.day)
        ) else { return nil }
        let foundationWeekday = utcCalendar.component(.weekday, from: value)
        return ((foundationWeekday + 5) % 7) + 1
    }

    private static func dayDistance(from start: CivilDateFact, to end: CivilDateFact) -> Int? {
        guard let startDate = utcCalendar.date(
            from: DateComponents(year: start.year, month: start.month, day: start.day)
        ), let endDate = utcCalendar.date(
            from: DateComponents(year: end.year, month: end.month, day: end.day)
        ) else { return nil }
        return utcCalendar.dateComponents([.day], from: startDate, to: endDate).day
    }

    private static func addingDays(_ days: Int, to date: CivilDateFact) throws -> CivilDateFact {
        guard let value = utcCalendar.date(
            from: DateComponents(year: date.year, month: date.month, day: date.day)
        ), let next = utcCalendar.date(byAdding: .day, value: days, to: value) else {
            throw HistoricalTimeError.invalidCivilDate
        }
        let components = utcCalendar.dateComponents([.year, .month, .day], from: next)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            throw HistoricalTimeError.invalidCivilDate
        }
        return try CivilDateFact(
            year: year,
            month: month,
            day: day
        )
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)
            ?? TimeZone(identifier: "UTC")
            ?? TimeZone.current
        return calendar
    }
}
