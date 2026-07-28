import Foundation
import SwiftData

enum DataControlDeletionTarget: Equatable, Sendable {
    case journeyEntry(UUID)
    case administrationOccurrence(DataControlOccurrenceProjection)
    case draftRegimenVersion(UUID)
    case sealedRegimenVersion(UUID)
    case hrtJourney

    var kind: DataControlTargetKind {
        switch self {
        case .journeyEntry:
            .journeyEntry
        case .administrationOccurrence:
            .administrationOccurrence
        case .draftRegimenVersion:
            .draftRegimenVersion
        case .sealedRegimenVersion:
            .sealedRegimenVersion
        case .hrtJourney:
            .hrtJourney
        }
    }

    var stableKey: String {
        switch self {
        case let .journeyEntry(id),
             let .draftRegimenVersion(id),
             let .sealedRegimenVersion(id):
            id.uuidString.lowercased()
        case let .administrationOccurrence(projection):
            projection.key
        case .hrtJourney:
            "primary-hrt-journey"
        }
    }

    var targetID: UUID? {
        switch self {
        case let .journeyEntry(id),
             let .draftRegimenVersion(id),
             let .sealedRegimenVersion(id):
            id
        case .administrationOccurrence, .hrtJourney:
            nil
        }
    }

    var occurrenceProjection: DataControlOccurrenceProjection? {
        guard case let .administrationOccurrence(projection) = self else {
            return nil
        }
        return projection
    }
}

struct DataControlDeletionPlanRequest: Equatable, Sendable {
    let generationID: UUID
    let target: DataControlDeletionTarget
    let attachmentDeletionOperationIDs: [UUID: UUID]
    let pendingNotifications: [DataControlPendingNotificationEntry]

    init(
        generationID: UUID,
        target: DataControlDeletionTarget,
        attachmentDeletionOperationIDs: [UUID: UUID] = [:],
        pendingNotifications: [DataControlPendingNotificationEntry] = []
    ) {
        self.generationID = generationID
        self.target = target
        self.attachmentDeletionOperationIDs =
            attachmentDeletionOperationIDs
        self.pendingNotifications = pendingNotifications
    }
}

struct DataControlDeletionPlan: Equatable, Sendable {
    let impact: DeletionImpact
    let impactDigest: String

    func command(
        operationID: UUID,
        timestamp: HistoricalTimestamp
    ) -> DeleteDataControlTargetCommand {
        DeleteDataControlTargetCommand(
            operationID: operationID,
            generationID: impact.generationID,
            datasetID: impact.datasetID,
            expectedNextLocalRevision: impact.expectedNextLocalRevision,
            targetKind: impact.targetKind,
            targetStableKey: impact.targetStableKey,
            targetID: impact.targetID,
            expectedRecordKey: impact.expectedRecordKey,
            expectedLocalRevision: impact.expectedLocalRevision,
            expectedDigestHex: impact.expectedDigestHex,
            targetSnapshotManifest: impact.targetSnapshotManifest,
            impactDigest: impactDigest,
            attachmentManifest: impact.attachmentManifest,
            notificationManifest: impact.notificationManifest,
            timestamp: timestamp
        )
    }
}

struct DataControlDeletionWriteResult: Equatable, Sendable {
    let tombstoneID: UUID
    let targetKey: String
    let didApply: Bool
}

struct DataControlAdministrationDeletionCandidate:
    Equatable,
    Sendable {
    let target: DataControlDeletionTarget
    let displayName: String
    let timestamp: HistoricalTimestamp
}

struct DataControlAttachmentRecoveryEvidence:
    Equatable,
    Sendable {
    let committedAttachments:
        [UUID: AttachmentCommittedImport]
    let committedDeletions:
        [UUID: AttachmentCommittedDeletion]
}

enum DataControlDeletionFailure: Error, Equatable, Sendable {
    case invalidTarget
    case missingFoundation
    case corruptionSuspected
    case staleToken
    case operationConflict
    case targetDeleted
    case targetAlreadyDeleted(existingTombstoneID: UUID)
    case attachmentOperationIDsRequired([UUID])
}

enum DataControlDeletionFailureInjection:
    Equatable,
    Sendable {
    case beforeRelationshipValidation
}

private enum DataControlOccurrenceZones {
    static let stableIdentifiers =
        TimeZone.knownTimeZoneIdentifiers.sorted()
}

struct DataControlTerminalOverlay: Equatable, Sendable {
    let journeyEntryIDs: Set<UUID>
    let administrationOccurrenceKeys: Set<String>
    let draftRegimenVersionIDs: Set<UUID>
    let sealedRegimenVersionIDs: Set<UUID>
    let hidesHrtJourney: Bool

    static let empty = DataControlTerminalOverlay(
        journeyEntryIDs: [],
        administrationOccurrenceKeys: [],
        draftRegimenVersionIDs: [],
        sealedRegimenVersionIDs: [],
        hidesHrtJourney: false
    )

    func contains(
        kind: DataControlTargetKind,
        stableKey: String,
        targetID: UUID?
    ) -> Bool {
        switch kind {
        case .journeyEntry:
            targetID.map(journeyEntryIDs.contains) ?? false
        case .administrationOccurrence:
            administrationOccurrenceKeys.contains(stableKey)
        case .draftRegimenVersion:
            targetID.map(draftRegimenVersionIDs.contains) ?? false
        case .sealedRegimenVersion:
            targetID.map(sealedRegimenVersionIDs.contains) ?? false
        case .hrtJourney:
            hidesHrtJourney && stableKey == "primary-hrt-journey"
        }
    }
}

struct DataControlTerminalProjection: Equatable, Sendable {
    let overlay: DataControlTerminalOverlay
    let administrationEventIDs: Set<UUID>
}

enum DataControlDeletionRepository {
    private static let maximumRowsPerModel =
        DataInventoryTaxonomy.maximumRowsPerModel
    private static let maximumRevisions = 1_000_000

