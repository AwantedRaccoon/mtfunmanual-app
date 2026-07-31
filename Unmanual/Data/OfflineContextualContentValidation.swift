import CryptoKit
import Foundation

enum OfflineContextualContentLimits {
    static let maximumJSONBytes = 4 * 1_024 * 1_024
    static let maximumStringBytes = 16 * 1_024
    static let maximumDepth = 32
    static let maximumCards = 100
    static let maximumSources = 256
    static let maximumScenarioAnchors = 128
    static let maximumTitleScalars = 160
    static let maximumSummaryScalars = 2_000
    static let maximumBoundaryScalars = 1_000
    static let maximumAliasesPerCard = 24
    static let maximumAliasScalars = 80
    static let maximumQueryScalars = 80
    static let maximumQueryTokens = 8
}

indirect enum OfflineContextualJSONValue: Equatable, Sendable {
    case object([String: OfflineContextualJSONValue])
    case array([OfflineContextualJSONValue])
    case string(String)
    case integer(Int)
    case bool(Bool)
    case null
}

enum OfflineContextualContentDecoder {
    struct Output {
        let pack: OfflineContextualContentPack
        let root: OfflineContextualJSONValue
    }

    static func decode(_ data: Data) throws -> Output {
        guard !data.isEmpty else {
            throw issue("input.empty", "$", "内容包为空。")
        }
        guard data.count <= OfflineContextualContentLimits.maximumJSONBytes else {
            throw issue("input.tooLarge", "$", "内容包超过 4 MiB 上限。")
        }

        do {
            try StrictJSONDuplicateKeyScanner.validate(
                data,
                maximumDepth: OfflineContextualContentLimits.maximumDepth,
                maximumStringBytes:
                    OfflineContextualContentLimits.maximumStringBytes
            )
        } catch let error as PortableDataV2Error {
            switch error {
            case let .duplicateJSONKey(key):
                throw issue(
                    "json.duplicateKey",
                    "$",
                    "JSON 含重复字段 \(key)。"
                )
            case .excessiveDepth:
                throw issue(
                    "json.excessiveDepth",
                    "$",
                    "JSON 嵌套超过 32 层。"
                )
            case .inputTooLarge:
                throw issue(
                    "json.stringTooLarge",
                    "$",
                    "JSON 字符串超过 16 KiB。"
                )
            default:
                throw issue("json.invalid", "$", "JSON 语法无效。")
            }
        } catch {
            throw issue("json.invalid", "$", "JSON 语法无效。")
        }

        var parser = OfflineContextualJSONParser(data: data)
        let root = try parser.parse()
        try OfflineContextualContentShapeValidator.validate(root)

        let pack: OfflineContextualContentPack
        do {
            pack = try JSONDecoder().decode(
                OfflineContextualContentPack.self,
                from: data
            )
        } catch {
            throw issue(
                "decode.invalid",
                "$",
                "内容包字段类型或枚举值无效。"
            )
        }
        return Output(pack: pack, root: root)
    }

    private static func issue(
        _ code: String,
        _ path: String,
        _ message: String
    ) -> OfflineContextualContentValidationIssue {
        OfflineContextualContentValidationIssue(
            code: code,
            path: path,
            message: message
        )
    }
}

private struct OfflineContextualJSONParser {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func parse() throws -> OfflineContextualJSONValue {
        let value = try parseValue(depth: 0, path: "$")
        skipWhitespace()
        guard index == bytes.count else {
            throw issue("json.invalid", "$", "JSON 尾部含多余内容。")
        }
        return value
    }

    private mutating func parseValue(
        depth: Int,
        path: String
    ) throws -> OfflineContextualJSONValue {
        guard depth <= OfflineContextualContentLimits.maximumDepth else {
            throw issue(
                "json.excessiveDepth",
                path,
                "JSON 嵌套超过 32 层。"
            )
        }
        skipWhitespace()
        guard index < bytes.count else {
            throw issue("json.invalid", path, "JSON 意外结束。")
        }
        switch bytes[index] {
        case 0x7B:
            return try parseObject(depth: depth, path: path)
        case 0x5B:
            return try parseArray(depth: depth, path: path)
        case 0x22:
            return .string(try parseString(path: path))
        case 0x74:
            try consume("true", path: path)
            return .bool(true)
        case 0x66:
            try consume("false", path: path)
            return .bool(false)
        case 0x6E:
            try consume("null", path: path)
            return .null
        default:
            return .integer(try parseInteger(path: path))
        }
    }

    private mutating func parseObject(
        depth: Int,
        path: String
    ) throws -> OfflineContextualJSONValue {
        index += 1
        skipWhitespace()
        if consumeIf(0x7D) {
            return .object([:])
        }
        var object: [String: OfflineContextualJSONValue] = [:]
        while true {
            skipWhitespace()
            let key = try parseString(path: path)
            skipWhitespace()
            guard consumeIf(0x3A) else {
                throw issue("json.invalid", path, "字段后缺少冒号。")
            }
            let childPath = "\(path).\(key)"
            object[key] = try parseValue(
                depth: depth + 1,
                path: childPath
            )
            skipWhitespace()
            if consumeIf(0x7D) {
                return .object(object)
            }
            guard consumeIf(0x2C) else {
                throw issue("json.invalid", path, "对象缺少分隔符。")
            }
        }
    }

    private mutating func parseArray(
        depth: Int,
        path: String
    ) throws -> OfflineContextualJSONValue {
        index += 1
        skipWhitespace()
        if consumeIf(0x5D) {
            return .array([])
        }
        var array: [OfflineContextualJSONValue] = []
        while true {
            array.append(
                try parseValue(
                    depth: depth + 1,
                    path: "\(path)[\(array.count)]"
                )
            )
            skipWhitespace()
            if consumeIf(0x5D) {
                return .array(array)
            }
            guard consumeIf(0x2C) else {
                throw issue("json.invalid", path, "数组缺少分隔符。")
            }
        }
    }

