import Foundation
import SwiftData

enum HrtJourneyLifecycleDigest {
    static let absentFactsID = CoreTimeRegimenBackfill.stableUUID(
        for: "HrtJourneyFactsAbsentV2"
    )

    static func facts(
        in context: ModelContext,
        failure: AppDataFailure
    ) throws -> String {
        var profileDescriptor = FetchDescriptor<HrtJourneyProfileRecord>()
        profileDescriptor.fetchLimit = 2
        var legacyDescriptor = FetchDescriptor<HRTProfile>()
        legacyDescriptor.fetchLimit = 2
        var periodDescriptor = FetchDescriptor<HrtPeriodRecord>()
        periodDescriptor.fetchLimit =
            HrtJourneyProjection.maximumPeriodCount + 1
        let profiles = try context.fetch(profileDescriptor)
        let legacyProfiles = try context.fetch(legacyDescriptor)
        let periods = try context.fetch(periodDescriptor)
        guard profiles.count <= 1,
              legacyProfiles.count <= 1,
              periods.count <= HrtJourneyProjection.maximumPeriodCount else {
            throw failure
        }
        if profiles.isEmpty {
            guard periods.isEmpty,
                  legacyProfiles.isEmpty else {
                throw failure
            }
            return try RecordDigestV1.sha256Hex(
                recordType: "HrtJourneyFactsAbsentV2",
                recordID: absentFactsID,
                fields: []
            )
        }
        guard let profile = profiles.first,
              let legacyProfile = legacyProfiles.first,
              profile.singletonKey == HrtJourneyProfileRecord.fixedKey,
              let first = profile.firstEverStartDate else {
            throw failure
        }
        let facts = try periods.map { period -> HrtPeriodFact in
            guard let start = period.startDate,
                  (period.endYear == nil
                      && period.endMonth == nil
                      && period.endDay == nil)
                    || period.endDate != nil else {
                throw failure
            }
            return HrtPeriodFact(
                id: period.id,
                startDate: start,
                endDate: period.endDate,
                note: period.note
            )
        }
        let sorted: [HrtPeriodFact]
        do {
            sorted = try HrtJourneyProjection.validate(
                firstEverStartDate: first,
                periods: facts
            )
        } catch {
            throw failure
        }
        var fields: [RecordDigestV1.Field] = [
            .init("firstEverStartDate", .string(first.iso8601)),
            .init(
                "legacyActivePeriodStartDate",
                try RecordDigestV1.timestampValue(
                    legacyProfile.activePeriodStartDate
                )
            ),
            .init(
                "legacyCreatedAt",
                try RecordDigestV1.timestampValue(
                    legacyProfile.createdAt
                )
            ),
            .init("legacyProfileID", .uuid(legacyProfile.id)),
            .init(
                "legacyStartDate",
                try RecordDigestV1.timestampValue(
                    legacyProfile.startDate
                )
            ),
            .init("periodCount", .integer(Int64(sorted.count)))
        ]
        for (index, period) in sorted.enumerated() {
            let prefix = "period\(index)"
            fields.append(.init(prefix + "ID", .uuid(period.id)))
            fields.append(
                .init(
                    prefix + "StartDate",
                    .string(period.startDate.iso8601)
                )
            )
            fields.append(
                .init(
                    prefix + "EndDate",
                    period.endDate.map {
                        RecordDigestV1.Value.string($0.iso8601)
                    } ?? .null
                )
            )
            fields.append(.init(prefix + "Note", .string(period.note)))
        }
        return try RecordDigestV1.sha256Hex(
            recordType: "HrtJourneyFactsV2",
            recordID: CoreTimeRegimenBackfill.stableUUID(
                for: HrtJourneyProfileRecord.fixedKey
            ),
            fields: fields
        )
    }

