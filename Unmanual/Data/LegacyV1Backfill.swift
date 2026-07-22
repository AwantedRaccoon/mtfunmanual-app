import Foundation
import SwiftData

enum LegacyV1Backfill {
    enum Interruption: Error, Equatable {
        case injected
    }

    struct Outcome: Equatable, Sendable {
        let didComplete: Bool
        let didChangeStore: Bool
        let processedRecordCount: Int
    }

    private struct SourceRecord {
        let id: UUID
        let recordType: String
        let createdAt: Date
        let fields: [RecordDigestV1.Field]

        var recordKey: String {
            recordType + ":" + id.uuidString.lowercased()
        }
    }

    static func run(
        in container: ModelContainer,
        batchSize: Int = 128,
        interruptAfterCommittedBatches: Int? = nil,
        now: Date = Date()
    ) throws -> Outcome {
        precondition(batchSize > 0)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var didChangeStore = false
        var committedBatches = 0

        var metadata = try context.fetch(FetchDescriptor<DatasetMetadata>()).first
        var state = try context.fetch(FetchDescriptor<MigrationBackfillState>()).first
        if metadata == nil || state == nil {
            try context.transaction {
                if metadata == nil {
                    let created = DatasetMetadata(createdAt: now)
                    context.insert(created)
                    metadata = created
                }
                if state == nil {
                    let created = MigrationBackfillState(updatedAt: now)
                    context.insert(created)
                    state = created
                }
            }
            didChangeStore = true
        }

        guard let metadata, let state else {
            throw AppDataFailure.migrationFailed
        }

        if state.phase == .complete {
            return Outcome(
                didComplete: true,
                didChangeStore: didChangeStore,
                processedRecordCount: try context.fetchCount(FetchDescriptor<RecordRevision>())
            )
        }

        while state.phase != .complete {
            if state.phase == .issues {
                try scanIssues(in: context, state: state, now: now)
                didChangeStore = true
                continue
            }

            let records = try fetchSourceRecords(
                phase: state.phase,
                offset: state.processedCountInPhase,
                limit: batchSize,
                in: context
            )

            if records.isEmpty {
                try context.transaction {
                    state.phase = nextPhase(after: state.phase)
                    state.processedCountInPhase = 0
                    state.updatedAt = now
                }
                didChangeStore = true
                continue
            }

            let startingRevision = metadata.nextLocalRevision
            guard startingRevision > 0,
                  startingRevision < Int64.max,
                  let recordCount = Int64(exactly: records.count),
                  recordCount <= Int64.max - startingRevision else {
                throw AppDataFailure.migrationFailed
            }
            let digests = try records.map { record in
                try RecordDigestV1.sha256Hex(
                    recordType: record.recordType,
                    recordID: record.id,
                    fields: record.fields
                )
            }

            do {
                try context.transaction {
                    for (index, record) in records.enumerated() {
                        context.insert(
                            RecordRevision(
                                recordKey: record.recordKey,
                                recordType: record.recordType,
                                recordID: record.id,
                                datasetID: metadata.datasetID,
                                localRevision: startingRevision + Int64(index),
                                digestVersion: RecordDigestV1.version,
                                digestHex: digests[index],
                                committedAt: now
                            )
                        )
                    }
                    metadata.nextLocalRevision += recordCount
                    metadata.lastCommittedAt = now
                    state.processedCountInPhase += records.count
                    state.updatedAt = now
                }
            } catch {
                context.rollback()
                throw error
            }

            didChangeStore = true
            committedBatches += 1
            if interruptAfterCommittedBatches == committedBatches {
                throw Interruption.injected
            }
        }

        return Outcome(
            didComplete: true,
            didChangeStore: didChangeStore,
            processedRecordCount: try context.fetchCount(FetchDescriptor<RecordRevision>())
        )
    }

