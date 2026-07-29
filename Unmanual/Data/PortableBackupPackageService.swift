import CryptoKit
import Foundation

enum PortableBackupPackageBuilder {
    typealias AttachmentCopier = (
        _ attachment: PortableDataAttachment,
        _ destinationURL: URL
    ) throws -> Void

    static func build(
        document: PortableDataV2Document,
        destinationURL: URL,
        copyAttachment: AttachmentCopier
    ) throws -> AuditedPortableBackup {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(
            atPath: destinationURL.path
        ) else {
            throw PortableBackupError
                .destinationExists
        }
        try createProtectedDirectory(destinationURL)
        let dataDirectory = destinationURL
            .appending(path: "data", directoryHint: .isDirectory)
        try createProtectedDirectory(dataDirectory)
        let readableURL = dataDirectory
            .appending(path: "readable-v2.json")
        let readableData = try PortableDataV2Codec
            .encode(document)
        try writeProtected(
            readableData,
            to: readableURL
        )
        let readableEntry = try entry(
            relativePath: "data/readable-v2.json",
            url: readableURL
        )

        var attachmentEntries:
            [PortableBackupPackageEntry] = []
        if !document.payload.activeAttachments.isEmpty {
            let attachmentsDirectory =
                destinationURL.appending(
                    path: "attachments",
                    directoryHint: .isDirectory
                )
            try createProtectedDirectory(
                attachmentsDirectory
            )
            for attachment in document.payload
                .activeAttachments {
                let relativePath =
                    attachment.packageRelativePath
                try PortableBackupPathPolicy.validate(
                    relativePath
                )
                let directory = destinationURL.appending(
                        path:
                            "attachments/"
                            + attachment.attachmentID
                                .uuidString.lowercased(),
                        directoryHint: .isDirectory
                    )
                try createProtectedDirectory(directory)
                let destination = directory
                    .appending(path: "payload")
                try copyAttachment(
                    attachment,
                    destination
                )
                try applyProtection(destination)
                let value = try entry(
                    relativePath: relativePath,
                    url: destination
                )
                guard value.byteCount
                        == attachment.byteCount,
                      value.sha256Hex
                        == attachment.sha256Hex else {
                    throw PortableBackupError
                        .attachmentMismatch
                }
                attachmentEntries.append(value)
            }
        }
        let payload = try PortableBackupManifestPayload(
            datasetID: document.payload.datasetID,
            sourceGenerationID:
                document.payload.sourceGenerationID,
            createdAtMicroseconds:
                document.payload.capturedAtMicroseconds,
            readableData: readableEntry,
            attachments: attachmentEntries.sorted {
                $0.relativePath < $1.relativePath
            }
        )
        let manifest = try PortableBackupManifestCodec
            .make(payload: payload)
        try writeProtected(
            PortableBackupManifestCodec.encode(
                manifest
            ),
            to: destinationURL.appending(
                path: "manifest.json"
            )
        )
        return try PortableBackupPackageAuditor.audit(
            at: destinationURL
        )
    }

    private static func createProtectedDirectory(
        _ url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [
                .protectionKey: FileProtectionType.complete
            ]
        )
        try applyProtection(url)
    }

    private static func writeProtected(
        _ data: Data,
        to url: URL
    ) throws {
        try data.write(to: url, options: [.atomic])
        try applyProtection(url)
    }

    private static func applyProtection(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
    }

    private static func entry(
        relativePath: String,
        url: URL
    ) throws -> PortableBackupPackageEntry {
        let snapshot = try PortableBackupFileAudit
            .snapshot(url)
        return PortableBackupPackageEntry(
            relativePath: relativePath,
            byteCount: snapshot.byteCount,
            sha256Hex: snapshot.sha256Hex
        )
    }
}

