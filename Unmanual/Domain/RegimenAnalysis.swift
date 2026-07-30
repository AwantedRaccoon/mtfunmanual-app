import CryptoKit
import Foundation

private func firstValuesByKey<Value, Key: Hashable>(
    _ values: [Value],
    key: (Value) -> Key
) -> [Key: Value] {
    values.reduce(into: [:]) { result, value in
        let valueKey = key(value)
        if result[valueKey] == nil {
            result[valueKey] = value
        }
    }
}

struct RegimenAnalysisContentPack: Codable, Equatable, Sendable {
    let manifest: RegimenAnalysisManifest
    let sources: [RegimenAnalysisSourceCard]
    let cards: [RegimenAnalysisCard]
    let ingredientProfiles: [RegimenAnalysisIngredientProfile]
    let safetyRules: [RegimenAnalysisSafetyRule]
}

struct RegimenAnalysisManifest: Codable, Equatable, Sendable {
    let schemaVersion: String
    let contentPackVersion: String
    let ruleSetVersion: String
    let requiredCatalogVersion: String
    let requiredCatalogContentDigest: String
    let generatedAt: String
    let coverageStatement: String
    let contentDigest: String
    let requiredIngredientIDs: [String]
    let globalBoundaryCardIDs: [String]
    let limitedCardIDs: [String]
    let review: RegimenAnalysisReview
    let medicalClassificationStatus: RegimenAnalysisClassificationStatus
}

struct RegimenAnalysisReview: Codable, Equatable, Sendable {
    enum Status: String, Codable, CaseIterable, Sendable {
        case candidate
        case approved
        case rejected
    }

    let status: Status
    let ownerRole: String
    let contentReviewerDisplayName: String?
    let medicalReviewerDisplayName: String?
    let completedAt: String?
    let scope: String
}

enum RegimenAnalysisClassificationStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case resolved
}

struct RegimenAnalysisSourceCard: Codable, Equatable, Identifiable, Sendable {
    enum Redistribution: String, Codable, CaseIterable, Sendable {
        case publicDomain
        case attributedReuse
        case linkOnly
    }

    let id: String
    let institution: String
    let title: String
    let versionOrPublishedAt: String
    let officialURL: String
    let retrievedAt: String
    let applicablePopulation: String
    let applicableRegions: [String]
    let licenseIdentifier: String
    let licenseURL: String
    let redistribution: Redistribution
    let attributionText: String?
    let boundary: String
}

struct RegimenAnalysisCard: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: RegimenAnalysisCardKind
    let evidenceBasis: RegimenAnalysisEvidenceBasis
    let title: String
    let body: String
    let boundary: String
    let sourceIDs: [String]
    let sortOrder: Int
}

enum RegimenAnalysisEvidenceBasis:
    String, Codable, CaseIterable, Sendable {
    case externalAuthority
    case productRule
}

enum RegimenAnalysisCardKind: String, Codable, CaseIterable, Sendable {
    case stop
    case framework
    case confirmation
    case monitoring
    case boundary
}

struct RegimenAnalysisIngredientProfile: Codable, Equatable, Identifiable, Sendable {
    let ingredientID: String
    let ingredientNameZH: String
    let correspondence: RegimenAnalysisCorrespondence
    let safetyFlags: [RegimenAnalysisSafetyFlag]
    let cardIDs: [String]
    let boundary: String

    var id: String { ingredientID }
}

enum RegimenAnalysisCorrespondence: String, Codable, CaseIterable, Sendable {
    case classLevel
    case specialistContext
    case recordOnly

    var explanation: String {
        switch self {
        case .classLevel:
            "这个精确成分只对应到公开资料中的类别层照护框架。"
        case .specialistContext:
            "这个精确成分只对应到需要专业团队核对的专科照护语境。"
        case .recordOnly:
            "当前规则包只确认它需要忠实保留，不建立药品特异结论。"
        }
    }
}

enum RegimenAnalysisSafetyFlag:
    String, Codable, CaseIterable, Hashable, Sendable {
    case estrogenRelated
    case cyproteroneAcetate
}

struct RegimenAnalysisSafetyRule: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let priority: Int
    let condition: RegimenAnalysisSafetyCondition
    let stopCardID: String
}

