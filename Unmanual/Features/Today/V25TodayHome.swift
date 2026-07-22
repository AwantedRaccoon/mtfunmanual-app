import Foundation
import SwiftUI

/// V2.5 首页：品牌配色 + 时间刻度上半部 + 紧凑个人台账下半部。
@MainActor
struct V25TodayHome: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let profile: HRTProfileSnapshot?
    let countdown: CountdownRecordSnapshot?
    let regimens: [CoreRegimenVersionSnapshot]
    let records: [LabRecordSnapshot]
    let entries: [JourneyEntrySnapshot]
    let quickRecordAction: () -> Void
    let startDateAction: () -> Void
    let countdownAction: () -> Void
    let regimenAction: () -> Void
    let metricsAction: () -> Void
    let journeyAction: () -> Void

    private var hrtDay: Int? {
        profile.map { DateFacts.hrtDay(startDate: $0.startDate) }
    }

    private var activeRegimen: CoreRegimenVersionSnapshot? {
        regimens.first(where: { regimen in
            guard regimen.editState == .sealed, !regimen.requiresReview,
                  let today = try? HistoricalTimestamp.captured(
                    instant: Date(),
                    timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
                  ).localDate else { return false }
            return regimen.effectiveStartDate <= today
                && (regimen.effectiveEndDate.map { today < $0 } ?? true)
        })
    }

    private var latestEntry: JourneyEntrySnapshot? {
        entries.max { $0.occurredAt < $1.occurredAt }
    }

    private var latestLabRecords: [LabRecordSnapshot] {
        guard let latest = records.max(by: { $0.sampledAt < $1.sampledAt }),
              let latestLocalDate = latest.recordedLocalDate() else { return [] }
        let sameDayRecords = records.filter {
            $0.recordedLocalDate() == latestLocalDate
        }
        return MetricReportFacts.orderedItemCodes(from: sameDayRecords).compactMap { itemCode in
            sameDayRecords
                .filter { $0.itemCode == itemCode }
                .max { $0.sampledAt < $1.sampledAt }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if dynamicTypeSize.isAccessibilitySize {
                accessibleNow
            } else {
                dayRuler
            }

            context
            latestTrace
            privacyFooter
        }
        .foregroundStyle(theme.indigoDeep)
    }

    @ViewBuilder
    private var header: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text("LOCAL / TODAY")
                    .font(.caption.weight(.bold))
                Label(SystemBackupDisclosure.statusLabel, systemImage: "lock.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.indigo.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("today.backupStatus")
                    .accessibilityLabel(SystemBackupDisclosure.statusLabel)
                Text(todayDayText)
                    .font(.title2.weight(.black))
                Text(todayMonthAndWeekdayText)
                    .font(.body.weight(.medium))
                    .foregroundStyle(theme.indigo.opacity(0.66))
            }
            .padding(.top, 6)
            .padding(.bottom, 12)
        } else {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(todayDayText)
                        .font(.system(size: 40, weight: .black, design: .rounded))
                        .tracking(-1.5)
                    Text(todayMonthAndWeekdayText)
                        .font(theme.utility(11))
                        .tracking(1.1)
                        .foregroundStyle(theme.indigo.opacity(0.66))
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 5) {
                    Text("LOCAL / TODAY")
                        .font(theme.utility(11))
                        .tracking(1)
                    Label(SystemBackupDisclosure.statusLabel, systemImage: "lock.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(theme.indigo.opacity(0.66))
                        .accessibilityIdentifier("today.backupStatus")
                }
                .padding(.top, 7)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(SystemBackupDisclosure.todayAccessibility)
            }
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var dayRuler: some View {
        if let hrtDay {
            VStack(spacing: 0) {
                rulerHeading
                neighborDay(max(1, hrtDay - 2), opacity: 0.16)
                neighborDay(max(1, hrtDay - 1), opacity: 0.38)
                currentDay(hrtDay)
                neighborDay(hrtDay + 1, opacity: 0.38)
                neighborDay(hrtDay + 2, opacity: 0.16)
                startDateLine
            }
            .accessibilityElement(children: .contain)
        } else {
            setupStartDate
        }
    }

    private var rulerHeading: some View {
        HStack(alignment: .lastTextBaseline) {
            Text("HRT 日数刻度")
                .font(.headline.weight(.black))
            Spacer()
            Text("过去 / 此刻 / 接下来")
                .font(theme.utility(10))
                .foregroundStyle(theme.indigo.opacity(0.62))
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo).frame(height: 2)
        }
    }

    private func neighborDay(_ day: Int, opacity: Double) -> some View {
        HStack(spacing: 0) {
            Text("DAY")
                .font(theme.utility(9))
                .tracking(1.2)
                .frame(width: 54, alignment: .leading)
            Text(verbatim: String(day))
                .font(.system(size: 31, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(width: 126, alignment: .trailing)
                .padding(.leading, V25Theme.dayValueLeadingInset)
            Spacer()
        }
        .foregroundStyle(theme.indigo.opacity(opacity))
        .frame(height: 42)
        .accessibilityHidden(true)
    }

    private func currentDay(_ day: Int) -> some View {
        ZStack {
            Rectangle()
                .fill(theme.vermilion)
                .frame(height: 3)
                .accessibilityHidden(true)

            HStack(spacing: 0) {
                Text("此刻")
                    .font(theme.utility(12))
                    .foregroundStyle(theme.paper)
                    .frame(width: 54, height: 34)
                    .background(theme.indigo)

                Button(action: startDateAction) {
                    Text(verbatim: String(day))
                        .font(.system(size: 64, weight: .black, design: .rounded))
                        .tracking(-3)
                        .monospacedDigit()
                        .foregroundStyle(theme.indigoDeep)
                        .frame(width: 126, alignment: .trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.leading, V25Theme.dayValueLeadingInset)
                        .contentShape(Rectangle())
                }
                .buttonStyle(V25PressStyle())
                .accessibilityLabel("HRT 第 \(day) 天")
                .accessibilityHint("点按修改开始日")
                .accessibilityIdentifier("today.v25.editStartDate")

                Spacer(minLength: 10)

                Button(action: quickRecordAction) {
                    VStack(alignment: .leading, spacing: 2) {
                        Image(systemName: "plus")
                            .font(.headline.weight(.black))
                        Text(hasEntryToday ? "再记一条" : "记录此刻")
                            .font(.caption.weight(.black))
                            .lineLimit(1)
                    }
                    .foregroundStyle(theme.paper)
                    .padding(.horizontal, 13)
                    .frame(minWidth: 86, minHeight: 62, alignment: .leading)
                    .background(theme.indigo)
                    .contentShape(Rectangle())
                }
                .buttonStyle(V25PressStyle())
                .accessibilityIdentifier("today.v25.quickRecord")
            }
        }
        .frame(height: 86)
    }

    private var startDateLine: some View {
        Button(action: startDateAction) {
            HStack {
                Text("从这里开始")
                    .font(.caption.weight(.bold))
                Spacer()
                Text(profile?.startDate.unmanualShortDateText ?? "设置开始日")
                    .font(theme.utility(11))
                    .monospacedDigit()
            }
            .foregroundStyle(theme.indigo.opacity(0.66))
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(V25PressStyle())
    }

    private var setupStartDate: some View {
        Button(action: startDateAction) {
            VStack(alignment: .leading, spacing: 14) {
                Text("HRT 日数刻度")
                    .font(.caption.weight(.black))
                Text("先标记你的开始日")
                    .font(theme.display(34, relativeTo: .largeTitle))
                Label("设置开始日", systemImage: "arrow.right")
                    .font(.headline.weight(.black))
            }
            .foregroundStyle(theme.paper)
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .leading)
            .background(theme.indigo)
            .contentShape(Rectangle())
        }
        .buttonStyle(V25PressStyle())
        .accessibilityIdentifier("today.v25.addStartDate")
    }

    private var accessibleNow: some View {
        VStack(spacing: 12) {
            Button(action: startDateAction) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("此刻")
                        .font(.caption.weight(.black))
                    Text(hrtDay.map { "HRT 第 \($0) 天" } ?? "设置 HRT 开始日")
                        .font(.largeTitle.weight(.black))
                    Text(profile?.startDate.unmanualShortDateText ?? "尚未设置")
                        .font(.body.monospacedDigit())
                }
                .foregroundStyle(theme.indigoDeep)
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 154, alignment: .leading)
                .background(theme.blue.opacity(0.26))
                .overlay { Rectangle().stroke(theme.indigo, lineWidth: 2) }
                .contentShape(Rectangle())
            }
            .buttonStyle(V25PressStyle())

            Button(action: quickRecordAction) {
                Label(hasEntryToday ? "再记一条" : "记录此刻", systemImage: "plus")
                    .font(.title3.weight(.black))
                    .foregroundStyle(theme.paper)
                    .padding(18)
                    .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                    .background(theme.indigo)
                    .contentShape(Rectangle())
            }
            .buttonStyle(V25PressStyle())
            .accessibilityIdentifier("today.v25.quickRecord")
        }
        .padding(.bottom, 16)
    }

    private var context: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    countdownContext
                    regimenContext
                    labContext
                }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        countdownContext
                        regimenContext
                    }
                    labContext
                }
            }
        }
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 2) }
    }

    private var countdownContext: some View {
        V25ContextItem(
            label: "下一件事",
            value: countdownValue,
            detail: countdown?.title ?? "添加目标日",
            metadata: countdown?.targetDate.unmanualShortDateText ?? "尚未设置",
            background: theme.blue.opacity(0.28),
            labelColor: theme.indigoDeep,
            accessibilityIdentifier: "today.v25.countdown",
            action: countdownAction
        )
    }

    private var regimenContext: some View {
        V25ContextItem(
            label: "当前方案",
            value: activeRegimen?.code ?? "未建立",
            detail: activeRegimen?.title ?? "建立当前方案",
            metadata: activeRegimen.map { "\($0.effectiveStartDate.iso8601) 起" } ?? "",
            background: theme.paper,
            labelColor: theme.vermilion,
            accessibilityIdentifier: "today.v25.regimen",
            action: regimenAction
        )
    }

    private var labContext: some View {
        V25ContextItem(
            label: "最近化验",
            value: labValue,
            detail: latestLabRecords.first?.recordedShortDateText ?? "尚无记录",
            metadata: "查看完整原始记录",
            background: theme.paper,
            labelColor: theme.vermilion,
            accessibilityIdentifier: "today.v25.metrics",
            action: metricsAction
        )
    }

    private var latestTrace: some View {
        Button(action: journeyAction) {
            VStack(alignment: .leading, spacing: dynamicTypeSize.isAccessibilitySize ? 10 : 7) {
                HStack {
                    Text(hasEntryToday ? "今天留下了" : "最近留下了")
                        .font(.caption.weight(.black))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.black))
                        .accessibilityHidden(true)
                }
                Text(latestEntry?.text ?? "还没有记录。想留下什么时，再从今天开始。")
                    .font(theme.display(dynamicTypeSize.isAccessibilitySize ? 22 : 20, relativeTo: .title3))
                    .multilineTextAlignment(.leading)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 6 : 2)
                Text(latestEntry.map { "\($0.kind.title) · \($0.recordedShortDateText)" } ?? "随时可以开始")
                    .font(theme.utility(11))
                    .foregroundStyle(theme.paper.opacity(0.64))
            }
            .foregroundStyle(theme.paper)
            .padding(dynamicTypeSize.isAccessibilitySize ? 18 : 12)
            .frame(
                maxWidth: .infinity,
                minHeight: dynamicTypeSize.isAccessibilitySize ? 142 : 98,
                alignment: .topLeading
            )
            .background(theme.indigoDeep)
            .overlay { Rectangle().stroke(theme.indigo, lineWidth: 2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(V25PressStyle())
        .accessibilityIdentifier("today.v25.latestEntry")
    }

    private var privacyFooter: some View {
        Text("LOCAL FIRST  ·  \(SystemBackupDisclosure.compact)")
            .font(dynamicTypeSize.isAccessibilitySize ? .caption.weight(.bold) : theme.utility(10))
            .tracking(dynamicTypeSize.isAccessibilitySize ? 0 : 0.8)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("today.backupDisclosure")
            .foregroundStyle(theme.indigo.opacity(0.62))
            .frame(maxWidth: .infinity)
            .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 18 : 8)
    }

    private var hasEntryToday: Bool {
        guard let today = try? HistoricalTimestamp.captured(
            instant: Date(),
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
        ).localDate else {
            return false
        }
        return entries.contains { $0.recordedLocalDate() == today }
    }

    private var countdownValue: String {
        guard let countdown else { return "未设置" }
        let days = DateFacts.countdownDays(targetDate: countdown.targetDate)
        if days > 0 { return "\(days) 天" }
        if days == 0 { return "今天" }
        return "\(abs(days)) 天前"
    }

    private var labValue: String {
        guard !latestLabRecords.isEmpty else { return "未记录" }
        return latestLabRecords.prefix(2).map { "\($0.itemCode) \($0.rawValue)" }.joined(separator: " · ")
    }

    private var todayDayText: String {
        Date.now.formatted(.dateTime.locale(Locale(identifier: "zh-Hans")).day(.twoDigits))
    }

    private var todayMonthAndWeekdayText: String {
        Date.now.formatted(.dateTime.locale(Locale(identifier: "zh-Hans")).month(.wide).weekday(.wide))
    }
}

