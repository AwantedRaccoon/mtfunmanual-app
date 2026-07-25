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

## 3. Schema V6、V7 与旧数据

不得修改 `AppSchemaV1` 已冻结的 `CountdownRecord` 形状。`AppSchemaV6CountdownLifecycle` 也作为已经落盘的迁移边界冻结，包含：

- `CountdownStateRecord`：稳定 ID、原始/温和名称、canonical target civil date、生命周期、到期后显示模式、Today 显示选择、终态时间、最新事件和迁移核对状态；
- `CountdownLifecycleEventRecord`：append-only create/edit/visibility/reminder/continue/complete/archive/delete/replace 事件链；V6 已持久化字段不得为了增强审计而原位追加；
- `CountdownReminderRuleRecord`：提醒 intent，不是系统 pending request；
- `CountdownNotificationCoverageRecord`：Countdown 域的可重建调度投影；
- `CountdownLifecycleBackfillState`：冻结 legacy `Date` 转 civil date 时使用的 assumed IANA zone。

完整性复核新增纯 additive `AppSchemaV7CountdownIntegrity`：

- `CountdownCommandAuditRecord`：对新写入保存 typed command v2、私有标题 commitment、target / Today / reminder / today / review / replacement 语义、事件时间 commitment、事件语义摘要、前后 materialized facts 摘要、终态提醒快照与前序 audit 摘要；
- `CountdownV6AuditCheckpointRecord`：只对无法追溯 typed command 的既有 V6 事件前缀保存边界、事件数、链摘要、升级时 materialized facts 摘要和提醒准入状态；
- `CountdownIntegrityBackfillState`：冻结首次 V7 完整性集合的来源版本、数量与集合摘要。

V5 直接迁移到 V7；既有 V6 通过 V6 → V7 lightweight migration 进入新的 inactive generation。两条路径都必须先复制 SQLite bundle 和 generation 的完整 `Files/` 树，拒绝 symlink 与非 regular leaf，在目标 generation 上完成 backfill、关系/revision/digest、附件恢复与字节 hash 审计，释放并重开后才把 pointer 切到 `7.0.0`。失败时旧 pointer 和 source durable bytes 保持不变；`.preparing` 中断复用 journal 冻结的 target generation ID。只在内存容器直接运行 backfill 不能替代真实 generation 迁移证据。

已经完成的 V6 lifecycle backfill marker 只证明迁移任务完成，不冻结当时的 state/event/reminder 数量；合法的后续 edit/delete 不得因数量变化在重开时误入 Recovery。首次迁移时的 legacy → state/event/reminder 一一对应数量检查仍保留为单次迁移后置条件。

Legacy target `Date` 使用既有 core backfill 已冻结的 assumed zone 转换一次，并标记 `migrationAssumed`。迁移事件必须以 `subsecond` 精度保留 legacy `createdAt` / `archivedAt`，使 event、canonical state、reminder 与 receipt 引用同一时间事实；不得只截断事件时间而保留其他记录的亚秒。设备旅行或后续改时区不会重写 canonical target。

若 legacy 中出现多个未归档 Countdown 或矛盾 flags，不得静默选择最新：全部标记 `requiresReview = true`、关闭 Today 显示与提醒，并给出可见核对入口。

V6 中已经启用的 Countdown reminder 没有可验证的 typed command 来源。升级到 V7 时保留其数据库 intent，但标记 `needsUserConfirmation`、停止产生系统通知候选并显示明确说明；只有用户在 V7 显式更新或替换该 Countdown 后，新的 command audit 才重新开放调度。普通 review/complete/archive/delete 事件不能绕过这道门禁。

## 4. 生命周期合同

持久生命周期：

- `active`：当前 Countdown；
- `completed`：用户明确“已经完成，收进旅程”；同时记录完成/归档时刻；
- `archived`：用户明确“未完成，收进旅程”；记录归档时刻；
- `deleted`：从当前资料中移除，不进入 Journey 正常历史。

一个 dataset 最多一个非 terminal Countdown。`showInToday = true` 只允许属于该 active Countdown；隐藏 Today 不会允许第二个后台 active Countdown。

任何 lifecycle 上只要仍有 `requiresReview = true` 的旧记录，写层就必须阻止新建 Countdown；这里同时包括直接创建与“删除并建立新的 Countdown”原子替换，不能只依靠 UI 隐藏入口，也不能只检查将被删除的 active 记录。门禁必须在事务准备前与事务内各核对一次；复核完成后才重新开放创建。

`beforeTarget`、`targetDay`、`overdue` 是 `current CivilDate` 与 target 的确定性派生状态，不写库。达到目标日不会自动完成、归档或删除。

Active 的到期后显示模式：

- `awaitingDecision`：显示“目标日到了”，要求用户选择；
- `countingUp`：目标日为 0，次日显示“已经过 1 天”，之后继续增加。

