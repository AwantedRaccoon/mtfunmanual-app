import SwiftUI

@MainActor
struct RegimenView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.appReadActor) private var appReadActor
    @State private var snapshot = CoreRegimenOverviewSnapshot.empty
    @State private var presentedSheet: RegimenPlanSheet?
    @State private var loadErrorMessage: String?
    @State private var isLoading = true

    private var activeRegimen: CoreRegimenVersionSnapshot? { snapshot.current }

    private var historicalRegimens: [CoreRegimenVersionSnapshot] { snapshot.history }

    private var latestSampleRecord: LabRecordSnapshot? {
        snapshot.labRecords.first
    }

    private var latestSampleDateText: String? {
        latestSampleRecord?.recordedShortDateText
    }

    private var latestSampleRecords: [LabRecordSnapshot] {
        guard let latestLocalDate = latestSampleRecord?.recordedLocalDate() else { return [] }
        return snapshot.labRecords.filter {
            $0.recordedLocalDate() == latestLocalDate
        }
    }

    private var latestSampleRegimen: CoreRegimenVersionSnapshot? {
        let linkedIDs = Set(latestSampleRecords.compactMap(\.regimenVersionID))
        guard linkedIDs.count == 1, let linkedID = linkedIDs.first else {
            return nil
        }
        return snapshot.allVersions.first(where: { $0.id == linkedID })
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

    private var persistedMedications: [RegimenPlanEntry] {
        (activeRegimen?.items ?? []).enumerated().map { index, item in
            RegimenPlanEntry(
                order: index + 1,
                name: item.displayName,
                route: [item.dosageForm, item.route, item.doseOriginal, item.unitOriginal]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                scheduleText: item.scheduleSummary
            )
        }
    }

    var body: some View {
        V25Page {
            VStack(alignment: .leading, spacing: 0) {
                V25PageHeader(
                    register: "REGIMEN / INDEX",
                    title: "方案",
                    subtitle: "把正在使用的版本与最近一次采样并排核对。",
                    status: "六项记录 \(recordedHormoneCount)/6"
                )

                if isLoading {
                    RegimenLoadingState()
                } else if let loadErrorMessage {
                    RegimenLoadErrorState(
                        message: loadErrorMessage,
                        retry: { Task { await refresh() } }
                    )
                } else {
                    V25SectionHeader(
                    title: "方案",
                    detail: activeRegimen.map { $0.code + " · 生效中" } ?? "尚未建立"
                )

                if let activeRegimen {
                    RegimenPlanFolio(
                        regimen: activeRegimen,
                        medications: persistedMedications,
                        latestSampleDateText: latestSampleDateText,
                        isLatestSampleLinked: latestSampleRegimen?.id == activeRegimen.id,
                        changeAction: presentNewVersion
                    )
                } else {
                    RegimenPlanMissingState(createAction: presentNewVersion)
                }

                if !snapshot.upcoming.isEmpty {
                    RegimenUpcomingNote(regimens: snapshot.upcoming)
                        .padding(.top, 16)
                }

                if !snapshot.drafts.isEmpty {
                    RegimenDraftNote(regimens: snapshot.drafts, openDraft: presentDraft)
                        .padding(.top, 12)
                }

                if !historicalRegimens.isEmpty {
                    RegimenPlanArchiveNote(regimens: historicalRegimens)
                        .padding(.top, 16)
                }

                if snapshot.isTimelineAmbiguous || snapshot.reviewIssueCount > 0 {
                    Text("有 \(max(snapshot.reviewIssueCount, 1)) 项时间或方案关联需要核对；未核对项不会自动成为当前方案。")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.vermilion)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                        .accessibilityIdentifier("regimen.reviewIssue")
                }

                V25SectionHeader(
                    title: "当前对照",
                    detail: contextDetail
                )

                    LedgerComparisonBoard(
                        activeRegimen: activeRegimen,
                        sampleDateText: latestSampleDateText,
                        linkedRegimenCode: latestSampleRegimen?.code,
                    facts: hormoneFacts,
                    importAction: presentLabImport
                )
                }
            }
            .padding(.bottom, 42)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await refresh() }
        .sheet(item: $presentedSheet, onDismiss: refreshAfterDismiss) { destination in
            switch destination {
            case .createVersion:
                RegimenVersionEditor()
            case let .editDraft(draftID):
                RegimenVersionEditor(existingDraftID: draftID)
            case .labImport:
                LabImportEditor()
            }
        }
    }

    private var contextDetail: String {
        let regimen = activeRegimen?.code ?? "无当前版本"
        let sample = latestSampleDateText ?? "无采样"
        return regimen + " × " + sample
    }

    private func presentNewVersion() {
        presentedSheet = .createVersion
    }

    private func presentLabImport() {
        presentedSheet = .labImport
    }

    private func presentDraft(_ draftID: UUID) {
        presentedSheet = .editDraft(draftID)
    }

    private func refreshAfterDismiss() {
        Task { await refresh() }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        guard let appReadActor else {
            loadErrorMessage = "本地资料尚未准备好。"
            return
        }
        do {
            let today = try HistoricalTimestamp.captured(
                instant: Date(),
                timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
            ).localDate
            let updated = try await appReadActor.coreRegimenOverview(asOf: today)
            snapshot = updated
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = "暂时无法读取方案，原资料没有被修改。"
        }
    }
}

