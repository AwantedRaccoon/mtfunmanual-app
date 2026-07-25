import SwiftData
import XCTest
@testable import Unmanual

final class CountdownLifecycleReadTests: XCTestCase {
    func testDetailTerminalTextStopsLoadingAfterReadFailure() {
        XCTAssertEqual(
            CountdownDetailTerminalText.make(
                timestamp: nil,
                loadState: .loading
            ),
            "读取中"
        )
        XCTAssertEqual(
            CountdownDetailTerminalText.make(
                timestamp: nil,
                loadState: .failed
            ),
            "未能核对"
        )
        XCTAssertEqual(
            CountdownDetailTerminalText.make(
                timestamp: nil,
                loadState: .loaded
            ),
            "未记录"
        )
    }

    func testDetailTerminalTimestampUsesArchivedPredecessorWhenReviewSharesInstant()
        async throws
    {
        let container = try AppModelContainerFactory
            .makeInMemoryCountdownLifecycleContainer()
        let context = ModelContext(container)
        let archivedAt = try XCTUnwrap(
            ISO8601DateFormatter().date(
                from: "2026-04-01T01:30:00Z"
            )
        )
        let countdownID = UUID()
        context.insert(
            CountdownRecord(
                id: countdownID,
                title: "同一时刻的旧归档",
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
                assumedTimeZoneIdentifier: "America/Chicago"
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
        let reviewTimestamp = try HistoricalTimestamp.captured(
            instant: archivedAt,
            timeZoneIdentifier: "Asia/Tokyo",
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
                timestamp: reviewTimestamp
            )
        )

        let loadedDetail = try await reader.countdownDetail(id: countdownID)
        let detail = try XCTUnwrap(loadedDetail)
        XCTAssertEqual(
            detail.events.map(\.kind),
            [.migratedSnapshot, .reviewResolved]
        )
        XCTAssertEqual(
            detail.events.map(\.timestamp.instant),
            [archivedAt, archivedAt]
        )
        XCTAssertEqual(
            detail.events.map(\.timestamp.timeZoneIdentifier),
            ["America/Chicago", "Asia/Tokyo"]
        )
        let terminal = try XCTUnwrap(
            CountdownDetailPresentation.terminalTimestamp(in: detail)
        )
        XCTAssertEqual(terminal, detail.events[0].timestamp)
        XCTAssertNotEqual(
            terminal.recordedCivilMinuteLabel,
            detail.events[1].timestamp.recordedCivilMinuteLabel
        )
    }

    func testLedgerStatusUsesAtLeastForPagedReviewAndHistory() {
        XCTAssertEqual(
            CountdownLedgerStatusText.make(
                hasError: false,
                isLoading: false,
                reviewCount: 20,
                reviewHasMore: true,
                hasCurrent: false,
                historyCount: 0,
                historyHasMore: false
            ),
            "至少 20 项待核对"
        )
        XCTAssertEqual(
            CountdownLedgerStatusText.make(
                hasError: false,
                isLoading: false,
                reviewCount: 0,
                reviewHasMore: false,
                hasCurrent: false,
                historyCount: 20,
                historyHasMore: true
            ),
            "至少 20 项历史"
        )
    }

    func testEditorSnapshotCarriesGentleModeWithoutAnActiveCountdown()
        async throws
    {
        let container = try preparedContainer()
        let storage = AppWriteActor(modelContainer: container)
        try await storage.setGentleMode(
            SetGentleModeCommand(
                isEnabled: true,
                committedAt: Date(
                    timeIntervalSince1970: 1_774_521_600
                )
            )
        )

        let snapshot = try await AppReadActor(
            modelContainer: container
        ).countdownEditorSnapshot(
            displayTimeZoneIdentifier: "UTC"
        )

        XCTAssertTrue(snapshot.gentleModeEnabled)
        XCTAssertNil(snapshot.current)
    }

    func testTodayProjectionHonorsVisibilityAndGentleModeWithoutLeakingTitle() async throws {
        let container = try preparedContainer()
        let storage = AppWriteActor(modelContainer: container)
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
        _ = try await storage.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: createEventID,
                countdownID: countdownID,
                title: "敏感原名",
                gentleTitle: nil,
                targetDate: CivilDateFact(
                    year: 2026,
                    month: 4,
                    day: 3
                ),
                showInToday: false,
                reminder: .disabled,
                timestamp: timestamp
            )
        )
        let reader = AppReadActor(modelContainer: container)
        let hidden = try await reader.countdownTodaySnapshot(
            today: CivilDateFact(year: 2026, month: 4, day: 1),
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertNil(hidden)

        _ = try await storage.updateCountdown(
            UpdateCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: countdownID,
                expectedLatestEventID: createEventID,
                title: "敏感原名",
                gentleTitle: nil,
                targetDate: CivilDateFact(
                    year: 2026,
                    month: 4,
                    day: 3
                ),
                showInToday: true,
                reminder: .disabled,
                timestamp: timestamp
            )
        )
        try await storage.setGentleMode(
            SetGentleModeCommand(
                isEnabled: true,
                committedAt: timestamp.instant.addingTimeInterval(1)
            )
        )
        let gentleMode = try await reader.gentleModeSnapshot()
        XCTAssertEqual(
            gentleMode,
            GentleModeSnapshot(isEnabled: true)
        )

