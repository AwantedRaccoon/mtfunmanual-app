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
                    .unsafePath
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
