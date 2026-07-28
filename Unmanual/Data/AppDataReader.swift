import Foundation

protocol AppReminderPlanningReader: Sendable {
    func reminderPlanningSnapshot(
        now: Date,
        displayTimeZoneIdentifier: String,
        horizonLocalDays: Int
    ) async throws -> ReminderPlanningSnapshot
}

protocol AppPrivacyControlReader: Sendable {
    func privacyControlSnapshot() async throws
        -> PrivacyControlSnapshot
}

extension AppReadActor: AppReminderPlanningReader,
    AppPrivacyControlReader {}

enum DataControlTimelineRedaction {
    static func apply(
        _ item: PersonalTimelineItem,
        terminal: DataControlTerminalProjection
    ) -> PersonalTimelineItem? {
        let overlay = terminal.overlay
        let hiddenRegimens =
            overlay.draftRegimenVersionIDs
                .union(
                    overlay.sealedRegimenVersionIDs
                )
        switch item.kind {
        case .journeyEntry:
            return overlay.journeyEntryIDs
                .contains(item.id)
                ? nil : item
        case .administration:
            guard !terminal.administrationEventIDs
                .contains(item.id) else {
                return nil
            }
            guard let regimenVersionID =
                    item.regimenVersionID,
                  hiddenRegimens.contains(
                      regimenVersionID
                  ) else {
                return item
            }
            return PersonalTimelineItem(
                id: item.id,
                kind: item.kind,
                title: "已删除方案",
                detail: item.detail,
                timestamp: item.timestamp,
                dateOnly: item.dateOnly,
                localDate: item.localDate,
                regimenVersionID:
                    regimenVersionID
            )
        case .regimenVersion:
            return hiddenRegimens.contains(item.id)
                ? nil : item
        case .hrtJourney:
            return overlay.hidesHrtJourney
                ? nil : item
        case .labSample, .statusObservation,
             .countdown:
            return item
        }
    }
}

struct AppDataReader: Sendable {
    private let storage: AppReadActor
    private let dataControlCoordinator: AppDataControlCoordinator
    private let sessionReleaseProbe:
        AppDataSessionReleaseProbe?

    init(
        storage: AppReadActor,
        dataControlCoordinator: AppDataControlCoordinator,
        sessionReleaseProbe:
            AppDataSessionReleaseProbe? = nil
    ) {
        self.storage = storage
        self.dataControlCoordinator = dataControlCoordinator
        self.sessionReleaseProbe = sessionReleaseProbe
    }

    func todaySnapshot() async throws -> TodaySnapshot {
        try await withReadLease {
            let snapshot = try await storage.todaySnapshot()
            let overlay = try await storage
                .dataControlTerminalOverlay()
            let parentRecordOverlay = try await storage
                .parentRecordTerminalOverlay()
            let hiddenRegimens =
                overlay.draftRegimenVersionIDs
                    .union(overlay.sealedRegimenVersionIDs)
            return TodaySnapshot(
                profile: overlay.hidesHrtJourney
                    ? nil
                    : snapshot.profile,
                hrtJourney: overlay.hidesHrtJourney
                    ? nil
                    : snapshot.hrtJourney,
                countdown: snapshot.countdown,
                regimens: snapshot.regimens.filter {
                    !hiddenRegimens.contains($0.id)
                },
                labRecords: snapshot.labRecords.filter {
                    !parentRecordOverlay.labSampleIDs
                        .contains(
                            PersonalTimelineBackfill
                                .legacySampleID(
                                    for: $0.id
                                )
                        )
                },
                entries: snapshot.entries.filter {
                    !overlay.journeyEntryIDs.contains($0.id)
                },
                gentleModeEnabled: snapshot.gentleModeEnabled
            )
        }
    }

