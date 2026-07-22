import Foundation
import SwiftData
import SwiftUI

enum AppWriteFailure: Error, Equatable, Sendable {
    case invalidInput
    case missingFoundation
    case revisionExhausted
    case staleRecord
    case injected
}

enum AppWriteFailureInjection: Equatable, Sendable {
    case beforeRevisionCommit
}

struct SetStartDateCommand: Sendable {
    let recordID: UUID
    let expectsExistingRecord: Bool
    let startDate: Date
    let timeZoneIdentifier: String
    let committedAt: Date

    init(
        recordID: UUID = UUID(),
        expectsExistingRecord: Bool = false,
        startDate: Date,
        timeZoneIdentifier: String = TimeZone.autoupdatingCurrent.identifier,
        committedAt: Date = Date()
    ) {
        self.recordID = recordID
        self.expectsExistingRecord = expectsExistingRecord
        self.startDate = startDate
        self.timeZoneIdentifier = timeZoneIdentifier
        self.committedAt = committedAt
    }
}

struct SaveCountdownCommand: Sendable {
    let recordID: UUID
    let expectsExistingRecord: Bool
    let title: String
    let gentleTitle: String?
    let targetDate: Date
    let committedAt: Date

    init(
        recordID: UUID = UUID(),
        expectsExistingRecord: Bool = false,
        title: String,
        gentleTitle: String?,
        targetDate: Date,
        committedAt: Date = Date()
    ) {
        self.recordID = recordID
        self.expectsExistingRecord = expectsExistingRecord
        self.title = title
        self.gentleTitle = gentleTitle
        self.targetDate = targetDate
        self.committedAt = committedAt
    }
}

struct AddJourneyEntryCommand: Sendable {
    let recordID: UUID
    let text: String
    let kind: JourneyEntryKind
    let occurredAt: Date
    let regimenVersionID: UUID?
    let timeZoneIdentifier: String
    let committedAt: Date

    init(
        recordID: UUID = UUID(),
        text: String,
        kind: JourneyEntryKind,
        occurredAt: Date,
        regimenVersionID: UUID?,
        timeZoneIdentifier: String = TimeZone.autoupdatingCurrent.identifier,
        committedAt: Date = Date()
    ) {
        self.recordID = recordID
        self.text = text
        self.kind = kind
        self.occurredAt = occurredAt
        self.regimenVersionID = regimenVersionID
        self.timeZoneIdentifier = timeZoneIdentifier
        self.committedAt = committedAt
    }
}

#if DEBUG
struct CreateRegimenVersionCommand: Sendable {
    let recordID: UUID
    let activeRegimenID: UUID?
    let code: String
    let title: String
    let startedAt: Date
    let note: String
    let committedAt: Date

    init(
        recordID: UUID = UUID(),
        activeRegimenID: UUID?,
        code: String,
        title: String,
        startedAt: Date,
        note: String,
        committedAt: Date = Date()
    ) {
        self.recordID = recordID
        self.activeRegimenID = activeRegimenID
        self.code = code
        self.title = title
        self.startedAt = startedAt
        self.note = note
        self.committedAt = committedAt
    }
}
#endif

struct RegimenScheduleInput: Equatable, Sendable {
    let id: UUID
    let kind: ScheduleRuleKind
    let localTimes: String
    let weekdays: String
    let intervalDays: Int?
    let timeZoneBehavior: ScheduleTimeZoneBehavior
    let fixedTimeZoneIdentifier: String?
    let reminderEnabled: Bool
    let defaultSnoozeMinutes: Int

    init(
        id: UUID = UUID(),
        kind: ScheduleRuleKind,
        localTimes: String = "",
        weekdays: String = "",
        intervalDays: Int? = nil,
        timeZoneBehavior: ScheduleTimeZoneBehavior = .floatingLocal,
        fixedTimeZoneIdentifier: String? = nil,
        reminderEnabled: Bool = false,
        defaultSnoozeMinutes: Int = 10
    ) {
        self.id = id
        self.kind = kind
        self.localTimes = localTimes
        self.weekdays = weekdays
        self.intervalDays = intervalDays
        self.timeZoneBehavior = timeZoneBehavior
        self.fixedTimeZoneIdentifier = fixedTimeZoneIdentifier
        self.reminderEnabled = reminderEnabled
        self.defaultSnoozeMinutes = defaultSnoozeMinutes
    }
}

