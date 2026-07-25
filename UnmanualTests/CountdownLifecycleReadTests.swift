import SwiftData
import XCTest
@testable import Unmanual

final class CountdownLifecycleReadTests: XCTestCase {
    func testTodayProjectionHonorsVisibilityAndGentleModeWithoutLeakingTitle() async throws {
        let container = try preparedContainer()
        let storage = AppWriteActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_774_521_600),
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
        let context = ModelContext(container)
        let preferences = try XCTUnwrap(
            context.fetch(FetchDescriptor<UserPreferencesRecord>()).first
        )
        preferences.gentleModeEnabled = true
        try context.save()

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
            instant: Date(timeIntervalSince1970: 1_774_521_600),
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
            offset: 0,
            limit: 20
        )
        XCTAssertEqual(history.items.map(\.id), [countdownID])
        XCTAssertEqual(history.items.first?.lifecycle, .completed)
        let detail = try await reader.countdownDetail(id: countdownID)
        XCTAssertEqual(detail?.events.map(\.kind), [.created, .completed])
        XCTAssertEqual(detail?.current.latestEventID, completeEventID)
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
            offset: 0,
            limit: 12
        )
        let deepPage = try await reader.countdownHistoryPage(
            offset: 1_020,
            limit: 12
        )

        XCTAssertEqual(first.items.count, 12)
        XCTAssertEqual(first.nextOffset, 12)
        XCTAssertEqual(deepPage.items.count, 10)
        XCTAssertNil(deepPage.nextOffset)
        XCTAssertEqual(
            Set((first.items + deepPage.items).map(\.id)).count,
            22
        )
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
        ).countdownReviewPage(offset: 0, limit: 20)

        XCTAssertEqual(page.items.count, 20)
        XCTAssertEqual(page.nextOffset, 20)
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