    func coreRegimenOverview(
        asOf date: CivilDateFact
    ) async throws -> CoreRegimenOverviewSnapshot {
        try await withReadLease {
            let snapshot = try await storage
                .coreRegimenOverview(asOf: date)
            let overlay = try await storage
                .dataControlTerminalOverlay()
            let parentRecordOverlay = try await storage
                .parentRecordTerminalOverlay()
            let hidden = overlay.draftRegimenVersionIDs
                .union(overlay.sealedRegimenVersionIDs)
            return CoreRegimenOverviewSnapshot(
                current: snapshot.current.flatMap { version in
                    guard !overlay.draftRegimenVersionIDs
                        .contains(version.id) else {
                        return nil
                    }
                    return overlay.sealedRegimenVersionIDs
                        .contains(version.id)
                        ? redactedDeletedRegimen(version)
                        : version
                },
                upcoming: snapshot.upcoming.compactMap { version in
                    guard !overlay.draftRegimenVersionIDs
                        .contains(version.id) else {
                        return nil
                    }
                    return overlay.sealedRegimenVersionIDs
                        .contains(version.id)
                        ? redactedDeletedRegimen(version)
                        : version
                },
                history: snapshot.history.compactMap { version in
                    guard !overlay.draftRegimenVersionIDs
                        .contains(version.id) else {
                        return nil
                    }
                    return overlay.sealedRegimenVersionIDs
                        .contains(version.id)
                        ? redactedDeletedRegimen(version)
                        : version
                },
                drafts: snapshot.drafts.filter {
                    !hidden.contains($0.id)
                },
                lineageAnchors: snapshot.lineageAnchors,
                terminalDeletedVersionIDs:
                    overlay.sealedRegimenVersionIDs,
                labRecords: snapshot.labRecords.filter {
                    !parentRecordOverlay.labSampleIDs
                        .contains(
                            PersonalTimelineBackfill
                                .legacySampleID(
                                    for: $0.id
                                )
                        )
                },
                latestLabSample: snapshot.latestLabSample,
                reviewIssueCount: snapshot.reviewIssueCount,
                isTimelineAmbiguous: snapshot.isTimelineAmbiguous
            )
        }
    }

    private func redactedDeletedRegimen(
        _ version: CoreRegimenVersionSnapshot
    ) -> CoreRegimenVersionSnapshot {
        CoreRegimenVersionSnapshot(
            id: version.id,
            code: "已删除",
            title: "已删除方案",
            effectiveStartDate: version.effectiveStartDate,
            effectiveEndDate: version.effectiveEndDate,
            previousVersionID: version.previousVersionID,
            changeReason: "",
            editState: .sealed,
            requiresReview: false,
            items: []
        )
    }

    func archiveSnapshot() async throws -> AppArchiveSnapshot {
        try await withReadLease {
            let overlay = try await storage
                .dataControlTerminalOverlay()
            let parentRecordOverlay = try await storage
                .parentRecordTerminalOverlay()
            return try await storage.archiveSnapshot(
                terminalOverlay: overlay,
                parentRecordOverlay: parentRecordOverlay
            )
        }
    }

#if DEBUG
    func developmentBackup() async throws -> AppDataBackup {
        try await withReadLease {
            let overlay = try await storage
                .dataControlTerminalOverlay()
            let parentRecordOverlay = try await storage
                .parentRecordTerminalOverlay()
            guard overlay == .empty,
                  parentRecordOverlay.isEmpty else {
                throw DataControlDeletionFailure.targetDeleted
            }
            return try await storage.developmentBackup()
        }
    }
#endif

