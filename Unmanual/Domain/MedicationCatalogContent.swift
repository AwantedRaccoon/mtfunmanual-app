import CryptoKit
import Foundation

struct MedicationCatalogPack: Codable, Equatable, Sendable {
    let manifest: MedicationCatalogManifest
    let sources: [MedicationCatalogSource]
    let ingredients: [MedicationIngredient]
    let products: [MedicationProduct]
    let presentations: [MedicationPresentation]
}

struct MedicationCatalogManifest: Codable, Equatable, Sendable {
    let schemaVersion: String
    let catalogVersion: String
    let generatedAt: String
    let coverageStatement: String
    let supportedRegions: [String]
    let contentDigest: String
    let review: MedicationCatalogReview
}

struct MedicationCatalogReview: Codable, Equatable, Sendable {
    enum Status: String, Codable, CaseIterable, Hashable, Sendable {
        case candidate
        case approved
        case rejected
    }

    let status: Status
    let ownerRole: String
    let reviewerDisplayName: String?
    let completedAt: String?
    let scope: String
}

struct MedicationCatalogSource: Codable, Equatable, Hashable, Identifiable, Sendable {
    enum Redistribution: String, Codable, CaseIterable, Hashable, Sendable {
        case publicDomain
        case cc0
        case openGovernmentLicence
        case linkOnly

        var permitsBundling: Bool {
            switch self {
            case .publicDomain, .cc0, .openGovernmentLicence:
                true
            case .linkOnly:
                false
            }
        }
    }

    let id: String
    let institution: String
    let title: String
    let versionOrPublishedAt: String
    let url: String
    let retrievedAt: String
    let region: String
    let jurisdictionCodes: [String]
    let authorityCodes: [String]
    let licenseIdentifier: String
    let licenseURL: String
    let redistribution: Redistribution
    let evidenceKinds: [MedicationCatalogSourceEvidenceKind]
    let proves: String
    let boundary: String
}

enum MedicationCatalogSourceEvidenceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case terminologyIdentity
    case currentPrescribableTerminology
    case regulatoryProductRecord
}

struct MedicationIngredient: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let preferredNameZH: String
    let preferredNameEN: String
    let exactSubstanceName: String
    let aliases: [String]
    let parentActiveMoietyID: String?
    let activeMoietyName: String?
    let substanceForm: MedicationSubstanceForm
    let roles: [MedicationRole]
    let tier: MedicationCatalogTier
    let externalIdentifiers: [MedicationExternalIdentifier]
    let sourceIDs: [String]
    let boundaryNote: String
}

enum MedicationSubstanceForm: String, Codable, CaseIterable, Hashable, Sendable {
    case activeMoiety
    case salt
    case ester
    case hydrate
    case mixture
}

enum MedicationRole: String, Codable, CaseIterable, Hashable, Sendable {
    case estrogen
    case androgenSuppressing
    case fiveAlphaReductaseInhibitor
    case progestogen
    case gnrhAgonist
    case gnrhAntagonist
    case historicalRecord

    var title: String {
        switch self {
        case .estrogen:
            "雌激素相关"
        case .androgenSuppressing:
            "抗雄相关"
        case .fiveAlphaReductaseInhibitor:
            "5α 还原酶抑制剂"
        case .progestogen:
            "孕激素相关"
        case .gnrhAgonist:
            "GnRH 激动剂"
        case .gnrhAntagonist:
            "GnRH 拮抗剂"
        case .historicalRecord:
            "历史记录"
        }
    }
}

enum MedicationCatalogTier: String, Codable, CaseIterable, Hashable, Sendable {
    case common
    case extended
    case recordOnly
    case historical

    var title: String {
        switch self {
        case .common:
            "常用记录"
        case .extended:
            "扩展记录"
        case .recordOnly:
            "仅供记录"
        case .historical:
            "历史记录"
        }
    }

    var defaultVisible: Bool {
        self == .common
    }

    var sortOrder: Int {
        switch self {
        case .common: 0
        case .extended: 1
        case .recordOnly: 2
        case .historical: 3
        }
    }
}

