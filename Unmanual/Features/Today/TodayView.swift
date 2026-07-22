import SwiftUI

@MainActor
struct TodayView: View {
    @Environment(\.appReadActor) private var appReadActor

    @Binding var selectedTab: AppTab
    @State private var presentedSheet: TodaySheet?
    @State private var snapshot = TodaySnapshot.empty
    @State private var coreRegimenOverview = CoreRegimenOverviewSnapshot.empty

    var body: some View {
        V25Page {
            V25TodayHome(
                profile: snapshot.profile,
                countdown: snapshot.countdown,
                regimens: coreRegimenOverview.current.map { [$0] } ?? [],
                records: snapshot.labRecords,
                entries: snapshot.entries,
                quickRecordAction: { presentedSheet = .quickRecord },
                startDateAction: { presentedSheet = .startDate },
                countdownAction: { presentedSheet = .countdown },
                regimenAction: { selectedTab = .regimen },
                metricsAction: { selectedTab = .journey },
                journeyAction: { selectedTab = .journey }
            )
        }
        .navigationBarHidden(true)
        .task { await refresh() }
        .sheet(item: $presentedSheet, onDismiss: refreshAfterDismiss) { destination in
            switch destination {
            case .startDate:
                StartDateEditor()
            case .countdown:
                CountdownEditor()
            case .quickRecord:
                QuickRecordEditor()
            }
        }
    }

    private func refreshAfterDismiss() {
        Task { await refresh() }
    }

    private func refresh() async {
        guard let appReadActor else { return }
        if let updated = try? await appReadActor.todaySnapshot() {
            snapshot = updated
        }
        if let today = try? HistoricalTimestamp.captured(
            instant: Date(),
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
        ).localDate,
        let updated = try? await appReadActor.coreRegimenOverview(asOf: today) {
            coreRegimenOverview = updated
        }
    }
}

private enum TodaySheet: String, Identifiable {
    case startDate
    case countdown
    case quickRecord

    var id: String { rawValue }
}
