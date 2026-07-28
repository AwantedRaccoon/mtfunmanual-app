import XCTest

@MainActor
final class LabTrendUITests: XCTestCase {
    func testTodayLatestLabOpensTheCorrespondingJourneyRecord() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-empty-store",
            "-unmanual-skip-onboarding",
            "-unmanual-lab-trend"
        ]
        app.launch()

        let latestLab = app.buttons["today.v25.metrics"]
        for _ in 0..<8
        where !latestLab.exists || !latestLab.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(latestLab.waitForExistence(timeout: 12))
        XCTAssertTrue(latestLab.isHittable)
        latestLab.tap()

        XCTAssertTrue(
            app.buttons["查看这个项目的变化"].firstMatch
                .waitForExistence(timeout: 12)
        )
    }

    func testTimelineOpensTrendAndExplicitUnitSelectionKeepsRawLedger() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-empty-store",
            "-unmanual-skip-onboarding",
            "-unmanual-lab-trend"
        ]
        app.launch()

        let journey = app.buttons["旅程"]
        XCTAssertTrue(journey.waitForExistence(timeout: 12))
        journey.tap()

        let labRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "化验记录")
        ).firstMatch
        XCTAssertTrue(labRow.waitForExistence(timeout: 12))
        labRow.tap()

        let trend = app.buttons["查看这个项目的变化"].firstMatch
        XCTAssertTrue(trend.waitForExistence(timeout: 10))
        trend.tap()

        XCTAssertTrue(
            app.staticTexts["化验趋势"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "另有 1 条记录的单位无法"
                )
            ).firstMatch.exists
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "是边界，不作为精确点"
                )
            ).firstMatch.exists
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "172.5 pmol/L"
                )
            ).firstMatch.exists
        )

        let unitPicker = app.descendants(matching: .any)[
            "labTrend.unitPicker"
        ]
        XCTAssertTrue(unitPicker.waitForExistence(timeout: 8))
        unitPicker.tap()
        let nanomoles = app.buttons["nmol/L"].firstMatch
        XCTAssertTrue(nanomoles.waitForExistence(timeout: 8))
        nanomoles.tap()

        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "显示为 0.1725 nmol/L"
                )
            ).firstMatch.waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "172.5 pmol/L"
                )
            ).firstMatch.exists
        )
    }

    func testRegimenLabActionOpensCanonicalSampleEditor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-empty-store",
            "-unmanual-skip-onboarding"
        ]
        app.launch()

        let regimen = app.buttons["方案"]
        XCTAssertTrue(regimen.waitForExistence(timeout: 12))
        regimen.tap()
        let addLab = app.buttons["regimen.labImport"]
        XCTAssertTrue(addLab.waitForExistence(timeout: 10))
        addLab.tap()

        XCTAssertTrue(
            app.staticTexts["添加化验"].waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.buttons["labSample.save"].exists)
        XCTAssertFalse(app.buttons["labImport.save"].exists)
    }

    func testGentleModeRenamesLabSurfacesWithoutHidingOpenedFacts() {
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
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "LAB / 化验"
                )
            ).firstMatch.waitForExistence(timeout: 12)
        )

        enableGentleMode(in: app)

        XCTAssertTrue(app.buttons["今天"].isHittable)
        app.buttons["今天"].tap()
        let latestLab = app.buttons["today.v25.metrics"]
        for _ in 0..<8
        where !latestLab.exists || !latestLab.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(latestLab.waitForExistence(timeout: 12))
        XCTAssertTrue(latestLab.label.contains("最近检查"))
        XCTAssertFalse(latestLab.label.contains("最近化验"))

        XCTAssertTrue(app.buttons["旅程"].isHittable)
        app.buttons["旅程"].tap()
        let gentleKind = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "RECORD / 检查")
        ).firstMatch
        XCTAssertTrue(gentleKind.waitForExistence(timeout: 12))

        let labRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "检查记录")
        ).firstMatch
        XCTAssertTrue(labRow.waitForExistence(timeout: 12))
        labRow.tap()

        XCTAssertTrue(
            app.staticTexts["检查记录"].waitForExistence(timeout: 10)
        )
        XCTAssertFalse(app.staticTexts["化验记录"].exists)
        let trend = app.buttons["查看数据变化"].firstMatch
        XCTAssertTrue(trend.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["查看这个项目的变化"].exists)
        trend.tap()

        XCTAssertTrue(
            app.staticTexts["数据变化"].waitForExistence(timeout: 10)
        )
        XCTAssertFalse(app.staticTexts["化验趋势"].exists)
        XCTAssertTrue(app.staticTexts["雌二醇"].exists)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "172.5 pmol/L"
                )
            ).firstMatch.exists
        )
    }

    private func enableGentleMode(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["档案"].waitForExistence(timeout: 12))
        app.buttons["档案"].tap()
        let toggle = app.descendants(matching: .any)[
            "archive.gentleMode.toggle"
        ]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        scrollToFullyVisible(toggle, in: app)
        XCTAssertTrue(isFullyVisible(toggle, in: app))
        toggle.tap()

        let status = app.descendants(matching: .any)[
            "archive.gentleMode.status"
        ]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        let enabled = NSPredicate(
            format: "label == %@",
            "温和模式已开启"
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: enabled,
                        object: status
                    )
                ],
                timeout: 8
            ),
            .completed
        )
    }

    private func scrollToFullyVisible(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        for _ in 0..<14 where !isFullyVisible(element, in: app) {
            let scrollViews = app.scrollViews
            guard scrollViews.count > 0 else { return }
            scrollViews.element(
                boundBy: scrollViews.count - 1
            ).swipeUp()
        }
    }

    private func isFullyVisible(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) -> Bool {
        guard element.exists, element.isHittable else { return false }
        return unobstructedContentFrame(in: app)
            .insetBy(dx: -1, dy: -1)
            .contains(element.frame)
    }

    private func unobstructedContentFrame(
        in app: XCUIApplication
    ) -> CGRect {
        let windowFrame = app.windows.firstMatch.frame
        let selectedTodayTab = app.buttons["今天"].firstMatch
        guard selectedTodayTab.exists else { return windowFrame }

        let tabBarTop = selectedTodayTab.frame.minY
        guard tabBarTop > windowFrame.minY,
              tabBarTop < windowFrame.maxY else {
            return windowFrame
        }
        return CGRect(
            x: windowFrame.minX,
            y: windowFrame.minY,
            width: windowFrame.width,
            height: tabBarTop - windowFrame.minY
        )
    }
}
