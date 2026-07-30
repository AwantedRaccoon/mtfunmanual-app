import CryptoKit
import Foundation

struct MedicationCatalogEntry: Identifiable, Hashable, Sendable {
    let id: String
    let catalogVersion: String
    let catalogContentDigest: String
    let name: String
    let englishName: String
    let aliases: [String]
    let forms: String
    let roles: [MedicationRole]
    let tier: MedicationCatalogTier
    let boundaryNote: String
    let externalIdentifiers: [MedicationExternalIdentifier]
    let routes: [MedicationCatalogRoute]
    let products: [MedicationProductVariant]

    var roleTitle: String {
        roles.map(\.title).joined(separator: "、")
    }

    var searchText: String {
        let productTerms = products.flatMap {
            [
                $0.displayName,
                $0.englishDisplayName,
                $0.holderOrManufacturer,
                $0.region,
                $0.regulatoryStatus.title,
                $0.authorizationIdentifier ?? ""
            ] + $0.aliases + $0.ingredientNames
        }
        let identifierTerms = externalIdentifiers.flatMap { [$0.system, $0.value] }
        return (
            [name, englishName, forms, roleTitle, tier.title, boundaryNote]
                + aliases
                + identifierTerms
                + productTerms
        )
        .joined(separator: " ")
    }

    func draft(for product: MedicationProductVariant) -> RegimenMedicationDraft {
        let detail = [
            product.holderOrManufacturer,
            product.form,
            product.routeTitle,
            product.region,
            product.regulatoryStatus.title
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
        let snapshot = MedicationCatalogSelectionSnapshotV1(
            schemaVersion: "1",
            catalogVersion: catalogVersion,
            catalogContentDigest: catalogContentDigest,
            presentationID: product.id,
            productID: product.productID,
            displayNameZH: product.displayName,
            displayNameEN: product.englishDisplayName,
            ingredients: zip(product.ingredientIDs, zip(
                product.ingredientNames,
                product.ingredientEnglishNames
            )).map {
                MedicationCatalogSelectionSnapshotV1.Ingredient(
                    id: $0.0,
                    nameZH: $0.1.0,
                    nameEN: $0.1.1
                )
            },
            dosageForm: product.form,
            routes: product.routeIDs,
            region: product.region,
            regulator: product.regulator,
            regulatoryStatus: product.regulatoryStatus,
            authorizationIdentifier: product.authorizationIdentifier,
            holderOrManufacturer: product.holderOrManufacturerFact,
            sources: product.sourceRecords.map {
                MedicationCatalogSelectionSnapshotV1.Source(
                    id: $0.id,
                    title: $0.title,
                    versionOrPublishedAt: $0.versionOrPublishedAt,
                    retrievedAt: $0.retrievedAt
                )
            },
            boundaryNote: product.boundaryNote,
            releasePattern: product.releasePattern,
            packageOrDevice: product.packageOrDevice,
            preciseIngredientForms: product.preciseIngredientForms
        )

        return RegimenMedicationDraft(
            catalogID: product.id,
            catalogVersion: catalogVersion,
            name: product.displayName,
            englishName: product.ingredientEnglishNames.joined(separator: " + "),
            detail: detail,
            dosageForm: product.form,
            route: product.routeTitle,
            productSnapshot: snapshot.encodedString() ?? detail,
            origin: .catalog
        )
    }
}

struct MedicationCatalogRoute: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
}

struct MedicationProductVariant: Identifiable, Hashable, Sendable {
    let id: String
    let productID: String
    let routeIDs: [String]
    let routeTitle: String
    let displayName: String
    let englishDisplayName: String
    let aliases: [String]
    let ingredientIDs: [String]
    let ingredientNames: [String]
    let ingredientEnglishNames: [String]
    let holderOrManufacturer: String
    let holderOrManufacturerFact: String?
    let form: String
    let region: String
    let regulator: String
    let regulatoryStatus: MedicationRegulatoryStatus
    let authorizationIdentifier: String?
    let sourceStatus: String
    let sourceRecords: [MedicationCatalogSource]
    let boundaryNote: String
    let releasePattern: String?
    let packageOrDevice: String?
    let preciseIngredientForms: [MedicationPresentationIngredientForm]
}

struct MedicationCatalogSnapshot: Equatable, Sendable {
    let exposure: MedicationCatalogExposure
    let manifest: MedicationCatalogManifest
    let sources: [MedicationCatalogSource]
    let entries: [MedicationCatalogEntry]

