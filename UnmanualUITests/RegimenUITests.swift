import XCTest

@MainActor
final class RegimenUITests: XCTestCase {
    func testRegimenAnalysisStopsUntilTransientBoundariesAreAnswered() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-empty-store",
            "-unmanual-skip-onboarding",
            "-unmanual-regimen-analysis"
        ]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["analysis.summary"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["analysis.unanswered"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.descendants(matching: .any)["analysis.stop"].exists)
        XCTAssertEqual(
            app.buttons["analysis.age.unknown"].value as? String,
            "未选择"
        )
        XCTAssertEqual(
            app.buttons["analysis.acute.unknown"].value as? String,
            "未选择"
        )

        app.buttons["analysis.age.unknown"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["analysis.stop"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["analysis.unanswered"].exists
        )
        app.buttons["analysis.age.adult"].tap()
        app.buttons["analysis.pregnancy.notApplicable"].tap()
        app.buttons["analysis.acute.no"].tap()
        if !app.buttons["analysis.vte.no"].isHittable {
            app.swipeUp()
        }
        app.buttons["analysis.vte.no"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["analysis.ready"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.descendants(matching: .any)["analysis.stop"].exists)

        let source = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "analysis.source."
            )
        ).firstMatch
        for _ in 0..<8 where !source.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(source.isHittable)
        source.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["analysis.externalBoundary"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "不包含你的方案"
                )
            ).firstMatch.exists
        )
        app.buttons["analysis.external.cancel"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["analysis.provenance"]
                .waitForExistence(timeout: 5)
        )
    }

    func testRegimenAnalysisAcuteConcernSuppressesDrugSpecificCards() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-empty-store",
            "-unmanual-skip-onboarding",
            "-unmanual-regimen-analysis"
        ]
        app.launch()

        XCTAssertTrue(
            app.buttons["analysis.acute.yes"].waitForExistence(timeout: 8)
        )
        app.buttons["analysis.acute.yes"].tap()

        let stop = app.descendants(matching: .any)["analysis.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertTrue(stop.label.contains("及时寻求医疗帮助"))
        XCTAssertFalse(
            app.descendants(matching: .any)["analysis.monitoring"].exists
        )
    }

    func testRegimenAnalysisUsesRealCurrentAndSeparateHistoricalEntries()
        throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-empty-store",
            "-unmanual-skip-onboarding",
            "-unmanual-regimen-analysis-fixture"
        ]
        app.launch()

        let regimenTab = app.buttons["方案"]
        XCTAssertTrue(regimenTab.waitForExistence(timeout: 12))
        regimenTab.tap()

        let currentAnalysis = app.buttons["regimen.analysis"]
        XCTAssertTrue(currentAnalysis.waitForExistence(timeout: 12))
        currentAnalysis.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["analysis.summary"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["analysis.historyContext"]
                .exists
        )
        let acuteYes = app.buttons["analysis.acute.yes"]
        scrollToHittable(acuteYes, in: app)
        acuteYes.tap()
        XCTAssertEqual(acuteYes.value as? String, "已选择")
        app.buttons["analysis.close"].tap()

        XCTAssertTrue(currentAnalysis.waitForExistence(timeout: 8))
        currentAnalysis.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["analysis.summary"]
                .waitForExistence(timeout: 8)
        )
        let reopenedAcuteYes = app.buttons["analysis.acute.yes"]
        let reopenedAcuteUnknown = app.buttons["analysis.acute.unknown"]
        XCTAssertTrue(reopenedAcuteYes.waitForExistence(timeout: 5))
        XCTAssertEqual(reopenedAcuteYes.value as? String, "未选择")
        XCTAssertEqual(reopenedAcuteUnknown.value as? String, "未选择")
        let reopenedStatuses = app.descendants(matching: .any)
            .matching(identifier: "analysis.semanticStatus")
        let reopenedStatus = reopenedStatuses.firstMatch
        XCTAssertTrue(reopenedStatus.waitForExistence(timeout: 5))
        let statusValues = (0..<reopenedStatuses.count).map {
            reopenedStatuses.element(boundBy: $0).value as? String
        }
        XCTAssertEqual(
            reopenedStatuses.count,
            1,
            "status values: \(statusValues)"
        )
        XCTAssertEqual(
            reopenedStatus.value as? String,
            "unanswered",
            "status values: \(statusValues)"
        )
        app.buttons["analysis.close"].tap()

        let historyNotice = app.descendants(matching: .any)[
            "regimen.analysis.historyNotice"
        ]
        scrollToHittable(historyNotice, in: app)
        XCTAssertTrue(historyNotice.isHittable)
        XCTAssertTrue(
            historyNotice.label.contains("当前规则包重新整理")
        )

        let historicalIDs = [
            "99000000-0000-0000-0000-000000000001",
            "99000000-0000-0000-0000-000000000002"
        ]
        for historicalID in historicalIDs {
            let button = app.buttons[
                "regimen.analysis.history.\(historicalID)"
            ]
            scrollToHittable(button, in: app)
            XCTAssertTrue(button.isHittable)
            button.tap()
            let context = app.descendants(matching: .any)[
                "analysis.historyContext"
            ]
            XCTAssertTrue(
                context.waitForExistence(timeout: 8),
                app.debugDescription
            )
            XCTAssertTrue(
                context.label.contains(
                    "不是永久保存的历史分析结论"
                )
            )
            app.buttons["analysis.close"].tap()
        }
    }

    func testRegimenAnalysisUnavailableStateUsesRealRegimenEntry() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-empty-store",
            "-unmanual-skip-onboarding",
            "-unmanual-regimen-analysis-fixture",
            "-unmanual-regimen-analysis-unavailable"
        ]
        app.launch()

        let regimenTab = app.buttons["方案"]
        XCTAssertTrue(regimenTab.waitForExistence(timeout: 12))
        regimenTab.tap()
        let currentAnalysis = app.buttons["regimen.analysis"]
        XCTAssertTrue(currentAnalysis.waitForExistence(timeout: 12))
        currentAnalysis.tap()

        let unavailable = app.descendants(matching: .any)[
            "analysis.unavailable"
        ]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 8))
        XCTAssertTrue(
            unavailable.label.contains("分析内容资源缺失")
        )
        app.buttons["analysis.close"].tap()
        XCTAssertTrue(currentAnalysis.waitForExistence(timeout: 8))
    }

    func testMedicationCatalogSearchAndSelectsVersionedPresentation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-empty-store",
            "-unmanual-skip-onboarding",
            "-unmanual-medication-picker"
        ]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["medication.catalog.provenance"]
                .waitForExistence(timeout: 8)
        )
        let search = app.textFields["medication.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("SPIRONOLACTONE")

        let ingredient = app.buttons["medication.catalog.spironolactone"]
        XCTAssertTrue(ingredient.waitForExistence(timeout: 5))
        ingredient.tap()

        let oralRoute = app.buttons["medication.route.oral"]
        XCTAssertTrue(oralRoute.waitForExistence(timeout: 5))
        XCTAssertEqual(oralRoute.value as? String, "已选择")

        let presentation = app.buttons[
            "medication.product.record.spironolactone.oral-tablet"
        ]
        XCTAssertTrue(presentation.waitForExistence(timeout: 5))
        presentation.tap()

        let add = app.buttons["medication.product.add"]
        XCTAssertTrue(add.isEnabled)
        add.tap()
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testMedicationCatalogNoMatchKeepsCustomOriginalEntryPath() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-empty-store",
            "-unmanual-skip-onboarding",
            "-unmanual-medication-picker"
        ]
        app.launch()

        let search = app.textFields["medication.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("my original label")
        let noResults = app.descendants(matching: .any)["medication.noResults.title"]
        XCTAssertTrue(noResults.waitForExistence(timeout: 5))
        XCTAssertTrue(noResults.label.contains("my original label"))

        app.buttons["medication.custom"].tap()
        let name = app.textFields["medication.custom.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "my original label")
        XCTAssertTrue(app.buttons["medication.custom.add"].isEnabled)
    }

    func testIngredientWithoutCompleteProductFactsUsesLabelBasedCustomPath() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-empty-store",
            "-unmanual-skip-onboarding",
            "-unmanual-medication-picker"
        ]
        app.launch()

        let search = app.textFields["medication.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("ESTETROL")

        let ingredient = app.buttons["medication.catalog.estetrol"]
        XCTAssertTrue(ingredient.waitForExistence(timeout: 5))
        ingredient.tap()

        let name = app.textFields["medication.custom.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "雌四醇")
        XCTAssertTrue(app.buttons["medication.custom.add"].isEnabled)
        XCTAssertFalse(app.buttons["medication.route.oral"].exists)
    }

    func testScheduleEditorSavesAPlanWithoutRequestingNotificationPermission() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-empty-store",
            "-unmanual-skip-onboarding",
            "-unmanual-regimen-editor"
        ]
        app.launch()

        let schedule = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "regimen.schedule.")
        ).firstMatch
        XCTAssertTrue(schedule.waitForExistence(timeout: 8))
        schedule.tap()

        let times = app.textFields["regimen.schedule.times"]
        XCTAssertTrue(times.waitForExistence(timeout: 5))
        XCTAssertEqual(times.value as? String, "08:00")
        app.buttons["regimen.schedule.save"].tap()

        XCTAssertTrue(app.staticTexts["每天 · 08:00"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testDraftPreviewCancelAndSealFlow() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-unmanual-empty-store",
            "-unmanual-skip-onboarding",
            "-unmanual-regimen-editor"
        ]
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

    private func scrollToHittable(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        for _ in 0..<12 where !element.isHittable {
            app.swipeUp()
        }
    }
}