    static func event(
        _ event: HrtJourneyLifecycleEventRecord
    ) throws -> [RecordDigestV1.Field] {
        [
            .init("kind", .string(event.kindRawValue)),
            .init("localDate", .string(
                try requiredTimestamp(event).localDate.iso8601
            )),
            .init(
                "localHour",
                .integer(Int64(try requiredTimestamp(event).localTime.hour))
            ),
            .init(
                "localMinute",
                .integer(Int64(try requiredTimestamp(event).localTime.minute))
            ),
            .init(
                "localNanosecond",
                .integer(Int64(try requiredTimestamp(event).localTime.nanosecond))
            ),
            .init(
                "localSecond",
                .integer(Int64(try requiredTimestamp(event).localTime.second))
            ),
            .init("noteSnapshot", .string(event.noteSnapshot)),
            .init("occurredAt", try RecordDigestV1.timestampValue(event.occurredAt)),
            .init("operationID", .uuid(event.operationID)),
            .init(
                "periodID",
                event.periodID.map(RecordDigestV1.Value.uuid) ?? .null
            ),
            .init(
                "precision",
                .string(try requiredTimestamp(event).precision.rawValue)
            ),
            .init(
                "previousEventID",
                event.previousEventID.map(RecordDigestV1.Value.uuid) ?? .null
            ),
            .init("preFactsDigest", .string(event.preFactsDigest)),
            .init("postFactsDigest", .string(event.postFactsDigest)),
            .init(
                "provenance",
                .string(try requiredTimestamp(event).provenance.rawValue)
            ),
            .init("source", .string(event.sourceRawValue)),
            .init(
                "timeZoneIdentifier",
                .string(try requiredTimestamp(event).timeZoneIdentifier)
            ),
            .init(
                "transitionDate",
                event.transitionDate.map {
                    RecordDigestV1.Value.string($0.iso8601)
                } ?? .null
            ),
            .init(
                "utcOffsetSeconds",
                .integer(
                    Int64(try requiredTimestamp(event).utcOffsetSeconds)
                )
            )
        ]
    }

    static func backfillState(
        _ state: HrtJourneyLifecycleBackfillState
    ) throws -> [RecordDigestV1.Field] {
        [
            .init(
                "completedAt",
                try state.completedAt.map(RecordDigestV1.timestampValue)
                    ?? .null
            ),
            .init(
                "initialEventCount",
                .integer(Int64(state.initialEventCount))
            ),
            .init("initialFactsDigest", .string(state.initialFactsDigest)),
            .init(
                "initialPeriodCount",
                .integer(Int64(state.initialPeriodCount))
            ),
            .init("sourceSchemaVersion", .string(state.sourceSchemaVersion)),
            .init("updatedAt", try RecordDigestV1.timestampValue(state.updatedAt))
        ]
    }

    private static func requiredTimestamp(
        _ event: HrtJourneyLifecycleEventRecord
    ) throws -> HistoricalTimestamp {
        guard let value = event.historicalTimestamp else {
            throw AppDataFailure.corruptionSuspected
        }
        return value
    }
}

enum HrtJourneyLifecycleValidator {
    static let maximumEventCount = 1_024

