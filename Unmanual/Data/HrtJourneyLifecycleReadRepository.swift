import Foundation
import SwiftData

struct HrtJourneyLifecycleEventSnapshot:
    Identifiable,
    Equatable,
    Sendable
{
    let id: UUID
    let kind: HrtJourneyLifecycleEventKind
    let periodID: UUID?
    let transitionDate: CivilDateFact?
    let note: String
    let timestamp: HistoricalTimestamp
}

struct HrtJourneySnapshot: Equatable, Sendable {
    let firstEverStartDate: CivilDateFact
    let periods: [HrtPeriodFact]
    let summary: HrtJourneySummary
    let latestEventID: UUID
    let events: [HrtJourneyLifecycleEventSnapshot]
}

extension AppReadActor {
    func hrtJourneySnapshot(
        asOf: CivilDateFact
    ) throws -> HrtJourneySnapshot? {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "-unmanual-hrt-read-error"
        ) {
            throw AppDataFailure.corruptionSuspected
        }
#endif
        try HrtJourneyLifecycleValidator.validate(
            in: modelContext,
            failure: .corruptionSuspected
        )
        var profileDescriptor =
            FetchDescriptor<HrtJourneyProfileRecord>()
        profileDescriptor.fetchLimit = 2
        let profiles = try modelContext.fetch(profileDescriptor)
        guard profiles.count <= 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        guard let profile = profiles.first else { return nil }
        guard let firstEverStartDate = profile.firstEverStartDate else {
            throw AppDataFailure.corruptionSuspected
        }

        var periodDescriptor = FetchDescriptor<HrtPeriodRecord>(
            sortBy: [
                SortDescriptor(\.startYear),
                SortDescriptor(\.startMonth),
                SortDescriptor(\.startDay),
                SortDescriptor(\.id)
            ]
        )
        periodDescriptor.fetchLimit =
            HrtJourneyProjection.maximumPeriodCount + 1
        let records = try modelContext.fetch(periodDescriptor)
        guard records.count <= HrtJourneyProjection.maximumPeriodCount
        else {
            throw AppDataFailure.corruptionSuspected
        }
        let periods = try records.map { record -> HrtPeriodFact in
            guard let startDate = record.startDate,
                  (record.endYear == nil
                      && record.endMonth == nil
                      && record.endDay == nil)
                    || record.endDate != nil else {
                throw AppDataFailure.corruptionSuspected
            }
            return HrtPeriodFact(
                id: record.id,
                startDate: startDate,
                endDate: record.endDate,
                note: record.note
            )
        }
        let sortedPeriods: [HrtPeriodFact]
        let summary: HrtJourneySummary
        do {
            sortedPeriods = try HrtJourneyProjection.validate(
                firstEverStartDate: firstEverStartDate,
                periods: periods
            )
            summary = try HrtJourneyProjection.project(
                firstEverStartDate: firstEverStartDate,
                periods: sortedPeriods,
                asOf: asOf
            )
        } catch {
            throw AppDataFailure.corruptionSuspected
        }

        var eventDescriptor =
            FetchDescriptor<HrtJourneyLifecycleEventRecord>()
        eventDescriptor.fetchLimit =
            HrtJourneyLifecycleValidator.maximumEventCount + 1
        let eventRecords = try modelContext.fetch(eventDescriptor)
        guard eventRecords.count
            <= HrtJourneyLifecycleValidator.maximumEventCount else {
            throw AppDataFailure.corruptionSuspected
        }
        let byID = try AppDataIndex.checkedUniqueMap(
            eventRecords,
            keyedBy: \.id,
            failure: .corruptionSuspected
        )
        let predecessorIDs =
            Set(eventRecords.compactMap(\.previousEventID))
        guard let leaf = eventRecords.first(where: {
            !predecessorIDs.contains($0.id)
        }) else {
            throw AppDataFailure.corruptionSuspected
        }
        var reverseChain: [HrtJourneyLifecycleEventRecord] = []
        var cursor: HrtJourneyLifecycleEventRecord? = leaf
        var visited = Set<UUID>()
        while let event = cursor {
            guard visited.insert(event.id).inserted else {
                throw AppDataFailure.corruptionSuspected
            }
            reverseChain.append(event)
            cursor = try event.previousEventID.map {
                guard let predecessor = byID[$0] else {
                    throw AppDataFailure.corruptionSuspected
                }
                return predecessor
            }
        }
        guard reverseChain.count == eventRecords.count else {
            throw AppDataFailure.corruptionSuspected
        }
        let events = try reverseChain.reversed().map {
            record -> HrtJourneyLifecycleEventSnapshot in
            guard let kind = record.kind,
                  let timestamp = record.historicalTimestamp else {
                throw AppDataFailure.corruptionSuspected
            }
            return HrtJourneyLifecycleEventSnapshot(
                id: record.id,
                kind: kind,
                periodID: record.periodID,
                transitionDate: record.transitionDate,
                note: record.noteSnapshot,
                timestamp: timestamp
            )
        }
        return HrtJourneySnapshot(
            firstEverStartDate: firstEverStartDate,
            periods: sortedPeriods,
            summary: summary,
            latestEventID: leaf.id,
            events: events
        )
    }
}
