# ADR 0010：正式首次设置与 V8 采用策略

- 状态：Accepted for local implementation
- 日期：2026-07-26
- 适用版本：App 1.0
- 前置决策：[0002 本地后端合同冻结](0002-batch-0-contract-freeze.md)、[0003 数据安全底座](0003-data-safety-foundation.md)、[0005 时间与方案核心](0005-time-and-regimen-core.md)、[0006 今日执行与本地提醒](0006-today-execution-and-local-reminders.md)、[0008 Countdown 生命周期与统一本地提醒](0008-countdown-lifecycle-and-unified-local-reminders.md)、[0009 库存后置](0009-inventory-deferred-from-app-1.0.md)

## 背景

App 已有开始日、方案草稿与封存、提醒、Countdown 和 Recovery Mode，但新安装会直接进入主标签页。这样既没有在用户写入敏感资料前说明真实存储边界，也没有把“建立可供今天页确定性使用的方案”变成可恢复、可验证的首次设置任务。

首次设置不能依赖内存页码或 `SceneStorage`：用户可能随时关闭 App，写入也可能在任一步失败。它同样不能把旧用户误判为新用户；已有 V7 或 legacy 资料的人升级后不应被强制重新走一遍新手流程。

## 决策

### 1. 根门禁与步骤合同

正常 App 入口在构造主标签页之前先读取 onboarding 快照。只有完成事实通过完整性校验时才进入 `AppShellView`。读取失败、事实不一致或迁移失败一律 fail closed，显示可滚动的错误与重试页；不得把错误解释为空白资料，也不得绕过门禁。

新安装采用六步可恢复流程：

1. **隐私与存储边界**：明确 App 私有存储、无 App 主动同步、iOS 系统管理备份，以及当前没有 App Lock 和最近任务预览遮挡；
2. **HRT 开始日**：可选；
3. **当前方案**：必需。至少存在一个已封存、非归档、无需迁移复核且处于当前或即将生效区间的方案，才可继续；
4. **本地提醒**：可选；
5. **Countdown**：可选；
6. **完成核对**：再次确认必需方案仍有效后，以单次事务完成 onboarding。

草稿不算当前方案；时间线歧义或 `requiresMigrationReview` 不得由 onboarding 猜测解决。可选步骤必须记录用户是保存了事实还是明确跳过，不能只凭当前空值反推。

完成核对页若要求修改某一步，必须把 progress 重新打开到该持久化步骤，并清除需要重新确认的对应 skip fact；不能只显示编辑器、保留 `.ready`，否则编辑结果与完成摘要会脱节。

档案页提供“首次设置与提醒”再次进入入口。再次进入只允许查看或修改相关事实，不把完成状态重置为未完成。

### 2. V8 additive schema

`AppSchemaV8Onboarding` 在冻结 V7 之上只新增：

- `OnboardingProgressRecord`：固定 singleton key、合同版本、准确步骤、三个可选步骤的 skip facts、完成时间和更新时间；
- `OnboardingBackfillState`：固定 task key、来源策略、完成时间和更新时间。

`UserPreferencesRecord.onboardingCompleted` 与 progress 的 `.completed` 必须一致；`.completed` 与 `completedAt` 也必须一致。三者任一不一致都由 `OnboardingRelationshipValidator` 拒绝。

progress、rollout state 和 preferences 都拥有 canonical revision/digest。步骤转换使用 expected-step 乐观并发门禁；事实更新、revision 和 dataset metadata 在同一 SwiftData 事务提交。完成操作在同一事务更新 progress 与 preferences，失败时全部回滚。

### 3. 新装、legacy 与 V7 升级

V8 采用三种明确来源策略：

| 来源 | 初始完成状态 | progress |
| --- | --- | --- |
| 真正的新安装 V8 | 未完成 | `privacy` |
| 无 pointer 的 legacy adoption | 已完成 | `completed` |
| 已有 V7 generation 升级 | 已完成 | `completed` |

旧用户采用 grandfathering，是兼容策略，不代表系统推断其已经阅读过新文案。

V7 → V8 必须复制到新的 inactive generation，在目标代完成 lightweight migration、onboarding backfill、全部关系与 digest 校验、附件审计和文件保护检查后才切换 pointer。中断恢复复用同一个 V8 target；V7 source 的 durable bundle 不得被修改。V5/V6 等更早版本先完成各自冻结的中间代，再进入 V7 → V8，不把 V8 模型提前塞进旧 generation。

### 4. 快照与写入门禁

onboarding 使用专用有界快照，而不是读取完整 Today 或方案页面：

- profile 最多一条；
- 方案版本最多 512 条；
- 组成项、计划与提醒偏好各最多 4,096 条；
- 当前 Countdown 最多一条；
- 超限、重复 ID、重复 schedule、损坏日期或不一致引用全部 fail closed。

提醒候选只来自当前或即将生效的 eligible sealed 方案，并绑定 `scheduleRuleID + scheduleRevision`。写层在“已设置提醒”路径重新验证精确 revision 已启用，避免旧 UI 为已变化的计划开启提醒。

### 5. 通知权限与隐私

进入提醒步骤本身不请求系统权限。用户必须先选择具体计划时段，并看到中性锁屏预览及系统备份边界；只有确认打开后才写入该 revision 的提醒偏好并请求通知权限。用户的提醒选择与 `NotificationCoverageSnapshot` 表达的实际权限、调和和覆盖结果必须分开呈现；拒绝、受限或调和失败不删除方案，也不把提醒写成已成功安排。