    func journeyPage(
        after cursor: JourneyPageCursor?,
        limit: Int = 100
    ) async throws -> JourneyPage {
        try await withReadLease {
            let overlay = try await storage
                .dataControlTerminalOverlay()
            let hiddenRegimens =
                overlay.draftRegimenVersionIDs
                    .union(overlay.sealedRegimenVersionIDs)
            var nextCursor = cursor
            var entries: [JourneyEntrySnapshot] = []
            var regimenCodes: [UUID: String] = [:]
            repeat {
                let page = try await storage.journeyPage(
                    after: nextCursor,
                    limit: max(1, limit - entries.count)
                )
                let visible = page.entries.filter {
                    !overlay.journeyEntryIDs.contains($0.id)
                }
                entries.append(contentsOf: visible)
                regimenCodes.merge(page.regimenCodes) {
                    current, _ in current
                }
                nextCursor = page.nextCursor
                if page.entries.isEmpty { break }
            } while entries.count < limit && nextCursor != nil
            let referenced = Set(entries.compactMap(\.regimenVersionID))
            regimenCodes = regimenCodes.filter {
                referenced.contains($0.key)
            }
            for regimenID in referenced
            where hiddenRegimens.contains(regimenID) {
                regimenCodes[regimenID] = "已删除方案"
            }
            return JourneyPage(
                entries: Array(entries.prefix(limit)),
                regimenCodes: regimenCodes,
                nextCursor: nextCursor
            )
        }
    }

    func labRecords(
        on localDate: CivilDateFact,
        fallbackTimeZone: TimeZone = .autoupdatingCurrent,
        limit: Int = 64
    ) async throws -> [LabRecordSnapshot] {
        try await withReadLease {
            let parentRecordOverlay = try await storage
                .parentRecordTerminalOverlay()
            return try await storage.labRecords(
                on: localDate,
                fallbackTimeZone: fallbackTimeZone,
                limit: limit
            ).filter {
                !parentRecordOverlay.labSampleIDs.contains(
                    PersonalTimelineBackfill
                        .legacySampleID(for: $0.id)
                )
            }
        }
    }

    func labItemDefinitions() async throws
        -> [LabItemDefinitionSnapshot] {
        try await withReadLease {
            try await storage.labItemDefinitions()
        }
    }

    func labTrendPage(
        _ request: LabTrendRequest,
        after cursor: LabTrendCursor? = nil,
        limit: Int = 100
    ) async throws -> LabTrendPage {
        try await withReadLease {
            try await storage.labTrendPage(
                request,
                after: cursor,
                limit: limit
            )
        }
    }

    func hrtJourneySnapshot(
        asOf date: CivilDateFact
    ) async throws -> HrtJourneySnapshot? {
        try await withReadLease {
            let overlay = try await storage
                .dataControlTerminalOverlay()
            guard !overlay.hidesHrtJourney else { return nil }
            return try await storage.hrtJourneySnapshot(asOf: date)
        }
    }

    func onboardingSnapshot(
        asOf instant: Date = Date(),
        displayTimeZoneIdentifier: String =
            TimeZone.autoupdatingCurrent.identifier
    ) async throws -> OnboardingSnapshot {
        try await withReadLease {
            let overlay = try await storage
                .dataControlTerminalOverlay()
            return try await storage.onboardingSnapshot(
                asOf: instant,
                displayTimeZoneIdentifier:
                    displayTimeZoneIdentifier,
                terminalOverlay: overlay
            )
        }
    }

    func onboardingProfileSnapshot() async throws
        -> HRTProfileSnapshot? {
        try await withReadLease {
            let overlay = try await storage
                .dataControlTerminalOverlay()
            return try await storage
                .onboardingProfileSnapshot(
                    terminalOverlay: overlay
                )
        }
    }

    func labSample(id: UUID) async throws
        -> LabSampleSnapshot? {
        try await withReadLease {
            try await storage.labSample(id: id)
        }
    }

    func statusObservation(id: UUID) async throws
        -> StatusObservationSnapshot? {
        try await withReadLease {
            try await storage.statusObservation(id: id)
        }
    }

    func parentRecordHeadToken(
        type: ParentRecordType,
        id: UUID
    ) async throws -> ParentRecordHeadToken? {
        try await withReadLease {
            try await storage.parentRecordHeadToken(
                type: type,
                id: id
            )
        }
    }