    var acknowledgement: String {
        "本产品使用美国国家医学图书馆（NLM）、NIH/HHS 的公开数据；NLM 不负责本产品，也不认可、推荐或背书本产品。"
    }

    var sourceFreezeSummary: String {
        sources
            .map { "\($0.institution) · \($0.versionOrPublishedAt)" }
            .joined(separator: "\n")
    }
}

struct MedicationCatalogSelectionSnapshotV1: Codable, Equatable, Sendable {
    struct Ingredient: Codable, Equatable, Sendable {
        let id: String
        let nameZH: String
        let nameEN: String
    }

    struct Source: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let versionOrPublishedAt: String
        let retrievedAt: String
    }

    let schemaVersion: String
    let catalogVersion: String
    let catalogContentDigest: String
    let presentationID: String
    let productID: String
    let displayNameZH: String
    let displayNameEN: String
    let ingredients: [Ingredient]
    let dosageForm: String
    let routes: [String]
    let region: String
    let regulator: String
    let regulatoryStatus: MedicationRegulatoryStatus
    let authorizationIdentifier: String?
    let holderOrManufacturer: String?
    let sources: [Source]
    let boundaryNote: String
    let releasePattern: String?
    let packageOrDevice: String?
    let preciseIngredientForms: [MedicationPresentationIngredientForm]
    var integrityDigest: String? = nil

    func encodedString() -> String? {
        var snapshot = self
        snapshot.integrityDigest = snapshot.expectedIntegrityDigest()
        guard snapshot.integrityDigest != nil else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(snapshot) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ value: String) -> Self? {
        guard let data = value.data(using: .utf8) else { return nil }
        guard (try? MedicationCatalogStrictJSONValidator
            .validateSelectionSnapshot(data: data)) != nil else {
            return nil
        }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    var hasValidIntegrityDigest: Bool {
        guard let integrityDigest else { return false }
        return integrityDigest == expectedIntegrityDigest()
    }

    private func expectedIntegrityDigest() -> String? {
        var unsigned = self
        unsigned.integrityDigest = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(unsigned) else { return nil }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var displaySummary: String {
        [
            ingredients.map(\.nameZH).joined(separator: " + "),
            dosageForm,
            routes.compactMap(MedicationRoute.init(rawValue:)).map(\.title)
                .joined(separator: "／"),
            region,
            regulatoryStatus.title,
            "目录 \(catalogVersion)"
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }
}

struct MedicationCatalogReleaseStateManifest: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case pendingHumanReview
        case rejected
        case approved
    }

    let schemaVersion: String
    let status: Status
    let catalogVersion: String
    let message: String
    let candidateResourceExcluded: Bool
    let approvedResourceName: String?
}

enum MedicationCatalogUnavailableReason: Equatable, Sendable {
    case missingResource
    case pendingHumanReview
    case rejectedByHumanReview
    case invalidContent([MedicationCatalogValidationIssue])
    case unreadableContent(String)

    var title: String {
        switch self {
        case .missingResource:
            "目录资源缺失"
        case .pendingHumanReview:
            "正式目录正在等待人工复核"
        case .rejectedByHumanReview:
            "本版目录未获批准"
        case .invalidContent:
            "目录完整性检查失败"
        case .unreadableContent:
            "目录无法读取"
        }
    }

    var detail: String {
        switch self {
        case .missingResource:
            return "App bundle 中没有找到构建期药品目录。"
        case .pendingHumanReview:
            return "候选药品和来源已经整理，但真实人类内容复核尚未完成，因此 Release 不会提供可选目录。"
        case .rejectedByHumanReview:
            return "这版内容已被标记为不采用，App 不会把它用于方案记录。"
        case let .invalidContent(issues):
            guard let first = issues.first else {
                return "目录没有通过结构、来源或版本校验。"
            }
            return "\(first.path)：\(first.message)"
        case let .unreadableContent(message):
            return "JSON 解码失败：\(message)"
        }
    }
}

enum MedicationCatalogLoadState: Equatable, Sendable {
    case available(MedicationCatalogSnapshot)
    case unavailable(MedicationCatalogUnavailableReason)

    var snapshot: MedicationCatalogSnapshot? {
        guard case let .available(snapshot) = self else { return nil }
        return snapshot
    }

    var unavailableReason: MedicationCatalogUnavailableReason? {
        guard case let .unavailable(reason) = self else { return nil }
        return reason
    }
}

