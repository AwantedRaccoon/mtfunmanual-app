import XCTest

@MainActor
final class PocketAppendixUITests: XCTestCase {
    func testSearchFavoriteReadBoundaryAndReentry()
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
            "-unmanual-archive"
        ]
        app.launch()

        openPocketAppendix(in: app)
        let directory = element(
            "pocketAppendix.directory",
            in: app
        )
        XCTAssertTrue(
            directory.waitForExistence(timeout: 12)
        )

        let favoriteCardID =
            "card.identity-childhood-required-001"
        let favorite = element(
            "pocketAppendix.favorite.\(favoriteCardID)",
            in: app
        )
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        XCTAssertTrue(favorite.isHittable)
        favorite.tap()
        XCTAssertTrue(
            element(
                "pocketAppendix.favoriteFeedback",
                in: app
            ).waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            favorite.value as? String,
            "已收藏"
        )

        let search = app.searchFields[
            "搜索离线摘要"
        ]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("验血")
        search.typeText("\n")

        let readerCardID = "card.hrt-monitoring-005"
        let card = element(
            "pocketAppendix.card.\(readerCardID)",
            in: app
        )
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        scrollUpToHittable(card, in: app)
        card.tap()
        XCTAssertTrue(
            element(
                "pocketAppendix.reader.status",
                in: app
            ).waitForExistence(timeout: 5)
        )
        let original = element(
            "pocketAppendix.reader.original",
            in: app
        )
        scrollUpToHittable(original, in: app)
        original.tap()
        XCTAssertTrue(
            element(
                "externalBoundary.sheet",
                in: app
            ).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["github.com"]
                .waitForExistence(timeout: 5)
        )
        let cancelBoundary =
            app.buttons["取消"].firstMatch
        XCTAssertTrue(
            cancelBoundary.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(cancelBoundary.isHittable)
        cancelBoundary.tap()

        let attribution = element(
            "pocketAppendix.reader.attribution",
            in: app
        )
        scrollUpToHittable(attribution, in: app)
        attribution.tap()
        XCTAssertTrue(
            element(
                "pocketAppendix.attribution.page",
                in: app
            ).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts[
                "https://github.com/AwantedRaccoon/MTF-Unmanual"
            ].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts[
                "https://creativecommons.org/licenses/by-sa/4.0/"
            ].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["已摘编"]
                .waitForExistence(timeout: 5)
        )
        let attributionBack =
            app.navigationBars["来源与许可"]
            .buttons.firstMatch
        XCTAssertTrue(
            attributionBack.waitForExistence(timeout: 5)
        )
        attributionBack.tap()

        let back =
            app.navigationBars["离线摘要"]
            .buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        let returnedSummary = element(
            "pocketAppendix.resultSummary",
            in: app
        )
        XCTAssertTrue(
            returnedSummary.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            returnedSummary.label.contains("1 项")
        )
        let close = app.buttons[
            "pocketAppendix.close"
        ].firstMatch
        XCTAssertTrue(
            close.waitForExistence(timeout: 5),
            app.debugDescription
        )
        close.tap()

        openPocketAppendix(in: app)
        XCTAssertTrue(
            directory.waitForExistence(timeout: 8)
        )
        let reopenedSearch = app.searchFields[
            "搜索离线摘要"
        ]
        XCTAssertTrue(
            reopenedSearch.waitForExistence(timeout: 5)
        )
        XCTAssertNotEqual(
            reopenedSearch.value as? String,
            "验血"
        )
        let persistedFavorite = element(
            "pocketAppendix.favorite.\(favoriteCardID)",
            in: app
        )
        XCTAssertTrue(
            persistedFavorite.waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            persistedFavorite.value as? String,
            "已收藏"
        )
        persistedFavorite.tap()
        XCTAssertEqual(
            persistedFavorite.value as? String,
            "未收藏"
        )
    }

    private func openPocketAppendix(
        in app: XCUIApplication
    ) {
        let entry = element(
            "archive.supplement.pocketAppendix",
            in: app
        )
        XCTAssertTrue(entry.waitForExistence(timeout: 12))
        scrollUpToHittable(entry, in: app)
        entry.tap()
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
        _ = cleanup.descendants(
            matching: .any
        )["app.shell"].waitForExistence(timeout: 8)
        cleanup.terminate()
    }

    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(
            matching: .any
        )[identifier]
    }

    private func scrollUpToHittable(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        for _ in 0..<14 where
            !element.exists || !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(
            element.exists,
            "Expected \(element.identifier) to exist."
        )
        XCTAssertTrue(
            element.isHittable,
            "Expected \(element.identifier) to be hittable; frame=\(element.frame)."
        )
    }
}
