import Foundation
import SwiftData

struct LabTrendRequest: Equatable, Sendable {
    let itemDefinitionID: UUID
    let assayOrVariantOriginal: String?
    let sourceUnitOriginal: String
    let displayUnitID: String?
}

struct LabTrendCursor: Equatable, Sendable {
    let instant: Date
    let sampleID: UUID
    let sortOrder: Int
    let resultID: UUID
}

struct LabTrendPoint: Identifiable, Equatable, Sendable {
    let id: UUID
    let sampleID: UUID
    let timestamp: HistoricalTimestamp
    let regimenVersionID: UUID?
    let associationState: HistoricalAssociationState
    let itemNameSnapshot: String
    let itemCodeSnapshot: String
    let rawValueOriginal: String
    let comparator: LabValueComparator?
    let canonicalDecimalString: String
    let unitOriginal: String
    let referenceRangeOriginal: String?
    let assayOrVariantOriginal: String?
    let displayCanonicalDecimalString: String
    let displayUnit: String
    let conversionRuleID: String?
    let conversionRuleVersion: String?

    var isExactPlotPoint: Bool {
        comparator == nil
            && Double(displayCanonicalDecimalString)?.isFinite == true
    }
}

struct LabTrendPage: Equatable, Sendable {
    let points: [LabTrendPoint]
    let nextCursor: LabTrendCursor?
    let compatibleUnits: [LabUnitRule]
    let excludedIncompatibleUnitCount: Int
}

private struct EffectiveLabTrendCandidate {
    let resultID: UUID
    let sampleID: UUID
    let timestamp: HistoricalTimestamp
    let regimenVersionID: UUID?
    let associationState: HistoricalAssociationState
    let sortOrder: Int
    let itemNameSnapshot: String
    let itemCodeSnapshot: String
    let rawValueOriginal: String
    let comparator: LabValueComparator?
    let canonicalDecimalString: String
    let unitOriginal: String
    let referenceRangeOriginal: String?
    let assayOrVariantOriginal: String?
}

extension AppReadActor {
    private static let labTrendFactScanBudget = 4_096
    private static let labTrendQueryChunkSize = 400

    func labTrendPage(
        _ request: LabTrendRequest,
        after cursor: LabTrendCursor? = nil,
        limit: Int = 100
    ) throws -> LabTrendPage {
        precondition((1...100).contains(limit))
        if modelContext.container.schema.entities.contains(where: {
            $0.name == "ParentRecordLifecycleHeadRecord"
        }) {
            return try effectiveLabTrendPage(
                request,
                after: cursor,
                limit: limit
            )
        }
        let itemDefinitionID = request.itemDefinitionID
        var resultDescriptor = FetchDescriptor<LabResultRecord>(
            predicate: #Predicate {
                $0.itemDefinitionID == itemDefinitionID
            }
        )
        var remainingFactBudget = Self.labTrendFactScanBudget
        resultDescriptor.fetchLimit = remainingFactBudget + 1
        let itemResults = try modelContext.fetch(resultDescriptor)
        guard itemResults.count <= remainingFactBudget else {
            throw AppDataFailure.corruptionSuspected
        }
        remainingFactBudget -= itemResults.count
        let variantResults = itemResults.filter {
            $0.assayOrVariantOriginal == request.assayOrVariantOriginal
        }
        let sampleIDs = Array(Set(variantResults.map(\.sampleID)))
        guard sampleIDs.count <= remainingFactBudget else {
            throw AppDataFailure.corruptionSuspected
        }
        var sampleDescriptor = FetchDescriptor<LabSampleRecord>(
            predicate: #Predicate { sampleIDs.contains($0.id) }
        )
        sampleDescriptor.fetchLimit =
            min(sampleIDs.count + 1, remainingFactBudget + 1)
        let samples = try modelContext.fetch(sampleDescriptor)
        let sampleByID = try AppDataIndex.checkedUniqueMap(
            samples,
            keyedBy: \.id,
            failure: .corruptionSuspected
        )
        guard samples.count == sampleIDs.count else {
            throw AppDataFailure.corruptionSuspected
        }
        remainingFactBudget -= samples.count

