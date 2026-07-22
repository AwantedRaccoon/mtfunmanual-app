# ADR 0006：今日执行与本地提醒合同

- 状态：Accepted
- 日期：2026-07-22
- 作用域：今日计划 occurrence、执行事实、稍后提醒、通知覆盖与前台交互
- 上游合同：[0002 Batch 0 合同冻结](0002-batch-0-contract-freeze.md)、[0005 时间与方案核心](0005-time-and-regimen-core.md)

## 1. 决定

本模块使用三层结构：

1. `ScheduleOccurrenceResolver` 从已封存、无歧义的方案与不可变计划规则中确定性派生 occurrence；occurrence 本身不批量持久化为医疗事实。
2. `AdministrationEvent` 以 append-only 事件链记录 `taken` 或 `skipped`；没有事件就是“未记录”。纠错通过同 occurrence 的 `supersedesEventID` 追加，不覆盖旧事件。
3. `ReminderPreference` 保存用户的提醒意图，`ReminderOverride` 保存一次 snooze，`NotificationCoverage` 只是可重建的系统投影。系统 pending notification 不是执行事实。

新增实体进入 additive `AppSchemaV4TodayExecution`。V1、V2、V3 名称和模型集合保持冻结；现有 generation-copy、双重验证与 pointer switch 扩展到 V3→V4。任何失败都保留旧 active generation。

## 2. occurrence v1

计划 occurrence key 冻结为：

```text
occ:v1:<schedule-rule-uuid-lowercase>:<positive-revision>:<YYYYMMDD>T<HHMM>
```

- 日期和时间均为规则所属时区中的 civil 值；禁止本地化字符串、`Date.description` 或当前 locale。
- 持久化事件与 override 必须重新解析并完整重建同一 canonical key；前缀相同但尾部多余、UUID 大写、revision 前导零、非法 civil date/time 或不符合规则 cadence 的 key 均视为损坏。`fixedZone` 的 `plannedInstant` 还必须与 key 的 civil slot 精确一致；`floatingLocal` 允许设备时区变化后同 key 派生出新的未来 instant。
- `dailyTimes` 每个 active civil day 的每个规范化时间生成一项。
- `weekly` 使用 ISO weekday：`1=周一 … 7=周日`。
- `everyNDays` 使用 Gregorian civil-day distance，以 anchor 为 0，满足 `distance % interval == 0`。
- `oneOff` 必须恰好一个时间，只在 anchor 生成一次。
- 时间必须为规范化 `HH:mm`，排序且不重复；非法 kind、时间、weekday、interval 或时区一律 fail closed。
- 规则与 owning regimen 都使用 `[start, end)`；draft、archived、需要复核或时间线歧义的方案不生成 occurrence。
- 每条规则最多 16 个当地时间；单次解析最多 4,096 个 occurrence。任一上限超出时不得返回部分计划，必须整体 fail closed 并进入可见复核。
- reminder reconcile 的读取窗口额外回看前三个当前当地 civil day，但只保留计划时间仍在未来，或拥有未来 snooze override 的候选；三日覆盖最大 25–26 小时时区跃迁叠加 24 小时 override 后的 civil-label 差，跨午夜或国际日期变更线的稍后提醒不得被当作 stale 删除。
- `floatingLocal` 对未来 occurrence 使用调用方显式注入的当前 IANA 时区；`fixedZone` 永远使用冻结时区。
- DST gap 不静默平移：该 slot 不生成可执行 occurrence，并产生需复核问题。DST overlap 固定选择第一次（较早 instant）。改变策略需要新的 key/engine 版本。
- 写入时只在目标 occurrence 的精确当地 civil-day 半开区间重算目标 key；同日其他 DST-gap slot 继续产生复核问题，但不能阻止安全 slot 的执行事实写入。

## 3. 执行与幂等

