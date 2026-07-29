import Darwin
import Foundation
import XCTest
@testable import Unmanual

final class PortableBackupPackageTests: XCTestCase {
    func testBuildAndAuditCompletePackageWithAttachment()
        throws {
        try withPackage { packageURL, document, attachmentData in
            let audited = try PortableBackupPackageBuilder.build(
                document: document,
                destinationURL: packageURL
            ) { _, destination in
                try attachmentData.write(
                    to: destination,
                    options: [.atomic]
                )
            }
            XCTAssertEqual(
                audited.manifest.payload.datasetID,
                document.payload.datasetID
            )
            XCTAssertEqual(
                audited.manifest.payload.entryCount,
                3
            )
            XCTAssertEqual(
                audited.readableDocument,
                document
            )
            XCTAssertEqual(
                audited.packageSHA256.count,
                64
            )
            XCTAssertEqual(
                audited.manifest.payload.attachments
                    .map(\.relativePath),
                document.payload.activeAttachments
                    .map(\.packageRelativePath)
            )
        }
    }

    func testAuditRejectsAttachmentTamper() throws {
        try withBuiltPackage {
            packageURL, document, _ in
            let attachment = try XCTUnwrap(
                document.payload.activeAttachments.first
            )
            let url = packageURL.appending(
                path: attachment.packageRelativePath
            )
            try Data("changed".utf8).write(
                to: url,
                options: [.atomic]
            )
            XCTAssertThrowsError(
                try PortableBackupPackageAuditor.audit(
                    at: packageURL
                )
            ) {
                XCTAssertTrue(
                    [
                        PortableBackupError.sizeMismatch,
                        .digestMismatch
                    ].contains($0 as? PortableBackupError)
                )
            }
        }
    }

    func testAuditRejectsUnexpectedFile() throws {
        try withBuiltPackage {
            packageURL, _, _ in
            try Data("extra".utf8).write(
                to: packageURL.appending(path: "extra.txt")
            )
            XCTAssertThrowsError(
                try PortableBackupPackageAuditor.audit(
                    at: packageURL
                )
            ) {
                XCTAssertEqual(
                    $0 as? PortableBackupError,
                    .limitExceeded
                )
            }
        }
    }

    func testAuditRejectsSymlinkedAttachment() throws {
        try withBuiltPackage {
            packageURL, document, _ in
            let attachment = try XCTUnwrap(
                document.payload.activeAttachments.first
            )
            let payloadURL = packageURL.appending(
                path: attachment.packageRelativePath
            )
            let outside = packageURL
                .deletingLastPathComponent()
                .appending(path: UUID().uuidString)
            try Data("outside".utf8).write(to: outside)
            defer {
                try? FileManager.default.removeItem(
                    at: outside
                )
            }
            try FileManager.default.removeItem(
                at: payloadURL
            )
            try FileManager.default.createSymbolicLink(
                at: payloadURL,
                withDestinationURL: outside
            )
            XCTAssertThrowsError(
                try PortableBackupPackageAuditor.audit(
                    at: packageURL
                )
            ) {
                XCTAssertEqual(
                    $0 as? PortableBackupError,
                    .unsupportedFileType
                )
            }
        }
    }

    func testAuditRejectsAttachmentWithExternalHardLink()
        throws {
        try withBuiltPackage {
            packageURL, document, _ in
            let attachment = try XCTUnwrap(
                document.payload.activeAttachments.first
            )
            let payloadURL = packageURL.appending(
                path: attachment.packageRelativePath
            )
            let outside = packageURL
                .deletingLastPathComponent()
                .appending(path: "external-hard-link")
            try FileManager.default.linkItem(
                at: payloadURL,
                to: outside
            )
            defer {
                try? FileManager.default.removeItem(at: outside)
            }

            XCTAssertThrowsError(
                try PortableBackupPackageAuditor.audit(
                    at: packageURL
                )
            ) {
                XCTAssertEqual(
                    $0 as? PortableBackupError,
                    .unsupportedFileType
                )
            }
        }
    }

