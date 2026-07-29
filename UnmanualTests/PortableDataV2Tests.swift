import Foundation
import XCTest
@testable import Unmanual

final class PortableDataV2Tests: XCTestCase {
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

    func testReadableV2RoundTripHasExact54ModelTaxonomyAndStableDigest()
        throws {
        let document = try makeDocument()
        let first = try PortableDataV2Codec.encode(document)
        let decoded = try PortableDataV2Codec.decode(first)
        let second = try PortableDataV2Codec.encode(decoded)

        XCTAssertEqual(decoded, document)
        XCTAssertEqual(first, second)
        XCTAssertEqual(decoded.payload.modelCounts.count, 54)
        XCTAssertEqual(
            decoded.payload.modelCounts.map(\.modelType),
            DataInventoryTaxonomy
                .allDatabaseModelNames.sorted()
        )
        XCTAssertEqual(decoded.transportSHA256.count, 64)
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

    func testRecordSchemaCoversEveryRevisionedTaxonomyModel() {
        let expected = Set(
            DataInventoryTaxonomy.allDatabaseModelNames
        )
        .subtracting(
            DataInventoryTaxonomy.allowedUnrevisionedControlModels
        )
        .subtracting(["RecordRevision"])

        XCTAssertEqual(
            Set(
                PortableDataV2RecordSchema
                    .fieldsByModelType.keys
            ),
            expected
        )
        XCTAssertEqual(expected.count, 44)
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
                    fields: exactFields
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
                            fields: nullFields
                        ),
                        "\(modelType).\(contract.name)"
                    )
                } else {
                    XCTAssertThrowsError(
                        try PortableDataV2RecordSchema.validate(
                            modelType: modelType,
                            recordType: modelType,
                            fields: nullFields
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

    private func makeDocument() throws
        -> PortableDataV2Document {
        try PortableDataV2Codec.makeDocument(
            payload: payload(records: [try record()])
        )
    }

    private func payload(
        records: [PortableDataRecord],
        activeAttachments:
            [PortableDataAttachment] = []
    ) -> PortableDataV2Payload {
        let counts = DataInventoryTaxonomy
            .allDatabaseModelNames.sorted().map {
                PortableDataModelCount(
                    modelType: $0,
                    rowCount: ["HRTProfile", "RecordRevision"]
                        .contains($0) ? 1 : ($0 == "DatasetMetadata" ? 1 : 0)
                )
            }
        return PortableDataV2Payload(
            datasetID: datasetID,
            sourceGenerationID: generationID,
            capturedAtMicroseconds: 1_750_000_000_000_000,
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
            fields: fields.map {
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
