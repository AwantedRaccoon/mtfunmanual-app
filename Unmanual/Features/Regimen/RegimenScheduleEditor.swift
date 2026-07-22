import SwiftUI

extension RegimenScheduleInput {
    var editorSummary: String {
        let timing: String = switch kind {
        case .dailyTimes:
            "每天"
        case .weekly:
            weekdays.split(separator: ",").compactMap { value in
                guard let number = Int(value) else { return nil }
                return RegimenScheduleEditor.weekdayLabel(number)
            }.joined(separator: "、")
        case .everyNDays:
            "每 \(intervalDays ?? 1) 天"
        case .oneOff:
            "仅生效日一次"
        }
        return timing + " · " + localTimes.replacingOccurrences(of: ",", with: "、")
    }
}

@MainActor
struct RegimenScheduleEditor: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let medicationName: String
    let initialSchedule: RegimenScheduleInput?
    let cancel: () -> Void
    let remove: (() -> Void)?
    let save: (RegimenScheduleInput) -> Void

    @State private var kind: ScheduleRuleKind
    @State private var localTimes: String
    @State private var weekdays: Set<Int>
    @State private var intervalDays: Int
    @State private var timeZoneBehavior: ScheduleTimeZoneBehavior
    @State private var fixedTimeZoneIdentifier: String
    @State private var errorMessage: String?

    private let scheduleID: UUID

    init(
        medicationName: String,
        initialSchedule: RegimenScheduleInput?,
        cancel: @escaping () -> Void,
        remove: (() -> Void)?,
        save: @escaping (RegimenScheduleInput) -> Void
    ) {
        let seed = initialSchedule ?? RegimenScheduleInput(
            kind: .dailyTimes,
            localTimes: "08:00"
        )
        self.medicationName = medicationName
        self.initialSchedule = initialSchedule
        self.cancel = cancel
        self.remove = remove
        self.save = save
        scheduleID = seed.id
        _kind = State(initialValue: seed.kind)
        _localTimes = State(initialValue: seed.localTimes)
        _weekdays = State(initialValue: Set(
            seed.weekdays.split(separator: ",").compactMap { Int($0) }
        ))
        _intervalDays = State(initialValue: seed.intervalDays ?? 2)
        _timeZoneBehavior = State(initialValue: seed.timeZoneBehavior)
        _fixedTimeZoneIdentifier = State(
            initialValue: seed.fixedTimeZoneIdentifier
                ?? TimeZone.autoupdatingCurrent.identifier
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    kindSection
                    timeSection
                    if kind == .weekly { weekdaySection }
                    if kind == .everyNDays { intervalSection }
                    timeZoneSection
                    scopeNote
                    if let remove { removeButton(remove) }
                }
                .padding(.horizontal, V25Theme.pagePadding)
                .padding(.vertical, 20)
                .frame(maxWidth: V25Theme.contentWidth)
                .frame(maxWidth: .infinity)
            }
            .background(theme.rice.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(theme.indigo)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("取消", action: cancel)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                Spacer()
                Text("LOCAL / SCHEDULE")
                    .font(theme.utility(10))
                    .tracking(0.8)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.indigo).frame(height: 1)
            }

            Text("执行时间")
                .font(theme.display(dynamicTypeSize.isAccessibilitySize ? 26 : 34))
                .foregroundStyle(theme.indigoDeep)
            Text(medicationName)
                .font(.headline.weight(.black))
                .foregroundStyle(theme.vermilion)
            Text("这里只描述你的计划，不判断剂量或是否适合。提醒会在今天页面单独开启。")
                .font(.subheadline)
                .foregroundStyle(theme.indigo.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var kindSection: some View {
        editorSection(title: "重复方式", detail: "从方案生效日开始") {
            Picker("重复方式", selection: $kind) {
                ForEach(ScheduleRuleKind.allCases, id: \.self) { value in
                    Text(Self.kindLabel(value)).tag(value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .accessibilityLabel("重复方式")
            .accessibilityIdentifier("regimen.schedule.kind")
        }
    }

    private var timeSection: some View {
        editorSection(
            title: kind == .oneOff ? "执行时间" : "每天的时间",
            detail: kind == .oneOff ? "只能填写一个" : "多个时间用逗号分开"
        ) {
            TextField("例如 08:00 或 08:00,20:30", text: $localTimes)
                .textInputAutocapitalization(.never)
                .keyboardType(.numbersAndPunctuation)
                .padding(.horizontal, 12)
                .frame(minHeight: 52)
                .background(theme.paper)
                .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
                .accessibilityLabel("执行时间")
                .accessibilityIdentifier("regimen.schedule.times")
        }
    }

    private var weekdaySection: some View {
        editorSection(title: "星期", detail: "ISO 周序：周一到周日") {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                spacing: 8
            ) {
                ForEach(1...7, id: \.self) { weekday in
                    Button {
                        if weekdays.contains(weekday) {
                            weekdays.remove(weekday)
                        } else {
                            weekdays.insert(weekday)
                        }
                    } label: {
                        Text(Self.weekdayLabel(weekday))
                            .font(.subheadline.weight(.black))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(
                                weekdays.contains(weekday) ? theme.paper : theme.indigoDeep
                            )
                            .background(
                                weekdays.contains(weekday) ? theme.indigo : theme.paper
                            )
                            .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
                    }
                    .buttonStyle(V25PressStyle())
                    .accessibilityValue(weekdays.contains(weekday) ? "已选择" : "未选择")
                }
            }
        }
    }

    private var intervalSection: some View {
        editorSection(title: "间隔天数", detail: "以方案生效日为第 0 天") {
            Stepper(value: $intervalDays, in: 1...365) {
                Text("每 \(intervalDays) 天")
                    .font(.headline.weight(.black))
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("regimen.schedule.interval")
        }
    }

    private var timeZoneSection: some View {
        editorSection(title: "跨时区", detail: "未来计划如何解释当地时间") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("跨时区方式", selection: $timeZoneBehavior) {
                    Text("跟随所在地").tag(ScheduleTimeZoneBehavior.floatingLocal)
                    Text("固定当前时区").tag(ScheduleTimeZoneBehavior.fixedZone)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("regimen.schedule.timeZoneBehavior")

                Text(
                    timeZoneBehavior == .floatingLocal
                        ? "旅行后，未来时间会按新的所在地解释。"
                        : "固定为 \(fixedTimeZoneIdentifier)。"
                )
                .font(.caption)
                .foregroundStyle(theme.indigo.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var scopeNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kind == .oneOff ? "一次计划发生在方案生效日。" : "结束时间跟随这版方案的有效期。")
                .font(.subheadline.weight(.semibold))
            Text("保存计划不会自动请求通知权限，也不会生成“已使用”记录。")
                .font(.caption)
                .foregroundStyle(theme.indigo.opacity(0.68))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.mustard.opacity(0.16))
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1) }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button("移除这项执行时间", role: .destructive, action: action)
            .font(.body.weight(.bold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .overlay { Rectangle().stroke(theme.vermilion, lineWidth: 1.5) }
            .accessibilityIdentifier("regimen.schedule.remove")
    }

    private var saveBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.vermilion)
                    .accessibilityIdentifier("regimen.schedule.error")
            }
            Button("保存执行时间", action: commit)
                .buttonStyle(V25PrimaryButtonStyle())
                .accessibilityIdentifier("regimen.schedule.save")
        }
        .padding(.horizontal, V25Theme.pagePadding)
        .padding(.vertical, 10)
        .background(theme.rice)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.indigo).frame(height: 1)
        }
    }

    private func editorSection<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline.weight(.black))
                Spacer()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(theme.indigo.opacity(0.6))
            }
            content()
        }
    }

    private func commit() {
        let input = RegimenScheduleInput(
            id: scheduleID,
            kind: kind,
            localTimes: localTimes,
            weekdays: kind == .weekly
                ? weekdays.sorted().map(String.init).joined(separator: ",")
                : "",
            intervalDays: kind == .everyNDays ? intervalDays : nil,
            timeZoneBehavior: timeZoneBehavior,
            fixedTimeZoneIdentifier: timeZoneBehavior == .fixedZone
                ? fixedTimeZoneIdentifier
                : nil,
            reminderEnabled: false,
            defaultSnoozeMinutes: initialSchedule?.defaultSnoozeMinutes ?? 10
        )
        guard let normalized = ScheduleRuleInputNormalizer.normalize(input) else {
            errorMessage = "请检查时间、星期和间隔；时间使用 24 小时制，例如 08:00。"
            return
        }
        save(normalized)
    }

    nonisolated fileprivate static func weekdayLabel(_ value: Int) -> String {
        switch value {
        case 1: "周一"
        case 2: "周二"
        case 3: "周三"
        case 4: "周四"
        case 5: "周五"
        case 6: "周六"
        case 7: "周日"
        default: ""
        }
    }

    private static func kindLabel(_ value: ScheduleRuleKind) -> String {
        switch value {
        case .dailyTimes: "每天"
        case .weekly: "每周指定日期"
        case .everyNDays: "每隔几天"
        case .oneOff: "仅一次"
        }
    }
}
