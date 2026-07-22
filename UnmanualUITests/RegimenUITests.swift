import XCTest

@MainActor
final class RegimenUITests: XCTestCase {
    func testDraftPreviewCancelAndSealFlow() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-unmanual-empty-store", "-unmanual-regimen-editor"]
        app.launch()

        let title = app.textFields["regimen.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.tap()
        title.typeText("当前个人方案")

        let save = app.buttons["regimen.save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()

        let confirm = app.buttons["regimen.confirmSeal"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["变更前"].exists)
        XCTAssertTrue(app.staticTexts["这是第一个方案版本"].exists)
        XCTAssertTrue(app.staticTexts["变更后"].exists)
        XCTAssertTrue(app.staticTexts["R-01 · 当前个人方案"].exists)

        app.buttons["返回修改"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))

        save.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        confirm.tap()

        XCTAssertFalse(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(title.exists)
        XCTAssertEqual(app.state, .runningForeground)
    }
}
