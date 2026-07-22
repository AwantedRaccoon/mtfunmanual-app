import Foundation

enum HistoricalTimeError: Error, Equatable, Sendable {
    case invalidCivilDate
    case invalidLocalTime
    case unknownTimeZone
    case offsetDoesNotMatchInstant
    case localComponentsDoNotMatchInstant
}

struct CivilDateFact: Codable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else {
            throw HistoricalTimeError.invalidCivilDate
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else {
            throw HistoricalTimeError.invalidCivilDate
        }
        self.year = year
        self.month = month
        self.day = day
    }

    private enum CodingKeys: String, CodingKey {
        case year
        case month
        case day
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            year: container.decode(Int.self, forKey: .year),
            month: container.decode(Int.self, forKey: .month),
            day: container.decode(Int.self, forKey: .day)
        )
    }

    var iso8601: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func < (lhs: CivilDateFact, rhs: CivilDateFact) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

struct HistoricalLocalTime: Codable, Equatable, Sendable {
    let hour: Int
    let minute: Int
    let second: Int
    let nanosecond: Int

    init(hour: Int, minute: Int, second: Int, nanosecond: Int = 0) throws {
        guard (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second),
              (0...999_999_999).contains(nanosecond) else {
            throw HistoricalTimeError.invalidLocalTime
        }
        self.hour = hour
        self.minute = minute
        self.second = second
        self.nanosecond = nanosecond
    }

    private enum CodingKeys: String, CodingKey {
        case hour
        case minute
        case second
        case nanosecond
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            hour: container.decode(Int.self, forKey: .hour),
            minute: container.decode(Int.self, forKey: .minute),
            second: container.decode(Int.self, forKey: .second),
            nanosecond: container.decode(Int.self, forKey: .nanosecond)
        )
    }
}

enum HistoricalTimestampPrecision: String, Codable, Equatable, Sendable {
    case minute
    case second
    case subsecond
}

enum HistoricalTimestampProvenance: String, Codable, Equatable, Sendable {
    case captured
    case userEntered
    case migrationAssumed
}

struct HistoricalTimestamp: Codable, Equatable, Sendable {
    let instant: Date
    let localDate: CivilDateFact
    let localTime: HistoricalLocalTime
    let timeZoneIdentifier: String
    let utcOffsetSeconds: Int
    let precision: HistoricalTimestampPrecision
    let provenance: HistoricalTimestampProvenance

    init(
        validatingInstant instant: Date,
        localDate: CivilDateFact,
        localTime: HistoricalLocalTime,
        timeZoneIdentifier: String,
        utcOffsetSeconds: Int,
        precision: HistoricalTimestampPrecision,
        provenance: HistoricalTimestampProvenance
    ) throws {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw HistoricalTimeError.unknownTimeZone
        }
        guard timeZone.secondsFromGMT(for: instant) == utcOffsetSeconds else {
            throw HistoricalTimeError.offsetDoesNotMatchInstant
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: instant
        )
        guard components.year == localDate.year,
              components.month == localDate.month,
              components.day == localDate.day,
              components.hour == localTime.hour,
              components.minute == localTime.minute,
              components.second == localTime.second else {
            throw HistoricalTimeError.localComponentsDoNotMatchInstant
        }
        if precision == .subsecond,
           components.nanosecond != localTime.nanosecond {
            throw HistoricalTimeError.localComponentsDoNotMatchInstant
        }

        self.instant = instant
        self.localDate = localDate
        self.localTime = localTime
        self.timeZoneIdentifier = timeZoneIdentifier
        self.utcOffsetSeconds = utcOffsetSeconds
        self.precision = precision
        self.provenance = provenance
    }

    private enum CodingKeys: String, CodingKey {
        case instant
        case localDate
        case localTime
        case timeZoneIdentifier
        case utcOffsetSeconds
        case precision
        case provenance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            validatingInstant: container.decode(Date.self, forKey: .instant),
            localDate: container.decode(CivilDateFact.self, forKey: .localDate),
            localTime: container.decode(HistoricalLocalTime.self, forKey: .localTime),
            timeZoneIdentifier: container.decode(String.self, forKey: .timeZoneIdentifier),
            utcOffsetSeconds: container.decode(Int.self, forKey: .utcOffsetSeconds),
            precision: container.decode(HistoricalTimestampPrecision.self, forKey: .precision),
            provenance: container.decode(HistoricalTimestampProvenance.self, forKey: .provenance)
        )
    }

    static func legacyAssumed(
        instant: Date,
        assumedTimeZoneIdentifier: String,
        precision: HistoricalTimestampPrecision = .second
    ) throws -> HistoricalTimestamp {
        guard let timeZone = TimeZone(identifier: assumedTimeZoneIdentifier) else {
            throw HistoricalTimeError.unknownTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: instant
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              let hour = components.hour,
              let minute = components.minute,
              let second = components.second else {
            throw HistoricalTimeError.localComponentsDoNotMatchInstant
        }
        return try HistoricalTimestamp(
            validatingInstant: instant,
            localDate: CivilDateFact(year: year, month: month, day: day),
            localTime: HistoricalLocalTime(
                hour: hour,
                minute: minute,
                second: second,
                nanosecond: components.nanosecond ?? 0
            ),
            timeZoneIdentifier: assumedTimeZoneIdentifier,
            utcOffsetSeconds: timeZone.secondsFromGMT(for: instant),
            precision: precision,
            provenance: .migrationAssumed
        )
    }

    static func captured(
        instant: Date,
        timeZoneIdentifier: String,
        precision: HistoricalTimestampPrecision = .second,
        provenance: HistoricalTimestampProvenance = .captured
    ) throws -> HistoricalTimestamp {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw HistoricalTimeError.unknownTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: instant
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              let hour = components.hour,
              let minute = components.minute,
              let second = components.second else {
            throw HistoricalTimeError.localComponentsDoNotMatchInstant
        }
        return try HistoricalTimestamp(
            validatingInstant: instant,
            localDate: CivilDateFact(year: year, month: month, day: day),
            localTime: HistoricalLocalTime(
                hour: hour,
                minute: minute,
                second: second,
                nanosecond: components.nanosecond ?? 0
            ),
            timeZoneIdentifier: timeZoneIdentifier,
            utcOffsetSeconds: timeZone.secondsFromGMT(for: instant),
            precision: precision,
            provenance: provenance
        )
    }
}
