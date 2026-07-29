import CryptoKit
import Darwin
import Foundation

enum PortableBackupPackageBuilder {
    #if DEBUG
    typealias AttachmentCopier = (
        _ attachment: PortableDataAttachment,
        _ destinationURL: URL
    ) throws -> Void
    #endif
    typealias AttachmentDataProvider = (
        _ attachment: PortableDataAttachment
    ) throws -> Data

    struct PreparedBuild: Sendable {
        let document: PortableDataV2Document
        let readableData: Data
        let attachmentEntries: [PortableBackupPackageEntry]
        let manifestData: Data
    }

    #if DEBUG
    static func build(
        document: PortableDataV2Document,
        destinationURL: URL,
        destinationAlreadyPrepared: Bool = false,
        copyAttachment: AttachmentCopier
    ) throws -> AuditedPortableBackup {
        // Complete the exact byte/count/path preflight before the destination
        // exists and before any attachment copier can touch local storage.
        let plan = try prepare(document: document)
        let fileManager = FileManager.default
        if destinationAlreadyPrepared {
            let values = try destinationURL.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  try fileManager.contentsOfDirectory(
                    atPath: destinationURL.path
                  ).isEmpty else {
                throw PortableBackupError.destinationExists
            }
        } else {
            guard !fileManager.fileExists(
                atPath: destinationURL.path
            ) else {
                throw PortableBackupError
                    .destinationExists
            }
            try createProtectedDirectory(destinationURL)
        }
        let dataDirectory = destinationURL
            .appending(path: "data", directoryHint: .isDirectory)
        try createProtectedDirectory(dataDirectory)
        let readableURL = dataDirectory
            .appending(path: "readable-v2.json")
        try writeProtected(
            plan.readableData,
            to: readableURL
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
        guard attachmentEntries.sorted(by: {
            $0.relativePath < $1.relativePath
        }) == plan.attachmentEntries else {
            throw PortableBackupError.attachmentMismatch
        }
        try writeProtected(
            plan.manifestData,
            to: destinationURL.appending(
                path: "manifest.json"
            )
        )
        return try PortableBackupPackageAuditor.audit(
            at: destinationURL
        )
    }
    #endif

    #if DEBUG
    static func build(
        document: PortableDataV2Document,
        destinationLease: PortablePackageDirectoryLease,
        readAttachmentData: AttachmentDataProvider
    ) throws -> AuditedPortableBackup {
        try build(
            prepared: prepare(document: document),
            destinationLease: destinationLease,
            readAttachmentData: readAttachmentData
        )
    }
    #endif

    static func build(
        prepared plan: PreparedBuild,
        destinationLease: PortablePackageDirectoryLease,
        afterFirstSensitiveWrite:
            PortableManagedPathSecurity.MutationProbe = {},
        readAttachmentData: AttachmentDataProvider
    ) throws -> AuditedPortableBackup {
        let document = plan.document
        try destinationLease.verifyPublished()
        guard try PortableBackupDescriptorIO
            .directoryEntries(
                destinationLease.packageDescriptor,
                maximumEntries: 0
            ).isEmpty else {
            throw PortableBackupError.destinationExists
        }

        let dataFD = try PortableManagedPathSecurity
            .createChildDirectory(
                at: destinationLease.packageDescriptor,
                component: "data",
                backupPolicy: .excluded
            )
        do {
            try PortableManagedPathSecurity.createChildFile(
                at: dataFD,
                component: "readable-v2.json",
                data: plan.readableData,
                maximumBytes:
                    PortableBackupLimits.maximumReadableBytes,
                backupPolicy: .excluded
            )
            try afterFirstSensitiveWrite()
            Darwin.close(dataFD)
        } catch {
            Darwin.close(dataFD)
            throw error
        }

        if !document.payload.activeAttachments.isEmpty {
            let attachmentsFD =
                try PortableManagedPathSecurity
                .createChildDirectory(
                    at: destinationLease.packageDescriptor,
                    component: "attachments",
                    backupPolicy: .excluded
                )
            do {
                for attachment in document.payload
                    .activeAttachments {
                    let data = try readAttachmentData(
                        attachment
                    )
                    guard Int64(data.count)
                            == attachment.byteCount,
                          PortableBackupFileAudit.sha256Hex(
                            data
                          ) == attachment.sha256Hex else {
                        throw PortableBackupError
                            .attachmentMismatch
                    }
                    let attachmentFD =
                        try PortableManagedPathSecurity
                        .createChildDirectory(
                            at: attachmentsFD,
                            component: attachment.attachmentID
                                .uuidString.lowercased(),
                            backupPolicy: .excluded
                        )
                    do {
                        try PortableManagedPathSecurity
                            .createChildFile(
                                at: attachmentFD,
                                component: "payload",
                                data: data,
                                maximumBytes: Int(
                                    PortableBackupLimits
                                        .maximumAttachmentBytes
                                ),
                                backupPolicy: .excluded
                            )
                        Darwin.close(attachmentFD)
                    } catch {
                        Darwin.close(attachmentFD)
                        throw error
                    }
                }
                guard Darwin.fsync(attachmentsFD) == 0 else {
                    throw PortableBackupError
                        .unsupportedFileType
                }
                Darwin.close(attachmentsFD)
            } catch {
                Darwin.close(attachmentsFD)
                throw error
            }
        }

        try PortableManagedPathSecurity.createChildFile(
            at: destinationLease.packageDescriptor,
            component: "manifest.json",
            data: plan.manifestData,
            maximumBytes:
                PortableBackupLimits.maximumManifestBytes,
            backupPolicy: .excluded
        )
        guard Darwin.fsync(
            destinationLease.packageDescriptor
        ) == 0 else {
            throw PortableBackupError.unsupportedFileType
        }
        try destinationLease.verifyPublished()
        let audited = try PortableBackupPackageAuditor
            .audit(
                at: destinationLease.packageURL,
                rootFD: destinationLease.packageDescriptor
            )
        try destinationLease.verifyPublished()
        return audited
    }

    static func prepare(
        document: PortableDataV2Document
    ) throws -> PreparedBuild {
        let readableData = try PortableDataV2Codec
            .encode(document)
        guard readableData.count
                <= PortableBackupLimits.maximumReadableBytes
        else {
            throw PortableBackupError.limitExceeded
        }
        let readableEntry = PortableBackupPackageEntry(
            relativePath: "data/readable-v2.json",
            byteCount: Int64(readableData.count),
            sha256Hex:
                PortableBackupFileAudit.sha256Hex(readableData)
        )
        let attachmentEntries = try document.payload
            .activeAttachments.map { attachment in
                try PortableBackupPathPolicy.validate(
                    attachment.packageRelativePath
                )
                return PortableBackupPackageEntry(
                    relativePath:
                        attachment.packageRelativePath,
                    byteCount: attachment.byteCount,
                    sha256Hex: attachment.sha256Hex
                )
            }.sorted {
                $0.relativePath < $1.relativePath
            }
        let payload = try PortableBackupManifestPayload(
            datasetID: document.payload.datasetID,
            sourceGenerationID:
                document.payload.sourceGenerationID,
            createdAtMicroseconds:
                document.payload.capturedAtMicroseconds,
            readableData: readableEntry,
            attachments: attachmentEntries
        )
        let manifestData = try PortableBackupManifestCodec
            .encode(
                try PortableBackupManifestCodec.make(
                    payload: payload
                )
            )
        var totalBytes = Int64(manifestData.count)
        for entry in [readableEntry] + attachmentEntries {
            let (next, overflow) = totalBytes
                .addingReportingOverflow(entry.byteCount)
            guard !overflow,
                  next <= PortableBackupLimits
                    .maximumTotalBytes else {
                throw PortableBackupError.limitExceeded
            }
            totalBytes = next
        }
        return PreparedBuild(
            document: document,
            readableData: readableData,
            attachmentEntries: attachmentEntries,
            manifestData: manifestData
        )
    }

    #if DEBUG
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
    #endif
}

struct PortableBackupAuditEvidence: Equatable, Sendable {
    let backup: AuditedPortableBackup
    let identities: [
        String: PortableBackupDescriptorIO.FileIdentity
    ]
}

struct PortableBackupExportSnapshot:
    @unchecked Sendable {
    let backup: AuditedPortableBackup
    let fileWrapper: FileWrapper
}

enum PortableBackupExportSnapshotBuilder {
    typealias FileWrapperLoader =
        (URL, FileWrapper.ReadingOptions) throws -> FileWrapper