- `taken` 与 `skipped` 是仅有的初始执行状态；“保持未记录”不写数据库。
- 方案有效期统一经过 `RegimenTimelineResolver` 规范化：后一份 sealed 方案的 civil start 会成为前一份未显式结束方案的半开 end；读取、提醒规划和写入校验不得各自解释时间线。每条 schedule rule 在进入 occurrence 容量核算、DST 问题生成与排序前，必须先与其归属方案的规范化 `[start, end)` 相交；空交集直接跳过。重复 start 或重叠一律 fail closed。
- generation 校验对既有 event/override 使用同一规范化方案区间；封存新方案若会让任一既有计划事实脱离其 owning regimen 的有效区间，整个封存事务必须拒绝并回滚，不能把事实变成 Today 不可见的孤儿。
- 初次记录要求 expected leaf 为 `nil`；纠错必须携带当前 expected leaf ID。
- 同一个 occurrence 的事件链必须无环、每个节点最多一个 successor、全链恰好一个 leaf；跨 occurrence supersedes 被拒绝。
- 执行、snooze 与提醒偏好写命令都携带唯一 `operationID` 和 canonical digest。三类摘要都绑定 checked `committedAt`；执行与 snooze 还绑定完整 `PlannedOccurrence` 快照（key、规则与 revision、方案与组成身份、展示名、civil date/time、IANA 时区、offset 与 instant），不能让 replay 绕过原命令的完整 occurrence 校验。相同 ID + 相同 digest 返回既有结果；相同 ID + 不同 digest 必须零写入失败。
- `OperationReceipt` 本身是带 `RecordRevision` 的事实；单例 `OperationReceiptLedger` 冻结收据数量与 canonical set digest。事件/override 必须各自与同 `operationID` 的唯一收据一一映射；偏好允许多次操作历史，但保存最后一次 operation。收据缺失、篡改、重复指向或孤立必须使 generation 校验失败。
- 执行命令 digest 包含完整 `HistoricalTimestamp` civil date/time、nanosecond、precision、provenance、IANA 时区和 offset，不能只绑定 instant。
- 所有进入 canonical digest 的 `Date` 统一按微秒取整，并以可失败的精确 `Int64` 转换编码；NaN、无穷和有限但超出 `Int64` 微秒范围的值一律 fail closed，不得触发整数转换陷阱。
- `AdministrationEvent.regimenVersionID` 保留计划 occurrence 的方案身份；实际时间 sidecar 必须按 `HistoricalTimestamp.localDate` 独立解析 sealed 方案。零候选或多候选时关联保持空，并同步可见核对项。
- 实际时间保存完整 `HistoricalTimestamp`。执行事实提交成功后，即使通知 reconcile 失败也不回滚。
- 执行与 override 提交前必须使用“提交瞬间 + 当前展示时区”重新解析 Today 所承诺的 civil day；若目标 occurrence 已不属于该展示日，写入必须 fail closed，不能把跨午夜或系统时区变化前的陈旧界面动作记入另一日。Today 在系统日历日变化、显著时间变化和系统时区变化时重新读取；重叠读取使用独立单调序号，较早完成的旧快照不得覆盖较新的读取结果或 loading/error 状态。
- 库存模块尚未存在。本批次允许在“库存未启用”路径保存执行；不得宣称已经扣减库存。未来启用库存时，执行、反转和 reconcile issue 必须按 ADR 0002 在同一事务提交。

## 4. 提醒意图与系统权限