enum RegimenAnalysisSafetyCondition:
    String, Codable, CaseIterable, Hashable, Sendable {
    case corruptSnapshot
    case acuteConcernYes
    case acuteConcernUnknown
    case ageUnder18
    case ageUnknown
    case pregnancyPossibilityYes
    case pregnancyPossibilityUnknown
    case estrogenVteRiskYes
    case estrogenVteRiskUnknown
    case cyproteroneMeningiomaYes
    case cyproteroneMeningiomaUnknown

    static let frozenOrder: [Self] = [
        .corruptSnapshot,
        .acuteConcernYes,
        .acuteConcernUnknown,
        .ageUnder18,
        .ageUnknown,
        .pregnancyPossibilityYes,
        .pregnancyPossibilityUnknown,
        .estrogenVteRiskYes,
        .estrogenVteRiskUnknown,
        .cyproteroneMeningiomaYes,
        .cyproteroneMeningiomaUnknown
    ]

    var frozenRuleIdentity: (
        id: String,
        priority: Int,
        stopCardID: String
    ) {
        switch self {
        case .corruptSnapshot:
            ("stop.snapshot", 10, "stop.snapshot")
        case .acuteConcernYes:
            ("stop.acute.yes", 20, "stop.acute.yes")
        case .acuteConcernUnknown:
            ("stop.acute.unknown", 21, "stop.acute.unknown")
        case .ageUnder18:
            ("stop.age.under18", 30, "stop.age.under18")
        case .ageUnknown:
            ("stop.age.unknown", 31, "stop.age.unknown")
        case .pregnancyPossibilityYes:
            ("stop.pregnancy.yes", 40, "stop.pregnancy.yes")
        case .pregnancyPossibilityUnknown:
            ("stop.pregnancy.unknown", 41, "stop.pregnancy.unknown")
        case .estrogenVteRiskYes:
            ("stop.vte.yes", 50, "stop.vte.yes")
        case .estrogenVteRiskUnknown:
            ("stop.vte.unknown", 51, "stop.vte.unknown")
        case .cyproteroneMeningiomaYes:
            (
                "stop.cpa.meningioma.yes",
                60,
                "stop.cpa.meningioma.yes"
            )
        case .cyproteroneMeningiomaUnknown:
            (
                "stop.cpa.meningioma.unknown",
                61,
                "stop.cpa.meningioma.unknown"
            )
        }
    }
}

enum RegimenAnalysisExposure: Sendable {
    case candidate
    case release
}

struct RegimenAnalysisValidationIssue: Equatable, Sendable {
    let code: String
    let path: String
    let message: String
}

enum RegimenAnalysisContentValidator {
    static let supportedSchemaVersion = "1"
    static let forbiddenCardTerms = [
        "最佳方案", "推荐方案", "推荐药物", "推荐途径", "推荐剂量",
        "推荐用量", "首选药物", "首选方案", "最适合", "符合指南",
        "指南推荐", "目标范围", "你应该使用", "建议使用该药",
        "必须使用", "必须服用", "必须注射", "建议服用", "建议注射",
        "应该停药", "应停药", "立即停药", "建议停用", "请停药",
        "请停止使用", "可以停药", "自行换药", "请换药", "建议换药",
        "建议更换药物", "可以换药", "自行减量", "自行加量",
        "增加剂量", "减少剂量", "加大剂量", "降低剂量",
        "应减量", "应加量", "请减量", "请加量", "把剂量改为",
        "将剂量改为", "每天服用", "每次服用", "注射教学",
        "预计身体结果", "正常值", "异常值", "已经达标", "未达标"
    ]

