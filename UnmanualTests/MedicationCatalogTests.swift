import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import Unmanual

@MainActor
final class MedicationCatalogTests: XCTestCase {
    func testBundledCandidatePackPassesCandidateContract() throws {
        let pack = try candidatePack()

        XCTAssertEqual(pack.ingredients.count, 33)
        XCTAssertEqual(pack.products.count, 31)
        XCTAssertEqual(pack.presentations.count, 44)
        XCTAssertEqual(pack.manifest.review.status, .candidate)
        XCTAssertEqual(
            MedicationCatalogValidator.issues(in: pack, exposure: .candidate),
            []
        )
    }

    func testCandidatePresentationsStayExplicitlyUnverifiedAndRoutesKeepDosageFormSeparate()
        throws {
        let pack = try candidatePack()

        XCTAssertTrue(
            pack.presentations.allSatisfy {
                $0.evidenceStatus == .candidateUnverified
            }
        )
        let leuprolide = try XCTUnwrap(
            pack.presentations.first {
                $0.id == "record.leuprolide-acetate.subcutaneous-depot"
            }
        )
        XCTAssertEqual(leuprolide.authorizedRoutes, [.subcutaneous])
        XCTAssertEqual(leuprolide.dosageForm, "缓释注射剂")

        let histrelin = try XCTUnwrap(
            pack.presentations.first {
                $0.id == "record.histrelin-acetate.implant"
            }
        )
        XCTAssertEqual(histrelin.authorizedRoutes, [.subcutaneous])
        XCTAssertEqual(histrelin.dosageForm, "植入剂")

        let goserelin = try XCTUnwrap(
            pack.presentations.first {
                $0.id == "record.goserelin-acetate.implant"
            }
        )
        XCTAssertEqual(goserelin.authorizedRoutes, [.subcutaneous])
        XCTAssertEqual(goserelin.dosageForm, "植入剂")
    }

    func testEmptySearchReturnsTieredCatalogOrder() {
        let entries = MedicationCatalog.search("")

        XCTAssertEqual(entries, MedicationCatalog.entries)
        XCTAssertEqual(entries.first?.tier, .common)
        XCTAssertEqual(entries.last?.tier, .historical)
        XCTAssertEqual(entries.count, 33)
    }

    func testSearchMatchesEnglishNameCaseInsensitively() {
        XCTAssertEqual(
            MedicationCatalog.search("SPIRONOLACTONE").map(\.id),
            ["spironolactone"]
        )
    }

    func testSearchMatchesReviewedAlias() {
        XCTAssertEqual(
            MedicationCatalog.search("leuprorelin acetate").map(\.id),
            ["leuprolide-acetate"]
        )
    }

    func testSearchMatchesRxCUI() {
        XCTAssertEqual(
            MedicationCatalog.search("1294622").map(\.id),
            ["histrelin-acetate"]
        )
    }

    func testSearchMatchesPresentationNameAndCombinationAliases() {
        XCTAssertEqual(
            MedicationCatalog.search("鼻喷").map(\.id),
            ["buserelin-acetate", "nafarelin-acetate"]
        )
        XCTAssertEqual(
            MedicationCatalog.search("norethisterone").map(\.id),
            ["norethindrone-acetate"]
        )
    }

    func testUnknownSearchReturnsNoApproximateEntry() {
        XCTAssertTrue(MedicationCatalog.search("unknown-entry").isEmpty)
    }

    func testEveryPresentationRouteAppearsOnItsIngredientEntry() {
        for entry in MedicationCatalog.entries {
            let routeIDs = Set(entry.routes.map(\.id))
            XCTAssertTrue(
                entry.products.allSatisfy {
                    !$0.routeIDs.isEmpty && Set($0.routeIDs).isSubset(of: routeIDs)
                },
                "\(entry.id) contains a presentation with an unknown route"
            )
        }
    }

    func testMultipleRolesAndParentActiveMoietyArePreserved() throws {
        let cyproterone = try XCTUnwrap(
            MedicationCatalog.entries.first { $0.id == "cyproterone-acetate" }
        )
        XCTAssertEqual(
            cyproterone.roles,
            [.androgenSuppressing, .progestogen]
        )

        let pack = try candidatePack()
        let valerate = try XCTUnwrap(
            pack.ingredients.first { $0.id == "estradiol-valerate" }
        )
        XCTAssertEqual(valerate.parentActiveMoietyID, "estradiol")
        XCTAssertEqual(valerate.substanceForm, .ester)
        let cyproteroneIngredient = try XCTUnwrap(
            pack.ingredients.first { $0.id == "cyproterone-acetate" }
        )
        XCTAssertEqual(cyproteroneIngredient.activeMoietyName, "cyproterone")
    }

    func testPreciseProductDraftFreezesCatalogVersionAndMetadata() throws {
        let entry = try XCTUnwrap(
            MedicationCatalog.entries.first { $0.id == "estradiol" }
        )
        let product = try XCTUnwrap(
            entry.products.first { $0.id == "record.estradiol.transdermal-patch" }
        )

        let draft = entry.draft(for: product)

        XCTAssertEqual(draft.catalogID, product.id)
        XCTAssertEqual(draft.catalogVersion, entry.catalogVersion)
        XCTAssertEqual(draft.name, product.displayName)
        XCTAssertTrue(draft.detail.contains(product.routeTitle))
        XCTAssertTrue(draft.detail.contains(product.region))
        let snapshot = try XCTUnwrap(
            MedicationCatalogSelectionSnapshotV1.decode(draft.productSnapshot)
        )
        XCTAssertEqual(snapshot.catalogVersion, entry.catalogVersion)
        XCTAssertEqual(snapshot.presentationID, product.id)
        XCTAssertEqual(snapshot.productID, product.productID)
        XCTAssertEqual(snapshot.displayNameZH, product.displayName)
        XCTAssertEqual(snapshot.displayNameEN, product.englishDisplayName)
        XCTAssertEqual(snapshot.ingredients.map(\.id), ["estradiol"])
        XCTAssertEqual(snapshot.routes, ["transdermal"])
        XCTAssertEqual(snapshot.region, product.region)
        XCTAssertEqual(snapshot.regulator, product.regulator)
        XCTAssertEqual(snapshot.sources.map(\.id), product.sourceRecords.map(\.id))
        XCTAssertEqual(snapshot.boundaryNote, product.boundaryNote)
        XCTAssertEqual(snapshot.packageOrDevice, "贴剂")
        XCTAssertNil(snapshot.holderOrManufacturer)
    }

