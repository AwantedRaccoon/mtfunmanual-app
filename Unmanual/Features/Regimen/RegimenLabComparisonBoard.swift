import SwiftUI

struct LedgerComparisonBoard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let activeRegimen: RegimenVersion?
    let sampleDate: Date?
    let linkedRegimenCode: String?
    let facts: [LedgerHormoneFact]
    let importAction: () -> Void

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stackedBoard
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    LedgerRegimenSpine(
                        regimen: activeRegimen,
                        sampleDate: sampleDate,
                        linkedRegimenCode: linkedRegimenCode,
                        layout: .spine
                    )
                    .frame(width: 96)

                    LedgerLabIndex(
                        sampleDate: sampleDate,
                        facts: facts,
                        importAction: importAction
                    )
                        .frame(minWidth: 228)
                }
                .fixedSize(horizontal: false, vertical: true)

                stackedBoard
            }
        }
    }

    private var stackedBoard: some View {
        VStack(spacing: 10) {
            LedgerRegimenSpine(
                regimen: activeRegimen,
                sampleDate: sampleDate,
                linkedRegimenCode: linkedRegimenCode,
                layout: .banner
            )
            LedgerLabIndex(
                sampleDate: sampleDate,
                facts: facts,
                importAction: importAction
            )
        }
    }
}

private struct LedgerRegimenSpine: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    enum Layout {
        case spine
        case banner
    }

    let regimen: RegimenVersion?
    let sampleDate: Date?
    let linkedRegimenCode: String?
    let layout: Layout

    var body: some View {
        Group {
            switch layout {
            case .spine:
                spine
            case .banner:
                banner
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(theme.paper)
        .background(theme.indigoDeep)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 2) }
        .overlay(alignment: .top) {
            Rectangle().fill(theme.mustard).frame(height: 7)
        }
    }

    private var spine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CURRENT")
                .font(theme.utility(10))
                .tracking(0.9)
                .foregroundStyle(theme.mustard)
                .padding(.top, 17)

            Text(regimen?.code ?? "—")
                .font(theme.display(29, relativeTo: .title2))
                .minimumScaleFactor(0.72)
                .lineLimit(1)
                .padding(.top, 5)

            Text(regimen?.title ?? "尚未建立")
                .font(theme.display(18, relativeTo: .headline))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            Rectangle()
                .fill(theme.paper.opacity(0.35))
                .frame(height: 1)
                .padding(.vertical, 13)

            LedgerSpineDatum(
                label: "开始",
                value: regimen?.startedAt.unmanualShortDateText ?? "未记录"
            )

            Spacer(minLength: 18)

            Text("LATEST LAB")
                .font(theme.utility(9))
                .tracking(0.7)
                .foregroundStyle(theme.mustard)
            Text(sampleDate?.unmanualShortDateText ?? "未采样")
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 5)
            Text(linkText)
                .font(.caption2)
                .foregroundStyle(theme.paper.opacity(0.64))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
        }
        .padding(.horizontal, 11)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 11) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CURRENT / \(regimen?.code ?? "—")")
                        .font(theme.utility(10))
                        .tracking(0.8)
                        .foregroundStyle(theme.mustard)
                    Text(regimen?.title ?? "尚未建立当前方案")
                        .font(theme.display(25, relativeTo: .title2))
                    Text("开始 \(regimen?.startedAt.unmanualShortDateText ?? "未记录")")
                        .font(.headline.monospacedDigit())
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("CURRENT / \(regimen?.code ?? "—")")
                            .font(theme.utility(10))
                            .tracking(0.8)
                            .foregroundStyle(theme.mustard)
                        Text(regimen?.title ?? "尚未建立当前方案")
                            .font(theme.display(25, relativeTo: .title2))
                    }

                    Spacer(minLength: 8)

                    Text(regimen?.startedAt.unmanualShortDateText ?? "未记录开始日")
                        .font(.caption.weight(.bold))
                        .multilineTextAlignment(.trailing)
                }
            }

            Rectangle().fill(theme.paper.opacity(0.35)).frame(height: 1)

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近采样")
                        .font(theme.utility(9))
                        .foregroundStyle(theme.mustard)
                    Text(sampleDate?.unmanualShortDateText ?? "尚无记录")
                        .font(.headline.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(linkText)
                        .font(.caption)
                        .foregroundStyle(theme.paper.opacity(0.66))
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("最近采样")
                        .font(theme.utility(9))
                        .foregroundStyle(theme.mustard)
                    Text(sampleDate?.unmanualShortDateText ?? "尚无记录")
                        .font(.subheadline.weight(.bold))
                    Spacer(minLength: 8)
                    Text(linkText)
                        .font(.caption2)
                        .foregroundStyle(theme.paper.opacity(0.66))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var linkText: String {
        guard let linkedRegimenCode else { return "未关联方案" }
        return "关联 \(linkedRegimenCode)"
    }
}

