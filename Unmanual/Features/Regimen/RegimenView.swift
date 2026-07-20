import SwiftData
import SwiftUI

@MainActor
struct RegimenView: View {
    @Environment(AppTheme.self) private var theme
    @Query(sort: \RegimenVersion.startedAt, order: .reverse) private var regimens: [RegimenVersion]
    @Query(sort: \LabRecord.sampledAt, order: .reverse) private var labRecords: [LabRecord]
    @State private var presentedSheet: RegimenPlanSheet?

    private var activeRegimen: RegimenVersion? {
        regimens.first(where: { $0.endedAt == nil })
    }

    private var historicalRegimens: [RegimenVersion] {
        regimens.filter { $0.endedAt != nil }
    }

    private var latestSampleDate: Date? {
        labRecords.first?.sampledAt
    }

    private var latestSampleRecords: [LabRecord] {
        guard let latestSampleDate else { return [] }
        let calendar = Calendar.autoupdatingCurrent
        return labRecords.filter {
            calendar.isDate($0.sampledAt, inSameDayAs: latestSampleDate)
        }
    }

    private var latestSampleRegimen: RegimenVersion? {
        let linkedIDs = Set(latestSampleRecords.compactMap(\.regimenVersionID))
        guard linkedIDs.count == 1, let linkedID = linkedIDs.first else {
            return nil
        }
        return regimens.first(where: { $0.id == linkedID })
    }

    private var hormoneFacts: [LedgerHormoneFact] {
        LedgerHormoneDescriptor.all.enumerated().map { index, descriptor in
            LedgerHormoneFact(
                order: index + 1,
                descriptor: descriptor,
                record: latestSampleRecords.first {
                    descriptor.matches(itemCode: $0.itemCode)
                }
            )
        }
    }

    private var recordedHormoneCount: Int {
        hormoneFacts.filter { $0.record != nil }.count
    }

    private var previewMedications: [RegimenPlanEntry] {
#if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-unmanual-demo-home") else {
            return []
        }
        return [
            RegimenPlanEntry(
                order: 1,
                name: "戊酸雌二醇片",
                route: "口服",
                slots: [.morning, .evening]
            ),
            RegimenPlanEntry(
                order: 2,
                name: "螺内酯片",
                route: "口服",
                slots: [.morning]
            )
        ]
#else
        return []
#endif
    }

    var body: some View {
        V25Page {
            VStack(alignment: .leading, spacing: 0) {
                V25PageHeader(
                    register: "V2.5 / INDEX PROOF",
                    title: "方案",
                    subtitle: "把正在使用的版本与最近一次采样并排核对。",
                    status: "六项记录 \(recordedHormoneCount)/6"
                )

                V25SectionHeader(
                    title: "当前对照",
                    detail: contextDetail
                )

                LedgerComparisonBoard(
                    activeRegimen: activeRegimen,
                    sampleDate: latestSampleDate,
                    linkedRegimenCode: latestSampleRegimen?.code,
                    facts: hormoneFacts
                )

                V25SectionHeader(
                    title: "方案",
                    detail: activeRegimen.map { $0.code + " · 生效中" } ?? "尚未建立"
                )

                if let activeRegimen {
                    RegimenPlanFolio(
                        regimen: activeRegimen,
                        medications: previewMedications,
                        latestSampleDate: latestSampleDate,
                        isLatestSampleLinked: latestSampleRegimen?.id == activeRegimen.id,
                        changeAction: presentNewVersion
                    )
                } else {
                    RegimenPlanMissingState(createAction: presentNewVersion)
                }

                if !historicalRegimens.isEmpty {
                    RegimenPlanArchiveNote(regimens: historicalRegimens)
                        .padding(.top, 16)
                }
            }
            .padding(.bottom, 42)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $presentedSheet) { _ in
            RegimenVersionEditor()
        }
    }

    private var contextDetail: String {
        let regimen = activeRegimen?.code ?? "无当前版本"
        let sample = latestSampleDate?.unmanualShortDateText ?? "无采样"
        return regimen + " × " + sample
    }

    private func presentNewVersion() {
        presentedSheet = .createVersion
    }
}

private struct RegimenPlanFolio: View {
    @Environment(AppTheme.self) private var theme

