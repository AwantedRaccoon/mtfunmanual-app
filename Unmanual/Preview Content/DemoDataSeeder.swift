#if DEBUG
import Foundation
import SwiftData

@MainActor
enum DemoDataSeeder {
    static func seedIfRequested(container: ModelContainer) async {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-unmanual-demo-home") {
            seedLegacyHome(container: container, arguments: arguments)
        }
        if arguments.contains("-unmanual-today-execution") {
            try? await seedTodayExecution(container: container)
        }
        if arguments.contains("-unmanual-onboarding-eligible-regimen") {
            try? await seedTodayExecution(container: container)
        }
        if arguments.contains("-unmanual-regimen-analysis-fixture") {
            try? await seedRegimenAnalysis(container: container)
        }
        if arguments.contains("-unmanual-countdown-due") {
            try? await seedDueCountdown(container: container)
        }
        if arguments.contains("-unmanual-lab-trend") {
            try? await seedLabTrend(container: container)
        }
    }

    private static func seedLegacyHome(
        container: ModelContainer,
        arguments: [String]
    ) {
        let context = container.mainContext
        let existingProfiles = (try? context.fetch(FetchDescriptor<HRTProfile>())) ?? []
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        var regimen = ((try? context.fetch(FetchDescriptor<RegimenVersion>())) ?? [])
            .first(where: { $0.endedAt == nil })

        if existingProfiles.isEmpty {
            let hrtDay = arguments.contains("-unmanual-demo-long-hrt") ? 1_428 : 238
            let startDate = calendar.date(byAdding: .day, value: 1 - hrtDay, to: now) ?? now
            let targetDate = calendar.date(byAdding: .day, value: 18, to: now) ?? now
            let createdRegimen = RegimenVersion(
                code: "R-02",
                title: "当前方案",
                startedAt: calendar.date(byAdding: .day, value: -42, to: now) ?? startDate,
                note: "按自己的原始记录保存"
            )

            context.insert(HRTProfile(startDate: startDate))
            context.insert(
                CountdownRecord(
                    title: "下一次复诊",
                    gentleTitle: "私人日期",
                    targetDate: targetDate
                )
            )
            context.insert(createdRegimen)
            regimen = createdRegimen

            let entryPlan: [(Int, JourneyEntryKind, String)] = [
                (-6, .moment, "把开始这段旅程的日期记了下来。"),
                (-4, .feeling, "今天的精力比前两天稳定一些。"),
                (-4, .change, "记下了一个想继续观察的小变化。"),
                (-2, .moment, "第一次更自在地穿喜欢的衣服出门。"),
                (0, .question, "今天想起一件下次要问的问题。")
            ]

            for (offset, kind, text) in entryPlan {
                let occurredAt = calendar.date(byAdding: .day, value: offset, to: now) ?? now
                context.insert(
                    JourneyEntry(
                        text: text,
                        kind: kind,
                        occurredAt: occurredAt,
                        regimenVersionID: createdRegimen.id
                    )
                )
            }
        }

        let existingLabs = (try? context.fetch(FetchDescriptor<LabRecord>())) ?? []
        if existingLabs.isEmpty {
            let labPlan: [(Int, String, String, String, Double, String)] = [
                (-120, "雌二醇", "E2", "146", 146, "pg/mL"),
                (-60, "雌二醇", "E2", "165", 165, "pg/mL"),
                (-6, "雌二醇", "E2", "172", 172, "pg/mL"),
                (-120, "睾酮", "T", "0.72", 0.72, "ng/mL"),
                (-60, "睾酮", "T", "0.58", 0.58, "ng/mL"),
                (-6, "睾酮", "T", "0.46", 0.46, "ng/mL")
            ]

            for (offset, name, code, rawValue, numericValue, unit) in labPlan {
                let sampledAt = calendar.date(byAdding: .day, value: offset, to: now) ?? now
                context.insert(
                    LabRecord(
                        itemName: name,
                        itemCode: code,
                        rawValue: rawValue,
                        numericValue: numericValue,
                        unit: unit,
                        sampledAt: sampledAt,
                        regimenVersionID: regimen?.id
                    )
                )
            }
        }

        try? context.save()
    }

    private static func seedTodayExecution(container: ModelContainer) async throws {
        let context = container.mainContext
        let sealed = try context.fetch(FetchDescriptor<RegimenPlanVersionRecord>())
            .contains { $0.editState == .sealed && !$0.isArchived }
        guard !sealed else { return }

        let now = Date()
        let effectiveDate = try HistoricalTimestamp.captured(
            instant: now,
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
            provenance: .captured
        ).localDate
        let writer = AppWriteActor(modelContainer: container)
        let draftID = UUID()
        try await writer.saveRegimenDraft(
            SaveRegimenDraftCommand(
                recordID: draftID,
                previousVersionID: nil,
                code: "R-DEMO",
                title: "今日执行测试方案",
                effectiveStartDate: effectiveDate,
                changeReason: "DEBUG UI fixture",
                items: [
                    RegimenItemInput(
                        displayName: "雌二醇片（测试项目）",
                        productSnapshot: "仅用于 DEBUG UI 测试",
                        schedule: RegimenScheduleInput(
                            kind: .dailyTimes,
                            localTimes: "08:00,20:30",
                            timeZoneBehavior: .floatingLocal
                        )
                    )
                ],
                committedAt: now
            )
        )
        let preview = try await writer.previewRegimenChange(draftID: draftID)
        try await writer.sealRegimenDraft(
            SealRegimenDraftCommand(
                draftID: draftID,
                expectedNextLocalRevision: preview.expectedNextLocalRevision,
                draftDigest: preview.draftDigest,
                committedAt: now
            )
        )
    }

    private static func seedRegimenAnalysis(
        container: ModelContainer
    ) async throws {
        let context = container.mainContext
        guard try context.fetchCount(
            FetchDescriptor<RegimenPlanVersionRecord>()
        ) == 0 else {
            return
        }

        guard let catalogEntry = MedicationCatalog.entries.first(
            where: { $0.id == "estradiol" }
        ),
            let catalogProduct = catalogEntry.products.first(
                where: { $0.id == "record.estradiol.oral-tablet" }
            ) else {
            return
        }
        let medicationDraft = catalogEntry.draft(for: catalogProduct)

        let now = Date()
        let timeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier
        let calendar = Calendar.autoupdatingCurrent
        let writer = AppWriteActor(modelContainer: container)
        let versionIDs = [
            UUID(
                uuidString: "99000000-0000-0000-0000-000000000001"
            )!,
            UUID(
                uuidString: "99000000-0000-0000-0000-000000000002"
            )!,
            UUID(
                uuidString: "99000000-0000-0000-0000-000000000003"
            )!
        ]

        func civilDate(daysFromNow: Int) throws -> CivilDateFact {
            let date = calendar.date(
                byAdding: .day,
                value: daysFromNow,
                to: now
            ) ?? now
            return try HistoricalTimestamp.captured(
                instant: date,
                timeZoneIdentifier: timeZoneIdentifier,
                provenance: .captured
            ).localDate
        }

        func sealVersion(
            index: Int,
            daysFromNow: Int,
            previousVersionID: UUID?
        ) async throws {
            let draftID = versionIDs[index]
            try await writer.saveRegimenDraft(
                SaveRegimenDraftCommand(
                    recordID: draftID,
                    previousVersionID: previousVersionID,
                    code: "R-8B-0\(index + 1)",
                    title: index == 2
                        ? "当前测试方案"
                        : "历史测试方案 \(index + 1)",
                    effectiveStartDate: try civilDate(
                        daysFromNow: daysFromNow
                    ),
                    changeReason: "DEBUG Batch 8B UI fixture",
                    items: [
                        RegimenItemInput(
                            catalogProductID: medicationDraft.catalogID,
                            catalogVersion: medicationDraft.catalogVersion,
                            displayName: medicationDraft.name,
                            genericName: medicationDraft.englishName,
                            dosageForm: medicationDraft.dosageForm,
                            route: medicationDraft.route,
                            doseOriginal: "用户原文",
                            unitOriginal: "原单位",
                            productSnapshot: medicationDraft.productSnapshot,
                            schedule: RegimenScheduleInput(
                                kind: .dailyTimes,
                                localTimes: "08:00",
                                timeZoneBehavior: .floatingLocal
                            )
                        )
                    ],
                    committedAt: now.addingTimeInterval(
                        TimeInterval(index)
                    )
                )
            )
            let preview = try await writer.previewRegimenChange(
                draftID: draftID
            )
            try await writer.sealRegimenDraft(
                SealRegimenDraftCommand(
                    draftID: draftID,
                    expectedNextLocalRevision:
                        preview.expectedNextLocalRevision,
                    draftDigest: preview.draftDigest,
                    committedAt: now.addingTimeInterval(
                        TimeInterval(index) + 0.5
                    )
                )
            )
        }

        try await sealVersion(
            index: 0,
            daysFromNow: -60,
            previousVersionID: nil
        )
        try await sealVersion(
            index: 1,
            daysFromNow: -30,
            previousVersionID: versionIDs[0]
        )
        try await sealVersion(
            index: 2,
            daysFromNow: 0,
            previousVersionID: versionIDs[1]
        )
    }

    private static func seedDueCountdown(
        container: ModelContainer
    ) async throws {
        let context = container.mainContext
        guard try context.fetchCount(
            FetchDescriptor<CountdownStateRecord>()
        ) == 0 else { return }
        let now = Date()
        let timestamp = try HistoricalTimestamp.captured(
            instant: now,
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
            provenance: .captured
        )
        _ = try await AppWriteActor(
            modelContainer: container
        ).createCountdown(
            CreateCountdownCommand(
                operationID: UUID(),
                eventID: UUID(),
                title: "到期测试",
                gentleTitle: nil,
                targetDate: timestamp.localDate,
                showInToday: true,
                reminder: .disabled,
                timestamp: timestamp
            )
        )
    }

    private static func seedLabTrend(
        container: ModelContainer
    ) async throws {
        let context = container.mainContext
        guard try context.fetchCount(
            FetchDescriptor<LabSampleRecord>()
        ) == 0 else { return }
        let writer = AppWriteActor(modelContainer: container)
        let definitionID = UUID(
            uuidString: "89000000-0000-0000-0000-000000000001"
        )!
        let testosteroneDefinitionID = UUID(
            uuidString: "89000000-0000-0000-0000-000000000002"
        )!
        let fixtures: [
            (
                sampleID: UUID,
                resultID: UUID,
                rawValue: String,
                unit: String,
                instant: Date
            )
        ] = [
            (
                UUID(
                    uuidString:
                        "89000000-0000-0000-0000-000000000101"
                )!,
                UUID(
                    uuidString:
                        "89000000-0000-0000-0000-000000000201"
                )!,
                "< 150",
                "pmol/L",
                Date(timeIntervalSince1970: 1_735_689_600)
            ),
            (
                UUID(
                    uuidString:
                        "89000000-0000-0000-0000-000000000102"
                )!,
                UUID(
                    uuidString:
                        "89000000-0000-0000-0000-000000000202"
                )!,
                "0.16",
                "nmol/L",
                Date(timeIntervalSince1970: 1_738_368_000)
            ),
            (
                UUID(
                    uuidString:
                        "89000000-0000-0000-0000-000000000103"
                )!,
                UUID(
                    uuidString:
                        "89000000-0000-0000-0000-000000000203"
                )!,
                "172.5",
                "pmol/L",
                Date(timeIntervalSince1970: 1_741_046_400)
            )
        ]
        for (index, fixture) in fixtures.enumerated() {
            let timestamp = try HistoricalTimestamp.captured(
                instant: fixture.instant,
                timeZoneIdentifier: "UTC",
                precision: .minute,
                provenance: .userEntered
            )
            _ = try await writer.createLabSample(
                CreateLabSampleCommand(
                    operationID: UUID(),
                    sampleID: fixture.sampleID,
                    timestamp: timestamp,
                    newDefinitions: index == 0
                        ? [
                            LabItemDefinitionInput(
                                id: definitionID,
                                displayName: "雌二醇",
                                code: "E2"
                            ),
                            LabItemDefinitionInput(
                                id: testosteroneDefinitionID,
                                displayName: "睾酮",
                                code: "T"
                            )
                        ]
                        : [],
                    results: [
                        LabResultInput(
                            id: fixture.resultID,
                            itemDefinitionID: definitionID,
                            rawValueOriginal: fixture.rawValue,
                            unitOriginal: fixture.unit,
                            assayOrVariantOriginal: "方法 A"
                        )
                    ] + (
                        index == fixtures.count - 1
                            ? [
                                LabResultInput(
                                    id: UUID(
                                        uuidString:
                                            "89000000-0000-0000-0000-000000000204"
                                    )!,
                                    itemDefinitionID:
                                        testosteroneDefinitionID,
                                    rawValueOriginal: "0.46",
                                    unitOriginal: "ng/mL",
                                    assayOrVariantOriginal: "方法 A"
                                )
                            ]
                            : []
                    ),
                    committedAt: fixture.instant
                )
            )
        }
    }
}
#endif
