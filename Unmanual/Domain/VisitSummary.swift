import Foundation

enum VisitSummaryRangePreset: String, CaseIterable, Identifiable, Sendable {
    case thirtyDays
    case ninetyDays
    case oneHundredEightyDays
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thirtyDays: "最近 30 天"
        case .ninetyDays: "最近 90 天"
        case .oneHundredEightyDays: "最近 180 天"
        case .custom: "自定义"
        }
    }

    var dayCount: Int? {
        switch self {
        case .thirtyDays: 30
        case .ninetyDays: 90
        case .oneHundredEightyDays: 180
        case .custom: nil
        }
    }
}

struct VisitSummaryPrivacySelection: Equatable, Sendable {
    var includeName = false
    var includeGeneratedDate = true
    var includeRegimen = true
    var includeLabs = true
    var includePhotos = false
    var includeSensitiveNotes = false
}

struct VisitSummaryContentSelection: Equatable, Sendable {
    var includeExecution = true
    var includeStatus = true
    var includeEvents = true
    var includeQuestions = true
}

struct VisitSummaryConfiguration: Equatable, Sendable {
    var preset: VisitSummaryRangePreset
    var start: Date
    var end: Date
    var subjectName: String
    var privacy: VisitSummaryPrivacySelection
    var content: VisitSummaryContentSelection

    init(
        preset: VisitSummaryRangePreset = .ninetyDays,
        start: Date,
        end: Date,
        subjectName: String = "",
        privacy: VisitSummaryPrivacySelection = .init(),
        content: VisitSummaryContentSelection = .init()
    ) {
        self.preset = preset
        self.start = start
        self.end = end
        self.subjectName = subjectName
        self.privacy = privacy
        self.content = content
    }

    var interval: DateInterval? {
        guard start.timeIntervalSince1970.isFinite,
              end.timeIntervalSince1970.isFinite,
              start <= end else {
            return nil
        }
        return DateInterval(start: start, end: end)
    }

    func normalizedName(maximumUTF8Bytes: Int = 256) -> String? {
        guard privacy.includeName else { return nil }
        let value = subjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.lengthOfBytes(using: .utf8) <= maximumUTF8Bytes else {
            return nil
        }
        return value
    }
}

struct VisitSummaryRegimen: Identifiable, Equatable, Sendable {
    let id: UUID
    let code: String
    let title: String
    let effectiveStartDate: CivilDateFact
    let effectiveEndDate: CivilDateFact?
    let changeReason: String
    let items: [VisitSummaryRegimenItem]
}

struct VisitSummaryRegimenItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let doseOriginal: String
    let unitOriginal: String
    let route: String
    let scheduleSummary: String
}

struct VisitSummaryAdministration: Identifiable, Equatable, Sendable {
    let id: UUID
    let occurrenceKey: String
    let plannedAt: Date
    let actualAt: Date?
    let status: AdministrationStatus
    let itemName: String
    let note: String
}

struct VisitSummaryLabResult: Identifiable, Equatable, Sendable {
    let id: UUID
    let itemName: String
    let rawValue: String
    let unit: String
    let referenceRange: String?
    let assayOrVariant: String?
}

struct VisitSummaryLabSample: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: HistoricalTimestamp
    let specimen: String
    let context: String
    let results: [VisitSummaryLabResult]
    let attachmentCount: Int
}

struct VisitSummaryStatus: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: HistoricalTimestamp
    let metricName: String
    let level: Int
    let note: String
    let attachmentCount: Int
}

struct VisitSummaryJourneyItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let occurredAt: Date
    let kind: JourneyEntryKind
    let text: String
}

struct VisitSummarySnapshot: Equatable, Sendable {
    static let disclaimer =
        "数据来自用户记录，不是处方、诊断证明或医生签署的病历。"

    let snapshotID: UUID
    let generatedAt: Date
    let rangeStart: Date
    let rangeEnd: Date
    let subjectName: String?
    let includesGeneratedDate: Bool
    let regimens: [VisitSummaryRegimen]
    let administrations: [VisitSummaryAdministration]
    let labs: [VisitSummaryLabSample]
    let statuses: [VisitSummaryStatus]
    let events: [VisitSummaryJourneyItem]
    let questions: [VisitSummaryJourneyItem]
    let disclosedAttachmentCount: Int
    let sensitiveNotesIncluded: Bool
    let stateDigest: String