    static func make(
        _ backup: AuditedPortableBackup,
        maximumResidentBytes: Int64 =
            PortableBackupLimits
                .maximumInternalResidentExportBytes,
        fileWrapperLoader: FileWrapperLoader = {
            try FileWrapper(url: $0, options: $1)
        }
    ) throws -> PortableBackupExportSnapshot {
        guard let lease = backup.packageLease else {
            throw PortableBackupError.stateChanged
        }
        let preflightResidentBytes = try residentByteCount(
            for: backup
        )
        guard maximumResidentBytes >= 0,
              preflightResidentBytes
                <= maximumResidentBytes else {
            throw PortableBackupError.limitExceeded
        }
        return try lease.withFrozenNamespace {
            try lease.verifyPublished()
            let before = try PortableBackupPackageAuditor
                .auditEvidence(
                    at: lease.packageURL,
                    rootFD: lease.packageDescriptor
            )
            guard before.backup == backup else {
                throw PortableBackupError.stateChanged
            }
            let residentBytes = try residentByteCount(
                for: before.backup
            )
            guard
                  residentBytes <= maximumResidentBytes else {
                throw PortableBackupError.limitExceeded
            }
            let wrapper = try fileWrapperLoader(
                lease.packageURL,
                [.immediate, .withoutMapping]
            )
            let files = try regularFiles(
                in: wrapper
            )
            try validate(
                files,
                against: before.backup
            )
            let after = try PortableBackupPackageAuditor
                .auditEvidence(
                    at: lease.packageURL,
                    rootFD: lease.packageDescriptor
                )
            guard after == before else {
                throw PortableBackupError.stateChanged
            }
            try lease.verifyPublished()
            return PortableBackupExportSnapshot(
                backup: backup.detached(),
                fileWrapper: wrapper
            )
        }
    }

    private static func residentByteCount(
        for backup: AuditedPortableBackup
    ) throws -> Int64 {
        let manifestData =
            try PortableBackupManifestCodec
                .encode(backup.manifest)
        let (residentBytes, overflow) =
            backup.manifest.payload.totalByteCount
            .addingReportingOverflow(
                Int64(manifestData.count)
            )
        guard !overflow, residentBytes >= 0 else {
            throw PortableBackupError.limitExceeded
        }
        return residentBytes
    }

