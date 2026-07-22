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

    private func launchTodayFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-empty-store",
            "-unmanual-today-execution"
        ]
        app.launch()
        let ledger = app.descendants(matching: .any)["today.execution.ledger"]
        XCTAssertTrue(ledger.waitForExistence(timeout: 10))
        return app
    }

    private func scrollToVisible(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !element.isHittable && attempts < 10 {
            app.swipeUp()
            attempts += 1
        }
    }
}
