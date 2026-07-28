import XCTest

@MainActor
final class TodayExecutionUITests: XCTestCase {
    func testVisibleLedgerPassesSystemInteractionAccessibilityAudit() throws {
        continueAfterFailure = false
        let app = launchTodayFixture()
        let taken = app.buttons["已使用"].firstMatch
        scrollToVisible(taken, in: app)
        XCTAssertTrue(taken.isHittable)

        try app.performAccessibilityAudit(for: [
            .elementDetection,
            .hitRegion,
            .sufficientElementDescription,
            .textClipped,
            .trait
        ])
    }

    func testRecordsExecutionAndOpensAppendOnlyCorrectionSheet() throws {
        continueAfterFailure = false
        let app = launchTodayFixture()
        let taken = app.buttons["已使用"].firstMatch
        scrollToVisible(taken, in: app)
        XCTAssertTrue(taken.isHittable)

        taken.tap()

        let correction = app.buttons["修改记录"].firstMatch
        XCTAssertTrue(correction.waitForExistence(timeout: 8))
        scrollToVisible(correction, in: app)
        correction.tap()
        XCTAssertTrue(
            app.buttons["today.execution.correction.save"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["旧记录会保留；这次修改会追加为新的有效记录。"].exists)
        app.buttons["取消"].tap()
    }

    func testReminderConsentShowsNeutralPreviewBeforeSystemPermission() throws {
        continueAfterFailure = false
        let app = launchTodayFixture()
        let reminder = app.buttons["打开此计划的本地提醒"].firstMatch
        scrollToVisible(reminder, in: app)
        XCTAssertTrue(reminder.isHittable)

        reminder.tap()

        XCTAssertTrue(
            app.buttons["today.execution.reminder.confirm"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["给自己留一点时间"].exists)
        XCTAssertTrue(app.staticTexts["打开 App 查看今天的安排。"].exists)
        XCTAssertTrue(app.staticTexts["不会显示 HRT、药名、剂量或身份信息。"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "系统会询问通知权限。App 不主动上传或同步；iOS 可能按系统设置将 App 数据纳入系统备份。通知只在当前设备安排。关闭通知权限也不会删除你的计划。"
            ].exists
        )
        app.buttons["取消"].tap()
    }

    func testReminderConsentPrimaryActionRemainsReachableAtAccessibilityFive() throws {
        continueAfterFailure = false
        let app = launchTodayFixture(additionalArguments: ["-unmanual-ui-test-accessibility5"])
        let reminder = app.buttons["打开此计划的本地提醒"].firstMatch
        scrollToVisible(reminder, in: app)
        reminder.tap()

        let confirm = app.buttons["today.execution.reminder.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.isHittable)
    }

    func testCorrectionPrimaryActionRemainsReachableAtAccessibilityFive() throws {
        continueAfterFailure = false
        let app = launchTodayFixture(additionalArguments: ["-unmanual-ui-test-accessibility5"])
        let taken = app.buttons["已使用"].firstMatch
        scrollToVisible(taken, in: app)
        taken.tap()

        let correction = app.buttons["修改记录"].firstMatch
        XCTAssertTrue(correction.waitForExistence(timeout: 8))
        scrollToVisible(correction, in: app)
        correction.tap()

        let save = app.buttons["today.execution.correction.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isHittable)
    }

    private func launchTodayFixture(additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-empty-store",
            "-unmanual-skip-onboarding",
            "-unmanual-today-execution"
        ] + additionalArguments
        app.launch()
        let ledger = app.descendants(matching: .any)["today.execution.ledger"]
        XCTAssertTrue(ledger.waitForExistence(timeout: 10))
        return app
    }

    private func scrollToVisible(_ element: XCUIElement, in app: XCUIApplication) {
        let todayTab = app.buttons["今天"].firstMatch
        XCTAssertTrue(todayTab.exists)
        let tabBarTop = todayTab.frame.minY
        var attempts = 0
        while attempts < 20 {
            if element.exists,
               element.isHittable,
               element.frame.maxY <= tabBarTop - 8 {
                break
            }
            if element.exists, element.frame.minY < 60 {
                drag(in: app, fromY: 0.38, toY: 0.50)
            } else if element.exists, element.frame.minY < tabBarTop {
                drag(in: app, fromY: 0.55, toY: 0.43)
            } else {
                app.swipeUp()
            }
            attempts += 1
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
        XCTAssertLessThanOrEqual(element.frame.maxY, tabBarTop - 8)
    }

    private func drag(in app: XCUIApplication, fromY: CGFloat, toY: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: fromY))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: toY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
}
