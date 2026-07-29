import PDFKit
import SwiftData
import XCTest
@testable import Unmanual

final class VisitSummaryTests: XCTestCase {
    func testDefaultPrivacySelectionExcludesDirectIdentifiersAndPhotos() {
        let selection = VisitSummaryPrivacySelection()
        XCTAssertFalse(selection.includeName)
        XCTAssertTrue(selection.includeGeneratedDate)
        XCTAssertTrue(selection.includeRegimen)
        XCTAssertTrue(selection.includeLabs)
        XCTAssertFalse(selection.includePhotos)
        XCTAssertFalse(selection.includeSensitiveNotes)
    }

    func testPolicyRejectsInvalidRangeLongRangeAndInvalidIncludedName() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        XCTAssertThrowsError(
            try VisitSummaryPolicy.validatedInterval(
                configuration: VisitSummaryConfiguration(
                    start: now,
                    end: now.addingTimeInterval(-1)
                )
            )
        ) {
            XCTAssertEqual($0 as? VisitSummaryFailure, .invalidRange)
        }
        XCTAssertThrowsError(
            try VisitSummaryPolicy.validatedInterval(
                configuration: VisitSummaryConfiguration(
                    start: now.addingTimeInterval(-4_000 * 86_400),
                    end: now
                )
            )
        ) {
            XCTAssertEqual($0 as? VisitSummaryFailure, .rangeTooLarge)
        }
        var privacy = VisitSummaryPrivacySelection()
        privacy.includeName = true
        XCTAssertThrowsError(
            try VisitSummaryPolicy.validatedInterval(
                configuration: VisitSummaryConfiguration(
                    start: now.addingTimeInterval(-86_400),
                    end: now,
                    subjectName: "   ",
                    privacy: privacy
                )
            )
        ) {
            XCTAssertEqual($0 as? VisitSummaryFailure, .invalidName)
        }
    }

    func testCSVUsesCRLFQuotesAndNeutralizesSpreadsheetFormulaPrefixes() {
        let value = VisitSummaryCSVEncoder.string(
            headers: ["text", "note"],
            rows: [
                ["=SUM(1,1)", "line one\nline \"two\""],
                ["+cmd", "@value"],
                ["-1", "\tformula"],
                ["\n=HYPERLINK(\"bad\")", "safe"]
            ]
        )
        XCTAssertEqual(
            value,
            "\"text\",\"note\"\r\n"
                + "\"'=SUM(1,1)\",\"line one\nline \"\"two\"\"\"\r\n"
                + "\"'+cmd\",\"'@value\"\r\n"
                + "\"'-1\",\"'\tformula\"\r\n"
                + "\"'\n=HYPERLINK(\"\"bad\"\")\",\"safe\"\r\n"
        )
        XCTAssertFalse(value.contains("\n\"+cmd\""))
    }

    @MainActor
    func testPDFContainsMultiplePagesAndRequiredDisclaimer() throws {
        let snapshot = makeSnapshot(
            events: (0..<180).map {
                VisitSummaryJourneyItem(
                    id: UUID(),
                    occurredAt: Date(timeIntervalSince1970: 1_750_000_000 + Double($0)),
                    kind: .moment,
                    text: "这是一条用于验证中文分页、换行与内容完整性的较长记录 \($0)。"
                )
            }
        )
        let data = try VisitSummaryPDFRenderer.render(snapshot)
        let document = PDFDocument(data: data)
        XCTAssertNotNil(document)
        XCTAssertGreaterThan(document?.pageCount ?? 0, 1)
        let text = (0..<(document?.pageCount ?? 0))
            .compactMap { document?.page(at: $0)?.string }
            .joined(separator: "\n")
        let compactText = text.replacingOccurrences(
            of: "\\s+",
            with: "",
            options: .regularExpression
        )
        XCTAssertTrue(text.contains("就诊摘要"))
        XCTAssertTrue(
            compactText.contains(
                VisitSummarySnapshot.disclaimer.replacingOccurrences(
                    of: "\\s+",
                    with: "",
                    options: .regularExpression
                )
            )
        )
        XCTAssertTrue(text.contains("离开 App 后"))
    }

    func testCSVPackageAlwaysContainsFiveStableFiles() {
        let files = VisitSummaryCSVEncoder.encode(makeSnapshot(events: []))
        XCTAssertEqual(
            files.map(\.filename),
            [
                "regimens.csv",
                "administrations.csv",
                "labs.csv",
                "status.csv",
                "journey.csv"
            ]
        )
        XCTAssertTrue(
            files.allSatisfy {
                String(data: $0.data, encoding: .utf8)?.hasSuffix("\r\n")
                    == true
            }
        )
    }

    @MainActor
    func testCanonicalDisclosureProjectionDrivesPreviewPDFAndCSV()
        throws {
        let snapshot = try makeDisclosureSnapshot()
        let projection = VisitSummaryDisclosureProjection(
            snapshot: snapshot
        )
        let previewText = (
            projection.metadataRows
                + projection.sections.flatMap(\.rows)
        ).joined(separator: "\n")
        let csvText = VisitSummaryCSVEncoder
            .encode(snapshot)
            .compactMap {
                String(data: $0.data, encoding: .utf8)
            }
            .joined(separator: "\n")
        let pdf = try XCTUnwrap(
            PDFDocument(
                data: VisitSummaryPDFRenderer.render(
                    snapshot
                )
            )
        )
        let pdfText = (0..<pdf.pageCount)
            .compactMap { pdf.page(at: $0)?.string }
            .joined(separator: "\n")
        let compactPDFText = pdfText
            .replacingOccurrences(
                of: "\\s+",
                with: "",
                options: .regularExpression
            )
        let expected = [
            "测试姓名",
            "方案标题哨兵",
            "12.345",
            "mg",
            "舌下",
            "每天 08:00",
            "方案敏感备注",
            "occurrence-sentinel",
            "执行敏感备注",
            "血清哨兵",
            "采样敏感备注",
            "180.50",
            "100—200",
            "LC-MS/MS",
            "状态敏感备注",
            "旅程内容哨兵",
            "问题内容哨兵"
        ]
        for sentinel in expected {
            XCTAssertTrue(
                previewText.contains(sentinel),
                "preview missing \(sentinel)"
            )
            XCTAssertTrue(
                compactPDFText.contains(
                    sentinel.replacingOccurrences(
                        of: "\\s+",
                        with: "",
                        options: .regularExpression
                    )
                ),
                "PDF missing \(sentinel)"
            )
            if sentinel != "测试姓名" {
                XCTAssertTrue(
                    csvText.contains(sentinel),
                    "CSV missing \(sentinel)"
                )
            }
        }
        XCTAssertTrue(previewText.contains("附件数量 2"))
        XCTAssertTrue(csvText.contains("\"2\""))
    }

    @MainActor
    func testAttachmentOnlyLabIsDisclosedExactlyOnceAcrossPreviewPDFAndCSV()
        throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let sampleID = UUID(
            uuidString: "12345678-1111-2222-3333-444444444444"
        )!
        let snapshot = VisitSummarySnapshot(
            snapshotID: UUID(),
            generatedAt: now,
            rangeStart: now.addingTimeInterval(-86_400),
            rangeEnd: now,
            subjectName: nil,
            includesGeneratedDate: true,
            regimens: [],
            administrations: [],
            labs: [
                VisitSummaryLabSample(
                    id: sampleID,
                    timestamp: try HistoricalTimestamp.captured(
                        instant: now,
                        timeZoneIdentifier: "UTC"
                    ),
                    specimen: "仅附件样本",
                    context: "没有结构化结果",
                    results: [],
                    attachmentCount: 1
                )
            ],
            statuses: [],
            events: [],
            questions: [],
            disclosedAttachmentCount: 1,
            sensitiveNotesIncluded: true,
            stateDigest: String(repeating: "c", count: 64)
        )
        let marker = sampleID.uuidString.lowercased()
        let projection = VisitSummaryDisclosureProjection(
            snapshot: snapshot
        )
        let preview = projection.sections
            .flatMap(\.rows)
            .joined(separator: "\n")
        let labsCSV = try XCTUnwrap(
            VisitSummaryCSVEncoder.encode(snapshot)
                .first { $0.filename == "labs.csv" }
        )
        let csv = try XCTUnwrap(
            String(data: labsCSV.data, encoding: .utf8)
        )
        let pdf = try XCTUnwrap(
            PDFDocument(
                data: VisitSummaryPDFRenderer.render(snapshot)
            )
        )
        let pdfText = (0..<pdf.pageCount)
            .compactMap { pdf.page(at: $0)?.string }
            .joined(separator: "\n")

        for text in [preview, csv, pdfText] {
            XCTAssertEqual(
                text.components(separatedBy: marker).count - 1,
                1,
                text
            )
        }
        XCTAssertTrue(preview.contains("仅附件样本"))
        XCTAssertTrue(csv.contains("仅附件样本"))
        XCTAssertTrue(preview.contains("附件数量 1"))
        XCTAssertTrue(csv.contains("\"1\""))
    }

    func testExportGateRejectsAnyChangedDisclosureAndEmptySnapshot()
        throws {
        let frozen = try makeDisclosureSnapshot()
        let changed = try makeDisclosureSnapshot(
            labRawValue: "999.99",
            stateDigest: frozen.stateDigest
        )
        XCTAssertThrowsError(
            try VisitSummaryExportGate.validate(
                frozen: frozen,
                current: changed
            )
        ) {
            XCTAssertEqual(
                $0 as? VisitSummaryFailure,
                .stateChanged
            )
        }
        let empty = makeSnapshot(events: [])
        XCTAssertThrowsError(
            try VisitSummaryExportGate.validate(
                frozen: empty,
                current: empty
            )
        )
    }

    @MainActor
    func testPDFSingleLongComposedRecordIsCompleteAndNotRepeated()
        throws {
        let prefix = "起始唯一标记甲乙丙"
        let middle = "中间唯一标记丁戊己"
        let suffix = "结尾唯一标记庚辛壬"
        let longText =
            "\n" + prefix + "\n"
            + String(
                repeating: "中文分页 🙂 e\u{301} 组合字符。 ",
                count: 3_500
            )
            + "\n" + middle + "\n"
            + String(
                repeating: "继续分页 🏳️‍⚧️ 与中文内容。 ",
                count: 3_500
            )
            + "\n" + suffix + "\n"
        let snapshot = makeSnapshot(
            events: [
                VisitSummaryJourneyItem(
                    id: UUID(),
                    occurredAt: Date(
                        timeIntervalSince1970:
                            1_750_000_000
                    ),
                    kind: .moment,
                    text: longText
                )
            ]
        )
        let document = try XCTUnwrap(
            PDFDocument(
                data: VisitSummaryPDFRenderer.render(
                    snapshot
                )
            )
        )
        XCTAssertGreaterThan(document.pageCount, 2)
        let text = (0..<document.pageCount)
            .compactMap {
                document.page(at: $0)?.string
            }
            .joined(separator: "\n")
        let compactText = text.replacingOccurrences(
            of: "\\s+",
            with: "",
            options: .regularExpression
        )
        for marker in [prefix, middle, suffix] {
            XCTAssertEqual(
                compactText.components(
                    separatedBy: marker
                ).count - 1,
                1,
                marker
            )
        }
        XCTAssertLessThan(
            try XCTUnwrap(
                compactText.range(of: prefix)
            ).lowerBound,
            try XCTUnwrap(
                compactText.range(of: middle)
            ).lowerBound
        )
        XCTAssertLessThan(
            try XCTUnwrap(
                compactText.range(of: middle)
            ).lowerBound,
            try XCTUnwrap(
                compactText.range(of: suffix)
            ).lowerBound
        )
    }

    private func makeSnapshot(
        events: [VisitSummaryJourneyItem]
    ) -> VisitSummarySnapshot {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        return VisitSummarySnapshot(
            snapshotID: UUID(),
            generatedAt: now,
            rangeStart: now.addingTimeInterval(-86_400),
            rangeEnd: now,
            subjectName: nil,
            includesGeneratedDate: true,
            regimens: [],
            administrations: [],
            labs: [],
            statuses: [],
            events: events,
            questions: [],
            disclosedAttachmentCount: 0,
            sensitiveNotesIncluded: false,
            stateDigest: String(repeating: "a", count: 64)
        )
    }

    private func makeDisclosureSnapshot(
        labRawValue: String = "180.50",
        stateDigest: String = String(
            repeating: "b",
            count: 64
        )
    ) throws -> VisitSummarySnapshot {
        let now = Date(
            timeIntervalSince1970: 1_750_000_000
        )
        let timestamp = try HistoricalTimestamp.captured(
            instant: now,
            timeZoneIdentifier: "UTC"
        )
        return VisitSummarySnapshot(
            snapshotID: UUID(),
            generatedAt: now,
            rangeStart:
                now.addingTimeInterval(-86_400),
            rangeEnd: now,
            subjectName: "测试姓名",
            includesGeneratedDate: true,
            regimens: [
                VisitSummaryRegimen(
                    id: UUID(),
                    code: "R-SENTINEL",
                    title: "方案标题哨兵",
                    effectiveStartDate:
                        try CivilDateFact(
                            year: 2025,
                            month: 6,
                            day: 1
                        ),
                    effectiveEndDate:
                        try CivilDateFact(
                            year: 2025,
                            month: 7,
                            day: 1
                        ),
                    changeReason: "方案敏感备注",
                    items: [
                        VisitSummaryRegimenItem(
                            id: UUID(),
                            displayName: "方案项目哨兵",
                            doseOriginal: "12.345",
                            unitOriginal: "mg",
                            route: "舌下",
                            scheduleSummary:
                                "每天 08:00"
                        )
                    ]
                )
            ],
            administrations: [
                VisitSummaryAdministration(
                    id: UUID(),
                    occurrenceKey:
                        "occurrence-sentinel",
                    plannedAt: now,
                    actualAt:
                        now.addingTimeInterval(30),
                    status: .taken,
                    itemName: "执行项目哨兵",
                    note: "执行敏感备注"
                )
            ],
            labs: [
                VisitSummaryLabSample(
                    id: UUID(),
                    timestamp: timestamp,
                    specimen: "血清哨兵",
                    context: "采样敏感备注",
                    results: [
                        VisitSummaryLabResult(
                            id: UUID(),
                            itemName: "雌二醇哨兵",
                            rawValue: labRawValue,
                            unit: "pg/mL",
                            referenceRange: "100—200",
                            assayOrVariant: "LC-MS/MS"
                        )
                    ],
                    attachmentCount: 2
                )
            ],
            statuses: [
                VisitSummaryStatus(
                    id: UUID(),
                    timestamp: timestamp,
                    metricName: "情绪哨兵",
                    level: 3,
                    note: "状态敏感备注",
                    attachmentCount: 1
                )
            ],
            events: [
                VisitSummaryJourneyItem(
                    id: UUID(),
                    occurredAt: now,
                    kind: .moment,
                    text: "旅程内容哨兵"
                )
            ],
            questions: [
                VisitSummaryJourneyItem(
                    id: UUID(),
                    occurredAt:
                        now.addingTimeInterval(1),
                    kind: .question,
                    text: "问题内容哨兵"
                )
            ],
            disclosedAttachmentCount: 3,
            sensitiveNotesIncluded: true,
            stateDigest: stateDigest
        )
    }
}