    func testCandidatePackIsFailClosedForRelease() throws {
        let repository = MedicationCatalogRepository(
            data: try candidateData(),
            exposure: .release
        )

        XCTAssertEqual(
            repository.state,
            .unavailable(.pendingHumanReview)
        )
    }

    func testApprovedCandidateStillCannotPassReleaseWithoutProductFacts() throws {
        let approved = try packWithReview(
            status: .approved,
            reviewer: "Human content reviewer",
            completedAt: "2026-07-30"
        )

        XCTAssertTrue(
            MedicationCatalogValidator.issues(in: approved, exposure: .release)
                .contains { $0.code == "product-not-release-eligible" }
        )
        XCTAssertTrue(
            MedicationCatalogValidator.issues(in: approved, exposure: .release)
                .contains { $0.code == "presentation-not-release-verified" }
        )
    }

    func testMinimalReviewedRegulatoryProductCanPassReleaseGate() throws {
        let base = try candidatePack()
        let originalSource = base.sources[0]
        let source = MedicationCatalogSource(
            id: "test-regulatory-source",
            institution: "Test regulator",
            title: "Test product register",
            versionOrPublishedAt: "2026-07-30",
            url: originalSource.url,
            retrievedAt: "2026-07-30",
            region: "Test jurisdiction",
            jurisdictionCodes: ["TEST"],
            authorityCodes: ["TEST"],
            licenseIdentifier: originalSource.licenseIdentifier,
            licenseURL: originalSource.licenseURL,
            redistribution: originalSource.redistribution,
            evidenceKinds: [.regulatoryProductRecord],
            proves: "Test product authorization facts",
            boundary: "Test fixture only"
        )
        let ingredient = MedicationIngredient(
            id: "release-fixture",
            preferredNameZH: "正式 fixture",
            preferredNameEN: "Release fixture",
            exactSubstanceName: "release fixture",
            aliases: [],
            parentActiveMoietyID: nil,
            activeMoietyName: nil,
            substanceForm: .activeMoiety,
            roles: [.historicalRecord],
            tier: .recordOnly,
            externalIdentifiers: [],
            sourceIDs: [source.id],
            boundaryNote: "Test fixture only"
        )
        let product = MedicationProduct(
            id: "release-fixture.product",
            displayNameZH: "正式产品 fixture",
            displayNameEN: "Release product fixture",
            aliases: [],
            region: "test",
            jurisdictionCode: "TEST",
            regulator: "test regulator",
            regulatorCode: "TEST",
            regulatoryStatus: .marketed,
            authorizationIdentifier: "TEST-AUTH-001",
            holderOrManufacturer: "Test holder",
            ingredientLinks: [
                MedicationProductIngredient(
                    ingredientID: ingredient.id,
                    labelStrengthOriginal: nil,
                    activeMoietyBasis: nil,
                    sortOrder: 0
                )
            ],
            sourceIDs: [source.id],
            regulatorySourceIDs: [source.id],
            boundaryNote: "Test fixture only"
        )
        let presentation = MedicationPresentation(
            id: "release-fixture.product.oral",
            productID: product.id,
            displayNameZH: "正式 presentation fixture",
            displayNameEN: "Release presentation fixture",
            dosageForm: "test",
            authorizedRoutes: [.oral],
            evidenceStatus: .regulatoryVerified,
            releasePattern: nil,
            packageOrDevice: nil,
            preciseIngredientForms: nil,
            sourceIDs: [source.id]
        )
        let pack = withCurrentDigest(
            MedicationCatalogPack(
                manifest: MedicationCatalogManifest(
                    schemaVersion: "1",
                    catalogVersion: "medication-catalog-2026.07.30-release.1",
                    generatedAt: "2026-07-30",
                    coverageStatement: "Test fixture only",
                    supportedRegions: ["test"],
                    contentDigest: "",
                    review: MedicationCatalogReview(
                        status: .approved,
                        ownerRole: "test",
                        reviewerDisplayName: "Human reviewer",
                        completedAt: "2026-07-30",
                        scope: "Test fixture only"
                    )
                ),
                sources: [source],
                ingredients: [ingredient],
                products: [product],
                presentations: [presentation]
            )
        )

        XCTAssertEqual(
            MedicationCatalogValidator.issues(in: pack, exposure: .release),
            []
        )
    }