        let visible = try await reader.countdownTodaySnapshot(
            today: CivilDateFact(year: 2026, month: 4, day: 1),
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertEqual(visible?.displayTitle, "私人日期")
        XCTAssertNotEqual(visible?.displayTitle, "敏感原名")
        XCTAssertEqual(visible?.dayState, .remaining(days: 2))
    }

    func testCompletedCountdownLeavesTodayAndAppearsInHistoryWithEventChain() async throws {
        let container = try preparedContainer()
        let storage = AppWriteActor(modelContainer: container)
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
        _ = try await storage.createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: createEventID,
                countdownID: countdownID,
                title: "里程碑",
                gentleTitle: nil,
                targetDate: CivilDateFact(
                    year: 2026,
                    month: 4,
                    day: 1
                ),
                showInToday: true,
                reminder: .disabled,
                timestamp: timestamp
            )
        )
        let completeEventID = UUID()
        _ = try await storage.completeCountdown(
            CompleteCountdownCommand(
                operationID: UUID(),
                eventID: completeEventID,
                countdownID: countdownID,
                expectedLatestEventID: createEventID,
                today: CivilDateFact(year: 2026, month: 4, day: 1),
                timestamp: timestamp
            )
        )
        let reader = AppReadActor(modelContainer: container)

        let hidden = try await reader.countdownTodaySnapshot(
            today: CivilDateFact(year: 2026, month: 4, day: 1),
            displayTimeZoneIdentifier: "UTC"
        )
        XCTAssertNil(hidden)
        let history = try await reader.countdownHistoryPage(
            after: nil,
            limit: 20
        )
        XCTAssertEqual(history.items.map(\.id), [countdownID])
        XCTAssertEqual(history.items.first?.lifecycle, .completed)
        let detail = try await reader.countdownDetail(id: countdownID)
        XCTAssertEqual(detail?.events.map(\.kind), [.created, .completed])
        XCTAssertEqual(detail?.current.latestEventID, completeEventID)
        let completedDetail = try XCTUnwrap(detail)
        XCTAssertEqual(
            CountdownDetailPresentation.terminalTimestamp(
                in: completedDetail
            ),
            completedDetail.events.last?.timestamp
        )
        XCTAssertNil(
            CountdownDetailPresentation.verifiedDetail(
                detail,
                loadState: .loading
            )
        )
        XCTAssertNil(
            CountdownDetailPresentation.verifiedDetail(
                detail,
                loadState: .failed
            )
        )
        XCTAssertEqual(
            CountdownDetailPresentation.verifiedDetail(
                detail,
                loadState: .loaded
            )?.current.title,
            "里程碑"
        )
    }

    func testCurrentSnapshotExposesPersistedCountdownReminderCoverage() async throws {
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
                title: "需要提醒",
                gentleTitle: nil,
                targetDate: CivilDateFact(year: 2026, month: 4, day: 3),
                showInToday: true,
                reminder: CountdownReminderInput(
                    isEnabled: true,
                    leadDays: 0,
                    localHour: 9,
                    localMinute: 0
                ),
                timestamp: timestamp
            )
        )
        let context = ModelContext(container)
        let coverage = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<CountdownNotificationCoverageRecord>()
            ).first
        )
        coverage.countdownID = countdownID
        coverage.statusRawValue =
            NotificationCoverageStatus.blockedByPermission.rawValue
        coverage.scheduledFireAt = nil
        coverage.desiredCount = 0
        coverage.confirmedPendingCount = 0
        coverage.lastErrorCode = nil
        coverage.observedAt = timestamp.instant
        try context.save()

        let snapshot = try await AppReadActor(
            modelContainer: container
        ).countdownCurrentSnapshot()

        XCTAssertEqual(snapshot?.coverage.status, .blockedByPermission)
        XCTAssertEqual(snapshot?.coverage.countdownID, countdownID)
        XCTAssertNil(snapshot?.coverage.scheduledFireAt)
    }

    func testCountdownReadRejectsCoverageThatClaimsAnUnconfirmedSchedule() async throws {
        let container = try preparedContainer()
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_775_203_200),
            timeZoneIdentifier: "UTC",
            provenance: .userEntered
        )
        let countdownID = UUID()
        _ = try await AppWriteActor(
            modelContainer: container
        ).createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                countdownID: countdownID,
                title: "需要提醒",
                gentleTitle: nil,
                targetDate: CivilDateFact(year: 2026, month: 4, day: 3),
                showInToday: true,
                reminder: .disabled,
                timestamp: timestamp
            )
        )
        let context = ModelContext(container)
        let coverage = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<CountdownNotificationCoverageRecord>()
            ).first
        )
        coverage.countdownID = countdownID
        coverage.statusRawValue =
            NotificationCoverageStatus.scheduledForWindow.rawValue
        coverage.scheduledFireAt = timestamp.instant.addingTimeInterval(3_600)
        coverage.desiredCount = 1
        coverage.confirmedPendingCount = 0
        coverage.lastErrorCode = nil
        coverage.observedAt = timestamp.instant
        try context.save()

        do {
            _ = try await AppReadActor(
                modelContainer: container
            ).countdownCurrentSnapshot()
            XCTFail("Unconfirmed scheduled coverage must fail closed")
        } catch {
            XCTAssertEqual(error as? AppDataFailure, .corruptionSuspected)
        }
    }

    func testHistoryPaginationDoesNotLoadOrCapTheEntireLedger() async throws {
        let container = try preparedContainer()
        let context = ModelContext(container)
        for index in 0..<1_030 {
            let countdownID = UUID()
            let eventID = UUID()
            let archivedAt = Date(
                timeIntervalSince1970: 1_700_000_000 + Double(index)
            )
            context.insert(
                CountdownStateRecord(
                    id: countdownID,
                    title: "历史 \(index)",
                    targetDate: try CivilDateFact(
                        year: 2026,
                        month: 1,
                        day: (index % 28) + 1
                    ),
                    lifecycle: .archived,
                    latestEventID: eventID,
                    archivedAt: archivedAt,
                    terminalReminderWasEnabled: false,
                    terminalReminderLeadDays: 0,
                    terminalReminderLocalHour: 9,
                    terminalReminderLocalMinute: 0,
                    createdAt: archivedAt.addingTimeInterval(-1),
                    updatedAt: archivedAt
                )
            )
            context.insert(
                CountdownReminderRuleRecord(
                    countdownID: countdownID,
                    isEnabled: false,
                    lastOperationID: UUID(),
                    updatedAt: archivedAt
                )
            )
        }
        try context.save()
        let reader = AppReadActor(modelContainer: container)

        let first = try await reader.countdownHistoryPage(
            after: nil,
            limit: 12
        )
        let insertedAfterSnapshotID = UUID()
        let insertedEventID = UUID()
        let insertedAt = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(
            CountdownStateRecord(
                id: insertedAfterSnapshotID,
                title: "并发新增历史",
                targetDate: try CivilDateFact(
                    year: 2027,
                    month: 1,
                    day: 1
                ),
                lifecycle: .archived,
                latestEventID: insertedEventID,
                archivedAt: insertedAt,
                terminalReminderWasEnabled: false,
                terminalReminderLeadDays: 0,
                terminalReminderLocalHour: 9,
                terminalReminderLocalMinute: 0,
                createdAt: insertedAt.addingTimeInterval(-1),
                updatedAt: insertedAt
            )
        )
        context.insert(
            CountdownReminderRuleRecord(
                countdownID: insertedAfterSnapshotID,
                isEnabled: false,
                lastOperationID: UUID(),
                updatedAt: insertedAt
            )
        )
        try context.save()
        var allItems = first.items
        var cursor = first.nextCursor
        while let nextCursor = cursor {
            let page = try await reader.countdownHistoryPage(
                after: nextCursor,
                limit: 50
            )
            allItems.append(contentsOf: page.items)
            cursor = page.nextCursor
        }

        XCTAssertEqual(first.items.count, 12)
        XCTAssertNotNil(first.nextCursor)
        XCTAssertEqual(allItems.count, 1_030)
        XCTAssertEqual(Set(allItems.map(\.id)).count, 1_030)
        XCTAssertFalse(allItems.contains {
            $0.id == insertedAfterSnapshotID
        })
    }

    func testLedgerCursorRejectsWrongDomainAndNonFiniteDate()
        async throws
    {
        let reader = AppReadActor(
            modelContainer: try preparedContainer()
        )
        do {
            _ = try await reader.countdownHistoryPage(
                after: CountdownLedgerCursor(
                    kind: .review,
                    sortDate: Date(
                        timeIntervalSince1970: 1_700_000_000
                    ),
                    recordID: UUID()
                ),
                limit: 20
            )
            XCTFail("A review cursor cannot drive history")
        } catch {
            XCTAssertEqual(
                error as? AppDataFailure,
                .corruptionSuspected
            )
        }
        do {
            _ = try await reader.countdownReviewPage(
                after: CountdownLedgerCursor(
                    kind: .review,
                    sortDate: Date(
                        timeIntervalSince1970: .infinity
                    ),
                    recordID: UUID()
                ),
                limit: 20
            )
            XCTFail("A non-finite cursor must fail closed")
        } catch {
            XCTAssertEqual(
                error as? AppDataFailure,
                .corruptionSuspected
            )
        }
    }

    func testCoveragePresentationMakesPermissionAndSchedulingFailuresVisible() {
        let base = CountdownReminderCoverageSnapshot(
            countdownID: UUID(),
            status: .blockedByPermission,
            scheduledFireAt: nil,
            desiredCount: 0,
            confirmedPendingCount: 0,
            lastErrorCode: nil,
            observedAt: Date()
        )
        XCTAssertEqual(
            CountdownReminderCoveragePresentation.title(
                coverage: base,
                countdownRuntimeErrorCode: nil
            ),
            "系统通知已关闭，可在系统设置中修改"
        )
        let failed = CountdownReminderCoverageSnapshot(
            countdownID: base.countdownID,
            status: .schedulingFailed,
            scheduledFireAt: nil,
            desiredCount: 0,
            confirmedPendingCount: 0,
            lastErrorCode: "dst-gap",
            observedAt: base.observedAt
        )
        XCTAssertEqual(
            CountdownReminderCoveragePresentation.title(
                coverage: failed,
                countdownRuntimeErrorCode: nil
            ),
            "提醒尚未安排，请检查日期和当地时间后重试"
        )
    }

    func testReminderPlanningIgnoresMoreThanOneThousandTerminalCountdowns() async throws {
        let container = try preparedContainer()
        let context = ModelContext(container)
        for index in 0..<1_025 {
            let countdownID = UUID()
            let archivedAt = Date(
                timeIntervalSince1970: 1_700_000_000 + Double(index)
            )
            context.insert(
                CountdownStateRecord(
                    id: countdownID,
                    title: "历史 \(index)",
                    targetDate: try CivilDateFact(
                        year: 2025,
                        month: 1,
                        day: (index % 28) + 1
                    ),
                    lifecycle: .archived,
                    latestEventID: UUID(),
                    archivedAt: archivedAt,
                    terminalReminderWasEnabled: false,
                    terminalReminderLeadDays: 0,
                    terminalReminderLocalHour: 9,
                    terminalReminderLocalMinute: 0,
                    createdAt: archivedAt.addingTimeInterval(-1),
                    updatedAt: archivedAt
                )
            )
            context.insert(
                CountdownReminderRuleRecord(
                    countdownID: countdownID,
                    isEnabled: false,
                    lastOperationID: UUID(),
                    updatedAt: archivedAt
                )
            )
        }
        let activeID = UUID()
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-04-01T12:00:00Z")
        )
        context.insert(
            CountdownStateRecord(
                id: activeID,
                title: "仍需提醒",
                targetDate: try CivilDateFact(
                    year: 2026,
                    month: 4,
                    day: 3
                ),
                latestEventID: UUID(),
                createdAt: now,
                updatedAt: now
            )
        )
        context.insert(
            CountdownReminderRuleRecord(
                countdownID: activeID,
                isEnabled: true,
                localHour: 9,
                localMinute: 0,
                lastOperationID: UUID(),
                updatedAt: now
            )
        )
        try context.save()

        let planning = try await AppReadActor(
            modelContainer: container
        ).reminderPlanningSnapshot(
            now: now,
            displayTimeZoneIdentifier: "UTC"
        )

        XCTAssertEqual(planning.countdownID, activeID)
        XCTAssertTrue(planning.countdownHasEnabledIntent)
        XCTAssertEqual(planning.countdownCandidates.count, 1)
    }

    func testScheduledCountdownPresentationUsesOnlyCountdownDomainRuntimeError() {
        let fireAt = Date(timeIntervalSince1970: 1_775_212_400)
        let coverage = CountdownReminderCoverageSnapshot(
            countdownID: UUID(),
            status: .scheduledForWindow,
            scheduledFireAt: fireAt,
            desiredCount: 1,
            confirmedPendingCount: 1,
            lastErrorCode: nil,
            observedAt: fireAt.addingTimeInterval(-60)
        )

        XCTAssertEqual(
            CountdownReminderCoveragePresentation.title(
                coverage: coverage,
                countdownRuntimeErrorCode: nil
            ),
            "已安排在 \(fireAt.formatted(date: .abbreviated, time: .shortened))"
        )
        XCTAssertEqual(
            CountdownReminderCoveragePresentation.symbol(
                coverage: coverage,
                countdownRuntimeErrorCode: nil
            ),
            "bell.badge"
        )

        XCTAssertEqual(
            CountdownReminderCoveragePresentation.title(
                coverage: coverage,
                countdownRuntimeErrorCode:
                    "countdown-coverage-invalidation-failed"
            ),
            "提醒覆盖没有完成核对，请打开 App 重试"
        )
        XCTAssertEqual(
            CountdownReminderCoveragePresentation.symbol(
                coverage: coverage,
                countdownRuntimeErrorCode:
                    "countdown-coverage-invalidation-failed"
            ),
            "bell.slash"
        )
    }

    func testReviewPageReportsAllActiveReviewItemsBeyondTheLoadedPage() async throws {
        let container = try preparedContainer()
        let context = ModelContext(container)
        let createdAt = Date(timeIntervalSince1970: 1_775_212_400)
        for index in 0..<25 {
            let countdownID = UUID()
            context.insert(
                CountdownStateRecord(
                    id: countdownID,
                    title: "待核对 \(index)",
                    targetDate: try CivilDateFact(
                        year: 2026,
                        month: 4,
                        day: (index % 25) + 1
                    ),
                    latestEventID: UUID(),
                    requiresReview: true,
                    createdAt: createdAt.addingTimeInterval(Double(index)),
                    updatedAt: createdAt.addingTimeInterval(Double(index))
                )
            )
            context.insert(
                CountdownReminderRuleRecord(
                    countdownID: countdownID,
                    isEnabled: false,
                    lastOperationID: UUID(),
                    updatedAt: createdAt
                )
            )
        }
        try context.save()

        let page = try await AppReadActor(
            modelContainer: container
        ).countdownReviewPage(after: nil, limit: 20)

        XCTAssertEqual(page.items.count, 20)
        XCTAssertNotNil(page.nextCursor)
        XCTAssertEqual(page.activeReviewCount, 25)
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
}
