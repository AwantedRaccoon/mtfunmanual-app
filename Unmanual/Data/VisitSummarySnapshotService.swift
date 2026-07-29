import CryptoKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

extension AppReadActor {
    func visitSummarySnapshot(
        configuration: VisitSummaryConfiguration,
        terminalOverlay: DataControlTerminalOverlay,
        parentRecordOverlay: ParentRecordTerminalOverlay,
        generatedAt: Date = Date(),
        displayTimeZoneIdentifier: String =
            TimeZone.autoupdatingCurrent.identifier
    ) throws -> VisitSummarySnapshot {
        guard let displayTimeZone = TimeZone(
            identifier: displayTimeZoneIdentifier
        ) else {
            throw HistoricalTimeError.unknownTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = displayTimeZone
        let interval = try VisitSummaryPolicy.validatedInterval(
            configuration: configuration,
            calendar: calendar
        )
        guard generatedAt.timeIntervalSince1970.isFinite else {
            throw VisitSummaryFailure.corruptedData
        }
        let startDate = try civilDate(interval.start, calendar: calendar)
        let endDate = try civilDate(interval.end, calendar: calendar)
        let hiddenRegimens =
            terminalOverlay.draftRegimenVersionIDs
                .union(terminalOverlay.sealedRegimenVersionIDs)

        let attachments = try fetchBounded(
            AttachmentRecord.self,
            limit: 20_000
        )
        let attachmentsByOwner = Dictionary(
            grouping: attachments,
            by: { $0.ownerTypeRawValue + ":" + $0.ownerID.uuidString.lowercased() }
        )
        let imageAttachmentCount: (AttachmentOwnerType, UUID) -> Int = {
            ownerType, ownerID in
            attachmentsByOwner[
                ownerType.rawValue + ":" + ownerID.uuidString.lowercased(),
                default: []
            ].filter {
                $0.deletedAt == nil
                    && $0.deleteOperationID == nil
                    && UTType($0.typeIdentifier)?
                        .conforms(to: .image) == true
            }.count
        }

        let regimens = try configuration.privacy.includeRegimen
            ? reportRegimens(
                startDate: startDate,
                endDate: endDate,
                hiddenRegimens: hiddenRegimens,
                includeSensitiveNotes:
                    configuration.privacy.includeSensitiveNotes
            )
            : []
        let administrations =
            try configuration.content.includeExecution
                ? reportAdministrations(
                    interval: interval,
                    hiddenRegimens: hiddenRegimens,
                    deletedOccurrenceKeys:
                        terminalOverlay.administrationOccurrenceKeys,
                    includeSensitiveNotes:
                        configuration.privacy.includeSensitiveNotes
                )
                : []
        let labs = try configuration.privacy.includeLabs
            ? reportLabs(
                interval: interval,
                deletedIDs: parentRecordOverlay.labSampleIDs,
                includeSensitiveNotes:
                    configuration.privacy.includeSensitiveNotes,
                attachmentCount: {
                    configuration.privacy.includePhotos
                        ? imageAttachmentCount(.labSample, $0)
                        : 0
                }
            )
            : []
        let statuses = try configuration.content.includeStatus
            ? reportStatuses(
                interval: interval,
                deletedIDs:
                    parentRecordOverlay.statusObservationIDs,
                includeSensitiveNotes:
                    configuration.privacy.includeSensitiveNotes,
                attachmentCount: {
                    configuration.privacy.includePhotos
                        ? imageAttachmentCount(.statusObservation, $0)
                        : 0
                }
            )
            : []
        let journey = try reportJourney(
            interval: interval,
            deletedIDs: terminalOverlay.journeyEntryIDs,
            includeEvents: configuration.content.includeEvents,
            includeQuestions: configuration.content.includeQuestions
        )

        let count = regimens.count
            + administrations.count
            + labs.count
            + statuses.count
            + journey.events.count
            + journey.questions.count
        guard count <= VisitSummaryPolicy.maximumRecordCount else {
            throw VisitSummaryFailure.capacityExceeded
        }
        let disclosedAttachmentCount =
            labs.reduce(0) { $0 + $1.attachmentCount }
                + statuses.reduce(0) { $0 + $1.attachmentCount }
        let stateDigest = VisitSummarySnapshotDigest.make(
            rangeStart: interval.start,
            rangeEnd: interval.end,
            regimens: regimens,
            administrations: administrations,
            labs: labs,
            statuses: statuses,
            events: journey.events,
            questions: journey.questions,
            disclosedAttachmentCount: disclosedAttachmentCount
        )
        return VisitSummarySnapshot(
            snapshotID: UUID(),
            generatedAt: generatedAt,
            rangeStart: interval.start,
            rangeEnd: interval.end,
            subjectName: configuration.normalizedName(),
            includesGeneratedDate:
                configuration.privacy.includeGeneratedDate,
            regimens: regimens,
            administrations: administrations,
            labs: labs,
            statuses: statuses,
            events: journey.events,
            questions: journey.questions,
            disclosedAttachmentCount: disclosedAttachmentCount,
            sensitiveNotesIncluded:
                configuration.privacy.includeSensitiveNotes,
            stateDigest: stateDigest
        )
    }

    private func reportRegimens(
        startDate: CivilDateFact,
        endDate: CivilDateFact,
        hiddenRegimens: Set<UUID>,
        includeSensitiveNotes: Bool
    ) throws -> [VisitSummaryRegimen] {
        let sealed = RegimenEditState.sealed.rawValue
        var descriptor = FetchDescriptor<RegimenPlanVersionRecord>(
            predicate: #Predicate {
                $0.editStateRawValue == sealed && $0.isArchived == false
            },
            sortBy: [
                SortDescriptor(\.effectiveStartYear),
                SortDescriptor(\.effectiveStartMonth),
                SortDescriptor(\.effectiveStartDay),
                SortDescriptor(\.id)
            ]
        )
        descriptor.fetchLimit = 513
        let models = try modelContext.fetch(descriptor)
        guard models.count <= 512 else {
            throw VisitSummaryFailure.capacityExceeded
        }
        let selected = models.filter {
            guard !hiddenRegimens.contains($0.id),
                  !$0.requiresMigrationReview,
                  let start = $0.effectiveStartDate else {
                return false
            }
            let end = $0.effectiveEndDate
            return start <= endDate && (end == nil || end! >= startDate)
        }
        let selectedIDs = Set(selected.map(\.id))
        var itemDescriptor = FetchDescriptor<RegimenItemRecord>(
            predicate: #Predicate {
                selectedIDs.contains($0.regimenVersionID)
            },
            sortBy: [
                SortDescriptor(\.sortOrder),
                SortDescriptor(\.id)
            ]
        )
        itemDescriptor.fetchLimit = 4_097
        let items = try modelContext.fetch(itemDescriptor)
        guard items.count <= 4_096 else {
            throw VisitSummaryFailure.capacityExceeded
        }
        let itemIDs = Set(items.map(\.id))
        var scheduleDescriptor = FetchDescriptor<ScheduleRuleRecord>(
            predicate: #Predicate {
                itemIDs.contains($0.regimenItemID)
            }
        )
        scheduleDescriptor.fetchLimit = 4_097
        let schedules = try modelContext.fetch(scheduleDescriptor)
        guard schedules.count <= 4_096 else {
            throw VisitSummaryFailure.capacityExceeded
        }
        let scheduleByItem = try AppDataIndex.checkedUniqueMap(
            schedules,
            keyedBy: \.regimenItemID,
            failure: .corruptionSuspected
        )
        let itemsByVersion = Dictionary(grouping: items, by: \.regimenVersionID)
        return try selected.map { regimen in
            guard let effectiveStartDate = regimen.effectiveStartDate else {
                throw VisitSummaryFailure.corruptedData
            }
            return VisitSummaryRegimen(
                id: regimen.id,
                code: try VisitSummaryPolicy.safeText(regimen.code),
                title: try VisitSummaryPolicy.safeText(regimen.title),
                effectiveStartDate: effectiveStartDate,
                effectiveEndDate: regimen.effectiveEndDate,
                changeReason: try VisitSummaryPolicy.safeText(
                    regimen.changeReason,
                    include: includeSensitiveNotes
                ),
                items: try itemsByVersion[
                    regimen.id,
                    default: []
                ].map { item in
                    VisitSummaryRegimenItem(
                        id: item.id,
                        displayName: try VisitSummaryPolicy.safeText(
                            item.displayName
                        ),
                        doseOriginal: try VisitSummaryPolicy.safeText(
                            item.doseOriginal
                        ),
                        unitOriginal: try VisitSummaryPolicy.safeText(
                            item.unitOriginal
                        ),
                        route: try VisitSummaryPolicy.safeText(item.route),
                        scheduleSummary: try scheduleByItem[item.id]
                            .map(reportScheduleSummary) ?? ""
                    )
                }
            )
        }
    }

    private func reportAdministrations(
        interval: DateInterval,
        hiddenRegimens: Set<UUID>,
        deletedOccurrenceKeys: Set<String>,
        includeSensitiveNotes: Bool
    ) throws -> [VisitSummaryAdministration] {
        let start = interval.start
        let end = interval.end
        var descriptor = FetchDescriptor<AdministrationEventRecord>(
            predicate: #Predicate {
                $0.plannedInstant >= start && $0.plannedInstant <= end
            },
            sortBy: [
                SortDescriptor(\.plannedInstant),
                SortDescriptor(\.createdAt),
                SortDescriptor(\.id)
            ]
        )
        descriptor.fetchLimit = VisitSummaryPolicy.maximumRecordCount + 1
        let events = try modelContext.fetch(descriptor)
        guard events.count <= VisitSummaryPolicy.maximumRecordCount else {
            throw VisitSummaryFailure.capacityExceeded
        }
        let superseded = Set(events.compactMap(\.supersedesEventID))
        let active = events.filter {
            !superseded.contains($0.id)
                && !hiddenRegimens.contains($0.regimenVersionID)
                && !deletedOccurrenceKeys.contains($0.occurrenceKey)
        }
        let itemIDs = Set(active.map(\.regimenItemID))
        var itemDescriptor = FetchDescriptor<RegimenItemRecord>(
            predicate: #Predicate { itemIDs.contains($0.id) }
        )
        itemDescriptor.fetchLimit = itemIDs.count + 1
        let items = try modelContext.fetch(itemDescriptor)
        guard items.count <= itemIDs.count else {
            throw VisitSummaryFailure.corruptedData
        }
        let itemByID = try AppDataIndex.checkedUniqueMap(
            items,
            keyedBy: \.id,
            failure: .corruptionSuspected
        )
        let sourceType = "AdministrationEventRecord"
        let activeIDs = Set(active.map(\.id))
        var timeDescriptor = FetchDescriptor<HistoricalTimeRecord>(
            predicate: #Predicate {
                $0.sourceRecordType == sourceType
                    && activeIDs.contains($0.sourceRecordID)
            }
        )
        timeDescriptor.fetchLimit = activeIDs.count + 1
        let historicalTimes = try modelContext.fetch(timeDescriptor)
        let timeBySourceID = try AppDataIndex.checkedUniqueMap(
            historicalTimes,
            keyedBy: \.sourceRecordID,
            failure: .corruptionSuspected
        )
        return try active.map { event in
            guard let status = event.status else {
                throw VisitSummaryFailure.corruptedData
            }
            return VisitSummaryAdministration(
                id: event.id,
                occurrenceKey: event.occurrenceKey,
                plannedAt: event.plannedInstant,
                actualAt: timeBySourceID[event.id]?.historicalTimestamp?.instant,
                status: status,
                itemName: try VisitSummaryPolicy.safeText(
                    itemByID[event.regimenItemID]?.displayName
                        ?? "已删除项目"
                ),
                note: try VisitSummaryPolicy.safeText(
                    event.note,
                    include: includeSensitiveNotes
                )
            )
        }
    }

    private func reportLabs(
        interval: DateInterval,
        deletedIDs: Set<UUID>,
        includeSensitiveNotes: Bool,
        attachmentCount: (UUID) -> Int
    ) throws -> [VisitSummaryLabSample] {
        let rows = try fetchBounded(
            LabSampleRecord.self,
            limit: VisitSummaryPolicy.maximumRecordCount
        )
        return try rows.compactMap {
            row -> VisitSummaryLabSample? in
            guard !deletedIDs.contains(row.id),
                  let sample = try labSample(id: row.id),
                  VisitSummaryPolicy.contains(
                      sample.timestamp.instant,
                      in: interval
                  ) else {
                return nil
            }
            return VisitSummaryLabSample(
                id: sample.id,
                timestamp: sample.timestamp,
                specimen: try VisitSummaryPolicy.safeText(
                    sample.specimenOriginal
                ),
                context: try VisitSummaryPolicy.safeText(
                    sample.contextNote,
                    include: includeSensitiveNotes
                ),
                results: try sample.results.map {
                    VisitSummaryLabResult(
                        id: $0.id,
                        itemName: try VisitSummaryPolicy.safeText(
                            $0.itemNameSnapshot
                        ),
                        rawValue: try VisitSummaryPolicy.safeText(
                            $0.rawValueOriginal
                        ),
                        unit: try VisitSummaryPolicy.safeText(
                            $0.unitOriginal
                        ),
                        referenceRange: try $0.referenceRangeOriginal.map {
                            try VisitSummaryPolicy.safeText($0)
                        },
                        assayOrVariant: try $0.assayOrVariantOriginal.map {
                            try VisitSummaryPolicy.safeText($0)
                        }
                    )
                },
                attachmentCount: attachmentCount(sample.id)
            )
        }
    }

    private func reportStatuses(
        interval: DateInterval,
        deletedIDs: Set<UUID>,
        includeSensitiveNotes: Bool,
        attachmentCount: (UUID) -> Int
    ) throws -> [VisitSummaryStatus] {
        let rows = try fetchBounded(
            StatusObservationRecord.self,
            limit: VisitSummaryPolicy.maximumRecordCount
        )
        return try rows.compactMap {
            row -> VisitSummaryStatus? in
            guard !deletedIDs.contains(row.id),
                  let status = try statusObservation(id: row.id),
                  VisitSummaryPolicy.contains(
                      status.timestamp.instant,
                      in: interval
                  ) else {
                return nil
            }
            return VisitSummaryStatus(
                id: status.id,
                timestamp: status.timestamp,
                metricName: try VisitSummaryPolicy.safeText(
                    status.metricNameSnapshot
                ),
                level: status.ordinalLevel,
                note: try VisitSummaryPolicy.safeText(
                    status.note,
                    include: includeSensitiveNotes
                ),
                attachmentCount: attachmentCount(status.id)
            )
        }
    }

    private func reportJourney(
        interval: DateInterval,
        deletedIDs: Set<UUID>,
        includeEvents: Bool,
        includeQuestions: Bool
    ) throws -> (
        events: [VisitSummaryJourneyItem],
        questions: [VisitSummaryJourneyItem]
    ) {
        let start = interval.start
        let end = interval.end
        var descriptor = FetchDescriptor<JourneyEntry>(
            predicate: #Predicate {
                $0.occurredAt >= start && $0.occurredAt <= end
            },
            sortBy: [
                SortDescriptor(\.occurredAt),
                SortDescriptor(\.id)
            ]
        )
        descriptor.fetchLimit = VisitSummaryPolicy.maximumRecordCount + 1
        let rows = try modelContext.fetch(descriptor)
        guard rows.count <= VisitSummaryPolicy.maximumRecordCount else {
            throw VisitSummaryFailure.capacityExceeded
        }
        var events: [VisitSummaryJourneyItem] = []
        var questions: [VisitSummaryJourneyItem] = []
        for row in rows where !deletedIDs.contains(row.id) {
            guard let kind = JourneyEntryKind(rawValue: row.kindRawValue) else {
                throw VisitSummaryFailure.corruptedData
            }
            let item = VisitSummaryJourneyItem(
                id: row.id,
                occurredAt: row.occurredAt,
                kind: kind,
                text: try VisitSummaryPolicy.safeText(row.text)
            )
            if kind == .question {
                if includeQuestions { questions.append(item) }
            } else if includeEvents {
                events.append(item)
            }
        }
        return (events, questions)
    }

    private func fetchBounded<Model: PersistentModel>(
        _ type: Model.Type,
        limit: Int
    ) throws -> [Model] {
        var descriptor = FetchDescriptor<Model>()
        descriptor.fetchLimit = limit + 1
        let rows = try modelContext.fetch(descriptor)
        guard rows.count <= limit else {
            throw VisitSummaryFailure.capacityExceeded
        }
        return rows
    }

    private func civilDate(
        _ date: Date,
        calendar: Calendar
    ) throws -> CivilDateFact {
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            throw VisitSummaryFailure.invalidRange
        }
        return try CivilDateFact(year: year, month: month, day: day)
    }

    private func reportScheduleSummary(
        _ schedule: ScheduleRuleRecord
    ) throws -> String {
        guard ScheduleRuleKind(rawValue: schedule.kindRawValue) != nil,
              ScheduleTimeZoneBehavior(
                rawValue: schedule.timeZoneBehaviorRawValue
              ) != nil else {
            throw VisitSummaryFailure.corruptedData
        }
        return try VisitSummaryPolicy.safeText(
            [
                schedule.kindRawValue,
                schedule.localTimes,
                schedule.weekdays,
                schedule.intervalDays.map(String.init) ?? ""
            ].filter { !$0.isEmpty }.joined(separator: " · ")
        )
    }
}

