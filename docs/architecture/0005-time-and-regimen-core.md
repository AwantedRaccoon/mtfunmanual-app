# 0005：时间事实与方案版本核心

- 状态：Accepted
- 日期：2026-07-21
- 适用版本：App 1.0 / Schema V3 Core
- 前置合同：[0002：Batch 0 本地后端合同冻结](0002-batch-0-contract-freeze.md)
- 数据底座：[0003：数据安全底座](0003-data-safety-foundation.md)

## 1. 本批目标

本批把 ADR 0002 已冻结的两类时间事实和方案版本合同接入实际 SwiftData、Repository 与 SwiftUI。交付范围是“可安全记录和回看个人方案版本”的核心骨架，不是处方、提醒、库存或执行系统。

完成后必须成立：

- 日期事实不再用裸 `Date` 表示；历史 instant 不会随设备当前时区重解释。
- 正式方案版本不可原地覆盖，草稿不会参与当前方案解析。
- 当前、未来和历史状态由同一个 civil-date resolver 派生。
- 旅程与化验写入时在存储层确定当时的方案关联。
- 历史生效日封存前显示变更前/后组成与受影响记录，过期校样零写入拒绝。
- V2 active generation 不原地升级；V3 只在 inactive copy 验证成功后切换 pointer。

## 2. Schema V3 Core

`AppSchemaV2Bridge` 保持冻结。新增 additive `AppSchemaV3Core`，保留 V1/V2 的所有实体，并加入：

- `UserPreferencesRecord`
- `HrtJourneyProfileRecord`
- `HrtPeriodRecord`
- `RegimenPlanVersionRecord`
- `RegimenItemRecord`
- `ScheduleRuleRecord`
- `HistoricalTimeRecord`
- `CoreTimeRegimenBackfillState`

新实体继续使用现有 dataset、revision 和 digest 底座。一个成功语义事务中的方案版本、组成项、计划规则和受影响历史关联共享同一 local revision；失败时整体 rollback。

旧 `RegimenVersion` 继续作为冻结的 legacy 事实，不再是当前业务写入目标；legacy 创建入口只在 DEBUG 测试构建存在。canonical 类型使用不同的 Swift 名称，避免伪装成直接改造旧实体。

## 3. 两类时间事实

### 3.1 CivilDateFact

`CivilDateFact` 保存公历年、月、日，不携带 instant。HRT 周期和方案生效日使用此类型，排序采用稳定的 `YYYY-MM-DD` 语义。

SwiftUI `DatePicker` 仍可作为显示适配层，但保存边界必须立即在明确时区中转换为 `CivilDateFact`；持久化层不得再次用设备当前时区解释这个日期。

### 3.2 HistoricalTimestamp

旅程与化验同时保存：

- UTC instant；
- 原始 local date 与 local time；
- IANA time-zone identifier；
- 当时 UTC offset；
- precision 与 provenance。

新写入使用 `userEntered` provenance。legacy 迁移固定使用该 generation 首次记录的 assumed time zone，并标为 `migrationAssumed`；重试不得换用新的设备时区。

HRT 开始日保存同时更新冻结 legacy 兼容事实和 `HrtJourneyProfileRecord` / 当前 `HrtPeriodRecord`；三个事实共享同一 local revision。Today 与编辑器优先读取 canonical civil-date facts，legacy `Date` 只承担兼容与备份边界。

化验界面收集日期与分钟；无论调用来自 UI 还是其他入口，写入边界都必须先把 instant 的秒/亚秒归零，再以同一个规范化 instant 写 legacy LabRecord 和 V3 sidecar，并记录 `.minute` precision。不得依赖 UI 归零，也不得把用户没有输入的秒标成已知事实。

Journey/Lab 读模型必须把对应 `HistoricalTimeRecord` 的 canonical timestamp 一并带到 UI。Today、Journey 与 Regimen 的当地日期显示、按日分组和“今天”比较都优先使用 sidecar 冻结的 local date；只有记录确实没有 sidecar 时，才允许用 legacy instant 与调用方明确提供的 fallback time zone 兼容显示。不得因为用户后来切换设备时区而重解释已有历史日期。

按 civil day 查询化验时，API 直接接收 `CivilDateFact`，并先按 `HistoricalTimeRecord.localYear/localMonth/localDay` 选择 canonical 记录；不能先用当前 `Calendar` 过滤 legacy instant 再补 sidecar。每条命中的 sidecar 必须通过 timestamp、source 一一对应和 association state/ID 配对校验，损坏、重复、孤儿或超过显式上限都 fail-closed。只有完全没有 sidecar 的 legacy 化验才进入调用方明确提供时区的日区间兼容查询；这个 fallback 不能覆盖或重解释 canonical 结果。