    let regimen: RegimenVersion
    let medications: [RegimenPlanEntry]
    let latestSampleDate: Date?
    let isLatestSampleLinked: Bool
    let changeAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            RegimenPlanSpread(
                regimen: regimen,
                medications: medications,
                latestSampleDate: latestSampleDate,
                isLatestSampleLinked: isLatestSampleLinked
            )

            if !regimen.note.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text("NOTE")
                        .font(theme.utility(8))
                        .tracking(0.8)
                        .foregroundStyle(theme.vermilion)
                    Text(regimen.note)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.indigoDeep)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 13)
                .padding(.top, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("编辑当前方案", action: changeAction)
                .buttonStyle(V25PrimaryButtonStyle())
                .padding(12)
                .accessibilityIdentifier("regimen.newVersion")
        }
        .background(theme.paper)
        .clipped()
        .overlay {
            Rectangle().stroke(theme.indigo, lineWidth: 1.5)
        }
    }
}

private struct RegimenPlanSpread: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let regimen: RegimenVersion
    let medications: [RegimenPlanEntry]
    let latestSampleDate: Date?
    let isLatestSampleLinked: Bool

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    RegimenPlanSpineHeader(regimenCode: regimen.code)
                    composition
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    composition
                    RegimenPlanSpine(regimenCode: regimen.code)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var composition: some View {
        VStack(spacing: 0) {
            RegimenPlanCompositionHeader(itemCount: medications.count)

            if medications.isEmpty {
                RegimenPlanEmptyComposition()
            } else {
                ForEach(Array(medications.enumerated()), id: \.element.id) { index, medication in
                    if index > 0 {
                        Rectangle()
                            .fill(theme.indigo.opacity(0.3))
                            .frame(height: 1)
                    }
                    RegimenPlanMedicationRow(medication: medication)
                }
            }

            RegimenPlanContextBand(
                regimen: regimen,
                latestSampleDate: latestSampleDate,
                isLatestSampleLinked: isLatestSampleLinked
            )
        }
        .frame(maxWidth: .infinity)
        .background(theme.paper)
    }
}

private struct RegimenPlanSpine: View {
    @Environment(AppTheme.self) private var theme

    let regimenCode: String

    var body: some View {
        ZStack {
            theme.mustard
            Text(regimenCode)
                .font(theme.display(27, relativeTo: .title2))
                .tracking(1.2)
                .foregroundStyle(theme.indigoDeep)
                .fixedSize()
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 52)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("当前方案 " + regimenCode)
    }
}

private struct RegimenPlanSpineHeader: View {
    @Environment(AppTheme.self) private var theme

    let regimenCode: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("当前生效")
                .font(theme.utility(9))
                .tracking(0.8)
                .foregroundStyle(theme.indigoDeep.opacity(0.68))
            Spacer(minLength: 8)
            Text(regimenCode)
                .font(theme.display(25, relativeTo: .title2))
                .foregroundStyle(theme.indigoDeep)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(theme.mustard)
        .accessibilityElement(children: .combine)
    }
}

private struct RegimenPlanCompositionHeader: View {
    @Environment(AppTheme.self) private var theme

