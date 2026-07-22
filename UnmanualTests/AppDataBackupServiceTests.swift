import SwiftData
import XCTest
@testable import Unmanual

@MainActor
final class AppDataBackupServiceTests: XCTestCase {
    func testBackupRoundTripPreservesEveryRecordCategory() throws {
        let exportedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let profile = HRTProfile(
            id: UUID(),
            startDate: exportedAt.addingTimeInterval(-86_400),
            activePeriodStartDate: exportedAt.addingTimeInterval(-43_200),
            createdAt: exportedAt.addingTimeInterval(-90_000)
        )
        let countdown = CountdownRecord(
            id: UUID(),
            title: "复诊",
            gentleTitle: "下一件事",
            targetDate: exportedAt.addingTimeInterval(86_400),
            createdAt: exportedAt,
            archivedAt: nil,
            continuesCountingUp: true
        )
        let regimen = RegimenVersion(
            id: UUID(),
            code: "R-02",
            title: "当前方案",
            startedAt: exportedAt.addingTimeInterval(-172_800),
            note: "保留备注",
            createdAt: exportedAt.addingTimeInterval(-172_900)
        )
        let journey = JourneyEntry(
            id: UUID(),
            text: "今天状态不错",
            kind: .feeling,
            occurredAt: exportedAt,
            createdAt: exportedAt,
            regimenVersionID: regimen.id
        )
        let lab = LabRecord(
            id: UUID(),
            itemName: "雌二醇",
            itemCode: "E2",
            rawValue: "180。5",
            numericValue: 180.5,
            unit: "pg/mL",
            sampledAt: exportedAt,
            referenceRangeOriginal: "原报告范围",
            contextNote: "上午采样",
            regimenVersionID: regimen.id,
            createdAt: exportedAt
        )

        let backup = AppDataBackupService.makeBackup(
            profiles: [profile],
            countdowns: [countdown],
            entries: [journey],
            labRecords: [lab],
            regimens: [regimen],
            exportedAt: exportedAt
        )
        let data = try AppDataBackupService.encode(backup)
        let decoded = try AppDataBackupService.decode(data)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.exportedAt, exportedAt)
        XCTAssertEqual(decoded.profiles.first?.id, profile.id)
        XCTAssertEqual(decoded.countdowns.first?.gentleTitle, "下一件事")
        XCTAssertEqual(decoded.countdowns.first?.continuesCountingUp, true)
        XCTAssertEqual(decoded.regimens.first?.note, "保留备注")
        XCTAssertEqual(decoded.entries.first?.kindRawValue, JourneyEntryKind.feeling.rawValue)
        XCTAssertEqual(decoded.entries.first?.regimenVersionID, regimen.id)
        XCTAssertEqual(decoded.labRecords.first?.rawValue, "180。5")
        XCTAssertEqual(decoded.labRecords.first?.referenceRangeOriginal, "原报告范围")
    }

    func testDecodeRejectsAnUnsupportedSchemaVersion() throws {
        let backup = AppDataBackup(
            format: AppDataBackupService.format,
            schemaVersion: 99,
            exportedAt: Date(timeIntervalSince1970: 1_750_000_000),
            profiles: [],
            countdowns: [],
            entries: [],
            labRecords: [],
            regimens: []
        )
        let data = try AppDataBackupService.encode(backup)

        XCTAssertThrowsError(try AppDataBackupService.decode(data)) { error in
            XCTAssertEqual(
                error as? AppDataBackupError,
                .unsupportedSchemaVersion(99)
            )
        }
    }

    func testImportSafelyMergesByIDWithoutDeletingLocalRecords() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let sharedJourneyID = UUID()
        let existingJourney = JourneyEntry(
            id: sharedJourneyID,
            text: "旧内容",
            kind: .moment,
            occurredAt: now.addingTimeInterval(-60),
            createdAt: now.addingTimeInterval(-60)
        )
        let localOnlyCountdown = CountdownRecord(
            title: "只在本机的倒计时",
            targetDate: now.addingTimeInterval(86_400)
        )
        context.insert(existingJourney)
        context.insert(localOnlyCountdown)
        try context.save()

        let regimen = RegimenVersion(code: "R-03", title: "导入方案", startedAt: now)
        let incomingJourney = JourneyEntry(
            id: sharedJourneyID,
            text: "备份中的新内容",
            kind: .feeling,
            occurredAt: now,
            createdAt: now,
            regimenVersionID: regimen.id
        )
        let backup = AppDataBackupService.makeBackup(
            profiles: [HRTProfile(startDate: now)],
            countdowns: [CountdownRecord(title: "备份倒计时", targetDate: now)],
            entries: [incomingJourney],
            labRecords: [
                LabRecord(
                    itemName: "雌二醇",
                    itemCode: "E2",
                    rawValue: "180",
                    numericValue: 180,
                    unit: "pg/mL",
                    sampledAt: now,
                    regimenVersionID: regimen.id
                )
            ],
            regimens: [regimen],
            exportedAt: now
        )

        let result = try AppDataBackupService.importBackup(backup, into: context)

        XCTAssertEqual(result.insertedCount, 4)
        XCTAssertEqual(result.updatedCount, 1)
        let journeys = try context.fetch(FetchDescriptor<JourneyEntry>())
        XCTAssertEqual(journeys.count, 1)
        XCTAssertEqual(journeys.first?.text, "备份中的新内容")
        XCTAssertEqual(journeys.first?.kind, .feeling)
        XCTAssertEqual(journeys.first?.regimenVersionID, regimen.id)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HRTProfile>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CountdownRecord>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LabRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RegimenVersion>()), 1)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            HRTProfile.self,
            CountdownRecord.self,
            RegimenVersion.self,
            JourneyEntry.self,
            LabRecord.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
