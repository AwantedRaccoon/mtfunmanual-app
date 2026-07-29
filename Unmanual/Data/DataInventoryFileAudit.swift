import CryptoKit
import Foundation

enum DataInventoryFileAuditError: Error, Equatable {
    case missingRequiredPath(String)
    case invalidFileType(String)
    case symbolicLink(String)
    case unknownManagedLeaf(String)
    case unsafeRelativePath(String)
    case duplicatePathOrInode(String)
    case readFailed(String)
}

enum DataInventoryRegularFileAudit {
    struct ReadResult {
        let snapshot: DataInventoryRegularFileSnapshot
        let data: Data
    }

    static func snapshot(
        at url: URL,
        relativePath: String,
        requiresSystemManagedProtection: Bool = false,
        fileManager: FileManager = .default
    ) throws -> DataInventoryRegularFileSnapshot {
        try read(
            at: url,
            relativePath: relativePath,
            requiresSystemManagedProtection:
                requiresSystemManagedProtection,
            fileManager: fileManager
        ).snapshot
    }

    static func read(
        at url: URL,
        relativePath: String,
        requiresSystemManagedProtection: Bool = false,
        fileManager: FileManager = .default
    ) throws -> ReadResult {
        let normalizedPath =
            relativePath.precomposedStringWithCanonicalMapping
        guard isSafeRelativePath(normalizedPath) else {
            throw DataInventoryFileAuditError
                .unsafeRelativePath(relativePath)
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
        } catch {
            throw DataInventoryFileAuditError.readFailed(relativePath)
        }
        guard values.isSymbolicLink != true else {
            throw DataInventoryFileAuditError.symbolicLink(relativePath)
        }
        guard values.isRegularFile == true else {
            throw DataInventoryFileAuditError.invalidFileType(relativePath)
        }
        if requiresSystemManagedProtection {
            try DataInventorySystemManagedProtectionAudit.validate(
                at: url,
                relativePath: relativePath
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw DataInventoryFileAuditError.readFailed(relativePath)
        }
        guard data.count <= Int(Int64.max) else {
            throw DataInventoryFileAuditError.readFailed(relativePath)
        }
        return ReadResult(
            snapshot: DataInventoryRegularFileSnapshot(
                relativePath: normalizedPath,
                byteCount: Int64(data.count),
                sha256Hex: SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
            ),
            data: data
        )
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("/") else {
            return false
        }
        return value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        .allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

enum DataInventoryGlobalFileIdentityAudit {
    static func validate(
        layout: AppDataStoreLayout,
        fileManager: FileManager = .default
    ) throws {
        var seenPaths = Set<String>()
        var seenInodes = Set<String>()
        var fileCount = 0
        let managedRoot = layout.rootURL.standardizedFileURL
        let rootValues = try resourceValues(
            for: managedRoot,
            fileManager: fileManager
        )
        guard rootValues.isSymbolicLink != true,
              rootValues.isDirectory == true else {
            throw DataInventoryFileAuditError.invalidFileType(
                managedRoot.path
            )
        }

        var enumerationError = false
        guard let enumerator = fileManager.enumerator(
            at: managedRoot,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: [],
            errorHandler: { _, _ in
                enumerationError = true
                return false
            }
        ) else {
            throw DataInventoryFileAuditError.readFailed(
                managedRoot.path
            )
        }
        while let candidate = enumerator.nextObject() as? URL {
            let values = try resourceValues(
                for: candidate,
                fileManager: fileManager
            )
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                throw DataInventoryFileAuditError.symbolicLink(
                    candidate.path
                )
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else {
                throw DataInventoryFileAuditError.invalidFileType(
                    candidate.path
                )
            }
            try register(
                candidate,
                fileCount: &fileCount,
                seenPaths: &seenPaths,
                seenInodes: &seenInodes,
                fileManager: fileManager
            )
        }
        guard !enumerationError else {
            throw DataInventoryFileAuditError.readFailed(
                managedRoot.path
            )
        }

        for candidate in [
            layout.legacyStoreURL,
            URL(fileURLWithPath: layout.legacyStoreURL.path + "-wal"),
            URL(fileURLWithPath: layout.legacyStoreURL.path + "-shm")
        ] where fileManager.fileExists(atPath: candidate.path) {
            let values = try resourceValues(
                for: candidate,
                fileManager: fileManager
            )
            guard values.isSymbolicLink != true else {
                throw DataInventoryFileAuditError.symbolicLink(
                    candidate.path
                )
            }
            guard values.isRegularFile == true else {
                throw DataInventoryFileAuditError.invalidFileType(
                    candidate.path
                )
            }
            try register(
                candidate,
                fileCount: &fileCount,
                seenPaths: &seenPaths,
                seenInodes: &seenInodes,
                fileManager: fileManager
            )
        }
    }

    private static func register(
        _ url: URL,
        fileCount: inout Int,
        seenPaths: inout Set<String>,
        seenInodes: inout Set<String>,
        fileManager: FileManager
    ) throws {
        let path = url.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
        guard seenPaths.insert(path).inserted else {
            throw DataInventoryFileAuditError
                .duplicatePathOrInode(path)
        }
        fileCount += 1
        guard fileCount
                <= DataInventoryTaxonomy.maximumRowsPerModel else {
            throw DataInventoryFileAuditError.readFailed(path)
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(
                atPath: url.path
            )
        } catch {
            throw DataInventoryFileAuditError.readFailed(path)
        }
        guard let device = attributes[.systemNumber],
              let inode = attributes[.systemFileNumber] else {
            throw DataInventoryFileAuditError.readFailed(path)
        }
        guard seenInodes.insert("\(device):\(inode)").inserted else {
            throw DataInventoryFileAuditError
                .duplicatePathOrInode(path)
        }
    }

    private static func resourceValues(
        for url: URL,
        fileManager: FileManager
    ) throws -> URLResourceValues {
        do {
            return try url.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
        } catch {
            throw DataInventoryFileAuditError.readFailed(url.path)
        }
    }
}

private enum DataInventorySystemManagedProtectionAudit {
    static func validate(
        at url: URL,
        relativePath: String
    ) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [
                    .isExcludedFromBackupKey,
                    .fileProtectionKey
                ]
            )
        } catch {
            throw DataInventoryFileAuditError.readFailed(relativePath)
        }
        guard values.isExcludedFromBackup == false else {
            throw DataInventoryFileAuditError.readFailed(relativePath)
        }
#if !targetEnvironment(simulator)
        guard values.fileProtection == .complete else {
            throw DataInventoryFileAuditError.readFailed(relativePath)
        }
#endif
    }
}