    static func validate(
        in context: ModelContext,
        failure: AppDataFailure
    ) throws {
        let currentFacts = try HrtJourneyLifecycleDigest.facts(
            in: context,
            failure: failure
        )
        var stateDescriptor =
            FetchDescriptor<HrtJourneyLifecycleBackfillState>()
        stateDescriptor.fetchLimit = 2
        var eventDescriptor =
            FetchDescriptor<HrtJourneyLifecycleEventRecord>()
        eventDescriptor.fetchLimit = maximumEventCount + 1
        let states = try context.fetch(stateDescriptor)
        let events = try context.fetch(eventDescriptor)
        guard states.count == 1,
              let state = states.first,
              state.taskKey == HrtJourneyLifecycleBackfillState.fixedKey,
              ["8.0.0", "9.0.0"].contains(state.sourceSchemaVersion),
              state.initialPeriodCount >= 0,
              state.initialPeriodCount
                <= HrtJourneyProjection.maximumPeriodCount,
              state.initialEventCount >= 0,
              state.initialEventCount <= 1,
              state.initialFactsDigest.count == 64,
              state.completedAt?.timeIntervalSince1970.isFinite == true,
              state.updatedAt.timeIntervalSince1970.isFinite,
              events.count <= maximumEventCount,
              Set(events.map(\.id)).count == events.count,
              Set(events.map(\.operationID)).count == events.count else {
            throw failure
        }

        let facts = try validatedFacts(
            in: context,
            failure: failure
        )
        let hrtResultRecordType = "HrtJourneyLifecycleEventRecord"
        var receiptDescriptor =
            FetchDescriptor<OperationReceiptRecord>(
                predicate: #Predicate {
                    $0.resultRecordType == hrtResultRecordType
                }
            )
        receiptDescriptor.fetchLimit = maximumEventCount + 1
        let receipts = try context.fetch(receiptDescriptor)
        guard receipts.count <= maximumEventCount else {
            throw failure
        }
        let hrtReceipts = receipts
        if events.isEmpty {
            guard currentFacts == state.initialFactsDigest,
                  state.initialEventCount == 0,
                  state.initialPeriodCount == 0,
                  facts == nil,
                  hrtReceipts.isEmpty else {
                throw failure
            }
            try validateRevisionAtomicity(
                in: context,
                state: state,
                chain: [],
                facts: nil,
                receipts: receipts,
                failure: failure
            )
            return
        }
        let byID = try AppDataIndex.checkedUniqueMap(
            events,
            keyedBy: \.id,
            failure: failure
        )
        let predecessorIDs = Set(events.compactMap(\.previousEventID))
        let leaves = events.filter { !predecessorIDs.contains($0.id) }
        guard leaves.count == 1, let leaf = leaves.first else {
            throw failure
        }
        var reversed: [HrtJourneyLifecycleEventRecord] = []
        var cursor: HrtJourneyLifecycleEventRecord? = leaf
        var visited = Set<UUID>()
        while let event = cursor {
            guard visited.insert(event.id).inserted,
                  event.kind != nil,
                  event.source != nil,
                  event.historicalTimestamp != nil,
                  event.preFactsDigest.count == 64,
                  event.postFactsDigest.count == 64 else {
                throw failure
            }
            reversed.append(event)
            cursor = try event.previousEventID.map {
                guard let predecessor = byID[$0] else { throw failure }
                return predecessor
            }
        }
        let chain = Array(reversed.reversed())
        guard chain.count == events.count else { throw failure }
        var prior: HrtJourneyLifecycleEventRecord?
        for event in chain {
            if let prior {
                guard event.previousEventID == prior.id,
                      event.preFactsDigest == prior.postFactsDigest else {
                    throw failure
                }
            } else {
                guard event.previousEventID == nil,
                      event.preFactsDigest == state.initialFactsDigest else {
                    throw failure
                }
            }
            switch (event.kind, event.source) {
            case (.migratedSnapshot, .migration):
                guard event.periodID == nil,
                      event.transitionDate == nil,
                      event.noteSnapshot.isEmpty,
                      event.preFactsDigest == event.postFactsDigest else {
                    throw failure
                }
            case (.started, .user),
                 (.firstStartCorrected, .user),
                 (.paused, .user),
                 (.resumed, .user):
                guard event.periodID != nil,
                      let transitionDate = event.transitionDate,
                      let historicalTimestamp =
                        event.historicalTimestamp,
                      event.noteSnapshot.count <= 500,
                      transitionDate
                        <= historicalTimestamp.localDate else {
                    throw failure
                }
            default:
                throw failure
            }
            prior = event
        }
        guard leaf.postFactsDigest == currentFacts else {
            throw failure
        }
        try validateLifecycleSemantics(
            chain: chain,
            state: state,
            facts: facts,
            failure: failure
        )
        try validateLegacyMirror(
            chain: chain,
            facts: facts,
            failure: failure
        )

