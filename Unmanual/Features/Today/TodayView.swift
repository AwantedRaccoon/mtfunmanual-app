import SwiftData
import SwiftUI

@MainActor
struct TodayView: View {
    @Query(sort: \HRTProfile.createdAt, order: .forward) private var profiles: [HRTProfile]
    @Query(sort: \CountdownRecord.createdAt, order: .reverse) private var countdowns: [CountdownRecord]
    @Query(sort: \JourneyEntry.occurredAt, order: .reverse) private var entries: [JourneyEntry]
    @Query(sort: \RegimenVersion.startedAt, order: .reverse) private var regimens: [RegimenVersion]
    @Query(sort: \LabRecord.sampledAt, order: .reverse) private var labRecords: [LabRecord]

    @Binding var selectedTab: AppTab
    @State private var presentedSheet: TodaySheet?

    private var profile: HRTProfile? { profiles.first }
    private var countdown: CountdownRecord? { countdowns.first(where: { $0.archivedAt == nil }) }

    var body: some View {
        V25Page {
            V25TodayHome(
                profile: profile,
                countdown: countdown,
                regimens: regimens,
                records: labRecords,
                entries: entries,
                quickRecordAction: { presentedSheet = .quickRecord },
                startDateAction: { presentedSheet = .startDate },
                countdownAction: { presentedSheet = .countdown },
                regimenAction: { selectedTab = .regimen },
                metricsAction: { selectedTab = .journey },
                journeyAction: { selectedTab = .journey }
            )
        }
        .navigationBarHidden(true)
        .sheet(item: $presentedSheet) { destination in
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
}

private enum TodaySheet: String, Identifiable {
    case startDate
    case countdown
    case quickRecord

    var id: String { rawValue }
}