struct DataInventoryActiveGenerationAuditReport: Equatable, Sendable {
    let generationID: UUID
    let auditedPathCount: Int64
    let requiresPhysicalDeviceValidation: Bool
    let backupPolicy: SystemBackupPolicy
}

struct DataInventoryValidatedActiveGenerationLayout: Sendable {
    fileprivate let generationID: UUID
    fileprivate let generationURL: URL
    let report: DataInventoryActiveGenerationAuditReport

    fileprivate init(
        generationID: UUID,
        generationURL: URL,
        report: DataInventoryActiveGenerationAuditReport
    ) {
        self.generationID = generationID
        self.generationURL = generationURL
        self.report = report
    }
}

struct DataInventoryValidatedControlSnapshot: Sendable {
    let pointer: GenerationPointer
    let migrationJournal: MigrationJournal?
    let portableRestoreJournal: PortableRestoreJournal?
    let categorySnapshot: DataInventoryCategorySnapshot

    fileprivate init(
        pointer: GenerationPointer,
        migrationJournal: MigrationJournal?,
        portableRestoreJournal: PortableRestoreJournal?,
        files: [DataInventoryRegularFileSnapshot]
    ) {
        self.pointer = pointer
        self.migrationJournal = migrationJournal
        self.portableRestoreJournal =
            portableRestoreJournal
        self.categorySnapshot = DataInventoryCategorySnapshot(
            key: "storage.control",
            kind: .control,
            payload: .regularFiles(files)
        )
    }
}

enum DataInventoryActiveGenerationLayoutAudit {
    static func validate(
        applicationSupportURL: URL,
        generationID: UUID,
        fileManager: FileManager = .default
    ) throws -> DataInventoryValidatedActiveGenerationLayout {
        let generationName = generationID.uuidString.lowercased()
        let generationURL = applicationSupportURL
            .appending(path: "Unmanual", directoryHint: .isDirectory)
            .appending(path: "Generations", directoryHint: .isDirectory)
            .appending(path: generationName, directoryHint: .isDirectory)
        let storeURL = generationURL.appending(
            path: "Store",
            directoryHint: .isDirectory
        )
        let filesURL = generationURL.appending(
            path: "Files",
            directoryHint: .isDirectory
        )

        try requireDirectory(
            generationURL,
            relativePath: "Unmanual/Generations/\(generationName)",
            fileManager: fileManager
        )
        try requireExactChildren(
            of: generationURL,
            allowed: ["Store", "Files"],
            required: ["Store", "Files"],
            relativeRoot: "Unmanual/Generations/\(generationName)",
            fileManager: fileManager
        )
        try requireDirectory(
            storeURL,
            relativePath:
                "Unmanual/Generations/\(generationName)/Store",
            fileManager: fileManager
        )
        try requireExactChildren(
            of: storeURL,
            allowed: [
                "user.sqlite",
                "user.sqlite-wal",
                "user.sqlite-shm"
            ],
            required: ["user.sqlite"],
            relativeRoot:
                "Unmanual/Generations/\(generationName)/Store",
            fileManager: fileManager
        )
        for fileName in [
            "user.sqlite",
            "user.sqlite-wal",
            "user.sqlite-shm"
        ] {
            let url = storeURL.appending(path: fileName)
            if fileManager.fileExists(atPath: url.path) {
                try requireRegularFile(
                    url,
                    relativePath:
                        "Unmanual/Generations/\(generationName)"
                        + "/Store/\(fileName)",
                    fileManager: fileManager
                )
            }
        }
        try requireDirectory(
            filesURL,
            relativePath:
                "Unmanual/Generations/\(generationName)/Files",
            fileManager: fileManager
        )
        try requireExactChildren(
            of: filesURL,
            allowed: [
                "Attachments",
                ".staging",
                ".trash"
            ],
            required: [
                "Attachments",
                ".staging",
                ".trash"
            ],
            relativeRoot:
                "Unmanual/Generations/\(generationName)/Files",
            fileManager: fileManager
        )
        for directoryName in [
            "Attachments",
            ".staging",
            ".trash"
        ] {
            try requireDirectory(
                filesURL.appending(
                    path: directoryName,
                    directoryHint: .isDirectory
                ),
                relativePath:
                    "Unmanual/Generations/\(generationName)"
                    + "/Files/\(directoryName)",
                fileManager: fileManager
            )
        }
        try validateAttachmentTreeShape(
            filesURL: filesURL,
            generationName: generationName,
            fileManager: fileManager
        )

        let nodes = try allNodes(
            root: generationURL,
            fileManager: fileManager
        )
        for node in nodes {
            try DataInventorySystemManagedProtectionAudit.validate(
                at: node,
                relativePath: try relativePath(
                    from: applicationSupportURL,
                    to: node
                )
            )
        }
#if targetEnvironment(simulator)
        let requiresPhysicalDeviceValidation = true
#else
        let requiresPhysicalDeviceValidation = false
#endif
        return DataInventoryValidatedActiveGenerationLayout(
            generationID: generationID,
            generationURL: generationURL.standardizedFileURL,
            report: DataInventoryActiveGenerationAuditReport(
                generationID: generationID,
                auditedPathCount: Int64(nodes.count),
                requiresPhysicalDeviceValidation:
                    requiresPhysicalDeviceValidation,
                backupPolicy: .systemManaged
            )
        )
    }