@MainActor
final class VisitSummarySnapshotServiceTests: XCTestCase {
    func testSnapshotUsesCanonicalFactsAndAppliesTerminalOverlays() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let rangeStart = Date(timeIntervalSince1970: 1_750_000_000)
        let rangeEnd = rangeStart.addingTimeInterval(7 * 86_400)
        let regimenID = UUID()
        let hiddenRegimenID = UUID()
        let itemID = UUID()
        let visibleQuestionID = UUID()
        let deletedJourneyID = UUID()
        let labSampleID = UUID()
        let statusID = UUID()
        let administrationID = UUID()
        let deletedOccurrenceKey = "occurrence-deleted"

        context.insert(
            RegimenPlanVersionRecord(
                id: regimenID,
                code: "R-01",
                title: "当前方案",
                effectiveStartDate: try CivilDateFact(
                    year: 2025,
                    month: 6,
                    day: 15
                ),
                editState: .sealed
            )
        )
        context.insert(
            RegimenPlanVersionRecord(
                id: hiddenRegimenID,
                code: "R-02",
                title: "已经删除",
                effectiveStartDate: try CivilDateFact(
                    year: 2025,
                    month: 6,
                    day: 16
                ),
                editState: .sealed
            )
        )
        context.insert(
            RegimenItemRecord(
                id: itemID,
                regimenVersionID: regimenID,
                sortOrder: 0,
                displayName: "测试项目",
                doseOriginal: "一",
                unitOriginal: "单位"
            )
        )
        context.insert(
            JourneyEntry(
                id: visibleQuestionID,
                text: "这次要问什么？",
                kind: .question,
                occurredAt: rangeStart.addingTimeInterval(3_600)
            )
        )
        context.insert(
            JourneyEntry(
                id: deletedJourneyID,
                text: "不应出现",
                kind: .moment,
                occurredAt: rangeStart.addingTimeInterval(7_200)
            )
        )

