import SwiftUI

@MainActor
struct LabImportEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDataWriter) private var appDataWriter
    @Environment(\.appReadActor) private var appReadActor
    @Environment(AppTheme.self) private var theme

    @State private var regimens: [CoreRegimenVersionSnapshot] = []
    @State private var sampledAt = Date()
    @State private var entries = LedgerHormoneDescriptor.all.map {
        LabImportEntry(itemName: $0.name, itemCode: $0.code, rawValue: "", unit: "")
    }
    @State private var existingRecordsOnSelectedDay = 0
    @State private var saveErrorMessage: String?
    @State private var isSaving = false

    private var associatedRegimen: CoreRegimenVersionSnapshot? {
        guard let localDate = try? HistoricalTimestamp.captured(
            instant: sampledAt,
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
            provenance: .userEntered
        ).localDate else { return nil }
        let timeline = regimens.map {
            RegimenTimelineVersion(
                id: $0.id,
                start: $0.effectiveStartDate,
                end: $0.effectiveEndDate,
                editState: $0.editState,
                requiresReview: $0.requiresReview
            )
        }
        guard let current = RegimenTimelineResolver.project(timeline, asOf: localDate).current else {
            return nil
        }
        return regimens.first { $0.id == current.id }
    }

    private var completedCount: Int {
        entries.filter(\.isComplete).count
    }

    private var hasIncompleteEntry: Bool {
        entries.contains { !$0.isBlank && !$0.isComplete }
    }

    private var canSave: Bool {
        completedCount > 0 && !hasIncompleteEntry
    }

    var body: some View {
        NavigationStack {
            V25EditorPage(
                register: "LOCAL / LAB RECORD",
                eyebrow: "NEW SAMPLE",
                title: "导入检查记录",
                detail: "选择采样日期，填写这次报告中的项目；没有记录的项目可以留空。",
                cancel: dismiss.callAsFunction
            ) {
                V25SectionHeader(
                    title: "采样信息",
                    detail: associatedRegimen.map { "关联 " + $0.code } ?? "未关联方案"
                )

                LabImportDateSlip(sampledAt: $sampledAt, regimen: associatedRegimen)

                if existingRecordsOnSelectedDay > 0 {
                    Text("这一天已有 \(existingRecordsOnSelectedDay) 项记录。本次保存会作为新的采样保留，不会覆盖原记录。")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.indigo)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("labImport.existingSampleNotice")
                }

                V25SectionHeader(
                    title: "性激素六项",
                    detail: "已填写 \(completedCount)/6"
                )

                LabImportLedger(entries: $entries)

                if hasIncompleteEntry {
                    Text("请为已填写的项目补全有效数值和单位。")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.vermilion)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("labImport.validation")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                V25SaveBar(
                    title: "保存 \(completedCount) 项记录",
                    isEnabled: canSave && !isSaving,
                    accessibilityIdentifier: "labImport.save",
                    action: save
                )
            }
        }
        .tint(theme.indigo)
        .task { await loadRegimens() }
        .task(id: Calendar.autoupdatingCurrent.startOfDay(for: sampledAt)) {
            await loadExistingRecordCount()
        }
        .localSaveErrorAlert(message: $saveErrorMessage)
    }

    private func loadRegimens() async {
        guard let today = try? HistoricalTimestamp.captured(
            instant: Date(),
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
        ).localDate,
        let updated = try? await appReadActor?.coreRegimenOverview(asOf: today) else { return }
        regimens = updated.allVersions
    }

    private func loadExistingRecordCount() async {
        guard let appReadActor else { return }
        let fallbackTimeZone = TimeZone.autoupdatingCurrent
        guard let requestedDay = try? HistoricalTimestamp.captured(
            instant: sampledAt,
            timeZoneIdentifier: fallbackTimeZone.identifier
        ).localDate else {
            saveErrorMessage = "暂时无法读取这一天的既有记录，原资料没有被修改。"
            return
        }
        existingRecordsOnSelectedDay = 0
        do {
            let records = try await appReadActor.labRecords(
                on: requestedDay,
                fallbackTimeZone: fallbackTimeZone
            )
            guard let currentSelectedDay = try? HistoricalTimestamp.captured(
                instant: sampledAt,
                timeZoneIdentifier: fallbackTimeZone.identifier
            ).localDate,
            currentSelectedDay == requestedDay else { return }
            existingRecordsOnSelectedDay = records.count
        } catch {
            saveErrorMessage = "暂时无法读取这一天的既有记录，原资料没有被修改。"
        }
    }

    private func save() {
        guard !isSaving else { return }
        guard let appDataWriter else {
            saveErrorMessage = "本地资料尚未准备好，请稍后再试。"
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: sampledAt
        )
        let minutePrecisionSampledAt = calendar.date(from: components) ?? sampledAt
        let command = SaveLabImportCommand(
            entries: entries,
            sampledAt: minutePrecisionSampledAt,
            regimenVersionID: associatedRegimen?.id,
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
            precision: .minute
        )
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                _ = try await appDataWriter.saveLabImport(command)
                dismiss()
            } catch {
                saveErrorMessage = "已填写的内容仍保留在当前页面，请检查后再保存。"
            }
        }
    }
}