    private static func validateAttachmentTreeShape(
        filesURL: URL,
        generationName: String,
        fileManager: FileManager
    ) throws {
        struct AttachmentJournal: Decodable {
            let operationID: UUID
            let attachmentID: UUID
            let relativePath: String
            let typeIdentifier: String
            let action: String
            let phase: String

            var isValid: Bool {
                let validPhase =
                    (action == "importFile"
                        && ["staged", "finalReady"].contains(phase))
                    || (action == "deleteFile"
                        && [
                            "deletionPrepared",
                            "deletionStaged"
                        ].contains(phase))
                return validPhase
                    && AttachmentPathFacts.isOpaquePath(
                        relativePath,
                        attachmentID: attachmentID,
                        typeIdentifier: typeIdentifier
                    )
            }
        }

        let filesRoot =
            "Unmanual/Generations/\(generationName)/Files"
        let attachmentsURL = filesURL.appending(
            path: "Attachments",
            directoryHint: .isDirectory
        )
        for attachmentDirectory in try contents(
            of: attachmentsURL,
            relativeRoot: filesRoot + "/Attachments",
            fileManager: fileManager
        ) {
            let name = attachmentDirectory.lastPathComponent
            let path = filesRoot + "/Attachments/" + name
            guard let attachmentID = UUID(uuidString: name),
                  name == attachmentID.uuidString.lowercased() else {
                throw DataInventoryFileAuditError.unknownManagedLeaf(path)
            }
            try requireDirectory(
                attachmentDirectory,
                relativePath: path,
                fileManager: fileManager
            )
            let payloads = try contents(
                of: attachmentDirectory,
                relativeRoot: path,
                fileManager: fileManager
            )
            guard payloads.count == 1,
                  let payload = payloads.first,
                  payload.lastPathComponent.hasPrefix("payload."),
                  payload.lastPathComponent.count > "payload.".count else {
                throw DataInventoryFileAuditError.unknownManagedLeaf(path)
            }
            try requireRegularFile(
                payload,
                relativePath: path + "/" + payload.lastPathComponent,
                fileManager: fileManager
            )
        }

        let stagingURL = filesURL.appending(
            path: ".staging",
            directoryHint: .isDirectory
        )
        let stagingEntries = try contents(
            of: stagingURL,
            relativeRoot: filesRoot + "/.staging",
            fileManager: fileManager
        )
        var journalsByOperationID: [UUID: AttachmentJournal] = [:]
        for entry in stagingEntries where entry.pathExtension == "json" {
            let name = entry.lastPathComponent
            let path = filesRoot + "/.staging/" + name
            let values = try entry.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            guard values.isSymbolicLink != true else {
                throw DataInventoryFileAuditError.symbolicLink(path)
            }
            guard values.isRegularFile == true,
                  name.hasSuffix(".json"),
                  let operationID = UUID(
                    uuidString: String(name.dropLast(5))
                  ),
                  name == operationID.uuidString.lowercased() + ".json" else {
                throw DataInventoryFileAuditError
                    .unknownManagedLeaf(path)
            }
            let read = try DataInventoryRegularFileAudit.read(
                at: entry,
                relativePath: path,
                requiresSystemManagedProtection: true,
                fileManager: fileManager
            )
            guard let journal = try? JSONDecoder().decode(
                AttachmentJournal.self,
                from: read.data
            ),
            journal.operationID == operationID,
            journal.isValid,
            journalsByOperationID.updateValue(
                journal,
                forKey: operationID
            ) == nil else {
                throw DataInventoryFileAuditError.readFailed(path)
            }
        }
        for entry in stagingEntries where entry.pathExtension.isEmpty {
            let name = entry.lastPathComponent
            let path = filesRoot + "/.staging/" + name
            let values = try entry.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            guard values.isSymbolicLink != true else {
                throw DataInventoryFileAuditError.symbolicLink(path)
            }
            guard values.isDirectory == true,
                  let operationID = UUID(uuidString: name),
                  name == operationID.uuidString.lowercased(),
                  journalsByOperationID[operationID] != nil else {
                throw DataInventoryFileAuditError
                    .unknownManagedLeaf(path)
            }
            let children = try contents(
                of: entry,
                relativeRoot: path,
                fileManager: fileManager
            )
            guard children.isEmpty
                    || (children.count == 1
                        && children[0].lastPathComponent == "payload") else {
                throw DataInventoryFileAuditError.unknownManagedLeaf(path)
            }
            if let payload = children.first {
                try requireRegularFile(
                    payload,
                    relativePath: path + "/payload",
                    fileManager: fileManager
                )
            }
        }
        guard stagingEntries.allSatisfy({
            $0.pathExtension == "json" || $0.pathExtension.isEmpty
        }) else {
            throw DataInventoryFileAuditError.unknownManagedLeaf(
                filesRoot + "/.staging"
            )
        }
        for journal in journalsByOperationID.values
        where journal.action == "importFile" {
            let operationDirectory = stagingURL.appending(
                path: journal.operationID.uuidString.lowercased(),
                directoryHint: .isDirectory
            )
            guard fileManager.fileExists(atPath: operationDirectory.path)
                    || journal.phase == "finalReady" else {
                throw DataInventoryFileAuditError.invalidFileType(
                    filesRoot + "/.staging/"
                        + journal.operationID.uuidString.lowercased()
                )
            }
        }

        let trashURL = filesURL.appending(
            path: ".trash",
            directoryHint: .isDirectory
        )
        for operationDirectory in try contents(
            of: trashURL,
            relativeRoot: filesRoot + "/.trash",
            fileManager: fileManager
        ) {
            let name = operationDirectory.lastPathComponent
            let path = filesRoot + "/.trash/" + name
            guard let operationID = UUID(uuidString: name),
                  name == operationID.uuidString.lowercased() else {
                throw DataInventoryFileAuditError.unknownManagedLeaf(path)
            }
            try requireDirectory(
                operationDirectory,
                relativePath: path,
                fileManager: fileManager
            )
            guard let journal = journalsByOperationID[operationID],
                  journal.action == "deleteFile" else {
                throw DataInventoryFileAuditError
                    .unknownManagedLeaf(path)
            }
            try requireExactChildren(
                of: operationDirectory,
                allowed: ["payload"],
                required: ["payload"],
                relativeRoot: path,
                fileManager: fileManager
            )
            try requireRegularFile(
                operationDirectory.appending(path: "payload"),
                relativePath: path + "/payload",
                fileManager: fileManager
            )
        }
    }