    private mutating func parseString(path: String) throws -> String {
        guard consumeIf(0x22) else {
            throw issue("json.invalid", path, "应为 JSON 字符串。")
        }
        let start = index - 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
                continue
            }
            if byte == 0x5C {
                escaped = true
                continue
            }
            if byte == 0x22 {
                let byteCount = index - start
                guard byteCount <=
                        OfflineContextualContentLimits.maximumStringBytes + 2
                else {
                    throw issue(
                        "json.stringTooLarge",
                        path,
                        "JSON 字符串超过 16 KiB。"
                    )
                }
                do {
                    return try JSONDecoder().decode(
                        String.self,
                        from: Data(bytes[start..<index])
                    )
                } catch {
                    throw issue(
                        "json.invalid",
                        path,
                        "JSON 字符串转义无效。"
                    )
                }
            }
            guard byte >= 0x20 else {
                throw issue(
                    "json.invalid",
                    path,
                    "JSON 字符串含控制字符。"
                )
            }
        }
        throw issue("json.invalid", path, "JSON 字符串未闭合。")
    }

    private mutating func parseInteger(path: String) throws -> Int {
        let start = index
        while index < bytes.count,
              ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D]
                .contains(bytes[index]) {
            index += 1
        }
        guard index > start else {
            throw issue("json.invalid", path, "JSON 值无效。")
        }
        let token = String(
            decoding: bytes[start..<index],
            as: UTF8.self
        )
        let canonical: Bool
        if token == "0" {
            canonical = true
        } else {
            canonical = token.first.map { ("1"..."9").contains($0) }
                == true
                && token.dropFirst().allSatisfy { ("0"..."9").contains($0) }
        }
        guard canonical, let value = Int(token) else {
            throw issue(
                "number.noncanonical",
                path,
                "数字必须是无符号规范十进制整数。"
            )
        }
        return value
    }

    private mutating func consume(
        _ literal: String,
        path: String
    ) throws {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)]) == expected
        else {
            throw issue("json.invalid", path, "JSON literal 无效。")
        }
        index += expected.count
    }

    private mutating func skipWhitespace() {
        while index < bytes.count,
              [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
    }

    private mutating func consumeIf(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else {
            return false
        }
        index += 1
        return true
    }

    private func issue(
        _ code: String,
        _ path: String,
        _ message: String
    ) -> OfflineContextualContentValidationIssue {
        OfflineContextualContentValidationIssue(
            code: code,
            path: path,
            message: message
        )
    }
}

private enum OfflineContextualContentShapeValidator {
    private static let rootKeys: Set<String> = [
        "manifest", "sources", "cards", "scenarioAnchors", "attribution"
    ]
    private static let manifestKeys: Set<String> = [
        "schemaVersion", "contentVersion", "locale", "generatedAt",
        "retrievedAt", "expiresAt", "sourceCommit", "contentDigest",
        "sourceCount", "cardCount", "scenarioAnchorCount", "review",
        "classificationStatus"
    ]
    private static let reviewKeys: Set<String> = [
        "status", "ownerRole", "contentReviewerDisplayName",
        "medicalReviewerDisplayName", "completedAt", "scope"
    ]
    private static let sourceKeys: Set<String> = [
        "id", "rightsHolder", "title", "versionOrPublishedAt",
        "retrievedAt", "expiresAt", "sourceStatus", "url",
        "licenseIdentifier", "licenseURL", "distributionMode",
        "applicableRegions", "applicablePopulations", "boundary"
    ]
    private static let cardKeys: Set<String> = [
        "id", "title", "summary", "applicabilityBoundary", "contentType",
        "category", "aliases", "sourceIDs", "displayOrder",
        "contentVersion", "cardDigest", "retrievedAt", "expiresAt",
        "originalURL", "provenance"
    ]
    private static let provenanceKeys: Set<String> = [
        "sourceRepository", "sourceCommit", "sourcePath",
        "sourceFileSHA256", "adaptationStatus", "modificationNote"
    ]
    private static let anchorKeys: Set<String> = [
        "id", "scenario", "purpose", "displayOrder", "cardID"
    ]
    private static let attributionKeys: Set<String> = [
        "sourceRepository", "sourceCommit", "creator",
        "licenseIdentifier", "licenseURL", "adaptationStatus",
        "modificationNote", "shareAlikeStatement"
    ]

    static func validate(_ root: OfflineContextualJSONValue) throws {
        let object = try exactObject(root, keys: rootKeys, path: "$")
        let manifest = try exactObject(
            required(object, "manifest", path: "$"),
            keys: manifestKeys,
            path: "$.manifest"
        )
        _ = try exactObject(
            required(manifest, "review", path: "$.manifest"),
            keys: reviewKeys,
            path: "$.manifest.review"
        )

        let sources = try array(
            required(object, "sources", path: "$"),
            path: "$.sources"
        )
        for (index, source) in sources.enumerated() {
            _ = try exactObject(
                source,
                keys: sourceKeys,
                path: "$.sources[\(index)]"
            )
        }

        let cards = try array(
            required(object, "cards", path: "$"),
            path: "$.cards"
        )
        for (index, cardValue) in cards.enumerated() {
            let path = "$.cards[\(index)]"
            let card = try exactObject(
                cardValue,
                keys: cardKeys,
                path: path
            )
            _ = try exactObject(
                required(card, "provenance", path: path),
                keys: provenanceKeys,
                path: "\(path).provenance"
            )
        }

        let anchors = try array(
            required(object, "scenarioAnchors", path: "$"),
            path: "$.scenarioAnchors"
        )
        for (index, anchor) in anchors.enumerated() {
            _ = try exactObject(
                anchor,
                keys: anchorKeys,
                path: "$.scenarioAnchors[\(index)]"
            )
        }
        _ = try exactObject(
            required(object, "attribution", path: "$"),
            keys: attributionKeys,
            path: "$.attribution"
        )
    }

