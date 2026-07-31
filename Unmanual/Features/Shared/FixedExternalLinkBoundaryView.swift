import SwiftUI

enum FixedExternalLinkFreshness: Equatable, Hashable, Sendable {
    case current
    case needsReverification
}

struct FixedExternalLinkTarget:
    Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let institution: String
    let boundary: String
    let urlString: String
    let freshness: FixedExternalLinkFreshness
    let applicableRegions: [String]
    let applicablePopulations: [String]

    var url: URL? { URL(string: urlString) }
    var domain: String { url?.host ?? "未知域名" }
}

struct FixedExternalLinkBoundaryView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let target: FixedExternalLinkTarget

    var body: some View {
        NavigationStack {
            V25Page {
                VStack(alignment: .leading, spacing: 0) {
                    V25PageHeader(
                        register: "SOURCE / BOUNDARY",
                        title: "将离开 App",
                        subtitle: "先核对目标域名和数据边界。",
                        status: target.domain
                    )

                    if target.freshness
                        == .needsReverification {
                        statusNotice
                    }

                    V25SectionHeader(
                        title: target.institution,
                        detail: "固定来源入口"
                    )
                    Text(target.title)
                        .font(
                            theme.display(
                                26,
                                relativeTo: .title2
                            )
                        )
                        .foregroundStyle(theme.indigoDeep)
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                    Text(target.boundary)
                        .font(.body)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                        .padding(.top, 12)

                    if !target.applicablePopulations.isEmpty
                        || !target.applicableRegions.isEmpty {
                        applicabilityLedger
                    }

                    VStack(
                        alignment: .leading,
                        spacing: 7
                    ) {
                        Text("目标域名")
                            .font(.caption.weight(.black))
                            .foregroundStyle(
                                theme.vermilionText
                            )
                        Text(target.domain)
                            .font(.headline.monospaced())
                        Text(
                            "这个固定 URL 不包含搜索词、content ID、收藏、药品、方案、化验、记录、用户或设备信息。系统浏览器可能留下网络记录；离开 App 后的活动不再受 App Lock 控制。"
                        )
                        .font(.caption)
                        .foregroundStyle(
                            theme.secondaryText
                        )
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                    }
                    .foregroundStyle(theme.indigoDeep)
                    .padding(12)
                    .background(theme.paper)
                    .overlay {
                        Rectangle().stroke(
                            theme.indigo,
                            lineWidth: 1.5
                        )
                    }
                    .padding(.top, 16)

                    Button("在系统浏览器中打开") {
                        guard let url = target.url else {
                            return
                        }
                        openURL(url)
                    }
                    .buttonStyle(V25PrimaryButtonStyle())
                    .disabled(target.url == nil)
                    .padding(.top, 16)
                    .accessibilityIdentifier(
                        "externalBoundary.open"
                    )
                }
            }
            .toolbar {
                ToolbarItem(
                    placement: .cancellationAction
                ) {
                    Button("取消") { dismiss() }
                        .frame(
                            minWidth: 44,
                            minHeight: 44
                        )
                        .accessibilityIdentifier(
                            "externalBoundary.cancel"
                        )
                }
            }
        }
        .accessibilityIdentifier(
            "externalBoundary.sheet"
        )
    }

    private var statusNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(theme.mustard)
                .frame(width: 5)
            VStack(alignment: .leading, spacing: 4) {
                Text("该来源需要重新核验")
                    .font(.headline.weight(.black))
                Text(
                    "缓存的书目信息仍可查看；打开前请留意来源日期和适用边界。"
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
            }
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(12)
        .background(theme.paper)
        .overlay {
            Rectangle().stroke(
                theme.mustard,
                lineWidth: 2
            )
        }
        .padding(.top, 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            "externalBoundary.needsReverification"
        )
    }

    private var applicabilityLedger: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("适用人群与地区")
                .font(.caption.weight(.black))
                .foregroundStyle(theme.vermilionText)
            if !target.applicablePopulations.isEmpty {
                Text(
                    target.applicablePopulations
                        .joined(separator: "、")
                )
                .font(.body)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
            }
            if !target.applicableRegions.isEmpty {
                Text(
                    target.applicableRegions
                        .joined(separator: "、")
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
            }
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(12)
        .background(theme.paper)
        .overlay {
            Rectangle().stroke(
                theme.indigo,
                lineWidth: 1
            )
        }
        .padding(.top, 16)
    }
}
