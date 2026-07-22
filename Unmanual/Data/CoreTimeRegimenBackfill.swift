import Foundation
import SwiftData

enum CoreTimeRegimenBackfill {
    struct Outcome: Equatable, Sendable {
        let didComplete: Bool
        let didChangeStore: Bool
    }

    static func run(
        in container: ModelContainer,
        assumedTimeZoneIdentifier: String = TimeZone.current.identifier,
        now: Date = Date()
    ) throws -> Outcome {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var states = try context.fetch(FetchDescriptor<CoreTimeRegimenBackfillState>())
        guard states.count <= 1 else { throw AppDataFailure.migrationFailed }
        if let completed = states.first, completed.completedAt != nil {
            return Outcome(didComplete: true, didChangeStore: false)
        }
        let effectiveTimeZoneIdentifier = states.first?.assumedTimeZoneIdentifier
            ?? assumedTimeZoneIdentifier
        guard TimeZone(identifier: effectiveTimeZoneIdentifier) != nil else {
            throw AppDataFailure.migrationFailed
        }

        let state: CoreTimeRegimenBackfillState
        if let existing = states.first {
            state = existing
        } else {
            state = CoreTimeRegimenBackfillState(
                assumedTimeZoneIdentifier: effectiveTimeZoneIdentifier,
                updatedAt: now
            )
            context.insert(state)
            states = [state]
        }

        do {
            try context.transaction {
                let preferences = try ensurePreferences(in: context, now: now)
                let journeyFacts = try backfillJourneyFacts(
                    in: context,
                    timeZoneIdentifier: effectiveTimeZoneIdentifier
                )
                let versions = try backfillRegimens(
                    in: context,
                    timeZoneIdentifier: effectiveTimeZoneIdentifier
                )
                let historicalTimes = try backfillHistoricalTimes(
                    in: context,
                    timeZoneIdentifier: effectiveTimeZoneIdentifier,
                    versions: versions,
                    now: now
                )
                try ensureRevisions(
                    preferences: preferences,
                    journeyFacts: journeyFacts,
                    versions: versions,
                    historicalTimes: historicalTimes,
                    in: context,
                    now: now
                )
                state.updatedAt = now
                state.completedAt = now
            }
            return Outcome(didComplete: true, didChangeStore: true)
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func ensurePreferences(
        in context: ModelContext,
        now: Date
    ) throws -> UserPreferencesRecord {
        let existing = try context.fetch(FetchDescriptor<UserPreferencesRecord>())
        guard existing.count <= 1 else { throw AppDataFailure.migrationFailed }
        if let first = existing.first { return first }
        let created = UserPreferencesRecord(createdAt: now)
        context.insert(created)
        return created
    }

    private struct JourneyFacts {
        let profile: HrtJourneyProfileRecord?
        let periods: [HrtPeriodRecord]
    }

    private static func backfillJourneyFacts(
        in context: ModelContext,
        timeZoneIdentifier: String
    ) throws -> JourneyFacts {
        let existingProfiles = try context.fetch(FetchDescriptor<HrtJourneyProfileRecord>())
        let existingPeriods = try context.fetch(FetchDescriptor<HrtPeriodRecord>())
        guard existingProfiles.count <= 1 else { throw AppDataFailure.migrationFailed }
        if let profile = existingProfiles.first {
            return JourneyFacts(profile: profile, periods: existingPeriods)
        }
        var descriptor = FetchDescriptor<HRTProfile>(sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = 2
        let legacyProfiles = try context.fetch(descriptor)
        guard legacyProfiles.count <= 1, let legacy = legacyProfiles.first else {
            return JourneyFacts(profile: nil, periods: existingPeriods)
        }
        let firstDate = try civilDate(from: legacy.startDate, timeZoneIdentifier: timeZoneIdentifier)
        let activeDate = try civilDate(
            from: legacy.activePeriodStartDate,
            timeZoneIdentifier: timeZoneIdentifier
        )
        let profile = HrtJourneyProfileRecord(
            firstEverStartDate: firstDate,
            createdAt: legacy.createdAt
        )
        let period = HrtPeriodRecord(startDate: activeDate, createdAt: legacy.createdAt)
        context.insert(profile)
        context.insert(period)
        return JourneyFacts(profile: profile, periods: existingPeriods + [period])
    }

    private static func backfillRegimens(
        in context: ModelContext,
        timeZoneIdentifier: String
    ) throws -> [RegimenPlanVersionRecord] {
        var canonical = try context.fetch(FetchDescriptor<RegimenPlanVersionRecord>())
        let existingIDs = Set(canonical.map(\.id))
        let legacy = try context.fetch(
            FetchDescriptor<RegimenVersion>(
                sortBy: [SortDescriptor(\.startedAt), SortDescriptor(\.id)]
            )
        )
        for source in legacy where !existingIDs.contains(source.id) {
            let created = RegimenPlanVersionRecord(
                id: source.id,
                code: source.code,
                title: source.title,
                effectiveStartDate: try civilDate(
                    from: source.startedAt,
                    timeZoneIdentifier: timeZoneIdentifier
                ),
                effectiveEndDate: try source.endedAt.map {
                    try civilDate(from: $0, timeZoneIdentifier: timeZoneIdentifier)
                },
                previousVersionID: nil,
                changeReason: source.note,
                editState: .sealed,
                legacySourceID: source.id,
                createdAt: source.createdAt
            )
            context.insert(created)
            canonical.append(created)
        }
        canonical.sort {
            let lhs = $0.effectiveStartDate
            let rhs = $1.effectiveStartDate
            if lhs != rhs { return (lhs?.iso8601 ?? "") < (rhs?.iso8601 ?? "") }
            return $0.id.uuidString < $1.id.uuidString
        }
        for index in canonical.indices where canonical[index].legacySourceID != nil {
            canonical[index].previousVersionID = index == canonical.startIndex
                ? nil
                : canonical[canonical.index(before: index)].id
        }
        for index in canonical.indices.dropFirst() {
            let prior = canonical[index - 1]
            let current = canonical[index]
            guard let priorStart = prior.effectiveStartDate,
                  let currentStart = current.effectiveStartDate else {
                prior.requiresMigrationReview = true
                current.requiresMigrationReview = true
                continue
            }
            let hasInvalidOrder = !(priorStart < currentStart)
            let explicitlyOverlaps = prior.effectiveEndDate.map { currentStart < $0 } ?? false
            if hasInvalidOrder || explicitlyOverlaps {
                prior.requiresMigrationReview = true
                current.requiresMigrationReview = true
                try insertIssueIfNeeded(
                    kind: .overlappingCanonicalRegimen,
                    recordType: "RegimenPlanVersionRecord",
                    recordID: current.id,
                    in: context,
                    now: current.createdAt
                )
            }
        }
        return canonical
    }

    private static func backfillHistoricalTimes(
        in context: ModelContext,
        timeZoneIdentifier: String,
        versions: [RegimenPlanVersionRecord],
        now: Date
    ) throws -> [HistoricalTimeRecord] {
        var records = try context.fetch(FetchDescriptor<HistoricalTimeRecord>())
        var keys = Set(records.map(\.recordKey))
        let timeline = versions.compactMap { version -> RegimenTimelineVersion? in
            guard let start = version.effectiveStartDate else { return nil }
            return RegimenTimelineVersion(
                id: version.id,
                start: start,
                end: version.effectiveEndDate,
                editState: version.editState,
                requiresReview: version.requiresMigrationReview
            )
        }

        let journeys = try context.fetch(FetchDescriptor<JourneyEntry>())
        for source in journeys {
            let key = "JourneyEntry:" + source.id.uuidString.lowercased()
            guard !keys.contains(key) else { continue }
            let timestamp = try HistoricalTimestamp.legacyAssumed(
                instant: source.occurredAt,
                assumedTimeZoneIdentifier: timeZoneIdentifier
            )
            let record = try makeHistoricalRecord(
                sourceRecordType: "JourneyEntry",
                sourceRecordID: source.id,
                timestamp: timestamp,
                legacyAssociationID: source.regimenVersionID,
                timeline: timeline,
                in: context,
                now: now
            )
            context.insert(record)
            records.append(record)
            keys.insert(key)
        }

        let labs = try context.fetch(FetchDescriptor<LabRecord>())
        for source in labs {
            let key = "LabRecord:" + source.id.uuidString.lowercased()
            guard !keys.contains(key) else { continue }
            let timestamp = try HistoricalTimestamp.legacyAssumed(
                instant: source.sampledAt,
                assumedTimeZoneIdentifier: timeZoneIdentifier
            )
            let record = try makeHistoricalRecord(
                sourceRecordType: "LabRecord",
                sourceRecordID: source.id,
                timestamp: timestamp,
                legacyAssociationID: source.regimenVersionID,
                timeline: timeline,
                in: context,
                now: now
            )
            context.insert(record)
            records.append(record)
            keys.insert(key)
        }
        return records
    }

    private static func makeHistoricalRecord(
        sourceRecordType: String,
        sourceRecordID: UUID,
        timestamp: HistoricalTimestamp,
        legacyAssociationID: UUID?,
        timeline: [RegimenTimelineVersion],
        in context: ModelContext,
        now: Date
    ) throws -> HistoricalTimeRecord {
        let projection = RegimenTimelineResolver.project(timeline, asOf: timestamp.localDate)
        let state: HistoricalAssociationState
        let resolved: UUID?
        if let current = projection.current {
            state = .resolved
            resolved = current.id
        } else if projection.isAmbiguous {
            state = .ambiguous
            resolved = nil
            try insertIssueIfNeeded(
                kind: .ambiguousCanonicalRegimenAssociation,
                recordType: sourceRecordType,
                recordID: sourceRecordID,
                in: context,
                now: now
            )
        } else {
            state = .missing
            resolved = nil
            try insertIssueIfNeeded(
                kind: .missingCanonicalRegimenAssociation,
                recordType: sourceRecordType,
                recordID: sourceRecordID,
                in: context,
                now: now
            )
        }
        return HistoricalTimeRecord(
            sourceRecordType: sourceRecordType,
            sourceRecordID: sourceRecordID,
            timestamp: timestamp,
            legacyAssociationID: legacyAssociationID,
            resolvedRegimenVersionID: resolved,
            associationState: state
        )
    }

    private static func insertIssueIfNeeded(
        kind: MigrationIssueKind,
        recordType: String,
        recordID: UUID,
        in context: ModelContext,
        now: Date
    ) throws {
        let issueKey = [kind.rawValue, recordType, recordID.uuidString.lowercased()]
            .joined(separator: ":")
        var descriptor = FetchDescriptor<MigrationIssue>(
            predicate: #Predicate { $0.issueKey == issueKey }
        )
        descriptor.fetchLimit = 1
        guard try context.fetch(descriptor).isEmpty else { return }
        context.insert(
            MigrationIssue(
                issueKey: issueKey,
                kind: kind,
                recordType: recordType,
                recordID: recordID,
                detectedAt: now
            )
        )
    }

    private static func ensureRevisions(
        preferences: UserPreferencesRecord,
        journeyFacts: JourneyFacts,
        versions: [RegimenPlanVersionRecord],
        historicalTimes: [HistoricalTimeRecord],
        in context: ModelContext,
        now: Date
    ) throws {
        var metadataDescriptor = FetchDescriptor<DatasetMetadata>()
        metadataDescriptor.fetchLimit = 2
        let metadataRecords = try context.fetch(metadataDescriptor)
        guard metadataRecords.count == 1, let metadata = metadataRecords.first else {
            throw AppDataFailure.migrationFailed
        }
        let items = try context.fetch(FetchDescriptor<RegimenItemRecord>())
        let rules = try context.fetch(FetchDescriptor<ScheduleRuleRecord>())
        var facts: [(String, UUID, [RecordDigestV1.Field], Date)] = [
            ("UserPreferencesRecord", stableUUID(for: preferences.singletonKey), CoreFactDigestV1.preferences(preferences), preferences.createdAt)
        ]
        if let profile = journeyFacts.profile {
            facts.append(("HrtJourneyProfileRecord", stableUUID(for: profile.singletonKey), CoreFactDigestV1.journeyProfile(profile), profile.createdAt))
        }
        facts += try journeyFacts.periods.map {
            ("HrtPeriodRecord", $0.id, try CoreFactDigestV1.period($0), $0.createdAt)
        }
        facts += try versions.map {
            ("RegimenPlanVersionRecord", $0.id, try CoreFactDigestV1.regimen($0), $0.createdAt)
        }
        facts += items.map {
            ("RegimenItemRecord", $0.id, CoreFactDigestV1.item($0), $0.createdAt)
        }
        facts += rules.map {
            ("ScheduleRuleRecord", $0.id, CoreFactDigestV1.schedule($0), $0.createdAt)
        }
        facts += historicalTimes.map {
            ("HistoricalTimeRecord", stableUUID(for: $0.recordKey), CoreFactDigestV1.historicalTime($0), $0.instant)
        }
        facts.sort {
            $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.uuidString < $1.1.uuidString
        }
        let existingKeys = Set(try context.fetch(FetchDescriptor<RecordRevision>()).map(\.recordKey))
        for (type, id, fields, createdAt) in facts {
            let key = type + ":" + id.uuidString.lowercased()
            guard !existingKeys.contains(key) else { continue }
            guard metadata.nextLocalRevision > 0,
                  metadata.nextLocalRevision < Int64.max else {
                throw AppDataFailure.migrationFailed
            }
            context.insert(
                RecordRevision(
                    recordKey: key,
                    recordType: type,
                    recordID: id,
                    datasetID: metadata.datasetID,
                    localRevision: metadata.nextLocalRevision,
                    digestVersion: RecordDigestV1.version,
                    digestHex: try RecordDigestV1.sha256Hex(
                        recordType: type,
                        recordID: id,
                        fields: fields
                    ),
                    committedAt: max(createdAt, now)
                )
            )
            metadata.nextLocalRevision += 1
        }
        metadata.lastCommittedAt = now
    }

    private static func civilDate(
        from instant: Date,
        timeZoneIdentifier: String
    ) throws -> CivilDateFact {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw AppDataFailure.migrationFailed
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: instant)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            throw AppDataFailure.migrationFailed
        }
        return try CivilDateFact(year: year, month: month, day: day)
    }

    static func stableUUID(for value: String) -> UUID {
        let bytes = Array(value.utf8)
        var buffer = [UInt8](repeating: 0, count: 16)
        for (index, byte) in bytes.enumerated() {
            buffer[index % 16] = buffer[index % 16] &+ byte &+ UInt8(truncatingIfNeeded: index)
        }
        buffer[6] = (buffer[6] & 0x0F) | 0x50
        buffer[8] = (buffer[8] & 0x3F) | 0x80
        return UUID(uuid: (
            buffer[0], buffer[1], buffer[2], buffer[3],
            buffer[4], buffer[5], buffer[6], buffer[7],
            buffer[8], buffer[9], buffer[10], buffer[11],
            buffer[12], buffer[13], buffer[14], buffer[15]
        ))
    }
}

enum CoreFactDigestV1 {
    static func preferences(_ model: UserPreferencesRecord) -> [RecordDigestV1.Field] {
        [
            .init("gentleModeEnabled", .bool(model.gentleModeEnabled)),
            .init("notificationContentLevel", .string(model.notificationContentLevel)),
            .init("onboardingCompleted", .bool(model.onboardingCompleted)),
            .init("preferredLanguage", .string(model.preferredLanguage))
        ]
    }