    static func issues(
        in pack: RegimenAnalysisContentPack,
        exposure: RegimenAnalysisExposure
    ) -> [RegimenAnalysisValidationIssue] {
        var issues: [RegimenAnalysisValidationIssue] = []

        func append(_ code: String, _ path: String, _ message: String) {
            issues.append(.init(code: code, path: path, message: message))
        }

        let manifest = pack.manifest
        if manifest.schemaVersion != supportedSchemaVersion {
            append("unsupported-schema", "manifest.schemaVersion", "不支持的分析内容 schema。")
        }
        if !matchesVersion(
            manifest.contentPackVersion,
            prefix: "regimen-analysis-content"
        ) {
            append(
                "invalid-content-version",
                "manifest.contentPackVersion",
                "内容包版本格式无效。"
            )
        }
        if !matchesVersion(
            manifest.ruleSetVersion,
            prefix: "regimen-analysis-rules"
        ) {
            append(
                "invalid-rule-version",
                "manifest.ruleSetVersion",
                "规则版本格式无效。"
            )
        }
        if manifest.requiredCatalogVersion.range(
            of: #"^medication-catalog-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-(?:candidate|release)\.[0-9]+$"#,
            options: .regularExpression
        ) == nil {
            append(
                "invalid-required-catalog-version",
                "manifest.requiredCatalogVersion",
                "依赖的药品目录版本格式无效。"
            )
        }
        if manifest.requiredCatalogContentDigest.range(
            of: #"^[a-f0-9]{64}$"#,
            options: .regularExpression
        ) == nil {
            append(
                "invalid-required-catalog-digest",
                "manifest.requiredCatalogContentDigest",
                "依赖的药品目录 digest 无效。"
            )
        }
        if !isDate(manifest.generatedAt) {
            append("invalid-date", "manifest.generatedAt", "生成日期无效。")
        }
        if !isNonBlank(manifest.coverageStatement)
            || !isNonBlank(manifest.review.ownerRole)
            || !isNonBlank(manifest.review.scope) {
            append("missing-manifest-metadata", "manifest", "内容范围和复核责任均为必填。")
        }

        if case .release = exposure {
            if manifest.review.status != .approved {
                append(
                    "review-not-approved",
                    "manifest.review.status",
                    "Release 只接受真实人类批准的内容。"
                )
            }
            if !isNonBlank(manifest.review.contentReviewerDisplayName ?? "") {
                append(
                    "missing-content-reviewer",
                    "manifest.review.contentReviewerDisplayName",
                    "Release 必须记录内容复核人。"
                )
            }
            if !isNonBlank(manifest.review.medicalReviewerDisplayName ?? "") {
                append(
                    "missing-medical-reviewer",
                    "manifest.review.medicalReviewerDisplayName",
                    "Release 必须记录医疗内容复核人。"
                )
            }
            if !isDate(manifest.review.completedAt ?? "") {
                append(
                    "missing-review-date",
                    "manifest.review.completedAt",
                    "Release 必须记录有效复核日期。"
                )
            }
            if manifest.medicalClassificationStatus != .resolved {
                append(
                    "classification-pending",
                    "manifest.medicalClassificationStatus",
                    "医疗分析发行分类未解决。"
                )
            }
        }

        validateUniqueIDs(pack.sources.map(\.id), path: "sources", append: append)
        validateUniqueIDs(pack.cards.map(\.id), path: "cards", append: append)
        validateUniqueIDs(
            pack.ingredientProfiles.map(\.ingredientID),
            path: "ingredientProfiles",
            append: append
        )
        validateUniqueIDs(pack.safetyRules.map(\.id), path: "safetyRules", append: append)

        let sourceIDs = Set(pack.sources.map(\.id))
        let cardIDs = Set(pack.cards.map(\.id))
        let cardsByID = firstValuesByKey(pack.cards, key: \.id)
        let profileIDs = Set(pack.ingredientProfiles.map(\.ingredientID))

        if manifest.requiredIngredientIDs.isEmpty
            || Set(manifest.requiredIngredientIDs).count
                != manifest.requiredIngredientIDs.count
            || manifest.requiredIngredientIDs.contains(
                where: { !isStableIdentifier($0) }
            )
            || Set(manifest.requiredIngredientIDs) != profileIDs {
            append(
                "incomplete-ingredient-coverage",
                "manifest.requiredIngredientIDs",
                "规则包必须明确且完整覆盖冻结的精确成分集合。"
            )
        }

        for source in pack.sources {
            let path = "sources.\(source.id)"
            if !isStableIdentifier(source.id) {
                append("invalid-id", "\(path).id", "来源 ID 无效。")
            }
            guard let components = URLComponents(string: source.officialURL),
                  components.scheme == "https",
                  components.host?.isEmpty == false,
                  components.query == nil,
                  components.fragment == nil else {
                append(
                    "unsafe-source-url",
                    "\(path).officialURL",
                    "来源必须是无 query/fragment 的固定 HTTPS URL。"
                )
                continue
            }
            if !isHTTPSURL(source.licenseURL)
                || !isDate(source.retrievedAt)
                || !isNonBlank(source.institution)
                || !isNonBlank(source.title)
                || !isNonBlank(source.versionOrPublishedAt)
                || !isNonBlank(source.applicablePopulation)
                || source.applicableRegions.isEmpty
                || source.applicableRegions.contains(where: { !isNonBlank($0) })
                || !isNonBlank(source.licenseIdentifier)
                || !isNonBlank(source.boundary) {
                append("missing-source-metadata", path, "来源元数据、许可或适用边界不完整。")
            }
            if source.redistribution == .attributedReuse
                && !isNonBlank(source.attributionText ?? "") {
                append(
                    "missing-attribution",
                    "\(path).attributionText",
                    "署名复用来源必须保存署名文本。"
                )
            }
        }

        for card in pack.cards {
            let path = "cards.\(card.id)"
            if !isStableIdentifier(card.id)
                || !isNonBlank(card.title)
                || !isNonBlank(card.body)
                || !isNonBlank(card.boundary)
                || card.sourceIDs.contains(where: { !sourceIDs.contains($0) })
                || Set(card.sourceIDs).count != card.sourceIDs.count {
                append("invalid-card", path, "卡片身份、文字、边界或来源引用无效。")
            }
            switch card.evidenceBasis {
            case .externalAuthority where card.sourceIDs.isEmpty:
                append(
                    "missing-card-source",
                    "\(path).sourceIDs",
                    "公开资料卡必须至少引用一个来源。"
                )
            case .productRule where !card.sourceIDs.isEmpty:
                append(
                    "product-rule-has-external-source",
                    "\(path).sourceIDs",
                    "产品规则卡不得伪装成外部医疗来源结论。"
                )
            case .externalAuthority, .productRule:
                break
            }
            let combined = card.title + card.body + card.boundary
            if let forbidden = Self.forbiddenCardTerms.first(
                where: combined.contains
            ) {
                append(
                    "forbidden-medical-output",
                    path,
                    "卡片包含禁止输出：\(forbidden)。"
                )
            }
        }

        for profile in pack.ingredientProfiles {
            let path = "ingredientProfiles.\(profile.ingredientID)"
            if !isStableIdentifier(profile.ingredientID)
                || !isNonBlank(profile.ingredientNameZH)
                || !isNonBlank(profile.boundary)
                || profile.cardIDs.isEmpty
                || profile.cardIDs.contains(where: { !cardIDs.contains($0) })
                || Set(profile.cardIDs).count != profile.cardIDs.count
                || Set(profile.safetyFlags).count != profile.safetyFlags.count {
                append("invalid-profile", path, "药品 profile 身份、卡片或边界无效。")
            }
            if profile.cardIDs.contains(where: {
                guard let kind = cardsByID[$0]?.kind else { return true }
                return ![.framework, .confirmation, .monitoring].contains(kind)
            }) {
                append(
                    "invalid-profile-card-kind",
                    "\(path).cardIDs",
                    "药品 profile 只能引用框架、确认或监测卡。"
                )
            }
        }

        if manifest.globalBoundaryCardIDs.isEmpty
            || manifest.globalBoundaryCardIDs.contains(where: { !cardIDs.contains($0) })
            || Set(manifest.globalBoundaryCardIDs).count
                != manifest.globalBoundaryCardIDs.count
            || manifest.globalBoundaryCardIDs.contains(
                where: { cardsByID[$0]?.kind != .boundary }
            )
            || manifest.limitedCardIDs.isEmpty
            || manifest.limitedCardIDs.contains(where: { !cardIDs.contains($0) })
            || Set(manifest.limitedCardIDs).count
                != manifest.limitedCardIDs.count
            || manifest.limitedCardIDs.contains(
                where: { cardsByID[$0]?.kind != .confirmation }
            ) {
            append(
                "invalid-manifest-card-reference",
                "manifest",
                "全局边界卡或有限分析卡引用无效。"
            )
        }

        let frozenRuleContractMatches =
            pack.safetyRules.count
                == RegimenAnalysisSafetyCondition.frozenOrder.count
            && zip(
                pack.safetyRules,
                RegimenAnalysisSafetyCondition.frozenOrder
            ).allSatisfy { rule, condition in
                let identity = condition.frozenRuleIdentity
                return rule.condition == condition
                    && rule.id == identity.id
                    && rule.priority == identity.priority
                    && rule.stopCardID == identity.stopCardID
            }
        if !frozenRuleContractMatches {
            append(
                "invalid-frozen-rule-contract",
                "safetyRules",
                "停止规则的条件、身份、卡片和优先级必须与冻结合同完全一致。"
            )
        }
        for rule in pack.safetyRules {
            let path = "safetyRules.\(rule.id)"
            if !isStableIdentifier(rule.id)
                || cardsByID[rule.stopCardID]?.kind != .stop {
                append("invalid-stop-rule", path, "停止规则必须引用有效 stop 卡。")
            }
        }
        if Set(pack.safetyRules.map(\.condition))
            != Set(RegimenAnalysisSafetyCondition.frozenOrder) {
            append(
                "incomplete-stop-rules",
                "safetyRules",
                "停止规则必须覆盖冻结条件全集。"
            )
        }

        let expectedDigest = RegimenAnalysisContentDigest.contentDigest(for: pack)
        if manifest.contentDigest.lowercased() != expectedDigest {
            append(
                "digest-mismatch",
                "manifest.contentDigest",
                "分析内容 digest 不一致；期望 \(expectedDigest)。"
            )
        }
        return issues
    }