    private static func exactObject(
        _ value: OfflineContextualJSONValue,
        keys: Set<String>,
        path: String
    ) throws -> [String: OfflineContextualJSONValue] {
        guard case let .object(object) = value else {
            throw issue("shape.object", path, "此处必须是对象。")
        }
        guard Set(object.keys) == keys else {
            let missing = keys.subtracting(object.keys).sorted()
            let extra = Set(object.keys).subtracting(keys).sorted()
            throw issue(
                "shape.exactKeys",
                path,
                "字段形状不符；缺少 \(missing)，多出 \(extra)。"
            )
        }
        return object
    }

    private static func array(
        _ value: OfflineContextualJSONValue,
        path: String
    ) throws -> [OfflineContextualJSONValue] {
        guard case let .array(array) = value else {
            throw issue("shape.array", path, "此处必须是数组。")
        }
        return array
    }

    private static func required(
        _ object: [String: OfflineContextualJSONValue],
        _ key: String,
        path: String
    ) throws -> OfflineContextualJSONValue {
        guard let value = object[key] else {
            throw issue(
                "shape.exactKeys",
                path,
                "缺少必需字段 \(key)。"
            )
        }
        return value
    }

    private static func issue(
        _ code: String,
        _ path: String,
        _ message: String
    ) -> OfflineContextualContentValidationIssue {
        OfflineContextualContentValidationIssue(
            code: code,
            path: path,
            message: message
        )
    }
}

enum OfflineContextualContentCanonicalJSON {
    static func digest(
        _ value: OfflineContextualJSONValue
    ) -> String {
        let data = encode(value)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func encode(
        _ value: OfflineContextualJSONValue
    ) -> Data {
        var bytes: [UInt8] = []
        append(value, to: &bytes)
        return Data(bytes)
    }

    private static func append(
        _ value: OfflineContextualJSONValue,
        to bytes: inout [UInt8]
    ) {
        switch value {
        case let .object(object):
            bytes.append(0x7B)
            let entries = object.map {
                (
                    $0.key.precomposedStringWithCanonicalMapping,
                    $0.value
                )
            }.sorted {
                $0.0.utf8.lexicographicallyPrecedes($1.0.utf8)
            }
            for (index, entry) in entries.enumerated() {
                if index > 0 {
                    bytes.append(0x2C)
                }
                appendString(entry.0, to: &bytes)
                bytes.append(0x3A)
                append(entry.1, to: &bytes)
            }
            bytes.append(0x7D)
        case let .array(array):
            bytes.append(0x5B)
            for (index, element) in array.enumerated() {
                if index > 0 {
                    bytes.append(0x2C)
                }
                append(element, to: &bytes)
            }
            bytes.append(0x5D)
        case let .string(string):
            appendString(
                string.precomposedStringWithCanonicalMapping,
                to: &bytes
            )
        case let .integer(integer):
            bytes.append(contentsOf: String(integer).utf8)
        case let .bool(value):
            bytes.append(
                contentsOf: value ? Array("true".utf8) : Array("false".utf8)
            )
        case .null:
            bytes.append(contentsOf: "null".utf8)
        }
    }

    private static func appendString(
        _ string: String,
        to bytes: inout [UInt8]
    ) {
        bytes.append(0x22)
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22:
                bytes.append(contentsOf: "\\\"".utf8)
            case 0x5C:
                bytes.append(contentsOf: "\\\\".utf8)
            case 0x08:
                bytes.append(contentsOf: "\\b".utf8)
            case 0x0C:
                bytes.append(contentsOf: "\\f".utf8)
            case 0x0A:
                bytes.append(contentsOf: "\\n".utf8)
            case 0x0D:
                bytes.append(contentsOf: "\\r".utf8)
            case 0x09:
                bytes.append(contentsOf: "\\t".utf8)
            case 0x00...0x1F:
                let escape = String(
                    format: "\\u%04x",
                    scalar.value
                )
                bytes.append(contentsOf: escape.utf8)
            default:
                bytes.append(contentsOf: String(scalar).utf8)
            }
        }
        bytes.append(0x22)
    }
}

enum OfflineContextualContentValidator {
    static let sourceRepository =
        "https://github.com/AwantedRaccoon/MTF-Unmanual"
    static let sourceCommit =
        "f39474389831840366c23fd274208319802bf2a5"
    static let allowedHosts: Set<String> = [
        "academic.oup.com",
        "ashpublications.org",
        "creativecommons.org",
        "github.com",
        "glaad.org",
        "pflag.org",
        "pubmed.ncbi.nlm.nih.gov",
        "transcare.ucsf.edu",
        "wpath.org",
        "www.asha.org",
        "www.asrm.org",
        "www.cdc.gov",
        "www.endocrine.org",
        "www.hopkinsmedicine.org",
        "www.mayoclinic.org",
        "www.nhc.gov.cn",
        "www.plannedparenthood.org",
        "www.psychiatry.org",
        "www.rainbowhealthontario.ca",
        "www.samhsa.gov",
        "www.thetrevorproject.org",
        "www.transcarebc.ca",
        "www.transhub.org.au",
        "www.who.int"
    ]

    static func validate(
        _ output: OfflineContextualContentDecoder.Output,
        exposure: OfflineContextualContentExposure,
        statusDate: Date
    ) -> [OfflineContextualContentValidationIssue] {
        var issues: [OfflineContextualContentValidationIssue] = []
        validateIntegrity(output, into: &issues)
        validateSemantics(output.pack, into: &issues)
        validateExposure(
            output.pack,
            exposure: exposure,
            statusDate: statusDate,
            into: &issues
        )
        return issues
    }