    func testAuditRejectsExtraEmptyAttachmentDirectory()
        throws {
        try withBuiltPackage {
            packageURL, _, _ in
            let extra = packageURL.appending(
                path:
                    "attachments/"
                    + UUID().uuidString.lowercased(),
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: extra,
                withIntermediateDirectories: false
            )

            XCTAssertThrowsError(
                try PortableBackupPackageAuditor.audit(
                    at: packageURL
                )
            ) {
                XCTAssertEqual(
                    $0 as? PortableBackupError,
                    .unexpectedEntry
                )
            }
        }
    }

    func testManifestRejectsTraversalAndCaseFoldCollision() throws {
        let entry = PortableBackupPackageEntry(
            relativePath: "../readable-v2.json",
            byteCount: 1,
            sha256Hex: String(repeating: "a", count: 64)
        )
        let unsafePayload = try PortableBackupManifestPayload(
                datasetID: datasetID,
                sourceGenerationID: generationID,
                createdAtMicroseconds: 1,
                readableData: entry,
                attachments: []
            )
        XCTAssertThrowsError(
            try PortableBackupManifestCodec.make(
                payload: unsafePayload
            )
        )

        let id = UUID(
            uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )!
        let lower =
            "attachments/"
            + id.uuidString.lowercased()
            + "/payload"
        let upper =
            "attachments/"
            + id.uuidString.uppercased()
            + "/payload"
        XCTAssertNoThrow(
            try PortableBackupPathPolicy.validate(lower)
        )
        XCTAssertThrowsError(
            try PortableBackupPathPolicy.validate(upper)
        )
    }

    func testBuilderRejectsOverTwoGiBBeforeCopierOrDestination()
        throws {
        let document = try makeOversizedMetadataDocument()
        let destination = FileManager.default.temporaryDirectory
            .appending(
                path: "Oversized-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        var copierCalls = 0
        var leaseCreated = false
        XCTAssertThrowsError(
            try {
                let prepared = try PortableBackupPackageBuilder
                    .prepare(document: document)
                leaseCreated = true
                let lease = try PortableManagedPathSecurity
                    .createTransferPackageRootLease(
                        transferRootURL: destination,
                        packageName: "package.unmanualbackup"
                    )
                return try PortableBackupPackageBuilder.build(
                    prepared: prepared,
                    destinationLease: lease
                ) { _ in
                    copierCalls += 1
                    return Data()
                }
            }()
        ) {
            XCTAssertEqual(
                $0 as? PortableBackupError,
                .limitExceeded
            )
        }
        XCTAssertFalse(leaseCreated)
        XCTAssertEqual(copierCalls, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.path
            )
        )
    }

