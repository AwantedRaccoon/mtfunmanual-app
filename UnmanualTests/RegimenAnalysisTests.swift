import SwiftUI
import UIKit
import XCTest
@testable import Unmanual

final class RegimenAnalysisTests: XCTestCase {
    func testCandidatePackPassesValidatorAndDigest() throws {
        let pack = try candidatePack()
        XCTAssertEqual(
            pack.manifest.contentDigest,
            RegimenAnalysisContentDigest.contentDigest(for: pack)
        )
        XCTAssertEqual(
            RegimenAnalysisContentValidator.issues(
                in: pack,
                exposure: .candidate
            ),
            []
        )
    }

    func testCandidateProfilesExactlyCoverBatch8ACandidateIngredients() throws {
        let analysisIDs = Set(try candidatePack().ingredientProfiles.map(\.ingredientID))
        let catalogData = try resourceData(
            name: MedicationCatalogRepository.resourceName
        )
        let catalog = try JSONDecoder().decode(
            MedicationCatalogPack.self,
            from: catalogData
        )
        XCTAssertEqual(analysisIDs, Set(catalog.ingredients.map(\.id)))
        XCTAssertEqual(analysisIDs.count, 33)
    }

    func testSameSemanticInputIsDeterministicAcrossItemArrayOrder() throws {
        let pack = try candidatePack()
        let first = request(
            items: [
                item(position: 1, ingredientIDs: ["spironolactone"]),
                item(position: 0, ingredientIDs: ["estradiol"])
            ]
        )
        let second = request(
            items: [
                item(position: 0, ingredientIDs: ["estradiol"]),
                item(position: 1, ingredientIDs: ["spironolactone"])
            ]
        )
        let firstResult = RegimenAnalysisEngine.evaluate(
            request: first,
            safetyContext: clearedSafety,
            pack: pack
        )
        let secondResult = RegimenAnalysisEngine.evaluate(
            request: second,
            safetyContext: clearedSafety,
            pack: pack
        )
        XCTAssertEqual(firstResult, secondResult)
        XCTAssertEqual(firstResult.semanticStatus, .ready)
    }

    func testUnansweredIsDistinctFromExplicitUnknownAndShowsNoDrugCards()
        throws {
        let pack = try candidatePack()
        let semanticRequest = request(
            items: [
                item(position: 0, ingredientIDs: ["estradiol"])
            ]
        )
        let unanswered = RegimenAnalysisEngine.evaluate(
            request: semanticRequest,
            safetyContext: .unanswered,
            pack: pack
        )
        let explicitUnknown = RegimenAnalysisEngine.evaluate(
            request: semanticRequest,
            safetyContext: .init(
                ageBand: .unknown,
                pregnancyPossibility: .notApplicable,
                acuteConcern: .no,
                knownVteHistoryOrRisk: .no,
                knownMeningiomaHistory: nil
            ),
            pack: pack
        )

        XCTAssertEqual(unanswered.semanticStatus, .unanswered)
        XCTAssertTrue(unanswered.stopCards.isEmpty)
        XCTAssertTrue(unanswered.frameworkCards.isEmpty)
        XCTAssertTrue(unanswered.confirmationCards.isEmpty)
        XCTAssertTrue(unanswered.monitoringCards.isEmpty)
        XCTAssertEqual(explicitUnknown.semanticStatus, .stopped)
        XCTAssertEqual(explicitUnknown.stopCards.map(\.id), ["stop.age.unknown"])
        XCTAssertNotEqual(
            unanswered.semanticInputDigest,
            explicitUnknown.semanticInputDigest
        )
    }

    func testOnlyQuestionsShownForMatchingIngredientsBlockAnalysis()
        throws {
        let pack = try candidatePack()
        let commonAnswers = RegimenAnalysisSafetyContext(
            ageBand: .adult,
            pregnancyPossibility: .notApplicable,
            acuteConcern: .no,
            knownVteHistoryOrRisk: nil,
            knownMeningiomaHistory: nil
        )

        let nonFlagged = RegimenAnalysisEngine.evaluate(
            request: request(
                items: [
                    item(position: 0, ingredientIDs: ["spironolactone"])
                ]
            ),
            safetyContext: commonAnswers,
            pack: pack
        )
        let estrogen = RegimenAnalysisEngine.evaluate(
            request: request(
                items: [
                    item(position: 0, ingredientIDs: ["estradiol"])
                ]
            ),
            safetyContext: commonAnswers,
            pack: pack
        )
        let cyproterone = RegimenAnalysisEngine.evaluate(
            request: request(
                items: [
                    item(
                        position: 0,
                        ingredientIDs: ["cyproterone-acetate"]
                    )
                ]
            ),
            safetyContext: commonAnswers,
            pack: pack
        )

        XCTAssertEqual(nonFlagged.semanticStatus, .ready)
        XCTAssertEqual(estrogen.semanticStatus, .unanswered)
        XCTAssertEqual(cyproterone.semanticStatus, .unanswered)
    }

    func testSameSemanticInputIsDeterministicAcrossLocaleAndTimeZoneDefaults()
        throws {
        let defaults = UserDefaults.standard
        let previousLocale = defaults.object(forKey: "AppleLocale")
        let previousLanguages = defaults.object(forKey: "AppleLanguages")
        let previousTimeZone = NSTimeZone.default
        defer {
            if let previousLocale {
                defaults.set(previousLocale, forKey: "AppleLocale")
            } else {
                defaults.removeObject(forKey: "AppleLocale")
            }
            if let previousLanguages {
                defaults.set(previousLanguages, forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: "AppleLanguages")
            }
            NSTimeZone.default = previousTimeZone
        }

        let pack = try candidatePack()
        let semanticRequest = request(
            items: [
                item(position: 0, ingredientIDs: ["estradiol"]),
                item(position: 1, ingredientIDs: ["spironolactone"])
            ]
        )

        defaults.set("en_US", forKey: "AppleLocale")
        defaults.set(["en-US"], forKey: "AppleLanguages")
        NSTimeZone.default = try XCTUnwrap(
            TimeZone(identifier: "America/Chicago")
        )
        let first = RegimenAnalysisEngine.evaluate(
            request: semanticRequest,
            safetyContext: clearedSafety,
            pack: pack
        )

        defaults.set("zh_CN", forKey: "AppleLocale")
        defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        NSTimeZone.default = try XCTUnwrap(
            TimeZone(identifier: "Asia/Shanghai")
        )
        let second = RegimenAnalysisEngine.evaluate(
            request: semanticRequest,
            safetyContext: clearedSafety,
            pack: pack
        )

        XCTAssertEqual(first, second)
    }

