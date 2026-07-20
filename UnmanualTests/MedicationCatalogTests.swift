import XCTest
@testable import Unmanual

final class MedicationCatalogTests: XCTestCase {
    func testEmptySearchReturnsTheCatalogOrder() {
        XCTAssertEqual(
            MedicationCatalog.search("").map(\.id),
            MedicationCatalog.entries.map(\.id)
        )
    }

    func testSearchMatchesEnglishNameCaseInsensitively() {
        XCTAssertEqual(
            MedicationCatalog.search("SPIRONOLACTONE").map(\.id),
            ["spironolactone"]
        )
    }

    func testSearchMatchesChineseAlias() {
        XCTAssertEqual(
            MedicationCatalog.search("补佳乐").map(\.id),
            ["estradiol-valerate"]
        )
    }

    func testUnknownSearchReturnsNoApproximateEntry() {
        XCTAssertTrue(MedicationCatalog.search("unknown-entry").isEmpty)
    }

    func testEveryProductPointsToARouteOnItsIngredient() {
        for entry in MedicationCatalog.entries {
            let routeIDs = Set(entry.routes.map(\.id))
            XCTAssertTrue(
                entry.products.allSatisfy { routeIDs.contains($0.routeID) },
                "\(entry.id) contains a product with an unknown route"
            )
        }
    }

    func testPreciseProductDraftUsesProductIdentifierAndMetadata() throws {
        let entry = try XCTUnwrap(MedicationCatalog.entries.first { $0.id == "estradiol" })
        let product = try XCTUnwrap(entry.products.first { $0.id == "estradiol-patch-placeholder" })

        let draft = entry.draft(for: product)

        XCTAssertEqual(draft.catalogID, product.id)
        XCTAssertEqual(draft.name, product.displayName)
        XCTAssertTrue(draft.detail.contains(product.routeTitle))
        XCTAssertTrue(draft.detail.contains(product.manufacturer))
    }
}
