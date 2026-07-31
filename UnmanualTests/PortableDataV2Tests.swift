import Foundation
import XCTest
@testable import Unmanual

final class PortableDataV2Tests: XCTestCase {
    func testUnknownDeviceProjectionPolicyIsRejectedWithMatchingDigest()
        throws {
        let document = try makeDocument()
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try PortableDataV2Codec
                    .encode(document)
            ) as? [String: Any]
        )
        var payloadObject = try XCTUnwrap(
            root["payload"] as? [String: Any]
        )
        payloadObject["deviceProjectionPolicy"] =
            "unknown-local-projection-contract"
        root["payload"] = payloadObject
        root["transportSHA256"] =
            String(repeating: "0", count: 64)
        let intermediateData = try JSONSerialization
            .data(withJSONObject: root)
        let intermediate = try JSONDecoder
            .unmanualFoundation.decode(
                PortableDataV2Document.self,
                from: intermediateData
            )
        root["transportSHA256"] =
            try PortableDataV2Codec.transportDigest(
                intermediate.payload
            )
        let tampered = try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys]
        )

        XCTAssertThrowsError(
            try PortableDataV2Codec.decode(tampered)
        ) {
            XCTAssertEqual(
                $0 as? PortableDataV2Error,
                .unsupportedVersion
            )
        }
    }

    func testDoubleBitPatternRequiresLowercaseCanonicalHex()
        throws {
        let uppercase = PortableDataValue(
            kind: .double,
            doubleBitPatternHex: "3FF0000000000000"
        )
        XCTAssertThrowsError(
            try uppercase.recordDigestValue()
        ) {
            XCTAssertEqual(
                $0 as? PortableDataV2Error,
                .invalidValue
            )
        }
        XCTAssertEqual(
            try PortableDataValue(
                kind: .double,
                doubleBitPatternHex: "3ff0000000000000"
            ).recordDigestValue(),
            .double(1)
        )
    }
    func testPortablePerModelRecordLimitIsFrozenAt250000() {
        XCTAssertEqual(
            PortableDataV2Limits.maximumRecordsPerModel,
            250_000
        )
        XCTAssertNoThrow(
            try PortableDataV2Validator
                .validateModelRecordCount(250_000)
        )
        XCTAssertThrowsError(
            try PortableDataV2Validator
                .validateModelRecordCount(250_001)
        ) {
            XCTAssertEqual(
                $0 as? PortableDataV2Error,
                .invalidCount
            )
        }
    }

    func testPortableAttachmentLimitsMatchProductionStoreContract()
        throws {
        XCTAssertEqual(
            PortableBackupLimits.maximumAttachmentBytes,
            AttachmentFileStore.maximumFileBytes
        )
        let ownerID = UUID()
        XCTAssertNoThrow(
            try PortableDataV2Validator.validate(
                payload(
                    records: [try record()],
                    activeAttachments: [
                        attachment(
                            ownerID: ownerID,
                            byteCount:
                                AttachmentFileStore
                                .maximumFileBytes
                        )
                    ]
                )
            )
        )
        XCTAssertThrowsError(
            try PortableDataV2Validator.validate(
                payload(
                    records: [try record()],
                    activeAttachments: [
                        attachment(
                            ownerID: ownerID,
                            byteCount:
                                AttachmentFileStore
                                .maximumFileBytes + 1
                        )
                    ]
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? PortableDataV2Error,
                .invalidAttachment
            )
        }
        XCTAssertThrowsError(
            try PortableDataV2Validator.validate(
                payload(
                    records: [try record()],
                    activeAttachments: [
                        attachment(
                            ownerID: ownerID,
                            byteCount: 1,
                            typeIdentifier:
                                "public.plain-text"
                        )
                    ]
                )
            )
        )
    }

    func testPortableAttachmentOwnerCountAndByteBudgetsAreEnforced()
        throws {
        let ownerID = UUID()
        XCTAssertThrowsError(
            try PortableDataV2Validator.validate(
                payload(
                    records: [try record()],
                    activeAttachments: (0..<7).map {
                        attachment(
                            id: UUID(),
                            ownerID: ownerID,
                            byteCount: Int64($0 + 1)
                        )
                    }
                )
            )
        )
        XCTAssertThrowsError(
            try PortableDataV2Validator.validate(
                payload(
                    records: [try record()],
                    activeAttachments: (0..<4).map { _ in
                        attachment(
                            id: UUID(),
                            ownerID: ownerID,
                            byteCount:
                                15 * 1_024 * 1_024 + 1
                        )
                    }
                )
            )
        )
    }

    func testCurrentReadableV2RoundTripHasExact55ModelTaxonomyAndStableDigest()
        throws {
        let document = try makeDocument()
        let first = try PortableDataV2Codec.encode(document)
        let decoded = try PortableDataV2Codec.decode(first)
        let second = try PortableDataV2Codec.encode(decoded)

        XCTAssertEqual(decoded, document)
        XCTAssertEqual(first, second)
        XCTAssertEqual(decoded.payload.schemaVersion, "13.0.0")
        XCTAssertEqual(decoded.payload.modelCounts.count, 55)
        XCTAssertEqual(
            decoded.payload.modelCounts.map(\.modelType),
            DataInventoryTaxonomy
                .allDatabaseModelNames.sorted()
        )
        XCTAssertEqual(decoded.transportSHA256.count, 64)
    }

    func testFrozenV12ReadableV2StillRoundTripsExact54ModelTaxonomy()
        throws {
        let v12Payload = payload(
            schemaVersion:
                PortableDataSchemaContract.v12.schemaVersion,
            records: [try record()]
        )
        let document = try PortableDataV2Codec.makeDocument(
            payload: v12Payload
        )
        let decoded = try PortableDataV2Codec.decode(
            PortableDataV2Codec.encode(document)
        )

        XCTAssertEqual(decoded.payload.schemaVersion, "12.0.0")
        XCTAssertEqual(decoded.payload.modelCounts.count, 54)
        XCTAssertEqual(
            decoded.payload.modelCounts.map(\.modelType),
            PortableDataSchemaContract.v12.modelNames.sorted()
        )
    }

    func testDecodeRejectsDuplicateJSONKeysBeforeTypedDecoding() {
        let data = Data(
            """
            {
              "payload": {},
              "payload": {},
              "transportSHA256": "00"
            }
            """.utf8
        )
        XCTAssertThrowsError(
            try PortableDataV2Codec.decode(data)
        ) {
            XCTAssertEqual(
                $0 as? PortableDataV2Error,
                .duplicateJSONKey("payload")
            )
        }
    }

    func testDecodeRejectsUnknownEnvelopeField() throws {
        let data = try PortableDataV2Codec.encode(
            makeDocument()
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )
        object["unexpected"] = true
        let mutated = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try PortableDataV2Codec.decode(mutated)
        ) {
            XCTAssertEqual(
                $0 as? PortableDataV2Error,
                .invalidEnvelope
            )
        }
    }

    func testDecodeRejectsFieldTamperAndStaleTransportDigest()
        throws {
        let document = try makeDocument()
        let record = try XCTUnwrap(
            document.payload.records.first
        )
        var fields = record.fields
        fields[0] = PortableDataField(
            name: fields[0].name,
            value: PortableDataValue(
                kind: .timestampMicroseconds,
                integerValue: 1_750_000_000_000_001
            )
        )
        let changedRecord = PortableDataRecord(
            modelType: record.modelType,
            recordType: record.recordType,
            recordID: record.recordID,
            recordKey: record.recordKey,
            datasetID: record.datasetID,
            localRevision: record.localRevision,
            committedAtMicroseconds:
                record.committedAtMicroseconds,
            digestVersion: record.digestVersion,
            digestHex: record.digestHex,
            fields: fields
        )
        let changedPayload = payload(
            records: [changedRecord]
        )
        let stale = PortableDataV2Document(
            payload: changedPayload,
            transportSHA256: document.transportSHA256
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(stale)
        XCTAssertThrowsError(
            try PortableDataV2Codec.decode(data)
        ) {
            XCTAssertTrue(
                ($0 as? PortableDataV2Error)
                    == .digestMismatch
            )
        }
    }

    func testValidatorRejectsNonFiniteDoubleBits() {
        let value = PortableDataValue(
            kind: .double,
            doubleBitPatternHex: "7ff8000000000000"
        )
        XCTAssertThrowsError(try value.recordDigestValue()) {
            XCTAssertEqual(
                $0 as? PortableDataV2Error,
                .invalidValue
            )
        }
    }

    func testDecodeRejectsRecordWithMissingRequiredField()
        throws {
        let original = try record()
        let fields = original.fields.filter {
            $0.name != "createdAt"
        }
        let data = try encodedDocument(
            replacing: original,
            fields: fields
        )

        XCTAssertThrowsError(
            try PortableDataV2Codec.decode(data)
        ) {
            XCTAssertEqual(
                $0 as? PortableDataV2Error,
                .invalidRecord
            )
        }
    }

    func testRecordSchemasCoverFrozenV12AndCurrentV13Taxonomies() {
        let expectedV12 =
            PortableDataSchemaContract.v12.revisionedModelNames
        let expectedV13 =
            PortableDataSchemaContract.v13.revisionedModelNames

        XCTAssertEqual(
            Set(
                PortableDataV2RecordSchema
                    .fieldsByModelType.keys
            ),
            expectedV12
        )
        XCTAssertEqual(
            Set(
                PortableDataV2RecordSchema
                    .v13FieldsByModelType.keys
            ),
            expectedV13
        )
        XCTAssertEqual(expectedV12.count, 44)
        XCTAssertEqual(expectedV13.count, 45)
    }

    func testDecodeRejectsSelfConsistentV13FavoriteWithNonNFCVersion()
        throws {
        let nonNFC = "candidate-e\u{301}"
        let record = try favoriteRecord(
            contentVersion: nonNFC
        )
        let changedPayload = favoritePayload(
            records: [record]
        )
        let document = PortableDataV2Document(
            payload: changedPayload,
            transportSHA256:
                try PortableDataV2Codec.transportDigest(
                    changedPayload
                )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        XCTAssertThrowsError(
            try PortableDataV2Codec.decode(
                encoder.encode(document)
            )
        ) {
            XCTAssertEqual(
                $0 as? PortableDataV2Error,
                .invalidRecord
            )
        }
    }

    func testDecodeRejectsRecordWithUnexpectedField()
        throws {
        let original = try record()
        let fields = original.fields + [
            PortableDataField(
                name: "unexpected",
                value: PortableDataValue(
                    kind: .string,
                    stringValue: "value"
                )
            )
        ]
        let data = try encodedDocument(
            replacing: original,
            fields: fields
        )

        XCTAssertThrowsError(
            try PortableDataV2Codec.decode(data)
        ) {
            XCTAssertEqual(
                $0 as? PortableDataV2Error,
                .invalidRecord
            )
        }
    }

    func testDecodeRejectsRecordWithWrongFieldType()
        throws {
        let original = try record()
        let fields = original.fields.map {
            guard $0.name == "createdAt" else {
                return $0
            }
            return PortableDataField(
                name: $0.name,
                value: PortableDataValue(
                    kind: .string,
                    stringValue: "not-a-timestamp"
                )
            )
        }
        let data = try encodedDocument(
            replacing: original,
            fields: fields
        )

        XCTAssertThrowsError(
            try PortableDataV2Codec.decode(data)
        ) {
            XCTAssertEqual(
                $0 as? PortableDataV2Error,
                .invalidRecord
            )
        }
    }

    func testRecordSchemaAllowsNullOnlyForDeclaredNullableFields()
        throws {
        for (
            modelType,
            contracts
        ) in PortableDataV2RecordSchema.fieldsByModelType {
            let exactFields = contracts.map {
                PortableDataField(
                    name: $0.name,
                    value: value(for: $0.kind)
                )
            }
            XCTAssertNoThrow(
                try PortableDataV2RecordSchema.validate(
                    modelType: modelType,
                    recordType: modelType,
                    fields: exactFields,
                    schemaVersion:
                        PortableDataSchemaContract.v12.schemaVersion
                ),
                modelType
            )
            for (index, contract) in contracts.enumerated() {
                var nullFields = exactFields
                nullFields[index] = PortableDataField(
                    name: contract.name,
                    value: PortableDataValue(kind: .null)
                )
                if contract.allowsNull {
                    XCTAssertNoThrow(
                        try PortableDataV2RecordSchema.validate(
                            modelType: modelType,
                            recordType: modelType,
                            fields: nullFields,
                            schemaVersion:
                                PortableDataSchemaContract.v12
                                .schemaVersion
                        ),
                        "\(modelType).\(contract.name)"
                    )
                } else {
                    XCTAssertThrowsError(
                        try PortableDataV2RecordSchema.validate(
                            modelType: modelType,
                            recordType: modelType,
                            fields: nullFields,
                            schemaVersion:
                                PortableDataSchemaContract.v12
                                .schemaVersion
                        ),
                        "\(modelType).\(contract.name)"
                    )
                }
            }
        }
    }

    func testDecodeRequiresCommittedAtHeaderAndControlFields()
        throws {
        let data = try PortableDataV2Codec.encode(
            makeDocument()
        )
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )
        var payload = try XCTUnwrap(
            root["payload"] as? [String: Any]
        )
        var records = try XCTUnwrap(
            payload["records"] as? [[String: Any]]
        )
        records[0].removeValue(
            forKey: "committedAtMicroseconds"
        )
        payload["records"] = records
        root["payload"] = payload
        let missingCommittedAt = try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try PortableDataV2Codec.decode(
                missingCommittedAt
            )
        ) {
            XCTAssertEqual(
                $0 as? PortableDataV2Error,
                .invalidEnvelope
            )
        }

        root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )
        payload = try XCTUnwrap(
            root["payload"] as? [String: Any]
        )
        var controls = try XCTUnwrap(
            payload["controls"] as? [[String: Any]]
        )
        controls[0].removeValue(forKey: "fields")
        payload["controls"] = controls
        root["payload"] = payload
        let missingControlFields =
            try JSONSerialization.data(
                withJSONObject: root,
                options: [.sortedKeys]
            )
        XCTAssertThrowsError(
            try PortableDataV2Codec.decode(
                missingControlFields
            )
        ) {
            XCTAssertEqual(
                $0 as? PortableDataV2Error,
                .invalidEnvelope
            )
        }
    }

    func testValidatorRejectsUnrepresentableTimestamp()
        throws {
        XCTAssertThrowsError(
            try PortableDataV2Validator.validate(
                payload(
                    records: [try record()],
                    capturedAtMicroseconds: Int64.max
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? PortableDataV2Error,
                .invalidEnvelope
            )
        }
    }

    func testDecodeRejectsNonCanonicalFieldOrdering()
        throws {
        let original = try record()
        let data = try encodedDocument(
            replacing: original,
            fields: Array(original.fields.reversed())
        )

        XCTAssertThrowsError(
            try PortableDataV2Codec.decode(data)
        ) {
            XCTAssertEqual(
                $0 as? PortableDataV2Error,
                .invalidEnvelope
            )
        }
    }

    func testDecodeRejectsUppercaseRecordDigest()
        throws {
        let original = try record()
        let changedRecord = PortableDataRecord(
            modelType: original.modelType,
            recordType: original.recordType,
            recordID: original.recordID,
            recordKey: original.recordKey,
            datasetID: original.datasetID,
            localRevision: original.localRevision,
            committedAtMicroseconds:
                original.committedAtMicroseconds,
            digestVersion: original.digestVersion,
            digestHex: original.digestHex.uppercased(),
            fields: original.fields
        )
        let changedPayload = payload(records: [changedRecord])
        let document = PortableDataV2Document(
            payload: changedPayload,
            transportSHA256:
                try PortableDataV2Codec.transportDigest(
                    changedPayload
                )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        XCTAssertThrowsError(
            try PortableDataV2Codec.decode(
                encoder.encode(document)
            )
        ) {
            XCTAssertEqual(
                $0 as? PortableDataV2Error,
                .invalidRecord
            )
        }
    }

    private func makeDocument() throws
        -> PortableDataV2Document {
        try PortableDataV2Codec.makeDocument(
            payload: payload(records: [try record()])
        )
    }

    private func payload(
        schemaVersion: String =
            PortableDataSchemaContract.v13.schemaVersion,
        records: [PortableDataRecord],
        activeAttachments:
            [PortableDataAttachment] = [],
        capturedAtMicroseconds:
            Int64 = 1_750_000_000_000_000
    ) -> PortableDataV2Payload {
        let models = try! PortableDataSchemaContract.resolve(
            schemaVersion: schemaVersion
        ).modelNames
        let counts = models.sorted().map {
                PortableDataModelCount(
                    modelType: $0,
                    rowCount: ["HRTProfile", "RecordRevision"]
                        .contains($0) ? 1 : ($0 == "DatasetMetadata" ? 1 : 0)
                )
            }
        return PortableDataV2Payload(
            schemaVersion: schemaVersion,
            datasetID: datasetID,
            sourceGenerationID: generationID,
            capturedAtMicroseconds:
                capturedAtMicroseconds,
            nextLocalRevision: 2,
            modelCounts: counts,
            records: records,
            controls: [
                PortableDataControl(
                    modelType: "DatasetMetadata",
                    stableIdentity: DatasetMetadata.fixedKey,
                    disposition: .embeddedInEnvelope,
                    fields: [
                        PortableDataField(
                            name: "createdAt",
                            value: PortableDataValue(
                                kind: .timestampMicroseconds,
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
                                kind: .timestampMicroseconds,
                                integerValue:
                                    1_750_000_000_000_000
                            )
                        ),
                        PortableDataField(
                            name: "nextLocalRevision",
                            value: PortableDataValue(
                                kind: .integer,
                                integerValue: 2
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
            activeAttachments: activeAttachments
        )
    }

    private func attachment(
        id: UUID = UUID(),
        ownerID: UUID,
        byteCount: Int64,
        typeIdentifier: String = "public.png"
    ) -> PortableDataAttachment {
        PortableDataAttachment(
            attachmentID: id,
            ownerType:
                AttachmentOwnerType.labSample.rawValue,
            ownerID: ownerID,
            originalFilename: "report.png",
            typeIdentifier: typeIdentifier,
            byteCount: byteCount,
            sha256Hex: String(repeating: "a", count: 64)
        )
    }

    private func favoritePayload(
        records: [PortableDataRecord]
    ) -> PortableDataV2Payload {
        let counts = PortableDataSchemaContract.v13
            .modelNames.sorted().map {
                PortableDataModelCount(
                    modelType: $0,
                    rowCount:
                        $0 == "DatasetMetadata"
                            || $0 == "ContentFavoriteRecord"
                            || $0 == "RecordRevision"
                        ? 1 : 0
                )
            }
        return PortableDataV2Payload(
            schemaVersion:
                PortableDataSchemaContract.v13.schemaVersion,
            datasetID: datasetID,
            sourceGenerationID: generationID,
            capturedAtMicroseconds:
                1_750_000_000_000_000,
            nextLocalRevision: 2,
            modelCounts: counts,
            records: records,
            controls: [
                PortableDataControl(
                    modelType: "DatasetMetadata",
                    stableIdentity: DatasetMetadata.fixedKey,
                    disposition: .embeddedInEnvelope,
                    fields: [
                        PortableDataField(
                            name: "createdAt",
                            value: PortableDataValue(
                                kind: .timestampMicroseconds,
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
                                kind: .timestampMicroseconds,
                                integerValue:
                                    1_750_000_000_000_000
                            )
                        ),
                        PortableDataField(
                            name: "nextLocalRevision",
                            value: PortableDataValue(
                                kind: .integer,
                                integerValue: 2
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
            activeAttachments: []
        )
    }

    private func favoriteRecord(
        contentVersion: String
    ) throws -> PortableDataRecord {
        let recordID = UUID(
            uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )!
        let committedAt: Int64 =
            1_750_000_000_000_000
        let portableFields = [
            PortableDataField(
                name: "cardDigest",
                value: PortableDataValue(
                    kind: .string,
                    stringValue:
                        String(repeating: "a", count: 64)
                )
            ),
            PortableDataField(
                name: "contentID",
                value: PortableDataValue(
                    kind: .string,
                    stringValue: "card.non-nfc"
                )
            ),
            PortableDataField(
                name: "contentVersion",
                value: PortableDataValue(
                    kind: .string,
                    stringValue: contentVersion
                )
            ),
            PortableDataField(
                name: "createdAt",
                value: PortableDataValue(
                    kind: .timestampMicroseconds,
                    integerValue: committedAt
                )
            ),
            PortableDataField(
                name: "lastOperationID",
                value: PortableDataValue(
                    kind: .uuid,
                    uuidValue: UUID(
                        uuidString:
                            "11111111-2222-3333-4444-555555555555"
                    )!
                )
            ),
            PortableDataField(
                name: "removedAt",
                value: PortableDataValue(kind: .null)
            ),
            PortableDataField(
                name: "updatedAt",
                value: PortableDataValue(
                    kind: .timestampMicroseconds,
                    integerValue: committedAt
                )
            )
        ]
        let digestFields = try portableFields.map {
            RecordDigestV1.Field(
                $0.name,
                try $0.value.recordDigestValue()
            )
        }
        return PortableDataRecord(
            modelType: ContentFavoriteContract.recordType,
            recordType: ContentFavoriteContract.recordType,
            recordID: recordID,
            recordKey:
                ContentFavoriteContract.recordKey(recordID),
            datasetID: datasetID,
            localRevision: 1,
            committedAtMicroseconds: committedAt,
            digestVersion: RecordDigestV1.version,
            digestHex: try RecordDigestV1.sha256Hex(
                recordType:
                    ContentFavoriteContract.recordType,
                recordID: recordID,
                fields: digestFields
            ),
            fields: portableFields
        )
    }

    private func record() throws -> PortableDataRecord {
        let recordID = UUID(
            uuidString: "11111111-2222-3333-4444-555555555555"
        )!
        let fields = [
            RecordDigestV1.Field(
                "startDate",
                .timestampMicroseconds(
                    1_750_000_000_000_000
                )
            ),
            RecordDigestV1.Field(
                "activePeriodStartDate",
                .timestampMicroseconds(
                    1_750_000_000_000_000
                )
            ),
            RecordDigestV1.Field(
                "createdAt",
                .timestampMicroseconds(
                    1_750_000_000_000_000
                )
            )
        ]
        return PortableDataRecord(
            modelType: "HRTProfile",
            recordType: "HRTProfile",
            recordID: recordID,
            recordKey:
                "HRTProfile:"
                    + recordID.uuidString.lowercased(),
            datasetID: datasetID,
            localRevision: 1,
            committedAtMicroseconds:
                1_750_000_000_000_000,
            digestVersion: RecordDigestV1.version,
            digestHex: try RecordDigestV1.sha256Hex(
                recordType: "HRTProfile",
                recordID: recordID,
                fields: fields
            ),
            fields: fields.sorted {
                $0.name < $1.name
            }.map {
                PortableDataField(
                    name: $0.name,
                    value: PortableDataValue($0.value)
                )
            }
        )
    }

    private func encodedDocument(
        replacing original: PortableDataRecord,
        fields: [PortableDataField]
    ) throws -> Data {
        let digestFields = try fields.map {
            RecordDigestV1.Field(
                $0.name,
                try $0.value.recordDigestValue()
            )
        }
        let changedRecord = PortableDataRecord(
            modelType: original.modelType,
            recordType: original.recordType,
            recordID: original.recordID,
            recordKey: original.recordKey,
            datasetID: original.datasetID,
            localRevision: original.localRevision,
            committedAtMicroseconds:
                original.committedAtMicroseconds,
            digestVersion: original.digestVersion,
            digestHex: try RecordDigestV1.sha256Hex(
                recordType: original.recordType,
                recordID: original.recordID,
                fields: digestFields
            ),
            fields: fields
        )
        let changedPayload = payload(records: [changedRecord])
        let document = PortableDataV2Document(
            payload: changedPayload,
            transportSHA256:
                try PortableDataV2Codec.transportDigest(
                    changedPayload
                )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    private func value(
        for kind: PortableDataValue.Kind
    ) -> PortableDataValue {
        switch kind {
        case .null:
            PortableDataValue(kind: .null)
        case .bool:
            PortableDataValue(
                kind: .bool,
                boolValue: true
            )
        case .integer:
            PortableDataValue(
                kind: .integer,
                integerValue: 1
            )
        case .double:
            PortableDataValue(
                kind: .double,
                doubleBitPatternHex: "3ff0000000000000"
            )
        case .string:
            PortableDataValue(
                kind: .string,
                stringValue: "value"
            )
        case .uuid:
            PortableDataValue(
                kind: .uuid,
                uuidValue: datasetID
            )
        case .timestampMicroseconds:
            PortableDataValue(
                kind: .timestampMicroseconds,
                integerValue: 1
            )
        }
    }

    private var datasetID: UUID {
        UUID(
            uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )!
    }

    private var generationID: UUID {
        UUID(
            uuidString: "99999999-8888-7777-6666-555555555555"
        )!
    }
}