    private static func allNodes(
        root: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        var result = [root]
        var enumerationFailed = false
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileProtectionKey,
                .isExcludedFromBackupKey
            ],
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else {
            throw DataInventoryFileAuditError.readFailed(
                root.lastPathComponent
            )
        }
        while let node = enumerator.nextObject() as? URL {
            let values = try node.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            guard values.isSymbolicLink != true else {
                throw DataInventoryFileAuditError
                    .symbolicLink(node.path)
            }
            guard values.isDirectory == true
                    || values.isRegularFile == true else {
                throw DataInventoryFileAuditError
                    .invalidFileType(node.path)
            }
            result.append(node)
        }
        guard !enumerationFailed else {
            throw DataInventoryFileAuditError.readFailed(
                root.lastPathComponent
            )
        }
        return result
    }

    private static func requireDirectory(
        _ url: URL,
        relativePath: String,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw DataInventoryFileAuditError
                .missingRequiredPath(relativePath)
        }
        let values = try url.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ]
        )
        guard values.isSymbolicLink != true else {
            throw DataInventoryFileAuditError.symbolicLink(relativePath)
        }
        guard values.isDirectory == true else {
            throw DataInventoryFileAuditError.invalidFileType(relativePath)
        }
    }

    private static func requireRegularFile(
        _ url: URL,
        relativePath: String,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw DataInventoryFileAuditError
                .missingRequiredPath(relativePath)
        }
        let values = try url.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard values.isSymbolicLink != true else {
            throw DataInventoryFileAuditError.symbolicLink(relativePath)
        }
        guard values.isRegularFile == true else {
            throw DataInventoryFileAuditError.invalidFileType(relativePath)
        }
    }

    private static func requireExactChildren(
        of directoryURL: URL,
        allowed: Set<String>,
        required: Set<String>,
        relativeRoot: String,
        fileManager: FileManager
    ) throws {
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ],
                options: []
            )
        } catch {
            throw DataInventoryFileAuditError.readFailed(relativeRoot)
        }
        for child in children {
            let path = relativeRoot + "/" + child.lastPathComponent
            guard allowed.contains(child.lastPathComponent) else {
                throw DataInventoryFileAuditError
                    .unknownManagedLeaf(path)
            }
            let values = try child.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            guard values.isSymbolicLink != true else {
                throw DataInventoryFileAuditError.symbolicLink(path)
            }
        }
        let names = Set(children.map(\.lastPathComponent))
        if let missing = required.subtracting(names).sorted().first {
            throw DataInventoryFileAuditError
                .missingRequiredPath(relativeRoot + "/" + missing)
        }
    }

    private static func contents(
        of directoryURL: URL,
        relativeRoot: String,
        fileManager: FileManager
    ) throws -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ],
                options: []
            )
        } catch {
            throw DataInventoryFileAuditError.readFailed(relativeRoot)
        }
    }

    private static func relativePath(
        from root: URL,
        to child: URL
    ) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/")
            ? rootPath
            : rootPath + "/"
        guard childPath.hasPrefix(prefix) else {
            throw DataInventoryFileAuditError
                .unsafeRelativePath(childPath)
        }
        return String(childPath.dropFirst(prefix.count))
            .precomposedStringWithCanonicalMapping
    }
}

