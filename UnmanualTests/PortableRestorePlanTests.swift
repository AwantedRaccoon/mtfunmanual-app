import CryptoKit
import XCTest
@testable import Unmanual

final class PortableRestorePlanTests: XCTestCase {
    func testSameDatasetConflictMatrixNeverUsesLastWriteWins()
        throws {
        let local = try document(
            datasetID: datasetID,
            records: [
                record(id: idA, revision: 2, text: "local"),
                record(id: idB, revision: 1, text: "same")
            ]
        )
        let incoming = try document(
            datasetID: datasetID,
            records: [
                record(id: idA, revision: 2, text: "tampered"),
                record(id: idB, revision: 2, text: "same"),
                record(id: idC, revision: 1, text: "new")
            ]
        )

        let plan = try PortableImportPlanner.makePlan(
            mode: .merge,
            packageRootDigest: digest("package"),
            localStateDigest: digest("local"),
            incoming: incoming,
            local: local
        )

        XCTAssertEqual(
            plan.noOpRecordKeys,
            ["JourneyEntry:\(idB.uuidString.lowercased())"]
        )
        XCTAssertEqual(
            Set(plan.conflicts.map(\.kind)),
            [.sameRevisionDifferentDigest, .missingLocalAmbiguous]
        )
        XCTAssertFalse(plan.canConfirm)
    }

    func testCrossDatasetCollisionRequiresExplicitChoice()
        throws {
        let local = try document(
            datasetID: datasetID,
            records: [
                record(id: idA, revision: 1, text: "local")
            ]
        )
        let incomingDatasetID = UUID()
        let incoming = try document(
            datasetID: incomingDatasetID,
            records: [
                record(
                    id: idA,
                    revision: 2,
                    text: "remote",
                    datasetID: incomingDatasetID
                ),
                record(
                    id: idC,
                    revision: 1,
                    text: "new",
                    datasetID: incomingDatasetID
                )
            ]
        )
        let newKey = "JourneyEntry:"
            + idC.uuidString.lowercased()

        let plan = try PortableImportPlanner.makePlan(
            mode: .merge,
            packageRootDigest: digest("package"),
            localStateDigest: digest("local"),
            incoming: incoming,
            local: local,
            acceptedDifferentDatasetRecordKeys: [newKey]
        )

        XCTAssertEqual(plan.acceptedRecordKeys, [newKey])
        XCTAssertEqual(
            plan.conflicts,
            [
                PortableImportConflict(
                    recordKey: "JourneyEntry:"
                        + idA.uuidString.lowercased(),
                    kind: .crossDatasetIdentityCollision
                )
            ]
        )
        XCTAssertFalse(plan.canConfirm)
    }

    func testTerminalDeletionAlwaysBlocksMerge() throws {
        let key = "JourneyEntry:"
            + idA.uuidString.lowercased()
        let local = try document(
            datasetID: datasetID,
            records: []
        )
        let incoming = try document(
            datasetID: datasetID,
            records: [
                record(id: idA, revision: 1, text: "deleted")
            ]
        )

        let plan = try PortableImportPlanner.makePlan(
            mode: .merge,
            packageRootDigest: digest("package"),
            localStateDigest: digest("local"),
            incoming: incoming,
            local: local,
            terminalRecordKeys: [key]
        )

        XCTAssertEqual(
            plan.conflicts,
            [
                PortableImportConflict(
                    recordKey: key,
                    kind: .terminalDeletion
                )
            ]
        )
    }

    func testRestoreRequiresEmptyLocalDataset() throws {
        let local = try document(
            datasetID: datasetID,
            records: [
                record(id: idA, revision: 1, text: "local")
            ]
        )
        let incoming = try document(
            datasetID: UUID(),
            records: []
        )
        XCTAssertThrowsError(
            try PortableImportPlanner.makePlan(
                mode: .restore,
                packageRootDigest: digest("package"),
                localStateDigest: digest("local"),
                incoming: incoming,
                local: local
            )
        ) {
            XCTAssertEqual(
                $0 as? PortableImportPlanError,
                .invalidMode
            )
        }
    }

