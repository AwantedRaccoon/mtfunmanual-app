import CryptoKit
import Foundation

struct PortableBackupPackageEntry: Codable, Equatable, Sendable {
    let relativePath: String
    let byteCount: Int64
    let sha256Hex: String
}

struct PortableBackupManifestPayload: Codable, Equatable, Sendable {
    static let format =
        "com.mtfbook.unmanual.complete-backup"
    static let version = 1

    let format: String
    let version: Int
    let datasetID: UUID
    let sourceGenerationID: UUID
    let createdAtMicroseconds: Int64
    let readableData: PortableBackupPackageEntry
    let attachments: [PortableBackupPackageEntry]
    let entryCount: Int
    let totalByteCount: Int64

    init(
        datasetID: UUID,
        sourceGenerationID: UUID,
        createdAtMicroseconds: Int64,
        readableData: PortableBackupPackageEntry,
        attachments: [PortableBackupPackageEntry]
    ) throws {
        let entries = [readableData] + attachments
        self.format = Self.format
        self.version = Self.version
        self.datasetID = datasetID
        self.sourceGenerationID = sourceGenerationID
        self.createdAtMicroseconds = createdAtMicroseconds
        self.readableData = readableData
        self.attachments = attachments
        self.entryCount = entries.count + 1
        self.totalByteCount = try entries.reduce(Int64(0)) {
            partial, entry in
            let (next, overflow) = partial
                .addingReportingOverflow(entry.byteCount)
            guard !overflow else {
                throw PortableBackupError.limitExceeded
            }
            return next
        }
    }
}

struct PortableBackupManifest: Codable, Equatable, Sendable {
    let payload: PortableBackupManifestPayload
    let rootSHA256: String
}

struct AuditedPortableBackup: Equatable, Sendable {
    let packageURL: URL
    let manifest: PortableBackupManifest
    let readableDocument: PortableDataV2Document
    let packageSHA256: String
}

enum PortableBackupLimits {
    static let maximumManifestBytes = 1_024 * 1_024
    static let maximumReadableBytes =
        PortableDataV2Limits.maximumJSONBytes
    static let maximumAttachmentBytes: Int64 =
        AttachmentFileStore.maximumFileBytes
    static let maximumAttachmentCount =
        PortableDataV2Limits.maximumAttachmentCount
    static let maximumEntryCount = 2_100
    static let maximumTotalBytes: Int64 =
        2 * 1_024 * 1_024 * 1_024
    static let maximumPathBytes = 512
}

enum PortableBackupError: Error, Equatable, LocalizedError {
    case destinationExists
    case invalidRoot
    case unsafePath
    case unsupportedFileType
    case duplicatePath
    case duplicateFileIdentity
    case unexpectedEntry
    case missingEntry
    case limitExceeded
    case sizeMismatch
    case digestMismatch
    case manifestMismatch
    case attachmentMismatch
    case stateChanged

    var errorDescription: String? {
        switch self {
        case .destinationExists:
            "临时目标已经存在；没有覆盖任何文件。"
        case .invalidRoot:
            "所选备份不是一个安全的目录 package。"
        case .unsafePath:
            "备份含有不安全的路径。"
        case .unsupportedFileType:
            "备份含有链接或其他不支持的文件类型。"
        case .duplicatePath:
            "备份含有重复或归一化后冲突的路径。"
        case .duplicateFileIdentity:
            "备份中的多个路径指向同一个底层文件。"
        case .unexpectedEntry:
            "备份含有未声明的文件。"
        case .missingEntry:
            "备份缺少清单声明的文件。"
        case .limitExceeded:
            "备份超过可安全处理的数量或大小上限。"
        case .sizeMismatch:
            "备份文件大小与清单不一致。"
        case .digestMismatch:
            "备份文件内容与清单摘要不一致。"
        case .manifestMismatch:
            "备份清单与 Readable JSON v2 不一致。"
        case .attachmentMismatch:
            "备份附件与逻辑附件清单不一致。"
        case .stateChanged:
            "生成期间本地资料发生了变化；没有交付旧快照。"
        }
    }
}

enum PortableBackupManifestCodec {
    static func make(
        payload: PortableBackupManifestPayload
    ) throws -> PortableBackupManifest {
        try validate(payload)
        return PortableBackupManifest(
            payload: payload,
            rootSHA256: try digest(payload)
        )
    }