    func testTerminologyOrWrongJurisdictionSourceCannotProveRegulatoryStatus() throws {
        let accepted = try minimalReleasePack()
        let original = accepted.sources[0]
        let terminologyOnly = MedicationCatalogSource(
            id: original.id,
            institution: original.institution,
            title: original.title,
            versionOrPublishedAt: original.versionOrPublishedAt,
            url: original.url,
            retrievedAt: original.retrievedAt,
            region: original.region,
            jurisdictionCodes: original.jurisdictionCodes,
            authorityCodes: original.authorityCodes,
            licenseIdentifier: original.licenseIdentifier,
            licenseURL: original.licenseURL,
            redistribution: original.redistribution,
            evidenceKinds: [.terminologyIdentity],
            proves: original.proves,
            boundary: original.boundary
        )
        let terminologyPack = withCurrentDigest(
            MedicationCatalogPack(
                manifest: accepted.manifest,
                sources: [terminologyOnly],
                ingredients: accepted.ingredients,
                products: accepted.products,
                presentations: accepted.presentations
            )
        )
        XCTAssertTrue(
            MedicationCatalogValidator.issues(
                in: terminologyPack,
                exposure: .release
            ).contains { $0.code == "source-does-not-prove-regulatory-fact" }
        )

        let wrongJurisdiction = MedicationCatalogSource(
            id: original.id,
            institution: original.institution,
            title: original.title,
            versionOrPublishedAt: original.versionOrPublishedAt,
            url: original.url,
            retrievedAt: original.retrievedAt,
            region: original.region,
            jurisdictionCodes: ["OTHER"],
            authorityCodes: original.authorityCodes,
            licenseIdentifier: original.licenseIdentifier,
            licenseURL: original.licenseURL,
            redistribution: original.redistribution,
            evidenceKinds: original.evidenceKinds,
            proves: original.proves,
            boundary: original.boundary
        )
        let jurisdictionPack = withCurrentDigest(
            MedicationCatalogPack(
                manifest: accepted.manifest,
                sources: [wrongJurisdiction],
                ingredients: accepted.ingredients,
                products: accepted.products,
                presentations: accepted.presentations
            )
        )
        XCTAssertTrue(
            MedicationCatalogValidator.issues(
                in: jurisdictionPack,
                exposure: .release
            ).contains { $0.code == "regulatory-source-jurisdiction-mismatch" }
        )

        let wrongAuthority = MedicationCatalogSource(
            id: original.id,
            institution: original.institution,
            title: original.title,
            versionOrPublishedAt: original.versionOrPublishedAt,
            url: original.url,
            retrievedAt: original.retrievedAt,
            region: original.region,
            jurisdictionCodes: original.jurisdictionCodes,
            authorityCodes: ["OTHER-AUTHORITY"],
            licenseIdentifier: original.licenseIdentifier,
            licenseURL: original.licenseURL,
            redistribution: original.redistribution,
            evidenceKinds: original.evidenceKinds,
            proves: original.proves,
            boundary: original.boundary
        )
        let authorityPack = withCurrentDigest(
            MedicationCatalogPack(
                manifest: accepted.manifest,
                sources: [wrongAuthority],
                ingredients: accepted.ingredients,
                products: accepted.products,
                presentations: accepted.presentations
            )
        )
        XCTAssertTrue(
            MedicationCatalogValidator.issues(
                in: authorityPack,
                exposure: .release
            ).contains { $0.code == "regulatory-source-authority-mismatch" }
        )
    }

    func testDigestMutationFailsClosedInsteadOfLookingLikeNoResults() throws {
        let pack = try candidatePack()
        let mutatedIngredient = MedicationIngredient(
            id: pack.ingredients[0].id,
            preferredNameZH: "\(pack.ingredients[0].preferredNameZH)改",
            preferredNameEN: pack.ingredients[0].preferredNameEN,
            exactSubstanceName: pack.ingredients[0].exactSubstanceName,
            aliases: pack.ingredients[0].aliases,
            parentActiveMoietyID: pack.ingredients[0].parentActiveMoietyID,
            activeMoietyName: pack.ingredients[0].activeMoietyName,
            substanceForm: pack.ingredients[0].substanceForm,
            roles: pack.ingredients[0].roles,
            tier: pack.ingredients[0].tier,
            externalIdentifiers: pack.ingredients[0].externalIdentifiers,
            sourceIDs: pack.ingredients[0].sourceIDs,
            boundaryNote: pack.ingredients[0].boundaryNote
        )
        let mutated = MedicationCatalogPack(
            manifest: pack.manifest,
            sources: pack.sources,
            ingredients: [mutatedIngredient] + Array(pack.ingredients.dropFirst()),
            products: pack.products,
            presentations: pack.presentations
        )

        XCTAssertTrue(
            MedicationCatalogValidator.issues(in: mutated, exposure: .candidate)
                .contains { $0.code == "digest-mismatch" }
        )
    }

    func testUnknownIngredientReferenceIsRejected() throws {
        let base = try candidatePack()
        let brokenProduct = MedicationProduct(
            id: "record.broken",
            displayNameZH: "损坏 fixture",
            displayNameEN: "Broken fixture",
            aliases: [],
            region: "test",
            jurisdictionCode: nil,
            regulator: "test",
            regulatorCode: nil,
            regulatoryStatus: .notAsserted,
            authorizationIdentifier: nil,
            holderOrManufacturer: nil,
            ingredientLinks: [
                MedicationProductIngredient(
                    ingredientID: "missing-ingredient",
                    labelStrengthOriginal: nil,
                    activeMoietyBasis: nil,
                    sortOrder: 0
                )
            ],
            sourceIDs: [base.sources[0].id],
            regulatorySourceIDs: nil,
            boundaryNote: "test"
        )
        let brokenPresentation = MedicationPresentation(
            id: "record.broken.other",
            productID: brokenProduct.id,
            displayNameZH: "损坏 fixture",
            displayNameEN: "Broken fixture",
            dosageForm: "test",
            authorizedRoutes: [.other],
            evidenceStatus: .candidateUnverified,
            releasePattern: nil,
            packageOrDevice: nil,
            preciseIngredientForms: nil,
            sourceIDs: [base.sources[0].id]
        )
        let brokenWithoutDigest = MedicationCatalogPack(
            manifest: base.manifest,
            sources: base.sources,
            ingredients: base.ingredients,
            products: base.products + [brokenProduct],
            presentations: base.presentations + [brokenPresentation]
        )
        let broken = withCurrentDigest(brokenWithoutDigest)

        XCTAssertTrue(
            MedicationCatalogValidator.issues(in: broken, exposure: .candidate)
                .contains { $0.code == "unknown-ingredient" }
        )
    }

