import CryptoKit
import Foundation
import SwiftData

enum TodayExecutionWriteFailure: Error, Equatable, Sendable {
    case invalidOccurrence
    case operationConflict
    case staleLeaf
    case duplicateEvent
}

struct CommitAdministrationCommand: Sendable {
    let operationID: UUID
    let eventID: UUID
    let occurrence: PlannedOccurrence
    let expectedLeafEventID: UUID?
    let status: AdministrationStatus
    let actualTimestamp: HistoricalTimestamp
    let note: String
    let committedAt: Date

    init(
        operationID: UUID,
        eventID: UUID,
        occurrence: PlannedOccurrence,
        expectedLeafEventID: UUID?,
        status: AdministrationStatus,
        actualTimestamp: HistoricalTimestamp,
        note: String = "",
        committedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.eventID = eventID
        self.occurrence = occurrence
        self.expectedLeafEventID = expectedLeafEventID
        self.status = status
        self.actualTimestamp = actualTimestamp
        self.note = note
        self.committedAt = committedAt
    }
}

struct AdministrationCommitResult: Equatable, Sendable {
    let eventID: UUID
    let didCreate: Bool
}

extension AppWriteActor {
    func commitAdministration(
        _ command: CommitAdministrationCommand
    ) throws -> AdministrationCommitResult {
        let digest = try TodayExecutionDigestV1.administrationCommand(command)
        if let replay = try administrationReplay(
            operationID: command.operationID,
            digest: digest
        ) {
            return replay
        }
        try validateAdministrationCommand(command)
        let existingEvents = try administrationEvents(for: command.occurrence.key)
        let leaf = try effectiveLeaf(in: existingEvents)
        guard leaf?.id == command.expectedLeafEventID else {
            throw TodayExecutionWriteFailure.staleLeaf
        }
        guard try fetchAdministrationEvent(id: command.eventID) == nil else {
            throw TodayExecutionWriteFailure.duplicateEvent
        }

        modelContext.autosaveEnabled = false
        let reservation = try reserveRevision()
        do {
            var result: AdministrationCommitResult?
            try modelContext.transaction {
                if let replay = try administrationReplay(
                    operationID: command.operationID,
                    digest: digest
                ) {
                    result = replay
                    return
                }
                try validateAdministrationCommand(command)
                let transactionalEvents = try administrationEvents(for: command.occurrence.key)
                let transactionalLeaf = try effectiveLeaf(in: transactionalEvents)
                guard transactionalLeaf?.id == command.expectedLeafEventID else {
                    throw TodayExecutionWriteFailure.staleLeaf
                }
                guard try fetchAdministrationEvent(id: command.eventID) == nil else {
                    throw TodayExecutionWriteFailure.duplicateEvent
                }

                let cleanNote = command.note.trimmingCharacters(in: .whitespacesAndNewlines)
                let event = AdministrationEventRecord(
                    id: command.eventID,
                    occurrenceKey: command.occurrence.key,
                    scheduleRuleID: command.occurrence.scheduleRuleID,
                    scheduleRevision: command.occurrence.scheduleRevision,
                    regimenVersionID: command.occurrence.regimenVersionID,
                    regimenItemID: command.occurrence.regimenItemID,
                    status: command.status,
                    plannedInstant: command.occurrence.instant,
                    supersedesEventID: command.expectedLeafEventID,
                    note: cleanNote,
                    operationID: command.operationID,
                    createdAt: command.committedAt
                )
                modelContext.insert(event)
                try upsertRevision(
                    recordType: "AdministrationEventRecord",
                    recordID: event.id,
                    fields: TodayExecutionDigestV1.administrationEvent(event),
                    reservation: reservation,
                    committedAt: command.committedAt
                )

                let association = try resolvedAssociationForWrite(
                    timestamp: command.actualTimestamp
                )
                try insertHistoricalTimeForWrite(
                    sourceRecordType: "AdministrationEventRecord",
                    sourceRecordID: event.id,
                    timestamp: command.actualTimestamp,
                    legacyAssociationID: nil,
                    resolvedAssociationID: association.id,
                    associationState: association.state,
                    reservation: reservation,
                    committedAt: command.committedAt
                )

                try insertOperationReceipt(
                    OperationReceiptRecord(
                        operationID: command.operationID,
                        commandDigest: digest,
                        resultRecordType: "AdministrationEventRecord",
                        resultRecordID: event.id,
                        committedAt: command.committedAt
                    ),
                    reservation: reservation
                )
                try markCommitted(at: command.committedAt)
                result = AdministrationCommitResult(eventID: event.id, didCreate: true)
            }
            guard let result else { throw AppWriteFailure.invalidInput }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func administrationReplay(
        operationID: UUID,
        digest: String
    ) throws -> AdministrationCommitResult? {
        var descriptor = FetchDescriptor<OperationReceiptRecord>(
            predicate: #Predicate { $0.operationID == operationID }
        )
        descriptor.fetchLimit = 1
        guard let receipt = try modelContext.fetch(descriptor).first else { return nil }
        guard receipt.commandDigest == digest,
              receipt.resultRecordType == "AdministrationEventRecord",
              try fetchAdministrationEvent(id: receipt.resultRecordID) != nil else {
            throw TodayExecutionWriteFailure.operationConflict
        }
        return AdministrationCommitResult(
            eventID: receipt.resultRecordID,
            didCreate: false
        )
    }

    private func validateAdministrationCommand(
        _ command: CommitAdministrationCommand
    ) throws {
        guard command.committedAt.timeIntervalSince1970.isFinite,
              command.actualTimestamp.instant.timeIntervalSince1970.isFinite else {
            throw TodayExecutionWriteFailure.invalidOccurrence
        }
        try validateOccurrenceForTodayExecution(command.occurrence)
    }

    func validateOccurrenceForTodayExecution(
        _ occurrence: PlannedOccurrence
    ) throws {
        guard occurrence.instant.timeIntervalSince1970.isFinite,
              occurrence.key == ScheduleOccurrenceResolver.occurrenceKey(
                ruleID: occurrence.scheduleRuleID,
                revision: occurrence.scheduleRevision,
                date: occurrence.localDate,
                time: occurrence.localTime
              ) else {
            throw TodayExecutionWriteFailure.invalidOccurrence
        }

        let ruleID = occurrence.scheduleRuleID
        var ruleDescriptor = FetchDescriptor<ScheduleRuleRecord>(
            predicate: #Predicate { $0.id == ruleID }
        )
        ruleDescriptor.fetchLimit = 1
        guard let rule = try modelContext.fetch(ruleDescriptor).first,
              rule.revision == occurrence.scheduleRevision,
              let kind = ScheduleRuleKind(rawValue: rule.kindRawValue),
              let zoneBehavior = ScheduleTimeZoneBehavior(
                rawValue: rule.timeZoneBehaviorRawValue
              ),
              let anchorDate = try? CivilDateFact(
                year: rule.anchorYear,
                month: rule.anchorMonth,
                day: rule.anchorDay
              ) else {
            throw TodayExecutionWriteFailure.invalidOccurrence
        }
        let endDate: CivilDateFact?
        if let year = rule.endYear,
           let month = rule.endMonth,
           let day = rule.endDay {
            endDate = try? CivilDateFact(year: year, month: month, day: day)
            guard endDate != nil else { throw TodayExecutionWriteFailure.invalidOccurrence }
        } else {
            guard rule.endYear == nil, rule.endMonth == nil, rule.endDay == nil else {
                throw TodayExecutionWriteFailure.invalidOccurrence
            }
            endDate = nil
        }

        let itemID = occurrence.regimenItemID
        var itemDescriptor = FetchDescriptor<RegimenItemRecord>(
            predicate: #Predicate { $0.id == itemID }
        )
        itemDescriptor.fetchLimit = 1
        guard let item = try modelContext.fetch(itemDescriptor).first,
              item.id == rule.regimenItemID,
              item.regimenVersionID == occurrence.regimenVersionID,
              item.displayName == occurrence.displayName else {
            throw TodayExecutionWriteFailure.invalidOccurrence
        }

        var versionDescriptor = FetchDescriptor<RegimenPlanVersionRecord>()
        versionDescriptor.fetchLimit = 513
        let allVersions = try modelContext.fetch(versionDescriptor)
        guard allVersions.count <= 512 else {
            throw TodayExecutionWriteFailure.invalidOccurrence
        }
        let eligibleRecords = allVersions.filter {
            $0.editState == .sealed && !$0.isArchived && !$0.requiresMigrationReview
        }
        let rawTimeline = eligibleRecords.compactMap { record -> RegimenTimelineVersion? in
            guard let start = record.effectiveStartDate else { return nil }
            return RegimenTimelineVersion(
                id: record.id,
                start: start,
                end: record.effectiveEndDate,
                editState: record.editState,
                requiresReview: record.requiresMigrationReview
            )
        }
        let occurrenceProjection = RegimenTimelineResolver.project(
            rawTimeline,
            asOf: occurrence.localDate
        )
        guard rawTimeline.count == eligibleRecords.count,
              !occurrenceProjection.isAmbiguous,
              occurrenceProjection.current?.id == occurrence.regimenVersionID,
              let version = eligibleRecords.first(where: {
                  $0.id == occurrence.regimenVersionID
              }) else {
            throw TodayExecutionWriteFailure.invalidOccurrence
        }

        let spec = ScheduleRuleSpec(
            id: rule.id,
            regimenVersionID: version.id,
            regimenItemID: item.id,
            displayName: item.displayName,
            kind: kind,
            anchorDate: anchorDate,
            endDate: endDate,
            localTimes: rule.localTimes,
            weekdays: rule.weekdays,
            intervalDays: rule.intervalDays,
            timeZoneBehavior: zoneBehavior,
            fixedTimeZoneIdentifier: rule.fixedTimeZoneIdentifier,
            revision: rule.revision
        )
        let resolution = try ScheduleOccurrenceResolver.occurrences(
            rules: [spec],
            interval: try occurrenceCivilDayInterval(occurrence),
            displayTimeZoneIdentifier: occurrence.timeZoneIdentifier
        )
        let hasBlockingIssue = resolution.issues.contains { issue in
            switch issue {
            case .invalidRule, .capacityExceeded:
                true
            case .nonexistentLocalTime:
                false
            }
        }
        let matches = resolution.occurrences.filter { $0.key == occurrence.key }
        guard !hasBlockingIssue,
              matches.count == 1,
              matches.first == occurrence else {
            throw TodayExecutionWriteFailure.invalidOccurrence
        }
    }

    private func occurrenceCivilDayInterval(
        _ occurrence: PlannedOccurrence
    ) throws -> DateInterval {
        guard let timeZone = TimeZone(identifier: occurrence.timeZoneIdentifier) else {
            throw TodayExecutionWriteFailure.invalidOccurrence
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let interval = calendar.dateInterval(of: .day, for: occurrence.instant) else {
            throw TodayExecutionWriteFailure.invalidOccurrence
        }
        return interval
    }

    private func administrationEvents(
        for occurrenceKey: String
    ) throws -> [AdministrationEventRecord] {
        let key = occurrenceKey
        return try modelContext.fetch(
            FetchDescriptor<AdministrationEventRecord>(
                predicate: #Predicate { $0.occurrenceKey == key }
            )
        )
    }

    private func effectiveLeaf(
        in events: [AdministrationEventRecord]
    ) throws -> AdministrationEventRecord? {
        guard Set(events.map(\.id)).count == events.count,
              events.allSatisfy({ $0.status != nil }) else {
            throw TodayExecutionWriteFailure.invalidOccurrence
        }
        let ids = Set(events.map(\.id))
        guard events.allSatisfy({ event in
            guard let predecessor = event.supersedesEventID else { return true }
            return predecessor != event.id && ids.contains(predecessor)
        }) else {
            throw TodayExecutionWriteFailure.invalidOccurrence
        }
        let successorGroups = Dictionary(
            grouping: events.compactMap { event in
                event.supersedesEventID.map { ($0, event.id) }
            },
            by: \.0
        )
        guard successorGroups.values.allSatisfy({ $0.count == 1 }) else {
            throw TodayExecutionWriteFailure.invalidOccurrence
        }
        let superseded = Set(events.compactMap(\.supersedesEventID))
        let leaves = events.filter { !superseded.contains($0.id) }
        guard leaves.count <= 1,
              events.isEmpty || leaves.count == 1 else {
            throw TodayExecutionWriteFailure.invalidOccurrence
        }
        if let leaf = leaves.first {
            var visited: Set<UUID> = []
            var cursor: AdministrationEventRecord? = leaf
            while let current = cursor {
                guard visited.insert(current.id).inserted else {
                    throw TodayExecutionWriteFailure.invalidOccurrence
                }
                guard let predecessorID = current.supersedesEventID else { break }
                cursor = events.first(where: { $0.id == predecessorID })
            }
            guard visited.count == events.count else {
                throw TodayExecutionWriteFailure.invalidOccurrence
            }
        }
        return leaves.first
    }

    private func fetchAdministrationEvent(
        id: UUID
    ) throws -> AdministrationEventRecord? {
        var descriptor = FetchDescriptor<AdministrationEventRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func insertOperationReceipt(
        _ receipt: OperationReceiptRecord,
        reservation: ReservedRevision
    ) throws {
        modelContext.insert(receipt)
        try upsertRevision(
            recordType: "OperationReceiptRecord",
            recordID: receipt.operationID,
            fields: TodayExecutionDigestV1.operationReceipt(receipt),
            reservation: reservation,
            committedAt: receipt.committedAt
        )

        var ledgerDescriptor = FetchDescriptor<OperationReceiptLedgerRecord>()
        ledgerDescriptor.fetchLimit = 2
        let ledgers = try modelContext.fetch(ledgerDescriptor)
        guard ledgers.count == 1, let ledger = ledgers.first else {
            throw AppDataFailure.corruptionSuspected
        }
        var receiptDescriptor = FetchDescriptor<OperationReceiptRecord>()
        receiptDescriptor.fetchLimit = 65_537
        let receipts = try modelContext.fetch(receiptDescriptor)
        guard receipts.count <= 65_536 else {
            throw AppDataFailure.corruptionSuspected
        }
        ledger.receiptCount = receipts.count
        ledger.receiptSetDigest = TodayExecutionDigestV1.receiptSetDigest(receipts)
        ledger.updatedAt = receipt.committedAt
        try upsertRevision(
            recordType: "OperationReceiptLedgerRecord",
            recordID: TodayExecutionDigestV1.receiptLedgerID,
            fields: TodayExecutionDigestV1.operationReceiptLedger(ledger),
            reservation: reservation,
            committedAt: receipt.committedAt
        )
    }
}

enum TodayExecutionDigestV1 {
    static func administrationCommand(
        _ command: CommitAdministrationCommand
    ) throws -> String {
        try RecordDigestV1.sha256Hex(
            recordType: "CommitAdministrationCommand",
            recordID: command.operationID,
            fields: [
                .init("actualInstant", timestamp(command.actualTimestamp.instant)),
                .init("actualLocalDate", .string(command.actualTimestamp.localDate.iso8601)),
                .init("actualLocalHour", .integer(Int64(command.actualTimestamp.localTime.hour))),
                .init("actualLocalMinute", .integer(Int64(command.actualTimestamp.localTime.minute))),
                .init("actualLocalNanosecond", .integer(Int64(command.actualTimestamp.localTime.nanosecond))),
                .init("actualLocalSecond", .integer(Int64(command.actualTimestamp.localTime.second))),
                .init("actualPrecision", .string(command.actualTimestamp.precision.rawValue)),
                .init("actualProvenance", .string(command.actualTimestamp.provenance.rawValue)),
                .init("actualTimeZoneIdentifier", .string(command.actualTimestamp.timeZoneIdentifier)),
                .init("actualUTCOffsetSeconds", .integer(Int64(command.actualTimestamp.utcOffsetSeconds))),
                .init("eventID", .uuid(command.eventID)),
                .init("expectedLeafEventID", command.expectedLeafEventID.map(RecordDigestV1.Value.uuid) ?? .null),
                .init("note", .string(command.note.trimmingCharacters(in: .whitespacesAndNewlines))),
                .init("occurrenceKey", .string(command.occurrence.key)),
                .init("status", .string(command.status.rawValue))
            ]
        )
    }

    static func administrationEvent(
        _ event: AdministrationEventRecord
    ) -> [RecordDigestV1.Field] {
        [
            .init("note", .string(event.note)),
            .init("occurrenceKey", .string(event.occurrenceKey)),
            .init("operationID", .uuid(event.operationID)),
            .init("plannedInstant", timestamp(event.plannedInstant)),
            .init("regimenItemID", .uuid(event.regimenItemID)),
            .init("regimenVersionID", .uuid(event.regimenVersionID)),
            .init("scheduleRevision", .integer(Int64(event.scheduleRevision))),
            .init("scheduleRuleID", .uuid(event.scheduleRuleID)),
            .init("status", .string(event.statusRawValue)),
            .init("supersedesEventID", event.supersedesEventID.map(RecordDigestV1.Value.uuid) ?? .null)
        ]
    }

    static let receiptLedgerID = CoreTimeRegimenBackfill.stableUUID(
        for: OperationReceiptLedgerRecord.fixedKey
    )

    static func operationReceipt(
        _ receipt: OperationReceiptRecord
    ) -> [RecordDigestV1.Field] {
        [
            .init("commandDigest", .string(receipt.commandDigest)),
            .init("committedAt", timestamp(receipt.committedAt)),
            .init("operationID", .uuid(receipt.operationID)),
            .init("resultRecordID", .uuid(receipt.resultRecordID)),
            .init("resultRecordType", .string(receipt.resultRecordType))
        ]
    }

    static func operationReceiptLedger(
        _ ledger: OperationReceiptLedgerRecord
    ) -> [RecordDigestV1.Field] {
        [
            .init("ledgerKey", .string(ledger.ledgerKey)),
            .init("receiptCount", .integer(Int64(ledger.receiptCount))),
            .init("receiptSetDigest", .string(ledger.receiptSetDigest))
        ]
    }

    static func receiptSetDigest(
        _ receipts: [OperationReceiptRecord]
    ) -> String {
        let canonical = receipts.map { receipt in
            [
                receipt.operationID.uuidString.lowercased(),
                receipt.commandDigest,
                receipt.resultRecordType,
                receipt.resultRecordID.uuidString.lowercased(),
                String(Int64((receipt.committedAt.timeIntervalSince1970 * 1_000_000).rounded()))
            ].joined(separator: "|")
        }
        .sorted()
        .joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func timestamp(_ date: Date) -> RecordDigestV1.Value {
        .timestampMicroseconds(Int64((date.timeIntervalSince1970 * 1_000_000).rounded()))
    }
}
