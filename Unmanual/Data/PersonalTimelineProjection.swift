import Foundation
import SwiftData

enum PersonalTimelineItemKind: String, Codable, Equatable, Sendable {
    case labSample
    case statusObservation
    case journeyEntry
    case administration
    case countdown
    case regimenVersion
    case hrtJourney

    var rank: Int {
        switch self {
        case .labSample: 0
        case .statusObservation: 1
        case .administration: 2
        case .countdown: 3
        case .journeyEntry: 4
        case .regimenVersion: 5
        case .hrtJourney: 6
        }
    }
}

struct PersonalTimelineItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: PersonalTimelineItemKind
    let title: String
    let detail: String
    let timestamp: HistoricalTimestamp?
    let dateOnly: CivilDateFact?
    let localDate: CivilDateFact
    let regimenVersionID: UUID?

    init(
        id: UUID,
        kind: PersonalTimelineItemKind,
        title: String,
        detail: String,
        timestamp: HistoricalTimestamp?,
        dateOnly: CivilDateFact?,
        localDate: CivilDateFact,
        regimenVersionID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.timestamp = timestamp
        self.dateOnly = dateOnly
        self.localDate = localDate
        self.regimenVersionID = regimenVersionID
    }

    var rowIdentity: String {
        "\(kind.rawValue):\(id.uuidString.lowercased())"
    }
}

struct PersonalTimelineCursor: Equatable, Sendable {
    fileprivate let sortDomainRank: Int
    fileprivate let localDate: CivilDateFact
    fileprivate let instantMicroseconds: Int64?
    fileprivate let kindRank: Int
    fileprivate let id: UUID
}

struct PersonalTimelinePage: Equatable, Sendable {
    let items: [PersonalTimelineItem]
    let nextCursor: PersonalTimelineCursor?
    let gentleModeEnabled: Bool
}

