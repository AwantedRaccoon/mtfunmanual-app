import Foundation

struct LabSurfaceCopy: Equatable, Sendable {
    let todayLabel: String
    let timelineRecordTitle: String
    let timelineKindLabel: String
    let trendActionTitle: String
    let trendRegister: String
    let trendTitle: String
    let journeySubtitle: String
    let timelineEmptyDetail: String
    let deletedRecordDetail: String
}

enum LabSurfaceDisplayPolicy {
    static func copy(gentleModeEnabled: Bool) -> LabSurfaceCopy {
        if gentleModeEnabled {
            return LabSurfaceCopy(
                todayLabel: "最近检查",
                timelineRecordTitle: "检查记录",
                timelineKindLabel: "RECORD / 检查",
                trendActionTitle: "查看数据变化",
                trendRegister: "RECORD / TREND",
                trendTitle: "数据变化",
                journeySubtitle:
                    "历程、检查、状态、执行、方案与片段，按事实发生的时间放在一起。",
                timelineEmptyDetail:
                    "添加检查、状态或普通记录后，它会按发生时间出现在这里。",
                deletedRecordDetail:
                    "这条检查或状态记录已经从正常视图移除。"
            )
        }
        return LabSurfaceCopy(
            todayLabel: "最近化验",
            timelineRecordTitle: "化验记录",
            timelineKindLabel: "LAB / 化验",
            trendActionTitle: "查看这个项目的变化",
            trendRegister: "LAB / TREND",
            trendTitle: "化验趋势",
            journeySubtitle:
                "历程、化验、状态、执行、方案与片段，按事实发生的时间放在一起。",
            timelineEmptyDetail:
                "添加化验、状态或普通记录后，它会按发生时间出现在这里。",
            deletedRecordDetail:
                "这条化验或状态记录已经从正常视图移除。"
        )
    }
}

enum LabDefinitionIdentityPresentation {
    static func marker(id: UUID) -> String {
        id.uuidString
    }

    static func label(
        id: UUID,
        displayName: String,
        code: String
    ) -> String {
        let base = code.isEmpty
            ? displayName
            : "\(displayName) · \(code)"
        return "\(base) · 识别码 \(marker(id: id))"
    }
}
