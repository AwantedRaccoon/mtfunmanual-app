import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class OnboardingTests: XCTestCase {
    func testNewInstallStartsAtPrivacyAndUpgradeIsGrandfathered()
        async throws {
        let newInstall = try makeContainer(
            source: .newInstallV8
        )
        let newReader = AppReadActor(modelContainer: newInstall)
        let newSnapshot = try await newReader.onboardingSnapshot(
            asOf: Date(timeIntervalSince1970: 1_774_000_000),
            displayTimeZoneIdentifier: "UTC"
        )

        XCTAssertFalse(newSnapshot.isCompleted)
        XCTAssertEqual(newSnapshot.progress.step, .privacy)
        XCTAssertNil(newSnapshot.progress.completedAt)

        let upgraded = try makeContainer(
            source: .schemaUpgradeV7
        )
        let upgradedReader = AppReadActor(modelContainer: upgraded)
        let upgradedSnapshot = try await upgradedReader
            .onboardingSnapshot(
                asOf: Date(timeIntervalSince1970: 1_774_000_000),
                displayTimeZoneIdentifier: "UTC"
            )

        XCTAssertTrue(upgradedSnapshot.isCompleted)
        XCTAssertEqual(upgradedSnapshot.progress.step, .completed)
        XCTAssertNotNil(upgradedSnapshot.progress.completedAt)
    }

    func testOnboardingBackfillSharesOneRevisionAcrossAtomicFacts()
        throws {
        for source in [
            OnboardingBackfillSource.newInstallV8,
            .legacyAdoption,
            .schemaUpgradeV7,
        ] {
            let container = try AppModelContainerFactory
                .makeInMemoryCountdownLifecycleContainer()
            _ = try LegacyV1Backfill.run(in: container)
            _ = try CoreTimeRegimenBackfill.run(
                in: container,
                assumedTimeZoneIdentifier: "UTC"
            )
            _ = try TodayExecutionBackfill.run(in: container)
            _ = try PersonalTimelineBackfill.run(in: container)
            _ = try CountdownLifecycleBackfill.run(in: container)

            let beforeContext = ModelContext(container)
            let beforeNextRevision = try XCTUnwrap(
                beforeContext.fetch(
                    FetchDescriptor<DatasetMetadata>()
                ).first
            ).nextLocalRevision

            _ = try OnboardingBackfill.run(
                in: container,
                source: source,
                now: Date(timeIntervalSince1970: 1_774_000_000)
            )

            let afterContext = ModelContext(container)
            let metadata = try XCTUnwrap(
                afterContext.fetch(
                    FetchDescriptor<DatasetMetadata>()
                ).first
            )
            let revisions = try afterContext.fetch(
                FetchDescriptor<RecordRevision>()
            ).filter {
                [
                    "UserPreferencesRecord",
                    "OnboardingProgressRecord",
                    "OnboardingBackfillState",
                ].contains($0.recordType)
            }

            XCTAssertEqual(revisions.count, 3, source.rawValue)
            XCTAssertEqual(
                Set(revisions.map(\.localRevision)).count,
                1,
                source.rawValue
            )
            XCTAssertEqual(
                revisions.first?.localRevision,
                beforeNextRevision,
                source.rawValue
            )
            XCTAssertEqual(
                metadata.nextLocalRevision,
                beforeNextRevision + 1,
                source.rawValue
            )
        }
    }

    func testOnboardingBackfillRejectsMalformedProgressWithoutMutation()
        throws {
        let container = try makePreOnboardingContainer()
        let context = ModelContext(container)
        context.insert(
            OnboardingProgressRecord(
                singletonKey: "unexpected-progress-key",
                step: .privacy,
                updatedAt: Date(timeIntervalSince1970: 1_773_999_900)
            )
        )
        try context.save()
        let before = try onboardingBackfillFacts(in: container)

        XCTAssertThrowsError(
            try OnboardingBackfill.run(
                in: container,
                source: .newInstallV8,
                now: Date(timeIntervalSince1970: 1_774_000_000)
            )
        ) {
            XCTAssertEqual($0 as? AppDataFailure, .migrationFailed)
        }
        XCTAssertEqual(try onboardingBackfillFacts(in: container), before)
    }

    func testOnboardingBackfillRejectsMalformedIncompleteStateWithoutMutation()
        throws {
        let container = try makePreOnboardingContainer()
        let context = ModelContext(container)
        context.insert(
            OnboardingBackfillState(
                taskKey: "unexpected-backfill-key",
                source: .newInstallV8,
                completedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 1_773_999_900)
            )
        )
        try context.save()
        let before = try onboardingBackfillFacts(in: container)

        XCTAssertThrowsError(
            try OnboardingBackfill.run(
                in: container,
                source: .newInstallV8,
                now: Date(timeIntervalSince1970: 1_774_000_000)
            )
        ) {
            XCTAssertEqual($0 as? AppDataFailure, .migrationFailed)
        }
        XCTAssertEqual(try onboardingBackfillFacts(in: container), before)
    }

    func testOnboardingBackfillRejectsExhaustedRevisionWithoutMutation()
        throws {
        let container = try makePreOnboardingContainer()
        let context = ModelContext(container)
        let metadata = try XCTUnwrap(
            context.fetch(FetchDescriptor<DatasetMetadata>()).first
        )
        metadata.nextLocalRevision = Int64.max - 1
        try context.save()
        let before = try onboardingBackfillFacts(in: container)

        XCTAssertThrowsError(
            try OnboardingBackfill.run(
                in: container,
                source: .newInstallV8,
                now: Date(timeIntervalSince1970: 1_774_000_000)
            )
        ) {
            XCTAssertEqual($0 as? AppDataFailure, .migrationFailed)
        }
        XCTAssertEqual(try onboardingBackfillFacts(in: container), before)
    }

    func testOnboardingProgressRequiresSealedRegimenAndCompletesAtomically()
        async throws {
        let container = try makeContainer(source: .newInstallV8)
        let writer = AppWriteActor(modelContainer: container)
        let committedAt = Date(timeIntervalSince1970: 1_774_000_000)

        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .privacy,
                action: .reviewPrivacy,
                committedAt: committedAt
            )
        )
        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .startDate,
                action: .continueStartDate(skipped: true),
                committedAt: committedAt.addingTimeInterval(1)
            )
        )

        do {
            _ = try await writer.updateOnboardingProgress(
                UpdateOnboardingProgressCommand(
                    expectedStep: .regimen,
                    action: .continueRegimen,
                    committedAt: committedAt.addingTimeInterval(2)
                )
            )
            XCTFail("未封存方案不得越过必填步骤")
        } catch {
            XCTAssertEqual(error as? AppWriteFailure, .staleRecord)
        }

        let draftID = UUID()
        let scheduleID = UUID()
        try await writer.saveRegimenDraft(
            SaveRegimenDraftCommand(
                recordID: draftID,
                previousVersionID: nil,
                code: "ONBOARDING-01",
                title: "当前方案",
                effectiveStartDate: try CivilDateFact(
                    year: 2026,
                    month: 1,
                    day: 1
                ),
                changeReason: "首次设置",
                items: [
                    RegimenItemInput(
                        displayName: "自定义项目",
                        schedule: RegimenScheduleInput(
                            id: scheduleID,
                            kind: .dailyTimes,
                            localTimes: "09:00"
                        )
                    )
                ],
                committedAt: committedAt.addingTimeInterval(3)
            )
        )
        let preview = try await writer.previewRegimenChange(
            draftID: draftID
        )
        try await writer.sealRegimenDraft(
            SealRegimenDraftCommand(
                draftID: draftID,
                expectedNextLocalRevision:
                    preview.expectedNextLocalRevision,
                draftDigest: preview.draftDigest,
                committedAt: committedAt.addingTimeInterval(4)
            )
        )

        let reader = AppReadActor(modelContainer: container)
        let setup = try await reader.onboardingSnapshot(
            asOf: committedAt.addingTimeInterval(5),
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertTrue(setup.hasEligibleRegimen)
        XCTAssertEqual(setup.reminderOptions.count, 1)
        XCTAssertEqual(
            setup.reminderOptions.first?.scheduleRuleID,
            scheduleID
        )
        XCTAssertEqual(
            setup.reminderOptions.first?.scheduleRevision,
            1
        )

        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .regimen,
                action: .continueRegimen,
                committedAt: committedAt.addingTimeInterval(5)
            )
        )
        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .reminder,
                action: .continueReminder(skipped: true),
                committedAt: committedAt.addingTimeInterval(6)
            )
        )
        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .countdown,
                action: .continueCountdown(skipped: true),
                committedAt: committedAt.addingTimeInterval(7)
            )
        )
        let result = try await writer.completeOnboarding(
            CompleteOnboardingCommand(
                committedAt: committedAt.addingTimeInterval(8)
            )
        )
        XCTAssertTrue(result.didApply)

        let completed = try await reader.onboardingSnapshot(
            asOf: committedAt.addingTimeInterval(9),
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertTrue(completed.isCompleted)
        XCTAssertEqual(completed.progress.step, .completed)
        XCTAssertTrue(completed.progress.skippedStartDate)
        XCTAssertTrue(completed.progress.skippedReminder)
        XCTAssertTrue(completed.progress.skippedCountdown)

        let context = ModelContext(container)
        let progress = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<OnboardingProgressRecord>()
            ).first
        )
        let preference = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<UserPreferencesRecord>()
            ).first
        )
        let revisions = try context.fetch(
            FetchDescriptor<RecordRevision>()
        )
        let progressID = CoreTimeRegimenBackfill.stableUUID(
            for: progress.singletonKey
        )
        let preferenceID = CoreTimeRegimenBackfill.stableUUID(
            for: preference.singletonKey
        )
        let progressRevision = try XCTUnwrap(
            revisions.first {
                $0.recordType == "OnboardingProgressRecord"
                    && $0.recordID == progressID
            }
        )
        let preferenceRevision = try XCTUnwrap(
            revisions.first {
                $0.recordType == "UserPreferencesRecord"
                    && $0.recordID == preferenceID
            }
        )
        XCTAssertEqual(
            progressRevision.localRevision,
            preferenceRevision.localRevision
        )
        XCTAssertEqual(
            progressRevision.digestHex,
            try RecordDigestV1.sha256Hex(
                recordType: "OnboardingProgressRecord",
                recordID: progressID,
                fields: OnboardingDigestV1.progress(progress)
            )
        )
        XCTAssertEqual(
            preferenceRevision.digestHex,
            try RecordDigestV1.sha256Hex(
                recordType: "UserPreferencesRecord",
                recordID: preferenceID,
                fields: CoreFactDigestV1.preferences(preference)
            )
        )
    }

    func testCompletionFailureRollsBackPreferenceAndProgress()
        async throws {
        let container = try await makeReadyContainer()
        let writer = AppWriteActor(modelContainer: container)
        let beforeContext = ModelContext(container)
        let beforeMetadata = try XCTUnwrap(
            beforeContext.fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        )
        let beforeNextRevision = beforeMetadata.nextLocalRevision
        let beforeLastCommittedAt = beforeMetadata.lastCommittedAt
        let beforeRevisions = try revisionFacts(in: beforeContext)

        do {
            _ = try await writer.completeOnboarding(
                CompleteOnboardingCommand(
                    committedAt: Date(
                        timeIntervalSince1970: 1_774_000_100
                    )
                ),
                failureInjection: .beforeRevisionCommit
            )
            XCTFail("注入失败必须回滚完成事务")
        } catch {
            XCTAssertEqual(error as? AppWriteFailure, .injected)
        }

        let context = ModelContext(container)
        let preference = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<UserPreferencesRecord>()
            ).first
        )
        let progress = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<OnboardingProgressRecord>()
            ).first
        )
        XCTAssertFalse(preference.onboardingCompleted)
        XCTAssertEqual(progress.step, .ready)
        XCTAssertNil(progress.completedAt)
        let metadata = try XCTUnwrap(
            context.fetch(FetchDescriptor<DatasetMetadata>()).first
        )
        XCTAssertEqual(metadata.nextLocalRevision, beforeNextRevision)
        XCTAssertEqual(metadata.lastCommittedAt, beforeLastCommittedAt)
        XCTAssertEqual(try revisionFacts(in: context), beforeRevisions)
    }

    func testProgressFailureAndStaleStepLeaveMetadataAndRevisionsUnchanged()
        async throws {
        let container = try makeContainer(source: .newInstallV8)
        let writer = AppWriteActor(modelContainer: container)
        let context = ModelContext(container)
        let beforeMetadata = try XCTUnwrap(
            context.fetch(FetchDescriptor<DatasetMetadata>()).first
        )
        let beforeNextRevision = beforeMetadata.nextLocalRevision
        let beforeLastCommittedAt = beforeMetadata.lastCommittedAt
        let beforeRevisions = try revisionFacts(in: context)

        do {
            _ = try await writer.updateOnboardingProgress(
                UpdateOnboardingProgressCommand(
                    expectedStep: .privacy,
                    action: .reviewPrivacy,
                    committedAt: Date(
                        timeIntervalSince1970: 1_774_000_010
                    )
                ),
                failureInjection: .beforeRevisionCommit
            )
            XCTFail("注入失败必须回滚进度与 metadata")
        } catch {
            XCTAssertEqual(error as? AppWriteFailure, .injected)
        }
        do {
            _ = try await writer.updateOnboardingProgress(
                UpdateOnboardingProgressCommand(
                    expectedStep: .startDate,
                    action: .continueStartDate(skipped: true),
                    committedAt: Date(
                        timeIntervalSince1970: 1_774_000_011
                    )
                )
            )
            XCTFail("过期 expected step 不得推进")
        } catch {
            XCTAssertEqual(error as? AppWriteFailure, .staleRecord)
        }

        let afterContext = ModelContext(container)
        let progress = try XCTUnwrap(
            afterContext.fetch(
                FetchDescriptor<OnboardingProgressRecord>()
            ).first
        )
        let metadata = try XCTUnwrap(
            afterContext.fetch(
                FetchDescriptor<DatasetMetadata>()
            ).first
        )
        XCTAssertEqual(progress.step, .privacy)
        XCTAssertEqual(metadata.nextLocalRevision, beforeNextRevision)
        XCTAssertEqual(metadata.lastCommittedAt, beforeLastCommittedAt)
        XCTAssertEqual(
            try revisionFacts(in: afterContext),
            beforeRevisions
        )
    }

    func testReadyReopenReconcilesStartDateAndReminderSkipFacts()
        async throws {
        let container = try await makeReadyContainer()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let base = Date(timeIntervalSince1970: 1_774_000_200)

        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .ready,
                action: .reopen(.startDate),
                committedAt: base
            )
        )
        var snapshot = try await reader.onboardingSnapshot(
            asOf: base.addingTimeInterval(0.5),
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertEqual(snapshot.progress.step, .startDate)
        XCTAssertFalse(snapshot.progress.skippedStartDate)
        try await writer.setStartDate(
            SetStartDateCommand(
                startDate: base,
                timeZoneIdentifier: "UTC",
                committedAt: base.addingTimeInterval(1)
            )
        )
        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .startDate,
                action: .continueStartDate(skipped: false),
                committedAt: base.addingTimeInterval(2)
            )
        )
        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .regimen,
                action: .continueRegimen,
                committedAt: base.addingTimeInterval(3)
            )
        )
        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .reminder,
                action: .continueReminder(skipped: true),
                committedAt: base.addingTimeInterval(4)
            )
        )
        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .countdown,
                action: .continueCountdown(skipped: true),
                committedAt: base.addingTimeInterval(5)
            )
        )

        snapshot = try await reader.onboardingSnapshot(
            asOf: base.addingTimeInterval(6),
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertFalse(snapshot.progress.skippedStartDate)
        let option = try XCTUnwrap(snapshot.reminderOptions.first)

        do {
            _ = try await writer.setReminderPreference(
                SetReminderPreferenceCommand(
                    operationID: UUID(),
                    scheduleRuleID: option.scheduleRuleID,
                    expectedRuleRevision: option.scheduleRevision + 1,
                    isEnabled: true,
                    defaultSnoozeMinutes:
                        option.defaultSnoozeMinutes,
                    committedAt: base.addingTimeInterval(7)
                )
            )
            XCTFail("错误 schedule revision 不得开启提醒")
        } catch {
            XCTAssertEqual(
                error as? TodayExecutionWriteFailure,
                .invalidOccurrence
            )
        }

        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .ready,
                action: .reopen(.reminder),
                committedAt: base.addingTimeInterval(8)
            )
        )
        snapshot = try await reader.onboardingSnapshot(
            asOf: base.addingTimeInterval(8.5),
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertEqual(snapshot.progress.step, .reminder)
        XCTAssertFalse(snapshot.progress.skippedReminder)
        _ = try await writer.setReminderPreference(
            SetReminderPreferenceCommand(
                operationID: UUID(),
                scheduleRuleID: option.scheduleRuleID,
                expectedRuleRevision: option.scheduleRevision,
                isEnabled: true,
                defaultSnoozeMinutes: option.defaultSnoozeMinutes,
                committedAt: base.addingTimeInterval(9)
            )
        )
        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .reminder,
                action: .continueReminder(skipped: false),
                committedAt: base.addingTimeInterval(10)
            )
        )
        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .countdown,
                action: .continueCountdown(skipped: true),
                committedAt: base.addingTimeInterval(11)
            )
        )

        snapshot = try await reader.onboardingSnapshot(
            asOf: base.addingTimeInterval(12),
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertTrue(snapshot.hasEnabledReminder)
        XCTAssertFalse(snapshot.progress.skippedReminder)

        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .ready,
                action: .reopen(.countdown),
                committedAt: base.addingTimeInterval(13)
            )
        )
        snapshot = try await reader.onboardingSnapshot(
            asOf: base.addingTimeInterval(14),
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertEqual(snapshot.progress.step, .countdown)
        XCTAssertFalse(snapshot.progress.skippedCountdown)
    }

    func testReopenRegimenAndMoveBackTraverseEveryPersistedStep()
        async throws {
        let container = try await makeReadyContainer()
        let writer = AppWriteActor(modelContainer: container)
        let base = Date(timeIntervalSince1970: 1_774_000_300)

        var result = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .ready,
                action: .reopen(.regimen),
                committedAt: base
            )
        )
        XCTAssertEqual(result.step, .regimen)

        result = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .regimen,
                action: .continueRegimen,
                committedAt: base.addingTimeInterval(1)
            )
        )
        XCTAssertEqual(result.step, .reminder)
        result = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .reminder,
                action: .continueReminder(skipped: true),
                committedAt: base.addingTimeInterval(2)
            )
        )
        XCTAssertEqual(result.step, .countdown)
        result = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .countdown,
                action: .continueCountdown(skipped: true),
                committedAt: base.addingTimeInterval(3)
            )
        )
        XCTAssertEqual(result.step, .ready)

        for (offset, expected, target) in [
            (4.0, OnboardingStep.ready, OnboardingStep.countdown),
            (5.0, .countdown, .reminder),
            (6.0, .reminder, .regimen),
            (7.0, .regimen, .startDate),
            (8.0, .startDate, .privacy),
        ] {
            result = try await writer.updateOnboardingProgress(
                UpdateOnboardingProgressCommand(
                    expectedStep: expected,
                    action: .moveBack,
                    committedAt: base.addingTimeInterval(offset)
                )
            )
            XCTAssertEqual(result.step, target)
        }
    }

    func testCountdownOptionalStepCanPersistARealCountdownInsteadOfSkip()
        async throws {
        let container = try await makeReadyContainer()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let base = Date(timeIntervalSince1970: 1_774_000_400)

        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .ready,
                action: .moveBack,
                committedAt: base
            )
        )
        let timestamp = try HistoricalTimestamp.captured(
            instant: base.addingTimeInterval(1),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        _ = try await writer.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                title: "首次设置目标",
                gentleTitle: nil,
                targetDate: try CivilDateFact(
                    year: 2026,
                    month: 8,
                    day: 1
                ),
                showInToday: true,
                reminder: .disabled,
                timestamp: timestamp
            )
        )
        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .countdown,
                action: .continueCountdown(skipped: false),
                committedAt: base.addingTimeInterval(2)
            )
        )

        let snapshot = try await reader.onboardingSnapshot(
            asOf: base.addingTimeInterval(3),
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertEqual(snapshot.progress.step, .ready)
        XCTAssertFalse(snapshot.progress.skippedCountdown)
        XCTAssertEqual(snapshot.countdown?.displayTitle, "首次设置目标")
    }

    func testOnboardingReadFailsClosedWhenCompletionFactsDisagree()
        async throws {
        let container = try makeContainer(source: .newInstallV8)
        let context = ModelContext(container)
        let preference = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<UserPreferencesRecord>()
            ).first
        )
        preference.onboardingCompleted = true
        try context.save()

        let reader = AppReadActor(modelContainer: container)
        do {
            _ = try await reader.onboardingSnapshot(
                displayTimeZoneIdentifier: "UTC"
            )
            XCTFail("不一致的终态不得打开 shell")
        } catch {
            XCTAssertEqual(
                error as? AppDataFailure,
                .corruptionSuspected
            )
        }
    }

    private func makeReadyContainer() async throws -> ModelContainer {
        let container = try makeContainer(source: .newInstallV8)
        let writer = AppWriteActor(modelContainer: container)
        let base = Date(timeIntervalSince1970: 1_774_000_000)
        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .privacy,
                action: .reviewPrivacy,
                committedAt: base
            )
        )
        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .startDate,
                action: .continueStartDate(skipped: true),
                committedAt: base.addingTimeInterval(1)
            )
        )
        let draftID = UUID()
        try await writer.saveRegimenDraft(
            SaveRegimenDraftCommand(
                recordID: draftID,
                previousVersionID: nil,
                code: "READY",
                title: "可完成方案",
                effectiveStartDate: try CivilDateFact(
                    year: 2026,
                    month: 1,
                    day: 1
                ),
                changeReason: "测试",
                items: [
                    RegimenItemInput(
                        displayName: "项目",
                        schedule: RegimenScheduleInput(
                            id: UUID(),
                            kind: .dailyTimes,
                            localTimes: "09:00"
                        )
                    )
                ],
                committedAt: base.addingTimeInterval(2)
            )
        )
        let preview = try await writer.previewRegimenChange(
            draftID: draftID
        )
        try await writer.sealRegimenDraft(
            SealRegimenDraftCommand(
                draftID: draftID,
                expectedNextLocalRevision:
                    preview.expectedNextLocalRevision,
                draftDigest: preview.draftDigest,
                committedAt: base.addingTimeInterval(3)
            )
        )
        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .regimen,
                action: .continueRegimen,
                committedAt: base.addingTimeInterval(4)
            )
        )
        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .reminder,
                action: .continueReminder(skipped: true),
                committedAt: base.addingTimeInterval(5)
            )
        )
        _ = try await writer.updateOnboardingProgress(
            UpdateOnboardingProgressCommand(
                expectedStep: .countdown,
                action: .continueCountdown(skipped: true),
                committedAt: base.addingTimeInterval(6)
            )
        )
        return container
    }

    private func revisionFacts(
        in context: ModelContext
    ) throws -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: try context.fetch(
                FetchDescriptor<RecordRevision>()
            ).map {
                (
                    $0.recordKey,
                    [
                        $0.localRevision.description,
                        $0.digestHex,
                        String(
                            $0.committedAt.timeIntervalSinceReferenceDate
                        ),
                    ].joined(separator: "|")
                )
            }
        )
    }

    private func onboardingBackfillFacts(
        in container: ModelContainer
    ) throws -> [String] {
        let context = ModelContext(container)
        var facts = try context.fetch(
            FetchDescriptor<DatasetMetadata>()
        ).map {
            [
                "metadata",
                $0.singletonKey,
                $0.datasetID.uuidString,
                $0.nextLocalRevision.description,
                $0.digestVersion.description,
                $0.createdAt.timeIntervalSinceReferenceDate.description,
                $0.lastCommittedAt?.timeIntervalSinceReferenceDate
                    .description ?? "nil",
            ].joined(separator: "|")
        }
        facts += try context.fetch(
            FetchDescriptor<UserPreferencesRecord>()
        ).map {
            [
                "preferences",
                $0.singletonKey,
                $0.onboardingCompleted.description,
            ].joined(separator: "|")
        }
        facts += try context.fetch(
            FetchDescriptor<OnboardingProgressRecord>()
        ).map {
            [
                "progress",
                $0.singletonKey,
                $0.contractVersion.description,
                $0.stepRawValue,
                $0.skippedStartDate.description,
                $0.skippedReminder.description,
                $0.skippedCountdown.description,
                $0.completedAt?.timeIntervalSinceReferenceDate
                    .description ?? "nil",
                $0.updatedAt.timeIntervalSinceReferenceDate.description,
            ].joined(separator: "|")
        }
        facts += try context.fetch(
            FetchDescriptor<OnboardingBackfillState>()
        ).map {
            [
                "state",
                $0.taskKey,
                $0.sourceRawValue,
                $0.completedAt?.timeIntervalSinceReferenceDate
                    .description ?? "nil",
                $0.updatedAt.timeIntervalSinceReferenceDate.description,
            ].joined(separator: "|")
        }
        facts += try context.fetch(
            FetchDescriptor<RecordRevision>()
        ).map {
            [
                "revision",
                $0.recordKey,
                $0.datasetID.uuidString,
                $0.localRevision.description,
                $0.digestVersion.description,
                $0.digestHex,
                $0.committedAt.timeIntervalSinceReferenceDate.description,
            ].joined(separator: "|")
        }
        return facts.sorted()
    }

    private func makePreOnboardingContainer() throws -> ModelContainer {
        let container = try AppModelContainerFactory
            .makeInMemoryCountdownLifecycleContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: "UTC"
        )
        _ = try TodayExecutionBackfill.run(in: container)
        _ = try PersonalTimelineBackfill.run(in: container)
        _ = try CountdownLifecycleBackfill.run(in: container)
        return container
    }

    private func makeContainer(
        source: OnboardingBackfillSource
    ) throws -> ModelContainer {
        let container = try makePreOnboardingContainer()
        _ = try OnboardingBackfill.run(
            in: container,
            source: source,
            now: Date(timeIntervalSince1970: 1_774_000_000)
        )
        return container
    }
}