    func testEveryDuplicateTopLevelStableIDFailsClosedWithoutCrashing() throws {
        let base = try candidatePack()
        let fixtures: [(path: String, pack: MedicationCatalogPack)] = [
            (
                "sources.\(base.sources[0].id)",
                MedicationCatalogPack(
                    manifest: base.manifest,
                    sources: base.sources + [base.sources[0]],
                    ingredients: base.ingredients,
                    products: base.products,
                    presentations: base.presentations
                )
            ),
            (
                "ingredients.\(base.ingredients[0].id)",
                MedicationCatalogPack(
                    manifest: base.manifest,
                    sources: base.sources,
                    ingredients: base.ingredients + [base.ingredients[0]],
                    products: base.products,
                    presentations: base.presentations
                )
            ),
            (
                "products.\(base.products[0].id)",
                MedicationCatalogPack(
                    manifest: base.manifest,
                    sources: base.sources,
                    ingredients: base.ingredients,
                    products: base.products + [base.products[0]],
                    presentations: base.presentations
                )
            ),
            (
                "presentations.\(base.presentations[0].id)",
                MedicationCatalogPack(
                    manifest: base.manifest,
                    sources: base.sources,
                    ingredients: base.ingredients,
                    products: base.products,
                    presentations: base.presentations + [base.presentations[0]]
                )
            )
        ]

        for fixture in fixtures {
            let data = try JSONEncoder().encode(withCurrentDigest(fixture.pack))
            let repository = MedicationCatalogRepository(
                data: data,
                exposure: .candidate
            )

            guard case let .unavailable(.invalidContent(issues)) = repository.state else {
                return XCTFail("\(fixture.path) 没有以 invalidContent 拒绝。")
            }
            XCTAssertTrue(
                issues.contains {
                    $0.code == "duplicate-id" && $0.path == fixture.path
                },
                "\(fixture.path) 缺少 duplicate-id 证据。"
            )
        }
    }

    func testLinkOnlySourceIsRejectedForRelease() throws {
        let base = try candidatePack()
        let original = base.sources[0]
        let linkOnly = MedicationCatalogSource(
            id: original.id,
            institution: original.institution,
            title: original.title,
            versionOrPublishedAt: original.versionOrPublishedAt,
            url: original.url,
            retrievedAt: original.retrievedAt,
            region: original.region,
            jurisdictionCodes: original.jurisdictionCodes,
            authorityCodes: original.authorityCodes,
            licenseIdentifier: original.licenseIdentifier,
            licenseURL: original.licenseURL,
            redistribution: .linkOnly,
            evidenceKinds: original.evidenceKinds,
            proves: original.proves,
            boundary: original.boundary
        )
        let approved = try packWithReview(
            status: .approved,
            reviewer: "Human content reviewer",
            completedAt: "2026-07-30"
        )
        let pack = withCurrentDigest(
            MedicationCatalogPack(
                manifest: approved.manifest,
                sources: [linkOnly] + Array(approved.sources.dropFirst()),
                ingredients: approved.ingredients,
                products: approved.products,
                presentations: approved.presentations
            )
        )

        XCTAssertTrue(
            MedicationCatalogValidator.issues(in: pack, exposure: .release)
                .contains { $0.code == "source-not-redistributable" }
        )
    }

    func testSaltOrEsterWithoutActiveMoietyFailsClosed() throws {
        let base = try candidatePack()
        let source = base.sources[0]
        let invalid = MedicationIngredient(
            id: "missing-active-moiety",
            preferredNameZH: "缺失母体 fixture",
            preferredNameEN: "Missing active moiety fixture",
            exactSubstanceName: "missing active moiety acetate",
            aliases: [],
            parentActiveMoietyID: nil,
            activeMoietyName: nil,
            substanceForm: .salt,
            roles: [.historicalRecord],
            tier: .recordOnly,
            externalIdentifiers: [],
            sourceIDs: [source.id],
            boundaryNote: "Test fixture only"
        )
        let pack = withCurrentDigest(
            MedicationCatalogPack(
                manifest: base.manifest,
                sources: base.sources,
                ingredients: base.ingredients + [invalid],
                products: base.products,
                presentations: base.presentations
            )
        )

        XCTAssertTrue(
            MedicationCatalogValidator.issues(in: pack, exposure: .candidate)
                .contains { $0.code == "missing-active-moiety" }
        )
    }

    func testEstradiolHemihydrateIsPreservedAsPreciseFormulation() throws {
        let pack = try candidatePack()
        let presentation = try XCTUnwrap(
            pack.presentations.first { $0.id == "record.estradiol.hemihydrate-label" }
        )
        let precise = try XCTUnwrap(presentation.preciseIngredientForms?.first)

        XCTAssertEqual(precise.ingredientID, "estradiol")
        XCTAssertEqual(precise.exactFormName, "estradiol hemihydrate")
        XCTAssertEqual(
            precise.externalIdentifiers,
            [MedicationExternalIdentifier(system: "RXCUI", value: "236859")]
        )
    }

    func testPreciseFormMustBelongToProductAndUseUniqueNonemptyExternalID() throws {
        let base = try candidatePack()
        let original = try XCTUnwrap(
            base.presentations.first {
                $0.id == "record.spironolactone.oral-tablet"
            }
        )
        let invalid = MedicationPresentation(
            id: original.id,
            productID: original.productID,
            displayNameZH: original.displayNameZH,
            displayNameEN: original.displayNameEN,
            dosageForm: original.dosageForm,
            authorizedRoutes: original.authorizedRoutes,
            evidenceStatus: original.evidenceStatus,
            releasePattern: original.releasePattern,
            packageOrDevice: original.packageOrDevice,
            preciseIngredientForms: [
                MedicationPresentationIngredientForm(
                    ingredientID: "estradiol",
                    exactFormName: "misattached estradiol fixture",
                    relationship: "test-only invalid relationship",
                    externalIdentifiers: [
                        MedicationExternalIdentifier(
                            system: "RXCUI",
                            value: "4083"
                        )
                    ]
                )
            ],
            sourceIDs: original.sourceIDs
        )
        let pack = withCurrentDigest(
            MedicationCatalogPack(
                manifest: base.manifest,
                sources: base.sources,
                ingredients: base.ingredients,
                products: base.products,
                presentations: base.presentations.map {
                    $0.id == invalid.id ? invalid : $0
                }
            )
        )
        let issues = MedicationCatalogValidator.issues(
            in: pack,
            exposure: .candidate
        )

        XCTAssertTrue(issues.contains { $0.code == "precise-form-not-in-product" })
        XCTAssertTrue(issues.contains { $0.code == "duplicate-external-id" })
    }

