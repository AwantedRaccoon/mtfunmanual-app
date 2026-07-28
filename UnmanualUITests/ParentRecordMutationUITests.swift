import XCTest

@MainActor
final class ParentRecordMutationUITests: XCTestCase {
    func testLabCorrectionReviewSaveAndTerminalDeleteFlow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-empty-store",
            "-unmanual-skip-onboarding",
            "-unmanual-lab-trend"
        ]
        app.launch()

        XCTAssertTrue(app.buttons["旅程"].waitForExistence(timeout: 12))
        app.buttons["旅程"].tap()

        let labRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "化验记录")
        ).firstMatch
        XCTAssertTrue(labRow.waitForExistence(timeout: 12))
        labRow.tap()

        let correct = app.descendants(matching: .any)[
            "parentRecord.correct"
        ]
        scrollTo(correct, in: app)
        XCTAssertTrue(correct.waitForExistence(timeout: 8))
        correct.tap()

        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "更正化验"
                )
            ).firstMatch.waitForExistence(timeout: 8)
        )
        let specimen = app.textFields["样本类型（可选）"]
        XCTAssertTrue(specimen.waitForExistence(timeout: 8))
        specimen.tap()
        specimen.typeText("血清")

        let moveEstradiolDown = app.buttons[
            "labCorrection.result."
                + "89000000-0000-0000-0000-000000000203"
                + ".moveDown"
        ]
        scrollTo(moveEstradiolDown, in: app)
        XCTAssertTrue(moveEstradiolDown.waitForExistence(timeout: 8))
        XCTAssertTrue(moveEstradiolDown.isEnabled)
        moveEstradiolDown.tap()

        let review = app.descendants(matching: .any)[
            "labCorrection.review"
        ]
        scrollTo(review, in: app)
        XCTAssertTrue(review.waitForExistence(timeout: 8))
        XCTAssertTrue(review.isEnabled)
        review.tap()

        XCTAssertTrue(
            app.staticTexts["请确认这些变化"]
                .waitForExistence(timeout: 8)
        )
        let expectedOrder =
            "结果顺序："
                + "雌二醇 · E2 · 识别码 "
                + "89000000-0000-0000-0000-000000000001、"
                + "睾酮 · T · 识别码 "
                + "89000000-0000-0000-0000-000000000002"
                + " → "
                + "睾酮 · T · 识别码 "
                + "89000000-0000-0000-0000-000000000002、"
                + "雌二醇 · E2 · 识别码 "
                + "89000000-0000-0000-0000-000000000001"
        let orderText = app.staticTexts.matching(
            NSPredicate(format: "label == %@", expectedOrder)
        ).firstMatch
        XCTAssertTrue(orderText.waitForExistence(timeout: 8))
        let confirmCorrection = app.descendants(matching: .any)[
            "labCorrection.confirm"
        ]
        XCTAssertTrue(confirmCorrection.waitForExistence(timeout: 8))
        confirmCorrection.tap()

        XCTAssertTrue(
            app.staticTexts["血清"].waitForExistence(timeout: 10)
        )
        let delete = app.descendants(matching: .any)[
            "parentRecord.delete"
        ]
        scrollTo(delete, in: app)
        XCTAssertTrue(delete.waitForExistence(timeout: 8))
        delete.tap()

        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "删除记录"
                )
            ).firstMatch.waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "不是取证级擦除"
                )
            ).firstMatch.exists
        )
        let confirmDelete = app.descendants(matching: .any)[
            "parentDelete.confirm"
        ]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 8))
        confirmDelete.tap()

        let remainingLabs = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "化验记录")
        )
        XCTAssertTrue(
            remainingLabs.firstMatch.waitForExistence(timeout: 10)
        )
        XCTAssertEqual(remainingLabs.count, 2)
    }

    private func scrollTo(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        for _ in 0..<8 where !element.exists || !element.isHittable {
            app.swipeUp()
        }
    }
}