private enum VisitSummarySnapshotDigest {
    static func make(
        rangeStart: Date,
        rangeEnd: Date,
        regimens: [VisitSummaryRegimen],
        administrations: [VisitSummaryAdministration],
        labs: [VisitSummaryLabSample],
        statuses: [VisitSummaryStatus],
        events: [VisitSummaryJourneyItem],
        questions: [VisitSummaryJourneyItem],
        disclosedAttachmentCount: Int
    ) -> String {
        var values = [
            rangeStart.timeIntervalSince1970.description,
            rangeEnd.timeIntervalSince1970.description,
            "attachments:\(disclosedAttachmentCount)"
        ]
        values += regimens.map {
            [
                "regimen",
                $0.id.uuidString.lowercased(),
                $0.code,
                $0.title,
                $0.effectiveStartDate.iso8601,
                $0.effectiveEndDate?.iso8601 ?? "",
                $0.changeReason
            ].joined(separator: "\u{001f}")
        }
        values += regimens.flatMap { regimen in
            regimen.items.map {
                [
                    "regimen-item",
                    regimen.id.uuidString.lowercased(),
                    $0.id.uuidString.lowercased(),
                    $0.displayName,
                    $0.doseOriginal,
                    $0.unitOriginal,
                    $0.route,
                    $0.scheduleSummary
                ].joined(separator: "\u{001f}")
            }
        }
        values += administrations.map {
            [
                "administration",
                $0.id.uuidString.lowercased(),
                $0.occurrenceKey,
                String($0.plannedAt.timeIntervalSince1970.bitPattern),
                $0.actualAt.map {
                    String($0.timeIntervalSince1970.bitPattern)
                } ?? "",
                $0.status.rawValue,
                $0.itemName,
                $0.note
            ].joined(separator: "\u{001f}")
        }
        values += labs.map { sample in
            [
                "lab-sample",
                sample.id.uuidString.lowercased(),
                String(
                    sample.timestamp.instant
                        .timeIntervalSince1970.bitPattern
                ),
                sample.timestamp.timeZoneIdentifier,
                sample.specimen,
                sample.context,
                String(sample.attachmentCount)
            ].joined(separator: "\u{001f}")
        }
        values += labs.flatMap { sample in
            sample.results.map {
                [
                    "lab-result",
                    sample.id.uuidString.lowercased(),
                    $0.id.uuidString.lowercased(),
                    $0.itemName,
                    $0.rawValue,
                    $0.unit,
                    $0.referenceRange ?? "",
                    $0.assayOrVariant ?? ""
                ].joined(separator: "\u{001f}")
            }
        }
        values += statuses.map {
            [
                "status",
                $0.id.uuidString.lowercased(),
                String(
                    $0.timestamp.instant
                        .timeIntervalSince1970.bitPattern
                ),
                $0.timestamp.timeZoneIdentifier,
                $0.metricName,
                String($0.level),
                $0.note,
                String($0.attachmentCount)
            ].joined(separator: "\u{001f}")
        }
        values += (events + questions).map {
            [
                "journey",
                $0.id.uuidString.lowercased(),
                String($0.occurredAt.timeIntervalSince1970.bitPattern),
                $0.kind.rawValue,
                $0.text
            ].joined(separator: "\u{001f}")
        }
        return SHA256.hash(
            data: Data(values.joined(separator: "\0").utf8)
        ).map { String(format: "%02x", $0) }.joined()
    }
}