    private static func validateIntegrity(
        _ output: OfflineContextualContentDecoder.Output,
        into issues: inout [OfflineContextualContentValidationIssue]
    ) {
        guard case let .object(root) = output.root,
              case let .array(rawCards)? = root["cards"]
        else {
            issues.append(
                issue("integrity.shape", "$", "无法读取完整性对象。")
            )
            return
        }
        for (index, rawCard) in rawCards.enumerated() {
            guard case var .object(cardObject) = rawCard,
                  case let .string(declaredDigest)? =
                    cardObject["cardDigest"]
            else {
                issues.append(
                    issue(
                        "integrity.cardDigest",
                        "$.cards[\(index)].cardDigest",
                        "卡片摘要缺少 digest。"
                    )
                )
                continue
            }
            cardObject.removeValue(forKey: "cardDigest")
            let actual = OfflineContextualContentCanonicalJSON.digest(
                .object(cardObject)
            )
            if declaredDigest != actual {
                issues.append(
                    issue(
                        "integrity.cardDigest",
                        "$.cards[\(index)].cardDigest",
                        "卡片 digest 不匹配。"
                    )
                )
            }
        }

        guard case var .object(manifest)? = root["manifest"],
              case let .string(declaredDigest)? =
                manifest["contentDigest"]
        else {
            issues.append(
                issue(
                    "integrity.contentDigest",
                    "$.manifest.contentDigest",
                    "内容包缺少 digest。"
                )
            )
            return
        }
        manifest.removeValue(forKey: "contentDigest")
        var unsignedRoot = root
        unsignedRoot["manifest"] = .object(manifest)
        let actual = OfflineContextualContentCanonicalJSON.digest(
            .object(unsignedRoot)
        )
        if declaredDigest != actual {
            issues.append(
                issue(
                    "integrity.contentDigest",
                    "$.manifest.contentDigest",
                    "内容包 digest 不匹配。"
                )
            )
        }
    }

    private static func validateSemantics(
        _ pack: OfflineContextualContentPack,
        into issues: inout [OfflineContextualContentValidationIssue]
    ) {
        let manifest = pack.manifest
        if manifest.schemaVersion != "1" {
            issues.append(
                issue(
                    "manifest.schemaVersion",
                    "$.manifest.schemaVersion",
                    "不支持该内容 schema。"
                )
            )
        }
        if manifest.locale != "zh-Hans" {
            issues.append(
                issue(
                    "manifest.locale",
                    "$.manifest.locale",
                    "首批内容只接受 zh-Hans。"
                )
            )
        }
        if !OfflineContextualContentVersionContract.isSupported(
            manifest.contentVersion
        ) {
            issues.append(
                issue(
                    "manifest.contentVersion",
                    "$.manifest.contentVersion",
                    "内容版本不受当前 App 支持。"
                )
            )
        }
        if manifest.sourceCount != pack.sources.count
            || manifest.cardCount != pack.cards.count
            || manifest.scenarioAnchorCount != pack.scenarioAnchors.count {
            issues.append(
                issue(
                    "manifest.count",
                    "$.manifest",
                    "声明计数与实际数组不一致。"
                )
            )
        }
        if pack.cards.isEmpty
            || pack.cards.count > OfflineContextualContentLimits.maximumCards
            || pack.sources.isEmpty
            || pack.sources.count >
                OfflineContextualContentLimits.maximumSources
            || pack.scenarioAnchors.isEmpty
            || pack.scenarioAnchors.count >
                OfflineContextualContentLimits.maximumScenarioAnchors {
            issues.append(
                issue(
                    "capacity.count",
                    "$",
                    "内容数组为空或超过冻结上限。"
                )
            )
        }
        validateManifestDates(manifest, into: &issues)
        validateReview(manifest, into: &issues)

        let sourceIDs = pack.sources.map(\.id)
        validateUniqueIDs(
            sourceIDs,
            path: "$.sources",
            into: &issues
        )
        let cardIDs = pack.cards.map(\.id)
        validateUniqueIDs(cardIDs, path: "$.cards", into: &issues)
        let anchorIDs = pack.scenarioAnchors.map(\.id)
        validateUniqueIDs(
            anchorIDs,
            path: "$.scenarioAnchors",
            into: &issues
        )
        validateUniqueOrders(
            pack.cards.map(\.displayOrder),
            path: "$.cards",
            into: &issues
        )

        let sourceIDSet = Set(sourceIDs)
        let cardIDSet = Set(cardIDs)
        for (index, source) in pack.sources.enumerated() {
            validateSource(source, index: index, into: &issues)
        }
        var pathDigests: [String: String] = [:]
        for (index, card) in pack.cards.enumerated() {
            validateCard(
                card,
                index: index,
                manifestContentVersion: manifest.contentVersion,
                sourceIDSet: sourceIDSet,
                attribution: pack.attribution,
                pathDigests: &pathDigests,
                into: &issues
            )
        }

        var scenarioOrders:
            [OfflineContextualContentScenario: Set<Int>] = [:]
        var seenScenarios: Set<OfflineContextualContentScenario> = []
        for (index, anchor) in pack.scenarioAnchors.enumerated() {
            let path = "$.scenarioAnchors[\(index)]"
            if !validStableID(anchor.id) {
                issues.append(
                    issue(
                        "id.invalid",
                        "\(path).id",
                        "anchor ID 不是 ASCII 稳定 ID。"
                    )
                )
            }
            if !nonempty(anchor.purpose) {
                issues.append(
                    issue(
                        "anchor.purpose",
                        "\(path).purpose",
                        "场景用途不能为空。"
                    )
                )
            }
            if !cardIDSet.contains(anchor.cardID) {
                issues.append(
                    issue(
                        "reference.card",
                        "\(path).cardID",
                        "场景引用不存在的卡片。"
                    )
                )
            }
            if scenarioOrders[anchor.scenario, default: []]
                .insert(anchor.displayOrder).inserted == false {
                issues.append(
                    issue(
                        "order.duplicate",
                        "\(path).displayOrder",
                        "同一场景的排序值重复。"
                    )
                )
            }
            seenScenarios.insert(anchor.scenario)
        }
        if seenScenarios != Set(OfflineContextualContentScenario.allCases) {
            issues.append(
                issue(
                    "anchor.scenarioCoverage",
                    "$.scenarioAnchors",
                    "六个冻结场景必须都有显式 anchor。"
                )
            )
        }
        validateAttribution(pack.attribution, into: &issues)
        if manifest.sourceCommit != pack.attribution.sourceCommit
            || manifest.sourceCommit != sourceCommit {
            issues.append(
                issue(
                    "provenance.commit",
                    "$.manifest.sourceCommit",
                    "manifest、署名和冻结来源提交不一致。"
                )
            )
        }
    }