private struct LabImportDateSlip: View {
    @Environment(AppTheme.self) private var theme

    @Binding var sampledAt: Date
    let regimen: CoreRegimenVersionSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("SAMPLE DATE")
                    .font(theme.utility(10))
                    .tracking(0.8)
                    .foregroundStyle(theme.mustard)
                Spacer()
                Text(regimen?.code ?? "—")
                    .font(theme.utility(10))
                    .tracking(0.7)
                    .foregroundStyle(theme.paper.opacity(0.68))
            }

            DatePicker(
                "采样日期与时间",
                selection: $sampledAt,
                in: ...Date(),
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .font(.headline.weight(.bold))
            .colorScheme(.dark)
            .tint(theme.mustard)
            .accessibilityIdentifier("labImport.date")

            Rectangle()
                .fill(theme.paper.opacity(0.32))
                .frame(height: 1)

            Text(regimen.map { "保存后关联到 \($0.code) · \($0.title)" } ?? "保存为未关联方案的检查记录")
                .font(.caption)
                .foregroundStyle(theme.paper.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(theme.paper)
        .padding(16)
        .background(theme.indigoDeep)
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.vermilion).frame(width: 7)
        }
        .background(alignment: .bottomTrailing) {
            Rectangle()
                .fill(theme.mustard.opacity(0.88))
                .offset(x: 6, y: 6)
                .accessibilityHidden(true)
        }
        .padding(.trailing, 6)
        .padding(.bottom, 6)
    }
}

private struct LabImportLedger: View {
    @Environment(AppTheme.self) private var theme

    @Binding var entries: [LabImportEntry]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("项目")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("数值")
                    .frame(width: 84, alignment: .leading)
                Text("单位")
                    .frame(width: 86, alignment: .leading)
            }
            .font(theme.utility(9))
            .tracking(0.7)
            .foregroundStyle(theme.indigo.opacity(0.58))
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .background(theme.mustard.opacity(0.18))
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.indigo).frame(height: 1.5)
            }

            ForEach(entries.indices, id: \.self) { index in
                LabImportLedgerRow(position: index + 1, entry: $entries[index])
            }
        }
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
    }
}

private struct LabImportLedgerRow: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let position: Int
    @Binding var entry: LabImportEntry

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    itemLabel
                    HStack(spacing: 10) {
                        valueField
                        unitField
                    }
                }
            } else {
                HStack(spacing: 10) {
                    itemLabel
                        .frame(maxWidth: .infinity, alignment: .leading)
                    valueField
                        .frame(width: 84)
                    unitField
                        .frame(width: 86)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 62)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo.opacity(0.28)).frame(height: 1)
        }
    }

    private var itemLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(String(format: "%02d", position))
                .font(theme.utility(8))
                .foregroundStyle(theme.indigo.opacity(0.38))
                .frame(width: 18, alignment: .leading)
            Text(entry.itemCode)
                .font(theme.utility(11))
                .tracking(0.4)
                .foregroundStyle(theme.vermilion)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(width: 28, alignment: .leading)
            Text(entry.itemName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.indigo.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private var valueField: some View {
        TextField("数值", text: $entry.rawValue)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .font(.body.monospacedDigit())
            .padding(.horizontal, 9)
            .frame(minHeight: 44)
            .background(theme.rice.opacity(0.58))
            .overlay { Rectangle().stroke(theme.indigo.opacity(0.52), lineWidth: 1) }
            .accessibilityLabel("\(entry.itemName)数值")
            .accessibilityIdentifier("labImport.\(entry.itemCode).value")
    }

    private var unitField: some View {
        TextField("单位", text: $entry.unit)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .frame(minHeight: 44)
            .background(theme.rice.opacity(0.58))
            .overlay { Rectangle().stroke(theme.indigo.opacity(0.52), lineWidth: 1) }
            .accessibilityLabel("\(entry.itemName)单位")
            .accessibilityIdentifier("labImport.\(entry.itemCode).unit")
    }
}
