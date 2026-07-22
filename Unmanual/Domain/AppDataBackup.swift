import Foundation
import SwiftData

struct AppDataBackup: Codable, Equatable {
    let format: String
    let schemaVersion: Int
    let exportedAt: Date
    let profiles: [Profile]
    let countdowns: [Countdown]
    let entries: [Journey]
    let labRecords: [Lab]
    let regimens: [Regimen]

    var totalRecordCount: Int {
        profiles.count + countdowns.count + entries.count + labRecords.count + regimens.count
    }

    struct Profile: Codable, Equatable {
        let id: UUID
        let startDate: Date
        let activePeriodStartDate: Date
        let createdAt: Date

        init(_ model: HRTProfile) {
            id = model.id
            startDate = model.startDate
            activePeriodStartDate = model.activePeriodStartDate
            createdAt = model.createdAt
        }
    }

    struct Countdown: Codable, Equatable {
        let id: UUID
        let title: String
        let gentleTitle: String?
        let targetDate: Date
        let createdAt: Date
        let archivedAt: Date?
        let continuesCountingUp: Bool

        init(_ model: CountdownRecord) {
            id = model.id
            title = model.title
            gentleTitle = model.gentleTitle
            targetDate = model.targetDate
            createdAt = model.createdAt
            archivedAt = model.archivedAt
            continuesCountingUp = model.continuesCountingUp
        }
    }

    struct Journey: Codable, Equatable {
        let id: UUID
        let text: String
        let kindRawValue: String
        let occurredAt: Date
        let createdAt: Date
        let regimenVersionID: UUID?

        init(_ model: JourneyEntry) {
            id = model.id
            text = model.text
            kindRawValue = model.kindRawValue
            occurredAt = model.occurredAt
            createdAt = model.createdAt
            regimenVersionID = model.regimenVersionID
        }
    }

    struct Lab: Codable, Equatable {
        let id: UUID
        let itemName: String
        let itemCode: String
        let rawValue: String
        let numericValue: Double
        let unit: String
        let sampledAt: Date
        let referenceRangeOriginal: String?
        let contextNote: String
        let regimenVersionID: UUID?
        let createdAt: Date

        init(_ model: LabRecord) {
            id = model.id
            itemName = model.itemName
            itemCode = model.itemCode
            rawValue = model.rawValue
            numericValue = model.numericValue
            unit = model.unit
            sampledAt = model.sampledAt
            referenceRangeOriginal = model.referenceRangeOriginal
            contextNote = model.contextNote
            regimenVersionID = model.regimenVersionID
            createdAt = model.createdAt
        }
    }

    struct Regimen: Codable, Equatable {
        let id: UUID
        let code: String
        let title: String
        let startedAt: Date
        let endedAt: Date?
        let note: String
        let createdAt: Date

        init(_ model: RegimenVersion) {
            id = model.id
            code = model.code
            title = model.title
            startedAt = model.startedAt
            endedAt = model.endedAt
            note = model.note
            createdAt = model.createdAt
        }
    }
}

enum AppDataBackupService {
    static let format = "mtfunmanual-app-backup"
    static let currentSchemaVersion = 1

    static func makeBackup(
        profiles: [HRTProfile],
        countdowns: [CountdownRecord],
        entries: [JourneyEntry],
        labRecords: [LabRecord],
        regimens: [RegimenVersion],
        exportedAt: Date = Date()
    ) -> AppDataBackup {
        AppDataBackup(
            format: format,
            schemaVersion: currentSchemaVersion,
            exportedAt: exportedAt,
            profiles: profiles.map(AppDataBackup.Profile.init),
            countdowns: countdowns.map(AppDataBackup.Countdown.init),
            entries: entries.map(AppDataBackup.Journey.init),
            labRecords: labRecords.map(AppDataBackup.Lab.init),
            regimens: regimens.map(AppDataBackup.Regimen.init)
        )
    }

    static func encode(_ backup: AppDataBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    static func decode(_ data: Data) throws -> AppDataBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let backup = try decoder.decode(AppDataBackup.self, from: data)
        try validate(backup)
        return backup
    }