    private static func fetchSourceRecords(
        phase: MigrationBackfillPhase,
        offset: Int,
        limit: Int,
        in context: ModelContext
    ) throws -> [SourceRecord] {
        switch phase {
        case .hrtProfiles:
            var descriptor = FetchDescriptor<HRTProfile>(
                sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = limit
            return try context.fetch(descriptor).map { model in
                SourceRecord(
                    id: model.id,
                    recordType: "HRTProfile",
                    createdAt: model.createdAt,
                    fields: try FactDigestV1.profile(model)
                )
            }
        case .countdowns:
            var descriptor = FetchDescriptor<CountdownRecord>(
                sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = limit
            return try context.fetch(descriptor).map { model in
                SourceRecord(
                    id: model.id,
                    recordType: "CountdownRecord",
                    createdAt: model.createdAt,
                    fields: try FactDigestV1.countdown(model)
                )
            }
        case .regimens:
            var descriptor = FetchDescriptor<RegimenVersion>(
                sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = limit
            return try context.fetch(descriptor).map { model in
                SourceRecord(
                    id: model.id,
                    recordType: "RegimenVersion",
                    createdAt: model.createdAt,
                    fields: try FactDigestV1.regimen(model)
                )
            }
        case .journeyEntries:
            var descriptor = FetchDescriptor<JourneyEntry>(
                sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = limit
            return try context.fetch(descriptor).map { model in
                SourceRecord(
                    id: model.id,
                    recordType: "JourneyEntry",
                    createdAt: model.createdAt,
                    fields: try FactDigestV1.journey(model)
                )
            }
        case .labRecords:
            var descriptor = FetchDescriptor<LabRecord>(
                sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = limit
            return try context.fetch(descriptor).map { model in
                SourceRecord(
                    id: model.id,
                    recordType: "LabRecord",
                    createdAt: model.createdAt,
                    fields: try FactDigestV1.lab(model)
                )
            }
        case .issues, .complete:
            return []
        }
    }

    private static func scanIssues(
        in context: ModelContext,
        state: MigrationBackfillState,
        now: Date
    ) throws {
        let existingKeys = Set(try context.fetch(FetchDescriptor<MigrationIssue>()).map(\.issueKey))
        var issues: [(MigrationIssueKind, String, UUID?)] = []

        let profiles = try context.fetch(FetchDescriptor<HRTProfile>())
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        for profile in profiles.dropFirst() {
            issues.append((.duplicateProfile, "HRTProfile", profile.id))
        }

        let regimens = try context.fetch(FetchDescriptor<RegimenVersion>())
            .sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
        for index in regimens.indices.dropFirst() {
            let prior = regimens[index - 1]
            let current = regimens[index]
            if prior.endedAt.map({ current.startedAt < $0 }) ?? true {
                issues.append((.overlappingRegimen, "RegimenVersion", current.id))
            }
        }

        let regimenIDs = Set(regimens.map(\.id))
        let journeys = try context.fetch(FetchDescriptor<JourneyEntry>())
        for journey in journeys where journey.regimenVersionID.map({ !regimenIDs.contains($0) }) == true {
            issues.append((.orphanedRegimenReference, "JourneyEntry", journey.id))
        }
        let labs = try context.fetch(FetchDescriptor<LabRecord>())
        for lab in labs where lab.regimenVersionID.map({ !regimenIDs.contains($0) }) == true {
            issues.append((.orphanedRegimenReference, "LabRecord", lab.id))
        }

        let earliestPlausible = Date(timeIntervalSince1970: 946_684_800)
        let latestPlausible = Calendar(identifier: .gregorian)
            .date(byAdding: .year, value: 5, to: now) ?? now
        let datedRecords: [(String, UUID, Date)] =
            profiles.map { ("HRTProfile", $0.id, $0.createdAt) }
            + regimens.map { ("RegimenVersion", $0.id, $0.createdAt) }
            + journeys.map { ("JourneyEntry", $0.id, $0.createdAt) }
            + labs.map { ("LabRecord", $0.id, $0.createdAt) }
        for (recordType, id, date) in datedRecords where date < earliestPlausible || date > latestPlausible {
            issues.append((.implausibleTimestamp, recordType, id))
        }

        try context.transaction {
            for (kind, recordType, recordID) in issues {
                let issueKey = [kind.rawValue, recordType, recordID?.uuidString.lowercased() ?? "none"]
                    .joined(separator: ":")
                guard !existingKeys.contains(issueKey) else { continue }
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
            state.phase = .complete
            state.processedCountInPhase = 0
            state.updatedAt = now
            state.completedAt = now
        }
    }

    private static func nextPhase(after phase: MigrationBackfillPhase) -> MigrationBackfillPhase {
        switch phase {
        case .hrtProfiles: .countdowns
        case .countdowns: .regimens
        case .regimens: .journeyEntries
        case .journeyEntries: .labRecords
        case .labRecords: .issues
        case .issues, .complete: .complete
        }
    }

}

enum AppDataFailure: Error, Equatable, Sendable {
    case protectedDataUnavailable
    case storageUnavailable
    case migrationFailed
    case corruptionSuspected
    case invalidGenerationPointer
    case fileProtectionUnverified
}

extension AppDataFailure {
    static func classifyStorage(
        _ error: Error,
        fallback: AppDataFailure
    ) -> AppDataFailure {
        if let failure = error as? AppDataFailure {
            return failure
        }
        return classifyNSError(error as NSError, depth: 0) ?? fallback
    }

    private static func classifyNSError(
        _ nsError: NSError,
        depth: Int
    ) -> AppDataFailure? {
        guard depth < 8 else { return nil }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .protectedDataUnavailable
            case NSFileWriteOutOfSpaceError:
                return .storageUnavailable
            default:
                break
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           let classified = classifyNSError(underlying, depth: depth + 1) {
            return classified
        }
        if let detailedErrors = nsError.userInfo["NSDetailedErrors"] as? [NSError] {
            for detailedError in detailedErrors {
                if let classified = classifyNSError(detailedError, depth: depth + 1) {
                    return classified
                }
            }
        }
        return nil
    }
}