        let labTimestamp = try HistoricalTimestamp.captured(
            instant: rangeStart.addingTimeInterval(10_800),
            timeZoneIdentifier: "UTC"
        )
        let definitionID = UUID()
        context.insert(
            LabItemDefinitionRecord(
                id: definitionID,
                kind: .custom,
                displayName: "雌二醇",
                code: "E2"
            )
        )
        context.insert(
            LabSampleRecord(
                id: labSampleID,
                operationID: UUID(),
                specimenOriginal: "血清",
                contextNote: "敏感采样备注"
            )
        )
        context.insert(
            LabResultRecord(
                id: UUID(),
                sampleID: labSampleID,
                sortOrder: 0,
                itemDefinitionID: definitionID,
                itemNameSnapshot: "雌二醇",
                itemCodeSnapshot: "E2",
                rawValueOriginal: "180.5",
                comparator: nil,
                canonicalDecimalString: "180.5",
                unitOriginal: "pg/mL",
                operationID: UUID()
            )
        )
        context.insert(
            HistoricalTimeRecord(
                sourceRecordType: "LabSampleRecord",
                sourceRecordID: labSampleID,
                timestamp: labTimestamp,
                legacyAssociationID: nil,
                resolvedRegimenVersionID: regimenID,
                associationState: .resolved
            )
        )
        let activeAttachmentID = UUID()
        context.insert(
            AttachmentRecord(
                id: activeAttachmentID,
                ownerType: .labSample,
                ownerID: labSampleID,
                relativePath:
                    "Attachments/"
                    + activeAttachmentID.uuidString.lowercased(),
                originalFilename: "active.png",
                typeIdentifier: "public.png",
                byteCount: 1,
                sha256Hex: String(repeating: "a", count: 64),
                operationID: UUID()
            )
        )
        let deletedAttachmentID = UUID()
        context.insert(
            AttachmentRecord(
                id: deletedAttachmentID,
                ownerType: .labSample,
                ownerID: labSampleID,
                relativePath:
                    "Attachments/"
                    + deletedAttachmentID.uuidString.lowercased(),
                originalFilename: "deleted.png",
                typeIdentifier: "public.png",
                byteCount: 1,
                sha256Hex: String(repeating: "b", count: 64),
                operationID: UUID(),
                deleteOperationID: UUID(),
                deletedAt:
                    rangeStart.addingTimeInterval(12_000)
            )
        )

