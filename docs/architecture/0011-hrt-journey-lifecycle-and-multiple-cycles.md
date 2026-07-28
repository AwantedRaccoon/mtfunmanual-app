# 0011：HRT 历程暂停、恢复与多周期

- 状态：Accepted
- 日期：2026-07-26
- 适用版本：App 1.0 / Schema V9 HRT Journey Lifecycle
- 前置合同：[0002：Batch 0 本地后端合同冻结](0002-batch-0-contract-freeze.md)
- 时间与方案核心：[0005：时间事实与方案版本核心](0005-time-and-regimen-core.md)
- 首次设置：[0010：正式首次设置与 V8 安全采用](0010-formal-onboarding-and-v8-adoption.md)

## 1. 决策与边界

本模块把 V3 已存在但尚未形成产品闭环的
`HrtJourneyProfileRecord` / `HrtPeriodRecord` 接入正式的暂停、恢复、多周期读写与
Today 展示。

HRT 历程周期是日期型个人事实，不是处方、方案或执行事实。记录历程暂停不会暗中：

- 结束、归档或改写 sealed 方案；
- 删除、隐藏或重解释既有执行记录；
- 开关方案提醒或移除已安排的通知；
- 改变化验、状态或旅程记录的历史方案关联。

产品规划 6.2 的历程暂停/恢复与 6.4 的计划暂停/恢复是两个不同控制面。后者涉及
occurrence、既有执行事实、本地通知调和和历史影响预览，必须另立 ADR 和显式用户
操作；本模块只在界面准确说明该边界，不把两者隐式耦合。

## 2. 日期和状态语义

所有开始、暂停和恢复日都使用 `CivilDateFact`，不得伪造午夜 instant。

周期统一使用半开区间 `[start, end)`：

- `start` 是这一段的第一个活跃日；
- `end` 是第一个暂停日；
- 无 `end` 表示当前仍在这一段；
- 暂停区间位于上一段 `end` 与下一段 `start` 之间。

例如 `[2026-07-01, 2026-07-11)` 表示 7 月 1 日至 10 日属于该周期，7 月 11 日
开始暂停；下一段 `[2026-07-15, nil)` 表示 7 月 15 日恢复。

不额外持久化可漂移的 active/paused 布尔值：

- 没有 profile：尚未设置；
- 有且仅有一个 open period：active；
- 有 profile 且没有 open period：paused。

暂停日必须晚于当前周期开始日；恢复日必须晚于上一暂停日。date-only 粒度无法表达
同一天内的有效暂停，因此同日暂停/恢复拒绝并要求用户修正，不静默建立零暂停日的
相邻周期。暂停/恢复只记录已发生事实，日期不得晚于命令提交时冻结的当地日期。

## 3. 展示语义

Today 同时表达：

- 从首次开始计算的自然日；
- active 时当前连续周期的自然日；
- 当前是 active 还是 paused；
- 已记录周期数；
- 最近一次 sealed 方案变更距今多久。

“从首次开始”是自然时间，包含暂停日；它不是累计使用日、依从率或身体变化进度。
App 1.0 不自行增加“累计活跃天数”指标。

active 主信息为“本周期第 N 天”，并显示“从首次开始第 M 个自然日”；paused 主信息
为“HRT 历程当前已暂停”，并显示暂停起始日与首次开始后的自然时间。每个状态都提供
明确的管理入口，不靠颜色表达。

统一时间线只投影用户实际提交的 started、first-start-corrected、paused 与 resumed
事件，按事件保存的 `HistoricalTimestamp` 稳定分页，并在摘要中显示对应的 transition
civil date。迁移生成的 `migratedSnapshot` 是采用既有资料的技术事实，不冒充用户动作，
因此不进入普通时间线。温和模式开启时，时间线标题与详情使用“时间坐标”等中性措辞，
不得暴露 `HRT` 字样或用户填写的生命周期备注。

编辑器只有一个当前主动作：

- active：记录暂停；
- paused：记录恢复；
- 未设置：记录首次开始日。

转换页先显示所选 civil date、将形成的区间和不联动方案/提醒的边界，再确认写入。
备注可选，不要求解释医疗原因。取消零写入；陈旧页面或并发变化拒绝并要求重新读取。

首次开始日只在尚未形成多个周期时允许直接修正，并同时修正首个周期。已有暂停/恢复
历史后的任意周期纠错不在本模块中原地覆盖；后续须采用带影响预览的 append-only
纠错合同。

## 4. V9 数据与审计

`AppSchemaV8Onboarding` 保持冻结。additive `AppSchemaV9HrtJourneyLifecycle`
新增：

- `HrtJourneyLifecycleEventRecord`：append-only 的 migrated snapshot、started、
  first-start-corrected、paused、resumed 事件；
- `HrtJourneyLifecycleBackfillState`：V8 → V9 的来源事实摘要、完成标记和幂等门禁。

事件保存稳定 event/operation ID、前序事件、目标 period、转换 civil date、可选备注、
提交时 `HistoricalTimestamp`、变更前/后的 HRT facts digest。最新事件的
`postFactsDigest` 必须与当前 profile/period 投影一致。V9 facts digest 同时承诺
legacy `HRTProfile` 的稳定 ID、兼容日期 instant、active-period 兼容 instant 与
`createdAt`；不能通过同时改写 canonical facts、legacy mirror 和普通 revision
绕过关系验证。

原生 started/pause/resume 命令携带：

