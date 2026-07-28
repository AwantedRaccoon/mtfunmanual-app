import Foundation
import SwiftData

struct OnboardingBackfillOutcome: Equatable, Sendable {
    let didComplete: Bool
    let didChangeStore: Bool
}

enum OnboardingBackfill {
    static func run(
        in container: ModelContainer,
        source: OnboardingBackfillSource,
        now: Date = Date()
    ) throws -> OnboardingBackfillOutcome {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard now.timeIntervalSince1970.isFinite else {
            throw AppDataFailure.migrationFailed
        }

        var stateDescriptor = FetchDescriptor<OnboardingBackfillState>()
        stateDescriptor.fetchLimit = 2
        let existingStates = try context.fetch(stateDescriptor)
        guard existingStates.count <= 1 else {
            throw AppDataFailure.migrationFailed
        }
        if let state = existingStates.first, state.completedAt != nil {
            guard OnboardingRelationshipValidator.validates(state) else {
                throw AppDataFailure.migrationFailed
            }
            try OnboardingRelationshipValidator.validate(
                in: context,
                failure: .migrationFailed
            )
            return OnboardingBackfillOutcome(
                didComplete: true,
                didChangeStore: false
            )
        }

        do {
            try context.transaction {
                var preferenceDescriptor =
                    FetchDescriptor<UserPreferencesRecord>()
                preferenceDescriptor.fetchLimit = 2
                let preferences = try context.fetch(preferenceDescriptor)
                guard preferences.count == 1,
                      let preference = preferences.first,
                      preference.singletonKey
                        == UserPreferencesRecord.fixedKey else {
                    throw AppDataFailure.migrationFailed
                }

                var progressDescriptor =
                    FetchDescriptor<OnboardingProgressRecord>()
                progressDescriptor.fetchLimit = 2
                let existingProgress = try context.fetch(progressDescriptor)
                guard existingProgress.count <= 1,
                      existingProgress.first.map(
                        OnboardingRelationshipValidator.validates
                      ) != false,
                      existingStates.first.map({
                          validatesIncompleteState(
                              $0,
                              expectedSource: source
                          )
                      }) != false else {
                    throw AppDataFailure.migrationFailed
                }

                let isCompleted = source.treatsUserAsAlreadyOnboarded
                preference.onboardingCompleted = isCompleted
                let progress = existingProgress.first
                    ?? OnboardingProgressRecord(
                        step: isCompleted ? .completed : .privacy,
                        completedAt: isCompleted ? now : nil,
                        updatedAt: now
                    )
                if existingProgress.isEmpty {
                    context.insert(progress)
                } else {
                    progress.contractVersion =
                        OnboardingProgressRecord.contractVersion
                    progress.stepRawValue = (
                        isCompleted
                            ? OnboardingStep.completed
                            : OnboardingStep.privacy
                    ).rawValue
                    progress.skippedStartDate = false
                    progress.skippedReminder = false
                    progress.skippedCountdown = false
                    progress.completedAt = isCompleted ? now : nil
                    progress.updatedAt = now
                }

                let state = existingStates.first
                    ?? OnboardingBackfillState(
                        source: source,
                        completedAt: now,
                        updatedAt: now
                    )
                if existingStates.isEmpty {
                    context.insert(state)
                } else {
                    state.sourceRawValue = source.rawValue
                    state.completedAt = now
                    state.updatedAt = now
                }

                try insertRevisions(
                    preference: preference,
                    progress: progress,
                    state: state,
                    in: context,
                    committedAt: now
                )
                try OnboardingRelationshipValidator.validate(
                    in: context,
                    failure: .migrationFailed
                )
                try context.save()
            }
            try OnboardingRelationshipValidator.validate(
                in: context,
                failure: .migrationFailed
            )
            return OnboardingBackfillOutcome(
                didComplete: true,
                didChangeStore: true
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func validatesIncompleteState(
        _ value: OnboardingBackfillState,
        expectedSource: OnboardingBackfillSource
    ) -> Bool {
        value.taskKey == OnboardingBackfillState.fixedKey
            && value.source == expectedSource
            && value.completedAt == nil
            && value.updatedAt.timeIntervalSince1970.isFinite
    }

    private static func insertRevisions(
        preference: UserPreferencesRecord,
        progress: OnboardingProgressRecord,
        state: OnboardingBackfillState,
        in context: ModelContext,
        committedAt: Date
    ) throws {
        var metadataDescriptor = FetchDescriptor<DatasetMetadata>()
        metadataDescriptor.fetchLimit = 2
        let metadataRecords = try context.fetch(metadataDescriptor)
        guard metadataRecords.count == 1,
              let metadata = metadataRecords.first,
              metadata.nextLocalRevision > 0,
              metadata.nextLocalRevision < Int64.max - 1 else {
            throw AppDataFailure.migrationFailed
        }
        let sharedRevision = metadata.nextLocalRevision

        let facts: [(
            recordType: String,
            recordID: UUID,
            fields: [RecordDigestV1.Field]
        )] = [
            (
                "UserPreferencesRecord",
                CoreTimeRegimenBackfill.stableUUID(
                    for: preference.singletonKey
                ),
                CoreFactDigestV1.preferences(preference)
            ),
            (
                "OnboardingProgressRecord",
                CoreTimeRegimenBackfill.stableUUID(
                    for: progress.singletonKey
                ),
                try OnboardingDigestV1.progress(progress)
            ),
            (
                "OnboardingBackfillState",
                CoreTimeRegimenBackfill.stableUUID(for: state.taskKey),
                try OnboardingDigestV1.backfillState(state)
            )
        ]

        for fact in facts {
            let recordKey = fact.recordType
                + ":"
                + fact.recordID.uuidString.lowercased()
            let digest = try RecordDigestV1.sha256Hex(
                recordType: fact.recordType,
                recordID: fact.recordID,
                fields: fact.fields
            )
            let expectedKey = recordKey
            var revisionDescriptor = FetchDescriptor<RecordRevision>(
                predicate: #Predicate {
                    $0.recordKey == expectedKey
                }
            )
            revisionDescriptor.fetchLimit = 2
            let existingRevisions = try context.fetch(
                revisionDescriptor
            )
            guard existingRevisions.count <= 1 else {
                throw AppDataFailure.migrationFailed
            }
            if let revision = existingRevisions.first {
                revision.datasetID = metadata.datasetID
                revision.localRevision = sharedRevision
                revision.digestVersion = RecordDigestV1.version
                revision.digestHex = digest
                revision.committedAt = committedAt
            } else {
                let revision = RecordRevision(
                    recordKey: recordKey,
                    recordType: fact.recordType,
                    recordID: fact.recordID,
                    datasetID: metadata.datasetID,
                    localRevision: sharedRevision,
                    digestVersion: RecordDigestV1.version,
                    digestHex: digest,
                    committedAt: committedAt
                )
                context.insert(revision)
            }
        }
        metadata.nextLocalRevision += 1
        metadata.lastCommittedAt = committedAt
    }
}