enum DataInventoryManagedRootAudit {
    static func validateReadyStructure(
        applicationSupportURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let unmanualURL = applicationSupportURL.appending(
            path: "Unmanual",
            directoryHint: .isDirectory
        )
        let generationsURL = unmanualURL.appending(
            path: "Generations",
            directoryHint: .isDirectory
        )
        let pointerDirectoryURL = unmanualURL.appending(
            path: "GenerationPointer",
            directoryHint: .isDirectory
        )
        let recoveryURL = unmanualURL.appending(
            path: "Recovery",
            directoryHint: .isDirectory
        )
        try requireDirectory(
            unmanualURL,
            relativePath: "Unmanual",
            fileManager: fileManager
        )
        try requireDirectory(
            generationsURL,
            relativePath: "Unmanual/Generations",
            fileManager: fileManager
        )
        try requireDirectory(
            pointerDirectoryURL,
            relativePath: "Unmanual/GenerationPointer",
            fileManager: fileManager
        )
        try requireDirectory(
            recoveryURL,
            relativePath: "Unmanual/Recovery",
            fileManager: fileManager
        )
        try requireExactChildren(
            of: unmanualURL,
            allowed: [
                "Generations",
                "GenerationPointer",
                "Recovery"
            ],
            relativeRoot: "Unmanual",
            fileManager: fileManager
        )
        let reconciliationLayout = AppDataStoreLayout(
            rootURL: unmanualURL,
            legacyStoreURL:
                applicationSupportURL.appending(
                    path:
                        "AtomicControlAudit-Legacy.sqlite"
                )
        )
        do {
            _ = try GenerationPointerStore(
                layout: reconciliationLayout
            ).read()
            _ = try MigrationJournalStore(
                layout: reconciliationLayout
            ).readIfPresent()
            _ = try PortableRestoreJournalStore(
                layout: reconciliationLayout
            ).readIfPresent()
            _ = try PortablePackageCleanupJournalStore(
                layout: reconciliationLayout
            ).readIfPresent()
        } catch {
            throw DataInventoryFileAuditError
                .readFailed(
                    "Unmanual control-file transaction"
                )
        }

        try requireExactChildren(
            of: pointerDirectoryURL,
            allowed: ["active.json"],
            relativeRoot: "Unmanual/GenerationPointer",
            fileManager: fileManager
        )
        try requireExactChildren(
            of: recoveryURL,
            allowed: [
                "migration-journal.json",
                "portable-restore-journal.json",
                "portable-package-cleanup-v1.json"
            ],
            allowMissing: true,
            relativeRoot: "Unmanual/Recovery",
            fileManager: fileManager
        )

        let pointerURL = pointerDirectoryURL.appending(path: "active.json")
        guard fileManager.fileExists(atPath: pointerURL.path) else {
            throw DataInventoryFileAuditError.missingRequiredPath(
                "Unmanual/GenerationPointer/active.json"
            )
        }
        let migrationJournalURL = recoveryURL.appending(
            path: "migration-journal.json"
        )
        if fileManager.fileExists(atPath: migrationJournalURL.path) {
            _ = try DataInventoryRegularFileAudit.snapshot(
                at: migrationJournalURL,
                relativePath: "Unmanual/Recovery/migration-journal.json",
                fileManager: fileManager
            )
        }
        let portableRestoreJournalURL = recoveryURL
            .appending(
                path: "portable-restore-journal.json"
            )
        if fileManager.fileExists(
            atPath: portableRestoreJournalURL.path
        ) {
            _ = try DataInventoryRegularFileAudit.snapshot(
                at: portableRestoreJournalURL,
                relativePath:
                    "Unmanual/Recovery/portable-restore-journal.json",
                fileManager: fileManager
            )
        }
        let portableCleanupJournalURL =
            recoveryURL.appending(
                path:
                    "portable-package-cleanup-v1.json"
            )
        if fileManager.fileExists(
            atPath: portableCleanupJournalURL.path
        ) {
            _ = try DataInventoryRegularFileAudit.snapshot(
                at: portableCleanupJournalURL,
                relativePath:
                    "Unmanual/Recovery/portable-package-cleanup-v1.json",
                fileManager: fileManager
            )
            do {
                _ = try PortablePackageCleanupJournalStore(
                    layout: AppDataStoreLayout(
                        rootURL: unmanualURL,
                        legacyStoreURL:
                            applicationSupportURL
                            .appending(
                                path:
                                    "PortableCleanupAudit-Legacy.sqlite"
                            )
                    )
                ).readIfPresent()
            } catch {
                throw DataInventoryFileAuditError
                    .readFailed(
                        "Unmanual/Recovery/portable-package-cleanup-v1.json"
                    )
            }
        }

        let applicationSupportChildren = try contents(
            of: applicationSupportURL,
            relativeRoot: "",
            fileManager: fileManager
        )
        if let resetControlURL = applicationSupportChildren.first(
            where: { $0.lastPathComponent == "UnmanualResetControl" }
        ) {
            try requireDirectory(
                resetControlURL,
                relativePath: "UnmanualResetControl",
                fileManager: fileManager
            )
            try requireExactChildren(
                of: resetControlURL,
                allowed: [],
                relativeRoot: "UnmanualResetControl",
                fileManager: fileManager
            )
        }

        if let quarantine = applicationSupportChildren.first(where: {
            $0.lastPathComponent.hasPrefix("Unmanual.reset-")
        }) {
            throw DataInventoryFileAuditError.unknownManagedLeaf(
                quarantine.lastPathComponent
            )
        }
    }