enum PortableBackupPackageAuditor {
    static func audit(
        at packageURL: URL
    ) throws -> AuditedPortableBackup {
        let rootValues = try packageURL.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ]
        )
        guard rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else {
            throw PortableBackupError.invalidRoot
        }
        let manifestURL = packageURL
            .appending(path: "manifest.json")
        let manifestData = try PortableBackupFileAudit
            .boundedData(
                manifestURL,
                maximumBytes:
                    PortableBackupLimits.maximumManifestBytes
            )
        let manifest = try PortableBackupManifestCodec
            .decode(manifestData)
        let expectedEntries =
            [manifest.payload.readableData]
                + manifest.payload.attachments
                + [
                    PortableBackupPackageEntry(
                        relativePath: "manifest.json",
                        byteCount: Int64(manifestData.count),
                        sha256Hex:
                            PortableBackupFileAudit.sha256Hex(
                                manifestData
                            )
                    )
                ]
        let actual = try enumerateFiles(
            root: packageURL,
            expectedPaths: Set(
                expectedEntries.map(\.relativePath)
            )
        )
        guard Set(actual.keys)
                == Set(expectedEntries.map(\.relativePath)) else {
            throw actual.keys.contains(
                where: {
                    !expectedEntries.map(\.relativePath)
                        .contains($0)
                }
            )
                ? PortableBackupError.unexpectedEntry
                : PortableBackupError.missingEntry
        }
        for entry in expectedEntries {
            guard let snapshot = actual[
                entry.relativePath
            ] else {
                throw PortableBackupError.missingEntry
            }
            guard snapshot.byteCount
                    == entry.byteCount else {
                throw PortableBackupError.sizeMismatch
            }
            guard snapshot.sha256Hex
                    == entry.sha256Hex else {
                throw PortableBackupError.digestMismatch
            }
        }
        let readableData = try PortableBackupFileAudit
            .boundedData(
                packageURL.appending(
                    path: manifest.payload
                        .readableData.relativePath
                ),
                maximumBytes:
                    PortableBackupLimits.maximumReadableBytes
            )
        let document = try PortableDataV2Codec.decode(
            readableData
        )
        guard document.payload.datasetID
                == manifest.payload.datasetID,
              document.payload.sourceGenerationID
                == manifest.payload.sourceGenerationID,
              document.payload.capturedAtMicroseconds
                == manifest.payload.createdAtMicroseconds else {
            throw PortableBackupError.manifestMismatch
        }
        let attachmentByID = Dictionary(
            uniqueKeysWithValues:
                document.payload.activeAttachments.map {
                    ($0.attachmentID, $0)
                }
        )
        guard manifest.payload.attachments.count
                == attachmentByID.count else {
            throw PortableBackupError.attachmentMismatch
        }
        for entry in manifest.payload.attachments {
            guard let id = PortableBackupPathPolicy
                .attachmentID(from: entry.relativePath),
                  let attachment = attachmentByID[id],
                  attachment.packageRelativePath
                    == entry.relativePath,
                  attachment.byteCount == entry.byteCount,
                  attachment.sha256Hex
                    == entry.sha256Hex else {
                throw PortableBackupError.attachmentMismatch
            }
        }
        let packageDigestInput =
            expectedEntries.sorted {
                $0.relativePath < $1.relativePath
            }.map {
                "\($0.relativePath)\0\($0.byteCount)\0\($0.sha256Hex)"
            }.joined(separator: "\0")
        return AuditedPortableBackup(
            packageURL: packageURL,
            manifest: manifest,
            readableDocument: document,
            packageSHA256:
                PortableBackupFileAudit.sha256Hex(
                    Data(packageDigestInput.utf8)
                )
        )
    }

    private static func enumerateFiles(
        root: URL,
        expectedPaths: Set<String>
    ) throws -> [
        String: PortableBackupFileAudit.Snapshot
    ] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileResourceIdentifierKey,
            .fileSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw PortableBackupError.invalidRoot
        }
        var result:
            [String: PortableBackupFileAudit.Snapshot] = [:]
        var collisions: Set<String> = []
        var identities: Set<String> = []
        var total: Int64 = 0
        var itemCount = 0
        for case let url as URL in enumerator {
            itemCount += 1
            guard itemCount
                    <= PortableBackupLimits.maximumEntryCount
                    * 3 else {
                throw PortableBackupError.limitExceeded
            }
            let relativePath = String(
                url.path.dropFirst(root.path.count + 1)
            )
            try PortableBackupPathPolicy
                .validateDirectoryOrFile(relativePath)
            let values = try url.resourceValues(
                forKeys: Set(keys)
            )
            guard values.isSymbolicLink != true else {
                throw PortableBackupError
                    .unsupportedFileType
            }
            let collision = PortableBackupPathPolicy
                .collisionKey(relativePath)
            guard collisions.insert(collision).inserted else {
                throw PortableBackupError.duplicatePath
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true,
                  expectedPaths.contains(relativePath) else {
                throw expectedPaths.contains(relativePath)
                    ? PortableBackupError
                        .unsupportedFileType
                    : PortableBackupError.unexpectedEntry
            }
            if let identifier =
                values.fileResourceIdentifier {
                let identity = String(
                    describing: identifier
                )
                guard identities.insert(identity).inserted else {
                    throw PortableBackupError
                        .duplicateFileIdentity
                }
            }
            let snapshot = try PortableBackupFileAudit
                .snapshot(url)
            let (next, overflow) = total
                .addingReportingOverflow(
                    snapshot.byteCount
                )
            guard !overflow,
                  next <= PortableBackupLimits
                    .maximumTotalBytes
                    + Int64(
                        PortableBackupLimits
                            .maximumManifestBytes
                    ) else {
                throw PortableBackupError.limitExceeded
            }
            total = next
            guard result.updateValue(
                snapshot,
                forKey: relativePath
            ) == nil else {
                throw PortableBackupError.duplicatePath
            }
        }
        return result
    }
}

