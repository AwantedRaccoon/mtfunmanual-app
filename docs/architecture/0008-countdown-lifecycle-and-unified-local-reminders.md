# ADR 0008：Countdown 生命周期与统一设备提醒

- 状态：Accepted for Batch 3 completion
- 日期：2026-07-24
- 适用版本：App 1.0，iOS / iPadOS 17+

## 1. 目的与边界

本 ADR 补齐 Batch 3 尚未完成的 Countdown：稳定目标日期、完整生命周期、Today 显示选择、设备本地提醒、Journey 历史与删除/替换边界。

本批不实现库存、App Lock、最近任务遮挡、正式导出/恢复、CloudKit、APNs、远程内容、遥测或第三方运行时依赖。Countdown 不推断事件类型，不与 HRT 效果进度自动关联，也不产生医疗结论。

## 2. 采用与放弃的方案

采用 Apple `Foundation.Calendar`、`UserNotifications` 与 SwiftData，并在项目内建立小型、可测试的 Countdown 领域模块。沿用现有 generation copy、migration journal、pointer、revision、operation receipt、全局 receipt ledger、串行提醒 runtime 与 Recovery epoch。

实现前只读调查评估了以下候选：

- `pointfreeco/swift-clocks`（MIT，维护中）：适合测试时钟，但不解决 civil date、通知权限、pending budget、调和或 generation 迁移；项目已有时间和 client 注入，因此不引入。
- `StanfordSpezi/SpeziNotifications`（MIT，维护中）：是 Spezi 生态包装层，仍不能提供本项目的预算、公平性、Recovery、事实/投影和迁移合同；依赖面大于收益，因此不引入或移植。
- `malcommac/SwiftDate`（MIT，最近正式更新较旧）：日期抽象范围过宽且可能与已冻结语义冲突；Foundation 已提供明确 Calendar 与 DST API，因此不引入。

App 继续没有第三方运行时依赖，也不新增网络能力。

## 3. Schema V6 与旧数据

不得修改 `AppSchemaV1` 已冻结的 `CountdownRecord` 形状。新增 additive `AppSchemaV6CountdownLifecycle`，包含：

- `CountdownStateRecord`：稳定 ID、原始/温和名称、canonical target civil date、生命周期、到期后显示模式、Today 显示选择、终态时间、最新事件和迁移核对状态；
- `CountdownLifecycleEventRecord`：append-only create/edit/visibility/reminder/continue/complete/archive/delete/replace 事件链；
- `CountdownReminderRuleRecord`：提醒 intent，不是系统 pending request；
- `CountdownNotificationCoverageRecord`：Countdown 域的可重建调度投影；
- `CountdownLifecycleBackfillState`：冻结 legacy `Date` 转 civil date 时使用的 assumed IANA zone。

V5 → V6 必须在 inactive generation 上完成 lightweight migration、幂等 backfill、关系/revision/digest 校验、释放并重开校验，最后切换 `6.0.0` pointer。失败时 V5 pointer 保持不变；`.preparing` 中断复用同一 target generation ID，精确重建该 generation，不产生 orphan。

Legacy target `Date` 使用既有 core backfill 已冻结的 assumed zone 转换一次，并标记 `migrationAssumed`。设备旅行或后续改时区不会重写 canonical target。

若 legacy 中出现多个未归档 Countdown 或矛盾 flags，不得静默选择最新：全部标记 `requiresReview = true`、关闭 Today 显示与提醒，并给出可见核对入口。

## 4. 生命周期合同

持久生命周期：

- `active`：当前 Countdown；
- `completed`：用户明确“已经完成，收进旅程”；同时记录完成/归档时刻；
- `archived`：用户明确“未完成，收进旅程”；记录归档时刻；
- `deleted`：从当前资料中移除，不进入 Journey 正常历史。

一个 dataset 最多一个非 terminal Countdown。`showInToday = true` 只允许属于该 active Countdown；隐藏 Today 不会允许第二个后台 active Countdown。

`beforeTarget`、`targetDay`、`overdue` 是 `current CivilDate` 与 target 的确定性派生状态，不写库。达到目标日不会自动完成、归档或删除。

Active 的到期后显示模式：

- `awaitingDecision`：显示“目标日到了”，要求用户选择；
- `countingUp`：目标日为 0，次日显示“已经过 1 天”，之后继续增加。

用户在目标日或之后可以继续计日。改目标日会把模式重置为 `awaitingDecision`。完成只允许在目标日或之后；未完成归档允许随时执行。

删除 active Countdown 时，同一事务：

1. 取消 Today 与 reminder intent；
2. 清空 canonical state 中的标题、温和标题和 target；
3. 删除 legacy payload row；
4. 写入不含敏感正文的 tombstone、delete event、receipt、revision；
5. 如为“删除并建立新的 Countdown”，在同一事务创建替代项，失败则全部回滚。

删除不承诺取证级擦除。inactive generation、系统备份或用户已导出文件可能仍保留历史副本；App 不能替用户删除系统备份或导出文件。完整 generation retention/purge 属 Batch 6 的独立决策。

## 5. 写入、幂等与审计

每个用户意图使用 typed command，携带稳定 `operationID`、canonical command digest、expected Countdown ID 与 expected latest event ID。

