import Foundation

private enum RegimenAnalysisStrictJSONValidator {
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
            errorDescription ?? "分析内容 JSON schema 校验失败。"
        }
    }

    static func validateContentPack(data: Data) throws {
        let root = try object(
            JSONSerialization.jsonObject(with: data),
            path: "$"
        )
        try requireOnly(
            [
                "manifest",
                "sources",
                "cards",
                "ingredientProfiles",
                "safetyRules"
            ],
            in: root,
            path: "$"
        )

        let manifest = try object(root["manifest"], path: "$.manifest")
        try requireOnly(
            [
                "schemaVersion",
                "contentPackVersion",
                "ruleSetVersion",
                "requiredCatalogVersion",
                "requiredCatalogContentDigest",
                "generatedAt",
                "coverageStatement",
                "contentDigest",
                "requiredIngredientIDs",
                "globalBoundaryCardIDs",
                "limitedCardIDs",
                "review",
                "medicalClassificationStatus"
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
                "contentReviewerDisplayName",
                "medicalReviewerDisplayName",
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
            "officialURL",
            "retrievedAt",
            "applicablePopulation",
            "applicableRegions",
            "licenseIdentifier",
            "licenseURL",
            "redistribution",
            "attributionText",
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

        let cardKeys: Set<String> = [
            "id",
            "kind",
            "evidenceBasis",
            "title",
            "body",
            "boundary",
            "sourceIDs",
            "sortOrder"
        ]
        for (index, card) in try objects(
            root["cards"],
            path: "$.cards"
        ).enumerated() {
            try requireOnly(
                cardKeys,
                in: card,
                path: "$.cards[\(index)]"
            )
        }

        let profileKeys: Set<String> = [
            "ingredientID",
            "ingredientNameZH",
            "correspondence",
            "safetyFlags",
            "cardIDs",
            "boundary"
        ]
        for (index, profile) in try objects(
            root["ingredientProfiles"],
            path: "$.ingredientProfiles"
        ).enumerated() {
            try requireOnly(
                profileKeys,
                in: profile,
                path: "$.ingredientProfiles[\(index)]"
            )
        }

        let ruleKeys: Set<String> = [
            "id",
            "priority",
            "condition",
            "stopCardID"
        ]
        for (index, rule) in try objects(
            root["safetyRules"],
            path: "$.safetyRules"
        ).enumerated() {
            try requireOnly(
                ruleKeys,
                in: rule,
                path: "$.safetyRules[\(index)]"
            )
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
                "contentPackVersion",
                "ruleSetVersion",
                "message",
                "candidateResourceExcluded",
                "medicalClassificationResolved",
                "approvedResourceName"
            ],
            in: root,
            path: "$"
        )
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

struct RegimenAnalysisReleaseStateManifest: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case pendingHumanReviewAndClassification
        case rejected
        case approved
    }

    let schemaVersion: String
    let status: Status
    let contentPackVersion: String
    let ruleSetVersion: String
    let message: String
    let candidateResourceExcluded: Bool
    let medicalClassificationResolved: Bool
    let approvedResourceName: String?
}

enum RegimenAnalysisUnavailableReason: Equatable, Sendable {
    case missingResource
    case pendingHumanReviewAndClassification
    case rejectedByHumanReview
    case medicationCatalogUnavailable
    case invalidContent([RegimenAnalysisValidationIssue])
    case unreadableContent(String)

    var title: String {
        switch self {
        case .missingResource:
            "分析内容资源缺失"
        case .pendingHumanReviewAndClassification:
            "正式方案分析正在等待复核"
        case .rejectedByHumanReview:
            "本版方案分析未获采用"
        case .medicationCatalogUnavailable:
            "正式药品目录尚不可用"
        case .invalidContent:
            "方案分析完整性检查失败"
        case .unreadableContent:
            "方案分析内容无法读取"
        }
    }

