import Foundation
import XCTest
@testable import Unmanual

final class OfflineContextualContentTests: XCTestCase {
    func testValidPackLoadsAndEmptyQueryUsesDisplayOrder() throws {
        let repository = OfflineContextualContentRepository(
            data: try minimalPackData(),
            exposure: .candidate,
            statusDate: try utcDate("2026-07-31")
        )

        let snapshot = try XCTUnwrap(repository.state.snapshot)
        XCTAssertEqual(snapshot.cards.map(\.id), ["card.alpha", "card.beta"])
        XCTAssertEqual(
            snapshot.search(
                query: "",
                category: nil,
                favoriteIDs: [],
                favoritesOnly: false
            ).cards.map(\.id),
            ["card.alpha", "card.beta"]
        )
        XCTAssertEqual(
            snapshot.cards(for: .regimenField).map(\.id),
            ["card.alpha"]
        )
    }

    func testRawJSONBoundariesFailClosedBeforeTypedDecode() throws {
        try assertInvalid(
            replacing(
                "\"schemaVersion\": \"1\",",
                with: """
                "schemaVersion": "1",
                            "schemaVersion": "1",
                """,
                in: minimalPackData()
            ),
            code: "json.duplicateKey"
        )
        try assertInvalid(
            replacing(
                "\"schemaVersion\": \"1\",",
                with: """
                "schemaVersion": "1",
                            "unexpected": true,
                """,
                in: minimalPackData()
            ),
            code: "shape.exactKeys"
        )
        try assertInvalid(
            replacing(
                "\"sourceCount\": 1",
                with: "\"sourceCount\": 1.0",
                in: minimalPackData()
            ),
            code: "number.noncanonical"
        )
    }