    static func encode(
        _ manifest: PortableBackupManifest
    ) throws -> Data {
        try validate(manifest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        let data = try encoder.encode(manifest)
        guard data.count <= PortableBackupLimits
            .maximumManifestBytes else {
            throw PortableBackupError.limitExceeded
        }
        return data
    }

    static func decode(_ data: Data) throws
        -> PortableBackupManifest {
        guard data.count <= PortableBackupLimits
            .maximumManifestBytes else {
            throw PortableBackupError.limitExceeded
        }
        try StrictJSONDuplicateKeyScanner.validate(
            data,
            maximumDepth: 16,
            maximumStringBytes: 1_024
        )
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PortableBackupError.manifestMismatch
        }
        guard let object = root as? [String: Any],
              Set(object.keys) == ["payload", "rootSHA256"],
              let payload = object["payload"] as? [String: Any],
              Set(payload.keys) == [
                  "format", "version", "datasetID",
                  "sourceGenerationID", "createdAtMicroseconds",
                  "readableData", "attachments", "entryCount",
                  "totalByteCount"
              ],
              let readable =
                payload["readableData"] as? [String: Any],
              validEntryShape(readable),
              let attachments =
                payload["attachments"] as? [[String: Any]],
              attachments.allSatisfy(validEntryShape) else {
            throw PortableBackupError.manifestMismatch
        }
        let decoder = JSONDecoder()
        let manifest: PortableBackupManifest
        do {
            manifest = try decoder.decode(
                PortableBackupManifest.self,
                from: data
            )
        } catch {
            throw PortableBackupError.manifestMismatch
        }
        try validate(manifest)
        return manifest
    }

    static func validate(
        _ manifest: PortableBackupManifest
    ) throws {
        try validate(manifest.payload)
        guard manifest.rootSHA256
                == (try digest(manifest.payload)) else {
            throw PortableBackupError.digestMismatch
        }
    }

    static func validate(
        _ payload: PortableBackupManifestPayload
    ) throws {
        guard payload.format
                == PortableBackupManifestPayload.format,
              payload.version
                == PortableBackupManifestPayload.version,
              payload.entryCount
                == payload.attachments.count + 2,
              payload.entryCount
                <= PortableBackupLimits.maximumEntryCount,
              payload.attachments.count
                <= PortableBackupLimits.maximumAttachmentCount,
              payload.readableData.relativePath
                == "data/readable-v2.json",
              payload.readableData.byteCount >= 0,
              payload.readableData.byteCount
                <= Int64(
                    PortableBackupLimits.maximumReadableBytes
                ) else {
            throw PortableBackupError.manifestMismatch
        }
        var paths: Set<String> = []
        var normalized: Set<String> = []
        let entries = [payload.readableData]
            + payload.attachments
        var total: Int64 = 0
        for entry in entries {
            try PortableBackupPathPolicy.validate(
                entry.relativePath
            )
            guard entry.byteCount >= 0,
                  entry.sha256Hex.count == 64,
                  paths.insert(entry.relativePath).inserted,
                  normalized.insert(
                    PortableBackupPathPolicy
                        .collisionKey(entry.relativePath)
                  ).inserted else {
                throw PortableBackupError.duplicatePath
            }
            if entry.relativePath
                .hasPrefix("attachments/") {
                guard entry.byteCount
                        <= PortableBackupLimits
                            .maximumAttachmentBytes,
                      PortableBackupPathPolicy
                        .attachmentID(
                            from: entry.relativePath
                        ) != nil else {
                    throw PortableBackupError.unsafePath
                }
            }
            let (next, overflow) = total
                .addingReportingOverflow(entry.byteCount)
            guard !overflow,
                  next <= PortableBackupLimits
                    .maximumTotalBytes else {
                throw PortableBackupError.limitExceeded
            }
            total = next
        }
        guard total == payload.totalByteCount else {
            throw PortableBackupError.sizeMismatch
        }
    }

    static func digest(
        _ payload: PortableBackupManifestPayload
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        return SHA256.hash(data: try encoder.encode(payload))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func validEntryShape(
        _ object: [String: Any]
    ) -> Bool {
        Set(object.keys) == [
            "relativePath", "byteCount", "sha256Hex"
        ]
    }
}

enum PortableBackupPathPolicy {
    static func validate(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0"),
              path.lengthOfBytes(using: .utf8)
                <= PortableBackupLimits.maximumPathBytes else {
            throw PortableBackupError.unsafePath
        }
        let parts = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !parts.isEmpty,
              parts.count <= 4,
              parts.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }),
              path == "manifest.json"
                || path == "data/readable-v2.json"
                || attachmentID(from: path) != nil else {
            throw PortableBackupError.unsafePath
        }
    }

    static func collisionKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func attachmentID(from path: String) -> UUID? {
        let parts = path.split(separator: "/")
        guard parts.count == 3,
              parts[0] == "attachments",
              parts[2] == "payload",
              String(parts[1])
                == String(parts[1]).lowercased(),
              let id = UUID(uuidString: String(parts[1])),
              id.uuidString.lowercased()
                == String(parts[1]) else {
            return nil
        }
        return id
    }
}