extension AppReadActor {
    func latestLabTimelineItem(
        gentleModeEnabled frozenGentleModeEnabled: Bool? = nil
    ) throws -> PersonalTimelineItem? {
        let gentleModeEnabled = try frozenGentleModeEnabled
            ?? gentleModeSnapshot().isEnabled
        let surfaceCopy = LabSurfaceDisplayPolicy.copy(
            gentleModeEnabled: gentleModeEnabled
        )
        if hasParentRecordLifecycleProjection {
            try ParentRecordLifecycleValidator.validate(
                in: modelContext,
                failure: .corruptionSuspected
            )
            let labType = ParentRecordType.labSample.rawValue
            let active = ParentRecordLifecycle.active.rawValue
            var descriptor =
                FetchDescriptor<ParentRecordLifecycleHeadRecord>(
                    predicate: #Predicate {
                        $0.parentTypeRawValue == labType
                            && $0.lifecycleRawValue == active
                    },
                    sortBy: [
                        SortDescriptor(
                            \.effectiveInstant,
                            order: .reverse
                        ),
                        SortDescriptor(\.parentID)
                    ]
                )
            descriptor.fetchLimit = 1
            guard let head = try modelContext.fetch(descriptor).first else {
                return nil
            }
            guard let sample =
                    try parentRecordLabSampleUnchecked(
                        id: head.parentID
                    ),
                  sample.timestamp == head.effectiveTimestamp else {
                throw AppDataFailure.corruptionSuspected
            }
            return PersonalTimelineItem(
                id: sample.id,
                kind: .labSample,
                title: surfaceCopy.timelineRecordTitle,
                detail: sample.results.isEmpty
                    ? "仅附件"
                    : "\(sample.results.count) 个结果",
                timestamp: sample.timestamp,
                dateOnly: nil,
                localDate: sample.timestamp.localDate
            )
        }
        let sourceType = "LabSampleRecord"
        var timeDescriptor = FetchDescriptor<HistoricalTimeRecord>(
            predicate: #Predicate { $0.sourceRecordType == sourceType },
            sortBy: [
                SortDescriptor(\.instant, order: .reverse),
                SortDescriptor(\.sourceRecordID)
            ]
        )
        timeDescriptor.fetchLimit = 1
        guard let time = try modelContext.fetch(timeDescriptor).first,
              let timestamp = time.historicalTimestamp else {
            return nil
        }
        let sampleID = time.sourceRecordID
        var sampleDescriptor = FetchDescriptor<LabSampleRecord>(
            predicate: #Predicate { $0.id == sampleID }
        )
        sampleDescriptor.fetchLimit = 1
        guard try modelContext.fetch(sampleDescriptor).count == 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        let resultCount = try modelContext.fetchCount(
            FetchDescriptor<LabResultRecord>(
                predicate: #Predicate { $0.sampleID == sampleID }
            )
        )
        return PersonalTimelineItem(
            id: sampleID,
            kind: .labSample,
            title: surfaceCopy.timelineRecordTitle,
            detail: resultCount == 0 ? "仅附件" : "\(resultCount) 个结果",
            timestamp: timestamp,
            dateOnly: nil,
            localDate: timestamp.localDate
        )
    }

    func personalTimelinePage(
        after cursor: PersonalTimelineCursor? = nil,
        limit: Int = 50
    ) throws -> PersonalTimelinePage {
        guard (1...100).contains(limit) else {
            throw AppDataFailure.corruptionSuspected
        }
        let gentleModeEnabled = try gentleModeSnapshot().isEnabled
        let labSurfaceCopy = LabSurfaceDisplayPolicy.copy(
            gentleModeEnabled: gentleModeEnabled
        )
        let sourceTypes = hasParentRecordLifecycleProjection
            ? ["JourneyEntry"]
            : [
                "LabSampleRecord",
                "StatusObservationRecord",
                "JourneyEntry"
            ]
        var times = try sourceTypes.flatMap {
            try timedCandidates(
                sourceType: $0,
                after: cursor,
                pageLimit: limit
            )
        }
        times += try administrationTimedCandidates(
            after: cursor,
            pageLimit: limit
        )
        if let cursorMicroseconds = cursor?.instantMicroseconds {
            let cursorTieCount = try times.reduce(into: 0) { count, time in
                if try RecordDigestV1.timestampMicroseconds(time.instant)
                    == cursorMicroseconds {
                    count += 1
                }
            }
            guard cursorTieCount
                    <= PersonalTimelineCapacity.maximumSameInstantCursorTieCount
            else {
                throw AppDataFailure.corruptionSuspected
            }
        }
        let timeByKey = try AppDataIndex.checkedUniqueMap(
            times,
            keyedBy: \.recordKey,
            failure: .corruptionSuspected
        )
        var items: [PersonalTimelineItem] = []

        let sampleIDs = times
            .filter { $0.sourceRecordType == "LabSampleRecord" }
            .map(\.sourceRecordID)
        var sampleDescriptor = FetchDescriptor<LabSampleRecord>(
            predicate: #Predicate { sampleIDs.contains($0.id) }
        )
        sampleDescriptor.fetchLimit = sampleIDs.count + 1
        let samples = try modelContext.fetch(sampleDescriptor)
        guard samples.count == sampleIDs.count else {
            throw AppDataFailure.corruptionSuspected
        }
        var resultDescriptor = FetchDescriptor<LabResultRecord>(
            predicate: #Predicate { sampleIDs.contains($0.sampleID) }
        )
        let (maximumResultCount, resultCapacityOverflow) =
            sampleIDs.count.multipliedReportingOverflow(
                by: PersonalTimelineCapacity.maximumLabResultsPerSample
            )
        let (resultFetchLimit, resultLimitOverflow) =
            maximumResultCount.addingReportingOverflow(1)
        guard !resultCapacityOverflow, !resultLimitOverflow else {
            throw AppDataFailure.corruptionSuspected
        }
        resultDescriptor.fetchLimit = resultFetchLimit
        let results = try modelContext.fetch(resultDescriptor)
        guard results.count <= maximumResultCount else {
            throw AppDataFailure.corruptionSuspected
        }
        let resultCountBySample = Dictionary(grouping: results, by: \.sampleID)
            .mapValues(\.count)
        guard resultCountBySample.values.allSatisfy({
            $0 <= PersonalTimelineCapacity.maximumLabResultsPerSample
        }) else {
            throw AppDataFailure.corruptionSuspected
        }
        for sample in samples {
            let timestamp = try requiredTimestamp(
                sourceType: "LabSampleRecord",
                sourceID: sample.id,
                timeByKey: timeByKey
            )
            let count = resultCountBySample[sample.id, default: 0]
            items.append(
                PersonalTimelineItem(
                    id: sample.id,
                    kind: .labSample,
                    title: labSurfaceCopy.timelineRecordTitle,
                    detail: count == 0 ? "仅附件" : "\(count) 个结果",
                    timestamp: timestamp,
                    dateOnly: nil,
                    localDate: timestamp.localDate
                )
            )
        }

        let observationIDs = times
            .filter { $0.sourceRecordType == "StatusObservationRecord" }
            .map(\.sourceRecordID)
        var observationDescriptor = FetchDescriptor<StatusObservationRecord>(
            predicate: #Predicate { observationIDs.contains($0.id) }
        )
        observationDescriptor.fetchLimit = observationIDs.count + 1
        let observations = try modelContext.fetch(observationDescriptor)
        guard observations.count == observationIDs.count else {
            throw AppDataFailure.corruptionSuspected
        }
        for observation in observations {
            let timestamp = try requiredTimestamp(
                sourceType: "StatusObservationRecord",
                sourceID: observation.id,
                timeByKey: timeByKey
            )
            guard (1...4).contains(observation.ordinalLevel) else {
                throw AppDataFailure.corruptionSuspected
            }
            items.append(
                PersonalTimelineItem(
                    id: observation.id,
                    kind: .statusObservation,
                    title: observation.metricNameSnapshot,
                    detail: "第 \(observation.ordinalLevel) 级，共 4 级",
                    timestamp: timestamp,
                    dateOnly: nil,
                    localDate: timestamp.localDate
                )
            )
        }

        let journeyIDs = times
            .filter { $0.sourceRecordType == "JourneyEntry" }
            .map(\.sourceRecordID)
        var journeyDescriptor = FetchDescriptor<JourneyEntry>(
            predicate: #Predicate { journeyIDs.contains($0.id) }
        )
        journeyDescriptor.fetchLimit = journeyIDs.count + 1
        let journeyEntries = try modelContext.fetch(journeyDescriptor)
        guard journeyEntries.count == journeyIDs.count else {
            throw AppDataFailure.corruptionSuspected
        }
        for entry in journeyEntries {
            let timestamp = try requiredTimestamp(
                sourceType: "JourneyEntry",
                sourceID: entry.id,
                timeByKey: timeByKey
            )
            items.append(
                PersonalTimelineItem(
                    id: entry.id,
                    kind: .journeyEntry,
                    title: entry.kind == .feeling ? "感受记录" : "片段记录",
                    detail: entry.text,
                    timestamp: timestamp,
                    dateOnly: nil,
                    localDate: timestamp.localDate
                )
            )
        }

        let eventIDs = times
            .filter { $0.sourceRecordType == "AdministrationEventRecord" }
            .map(\.sourceRecordID)
        var eventDescriptor = FetchDescriptor<AdministrationEventRecord>(
            predicate: #Predicate { eventIDs.contains($0.id) }
        )
        eventDescriptor.fetchLimit = eventIDs.count + 1
        let events = try modelContext.fetch(eventDescriptor)
        guard events.count == eventIDs.count else {
            throw AppDataFailure.corruptionSuspected
        }
        let itemIDs = Array(Set(events.map(\.regimenItemID)))
        var itemDescriptor = FetchDescriptor<RegimenItemRecord>(
            predicate: #Predicate { itemIDs.contains($0.id) }
        )
        itemDescriptor.fetchLimit = itemIDs.count + 1
        let regimenItems = try modelContext.fetch(itemDescriptor)
        guard regimenItems.count == itemIDs.count else {
            throw AppDataFailure.corruptionSuspected
        }
        let itemNameByID = Dictionary(
            uniqueKeysWithValues: regimenItems.map { ($0.id, $0.displayName) }
        )
        for event in events {
            guard let status = event.status else {
                throw AppDataFailure.corruptionSuspected
            }
            let timestamp = try requiredTimestamp(
                sourceType: "AdministrationEventRecord",
                sourceID: event.id,
                timeByKey: timeByKey
            )
            items.append(
                PersonalTimelineItem(
                    id: event.id,
                    kind: .administration,
                    title: itemNameByID[event.regimenItemID] ?? "执行记录",
                    detail: administrationLabel(status),
                    timestamp: timestamp,
                    dateOnly: nil,
                    localDate: timestamp.localDate,
                    regimenVersionID:
                        event.regimenVersionID
                )
            )
        }

        if hasParentRecordLifecycleProjection {
            items += try parentRecordTimelineItems(
                after: cursor,
                pageLimit: limit,
                gentleModeEnabled: gentleModeEnabled
            )
        }

        items += try countdownTerminalTimelineItems(
            after: cursor,
            pageLimit: limit
        )
        items += try hrtJourneyTimelineItems(
            after: cursor,
            pageLimit: limit
        )

        let versions = try regimenDateCandidates(after: cursor, pageLimit: limit)
        for version in versions
        where version.editState == .sealed
            && !version.isArchived
            && !version.requiresMigrationReview {
            guard let start = version.effectiveStartDate else {
                throw AppDataFailure.corruptionSuspected
            }
            items.append(
                PersonalTimelineItem(
                    id: version.id,
                    kind: .regimenVersion,
                    title: version.title,
                    detail: "方案从这一天起生效",
                    timestamp: nil,
                    dateOnly: start,
                    localDate: start
                )
            )
        }

        if let cursorMicroseconds = cursor?.instantMicroseconds {
            var cursorTieCount = 0
            for item in items {
                if let timestamp = item.timestamp,
                   try RecordDigestV1.timestampMicroseconds(
                       timestamp.instant
                   ) == cursorMicroseconds {
                    cursorTieCount += 1
                }
            }
            guard cursorTieCount
                    <= PersonalTimelineCapacity.maximumSameInstantCursorTieCount
            else {
                throw AppDataFailure.corruptionSuspected
            }
        }

        items.sort(by: Self.isEarlierInTimeline)
        if let cursor {
            items = items.filter { Self.isAfterCursor($0, cursor: cursor) }
        }
        let pageItems = Array(items.prefix(limit))
        let nextCursor = items.count > pageItems.count
            ? pageItems.last.map(Self.cursor)
            : nil
        return PersonalTimelinePage(
            items: pageItems,
            nextCursor: nextCursor,
            gentleModeEnabled: gentleModeEnabled
        )
    }

    private var hasParentRecordLifecycleProjection: Bool {
        modelContext.container.schema.entities.contains {
            $0.name == "ParentRecordLifecycleHeadRecord"
        }
    }

    private func parentRecordTimelineItems(
        after cursor: PersonalTimelineCursor?,
        pageLimit: Int,
        gentleModeEnabled: Bool
    ) throws -> [PersonalTimelineItem] {
        guard cursor?.sortDomainRank != 1 else { return [] }
        if cursor != nil, cursor?.instantMicroseconds == nil {
            throw AppDataFailure.corruptionSuspected
        }
        try ParentRecordLifecycleValidator.validate(
            in: modelContext,
            failure: .corruptionSuspected
        )
        let active = ParentRecordLifecycle.active.rawValue
        let tieCount: Int
        var descriptor:
            FetchDescriptor<ParentRecordLifecycleHeadRecord>
        if let microseconds = cursor?.instantMicroseconds {
            let cutoff = Date(
                timeIntervalSince1970:
                    Double(microseconds) / 1_000_000
            )
            tieCount = try modelContext.fetchCount(
                FetchDescriptor<ParentRecordLifecycleHeadRecord>(
                    predicate: #Predicate {
                        $0.lifecycleRawValue == active
                            && $0.effectiveInstant == cutoff
                    }
                )
            )
            descriptor =
                FetchDescriptor<ParentRecordLifecycleHeadRecord>(
                    predicate: #Predicate {
                        $0.lifecycleRawValue == active
                            && $0.effectiveInstant <= cutoff
                    },
                    sortBy: [
                        SortDescriptor(
                            \.effectiveInstant,
                            order: .reverse
                        ),
                        SortDescriptor(\.parentTypeRawValue),
                        SortDescriptor(\.parentID)
                    ]
                )
        } else {
            tieCount = 0
            descriptor =
                FetchDescriptor<ParentRecordLifecycleHeadRecord>(
                    predicate: #Predicate {
                        $0.lifecycleRawValue == active
                    },
                    sortBy: [
                        SortDescriptor(
                            \.effectiveInstant,
                            order: .reverse
                        ),
                        SortDescriptor(\.parentTypeRawValue),
                        SortDescriptor(\.parentID)
                    ]
                )
        }
        guard tieCount
                <= PersonalTimelineCapacity
                    .maximumSameInstantCursorTieCount else {
            throw AppDataFailure.corruptionSuspected
        }
        let (limitWithTies, firstOverflow) =
            pageLimit.addingReportingOverflow(tieCount)
        let (fetchLimit, secondOverflow) =
            limitWithTies.addingReportingOverflow(1)
        guard !firstOverflow, !secondOverflow else {
            throw AppDataFailure.corruptionSuspected
        }
        descriptor.fetchLimit = fetchLimit
        return try modelContext.fetch(descriptor).map { head in
            guard let type = head.parentType,
                  let timestamp = head.effectiveTimestamp else {
                throw AppDataFailure.corruptionSuspected
            }
            switch type {
            case .labSample:
                guard let sample =
                        try parentRecordLabSampleUnchecked(
                            id: head.parentID
                        ),
                      sample.timestamp == timestamp else {
                    throw AppDataFailure.corruptionSuspected
                }
                return PersonalTimelineItem(
                    id: sample.id,
                    kind: .labSample,
                    title: LabSurfaceDisplayPolicy.copy(
                        gentleModeEnabled: gentleModeEnabled
                    ).timelineRecordTitle,
                    detail: sample.results.isEmpty
                        ? "仅附件"
                        : "\(sample.results.count) 个结果",
                    timestamp: timestamp,
                    dateOnly: nil,
                    localDate: timestamp.localDate
                )
            case .statusObservation:
                guard let observation =
                        try parentRecordStatusObservationUnchecked(
                            id: head.parentID
                        ),
                observation.timestamp == timestamp,
                (1...4).contains(observation.ordinalLevel) else {
                    throw AppDataFailure.corruptionSuspected
                }
                return PersonalTimelineItem(
                    id: observation.id,
                    kind: .statusObservation,
                    title: observation.metricNameSnapshot,
                    detail:
                        "第 \(observation.ordinalLevel) 级，共 4 级",
                    timestamp: timestamp,
                    dateOnly: nil,
                    localDate: timestamp.localDate
                )
            }
        }
    }

    private func countdownTerminalTimelineItems(
        after cursor: PersonalTimelineCursor?,
        pageLimit: Int
    ) throws -> [PersonalTimelineItem] {
        guard cursor?.sortDomainRank != 1 else { return [] }
        let completed = CountdownLifecycle.completed.rawValue
        let archived = CountdownLifecycle.archived.rawValue
        let cursorTieCount: Int
        var stateDescriptor: FetchDescriptor<CountdownStateRecord>
        if let cursorMicroseconds = cursor?.instantMicroseconds {
            let cutoff = Date(
                timeIntervalSince1970:
                    Double(cursorMicroseconds) / 1_000_000
            )
            cursorTieCount = try modelContext.fetchCount(
                FetchDescriptor<CountdownStateRecord>(
                    predicate: #Predicate {
                        (
                            $0.lifecycleRawValue == completed
                                || $0.lifecycleRawValue == archived
                        )
                            && !$0.requiresReview
                            && $0.archivedAt == cutoff
                    }
                )
            )
            stateDescriptor = FetchDescriptor<CountdownStateRecord>(
                predicate: #Predicate {
                    (
                        $0.lifecycleRawValue == completed
                            || $0.lifecycleRawValue == archived
                        )
                        && !$0.requiresReview
                        && $0.archivedAt != nil
                        && ($0.archivedAt ?? cutoff) <= cutoff
                },
                sortBy: [
                    SortDescriptor(\.archivedAt, order: .reverse),
                    SortDescriptor(\.id)
                ]
            )
        } else {
            cursorTieCount = 0
            stateDescriptor = FetchDescriptor<CountdownStateRecord>(
                predicate: #Predicate {
                    (
                        $0.lifecycleRawValue == completed
                            || $0.lifecycleRawValue == archived
                    )
                        && !$0.requiresReview
                },
                sortBy: [
                    SortDescriptor(\.archivedAt, order: .reverse),
                    SortDescriptor(\.id)
                ]
            )
        }
        guard cursorTieCount
                <= PersonalTimelineCapacity.maximumSameInstantCursorTieCount
        else {
            throw AppDataFailure.corruptionSuspected
        }
        let (limitWithTies, firstOverflow) =
            pageLimit.addingReportingOverflow(cursorTieCount)
        let (fetchLimit, secondOverflow) =
            limitWithTies.addingReportingOverflow(1)
        guard !firstOverflow, !secondOverflow else {
            throw AppDataFailure.corruptionSuspected
        }
        stateDescriptor.fetchLimit = fetchLimit
        let states = try modelContext.fetch(stateDescriptor)
        guard states.allSatisfy({
            !$0.title.isEmpty && $0.targetDate != nil
        }) else {
            throw AppDataFailure.corruptionSuspected
        }
        guard !states.isEmpty else { return [] }

        let eventIDs = states.map(\.latestEventID)
        var eventDescriptor = FetchDescriptor<CountdownLifecycleEventRecord>(
            predicate: #Predicate { eventIDs.contains($0.id) }
        )
        eventDescriptor.fetchLimit = eventIDs.count + 1
        let events = try modelContext.fetch(eventDescriptor)
        guard events.count == eventIDs.count else {
            throw AppDataFailure.corruptionSuspected
        }
        let eventByID = try AppDataIndex.checkedUniqueMap(
            events,
            keyedBy: \.id,
            failure: .corruptionSuspected
        )
        let reviewPredecessorIDs = events.compactMap { event -> UUID? in
            event.kind == .reviewResolved ? event.previousEventID : nil
        }
        var predecessorByID: [UUID: CountdownLifecycleEventRecord] = [:]
        if !reviewPredecessorIDs.isEmpty {
            var predecessorDescriptor =
                FetchDescriptor<CountdownLifecycleEventRecord>(
                    predicate: #Predicate {
                        reviewPredecessorIDs.contains($0.id)
                    }
                )
            predecessorDescriptor.fetchLimit =
                reviewPredecessorIDs.count + 1
            let predecessors = try modelContext.fetch(
                predecessorDescriptor
            )
            guard predecessors.count == reviewPredecessorIDs.count else {
                throw AppDataFailure.corruptionSuspected
            }
            predecessorByID = try AppDataIndex.checkedUniqueMap(
                predecessors,
                keyedBy: \.id,
                failure: .corruptionSuspected
            )
        }

        var preferenceDescriptor = FetchDescriptor<UserPreferencesRecord>()
        preferenceDescriptor.fetchLimit = 2
        let preferences = try modelContext.fetch(preferenceDescriptor)
        guard preferences.count == 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        let gentleModeEnabled = preferences[0].gentleModeEnabled

        return try states.map { state in
            guard let lifecycle = state.lifecycle,
                  let latestEvent = eventByID[state.latestEventID],
                  latestEvent.countdownID == state.id,
                  let latestEventKind = latestEvent.kind else {
                throw AppDataFailure.corruptionSuspected
            }
            let event: CountdownLifecycleEventRecord
            if latestEventKind == .reviewResolved {
                guard lifecycle == .archived,
                      let previousID = latestEvent.previousEventID,
                      let previous = predecessorByID[previousID],
                      previous.countdownID == state.id else {
                    throw AppDataFailure.corruptionSuspected
                }
                event = previous
            } else {
                event = latestEvent
            }
            guard let eventKind = event.kind,
                  (
                      lifecycle == .completed && eventKind == .completed
                  ) || (
                      lifecycle == .archived
                          && (
                              eventKind == .archived
                                  || eventKind == .migratedSnapshot
                          )
                  ),
                  let timestamp = event.historicalTimestamp else {
                throw AppDataFailure.corruptionSuspected
            }
            let displayTitle: String
            if gentleModeEnabled {
                displayTitle = state.gentleTitle?.isEmpty == false
                    ? state.gentleTitle!
                    : "私人日期"
            } else {
                displayTitle = state.title
            }
            return PersonalTimelineItem(
                id: state.id,
                kind: .countdown,
                title: displayTitle,
                detail: lifecycle == .completed
                    ? "已经完成，已收进旅程"
                    : "未完成，已收进旅程",
                timestamp: timestamp,
                dateOnly: nil,
                localDate: timestamp.localDate
            )
        }
    }

    private func hrtJourneyTimelineItems(
        after cursor: PersonalTimelineCursor?,
        pageLimit: Int
    ) throws -> [PersonalTimelineItem] {
        guard modelContext.container.schema.entities.contains(where: {
            $0.name == "HrtJourneyLifecycleEventRecord"
        }) else {
            return []
        }
        guard cursor?.sortDomainRank != 1 else { return [] }
        try HrtJourneyLifecycleValidator.validate(
            in: modelContext,
            failure: .corruptionSuspected
        )

        let migratedSnapshot =
            HrtJourneyLifecycleEventKind.migratedSnapshot.rawValue
        let cursorTieCount: Int
        var descriptor: FetchDescriptor<HrtJourneyLifecycleEventRecord>
        if let cursorMicroseconds = cursor?.instantMicroseconds {
            let cutoff = Date(
                timeIntervalSince1970:
                    Double(cursorMicroseconds) / 1_000_000
            )
            cursorTieCount = try modelContext.fetchCount(
                FetchDescriptor<HrtJourneyLifecycleEventRecord>(
                    predicate: #Predicate {
                        $0.kindRawValue != migratedSnapshot
                            && $0.occurredAt == cutoff
                    }
                )
            )
            descriptor = FetchDescriptor<HrtJourneyLifecycleEventRecord>(
                predicate: #Predicate {
                    $0.kindRawValue != migratedSnapshot
                        && $0.occurredAt <= cutoff
                },
                sortBy: [
                    SortDescriptor(\.occurredAt, order: .reverse),
                    SortDescriptor(\.id)
                ]
            )
        } else {
            cursorTieCount = 0
            descriptor = FetchDescriptor<HrtJourneyLifecycleEventRecord>(
                predicate: #Predicate {
                    $0.kindRawValue != migratedSnapshot
                },
                sortBy: [
                    SortDescriptor(\.occurredAt, order: .reverse),
                    SortDescriptor(\.id)
                ]
            )
        }
        guard cursorTieCount
                <= PersonalTimelineCapacity.maximumSameInstantCursorTieCount
        else {
            throw AppDataFailure.corruptionSuspected
        }
        let (limitWithTies, firstOverflow) =
            pageLimit.addingReportingOverflow(cursorTieCount)
        let (fetchLimit, secondOverflow) =
            limitWithTies.addingReportingOverflow(1)
        guard !firstOverflow, !secondOverflow else {
            throw AppDataFailure.corruptionSuspected
        }
        descriptor.fetchLimit = fetchLimit
        let records = try modelContext.fetch(descriptor)

        var preferenceDescriptor = FetchDescriptor<UserPreferencesRecord>()
        preferenceDescriptor.fetchLimit = 2
        let preferences = try modelContext.fetch(preferenceDescriptor)
        guard preferences.count == 1 else {
            throw AppDataFailure.corruptionSuspected
        }
        let gentleModeEnabled = preferences[0].gentleModeEnabled

        return try records.map { event in
            guard let kind = event.kind,
                  kind != .migratedSnapshot,
                  let transitionDate = event.transitionDate,
                  let timestamp = event.historicalTimestamp else {
                throw AppDataFailure.corruptionSuspected
            }
            return PersonalTimelineItem(
                id: event.id,
                kind: .hrtJourney,
                title: hrtJourneyTitle(
                    kind: kind,
                    gentleModeEnabled: gentleModeEnabled
                ),
                detail: hrtJourneyDetail(
                    kind: kind,
                    transitionDate: transitionDate,
                    gentleModeEnabled: gentleModeEnabled
                ),
                timestamp: timestamp,
                dateOnly: nil,
                localDate: timestamp.localDate
            )
        }
    }

    private func hrtJourneyTitle(
        kind: HrtJourneyLifecycleEventKind,
        gentleModeEnabled: Bool
    ) -> String {
        if gentleModeEnabled {
            switch kind {
            case .started: "时间坐标已开始"
            case .firstStartCorrected: "时间坐标起点已修正"
            case .paused: "时间坐标已暂停"
            case .resumed: "时间坐标已恢复"
            case .migratedSnapshot: "时间坐标"
            }
        } else {
            switch kind {
            case .started: "HRT 历程已开始"
            case .firstStartCorrected: "HRT 历程起点已修正"
            case .paused: "HRT 历程已暂停"
            case .resumed: "HRT 历程已恢复"
            case .migratedSnapshot: "HRT 历程"
            }
        }
    }

    private func hrtJourneyDetail(
        kind: HrtJourneyLifecycleEventKind,
        transitionDate: CivilDateFact,
        gentleModeEnabled: Bool
    ) -> String {
        let date = String(
            format: "%04d.%02d.%02d",
            transitionDate.year,
            transitionDate.month,
            transitionDate.day
        )
        let boundary = gentleModeEnabled
            ? "其他计划没有改变"
            : "方案、执行和提醒未改变"
        switch kind {
        case .started:
            return "开始日：\(date)；\(boundary)"
        case .firstStartCorrected:
            return "起点修正为 \(date)；\(boundary)"
        case .paused:
            return "暂停从 \(date) 开始；\(boundary)"
        case .resumed:
            return "恢复日：\(date)；\(boundary)"
        case .migratedSnapshot:
            return boundary
        }
    }

    private func timedCandidates(
        sourceType: String,
        after cursor: PersonalTimelineCursor?,
        pageLimit: Int
    ) throws -> [HistoricalTimeRecord] {
        if cursor?.sortDomainRank == 1 { return [] }
        let fetchLimit: Int
        var descriptor: FetchDescriptor<HistoricalTimeRecord>
        if let microseconds = cursor?.instantMicroseconds {
            let cutoff = Date(
                timeIntervalSince1970: Double(microseconds) / 1_000_000
            )
            let tieCount = try modelContext.fetchCount(
                FetchDescriptor<HistoricalTimeRecord>(
                    predicate: #Predicate {
                        $0.sourceRecordType == sourceType
                            && $0.instant == cutoff
                    }
                )
            )
            guard tieCount
                    <= PersonalTimelineCapacity.maximumSameInstantCursorTieCount
            else {
                throw AppDataFailure.corruptionSuspected
            }
            let (limitWithTies, firstOverflow) =
                pageLimit.addingReportingOverflow(tieCount)
            let (boundedLimit, secondOverflow) =
                limitWithTies.addingReportingOverflow(1)
            guard !firstOverflow, !secondOverflow else {
                throw AppDataFailure.corruptionSuspected
            }
            descriptor = FetchDescriptor<HistoricalTimeRecord>(
                predicate: #Predicate {
                    $0.sourceRecordType == sourceType && $0.instant <= cutoff
                },
                sortBy: [
                    SortDescriptor(\.instant, order: .reverse),
                    SortDescriptor(\.sourceRecordID)
                ]
            )
            fetchLimit = boundedLimit
        } else {
            descriptor = FetchDescriptor<HistoricalTimeRecord>(
                predicate: #Predicate { $0.sourceRecordType == sourceType },
                sortBy: [
                    SortDescriptor(\.instant, order: .reverse),
                    SortDescriptor(\.sourceRecordID)
                ]
            )
            fetchLimit = pageLimit + 1
        }
        descriptor.fetchLimit = fetchLimit
        return try modelContext.fetch(descriptor)
    }

    private func administrationTimedCandidates(
        after cursor: PersonalTimelineCursor?,
        pageLimit: Int
    ) throws -> [HistoricalTimeRecord] {
        guard cursor?.sortDomainRank != 1 else { return [] }
        if cursor != nil, cursor?.instantMicroseconds == nil {
            throw AppDataFailure.corruptionSuspected
        }

        let sourceType = "AdministrationEventRecord"
        let resolutionLimit =
            PersonalTimelineCapacity.maximumAdministrationRecordsPerPageResolution
        let chunkSize = PersonalTimelineCapacity.administrationScanChunkSize
        if let microseconds = cursor?.instantMicroseconds {
            let cutoff = Date(
                timeIntervalSince1970: Double(microseconds) / 1_000_000
            )
            let tieCount = try modelContext.fetchCount(
                FetchDescriptor<HistoricalTimeRecord>(
                    predicate: #Predicate {
                        $0.sourceRecordType == sourceType
                            && $0.instant == cutoff
                    }
                )
            )
            guard tieCount
                    <= PersonalTimelineCapacity.maximumSameInstantCursorTieCount
            else {
                throw AppDataFailure.corruptionSuspected
            }
        }
        var fetchOffset = 0
        var databaseRowsRead = 0
        var rawTimeByEventID: [UUID: HistoricalTimeRecord] = [:]
        var eventByID: [UUID: AdministrationEventRecord] = [:]
        var chainsByOccurrence: [String: [AdministrationEventRecord]] = [:]

        while databaseRowsRead < resolutionLimit {
            let remaining = resolutionLimit - databaseRowsRead
            guard remaining >= 2 else {
                throw AppDataFailure.corruptionSuspected
            }
            let batchLimit = min(chunkSize, remaining - 1)
            var descriptor: FetchDescriptor<HistoricalTimeRecord>
            if let microseconds = cursor?.instantMicroseconds {
                let cutoff = Date(
                    timeIntervalSince1970: Double(microseconds) / 1_000_000
                )
                descriptor = FetchDescriptor<HistoricalTimeRecord>(
                    predicate: #Predicate {
                        $0.sourceRecordType == sourceType && $0.instant <= cutoff
                    },
                    sortBy: [
                        SortDescriptor(\.instant, order: .reverse),
                        SortDescriptor(\.sourceRecordID)
                    ]
                )
            } else {
                descriptor = FetchDescriptor<HistoricalTimeRecord>(
                    predicate: #Predicate { $0.sourceRecordType == sourceType },
                    sortBy: [
                        SortDescriptor(\.instant, order: .reverse),
                        SortDescriptor(\.sourceRecordID)
                    ]
                )
            }
            descriptor.fetchOffset = fetchOffset
            descriptor.fetchLimit = batchLimit + 1
            let fetched = try modelContext.fetch(descriptor)
            databaseRowsRead += fetched.count
            let hasMore = fetched.count > batchLimit
            let batch = Array(fetched.prefix(batchLimit))
            guard !batch.isEmpty else { return [] }

            fetchOffset += batch.count
            for time in batch {
                guard rawTimeByEventID.updateValue(
                    time,
                    forKey: time.sourceRecordID
                ) == nil else {
                    throw AppDataFailure.corruptionSuspected
                }
            }

            let eligibleTimes = try batch.filter {
                try isAdministrationTimeAfterCursor($0, cursor: cursor)
            }
            let missingEventIDs = eligibleTimes
                .map(\.sourceRecordID)
                .filter { eventByID[$0] == nil }
            guard missingEventIDs.count <= resolutionLimit - databaseRowsRead else {
                throw AppDataFailure.corruptionSuspected
            }
            let batchEvents = try administrationEvents(ids: missingEventIDs)
            databaseRowsRead += batchEvents.count
            for event in batchEvents {
                guard eventByID.updateValue(event, forKey: event.id) == nil else {
                    throw AppDataFailure.corruptionSuspected
                }
            }

            let newOccurrenceKeys = Array(
                Set(batchEvents.map(\.occurrenceKey)).filter {
                    chainsByOccurrence[$0] == nil
                }
            )
            let chainEvents = try administrationEvents(
                occurrenceKeys: newOccurrenceKeys,
                maximumRecords: resolutionLimit - databaseRowsRead
            )
            databaseRowsRead += chainEvents.count
            let newChains = Dictionary(
                grouping: chainEvents,
                by: \.occurrenceKey
            )
            guard newChains.count == newOccurrenceKeys.count else {
                throw AppDataFailure.corruptionSuspected
            }
            for key in newOccurrenceKeys {
                guard let chain = newChains[key], !chain.isEmpty else {
                    throw AppDataFailure.corruptionSuspected
                }
                chainsByOccurrence[key] = chain
                for event in chain {
                    eventByID[event.id] = event
                }
            }

            let leaves = try effectiveAdministrationLeaves(
                chainsByOccurrence: chainsByOccurrence
            )
            let missingLeafIDs = leaves.map(\.id).filter {
                rawTimeByEventID[$0] == nil
            }
            guard missingLeafIDs.count
                    <= resolutionLimit - databaseRowsRead else {
                throw AppDataFailure.corruptionSuspected
            }
            let missingLeafTimes = try administrationTimes(ids: missingLeafIDs)
            databaseRowsRead += missingLeafTimes.count
            for time in missingLeafTimes {
                rawTimeByEventID[time.sourceRecordID] = time
            }
            let latestEffectiveTimes = try leaves.map { leaf in
                guard let time = rawTimeByEventID[leaf.id] else {
                    throw AppDataFailure.corruptionSuspected
                }
                return time
            }.filter {
                try isAdministrationTimeAfterCursor($0, cursor: cursor)
            }.sorted {
                if $0.instant != $1.instant {
                    return $0.instant > $1.instant
                }
                return $0.sourceRecordID.uuidString
                    < $1.sourceRecordID.uuidString
            }
            if latestEffectiveTimes.count >= pageLimit + 1 {
                return Array(latestEffectiveTimes.prefix(pageLimit + 1))
            }
            if !hasMore {
                return latestEffectiveTimes
            }
        }

        throw AppDataFailure.corruptionSuspected
    }

    private func administrationEvents(
        ids: [UUID]
    ) throws -> [AdministrationEventRecord] {
        guard !ids.isEmpty else { return [] }
        var result: [AdministrationEventRecord] = []
        let uniqueIDs = Array(Set(ids)).sorted {
            $0.uuidString < $1.uuidString
        }
        for start in stride(from: 0, to: uniqueIDs.count, by: 128) {
            let end = min(start + 128, uniqueIDs.count)
            let batch = Array(uniqueIDs[start..<end])
            var descriptor = FetchDescriptor<AdministrationEventRecord>(
                predicate: #Predicate { batch.contains($0.id) }
            )
            descriptor.fetchLimit = batch.count + 1
            let records = try modelContext.fetch(descriptor)
            guard records.count == batch.count else {
                throw AppDataFailure.corruptionSuspected
            }
            result.append(contentsOf: records)
        }
        return result
    }

    private func administrationEvents(
        occurrenceKeys: [String],
        maximumRecords: Int
    ) throws -> [AdministrationEventRecord] {
        guard !occurrenceKeys.isEmpty else { return [] }
        guard maximumRecords > 0 else {
            throw AppDataFailure.corruptionSuspected
        }
        var result: [AdministrationEventRecord] = []
        let uniqueKeys = Array(Set(occurrenceKeys)).sorted()
        for start in stride(from: 0, to: uniqueKeys.count, by: 128) {
            let end = min(start + 128, uniqueKeys.count)
            let batch = Array(uniqueKeys[start..<end])
            let remaining = maximumRecords - result.count
            guard remaining > 0 else {
                throw AppDataFailure.corruptionSuspected
            }
            var descriptor = FetchDescriptor<AdministrationEventRecord>(
                predicate: #Predicate { batch.contains($0.occurrenceKey) }
            )
            descriptor.fetchLimit = remaining
            let records = try modelContext.fetch(descriptor)
            guard records.count < remaining else {
                throw AppDataFailure.corruptionSuspected
            }
            result.append(contentsOf: records)
        }
        return result
    }

    private func effectiveAdministrationLeaves(
        chainsByOccurrence: [String: [AdministrationEventRecord]]
    ) throws -> [AdministrationEventRecord] {
        var leaves: [AdministrationEventRecord] = []
        for group in chainsByOccurrence.values {
            guard SupersessionChainValidator.formsSingleChain(
                group.map {
                    SupersessionLink(
                        id: $0.id,
                        predecessorID: $0.supersedesEventID
                    )
                }
            ) else {
                throw AppDataFailure.corruptionSuspected
            }
            let supersededIDs = Set(group.compactMap(\.supersedesEventID))
            guard let leaf = group.first(where: {
                !supersededIDs.contains($0.id)
            }) else {
                throw AppDataFailure.corruptionSuspected
            }
            leaves.append(leaf)
        }
        return leaves
    }

    private func administrationTimes(
        ids: [UUID]
    ) throws -> [HistoricalTimeRecord] {
        guard !ids.isEmpty else { return [] }
        let sourceType = "AdministrationEventRecord"
        var times: [HistoricalTimeRecord] = []
        let uniqueIDs = Array(Set(ids)).sorted {
            $0.uuidString < $1.uuidString
        }
        for start in stride(from: 0, to: uniqueIDs.count, by: 128) {
            let end = min(start + 128, uniqueIDs.count)
            let batch = Array(uniqueIDs[start..<end])
            var descriptor = FetchDescriptor<HistoricalTimeRecord>(
                predicate: #Predicate {
                    $0.sourceRecordType == sourceType
                        && batch.contains($0.sourceRecordID)
                }
            )
            descriptor.fetchLimit = batch.count + 1
            let records = try modelContext.fetch(descriptor)
            guard records.count == batch.count else {
                throw AppDataFailure.corruptionSuspected
            }
            times.append(contentsOf: records)
        }
        return times
    }

    private func isAdministrationTimeAfterCursor(
        _ time: HistoricalTimeRecord,
        cursor: PersonalTimelineCursor?
    ) throws -> Bool {
        guard let cursor else { return true }
        guard cursor.sortDomainRank == 0,
              let cursorMicroseconds = cursor.instantMicroseconds else {
            return false
        }
        let timeMicroseconds = try RecordDigestV1.timestampMicroseconds(
            time.instant
        )
        if timeMicroseconds != cursorMicroseconds {
            return timeMicroseconds < cursorMicroseconds
        }
        if PersonalTimelineItemKind.administration.rank != cursor.kindRank {
            return PersonalTimelineItemKind.administration.rank > cursor.kindRank
        }
        return time.sourceRecordID.uuidString > cursor.id.uuidString
    }

    private func regimenDateCandidates(
        after cursor: PersonalTimelineCursor?,
        pageLimit: Int
    ) throws -> [RegimenPlanVersionRecord] {
        let sealed = RegimenEditState.sealed.rawValue
        var descriptor: FetchDescriptor<RegimenPlanVersionRecord>
        if let cursor, cursor.sortDomainRank == 1 {
            let year = cursor.localDate.year
            let month = cursor.localDate.month
            let day = cursor.localDate.day
            let tieCount = try modelContext.fetchCount(
                FetchDescriptor<RegimenPlanVersionRecord>(
                    predicate: #Predicate {
                        $0.editStateRawValue == sealed
                            && !$0.isArchived
                            && !$0.requiresMigrationReview
                            && $0.effectiveStartYear == year
                            && $0.effectiveStartMonth == month
                            && $0.effectiveStartDay == day
                    }
                )
            )
            guard tieCount
                    <= PersonalTimelineCapacity.maximumSameInstantCursorTieCount
            else {
                throw AppDataFailure.corruptionSuspected
            }
            let (limitWithTies, firstOverflow) =
                pageLimit.addingReportingOverflow(tieCount)
            let (fetchLimit, secondOverflow) =
                limitWithTies.addingReportingOverflow(1)
            guard !firstOverflow, !secondOverflow else {
                throw AppDataFailure.corruptionSuspected
            }
            descriptor = FetchDescriptor<RegimenPlanVersionRecord>(
                predicate: #Predicate {
                    $0.editStateRawValue == sealed
                        && !$0.isArchived
                        && !$0.requiresMigrationReview
                        && (
                            $0.effectiveStartYear < year
                                || (
                                    $0.effectiveStartYear == year
                                        && $0.effectiveStartMonth < month
                                )
                                || (
                                    $0.effectiveStartYear == year
                                        && $0.effectiveStartMonth == month
                                        && $0.effectiveStartDay <= day
                                )
                        )
                },
                sortBy: [
                    SortDescriptor(\.effectiveStartYear, order: .reverse),
                    SortDescriptor(\.effectiveStartMonth, order: .reverse),
                    SortDescriptor(\.effectiveStartDay, order: .reverse),
                    SortDescriptor(\.id)
                ]
            )
            descriptor.fetchLimit = fetchLimit
        } else {
            descriptor = FetchDescriptor<RegimenPlanVersionRecord>(
                predicate: #Predicate {
                    $0.editStateRawValue == sealed
                        && !$0.isArchived
                        && !$0.requiresMigrationReview
                },
                sortBy: [
                    SortDescriptor(\.effectiveStartYear, order: .reverse),
                    SortDescriptor(\.effectiveStartMonth, order: .reverse),
                    SortDescriptor(\.effectiveStartDay, order: .reverse),
                    SortDescriptor(\.id)
                ]
            )
            descriptor.fetchLimit = pageLimit + 1
        }
        return try modelContext.fetch(descriptor)
    }

    private func requiredTimestamp(
        sourceType: String,
        sourceID: UUID,
        timeByKey: [String: HistoricalTimeRecord]
    ) throws -> HistoricalTimestamp {
        let key = sourceType + ":" + sourceID.uuidString.lowercased()
        guard let timestamp = timeByKey[key]?.historicalTimestamp else {
            throw AppDataFailure.corruptionSuspected
        }
        return timestamp
    }

    private func administrationLabel(_ status: AdministrationStatus) -> String {
        switch status {
        case .taken: "已记录"
        case .skipped: "已跳过"
        }
    }

    private static func isEarlierInTimeline(
        _ lhs: PersonalTimelineItem,
        _ rhs: PersonalTimelineItem
    ) -> Bool {
        let leftDomain = lhs.timestamp == nil ? 1 : 0
        let rightDomain = rhs.timestamp == nil ? 1 : 0
        if leftDomain != rightDomain { return leftDomain < rightDomain }
        switch (lhs.timestamp, rhs.timestamp) {
        case let (.some(left), .some(right)):
            if left.instant != right.instant { return left.instant > right.instant }
        case (.none, .none):
            if lhs.localDate != rhs.localDate {
                return rhs.localDate < lhs.localDate
            }
        case (.some, .none), (.none, .some):
            return leftDomain < rightDomain
        }
        if lhs.kind.rank != rhs.kind.rank { return lhs.kind.rank < rhs.kind.rank }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func cursor(_ item: PersonalTimelineItem) -> PersonalTimelineCursor {
        PersonalTimelineCursor(
            sortDomainRank: item.timestamp == nil ? 1 : 0,
            localDate: item.localDate,
            instantMicroseconds: item.timestamp.flatMap {
                try? RecordDigestV1.timestampMicroseconds($0.instant)
            },
            kindRank: item.kind.rank,
            id: item.id
        )
    }

    private static func isAfterCursor(
        _ item: PersonalTimelineItem,
        cursor: PersonalTimelineCursor
    ) -> Bool {
        let itemCursor = Self.cursor(item)
        if itemCursor.sortDomainRank != cursor.sortDomainRank {
            return itemCursor.sortDomainRank > cursor.sortDomainRank
        }
        if itemCursor.sortDomainRank == 0 {
            switch (itemCursor.instantMicroseconds, cursor.instantMicroseconds) {
            case let (.some(left), .some(right)) where left != right:
                return left < right
            default:
                break
            }
        } else if itemCursor.localDate != cursor.localDate {
            return itemCursor.localDate < cursor.localDate
        }
        if itemCursor.kindRank != cursor.kindRank {
            return itemCursor.kindRank > cursor.kindRank
        }
        return itemCursor.id.uuidString > cursor.id.uuidString
    }
}