    static func validatedReadyControlSnapshot(
        applicationSupportURL: URL,
        expectedGenerationID: UUID,
        expectedDatasetID: UUID,
        expectedSchemaVersion: String,
        expectedMinimumFactCount: Int,
        expectedMinimumRevisionCount: Int,
        activeGenerationLayout:
            DataInventoryValidatedActiveGenerationLayout,
        fileManager: FileManager = .default
    ) throws -> DataInventoryValidatedControlSnapshot {
        try validateReadyStructure(
            applicationSupportURL: applicationSupportURL,
            fileManager: fileManager
        )
        let expectedGenerationURL = applicationSupportURL
            .appending(path: "Unmanual", directoryHint: .isDirectory)
            .appending(path: "Generations", directoryHint: .isDirectory)
            .appending(
                path: expectedGenerationID.uuidString.lowercased(),
                directoryHint: .isDirectory
            )
            .standardizedFileURL
        guard activeGenerationLayout.generationID
                == expectedGenerationID,
              activeGenerationLayout.generationURL
                == expectedGenerationURL,
              activeGenerationLayout.report.backupPolicy
                == .systemManaged else {
            throw DataInventoryFileAuditError
                .readFailed("active-generation-proof")
        }

        let pointerRead = try DataInventoryRegularFileAudit.read(
            at: applicationSupportURL
                .appending(path: "Unmanual")
                .appending(path: "GenerationPointer")
                .appending(path: "active.json"),
            relativePath: "Unmanual/GenerationPointer/active.json",
            requiresSystemManagedProtection: true,
            fileManager: fileManager
        )
        let pointer: GenerationPointer
        do {
            pointer = try controlDecoder.decode(
                GenerationPointer.self,
                from: pointerRead.data
            )
        } catch {
            throw DataInventoryFileAuditError
                .readFailed("Unmanual/GenerationPointer/active.json")
        }
        guard pointer.formatVersion == GenerationPointer.formatVersion,
              pointer.generationID == expectedGenerationID,
              pointer.datasetID == expectedDatasetID,
              pointer.schemaVersion == expectedSchemaVersion,
              expectedMinimumFactCount >= pointer.minimumFactCount,
              expectedMinimumRevisionCount
                >= pointer.minimumRevisionCount,
              expectedMinimumFactCount == expectedMinimumRevisionCount,
              pointer.minimumFactCount >= 0,
              pointer.minimumFactCount
                == pointer.minimumRevisionCount,
              pointer.activatedAt.timeIntervalSince1970.isFinite else {
            throw DataInventoryFileAuditError
                .readFailed("Unmanual/GenerationPointer/active.json")
        }

        var files = [pointerRead.snapshot]
        let layout = AppDataStoreLayout(
            rootURL: applicationSupportURL.appending(
                path: "Unmanual",
                directoryHint: .isDirectory
            ),
            legacyStoreURL:
                applicationSupportURL.appending(
                    path:
                        "PortableRestoreAudit-Legacy.sqlite"
                )
        )
        let portableJournalURL =
            layout.portableRestoreJournalURL
        let portableJournal:
            PortableRestoreJournal?
        if fileManager.fileExists(
            atPath: portableJournalURL.path
        ) {
            let read = try DataInventoryRegularFileAudit.read(
                at: portableJournalURL,
                relativePath:
                    "Unmanual/Recovery/portable-restore-journal.json",
                requiresSystemManagedProtection: true,
                fileManager: fileManager
            )
            let decoded: PortableRestoreJournal
            do {
                decoded = try PortableRestoreJournalStore(
                    layout: layout
                ).read()
            } catch {
                throw DataInventoryFileAuditError.readFailed(
                    "Unmanual/Recovery/portable-restore-journal.json"
                )
            }
            guard decoded.phase == .activated,
                  decoded.targetGenerationID
                    == pointer.generationID,
                  decoded.targetDatasetID
                    == pointer.datasetID,
                  decoded.factCount
                    == decoded.revisionCount,
                  decoded.factCount
                    <= expectedMinimumFactCount,
                  journalGenerationExists(
                    decoded.sourceGenerationID,
                    applicationSupportURL:
                        applicationSupportURL,
                    fileManager: fileManager
                  ) else {
                throw DataInventoryFileAuditError.readFailed(
                    "Unmanual/Recovery/portable-restore-journal.json"
                )
            }
            files.append(read.snapshot)
            portableJournal = decoded
        } else {
            portableJournal = nil
        }
        let cleanupJournalURL =
            layout.portablePackageCleanupJournalURL
        if fileManager.fileExists(
            atPath: cleanupJournalURL.path
        ) {
            let read = try DataInventoryRegularFileAudit.read(
                at: cleanupJournalURL,
                relativePath:
                    "Unmanual/Recovery/portable-package-cleanup-v1.json",
                fileManager: fileManager
            )
            do {
                _ = try
                    PortablePackageCleanupJournalStore(
                        layout: layout
                    ).readIfPresent()
            } catch {
                throw DataInventoryFileAuditError
                    .readFailed(
                        "Unmanual/Recovery/portable-package-cleanup-v1.json"
                    )
            }
            files.append(read.snapshot)
        }
        let journalURL = applicationSupportURL
            .appending(path: "Unmanual")
            .appending(path: "Recovery")
            .appending(path: "migration-journal.json")
        let journal: MigrationJournal?
        if fileManager.fileExists(atPath: journalURL.path) {
            let journalRead = try DataInventoryRegularFileAudit.read(
                at: journalURL,
                relativePath: "Unmanual/Recovery/migration-journal.json",
                requiresSystemManagedProtection: true,
                fileManager: fileManager
            )
            let decoded: MigrationJournal
            do {
                decoded = try controlDecoder.decode(
                    MigrationJournal.self,
                    from: journalRead.data
                )
            } catch {
                throw DataInventoryFileAuditError
                    .readFailed(
                        "Unmanual/Recovery/migration-journal.json"
                    )
            }
            let provesCurrentPointer =
                decoded.targetGenerationID
                    == pointer.generationID
                    && decoded.origin == pointer.origin
            let provesPortableSource =
                portableJournal.map {
                    decoded.targetGenerationID
                        == $0.sourceGenerationID
                } == true
            guard decoded.formatVersion
                    == MigrationJournal.formatVersion,
                  decoded.origin != .existingGeneration,
                  decoded.phase == .activated,
                  provesCurrentPointer
                    || provesPortableSource,
                  decoded.sourceGenerationID
                    != decoded.targetGenerationID,
                  decoded.updatedAt.timeIntervalSince1970.isFinite,
                  validSchemaTransition(
                    decoded,
                    pointerSchemaVersion: pointer.schemaVersion
                  ),
                  journalSourceExists(
                    decoded,
                    applicationSupportURL: applicationSupportURL,
                    fileManager: fileManager
                  ) else {
                throw DataInventoryFileAuditError
                    .readFailed(
                        "Unmanual/Recovery/migration-journal.json"
                    )
            }
            files.append(journalRead.snapshot)
            journal = decoded
        } else {
            journal = nil
        }
        return DataInventoryValidatedControlSnapshot(
            pointer: pointer,
            migrationJournal: journal,
            portableRestoreJournal: portableJournal,
            files: files.sorted {
            $0.relativePath.utf8.lexicographicallyPrecedes(
                $1.relativePath.utf8
            )
            }
        )
    }