    private static func validateUniqueIDs(
        _ ids: [String],
        path: String,
        append: (String, String, String) -> Void
    ) {
        var seen = Set<String>()
        for id in ids where !seen.insert(id).inserted {
            append("duplicate-id", "\(path).\(id)", "稳定 ID 重复。")
        }
    }

    private static func matchesVersion(_ value: String, prefix: String) -> Bool {
        value.range(
            of: #"^\#(prefix)-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-(?:candidate|release)\.[0-9]+$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isStableIdentifier(_ value: String) -> Bool {
        value.range(
            of: #"^[a-z0-9]+(?:[.-][a-z0-9]+)*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isNonBlank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isHTTPSURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else { return false }
        return components.scheme == "https" && components.host?.isEmpty == false
    }

    private static func isDate(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let date = calendar.date(
            from: DateComponents(year: year, month: month, day: day)
        ) else {
            return false
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year
            && roundTrip.month == month
            && roundTrip.day == day
    }
}

enum RegimenAnalysisContentDigest {
    static func contentDigest(for pack: RegimenAnalysisContentPack) -> String {
        var writer = Writer()
        let manifest = pack.manifest
        writer.append(manifest.schemaVersion)
        writer.append(manifest.contentPackVersion)
        writer.append(manifest.ruleSetVersion)
        writer.append(manifest.requiredCatalogVersion)
        writer.append(manifest.requiredCatalogContentDigest)
        writer.append(manifest.generatedAt)
        writer.append(manifest.coverageStatement)
        writer.append(sorted: manifest.requiredIngredientIDs)
        writer.append(sorted: manifest.globalBoundaryCardIDs)
        writer.append(sorted: manifest.limitedCardIDs)
        writer.append(manifest.review.status.rawValue)
        writer.append(manifest.review.ownerRole)
        writer.appendOptional(manifest.review.contentReviewerDisplayName)
        writer.appendOptional(manifest.review.medicalReviewerDisplayName)
        writer.appendOptional(manifest.review.completedAt)
        writer.append(manifest.review.scope)
        writer.append(manifest.medicalClassificationStatus.rawValue)

        for source in pack.sources.sorted(by: { $0.id < $1.id }) {
            writer.append(source.id)
            writer.append(source.institution)
            writer.append(source.title)
            writer.append(source.versionOrPublishedAt)
            writer.append(source.officialURL)
            writer.append(source.retrievedAt)
            writer.append(source.applicablePopulation)
            writer.append(sorted: source.applicableRegions)
            writer.append(source.licenseIdentifier)
            writer.append(source.licenseURL)
            writer.append(source.redistribution.rawValue)
            writer.appendOptional(source.attributionText)
            writer.append(source.boundary)
        }
        for card in pack.cards.sorted(by: { $0.id < $1.id }) {
            writer.append(card.id)
            writer.append(card.kind.rawValue)
            writer.append(card.evidenceBasis.rawValue)
            writer.append(card.title)
            writer.append(card.body)
            writer.append(card.boundary)
            writer.append(sorted: card.sourceIDs)
            writer.append(String(card.sortOrder))
        }
        for profile in pack.ingredientProfiles.sorted(by: {
            $0.ingredientID < $1.ingredientID
        }) {
            writer.append(profile.ingredientID)
            writer.append(profile.ingredientNameZH)
            writer.append(profile.correspondence.rawValue)
            writer.append(sorted: profile.safetyFlags.map(\.rawValue))
            writer.append(sorted: profile.cardIDs)
            writer.append(profile.boundary)
        }
        for rule in pack.safetyRules.sorted(by: {
            ($0.priority, $0.id) < ($1.priority, $1.id)
        }) {
            writer.append(rule.id)
            writer.append(String(rule.priority))
            writer.append(rule.condition.rawValue)
            writer.append(rule.stopCardID)
        }
        return writer.digest
    }

    fileprivate struct Writer {
        private(set) var data = Data()

        mutating func append(_ value: String) {
            let bytes = Data(value.utf8)
            data.append(Data(String(bytes.count).utf8))
            data.append(0x3A)
            data.append(bytes)
            data.append(0x0A)
        }

        mutating func appendOptional(_ value: String?) {
            append(value ?? "<nil>")
        }

        mutating func append(sorted values: [String]) {
            append(String(values.count))
            for value in values.sorted() {
                append(value)
            }
        }

        var digest: String {
            SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }
}

enum RegimenAnalysisAgeBand: String, Codable, CaseIterable, Sendable {
    case adult
    case under18
    case unknown
}

enum RegimenAnalysisAnswer: String, Codable, CaseIterable, Sendable {
    case yes
    case no
    case notApplicable
    case unknown
}

struct RegimenAnalysisSafetyContext: Codable, Equatable, Sendable {
    static let unanswered = RegimenAnalysisSafetyContext(
        ageBand: nil,
        pregnancyPossibility: nil,
        acuteConcern: nil,
        knownVteHistoryOrRisk: nil,
        knownMeningiomaHistory: nil
    )

    let ageBand: RegimenAnalysisAgeBand?
    let pregnancyPossibility: RegimenAnalysisAnswer?
    let acuteConcern: RegimenAnalysisAnswer?
    let knownVteHistoryOrRisk: RegimenAnalysisAnswer?
    let knownMeningiomaHistory: RegimenAnalysisAnswer?
}

enum RegimenAnalysisItemSnapshotStatus: String, Codable, Equatable, Sendable {
    case verifiedCatalogSnapshot
    case customEntry
    case unreadableCatalogSnapshot
}

struct RegimenAnalysisRequestV1: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        let itemID: UUID
        let position: Int
        let displayNameOriginal: String
        let dosageFormOriginal: String
        let routeOriginal: String
        let doseOriginal: String
        let unitOriginal: String
        let scheduleSummaryOriginal: String
        let catalogVersion: String?
        let presentationID: String?
        let exactIngredientIDs: [String]
        let snapshotStatus: RegimenAnalysisItemSnapshotStatus
    }

    let schemaVersion: String
    let regimenVersionID: UUID
    let regimenCode: String
    let regimenTitle: String
    let effectiveStartDate: String
    let items: [Item]
}

struct RegimenAnalysisItemSummary: Equatable, Identifiable, Sendable {
    let id: UUID
    let position: Int
    let name: String
    let formAndRoute: String
    let doseAndUnitOriginal: String
    let scheduleOriginal: String
}

struct RegimenAnalysisComponentExplanation:
    Equatable, Identifiable, Sendable {
    let itemID: UUID
    let itemPosition: Int
    let itemNameOriginal: String
    let ingredientID: String
    let ingredientNameZH: String
    let correspondenceExplanation: String
    let boundary: String
    let discussionCards: [RegimenAnalysisCard]
    let sources: [RegimenAnalysisSourceCard]

    var id: String {
        "\(itemID.uuidString).\(ingredientID)"
    }
}

enum RegimenAnalysisSemanticStatus: String, Equatable, Sendable {
    case unanswered
    case ready
    case limited
    case stopped
}

struct RegimenAnalysisSnapshot: Equatable, Sendable {
    let semanticStatus: RegimenAnalysisSemanticStatus
    let regimenCode: String
    let regimenTitle: String
    let effectiveStartDate: String
    let summaries: [RegimenAnalysisItemSummary]
    let componentExplanations: [RegimenAnalysisComponentExplanation]
    let recordFindings: [String]
    let stopCards: [RegimenAnalysisCard]
    let frameworkCards: [RegimenAnalysisCard]
    let confirmationCards: [RegimenAnalysisCard]
    let monitoringCards: [RegimenAnalysisCard]
    let boundaryCards: [RegimenAnalysisCard]
    let sources: [RegimenAnalysisSourceCard]
    let ruleSetVersion: String
    let contentPackVersion: String
    let semanticInputDigest: String
}

enum RegimenAnalysisEngine {
    static func evaluate(
        request: RegimenAnalysisRequestV1,
        safetyContext: RegimenAnalysisSafetyContext,
        pack: RegimenAnalysisContentPack
    ) -> RegimenAnalysisSnapshot {
        let sortedItems = request.items.sorted {
            ($0.position, $0.itemID.uuidString)
                < ($1.position, $1.itemID.uuidString)
        }
        let profilesByID = firstValuesByKey(
            pack.ingredientProfiles,
            key: \.ingredientID
        )
        let cardsByID = firstValuesByKey(pack.cards, key: \.id)
        let sourcesByID = firstValuesByKey(pack.sources, key: \.id)

        let summaries = sortedItems.map { item in
            RegimenAnalysisItemSummary(
                id: item.itemID,
                position: item.position,
                name: item.displayNameOriginal.isEmpty ? "未记录名称" : item.displayNameOriginal,
                formAndRoute: [item.dosageFormOriginal, item.routeOriginal]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                doseAndUnitOriginal: [item.doseOriginal, item.unitOriginal]
                    .filter { !$0.isEmpty }
                    .joined(separator: " "),
                scheduleOriginal: item.scheduleSummaryOriginal
            )
        }

        var findings: [String] = []
        if sortedItems.isEmpty {
            findings.append("方案中尚未记录组成项。")
        }
        for item in sortedItems {
            let prefix = item.displayNameOriginal.isEmpty
                ? "第 \(item.position + 1) 项"
                : item.displayNameOriginal
            if item.displayNameOriginal.isEmpty {
                findings.append("\(prefix)：名称未记录。")
            }
            if item.routeOriginal.isEmpty {
                findings.append("\(prefix)：途径未记录。")
            }
            if item.dosageFormOriginal.isEmpty {
                findings.append("\(prefix)：剂型未记录。")
            }
            if item.doseOriginal.isEmpty {
                findings.append("\(prefix)：用量原文未记录。")
            }
            if item.unitOriginal.isEmpty {
                findings.append("\(prefix)：单位原文未记录。")
            }
            if item.scheduleSummaryOriginal.isEmpty {
                findings.append("\(prefix)：使用时段未记录。")
            }
        }
        if findings.isEmpty {
            findings.append("名称、剂型、途径、用量原文、单位原文和使用时段均有记录。")
        }

        let ingredientIDs = Set(sortedItems.flatMap(\.exactIngredientIDs))
        let matchedProfiles = ingredientIDs
            .compactMap { profilesByID[$0] }
            .sorted { $0.ingredientID < $1.ingredientID }
        let hasUnmappedContent = sortedItems.isEmpty
            || sortedItems.contains { item in
                item.snapshotStatus == .customEntry
                    || item.exactIngredientIDs.contains {
                        profilesByID[$0] == nil
                    }
            }
        let hasCorruptSnapshot = sortedItems.contains {
            $0.snapshotStatus == .unreadableCatalogSnapshot
        }
        let flags = Set(matchedProfiles.flatMap(\.safetyFlags))
        let hasUnansweredSafety =
            safetyContext.ageBand == nil
            || safetyContext.pregnancyPossibility == nil
            || safetyContext.acuteConcern == nil
            || (
                flags.contains(.estrogenRelated)
                    && safetyContext.knownVteHistoryOrRisk == nil
            )
            || (
                flags.contains(.cyproteroneAcetate)
                    && safetyContext.knownMeningiomaHistory == nil
            )

        let rulesByCondition = firstValuesByKey(
            pack.safetyRules,
            key: \.condition
        )
        var stopRule: RegimenAnalysisSafetyRule?
        for condition in RegimenAnalysisSafetyCondition.frozenOrder
        where matches(
            condition,
            safety: safetyContext,
            hasCorruptSnapshot: hasCorruptSnapshot,
            flags: flags
        ) {
            if let rule = rulesByCondition[condition] {
                stopRule = rule
                break
            }
        }

        let status: RegimenAnalysisSemanticStatus
        let selectedCardIDs: Set<String>
        let stopCards: [RegimenAnalysisCard]
        if let stopRule, let stopCard = cardsByID[stopRule.stopCardID] {
            status = .stopped
            stopCards = [stopCard]
            selectedCardIDs = Set(
                pack.manifest.globalBoundaryCardIDs + [stopCard.id]
            )
        } else if hasUnansweredSafety {
            status = .unanswered
            stopCards = []
            selectedCardIDs = Set(
                pack.manifest.globalBoundaryCardIDs
            )
        } else if hasUnmappedContent
                    || matchedProfiles.count != ingredientIDs.count {
            status = .limited
            stopCards = []
            selectedCardIDs = Set(
                pack.manifest.globalBoundaryCardIDs
                    + pack.manifest.limitedCardIDs
            )
        } else {
            status = .ready
            stopCards = []
            selectedCardIDs = Set(
                pack.manifest.globalBoundaryCardIDs
                    + matchedProfiles.flatMap(\.cardIDs)
            )
        }

        let selectedCards = selectedCardIDs
            .compactMap { cardsByID[$0] }
            .sorted {
                ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id)
            }
        let sourceIDs = Set(selectedCards.flatMap(\.sourceIDs))
        let selectedSources = sourceIDs
            .compactMap { sourcesByID[$0] }
            .sorted { $0.id < $1.id }
        let componentExplanations: [RegimenAnalysisComponentExplanation]
        if status == .ready {
            componentExplanations = sortedItems.flatMap { item in
                item.exactIngredientIDs.sorted().compactMap { ingredientID in
                    guard let profile = profilesByID[ingredientID] else {
                        return nil
                    }
                    let profileCards = profile.cardIDs
                        .compactMap { cardsByID[$0] }
                        .filter {
                            $0.kind == .confirmation
                                || $0.kind == .monitoring
                        }
                        .sorted {
                            ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id)
                        }
                    let profileSourceIDs = Set(
                        profile.cardIDs
                            .compactMap { cardsByID[$0] }
                            .flatMap(\.sourceIDs)
                    )
                    return RegimenAnalysisComponentExplanation(
                        itemID: item.itemID,
                        itemPosition: item.position,
                        itemNameOriginal: item.displayNameOriginal,
                        ingredientID: profile.ingredientID,
                        ingredientNameZH: profile.ingredientNameZH,
                        correspondenceExplanation:
                            profile.correspondence.explanation,
                        boundary: profile.boundary,
                        discussionCards: profileCards,
                        sources: profileSourceIDs
                            .compactMap { sourcesByID[$0] }
                            .sorted { $0.id < $1.id }
                    )
                }
            }
        } else {
            componentExplanations = []
        }

        return RegimenAnalysisSnapshot(
            semanticStatus: status,
            regimenCode: request.regimenCode,
            regimenTitle: request.regimenTitle,
            effectiveStartDate: request.effectiveStartDate,
            summaries: summaries,
            componentExplanations: componentExplanations,
            recordFindings: findings,
            stopCards: stopCards,
            frameworkCards: selectedCards.filter { $0.kind == .framework },
            confirmationCards: selectedCards.filter { $0.kind == .confirmation },
            monitoringCards: selectedCards.filter { $0.kind == .monitoring },
            boundaryCards: selectedCards.filter { $0.kind == .boundary },
            sources: selectedSources,
            ruleSetVersion: pack.manifest.ruleSetVersion,
            contentPackVersion: pack.manifest.contentPackVersion,
            semanticInputDigest: inputDigest(
                request: request,
                safetyContext: safetyContext,
                ruleSetVersion: pack.manifest.ruleSetVersion,
                contentPackVersion: pack.manifest.contentPackVersion
            )
        )
    }

