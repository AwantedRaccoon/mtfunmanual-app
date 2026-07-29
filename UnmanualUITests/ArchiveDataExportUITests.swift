import XCTest

@MainActor
final class ArchiveDataExportUITests: XCTestCase {
    func testVisitSummaryBuildModifyAndReenterFlow()
        throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let storeID = UUID()
        defer { cleanupDurableStore(storeID) }

        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-ui-test-store-id",
            storeID.uuidString,
            "-unmanual-ui-test-reset-store",
            "-unmanual-skip-onboarding",
            "-unmanual-ui-test-initial-archive",
            "-unmanual-hrt-active-fixture"
        ]
        app.launch()

        let entry = app.staticTexts[
            "整理就诊材料"
        ]
        XCTAssertTrue(entry.waitForExistence(timeout: 12))
        scrollUpToHittable(entry, in: app)
        entry.tap()

        let build = app.descendants(matching: .any)[
            "archive.visitSummary.build"
        ]
        XCTAssertTrue(build.waitForExistence(timeout: 5))
        scrollDownToHittable(build, in: app)
        build.tap()

        let preview = app.descendants(
            matching: .any
        )["archive.visitSummary.preview"]
        XCTAssertTrue(
            preview.waitForExistence(timeout: 20)
        )
        let modify = app.descendants(matching: .any)[
            "archive.visitSummary.modify"
        ]
        XCTAssertTrue(
            modify.waitForExistence(timeout: 5)
        )
        scrollDownToHittable(modify, in: app)
        modify.tap()
        XCTAssertTrue(build.waitForExistence(timeout: 5))

        build.tap()
        XCTAssertTrue(
            preview.waitForExistence(timeout: 20)
        )
        let cancel = app.buttons["取消"]
        scrollDownToHittable(cancel, in: app)
        cancel.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))

        entry.tap()
        XCTAssertTrue(build.waitForExistence(timeout: 5))
    }

    func testReadableAndCompleteBackupRequirePreview()
        throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let storeID = UUID()
        defer { cleanupDurableStore(storeID) }

        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-ui-test-store-id",
            storeID.uuidString,
            "-unmanual-ui-test-reset-store",
            "-unmanual-skip-onboarding",
            "-unmanual-ui-test-initial-archive"
        ]
        app.launch()

        let entry = app.descendants(matching: .any)[
            "archive.export.data"
        ]
        XCTAssertTrue(entry.waitForExistence(timeout: 12))
        scrollUpToHittable(entry, in: app)
        entry.tap()

        XCTAssertTrue(
            app.staticTexts["数据副本预览"]
                .waitForExistence(timeout: 5)
        )
        let prepare = app.descendants(matching: .any)[
            "archive.export.prepare"
        ]
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.descendants(matching: .any)[
                "archive.export.confirm"
            ].exists
        )
        prepare.tap()

        let preview = app.descendants(matching: .any)[
            "archive.export.preview"
        ]
        XCTAssertTrue(preview.waitForExistence(timeout: 20))
        XCTAssertTrue(
            preview.label.contains("Readable JSON v2")
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "archive.export.confirm"
            ].waitForExistence(timeout: 5)
        )

        let completeBackup = app.descendants(
            matching: .any
        )["archive.export.kind.completeBackup"]
        XCTAssertTrue(
            completeBackup.waitForExistence(timeout: 5)
        )
        scrollDownToHittable(completeBackup, in: app)
        completeBackup.tap()
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        prepare.tap()

        XCTAssertTrue(preview.waitForExistence(timeout: 30))
        XCTAssertTrue(
            preview.label.contains("完整备份")
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "archive.export.confirm"
            ].waitForExistence(timeout: 5)
        )

        let cancel = app.buttons["取消"]
        scrollDownToHittable(cancel, in: app)
        cancel.tap()
        XCTAssertTrue(
            entry.waitForExistence(timeout: 5)
        )
    }

    func testExportConfirmationRejectsChangedStateBeforeFiles()
        throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let storeID = UUID()
        defer { cleanupDurableStore(storeID) }

        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-ui-test-store-id",
            storeID.uuidString,
            "-unmanual-ui-test-reset-store",
            "-unmanual-skip-onboarding",
            "-unmanual-ui-test-initial-archive",
            "-unmanual-ui-test-export-confirmation-state-changed"
        ]
        app.launch()

        let entry = app.descendants(matching: .any)[
            "archive.export.data"
        ]
        XCTAssertTrue(entry.waitForExistence(timeout: 12))
        scrollUpToHittable(entry, in: app)
        entry.tap()
        let prepare = app.descendants(matching: .any)[
            "archive.export.prepare"
        ]
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        prepare.tap()
        let confirm = app.descendants(matching: .any)[
            "archive.export.confirm"
        ]
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 20)
        )
        confirm.tap()

        XCTAssertTrue(
            app.staticTexts[
                "预览后本地资料发生了变化；没有打开 Files，请重新生成并核对。"
            ].waitForExistence(timeout: 10)
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[
                "archive.export.preview"
            ].exists
        )
        XCTAssertTrue(
            prepare.waitForExistence(timeout: 5)
        )
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
        _ = cleanup.descendants(matching: .any)[
            "app.shell"
        ].waitForExistence(timeout: 8)
        cleanup.terminate()
    }

    private func scrollUpToHittable(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        for _ in 0..<8 where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    private func scrollDownToHittable(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        for _ in 0..<8 where !element.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(element.isHittable)
    }
}