    private static func regularFiles(
        in root: FileWrapper
    ) throws -> [String: Data] {
        guard root.isDirectory else {
            throw PortableBackupError.invalidRoot
        }
        var result: [String: Data] = [:]
        var regularFileCount = 0
        var directoryCount = 0
        var treeNodeCount = 0

        func walk(
            _ wrapper: FileWrapper,
            prefix: String
        ) throws {
            guard let children = wrapper.fileWrappers else {
                throw PortableBackupError
                    .unsupportedFileType
            }
            for name in children.keys.sorted() {
                guard treeNodeCount
                        < PortableBackupLimits
                            .maximumPackageTreeNodeCount,
                      !name.isEmpty,
                      name != ".",
                      name != "..",
                      !name.contains("/"),
                      !name.contains("\\"),
                      !name.contains("\0"),
                      let child = children[name] else {
                    throw PortableBackupError.unsafePath
                }
                treeNodeCount += 1
                let path = prefix.isEmpty
                    ? name : prefix + "/" + name
                if child.isDirectory {
                    directoryCount += 1
                    guard directoryCount
                            <= PortableBackupLimits
                                .maximumPackageDirectoryCount else {
                        throw PortableBackupError
                            .limitExceeded
                    }
                    try walk(child, prefix: path)
                } else if child.isRegularFile,
                          let data =
                            child.regularFileContents {
                    regularFileCount += 1
                    guard regularFileCount
                            <= PortableBackupLimits
                                .maximumEntryCount else {
                        throw PortableBackupError
                            .limitExceeded
                    }
                    try PortableBackupPathPolicy
                        .validate(path)
                    guard result.updateValue(
                            data,
                            forKey: path
                          ) == nil else {
                        throw PortableBackupError
                            .duplicatePath
                    }
                } else {
                    throw PortableBackupError
                        .unsupportedFileType
                }
            }
        }

        try walk(root, prefix: "")
        return result
    }