        let statusTimestamp = try HistoricalTimestamp.captured(
            instant: rangeStart.addingTimeInterval(14_400),
            timeZoneIdentifier: "UTC"
        )
        let metricID = UUID()
        context.insert(
            StatusObservationRecord(
                id: statusID,
                metricDefinitionID: metricID,
                metricNameSnapshot: "精力",
                ordinalLevel: 3,
                note: "敏感状态备注",
                operationID: UUID()
            )
        )
        context.insert(
            HistoricalTimeRecord(
                sourceRecordType: "StatusObservationRecord",
                sourceRecordID: statusID,
                timestamp: statusTimestamp,
                legacyAssociationID: nil,
                resolvedRegimenVersionID: regimenID,
                associationState: .resolved
            )
        )

        context.insert(
            AdministrationEventRecord(
                id: administrationID,
                occurrenceKey: "occurrence-visible",
                scheduleRuleID: UUID(),
                scheduleRevision: 1,
                regimenVersionID: regimenID,
                regimenItemID: itemID,
                status: .taken,
                plannedInstant: rangeStart.addingTimeInterval(18_000),
                note: "敏感执行备注",
                operationID: UUID()
            )
        )
        context.insert(
            AdministrationEventRecord(
                occurrenceKey: deletedOccurrenceKey,
                scheduleRuleID: UUID(),
                scheduleRevision: 1,
                regimenVersionID: regimenID,
                regimenItemID: itemID,
                status: .skipped,
                plannedInstant: rangeStart.addingTimeInterval(21_600),
                operationID: UUID()
            )
        )
        try context.save()