    func testDoseAndUnitOnlyChangeSummaryAndInputDigest() throws {
        let pack = try candidatePack()
        let first = RegimenAnalysisEngine.evaluate(
            request: request(
                items: [
                    item(
                        position: 0,
                        ingredientIDs: ["estradiol"],
                        dose: "原文 A",
                        unit: "单位 A"
                    )
                ]
            ),
            safetyContext: clearedSafety,
            pack: pack
        )
        let second = RegimenAnalysisEngine.evaluate(
            request: request(
                items: [
                    item(
                        position: 0,
                        ingredientIDs: ["estradiol"],
                        dose: "完全不同的原文",
                        unit: "完全不同的单位"
                    )
                ]
            ),
            safetyContext: clearedSafety,
            pack: pack
        )
        XCTAssertNotEqual(first.summaries, second.summaries)
        XCTAssertNotEqual(first.semanticInputDigest, second.semanticInputDigest)
        XCTAssertEqual(first.semanticStatus, second.semanticStatus)
        XCTAssertEqual(first.frameworkCards.map(\.id), second.frameworkCards.map(\.id))
        XCTAssertEqual(
            first.confirmationCards.map(\.id),
            second.confirmationCards.map(\.id)
        )
        XCTAssertEqual(
            first.monitoringCards.map(\.id),
            second.monitoringCards.map(\.id)
        )
    }

    func testRecordFindingsReportMissingDosageFormWithoutMedicalJudgment()
        throws {
        let result = RegimenAnalysisEngine.evaluate(
            request: request(
                items: [
                    item(
                        position: 0,
                        ingredientIDs: ["estradiol"],
                        form: ""
                    )
                ]
            ),
            safetyContext: clearedSafety,
            pack: try candidatePack()
        )
        XCTAssertTrue(
            result.recordFindings.contains {
                $0.contains("剂型未记录")
            }
        )
    }

    func testStopRulePriorityAndAllFrozenBranches() throws {
        let pack = try candidatePack()

        let corrupt = RegimenAnalysisEngine.evaluate(
            request: request(
                items: [
                    item(
                        position: 0,
                        ingredientIDs: [],
                        status: .unreadableCatalogSnapshot
                    )
                ]
            ),
            safetyContext: .init(
                ageBand: .under18,
                pregnancyPossibility: .yes,
                acuteConcern: .yes,
                knownVteHistoryOrRisk: .yes,
                knownMeningiomaHistory: .yes
            ),
            pack: pack
        )
        XCTAssertEqual(corrupt.stopCards.map(\.id), ["stop.snapshot"])

        let cases: [
            (
                ingredient: String,
                context: RegimenAnalysisSafetyContext,
                expected: String
            )
        ] = [
            (
                "estradiol",
                .init(
                    ageBand: .adult,
                    pregnancyPossibility: .notApplicable,
                    acuteConcern: .yes,
                    knownVteHistoryOrRisk: .no,
                    knownMeningiomaHistory: .no
                ),
                "stop.acute.yes"
            ),
            (
                "estradiol",
                .init(
                    ageBand: .adult,
                    pregnancyPossibility: .notApplicable,
                    acuteConcern: .unknown,
                    knownVteHistoryOrRisk: .no,
                    knownMeningiomaHistory: .no
                ),
                "stop.acute.unknown"
            ),
            (
                "estradiol",
                .init(
                    ageBand: .under18,
                    pregnancyPossibility: .notApplicable,
                    acuteConcern: .no,
                    knownVteHistoryOrRisk: .no,
                    knownMeningiomaHistory: .no
                ),
                "stop.age.under18"
            ),
            (
                "estradiol",
                .init(
                    ageBand: .unknown,
                    pregnancyPossibility: .notApplicable,
                    acuteConcern: .no,
                    knownVteHistoryOrRisk: .no,
                    knownMeningiomaHistory: .no
                ),
                "stop.age.unknown"
            ),
            (
                "estradiol",
                .init(
                    ageBand: .adult,
                    pregnancyPossibility: .yes,
                    acuteConcern: .no,
                    knownVteHistoryOrRisk: .no,
                    knownMeningiomaHistory: .no
                ),
                "stop.pregnancy.yes"
            ),
            (
                "estradiol",
                .init(
                    ageBand: .adult,
                    pregnancyPossibility: .unknown,
                    acuteConcern: .no,
                    knownVteHistoryOrRisk: .no,
                    knownMeningiomaHistory: .no
                ),
                "stop.pregnancy.unknown"
            ),
            (
                "estradiol",
                .init(
                    ageBand: .adult,
                    pregnancyPossibility: .notApplicable,
                    acuteConcern: .no,
                    knownVteHistoryOrRisk: .yes,
                    knownMeningiomaHistory: .no
                ),
                "stop.vte.yes"
            ),
            (
                "estradiol",
                .init(
                    ageBand: .adult,
                    pregnancyPossibility: .notApplicable,
                    acuteConcern: .no,
                    knownVteHistoryOrRisk: .unknown,
                    knownMeningiomaHistory: .no
                ),
                "stop.vte.unknown"
            ),
            (
                "cyproterone-acetate",
                .init(
                    ageBand: .adult,
                    pregnancyPossibility: .notApplicable,
                    acuteConcern: .no,
                    knownVteHistoryOrRisk: .no,
                    knownMeningiomaHistory: .yes
                ),
                "stop.cpa.meningioma.yes"
            ),
            (
                "cyproterone-acetate",
                .init(
                    ageBand: .adult,
                    pregnancyPossibility: .notApplicable,
                    acuteConcern: .no,
                    knownVteHistoryOrRisk: .no,
                    knownMeningiomaHistory: .unknown
                ),
                "stop.cpa.meningioma.unknown"
            )
        ]

        for testCase in cases {
            let result = RegimenAnalysisEngine.evaluate(
                request: request(
                    items: [
                        item(
                            position: 0,
                            ingredientIDs: [testCase.ingredient]
                        )
                    ]
                ),
                safetyContext: testCase.context,
                pack: pack
            )
            XCTAssertEqual(
                result.stopCards.map(\.id),
                [testCase.expected],
                testCase.expected
            )
            XCTAssertEqual(result.semanticStatus, .stopped)
            XCTAssertTrue(result.monitoringCards.isEmpty)
            XCTAssertTrue(result.frameworkCards.isEmpty)
        }
    }