    private static func journalGenerationExists(
        _ generationID: UUID,
        applicationSupportURL: URL,
        fileManager: FileManager
    ) -> Bool {
        let url = applicationSupportURL
            .appending(path: "Unmanual")
            .appending(path: "Generations")
            .appending(
                path: generationID.uuidString.lowercased()
            )
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isDirectory == true
            && values.isSymbolicLink != true
    }

    private static func validSchemaTransition(
        _ journal: MigrationJournal,
        pointerSchemaVersion: String
    ) -> Bool {
        guard journal.origin == .schemaUpgrade else {
            return journal.sourceGenerationID == nil
                && journal.sourceSchemaVersion == nil
                && journal.targetSchemaVersion == nil
        }
        guard journal.sourceGenerationID != nil,
              let source = journal.sourceSchemaVersion,
              let target = journal.targetSchemaVersion,
              target == pointerSchemaVersion else {
            return false
        }
        let supported = [
            "2.0.0": Set(["3.0.0"]),
            "3.0.0": Set(["4.0.0"]),
            "4.0.0": Set(["5.0.0"]),
            "5.0.0": Set(["6.0.0", "7.0.0"]),
            "6.0.0": Set(["7.0.0", "8.0.0"]),
            "7.0.0": Set(["8.0.0"]),
            "8.0.0": Set(["9.0.0"]),
            "9.0.0": Set(["10.0.0"]),
            "10.0.0": Set(["11.0.0"]),
            "11.0.0": Set(["12.0.0"])
        ]
        return supported[source]?.contains(target) == true
    }

    private static func journalSourceExists(
        _ journal: MigrationJournal,
        applicationSupportURL: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let sourceID = journal.sourceGenerationID else {
            return journal.origin != .schemaUpgrade
        }
        let sourceName = sourceID.uuidString.lowercased()
        let generationsURL = applicationSupportURL
            .appending(path: "Unmanual", directoryHint: .isDirectory)
            .appending(path: "Generations", directoryHint: .isDirectory)
        guard let children = try? contents(
            of: generationsURL,
            relativeRoot: "Unmanual/Generations",
            fileManager: fileManager
        ),
        let source = children.first(
            where: { $0.lastPathComponent == sourceName }
        ),
        let values = try? source.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isSymbolicLink != true
            && values.isDirectory == true
    }

    private static var controlDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func requireDirectory(
        _ url: URL,
        relativePath: String,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw DataInventoryFileAuditError
                .missingRequiredPath(relativePath)
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ]
            )
        } catch {
            throw DataInventoryFileAuditError.readFailed(relativePath)
        }
        guard values.isSymbolicLink != true else {
            throw DataInventoryFileAuditError.symbolicLink(relativePath)
        }
        guard values.isDirectory == true else {
            throw DataInventoryFileAuditError.invalidFileType(relativePath)
        }
    }

    private static func requireExactChildren(
        of directoryURL: URL,
        allowed: Set<String>,
        allowMissing: Bool = false,
        relativeRoot: String,
        fileManager: FileManager
    ) throws {
        let children = try contents(
            of: directoryURL,
            relativeRoot: relativeRoot,
            fileManager: fileManager
        )
        for child in children {
            let relativePath = [relativeRoot, child.lastPathComponent]
                .filter { !$0.isEmpty }
                .joined(separator: "/")
            guard allowed.contains(child.lastPathComponent) else {
                throw DataInventoryFileAuditError
                    .unknownManagedLeaf(relativePath)
            }
            let values = try child.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw DataInventoryFileAuditError
                    .symbolicLink(relativePath)
            }
        }
        if !allowMissing {
            for required in allowed where !children.contains(where: {
                $0.lastPathComponent == required
            }) {
                let relativePath = [relativeRoot, required]
                    .filter { !$0.isEmpty }
                    .joined(separator: "/")
                throw DataInventoryFileAuditError
                    .missingRequiredPath(relativePath)
            }
        }
    }

    private static func contents(
        of directoryURL: URL,
        relativeRoot: String,
        fileManager: FileManager
    ) throws -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ],
                options: []
            )
        } catch {
            throw DataInventoryFileAuditError.readFailed(relativeRoot)
        }
    }
}

enum DataInventoryGenerationTreeAudit {
    static func regularFiles(
        at generationURL: URL,
        scope: DataInventoryGenerationTreeScope,
        fileManager: FileManager = .default
    ) throws -> [DataInventoryRegularFileSnapshot] {
        var inodeKeys = Set<String>()
        return try regularFiles(
            at: generationURL,
            scope: scope,
            knownInodeKeys: &inodeKeys,
            fileManager: fileManager
        )
    }

