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
        let createdAt = target
            .addingTimeInterval(-86_400)
            .addingTimeInterval(0.5)
        context.insert(
            CountdownRecord(
                id: id,
                title: "复诊",
                gentleTitle: "私人日期",
                targetDate: target,
                createdAt: createdAt
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
        let event = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<CountdownLifecycleEventRecord>()
            ).first
        )
        XCTAssertEqual(event.occurredAt, createdAt)
        XCTAssertNoThrow(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )

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

    func testCompletedLifecycleBackfillAllowsLegalEventGrowthAndLegacyDeletion()
        async throws
    {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let firstTimestamp = try HistoricalTimestamp.captured(
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
                title: "会继续变化的目标",
                gentleTitle: nil,
                targetDate: try CivilDateFact(
                    year: 2026,
                    month: 8,
                    day: 1
                ),
                showInToday: true,
                reminder: .disabled,
                timestamp: firstTimestamp
            )
        )
        let updateTimestamp = try HistoricalTimestamp.captured(
            instant: firstTimestamp.instant.addingTimeInterval(60),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let updateEventID = UUID()
        _ = try await writer.updateCountdown(
            UpdateCountdownCommand(
                operationID: UUID(),
                eventID: updateEventID,
                countdownID: countdownID,
                expectedLatestEventID: createEventID,
                title: "已经编辑过的目标",
                gentleTitle: nil,
                targetDate: try CivilDateFact(
                    year: 2026,
                    month: 8,
                    day: 2
                ),
                showInToday: true,
                reminder: .disabled,
                timestamp: updateTimestamp
            )
        )

        XCTAssertNoThrow(try CountdownLifecycleBackfill.run(in: container))

        let deleteTimestamp = try HistoricalTimestamp.captured(
            instant: updateTimestamp.instant.addingTimeInterval(60),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        _ = try await writer.deleteCountdown(
            DeleteCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: countdownID,
                expectedLatestEventID: updateEventID,
                timestamp: deleteTimestamp
            )
        )

        XCTAssertNoThrow(try CountdownLifecycleBackfill.run(in: container))
        let context = ModelContext(container)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<CountdownRecord>()),
            0
        )
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<CountdownLifecycleEventRecord>()
            ),
            3
        )
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

    func testCreateRejectsWhileArchivedLegacyReviewRemains() async throws {
        let container = try AppModelContainerFactory
            .makeInMemoryCountdownLifecycleContainer()
        let context = ModelContext(container)
        let archivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(
            CountdownRecord(
                title: "仍需核对的旧归档",
                targetDate: archivedAt.addingTimeInterval(-86_400),
                createdAt: archivedAt.addingTimeInterval(-172_800),
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
        let review = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CountdownStateRecord>()).first
        )
        XCTAssertEqual(review.lifecycle, .archived)
        XCTAssertTrue(review.requiresReview)
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: archivedAt.addingTimeInterval(86_400),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )

        do {
            _ = try await writer.createCountdown(
                CreateCountdownCommand(
                    operationID: UUID(),
                    eventID: UUID(),
                    title: "不应建立的新目标",
                    gentleTitle: nil,
                    targetDate: timestamp.localDate,
                    showInToday: true,
                    reminder: .disabled,
                    timestamp: timestamp
                )
            )
            XCTFail("Any unresolved legacy review must block creation")
        } catch {
            XCTAssertEqual(
                error as? CountdownWriteFailure,
                .invalidTransition
            )
        }
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<CountdownStateRecord>()
            ),
            1
        )
    }

    func testReplaceRejectsWhileArchivedLegacyReviewRemainsWithoutMutation()
        async throws
    {
        let container = try AppModelContainerFactory
            .makeInMemoryCountdownLifecycleContainer()
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let activeID = UUID()
        let archivedReviewID = UUID()
        context.insert(
            CountdownRecord(
                id: activeID,
                title: "正常进行中的旧目标",
                targetDate: base.addingTimeInterval(86_400),
                createdAt: base
            )
        )
        context.insert(
            CountdownRecord(
                id: archivedReviewID,
                title: "仍需核对的旧归档",
                targetDate: base.addingTimeInterval(-86_400),
                createdAt: base.addingTimeInterval(-172_800),
                archivedAt: base.addingTimeInterval(-43_200),
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

        let statesBefore = try context.fetch(
            FetchDescriptor<CountdownStateRecord>()
        )
        let active = try XCTUnwrap(
            statesBefore.first { $0.id == activeID }
        )
        let archivedReview = try XCTUnwrap(
            statesBefore.first { $0.id == archivedReviewID }
        )
        XCTAssertEqual(active.lifecycle, .active)
        XCTAssertFalse(active.requiresReview)
        XCTAssertEqual(archivedReview.lifecycle, .archived)
        XCTAssertTrue(archivedReview.requiresReview)
        let eventCountBefore = try context.fetchCount(
            FetchDescriptor<CountdownLifecycleEventRecord>()
        )
        let receiptCountBefore = try context.fetchCount(
            FetchDescriptor<OperationReceiptRecord>()
        )
        let revisionCountBefore = try context.fetchCount(
            FetchDescriptor<RecordRevision>()
        )
        let metadataBefore = try XCTUnwrap(
            try context.fetch(FetchDescriptor<DatasetMetadata>()).first
        )
        let nextRevisionBefore = metadataBefore.nextLocalRevision
        let replacementID = UUID()
        let timestamp = try HistoricalTimestamp.captured(
            instant: base.addingTimeInterval(172_800),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )

        do {
            _ = try await AppWriteActor(
                modelContainer: container
            ).replaceCountdown(
                ReplaceCountdownCommand(
                    operationID: UUID(),
                    deleteEventID: UUID(),
                    newEventID: UUID(),
                    countdownID: activeID,
                    expectedLatestEventID: active.latestEventID,
                    newCountdownID: replacementID,
                    title: "不应建立的新目标",
                    gentleTitle: nil,
                    targetDate: timestamp.localDate,
                    showInToday: true,
                    reminder: .disabled,
                    timestamp: timestamp
                )
            )
            XCTFail("Any unresolved legacy review must block replacement")
        } catch {
            XCTAssertEqual(
                error as? CountdownWriteFailure,
                .invalidTransition
            )
        }

        let statesAfter = try context.fetch(
            FetchDescriptor<CountdownStateRecord>()
        )
        XCTAssertEqual(statesAfter.count, statesBefore.count)
        XCTAssertNil(statesAfter.first { $0.id == replacementID })
        XCTAssertEqual(
            statesAfter.first { $0.id == activeID }?.lifecycle,
            .active
        )
        XCTAssertEqual(
            statesAfter.first { $0.id == activeID }?.latestEventID,
            active.latestEventID
        )
        XCTAssertTrue(
            try XCTUnwrap(
                statesAfter.first { $0.id == archivedReviewID }
            ).requiresReview
        )
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<CountdownLifecycleEventRecord>()
            ),
            eventCountBefore
        )
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<OperationReceiptRecord>()
            ),
            receiptCountBefore
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<RecordRevision>()),
            revisionCountBefore
        )
        XCTAssertEqual(metadataBefore.nextLocalRevision, nextRevisionBefore)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<CountdownRecord>()),
            2
        )
    }

    func testMigrationReceiptRejectsSilentlyResolvedMultipleActiveReview()
        throws
    {
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
                assumedTimeZoneIdentifier: "UTC"
            ).didComplete
        )
        XCTAssertTrue(try TodayExecutionBackfill.run(in: container).didComplete)
        XCTAssertTrue(try PersonalTimelineBackfill.run(in: container).didComplete)
        XCTAssertTrue(
            try CountdownLifecycleBackfill.run(in: container).didComplete
        )
        let state = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<CountdownStateRecord>(
                    sortBy: [SortDescriptor(\.id)]
                )
            ).first
        )
        state.requiresReview = false
        state.showInToday = true
        try rewriteRevisionDigest(
            recordType: "CountdownStateRecord",
            recordID: state.id,
            fields: CountdownDigestV1.state(state),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testMigrationReceiptRejectsMigratedRootRelabeledAsCreated() throws {
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
                assumedTimeZoneIdentifier: "UTC"
            ).didComplete
        )
        XCTAssertTrue(try TodayExecutionBackfill.run(in: container).didComplete)
        XCTAssertTrue(try PersonalTimelineBackfill.run(in: container).didComplete)
        XCTAssertTrue(
            try CountdownLifecycleBackfill.run(in: container).didComplete
        )
        let state = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<CountdownStateRecord>(
                    sortBy: [SortDescriptor(\.id)]
                )
            ).first
        )
        let eventID = state.latestEventID
        let event = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<CountdownLifecycleEventRecord>(
                    predicate: #Predicate { $0.id == eventID }
                )
            ).first
        )
        state.requiresReview = false
        state.showInToday = true
        event.kindRawValue = CountdownLifecycleEventKind.created.rawValue
        try rewriteRevisionDigest(
            recordType: "CountdownStateRecord",
            recordID: state.id,
            fields: CountdownDigestV1.state(state),
            in: context
        )
        try rewriteRevisionDigest(
            recordType: "CountdownLifecycleEventRecord",
            recordID: event.id,
            fields: CountdownDigestV1.event(event),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testMigrationReceiptRejectsRedigestedLegacyCreatedAt() throws {
        let container = try AppModelContainerFactory
            .makeInMemoryCountdownLifecycleContainer()
        let context = ModelContext(container)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000.5)
        context.insert(
            CountdownRecord(
                title: "迁移时间篡改",
                targetDate: createdAt.addingTimeInterval(86_400),
                createdAt: createdAt
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
        let state = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CountdownStateRecord>()).first
        )
        let legacy = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CountdownRecord>()).first
        )
        let forgedCreatedAt = createdAt.addingTimeInterval(-3_600)
        state.createdAt = forgedCreatedAt
        legacy.createdAt = forgedCreatedAt
        try rewriteRevisionDigest(
            recordType: "CountdownStateRecord",
            recordID: state.id,
            fields: CountdownDigestV1.state(state),
            in: context
        )
        try rewriteRevisionDigest(
            recordType: "CountdownRecord",
            recordID: legacy.id,
            fields: FactDigestV1.countdown(legacy),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
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
            after: nil,
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
            after: nil,
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
            after: nil,
            limit: 20
        )
        let resolvedCurrent = try await reader.countdownCurrentSnapshot()
        let resolvedHistory = try await reader.countdownHistoryPage(
            after: nil,
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
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000.25)
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
            after: nil,
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
            after: nil,
            limit: 20
        )
        XCTAssertTrue(finalReviewPage.items.isEmpty)
        XCTAssertNoThrow(
            try CountdownLifecycleRelationshipValidator.validate(
                in: ModelContext(container),
                failure: .corruptionSuspected
            )
        )
    }

    func testRelationshipValidatorRejectsRedigestedCountingUpAfterKeepArchived()
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
                title: "旧归档篡改",
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
        let reviewPage = try await reader.countdownReviewPage(
            after: nil,
            limit: 20
        )
        let review = try XCTUnwrap(
            reviewPage.items.first
        )
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

        let tamperContext = ModelContext(container)
        let state = try XCTUnwrap(
            try tamperContext.fetch(
                FetchDescriptor<CountdownStateRecord>()
            ).first
        )
        let legacy = try XCTUnwrap(
            try tamperContext.fetch(
                FetchDescriptor<CountdownRecord>()
            ).first
        )
        state.overdueModeRawValue = CountdownOverdueMode.countingUp.rawValue
        legacy.continuesCountingUp = true
        try rewriteRevisionDigest(
            recordType: "CountdownStateRecord",
            recordID: state.id,
            fields: CountdownDigestV1.state(state),
            in: tamperContext
        )
        try rewriteRevisionDigest(
            recordType: "CountdownRecord",
            recordID: legacy.id,
            fields: FactDigestV1.countdown(legacy),
            in: tamperContext
        )
        try tamperContext.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: tamperContext,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }

        state.overdueModeRawValue =
            CountdownOverdueMode.awaitingDecision.rawValue
        state.requiresReview = true
        legacy.continuesCountingUp = false
        try rewriteRevisionDigest(
            recordType: "CountdownStateRecord",
            recordID: state.id,
            fields: CountdownDigestV1.state(state),
            in: tamperContext
        )
        try rewriteRevisionDigest(
            recordType: "CountdownRecord",
            recordID: legacy.id,
            fields: FactDigestV1.countdown(legacy),
            in: tamperContext
        )
        try tamperContext.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: tamperContext,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testRelationshipValidatorRejectsRedigestedLegacyTargetAfterCreate()
        async throws
    {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_774_521_600),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let countdownID = UUID()
        _ = try await writer.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: countdownID,
                title: "目标日关系",
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
        let legacy = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CountdownRecord>()).first
        )
        legacy.targetDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-06-02T12:00:00Z")
        )
        try rewriteRevisionDigest(
            recordType: "CountdownRecord",
            recordID: legacy.id,
            fields: FactDigestV1.countdown(legacy),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testRelationshipValidatorRejectsRedigestedCreatedAtAfterCreate()
        async throws
    {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_774_521_600),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let countdownID = UUID()
        _ = try await writer.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: countdownID,
                title: "创建时间关系",
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
        let state = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CountdownStateRecord>()).first
        )
        let legacy = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CountdownRecord>()).first
        )
        let tamperedCreatedAt = timestamp.instant.addingTimeInterval(60)
        state.createdAt = tamperedCreatedAt
        legacy.createdAt = tamperedCreatedAt
        try rewriteRevisionDigest(
            recordType: "CountdownStateRecord",
            recordID: state.id,
            fields: CountdownDigestV1.state(state),
            in: context
        )
        try rewriteRevisionDigest(
            recordType: "CountdownRecord",
            recordID: legacy.id,
            fields: FactDigestV1.countdown(legacy),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testRelationshipValidatorUsesRetargetTimeZoneAfterLaterContentEdit()
        async throws
    {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let createTimestamp = try HistoricalTimestamp.captured(
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
                title: "改期前",
                gentleTitle: nil,
                targetDate: try CivilDateFact(
                    year: 2026,
                    month: 6,
                    day: 1
                ),
                showInToday: true,
                reminder: .disabled,
                timestamp: createTimestamp
            )
        )
        let retargetTimestamp = try HistoricalTimestamp.captured(
            instant: createTimestamp.instant.addingTimeInterval(3_600),
            timeZoneIdentifier: "America/Chicago",
            provenance: .userEntered
        )
        let retargetEventID = UUID()
        let retarget = try CivilDateFact(year: 2026, month: 6, day: 2)
        _ = try await writer.updateCountdown(
            UpdateCountdownCommand(
                operationID: UUID(),
                eventID: retargetEventID,
                countdownID: countdownID,
                expectedLatestEventID: createEventID,
                title: "改期后",
                gentleTitle: nil,
                targetDate: retarget,
                showInToday: true,
                reminder: .disabled,
                timestamp: retargetTimestamp
            )
        )
        let contentTimestamp = try HistoricalTimestamp.captured(
            instant: retargetTimestamp.instant.addingTimeInterval(3_600),
            timeZoneIdentifier: "Asia/Tokyo",
            provenance: .userEntered
        )
        _ = try await writer.updateCountdown(
            UpdateCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: countdownID,
                expectedLatestEventID: retargetEventID,
                title: "只改标题",
                gentleTitle: nil,
                targetDate: retarget,
                showInToday: true,
                reminder: .disabled,
                timestamp: contentTimestamp
            )
        )

        let context = ModelContext(container)
        XCTAssertNoThrow(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
        let legacy = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CountdownRecord>()).first
        )
        var chicago = Calendar(identifier: .gregorian)
        chicago.timeZone = try XCTUnwrap(
            TimeZone(identifier: "America/Chicago")
        )
        legacy.targetDate = try XCTUnwrap(
            chicago.date(
                from: DateComponents(
                    calendar: chicago,
                    timeZone: chicago.timeZone,
                    year: 2026,
                    month: 6,
                    day: 3,
                    hour: 12
                )
            )
        )
        try rewriteRevisionDigest(
            recordType: "CountdownRecord",
            recordID: legacy.id,
            fields: FactDigestV1.countdown(legacy),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
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
        let continueTimestamp = try HistoricalTimestamp.captured(
            instant: try XCTUnwrap(
                ISO8601DateFormatter().date(
                    from: "2026-04-01T12:00:00Z"
                )
            ),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let updateTimestamp = try HistoricalTimestamp.captured(
            instant: try XCTUnwrap(
                ISO8601DateFormatter().date(
                    from: "2026-04-02T12:00:00Z"
                )
            ),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let completionTimestamp = try HistoricalTimestamp.captured(
            instant: try XCTUnwrap(
                ISO8601DateFormatter().date(
                    from: "2026-05-02T12:00:00Z"
                )
            ),
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
                timestamp: continueTimestamp
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
                timestamp: updateTimestamp
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
                timestamp: completionTimestamp
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

    func testContinueRejectsASecondTransitionAndWritesNothing() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let instant = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-04-01T12:00:00Z")
        )
        let timestamp = try HistoricalTimestamp.captured(
            instant: instant,
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
                title: "一次转换",
                gentleTitle: nil,
                targetDate: timestamp.localDate,
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
                today: timestamp.localDate,
                timestamp: timestamp
            )
        )
        let context = ModelContext(container)
        let eventsBefore = try context.fetchCount(
            FetchDescriptor<CountdownLifecycleEventRecord>()
        )
        let receiptsBefore = try context.fetchCount(
            FetchDescriptor<OperationReceiptRecord>()
        )
        let revisionsBefore = try context.fetchCount(
            FetchDescriptor<RecordRevision>()
        )

        do {
            _ = try await writer.continueCountdown(
                ContinueCountdownCommand(
                    operationID: UUID(),
                    eventID: UUID(),
                    countdownID: countdownID,
                    expectedLatestEventID: continueEventID,
                    today: timestamp.localDate,
                    timestamp: timestamp
                )
            )
            XCTFail("Counting-up mode must not transition to itself")
        } catch {
            XCTAssertEqual(
                error as? CountdownWriteFailure,
                .invalidTransition
            )
        }

        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<CountdownLifecycleEventRecord>()
            ),
            eventsBefore
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<OperationReceiptRecord>()),
            receiptsBefore
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<RecordRevision>()),
            revisionsBefore
        )
    }

    func testReceiptRejectsRedigestedContinueRelabeledAsEdit() async throws {
        let fixture = try await makeContinuedCountdownFixture()
        let context = ModelContext(fixture.container)
        let countdownID = fixture.countdownID
        let latestEventID = fixture.latestEventID
        let state = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<CountdownStateRecord>(
                    predicate: #Predicate { $0.id == countdownID }
                )
            ).first
        )
        let event = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<CountdownLifecycleEventRecord>(
                    predicate: #Predicate { $0.id == latestEventID }
                )
            ).first
        )
        let legacy = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<CountdownRecord>(
                    predicate: #Predicate { $0.id == countdownID }
                )
            ).first
        )
        event.kindRawValue = CountdownLifecycleEventKind.edited.rawValue
        state.overdueModeRawValue =
            CountdownOverdueMode.awaitingDecision.rawValue
        legacy.continuesCountingUp = false
        try rewriteRevisionDigest(
            recordType: "CountdownLifecycleEventRecord",
            recordID: event.id,
            fields: CountdownDigestV1.event(event),
            in: context
        )
        try rewriteRevisionDigest(
            recordType: "CountdownStateRecord",
            recordID: state.id,
            fields: CountdownDigestV1.state(state),
            in: context
        )
        try rewriteRevisionDigest(
            recordType: "CountdownRecord",
            recordID: legacy.id,
            fields: FactDigestV1.countdown(legacy),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testClockCorrectionDoesNotMakeSuccessfulEditFailValidation()
        async throws
    {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let futureTimestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_900_000_000),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let correctedTimestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_800_000_000),
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
                title: "时钟校正",
                gentleTitle: nil,
                targetDate: futureTimestamp.localDate,
                showInToday: true,
                reminder: .disabled,
                timestamp: futureTimestamp
            )
        )
        _ = try await writer.updateCountdown(
            UpdateCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: countdownID,
                expectedLatestEventID: createEventID,
                title: "时钟校正后的编辑",
                gentleTitle: nil,
                targetDate: futureTimestamp.localDate,
                showInToday: true,
                reminder: .disabled,
                timestamp: correctedTimestamp
            )
        )

        let context = ModelContext(container)
        let state = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<CountdownStateRecord>(
                    predicate: #Predicate { $0.id == countdownID }
                )
            ).first
        )
        XCTAssertLessThan(state.updatedAt, state.createdAt)
        XCTAssertNoThrow(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    func testTerminalReminderSnapshotRejectsRedigestedStateTamper()
        async throws
    {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_800_000_000),
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
                title: "提醒快照",
                gentleTitle: nil,
                targetDate: timestamp.localDate,
                showInToday: true,
                reminder: CountdownReminderInput(
                    isEnabled: true,
                    leadDays: 3,
                    localHour: 8,
                    localMinute: 30
                ),
                timestamp: timestamp
            )
        )
        _ = try await writer.archiveCountdown(
            ArchiveCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: countdownID,
                expectedLatestEventID: createEventID,
                timestamp: timestamp
            )
        )

        let context = ModelContext(container)
        let state = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<CountdownStateRecord>(
                    predicate: #Predicate { $0.id == countdownID }
                )
            ).first
        )
        XCTAssertEqual(state.terminalReminderWasEnabled, true)
        state.terminalReminderWasEnabled = false
        state.terminalReminderLeadDays = 0
        state.terminalReminderLocalHour = 9
        state.terminalReminderLocalMinute = 0
        try rewriteRevisionDigest(
            recordType: "CountdownStateRecord",
            recordID: state.id,
            fields: CountdownDigestV1.state(state),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testRetargetResetsContinueCycleAndRelationshipValidationAcceptsSecondContinue()
        async throws
    {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let countdownID = UUID()
        let createEventID = UUID()
        let firstTargetTimestamp = try HistoricalTimestamp.captured(
            instant: try XCTUnwrap(
                ISO8601DateFormatter().date(
                    from: "2026-04-01T12:00:00Z"
                )
            ),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        _ = try await writer.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: createEventID,
                countdownID: countdownID,
                title: "可以重新开始计日",
                gentleTitle: nil,
                targetDate: firstTargetTimestamp.localDate,
                showInToday: true,
                reminder: .disabled,
                timestamp: firstTargetTimestamp
            )
        )
        let firstContinueEventID = UUID()
        _ = try await writer.continueCountdown(
            ContinueCountdownCommand(
                operationID: UUID(),
                eventID: firstContinueEventID,
                countdownID: countdownID,
                expectedLatestEventID: createEventID,
                today: firstTargetTimestamp.localDate,
                timestamp: firstTargetTimestamp
            )
        )
        let retargetTimestamp = try HistoricalTimestamp.captured(
            instant: try XCTUnwrap(
                ISO8601DateFormatter().date(
                    from: "2026-04-02T12:00:00Z"
                )
            ),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let secondTargetTimestamp = try HistoricalTimestamp.captured(
            instant: try XCTUnwrap(
                ISO8601DateFormatter().date(
                    from: "2026-05-02T12:00:00Z"
                )
            ),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let retargetEventID = UUID()
        _ = try await writer.updateCountdown(
            UpdateCountdownCommand(
                operationID: UUID(),
                eventID: retargetEventID,
                countdownID: countdownID,
                expectedLatestEventID: firstContinueEventID,
                title: "可以重新开始计日",
                gentleTitle: nil,
                targetDate: secondTargetTimestamp.localDate,
                showInToday: true,
                reminder: .disabled,
                timestamp: retargetTimestamp
            )
        )
        let secondContinueEventID = UUID()
        _ = try await writer.continueCountdown(
            ContinueCountdownCommand(
                operationID: UUID(),
                eventID: secondContinueEventID,
                countdownID: countdownID,
                expectedLatestEventID: retargetEventID,
                today: secondTargetTimestamp.localDate,
                timestamp: secondTargetTimestamp
            )
        )

        let context = ModelContext(container)
        XCTAssertNoThrow(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<CountdownStateRecord>())
                .first?.overdueMode,
            .countingUp
        )
    }

    func testRelationshipValidatorRejectsRedigestedAwaitingModeAfterContinue()
        async throws
    {
        let fixture = try await makeContinuedCountdownFixture()
        let editTimestamp = try HistoricalTimestamp.captured(
            instant: fixture.timestamp.instant.addingTimeInterval(60),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        _ = try await fixture.writer.updateCountdown(
            UpdateCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: fixture.countdownID,
                expectedLatestEventID: fixture.latestEventID,
                title: "继续后只改名称",
                gentleTitle: nil,
                targetDate: fixture.timestamp.localDate,
                showInToday: true,
                reminder: .disabled,
                timestamp: editTimestamp
            )
        )

        let context = ModelContext(fixture.container)
        let state = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CountdownStateRecord>()).first
        )
        let legacy = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CountdownRecord>()).first
        )
        state.overdueModeRawValue =
            CountdownOverdueMode.awaitingDecision.rawValue
        legacy.continuesCountingUp = false
        try rewriteRevisionDigest(
            recordType: "CountdownStateRecord",
            recordID: state.id,
            fields: CountdownDigestV1.state(state),
            in: context
        )
        try rewriteRevisionDigest(
            recordType: "CountdownRecord",
            recordID: legacy.id,
            fields: FactDigestV1.countdown(legacy),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testRelationshipValidatorRejectsRedigestedCountingUpWithoutContinue()
        async throws
    {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: try XCTUnwrap(
                ISO8601DateFormatter().date(
                    from: "2026-04-01T12:00:00Z"
                )
            ),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        _ = try await writer.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: UUID(),
                title: "没有继续事件",
                gentleTitle: nil,
                targetDate: timestamp.localDate,
                showInToday: true,
                reminder: .disabled,
                timestamp: timestamp
            )
        )

        let context = ModelContext(container)
        let state = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CountdownStateRecord>()).first
        )
        let legacy = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CountdownRecord>()).first
        )
        state.overdueModeRawValue = CountdownOverdueMode.countingUp.rawValue
        legacy.continuesCountingUp = true
        try rewriteRevisionDigest(
            recordType: "CountdownStateRecord",
            recordID: state.id,
            fields: CountdownDigestV1.state(state),
            in: context
        )
        try rewriteRevisionDigest(
            recordType: "CountdownRecord",
            recordID: legacy.id,
            fields: FactDigestV1.countdown(legacy),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testRelationshipValidatorRejectsRedigestedNonMigratedActiveReview()
        async throws
    {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: try XCTUnwrap(
                ISO8601DateFormatter().date(
                    from: "2026-04-01T12:00:00Z"
                )
            ),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        _ = try await writer.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: UUID(),
                title: "伪造复核",
                gentleTitle: nil,
                targetDate: timestamp.localDate,
                showInToday: true,
                reminder: .disabled,
                timestamp: timestamp
            )
        )

        let context = ModelContext(container)
        let state = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CountdownStateRecord>()).first
        )
        state.requiresReview = true
        state.showInToday = false
        try rewriteRevisionDigest(
            recordType: "CountdownStateRecord",
            recordID: state.id,
            fields: CountdownDigestV1.state(state),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testMigratedCountingUpSnapshotPassesRelationshipValidation() throws {
        let container = try AppModelContainerFactory
            .makeInMemoryCountdownLifecycleContainer()
        let context = ModelContext(container)
        let target = try XCTUnwrap(
            ISO8601DateFormatter().date(
                from: "2026-04-01T12:00:00Z"
            )
        )
        context.insert(
            CountdownRecord(
                title: "旧数据继续计日",
                targetDate: target,
                createdAt: target,
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

        XCTAssertEqual(
            try context.fetch(FetchDescriptor<CountdownStateRecord>())
                .first?.overdueMode,
            .countingUp
        )
        XCTAssertNoThrow(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    func testCompleteAfterContinuePassesRelationshipValidation() async throws {
        let fixture = try await makeContinuedCountdownFixture()
        let terminalTimestamp = try HistoricalTimestamp.captured(
            instant: fixture.timestamp.instant.addingTimeInterval(60),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        _ = try await fixture.writer.completeCountdown(
            CompleteCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: fixture.countdownID,
                expectedLatestEventID: fixture.latestEventID,
                today: terminalTimestamp.localDate,
                timestamp: terminalTimestamp
            )
        )

        XCTAssertNoThrow(
            try CountdownLifecycleRelationshipValidator.validate(
                in: ModelContext(fixture.container),
                failure: .corruptionSuspected
            )
        )
    }

    func testArchiveAfterContinuePassesRelationshipValidation() async throws {
        let fixture = try await makeContinuedCountdownFixture()
        let terminalTimestamp = try HistoricalTimestamp.captured(
            instant: fixture.timestamp.instant.addingTimeInterval(60),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        _ = try await fixture.writer.archiveCountdown(
            ArchiveCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: fixture.countdownID,
                expectedLatestEventID: fixture.latestEventID,
                timestamp: terminalTimestamp
            )
        )

        XCTAssertNoThrow(
            try CountdownLifecycleRelationshipValidator.validate(
                in: ModelContext(fixture.container),
                failure: .corruptionSuspected
            )
        )
    }

    func testRelationshipValidatorRejectsRedigestedArchivedAt()
        async throws
    {
        let fixture = try await makeContinuedCountdownFixture()
        let terminalTimestamp = try HistoricalTimestamp.captured(
            instant: fixture.timestamp.instant.addingTimeInterval(60),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        _ = try await fixture.writer.archiveCountdown(
            ArchiveCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: fixture.countdownID,
                expectedLatestEventID: fixture.latestEventID,
                timestamp: terminalTimestamp
            )
        )

        let context = ModelContext(fixture.container)
        let state = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CountdownStateRecord>()).first
        )
        let legacy = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CountdownRecord>()).first
        )
        let forgedArchivedAt = terminalTimestamp.instant
            .addingTimeInterval(3_600)
        state.archivedAt = forgedArchivedAt
        legacy.archivedAt = forgedArchivedAt
        try rewriteRevisionDigest(
            recordType: "CountdownStateRecord",
            recordID: state.id,
            fields: CountdownDigestV1.state(state),
            in: context
        )
        try rewriteRevisionDigest(
            recordType: "CountdownRecord",
            recordID: legacy.id,
            fields: FactDigestV1.countdown(legacy),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testRelationshipValidatorRejectsRedigestedCompletedReviewState()
        async throws
    {
        let fixture = try await makeContinuedCountdownFixture()
        let terminalTimestamp = try HistoricalTimestamp.captured(
            instant: fixture.timestamp.instant.addingTimeInterval(60),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        _ = try await fixture.writer.completeCountdown(
            CompleteCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: fixture.countdownID,
                expectedLatestEventID: fixture.latestEventID,
                today: terminalTimestamp.localDate,
                timestamp: terminalTimestamp
            )
        )

        let context = ModelContext(fixture.container)
        let state = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CountdownStateRecord>()).first
        )
        state.requiresReview = true
        try rewriteRevisionDigest(
            recordType: "CountdownStateRecord",
            recordID: state.id,
            fields: CountdownDigestV1.state(state),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testRelationshipValidatorRejectsRedigestedContinueBeforeTarget()
        async throws
    {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let countdownID = UUID()
        let createEventID = UUID()
        let targetTimestamp = try HistoricalTimestamp.captured(
            instant: try XCTUnwrap(
                ISO8601DateFormatter().date(
                    from: "2026-04-01T12:00:00Z"
                )
            ),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        _ = try await writer.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: createEventID,
                countdownID: countdownID,
                title: "不能提前计日",
                gentleTitle: nil,
                targetDate: targetTimestamp.localDate,
                showInToday: true,
                reminder: .disabled,
                timestamp: targetTimestamp
            )
        )
        let continueEventID = UUID()
        _ = try await writer.continueCountdown(
            ContinueCountdownCommand(
                operationID: UUID(),
                eventID: continueEventID,
                countdownID: countdownID,
                expectedLatestEventID: createEventID,
                today: targetTimestamp.localDate,
                timestamp: targetTimestamp
            )
        )
        let editTimestamp = try HistoricalTimestamp.captured(
            instant: try XCTUnwrap(
                ISO8601DateFormatter().date(
                    from: "2026-04-02T12:00:00Z"
                )
            ),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        _ = try await writer.updateCountdown(
            UpdateCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: countdownID,
                expectedLatestEventID: continueEventID,
                title: "不能提前计日（已编辑）",
                gentleTitle: nil,
                targetDate: targetTimestamp.localDate,
                showInToday: true,
                reminder: .disabled,
                timestamp: editTimestamp
            )
        )

        let context = ModelContext(container)
        let tampered = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<CountdownLifecycleEventRecord>(
                    predicate: #Predicate {
                        $0.id == continueEventID
                    }
                )
            ).first
        )
        let beforeTarget = try HistoricalTimestamp.captured(
            instant: try XCTUnwrap(
                ISO8601DateFormatter().date(
                    from: "2026-03-31T12:00:00Z"
                )
            ),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        tampered.occurredAt = beforeTarget.instant
        tampered.localYear = beforeTarget.localDate.year
        tampered.localMonth = beforeTarget.localDate.month
        tampered.localDay = beforeTarget.localDate.day
        tampered.localHour = beforeTarget.localTime.hour
        tampered.localMinute = beforeTarget.localTime.minute
        tampered.localSecond = beforeTarget.localTime.second
        tampered.localNanosecond = beforeTarget.localTime.nanosecond
        tampered.utcOffsetSeconds = beforeTarget.utcOffsetSeconds
        try rewriteRevisionDigest(
            recordType: "CountdownLifecycleEventRecord",
            recordID: tampered.id,
            fields: CountdownDigestV1.event(tampered),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testRelationshipValidatorRejectsRedigestedDeletedReminderPreferences()
        async throws
    {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: try XCTUnwrap(
                ISO8601DateFormatter().date(
                    from: "2026-04-01T12:00:00Z"
                )
            ),
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
                title: "删除后不留提醒偏好",
                gentleTitle: nil,
                targetDate: try CivilDateFact(
                    year: 2026,
                    month: 6,
                    day: 1
                ),
                showInToday: true,
                reminder: CountdownReminderInput(
                    isEnabled: true,
                    leadDays: 7,
                    localHour: 8,
                    localMinute: 30
                ),
                timestamp: timestamp
            )
        )
        _ = try await writer.deleteCountdown(
            DeleteCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: countdownID,
                expectedLatestEventID: createEventID,
                timestamp: timestamp
            )
        )

        let context = ModelContext(container)
        let reminder = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<CountdownReminderRuleRecord>(
                    predicate: #Predicate {
                        $0.countdownID == countdownID
                    }
                )
            ).first
        )
        reminder.leadDays = 7
        reminder.localHour = 8
        reminder.localMinute = 30
        try rewriteRevisionDigest(
            recordType: "CountdownReminderRuleRecord",
            recordID: reminder.id,
            fields: CountdownDigestV1.reminder(reminder),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testTerminalTransitionsRejectTodayThatDisagreesWithCapturedTimestamp()
        async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: try XCTUnwrap(
                ISO8601DateFormatter().date(
                    from: "2026-04-01T12:00:00Z"
                )
            ),
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
                title: "时间一致性",
                gentleTitle: nil,
                targetDate: timestamp.localDate,
                showInToday: true,
                reminder: .disabled,
                timestamp: timestamp
            )
        )
        let context = ModelContext(container)
        let eventCount = try context.fetchCount(
            FetchDescriptor<CountdownLifecycleEventRecord>()
        )
        let receiptCount = try context.fetchCount(
            FetchDescriptor<OperationReceiptRecord>()
        )
        let revisionCount = try context.fetchCount(
            FetchDescriptor<RecordRevision>()
        )
        let mismatchedToday = try CivilDateFact(
            year: 2026,
            month: 4,
            day: 2
        )

        for transition in [
            {
                try await writer.continueCountdown(
                    ContinueCountdownCommand(
                        operationID: UUID(),
                        eventID: UUID(),
                        countdownID: countdownID,
                        expectedLatestEventID: createEventID,
                        today: mismatchedToday,
                        timestamp: timestamp
                    )
                )
            },
            {
                try await writer.completeCountdown(
                    CompleteCountdownCommand(
                        operationID: UUID(),
                        eventID: UUID(),
                        countdownID: countdownID,
                        expectedLatestEventID: createEventID,
                        today: mismatchedToday,
                        timestamp: timestamp
                    )
                )
            }
        ] {
            do {
                _ = try await transition()
                XCTFail("Mismatched civil-day evidence must be rejected")
            } catch {
                XCTAssertEqual(
                    error as? CountdownWriteFailure,
                    .invalidTransition
                )
            }
        }

        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<CountdownLifecycleEventRecord>()
            ),
            eventCount
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<OperationReceiptRecord>()),
            receiptCount
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<RecordRevision>()),
            revisionCount
        )
    }

    func testCreateRejectsSecondActiveAndStaleMutationWritesNothing() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: try XCTUnwrap(
                ISO8601DateFormatter().date(
                    from: "2026-04-01T12:00:00Z"
                )
            ),
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
            instant: try XCTUnwrap(
                ISO8601DateFormatter().date(
                    from: "2026-04-01T12:00:00Z"
                )
            ),
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

    func testContentOnlyEditFromAnotherTimeZonePreservesLegacyTargetInstant()
        async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let createTimestamp = try HistoricalTimestamp.captured(
            instant: try XCTUnwrap(
                ISO8601DateFormatter().date(
                    from: "2026-03-20T18:00:00Z"
                )
            ),
            timeZoneIdentifier: "America/Chicago",
            provenance: .userEntered
        )
        let target = try CivilDateFact(year: 2026, month: 4, day: 1)
        let countdownID = UUID()
        let createEventID = UUID()
        _ = try await writer.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: createEventID,
                countdownID: countdownID,
                title: "原名称",
                gentleTitle: nil,
                targetDate: target,
                showInToday: true,
                reminder: .disabled,
                timestamp: createTimestamp
            )
        )
        let context = ModelContext(container)
        let originalLegacyTarget = try XCTUnwrap(
            context.fetch(FetchDescriptor<CountdownRecord>()).first
        ).targetDate
        let updateTimestamp = try HistoricalTimestamp.captured(
            instant: try XCTUnwrap(
                ISO8601DateFormatter().date(
                    from: "2026-03-21T01:00:00Z"
                )
            ),
            timeZoneIdentifier: "Asia/Tokyo",
            provenance: .userEntered
        )

        _ = try await writer.updateCountdown(
            UpdateCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: countdownID,
                expectedLatestEventID: createEventID,
                title: "只改名称",
                gentleTitle: nil,
                targetDate: target,
                showInToday: true,
                reminder: .disabled,
                timestamp: updateTimestamp
            )
        )

        let updatedLegacy = try XCTUnwrap(
            context.fetch(FetchDescriptor<CountdownRecord>()).first
        )
        XCTAssertEqual(updatedLegacy.targetDate, originalLegacyTarget)
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
        let deletedReminder = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<CountdownReminderRuleRecord>()
            ).first
        )
        XCTAssertFalse(deletedReminder.isEnabled)
        XCTAssertEqual(deletedReminder.leadDays, 0)
        XCTAssertEqual(deletedReminder.localHour, 9)
        XCTAssertEqual(deletedReminder.localMinute, 0)
        XCTAssertEqual(deletedReminder.contentVersion, "neutralV1")
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

    func testRelationshipValidatorRejectsRedigestedReplacementLinkTampering()
        async throws
    {
        let fixture = try await makeReplacementFixture()
        let context = ModelContext(fixture.container)
        let deleteEventID = fixture.deleteEventID
        let replaced = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<CountdownLifecycleEventRecord>(
                    predicate: #Predicate {
                        $0.id == deleteEventID
                    }
                )
            ).first
        )
        replaced.replacementCountdownID = UUID()
        try rewriteRevisionDigest(
            recordType: "CountdownLifecycleEventRecord",
            recordID: replaced.id,
            fields: CountdownDigestV1.event(replaced),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testRelationshipValidatorRejectsReplacementPayloadOnCreatedEvent()
        async throws
    {
        let fixture = try await makeReplacementFixture()
        let context = ModelContext(fixture.container)
        let newEventID = fixture.newEventID
        let created = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<CountdownLifecycleEventRecord>(
                    predicate: #Predicate {
                        $0.id == newEventID
                    }
                )
            ).first
        )
        created.replacementCountdownID = fixture.oldCountdownID
        try rewriteRevisionDigest(
            recordType: "CountdownLifecycleEventRecord",
            recordID: created.id,
            fields: CountdownDigestV1.event(created),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testRelationshipValidatorRejectsArchivedAtOnRedigestedDeletedState()
        async throws
    {
        let fixture = try await makeReplacementFixture()
        let context = ModelContext(fixture.container)
        let oldCountdownID = fixture.oldCountdownID
        let deleted = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<CountdownStateRecord>(
                    predicate: #Predicate {
                        $0.id == oldCountdownID
                    }
                )
            ).first
        )
        deleted.archivedAt = fixture.timestamp.instant
        try rewriteRevisionDigest(
            recordType: "CountdownStateRecord",
            recordID: deleted.id,
            fields: CountdownDigestV1.state(deleted),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
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

    func testCommandAuditRejectsSelfConsistentTitleAndReminderTampering()
        async throws
    {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_774_521_600),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let countdownID = UUID()
        let eventID = UUID()
        _ = try await writer.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: eventID,
                countdownID: countdownID,
                title: "审计锚点",
                gentleTitle: "私人日期",
                targetDate: try CivilDateFact(
                    year: 2026,
                    month: 12,
                    day: 1
                ),
                showInToday: true,
                reminder: CountdownReminderInput(
                    isEnabled: true,
                    leadDays: 2,
                    localHour: 9,
                    localMinute: 30
                ),
                timestamp: timestamp
            )
        )

        let context = ModelContext(container)
        let state = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CountdownStateRecord>()).first
        )
        let legacy = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CountdownRecord>()).first
        )
        let reminder = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<CountdownReminderRuleRecord>()
            ).first
        )
        let audit = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<CountdownCommandAuditRecord>(
                    predicate: #Predicate { $0.eventID == eventID }
                )
            ).first
        )
        state.title = "被共同改写的标题"
        legacy.title = state.title
        reminder.leadDays = 12
        audit.postFactsDigest = try CountdownIntegrityDigest.facts(
            state: state,
            reminder: reminder,
            legacy: legacy
        )
        try audit.seal()
        try rewriteRevisionDigest(
            recordType: "CountdownStateRecord",
            recordID: state.id,
            fields: CountdownDigestV1.state(state),
            in: context
        )
        try rewriteRevisionDigest(
            recordType: "CountdownRecord",
            recordID: legacy.id,
            fields: FactDigestV1.countdown(legacy),
            in: context
        )
        try rewriteRevisionDigest(
            recordType: "CountdownReminderRuleRecord",
            recordID: reminder.id,
            fields: CountdownDigestV1.reminder(reminder),
            in: context
        )
        try rewriteRevisionDigest(
            recordType: "CountdownCommandAuditRecord",
            recordID: audit.eventID,
            fields: CountdownIntegrityDigest.revisionFields(audit),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testCommandAuditRejectsRedigestedEventTimestampTampering()
        async throws
    {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_774_521_600),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let eventID = UUID()
        _ = try await writer.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: eventID,
                countdownID: UUID(),
                title: "时间承诺",
                gentleTitle: nil,
                targetDate: try CivilDateFact(
                    year: 2026,
                    month: 12,
                    day: 1
                ),
                showInToday: true,
                reminder: .disabled,
                timestamp: timestamp
            )
        )

        let context = ModelContext(container)
        let event = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<CountdownLifecycleEventRecord>(
                    predicate: #Predicate { $0.id == eventID }
                )
            ).first
        )
        let state = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CountdownStateRecord>()).first
        )
        let legacy = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CountdownRecord>()).first
        )
        let reminder = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<CountdownReminderRuleRecord>()
            ).first
        )
        let audit = try XCTUnwrap(
            try context.fetch(
                FetchDescriptor<CountdownCommandAuditRecord>(
                    predicate: #Predicate { $0.eventID == eventID }
                )
            ).first
        )
        let forged = try HistoricalTimestamp.captured(
            instant: timestamp.instant.addingTimeInterval(3_600),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        event.occurredAt = forged.instant
        event.localYear = forged.localDate.year
        event.localMonth = forged.localDate.month
        event.localDay = forged.localDate.day
        event.localHour = forged.localTime.hour
        event.localMinute = forged.localTime.minute
        event.localSecond = forged.localTime.second
        event.localNanosecond = forged.localTime.nanosecond
        event.utcOffsetSeconds = forged.utcOffsetSeconds
        state.createdAt = forged.instant
        state.updatedAt = forged.instant
        legacy.createdAt = forged.instant
        reminder.updatedAt = forged.instant
        audit.eventSemanticDigest =
            try CountdownIntegrityDigest.eventSemantic(event)
        audit.postFactsDigest = try CountdownIntegrityDigest.facts(
            state: state,
            reminder: reminder,
            legacy: legacy
        )
        try audit.seal()
        try rewriteRevisionDigest(
            recordType: "CountdownLifecycleEventRecord",
            recordID: event.id,
            fields: CountdownDigestV1.event(event),
            in: context
        )
        try rewriteRevisionDigest(
            recordType: "CountdownStateRecord",
            recordID: state.id,
            fields: CountdownDigestV1.state(state),
            in: context
        )
        try rewriteRevisionDigest(
            recordType: "CountdownRecord",
            recordID: legacy.id,
            fields: FactDigestV1.countdown(legacy),
            in: context
        )
        try rewriteRevisionDigest(
            recordType: "CountdownReminderRuleRecord",
            recordID: reminder.id,
            fields: CountdownDigestV1.reminder(reminder),
            in: context
        )
        try rewriteRevisionDigest(
            recordType: "CountdownCommandAuditRecord",
            recordID: audit.eventID,
            fields: CountdownIntegrityDigest.revisionFields(audit),
            in: context
        )
        try context.save()

        XCTAssertThrowsError(
            try CountdownLifecycleRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        ) { error in
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    private func makeReplacementFixture() async throws -> (
        container: ModelContainer,
        oldCountdownID: UUID,
        newCountdownID: UUID,
        deleteEventID: UUID,
        newEventID: UUID,
        timestamp: HistoricalTimestamp
    ) {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_774_521_600),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let oldCountdownID = UUID()
        let oldEventID = UUID()
        _ = try await writer.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: oldEventID,
                countdownID: oldCountdownID,
                title: "旧目标",
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
        let newCountdownID = UUID()
        let deleteEventID = UUID()
        let newEventID = UUID()
        _ = try await writer.replaceCountdown(
            ReplaceCountdownCommand(
                operationID: UUID(),
                deleteEventID: deleteEventID,
                newEventID: newEventID,
                countdownID: oldCountdownID,
                expectedLatestEventID: oldEventID,
                newCountdownID: newCountdownID,
                title: "新目标",
                gentleTitle: "私人日期",
                targetDate: try CivilDateFact(
                    year: 2026,
                    month: 8,
                    day: 1
                ),
                showInToday: false,
                reminder: .disabled,
                timestamp: timestamp
            )
        )
        return (
            container,
            oldCountdownID,
            newCountdownID,
            deleteEventID,
            newEventID,
            timestamp
        )
    }

    private func makeContinuedCountdownFixture() async throws -> (
        container: ModelContainer,
        writer: AppWriteActor,
        countdownID: UUID,
        latestEventID: UUID,
        timestamp: HistoricalTimestamp
    ) {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: try XCTUnwrap(
                ISO8601DateFormatter().date(
                    from: "2026-04-01T12:00:00Z"
                )
            ),
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
                title: "继续计日",
                gentleTitle: nil,
                targetDate: timestamp.localDate,
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
                today: timestamp.localDate,
                timestamp: timestamp
            )
        )
        return (
            container,
            writer,
            countdownID,
            continueEventID,
            timestamp
        )
    }

    private func rewriteRevisionDigest(
        recordType: String,
        recordID: UUID,
        fields: [RecordDigestV1.Field],
        in context: ModelContext
    ) throws {
        let recordKey =
            recordType + ":" + recordID.uuidString.lowercased()
        var descriptor = FetchDescriptor<RecordRevision>(
            predicate: #Predicate {
                $0.recordKey == recordKey
            }
        )
        descriptor.fetchLimit = 2
        let revisions = try context.fetch(descriptor)
        XCTAssertEqual(revisions.count, 1)
        let revision = try XCTUnwrap(revisions.first)
        revision.digestVersion = RecordDigestV1.version
        revision.digestHex = try RecordDigestV1.sha256Hex(
            recordType: recordType,
            recordID: recordID,
            fields: fields
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