    func testFrozenCombinationFixturesPreserveEveryIngredient() throws {
        let base = try candidatePack()
        let sourceID = base.sources[0].id
        let norethisteroneEnanthate = MedicationIngredient(
            id: "norethisterone-enanthate",
            preferredNameZH: "庚酸炔诺酮",
            preferredNameEN: "Norethisterone enanthate",
            exactSubstanceName: "norethisterone enanthate",
            aliases: [],
            parentActiveMoietyID: "norethisterone",
            activeMoietyName: "norethisterone",
            substanceForm: .ester,
            roles: [.progestogen],
            tier: .recordOnly,
            externalIdentifiers: [],
            sourceIDs: [sourceID],
            boundaryNote: "Test fixture only"
        )
        let combinations: [(String, [String])] = [
            ("fixture.cpa-ethinyl-estradiol", ["cyproterone-acetate", "ethinyl-estradiol"]),
            ("fixture.cpa-estradiol-valerate", ["cyproterone-acetate", "estradiol-valerate"]),
            (
                "fixture.estradiol-cypionate-mpa",
                ["estradiol-cypionate", "medroxyprogesterone-acetate"]
            ),
            (
                "fixture.estradiol-valerate-norethisterone-enanthate",
                ["estradiol-valerate", "norethisterone-enanthate"]
            )
        ]
        let products = combinations.map { fixture in
            MedicationProduct(
                id: fixture.0,
                displayNameZH: "复方 fixture",
                displayNameEN: "Combination fixture",
                aliases: [],
                region: "test-only",
                jurisdictionCode: nil,
                regulator: "test-only",
                regulatorCode: nil,
                regulatoryStatus: .combinationOnly,
                authorizationIdentifier: nil,
                holderOrManufacturer: nil,
                ingredientLinks: fixture.1.enumerated().map {
                    MedicationProductIngredient(
                        ingredientID: $0.element,
                        labelStrengthOriginal: nil,
                        activeMoietyBasis: nil,
                        sortOrder: $0.offset
                    )
                },
                sourceIDs: [sourceID],
                regulatorySourceIDs: nil,
                boundaryNote: "Test fixture only"
            )
        }
        let presentations = products.map {
            MedicationPresentation(
                id: "\($0.id).oral",
                productID: $0.id,
                displayNameZH: "复方 presentation fixture",
                displayNameEN: "Combination presentation fixture",
                dosageForm: "test",
                authorizedRoutes: [.oral],
                evidenceStatus: .candidateUnverified,
                releasePattern: nil,
                packageOrDevice: nil,
                preciseIngredientForms: nil,
                sourceIDs: [sourceID]
            )
        }
        let pack = withCurrentDigest(
            MedicationCatalogPack(
                manifest: base.manifest,
                sources: base.sources,
                ingredients: base.ingredients + [norethisteroneEnanthate],
                products: base.products + products,
                presentations: base.presentations + presentations
            )
        )

        XCTAssertEqual(
            MedicationCatalogValidator.issues(in: pack, exposure: .candidate),
            []
        )
        XCTAssertEqual(
            products.map { $0.ingredientLinks.map(\.ingredientID) },
            combinations.map(\.1)
        )
    }

    func testPreciseFormDigestIsIndependentOfArrayOrder() throws {
        let base = try candidatePack()
        let index = try XCTUnwrap(
            base.presentations.firstIndex {
                $0.id == "record.estradiol.hemihydrate-label"
            }
        )
        let original = base.presentations[index]
        let forms = [
            MedicationPresentationIngredientForm(
                ingredientID: "estradiol",
                exactFormName: "estradiol alpha fixture",
                relationship: "test fixture",
                externalIdentifiers: [
                    .init(system: "RXCUI", value: "fixture-1")
                ]
            ),
            MedicationPresentationIngredientForm(
                ingredientID: "estradiol",
                exactFormName: "estradiol beta fixture",
                relationship: "test fixture",
                externalIdentifiers: [
                    .init(system: "RXCUI", value: "fixture-2")
                ]
            )
        ]
        func replacingForms(
            _ preciseForms: [MedicationPresentationIngredientForm]
        ) -> MedicationCatalogPack {
            var presentations = base.presentations
            presentations[index] = MedicationPresentation(
                id: original.id,
                productID: original.productID,
                displayNameZH: original.displayNameZH,
                displayNameEN: original.displayNameEN,
                dosageForm: original.dosageForm,
                authorizedRoutes: original.authorizedRoutes,
                evidenceStatus: original.evidenceStatus,
                releasePattern: original.releasePattern,
                packageOrDevice: original.packageOrDevice,
                preciseIngredientForms: preciseForms,
                sourceIDs: original.sourceIDs
            )
            return MedicationCatalogPack(
                manifest: base.manifest,
                sources: base.sources,
                ingredients: base.ingredients,
                products: base.products,
                presentations: presentations
            )
        }

        XCTAssertEqual(
            MedicationCatalogDigest.contentDigest(
                for: replacingForms(forms)
            ),
            MedicationCatalogDigest.contentDigest(
                for: replacingForms(forms.reversed())
            )
        )
    }

