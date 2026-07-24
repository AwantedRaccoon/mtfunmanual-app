import Foundation
import SwiftData

enum PersonalTimelineRelationshipValidator {
    static func validate(
        in context: ModelContext,
        failure: AppDataFailure
    ) throws {
        let states = try context.fetch(FetchDescriptor<PersonalTimelineBackfillState>())
        guard states.count == 1,
              states[0].taskKey == PersonalTimelineBackfillState.fixedKey,
              states[0].completedAt?.timeIntervalSince1970.isFinite == true,
              states[0].updatedAt.timeIntervalSince1970.isFinite else {
            throw failure
        }

        let definitions = try context.fetch(FetchDescriptor<LabItemDefinitionRecord>())
        let definitionByID = try AppDataIndex.checkedUniqueMap(
            definitions,
            keyedBy: \.id,
            failure: failure
        )
        guard definitions.count
                <= PersonalTimelineCapacity.maximumLabItemDefinitions,
              definitions.allSatisfy({
            guard let kind = LabItemDefinitionKind(
                rawValue: $0.kindRawValue
            ) else {
                return false
            }
            return !$0.displayName.isEmpty
                && (kind != .bundled || $0.bundledStableID?.isEmpty == false)
        }) else {
            throw failure
        }

        let samples = try context.fetch(FetchDescriptor<LabSampleRecord>())
        let sampleByID = try AppDataIndex.checkedUniqueMap(
            samples,
            keyedBy: \.id,
            failure: failure
        )
        let results = try context.fetch(FetchDescriptor<LabResultRecord>())
        guard Set(results.map(\.id)).count == results.count,
              results.allSatisfy({ result in
                  sampleByID[result.sampleID] != nil
                      && definitionByID[result.itemDefinitionID] != nil
                      && result.operationID == sampleByID[result.sampleID]?.operationID
                      && result.comparatorRawValue.map {
                          LabValueComparator(rawValue: $0) != nil
                      } != false
                      && (try? LabDecimalValue.parse(result.canonicalDecimalString)) != nil
              }) else {
            throw failure
        }
        for group in Dictionary(grouping: results, by: \.sampleID).values {
            let orders = group.map(\.sortOrder).sorted()
            guard group.count
                    <= PersonalTimelineCapacity.maximumLabResultsPerSample,
                  orders == Array(0..<orders.count) else {
                throw failure
            }
        }

        let metrics = try context.fetch(FetchDescriptor<StatusMetricDefinitionRecord>())
        let metricByID = try AppDataIndex.checkedUniqueMap(
            metrics,
            keyedBy: \.id,
            failure: failure
        )
        guard metrics.count
                <= PersonalTimelineCapacity.maximumStatusMetricDefinitions,
              metrics.filter({ !$0.isArchived }).count <= 5,
              metrics.allSatisfy({
                  !$0.displayName.isEmpty && $0.createdAt.timeIntervalSince1970.isFinite
              }) else {
            throw failure
        }
        let observations = try context.fetch(FetchDescriptor<StatusObservationRecord>())
        let observationByID = try AppDataIndex.checkedUniqueMap(
            observations,
            keyedBy: \.id,
            failure: failure
        )
        guard observations.allSatisfy({
            metricByID[$0.metricDefinitionID] != nil
                && !$0.metricNameSnapshot.isEmpty
                && (1...4).contains($0.ordinalLevel)
                && $0.createdAt.timeIntervalSince1970.isFinite
        }) else {
            throw failure
        }

        let journeyIDs = Set(try context.fetch(FetchDescriptor<JourneyEntry>()).map(\.id))
        let attachments = try context.fetch(FetchDescriptor<AttachmentRecord>())
        let attachmentOwnerSampleIDs = Set(
            attachments
                .filter { $0.ownerType == .labSample && $0.deletedAt == nil }
                .map(\.ownerID)
        )
        guard samples.allSatisfy({ sample in
            results.contains(where: { result in result.sampleID == sample.id })
                || attachmentOwnerSampleIDs.contains(sample.id)
        }) else {
            throw failure
        }
        guard Set(attachments.map(\.id)).count == attachments.count,
              Set(attachments.map(\.relativePath)).count == attachments.count,
              attachments.allSatisfy({ attachment in
                  let prepared = PreparedAttachmentMetadata(
                      operationID: attachment.operationID,
                      attachmentID: attachment.id,
                      relativePath: attachment.relativePath,
                      originalFilename: attachment.originalFilename,
                      typeIdentifier: attachment.typeIdentifier,
                      byteCount: attachment.byteCount,
                      sha256Hex: attachment.sha256Hex
                  )
                  guard (try? AttachmentMetadataFacts.normalize(prepared)) != nil,
                        let ownerType = attachment.ownerType,
                        attachment.byteCount > 0,
                        attachment.byteCount <= AttachmentFileStore.maximumFileBytes,
                        attachment.sha256Hex.count == 64,
                        attachment.sha256Hex.allSatisfy(\.isHexDigit),
                        !attachment.relativePath.hasPrefix("/"),
                        !attachment.relativePath.split(separator: "/").contains(".."),
                        attachment.createdAt.timeIntervalSince1970.isFinite,
                        attachment.deletedAt?.timeIntervalSince1970.isFinite != false,
                        attachment.deleteOperationID != attachment.operationID else {
                      return false
                  }
                  switch ownerType {
                  case .labSample:
                      return sampleByID[attachment.ownerID] != nil
                  case .statusObservation:
                      return observationByID[attachment.ownerID] != nil
                  case .journeyEntry:
                      return journeyIDs.contains(attachment.ownerID)
                  }
              }) else {
            throw failure
        }
        for group in Dictionary(
            grouping: attachments.filter { $0.deletedAt == nil },
            by: { $0.ownerTypeRawValue + ":" + $0.ownerID.uuidString }
        ).values {
            let total = group.reduce(Int64(0)) { partial, attachment in
                let addition = partial.addingReportingOverflow(attachment.byteCount)
                return addition.overflow ? Int64.max : addition.partialValue
            }
            guard group.count <= AttachmentFileStore.maximumOwnerFiles,
                  total <= AttachmentFileStore.maximumOwnerBytes else {
                throw failure
            }
        }

        let times = try context.fetch(FetchDescriptor<HistoricalTimeRecord>())
        let sampleTimeKeys = Set(times.filter {
            $0.sourceRecordType == "LabSampleRecord"
        }.map(\.recordKey))
        let observationTimeKeys = Set(times.filter {
            $0.sourceRecordType == "StatusObservationRecord"
        }.map(\.recordKey))
        guard sampleTimeKeys == Set(samples.map {
            "LabSampleRecord:" + $0.id.uuidString.lowercased()
        }),
        observationTimeKeys == Set(observations.map {
            "StatusObservationRecord:" + $0.id.uuidString.lowercased()
        }) else {
            throw failure
        }

        let receipts = try context.fetch(FetchDescriptor<OperationReceiptRecord>())
        let receiptByOperationID = try AppDataIndex.checkedUniqueMap(
            receipts,
            keyedBy: \.operationID,
            failure: failure
        )
        var expectedV5Receipts = Set<V5ReceiptIdentity>()
        for sample in samples {
            guard let receipt = receiptByOperationID[sample.operationID],
                  receipt.resultRecordType == "LabSampleRecord",
                  receipt.resultRecordID == sample.id else {
                throw failure
            }
            expectedV5Receipts.insert(V5ReceiptIdentity(receipt))
        }
        for metric in metrics {
            guard let receipt = receiptByOperationID[metric.operationID],
                  receipt.resultRecordType == "StatusMetricDefinitionRecord",
                  receipt.resultRecordID == metric.id else {
                throw failure
            }
            expectedV5Receipts.insert(V5ReceiptIdentity(receipt))
            if let archiveOperationID = metric.archiveOperationID {
                guard metric.isArchived,
                      archiveOperationID != metric.operationID,
                      let archiveReceipt = receiptByOperationID[
                          archiveOperationID
                      ],
                      archiveReceipt.resultRecordType
                        == "StatusMetricDefinitionRecord",
                      archiveReceipt.resultRecordID == metric.id else {
                    throw failure
                }
                expectedV5Receipts.insert(V5ReceiptIdentity(archiveReceipt))
            } else if metric.isArchived {
                throw failure
            }
        }
        for observation in observations {
            guard let receipt = receiptByOperationID[observation.operationID],
                  receipt.resultRecordType == "StatusObservationRecord",
                  receipt.resultRecordID == observation.id else {
                throw failure
            }
            expectedV5Receipts.insert(V5ReceiptIdentity(receipt))
        }
        for attachment in attachments {
            guard let receipt = receiptByOperationID[attachment.operationID],
                  receipt.resultRecordType == "AttachmentRecord",
                  receipt.resultRecordID == attachment.id else {
                throw failure
            }
            expectedV5Receipts.insert(V5ReceiptIdentity(receipt))
            if let deleteOperationID = attachment.deleteOperationID {
                guard attachment.deletedAt != nil,
                      let deleteReceipt = receiptByOperationID[deleteOperationID],
                      deleteReceipt.resultRecordType == "AttachmentRecord",
                      deleteReceipt.resultRecordID == attachment.id else {
                    throw failure
                }
                expectedV5Receipts.insert(V5ReceiptIdentity(deleteReceipt))
            } else if attachment.deletedAt != nil {
                throw failure
            }
        }
        let v5RecordTypes: Set<String> = [
            "LabSampleRecord",
            "StatusMetricDefinitionRecord",
            "StatusObservationRecord",
            "AttachmentRecord"
        ]
        let actualV5ReceiptValues = receipts
            .filter { v5RecordTypes.contains($0.resultRecordType) }
            .map(V5ReceiptIdentity.init)
        guard actualV5ReceiptValues.count == expectedV5Receipts.count,
              Set(actualV5ReceiptValues) == expectedV5Receipts else {
            throw failure
        }
    }

    private struct V5ReceiptIdentity: Hashable {
        let operationID: UUID
        let resultRecordType: String
        let resultRecordID: UUID

        init(_ receipt: OperationReceiptRecord) {
            operationID = receipt.operationID
            resultRecordType = receipt.resultRecordType
            resultRecordID = receipt.resultRecordID
        }
    }
}