    private static func validateManifestDates(
        _ manifest: OfflineContextualContentManifest,
        into issues: inout [OfflineContextualContentValidationIssue]
    ) {
        guard let generated = UTCDateParser.date(manifest.generatedAt),
              let retrieved = UTCDateParser.date(manifest.retrievedAt),
              let expires = UTCDateParser.date(manifest.expiresAt)
        else {
            issues.append(
                issue(
                    "date.invalid",
                    "$.manifest",
                    "manifest 日期必须是严格 UTC YYYY-MM-DD。"
                )
            )
            return
        }
        if retrieved > generated || generated > expires {
            issues.append(
                issue(
                    "date.order",
                    "$.manifest",
                    "manifest 日期顺序无效。"
                )
            )
        }
    }

    private static func validateReview(
        _ manifest: OfflineContextualContentManifest,
        into issues: inout [OfflineContextualContentValidationIssue]
    ) {
        let review = manifest.review
        if !nonempty(review.ownerRole) || !nonempty(review.scope) {
            issues.append(
                issue(
                    "review.required",
                    "$.manifest.review",
                    "复核责任角色和范围不能为空。"
                )
            )
        }
        switch review.status {
        case .candidate:
            if review.contentReviewerDisplayName != nil
                || review.medicalReviewerDisplayName != nil
                || review.completedAt != nil
                || manifest.classificationStatus != .pending {
                issues.append(
                    issue(
                        "review.candidateShape",
                        "$.manifest.review",
                        "candidate 不得伪装成人工复核完成。"
                    )
                )
            }
        case .approved:
            if !nonempty(review.contentReviewerDisplayName)
                || !nonempty(review.medicalReviewerDisplayName)
                || review.completedAt.flatMap(UTCDateParser.date) == nil
                || manifest.classificationStatus != .resolved {
                issues.append(
                    issue(
                        "review.approvedShape",
                        "$.manifest.review",
                        "approved 缺少真实人类复核或分类结论。"
                    )
                )
            } else if let completedAt =
                review.completedAt.flatMap(UTCDateParser.date),
                let generatedAt =
                    UTCDateParser.date(manifest.generatedAt),
                let retrievedAt =
                    UTCDateParser.date(manifest.retrievedAt),
                let expiresAt =
                    UTCDateParser.date(manifest.expiresAt),
                completedAt < max(generatedAt, retrievedAt)
                    || completedAt > expiresAt {
                issues.append(
                    issue(
                        "review.dateOrder",
                        "$.manifest.review.completedAt",
                        "人工复核完成日期不在内容生成、查阅和有效期范围内。"
                    )
                )
            }
        case .rejected:
            break
        }
    }

    private static func validateSource(
        _ source: OfflineContextualContentSource,
        index: Int,
        into issues: inout [OfflineContextualContentValidationIssue]
    ) {
        let path = "$.sources[\(index)]"
        if !validStableID(source.id) {
            issues.append(
                issue("id.invalid", "\(path).id", "source ID 无效。")
            )
        }
        for (key, value) in [
            ("rightsHolder", source.rightsHolder),
            ("title", source.title),
            ("versionOrPublishedAt", source.versionOrPublishedAt),
            ("licenseIdentifier", source.licenseIdentifier),
            ("boundary", source.boundary)
        ] where !nonempty(value) {
            issues.append(
                issue(
                    "source.required",
                    "\(path).\(key)",
                    "来源必填字段不能为空。"
                )
            )
        }
        validateDateRange(
            retrievedAt: source.retrievedAt,
            expiresAt: source.expiresAt,
            path: path,
            into: &issues
        )
        if !validFixedHTTPSURL(source.url) {
            issues.append(
                issue(
                    "url.invalid",
                    "\(path).url",
                    "来源 URL 不符合固定 HTTPS 合同。"
                )
            )
        }
        if source.applicableRegions.isEmpty
            || source.applicablePopulations.isEmpty
            || source.applicableRegions.contains(where: { !nonempty($0) })
            || source.applicablePopulations.contains(where: { !nonempty($0) }) {
            issues.append(
                issue(
                    "source.applicability",
                    path,
                    "来源适用地区和人群必须显式声明。"
                )
            )
        }
        switch source.distributionMode {
        case .linkOnly:
            if source.licenseIdentifier != "rights-reserved-link-only"
                || source.licenseURL != nil {
                issues.append(
                    issue(
                        "license.linkOnly",
                        path,
                        "linkOnly 必须保留外部权利且 licenseURL 为 null。"
                    )
                )
            }
        case .redistributable:
            guard let licenseURL = source.licenseURL,
                  nonempty(licenseURL),
                  validFixedHTTPSURL(licenseURL),
                  source.licenseIdentifier != "rights-reserved-link-only"
            else {
                issues.append(
                    issue(
                        "license.redistributable",
                        path,
                        "可再分发来源必须提供有效许可证。"
                    )
                )
                return
            }
        }
    }

