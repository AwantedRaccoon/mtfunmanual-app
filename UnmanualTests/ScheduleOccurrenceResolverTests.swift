import XCTest
@testable import Unmanual

final class ScheduleOccurrenceResolverTests: XCTestCase {
    private let ruleID = UUID(uuidString: "B3C812AF-3A23-4A74-91CE-BD4225719668")!

    func testOccurrenceIdentityParserRejectsNoncanonicalOrMalformedKeys() throws {
        let valid = "occ:v1:b3c812af-3a23-4a74-91ce-bd4225719668:2:20260722T0830"
        let identity = try XCTUnwrap(ScheduleOccurrenceResolver.identity(for: valid))

        XCTAssertEqual(identity.ruleID, ruleID)
        XCTAssertEqual(identity.revision, 2)
        XCTAssertEqual(identity.date, try civil(2026, 7, 22))
        XCTAssertEqual(identity.time, try HistoricalLocalTime(hour: 8, minute: 30, second: 0))
        XCTAssertNil(ScheduleOccurrenceResolver.identity(for: valid + "junk"))
        XCTAssertNil(ScheduleOccurrenceResolver.identity(for: valid.replacingOccurrences(of: ":2:", with: ":02:")))
        XCTAssertNil(ScheduleOccurrenceResolver.identity(for: valid.replacingOccurrences(of: "b3c", with: "B3C")))
        XCTAssertNil(ScheduleOccurrenceResolver.identity(for: valid.replacingOccurrences(of: "20260722", with: "20260230")))
        XCTAssertNil(ScheduleOccurrenceResolver.identity(for: valid.replacingOccurrences(of: "0830", with: "2460")))
    }

    func testStoredOccurrenceValidationRejectsWrongCadenceAndFixedInstantDrift() throws {
        let rule = ScheduleRuleSpec(
            id: ruleID,
            regimenVersionID: UUID(),
            regimenItemID: UUID(),
            displayName: "周一计划",
            kind: .weekly,
            anchorDate: try civil(2026, 7, 20),
            endDate: nil,
            localTimes: "08:30",
            weekdays: "1",
            intervalDays: nil,
            timeZoneBehavior: .fixedZone,
            fixedTimeZoneIdentifier: "UTC",
            revision: 2
        )
        let validKey = "occ:v1:b3c812af-3a23-4a74-91ce-bd4225719668:2:20260720T0830"
        let validInstant = try instant("2026-07-20T08:30:00Z")

        XCTAssertTrue(
            ScheduleOccurrenceResolver.validatesStoredOccurrence(
                key: validKey,
                plannedInstant: validInstant,
                rule: rule
            )
        )
        XCTAssertFalse(
            ScheduleOccurrenceResolver.validatesStoredOccurrence(
                key: validKey.replacingOccurrences(of: "20260720", with: "20260721"),
                plannedInstant: try instant("2026-07-21T08:30:00Z"),
                rule: rule
            )
        )
        XCTAssertFalse(
            ScheduleOccurrenceResolver.validatesStoredOccurrence(
                key: validKey,
                plannedInstant: validInstant.addingTimeInterval(60),
                rule: rule
            )
        )
    }

    func testDailyTimesAreNormalizedSortedAndBoundedByHalfOpenIntervals() throws {
        let rule = ScheduleRuleSpec(
            id: ruleID,
            regimenVersionID: UUID(),
            regimenItemID: UUID(),
            displayName: "测试项目",
            kind: .dailyTimes,
            anchorDate: try civil(2026, 7, 21),
            endDate: try civil(2026, 7, 23),
            localTimes: "20:30, 08:00",
            weekdays: "",
            intervalDays: nil,
            timeZoneBehavior: .fixedZone,
            fixedTimeZoneIdentifier: "America/Chicago",
            revision: 2
        )

        let result = try ScheduleOccurrenceResolver.occurrences(
            rules: [rule],
            interval: DateInterval(
                start: try instant("2026-07-21T00:00:00-05:00"),
                end: try instant("2026-07-24T00:00:00-05:00")
            ),
            displayTimeZoneIdentifier: "America/Chicago"
        )

        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(result.occurrences.map(\.key), [
            "occ:v1:b3c812af-3a23-4a74-91ce-bd4225719668:2:20260721T0800",
            "occ:v1:b3c812af-3a23-4a74-91ce-bd4225719668:2:20260721T2030",
            "occ:v1:b3c812af-3a23-4a74-91ce-bd4225719668:2:20260722T0800",
            "occ:v1:b3c812af-3a23-4a74-91ce-bd4225719668:2:20260722T2030"
        ])
    }