struct MedicationExternalIdentifier: Codable, Equatable, Hashable, Sendable {
    let system: String
    let value: String
}

struct MedicationProduct: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayNameZH: String
    let displayNameEN: String
    let aliases: [String]
    let region: String
    let jurisdictionCode: String?
    let regulator: String
    let regulatorCode: String?
    let regulatoryStatus: MedicationRegulatoryStatus
    let authorizationIdentifier: String?
    let holderOrManufacturer: String?
    let ingredientLinks: [MedicationProductIngredient]
    let sourceIDs: [String]
    let regulatorySourceIDs: [String]?
    let boundaryNote: String
}

enum MedicationRegulatoryStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case marketed
    case approvedNotMarketed
    case discontinued
    case withdrawn
    case combinationOnly
    case compoundedOnly
    case terminologyVerified
    case notAsserted

    var title: String {
        switch self {
        case .marketed:
            "已核对在售记录"
        case .approvedNotMarketed:
            "已批准／未核对在售"
        case .discontinued:
            "已停产或停止销售"
        case .withdrawn:
            "已撤回"
        case .combinationOnly:
            "仅核对到复方"
        case .compoundedOnly:
            "仅调配记录"
        case .terminologyVerified:
            "规范名已核对"
        case .notAsserted:
            "未断言地区批准状态"
        }
    }
}

struct MedicationProductIngredient: Codable, Equatable, Sendable {
    let ingredientID: String
    let labelStrengthOriginal: String?
    let activeMoietyBasis: String?
    let sortOrder: Int
}

struct MedicationPresentation: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let productID: String
    let displayNameZH: String
    let displayNameEN: String
    let dosageForm: String
    let authorizedRoutes: [MedicationRoute]
    let evidenceStatus: MedicationPresentationEvidenceStatus
    let releasePattern: String?
    let packageOrDevice: String?
    let preciseIngredientForms: [MedicationPresentationIngredientForm]?
    let sourceIDs: [String]
}

enum MedicationPresentationEvidenceStatus:
    String, Codable, CaseIterable, Hashable, Sendable {
    case candidateUnverified
    case regulatoryVerified
}

struct MedicationPresentationIngredientForm: Codable, Equatable, Hashable, Sendable {
    let ingredientID: String
    let exactFormName: String
    let relationship: String
    let externalIdentifiers: [MedicationExternalIdentifier]
}

enum MedicationRoute: String, Codable, CaseIterable, Hashable, Sendable {
    case oral
    case sublingual
    case transdermal
    case topical
    case vaginal
    case intramuscular
    case subcutaneous
    case intranasal
    case other

    var title: String {
        switch self {
        case .oral:
            "口服"
        case .sublingual:
            "舌下记录"
        case .transdermal:
            "经皮"
        case .topical:
            "局部外用"
        case .vaginal:
            "阴道用"
        case .intramuscular:
            "肌内注射"
        case .subcutaneous:
            "皮下注射"
        case .intranasal:
            "鼻用"
        case .other:
            "其他／按标签原文"
        }
    }
}

enum MedicationCatalogExposure: Equatable, Sendable {
    case candidate
    case release
}

struct MedicationCatalogValidationIssue: Error, Equatable, Sendable {
    let code: String
    let path: String
    let message: String
}

enum MedicationCatalogValidator {
    static let supportedSchemaVersion = "1"