用户在目标日或之后可以从 `awaitingDecision` 进入一次 `countingUp`；同一 target 周期已经在 `countingUp` 时重复执行 continue 必须以非法转换拒绝且零写入。改目标日会开始新的 target 周期并把模式重置为 `awaitingDecision`，新目标日到达后可以再次选择继续计日；只改名称、Today 可见性或提醒不能重置该门禁。完成或归档必须把 canonical state 与 legacy mirror 一起收敛回 `awaitingDecision`，避免终态保留互相矛盾的模式；completed 不得进入复核队列，active / archived 只有最新事件仍为 `migratedSnapshot` 时才可处于未解决 legacy review，`reviewResolved` 后必须回到正常状态。归档时间必须绑定直接 `.archived` / `migratedSnapshot` 终态事件；`keepArchived` 保留原归档时间时，必须绑定其 migrated predecessor，不能重算 state 与 legacy digest 改写审计时间。历史详情解析终态 civil time 时必须按当前 lifecycle 与 latest event kind 选择事件；latest 为 `.reviewResolved` 的 `keepArchived` 必须沿 `previousEventID` 读取真正的归档 predecessor，禁止只用 instant 相等查找，因为设备时钟回拨或同一时刻复核可让多个事件共享 instant 但保存不同 IANA zone。完成、直接归档和 `keepArchived` 的终态 event 必须冻结与 state 相同的 reminder snapshot，供历史详情审计。关系 validator 从 create 或可判定的改期事件开始按 root → leaf 重放每个 target 周期的模式，并与最终 state 核对；legacy `migratedSnapshot` 没有足够事件载荷证明回填前模式，只在没有后续可判定模式事件时保留兼容。完成只允许在目标日或之后；未完成归档允许随时执行。带 `today` 的命令必须与 `HistoricalTimestamp.localDate` 一致，不能把调用方当地日和记录时间事实混用。

设备系统时间可能先错误地跳到未来，再被用户或系统校正。`HistoricalTimestamp` 如实保存每次动作捕获到的 wall-clock 事实，因此后写事件的 instant 不保证大于创建事件；逻辑顺序由 append-only event link 与 local revision 决定。关系校验不得因合法时钟回拨制造“当次成功、下次启动 Recovery”的自损路径。

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
- V7 新写入由 `CountdownCommandAuditRecord` 保存原始 typed command digest，并把它与 event timestamp/语义、前后 materialized facts、终态 reminder snapshot 和前序 audit 链共同封存；receipt 直接引用该 command digest。启动校验从 audit 承诺与持久事实独立重算，不能通过联合修改 state/event/legacy/reminder 后重算普通 revision 来伪造合法命令；
- 新建、更新和原子替换的审计必须把私有标题 commitment、target、Today 显示与 reminder intent 重新投影到当前 materialized facts；replace 的主/替代事件交叉链接与 primary command digest 必须一致。完成/归档/删除等终态 audit 必须冻结与 state 一致的 reminder snapshot；
- V7 原生 `migratedSnapshot` 使用同一 command-audit v2；从 V6 升级的历史前缀只由 V6 checkpoint 如实证明“升级时观察到的完整前缀与事实”，不伪装成拥有旧 typed command。checkpoint 之后的所有事件必须接入新的 audit 链；
- 非删除 legacy compatibility mirror 的 target `Date` 必须使用事件链中最近一次真正建立或改变 target 的事件所记录 IANA zone 还原为 civil date，并与 canonical target 精确相等；后续只改标题、可见性或提醒时不能改用较晚事件的时区。普通 `.created` 根还必须同时锚定 canonical state 与 legacy mirror 的 `createdAt`，即使攻击者同步重算两条 record revision 也不能改写创建事实；
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

Reconciler 只删除两类 owned request，绝不使用 remove-all。每次 remove/add 后回读；foreign 在调和期间增长时重新裁剪。调和初始回读即使已经超过 60，也先分离 foreign / owned 并删除当前容量外的 owned：59 条 foreign + 2 条匹配 owned 必须收缩并保留 1 条 authoritative owned，60 条 foreign + 1 条 owned 必须只删除 owned 并报告预算受限，而不是误报安排失败。最终回读以当时的 foreign 数量重新冻结 authoritative owned 前缀：有界收缩能够使总数不超过 60 时，必须保留仍被允许且回读匹配的前缀，并按 schedule / Countdown 各自报告确认数量、`limitedByBudget` 与首个未覆盖时间，不能因为它少于初始计划就清除全部 owned request。只有 foreign 本身超过预算、有界收缩仍无法满足总预算，或出现重复 ID、add 失败、remove 未生效、readback 不一致、epoch 过期时才 fail closed，清除全部 owned pending 并保留业务 intent。一个域的规划错误不能被另一个域成功收缩时的预算变化错误码覆盖。只有 owned 清理已经回读确认且 coverage 持久化成功的请求才算 settled，才允许刷新 Today；清理无法确认时必须保留可见错误，不能伪装成 disabled。

Recovery 清理两类 owned pending。清理 pending 不会追溯移除已经投递、仍停留在通知中心的内容；用户文案不得宣称会清除系统通知历史。

