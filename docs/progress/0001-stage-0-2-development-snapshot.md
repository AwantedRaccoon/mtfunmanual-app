# Stage 0–2 开发快照

- 日期：2026-07-21
- 产品版本：App 1.0（build 1）
- 最低系统：iOS / iPadOS 17.0
- 快照状态：本地阶段报告，尚未 push；不是 GitHub Release、TestFlight 或 App Store 构建
- 下一计划批次：Batch 3「今日执行、提醒与 Countdown」

## 1. 这份快照是什么

这是一份供维护者审阅的开发阶段快照，把许可证与来源、Batch 0 合同、Batch 1 数据底座、Batch 2 时间与方案核心拆成四个可读提交。它报告已经完成的工程事实和仍未验证的边界，不代表整个 App 已构建完成或达到发布条件。

四个提交主题依次为：

1. `chore: define repository licensing and provenance`
2. `docs: freeze app 1.0 local backend contracts`
3. `feat: establish local data foundation and regimen core`
4. `docs: publish stage 0-2 development snapshot`

## 2. 已落地范围

### Batch 0：合同冻结

- 固定 App 1.0、iOS 17+、SwiftUI + SwiftData、本地优先与无 App 主动联网边界；
- 固定 `.systemManaged` 系统备份口径，以及时间、执行、库存、化验、数据谱系和发行门禁；
- 固定多 Agent 调查、独立审查与全新复审纪律。

### Batch 1：数据安全底座

- V1 → V2 bridge、generation copy/journal/pointer、幂等 backfill 与 Recovery Mode；
- DatasetMetadata、RecordRevision、稳定 digest、读写 actor、有界查询和文件保护代码路径；
- 五年数据性能 evidence harness；Simulator 只用于预检，不替代真机门禁；
- DEBUG JSON v1 原型仍不是完整备份或安全恢复协议。

### Batch 2：时间与方案版本核心

- additive Schema V3、civil date 与 historical timestamp；
- canonical 方案草稿、组成项、计划规则、校样 token、封存与历史关联；
- 当前、未来、历史状态及核对项的读写接线；
- Release 药品目录保持为空，未复核 placeholder 不进入正式目录。

## 3. 阶段验证

本快照形成前完成了以下本地验证：

- generic iOS Simulator 无签名 Debug build：通过；
- 单元与渲染测试：119/119 通过；
- UI 测试：13/13 通过；
- Release 合同测试：9/9 通过；
- Simulator performance preflight：1/1 通过，完成 1 次预热和 20 个正式样本；
- 性能报告状态：`complete-characterization`；验收状态：`not-evaluated`；
- 冻结 legacy SQLite main/WAL/SHM 哈希与来源清单一致；
- AppIcon 哈希与来源记录一致；
- Swift 源码静态扫描未发现 App 主动网络、WebView、CloudKit 或遥测入口；
- 暂存内容未包含内部工作日志、构建产物、Simulator 标识或绝对本机路径。

性能预检只证明 harness 在当前 Simulator 上完成了正确性校验和样本收集。由于数值阈值、低端真机和跨设备冻结 fixture 尚未确定，本快照不宣称性能达标。

## 4. 仍未关闭的门禁

- 真机文件保护 class、锁屏 I/O 与系统备份/恢复；
- 动态无网络验证与完整数据外流审计；
- iPhone SE 2 / XR 级别 Release 性能阈值；
- 完整 VoiceOver、动态字号、旋转、键盘和全状态人工矩阵；
- ScheduleEngine、occurrence、执行与纠错、本地提醒和 Countdown 完整状态机；
- 库存、完整化验、状态/附件、统一时间线、隐私控制、报告与完整备份；
- 正式药品 catalog、公共内容包、确定性分析和发布硬化；
- Apple Developer Program、签名 Release Candidate、发行主体、地区、隐私/医疗分类与内容授权。

真机测试按项目约定等整个 App 构建完成后统一执行；达到发布 ready 前不把 Simulator 结果外推为真机结论。

## 5. GitHub 与发布边界

本地分支为 `codex/github-stage-0-2-report`。截至本报告，该分支尚未 push；远端主分支未被本次整理改变。

阶段快照可以在维护者确认后作为开发进度推送到 GitHub，但它不是 Release，也不会触发 TestFlight、App Store Connect 或其他发布操作。任何 push 或发布动作仍需要当次明确授权。
