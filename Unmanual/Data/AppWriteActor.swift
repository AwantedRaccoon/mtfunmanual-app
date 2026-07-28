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

struct SetGentleModeCommand: Sendable {
    let isEnabled: Bool
    let committedAt: Date

    init(isEnabled: Bool, committedAt: Date = Date()) {
        self.isEnabled = isEnabled
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
    let attachments: [PreparedAttachmentMetadata]

    init(
        recordID: UUID = UUID(),
        text: String,
        kind: JourneyEntryKind,
        occurredAt: Date,
        regimenVersionID: UUID?,
        timeZoneIdentifier: String = TimeZone.autoupdatingCurrent.identifier,
        committedAt: Date = Date(),
        attachments: [PreparedAttachmentMetadata] = []
    ) {
        self.recordID = recordID
        self.text = text
        self.kind = kind
        self.occurredAt = occurredAt
        self.regimenVersionID = regimenVersionID
        self.timeZoneIdentifier = timeZoneIdentifier
        self.committedAt = committedAt
        self.attachments = attachments
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
        guard !modelContext.container.schema.entities.contains(where: {
            $0.name == "HrtJourneyLifecycleEventRecord"
        }) else {
            throw AppWriteFailure.invalidInput
        }
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
        let reservation = try reserveRevision(committedAt: command.committedAt)

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

    func setGentleMode(_ command: SetGentleModeCommand) throws {
        modelContext.autosaveEnabled = false
        let reservation = try reserveRevision(
            committedAt: command.committedAt
        )
        do {
            try modelContext.transaction {
                var descriptor =
                    FetchDescriptor<UserPreferencesRecord>()
                descriptor.fetchLimit = 2
                let preferences = try modelContext.fetch(descriptor)
                guard preferences.count == 1,
                      let preference = preferences.first else {
                    throw AppWriteFailure.missingFoundation
                }
                preference.gentleModeEnabled = command.isEnabled
                try upsertRevision(
                    recordType: "UserPreferencesRecord",
                    recordID: CoreTimeRegimenBackfill.stableUUID(
                        for: preference.singletonKey
                    ),
                    fields: CoreFactDigestV1.preferences(preference),
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
        let reservation = try reserveRevision(committedAt: command.committedAt)

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
        try ensureDataControlJourneyEntryIsWritable(
            command.recordID
        )
        let cleanText = command.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordID = command.recordID
        guard !cleanText.isEmpty else { throw AppWriteFailure.invalidInput }
        let attachments = try normalizedJourneyAttachments(command.attachments)
        try validateJourneyAttachmentIDs(attachments)
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
        let reservation = try reserveRevision(committedAt: command.committedAt)

        do {
            try modelContext.transaction {
                try ensureDataControlJourneyEntryIsWritable(
                    recordID
                )
                var duplicateDescriptor = FetchDescriptor<JourneyEntry>(
                    predicate: #Predicate { $0.id == recordID }
                )
                duplicateDescriptor.fetchLimit = 1
                guard try modelContext.fetch(duplicateDescriptor).isEmpty else {
                    throw AppWriteFailure.staleRecord
                }
                try validateJourneyAttachmentIDs(attachments)
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
                for input in attachments {
                    let attachment = AttachmentRecord(
                        id: input.attachmentID,
                        ownerType: .journeyEntry,
                        ownerID: entry.id,
                        relativePath: input.relativePath,
                        originalFilename: input.filename,
                        typeIdentifier: input.typeIdentifier,
                        byteCount: input.byteCount,
                        sha256Hex: input.sha256Hex,
                        operationID: input.operationID,
                        createdAt: command.committedAt
                    )
                    modelContext.insert(attachment)
                    try upsertRevision(
                        recordType: "AttachmentRecord",
                        recordID: attachment.id,
                        fields: try AttachmentDigestV1.record(attachment),
                        reservation: reservation,
                        committedAt: command.committedAt
                    )
                    let attachmentCommand = AddAttachmentMetadataCommand(
                        operationID: input.operationID,
                        attachmentID: input.attachmentID,
                        ownerType: .journeyEntry,
                        ownerID: entry.id,
                        relativePath: input.relativePath,
                        originalFilename: input.filename,
                        typeIdentifier: input.typeIdentifier,
                        byteCount: input.byteCount,
                        sha256Hex: input.sha256Hex,
                        committedAt: command.committedAt
                    )
                    try insertOperationReceipt(
                        OperationReceiptRecord(
                            operationID: input.operationID,
                            commandDigest: try AttachmentDigestV1.command(
                                attachmentCommand
                            ),
                            resultRecordType: "AttachmentRecord",
                            resultRecordID: attachment.id,
                            committedAt: command.committedAt
                        ),
                        reservation: reservation
                    )
                }
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

    private func normalizedJourneyAttachments(
        _ attachments: [PreparedAttachmentMetadata]
    ) throws -> [NormalizedPreparedAttachment] {
        guard attachments.count <= AttachmentFileStore.maximumOwnerFiles,
              Set(attachments.map(\.attachmentID)).count == attachments.count,
              Set(attachments.map(\.operationID)).count == attachments.count,
              Set(attachments.map(\.relativePath)).count == attachments.count else {
            throw PersonalTimelineWriteFailure.invalidInput
        }
        let normalized = try attachments.map(AttachmentMetadataFacts.normalize)
        let total = normalized.reduce(Int64(0)) { partial, attachment in
            let addition = partial.addingReportingOverflow(attachment.byteCount)
            return addition.overflow ? Int64.max : addition.partialValue
        }
        guard total <= AttachmentFileStore.maximumOwnerBytes else {
            throw PersonalTimelineWriteFailure.attachmentLimitReached
        }
        return normalized
    }

    private func validateJourneyAttachmentIDs(
        _ attachments: [NormalizedPreparedAttachment]
    ) throws {
        for attachment in attachments {
            let attachmentID = attachment.attachmentID
            var idDescriptor = FetchDescriptor<AttachmentRecord>(
                predicate: #Predicate { $0.id == attachmentID }
            )
            idDescriptor.fetchLimit = 1
            guard try modelContext.fetch(idDescriptor).isEmpty else {
                throw AppWriteFailure.staleRecord
            }

            let relativePath = attachment.relativePath
            var pathDescriptor = FetchDescriptor<AttachmentRecord>(
                predicate: #Predicate { $0.relativePath == relativePath }
            )
            pathDescriptor.fetchLimit = 1
            guard try modelContext.fetch(pathDescriptor).isEmpty else {
                throw AppWriteFailure.staleRecord
            }

            let operationID = attachment.operationID
            var receiptDescriptor = FetchDescriptor<OperationReceiptRecord>(
                predicate: #Predicate { $0.operationID == operationID }
            )
            receiptDescriptor.fetchLimit = 1
            guard try modelContext.fetch(receiptDescriptor).isEmpty else {
                throw PersonalTimelineWriteFailure.operationConflict
            }
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
        let reservation = try reserveRevision(committedAt: command.committedAt)

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
        if modelContext.container.schema.entities.contains(where: {
            $0.name == "LabSampleRecord"
        }) {
            return try saveCanonicalLabImport(command)
        }

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
        let reservation = try reserveRevision(committedAt: command.committedAt)
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

    private func saveCanonicalLabImport(
        _ command: SaveLabImportCommand
    ) throws -> Int {
        let completedEntries = command.entries.filter(\.isComplete)
        guard !completedEntries.isEmpty,
              completedEntries.allSatisfy({
                  !$0.itemName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
              }) else {
            throw AppWriteFailure.invalidInput
        }
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

        let definitions = completedEntries.map {
            LabItemDefinitionInput(
                id: UUID(),
                displayName: $0.itemName,
                code: $0.itemCode
            )
        }
        let results = zip(completedEntries, definitions).map {
            LabResultInput(
                itemDefinitionID: $0.1.id,
                rawValueOriginal: $0.0.rawValue,
                unitOriginal: $0.0.unit
            )
        }
        _ = try createLabSample(
            CreateLabSampleCommand(
                operationID: UUID(),
                timestamp: timestamp,
                newDefinitions: definitions,
                results: results,
                committedAt: command.committedAt
            )
        )
        return completedEntries.count
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

    func reserveRevision(committedAt: Date) throws -> ReservedRevision {
        var reservation: ReservedRevision?
        try modelContext.transaction {
            reservation = try reserveRevisionInCurrentTransaction(
                committedAt: committedAt
            )
        }
        guard let reservation else { throw AppWriteFailure.missingFoundation }
        return reservation
    }

    func reserveRevisionInCurrentTransaction(
        committedAt: Date
    ) throws -> ReservedRevision {
        _ = try RecordDigestV1.timestampMicroseconds(committedAt)
        let singletonKey = DatasetMetadata.fixedKey
        var descriptor = FetchDescriptor<DatasetMetadata>(
            predicate: #Predicate { $0.singletonKey == singletonKey }
        )
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count == 1,
              let metadata = records.first else {
            throw AppWriteFailure.missingFoundation
        }
        guard metadata.nextLocalRevision > 0,
              metadata.nextLocalRevision < Int64.max else {
            throw AppWriteFailure.revisionExhausted
        }
        let reservation = ReservedRevision(
            datasetID: metadata.datasetID,
            localRevision: metadata.nextLocalRevision
        )
        metadata.nextLocalRevision += 1
        return reservation
    }

    func markCommitted(at date: Date) throws {
        _ = try RecordDigestV1.timestampMicroseconds(date)
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
        _ = try RecordDigestV1.timestampMicroseconds(committedAt)
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
        try RecordDigestV1.timestampValue(date)
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
    private let dataControlCoordinator: AppDataControlCoordinator
    private let sessionReleaseProbe:
        AppDataSessionReleaseProbe?
    private let verifyStoreProtection: @Sendable () async -> Bool
    private let onProtectionFailure: @Sendable () async -> Void
    private let onReminderInputsChanged:
        @Sendable (ReminderCoverageInvalidationResult) async -> Void

    init(
        storage: AppWriteActor,
        dataControlCoordinator: AppDataControlCoordinator =
            AppDataControlCoordinator(generationID: UUID()),
        verifyStoreProtection: @escaping @Sendable () async -> Bool,
        onProtectionFailure: @escaping @Sendable () async -> Void,
        sessionReleaseProbe:
            AppDataSessionReleaseProbe? = nil,
        onReminderInputsChanged:
            @escaping @Sendable (ReminderCoverageInvalidationResult) async -> Void = { _ in }
    ) {
        self.storage = storage
        self.dataControlCoordinator = dataControlCoordinator
        self.sessionReleaseProbe = sessionReleaseProbe
        self.verifyStoreProtection = verifyStoreProtection
        self.onProtectionFailure = onProtectionFailure
        self.onReminderInputsChanged = onReminderInputsChanged
    }

    func setStartDate(_ command: SetStartDateCommand) async throws {
        try await withMutationLease {
            try await storage.setStartDate(command)
            await revalidateProtectionAfterCommit()
        }
    }

    func createHrtJourney(
        _ command: CreateHrtJourneyCommand
    ) async throws -> HrtJourneyMutationResult {
        try await withMutationLease {
            try await storage
                .ensureDataControlHrtJourneyIsWritable()
            let result = try await storage.createHrtJourney(command)
            if result.didApply {
                await revalidateProtectionAfterCommit()
            }
            return result
        }
    }

    func correctHrtJourneyFirstStart(
        _ command: CorrectHrtJourneyFirstStartCommand
    ) async throws -> HrtJourneyMutationResult {
        try await withMutationLease {
            try await storage
                .ensureDataControlHrtJourneyIsWritable()
            let result = try await storage
                .correctHrtJourneyFirstStart(command)
            if result.didApply {
                await revalidateProtectionAfterCommit()
            }
            return result
        }
    }

    func pauseHrtJourney(
        _ command: PauseHrtJourneyCommand
    ) async throws -> HrtJourneyMutationResult {
        try await withMutationLease {
            try await storage
                .ensureDataControlHrtJourneyIsWritable()
            let result = try await storage.pauseHrtJourney(command)
            if result.didApply {
                await revalidateProtectionAfterCommit()
            }
            return result
        }
    }

    func resumeHrtJourney(
        _ command: ResumeHrtJourneyCommand
    ) async throws -> HrtJourneyMutationResult {
        try await withMutationLease {
            try await storage
                .ensureDataControlHrtJourneyIsWritable()
            let result = try await storage.resumeHrtJourney(command)
            if result.didApply {
                await revalidateProtectionAfterCommit()
            }
            return result
        }
    }

    func setGentleMode(_ command: SetGentleModeCommand) async throws {
        try await withMutationLease {
            try await storage.setGentleMode(command)
            await revalidateProtectionAfterCommit()
        }
    }

    func setAppLock(
        _ command: SetAppLockCommand
    ) async throws -> SetAppLockResult {
        try await withMutationLease {
            let result = try await storage.setAppLock(command)
            if result.didApply {
                await revalidateProtectionAfterCommit()
            }
            return result
        }
    }

    func updateOnboardingProgress(
        _ command: UpdateOnboardingProgressCommand
    ) async throws -> OnboardingProgressResult {
        try await withMutationLease {
            let result = try await storage.updateOnboardingProgress(
                command
            )
            if result.didApply {
                await revalidateProtectionAfterCommit()
            }
            return result
        }
    }

    func completeOnboarding(
        _ command: CompleteOnboardingCommand
    ) async throws -> CompleteOnboardingResult {
        try await withMutationLease {
            let result = try await storage.completeOnboarding(command)
            if result.didApply {
                await revalidateProtectionAfterCommit()
            }
            return result
        }
    }

    func saveCountdown(_ command: SaveCountdownCommand) async throws {
        try await withMutationLease {
            try await storage.saveCountdown(command)
            await revalidateProtectionAfterCommit()
        }
    }

    func createCountdown(
        _ command: CreateCountdownCommand
    ) async throws -> CountdownMutationResult {
        try await withMutationLease {
            let result = try await storage.createCountdown(command)
            if result.didApply {
                await countdownReminderInputsDidChange(
                    at: command.committedAt,
                    countdownID: result.countdownID
                )
            }
            return result
        }
    }

    func updateCountdown(
        _ command: UpdateCountdownCommand
    ) async throws -> CountdownMutationResult {
        try await withMutationLease {
            let result = try await storage.updateCountdown(command)
            if result.didApply {
                await countdownReminderInputsDidChange(
                    at: command.committedAt,
                    countdownID: result.countdownID
                )
            }
            return result
        }
    }

    func resolveCountdownReview(
        _ command: ResolveCountdownReviewCommand
    ) async throws -> CountdownMutationResult {
        try await withMutationLease {
            let result = try await storage.resolveCountdownReview(
                command
            )
            if result.didApply {
                await countdownReminderInputsDidChange(
                    at: command.committedAt,
                    countdownID:
                        command.resolution == .keepAsCurrent
                            ? result.countdownID
                            : nil
                )
            }
            return result
        }
    }

    func continueCountdown(
        _ command: ContinueCountdownCommand
    ) async throws -> CountdownMutationResult {
        try await withMutationLease {
            let result = try await storage.continueCountdown(command)
            if result.didApply {
                await countdownReminderInputsDidChange(
                    at: command.committedAt,
                    countdownID: result.countdownID
                )
            }
            return result
        }
    }

    func completeCountdown(
        _ command: CompleteCountdownCommand
    ) async throws -> CountdownMutationResult {
        try await withMutationLease {
            let result = try await storage.completeCountdown(command)
            if result.didApply {
                await countdownReminderInputsDidChange(
                    at: command.committedAt,
                    countdownID: nil
                )
            }
            return result
        }
    }

    func archiveCountdown(
        _ command: ArchiveCountdownCommand
    ) async throws -> CountdownMutationResult {
        try await withMutationLease {
            let result = try await storage.archiveCountdown(command)
            if result.didApply {
                await countdownReminderInputsDidChange(
                    at: command.committedAt,
                    countdownID: nil
                )
            }
            return result
        }
    }

    func deleteCountdown(
        _ command: DeleteCountdownCommand
    ) async throws -> CountdownMutationResult {
        try await withMutationLease {
            let result = try await storage.deleteCountdown(command)
            if result.didApply {
                await countdownReminderInputsDidChange(
                    at: command.committedAt,
                    countdownID: nil
                )
            }
            return result
        }
    }

    func replaceCountdown(
        _ command: ReplaceCountdownCommand
    ) async throws -> CountdownMutationResult {
        try await withMutationLease {
            let result = try await storage.replaceCountdown(command)
            if result.didApply {
                await countdownReminderInputsDidChange(
                    at: command.committedAt,
                    countdownID: result.countdownID
                )
            }
            return result
        }
    }

    func addJourneyEntry(_ command: AddJourneyEntryCommand) async throws {
        try await withMutationLease {
            try await storage.ensureDataControlJourneyEntryIsWritable(
                command.recordID
            )
            try await storage.addJourneyEntry(command)
            await revalidateProtectionAfterCommit()
        }
    }

#if DEBUG
    func createRegimenVersion(_ command: CreateRegimenVersionCommand) async throws {
        try await withMutationLease {
            try await storage.createRegimenVersion(command)
            await revalidateProtectionAfterCommit()
        }
    }
#endif

    func saveRegimenDraft(_ command: SaveRegimenDraftCommand) async throws {
        try await withMutationLease {
            try await storage
                .ensureDataControlRegimenLineageIsWritable(
                    recordID: command.recordID
                )
            try await storage.saveRegimenDraft(command)
            await revalidateProtectionAfterCommit()
        }
    }

    func previewRegimenChange(draftID: UUID) async throws -> RegimenChangePreview {
        try await dataControlCoordinator.withReadLease {
            try await storage
                .ensureDataControlRegimenVersionIsWritable(draftID)
            return try await storage.previewRegimenChange(
                draftID: draftID
            )
        }
    }

    func sealRegimenDraft(_ command: SealRegimenDraftCommand) async throws {
        try await withMutationLease {
            try await storage
                .ensureDataControlRegimenVersionIsWritable(
                    command.draftID
                )
            try await storage.sealRegimenDraft(command)
            let didInvalidateCoverage =
                await invalidateReminderCoverage(
                    at: command.committedAt
                )
            await onReminderInputsChanged(
                .schedule(
                    coverageWasInvalidated: didInvalidateCoverage
                )
            )
            await revalidateProtectionAfterCommit()
        }
    }

    func saveLabImport(_ command: SaveLabImportCommand) async throws -> Int {
        try await withMutationLease {
            let count = try await storage.saveLabImport(command)
            await revalidateProtectionAfterCommit()
            return count
        }
    }

    func createLabSample(
        _ command: CreateLabSampleCommand
    ) async throws -> LabSampleCommitResult {
        try await withMutationLease {
            let result = try await storage.createLabSample(command)
            if result.didCreate {
                await revalidateProtectionAfterCommit()
            }
            return result
        }
    }

    func createStatusMetric(
        _ command: CreateStatusMetricCommand
    ) async throws -> StatusMetricCommitResult {
        try await withMutationLease {
            let result = try await storage.createStatusMetric(command)
            if result.didCreate {
                await revalidateProtectionAfterCommit()
            }
            return result
        }
    }

    func recordStatusObservation(
        _ command: RecordStatusObservationCommand
    ) async throws -> StatusObservationCommitResult {
        try await withMutationLease {
            let result = try await storage
                .recordStatusObservation(command)
            if result.didCreate {
                await revalidateProtectionAfterCommit()
            }
            return result
        }
    }

    func correctLabSample(
        _ command: CorrectLabSampleCommand
    ) async throws -> ParentRecordMutationResult {
        try await withMutationLease {
            let result = try await storage.correctLabSample(command)
            if result.didApply {
                await revalidateProtectionAfterCommit()
            }
            return result
        }
    }

    func correctStatusObservation(
        _ command: CorrectStatusObservationCommand
    ) async throws -> ParentRecordMutationResult {
        try await withMutationLease {
            let result = try await storage.correctStatusObservation(
                command
            )
            if result.didApply {
                await revalidateProtectionAfterCommit()
            }
            return result
        }
    }

    func deleteParentRecord(
        _ command: DeleteParentRecordCommand,
        failureInjection: AppWriteFailureInjection? = nil
    ) async throws -> ParentRecordMutationResult {
        try await withMutationLease {
            let result = try await storage.deleteParentRecord(
                command,
                failureInjection: failureInjection
            )
            if result.didApply {
                await revalidateProtectionAfterCommit()
            }
            return result
        }
    }

    func validateParentRecordDeletionImpact(
        _ impact: ParentRecordDeletionImpact
    ) async throws {
        try await dataControlCoordinator.withReadLease {
            try await storage.validateParentRecordDeletionImpact(impact)
        }
    }

    func archiveStatusMetric(
        _ command: ArchiveStatusMetricCommand
    ) async throws -> StatusMetricArchiveResult {
        try await withMutationLease {
            let result = try await storage.archiveStatusMetric(command)
            if result.didArchive {
                await revalidateProtectionAfterCommit()
            }
            return result
        }
    }

    func addAttachmentMetadata(
        _ command: AddAttachmentMetadataCommand
    ) async throws -> AttachmentCommitResult {
        try await withMutationLease {
            try await storage
                .ensureDataControlAttachmentOwnerIsWritable(
                    ownerType: command.ownerType,
                    ownerID: command.ownerID
                )
            let result = try await storage.addAttachmentMetadata(
                command
            )
            if result.didCreate {
                await revalidateProtectionAfterCommit()
            }
            return result
        }
    }

    func deleteAttachment(
        _ command: DeleteAttachmentCommand
    ) async throws -> AttachmentDeletionResult {
        try await withMutationLease {
            try await storage.ensureDataControlAttachmentIsWritable(
                command.attachmentID
            )
            let result = try await storage.deleteAttachment(command)
            if result.didDelete {
                await revalidateProtectionAfterCommit()
            }
            return result
        }
    }

    func commitAdministration(
        _ command: CommitAdministrationCommand
    ) async throws -> AdministrationCommitResult {
        try await withMutationLease {
            try await storage.ensureDataControlOccurrenceIsWritable(
                command.occurrence
            )
            let result = try await storage.commitAdministration(
                command
            )
            if result.didCreate {
                let didInvalidateCoverage =
                    await invalidateReminderCoverage(
                        at: command.committedAt
                    )
                await onReminderInputsChanged(
                    .schedule(
                        coverageWasInvalidated:
                            didInvalidateCoverage
                    )
                )
                await revalidateProtectionAfterCommit()
            }
            return result
        }
    }

    func setReminderPreference(
        _ command: SetReminderPreferenceCommand
    ) async throws -> ReminderPreferenceResult {
        try await withMutationLease {
            try await storage.ensureDataControlScheduleRuleIsWritable(
                command.scheduleRuleID
            )
            let result = try await storage.setReminderPreference(
                command
            )
            if result.didApply {
                let didInvalidateCoverage =
                    await invalidateReminderCoverage(
                        at: command.committedAt
                    )
                await onReminderInputsChanged(
                    .schedule(
                        coverageWasInvalidated:
                            didInvalidateCoverage
                    )
                )
                await revalidateProtectionAfterCommit()
            }
            return result
        }
    }

    func applyReminderOverride(
        _ command: ApplyReminderOverrideCommand
    ) async throws -> ReminderOverrideResult {
        try await withMutationLease {
            try await storage.ensureDataControlOccurrenceIsWritable(
                command.occurrence
            )
            let result = try await storage.applyReminderOverride(
                command
            )
            if result.didCreate {
                let didInvalidateCoverage =
                    await invalidateReminderCoverage(
                        at: command.committedAt
                    )
                await onReminderInputsChanged(
                    .schedule(
                        coverageWasInvalidated:
                            didInvalidateCoverage
                    )
                )
                await revalidateProtectionAfterCommit()
            }
            return result
        }
    }

    func updateNotificationCoverage(
        _ observation: LocalReminderReconciliationObservation
    ) async throws {
        try await withMutationLease {
            try await storage.updateNotificationCoverage(observation)
            await revalidateProtectionAfterCommit()
        }
    }

    func updateUnifiedNotificationCoverage(
        _ observation: LocalReminderReconciliationObservation
    ) async throws {
        try await withMutationLease {
            try await storage.updateUnifiedNotificationCoverage(
                observation
            )
            await revalidateProtectionAfterCommit()
        }
    }

    func dataControlDeletionPlan(
        _ request: DataControlDeletionPlanRequest
    ) async throws -> DataControlDeletionPlan {
        try await dataControlCoordinator.withReadLease {
            try await storage.dataControlDeletionPlan(request)
        }
    }

    func commitDataControlDeletion(
        impact: DeletionImpact,
        command: DeleteDataControlTargetCommand,
        activeGenerationID: UUID
    ) async throws -> DataControlDeletionWriteResult {
        try await withMutationLease {
            let result = try await storage.commitDataControlDeletion(
                impact: impact,
                command: command,
                activeGenerationID: activeGenerationID
            )
            await revalidateProtectionAfterCommit()
            return result
        }
    }

    func replayCommittedDataControlDeletion(
        impact: DeletionImpact,
        command: DeleteDataControlTargetCommand,
        activeGenerationID: UUID
    ) async throws -> DataControlDeletionWriteResult? {
        try await dataControlCoordinator.withReadLease {
            try await storage
                .replayCommittedDataControlDeletion(
                    impact: impact,
                    command: command,
                    activeGenerationID:
                        activeGenerationID
                )
        }
    }

    func dataControlAttachmentRecoveryEvidence()
        async throws
        -> DataControlAttachmentRecoveryEvidence {
        try await dataControlCoordinator.withReadLease {
            try await storage
                .dataControlAttachmentRecoveryEvidence()
        }
    }

    func dataControlTerminalOverlay()
        async throws -> DataControlTerminalOverlay {
        try await dataControlCoordinator.withReadLease {
            try await storage.dataControlTerminalOverlay()
        }
    }

    private func revalidateProtectionAfterCommit() async {
        guard await verifyStoreProtection() else {
            await onProtectionFailure()
            return
        }
    }

    private func withMutationLease<Output: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        try await dataControlCoordinator.withMutationLease(operation)
    }

    private func invalidateReminderCoverage(at observedAt: Date) async -> Bool {
        do {
            try await storage.updateNotificationCoverage(
                LocalReminderReconciliationObservation(
                    status: .reconciliationPending,
                    scheduledThrough: nil,
                    desiredCount: 0,
                    confirmedPendingCount: 0,
                    lastErrorCode: nil,
                    observedAt: observedAt
                )
            )
            return true
        } catch {
            return false
        }
    }

    private func countdownReminderInputsDidChange(
        at observedAt: Date,
        countdownID: UUID?
    ) async {
        let didInvalidateCoverage = await invalidateCountdownReminderCoverage(
            at: observedAt,
            countdownID: countdownID
        )
        await onReminderInputsChanged(
            .countdown(coverageWasInvalidated: didInvalidateCoverage)
        )
        await revalidateProtectionAfterCommit()
    }

    private func invalidateCountdownReminderCoverage(
        at observedAt: Date,
        countdownID: UUID?
    ) async -> Bool {
        do {
            try await storage.updateCountdownNotificationCoverage(
                LocalReminderReconciliationObservation(
                    status: .disabledByUser,
                    scheduledThrough: nil,
                    desiredCount: 0,
                    confirmedPendingCount: 0,
                    lastErrorCode: nil,
                    observedAt: observedAt,
                    countdownStatus: .reconciliationPending,
                    countdownID: countdownID
                )
            )
            return true
        } catch {
            return false
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