    private static func validateCard(
        _ card: OfflineContextualContentCard,
        index: Int,
        manifestContentVersion: String,
        sourceIDSet: Set<String>,
        attribution: OfflineContextualContentAttribution,
        pathDigests: inout [String: String],
        into issues: inout [OfflineContextualContentValidationIssue]
    ) {
        let path = "$.cards[\(index)]"
        if !validStableID(card.id) {
            issues.append(
                issue("id.invalid", "\(path).id", "card ID 无效。")
            )
        }
        if !boundedNonempty(
            card.title,
            maximumScalars:
                OfflineContextualContentLimits.maximumTitleScalars
        ) {
            issues.append(
                issue("card.title", "\(path).title", "标题为空或超限。")
            )
        }
        if !boundedNonempty(
            card.summary,
            maximumScalars:
                OfflineContextualContentLimits.maximumSummaryScalars
        ) {
            issues.append(
                issue(
                    "card.summary",
                    "\(path).summary",
                    "摘要为空或超限。"
                )
            )
        }
        if !boundedNonempty(
            card.applicabilityBoundary,
            maximumScalars:
                OfflineContextualContentLimits.maximumBoundaryScalars
        ) {
            issues.append(
                issue(
                    "card.boundary",
                    "\(path).applicabilityBoundary",
                    "适用边界为空或超限。"
                )
            )
        }
        if card.aliases.count >
            OfflineContextualContentLimits.maximumAliasesPerCard
            || card.aliases.contains(where: {
                !boundedNonempty(
                    $0,
                    maximumScalars:
                        OfflineContextualContentLimits.maximumAliasScalars
                )
            }) {
            issues.append(
                issue(
                    "card.alias",
                    "\(path).aliases",
                    "别名为空、过长或数量超限。"
                )
            )
        }
        let normalizedAliases = card.aliases.map(
            OfflineContextualContentSearch.normalize
        )
        if Set(normalizedAliases).count != normalizedAliases.count {
            issues.append(
                issue(
                    "card.aliasDuplicate",
                    "\(path).aliases",
                    "规范化后别名重复。"
                )
            )
        }
        if card.sourceIDs.isEmpty
            || Set(card.sourceIDs).count != card.sourceIDs.count {
            issues.append(
                issue(
                    "reference.source",
                    "\(path).sourceIDs",
                    "来源引用为空或重复。"
                )
            )
        }
        for sourceID in card.sourceIDs
        where !sourceIDSet.contains(sourceID) {
            issues.append(
                issue(
                    "reference.source",
                    "\(path).sourceIDs",
                    "卡片引用不存在的来源。"
                )
            )
        }
        if !OfflineContextualContentVersionContract.isSupported(
            card.contentVersion
        ) || card.contentVersion != manifestContentVersion {
            issues.append(
                issue(
                    "card.contentVersion",
                    "\(path).contentVersion",
                    "卡片内容版本不受支持或未与 manifest 绑定。"
                )
            )
        }
        if !isLowerHex(card.cardDigest, count: 64) {
            issues.append(
                issue(
                    "card.digest",
                    "\(path).cardDigest",
                    "卡片 digest 无效。"
                )
            )
        }
        validateDateRange(
            retrievedAt: card.retrievedAt,
            expiresAt: card.expiresAt,
            path: path,
            into: &issues
        )
        if !validFixedHTTPSURL(card.originalURL) {
            issues.append(
                issue(
                    "url.invalid",
                    "\(path).originalURL",
                    "网站原文 URL 不符合固定 HTTPS 合同。"
                )
            )
        }
        let provenance = card.provenance
        if provenance.sourceRepository != attribution.sourceRepository
            || provenance.sourceRepository != sourceRepository {
            issues.append(
                issue(
                    "provenance.repository",
                    "\(path).provenance.sourceRepository",
                    "卡片来源仓库与署名不一致。"
                )
            )
        }
        if provenance.sourceCommit != attribution.sourceCommit
            || provenance.sourceCommit != sourceCommit {
            issues.append(
                issue(
                    "provenance.commit",
                    "\(path).provenance.sourceCommit",
                    "卡片来源提交与冻结提交不一致。"
                )
            )
        }
        if !validSourcePath(provenance.sourcePath) {
            issues.append(
                issue(
                    "provenance.path",
                    "\(path).provenance.sourcePath",
                    "来源路径不是安全仓库相对路径。"
                )
            )
        }
        if !isLowerHex(provenance.sourceFileSHA256, count: 64) {
            issues.append(
                issue(
                    "provenance.digest",
                    "\(path).provenance.sourceFileSHA256",
                    "来源文件 SHA-256 无效。"
                )
            )
        }
        if !nonempty(provenance.modificationNote) {
            issues.append(
                issue(
                    "provenance.modification",
                    "\(path).provenance.modificationNote",
                    "改编说明不能为空。"
                )
            )
        }
        if let existing = pathDigests[provenance.sourcePath],
           existing != provenance.sourceFileSHA256 {
            issues.append(
                issue(
                    "provenance.pathDigest",
                    "\(path).provenance",
                    "同一来源路径对应多个 digest。"
                )
            )
        } else {
            pathDigests[provenance.sourcePath] =
                provenance.sourceFileSHA256
        }
    }

    private static func validateAttribution(
        _ attribution: OfflineContextualContentAttribution,
        into issues: inout [OfflineContextualContentValidationIssue]
    ) {
        if attribution.sourceRepository != sourceRepository
            || attribution.sourceCommit != sourceCommit
            || attribution.creator != "MtF Manual contributors"
            || attribution.licenseIdentifier != "CC-BY-SA-4.0"
            || attribution.licenseURL
                != "https://creativecommons.org/licenses/by-sa/4.0/"
            || !nonempty(attribution.modificationNote)
            || !nonempty(attribution.shareAlikeStatement) {
            issues.append(
                issue(
                    "attribution.invalid",
                    "$.attribution",
                    "CC BY-SA 署名、改编或来源锁不完整。"
                )
            )
        }
        if !validFixedHTTPSURL(attribution.sourceRepository)
            || !validFixedHTTPSURL(attribution.licenseURL) {
            issues.append(
                issue(
                    "url.invalid",
                    "$.attribution",
                    "署名 URL 不符合固定 HTTPS 合同。"
                )
            )
        }
    }