private enum MedicationCatalogStrictJSONValidator {
    enum ValidationError: LocalizedError, CustomStringConvertible {
        case expectedObject(String)
        case expectedObjectArray(String)
        case unexpectedKeys(path: String, keys: [String])

        var errorDescription: String? {
            switch self {
            case let .expectedObject(path):
                return "\(path) 必须是 JSON object。"
            case let .expectedObjectArray(path):
                return "\(path) 必须是 JSON object array。"
            case let .unexpectedKeys(path, keys):
                return "\(path) 包含不允许的字段：\(keys.joined(separator: ", "))。"
            }
        }

        var description: String {
            errorDescription ?? "药品目录 JSON schema 校验失败。"
        }
    }

    static func validateContentPack(data: Data) throws {
        let root = try object(
            JSONSerialization.jsonObject(with: data),
            path: "$"
        )
        try requireOnly(
            ["manifest", "sources", "ingredients", "products", "presentations"],
            in: root,
            path: "$"
        )

        let manifest = try object(root["manifest"], path: "$.manifest")
        try requireOnly(
            [
                "schemaVersion",
                "catalogVersion",
                "generatedAt",
                "coverageStatement",
                "supportedRegions",
                "contentDigest",
                "review"
            ],
            in: manifest,
            path: "$.manifest"
        )
        let review = try object(
            manifest["review"],
            path: "$.manifest.review"
        )
        try requireOnly(
            [
                "status",
                "ownerRole",
                "reviewerDisplayName",
                "completedAt",
                "scope"
            ],
            in: review,
            path: "$.manifest.review"
        )

        let sourceKeys: Set<String> = [
            "id",
            "institution",
            "title",
            "versionOrPublishedAt",
            "url",
            "retrievedAt",
            "region",
            "jurisdictionCodes",
            "authorityCodes",
            "licenseIdentifier",
            "licenseURL",
            "redistribution",
            "evidenceKinds",
            "proves",
            "boundary"
        ]
        for (index, source) in try objects(
            root["sources"],
            path: "$.sources"
        ).enumerated() {
            try requireOnly(
                sourceKeys,
                in: source,
                path: "$.sources[\(index)]"
            )
        }

        let ingredientKeys: Set<String> = [
            "id",
            "preferredNameZH",
            "preferredNameEN",
            "exactSubstanceName",
            "aliases",
            "parentActiveMoietyID",
            "activeMoietyName",
            "substanceForm",
            "roles",
            "tier",
            "externalIdentifiers",
            "sourceIDs",
            "boundaryNote"
        ]
        for (index, ingredient) in try objects(
            root["ingredients"],
            path: "$.ingredients"
        ).enumerated() {
            let path = "$.ingredients[\(index)]"
            try requireOnly(ingredientKeys, in: ingredient, path: path)
            try validateExternalIdentifiers(
                ingredient["externalIdentifiers"],
                path: "\(path).externalIdentifiers"
            )
        }

        let productKeys: Set<String> = [
            "id",
            "displayNameZH",
            "displayNameEN",
            "aliases",
            "region",
            "jurisdictionCode",
            "regulator",
            "regulatorCode",
            "regulatoryStatus",
            "authorizationIdentifier",
            "holderOrManufacturer",
            "ingredientLinks",
            "sourceIDs",
            "regulatorySourceIDs",
            "boundaryNote"
        ]
        let productIngredientKeys: Set<String> = [
            "ingredientID",
            "labelStrengthOriginal",
            "activeMoietyBasis",
            "sortOrder"
        ]
        for (index, product) in try objects(
            root["products"],
            path: "$.products"
        ).enumerated() {
            let path = "$.products[\(index)]"
            try requireOnly(productKeys, in: product, path: path)
            for (linkIndex, link) in try objects(
                product["ingredientLinks"],
                path: "\(path).ingredientLinks"
            ).enumerated() {
                try requireOnly(
                    productIngredientKeys,
                    in: link,
                    path: "\(path).ingredientLinks[\(linkIndex)]"
                )
            }
        }

        let presentationKeys: Set<String> = [
            "id",
            "productID",
            "displayNameZH",
            "displayNameEN",
            "dosageForm",
            "authorizedRoutes",
            "evidenceStatus",
            "releasePattern",
            "packageOrDevice",
            "preciseIngredientForms",
            "sourceIDs"
        ]
        let preciseFormKeys: Set<String> = [
            "ingredientID",
            "exactFormName",
            "relationship",
            "externalIdentifiers"
        ]
        for (index, presentation) in try objects(
            root["presentations"],
            path: "$.presentations"
        ).enumerated() {
            let path = "$.presentations[\(index)]"
            try requireOnly(presentationKeys, in: presentation, path: path)
            guard let rawPreciseForms = presentation["preciseIngredientForms"],
                  !(rawPreciseForms is NSNull) else {
                continue
            }
            for (formIndex, form) in try objects(
                rawPreciseForms,
                path: "\(path).preciseIngredientForms"
            ).enumerated() {
                let formPath = "\(path).preciseIngredientForms[\(formIndex)]"
                try requireOnly(preciseFormKeys, in: form, path: formPath)
                try validateExternalIdentifiers(
                    form["externalIdentifiers"],
                    path: "\(formPath).externalIdentifiers"
                )
            }
        }
    }

