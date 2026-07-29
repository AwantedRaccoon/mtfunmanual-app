import CryptoKit
import Darwin
import Foundation

enum PortablePackageArtifactKind:
    String, Codable, CaseIterable, Sendable {
    case backupTransfer
    case importTransfer
    case restoreStaging
}

enum PortablePackageCleanupIntentState:
    String, Codable, CaseIterable, Sendable {
    case active
    case cleanupPending
}

struct PortablePackageCleanupIntent:
    Codable, Equatable, Sendable {
    static let formatVersion = 1

    let formatVersion: Int
    let operationID: UUID
    let kind: PortablePackageArtifactKind
    let state: PortablePackageCleanupIntentState
    let relativePath: String
    let contractSHA256: String

    init(
        operationID: UUID,
        kind: PortablePackageArtifactKind,
        state: PortablePackageCleanupIntentState = .active
    ) {
        self.formatVersion = Self.formatVersion
        self.operationID = operationID
        self.kind = kind
        self.state = state
        self.relativePath = Self.relativePath(
            operationID: operationID,
            kind: kind
        )
        self.contractSHA256 = Self.contractDigest(
            formatVersion: Self.formatVersion,
            operationID: operationID,
            kind: kind,
            state: state,
            relativePath: relativePath
        )
    }

    func updatingState(
        _ state: PortablePackageCleanupIntentState
    ) -> Self {
        Self(
            operationID: operationID,
            kind: kind,
            state: state
        )
    }

    static func relativePath(
        operationID: UUID,
        kind: PortablePackageArtifactKind
    ) -> String {
        let id = operationID.uuidString.lowercased()
        switch kind {
        case .backupTransfer:
            return "Unmanual-Backup-\(id).unmanualbackup"
        case .importTransfer:
            return "Unmanual-Import-\(id).unmanualbackup"
        case .restoreStaging:
            return "PortableImports/\(id)/package.unmanualbackup"
        }
    }

    fileprivate static func contractDigest(
        formatVersion: Int,
        operationID: UUID,
        kind: PortablePackageArtifactKind,
        state: PortablePackageCleanupIntentState,
        relativePath: String
    ) -> String {
        let value = [
            String(formatVersion),
            operationID.uuidString.lowercased(),
            kind.rawValue,
            state.rawValue,
            relativePath
        ].joined(separator: "\u{001f}")
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct PortablePackageCleanupJournal:
    Codable, Equatable, Sendable {
    static let formatVersion = 1

    let formatVersion: Int
    let intents: [PortablePackageCleanupIntent]
    let contractSHA256: String

    init(intents: [PortablePackageCleanupIntent]) {
        self.formatVersion = Self.formatVersion
        self.intents = intents.sorted {
            $0.operationID.uuidString
                < $1.operationID.uuidString
        }
        self.contractSHA256 = Self.contractDigest(
            formatVersion: Self.formatVersion,
            intents: self.intents
        )
    }

    fileprivate static func contractDigest(
        formatVersion: Int,
        intents: [PortablePackageCleanupIntent]
    ) -> String {
        let value = [String(formatVersion)]
            + intents.map {
                $0.operationID.uuidString.lowercased()
                    + "\u{001f}" + $0.kind.rawValue
                    + "\u{001f}" + $0.state.rawValue
                    + "\u{001f}" + $0.relativePath
                    + "\u{001f}" + $0.contractSHA256
            }
        return SHA256.hash(
            data: Data(
                value.joined(separator: "\u{001e}").utf8
            )
        )
        .map { String(format: "%02x", $0) }
        .joined()
    }
}

enum PortablePackageCleanupError:
    Error, Equatable, LocalizedError, Sendable {
    case invalidJournal
    case duplicateIntent
    case unregisteredTarget
    case unsafeTarget
    case cleanupRequired

    var errorDescription: String? {
        switch self {
        case .invalidJournal:
            "内部临时文件清理记录无效；没有删除任何文件。"
        case .duplicateIntent:
            "内部临时文件操作重复；没有创建新的副本。"
        case .unregisteredTarget:
            "目标不是本次 App 登记的临时副本；没有删除。"
        case .unsafeTarget:
            "临时文件路径或类型不安全；没有删除。"
        case .cleanupRequired:
            "敏感临时文件尚未清理；已保留精确重试凭据。"
        }
    }
}

struct PortablePackageCleanupJournalStore: Sendable {
    let layout: AppDataStoreLayout
    let beforeWrite:
        PortableManagedPathSecurity.MutationProbe

    init(
        layout: AppDataStoreLayout,
        beforeWrite:
            @escaping PortableManagedPathSecurity
            .MutationProbe = {}
    ) {
        self.layout = layout
        self.beforeWrite = beforeWrite
    }

    func readIfPresent() throws
        -> PortablePackageCleanupJournal? {
        do {
            guard let data = try
                PortableManagedPathSecurity
                .readRecoveryRegularFileIfPresent(
                    layout: layout,
                    fileName:
                        "portable-package-cleanup-v1.json",
                    maximumBytes: 512 * 1_024
                ) else {
                return nil
            }
            try StrictJSONDuplicateKeyScanner.validate(
                data,
                maximumDepth: 12,
                maximumStringBytes: 1_024
            )
            let root = try JSONSerialization
                .jsonObject(with: data)
            guard let dictionary =
                    root as? [String: Any],
                  Set(dictionary.keys) == [
                      "formatVersion", "intents",
                      "contractSHA256"
                  ],
                  let intents =
                    dictionary["intents"]
                        as? [[String: Any]],
                  intents.allSatisfy({
                      Set($0.keys) == [
                          "formatVersion",
                          "operationID", "kind",
                          "state",
                          "relativePath",
                          "contractSHA256"
                      ]
                  }) else {
                throw PortablePackageCleanupError
                    .invalidJournal
            }
            let value = try JSONDecoder
                .unmanualFoundation.decode(
                    PortablePackageCleanupJournal.self,
                    from: data
                )
            try validate(value)
            return value
        } catch let error as
            PortablePackageCleanupError {
            throw error
        } catch {
            throw PortablePackageCleanupError
                .invalidJournal
        }
    }

    func write(
        _ value: PortablePackageCleanupJournal
    ) throws {
        try validate(value)
        let data = try JSONEncoder
            .unmanualFoundation.encode(value)
        let readback: Data
        do {
            readback = try PortableManagedPathSecurity
                .writeRecoveryRegularFile(
                layout: layout,
                fileName:
                    "portable-package-cleanup-v1.json",
                data: data,
                maximumBytes: 512 * 1_024,
                backupPolicy: .excluded,
                beforeWrite: beforeWrite
            )
        } catch {
            throw error
        }
        guard readback == data else {
            throw PortablePackageCleanupError
                .invalidJournal
        }
        guard try readIfPresent() == value else {
            throw PortablePackageCleanupError
                .invalidJournal
        }
    }

    private func validate(
        _ value: PortablePackageCleanupJournal
    ) throws {
        guard value.formatVersion
                == PortablePackageCleanupJournal
                    .formatVersion,
              value.intents.count <= 4_096,
              value.contractSHA256
                == PortablePackageCleanupJournal
                    .contractDigest(
                        formatVersion:
                            value.formatVersion,
                        intents: value.intents
                    ) else {
            throw PortablePackageCleanupError
                .invalidJournal
        }
        var operationIDs: Set<UUID> = []
        var paths: Set<String> = []
        for intent in value.intents {
            guard intent.formatVersion
                    == PortablePackageCleanupIntent
                        .formatVersion,
                  operationIDs.insert(
                    intent.operationID
                  ).inserted,
                  paths.insert(
                    intent.relativePath
                  ).inserted,
                  intent.relativePath
                    == PortablePackageCleanupIntent
                        .relativePath(
                            operationID:
                                intent.operationID,
                            kind: intent.kind
                        ),
                  intent.contractSHA256
                    == PortablePackageCleanupIntent
                        .contractDigest(
                            formatVersion:
                                intent.formatVersion,
                            operationID:
                                intent.operationID,
                            kind: intent.kind,
                            state: intent.state,
                            relativePath:
                                intent.relativePath
                        ) else {
                throw PortablePackageCleanupError
                    .invalidJournal
            }
        }
        guard value.intents
            == value.intents.sorted(by: {
                $0.operationID.uuidString
                    < $1.operationID.uuidString
            }) else {
            throw PortablePackageCleanupError
                .invalidJournal
        }
    }
}

enum PortableManagedPathSecurity {
    typealias MutationProbe = @Sendable () throws -> Void

    static func ensureRecoveryDirectory(
        layout: AppDataStoreLayout
    ) throws {
        if Darwin.mkdir(
            layout.rootURL.path,
            S_IRWXU
        ) != 0,
        errno != EEXIST {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        guard let rootFD = try openDirectory(
            at: AT_FDCWD,
            component: layout.rootURL.path,
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        defer { Darwin.close(rootFD) }
        if "Recovery".withCString({
            Darwin.mkdirat(rootFD, $0, S_IRWXU)
        }) != 0,
        errno != EEXIST {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        guard let recoveryFD = try openDirectory(
            at: rootFD,
            component: "Recovery",
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        Darwin.close(recoveryFD)
    }

    static func readRecoveryRegularFileIfPresent(
        layout: AppDataStoreLayout,
        fileName: String,
        maximumBytes: Int
    ) throws -> Data? {
        guard let rootFD = try openDirectory(
            at: AT_FDCWD,
            component: layout.rootURL.path,
            allowMissing: true
        ) else {
            return nil
        }
        defer { Darwin.close(rootFD) }
        guard let recoveryFD = try openDirectory(
            at: rootFD,
            component: "Recovery",
            allowMissing: true
        ) else {
            return nil
        }
        defer { Darwin.close(recoveryFD) }

        guard let entry = try entryStatus(
            at: recoveryFD,
            component: fileName,
            allowMissing: true
        ) else {
            return nil
        }
        guard isRegular(entry) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        let descriptor = fileName.withCString {
            Darwin.openat(
                recoveryFD,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              isRegular(opened),
              sameFile(entry, opened),
              opened.st_size >= 0,
              opened.st_size <= off_t(maximumBytes) else {
            Darwin.close(descriptor)
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        defer { try? handle.close() }
        do {
            let data = try handle.readToEnd() ?? Data()
            guard data.count <= maximumBytes else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            return data
        } catch let error as
            PortablePackageCleanupError {
            throw error
        } catch {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
    }

    /// Atomically writes a fixed control file without ever resolving the
    /// Recovery directory again for the actual write or rename. The directory
    /// descriptors remain open from ancestry validation through readback.
    static func writeRecoveryRegularFile(
        layout: AppDataStoreLayout,
        fileName: String,
        data: Data,
        maximumBytes: Int,
        backupPolicy: SystemBackupPolicy,
        beforeWrite: MutationProbe = {}
    ) throws -> Data {
        guard isSafeComponent(fileName),
              data.count <= maximumBytes else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        if Darwin.mkdir(
            layout.rootURL.path,
            S_IRWXU
        ) != 0,
        errno != EEXIST {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        guard let rootFD = try openDirectory(
            at: AT_FDCWD,
            component: layout.rootURL.path,
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        defer { Darwin.close(rootFD) }
        var rootIdentity = stat()
        guard Darwin.fstat(rootFD, &rootIdentity) == 0,
              isDirectory(rootIdentity) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        if "Recovery".withCString({
            Darwin.mkdirat(rootFD, $0, S_IRWXU)
        }) != 0,
        errno != EEXIST {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        guard let recoveryFD = try openDirectory(
            at: rootFD,
            component: "Recovery",
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        defer { Darwin.close(recoveryFD) }
        var recoveryIdentity = stat()
        guard Darwin.fstat(
            recoveryFD,
            &recoveryIdentity
        ) == 0,
        isDirectory(recoveryIdentity) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        try applyCompleteProtection(
            descriptor: recoveryFD
        )

        try beforeWrite()
        try verifyRecoveryAncestry(
            layout: layout,
            rootIdentity: rootIdentity,
            recoveryIdentity: recoveryIdentity
        )

        if let existing = try entryStatus(
            at: recoveryFD,
            component: fileName,
            allowMissing: true
        ),
        !isRegular(existing) {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        let temporaryName =
            "." + fileName + ".tmp-"
            + UUID().uuidString.lowercased()
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                recoveryFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        var temporaryExists = true
        defer {
            Darwin.close(descriptor)
            if temporaryExists {
                _ = temporaryName.withCString {
                    Darwin.unlinkat(recoveryFD, $0, 0)
                }
            }
        }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              isRegular(opened) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        try applyCompleteProtection(
            descriptor: descriptor
        )
        try applyBackupPolicy(
            backupPolicy,
            descriptor: descriptor
        )
        try writeAll(data, descriptor: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        try verifyRecoveryAncestry(
            layout: layout,
            rootIdentity: rootIdentity,
            recoveryIdentity: recoveryIdentity
        )
        let renamed = temporaryName.withCString {
            source in
            fileName.withCString {
                destination in
                Darwin.renameat(
                    recoveryFD,
                    source,
                    recoveryFD,
                    destination
                )
            }
        }
        guard renamed == 0 else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        temporaryExists = false
        guard Darwin.fsync(recoveryFD) == 0 else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        guard let readback = try readRegularFile(
            at: recoveryFD,
            component: fileName,
            maximumBytes: maximumBytes
        ) else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        return readback
    }

    /// Builds and audits the private restore copy under one descriptor lease.
    /// Foundation URL APIs are used only to read the already-audited source.
    static func buildRestoreStagingPackage(
        source: AuditedPortableBackup,
        journal: PortableRestoreJournal,
        layout: AppDataStoreLayout,
        beforeCreate: MutationProbe = {},
        beforeWrite: MutationProbe = {}
    ) throws -> AuditedPortableBackup {
        guard let rootFD = try openDirectory(
            at: AT_FDCWD,
            component: layout.rootURL.path,
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        defer { Darwin.close(rootFD) }
        var rootIdentity = stat()
        guard Darwin.fstat(rootFD, &rootIdentity) == 0,
              isDirectory(rootIdentity),
              let recoveryFD = try openDirectory(
                at: rootFD,
                component: "Recovery",
                allowMissing: false
              ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        defer { Darwin.close(recoveryFD) }
        var recoveryIdentity = stat()
        guard Darwin.fstat(
            recoveryFD,
            &recoveryIdentity
        ) == 0,
        isDirectory(recoveryIdentity) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        if "PortableImports".withCString({
            Darwin.mkdirat(recoveryFD, $0, S_IRWXU)
        }) != 0,
        errno != EEXIST {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        guard
        let stagingFD = try openDirectory(
            at: recoveryFD,
            component: "PortableImports",
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        defer { Darwin.close(stagingFD) }
        var stagingIdentity = stat()
        let operationName =
            journal.operationID.uuidString.lowercased()
        guard Darwin.fstat(
            stagingFD,
            &stagingIdentity
        ) == 0,
        isDirectory(stagingIdentity) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        try applyCompleteProtection(
            descriptor: stagingFD
        )
        try applyBackupPolicy(
            .excluded,
            descriptor: stagingFD
        )
        try beforeCreate()
        try verifyRestoreStagingAncestry(
            layout: layout,
            rootIdentity: rootIdentity,
            recoveryIdentity: recoveryIdentity,
            stagingIdentity: stagingIdentity
        )
        guard try entryStatus(
            at: stagingFD,
            component: operationName,
            allowMissing: true
        ) == nil,
        operationName.withCString({
            Darwin.mkdirat(stagingFD, $0, S_IRWXU)
        }) == 0,
        let operationFD = try openDirectory(
            at: stagingFD,
            component: operationName,
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        defer { Darwin.close(operationFD) }
        var operationIdentity = stat()
        guard Darwin.fstat(
            operationFD,
            &operationIdentity
        ) == 0,
        isDirectory(operationIdentity),
        let publishedOperation = try entryStatus(
            at: stagingFD,
            component: operationName,
            allowMissing: false
        ),
        sameFile(publishedOperation, operationIdentity)
        else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        try applyCompleteProtection(
            descriptor: operationFD
        )
        try applyBackupPolicy(
            .excluded,
            descriptor: operationFD
        )
        let packageName = "package.unmanualbackup"
        guard packageName.withCString({
            Darwin.mkdirat(operationFD, $0, S_IRWXU)
        }) == 0,
        let packageFD = try openDirectory(
            at: operationFD,
            component: packageName,
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        defer { Darwin.close(packageFD) }
        var packageIdentity = stat()
        guard Darwin.fstat(
            packageFD,
            &packageIdentity
        ) == 0,
        isDirectory(packageIdentity),
        let publishedPackage = try entryStatus(
            at: operationFD,
            component: packageName,
            allowMissing: false
        ),
        sameFile(publishedPackage, packageIdentity),
        try directoryEntries(
            descriptor: packageFD
        ).isEmpty else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        try applyCompleteProtection(
            descriptor: packageFD
        )
        try applyBackupPolicy(
            .excluded,
            descriptor: packageFD
        )
        try verifyRestoreStagingPackageAncestry(
            layout: layout,
            operationID: journal.operationID,
            rootIdentity: rootIdentity,
            recoveryIdentity: recoveryIdentity,
            stagingIdentity: stagingIdentity,
            operationIdentity: operationIdentity,
            packageIdentity: packageIdentity
        )
        try beforeWrite()
        try verifyRestoreStagingPackageAncestry(
            layout: layout,
            operationID: journal.operationID,
            rootIdentity: rootIdentity,
            recoveryIdentity: recoveryIdentity,
            stagingIdentity: stagingIdentity,
            operationIdentity: operationIdentity,
            packageIdentity: packageIdentity
        )

        let document = source.readableDocument
        let readableData = try PortableDataV2Codec
            .encode(document)
        let dataFD = try createChildDirectory(
            at: packageFD,
            component: "data",
            backupPolicy: .excluded
        )
        defer { Darwin.close(dataFD) }
        try createChildFile(
            at: dataFD,
            component: "readable-v2.json",
            data: readableData,
            maximumBytes:
                PortableBackupLimits
                .maximumReadableBytes,
            backupPolicy: .excluded
        )
        let readableEntry =
            PortableBackupPackageEntry(
                relativePath:
                    "data/readable-v2.json",
                byteCount:
                    Int64(readableData.count),
                sha256Hex:
                    PortableBackupFileAudit
                    .sha256Hex(readableData)
            )

        var attachmentEntries:
            [PortableBackupPackageEntry] = []
        if !document.payload.activeAttachments
            .isEmpty {
            let attachmentsFD =
                try createChildDirectory(
                    at: packageFD,
                    component: "attachments",
                    backupPolicy: .excluded
                )
            defer { Darwin.close(attachmentsFD) }
            for attachment in document.payload
                .activeAttachments {
                try PortableBackupPathPolicy.validate(
                    attachment.packageRelativePath
                )
                let attachmentName =
                    attachment.attachmentID
                    .uuidString.lowercased()
                let attachmentFD =
                    try createChildDirectory(
                        at: attachmentsFD,
                        component: attachmentName,
                        backupPolicy: .excluded
                    )
                do {
                    let sourceURL = source.packageURL
                        .appending(
                            path:
                                attachment
                                .packageRelativePath
                        )
                    let attachmentData =
                        try PortableBackupFileAudit
                        .boundedData(
                            sourceURL,
                            maximumBytes: Int(
                                PortableBackupLimits
                                .maximumAttachmentBytes
                            )
                        )
                    guard Int64(
                        attachmentData.count
                    ) == attachment.byteCount,
                    PortableBackupFileAudit.sha256Hex(
                        attachmentData
                    ) == attachment.sha256Hex else {
                        throw PortableBackupError
                            .attachmentMismatch
                    }
                    try createChildFile(
                        at: attachmentFD,
                        component: "payload",
                        data: attachmentData,
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
                attachmentEntries.append(
                    PortableBackupPackageEntry(
                        relativePath:
                            attachment
                            .packageRelativePath,
                        byteCount:
                            attachment.byteCount,
                        sha256Hex:
                            attachment.sha256Hex
                    )
                )
            }
        }
        let payload = try
            PortableBackupManifestPayload(
                datasetID:
                    document.payload.datasetID,
                sourceGenerationID:
                    document.payload
                    .sourceGenerationID,
                createdAtMicroseconds:
                    document.payload
                    .capturedAtMicroseconds,
                readableData: readableEntry,
                attachments:
                    attachmentEntries.sorted {
                        $0.relativePath
                            < $1.relativePath
                    }
            )
        let manifest = try
            PortableBackupManifestCodec.make(
                payload: payload
            )
        let manifestData = try
            PortableBackupManifestCodec.encode(
                manifest
            )
        try createChildFile(
            at: packageFD,
            component: "manifest.json",
            data: manifestData,
            maximumBytes:
                PortableBackupLimits
                .maximumManifestBytes,
            backupPolicy: .excluded
        )
        guard Darwin.fsync(packageFD) == 0 else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        try verifyRestoreStagingPackageAncestry(
            layout: layout,
            operationID: journal.operationID,
            rootIdentity: rootIdentity,
            recoveryIdentity: recoveryIdentity,
            stagingIdentity: stagingIdentity,
            operationIdentity: operationIdentity,
            packageIdentity: packageIdentity
        )
        let destination =
            journal.stagingURL(in: layout)
        let audited = try auditRestoreStagingPackage(
            descriptor: packageFD,
            packageURL: destination,
            expectedDocument: document,
            expectedManifest: manifest,
            expectedManifestData: manifestData
        )
        try verifyRestoreStagingPackageAncestry(
            layout: layout,
            operationID: journal.operationID,
            rootIdentity: rootIdentity,
            recoveryIdentity: recoveryIdentity,
            stagingIdentity: stagingIdentity,
            operationIdentity: operationIdentity,
            packageIdentity: packageIdentity
        )
        return audited
    }

    private static func auditRestoreStagingPackage(
        descriptor packageFD: Int32,
        packageURL: URL,
        expectedDocument: PortableDataV2Document,
        expectedManifest: PortableBackupManifest,
        expectedManifestData: Data
    ) throws -> AuditedPortableBackup {
        var expectedRootEntries: Set<String> = [
            "data",
            "manifest.json"
        ]
        if !expectedDocument.payload
            .activeAttachments.isEmpty {
            expectedRootEntries.insert("attachments")
        }
        guard Set(try directoryEntries(
            descriptor: packageFD
        )) == expectedRootEntries else {
            throw PortableBackupError.unexpectedEntry
        }

        let dataFD = try openVerifiedChildDirectory(
            at: packageFD,
            component: "data"
        )
        defer { Darwin.close(dataFD) }
        guard try directoryEntries(
            descriptor: dataFD
        ) == ["readable-v2.json"],
        let readableData = try readRegularFile(
            at: dataFD,
            component: "readable-v2.json",
            maximumBytes:
                PortableBackupLimits.maximumReadableBytes
        ) else {
            throw PortableBackupError.missingEntry
        }
        let decodedDocument =
            try PortableDataV2Codec.decode(readableData)
        guard decodedDocument == expectedDocument else {
            throw PortableBackupError.manifestMismatch
        }

        guard let manifestData = try readRegularFile(
            at: packageFD,
            component: "manifest.json",
            maximumBytes:
                PortableBackupLimits.maximumManifestBytes
        ),
        manifestData == expectedManifestData,
        try PortableBackupManifestCodec.decode(manifestData)
            == expectedManifest else {
            throw PortableBackupError.manifestMismatch
        }

        let readableEntry = PortableBackupPackageEntry(
            relativePath: "data/readable-v2.json",
            byteCount: Int64(readableData.count),
            sha256Hex:
                PortableBackupFileAudit.sha256Hex(
                    readableData
                )
        )
        guard readableEntry
                == expectedManifest.payload.readableData
        else {
            throw PortableBackupError.manifestMismatch
        }

        var attachmentEntries:
            [PortableBackupPackageEntry] = []
        if !expectedDocument.payload
            .activeAttachments.isEmpty {
            let attachmentsFD =
                try openVerifiedChildDirectory(
                    at: packageFD,
                    component: "attachments"
                )
            defer { Darwin.close(attachmentsFD) }
            let expectedNames = Set(
                expectedDocument.payload
                    .activeAttachments.map {
                        $0.attachmentID
                            .uuidString.lowercased()
                    }
            )
            guard Set(try directoryEntries(
                descriptor: attachmentsFD
            )) == expectedNames else {
                throw PortableBackupError.unexpectedEntry
            }
            for attachment in expectedDocument.payload
                .activeAttachments {
                let name = attachment.attachmentID
                    .uuidString.lowercased()
                let attachmentFD =
                    try openVerifiedChildDirectory(
                        at: attachmentsFD,
                        component: name
                    )
                do {
                    guard try directoryEntries(
                        descriptor: attachmentFD
                    ) == ["payload"],
                    let payload = try readRegularFile(
                        at: attachmentFD,
                        component: "payload",
                        maximumBytes: Int(
                            PortableBackupLimits
                                .maximumAttachmentBytes
                        )
                    ),
                    Int64(payload.count)
                        == attachment.byteCount,
                    PortableBackupFileAudit.sha256Hex(
                        payload
                    ) == attachment.sha256Hex else {
                        throw PortableBackupError
                            .attachmentMismatch
                    }
                    Darwin.close(attachmentFD)
                } catch {
                    Darwin.close(attachmentFD)
                    throw error
                }
                attachmentEntries.append(
                    PortableBackupPackageEntry(
                        relativePath:
                            attachment
                            .packageRelativePath,
                        byteCount:
                            attachment.byteCount,
                        sha256Hex:
                            attachment.sha256Hex
                    )
                )
            }
        }
        guard attachmentEntries.sorted(by: {
            $0.relativePath < $1.relativePath
        }) == expectedManifest.payload.attachments else {
            throw PortableBackupError.attachmentMismatch
        }

        let expectedEntries =
            [readableEntry]
            + attachmentEntries
            + [
                PortableBackupPackageEntry(
                    relativePath: "manifest.json",
                    byteCount:
                        Int64(manifestData.count),
                    sha256Hex:
                        PortableBackupFileAudit.sha256Hex(
                            manifestData
                        )
                )
            ]
        let packageDigestInput =
            expectedEntries.sorted {
                $0.relativePath < $1.relativePath
            }.map {
                "\($0.relativePath)\0\($0.byteCount)\0\($0.sha256Hex)"
            }.joined(separator: "\0")
        return AuditedPortableBackup(
            packageURL: packageURL,
            manifest: expectedManifest,
            readableDocument: decodedDocument,
            packageSHA256:
                PortableBackupFileAudit.sha256Hex(
                    Data(packageDigestInput.utf8)
                )
        )
    }

    static func removeTransferPackage(
        transferRootURL: URL,
        packageName: String,
        beforeQuarantine:
            @Sendable (URL) throws -> Void = { _ in }
    ) throws {
        guard isSafeComponent(packageName),
              let rootFD = try openDirectory(
                at: AT_FDCWD,
                component: transferRootURL.path,
                allowMissing: true
              ) else {
            if !isSafeComponent(packageName) {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            return
        }
        defer { Darwin.close(rootFD) }
        let quarantineName = ".cleanup-" + packageName
        let packageStatus = try entryStatus(
            at: rootFD,
            component: packageName,
            allowMissing: true
        )
        let quarantineStatus = try entryStatus(
            at: rootFD,
            component: quarantineName,
            allowMissing: true
        )
        guard packageStatus == nil
                || quarantineStatus == nil else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        guard packageStatus != nil
                || quarantineStatus != nil else {
            return
        }
        let activeName = packageStatus == nil
            ? quarantineName : packageName
        guard let initial = packageStatus
                ?? quarantineStatus,
              isDirectory(initial),
              let packageFD = try openDirectory(
                at: rootFD,
                component: activeName,
                allowMissing: false
              ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        defer { Darwin.close(packageFD) }
        var opened = stat()
        guard Darwin.fstat(packageFD, &opened) == 0,
              isDirectory(opened),
              sameFile(initial, opened) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        let treeSnapshot = try preflightTree(
            descriptor: packageFD
        )
        let candidateURL = transferRootURL.appending(
            path: packageName,
            directoryHint: .isDirectory
        )
        do {
            try beforeQuarantine(candidateURL)
        } catch {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        guard let current = try entryStatus(
            at: rootFD,
            component: activeName,
            allowMissing: false
        ),
        isDirectory(current),
        sameFile(current, opened) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        try verifyTree(
            descriptor: packageFD,
            snapshot: treeSnapshot
        )
        if activeName == packageName {
            let renamed = packageName.withCString {
                source in
                quarantineName.withCString {
                    destination in
                    Darwin.renameat(
                        rootFD,
                        source,
                        rootFD,
                        destination
                    )
                }
            }
            guard renamed == 0,
                  let quarantined = try entryStatus(
                    at: rootFD,
                    component: quarantineName,
                    allowMissing: false
                  ),
                  isDirectory(quarantined),
                  sameFile(quarantined, opened) else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
        }
        try removeTreeContents(
            descriptor: packageFD,
            snapshot: treeSnapshot
        )
        guard let final = try entryStatus(
            at: rootFD,
            component: quarantineName,
            allowMissing: false
        ),
        isDirectory(final),
        sameFile(final, opened),
        quarantineName.withCString({
            Darwin.unlinkat(
                rootFD,
                $0,
                AT_REMOVEDIR
            )
        }) == 0 else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
    }

    static func removeRestoreOperation(
        layout: AppDataStoreLayout,
        operationID: UUID,
        beforeQuarantine:
            MutationProbe = {}
    ) throws {
        guard let rootFD = try openDirectory(
            at: AT_FDCWD,
            component: layout.rootURL.path,
            allowMissing: true
        ) else {
            return
        }
        defer { Darwin.close(rootFD) }
        guard let recoveryFD = try openDirectory(
            at: rootFD,
            component: "Recovery",
            allowMissing: true
        ) else {
            return
        }
        defer { Darwin.close(recoveryFD) }
        guard let stagingFD = try openDirectory(
            at: recoveryFD,
            component: "PortableImports",
            allowMissing: true
        ) else {
            return
        }
        defer { Darwin.close(stagingFD) }

        let operationName =
            operationID.uuidString.lowercased()
        let quarantineName =
            ".cleanup-" + operationName
        let operationStatus = try entryStatus(
            at: stagingFD,
            component: operationName,
            allowMissing: true
        )
        let quarantineStatus = try entryStatus(
            at: stagingFD,
            component: quarantineName,
            allowMissing: true
        )
        guard operationStatus == nil
                || quarantineStatus == nil else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        guard operationStatus != nil
                || quarantineStatus != nil else {
            try removeStagingRootIfEmpty(
                recoveryFD: recoveryFD,
                stagingFD: stagingFD
            )
            return
        }
        let activeName = operationStatus == nil
            ? quarantineName : operationName
        guard let initial = operationStatus
                ?? quarantineStatus,
              isDirectory(initial) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        guard let operationFD = try openDirectory(
            at: stagingFD,
            component: activeName,
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        defer { Darwin.close(operationFD) }
        var openedOperation = stat()
        guard Darwin.fstat(
            operationFD,
            &openedOperation
        ) == 0,
        isDirectory(openedOperation),
        sameFile(initial, openedOperation) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }

        let packageName = "package.unmanualbackup"
        let children = try directoryEntries(
            descriptor: operationFD
        )
        guard children.isEmpty
                || children == [packageName] else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        var openedPackage: stat?
        if children == [packageName] {
            guard let packageStatus = try entryStatus(
                at: operationFD,
                component: packageName,
                allowMissing: false
            ),
            isDirectory(packageStatus),
            let packageFD = try openDirectory(
                at: operationFD,
                component: packageName,
                allowMissing: false
            ) else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            defer { Darwin.close(packageFD) }
            var packageOpened = stat()
            guard Darwin.fstat(
                packageFD,
                &packageOpened
            ) == 0,
            isDirectory(packageOpened),
            sameFile(
                packageStatus,
                packageOpened
            ) else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            openedPackage = packageOpened
        }

        let treeSnapshot = try preflightTree(
            descriptor: operationFD
        )
        try beforeQuarantine()

        guard let currentOperation = try entryStatus(
            at: stagingFD,
            component: activeName,
            allowMissing: false
        ),
        isDirectory(currentOperation),
        sameFile(
            currentOperation,
            openedOperation
        ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        let currentChildren = try directoryEntries(
            descriptor: operationFD
        )
        guard currentChildren == children else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        if let openedPackage {
            guard let currentPackage = try entryStatus(
                at: operationFD,
                component: packageName,
                allowMissing: false
            ),
            isDirectory(currentPackage),
            sameFile(
                currentPackage,
                openedPackage
            ) else {
                throw PortablePackageCleanupError
                .unsafeTarget
            }
        }
        try verifyTree(
            descriptor: operationFD,
            snapshot: treeSnapshot
        )

        if activeName == operationName {
            let renamed = operationName.withCString {
                source in
                quarantineName.withCString {
                    destination in
                    Darwin.renameat(
                        stagingFD,
                        source,
                        stagingFD,
                        destination
                    )
                }
            }
            guard renamed == 0,
                  let quarantined =
                    try entryStatus(
                        at: stagingFD,
                        component: quarantineName,
                        allowMissing: false
                    ),
                  isDirectory(quarantined),
                  sameFile(
                    quarantined,
                    openedOperation
                  ) else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
        }

        try removeTreeContents(
            descriptor: operationFD,
            snapshot: treeSnapshot
        )
        guard let finalStatus = try entryStatus(
            at: stagingFD,
            component: quarantineName,
            allowMissing: false
        ),
        isDirectory(finalStatus),
        sameFile(
            finalStatus,
            openedOperation
        ) else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        let removed = quarantineName.withCString {
            Darwin.unlinkat(
                stagingFD,
                $0,
                AT_REMOVEDIR
            )
        }
        guard removed == 0 else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        try removeStagingRootIfEmpty(
            recoveryFD: recoveryFD,
            stagingFD: stagingFD
        )
    }

    static func restoreOperationExists(
        layout: AppDataStoreLayout,
        operationID: UUID
    ) throws -> Bool {
        guard let rootFD = try openDirectory(
            at: AT_FDCWD,
            component: layout.rootURL.path,
            allowMissing: true
        ) else {
            return false
        }
        defer { Darwin.close(rootFD) }
        guard let recoveryFD = try openDirectory(
            at: rootFD,
            component: "Recovery",
            allowMissing: true
        ) else {
            return false
        }
        defer { Darwin.close(recoveryFD) }
        guard let stagingFD = try openDirectory(
            at: recoveryFD,
            component: "PortableImports",
            allowMissing: true
        ) else {
            return false
        }
        defer { Darwin.close(stagingFD) }
        return try entryStatus(
            at: stagingFD,
            component:
                operationID.uuidString.lowercased(),
            allowMissing: true
        ) != nil
    }

    private static func verifyRecoveryAncestry(
        layout: AppDataStoreLayout,
        rootIdentity: stat,
        recoveryIdentity: stat
    ) throws {
        guard let currentRoot = try openDirectory(
            at: AT_FDCWD,
            component: layout.rootURL.path,
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        defer { Darwin.close(currentRoot) }
        var currentRootIdentity = stat()
        guard Darwin.fstat(
            currentRoot,
            &currentRootIdentity
        ) == 0,
        sameFile(
            currentRootIdentity,
            rootIdentity
        ),
        let currentRecovery = try openDirectory(
            at: currentRoot,
            component: "Recovery",
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        defer { Darwin.close(currentRecovery) }
        var currentRecoveryIdentity = stat()
        guard Darwin.fstat(
            currentRecovery,
            &currentRecoveryIdentity
        ) == 0,
        sameFile(
            currentRecoveryIdentity,
            recoveryIdentity
        ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
    }

    private static func verifyRestoreStagingPackageAncestry(
        layout: AppDataStoreLayout,
        operationID: UUID,
        rootIdentity: stat,
        recoveryIdentity: stat,
        stagingIdentity: stat,
        operationIdentity: stat,
        packageIdentity: stat
    ) throws {
        guard let currentRoot = try openDirectory(
            at: AT_FDCWD,
            component: layout.rootURL.path,
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        defer { Darwin.close(currentRoot) }
        var currentRootIdentity = stat()
        guard Darwin.fstat(
            currentRoot,
            &currentRootIdentity
        ) == 0,
        sameFile(
            currentRootIdentity,
            rootIdentity
        ),
        let currentRecovery = try openDirectory(
            at: currentRoot,
            component: "Recovery",
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        defer { Darwin.close(currentRecovery) }
        var currentRecoveryIdentity = stat()
        guard Darwin.fstat(
            currentRecovery,
            &currentRecoveryIdentity
        ) == 0,
        sameFile(
            currentRecoveryIdentity,
            recoveryIdentity
        ),
        let currentStaging = try openDirectory(
            at: currentRecovery,
            component: "PortableImports",
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        defer { Darwin.close(currentStaging) }
        var currentStagingIdentity = stat()
        let operationName =
            operationID.uuidString.lowercased()
        guard Darwin.fstat(
            currentStaging,
            &currentStagingIdentity
        ) == 0,
        sameFile(
            currentStagingIdentity,
            stagingIdentity
        ),
        let currentOperation = try openDirectory(
            at: currentStaging,
            component: operationName,
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        defer { Darwin.close(currentOperation) }
        var currentOperationIdentity = stat()
        guard Darwin.fstat(
            currentOperation,
            &currentOperationIdentity
        ) == 0,
        sameFile(
            currentOperationIdentity,
            operationIdentity
        ),
        let currentPackage = try openDirectory(
            at: currentOperation,
            component: "package.unmanualbackup",
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        defer { Darwin.close(currentPackage) }
        var currentPackageIdentity = stat()
        guard Darwin.fstat(
            currentPackage,
            &currentPackageIdentity
        ) == 0,
        sameFile(
            currentPackageIdentity,
            packageIdentity
        ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
    }

    private static func createChildDirectory(
        at parentFD: Int32,
        component: String,
        backupPolicy: SystemBackupPolicy
    ) throws -> Int32 {
        guard isSafeComponent(component),
              component.withCString({
                Darwin.mkdirat(
                    parentFD,
                    $0,
                    S_IRWXU
                )
              }) == 0,
              let descriptor = try openDirectory(
                at: parentFD,
                component: component,
                allowMissing: false
              ) else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        do {
            guard let published = try entryStatus(
                at: parentFD,
                component: component,
                allowMissing: false
            ) else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            var opened = stat()
            guard Darwin.fstat(
                descriptor,
                &opened
            ) == 0,
            isDirectory(published),
            isDirectory(opened),
            sameFile(published, opened) else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            try applyCompleteProtection(
                descriptor: descriptor
            )
            try applyBackupPolicy(
                backupPolicy,
                descriptor: descriptor
            )
            guard Darwin.fsync(parentFD) == 0 else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func openVerifiedChildDirectory(
        at parentFD: Int32,
        component: String
    ) throws -> Int32 {
        guard isSafeComponent(component),
              let expected = try entryStatus(
                at: parentFD,
                component: component,
                allowMissing: false
              ),
              isDirectory(expected),
              let descriptor = try openDirectory(
                at: parentFD,
                component: component,
                allowMissing: false
              ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              isDirectory(opened),
              sameFile(expected, opened) else {
            Darwin.close(descriptor)
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        return descriptor
    }

    private static func createChildFile(
        at parentFD: Int32,
        component: String,
        data: Data,
        maximumBytes: Int,
        backupPolicy: SystemBackupPolicy
    ) throws {
        guard isSafeComponent(component),
              data.count <= maximumBytes else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        let descriptor = component.withCString {
            Darwin.openat(
                parentFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              isRegular(opened) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        try applyCompleteProtection(
            descriptor: descriptor
        )
        try applyBackupPolicy(
            backupPolicy,
            descriptor: descriptor
        )
        try writeAll(data, descriptor: descriptor)
        guard Darwin.fsync(descriptor) == 0,
              let readback = try readRegularFile(
                at: parentFD,
                component: component,
                maximumBytes: maximumBytes
              ),
              readback == data,
              Darwin.fsync(parentFD) == 0 else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
    }

    private static func verifyRestoreStagingAncestry(
        layout: AppDataStoreLayout,
        rootIdentity: stat,
        recoveryIdentity: stat,
        stagingIdentity: stat
    ) throws {
        try verifyRecoveryAncestry(
            layout: layout,
            rootIdentity: rootIdentity,
            recoveryIdentity: recoveryIdentity
        )
        guard let currentRoot = try openDirectory(
            at: AT_FDCWD,
            component: layout.rootURL.path,
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        defer { Darwin.close(currentRoot) }
        guard let currentRecovery = try openDirectory(
            at: currentRoot,
            component: "Recovery",
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        defer { Darwin.close(currentRecovery) }
        guard let currentStaging = try openDirectory(
            at: currentRecovery,
            component: "PortableImports",
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        defer { Darwin.close(currentStaging) }
        var currentStagingIdentity = stat()
        guard Darwin.fstat(
            currentStaging,
            &currentStagingIdentity
        ) == 0,
        sameFile(
            currentStagingIdentity,
            stagingIdentity
        ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
    }

    private static func readRegularFile(
        at parentFD: Int32,
        component: String,
        maximumBytes: Int
    ) throws -> Data? {
        guard let expected = try entryStatus(
            at: parentFD,
            component: component,
            allowMissing: true
        ) else {
            return nil
        }
        guard isRegular(expected) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        let descriptor = component.withCString {
            Darwin.openat(
                parentFD,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              isRegular(opened),
              sameFile(expected, opened),
              opened.st_size >= 0,
              opened.st_size <= off_t(maximumBytes) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        var data = Data(count: Int(opened.st_size))
        var offset = 0
        try data.withUnsafeMutableBytes {
            buffer in
            while offset < buffer.count {
                guard let base = buffer.baseAddress else {
                    break
                }
                let count = Darwin.pread(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset,
                    off_t(offset)
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw PortablePackageCleanupError
                        .cleanupRequired
                }
                offset += count
            }
        }
        guard offset == data.count else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        return data
    }

    private static func writeAll(
        _ data: Data,
        descriptor: Int32
    ) throws {
        var offset = 0
        try data.withUnsafeBytes {
            buffer in
            while offset < buffer.count {
                guard let base = buffer.baseAddress else {
                    break
                }
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw PortablePackageCleanupError
                        .cleanupRequired
                }
                offset += count
            }
        }
        guard offset == data.count else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
    }

    private static func applyCompleteProtection(
        descriptor: Int32
    ) throws {
        #if targetEnvironment(simulator)
        _ = descriptor
        #else
        guard Darwin.fcntl(
            descriptor,
            F_SETPROTECTIONCLASS,
            1
        ) == 0 else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        #endif
    }

    private static func applyBackupPolicy(
        _ policy: SystemBackupPolicy,
        descriptor: Int32
    ) throws {
        guard policy == .excluded else {
            return
        }
        var excluded: UInt8 = 1
        let result = "com.apple.MobileBackup"
            .withCString {
                name in
                withUnsafePointer(to: &excluded) {
                    value in
                    Darwin.fsetxattr(
                        descriptor,
                        name,
                        value,
                        MemoryLayout<UInt8>.size,
                        0,
                        0
                    )
                }
            }
        #if targetEnvironment(simulator)
        if result != 0,
           errno != ENOTSUP,
           errno != EOPNOTSUPP {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        #else
        guard result == 0 else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        #endif
    }

    private static func isSafeComponent(
        _ value: String
    ) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\0")
    }

    private static func openDirectory(
        at parentFD: Int32,
        component: String,
        allowMissing: Bool
    ) throws -> Int32? {
        let descriptor = component.withCString {
            Darwin.openat(
                parentFD,
                $0,
                O_RDONLY | O_DIRECTORY
                    | O_NOFOLLOW | O_CLOEXEC
            )
        }
        if descriptor >= 0 {
            return descriptor
        }
        if allowMissing, errno == ENOENT {
            return nil
        }
        if errno == ELOOP || errno == ENOTDIR {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        throw PortablePackageCleanupError
            .cleanupRequired
    }

    private static func entryStatus(
        at parentFD: Int32,
        component: String,
        allowMissing: Bool
    ) throws -> stat? {
        var value = stat()
        let result = component.withCString {
            Darwin.fstatat(
                parentFD,
                $0,
                &value,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result == 0 {
            return value
        }
        if allowMissing, errno == ENOENT {
            return nil
        }
        throw PortablePackageCleanupError
            .cleanupRequired
    }

    private static func directoryEntries(
        descriptor: Int32
    ) throws -> [String] {
        let iteratorFD = ".".withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_RDONLY | O_DIRECTORY
                    | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard iteratorFD >= 0,
              let directory = Darwin.fdopendir(
                iteratorFD
              ) else {
            if iteratorFD >= 0 {
                Darwin.close(iteratorFD)
            }
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        defer { Darwin.closedir(directory) }
        var values: [String] = []
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
                values.append(name)
            }
        }
        return values.sorted()
    }

    private typealias ManagedTreeSnapshot =
        [String: stat]

    private static func preflightTree(
        descriptor: Int32,
        prefix: String = ""
    ) throws -> ManagedTreeSnapshot {
        var snapshot: ManagedTreeSnapshot = [:]
        for name in try directoryEntries(
            descriptor: descriptor
        ) {
            guard let value = try entryStatus(
                at: descriptor,
                component: name,
                allowMissing: false
            ) else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            let path = prefix.isEmpty
                ? name : prefix + "/" + name
            snapshot[path] = value
            if isDirectory(value) {
                guard let child = try openDirectory(
                    at: descriptor,
                    component: name,
                    allowMissing: false
                ) else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                var opened = stat()
                guard Darwin.fstat(
                    child,
                    &opened
                ) == 0,
                sameManagedEntry(value, opened) else {
                    Darwin.close(child)
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                do {
                    let descendants =
                        try preflightTree(
                            descriptor: child,
                            prefix: path
                        )
                    for (descendantPath, status)
                    in descendants {
                        guard snapshot[descendantPath]
                                == nil else {
                            throw PortablePackageCleanupError
                                .unsafeTarget
                        }
                        snapshot[descendantPath] =
                            status
                    }
                    Darwin.close(child)
                } catch {
                    Darwin.close(child)
                    throw error
                }
            } else if isRegular(value)
                        || isSymbolicLink(value) {
                continue
            } else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
        }
        return snapshot
    }

    private static func verifyTree(
        descriptor: Int32,
        snapshot: ManagedTreeSnapshot
    ) throws {
        let current = try preflightTree(
            descriptor: descriptor
        )
        guard Set(current.keys) == Set(snapshot.keys),
              current.allSatisfy({
                  guard let expected = snapshot[$0.key]
                  else { return false }
                  return sameManagedEntry(
                      $0.value,
                      expected
                  )
              }) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
    }

    private static func removeTreeContents(
        descriptor: Int32,
        snapshot: ManagedTreeSnapshot,
        prefix: String = ""
    ) throws {
        let names = try directoryEntries(
            descriptor: descriptor
        )
        let depth = prefix.isEmpty
            ? 1 : prefix.split(separator: "/").count + 1
        let expectedNames: Set<String> = Set(
            snapshot.keys.compactMap {
                path -> String? in
                let components = path.split(
                    separator: "/"
                )
                guard components.count == depth,
                      prefix.isEmpty
                        || path.hasPrefix(prefix + "/")
                else {
                    return nil
                }
                return String(components.last!)
            }
        )
        guard Set(names) == expectedNames else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        for name in names {
            let path = prefix.isEmpty
                ? name : prefix + "/" + name
            guard let expected = snapshot[path],
                  let value = try entryStatus(
                    at: descriptor,
                    component: name,
                    allowMissing: false
                  ),
                  sameManagedEntry(value, expected)
            else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
            if isDirectory(value) {
                guard let child = try openDirectory(
                    at: descriptor,
                    component: name,
                    allowMissing: false
                ) else {
                    throw PortablePackageCleanupError
                        .cleanupRequired
                }
                var opened = stat()
                guard Darwin.fstat(
                    child,
                    &opened
                ) == 0,
                sameManagedEntry(expected, opened) else {
                    Darwin.close(child)
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                do {
                    try removeTreeContents(
                        descriptor: child,
                        snapshot: snapshot,
                        prefix: path
                    )
                    guard let final =
                            try entryStatus(
                                at: descriptor,
                                component: name,
                                allowMissing: false
                            ),
                          sameManagedEntry(
                            final,
                            opened
                          ) else {
                        throw PortablePackageCleanupError
                            .unsafeTarget
                    }
                    Darwin.close(child)
                } catch {
                    Darwin.close(child)
                    throw error
                }
                guard name.withCString({
                    Darwin.unlinkat(
                        descriptor,
                        $0,
                        AT_REMOVEDIR
                    )
                }) == 0 else {
                    throw PortablePackageCleanupError
                        .cleanupRequired
                }
            } else if isRegular(value)
                        || isSymbolicLink(value) {
                guard let final = try entryStatus(
                    at: descriptor,
                    component: name,
                    allowMissing: false
                ),
                sameManagedEntry(final, expected)
                else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                guard name.withCString({
                    Darwin.unlinkat(
                        descriptor,
                        $0,
                        0
                    )
                }) == 0 else {
                    throw PortablePackageCleanupError
                        .cleanupRequired
                }
            } else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
        }
    }

    private static func sameManagedEntry(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        sameFile(lhs, rhs)
            && (lhs.st_mode & S_IFMT)
                == (rhs.st_mode & S_IFMT)
    }

    private static func removeStagingRootIfEmpty(
        recoveryFD: Int32,
        stagingFD: Int32
    ) throws {
        guard try directoryEntries(
            descriptor: stagingFD
        ).isEmpty else {
            return
        }
        var opened = stat()
        guard Darwin.fstat(stagingFD, &opened) == 0,
              let published = try entryStatus(
                at: recoveryFD,
                component: "PortableImports",
                allowMissing: false
              ),
              isDirectory(published),
              sameFile(published, opened) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        guard "PortableImports".withCString({
            Darwin.unlinkat(
                recoveryFD,
                $0,
                AT_REMOVEDIR
            )
        }) == 0 || errno == ENOTEMPTY else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
    }

    private static func sameFile(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
    }

    private static func isDirectory(
        _ value: stat
    ) -> Bool {
        (value.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isRegular(
        _ value: stat
    ) -> Bool {
        (value.st_mode & S_IFMT) == S_IFREG
    }

    private static func isSymbolicLink(
        _ value: stat
    ) -> Bool {
        (value.st_mode & S_IFMT) == S_IFLNK
    }
}

private final class
PortablePackageCleanupJournalTransactionLock:
    @unchecked Sendable {
    static let shared =
        PortablePackageCleanupJournalTransactionLock()

    private let lock = NSRecursiveLock()

    private init() {}

    func withLock<Value>(
        _ operation: () throws -> Value
    ) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

actor PortablePackageCleanupCoordinator {
    typealias TransferMutationProbe =
        @Sendable (URL) throws -> Void
    typealias RestoreMutationProbe =
        PortableManagedPathSecurity.MutationProbe

    private let layout: AppDataStoreLayout
    private let transferRootURL: URL
    private let store:
        PortablePackageCleanupJournalStore
    private let beforeTransferQuarantine:
        TransferMutationProbe
    private let beforeRestoreQuarantine:
        RestoreMutationProbe

    init(
        layout: AppDataStoreLayout,
        transferRootURL: URL = FileManager.default
            .temporaryDirectory.appending(
                path: "UnmanualTransfers",
                directoryHint: .isDirectory
        ),
        beforeTransferQuarantine:
            @escaping TransferMutationProbe = { _ in },
        beforeRestoreQuarantine:
            @escaping RestoreMutationProbe = {}
    ) {
        self.layout = layout
        self.transferRootURL = transferRootURL
        self.store =
            PortablePackageCleanupJournalStore(
                layout: layout
            )
        self.beforeTransferQuarantine =
            beforeTransferQuarantine
        self.beforeRestoreQuarantine =
            beforeRestoreQuarantine
    }

    func register(
        kind: PortablePackageArtifactKind,
        operationID: UUID = UUID()
    ) throws -> PortablePackageCleanupIntent {
        try PortablePackageCleanupJournalTransactionLock
            .shared.withLock {
                var intents = try currentIntents()
                let intent =
                    PortablePackageCleanupIntent(
                        operationID: operationID,
                        kind: kind
                    )
                guard !intents.contains(where: {
                    $0.operationID == operationID
                        || $0.relativePath
                            == intent.relativePath
                }) else {
                    throw PortablePackageCleanupError
                        .duplicateIntent
                }
                intents.append(intent)
                try store.write(
                    PortablePackageCleanupJournal(
                        intents: intents
                    )
                )
                return intent
            }
    }

    func url(
        for intent: PortablePackageCleanupIntent
    ) -> URL {
        switch intent.kind {
        case .backupTransfer, .importTransfer:
            transferRootURL.appending(
                path: intent.relativePath,
                directoryHint: .isDirectory
            )
        case .restoreStaging:
            layout.recoveryURL.appending(
                path: intent.relativePath,
                directoryHint: .isDirectory
            )
        }
    }

    func discardTransferPackage(
        at url: URL
    ) throws {
        try PortablePackageCleanupJournalTransactionLock
            .shared.withLock {
                let standardized =
                    url.standardizedFileURL
                guard let intent = try currentIntents()
                    .first(where: {
                        $0.kind != .restoreStaging
                            && self.url(for: $0)
                                .standardizedFileURL
                                == standardized
                    }) else {
                    throw PortablePackageCleanupError
                        .unregisteredTarget
                }
                let pending =
                    try markCleanupPendingLocked(intent)
                try discardPendingLocked(pending)
            }
    }

    func discard(
        _ intent: PortablePackageCleanupIntent
    ) throws {
        try PortablePackageCleanupJournalTransactionLock
            .shared.withLock {
                let pending =
                    try markCleanupPendingLocked(intent)
                try discardPendingLocked(pending)
            }
    }

    private func markCleanupPendingLocked(
        _ intent: PortablePackageCleanupIntent
    ) throws -> PortablePackageCleanupIntent {
        let intents = try currentIntents()
        guard let stored = intents.first(where: {
            $0.operationID == intent.operationID
                && $0.kind == intent.kind
                && $0.relativePath == intent.relativePath
        }) else {
            throw PortablePackageCleanupError
                .unregisteredTarget
        }
        guard stored.state != .cleanupPending else {
            return stored
        }
        let pending = stored.updatingState(
            .cleanupPending
        )
        try store.write(
            PortablePackageCleanupJournal(
                intents: intents.map {
                    $0 == stored ? pending : $0
                }
            )
        )
        return pending
    }

    private func discardPendingLocked(
        _ intent: PortablePackageCleanupIntent
    ) throws {
        let intents = try currentIntents()
        guard intents.contains(intent),
              intent.state == .cleanupPending else {
            throw PortablePackageCleanupError
                .unregisteredTarget
        }
        switch intent.kind {
        case .backupTransfer, .importTransfer:
            try PortableManagedPathSecurity
                .removeTransferPackage(
                    transferRootURL:
                        transferRootURL,
                    packageName:
                        intent.relativePath,
                    beforeQuarantine:
                        beforeTransferQuarantine
                )
        case .restoreStaging:
            try PortableManagedPathSecurity
                .removeRestoreOperation(
                    layout: layout,
                    operationID:
                        intent.operationID,
                    beforeQuarantine:
                        beforeRestoreQuarantine
                )
        }
        let remaining = intents.filter {
            $0 != intent
        }
        do {
            try store.write(
                PortablePackageCleanupJournal(
                    intents: remaining
                )
            )
        } catch {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
    }

    func releaseRestoreIntent(
        operationID: UUID
    ) throws {
        try PortablePackageCleanupJournalTransactionLock
            .shared.withLock {
                let intents = try currentIntents()
                guard let intent =
                    intents.first(where: {
                        $0.kind == .restoreStaging
                            && $0.operationID
                                == operationID
                    }) else {
                    return
                }
                guard try !PortableManagedPathSecurity
                    .restoreOperationExists(
                        layout: layout,
                        operationID: operationID
                    ) else {
                    throw PortablePackageCleanupError
                        .cleanupRequired
                }
                try store.write(
                    PortablePackageCleanupJournal(
                        intents: intents.filter {
                            $0 != intent
                        }
                    )
                )
            }
    }

    func discardRestoreStaging(
        operationID: UUID
    ) throws {
        try PortablePackageCleanupJournalTransactionLock
            .shared.withLock {
                let intent:
                    PortablePackageCleanupIntent
                if let existing = try currentIntents()
                    .first(where: {
                        $0.kind == .restoreStaging
                            && $0.operationID
                                == operationID
                    }) {
                    intent = existing
                } else {
                    intent = try register(
                        kind: .restoreStaging,
                        operationID: operationID
                    )
                }
                let pending =
                    try markCleanupPendingLocked(intent)
                try discardPendingLocked(pending)
            }
    }

    func retryPending(
        protectingRestoreOperationID:
            UUID? = nil,
        includeActive: Bool = false
    ) throws {
        try PortablePackageCleanupJournalTransactionLock
            .shared.withLock {
                let snapshot = try currentIntents()
                for intent in snapshot {
                    if intent.kind
                        == .restoreStaging,
                       intent.operationID
                        == protectingRestoreOperationID {
                        continue
                    }
                    if intent.state == .active {
                        guard includeActive else {
                            continue
                        }
                        let pending =
                            try markCleanupPendingLocked(
                                intent
                            )
                        try discardPendingLocked(pending)
                    } else {
                        try discardPendingLocked(intent)
                    }
                }
            }
    }

    func pendingTransferURLs() throws -> [URL] {
        try PortablePackageCleanupJournalTransactionLock
            .shared.withLock {
                try currentIntents().compactMap {
                    $0.kind == .restoreStaging
                        || $0.state != .cleanupPending
                        ? nil : url(for: $0)
                }
            }
    }

    static func recoverBeforeStoreOpen(
        layout: AppDataStoreLayout
    ) async throws {
        let protectedOperationID = try
            PortableRestoreJournalStore(
                layout: layout
            ).readIfPresent()?.operationID
        let coordinator =
            PortablePackageCleanupCoordinator(
                layout: layout
            )
        try await coordinator.retryPending(
            protectingRestoreOperationID:
                protectedOperationID,
            includeActive: true
        )
    }

    private func currentIntents() throws
        -> [PortablePackageCleanupIntent] {
        try store.readIfPresent()?.intents ?? []
    }

}