    static func inputDigest(
        request: RegimenAnalysisRequestV1,
        safetyContext: RegimenAnalysisSafetyContext,
        ruleSetVersion: String,
        contentPackVersion: String
    ) -> String {
        var writer = RegimenAnalysisContentDigest.Writer()
        writer.append(request.schemaVersion)
        writer.append(request.regimenVersionID.uuidString.lowercased())
        writer.append(request.regimenCode)
        writer.append(request.regimenTitle)
        writer.append(request.effectiveStartDate)
        writer.append(ruleSetVersion)
        writer.append(contentPackVersion)
        writer.append(safetyContext.ageBand?.rawValue ?? "unanswered")
        writer.append(
            safetyContext.pregnancyPossibility?.rawValue ?? "unanswered"
        )
        writer.append(safetyContext.acuteConcern?.rawValue ?? "unanswered")
        writer.append(
            safetyContext.knownVteHistoryOrRisk?.rawValue ?? "unanswered"
        )
        writer.append(
            safetyContext.knownMeningiomaHistory?.rawValue ?? "unanswered"
        )
        let items = request.items.sorted {
            ($0.position, $0.itemID.uuidString)
                < ($1.position, $1.itemID.uuidString)
        }
        writer.append(String(items.count))
        for item in items {
            writer.append(item.itemID.uuidString.lowercased())
            writer.append(String(item.position))
            writer.append(item.displayNameOriginal)
            writer.append(item.dosageFormOriginal)
            writer.append(item.routeOriginal)
            writer.append(item.doseOriginal)
            writer.append(item.unitOriginal)
            writer.append(item.scheduleSummaryOriginal)
            writer.appendOptional(item.catalogVersion)
            writer.appendOptional(item.presentationID)
            writer.append(sorted: item.exactIngredientIDs)
            writer.append(item.snapshotStatus.rawValue)
        }
        return writer.digest
    }