    private static func validate(
        _ files: [String: Data],
        against backup: AuditedPortableBackup
    ) throws {
        let expected =
            [backup.manifest.payload.readableData]
            + backup.manifest.payload.attachments
            + [
                PortableBackupPackageEntry(
                    relativePath: "manifest.json",
                    byteCount: Int64(
                        try PortableBackupManifestCodec
                            .encode(backup.manifest)
                            .count
                    ),
                    sha256Hex:
                        PortableBackupFileAudit.sha256Hex(
                            try PortableBackupManifestCodec
                                .encode(backup.manifest)
                        )
                )
            ]
        guard Set(files.keys)
                == Set(expected.map(\.relativePath)) else {
            throw PortableBackupError.unexpectedEntry
        }
        var total: Int64 = 0
        for entry in expected {
            guard let data = files[entry.relativePath],
                  Int64(data.count) == entry.byteCount,
                  PortableBackupFileAudit.sha256Hex(data)
                    == entry.sha256Hex else {
                throw PortableBackupError.digestMismatch
            }
            let (next, overflow) = total.addingReportingOverflow(
                Int64(data.count)
            )
            guard !overflow,
                  next <= PortableBackupLimits
                    .maximumTotalBytes else {
                throw PortableBackupError.limitExceeded
            }
            total = next
        }
        guard let manifestData = files["manifest.json"],
              try PortableBackupManifestCodec
                .decode(manifestData) == backup.manifest,
              let readableData =
                files["data/readable-v2.json"],
              try PortableDataV2Codec.decode(readableData)
                == backup.readableDocument else {
            throw PortableBackupError.manifestMismatch
        }
    }
}

final class PortableExternalBackupSourceLease:
    @unchecked Sendable {
    let evidence: PortableBackupAuditEvidence
    let rootDescriptor: Int32

    private init(
        evidence: PortableBackupAuditEvidence,
        rootDescriptor: Int32
    ) {
        self.evidence = evidence
        self.rootDescriptor = rootDescriptor
    }

    deinit {
        Darwin.close(rootDescriptor)
    }

    static func prepare(
        at packageURL: URL
    ) throws -> PortableExternalBackupSourceLease {
        let descriptor = try PortableBackupDescriptorIO
            .openRoot(packageURL)
        do {
            let evidence = try PortableBackupPackageAuditor
                .auditEvidence(
                    at: packageURL,
                    rootFD: descriptor
                )
            return PortableExternalBackupSourceLease(
                evidence: evidence,
                rootDescriptor: descriptor
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
}

enum PortableBackupPackageAuditor {
    static func audit(
        at packageURL: URL
    ) throws -> AuditedPortableBackup {
        let rootFD = try PortableBackupDescriptorIO
            .openRoot(packageURL)
        defer { Darwin.close(rootFD) }
        return try auditEvidence(
            at: packageURL,
            rootFD: rootFD
        ).backup
    }

    static func audit(
        at packageURL: URL,
        rootFD: Int32
    ) throws -> AuditedPortableBackup {
        try auditEvidence(
            at: packageURL,
            rootFD: rootFD
        ).backup
    }

    static func auditEvidence(
        at packageURL: URL,
        rootFD: Int32
    ) throws -> PortableBackupAuditEvidence {
        var identities: Set<PortableBackupDescriptorIO.FileIdentity> = []
        var pathIdentities: [
            String: PortableBackupDescriptorIO.FileIdentity
        ] = [:]
        let rootIdentity = try PortableBackupDescriptorIO
            .directoryIdentity(rootFD)
        guard identities.insert(rootIdentity).inserted else {
            throw PortableBackupError.duplicateFileIdentity
        }
        pathIdentities[""] = rootIdentity
        let manifestRead = try PortableBackupDescriptorIO
            .readRegularFile(
                at: rootFD,
                component: "manifest.json",
                maximumBytes:
                    PortableBackupLimits.maximumManifestBytes
            )
        guard identities.insert(
            manifestRead.identity
        ).inserted else {
            throw PortableBackupError.duplicateFileIdentity
        }
        pathIdentities["manifest.json"] =
            manifestRead.identity
        let manifestData = manifestRead.data
        let manifest = try PortableBackupManifestCodec
            .decode(manifestData)
        var expectedRoot: Set<String> = [
            "manifest.json", "data"
        ]
        if !manifest.payload.attachments.isEmpty {
            expectedRoot.insert("attachments")
        }
        guard Set(try PortableBackupDescriptorIO
            .directoryEntries(
                rootFD,
                maximumEntries: 3
            )) == expectedRoot else {
            throw PortableBackupError.unexpectedEntry
        }

        let dataFD = try PortableBackupDescriptorIO
            .openDirectory(at: rootFD, component: "data")
        defer { Darwin.close(dataFD) }
        let dataIdentity = try PortableBackupDescriptorIO
            .directoryIdentity(dataFD)
        guard identities.insert(dataIdentity).inserted else {
            throw PortableBackupError.duplicateFileIdentity
        }
        pathIdentities["data"] = dataIdentity
        guard try PortableBackupDescriptorIO
            .directoryEntries(
                dataFD,
                maximumEntries: 1
            ) == ["readable-v2.json"] else {
            throw PortableBackupError.unexpectedEntry
        }
        let readableRead = try PortableBackupDescriptorIO
            .readRegularFile(
                at: dataFD,
                component: "readable-v2.json",
                maximumBytes:
                    PortableBackupLimits.maximumReadableBytes
            )
        guard identities.insert(
            readableRead.identity
        ).inserted else {
            throw PortableBackupError.duplicateFileIdentity
        }
        pathIdentities["data/readable-v2.json"] =
            readableRead.identity

        var actual: [
            String: PortableBackupFileAudit.Snapshot
        ] = [
            "manifest.json": manifestRead.snapshot,
            "data/readable-v2.json": readableRead.snapshot
        ]
        if !manifest.payload.attachments.isEmpty {
            let attachmentsFD = try PortableBackupDescriptorIO
                .openDirectory(
                    at: rootFD,
                    component: "attachments"
                )
            defer { Darwin.close(attachmentsFD) }
            let attachmentsIdentity =
                try PortableBackupDescriptorIO
                .directoryIdentity(attachmentsFD)
            guard identities.insert(
                attachmentsIdentity
            ).inserted else {
                throw PortableBackupError
                    .duplicateFileIdentity
            }
            pathIdentities["attachments"] =
                attachmentsIdentity
            let expectedNames = Set(
                manifest.payload.attachments.compactMap {
                    PortableBackupPathPolicy
                        .attachmentID(
                            from: $0.relativePath
                        )?.uuidString.lowercased()
                }
            )
            guard expectedNames.count
                    == manifest.payload.attachments.count,
                  Set(try PortableBackupDescriptorIO
                    .directoryEntries(
                        attachmentsFD,
                        maximumEntries:
                            PortableBackupLimits
                            .maximumAttachmentCount
                    ))
                    == expectedNames else {
                throw PortableBackupError.unexpectedEntry
            }
            for entry in manifest.payload.attachments {
                guard let attachmentID =
                        PortableBackupPathPolicy
                        .attachmentID(
                            from: entry.relativePath
                        ) else {
                    throw PortableBackupError.unsafePath
                }
                let attachmentFD =
                    try PortableBackupDescriptorIO
                    .openDirectory(
                        at: attachmentsFD,
                        component: attachmentID
                            .uuidString.lowercased()
                    )
                let attachmentDirectoryPath =
                    "attachments/"
                    + attachmentID.uuidString.lowercased()
                do {
                    let attachmentDirectoryIdentity =
                        try PortableBackupDescriptorIO
                        .directoryIdentity(attachmentFD)
                    guard identities.insert(
                        attachmentDirectoryIdentity
                    ).inserted else {
                        throw PortableBackupError
                            .duplicateFileIdentity
                    }
                    pathIdentities[
                        attachmentDirectoryPath
                    ] = attachmentDirectoryIdentity
                    guard try PortableBackupDescriptorIO
                        .directoryEntries(
                            attachmentFD,
                            maximumEntries: 1
                        )
                        == ["payload"] else {
                        throw PortableBackupError.unexpectedEntry
                    }
                    let read = try PortableBackupDescriptorIO
                        .readRegularFile(
                            at: attachmentFD,
                            component: "payload",
                            maximumBytes: Int(
                                PortableBackupLimits
                                    .maximumAttachmentBytes
                            )
                        )
                    guard identities.insert(
                        read.identity
                    ).inserted else {
                        throw PortableBackupError
                            .duplicateFileIdentity
                    }
                    pathIdentities[entry.relativePath] =
                        read.identity
                    actual[entry.relativePath] =
                        read.snapshot
                    Darwin.close(attachmentFD)
                } catch {
                    Darwin.close(attachmentFD)
                    throw error
                }
            }
        }
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
        guard Set(actual.keys)
                == Set(expectedEntries.map(\.relativePath)) else {
            throw PortableBackupError.missingEntry
        }
        var totalBytes: Int64 = 0
        for entry in expectedEntries {
            guard let snapshot = actual[entry.relativePath]
            else {
                throw PortableBackupError.missingEntry
            }
            guard snapshot.byteCount == entry.byteCount else {
                throw PortableBackupError.sizeMismatch
            }
            guard snapshot.sha256Hex == entry.sha256Hex else {
                throw PortableBackupError.digestMismatch
            }
            let (next, overflow) = totalBytes
                .addingReportingOverflow(snapshot.byteCount)
            guard !overflow,
                  next <= PortableBackupLimits
                    .maximumTotalBytes else {
                throw PortableBackupError.limitExceeded
            }
            totalBytes = next
        }
        let readableData = readableRead.data
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
        return PortableBackupAuditEvidence(
            backup: AuditedPortableBackup(
                packageURL: packageURL,
                manifest: manifest,
                readableDocument: document,
                packageSHA256:
                    PortableBackupFileAudit.sha256Hex(
                        Data(packageDigestInput.utf8)
                    )
            ),
            identities: pathIdentities
        )
    }

}

enum PortableBackupDescriptorIO {
    struct FileIdentity: Hashable, Sendable {
        let deviceID: UInt64
        let inode: UInt64
    }

    struct ReadResult: Sendable {
        let data: Data
        let snapshot: PortableBackupFileAudit.Snapshot
        let identity: FileIdentity
    }

    static func directoryIdentity(
        _ descriptor: Int32
    ) throws -> FileIdentity {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              isDirectory(status) else {
            throw PortableBackupError.invalidRoot
        }
        return FileIdentity(
            deviceID: UInt64(
                truncatingIfNeeded: status.st_dev
            ),
            inode: UInt64(
                truncatingIfNeeded: status.st_ino
            )
        )
    }

    static func openRoot(_ url: URL) throws -> Int32 {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw PortableBackupError.invalidRoot
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              isDirectory(status) else {
            Darwin.close(descriptor)
            throw PortableBackupError.invalidRoot
        }
        return descriptor
    }

    static func openDirectory(
        at parentFD: Int32,
        component: String
    ) throws -> Int32 {
        guard isSafeComponent(component) else {
            throw PortableBackupError.unsafePath
        }
        let descriptor = component.withCString {
            Darwin.openat(
                parentFD,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw PortableBackupError.unsupportedFileType
        }
        var opened = stat()
        var published = stat()
        let status = component.withCString {
            Darwin.fstatat(
                parentFD,
                $0,
                &published,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard Darwin.fstat(descriptor, &opened) == 0,
              status == 0,
              isDirectory(opened),
              sameFile(opened, published) else {
            Darwin.close(descriptor)
            throw PortableBackupError.unsupportedFileType
        }
        return descriptor
    }

    static func directoryEntries(
        _ descriptor: Int32,
        maximumEntries: Int = .max
    ) throws -> [String] {
        guard maximumEntries >= 0 else {
            throw PortableBackupError.limitExceeded
        }
        let iteratorFD = ".".withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard iteratorFD >= 0,
              let directory = Darwin.fdopendir(iteratorFD) else {
            if iteratorFD >= 0 {
                Darwin.close(iteratorFD)
            }
            throw PortableBackupError.invalidRoot
        }
        defer { Darwin.closedir(directory) }
        var names: [String] = []
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(
                to: &entry.pointee.d_name
            ) {
                $0.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                guard isSafeComponent(name) else {
                    throw PortableBackupError.unsafePath
                }
                names.append(name)
                guard names.count <= maximumEntries else {
                    throw PortableBackupError.limitExceeded
                }
            }
        }
        return names.sorted()
    }

    static func readRegularFile(
        at parentFD: Int32,
        component: String,
        maximumBytes: Int
    ) throws -> ReadResult {
        guard isSafeComponent(component),
              maximumBytes >= 0 else {
            throw PortableBackupError.unsafePath
        }
        var published = stat()
        guard component.withCString({
            Darwin.fstatat(
                parentFD,
                $0,
                &published,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0,
        isRegular(published),
        published.st_nlink == 1,
        published.st_size >= 0,
        published.st_size <= off_t(maximumBytes) else {
            throw PortableBackupError.unsupportedFileType
        }
        let descriptor = component.withCString {
            Darwin.openat(
                parentFD,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw PortableBackupError.unsupportedFileType
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        defer { try? handle.close() }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              isRegular(opened),
              opened.st_nlink == 1,
              sameFile(opened, published),
              opened.st_size == published.st_size else {
            throw PortableBackupError.unsupportedFileType
        }
        let expectedSize = Int(opened.st_size)
        var data = Data()
        data.reserveCapacity(expectedSize)
        while data.count < expectedSize {
            let chunk = try handle.read(
                upToCount: min(
                    64 * 1_024,
                    expectedSize - data.count
                )
            ) ?? Data()
            guard !chunk.isEmpty else {
                throw PortableBackupError.sizeMismatch
            }
            data.append(chunk)
        }
        let trailing = try handle.read(upToCount: 1)
            ?? Data()
        var finalStatus = stat()
        var finalPublished = stat()
        guard trailing.isEmpty,
              Darwin.fstat(descriptor, &finalStatus) == 0,
              component.withCString({
                  Darwin.fstatat(
                      parentFD,
                      $0,
                      &finalPublished,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              isRegular(finalStatus),
              finalStatus.st_nlink == 1,
              sameFile(opened, finalStatus),
              sameFile(finalStatus, finalPublished),
              finalPublished.st_nlink == 1,
              finalStatus.st_size == opened.st_size,
              finalPublished.st_size == opened.st_size else {
            throw PortableBackupError.sizeMismatch
        }
        return ReadResult(
            data: data,
            snapshot: PortableBackupFileAudit.Snapshot(
                byteCount: Int64(data.count),
                sha256Hex:
                    PortableBackupFileAudit.sha256Hex(data)
            ),
            identity: FileIdentity(
                deviceID: UInt64(
                    truncatingIfNeeded: opened.st_dev
                ),
                inode: UInt64(
                    truncatingIfNeeded: opened.st_ino
                )
            )
        )
    }

    private static func isSafeComponent(
        _ value: String
    ) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\0")
    }

    private static func isDirectory(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isRegular(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFREG
    }

    private static func sameFile(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && (lhs.st_mode & S_IFMT)
                == (rhs.st_mode & S_IFMT)
    }
}

enum PortableExternalBackupStager {
    static func copy(
        sourceLease: PortableExternalBackupSourceLease,
        destinationLease: PortablePackageDirectoryLease,
        beforeCopy:
            PortableManagedPathSecurity.MutationProbe = {},
        afterFirstSensitiveWrite:
            PortableManagedPathSecurity.MutationProbe = {}
    ) throws -> AuditedPortableBackup {
        try beforeCopy()
        let source = sourceLease.evidence.backup
        let sourceFD = sourceLease.rootDescriptor
        try requireIdentity(
            try PortableBackupDescriptorIO
                .directoryIdentity(sourceFD),
            path: "",
            evidence: sourceLease.evidence
        )
        var expectedRoot: Set<String> = [
            "manifest.json", "data"
        ]
        if !source.manifest.payload.attachments.isEmpty {
            expectedRoot.insert("attachments")
        }
        let rootEntries = try PortableBackupDescriptorIO
            .directoryEntries(
                sourceFD,
                maximumEntries: 3
            )
        guard Set(rootEntries) == expectedRoot else {
            throw PortableBackupError.unexpectedEntry
        }
        try destinationLease.verifyPublished()
        guard try PortableBackupDescriptorIO
            .directoryEntries(
                destinationLease.packageDescriptor,
                maximumEntries: 0
            ).isEmpty else {
            throw PortableBackupError.destinationExists
        }

        var totalBytes: Int64 = 0
        let manifestRead = try PortableBackupDescriptorIO
            .readRegularFile(
                at: sourceFD,
                component: "manifest.json",
                maximumBytes:
                    PortableBackupLimits.maximumManifestBytes
            )
        try requireIdentity(
            manifestRead.identity,
            path: "manifest.json",
            evidence: sourceLease.evidence
        )
        let expectedManifest = try PortableBackupManifestCodec
            .encode(source.manifest)
        guard manifestRead.data == expectedManifest else {
            throw PortableBackupError.stateChanged
        }
        try addBytes(
            manifestRead.data.count,
            total: &totalBytes
        )
        try PortableManagedPathSecurity.createChildFile(
            at: destinationLease.packageDescriptor,
            component: "manifest.json",
            data: manifestRead.data,
            maximumBytes:
                PortableBackupLimits.maximumManifestBytes,
            backupPolicy: .excluded
        )
        try afterFirstSensitiveWrite()

        let sourceDataFD = try PortableBackupDescriptorIO
            .openDirectory(
                at: sourceFD,
                component: "data"
            )
        defer { Darwin.close(sourceDataFD) }
        try requireIdentity(
            try PortableBackupDescriptorIO
                .directoryIdentity(sourceDataFD),
            path: "data",
            evidence: sourceLease.evidence
        )
        guard try PortableBackupDescriptorIO
            .directoryEntries(
                sourceDataFD,
                maximumEntries: 1
            ) == ["readable-v2.json"] else {
            throw PortableBackupError.unexpectedEntry
        }
        let readableRead = try PortableBackupDescriptorIO
            .readRegularFile(
                at: sourceDataFD,
                component: "readable-v2.json",
                maximumBytes:
                    PortableBackupLimits.maximumReadableBytes
            )
        try requireIdentity(
            readableRead.identity,
            path: "data/readable-v2.json",
            evidence: sourceLease.evidence
        )
        guard readableRead.snapshot.byteCount
                == source.manifest.payload
                    .readableData.byteCount,
              readableRead.snapshot.sha256Hex
                == source.manifest.payload
                    .readableData.sha256Hex else {
            throw PortableBackupError.stateChanged
        }
        try addBytes(
            readableRead.data.count,
            total: &totalBytes
        )
        let destinationDataFD =
            try PortableManagedPathSecurity
            .createChildDirectory(
                at: destinationLease.packageDescriptor,
                component: "data",
                backupPolicy: .excluded
            )
        do {
            try PortableManagedPathSecurity.createChildFile(
                at: destinationDataFD,
                component: "readable-v2.json",
                data: readableRead.data,
                maximumBytes:
                    PortableBackupLimits.maximumReadableBytes,
                backupPolicy: .excluded
            )
            Darwin.close(destinationDataFD)
        } catch {
            Darwin.close(destinationDataFD)
            throw error
        }

        if !source.manifest.payload.attachments.isEmpty {
            let sourceAttachmentsFD =
                try PortableBackupDescriptorIO
                .openDirectory(
                    at: sourceFD,
                    component: "attachments"
                )
            defer { Darwin.close(sourceAttachmentsFD) }
            try requireIdentity(
                try PortableBackupDescriptorIO
                    .directoryIdentity(
                        sourceAttachmentsFD
                    ),
                path: "attachments",
                evidence: sourceLease.evidence
            )
            let names = try PortableBackupDescriptorIO
                .directoryEntries(
                    sourceAttachmentsFD,
                    maximumEntries:
                        PortableBackupLimits
                        .maximumAttachmentCount
                )
            let expectedNames = source.manifest.payload
                .attachments.compactMap {
                    PortableBackupPathPolicy
                        .attachmentID(
                            from: $0.relativePath
                        )?.uuidString.lowercased()
                }
            guard expectedNames.count
                    == source.manifest.payload
                        .attachments.count,
                  Set(names) == Set(expectedNames) else {
                throw PortableBackupError.unexpectedEntry
            }
            let destinationAttachmentsFD =
                try PortableManagedPathSecurity
                .createChildDirectory(
                    at: destinationLease.packageDescriptor,
                    component: "attachments",
                    backupPolicy: .excluded
                )
            do {
                for entry in source.manifest.payload
                    .attachments {
                    guard let attachmentID =
                            PortableBackupPathPolicy
                            .attachmentID(
                                from: entry.relativePath
                            ) else {
                        throw PortableBackupError.unsafePath
                    }
                    let name = attachmentID
                        .uuidString.lowercased()
                    let sourceAttachmentFD =
                        try PortableBackupDescriptorIO
                        .openDirectory(
                            at: sourceAttachmentsFD,
                            component: name
                        )
                    let read: PortableBackupDescriptorIO
                        .ReadResult
                    do {
                        try requireIdentity(
                            try PortableBackupDescriptorIO
                                .directoryIdentity(
                                    sourceAttachmentFD
                                ),
                            path: "attachments/" + name,
                            evidence: sourceLease.evidence
                        )
                        guard try PortableBackupDescriptorIO
                            .directoryEntries(
                                sourceAttachmentFD,
                                maximumEntries: 1
                            ) == ["payload"] else {
                            throw PortableBackupError
                                .unexpectedEntry
                        }
                        read = try PortableBackupDescriptorIO
                            .readRegularFile(
                                at: sourceAttachmentFD,
                                component: "payload",
                                maximumBytes: Int(
                                    PortableBackupLimits
                                        .maximumAttachmentBytes
                                )
                            )
                        try requireIdentity(
                            read.identity,
                            path: entry.relativePath,
                            evidence: sourceLease.evidence
                        )
                        guard read.snapshot.byteCount
                                == entry.byteCount,
                              read.snapshot.sha256Hex
                                == entry.sha256Hex else {
                            throw PortableBackupError
                                .stateChanged
                        }
                        try addBytes(
                            read.data.count,
                            total: &totalBytes
                        )
                        Darwin.close(sourceAttachmentFD)
                    } catch {
                        Darwin.close(sourceAttachmentFD)
                        throw error
                    }
                    let destinationAttachmentFD =
                        try PortableManagedPathSecurity
                        .createChildDirectory(
                            at: destinationAttachmentsFD,
                            component: name,
                            backupPolicy: .excluded
                        )
                    do {
                        try PortableManagedPathSecurity
                            .createChildFile(
                                at: destinationAttachmentFD,
                                component: "payload",
                                data: read.data,
                                maximumBytes: Int(
                                    PortableBackupLimits
                                        .maximumAttachmentBytes
                                ),
                                backupPolicy: .excluded
                            )
                        Darwin.close(
                            destinationAttachmentFD
                        )
                    } catch {
                        Darwin.close(
                            destinationAttachmentFD
                        )
                        throw error
                    }
                }
                guard Darwin.fsync(
                    destinationAttachmentsFD
                ) == 0 else {
                    throw PortableBackupError
                        .unsupportedFileType
                }
                Darwin.close(destinationAttachmentsFD)
            } catch {
                Darwin.close(destinationAttachmentsFD)
                throw error
            }
        }
        guard Darwin.fsync(
            destinationLease.packageDescriptor
        ) == 0 else {
            throw PortableBackupError.unsupportedFileType
        }
        try destinationLease.verifyPublished()
        guard try PortableBackupPackageAuditor
            .auditEvidence(
                at: source.packageURL,
                rootFD: sourceFD
            ) == sourceLease.evidence else {
            throw PortableBackupError.stateChanged
        }
        let audited = try PortableBackupPackageAuditor.audit(
            at: destinationLease.packageURL,
            rootFD: destinationLease.packageDescriptor
        )
        try destinationLease.verifyPublished()
        guard audited.manifest == source.manifest,
              audited.readableDocument
                == source.readableDocument,
              audited.packageSHA256
                == source.packageSHA256 else {
            throw PortableBackupError.stateChanged
        }
        return audited
    }

    private static func requireIdentity(
        _ identity:
            PortableBackupDescriptorIO.FileIdentity,
        path: String,
        evidence: PortableBackupAuditEvidence
    ) throws {
        guard evidence.identities[path] == identity else {
            throw PortableBackupError.stateChanged
        }
    }

    private static func addBytes(
        _ count: Int,
        total: inout Int64
    ) throws {
        let (next, overflow) = total.addingReportingOverflow(
            Int64(count)
        )
        guard !overflow,
              next <= PortableBackupLimits.maximumTotalBytes
        else {
            throw PortableBackupError.limitExceeded
        }
        total = next
    }

    #if DEBUG
    static func copy(
        sourceURL: URL,
        destinationURL: URL
    ) throws {
        let sourceFD = try PortableBackupDescriptorIO
            .openRoot(sourceURL)
        defer { Darwin.close(sourceFD) }
        let rootEntries = try PortableBackupDescriptorIO
            .directoryEntries(
                sourceFD,
                maximumEntries: 3
            )
        guard rootEntries.contains("manifest.json"),
              rootEntries.contains("data"),
              Set(rootEntries).isSubset(
                of: Set([
                    "manifest.json", "data", "attachments"
                ])
              ) else {
            throw PortableBackupError.unexpectedEntry
        }
        var totalBytes: Int64 = 0
        let manifest = try PortableBackupDescriptorIO
            .readRegularFile(
                at: sourceFD,
                component: "manifest.json",
                maximumBytes:
                    PortableBackupLimits.maximumManifestBytes
            ).data
        try addBytes(manifest.count, total: &totalBytes)
        try writeProtected(
            manifest,
            to: destinationURL.appending(path: "manifest.json")
        )

        let sourceDataFD = try PortableBackupDescriptorIO
            .openDirectory(
                at: sourceFD,
                component: "data"
            )
        defer { Darwin.close(sourceDataFD) }
        guard try PortableBackupDescriptorIO
            .directoryEntries(
                sourceDataFD,
                maximumEntries: 1
            )
            == ["readable-v2.json"] else {
            throw PortableBackupError.unexpectedEntry
        }
        let destinationData = destinationURL.appending(
            path: "data",
            directoryHint: .isDirectory
        )
        try createProtectedDirectory(destinationData)
        let readable = try PortableBackupDescriptorIO
            .readRegularFile(
                at: sourceDataFD,
                component: "readable-v2.json",
                maximumBytes:
                    PortableBackupLimits.maximumReadableBytes
            ).data
        try addBytes(readable.count, total: &totalBytes)
        try writeProtected(
            readable,
            to: destinationData.appending(
                path: "readable-v2.json"
            )
        )

        guard rootEntries.contains("attachments") else {
            return
        }
        let sourceAttachmentsFD =
            try PortableBackupDescriptorIO
            .openDirectory(
                at: sourceFD,
                component: "attachments"
            )
        defer { Darwin.close(sourceAttachmentsFD) }
        let names = try PortableBackupDescriptorIO
            .directoryEntries(
                sourceAttachmentsFD,
                maximumEntries:
                    PortableBackupLimits.maximumAttachmentCount
            )
        let destinationAttachments =
            destinationURL.appending(
                path: "attachments",
                directoryHint: .isDirectory
            )
        try createProtectedDirectory(
            destinationAttachments
        )
        for name in names {
            guard let id = UUID(uuidString: name),
                  id.uuidString.lowercased() == name else {
                throw PortableBackupError.unsafePath
            }
            let sourceAttachmentFD =
                try PortableBackupDescriptorIO
                .openDirectory(
                    at: sourceAttachmentsFD,
                    component: name
                )
            do {
                guard try PortableBackupDescriptorIO
                    .directoryEntries(
                        sourceAttachmentFD,
                        maximumEntries: 1
                    )
                    == ["payload"] else {
                    throw PortableBackupError.unexpectedEntry
                }
                let data = try PortableBackupDescriptorIO
                    .readRegularFile(
                        at: sourceAttachmentFD,
                        component: "payload",
                        maximumBytes: Int(
                            PortableBackupLimits
                                .maximumAttachmentBytes
                        )
                    ).data
                try addBytes(
                    data.count,
                    total: &totalBytes
                )
                let destinationAttachment =
                    destinationAttachments.appending(
                        path: name,
                        directoryHint: .isDirectory
                    )
                try createProtectedDirectory(
                    destinationAttachment
                )
                try writeProtected(
                    data,
                    to: destinationAttachment
                        .appending(path: "payload")
                )
                Darwin.close(sourceAttachmentFD)
            } catch {
                Darwin.close(sourceAttachmentFD)
                throw error
            }
        }
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
    #endif
}

enum PortableBackupFileAudit {
    struct Snapshot: Equatable, Sendable {
        let byteCount: Int64
        let sha256Hex: String
    }

    static func snapshot(_ url: URL) throws -> Snapshot {
        let parentFD = try PortableBackupDescriptorIO
            .openRoot(url.deletingLastPathComponent())
        defer { Darwin.close(parentFD) }
        let component = url.lastPathComponent
        var published = stat()
        guard component.withCString({
            Darwin.fstatat(
                parentFD,
                $0,
                &published,
                AT_SYMLINK_NOFOLLOW
            )
        }) == 0,
        (published.st_mode & S_IFMT) == S_IFREG,
        published.st_nlink == 1,
        published.st_size >= 0 else {
            throw PortableBackupError.unsupportedFileType
        }
        let descriptor = component.withCString {
            Darwin.openat(
                parentFD,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw PortableBackupError.unsupportedFileType
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        defer { try? handle.close() }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_nlink == 1,
              opened.st_dev == published.st_dev,
              opened.st_ino == published.st_ino,
              opened.st_size == published.st_size else {
            throw PortableBackupError.unsupportedFileType
        }
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
        var finalStatus = stat()
        guard count == Int64(opened.st_size),
              Darwin.fstat(descriptor, &finalStatus) == 0,
              finalStatus.st_dev == opened.st_dev,
              finalStatus.st_ino == opened.st_ino,
              finalStatus.st_size == opened.st_size,
              finalStatus.st_nlink == 1 else {
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
        let parentFD = try PortableBackupDescriptorIO
            .openRoot(url.deletingLastPathComponent())
        defer { Darwin.close(parentFD) }
        return try PortableBackupDescriptorIO
            .readRegularFile(
                at: parentFD,
                component: url.lastPathComponent,
                maximumBytes: maximumBytes
            ).data
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
