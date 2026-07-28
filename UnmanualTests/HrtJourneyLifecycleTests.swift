import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class HrtJourneyLifecycleTests: XCTestCase {
    func testEditorFailurePolicyEscalatesOnlyIntegrityFailures() {
        XCTAssertTrue(
            HrtJourneyEditorFailurePolicy.requiresRecovery(
                AppDataFailure.corruptionSuspected
            )
        )
        XCTAssertTrue(
            HrtJourneyEditorFailurePolicy.requiresRecovery(
                HrtJourneyWriteFailure.missingFoundation
            )
        )
        XCTAssertTrue(
            HrtJourneyEditorFailurePolicy.requiresRecovery(
                HrtJourneyWriteFailure.corruptionSuspected
            )
        )
        XCTAssertFalse(
            HrtJourneyEditorFailurePolicy.requiresRecovery(
                HrtJourneyWriteFailure.staleRecord
            )
        )
        XCTAssertFalse(
            HrtJourneyEditorFailurePolicy.requiresRecovery(
                AppDataFailure.storageUnavailable
            )
        )
    }

    func testJourneySummaryUsesCivilDatesAndDoesNotCountPausedDaysAsCurrentPhase() throws {
        let first = try CivilDateFact(year: 2026, month: 1, day: 1)
        let pause = try CivilDateFact(year: 2026, month: 1, day: 11)
        let resume = try CivilDateFact(year: 2026, month: 1, day: 15)
        let today = try CivilDateFact(year: 2026, month: 1, day: 20)
        let summary = try HrtJourneyProjection.project(
            firstEverStartDate: first,
            periods: [
                HrtPeriodFact(
                    id: UUID(uuidString: "91000000-0000-0000-0000-000000000001")!,
                    startDate: first,
                    endDate: pause,
                    note: ""
                ),
                HrtPeriodFact(
                    id: UUID(uuidString: "91000000-0000-0000-0000-000000000002")!,
                    startDate: resume,
                    endDate: nil,
                    note: ""
                )
            ],
            asOf: today
        )

        XCTAssertEqual(summary.state, .active)
        XCTAssertEqual(summary.overallJourneyDay, 20)
        XCTAssertEqual(summary.currentPhaseDay, 6)
        XCTAssertNil(summary.pausedDay)
        XCTAssertEqual(summary.periodCount, 2)
    }

    func testJourneySummaryReportsPausedStateFromOpenPeriodAbsence() throws {
        let first = try CivilDateFact(year: 2026, month: 2, day: 1)
        let pause = try CivilDateFact(year: 2026, month: 2, day: 10)
        let today = try CivilDateFact(year: 2026, month: 2, day: 12)
        let summary = try HrtJourneyProjection.project(
            firstEverStartDate: first,
            periods: [
                HrtPeriodFact(
                    id: UUID(),
                    startDate: first,
                    endDate: pause,
                    note: ""
                )
            ],
            asOf: today
        )

        XCTAssertEqual(summary.state, .paused)
        XCTAssertEqual(summary.overallJourneyDay, 12)
        XCTAssertNil(summary.currentPhaseDay)
        XCTAssertEqual(summary.pausedDay, 3)
        XCTAssertEqual(summary.pausedSince, pause)
    }

    func testV9BackfillCreatesSingleMigratedSnapshotAndIsIdempotent() throws {
        let container = try preparedV9Container()
        let context = ModelContext(container)
        let first = try CivilDateFact(year: 2026, month: 1, day: 1)
        context.insert(
            HRTProfile(
                id: UUID(uuidString: "92000000-0000-0000-0000-000000000001")!,
                startDate: displayDate(first),
                activePeriodStartDate: displayDate(first),
                createdAt: Date(timeIntervalSince1970: 1_767_225_600)
            )
        )
        context.insert(
            HrtJourneyProfileRecord(
                firstEverStartDate: first,
                createdAt: Date(timeIntervalSince1970: 1_767_225_600)
            )
        )
        context.insert(
            HrtPeriodRecord(
                id: UUID(uuidString: "92000000-0000-0000-0000-000000000002")!,
                startDate: first,
                createdAt: Date(timeIntervalSince1970: 1_767_225_600)
            )
        )
        try context.save()

        let fractionalNow = Date(
            timeIntervalSince1970: 1_767_225_601.75
        )
        let firstRun = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "8.0.0",
            now: fractionalNow
        )
        let secondRun = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "8.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_602)
        )

        XCTAssertTrue(firstRun.didChangeStore)
        XCTAssertFalse(secondRun.didChangeStore)
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<HrtJourneyLifecycleEventRecord>()
            ),
            1
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<HrtJourneyLifecycleEventRecord>())
                .first?.kind,
            .migratedSnapshot
        )
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<HrtJourneyLifecycleBackfillState>()
            ),
            1
        )
        let event = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<HrtJourneyLifecycleEventRecord>()
            ).first
        )
        let state = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<HrtJourneyLifecycleBackfillState>()
            ).first
        )
        let revisions = try context.fetch(
            FetchDescriptor<RecordRevision>()
        ).filter {
            $0.recordType == "HrtJourneyLifecycleEventRecord"
                || $0.recordType
                    == "HrtJourneyLifecycleBackfillState"
        }
        let metadata = try XCTUnwrap(
            context.fetch(FetchDescriptor<DatasetMetadata>()).first
        )
        XCTAssertEqual(
            event.occurredAt,
            Date(timeIntervalSince1970: 1_767_225_601)
        )
        XCTAssertNotEqual(event.occurredAt, fractionalNow)
        XCTAssertEqual(state.completedAt, event.occurredAt)
        XCTAssertEqual(state.updatedAt, event.occurredAt)
        XCTAssertEqual(revisions.count, 2)
        XCTAssertTrue(
            revisions.allSatisfy {
                $0.committedAt == event.occurredAt
            }
        )
        XCTAssertEqual(metadata.lastCommittedAt, event.occurredAt)
        XCTAssertNoThrow(
            try HrtJourneyLifecycleValidator.validate(
                in: context,
                failure: .migrationFailed
            )
        )
    }

    func testV9BackfillAcceptsReceiptLedgerReconciledAfterCountdownMigration()
        throws
    {
        let container =
            try preparedV9ContainerWithReconciledCountdownLedger()
        let context = ModelContext(container)
        let migrationCommittedAt = Date(
            timeIntervalSince1970: 1_767_225_700
        )

        let revisions = try context.fetch(
            FetchDescriptor<RecordRevision>()
        )
        let latestReceiptRevision = try XCTUnwrap(
            revisions
                .filter { $0.recordType == "OperationReceiptRecord" }
                .max { $0.localRevision < $1.localRevision }
        )
        let ledgerRevision = try XCTUnwrap(
            revisions.first {
                $0.recordKey
                    == "OperationReceiptLedgerRecord:"
                        + TodayExecutionDigestV1.receiptLedgerID
                            .uuidString.lowercased()
            }
        )
        let ledger = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<OperationReceiptLedgerRecord>()
            ).first
        )
        XCTAssertGreaterThan(
            ledgerRevision.localRevision,
            latestReceiptRevision.localRevision
        )
        XCTAssertNotEqual(
            ledgerRevision.committedAt,
            latestReceiptRevision.committedAt
        )
        XCTAssertEqual(ledgerRevision.committedAt, ledger.updatedAt)

        XCTAssertNoThrow(
            try HrtJourneyLifecycleBackfill.run(
                in: container,
                sourceSchemaVersion: "8.0.0",
                now: migrationCommittedAt.addingTimeInterval(100)
            )
        )
        XCTAssertNoThrow(
            try HrtJourneyLifecycleValidator.validate(
                in: context,
                failure: .migrationFailed
            )
        )
    }

    func testHrtValidatorRejectsReceiptLedgerMovedToUnrelatedLaterRevision()
        throws
    {
        let container =
            try preparedV9ContainerWithReconciledCountdownLedger()
        let context = ModelContext(container)
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "8.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_800)
        )
        let revisions = try context.fetch(
            FetchDescriptor<RecordRevision>()
        )
        let ledgerRevision = try XCTUnwrap(
            revisions.first {
                $0.recordKey
                    == "OperationReceiptLedgerRecord:"
                        + TodayExecutionDigestV1.receiptLedgerID
                            .uuidString.lowercased()
            }
        )
        let hrtStateRevision = try XCTUnwrap(
            revisions.first {
                $0.recordType
                    == "HrtJourneyLifecycleBackfillState"
            }
        )
        XCTAssertGreaterThan(
            hrtStateRevision.localRevision,
            ledgerRevision.localRevision
        )
        ledgerRevision.localRevision = hrtStateRevision.localRevision
        try context.save()

        XCTAssertThrowsError(
            try HrtJourneyLifecycleValidator.validate(
                in: context,
                failure: .migrationFailed
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .migrationFailed)
        }
    }

    func testPauseResumeCreatesMultiplePeriodsAndSupportsExactReplay() async throws {
        let container = try preparedV9Container()
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let writer = AppWriteActor(modelContainer: container)
        let start = try CivilDateFact(year: 2026, month: 1, day: 1)
        let pause = try CivilDateFact(year: 2026, month: 1, day: 11)
        let resume = try CivilDateFact(year: 2026, month: 1, day: 15)
        let startTimestamp = try timestamp(
            localDate: try CivilDateFact(year: 2026, month: 1, day: 20)
        )
        let startResult = try await writer.createHrtJourney(
            CreateHrtJourneyCommand(
                operationID: UUID(uuidString: "93000000-0000-0000-0000-000000000001")!,
                eventID: UUID(uuidString: "93000000-0000-0000-0000-000000000002")!,
                periodID: UUID(uuidString: "93000000-0000-0000-0000-000000000003")!,
                legacyProfileID: UUID(uuidString: "93000000-0000-0000-0000-000000000004")!,
                startDate: start,
                note: "第一次",
                timestamp: startTimestamp
            )
        )
        let pauseCommand = PauseHrtJourneyCommand(
            operationID: UUID(uuidString: "93000000-0000-0000-0000-000000000005")!,
            eventID: UUID(uuidString: "93000000-0000-0000-0000-000000000006")!,
            expectedLatestEventID: startResult.eventID,
            expectedOpenPeriodID: startResult.periodID,
            pauseDate: pause,
            note: "暂时停下",
            timestamp: startTimestamp
        )
        let pauseResult = try await writer.pauseHrtJourney(pauseCommand)
        let replay = try await writer.pauseHrtJourney(pauseCommand)
        XCTAssertTrue(pauseResult.didApply)
        XCTAssertFalse(replay.didApply)
        XCTAssertEqual(replay.eventID, pauseResult.eventID)

        let resumeResult = try await writer.resumeHrtJourney(
            ResumeHrtJourneyCommand(
                operationID: UUID(uuidString: "93000000-0000-0000-0000-000000000007")!,
                eventID: UUID(uuidString: "93000000-0000-0000-0000-000000000008")!,
                periodID: UUID(uuidString: "93000000-0000-0000-0000-000000000009")!,
                expectedLatestEventID: pauseResult.eventID,
                expectedLastPeriodID: pauseResult.periodID,
                resumeDate: resume,
                note: "重新开始",
                timestamp: startTimestamp
            )
        )

        let snapshot = try await AppReadActor(modelContainer: container)
            .hrtJourneySnapshot(asOf: try CivilDateFact(year: 2026, month: 1, day: 20))
        XCTAssertEqual(snapshot?.summary.state, .active)
        XCTAssertEqual(snapshot?.summary.currentPhaseDay, 6)
        XCTAssertEqual(snapshot?.periods.count, 2)
        XCTAssertEqual(snapshot?.latestEventID, resumeResult.eventID)
    }

    func testPersonalTimelineProjectsUserLifecycleEventsInAuditOrder()
        async throws
    {
        let container = try preparedV9Container()
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let writer = AppWriteActor(modelContainer: container)
        let startDate = try CivilDateFact(
            year: 2026,
            month: 1,
            day: 1
        )
        let pauseDate = try CivilDateFact(
            year: 2026,
            month: 1,
            day: 11
        )
        let resumeDate = try CivilDateFact(
            year: 2026,
            month: 1,
            day: 15
        )
        let baseTimestamp = try timestamp(
            localDate: try CivilDateFact(
                year: 2026,
                month: 1,
                day: 20
            )
        )
        let started = try await writer.createHrtJourney(
            CreateHrtJourneyCommand(
                startDate: startDate,
                note: "开始备注不进入时间线摘要",
                timestamp: baseTimestamp
            )
        )
        let paused = try await writer.pauseHrtJourney(
            PauseHrtJourneyCommand(
                expectedLatestEventID: started.eventID,
                expectedOpenPeriodID: started.periodID,
                pauseDate: pauseDate,
                note: "暂停备注不进入时间线摘要",
                timestamp: try timestamp(
                    from: baseTimestamp,
                    addingSeconds: 60
                )
            )
        )
        _ = try await writer.resumeHrtJourney(
            ResumeHrtJourneyCommand(
                expectedLatestEventID: paused.eventID,
                expectedLastPeriodID: paused.periodID,
                resumeDate: resumeDate,
                note: "恢复备注不进入时间线摘要",
                timestamp: try timestamp(
                    from: baseTimestamp,
                    addingSeconds: 120
                )
            )
        )

        let reader = AppReadActor(modelContainer: container)
        let page = try await reader.personalTimelinePage(limit: 10)

        XCTAssertEqual(
            page.items.map(\.title),
            [
                "HRT 历程已恢复",
                "HRT 历程已暂停",
                "HRT 历程已开始"
            ]
        )
        XCTAssertEqual(
            page.items.map(\.detail),
            [
                "恢复日：2026.01.15；方案、执行和提醒未改变",
                "暂停从 2026.01.11 开始；方案、执行和提醒未改变",
                "开始日：2026.01.01；方案、执行和提醒未改变"
            ]
        )
        XCTAssertFalse(
            page.items.contains {
                $0.title.contains("迁移") || $0.detail.contains("备注")
            }
        )

        var pagedIDs: [UUID] = []
        var cursor: PersonalTimelineCursor?
        repeat {
            let next = try await reader.personalTimelinePage(
                after: cursor,
                limit: 1
            )
            pagedIDs.append(contentsOf: next.items.map(\.id))
            cursor = next.nextCursor
        } while cursor != nil
        XCTAssertEqual(pagedIDs, page.items.map(\.id))
        XCTAssertEqual(Set(pagedIDs).count, pagedIDs.count)
    }

    func testPersonalTimelineGentleModeDoesNotExposeHrtOrLifecycleNotes()
        async throws
    {
        let container = try preparedV9Container()
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try self.timestamp(
            localDate: try CivilDateFact(
                year: 2026,
                month: 2,
                day: 20
            )
        )
        let started = try await writer.createHrtJourney(
            CreateHrtJourneyCommand(
                startDate: try CivilDateFact(
                    year: 2026,
                    month: 2,
                    day: 1
                ),
                note: "HRT 开始的私密备注",
                timestamp: timestamp
            )
        )
        _ = try await writer.pauseHrtJourney(
            PauseHrtJourneyCommand(
                expectedLatestEventID: started.eventID,
                expectedOpenPeriodID: started.periodID,
                pauseDate: try CivilDateFact(
                    year: 2026,
                    month: 2,
                    day: 10
                ),
                note: "HRT 暂停的私密备注",
                timestamp: try self.timestamp(
                    from: timestamp,
                    addingSeconds: 60
                )
            )
        )
        try await writer.setGentleMode(
            SetGentleModeCommand(
                isEnabled: true,
                committedAt: timestamp.instant.addingTimeInterval(120)
            )
        )

        let page = try await AppReadActor(modelContainer: container)
            .personalTimelinePage(limit: 10)
        let visibleText = page.items
            .flatMap { [$0.title, $0.detail] }
            .joined(separator: "\n")

        XCTAssertEqual(
            page.items.map(\.title),
            ["时间坐标已暂停", "时间坐标已开始"]
        )
        XCTAssertFalse(visibleText.localizedCaseInsensitiveContains("HRT"))
        XCTAssertFalse(visibleText.contains("私密备注"))
        XCTAssertTrue(visibleText.contains("其他计划没有改变"))
    }

    func testV9RejectsLegacyStartDateWriterWithoutCreatingUntrackedFacts()
        async throws
    {
        let container = try preparedV9Container()
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let context = ModelContext(container)
        let factsBefore = try HrtJourneyLifecycleDigest.facts(
            in: context,
            failure: .corruptionSuspected
        )
        let metadata = try XCTUnwrap(
            context.fetch(FetchDescriptor<DatasetMetadata>()).first
        )
        let revisionBefore = metadata.nextLocalRevision

        do {
            try await AppWriteActor(modelContainer: container).setStartDate(
                SetStartDateCommand(
                    startDate: Date(
                        timeIntervalSince1970: 1_767_225_600
                    ),
                    timeZoneIdentifier: "UTC",
                    committedAt: Date(
                        timeIntervalSince1970: 1_767_225_601
                    )
                )
            )
            XCTFail("V9 必须只允许 append-only HRT 生命周期命令")
        } catch {
            XCTAssertEqual(error as? AppWriteFailure, .invalidInput)
        }

        XCTAssertEqual(
            try HrtJourneyLifecycleDigest.facts(
                in: context,
                failure: .corruptionSuspected
            ),
            factsBefore
        )
        XCTAssertEqual(metadata.nextLocalRevision, revisionBefore)
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<HrtJourneyLifecycleEventRecord>()
            ),
            0
        )
    }

    func testIllegalAndStaleTransitionsAreZeroWrite() async throws {
        let container = try preparedV9Container()
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let writer = AppWriteActor(modelContainer: container)
        let start = try CivilDateFact(year: 2026, month: 3, day: 1)
        let timestamp = try self.timestamp(
            localDate: try CivilDateFact(year: 2026, month: 3, day: 10)
        )
        let created = try await writer.createHrtJourney(
            CreateHrtJourneyCommand(
                operationID: UUID(),
                eventID: UUID(),
                periodID: UUID(),
                legacyProfileID: UUID(),
                startDate: start,
                note: "",
                timestamp: timestamp
            )
        )
        let context = ModelContext(container)
        let factsBefore = try HrtJourneyLifecycleDigest.facts(
            in: context,
            failure: .corruptionSuspected
        )
        let revisionBefore = try XCTUnwrap(
            context.fetch(FetchDescriptor<DatasetMetadata>()).first
        ).nextLocalRevision

        do {
            _ = try await writer.pauseHrtJourney(
                PauseHrtJourneyCommand(
                    operationID: UUID(),
                    eventID: UUID(),
                    expectedLatestEventID: UUID(),
                    expectedOpenPeriodID: created.periodID,
                    pauseDate: try CivilDateFact(year: 2026, month: 3, day: 2),
                    note: "",
                    timestamp: timestamp
                )
            )
            XCTFail("陈旧事件 head 必须拒绝")
        } catch {
            XCTAssertEqual(error as? HrtJourneyWriteFailure, .staleRecord)
        }

        do {
            _ = try await writer.pauseHrtJourney(
                PauseHrtJourneyCommand(
                    operationID: UUID(),
                    eventID: UUID(),
                    expectedLatestEventID: created.eventID,
                    expectedOpenPeriodID: created.periodID,
                    pauseDate: start,
                    note: "",
                    timestamp: timestamp
                )
            )
            XCTFail("同日暂停必须拒绝")
        } catch {
            XCTAssertEqual(error as? HrtJourneyWriteFailure, .invalidTransition)
        }

        XCTAssertEqual(
            try HrtJourneyLifecycleDigest.facts(
                in: context,
                failure: .corruptionSuspected
            ),
            factsBefore
        )
        XCTAssertEqual(
            try XCTUnwrap(
                context.fetch(FetchDescriptor<DatasetMetadata>()).first
            ).nextLocalRevision,
            revisionBefore
        )
    }

    func testFirstStartCorrectionIsAppendOnlyAndSupportsExactReplay()
        async throws
    {
        let container = try preparedV9Container()
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let writer = AppWriteActor(modelContainer: container)
        let original = try CivilDateFact(year: 2026, month: 1, day: 1)
        let corrected = try CivilDateFact(year: 2026, month: 1, day: 3)
        let timestamp = try self.timestamp(
            localDate: try CivilDateFact(year: 2026, month: 1, day: 20)
        )
        let created = try await writer.createHrtJourney(
            CreateHrtJourneyCommand(
                startDate: original,
                timestamp: timestamp
            )
        )
        let command = CorrectHrtJourneyFirstStartCommand(
            operationID: UUID(),
            eventID: UUID(),
            expectedLatestEventID: created.eventID,
            expectedPeriodID: created.periodID,
            correctedStartDate: corrected,
            note: "修正录入日期",
            timestamp: timestamp
        )

        let applied = try await writer.correctHrtJourneyFirstStart(command)
        let replay = try await writer.correctHrtJourneyFirstStart(command)
        let snapshot = try await AppReadActor(modelContainer: container)
            .hrtJourneySnapshot(
                asOf: try CivilDateFact(
                    year: 2026,
                    month: 1,
                    day: 20
                )
            )

        XCTAssertTrue(applied.didApply)
        XCTAssertFalse(replay.didApply)
        XCTAssertEqual(replay.eventID, applied.eventID)
        XCTAssertEqual(snapshot?.firstEverStartDate, corrected)
        XCTAssertEqual(snapshot?.periods.first?.startDate, corrected)
        XCTAssertEqual(snapshot?.summary.currentPhaseDay, 18)
        XCTAssertEqual(snapshot?.events.last?.kind, .firstStartCorrected)
    }

    func testFirstStartCorrectionRejectsMultipleCycleHistoryWithoutWriting()
        async throws
    {
        let container = try preparedV9Container()
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try self.timestamp(
            localDate: try CivilDateFact(year: 2026, month: 2, day: 20)
        )
        let created = try await writer.createHrtJourney(
            CreateHrtJourneyCommand(
                startDate: try CivilDateFact(
                    year: 2026,
                    month: 2,
                    day: 1
                ),
                timestamp: timestamp
            )
        )
        let paused = try await writer.pauseHrtJourney(
            PauseHrtJourneyCommand(
                expectedLatestEventID: created.eventID,
                expectedOpenPeriodID: created.periodID,
                pauseDate: try CivilDateFact(
                    year: 2026,
                    month: 2,
                    day: 10
                ),
                timestamp: timestamp
            )
        )
        let context = ModelContext(container)
        let factsBefore = try HrtJourneyLifecycleDigest.facts(
            in: context,
            failure: .corruptionSuspected
        )

        do {
            _ = try await writer.correctHrtJourneyFirstStart(
                CorrectHrtJourneyFirstStartCommand(
                    expectedLatestEventID: paused.eventID,
                    expectedPeriodID: paused.periodID,
                    correctedStartDate: try CivilDateFact(
                        year: 2026,
                        month: 2,
                        day: 2
                    ),
                    timestamp: timestamp
                )
            )
            XCTFail("已有暂停历史后不得原地纠正首次日期")
        } catch {
            XCTAssertEqual(
                error as? HrtJourneyWriteFailure,
                .invalidTransition
            )
        }
        XCTAssertEqual(
            try HrtJourneyLifecycleDigest.facts(
                in: context,
                failure: .corruptionSuspected
            ),
            factsBefore
        )
    }

    func testValidatorRejectsOrphanHrtReceiptEvenWithoutEvents() throws {
        let container = try preparedV9Container()
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let context = ModelContext(container)
        context.insert(
            OperationReceiptRecord(
                operationID: UUID(),
                commandDigest: String(repeating: "a", count: 64),
                resultRecordType: "HrtJourneyLifecycleEventRecord",
                resultRecordID: UUID(),
                committedAt: Date(timeIntervalSince1970: 1_767_225_601)
            )
        )
        try context.save()

        XCTAssertThrowsError(
            try HrtJourneyLifecycleValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(
                error as? AppDataFailure,
                .corruptionSuspected
            )
        }
    }

    func testValidatorRejectsEveryHrtMutationRevisionMovedOutsideItsTransaction()
        async throws
    {
        for target in HrtMutationRevisionTarget.allCases {
            let container = try preparedV9Container()
            _ = try HrtJourneyLifecycleBackfill.run(
                in: container,
                sourceSchemaVersion: "9.0.0",
                now: Date(timeIntervalSince1970: 1_767_225_600)
            )
            let operationID = UUID()
            let legacyProfileID = UUID()
            let writer = AppWriteActor(modelContainer: container)
            let started = try await writer.createHrtJourney(
                CreateHrtJourneyCommand(
                    operationID: operationID,
                    legacyProfileID: legacyProfileID,
                    startDate: try CivilDateFact(
                        year: 2026,
                        month: 4,
                        day: 1
                    ),
                    timestamp: try timestamp(
                        localDate: try CivilDateFact(
                            year: 2026,
                            month: 4,
                            day: 20
                        )
                    )
                )
            )
            let context = ModelContext(container)
            let targetKey: String = switch target {
            case .event:
                revisionKey(
                    "HrtJourneyLifecycleEventRecord",
                    started.eventID
                )
            case .receipt:
                revisionKey("OperationReceiptRecord", operationID)
            case .period:
                revisionKey("HrtPeriodRecord", started.periodID)
            case .profile:
                revisionKey(
                    "HrtJourneyProfileRecord",
                    CoreTimeRegimenBackfill.stableUUID(
                        for: HrtJourneyProfileRecord.fixedKey
                    )
                )
            case .legacy:
                revisionKey("HRTProfile", legacyProfileID)
            case .ledger:
                revisionKey(
                    "OperationReceiptLedgerRecord",
                    TodayExecutionDigestV1.receiptLedgerID
                )
            }
            let stateKey = revisionKey(
                "HrtJourneyLifecycleBackfillState",
                CoreTimeRegimenBackfill.stableUUID(
                    for: HrtJourneyLifecycleBackfillState.fixedKey
                )
            )
            let revisions = try context.fetch(
                FetchDescriptor<RecordRevision>()
            )
            let targetRevision = try XCTUnwrap(
                revisions.first { $0.recordKey == targetKey },
                target.rawValue
            )
            let stateRevision = try XCTUnwrap(
                revisions.first { $0.recordKey == stateKey }
            )
            XCTAssertNotEqual(
                targetRevision.localRevision,
                stateRevision.localRevision,
                target.rawValue
            )
            targetRevision.localRevision =
                stateRevision.localRevision
            try context.save()

            XCTAssertThrowsError(
                try HrtJourneyLifecycleValidator.validate(
                    in: context,
                    failure: .corruptionSuspected
                ),
                target.rawValue
            ) { error in
                XCTAssertEqual(
                    error as? AppDataFailure,
                    .corruptionSuspected,
                    target.rawValue
                )
            }
        }
    }

    func testValidatorRejectsWholeUserMutationMovedBackToFoundationRevision()
        async throws
    {
        let container = try preparedV9Container()
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let operationID = UUID()
        let legacyProfileID = UUID()
        let started = try await AppWriteActor(
            modelContainer: container
        ).createHrtJourney(
            CreateHrtJourneyCommand(
                operationID: operationID,
                legacyProfileID: legacyProfileID,
                startDate: try CivilDateFact(
                    year: 2026,
                    month: 4,
                    day: 1
                ),
                timestamp: try timestamp(
                    localDate: try CivilDateFact(
                        year: 2026,
                        month: 4,
                        day: 20
                    )
                )
            )
        )
        let context = ModelContext(container)
        let revisions = try context.fetch(
            FetchDescriptor<RecordRevision>()
        )
        let revisionsByKey = Dictionary(
            uniqueKeysWithValues: revisions.map {
                ($0.recordKey, $0)
            }
        )
        let stateKey = revisionKey(
            "HrtJourneyLifecycleBackfillState",
            CoreTimeRegimenBackfill.stableUUID(
                for: HrtJourneyLifecycleBackfillState.fixedKey
            )
        )
        let stateRevision = try XCTUnwrap(
            revisionsByKey[stateKey]
        ).localRevision
        let transactionKeys = [
            revisionKey(
                "HrtJourneyLifecycleEventRecord",
                started.eventID
            ),
            revisionKey("OperationReceiptRecord", operationID),
            revisionKey("HrtPeriodRecord", started.periodID),
            revisionKey(
                "HrtJourneyProfileRecord",
                CoreTimeRegimenBackfill.stableUUID(
                    for: HrtJourneyProfileRecord.fixedKey
                )
            ),
            revisionKey("HRTProfile", legacyProfileID),
            revisionKey(
                "OperationReceiptLedgerRecord",
                TodayExecutionDigestV1.receiptLedgerID
            )
        ]
        for key in transactionKeys {
            let revision = try XCTUnwrap(revisionsByKey[key], key)
            XCTAssertGreaterThan(revision.localRevision, stateRevision)
            revision.localRevision = stateRevision
        }
        try context.save()

        XCTAssertThrowsError(
            try HrtJourneyLifecycleValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(
                error as? AppDataFailure,
                .corruptionSuspected
            )
        }
    }

    func testValidatorRejectsMigrationStateRevisionSeparatedFromRootEvent()
        throws
    {
        let container = try preparedV9Container()
        let context = ModelContext(container)
        let first = try CivilDateFact(
            year: 2026,
            month: 4,
            day: 1
        )
        context.insert(
            HRTProfile(
                startDate: displayDate(first),
                activePeriodStartDate: displayDate(first),
                createdAt: Date(timeIntervalSince1970: 1_767_225_600)
            )
        )
        context.insert(
            HrtJourneyProfileRecord(
                firstEverStartDate: first,
                createdAt: Date(timeIntervalSince1970: 1_767_225_600)
            )
        )
        context.insert(
            HrtPeriodRecord(
                startDate: first,
                createdAt: Date(timeIntervalSince1970: 1_767_225_600)
            )
        )
        try context.save()
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "8.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_601)
        )
        let event = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<HrtJourneyLifecycleEventRecord>()
            ).first
        )
        let revisions = try context.fetch(
            FetchDescriptor<RecordRevision>()
        )
        let eventRevision = try XCTUnwrap(
            revisions.first {
                $0.recordKey == revisionKey(
                    "HrtJourneyLifecycleEventRecord",
                    event.id
                )
            }
        )
        let stateRevision = try XCTUnwrap(
            revisions.first {
                $0.recordKey == revisionKey(
                    "HrtJourneyLifecycleBackfillState",
                    CoreTimeRegimenBackfill.stableUUID(
                        for:
                            HrtJourneyLifecycleBackfillState
                                .fixedKey
                    )
                )
            }
        )
        stateRevision.localRevision += 1
        XCTAssertNotEqual(
            stateRevision.localRevision,
            eventRevision.localRevision
        )
        try context.save()

        XCTAssertThrowsError(
            try HrtJourneyLifecycleValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(
                error as? AppDataFailure,
                .corruptionSuspected
            )
        }
    }

    func testValidatorRejectsPauseBoundaryTamperAfterDigestRefresh()
        async throws
    {
        let container = try preparedV9Container()
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try self.timestamp(
            localDate: try CivilDateFact(
                year: 2026,
                month: 4,
                day: 20
            )
        )
        let started = try await writer.createHrtJourney(
            CreateHrtJourneyCommand(
                startDate: try CivilDateFact(
                    year: 2026,
                    month: 4,
                    day: 1
                ),
                timestamp: timestamp
            )
        )
        let paused = try await writer.pauseHrtJourney(
            PauseHrtJourneyCommand(
                expectedLatestEventID: started.eventID,
                expectedOpenPeriodID: started.periodID,
                pauseDate: try CivilDateFact(
                    year: 2026,
                    month: 4,
                    day: 10
                ),
                timestamp: timestamp
            )
        )
        let context = ModelContext(container)
        let pausedEventID = paused.eventID
        let event = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<HrtJourneyLifecycleEventRecord>(
                    predicate: #Predicate { $0.id == pausedEventID }
                )
            ).first
        )
        event.transitionDay = 11
        try refreshRevision(for: event, in: context)
        try context.save()

        XCTAssertThrowsError(
            try HrtJourneyLifecycleValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    func testValidatorRejectsIllegalStateMachineAfterDigestRefresh()
        async throws
    {
        let container = try preparedV9Container()
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try self.timestamp(
            localDate: try CivilDateFact(
                year: 2026,
                month: 5,
                day: 20
            )
        )
        let started = try await writer.createHrtJourney(
            CreateHrtJourneyCommand(
                startDate: try CivilDateFact(
                    year: 2026,
                    month: 5,
                    day: 1
                ),
                timestamp: timestamp
            )
        )
        let paused = try await writer.pauseHrtJourney(
            PauseHrtJourneyCommand(
                expectedLatestEventID: started.eventID,
                expectedOpenPeriodID: started.periodID,
                pauseDate: try CivilDateFact(
                    year: 2026,
                    month: 5,
                    day: 10
                ),
                timestamp: timestamp
            )
        )
        let context = ModelContext(container)
        let pausedEventID = paused.eventID
        let event = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<HrtJourneyLifecycleEventRecord>(
                    predicate: #Predicate { $0.id == pausedEventID }
                )
            ).first
        )
        event.kindRawValue = HrtJourneyLifecycleEventKind.resumed.rawValue
        try refreshRevision(for: event, in: context)
        try context.save()

        XCTAssertThrowsError(
            try HrtJourneyLifecycleValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    func testSameOperationWithDifferentDigestIsZeroWriteConflict()
        async throws
    {
        let container = try preparedV9Container()
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let writer = AppWriteActor(modelContainer: container)
        let operationID = UUID()
        let timestamp = try self.timestamp(
            localDate: try CivilDateFact(
                year: 2026,
                month: 6,
                day: 20
            )
        )
        _ = try await writer.createHrtJourney(
            CreateHrtJourneyCommand(
                operationID: operationID,
                startDate: try CivilDateFact(
                    year: 2026,
                    month: 6,
                    day: 1
                ),
                timestamp: timestamp
            )
        )
        let context = ModelContext(container)
        let revisionBefore = try XCTUnwrap(
            context.fetch(FetchDescriptor<DatasetMetadata>()).first
        ).nextLocalRevision
        let eventCountBefore = try context.fetchCount(
            FetchDescriptor<HrtJourneyLifecycleEventRecord>()
        )

        do {
            _ = try await writer.createHrtJourney(
                CreateHrtJourneyCommand(
                    operationID: operationID,
                    startDate: try CivilDateFact(
                        year: 2026,
                        month: 6,
                        day: 2
                    ),
                    timestamp: timestamp
                )
            )
            XCTFail("相同 operationID 的不同命令摘要必须拒绝")
        } catch {
            XCTAssertEqual(
                error as? HrtJourneyWriteFailure,
                .operationConflict
            )
        }

        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<HrtJourneyLifecycleEventRecord>()
            ),
            eventCountBefore
        )
        XCTAssertEqual(
            try XCTUnwrap(
                context.fetch(FetchDescriptor<DatasetMetadata>()).first
            ).nextLocalRevision,
            revisionBefore
        )
    }

    func testValidatorRejectsLegacyMirrorTamperAfterRevisionRefresh()
        async throws
    {
        let container = try preparedV9Container()
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let writer = AppWriteActor(modelContainer: container)
        _ = try await writer.createHrtJourney(
            CreateHrtJourneyCommand(
                startDate: try CivilDateFact(
                    year: 2026,
                    month: 7,
                    day: 1
                ),
                timestamp: try timestamp(
                    localDate: try CivilDateFact(
                        year: 2026,
                        month: 7,
                        day: 20
                    )
                )
            )
        )
        let context = ModelContext(container)
        let legacy = try XCTUnwrap(
            try context.fetch(FetchDescriptor<HRTProfile>()).first
        )
        legacy.startDate = displayDate(
            try CivilDateFact(
                year: 2026,
                month: 7,
                day: 2
            )
        )
        try refreshRevision(for: legacy, in: context)
        try context.save()

        XCTAssertThrowsError(
            try HrtJourneyLifecycleValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(
                error as? AppDataFailure,
                .corruptionSuspected
            )
        }
    }

    func testValidatorRecomputesReceiptCommandDigestFromEventSemantics()
        async throws
    {
        let container = try preparedV9Container()
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let writer = AppWriteActor(modelContainer: container)
        _ = try await writer.createHrtJourney(
            CreateHrtJourneyCommand(
                startDate: try CivilDateFact(
                    year: 2026,
                    month: 7,
                    day: 1
                ),
                timestamp: try timestamp(
                    localDate: try CivilDateFact(
                        year: 2026,
                        month: 7,
                        day: 20
                    )
                )
            )
        )
        let context = ModelContext(container)
        let receipt = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<OperationReceiptRecord>()
            ).first {
                $0.resultRecordType
                    == "HrtJourneyLifecycleEventRecord"
            }
        )
        receipt.commandDigest = String(repeating: "a", count: 64)
        try refreshReceiptAndLedgerRevisions(in: context)
        try context.save()

        XCTAssertThrowsError(
            try HrtJourneyLifecycleValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(
                error as? AppDataFailure,
                .corruptionSuspected
            )
        }
    }

    func testExactReplayValidatesLifecycleIntegrityBeforeReturning()
        async throws
    {
        let container = try preparedV9Container()
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let writer = AppWriteActor(modelContainer: container)
        let command = CreateHrtJourneyCommand(
            startDate: try CivilDateFact(
                year: 2026,
                month: 7,
                day: 1
            ),
            timestamp: try timestamp(
                localDate: try CivilDateFact(
                    year: 2026,
                    month: 7,
                    day: 20
                )
            )
        )
        _ = try await writer.createHrtJourney(command)
        let context = ModelContext(container)
        let legacy = try XCTUnwrap(
            try context.fetch(FetchDescriptor<HRTProfile>()).first
        )
        legacy.activePeriodStartDate = displayDate(
            try CivilDateFact(
                year: 2026,
                month: 7,
                day: 2
            )
        )
        try refreshRevision(for: legacy, in: context)
        try context.save()

        do {
            _ = try await writer.createHrtJourney(command)
            XCTFail("精确重放前必须先拒绝已损坏的生命周期事实")
        } catch {
            XCTAssertEqual(
                error as? HrtJourneyWriteFailure,
                .corruptionSuspected
            )
        }
    }

    func testPausedCanonicalProfileKeepsLatestPeriodStartDate()
        async throws
    {
        let container = try preparedV9Container()
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try self.timestamp(
            localDate: try CivilDateFact(
                year: 2026,
                month: 7,
                day: 25
            )
        )
        let started = try await writer.createHrtJourney(
            CreateHrtJourneyCommand(
                startDate: try CivilDateFact(
                    year: 2026,
                    month: 7,
                    day: 1
                ),
                timestamp: timestamp
            )
        )
        let paused = try await writer.pauseHrtJourney(
            PauseHrtJourneyCommand(
                expectedLatestEventID: started.eventID,
                expectedOpenPeriodID: started.periodID,
                pauseDate: try CivilDateFact(
                    year: 2026,
                    month: 7,
                    day: 10
                ),
                timestamp: try self.timestamp(
                    from: timestamp,
                    addingSeconds: 60
                )
            )
        )
        let resumed = try await writer.resumeHrtJourney(
            ResumeHrtJourneyCommand(
                expectedLatestEventID: paused.eventID,
                expectedLastPeriodID: paused.periodID,
                resumeDate: try CivilDateFact(
                    year: 2026,
                    month: 7,
                    day: 15
                ),
                timestamp: try self.timestamp(
                    from: timestamp,
                    addingSeconds: 120
                )
            )
        )
        _ = try await writer.pauseHrtJourney(
            PauseHrtJourneyCommand(
                expectedLatestEventID: resumed.eventID,
                expectedOpenPeriodID: resumed.periodID,
                pauseDate: try CivilDateFact(
                    year: 2026,
                    month: 7,
                    day: 20
                ),
                timestamp: try self.timestamp(
                    from: timestamp,
                    addingSeconds: 180
                )
            )
        )

        let snapshot = try await AppReadActor(
            modelContainer: container
        ).todaySnapshot()
        let profile = try XCTUnwrap(snapshot.profile)
        XCTAssertEqual(
            civilDate(
                profile.activePeriodStartDate,
                timeZone: .autoupdatingCurrent
            ),
            try CivilDateFact(
                year: 2026,
                month: 7,
                day: 15
            )
        )
    }

    func testCreateFailureRollsBackAndSuccessUsesSingleRevision()
        async throws
    {
        let container = try preparedV9Container()
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let writer = AppWriteActor(modelContainer: container)
        let command = CreateHrtJourneyCommand(
            operationID: UUID(
                uuidString:
                    "98000000-0000-0000-0000-000000000001"
            )!,
            eventID: UUID(
                uuidString:
                    "98000000-0000-0000-0000-000000000002"
            )!,
            periodID: UUID(
                uuidString:
                    "98000000-0000-0000-0000-000000000003"
            )!,
            legacyProfileID: UUID(
                uuidString:
                    "98000000-0000-0000-0000-000000000004"
            )!,
            startDate: try CivilDateFact(
                year: 2026,
                month: 7,
                day: 1
            ),
            timestamp: try timestamp(
                localDate: try CivilDateFact(
                    year: 2026,
                    month: 7,
                    day: 20
                )
            )
        )
        let beforeContext = ModelContext(container)
        let revisionBefore = try XCTUnwrap(
            beforeContext.fetch(FetchDescriptor<DatasetMetadata>()).first
        ).nextLocalRevision
        let revisionCountBefore = try beforeContext.fetchCount(
            FetchDescriptor<RecordRevision>()
        )

        do {
            _ = try await writer.createHrtJourney(
                command,
                failureInjection: .beforeRevisionCommit
            )
            XCTFail("注入故障必须回滚整个 HRT 创建事务")
        } catch {
            XCTAssertEqual(error as? AppWriteFailure, .injected)
        }

        let rolledBackContext = ModelContext(container)
        XCTAssertEqual(
            try rolledBackContext.fetchCount(
                FetchDescriptor<HRTProfile>()
            ),
            0
        )
        XCTAssertEqual(
            try rolledBackContext.fetchCount(
                FetchDescriptor<HrtJourneyProfileRecord>()
            ),
            0
        )
        XCTAssertEqual(
            try rolledBackContext.fetchCount(
                FetchDescriptor<HrtPeriodRecord>()
            ),
            0
        )
        XCTAssertEqual(
            try rolledBackContext.fetchCount(
                FetchDescriptor<HrtJourneyLifecycleEventRecord>()
            ),
            0
        )
        XCTAssertEqual(
            try rolledBackContext.fetch(
                FetchDescriptor<OperationReceiptRecord>()
            ).filter {
                $0.resultRecordType
                    == "HrtJourneyLifecycleEventRecord"
            }.count,
            0
        )
        XCTAssertEqual(
            try rolledBackContext.fetchCount(
                FetchDescriptor<RecordRevision>()
            ),
            revisionCountBefore
        )
        XCTAssertEqual(
            try XCTUnwrap(
                rolledBackContext.fetch(
                    FetchDescriptor<DatasetMetadata>()
                ).first
            ).nextLocalRevision,
            revisionBefore
        )

        _ = try await writer.createHrtJourney(command)
        let committedContext = ModelContext(container)
        let committedRevisions = try committedContext.fetch(
            FetchDescriptor<RecordRevision>()
        ).filter { $0.localRevision == revisionBefore }
        XCTAssertEqual(committedRevisions.count, 6)
        XCTAssertEqual(
            Set(committedRevisions.map(\.recordType)),
            [
                "HRTProfile",
                "HrtJourneyProfileRecord",
                "HrtPeriodRecord",
                "HrtJourneyLifecycleEventRecord",
                "OperationReceiptRecord",
                "OperationReceiptLedgerRecord"
            ]
        )
        XCTAssertEqual(
            try XCTUnwrap(
                committedContext.fetch(
                    FetchDescriptor<DatasetMetadata>()
                ).first
            ).nextLocalRevision,
            revisionBefore + 1
        )
    }

    func testCorrectionPauseAndResumeFailureInjectionRollBackAtomically()
        async throws
    {
        let container = try preparedV9Container()
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try self.timestamp(
            localDate: try CivilDateFact(
                year: 2026,
                month: 8,
                day: 25
            )
        )
        let started = try await writer.createHrtJourney(
            CreateHrtJourneyCommand(
                startDate: try CivilDateFact(
                    year: 2026,
                    month: 8,
                    day: 1
                ),
                timestamp: timestamp
            )
        )
        let correction = CorrectHrtJourneyFirstStartCommand(
            expectedLatestEventID: started.eventID,
            expectedPeriodID: started.periodID,
            correctedStartDate: try CivilDateFact(
                year: 2026,
                month: 8,
                day: 2
            ),
            timestamp: try self.timestamp(
                from: timestamp,
                addingSeconds: 60
            )
        )
        var before = try hrtAuditSnapshot(in: container)
        do {
            _ = try await writer.correctHrtJourneyFirstStart(
                correction,
                failureInjection: .beforeRevisionCommit
            )
            XCTFail("首次日期纠错注入故障必须原子回滚")
        } catch {
            XCTAssertEqual(error as? AppWriteFailure, .injected)
        }
        XCTAssertEqual(try hrtAuditSnapshot(in: container), before)

        let corrected = try await writer
            .correctHrtJourneyFirstStart(correction)
        let pause = PauseHrtJourneyCommand(
            expectedLatestEventID: corrected.eventID,
            expectedOpenPeriodID: corrected.periodID,
            pauseDate: try CivilDateFact(
                year: 2026,
                month: 8,
                day: 10
            ),
            timestamp: try self.timestamp(
                from: timestamp,
                addingSeconds: 120
            )
        )
        before = try hrtAuditSnapshot(in: container)
        do {
            _ = try await writer.pauseHrtJourney(
                pause,
                failureInjection: .beforeRevisionCommit
            )
            XCTFail("暂停注入故障必须原子回滚")
        } catch {
            XCTAssertEqual(error as? AppWriteFailure, .injected)
        }
        XCTAssertEqual(try hrtAuditSnapshot(in: container), before)

        let paused = try await writer.pauseHrtJourney(pause)
        let resume = ResumeHrtJourneyCommand(
            expectedLatestEventID: paused.eventID,
            expectedLastPeriodID: paused.periodID,
            resumeDate: try CivilDateFact(
                year: 2026,
                month: 8,
                day: 15
            ),
            timestamp: try self.timestamp(
                from: timestamp,
                addingSeconds: 180
            )
        )
        before = try hrtAuditSnapshot(in: container)
        do {
            _ = try await writer.resumeHrtJourney(
                resume,
                failureInjection: .beforeRevisionCommit
            )
            XCTFail("恢复注入故障必须原子回滚")
        } catch {
            XCTAssertEqual(error as? AppWriteFailure, .injected)
        }
        XCTAssertEqual(try hrtAuditSnapshot(in: container), before)

        let resumed = try await writer.resumeHrtJourney(resume)
        XCTAssertTrue(resumed.didApply)
        XCTAssertNotEqual(
            try hrtAuditSnapshot(in: container),
            before
        )
    }

    private struct HrtAuditSnapshot: Equatable {
        let factsDigest: String
        let eventCount: Int
        let hrtReceiptCount: Int
        let revisionCount: Int
        let nextLocalRevision: Int64
    }

    private enum HrtMutationRevisionTarget: String, CaseIterable {
        case event
        case receipt
        case period
        case profile
        case legacy
        case ledger
    }

    private func revisionKey(
        _ recordType: String,
        _ recordID: UUID
    ) -> String {
        recordType + ":" + recordID.uuidString.lowercased()
    }

    private func hrtAuditSnapshot(
        in container: ModelContainer
    ) throws -> HrtAuditSnapshot {
        let context = ModelContext(container)
        return HrtAuditSnapshot(
            factsDigest: try HrtJourneyLifecycleDigest.facts(
                in: context,
                failure: .corruptionSuspected
            ),
            eventCount: try context.fetchCount(
                FetchDescriptor<HrtJourneyLifecycleEventRecord>()
            ),
            hrtReceiptCount: try context.fetch(
                FetchDescriptor<OperationReceiptRecord>()
            ).filter {
                $0.resultRecordType
                    == "HrtJourneyLifecycleEventRecord"
            }.count,
            revisionCount: try context.fetchCount(
                FetchDescriptor<RecordRevision>()
            ),
            nextLocalRevision: try XCTUnwrap(
                context.fetch(
                    FetchDescriptor<DatasetMetadata>()
                ).first
            ).nextLocalRevision
        )
    }

    private func preparedV9Container() throws -> ModelContainer {
        let container = try AppModelContainerFactory
            .makeInMemoryHrtJourneyLifecycleContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: "UTC",
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        _ = try TodayExecutionBackfill.run(
            in: container,
            now: Date(timeIntervalSince1970: 1_767_225_600)
        )
        return container
    }

    private func preparedV9ContainerWithReconciledCountdownLedger()
        throws -> ModelContainer
    {
        let container = try AppModelContainerFactory
            .makeInMemoryHrtJourneyLifecycleContainer()
        let context = ModelContext(container)
        let legacyCommittedAt = Date(
            timeIntervalSince1970: 1_767_225_600
        )
        let migrationCommittedAt = Date(
            timeIntervalSince1970: 1_767_225_700
        )
        context.insert(
            CountdownRecord(
                title: "旧目标",
                targetDate:
                    legacyCommittedAt.addingTimeInterval(86_400),
                createdAt: legacyCommittedAt
            )
        )
        try context.save()
        _ = try LegacyV1Backfill.run(
            in: container,
            now: legacyCommittedAt
        )
        _ = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: "UTC",
            now: legacyCommittedAt
        )
        _ = try TodayExecutionBackfill.run(
            in: container,
            now: legacyCommittedAt
        )
        _ = try PersonalTimelineBackfill.run(
            in: container,
            now: legacyCommittedAt
        )
        _ = try CountdownLifecycleBackfill.run(
            in: container,
            now: migrationCommittedAt,
            includeIntegrityFacts: true
        )
        return container
    }

    private func refreshRevision(
        for event: HrtJourneyLifecycleEventRecord,
        in context: ModelContext
    ) throws {
        let key =
            "HrtJourneyLifecycleEventRecord:"
            + event.id.uuidString.lowercased()
        let revision = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<RecordRevision>(
                    predicate: #Predicate { $0.recordKey == key }
                )
            ).first
        )
        revision.digestHex = try RecordDigestV1.sha256Hex(
            recordType: "HrtJourneyLifecycleEventRecord",
            recordID: event.id,
            fields: try HrtJourneyLifecycleDigest.event(event)
        )
    }

    private func refreshRevision(
        for profile: HRTProfile,
        in context: ModelContext
    ) throws {
        let key =
            "HRTProfile:" + profile.id.uuidString.lowercased()
        let revision = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<RecordRevision>(
                    predicate: #Predicate { $0.recordKey == key }
                )
            ).first
        )
        revision.digestHex = try RecordDigestV1.sha256Hex(
            recordType: "HRTProfile",
            recordID: profile.id,
            fields: try FactDigestV1.profile(profile)
        )
    }

    private func refreshReceiptAndLedgerRevisions(
        in context: ModelContext
    ) throws {
        let receipts = try context.fetch(
            FetchDescriptor<OperationReceiptRecord>()
        )
        for receipt in receipts {
            let key =
                "OperationReceiptRecord:"
                + receipt.operationID.uuidString.lowercased()
            let revision = try XCTUnwrap(
                try context.fetch(
                    FetchDescriptor<RecordRevision>(
                        predicate: #Predicate {
                            $0.recordKey == key
                        }
                    )
                ).first
            )
            revision.digestHex = try RecordDigestV1.sha256Hex(
                recordType: "OperationReceiptRecord",
                recordID: receipt.operationID,
                fields: try TodayExecutionDigestV1
                    .operationReceipt(receipt)
            )
        }
        let ledger = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<OperationReceiptLedgerRecord>()
            ).first
        )
        ledger.receiptCount = receipts.count
        ledger.receiptSetDigest = try TodayExecutionDigestV1
            .receiptSetDigest(receipts)
        let ledgerKey =
            "OperationReceiptLedgerRecord:"
            + TodayExecutionDigestV1.receiptLedgerID
                .uuidString.lowercased()
        let ledgerRevision = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<RecordRevision>(
                    predicate: #Predicate {
                        $0.recordKey == ledgerKey
                    }
                )
            ).first
        )
        ledgerRevision.digestHex = try RecordDigestV1.sha256Hex(
            recordType: "OperationReceiptLedgerRecord",
            recordID: TodayExecutionDigestV1.receiptLedgerID,
            fields: TodayExecutionDigestV1
                .operationReceiptLedger(ledger)
        )
    }

    private func timestamp(
        localDate: CivilDateFact
    ) throws -> HistoricalTimestamp {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: localDate.year,
                    month: localDate.month,
                    day: localDate.day,
                    hour: 0,
                    minute: 0,
                    second: 0
                )
            )
        )
        return try HistoricalTimestamp(
            validatingInstant: instant,
            localDate: localDate,
            localTime: HistoricalLocalTime(
                hour: 0,
                minute: 0,
                second: 0
            ),
            timeZoneIdentifier: "UTC",
            utcOffsetSeconds: 0,
            precision: .second,
            provenance: .userEntered
        )
    }

    private func timestamp(
        from base: HistoricalTimestamp,
        addingSeconds seconds: TimeInterval
    ) throws -> HistoricalTimestamp {
        try HistoricalTimestamp.captured(
            instant: base.instant.addingTimeInterval(seconds),
            timeZoneIdentifier: base.timeZoneIdentifier,
            precision: .second,
            provenance: .userEntered
        )
    }

    private func displayDate(_ value: CivilDateFact) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(
            from: DateComponents(
                year: value.year,
                month: value.month,
                day: value.day,
                hour: 12
            )
        )!
    }

    private func civilDate(
        _ value: Date,
        timeZone: TimeZone
    ) -> CivilDateFact? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: value
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return nil
        }
        return try? CivilDateFact(
            year: year,
            month: month,
            day: day
        )
    }
}