@MainActor
private struct V25ContextItem: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let label: String
    let value: String
    let detail: String
    let metadata: String
    let background: Color
    let labelColor: Color
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: dynamicTypeSize.isAccessibilitySize ? 4 : 2) {
                Text(label)
                    .font(dynamicTypeSize.isAccessibilitySize ? .caption.weight(.black) : .caption2.weight(.black))
                    .foregroundStyle(labelColor)
                Text(value)
                    .font(theme.display(dynamicTypeSize.isAccessibilitySize ? 24 : 21, relativeTo: .title3))
                    .monospacedDigit()
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .minimumScaleFactor(0.72)
                if dynamicTypeSize.isAccessibilitySize {
                    Text(detail)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if !metadata.isEmpty {
                        Text(metadata)
                            .font(theme.utility(10))
                            .foregroundStyle(theme.indigo.opacity(0.62))
                            .lineLimit(3)
                    }
                } else {
                    Text(metadata.isEmpty ? detail : "\(detail) · \(metadata)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.indigo.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }
            .foregroundStyle(theme.indigoDeep)
            .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 14 : 12)
            .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 14 : 9)
            .frame(
                maxWidth: .infinity,
                minHeight: dynamicTypeSize.isAccessibilitySize ? 128 : 92,
                alignment: .topLeading
            )
            .background(background)
            .overlay(alignment: .trailing) {
                Rectangle().fill(theme.indigo).frame(width: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.indigo).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(V25PressStyle())
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