    private static func validateExposure(
        _ pack: OfflineContextualContentPack,
        exposure: OfflineContextualContentExposure,
        statusDate: Date,
        into issues: inout [OfflineContextualContentValidationIssue]
    ) {
        switch exposure {
        case .candidate:
            if pack.manifest.review.status != .candidate
                || pack.manifest.classificationStatus != .pending {
                issues.append(
                    issue(
                        "exposure.review",
                        "$.manifest.review",
                        "candidate exposure 只接受待人工复核内容。"
                    )
                )
            }
        case .release:
            if pack.manifest.review.status != .approved
                || pack.manifest.classificationStatus != .resolved
                || !nonempty(
                    pack.manifest.review.contentReviewerDisplayName
                )
                || !nonempty(
                    pack.manifest.review.medicalReviewerDisplayName
                )
                || pack.manifest.review.completedAt
                    .flatMap(UTCDateParser.date) == nil {
                issues.append(
                    issue(
                        "exposure.review",
                        "$.manifest.review",
                        "Release 缺少真实人类内容与医疗复核。"
                    )
                )
            }
            if let completedAt =
                pack.manifest.review.completedAt
                    .flatMap(UTCDateParser.date),
                completedAt > UTCDateParser.startOfDay(statusDate) {
                issues.append(
                    issue(
                        "exposure.reviewDate",
                        "$.manifest.review.completedAt",
                        "人工复核完成日期晚于 Release 状态日期。"
                    )
                )
            }
            if isExpired(pack.manifest.expiresAt, on: statusDate)
                || pack.cards.contains(where: {
                    isExpired($0.expiresAt, on: statusDate)
                })
                || pack.sources.contains(where: {
                    isExpired($0.expiresAt, on: statusDate)
                        || $0.sourceStatus == .knownUnavailable
                }) {
                issues.append(
                    issue(
                        "exposure.current",
                        "$",
                        "Release 含过期或已失效来源。"
                    )
                )
            }
        }
    }

    private static func validateDateRange(
        retrievedAt: String,
        expiresAt: String,
        path: String,
        into issues: inout [OfflineContextualContentValidationIssue]
    ) {
        guard let retrieved = UTCDateParser.date(retrievedAt),
              let expires = UTCDateParser.date(expiresAt)
        else {
            issues.append(
                issue(
                    "date.invalid",
                    path,
                    "日期必须是严格 UTC YYYY-MM-DD。"
                )
            )
            return
        }
        if retrieved > expires {
            issues.append(
                issue("date.order", path, "查阅日期晚于到期日期。")
            )
        }
    }

    private static func validateUniqueIDs(
        _ ids: [String],
        path: String,
        into issues: inout [OfflineContextualContentValidationIssue]
    ) {
        if Set(ids).count != ids.count {
            issues.append(
                issue("id.duplicate", path, "稳定 ID 重复。")
            )
        }
    }

    private static func validateUniqueOrders(
        _ orders: [Int],
        path: String,
        into issues: inout [OfflineContextualContentValidationIssue]
    ) {
        if Set(orders).count != orders.count {
            issues.append(
                issue("order.duplicate", path, "展示排序值重复。")
            )
        }
    }

    private static func validStableID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 128,
              bytes.allSatisfy({ $0 < 0x80 }),
              (0x61...0x7A).contains(bytes[0])
        else {
            return false
        }
        var previousWasSeparator = false
        for byte in bytes {
            let isLetter = (0x61...0x7A).contains(byte)
            let isDigit = (0x30...0x39).contains(byte)
            let isSeparator = byte == 0x2D || byte == 0x2E
            guard isLetter || isDigit || isSeparator else {
                return false
            }
            if isSeparator && previousWasSeparator {
                return false
            }
            previousWasSeparator = isSeparator
        }
        return !previousWasSeparator
    }

    private static func validSourcePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.contains("\0"),
              value.unicodeScalars.allSatisfy({ $0.value < 0x80 })
        else {
            return false
        }
        let segments = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return !segments.isEmpty
            && segments.allSatisfy(validSourcePathSegment)
    }

    private static func validSourcePathSegment(
        _ segment: Substring
    ) -> Bool {
        guard let first = segment.utf8.first,
              isASCIIAlphaNumeric(first) else {
            return false
        }
        return segment.utf8.allSatisfy {
            isASCIIAlphaNumeric($0)
                || $0 == 0x2E
                || $0 == 0x5F
                || $0 == 0x2D
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
    }

    static func validFixedHTTPSURL(_ value: String) -> Bool {
        guard !value.contains("\\"),
              !value.contains("?"),
              !value.contains("#") else {
            return false
        }
        let lower = value.lowercased()
        if lower.contains("%2f")
            || lower.contains("%5c")
            || lower.contains("%40") {
            return false
        }
        guard let components = URLComponents(string: value),
              components.scheme == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host,
              host == host.lowercased(),
              !host.hasSuffix("."),
              allowedHosts.contains(host),
              !isIPLiteral(host)
        else {
            return false
        }

        guard value.hasPrefix("https://") else {
            return false
        }
        let afterScheme = value.dropFirst("https://".count)
        let pathStart = afterScheme.firstIndex(of: "/")
        let rawAuthority = pathStart.map {
            afterScheme[..<$0]
        } ?? afterScheme[...]
        guard rawAuthority == Substring(host),
              !rawAuthority.contains(":") else {
            return false
        }
        let rawPath = pathStart.map { String(afterScheme[$0...]) } ?? ""
        let segments = rawPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        for segment in segments {
            let decoded = String(segment).removingPercentEncoding
            if segment == "." || segment == ".."
                || decoded == "." || decoded == ".." {
                return false
            }
        }
        return true
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        if host.contains(":") {
            return true
        }
        let parts = host.split(separator: ".")
        return parts.count == 4
            && parts.allSatisfy {
                !$0.isEmpty && $0.allSatisfy(\.isNumber)
            }
    }

    private static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count
            && value.utf8.allSatisfy {
                (0x30...0x39).contains($0)
                    || (0x61...0x66).contains($0)
            }
    }

    private static func boundedNonempty(
        _ value: String,
        maximumScalars: Int
    ) -> Bool {
        nonempty(value)
            && value.unicodeScalars.count <= maximumScalars
    }

    private static func nonempty(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
    }

    private static func isExpired(_ value: String, on date: Date) -> Bool {
        guard let expiry = UTCDateParser.date(value) else { return true }
        return UTCDateParser.startOfDay(date) > expiry
    }

    private static func issue(
        _ code: String,
        _ path: String,
        _ message: String
    ) -> OfflineContextualContentValidationIssue {
        OfflineContextualContentValidationIssue(
            code: code,
            path: path,
            message: message
        )
    }
}