    static func regularFiles(
        at generationURL: URL,
        scope: DataInventoryGenerationTreeScope,
        knownInodeKeys: inout Set<String>,
        fileManager: FileManager = .default
    ) throws -> [DataInventoryRegularFileSnapshot] {
        let rootValues: URLResourceValues
        do {
            rootValues = try generationURL.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ]
            )
        } catch {
            throw DataInventoryFileAuditError
                .readFailed(generationURL.lastPathComponent)
        }
        guard rootValues.isSymbolicLink != true else {
            throw DataInventoryFileAuditError
                .symbolicLink(generationURL.lastPathComponent)
        }
        guard rootValues.isDirectory == true else {
            throw DataInventoryFileAuditError
                .invalidFileType(generationURL.lastPathComponent)
        }

        var enumerationError = false
        guard let enumerator = fileManager.enumerator(
            at: generationURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: [],
            errorHandler: { _, _ in
                enumerationError = true
                return false
            }
        ) else {
            throw DataInventoryFileAuditError
                .readFailed(generationURL.lastPathComponent)
        }

        var files: [DataInventoryRegularFileSnapshot] = []
        var paths: Set<String> = []
        while let candidate = enumerator.nextObject() as? URL {
            let relativePath = try relativePath(
                from: generationURL,
                to: candidate
            )
            let values: URLResourceValues
            do {
                values = try candidate.resourceValues(
                    forKeys: [
                        .isDirectoryKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey
                    ]
                )
            } catch {
                throw DataInventoryFileAuditError.readFailed(relativePath)
            }
            guard values.isSymbolicLink != true else {
                throw DataInventoryFileAuditError.symbolicLink(relativePath)
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else {
                throw DataInventoryFileAuditError.invalidFileType(relativePath)
            }
            let normalizedPath =
                relativePath.precomposedStringWithCanonicalMapping
            guard paths.insert(normalizedPath).inserted else {
                throw DataInventoryFileAuditError
                    .duplicatePathOrInode(normalizedPath)
            }
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(
                    atPath: candidate.path
                )
            } catch {
                throw DataInventoryFileAuditError.readFailed(normalizedPath)
            }
            if let device = attributes[.systemNumber],
               let inode = attributes[.systemFileNumber] {
                let inodeKey = "\(device):\(inode)"
                guard knownInodeKeys.insert(inodeKey).inserted else {
                    throw DataInventoryFileAuditError
                        .duplicatePathOrInode(normalizedPath)
                }
            }
            if scope == .activeLogicalOverlay,
               isExcludedFromActiveDigest(normalizedPath) {
                continue
            }
            files.append(
                try DataInventoryRegularFileAudit.snapshot(
                    at: candidate,
                    relativePath: normalizedPath,
                    fileManager: fileManager
                )
            )
        }
        guard !enumerationError else {
            throw DataInventoryFileAuditError
                .readFailed(generationURL.lastPathComponent)
        }
        return files.sorted {
            $0.relativePath.utf8.lexicographicallyPrecedes(
                $1.relativePath.utf8
            )
        }
    }

    static func isExcludedFromActiveDigest(_ relativePath: String) -> Bool {
        relativePath == "Store/user.sqlite"
            || relativePath == "Store/user.sqlite-wal"
            || relativePath == "Store/user.sqlite-shm"
            || relativePath.hasPrefix("Files/")
    }

    private static func relativePath(
        from rootURL: URL,
        to childURL: URL
    ) throws -> String {
        let root = rootURL.standardizedFileURL.path
        let child = childURL.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard child.hasPrefix(prefix) else {
            throw DataInventoryFileAuditError.unsafeRelativePath(child)
        }
        let relative = String(child.dropFirst(prefix.count))
        guard !relative.isEmpty,
              !relative.hasPrefix("/"),
              relative.split(
                  separator: "/",
                  omittingEmptySubsequences: false
              )
              .allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            throw DataInventoryFileAuditError.unsafeRelativePath(relative)
        }
        return relative
    }
}

struct DataInventoryNotificationRequestObservation: Equatable, Sendable {
    let identifier: String
    let deliveryState: DataInventoryNotificationDeliveryState
}

protocol DataInventoryNotificationSnapshotProvider: Sendable {
    func notificationRequests()
        async throws -> [DataInventoryNotificationRequestObservation]
}

enum DataInventoryNotificationSnapshotFactory {
    static func categories(
        observations: [DataInventoryNotificationRequestObservation]
    ) -> [DataInventoryCategorySnapshot] {
        var requests: [DataInventoryNotificationSnapshot] = []
        for observation in observations {
            let namespace: DataInventoryNotificationNamespace?
            if observation.identifier.hasPrefix(
                DataInventoryNotificationNamespace.execution.identifierPrefix
            ) {
                namespace = .execution
            } else if observation.identifier.hasPrefix(
                DataInventoryNotificationNamespace.countdown.identifierPrefix
            ) {
                namespace = .countdown
            } else {
                namespace = nil
            }
            if let namespace {
                requests.append(
                    DataInventoryNotificationSnapshot(
                        namespace: namespace,
                        deliveryState: observation.deliveryState,
                        identifier: observation.identifier
                    )
                )
            }
        }
        return DataInventoryTaxonomy.categorySpecifications
            .filter { $0.kind == .notification }
            .map { specification in
                DataInventoryCategorySnapshot(
                    key: specification.key,
                    kind: .notification,
                    payload: .notifications(
                        requests.filter {
                            $0.categoryKey == specification.key
                        }
                    )
                )
            }
    }
}
