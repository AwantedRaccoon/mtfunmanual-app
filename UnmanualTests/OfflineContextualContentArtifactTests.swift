import Foundation
import XCTest
@testable import Unmanual

final class OfflineContextualContentArtifactTests: XCTestCase {
    func testBundleCandidatePolicyMatchesBuildConfiguration() {
#if DEBUG
        XCTAssertTrue(
            OfflineContextualContentBundleCandidatePolicy.isEnabled
        )
        XCTAssertEqual(
            OfflineContextualContentResourcePolicy.exposure,
            .candidate
        )
#else
        XCTAssertFalse(
            OfflineContextualContentBundleCandidatePolicy.isEnabled
        )
        XCTAssertEqual(
            OfflineContextualContentResourcePolicy.exposure,
            .release
        )
#endif
    }

    func testCheckedInCandidateHasFrozenCountsDigestsAndTypedStatuses()
        throws {
        let data = try Data(contentsOf: candidateURL)
        let repository = OfflineContextualContentRepository(
            data: data,
            exposure: .candidate,
            statusDate: try utcDate("2026-07-31")
        )

        let snapshot = try XCTUnwrap(repository.state.snapshot)
        XCTAssertEqual(snapshot.sources.count, 45)
        XCTAssertEqual(snapshot.cards.count, 48)
        XCTAssertEqual(snapshot.scenarioAnchors.count, 53)
        XCTAssertEqual(
            snapshot.cards.filter { $0.status == .stale }.map(\.id),
            [
                "guide.regimen-field",
                "guide.lab-recording",
                "guide.visit-preparation"
            ]
        )
        XCTAssertEqual(
            Set(snapshot.scenarioAnchors.map(\.scenario)),
            Set(OfflineContextualContentScenario.allCases)
        )
        XCTAssertEqual(
            snapshot.cards(for: .pocketAppendix).count,
            48
        )
    }

