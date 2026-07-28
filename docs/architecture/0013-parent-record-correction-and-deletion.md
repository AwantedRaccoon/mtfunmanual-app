# 0013：化验与状态父记录的追加式更正和终止删除

- 状态：Accepted
- 日期：2026-07-26
- 适用版本：App 1.0 / Schema V10
- 前置合同：[0002](0002-batch-0-contract-freeze.md)、[0007](0007-labs-status-attachments-and-personal-timeline.md)、[0012](0012-lab-trends-and-deterministic-unit-conversion.md)

## 1. 决策

化验 sample 与状态 observation 不允许原地覆盖。V10 为每个父记录建立一个可验证
`ParentRecordLifecycleHeadRecord` 和一条单根、单叶、不可分叉的 append-only event
chain。V9 → V10 在 inactive generation copy 上为每个既有父记录创建确定性
`migratedSnapshot` root；用户更正追加 `corrected` event 与 typed full snapshot；
删除追加终止 `deleted` event 与 opaque tombstone。V10 中新建的化验/状态在其创建
事务内追加 `createdSnapshot` root，并复用创建命令已有的 operation receipt；
`createdSnapshot` 与 `migratedSnapshot` 必须保持可区分，后者不冒充用户操作。

V5 原始 parent、result 与 `HistoricalTimeRecord` 永不因更正而改变。读取、Today 最近
化验、趋势和时间线只消费当前有效 leaf；纠正时间会重新排序，删除后普通投影不得再
展示该父记录。删除后不能继续更正，也不能恢复为 active。

删除在当前 active generation 中移除全部活动附件文件并把 metadata 标为 deleted。
首版保留原始事实、typed correction 与摘要链以维持审计和完整性校验；因此 UI 必须
明确说明：删除会从 App 的普通视图和当前活动附件目录移除记录，但不是取证级擦除，
inactive generation 与系统备份仍可能保留历史副本。未来若需要敏感 payload purge，
须另立 retention、receipt 重写与备份边界合同。

## 2. 有效快照

化验更正是完整快照，不是稀疏 patch，包含：

- 采样 `HistoricalTimestamp`、specimen 和 context 原文；
- 有序结果全集；
- 每条结果的稳定 logical result ID、item definition ID、name/code snapshot、
  原始数值、派生 Decimal、原始单位、参考区间和 assay/variant；
- `nil`、空字符串、仅空白和全角符号差异。

更正后化验仍须至少有一条完整 result 或一个活动附件；更正为零结果必须在同一个全局
attachment mutation lease 内确认仍有附件，避免与“删除最后附件”竞态。

状态更正完整保存发生时间、metric definition ID、metric name snapshot、1–4 级和
备注。它不修改 metric definition，也不影响同指标的其他 observation。

完全没有有效变化的命令零写入拒绝。用户可见 diff 必须展示更正前后时间、所有变化
字段及化验结果的新增、移除、重排和原文变化；不得只显示“确认修改”。

## 3. 并发、幂等与审计

每次 correction/delete 命令冻结：

- parent type/ID；
- expected latest event、event count、head revision 与 effective facts digest；
- operation/event/payload ID；
- committedAt 和所有原始输入；
- 删除时的完整附件 identity（含 owner、relative path、original filename、type、
  createdAt）、size、hash、独立 deletion operation ID 与 impact digest。

同一 operation + 同一 command digest 在完整性验证后返回 `didApply = false`；同一
operation + 不同 digest、stale head/revision、no-op、fork、cycle、未知 payload、
非唯一 leaf 与非法终态均 fail closed 且零写入。

