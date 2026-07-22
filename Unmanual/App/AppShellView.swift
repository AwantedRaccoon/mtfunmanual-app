import SwiftUI

enum AppTabBarLayout: Equatable {
    case singleRow
    case twoColumnGrid

    static func mode(for dynamicTypeSize: DynamicTypeSize) -> AppTabBarLayout {
        dynamicTypeSize.isAccessibilitySize ? .twoColumnGrid : .singleRow
    }
}

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
        .onReceive(NotificationCenter.default.publisher(for: .unmanualOpenToday)) { _ in
            selectedTab = .today
        }
        .accessibilityIdentifier("app.shell")
    }
}

@MainActor
private struct V25TabBar: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selection: AppTab

    private let accessibilityRows: [[AppTab]] = [
        [.today, .journey],
        [.regimen, .archive]
    ]

    var body: some View {
        Group {
            if AppTabBarLayout.mode(for: dynamicTypeSize) == .twoColumnGrid {
                VStack(spacing: 0) {
                    ForEach(accessibilityRows.indices, id: \.self) { rowIndex in
                        HStack(spacing: 0) {
                            ForEach(accessibilityRows[rowIndex]) { tab in
                                tabButton(tab, layout: .twoColumnGrid)
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(AppTab.allCases) { tab in
                        tabButton(tab, layout: .singleRow)
                    }
                }
            }
        }
        .dynamicTypeSize(...V25Theme.tabBarMaximumDynamicTypeSize)
        .padding(
            .bottom,
            dynamicTypeSize.isAccessibilitySize
                ? V25Theme.accessibilityTabBarBottomPadding
                : 0
        )
        .background(theme.paper)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.indigo).frame(height: 1)
        }
        .background(theme.paper.ignoresSafeArea(edges: .bottom))
    }

    private func tabButton(
        _ tab: AppTab,
        layout: AppTabBarLayout
    ) -> some View {
        Button {
            selection = tab
        } label: {
            Group {
                if layout == .twoColumnGrid {
                    VStack(spacing: 6) {
                        Image(systemName: tab.systemImage)
                            .font(.body.weight(.bold))
                        Text(tab.title)
                            .font(.caption.weight(.bold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(
                                .bottom,
                                V25Theme.accessibilityTabLabelBottomPadding
                            )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 76)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 15, weight: .bold))
                        Text(tab.title)
                            .font(.caption2.weight(.bold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 58)
                }
            }
            .foregroundStyle(selection == tab ? theme.paper : theme.indigo)
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