- 相同 operation + 相同 digest 返回既有结果；
- 相同 operation + 不同 digest 拒绝且零业务写入；
- stale expected event 拒绝且零业务写入；
- state、event、legacy compatibility mirror、reminder intent、historical time、receipt、receipt ledger、record revision 在一个 SwiftData transaction 中提交；
- 提醒 reconcile 是事务后的可重建副作用，失败不回滚已提交的业务事实，但 coverage 必须变为可见错误。

生命周期事件使用完整 `HistoricalTimestamp`，association 为 `notApplicable`；Countdown 不制造“缺少当时 HRT 方案”的核对项。Journey 只投影 `completed` 与 `archived` 的有意义路标，不新建第二份持久化 timeline。

## 6. Target 与提醒时间语义

Target 是 Gregorian `CivilDateFact`，没有 instant。剩余/已过天数只计算两个 civil date 的 Gregorian day distance。

1.0 的 Countdown reminder 冻结为：

- `floatingLocalV1`；
- 用户选择提前 `0...365` 天；
- 用户选择当地小时/分钟，默认 `09:00`；
- 每次 reconcile 使用当前明确 IANA zone，把 `target - leadDays + wall clock` 解析为唯一 future instant；
- DST gap 使用 strict 解析并 fail closed，要求用户调整，不静默平移；
- DST overlap 固定选择第一次；
- 已过去的 fire time 不补发，也不退化为“立即提醒”；
- continue/complete/archive/delete 后不再保留 Countdown pending request；
- retarget 后按相同 lead/time 重新计算。

提醒 intent 与系统权限/coverage 分离。权限拒绝时保留 intent，不反复弹 prompt。通知正文始终中性：

- 标题：“给自己留一点时间”
- 正文：“打开 App 查看下一件事。”

原始名称与温和名称都不进入锁屏 payload。温和名称只用于 App 内温和模式显示。

## 7. 统一 60 条设备提醒预算

不得新增第二个 Countdown reconciler。Schedule occurrence 与 Countdown candidate 由同一个 runtime、请求序号和 Recovery epoch 读取、规划、提交与回读。

已知 owned namespaces：

- `unmanual.exec.v1.`
- `unmanual.countdown.v1.`

`foreign` 指当前 App pending requests 中不属于任一已知 owned namespace 的请求；它不代表其他 App 的通知。旧 exec request ID 保持不变。

总保守预算仍为 60。规划顺序：

1. 先形成每个 schedule rule 的下一项和当前 Countdown 的最多一项；
2. 按 `fireAt → source kind → semantic key` 稳定排序并裁剪；
3. 再用剩余容量填入更远的 schedule occurrence；
4. coverage 必须分别报告 schedule 与 Countdown 是否被选择，不能因某一域关闭而把另一域误报为 disabled。

Reconciler 只删除两类 owned request，绝不使用 remove-all。每次 remove/add 后回读；foreign 在调和期间增长时重新裁剪。重复 ID、add 失败、remove 未生效、readback 不一致或 epoch 过期均 fail closed，清除全部 owned pending 并保留业务 intent。

Recovery 清理两类 owned pending。清理 pending 不会追溯移除已经投递、仍停留在通知中心的内容；用户文案不得宣称会清除系统通知历史。

## 8. Today、Journey 与温和模式

Today 只在 active 且 `showInToday = true` 时显示 Countdown；未设置或关闭显示时不画空卡。

- 未来：“还有 N 天”；
- 目标日且待决定：“目标日到了”；
- 继续计日：“已经过 N 天”；
- completed / archived / deleted：不显示。

温和模式开启时，可见文本和 VoiceOver 均使用温和名称；没有温和名称时使用中性的“私人日期”，不能从辅助功能树泄露原始标题。

到期决策页提供：

1. “已经完成，收进旅程”；
2. “继续计算已经过了多久”；
3. “换一个目标日”。

“未完成，收进旅程”和“删除并建立新的目标日”放在次级管理区，并在确认前解释影响。

Journey 提供当前/历史 Countdown 台账入口；统一时间线只显示完成/归档路标。历史详情可回看目标日、最终结果、完成/归档时间、改期日期链与当时 reminder intent，不显示已删除项。

## 9. 验证门禁

完成前必须覆盖：

- V5 → V6 source 不变、failpoint、同 target 重试、幂等、assumed-zone、多 active/review、receipt/revision/digest/关系篡改；
- create/edit/show/continue/retarget/complete/archive/delete/replace 与所有非法转换；
- same-operation replay、digest conflict、stale expected event、事务故障零部分写；
- leap day、月/年边界、目标日 0 / 次日 +1、旅行换区、DST gap/overlap；
- show=false Today 隐藏，terminal/deleted 过滤，Journey 分页与详情；
- schedule + Countdown 联合预算、foreign 0/59/60/61、动态增长、add/remove/readback failure、两个前缀 Recovery 清理、中性 payload；
- permission 全状态、coverage、换日/显著时间/时区变化重新调和；
- 320×568、390×844、430×932、768×1024、844×390 横屏和最大辅助字号；
- 返回、取消、读取错误、保存错误、重复点击、重新进入、VoiceOver、外接键盘、安全区和减少动态效果。

Simulator 自动化只能证明代码、迁移和调和 harness。真机锁屏预览、Focus、Scheduled Summary、实际投递、文件保护、系统备份恢复与跨设备行为继续保留到发布候选真机门禁。