`event.preFactsDigest` 必须等于前一 event 的 `postFactsDigest`；head 必须指向唯一
leaf，event count、payload identity、effective timestamp 与 effective digest 必须
可从 base + typed snapshot 重算。用户 mutation 产生 operation receipt；迁移 root
不冒充用户操作；V10 新建 root 则绑定对应创建命令已有的 receipt。一次成功语义事务
的 event、payload、head、attachment metadata、receipts 与 receipt ledger 共享一个
local revision。完整性校验必须用 `RecordRevision` 的事实 digest 与 committedAt
验证相关 revision：expected-head revision 等于 predecessor event revision；最新
event 等于当前 head revision；correction 的 event、typed payload、结果与 mutation
receipt 共享 revision；delete 的 event、tombstone、全部 attachment metadata、父
receipt 与逐附件 deletion receipt 共享 revision。额外的
`ParentRecordMutationEventRecord` receipt 必须反向对应唯一 correction/delete
event，孤立 receipt 必须 fail closed。完整性校验加载到的每一条 lifecycle event
都必须恰好被一个现存 parent head 的已验证链消费；event parent-key 集合必须与 head
集合完全相等，孤立 event 或指向不存在 parent/head 的额外链同样必须 fail closed。

correction/delete 的 command digest 不能只在 event 与 receipt 之间互相比对。V10
还必须持久化可重建 expected head token 的 event count/local revision，并在删除
tombstone 中保存 canonical attachment manifest 与 impact digest；完整性校验从
typed snapshot、前序 event、实际 attachment metadata 和每个附件的 deletion receipt
重新计算 expected command/impact digest。event 与 receipt 同时漂移、附件 identity
或 deletion operation ID 脱链均须 fail closed。删除 command 与 impact digest 都
冻结完整附件快照；改变 original filename、createdAt 或其他任一冻结字段不得命中
同 operation replay。

## 4. 删除与附件事务

删除前 read actor 返回影响预览：有效结果数量、更正次数、活动附件完整列表、总字节、
head token 与 impact digest。确认时必须重新核对；期间附件或 head 有任何变化即
`impactChanged`，DB/FS 零变化。

父删除只通过 generation 级 `AttachmentMutationService` 执行：

1. 持有全局 mutation lease，并拒绝 pending/presented/releasing preview；
2. 为每个活动附件使用独立 operation ID，逐个写 journal 并移动到 recoverable
   trash；
3. 任一 staging 失败，按逆序强制回滚所有已 staged 文件；
4. 单个 SwiftData transaction 追加 deleted event/tombstone、更新 head、标记全部
   attachment metadata deleted、写父与附件 receipts/revisions/ledger；
5. DB 失败回滚全部 trash；回滚失败进入 Recovery；
6. DB 成功后逐个强制 finalize；任何失败进入 Recovery，UI 不得显示成功；
7. Recovery latch 在事务中途失效时仍完成必需收尾，但不得向旧 Task 返回成功。

没有附件的父删除仍必须持有同一个 mutation lease，以避免与更正或新附件导入交错。
单附件删除的“附件-only 化验至少保留一个”规则改为读取 effective leaf，而不是只数
V5 原始 results。

## 5. UI 与可访问性

详情页提供“更正记录”和“删除记录”两个低层级动作。更正从当前有效快照预填，保存前
展示 before/after diff；删除使用独立影响 sheet，明确附件数量、当前普通视图将消失、
不可恢复为 active 以及非取证级擦除边界。操作期间禁止交互式 dismiss、返回、预览、
单附件删除和重复提交。

stale/impact changed 不覆盖用户草稿：重新读取新 head 后，用户可比较并再次确认。
corruption、rollback 或 finalize failure 进入 Recovery；普通输入错误与完整性失败不
得共用“稍后重试”文案。删除完成后返回时间线，旧深链显示“记录已删除”，不能伪装成
空记录或损坏。

render 与 UI 门禁覆盖 320×568、390×844、430×932、768×1024、844×390 和
320×568 Accessibility 5；VoiceOver 必须读出字段名、前后值、附件影响、不可恢复
状态和删除边界。

## 6. 成熟方案与复用调查

