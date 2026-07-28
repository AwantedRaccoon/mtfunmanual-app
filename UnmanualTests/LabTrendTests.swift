import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class LabTrendTests: XCTestCase {
    func testLabSurfaceCopyDistinguishesGentleModeWithoutHidingFacts()
    {
        let standard = LabSurfaceDisplayPolicy.copy(
            gentleModeEnabled: false
        )
        XCTAssertEqual(standard.todayLabel, "最近化验")
        XCTAssertEqual(standard.timelineRecordTitle, "化验记录")
        XCTAssertEqual(standard.timelineKindLabel, "LAB / 化验")
        XCTAssertEqual(standard.trendActionTitle, "查看这个项目的变化")
        XCTAssertEqual(standard.trendTitle, "化验趋势")

        let gentle = LabSurfaceDisplayPolicy.copy(
            gentleModeEnabled: true
        )
        XCTAssertEqual(gentle.todayLabel, "最近检查")
        XCTAssertEqual(gentle.timelineRecordTitle, "检查记录")
        XCTAssertEqual(gentle.timelineKindLabel, "RECORD / 检查")
        XCTAssertEqual(gentle.trendActionTitle, "查看数据变化")
        XCTAssertEqual(gentle.trendTitle, "数据变化")
        XCTAssertEqual(
            gentle.deletedRecordDetail,
            "这条检查或状态记录已经从正常视图移除。"
        )

        XCTAssertFalse(gentle.trendTitle.contains("雌二醇"))
        XCTAssertFalse(gentle.trendTitle.contains("172.5"))
    }

    func testDecimalConversionUsesVersionedSameDimensionRules() throws {
        let converted = try LabUnitConversionRulesV1.convert(
            canonicalDecimalString: "17.25",
            comparator: .lessThan,
            sourceUnitOriginal: "mg/dL",
            targetUnitID: "mass.g-per-l"
        )

        XCTAssertEqual(converted.canonicalDecimalString, "0.1725")
        XCTAssertEqual(converted.comparator, .lessThan)
        XCTAssertEqual(converted.sourceUnitID, "mass.mg-per-dl")
        XCTAssertEqual(converted.targetUnitID, "mass.g-per-l")
        XCTAssertEqual(converted.ruleID, "mass.mg-per-dl->mass.g-per-l")
        XCTAssertEqual(converted.ruleVersion, "lab-unit-conversion/1")

        let roundTrip = try LabUnitConversionRulesV1.convert(
            canonicalDecimalString: converted.canonicalDecimalString,
            comparator: converted.comparator,
            sourceUnitOriginal: "g/L",
            targetUnitID: "mass.mg-per-dl"
        )
        XCTAssertEqual(roundTrip.canonicalDecimalString, "17.25")
        XCTAssertEqual(roundTrip.comparator, .lessThan)
    }

    func testUnitAliasesAreExplicitAndCrossDimensionConversionIsRejected() throws {
        XCTAssertEqual(
            LabUnitConversionRulesV1.unit(for: "µg/L")?.id,
            "mass.microgram-per-l"
        )
        XCTAssertEqual(
            LabUnitConversionRulesV1.unit(for: "μg/L")?.id,
            "mass.microgram-per-l"
        )
        XCTAssertEqual(
            LabUnitConversionRulesV1.unit(for: "ug/L")?.id,
            "mass.microgram-per-l"
        )
        XCTAssertNil(LabUnitConversionRulesV1.unit(for: "UG/L"))
        XCTAssertNil(LabUnitConversionRulesV1.unit(for: "pg / mL"))

        XCTAssertThrowsError(
            try LabUnitConversionRulesV1.convert(
                canonicalDecimalString: "1",
                comparator: nil,
                sourceUnitOriginal: "pg/mL",
                targetUnitID: "amount.pmol-per-l"
            )
        ) {
            XCTAssertEqual(
                $0 as? LabUnitConversionFailure,
                .incompatibleDimensions
            )
        }
        XCTAssertThrowsError(
            try LabUnitConversionRulesV1.convert(
                canonicalDecimalString: "1",
                comparator: nil,
                sourceUnitOriginal: "unknown",
                targetUnitID: "mass.g-per-l"
            )
        ) {
            XCTAssertEqual(
                $0 as? LabUnitConversionFailure,
                .unsupportedUnit
            )
        }
    }

    func testEveryFrozenUnitFactorRoundTripsWithoutChangingComparator()
        throws {
        for source in LabUnitConversionRulesV1.units {
            let targets = LabUnitConversionRulesV1.compatibleTargets(
                for: source.symbol
            )
            XCTAssertFalse(targets.isEmpty, source.id)
            for target in targets {
                let converted = try LabUnitConversionRulesV1.convert(
                    canonicalDecimalString: "1.2345e3",
                    comparator: .greaterThanOrEqual,
                    sourceUnitOriginal: source.symbol,
                    targetUnitID: target.id
                )
                let roundTrip = try LabUnitConversionRulesV1.convert(
                    canonicalDecimalString:
                        converted.canonicalDecimalString,
                    comparator: converted.comparator,
                    sourceUnitOriginal: target.symbol,
                    targetUnitID: source.id
                )
                XCTAssertEqual(
                    roundTrip.canonicalDecimalString,
                    "1234.5",
                    "\(source.id) ↔ \(target.id)"
                )
                XCTAssertEqual(
                    roundTrip.comparator,
                    .greaterThanOrEqual
                )
            }
        }
    }

    func testInvalidTargetDecimalAndArithmeticFailureAreExplicit() {
        XCTAssertThrowsError(
            try LabUnitConversionRulesV1.convert(
                canonicalDecimalString: "not-a-number",
                comparator: nil,
                sourceUnitOriginal: "mg/L",
                targetUnitID: "mass.g-per-l"
            )
        ) {
            XCTAssertEqual(
                $0 as? LabUnitConversionFailure,
                .invalidDecimal
            )
        }
        XCTAssertThrowsError(
            try LabUnitConversionRulesV1.convert(
                canonicalDecimalString: "1",
                comparator: nil,
                sourceUnitOriginal: "mg/L",
                targetUnitID: "unknown-target"
            )
        ) {
            XCTAssertEqual(
                $0 as? LabUnitConversionFailure,
                .unsupportedUnit
            )
        }
        XCTAssertThrowsError(
            try LabUnitConversionRulesV1.convert(
                canonicalDecimalString:
                    "1e-127",
                comparator: nil,
                sourceUnitOriginal: "pmol/L",
                targetUnitID: "amount.mol-per-l"
            )
        ) {
            XCTAssertEqual(
                $0 as? LabUnitConversionFailure,
                .arithmeticFailure
            )
        }
        XCTAssertThrowsError(
            try LabUnitConversionRulesV1.convert(
                canonicalDecimalString:
                    "99999999999999999999999999999999999999e127",
                comparator: nil,
                sourceUnitOriginal: "g/L",
                targetUnitID: "mass.pg-per-ml"
            )
        ) {
            XCTAssertEqual(
                $0 as? LabUnitConversionFailure,
                .arithmeticFailure
            )
        }
        XCTAssertThrowsError(
            try LabUnitConversionRulesV1.convert(
                canonicalDecimalString: "1,5",
                comparator: nil,
                sourceUnitOriginal: "mg/L",
                targetUnitID: "mass.g-per-l"
            )
        ) {
            XCTAssertEqual(
                $0 as? LabUnitConversionFailure,
                .invalidDecimal
            )
        }
    }

    func testTrendUsesStableIdentityExactVariantAndPreservesBoundaryPoints() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let itemID = UUID()
        let otherItemID = UUID()
        let firstSampleID = UUID()
        let secondSampleID = UUID()
        let thirdSampleID = UUID()

        try await createSample(
            writer: writer,
            sampleID: secondSampleID,
            itemID: itemID,
            newDefinition: true,
            rawValue: "2",
            unit: "mg/L",
            variant: nil,
            instant: Date(timeIntervalSince1970: 200)
        )
        try await createSample(
            writer: writer,
            sampleID: firstSampleID,
            itemID: itemID,
            rawValue: "< 1000",
            unit: "µg/L",
            variant: nil,
            instant: Date(timeIntervalSince1970: 100)
        )
        try await createSample(
            writer: writer,
            sampleID: thirdSampleID,
            itemID: itemID,
            rawValue: "3",
            unit: "mg/L",
            variant: "",
            instant: Date(timeIntervalSince1970: 300)
        )
        try await createSample(
            writer: writer,
            sampleID: UUID(),
            itemID: otherItemID,
            newDefinition: true,
            rawValue: "99",
            unit: "mg/L",
            variant: nil,
            instant: Date(timeIntervalSince1970: 400)
        )
        try await createSample(
            writer: writer,
            sampleID: UUID(),
            itemID: itemID,
            rawValue: "4",
            unit: "pmol/L",
            variant: nil,
            instant: Date(timeIntervalSince1970: 500)
        )
        let whitespaceVariantSampleID = UUID()
        try await createSample(
            writer: writer,
            sampleID: whitespaceVariantSampleID,
            itemID: itemID,
            rawValue: "5",
            unit: "mg/L",
            variant: " ",
            instant: Date(timeIntervalSince1970: 600)
        )

        let page = try await reader.labTrendPage(
            LabTrendRequest(
                itemDefinitionID: itemID,
                assayOrVariantOriginal: nil,
                sourceUnitOriginal: "mg/L",
                displayUnitID: "mass.mg-per-l"
            ),
            limit: 20
        )

        XCTAssertEqual(page.points.map(\.sampleID), [
            secondSampleID,
            firstSampleID
        ])
        XCTAssertEqual(
            page.points.map(\.displayCanonicalDecimalString),
            ["2", "1"]
        )
        XCTAssertEqual(page.points.map(\.comparator), [nil, .lessThan])
        XCTAssertEqual(page.points.map(\.isExactPlotPoint), [true, false])
        XCTAssertEqual(page.excludedIncompatibleUnitCount, 1)
        XCTAssertNil(page.nextCursor)

        let whitespacePage = try await reader.labTrendPage(
            LabTrendRequest(
                itemDefinitionID: itemID,
                assayOrVariantOriginal: " ",
                sourceUnitOriginal: "mg/L",
                displayUnitID: nil
            )
        )
        XCTAssertEqual(
            whitespacePage.points.map(\.sampleID),
            [whitespaceVariantSampleID]
        )
    }

    func testTrendCursorIsStableForSameInstantAndDoesNotDuplicate() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let itemID = UUID()
        let instant = Date(timeIntervalSince1970: 500)
        let ids = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        ]
        for (index, id) in ids.enumerated() {
            try await createSample(
                writer: writer,
                sampleID: id,
                itemID: itemID,
                newDefinition: index == 0,
                rawValue: "\(index + 1)",
                unit: "mg/L",
                variant: "方法 A",
                instant: instant
            )
        }

        let request = LabTrendRequest(
            itemDefinitionID: itemID,
            assayOrVariantOriginal: "方法 A",
            sourceUnitOriginal: "mg/L",
            displayUnitID: nil
        )
        let first = try await reader.labTrendPage(request, limit: 2)
        let second = try await reader.labTrendPage(
            request,
            after: try XCTUnwrap(first.nextCursor),
            limit: 2
        )

        XCTAssertEqual(first.points.count, 2)
        XCTAssertEqual(second.points.count, 1)
        XCTAssertEqual(
            Set((first.points + second.points).map(\.sampleID)),
            Set(ids)
        )
        XCTAssertNil(second.nextCursor)
    }

    func testTrendCursorKeepsRepeatedMeasurementsWithinOneSample()
        async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let itemID = UUID()
        let sampleID = UUID()
        let instant = Date(timeIntervalSince1970: 650)
        let timestamp = try HistoricalTimestamp.captured(
            instant: instant,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        _ = try await writer.createLabSample(
            CreateLabSampleCommand(
                operationID: UUID(),
                sampleID: sampleID,
                timestamp: timestamp,
                newDefinitions: [
                    LabItemDefinitionInput(
                        id: itemID,
                        displayName: "重复测定",
                        code: "R"
                    )
                ],
                results: [
                    LabResultInput(
                        itemDefinitionID: itemID,
                        rawValueOriginal: "1",
                        unitOriginal: "mg/L",
                        assayOrVariantOriginal: "方法 A"
                    ),
                    LabResultInput(
                        itemDefinitionID: itemID,
                        rawValueOriginal: "2",
                        unitOriginal: "mg/L",
                        assayOrVariantOriginal: "方法 A"
                    )
                ],
                committedAt: instant
            )
        )
        let request = LabTrendRequest(
            itemDefinitionID: itemID,
            assayOrVariantOriginal: "方法 A",
            sourceUnitOriginal: "mg/L",
            displayUnitID: nil
        )
        let first = try await reader.labTrendPage(request, limit: 1)
        let second = try await reader.labTrendPage(
            request,
            after: try XCTUnwrap(first.nextCursor),
            limit: 1
        )

        XCTAssertEqual(
            (first.points + second.points).map(\.rawValueOriginal),
            ["2", "1"]
        )
        XCTAssertEqual(
            Set((first.points + second.points).map(\.sampleID)),
            Set([sampleID])
        )
        XCTAssertNil(second.nextCursor)
    }

    func testTrendFailsClosedWhenCombinedFactBudgetExceeds4096()
        async throws {
        let container = try preparedContainer()
        let context = ModelContext(container)
        let itemID = UUID()
        context.insert(
            LabItemDefinitionRecord(
                id: itemID,
                displayName: "容量测试",
                code: "CAP"
            )
        )
        let instant = Date(timeIntervalSince1970: 675)
        let timestamp = try HistoricalTimestamp.captured(
            instant: instant,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        for index in 0..<1_366 {
            let sampleID = UUID()
            let operationID = UUID()
            context.insert(
                LabSampleRecord(
                    id: sampleID,
                    operationID: operationID,
                    createdAt: instant
                )
            )
            context.insert(
                LabResultRecord(
                    sampleID: sampleID,
                    sortOrder: 0,
                    itemDefinitionID: itemID,
                    itemNameSnapshot: "容量测试",
                    itemCodeSnapshot: "CAP",
                    rawValueOriginal: "\(index)",
                    comparator: nil,
                    canonicalDecimalString: "\(index)",
                    unitOriginal: "mg/L",
                    operationID: operationID,
                    createdAt: instant
                )
            )
            context.insert(
                HistoricalTimeRecord(
                    sourceRecordType: "LabSampleRecord",
                    sourceRecordID: sampleID,
                    timestamp: timestamp,
                    legacyAssociationID: nil,
                    resolvedRegimenVersionID: nil,
                    associationState: .missing
                )
            )
        }
        try context.save()
        let reader = AppReadActor(modelContainer: container)

        do {
            _ = try await reader.labTrendPage(
                LabTrendRequest(
                    itemDefinitionID: itemID,
                    assayOrVariantOriginal: nil,
                    sourceUnitOriginal: "mg/L",
                    displayUnitID: nil
                )
            )
            XCTFail("Combined result/sample/time budget must fail closed")
        } catch {
            XCTAssertEqual(
                error as? AppDataFailure,
                .corruptionSuspected
            )
        }
    }

    func testEffectiveTrendIgnores4096ActiveSamplesForOtherItems()
        async throws
    {
        let container =
            try preparedV10ContainerBeforeParentLifecycle()
        let context = ModelContext(container)
        let targetItemID = UUID()
        let unrelatedItemID = UUID()
        context.insert(
            LabItemDefinitionRecord(
                id: targetItemID,
                displayName: "目标项目",
                code: "TARGET"
            )
        )
        context.insert(
            LabItemDefinitionRecord(
                id: unrelatedItemID,
                displayName: "其他项目",
                code: "OTHER"
            )
        )
        let instant = Date(timeIntervalSince1970: 700)
        let timestamp = try HistoricalTimestamp.captured(
            instant: instant,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        for index in 0..<4_096 {
            insertBaseLabSample(
                in: context,
                itemID: unrelatedItemID,
                itemName: "其他项目",
                itemCode: "OTHER",
                rawValue: "\(index)",
                timestamp: timestamp
            )
        }
        let targetSampleID = insertBaseLabSample(
            in: context,
            itemID: targetItemID,
            itemName: "目标项目",
            itemCode: "TARGET",
            rawValue: "42",
            timestamp: timestamp
        )
        try context.save()
        _ = try ParentRecordLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 701)
        )

        let page = try await AppReadActor(
            modelContainer: container
        ).labTrendPage(
            LabTrendRequest(
                itemDefinitionID: targetItemID,
                assayOrVariantOriginal: nil,
                sourceUnitOriginal: "mg/L",
                displayUnitID: nil
            )
        )

        XCTAssertEqual(page.points.count, 1)
        XCTAssertEqual(page.points.first?.sampleID, targetSampleID)
        XCTAssertEqual(page.points.first?.rawValueOriginal, "42")
    }

    func testEffectiveTrendMixesCorrectedAndBaseLeavesWithStableCursor()
        async throws
    {
        let container = try preparedV10Container()
        let writer = AppWriteActor(modelContainer: container)
        let reader = AppReadActor(modelContainer: container)
        let itemID = UUID()
        let olderSampleID = UUID()
        let correctedSampleID = UUID()
        try await createSample(
            writer: writer,
            sampleID: olderSampleID,
            itemID: itemID,
            newDefinition: true,
            rawValue: "1",
            unit: "mg/L",
            variant: nil,
            instant: Date(timeIntervalSince1970: 100)
        )
        try await createSample(
            writer: writer,
            sampleID: correctedSampleID,
            itemID: itemID,
            rawValue: "2",
            unit: "mg/L",
            variant: nil,
            instant: Date(timeIntervalSince1970: 200)
        )
        let loadedOriginal = try await reader.labSample(
            id: correctedSampleID
        )
        let original = try XCTUnwrap(loadedOriginal)
        let loadedHead = try await reader.parentRecordHeadToken(
            type: .labSample,
            id: correctedSampleID
        )
        let head = try XCTUnwrap(loadedHead)
        _ = try await writer.correctLabSample(
            CorrectLabSampleCommand(
                parentID: correctedSampleID,
                expectedHead: head,
                timestamp: try HistoricalTimestamp.captured(
                    instant: Date(timeIntervalSince1970: 300),
                    timeZoneIdentifier: "UTC",
                    precision: .minute,
                    provenance: .userEntered
                ),
                specimenOriginal: "",
                contextNote: "更正后的有效叶",
                results: [
                    CorrectedLabResultInput(
                        logicalResultID:
                            try XCTUnwrap(original.results.first).id,
                        itemDefinitionID: itemID,
                        rawValueOriginal: "3",
                        unitOriginal: "mg/L"
                    )
                ],
                committedAt: Date(timeIntervalSince1970: 301)
            )
        )
        let request = LabTrendRequest(
            itemDefinitionID: itemID,
            assayOrVariantOriginal: nil,
            sourceUnitOriginal: "mg/L",
            displayUnitID: nil
        )

        let first = try await reader.labTrendPage(
            request,
            limit: 1
        )
        let second = try await reader.labTrendPage(
            request,
            after: try XCTUnwrap(first.nextCursor),
            limit: 1
        )

        XCTAssertEqual(first.points.map(\.sampleID), [correctedSampleID])
        XCTAssertEqual(first.points.map(\.rawValueOriginal), ["3"])
        XCTAssertEqual(
            first.points.first?.timestamp.instant,
            Date(timeIntervalSince1970: 300)
        )
        XCTAssertEqual(second.points.map(\.sampleID), [olderSampleID])
        XCTAssertEqual(second.points.map(\.rawValueOriginal), ["1"])
        XCTAssertNil(second.nextCursor)
    }

    func testEffectiveTrendCountsOtherVariantsTowardTargetItemBudget()
        async throws
    {
        let container =
            try preparedV10ContainerBeforeParentLifecycle()
        let context = ModelContext(container)
        let itemID = UUID()
        context.insert(
            LabItemDefinitionRecord(
                id: itemID,
                displayName: "容量项目",
                code: "CAP"
            )
        )
        let timestamp = try HistoricalTimestamp.captured(
            instant: Date(timeIntervalSince1970: 710),
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        for index in 0..<4_096 {
            insertBaseLabSample(
                in: context,
                itemID: itemID,
                itemName: "容量项目",
                itemCode: "CAP",
                rawValue: "\(index)",
                variant: "方法 B",
                timestamp: timestamp
            )
        }
        insertBaseLabSample(
            in: context,
            itemID: itemID,
            itemName: "容量项目",
            itemCode: "CAP",
            rawValue: "42",
            variant: "方法 A",
            timestamp: timestamp
        )
        try context.save()
        _ = try ParentRecordLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 711)
        )

        do {
            _ = try await AppReadActor(
                modelContainer: container
            ).labTrendPage(
                LabTrendRequest(
                    itemDefinitionID: itemID,
                    assayOrVariantOriginal: "方法 A",
                    sourceUnitOriginal: "mg/L",
                    displayUnitID: nil
                )
            )
            XCTFail("同一项目的全部变体结果必须共同受事实预算约束")
        } catch {
            XCTAssertEqual(
                error as? AppDataFailure,
                .corruptionSuspected
            )
        }
    }

    func testTrendReadFailurePolicyRequiresRecoveryAndIgnoresStaleRequests() {
        XCTAssertEqual(
            LabTrendReadFailurePolicy.action(
                for: AppDataFailure.corruptionSuspected,
                context: .olderPage,
                requestIsCurrent: true
            ),
            .requireRecovery(
                "化验趋势没有通过本地完整性检查。App 将进入恢复模式，不会把损坏资料显示成空状态。"
            )
        )
        XCTAssertEqual(
            LabTrendReadFailurePolicy.action(
                for: AppDataFailure.corruptionSuspected,
                context: .firstPage,
                requestIsCurrent: true,
                gentleModeEnabled: true
            ),
            .requireRecovery(
                "数据变化没有通过本地完整性检查。App 将进入恢复模式，不会把损坏资料显示成空状态。"
            )
        )
        XCTAssertEqual(
            LabTrendReadFailurePolicy.action(
                for: AppWriteFailure.invalidInput,
                context: .firstPage,
                requestIsCurrent: true,
                gentleModeEnabled: true
            ),
            .retryable(
                "暂时无法读取这组趋势，原始记录没有被修改。"
            )
        )
        XCTAssertEqual(
            LabTrendReadFailurePolicy.action(
                for: AppWriteFailure.invalidInput,
                context: .olderPage,
                requestIsCurrent: false
            ),
            .ignore
        )

        var gate = TimelineRequestEpochGate()
        let stale = gate.beginRefresh()
        let current = gate.beginRefresh()
        XCTAssertFalse(gate.isCurrent(stale))
        XCTAssertTrue(gate.isCurrent(current))
    }

    func testRegimenComparisonNeverGuessesIdentityFromEditableCode() {
        let estradiol = LedgerHormoneDescriptor.all[0]

        XCTAssertFalse(
            estradiol.matches(
                definitionKind: .custom,
                bundledStableID: "E2"
            )
        )
        XCTAssertFalse(
            estradiol.matches(
                definitionKind: .bundled,
                bundledStableID: "E2"
            )
        )
    }

    func testRelationshipValidatorRejectsRawCanonicalComparatorAndUnitTamper() async throws {
        let container = try preparedContainer()
        let writer = AppWriteActor(modelContainer: container)
        let itemID = UUID()
        try await createSample(
            writer: writer,
            sampleID: UUID(),
            itemID: itemID,
            newDefinition: true,
            rawValue: "< 1.25",
            unit: "mg/L",
            variant: nil,
            instant: Date(timeIntervalSince1970: 700)
        )
        let context = ModelContext(container)
        let result = try XCTUnwrap(
            try context.fetch(FetchDescriptor<LabResultRecord>()).first
        )

        result.canonicalDecimalString = "9"
        XCTAssertThrowsError(
            try PersonalTimelineRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )

        result.canonicalDecimalString = "1.25"
        result.comparatorRawValue = nil
        XCTAssertThrowsError(
            try PersonalTimelineRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )

        result.comparatorRawValue = LabValueComparator.lessThan.rawValue
        result.unitOriginal = ""
        XCTAssertThrowsError(
            try PersonalTimelineRelationshipValidator.validate(
                in: context,
                failure: .corruptionSuspected
            )
        )
    }

    private func preparedContainer() throws -> ModelContainer {
        let container =
            try AppModelContainerFactory.makeInMemoryPersonalTimelineContainer()
        _ = try LegacyV1Backfill.run(in: container)
        _ = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: "UTC"
        )
        _ = try TodayExecutionBackfill.run(in: container)
        _ = try PersonalTimelineBackfill.run(in: container)
        return container
    }

    private func preparedV10ContainerBeforeParentLifecycle()
        throws -> ModelContainer
    {
        let container = try AppModelContainerFactory
            .makeInMemoryParentRecordLifecycleContainer()
        let now = Date(timeIntervalSince1970: 1)
        _ = try LegacyV1Backfill.run(in: container, now: now)
        _ = try CoreTimeRegimenBackfill.run(
            in: container,
            assumedTimeZoneIdentifier: "UTC",
            now: now
        )
        _ = try TodayExecutionBackfill.run(in: container, now: now)
        _ = try PersonalTimelineBackfill.run(in: container, now: now)
        _ = try CountdownLifecycleBackfill.run(
            in: container,
            now: now,
            includeIntegrityFacts: true
        )
        _ = try OnboardingBackfill.run(
            in: container,
            source: .newInstallV8,
            now: now
        )
        _ = try HrtJourneyLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: now
        )
        return container
    }

    private func preparedV10Container() throws -> ModelContainer {
        let container =
            try preparedV10ContainerBeforeParentLifecycle()
        _ = try ParentRecordLifecycleBackfill.run(
            in: container,
            sourceSchemaVersion: "9.0.0",
            now: Date(timeIntervalSince1970: 2)
        )
        return container
    }

    @discardableResult
    private func insertBaseLabSample(
        in context: ModelContext,
        itemID: UUID,
        itemName: String,
        itemCode: String,
        rawValue: String,
        variant: String? = nil,
        timestamp: HistoricalTimestamp
    ) -> UUID {
        let sampleID = UUID()
        let operationID = UUID()
        context.insert(
            LabSampleRecord(
                id: sampleID,
                operationID: operationID,
                createdAt: timestamp.instant
            )
        )
        context.insert(
            LabResultRecord(
                sampleID: sampleID,
                sortOrder: 0,
                itemDefinitionID: itemID,
                itemNameSnapshot: itemName,
                itemCodeSnapshot: itemCode,
                rawValueOriginal: rawValue,
                comparator: nil,
                canonicalDecimalString: rawValue,
                unitOriginal: "mg/L",
                assayOrVariantOriginal: variant,
                operationID: operationID,
                createdAt: timestamp.instant
            )
        )
        context.insert(
            HistoricalTimeRecord(
                sourceRecordType: "LabSampleRecord",
                sourceRecordID: sampleID,
                timestamp: timestamp,
                legacyAssociationID: nil,
                resolvedRegimenVersionID: nil,
                associationState: .missing
            )
        )
        return sampleID
    }

    private func createSample(
        writer: AppWriteActor,
        sampleID: UUID,
        itemID: UUID,
        newDefinition: Bool = false,
        rawValue: String,
        unit: String,
        variant: String?,
        instant: Date
    ) async throws {
        let timestamp = try HistoricalTimestamp.captured(
            instant: instant,
            timeZoneIdentifier: "UTC",
            precision: .minute,
            provenance: .userEntered
        )
        _ = try await writer.createLabSample(
            CreateLabSampleCommand(
                operationID: UUID(),
                sampleID: sampleID,
                timestamp: timestamp,
                newDefinitions: newDefinition
                    ? [
                        LabItemDefinitionInput(
                            id: itemID,
                            displayName: "同名项目",
                            code: "STABLE"
                        )
                    ]
                    : [],
                results: [
                    LabResultInput(
                        itemDefinitionID: itemID,
                        rawValueOriginal: rawValue,
                        unitOriginal: unit,
                        assayOrVariantOriginal: variant
                    )
                ],
                committedAt: instant
            )
        )
    }
}