    func parentRecordDeletionImpact(
        type: ParentRecordType,
        id: UUID
    ) async throws -> ParentRecordDeletionImpact {
        try await withReadLease {
            try await storage.parentRecordDeletionImpact(
                type: type,
                id: id
            )
        }
    }

    func parentRecordIsDeleted(
        type: ParentRecordType,
        id: UUID
    ) async throws -> Bool {
        try await withReadLease {
            try await storage.parentRecordIsDeleted(
                type: type,
                id: id
            )
        }
    }

    func attachments(
        ownerType: AttachmentOwnerType,
        ownerID: UUID
    ) async throws -> [AttachmentSnapshot] {
        try await withReadLease {
            try await storage.attachments(
                ownerType: ownerType,
                ownerID: ownerID
            )
        }
    }

    func gentleModeSnapshot() async throws
        -> GentleModeSnapshot {
        try await withReadLease {
            try await storage.gentleModeSnapshot()
        }
    }

    func countdownCurrentSnapshot(
        displayTimeZoneIdentifier: String =
            TimeZone.autoupdatingCurrent.identifier
    ) async throws -> CountdownCurrentSnapshot? {
        try await withReadLease {
            try await storage.countdownCurrentSnapshot(
                displayTimeZoneIdentifier:
                    displayTimeZoneIdentifier
            )
        }
    }

    func countdownEditorSnapshot(
        displayTimeZoneIdentifier: String =
            TimeZone.autoupdatingCurrent.identifier
    ) async throws -> CountdownEditorSnapshot {
        try await withReadLease {
            try await storage.countdownEditorSnapshot(
                displayTimeZoneIdentifier:
                    displayTimeZoneIdentifier
            )
        }
    }

    func countdownHistoryPage(
        after cursor: CountdownLedgerCursor? = nil,
        limit: Int,
        displayTimeZoneIdentifier: String =
            TimeZone.autoupdatingCurrent.identifier
    ) async throws -> CountdownLedgerPage {
        try await withReadLease {
            try await storage.countdownHistoryPage(
                after: cursor,
                limit: limit,
                displayTimeZoneIdentifier:
                    displayTimeZoneIdentifier
            )
        }
    }

    func countdownReviewPage(
        after cursor: CountdownLedgerCursor? = nil,
        limit: Int,
        displayTimeZoneIdentifier: String =
            TimeZone.autoupdatingCurrent.identifier
    ) async throws -> CountdownLedgerPage {
        try await withReadLease {
            try await storage.countdownReviewPage(
                after: cursor,
                limit: limit,
                displayTimeZoneIdentifier:
                    displayTimeZoneIdentifier
            )
        }
    }

    func countdownDetail(
        id: UUID,
        displayTimeZoneIdentifier: String =
            TimeZone.autoupdatingCurrent.identifier
    ) async throws -> CountdownDetailSnapshot? {
        try await withReadLease {
            try await storage.countdownDetail(
                id: id,
                displayTimeZoneIdentifier:
                    displayTimeZoneIdentifier
            )
        }
    }

    func latestLabTimelineItem(
        gentleModeEnabled: Bool? = nil
    ) async throws -> PersonalTimelineItem? {
        try await withReadLease {
            try await storage.latestLabTimelineItem(
                gentleModeEnabled: gentleModeEnabled
            )
        }
    }

    func personalTimelinePage(
        after cursor: PersonalTimelineCursor? = nil,
        limit: Int = 50
    ) async throws -> PersonalTimelinePage {
        try await withReadLease {
            let terminal = try await storage
                .dataControlTerminalProjection()
            var nextCursor = cursor
            var items: [PersonalTimelineItem] = []
            var gentleModeEnabled = false
            repeat {
                let page = try await storage.personalTimelinePage(
                    after: nextCursor,
                    limit: max(1, limit - items.count)
                )
                gentleModeEnabled = page.gentleModeEnabled
                items.append(
                    contentsOf: page.items.compactMap {
                        item -> PersonalTimelineItem? in
                        DataControlTimelineRedaction
                            .apply(
                                item,
                                terminal: terminal
                            )
                    }
                )
                nextCursor = page.nextCursor
                if page.items.isEmpty { break }
            } while items.count < limit && nextCursor != nil
            return PersonalTimelinePage(
                items: Array(items.prefix(limit)),
                nextCursor: nextCursor,
                gentleModeEnabled: gentleModeEnabled
            )
        }
    }