enum PortableBackupFileAudit {
    struct Snapshot: Equatable, Sendable {
        let byteCount: Int64
        let sha256Hex: String
    }

    static func snapshot(_ url: URL) throws -> Snapshot {
        let values = try url.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size >= 0 else {
            throw PortableBackupError.unsupportedFileType
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var count: Int64 = 0
        while true {
            let data = try handle.read(upToCount: 64 * 1_024)
                ?? Data()
            if data.isEmpty { break }
            let (next, overflow) = count
                .addingReportingOverflow(
                    Int64(data.count)
                )
            guard !overflow,
                  next <= PortableBackupLimits
                    .maximumTotalBytes else {
                throw PortableBackupError.limitExceeded
            }
            count = next
            hasher.update(data: data)
        }
        guard count == Int64(size) else {
            throw PortableBackupError.sizeMismatch
        }
        return Snapshot(
            byteCount: count,
            sha256Hex: hasher.finalize()
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    static func boundedData(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let values = try url.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= maximumBytes else {
            throw PortableBackupError.limitExceeded
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        result.reserveCapacity(fileSize)
        while true {
            let chunk = try handle.read(
                upToCount: min(
                    64 * 1_024,
                    maximumBytes - result.count + 1
                )
            ) ?? Data()
            if chunk.isEmpty { break }
            result.append(chunk)
            guard result.count <= maximumBytes else {
                throw PortableBackupError.limitExceeded
            }
        }
        guard result.count == fileSize else {
            throw PortableBackupError.sizeMismatch
        }
        return result
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private extension PortableBackupPathPolicy {
    static func validateDirectoryOrFile(
        _ path: String
    ) throws {
        if path == "data" || path == "attachments" {
            return
        }
        let parts = path.split(separator: "/")
        if parts.count == 2,
           parts[0] == "attachments",
           let id = UUID(uuidString: String(parts[1])),
           id.uuidString.lowercased()
            == String(parts[1]) {
            return
        }
        try validate(path)
    }
}
