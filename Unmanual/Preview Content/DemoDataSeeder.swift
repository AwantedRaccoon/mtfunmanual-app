#if DEBUG
import Foundation
import SwiftData

@MainActor
enum DemoDataSeeder {
    static func seedIfRequested(container: ModelContainer) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-unmanual-demo-home") else {
            return
        }

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
}
#endif
