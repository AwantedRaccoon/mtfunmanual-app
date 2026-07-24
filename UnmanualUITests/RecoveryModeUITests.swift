import XCTest

@MainActor
final class RecoveryModeUITests: XCTestCase {
    func testRetryFromRecoveryReachesReadyApp() throws {
        let app = launchRecoveryThatSucceedsOnRetry()
        let retry = app.buttons["recovery.retry"]

        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertEqual(retry.label, "重新检查本地资料")

        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.exists)
        for _ in 0..<6 where !retry.isHittable {
            scrollView.swipeUp()
        }

        XCTAssertTrue(retry.isHittable)
        XCTAssertGreaterThanOrEqual(retry.frame.width, 44)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        attachScreenshot(named: "Recovery-before-retry")
        try auditRecoveryAccessibility(in: app)

        retry.tap()

        XCTAssertTrue(readyShell(in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(retry.exists)
        XCTAssertEqual(app.state, .runningForeground)
        attachScreenshot(named: "Recovery-after-ready")
    }

    func testMaximumContentSizeCanScrollToRetryAndReachReadyApp() throws {
        let app = launchRecoveryThatSucceedsOnRetry(maximumDynamicType: true)
        let retry = app.buttons["recovery.retry"]

        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)
        if window.frame.width < 600 {
            XCTAssertFalse(
                retry.isHittable,
                "Accessibility5 should require real scrolling on the phone matrix."
            )
        }

        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.exists)
        for _ in 0..<6 where !retry.isHittable {
            scrollView.swipeUp()
        }

        XCTAssertTrue(retry.isHittable)
        XCTAssertGreaterThanOrEqual(retry.frame.width, 44)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        try auditRecoveryAccessibility(in: app, includeDynamicType: false)
        attachScreenshot(named: "Recovery-maximum-type-after-scroll")

        retry.tap()