    func privacyControlSnapshot() async throws
        -> PrivacyControlSnapshot {
        try await withReadLease {
            try await storage.privacyControlSnapshot()
        }
    }

    func statusMetrics() async throws
        -> [StatusMetricSnapshot] {
        try await withReadLease {
            try await storage.statusMetrics()
        }
    }

    func todayExecutionSnapshot(
        now: Date,
        displayTimeZoneIdentifier: String
    ) async throws -> TodayExecutionSnapshot {
        try await withReadLease {
            let snapshot = try await storage.todayExecutionSnapshot(
                now: now,
                displayTimeZoneIdentifier:
                    displayTimeZoneIdentifier
            )
            let overlay = try await storage
                .dataControlTerminalOverlay()
            let hiddenRegimens =
                overlay.draftRegimenVersionIDs
                    .union(overlay.sealedRegimenVersionIDs)
            return TodayExecutionSnapshot(
                items: snapshot.items.filter {
                    !overlay.administrationOccurrenceKeys.contains(
                        $0.occurrence.key
                    )
                        && !hiddenRegimens.contains(
                            $0.occurrence.regimenVersionID
                        )
                },
                coverage: snapshot.coverage,
                reviewIssues: snapshot.reviewIssues
            )
        }
    }

    func reminderPlanningSnapshot(
        now: Date,
        displayTimeZoneIdentifier: String,
        horizonLocalDays: Int = 14
    ) async throws -> ReminderPlanningSnapshot {
        try await withReadLease {
            let snapshot = try await storage.reminderPlanningSnapshot(
                now: now,
                displayTimeZoneIdentifier:
                    displayTimeZoneIdentifier,
                horizonLocalDays: horizonLocalDays
            )
            let overlay = try await storage
                .dataControlTerminalOverlay()
            let hiddenRegimens =
                overlay.draftRegimenVersionIDs
                    .union(overlay.sealedRegimenVersionIDs)
            let candidates = snapshot.candidates.filter {
                !overlay.administrationOccurrenceKeys.contains(
                    $0.occurrence.key
                )
                    && !hiddenRegimens.contains(
                        $0.occurrence.regimenVersionID
                    )
            }
            return ReminderPlanningSnapshot(
                candidates: candidates,
                hasEnabledIntent:
                    snapshot.hasEnabledIntent
                        && candidates.contains(where: \.isEnabled),
                countdownCandidates:
                    snapshot.countdownCandidates,
                countdownHasEnabledIntent:
                    snapshot.countdownHasEnabledIntent,
                countdownID: snapshot.countdownID,
                countdownResolutionFailed:
                    snapshot.countdownResolutionFailed,
                countdownFailureCode:
                    snapshot.countdownFailureCode
            )
        }
    }

    func dataControlTerminalOverlay()
        async throws -> DataControlTerminalOverlay {
        try await withReadLease {
            try await storage.dataControlTerminalOverlay()
        }
    }