- `operationID` 与 command digest；
- `eventID`；
- `expectedLatestEventID`；
- pause 时的 `expectedOpenPeriodID`，resume 时的 `expectedLastPeriodID`；
- civil transition date、可选备注和提交 timestamp。

同 operationID + 同 digest 返回既有结果；同 operationID + 不同 digest、陈旧 head、
陈旧 period 或非法转换均零写入拒绝。period、legacy mirror、event、receipt、receipt
ledger、RecordRevision 与 dataset metadata 在同一 SwiftData transaction 使用同一
local revision；revision 也在该 transaction 内预留。

冻结 legacy `HRTProfile` 不能表达 paused。暂停时保留：

- `startDate`：首次开始日的兼容 instant；
- `activePeriodStartDate`：最近一段开始日的兼容 instant。

不得写 sentinel、未来值或用首次开始日回退伪装 active。恢复时才把
`activePeriodStartDate` 镜像为新周期开始日。所有正式状态和 UI 只读 canonical
lifecycle snapshot。

## 5. 完整性与迁移

V9 bootstrap 在 inactive generation copy 中完成 lightweight migration、幂等
backfill、关系/digest/revision/receipt 校验、附件树与文件保护校验，最后切换
`9.0.0` pointer。V8 source 在切换前保持不变。

启动与迁移验证至少保证：

- legacy profile、journey profile 各至多一条；
- profile 与 period 要么同时不存在，要么同时存在；
- 最多 512 个 period，超过显式产品上限 fail closed；
- 日期三元组全有或全无且可构造；每段 `start < end`；
- 按 start + stable ID 排序后不重叠、不相邻；open period 至多一个且只能是最后一段；
- first-ever start 等于最早 period start；
- event ID、operation ID 唯一，事件形成一条无环单链；
- migrated snapshot 准确承诺 V8 facts；每个原生命令事件有一一对应 receipt；
- 每个 receipt 的 command digest 必须由对应事件与冻结 facts 重算一致，损坏资料不能
  通过 exact replay 绕过启动时的 lifecycle 完整性验证；
- 事件、backfill marker、period/profile、receipt/ledger 与 RecordRevision 一一对应；
- 最新事件 post digest 与当前 HRT facts 一致。

V8 同时保存了 legacy Date instant 与 canonical civil date，但没有保存最初命令使用
的时区 ID。V9 迁移不得猜测当时的时区：迁移根把这两个既有值作为一组冻结事实纳入
digest；V9 原生命令一旦保存 `HistoricalTimestamp`，legacy mirror 必须严格等于该
事件时区下 civil date 的正午 instant。暂停时最近周期开始日继续保留在 legacy
`activePeriodStartDate`，不得回退到首次开始日。

任何损坏、重复、超限或关系不一致进入 Recovery，不把异常资料当作空状态或 active。

## 6. 复用方案调查

调查日期为 2026-07-26：

- [Apple CareKit](https://github.com/carekit-apple/CareKit) 采用宽松许可证并提供本机
  versioned store、task schedule 与 outcome 分离。借鉴其“计划和结果分离、变更可
  追溯”的思想，但不引入依赖：CareKit 会增加第二套 Core Data/Combine/UIKit 数据栈，
  与当前 SwiftData generation/revision/digest 重复，也不是 HRT journey cycle 模型。
- [Apple FHIRModels](https://github.com/apple/FHIRModels) 使用 Apache-2.0，适合
  FHIR 互操作资源，不提供本项目所需的本地事务、generation 或私人历程交互。把个人
  历程强行塑造成临床 MedicationStatement 还会扩大医疗语义，拒绝引入。
- [GRDB.swift](https://github.com/groue/GRDB.swift) 使用 MIT，维护活跃且提供 SQLite
  transaction/migration/concurrency；但替换既有 SwiftData 底座会重写已验证的 V1–V8
  迁移和隐私门禁，收益不足以覆盖复杂度。
- [davedelong/time](https://github.com/davedelong/time) 使用 MIT，提供类型安全日期
  运算；它不解决本项目的审计、幂等或迁移，现有 `CivilDateFact` 已覆盖所需日期粒度。
- [SwiftDate](https://github.com/malcommac/SwiftDate) 使用 MIT，功能范围远大于当前
  civil-date 区间需求，会增加第三方供应链与维护面。

结论：不复制候选代码，也不新增第三方运行时依赖；在现有 SwiftData /
`CivilDateFact` / revision / receipt 基础上实现薄的 lifecycle repository 与
validator。

## 7. 完成门禁

- domain：半开区间、active/paused、自然日和同日/未来边界测试；
- repository：start、pause、resume、两个以上周期、重放、冲突、stale、失败回滚和
  revision 原子性；
- migration：V8 source 不变、pointer-last、中断恢复、backfill 幂等、重开与篡改
  fail-closed；
- UI：empty/active/paused/多周期/loading/error/saving，取消零写入，重进后状态准确；
- timeline：只纳入用户生命周期事件，迁移 snapshot 不伪装为用户动作；普通/温和模式
  投影、稳定分页和无备注泄漏均有回归；
- render：320×568、390×844、430×932、768×1024、844×390，以及
  320×568 Accessibility 5；
- accessibility：44 pt、持久标签、VoiceOver 名称/值/提示、动态字体、减少动态效果；
- build/test：完整普通测试、UI 测试、Release 合同、generic Simulator build 与
  项目专属 Simulator smoke；
- deferred：任意历史周期 append-only 纠错、方案级暂停/提醒调和、真机文件保护与
  系统备份恢复、最低设备性能和完整人工辅助技术矩阵。