    static func validateReleaseState(data: Data) throws {
        let root = try object(
            JSONSerialization.jsonObject(with: data),
            path: "$"
        )
        try requireOnly(
            [
                "schemaVersion",
                "status",
                "catalogVersion",
                "message",
                "candidateResourceExcluded",
                "approvedResourceName"
            ],
            in: root,
            path: "$"
        )
    }

    static func validateSelectionSnapshot(data: Data) throws {
        let root = try object(
            JSONSerialization.jsonObject(with: data),
            path: "$"
        )
        try requireOnly(
            [
                "schemaVersion",
                "catalogVersion",
                "catalogContentDigest",
                "presentationID",
                "productID",
                "displayNameZH",
                "displayNameEN",
                "ingredients",
                "dosageForm",
                "routes",
                "region",
                "regulator",
                "regulatoryStatus",
                "authorizationIdentifier",
                "holderOrManufacturer",
                "sources",
                "boundaryNote",
                "releasePattern",
                "packageOrDevice",
                "preciseIngredientForms",
                "integrityDigest"
            ],
            in: root,
            path: "$"
        )
        for (index, ingredient) in try objects(
            root["ingredients"],
            path: "$.ingredients"
        ).enumerated() {
            try requireOnly(
                ["id", "nameZH", "nameEN"],
                in: ingredient,
                path: "$.ingredients[\(index)]"
            )
        }
        for (index, source) in try objects(
            root["sources"],
            path: "$.sources"
        ).enumerated() {
            try requireOnly(
                ["id", "title", "versionOrPublishedAt", "retrievedAt"],
                in: source,
                path: "$.sources[\(index)]"
            )
        }
        for (index, form) in try objects(
            root["preciseIngredientForms"],
            path: "$.preciseIngredientForms"
        ).enumerated() {
            let path = "$.preciseIngredientForms[\(index)]"
            try requireOnly(
                [
                    "ingredientID",
                    "exactFormName",
                    "relationship",
                    "externalIdentifiers"
                ],
                in: form,
                path: path
            )
            try validateExternalIdentifiers(
                form["externalIdentifiers"],
                path: "\(path).externalIdentifiers"
            )
        }
    }

    private static func validateExternalIdentifiers(
        _ value: Any?,
        path: String
    ) throws {
        for (index, identifier) in try objects(value, path: path).enumerated() {
            try requireOnly(
                ["system", "value"],
                in: identifier,
                path: "\(path)[\(index)]"
            )
        }
    }

    private static func object(
        _ value: Any?,
        path: String
    ) throws -> [String: Any] {
        guard let value = value as? [String: Any] else {
            throw ValidationError.expectedObject(path)
        }
        return value
    }

    private static func objects(
        _ value: Any?,
        path: String
    ) throws -> [[String: Any]] {
        guard let value = value as? [[String: Any]] else {
            throw ValidationError.expectedObjectArray(path)
        }
        return value
    }

    private static func requireOnly(
        _ allowedKeys: Set<String>,
        in object: [String: Any],
        path: String
    ) throws {
        let unexpected = Set(object.keys)
            .subtracting(allowedKeys)
            .sorted()
        guard unexpected.isEmpty else {
            throw ValidationError.unexpectedKeys(
                path: path,
                keys: unexpected
            )
        }
    }
}

struct MedicationCatalogRepository: Sendable {
    static let resourceName = "medication-catalog-candidate-v1"
    static let releaseStateResourceName = "medication-catalog-release-state-v1"

    let state: MedicationCatalogLoadState