    private static func matches(
        _ condition: RegimenAnalysisSafetyCondition,
        safety: RegimenAnalysisSafetyContext,
        hasCorruptSnapshot: Bool,
        flags: Set<RegimenAnalysisSafetyFlag>
    ) -> Bool {
        switch condition {
        case .corruptSnapshot:
            hasCorruptSnapshot
        case .acuteConcernYes:
            safety.acuteConcern == .yes
        case .acuteConcernUnknown:
            safety.acuteConcern == .unknown
        case .ageUnder18:
            safety.ageBand == .under18
        case .ageUnknown:
            safety.ageBand == .unknown
        case .pregnancyPossibilityYes:
            safety.pregnancyPossibility == .yes
        case .pregnancyPossibilityUnknown:
            safety.pregnancyPossibility == .unknown
        case .estrogenVteRiskYes:
            flags.contains(.estrogenRelated)
                && safety.knownVteHistoryOrRisk == .yes
        case .estrogenVteRiskUnknown:
            flags.contains(.estrogenRelated)
                && safety.knownVteHistoryOrRisk == .unknown
        case .cyproteroneMeningiomaYes:
            flags.contains(.cyproteroneAcetate)
                && safety.knownMeningiomaHistory == .yes
        case .cyproteroneMeningiomaUnknown:
            flags.contains(.cyproteroneAcetate)
                && safety.knownMeningiomaHistory == .unknown
        }
    }
}