## 4. 方案时间线与不变量

只有 `sealed`、非 archived、无需 migration review 的版本进入 canonical 时间线。

- 区间统一为半开区间 `[start, end)`。
- 没有显式结束日的旧版本，由下一 sealed 版本的开始日推导 end。
- 生效日前为 upcoming，生效日当天才可能成为 current。
- 同一日期存在零个或多个候选时，current/association 均为空并产生核对状态，不猜测。
- draft 永远不成为 current，也不改变历史关联。
- sealed 版本的用户内容及其组成项不可原地修改；后续变化创建新版本和全新的 item identity。
- `previousVersionID` 必须指向生效日前最近的 sealed 版本；过期或跳链命令拒绝。

若用户在既有两个 sealed 版本之间补录历史版本，封存事务会只重连紧邻后续版本的 `previousVersionID`，并为新版本与该结构链接写同一 revision。该系统维护字段的重连不是覆盖后续版本的标题、组成、开始日或理由；它是支持历史插入且保持链不跳跃的唯一例外。

## 5. 草稿、校样与封存

`AppWriteActor` 暴露三个明确边界：

1. `saveRegimenDraft`：显式保存草稿及全部组成项/规则。取消编辑且未保存时零写入；已保存草稿保持 inert。
2. `previewRegimenChange`：只读计算变更前/后版本快照、受影响 Journey/Lab 的 ID、当地日期、摘要及关联前后值，并签发包含 draft digest 与预期 dataset revision 的 token。
3. `sealRegimenDraft`：在单一事务中重新校验 token、前序版本、时间线和草稿 digest，封存版本并重算受影响历史关联。

任何 intervening write 都会使 preview token 过期。过期、重复身份、重叠、错误前序或非法时间线均拒绝并零写入。

组成项保存用户原始名称、通用名、剂型、途径、用量原文、单位原文和可选 schedule rule。App 不解释、纠正或推荐用量。

运行时写入若得到零个或多个候选，必须与 `HistoricalTimeRecord` 同事务创建对应可见核对项；后续封存使关联唯一时，同一事务删除过期核对项。读模型优先消费 sidecar 的 canonical association，不能继续从 legacy `regimenVersionID` 显示旧结果。

拒绝错误前序、sealed ID 和跨版本 child identity 必须在 revision 预留前完成只读 preflight；这些用户可预期的拒绝条件不能推进 `nextLocalRevision`。

## 6. 迁移与 pointer 切换

V2 active generation 的升级流程固定为：

1. 创建 inactive generation。
2. 复制 source SQLite bundle。
3. 以 `AppSchemaV3Core` 打开 copy。
4. 执行幂等 core backfill。
5. 重开并验证 metadata、事实/Revision/digest 一一对应及关系完整性。
6. 原子写入 `schemaVersion = 3.0.0` 的 active pointer。

关系完整性不是只查外键存在。激活前至少还要 fail-closed 核对：`previousVersionID` 存在、无环且不跳过最近 eligible sealed 前序；每个 item 至多一条 schedule；sidecar 的 source type/ID/record key 指向真实 Journey/Lab；`resolved` 必须有且只能指向存在的 canonical version，`missing/ambiguous` 必须没有 resolved ID。即使损坏事实与 digest 自洽，也不得切换 pointer。

source V2 generation 在整个过程中保持不变，包括 SQLite bytes 与文件资源元数据。通用复制器只在 legacy adoption 完成安全复制后强化 legacy source；V2 schema upgrade 不再触碰 active source 的 file-protection 或 backup xattr。失败或进程中断时，pointer 仍指向旧 generation；重试使用 journal 恢复，不把未验证 copy 暴露给 App。

当前 core backfill 在 inactive copy 内使用单一事务。它对冻结的五年 fixture 已有 Simulator 回归证据；更大规模、低端真机和最终阈值仍属于发布性能门禁，不能从本 ADR 推断已通过。

## 7. UI 与 Release catalog 边界

方案页明确区分 loading、error、empty、current、upcoming、history、draft 和 review issue。UI 只消费 `CoreRegimenOverviewSnapshot`，不得再用 `endedAt == nil` 自行判断 current。

编辑流程为：编辑内存内容 → 显式保存草稿 → 查看变更前/后组成与关联影响 → 带 token 封存 → 从 repository 重读。

已保存草稿在方案页有“继续编辑”入口。克隆 sealed 版本时使用全新的 item/schedule identity，但完整保留 catalog ID/version、product snapshot 与结构化 schedule；重开既有 draft 时保持该 draft 自己的 child identity。

