import XCTest
@testable import Unmanual

final class CountdownLifecycleDomainTests: XCTestCase {
    func testReminderAuthorizationIsRequestedOnlyWhenEnablingIntent() {
        XCTAssertTrue(
            CountdownReminderAuthorizationPolicy.shouldRequest(
                previousIntentEnabled: nil,
                newIntentEnabled: true
            )
        )
        XCTAssertTrue(
            CountdownReminderAuthorizationPolicy.shouldRequest(
                previousIntentEnabled: false,
                newIntentEnabled: true
            )
        )
        XCTAssertFalse(
            CountdownReminderAuthorizationPolicy.shouldRequest(
                previousIntentEnabled: true,
                newIntentEnabled: true
            )
        )
        XCTAssertFalse(
            CountdownReminderAuthorizationPolicy.shouldRequest(
                previousIntentEnabled: true,
                newIntentEnabled: false
            )
        )
    }

    func testCivilDateProjectionKeepsTargetDayAtZeroAndCountsUpOnlyAfterChoice() throws {
        let target = try CivilDateFact(year: 2026, month: 7, day: 24)

        XCTAssertEqual(
            try CountdownDayProjection.resolve(
                target: target,
                today: target,
                overdueMode: .awaitingDecision
            ),
            .targetDay
        )
        XCTAssertEqual(
            try CountdownDayProjection.resolve(
                target: target,
                today: CivilDateFact(year: 2026, month: 7, day: 25),
                overdueMode: .awaitingDecision
            ),
            .overdueAwaitingDecision(days: 1)
        )
        XCTAssertEqual(
            try CountdownDayProjection.resolve(
                target: target,
                today: CivilDateFact(year: 2026, month: 7, day: 25),
                overdueMode: .countingUp
            ),
            .countingUp(days: 1)
        )
    }

    func testCivilDateProjectionHandlesLeapAndYearBoundariesWithoutTimeZone() throws {
        XCTAssertEqual(
            try CountdownDayProjection.resolve(
                target: CivilDateFact(year: 2028, month: 2, day: 29),
                today: CivilDateFact(year: 2028, month: 2, day: 28),
                overdueMode: .awaitingDecision
            ),
            .remaining(days: 1)
        )
        XCTAssertEqual(
            try CountdownDayProjection.resolve(
                target: CivilDateFact(year: 2026, month: 12, day: 31),
                today: CivilDateFact(year: 2027, month: 1, day: 1),
                overdueMode: .countingUp
            ),
            .countingUp(days: 1)
        )
    }

    func testLifecycleRejectsCompletionBeforeTargetAndAllowsArchiveAnytime() throws {
        let today = try CivilDateFact(year: 2026, month: 7, day: 24)
        let future = try CivilDateFact(year: 2026, month: 7, day: 25)

        XCTAssertFalse(
            CountdownLifecycleRules.canComplete(
                lifecycle: .active,
                target: future,
                today: today
            )
        )
        XCTAssertTrue(
            CountdownLifecycleRules.canArchive(lifecycle: .active)
        )
        XCTAssertFalse(
            CountdownLifecycleRules.canArchive(lifecycle: .completed)
        )
    }
}