        let reader = AppReadActor(modelContainer: container)
        var privacy = VisitSummaryPrivacySelection()
        privacy.includePhotos = true
        let snapshot = try await reader.visitSummarySnapshot(
            configuration: VisitSummaryConfiguration(
                start: rangeStart,
                end: rangeEnd,
                privacy: privacy
            ),
            terminalOverlay: DataControlTerminalOverlay(
                journeyEntryIDs: [deletedJourneyID],
                administrationOccurrenceKeys: [deletedOccurrenceKey],
                draftRegimenVersionIDs: [],
                sealedRegimenVersionIDs: [hiddenRegimenID],
                hidesHrtJourney: false
            ),
            parentRecordOverlay: .empty,
            generatedAt: rangeEnd,
            displayTimeZoneIdentifier: "UTC"
        )

        XCTAssertEqual(snapshot.regimens.map(\.id), [regimenID])
        XCTAssertEqual(snapshot.administrations.map(\.id), [administrationID])
        XCTAssertEqual(snapshot.labs.map(\.id), [labSampleID])
        XCTAssertEqual(snapshot.statuses.map(\.id), [statusID])
        XCTAssertEqual(snapshot.questions.map(\.id), [visibleQuestionID])
        XCTAssertTrue(snapshot.events.isEmpty)
        XCTAssertEqual(snapshot.labs.first?.attachmentCount, 1)
        XCTAssertEqual(snapshot.disclosedAttachmentCount, 1)
        XCTAssertEqual(snapshot.labs.first?.context, "")
        XCTAssertEqual(snapshot.statuses.first?.note, "")
        XCTAssertEqual(snapshot.administrations.first?.note, "")
        XCTAssertEqual(snapshot.stateDigest.count, 64)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            RegimenPlanVersionRecord.self,
            RegimenItemRecord.self,
            ScheduleRuleRecord.self,
            AdministrationEventRecord.self,
            HistoricalTimeRecord.self,
            LabItemDefinitionRecord.self,
            LabSampleRecord.self,
            LabResultRecord.self,
            StatusObservationRecord.self,
            AttachmentRecord.self,
            JourneyEntry.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
    }
}
