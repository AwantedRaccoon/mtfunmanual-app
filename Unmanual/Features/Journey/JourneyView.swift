import SwiftUI

@MainActor
struct JourneyView: View {
    @State private var presentedSheet: JourneySheet?
    @State private var refreshToken = 0

    var body: some View {
        JourneyRouteBookView(refreshToken: refreshToken, recordAction: presentRecordEditor)
            .sheet(item: $presentedSheet, onDismiss: refreshAfterDismiss) { destination in
                switch destination {
                case .quickRecord:
                    QuickRecordEditor()
                }
            }
    }

    private func presentRecordEditor() {
        presentedSheet = .quickRecord
    }

    private func refreshAfterDismiss() {
        refreshToken &+= 1
    }
}

private enum JourneySheet: String, Identifiable {
    case quickRecord

    var id: String { rawValue }
}

struct JourneyPageRecordAction: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        actionCopy
                        actionLabel
                    }
                } else {
                    HStack(spacing: 12) {
                        actionCopy
                        Spacer(minLength: 10)
                        actionLabel
                    }
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, dynamicTypeSize.isAccessibilitySize ? 14 : 5)
            .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 12 : 5)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(theme.paper)
            .contentShape(Rectangle())
        }
        .buttonStyle(V25PressStyle())
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.mustard).frame(height: 4)
        }
        .accessibilityLabel("记录旅程")
        .accessibilityHint("打开新的旅程记录")
        .accessibilityIdentifier("journey.record")
    }

    private var actionCopy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("NEW ENTRY")
                .font(theme.utility(9))
                .tracking(0.8)
                .foregroundStyle(theme.vermilionText)
            Text("想留下什么时再记")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var actionLabel: some View {
        Label("记录旅程", systemImage: "plus")
            .font(.body.weight(.black))
            .foregroundStyle(theme.paper)
            .padding(.horizontal, 14)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 46)
            .background(theme.indigoDeep)
    }
}
