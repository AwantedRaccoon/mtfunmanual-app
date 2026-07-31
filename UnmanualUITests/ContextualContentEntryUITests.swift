import XCTest

@MainActor
final class ContextualContentEntryUITests: XCTestCase {
    func testLabContextualReaderPreservesDraftAndSaveGate()
        throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-empty-store",
            "-unmanual-skip-onboarding",
            "-unmanual-lab-editor"
        ]
        app.launch()

        let specimen = app.textFields["样本类型（可选）"]
        XCTAssertTrue(specimen.waitForExistence(timeout: 8))
        specimen.tap()
        specimen.typeText("血清")

        let entry = app.buttons["contextual.labRecording"]
        scrollTo(entry, in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["contextual.reader.sheet"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            app.buttons["pocketAppendix.reader.favorite"].exists
        )
        app.buttons["contextual.reader.close"].tap()

        XCTAssertTrue(specimen.waitForExistence(timeout: 5))
        XCTAssertEqual(specimen.value as? String, "血清")
        XCTAssertFalse(app.buttons["labSample.save"].isEnabled)
    }

    func testContextualReaderRemainsReachableAtAccessibilityFive()
        throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-empty-store",
            "-unmanual-skip-onboarding",
            "-unmanual-lab-editor",
            "-unmanual-ui-test-accessibility5"
        ]
        app.launch()

        let entry = app.buttons["contextual.labRecording"]
        scrollTo(entry, in: app)
        scrollFullyIntoWindow(entry, in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        assertReachableAndInsideWindow(entry, in: app)
        entry.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)[
                "contextual.reader.sheet"
            ].waitForExistence(timeout: 5)
        )
        let close = app.buttons["contextual.reader.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(close.isHittable)
        assertInsideWindow(close, in: app)
        try app.performAccessibilityAudit(for: [
            .hitRegion,
            .sufficientElementDescription,
            .textClipped,
            .trait
        ])
    }

    private func scrollTo(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        for _ in 0..<12 where
            !element.exists || !element.isHittable {
            app.swipeUp()
        }
    }

    private func assertReachableAndInsideWindow(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.exists, file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            element.frame.width,
            44,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            element.frame.height,
            44,
            file: file,
            line: line
        )
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(
            element.frame.minX,
            window.minX - 1,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            element.frame.maxX,
            window.maxX + 1,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            element.frame.minY,
            window.minY - 1,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            element.frame.maxY,
            window.maxY + 1,
            file: file,
            line: line
        )
    }

    private func scrollFullyIntoWindow(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        let window = app.windows.firstMatch.frame
        for _ in 0..<8 {
            guard element.exists else {
                app.swipeUp()
                continue
            }
            let frame = element.frame
            if element.isHittable,
               frame.minY >= window.minY,
               frame.maxY <= window.maxY {
                return
            }
            let start: CGVector
            let end: CGVector
            if frame.maxY > window.maxY {
                start = CGVector(dx: 0.5, dy: 0.72)
                end = CGVector(dx: 0.5, dy: 0.52)
            } else {
                start = CGVector(dx: 0.5, dy: 0.38)
                end = CGVector(dx: 0.5, dy: 0.55)
            }
            app.coordinate(
                withNormalizedOffset: start
            ).press(
                forDuration: 0.05,
                thenDragTo:
                    app.coordinate(
                        withNormalizedOffset: end
                    )
            )
        }
    }

    private func assertInsideWindow(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frame = element.frame
        let window = app.windows.firstMatch.frame
        XCTAssertFalse(frame.isEmpty, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            frame.minX,
            window.minX - 1,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            frame.maxX,
            window.maxX + 1,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            frame.minY,
            window.minY - 1,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            frame.maxY,
            window.maxY + 1,
            file: file,
            line: line
        )
    }
}