## 8. Today、Journey 与温和模式

Today 只在 active 且 `showInToday = true` 时显示 Countdown；未设置或关闭显示时不画空卡。

- 未来：“还有 N 天”；
- 目标日且待决定：“目标日到了”；
- 继续计日：“已经过 N 天”；
- completed / archived / deleted：不显示。

温和模式必须有正式可达的本地设置。开启时，可见文本和 VoiceOver 均使用温和名称；没有温和名称时使用中性的“私人日期”，不能从辅助功能树泄露原始标题。设置保存期间必须阻止用户进入仍可能呈现旧名称的页面；写入失败要回滚开关并给出可见错误。

到期决策页提供：

1. “已经完成，收进旅程”；
2. “继续计算已经过了多久”；
3. “换一个目标日”。

“未完成，收进旅程”和“删除并建立新的目标日”放在次级管理区，并在确认前解释影响。

Journey 提供当前/历史 Countdown 台账入口；统一时间线只显示完成/归档路标。历史详情可回看目标日、最终结果、完成/归档时间、改期日期链与当时 reminder intent，不显示已删除项。历史动作时间使用事件保存的 civil date/time，不按查看时设备时区重新解释。详情中的名称、目标日、生命周期、终态时间、提醒快照与事件链只能来自本次成功读取并通过校验的 detail；Navigation 路由只携带稳定 ID。读取或关系校验失败必须显示通用标题、“未能核对”、错误与重试，并清空过期投影；不能继续展示路由快照或上一次成功读取中的任何事实，不能把损坏资料呈现为空记录，也不能永久停留在“读取中”。

Journey 历史与 legacy 复核分页使用不可变排序键组成的 keyset cursor，并以 `limit + 1` 判断下一页。每次 fetch 都必须有明确 `fetchLimit`；不得先读取整张表的 ID、依赖 offset，或在 actor 内保留会话级全量记录集合。cursor 类型、日期有限性与域必须校验，错误域或损坏 cursor 必须拒绝。

台账头部只能把已经加载的分页数量表述为精确值；当 `nextCursor` 非空时必须显示“至少 N 项”，不能把首屏 20 项误写成总数。

Today 主投影或档案摘要读取失败时，依赖该投影的事实、空状态与操作入口必须一起隐藏，只显示可见错误和重试；不得继续呈现默认空快照或上一次成功快照。档案摘要错误与温和模式偏好错误是两个独立状态，保存温和模式不能清除仍未恢复的档案读取错误。

## 9. 验证门禁

完成前必须覆盖：

- V5 → V7 与 V6 → V7 source 不变、failpoint、同 target 重试、幂等、assumed-zone、多 active/review、receipt/revision/digest/command-audit/checkpoint/关系篡改；
- generation 附件树完整复制、活动附件逐字节审计、symlink/非 regular leaf 拒绝、附件失败时 pointer 不切换；
- V6 已启用 reminder 升级后不产生候选，V7 显式 update/replace 后才重新准入；合法 lifecycle edit/delete 后 completed backfill marker 继续有效；
- create/edit/show/continue/retarget/complete/archive/delete/replace 与所有非法转换，包括同一 target 重复 continue、continue → retarget → 新 target continue、continue 后完成/归档、任意 archived review 未解决时直接创建或原子替换零写入，以及重新计算 state/legacy digest 伪装逾期模式、legacy target 或普通创建时间；改期后再做跨时区内容编辑仍使用最近一次改期事件的时区解释 legacy target；
- same-operation replay、digest conflict、stale expected event、事务故障零部分写；
- leap day、月/年边界、目标日 0 / 次日 +1、旅行换区、DST gap/overlap；
- show=false Today 隐藏，terminal/deleted 过滤，Journey `limit + 1` keyset 分页、并发插入稳定性、损坏/跨域 cursor 与详情；
- schedule + Countdown 联合预算、foreign 0/59/60/61、初始总数超预算时从 59 foreign + 2 owned 收缩为 1 owned 或从 60 foreign + 1 owned 收缩为 0 owned、动态增长后成功收缩、动态增长后仍超预算、按域保持错误与 coverage、add/remove/readback failure、两个前缀 Recovery 清理、中性 payload；
- permission 全状态、coverage、换日/显著时间/时区变化重新调和；
- 320×568、390×844、430×932、768×1024、844×390 横屏和最大辅助字号；
- 返回、取消、读取错误、保存错误、重复点击、重新进入、VoiceOver、外接键盘、安全区和减少动态效果；Today/档案读取错误必须隐藏依赖投影的空状态和操作，Countdown 历史详情读取错误必须退出“读取中”、显示“未能核对”并隐藏路由快照中的全部旧事实，删除态提醒必须只保留冻结的中性默认值。

Simulator 自动化只能证明代码、迁移和调和 harness。真机锁屏预览、Focus、Scheduled Summary、实际投递、文件保护、系统备份恢复与跨设备行为继续保留到发布候选真机门禁。