    func testValidatorRejectsMaliciousRuleRepriorityAndEngineKeepsFrozenOrder()
        throws {
        let base = try candidatePack()
        var rules = base.safetyRules
        let acuteIndex = try XCTUnwrap(
            rules.firstIndex { $0.condition == .acuteConcernYes }
        )
        let ageIndex = try XCTUnwrap(
            rules.firstIndex { $0.condition == .ageUnder18 }
        )
        let acute = rules[acuteIndex]
        let age = rules[ageIndex]
        rules[acuteIndex] = RegimenAnalysisSafetyRule(
            id: acute.id,
            priority: 30,
            condition: acute.condition,
            stopCardID: acute.stopCardID
        )
        rules[ageIndex] = RegimenAnalysisSafetyRule(
            id: age.id,
            priority: 5,
            condition: age.condition,
            stopCardID: age.stopCardID
        )
        rules.sort {
            ($0.priority, $0.id) < ($1.priority, $1.id)
        }
        let reprioritized = withDigest(
            RegimenAnalysisContentPack(
                manifest: base.manifest,
                sources: base.sources,
                cards: base.cards,
                ingredientProfiles: base.ingredientProfiles,
                safetyRules: rules
            )
        )
        XCTAssertTrue(
            RegimenAnalysisContentValidator.issues(
                in: reprioritized,
                exposure: .candidate
            ).contains {
                $0.code == "invalid-frozen-rule-contract"
            }
        )

        let result = RegimenAnalysisEngine.evaluate(
            request: request(
                items: [
                    item(
                        position: 0,
                        ingredientIDs: ["estradiol"]
                    )
                ]
            ),
            safetyContext: .init(
                ageBand: .under18,
                pregnancyPossibility: .yes,
                acuteConcern: .yes,
                knownVteHistoryOrRisk: .yes,
                knownMeningiomaHistory: .unknown
            ),
            pack: reprioritized
        )
        XCTAssertEqual(result.stopCards.map(\.id), ["stop.acute.yes"])
    }

    func testCustomUnknownAndCorruptEntriesNeverUseNameGuessing() throws {
        let pack = try candidatePack()
        let custom = RegimenAnalysisEngine.evaluate(
            request: request(
                items: [
                    item(
                        position: 0,
                        ingredientIDs: [],
                        name: "Estradiol / E2",
                        status: .customEntry
                    )
                ]
            ),
            safetyContext: clearedSafety,
            pack: pack
        )
        XCTAssertEqual(custom.semanticStatus, .limited)
        XCTAssertEqual(
            custom.confirmationCards.map(\.id),
            ["confirmation.unmapped"]
        )
        XCTAssertTrue(custom.monitoringCards.isEmpty)
        XCTAssertTrue(custom.frameworkCards.isEmpty)

        let unknown = RegimenAnalysisEngine.evaluate(
            request: request(
                items: [
                    item(
                        position: 0,
                        ingredientIDs: ["not-in-rule-pack"],
                        name: "雌二醇"
                    )
                ]
            ),
            safetyContext: clearedSafety,
            pack: pack
        )
        XCTAssertEqual(unknown.semanticStatus, .limited)
        XCTAssertTrue(unknown.monitoringCards.isEmpty)
    }

    func testCombinationMergesCardsAndSourcesByStableID() throws {
        let pack = try candidatePack()
        let result = RegimenAnalysisEngine.evaluate(
            request: request(
                items: [
                    item(
                        position: 0,
                        ingredientIDs: [
                            "estradiol",
                            "medroxyprogesterone-acetate"
                        ]
                    )
                ]
            ),
            safetyContext: clearedSafety,
            pack: pack
        )
        XCTAssertEqual(result.semanticStatus, .ready)
        XCTAssertEqual(
            result.frameworkCards.map(\.id).count,
            Set(result.frameworkCards.map(\.id)).count
        )
        XCTAssertEqual(
            result.sources.map(\.id).count,
            Set(result.sources.map(\.id)).count
        )
        XCTAssertEqual(result.componentExplanations.count, 2)
        for component in result.componentExplanations {
            XCTAssertFalse(component.ingredientID.isEmpty)
            XCTAssertFalse(component.correspondenceExplanation.isEmpty)
            XCTAssertFalse(component.boundary.isEmpty)
            XCTAssertFalse(component.discussionCards.isEmpty)
            XCTAssertFalse(component.sources.isEmpty)
        }
        XCTAssertEqual(
            Set(result.componentExplanations.map(\.ingredientID)),
            ["estradiol", "medroxyprogesterone-acetate"]
        )
    }

    func testHistoricalCatalogVersionCanUseCompatibleSnapshotFacts() throws {
        let pack = try candidatePack()
        let old = item(
            position: 0,
            ingredientIDs: ["estradiol"],
            catalogVersion: "medication-catalog-2025.01.01-release.1"
        )
        let result = RegimenAnalysisEngine.evaluate(
            request: request(items: [old]),
            safetyContext: clearedSafety,
            pack: pack
        )
        XCTAssertEqual(result.semanticStatus, .ready)
        XCTAssertEqual(
            result.contentPackVersion,
            pack.manifest.contentPackVersion
        )
    }

    func testCoreRegimenAdapterAcceptsOnlyExactVersionedCatalogSnapshot() {
        let verified = RegimenAnalysisRequestV1(
            regimen: RegimenAnalysisDebugFixture.regimen
        )
        XCTAssertEqual(
            verified.items.first?.snapshotStatus,
            .verifiedCatalogSnapshot
        )
        XCTAssertEqual(
            verified.items.first?.exactIngredientIDs,
            ["estradiol"]
        )

        let source = RegimenAnalysisDebugFixture.regimen
        let original = source.items[0]
        let corrupted = CoreRegimenVersionSnapshot(
            id: source.id,
            code: source.code,
            title: source.title,
            effectiveStartDate: source.effectiveStartDate,
            effectiveEndDate: source.effectiveEndDate,
            previousVersionID: source.previousVersionID,
            changeReason: source.changeReason,
            editState: source.editState,
            requiresReview: source.requiresReview,
            items: [
                CoreRegimenItemSnapshot(
                    id: original.id,
                    catalogProductID: original.catalogProductID,
                    catalogVersion: original.catalogVersion,
                    displayName: "雌二醇",
                    genericName: original.genericName,
                    dosageForm: original.dosageForm,
                    route: original.route,
                    doseOriginal: original.doseOriginal,
                    unitOriginal: original.unitOriginal,
                    productSnapshot: "{\"schemaVersion\":\"1\"}",
                    schedule: nil,
                    scheduleSummary: original.scheduleSummary
                )
            ]
        )
        let invalidRequest = RegimenAnalysisRequestV1(regimen: corrupted)
        XCTAssertEqual(
            invalidRequest.items.first?.snapshotStatus,
            .unreadableCatalogSnapshot
        )
        XCTAssertTrue(invalidRequest.items.first?.exactIngredientIDs.isEmpty == true)
    }

