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
    case sanitized
}

struct PortableArtifactIdentity:
    Codable, Equatable, Sendable {
    let deviceID: UInt64
    let inode: UInt64
    let fileType: UInt32

    init(_ value: stat) {
        deviceID = UInt64(truncatingIfNeeded: value.st_dev)
        inode = UInt64(truncatingIfNeeded: value.st_ino)
        fileType = UInt32(value.st_mode & S_IFMT)
    }

    func matches(_ value: stat) -> Bool {
        self == PortableArtifactIdentity(value)
    }
}

/// Keeps a managed package directory anchored to the exact directory
/// descriptors that created it. All package writes must use
/// `packageDescriptor`; the canonical path is only a publication name.
final class PortablePackageDirectoryLease: @unchecked Sendable {
    struct FrozenNamespaceMetrics:
        Equatable, Sendable {
        let regularFileCount: Int
        let directoryCount: Int
        let treeNodeCount: Int
        let peakTransientDescriptorCount: Int
    }

    private struct EntrySeal {
        let path: String
        let identity: PortableArtifactIdentity
        let isDirectory: Bool
        let originalMode: UInt32
        let sealedMode: UInt32
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }

    let packageURL: URL
    let anchorIdentity: PortableArtifactIdentity
    let identity: PortableArtifactIdentity
    let packageDescriptor: Int32

    private let transferRootURL: URL
    private let parentDescriptor: Int32
    private let packageName: String

    fileprivate init(
        packageURL: URL,
        transferRootURL: URL,
        transferRootIdentity: PortableArtifactIdentity,
        parentDescriptor: Int32,
        packageDescriptor: Int32,
        packageName: String,
        identity: PortableArtifactIdentity
    ) {
        self.packageURL = packageURL
        self.transferRootURL = transferRootURL
        self.anchorIdentity = transferRootIdentity
        self.parentDescriptor = parentDescriptor
        self.packageDescriptor = packageDescriptor
        self.packageName = packageName
        self.identity = identity
    }

    deinit {
        Darwin.close(packageDescriptor)
        Darwin.close(parentDescriptor)
    }