    var detail: String {
        switch self {
        case .missingResource:
            return "App bundle 中没有找到构建期分析内容。你的方案原始记录没有被修改。"
        case .pendingHumanReviewAndClassification:
            return "候选规则、来源和逐药覆盖已经整理，但真实人类内容复核、医疗复核或发行分类尚未完成，因此 Release 不会运行这套分析。"
        case .rejectedByHumanReview:
            return "这版内容已被标记为不采用，App 不会用它整理你的方案。"
        case .medicationCatalogUnavailable:
            return "方案分析必须与已批准且版本、digest 和成分集合一致的正式药品目录一起启用。"
        case let .invalidContent(issues):
            guard let first = issues.first else {
                return "规则、来源或版本没有通过校验。"
            }
            return "\(first.path)：\(first.message)"
        case let .unreadableContent(message):
            return "JSON 解码失败：\(message)"
        }
    }
}

enum RegimenAnalysisLoadState: Equatable, Sendable {
    case available(RegimenAnalysisContentPack)
    case unavailable(RegimenAnalysisUnavailableReason)

    var pack: RegimenAnalysisContentPack? {
        guard case let .available(pack) = self else { return nil }
        return pack
    }

    var unavailableReason: RegimenAnalysisUnavailableReason? {
        guard case let .unavailable(reason) = self else { return nil }
        return reason
    }
}

struct RegimenAnalysisContentRepository: Sendable {
    static let resourceName = "regimen-analysis-candidate-v1"
    static let releaseStateResourceName = "regimen-analysis-release-state-v1"

    let state: RegimenAnalysisLoadState

    init(
        data: Data,
        exposure: RegimenAnalysisExposure,
        medicationCatalogState: MedicationCatalogLoadState? = nil
    ) {
        do {
            try RegimenAnalysisStrictJSONValidator
                .validateContentPack(data: data)
            let pack = try JSONDecoder().decode(
                RegimenAnalysisContentPack.self,
                from: data
            )
            let candidateIssues = RegimenAnalysisContentValidator.issues(
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
                    state = .unavailable(.pendingHumanReviewAndClassification)
                    return
                case .rejected:
                    state = .unavailable(.rejectedByHumanReview)
                    return
                case .approved:
                    break
                }
                let releaseIssues = RegimenAnalysisContentValidator.issues(
                    in: pack,
                    exposure: .release
                )
                guard releaseIssues.isEmpty else {
                    state = .unavailable(.invalidContent(releaseIssues))
                    return
                }
                guard let medicationCatalogState,
                      case let .available(catalogSnapshot) =
                        medicationCatalogState,
                      catalogSnapshot.exposure == .release,
                      pack.manifest.requiredCatalogVersion
                        == catalogSnapshot.manifest.catalogVersion,
                      pack.manifest.requiredCatalogContentDigest
                        == catalogSnapshot.manifest.contentDigest,
                      Set(pack.manifest.requiredIngredientIDs)
                        == Set(catalogSnapshot.entries.map(\.id)) else {
                    state = .unavailable(.medicationCatalogUnavailable)
                    return
                }
            }
            state = .available(pack)
        } catch {
            state = .unavailable(.unreadableContent(String(describing: error)))
        }
    }

    init(
        bundle: Bundle,
        exposure: RegimenAnalysisExposure,
        resourceName: String = Self.resourceName,
        medicationCatalogState: MedicationCatalogLoadState? = nil
    ) {
        guard let url = bundle.url(
            forResource: resourceName,
            withExtension: "json"
        ) else {
            self.init(state: .unavailable(.missingResource))
            return
        }
        do {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize > 0,
                  fileSize <= 1_048_576 else {
                self.init(
                    state: .unavailable(
                        .unreadableContent(
                            "分析内容不是 1 MiB 以内的普通非空文件。"
                        )
                    )
                )
                return
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            self.init(
                data: data,
                exposure: exposure,
                medicationCatalogState: medicationCatalogState
            )
        } catch {
            self.init(
                state: .unavailable(
                    .unreadableContent(String(describing: error))
                )
            )
        }
    }

    static func releaseState(bundle: Bundle) -> RegimenAnalysisLoadState {
        guard let url = bundle.url(
            forResource: releaseStateResourceName,
            withExtension: "json"
        ) else {
            return .unavailable(.missingResource)
        }
        do {
            return releaseState(
                data: try Data(contentsOf: url),
                approvedResourceBundle: bundle,
                medicationCatalogState:
                    MedicationCatalogRepository.releaseState(bundle: bundle)
            )
        } catch {
            return .unavailable(
                .unreadableContent(String(describing: error))
            )
        }
    }

    static func releaseState(
        data: Data,
        approvedResourceBundle: Bundle? = nil,
        medicationCatalogState: MedicationCatalogLoadState? = nil
    ) -> RegimenAnalysisLoadState {
        do {
            try RegimenAnalysisStrictJSONValidator
                .validateReleaseState(data: data)
            let manifest = try JSONDecoder().decode(
                RegimenAnalysisReleaseStateManifest.self,
                from: data
            )
            guard manifest.schemaVersion == "1",
                  !manifest.contentPackVersion.isEmpty,
                  !manifest.ruleSetVersion.isEmpty,
                  !manifest.message
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty,
                  manifest.candidateResourceExcluded else {
                return .unavailable(
                    .unreadableContent("Release 分析状态清单不完整。")
                )
            }
            switch manifest.status {
            case .pendingHumanReviewAndClassification:
                return .unavailable(.pendingHumanReviewAndClassification)
            case .rejected:
                return .unavailable(.rejectedByHumanReview)
            case .approved:
                guard manifest.medicalClassificationResolved,
                      let resourceName = manifest.approvedResourceName,
                      !resourceName.isEmpty,
                      let approvedResourceBundle else {
                    return .unavailable(
                        .unreadableContent(
                            "已批准分析缺少分类结论或正式资源。"
                        )
                    )
                }
                return RegimenAnalysisContentRepository(
                    bundle: approvedResourceBundle,
                    exposure: .release,
                    resourceName: resourceName,
                    medicationCatalogState: medicationCatalogState
                ).state
            }
        } catch {
            return .unavailable(
                .unreadableContent(String(describing: error))
            )
        }
    }

    private init(state: RegimenAnalysisLoadState) {
        self.state = state
    }
}

