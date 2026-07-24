import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class PersonalTimelineStoreTests: XCTestCase {
    func testAttachmentOnlyLabRequiresPreparedAttachmentAndCommitsAtomically() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_735_732_860),
            timeZoneIdentifier: "Asia/Shanghai",
            precision: .minute,
            provenance: .userEntered
        )
        do {
            _ = try await writer.createLabSample(
                CreateLabSampleCommand(
                    operationID: UUID(),
                    timestamp: timestamp,
                    newDefinitions: [],
                    results: []
                )
            )
            XCTFail("A lab sample cannot be empty")
        } catch {
            XCTAssertEqual(error as? PersonalTimelineWriteFailure, .invalidInput)
        }

        let sampleID = UUID()
        let attachmentID = UUID()
        let attachmentOperationID = UUID()
        _ = try await writer.createLabSample(
            CreateLabSampleCommand(
                operationID: UUID(),
                sampleID: sampleID,
                timestamp: timestamp,
                newDefinitions: [],
                results: [],
                attachments: [
                    PreparedAttachmentMetadata(
                        operationID: attachmentOperationID,
                        attachmentID: attachmentID,
                        relativePath: "Attachments/\(attachmentID.uuidString.lowercased())/payload.pdf",
                        originalFilename: "report.pdf",
                        typeIdentifier: "com.adobe.pdf",
                        byteCount: 3,
                        sha256Hex: String(repeating: "a", count: 64)
                    )
                ]
            )
        )
        let savedSample = try await reader.labSample(id: sampleID)
        let savedAttachments = try await reader.attachments(
            ownerType: .labSample,
            ownerID: sampleID
        )
        XCTAssertNotNil(savedSample)
        XCTAssertEqual(savedAttachments.map(\.id), [attachmentID])
    }

    func testCreateLabSamplePreservesRepeatedResultsAndOriginalFacts() async throws {
        let container = try AppModelContainerFactory.makeInMemoryPersonalTimelineContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: "UTC"
        )
        _ = try TodayExecutionBackfill.run(in: container)
        _ = try PersonalTimelineBackfill.run(in: container)

        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let itemID = UUID()
        let sampleID = UUID()
        let firstResultID = UUID()
        let secondResultID = UUID()
        let sampledAt = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_735_732_860),
            timeZoneIdentifier: "Asia/Shanghai",
            precision: .minute,
            provenance: .userEntered
        )

        let commit = try await writer.createLabSample(
            CreateLabSampleCommand(
                operationID: UUID(),
                sampleID: sampleID,
                timestamp: sampledAt,
                specimenOriginal: "血清",
                contextNote: "  空腹；原报告重复测定  ",
                newDefinitions: [
                    LabItemDefinitionInput(
                        id: itemID,
                        displayName: "  自定义项目  ",
                        code: " CUSTOM "
                    )
                ],
                results: [
                    LabResultInput(
                        id: firstResultID,
                        itemDefinitionID: itemID,
                        rawValueOriginal: "  < 172.50  ",
                        unitOriginal: " pmol/L ",
                        referenceRangeOriginal: " 实验室原文 40–200 ",
                        assayOrVariantOriginal: " 方法 A "
                    ),
                    LabResultInput(
                        id: secondResultID,
                        itemDefinitionID: itemID,
                        rawValueOriginal: "171.75",
                        unitOriginal: "pmol/L",
                        referenceRangeOriginal: nil,
                        assayOrVariantOriginal: "方法 B"
                    )
                ],
                committedAt: sampledAt.instant
            )
        )

        XCTAssertEqual(commit.sampleID, sampleID)
        XCTAssertTrue(commit.didCreate)

        let sample = try await reader.labSample(id: sampleID)
        XCTAssertEqual(sample?.id, sampleID)
        XCTAssertEqual(sample?.timestamp, sampledAt)
        XCTAssertEqual(sample?.specimenOriginal, "血清")
        XCTAssertEqual(sample?.contextNote, "  空腹；原报告重复测定  ")
        XCTAssertEqual(sample?.results.map(\.id), [firstResultID, secondResultID])
        XCTAssertEqual(sample?.results.map(\.itemDefinitionID), [itemID, itemID])
        XCTAssertEqual(sample?.results.map(\.itemNameSnapshot), ["  自定义项目  ", "  自定义项目  "])
        XCTAssertEqual(sample?.results.map(\.itemCodeSnapshot), [" CUSTOM ", " CUSTOM "])
        XCTAssertEqual(sample?.results.map(\.rawValueOriginal), ["  < 172.50  ", "171.75"])
        XCTAssertEqual(sample?.results.map(\.canonicalDecimalString), ["172.5", "171.75"])
        XCTAssertEqual(sample?.results.map(\.unitOriginal), [" pmol/L ", "pmol/L"])
        XCTAssertEqual(
            sample?.results.map(\.referenceRangeOriginal),
            [" 实验室原文 40–200 ", nil]
        )
        XCTAssertEqual(sample?.results.map(\.assayOrVariantOriginal), [" 方法 A ", "方法 B"])
    }

    func testCreateLabSampleReplaysSameOperationAndRejectsChangedPayload() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let operationID = UUID()
        let definitionID = UUID()
        let sampleID = UUID()
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_735_732_860),
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        let command = CreateLabSampleCommand(
            operationID: operationID,
            sampleID: sampleID,
            timestamp: timestamp,
            newDefinitions: [
                LabItemDefinitionInput(id: definitionID, displayName: "自定义项目")
            ],
            results: [
                LabResultInput(
                    itemDefinitionID: definitionID,
                    rawValueOriginal: "10",
                    unitOriginal: "unit"
                )
            ],
            committedAt: timestamp.instant
        )

        let first = try await writer.createLabSample(command)
        let replay = try await writer.createLabSample(command)
        XCTAssertTrue(first.didCreate)
        XCTAssertFalse(replay.didCreate)
        XCTAssertEqual(replay.sampleID, sampleID)

        let changed = CreateLabSampleCommand(
            operationID: operationID,
            sampleID: sampleID,
            timestamp: timestamp,
            contextNote: "不同内容",
            newDefinitions: [
                LabItemDefinitionInput(id: definitionID, displayName: "自定义项目")
            ],
            results: [
                LabResultInput(
                    itemDefinitionID: definitionID,
                    rawValueOriginal: "10",
                    unitOriginal: "unit"
                )
            ],
            committedAt: timestamp.instant
        )
        do {
            _ = try await writer.createLabSample(changed)
            XCTFail("Changed payload must not replay")
        } catch {
            XCTAssertEqual(error as? PersonalTimelineWriteFailure, .operationConflict)
        }
    }

    func testCreateLabSampleDigestTreatsRawWhitespaceAsFact() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let operationID = UUID()
        let definitionID = UUID()
        let sampleID = UUID()
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_735_732_860),
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        let original = CreateLabSampleCommand(
            operationID: operationID,
            sampleID: sampleID,
            timestamp: timestamp,
            specimenOriginal: "血清",
            contextNote: "空腹",
            newDefinitions: [
                LabItemDefinitionInput(
                    id: definitionID,
                    displayName: "E2",
                    code: "E2"
                )
            ],
            results: [
                LabResultInput(
                    itemDefinitionID: definitionID,
                    rawValueOriginal: "10",
                    unitOriginal: "unit",
                    referenceRangeOriginal: "1-20",
                    assayOrVariantOriginal: "A"
                )
            ],
            committedAt: timestamp.instant
        )
        _ = try await writer.createLabSample(original)

        let whitespaceChanged = CreateLabSampleCommand(
            operationID: operationID,
            sampleID: sampleID,
            timestamp: timestamp,
            specimenOriginal: " 血清 ",
            contextNote: " 空腹 ",
            newDefinitions: [
                LabItemDefinitionInput(
                    id: definitionID,
                    displayName: " E2 ",
                    code: " E2 "
                )
            ],
            results: [
                LabResultInput(
                    itemDefinitionID: definitionID,
                    rawValueOriginal: "10",
                    unitOriginal: " unit ",
                    referenceRangeOriginal: " 1-20 ",
                    assayOrVariantOriginal: " A "
                )
            ],
            committedAt: timestamp.instant
        )
        do {
            _ = try await writer.createLabSample(whitespaceChanged)
            XCTFail("Raw whitespace changes must conflict with an existing operation")
        } catch {
            XCTAssertEqual(error as? PersonalTimelineWriteFailure, .operationConflict)
        }
    }

    func testCreateLabSampleRejectsMoreResultsThanTheReaderCanOpen() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let definitionID = UUID()
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 1_735_732_860),
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        let results = (0..<257).map { index in
            LabResultInput(
                itemDefinitionID: definitionID,
                rawValueOriginal: "\(index)",
                unitOriginal: "unit"
            )
        }

        do {
            _ = try await writer.createLabSample(
                CreateLabSampleCommand(
                    operationID: UUID(),
                    timestamp: timestamp,
                    newDefinitions: [
                        LabItemDefinitionInput(
                            id: definitionID,
                            displayName: "自定义项目"
                        )
                    ],
                    results: results,
                    committedAt: timestamp.instant
                )
            )
            XCTFail("Writer must not create a sample the bounded reader rejects")
        } catch {
            XCTAssertEqual(error as? PersonalTimelineWriteFailure, .invalidInput)
        }
    }

    func testBackfillCreatesOneSyntheticSamplePerLegacyLabWithoutLosingFacts() throws {
        let container = try AppModelContainerFactory.makeInMemoryPersonalTimelineContainer()
        let legacyID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let sampledAt = Date(timeIntervalSince1970: 1_700_000_050)
        let context = ModelContext(container)
        context.insert(
            LabRecord(
                id: legacyID,
                itemName: " 雌二醇 ",
                itemCode: " E2 ",
                rawValue: " < 123.40 ",
                numericValue: 123.4,
                unit: " pmol/L ",
                sampledAt: sampledAt,
                referenceRangeOriginal: " 实验室原文 ",
                contextNote: " 旧版备注 ",
                createdAt: sampledAt
            )
        )
        try context.save()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: "Asia/Shanghai"
        )
        _ = try TodayExecutionBackfill.run(in: container)

        let first = try PersonalTimelineBackfill.run(in: container)
        let second = try PersonalTimelineBackfill.run(in: container)
        XCTAssertTrue(first.didComplete)
        XCTAssertTrue(first.didChangeStore)
        XCTAssertFalse(second.didChangeStore)

        let verification = ModelContext(container)
        let samples = try verification.fetch(FetchDescriptor<LabSampleRecord>())
        let definitions = try verification.fetch(FetchDescriptor<LabItemDefinitionRecord>())
        let results = try verification.fetch(FetchDescriptor<LabResultRecord>())
        let receipts = try verification.fetch(
            FetchDescriptor<OperationReceiptRecord>()
        ).filter { $0.resultRecordType == "LabSampleRecord" }
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(definitions.count, 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(receipts.count, 1)
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(samples[0].id, PersonalTimelineBackfill.legacySampleID(for: legacyID))
        XCTAssertEqual(receipt.operationID, samples[0].operationID)
        XCTAssertEqual(receipt.resultRecordID, samples[0].id)
        XCTAssertEqual(receipt.commandDigest.count, 64)
        XCTAssertEqual(receipt.committedAt, sampledAt)
        XCTAssertEqual(samples[0].contextNote, " 旧版备注 ")
        XCTAssertEqual(results[0].id, legacyID)
        XCTAssertEqual(definitions[0].displayName, " 雌二醇 ")
        XCTAssertEqual(definitions[0].code, " E2 ")
        XCTAssertEqual(results[0].itemNameSnapshot, " 雌二醇 ")
        XCTAssertEqual(results[0].itemCodeSnapshot, " E2 ")
        XCTAssertEqual(results[0].rawValueOriginal, " < 123.40 ")
        XCTAssertEqual(results[0].canonicalDecimalString, "123.4")
        XCTAssertEqual(results[0].unitOriginal, " pmol/L ")
        XCTAssertEqual(results[0].referenceRangeOriginal, " 实验室原文 ")

        XCTAssertNoThrow(
            try PersonalTimelineRelationshipValidator.validate(
                in: verification,
                failure: .corruptionSuspected
            )
        )
        verification.delete(receipt)
        try verification.save()
        XCTAssertThrowsError(
            try PersonalTimelineRelationshipValidator.validate(
                in: verification,
                failure: .corruptionSuspected
            )
        )
    }

    func testLaterSampleCanReuseAnExistingDefinitionWithoutUnitConversion() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let definitionID = UUID()
        let firstInstant = Date(timeIntervalSince1970: 1_735_732_800)
        let firstTimestamp = try HistoricalTimestamp.captured(
            instant: firstInstant,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        _ = try await writer.createLabSample(
            CreateLabSampleCommand(
                operationID: UUID(),
                timestamp: firstTimestamp,
                newDefinitions: [
                    LabItemDefinitionInput(id: definitionID, displayName: "自定义项目")
                ],
                results: [
                    LabResultInput(
                        itemDefinitionID: definitionID,
                        rawValueOriginal: "10",
                        unitOriginal: "unit-A"
                    )
                ],
                committedAt: firstInstant
            )
        )
        let secondID = UUID()
        let secondInstant = firstInstant.addingTimeInterval(86_400)
        let secondTimestamp = try HistoricalTimestamp.captured(
            instant: secondInstant,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        _ = try await writer.createLabSample(
            CreateLabSampleCommand(
                operationID: UUID(),
                sampleID: secondID,
                timestamp: secondTimestamp,
                newDefinitions: [],
                results: [
                    LabResultInput(
                        itemDefinitionID: definitionID,
                        rawValueOriginal: "11",
                        unitOriginal: "unit-B"
                    )
                ],
                committedAt: secondInstant
            )
        )
        let second = try await reader.labSample(id: secondID)
        XCTAssertEqual(second?.results.first?.itemDefinitionID, definitionID)
        XCTAssertEqual(second?.results.first?.unitOriginal, "unit-B")
    }

    private func preparedContainer() throws -> ModelContainer {
        let container = try AppModelContainerFactory.makeInMemoryPersonalTimelineContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: "UTC"
        )
        _ = try TodayExecutionBackfill.run(in: container)
        _ = try PersonalTimelineBackfill.run(in: container)
        return container
    }
}