struct RegimenItemInput: Identifiable, Equatable, Sendable {
    let id: UUID
    let catalogProductID: String?
    let catalogVersion: String?
    let displayName: String
    let genericName: String
    let dosageForm: String
    let route: String
    let doseOriginal: String
    let unitOriginal: String
    let productSnapshot: String
    let schedule: RegimenScheduleInput?

    init(
        id: UUID = UUID(),
        catalogProductID: String? = nil,
        catalogVersion: String? = nil,
        displayName: String,
        genericName: String = "",
        dosageForm: String = "",
        route: String = "",
        doseOriginal: String = "",
        unitOriginal: String = "",
        productSnapshot: String = "",
        schedule: RegimenScheduleInput? = nil
    ) {
        self.id = id
        self.catalogProductID = catalogProductID
        self.catalogVersion = catalogVersion
        self.displayName = displayName
        self.genericName = genericName
        self.dosageForm = dosageForm
        self.route = route
        self.doseOriginal = doseOriginal
        self.unitOriginal = unitOriginal
        self.productSnapshot = productSnapshot
        self.schedule = schedule
    }
}

struct SaveRegimenDraftCommand: Sendable {
    let recordID: UUID
    let previousVersionID: UUID?
    let code: String
    let title: String
    let effectiveStartDate: CivilDateFact
    let changeReason: String
    let items: [RegimenItemInput]
    let committedAt: Date
}

struct RegimenChangeVersionPreview: Equatable, Sendable {
    let code: String
    let title: String
    let items: [String]
}

struct RegimenImpactRecordPreview: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceRecordType: String
    let localDate: CivilDateFact
    let summary: String
    let beforeRegimenVersionID: UUID?
    let afterRegimenVersionID: UUID?
}

struct RegimenChangePreview: Equatable, Sendable {
    let draftID: UUID
    let expectedNextLocalRevision: Int64
    let draftDigest: String
    let before: RegimenChangeVersionPreview?
    let after: RegimenChangeVersionPreview
    let affectedJourneyIDs: [UUID]
    let affectedLabIDs: [UUID]
    let affectedRecords: [RegimenImpactRecordPreview]
}

struct SealRegimenDraftCommand: Sendable {
    let draftID: UUID
    let expectedNextLocalRevision: Int64
    let draftDigest: String
    let committedAt: Date
}

struct SaveLabImportCommand: Sendable {
    let entries: [LabImportEntry]
    let sampledAt: Date
    let regimenVersionID: UUID?
    let timeZoneIdentifier: String
    let precision: HistoricalTimestampPrecision
    let committedAt: Date

    init(
        entries: [LabImportEntry],
        sampledAt: Date,
        regimenVersionID: UUID?,
        timeZoneIdentifier: String = TimeZone.autoupdatingCurrent.identifier,
        precision: HistoricalTimestampPrecision = .minute,
        committedAt: Date = Date()
    ) {
        self.entries = entries
        self.sampledAt = sampledAt
        self.regimenVersionID = regimenVersionID
        self.timeZoneIdentifier = timeZoneIdentifier
        self.precision = precision
        self.committedAt = committedAt
    }
}