        let sourceType = "LabSampleRecord"
        guard sampleIDs.count <= remainingFactBudget else {
            throw AppDataFailure.corruptionSuspected
        }
        var timeDescriptor = FetchDescriptor<HistoricalTimeRecord>(
            predicate: #Predicate {
                $0.sourceRecordType == sourceType
                    && sampleIDs.contains($0.sourceRecordID)
            }
        )
        timeDescriptor.fetchLimit =
            min(sampleIDs.count + 1, remainingFactBudget + 1)
        let times = try modelContext.fetch(timeDescriptor)
        let timeByID = try AppDataIndex.checkedUniqueMap(
            times,
            keyedBy: \.sourceRecordID,
            failure: .corruptionSuspected
        )
        guard times.count == sampleIDs.count else {
            throw AppDataFailure.corruptionSuspected
        }

        var excludedIncompatibleUnitCount = 0
        let projected: [(LabTrendPoint, LabTrendCursor)] = try variantResults
            .compactMap { result in
                guard sampleByID[result.sampleID] != nil,
                      let time = timeByID[result.sampleID],
                      let timestamp = time.historicalTimestamp,
                      let associationState = HistoricalAssociationState(
                          rawValue: time.associationStateRawValue
                      ) else {
                    throw AppDataFailure.corruptionSuspected
                }
                let displayValue: String
                let displayUnit: String
                let ruleID: String?
                let ruleVersion: String?
                if let targetUnitID = request.displayUnitID {
                    do {
                        let conversion = try LabUnitConversionRulesV1.convert(
                            canonicalDecimalString:
                                result.canonicalDecimalString,
                            comparator: result.comparator,
                            sourceUnitOriginal: result.unitOriginal,
                            targetUnitID: targetUnitID
                        )
                        displayValue = conversion.canonicalDecimalString
                        displayUnit = conversion.targetSymbol
                        ruleID = conversion.ruleID
                        ruleVersion = conversion.ruleVersion
                    } catch let failure as LabUnitConversionFailure
                    where failure == .unsupportedUnit
                        || failure == .incompatibleDimensions {
                        excludedIncompatibleUnitCount += 1
                        return nil
                    }
                } else {
                    guard result.unitOriginal
                            == request.sourceUnitOriginal else {
                        excludedIncompatibleUnitCount += 1
                        return nil
                    }
                    displayValue = result.canonicalDecimalString
                    displayUnit = result.unitOriginal
                    ruleID = nil
                    ruleVersion = nil
                }
                let cursor = LabTrendCursor(
                    instant: timestamp.instant,
                    sampleID: result.sampleID,
                    sortOrder: result.sortOrder,
                    resultID: result.id
                )
                return (
                    LabTrendPoint(
                        id: result.id,
                        sampleID: result.sampleID,
                        timestamp: timestamp,
                        regimenVersionID:
                            time.resolvedRegimenVersionID,
                        associationState: associationState,
                        itemNameSnapshot: result.itemNameSnapshot,
                        itemCodeSnapshot: result.itemCodeSnapshot,
                        rawValueOriginal: result.rawValueOriginal,
                        comparator: result.comparator,
                        canonicalDecimalString:
                            result.canonicalDecimalString,
                        unitOriginal: result.unitOriginal,
                        referenceRangeOriginal:
                            result.referenceRangeOriginal,
                        assayOrVariantOriginal:
                            result.assayOrVariantOriginal,
                        displayCanonicalDecimalString: displayValue,
                        displayUnit: displayUnit,
                        conversionRuleID: ruleID,
                        conversionRuleVersion: ruleVersion
                    ),
                    cursor
                )
            }
            .sorted { lhs, rhs in
                trendCursorPrecedes(lhs.1, rhs.1)
            }

        let remaining = projected.filter {
            guard let cursor else { return true }
            return trendCursorPrecedes(cursor, $0.1)
        }
        let selected = Array(remaining.prefix(limit))
        let nextCursor = remaining.count > limit
            ? selected.last?.1
            : nil
        return LabTrendPage(
            points: selected.map(\.0),
            nextCursor: nextCursor,
            compatibleUnits:
                LabUnitConversionRulesV1.compatibleTargets(
                    for: request.sourceUnitOriginal
                ),
            excludedIncompatibleUnitCount:
                excludedIncompatibleUnitCount
        )
    }

    private func effectiveLabTrendPage(
        _ request: LabTrendRequest,
        after cursor: LabTrendCursor?,
        limit: Int
    ) throws -> LabTrendPage {
        try ParentRecordLifecycleValidator.validate(
            in: modelContext,
            failure: .corruptionSuspected
        )
        let labType = ParentRecordType.labSample.rawValue
        let active = ParentRecordLifecycle.active.rawValue
        var descriptor =
            FetchDescriptor<ParentRecordLifecycleHeadRecord>(
                predicate: #Predicate {
                    $0.parentTypeRawValue == labType
                        && $0.lifecycleRawValue == active
                },
                sortBy: [
                    SortDescriptor(
                        \.effectiveInstant,
                        order: .reverse
                    ),
                    SortDescriptor(\.parentID)
                ]
            )
        descriptor.fetchLimit =
            ParentRecordLifecycleCapacity.maximumParents + 1
        let heads = try modelContext.fetch(descriptor)
        guard heads.count
                <= ParentRecordLifecycleCapacity.maximumParents else {
            throw AppDataFailure.corruptionSuspected
        }
        var remainingFactBudget = Self.labTrendFactScanBudget
        let baseHeads = heads.filter { $0.latestPayloadID == nil }
        let correctedHeadPairs = heads.compactMap { head in
            head.latestPayloadID.map { ($0, head) }
        }
        guard Set(correctedHeadPairs.map(\.0)).count
                == correctedHeadPairs.count else {
            throw AppDataFailure.corruptionSuspected
        }
        let baseHeadByParentID = try AppDataIndex.checkedUniqueMap(
            baseHeads,
            keyedBy: \.parentID,
            failure: .corruptionSuspected
        )
        let correctedHeadByPayloadID = Dictionary(
            uniqueKeysWithValues: correctedHeadPairs
        )
        let baseResults = try targetBaseLabResults(
            itemDefinitionID: request.itemDefinitionID,
            sampleIDs: Array(baseHeadByParentID.keys),
            remainingFactBudget: &remainingFactBudget
        )
        let correctedResults = try targetCorrectedLabResults(
            itemDefinitionID: request.itemDefinitionID,
            correctionIDs: Array(correctedHeadByPayloadID.keys),
            remainingFactBudget: &remainingFactBudget
        )
        let matchingBaseResults = baseResults.filter {
            $0.assayOrVariantOriginal
                == request.assayOrVariantOriginal
        }
        let matchingCorrectedResults = correctedResults.filter {
            $0.assayOrVariantOriginal
                == request.assayOrVariantOriginal
        }
        let baseSampleIDs = Array(
            Set(matchingBaseResults.map(\.sampleID))
        )
        let correctionIDs = Array(
            Set(
                matchingCorrectedResults.map(
                    \.correctionSnapshotID
                )
            )
        )
        let baseSamples = try baseLabSamples(
            ids: baseSampleIDs,
            remainingFactBudget: &remainingFactBudget
        )
        let baseSampleByID = try AppDataIndex.checkedUniqueMap(
            baseSamples,
            keyedBy: \.id,
            failure: .corruptionSuspected
        )
        let baseTimes = try baseLabTimes(
            sampleIDs: baseSampleIDs,
            remainingFactBudget: &remainingFactBudget
        )
        let baseTimeBySampleID = try AppDataIndex.checkedUniqueMap(
            baseTimes,
            keyedBy: \.sourceRecordID,
            failure: .corruptionSuspected
        )
        let correctionSnapshots = try labCorrectionSnapshots(
            ids: correctionIDs,
            remainingFactBudget: &remainingFactBudget
        )
        let correctionByID = try AppDataIndex.checkedUniqueMap(
            correctionSnapshots,
            keyedBy: \.id,
            failure: .corruptionSuspected
        )
        var candidates: [EffectiveLabTrendCandidate] = []
        candidates.reserveCapacity(
            matchingBaseResults.count
                + matchingCorrectedResults.count
        )
        for result in matchingBaseResults {
            guard baseSampleByID[result.sampleID] != nil,
                  let head = baseHeadByParentID[result.sampleID],
                  let time = baseTimeBySampleID[result.sampleID],
                  let timestamp = time.historicalTimestamp,
                  let associationState = HistoricalAssociationState(
                      rawValue: time.associationStateRawValue
                  ),
                  head.effectiveTimestamp == timestamp else {
                throw AppDataFailure.corruptionSuspected
            }
            candidates.append(
                EffectiveLabTrendCandidate(
                    resultID: result.id,
                    sampleID: result.sampleID,
                    timestamp: timestamp,
                    regimenVersionID:
                        time.resolvedRegimenVersionID,
                    associationState: associationState,
                    sortOrder: result.sortOrder,
                    itemNameSnapshot: result.itemNameSnapshot,
                    itemCodeSnapshot: result.itemCodeSnapshot,
                    rawValueOriginal: result.rawValueOriginal,
                    comparator: result.comparator,
                    canonicalDecimalString:
                        result.canonicalDecimalString,
                    unitOriginal: result.unitOriginal,
                    referenceRangeOriginal:
                        result.referenceRangeOriginal,
                    assayOrVariantOriginal:
                        result.assayOrVariantOriginal
                )
            )
        }
        for result in matchingCorrectedResults {
            guard let snapshot =
                    correctionByID[result.correctionSnapshotID],
                  let head =
                    correctedHeadByPayloadID[
                        result.correctionSnapshotID
                    ],
                  snapshot.parentID == head.parentID,
                  let timestamp = snapshot.timestamp,
                  let associationState = HistoricalAssociationState(
                      rawValue: snapshot.associationStateRawValue
                  ),
                  head.effectiveTimestamp == timestamp else {
                throw AppDataFailure.corruptionSuspected
            }
            candidates.append(
                EffectiveLabTrendCandidate(
                    resultID: result.logicalResultID,
                    sampleID: head.parentID,
                    timestamp: timestamp,
                    regimenVersionID:
                        snapshot.resolvedRegimenVersionID,
                    associationState: associationState,
                    sortOrder: result.sortOrder,
                    itemNameSnapshot: result.itemNameSnapshot,
                    itemCodeSnapshot: result.itemCodeSnapshot,
                    rawValueOriginal: result.rawValueOriginal,
                    comparator: result.comparator,
                    canonicalDecimalString:
                        result.canonicalDecimalString,
                    unitOriginal: result.unitOriginal,
                    referenceRangeOriginal:
                        result.referenceRangeOriginal,
                    assayOrVariantOriginal:
                        result.assayOrVariantOriginal
                )
            )
        }

        var excludedIncompatibleUnitCount = 0
        let projected: [(LabTrendPoint, LabTrendCursor)] =
            try candidates.compactMap { candidate in
                let displayValue: String
                let displayUnit: String
                let ruleID: String?
                let ruleVersion: String?
                if let targetUnitID = request.displayUnitID {
                    do {
                        let conversion =
                            try LabUnitConversionRulesV1.convert(
                                canonicalDecimalString:
                                    candidate.canonicalDecimalString,
                                comparator: candidate.comparator,
                                sourceUnitOriginal:
                                    candidate.unitOriginal,
                                targetUnitID: targetUnitID
                            )
                        displayValue =
                            conversion.canonicalDecimalString
                        displayUnit = conversion.targetSymbol
                        ruleID = conversion.ruleID
                        ruleVersion = conversion.ruleVersion
                    } catch let failure as LabUnitConversionFailure
                    where failure == .unsupportedUnit
                        || failure == .incompatibleDimensions {
                        excludedIncompatibleUnitCount += 1
                        return nil
                    }
                } else {
                    guard candidate.unitOriginal
                            == request.sourceUnitOriginal else {
                        excludedIncompatibleUnitCount += 1
                        return nil
                    }
                    displayValue =
                        candidate.canonicalDecimalString
                    displayUnit = candidate.unitOriginal
                    ruleID = nil
                    ruleVersion = nil
                }
                let pointCursor = LabTrendCursor(
                    instant: candidate.timestamp.instant,
                    sampleID: candidate.sampleID,
                    sortOrder: candidate.sortOrder,
                    resultID: candidate.resultID
                )
                return (
                    LabTrendPoint(
                        id: candidate.resultID,
                        sampleID: candidate.sampleID,
                        timestamp: candidate.timestamp,
                        regimenVersionID:
                            candidate.regimenVersionID,
                        associationState:
                            candidate.associationState,
                        itemNameSnapshot:
                            candidate.itemNameSnapshot,
                        itemCodeSnapshot:
                            candidate.itemCodeSnapshot,
                        rawValueOriginal:
                            candidate.rawValueOriginal,
                        comparator: candidate.comparator,
                        canonicalDecimalString:
                            candidate.canonicalDecimalString,
                        unitOriginal: candidate.unitOriginal,
                        referenceRangeOriginal:
                            candidate.referenceRangeOriginal,
                        assayOrVariantOriginal:
                            candidate.assayOrVariantOriginal,
                        displayCanonicalDecimalString:
                            displayValue,
                        displayUnit: displayUnit,
                        conversionRuleID: ruleID,
                        conversionRuleVersion: ruleVersion
                    ),
                    pointCursor
                )
            }
            .sorted {
                trendCursorPrecedes($0.1, $1.1)
            }
        let remaining = projected.filter {
            guard let cursor else { return true }
            return trendCursorPrecedes(cursor, $0.1)
        }
        let selected = Array(remaining.prefix(limit))
        return LabTrendPage(
            points: selected.map(\.0),
            nextCursor: remaining.count > limit
                ? selected.last?.1
                : nil,
            compatibleUnits:
                LabUnitConversionRulesV1.compatibleTargets(
                    for: request.sourceUnitOriginal
                ),
            excludedIncompatibleUnitCount:
                excludedIncompatibleUnitCount
        )
    }

    private func targetBaseLabResults(
        itemDefinitionID: UUID,
        sampleIDs: [UUID],
        remainingFactBudget: inout Int
    ) throws -> [LabResultRecord] {
        var output: [LabResultRecord] = []
        for ids in chunks(sampleIDs) {
            var descriptor = FetchDescriptor<LabResultRecord>(
                predicate: #Predicate {
                    $0.itemDefinitionID == itemDefinitionID
                        && ids.contains($0.sampleID)
                }
            )
            descriptor.fetchLimit = remainingFactBudget + 1
            let records = try modelContext.fetch(descriptor)
            guard records.count <= remainingFactBudget else {
                throw AppDataFailure.corruptionSuspected
            }
            remainingFactBudget -= records.count
            output.append(contentsOf: records)
        }
        return output
    }

    private func targetCorrectedLabResults(
        itemDefinitionID: UUID,
        correctionIDs: [UUID],
        remainingFactBudget: inout Int
    ) throws -> [LabResultCorrectionSnapshotRecord] {
        var output: [LabResultCorrectionSnapshotRecord] = []
        for ids in chunks(correctionIDs) {
            var descriptor =
                FetchDescriptor<LabResultCorrectionSnapshotRecord>(
                    predicate: #Predicate {
                        $0.itemDefinitionID == itemDefinitionID
                            && ids.contains(
                                $0.correctionSnapshotID
                            )
                    }
                )
            descriptor.fetchLimit = remainingFactBudget + 1
            let records = try modelContext.fetch(descriptor)
            guard records.count <= remainingFactBudget else {
                throw AppDataFailure.corruptionSuspected
            }
            remainingFactBudget -= records.count
            output.append(contentsOf: records)
        }
        return output
    }

    private func baseLabSamples(
        ids sampleIDs: [UUID],
        remainingFactBudget: inout Int
    ) throws -> [LabSampleRecord] {
        guard sampleIDs.count <= remainingFactBudget else {
            throw AppDataFailure.corruptionSuspected
        }
        var output: [LabSampleRecord] = []
        for ids in chunks(sampleIDs) {
            var descriptor = FetchDescriptor<LabSampleRecord>(
                predicate: #Predicate { ids.contains($0.id) }
            )
            descriptor.fetchLimit = ids.count + 1
            output.append(
                contentsOf: try modelContext.fetch(descriptor)
            )
        }
        guard output.count == sampleIDs.count else {
            throw AppDataFailure.corruptionSuspected
        }
        remainingFactBudget -= output.count
        return output
    }

    private func baseLabTimes(
        sampleIDs: [UUID],
        remainingFactBudget: inout Int
    ) throws -> [HistoricalTimeRecord] {
        guard sampleIDs.count <= remainingFactBudget else {
            throw AppDataFailure.corruptionSuspected
        }
        let sourceType = "LabSampleRecord"
        var output: [HistoricalTimeRecord] = []
        for ids in chunks(sampleIDs) {
            var descriptor = FetchDescriptor<HistoricalTimeRecord>(
                predicate: #Predicate {
                    $0.sourceRecordType == sourceType
                        && ids.contains($0.sourceRecordID)
                }
            )
            descriptor.fetchLimit = ids.count + 1
            output.append(
                contentsOf: try modelContext.fetch(descriptor)
            )
        }
        guard output.count == sampleIDs.count else {
            throw AppDataFailure.corruptionSuspected
        }
        remainingFactBudget -= output.count
        return output
    }

    private func labCorrectionSnapshots(
        ids correctionIDs: [UUID],
        remainingFactBudget: inout Int
    ) throws -> [LabSampleCorrectionSnapshotRecord] {
        guard correctionIDs.count <= remainingFactBudget else {
            throw AppDataFailure.corruptionSuspected
        }
        var output: [LabSampleCorrectionSnapshotRecord] = []
        for ids in chunks(correctionIDs) {
            var descriptor =
                FetchDescriptor<LabSampleCorrectionSnapshotRecord>(
                    predicate: #Predicate {
                        ids.contains($0.id)
                    }
                )
            descriptor.fetchLimit = ids.count + 1
            output.append(
                contentsOf: try modelContext.fetch(descriptor)
            )
        }
        guard output.count == correctionIDs.count else {
            throw AppDataFailure.corruptionSuspected
        }
        remainingFactBudget -= output.count
        return output
    }

    private func chunks<T>(_ values: [T]) -> [[T]] {
        guard !values.isEmpty else { return [] }
        return stride(
            from: 0,
            to: values.count,
            by: Self.labTrendQueryChunkSize
        ).map { start in
            Array(
                values[
                    start..<min(
                        start + Self.labTrendQueryChunkSize,
                        values.count
                    )
                ]
            )
        }
    }

    private func trendCursorPrecedes(
        _ lhs: LabTrendCursor,
        _ rhs: LabTrendCursor
    ) -> Bool {
        if lhs.instant != rhs.instant {
            return lhs.instant > rhs.instant
        }
        let lhsSample = lhs.sampleID.uuidString
        let rhsSample = rhs.sampleID.uuidString
        if lhsSample != rhsSample {
            return lhsSample > rhsSample
        }
        if lhs.sortOrder != rhs.sortOrder {
            return lhs.sortOrder > rhs.sortOrder
        }
        return lhs.resultID.uuidString > rhs.resultID.uuidString
    }
}