    init(data: Data, exposure: MedicationCatalogExposure) {
        do {
            try MedicationCatalogStrictJSONValidator
                .validateContentPack(data: data)
            let decoder = JSONDecoder()
            let pack = try decoder.decode(MedicationCatalogPack.self, from: data)

            let candidateIssues = MedicationCatalogValidator.issues(
                in: pack,
                exposure: .candidate
            )
            guard candidateIssues.isEmpty else {
                state = .unavailable(.invalidContent(candidateIssues))
                return
            }

            if case .release = exposure {
                switch pack.manifest.review.status {
                case .candidate:
                    state = .unavailable(.pendingHumanReview)
                    return
                case .rejected:
                    state = .unavailable(.rejectedByHumanReview)
                    return
                case .approved:
                    break
                }
                let releaseIssues = MedicationCatalogValidator.issues(
                    in: pack,
                    exposure: .release
                )
                guard releaseIssues.isEmpty else {
                    state = .unavailable(.invalidContent(releaseIssues))
                    return
                }
            }

            state = .available(
                Self.makeSnapshot(from: pack, exposure: exposure)
            )
        } catch {
            state = .unavailable(.unreadableContent(String(describing: error)))
        }
    }

    init(
        bundle: Bundle,
        exposure: MedicationCatalogExposure,
        resourceName: String = Self.resourceName
    ) {
        guard let url = bundle.url(
            forResource: resourceName,
            withExtension: "json"
        ) else {
            self.init(state: .unavailable(.missingResource))
            return
        }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize > 0,
                  fileSize <= 1_048_576
            else {
                self.init(
                    state: .unavailable(
                        .unreadableContent("目录资源不是 1 MiB 以内的普通非空文件。")
                    )
                )
                return
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            self.init(data: data, exposure: exposure)
        } catch {
            self.init(
                state: .unavailable(.unreadableContent(String(describing: error)))
            )
        }
    }

    static func releaseState(bundle: Bundle) -> MedicationCatalogLoadState {
        guard let url = bundle.url(
            forResource: releaseStateResourceName,
            withExtension: "json"
        ) else {
            return .unavailable(.missingResource)
        }
        do {
            let data = try Data(contentsOf: url)
            return releaseState(data: data, approvedResourceBundle: bundle)
        } catch {
            return .unavailable(.unreadableContent(String(describing: error)))
        }
    }

    static func releaseState(
        data: Data,
        approvedResourceBundle: Bundle? = nil
    ) -> MedicationCatalogLoadState {
        do {
            try MedicationCatalogStrictJSONValidator
                .validateReleaseState(data: data)
            let manifest = try JSONDecoder().decode(
                MedicationCatalogReleaseStateManifest.self,
                from: data
            )
            guard manifest.schemaVersion == "1",
                  !manifest.catalogVersion.isEmpty,
                  !manifest.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  manifest.candidateResourceExcluded
            else {
                return .unavailable(
                    .unreadableContent("Release 目录状态清单不完整。")
                )
            }
            switch manifest.status {
            case .pendingHumanReview:
                return .unavailable(.pendingHumanReview)
            case .rejected:
                return .unavailable(.rejectedByHumanReview)
            case .approved:
                guard let resourceName = manifest.approvedResourceName,
                      !resourceName.isEmpty,
                      let approvedResourceBundle
                else {
                    return .unavailable(
                        .unreadableContent("已批准目录没有指定正式资源。")
                    )
                }
                return MedicationCatalogRepository(
                    bundle: approvedResourceBundle,
                    exposure: .release,
                    resourceName: resourceName
                ).state
            }
        } catch {
            return .unavailable(.unreadableContent(String(describing: error)))
        }
    }

    private init(state: MedicationCatalogLoadState) {
        self.state = state
    }