onboarding 不新增网络、WebView、CloudKit、APNs、远程配置、遥测、崩溃上传或第三方运行时依赖。它不得宣称 App Lock、最近任务遮挡、一键无痕或系统备份一定成功。

### 6. DEBUG 测试边界

正式入口始终执行根门禁。仅 DEBUG 提供：

- 既有页面测试的显式 onboarding bypass；
- 强制读取错误；
- UUID 命名的项目 UI 测试专属持久化 store，可显式 reset 或 cleanup；
- 测试方案 fixture。

持久化测试目录只接受可解析 UUID，位于单独的 `UnmanualUITestStores/<UUID>` 子目录。cleanup 只删除该精确目录，随后使用内存 store；不得触碰正式资料库或其他测试目录。上述参数不进入 Release 行为。

### 7. 成熟方案与复用调查

本节是 2026-07-27 对既有实现补做的回顾性调查，用于补齐工程合同要求的可复用方案记录；
它不应被解释为实施前已经完成的门禁，也不能为今后模块豁免实施前调查。核查仅基于候选的
官方仓库、许可证与发布记录，没有复制候选源码，也没有把候选加入依赖图。

| 候选 | 许可证与维护状态 | 能力匹配 | 安全与隐私影响 | 决定 |
| --- | --- | --- | --- | --- |
| [ResearchKit](https://github.com/ResearchKit/ResearchKit) | BSD；官方项目仍维护 iOS 研究任务框架，3.4.0 在核查时为预发布版本 | 有 ordered task、说明、问卷、consent 和辅助功能实践；但不提供本项目的 SwiftData expected-step、skip facts、revision/digest、同事务完成或 V7 → V8 generation 迁移 | 能力面包含结果文件、日志、传感器与研究任务语义；即使只启用子集，也会扩大依赖、权限与审计面，新 SwiftUI 集成仍处于预发布版本 | 不引入、不移植源码；仅借鉴稳定步骤标识、返回门禁和辅助功能测试方法 |
| [Stanford SpeziOnboarding](https://github.com/StanfordSpezi/SpeziOnboarding) | MIT；有安全政策与 CI，核查时最新正式版为 2.0.4（2025-12-14） | 提供 SwiftUI 的 onboarding、顺序展示和 consent 组件；不负责进程重启恢复、持久化事实、乐观并发、迁移、业务编辑器复用或原子完成 | 默认是本地 UI，但引入后仍增加第三方供应链与版本审计；研究参与 consent 语义也不能替代本 App 的真实隐私边界说明 | 不引入；领域状态仍由专用 repository 管理 |
| [OnboardingUI](https://github.com/KC-2001MS/OnboardingUI) | BSD-3-Clause；核查时主分支支持 iOS 17 且近期仍有修复，但 README 的安装说明与 Package/release 状态存在矛盾 | 轻量 welcome sheet，适合首次启动信息展示；不能表达六步业务编辑、skip facts、完成前复核或迁移审计 | 没有必要的网络能力，但仍增加供应链、许可证归档和品牌 UI 改造成本；文档状态矛盾也提高维护风险 | 不引入；收益不足以替代现有 SwiftUI 视图和领域层 |

采用边界是继续复用 Apple 平台的 SwiftUI、SwiftData 和 UserNotifications，以及项目既有的
generation、revision、digest 和 repository 基础设施。项目自实现仅限候选无法提供的六步
持久化任务、fail-closed 根门禁、并发与迁移不变量。可以借鉴顺序信息呈现、Dynamic Type、
VoiceOver 和减少动态效果实践，但不建立第二套 onboarding 状态或持久化体系。未来若要引入
任一第三方依赖，必须另立依赖 ADR，重新核查版本、许可证、安全、隐私和替代方案。

## 后果

- 新用户在看到主功能前得到真实隐私说明，并可从准确步骤恢复；
- 方案成为唯一必需业务设置，开始日、提醒和 Countdown 保持可选，避免强迫用户录入库存或额外资料；
- 旧用户无阻塞升级，且源 generation、迁移中断和目标复用继续遵守数据安全合同；
- 根门禁读取错误会阻止主界面，牺牲“尽量打开”的宽松体验以避免错误资料被伪装成空白；
- 方案编辑仍是完整编辑器，首次设置不复制一套简化但规则不同的写路径。

## 不在本决策范围

- HRT 暂停、恢复与多周期管理；
- 化验趋势与确定性单位换算；
- 化验/状态父记录纠错与删除；
- 库存、余量、批次与补货提醒；
- App Lock、最近任务遮挡、全 App 删除/重置；
- 正式导出、恢复、就诊摘要或医疗方案分析；
- 真机通知投递、文件保护、系统备份恢复和完整人工辅助技术验收。

## 验证门禁

本地实现至少需要：

1. 新装、legacy adoption、V7 升级、V7 → V8 pointer 切换中断与恢复测试；
2. 每一步合法前进、后退、skip、stale step、必需方案、精确提醒 revision、完成事务与注入失败回滚测试；
3. 新装门禁、进程重启恢复、硬门禁、完整可选路径、提醒权限拒绝、完成页修改、读取错误和 Archive 再进入 UI 测试；
4. 六个步骤在 320×568、390×844、430×932、768×1024 和横屏的渲染，以及 320×568 Accessibility 5；
5. V7 → V8 的附件树复制、文件保护失败、中断重试和 pointer-last 回归；
6. generic iOS Simulator 无签名 Debug build、现有单元/UI 全量回归、Release 合同与完整 performance preflight。

Simulator 结果不能替代真机通知、文件保护、系统备份恢复、VoiceOver、外接键盘或最低设备性能门禁。