    func dataControlAdministrationDeletionCandidates(
        now: Date,
        displayTimeZoneIdentifier: String
    ) async throws
        -> [DataControlAdministrationDeletionCandidate] {
        try await withReadLease {
            let terminal = try await storage
                .dataControlTerminalProjection()
            let overlay = terminal.overlay
            let hiddenRegimens =
                overlay.draftRegimenVersionIDs
                    .union(overlay.sealedRegimenVersionIDs)
            let historical = try await storage
                .dataControlAdministrationDeletionCandidates()
            let today = try await storage.todayExecutionSnapshot(
                now: now,
                displayTimeZoneIdentifier:
                    displayTimeZoneIdentifier
            )
            var byStableKey:
                [String: DataControlAdministrationDeletionCandidate] =
                    [:]
            for candidate in historical
            where !overlay.administrationOccurrenceKeys
                .contains(candidate.target.stableKey) {
                let regimenVersionID =
                    candidate.target.occurrenceProjection?
                        .regimenVersionID
                byStableKey[candidate.target.stableKey] =
                    DataControlAdministrationDeletionCandidate(
                        target: candidate.target,
                        displayName:
                            regimenVersionID.map(
                                hiddenRegimens.contains
                            ) == true
                                ? "已删除方案"
                                : candidate.displayName,
                        timestamp: candidate.timestamp
                    )
            }
            for item in today.items
            where !overlay.administrationOccurrenceKeys
                .contains(item.occurrence.key)
                && !hiddenRegimens.contains(
                    item.occurrence.regimenVersionID
                )
                && byStableKey[
                    item.occurrence.key
                ] == nil {
                byStableKey[item.occurrence.key] =
                    try Self.dataControlDeletionCandidate(
                        for: item.occurrence,
                        displayTimeZoneIdentifier:
                            displayTimeZoneIdentifier
                    )
            }
            return byStableKey.values.sorted {
                if $0.timestamp.instant
                    != $1.timestamp.instant {
                    return $0.timestamp.instant
                        > $1.timestamp.instant
                }
                return $0.target.stableKey
                    < $1.target.stableKey
            }
        }
    }

    private static func dataControlDeletionCandidate(
        for occurrence: PlannedOccurrence,
        displayTimeZoneIdentifier: String
    ) throws -> DataControlAdministrationDeletionCandidate {
        guard let canonicalDisplayZone =
                TimeZone(
                    identifier:
                        displayTimeZoneIdentifier
                )?.identifier else {
            throw HistoricalTimeError.unknownTimeZone
        }
        let timestamp = try HistoricalTimestamp(
            validatingInstant: occurrence.instant,
            localDate: occurrence.localDate,
            localTime: occurrence.localTime,
            timeZoneIdentifier:
                occurrence.timeZoneIdentifier,
            utcOffsetSeconds:
                occurrence.utcOffsetSeconds,
            precision:
                occurrence.localTime.nanosecond == 0
                    ? .second : .subsecond,
            provenance: .captured
        )
        return DataControlAdministrationDeletionCandidate(
            target: .administrationOccurrence(
                DataControlOccurrenceProjection(
                    key: occurrence.key,
                    scheduleRuleID:
                        occurrence.scheduleRuleID,
                    scheduleRevision:
                        Int64(
                            occurrence.scheduleRevision
                        ),
                    regimenVersionID:
                        occurrence.regimenVersionID,
                    regimenItemID:
                        occurrence.regimenItemID,
                    displayTimeZoneIdentifier:
                        canonicalDisplayZone,
                    localYear:
                        Int64(occurrence.localDate.year),
                    localMonth:
                        Int64(occurrence.localDate.month),
                    localDay:
                        Int64(occurrence.localDate.day),
                    localHour:
                        Int64(occurrence.localTime.hour),
                    localMinute:
                        Int64(occurrence.localTime.minute),
                    localSecond:
                        Int64(occurrence.localTime.second),
                    localNanosecond:
                        Int64(
                            occurrence.localTime.nanosecond
                        ),
                    resolvedTimeZoneIdentifier:
                        occurrence.timeZoneIdentifier,
                    utcOffsetSeconds:
                        Int64(occurrence.utcOffsetSeconds),
                    instant: occurrence.instant
                )
            ),
            displayName: occurrence.displayName,
            timestamp: timestamp
        )
    }

    private func withReadLease<Output: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        try await dataControlCoordinator.withReadLease(operation)
    }
}

extension AppDataReader: AppReminderPlanningReader,
    AppPrivacyControlReader {}