    static func issues(
        in pack: MedicationCatalogPack,
        exposure: MedicationCatalogExposure
    ) -> [MedicationCatalogValidationIssue] {
        var issues: [MedicationCatalogValidationIssue] = []

        func append(_ code: String, _ path: String, _ message: String) {
            issues.append(
                MedicationCatalogValidationIssue(
                    code: code,
                    path: path,
                    message: message
                )
            )
        }

        let manifest = pack.manifest
        if manifest.schemaVersion != supportedSchemaVersion {
            append(
                "unsupported-schema",
                "manifest.schemaVersion",
                "不支持目录 schema \(manifest.schemaVersion)。"
            )
        }
        if manifest.catalogVersion.range(
            of: #"^medication-catalog-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-(?:candidate|release)\.[0-9]+$"#,
            options: .regularExpression
        ) == nil {
            append(
                "invalid-catalog-version",
                "manifest.catalogVersion",
                "catalog version 必须是稳定的小写标识。"
            )
        }
        if !isDate(manifest.generatedAt) {
            append("invalid-date", "manifest.generatedAt", "生成日期必须是有效 YYYY-MM-DD。")
        }
        if manifest.coverageStatement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append("missing-coverage", "manifest.coverageStatement", "目录必须声明覆盖边界。")
        }
        if manifest.supportedRegions.isEmpty
            || manifest.supportedRegions.contains(where: { !isNonBlank($0) }) {
            append("missing-region", "manifest.supportedRegions", "目录必须声明适用地区。")
        }
        if Set(manifest.supportedRegions).count != manifest.supportedRegions.count {
            append("duplicate-region", "manifest.supportedRegions", "适用地区不能重复。")
        }
        if manifest.review.ownerRole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append("missing-review-owner", "manifest.review.ownerRole", "必须指定人工复核责任角色。")
        }
        if manifest.review.scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append("missing-review-scope", "manifest.review.scope", "必须声明人工复核范围。")
        }
        if case .release = exposure {
            if manifest.review.status != .approved {
                append("review-not-approved", "manifest.review.status", "Release 只接受人工批准内容。")
            }
            if manifest.review.reviewerDisplayName?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                append(
                    "missing-human-reviewer",
                    "manifest.review.reviewerDisplayName",
                    "Release 必须记录真实人类复核人。"
                )
            }
            guard let completedAt = manifest.review.completedAt, isDate(completedAt) else {
                append(
                    "missing-review-date",
                    "manifest.review.completedAt",
                    "Release 必须记录有效复核日期。"
                )
                return structuralIssues(
                    pack: pack,
                    existing: issues,
                    exposure: exposure
                )
            }
        }

        return structuralIssues(pack: pack, existing: issues, exposure: exposure)
    }

    private static func structuralIssues(
        pack: MedicationCatalogPack,
        existing: [MedicationCatalogValidationIssue],
        exposure: MedicationCatalogExposure
    ) -> [MedicationCatalogValidationIssue] {
        var issues = existing

        func append(_ code: String, _ path: String, _ message: String) {
            issues.append(
                MedicationCatalogValidationIssue(
                    code: code,
                    path: path,
                    message: message
                )
            )
        }

        validateUniqueIDs(
            pack.sources.map(\.id),
            path: "sources",
            append: append
        )
        validateUniqueIDs(
            pack.ingredients.map(\.id),
            path: "ingredients",
            append: append
        )
        validateUniqueIDs(
            pack.products.map(\.id),
            path: "products",
            append: append
        )
        validateUniqueIDs(
            pack.presentations.map(\.id),
            path: "presentations",
            append: append
        )

        let sourceIDs = Set(pack.sources.map(\.id))
        let sourcesByID = pack.sources.reduce(into: [String: MedicationCatalogSource]()) {
            if $0[$1.id] == nil {
                $0[$1.id] = $1
            }
        }
        let ingredientIDs = Set(pack.ingredients.map(\.id))
        let productIDs = Set(pack.products.map(\.id))

        for source in pack.sources {
            let path = "sources.\(source.id)"
            if !isStableIdentifier(source.id) {
                append("invalid-id", "\(path).id", "来源 ID 不是稳定小写标识。")
            }
            if !isHTTPSURL(source.url) {
                append("invalid-url", "\(path).url", "来源 URL 必须使用 HTTPS。")
            }
            if !isHTTPSURL(source.licenseURL) {
                append("invalid-url", "\(path).licenseURL", "许可证 URL 必须使用 HTTPS。")
            }
            if !isDate(source.retrievedAt) {
                append("invalid-date", "\(path).retrievedAt", "查阅日期无效。")
            }
            if !isNonBlank(source.institution) || !isNonBlank(source.title)
                || !isNonBlank(source.versionOrPublishedAt)
                || !isNonBlank(source.region) || !isNonBlank(source.licenseIdentifier)
                || !isNonBlank(source.proves) || !isNonBlank(source.boundary) {
                append("missing-source-metadata", path, "来源地区、许可、证明范围和边界均为必填。")
            }
            if source.jurisdictionCodes.isEmpty
                || source.jurisdictionCodes.contains(where: { !isNonBlank($0) })
                || Set(source.jurisdictionCodes).count != source.jurisdictionCodes.count {
                append(
                    "invalid-source-jurisdiction",
                    "\(path).jurisdictionCodes",
                    "来源必须声明非空且不重复的机器可读辖区。"
                )
            }
            if source.authorityCodes.isEmpty
                || source.authorityCodes.contains(where: { !isNonBlank($0) })
                || Set(source.authorityCodes).count != source.authorityCodes.count {
                append(
                    "invalid-source-authority",
                    "\(path).authorityCodes",
                    "来源必须声明非空且不重复的机器可读机构代码。"
                )
            }
            if source.evidenceKinds.isEmpty
                || Set(source.evidenceKinds).count != source.evidenceKinds.count {
                append(
                    "invalid-source-evidence-kind",
                    "\(path).evidenceKinds",
                    "来源必须声明非空且不重复的证据类型。"
                )
            }
            if case .release = exposure, !source.redistribution.permitsBundling {
                append(
                    "source-not-redistributable",
                    "\(path).redistribution",
                    "Release 不得引用只允许链接的来源。"
                )
            }
        }

        var externalIdentifierKeys = Set<String>()
        for ingredient in pack.ingredients {
            let path = "ingredients.\(ingredient.id)"
            if !isStableIdentifier(ingredient.id) {
                append("invalid-id", "\(path).id", "成分 ID 不是稳定小写标识。")
            }
            if !isNonBlank(ingredient.preferredNameZH)
                || !isNonBlank(ingredient.preferredNameEN)
                || !isNonBlank(ingredient.exactSubstanceName) {
                append("missing-name", path, "成分的中英文名和精确 substance name 均为必填。")
            }
            if ingredient.roles.isEmpty {
                append("missing-role", "\(path).roles", "成分至少需要一个索引角色。")
            }
            if let parent = ingredient.parentActiveMoietyID {
                if parent == ingredient.id || !isStableIdentifier(parent) {
                    append("invalid-parent", "\(path).parentActiveMoietyID", "母体成分引用无效。")
                }
                if !ingredientIDs.contains(parent),
                   !isNonBlank(ingredient.activeMoietyName ?? "") {
                    append(
                        "missing-unlisted-active-moiety-name",
                        "\(path).activeMoietyName",
                        "未列为可选成分的稳定母体 ID 必须同时保存精确名称。"
                    )
                }
            }
            if [.salt, .ester, .hydrate].contains(ingredient.substanceForm),
               ingredient.parentActiveMoietyID == nil {
                append(
                    "missing-active-moiety",
                    "\(path).parentActiveMoietyID",
                    "盐、酯或水合物必须保存稳定母体 ID。"
                )
            }
            validateSourceReferences(
                ingredient.sourceIDs,
                available: sourceIDs,
                path: "\(path).sourceIDs",
                append: append
            )
            for identifier in ingredient.externalIdentifiers {
                if !isNonBlank(identifier.system) || !isNonBlank(identifier.value) {
                    append("empty-external-id", "\(path).externalIdentifiers", "外部标识不能为空。")
                }
                let key = "\(identifier.system.lowercased())|\(identifier.value.lowercased())"
                if !externalIdentifierKeys.insert(key).inserted {
                    append("duplicate-external-id", "\(path).externalIdentifiers", "外部标识重复。")
                }
            }
        }

        for ingredient in pack.ingredients {
            var visited = Set<String>()
            var cursor = ingredient.parentActiveMoietyID
            while let current = cursor {
                if !visited.insert(current).inserted {
                    append(
                        "parent-cycle",
                        "ingredients.\(ingredient.id).parentActiveMoietyID",
                        "母体成分关系形成循环。"
                    )
                    break
                }
                cursor = pack.ingredients.first { $0.id == current }?.parentActiveMoietyID
            }
        }

        for product in pack.products {
            let path = "products.\(product.id)"
            if !isStableIdentifier(product.id) {
                append("invalid-id", "\(path).id", "产品 ID 不是稳定小写标识。")
            }
            if !isNonBlank(product.displayNameZH) || !isNonBlank(product.displayNameEN)
                || !isNonBlank(product.region) || !isNonBlank(product.regulator)
                || !isNonBlank(product.boundaryNote) {
                append("missing-product-metadata", path, "产品名称、地区、监管方和边界均为必填。")
            }
            if product.ingredientLinks.isEmpty {
                append("missing-product-ingredient", "\(path).ingredientLinks", "产品不能没有成分。")
            }
            switch product.regulatoryStatus {
            case .marketed, .approvedNotMarketed, .discontinued, .withdrawn:
                if product.authorizationIdentifier?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    append(
                        "missing-authorization-id",
                        "\(path).authorizationIdentifier",
                        "断言具体监管状态时必须保存批准号或产品号。"
                    )
                }
                let jurisdictionCode = product.jurisdictionCode?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if jurisdictionCode?.isEmpty != false {
                    append(
                        "missing-product-jurisdiction",
                        "\(path).jurisdictionCode",
                        "断言具体监管状态时必须保存机器可读辖区。"
                    )
                }
                let regulatorCode = product.regulatorCode?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if regulatorCode?.isEmpty != false {
                    append(
                        "missing-product-regulator-code",
                        "\(path).regulatorCode",
                        "断言具体监管状态时必须保存机器可读监管机构代码。"
                    )
                }
                let regulatorySourceIDs = product.regulatorySourceIDs ?? []
                if regulatorySourceIDs.isEmpty {
                    append(
                        "missing-regulatory-source",
                        "\(path).regulatorySourceIDs",
                        "断言具体监管状态时必须绑定能够证明该事实的监管来源。"
                    )
                }
                for sourceID in regulatorySourceIDs {
                    if !product.sourceIDs.contains(sourceID) {
                        append(
                            "regulatory-source-not-attributed",
                            "\(path).regulatorySourceIDs",
                            "监管来源必须同时出现在产品来源列表中。"
                        )
                    }
                    guard let source = sourcesByID[sourceID] else {
                        append(
                            "unknown-regulatory-source",
                            "\(path).regulatorySourceIDs",
                            "监管来源 \(sourceID) 不存在。"
                        )
                        continue
                    }
                    if !source.evidenceKinds.contains(.regulatoryProductRecord) {
                        append(
                            "source-does-not-prove-regulatory-fact",
                            "\(path).regulatorySourceIDs",
                            "来源 \(sourceID) 不能证明产品监管事实。"
                        )
                    }
                    if let jurisdictionCode,
                       !jurisdictionCode.isEmpty,
                       !source.jurisdictionCodes.contains(jurisdictionCode) {
                        append(
                            "regulatory-source-jurisdiction-mismatch",
                            "\(path).regulatorySourceIDs",
                            "监管来源与产品辖区不一致。"
                        )
                    }
                    if let regulatorCode,
                       !regulatorCode.isEmpty,
                       !source.authorityCodes.contains(regulatorCode) {
                        append(
                            "regulatory-source-authority-mismatch",
                            "\(path).regulatorySourceIDs",
                            "监管来源与产品监管机构不一致。"
                        )
                    }
                }
            case .combinationOnly:
                if product.ingredientLinks.count < 2 {
                    append(
                        "incomplete-combination",
                        "\(path).ingredientLinks",
                        "复方产品必须保存至少两个精确成分。"
                    )
                }
            case .compoundedOnly, .terminologyVerified, .notAsserted:
                break
            }
            if case .release = exposure,
               [.combinationOnly, .compoundedOnly, .terminologyVerified, .notAsserted]
                .contains(product.regulatoryStatus) {
                append(
                    "product-not-release-eligible",
                    "\(path).regulatoryStatus",
                    "未断言监管事实、仅术语或仅调配条目不能进入 Release 可选产品。"
                )
            }
            let linked = product.ingredientLinks.map(\.ingredientID)
            if Set(linked).count != linked.count {
                append("duplicate-product-ingredient", "\(path).ingredientLinks", "产品成分重复。")
            }
            if Set(product.ingredientLinks.map(\.sortOrder)).count
                != product.ingredientLinks.count {
                append("duplicate-sort-order", "\(path).ingredientLinks", "产品成分顺序重复。")
            }
            for link in product.ingredientLinks where !ingredientIDs.contains(link.ingredientID) {
                append(
                    "unknown-ingredient",
                    "\(path).ingredientLinks",
                    "产品引用未知成分 \(link.ingredientID)。"
                )
            }
            validateSourceReferences(
                product.sourceIDs,
                available: sourceIDs,
                path: "\(path).sourceIDs",
                append: append
            )
        }

        var productsWithPresentations = Set<String>()
        for presentation in pack.presentations {
            let path = "presentations.\(presentation.id)"
            if !isStableIdentifier(presentation.id) {
                append("invalid-id", "\(path).id", "presentation ID 不是稳定小写标识。")
            }
            if !productIDs.contains(presentation.productID) {
                append("unknown-product", "\(path).productID", "presentation 引用未知产品。")
            } else {
                productsWithPresentations.insert(presentation.productID)
            }
            if !isNonBlank(presentation.displayNameZH)
                || !isNonBlank(presentation.displayNameEN)
                || !isNonBlank(presentation.dosageForm) {
                append("missing-presentation-metadata", path, "presentation 名称和剂型均为必填。")
            }
            if presentation.authorizedRoutes.isEmpty {
                append("missing-route", "\(path).authorizedRoutes", "presentation 至少需要一个标签途径。")
            }
            if Set(presentation.authorizedRoutes).count != presentation.authorizedRoutes.count {
                append("duplicate-route", "\(path).authorizedRoutes", "presentation 途径重复。")
            }
            let presentationProduct = pack.products
                .first { $0.id == presentation.productID }
            let productIngredientIDs = Set(
                presentationProduct?.ingredientLinks.map(\.ingredientID) ?? []
            )
            var preciseFormKeys = Set<String>()
            for preciseForm in presentation.preciseIngredientForms ?? [] {
                if !ingredientIDs.contains(preciseForm.ingredientID) {
                    append(
                        "unknown-precise-form-ingredient",
                        "\(path).preciseIngredientForms",
                        "精确 formulation 引用未知成分。"
                    )
                }
                if !productIngredientIDs.contains(preciseForm.ingredientID) {
                    append(
                        "precise-form-not-in-product",
                        "\(path).preciseIngredientForms",
                        "精确 formulation 必须属于 presentation 对应产品的成分。"
                    )
                }
                if !isNonBlank(preciseForm.exactFormName)
                    || !isNonBlank(preciseForm.relationship) {
                    append(
                        "missing-precise-form-metadata",
                        "\(path).preciseIngredientForms",
                        "精确 formulation 的名称和关系不能为空。"
                    )
                }
                if preciseForm.externalIdentifiers.isEmpty {
                    append(
                        "missing-precise-form-identifier",
                        "\(path).preciseIngredientForms",
                        "精确 formulation 至少需要一个外部标识。"
                    )
                }
                let preciseKey = [
                    preciseForm.ingredientID.lowercased(),
                    preciseForm.exactFormName.lowercased(),
                    preciseForm.relationship.lowercased()
                ].joined(separator: "|")
                if !preciseFormKeys.insert(preciseKey).inserted {
                    append(
                        "duplicate-precise-form",
                        "\(path).preciseIngredientForms",
                        "精确 formulation 重复。"
                    )
                }
                for identifier in preciseForm.externalIdentifiers {
                    if !isNonBlank(identifier.system) || !isNonBlank(identifier.value) {
                        append(
                            "empty-external-id",
                            "\(path).preciseIngredientForms.externalIdentifiers",
                            "精确 formulation 的外部标识不能为空。"
                        )
                    }
                    let key = "\(identifier.system.lowercased())|\(identifier.value.lowercased())"
                    if !externalIdentifierKeys.insert(key).inserted {
                        append(
                            "duplicate-external-id",
                            "\(path).preciseIngredientForms.externalIdentifiers",
                            "外部标识在目录中重复。"
                        )
                    }
                }
            }
            validateSourceReferences(
                presentation.sourceIDs,
                available: sourceIDs,
                path: "\(path).sourceIDs",
                append: append
            )
            if case .release = exposure {
                if presentation.evidenceStatus != .regulatoryVerified {
                    append(
                        "presentation-not-release-verified",
                        "\(path).evidenceStatus",
                        "Release presentation 必须完成逐产品监管事实核对。"
                    )
                }
                guard let presentationProduct,
                      let jurisdictionCode = presentationProduct.jurisdictionCode,
                      let regulatorCode = presentationProduct.regulatorCode else {
                    continue
                }
                let provesPresentation = presentation.sourceIDs.contains { sourceID in
                    guard let source = sourcesByID[sourceID] else { return false }
                    return source.evidenceKinds.contains(.regulatoryProductRecord)
                        && source.jurisdictionCodes.contains(jurisdictionCode)
                        && source.authorityCodes.contains(regulatorCode)
                }
                if !provesPresentation {
                    append(
                        "missing-presentation-regulatory-source",
                        "\(path).sourceIDs",
                        "Release presentation 的剂型与标签途径必须绑定同辖区、同监管机构的产品来源。"
                    )
                }
            }
        }
        for productID in productIDs where !productsWithPresentations.contains(productID) {
            append(
                "product-without-presentation",
                "products.\(productID)",
                "每个产品至少需要一个 presentation。"
            )
        }

        let expectedDigest = MedicationCatalogDigest.contentDigest(for: pack)
        if pack.manifest.contentDigest.lowercased() != expectedDigest {
            append(
                "digest-mismatch",
                "manifest.contentDigest",
                "目录 digest 与规范化内容不一致；期望 \(expectedDigest)。"
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

    private static func validateSourceReferences(
        _ references: [String],
        available: Set<String>,
        path: String,
        append: (String, String, String) -> Void
    ) {
        if references.isEmpty {
            append("missing-source", path, "至少需要一个来源。")
        }
        if Set(references).count != references.count {
            append("duplicate-source", path, "来源引用重复。")
        }
        for reference in references where !available.contains(reference) {
            append("unknown-source", path, "引用未知来源 \(reference)。")
        }
    }

    private static func isStableIdentifier(_ value: String) -> Bool {
        let pattern = #"^[a-z0-9]+(?:[.-][a-z0-9]+)*$"#
        return value.range(of: pattern, options: .regularExpression) != nil
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
              let day = Int(parts[2])
        else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return false }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
    }
}