    let itemCount: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("REGIMEN COMPOSITION")
                    .font(theme.utility(8))
                    .tracking(0.9)
                    .foregroundStyle(theme.vermilion)
                Text("方案组成")
                    .font(theme.display(22, relativeTo: .title3))
                    .foregroundStyle(theme.indigoDeep)
            }
            Spacer(minLength: 8)
            Text("\(itemCount) 项")
                .font(theme.utility(10))
                .foregroundStyle(theme.indigo.opacity(0.54))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.indigo)
                .frame(height: 1.5)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RegimenPlanMedicationRow: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let medication: RegimenPlanEntry

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    identity
                    schedule
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    identity
                    Spacer(minLength: 8)
                    schedule
                }
            }
        }
        .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 13 : 11)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 13 : 8)
        .frame(
            maxWidth: .infinity,
            minHeight: dynamicTypeSize.isAccessibilitySize ? 82 : 64,
            alignment: .leading
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            medication.name
                + "，"
                + medication.route
                + "，使用时段 "
                + medication.scheduleText
        )
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: dynamicTypeSize.isAccessibilitySize ? 5 : 3) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(String(format: "%02d", medication.order))
                    .foregroundStyle(theme.vermilion)
                Text(medication.route)
                    .foregroundStyle(theme.blue)
            }
            .font(theme.utility(9))
            .tracking(0.5)

            Text(medication.name)
                .font(theme.display(18, relativeTo: .headline))
                .foregroundStyle(theme.indigoDeep)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var schedule: some View {
        VStack(
            alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing,
            spacing: dynamicTypeSize.isAccessibilitySize ? 3 : 1
        ) {
            Text("使用时段")
                .font(theme.utility(8))
                .tracking(0.7)
                .foregroundStyle(theme.indigo.opacity(0.48))
            Text(medication.scheduleText)
                .font(theme.display(18, relativeTo: .headline))
                .foregroundStyle(theme.indigoDeep)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct RegimenPlanContextBand: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let regimen: RegimenVersion
    let latestSampleDate: Date?
    let isLatestSampleLinked: Bool

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 11) {
                    contextItem(label: "开始", value: regimen.startedAt.unmanualShortDateText)
                    contextItem(label: "最近采样", value: sampleDescription)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    contextItem(label: "开始", value: regimen.startedAt.unmanualShortDateText)
                    Rectangle()
                        .fill(theme.indigo.opacity(0.28))
                        .frame(width: 1, height: 28)
                    contextItem(label: "最近采样", value: sampleDescription)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 11 : 9)
        .background(theme.rice)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.indigo)
                .frame(height: 1.5)
        }
        .accessibilityElement(children: .combine)
    }

    private func contextItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(theme.utility(8))
                .tracking(0.7)
                .foregroundStyle(theme.indigo.opacity(0.5))
            Text(value)
                .font(.caption.weight(.black))
                .foregroundStyle(theme.indigoDeep)
        }
    }

    private var sampleDescription: String {
        guard let latestSampleDate else { return "尚无记录" }
        return latestSampleDate.unmanualShortDateText
            + (isLatestSampleLinked ? " · 已关联" : " · 未关联")
    }
}

private struct RegimenPlanEmptyComposition: View {
    @Environment(AppTheme.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("尚未填写方案组成")
                .font(theme.display(23, relativeTo: .title3))
            Text("补充药物名称、使用途径和时段后，这里会列出当前方案。")
                .font(.body)
                .foregroundStyle(theme.indigo.opacity(0.64))
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.paper)
    }
}

private struct RegimenPlanMissingState: View {
    @Environment(AppTheme.self) private var theme

    let createAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("还没有当前方案")
                .font(theme.display(26, relativeTo: .title2))
            Text("建立后，这里会显示方案版本、组成、使用时段和关联采样。")
                .font(.body)
                .foregroundStyle(theme.indigo.opacity(0.66))
            Button("建立第一个方案", action: createAction)
                .buttonStyle(V25PrimaryButtonStyle())
                .accessibilityIdentifier("regimen.newVersion")
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(14)
        .background(theme.paper)
        .overlay {
            Rectangle().stroke(theme.indigo, lineWidth: 1.5)
        }
    }
}

private struct RegimenPlanArchiveNote: View {
    @Environment(AppTheme.self) private var theme

    let regimens: [RegimenVersion]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("ARCHIVE")
                .font(theme.utility(9))
                .tracking(0.8)
                .foregroundStyle(theme.vermilion)
            Text("另有 \(regimens.count) 个历史版本")
                .font(.subheadline.weight(.bold))
            Spacer()
            Text(regimens.first?.code ?? "")
                .font(theme.utility(10))
                .foregroundStyle(theme.indigo.opacity(0.48))
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.indigo).frame(height: 1.5)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo).frame(height: 1.5)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RegimenPlanEntry: Identifiable, Hashable {
    let order: Int
    let name: String
    let route: String
    let slots: [RegimenPlanSlot]

    var id: Int { order }

    var scheduleText: String {
        slots.map(\.title).joined(separator: " · ")
    }
}

private enum RegimenPlanSlot: String, Hashable {
    case morning
    case evening

    var title: String {
        switch self {
        case .morning: "早"
        case .evening: "晚"
        }
    }

}

private enum RegimenPlanSheet: String, Identifiable {
    case createVersion

    var id: String { rawValue }
}