本节是 2026-07-27 对既有实现补做的回顾性调查，用于补齐工程合同要求的可复用方案记录；
它不应被解释为实施前已经完成的门禁，也不能为今后模块豁免实施前调查。核查仅基于候选的
官方仓库、许可证与发布记录，没有复制候选源码，也没有把候选加入依赖图。

| 候选 | 许可证与维护状态 | 能力匹配 | 安全与隐私影响 | 决定 |
| --- | --- | --- | --- | --- |
| [CareKit / CareKitStore](https://github.com/carekit-apple/CareKit) | BSD；官方项目仍维护，核查时最新正式版 4.1.0 包含 Xcode 26.4 兼容修复 | `OCKStore` 提供基于 Core Data 的本地 append-only、versioned store；但 patient/task/outcome 语义和按日期取版本不等于本 ADR 的 typed snapshot、唯一 leaf、receipt/digest、终态 tombstone 与跨 DB/FS journal | 可在设备本地运行，但会引入第二套 Core Data store、Combine/UIKit 层和更广的健康数据模型；双持久化体系扩大迁移、恢复和完整性审计面 | 不引入；只借鉴 append-only 与版本化读取原则 |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT；成熟并持续维护的 SQLite 工具包 | 事务、迁移、并发与数据库控制力很强；但替换 SwiftData 仍需重写 V1 → V10 generation 层，也不提供 typed lifecycle、receipt/digest 或附件文件事务 | 本地数据库本身不要求网络，但引入第二套数据库和迁移供应链；在没有 SwiftData 可复现能力缺口时，重写会提高数据迁移风险 | 不引入；仅在 SwiftData 出现可复现且无法规避的能力失败时另立替换 ADR |
| [Apple FHIRModels](https://github.com/apple/FHIRModels) | Apache-2.0；核查时 0.9.3，2026-06 仍有正式发布和安全政策 | 提供 FHIR Observation、Provenance 等互操作数据模型；不提供本地 event store、head 乐观并发、完整性链、终态删除或附件恢复协议 | 无默认网络传输，但模型和临床语义面远超本地纠错需求；引入还可能让用户或维护者误以为 App 已承诺 FHIR 互操作 | 不引入；如未来确需 FHIR 导入/导出，另立互操作与隐私边界 ADR |

采用边界是继续复用 Apple 平台的 SwiftData、CryptoKit 与文件保护能力，以及项目既有的
generation、revision、receipt ledger 和 `AttachmentMutationService`。项目自实现仅限本 ADR
冻结而候选没有共同提供的本地 typed lifecycle、可重算完整性链和跨数据库/文件系统恢复
协议。没有引入或局部复制第三方实现；未来若要采用候选，必须先证明现有基础设施的可复现
能力缺口，并另立包含迁移、许可证、安全与隐私影响的替换 ADR。

## 7. 验证门禁

- V9 → V10 inactive copy、target UUID reuse、source bytes 不变、backfill 幂等、
  reopen 与 pointer 切换；
- 两次连续更正后 V5 base/result/time 逐字段不变；
- raw whitespace、全角符号、nil/empty variant、结果新增/移除/重排；
- no-op、same-op replay、digest conflict、stale revision/head、fork/cycle，以及
  event/receipt command digest 同时漂移；
- 删除 attachment manifest、attachment metadata、独立 deletion receipt 与 impact
  digest 的关系损坏；
- correction-to-zero 与最后附件删除/导入的 mutation lease 竞态；
- 删除 preview 后附件或 head 变化；
- 第 N 个 stage 失败、DB rollback、rollback/finalize failure 与 crash recovery；
- 删除不影响其他 parent、metric definition 或附件；
- 删除后 Today、趋势、详情与时间线隐藏，纠正时间按冻结 civil facts 重排；
- ordinary tests、Release contract、generic build、项目专属 Simulator UI smoke。

真机数据保护 class、Files/PDF 边界、系统备份恢复与最终 signed Release 仍按 ADR 0007
和发行门禁单独验证；Simulator 通过不能替代。
