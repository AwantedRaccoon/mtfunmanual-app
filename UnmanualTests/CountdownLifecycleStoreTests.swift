import SwiftData
import XCTest
@testable import Unmanual

final class CountdownLifecycleStoreTests: XCTestCase {
    func testCountdownInvalidationFailureReportsCountdownDomainWithoutRollingBack()
        async throws
    {
        let container = try preparedContainer()
        let context = ModelContext(container)
        for record in try context.fetch(
            FetchDescriptor<CountdownNotificationCoverageRecord>()
        ) {
            context.delete(record)
        }
        try context.save()
        let recorder = CountdownReminderChangeRecorder()
        let writer = AppDataWriter(
            storage: AppWriteActor(modelContainer: container),
            verifyStoreProtection: { true },
            onProtectionFailure: {},
            onReminderInputsChanged: { result in
                await recorder.record(result)
            }
        )
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_774_521_600),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let countdownID = UUID()

        let result = try await writer.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: countdownID,
                title: "失效写入失败也不能回滚目标",
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

        XCTAssertTrue(result.didApply)
        XCTAssertNotNil(
            try context.fetch(
                FetchDescriptor<CountdownStateRecord>(
                    predicate: #Predicate { $0.id == countdownID }
                )
            ).first
        )
        let invalidationResults = await recorder.results()
        XCTAssertEqual(
            invalidationResults,
            [.countdown(coverageWasInvalidated: false)]
        )
    }

    func testLegacyCountdownBackfillsToCanonicalCivilDateAndIsIdempotent() throws {
        let container = try AppModelContainerFactory
            .makeInMemoryCountdownLifecycleContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let id = UUID(uuidString: "81000000-0000-0000-0000-000000000001")!
        let target = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-24T05:00:00Z")
        )
        context.insert(
            CountdownRecord(
                id: id,
                title: "复诊",
                gentleTitle: "私人日期",
                targetDate: target,
                createdAt: target.addingTimeInterval(-86_400)
            )
        )
        try context.save()

        XCTAssertTrue(try LegacyV1Backfill.run(in: container).didComplete)
        XCTAssertTrue(
            try CoreTimeRegimenBackfill.run(
                in: container,
                assumedTimeZoneIdentifier: "America/Chicago"
            ).didComplete
        )
        XCTAssertTrue(try TodayExecutionBackfill.run(in: container).didComplete)
        XCTAssertTrue(try PersonalTimelineBackfill.run(in: container).didComplete)

        let first = try CountdownLifecycleBackfill.run(in: container)
        let second = try CountdownLifecycleBackfill.run(in: container)
        XCTAssertTrue(first.didComplete)
        XCTAssertTrue(first.didChangeStore)
        XCTAssertTrue(second.didComplete)
        XCTAssertFalse(second.didChangeStore)

        let states = try context.fetch(FetchDescriptor<CountdownStateRecord>())
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states[0].id, id)
        XCTAssertEqual(states[0].title, "复诊")
        XCTAssertEqual(states[0].gentleTitle, "私人日期")
        XCTAssertEqual(states[0].targetDate?.iso8601, "2026-07-24")
        XCTAssertEqual(states[0].lifecycle, .active)
        XCTAssertEqual(states[0].overdueMode, .awaitingDecision)
        XCTAssertTrue(states[0].showInToday)
        XCTAssertFalse(states[0].requiresReview)

        let backfillStates = try context.fetch(
            FetchDescriptor<CountdownLifecycleBackfillState>()
        )
        XCTAssertEqual(backfillStates.count, 1)
        XCTAssertEqual(
            backfillStates[0].assumedTimeZoneIdentifier,
            "America/Chicago"
        )
        XCTAssertNotNil(backfillStates[0].completedAt)
    }

    func testMultipleLegacyActiveCountdownsAreHiddenForExplicitReview() throws {
        let container = try AppModelContainerFactory
            .makeInMemoryCountdownLifecycleContainer()
        let context = ModelContext(container)
        let target = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-24T05:00:00Z")
        )
        context.insert(CountdownRecord(title: "一", targetDate: target))
        context.insert(CountdownRecord(title: "二", targetDate: target))
        try context.save()

        XCTAssertTrue(try LegacyV1Backfill.run(in: container).didComplete)
        XCTAssertTrue(
            try CoreTimeRegimenBackfill.run(
                in: container,
                assumedTimeZoneIdentifier: "America/Chicago"
            ).didComplete
        )
        XCTAssertTrue(try TodayExecutionBackfill.run(in: container).didComplete)
        XCTAssertTrue(try PersonalTimelineBackfill.run(in: container).didComplete)
        XCTAssertTrue(
            try CountdownLifecycleBackfill.run(in: container).didComplete
        )

        let states = try context.fetch(FetchDescriptor<CountdownStateRecord>())
        XCTAssertEqual(states.count, 2)
        XCTAssertTrue(states.allSatisfy(\.requiresReview))
        XCTAssertTrue(states.allSatisfy { !$0.showInToday })
    }

    func testLegacyReviewBlocksCreationAndCanBeResolvedWithoutHiddenRecords()
        async throws
    {
        let container = try AppModelContainerFactory
            .makeInMemoryCountdownLifecycleContainer()
        let context = ModelContext(container)
        let target = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-24T05:00:00Z")
        )
        let firstID = UUID()
        let secondID = UUID()
        context.insert(
            CountdownRecord(
                id: firstID,
                title: "保留",
                targetDate: target
            )
        )
        context.insert(
            CountdownRecord(
                id: secondID,
                title: "归档",
                targetDate: target
            )
        )
        try context.save()
        XCTAssertTrue(try LegacyV1Backfill.run(in: container).didComplete)
        XCTAssertTrue(
            try CoreTimeRegimenBackfill.run(
                in: container,
                assumedTimeZoneIdentifier: "UTC"
            ).didComplete
        )
        XCTAssertTrue(try TodayExecutionBackfill.run(in: container).didComplete)
        XCTAssertTrue(try PersonalTimelineBackfill.run(in: container).didComplete)
        XCTAssertTrue(
            try CountdownLifecycleBackfill.run(in: container).didComplete
        )
        let reader = AppReadActor(modelContainer: container)
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date().addingTimeInterval(1),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )

        let review = try await reader.countdownReviewPage(
            offset: 0,
            limit: 20
        )
        XCTAssertEqual(Set(review.items.map(\.id)), [firstID, secondID])
        do {
            _ = try await writer.createCountdown(
                CreateCountdownCommand(
                    operationID: UUID(),
                    eventID: UUID(),
                    title: "不应建立",
                    gentleTitle: nil,
                    targetDate: CivilDateFact(
                        year: 2026,
                        month: 8,
                        day: 1
                    ),
                    showInToday: true,
                    reminder: .disabled,
                    timestamp: timestamp
                )
            )
            XCTFail("Review records must block a third active Countdown")
        } catch {
            XCTAssertEqual(
                error as? CountdownWriteFailure,
                .activeCountdownAlreadyExists
            )
        }

        let second = try XCTUnwrap(
            review.items.first(where: { $0.id == secondID })
        )
        _ = try await writer.resolveCountdownReview(
            ResolveCountdownReviewCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: second.id,
                expectedLatestEventID: second.latestEventID,
                resolution: .archive,
                timestamp: timestamp
            )
        )
        let remainingReview = try await reader.countdownReviewPage(
            offset: 0,
            limit: 20
        )
        let first = try XCTUnwrap(remainingReview.items.first)
        XCTAssertEqual(first.id, firstID)
        _ = try await writer.resolveCountdownReview(
            ResolveCountdownReviewCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: first.id,
                expectedLatestEventID: first.latestEventID,
                resolution: .keepAsCurrent,
                timestamp: timestamp
            )
        )

        let resolvedReview = try await reader.countdownReviewPage(
            offset: 0,
            limit: 20
        )
        let resolvedCurrent = try await reader.countdownCurrentSnapshot()
        let resolvedHistory = try await reader.countdownHistoryPage(
            offset: 0,
            limit: 20
        )
        XCTAssertTrue(resolvedReview.items.isEmpty)
        XCTAssertEqual(resolvedCurrent?.id, firstID)
        XCTAssertEqual(resolvedHistory.items.map(\.id), [secondID])
        XCTAssertNoThrow(
            try CountdownLifecycleRelationshipValidator.validate(
                in: ModelContext(container),
                failure: .corruptionSuspected
            )
        )
    }

    func testUpdateClassifiesVisibilityAndReminderOnlyChanges() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_774_521_600),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let countdownID = UUID()
        let createEventID = UUID()
        _ = try await writer.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: createEventID,
                countdownID: countdownID,
                title: "同一内容",
                gentleTitle: nil,
                targetDate: CivilDateFact(
                    year: 2026,
                    month: 8,
                    day: 1
                ),
                showInToday: true,
                reminder: .disabled,
                timestamp: timestamp
            )
        )
        let visibilityEventID = UUID()
        _ = try await writer.updateCountdown(
            UpdateCountdownCommand(
                operationID: UUID(),
                eventID: visibilityEventID,
                countdownID: countdownID,
                expectedLatestEventID: createEventID,
                title: "同一内容",
                gentleTitle: nil,
                targetDate: CivilDateFact(
                    year: 2026,
                    month: 8,
                    day: 1
                ),
                showInToday: false,
                reminder: .disabled,
                timestamp: timestamp
            )
        )
        let reminderEventID = UUID()
        _ = try await writer.updateCountdown(
            UpdateCountdownCommand(
                operationID: UUID(),
                eventID: reminderEventID,
                countdownID: countdownID,
                expectedLatestEventID: visibilityEventID,
                title: "同一内容",
                gentleTitle: nil,
                targetDate: CivilDateFact(
                    year: 2026,
                    month: 8,
                    day: 1
                ),
                showInToday: false,
                reminder: CountdownReminderInput(
                    isEnabled: true,
                    leadDays: 1,
                    localHour: 8,
                    localMinute: 30
                ),
                timestamp: timestamp
            )
        )

        let events = try ModelContext(container).fetch(
            FetchDescriptor<CountdownLifecycleEventRecord>()
        )
        XCTAssertEqual(
            events.first(where: { $0.id == visibilityEventID })?.kind,
            .visibilityChanged
        )
        XCTAssertEqual(
            events.first(where: { $0.id == reminderEventID })?.kind,
            .reminderChanged
        )
    }

    func testArchivedLegacyReviewStaysVisibleForResolutionWithoutBreakingTimeline()
        async throws
    {
        let container = try AppModelContainerFactory
            .makeInMemoryCountdownLifecycleContainer()
        let context = ModelContext(container)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let archivedAt = createdAt.addingTimeInterval(86_400)
        let countdownID = UUID()
        context.insert(
            CountdownRecord(
                id: countdownID,
                title: "旧归档",
                targetDate: createdAt,
                createdAt: createdAt,
                archivedAt: archivedAt,
                continuesCountingUp: true
            )
        )
        try context.save()
        XCTAssertTrue(try LegacyV1Backfill.run(in: container).didComplete)
        XCTAssertTrue(
            try CoreTimeRegimenBackfill.run(
                in: container,
                assumedTimeZoneIdentifier: "UTC"
            ).didComplete
        )
        XCTAssertTrue(try TodayExecutionBackfill.run(in: container).didComplete)
        XCTAssertTrue(try PersonalTimelineBackfill.run(in: container).didComplete)
        XCTAssertTrue(
            try CountdownLifecycleBackfill.run(in: container).didComplete
        )
        let reader = AppReadActor(modelContainer: container)
        let unresolvedTimeline = try await reader.personalTimelinePage(
            limit: 20
        )
        XCTAssertFalse(
            unresolvedTimeline.items.contains {
                $0.kind == .countdown && $0.id == countdownID
            }
        )
        let reviewPage = try await reader.countdownReviewPage(
            offset: 0,
            limit: 20
        )
        let review = try XCTUnwrap(reviewPage.items.first)
        let timestamp = try HistoricalTimestamp.captured(
            instant: archivedAt.addingTimeInterval(86_400),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        _ = try await AppWriteActor(
            modelContainer: container
        ).resolveCountdownReview(
            ResolveCountdownReviewCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: countdownID,
                expectedLatestEventID: review.latestEventID,
                resolution: .keepArchived,
                timestamp: timestamp
            )
        )

        let resolvedTimeline = try await reader.personalTimelinePage(
            limit: 20
        )
        let item = try XCTUnwrap(
            resolvedTimeline.items.first {
                $0.kind == .countdown && $0.id == countdownID
            }
        )
        XCTAssertEqual(item.timestamp?.instant, archivedAt)
        let finalReviewPage = try await reader.countdownReviewPage(
            offset: 0,
            limit: 20
        )
        XCTAssertTrue(finalReviewPage.items.isEmpty)
    }

    func testCreateReplayRetargetContinueAndCompleteAreAuditable() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let countdownID = UUID(uuidString: "82000000-0000-0000-0000-000000000001")!
        let createOperationID = UUID(
            uuidString: "82000000-0000-0000-0000-000000000002"
        )!
        let createEventID = UUID(
            uuidString: "82000000-0000-0000-0000-000000000003"
        )!
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_774_521_600),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let create = CreateCountdownCommand(
            operationID: createOperationID,
            eventID: createEventID,
            countdownID: countdownID,
            title: "旅行",
            gentleTitle: "私人日期",
            targetDate: try CivilDateFact(year: 2026, month: 4, day: 1),
            showInToday: true,
            reminder: CountdownReminderInput(
                isEnabled: true,
                leadDays: 2,
                localHour: 9,
                localMinute: 30
            ),
            timestamp: timestamp,
            committedAt: timestamp.instant
        )

        let first = try await writer.createCountdown(create)
        let replay = try await writer.createCountdown(create)
        XCTAssertTrue(first.didApply)
        XCTAssertFalse(replay.didApply)
        XCTAssertEqual(first.countdownID, countdownID)
        XCTAssertEqual(first.eventID, createEventID)

        let continueEventID = UUID(
            uuidString: "82000000-0000-0000-0000-000000000004"
        )!
        let continued = try await writer.continueCountdown(
            ContinueCountdownCommand(
                operationID: UUID(
                    uuidString: "82000000-0000-0000-0000-000000000005"
                )!,
                eventID: continueEventID,
                countdownID: countdownID,
                expectedLatestEventID: createEventID,
                today: try CivilDateFact(year: 2026, month: 4, day: 1),
                timestamp: timestamp,
                committedAt: timestamp.instant.addingTimeInterval(1)
            )
        )
        XCTAssertTrue(continued.didApply)

        let retargetEventID = UUID(
            uuidString: "82000000-0000-0000-0000-000000000006"
        )!
        let updated = try await writer.updateCountdown(
            UpdateCountdownCommand(
                operationID: UUID(
                    uuidString: "82000000-0000-0000-0000-000000000007"
                )!,
                eventID: retargetEventID,
                countdownID: countdownID,
                expectedLatestEventID: continueEventID,
                title: "新旅行",
                gentleTitle: nil,
                targetDate: try CivilDateFact(year: 2026, month: 5, day: 2),
                showInToday: false,
                reminder: CountdownReminderInput(
                    isEnabled: false,
                    leadDays: 0,
                    localHour: 9,
                    localMinute: 0
                ),
                timestamp: timestamp,
                committedAt: timestamp.instant.addingTimeInterval(2)
            )
        )
        XCTAssertTrue(updated.didApply)

        let completeEventID = UUID(
            uuidString: "82000000-0000-0000-0000-000000000008"
        )!
        let completed = try await writer.completeCountdown(
            CompleteCountdownCommand(
                operationID: UUID(
                    uuidString: "82000000-0000-0000-0000-000000000009"
                )!,
                eventID: completeEventID,
                countdownID: countdownID,
                expectedLatestEventID: retargetEventID,
                today: try CivilDateFact(year: 2026, month: 5, day: 2),
                timestamp: timestamp,
                committedAt: timestamp.instant.addingTimeInterval(3)
            )
        )
        XCTAssertTrue(completed.didApply)

        let context = ModelContext(container)
        let states = try context.fetch(FetchDescriptor<CountdownStateRecord>())
        let state = try XCTUnwrap(states.first)
        XCTAssertEqual(state.lifecycle, .completed)
        XCTAssertEqual(state.overdueMode, .awaitingDecision)
        XCTAssertEqual(state.targetDate?.iso8601, "2026-05-02")
        XCTAssertFalse(state.showInToday)
        XCTAssertEqual(state.latestEventID, completeEventID)
        XCTAssertNotNil(state.completedAt)
        XCTAssertNotNil(state.archivedAt)

        let events = try context.fetch(
            FetchDescriptor<CountdownLifecycleEventRecord>()
        )
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(Set(events.compactMap(\.kind)), [
            .created,
            .continuedCountingUp,
            .edited,
            .completed
        ])
        let reminders = try context.fetch(
            FetchDescriptor<CountdownReminderRuleRecord>()
        )
        XCTAssertEqual(reminders.count, 1)
        XCTAssertFalse(reminders[0].isEnabled)
        XCTAssertEqual(reminders[0].leadDays, 0)
        XCTAssertEqual(state.terminalReminderWasEnabled, false)
        XCTAssertEqual(state.terminalReminderLeadDays, 0)
        XCTAssertEqual(state.terminalReminderLocalHour, 9)
        XCTAssertEqual(state.terminalReminderLocalMinute, 0)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<OperationReceiptRecord>()),
            4
        )
    }

    func testCreateRejectsSecondActiveAndStaleMutationWritesNothing() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_774_521_600),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let firstEventID = UUID()
        let firstID = UUID()
        _ = try await writer.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: firstEventID,
                countdownID: firstID,
                title: "第一项",
                gentleTitle: nil,
                targetDate: try CivilDateFact(year: 2026, month: 4, day: 1),
                showInToday: true,
                reminder: .disabled,
                timestamp: timestamp
            )
        )

        do {
            _ = try await writer.createCountdown(
                CreateCountdownCommand(
                    operationID: UUID(),
                    eventID: UUID(),
                    countdownID: UUID(),
                    title: "第二项",
                    gentleTitle: nil,
                    targetDate: try CivilDateFact(year: 2026, month: 4, day: 2),
                    showInToday: true,
                    reminder: .disabled,
                    timestamp: timestamp
                )
            )
            XCTFail("Expected active Countdown conflict")
        } catch {
            XCTAssertEqual(
                error as? CountdownWriteFailure,
                .activeCountdownAlreadyExists
            )
        }

        let countBefore = try ModelContext(container).fetchCount(
            FetchDescriptor<CountdownLifecycleEventRecord>()
        )
        do {
            _ = try await writer.archiveCountdown(
                ArchiveCountdownCommand(
                    operationID: UUID(),
                    eventID: UUID(),
                    countdownID: firstID,
                    expectedLatestEventID: UUID(),
                    timestamp: timestamp
                )
            )
            XCTFail("Expected stale event")
        } catch {
            XCTAssertEqual(error as? CountdownWriteFailure, .staleRecord)
        }
        let context = ModelContext(container)
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<CountdownLifecycleEventRecord>()
            ),
            countBefore
        )
        XCTAssertEqual(
            try XCTUnwrap(
                context.fetch(FetchDescriptor<CountdownStateRecord>()).first
            ).lifecycle,
            .active
        )
    }

    func testSameOperationWithDifferentDigestIsRejectedWithoutNewFacts()
        async throws
    {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_774_521_600),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let operationID = UUID()
        let first = CreateCountdownCommand(
            operationID: operationID,
            eventID: UUID(),
            countdownID: UUID(),
            title: "原始内容",
            gentleTitle: nil,
            targetDate: try CivilDateFact(
                year: 2026,
                month: 4,
                day: 1
            ),
            showInToday: true,
            reminder: .disabled,
            timestamp: timestamp
        )
        _ = try await writer.createCountdown(first)
        let context = ModelContext(container)
        let eventsBefore = try context.fetchCount(
            FetchDescriptor<CountdownLifecycleEventRecord>()
        )
        let revisionsBefore = try context.fetchCount(
            FetchDescriptor<RecordRevision>()
        )

        do {
            _ = try await writer.createCountdown(
                CreateCountdownCommand(
                    operationID: operationID,
                    eventID: first.eventID,
                    countdownID: first.countdownID,
                    title: "篡改后的内容",
                    gentleTitle: nil,
                    targetDate: first.targetDate,
                    showInToday: true,
                    reminder: .disabled,
                    timestamp: timestamp
                )
            )
            XCTFail("Same operation with a different digest must fail")
        } catch {
            XCTAssertEqual(
                error as? CountdownWriteFailure,
                .operationConflict
            )
        }

        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<CountdownLifecycleEventRecord>()
            ),
            eventsBefore
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<RecordRevision>()),
            revisionsBefore
        )
        XCTAssertEqual(
            try XCTUnwrap(
                context.fetch(FetchDescriptor<CountdownStateRecord>()).first
            ).title,
            "原始内容"
        )
    }

    func testContentOnlyEditPreservesCountingUpMode() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_774_521_600),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let countdownID = UUID()
        let createEventID = UUID()
        _ = try await writer.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: createEventID,
                countdownID: countdownID,
                title: "原名称",
                gentleTitle: nil,
                targetDate: try CivilDateFact(year: 2026, month: 4, day: 1),
                showInToday: true,
                reminder: .disabled,
                timestamp: timestamp
            )
        )
        let continueEventID = UUID()
        _ = try await writer.continueCountdown(
            ContinueCountdownCommand(
                operationID: UUID(),
                eventID: continueEventID,
                countdownID: countdownID,
                expectedLatestEventID: createEventID,
                today: try CivilDateFact(year: 2026, month: 4, day: 1),
                timestamp: timestamp
            )
        )
        _ = try await writer.updateCountdown(
            UpdateCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: countdownID,
                expectedLatestEventID: continueEventID,
                title: "新名称",
                gentleTitle: nil,
                targetDate: try CivilDateFact(year: 2026, month: 4, day: 1),
                showInToday: true,
                reminder: .disabled,
                timestamp: timestamp
            )
        )

        let context = ModelContext(container)
        let state = try XCTUnwrap(
            context.fetch(FetchDescriptor<CountdownStateRecord>()).first
        )
        let legacy = try XCTUnwrap(
            context.fetch(FetchDescriptor<CountdownRecord>()).first
        )
        XCTAssertEqual(state.overdueMode, .countingUp)
        XCTAssertTrue(legacy.continuesCountingUp)
    }

    func testDeleteLeavesOpaqueTombstoneAndRemovesLegacyPayload() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_774_521_600),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let countdownID = UUID()
        let createEventID = UUID()
        _ = try await writer.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: createEventID,
                countdownID: countdownID,
                title: "需要清除的正文",
                gentleTitle: "温和正文",
                targetDate: try CivilDateFact(year: 2026, month: 6, day: 1),
                showInToday: true,
                reminder: CountdownReminderInput(
                    isEnabled: true,
                    leadDays: 1,
                    localHour: 9,
                    localMinute: 0
                ),
                timestamp: timestamp
            )
        )
        let deleteEventID = UUID()
        let command = DeleteCountdownCommand(
            operationID: UUID(),
            eventID: deleteEventID,
            countdownID: countdownID,
            expectedLatestEventID: createEventID,
            timestamp: timestamp
        )

        let first = try await writer.deleteCountdown(command)
        let replay = try await writer.deleteCountdown(command)

        XCTAssertTrue(first.didApply)
        XCTAssertFalse(replay.didApply)
        let context = ModelContext(container)
        let state = try XCTUnwrap(
            context.fetch(FetchDescriptor<CountdownStateRecord>()).first
        )
        XCTAssertEqual(state.lifecycle, .deleted)
        XCTAssertEqual(state.title, "")
        XCTAssertNil(state.gentleTitle)
        XCTAssertNil(state.targetDate)
        XCTAssertFalse(state.showInToday)
        XCTAssertNotNil(state.deletedAt)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<CountdownRecord>()),
            0
        )
        XCTAssertFalse(
            try XCTUnwrap(
                context.fetch(
                    FetchDescriptor<CountdownReminderRuleRecord>()
                ).first
            ).isEnabled
        )
        XCTAssertNoThrow(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    func testReplaceDeletesOldAndCreatesNewInOneAuditedTransaction() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_774_521_600),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let oldID = UUID()
        let oldCreateEventID = UUID()
        _ = try await writer.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: oldCreateEventID,
                countdownID: oldID,
                title: "旧目标",
                gentleTitle: nil,
                targetDate: try CivilDateFact(year: 2026, month: 6, day: 1),
                showInToday: true,
                reminder: .disabled,
                timestamp: timestamp
            )
        )
        let newID = UUID()
        let newEventID = UUID()
        let replace = ReplaceCountdownCommand(
            operationID: UUID(),
            deleteEventID: UUID(),
            newEventID: newEventID,
            countdownID: oldID,
            expectedLatestEventID: oldCreateEventID,
            newCountdownID: newID,
            title: "新目标",
            gentleTitle: "私人日期",
            targetDate: try CivilDateFact(year: 2026, month: 8, day: 1),
            showInToday: false,
            reminder: CountdownReminderInput(
                isEnabled: true,
                leadDays: 7,
                localHour: 8,
                localMinute: 30
            ),
            timestamp: timestamp
        )

        let first = try await writer.replaceCountdown(replace)
        let replay = try await writer.replaceCountdown(replace)

        XCTAssertTrue(first.didApply)
        XCTAssertFalse(replay.didApply)
        XCTAssertEqual(first.countdownID, newID)
        XCTAssertEqual(first.eventID, newEventID)
        let context = ModelContext(container)
        let states = try context.fetch(FetchDescriptor<CountdownStateRecord>())
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(
            states.first(where: { $0.id == oldID })?.lifecycle,
            .deleted
        )
        XCTAssertEqual(
            states.first(where: { $0.id == newID })?.lifecycle,
            .active
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<CountdownRecord>()).map(\.id),
            [newID]
        )
        XCTAssertNoThrow(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    func testReplaceFailureRollsBackOldDeletionAndAllNewCanonicalFacts()
        async throws
    {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_774_521_600),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let oldID = UUID()
        let oldEventID = UUID()
        _ = try await writer.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: oldEventID,
                countdownID: oldID,
                title: "旧目标仍应保留",
                gentleTitle: nil,
                targetDate: try CivilDateFact(
                    year: 2026,
                    month: 6,
                    day: 1
                ),
                showInToday: true,
                reminder: .disabled,
                timestamp: timestamp
            )
        )

        let context = ModelContext(container)
        let newID = UUID()
        let eventCountBefore = try context.fetchCount(
            FetchDescriptor<CountdownLifecycleEventRecord>()
        )

        do {
            _ = try await writer.replaceCountdown(
                ReplaceCountdownCommand(
                    operationID: UUID(),
                    deleteEventID: UUID(),
                    newEventID: UUID(),
                    countdownID: oldID,
                    expectedLatestEventID: oldEventID,
                    newCountdownID: newID,
                    title: "不应建立",
                    gentleTitle: nil,
                    targetDate: try CivilDateFact(
                        year: 2026,
                        month: 8,
                        day: 1
                    ),
                    showInToday: true,
                    reminder: .disabled,
                    timestamp: timestamp,
                    failureInjection:
                        .afterOldDeletionBeforeNewCreation
                )
            )
            XCTFail("Injected unique-key conflict must fail replacement")
        } catch {
            XCTAssertEqual(error as? AppWriteFailure, .injected)
        }

        let states = try context.fetch(FetchDescriptor<CountdownStateRecord>())
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.id, oldID)
        XCTAssertEqual(states.first?.lifecycle, .active)
        XCTAssertEqual(states.first?.title, "旧目标仍应保留")
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<CountdownLifecycleEventRecord>()
            ),
            eventCountBefore
        )
        XCTAssertNotNil(
            try context.fetch(
                FetchDescriptor<CountdownRecord>(
                    predicate: #Predicate { $0.id == oldID }
                )
            ).first
        )
    }

    private func preparedContainer() throws -> ModelContainer {
        let container = try AppModelContainerFactory
            .makeInMemoryCountdownLifecycleContainer()
        XCTAssertTrue(try LegacyV1Backfill.run(in: container).didComplete)
        XCTAssertTrue(
            try CoreTimeRegimenBackfill.run(
                in: container,
                assumedTimeZoneIdentifier: "UTC"
            ).didComplete
        )
        XCTAssertTrue(try TodayExecutionBackfill.run(in: container).didComplete)
        XCTAssertTrue(try PersonalTimelineBackfill.run(in: container).didComplete)
        XCTAssertTrue(
            try CountdownLifecycleBackfill.run(in: container).didComplete
        )
        return container
    }

    private actor CountdownReminderChangeRecorder {
        private var recorded: [ReminderCoverageInvalidationResult] = []

        func record(_ result: ReminderCoverageInvalidationResult) {
            recorded.append(result)
        }

        func results() -> [ReminderCoverageInvalidationResult] {
            recorded
        }
    }
}