    func testCheckedInReleaseStateIsClosedAndCandidateIsReleaseExcluded()
        throws {
        let releaseData = try Data(contentsOf: releaseStateURL)
        let releaseRepository =
            OfflineContextualContentReleaseStateRepository(
                data: releaseData
            )
        guard case let .available(releaseState) =
            releaseRepository.state else {
            return XCTFail("checked-in release-state 必须严格可读")
        }
        XCTAssertEqual(
            releaseState.status,
            .pendingHumanReviewAndClassification
        )
        XCTAssertTrue(releaseState.candidateResourceExcluded)

        let projectYAML = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "project.yml"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            try releaseExclusionBlock(
                inProjectYAML: projectYAML
            ).contains(
                "- offline-contextual-content-candidate-v1.json"
            ),
            "candidate 必须位于 Release EXCLUDED_SOURCE_FILE_NAMES"
        )
        let generatedProject = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Unmanual.xcodeproj/project.pbxproj"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            try releaseBuildSettingsBlock(
                inGeneratedProject: generatedProject
            ).contains(
                "offline-contextual-content-candidate-v1.json"
            ),
            "生成工程的 App Release build settings 必须排除 candidate"
        )
    }

    func testSourceLockMatchesCandidateProvenanceAndLicenseBoundary()
        throws {
        let candidate = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: candidateURL)
            ) as? [String: Any]
        )
        let lock = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: sourceLockURL)
            ) as? [String: Any]
        )
        let cards = try XCTUnwrap(candidate["cards"] as? [[String: Any]])
        let lockedCards = try XCTUnwrap(
            lock["cards"] as? [[String: Any]]
        )
        let sources = try XCTUnwrap(
            candidate["sources"] as? [[String: Any]]
        )
        let lockedSources = try XCTUnwrap(
            lock["sources"] as? [[String: Any]]
        )
        XCTAssertEqual(
            try OfflineContextualContentTestSigning.jsonValue(sources),
            try OfflineContextualContentTestSigning.jsonValue(
                lockedSources
            )
        )

        XCTAssertEqual(cards.count, lockedCards.count)
        let lockedByID = Dictionary(
            uniqueKeysWithValues: try lockedCards.map { locked in
                (
                    try XCTUnwrap(locked["id"] as? String),
                    locked
                )
            }
        )
        for var card in cards {
            let cardID = try XCTUnwrap(card["id"] as? String)
            let locked = try XCTUnwrap(lockedByID[cardID])
            card.removeValue(forKey: "cardDigest")
            XCTAssertEqual(
                try OfflineContextualContentTestSigning.jsonValue(card),
                try OfflineContextualContentTestSigning.jsonValue(
                    adaptedCandidateCard(
                        from: locked,
                        cardID: cardID
                    )
                ),
                "candidate card 只能包含已登记的确定性改编：\(cardID)"
            )
        }
        let attribution = try XCTUnwrap(
            candidate["attribution"] as? [String: Any]
        )
        XCTAssertEqual(
            attribution["creator"] as? String,
            "MtF Manual contributors"
        )
        XCTAssertEqual(
            attribution["licenseIdentifier"] as? String,
            "CC-BY-SA-4.0"
        )
    }

    private func adaptedCandidateCard(
        from locked: [String: Any],
        cardID: String
    ) throws -> [String: Any] {
        var expected = locked
        let original = try XCTUnwrap(
            locked["summary"] as? String
        )
        let markdownAdapted =
            stripMarkdownBlockquoteMarkers(original)
        var adapted = markdownAdapted
        if let regionalClaim =
            unreferencedRegionalClaims[cardID] {
            XCTAssertTrue(
                adapted.contains(regionalClaim),
                "登记的地区性原句必须存在：\(cardID)"
            )
            adapted = adapted.replacingOccurrences(
                of: regionalClaim,
                with: ""
            )
        }
        adapted = collapseBlankLines(adapted)
        expected["summary"] = adapted

        if adapted != original {
            var provenance = try XCTUnwrap(
                locked["provenance"] as? [String: Any]
            )
            var note = try XCTUnwrap(
                provenance["modificationNote"] as? String
            )
            while note.last == "。" || note.last == "；" {
                note.removeLast()
            }
            var reasons: [String] = []
            if unreferencedRegionalClaims[cardID] != nil {
                reasons.append(
                    "移除未被当前 sourceIDs 支持的地区性断言"
                )
            }
            if markdownAdapted != original {
                reasons.append(
                    "把 Markdown 引用标记转换为纯文本"
                )
            }
            provenance["modificationNote"] =
                note + "；" + reasons.joined(separator: "；")
            expected["provenance"] = provenance
        }
        return expected
    }

    private func stripMarkdownBlockquoteMarkers(
        _ text: String
    ) -> String {
        text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        .map { rawLine in
            let line = String(rawLine)
            guard let marker = line.firstIndex(of: ">"),
                  line[..<marker].allSatisfy({
                      $0 == " " || $0 == "\t"
                  }) else {
                return line
            }
            var start = line.index(after: marker)
            if start < line.endIndex,
               line[start] == " " || line[start] == "\t" {
                start = line.index(after: start)
            }
            return String(line[start...])
        }
        .joined(separator: "\n")
    }

    private func collapseBlankLines(_ text: String) -> String {
        let expression = try! NSRegularExpression(
            pattern: #"\n{3,}"#
        )
        let range = NSRange(
            text.startIndex..<text.endIndex,
            in: text
        )
        return expression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "\n\n"
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var unreferencedRegionalClaims: [String: String] {
        [
            "card.hiv-testing-prep-021":
                "国内 PrEP 可及性因地区而异，可到正规医院挂号（感染科）"
                + "或当地疾控/PrEP 项目咨询，通常自费。",
            "card.prep-hrt-022":
                "大陆可经感染科或本地 PrEP 项目（疾控、部分社区组织）获取与随访。",
            "card.hpv-vaccine-024":
                "国内 HPV 疫苗按获批价型有不同适用年龄（九价已扩龄 "
                + "9–45 岁女性、有国产九价），可经社区卫生服务中心或"
                + "正规预约平台接种；具体以本地获批价型为准。",
            "card.surgery-options-026":
                "（中国大陆此类手术通常自费、医保一般不覆盖）",
            "card.finding-affirming-therapist-033":
                "国内缺公开的友善咨询师名录，更多靠跨性别社群转介、"
                + "有性别相关门诊经验的医院、社群口碑来找，而非依赖"
                + "\"LGBT 友好\"标签检索；并提醒诊断证明只有精神科医生能开。"
        ]
    }

    private func releaseExclusionBlock(
        inProjectYAML text: String
    ) throws -> Substring {
        let marker = """
              configs:
                Release:
                  EXCLUDED_SOURCE_FILE_NAMES:
        """
        let start = try XCTUnwrap(text.range(of: marker))
        let tail = text[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: "\n    scheme:"))
        return tail[..<end.lowerBound]
    }

    private func releaseBuildSettingsBlock(
        inGeneratedProject text: String
    ) throws -> Substring {
        let marker = "EXCLUDED_SOURCE_FILE_NAMES = ("
        let exclusion = try XCTUnwrap(text.range(of: marker))
        let prefix = text[..<exclusion.lowerBound]
        let settingsStart = try XCTUnwrap(
            prefix.range(
                of: "buildSettings = {",
                options: .backwards
            )
        )
        let suffix = text[settingsStart.lowerBound...]
        let settingsEnd = try XCTUnwrap(
            suffix.range(of: "\n\t\t\t};\n\t\t\tname = Release;")
        )
        let block = suffix[..<settingsEnd.upperBound]
        XCTAssertTrue(
            block.contains(
                "PRODUCT_BUNDLE_IDENTIFIER = com.mtfbook.unmanual;"
            ),
            "必须核对 App target 的 Release build settings"
        )
        return block
    }

    func testBundleLoaderDistinguishesMissingPendingRejectedAndApproved()
        throws {
        try withBundle(resources: [:]) { bundle in
            let candidate = OfflineContextualContentRepository(
                bundle: bundle,
                exposure: .candidate,
                statusDate: try utcDate("2026-07-31")
            )
#if DEBUG
            XCTAssertEqual(
                candidate.state,
                .unavailable(.missingResource)
            )
#else
            XCTAssertEqual(
                candidate.state,
                .unavailable(
                    .pendingHumanReviewAndClassification
                )
            )
#endif
        }

        try withBundle(resources: [
            "offline-contextual-content-candidate-v1.json":
                Data(contentsOf: candidateURL)
        ]) { bundle in
            let candidate = OfflineContextualContentRepository(
                bundle: bundle,
                exposure: .candidate,
                statusDate: try utcDate("2026-07-31")
            )
#if DEBUG
            XCTAssertEqual(
                candidate.state.snapshot?.cards.count,
                48
            )
#else
            XCTAssertEqual(
                candidate.state,
                .unavailable(
                    .pendingHumanReviewAndClassification
                )
            )
#endif
        }

        try withBundle(resources: [
            "offline-contextual-content-release-state-v1.json":
                Data(contentsOf: releaseStateURL)
        ]) { bundle in
            let pending = OfflineContextualContentRepository(
                bundle: bundle,
                exposure: .release,
                statusDate: try utcDate("2026-07-31")
            )
            XCTAssertEqual(
                pending.state,
                .unavailable(
                    .pendingHumanReviewAndClassification
                )
            )
        }

        try withBundle(resources: [
            "offline-contextual-content-release-state-v1.json":
                releaseStateData(status: .rejected)
        ]) { bundle in
            let rejected = OfflineContextualContentRepository(
                bundle: bundle,
                exposure: .release,
                statusDate: try utcDate("2026-07-31")
            )
            XCTAssertEqual(
                rejected.state,
                .unavailable(.rejectedByHumanReview)
            )
        }

        let approvedState = releaseStateData(
            status: .approved,
            approvedResourceName:
                "offline-contextual-content-release-test"
        )
        try withBundle(resources: [
            "offline-contextual-content-release-state-v1.json":
                approvedState
        ]) { bundle in
            let missingApprovedResource =
                OfflineContextualContentRepository(
                    bundle: bundle,
                    exposure: .release,
                    statusDate: try utcDate("2026-07-31")
                )
            XCTAssertEqual(
                missingApprovedResource.state,
                .unavailable(.missingResource)
            )
        }

        try withBundle(resources: [
            "offline-contextual-content-release-state-v1.json":
                approvedState,
            "offline-contextual-content-release-test.json":
                try approvedCandidateData()
        ]) { bundle in
            let approved = OfflineContextualContentRepository(
                bundle: bundle,
                exposure: .release,
                statusDate: try utcDate("2026-07-31")
            )
            XCTAssertEqual(approved.state.snapshot?.cards.count, 48)
        }
    }

    func testRuntimeReleaseUsesApprovalDateForGateAndCurrentDateForStale()
        throws {
        let approvedState = releaseStateData(
            status: .approved,
            approvedResourceName:
                "offline-contextual-content-release-test"
        )
        try withBundle(resources: [
            "offline-contextual-content-release-state-v1.json":
                approvedState,
            "offline-contextual-content-release-test.json":
                try approvedCandidateData()
        ]) { bundle in
            let future = try utcDate("2027-07-01")
            let buildAudit = OfflineContextualContentRepository(
                bundle: bundle,
                exposure: .release,
                statusDate: future
            )
            guard case let .unavailable(.invalidContent(issues)) =
                buildAudit.state else {
                return XCTFail(
                    "构建日期过期的正式包必须继续 fail closed"
                )
            }
            XCTAssertTrue(
                issues.contains { $0.code == "exposure.current" }
            )

            let runtime =
                OfflineContextualContentRepository(
                    runtimeBundle: bundle,
                    exposure: .release,
                    statusDate: future
                )
            let snapshot = try XCTUnwrap(runtime.state.snapshot)
            XCTAssertEqual(snapshot.cards.count, 48)
            XCTAssertTrue(
                snapshot.cards.allSatisfy {
                    $0.status == .stale
                }
            )
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var candidateURL: URL {
        repositoryRoot.appendingPathComponent(
            "Unmanual/Resources/PublicContent/"
                + "offline-contextual-content-candidate-v1.json"
        )
    }

    private var releaseStateURL: URL {
        repositoryRoot.appendingPathComponent(
            "Unmanual/Resources/PublicContent/"
                + "offline-contextual-content-release-state-v1.json"
        )
    }

    private var sourceLockURL: URL {
        repositoryRoot.appendingPathComponent(
            "docs/content/"
                + "offline-contextual-content-source-lock-v1.json"
        )
    }

    private func approvedCandidateData() throws -> Data {
        try OfflineContextualContentTestSigning.resign(
            Data(contentsOf: candidateURL)
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
            review["completedAt"] = "2026-07-31"
            manifest["review"] = review
            manifest["classificationStatus"] = "resolved"
            root["manifest"] = manifest
            var cards =
                try OfflineContextualContentTestSigning
                    .requireArrayOfDictionaries(root["cards"])
            for index in cards.indices {
                if cards[index]["expiresAt"] as? String
                    == "2026-07-27" {
                    cards[index]["expiresAt"] = "2027-07-31"
                }
            }
            root["cards"] = cards
        }
    }

    private func releaseStateData(
        status: OfflineContextualContentReleaseStatus,
        approvedResourceName: String? = nil
    ) -> Data {
        let approved = status == .approved
        let object: [String: Any] = [
            "schemaVersion": "1",
            "status": status.rawValue,
            "contentVersion":
                "offline-contextual-content-candidate.1",
            "message": "测试 release-state。",
            "candidateResourceExcluded": true,
            "contentReviewApproved": approved,
            "medicalReviewApproved": approved,
            "classificationResolved": approved,
            "approvedResourceName":
                approvedResourceName ?? NSNull()
        ]
        return try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    private func withBundle(
        resources: [String: Data],
        body: (Bundle) throws -> Void
    ) throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: bundleURL)
        }
        let info: [String: Any] = [
            "CFBundleIdentifier":
                "com.mtfbook.unmanual.tests.\(UUID().uuidString)",
            "CFBundleName": "OfflineContentTestBundle",
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1"
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        ).write(to: bundleURL.appendingPathComponent("Info.plist"))
        for (name, data) in resources {
            try data.write(
                to: bundleURL.appendingPathComponent(name)
            )
        }
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        try body(bundle)
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