    func testStrictJSONSchemaRejectsUnknownFieldsAtEveryCatalogLayer()
        throws {
        let sourceData = try candidateData()
        let targets = [
            "root",
            "manifest",
            "review",
            "source",
            "ingredient",
            "ingredientExternalIdentifier",
            "product",
            "productIngredientLink",
            "presentation",
            "preciseForm",
            "preciseFormExternalIdentifier"
        ]

        for target in targets {
            var root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: sourceData)
                    as? [String: Any]
            )
            let field = "unexpected_\(target)"
            switch target {
            case "root":
                root[field] = true
            case "manifest":
                var manifest = try XCTUnwrap(
                    root["manifest"] as? [String: Any]
                )
                manifest[field] = true
                root["manifest"] = manifest
            case "review":
                var manifest = try XCTUnwrap(
                    root["manifest"] as? [String: Any]
                )
                var review = try XCTUnwrap(
                    manifest["review"] as? [String: Any]
                )
                review[field] = true
                manifest["review"] = review
                root["manifest"] = manifest
            case "source":
                var values = try XCTUnwrap(
                    root["sources"] as? [[String: Any]]
                )
                values[0][field] = true
                root["sources"] = values
            case "ingredient":
                var values = try XCTUnwrap(
                    root["ingredients"] as? [[String: Any]]
                )
                values[0][field] = true
                root["ingredients"] = values
            case "ingredientExternalIdentifier":
                var values = try XCTUnwrap(
                    root["ingredients"] as? [[String: Any]]
                )
                var identifiers = try XCTUnwrap(
                    values[0]["externalIdentifiers"] as? [[String: Any]]
                )
                identifiers[0][field] = true
                values[0]["externalIdentifiers"] = identifiers
                root["ingredients"] = values
            case "product":
                var values = try XCTUnwrap(
                    root["products"] as? [[String: Any]]
                )
                values[0][field] = true
                root["products"] = values
            case "productIngredientLink":
                var values = try XCTUnwrap(
                    root["products"] as? [[String: Any]]
                )
                var links = try XCTUnwrap(
                    values[0]["ingredientLinks"] as? [[String: Any]]
                )
                links[0][field] = true
                values[0]["ingredientLinks"] = links
                root["products"] = values
            case "presentation":
                var values = try XCTUnwrap(
                    root["presentations"] as? [[String: Any]]
                )
                values[0][field] = true
                root["presentations"] = values
            case "preciseForm", "preciseFormExternalIdentifier":
                var values = try XCTUnwrap(
                    root["presentations"] as? [[String: Any]]
                )
                let index = try XCTUnwrap(
                    values.firstIndex {
                        ($0["preciseIngredientForms"] as? [[String: Any]])?
                            .isEmpty == false
                    }
                )
                var forms = try XCTUnwrap(
                    values[index]["preciseIngredientForms"]
                        as? [[String: Any]]
                )
                if target == "preciseForm" {
                    forms[0][field] = true
                } else {
                    var identifiers = try XCTUnwrap(
                        forms[0]["externalIdentifiers"]
                            as? [[String: Any]]
                    )
                    identifiers[0][field] = true
                    forms[0]["externalIdentifiers"] = identifiers
                }
                values[index]["preciseIngredientForms"] = forms
                root["presentations"] = values
            default:
                XCTFail("Unhandled strict-schema target")
            }