    func testDirectoryEnumerationStopsAtLimitPlusOne()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "BoundedDirectory-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["one", "two"] {
            try FileManager.default.createDirectory(
                at: root.appending(path: name),
                withIntermediateDirectories: false
            )
        }
        let descriptor = try PortableBackupDescriptorIO
            .openRoot(root)
        defer { Darwin.close(descriptor) }
        XCTAssertThrowsError(
            try PortableBackupDescriptorIO.directoryEntries(
                descriptor,
                maximumEntries: 1
            )
        ) {
            XCTAssertEqual(
                $0 as? PortableBackupError,
                .limitExceeded
            )
        }
    }

    func testTransferRootSymlinkFailsBeforeForeignMetadataWrite()
        throws {
        let base = FileManager.default.temporaryDirectory
            .appending(
                path: "LeaseRootSymlink-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let external = base.appending(
            path: "external",
            directoryHint: .isDirectory
        )
        let transferRoot = base.appending(
            path: "UnmanualTransfers",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: base) }
        let sentinel = external.appending(path: "sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: transferRoot,
            withDestinationURL: external
        )
        let before = try status(of: external)

        XCTAssertThrowsError(
            try PortableManagedPathSecurity
                .createTransferPackageRootLease(
                    transferRootURL: transferRoot,
                    packageName: "package.unmanualbackup"
                )
        )

        let after = try status(of: external)
        XCTAssertEqual(before.st_mode, after.st_mode)
        XCTAssertEqual(
            before.st_ctimespec.tv_sec,
            after.st_ctimespec.tv_sec
        )
        XCTAssertEqual(
            before.st_ctimespec.tv_nsec,
            after.st_ctimespec.tv_nsec
        )
        XCTAssertEqual(
            try Data(contentsOf: sentinel),
            Data("unchanged".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: external.appending(
                    path: "package.unmanualbackup"
                ).path
            )
        )
    }

    func testTransferRootReplacementRaceFailsBeforeForeignWrite()
        throws {
        let base = FileManager.default.temporaryDirectory
            .appending(
                path: "LeaseRootRace-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let external = base.appending(
            path: "external",
            directoryHint: .isDirectory
        )
        let transferRoot = base.appending(
            path: "UnmanualTransfers",
            directoryHint: .isDirectory
        )
        let displaced = base.appending(
            path: "displaced",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: base) }
        let sentinel = external.appending(path: "sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        let before = try status(of: external)

        XCTAssertThrowsError(
            try PortableManagedPathSecurity
                .createTransferPackageRootLease(
                    transferRootURL: transferRoot,
                    packageName: "package.unmanualbackup",
                    beforeOpenRoot: {
                        try FileManager.default.moveItem(
                            at: transferRoot,
                            to: displaced
                        )
                        try FileManager.default
                            .createSymbolicLink(
                                at: transferRoot,
                                withDestinationURL: external
                            )
                    }
                )
        )

        let after = try status(of: external)
        XCTAssertEqual(before.st_mode, after.st_mode)
        XCTAssertEqual(
            before.st_ctimespec.tv_sec,
            after.st_ctimespec.tv_sec
        )
        XCTAssertEqual(
            before.st_ctimespec.tv_nsec,
            after.st_ctimespec.tv_nsec
        )
        XCTAssertEqual(
            try Data(contentsOf: sentinel),
            Data("unchanged".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: external.appending(
                    path: "package.unmanualbackup"
                ).path
            )
        )
    }

    func testDescriptorLeaseRejectsWholeTransferRootReplacementBeforeBuild()
        throws {
        try withPackage {
            _, document, attachmentData in
            let base = FileManager.default.temporaryDirectory
                .appending(
                    path: "LeaseWholeBuild-\(UUID().uuidString)",
                    directoryHint: .isDirectory
                )
            let transferRoot = base.appending(
                path: "UnmanualTransfers",
                directoryHint: .isDirectory
            )
            let displaced = base.appending(
                path: "displaced",
                directoryHint: .isDirectory
            )
            let external = base.appending(
                path: "external",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: base,
                withIntermediateDirectories: false
            )
            defer {
                try? FileManager.default.removeItem(at: base)
            }
            let name = "package.unmanualbackup"
            let lease = try PortableManagedPathSecurity
                .createTransferPackageRootLease(
                    transferRootURL: transferRoot,
                    packageName: name
                )
            try makeForeignPackage(
                at: external,
                packageName: name
            )
            try FileManager.default.moveItem(
                at: transferRoot,
                to: displaced
            )
            try FileManager.default.createSymbolicLink(
                at: transferRoot,
                withDestinationURL: external
            )

            XCTAssertThrowsError(
                try PortableBackupPackageBuilder.build(
                    prepared:
                        PortableBackupPackageBuilder.prepare(
                            document: document
                        ),
                    destinationLease: lease
                ) { _ in attachmentData }
            )
            XCTAssertEqual(
                try Data(
                    contentsOf: external
                        .appending(path: name)
                        .appending(path: "sentinel")
                ),
                Data("foreign".utf8)
            )
        }
    }

    func testDescriptorLeaseRejectsWholeTransferRootReplacementBeforeImport()
        throws {
        try withBuiltPackage { sourceURL, _, _ in
            let base = FileManager.default.temporaryDirectory
                .appending(
                    path: "LeaseWholeImport-\(UUID().uuidString)",
                    directoryHint: .isDirectory
                )
            let transferRoot = base.appending(
                path: "UnmanualTransfers",
                directoryHint: .isDirectory
            )
            let displaced = base.appending(
                path: "displaced",
                directoryHint: .isDirectory
            )
            let external = base.appending(
                path: "external",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: base,
                withIntermediateDirectories: false
            )
            defer {
                try? FileManager.default.removeItem(at: base)
            }
            let name = "import.unmanualbackup"
            let lease = try PortableManagedPathSecurity
                .createTransferPackageRootLease(
                    transferRootURL: transferRoot,
                    packageName: name
                )
            try makeForeignPackage(
                at: external,
                packageName: name
            )
            try FileManager.default.moveItem(
                at: transferRoot,
                to: displaced
            )
            try FileManager.default.createSymbolicLink(
                at: transferRoot,
                withDestinationURL: external
            )

            XCTAssertThrowsError(
                try PortableExternalBackupStager.copy(
                    sourceLease:
                        PortableExternalBackupSourceLease
                        .prepare(
                            at: sourceURL
                        ),
                    destinationLease: lease
                )
            )
            XCTAssertEqual(
                try Data(
                    contentsOf: external
                        .appending(path: name)
                        .appending(path: "sentinel")
                ),
                Data("foreign".utf8)
            )
        }
    }

    func testSourceLeaseRejectsSameByteChildReplacementBeforeCopy()
        throws {
        try withBuiltPackage { sourceURL, _, _ in
            let sourceLease =
                try PortableExternalBackupSourceLease
                .prepare(at: sourceURL)
            let manifest = sourceURL.appending(
                path: "manifest.json"
            )
            let moved = sourceURL
                .deletingLastPathComponent()
                .appending(path: "moved-manifest")
            let bytes = try Data(contentsOf: manifest)
            try FileManager.default.moveItem(
                at: manifest,
                to: moved
            )
            try bytes.write(to: manifest)

            let transferRoot = FileManager.default
                .temporaryDirectory.appending(
                    path:
                        "SourceLeaseReplacement-"
                        + UUID().uuidString,
                    directoryHint: .isDirectory
                )
            defer {
                try? FileManager.default.removeItem(
                    at: transferRoot
                )
            }
            let destination =
                try PortableManagedPathSecurity
                .createTransferPackageRootLease(
                    transferRootURL: transferRoot,
                    packageName: "import.unmanualbackup"
                )

            XCTAssertThrowsError(
                try PortableExternalBackupStager.copy(
                    sourceLease: sourceLease,
                    destinationLease: destination
                )
            ) {
                XCTAssertEqual(
                    $0 as? PortableBackupError,
                    .stateChanged
                )
            }
            XCTAssertEqual(
                try PortableBackupDescriptorIO
                    .directoryEntries(
                        destination.packageDescriptor,
                        maximumEntries: 0
                    ),
                []
            )
        }
    }

    func testDescriptorWriterRejectsSameBytePublishedReplacement()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path:
                    "WriterReplacement-"
                    + UUID().uuidString,
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let rootFD = try PortableBackupDescriptorIO
            .openRoot(root)
        defer { Darwin.close(rootFD) }
        let bytes = Data("sensitive".utf8)
        let published = root.appending(path: "payload")
        let escaped = root.appending(path: "escaped-sibling")

        XCTAssertThrowsError(
            try PortableManagedPathSecurity.createChildFile(
                at: rootFD,
                component: "payload",
                data: bytes,
                maximumBytes: 1_024,
                backupPolicy: .excluded,
                beforeReadback: {
                    try FileManager.default.moveItem(
                        at: published,
                        to: escaped
                    )
                    try bytes.write(to: published)
                }
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: escaped),
            Data()
        )
        XCTAssertEqual(
            try Data(contentsOf: published),
            bytes
        )
        XCTAssertNotEqual(
            try fileIdentity(at: escaped),
            try fileIdentity(at: published)
        )
    }

    func testDescriptorLeaseRejectsRootReplacementBeforeBuild()
        throws {
        try withPackage {
            _, document, attachmentData in
            let transferRoot = FileManager.default
                .temporaryDirectory.appending(
                    path: "LeaseBuild-\(UUID().uuidString)",
                    directoryHint: .isDirectory
                )
            try FileManager.default.createDirectory(
                at: transferRoot,
                withIntermediateDirectories: false
            )
            defer {
                try? FileManager.default.removeItem(
                    at: transferRoot
                )
            }
            let name = "package.unmanualbackup"
            let lease = try PortableManagedPathSecurity
                .createTransferPackageRootLease(
                    transferRootURL: transferRoot,
                    packageName: name
                )
            let original = transferRoot.appending(
                path: "original",
                directoryHint: .isDirectory
            )
            let external = transferRoot.appending(
                path: "external",
                directoryHint: .isDirectory
            )
            try FileManager.default.moveItem(
                at: lease.packageURL,
                to: original
            )
            try FileManager.default.createDirectory(
                at: external,
                withIntermediateDirectories: false
            )
            try FileManager.default.createSymbolicLink(
                at: lease.packageURL,
                withDestinationURL: external
            )

            XCTAssertThrowsError(
                try PortableBackupPackageBuilder.build(
                    document: document,
                    destinationLease: lease
                ) { _ in attachmentData }
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: external.path
                ),
                []
            )
        }
    }

    func testDescriptorLeaseRejectsRootReplacementBeforeImportCopy()
        throws {
        try withBuiltPackage { source, _, _ in
            let transferRoot = FileManager.default
                .temporaryDirectory.appending(
                    path: "LeaseImport-\(UUID().uuidString)",
                    directoryHint: .isDirectory
                )
            try FileManager.default.createDirectory(
                at: transferRoot,
                withIntermediateDirectories: false
            )
            defer {
                try? FileManager.default.removeItem(
                    at: transferRoot
                )
            }
            let lease = try PortableManagedPathSecurity
                .createTransferPackageRootLease(
                    transferRootURL: transferRoot,
                    packageName: "import.unmanualbackup"
                )
            let original = transferRoot.appending(
                path: "original",
                directoryHint: .isDirectory
            )
            let external = transferRoot.appending(
                path: "external",
                directoryHint: .isDirectory
            )
            try FileManager.default.moveItem(
                at: lease.packageURL,
                to: original
            )
            try FileManager.default.createDirectory(
                at: external,
                withIntermediateDirectories: false
            )
            try FileManager.default.createSymbolicLink(
                at: lease.packageURL,
                withDestinationURL: external
            )

            XCTAssertThrowsError(
                try PortableExternalBackupStager.copy(
                    sourceLease:
                        PortableExternalBackupSourceLease
                        .prepare(
                            at: source
                        ),
                    destinationLease: lease
                )
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: external.path
                ),
                []
            )
        }
    }

    func testFrozenNamespaceAcceptsTwoThousandAttachmentDirectoriesWithBoundedDescriptors()
        throws {
        let root = FileManager.default
            .temporaryDirectory.appending(
                path:
                    "PortableFreezeScale-"
                    + UUID().uuidString.lowercased(),
                directoryHint: .isDirectory
            )
        let transferRoot = root.appending(
            path: "Transfers",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(
                at: root
            )
        }
        let lease = try PortableManagedPathSecurity
            .createTransferPackageRootLease(
                transferRootURL: transferRoot,
                packageName:
                    "Scale.unmanualbackup"
            )
        let dataDirectory = lease.packageURL
            .appending(
                path: "data",
                directoryHint: .isDirectory
            )
        let attachmentsDirectory =
            lease.packageURL.appending(
                path: "attachments",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: attachmentsDirectory,
            withIntermediateDirectories: false
        )
        try Data("manifest".utf8).write(
            to: lease.packageURL
                .appending(path: "manifest.json")
        )
        try Data("readable".utf8).write(
            to: dataDirectory.appending(
                path: "readable-v2.json"
            )
        )
        for index in 0..<2_000 {
            let directory =
                attachmentsDirectory.appending(
                    path: String(
                        format: "%04d",
                        index
                    ),
                    directoryHint: .isDirectory
                )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            try Data([UInt8(index & 0xff)])
                .write(
                    to: directory.appending(
                        path: "payload"
                    )
                )
        }
        var observed:
            PortablePackageDirectoryLease
            .FrozenNamespaceMetrics?

        try lease.withFrozenNamespace(
            metricsObserver: {
                observed = $0
            }
        ) {
            XCTAssertEqual(
                UInt32(
                    try status(
                        of: attachmentsDirectory
                    ).st_mode
                ) & 0o222,
                0
            )
        }

        let metrics = try XCTUnwrap(observed)
        XCTAssertEqual(
            metrics.regularFileCount,
            2_002
        )
        XCTAssertEqual(
            metrics.directoryCount,
            2_002
        )
        XCTAssertEqual(
            metrics.treeNodeCount,
            4_004
        )
        XCTAssertLessThanOrEqual(
            metrics.peakTransientDescriptorCount,
            3
        )
        XCTAssertEqual(
            UInt32(
                try status(
                    of: attachmentsDirectory
                ).st_mode
            ) & 0o700,
            0o700
        )
    }

    private func withBuiltPackage(
        _ body: (
            URL,
            PortableDataV2Document,
            Data
        ) throws -> Void
    ) throws {
        try withPackage {
            packageURL, document, attachmentData in
            _ = try PortableBackupPackageBuilder.build(
                document: document,
                destinationURL: packageURL
            ) { _, destination in
                try attachmentData.write(
                    to: destination,
                    options: [.atomic]
                )
            }
            try body(
                packageURL,
                document,
                attachmentData
            )
        }
    }

    private func status(of url: URL) throws -> stat {
        var value = stat()
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fstat(descriptor, &value) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return value
    }

    private func fileIdentity(
        at url: URL
    ) throws -> PortableBackupDescriptorIO.FileIdentity {
        let parent = try PortableBackupDescriptorIO.openRoot(
            url.deletingLastPathComponent()
        )
        defer { Darwin.close(parent) }
        return try PortableBackupDescriptorIO
            .readRegularFile(
                at: parent,
                component: url.lastPathComponent,
                maximumBytes: 1_024
            ).identity
    }

    private func makeForeignPackage(
        at root: URL,
        packageName: String
    ) throws {
        let package = root.appending(
            path: packageName,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        try Data("foreign".utf8).write(
            to: package.appending(path: "sentinel")
        )
    }

    private func withPackage(
        _ body: (
            URL,
            PortableDataV2Document,
            Data
        ) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "PortableBackupTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let attachmentData = Data("image-payload".utf8)
        let document = try makeDocument(
            attachmentData: attachmentData
        )
        try body(
            root.appending(
                path: "Backup.unmanualbackup",
                directoryHint: .isDirectory
            ),
            document,
            attachmentData
        )
    }

    private func makeDocument(
        attachmentData: Data
    ) throws -> PortableDataV2Document {
        let attachmentID = UUID(
            uuidString: "12345678-1234-1234-1234-123456789012"
        )!
        let ownerID = UUID(
            uuidString: "11111111-2222-3333-4444-555555555555"
        )!
        let attachment = PortableDataAttachment(
            attachmentID: attachmentID,
            ownerType: AttachmentOwnerType.labSample.rawValue,
            ownerID: ownerID,
            originalFilename: "report.png",
            typeIdentifier: "public.png",
            byteCount: Int64(attachmentData.count),
            sha256Hex:
                PortableBackupFileAudit.sha256Hex(
                    attachmentData
                )
        )
        let profile = try record(
            modelType: "HRTProfile",
            id: ownerID,
            localRevision: 1,
            fields: [
                .init(
                    "activePeriodStartDate",
                    .timestampMicroseconds(
                        1_750_000_000_000_000
                    )
                ),
                .init(
                    "createdAt",
                    .timestampMicroseconds(
                        1_750_000_000_000_000
                    )
                ),
                .init(
                    "startDate",
                    .timestampMicroseconds(
                        1_750_000_000_000_000
                    )
                )
            ]
        )
        let attachmentRecord = try record(
            modelType: "AttachmentRecord",
            id: attachmentID,
            localRevision: 2,
            fields: [
                .init(
                    "byteCount",
                    .integer(attachment.byteCount)
                ),
                .init(
                    "createdAt",
                    .timestampMicroseconds(
                        1_750_000_000_000_000
                    )
                ),
                .init("deleteOperationID", .null),
                .init("deletedAt", .null),
                .init("operationID", .uuid(UUID())),
                .init(
                    "originalFilename",
                    .string(attachment.originalFilename)
                ),
                .init("ownerID", .uuid(ownerID)),
                .init(
                    "ownerType",
                    .string(attachment.ownerType)
                ),
                .init(
                    "relativePath",
                    .string(
                        "lab-sample/"
                            + attachmentID.uuidString
                                .lowercased()
                            + "/payload"
                    )
                ),
                .init(
                    "sha256Hex",
                    .string(attachment.sha256Hex)
                ),
                .init(
                    "typeIdentifier",
                    .string(attachment.typeIdentifier)
                )
            ]
        )
        let modelCounts = DataInventoryTaxonomy
            .allDatabaseModelNames.sorted().map {
                PortableDataModelCount(
                    modelType: $0,
                    rowCount:
                        ["HRTProfile", "AttachmentRecord"]
                            .contains($0)
                            ? 1
                            : ($0 == "RecordRevision"
                                ? 2
                                : ($0 == "DatasetMetadata"
                                    ? 1 : 0))
                )
            }
        return try PortableDataV2Codec.makeDocument(
            payload: PortableDataV2Payload(
                datasetID: datasetID,
                sourceGenerationID: generationID,
                capturedAtMicroseconds: 1_750_000_000_000_000,
                nextLocalRevision: 3,
                modelCounts: modelCounts,
                records: [attachmentRecord, profile]
                    .sorted { $0.recordKey < $1.recordKey },
                controls: [
                    PortableDataControl(
                        modelType: "DatasetMetadata",
                        stableIdentity:
                            DatasetMetadata.fixedKey,
                        disposition:
                            .embeddedInEnvelope,
                        fields: [
                            PortableDataField(
                                name: "createdAt",
                                value: PortableDataValue(
                                    kind:
                                        .timestampMicroseconds,
                                    integerValue:
                                        1_750_000_000_000_000
                                )
                            ),
                            PortableDataField(
                                name: "datasetID",
                                value: PortableDataValue(
                                    kind: .uuid,
                                    uuidValue: datasetID
                                )
                            ),
                            PortableDataField(
                                name: "digestVersion",
                                value: PortableDataValue(
                                    kind: .integer,
                                    integerValue: Int64(
                                        RecordDigestV1.version
                                    )
                                )
                            ),
                            PortableDataField(
                                name: "lastCommittedAt",
                                value: PortableDataValue(
                                    kind:
                                        .timestampMicroseconds,
                                    integerValue:
                                        1_750_000_000_000_000
                                )
                            ),
                            PortableDataField(
                                name: "nextLocalRevision",
                                value: PortableDataValue(
                                    kind: .integer,
                                    integerValue: 3
                                )
                            ),
                            PortableDataField(
                                name: "singletonKey",
                                value: PortableDataValue(
                                    kind: .string,
                                    stringValue:
                                        DatasetMetadata.fixedKey
                                )
                            )
                        ]
                    )
                ],
                activeAttachments: [attachment]
            )
        )
    }

    private func makeOversizedMetadataDocument()
        throws -> PortableDataV2Document {
        let ownerID = UUID(
            uuidString: "11111111-2222-3333-4444-555555555555"
        )!
        let profile = try record(
            modelType: "HRTProfile",
            id: ownerID,
            localRevision: 1,
            fields: [
                .init(
                    "activePeriodStartDate",
                    .timestampMicroseconds(
                        1_750_000_000_000_000
                    )
                ),
                .init(
                    "createdAt",
                    .timestampMicroseconds(
                        1_750_000_000_000_000
                    )
                ),
                .init(
                    "startDate",
                    .timestampMicroseconds(
                        1_750_000_000_000_000
                    )
                )
            ]
        )
        var attachments: [PortableDataAttachment] = []
        var records: [PortableDataRecord] = [profile]
        for index in 0..<103 {
            let id = UUID(
                uuidString: String(
                    format:
                        "12345678-1234-1234-1234-%012x",
                    index + 1
                )
            )!
            let attachment = PortableDataAttachment(
                attachmentID: id,
                ownerType:
                    AttachmentOwnerType.labSample.rawValue,
                ownerID: id,
                originalFilename: "\(index).png",
                typeIdentifier: "public.png",
                byteCount:
                    PortableBackupLimits.maximumAttachmentBytes,
                sha256Hex: String(
                    repeating: "a",
                    count: 64
                )
            )
            attachments.append(attachment)
            records.append(
                try record(
                    modelType: "AttachmentRecord",
                    id: id,
                    localRevision: Int64(index + 2),
                    fields: [
                        .init(
                            "byteCount",
                            .integer(attachment.byteCount)
                        ),
                        .init(
                            "createdAt",
                            .timestampMicroseconds(
                                1_750_000_000_000_000
                            )
                        ),
                        .init("deleteOperationID", .null),
                        .init("deletedAt", .null),
                        .init("operationID", .uuid(UUID())),
                        .init(
                            "originalFilename",
                            .string(
                                attachment.originalFilename
                            )
                        ),
                        .init("ownerID", .uuid(id)),
                        .init(
                            "ownerType",
                            .string(attachment.ownerType)
                        ),
                        .init(
                            "relativePath",
                            .string(
                                "lab-sample/"
                                    + id.uuidString.lowercased()
                                    + "/payload"
                            )
                        ),
                        .init(
                            "sha256Hex",
                            .string(attachment.sha256Hex)
                        ),
                        .init(
                            "typeIdentifier",
                            .string(
                                attachment.typeIdentifier
                            )
                        )
                    ]
                )
            )
        }
        let modelCounts = DataInventoryTaxonomy
            .allDatabaseModelNames.sorted().map {
                PortableDataModelCount(
                    modelType: $0,
                    rowCount:
                        $0 == "HRTProfile"
                            ? 1
                            : ($0 == "AttachmentRecord"
                                ? Int64(attachments.count)
                                : ($0 == "RecordRevision"
                                    ? Int64(records.count)
                                    : ($0 == "DatasetMetadata"
                                        ? 1 : 0)))
                )
            }
        let base = try makeDocument(
            attachmentData: Data("placeholder".utf8)
        )
        let nextLocalRevision =
            Int64(records.count + 1)
        let controls = base.payload.controls.map {
            control in
            PortableDataControl(
                modelType: control.modelType,
                stableIdentity: control.stableIdentity,
                disposition: control.disposition,
                fields: control.fields.map { field in
                    field.name == "nextLocalRevision"
                        ? PortableDataField(
                            name: field.name,
                            value: PortableDataValue(
                                kind: .integer,
                                integerValue:
                                    nextLocalRevision
                            )
                        )
                        : field
                }
            )
        }
        return try PortableDataV2Codec.makeDocument(
            payload: PortableDataV2Payload(
                datasetID: datasetID,
                sourceGenerationID: generationID,
                capturedAtMicroseconds:
                    1_750_000_000_000_000,
                nextLocalRevision: nextLocalRevision,
                modelCounts: modelCounts,
                records: records.sorted {
                    $0.recordKey < $1.recordKey
                },
                controls: controls,
                activeAttachments: attachments
            )
        )
    }

    private func record(
        modelType: String,
        id: UUID,
        localRevision: Int64,
        fields: [RecordDigestV1.Field]
    ) throws -> PortableDataRecord {
        PortableDataRecord(
            modelType: modelType,
            recordType: modelType,
            recordID: id,
            recordKey:
                modelType + ":" + id.uuidString.lowercased(),
            datasetID: datasetID,
            localRevision: localRevision,
            committedAtMicroseconds:
                1_750_000_000_000_000,
            digestVersion: RecordDigestV1.version,
            digestHex: try RecordDigestV1.sha256Hex(
                recordType: modelType,
                recordID: id,
                fields: fields
            ),
            fields: fields.map {
                PortableDataField(
                    name: $0.name,
                    value: PortableDataValue($0.value)
                )
            }
        )
    }

    private var datasetID: UUID {
        UUID(
            uuidString: "AAAAAAAA-0000-0000-0000-000000000001"
        )!
    }

    private var generationID: UUID {
        UUID(
            uuidString: "BBBBBBBB-0000-0000-0000-000000000002"
        )!
    }
}