struct OfflineContextualContentReleaseStateRepository: Sendable {
    let state: OfflineContextualContentReleaseStateLoadState

    init(data: Data) {
        do {
            let value = try Self.parse(data)
            let releaseState = try JSONDecoder().decode(
                OfflineContextualContentReleaseState.self,
                from: data
            )
            let issues = Self.validate(releaseState, rawValue: value)
            if issues.isEmpty {
                state = .available(releaseState)
            } else {
                state = .unavailable(issues)
            }
        } catch let issue as OfflineContextualContentValidationIssue {
            state = .unavailable([issue])
        } catch {
            state = .unavailable([
                Self.issue(
                    "decode.invalid",
                    "$",
                    "release-state 字段类型或枚举无效。"
                )
            ])
        }
    }

    private static let exactKeys: Set<String> = [
        "schemaVersion",
        "status",
        "contentVersion",
        "message",
        "candidateResourceExcluded",
        "contentReviewApproved",
        "medicalReviewApproved",
        "classificationResolved",
        "approvedResourceName"
    ]

    private static func parse(
        _ data: Data
    ) throws -> OfflineContextualJSONValue {
        guard !data.isEmpty else {
            throw issue("input.empty", "$", "release-state 为空。")
        }
        guard data.count <= OfflineContextualContentLimits.maximumJSONBytes
        else {
            throw issue(
                "input.tooLarge",
                "$",
                "release-state 超过大小上限。"
            )
        }
        do {
            try StrictJSONDuplicateKeyScanner.validate(
                data,
                maximumDepth: OfflineContextualContentLimits.maximumDepth,
                maximumStringBytes:
                    OfflineContextualContentLimits.maximumStringBytes
            )
        } catch let error as PortableDataV2Error {
            switch error {
            case let .duplicateJSONKey(key):
                throw issue(
                    "json.duplicateKey",
                    "$",
                    "JSON 含重复字段 \(key)。"
                )
            case .excessiveDepth:
                throw issue(
                    "json.excessiveDepth",
                    "$",
                    "JSON 嵌套超过上限。"
                )
            case .inputTooLarge:
                throw issue(
                    "json.stringTooLarge",
                    "$",
                    "JSON 字符串超过上限。"
                )
            default:
                throw issue("json.invalid", "$", "JSON 语法无效。")
            }
        }
        var parser = OfflineContextualJSONParser(data: data)
        let value = try parser.parse()
        guard case let .object(object) = value,
              Set(object.keys) == exactKeys else {
            throw issue(
                "shape.exactKeys",
                "$",
                "release-state 必须使用冻结字段形状。"
            )
        }
        return value
    }

    private static func validate(
        _ state: OfflineContextualContentReleaseState,
        rawValue _: OfflineContextualJSONValue
    ) -> [OfflineContextualContentValidationIssue] {
        var issues: [OfflineContextualContentValidationIssue] = []
        if state.schemaVersion != "1"
            || state.message.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
            issues.append(
                issue(
                    "releaseState.required",
                    "$",
                    "release-state 版本和说明不能为空。"
                )
            )
        }
        if !OfflineContextualContentVersionContract.isSupported(
            state.contentVersion
        ) {
            issues.append(
                issue(
                    "releaseState.contentVersion",
                    "$.contentVersion",
                    "release-state 内容版本不受当前 App 支持。"
                )
            )
        }

        let sharedClosedValues =
            state.candidateResourceExcluded
                && !state.contentReviewApproved
                && !state.medicalReviewApproved
                && !state.classificationResolved
                && state.approvedResourceName == nil
        switch state.status {
        case .pendingHumanReviewAndClassification, .rejected:
            if !sharedClosedValues {
                issues.append(
                    issue(
                        "releaseState.truthTable",
                        "$",
                        "release-state 不符合冻结真值表。"
                    )
                )
            }
        case .approved:
            let approvedValues =
                state.candidateResourceExcluded
                    && state.contentReviewApproved
                    && state.medicalReviewApproved
                    && state.classificationResolved
            guard approvedValues,
                  let name = state.approvedResourceName
            else {
                issues.append(
                    issue(
                        "releaseState.truthTable",
                        "$",
                        "approved 状态不符合冻结真值表。"
                    )
                )
                return issues
            }
            if !validReleaseBasename(name) {
                issues.append(
                    issue(
                        "releaseState.resourceName",
                        "$.approvedResourceName",
                        "正式资源 basename 无效。"
                    )
                )
            }
        }
        return issues
    }

    private static func validReleaseBasename(_ value: String) -> Bool {
        let prefix = "offline-contextual-content-release-"
        guard value.hasPrefix(prefix),
              !value.hasSuffix(".json") else {
            return false
        }
        let suffix = value.dropFirst(prefix.count)
        guard let first = suffix.first,
              let last = suffix.last,
              isLowerAlphanumeric(first),
              isLowerAlphanumeric(last) else {
            return false
        }
        var previousWasSeparator = false
        for character in suffix {
            if character == "." || character == "-" {
                if previousWasSeparator {
                    return false
                }
                previousWasSeparator = true
            } else if isLowerAlphanumeric(character) {
                previousWasSeparator = false
            } else {
                return false
            }
        }
        return !previousWasSeparator
    }

    private static func isLowerAlphanumeric(
        _ character: Character
    ) -> Bool {
        character.isASCII
            && (character.isNumber
                || ("a"..."z").contains(character))
    }

    private static func issue(
        _ code: String,
        _ path: String,
        _ message: String
    ) -> OfflineContextualContentValidationIssue {
        OfflineContextualContentValidationIssue(
            code: code,
            path: path,
            message: message
        )
    }
}