            let state = MedicationCatalogRepository(
                data: try JSONSerialization.data(
                    withJSONObject: root,
                    options: [.sortedKeys]
                ),
                exposure: .candidate
            ).state
            guard case let .unavailable(.unreadableContent(message)) = state
            else {
                XCTFail("Expected strict failure for \(target)")
                continue
            }
            XCTAssertTrue(message.contains(field), target)
            XCTAssertTrue(message.contains("不允许的字段"), target)
        }
    }

    func testSelectionSnapshotIntegrityCoversSemanticFacts() throws {
        let entry = try XCTUnwrap(
            MedicationCatalog.entries.first { $0.id == "estradiol" }
        )
        let product = try XCTUnwrap(entry.products.first)
        let draft = entry.draft(for: product)
        let valid = try XCTUnwrap(
            MedicationCatalogSelectionSnapshotV1.decode(
                draft.productSnapshot
            )
        )
        XCTAssertTrue(valid.hasValidIntegrityDigest)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(draft.productSnapshot.utf8)
            ) as? [String: Any]
        )
        object["productID"] = "record.spironolactone"
        let tampered = try XCTUnwrap(
            MedicationCatalogSelectionSnapshotV1.decode(
                String(
                    data: try JSONSerialization.data(
                        withJSONObject: object,
                        options: [.sortedKeys]
                    ),
                    encoding: .utf8
                )!
            )
        )
        XCTAssertFalse(tampered.hasValidIntegrityDigest)

        object["unexpectedRule"] = "ignored-by-Codable"
        let unknownFieldSnapshot = try XCTUnwrap(
            String(
                data: try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys]
                ),
                encoding: .utf8
            )
        )
        XCTAssertNil(
            MedicationCatalogSelectionSnapshotV1.decode(
                unknownFieldSnapshot
            )
        )

        let nestedProduct = try XCTUnwrap(
            entry.products.first {
                $0.id == "record.estradiol.hemihydrate-label"
            }
        )
        let nestedDraft = entry.draft(for: nestedProduct)
        for target in ["ingredient", "source", "preciseForm", "identifier"] {
            var nestedObject = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(nestedDraft.productSnapshot.utf8)
                ) as? [String: Any]
            )
            switch target {
            case "ingredient":
                var values = try XCTUnwrap(
                    nestedObject["ingredients"] as? [[String: Any]]
                )
                values[0]["unexpectedRule"] = true
                nestedObject["ingredients"] = values
            case "source":
                var values = try XCTUnwrap(
                    nestedObject["sources"] as? [[String: Any]]
                )
                values[0]["unexpectedRule"] = true
                nestedObject["sources"] = values
            case "preciseForm", "identifier":
                var values = try XCTUnwrap(
                    nestedObject["preciseIngredientForms"]
                        as? [[String: Any]]
                )
                if target == "preciseForm" {
                    values[0]["unexpectedRule"] = true
                } else {
                    var identifiers = try XCTUnwrap(
                        values[0]["externalIdentifiers"]
                            as? [[String: Any]]
                    )
                    identifiers[0]["unexpectedRule"] = true
                    values[0]["externalIdentifiers"] = identifiers
                }
                nestedObject["preciseIngredientForms"] = values
            default:
                XCTFail("Unhandled nested snapshot target")
            }
            let nestedSnapshot = try XCTUnwrap(
                String(
                    data: try JSONSerialization.data(
                        withJSONObject: nestedObject,
                        options: [.sortedKeys]
                    ),
                    encoding: .utf8
                )
            )
            XCTAssertNil(
                MedicationCatalogSelectionSnapshotV1.decode(nestedSnapshot),
                target
            )
        }
    }

    func testReleaseStateManifestMakesReleaseUnavailabilityExplicit() throws {
        let data = try releaseStateData()
        let manifest = try JSONDecoder().decode(
            MedicationCatalogReleaseStateManifest.self,
            from: data
        )

        XCTAssertEqual(manifest.status, .pendingHumanReview)
        XCTAssertTrue(manifest.candidateResourceExcluded)
        XCTAssertNil(manifest.approvedResourceName)
        XCTAssertEqual(
            MedicationCatalogRepository.releaseState(data: data),
            .unavailable(.pendingHumanReview)
        )
    }

    func testCatalogSnapshotSurvivesSwiftDataWriteReadAndClone() async throws {
        let entry = try XCTUnwrap(
            MedicationCatalog.entries.first { $0.id == "estradiol" }
        )
        let product = try XCTUnwrap(
            entry.products.first { $0.id == "record.estradiol.transdermal-patch" }
        )
        let draft = entry.draft(for: product)
        let itemID = UUID()
        let recordID = UUID()
        let container = try AppModelContainerFactory.makeInMemoryCoreContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: "UTC"
        )
        try await AppWriteActor(modelContainer: container).saveRegimenDraft(
            SaveRegimenDraftCommand(
                recordID: recordID,
                previousVersionID: nil,
                code: "R-CATALOG-SNAPSHOT",
                title: "目录快照往返",
                effectiveStartDate: try CivilDateFact(
                    year: 2026,
                    month: 7,
                    day: 30
                ),
                changeReason: "Batch 8A persistence contract",
                items: [
                    RegimenItemInput(
                        id: itemID,
                        catalogProductID: draft.catalogID,
                        catalogVersion: draft.catalogVersion,
                        displayName: draft.name,
                        genericName: draft.englishName,
                        dosageForm: draft.dosageForm,
                        route: draft.route,
                        doseOriginal: draft.doseOriginal,
                        unitOriginal: draft.unitOriginal,
                        productSnapshot: draft.productSnapshot,
                        schedule: nil
                    )
                ],
                committedAt: Date(timeIntervalSince1970: 1_775_059_200)
            )
        )

        let overview = try await AppReadActor(
            modelContainer: container
        ).coreRegimenOverview(
            asOf: try CivilDateFact(year: 2026, month: 7, day: 30)
        )
        let stored = try XCTUnwrap(
            overview.drafts.first { $0.id == recordID }?.items.first
        )
        XCTAssertEqual(stored.id, itemID)
        XCTAssertEqual(stored.catalogProductID, draft.catalogID)
        XCTAssertEqual(stored.catalogVersion, draft.catalogVersion)
        XCTAssertEqual(stored.productSnapshot, draft.productSnapshot)
        XCTAssertNotNil(
            MedicationCatalogSelectionSnapshotV1.decode(stored.productSnapshot)
        )

        let clone = RegimenMedicationDraft(
            snapshot: stored,
            cloningIdentity: true
        )
        XCTAssertNotEqual(clone.id, stored.id)
        XCTAssertEqual(clone.catalogID, stored.catalogProductID)
        XCTAssertEqual(clone.catalogVersion, stored.catalogVersion)
        XCTAssertEqual(clone.productSnapshot, stored.productSnapshot)
    }

    private func minimalReleasePack() throws -> MedicationCatalogPack {
        let originalSource = try candidatePack().sources[0]
        let source = MedicationCatalogSource(
            id: "test-regulatory-source",
            institution: "Test regulator",
            title: "Test product register",
            versionOrPublishedAt: "2026-07-30",
            url: originalSource.url,
            retrievedAt: "2026-07-30",
            region: "Test jurisdiction",
            jurisdictionCodes: ["TEST"],
            authorityCodes: ["TEST"],
            licenseIdentifier: originalSource.licenseIdentifier,
            licenseURL: originalSource.licenseURL,
            redistribution: originalSource.redistribution,
            evidenceKinds: [.regulatoryProductRecord],
            proves: "Test product authorization facts",
            boundary: "Test fixture only"
        )
        let ingredient = MedicationIngredient(
            id: "release-fixture",
            preferredNameZH: "正式 fixture",
            preferredNameEN: "Release fixture",
            exactSubstanceName: "release fixture",
            aliases: [],
            parentActiveMoietyID: nil,
            activeMoietyName: nil,
            substanceForm: .activeMoiety,
            roles: [.historicalRecord],
            tier: .recordOnly,
            externalIdentifiers: [],
            sourceIDs: [source.id],
            boundaryNote: "Test fixture only"
        )
        let product = MedicationProduct(
            id: "release-fixture.product",
            displayNameZH: "正式产品 fixture",
            displayNameEN: "Release product fixture",
            aliases: [],
            region: "test",
            jurisdictionCode: "TEST",
            regulator: "test regulator",
            regulatorCode: "TEST",
            regulatoryStatus: .marketed,
            authorizationIdentifier: "TEST-AUTH-001",
            holderOrManufacturer: "Test holder",
            ingredientLinks: [
                MedicationProductIngredient(
                    ingredientID: ingredient.id,
                    labelStrengthOriginal: nil,
                    activeMoietyBasis: nil,
                    sortOrder: 0
                )
            ],
            sourceIDs: [source.id],
            regulatorySourceIDs: [source.id],
            boundaryNote: "Test fixture only"
        )
        let presentation = MedicationPresentation(
            id: "release-fixture.product.oral",
            productID: product.id,
            displayNameZH: "正式 presentation fixture",
            displayNameEN: "Release presentation fixture",
            dosageForm: "test",
            authorizedRoutes: [.oral],
            evidenceStatus: .regulatoryVerified,
            releasePattern: nil,
            packageOrDevice: nil,
            preciseIngredientForms: nil,
            sourceIDs: [source.id]
        )
        return withCurrentDigest(
            MedicationCatalogPack(
                manifest: MedicationCatalogManifest(
                    schemaVersion: "1",
                    catalogVersion: "medication-catalog-2026.07.30-release.1",
                    generatedAt: "2026-07-30",
                    coverageStatement: "Test fixture only",
                    supportedRegions: ["test"],
                    contentDigest: "",
                    review: MedicationCatalogReview(
                        status: .approved,
                        ownerRole: "test",
                        reviewerDisplayName: "Human reviewer",
                        completedAt: "2026-07-30",
                        scope: "Test fixture only"
                    )
                ),
                sources: [source],
                ingredients: [ingredient],
                products: [product],
                presentations: [presentation]
            )
        )
    }

    private func candidateData() throws -> Data {
        let bundles = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        let url = try XCTUnwrap(
            bundles.lazy.compactMap {
                $0.url(
                    forResource: MedicationCatalogRepository.resourceName,
                    withExtension: "json"
                )
            }
            .first
        )
        return try Data(contentsOf: url)
    }

    private func candidatePack() throws -> MedicationCatalogPack {
        try JSONDecoder().decode(
            MedicationCatalogPack.self,
            from: candidateData()
        )
    }

    private func releaseStateData() throws -> Data {
        let bundles = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        let url = try XCTUnwrap(
            bundles.lazy.compactMap {
                $0.url(
                    forResource: MedicationCatalogRepository.releaseStateResourceName,
                    withExtension: "json"
                )
            }
            .first
        )
        return try Data(contentsOf: url)
    }

    private func packWithReview(
        status: MedicationCatalogReview.Status,
        reviewer: String?,
        completedAt: String?
    ) throws -> MedicationCatalogPack {
        let base = try candidatePack()
        let manifest = MedicationCatalogManifest(
            schemaVersion: base.manifest.schemaVersion,
            catalogVersion: base.manifest.catalogVersion,
            generatedAt: base.manifest.generatedAt,
            coverageStatement: base.manifest.coverageStatement,
            supportedRegions: base.manifest.supportedRegions,
            contentDigest: base.manifest.contentDigest,
            review: MedicationCatalogReview(
                status: status,
                ownerRole: base.manifest.review.ownerRole,
                reviewerDisplayName: reviewer,
                completedAt: completedAt,
                scope: base.manifest.review.scope
            )
        )
        return withCurrentDigest(
            MedicationCatalogPack(
                manifest: manifest,
                sources: base.sources,
                ingredients: base.ingredients,
                products: base.products,
                presentations: base.presentations
            )
        )
    }

    private func withCurrentDigest(
        _ pack: MedicationCatalogPack
    ) -> MedicationCatalogPack {
        let manifestWithoutDigest = MedicationCatalogManifest(
            schemaVersion: pack.manifest.schemaVersion,
            catalogVersion: pack.manifest.catalogVersion,
            generatedAt: pack.manifest.generatedAt,
            coverageStatement: pack.manifest.coverageStatement,
            supportedRegions: pack.manifest.supportedRegions,
            contentDigest: "",
            review: pack.manifest.review
        )
        let draft = MedicationCatalogPack(
            manifest: manifestWithoutDigest,
            sources: pack.sources,
            ingredients: pack.ingredients,
            products: pack.products,
            presentations: pack.presentations
        )
        let digest = MedicationCatalogDigest.contentDigest(for: draft)
        let manifest = MedicationCatalogManifest(
            schemaVersion: draft.manifest.schemaVersion,
            catalogVersion: draft.manifest.catalogVersion,
            generatedAt: draft.manifest.generatedAt,
            coverageStatement: draft.manifest.coverageStatement,
            supportedRegions: draft.manifest.supportedRegions,
            contentDigest: digest,
            review: draft.manifest.review
        )
        return MedicationCatalogPack(
            manifest: manifest,
            sources: draft.sources,
            ingredients: draft.ingredients,
            products: draft.products,
            presentations: draft.presentations
        )
    }
}