    func testOccurrenceExactlyAtIntervalEndIsExcluded() throws {
        let rule = ScheduleRuleSpec(
            id: ruleID,
            regimenVersionID: UUID(),
            regimenItemID: UUID(),
            displayName: "结束边界",
            kind: .oneOff,
            anchorDate: try civil(2026, 7, 22),
            endDate: nil,
            localTimes: "08:00",
            weekdays: "",
            intervalDays: nil,
            timeZoneBehavior: .fixedZone,
            fixedTimeZoneIdentifier: "UTC",
            revision: 1
        )

        let result = try ScheduleOccurrenceResolver.occurrences(
            rules: [rule],
            interval: DateInterval(
                start: try instant("2026-07-22T07:00:00Z"),
                end: try instant("2026-07-22T08:00:00Z")
            ),
            displayTimeZoneIdentifier: "UTC"
        )

        XCTAssertTrue(result.occurrences.isEmpty)
    }

    func testTotalOccurrenceLimitFailsClosedWithoutPartialSchedule() throws {
        let times = (0..<ScheduleOccurrenceResolver.maximumTimesPerRule)
            .map { String(format: "%02d:%02d", $0 / 60, $0 % 60) }
            .joined(separator: ",")
        let ruleCount = ScheduleOccurrenceResolver.maximumOccurrencesPerResolution
            / ScheduleOccurrenceResolver.maximumTimesPerRule + 1
        let rules = try (0..<ruleCount).map { index in
            ScheduleRuleSpec(
                id: UUID(),
                regimenVersionID: UUID(),
                regimenItemID: UUID(),
                displayName: "上限 \(index)",
                kind: .dailyTimes,
                anchorDate: try civil(2026, 7, 22),
                endDate: nil,
                localTimes: times,
                weekdays: "",
                intervalDays: nil,
                timeZoneBehavior: .fixedZone,
                fixedTimeZoneIdentifier: "UTC",
                revision: 1
            )
        }

        let result = try ScheduleOccurrenceResolver.occurrences(
            rules: rules,
            interval: DateInterval(
                start: try instant("2026-07-22T00:00:00Z"),
                end: try instant("2026-07-23T00:00:00Z")
            ),
            displayTimeZoneIdentifier: "UTC"
        )

        XCTAssertTrue(result.occurrences.isEmpty)
        XCTAssertEqual(result.issues, [.capacityExceeded])
    }

    func testActiveRegimenIntervalsBoundHistoricalRulesBeforeCapacityAndIssueGeneration() throws {
        let times = (0..<ScheduleOccurrenceResolver.maximumTimesPerRule)
            .map { String(format: "%02d:00", $0) }
            .joined(separator: ",")
        let rules = try (0..<16).map { index in
            let activeDay = (index % 7) + 1
            return ScheduleRuleSpec(
                id: UUID(),
                regimenVersionID: UUID(),
                regimenItemID: UUID(),
                displayName: "历史方案 \(index)",
                kind: .dailyTimes,
                anchorDate: try civil(2026, 3, 1),
                activeStartDate: try civil(2026, 3, activeDay),
                endDate: try civil(2026, 3, activeDay + 1),
                localTimes: times,
                weekdays: "",
                intervalDays: nil,
                timeZoneBehavior: .fixedZone,
                fixedTimeZoneIdentifier: "America/Chicago",
                revision: 1
            )
        }

        let result = try ScheduleOccurrenceResolver.occurrences(
            rules: rules,
            interval: DateInterval(
                start: try instant("2026-03-01T00:00:00Z"),
                end: try instant("2026-03-18T00:00:00Z")
            ),
            displayTimeZoneIdentifier: "UTC"
        )

        XCTAssertLessThan(result.occurrences.count, 300)
        XCTAssertFalse(result.issues.contains(.capacityExceeded))
        XCTAssertFalse(result.issues.contains { issue in
            if case .nonexistentLocalTime = issue { return true }
            return false
        })
    }

