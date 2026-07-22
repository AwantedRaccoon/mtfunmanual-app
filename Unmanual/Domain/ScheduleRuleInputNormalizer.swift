import Foundation

enum ScheduleRuleInputNormalizer {
    static func normalize(_ input: RegimenScheduleInput) -> RegimenScheduleInput? {
        guard !input.reminderEnabled,
              (0...1_440).contains(input.defaultSnoozeMinutes),
              let localTimes = normalizedTimes(input.localTimes) else {
            return nil
        }

        let weekdays: String
        let intervalDays: Int?
        switch input.kind {
        case .dailyTimes:
            guard input.weekdays.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  input.intervalDays == nil else { return nil }
            weekdays = ""
            intervalDays = nil
        case .weekly:
            guard input.intervalDays == nil,
                  let normalized = normalizedWeekdays(input.weekdays) else { return nil }
            weekdays = normalized
            intervalDays = nil
        case .everyNDays:
            guard input.weekdays.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let interval = input.intervalDays,
                  (1...3_650).contains(interval) else { return nil }
            weekdays = ""
            intervalDays = interval
        case .oneOff:
            guard localTimes.split(separator: ",").count == 1,
                  input.weekdays.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  input.intervalDays == nil else { return nil }
            weekdays = ""
            intervalDays = nil
        }

        let fixedTimeZoneIdentifier: String?
        switch input.timeZoneBehavior {
        case .floatingLocal:
            fixedTimeZoneIdentifier = nil
        case .fixedZone:
            guard let identifier = input.fixedTimeZoneIdentifier,
                  TimeZone(identifier: identifier) != nil else { return nil }
            fixedTimeZoneIdentifier = identifier
        }

        return RegimenScheduleInput(
            id: input.id,
            kind: input.kind,
            localTimes: localTimes,
            weekdays: weekdays,
            intervalDays: intervalDays,
            timeZoneBehavior: input.timeZoneBehavior,
            fixedTimeZoneIdentifier: fixedTimeZoneIdentifier,
            reminderEnabled: false,
            defaultSnoozeMinutes: input.defaultSnoozeMinutes
        )
    }

    private static func normalizedTimes(_ rawValue: String) -> String? {
        let value = rawValue
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "；", with: ",")
        let tokens = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !tokens.isEmpty,
              tokens.count <= ScheduleOccurrenceResolver.maximumTimesPerRule,
              tokens.allSatisfy({ !$0.isEmpty }) else { return nil }

        var normalized: [String] = []
        for token in tokens {
            let parts = token.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  (1...2).contains(parts[0].count),
                  parts[1].count == 2,
                  let hour = Int(parts[0]),
                  let minute = Int(parts[1]),
                  (0...23).contains(hour),
                  (0...59).contains(minute) else { return nil }
            normalized.append(String(format: "%02d:%02d", hour, minute))
        }
        guard Set(normalized).count == normalized.count else { return nil }
        return normalized.sorted().joined(separator: ",")
    }

    private static func normalizedWeekdays(_ rawValue: String) -> String? {
        let tokens = rawValue.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let values = tokens.compactMap { Int($0) }
        guard !tokens.isEmpty,
              tokens.allSatisfy({ !$0.isEmpty }),
              values.count == tokens.count,
              values.allSatisfy({ (1...7).contains($0) }),
              Set(values).count == values.count else { return nil }
        return values.sorted().map(String.init).joined(separator: ",")
    }
}