    private static func validate(_ backup: AppDataBackup) throws {
        guard backup.format == format else {
            throw AppDataBackupError.invalidFormat
        }
        guard backup.schemaVersion == currentSchemaVersion else {
            throw AppDataBackupError.unsupportedSchemaVersion(backup.schemaVersion)
        }
    }

#if DEBUG
    @MainActor
    static func importBackup(
        _ backup: AppDataBackup,
        into context: ModelContext
    ) throws -> AppDataImportResult {
        try validate(backup)
        var insertedCount = 0
        var updatedCount = 0

        let existingProfiles = try context.fetch(FetchDescriptor<HRTProfile>())
        let existingCountdowns = try context.fetch(FetchDescriptor<CountdownRecord>())
        let existingRegimens = try context.fetch(FetchDescriptor<RegimenVersion>())
        let existingEntries = try context.fetch(FetchDescriptor<JourneyEntry>())
        let existingLabRecords = try context.fetch(FetchDescriptor<LabRecord>())

        var profilesByID = Dictionary(
            uniqueKeysWithValues: existingProfiles.map { ($0.id, $0) }
        )
        for item in backup.profiles {
            if let model = profilesByID[item.id] {
                model.startDate = item.startDate
                model.activePeriodStartDate = item.activePeriodStartDate
                model.createdAt = item.createdAt
                updatedCount += 1
            } else {
                let model = HRTProfile(
                    id: item.id,
                    startDate: item.startDate,
                    activePeriodStartDate: item.activePeriodStartDate,
                    createdAt: item.createdAt
                )
                context.insert(model)
                profilesByID[item.id] = model
                insertedCount += 1
            }
        }

        var countdownsByID = Dictionary(
            uniqueKeysWithValues: existingCountdowns.map { ($0.id, $0) }
        )
        for item in backup.countdowns {
            if let model = countdownsByID[item.id] {
                model.title = item.title
                model.gentleTitle = item.gentleTitle
                model.targetDate = item.targetDate
                model.createdAt = item.createdAt
                model.archivedAt = item.archivedAt
                model.continuesCountingUp = item.continuesCountingUp
                updatedCount += 1
            } else {
                let model = CountdownRecord(
                    id: item.id,
                    title: item.title,
                    gentleTitle: item.gentleTitle,
                    targetDate: item.targetDate,
                    createdAt: item.createdAt,
                    archivedAt: item.archivedAt,
                    continuesCountingUp: item.continuesCountingUp
                )
                context.insert(model)
                countdownsByID[item.id] = model
                insertedCount += 1
            }
        }

        var regimensByID = Dictionary(
            uniqueKeysWithValues: existingRegimens.map { ($0.id, $0) }
        )
        for item in backup.regimens {
            if let model = regimensByID[item.id] {
                model.code = item.code
                model.title = item.title
                model.startedAt = item.startedAt
                model.endedAt = item.endedAt
                model.note = item.note
                model.createdAt = item.createdAt
                updatedCount += 1
            } else {
                let model = RegimenVersion(
                    id: item.id,
                    code: item.code,
                    title: item.title,
                    startedAt: item.startedAt,
                    endedAt: item.endedAt,
                    note: item.note,
                    createdAt: item.createdAt
                )
                context.insert(model)
                regimensByID[item.id] = model
                insertedCount += 1
            }
        }

        var entriesByID = Dictionary(
            uniqueKeysWithValues: existingEntries.map { ($0.id, $0) }
        )
        for item in backup.entries {
            if let model = entriesByID[item.id] {
                model.text = item.text
                model.kindRawValue = item.kindRawValue
                model.occurredAt = item.occurredAt
                model.createdAt = item.createdAt
                model.regimenVersionID = item.regimenVersionID
                updatedCount += 1
            } else {
                let model = JourneyEntry(
                    id: item.id,
                    text: item.text,
                    kind: JourneyEntryKind(rawValue: item.kindRawValue) ?? .moment,
                    occurredAt: item.occurredAt,
                    createdAt: item.createdAt,
                    regimenVersionID: item.regimenVersionID
                )
                context.insert(model)
                entriesByID[item.id] = model
                insertedCount += 1
            }
        }

        var labRecordsByID = Dictionary(
            uniqueKeysWithValues: existingLabRecords.map { ($0.id, $0) }
        )
        for item in backup.labRecords {
            if let model = labRecordsByID[item.id] {
                model.itemName = item.itemName
                model.itemCode = item.itemCode
                model.rawValue = item.rawValue
                model.numericValue = item.numericValue
                model.unit = item.unit
                model.sampledAt = item.sampledAt
                model.referenceRangeOriginal = item.referenceRangeOriginal
                model.contextNote = item.contextNote
                model.regimenVersionID = item.regimenVersionID
                model.createdAt = item.createdAt
                updatedCount += 1
            } else {
                let model = LabRecord(
                    id: item.id,
                    itemName: item.itemName,
                    itemCode: item.itemCode,
                    rawValue: item.rawValue,
                    numericValue: item.numericValue,
                    unit: item.unit,
                    sampledAt: item.sampledAt,
                    referenceRangeOriginal: item.referenceRangeOriginal,
                    contextNote: item.contextNote,
                    regimenVersionID: item.regimenVersionID,
                    createdAt: item.createdAt
                )
                context.insert(model)
                labRecordsByID[item.id] = model
                insertedCount += 1
            }
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return AppDataImportResult(insertedCount: insertedCount, updatedCount: updatedCount)
    }
#endif
}

struct AppDataImportResult: Equatable {
    let insertedCount: Int
    let updatedCount: Int
}

enum AppDataBackupError: Error, Equatable, LocalizedError {
    case invalidFormat
    case unsupportedSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "这不是 Unmanual 的 App 数据备份文件。"
        case let .unsupportedSchemaVersion(version):
            "这个备份使用版本 \(version)，当前 App 暂时无法导入。"
        }
    }
}