    static func plan(
        _ request: DataControlDeletionPlanRequest,
        in context: ModelContext
    ) throws -> DataControlDeletionPlan {
        do {
            try DataControlRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        } catch {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        guard request.target.kind.validates(
            stableKey: request.target.stableKey,
            targetID: request.target.targetID
        ) else {
            throw DataControlDeletionFailure.invalidTarget
        }
        let targetKey = request.target.kind.targetKey(
            stableKey: request.target.stableKey
        )
        if let existing = try tombstone(
            targetKey: targetKey,
            in: context
        ) {
            throw DataControlDeletionFailure.targetAlreadyDeleted(
                existingTombstoneID: existing.id
            )
        }

        let metadata = try uniqueMetadata(in: context)
        let sourceKeys = try sourceRecordKeys(
            for: request.target,
            in: context
        )
        let sources = try sourceEntries(
            for: sourceKeys,
            metadata: metadata,
            in: context
        )
        let expectedRecordKey = "DataControlTarget:" + targetKey
        let snapshot = DataControlTargetSnapshot(
            targetKind: request.target.kind,
            targetStableKey: request.target.stableKey,
            targetID: request.target.targetID,
            expectedRecordKey: expectedRecordKey,
            sources: sources,
            occurrenceProjection: request.target.occurrenceProjection
        )
        guard let expectedLocalRevision = snapshot.expectedLocalRevision,
              let snapshotManifest =
                DataControlTargetSnapshotManifest.encode(snapshot) else {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        do {
            try DataControlRelationshipValidator.validateSourceClosure(
                snapshot: snapshot,
                in: context,
                failure: .corruptionSuspected
            )
        } catch {
            throw DataControlDeletionFailure.corruptionSuspected
        }

        let attachmentEntries = try attachmentManifestEntries(
            sourceKeys: Set(sourceKeys),
            operationIDs: request.attachmentDeletionOperationIDs,
            in: context
        )
        guard let attachmentManifest =
                DataControlAttachmentManifest.encode(attachmentEntries),
              let notificationManifest =
                DataControlPendingNotificationManifest.encode(
                    request.pendingNotifications
                ),
              request.target.kind.isPlannerTarget
                || request.pendingNotifications.isEmpty else {
            throw DataControlDeletionFailure.invalidTarget
        }

        let associatedReceiptCount = try associatedReceiptCount(
            sourceKeys: Set(sourceKeys),
            in: context
        )
        guard let retainedRecordCount = retainedRecordCount(
            sourceCount: sources.count,
            associatedReceiptCount: associatedReceiptCount,
            deletedAttachmentCount: attachmentEntries.count
        ) else {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        let deletedAttachmentBytes = try attachmentEntries.reduce(
            Int64(0)
        ) { total, entry in
            let (sum, overflow) = total.addingReportingOverflow(
                entry.byteCount
            )
            guard !overflow else {
                throw DataControlDeletionFailure.corruptionSuspected
            }
            return sum
        }
        let impact = DeletionImpact(
            generationID: request.generationID,
            datasetID: metadata.datasetID,
            expectedNextLocalRevision: metadata.nextLocalRevision,
            targetKind: request.target.kind,
            targetStableKey: request.target.stableKey,
            targetID: request.target.targetID,
            expectedRecordKey: expectedRecordKey,
            expectedLocalRevision: expectedLocalRevision,
            expectedDigestHex: try DataControlDigestV1.targetToken(
                snapshotManifest
            ),
            targetSnapshotManifest: snapshotManifest,
            attachmentManifest: attachmentManifest,
            notificationManifest: notificationManifest,
            retainedRecordCount: retainedRecordCount,
            deletedAttachmentCount: attachmentEntries.count,
            deletedAttachmentBytes: deletedAttachmentBytes,
            affectedReminderCount: request.pendingNotifications.count
        )
        return DataControlDeletionPlan(
            impact: impact,
            impactDigest: try DataControlDigestV1.impact(impact)
        )
    }

    static func terminalOverlay(
        in context: ModelContext
    ) throws -> DataControlTerminalOverlay {
        do {
            try DataControlRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        } catch {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        let tombstones = try fetchBounded(
            DataControlDeletionTombstoneRecord.self,
            in: context
        )
        var journeys: Set<UUID> = []
        var occurrences: Set<String> = []
        var drafts: Set<UUID> = []
        var sealed: Set<UUID> = []
        var hrt = false
        for tombstone in tombstones {
            guard let kind = tombstone.targetKind else {
                throw DataControlDeletionFailure.corruptionSuspected
            }
            switch kind {
            case .journeyEntry:
                guard let id = tombstone.targetID else {
                    throw DataControlDeletionFailure.corruptionSuspected
                }
                journeys.insert(id)
            case .administrationOccurrence:
                occurrences.insert(tombstone.targetStableKey)
            case .draftRegimenVersion:
                guard let id = tombstone.targetID else {
                    throw DataControlDeletionFailure.corruptionSuspected
                }
                drafts.insert(id)
            case .sealedRegimenVersion:
                guard let id = tombstone.targetID else {
                    throw DataControlDeletionFailure.corruptionSuspected
                }
                sealed.insert(id)
            case .hrtJourney:
                hrt = true
            }
        }
        return DataControlTerminalOverlay(
            journeyEntryIDs: journeys,
            administrationOccurrenceKeys: occurrences,
            draftRegimenVersionIDs: drafts,
            sealedRegimenVersionIDs: sealed,
            hidesHrtJourney: hrt
        )
    }

    static func validate(
        impact: DeletionImpact,
        command: DeleteDataControlTargetCommand,
        activeGenerationID: UUID
    ) throws {
        guard command.generationID == activeGenerationID,
              impact.generationID == activeGenerationID,
              command.datasetID == impact.datasetID,
              command.expectedNextLocalRevision
                == impact.expectedNextLocalRevision,
              command.targetKind == impact.targetKind,
              command.targetStableKey == impact.targetStableKey,
              command.targetID == impact.targetID,
              command.expectedRecordKey == impact.expectedRecordKey,
              command.expectedLocalRevision == impact.expectedLocalRevision,
              command.expectedDigestHex == impact.expectedDigestHex,
              command.targetSnapshotManifest
                == impact.targetSnapshotManifest,
              command.impactDigest
                == (try DataControlDigestV1.impact(impact)),
              command.attachmentManifest == impact.attachmentManifest,
              command.notificationManifest == impact.notificationManifest,
              DataControlTargetSnapshotManifest.decode(
                command.targetSnapshotManifest
              ) != nil,
              DataControlAttachmentManifest.decode(
                command.attachmentManifest
              )?.count == impact.deletedAttachmentCount,
              DataControlPendingNotificationManifest.decode(
                command.notificationManifest
              )?.count == impact.affectedReminderCount else {
            throw DataControlDeletionFailure.staleToken
        }
    }

    static func replan(
        impact: DeletionImpact,
        in context: ModelContext
    ) throws -> DataControlDeletionPlan {
        guard let snapshot = DataControlTargetSnapshotManifest.decode(
            impact.targetSnapshotManifest
        ),
        let attachments = DataControlAttachmentManifest.decode(
            impact.attachmentManifest
        ),
        let notifications = DataControlPendingNotificationManifest.decode(
            impact.notificationManifest
        ) else {
            throw DataControlDeletionFailure.staleToken
        }
        let target: DataControlDeletionTarget
        switch snapshot.targetKind {
        case .journeyEntry:
            guard let id = snapshot.targetID else {
                throw DataControlDeletionFailure.staleToken
            }
            target = .journeyEntry(id)
        case .administrationOccurrence:
            guard let projection = snapshot.occurrenceProjection else {
                throw DataControlDeletionFailure.staleToken
            }
            target = .administrationOccurrence(projection)
        case .draftRegimenVersion:
            guard let id = snapshot.targetID else {
                throw DataControlDeletionFailure.staleToken
            }
            target = .draftRegimenVersion(id)
        case .sealedRegimenVersion:
            guard let id = snapshot.targetID else {
                throw DataControlDeletionFailure.staleToken
            }
            target = .sealedRegimenVersion(id)
        case .hrtJourney:
            target = .hrtJourney
        }
        let operationIDs = Dictionary(
            uniqueKeysWithValues: attachments.map {
                ($0.attachmentID, $0.deletionOperationID)
            }
        )
        return try plan(
            DataControlDeletionPlanRequest(
                generationID: impact.generationID,
                target: target,
                attachmentDeletionOperationIDs: operationIDs,
                pendingNotifications: notifications
            ),
            in: context
        )
    }

    static func retainedRecordCount(
        sourceCount: Int,
        associatedReceiptCount: Int,
        deletedAttachmentCount: Int
    ) -> Int? {
        guard sourceCount >= 0,
              associatedReceiptCount >= 0,
              deletedAttachmentCount >= 0 else {
            return nil
        }
        let (sourceRows, sourceOverflow) =
            sourceCount.multipliedReportingOverflow(by: 2)
        let (receiptRows, receiptOverflow) =
            associatedReceiptCount.multipliedReportingOverflow(by: 2)
        let (attachmentRows, attachmentOverflow) =
            deletedAttachmentCount.multipliedReportingOverflow(by: 6)
        let (first, firstOverflow) = sourceRows.addingReportingOverflow(
            receiptRows
        )
        let (second, secondOverflow) = first.addingReportingOverflow(
            attachmentRows
        )
        let (result, finalOverflow) = second.addingReportingOverflow(4)
        guard !sourceOverflow, !receiptOverflow, !attachmentOverflow,
              !firstOverflow, !secondOverflow, !finalOverflow else {
            return nil
        }
        return result
    }

    private static func sourceRecordKeys(
        for target: DataControlDeletionTarget,
        in context: ModelContext
    ) throws -> [String] {
        switch target {
        case let .journeyEntry(id):
            let journeys = try fetchBounded(JourneyEntry.self, in: context)
            guard journeys.filter({ $0.id == id }).count == 1 else {
                throw DataControlDeletionFailure.invalidTarget
            }
            let times = try fetchBounded(
                HistoricalTimeRecord.self,
                in: context
            ).filter {
                $0.sourceRecordType == "JourneyEntry"
                    && $0.sourceRecordID == id
            }
            guard times.count == 1 else {
                throw DataControlDeletionFailure.corruptionSuspected
            }
            return [
                recordKey("JourneyEntry", id),
                historicalRecordKey(times[0])
            ]

        case let .administrationOccurrence(projection):
            guard let identity = ScheduleOccurrenceResolver.identity(
                for: projection.key
            ),
            identity.ruleID == projection.scheduleRuleID,
            Int64(identity.revision) == projection.scheduleRevision else {
                throw DataControlDeletionFailure.invalidTarget
            }
            let events = try fetchBounded(
                AdministrationEventRecord.self,
                in: context
            ).filter { $0.occurrenceKey == projection.key }
            let overrides = try fetchBounded(
                ReminderOverrideRecord.self,
                in: context
            ).filter { $0.occurrenceKey == projection.key }
            let eventIDs = Set(events.map(\.id))
            let times = try fetchBounded(
                HistoricalTimeRecord.self,
                in: context
            ).filter {
                $0.sourceRecordType == "AdministrationEventRecord"
                    && eventIDs.contains($0.sourceRecordID)
            }
            guard times.count == events.count else {
                throw DataControlDeletionFailure.corruptionSuspected
            }
            return [
                recordKey(
                    "RegimenPlanVersionRecord",
                    projection.regimenVersionID
                ),
                recordKey("RegimenItemRecord", projection.regimenItemID),
                recordKey("ScheduleRuleRecord", projection.scheduleRuleID)
            ]
                + events.map { recordKey("AdministrationEventRecord", $0.id) }
                + overrides.map { recordKey("ReminderOverrideRecord", $0.id) }
                + times.map(historicalRecordKey)

        case let .draftRegimenVersion(id):
            return try regimenSourceRecordKeys(
                id: id,
                requiredState: .draft,
                in: context
            )

        case let .sealedRegimenVersion(id):
            return try regimenSourceRecordKeys(
                id: id,
                requiredState: .sealed,
                in: context
            )

        case .hrtJourney:
            let legacy = try fetchBounded(HRTProfile.self, in: context)
            let profiles = try fetchBounded(
                HrtJourneyProfileRecord.self,
                in: context
            )
            guard legacy.count == 1,
                  profiles.count == 1,
                  profiles[0].singletonKey
                    == HrtJourneyProfileRecord.fixedKey else {
                throw DataControlDeletionFailure.invalidTarget
            }
            let periods = try fetchBounded(HrtPeriodRecord.self, in: context)
            let events = try fetchBounded(
                HrtJourneyLifecycleEventRecord.self,
                in: context
            )
            return [
                recordKey("HRTProfile", legacy[0].id),
                recordKey(
                    "HrtJourneyProfileRecord",
                    CoreTimeRegimenBackfill.stableUUID(
                        for: profiles[0].singletonKey
                    )
                )
            ]
                + periods.map { recordKey("HrtPeriodRecord", $0.id) }
                + events.map {
                    recordKey("HrtJourneyLifecycleEventRecord", $0.id)
                }
        }
    }

    private static func regimenSourceRecordKeys(
        id: UUID,
        requiredState: RegimenEditState,
        in context: ModelContext
    ) throws -> [String] {
        let versions = try fetchBounded(
            RegimenPlanVersionRecord.self,
            in: context
        )
        guard let version = versions.first(where: { $0.id == id }),
              versions.filter({ $0.id == id }).count == 1,
              version.editState == requiredState else {
            throw DataControlDeletionFailure.invalidTarget
        }
        let items = try fetchBounded(
            RegimenItemRecord.self,
            in: context
        ).filter { $0.regimenVersionID == id }
        let itemIDs = Set(items.map(\.id))
        let rules = try fetchBounded(
            ScheduleRuleRecord.self,
            in: context
        ).filter { itemIDs.contains($0.regimenItemID) }
        let ruleIDs = Set(rules.map(\.id))
        let preferences = try fetchBounded(
            ReminderPreferenceRecord.self,
            in: context
        ).filter { ruleIDs.contains($0.scheduleRuleID) }
        let overrides = try fetchBounded(
            ReminderOverrideRecord.self,
            in: context
        ).filter { ruleIDs.contains($0.scheduleRuleID) }
        let events = try fetchBounded(
            AdministrationEventRecord.self,
            in: context
        ).filter { $0.regimenVersionID == id }
        let eventIDs = Set(events.map(\.id))
        let times = try fetchBounded(
            HistoricalTimeRecord.self,
            in: context
        ).filter {
            $0.sourceRecordType == "AdministrationEventRecord"
                && eventIDs.contains($0.sourceRecordID)
        }
        guard times.count == events.count else {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        return [recordKey("RegimenPlanVersionRecord", id)]
            + items.map { recordKey("RegimenItemRecord", $0.id) }
            + rules.map { recordKey("ScheduleRuleRecord", $0.id) }
            + preferences.map {
                recordKey("ReminderPreferenceRecord", $0.id)
            }
            + overrides.map { recordKey("ReminderOverrideRecord", $0.id) }
            + events.map { recordKey("AdministrationEventRecord", $0.id) }
            + times.map(historicalRecordKey)
    }

    private static func sourceEntries(
        for keys: [String],
        metadata: DatasetMetadata,
        in context: ModelContext
    ) throws -> [DataControlTargetSourceEntry] {
        guard Set(keys).count == keys.count, !keys.isEmpty else {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        var descriptor = FetchDescriptor<RecordRevision>()
        descriptor.fetchLimit = maximumRevisions + 1
        let revisions = try context.fetch(descriptor)
        guard revisions.count <= maximumRevisions else {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        let grouped = Dictionary(grouping: revisions, by: \.recordKey)
        return try keys.map { key in
            guard let matches = grouped[key],
                  matches.count == 1,
                  let revision = matches.first,
                  revision.datasetID == metadata.datasetID,
                  revision.localRevision > 0,
                  revision.localRevision < metadata.nextLocalRevision,
                  revision.digestVersion == RecordDigestV1.version else {
                throw DataControlDeletionFailure.corruptionSuspected
            }
            return DataControlTargetSourceEntry(
                recordKey: key,
                localRevision: revision.localRevision,
                digestHex: revision.digestHex
            )
        }
    }

    private static func attachmentManifestEntries(
        sourceKeys: Set<String>,
        operationIDs: [UUID: UUID],
        in context: ModelContext
    ) throws -> [DataControlAttachmentManifestEntry] {
        let attachments = try fetchBounded(
            AttachmentRecord.self,
            in: context
        ).filter {
            $0.deletedAt == nil
                && sourceKeys.contains(
                    $0.ownerTypeRawValue + ":"
                        + $0.ownerID.uuidString.lowercased()
                )
        }
        let attachmentIDs = Set(attachments.map(\.id))
        guard Set(operationIDs.keys) == attachmentIDs else {
            throw DataControlDeletionFailure
                .attachmentOperationIDsRequired(
                    attachmentIDs.sorted {
                        $0.uuidString.lowercased()
                            < $1.uuidString.lowercased()
                    }
                )
        }
        let deletionIDs = Array(operationIDs.values)
        guard Set(deletionIDs).count == deletionIDs.count else {
            throw DataControlDeletionFailure.invalidTarget
        }
        let receipts = try fetchBounded(
            OperationReceiptRecord.self,
            in: context
        )
        let occupiedOperationIDs = Set(receipts.map(\.operationID))
        guard occupiedOperationIDs.isDisjoint(with: deletionIDs) else {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        let tombstones = try fetchBounded(
            DataControlDeletionTombstoneRecord.self,
            in: context
        )
        guard Set(tombstones.map(\.operationID))
            .isDisjoint(with: deletionIDs) else {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        return try attachments.map { attachment in
            guard let deletionOperationID = operationIDs[attachment.id],
                  deletionOperationID != attachment.operationID,
                  attachment.byteCount >= 0,
                  attachment.createdAt.timeIntervalSince1970.isFinite else {
                throw DataControlDeletionFailure.corruptionSuspected
            }
            return DataControlAttachmentManifestEntry(
                attachmentID: attachment.id,
                ownerType: attachment.ownerTypeRawValue,
                ownerID: attachment.ownerID,
                relativePath: attachment.relativePath,
                originalFilename: attachment.originalFilename,
                contentType: attachment.typeIdentifier,
                createdAt: attachment.createdAt,
                byteCount: attachment.byteCount,
                sha256Hex: attachment.sha256Hex,
                deletionOperationID: deletionOperationID
            )
        }
    }

    private static func associatedReceiptCount(
        sourceKeys: Set<String>,
        in context: ModelContext
    ) throws -> Int {
        let receipts = try fetchBounded(
            OperationReceiptRecord.self,
            in: context
        )
        return receipts.reduce(into: 0) { count, receipt in
            let key = recordKey(
                receipt.resultRecordType,
                receipt.resultRecordID
            )
            if sourceKeys.contains(key) {
                count += 1
            }
        }
    }

    private static func uniqueMetadata(
        in context: ModelContext
    ) throws -> DatasetMetadata {
        var descriptor = FetchDescriptor<DatasetMetadata>()
        descriptor.fetchLimit = 2
        let metadata = try context.fetch(descriptor)
        guard metadata.count == 1,
              let value = metadata.first,
              value.singletonKey == DatasetMetadata.fixedKey,
              value.nextLocalRevision > 0,
              value.nextLocalRevision < Int64.max else {
            throw DataControlDeletionFailure.missingFoundation
        }
        return value
    }

    private static func tombstone(
        targetKey: String,
        in context: ModelContext
    ) throws -> DataControlDeletionTombstoneRecord? {
        var descriptor =
            FetchDescriptor<DataControlDeletionTombstoneRecord>(
                predicate: #Predicate { $0.targetKey == targetKey }
            )
        descriptor.fetchLimit = 2
        let records = try context.fetch(descriptor)
        guard records.count <= 1 else {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        return records.first
    }

    private static func recordKey(
        _ type: String,
        _ id: UUID
    ) -> String {
        type + ":" + id.uuidString.lowercased()
    }

    private static func historicalRecordKey(
        _ value: HistoricalTimeRecord
    ) -> String {
        recordKey(
            "HistoricalTimeRecord",
            CoreTimeRegimenBackfill.stableUUID(for: value.recordKey)
        )
    }

    private static func fetchBounded<T: PersistentModel>(
        _ type: T.Type,
        in context: ModelContext
    ) throws -> [T] {
        var descriptor = FetchDescriptor<T>()
        descriptor.fetchLimit = maximumRowsPerModel + 1
        let records = try context.fetch(descriptor)
        guard records.count <= maximumRowsPerModel else {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        return records
    }
}

extension AppWriteActor {
    func dataControlDeletionPlan(
        _ request: DataControlDeletionPlanRequest
    ) throws -> DataControlDeletionPlan {
        try DataControlDeletionRepository.plan(
            request,
            in: modelContext
        )
    }

    func commitDataControlDeletion(
        impact: DeletionImpact,
        command: DeleteDataControlTargetCommand,
        activeGenerationID: UUID,
        failureInjection:
            DataControlDeletionFailureInjection? = nil
    ) throws -> DataControlDeletionWriteResult {
        try DataControlDeletionRepository.validate(
            impact: impact,
            command: command,
            activeGenerationID: activeGenerationID
        )
        let commandDigest = try DataControlDigestV1.deleteCommand(command)
        if let replay = try dataControlDeletionReplay(
            command: command,
            commandDigest: commandDigest
        ) {
            return replay
        }
        if let existing = try dataControlTombstone(
            targetKey: impact.targetKey
        ) {
            throw DataControlDeletionFailure.targetAlreadyDeleted(
                existingTombstoneID: existing.id
            )
        }

        modelContext.autosaveEnabled = false
        do {
            var output: DataControlDeletionWriteResult?
            try modelContext.transaction {
                if let replay = try dataControlDeletionReplay(
                    command: command,
                    commandDigest: commandDigest
                ) {
                    output = replay
                    return
                }
                if let existing = try dataControlTombstone(
                    targetKey: impact.targetKey
                ) {
                    throw DataControlDeletionFailure
                        .targetAlreadyDeleted(
                            existingTombstoneID: existing.id
                        )
                }
                let metadata = try dataControlMetadata()
                guard metadata.datasetID == impact.datasetID,
                      metadata.nextLocalRevision
                        == impact.expectedNextLocalRevision,
                      metadata.nextLocalRevision
                        == command.expectedNextLocalRevision else {
                    throw DataControlDeletionFailure.staleToken
                }
                guard let snapshot =
                        DataControlTargetSnapshotManifest.decode(
                            impact.targetSnapshotManifest
                        ),
                      snapshot.targetKind == impact.targetKind,
                      snapshot.targetStableKey == impact.targetStableKey,
                      snapshot.targetID == impact.targetID else {
                    throw DataControlDeletionFailure.staleToken
                }
                let currentPlan = try DataControlDeletionRepository.replan(
                    impact: impact,
                    in: modelContext
                )
                guard currentPlan.impact == impact,
                      currentPlan.impactDigest
                        == command.impactDigest else {
                    throw DataControlDeletionFailure.staleToken
                }
                do {
                    try DataControlRelationshipValidator
                        .validateSourceClosure(
                            snapshot: snapshot,
                            in: modelContext,
                            failure: .corruptionSuspected
                        )
                    try validateDataControlReceiptLedgerBeforeWrite()
                } catch {
                    if let failure = error
                        as? DataControlDeletionFailure {
                        throw failure
                    }
                    throw DataControlDeletionFailure
                        .corruptionSuspected
                }
                let reservation = try reserveRevisionInCurrentTransaction(
                    committedAt: command.committedAt
                )
                guard reservation.datasetID == impact.datasetID,
                      reservation.localRevision
                        == impact.expectedNextLocalRevision else {
                    throw DataControlDeletionFailure.staleToken
                }
                try applyDataControlAttachmentTerminals(
                    impact: impact,
                    command: command,
                    reservation: reservation
                )

                let tombstone = DataControlDeletionTombstoneRecord(
                    targetKey: impact.targetKey,
                    id: command.operationID,
                    operationID: command.operationID,
                    targetKind: impact.targetKind,
                    targetStableKey: impact.targetStableKey,
                    targetID: impact.targetID,
                    sourceGenerationID: impact.generationID,
                    sourceDatasetID: impact.datasetID,
                    sourceNextLocalRevision:
                        impact.expectedNextLocalRevision,
                    expectedRecordKey: impact.expectedRecordKey,
                    expectedLocalRevision:
                        impact.expectedLocalRevision,
                    expectedDigestHex: impact.expectedDigestHex,
                    targetSnapshotManifest:
                        impact.targetSnapshotManifest,
                    impactDigest: command.impactDigest,
                    attachmentManifest: impact.attachmentManifest,
                    notificationManifest:
                        impact.notificationManifest,
                    retainedRecordCount: impact.retainedRecordCount,
                    deletedAttachmentCount:
                        impact.deletedAttachmentCount,
                    deletedAttachmentBytes:
                        impact.deletedAttachmentBytes,
                    affectedReminderCount:
                        impact.affectedReminderCount,
                    timestamp: try dataControlTimestamp(command),
                    commandDigest: commandDigest
                )
                modelContext.insert(tombstone)
                try upsertRevision(
                    recordType:
                        "DataControlDeletionTombstoneRecord",
                    recordID: tombstone.id,
                    fields: try DataControlDigestV1.tombstone(
                        tombstone
                    ),
                    reservation: reservation,
                    committedAt: command.committedAt
                )
                try insertOperationReceipt(
                    OperationReceiptRecord(
                        operationID: command.operationID,
                        commandDigest: commandDigest,
                        resultRecordType:
                            "DataControlDeletionTombstoneRecord",
                        resultRecordID: tombstone.id,
                        committedAt: command.committedAt
                    ),
                    reservation: reservation
                )
                try markCommitted(at: command.committedAt)
                if failureInjection
                    == .beforeRelationshipValidation {
                    throw DataControlDeletionFailure
                        .corruptionSuspected
                }
                do {
                    try DataControlRelationshipValidator
                        .validate(
                            in: modelContext,
                            failure:
                                .corruptionSuspected
                        )
                } catch {
                    throw DataControlDeletionFailure
                        .corruptionSuspected
                }
                output = DataControlDeletionWriteResult(
                    tombstoneID: tombstone.id,
                    targetKey: tombstone.targetKey,
                    didApply: true
                )
            }
            guard let output else {
                throw DataControlDeletionFailure.corruptionSuspected
            }
            return output
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func replayCommittedDataControlDeletion(
        impact: DeletionImpact,
        command: DeleteDataControlTargetCommand,
        activeGenerationID: UUID
    ) throws -> DataControlDeletionWriteResult? {
        try DataControlDeletionRepository.validate(
            impact: impact,
            command: command,
            activeGenerationID: activeGenerationID
        )
        return try dataControlDeletionReplay(
            command: command,
            commandDigest:
                DataControlDigestV1.deleteCommand(
                    command
                )
        )
    }

    func dataControlAttachmentRecoveryEvidence()
        throws -> DataControlAttachmentRecoveryEvidence {
        var descriptor = FetchDescriptor<AttachmentRecord>()
        descriptor.fetchLimit =
            DataInventoryTaxonomy.maximumRowsPerModel + 1
        let records = try modelContext.fetch(descriptor)
        guard records.count
                <= DataInventoryTaxonomy
                    .maximumRowsPerModel else {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        var active:
            [UUID: AttachmentCommittedImport] = [:]
        var deleted:
            [UUID: AttachmentCommittedDeletion] = [:]
        for record in records {
            guard let attachment =
                    AttachmentSnapshot(record) else {
                throw DataControlDeletionFailure
                    .corruptionSuspected
            }
            if record.deletedAt == nil {
                guard active.updateValue(
                    AttachmentCommittedImport(
                        operationID:
                            record.operationID,
                        attachment: attachment
                    ),
                    forKey: record.id
                ) == nil else {
                    throw DataControlDeletionFailure
                        .corruptionSuspected
                }
            } else {
                guard let operationID =
                        record.deleteOperationID,
                      deleted.updateValue(
                          AttachmentCommittedDeletion(
                              operationID:
                                  operationID,
                              attachment: attachment
                          ),
                          forKey: record.id
                      ) == nil else {
                    throw DataControlDeletionFailure
                        .corruptionSuspected
                }
            }
        }
        return DataControlAttachmentRecoveryEvidence(
            committedAttachments: active,
            committedDeletions: deleted
        )
    }

    func dataControlTerminalOverlay()
        throws -> DataControlTerminalOverlay {
        try DataControlDeletionRepository.terminalOverlay(
            in: modelContext
        )
    }

    private func applyDataControlAttachmentTerminals(
        impact: DeletionImpact,
        command: DeleteDataControlTargetCommand,
        reservation: ReservedRevision
    ) throws {
        guard let entries = DataControlAttachmentManifest.decode(
            impact.attachmentManifest
        ) else {
            throw DataControlDeletionFailure.staleToken
        }
        let snapshot = DataControlTargetSnapshotManifest.decode(
            impact.targetSnapshotManifest
        )
        let sourceKeys = Set(snapshot?.sources.map(\.recordKey) ?? [])
        for entry in entries {
            let id = entry.attachmentID
            var descriptor = FetchDescriptor<AttachmentRecord>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 2
            let records = try modelContext.fetch(descriptor)
            guard records.count == 1,
                  let attachment = records.first,
                  attachment.deletedAt == nil,
                  attachment.deleteOperationID == nil,
                  sourceKeys.contains(
                    attachment.ownerTypeRawValue + ":"
                        + attachment.ownerID.uuidString.lowercased()
                  ),
                  attachment.ownerTypeRawValue == entry.ownerType,
                  attachment.ownerID == entry.ownerID,
                  attachment.relativePath == entry.relativePath,
                  attachment.originalFilename
                    == entry.originalFilename,
                  attachment.typeIdentifier == entry.contentType,
                  attachment.byteCount == entry.byteCount,
                  attachment.sha256Hex == entry.sha256Hex,
                  (try? RecordDigestV1.timestampMicroseconds(
                    attachment.createdAt
                  )) == (try? RecordDigestV1.timestampMicroseconds(
                    entry.createdAt
                  )),
                  attachment.operationID
                    != entry.deletionOperationID,
                  try dataControlReceipt(
                    operationID: entry.deletionOperationID
                  ) == nil else {
                throw DataControlDeletionFailure.staleToken
            }
            let creationReceipts = try dataControlReceipts(
                resultRecordType: "AttachmentRecord",
                resultRecordID: attachment.id
            )
            guard creationReceipts.count == 1,
                  creationReceipts[0].operationID
                    == attachment.operationID else {
                throw DataControlDeletionFailure.corruptionSuspected
            }
            attachment.deletedAt = command.committedAt
            attachment.deleteOperationID = entry.deletionOperationID
            try upsertRevision(
                recordType: "AttachmentRecord",
                recordID: attachment.id,
                fields: try AttachmentDigestV1.record(attachment),
                reservation: reservation,
                committedAt: command.committedAt
            )
            let deletionCommand = DeleteAttachmentCommand(
                operationID: entry.deletionOperationID,
                attachmentID: entry.attachmentID,
                committedAt: command.committedAt
            )
            try insertOperationReceipt(
                OperationReceiptRecord(
                    operationID: entry.deletionOperationID,
                    commandDigest: try AttachmentDigestV1
                        .deleteCommand(deletionCommand),
                    resultRecordType: "AttachmentRecord",
                    resultRecordID: attachment.id,
                    committedAt: command.committedAt
                ),
                reservation: reservation
            )
        }
    }

    private func dataControlDeletionReplay(
        command: DeleteDataControlTargetCommand,
        commandDigest: String
    ) throws -> DataControlDeletionWriteResult? {
        guard let receipt = try dataControlReceipt(
            operationID: command.operationID
        ) else {
            return nil
        }
        guard receipt.commandDigest == commandDigest,
              receipt.resultRecordType
                == "DataControlDeletionTombstoneRecord",
              let tombstone = try dataControlTombstone(
                id: receipt.resultRecordID
              ),
              tombstone.operationID == command.operationID,
              tombstone.commandDigest == commandDigest else {
            throw DataControlDeletionFailure.operationConflict
        }
        do {
            try DataControlRelationshipValidator.validate(
                in: modelContext,
                failure: .corruptionSuspected
            )
        } catch {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        return DataControlDeletionWriteResult(
            tombstoneID: tombstone.id,
            targetKey: tombstone.targetKey,
            didApply: false
        )
    }

    private func dataControlMetadata() throws -> DatasetMetadata {
        var descriptor = FetchDescriptor<DatasetMetadata>()
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count == 1,
              let metadata = records.first,
              metadata.singletonKey == DatasetMetadata.fixedKey else {
            throw DataControlDeletionFailure.missingFoundation
        }
        return metadata
    }

    private func dataControlTombstone(
        targetKey: String
    ) throws -> DataControlDeletionTombstoneRecord? {
        var descriptor =
            FetchDescriptor<DataControlDeletionTombstoneRecord>(
                predicate: #Predicate { $0.targetKey == targetKey }
            )
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count <= 1 else {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        return records.first
    }

    private func dataControlTombstone(
        id: UUID
    ) throws -> DataControlDeletionTombstoneRecord? {
        var descriptor =
            FetchDescriptor<DataControlDeletionTombstoneRecord>(
                predicate: #Predicate { $0.id == id }
            )
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count <= 1 else {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        return records.first
    }

    private func dataControlReceipt(
        operationID: UUID
    ) throws -> OperationReceiptRecord? {
        var descriptor = FetchDescriptor<OperationReceiptRecord>(
            predicate: #Predicate { $0.operationID == operationID }
        )
        descriptor.fetchLimit = 2
        let records = try modelContext.fetch(descriptor)
        guard records.count <= 1 else {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        return records.first
    }

    private func dataControlReceipts(
        resultRecordType: String,
        resultRecordID: UUID
    ) throws -> [OperationReceiptRecord] {
        let type = resultRecordType
        let id = resultRecordID
        var descriptor = FetchDescriptor<OperationReceiptRecord>(
            predicate: #Predicate {
                $0.resultRecordType == type
                    && $0.resultRecordID == id
            }
        )
        descriptor.fetchLimit = 3
        return try modelContext.fetch(descriptor)
    }

    private func dataControlTimestamp(
        _ command: DeleteDataControlTargetCommand
    ) throws -> HistoricalTimestamp {
        guard let localDate = try? CivilDateFact(
            year: command.localYear,
            month: command.localMonth,
            day: command.localDay
        ),
        let localTime = try? HistoricalLocalTime(
            hour: command.localHour,
            minute: command.localMinute,
            second: command.localSecond,
            nanosecond: command.localNanosecond
        ),
        let precision = HistoricalTimestampPrecision(
            rawValue: command.precisionRawValue
        ),
        let provenance = HistoricalTimestampProvenance(
            rawValue: command.provenanceRawValue
        ),
        let timestamp = try? HistoricalTimestamp(
            validatingInstant: command.committedAt,
            localDate: localDate,
            localTime: localTime,
            timeZoneIdentifier: command.timeZoneIdentifier,
            utcOffsetSeconds: command.utcOffsetSeconds,
            precision: precision,
            provenance: provenance
        ) else {
            throw DataControlDeletionFailure.staleToken
        }
        return timestamp
    }

    private func validateDataControlReceiptLedgerBeforeWrite() throws {
        var receiptDescriptor = FetchDescriptor<OperationReceiptRecord>()
        receiptDescriptor.fetchLimit =
            DataInventoryTaxonomy.maximumRowsPerModel + 1
        let receipts = try modelContext.fetch(receiptDescriptor)
        guard receipts.count
                <= DataInventoryTaxonomy.maximumRowsPerModel else {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        var ledgerDescriptor =
            FetchDescriptor<OperationReceiptLedgerRecord>()
        ledgerDescriptor.fetchLimit = 2
        let ledgers = try modelContext.fetch(ledgerDescriptor)
        guard ledgers.count == 1,
              let ledger = ledgers.first,
              ledger.ledgerKey
                == OperationReceiptLedgerRecord.fixedKey,
              ledger.receiptCount == receipts.count,
              ledger.receiptSetDigest
                == (try TodayExecutionDigestV1.receiptSetDigest(
                    receipts
                )) else {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        if !receipts.isEmpty {
            do {
                try DataControlRelationshipValidator
                    .validateCurrentReceiptLedger(
                        in: modelContext,
                        failure: .corruptionSuspected
                    )
            } catch {
                throw DataControlDeletionFailure.corruptionSuspected
            }
        }
    }
}

extension AppReadActor {
    func dataControlAdministrationDeletionCandidates()
        throws -> [DataControlAdministrationDeletionCandidate] {
        try DataControlRelationshipValidator.validate(
            in: modelContext,
            failure: .corruptionSuspected
        )

        func boundedRows<T: PersistentModel>(
            _ type: T.Type
        ) throws -> [T] {
            let count = try modelContext.fetchCount(
                FetchDescriptor<T>()
            )
            guard count >= 0,
                  count
                    <= DataInventoryTaxonomy
                        .maximumRowsPerModel else {
                throw AppDataFailure.corruptionSuspected
            }
            var descriptor = FetchDescriptor<T>()
            descriptor.fetchLimit = count + 1
            let rows = try modelContext.fetch(descriptor)
            guard rows.count == count else {
                throw AppDataFailure.corruptionSuspected
            }
            return rows
        }

        let events = try boundedRows(
            AdministrationEventRecord.self
        )
        let times = try boundedRows(
            HistoricalTimeRecord.self
        ).filter {
            $0.sourceRecordType
                == "AdministrationEventRecord"
        }
        let items = try boundedRows(
            RegimenItemRecord.self
        )
        let schedules = try boundedRows(
            ScheduleRuleRecord.self
        )
        let timeByEventID = Dictionary(
            uniqueKeysWithValues: times.map {
                ($0.sourceRecordID, $0)
            }
        )
        guard timeByEventID.count == times.count else {
            throw AppDataFailure.corruptionSuspected
        }
        let itemByID = Dictionary(
            uniqueKeysWithValues: items.map {
                ($0.id, $0)
            }
        )
        let scheduleByID = Dictionary(
            uniqueKeysWithValues: schedules.map {
                ($0.id, $0)
            }
        )
        guard itemByID.count == items.count,
              scheduleByID.count
                == schedules.count else {
            throw AppDataFailure.corruptionSuspected
        }
        let grouped = Dictionary(
            grouping: events,
            by: \.occurrenceKey
        )
        return try grouped.map { key, chain in
            let supersededIDs = Set(
                chain.compactMap(\.supersedesEventID)
            )
            let leaves = chain.filter {
                !supersededIDs.contains($0.id)
            }
            guard leaves.count == 1,
                  let leaf = leaves.first,
                  let time = timeByEventID[leaf.id],
                  let timestamp =
                    time.historicalTimestamp,
                  let item = itemByID[
                      leaf.regimenItemID
                  ],
                  item.regimenVersionID
                    == leaf.regimenVersionID,
                  let schedule = scheduleByID[
                      leaf.scheduleRuleID
                  ],
                  schedule.regimenItemID
                    == item.id,
                  let identity =
                    ScheduleOccurrenceResolver
                    .identity(for: key),
                  identity.ruleID
                    == leaf.scheduleRuleID,
                  identity.revision
                    == leaf.scheduleRevision,
                  let resolvedZoneIdentifier =
                    dataControlOccurrenceZoneIdentifier(
                        identity: identity,
                        plannedInstant:
                            leaf.plannedInstant,
                        schedule: schedule
                    ),
                  let resolvedZone = TimeZone(
                      identifier:
                          resolvedZoneIdentifier
                  ) else {
                throw AppDataFailure.corruptionSuspected
            }
            return DataControlAdministrationDeletionCandidate(
                target: .administrationOccurrence(
                    DataControlOccurrenceProjection(
                        key: key,
                        scheduleRuleID:
                            leaf.scheduleRuleID,
                        scheduleRevision:
                            Int64(
                                leaf.scheduleRevision
                            ),
                        regimenVersionID:
                            leaf.regimenVersionID,
                        regimenItemID:
                            leaf.regimenItemID,
                        displayTimeZoneIdentifier:
                            resolvedZoneIdentifier,
                        localYear:
                            Int64(
                                identity.date.year
                            ),
                        localMonth:
                            Int64(
                                identity.date.month
                            ),
                        localDay:
                            Int64(
                                identity.date.day
                            ),
                        localHour:
                            Int64(
                                identity.time.hour
                            ),
                        localMinute:
                            Int64(
                                identity.time.minute
                            ),
                        localSecond:
                            Int64(
                                identity.time.second
                            ),
                        localNanosecond:
                            Int64(
                                identity.time
                                    .nanosecond
                            ),
                        resolvedTimeZoneIdentifier:
                            resolvedZoneIdentifier,
                        utcOffsetSeconds:
                            Int64(
                                resolvedZone
                                    .secondsFromGMT(
                                        for:
                                            leaf
                                                .plannedInstant
                                    )
                            ),
                        instant:
                            leaf.plannedInstant
                    )
                ),
                displayName: item.displayName,
                timestamp: timestamp
            )
        }
        .sorted {
            $0.timestamp.instant
                != $1.timestamp.instant
                ? $0.timestamp.instant
                    > $1.timestamp.instant
                : $0.target.stableKey
                    > $1.target.stableKey
        }
    }

    private func dataControlOccurrenceZoneIdentifier(
        identity: ScheduleOccurrenceIdentity,
        plannedInstant: Date,
        schedule: ScheduleRuleRecord
    ) -> String? {
        guard plannedInstant.timeIntervalSince1970
            .isFinite else {
            return nil
        }
        let sameRevision =
            schedule.revision == identity.revision
        if sameRevision,
           schedule.timeZoneBehavior == .fixedZone {
            guard let fixed =
                    schedule.fixedTimeZoneIdentifier,
                  dataControlOccurrence(
                      identity,
                      at: plannedInstant,
                      matches: fixed
                  ) else {
                return nil
            }
            return fixed
        }
        return DataControlOccurrenceZones
            .stableIdentifiers
            .first {
                dataControlOccurrence(
                    identity,
                    at: plannedInstant,
                    matches: $0
                )
        }
    }

    private func dataControlOccurrence(
        _ identity: ScheduleOccurrenceIdentity,
        at instant: Date,
        matches timeZoneIdentifier: String
    ) -> Bool {
        guard let timeZone = TimeZone(
            identifier: timeZoneIdentifier
        ) else {
            return false
        }
        var calendar = Calendar(
            identifier: .gregorian
        )
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [
                .year,
                .month,
                .day,
                .hour,
                .minute,
                .second,
                .nanosecond
            ],
            from: instant
        )
        return components.year == identity.date.year
            && components.month
                == identity.date.month
            && components.day == identity.date.day
            && components.hour
                == identity.time.hour
            && components.minute
                == identity.time.minute
            && components.second
                == identity.time.second
            && (components.nanosecond ?? 0)
                == identity.time.nanosecond
    }
}

extension AppWriteActor {
    func ensureDataControlHrtJourneyIsWritable() throws {
        guard try dataControlTombstone(
            targetKey: DataControlTargetKind.hrtJourney.targetKey(
                stableKey: "primary-hrt-journey"
            )
        ) == nil else {
            throw DataControlDeletionFailure.targetDeleted
        }
    }

    func ensureDataControlJourneyEntryIsWritable(
        _ entryID: UUID
    ) throws {
        try ensureDataControlTargetIsWritable(
            kind: .journeyEntry,
            stableKey: entryID.uuidString.lowercased(),
            targetID: entryID
        )
    }

    func ensureDataControlRegimenVersionIsWritable(
        _ versionID: UUID
    ) throws {
        let stableKey = versionID.uuidString.lowercased()
        for kind in [
            DataControlTargetKind.draftRegimenVersion,
            .sealedRegimenVersion
        ] {
            try ensureDataControlTargetIsWritable(
                kind: kind,
                stableKey: stableKey,
                targetID: versionID
            )
        }
    }

    func ensureDataControlRegimenLineageIsWritable(
        recordID: UUID
    ) throws {
        try ensureDataControlRegimenVersionIsWritable(recordID)
    }

    func ensureDataControlOccurrenceIsWritable(
        _ occurrence: PlannedOccurrence
    ) throws {
        try ensureDataControlTargetIsWritable(
            kind: .administrationOccurrence,
            stableKey: occurrence.key,
            targetID: nil
        )
        try ensureDataControlRegimenVersionIsWritable(
            occurrence.regimenVersionID
        )
    }

    func ensureDataControlHistoricalAssociationIsWritable(
        _ historical: HistoricalTimeRecord,
        proposedRegimenVersionID: UUID?
    ) throws {
        if let currentRegimenVersionID =
            historical.resolvedRegimenVersionID {
            try ensureDataControlRegimenVersionIsWritable(
                currentRegimenVersionID
            )
        }
        if let proposedRegimenVersionID {
            try ensureDataControlRegimenVersionIsWritable(
                proposedRegimenVersionID
            )
        }

        switch historical.sourceRecordType {
        case "JourneyEntry":
            try ensureDataControlJourneyEntryIsWritable(
                historical.sourceRecordID
            )
        case "AdministrationEventRecord":
            let eventID = historical.sourceRecordID
            var descriptor =
                FetchDescriptor<AdministrationEventRecord>(
                    predicate: #Predicate {
                        $0.id == eventID
                    }
                )
            descriptor.fetchLimit = 2
            let events = try modelContext.fetch(descriptor)
            guard events.count == 1,
                  let event = events.first else {
                throw DataControlDeletionFailure
                    .corruptionSuspected
            }
            try ensureDataControlTargetIsWritable(
                kind: .administrationOccurrence,
                stableKey: event.occurrenceKey,
                targetID: nil
            )
            try ensureDataControlRegimenVersionIsWritable(
                event.regimenVersionID
            )
        default:
            break
        }
    }

    func ensureDataControlScheduleRuleIsWritable(
        _ scheduleRuleID: UUID
    ) throws {
        var ruleDescriptor = FetchDescriptor<ScheduleRuleRecord>(
            predicate: #Predicate { $0.id == scheduleRuleID }
        )
        ruleDescriptor.fetchLimit = 2
        let rules = try modelContext.fetch(ruleDescriptor)
        guard rules.count == 1, let rule = rules.first else {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        let itemID = rule.regimenItemID
        var itemDescriptor = FetchDescriptor<RegimenItemRecord>(
            predicate: #Predicate { $0.id == itemID }
        )
        itemDescriptor.fetchLimit = 2
        let items = try modelContext.fetch(itemDescriptor)
        guard items.count == 1, let item = items.first else {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        try ensureDataControlRegimenVersionIsWritable(
            item.regimenVersionID
        )
    }

    func ensureDataControlAttachmentOwnerIsWritable(
        ownerType: AttachmentOwnerType,
        ownerID: UUID
    ) throws {
        if ownerType == .journeyEntry {
            try ensureDataControlJourneyEntryIsWritable(ownerID)
        }
    }

    func ensureDataControlAttachmentIsWritable(
        _ attachmentID: UUID
    ) throws {
        var descriptor = FetchDescriptor<AttachmentRecord>(
            predicate: #Predicate { $0.id == attachmentID }
        )
        descriptor.fetchLimit = 2
        let attachments = try modelContext.fetch(descriptor)
        guard attachments.count == 1,
              let attachment = attachments.first,
              let ownerType = attachment.ownerType else {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        try ensureDataControlAttachmentOwnerIsWritable(
            ownerType: ownerType,
            ownerID: attachment.ownerID
        )
    }

    private func ensureDataControlTargetIsWritable(
        kind: DataControlTargetKind,
        stableKey: String,
        targetID: UUID?
    ) throws {
        guard kind.validates(
            stableKey: stableKey,
            targetID: targetID
        ),
        try dataControlTombstone(
            targetKey: kind.targetKey(stableKey: stableKey)
        ) == nil else {
            throw DataControlDeletionFailure.targetDeleted
        }
    }
}

extension AppReadActor {
    func dataControlTerminalOverlay()
        throws -> DataControlTerminalOverlay {
        try DataControlDeletionRepository.terminalOverlay(
            in: modelContext
        )
    }

    func dataControlTerminalProjection()
        throws -> DataControlTerminalProjection {
        let overlay = try dataControlTerminalOverlay()
        var descriptor = FetchDescriptor<AdministrationEventRecord>()
        descriptor.fetchLimit =
            DataInventoryTaxonomy.maximumRowsPerModel + 1
        let events = try modelContext.fetch(descriptor)
        guard events.count
                <= DataInventoryTaxonomy.maximumRowsPerModel else {
            throw DataControlDeletionFailure.corruptionSuspected
        }
        return DataControlTerminalProjection(
            overlay: overlay,
            administrationEventIDs: Set(
                events.lazy.filter {
                    overlay.administrationOccurrenceKeys.contains(
                        $0.occurrenceKey
                    )
                }.map(\.id)
            )
        )
    }
}