    func testPerRuleTimeLimitFailsClosedWithoutLeakingOtherRuleOccurrences() throws {
        let tooManyTimes = (0...ScheduleOccurrenceResolver.maximumTimesPerRule)
            .map { String(format: "%02d:%02d", $0 / 60, $0 % 60) }
            .joined(separator: ",")
        let oversized = ScheduleRuleSpec(
            id: ruleID,
            regimenVersionID: UUID(),
            regimenItemID: UUID(),
            displayName: "损坏的超限规则",
            kind: .dailyTimes,
            anchorDate: try civil(2026, 7, 22),
            endDate: nil,
            localTimes: tooManyTimes,
            weekdays: "",
            intervalDays: nil,
            timeZoneBehavior: .fixedZone,
            fixedTimeZoneIdentifier: "UTC",
            revision: 1
        )
        let valid = ScheduleRuleSpec(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            regimenVersionID: UUID(),
            regimenItemID: UUID(),
            displayName: "合法规则",
            kind: .dailyTimes,
            anchorDate: try civil(2026, 7, 22),
            endDate: nil,
            localTimes: "09:00",
            weekdays: "",
            intervalDays: nil,
            timeZoneBehavior: .fixedZone,
            fixedTimeZoneIdentifier: "UTC",
            revision: 1
        )

        let result = try ScheduleOccurrenceResolver.occurrences(
            rules: [oversized, valid],
            interval: DateInterval(
                start: try instant("2026-07-22T00:00:00Z"),
                end: try instant("2026-07-23T00:00:00Z")
            ),
            displayTimeZoneIdentifier: "UTC"
        )

        XCTAssertTrue(result.occurrences.isEmpty)
        XCTAssertEqual(result.issues, [.capacityExceeded])
    }

    func testWeeklyEveryNDaysAndOneOffUseFrozenCivilSemantics() throws {
        let versionID = UUID()
        let itemID = UUID()
        let rules = [
            ScheduleRuleSpec(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                regimenVersionID: versionID,
                regimenItemID: itemID,
                displayName: "周计划",
                kind: .weekly,
                anchorDate: try civil(2026, 7, 20),
                endDate: nil,
                localTimes: "09:00",
                weekdays: "1,3",
                intervalDays: nil,
                timeZoneBehavior: .fixedZone,
                fixedTimeZoneIdentifier: "UTC",
                revision: 1
            ),
            ScheduleRuleSpec(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                regimenVersionID: versionID,
                regimenItemID: itemID,
                displayName: "隔日计划",
                kind: .everyNDays,
                anchorDate: try civil(2026, 7, 20),
                endDate: nil,
                localTimes: "10:00",
                weekdays: "",
                intervalDays: 2,
                timeZoneBehavior: .fixedZone,
                fixedTimeZoneIdentifier: "UTC",
                revision: 1
            ),
            ScheduleRuleSpec(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                regimenVersionID: versionID,
                regimenItemID: itemID,
                displayName: "一次计划",
                kind: .oneOff,
                anchorDate: try civil(2026, 7, 21),
                endDate: nil,
                localTimes: "11:00",
                weekdays: "",
                intervalDays: nil,
                timeZoneBehavior: .fixedZone,
                fixedTimeZoneIdentifier: "UTC",
                revision: 1
            )
        ]

        let result = try ScheduleOccurrenceResolver.occurrences(
            rules: rules,
            interval: DateInterval(
                start: try instant("2026-07-20T00:00:00Z"),
                end: try instant("2026-07-24T00:00:00Z")
            ),
            displayTimeZoneIdentifier: "UTC"
        )

        XCTAssertEqual(result.occurrences.map(\.displayName), [
            "周计划", "隔日计划", "一次计划", "周计划", "隔日计划"
        ])
        XCTAssertEqual(result.occurrences.map(\.localDate.iso8601), [
            "2026-07-20", "2026-07-20", "2026-07-21", "2026-07-22", "2026-07-22"
        ])
    }