    static func journeyProfile(_ model: HrtJourneyProfileRecord) -> [RecordDigestV1.Field] {
        [
            .init("firstEverStartDay", .integer(Int64(model.firstEverStartDay))),
            .init("firstEverStartMonth", .integer(Int64(model.firstEverStartMonth))),
            .init("firstEverStartYear", .integer(Int64(model.firstEverStartYear)))
        ]
    }

    static func period(_ model: HrtPeriodRecord) throws -> [RecordDigestV1.Field] {
        [
            .init("endDay", integer(model.endDay)),
            .init("endMonth", integer(model.endMonth)),
            .init("endYear", integer(model.endYear)),
            .init("note", .string(model.note)),
            .init("startDay", .integer(Int64(model.startDay))),
            .init("startMonth", .integer(Int64(model.startMonth))),
            .init("startYear", .integer(Int64(model.startYear)))
        ]
    }

    static func regimen(_ model: RegimenPlanVersionRecord) throws -> [RecordDigestV1.Field] {
        [
            .init("changeReason", .string(model.changeReason)),
            .init("code", .string(model.code)),
            .init("editState", .string(model.editStateRawValue)),
            .init("effectiveEndDay", integer(model.effectiveEndDay)),
            .init("effectiveEndMonth", integer(model.effectiveEndMonth)),
            .init("effectiveEndYear", integer(model.effectiveEndYear)),
            .init("effectiveStartDay", .integer(Int64(model.effectiveStartDay))),
            .init("effectiveStartMonth", .integer(Int64(model.effectiveStartMonth))),
            .init("effectiveStartYear", .integer(Int64(model.effectiveStartYear))),
            .init("isArchived", .bool(model.isArchived)),
            .init("legacySourceID", model.legacySourceID.map(RecordDigestV1.Value.uuid) ?? .null),
            .init("previousVersionID", model.previousVersionID.map(RecordDigestV1.Value.uuid) ?? .null),
            .init("requiresMigrationReview", .bool(model.requiresMigrationReview)),
            .init("title", .string(model.title))
        ]
    }

