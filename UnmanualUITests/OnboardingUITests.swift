import XCTest

@MainActor
final class OnboardingUITests: XCTestCase {
    func testFreshInstallShowsPrivacyBeforeShellAndPersistsResumeStep()
        throws
    {
        continueAfterFailure = false
        let storeID = UUID()
        defer { cleanupDurableStore(storeID) }

        let firstLaunch = XCUIApplication()
        firstLaunch.launchArguments = durableStoreArguments(
            storeID,
            resetsBeforeOpen: true
        )
        firstLaunch.launch()

        let privacyContinue = firstLaunch.buttons[
            "onboarding.privacy.continue"
        ]
        XCTAssertTrue(privacyContinue.waitForExistence(timeout: 12))
        XCTAssertFalse(shell(in: firstLaunch).exists)
        privacyContinue.tap()
        XCTAssertTrue(
            firstLaunch.buttons[
                "onboarding.startDate.continue"
            ].waitForExistence(timeout: 8)
        )
        firstLaunch.terminate()

        let resumed = XCUIApplication()
        resumed.launchArguments = durableStoreArguments(storeID)
        resumed.launch()

        XCTAssertTrue(
            resumed.buttons[
                "onboarding.startDate.continue"
            ].waitForExistence(timeout: 12)
        )
        XCTAssertFalse(resumed.buttons["onboarding.privacy.continue"].exists)
        XCTAssertFalse(shell(in: resumed).exists)
    }

    func testRegimenIsARequiredGate() {
        continueAfterFailure = false
        let app = launchInMemory()

        tapWhenReady("onboarding.privacy.continue", in: app)
        tapWhenReady("onboarding.startDate.continue", in: app)

        let continueRegimen = app.buttons[
            "onboarding.regimen.continue"
        ]
        XCTAssertTrue(continueRegimen.waitForExistence(timeout: 8))
        XCTAssertFalse(continueRegimen.isEnabled)
        XCTAssertTrue(app.buttons["onboarding.regimen.new"].exists)
        XCTAssertFalse(shell(in: app).exists)
        let register = app.staticTexts["SETUP / 03"]
        XCTAssertTrue(register.exists)
        let windowFrame = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(register.frame.minX, windowFrame.minX)
        XCTAssertLessThanOrEqual(register.frame.maxX, windowFrame.maxX)
    }

    func testEligibleRegimenAllowsOptionalStepsAndCompletion() {
        continueAfterFailure = false
        let app = launchInMemory(
            additionalArguments: [
                "-unmanual-onboarding-eligible-regimen"
            ]
        )

        tapWhenReady("onboarding.privacy.continue", in: app)
        tapWhenReady("onboarding.startDate.continue", in: app)

        let continueRegimen = app.buttons[
            "onboarding.regimen.continue"
        ]
        XCTAssertTrue(continueRegimen.waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: continueRegimen
        )
        wait(for: [enabled], timeout: 10)
        continueRegimen.tap()

        tapWhenReady("onboarding.reminder.continue", in: app)
        tapWhenReady("onboarding.countdown.continue", in: app)
        tapWhenReady("onboarding.complete", in: app)

        XCTAssertTrue(shell(in: app).waitForExistence(timeout: 12))
        XCTAssertFalse(app.descendants(matching: .any)["onboarding.flow"].exists)
        XCTAssertTrue(
            app.buttons["today.v25.quickRecord"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.staticTexts["今天先从此刻开始"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "不需要先填写 HRT 日期或化验资料。想留下什么时，再记录一条。"
            ].exists
        )
        XCTAssertFalse(app.staticTexts["先标记你的开始日"].exists)
        XCTAssertFalse(app.staticTexts["HRT 日数刻度"].exists)
        XCTAssertFalse(app.buttons["today.v25.editStartDate"].exists)
        XCTAssertFalse(app.buttons["today.hrtJourney.paused"].exists)
        XCTAssertFalse(app.buttons["today.v25.metrics"].exists)
    }

    func testReadFailureFailsClosedWithoutShowingShell() {
        continueAfterFailure = false
        let app = launchInMemory(
            additionalArguments: [
                "-unmanual-onboarding-read-error"
            ]
        )

        XCTAssertTrue(
            app.descendants(matching: .any)[
                "onboarding.gate.error"
            ].waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.buttons["onboarding.gate.retry"].exists)
        XCTAssertFalse(shell(in: app).exists)
    }

    func testReadyPageReturnsToPersistedStepBeforeModification() {
        continueAfterFailure = false
        let app = launchInMemory(
            additionalArguments: [
                "-unmanual-onboarding-eligible-regimen"
            ]
        )

        tapWhenReady("onboarding.privacy.continue", in: app)
        tapWhenReady("onboarding.startDate.continue", in: app)
        tapWhenReady("onboarding.regimen.continue", in: app)
        tapWhenReady("onboarding.reminder.continue", in: app)
        tapWhenReady("onboarding.countdown.continue", in: app)
        tapWhenReady("onboarding.ready.editStartDate", in: app)

        XCTAssertTrue(
            app.buttons[
                "onboarding.startDate.continue"
            ].waitForExistence(timeout: 8)
        )
        XCTAssertFalse(app.buttons["onboarding.complete"].exists)
    }

    func testDeniedNotificationPermissionIsNotShownAsArranged() {
        continueAfterFailure = false
        let app = launchInMemory(
            additionalArguments: [
                "-unmanual-onboarding-eligible-regimen",
                "-unmanual-notification-denied",
            ]
        )

        tapWhenReady("onboarding.privacy.continue", in: app)
        tapWhenReady("onboarding.startDate.continue", in: app)
        tapWhenReady("onboarding.regimen.continue", in: app)

        let setup = app.buttons["设置提醒"].firstMatch
        XCTAssertTrue(setup.waitForExistence(timeout: 8))
        setup.tap()
        let open = app.buttons["打开"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        open.tap()
        tapWhenReady("onboarding.reminder.confirm", in: app)

        let denied = app.staticTexts[
            "已选择，系统通知已关闭"
        ]
        XCTAssertTrue(denied.waitForExistence(timeout: 12))
        XCTAssertFalse(app.staticTexts["提醒已打开"].exists)
        tapWhenReady("onboarding.reminder.done", in: app)
        let parentDenied = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@",
                "系统通知已关闭"
            )
        ).firstMatch
        XCTAssertTrue(
            parentDenied.waitForExistence(timeout: 8)
        )
    }