    var isEmpty: Bool {
        regimens.isEmpty
            && administrations.isEmpty
            && labs.isEmpty
            && statuses.isEmpty
            && events.isEmpty
            && questions.isEmpty
    }

    var recordCount: Int {
        regimens.count
            + administrations.count
            + labs.count
            + statuses.count
            + events.count
            + questions.count
    }
}

struct VisitSummaryDisclosureProjection: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        let title: String
        let rows: [String]
    }

    struct CSVTable: Equatable, Sendable {
        let filename: String
        let headers: [String]
        let rows: [[String]]
    }

    let metadataRows: [String]
    let sections: [Section]
    let csvTables: [CSVTable]

    init(snapshot: VisitSummarySnapshot) {
        var metadata = [
            "记录范围：\(Self.iso8601(snapshot.rangeStart)) — \(Self.iso8601(snapshot.rangeEnd))"
        ]
        if snapshot.includesGeneratedDate {
            metadata.append(
                "生成时间：\(Self.iso8601(snapshot.generatedAt))"
            )
        }
        if let subjectName = snapshot.subjectName {
            metadata.append("姓名：\(subjectName)")
        }
        metadataRows = metadata

        let regimenRows = snapshot.regimens.flatMap { regimen in
            let items = regimen.items.isEmpty
                ? [VisitSummaryRegimenItem(
                    id: .zero,
                    displayName: "",
                    doseOriginal: "",
                    unitOriginal: "",
                    route: "",
                    scheduleSummary: ""
                )]
                : regimen.items
            return items.map { item in
                Self.join([
                    "记录 ID \(regimen.id.uuidString.lowercased())",
                    "编号 \(regimen.code)",
                    "标题 \(regimen.title)",
                    "开始 \(regimen.effectiveStartDate.iso8601)",
                    "结束 \(regimen.effectiveEndDate?.iso8601 ?? "未填写")",
                    "项目 \(Self.present(item.displayName))",
                    "原始用量 \(Self.present(item.doseOriginal))",
                    "单位 \(Self.present(item.unitOriginal))",
                    "途径 \(Self.present(item.route))",
                    "日程 \(Self.present(item.scheduleSummary))",
                    snapshot.sensitiveNotesIncluded
                        ? "变更说明 \(Self.present(regimen.changeReason))"
                        : nil
                ])
            }
        }
        let administrationRows = snapshot.administrations.map {
            Self.join([
                "记录 ID \($0.id.uuidString.lowercased())",
                "发生键 \($0.occurrenceKey)",
                "计划 \(Self.iso8601($0.plannedAt))",
                "实际 \($0.actualAt.map(Self.iso8601) ?? "未填写")",
                "状态 \($0.status.rawValue)",
                "项目 \($0.itemName)",
                snapshot.sensitiveNotesIncluded
                    ? "备注 \(Self.present($0.note))"
                    : nil
            ])
        }
        let labRows = snapshot.labs.flatMap { sample in
            let results: [VisitSummaryLabResult?] =
                sample.results.isEmpty
                ? [nil]
                : sample.results.map(Optional.some)
            return results.map { result in
                Self.join([
                    "样本 ID \(sample.id.uuidString.lowercased())",
                    "采样 \(Self.iso8601(sample.timestamp.instant))",
                    "样本 \(Self.present(sample.specimen))",
                    snapshot.sensitiveNotesIncluded
                        ? "采样备注 \(Self.present(sample.context))"
                        : nil,
                    "结果 ID \(result?.id.uuidString.lowercased() ?? "未填写")",
                    "项目 \(Self.present(result?.itemName ?? ""))",
                    "原始结果 \(Self.present(result?.rawValue ?? ""))",
                    "单位 \(Self.present(result?.unit ?? ""))",
                    "参考范围 \(Self.present(result?.referenceRange ?? ""))",
                    "方法或变体 \(Self.present(result?.assayOrVariant ?? ""))",
                    "附件数量 \(sample.attachmentCount)"
                ])
            }
        }
        let statusRows = snapshot.statuses.map {
            Self.join([
                "记录 ID \($0.id.uuidString.lowercased())",
                "观察 \(Self.iso8601($0.timestamp.instant))",
                "指标 \($0.metricName)",
                "等级 \($0.level)",
                snapshot.sensitiveNotesIncluded
                    ? "备注 \(Self.present($0.note))"
                    : nil,
                "附件数量 \($0.attachmentCount)"
            ])
        }
        let journeyRows = (snapshot.events + snapshot.questions)
            .sorted {
                $0.occurredAt != $1.occurredAt
                    ? $0.occurredAt < $1.occurredAt
                    : $0.id.uuidString < $1.id.uuidString
            }
            .map {
                Self.join([
                    "记录 ID \($0.id.uuidString.lowercased())",
                    "时间 \(Self.iso8601($0.occurredAt))",
                    "类型 \($0.kind.rawValue)",
                    "内容 \($0.text)"
                ])
            }
        var values = [
            Section(title: "方案", rows: regimenRows),
            Section(title: "执行", rows: administrationRows),
            Section(title: "化验", rows: labRows),
            Section(title: "状态", rows: statusRows),
            Section(title: "变化、事件与问题", rows: journeyRows)
        ]
        if snapshot.disclosedAttachmentCount > 0 {
            values.append(
                Section(
                    title: "附件",
                    rows: [
                        "所选记录共有 \(snapshot.disclosedAttachmentCount) 个附件；"
                            + "报告只披露数量，不嵌入原始文件。"
                    ]
                )
            )
        }
        sections = values

        csvTables = [
            CSVTable(
                filename: "regimens.csv",
                headers: [
                    "id", "code", "title", "start_date", "end_date",
                    "item", "dose", "unit", "route", "schedule",
                    "change_reason"
                ],
                rows: snapshot.regimens.flatMap { regimen in
                    let items = regimen.items.isEmpty
                        ? [VisitSummaryRegimenItem(
                            id: .zero,
                            displayName: "",
                            doseOriginal: "",
                            unitOriginal: "",
                            route: "",
                            scheduleSummary: ""
                        )]
                        : regimen.items
                    return items.map { item in
                        [
                            regimen.id.uuidString.lowercased(),
                            regimen.code,
                            regimen.title,
                            regimen.effectiveStartDate.iso8601,
                            regimen.effectiveEndDate?.iso8601 ?? "",
                            item.displayName,
                            item.doseOriginal,
                            item.unitOriginal,
                            item.route,
                            item.scheduleSummary,
                            snapshot.sensitiveNotesIncluded
                                ? regimen.changeReason : ""
                        ]
                    }
                }
            ),
            CSVTable(
                filename: "administrations.csv",
                headers: [
                    "id", "occurrence_key", "planned_at", "actual_at",
                    "status", "item", "note"
                ],
                rows: snapshot.administrations.map {
                    [
                        $0.id.uuidString.lowercased(),
                        $0.occurrenceKey,
                        Self.iso8601($0.plannedAt),
                        $0.actualAt.map(Self.iso8601) ?? "",
                        $0.status.rawValue,
                        $0.itemName,
                        snapshot.sensitiveNotesIncluded ? $0.note : ""
                    ]
                }
            ),
            CSVTable(
                filename: "labs.csv",
                headers: [
                    "sample_id", "sampled_at", "specimen", "context",
                    "result_id", "item", "raw_value", "unit",
                    "reference_range", "assay_or_variant",
                    "attachment_count"
                ],
                rows: snapshot.labs.flatMap { sample in
                    let results: [VisitSummaryLabResult?] =
                        sample.results.isEmpty
                        ? [nil]
                        : sample.results.map(Optional.some)
                    return results.map { result in
                        [
                            sample.id.uuidString.lowercased(),
                            Self.iso8601(sample.timestamp.instant),
                            sample.specimen,
                            snapshot.sensitiveNotesIncluded
                                ? sample.context : "",
                            result?.id.uuidString.lowercased() ?? "",
                            result?.itemName ?? "",
                            result?.rawValue ?? "",
                            result?.unit ?? "",
                            result?.referenceRange ?? "",
                            result?.assayOrVariant ?? "",
                            String(sample.attachmentCount)
                        ]
                    }
                }
            ),
            CSVTable(
                filename: "status.csv",
                headers: [
                    "id", "observed_at", "metric", "level", "note",
                    "attachment_count"
                ],
                rows: snapshot.statuses.map {
                    [
                        $0.id.uuidString.lowercased(),
                        Self.iso8601($0.timestamp.instant),
                        $0.metricName,
                        String($0.level),
                        snapshot.sensitiveNotesIncluded ? $0.note : "",
                        String($0.attachmentCount)
                    ]
                }
            ),
            CSVTable(
                filename: "journey.csv",
                headers: ["id", "occurred_at", "kind", "text"],
                rows: (snapshot.events + snapshot.questions)
                    .sorted {
                        $0.occurredAt != $1.occurredAt
                            ? $0.occurredAt < $1.occurredAt
                            : $0.id.uuidString < $1.id.uuidString
                    }
                    .map {
                        [
                            $0.id.uuidString.lowercased(),
                            Self.iso8601($0.occurredAt),
                            $0.kind.rawValue,
                            $0.text
                        ]
                    }
            )
        ]
    }

    private static func join(_ values: [String?]) -> String {
        values.compactMap { $0 }.joined(separator: "｜")
    }

    private static func present(_ value: String) -> String {
        value.isEmpty ? "未填写" : value
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

enum VisitSummaryExportGate {
    static func validate(
        frozen: VisitSummarySnapshot,
        current: VisitSummarySnapshot
    ) throws {
        guard !frozen.isEmpty,
              frozen.stateDigest == current.stateDigest,
              VisitSummaryDisclosureProjection(
                  snapshot: frozen
              ) == VisitSummaryDisclosureProjection(
                  snapshot: current
              ) else {
            throw VisitSummaryFailure.stateChanged
        }
    }
}

enum VisitSummaryFailure: Error, Equatable, LocalizedError {
    case invalidRange
    case invalidName
    case rangeTooLarge
    case capacityExceeded
    case stateChanged
    case corruptedData

    var errorDescription: String? {
        switch self {
        case .invalidRange:
            "开始日期不能晚于结束日期。"
        case .invalidName:
            "姓名为空或过长；请关闭姓名开关，或填写较短的姓名。"
        case .rangeTooLarge:
            "自定义范围最多为十年。"
        case .capacityExceeded:
            "这个范围内的记录过多，无法安全生成摘要。"
        case .stateChanged:
            "预览后本地资料发生了变化，请重新核对。"
        case .corruptedData:
            "本地资料没有通过完整性检查。"
        }
    }
}

private extension UUID {
    static let zero = UUID(
        uuid: (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
    )
}

enum VisitSummaryPolicy {
    static let maximumRecordCount = 20_000
    static let maximumRangeDays = 3_653
    static let maximumTextUTF8Bytes = 1_048_576

    static func validatedInterval(
        configuration: VisitSummaryConfiguration,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) throws -> DateInterval {
        guard let interval = configuration.interval else {
            throw VisitSummaryFailure.invalidRange
        }
        let dayCount = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: interval.start),
            to: calendar.startOfDay(for: interval.end)
        ).day ?? Int.max
        guard dayCount <= maximumRangeDays else {
            throw VisitSummaryFailure.rangeTooLarge
        }
        if configuration.privacy.includeName,
           configuration.normalizedName() == nil {
            throw VisitSummaryFailure.invalidName
        }
        return interval
    }

    static func contains(_ date: Date, in interval: DateInterval) -> Bool {
        date >= interval.start && date <= interval.end
    }

    static func safeText(_ value: String, include: Bool = true) throws -> String {
        guard include else { return "" }
        guard value.lengthOfBytes(using: .utf8) <= maximumTextUTF8Bytes else {
            throw VisitSummaryFailure.capacityExceeded
        }
        return value
    }
}