@ModelActor
actor AppWriteActor {
    struct ReservedRevision {
        let datasetID: UUID
        let localRevision: Int64
    }

    func setStartDate(
        _ command: SetStartDateCommand,
        failureInjection: AppWriteFailureInjection? = nil
    ) throws {
        let canonicalDate: CivilDateFact
        do {
            canonicalDate = try HistoricalTimestamp.captured(
                instant: command.startDate,
                timeZoneIdentifier: command.timeZoneIdentifier,
                precision: .minute,
                provenance: .userEntered
            ).localDate
        } catch {
            throw AppWriteFailure.invalidInput
        }
        modelContext.autosaveEnabled = false
        let reservation = try reserveRevision()

        do {
            try modelContext.transaction {
                let profile = try fetchProfile(id: command.recordID)
                if command.expectsExistingRecord && profile == nil {
                    throw AppWriteFailure.staleRecord
                }
                if !command.expectsExistingRecord {
                    var existingDescriptor = FetchDescriptor<HRTProfile>()
                    existingDescriptor.fetchLimit = 1
                    guard try modelContext.fetch(existingDescriptor).isEmpty else {
                        throw AppWriteFailure.staleRecord
                    }
                }
                let changed = profile ?? HRTProfile(
                    id: command.recordID,
                    startDate: command.startDate,
                    createdAt: command.committedAt
                )
                if profile == nil {
                    modelContext.insert(changed)
                } else {
                    changed.startDate = command.startDate
                    if changed.activePeriodStartDate < command.startDate {
                        changed.activePeriodStartDate = command.startDate
                    }
                }

                let canonicalProfiles = try modelContext.fetch(
                    FetchDescriptor<HrtJourneyProfileRecord>()
                )
                guard canonicalProfiles.count <= 1 else {
                    throw AppWriteFailure.staleRecord
                }
                let canonicalProfile: HrtJourneyProfileRecord
                if let existing = canonicalProfiles.first {
                    existing.firstEverStartYear = canonicalDate.year
                    existing.firstEverStartMonth = canonicalDate.month
                    existing.firstEverStartDay = canonicalDate.day
                    canonicalProfile = existing
                } else {
                    canonicalProfile = HrtJourneyProfileRecord(
                        firstEverStartDate: canonicalDate,
                        createdAt: command.committedAt
                    )
                    modelContext.insert(canonicalProfile)
                }

                let openPeriods = try modelContext.fetch(FetchDescriptor<HrtPeriodRecord>())
                    .filter { $0.endDate == nil }
                guard openPeriods.count <= 1 else {
                    throw AppWriteFailure.staleRecord
                }
                let activePeriod: HrtPeriodRecord
                if let existing = openPeriods.first {
                    if let existingStart = existing.startDate, existingStart < canonicalDate {
                        existing.startYear = canonicalDate.year
                        existing.startMonth = canonicalDate.month
                        existing.startDay = canonicalDate.day
                    }
                    activePeriod = existing
                } else {
                    activePeriod = HrtPeriodRecord(
                        id: CoreTimeRegimenBackfill.stableUUID(
                            for: "HrtPeriodRecord:" + command.recordID.uuidString.lowercased()
                        ),
                        startDate: canonicalDate,
                        createdAt: command.committedAt
                    )
                    modelContext.insert(activePeriod)
                }
                try injectFailureIfRequested(failureInjection)
                try upsertRevision(
                    recordType: "HRTProfile",
                    recordID: changed.id,
                    fields: try FactDigestV1.profile(changed),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try upsertRevision(
                    recordType: "HrtJourneyProfileRecord",
                    recordID: CoreTimeRegimenBackfill.stableUUID(
                        for: HrtJourneyProfileRecord.fixedKey
                    ),
                    fields: CoreFactDigestV1.journeyProfile(canonicalProfile),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try upsertRevision(
                    recordType: "HrtPeriodRecord",
                    recordID: activePeriod.id,
                    fields: try CoreFactDigestV1.period(activePeriod),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try markCommitted(at: command.committedAt)
            }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func saveCountdown(_ command: SaveCountdownCommand) throws {
        let cleanTitle = command.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanGentleTitle = command.gentleTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw AppWriteFailure.invalidInput }
        modelContext.autosaveEnabled = false
        let reservation = try reserveRevision()

        do {
            try modelContext.transaction {
                let countdown = try fetchCountdown(id: command.recordID)
                if command.expectsExistingRecord && countdown == nil {
                    throw AppWriteFailure.staleRecord
                }
                if !command.expectsExistingRecord {
                    var activeDescriptor = FetchDescriptor<CountdownRecord>(
                        predicate: #Predicate { $0.archivedAt == nil }
                    )
                    activeDescriptor.fetchLimit = 1
                    guard try modelContext.fetch(activeDescriptor).isEmpty else {
                        throw AppWriteFailure.staleRecord
                    }
                }
                let changed = countdown ?? CountdownRecord(
                    id: command.recordID,
                    title: cleanTitle,
                    gentleTitle: cleanGentleTitle?.isEmpty == false ? cleanGentleTitle : nil,
                    targetDate: command.targetDate,
                    createdAt: command.committedAt
                )
                if countdown == nil {
                    modelContext.insert(changed)
                } else {
                    changed.title = cleanTitle
                    changed.gentleTitle = cleanGentleTitle?.isEmpty == false ? cleanGentleTitle : nil
                    changed.targetDate = command.targetDate
                }
                try upsertRevision(
                    recordType: "CountdownRecord",
                    recordID: changed.id,
                    fields: try FactDigestV1.countdown(changed),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try markCommitted(at: command.committedAt)
            }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func addJourneyEntry(_ command: AddJourneyEntryCommand) throws {
        let cleanText = command.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordID = command.recordID
        guard !cleanText.isEmpty else { throw AppWriteFailure.invalidInput }
        let timestamp: HistoricalTimestamp
        do {
            timestamp = try HistoricalTimestamp.captured(
                instant: command.occurredAt,
                timeZoneIdentifier: command.timeZoneIdentifier,
                provenance: .userEntered
            )
        } catch {
            throw AppWriteFailure.invalidInput
        }
        modelContext.autosaveEnabled = false
        let reservation = try reserveRevision()

        do {
            try modelContext.transaction {
                var duplicateDescriptor = FetchDescriptor<JourneyEntry>(
                    predicate: #Predicate { $0.id == recordID }
                )
                duplicateDescriptor.fetchLimit = 1
                guard try modelContext.fetch(duplicateDescriptor).isEmpty else {
                    throw AppWriteFailure.staleRecord
                }
                let association = try resolvedAssociationForWrite(timestamp: timestamp)
                let entry = JourneyEntry(
                    id: command.recordID,
                    text: cleanText,
                    kind: command.kind,
                    occurredAt: command.occurredAt,
                    createdAt: command.committedAt,
                    regimenVersionID: association.id
                )
                modelContext.insert(entry)
                try upsertRevision(
                    recordType: "JourneyEntry",
                    recordID: entry.id,
                    fields: try FactDigestV1.journey(entry),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try insertHistoricalTimeForWrite(
                    sourceRecordType: "JourneyEntry",
                    sourceRecordID: entry.id,
                    timestamp: timestamp,
                    legacyAssociationID: command.regimenVersionID,
                    resolvedAssociationID: association.id,
                    associationState: association.state,
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try markCommitted(at: command.committedAt)
            }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

#if DEBUG
    func createRegimenVersion(_ command: CreateRegimenVersionCommand) throws {
        let cleanCode = command.code.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = command.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = command.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordID = command.recordID
        guard !cleanCode.isEmpty, !cleanTitle.isEmpty else { throw AppWriteFailure.invalidInput }
        modelContext.autosaveEnabled = false
        let reservation = try reserveRevision()

        do {
            try modelContext.transaction {
                var duplicateDescriptor = FetchDescriptor<RegimenVersion>(
                    predicate: #Predicate { $0.id == recordID }
                )
                duplicateDescriptor.fetchLimit = 1
                guard try modelContext.fetch(duplicateDescriptor).isEmpty else {
                    throw AppWriteFailure.staleRecord
                }
                var activeDescriptor = FetchDescriptor<RegimenVersion>(
                    predicate: #Predicate { $0.endedAt == nil }
                )
                activeDescriptor.fetchLimit = 2
                let activeRegimens = try modelContext.fetch(activeDescriptor)
                let previous: RegimenVersion?
                if let activeID = command.activeRegimenID {
                    guard activeRegimens.count == 1,
                          activeRegimens.first?.id == activeID else {
                        throw AppWriteFailure.staleRecord
                    }
                    previous = activeRegimens.first
                    guard let previous else { throw AppWriteFailure.staleRecord }
                    guard previous.endedAt == nil, command.startedAt >= previous.startedAt else {
                        throw AppWriteFailure.staleRecord
                    }
                    previous.endedAt = command.startedAt
                } else {
                    previous = nil
                    guard activeRegimens.isEmpty else {
                        throw AppWriteFailure.staleRecord
                    }
                }

                let created = RegimenVersion(
                    id: command.recordID,
                    code: cleanCode,
                    title: cleanTitle,
                    startedAt: command.startedAt,
                    note: cleanNote,
                    createdAt: command.committedAt
                )
                modelContext.insert(created)

                if let previous {
                    try upsertRevision(
                        recordType: "RegimenVersion",
                        recordID: previous.id,
                        fields: try FactDigestV1.regimen(previous),
                        reservation: reservation,
                        committedAt: command.committedAt
                    )
                }
                try upsertRevision(
                    recordType: "RegimenVersion",
                    recordID: created.id,
                    fields: try FactDigestV1.regimen(created),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try markCommitted(at: command.committedAt)
            }
        } catch {
            modelContext.rollback()
            throw error
        }
    }
#endif

    @discardableResult
    func saveLabImport(_ command: SaveLabImportCommand) throws -> Int {
        let completedEntries = command.entries.filter(\.isComplete)
        guard !completedEntries.isEmpty else { throw AppWriteFailure.invalidInput }
        let normalizedSampledAt = Self.normalizedInstant(
            command.sampledAt,
            precision: command.precision
        )
        let timestamp: HistoricalTimestamp
        do {
            timestamp = try HistoricalTimestamp.captured(
                instant: normalizedSampledAt,
                timeZoneIdentifier: command.timeZoneIdentifier,
                precision: command.precision,
                provenance: .userEntered
            )
        } catch {
            throw AppWriteFailure.invalidInput
        }
        modelContext.autosaveEnabled = false
        let reservation = try reserveRevision()
        var savedCount = 0

        do {
            try modelContext.transaction {
                let association = try resolvedAssociationForWrite(timestamp: timestamp)

                var changedRecords: [LabRecord] = []
                for entry in completedEntries {
                    guard let numericValue = entry.numericValue else {
                        throw AppWriteFailure.invalidInput
                    }
                    let created = LabRecord(
                        itemName: entry.itemName,
                        itemCode: entry.itemCode,
                        rawValue: entry.cleanRawValue,
                        numericValue: numericValue,
                        unit: entry.cleanUnit,
                        sampledAt: normalizedSampledAt,
                        regimenVersionID: association.id,
                        createdAt: command.committedAt
                    )
                    modelContext.insert(created)
                    changedRecords.append(created)
                }

                for record in changedRecords {
                    try upsertRevision(
                        recordType: "LabRecord",
                        recordID: record.id,
                        fields: try FactDigestV1.lab(record),
                        reservation: reservation,
                        committedAt: command.committedAt
                    )
                    try insertHistoricalTimeForWrite(
                        sourceRecordType: "LabRecord",
                        sourceRecordID: record.id,
                        timestamp: timestamp,
                        legacyAssociationID: command.regimenVersionID,
                        resolvedAssociationID: association.id,
                        associationState: association.state,
                        reservation: reservation,
                        committedAt: command.committedAt
                    )
                }
                try markCommitted(at: command.committedAt)
                savedCount = changedRecords.count
            }
            return savedCount
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private static func normalizedInstant(
        _ instant: Date,
        precision: HistoricalTimestampPrecision
    ) -> Date {
        let quantum: TimeInterval
        switch precision {
        case .minute:
            quantum = 60
        case .second:
            quantum = 1
        case .subsecond:
            return instant
        }
        return Date(
            timeIntervalSinceReferenceDate:
                floor(instant.timeIntervalSinceReferenceDate / quantum) * quantum
        )
    }

    func reserveRevision() throws -> ReservedRevision {
        var reservation: ReservedRevision?
        let singletonKey = DatasetMetadata.fixedKey
        try modelContext.transaction {
            var descriptor = FetchDescriptor<DatasetMetadata>(
                predicate: #Predicate { $0.singletonKey == singletonKey }
            )
            descriptor.fetchLimit = 1
            guard let metadata = try modelContext.fetch(descriptor).first else {
                throw AppWriteFailure.missingFoundation
            }
            guard metadata.nextLocalRevision > 0,
                  metadata.nextLocalRevision < Int64.max else {
                throw AppWriteFailure.revisionExhausted
            }
            reservation = ReservedRevision(
                datasetID: metadata.datasetID,
                localRevision: metadata.nextLocalRevision
            )
            metadata.nextLocalRevision += 1
        }
        guard let reservation else { throw AppWriteFailure.missingFoundation }
        return reservation
    }

    func markCommitted(at date: Date) throws {
        let singletonKey = DatasetMetadata.fixedKey
        var descriptor = FetchDescriptor<DatasetMetadata>(
            predicate: #Predicate { $0.singletonKey == singletonKey }
        )
        descriptor.fetchLimit = 1
        guard let metadata = try modelContext.fetch(descriptor).first else {
            throw AppWriteFailure.missingFoundation
        }
        metadata.lastCommittedAt = date
    }

    func upsertRevision(
        recordType: String,
        recordID: UUID,
        fields: [RecordDigestV1.Field],
        reservation: ReservedRevision,
        committedAt: Date
    ) throws {
        let key = recordType + ":" + recordID.uuidString.lowercased()
        let digest = try RecordDigestV1.sha256Hex(
            recordType: recordType,
            recordID: recordID,
            fields: fields
        )
        var descriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate { $0.recordKey == key }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.datasetID = reservation.datasetID
            existing.localRevision = reservation.localRevision
            existing.digestVersion = RecordDigestV1.version
            existing.digestHex = digest
            existing.committedAt = committedAt
        } else {
            modelContext.insert(
                RecordRevision(
                    recordKey: key,
                    recordType: recordType,
                    recordID: recordID,
                    datasetID: reservation.datasetID,
                    localRevision: reservation.localRevision,
                    digestVersion: RecordDigestV1.version,
                    digestHex: digest,
                    committedAt: committedAt
                )
            )
        }
    }

    private func fetchProfile(id: UUID) throws -> HRTProfile? {
        var descriptor = FetchDescriptor<HRTProfile>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchCountdown(id: UUID) throws -> CountdownRecord? {
        var descriptor = FetchDescriptor<CountdownRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchRegimen(id: UUID) throws -> RegimenVersion? {
        var descriptor = FetchDescriptor<RegimenVersion>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func injectFailureIfRequested(_ failureInjection: AppWriteFailureInjection?) throws {
        if failureInjection == .beforeRevisionCommit {
            throw AppWriteFailure.injected
        }
    }
}

enum FactDigestV1 {
    static func profile(_ model: HRTProfile) throws -> [RecordDigestV1.Field] {
        [
            .init("activePeriodStartDate", try timestamp(model.activePeriodStartDate)),
            .init("createdAt", try timestamp(model.createdAt)),
            .init("startDate", try timestamp(model.startDate))
        ]
    }

    static func countdown(_ model: CountdownRecord) throws -> [RecordDigestV1.Field] {
        [
            .init("archivedAt", try optionalTimestamp(model.archivedAt)),
            .init("continuesCountingUp", .bool(model.continuesCountingUp)),
            .init("createdAt", try timestamp(model.createdAt)),
            .init("gentleTitle", optionalString(model.gentleTitle)),
            .init("targetDate", try timestamp(model.targetDate)),
            .init("title", .string(model.title))
        ]
    }

    static func regimen(_ model: RegimenVersion) throws -> [RecordDigestV1.Field] {
        [
            .init("code", .string(model.code)),
            .init("createdAt", try timestamp(model.createdAt)),
            .init("endedAt", try optionalTimestamp(model.endedAt)),
            .init("note", .string(model.note)),
            .init("startedAt", try timestamp(model.startedAt)),
            .init("title", .string(model.title))
        ]
    }

    static func journey(_ model: JourneyEntry) throws -> [RecordDigestV1.Field] {
        [
            .init("createdAt", try timestamp(model.createdAt)),
            .init("kindRawValue", .string(model.kindRawValue)),
            .init("occurredAt", try timestamp(model.occurredAt)),
            .init("regimenVersionID", optionalUUID(model.regimenVersionID)),
            .init("text", .string(model.text))
        ]
    }

    static func lab(_ model: LabRecord) throws -> [RecordDigestV1.Field] {
        [
            .init("contextNote", .string(model.contextNote)),
            .init("createdAt", try timestamp(model.createdAt)),
            .init("itemCode", .string(model.itemCode)),
            .init("itemName", .string(model.itemName)),
            .init("numericValue", .double(model.numericValue)),
            .init("rawValue", .string(model.rawValue)),
            .init("referenceRangeOriginal", optionalString(model.referenceRangeOriginal)),
            .init("regimenVersionID", optionalUUID(model.regimenVersionID)),
            .init("sampledAt", try timestamp(model.sampledAt)),
            .init("unit", .string(model.unit))
        ]
    }

    static func digest(_ model: HRTProfile) throws -> String {
        try digest(recordType: "HRTProfile", recordID: model.id, fields: profile(model))
    }

    static func digest(_ model: CountdownRecord) throws -> String {
        try digest(recordType: "CountdownRecord", recordID: model.id, fields: countdown(model))
    }

    static func digest(_ model: RegimenVersion) throws -> String {
        try digest(recordType: "RegimenVersion", recordID: model.id, fields: regimen(model))
    }

    static func digest(_ model: JourneyEntry) throws -> String {
        try digest(recordType: "JourneyEntry", recordID: model.id, fields: journey(model))
    }

    static func digest(_ model: LabRecord) throws -> String {
        try digest(recordType: "LabRecord", recordID: model.id, fields: lab(model))
    }

    private static func digest(
        recordType: String,
        recordID: UUID,
        fields: [RecordDigestV1.Field]
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: recordType,
            recordID: recordID,
            fields: fields
        )
    }

    private static func timestamp(_ date: Date) throws -> RecordDigestV1.Value {
        let roundedMicroseconds = (date.timeIntervalSince1970 * 1_000_000).rounded()
        guard roundedMicroseconds.isFinite,
              let microseconds = Int64(exactly: roundedMicroseconds) else {
            throw RecordDigestV1.EncodingError.timestampOutOfRange
        }
        return .timestampMicroseconds(microseconds)
    }

    private static func optionalTimestamp(_ date: Date?) throws -> RecordDigestV1.Value {
        guard let date else { return .null }
        return try timestamp(date)
    }

    private static func optionalString(_ value: String?) -> RecordDigestV1.Value {
        value.map(RecordDigestV1.Value.string) ?? .null
    }

    private static func optionalUUID(_ value: UUID?) -> RecordDigestV1.Value {
        value.map(RecordDigestV1.Value.uuid) ?? .null
    }
}

struct AppDataWriter: Sendable {
    private let storage: AppWriteActor
    private let verifyStoreProtection: @Sendable () async -> Bool
    private let onProtectionFailure: @Sendable () async -> Void

    init(
        storage: AppWriteActor,
        verifyStoreProtection: @escaping @Sendable () async -> Bool,
        onProtectionFailure: @escaping @Sendable () async -> Void
    ) {
        self.storage = storage
        self.verifyStoreProtection = verifyStoreProtection
        self.onProtectionFailure = onProtectionFailure
    }

    func setStartDate(_ command: SetStartDateCommand) async throws {
        try await storage.setStartDate(command)
        await revalidateProtectionAfterCommit()
    }

    func saveCountdown(_ command: SaveCountdownCommand) async throws {
        try await storage.saveCountdown(command)
        await revalidateProtectionAfterCommit()
    }

    func addJourneyEntry(_ command: AddJourneyEntryCommand) async throws {
        try await storage.addJourneyEntry(command)
        await revalidateProtectionAfterCommit()
    }

#if DEBUG
    func createRegimenVersion(_ command: CreateRegimenVersionCommand) async throws {
        try await storage.createRegimenVersion(command)
        await revalidateProtectionAfterCommit()
    }
#endif

    func saveRegimenDraft(_ command: SaveRegimenDraftCommand) async throws {
        try await storage.saveRegimenDraft(command)
        await revalidateProtectionAfterCommit()
    }

    func previewRegimenChange(draftID: UUID) async throws -> RegimenChangePreview {
        try await storage.previewRegimenChange(draftID: draftID)
    }

    func sealRegimenDraft(_ command: SealRegimenDraftCommand) async throws {
        try await storage.sealRegimenDraft(command)
        await revalidateProtectionAfterCommit()
    }

    func saveLabImport(_ command: SaveLabImportCommand) async throws -> Int {
        let count = try await storage.saveLabImport(command)
        await revalidateProtectionAfterCommit()
        return count
    }

    private func revalidateProtectionAfterCommit() async {
        guard await verifyStoreProtection() else {
            await onProtectionFailure()
            return
        }
    }
}

private struct AppDataWriterEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppDataWriter? = nil
}

extension EnvironmentValues {
    var appDataWriter: AppDataWriter? {
        get { self[AppDataWriterEnvironmentKey.self] }
        set { self[AppDataWriterEnvironmentKey.self] = newValue }
    }
}
