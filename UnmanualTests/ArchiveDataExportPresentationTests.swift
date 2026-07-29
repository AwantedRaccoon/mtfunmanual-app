import XCTest
import UniformTypeIdentifiers
@testable import Unmanual

#if DEBUG
final class ArchiveDataExportPresentationTests:
    XCTestCase {
    func testReadablePreviewUsesFrozenV2CountsAndDigest()
        throws {
        let document = try makeReadableDocument(
            capturedAtMicroseconds: 1_750_000_000_000_000
        )

        let preview = ArchiveDataExportPreview(
            readableDocument: document,
            encodedByteCount: 4_096
        )

        XCTAssertEqual(preview.kind, .readableJSON)
        XCTAssertEqual(preview.schemaVersion, "12.0.0")
        XCTAssertEqual(preview.recordCount, 0)
        XCTAssertEqual(preview.controlCount, 0)
        XCTAssertEqual(preview.attachmentCount, 0)
        XCTAssertEqual(preview.byteCount, 4_096)
        XCTAssertEqual(
            preview.integrityDigest,
            document.transportSHA256
        )
        XCTAssertEqual(
            preview.shortIntegrityDigest,
            String(document.transportSHA256.prefix(16))
        )
    }

    func testCompleteBackupPreviewUsesAuditedPackageFacts()
        throws {
        let document = try makeReadableDocument(
            capturedAtMicroseconds: 1_760_000_000_000_000
        )
        let readableEntry = PortableBackupPackageEntry(
            relativePath: "data/readable-v2.json",
            byteCount: 3_072,
            sha256Hex: String(repeating: "a", count: 64)
        )
        let manifest = try PortableBackupManifestCodec.make(
            payload: PortableBackupManifestPayload(
                datasetID: document.payload.datasetID,
                sourceGenerationID:
                    document.payload.sourceGenerationID,
                createdAtMicroseconds:
                    document.payload.capturedAtMicroseconds,
                readableData: readableEntry,
                attachments: []
            )
        )
        let backup = AuditedPortableBackup(
            packageURL: URL(
                fileURLWithPath:
                    "/tmp/preview.unmanualbackup",
                isDirectory: true
            ),
            manifest: manifest,
            readableDocument: document,
            packageSHA256:
                String(repeating: "b", count: 64)
        )

        let preview = ArchiveDataExportPreview(
            completeBackup: backup
        )

        XCTAssertEqual(preview.kind, .completeBackup)
        XCTAssertEqual(preview.recordCount, 0)
        XCTAssertEqual(preview.controlCount, 0)
        XCTAssertEqual(preview.attachmentCount, 0)
        XCTAssertEqual(preview.byteCount, 3_072)
        XCTAssertEqual(
            preview.integrityDigest,
            backup.packageSHA256
        )
    }

    func testExportKindsKeepJSONAndPackageTypesDistinct() {
        XCTAssertEqual(
            ArchiveDataExportKind.readableJSON.contentType,
            .json
        )
        XCTAssertEqual(
            ArchiveDataExportKind.completeBackup.contentType,
            .unmanualCompleteBackup
        )
        XCTAssertTrue(
            UTType.unmanualCompleteBackup.conforms(
                to: .package
            )
        )
        XCTAssertNotEqual(
            ArchiveDataExportKind.readableJSON.contentType,
            ArchiveDataExportKind.completeBackup.contentType
        )
    }

    func testPackageDocumentRetainsOnlyExactTemporaryURL() {
        let packageURL = URL(
            fileURLWithPath:
                "/tmp/exact.unmanualbackup",
            isDirectory: true
        )
        let document = ArchiveDataExportDocument(
            packageURL: packageURL
        )

        guard case let .directoryPackage(storedURL) =
                document.storage else {
            return XCTFail(
                "Expected a directory package export."
            )
        }
        XCTAssertEqual(storedURL, packageURL)
    }

    private func makeReadableDocument(
        capturedAtMicroseconds: Int64
    ) throws -> PortableDataV2Document {
        let modelTypes = DataInventoryTaxonomy
            .databaseModelsByCategory
            .values
            .flatMap { $0 }
            .sorted()
        XCTAssertEqual(modelTypes.count, 54)
        let payload = PortableDataV2Payload(
            datasetID: UUID(),
            sourceGenerationID: UUID(),
            capturedAtMicroseconds:
                capturedAtMicroseconds,
            nextLocalRevision: 1,
            modelCounts: modelTypes.map {
                PortableDataModelCount(
                    modelType: $0,
                    rowCount: 0
                )
            },
            records: [],
            controls: [],
            activeAttachments: []
        )
        return try PortableDataV2Codec.makeDocument(
            payload: payload
        )
    }
}
#endif