enum MedicationCatalogDigest {
    static func contentDigest(for pack: MedicationCatalogPack) -> String {
        var writer = CanonicalWriter()
        let manifest = pack.manifest
        writer.append(manifest.schemaVersion)
        writer.append(manifest.catalogVersion)
        writer.append(manifest.generatedAt)
        writer.append(manifest.coverageStatement)
        writer.append(sorted: manifest.supportedRegions)
        writer.append(manifest.review.status.rawValue)
        writer.append(manifest.review.ownerRole)
        writer.appendOptional(manifest.review.reviewerDisplayName)
        writer.appendOptional(manifest.review.completedAt)
        writer.append(manifest.review.scope)

        for source in pack.sources.sorted(by: { $0.id < $1.id }) {
            writer.append(source.id)
            writer.append(source.institution)
            writer.append(source.title)
            writer.append(source.versionOrPublishedAt)
            writer.append(source.url)
            writer.append(source.retrievedAt)
            writer.append(source.region)
            writer.append(sorted: source.jurisdictionCodes)
            writer.append(sorted: source.authorityCodes)
            writer.append(source.licenseIdentifier)
            writer.append(source.licenseURL)
            writer.append(source.redistribution.rawValue)
            writer.append(sorted: source.evidenceKinds.map(\.rawValue))
            writer.append(source.proves)
            writer.append(source.boundary)
        }
        for ingredient in pack.ingredients.sorted(by: { $0.id < $1.id }) {
            writer.append(ingredient.id)
            writer.append(ingredient.preferredNameZH)
            writer.append(ingredient.preferredNameEN)
            writer.append(ingredient.exactSubstanceName)
            writer.append(sorted: ingredient.aliases)
            writer.appendOptional(ingredient.parentActiveMoietyID)
            writer.appendOptional(ingredient.activeMoietyName)
            writer.append(ingredient.substanceForm.rawValue)
            writer.append(sorted: ingredient.roles.map(\.rawValue))
            writer.append(ingredient.tier.rawValue)
            for identifier in ingredient.externalIdentifiers.sorted(by: {
                ($0.system, $0.value) < ($1.system, $1.value)
            }) {
                writer.append(identifier.system)
                writer.append(identifier.value)
            }
            writer.append(sorted: ingredient.sourceIDs)
            writer.append(ingredient.boundaryNote)
        }
        for product in pack.products.sorted(by: { $0.id < $1.id }) {
            writer.append(product.id)
            writer.append(product.displayNameZH)
            writer.append(product.displayNameEN)
            writer.append(sorted: product.aliases)
            writer.append(product.region)
            writer.appendOptional(product.jurisdictionCode)
            writer.append(product.regulator)
            writer.appendOptional(product.regulatorCode)
            writer.append(product.regulatoryStatus.rawValue)
            writer.appendOptional(product.authorizationIdentifier)
            writer.appendOptional(product.holderOrManufacturer)
            for link in product.ingredientLinks.sorted(by: {
                ($0.sortOrder, $0.ingredientID) < ($1.sortOrder, $1.ingredientID)
            }) {
                writer.append(link.ingredientID)
                writer.appendOptional(link.labelStrengthOriginal)
                writer.appendOptional(link.activeMoietyBasis)
                writer.append(String(link.sortOrder))
            }
            writer.append(sorted: product.sourceIDs)
            writer.append(sorted: product.regulatorySourceIDs ?? [])
            writer.append(product.boundaryNote)
        }
        for presentation in pack.presentations.sorted(by: { $0.id < $1.id }) {
            writer.append(presentation.id)
            writer.append(presentation.productID)
            writer.append(presentation.displayNameZH)
            writer.append(presentation.displayNameEN)
            writer.append(presentation.dosageForm)
            writer.append(sorted: presentation.authorizedRoutes.map(\.rawValue))
            writer.append(presentation.evidenceStatus.rawValue)
            writer.appendOptional(presentation.releasePattern)
            writer.appendOptional(presentation.packageOrDevice)
            for preciseForm in (presentation.preciseIngredientForms ?? []).sorted(by: {
                let lhsIdentifiers = $0.externalIdentifiers
                    .map { "\($0.system)|\($0.value)" }
                    .sorted()
                    .joined(separator: "\u{1F}")
                let rhsIdentifiers = $1.externalIdentifiers
                    .map { "\($0.system)|\($0.value)" }
                    .sorted()
                    .joined(separator: "\u{1F}")
                return (
                    $0.ingredientID,
                    $0.exactFormName,
                    $0.relationship,
                    lhsIdentifiers
                ) < (
                    $1.ingredientID,
                    $1.exactFormName,
                    $1.relationship,
                    rhsIdentifiers
                )
            }) {
                writer.append(preciseForm.ingredientID)
                writer.append(preciseForm.exactFormName)
                writer.append(preciseForm.relationship)
                for identifier in preciseForm.externalIdentifiers.sorted(by: {
                    ($0.system, $0.value) < ($1.system, $1.value)
                }) {
                    writer.append(identifier.system)
                    writer.append(identifier.value)
                }
            }
            writer.append(sorted: presentation.sourceIDs)
        }

        return SHA256.hash(data: writer.data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private struct CanonicalWriter {
        private(set) var data = Data()

        mutating func append(_ value: String) {
            let bytes = Data(value.utf8)
            data.append(Data(String(bytes.count).utf8))
            data.append(0x3A)
            data.append(bytes)
            data.append(0x0A)
        }

        mutating func appendOptional(_ value: String?) {
            guard let value else {
                append("<nil>")
                return
            }
            append(value)
        }

        mutating func append(sorted values: [String]) {
            append(String(values.count))
            for value in values.sorted() {
                append(value)
            }
        }
    }
}