    func testConfirmationIsBoundToBothDigests() throws {
        let local = try document(
            datasetID: datasetID,
            records: []
        )
        let incoming = try document(
            datasetID: UUID(),
            records: []
        )
        let packageDigest = digest("package")
        let localDigest = digest("local")
        let plan = try PortableImportPlanner.makePlan(
            mode: .restore,
            packageRootDigest: packageDigest,
            localStateDigest: localDigest,
            incoming: incoming,
            local: local,
            localIsRestoreEligible: true
        )

        XCTAssertNoThrow(
            try PortableImportPlanner.validateConfirmation(
                plan,
                packageRootDigest: packageDigest,
                localStateDigest: localDigest
            )
        )
        XCTAssertThrowsError(
            try PortableImportPlanner.validateConfirmation(
                plan,
                packageRootDigest: digest("changed"),
                localStateDigest: localDigest
            )
        ) {
            XCTAssertEqual(
                $0 as? PortableImportPlanError,
                .stalePlan
            )
        }
    }

    func testPlanRequestIdentityRejectsLateModeAndPackageResults()
        throws {
        let local = try document(
            datasetID: datasetID,
            records: []
        )
        let incoming = try document(
            datasetID: UUID(),
            records: []
        )
        let packageA = digest("package-a")
        let packageB = digest("package-b")
        let oldRequest =
            PortableRestorePlanRequestIdentity(
                requestID: UUID(),
                packageRootDigest: packageA,
                mode: .restore
            )
        let currentRequest =
            PortableRestorePlanRequestIdentity(
                requestID: UUID(),
                packageRootDigest: packageB,
                mode: .replace
            )
        let oldPlan = try PortableImportPlanner
            .makePlan(
                mode: .restore,
                packageRootDigest: packageA,
                localStateDigest: digest("local"),
                incoming: incoming,
                local: local,
                localIsRestoreEligible: true
            )
        let currentPlan = try PortableImportPlanner
            .makePlan(
                mode: .replace,
                packageRootDigest: packageB,
                localStateDigest: digest("local"),
                incoming: incoming,
                local: local
            )

        XCTAssertFalse(
            oldRequest.accepts(
                requestID:
                    currentRequest.requestID,
                packageRootDigest: packageB,
                mode: .replace,
                plan: oldPlan
            )
        )
        XCTAssertTrue(
            currentRequest.accepts(
                requestID:
                    currentRequest.requestID,
                packageRootDigest: packageB,
                mode: .replace,
                plan: currentPlan
            )
        )
        XCTAssertFalse(
            currentRequest.accepts(
                requestID:
                    currentRequest.requestID,
                packageRootDigest: packageA,
                mode: .replace,
                plan: currentPlan
            )
        )
    }

    private let datasetID = UUID(
        uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    )!
    private let idA = UUID(
        uuidString: "11111111-1111-1111-1111-111111111111"
    )!
    private let idB = UUID(
        uuidString: "22222222-2222-2222-2222-222222222222"
    )!
    private let idC = UUID(
        uuidString: "33333333-3333-3333-3333-333333333333"
    )!

    private func document(
        datasetID: UUID,
        records: [PortableDataRecord]
    ) throws -> PortableDataV2Document {
        let counts = DataInventoryTaxonomy
            .allDatabaseModelNames
            .sorted()
            .map {
                PortableDataModelCount(
                    modelType: $0,
                    rowCount: $0 == "JourneyEntry"
                        ? Int64(records.count)
                        : $0 == "RecordRevision"
                            ? Int64(records.count)
                            : 0
                )
            }
        return try PortableDataV2Codec.makeDocument(
            payload: PortableDataV2Payload(
                datasetID: datasetID,
                sourceGenerationID: UUID(),
                capturedAtMicroseconds: 1,
                nextLocalRevision: 10,
                modelCounts: counts,
                records: records,
                controls: [],
                activeAttachments: []
            )
        )
    }

    private func record(
        id: UUID,
        revision: Int64,
        text: String,
        datasetID: UUID? = nil
    ) -> PortableDataRecord {
        let fields = [
            RecordDigestV1.Field(
                "createdAt",
                .timestampMicroseconds(1)
            ),
            RecordDigestV1.Field(
                "kindRawValue",
                .string("moment")
            ),
            RecordDigestV1.Field(
                "occurredAt",
                .timestampMicroseconds(1)
            ),
            RecordDigestV1.Field("regimenVersionID", .null),
            RecordDigestV1.Field("text", .string(text))
        ]
        return PortableDataRecord(
            modelType: "JourneyEntry",
            recordType: "JourneyEntry",
            recordID: id,
            recordKey: "JourneyEntry:"
                + id.uuidString.lowercased(),
            datasetID: datasetID ?? self.datasetID,
            localRevision: revision,
            committedAtMicroseconds: 1,
            digestVersion: RecordDigestV1.version,
            digestHex: try! RecordDigestV1.sha256Hex(
                recordType: "JourneyEntry",
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

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
