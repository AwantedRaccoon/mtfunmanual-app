import Foundation

enum HrtJourneyState: String, Codable, Equatable, Sendable {
    case active
    case paused
}

struct HrtPeriodFact: Identifiable, Equatable, Sendable {
    let id: UUID
    let startDate: CivilDateFact
    let endDate: CivilDateFact?
    let note: String

    func contains(_ date: CivilDateFact) -> Bool {
        startDate <= date && (endDate.map { date < $0 } ?? true)
    }
}

struct HrtJourneySummary: Equatable, Sendable {
    let state: HrtJourneyState
    let overallJourneyDay: Int
    let currentPhaseDay: Int?
    let pausedDay: Int?
    let pausedSince: CivilDateFact?
    let periodCount: Int
}

enum HrtJourneyProjectionError: Error, Equatable, Sendable {
    case invalidFacts
    case capacityExceeded
}

enum HrtJourneyProjection {
    static let maximumPeriodCount = 512

    static func validate(
        firstEverStartDate: CivilDateFact,
        periods: [HrtPeriodFact]
    ) throws -> [HrtPeriodFact] {
        guard !periods.isEmpty else {
            throw HrtJourneyProjectionError.invalidFacts
        }
        guard periods.count <= maximumPeriodCount else {
            throw HrtJourneyProjectionError.capacityExceeded
        }
        let sorted = periods.sorted {
            $0.startDate != $1.startDate
                ? $0.startDate < $1.startDate
                : $0.id.uuidString < $1.id.uuidString
        }
        guard sorted.first?.startDate == firstEverStartDate else {
            throw HrtJourneyProjectionError.invalidFacts
        }
        for index in sorted.indices {
            let period = sorted[index]
            guard period.endDate.map({ period.startDate < $0 }) ?? true else {
                throw HrtJourneyProjectionError.invalidFacts
            }
            if index < sorted.index(before: sorted.endIndex) {
                guard let end = period.endDate,
                      end < sorted[sorted.index(after: index)].startDate else {
                    throw HrtJourneyProjectionError.invalidFacts
                }
            } else if period.endDate == nil {
                continue
            }
        }
        guard sorted.dropLast().allSatisfy({ $0.endDate != nil }) else {
            throw HrtJourneyProjectionError.invalidFacts
        }
        return sorted
    }

    static func project(
        firstEverStartDate: CivilDateFact,
        periods: [HrtPeriodFact],
        asOf: CivilDateFact
    ) throws -> HrtJourneySummary {
        let sorted = try validate(
            firstEverStartDate: firstEverStartDate,
            periods: periods
        )
        guard firstEverStartDate <= asOf,
              let overallElapsed = asOf.days(since: firstEverStartDate) else {
            throw HrtJourneyProjectionError.invalidFacts
        }
        if let open = sorted.last, open.endDate == nil {
            guard open.startDate <= asOf,
                  let currentElapsed = asOf.days(since: open.startDate) else {
                throw HrtJourneyProjectionError.invalidFacts
            }
            return HrtJourneySummary(
                state: .active,
                overallJourneyDay: overallElapsed + 1,
                currentPhaseDay: currentElapsed + 1,
                pausedDay: nil,
                pausedSince: nil,
                periodCount: sorted.count
            )
        }
        guard let pausedSince = sorted.last?.endDate,
              pausedSince <= asOf,
              let pausedElapsed = asOf.days(since: pausedSince) else {
            throw HrtJourneyProjectionError.invalidFacts
        }
        return HrtJourneySummary(
            state: .paused,
            overallJourneyDay: overallElapsed + 1,
            currentPhaseDay: nil,
            pausedDay: pausedElapsed + 1,
            pausedSince: pausedSince,
            periodCount: sorted.count
        )
    }
}
