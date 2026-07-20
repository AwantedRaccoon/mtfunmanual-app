import SwiftUI

@MainActor
struct AppShellView: View {
    @Environment(AppTheme.self) private var theme
    @State private var selectedTab: AppTab = .today

    var body: some View {
        Group {
            switch selectedTab {
            case .today:
                NavigationStack {
                    TodayView(selectedTab: $selectedTab)
                }
            case .journey:
                NavigationStack {
                    JourneyView()
                }
            case .regimen:
                NavigationStack {
                    RegimenView()
                }
            case .archive:
                NavigationStack {
                    ArchiveView()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            V25TabBar(selection: $selectedTab)
        }
    }
}

@MainActor
private struct V25TabBar: View {
    @Environment(AppTheme.self) private var theme
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 15, weight: .bold))
                        Text(tab.title)
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(selection == tab ? theme.paper : theme.indigo)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .background(selection == tab ? theme.indigo : theme.paper)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(selection == tab ? theme.mustard : Color.clear)
                            .frame(height: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(V25PressStyle())
                .accessibilityLabel(tab.title)
                .accessibilityValue(selection == tab ? "已选择" : "")
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
        }
        .background(theme.paper)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.indigo).frame(height: 1)
        }
        .background(theme.paper.ignoresSafeArea(edges: .bottom))
    }
}