        XCTAssertTrue(readyShell(in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(retry.exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testLandscapeCanScrollToRetryAndReachReadyApp() throws {
        let app = launchRecoveryThatSucceedsOnRetry(orientation: .landscapeLeft)
        let retry = app.buttons["recovery.retry"]

        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertEqual(retry.label, "重新检查本地资料")

        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.exists)
        for _ in 0..<6 where !retry.isHittable {
            scrollView.swipeUp()
        }

        XCTAssertTrue(retry.isHittable)
        XCTAssertGreaterThanOrEqual(retry.frame.width, 44)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        try auditRecoveryAccessibility(in: app)
        attachScreenshot(named: "Recovery-landscape-before-retry")

        retry.tap()

        XCTAssertTrue(readyShell(in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(retry.exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func launchRecoveryThatSucceedsOnRetry(
        maximumDynamicType: Bool = false,
        orientation: UIDeviceOrientation = .portrait
    ) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-recovery-once",
            "corruptionSuspected",
            "-unmanual-empty-store"
        ]
        if maximumDynamicType {
            app.launchArguments.append("-unmanual-ui-test-accessibility5")
        }
        app.launch()
        return app
    }

    private func readyShell(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["app.shell"]
    }

    private func auditRecoveryAccessibility(
        in app: XCUIApplication,
        includeDynamicType: Bool = true
    ) throws {
        var auditTypes: XCUIAccessibilityAuditType = [
            .hitRegion,
            .sufficientElementDescription,
            .textClipped,
            .trait
        ]
        if includeDynamicType {
            auditTypes.insert(.dynamicType)
        }
        try app.performAccessibilityAudit(for: auditTypes)
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
final class SystemBackupDisclosureUITests: XCTestCase {
    func testTodayDisclosureIsReachableAndNotClipped() throws {
        let app = launch()
        XCTAssertTrue(statusElement(in: app).waitForExistence(timeout: 5))

        let disclosure = element("today.backupDisclosure", in: app)
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        scrollToFullyVisible(disclosure, in: app)
        XCTAssertTrue(disclosure.isHittable)
        assertFullyVisible(disclosure, in: app)

        attachScreenshot(named: "SystemBackup-Today")
    }

    func testArchiveDisclosureIsReachableAndNotClipped() throws {
        let app = launch(arguments: ["-unmanual-archive"])
        let localStorage = element("archive.localStorage", in: app)
        XCTAssertTrue(localStorage.waitForExistence(timeout: 5))
        scrollToVisible(localStorage, in: app)
        XCTAssertTrue(localStorage.isHittable)
        localStorage.tap()

        let boundary = app.staticTexts[
            "iOS 可能按你的设置将 App 数据纳入 iCloud 或电脑的系统备份；App 不保证每次备份或恢复成功。"
        ]
        XCTAssertTrue(boundary.waitForExistence(timeout: 5))
        scrollToFullyVisible(boundary, in: app)
        XCTAssertTrue(boundary.isHittable)
        assertFullyVisible(boundary, in: app)

        let footer = element("archive.preview.footer", in: app)
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
        scrollToFullyVisible(footer, in: app)
        XCTAssertTrue(footer.isHittable)
        assertFullyVisible(footer, in: app)

        attachScreenshot(named: "SystemBackup-Archive")
    }

    func testQuickRecordDisclosureIsReachableAndNotClipped() throws {
        let app = launch(arguments: ["-unmanual-quick-record"])
        XCTAssertTrue(
            app.staticTexts["附件"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["从照片中选择"].exists)
        let saveButton = element("quickRecord.save", in: app)
        XCTAssertTrue(saveButton.exists)
        XCTAssertFalse(saveButton.isEnabled)

        let disclosure = element("quickRecord.backupDisclosure", in: app)
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        scrollToFullyVisible(disclosure, in: app)
        XCTAssertTrue(disclosure.isHittable)
        assertFullyVisible(disclosure, in: app)

        attachScreenshot(named: "SystemBackup-QuickRecord")
    }

    func testCountdownDisclosureIsReachableAndNotClipped() throws {
        let app = launch(arguments: ["-unmanual-countdown"])
        let disclosure = app.staticTexts[
            "温和模式可以使用这个名称，但不会改变系统备份设置，也不会隐藏导出文件。"
        ]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        scrollToVisible(disclosure, in: app)
        XCTAssertTrue(disclosure.isHittable)
        assertFullyVisible(disclosure, in: app)

        attachScreenshot(named: "SystemBackup-Countdown")
    }

    func testTodayDisclosureAtAccessibility5IsReachableAndNotClipped() throws {
        let app = launch(maximumDynamicType: true)
        let status = statusElement(in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "本地保存")
        assertFullyVisible(status, in: app)

        let disclosure = element("today.backupDisclosure", in: app)
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        scrollToFullyVisible(disclosure, in: app)
        XCTAssertTrue(disclosure.isHittable)
        assertFullyVisible(disclosure, in: app)
        try auditVisibleText(in: app)

        attachScreenshot(named: "SystemBackup-Today-Accessibility5")
    }

    func testAppTabsAtAccessibility5AreFullyVisible() throws {
        let app = launch(maximumDynamicType: true)
        XCTAssertTrue(app.buttons["今天"].waitForExistence(timeout: 5))
        let windowFrame = app.windows.firstMatch.frame

        for title in ["今天", "旅程", "方案", "档案"] {
            let tab = app.buttons[title].firstMatch
            XCTAssertTrue(tab.exists, "Expected the \(title) tab to remain exposed.")
            XCTAssertFalse(tab.frame.isEmpty)
            XCTAssertTrue(
                windowFrame.insetBy(dx: -1, dy: -1).contains(tab.frame),
                "The \(title) tab must stay inside the screen at Accessibility 5. tab=\(tab.frame), window=\(windowFrame)"
            )
        }
        try auditVisibleText(in: app)
        attachScreenshot(named: "SystemBackup-AppTabs-Accessibility5")
    }

    func testArchiveDisclosureAtAccessibility5IsReachableAndNotClipped() throws {
        let app = launch(arguments: ["-unmanual-archive"], maximumDynamicType: true)
        let localStorage = element("archive.localStorage", in: app)
        XCTAssertTrue(localStorage.waitForExistence(timeout: 5))
        scrollToVisible(localStorage, in: app)
        XCTAssertTrue(localStorage.isHittable)
        localStorage.tap()

        let boundary = app.staticTexts[
            "iOS 可能按你的设置将 App 数据纳入 iCloud 或电脑的系统备份；App 不保证每次备份或恢复成功。"
        ]
        XCTAssertTrue(boundary.waitForExistence(timeout: 5))
        scrollToFullyVisible(boundary, in: app)
        XCTAssertTrue(boundary.isHittable)
        assertFullyVisible(boundary, in: app)
        try auditVisibleText(in: app)

        attachScreenshot(named: "SystemBackup-Archive-Accessibility5")
    }

    func testQuickRecordDisclosureAtAccessibility5IsReachableAndNotClipped() throws {
        let app = launch(arguments: ["-unmanual-quick-record"], maximumDynamicType: true)
        let disclosure = element("quickRecord.backupDisclosure", in: app)
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        scrollToFullyVisible(disclosure, in: app)
        XCTAssertTrue(disclosure.isHittable)
        assertFullyVisible(disclosure, in: app)
        try auditVisibleText(in: app)

        attachScreenshot(named: "SystemBackup-QuickRecord-Accessibility5")
    }

    func testCountdownDisclosureAtAccessibility5IsReachableAndNotClipped() throws {
        let app = launch(arguments: ["-unmanual-countdown"], maximumDynamicType: true)
        let datePicker = element("countdown.date", in: app)
        XCTAssertTrue(datePicker.waitForExistence(timeout: 5))
        scrollToVisible(datePicker, in: app)
        XCTAssertTrue(datePicker.isHittable)
        assertHorizontallyContained(datePicker, in: app)
        attachScreenshot(named: "SystemBackup-Countdown-Date-Accessibility5")

        let disclosure = app.staticTexts[
            "温和模式可以使用这个名称，但不会改变系统备份设置，也不会隐藏导出文件。"
        ]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        scrollToFullyVisible(disclosure, in: app)
        XCTAssertTrue(disclosure.isHittable)
        assertFullyVisible(disclosure, in: app)
        try auditVisibleText(in: app)

        attachScreenshot(named: "SystemBackup-Countdown-Accessibility5")
    }

    private func launch(
        arguments: [String] = [],
        maximumDynamicType: Bool = false
    ) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-unmanual-empty-store"] + arguments
        if maximumDynamicType {
            app.launchArguments.append("-unmanual-ui-test-accessibility5")
        }
        app.launch()
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func statusElement(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(identifier: "today.backupStatus").firstMatch
    }

    private func scrollToVisible(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<14 where !element.isHittable {
            let scrollViews = app.scrollViews
            guard scrollViews.count > 0 else { return }
            scrollViews.element(boundBy: scrollViews.count - 1).swipeUp()
        }
    }

    private func scrollToFullyVisible(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<14 where !isFullyVisible(element, in: app) {
            let scrollViews = app.scrollViews
            guard scrollViews.count > 0 else { return }
            scrollViews.element(boundBy: scrollViews.count - 1).swipeUp()
        }
    }

    private func isFullyVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isHittable else { return false }
        return unobstructedContentFrame(in: app).insetBy(dx: -1, dy: -1).contains(element.frame)
    }

    private func assertFullyVisible(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frame = element.frame
        let visibleFrame = unobstructedContentFrame(in: app)
        XCTAssertFalse(element.label.isEmpty, file: file, line: line)
        XCTAssertFalse(frame.isEmpty, file: file, line: line)
        XCTAssertTrue(
            visibleFrame.insetBy(dx: -1, dy: -1).contains(frame),
            "Target copy must be fully inside the unobstructed content region. target=\(frame), visible=\(visibleFrame)",
            file: file,
            line: line
        )
    }

    private func assertHorizontallyContained(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frame = element.frame
        let windowFrame = app.windows.firstMatch.frame
        XCTAssertFalse(frame.isEmpty, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            frame.minX,
            windowFrame.minX - 1,
            "Target must not overflow the leading screen edge. target=\(frame), window=\(windowFrame)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            frame.maxX,
            windowFrame.maxX + 1,
            "Target must not overflow the trailing screen edge. target=\(frame), window=\(windowFrame)",
            file: file,
            line: line
        )
    }

    private func unobstructedContentFrame(in app: XCUIApplication) -> CGRect {
        let windowFrame = app.windows.firstMatch.frame
        let selectedTodayTab = app.buttons["今天"].firstMatch
        guard selectedTodayTab.exists else { return windowFrame }

        let tabBarTop = selectedTodayTab.frame.minY
        guard tabBarTop > windowFrame.minY, tabBarTop < windowFrame.maxY else {
            return windowFrame
        }
        return CGRect(
            x: windowFrame.minX,
            y: windowFrame.minY,
            width: windowFrame.width,
            height: tabBarTop - windowFrame.minY
        )
    }

    private func auditVisibleText(in app: XCUIApplication) throws {
        try app.performAccessibilityAudit(for: [.textClipped])
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