    func testCurrentCatalogRejectsRehashedSemanticSnapshotMismatch()
        throws {
        let source = RegimenAnalysisDebugFixture.regimen
        let original = source.items[0]

        func rehashedSnapshot(
            mutating mutation: (inout [String: Any]) -> Void
        ) throws -> String {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(original.productSnapshot.utf8)
                ) as? [String: Any]
            )
            mutation(&object)
            object["integrityDigest"] = NSNull()
            let unsignedString = try XCTUnwrap(
                String(
                    data: try JSONSerialization.data(
                        withJSONObject: object,
                        options: [.sortedKeys]
                    ),
                    encoding: .utf8
                )
            )
            let unsigned = try XCTUnwrap(
                MedicationCatalogSelectionSnapshotV1.decode(unsignedString)
            )
            return try XCTUnwrap(unsigned.encodedString())
        }

        func request(
            snapshot: String,
            currentCatalog: MedicationCatalogSnapshot? =
                MedicationCatalog.loadState.snapshot
        ) -> RegimenAnalysisRequestV1 {
            RegimenAnalysisRequestV1(
                regimen: CoreRegimenVersionSnapshot(
                    id: source.id,
                    code: source.code,
                    title: source.title,
                    effectiveStartDate: source.effectiveStartDate,
                    effectiveEndDate: source.effectiveEndDate,
                    previousVersionID: source.previousVersionID,
                    changeReason: source.changeReason,
                    editState: source.editState,
                    requiresReview: source.requiresReview,
                    items: [
                        CoreRegimenItemSnapshot(
                            id: original.id,
                            catalogProductID: original.catalogProductID,
                            catalogVersion: original.catalogVersion,
                            displayName: original.displayName,
                            genericName: original.genericName,
                            dosageForm: original.dosageForm,
                            route: original.route,
                            doseOriginal: original.doseOriginal,
                            unitOriginal: original.unitOriginal,
                            productSnapshot: snapshot,
                            schedule: nil,
                            scheduleSummary: original.scheduleSummary
                        )
                    ]
                ),
                currentCatalog: currentCatalog
            )
        }

        let forgedIngredient = try rehashedSnapshot { object in
            object["ingredients"] = [
                [
                    "id": "spironolactone",
                    "nameZH": "螺内酯",
                    "nameEN": "Spironolactone"
                ]
            ]
        }
        let forgedDosageForm = try rehashedSnapshot { object in
            object["dosageForm"] = "伪造剂型"
        }
        let malformedCatalogDigest = try rehashedSnapshot { object in
            object["catalogContentDigest"] = "not-a-sha256-digest"
        }

        for snapshot in [forgedIngredient, forgedDosageForm] {
            let result = request(snapshot: snapshot)
            XCTAssertEqual(
                result.items.first?.snapshotStatus,
                .unreadableCatalogSnapshot
            )
            XCTAssertTrue(
                result.items.first?.exactIngredientIDs.isEmpty == true
            )
        }
        let historicalResult = request(
            snapshot: malformedCatalogDigest,
            currentCatalog: nil
        )
        XCTAssertEqual(
            historicalResult.items.first?.snapshotStatus,
            .unreadableCatalogSnapshot
        )
    }

    func testCandidateFailsReleaseAndApprovedFixturePassesRelease() throws {
        let candidate = try candidatePack()
        let releaseIssues = RegimenAnalysisContentValidator.issues(
            in: candidate,
            exposure: .release
        )
        XCTAssertTrue(releaseIssues.contains { $0.code == "review-not-approved" })
        XCTAssertTrue(releaseIssues.contains { $0.code == "classification-pending" })

        let approved = withDigest(
            replacingManifest(
                in: candidate,
                review: .init(
                    status: .approved,
                    ownerRole: candidate.manifest.review.ownerRole,
                    contentReviewerDisplayName: "Human content reviewer",
                    medicalReviewerDisplayName: "Human medical reviewer",
                    completedAt: "2026-07-30",
                    scope: candidate.manifest.review.scope
                ),
                classification: .resolved
            )
        )
        XCTAssertEqual(
            RegimenAnalysisContentValidator.issues(
                in: approved,
                exposure: .release
            ),
            []
        )
    }

    func testReleaseRepositoryRequiresMatchingReleaseCatalogState()
        throws {
        let candidate = try candidatePack()
        let catalogCandidate = try XCTUnwrap(
            MedicationCatalog.loadState.snapshot
        )
        let releaseCatalogVersion =
            "medication-catalog-2026.07.30-release.1"
        let releaseCatalogDigest = String(repeating: "a", count: 64)
        let approvedBase = replacingManifest(
            in: candidate,
            review: .init(
                status: .approved,
                ownerRole: candidate.manifest.review.ownerRole,
                contentReviewerDisplayName: "Human content reviewer",
                medicalReviewerDisplayName: "Human medical reviewer",
                completedAt: "2026-07-30",
                scope: candidate.manifest.review.scope
            ),
            classification: .resolved
        )
        let approved = withDigest(
            RegimenAnalysisContentPack(
                manifest: RegimenAnalysisManifest(
                    schemaVersion: approvedBase.manifest.schemaVersion,
                    contentPackVersion:
                        approvedBase.manifest.contentPackVersion,
                    ruleSetVersion: approvedBase.manifest.ruleSetVersion,
                    requiredCatalogVersion: releaseCatalogVersion,
                    requiredCatalogContentDigest: releaseCatalogDigest,
                    generatedAt: approvedBase.manifest.generatedAt,
                    coverageStatement:
                        approvedBase.manifest.coverageStatement,
                    contentDigest: "",
                    requiredIngredientIDs:
                        approvedBase.manifest.requiredIngredientIDs,
                    globalBoundaryCardIDs:
                        approvedBase.manifest.globalBoundaryCardIDs,
                    limitedCardIDs:
                        approvedBase.manifest.limitedCardIDs,
                    review: approvedBase.manifest.review,
                    medicalClassificationStatus:
                        approvedBase.manifest.medicalClassificationStatus
                ),
                sources: approvedBase.sources,
                cards: approvedBase.cards,
                ingredientProfiles: approvedBase.ingredientProfiles,
                safetyRules: approvedBase.safetyRules
            )
        )
        let data = try JSONEncoder().encode(approved)
        let releaseCatalog = MedicationCatalogSnapshot(
            exposure: .release,
            manifest: MedicationCatalogManifest(
                schemaVersion: catalogCandidate.manifest.schemaVersion,
                catalogVersion: releaseCatalogVersion,
                generatedAt: catalogCandidate.manifest.generatedAt,
                coverageStatement:
                    catalogCandidate.manifest.coverageStatement,
                supportedRegions:
                    catalogCandidate.manifest.supportedRegions,
                contentDigest: releaseCatalogDigest,
                review: .init(
                    status: .approved,
                    ownerRole: "test",
                    reviewerDisplayName: "Human reviewer",
                    completedAt: "2026-07-30",
                    scope: "test"
                )
            ),
            sources: catalogCandidate.sources,
            entries: catalogCandidate.entries
        )

        for catalogState in [
            Optional<MedicationCatalogLoadState>.none,
            .some(.available(catalogCandidate))
        ] {
            XCTAssertEqual(
                RegimenAnalysisContentRepository(
                    data: data,
                    exposure: .release,
                    medicationCatalogState: catalogState
                ).state,
                .unavailable(.medicationCatalogUnavailable)
            )
        }

        guard case .available = RegimenAnalysisContentRepository(
            data: data,
            exposure: .release,
            medicationCatalogState: .available(releaseCatalog)
        ).state else {
            return XCTFail("Matching Release catalog must open Release 8B")
        }
    }

    func testValidatorRejectsUnsafeURLUnknownReferenceAndForbiddenOutput() throws {
        let base = try candidatePack()
        let firstSource = try XCTUnwrap(base.sources.first)
        let unsafeSource = RegimenAnalysisSourceCard(
            id: firstSource.id,
            institution: firstSource.institution,
            title: firstSource.title,
            versionOrPublishedAt: firstSource.versionOrPublishedAt,
            officialURL: firstSource.officialURL + "?drug=user-value",
            retrievedAt: firstSource.retrievedAt,
            applicablePopulation: firstSource.applicablePopulation,
            applicableRegions: firstSource.applicableRegions,
            licenseIdentifier: firstSource.licenseIdentifier,
            licenseURL: firstSource.licenseURL,
            redistribution: firstSource.redistribution,
            attributionText: firstSource.attributionText,
            boundary: firstSource.boundary
        )
        var sources = base.sources
        sources[0] = unsafeSource
        var cards = base.cards
        let firstCard = cards[0]
        cards[0] = RegimenAnalysisCard(
            id: firstCard.id,
            kind: firstCard.kind,
            evidenceBasis: firstCard.evidenceBasis,
            title: "推荐剂量",
            body: firstCard.body,
            boundary: firstCard.boundary,
            sourceIDs: ["missing-source"],
            sortOrder: firstCard.sortOrder
        )
        let invalid = withDigest(
            RegimenAnalysisContentPack(
                manifest: base.manifest,
                sources: sources,
                cards: cards,
                ingredientProfiles: base.ingredientProfiles,
                safetyRules: base.safetyRules
            )
        )
        let issues = RegimenAnalysisContentValidator.issues(
            in: invalid,
            exposure: .candidate
        )
        XCTAssertTrue(issues.contains { $0.code == "unsafe-source-url" })
        XCTAssertTrue(issues.contains { $0.code == "invalid-card" })
        XCTAssertTrue(issues.contains { $0.code == "forbidden-medical-output" })
    }

    func testValidatorRejectsCardEvidenceAndManifestReferenceKindConfusion()
        throws {
        let base = try candidatePack()
        let productRuleIndex = try XCTUnwrap(
            base.cards.firstIndex {
                $0.evidenceBasis == .productRule
            }
        )
        let externalIndex = try XCTUnwrap(
            base.cards.firstIndex {
                $0.evidenceBasis == .externalAuthority
                    && !$0.sourceIDs.isEmpty
            }
        )
        var cards = base.cards
        let productRule = cards[productRuleIndex]
        cards[productRuleIndex] = RegimenAnalysisCard(
            id: productRule.id,
            kind: productRule.kind,
            evidenceBasis: .externalAuthority,
            title: productRule.title,
            body: productRule.body,
            boundary: productRule.boundary,
            sourceIDs: [],
            sortOrder: productRule.sortOrder
        )
        let external = cards[externalIndex]
        cards[externalIndex] = RegimenAnalysisCard(
            id: external.id,
            kind: external.kind,
            evidenceBasis: .productRule,
            title: external.title,
            body: external.body,
            boundary: external.boundary,
            sourceIDs: external.sourceIDs,
            sortOrder: external.sortOrder
        )
        let evidenceInvalid = withDigest(
            RegimenAnalysisContentPack(
                manifest: base.manifest,
                sources: base.sources,
                cards: cards,
                ingredientProfiles: base.ingredientProfiles,
                safetyRules: base.safetyRules
            )
        )
        let evidenceIssues = RegimenAnalysisContentValidator.issues(
            in: evidenceInvalid,
            exposure: .candidate
        )
        XCTAssertTrue(
            evidenceIssues.contains { $0.code == "missing-card-source" }
        )
        XCTAssertTrue(
            evidenceIssues.contains {
                $0.code == "product-rule-has-external-source"
            }
        )

        var profiles = base.ingredientProfiles
        let firstProfile = profiles[0]
        profiles[0] = RegimenAnalysisIngredientProfile(
            ingredientID: firstProfile.ingredientID,
            ingredientNameZH: firstProfile.ingredientNameZH,
            correspondence: firstProfile.correspondence,
            safetyFlags: firstProfile.safetyFlags,
            cardIDs: ["stop.snapshot"],
            boundary: firstProfile.boundary
        )
        let profileInvalid = withDigest(
            RegimenAnalysisContentPack(
                manifest: base.manifest,
                sources: base.sources,
                cards: base.cards,
                ingredientProfiles: profiles,
                safetyRules: base.safetyRules
            )
        )
        XCTAssertTrue(
            RegimenAnalysisContentValidator.issues(
                in: profileInvalid,
                exposure: .candidate
            ).contains { $0.code == "invalid-profile-card-kind" }
        )

        let manifest = RegimenAnalysisManifest(
            schemaVersion: base.manifest.schemaVersion,
            contentPackVersion: base.manifest.contentPackVersion,
            ruleSetVersion: base.manifest.ruleSetVersion,
            requiredCatalogVersion:
                base.manifest.requiredCatalogVersion,
            requiredCatalogContentDigest:
                base.manifest.requiredCatalogContentDigest,
            generatedAt: base.manifest.generatedAt,
            coverageStatement: base.manifest.coverageStatement,
            contentDigest: "",
            requiredIngredientIDs: base.manifest.requiredIngredientIDs,
            globalBoundaryCardIDs: ["confirmation.unmapped"],
            limitedCardIDs: ["boundary.educational-only"],
            review: base.manifest.review,
            medicalClassificationStatus:
                base.manifest.medicalClassificationStatus
        )
        let manifestInvalid = withDigest(
            RegimenAnalysisContentPack(
                manifest: manifest,
                sources: base.sources,
                cards: base.cards,
                ingredientProfiles: base.ingredientProfiles,
                safetyRules: base.safetyRules
            )
        )
        XCTAssertTrue(
            RegimenAnalysisContentValidator.issues(
                in: manifestInvalid,
                exposure: .candidate
            ).contains { $0.code == "invalid-manifest-card-reference" }
        )
    }

    func testEveryFrozenForbiddenPhraseFailsClosed() throws {
        let base = try candidatePack()
        for phrase in RegimenAnalysisContentValidator.forbiddenCardTerms {
            var cards = base.cards
            let original = cards[0]
            cards[0] = RegimenAnalysisCard(
                id: original.id,
                kind: original.kind,
                evidenceBasis: original.evidenceBasis,
                title: phrase,
                body: original.body,
                boundary: original.boundary,
                sourceIDs: original.sourceIDs,
                sortOrder: original.sortOrder
            )
            let invalid = withDigest(
                RegimenAnalysisContentPack(
                    manifest: base.manifest,
                    sources: base.sources,
                    cards: cards,
                    ingredientProfiles: base.ingredientProfiles,
                    safetyRules: base.safetyRules
                )
            )
            XCTAssertTrue(
                RegimenAnalysisContentValidator.issues(
                    in: invalid,
                    exposure: .candidate
                ).contains { $0.code == "forbidden-medical-output" },
                phrase
            )
        }
    }

    func testStrictJSONSchemaRejectsUnknownExecutableAndThresholdFields()
        throws {
        let sourceData = try resourceData(
            name: RegimenAnalysisContentRepository.resourceName
        )
        let mutations: [(target: String, field: String)] = [
            ("root", "script"),
            ("manifest", "expression"),
            ("review", "doseThreshold"),
            ("source", "labThreshold"),
            ("card", "doseThreshold"),
            ("profile", "namePattern"),
            ("rule", "expression")
        ]

        for mutation in mutations {
            var root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: sourceData)
                    as? [String: Any]
            )
            switch mutation.target {
            case "root":
                root[mutation.field] = "ignored-by-Codable"
            case "manifest":
                var manifest = try XCTUnwrap(
                    root["manifest"] as? [String: Any]
                )
                manifest[mutation.field] = "ignored-by-Codable"
                root["manifest"] = manifest
            case "review":
                var manifest = try XCTUnwrap(
                    root["manifest"] as? [String: Any]
                )
                var review = try XCTUnwrap(
                    manifest["review"] as? [String: Any]
                )
                review[mutation.field] = 1
                manifest["review"] = review
                root["manifest"] = manifest
            case "source":
                var sources = try XCTUnwrap(
                    root["sources"] as? [[String: Any]]
                )
                sources[0][mutation.field] = 1
                root["sources"] = sources
            case "card":
                var cards = try XCTUnwrap(
                    root["cards"] as? [[String: Any]]
                )
                cards[0][mutation.field] = 1
                root["cards"] = cards
            case "profile":
                var profiles = try XCTUnwrap(
                    root["ingredientProfiles"] as? [[String: Any]]
                )
                profiles[0][mutation.field] = "estradiol"
                root["ingredientProfiles"] = profiles
            case "rule":
                var rules = try XCTUnwrap(
                    root["safetyRules"] as? [[String: Any]]
                )
                rules[0][mutation.field] = "return true"
                root["safetyRules"] = rules
            default:
                XCTFail("Unknown mutation target")
            }

            let mutatedData = try JSONSerialization.data(
                withJSONObject: root,
                options: [.sortedKeys]
            )
            let state = RegimenAnalysisContentRepository(
                data: mutatedData,
                exposure: .candidate
            ).state
            guard case let .unavailable(.unreadableContent(message)) = state
            else {
                XCTFail(
                    "Expected strict schema failure for \(mutation.target)"
                )
                continue
            }
            XCTAssertTrue(message.contains(mutation.field))
            XCTAssertTrue(message.contains("不允许的字段"))
        }
    }

    func testRepositoryRejectsEveryDuplicateStableIDWithoutCrashing()
        throws {
        let sourceData = try resourceData(
            name: RegimenAnalysisContentRepository.resourceName
        )
        let arrayKeys = [
            "sources",
            "cards",
            "ingredientProfiles",
            "safetyRules"
        ]

        for arrayKey in arrayKeys {
            var root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: sourceData)
                    as? [String: Any]
            )
            var values = try XCTUnwrap(
                root[arrayKey] as? [[String: Any]]
            )
            values.append(try XCTUnwrap(values.first))
            root[arrayKey] = values
            let mutatedData = try JSONSerialization.data(
                withJSONObject: root,
                options: [.sortedKeys]
            )

            let state = RegimenAnalysisContentRepository(
                data: mutatedData,
                exposure: .candidate
            ).state
            guard case let .unavailable(.invalidContent(issues)) = state
            else {
                XCTFail(
                    "Expected fail-closed duplicate rejection for \(arrayKey)"
                )
                continue
            }
            XCTAssertTrue(
                issues.contains { $0.code == "duplicate-id" },
                "Expected duplicate-id issue for \(arrayKey)"
            )
        }
    }

    func testAccessibilityUpdateIdentityTracksStatusAndPrimaryStopReason()
        throws {
        let pack = try candidatePack()
        let semanticRequest = request(
            items: [
                item(position: 0, ingredientIDs: ["estradiol"])
            ]
        )
        let ready = RegimenAnalysisAccessibilityUpdate(
            snapshot: RegimenAnalysisEngine.evaluate(
                request: semanticRequest,
                safetyContext: clearedSafety,
                pack: pack
            )
        )
        let unanswered = RegimenAnalysisAccessibilityUpdate(
            snapshot: RegimenAnalysisEngine.evaluate(
                request: semanticRequest,
                safetyContext: .unanswered,
                pack: pack
            )
        )
        let acuteStop = RegimenAnalysisAccessibilityUpdate(
            snapshot: RegimenAnalysisEngine.evaluate(
                request: semanticRequest,
                safetyContext: .init(
                    ageBand: .adult,
                    pregnancyPossibility: .notApplicable,
                    acuteConcern: .yes,
                    knownVteHistoryOrRisk: .no,
                    knownMeningiomaHistory: .no
                ),
                pack: pack
            )
        )
        let ageStop = RegimenAnalysisAccessibilityUpdate(
            snapshot: RegimenAnalysisEngine.evaluate(
                request: semanticRequest,
                safetyContext: .init(
                    ageBand: .unknown,
                    pregnancyPossibility: .notApplicable,
                    acuteConcern: .no,
                    knownVteHistoryOrRisk: .no,
                    knownMeningiomaHistory: .no
                ),
                pack: pack
            )
        )

        XCTAssertEqual(ready.semanticKey, "ready")
        XCTAssertTrue(ready.announcement.contains("可以显示"))
        XCTAssertEqual(unanswered.semanticKey, "unanswered")
        XCTAssertTrue(unanswered.announcement.contains("未选择"))
        XCTAssertNotEqual(acuteStop.semanticKey, ageStop.semanticKey)
        XCTAssertTrue(acuteStop.semanticKey.hasPrefix("stopped:"))
        XCTAssertTrue(acuteStop.announcement.contains("停止 App 分析"))
        XCTAssertTrue(ageStop.announcement.contains("停止 App 分析"))
    }

    func testValidatorRejectsIncompleteFrozenIngredientCoverage() throws {
        let base = try candidatePack()
        let manifest = RegimenAnalysisManifest(
            schemaVersion: base.manifest.schemaVersion,
            contentPackVersion: base.manifest.contentPackVersion,
            ruleSetVersion: base.manifest.ruleSetVersion,
            requiredCatalogVersion:
                base.manifest.requiredCatalogVersion,
            requiredCatalogContentDigest:
                base.manifest.requiredCatalogContentDigest,
            generatedAt: base.manifest.generatedAt,
            coverageStatement: base.manifest.coverageStatement,
            contentDigest: "",
            requiredIngredientIDs:
                Array(base.manifest.requiredIngredientIDs.dropLast()),
            globalBoundaryCardIDs: base.manifest.globalBoundaryCardIDs,
            limitedCardIDs: base.manifest.limitedCardIDs,
            review: base.manifest.review,
            medicalClassificationStatus:
                base.manifest.medicalClassificationStatus
        )
        let incomplete = withDigest(
            RegimenAnalysisContentPack(
                manifest: manifest,
                sources: base.sources,
                cards: base.cards,
                ingredientProfiles: base.ingredientProfiles,
                safetyRules: base.safetyRules
            )
        )
        XCTAssertTrue(
            RegimenAnalysisContentValidator.issues(
                in: incomplete,
                exposure: .candidate
            ).contains { $0.code == "incomplete-ingredient-coverage" }
        )
    }

    func testReleaseStateIsExplicitlyPendingAndCandidateExcluded() throws {
        let data = try resourceData(
            name: RegimenAnalysisContentRepository.releaseStateResourceName
        )
        let manifest = try JSONDecoder().decode(
            RegimenAnalysisReleaseStateManifest.self,
            from: data
        )
        XCTAssertEqual(
            manifest.status,
            .pendingHumanReviewAndClassification
        )
        XCTAssertTrue(manifest.candidateResourceExcluded)
        XCTAssertFalse(manifest.medicalClassificationResolved)
        XCTAssertEqual(
            RegimenAnalysisContentRepository.releaseState(data: data),
            .unavailable(.pendingHumanReviewAndClassification)
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )
        object["expression"] = "ignored-by-Codable"
        let mutated = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        guard case let .unavailable(.unreadableContent(message)) =
            RegimenAnalysisContentRepository.releaseState(data: mutated)
        else {
            XCTFail("Expected strict Release state schema failure")
            return
        }
        XCTAssertTrue(message.contains("expression"))
    }

    func testEveryExternalURLIsFixedHTTPSWithoutUserContextComponents() throws {
        for source in try candidatePack().sources {
            let components = try XCTUnwrap(
                URLComponents(string: source.officialURL)
            )
            XCTAssertEqual(components.scheme, "https")
            XCTAssertNotNil(components.host)
            XCTAssertNil(components.query)
            XCTAssertNil(components.fragment)
        }
    }

    private var clearedSafety: RegimenAnalysisSafetyContext {
        .init(
            ageBand: .adult,
            pregnancyPossibility: .notApplicable,
            acuteConcern: .no,
            knownVteHistoryOrRisk: .no,
            knownMeningiomaHistory: .no
        )
    }

    private func item(
        position: Int,
        ingredientIDs: [String],
        name: String = "记录药品",
        form: String = "记录剂型",
        dose: String = "用户原文",
        unit: String = "用户单位",
        catalogVersion: String = "medication-catalog-2026.07.30-candidate.2",
        status: RegimenAnalysisItemSnapshotStatus = .verifiedCatalogSnapshot
    ) -> RegimenAnalysisRequestV1.Item {
        RegimenAnalysisRequestV1.Item(
            itemID: UUID(
                uuidString: String(
                    format: "00000000-0000-0000-0000-%012d",
                    position + 1
                )
            )!,
            position: position,
            displayNameOriginal: name,
            dosageFormOriginal: form,
            routeOriginal: "记录途径",
            doseOriginal: dose,
            unitOriginal: unit,
            scheduleSummaryOriginal: "记录计划",
            catalogVersion: catalogVersion,
            presentationID: "test.presentation.\(position)",
            exactIngredientIDs: ingredientIDs,
            snapshotStatus: status
        )
    }

    private func request(
        items: [RegimenAnalysisRequestV1.Item]
    ) -> RegimenAnalysisRequestV1 {
        RegimenAnalysisRequestV1(
            schemaVersion: "1",
            regimenVersionID: UUID(
                uuidString: "10000000-0000-0000-0000-000000000001"
            )!,
            regimenCode: "R-TEST",
            regimenTitle: "测试方案",
            effectiveStartDate: "2026-07-30",
            items: items
        )
    }

    private func candidatePack() throws -> RegimenAnalysisContentPack {
        try JSONDecoder().decode(
            RegimenAnalysisContentPack.self,
            from: resourceData(
                name: RegimenAnalysisContentRepository.resourceName
            )
        )
    }

    private func resourceData(name: String) throws -> Data {
        let bundles = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        let url = try XCTUnwrap(
            bundles.lazy.compactMap {
                $0.url(forResource: name, withExtension: "json")
            }.first
        )
        return try Data(contentsOf: url)
    }

    private func replacingManifest(
        in pack: RegimenAnalysisContentPack,
        review: RegimenAnalysisReview,
        classification: RegimenAnalysisClassificationStatus
    ) -> RegimenAnalysisContentPack {
        RegimenAnalysisContentPack(
            manifest: RegimenAnalysisManifest(
                schemaVersion: pack.manifest.schemaVersion,
                contentPackVersion: pack.manifest.contentPackVersion
                    .replacingOccurrences(
                        of: "-candidate.",
                        with: "-release."
                    ),
                ruleSetVersion: pack.manifest.ruleSetVersion
                    .replacingOccurrences(
                        of: "-candidate.",
                        with: "-release."
                    ),
                requiredCatalogVersion:
                    pack.manifest.requiredCatalogVersion,
                requiredCatalogContentDigest:
                    pack.manifest.requiredCatalogContentDigest,
                generatedAt: pack.manifest.generatedAt,
                coverageStatement: pack.manifest.coverageStatement,
                contentDigest: "",
                requiredIngredientIDs:
                    pack.manifest.requiredIngredientIDs,
                globalBoundaryCardIDs: pack.manifest.globalBoundaryCardIDs,
                limitedCardIDs: pack.manifest.limitedCardIDs,
                review: review,
                medicalClassificationStatus: classification
            ),
            sources: pack.sources,
            cards: pack.cards,
            ingredientProfiles: pack.ingredientProfiles,
            safetyRules: pack.safetyRules
        )
    }

    private func withDigest(
        _ pack: RegimenAnalysisContentPack
    ) -> RegimenAnalysisContentPack {
        let digest = RegimenAnalysisContentDigest.contentDigest(for: pack)
        return RegimenAnalysisContentPack(
            manifest: RegimenAnalysisManifest(
                schemaVersion: pack.manifest.schemaVersion,
                contentPackVersion: pack.manifest.contentPackVersion,
                ruleSetVersion: pack.manifest.ruleSetVersion,
                requiredCatalogVersion:
                    pack.manifest.requiredCatalogVersion,
                requiredCatalogContentDigest:
                    pack.manifest.requiredCatalogContentDigest,
                generatedAt: pack.manifest.generatedAt,
                coverageStatement: pack.manifest.coverageStatement,
                contentDigest: digest,
                requiredIngredientIDs:
                    pack.manifest.requiredIngredientIDs,
                globalBoundaryCardIDs: pack.manifest.globalBoundaryCardIDs,
                limitedCardIDs: pack.manifest.limitedCardIDs,
                review: pack.manifest.review,
                medicalClassificationStatus:
                    pack.manifest.medicalClassificationStatus
            ),
            sources: pack.sources,
            cards: pack.cards,
            ingredientProfiles: pack.ingredientProfiles,
            safetyRules: pack.safetyRules
        )
    }
}

