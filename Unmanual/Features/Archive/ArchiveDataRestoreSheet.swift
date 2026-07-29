import SwiftUI
import UniformTypeIdentifiers

#if DEBUG
@MainActor
struct ArchiveDataImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppTheme.self) private var theme
    @Environment(\.dataInventoryService)
    private var dataInventoryService
    @Environment(\.portableRestoreAction)
    private var portableRestoreAction

    @State private var isChoosingFile = false
    @State private var isWorking = false
    @State private var mode:
        PortableImportMode = .restore
    @State private var package:
        AuditedPortableBackup?
    @State private var plan: PortableImportPlan?
    @State private var filename: String?
    @State private var errorMessage: String?
    @State private var requiresFinalConfirmation = false
    @State private var planRequestID: UUID?
    @State private var planTask: Task<Void, Never>?
    @State private var selectionRequestID: UUID?

    var body: some View {
        NavigationStack {
            V25EditorPage(
                register: "DATA / RESTORE",
                eyebrow: "INTERNAL / PREVIEW FIRST",
                title: "采用完整备份",
                detail:
                    "先把所选 package 复制到 App 内并完成完整性核对；在最后确认前不会改变当前资料库。",
                cancel: {
                    Task { await close() }
                }
            ) {
                if isWorking {
                    V25FieldSurface(
                        "正在核对",
                        note:
                            "正在检查 manifest、Readable JSON v2、附件摘要和本机资料状态。"
                    ) {
                        ProgressView().tint(theme.indigo)
                    }
                    .accessibilityIdentifier(
                        "archive.restore.working"
                    )
                } else if let package {
                    packagePreview(package)
                    modePicker
                    impactPreview
                    Button("改选其他完整备份") {
                        isChoosingFile = true
                    }
                    .buttonStyle(V25SecondaryButtonStyle())
                    .accessibilityIdentifier(
                        "archive.restore.chooseAnother"
                    )
                } else {
                    V25FieldSurface(
                        "01 / 选择完整备份",
                        note:
                            "只接受 .unmanualbackup 目录 package；Readable JSON v2、PDF、CSV 和 Legacy JSON v1 都不是恢复格式。"
                    ) {
                        Button("选择 .unmanualbackup") {
                            isChoosingFile = true
                        }
                        .buttonStyle(
                            V25PrimaryButtonStyle()
                        )
                        .accessibilityIdentifier(
                            "archive.restore.chooseFile"
                        )
                    }
                }

                V25PrivacyFooter(
                    text:
                        "选择器可能显示 iCloud Drive 或第三方文件提供方。导入会把选中的 package 复制到 App 内；不会删除 Files 中的原件。"
                )

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(
                            theme.vermilionText
                        )
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                        .accessibilityIdentifier(
                            "archive.restore.error"
                        )
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let package, let plan,
                   plan.canConfirm,
                   plan.mode == mode,
                   plan.packageRootDigest
                    == package.packageSHA256,
                   !isWorking {
                    V25SaveBar(
                        title: confirmTitle(for: plan),
                        isEnabled: true,
                        accessibilityIdentifier:
                            "archive.restore.confirm",
                        action: {
                            confirm(
                                package: package,
                                plan: plan
                            )
                        }
                    )
                }
            }
        }
        .tint(theme.indigo)
        .interactiveDismissDisabled(
            isWorking || package != nil
        )
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [
                .unmanualCompleteBackup
            ],
            allowsMultipleSelection: false,
            onCompletion: selectFile
        )
        .onChange(of: mode) {
            requiresFinalConfirmation = false
            refreshPlan()
        }
        .onDisappear {
            cancelOutstandingRequests()
            Task {
                _ = await discardPackage()
            }
        }
    }

    private func packagePreview(
        _ package: AuditedPortableBackup
    ) -> some View {
        let payload = package.readableDocument.payload
        return V25FieldSurface(
            "已冻结的 package",
            note: filename ?? ".unmanualbackup"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "\(payload.records.count) 条事实 · \(payload.controls.count) 条控制 · \(payload.activeAttachments.count) 个附件"
                )
                .font(.body.weight(.black))
                Text(
                    "schema \(payload.schemaVersion) · dataset "
                        + payload.datasetID.uuidString
                            .lowercased()
                )
                .font(.caption.monospaced())
                .textSelection(.enabled)
                Text(
                    "package 摘要 "
                        + String(
                            package.packageSHA256
                                .prefix(20)
                        )
                        + "…"
                )
                .font(.caption.monospaced())
            }
        }
        .accessibilityIdentifier(
            "archive.restore.preview"
        )
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            V25SectionHeader(
                title: "02 / 选择采用方式",
                detail: "不会合并两条历史"
            )
            Picker("采用方式", selection: $mode) {
                Text("恢复到空白设备")
                    .tag(PortableImportMode.restore)
                Text("替换本机资料")
                    .tag(PortableImportMode.replace)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(
                "archive.restore.mode"
            )
            Text(
                mode == .restore
                    ? "只在本机仍满足 fresh/reset 合同时可用。"
                    : "会在独立 generation 中采用 package 的 dataset；原 active generation 保留为回退证据，不会立即删除。"
            )
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
        }
    }

    @ViewBuilder
    private var impactPreview: some View {
        if let plan {
            V25FieldSurface(
                "冻结影响",
                note:
                    "确认时会重新核对本机状态与 package 摘要"
            ) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(
                        "\(plan.acceptedRecordKeys.count) 条事实将进入新的非活动资料库"
                    )
                    .font(.body.weight(.black))
                    Text(
                        "\(plan.attachmentCount) 个 active 附件将逐一核对路径、大小和 SHA-256"
                    )
                    .font(.caption)
                    Text(
                        plan.conflicts.isEmpty
                            ? "没有待解决冲突。"
                            : "发现 \(plan.conflicts.count) 个冲突；当前操作不会写入。"
                    )
                    .font(.caption.weight(.semibold))
                }
            }
            .accessibilityIdentifier(
                "archive.restore.impact"
            )
        }
    }

    private func confirmTitle(
        for plan: PortableImportPlan
    ) -> String {
        if !requiresFinalConfirmation {
            return plan.mode == .restore
                ? "查看最后确认"
                : "查看替换确认"
        }
        return plan.mode == .restore
            ? "确认恢复并准备重启"
            : "确认替换并准备重启"
    }

    private func selectFile(
        _ result: Result<[URL], Error>
    ) {
        let requestID = UUID()
        selectionRequestID = requestID
        planTask?.cancel()
        planRequestID = nil
        plan = nil
        requiresFinalConfirmation = false
        isWorking = true
        Task {
            do {
                guard let source = try result.get().first
                else {
                    guard selectionRequestID == requestID
                    else { return }
                    isWorking = false
                    return
                }
                guard let dataInventoryService,
                      portableRestoreAction != nil else {
                    throw PortableRestoreServiceError
                        .unavailable
                }
                errorMessage = nil
                guard await discardPackage() else {
                    isWorking = false
                    return
                }
                let hasAccess =
                    source
                    .startAccessingSecurityScopedResource()
                defer {
                    if hasAccess {
                        source
                            .stopAccessingSecurityScopedResource()
                    }
                }
                let staged = try await
                    dataInventoryService
                    .stageImportedBackup(at: source)
                guard selectionRequestID == requestID,
                      !Task.isCancelled else {
                    do {
                        try await dataInventoryService
                            .discardTransferPackage(
                                at: staged.packageURL
                            )
                    } catch {
                        self.package = staged
                        errorMessage =
                            "内部临时 package 尚未清理：\(error.localizedDescription)"
                    }
                    isWorking = false
                    return
                }
                package = staged
                filename = source.lastPathComponent
                selectionRequestID = nil
                requestPlan(for: staged)
            } catch {
                guard selectionRequestID == requestID
                else { return }
                selectionRequestID = nil
                isWorking = false
                errorMessage =
                    "这个完整备份没有通过导入核对；当前资料没有改变。\(error.localizedDescription)"
            }
        }
    }

    private func refreshPlan() {
        guard let package else { return }
        requestPlan(for: package)
    }

    private func requestPlan(
        for package: AuditedPortableBackup
    ) {
        planTask?.cancel()
        let requestID = UUID()
        let requestedMode = mode
        let packageDigest = package.packageSHA256
        let identity = PortableRestorePlanRequestIdentity(
            requestID: requestID,
            packageRootDigest: packageDigest,
            mode: requestedMode
        )
        planRequestID = requestID
        plan = nil
        requiresFinalConfirmation = false
        isWorking = true
        guard let portableRestoreAction else {
            isWorking = false
            errorMessage = "当前恢复会话不可用。"
            return
        }
        planTask = Task {
            do {
                let candidate = try await
                    portableRestoreAction.makePlan(
                        package,
                        requestedMode
                    )
                guard !Task.isCancelled,
                      identity.accepts(
                          requestID: planRequestID,
                          packageRootDigest:
                              self.package?
                              .packageSHA256,
                          mode: mode,
                          plan: candidate
                      ) else {
                    return
                }
                plan = candidate
                errorMessage = nil
            } catch {
                guard !Task.isCancelled,
                      planRequestID == requestID,
                      self.package?.packageSHA256
                        == packageDigest,
                      mode == requestedMode else {
                    return
                }
                plan = nil
                errorMessage =
                    requestedMode == .restore
                        ? "本机不是可恢复的空白状态。你可以改选“替换本机资料”，再核对冻结影响。"
                        : "无法冻结替换影响；当前资料没有改变。\(error.localizedDescription)"
            }
            guard planRequestID == requestID else {
                return
            }
            planRequestID = nil
            planTask = nil
            isWorking = false
        }
    }

    private func confirm(
        package: AuditedPortableBackup,
        plan: PortableImportPlan
    ) {
        guard plan.mode == mode,
              plan.packageRootDigest
                == package.packageSHA256,
              self.plan == plan,
              planRequestID == nil else {
            errorMessage =
                "采用方式或 package 已改变；请重新核对冻结影响。"
            return
        }
        guard requiresFinalConfirmation else {
            requiresFinalConfirmation = true
            errorMessage =
                "这是最后一步。再次点击后，App 会构造并核对新的资料库，然后要求完全退出并重新打开。"
            return
        }
        Task {
            guard let portableRestoreAction else {
                errorMessage = "当前恢复会话不可用。"
                return
            }
            isWorking = true
            defer { isWorking = false }
            do {
                try await portableRestoreAction
                    .confirm(package, plan)
            } catch {
                requiresFinalConfirmation = false
                errorMessage =
                    "恢复没有进入可重启状态；当前资料库仍保持不变。\(error.localizedDescription)"
            }
        }
    }

    private func close() async {
        guard !isWorking else { return }
        cancelOutstandingRequests()
        guard await discardPackage() else { return }
        dismiss()
    }

    @discardableResult
    private func discardPackage() async -> Bool {
        guard let package else { return true }
        if let dataInventoryService {
            do {
                try await dataInventoryService
                    .discardTransferPackage(
                        at: package.packageURL
                    )
            } catch {
                errorMessage =
                    "内部临时 package 尚未清理；请重试关闭。\(error.localizedDescription)"
                return false
            }
        } else {
            errorMessage =
                "内部临时 package 尚未清理；当前会话缺少精确清理器。"
            return false
        }
        self.package = nil
        plan = nil
        filename = nil
        requiresFinalConfirmation = false
        return true
    }

    private func cancelOutstandingRequests() {
        selectionRequestID = nil
        planRequestID = nil
        planTask?.cancel()
        planTask = nil
    }
}
#endif