- sealed `ScheduleRuleRecord` 只描述计划；不通过修改它来开关提醒。
- `ReminderPreference(scheduleRuleID, expectedRuleRevision)` 独立保存 enabled、默认 snooze 和中性内容版本。
- 一次 snooze 必须晚于提交时间且最多延后 24 小时；这与 `defaultSnoozeMinutes` 的 `1...1440` 合同一致。结合最大跨区 civil-label 差，reminder planning 回看前三个当前当地 civil day；写入与 generation 校验都执行同一上限。
- 用户第一次主动打开提醒时，先展示用途与中性预览，再请求系统权限；禁止首启自动请求、provisional 或静默授权。
- denied 不删除用户意图、不影响 Today occurrence，也不产生 taken/skipped；coverage 显示“系统通知已关闭”。
- 每次 reconcile 前读取最新 `UNNotificationSettings`。数据库与通知中心不能原子提交：先保存用户意图/override，再幂等 reconcile，回读 pending requests，最后更新 coverage。
- 方案封存、执行事实、提醒偏好或 override 成功提交后，先把 coverage 标记为 `reconciliationPending`，再把失效是否成功传给运行时并触发最新上下文的 reconcile。若 coverage 持久化本身失败，运行时必须立即进入可见错误态，覆盖 UI 中旧的“已安排”投影；业务事实仍保留，不能因投影失效失败而回滚。
- 本地通知仅使用一次性 `UNCalendarNotificationTrigger`。request ID 使用 `unmanual.exec.v1.<SHA256(occurrence-key + effective-fire-instant)>`；只增删此前缀，禁止 `removeAllPendingNotificationRequests()`。
- 内部全局预算冻结为 60 个 pending request，目标窗口 14 个当地日；预算必须先扣除通知中心中其他来源的 pending request，再先覆盖每条启用规则的下一项，最后按 fire date 和 key 稳定排序填充。每次 add 前都重新回读并按最新 foreign 数量裁剪可提交的 owned 前缀，禁止先超额提交再事后收缩。调和尾声还需有界地重复回读并按最新 foreign 数量收缩 owned 集合；foreign request 在清理期间持续增长且有界收缩仍无法把最后观测总数压到 60 时，保守删除全部 owned request、再次回读并报告安排失败。60 是保守产品预算，不宣称为当前 UserNotifications 公布上限。
- 候选超过剩余容量时 coverage 使用 `limitedByBudget`；截止值是最早未覆盖 occurrence 的 fire instant，UI 明确写“连续覆盖至该时间之前”，不得用已选择的最远提醒伪装连续覆盖。
- 用户存在 enabled 意图但当前窗口没有候选时仍属于 `scheduledForWindow`（0 条），不得误报为“用户关闭”。pending 回读必须同时核对 request ID 与 fire instant，并要求本 App 前缀下的完整 pending 集合与 desired 集合严格相等；删除后仍残留的 stale request 必须报告 `schedulingFailed`，不能宣称关闭或完全覆盖。
- 通知文案固定为中性内容，不含 HRT、药名、剂量、方案、身份、稳定用户 ID、badge、附件、Time Sensitive 或 Critical Alert。
- 权限说明必须区分两个边界：通知 request 只在当前设备安排；提醒偏好属于 App 本地数据，可能按用户的 iOS 设置进入 iCloud 或电脑系统备份。只能承诺 App 不主动上传或实时同步，不能写成偏好“只保存在这台设备”。
- 当前没有 App Lock。通知只有默认 tap/open Today；不注册可在后台写入“已使用 / 稍后 / 跳过”的 action。所有事实写入在 App 前台、唯一 store ready 后重新读取 occurrence 并由用户确认。
- UI 只能表述“已安排”与覆盖截止时间，不能保证投递。
- App 首次 ready、每次 scene 回到 active，以及前台收到系统换日、显著时间变化或时区变化时都触发幂等 reconcile；每次调和必须在 coverage 写入完成后发布本地资料刷新，使 Today 不会保留冷启动前的旧投影。普通 reconcile 在异步时钟读取前取得单调请求序号。授权 prompt 是单独的系统状态转换：prompt 返回并重新读取设置后，授权完成事件才取得新的序号并排入同一串行工作队列，因此它会覆盖由同一次偏好写入在 prompt 期间触发、但只看见旧授权状态的自动 reconcile。Recovery epoch 可以让等待中的授权完成整体失效。队列中的调用只有等当前 processor 连同最新待处理工作全部排空后才返回；只有最新序号可以提交新的系统 request 或 coverage。每次系统 mutation 前后都必须核对序号；若 add 在等待期间被更新序号取代，旧工作只允许执行补偿性 owned-prefix 清理并立即停止，禁止继续 add 或写 coverage。重复 desired request ID 同样 fail closed 清理 owned、回读确认并保留全部 foreign request。所有规则、方案、偏好读取有显式 `limit + 1` 上限，事件与 override 按 planning interval 查询，历史时间按命中的执行 leaf 精确读取，越界一律 fail closed。
- 进入 Recovery Mode 时先暂停调和并递增运行 epoch，使正在等待授权、时钟或通知中心的旧请求失效；随后只清理 `unmanual.exec.v1.` 前缀的 pending request，等待已在途调和退出，再以有界重试执行最终清理和回读确认。其他 App/系统来源的通知必须保留；最终仍观察到 owned request 时进入可见失败态，不能宣称 Recovery 清理完成。退出 Recovery 后才恢复调和。

