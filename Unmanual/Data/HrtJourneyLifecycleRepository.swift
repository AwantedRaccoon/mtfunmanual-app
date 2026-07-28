import Foundation
import SwiftData

enum HrtJourneyWriteFailure: Error, Equatable, Sendable {
    case invalidInput
    case missingFoundation
    case operationConflict
    case staleRecord
    case invalidTransition
    case capacityExceeded
    case corruptionSuspected
}

struct HrtJourneyMutationResult: Equatable, Sendable {
    let eventID: UUID
    let periodID: UUID
    let didApply: Bool
}

struct CreateHrtJourneyCommand: Sendable {
    let operationID: UUID
    let eventID: UUID
    let periodID: UUID
    let legacyProfileID: UUID
    let startDate: CivilDateFact
    let note: String
    let timestamp: HistoricalTimestamp

    init(
        operationID: UUID = UUID(),
        eventID: UUID = UUID(),
        periodID: UUID = UUID(),
        legacyProfileID: UUID = UUID(),
        startDate: CivilDateFact,
        note: String = "",
        timestamp: HistoricalTimestamp
    ) {
        self.operationID = operationID
        self.eventID = eventID
        self.periodID = periodID
        self.legacyProfileID = legacyProfileID
        self.startDate = startDate
        self.note = note
        self.timestamp = timestamp
    }
}

struct CorrectHrtJourneyFirstStartCommand: Sendable {
    let operationID: UUID
    let eventID: UUID
    let expectedLatestEventID: UUID
    let expectedPeriodID: UUID
    let correctedStartDate: CivilDateFact
    let note: String
    let timestamp: HistoricalTimestamp

    init(
        operationID: UUID = UUID(),
        eventID: UUID = UUID(),
        expectedLatestEventID: UUID,
        expectedPeriodID: UUID,
        correctedStartDate: CivilDateFact,
        note: String = "",
        timestamp: HistoricalTimestamp
    ) {
        self.operationID = operationID
        self.eventID = eventID
        self.expectedLatestEventID = expectedLatestEventID
        self.expectedPeriodID = expectedPeriodID
        self.correctedStartDate = correctedStartDate
        self.note = note
        self.timestamp = timestamp
    }
}

struct PauseHrtJourneyCommand: Sendable {
    let operationID: UUID
    let eventID: UUID
    let expectedLatestEventID: UUID
    let expectedOpenPeriodID: UUID
    let pauseDate: CivilDateFact
    let note: String
    let timestamp: HistoricalTimestamp

    init(
        operationID: UUID = UUID(),
        eventID: UUID = UUID(),
        expectedLatestEventID: UUID,
        expectedOpenPeriodID: UUID,
        pauseDate: CivilDateFact,
        note: String = "",
        timestamp: HistoricalTimestamp
    ) {
        self.operationID = operationID
        self.eventID = eventID
        self.expectedLatestEventID = expectedLatestEventID
        self.expectedOpenPeriodID = expectedOpenPeriodID
        self.pauseDate = pauseDate
        self.note = note
        self.timestamp = timestamp
    }
}

struct ResumeHrtJourneyCommand: Sendable {
    let operationID: UUID
    let eventID: UUID
    let periodID: UUID
    let expectedLatestEventID: UUID
    let expectedLastPeriodID: UUID
    let resumeDate: CivilDateFact
    let note: String
    let timestamp: HistoricalTimestamp

    init(
        operationID: UUID = UUID(),
        eventID: UUID = UUID(),
        periodID: UUID = UUID(),
        expectedLatestEventID: UUID,
        expectedLastPeriodID: UUID,
        resumeDate: CivilDateFact,
        note: String = "",
        timestamp: HistoricalTimestamp
    ) {
        self.operationID = operationID
        self.eventID = eventID
        self.periodID = periodID
        self.expectedLatestEventID = expectedLatestEventID
        self.expectedLastPeriodID = expectedLastPeriodID
        self.resumeDate = resumeDate
        self.note = note
        self.timestamp = timestamp
    }
}