    func testInvalidRuleFailsClosedAndDSTGapProducesReviewIssue() throws {
        let invalid = ScheduleRuleSpec(
            id: ruleID,
            regimenVersionID: UUID(),
            regimenItemID: UUID(),
            displayName: "测试项目",
            kind: .dailyTimes,
            anchorDate: try civil(2026, 3, 8),
            endDate: nil,
            localTimes: "02:30,02:30",
            weekdays: "",
            intervalDays: nil,
            timeZoneBehavior: .fixedZone,
            fixedTimeZoneIdentifier: "America/Chicago",
            revision: 1
        )

        let result = try ScheduleOccurrenceResolver.occurrences(
            rules: [invalid],
            interval: DateInterval(
                start: try instant("2026-03-08T00:00:00-06:00"),
                end: try instant("2026-03-09T00:00:00-05:00")
            ),
            displayTimeZoneIdentifier: "America/Chicago"
        )

        XCTAssertTrue(result.occurrences.isEmpty)
        XCTAssertEqual(result.issues, [.invalidRule(ruleID)])

        let gap = ScheduleRuleSpec(
            id: ruleID,
            regimenVersionID: UUID(),
            regimenItemID: UUID(),
            displayName: "测试项目",
            kind: .oneOff,
            anchorDate: try civil(2026, 3, 8),
            endDate: nil,
            localTimes: "02:30",
            weekdays: "",
            intervalDays: nil,
            timeZoneBehavior: .fixedZone,
            fixedTimeZoneIdentifier: "America/Chicago",
            revision: 1
        )
        let gapResult = try ScheduleOccurrenceResolver.occurrences(
            rules: [gap],
            interval: DateInterval(
                start: try instant("2026-03-08T00:00:00-06:00"),
                end: try instant("2026-03-09T00:00:00-05:00")
            ),
            displayTimeZoneIdentifier: "America/Chicago"
        )
        XCTAssertTrue(gapResult.occurrences.isEmpty)
        XCTAssertEqual(gapResult.issues, [.nonexistentLocalTime(ruleID, try civil(2026, 3, 8), "02:30")])
    }

    func testDSTOverlapAlwaysUsesEarlierInstant() throws {
        let rule = ScheduleRuleSpec(
            id: ruleID,
            regimenVersionID: UUID(),
            regimenItemID: UUID(),
            displayName: "测试项目",
            kind: .oneOff,
            anchorDate: try civil(2026, 11, 1),
            endDate: nil,
            localTimes: "01:30",
            weekdays: "",
            intervalDays: nil,
            timeZoneBehavior: .fixedZone,
            fixedTimeZoneIdentifier: "America/Chicago",
            revision: 1
        )

        let result = try ScheduleOccurrenceResolver.occurrences(
            rules: [rule],
            interval: DateInterval(
                start: try instant("2026-11-01T00:00:00-05:00"),
                end: try instant("2026-11-02T00:00:00-06:00")
            ),
            displayTimeZoneIdentifier: "America/Chicago"
        )

        XCTAssertEqual(result.occurrences.first?.instant, try instant("2026-11-01T01:30:00-05:00"))
        XCTAssertEqual(result.occurrences.first?.utcOffsetSeconds, -18_000)
    }

    func testLeapDayAndFloatingVersusFixedZonesUseCalendarFactsNotLocaleText() throws {
        let anchor = try civil(2028, 2, 28)
        let floating = ScheduleRuleSpec(
            id: UUID(),
            regimenVersionID: UUID(),
            regimenItemID: UUID(),
            displayName: "浮动时间",
            kind: .dailyTimes,
            anchorDate: anchor,
            endDate: nil,
            localTimes: "08:00",
            weekdays: "",
            intervalDays: nil,
            timeZoneBehavior: .floatingLocal,
            fixedTimeZoneIdentifier: nil,
            revision: 1
        )
        let fixed = ScheduleRuleSpec(
            id: UUID(),
            regimenVersionID: floating.regimenVersionID,
            regimenItemID: floating.regimenItemID,
            displayName: "固定时间",
            kind: .dailyTimes,
            anchorDate: anchor,
            endDate: nil,
            localTimes: "08:00",
            weekdays: "",
            intervalDays: nil,
            timeZoneBehavior: .fixedZone,
            fixedTimeZoneIdentifier: "America/Chicago",
            revision: 1
        )

        let result = try ScheduleOccurrenceResolver.occurrences(
            rules: [floating, fixed],
            interval: DateInterval(
                start: try instant("2028-02-28T00:00:00Z"),
                end: try instant("2028-03-01T23:59:59Z")
            ),
            displayTimeZoneIdentifier: "Asia/Tokyo"
        )

        XCTAssertTrue(result.occurrences.contains { $0.localDate.iso8601 == "2028-02-29" })
        let leapOccurrences = result.occurrences.filter {
            $0.localDate.iso8601 == "2028-02-29"
        }
        XCTAssertEqual(leapOccurrences.count, 2)
        XCTAssertNotEqual(leapOccurrences[0].instant, leapOccurrences[1].instant)
        XCTAssertEqual(Set(leapOccurrences.map(\.localTime.hour)), [8])
    }

    private func civil(_ year: Int, _ month: Int, _ day: Int) throws -> CivilDateFact {
        try CivilDateFact(year: year, month: month, day: day)
    }

    private func instant(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: value))
    }
}