    func testRawScannerRejectsEscapedDuplicatesSizeDepthStringsAndInvalidUTF8()
        throws {
        try assertInvalid(
            replacing(
                "\"schemaVersion\": \"1\",",
                with: """
                "schemaVersion": "1",
                            "\\u0073chemaVersion": "1",
                """,
                in: minimalPackData()
            ),
            code: "json.duplicateKey"
        )
        try assertInvalid(
            Data(
                repeating: 0x20,
                count:
                    OfflineContextualContentLimits.maximumJSONBytes + 1
            ),
            code: "input.tooLarge"
        )
        let excessiveDepth = Data(
            (
                String(
                    repeating: "[",
                    count:
                        OfflineContextualContentLimits.maximumDepth + 2
                )
                    + "0"
                    + String(
                        repeating: "]",
                        count:
                            OfflineContextualContentLimits.maximumDepth + 2
                    )
            ).utf8
        )
        try assertInvalid(
            excessiveDepth,
            code: "json.excessiveDepth"
        )
        let oversizedString = Data(
            (
                "{\"value\":\""
                    + String(
                        repeating: "a",
                        count:
                            OfflineContextualContentLimits
                                .maximumStringBytes + 1
                    )
                    + "\"}"
            ).utf8
        )
        try assertInvalid(
            oversizedString,
            code: "json.stringTooLarge"
        )
        try assertInvalid(
            Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x30, 0x7D]),
            code: "json.invalid"
        )
    }

    func testCanonicalJSONHasFrozenNFCAndByteOrderingVector() {
        let value = OfflineContextualJSONValue.object([
            "z": .string("e\u{301}\n"),
            "a": .array([.integer(0), .bool(true), .null])
        ])

        XCTAssertEqual(
            String(
                data: OfflineContextualContentCanonicalJSON.encode(value),
                encoding: .utf8
            ),
            "{\"a\":[0,true,null],\"z\":\"é\\n\"}"
        )
        XCTAssertEqual(
            OfflineContextualContentCanonicalJSON.digest(value),
            "e69f3482e95fa151dbc754f52dcc343d7b7d678d785e9d57b599b9bd5f0de913"
        )
    }

    func testIntegrityReferencesAndFixedURLsFailClosed() throws {
        try assertInvalid(
            replacing(
                "\"第一张摘要。\"",
                with: "\"已被篡改的摘要。\"",
                in: minimalPackData()
            ),
            code: "integrity.cardDigest"
        )
        try assertInvalid(
            replacing(
                "\"sourceIDs\": [\"source.one\"]",
                with: "\"sourceIDs\": [\"source.missing\"]",
                in: minimalPackData()
            ),
            code: "reference.source"
        )
        try assertInvalid(
            replacing(
                "https://www.who.int/test",
                with: "https://www.who.int/test?query=leak",
                in: minimalPackData()
            ),
            code: "url.invalid"
        )
    }

    func testSemanticValidatorRejectsFrozenContractMutations() throws {
        let mutations: [(Data, String)] = [
            (
                try replacing(
                    "\"schemaVersion\": \"1\"",
                    with: "\"schemaVersion\": \"2\"",
                    in: minimalPackData()
                ),
                "manifest.schemaVersion"
            ),
            (
                try replacing(
                    "fbf4f02b6122deeb0ccce427bd6904ec4ae192e0fdd2ee7c89237cec3034732c",
                    with: String(repeating: "0", count: 64),
                    in: minimalPackData()
                ),
                "integrity.contentDigest"
            ),
            (
                try replacing(
                    "\"id\": \"card.beta\"",
                    with: "\"id\": \"card_beta\"",
                    in: minimalPackData()
                ),
                "id.invalid"
            ),
            (
                try replacing(
                    "\"displayOrder\": 2",
                    with: "\"displayOrder\": 1",
                    in: minimalPackData()
                ),
                "order.duplicate"
            ),
            (
                try replacing(
                    "\"retrievedAt\": \"2026-07-01\"",
                    with: "\"retrievedAt\": \"2027-07-02\"",
                    in: minimalPackData()
                ),
                "date.order"
            ),
            (
                try replacing(
                    "\"licenseIdentifier\": \"rights-reserved-link-only\"",
                    with: "\"licenseIdentifier\": \"CC-BY-SA-4.0\"",
                    in: minimalPackData()
                ),
                "license.linkOnly"
            ),
            (
                try replacing(
                    "\"distributionMode\": \"linkOnly\"",
                    with: "\"distributionMode\": \"redistributable\"",
                    in: minimalPackData()
                ),
                "license.redistributable"
            ),
            (
                try replacing(
                    "\"creator\": \"MtF Manual contributors\"",
                    with: "\"creator\": \"\"",
                    in: minimalPackData()
                ),
                "attribution.invalid"
            ),
            (
                try replacing(
                    "\"sourceRepository\": \"https://github.com/AwantedRaccoon/MTF-Unmanual\"",
                    with: "\"sourceRepository\": \"https://github.com/other/project\"",
                    in: minimalPackData()
                ),
                "provenance.repository"
            ),
            (
                try replacing(
                    "\"sourcePath\": \"cards/zh-CN/beta.md\"",
                    with: "\"sourcePath\": \"C:/local/beta.md\"",
                    in: minimalPackData()
                ),
                "provenance.path"
            ),
            (
                try replacing(
                    "\"sourcePath\": \"cards/zh-CN/beta.md\"",
                    with: "\"sourcePath\": \"~/beta.md\"",
                    in: minimalPackData()
                ),
                "provenance.path"
            ),
            (
                try replacing(
                    "\"sourcePath\": \"cards/zh-CN/alpha.md\"",
                    with: "\"sourcePath\": \"cards/zh-CN/beta.md\"",
                    in: minimalPackData()
                ),
                "provenance.pathDigest"
            )
        ]

        for (data, code) in mutations {
            try assertInvalid(data, code: code)
        }
    }

    func testCapacityRejectsMoreThanOneHundredCards() throws {
        let oversized = try OfflineContextualContentTestSigning.resign(
            minimalPackData()
        ) { root in
            let templates =
                try OfflineContextualContentTestSigning
                    .requireArrayOfDictionaries(root["cards"])
            let template = templates[0]
            var cards: [[String: Any]] = []
            var anchors: [[String: Any]] = []
            for index in 0...100 {
                let id = "card.capacity-\(index)"
                var card = template
                card["id"] = id
                card["displayOrder"] = index
                card["originalURL"] =
                    "https://github.com/AwantedRaccoon/MTF-Unmanual/"
                    + "blob/"
                    + "f39474389831840366c23fd274208319802bf2a5/"
                    + "cards/zh-CN/capacity-\(index).md"
                var provenance =
                    try OfflineContextualContentTestSigning
                        .requireDictionary(card["provenance"])
                provenance["sourcePath"] =
                    "cards/zh-CN/capacity-\(index).md"
                card["provenance"] = provenance
                cards.append(card)
                anchors.append([
                    "id": "anchor.pocket-capacity-\(index)",
                    "scenario": "pocketAppendix",
                    "purpose": "容量测试。",
                    "displayOrder": index,
                    "cardID": id
                ])
            }
            let firstID = "card.capacity-0"
            for (index, scenario) in [
                "regimenField",
                "labRecording",
                "regimenAnalysisSource",
                "visitPreparation",
                "timelineRecord"
            ].enumerated() {
                anchors.append([
                    "id": "anchor.capacity-extra-\(index)",
                    "scenario": scenario,
                    "purpose": "容量测试。",
                    "displayOrder": 1,
                    "cardID": firstID
                ])
            }
            root["cards"] = cards
            root["scenarioAnchors"] = anchors
            var manifest =
                try OfflineContextualContentTestSigning
                    .requireDictionary(root["manifest"])
            manifest["cardCount"] = cards.count
            manifest["scenarioAnchorCount"] = anchors.count
            root["manifest"] = manifest
        }

        try assertInvalid(oversized, code: "capacity.count")
    }

    func testFixedURLRejectsEveryFrozenBypassClass() throws {
        let invalidURLs = [
            "https://www.who.int/test#fragment",
            "https://user@www.who.int/test",
            "https://www.who.int:443/test",
            "https://www.who.int:/test",
            "https://www.who.int./test",
            "https://127.0.0.1/test",
            "https://www.who.int/a/../test",
            "https://www.who.int/a/%2F/test",
            "https://www.who.int/a/%5C/test",
            "https://www.who.int/a/%40/test",
            "http://www.who.int/test",
            "https://example.com/test"
        ]
        for invalidURL in invalidURLs {
            try assertInvalid(
                replacing(
                    "https://www.who.int/test",
                    with: invalidURL,
                    in: minimalPackData()
                ),
                code: "url.invalid"
            )
        }
    }

    func testCandidateCannotLoadThroughReleaseExposure() throws {
        let repository = OfflineContextualContentRepository(
            data: try minimalPackData(),
            exposure: .release,
            statusDate: try utcDate("2026-07-31")
        )

        guard case let .unavailable(.invalidContent(issues)) =
            repository.state else {
            return XCTFail("candidate 内容不得通过 Release exposure")
        }
        XCTAssertTrue(
            issues.contains { $0.code == "exposure.review" },
            "\(issues)"
        )
    }

    func testApprovedReleaseRequiresCurrentAvailableSources() throws {
        let approved = try approvedPackData(sourceUnavailable: false)
        XCTAssertNotNil(
            OfflineContextualContentRepository(
                data: approved,
                exposure: .release,
                statusDate: try utcDate("2026-07-31")
            ).state.snapshot
        )

        let expired = OfflineContextualContentRepository(
            data: approved,
            exposure: .release,
            statusDate: try utcDate("2027-07-02")
        )
        try assertInvalid(
            expired.state,
            code: "exposure.current"
        )

        let unavailable = OfflineContextualContentRepository(
            data: try approvedPackData(sourceUnavailable: true),
            exposure: .release,
            statusDate: try utcDate("2026-07-31")
        )
        try assertInvalid(
            unavailable.state,
            code: "exposure.current"
        )
    }

    func testStatusUsesUTCExpiryAndSourceUnavailablePriority() throws {
        let expiryDay = OfflineContextualContentRepository(
            data: try minimalPackData(),
            exposure: .candidate,
            statusDate: try utcDate("2027-07-01")
        )
        XCTAssertEqual(
            try XCTUnwrap(expiryDay.state.snapshot)
                .cards.map(\.status),
            [.current, .current]
        )

        let nextDay = OfflineContextualContentRepository(
            data: try minimalPackData(),
            exposure: .candidate,
            statusDate: try utcDate("2027-07-02")
        )
        XCTAssertEqual(
            try XCTUnwrap(nextDay.state.snapshot)
                .cards.map(\.status),
            [.stale, .stale]
        )

        let unavailableSource = OfflineContextualContentRepository(
            data: try OfflineContextualContentTestSigning.resign(
                minimalPackData()
            ) { root in
                var sources =
                    try OfflineContextualContentTestSigning
                        .requireArrayOfDictionaries(root["sources"])
                sources[0]["sourceStatus"] = "knownUnavailable"
                root["sources"] = sources
            },
            exposure: .candidate,
            statusDate: try utcDate("2028-08-01")
        )
        XCTAssertEqual(
            try XCTUnwrap(unavailableSource.state.snapshot)
                .cards.map(\.status),
            [.sourceUnavailable, .sourceUnavailable]
        )
    }

    func testDatesRejectSignedComponentsAtEveryContractLayer() throws {
        XCTAssertNil(UTCDateParser.date("+026-+7-+7"))

        for data in [
            try replacing(
                "\"generatedAt\": \"2026-07-31\"",
                with: "\"generatedAt\": \"+026-+7-+7\"",
                in: minimalPackData()
            ),
            try replacing(
                "\"retrievedAt\": \"2026-07-01\"",
                with: "\"retrievedAt\": \"+026-+7-+1\"",
                in: minimalPackData()
            ),
            try replacing(
                "\"expiresAt\": \"2027-07-31\"",
                with: "\"expiresAt\": \"+027-+7-+1\"",
                in: minimalPackData()
            )
        ] {
            try assertInvalid(data, code: "date.invalid")
        }

        let signedCompletedAt =
            try OfflineContextualContentTestSigning.resign(
                minimalPackData()
            ) { root in
                var manifest =
                    try OfflineContextualContentTestSigning
                        .requireDictionary(root["manifest"])
                var review =
                    try OfflineContextualContentTestSigning
                        .requireDictionary(manifest["review"])
                review["status"] = "approved"
                review["contentReviewerDisplayName"] = "内容复核员"
                review["medicalReviewerDisplayName"] = "医疗复核员"
                review["completedAt"] = "+026-+7-+1"
                manifest["review"] = review
                manifest["classificationStatus"] = "resolved"
                root["manifest"] = manifest
            }
        let repository = OfflineContextualContentRepository(
            data: signedCompletedAt,
            exposure: .release,
            statusDate: try utcDate("2026-07-31")
        )
        try assertInvalid(
            repository.state,
            code: "review.approvedShape"
        )
    }

    func testContentVersionMustBeSupportedAndBoundAcrossPack() throws {
        XCTAssertTrue(
            OfflineContextualContentVersionContract
                .releaseStateMatchesPack(
                    releaseStateVersion:
                        "offline-contextual-content-candidate.1",
                    packVersion:
                        "offline-contextual-content-candidate.1"
                )
        )
        XCTAssertFalse(
            OfflineContextualContentVersionContract
                .releaseStateMatchesPack(
                    releaseStateVersion:
                        "offline-contextual-content-candidate.1",
                    packVersion: "future-content.2"
                )
        )

        let unsupportedManifest =
            try OfflineContextualContentTestSigning.resign(
                minimalPackData()
            ) { root in
                var manifest =
                    try OfflineContextualContentTestSigning
                        .requireDictionary(root["manifest"])
                manifest["contentVersion"] = "future-content.2"
                root["manifest"] = manifest
            }
        try assertInvalid(
            unsupportedManifest,
            code: "manifest.contentVersion"
        )

        let mismatchedCard =
            try OfflineContextualContentTestSigning.resign(
                minimalPackData()
            ) { root in
                var cards =
                    try OfflineContextualContentTestSigning
                        .requireArrayOfDictionaries(root["cards"])
                cards[0]["contentVersion"] = "future-content.2"
                root["cards"] = cards
            }
        try assertInvalid(
            mismatchedCard,
            code: "card.contentVersion"
        )
    }

    func testApprovedReviewCompletionDateMustBeChronological() throws {
        let predatingPack = try approvedPackData(
            sourceUnavailable: false,
            completedAt: "0001-01-01"
        )
        try assertInvalid(
            OfflineContextualContentRepository(
                data: predatingPack,
                exposure: .release,
                statusDate: try utcDate("2026-07-31")
            ).state,
            code: "review.dateOrder"
        )

        let afterStatusDate = try approvedPackData(
            sourceUnavailable: false,
            completedAt: "2026-08-01"
        )
        try assertInvalid(
            OfflineContextualContentRepository(
                data: afterStatusDate,
                exposure: .release,
                statusDate: try utcDate("2026-07-31")
            ).state,
            code: "exposure.reviewDate"
        )
    }

    func testSearchNormalizesWidthUsesTokenANDAndRejectsOversizedQuery()
        throws {
        let snapshot = try XCTUnwrap(
            OfflineContextualContentRepository(
                data: try minimalPackData(),
                exposure: .candidate,
                statusDate: try utcDate("2026-07-31")
            ).state.snapshot
        )

        XCTAssertEqual(
            snapshot.search(
                query: "ＡＬＰＨＡ",
                category: nil,
                favoriteIDs: [],
                favoritesOnly: false
            ).cards.map(\.id),
            ["card.alpha"]
        )
        XCTAssertEqual(
            snapshot.search(
                query: "第一 摘要",
                category: nil,
                favoriteIDs: [],
                favoritesOnly: false
            ).cards.map(\.id),
            ["card.alpha"]
        )

        let oversized = snapshot.search(
            query: String(repeating: "甲", count: 81),
            category: nil,
            favoriteIDs: [],
            favoritesOnly: false
        )
        XCTAssertEqual(oversized.cards, [])
        XCTAssertEqual(oversized.issue, .tooLong)

        let tooManyTokens = snapshot.search(
            query: "一 二 三 四 五 六 七 八 九",
            category: nil,
            favoriteIDs: [],
            favoritesOnly: false
        )
        XCTAssertEqual(tooManyTokens.cards, [])
        XCTAssertEqual(tooManyTokens.issue, .tooManyTokens)

        let compatibilityExpansion = snapshot.search(
            query: String(repeating: "\u{FDFA}", count: 5),
            category: nil,
            favoriteIDs: [],
            favoritesOnly: false
        )
        XCTAssertEqual(compatibilityExpansion.cards, [])
        XCTAssertEqual(compatibilityExpansion.issue, .tooLong)
    }

    func testSearchUsesFrozenSevenRanksBeforeDisplayOrder() {
        let cards = [
            searchCard(
                id: "card.rank-seven",
                title: "其他",
                summary: "含 questionAnswer",
                displayOrder: 1
            ),
            searchCard(
                id: "card.rank-six",
                title: "其他",
                contentType: .questionAnswer,
                displayOrder: 2
            ),
            searchCard(
                id: "card.rank-five",
                title: "其他",
                aliases: ["前 questionAnswer 后"],
                displayOrder: 3
            ),
            searchCard(
                id: "card.rank-four",
                title: "其他",
                aliases: ["questionAnswer"],
                displayOrder: 4
            ),
            searchCard(
                id: "card.rank-three",
                title: "前 questionAnswer 后",
                displayOrder: 5
            ),
            searchCard(
                id: "card.rank-two",
                title: "questionAnswer 后",
                displayOrder: 6
            ),
            searchCard(
                id: "card.rank-one",
                title: "questionAnswer",
                displayOrder: 7
            )
        ]

        XCTAssertEqual(
            OfflineContextualContentSearch.search(
                cards: cards,
                query: "QUESTIONANSWER",
                category: nil,
                favoriteIDs: [],
                favoritesOnly: false
            ).cards.map(\.id),
            [
                "card.rank-one",
                "card.rank-two",
                "card.rank-three",
                "card.rank-four",
                "card.rank-five",
                "card.rank-six",
                "card.rank-seven"
            ]
        )
    }

    func testSearchMatchesVisibleChineseCategoryAndContentTypeLabels() {
        let card = searchCard(
            id: "card.visible-labels",
            title: "其他",
            contentType: .questionAnswer,
            category: .mentalWellbeing,
            displayOrder: 1
        )

        for query in ["心理与支持", "问题摘要"] {
            XCTAssertEqual(
                OfflineContextualContentSearch.search(
                    cards: [card],
                    query: query,
                    category: nil,
                    favoriteIDs: [],
                    favoritesOnly: false
                ).cards.map(\.id),
                ["card.visible-labels"],
                query
            )
        }
    }

    func testMultiTokenRankingComparesWorstToBestAndIgnoresTokenOrder() {
        let mixed = searchCard(
            id: "card.mixed",
            title: "alpha",
            summary: "beta",
            displayOrder: 1
        )
        let balanced = searchCard(
            id: "card.balanced",
            title: "其他",
            aliases: ["x alpha", "x beta"],
            displayOrder: 2
        )
        let first = OfflineContextualContentSearch.search(
            cards: [mixed, balanced],
            query: "alpha beta",
            category: nil,
            favoriteIDs: [],
            favoritesOnly: false
        )
        let reversed = OfflineContextualContentSearch.search(
            cards: [balanced, mixed],
            query: "beta alpha",
            category: nil,
            favoriteIDs: [],
            favoritesOnly: false
        )

        XCTAssertEqual(
            first.cards.map(\.id),
            ["card.balanced", "card.mixed"]
        )
        XCTAssertEqual(
            reversed.cards.map(\.id),
            ["card.balanced", "card.mixed"]
        )
    }

    private func minimalPackData() throws -> Data {
        let json = """
        {
          "manifest": {
            "schemaVersion": "1",
            "contentVersion": "offline-contextual-content-candidate.1",
            "locale": "zh-Hans",
            "generatedAt": "2026-07-31",
            "retrievedAt": "2026-07-31",
            "expiresAt": "2027-07-31",
            "sourceCommit": "f39474389831840366c23fd274208319802bf2a5",
            "contentDigest": "fbf4f02b6122deeb0ccce427bd6904ec4ae192e0fdd2ee7c89237cec3034732c",
            "sourceCount": 1,
            "cardCount": 2,
            "scenarioAnchorCount": 6,
            "review": {
              "status": "candidate",
              "ownerRole": "内容与医疗复核责任人",
              "contentReviewerDisplayName": null,
              "medicalReviewerDisplayName": null,
              "completedAt": null,
              "scope": "测试候选内容"
            },
            "classificationStatus": "pending"
          },
          "sources": [
            {
              "id": "source.one",
              "rightsHolder": "World Health Organization",
              "title": "Test bibliography",
              "versionOrPublishedAt": "2026-01-01",
              "retrievedAt": "2026-07-01",
              "expiresAt": "2027-07-01",
              "sourceStatus": "current",
              "url": "https://www.who.int/test",
              "licenseIdentifier": "rights-reserved-link-only",
              "licenseURL": null,
              "distributionMode": "linkOnly",
              "applicableRegions": ["global"],
              "applicablePopulations": ["public"],
              "boundary": "只保存书目信息和固定链接。"
            }
          ],
          "cards": [
            {
              "id": "card.beta",
              "title": "第二张",
              "summary": "第二张摘要。",
              "applicabilityBoundary": "只用于测试。",
              "contentType": "questionAnswer",
              "category": "identityAndTerms",
              "aliases": ["Beta"],
              "sourceIDs": ["source.one"],
              "displayOrder": 2,
              "contentVersion": "offline-contextual-content-candidate.1",
              "cardDigest": "11ec8710ce660d922b193955f1796db520962dee81755f0c81bdcf83f50f77cf",
              "retrievedAt": "2026-07-31",
              "expiresAt": "2027-07-31",
              "originalURL": "https://github.com/AwantedRaccoon/MTF-Unmanual/blob/f39474389831840366c23fd274208319802bf2a5/cards/zh-CN/beta.md",
              "provenance": {
                "sourceRepository": "https://github.com/AwantedRaccoon/MTF-Unmanual",
                "sourceCommit": "f39474389831840366c23fd274208319802bf2a5",
                "sourcePath": "cards/zh-CN/beta.md",
                "sourceFileSHA256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "adaptationStatus": "modified",
                "modificationNote": "测试摘要。"
              }
            },
            {
              "id": "card.alpha",
              "title": "第一张",
              "summary": "第一张摘要。",
              "applicabilityBoundary": "只用于测试。",
              "contentType": "recordingGuide",
              "category": "recordsAndVisits",
              "aliases": ["Alpha"],
              "sourceIDs": ["source.one"],
              "displayOrder": 1,
              "contentVersion": "offline-contextual-content-candidate.1",
              "cardDigest": "5ee89716f3cb8f67970785ce489e1842582bf8046855d885b58a867611271084",
              "retrievedAt": "2026-07-31",
              "expiresAt": "2027-07-31",
              "originalURL": "https://github.com/AwantedRaccoon/MTF-Unmanual/blob/f39474389831840366c23fd274208319802bf2a5/cards/zh-CN/alpha.md",
              "provenance": {
                "sourceRepository": "https://github.com/AwantedRaccoon/MTF-Unmanual",
                "sourceCommit": "f39474389831840366c23fd274208319802bf2a5",
                "sourcePath": "cards/zh-CN/alpha.md",
                "sourceFileSHA256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                "adaptationStatus": "modified",
                "modificationNote": "测试摘要。"
              }
            }
          ],
          "scenarioAnchors": [
            {
              "id": "anchor.regimen-field",
              "scenario": "regimenField",
              "purpose": "解释方案字段。",
              "displayOrder": 1,
              "cardID": "card.alpha"
            },
            {
              "id": "anchor.lab-recording",
              "scenario": "labRecording",
              "purpose": "解释化验记录。",
              "displayOrder": 1,
              "cardID": "card.alpha"
            },
            {
              "id": "anchor.regimen-analysis-source",
              "scenario": "regimenAnalysisSource",
              "purpose": "复用方案分析来源入口。",
              "displayOrder": 1,
              "cardID": "card.alpha"
            },
            {
              "id": "anchor.visit-preparation",
              "scenario": "visitPreparation",
              "purpose": "准备复诊。",
              "displayOrder": 1,
              "cardID": "card.alpha"
            },
            {
              "id": "anchor.timeline-record",
              "scenario": "timelineRecord",
              "purpose": "解释记录详情。",
              "displayOrder": 1,
              "cardID": "card.alpha"
            },
            {
              "id": "anchor.pocket-appendix",
              "scenario": "pocketAppendix",
              "purpose": "随身附页。",
              "displayOrder": 1,
              "cardID": "card.alpha"
            }
          ],
          "attribution": {
            "sourceRepository": "https://github.com/AwantedRaccoon/MTF-Unmanual",
            "sourceCommit": "f39474389831840366c23fd274208319802bf2a5",
            "creator": "MtF Manual contributors",
            "licenseIdentifier": "CC-BY-SA-4.0",
            "licenseURL": "https://creativecommons.org/licenses/by-sa/4.0/",
            "adaptationStatus": "modified",
            "modificationNote": "改编为 App 离线测试摘要。",
            "shareAlikeStatement": "改编内容按相同或兼容许可证共享。"
          }
        }
        """
        return try XCTUnwrap(json.data(using: .utf8))
    }

    private func assertInvalid(
        _ data: Data,
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let repository = OfflineContextualContentRepository(
            data: data,
            exposure: .candidate,
            statusDate: try utcDate("2026-07-31")
        )
        guard case let .unavailable(.invalidContent(issues)) =
            repository.state else {
            return XCTFail(
                "应 fail closed，实际为 \(repository.state)",
                file: file,
                line: line
            )
        }
        XCTAssertTrue(
            issues.contains { $0.code == code },
            "缺少 \(code)，实际为 \(issues)",
            file: file,
            line: line
        )
    }

    private func assertInvalid(
        _ state: OfflineContextualContentLoadState,
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard case let .unavailable(.invalidContent(issues)) = state else {
            return XCTFail(
                "应为 invalidContent，实际为 \(state)",
                file: file,
                line: line
            )
        }
        XCTAssertTrue(
            issues.contains { $0.code == code },
            "缺少 \(code)，实际为 \(issues)",
            file: file,
            line: line
        )
    }

    private func replacing(
        _ target: String,
        with replacement: String,
        in data: Data
    ) throws -> Data {
        let source = try XCTUnwrap(String(data: data, encoding: .utf8))
        let mutated = source.replacingOccurrences(
            of: target,
            with: replacement
        )
        XCTAssertNotEqual(source, mutated, "测试 mutation 必须命中原文")
        return try XCTUnwrap(mutated.data(using: .utf8))
    }

    private func searchCard(
        id: String,
        title: String,
        summary: String = "其他",
        aliases: [String] = [],
        contentType: OfflineContextualContentType = .recordingGuide,
        category: OfflineContextualContentCategory = .recordsAndVisits,
        displayOrder: Int
    ) -> OfflineContextualContentCardSnapshot {
        let card = OfflineContextualContentCard(
            id: id,
            title: title,
            summary: summary,
            applicabilityBoundary: "测试。",
            contentType: contentType,
            category: category,
            aliases: aliases,
            sourceIDs: [],
            displayOrder: displayOrder,
            contentVersion: "test",
            cardDigest: String(repeating: "a", count: 64),
            retrievedAt: "2026-07-31",
            expiresAt: "2027-07-31",
            originalURL: "https://www.who.int/test",
            provenance: OfflineContextualContentProvenance(
                sourceRepository: "https://github.com/test",
                sourceCommit: String(repeating: "a", count: 40),
                sourcePath: "test.md",
                sourceFileSHA256: String(repeating: "a", count: 64),
                adaptationStatus: .modified,
                modificationNote: "测试。"
            )
        )
        return OfflineContextualContentCardSnapshot(
            card: card,
            sources: [],
            status: .current
        )
    }

    private func approvedPackData(
        sourceUnavailable: Bool,
        completedAt: String = "2026-07-31"
    ) throws -> Data {
        try OfflineContextualContentTestSigning.resign(
            minimalPackData()
        ) { root in
            var manifest =
                try OfflineContextualContentTestSigning
                    .requireDictionary(root["manifest"])
            var review =
                try OfflineContextualContentTestSigning
                    .requireDictionary(manifest["review"])
            review["status"] = "approved"
            review["contentReviewerDisplayName"] = "内容复核员"
            review["medicalReviewerDisplayName"] = "医疗复核员"
            review["completedAt"] = completedAt
            manifest["review"] = review
            manifest["classificationStatus"] = "resolved"
            root["manifest"] = manifest
            if sourceUnavailable {
                var sources =
                    try OfflineContextualContentTestSigning
                        .requireArrayOfDictionaries(root["sources"])
                sources[0]["sourceStatus"] = "knownUnavailable"
                root["sources"] = sources
            }
        }
    }

    private func utcDate(_ value: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return try XCTUnwrap(formatter.date(from: value))
    }
}