    func testOptionalFactsCanBeSavedThroughEditorsAndCompleted() {
        continueAfterFailure = false
        let app = launchInMemory(
            additionalArguments: [
                "-unmanual-onboarding-eligible-regimen",
                "-unmanual-notification-denied",
            ]
        )

        tapWhenReady("onboarding.privacy.continue", in: app)

        let editStartDate = app.buttons["填写日期"]
        XCTAssertTrue(editStartDate.waitForExistence(timeout: 8))
        editStartDate.tap()
        tapWhenReady("startDate.save", in: app)
        tapWhenReady("onboarding.startDate.continue", in: app)
        tapWhenReady("onboarding.regimen.continue", in: app)

        let setupReminder = app.buttons["设置提醒"].firstMatch
        XCTAssertTrue(setupReminder.waitForExistence(timeout: 8))
        setupReminder.tap()
        let openReminder = app.buttons["打开"].firstMatch
        XCTAssertTrue(openReminder.waitForExistence(timeout: 8))
        openReminder.tap()
        tapWhenReady("onboarding.reminder.confirm", in: app)
        XCTAssertTrue(
            app.staticTexts["已选择，系统通知已关闭"]
                .waitForExistence(timeout: 12)
        )
        tapWhenReady("onboarding.reminder.done", in: app)
        tapWhenReady("onboarding.reminder.continue", in: app)

        let createCountdown = app.buttons["建立 Countdown"]
        XCTAssertTrue(createCountdown.waitForExistence(timeout: 8))
        createCountdown.tap()
        let title = app.textFields["countdown.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.tap()
        title.typeText("首次设置目标")
        tapWhenReady("countdown.save", in: app)
        tapWhenReady("onboarding.countdown.continue", in: app)
        tapWhenReady("onboarding.complete", in: app)

        XCTAssertTrue(shell(in: app).waitForExistence(timeout: 12))
    }

    func testArchiveCanReenterSettingsWithoutResettingRootGate() {
        continueAfterFailure = false
        let app = launchInMemory(
            additionalArguments: [
                "-unmanual-archive"
            ]
        )

        let entry = app.buttons[
            "archive.onboarding"
        ]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        for _ in 0..<5 where !entry.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(entry.isHittable)
        entry.tap()
        tapWhenReady("onboarding.revisit.done", in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        XCTAssertTrue(entry.isHittable)
        entry.tap()
        XCTAssertTrue(
            app.staticTexts["首次设置与提醒"]
                .waitForExistence(timeout: 8)
        )
        tapWhenReady("onboarding.revisit.done", in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        XCTAssertFalse(shell(in: app).exists)
    }

    func testPrivacyStepRemainsReachableAtAccessibilityFiveInLandscape()
        throws
    {
        continueAfterFailure = false
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchInMemory(
            additionalArguments: [
                "-unmanual-ui-test-accessibility5"
            ],
            orientation: .landscapeLeft
        )
        let continueButton = app.buttons[
            "onboarding.privacy.continue"
        ]

        XCTAssertTrue(continueButton.waitForExistence(timeout: 8))
        XCTAssertTrue(continueButton.isHittable)
        XCTAssertGreaterThanOrEqual(continueButton.frame.width, 44)
        XCTAssertGreaterThanOrEqual(continueButton.frame.height, 44)
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "onboarding.progress"
            ].exists
        )
        try app.performAccessibilityAudit(for: [
            .hitRegion,
            .sufficientElementDescription,
            .textClipped,
            .trait
        ])
    }

    private func launchInMemory(
        additionalArguments: [String] = [],
        orientation: UIDeviceOrientation = .portrait
    ) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-empty-store"
        ] + additionalArguments
        app.launch()
        return app
    }

    private func durableStoreArguments(
        _ id: UUID,
        resetsBeforeOpen: Bool = false
    ) -> [String] {
        var arguments = [
            "-unmanual-ui-test-store-id",
            id.uuidString
        ]
        if resetsBeforeOpen {
            arguments.append("-unmanual-ui-test-reset-store")
        }
        return arguments
    }

    private func cleanupDurableStore(_ id: UUID) {
        let cleanup = XCUIApplication()
        cleanup.launchArguments = [
            "-unmanual-ui-test-store-id",
            id.uuidString,
            "-unmanual-ui-test-cleanup-store",
            "-unmanual-skip-onboarding"
        ]
        cleanup.launch()
        _ = shell(in: cleanup).waitForExistence(timeout: 8)
        cleanup.terminate()
    }

    private func tapWhenReady(
        _ identifier: String,
        in app: XCUIApplication
    ) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 10), identifier)
        XCTAssertTrue(button.isHittable, identifier)
        button.tap()
    }

    private func shell(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["app.shell"]
    }
}
