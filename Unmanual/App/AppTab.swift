import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case today
    case journey
    case regimen
    case archive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "今天"
        case .journey: "旅程"
        case .regimen: "方案"
        case .archive: "档案"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "calendar.day.timeline.left"
        case .journey: "text.line.first.and.arrowtriangle.forward"
        case .regimen: "doc.text"
        case .archive: "archivebox"
        }
    }
}
