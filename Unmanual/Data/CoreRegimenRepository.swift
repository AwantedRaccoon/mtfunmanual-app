import Foundation
import SwiftData

extension AppWriteActor {
    func resolvedAssociationForWrite(
        timestamp: HistoricalTimestamp
    ) throws -> (id: UUID?, state: HistoricalAssociationState) {
        let result = association(in: try sealedTimeline(), on: timestamp.localDate)
        return (result.id, result.state)
    }

    func insertHistoricalTimeForWrite(
        sourceRecordType: String,
        sourceRecordID: UUID,
        timestamp: HistoricalTimestamp,
        legacyAssociationID: UUID?,
        resolvedAssociationID: UUID?,
        associationState: HistoricalAssociationState,
        reservation: ReservedRevision,
        committedAt: Date
    ) throws {
        let record = HistoricalTimeRecord(
            sourceRecordType: sourceRecordType,
            sourceRecordID: sourceRecordID,
            timestamp: timestamp,
            legacyAssociationID: legacyAssociationID,
            resolvedRegimenVersionID: resolvedAssociationID,
            associationState: associationState
        )
        modelContext.insert(record)
        try upsertRevision(
            recordType: "HistoricalTimeRecord",
            recordID: CoreTimeRegimenBackfill.stableUUID(for: record.recordKey),
            fields: CoreFactDigestV1.historicalTime(record),
            reservation: reservation,
            committedAt: committedAt
        )
        try synchronizeAssociationIssue(
            sourceRecordType: sourceRecordType,
            sourceRecordID: sourceRecordID,
            state: associationState,
            detectedAt: committedAt
        )
    }