        let receiptByOperationID = try AppDataIndex.checkedUniqueMap(
            receipts,
            keyedBy: \.operationID,
            failure: failure
        )
        let userEvents = events.filter { $0.source == .user }
        let eventByID = try AppDataIndex.checkedUniqueMap(
            events,
            keyedBy: \.id,
            failure: failure
        )
        guard hrtReceipts.count == userEvents.count,
              hrtReceipts.allSatisfy({ receipt in
                  guard receipt.commandDigest.count == 64,
                        receipt.commandDigest.allSatisfy(\.isHexDigit),
                        receipt.committedAt.timeIntervalSince1970.isFinite,
                        let event = eventByID[receipt.resultRecordID] else {
                      return false
                  }
                  return event.source == .user
                      && event.operationID == receipt.operationID
                      && event.occurredAt == receipt.committedAt
              }) else {
            throw failure
        }
        for event in userEvents {
            guard let receipt = receiptByOperationID[event.operationID],
                  receipt.resultRecordType
                    == "HrtJourneyLifecycleEventRecord",
                  receipt.resultRecordID == event.id,
                  receipt.commandDigest
                    == (try expectedCommandDigest(
                        for: event,
                        facts: facts,
                        failure: failure
                    )) else {
                throw failure
            }
        }
        try validateRevisionAtomicity(
            in: context,
            state: state,
            chain: chain,
            facts: facts,
            receipts: receipts,
            failure: failure
        )
    }

    private struct ValidatedFacts {
        let legacyProfile: HRTProfile
        let profileCreatedAt: Date
        let firstEverStartDate: CivilDateFact
        let periods: [HrtPeriodFact]
    }

    private enum MaterializedState: Equatable {
        case none
        case active
        case paused
    }

    private static func validatedFacts(
        in context: ModelContext,
        failure: AppDataFailure
    ) throws -> ValidatedFacts? {
        var profileDescriptor =
            FetchDescriptor<HrtJourneyProfileRecord>()
        profileDescriptor.fetchLimit = 2
        var legacyDescriptor = FetchDescriptor<HRTProfile>()
        legacyDescriptor.fetchLimit = 2
        var coreStateDescriptor =
            FetchDescriptor<CoreTimeRegimenBackfillState>()
        coreStateDescriptor.fetchLimit = 2
        var periodDescriptor = FetchDescriptor<HrtPeriodRecord>()
        periodDescriptor.fetchLimit =
            HrtJourneyProjection.maximumPeriodCount + 1
        let profiles = try context.fetch(profileDescriptor)
        let legacyProfiles = try context.fetch(legacyDescriptor)
        let coreStates = try context.fetch(coreStateDescriptor)
        let records = try context.fetch(periodDescriptor)
        guard profiles.count <= 1,
              legacyProfiles.count <= 1,
              coreStates.count == 1,
              let coreState = coreStates.first,
              coreState.taskKey
                == CoreTimeRegimenBackfillState.fixedKey,
              coreState.completedAt?.timeIntervalSince1970
                .isFinite == true,
              coreState.updatedAt.timeIntervalSince1970.isFinite,
              TimeZone(
                identifier: coreState.assumedTimeZoneIdentifier
              ) != nil,
              records.count <= HrtJourneyProjection.maximumPeriodCount
        else {
            throw failure
        }
        guard let profile = profiles.first else {
            guard records.isEmpty,
                  legacyProfiles.isEmpty else {
                throw failure
            }
            return nil
        }
        guard legacyProfiles.count == 1,
              let legacyProfile = legacyProfiles.first,
              legacyProfile.startDate.timeIntervalSince1970.isFinite,
              legacyProfile.activePeriodStartDate
                .timeIntervalSince1970.isFinite,
              legacyProfile.createdAt.timeIntervalSince1970.isFinite,
              profile.createdAt.timeIntervalSince1970.isFinite,
              legacyProfile.createdAt == profile.createdAt else {
            throw failure
        }
        guard profile.singletonKey
                == HrtJourneyProfileRecord.fixedKey,
              let first = profile.firstEverStartDate else {
            throw failure
        }
        let periods = try records.map { record in
            guard let start = record.startDate,
                  (record.endYear == nil
                      && record.endMonth == nil
                      && record.endDay == nil)
                    || record.endDate != nil else {
                throw failure
            }
            return HrtPeriodFact(
                id: record.id,
                startDate: start,
                endDate: record.endDate,
                note: record.note
            )
        }
        do {
            return ValidatedFacts(
                legacyProfile: legacyProfile,
                profileCreatedAt: profile.createdAt,
                firstEverStartDate: first,
                periods: try HrtJourneyProjection.validate(
                    firstEverStartDate: first,
                    periods: periods
                )
            )
        } catch {
            throw failure
        }
    }

    private static func validateLifecycleSemantics(
        chain: [HrtJourneyLifecycleEventRecord],
        state: HrtJourneyLifecycleBackfillState,
        facts: ValidatedFacts?,
        failure: AppDataFailure
    ) throws {
        let migrationEvents = chain.filter {
            $0.kind == .migratedSnapshot
        }
        guard migrationEvents.count == state.initialEventCount,
              state.initialEventCount == 0
                || (state.initialEventCount == 1
                    && chain.first?.kind == .migratedSnapshot),
              let facts else {
            throw failure
        }
        let periodsByID = try AppDataIndex.checkedUniqueMap(
            facts.periods,
            keyedBy: \.id,
            failure: failure
        )
        let allPeriodIDs = Set(periodsByID.keys)
        let userEvents = chain.filter { $0.source == .user }

        var materializedState: MaterializedState
        var knownPeriodIDs = Set<UUID>()
        var currentPeriodID: UUID?
        var firstPeriodID: UUID?
        var latestFirstStartTransition: CivilDateFact?
        var hasLifecycleBoundary = false

        if state.initialEventCount == 1 {
            guard state.initialPeriodCount > 0,
                  state.initialPeriodCount <= facts.periods.count else {
                throw failure
            }
            let initialPeriods =
                Array(facts.periods.prefix(state.initialPeriodCount))
            knownPeriodIDs = Set(initialPeriods.map(\.id))
            firstPeriodID = initialPeriods.first?.id
            currentPeriodID = initialPeriods.last?.id
            if let firstUserEvent = userEvents.first {
                switch firstUserEvent.kind {
                case .firstStartCorrected, .paused:
                    materializedState = .active
                case .resumed:
                    materializedState = .paused
                default:
                    throw failure
                }
            } else {
                materializedState =
                    initialPeriods.last?.endDate == nil
                    ? .active
                    : .paused
            }
        } else {
            guard state.initialPeriodCount == 0,
                  migrationEvents.isEmpty else {
                throw failure
            }
            materializedState = .none
        }

        for event in chain {
            guard let kind = event.kind else { throw failure }
            if kind == .migratedSnapshot {
                continue
            }
            guard event.source == .user,
                  let periodID = event.periodID,
                  let transitionDate = event.transitionDate,
                  let period = periodsByID[periodID] else {
                throw failure
            }
            switch kind {
            case .started:
                guard materializedState == .none,
                      knownPeriodIDs.isEmpty,
                      periodID == facts.periods.first?.id else {
                    throw failure
                }
                knownPeriodIDs.insert(periodID)
                currentPeriodID = periodID
                firstPeriodID = periodID
                latestFirstStartTransition = transitionDate
                materializedState = .active
            case .firstStartCorrected:
                guard materializedState == .active,
                      !hasLifecycleBoundary,
                      knownPeriodIDs.count == 1,
                      currentPeriodID == periodID,
                      firstPeriodID == periodID else {
                    throw failure
                }
                latestFirstStartTransition = transitionDate
            case .paused:
                guard materializedState == .active,
                      currentPeriodID == periodID,
                      period.endDate == transitionDate else {
                    throw failure
                }
                materializedState = .paused
                hasLifecycleBoundary = true
            case .resumed:
                guard materializedState == .paused,
                      !knownPeriodIDs.contains(periodID),
                      period.startDate == transitionDate,
                      let priorID = currentPeriodID,
                      let priorEnd = periodsByID[priorID]?.endDate,
                      priorEnd < transitionDate else {
                    throw failure
                }
                knownPeriodIDs.insert(periodID)
                currentPeriodID = periodID
                materializedState = .active
                hasLifecycleBoundary = true
            case .migratedSnapshot:
                throw failure
            }
        }

        guard knownPeriodIDs == allPeriodIDs,
              firstPeriodID == facts.periods.first?.id,
              currentPeriodID == facts.periods.last?.id,
              materializedState
                == (facts.periods.last?.endDate == nil
                    ? .active
                    : .paused) else {
            throw failure
        }
        if let latestFirstStartTransition {
            guard latestFirstStartTransition
                    == facts.firstEverStartDate,
                  latestFirstStartTransition
                    == facts.periods.first?.startDate else {
                throw failure
            }
        }
    }

    private static func validateLegacyMirror(
        chain: [HrtJourneyLifecycleEventRecord],
        facts: ValidatedFacts?,
        failure: AppDataFailure
    ) throws {
        guard let facts,
              facts.profileCreatedAt
                == facts.legacyProfile.createdAt,
              let firstPeriod = facts.periods.first,
              let latestPeriod = facts.periods.last else {
            throw failure
        }
        let firstAnchor = chain.last { event in
            event.source == .user
                && event.periodID == firstPeriod.id
                && (event.kind == .started
                    || event.kind == .firstStartCorrected)
        }
        let activeAnchor = chain.last { event in
            event.source == .user
                && event.periodID == latestPeriod.id
                && (event.kind == .started
                    || event.kind == .firstStartCorrected
                    || event.kind == .resumed)
        }
        try validateLegacyDate(
            facts.legacyProfile.startDate,
            mirrors: facts.firstEverStartDate,
            userAnchor: firstAnchor,
            hasFrozenMigrationRoot:
                chain.first?.kind == .migratedSnapshot,
            failure: failure
        )
        try validateLegacyDate(
            facts.legacyProfile.activePeriodStartDate,
            mirrors: latestPeriod.startDate,
            userAnchor: activeAnchor,
            hasFrozenMigrationRoot:
                chain.first?.kind == .migratedSnapshot,
            failure: failure
        )
    }

    private static func validateLegacyDate(
        _ legacyDate: Date,
        mirrors civilDate: CivilDateFact,
        userAnchor: HrtJourneyLifecycleEventRecord?,
        hasFrozenMigrationRoot: Bool,
        failure: AppDataFailure
    ) throws {
        if let userAnchor {
            guard let timestamp = userAnchor.historicalTimestamp,
                  let timeZone = TimeZone(
                    identifier: timestamp.timeZoneIdentifier
                  ) else {
                throw failure
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            guard let expected = calendar.date(
                from: DateComponents(
                    year: civilDate.year,
                    month: civilDate.month,
                    day: civilDate.day,
                    hour: 12
                )
            ),
            legacyDate == expected else {
                throw failure
            }
            return
        }
        // V8 stored the legacy Date instant and canonical civil date in one
        // audited revision, but did not persist the command's time-zone ID.
        // V9 therefore freezes both values into the migration root digest.
        // Once a V9 user event supplies zone provenance, the exact noon mirror
        // rule above replaces this migration-only frozen-pair rule.
        guard hasFrozenMigrationRoot,
              legacyDate.timeIntervalSince1970.isFinite else {
            throw failure
        }
    }

    private static func validateRevisionAtomicity(
        in context: ModelContext,
        state: HrtJourneyLifecycleBackfillState,
        chain: [HrtJourneyLifecycleEventRecord],
        facts: ValidatedFacts?,
        receipts: [OperationReceiptRecord],
        failure: AppDataFailure
    ) throws {
        let relevantTypes: [(recordType: String, fetchLimit: Int)] = [
            ("HrtJourneyLifecycleBackfillState", 2),
            (
                "HrtJourneyLifecycleEventRecord",
                maximumEventCount + 1
            ),
            ("HRTProfile", 2),
            ("HrtJourneyProfileRecord", 2),
            (
                "HrtPeriodRecord",
                HrtJourneyProjection.maximumPeriodCount + 1
            ),
            ("OperationReceiptLedgerRecord", 2)
        ]
        var collectedRevisions: [RecordRevision] = []
        for relevantType in relevantTypes {
            let records = try revisions(
                recordType: relevantType.recordType,
                fetchLimit: relevantType.fetchLimit,
                in: context
            )
            guard records.count < relevantType.fetchLimit else {
                throw failure
            }
            collectedRevisions += records
        }
        for receipt in receipts {
            let records = try revisions(
                recordType: "OperationReceiptRecord",
                recordID: receipt.operationID,
                in: context
            )
            guard records.count == 1 else {
                throw failure
            }
            collectedRevisions += records
        }
        let revisionByKey = try AppDataIndex.checkedUniqueMap(
            collectedRevisions,
            keyedBy: \.recordKey,
            failure: failure
        )
        let stateRevision = try verifiedLocalRevision(
            recordType: "HrtJourneyLifecycleBackfillState",
            recordID: CoreTimeRegimenBackfill.stableUUID(
                for: HrtJourneyLifecycleBackfillState.fixedKey
            ),
            committedAt: state.updatedAt,
            revisionByKey: revisionByKey,
            failure: failure
        )

        let receiptByOperationID = try AppDataIndex.checkedUniqueMap(
            receipts,
            keyedBy: \.operationID,
            failure: failure
        )
        var eventRevisionByID: [UUID: Int64] = [:]
        var latestEventByPeriodID:
            [UUID: HrtJourneyLifecycleEventRecord] = [:]
        var previousEventRevision: Int64?
        for event in chain {
            let eventRevision = try verifiedLocalRevision(
                recordType: "HrtJourneyLifecycleEventRecord",
                recordID: event.id,
                committedAt: event.occurredAt,
                revisionByKey: revisionByKey,
                failure: failure
            )
            eventRevisionByID[event.id] = eventRevision
            switch event.source {
            case .migration:
                guard previousEventRevision == nil,
                      eventRevision == stateRevision else {
                    throw failure
                }
            case .user:
                guard eventRevision > stateRevision,
                      previousEventRevision.map({
                          eventRevision > $0
                      }) ?? true else {
                    throw failure
                }
                guard let receipt =
                        receiptByOperationID[event.operationID],
                      try verifiedLocalRevision(
                          recordType: "OperationReceiptRecord",
                          recordID: receipt.operationID,
                          committedAt: receipt.committedAt,
                          revisionByKey: revisionByKey,
                          failure: failure
                      ) == eventRevision else {
                    throw failure
                }
                if let periodID = event.periodID {
                    latestEventByPeriodID[periodID] = event
                }
            case .none:
                throw failure
            }
            previousEventRevision = eventRevision
        }

        let userEvents = chain.filter { $0.source == .user }
        if let latestUserEvent = userEvents.last,
           let facts,
           let latestRevision =
                eventRevisionByID[latestUserEvent.id] {
            let profileRevision = try verifiedLocalRevision(
                recordType: "HrtJourneyProfileRecord",
                recordID: CoreTimeRegimenBackfill.stableUUID(
                    for: HrtJourneyProfileRecord.fixedKey
                ),
                committedAt: latestUserEvent.occurredAt,
                revisionByKey: revisionByKey,
                failure: failure
            )
            let legacyRevision = try verifiedLocalRevision(
                recordType: "HRTProfile",
                recordID: facts.legacyProfile.id,
                committedAt: latestUserEvent.occurredAt,
                revisionByKey: revisionByKey,
                failure: failure
            )
            guard profileRevision == latestRevision,
                  legacyRevision == latestRevision else {
                throw failure
            }
        }
        for period in facts?.periods ?? [] {
            guard let event = latestEventByPeriodID[period.id],
                  let eventRevision = eventRevisionByID[event.id]
            else {
                continue
            }
            guard try verifiedLocalRevision(
                recordType: "HrtPeriodRecord",
                recordID: period.id,
                committedAt: event.occurredAt,
                revisionByKey: revisionByKey,
                failure: failure
            ) == eventRevision else {
                throw failure
            }
        }

        var ledgerDescriptor =
            FetchDescriptor<OperationReceiptLedgerRecord>()
        ledgerDescriptor.fetchLimit = 2
        let ledgers = try context.fetch(ledgerDescriptor)
        guard ledgers.count == 1,
              let ledger = ledgers.first,
              ledger.ledgerKey
                == OperationReceiptLedgerRecord.fixedKey,
              ledger.updatedAt.timeIntervalSince1970.isFinite else {
            throw failure
        }
        let ledgerRevision = try verifiedLocalRevision(
            recordType: "OperationReceiptLedgerRecord",
            recordID: TodayExecutionDigestV1.receiptLedgerID,
            committedAt: ledger.updatedAt,
            revisionByKey: revisionByKey,
            failure: failure
        )
        if let latestReceiptRevision = try latestRevision(
            recordType: "OperationReceiptRecord",
            in: context
        ) {
            guard ledgerRevision != latestReceiptRevision.localRevision else {
                return
            }
            guard latestReceiptRevision.localRevision < Int64.max,
                  ledgerRevision == latestReceiptRevision.localRevision + 1,
                  let latestReceipt = try operationReceipt(
                    operationID: latestReceiptRevision.recordID,
                    in: context,
                    failure: failure
                  ),
                  latestReceipt.resultRecordType
                    == "CountdownLifecycleEventRecord" else {
                throw failure
            }
            var countdownBackfillDescriptor =
                FetchDescriptor<CountdownLifecycleBackfillState>()
            countdownBackfillDescriptor.fetchLimit = 2
            let countdownBackfills = try context.fetch(
                countdownBackfillDescriptor
            )
            guard countdownBackfills.count == 1,
                  let countdownBackfill = countdownBackfills.first,
                  countdownBackfill.taskKey
                    == CountdownLifecycleBackfillState.fixedKey,
                  countdownBackfill.completedAt == ledger.updatedAt,
                  countdownBackfill.updatedAt == ledger.updatedAt else {
                throw failure
            }
        }
    }

    private static func verifiedLocalRevision(
        recordType: String,
        recordID: UUID,
        committedAt: Date,
        revisionByKey: [String: RecordRevision],
        failure: AppDataFailure
    ) throws -> Int64 {
        let key =
            recordType + ":" + recordID.uuidString.lowercased()
        guard let revision = revisionByKey[key],
              revision.recordKey == key,
              revision.recordType == recordType,
              revision.recordID == recordID,
              revision.localRevision > 0,
              revision.digestVersion == RecordDigestV1.version,
              revision.committedAt == committedAt else {
            throw failure
        }
        return revision.localRevision
    }

    private static func revisions(
        recordType: String,
        fetchLimit: Int,
        in context: ModelContext
    ) throws -> [RecordRevision] {
        let expectedType = recordType
        var descriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate {
                $0.recordType == expectedType
            }
        )
        descriptor.fetchLimit = fetchLimit
        return try context.fetch(descriptor)
    }

    private static func revisions(
        recordType: String,
        recordID: UUID,
        in context: ModelContext
    ) throws -> [RecordRevision] {
        let expectedType = recordType
        let expectedID = recordID
        var descriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate {
                $0.recordType == expectedType
                    && $0.recordID == expectedID
            }
        )
        descriptor.fetchLimit = 2
        return try context.fetch(descriptor)
    }

    private static func operationReceipt(
        operationID: UUID,
        in context: ModelContext,
        failure: AppDataFailure
    ) throws -> OperationReceiptRecord? {
        let expectedID = operationID
        var descriptor = FetchDescriptor<OperationReceiptRecord>(
            predicate: #Predicate {
                $0.operationID == expectedID
            }
        )
        descriptor.fetchLimit = 2
        let records = try context.fetch(descriptor)
        guard records.count <= 1 else {
            throw failure
        }
        return records.first
    }

    private static func latestRevision(
        recordType: String,
        in context: ModelContext
    ) throws -> RecordRevision? {
        let expectedType = recordType
        var descriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate {
                $0.recordType == expectedType
            },
            sortBy: [
                SortDescriptor(
                    \.localRevision,
                    order: .reverse
                )
            ]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func expectedCommandDigest(
        for event: HrtJourneyLifecycleEventRecord,
        facts: ValidatedFacts?,
        failure: AppDataFailure
    ) throws -> String {
        guard let facts,
              event.source == .user,
              let kind = event.kind,
              let periodID = event.periodID,
              let transitionDate = event.transitionDate,
              let timestamp = event.historicalTimestamp else {
            throw failure
        }
        do {
            switch kind {
            case .started:
                guard event.previousEventID == nil else {
                    throw failure
                }
                return try HrtJourneyCommandDigest.create(
                    CreateHrtJourneyCommand(
                        operationID: event.operationID,
                        eventID: event.id,
                        periodID: periodID,
                        legacyProfileID: facts.legacyProfile.id,
                        startDate: transitionDate,
                        note: event.noteSnapshot,
                        timestamp: timestamp
                    ),
                    normalizedNote: event.noteSnapshot
                )
            case .firstStartCorrected:
                guard let previousEventID =
                        event.previousEventID else {
                    throw failure
                }
                return try HrtJourneyCommandDigest.correctFirstStart(
                    CorrectHrtJourneyFirstStartCommand(
                        operationID: event.operationID,
                        eventID: event.id,
                        expectedLatestEventID: previousEventID,
                        expectedPeriodID: periodID,
                        correctedStartDate: transitionDate,
                        note: event.noteSnapshot,
                        timestamp: timestamp
                    ),
                    normalizedNote: event.noteSnapshot
                )
            case .paused:
                guard let previousEventID =
                        event.previousEventID else {
                    throw failure
                }
                return try HrtJourneyCommandDigest.pause(
                    PauseHrtJourneyCommand(
                        operationID: event.operationID,
                        eventID: event.id,
                        expectedLatestEventID: previousEventID,
                        expectedOpenPeriodID: periodID,
                        pauseDate: transitionDate,
                        note: event.noteSnapshot,
                        timestamp: timestamp
                    ),
                    normalizedNote: event.noteSnapshot
                )
            case .resumed:
                guard let previousEventID =
                        event.previousEventID,
                      let periodIndex = facts.periods.firstIndex(
                        where: { $0.id == periodID }
                      ),
                      periodIndex > facts.periods.startIndex else {
                    throw failure
                }
                let previousPeriodID = facts.periods[
                    facts.periods.index(before: periodIndex)
                ].id
                return try HrtJourneyCommandDigest.resume(
                    ResumeHrtJourneyCommand(
                        operationID: event.operationID,
                        eventID: event.id,
                        periodID: periodID,
                        expectedLatestEventID: previousEventID,
                        expectedLastPeriodID: previousPeriodID,
                        resumeDate: transitionDate,
                        note: event.noteSnapshot,
                        timestamp: timestamp
                    ),
                    normalizedNote: event.noteSnapshot
                )
            case .migratedSnapshot:
                throw failure
            }
        } catch let error as AppDataFailure {
            throw error
        } catch {
            throw failure
        }
    }
}