    private static func makeSnapshot(
        from pack: MedicationCatalogPack,
        exposure: MedicationCatalogExposure
    ) -> MedicationCatalogSnapshot {
        let ingredientsByID = pack.ingredients.reduce(
            into: [String: MedicationIngredient]()
        ) {
            if $0[$1.id] == nil {
                $0[$1.id] = $1
            }
        }
        let sourcesByID = pack.sources.reduce(
            into: [String: MedicationCatalogSource]()
        ) {
            if $0[$1.id] == nil {
                $0[$1.id] = $1
            }
        }
        let presentationsByProductID = Dictionary(
            grouping: pack.presentations,
            by: \.productID
        )

        let entries = pack.ingredients.map { ingredient in
            let matchingProducts = pack.products.filter {
                $0.ingredientLinks.contains { $0.ingredientID == ingredient.id }
            }
            let variants = matchingProducts.flatMap { product -> [MedicationProductVariant] in
                let ingredientRecords = product.ingredientLinks
                    .sorted {
                        ($0.sortOrder, $0.ingredientID) < ($1.sortOrder, $1.ingredientID)
                    }
                    .compactMap { ingredientsByID[$0.ingredientID] }
                return (presentationsByProductID[product.id] ?? []).map { presentation in
                    let routes = presentation.authorizedRoutes
                    let holder = product.holderOrManufacturer ?? "通用记录模板"
                    let sourceIDs = Array(Set(product.sourceIDs + presentation.sourceIDs))
                        .sorted()
                    let sources = sourceIDs.compactMap { sourcesByID[$0] }
                    let retrievedAt = sources.map(\.retrievedAt).max() ?? "未记录"
                    return MedicationProductVariant(
                        id: presentation.id,
                        productID: product.id,
                        routeIDs: routes.map(\.rawValue),
                        routeTitle: routes.map(\.title).joined(separator: "／"),
                        displayName: presentation.displayNameZH,
                        englishDisplayName: presentation.displayNameEN,
                        aliases: product.aliases,
                        ingredientIDs: ingredientRecords.map(\.id),
                        ingredientNames: ingredientRecords.map(\.preferredNameZH),
                        ingredientEnglishNames: ingredientRecords.map(\.preferredNameEN),
                        holderOrManufacturer: holder,
                        holderOrManufacturerFact: product.holderOrManufacturer,
                        form: presentation.dosageForm,
                        region: product.region,
                        regulator: product.regulator,
                        regulatoryStatus: product.regulatoryStatus,
                        authorizationIdentifier: product.authorizationIdentifier,
                        sourceStatus: "\(product.region) · \(product.regulatoryStatus.title) · 查阅 \(retrievedAt)",
                        sourceRecords: sources,
                        boundaryNote: product.boundaryNote,
                        releasePattern: presentation.releasePattern,
                        packageOrDevice: presentation.packageOrDevice,
                        preciseIngredientForms: presentation.preciseIngredientForms ?? []
                    )
                }
            }
            .sorted {
                ($0.form, $0.displayName, $0.id) < ($1.form, $1.displayName, $1.id)
            }

            let routeMap = Dictionary(
                grouping: variants.flatMap { variant in
                    variant.routeIDs.compactMap { rawValue in
                        MedicationRoute(rawValue: rawValue).map { (route: $0, form: variant.form) }
                    }
                },
                by: { $0.route }
            )
            let routes = routeMap.keys.sorted { $0.rawValue < $1.rawValue }.map { route in
                let forms = Array(Set(routeMap[route, default: []].map(\.form))).sorted()
                return MedicationCatalogRoute(
                    id: route.rawValue,
                    title: route.title,
                    detail: forms.joined(separator: "、")
                )
            }
            let forms = Array(Set(variants.map(\.form))).sorted().joined(separator: "、")

            return MedicationCatalogEntry(
                id: ingredient.id,
                catalogVersion: pack.manifest.catalogVersion,
                catalogContentDigest: pack.manifest.contentDigest,
                name: ingredient.preferredNameZH,
                englishName: ingredient.preferredNameEN,
                aliases: ingredient.aliases,
                forms: forms,
                roles: ingredient.roles,
                tier: ingredient.tier,
                boundaryNote: ingredient.boundaryNote,
                externalIdentifiers: ingredient.externalIdentifiers,
                routes: routes,
                products: variants
            )
        }
        .sorted {
            if $0.tier.sortOrder != $1.tier.sortOrder {
                return $0.tier.sortOrder < $1.tier.sortOrder
            }
            return $0.id < $1.id
        }

        return MedicationCatalogSnapshot(
            exposure: exposure,
            manifest: pack.manifest,
            sources: pack.sources,
            entries: entries
        )
    }
}

private final class MedicationCatalogBundleToken {}

enum MedicationCatalog {
#if DEBUG
    static let loadState = MedicationCatalogRepository(
        bundle: Bundle(for: MedicationCatalogBundleToken.self),
        exposure: .candidate
    ).state
#else
    static let loadState = MedicationCatalogRepository.releaseState(
        bundle: Bundle(for: MedicationCatalogBundleToken.self)
    )
#endif

    static var entries: [MedicationCatalogEntry] {
        loadState.snapshot?.entries ?? []
    }

    static var manifest: MedicationCatalogManifest? {
        loadState.snapshot?.manifest
    }

    static func search(_ query: String) -> [MedicationCatalogEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return entries }
        return entries.filter { $0.searchText.localizedCaseInsensitiveContains(term) }
    }
}