    static func item(_ model: RegimenItemRecord) -> [RecordDigestV1.Field] {
        [
            .init("catalogProductID", string(model.catalogProductID)),
            .init("catalogVersion", string(model.catalogVersion)),
            .init("displayName", .string(model.displayName)),
            .init("dosageForm", .string(model.dosageForm)),
            .init("doseOriginal", .string(model.doseOriginal)),
            .init("genericName", .string(model.genericName)),
            .init("productSnapshot", .string(model.productSnapshot)),
            .init("regimenVersionID", .uuid(model.regimenVersionID)),
            .init("route", .string(model.route)),
            .init("sortOrder", .integer(Int64(model.sortOrder))),
            .init("unitOriginal", .string(model.unitOriginal))
        ]
    }

    static func schedule(_ model: ScheduleRuleRecord) -> [RecordDigestV1.Field] {
        [
            .init("anchorDay", .integer(Int64(model.anchorDay))),
            .init("anchorMonth", .integer(Int64(model.anchorMonth))),
            .init("anchorYear", .integer(Int64(model.anchorYear))),
            .init("defaultSnoozeMinutes", .integer(Int64(model.defaultSnoozeMinutes))),
            .init("endDay", integer(model.endDay)),
            .init("endMonth", integer(model.endMonth)),
            .init("endYear", integer(model.endYear)),
            .init("fixedTimeZoneIdentifier", string(model.fixedTimeZoneIdentifier)),
            .init("intervalDays", integer(model.intervalDays)),
            .init("kind", .string(model.kindRawValue)),
            .init("localTimes", .string(model.localTimes)),
            .init("regimenItemID", .uuid(model.regimenItemID)),
            .init("reminderEnabled", .bool(model.reminderEnabled)),
            .init("revision", .integer(Int64(model.revision))),
            .init("timeZoneBehavior", .string(model.timeZoneBehaviorRawValue)),
            .init("weekdays", .string(model.weekdays))
        ]
    }

