import SwiftData
import SwiftUI

@MainActor
enum PreviewFixtures {
    static func emptyModelContainer() -> ModelContainer {
        let schema = Schema([
            HRTProfile.self,
            CountdownRecord.self,
            RegimenVersion.self,
            JourneyEntry.self,
            LabRecord.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [configuration])
    }

    static func modelContainer(hrtDay: Int = 238) -> ModelContainer {
        let schema = Schema([
            HRTProfile.self,
            CountdownRecord.self,
            RegimenVersion.self,
            JourneyEntry.self,
            LabRecord.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let calendar = Calendar(identifier: .gregorian)
        let startDate = calendar.date(byAdding: .day, value: 1 - max(1, hrtDay), to: Date()) ?? Date()
        let targetDate = calendar.date(byAdding: .day, value: 18, to: Date()) ?? Date()
        let regimen = RegimenVersion(code: "R-02", title: "当前方案", startedAt: startDate, note: "按自己的原始记录保存")

        context.insert(HRTProfile(startDate: startDate))
        context.insert(CountdownRecord(title: "下一次复诊", gentleTitle: "私人日期", targetDate: targetDate))
        context.insert(regimen)
        let entryPlan: [(Int, JourneyEntryKind, String)] = [
            (-6, .moment, "把开始这段旅程的日期记了下来。"),
            (-4, .feeling, "今天的精力比前两天稳定一些。"),
            (-4, .change, "记下了一个想继续观察的小变化。"),
            (-2, .moment, "第一次更自在地穿喜欢的衣服出门。"),
            (0, .question, "今天想起一件下次要问的问题。")
        ]

        for (offset, kind, text) in entryPlan {
            let occurredAt = calendar.date(byAdding: .day, value: offset, to: Date()) ?? Date()
            context.insert(
                JourneyEntry(
                    text: text,
                    kind: kind,
                    occurredAt: occurredAt,
                    regimenVersionID: regimen.id
                )
            )
        }

        let labPlan: [(Int, String, String, String, Double, String)] = [
            (-120, "雌二醇", "E2", "146", 146, "pg/mL"),
            (-60, "雌二醇", "E2", "165", 165, "pg/mL"),
            (-6, "雌二醇", "E2", "172", 172, "pg/mL"),
            (-120, "睾酮", "T", "0.72", 0.72, "ng/mL"),
            (-60, "睾酮", "T", "0.58", 0.58, "ng/mL"),
            (-6, "睾酮", "T", "0.46", 0.46, "ng/mL")
        ]

        for (offset, name, code, rawValue, numericValue, unit) in labPlan {
            let sampledAt = calendar.date(byAdding: .day, value: offset, to: Date()) ?? Date()
            context.insert(
                LabRecord(
                    itemName: name,
                    itemCode: code,
                    rawValue: rawValue,
                    numericValue: numericValue,
                    unit: unit,
                    sampledAt: sampledAt,
                    regimenVersionID: regimen.id
                )
            )
        }
        try? context.save()

        return container
    }
}

#Preview("今天 · 已设置") {
    AppShellView()
        .environment(AppTheme())
        .modelContainer(PreviewFixtures.modelContainer())
}

#Preview("今天 · 空数据") {
    AppShellView()
        .environment(AppTheme())
        .modelContainer(PreviewFixtures.emptyModelContainer())
}

#Preview("今天 · V2.5") {
    NavigationStack {
        TodayView(selectedTab: .constant(.today))
    }
    .environment(AppTheme())
    .modelContainer(PreviewFixtures.modelContainer())
}

#Preview("今天 · V2.5 · 四位日数") {
    NavigationStack {
        TodayView(selectedTab: .constant(.today))
    }
    .environment(AppTheme())
    .modelContainer(PreviewFixtures.modelContainer(hrtDay: 1_428))
}