@MainActor
final class RegimenAnalysisRenderTests: XCTestCase {
    func testAnalysisRendersAtRepresentativeSizes() throws {
        let pack = try candidatePack()
        for size in [
            CGSize(width: 320, height: 568),
            CGSize(width: 390, height: 844),
            CGSize(width: 430, height: 932),
            CGSize(width: 768, height: 1_024),
            CGSize(width: 844, height: 390),
            CGSize(width: 1_024, height: 768)
        ] {
            let image = try render(
                size: size,
                dynamicTypeSize: .large,
                pack: pack
            )
            XCTAssertEqual(image.size, size)
            let attachment = XCTAttachment(image: image)
            attachment.name = "RegimenAnalysis-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testAnalysisRendersAtAccessibilityFiveOnNarrowPhone() throws {
        let size = CGSize(width: 320, height: 568)
        let image = try render(
            size: size,
            dynamicTypeSize: .accessibility5,
            pack: candidatePack()
        )
        XCTAssertEqual(image.size, size)
        let attachment = XCTAttachment(image: image)
        attachment.name = "RegimenAnalysis-320x568-AX5"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testReadyAnalysisRendersAtPhoneAndTabletSizes() throws {
        let pack = try candidatePack()
        for size in [
            CGSize(width: 390, height: 844),
            CGSize(width: 768, height: 1_024)
        ] {
            let image = try render(
                size: size,
                dynamicTypeSize: .large,
                pack: pack,
                initialSafetyContext: .init(
                    ageBand: .adult,
                    pregnancyPossibility: .notApplicable,
                    acuteConcern: .no,
                    knownVteHistoryOrRisk: .no,
                    knownMeningiomaHistory: .no
                )
            )
            XCTAssertEqual(image.size, size)
            let attachment = XCTAttachment(image: image)
            attachment.name =
                "RegimenAnalysis-Ready-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func candidatePack() throws -> RegimenAnalysisContentPack {
        let bundles = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        let url = try XCTUnwrap(
            bundles.lazy.compactMap {
                $0.url(
                    forResource: RegimenAnalysisContentRepository.resourceName,
                    withExtension: "json"
                )
            }.first
        )
        return try JSONDecoder().decode(
            RegimenAnalysisContentPack.self,
            from: Data(contentsOf: url)
        )
    }

    private func render(
        size: CGSize,
        dynamicTypeSize: DynamicTypeSize,
        pack: RegimenAnalysisContentPack,
        initialSafetyContext: RegimenAnalysisSafetyContext = .unanswered
    ) throws -> UIImage {
        let controller = UIHostingController(
            rootView: RegimenAnalysisView(
                regimen: RegimenAnalysisDebugFixture.regimen,
                loadState: .available(pack),
                initialSafetyContext: initialSafetyContext
            )
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