Apple 官方依据：

- [请求通知权限](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)
- [在本地安排通知](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app)
- [UNNotificationRequest identifier](https://developer.apple.com/documentation/usernotifications/unnotificationrequest/identifier)
- [读取 pending requests](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/getpendingnotificationrequests(completionhandler:))
- [处理通知与 action](https://developer.apple.com/documentation/usernotifications/handling-notifications-and-notification-related-actions)

## 5. 采用与放弃的候选

- 采用 Apple `UserNotifications` + Foundation `Calendar`：系统原生、无网络、无第三方运行时，权限与 pending reconciliation 能力完整。
- 不引入 `timokoethe/NotificationManager`（MIT）：它主要包装授权与增删 API，不能提供本项目的 occurrence、事实幂等、覆盖或 App Lock 合同。
- 暂不引入 `pointfreeco/swift-clocks`（MIT）：维护活跃且测试能力成熟，但本模块不需要 sleep/timer；显式注入 `Date`、`Calendar` 与系统 client 已足够，会避免额外运行时依赖。
- 不引入 Stanford `SpeziNotifications`（MIT）：维护状态良好，但会引入不需要的 Spezi 架构，仍不能替代本项目的数据语义。

## 6. UI 与范围

Today 在 HRT 日数之后显示“今日执行台账”：计划时间、项目原文、文字状态与明确动作。主动作“已使用”，次动作“稍后提醒”“本次跳过”；离开即保持未记录。已有事实提供“修改记录”，通过 correction 追加。提醒授权与纠错 sheet 的正文必须可滚动，主操作固定在安全区内，并同时提供 medium/large detent，保证 320×568 与辅助字号下仍能取消、查看字段并完成操作。

无计划时解释原因并提供“建立计划”；即使同屏仍有可执行项目，任何被 fail-closed 的时间规则也必须显示复核提示与返回方案入口。提醒覆盖分别显示未打开、待授权、系统阻止、已安排至某日、容量受限或安排失败，并给下一步。所有动作至少 44×44 pt，状态不只靠颜色表达，动态字体时纵向排布。rice/paper 上的小字与辅助文字只能消费达到 WCAG AA 的 `secondaryText` / `vermilionText` / `blueText` / `mossText` / `mustardText` 语义令牌；原始品牌强调色仅用于装饰面、边线或已验证的深色背景，禁止通过前景透明度制造低对比层级。

本批次不包括 Countdown 提醒、库存 UI、APNs/CloudKit、远程内容、后台网络、依从率/漏用推断、医疗建议或锁屏写 action。真机投递、锁屏预览、Focus/Scheduled Summary、Data Protection class 和真实 DST 旅行继续留在发布真机门禁。

## 7. 完成门禁

- occurrence：四种规则、半开区间、排序/去重、非法值、locale、leap day、DST gap/overlap、floating/fixed 与 golden key。
- 执行：taken/skipped、未记录零事件、same-op 幂等、digest 冲突零写入、stale leaf、纠错单 leaf、rollback 与历史时间。
- 提醒：权限全状态、60 budget 公平覆盖、stale cleanup、部分失败、回读不符、payload 无敏感内容、foreign request 不受影响。
- UI：loading/error/empty/planned/taken/skipped/snoozed/permission denied；320×568、390×844、430×932、768×1024、横屏、动态字体、VoiceOver、减少动态效果。render fixture 必须显式覆盖 snoozed、blocked permission 与 reduce-motion 分支。
- 空台账仍必须显示 reminder coverage；没有 occurrence 不等于没有提醒意图或没有系统权限状态。
- Simulator 只证明工程、fake/system adapter 和模拟投递路径；不替代真机发布门禁。