extension RegimenAnalysisRequestV1 {
    init(
        regimen: CoreRegimenVersionSnapshot,
        currentCatalog: MedicationCatalogSnapshot? =
            MedicationCatalog.loadState.snapshot
    ) {
        self.init(
            schemaVersion: "1",
            regimenVersionID: regimen.id,
            regimenCode: regimen.code,
            regimenTitle: regimen.title,
            effectiveStartDate: regimen.effectiveStartDate.iso8601,
            items: regimen.items.enumerated().map { position, item in
                let catalogSnapshot = MedicationCatalogSelectionSnapshotV1
                    .decode(item.productSnapshot)
                let status: RegimenAnalysisItemSnapshotStatus
                let ingredientIDs: [String]
                let presentationID: String?

                if item.catalogProductID == nil {
                    status = .customEntry
                    ingredientIDs = []
                    presentationID = nil
                } else if let catalogSnapshot,
                          catalogSnapshot.schemaVersion == "1",
                          catalogSnapshot.catalogVersion == item.catalogVersion,
                          catalogSnapshot.presentationID == item.catalogProductID,
                          catalogSnapshot.hasValidIntegrityDigest,
                          Self.isSHA256Hex(
                              catalogSnapshot.catalogContentDigest
                          ),
                          !catalogSnapshot.ingredients.isEmpty,
                          Set(catalogSnapshot.ingredients.map(\.id)).count
                            == catalogSnapshot.ingredients.count,
                          catalogSnapshot.ingredients.allSatisfy({
                              !$0.id.trimmingCharacters(
                                  in: .whitespacesAndNewlines
                              ).isEmpty
                          }),
                          Self.catalogSnapshotMatchesCurrentCatalogWhenAvailable(
                            catalogSnapshot,
                            currentCatalog: currentCatalog
                          ) {
                    status = .verifiedCatalogSnapshot
                    ingredientIDs = catalogSnapshot.ingredients.map(\.id)
                        .sorted()
                    presentationID = catalogSnapshot.presentationID
                } else {
                    status = .unreadableCatalogSnapshot
                    ingredientIDs = []
                    presentationID = nil
                }

                return Item(
                    itemID: item.id,
                    position: position,
                    displayNameOriginal: item.displayName,
                    dosageFormOriginal: item.dosageForm,
                    routeOriginal: item.route,
                    doseOriginal: item.doseOriginal,
                    unitOriginal: item.unitOriginal,
                    scheduleSummaryOriginal: item.scheduleSummary,
                    catalogVersion: item.catalogVersion,
                    presentationID: presentationID,
                    exactIngredientIDs: ingredientIDs,
                    snapshotStatus: status
                )
            }
        )
    }