extension AppWriteActor {
    func createHrtJourney(
        _ command: CreateHrtJourneyCommand,
        failureInjection: AppWriteFailureInjection? = nil
    ) throws -> HrtJourneyMutationResult {
        try ensureDataControlHrtJourneyIsWritable()
        let note = try normalizedHrtJourneyNote(command.note)
        try validateHrtTransitionDate(
            command.startDate,
            timestamp: command.timestamp
        )
        let digest = try HrtJourneyCommandDigest.create(
            command,
            normalizedNote: note
        )
        try validateHrtJourneyFoundation()
        try validateHrtLifecycleIntegrity()
        if let replay = try hrtJourneyReplay(
            operationID: command.operationID,
            digest: digest
        ) {
            return replay
        }
        try requireHrtJourneyCanBeCreated(command)

        modelContext.autosaveEnabled = false
        do {
            var result: HrtJourneyMutationResult?
            try modelContext.transaction {
                try ensureDataControlHrtJourneyIsWritable()
                try validateHrtLifecycleIntegrity()
                if let replay = try hrtJourneyReplay(
                    operationID: command.operationID,
                    digest: digest
                ) {
                    result = replay
                    return
                }
                try requireHrtJourneyCanBeCreated(command)
                let preFactsDigest = try hrtJourneyFactsDigest()
                let reservation = try reserveRevisionInCurrentTransaction(
                    committedAt: command.timestamp.instant
                )
                let displayDate = try hrtJourneyDisplayDate(
                    command.startDate,
                    timeZoneIdentifier: command.timestamp.timeZoneIdentifier
                )
                let legacy = HRTProfile(
                    id: command.legacyProfileID,
                    startDate: displayDate,
                    activePeriodStartDate: displayDate,
                    createdAt: command.timestamp.instant
                )
                let profile = HrtJourneyProfileRecord(
                    firstEverStartDate: command.startDate,
                    createdAt: command.timestamp.instant
                )
                let period = HrtPeriodRecord(
                    id: command.periodID,
                    startDate: command.startDate,
                    note: note,
                    createdAt: command.timestamp.instant
                )
                modelContext.insert(legacy)
                modelContext.insert(profile)
                modelContext.insert(period)
                let postFactsDigest = try hrtJourneyFactsDigest()
                let event = HrtJourneyLifecycleEventRecord(
                    id: command.eventID,
                    operationID: command.operationID,
                    kind: .started,
                    source: .user,
                    previousEventID: nil,
                    periodID: period.id,
                    transitionDate: command.startDate,
                    noteSnapshot: note,
                    timestamp: command.timestamp,
                    preFactsDigest: preFactsDigest,
                    postFactsDigest: postFactsDigest
                )
                modelContext.insert(event)
                if failureInjection == .beforeRevisionCommit {
                    throw AppWriteFailure.injected
                }
                try persistHrtJourneyFacts(
                    legacy: legacy,
                    profile: profile,
                    changedPeriods: [period],
                    event: event,
                    commandDigest: digest,
                    reservation: reservation
                )
                try validateHrtLifecycleIntegrity()
                result = HrtJourneyMutationResult(
                    eventID: event.id,
                    periodID: period.id,
                    didApply: true
                )
            }
            guard let result else {
                throw HrtJourneyWriteFailure.corruptionSuspected
            }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func pauseHrtJourney(
        _ command: PauseHrtJourneyCommand,
        failureInjection: AppWriteFailureInjection? = nil
    ) throws -> HrtJourneyMutationResult {
        try ensureDataControlHrtJourneyIsWritable()
        let note = try normalizedHrtJourneyNote(command.note)
        try validateHrtTransitionDate(
            command.pauseDate,
            timestamp: command.timestamp
        )
        let digest = try HrtJourneyCommandDigest.pause(
            command,
            normalizedNote: note
        )
        try validateHrtJourneyFoundation()
        try validateHrtLifecycleIntegrity()
        if let replay = try hrtJourneyReplay(
            operationID: command.operationID,
            digest: digest
        ) {
            return replay
        }
        _ = try requirePauseTarget(command)

        modelContext.autosaveEnabled = false
        do {
            var result: HrtJourneyMutationResult?
            try modelContext.transaction {
                try ensureDataControlHrtJourneyIsWritable()
                try validateHrtLifecycleIntegrity()
                if let replay = try hrtJourneyReplay(
                    operationID: command.operationID,
                    digest: digest
                ) {
                    result = replay
                    return
                }
                let target = try requirePauseTarget(command)
                let preFactsDigest = try hrtJourneyFactsDigest()
                let reservation = try reserveRevisionInCurrentTransaction(
                    committedAt: command.timestamp.instant
                )
                target.period.endYear = command.pauseDate.year
                target.period.endMonth = command.pauseDate.month
                target.period.endDay = command.pauseDate.day
                let postFactsDigest = try hrtJourneyFactsDigest()
                let event = HrtJourneyLifecycleEventRecord(
                    id: command.eventID,
                    operationID: command.operationID,
                    kind: .paused,
                    source: .user,
                    previousEventID: target.latestEvent.id,
                    periodID: target.period.id,
                    transitionDate: command.pauseDate,
                    noteSnapshot: note,
                    timestamp: command.timestamp,
                    preFactsDigest: preFactsDigest,
                    postFactsDigest: postFactsDigest
                )
                modelContext.insert(event)
                if failureInjection == .beforeRevisionCommit {
                    throw AppWriteFailure.injected
                }
                try persistHrtJourneyFacts(
                    legacy: target.legacy,
                    profile: target.profile,
                    changedPeriods: [target.period],
                    event: event,
                    commandDigest: digest,
                    reservation: reservation
                )
                try validateHrtLifecycleIntegrity()
                result = HrtJourneyMutationResult(
                    eventID: event.id,
                    periodID: target.period.id,
                    didApply: true
                )
            }
            guard let result else {
                throw HrtJourneyWriteFailure.corruptionSuspected
            }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func correctHrtJourneyFirstStart(
        _ command: CorrectHrtJourneyFirstStartCommand,
        failureInjection: AppWriteFailureInjection? = nil
    ) throws -> HrtJourneyMutationResult {
        try ensureDataControlHrtJourneyIsWritable()
        let note = try normalizedHrtJourneyNote(command.note)
        try validateHrtTransitionDate(
            command.correctedStartDate,
            timestamp: command.timestamp
        )
        let digest = try HrtJourneyCommandDigest.correctFirstStart(
            command,
            normalizedNote: note
        )
        try validateHrtJourneyFoundation()
        try validateHrtLifecycleIntegrity()
        if let replay = try hrtJourneyReplay(
            operationID: command.operationID,
            digest: digest
        ) {
            return replay
        }
        _ = try requireFirstStartCorrectionTarget(command)

        modelContext.autosaveEnabled = false
        do {
            var result: HrtJourneyMutationResult?
            try modelContext.transaction {
                try ensureDataControlHrtJourneyIsWritable()
                try validateHrtLifecycleIntegrity()
                if let replay = try hrtJourneyReplay(
                    operationID: command.operationID,
                    digest: digest
                ) {
                    result = replay
                    return
                }
                let target = try requireFirstStartCorrectionTarget(
                    command
                )
                let preFactsDigest = try hrtJourneyFactsDigest()
                let reservation = try reserveRevisionInCurrentTransaction(
                    committedAt: command.timestamp.instant
                )
                let displayDate = try hrtJourneyDisplayDate(
                    command.correctedStartDate,
                    timeZoneIdentifier:
                        command.timestamp.timeZoneIdentifier
                )
                target.legacy.startDate = displayDate
                target.legacy.activePeriodStartDate = displayDate
                target.profile.firstEverStartYear =
                    command.correctedStartDate.year
                target.profile.firstEverStartMonth =
                    command.correctedStartDate.month
                target.profile.firstEverStartDay =
                    command.correctedStartDate.day
                target.period.startYear =
                    command.correctedStartDate.year
                target.period.startMonth =
                    command.correctedStartDate.month
                target.period.startDay =
                    command.correctedStartDate.day
                let postFactsDigest = try hrtJourneyFactsDigest()
                let event = HrtJourneyLifecycleEventRecord(
                    id: command.eventID,
                    operationID: command.operationID,
                    kind: .firstStartCorrected,
                    source: .user,
                    previousEventID: target.latestEvent.id,
                    periodID: target.period.id,
                    transitionDate: command.correctedStartDate,
                    noteSnapshot: note,
                    timestamp: command.timestamp,
                    preFactsDigest: preFactsDigest,
                    postFactsDigest: postFactsDigest
                )
                modelContext.insert(event)
                if failureInjection == .beforeRevisionCommit {
                    throw AppWriteFailure.injected
                }
                try persistHrtJourneyFacts(
                    legacy: target.legacy,
                    profile: target.profile,
                    changedPeriods: [target.period],
                    event: event,
                    commandDigest: digest,
                    reservation: reservation
                )
                try validateHrtLifecycleIntegrity()
                result = HrtJourneyMutationResult(
                    eventID: event.id,
                    periodID: target.period.id,
                    didApply: true
                )
            }
            guard let result else {
                throw HrtJourneyWriteFailure.corruptionSuspected
            }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func resumeHrtJourney(
        _ command: ResumeHrtJourneyCommand,
        failureInjection: AppWriteFailureInjection? = nil
    ) throws -> HrtJourneyMutationResult {
        try ensureDataControlHrtJourneyIsWritable()
        let note = try normalizedHrtJourneyNote(command.note)
        try validateHrtTransitionDate(
            command.resumeDate,
            timestamp: command.timestamp
        )
        let digest = try HrtJourneyCommandDigest.resume(
            command,
            normalizedNote: note
        )
        try validateHrtJourneyFoundation()
        try validateHrtLifecycleIntegrity()
        if let replay = try hrtJourneyReplay(
            operationID: command.operationID,
            digest: digest
        ) {
            return replay
        }
        _ = try requireResumeTarget(command)

        modelContext.autosaveEnabled = false
        do {
            var result: HrtJourneyMutationResult?
            try modelContext.transaction {
                try ensureDataControlHrtJourneyIsWritable()
                try validateHrtLifecycleIntegrity()
                if let replay = try hrtJourneyReplay(
                    operationID: command.operationID,
                    digest: digest
                ) {
                    result = replay
                    return
                }
                let target = try requireResumeTarget(command)
                let preFactsDigest = try hrtJourneyFactsDigest()
                let reservation = try reserveRevisionInCurrentTransaction(
                    committedAt: command.timestamp.instant
                )
                let period = HrtPeriodRecord(
                    id: command.periodID,
                    startDate: command.resumeDate,
                    note: note,
                    createdAt: command.timestamp.instant
                )
                target.legacy.activePeriodStartDate =
                    try hrtJourneyDisplayDate(
                        command.resumeDate,
                        timeZoneIdentifier:
                            command.timestamp.timeZoneIdentifier
                    )
                modelContext.insert(period)
                let postFactsDigest = try hrtJourneyFactsDigest()
                let event = HrtJourneyLifecycleEventRecord(
                    id: command.eventID,
                    operationID: command.operationID,
                    kind: .resumed,
                    source: .user,
                    previousEventID: target.latestEvent.id,
                    periodID: period.id,
                    transitionDate: command.resumeDate,
                    noteSnapshot: note,
                    timestamp: command.timestamp,
                    preFactsDigest: preFactsDigest,
                    postFactsDigest: postFactsDigest
                )
                modelContext.insert(event)
                if failureInjection == .beforeRevisionCommit {
                    throw AppWriteFailure.injected
                }
                try persistHrtJourneyFacts(
                    legacy: target.legacy,
                    profile: target.profile,
                    changedPeriods: [period],
                    event: event,
                    commandDigest: digest,
                    reservation: reservation
                )
                try validateHrtLifecycleIntegrity()
                result = HrtJourneyMutationResult(
                    eventID: event.id,
                    periodID: period.id,
                    didApply: true
                )
            }
            guard let result else {
                throw HrtJourneyWriteFailure.corruptionSuspected
            }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func requireHrtJourneyCanBeCreated(
        _ command: CreateHrtJourneyCommand
    ) throws {
        guard try hrtLegacyProfile() == nil,
              try hrtJourneyProfile() == nil,
              try hrtPeriods().isEmpty,
              try hrtLifecycleEvents().isEmpty else {
            throw HrtJourneyWriteFailure.staleRecord
        }
        guard try hrtLifecycleEvent(id: command.eventID) == nil,
              try hrtPeriod(id: command.periodID) == nil else {
            throw HrtJourneyWriteFailure.invalidInput
        }
    }

    private func requirePauseTarget(
        _ command: PauseHrtJourneyCommand
    ) throws -> (
        legacy: HRTProfile,
        profile: HrtJourneyProfileRecord,
        period: HrtPeriodRecord,
        latestEvent: HrtJourneyLifecycleEventRecord
    ) {
        guard let legacy = try hrtLegacyProfile(),
              let profile = try hrtJourneyProfile() else {
            throw HrtJourneyWriteFailure.missingFoundation
        }
        let periods = try hrtPeriods()
        let open = periods.filter { $0.endDate == nil }
        guard open.count == 1,
              let period = open.first,
              period.id == command.expectedOpenPeriodID,
              let startDate = period.startDate else {
            throw HrtJourneyWriteFailure.staleRecord
        }
        guard startDate < command.pauseDate else {
            throw HrtJourneyWriteFailure.invalidTransition
        }
        guard let latest = try latestHrtLifecycleEvent(),
              latest.id == command.expectedLatestEventID else {
            throw HrtJourneyWriteFailure.staleRecord
        }
        guard try hrtLifecycleEvent(id: command.eventID) == nil else {
            throw HrtJourneyWriteFailure.invalidInput
        }
        return (legacy, profile, period, latest)
    }

    private func requireFirstStartCorrectionTarget(
        _ command: CorrectHrtJourneyFirstStartCommand
    ) throws -> (
        legacy: HRTProfile,
        profile: HrtJourneyProfileRecord,
        period: HrtPeriodRecord,
        latestEvent: HrtJourneyLifecycleEventRecord
    ) {
        guard let legacy = try hrtLegacyProfile(),
              let profile = try hrtJourneyProfile() else {
            throw HrtJourneyWriteFailure.missingFoundation
        }
        let periods = try hrtPeriods()
        guard periods.count == 1,
              let period = periods.first,
              period.id == command.expectedPeriodID,
              period.endDate == nil,
              let currentStartDate = period.startDate else {
            throw HrtJourneyWriteFailure.invalidTransition
        }
        guard currentStartDate != command.correctedStartDate else {
            throw HrtJourneyWriteFailure.invalidTransition
        }
        let events = try hrtLifecycleEvents()
        guard !events.contains(where: {
            $0.kind == .paused || $0.kind == .resumed
        }) else {
            throw HrtJourneyWriteFailure.invalidTransition
        }
        guard let latest = try latestHrtLifecycleEvent(),
              latest.id == command.expectedLatestEventID else {
            throw HrtJourneyWriteFailure.staleRecord
        }
        guard try hrtLifecycleEvent(id: command.eventID) == nil else {
            throw HrtJourneyWriteFailure.invalidInput
        }
        return (legacy, profile, period, latest)
    }

    private func requireResumeTarget(
        _ command: ResumeHrtJourneyCommand
    ) throws -> (
        legacy: HRTProfile,
        profile: HrtJourneyProfileRecord,
        latestEvent: HrtJourneyLifecycleEventRecord
    ) {
        guard let legacy = try hrtLegacyProfile(),
              let profile = try hrtJourneyProfile() else {
            throw HrtJourneyWriteFailure.missingFoundation
        }
        let periods = try hrtPeriods()
        guard periods.count < HrtJourneyProjection.maximumPeriodCount else {
            throw HrtJourneyWriteFailure.capacityExceeded
        }
        guard periods.allSatisfy({ $0.endDate != nil }),
              let last = periods.last,
              last.id == command.expectedLastPeriodID,
              let endDate = last.endDate else {
            throw HrtJourneyWriteFailure.staleRecord
        }
        guard endDate < command.resumeDate else {
            throw HrtJourneyWriteFailure.invalidTransition
        }
        guard let latest = try latestHrtLifecycleEvent(),
              latest.id == command.expectedLatestEventID else {
            throw HrtJourneyWriteFailure.staleRecord
        }
        guard try hrtLifecycleEvent(id: command.eventID) == nil,
              try hrtPeriod(id: command.periodID) == nil else {
            throw HrtJourneyWriteFailure.invalidInput
        }
        return (legacy, profile, latest)
    }

    private func persistHrtJourneyFacts(
        legacy: HRTProfile,
        profile: HrtJourneyProfileRecord,
        changedPeriods: [HrtPeriodRecord],
        event: HrtJourneyLifecycleEventRecord,
        commandDigest: String,
        reservation: ReservedRevision
    ) throws {
        let committedAt = event.occurredAt
        try upsertRevision(
            recordType: "HRTProfile",
            recordID: legacy.id,
            fields: try FactDigestV1.profile(legacy),
            reservation: reservation,
            committedAt: committedAt
        )
        try upsertRevision(
            recordType: "HrtJourneyProfileRecord",
            recordID: CoreTimeRegimenBackfill.stableUUID(
                for: HrtJourneyProfileRecord.fixedKey
            ),
            fields: CoreFactDigestV1.journeyProfile(profile),
            reservation: reservation,
            committedAt: committedAt
        )
        for period in changedPeriods {
            try upsertRevision(
                recordType: "HrtPeriodRecord",
                recordID: period.id,
                fields: try CoreFactDigestV1.period(period),
                reservation: reservation,
                committedAt: committedAt
            )
        }
        try upsertRevision(
            recordType: "HrtJourneyLifecycleEventRecord",
            recordID: event.id,
            fields: try HrtJourneyLifecycleDigest.event(event),
            reservation: reservation,
            committedAt: committedAt
        )
        try insertOperationReceipt(
            OperationReceiptRecord(
                operationID: event.operationID,
                commandDigest: commandDigest,
                resultRecordType: "HrtJourneyLifecycleEventRecord",
                resultRecordID: event.id,
                committedAt: committedAt
            ),
            reservation: reservation
        )
        try markCommitted(at: committedAt)
    }

    private func validateHrtJourneyFoundation() throws {
        var descriptor =
            FetchDescriptor<HrtJourneyLifecycleBackfillState>()
        descriptor.fetchLimit = 2
        let states = try modelContext.fetch(descriptor)
        guard states.count == 1,
              states.first?.completedAt != nil else {
            throw HrtJourneyWriteFailure.missingFoundation
        }
    }

    private func validateHrtLifecycleIntegrity() throws {
        do {
            try HrtJourneyLifecycleValidator.validate(
                in: modelContext,
                failure: .corruptionSuspected
            )
        } catch {
            throw HrtJourneyWriteFailure.corruptionSuspected
        }
    }

    private func validateHrtTransitionDate(
        _ date: CivilDateFact,
        timestamp: HistoricalTimestamp
    ) throws {
        guard date <= timestamp.localDate,
              timestamp.instant.timeIntervalSinceReferenceDate.isFinite
        else {
            throw HrtJourneyWriteFailure.invalidTransition
        }
    }

    private func normalizedHrtJourneyNote(
        _ value: String
    ) throws -> String {
        let normalized =
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count <= 500 else {
            throw HrtJourneyWriteFailure.invalidInput
        }
        return normalized
    }

    private func hrtJourneyDisplayDate(
        _ date: CivilDateFact,
        timeZoneIdentifier: String
    ) throws -> Date {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw HrtJourneyWriteFailure.invalidInput
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let result = calendar.date(
            from: DateComponents(
                year: date.year,
                month: date.month,
                day: date.day,
                hour: 12
            )
        ) else {
            throw HrtJourneyWriteFailure.invalidInput
        }
        return result
    }

    private func hrtJourneyReplay(
        operationID: UUID,
        digest: String
    ) throws -> HrtJourneyMutationResult? {
        var descriptor = FetchDescriptor<OperationReceiptRecord>(
            predicate: #Predicate { $0.operationID == operationID }
        )
        descriptor.fetchLimit = 2
        let receipts = try modelContext.fetch(descriptor)
        guard receipts.count <= 1 else {
            throw HrtJourneyWriteFailure.corruptionSuspected
        }
        guard let receipt = receipts.first else { return nil }
        guard receipt.commandDigest == digest,
              receipt.resultRecordType
                == "HrtJourneyLifecycleEventRecord",
              let event = try hrtLifecycleEvent(
                id: receipt.resultRecordID
              ),
              event.operationID == operationID,
              let periodID = event.periodID,
              try hrtPeriod(id: periodID) != nil else {
            throw HrtJourneyWriteFailure.operationConflict
        }
        return HrtJourneyMutationResult(
            eventID: event.id,
            periodID: periodID,
            didApply: false
        )
    }

    private func hrtJourneyFactsDigest() throws -> String {
        do {
            return try HrtJourneyLifecycleDigest.facts(
                in: modelContext,
                failure: .corruptionSuspected
            )
        } catch {
            throw HrtJourneyWriteFailure.corruptionSuspected
        }
    }

    private func hrtLegacyProfile() throws -> HRTProfile? {
        var descriptor = FetchDescriptor<HRTProfile>()
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count <= 1 else {
            throw HrtJourneyWriteFailure.corruptionSuspected
        }
        return records.first
    }

    private func hrtJourneyProfile()
        throws -> HrtJourneyProfileRecord? {
        var descriptor = FetchDescriptor<HrtJourneyProfileRecord>()
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count <= 1 else {
            throw HrtJourneyWriteFailure.corruptionSuspected
        }
        return records.first
    }

    private func hrtPeriods() throws -> [HrtPeriodRecord] {
        var descriptor = FetchDescriptor<HrtPeriodRecord>(
            sortBy: [
                SortDescriptor(\.startYear),
                SortDescriptor(\.startMonth),
                SortDescriptor(\.startDay),
                SortDescriptor(\.id)
            ]
        )
        descriptor.fetchLimit =
            HrtJourneyProjection.maximumPeriodCount + 1
        let records = try modelContext.fetch(descriptor)
        guard records.count <= HrtJourneyProjection.maximumPeriodCount
        else {
            throw HrtJourneyWriteFailure.capacityExceeded
        }
        return records
    }

    private func hrtPeriod(id: UUID) throws -> HrtPeriodRecord? {
        var descriptor = FetchDescriptor<HrtPeriodRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count <= 1 else {
            throw HrtJourneyWriteFailure.corruptionSuspected
        }
        return records.first
    }

    private func hrtLifecycleEvents()
        throws -> [HrtJourneyLifecycleEventRecord] {
        var descriptor =
            FetchDescriptor<HrtJourneyLifecycleEventRecord>()
        descriptor.fetchLimit =
            HrtJourneyLifecycleValidator.maximumEventCount + 1
        let records = try modelContext.fetch(descriptor)
        guard records.count <= HrtJourneyLifecycleValidator.maximumEventCount
        else {
            throw HrtJourneyWriteFailure.capacityExceeded
        }
        return records
    }

    private func hrtLifecycleEvent(
        id: UUID
    ) throws -> HrtJourneyLifecycleEventRecord? {
        var descriptor =
            FetchDescriptor<HrtJourneyLifecycleEventRecord>(
                predicate: #Predicate { $0.id == id }
            )
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count <= 1 else {
            throw HrtJourneyWriteFailure.corruptionSuspected
        }
        return records.first
    }

    private func latestHrtLifecycleEvent()
        throws -> HrtJourneyLifecycleEventRecord? {
        let events = try hrtLifecycleEvents()
        let predecessorIDs = Set(events.compactMap(\.previousEventID))
        let leaves = events.filter {
            !predecessorIDs.contains($0.id)
        }
        guard leaves.count <= 1 else {
            throw HrtJourneyWriteFailure.corruptionSuspected
        }
        return leaves.first
    }
}

enum HrtJourneyCommandDigest {
    static func create(
        _ command: CreateHrtJourneyCommand,
        normalizedNote: String
    ) throws -> String {
        try digest(
            recordType: "CreateHrtJourneyCommand",
            operationID: command.operationID,
            fields: [
                .init("eventID", .uuid(command.eventID)),
                .init("legacyProfileID", .uuid(command.legacyProfileID)),
                .init("note", .string(normalizedNote)),
                .init("periodID", .uuid(command.periodID)),
                .init("startDate", .string(command.startDate.iso8601))
            ],
            timestamp: command.timestamp
        )
    }

    static func pause(
        _ command: PauseHrtJourneyCommand,
        normalizedNote: String
    ) throws -> String {
        try digest(
            recordType: "PauseHrtJourneyCommand",
            operationID: command.operationID,
            fields: [
                .init(
                    "expectedLatestEventID",
                    .uuid(command.expectedLatestEventID)
                ),
                .init(
                    "expectedOpenPeriodID",
                    .uuid(command.expectedOpenPeriodID)
                ),
                .init("eventID", .uuid(command.eventID)),
                .init("note", .string(normalizedNote)),
                .init("pauseDate", .string(command.pauseDate.iso8601))
            ],
            timestamp: command.timestamp
        )
    }

    static func correctFirstStart(
        _ command: CorrectHrtJourneyFirstStartCommand,
        normalizedNote: String
    ) throws -> String {
        try digest(
            recordType: "CorrectHrtJourneyFirstStartCommand",
            operationID: command.operationID,
            fields: [
                .init(
                    "correctedStartDate",
                    .string(command.correctedStartDate.iso8601)
                ),
                .init(
                    "expectedLatestEventID",
                    .uuid(command.expectedLatestEventID)
                ),
                .init(
                    "expectedPeriodID",
                    .uuid(command.expectedPeriodID)
                ),
                .init("eventID", .uuid(command.eventID)),
                .init("note", .string(normalizedNote))
            ],
            timestamp: command.timestamp
        )
    }

    static func resume(
        _ command: ResumeHrtJourneyCommand,
        normalizedNote: String
    ) throws -> String {
        try digest(
            recordType: "ResumeHrtJourneyCommand",
            operationID: command.operationID,
            fields: [
                .init(
                    "expectedLastPeriodID",
                    .uuid(command.expectedLastPeriodID)
                ),
                .init(
                    "expectedLatestEventID",
                    .uuid(command.expectedLatestEventID)
                ),
                .init("eventID", .uuid(command.eventID)),
                .init("note", .string(normalizedNote)),
                .init("periodID", .uuid(command.periodID)),
                .init("resumeDate", .string(command.resumeDate.iso8601))
            ],
            timestamp: command.timestamp
        )
    }

    private static func digest(
        recordType: String,
        operationID: UUID,
        fields: [RecordDigestV1.Field],
        timestamp: HistoricalTimestamp
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: recordType,
            recordID: operationID,
            fields: fields + [
                .init(
                    "timestampInstant",
                    try RecordDigestV1.timestampValue(timestamp.instant)
                ),
                .init(
                    "timestampLocalDate",
                    .string(timestamp.localDate.iso8601)
                ),
                .init(
                    "timestampLocalHour",
                    .integer(Int64(timestamp.localTime.hour))
                ),
                .init(
                    "timestampLocalMinute",
                    .integer(Int64(timestamp.localTime.minute))
                ),
                .init(
                    "timestampLocalNanosecond",
                    .integer(Int64(timestamp.localTime.nanosecond))
                ),
                .init(
                    "timestampLocalSecond",
                    .integer(Int64(timestamp.localTime.second))
                ),
                .init(
                    "timestampPrecision",
                    .string(timestamp.precision.rawValue)
                ),
                .init(
                    "timestampProvenance",
                    .string(timestamp.provenance.rawValue)
                ),
                .init(
                    "timestampTimeZoneIdentifier",
                    .string(timestamp.timeZoneIdentifier)
                ),
                .init(
                    "timestampUTCOffsetSeconds",
                    .integer(Int64(timestamp.utcOffsetSeconds))
                )
            ]
        )
    }
}
