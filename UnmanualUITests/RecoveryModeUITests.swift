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
            "-unmanual-empty-store",
            "-unmanual-skip-onboarding"
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
        let storeID = UUID()
        defer { cleanupDurableStore(storeID) }
        let app = launch(
            arguments: ["-unmanual-archive"],
            durableStoreID: storeID
        )
        let localStorage = element("archive.localStorage", in: app)
        XCTAssertTrue(localStorage.waitForExistence(timeout: 5))
        scrollToVisible(localStorage, in: app)
        XCTAssertTrue(localStorage.isHittable)
        localStorage.tap()
        let integrity = element(
            "archive.localStorage.integrity",
            in: app
        )
        XCTAssertTrue(integrity.waitForExistence(timeout: 12))
        XCTAssertTrue(
            app.staticTexts["清单核对完整"]
                .waitForExistence(timeout: 5)
        )

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
        let storeID = UUID()
        defer { cleanupDurableStore(storeID) }
        let app = launch(
            arguments: ["-unmanual-archive"],
            maximumDynamicType: true,
            durableStoreID: storeID
        )
        let localStorage = element("archive.localStorage", in: app)
        XCTAssertTrue(localStorage.waitForExistence(timeout: 5))
        scrollToVisible(localStorage, in: app)
        XCTAssertTrue(localStorage.isHittable)
        localStorage.tap()
        XCTAssertTrue(
            element(
                "archive.localStorage.integrity",
                in: app
            ).waitForExistence(timeout: 12)
        )

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

    func testArchiveInventoryFailureCanRetryToComplete() throws {
        let storeID = UUID()
        defer { cleanupDurableStore(storeID) }
        let app = launch(
            arguments: [
                "-unmanual-archive",
                "-unmanual-ui-test-inventory-fail-once"
            ],
            durableStoreID: storeID
        )
        let localStorage = element("archive.localStorage", in: app)
        XCTAssertTrue(localStorage.waitForExistence(timeout: 8))
        scrollToVisible(localStorage, in: app)
        localStorage.tap()

        let unavailable = element(
            "archive.localStorage.unavailable",
            in: app
        )
        XCTAssertTrue(unavailable.waitForExistence(timeout: 12))
        let retry = element("archive.localStorage.retry", in: app)
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertTrue(retry.isEnabled)
        retry.tap()

        let integrity = element(
            "archive.localStorage.integrity",
            in: app
        )
        XCTAssertTrue(integrity.waitForExistence(timeout: 12))
        XCTAssertTrue(
            app.staticTexts["清单核对完整"]
                .waitForExistence(timeout: 5)
        )
    }

    func testArchiveDataControlDeletionCanCancelConfirmAndStayDeletedAfterReopen()
        throws
    {
        let storeID = UUID()
        defer { cleanupDurableStore(storeID) }
        let app = launch(
            arguments: [
                "-unmanual-archive",
                "-unmanual-hrt-active-fixture"
            ],
            durableStoreID: storeID
        )
        openDataControl(in: app)

        let target = element(
            "archive.dataControl.target.hrt-journey",
            in: app
        )
        XCTAssertTrue(target.waitForExistence(timeout: 12))
        target.tap()

        let confirm = element(
            "archive.dataControl.confirm",
            in: app
        )
        XCTAssertTrue(confirm.waitForExistence(timeout: 12))
        scrollToVisible(confirm, in: app)
        confirm.tap()

        let alert = app.alerts["再次确认移除？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["取消"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))

        confirm.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["从普通页面移除"].tap()

        let success = element(
            "archive.dataControl.success",
            in: app
        )
        XCTAssertTrue(success.waitForExistence(timeout: 15))
        XCTAssertFalse(target.exists)
        attachScreenshot(
            named: "DataControl-Deletion-Confirmed"
        )
        app.terminate()

        let reopened = launch(
            arguments: ["-unmanual-archive"],
            durableStoreID: storeID,
            resetsBeforeOpen: false
        )
        openDataControl(in: reopened)
        XCTAssertTrue(
            reopened.staticTexts[
                "当前没有可逐项移除的记录"
            ].waitForExistence(timeout: 12)
        )
        XCTAssertFalse(
            element(
                "archive.dataControl.target.hrt-journey",
                in: reopened
            ).exists
        )
        attachScreenshot(
            named: "DataControl-Deletion-Reopened"
        )
    }

    func testArchiveDataControlResetCanCancelThenCompletesAcrossColdLaunch()
        throws
    {
        let storeID = UUID()
        defer { cleanupDurableStore(storeID) }
        let app = launch(
            arguments: [
                "-unmanual-archive",
                "-unmanual-hrt-active-fixture"
            ],
            durableStoreID: storeID
        )
        openDataControl(in: app)

        let reset = element(
            "archive.dataControl.resetConfirm",
            in: app
        )
        XCTAssertTrue(reset.waitForExistence(timeout: 12))
        scrollToVisible(reset, in: app)
        reset.tap()

        let alert = app.alerts["清空全部 App 数据？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["取消"].tap()
        XCTAssertTrue(reset.waitForExistence(timeout: 5))

        reset.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["隔离并准备清空"].tap()
        XCTAssertTrue(
            element(
                "dataReset.restartRequired",
                in: app
            ).waitForExistence(timeout: 20)
        )
        attachScreenshot(
            named: "DataControl-Reset-RestartRequired"
        )
        app.terminate()

        let coldLaunch = launch(
            durableStoreID: storeID,
            resetsBeforeOpen: false,
            skipsOnboarding: false
        )
        XCTAssertTrue(
            element(
                "onboarding.privacy.continue",
                in: coldLaunch
            ).waitForExistence(timeout: 20)
        )
        XCTAssertFalse(
            element(
                "dataReset.restartRequired",
                in: coldLaunch
            ).exists
        )
        coldLaunch.terminate()

        let verified = launch(
            arguments: ["-unmanual-archive"],
            durableStoreID: storeID,
            resetsBeforeOpen: false
        )
        openDataControl(in: verified)
        XCTAssertTrue(
            verified.staticTexts[
                "当前没有可逐项移除的记录"
            ].waitForExistence(timeout: 12)
        )
        XCTAssertFalse(
            element(
                "archive.dataControl.target.hrt-journey",
                in: verified
            ).exists
        )
        attachScreenshot(
            named: "DataControl-Reset-FreshStore"
        )
    }

    func testArchiveDataControlManifestFailureRetriesAtAccessibilityFive()
        throws
    {
        let storeID = UUID()
        defer { cleanupDurableStore(storeID) }
        let app = launch(
            arguments: [
                "-unmanual-archive",
                "-unmanual-ui-test-inventory-fail-once"
            ],
            maximumDynamicType: true,
            durableStoreID: storeID
        )
        openDataControl(in: app)

        let retry = app.buttons[
            "重新核对完整清单"
        ]
        XCTAssertTrue(retry.waitForExistence(timeout: 12))
        scrollToVisible(retry, in: app)
        XCTAssertTrue(retry.isHittable)
        retry.tap()

        let reset = element(
            "archive.dataControl.resetConfirm",
            in: app
        )
        XCTAssertTrue(reset.waitForExistence(timeout: 15))
        scrollToVisible(reset, in: app)
        XCTAssertTrue(reset.isHittable)
        try auditVisibleText(in: app)
        attachScreenshot(
            named: "DataControl-Accessibility5-Retry"
        )
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
        try app.performAccessibilityAudit(for: [
            .hitRegion,
            .sufficientElementDescription,
            .textClipped,
            .trait
        ])

        attachScreenshot(named: "SystemBackup-Countdown-Accessibility5")
    }

    func testCountdownCreateCancelArchiveDeleteAndReenterFlow() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["旅程"].waitForExistence(timeout: 5))
        app.buttons["旅程"].tap()

        let record = element("journey.record", in: app)
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        let countdownMenu = app.buttons.containing(
            .staticText,
            identifier: "倒计时"
        ).firstMatch
        XCTAssertTrue(countdownMenu.waitForExistence(timeout: 5))
        countdownMenu.tap()

        let create = element("countdown.ledger.create", in: app)
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        let title = element("countdown.title", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("取消项")
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertFalse(
            element("countdown.ledger.current", in: app).exists
        )

        create.tap()
        let savedTitle = element("countdown.title", in: app)
        XCTAssertTrue(savedTitle.waitForExistence(timeout: 5))
        savedTitle.tap()
        savedTitle.typeText("阶段目标")
        let save = element("countdown.save", in: app)
        XCTAssertTrue(save.isEnabled)
        save.tap()

        let current = element("countdown.ledger.current", in: app)
        XCTAssertTrue(current.waitForExistence(timeout: 8))
        XCTAssertTrue(current.label.contains("阶段目标"))
        current.tap()
        let archive = app.buttons["未完成，收进旅程"].firstMatch
        scrollToVisible(archive, in: app)
        XCTAssertTrue(archive.isHittable)
        archive.tap()
        let archiveConfirmation = app.sheets.buttons["收进旅程"]
        XCTAssertTrue(archiveConfirmation.waitForExistence(timeout: 3))
        archiveConfirmation.tap()

        XCTAssertTrue(create.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["阶段目标"].waitForExistence(timeout: 5))

        create.tap()
        let deleteTitle = element("countdown.title", in: app)
        XCTAssertTrue(deleteTitle.waitForExistence(timeout: 5))
        deleteTitle.tap()
        deleteTitle.typeText("临时目标")
        element("countdown.save", in: app).tap()
        XCTAssertTrue(current.waitForExistence(timeout: 8))
        current.tap()
        let replace = app.buttons[
            "删除并建立新的目标日"
        ].firstMatch
        scrollToVisible(replace, in: app)
        XCTAssertTrue(replace.isHittable)
        replace.tap()
        let replaceConfirmation =
            app.sheets.buttons["开始建立新目标"]
        XCTAssertTrue(replaceConfirmation.waitForExistence(timeout: 3))
        replaceConfirmation.tap()
        let replacementTitle = element("countdown.title", in: app)
        XCTAssertTrue(replacementTitle.waitForExistence(timeout: 5))
        XCTAssertNotEqual(replacementTitle.value as? String, "临时目标")
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(current.waitForExistence(timeout: 8))
        current.tap()
        let delete = app.buttons["删除当前倒计时"].firstMatch
        scrollToVisible(delete, in: app)
        XCTAssertTrue(delete.isHittable)
        delete.tap()
        let deleteConfirmation =
            app.sheets.buttons["删除当前倒计时"]
        XCTAssertTrue(deleteConfirmation.waitForExistence(timeout: 3))
        deleteConfirmation.tap()

        XCTAssertTrue(create.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["阶段目标"].exists)
        XCTAssertFalse(app.staticTexts["临时目标"].exists)
        attachScreenshot(named: "Countdown-Lifecycle-Archive-Delete")
    }

    func testDueCountdownCanContinueThenCompleteIntoHistory() throws {
        let app = launch(arguments: ["-unmanual-countdown-due"])
        XCTAssertTrue(app.buttons["旅程"].waitForExistence(timeout: 5))
        app.buttons["旅程"].tap()
        let record = element("journey.record", in: app)
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        let countdownMenu = app.buttons.containing(
            .staticText,
            identifier: "倒计时"
        ).firstMatch
        XCTAssertTrue(countdownMenu.waitForExistence(timeout: 5))
        countdownMenu.tap()

        let current = element("countdown.ledger.current", in: app)
        XCTAssertTrue(current.waitForExistence(timeout: 8))
        XCTAssertTrue(current.label.contains("到期测试"))
        current.tap()
        let continueButton = element("countdown.continue", in: app)
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        continueButton.tap()

        XCTAssertTrue(current.waitForExistence(timeout: 8))
        current.tap()
        let completeButton = element("countdown.complete", in: app)
        XCTAssertTrue(completeButton.waitForExistence(timeout: 5))
        completeButton.tap()

        let create = element("countdown.ledger.create", in: app)
        XCTAssertTrue(create.waitForExistence(timeout: 8))
        XCTAssertFalse(current.exists)
        XCTAssertTrue(app.staticTexts["到期测试"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["已经完成，已收进旅程"].exists
        )
        attachScreenshot(named: "Countdown-Lifecycle-Continue-Complete")
    }

    func testGentleModeHidesCountdownRawTitleFromLedgerAndEditorAccessibility()
        throws
    {
        let app = launch(arguments: ["-unmanual-countdown-due"])
        enableGentleMode(in: app)

        app.buttons["旅程"].tap()
        let record = element("journey.record", in: app)
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        let countdownMenu = app.buttons.containing(
            .staticText,
            identifier: "倒计时"
        ).firstMatch
        XCTAssertTrue(countdownMenu.waitForExistence(timeout: 5))
        countdownMenu.tap()

        let current = element("countdown.ledger.current", in: app)
        XCTAssertTrue(current.waitForExistence(timeout: 8))
        XCTAssertTrue(current.label.contains("私人日期"))
        XCTAssertFalse(current.label.contains("到期测试"))
        current.tap()

        XCTAssertTrue(
            element("countdown.gentleTitle", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(element("countdown.title", in: app).exists)
        XCTAssertFalse(app.staticTexts["到期测试"].exists)

        let replace = app.buttons[
            "删除并建立新的目标日"
        ].firstMatch
        scrollToVisible(replace, in: app)
        XCTAssertTrue(replace.isHittable)
        replace.tap()
        let confirmation =
            app.sheets.buttons["开始建立新目标"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.tap()

        XCTAssertTrue(
            element("countdown.gentleTitle", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(element("countdown.title", in: app).exists)
        XCTAssertFalse(app.staticTexts["到期测试"].exists)
    }

    func testGentleModeNewCountdownNeverExposesRawTitle() throws {
        let app = launch()
        enableGentleMode(in: app)

        app.buttons["旅程"].tap()
        let record = element("journey.record", in: app)
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        let countdownMenu = app.buttons.containing(
            .staticText,
            identifier: "倒计时"
        ).firstMatch
        XCTAssertTrue(countdownMenu.waitForExistence(timeout: 5))
        countdownMenu.tap()
        let create = element("countdown.ledger.create", in: app)
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()

        let gentleTitle = element(
            "countdown.gentleTitle",
            in: app
        )
        XCTAssertTrue(gentleTitle.waitForExistence(timeout: 5))
        XCTAssertFalse(element("countdown.title", in: app).exists)
        gentleTitle.tap()
        gentleTitle.typeText("私人里程碑")
        XCTAssertTrue(element("countdown.save", in: app).isEnabled)
    }

    func testArchiveGentleModeReadFailureIsVisibleAndNotEditable()
        throws
    {
        let app = launch(
            arguments: ["-unmanual-gentle-mode-read-error"]
        )
        app.buttons["档案"].tap()

        let error = element(
            "archive.gentleModeError",
            in: app
        )
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(
            error.label.contains(
                "温和模式状态没有通过完整性检查"
            )
        )
        let toggle = element(
            "archive.gentleMode.toggle",
            in: app
        )
        XCTAssertTrue(toggle.exists)
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertEqual(
            element(
                "archive.gentleMode.status",
                in: app
            ).label,
            "温和模式状态不可用"
        )
    }

    func testCountdownEditorReadFailureCannotBecomeBlankCreateOrSave()
        throws
    {
        let app = launch(
            arguments: [
                "-unmanual-countdown",
                "-unmanual-countdown-read-error"
            ]
        )
        let error = element("countdown.readError", in: app)
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(element("countdown.retryRead", in: app).exists)
        XCTAssertFalse(element("countdown.title", in: app).exists)
        XCTAssertFalse(element("countdown.save", in: app).isEnabled)

        element("countdown.retryRead", in: app).tap()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
    }

    func testTodayCountdownReadFailureIsVisibleAndClearsContent()
        throws
    {
        let app = launch(
            arguments: ["-unmanual-countdown-read-error"]
        )
        let error = element("today.contentReadError", in: app)
        XCTAssertTrue(error.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["重新读取"].exists)
        XCTAssertFalse(element("today.v25.addStartDate", in: app).exists)
        XCTAssertFalse(element("today.v25.quickRecord", in: app).exists)
    }

    func testArchiveSnapshotReadFailureHidesFactsAndExportActions()
        throws
    {
        let app = launch(
            arguments: ["-unmanual-archive-read-error"]
        )
        app.buttons["档案"].tap()

        let error = element("archive.readError", in: app)
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(element("archive.retryRead", in: app).exists)
        XCTAssertFalse(app.staticTexts["从第一笔开始"].exists)
        XCTAssertFalse(app.staticTexts["整理就诊材料"].exists)
    }

    func testCountdownSaveFailureStaysOnPageAndPreventsDuplicateSubmission()
        throws
    {
        let app = launch(arguments: ["-unmanual-countdown"])
        let title = element("countdown.title", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText(String(repeating: "a", count: 121))
        let save = element("countdown.save", in: app)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        if save.isHittable {
            save.tap()
        }

        let alert = app.alerts["没有保存"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 1)
        XCTAssertTrue(
            alert.staticTexts[
                "倒计时仍在当前页面。请检查日期和提醒时间后再保存。"
            ].exists
        )
        alert.buttons["返回检查"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertEqual(title.value as? String, String(repeating: "a", count: 121))
    }

    private func launch(
        arguments: [String] = [],
        maximumDynamicType: Bool = false,
        durableStoreID: UUID? = nil,
        resetsBeforeOpen: Bool = true,
        skipsOnboarding: Bool = true
    ) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        if let durableStoreID {
            app.launchArguments = [
                "-unmanual-ui-test-store-id",
                durableStoreID.uuidString
            ]
            if resetsBeforeOpen {
                app.launchArguments.append(
                    "-unmanual-ui-test-reset-store"
                )
            }
            if skipsOnboarding {
                app.launchArguments.append(
                    "-unmanual-skip-onboarding"
                )
            }
            app.launchArguments += arguments
        } else {
            app.launchArguments = ["-unmanual-empty-store"]
            if skipsOnboarding {
                app.launchArguments.append(
                    "-unmanual-skip-onboarding"
                )
            }
            app.launchArguments += arguments
        }
        if maximumDynamicType {
            app.launchArguments.append("-unmanual-ui-test-accessibility5")
        }
        app.launch()
        return app
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
        _ = cleanup.descendants(matching: .any)["app.shell"]
            .waitForExistence(timeout: 8)
        cleanup.terminate()
    }

    private func openDataControl(
        in app: XCUIApplication
    ) {
        let entry = element(
            "archive.deleteAndReset",
            in: app
        )
        XCTAssertTrue(entry.waitForExistence(timeout: 12))
        scrollToVisible(entry, in: app)
        XCTAssertTrue(entry.isHittable)
        entry.tap()
        XCTAssertTrue(
            element(
                "archive.dataControl.resetBoundary",
                in: app
            ).waitForExistence(timeout: 15)
        )
    }

    private func enableGentleMode(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["档案"].waitForExistence(timeout: 5))
        app.buttons["档案"].tap()
        let toggle = element(
            "archive.gentleMode.toggle",
            in: app
        )
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        scrollToFullyVisible(toggle, in: app)
        XCTAssertTrue(isFullyVisible(toggle, in: app))
        toggle.tap()
        let status = element(
            "archive.gentleMode.status",
            in: app
        )
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let enabledStatus = NSPredicate(
            format: "label == %@",
            "温和模式已开启"
        )
        let expectation = XCTNSPredicateExpectation(
            predicate: enabledStatus,
            object: status
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [expectation],
                timeout: 5
            ),
            .completed
        )
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