    func verifyPublished() throws {
        let canonicalRoot = transferRootURL.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard canonicalRoot >= 0 else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        defer { Darwin.close(canonicalRoot) }
        var canonicalRootStatus = stat()
        var anchoredRootStatus = stat()
        var opened = stat()
        var published = stat()
        guard Darwin.fstat(
                canonicalRoot,
                &canonicalRootStatus
              ) == 0,
              Darwin.fstat(
                parentDescriptor,
                &anchoredRootStatus
              ) == 0,
              anchorIdentity.matches(
                canonicalRootStatus
              ),
              anchorIdentity.matches(
                anchoredRootStatus
              ),
              Darwin.fstat(packageDescriptor, &opened) == 0,
              packageName.withCString({
                  Darwin.fstatat(
                      parentDescriptor,
                      $0,
                      &published,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              identity.matches(opened),
              identity.matches(published) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
    }

    func withFrozenNamespace<T>(
        metricsObserver:
            ((FrozenNamespaceMetrics) -> Void)? = nil,
        _ operation: () throws -> T
    ) throws -> T {
        func permissionMode(_ value: stat) -> UInt32 {
            UInt32(value.st_mode) & 0o7777
        }

        func sameIdentity(
            _ lhs: stat,
            _ rhs: stat
        ) -> Bool {
            lhs.st_dev == rhs.st_dev
                && lhs.st_ino == rhs.st_ino
                && (lhs.st_mode & S_IFMT)
                    == (rhs.st_mode & S_IFMT)
        }

        func matchesSeal(
            _ value: stat,
            _ seal: EntrySeal
        ) -> Bool {
            seal.identity.matches(value)
                && permissionMode(value)
                    == seal.sealedMode
                && Int64(value.st_mtimespec.tv_sec)
                    == seal.modifiedSeconds
                && Int64(value.st_mtimespec.tv_nsec)
                    == seal.modifiedNanoseconds
                && Int64(value.st_ctimespec.tv_sec)
                    == seal.changedSeconds
                && Int64(value.st_ctimespec.tv_nsec)
                    == seal.changedNanoseconds
        }

        func openEntry(
            _ seal: EntrySeal
        ) throws -> Int32 {
            if seal.isDirectory {
                return try Self.openManagedDirectory(
                        rootDescriptor:
                            packageDescriptor,
                        path: seal.path
                    )
            }
            return try Self.openManagedRegularFile(
                    rootDescriptor:
                        packageDescriptor,
                    path: seal.path
                )
        }

        try verifyPublished()
        var parentStatus = stat()
        var packageStatus = stat()
        guard Darwin.fstat(
                parentDescriptor,
                &parentStatus
              ) == 0,
              Darwin.fstat(
                packageDescriptor,
                &packageStatus
              ) == 0,
              (parentStatus.st_mode & S_IFMT)
                == S_IFDIR,
              (packageStatus.st_mode & S_IFMT)
                == S_IFDIR else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        let parentMode = permissionMode(parentStatus)
        let packageMode = permissionMode(packageStatus)
        var parentSealed = stat()
        var packageSealed = stat()
        var seals: [EntrySeal] = []
        var regularFileCount = 0
        var directoryCount = 0
        var treeNodeCount = 0
        var transientDescriptorCount = 0
        var peakTransientDescriptorCount = 0

        func freezeChildren(
            descriptor: Int32,
            prefix: String
        ) throws {
            let remaining =
                PortableBackupLimits
                    .maximumPackageTreeNodeCount
                - treeNodeCount
            let names = try PortableManagedPathSecurity
                .directoryEntries(
                    descriptor: descriptor,
                    maximumEntries: remaining
                )
            for name in names {
                guard treeNodeCount
                        < PortableBackupLimits
                            .maximumPackageTreeNodeCount,
                      let status = try
                        PortableManagedPathSecurity
                        .entryStatus(
                            at: descriptor,
                            component: name,
                            allowMissing: false
                        ) else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                treeNodeCount += 1
                let path = prefix.isEmpty
                    ? name : prefix + "/" + name
                let fileType =
                    status.st_mode & S_IFMT
                let child: Int32
                let isDirectory: Bool
                if fileType == S_IFDIR {
                    directoryCount += 1
                    guard directoryCount
                            <= PortableBackupLimits
                                .maximumPackageDirectoryCount,
                          let opened = try
                            PortableManagedPathSecurity
                            .openDirectory(
                                at: descriptor,
                                component: name,
                                allowMissing: false
                            ) else {
                        throw PortablePackageCleanupError
                            .unsafeTarget
                    }
                    child = opened
                    isDirectory = true
                } else if fileType == S_IFREG,
                          status.st_nlink == 1 {
                    regularFileCount += 1
                    guard regularFileCount
                            <= PortableBackupLimits
                                .maximumEntryCount else {
                        throw PortablePackageCleanupError
                            .unsafeTarget
                    }
                    child = name.withCString {
                        Darwin.openat(
                            descriptor,
                            $0,
                            O_RDONLY | O_NOFOLLOW
                                | O_CLOEXEC
                        )
                    }
                    guard child >= 0 else {
                        throw PortablePackageCleanupError
                            .unsafeTarget
                    }
                    isDirectory = false
                } else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                transientDescriptorCount += 1
                peakTransientDescriptorCount = max(
                    peakTransientDescriptorCount,
                    transientDescriptorCount
                )
                do {
                    var opened = stat()
                    guard Darwin.fstat(child, &opened) == 0,
                          sameIdentity(status, opened),
                          isDirectory
                            || opened.st_nlink == 1 else {
                        throw PortablePackageCleanupError
                            .unsafeTarget
                    }
                    let originalMode =
                        permissionMode(opened)
                    let sealedMode =
                        originalMode & ~0o222
                    guard Darwin.fchmod(
                            child,
                            mode_t(sealedMode)
                          ) == 0,
                          Darwin.fsync(child) == 0 else {
                        throw PortablePackageCleanupError
                            .cleanupRequired
                    }
                    var sealed = stat()
                    guard Darwin.fstat(
                            child,
                            &sealed
                          ) == 0,
                          sameIdentity(opened, sealed),
                          permissionMode(sealed)
                            == sealedMode else {
                        throw PortablePackageCleanupError
                            .unsafeTarget
                    }
                    seals.append(
                        EntrySeal(
                            path: path,
                            identity:
                                PortableArtifactIdentity(
                                    sealed
                                ),
                            isDirectory: isDirectory,
                            originalMode: originalMode,
                            sealedMode: sealedMode,
                            modifiedSeconds:
                                Int64(
                                    sealed.st_mtimespec
                                        .tv_sec
                                ),
                            modifiedNanoseconds:
                                Int64(
                                    sealed.st_mtimespec
                                        .tv_nsec
                                ),
                            changedSeconds:
                                Int64(
                                    sealed.st_ctimespec
                                        .tv_sec
                                ),
                            changedNanoseconds:
                                Int64(
                                    sealed.st_ctimespec
                                        .tv_nsec
                                )
                        )
                    )
                    if isDirectory {
                        try freezeChildren(
                            descriptor: child,
                            prefix: path
                        )
                    }
                    Darwin.close(child)
                    transientDescriptorCount -= 1
                } catch {
                    Darwin.close(child)
                    transientDescriptorCount -= 1
                    throw error
                }
            }
        }

        func verifyFrozenNamespace() throws {
            try verifyPublished()
            var currentParent = stat()
            var currentPackage = stat()
            guard Darwin.fstat(
                    parentDescriptor,
                    &currentParent
                  ) == 0,
                  Darwin.fstat(
                    packageDescriptor,
                    &currentPackage
                  ) == 0,
                  sameIdentity(
                    parentSealed,
                    currentParent
                  ),
                  sameIdentity(
                    packageSealed,
                    currentPackage
                  ),
                  permissionMode(currentParent)
                    == permissionMode(
                        parentSealed
                    ),
                  permissionMode(currentPackage)
                    == permissionMode(
                        packageSealed
                    ),
                  currentParent.st_ctimespec.tv_sec
                    == parentSealed.st_ctimespec.tv_sec,
                  currentParent.st_ctimespec.tv_nsec
                    == parentSealed.st_ctimespec.tv_nsec,
                  currentPackage.st_ctimespec.tv_sec
                    == packageSealed.st_ctimespec.tv_sec,
                  currentPackage.st_ctimespec.tv_nsec
                    == packageSealed.st_ctimespec.tv_nsec else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            let tree = try PortableManagedPathSecurity
                .preflightTree(
                    descriptor: packageDescriptor
                )
            guard tree.count == seals.count,
                  Set(tree.keys)
                    == Set(seals.map(\.path)) else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            for seal in seals {
                let descriptor = try openEntry(seal)
                do {
                    var opened = stat()
                    guard Darwin.fstat(
                            descriptor,
                            &opened
                          ) == 0,
                          matchesSeal(
                            opened,
                            seal
                          ) else {
                        throw PortablePackageCleanupError
                            .unsafeTarget
                    }
                    Darwin.close(descriptor)
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
            }
        }

        func restorePermissions() throws {
            var restored = true
            let ordered = seals.sorted {
                let leftDepth =
                    $0.path.split(separator: "/").count
                let rightDepth =
                    $1.path.split(separator: "/").count
                if leftDepth == rightDepth {
                    return $0.path > $1.path
                }
                return leftDepth > rightDepth
            }
            for seal in ordered {
                do {
                    let descriptor = try openEntry(seal)
                    defer { Darwin.close(descriptor) }
                    var opened = stat()
                    guard Darwin.fstat(
                            descriptor,
                            &opened
                          ) == 0,
                          seal.identity.matches(opened),
                          Darwin.fchmod(
                            descriptor,
                            mode_t(seal.originalMode)
                          ) == 0,
                          Darwin.fsync(descriptor) == 0 else {
                        restored = false
                        continue
                    }
                    var final = stat()
                    restored =
                        Darwin.fstat(
                            descriptor,
                            &final
                        ) == 0
                        && permissionMode(final)
                            == seal.originalMode
                        && restored
                } catch {
                    restored = false
                }
            }
            restored = Darwin.fchmod(
                packageDescriptor,
                mode_t(packageMode)
            ) == 0 && restored
            restored = Darwin.fsync(
                packageDescriptor
            ) == 0 && restored
            restored = Darwin.fchmod(
                parentDescriptor,
                mode_t(parentMode)
            ) == 0 && restored
            restored = Darwin.fsync(
                parentDescriptor
            ) == 0 && restored
            guard restored else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
        }

        do {
            guard Darwin.fchmod(
                    parentDescriptor,
                    mode_t(parentMode & ~0o222)
                  ) == 0,
                  Darwin.fsync(parentDescriptor) == 0,
                  Darwin.fstat(
                    parentDescriptor,
                    &parentSealed
                  ) == 0,
                  Darwin.fchmod(
                    packageDescriptor,
                    mode_t(packageMode & ~0o222)
                  ) == 0,
                  Darwin.fsync(packageDescriptor) == 0,
                  Darwin.fstat(
                    packageDescriptor,
                    &packageSealed
                  ) == 0 else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
            try freezeChildren(
                descriptor: packageDescriptor,
                prefix: ""
            )
            try verifyFrozenNamespace()
            metricsObserver?(
                FrozenNamespaceMetrics(
                    regularFileCount:
                        regularFileCount,
                    directoryCount: directoryCount,
                    treeNodeCount: treeNodeCount,
                    peakTransientDescriptorCount:
                        peakTransientDescriptorCount
                )
            )
            let value = try operation()
            try verifyFrozenNamespace()
            try restorePermissions()
            return value
        } catch {
            let original = error
            do {
                try restorePermissions()
            } catch {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
            throw original
        }
    }

    private static func openManagedDirectory(
        rootDescriptor: Int32,
        path: String
    ) throws -> Int32 {
        let components = path.split(
            separator: "/"
        ).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy(
                isSafePathComponent
              ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        var current = rootDescriptor
        var ownsCurrent = false
        do {
            for component in components {
                guard let next = try
                        PortableManagedPathSecurity
                        .openDirectory(
                            at: current,
                            component: component,
                            allowMissing: false
                        ) else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                if ownsCurrent {
                    Darwin.close(current)
                }
                current = next
                ownsCurrent = true
            }
            return current
        } catch {
            if ownsCurrent {
                Darwin.close(current)
            }
            throw error
        }
    }

    private static func openManagedRegularFile(
        rootDescriptor: Int32,
        path: String
    ) throws -> Int32 {
        let components = path.split(
            separator: "/"
        ).map(String.init)
        guard let leaf = components.last,
              components.allSatisfy(
                isSafePathComponent
              ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        var parent = rootDescriptor
        var ownsParent = false
        do {
            for component in components.dropLast() {
                guard let next = try
                        PortableManagedPathSecurity
                        .openDirectory(
                            at: parent,
                            component: component,
                            allowMissing: false
                        ) else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                if ownsParent {
                    Darwin.close(parent)
                }
                parent = next
                ownsParent = true
            }
            let descriptor = leaf.withCString {
                Darwin.openat(
                    parent,
                    $0,
                    O_RDONLY | O_NOFOLLOW
                        | O_CLOEXEC
                )
            }
            if ownsParent {
                Darwin.close(parent)
                ownsParent = false
            }
            guard descriptor >= 0 else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            return descriptor
        } catch {
            if ownsParent {
                Darwin.close(parent)
            }
            throw error
        }
    }

    private static func isSafePathComponent(
        _ value: String
    ) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\0")
    }

    /// Removes every byte written through this lease, even if the canonical
    /// transfer-root name was moved or replaced after the lease was acquired.
    /// The caller may persist `.sanitized` only after this returns.
    func sanitizeAfterFailure() throws {
        do {
            try PortableManagedPathSecurity
                .quarantineManagedDirectoryIfPublished(
                    parentDescriptor: parentDescriptor,
                    activeName: packageName,
                    quarantineName:
                        ".cleanup-" + packageName,
                    directoryDescriptor:
                        packageDescriptor,
                    expectedIdentity: identity
                )
        } catch {
            try PortableManagedPathSecurity
                .sanitizeManagedDirectory(
                    descriptor: packageDescriptor
                )
            guard Darwin.fsync(packageDescriptor) == 0,
                  Darwin.fsync(parentDescriptor) == 0 else {
                throw PortablePackageCleanupError.cleanupRequired
            }
            throw error
        }
        try PortableManagedPathSecurity
            .sanitizeManagedDirectory(
                descriptor: packageDescriptor
            )
        guard Darwin.fsync(packageDescriptor) == 0,
              Darwin.fsync(parentDescriptor) == 0 else {
            throw PortablePackageCleanupError.cleanupRequired
        }
    }
}

struct PortablePackageCleanupIntent:
    Codable, Equatable, Sendable {
    static let formatVersion = 2

    let formatVersion: Int
    let operationID: UUID
    let kind: PortablePackageArtifactKind
    let state: PortablePackageCleanupIntentState
    let relativePath: String
    let anchorIdentity: PortableArtifactIdentity?
    let rootIdentity: PortableArtifactIdentity?
    let packageIdentity: PortableArtifactIdentity?
    let contractSHA256: String

    init(
        operationID: UUID,
        kind: PortablePackageArtifactKind,
        state: PortablePackageCleanupIntentState = .active,
        anchorIdentity: PortableArtifactIdentity? = nil,
        rootIdentity: PortableArtifactIdentity? = nil,
        packageIdentity: PortableArtifactIdentity? = nil
    ) {
        self.formatVersion = Self.formatVersion
        self.operationID = operationID
        self.kind = kind
        self.state = state
        self.relativePath = Self.relativePath(
            operationID: operationID,
            kind: kind
        )
        self.anchorIdentity = anchorIdentity
        self.rootIdentity = rootIdentity
        self.packageIdentity = packageIdentity
        self.contractSHA256 = Self.contractDigest(
            formatVersion: Self.formatVersion,
            operationID: operationID,
            kind: kind,
            state: state,
            relativePath: relativePath,
            anchorIdentity: anchorIdentity,
            rootIdentity: rootIdentity,
            packageIdentity: packageIdentity
        )
    }

    func updatingState(
        _ state: PortablePackageCleanupIntentState
    ) -> Self {
        Self(
            operationID: operationID,
            kind: kind,
            state: state,
            anchorIdentity: anchorIdentity,
            rootIdentity: rootIdentity,
            packageIdentity: packageIdentity
        )
    }

    func binding(
        anchorIdentity: PortableArtifactIdentity,
        rootIdentity: PortableArtifactIdentity,
        packageIdentity: PortableArtifactIdentity
    ) -> Self {
        Self(
            operationID: operationID,
            kind: kind,
            state: state,
            anchorIdentity: anchorIdentity,
            rootIdentity: rootIdentity,
            packageIdentity: packageIdentity
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
        relativePath: String,
        anchorIdentity: PortableArtifactIdentity?,
        rootIdentity: PortableArtifactIdentity?,
        packageIdentity: PortableArtifactIdentity?
    ) -> String {
        var components = [
            String(formatVersion),
            operationID.uuidString.lowercased(),
            kind.rawValue,
            state.rawValue,
            relativePath
        ]
        if let anchorIdentity,
           let rootIdentity,
           let packageIdentity {
            components += [
                String(anchorIdentity.deviceID),
                String(anchorIdentity.inode),
                String(anchorIdentity.fileType),
                String(rootIdentity.deviceID),
                String(rootIdentity.inode),
                String(rootIdentity.fileType),
                String(packageIdentity.deviceID),
                String(packageIdentity.inode),
                String(packageIdentity.fileType)
            ]
        }
        let value = components.joined(separator: "\u{001f}")
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct PortablePackageCleanupJournal:
    Codable, Equatable, Sendable {
    static let formatVersion = 2

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

private struct LegacyPortablePackageCleanupIntentV1:
    Codable, Equatable, Sendable {
    let formatVersion: Int
    let operationID: UUID
    let kind: PortablePackageArtifactKind
    let state: PortablePackageCleanupIntentState
    let relativePath: String
    let contractSHA256: String

    var migrated: PortablePackageCleanupIntent {
        PortablePackageCleanupIntent(
            operationID: operationID,
            kind: kind,
            state: state
        )
    }

    var expectedContractSHA256: String {
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

private struct LegacyPortablePackageCleanupJournalV1:
    Codable, Equatable, Sendable {
    let formatVersion: Int
    let intents: [LegacyPortablePackageCleanupIntentV1]
    let contractSHA256: String

    var expectedContractSHA256: String {
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
                    maximumBytes: 512 * 1_024,
                    validator: {
                        (try? decodeValidated($0))
                            != nil
                    }
                ) else {
                return nil
            }
            return try decodeValidated(data)
        } catch let error as
            PortablePackageCleanupError {
            throw error
        } catch {
            throw PortablePackageCleanupError
                .invalidJournal
        }
    }

    private func decodeValidated(
        _ data: Data
    ) throws -> PortablePackageCleanupJournal {
        do {
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
                  let formatVersion =
                    dictionary["formatVersion"] as? Int else {
                throw PortablePackageCleanupError
                    .invalidJournal
            }
            if formatVersion == 1 {
                return try migrateLegacyV1(
                    data: data,
                    dictionaries: intents
                )
            }
            guard formatVersion
                    == PortablePackageCleanupJournal
                        .formatVersion,
                  intents.allSatisfy(
                    isValidCurrentIntentShape
                  ) else {
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

    private func migrateLegacyV1(
        data: Data,
        dictionaries: [[String: Any]]
    ) throws -> PortablePackageCleanupJournal {
        let legacyKeys: Set<String> = [
            "formatVersion", "operationID", "kind",
            "state", "relativePath", "contractSHA256"
        ]
        guard dictionaries.allSatisfy({
            Set($0.keys) == legacyKeys
        }) else {
            throw PortablePackageCleanupError.invalidJournal
        }
        let legacy = try JSONDecoder
            .unmanualFoundation.decode(
                LegacyPortablePackageCleanupJournalV1.self,
                from: data
            )
        guard legacy.formatVersion == 1,
              legacy.intents.count <= 4_096,
              legacy.contractSHA256
                == legacy.expectedContractSHA256 else {
            throw PortablePackageCleanupError.invalidJournal
        }
        var operationIDs: Set<UUID> = []
        var paths: Set<String> = []
        for intent in legacy.intents {
            guard intent.formatVersion == 1,
                  intent.state != .sanitized,
                  operationIDs.insert(intent.operationID).inserted,
                  paths.insert(intent.relativePath).inserted,
                  intent.relativePath
                    == PortablePackageCleanupIntent.relativePath(
                        operationID: intent.operationID,
                        kind: intent.kind
                    ),
                  intent.contractSHA256
                    == intent.expectedContractSHA256 else {
                throw PortablePackageCleanupError.invalidJournal
            }
        }
        guard legacy.intents
            == legacy.intents.sorted(by: {
                $0.operationID.uuidString
                    < $1.operationID.uuidString
            }) else {
            throw PortablePackageCleanupError.invalidJournal
        }
        return PortablePackageCleanupJournal(
            intents: legacy.intents.map(\.migrated)
        )
    }

    private func isValidCurrentIntentShape(
        _ dictionary: [String: Any]
    ) -> Bool {
        let keys = Set(dictionary.keys)
        let base: Set<String> = [
            "formatVersion",
            "operationID", "kind",
            "state",
            "relativePath",
            "contractSHA256"
        ]
        guard keys == base
                || keys == base.union([
                    "anchorIdentity",
                    "rootIdentity",
                    "packageIdentity"
                ]) else {
            return false
        }
        if keys == base {
            return true
        }
        guard let anchor =
                dictionary["anchorIdentity"]
                as? [String: Any],
              let root =
                dictionary["rootIdentity"]
                as? [String: Any],
              let package =
                dictionary["packageIdentity"]
                as? [String: Any] else {
            return false
        }
        let identityKeys: Set<String> = [
            "deviceID", "inode", "fileType"
        ]
        return Set(anchor.keys) == identityKeys
            && Set(root.keys) == identityKeys
            && Set(package.keys) == identityKeys
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
                    beforeWrite: beforeWrite,
                    validator: {
                        (try? decodeValidated($0))
                            != nil
                    }
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
                  (intent.anchorIdentity == nil)
                    == (intent.rootIdentity == nil),
                  (intent.rootIdentity == nil)
                    == (intent.packageIdentity == nil),
                  (intent.anchorIdentity.map {
                      $0.inode > 0
                          && $0.fileType == UInt32(S_IFDIR)
                  } ?? true),
                  (intent.rootIdentity.map {
                      $0.inode > 0
                          && $0.fileType == UInt32(S_IFDIR)
                  } ?? true),
                  (intent.packageIdentity.map {
                      $0.inode > 0
                          && $0.fileType == UInt32(S_IFDIR)
                  } ?? true),
                  intent.state != .sanitized
                    || (
                        intent.anchorIdentity != nil
                            && intent.rootIdentity != nil
                            && intent.packageIdentity != nil
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
                                intent.relativePath,
                            anchorIdentity:
                                intent.anchorIdentity,
                            rootIdentity:
                                intent.rootIdentity,
                            packageIdentity:
                                intent.packageIdentity
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

enum AtomicControlFileTransactionError: Error {
    case unsafeState
    case ioFailure
}

/// Shared crash-recovery protocol for the fixed control JSON files under
/// GenerationPointer and Recovery. The temporary names carry complete
/// content digests, so a cold reader can distinguish the intended new and old
/// values from a path replacement without trusting pathname presence alone.
enum AtomicControlFileTransaction {
    private struct Candidate {
        let name: String
        let status: stat
        let data: Data
        let digest: String
        let isSemanticallyValid: Bool
    }

    private static let processLock = NSRecursiveLock()
    private static let digestLength = 64

    static func locked<T>(
        _ operation: () throws -> T
    ) rethrows -> T {
        processLock.lock()
        defer { processLock.unlock() }
        return try operation()
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func newName(
        destinationName: String,
        data: Data
    ) -> String {
        newPrefix(destinationName)
            + digest(data)
    }

    static func oldName(
        destinationName: String,
        data: Data
    ) -> String {
        oldPrefix(destinationName)
            + digest(data)
    }

    static func reconcile(
        parentDescriptor: Int32,
        destinationName: String,
        maximumBytes: Int,
        validator: (Data) -> Bool
    ) throws -> Data? {
        guard maximumBytes >= 0,
              isSafeComponent(destinationName) else {
            throw AtomicControlFileTransactionError
                .unsafeState
        }
        return try locked {
            let names = try PortableManagedPathSecurity
                .directoryEntries(
                    descriptor: parentDescriptor,
                    maximumEntries: 64
                )
            let newNames = try transactionNames(
                in: names,
                prefix: newPrefix(destinationName)
            )
            let oldNames = try transactionNames(
                in: names,
                prefix: oldPrefix(destinationName)
            )
            let canonical = try readCandidate(
                parentDescriptor: parentDescriptor,
                name: destinationName,
                maximumBytes: maximumBytes,
                validator: validator
            )
            let newCandidate = try newNames.first.map {
                try readCandidateRequired(
                    parentDescriptor:
                        parentDescriptor,
                    name: $0,
                    maximumBytes: maximumBytes,
                    validator: validator
                )
            }
            let oldCandidate = try oldNames.first.map {
                try readCandidateRequired(
                    parentDescriptor:
                        parentDescriptor,
                    name: $0,
                    maximumBytes: maximumBytes,
                    validator: validator
                )
            }
            if let oldCandidate {
                guard oldCandidate.isSemanticallyValid,
                      oldCandidate.digest
                        == digestSuffix(
                            oldCandidate.name,
                            prefix:
                                oldPrefix(
                                    destinationName
                                )
                        ) else {
                    throw AtomicControlFileTransactionError
                        .unsafeState
                }
            }
            let expectedNewDigest =
                newCandidate.map {
                    digestSuffix(
                        $0.name,
                        prefix:
                            newPrefix(destinationName)
                    )
                }
            guard newCandidate?.isSemanticallyValid
                    ?? true else {
                throw AtomicControlFileTransactionError
                    .unsafeState
            }

            switch (
                canonical,
                newCandidate,
                oldCandidate
            ) {
            case (nil, nil, nil):
                return nil

            case let (canonical?, nil, nil):
                return canonical.data

            case let (canonical?, nil, old?):
                guard canonical.isSemanticallyValid,
                      canonical.digest
                        == old.digest else {
                    throw AtomicControlFileTransactionError
                        .unsafeState
                }
                try remove(
                    old,
                    parentDescriptor:
                        parentDescriptor
                )
                return canonical.data

            case (nil, nil, let old?):
                try publishExclusively(
                    old,
                    destinationName:
                        destinationName,
                    parentDescriptor:
                        parentDescriptor
                )
                return old.data

            case (nil, let new?, nil):
                guard new.digest
                        == expectedNewDigest else {
                    throw AtomicControlFileTransactionError
                        .unsafeState
                }
                // No old value existed and publish had not happened. Abort
                // the incomplete creation and let the upper layer retry.
                try remove(
                    new,
                    parentDescriptor:
                        parentDescriptor
                )
                return nil

            case let (canonical?, new?, nil):
                guard canonical.isSemanticallyValid,
                      canonical.digest
                        == expectedNewDigest else {
                    throw AtomicControlFileTransactionError
                        .unsafeState
                }
                // The old rollback was already durably removed. The name of
                // the swapped-out old inode still proves the intended new
                // canonical digest.
                try remove(
                    new,
                    parentDescriptor:
                        parentDescriptor
                )
                return canonical.data

            case (nil, let new?, let old?):
                let newIsPrePublish =
                    new.digest == expectedNewDigest
                let newIsPostPublish =
                    new.digest == old.digest
                guard newIsPrePublish
                        || newIsPostPublish else {
                    throw AtomicControlFileTransactionError
                        .unsafeState
                }
                try publishExclusively(
                    old,
                    destinationName:
                        destinationName,
                    parentDescriptor:
                        parentDescriptor
                )
                try remove(
                    new,
                    parentDescriptor:
                        parentDescriptor
                )
                return old.data

            case let (canonical?, new?, old?):
                guard canonical.isSemanticallyValid
                else {
                    throw AtomicControlFileTransactionError
                        .unsafeState
                }
                if canonical.digest == old.digest,
                   new.digest == expectedNewDigest {
                    // Pre-publish crash: canonical is still the exact old
                    // value.
                    try remove(
                        new,
                        parentDescriptor:
                            parentDescriptor
                    )
                    try remove(
                        old,
                        parentDescriptor:
                            parentDescriptor
                    )
                    return canonical.data
                }
                guard canonical.digest
                        == expectedNewDigest,
                      new.digest == old.digest else {
                    throw AtomicControlFileTransactionError
                        .unsafeState
                }
                // Post-swap crash. Remove the independent rollback first so
                // the new digest remains encoded in the swapped temporary
                // name until the final cleanup cut.
                try remove(
                    old,
                    parentDescriptor:
                        parentDescriptor
                )
                try remove(
                    new,
                    parentDescriptor:
                        parentDescriptor
                )
                return canonical.data
            }
        }
    }

    private static func transactionNames(
        in names: [String],
        prefix: String
    ) throws -> [String] {
        let reserved = names.filter {
            $0.hasPrefix(prefix)
        }
        guard reserved.count <= 1,
              reserved.allSatisfy({
                  let suffix = String(
                    $0.dropFirst(prefix.count)
                  )
                  return suffix.count == digestLength
                    && suffix.allSatisfy {
                        $0.isNumber
                            || ("a"..."f")
                                .contains(
                                    String($0)
                                )
                    }
              }) else {
            throw AtomicControlFileTransactionError
                .unsafeState
        }
        return reserved
    }

    private static func readCandidateRequired(
        parentDescriptor: Int32,
        name: String,
        maximumBytes: Int,
        validator: (Data) -> Bool
    ) throws -> Candidate {
        guard let value = try readCandidate(
            parentDescriptor: parentDescriptor,
            name: name,
            maximumBytes: maximumBytes,
            validator: validator
        ) else {
            throw AtomicControlFileTransactionError
                .unsafeState
        }
        return value
    }

    private static func readCandidate(
        parentDescriptor: Int32,
        name: String,
        maximumBytes: Int,
        validator: (Data) -> Bool
    ) throws -> Candidate? {
        var published = stat()
        let result = name.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &published,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result != 0 {
            guard errno == ENOENT else {
                throw AtomicControlFileTransactionError
                    .ioFailure
            }
            return nil
        }
        guard (published.st_mode & S_IFMT)
                == S_IFREG,
              published.st_nlink == 1,
              published.st_size >= 0,
              published.st_size
                <= off_t(maximumBytes) else {
            throw AtomicControlFileTransactionError
                .unsafeState
        }
        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw AtomicControlFileTransactionError
                .ioFailure
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              sameFile(published, opened),
              opened.st_nlink == 1,
              opened.st_size == published.st_size else {
            throw AtomicControlFileTransactionError
                .unsafeState
        }
        var bytes = [UInt8](
            repeating: 0,
            count: Int(opened.st_size)
        )
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes {
                raw in
                Darwin.pread(
                    descriptor,
                    raw.baseAddress?
                        .advanced(by: offset),
                    remaining,
                    off_t(offset)
                )
            }
            guard count > 0 else {
                throw AtomicControlFileTransactionError
                    .ioFailure
            }
            offset += count
        }
        var final = stat()
        guard Darwin.fstat(descriptor, &final) == 0,
              sameFile(opened, final),
              final.st_nlink == 1,
              final.st_size == opened.st_size else {
            throw AtomicControlFileTransactionError
                .unsafeState
        }
        let data = Data(bytes)
        return Candidate(
            name: name,
            status: final,
            data: data,
            digest: digest(data),
            isSemanticallyValid: validator(data)
        )
    }

    private static func publishExclusively(
        _ candidate: Candidate,
        destinationName: String,
        parentDescriptor: Int32
    ) throws {
        try verifyPublished(
            candidate,
            parentDescriptor:
                parentDescriptor
        )
        let result = candidate.name.withCString {
            source in
            destinationName.withCString {
                destination in
                Darwin.renameatx_np(
                    parentDescriptor,
                    source,
                    parentDescriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0,
              Darwin.fsync(parentDescriptor) == 0 else {
            throw AtomicControlFileTransactionError
                .ioFailure
        }
    }

    private static func remove(
        _ candidate: Candidate,
        parentDescriptor: Int32
    ) throws {
        try verifyPublished(
            candidate,
            parentDescriptor:
                parentDescriptor
        )
        guard candidate.name.withCString({
                  Darwin.unlinkat(
                    parentDescriptor,
                    $0,
                    0
                  )
              }) == 0,
              Darwin.fsync(parentDescriptor) == 0 else {
            throw AtomicControlFileTransactionError
                .ioFailure
        }
    }

    private static func verifyPublished(
        _ candidate: Candidate,
        parentDescriptor: Int32
    ) throws {
        var current = stat()
        guard candidate.name.withCString({
                  Darwin.fstatat(
                      parentDescriptor,
                      $0,
                      &current,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              sameFile(
                candidate.status,
                current
              ),
              current.st_nlink == 1 else {
            throw AtomicControlFileTransactionError
                .unsafeState
        }
    }

    private static func digestSuffix(
        _ name: String,
        prefix: String
    ) -> String {
        String(name.dropFirst(prefix.count))
    }

    private static func newPrefix(
        _ destinationName: String
    ) -> String {
        "." + destinationName
            + ".atomic-new-v1-"
    }

    private static func oldPrefix(
        _ destinationName: String
    ) -> String {
        "." + destinationName
            + ".atomic-old-v1-"
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

enum PortableManagedPathSecurity {
    typealias MutationProbe = @Sendable () throws -> Void
    typealias ArtifactBinding =
        @Sendable (
            PortableArtifactIdentity,
            PortableArtifactIdentity,
            PortableArtifactIdentity
        ) async throws -> Void
    typealias ArtifactSanitization =
        @Sendable (
            PortableArtifactIdentity,
            PortableArtifactIdentity,
            PortableArtifactIdentity
        ) async throws -> Void

    final class GenerationTargetLease:
        @unchecked Sendable {
        let layout: AppDataStoreLayout
        let generationName: String
        let ancestry: PortableRestoreTargetAncestry
        let targetDescriptor: Int32
        let storeDescriptor: Int32
        let filesDescriptor: Int32

        private let containerParentDescriptor: Int32
        private let rootDescriptor: Int32
        private let generationsDescriptor: Int32
        private var databaseBundle:
            [String: PortableArtifactIdentity] = [:]
        private struct SealedDirectory {
            let path: String
            let identity: PortableArtifactIdentity
            let sealedMode: UInt32
            let restoreMode: UInt32
            let modifiedSeconds: Int64
            let modifiedNanoseconds: Int64
            let changedSeconds: Int64
            let changedNanoseconds: Int64
        }
        private struct SealedDescriptorDirectory {
            let identity: PortableArtifactIdentity
            let sealedMode: UInt32
            let restoreMode: UInt32
            let modifiedSeconds: Int64
            let modifiedNanoseconds: Int64
            let changedSeconds: Int64
            let changedNanoseconds: Int64
        }
        private struct RegularFileSeal {
            let path: String
            let identity: PortableArtifactIdentity
            let byteCount: Int64
            let sealedMode: UInt32
            let restoreMode: UInt32
            let modifiedSeconds: Int64
            let modifiedNanoseconds: Int64
            let changedSeconds: Int64
            let changedNanoseconds: Int64
            let sha256Hex: String
        }
        private var sealedFilesDirectories:
            [SealedDirectory] = []
        private var sealedDescriptorDirectories:
            [SealedDescriptorDirectory] = []
        private var sealedStoreFiles:
            [RegularFileSeal] = []
        private var sealedFiles:
            [RegularFileSeal] = []
        private var sealedFilesTree: [String: stat]?
        private var filesNamespaceSealed = false

        private init(
            layout: AppDataStoreLayout,
            generationName: String,
            ancestry: PortableRestoreTargetAncestry,
            containerParentDescriptor: Int32,
            rootDescriptor: Int32,
            generationsDescriptor: Int32,
            targetDescriptor: Int32,
            storeDescriptor: Int32,
            filesDescriptor: Int32
        ) {
            self.layout = layout
            self.generationName = generationName
            self.ancestry = ancestry
            self.containerParentDescriptor =
                containerParentDescriptor
            self.rootDescriptor = rootDescriptor
            self.generationsDescriptor =
                generationsDescriptor
            self.targetDescriptor = targetDescriptor
            self.storeDescriptor = storeDescriptor
            self.filesDescriptor = filesDescriptor
        }

        deinit {
            Darwin.close(filesDescriptor)
            Darwin.close(storeDescriptor)
            Darwin.close(targetDescriptor)
            Darwin.close(generationsDescriptor)
            Darwin.close(rootDescriptor)
            Darwin.close(containerParentDescriptor)
        }

        static func acquire(
            layout: AppDataStoreLayout,
            generationName: String,
            expectedTarget:
                PortableArtifactIdentity?,
            expectedAncestry:
                PortableRestoreTargetAncestry? = nil
        ) throws -> GenerationTargetLease {
            guard isSafeComponent(generationName) else {
                throw PortablePackageCleanupError.unsafeTarget
            }
            let parentURL = layout.rootURL
                .deletingLastPathComponent()
            let rootName = layout.rootURL.lastPathComponent
            guard isSafeComponent(rootName),
                  let parentFD = try openDirectory(
                    at: AT_FDCWD,
                    component: parentURL.path,
                    allowMissing: false
                  ) else {
                throw PortablePackageCleanupError.unsafeTarget
            }
            var owned = [
                parentFD
            ]
            func closeOwned() {
                for descriptor in owned.reversed() {
                    Darwin.close(descriptor)
                }
            }
            do {
                guard let rootFD = try openDirectory(
                    at: parentFD,
                    component: rootName,
                    allowMissing: false
                ) else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                owned.append(rootFD)
                guard let generationsFD = try openDirectory(
                    at: rootFD,
                    component: "Generations",
                    allowMissing: false
                ) else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                owned.append(generationsFD)
                guard let targetFD = try openDirectory(
                    at: generationsFD,
                    component: generationName,
                    allowMissing: false
                ) else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                owned.append(targetFD)
                guard let storeFD = try openDirectory(
                    at: targetFD,
                    component: "Store",
                    allowMissing: false
                ) else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                owned.append(storeFD)
                let filesFD: Int32
                if let openedFiles = try openDirectory(
                    at: targetFD,
                    component: "Files",
                    allowMissing: true
                ) {
                    filesFD = openedFiles
                } else {
                    guard expectedAncestry == nil else {
                        throw PortablePackageCleanupError
                            .unsafeTarget
                    }
                    filesFD = try createChildDirectory(
                        at: targetFD,
                        component: "Files",
                        backupPolicy: .systemManaged
                    )
                }
                owned.append(filesFD)
                let statuses = try [
                    status(parentFD),
                    status(rootFD),
                    status(generationsFD),
                    status(targetFD),
                    status(storeFD),
                    status(filesFD)
                ]
                guard statuses.allSatisfy(isDirectory),
                      expectedTarget?
                        .matches(statuses[3]) == true else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                let captured =
                    PortableRestoreTargetAncestry(
                        containerParent:
                            PortableArtifactIdentity(
                                statuses[0]
                            ),
                        root:
                            PortableArtifactIdentity(
                                statuses[1]
                            ),
                        generations:
                            PortableArtifactIdentity(
                                statuses[2]
                            ),
                        target:
                            PortableArtifactIdentity(
                                statuses[3]
                            ),
                        store:
                            PortableArtifactIdentity(
                                statuses[4]
                            ),
                        files:
                            PortableArtifactIdentity(
                                statuses[5]
                            ),
                        containerParentMode:
                            permissionMode(statuses[0]),
                        rootMode:
                            permissionMode(statuses[1]),
                        generationsMode:
                            permissionMode(statuses[2]),
                        targetMode:
                            permissionMode(statuses[3]),
                        storeMode:
                            permissionMode(statuses[4]),
                        filesMode:
                            permissionMode(statuses[5])
                    )
                let ancestry = expectedAncestry
                    ?? captured
                if let expectedAncestry {
                    guard ancestryIdentitiesMatch(
                        expectedAncestry,
                        statuses: statuses
                    ),
                    currentModesAreExpectedOrShielded(
                        statuses: statuses,
                        ancestry: expectedAncestry
                    ) else {
                        throw PortablePackageCleanupError
                            .unsafeTarget
                    }
                }
                let lease = GenerationTargetLease(
                    layout: layout,
                    generationName: generationName,
                    ancestry: ancestry,
                    containerParentDescriptor:
                        parentFD,
                    rootDescriptor: rootFD,
                    generationsDescriptor:
                        generationsFD,
                    targetDescriptor: targetFD,
                    storeDescriptor: storeFD,
                    filesDescriptor: filesFD
                )
                owned.removeAll()
                try lease.verifyPublished()
                return lease
            } catch {
                closeOwned()
                throw error
            }
        }

        func verifyPublished() throws {
            guard let currentParent = try openDirectory(
                at: AT_FDCWD,
                component: layout.rootURL
                    .deletingLastPathComponent().path,
                allowMissing: false
            ) else {
                throw PortablePackageCleanupError.unsafeTarget
            }
            defer { Darwin.close(currentParent) }
            let rootName = layout.rootURL.lastPathComponent
            guard let currentRoot = try openDirectory(
                at: currentParent,
                component: rootName,
                allowMissing: false
            ) else {
                throw PortablePackageCleanupError.unsafeTarget
            }
            defer { Darwin.close(currentRoot) }
            guard let currentGenerations = try openDirectory(
                at: currentRoot,
                component: "Generations",
                allowMissing: false
            ) else {
                throw PortablePackageCleanupError.unsafeTarget
            }
            defer { Darwin.close(currentGenerations) }
            guard let currentTarget = try openDirectory(
                at: currentGenerations,
                component: generationName,
                allowMissing: false
            ) else {
                throw PortablePackageCleanupError.unsafeTarget
            }
            defer { Darwin.close(currentTarget) }
            guard let currentStore = try openDirectory(
                at: currentTarget,
                component: "Store",
                allowMissing: false
            ) else {
                throw PortablePackageCleanupError.unsafeTarget
            }
            defer { Darwin.close(currentStore) }
            guard let currentFiles = try openDirectory(
                at: currentTarget,
                component: "Files",
                allowMissing: false
            ) else {
                throw PortablePackageCleanupError.unsafeTarget
            }
            defer { Darwin.close(currentFiles) }
            let current = try [
                Self.status(currentParent),
                Self.status(currentRoot),
                Self.status(currentGenerations),
                Self.status(currentTarget),
                Self.status(currentStore),
                Self.status(currentFiles)
            ]
            let held = try [
                Self.status(containerParentDescriptor),
                Self.status(rootDescriptor),
                Self.status(generationsDescriptor),
                Self.status(targetDescriptor),
                Self.status(storeDescriptor),
                Self.status(filesDescriptor)
            ]
            guard Self.ancestryIdentitiesMatch(
                    ancestry,
                    statuses: current
                  ),
                  Self.ancestryIdentitiesMatch(
                    ancestry,
                    statuses: held
                  ) else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
        }

        func beginNamespaceShield() throws {
            if !sealedDescriptorDirectories.isEmpty {
                try verifyDescriptorDirectorySeals()
                return
            }
            try verifyPublished()
            try bindDatabaseBundle()
            let descriptors = [
                containerParentDescriptor,
                rootDescriptor,
                generationsDescriptor,
                targetDescriptor,
                storeDescriptor
            ]
            let modes = Array(
                ancestry.allModes.prefix(5)
            )
            for (descriptor, mode) in zip(
                descriptors,
                modes
            ).reversed() {
                guard Darwin.fchmod(
                    descriptor,
                    mode_t(mode & ~0o222)
                ) == 0 else {
                    throw PortablePackageCleanupError
                        .cleanupRequired
                }
            }
            guard descriptors.allSatisfy({
                Darwin.fsync($0) == 0
            }) else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
            sealedDescriptorDirectories = try zip(
                descriptors,
                modes
            ).map {
                try captureDescriptorDirectorySeal(
                    descriptor: $0.0,
                    restoreMode: $0.1
                )
            }
            try verifyPublished()
            try verifyDatabaseBundle()
            try verifyDescriptorDirectorySeals()
        }

        func restoreNamespacePermissions() throws {
            if sealedDescriptorDirectories.count == 5,
               sealedFilesDirectories.isEmpty {
                try verifyDescriptorDirectorySeals()
            } else if !sealedDescriptorDirectories
                        .isEmpty
                        || !sealedFilesDirectories.isEmpty {
                try verifyDirectorySeals()
            }
            try restoreRegularFilePermissions(
                rootDescriptor: storeDescriptor,
                seals: sealedStoreFiles,
                fallbackPaths:
                    databaseBundle.keys.sorted()
            )
            let filesSnapshot = try preflightTree(
                descriptor: filesDescriptor
            )
            try restoreRegularFilePermissions(
                rootDescriptor: filesDescriptor,
                seals: sealedFiles,
                fallbackPaths: filesSnapshot
                    .filter { isRegular($0.value) }
                    .map(\.key)
                    .sorted()
            )
            var directoriesToRestore =
                sealedFilesDirectories
            if directoriesToRestore.isEmpty {
                for path in filesSnapshot
                    .filter({ isDirectory($0.value) })
                    .map(\.key)
                    .sorted() {
                    guard let value =
                            filesSnapshot[path] else {
                        throw PortablePackageCleanupError
                            .unsafeTarget
                    }
                    let mode = Self.permissionMode(
                        value
                    )
                    guard mode == 0o500
                            || mode == 0o700 else {
                        throw PortablePackageCleanupError
                            .unsafeTarget
                    }
                    directoriesToRestore.append(
                        SealedDirectory(
                            path: path,
                            identity:
                                PortableArtifactIdentity(
                                    value
                                ),
                            sealedMode: mode,
                            restoreMode: 0o700,
                            modifiedSeconds:
                                Int64(
                                    value.st_mtimespec
                                        .tv_sec
                                ),
                            modifiedNanoseconds:
                                Int64(
                                    value.st_mtimespec
                                        .tv_nsec
                                ),
                            changedSeconds:
                                Int64(
                                    value.st_ctimespec
                                        .tv_sec
                                ),
                            changedNanoseconds:
                                Int64(
                                    value.st_ctimespec
                                        .tv_nsec
                                )
                        )
                    )
                }
            }
            for entry in directoriesToRestore.reversed() {
                let descriptor = try openManagedDirectory(
                    rootDescriptor: filesDescriptor,
                    path: entry.path
                )
                do {
                    var opened = stat()
                    guard Darwin.fstat(
                            descriptor,
                            &opened
                          ) == 0,
                          entry.identity.matches(opened),
                          isDirectory(opened),
                          Darwin.fchmod(
                            descriptor,
                            mode_t(entry.restoreMode)
                          ) == 0,
                          Darwin.fsync(descriptor) == 0 else {
                        throw PortablePackageCleanupError
                            .cleanupRequired
                    }
                    Darwin.close(descriptor)
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
            }
            let descriptors = [
                containerParentDescriptor,
                rootDescriptor,
                generationsDescriptor,
                targetDescriptor,
                storeDescriptor,
                filesDescriptor
            ]
            let modes: [UInt32]
            if sealedDescriptorDirectories.isEmpty {
                modes = ancestry.allModes
            } else if sealedDescriptorDirectories
                        .count == 5 {
                modes = sealedDescriptorDirectories
                    .map(\.restoreMode)
                    + [ancestry.filesMode]
            } else {
                modes = sealedDescriptorDirectories
                    .map(\.restoreMode)
            }
            guard modes.count == descriptors.count else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            for (descriptor, mode) in zip(
                descriptors,
                modes
            ) {
                guard Darwin.fchmod(
                    descriptor,
                    mode_t(mode)
                ) == 0 else {
                    throw PortablePackageCleanupError
                        .cleanupRequired
                }
            }
            guard descriptors.reversed().allSatisfy({
                Darwin.fsync($0) == 0
            }) else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
            try verifyPublished()
            sealedFilesDirectories.removeAll()
            sealedDescriptorDirectories.removeAll()
            sealedStoreFiles.removeAll()
            sealedFiles.removeAll()
            sealedFilesTree = nil
            filesNamespaceSealed = false
        }

        func sealFilesNamespace() throws {
            if filesNamespaceSealed {
                try verifyPublished()
                try verifyDirectorySeals()
                return
            }
            try verifyPublished()
            let snapshot = try preflightTree(
                descriptor: filesDescriptor
            )
            try verifyTree(
                descriptor: filesDescriptor,
                snapshot: snapshot
            )
            let directoryPaths = snapshot
                .filter { isDirectory($0.value) }
                .map(\.key)
                .sorted {
                    let leftDepth =
                        $0.split(separator: "/").count
                    let rightDepth =
                        $1.split(separator: "/").count
                    if leftDepth == rightDepth {
                        return $0 < $1
                    }
                    return leftDepth < rightDepth
                }
            var retained: [SealedDirectory] = []
            do {
                for path in directoryPaths {
                    let current = try openManagedDirectory(
                        rootDescriptor: filesDescriptor,
                        path: path
                    )
                    do {
                        var opened = stat()
                        guard Darwin.fstat(
                                current,
                                &opened
                              ) == 0,
                              let expected = snapshot[path],
                              sameFile(opened, expected),
                              isDirectory(opened) else {
                            throw PortablePackageCleanupError
                                .unsafeTarget
                        }
                        let currentMode =
                            Self.permissionMode(opened)
                        guard currentMode == 0o500
                                || currentMode
                                    == 0o700 else {
                            throw PortablePackageCleanupError
                                .unsafeTarget
                        }
                        let sealedMode: UInt32 =
                            0o500
                        guard Darwin.fchmod(
                                current,
                                mode_t(sealedMode)
                              ) == 0,
                              Darwin.fsync(
                                current
                              ) == 0 else {
                            throw PortablePackageCleanupError
                                .cleanupRequired
                        }
                        var sealed = stat()
                        guard Darwin.fstat(
                                current,
                                &sealed
                              ) == 0,
                              sameFile(opened, sealed),
                              isDirectory(sealed),
                              Self.permissionMode(sealed)
                                == sealedMode else {
                            throw PortablePackageCleanupError
                                .unsafeTarget
                        }
                        retained.append(
                            SealedDirectory(
                                path: path,
                                identity:
                                    PortableArtifactIdentity(
                                        sealed
                                    ),
                                sealedMode: sealedMode,
                                restoreMode: 0o700,
                                modifiedSeconds:
                                    Int64(
                                        sealed.st_mtimespec
                                            .tv_sec
                                    ),
                                modifiedNanoseconds:
                                    Int64(
                                        sealed.st_mtimespec
                                            .tv_nsec
                                    ),
                                changedSeconds:
                                    Int64(
                                        sealed.st_ctimespec
                                            .tv_sec
                                    ),
                                changedNanoseconds:
                                    Int64(
                                        sealed.st_ctimespec
                                            .tv_nsec
                                    )
                            )
                        )
                        Darwin.close(current)
                    } catch {
                        Darwin.close(current)
                        throw error
                    }
                }
                guard Darwin.fchmod(
                        filesDescriptor,
                        mode_t(
                            ancestry.filesMode & ~0o222
                        )
                      ) == 0,
                      Darwin.fsync(filesDescriptor) == 0,
                      Darwin.fsync(targetDescriptor) == 0 else {
                    throw PortablePackageCleanupError
                        .cleanupRequired
                }
                let filesSeal = try
                    captureDescriptorDirectorySeal(
                        descriptor: filesDescriptor,
                        restoreMode:
                            ancestry.filesMode
                    )
                guard sealedDescriptorDirectories
                        .count == 5 else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                sealedDescriptorDirectories.append(
                    filesSeal
                )
                try verifyTree(
                    descriptor: filesDescriptor,
                    snapshot: snapshot
                )
                sealedFilesDirectories = retained
                filesNamespaceSealed = true
                try verifyPublished()
                try verifyDirectorySeals()
            } catch {
                for entry in retained {
                    if let descriptor = try? openManagedDirectory(
                        rootDescriptor: filesDescriptor,
                        path: entry.path
                    ) {
                        _ = Darwin.fchmod(
                            descriptor,
                            mode_t(entry.restoreMode)
                        )
                        Darwin.close(descriptor)
                    }
                }
                _ = Darwin.fchmod(
                    filesDescriptor,
                    mode_t(ancestry.filesMode)
                )
                if sealedDescriptorDirectories
                    .count == 6 {
                    sealedDescriptorDirectories
                        .removeLast()
                }
                sealedFilesDirectories.removeAll()
                filesNamespaceSealed = false
                throw error
            }
        }

        /// Seals the exact activation payload after semantic validation. The
        /// directory namespace shield prevents normal new opens while these
        /// hashes also detect writes made through descriptors that were
        /// already open before the shield.
        func sealActivationContents() throws {
            if !sealedStoreFiles.isEmpty
                || !sealedFiles.isEmpty
                || sealedFilesTree != nil {
                try verifyActivationContents()
                return
            }
            guard filesNamespaceSealed else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            try verifyPublished()
            try verifyDatabaseBundle()
            let storeNames = try directoryEntries(
                descriptor: storeDescriptor,
                maximumEntries: 3
            )
            guard Set(storeNames)
                    == Set(databaseBundle.keys) else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            let filesTree = try preflightTree(
                descriptor: filesDescriptor
            )
            try verifyTree(
                descriptor: filesDescriptor,
                snapshot: filesTree
            )
            var expectedStore: [String: stat] = [:]
            for name in storeNames {
                guard let value = try entryStatus(
                    at: storeDescriptor,
                    component: name,
                    allowMissing: false
                ) else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                expectedStore[name] = value
            }
            var storeSeals: [RegularFileSeal] = []
            var fileSeals: [RegularFileSeal] = []
            do {
                try appendSealedRegularFiles(
                    rootDescriptor: storeDescriptor,
                    expected: expectedStore,
                    into: &storeSeals
                )
                try appendSealedRegularFiles(
                    rootDescriptor: filesDescriptor,
                    expected: filesTree.filter {
                        isRegular($0.value)
                    },
                    into: &fileSeals
                )
                sealedStoreFiles = storeSeals
                sealedFiles = fileSeals
                sealedFilesTree = filesTree
                try verifyActivationContents()
            } catch {
                try? restoreRegularFilePermissions(
                    rootDescriptor: storeDescriptor,
                    seals: storeSeals,
                    fallbackPaths: []
                )
                try? restoreRegularFilePermissions(
                    rootDescriptor: filesDescriptor,
                    seals: fileSeals,
                    fallbackPaths: []
                )
                sealedStoreFiles.removeAll()
                sealedFiles.removeAll()
                sealedFilesTree = nil
                throw error
            }
        }

        func verifyActivationContents() throws {
            guard let filesTree = sealedFilesTree,
                  !sealedStoreFiles.isEmpty else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            try verifyPublished()
            try verifyDatabaseBundle()
            let storeNames = try directoryEntries(
                descriptor: storeDescriptor,
                maximumEntries: 3
            )
            guard Set(storeNames)
                    == Set(sealedStoreFiles.map(\.path)) else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            try verifyTree(
                descriptor: filesDescriptor,
                snapshot: filesTree
            )
            try verifyDirectorySeals()
            try verifyRegularFileSeals(
                rootDescriptor: storeDescriptor,
                seals: sealedStoreFiles
            )
            try verifyRegularFileSeals(
                rootDescriptor: filesDescriptor,
                seals: sealedFiles
            )
            try verifyPublished()
        }

        func verifyDatabaseBundle() throws {
            guard !databaseBundle.isEmpty else {
                throw PortablePackageCleanupError.unsafeTarget
            }
            let names = try directoryEntries(
                descriptor: storeDescriptor,
                maximumEntries: 3
            )
            guard Set(names) == Set(databaseBundle.keys)
            else {
                throw PortablePackageCleanupError.unsafeTarget
            }
            for (name, identity) in databaseBundle {
                guard let published = try entryStatus(
                    at: storeDescriptor,
                    component: name,
                    allowMissing: false
                ),
                isRegular(published),
                published.st_nlink == 1,
                identity.matches(published) else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
            }
        }

        private func verifyDirectorySeals() throws {
            try verifyDescriptorDirectorySeals()
            guard sealedDescriptorDirectories
                    .count == 6 else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            for seal in sealedFilesDirectories {
                let descriptor = try openManagedDirectory(
                    rootDescriptor: filesDescriptor,
                    path: seal.path
                )
                do {
                    var opened = stat()
                    guard Darwin.fstat(
                            descriptor,
                            &opened
                          ) == 0,
                          isDirectory(opened),
                          seal.identity.matches(opened),
                          Self.permissionMode(opened)
                            == seal.sealedMode,
                          Int64(
                            opened.st_mtimespec.tv_sec
                          ) == seal.modifiedSeconds,
                          Int64(
                            opened.st_mtimespec.tv_nsec
                          ) == seal.modifiedNanoseconds,
                          Int64(
                            opened.st_ctimespec.tv_sec
                          ) == seal.changedSeconds,
                          Int64(
                            opened.st_ctimespec.tv_nsec
                          ) == seal.changedNanoseconds else {
                        throw PortablePackageCleanupError
                            .unsafeTarget
                    }
                    Darwin.close(descriptor)
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
            }
        }

        private func verifyDescriptorDirectorySeals()
            throws {
            let descriptors = [
                containerParentDescriptor,
                rootDescriptor,
                generationsDescriptor,
                targetDescriptor,
                storeDescriptor,
                filesDescriptor
            ]
            guard sealedDescriptorDirectories
                    .count == 5
                    || sealedDescriptorDirectories
                        .count == 6 else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            for (descriptor, seal) in zip(
                descriptors,
                sealedDescriptorDirectories
            ) {
                var opened = stat()
                guard Darwin.fstat(
                        descriptor,
                        &opened
                      ) == 0,
                      isDirectory(opened),
                      seal.identity.matches(opened),
                      Self.permissionMode(opened)
                        == seal.sealedMode,
                      Int64(
                        opened.st_mtimespec.tv_sec
                      ) == seal.modifiedSeconds,
                      Int64(
                        opened.st_mtimespec.tv_nsec
                      ) == seal.modifiedNanoseconds,
                      Int64(
                        opened.st_ctimespec.tv_sec
                      ) == seal.changedSeconds,
                      Int64(
                        opened.st_ctimespec.tv_nsec
                      ) == seal.changedNanoseconds else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
            }
        }

        private func captureDescriptorDirectorySeal(
            descriptor: Int32,
            restoreMode: UInt32
        ) throws -> SealedDescriptorDirectory {
            var opened = stat()
            guard Darwin.fstat(
                    descriptor,
                    &opened
                  ) == 0,
                  isDirectory(opened) else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            return SealedDescriptorDirectory(
                identity:
                    PortableArtifactIdentity(opened),
                sealedMode:
                    Self.permissionMode(opened),
                restoreMode: restoreMode,
                modifiedSeconds:
                    Int64(
                        opened.st_mtimespec.tv_sec
                    ),
                modifiedNanoseconds:
                    Int64(
                        opened.st_mtimespec.tv_nsec
                    ),
                changedSeconds:
                    Int64(
                        opened.st_ctimespec.tv_sec
                    ),
                changedNanoseconds:
                    Int64(
                        opened.st_ctimespec.tv_nsec
                    )
            )
        }

        private func appendSealedRegularFiles(
            rootDescriptor: Int32,
            expected: [String: stat],
            into result: inout [RegularFileSeal]
        ) throws {
            for path in expected.keys.sorted() {
                guard let expectedStatus = expected[path],
                      isRegular(expectedStatus),
                      expectedStatus.st_nlink == 1 else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                let descriptor = try openManagedRegularFile(
                    rootDescriptor: rootDescriptor,
                    path: path,
                    writable: false
                )
                do {
                    var opened = stat()
                    guard Darwin.fstat(
                            descriptor,
                            &opened
                          ) == 0,
                          sameManagedEntry(
                            opened,
                            expectedStatus
                          ) else {
                        throw PortablePackageCleanupError
                            .unsafeTarget
                    }
                    let currentMode =
                        Self.permissionMode(opened)
                    guard currentMode == 0o400
                            || currentMode == 0o600
                            || currentMode == 0o444
                            || currentMode == 0o644 else {
                        throw PortablePackageCleanupError
                            .unsafeTarget
                    }
                    if currentMode != 0o600 {
                        guard Darwin.fchmod(
                                descriptor,
                                mode_t(0o600)
                              ) == 0,
                              Darwin.fsync(descriptor)
                                == 0 else {
                            throw PortablePackageCleanupError
                                .cleanupRequired
                        }
                        var normalized = stat()
                        guard Darwin.fstat(
                                descriptor,
                                &normalized
                              ) == 0,
                              sameFile(opened, normalized),
                              isRegular(normalized),
                              normalized.st_nlink == 1,
                              Self.permissionMode(
                                normalized
                              ) == 0o600 else {
                            throw PortablePackageCleanupError
                                .unsafeTarget
                        }
                        opened = normalized
                    }
                    let restoreMode: UInt32 = 0o600
                    guard Darwin.fchmod(
                            descriptor,
                            mode_t(0o400)
                          ) == 0,
                          Darwin.fsync(descriptor) == 0 else {
                        throw PortablePackageCleanupError
                            .cleanupRequired
                    }
                    var sealed = stat()
                    guard Darwin.fstat(
                            descriptor,
                            &sealed
                          ) == 0,
                          sameFile(opened, sealed),
                          isRegular(sealed),
                          sealed.st_nlink == 1 else {
                        throw PortablePackageCleanupError
                            .unsafeTarget
                    }
                    let digest = try stableSHA256(
                        descriptor: descriptor,
                        expected: sealed
                    )
                    result.append(
                        RegularFileSeal(
                            path: path,
                            identity:
                                PortableArtifactIdentity(
                                    sealed
                                ),
                            byteCount:
                                Int64(sealed.st_size),
                            sealedMode:
                                Self.permissionMode(sealed),
                            restoreMode: restoreMode,
                            modifiedSeconds:
                                Int64(
                                    sealed.st_mtimespec
                                        .tv_sec
                                ),
                            modifiedNanoseconds:
                                Int64(
                                    sealed.st_mtimespec
                                        .tv_nsec
                                ),
                            changedSeconds:
                                Int64(
                                    sealed.st_ctimespec
                                        .tv_sec
                                ),
                            changedNanoseconds:
                                Int64(
                                    sealed.st_ctimespec
                                        .tv_nsec
                                ),
                            sha256Hex: digest
                        )
                    )
                    Darwin.close(descriptor)
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
            }
        }

        private func verifyRegularFileSeals(
            rootDescriptor: Int32,
            seals: [RegularFileSeal]
        ) throws {
            for seal in seals {
                let descriptor = try openManagedRegularFile(
                    rootDescriptor: rootDescriptor,
                    path: seal.path,
                    writable: false
                )
                do {
                    var opened = stat()
                    guard Darwin.fstat(
                            descriptor,
                            &opened
                          ) == 0,
                          sealMatches(
                            seal,
                            status: opened
                          ),
                          try stableSHA256(
                            descriptor: descriptor,
                            expected: opened
                          ) == seal.sha256Hex else {
                        throw PortablePackageCleanupError
                            .unsafeTarget
                    }
                    Darwin.close(descriptor)
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
            }
        }

        private func restoreRegularFilePermissions(
            rootDescriptor: Int32,
            seals: [RegularFileSeal],
            fallbackPaths: [String]
        ) throws {
            let sealedByPath = Dictionary(
                uniqueKeysWithValues:
                    seals.map { ($0.path, $0) }
            )
            let paths = sealedByPath.isEmpty
                ? fallbackPaths : sealedByPath.keys.sorted()
            for path in paths {
                let descriptor = try openManagedRegularFile(
                    rootDescriptor: rootDescriptor,
                    path: path,
                    writable: false
                )
                do {
                    var opened = stat()
                    guard Darwin.fstat(
                            descriptor,
                            &opened
                          ) == 0,
                          isRegular(opened),
                          opened.st_nlink == 1,
                          sealedByPath[path].map({
                              $0.identity.matches(opened)
                          }) ?? true else {
                        throw PortablePackageCleanupError
                            .unsafeTarget
                    }
                    let restoreMode =
                        sealedByPath[path]?.restoreMode
                        ?? 0o600
                    if sealedByPath[path] == nil {
                        let currentMode =
                            Self.permissionMode(opened)
                        guard currentMode == 0o400
                                || currentMode == 0o600 else {
                            throw PortablePackageCleanupError
                                .unsafeTarget
                        }
                    }
                    guard Darwin.fchmod(
                            descriptor,
                            mode_t(restoreMode)
                          ) == 0,
                          Darwin.fsync(descriptor) == 0 else {
                        throw PortablePackageCleanupError
                            .cleanupRequired
                    }
                    Darwin.close(descriptor)
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
            }
        }

        private func sealMatches(
            _ seal: RegularFileSeal,
            status: stat
        ) -> Bool {
            isRegular(status)
                && status.st_nlink == 1
                && seal.identity.matches(status)
                && Int64(status.st_size)
                    == seal.byteCount
                && Self.permissionMode(status)
                    == seal.sealedMode
                && Int64(
                    status.st_mtimespec.tv_sec
                ) == seal.modifiedSeconds
                && Int64(
                    status.st_mtimespec.tv_nsec
                ) == seal.modifiedNanoseconds
                && Int64(
                    status.st_ctimespec.tv_sec
                ) == seal.changedSeconds
                && Int64(
                    status.st_ctimespec.tv_nsec
                ) == seal.changedNanoseconds
        }

        private func stableSHA256(
            descriptor: Int32,
            expected: stat
        ) throws -> String {
            guard isRegular(expected),
                  expected.st_nlink == 1,
                  expected.st_size >= 0,
                  expected.st_size <= off_t(
                    PortableBackupLimits
                        .maximumTotalBytes
                  ) else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            var hasher = SHA256()
            var buffer = [UInt8](
                repeating: 0,
                count: 64 * 1_024
            )
            var offset: off_t = 0
            while offset < expected.st_size {
                let requested = min(
                    buffer.count,
                    Int(expected.st_size - offset)
                )
                let count = buffer.withUnsafeMutableBytes {
                    bytes in
                    Darwin.pread(
                        descriptor,
                        bytes.baseAddress,
                        requested,
                        offset
                    )
                }
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw PortablePackageCleanupError
                        .cleanupRequired
                }
                hasher.update(
                    data: Data(buffer.prefix(count))
                )
                offset += off_t(count)
            }
            var final = stat()
            guard offset == expected.st_size,
                  Darwin.fstat(
                    descriptor,
                    &final
                  ) == 0,
                  sameSealedMetadata(
                    expected,
                    final
                  ) else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            return hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        }

        private func sameSealedMetadata(
            _ lhs: stat,
            _ rhs: stat
        ) -> Bool {
            sameFile(lhs, rhs)
                && isRegular(lhs)
                && isRegular(rhs)
                && lhs.st_nlink == 1
                && rhs.st_nlink == 1
                && lhs.st_size == rhs.st_size
                && Self.permissionMode(lhs)
                    == Self.permissionMode(rhs)
                && lhs.st_mtimespec.tv_sec
                    == rhs.st_mtimespec.tv_sec
                && lhs.st_mtimespec.tv_nsec
                    == rhs.st_mtimespec.tv_nsec
                && lhs.st_ctimespec.tv_sec
                    == rhs.st_ctimespec.tv_sec
                && lhs.st_ctimespec.tv_nsec
                    == rhs.st_ctimespec.tv_nsec
        }

        private func openManagedDirectory(
            rootDescriptor: Int32,
            path: String
        ) throws -> Int32 {
            let components = path.split(
                separator: "/"
            ).map(String.init)
            guard !components.isEmpty,
                  components.allSatisfy(
                    PortableManagedPathSecurity
                        .isSafeComponent
                  ) else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            var current = rootDescriptor
            var ownsCurrent = false
            do {
                for component in components {
                    guard let next = try PortableManagedPathSecurity
                        .openDirectory(
                        at: current,
                        component: component,
                        allowMissing: false
                    ) else {
                        throw PortablePackageCleanupError
                            .unsafeTarget
                    }
                    if ownsCurrent {
                        Darwin.close(current)
                    }
                    current = next
                    ownsCurrent = true
                }
                return current
            } catch {
                if ownsCurrent {
                    Darwin.close(current)
                }
                throw error
            }
        }

        private func openManagedRegularFile(
            rootDescriptor: Int32,
            path: String,
            writable: Bool
        ) throws -> Int32 {
            let components = path.split(
                separator: "/"
            ).map(String.init)
            guard let leaf = components.last,
                  components.allSatisfy(
                    PortableManagedPathSecurity
                        .isSafeComponent
                  ) else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            var parent = rootDescriptor
            var ownsParent = false
            do {
                for component in components.dropLast() {
                    guard let next = try PortableManagedPathSecurity
                        .openDirectory(
                        at: parent,
                        component: component,
                        allowMissing: false
                    ) else {
                        throw PortablePackageCleanupError
                            .unsafeTarget
                    }
                    if ownsParent {
                        Darwin.close(parent)
                    }
                    parent = next
                    ownsParent = true
                }
                let descriptor = leaf.withCString {
                    Darwin.openat(
                        parent,
                        $0,
                        (writable ? O_RDWR : O_RDONLY)
                            | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                if ownsParent {
                    Darwin.close(parent)
                    ownsParent = false
                }
                guard descriptor >= 0 else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                return descriptor
            } catch {
                if ownsParent {
                    Darwin.close(parent)
                }
                throw error
            }
        }

        func installAttachments(
            from package: AuditedPortableBackup,
            operationID: UUID
        ) throws {
            try verifyPublished()
            try sanitizeManagedDirectory(
                descriptor: filesDescriptor
            )
            let stagingFD = try createChildDirectory(
                at: filesDescriptor,
                component: ".staging",
                backupPolicy: .systemManaged
            )
            Darwin.close(stagingFD)
            let trashFD = try createChildDirectory(
                at: filesDescriptor,
                component: ".trash",
                backupPolicy: .systemManaged
            )
            Darwin.close(trashFD)
            let attachmentsFD = try createChildDirectory(
                at: filesDescriptor,
                component: "Attachments",
                backupPolicy: .systemManaged
            )
            defer { Darwin.close(attachmentsFD) }

            let attachmentRecords = Dictionary(
                uniqueKeysWithValues:
                    package.readableDocument.payload.records
                    .filter {
                        $0.modelType == "AttachmentRecord"
                    }
                    .map { ($0.recordID, $0) }
            )
            for attachment in package.readableDocument
                .payload.activeAttachments {
                guard let record =
                        attachmentRecords[
                            attachment.attachmentID
                        ],
                      let relativePathField =
                        record.fields.first(
                            where: {
                                $0.name == "relativePath"
                            }
                        ),
                      case let .string(relativePath) =
                        try relativePathField.value
                            .recordDigestValue(),
                      relativePath
                        == AttachmentPathFacts.relativePath(
                            attachmentID:
                                attachment.attachmentID,
                            typeIdentifier:
                                attachment.typeIdentifier
                        ) else {
                    throw PortableRestoreServiceError
                        .targetInvalid
                }
                let components = relativePath.split(
                    separator: "/",
                    omittingEmptySubsequences: false
                )
                guard components.count == 3,
                      components[0] == "Attachments",
                      components[1] == Substring(
                        attachment.attachmentID
                            .uuidString.lowercased()
                      ) else {
                    throw PortableRestoreServiceError
                        .targetInvalid
                }
                let payload = try PortableBackupFileAudit
                    .boundedData(
                        package.packageURL.appending(
                            path:
                                attachment.packageRelativePath
                        ),
                        maximumBytes: Int(
                            AttachmentFileStore
                                .maximumFileBytes
                        )
                    )
                guard Int64(payload.count)
                        == attachment.byteCount,
                      PortableBackupFileAudit.sha256Hex(
                        payload
                      ) == attachment.sha256Hex else {
                    throw PortableBackupError
                        .attachmentMismatch
                }
                let attachmentFD = try createChildDirectory(
                    at: attachmentsFD,
                    component: String(components[1]),
                    backupPolicy: .systemManaged
                )
                do {
                    try createChildFile(
                        at: attachmentFD,
                        component: String(components[2]),
                        data: payload,
                        maximumBytes: Int(
                            AttachmentFileStore
                                .maximumFileBytes
                        ),
                        backupPolicy: .systemManaged
                    )
                    guard Darwin.fsync(attachmentFD) == 0
                    else {
                        throw PortablePackageCleanupError
                            .cleanupRequired
                    }
                    Darwin.close(attachmentFD)
                } catch {
                    Darwin.close(attachmentFD)
                    throw error
                }
            }
            guard Darwin.fsync(attachmentsFD) == 0,
                  Darwin.fsync(filesDescriptor) == 0 else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
            _ = operationID
            try validateAttachments(
                package.readableDocument.payload
                    .activeAttachments
            )
            try verifyPublished()
        }

        func validateAttachments(
            _ attachments: [PortableDataAttachment]
        ) throws {
            let rootNames = try directoryEntries(
                descriptor: filesDescriptor,
                maximumEntries: 3
            )
            guard Set(rootNames) == [
                ".staging", ".trash", "Attachments"
            ] else {
                throw PortableRestoreServiceError
                    .targetInvalid
            }
            for emptyName in [".staging", ".trash"] {
                let emptyFD = try openVerifiedChildDirectory(
                    at: filesDescriptor,
                    component: emptyName
                )
                defer { Darwin.close(emptyFD) }
                guard try directoryEntries(
                    descriptor: emptyFD,
                    maximumEntries: 0
                ).isEmpty else {
                    throw PortableRestoreServiceError
                        .targetInvalid
                }
            }
            let attachmentsFD =
                try openVerifiedChildDirectory(
                    at: filesDescriptor,
                    component: "Attachments"
                )
            defer { Darwin.close(attachmentsFD) }
            let expectedNames = Set(
                attachments.map {
                    $0.attachmentID.uuidString
                        .lowercased()
                }
            )
            guard Set(try directoryEntries(
                descriptor: attachmentsFD,
                maximumEntries:
                    PortableBackupLimits
                    .maximumAttachmentCount
            )) == expectedNames else {
                throw PortableRestoreServiceError
                    .targetInvalid
            }
            for attachment in attachments {
                guard let relativePath =
                    AttachmentPathFacts.relativePath(
                        attachmentID:
                            attachment.attachmentID,
                        typeIdentifier:
                            attachment.typeIdentifier
                    ) else {
                    throw PortableRestoreServiceError
                        .targetInvalid
                }
                let leaf = String(
                    relativePath.split(separator: "/").last!
                )
                let attachmentFD =
                    try openVerifiedChildDirectory(
                        at: attachmentsFD,
                        component:
                            attachment.attachmentID
                            .uuidString.lowercased()
                    )
                do {
                    guard try directoryEntries(
                        descriptor: attachmentFD,
                        maximumEntries: 1
                    ) == [leaf],
                    let data = try readRegularFile(
                        at: attachmentFD,
                        component: leaf,
                        maximumBytes: Int(
                            AttachmentFileStore
                                .maximumFileBytes
                        )
                    ),
                    Int64(data.count)
                        == attachment.byteCount,
                    PortableBackupFileAudit.sha256Hex(
                        data
                    ) == attachment.sha256Hex else {
                        throw PortableRestoreServiceError
                            .targetInvalid
                    }
                    Darwin.close(attachmentFD)
                } catch {
                    Darwin.close(attachmentFD)
                    throw error
                }
            }
        }

        private func bindDatabaseBundle() throws {
            let allowed: Set<String> = [
                "user.sqlite",
                "user.sqlite-wal",
                "user.sqlite-shm"
            ]
            let names = try directoryEntries(
                descriptor: storeDescriptor,
                maximumEntries: 3
            )
            guard names.contains("user.sqlite"),
                  Set(names).isSubset(of: allowed) else {
                throw PortablePackageCleanupError.unsafeTarget
            }
            var values:
                [String: PortableArtifactIdentity] = [:]
            for name in names {
                guard let published = try entryStatus(
                    at: storeDescriptor,
                    component: name,
                    allowMissing: false
                ),
                isRegular(published),
                published.st_nlink == 1 else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                values[name] =
                    PortableArtifactIdentity(published)
            }
            databaseBundle = values
        }

        private static func status(
            _ descriptor: Int32
        ) throws -> stat {
            var value = stat()
            guard Darwin.fstat(descriptor, &value) == 0 else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
            return value
        }

        private static func permissionMode(
            _ value: stat
        ) -> UInt32 {
            UInt32(value.st_mode) & 0o7777
        }

        private static func ancestryIdentitiesMatch(
            _ ancestry: PortableRestoreTargetAncestry,
            statuses: [stat]
        ) -> Bool {
            let identities = [
                ancestry.containerParent,
                ancestry.root,
                ancestry.generations,
                ancestry.target,
                ancestry.store,
                ancestry.files
            ]
            return statuses.count == identities.count
                && zip(identities, statuses)
                    .allSatisfy { $0.matches($1) }
        }

        private static func currentModesAreExpectedOrShielded(
            statuses: [stat],
            ancestry: PortableRestoreTargetAncestry
        ) -> Bool {
            guard statuses.count
                    == ancestry.allModes.count else {
                return false
            }
            return zip(
                statuses,
                ancestry.allModes
            ).allSatisfy {
                let current = permissionMode($0.0)
                let original = $0.1
                return current == original
                    || current == (original & ~0o222)
            }
        }
    }

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

    static func createTransferPackageRoot(
        transferRootURL: URL,
        packageName: String
    ) throws -> PortableArtifactIdentity {
        try createTransferPackageRootLease(
            transferRootURL: transferRootURL,
            packageName: packageName
        ).identity
    }

    static func createTransferPackageRootLease(
        transferRootURL: URL,
        packageName: String,
        beforeOpenRoot: MutationProbe = {}
    ) throws -> PortablePackageDirectoryLease {
        guard isSafeComponent(packageName) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        let createResult = Darwin.mkdir(
            transferRootURL.path,
            S_IRWXU
        )
        let didCreateRoot = createResult == 0
        if createResult != 0, errno != EEXIST {
            throw PortablePackageCleanupError.cleanupRequired
        }
        try beforeOpenRoot()
        guard let rootFD = try openDirectory(
            at: AT_FDCWD,
            component: transferRootURL.path,
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError.cleanupRequired
        }
        var ownsRootFD = true
        defer {
            if ownsRootFD {
                Darwin.close(rootFD)
            }
        }
        var rootStatus = stat()
        guard Darwin.fstat(rootFD, &rootStatus) == 0,
              isDirectory(rootStatus) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        try applyCompleteProtection(descriptor: rootFD)
        try applyBackupPolicy(
            .excluded,
            descriptor: rootFD
        )
        if didCreateRoot {
            guard let rootParentFD = try openDirectory(
                at: AT_FDCWD,
                component: transferRootURL
                    .deletingLastPathComponent().path,
                allowMissing: false
            ) else {
                throw PortablePackageCleanupError.cleanupRequired
            }
            defer { Darwin.close(rootParentFD) }
            guard Darwin.fsync(rootParentFD) == 0 else {
                throw PortablePackageCleanupError.cleanupRequired
            }
        }
        guard try entryStatus(
            at: rootFD,
            component: packageName,
            allowMissing: true
        ) == nil,
        packageName.withCString({
            Darwin.mkdirat(rootFD, $0, S_IRWXU)
        }) == 0,
        Darwin.fsync(rootFD) == 0,
        let packageFD = try openDirectory(
            at: rootFD,
            component: packageName,
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError.cleanupRequired
        }
        var ownsPackageFD = true
        defer {
            if ownsPackageFD {
                Darwin.close(packageFD)
            }
        }
        var status = stat()
        guard Darwin.fstat(packageFD, &status) == 0,
              isDirectory(status),
              let published = try entryStatus(
                at: rootFD,
                component: packageName,
                allowMissing: false
              ),
              sameFile(published, status) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        try applyCompleteProtection(descriptor: packageFD)
        try applyBackupPolicy(
            .excluded,
            descriptor: packageFD
        )
        guard Darwin.fsync(packageFD) == 0,
              Darwin.fsync(rootFD) == 0 else {
            throw PortablePackageCleanupError.cleanupRequired
        }
        let lease = PortablePackageDirectoryLease(
            packageURL: transferRootURL.appending(
                path: packageName,
                directoryHint: .isDirectory
            ),
            transferRootURL: transferRootURL,
            transferRootIdentity:
                PortableArtifactIdentity(rootStatus),
            parentDescriptor: rootFD,
            packageDescriptor: packageFD,
            packageName: packageName,
            identity: PortableArtifactIdentity(status)
        )
        try lease.verifyPublished()
        ownsPackageFD = false
        ownsRootFD = false
        return lease
    }

    static func directoryIdentity(
        at url: URL
    ) throws -> PortableArtifactIdentity {
        guard let descriptor = try openDirectory(
            at: AT_FDCWD,
            component: url.path,
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              isDirectory(status) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        return PortableArtifactIdentity(status)
    }

    static func verifyDirectoryIdentity(
        at url: URL,
        expectedIdentity: PortableArtifactIdentity?
    ) throws {
        guard let expectedIdentity,
              try directoryIdentity(at: url)
                == expectedIdentity else {
            throw PortablePackageCleanupError.unsafeTarget
        }
    }

    /// Recovers only the exact empty directory that this process can leave
    /// between durable intent registration and durable identity binding.
    static func recoverUnboundTransferIdentity(
        transferRootURL: URL,
        packageName: String
    ) throws -> (
        anchor: PortableArtifactIdentity,
        package: PortableArtifactIdentity
    )? {
        guard isSafeComponent(packageName),
              let rootFD = try openDirectory(
                at: AT_FDCWD,
                component: transferRootURL.path,
                allowMissing: true
              ) else {
            if !isSafeComponent(packageName) {
                throw PortablePackageCleanupError.unsafeTarget
            }
            return nil
        }
        defer { Darwin.close(rootFD) }
        var rootOpened = stat()
        guard Darwin.fstat(rootFD, &rootOpened) == 0,
              isDirectory(rootOpened) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        guard let published = try entryStatus(
            at: rootFD,
            component: packageName,
            allowMissing: true
        ) else {
            return nil
        }
        guard isDirectory(published),
              let descriptor = try openDirectory(
                at: rootFD,
                component: packageName,
                allowMissing: false
              ) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              sameFile(published, opened),
              try directoryEntries(
                descriptor: descriptor,
                maximumEntries: 0
              ).isEmpty else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        return (
            anchor: PortableArtifactIdentity(rootOpened),
            package: PortableArtifactIdentity(opened)
        )
    }

    /// Restores identity binding only for the two exact partial shapes created
    /// by restore staging: an empty operation directory, or that directory
    /// containing one empty `package.unmanualbackup` directory.
    static func recoverUnboundRestoreIdentities(
        layout: AppDataStoreLayout,
        operationID: UUID
    ) throws -> (
        anchor: PortableArtifactIdentity,
        root: PortableArtifactIdentity,
        package: PortableArtifactIdentity
    )? {
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
        guard let stagingFD = try openDirectory(
            at: recoveryFD,
            component: "PortableImports",
            allowMissing: true
        ) else {
            return nil
        }
        defer { Darwin.close(stagingFD) }
        var stagingOpened = stat()
        guard Darwin.fstat(stagingFD, &stagingOpened) == 0,
              isDirectory(stagingOpened) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        let operationName =
            operationID.uuidString.lowercased()
        guard let published = try entryStatus(
            at: stagingFD,
            component: operationName,
            allowMissing: true
        ) else {
            return nil
        }
        guard isDirectory(published),
              let operationFD = try openDirectory(
                at: stagingFD,
                component: operationName,
                allowMissing: false
              ) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        defer { Darwin.close(operationFD) }
        var openedOperation = stat()
        guard Darwin.fstat(
            operationFD,
            &openedOperation
        ) == 0,
        sameFile(published, openedOperation) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        let children = try directoryEntries(
            descriptor: operationFD,
            maximumEntries: 1
        )
        guard children.isEmpty
                || children == ["package.unmanualbackup"] else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        let operationIdentity =
            PortableArtifactIdentity(openedOperation)
        guard !children.isEmpty else {
            return (
                anchor:
                    PortableArtifactIdentity(stagingOpened),
                root: operationIdentity,
                package: operationIdentity
            )
        }
        guard let packagePublished = try entryStatus(
            at: operationFD,
            component: "package.unmanualbackup",
            allowMissing: false
        ),
        isDirectory(packagePublished),
        let packageFD = try openDirectory(
            at: operationFD,
            component: "package.unmanualbackup",
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        defer { Darwin.close(packageFD) }
        var openedPackage = stat()
        guard Darwin.fstat(packageFD, &openedPackage) == 0,
              sameFile(packagePublished, openedPackage),
              try directoryEntries(
                descriptor: packageFD,
                maximumEntries: 0
              ).isEmpty else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        return (
            anchor:
                PortableArtifactIdentity(stagingOpened),
            root: operationIdentity,
            package: PortableArtifactIdentity(openedPackage)
        )
    }

    static func createOrResumeEmptyGenerationRoot(
        generationsURL: URL,
        generationName: String
    ) throws -> PortableArtifactIdentity {
        guard isSafeComponent(generationName),
              let generationsFD = try openDirectory(
                at: AT_FDCWD,
                component: generationsURL.path,
                allowMissing: false
              ) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        defer { Darwin.close(generationsFD) }
        if try entryStatus(
            at: generationsFD,
            component: generationName,
            allowMissing: true
        ) == nil {
            guard generationName.withCString({
                Darwin.mkdirat(
                    generationsFD,
                    $0,
                    S_IRWXU
                )
            }) == 0,
            Darwin.fsync(generationsFD) == 0 else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
        }
        guard let published = try entryStatus(
            at: generationsFD,
            component: generationName,
            allowMissing: false
        ),
        isDirectory(published),
        let generationFD = try openDirectory(
            at: generationsFD,
            component: generationName,
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        defer { Darwin.close(generationFD) }
        var opened = stat()
        guard Darwin.fstat(generationFD, &opened) == 0,
              sameFile(published, opened) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        let children = try directoryEntries(
            descriptor: generationFD,
            maximumEntries: 1
        )
        let storeFD: Int32
        if children.isEmpty {
            storeFD = try createChildDirectory(
                at: generationFD,
                component: "Store",
                backupPolicy: .systemManaged
            )
        } else {
            guard children == ["Store"] else {
                throw PortablePackageCleanupError.unsafeTarget
            }
            storeFD = try openVerifiedChildDirectory(
                at: generationFD,
                component: "Store"
            )
        }
        defer { Darwin.close(storeFD) }
        guard try directoryEntries(
            descriptor: storeFD,
            maximumEntries: 0
        ).isEmpty else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        try applyCompleteProtection(descriptor: generationFD)
        try applyCompleteProtection(descriptor: storeFD)
        guard Darwin.fsync(storeFD) == 0,
              Darwin.fsync(generationFD) == 0,
              Darwin.fsync(generationsFD) == 0 else {
            throw PortablePackageCleanupError.cleanupRequired
        }
        return PortableArtifactIdentity(opened)
    }

    /// Clears an inactive generation without changing its journal-bound root
    /// inode. A crash at any point can safely retry this operation against the
    /// same identity.
    static func resetGenerationRootContents(
        generationsURL: URL,
        generationName: String,
        expectedIdentity: PortableArtifactIdentity?,
        afterContentsRemoved: MutationProbe = {}
    ) throws -> PortableArtifactIdentity {
        guard isSafeComponent(generationName),
              let expectedIdentity,
              let generationsFD = try openDirectory(
                at: AT_FDCWD,
                component: generationsURL.path,
                allowMissing: false
              ) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        defer { Darwin.close(generationsFD) }
        guard let published = try entryStatus(
            at: generationsFD,
            component: generationName,
            allowMissing: false
        ),
        isDirectory(published),
        expectedIdentity.matches(published),
        let generationFD = try openDirectory(
            at: generationsFD,
            component: generationName,
            allowMissing: false
        ) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        defer { Darwin.close(generationFD) }
        var opened = stat()
        guard Darwin.fstat(generationFD, &opened) == 0,
              isDirectory(opened),
              sameFile(published, opened),
              expectedIdentity.matches(opened) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        let snapshot = try preflightTree(
            descriptor: generationFD
        )
        try makeManagedDirectoriesOwnerWritable(
            descriptor: generationFD,
            snapshot: snapshot
        )
        try verifyTree(
            descriptor: generationFD,
            snapshot: snapshot
        )
        try removeTreeContents(
            descriptor: generationFD,
            snapshot: snapshot
        )
        guard Darwin.fsync(generationFD) == 0,
              Darwin.fsync(generationsFD) == 0 else {
            throw PortablePackageCleanupError.cleanupRequired
        }
        try afterContentsRemoved()
        guard try directoryEntries(
            descriptor: generationFD,
            maximumEntries: 0
        ).isEmpty else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        let storeFD = try createChildDirectory(
            at: generationFD,
            component: "Store",
            backupPolicy: .systemManaged
        )
        Darwin.close(storeFD)
        try applyCompleteProtection(descriptor: generationFD)
        guard Darwin.fsync(generationFD) == 0,
              Darwin.fsync(generationsFD) == 0,
              let finalPublished = try entryStatus(
                  at: generationsFD,
                  component: generationName,
                  allowMissing: false
              ),
              sameFile(opened, finalPublished),
              expectedIdentity.matches(finalPublished) else {
            throw PortablePackageCleanupError.cleanupRequired
        }
        return expectedIdentity
    }

    static func readRecoveryRegularFileIfPresent(
        layout: AppDataStoreLayout,
        fileName: String,
        maximumBytes: Int,
        validator: (Data) -> Bool = { _ in true }
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
        do {
            return try AtomicControlFileTransaction
                .reconcile(
                    parentDescriptor: recoveryFD,
                    destinationName: fileName,
                    maximumBytes: maximumBytes,
                    validator: validator
                )
        } catch {
            throw PortablePackageCleanupError
                .unsafeTarget
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
        beforeWrite: MutationProbe = {},
        afterPublish: MutationProbe = {},
        validator: (Data) -> Bool = { _ in true }
    ) throws -> Data {
        try AtomicControlFileTransaction.locked {
            try writeRecoveryRegularFileUnlocked(
                layout: layout,
                fileName: fileName,
                data: data,
                maximumBytes: maximumBytes,
                backupPolicy: backupPolicy,
                beforeWrite: beforeWrite,
                afterPublish: afterPublish,
                validator: validator
            )
        }
    }

    private static func writeRecoveryRegularFileUnlocked(
        layout: AppDataStoreLayout,
        fileName: String,
        data: Data,
        maximumBytes: Int,
        backupPolicy: SystemBackupPolicy,
        beforeWrite: MutationProbe,
        afterPublish: MutationProbe,
        validator: (Data) -> Bool
    ) throws -> Data {
        guard isSafeComponent(fileName),
              data.count <= maximumBytes,
              validator(data) else {
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

        do {
            _ = try AtomicControlFileTransaction
                .reconcile(
                    parentDescriptor: recoveryFD,
                    destinationName: fileName,
                    maximumBytes: maximumBytes,
                    validator: validator
                )
        } catch {
            throw PortablePackageCleanupError
                .unsafeTarget
        }

        try beforeWrite()
        try verifyRecoveryAncestry(
            layout: layout,
            rootIdentity: rootIdentity,
            recoveryIdentity: recoveryIdentity
        )

        let existingStatus = try entryStatus(
            at: recoveryFD,
            component: fileName,
            allowMissing: true
        )
        if let existingStatus,
           !isRegular(existingStatus)
                || existingStatus.st_nlink != 1 {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        let existingDescriptor: Int32?
        if let existingStatus {
            let openedExisting = fileName.withCString {
                Darwin.openat(
                    recoveryFD,
                    $0,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard openedExisting >= 0 else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
            var openedExistingStatus = stat()
            guard Darwin.fstat(
                    openedExisting,
                    &openedExistingStatus
                  ) == 0,
                  sameFile(
                    existingStatus,
                    openedExistingStatus
                  ),
                  openedExistingStatus.st_nlink == 1 else {
                Darwin.close(openedExisting)
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            existingDescriptor = openedExisting
        } else {
            existingDescriptor = nil
        }
        defer {
            if let existingDescriptor {
                Darwin.close(existingDescriptor)
            }
        }
        let previousData: Data?
        if let existingDescriptor,
           let existingStatus {
            previousData = try readRegularFile(
                descriptor: existingDescriptor,
                expected: existingStatus,
                maximumBytes: maximumBytes
            )
        } else {
            previousData = nil
        }
        let rollbackName: String?
        let rollbackDescriptor: Int32?
        let rollbackIdentity: stat?
        if let previousData {
            let rollback = try makeRecoveryRollback(
                data: previousData,
                recoveryFD: recoveryFD,
                fileName: fileName,
                maximumBytes: maximumBytes,
                backupPolicy: backupPolicy
            )
            rollbackName = rollback.name
            rollbackDescriptor = rollback.descriptor
            rollbackIdentity = rollback.identity
        } else {
            rollbackName = nil
            rollbackDescriptor = nil
            rollbackIdentity = nil
        }
        var removeRollbackOnExit = true
        defer {
            if let rollbackDescriptor {
                Darwin.close(rollbackDescriptor)
            }
            if removeRollbackOnExit,
               let rollbackName,
               let rollbackIdentity {
                removeRecoveryEntryIfPublished(
                    name: rollbackName,
                    identity: rollbackIdentity,
                    recoveryFD: recoveryFD
                )
            }
        }
        let temporaryName =
            AtomicControlFileTransaction.newName(
                destinationName: fileName,
                data: data
            )
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                recoveryFD,
                $0,
                O_RDWR | O_CREAT | O_EXCL
                    | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        var temporaryExists = true
        var temporaryContainsPrevious = false
        var destinationPublished = false
        var commitVerified = false
        defer {
            Darwin.close(descriptor)
            if temporaryExists,
               !temporaryContainsPrevious {
                _ = temporaryName.withCString {
                    Darwin.unlinkat(recoveryFD, $0, 0)
                }
            }
        }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              isRegular(opened),
              opened.st_nlink == 1 else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        do {
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
            var temporaryPublished = stat()
            guard temporaryName.withCString({
                Darwin.fstatat(
                    recoveryFD,
                    $0,
                    &temporaryPublished,
                    AT_SYMLINK_NOFOLLOW
                )
            }) == 0,
            sameFile(opened, temporaryPublished),
            temporaryPublished.st_nlink == 1,
            temporaryPublished.st_size == off_t(data.count)
            else {
                throw PortablePackageCleanupError.unsafeTarget
            }
            try verifyRecoveryAncestry(
                layout: layout,
                rootIdentity: rootIdentity,
                recoveryIdentity: recoveryIdentity
            )
            let renamed: Int32
            if existingDescriptor != nil {
                renamed = temporaryName.withCString {
                    source in
                    fileName.withCString {
                        destination in
                        Darwin.renameatx_np(
                            recoveryFD,
                            source,
                            recoveryFD,
                            destination,
                            UInt32(RENAME_SWAP)
                        )
                    }
                }
            } else {
                renamed = temporaryName.withCString {
                    source in
                    fileName.withCString {
                        destination in
                        Darwin.renameatx_np(
                            recoveryFD,
                            source,
                            recoveryFD,
                            destination,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
            }
            guard renamed == 0 else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
            temporaryExists = existingDescriptor != nil
            temporaryContainsPrevious =
                existingDescriptor != nil
            destinationPublished = true
            guard Darwin.fsync(recoveryFD) == 0 else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
            try afterPublish()
            var finalOpened = stat()
            var finalPublished = stat()
            guard Darwin.fstat(
                    descriptor,
                    &finalOpened
                  ) == 0,
                  fileName.withCString({
                      Darwin.fstatat(
                          recoveryFD,
                          $0,
                          &finalPublished,
                          AT_SYMLINK_NOFOLLOW
                      )
                  }) == 0,
                  sameFile(opened, finalOpened),
                  sameFile(finalOpened, finalPublished),
                  finalOpened.st_nlink == 1,
                  finalOpened.st_size
                    == off_t(data.count),
                  Darwin.fsync(recoveryFD) == 0,
                  try readRegularFile(
                    descriptor: descriptor,
                    expected: finalOpened,
                    maximumBytes: maximumBytes
                  ) == data else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
            try verifyRecoveryAncestry(
                layout: layout,
                rootIdentity: rootIdentity,
                recoveryIdentity: recoveryIdentity
            )
            commitVerified = true
            if let rollbackName,
               let rollbackIdentity {
                try discardRecoveryEntry(
                    name: rollbackName,
                    identity: rollbackIdentity,
                    recoveryFD: recoveryFD
                )
                removeRollbackOnExit = false
            }
            if let existingDescriptor {
                var priorOpened = stat()
                var priorPublished = stat()
                guard Darwin.fstat(
                        existingDescriptor,
                        &priorOpened
                      ) == 0,
                      temporaryName.withCString({
                          Darwin.fstatat(
                              recoveryFD,
                              $0,
                              &priorPublished,
                              AT_SYMLINK_NOFOLLOW
                          )
                      }) == 0,
                      sameFile(
                        priorOpened,
                        priorPublished
                      ),
                      priorOpened.st_nlink == 1,
                      temporaryName.withCString({
                          Darwin.unlinkat(
                              recoveryFD,
                              $0,
                              0
                          )
                      }) == 0,
                      Darwin.fsync(recoveryFD) == 0 else {
                    throw PortablePackageCleanupError
                        .cleanupRequired
                }
                temporaryExists = false
                temporaryContainsPrevious = false
            }
            return data
        } catch {
            let originalError = error
            do {
                if !commitVerified,
                   destinationPublished,
                   let previousData,
                   let rollbackName,
                   let rollbackDescriptor,
                   let rollbackIdentity {
                    var currentNew = stat()
                    var currentRollback = stat()
                    var publishedRollback = stat()
                    guard Darwin.fstat(
                            descriptor,
                            &currentNew
                          ) == 0,
                          Darwin.fstat(
                            rollbackDescriptor,
                            &currentRollback
                          ) == 0,
                          rollbackName.withCString({
                              Darwin.fstatat(
                                  recoveryFD,
                                  $0,
                                  &publishedRollback,
                                  AT_SYMLINK_NOFOLLOW
                              )
                          }) == 0,
                          sameFile(
                            rollbackIdentity,
                            currentRollback
                          ),
                          sameFile(
                            currentRollback,
                            publishedRollback
                          ),
                          currentRollback.st_nlink == 1,
                          currentRollback.st_size
                            == off_t(previousData.count),
                          try readRegularFile(
                            descriptor: rollbackDescriptor,
                            expected: currentRollback,
                            maximumBytes: maximumBytes
                          ) == previousData else {
                        removeRollbackOnExit = false
                        temporaryExists = false
                        try? sanitizeWrittenDescriptor(
                            descriptor
                        )
                        throw PortablePackageCleanupError
                            .cleanupRequired
                    }
                    var currentDestination = stat()
                    let destinationResult =
                        fileName.withCString {
                            Darwin.fstatat(
                                recoveryFD,
                                $0,
                                &currentDestination,
                                AT_SYMLINK_NOFOLLOW
                            )
                        }
                    let rollbackNowContainsFailedNew: Bool
                    if destinationResult == 0,
                       sameFile(
                        currentNew,
                        currentDestination
                       ) {
                        guard rollbackName.withCString({
                                source in
                                fileName.withCString {
                                    destination in
                                    Darwin.renameatx_np(
                                        recoveryFD,
                                        source,
                                        recoveryFD,
                                        destination,
                                        UInt32(RENAME_SWAP)
                                    )
                                }
                            }) == 0 else {
                            removeRollbackOnExit = false
                            temporaryExists = false
                            throw PortablePackageCleanupError
                                .cleanupRequired
                        }
                        rollbackNowContainsFailedNew = true
                        removeRollbackOnExit = false
                    } else if destinationResult != 0,
                              errno == ENOENT {
                        guard rollbackName.withCString({
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
                            }) == 0 else {
                            removeRollbackOnExit = false
                            temporaryExists = false
                            throw PortablePackageCleanupError
                                .cleanupRequired
                        }
                        rollbackNowContainsFailedNew = false
                        removeRollbackOnExit = false
                    } else if destinationResult == 0,
                              sameFile(
                                currentRollback,
                                currentDestination
                              ) {
                        rollbackNowContainsFailedNew = false
                        removeRollbackOnExit = false
                    } else {
                        // A foreign replacement is left untouched. The exact
                        // valid rollback remains published for Recovery.
                        removeRollbackOnExit = false
                        temporaryExists = false
                        try? sanitizeWrittenDescriptor(
                            descriptor
                        )
                        throw PortablePackageCleanupError
                            .cleanupRequired
                    }
                    var restoredStatus = stat()
                    guard fileName.withCString({
                              Darwin.fstatat(
                                  recoveryFD,
                                  $0,
                                  &restoredStatus,
                                  AT_SYMLINK_NOFOLLOW
                              )
                          }) == 0,
                          sameFile(
                            currentRollback,
                            restoredStatus
                          ),
                          try readRegularFile(
                            descriptor: rollbackDescriptor,
                            expected: restoredStatus,
                            maximumBytes: maximumBytes
                          ) == previousData,
                          Darwin.fsync(recoveryFD) == 0 else {
                        throw PortablePackageCleanupError
                            .cleanupRequired
                    }
                    try sanitizeWrittenDescriptor(descriptor)
                    if rollbackNowContainsFailedNew {
                        removeRecoveryEntryIfPublished(
                            name: rollbackName,
                            identity: currentNew,
                            recoveryFD: recoveryFD
                        )
                    }
                    if let existingDescriptor {
                        var prior = stat()
                        if Darwin.fstat(
                            existingDescriptor,
                            &prior
                        ) == 0 {
                            removeRecoveryEntryIfPublished(
                                name: temporaryName,
                                identity: prior,
                                recoveryFD: recoveryFD
                            )
                        }
                    }
                    guard Darwin.fsync(recoveryFD) == 0 else {
                        throw PortablePackageCleanupError
                            .cleanupRequired
                    }
                    temporaryExists = false
                    temporaryContainsPrevious = false
                } else if !commitVerified {
                    do {
                        try sanitizeWrittenDescriptor(descriptor)
                    } catch {
                        if !destinationPublished {
                            temporaryExists = false
                        }
                        throw error
                    }
                    if destinationPublished {
                        var published = stat()
                        var currentOpened = stat()
                        guard Darwin.fstat(
                                descriptor,
                                &currentOpened
                              ) == 0 else {
                            throw PortablePackageCleanupError
                                .cleanupRequired
                        }
                        if fileName.withCString({
                            Darwin.fstatat(
                                recoveryFD,
                                $0,
                                &published,
                                AT_SYMLINK_NOFOLLOW
                            )
                        }) == 0,
                        sameFile(currentOpened, published) {
                            guard fileName.withCString({
                                Darwin.unlinkat(
                                    recoveryFD,
                                    $0,
                                    0
                                )
                            }) == 0,
                            Darwin.fsync(recoveryFD) == 0 else {
                                throw PortablePackageCleanupError
                                    .cleanupRequired
                            }
                        }
                    }
                }
            } catch {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
            throw originalError
        }
    }

    private static func makeRecoveryRollback(
        data: Data,
        recoveryFD: Int32,
        fileName: String,
        maximumBytes: Int,
        backupPolicy: SystemBackupPolicy
    ) throws -> (
        name: String,
        descriptor: Int32,
        identity: stat
    ) {
        guard data.count <= maximumBytes else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        let name =
            AtomicControlFileTransaction.oldName(
                destinationName: fileName,
                data: data
            )
        let descriptor = name.withCString {
            Darwin.openat(
                recoveryFD,
                $0,
                O_RDWR | O_CREAT | O_EXCL
                    | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        var shouldUnlink = true
        defer {
            if shouldUnlink {
                Darwin.close(descriptor)
                _ = name.withCString {
                    Darwin.unlinkat(
                        recoveryFD,
                        $0,
                        0
                    )
                }
            }
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
        var opened = stat()
        var published = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              isRegular(opened),
              opened.st_nlink == 1,
              opened.st_size == off_t(data.count),
              name.withCString({
                  Darwin.fstatat(
                      recoveryFD,
                      $0,
                      &published,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              sameFile(opened, published),
              try readRegularFile(
                descriptor: descriptor,
                expected: opened,
                maximumBytes: maximumBytes
              ) == data,
              Darwin.fsync(recoveryFD) == 0 else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        shouldUnlink = false
        return (name, descriptor, opened)
    }

    private static func discardRecoveryEntry(
        name: String,
        identity: stat,
        recoveryFD: Int32
    ) throws {
        var published = stat()
        guard name.withCString({
                  Darwin.fstatat(
                      recoveryFD,
                      $0,
                      &published,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              sameFile(identity, published),
              name.withCString({
                  Darwin.unlinkat(
                      recoveryFD,
                      $0,
                      0
                  )
              }) == 0,
              Darwin.fsync(recoveryFD) == 0 else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
    }

    private static func removeRecoveryEntryIfPublished(
        name: String,
        identity: stat,
        recoveryFD: Int32
    ) {
        var published = stat()
        guard name.withCString({
                  Darwin.fstatat(
                      recoveryFD,
                      $0,
                      &published,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              sameFile(identity, published) else {
            return
        }
        _ = name.withCString {
            Darwin.unlinkat(
                recoveryFD,
                $0,
                0
            )
        }
        _ = Darwin.fsync(recoveryFD)
    }

    /// Builds and audits the private restore copy under one descriptor lease.
    /// Foundation URL APIs are used only to read the already-audited source.
    static func buildRestoreStagingPackage(
        source: AuditedPortableBackup,
        journal: PortableRestoreJournal,
        layout: AppDataStoreLayout,
        beforeCreate: MutationProbe = {},
        beforeWrite: MutationProbe = {},
        afterFirstSensitiveWrite:
            MutationProbe = {},
        bindArtifact:
            ArtifactBinding = { _, _, _ in },
        recordSanitization:
            ArtifactSanitization = { _, _, _ in }
    ) async throws -> AuditedPortableBackup {
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
        let stagingCreateResult =
            "PortableImports".withCString({
            Darwin.mkdirat(recoveryFD, $0, S_IRWXU)
        })
        if stagingCreateResult != 0,
           errno != EEXIST {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        if stagingCreateResult == 0,
           Darwin.fsync(recoveryFD) != 0 {
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
        Darwin.fsync(stagingFD) == 0,
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
        Darwin.fsync(operationFD) == 0,
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
        try await bindArtifact(
            PortableArtifactIdentity(stagingIdentity),
            PortableArtifactIdentity(operationIdentity),
            PortableArtifactIdentity(packageIdentity)
        )
        do {
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
        try afterFirstSensitiveWrite()
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
        guard Darwin.fsync(packageFD) == 0,
              Darwin.fsync(operationFD) == 0,
              Darwin.fsync(stagingFD) == 0,
              Darwin.fsync(recoveryFD) == 0 else {
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
        } catch {
            let originalError = error
            do {
                try quarantineManagedDirectoryIfPublished(
                    parentDescriptor: stagingFD,
                    activeName: operationName,
                    quarantineName:
                        ".cleanup-" + operationName,
                    directoryDescriptor: operationFD,
                    expectedIdentity:
                        PortableArtifactIdentity(
                            operationIdentity
                        )
                )
                try sanitizeManagedDirectory(
                    descriptor: operationFD
                )
                guard Darwin.fsync(operationFD) == 0,
                      Darwin.fsync(stagingFD) == 0 else {
                    throw PortablePackageCleanupError
                        .cleanupRequired
                }
                try await recordSanitization(
                    PortableArtifactIdentity(
                        stagingIdentity
                    ),
                    PortableArtifactIdentity(
                        operationIdentity
                    ),
                    PortableArtifactIdentity(
                        packageIdentity
                    )
                )
            } catch {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
            throw originalError
        }
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

    static func sanitizeTransferPackage(
        transferRootURL: URL,
        packageName: String,
        expectedAnchorIdentity:
            PortableArtifactIdentity?,
        expectedPackageIdentity:
            PortableArtifactIdentity?,
        beforeQuarantine:
            @Sendable (URL) throws -> Void = { _ in }
    ) throws {
        guard isSafeComponent(packageName),
              let rootFD = try openDirectory(
                at: AT_FDCWD,
                component: transferRootURL.path,
                allowMissing: true
              ) else {
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        defer { Darwin.close(rootFD) }
        var rootOpened = stat()
        guard Darwin.fstat(rootFD, &rootOpened) == 0,
              isDirectory(rootOpened),
              expectedAnchorIdentity?
                .matches(rootOpened) == true else {
            throw PortablePackageCleanupError.unsafeTarget
        }
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
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        guard let expectedPackageIdentity else {
            throw PortablePackageCleanupError
                .unsafeTarget
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
              sameFile(initial, opened),
              expectedPackageIdentity.matches(opened) else {
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
            guard Darwin.fsync(rootFD) == 0 else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
        }
        try removeTreeContents(
            descriptor: packageFD,
            snapshot: treeSnapshot
        )
        guard try directoryEntries(
                descriptor: packageFD,
                maximumEntries: 0
              ).isEmpty,
              let final = try entryStatus(
            at: rootFD,
            component: quarantineName,
            allowMissing: false
        ),
        isDirectory(final),
        sameFile(final, opened),
        Darwin.fsync(packageFD) == 0,
        Darwin.fsync(rootFD) == 0 else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
    }

    static func finalizeSanitizedTransferPackage(
        transferRootURL: URL,
        packageName: String,
        expectedAnchorIdentity:
            PortableArtifactIdentity?,
        expectedPackageIdentity:
            PortableArtifactIdentity?
    ) throws {
        guard isSafeComponent(packageName),
              let expectedAnchorIdentity,
              let expectedPackageIdentity else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        guard let rootFD = try openDirectory(
                at: AT_FDCWD,
                component: transferRootURL.path,
                allowMissing: true
              ) else {
            // The durable `.sanitized` journal state proves that the held
            // artifact descriptor was already scrubbed and fsynced. A missing
            // publication anchor is therefore safe to finalize.
            return
        }
        defer { Darwin.close(rootFD) }
        var rootOpened = stat()
        guard Darwin.fstat(rootFD, &rootOpened) == 0 else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        guard expectedAnchorIdentity.matches(rootOpened) else {
            // Never touch a replacement anchor. The exact original artifact
            // was already descriptor-scrubbed before `.sanitized` persisted.
            return
        }
        let quarantineName = ".cleanup-" + packageName
        guard try entryStatus(
            at: rootFD,
            component: packageName,
            allowMissing: true
        ) == nil else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        guard let quarantine = try entryStatus(
            at: rootFD,
            component: quarantineName,
            allowMissing: true
        ) else {
            guard Darwin.fsync(rootFD) == 0 else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
            return
        }
        guard isDirectory(quarantine),
              expectedPackageIdentity.matches(quarantine),
              let packageFD = try openDirectory(
                at: rootFD,
                component: quarantineName,
                allowMissing: false
              ) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        defer { Darwin.close(packageFD) }
        var opened = stat()
        guard Darwin.fstat(packageFD, &opened) == 0,
              expectedPackageIdentity.matches(opened),
              sameFile(quarantine, opened),
              try directoryEntries(
                descriptor: packageFD,
                maximumEntries: 0
              ).isEmpty,
              quarantineName.withCString({
                  Darwin.unlinkat(
                      rootFD,
                      $0,
                      AT_REMOVEDIR
                  )
              }) == 0,
              Darwin.fsync(rootFD) == 0 else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
    }

    static func sanitizeRestoreOperation(
        layout: AppDataStoreLayout,
        operationID: UUID,
        expectedAnchorIdentity:
            PortableArtifactIdentity?,
        expectedOperationIdentity:
            PortableArtifactIdentity?,
        expectedPackageIdentity:
            PortableArtifactIdentity?,
        beforeQuarantine:
            MutationProbe = {}
    ) throws {
        guard let rootFD = try openDirectory(
            at: AT_FDCWD,
            component: layout.rootURL.path,
            allowMissing: true
        ) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        defer { Darwin.close(rootFD) }
        guard let recoveryFD = try openDirectory(
            at: rootFD,
            component: "Recovery",
            allowMissing: true
        ) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        defer { Darwin.close(recoveryFD) }
        guard let stagingFD = try openDirectory(
            at: recoveryFD,
            component: "PortableImports",
            allowMissing: true
        ) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        defer { Darwin.close(stagingFD) }
        var stagingOpened = stat()
        guard Darwin.fstat(stagingFD, &stagingOpened) == 0,
              expectedAnchorIdentity?
                .matches(stagingOpened) == true else {
            throw PortablePackageCleanupError.unsafeTarget
        }

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
            throw PortablePackageCleanupError
                .unsafeTarget
        }
        guard let expectedOperationIdentity,
              let expectedPackageIdentity else {
            throw PortablePackageCleanupError
                .unsafeTarget
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
        sameFile(initial, openedOperation),
        expectedOperationIdentity
            .matches(openedOperation) else {
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
            ),
            expectedPackageIdentity
                .matches(packageOpened) else {
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
            guard Darwin.fsync(stagingFD) == 0 else {
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
        guard try directoryEntries(
                descriptor: operationFD,
                maximumEntries: 0
              ).isEmpty,
              Darwin.fsync(operationFD) == 0,
              Darwin.fsync(stagingFD) == 0 else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
    }

    static func finalizeSanitizedRestoreOperation(
        layout: AppDataStoreLayout,
        operationID: UUID,
        expectedAnchorIdentity:
            PortableArtifactIdentity?,
        expectedOperationIdentity:
            PortableArtifactIdentity?
    ) throws {
        guard let expectedAnchorIdentity,
              let expectedOperationIdentity else {
            throw PortablePackageCleanupError.unsafeTarget
        }
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
        var stagingOpened = stat()
        guard Darwin.fstat(stagingFD, &stagingOpened) == 0 else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        guard expectedAnchorIdentity.matches(stagingOpened) else {
            return
        }
        let operationName =
            operationID.uuidString.lowercased()
        let quarantineName = ".cleanup-" + operationName
        guard try entryStatus(
            at: stagingFD,
            component: operationName,
            allowMissing: true
        ) == nil else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        if let quarantine = try entryStatus(
            at: stagingFD,
            component: quarantineName,
            allowMissing: true
        ) {
            guard isDirectory(quarantine),
                  expectedOperationIdentity
                    .matches(quarantine),
                  let operationFD = try openDirectory(
                    at: stagingFD,
                    component: quarantineName,
                    allowMissing: false
                  ) else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            defer { Darwin.close(operationFD) }
            var opened = stat()
            guard Darwin.fstat(operationFD, &opened) == 0,
                  sameFile(quarantine, opened),
                  expectedOperationIdentity
                    .matches(opened),
                  try directoryEntries(
                    descriptor: operationFD,
                    maximumEntries: 0
                  ).isEmpty,
                  quarantineName.withCString({
                      Darwin.unlinkat(
                          stagingFD,
                          $0,
                          AT_REMOVEDIR
                      )
                  }) == 0,
                  Darwin.fsync(stagingFD) == 0 else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
        } else {
            guard Darwin.fsync(stagingFD) == 0 else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
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

    static func createChildDirectory(
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
              Darwin.fsync(parentFD) == 0,
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

    static func createChildFile(
        at parentFD: Int32,
        component: String,
        data: Data,
        maximumBytes: Int,
        backupPolicy: SystemBackupPolicy,
        beforeReadback: MutationProbe = {}
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
        do {
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
            try beforeReadback()
            var publishedBeforeReadback = stat()
            var openedAfterWrite = stat()
            guard Darwin.fstat(
                    descriptor,
                    &openedAfterWrite
                  ) == 0,
                  component.withCString({
                      Darwin.fstatat(
                          parentFD,
                          $0,
                          &publishedBeforeReadback,
                          AT_SYMLINK_NOFOLLOW
                      )
                  }) == 0,
                  isRegular(openedAfterWrite),
                  openedAfterWrite.st_nlink == 1,
                  openedAfterWrite.st_size
                    == off_t(data.count),
                  sameFile(opened, openedAfterWrite),
                  sameFile(
                      openedAfterWrite,
                      publishedBeforeReadback
                  ),
                  let readback = try readRegularFile(
                    at: parentFD,
                    component: component,
                    maximumBytes: maximumBytes
                  ),
                  readback == data else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
            var finalOpened = stat()
            var finalPublished = stat()
            guard Darwin.fstat(
                    descriptor,
                    &finalOpened
                  ) == 0,
                  component.withCString({
                      Darwin.fstatat(
                          parentFD,
                          $0,
                          &finalPublished,
                          AT_SYMLINK_NOFOLLOW
                      )
                  }) == 0,
                  isRegular(finalOpened),
                  finalOpened.st_nlink == 1,
                  finalOpened.st_size
                    == off_t(data.count),
                  sameFile(opened, finalOpened),
                  sameFile(finalOpened, finalPublished),
                  Darwin.fsync(parentFD) == 0 else {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
        } catch {
            do {
                try sanitizeWrittenDescriptor(descriptor)
            } catch {
                throw PortablePackageCleanupError
                    .cleanupRequired
            }
            throw error
        }
    }

    private static func sanitizeWrittenDescriptor(
        _ descriptor: Int32
    ) throws {
        guard Darwin.ftruncate(descriptor, 0) == 0,
              Darwin.fsync(descriptor) == 0 else {
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
        var finalOpened = stat()
        var finalPublished = stat()
        guard Darwin.fstat(descriptor, &finalOpened) == 0,
              component.withCString({
                  Darwin.fstatat(
                      parentFD,
                      $0,
                      &finalPublished,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              isRegular(finalOpened),
              finalOpened.st_nlink == 1,
              finalOpened.st_size == opened.st_size,
              sameFile(opened, finalOpened),
              sameFile(finalOpened, finalPublished) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        return data
    }

    private static func readRegularFile(
        descriptor: Int32,
        expected: stat,
        maximumBytes: Int
    ) throws -> Data {
        guard isRegular(expected),
              expected.st_nlink == 1,
              expected.st_size >= 0,
              expected.st_size <= off_t(maximumBytes) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        var data = Data(count: Int(expected.st_size))
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
        var final = stat()
        guard offset == data.count,
              Darwin.fstat(descriptor, &final) == 0,
              isRegular(final),
              final.st_nlink == 1,
              final.st_size == expected.st_size,
              sameFile(final, expected) else {
            throw PortablePackageCleanupError.unsafeTarget
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

    fileprivate static func openDirectory(
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

    static func entryStatus(
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

    static func directoryEntries(
        descriptor: Int32,
        maximumEntries: Int? = nil
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
                if let maximumEntries,
                   values.count > maximumEntries {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
            }
        }
        return values.sorted()
    }

    fileprivate typealias ManagedTreeSnapshot =
        [String: stat]
    private static let maximumManagedTreeEntries =
        PortableBackupLimits.maximumEntryCount
        + PortableBackupLimits.maximumAttachmentCount
        + 8
    private static let maximumManagedTreeDepth = 4

    fileprivate static func preflightTree(
        descriptor: Int32,
        prefix: String = ""
    ) throws -> ManagedTreeSnapshot {
        var snapshot: ManagedTreeSnapshot = [:]
        var remainingEntries = maximumManagedTreeEntries
        try appendPreflightTree(
            descriptor: descriptor,
            prefix: prefix,
            depth: prefix.isEmpty
                ? 0 : prefix.split(separator: "/").count,
            remainingEntries: &remainingEntries,
            snapshot: &snapshot
        )
        return snapshot
    }

    private static func appendPreflightTree(
        descriptor: Int32,
        prefix: String,
        depth: Int,
        remainingEntries: inout Int,
        snapshot: inout ManagedTreeSnapshot
    ) throws {
        for name in try directoryEntries(
            descriptor: descriptor,
            maximumEntries: remainingEntries
        ) {
            guard remainingEntries > 0 else {
                throw PortablePackageCleanupError.unsafeTarget
            }
            remainingEntries -= 1
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
            let pathDepth = depth + 1
            guard pathDepth <= maximumManagedTreeDepth,
                  snapshot[path] == nil else {
                throw PortablePackageCleanupError.unsafeTarget
            }
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
                    try appendPreflightTree(
                        descriptor: child,
                        prefix: path,
                        depth: pathDepth,
                        remainingEntries:
                            &remainingEntries,
                        snapshot: &snapshot
                    )
                    Darwin.close(child)
                } catch {
                    Darwin.close(child)
                    throw error
                }
            } else if isRegular(value) {
                guard value.st_nlink == 1 else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                continue
            } else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
        }
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

    private static func makeManagedDirectoriesOwnerWritable(
        descriptor: Int32,
        snapshot: ManagedTreeSnapshot,
        prefix: String = ""
    ) throws {
        guard Darwin.fchmod(
            descriptor,
            S_IRWXU
        ) == 0 else {
            throw PortablePackageCleanupError.cleanupRequired
        }
        let depth = prefix.isEmpty
            ? 1 : prefix.split(separator: "/").count + 1
        let directoryPaths = snapshot.keys.filter {
            path in
            let components = path.split(separator: "/")
            guard components.count == depth,
                  prefix.isEmpty
                    || path.hasPrefix(prefix + "/"),
                  let value = snapshot[path] else {
                return false
            }
            return isDirectory(value)
        }.sorted()
        for path in directoryPaths {
            let name = String(
                path.split(separator: "/").last!
            )
            guard let child = try openDirectory(
                at: descriptor,
                component: name,
                allowMissing: false
            ) else {
                throw PortablePackageCleanupError.unsafeTarget
            }
            do {
                try makeManagedDirectoriesOwnerWritable(
                    descriptor: child,
                    snapshot: snapshot,
                    prefix: path
                )
                guard Darwin.fsync(child) == 0 else {
                    throw PortablePackageCleanupError
                        .cleanupRequired
                }
                Darwin.close(child)
            } catch {
                Darwin.close(child)
                throw error
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw PortablePackageCleanupError.cleanupRequired
        }
    }

    static func sanitizeManagedDirectory(
        descriptor: Int32
    ) throws {
        let snapshot = try preflightTree(
            descriptor: descriptor
        )
        try verifyTree(
            descriptor: descriptor,
            snapshot: snapshot
        )
        try removeTreeContents(
            descriptor: descriptor,
            snapshot: snapshot
        )
        guard try directoryEntries(
                descriptor: descriptor,
                maximumEntries: 0
              ).isEmpty,
              Darwin.fsync(descriptor) == 0 else {
            throw PortablePackageCleanupError.cleanupRequired
        }
    }

    static func quarantineManagedDirectoryIfPublished(
        parentDescriptor: Int32,
        activeName: String,
        quarantineName: String,
        directoryDescriptor: Int32,
        expectedIdentity: PortableArtifactIdentity
    ) throws {
        guard isSafeComponent(activeName),
              isSafeComponent(quarantineName) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        var opened = stat()
        guard Darwin.fstat(
                directoryDescriptor,
                &opened
              ) == 0,
              isDirectory(opened),
              expectedIdentity.matches(opened) else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        let active = try entryStatus(
            at: parentDescriptor,
            component: activeName,
            allowMissing: true
        )
        let quarantine = try entryStatus(
            at: parentDescriptor,
            component: quarantineName,
            allowMissing: true
        )
        guard active == nil || quarantine == nil else {
            throw PortablePackageCleanupError.unsafeTarget
        }
        if let active {
            guard isDirectory(active),
                  sameFile(active, opened) else {
                throw PortablePackageCleanupError.unsafeTarget
            }
            guard activeName.withCString({
                source in
                quarantineName.withCString {
                    destination in
                    Darwin.renameat(
                        parentDescriptor,
                        source,
                        parentDescriptor,
                        destination
                    )
                }
            }) == 0,
            let published = try entryStatus(
                at: parentDescriptor,
                component: quarantineName,
                allowMissing: false
            ),
            sameFile(published, opened),
            Darwin.fsync(parentDescriptor) == 0 else {
                throw PortablePackageCleanupError.cleanupRequired
            }
        } else if let quarantine {
            guard isDirectory(quarantine),
                  sameFile(quarantine, opened),
                  Darwin.fsync(parentDescriptor) == 0 else {
                throw PortablePackageCleanupError.unsafeTarget
            }
        } else {
            // The exact directory may have been moved to another publication
            // name. Its held descriptor can still be scrubbed; the durable
            // sanitized marker then authorizes forgetting the empty remnant.
            guard Darwin.fsync(parentDescriptor) == 0 else {
                throw PortablePackageCleanupError.cleanupRequired
            }
        }
    }

    private static func removeTreeContents(
        descriptor: Int32,
        snapshot: ManagedTreeSnapshot,
        prefix: String = ""
    ) throws {
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
        let names = try directoryEntries(
            descriptor: descriptor,
            maximumEntries: expectedNames.count
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
                          ),
                          Darwin.fsync(child) == 0 else {
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
                }) == 0,
                Darwin.fsync(descriptor) == 0 else {
                    throw PortablePackageCleanupError
                        .cleanupRequired
                }
            } else if isRegular(value) {
                guard value.st_nlink == 1 else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                let fileFD = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_WRONLY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard fileFD >= 0 else {
                    throw PortablePackageCleanupError
                        .cleanupRequired
                }
                defer { Darwin.close(fileFD) }
                var openedFile = stat()
                guard Darwin.fstat(
                        fileFD,
                        &openedFile
                      ) == 0,
                      sameManagedEntry(
                        openedFile,
                        expected
                      ),
                      let final = try entryStatus(
                    at: descriptor,
                    component: name,
                    allowMissing: false
                      ),
                      sameManagedEntry(final, expected)
                else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                guard Darwin.ftruncate(fileFD, 0) == 0,
                      Darwin.fsync(fileFD) == 0 else {
                    throw PortablePackageCleanupError
                        .cleanupRequired
                }
                var scrubbed = stat()
                guard Darwin.fstat(fileFD, &scrubbed) == 0,
                      sameFile(scrubbed, openedFile),
                      scrubbed.st_size == 0,
                      let scrubbedPublished =
                        try entryStatus(
                            at: descriptor,
                            component: name,
                            allowMissing: false
                        ),
                      sameFile(
                        scrubbedPublished,
                        openedFile
                      ) else {
                    throw PortablePackageCleanupError
                        .unsafeTarget
                }
                guard name.withCString({
                    Darwin.unlinkat(
                        descriptor,
                        $0,
                        0
                    )
                }) == 0,
                Darwin.fsync(descriptor) == 0 else {
                    throw PortablePackageCleanupError
                        .cleanupRequired
                }
            } else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw PortablePackageCleanupError.cleanupRequired
        }
    }

    private static func sameManagedEntry(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        guard sameFile(lhs, rhs),
              (lhs.st_mode & S_IFMT)
                == (rhs.st_mode & S_IFMT) else {
            return false
        }
        if isRegular(lhs) {
            return lhs.st_nlink == 1
                && rhs.st_nlink == 1
                && lhs.st_size == rhs.st_size
        }
        return true
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
        let removed = "PortableImports".withCString({
            Darwin.unlinkat(
                recoveryFD,
                $0,
                AT_REMOVEDIR
            )
        })
        guard removed == 0 || errno == ENOTEMPTY else {
            throw PortablePackageCleanupError
                .cleanupRequired
        }
        if removed == 0,
           Darwin.fsync(recoveryFD) != 0 {
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

    func bind(
        _ intent: PortablePackageCleanupIntent,
        anchorIdentity: PortableArtifactIdentity,
        rootIdentity: PortableArtifactIdentity,
        packageIdentity: PortableArtifactIdentity
    ) throws -> PortablePackageCleanupIntent {
        try PortablePackageCleanupJournalTransactionLock
            .shared.withLock {
                let intents = try currentIntents()
                guard let stored = intents.first(where: {
                    $0.operationID == intent.operationID
                        && $0.kind == intent.kind
                        && $0.relativePath == intent.relativePath
                }),
                stored.state == .active,
                stored.anchorIdentity == nil,
                stored.rootIdentity == nil,
                stored.packageIdentity == nil else {
                    throw PortablePackageCleanupError
                        .unregisteredTarget
                }
                let bound = stored.binding(
                    anchorIdentity:
                        anchorIdentity,
                    rootIdentity: rootIdentity,
                    packageIdentity: packageIdentity
                )
                try store.write(
                    PortablePackageCleanupJournal(
                        intents: intents.map {
                            $0 == stored ? bound : $0
                        }
                    )
                )
                return bound
            }
    }

    /// Records that the exact descriptor-bound artifact was already scrubbed
    /// by its live lease. This is the only path that may authorize a later
    /// "canonical artifact missing" result during finalization.
    func recordLeaseSanitization(
        _ intent: PortablePackageCleanupIntent,
        anchorIdentity: PortableArtifactIdentity,
        rootIdentity: PortableArtifactIdentity,
        packageIdentity: PortableArtifactIdentity
    ) throws -> PortablePackageCleanupIntent {
        try PortablePackageCleanupJournalTransactionLock
            .shared.withLock {
                let intents = try currentIntents()
                guard let stored = intents.first(where: {
                    $0.operationID == intent.operationID
                        && $0.kind == intent.kind
                        && $0.relativePath == intent.relativePath
                }),
                stored.anchorIdentity == anchorIdentity,
                stored.rootIdentity == rootIdentity,
                stored.packageIdentity == packageIdentity,
                stored.state == .active
                    || stored.state == .cleanupPending
                    || stored.state == .sanitized else {
                    throw PortablePackageCleanupError
                        .unregisteredTarget
                }
                if stored.state == .sanitized {
                    return stored
                }
                let pending: PortablePackageCleanupIntent
                if stored.state == .active {
                    pending = stored.updatingState(.cleanupPending)
                    try store.write(
                        PortablePackageCleanupJournal(
                            intents: intents.map {
                                $0 == stored ? pending : $0
                            }
                        )
                    )
                } else {
                    pending = stored
                }
                return try markSanitizedLocked(pending)
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
                guard let reconciled =
                        try reconcileForDiscardLocked(
                            intent
                        ) else {
                    return
                }
                let pending =
                    try markCleanupPendingLocked(
                        reconciled
                    )
                try discardPendingLocked(pending)
            }
    }

    func discard(
        _ intent: PortablePackageCleanupIntent
    ) throws {
        try PortablePackageCleanupJournalTransactionLock
            .shared.withLock {
                guard let stored = try currentIntents()
                    .first(where: {
                        $0.operationID
                            == intent.operationID
                            && $0.kind == intent.kind
                            && $0.relativePath
                                == intent.relativePath
                    }) else {
                    throw PortablePackageCleanupError
                        .unregisteredTarget
                }
                guard let reconciled =
                        try reconcileForDiscardLocked(
                            stored
                        ) else {
                    return
                }
                let pending =
                    try markCleanupPendingLocked(
                        reconciled
                    )
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
        guard stored.state == .active else {
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
        guard try currentIntents().contains(intent),
              intent.state == .cleanupPending
                || intent.state == .sanitized else {
            throw PortablePackageCleanupError
                .unregisteredTarget
        }
        var sanitized = intent
        if intent.state == .cleanupPending {
            switch intent.kind {
            case .backupTransfer, .importTransfer:
                try PortableManagedPathSecurity
                    .sanitizeTransferPackage(
                        transferRootURL:
                            transferRootURL,
                        packageName:
                            intent.relativePath,
                        expectedAnchorIdentity:
                            intent.anchorIdentity,
                        expectedPackageIdentity:
                            intent.packageIdentity,
                        beforeQuarantine:
                            beforeTransferQuarantine
                    )
            case .restoreStaging:
                try PortableManagedPathSecurity
                    .sanitizeRestoreOperation(
                        layout: layout,
                        operationID:
                            intent.operationID,
                        expectedAnchorIdentity:
                            intent.anchorIdentity,
                        expectedOperationIdentity:
                            intent.rootIdentity,
                        expectedPackageIdentity:
                            intent.packageIdentity,
                        beforeQuarantine:
                            beforeRestoreQuarantine
                    )
            }
            sanitized = try markSanitizedLocked(intent)
        }
        switch sanitized.kind {
        case .backupTransfer, .importTransfer:
            try PortableManagedPathSecurity
                .finalizeSanitizedTransferPackage(
                    transferRootURL: transferRootURL,
                    packageName: sanitized.relativePath,
                    expectedAnchorIdentity:
                        sanitized.anchorIdentity,
                    expectedPackageIdentity:
                        sanitized.packageIdentity
                )
        case .restoreStaging:
            try PortableManagedPathSecurity
                .finalizeSanitizedRestoreOperation(
                    layout: layout,
                    operationID: sanitized.operationID,
                    expectedAnchorIdentity:
                        sanitized.anchorIdentity,
                    expectedOperationIdentity:
                        sanitized.rootIdentity
                )
        }
        let intents = try currentIntents()
        guard intents.contains(sanitized) else {
            throw PortablePackageCleanupError
                .unregisteredTarget
        }
        let remaining = intents.filter {
            $0 != sanitized
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

    private func markSanitizedLocked(
        _ intent: PortablePackageCleanupIntent
    ) throws -> PortablePackageCleanupIntent {
        let intents = try currentIntents()
        guard let stored = intents.first(where: {
            $0.operationID == intent.operationID
                && $0.kind == intent.kind
                && $0.relativePath == intent.relativePath
        }),
        stored.state == .cleanupPending else {
            throw PortablePackageCleanupError
                .unregisteredTarget
        }
        let sanitized = stored.updatingState(.sanitized)
        try store.write(
            PortablePackageCleanupJournal(
                intents: intents.map {
                    $0 == stored ? sanitized : $0
                }
            )
        )
        return sanitized
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
                guard let reconciled =
                        try reconcileForDiscardLocked(
                            intent
                        ) else {
                    return
                }
                let pending =
                    try markCleanupPendingLocked(
                        reconciled
                    )
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
                        let reconciled = try
                            reconcileUnboundIntentLocked(
                                intent
                            )
                        guard let reconciled else {
                            continue
                        }
                        let pending =
                            try markCleanupPendingLocked(
                                reconciled
                            )
                        try discardPendingLocked(pending)
                    } else {
                        guard let reconciled = try
                                reconcileUnboundIntentLocked(
                                    intent
                                ) else {
                            continue
                        }
                        try discardPendingLocked(
                            reconciled
                        )
                    }
                }
            }
    }

    private func reconcileUnboundIntentLocked(
        _ intent: PortablePackageCleanupIntent
    ) throws -> PortablePackageCleanupIntent? {
        guard intent.anchorIdentity == nil,
              intent.rootIdentity == nil,
              intent.packageIdentity == nil else {
            guard intent.anchorIdentity != nil,
                  intent.rootIdentity != nil,
                  intent.packageIdentity != nil else {
                throw PortablePackageCleanupError
                    .unsafeTarget
            }
            return intent
        }
        let identities: (
            anchor: PortableArtifactIdentity,
            root: PortableArtifactIdentity,
            package: PortableArtifactIdentity
        )?
        switch intent.kind {
        case .backupTransfer, .importTransfer:
            identities = try PortableManagedPathSecurity
                .recoverUnboundTransferIdentity(
                    transferRootURL: transferRootURL,
                    packageName: intent.relativePath
                ).map {
                    (
                        anchor: $0.anchor,
                        root: $0.package,
                        package: $0.package
                    )
                }
        case .restoreStaging:
            identities = try PortableManagedPathSecurity
                .recoverUnboundRestoreIdentities(
                    layout: layout,
                    operationID: intent.operationID
                )
        }
        var intents = try currentIntents()
        guard let stored = intents.first(where: {
            $0.operationID == intent.operationID
                && $0.kind == intent.kind
                && $0.relativePath == intent.relativePath
        }),
        stored.rootIdentity == nil,
        stored.anchorIdentity == nil,
        stored.packageIdentity == nil else {
            throw PortablePackageCleanupError
                .unregisteredTarget
        }
        guard let identities else {
            guard stored.state == .active else {
                // Before a durable `.sanitized` marker, a missing publication
                // name is not proof that sensitive bytes are gone.
                throw PortablePackageCleanupError.unsafeTarget
            }
            intents.removeAll { $0 == stored }
            try store.write(
                PortablePackageCleanupJournal(
                    intents: intents
                )
            )
            return nil
        }
        let bound = stored.binding(
            anchorIdentity: identities.anchor,
            rootIdentity: identities.root,
            packageIdentity: identities.package
        )
        try store.write(
            PortablePackageCleanupJournal(
                intents: intents.map {
                    $0 == stored ? bound : $0
                }
            )
        )
        return bound
    }

    private func reconcileForDiscardLocked(
        _ intent: PortablePackageCleanupIntent
    ) throws -> PortablePackageCleanupIntent? {
        do {
            return try reconcileUnboundIntentLocked(
                intent
            )
        } catch {
            if intent.state == .active {
                _ = try markCleanupPendingLocked(intent)
            }
            throw error
        }
    }

    func pendingTransferURLs() throws -> [URL] {
        try PortablePackageCleanupJournalTransactionLock
            .shared.withLock {
                try currentIntents().compactMap {
                    $0.kind == .restoreStaging
                        || $0.state == .active
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