private struct LedgerSpineDatum: View {
    @Environment(AppTheme.self) private var theme

    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(theme.utility(9))
                .tracking(0.6)
                .foregroundStyle(theme.paper.opacity(0.54))
            Text(value)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct LedgerLabIndex: View {
    @Environment(AppTheme.self) private var theme

    let sampleDate: Date?
    let facts: [LedgerHormoneFact]
    let importAction: () -> Void

    private var recordedCount: Int {
        facts.filter { $0.record != nil }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("最近检查")
                        .font(theme.display(23, relativeTo: .title3))
                    Text(sampleDate?.unmanualShortDateText ?? "尚无采样记录")
                        .font(theme.utility(9))
                        .tracking(0.5)
                        .foregroundStyle(theme.indigo.opacity(0.58))
                }

                Spacer(minLength: 6)

                Button(action: importAction) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(recordedCount)/6")
                            .font(theme.display(24, relativeTo: .title3))
                            .monospacedDigit()
                        Label("导入", systemImage: "plus")
                            .font(theme.utility(9))
                            .tracking(0.5)
                    }
                    .foregroundStyle(theme.vermilion)
                    .frame(minWidth: 54, minHeight: 48, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(V25PressStyle())
                .accessibilityLabel("导入性激素六项记录，当前已填写 \(recordedCount) 项")
                .accessibilityIdentifier("regimen.labImport")
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.mustard.opacity(0.18))
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.indigo).frame(height: 2)
            }

            ForEach(facts) { fact in
                LedgerHormoneRow(fact: fact)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .foregroundStyle(theme.indigoDeep)
        .background(theme.paper)
        .overlay { Rectangle().stroke(theme.indigo, lineWidth: 1.5) }
    }
}

private struct LedgerHormoneRow: View {
    @Environment(AppTheme.self) private var theme

    let fact: LedgerHormoneFact

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Text(String(format: "%02d", fact.order))
                .font(theme.utility(8))
                .foregroundStyle(theme.indigo.opacity(0.36))
                .frame(width: 17, alignment: .leading)

            Text(fact.descriptor.code)
                .font(theme.utility(11))
                .tracking(0.5)
                .foregroundStyle(fact.record == nil ? theme.indigo.opacity(0.44) : theme.vermilion)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(width: 28, alignment: .leading)

            Text(fact.descriptor.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.indigo.opacity(fact.record == nil ? 0.48 : 0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Spacer(minLength: 3)

            if let record = fact.record {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(record.rawValue)
                        .font(theme.display(18, relativeTo: .body))
                        .monospacedDigit()
                    Text(record.unit)
                        .font(theme.utility(7))
                        .foregroundStyle(theme.indigo.opacity(0.54))
                        .lineLimit(1)
                        .minimumScaleFactor(0.66)
                }
            } else {
                Text("—")
                    .font(theme.display(20, relativeTo: .body))
                    .foregroundStyle(theme.indigo.opacity(0.28))
            }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 46)
        .background(fact.record == nil ? theme.rice.opacity(0.42) : theme.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.indigo.opacity(0.28)).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let record = fact.record else {
            return "第 \(fact.order) 项，\(fact.descriptor.name)，本次采样未记录"
        }
        return "第 \(fact.order) 项，\(fact.descriptor.name)，\(record.rawValue) \(record.unit)"
    }
}
struct LedgerHormoneFact: Identifiable {
    let order: Int
    let descriptor: LedgerHormoneDescriptor
    let record: LabRecord?

    var id: String { descriptor.code }
}

struct LedgerHormoneDescriptor: Identifiable {
    let code: String
    let name: String
    let aliases: Set<String>

    var id: String { code }

    func matches(itemCode: String) -> Bool {
        aliases.contains(itemCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }

    static let all: [LedgerHormoneDescriptor] = [
        .init(code: "E2", name: "雌二醇", aliases: ["E2", "ESTRADIOL"]),
        .init(code: "T", name: "睾酮", aliases: ["T", "TESTOSTERONE", "TESTO"]),
        .init(code: "LH", name: "促黄体生成素", aliases: ["LH"]),
        .init(code: "FSH", name: "促卵泡生成素", aliases: ["FSH"]),
        .init(code: "PRL", name: "泌乳素", aliases: ["PRL", "PROLACTIN"]),
        .init(code: "P", name: "孕酮", aliases: ["P", "P4", "PROG", "PROGESTERONE"])
    ]
}