    var ingredientIDs: Set<String> {
        Set(items.flatMap(\.exactIngredientIDs))
    }

    private static func catalogSnapshotMatchesCurrentCatalogWhenAvailable(
        _ selection: MedicationCatalogSelectionSnapshotV1,
        currentCatalog: MedicationCatalogSnapshot?
    ) -> Bool {
        guard let currentCatalog,
              currentCatalog.manifest.catalogVersion
                == selection.catalogVersion else {
            return true
        }
        guard currentCatalog.manifest.contentDigest
                == selection.catalogContentDigest,
              let product = currentCatalog.entries
                .flatMap(\.products)
                .first(where: { $0.id == selection.presentationID }) else {
            return false
        }
        let expectedIngredients = zip(
            product.ingredientIDs,
            zip(
                product.ingredientNames,
                product.ingredientEnglishNames
            )
        ).map {
            MedicationCatalogSelectionSnapshotV1.Ingredient(
                id: $0.0,
                nameZH: $0.1.0,
                nameEN: $0.1.1
            )
        }
        let expectedSources = product.sourceRecords.map {
            MedicationCatalogSelectionSnapshotV1.Source(
                id: $0.id,
                title: $0.title,
                versionOrPublishedAt: $0.versionOrPublishedAt,
                retrievedAt: $0.retrievedAt
            )
        }
        return product.productID == selection.productID
            && product.displayName == selection.displayNameZH
            && product.englishDisplayName == selection.displayNameEN
            && expectedIngredients == selection.ingredients
            && product.form == selection.dosageForm
            && product.routeIDs.sorted() == selection.routes.sorted()
            && product.region == selection.region
            && product.regulator == selection.regulator
            && product.regulatoryStatus == selection.regulatoryStatus
            && product.authorizationIdentifier
                == selection.authorizationIdentifier
            && product.holderOrManufacturerFact
                == selection.holderOrManufacturer
            && expectedSources == selection.sources
            && product.boundaryNote == selection.boundaryNote
            && product.releasePattern == selection.releasePattern
            && product.packageOrDevice == selection.packageOrDevice
            && product.preciseIngredientForms
                == selection.preciseIngredientForms
    }

    private static func isSHA256Hex(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                (48 ... 57).contains($0.value)
                    || (97 ... 102).contains($0.value)
            }
    }
}

private final class RegimenAnalysisBundleToken {}

enum RegimenAnalysisContent {
#if DEBUG
    static let loadState = RegimenAnalysisContentRepository(
        bundle: Bundle(for: RegimenAnalysisBundleToken.self),
        exposure: .candidate
    ).state
#else
    static let loadState = RegimenAnalysisContentRepository.releaseState(
        bundle: Bundle(for: RegimenAnalysisBundleToken.self)
    )
#endif
}