    func saveRegimenDraft(_ command: SaveRegimenDraftCommand) throws {
        let normalized = try normalize(command)
        modelContext.autosaveEnabled = false
        let preflightExisting = try fetchCoreRegimen(id: command.recordID)
        if let preflightExisting, preflightExisting.editState != .draft {
            throw AppWriteFailure.staleRecord
        }
        try validatePreviousVersion(
            normalized.previousVersionID,
            forStart: normalized.effectiveStartDate,
            excluding: command.recordID
        )
        try validateChildIdentities(
            normalized.items,
            replacingDraftID: command.recordID
        )
        let reservation = try reserveRevision()

        do {
            try modelContext.transaction {
                let existing = try fetchCoreRegimen(id: command.recordID)
                if let existing, existing.editState != .draft {
                    throw AppWriteFailure.staleRecord
                }
                try validatePreviousVersion(
                    normalized.previousVersionID,
                    forStart: normalized.effectiveStartDate,
                    excluding: command.recordID
                )
                try validateChildIdentities(
                    normalized.items,
                    replacingDraftID: command.recordID
                )

                let draft = existing ?? RegimenPlanVersionRecord(
                    id: command.recordID,
                    code: normalized.code,
                    title: normalized.title,
                    effectiveStartDate: normalized.effectiveStartDate,
                    previousVersionID: normalized.previousVersionID,
                    changeReason: normalized.changeReason,
                    editState: .draft,
                    createdAt: command.committedAt
                )
                if existing == nil {
                    modelContext.insert(draft)
                } else {
                    draft.code = normalized.code
                    draft.title = normalized.title
                    draft.effectiveStartYear = normalized.effectiveStartDate.year
                    draft.effectiveStartMonth = normalized.effectiveStartDate.month
                    draft.effectiveStartDay = normalized.effectiveStartDate.day
                    draft.effectiveEndYear = nil
                    draft.effectiveEndMonth = nil
                    draft.effectiveEndDay = nil
                    draft.previousVersionID = normalized.previousVersionID
                    draft.changeReason = normalized.changeReason
                    draft.isArchived = false
                    draft.requiresMigrationReview = false
                }

                try deleteDraftChildren(regimenID: draft.id)
                try upsertRevision(
                    recordType: "RegimenPlanVersionRecord",
                    recordID: draft.id,
                    fields: try CoreFactDigestV1.regimen(draft),
                    reservation: reservation,
                    committedAt: command.committedAt
                )

                for (sortOrder, input) in normalized.items.enumerated() {
                    let item = RegimenItemRecord(
                        id: input.id,
                        regimenVersionID: draft.id,
                        sortOrder: sortOrder,
                        catalogProductID: input.catalogProductID,
                        catalogVersion: input.catalogVersion,
                        displayName: input.displayName,
                        genericName: input.genericName,
                        dosageForm: input.dosageForm,
                        route: input.route,
                        doseOriginal: input.doseOriginal,
                        unitOriginal: input.unitOriginal,
                        productSnapshot: input.productSnapshot,
                        createdAt: command.committedAt
                    )
                    modelContext.insert(item)
                    try upsertRevision(
                        recordType: "RegimenItemRecord",
                        recordID: item.id,
                        fields: CoreFactDigestV1.item(item),
                        reservation: reservation,
                        committedAt: command.committedAt
                    )

                    if let inputSchedule = input.schedule {
                        let schedule = ScheduleRuleRecord(
                            id: inputSchedule.id,
                            regimenItemID: item.id,
                            kind: inputSchedule.kind,
                            anchorDate: normalized.effectiveStartDate,
                            localTimes: inputSchedule.localTimes,
                            weekdays: inputSchedule.weekdays,
                            intervalDays: inputSchedule.intervalDays,
                            timeZoneBehavior: inputSchedule.timeZoneBehavior,
                            fixedTimeZoneIdentifier: inputSchedule.fixedTimeZoneIdentifier,
                            reminderEnabled: false,
                            defaultSnoozeMinutes: inputSchedule.defaultSnoozeMinutes,
                            createdAt: command.committedAt
                        )
                        modelContext.insert(schedule)
                        try upsertRevision(
                            recordType: "ScheduleRuleRecord",
                            recordID: schedule.id,
                            fields: CoreFactDigestV1.schedule(schedule),
                            reservation: reservation,
                            committedAt: command.committedAt
                        )
                    }
                }
                try markCommitted(at: command.committedAt)
            }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func previewRegimenChange(draftID: UUID) throws -> RegimenChangePreview {
        guard let draft = try fetchCoreRegimen(id: draftID),
              draft.editState == .draft,
              let start = draft.effectiveStartDate else {
            throw AppWriteFailure.staleRecord
        }
        try validatePreviousVersion(
            draft.previousVersionID,
            forStart: start,
            excluding: draft.id
        )
        let metadata = try fetchDatasetMetadata()
        let items = try regimenItems(for: draft.id)
        let schedules = try schedules(for: Set(items.map(\.id)))
        let digest = try regimenDraftDigest(draft: draft, items: items, schedules: schedules)
        let impact = try regimenImpact(adding: draft)
        let before: RegimenChangeVersionPreview?
        if let previousVersionID = draft.previousVersionID,
           let previous = try fetchCoreRegimen(id: previousVersionID) {
            before = RegimenChangeVersionPreview(
                code: previous.code,
                title: previous.title,
                items: try regimenItems(for: previous.id).map(regimenItemPreview)
            )
        } else {
            before = nil
        }
        return RegimenChangePreview(
            draftID: draft.id,
            expectedNextLocalRevision: metadata.nextLocalRevision,
            draftDigest: digest,
            before: before,
            after: RegimenChangeVersionPreview(
                code: draft.code,
                title: draft.title,
                items: items.map(regimenItemPreview)
            ),
            affectedJourneyIDs: impact.journey,
            affectedLabIDs: impact.lab,
            affectedRecords: impact.records
        )
    }

    func sealRegimenDraft(_ command: SealRegimenDraftCommand) throws {
        guard let draft = try fetchCoreRegimen(id: command.draftID),
              draft.editState == .draft,
              let start = draft.effectiveStartDate else {
            throw AppWriteFailure.staleRecord
        }
        let metadata = try fetchDatasetMetadata()
        guard metadata.nextLocalRevision == command.expectedNextLocalRevision else {
            throw AppWriteFailure.staleRecord
        }
        let items = try regimenItems(for: draft.id)
        let schedules = try schedules(for: Set(items.map(\.id)))
        guard try regimenDraftDigest(draft: draft, items: items, schedules: schedules)
            == command.draftDigest else {
            throw AppWriteFailure.staleRecord
        }
        try validatePreviousVersion(
            draft.previousVersionID,
            forStart: start,
            excluding: draft.id
        )
        try validateSealedTimeline(adding: draft)

        modelContext.autosaveEnabled = false
        let reservation = try reserveRevision()
        guard reservation.localRevision == command.expectedNextLocalRevision else {
            throw AppWriteFailure.staleRecord
        }

        do {
            try modelContext.transaction {
                guard let transactionDraft = try fetchCoreRegimen(id: command.draftID),
                      transactionDraft.editState == .draft else {
                    throw AppWriteFailure.staleRecord
                }
                transactionDraft.editState = .sealed
                try upsertRevision(
                    recordType: "RegimenPlanVersionRecord",
                    recordID: transactionDraft.id,
                    fields: try CoreFactDigestV1.regimen(transactionDraft),
                    reservation: reservation,
                    committedAt: command.committedAt
                )

                if let successor = try immediateSealedSuccessor(after: start, excluding: transactionDraft.id),
                   successor.previousVersionID != transactionDraft.id {
                    successor.previousVersionID = transactionDraft.id
                    try upsertRevision(
                        recordType: "RegimenPlanVersionRecord",
                        recordID: successor.id,
                        fields: try CoreFactDigestV1.regimen(successor),
                        reservation: reservation,
                        committedAt: command.committedAt
                    )
                }

                let timeline = try sealedTimeline()
                for historical in try boundedHistoricalTimes() {
                    guard let timestamp = historical.historicalTimestamp else {
                        throw AppWriteFailure.invalidInput
                    }
                    let association = association(in: timeline, on: timestamp.localDate)
                    if historical.resolvedRegimenVersionID != association.id
                        || historical.associationStateRawValue != association.state.rawValue {
                        historical.resolvedRegimenVersionID = association.id
                        historical.associationStateRawValue = association.state.rawValue
                        try upsertRevision(
                            recordType: "HistoricalTimeRecord",
                            recordID: CoreTimeRegimenBackfill.stableUUID(for: historical.recordKey),
                            fields: CoreFactDigestV1.historicalTime(historical),
                            reservation: reservation,
                            committedAt: command.committedAt
                        )
                    }
                    try synchronizeAssociationIssue(
                        sourceRecordType: historical.sourceRecordType,
                        sourceRecordID: historical.sourceRecordID,
                        state: association.state,
                        detectedAt: command.committedAt
                    )
                }
                try markCommitted(at: command.committedAt)
            }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private struct NormalizedRegimenDraft {
        let previousVersionID: UUID?
        let code: String
        let title: String
        let effectiveStartDate: CivilDateFact
        let changeReason: String
        let items: [RegimenItemInput]
    }

    private struct AssociationResult {
        let id: UUID?
        let state: HistoricalAssociationState
    }

    private func normalize(_ command: SaveRegimenDraftCommand) throws -> NormalizedRegimenDraft {
        let code = command.code.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = command.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = command.changeReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !title.isEmpty, !command.items.isEmpty else {
            throw AppWriteFailure.invalidInput
        }
        guard Set(command.items.map(\.id)).count == command.items.count else {
            throw AppWriteFailure.invalidInput
        }
        let scheduleIDs = command.items.compactMap(\.schedule?.id)
        guard Set(scheduleIDs).count == scheduleIDs.count else {
            throw AppWriteFailure.invalidInput
        }

        let normalizedItems = try command.items.map { input in
            let displayName = input.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty else { throw AppWriteFailure.invalidInput }
            if let schedule = input.schedule {
                guard !schedule.reminderEnabled,
                      (0...1_440).contains(schedule.defaultSnoozeMinutes) else {
                    throw AppWriteFailure.invalidInput
                }
                if schedule.kind == .everyNDays {
                    guard let interval = schedule.intervalDays, interval > 0 else {
                        throw AppWriteFailure.invalidInput
                    }
                }
                if schedule.timeZoneBehavior == .fixedZone {
                    guard let identifier = schedule.fixedTimeZoneIdentifier,
                          TimeZone(identifier: identifier) != nil else {
                        throw AppWriteFailure.invalidInput
                    }
                }
            }
            return RegimenItemInput(
                id: input.id,
                catalogProductID: input.catalogProductID?.trimmingCharacters(in: .whitespacesAndNewlines),
                catalogVersion: input.catalogVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
                displayName: displayName,
                genericName: input.genericName.trimmingCharacters(in: .whitespacesAndNewlines),
                dosageForm: input.dosageForm.trimmingCharacters(in: .whitespacesAndNewlines),
                route: input.route.trimmingCharacters(in: .whitespacesAndNewlines),
                doseOriginal: input.doseOriginal.trimmingCharacters(in: .whitespacesAndNewlines),
                unitOriginal: input.unitOriginal.trimmingCharacters(in: .whitespacesAndNewlines),
                productSnapshot: input.productSnapshot.trimmingCharacters(in: .whitespacesAndNewlines),
                schedule: input.schedule
            )
        }
        return NormalizedRegimenDraft(
            previousVersionID: command.previousVersionID,
            code: code,
            title: title,
            effectiveStartDate: command.effectiveStartDate,
            changeReason: reason,
            items: normalizedItems
        )
    }

    private func fetchCoreRegimen(id: UUID) throws -> RegimenPlanVersionRecord? {
        var descriptor = FetchDescriptor<RegimenPlanVersionRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchDatasetMetadata() throws -> DatasetMetadata {
        var descriptor = FetchDescriptor<DatasetMetadata>()
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count == 1, let metadata = records.first else {
            throw AppWriteFailure.missingFoundation
        }
        return metadata
    }

    private func regimenItems(for versionID: UUID) throws -> [RegimenItemRecord] {
        var descriptor = FetchDescriptor<RegimenItemRecord>(
            predicate: #Predicate { $0.regimenVersionID == versionID }
        )
        descriptor.fetchLimit = 257
        let records = try modelContext.fetch(descriptor)
        guard records.count <= 256 else { throw AppWriteFailure.invalidInput }
        return records.sorted {
                $0.sortOrder != $1.sortOrder
                    ? $0.sortOrder < $1.sortOrder
                    : $0.id.uuidString < $1.id.uuidString
            }
    }

    private func regimenItemPreview(_ item: RegimenItemRecord) -> String {
        let dose = [item.doseOriginal, item.unitOriginal]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return [item.displayName, dose, item.dosageForm, item.route]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func schedules(for itemIDs: Set<UUID>) throws -> [ScheduleRuleRecord] {
        var descriptor = FetchDescriptor<ScheduleRuleRecord>()
        descriptor.fetchLimit = 4_097
        let records = try modelContext.fetch(descriptor)
        guard records.count <= 4_096 else { throw AppWriteFailure.invalidInput }
        return records
            .filter { itemIDs.contains($0.regimenItemID) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func deleteDraftChildren(regimenID: UUID) throws {
        let items = try regimenItems(for: regimenID)
        let itemIDs = Set(items.map(\.id))
        let rules = try schedules(for: itemIDs)
        for rule in rules {
            try deleteRevision(recordType: "ScheduleRuleRecord", recordID: rule.id)
            modelContext.delete(rule)
        }
        for item in items {
            try deleteRevision(recordType: "RegimenItemRecord", recordID: item.id)
            modelContext.delete(item)
        }
    }

    private func validateChildIdentities(
        _ inputs: [RegimenItemInput],
        replacingDraftID draftID: UUID
    ) throws {
        let inputItemIDs = Set(inputs.map(\.id))
        var itemDescriptor = FetchDescriptor<RegimenItemRecord>()
        itemDescriptor.fetchLimit = 4_097
        let persistedItems = try modelContext.fetch(itemDescriptor)
        guard persistedItems.count <= 4_096 else { throw AppWriteFailure.invalidInput }
        guard !persistedItems.contains(where: {
            inputItemIDs.contains($0.id) && $0.regimenVersionID != draftID
        }) else {
            throw AppWriteFailure.invalidInput
        }

        let inputScheduleIDs = Set(inputs.compactMap(\.schedule?.id))
        guard !inputScheduleIDs.isEmpty else { return }
        let draftItemIDs = Set(
            persistedItems.filter { $0.regimenVersionID == draftID }.map(\.id)
        )
        var scheduleDescriptor = FetchDescriptor<ScheduleRuleRecord>()
        scheduleDescriptor.fetchLimit = 4_097
        let persistedSchedules = try modelContext.fetch(scheduleDescriptor)
        guard persistedSchedules.count <= 4_096 else { throw AppWriteFailure.invalidInput }
        guard !persistedSchedules.contains(where: {
            inputScheduleIDs.contains($0.id) && !draftItemIDs.contains($0.regimenItemID)
        }) else {
            throw AppWriteFailure.invalidInput
        }
    }

    private func deleteRevision(recordType: String, recordID: UUID) throws {
        let key = recordType + ":" + recordID.uuidString.lowercased()
        var descriptor = FetchDescriptor<RecordRevision>(predicate: #Predicate { $0.recordKey == key })
        descriptor.fetchLimit = 1
        if let revision = try modelContext.fetch(descriptor).first {
            modelContext.delete(revision)
        }
    }

    private func validatePreviousVersion(
        _ previousVersionID: UUID?,
        forStart start: CivilDateFact,
        excluding excludedID: UUID
    ) throws {
        var descriptor = FetchDescriptor<RegimenPlanVersionRecord>()
        descriptor.fetchLimit = 513
        let versions = try modelContext.fetch(descriptor)
        guard versions.count <= 512 else { throw AppWriteFailure.invalidInput }
        let earlier = versions
            .filter {
                $0.id != excludedID
                    && $0.editState == .sealed
                    && !$0.requiresMigrationReview
                    && !$0.isArchived
                    && ($0.effectiveStartDate.map { $0 < start } ?? false)
            }
            .sorted {
                guard let lhs = $0.effectiveStartDate, let rhs = $1.effectiveStartDate else {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return lhs != rhs ? lhs < rhs : $0.id.uuidString < $1.id.uuidString
            }
        guard earlier.last?.id == previousVersionID else {
            throw AppWriteFailure.staleRecord
        }
    }

    private func immediateSealedSuccessor(
        after start: CivilDateFact,
        excluding excludedID: UUID
    ) throws -> RegimenPlanVersionRecord? {
        var descriptor = FetchDescriptor<RegimenPlanVersionRecord>()
        descriptor.fetchLimit = 513
        let versions = try modelContext.fetch(descriptor)
        guard versions.count <= 512 else { throw AppWriteFailure.invalidInput }
        return versions
            .filter {
                $0.id != excludedID
                    && $0.editState == .sealed
                    && !$0.requiresMigrationReview
                    && !$0.isArchived
                    && ($0.effectiveStartDate.map { start < $0 } ?? false)
            }
            .sorted {
                guard let lhs = $0.effectiveStartDate, let rhs = $1.effectiveStartDate else {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return lhs != rhs ? lhs < rhs : $0.id.uuidString < $1.id.uuidString
            }
            .first
    }

    private func synchronizeAssociationIssue(
        sourceRecordType: String,
        sourceRecordID: UUID,
        state: HistoricalAssociationState,
        detectedAt: Date
    ) throws {
        let kinds: [MigrationIssueKind] = [
            .missingCanonicalRegimenAssociation,
            .ambiguousCanonicalRegimenAssociation
        ]
        let desiredKind: MigrationIssueKind? = switch state {
        case .resolved: nil
        case .missing: .missingCanonicalRegimenAssociation
        case .ambiguous: .ambiguousCanonicalRegimenAssociation
        }
        for kind in kinds {
            let issueKey = [kind.rawValue, sourceRecordType, sourceRecordID.uuidString.lowercased()]
                .joined(separator: ":")
            var descriptor = FetchDescriptor<MigrationIssue>(
                predicate: #Predicate { $0.issueKey == issueKey }
            )
            descriptor.fetchLimit = 1
            let existing = try modelContext.fetch(descriptor).first
            if kind == desiredKind {
                if existing == nil {
                    modelContext.insert(
                        MigrationIssue(
                            issueKey: issueKey,
                            kind: kind,
                            recordType: sourceRecordType,
                            recordID: sourceRecordID,
                            detectedAt: detectedAt
                        )
                    )
                }
            } else if let existing {
                modelContext.delete(existing)
            }
        }
    }

    private func sealedTimeline() throws -> [RegimenTimelineVersion] {
        var descriptor = FetchDescriptor<RegimenPlanVersionRecord>()
        descriptor.fetchLimit = 513
        let records = try modelContext.fetch(descriptor)
        guard records.count <= 512 else { throw AppWriteFailure.invalidInput }
        return records
            .filter { !$0.isArchived }
            .compactMap { record in
                guard let start = record.effectiveStartDate else { return nil }
                return RegimenTimelineVersion(
                    id: record.id,
                    start: start,
                    end: record.effectiveEndDate,
                    editState: record.editState,
                    requiresReview: record.requiresMigrationReview
                )
            }
    }

    private func validateSealedTimeline(adding draft: RegimenPlanVersionRecord) throws {
        guard let start = draft.effectiveStartDate else { throw AppWriteFailure.invalidInput }
        var eligible = try sealedTimeline().filter {
            $0.editState == .sealed && !$0.requiresReview && $0.id != draft.id
        }
        eligible.append(
            RegimenTimelineVersion(
                id: draft.id,
                start: start,
                end: nil,
                editState: .sealed,
                requiresReview: false
            )
        )
        eligible.sort {
            $0.start != $1.start
                ? $0.start < $1.start
                : $0.id.uuidString < $1.id.uuidString
        }
        for pair in zip(eligible, eligible.dropFirst()) {
            guard pair.0.start < pair.1.start,
                  pair.0.end.map({ $0 <= pair.1.start }) ?? true else {
                throw AppWriteFailure.invalidInput
            }
        }
    }

    private func association(
        in timeline: [RegimenTimelineVersion],
        on date: CivilDateFact
    ) -> AssociationResult {
        let projection = RegimenTimelineResolver.project(timeline, asOf: date)
        if let current = projection.current {
            return AssociationResult(id: current.id, state: .resolved)
        }
        return AssociationResult(id: nil, state: projection.isAmbiguous ? .ambiguous : .missing)
    }

    private func regimenImpact(
        adding draft: RegimenPlanVersionRecord
    ) throws -> (
        journey: [UUID],
        lab: [UUID],
        records: [RegimenImpactRecordPreview]
    ) {
        guard let start = draft.effectiveStartDate else { throw AppWriteFailure.invalidInput }
        var proposedTimeline = try sealedTimeline().filter { $0.id != draft.id }
        proposedTimeline.append(
            RegimenTimelineVersion(
                id: draft.id,
                start: start,
                end: nil,
                editState: .sealed,
                requiresReview: false
            )
        )
        var journey: [UUID] = []
        var lab: [UUID] = []
        var records: [RegimenImpactRecordPreview] = []
        for historical in try boundedHistoricalTimes() {
            guard let timestamp = historical.historicalTimestamp else {
                throw AppWriteFailure.invalidInput
            }
            let proposed = association(in: proposedTimeline, on: timestamp.localDate)
            guard proposed.id != historical.resolvedRegimenVersionID
                    || proposed.state.rawValue != historical.associationStateRawValue else {
                continue
            }
            if historical.sourceRecordType == "JourneyEntry" {
                journey.append(historical.sourceRecordID)
            } else if historical.sourceRecordType == "LabRecord" {
                lab.append(historical.sourceRecordID)
            }
            records.append(
                RegimenImpactRecordPreview(
                    id: historical.sourceRecordID,
                    sourceRecordType: historical.sourceRecordType,
                    localDate: timestamp.localDate,
                    summary: try impactSummary(for: historical),
                    beforeRegimenVersionID: historical.resolvedRegimenVersionID,
                    afterRegimenVersionID: proposed.id
                )
            )
        }
        return (
            journey.sorted { $0.uuidString < $1.uuidString },
            lab.sorted { $0.uuidString < $1.uuidString },
            records.sorted {
                $0.localDate != $1.localDate
                    ? $0.localDate < $1.localDate
                    : $0.id.uuidString < $1.id.uuidString
            }
        )
    }

    private func boundedHistoricalTimes(limit: Int = 10_000) throws -> [HistoricalTimeRecord] {
        var descriptor = FetchDescriptor<HistoricalTimeRecord>()
        descriptor.fetchLimit = limit + 1
        let records = try modelContext.fetch(descriptor)
        guard records.count <= limit else { throw AppWriteFailure.invalidInput }
        return records
    }

    private func impactSummary(for historical: HistoricalTimeRecord) throws -> String {
        let sourceID = historical.sourceRecordID
        if historical.sourceRecordType == "JourneyEntry" {
            var descriptor = FetchDescriptor<JourneyEntry>(
                predicate: #Predicate { $0.id == sourceID }
            )
            descriptor.fetchLimit = 1
            return try modelContext.fetch(descriptor).first?.text ?? "旅程记录"
        }
        if historical.sourceRecordType == "LabRecord" {
            var descriptor = FetchDescriptor<LabRecord>(
                predicate: #Predicate { $0.id == sourceID }
            )
            descriptor.fetchLimit = 1
            if let record = try modelContext.fetch(descriptor).first {
                return [record.itemName, record.rawValue, record.unit]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
            }
            return "检查记录"
        }
        return historical.sourceRecordType
    }

    private func regimenDraftDigest(
        draft: RegimenPlanVersionRecord,
        items: [RegimenItemRecord],
        schedules: [ScheduleRuleRecord]
    ) throws -> String {
        let itemDigests = try items.map {
            try RecordDigestV1.sha256Hex(
                recordType: "RegimenItemRecord",
                recordID: $0.id,
                fields: CoreFactDigestV1.item($0)
            )
        }
        let scheduleDigests = try schedules.map {
            try RecordDigestV1.sha256Hex(
                recordType: "ScheduleRuleRecord",
                recordID: $0.id,
                fields: CoreFactDigestV1.schedule($0)
            )
        }
        return try RecordDigestV1.sha256Hex(
            recordType: "RegimenDraftPreview",
            recordID: draft.id,
            fields: [
                .init("draft", .string(try RecordDigestV1.sha256Hex(
                    recordType: "RegimenPlanVersionRecord",
                    recordID: draft.id,
                    fields: CoreFactDigestV1.regimen(draft)
                ))),
                .init("items", .string(itemDigests.joined(separator: ","))),
                .init("schedules", .string(scheduleDigests.joined(separator: ",")))
            ]
        )
    }
}