private struct RegimenPlanFolio: View {
    @Environment(AppTheme.self) private var theme

    let regimen: CoreRegimenVersionSnapshot
    let medications: [RegimenPlanEntry]
    let latestSampleDateText: String?
    let isLatestSampleLinked: Bool
    let changeAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            RegimenPlanSpread(
                regimen: regimen,
                medications: medications,
                latestSampleDateText: latestSampleDateText,
                isLatestSampleLinked: isLatestSampleLinked
            )

            if !regimen.changeReason.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text("NOTE")
                        .font(theme.utility(8))
                        .tracking(0.8)
                        .foregroundStyle(theme.vermilion)
                    Text(regimen.changeReason)
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

    let regimen: CoreRegimenVersionSnapshot
    let medications: [RegimenPlanEntry]
    let latestSampleDateText: String?
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
                latestSampleDateText: latestSampleDateText,
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

    let regimen: CoreRegimenVersionSnapshot
    let latestSampleDateText: String?
    let isLatestSampleLinked: Bool

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 11) {
                    contextItem(label: "开始", value: regimen.effectiveStartDate.iso8601)
                    contextItem(label: "最近采样", value: sampleDescription)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    contextItem(label: "开始", value: regimen.effectiveStartDate.iso8601)
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
        guard let latestSampleDateText else { return "尚无记录" }
        return latestSampleDateText
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

    let regimens: [CoreRegimenVersionSnapshot]

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

private struct RegimenUpcomingNote: View {
    @Environment(AppTheme.self) private var theme

    let regimens: [CoreRegimenVersionSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("UPCOMING / 即将生效")
                .font(theme.utility(9))
                .tracking(0.8)
                .foregroundStyle(theme.vermilion)
            ForEach(regimens) { regimen in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(regimen.code)
                        .font(theme.utility(10))
                    Text(regimen.title)
                        .font(.subheadline.weight(.bold))
                    Spacer(minLength: 8)
                    Text(regimen.effectiveStartDate.iso8601)
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(theme.indigoDeep)
                .frame(minHeight: 44)
            }
        }
        .padding(12)
        .background(theme.mustard.opacity(0.14))
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
        .accessibilityElement(children: .contain)
    }
}

private struct RegimenDraftNote: View {
    @Environment(AppTheme.self) private var theme

    let regimens: [CoreRegimenVersionSnapshot]
    let openDraft: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("DRAFT")
                    .font(theme.utility(9))
                    .tracking(0.8)
                    .foregroundStyle(theme.vermilion)
                Text("有 \(regimens.count) 份未封存校样，不会参与当前方案或历史关联。")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(regimens) { regimen in
                Button {
                    openDraft(regimen.id)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(regimen.code)
                            .font(theme.utility(9))
                        Text(regimen.title)
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Text("继续编辑")
                            .font(.caption.weight(.bold))
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("regimen.openDraft.\(regimen.id.uuidString)")
            }
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(theme.indigo).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(theme.indigo).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}

private struct RegimenLoadingState: View {
    @Environment(AppTheme.self) private var theme

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("正在读取本地方案…")
                .font(.body.weight(.semibold))
        }
        .foregroundStyle(theme.indigo)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .center)
        .accessibilityIdentifier("regimen.loading")
    }
}

private struct RegimenLoadErrorState: View {
    @Environment(AppTheme.self) private var theme

    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("方案暂时没有读出来")
                .font(.headline.weight(.black))
            Text(message)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Button("重新读取方案", action: retry)
                .buttonStyle(V25PrimaryButtonStyle())
                .accessibilityIdentifier("regimen.retry")
        }
        .foregroundStyle(theme.indigoDeep)
        .padding(.vertical, 22)
        .accessibilityIdentifier("regimen.loadError")
    }
}

private struct RegimenPlanEntry: Identifiable, Hashable {
    let order: Int
    let name: String
    let route: String
    let scheduleText: String

    var id: Int { order }

}

private enum RegimenPlanSheet: Identifiable {
    case createVersion
    case editDraft(UUID)
    case labImport

    var id: String {
        switch self {
        case .createVersion: "createVersion"
        case let .editDraft(id): "editDraft-" + id.uuidString
        case .labImport: "labImport"
        }
    }
}