    static func historicalTime(_ model: HistoricalTimeRecord) -> [RecordDigestV1.Field] {
        [
            .init("associationState", .string(model.associationStateRawValue)),
            .init("instant", timestamp(model.instant)),
            .init("legacyAssociationID", model.legacyAssociationID.map(RecordDigestV1.Value.uuid) ?? .null),
            .init("localDay", .integer(Int64(model.localDay))),
            .init("localHour", .integer(Int64(model.localHour))),
            .init("localMinute", .integer(Int64(model.localMinute))),
            .init("localMonth", .integer(Int64(model.localMonth))),
            .init("localNanosecond", .integer(Int64(model.localNanosecond))),
            .init("localSecond", .integer(Int64(model.localSecond))),
            .init("localYear", .integer(Int64(model.localYear))),
            .init("precision", .string(model.precisionRawValue)),
            .init("provenance", .string(model.provenanceRawValue)),
            .init("resolvedRegimenVersionID", model.resolvedRegimenVersionID.map(RecordDigestV1.Value.uuid) ?? .null),
            .init("sourceRecordID", .uuid(model.sourceRecordID)),
            .init("sourceRecordType", .string(model.sourceRecordType)),
            .init("timeZoneIdentifier", .string(model.timeZoneIdentifier)),
            .init("utcOffsetSeconds", .integer(Int64(model.utcOffsetSeconds)))
        ]
    }

    private static func integer(_ value: Int?) -> RecordDigestV1.Value {
        value.map { .integer(Int64($0)) } ?? .null
    }

    private static func string(_ value: String?) -> RecordDigestV1.Value {
        value.map(RecordDigestV1.Value.string) ?? .null
    }

    private static func timestamp(_ date: Date) -> RecordDigestV1.Value {
        .timestampMicroseconds(Int64((date.timeIntervalSince1970 * 1_000_000).rounded()))
    }
}