@MainActor
final class MedicationCatalogRenderTests: XCTestCase {
    func testPickerRendersAtRepresentativeSizes() throws {
        let sizes = [
            CGSize(width: 320, height: 568),
            CGSize(width: 390, height: 844),
            CGSize(width: 430, height: 932),
            CGSize(width: 768, height: 1_024)
        ]

        for size in sizes {
            let image = try renderPicker(
                size: size,
                dynamicTypeSize: .large
            )
            XCTAssertEqual(image.size, size)
            let attachment = XCTAttachment(image: image)
            attachment.name = "MedicationCatalog-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testPickerRendersAtAccessibilityFiveOnNarrowPhone() throws {
        let size = CGSize(width: 320, height: 568)
        let image = try renderPicker(
            size: size,
            dynamicTypeSize: .accessibility5
        )
        XCTAssertEqual(image.size, size)
        let attachment = XCTAttachment(image: image)
        attachment.name = "MedicationCatalog-320x568-AX5"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func renderPicker(
        size: CGSize,
        dynamicTypeSize: DynamicTypeSize
    ) throws -> UIImage {
        let controller = UIHostingController(
            rootView: NavigationStack {
                MedicationCatalogPicker(backAction: {}, chooseAction: { _ in })
            }
            .environment(AppTheme())
            .environment(\.dynamicTypeSize, dynamicTypeSize)
        )
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        var didDrawHierarchy = false
        let image = renderer.image { _ in
            didDrawHierarchy = controller.view.drawHierarchy(
                in: controller.view.bounds,
                afterScreenUpdates: true
            )
        }
        XCTAssertTrue(didDrawHierarchy)
        return image
    }
}
