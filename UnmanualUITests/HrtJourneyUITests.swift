import XCTest

@MainActor
final class HrtJourneyUITests: XCTestCase {
    func testActiveJourneyManagementIsReachableAtAccessibilityFive() {
        continueAfterFailure = false
        let app = launchFixture(
            "-unmanual-hrt-active-fixture",
            "-unmanual-ui-test-accessibility5"
        )

        let manage = app.buttons["today.v25.editStartDate"]
        XCTAssertTrue(manage.waitForExistence(timeout: 12))
        XCTAssertTrue(manage.isHittable)
        manage.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["hrtJourney.status"]
                .waitForExistence(timeout: 8)
        )
    }

    func testPausedJourneyManagementIsReachableAtAccessibilityFive() {
        continueAfterFailure = false
        let app = launchFixture(
            "-unmanual-hrt-paused-fixture",
            "-unmanual-ui-test-accessibility5"
        )

        let manage = app.buttons["today.hrtJourney.paused"]
        XCTAssertTrue(manage.waitForExistence(timeout: 12))
        XCTAssertTrue(manage.isHittable)
        manage.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["hrtJourney.status"]
                .waitForExistence(timeout: 8)
        )
    }

    func testActiveJourneyCanBePausedWithoutChangingPlanControls() {
        continueAfterFailure = false
        let app = launchFixture("-unmanual-hrt-active-fixture")

        let manage = app.buttons["today.v25.editStartDate"]
        XCTAssertTrue(manage.waitForExistence(timeout: 12))
        manage.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["hrtJourney.status"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.staticTexts["只记录历程时间"].exists
        )
        let save = app.buttons["startDate.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        XCTAssertTrue(save.isEnabled)
        save.tap()

        XCTAssertTrue(
            app.buttons["today.hrtJourney.paused"]
                .waitForExistence(timeout: 12)
        )
        XCTAssertTrue(app.buttons["方案"].exists)
    }

    func testPausedJourneyCanResumeIntoANewCycle() {
        continueAfterFailure = false
        let app = launchFixture("-unmanual-hrt-paused-fixture")

        let paused = app.buttons["today.hrtJourney.paused"]
        XCTAssertTrue(paused.waitForExistence(timeout: 12))
        paused.tap()

        XCTAssertTrue(
            app.staticTexts["HRT 历程当前已暂停"]
                .waitForExistence(timeout: 8)
        )
        let save = app.buttons["startDate.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        XCTAssertTrue(save.isEnabled)
        save.tap()

        XCTAssertTrue(
            app.buttons["today.v25.editStartDate"]
                .waitForExistence(timeout: 12)
        )
    }

    func testCancellingLifecycleEditorWritesNothingAndReentersActiveState() {
        continueAfterFailure = false
        let app = launchFixture("-unmanual-hrt-active-fixture")

        let manage = app.buttons["today.v25.editStartDate"]
        XCTAssertTrue(manage.waitForExistence(timeout: 12))
        manage.tap()
        let status = app.descendants(matching: .any)["hrtJourney.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["取消"].isHittable)
        app.buttons["取消"].tap()

        XCTAssertTrue(manage.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["today.hrtJourney.paused"].exists)
        manage.tap()
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertTrue(
            status.label.contains("当前处于第 1 段周期")
        )
    }

    func testGentleModeProjectsLifecycleEventsWithoutHrtText() {
        continueAfterFailure = false
        let app = launchFixture("-unmanual-hrt-paused-fixture")

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

        XCTAssertTrue(app.buttons["旅程"].isHittable)
        app.buttons["旅程"].tap()
        XCTAssertTrue(
            app.staticTexts["时间坐标已暂停"]
                .waitForExistence(timeout: 12)
        )
        XCTAssertTrue(app.staticTexts["时间坐标已开始"].exists)
        XCTAssertFalse(app.staticTexts["HRT 历程已暂停"].exists)
        XCTAssertFalse(app.staticTexts["HRT 历程已开始"].exists)
    }

    func testSavingDisablesCancelUntilLifecycleWriteFinishes() {
        continueAfterFailure = false
        let app = launchFixture(
            "-unmanual-hrt-active-fixture",
            "-unmanual-hrt-save-delay"
        )

        let manage = app.buttons["today.v25.editStartDate"]
        XCTAssertTrue(manage.waitForExistence(timeout: 12))
        manage.tap()
        let save = app.buttons["startDate.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        save.tap()

        let saving = NSPredicate(format: "label == %@", "正在保存")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: saving,
                        object: save
                    )
                ],
                timeout: 2
            ),
            .completed
        )
        XCTAssertFalse(save.isEnabled)
        XCTAssertFalse(app.buttons["取消"].isEnabled)
        XCTAssertTrue(
            app.buttons["today.hrtJourney.paused"]
                .waitForExistence(timeout: 12)
        )
    }

    func testReadCorruptionEntersRecoveryInsteadOfStayingInEditor() {
        continueAfterFailure = false
        let app = launchFixture(
            "-unmanual-hrt-editor",
            "-unmanual-hrt-read-error"
        )

        XCTAssertTrue(
            app.buttons["recovery.retry"]
                .waitForExistence(timeout: 12)
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["startDate.readError"]
                .exists
        )
        XCTAssertFalse(app.buttons["startDate.save"].exists)
    }

    private func launchFixture(_ fixtureArguments: String...)
        -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-empty-store",
            "-unmanual-skip-onboarding"
        ] + fixtureArguments
        app.launch()
        return app
    }

    private func scrollToFullyVisible(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        for _ in 0..<14 where !isFullyVisible(element, in: app) {
            let scrollViews = app.scrollViews
            guard scrollViews.count > 0 else { return }
            scrollViews.element(boundBy: scrollViews.count - 1).swipeUp()
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