Accessibility 字号下底部导航使用明确的 2×2 布局，保留四个文字标签、选中状态和至少 44 pt 命中区。页面正文继续响应 Accessibility 5；持久导航的视觉字号上限为 Accessibility 2，以保证 320×568 上四个标签完整可见且不吞没内容，VoiceOver 标签不受该视觉上限影响。

档案页的“方案版本”真实数量以 canonical、`sealed`、未归档的 `RegimenPlanVersionRecord` 为准，并用其 civil start date 参与档案范围；draft 不算正式版本。legacy `RegimenVersion` 只保留给迁移兼容和 DEBUG JSON 原型，原型可导出条数必须与用户可见的本机真实数量分开计算，不能暗示 canonical 方案已被该原型完整导出。

主页面 read model 对版本、组成、计划与问题单设置显式上限；preview/seal 对历史 sidecar 使用 10,000 条 fail-closed 上限。达到上限时拒绝继续，而不是截断后给出不完整影响或部分重关联。最终规模阈值仍需 Batch 2 性能门禁冻结。

正式 catalog seed 的来源、稳定 ID、许可证与人工复核未完成前：

- Release catalog 固定为空；
- DEBUG placeholder 不得进入 Release 或正式持久化事实；
- Release 明确显示“正式药品目录尚未提供”；
- 用户始终可以按药盒、处方或自己的记录原样创建自定义条目。

## 8. 外部方案调查

实施前评估了以下成熟方案：

- [Apple SwiftData SchemaMigrationPlan](https://developer.apple.com/documentation/swiftdata/schemamigrationplan) 与 [MigrationStage](https://developer.apple.com/documentation/swiftdata/migrationstage)：继续采用系统 schema/migration 能力，但外层仍保留 generation copy + pointer switch，以满足 source 不变和 fail-closed 合同。
- [Foundation Calendar](https://developer.apple.com/documentation/foundation/calendar)：足以做显式时区转换；持久化仍由项目自己的两类事实承担，避免把 `Date` 当 civil date。
- [GRDB.swift](https://github.com/groue/GRDB.swift)：成熟且事务/迁移能力强，但会引入新的持久化栈和第三方运行时依赖，本批不采用。
- [davedelong/time](https://github.com/davedelong/time) 与 [SwiftDate](https://github.com/malcommac/SwiftDate)：日期抽象较完整，但不能替代已冻结的 provenance、关联和 generation 合同，本批不采用。
- [swift-clocks](https://github.com/pointfreeco/swift-clocks)：适合可控异步时钟；本批核心是 civil date 与持久化，待提醒模块再评估。
- [Apple FHIRModels](https://github.com/apple/FHIRModels)：互操作模型远超本地个人记录范围，且容易引入临床/处方语义，本批不采用。

因此本批继续使用 Foundation + SwiftData，不新增第三方运行时依赖。

## 9. 明确不在本批完成

- occurrence 生成、执行事实、提醒调度与通知权限；
- 库存 ledger、lot 分配和 reconciliation；
- 正式药品 catalog seed；
- 删除/反转 sealed 方案的产品流程；
- CloudKit、远程配置、遥测或任何 App 发起的网络请求；
- 真机文件保护、系统备份恢复、动态无网络和低端设备性能结论。

这些能力必须继续遵守 ADR 0002，并在实施前独立立项、调查和审查。

## 10. 完成门禁

- V2 source bundle hash 在升级前后不变，active pointer 只在 V3 验证后切换。
- civil date、未来生效、半开边界、跨时区历史和零/多候选有确定性测试。
- 草稿组成持久化，sealed 旧版本不被覆盖，跨版本 item identity 复用被拒绝。
- 历史影响 preview token 在 intervening write 后失效，封存事务重算关联。
- 运行时 missing/ambiguous 问题单创建与 resolved 清理、canonical Journey/Lab 读取有回归测试。
- Journey/Lab DTO 保留 canonical timestamp；切换 fallback/device time zone 不改变已有记录的当地日期。
- civil-day 化验查询直接命中 frozen local date；损坏 sidecar fail-closed，只有无 sidecar legacy 记录允许显式 fallback time zone。
- HRT 开始日 legacy/canonical 三事实同 revision，Today 从 civil-date fact 读取。
- 历史插入重连紧邻后续版本；克隆组成保留 catalog provenance 与 schedule。
- Release catalog/源码/entitlement 静态边界通过。
- 320×568、390×844、430×932、768×1024、横屏和 Accessibility 5 有真实渲染证据。
- 独立 reviewer 审查实际 diff、测试、合同与未验证项；若修复，使用全新 reviewer 复审。
