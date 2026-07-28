# 0016：Schema V11/V12 安全采用与 generation retention/purge

- 状态：Accepted
- 日期：2026-07-28
- 适用版本：App 1.0 / Schema V11–V12
- 前置合同：[0003](0003-data-safety-foundation.md)、[0013](0013-parent-record-correction-and-deletion.md)
- 隐私表面：[0014](0014-batch-6-app-lock-and-privacy-shield.md)
- 数据控制：[0015](0015-batch-6-data-inventory-deletion-and-reset.md)

## 1. 冻结的 V11 与 V12 additive schema

`AppSchemaV10ParentRecordLifecycle` 保持冻结。privacy-only
`AppSchemaV11PrivacyControl` 只 additive 增加：

- `PrivacyControlRecord`；
- `PrivacyControlBackfillState`；

两者的 exact fields、固定 key 与 digest 见 ADR 0014。数据控制使用独立
`AppSchemaV12DataControl`，只 additive 增加：

- `DataControlDeletionTombstoneRecord`；
- `DataControlBackfillState`。

V12 exact model shape 冻结为：

```text
DataControlDeletionTombstoneRecord
  targetKey: String unique
  id: UUID unique
  operationID: UUID
  targetKindRawValue: String
  targetStableKey: String
  targetID: UUID?
  sourceGenerationID: UUID
  sourceDatasetID: UUID
  sourceNextLocalRevision: Int64
  expectedRecordKey: String
  expectedLocalRevision: Int64
  expectedDigestHex: String
  targetSnapshotManifest: String
  impactDigest: String
  attachmentManifest: String
  notificationManifest: String
  retainedRecordCount: Int
  deletedAttachmentCount: Int
  deletedAttachmentBytes: Int64
  affectedReminderCount: Int
  committedAt: Date
  localYear: Int
  localMonth: Int
  localDay: Int
  localHour: Int
  localMinute: Int
  localSecond: Int
  localNanosecond: Int
  timeZoneIdentifier: String
  utcOffsetSeconds: Int
  precisionRawValue: String
  provenanceRawValue: String
  commandDigest: String

DataControlBackfillState
  taskKey: String unique = "v11-to-v12-data-control"
  sourceRawValue: String
  initialTombstoneCount: Int
  initialTombstoneSetDigest: String
  completedAt: Date?
  updatedAt: Date
```

`DataControlDeletionTombstoneRecord` 自身的 `RecordRevision` digest domain 固定为
`recordType = "DataControlDeletionTombstoneRecord"`、`recordID = tombstone.id`。
字段名就是上面 model property 名，完整 `RecordDigestV1.Value` 映射为：

```text
id/operationID/sourceGenerationID/sourceDatasetID -> .uuid
targetID                                           -> .uuid 或 .null
sourceNextLocalRevision/expectedLocalRevision
retainedRecordCount/deletedAttachmentCount/deletedAttachmentBytes
affectedReminderCount
localYear/localMonth/localDay/localHour/localMinute/localSecond/localNanosecond
utcOffsetSeconds                                   -> .integer(Int64)
committedAt                                        -> .timestampMicroseconds
targetKey/targetKindRawValue/targetStableKey/expectedRecordKey
expectedDigestHex/targetSnapshotManifest/impactDigest
attachmentManifest/notificationManifest/timeZoneIdentifier
precisionRawValue/provenanceRawValue/commandDigest -> .string
```

不得省略 `id`、用 target stable UUID 代替 record ID、把 nullable UUID 编成空 String，
或把任何时间换成另一个精度。validator 与 V12 migration 只接受这一种 digest。
`DataControlBackfillState` 的 domain 固定为
`recordType = "DataControlBackfillState"`、`recordID =
CoreTimeRegimenBackfill.stableUUID(for: taskKey)`；task/source/initial set digest 使用
`.string`，initial count 使用 `.integer(Int64)`，completed/updated 使用
`.timestampMicroseconds`（completed nil 非法完成形状）。

`targetKindRawValue` 只接受 `journeyEntry`、`administrationOccurrence`、
`draftRegimenVersion`、`sealedRegimenVersion`、`hrtJourney`；既有附件、父记录和
Countdown 继续使用原 typed lifecycle，不重复建立 generic tombstone。
`targetStableKey` 对 UUID target 使用 lowercase UUID，对 occurrence 使用原冻结
occurrence key，对 HRT singleton 使用 `"primary-hrt-journey"`；`targetKey` 是
`kind + ":" + targetStableKey`。

每个 V12 model 有唯一 `RecordRevision`。backfill 创建零 tombstone，
`initialTombstoneCount = 0`。`initialTombstoneSetDigest` 使用
`RecordDigestV1.sha256Hex` 的唯一 empty-set vector：

```text
recordType = "DataControlTombstoneSetV1"
recordID   = CoreTimeRegimenBackfill.stableUUID(
               for: "data-control-tombstone-set-v1"
             )
fields     = ["count": .integer(0)]
```

没有其他字段，digest 本身不进入 fields；golden test 直接以这组 domain/fields 重算，
不得以 JSON、空 Data、空字符串或实现私有常量替代。迁移 marker 不冒充用户 operation，
不产生 `OperationReceiptRecord`；用户 tombstone 必须产生唯一 receipt 并更新 receipt
ledger。

V12 backfill source 只描述当前一步，接受 `bootstrapV12` 或
`schemaUpgradeV11`。`bootstrapV12` 同时用于无 pointer 的新安装和 legacy adoption；
`schemaUpgradeV11` 用于任何已验证 V11 pointer。两种路径都创建 completed marker 与
revision，source、initial count、canonical empty-set digest、completedAt 和 updatedAt
全部进入 marker digest。V11 privacy marker 同样总是存在，source 只接受 ADR 0014
冻结的两值。新装、legacy adoption 和 pointer upgrade 没有缺 marker 的合法形状，
冷启动中断不会改变同一步的 source。

V11 不删除或修改 V1–V10 model；V12 不删除或修改 V1–V11 model。V10 → V11 与
V11 → V12 分别使用独立 inactive generation copy：

1. pointer 指向的 V10 source 保持不变；
2. migration journal 冻结 source/target；
3. lightweight migration 后运行对应幂等 backfill；
4. V11 建立默认关闭的 privacy 单例，V12 建立零 tombstone marker；
5. 从磁盘事实独立重算 expected digest/revision/receipt/lifecycle/附件关系并逐项比对；
   绝不“修复”、重写或重基线 V1–V11 既有 fact、revision、receipt 或 digest；
6. 释放 container，以只读方式重开并核对 dataset 与最低计数；
7. pointer-last 激活本段目标版本。

相同 source 和未完成 journal 复用同一个合法 target；App 1.0 不把 unresolved target
推断成可删除失败 target。source bytes、附件树和保护/备份属性在 pointer 切换前不得
改变。

## 2. Tombstone 完整性

`DataControlDeletionTombstoneRecord` 精确保存上一节冻结的字段。它是 projection
suppression overlay，不是 redaction event；任何 V1–V11 原始或 append-only row 都保持
不变。target kind 决定 typed validator 如何从目标事实重算 expected record key、
revision、digest、impact 和 command digest。

`expectedRecordKey` 对五种 kind 都是 synthetic token key：
`"DataControlTarget:" + targetKey`，不伪装成某条既有 `RecordRevision.recordKey`。
预览把当时的 typed source snapshot 持久化为：

```text
targetSnapshotManifest = "dct1." + base64url(canonicalTargetSnapshotBytes)
```

`dct1` 复用 ADR 0015 的 base64url、NFC、UUID、Int64、timestamp-microseconds、拒绝
non-canonical/trailing bytes 和 decode/re-encode 门禁。payload 固定写入 kind、
stable key、target-ID presence + UUID、expected record key、`UInt32 sourceCount`，
再写 source entries；source 按 `recordKey` UTF-8 升序，每项依次为 record key、
`Int64 localRevision`、32-byte digest。source 不得为空、重复或缺 revision。

最后写 occurrence-projection presence byte。非 occurrence 必须为 `0x00` 且立刻结束；
occurrence 必须为 `0x01`，并按以下 exact 顺序编码：

```text
key String
scheduleRuleID UUID
scheduleRevision Int64
regimenVersionID UUID
regimenItemID UUID
displayTimeZoneIdentifier String
localYear/month/day/hour/minute/second/nanosecond Int64
resolvedTimeZoneIdentifier String
utcOffsetSeconds Int64
instant timestampMicroseconds
```

`recordID` 的算法明确复用
`CoreTimeRegimenBackfill.stableUUID(for: "data-control-target:" + targetKey)`；
`expectedLocalRevision` 是 manifest source entries 的最大 revision；
`expectedDigestHex` 固定为：

```text
RecordDigestV1.sha256Hex(
  recordType: "DataControlTargetTokenV1",
  recordID: stable target UUID,
  fields: [
    "targetSnapshotManifest": .string(targetSnapshotManifest)
  ]
)
```

逐 kind 的合法形状冻结如下：

| kind | `targetID` | stable key 与预览时 source snapshot | reminder |
| --- | --- | --- | --- |
| `journeyEntry` | 必须是 entry UUID | lowercase UUID；该 `JourneyEntry` 及其 `sourceRecordType = JourneyEntry`、source ID 相同的 `HistoricalTimeRecord` | canonical empty manifest，不调和 |
| `administrationOccurrence` | 必须 `nil` | 完整 occurrence key；预览使用明确传入并持久化的 `displayTimeZoneIdentifier` 解析出的 version/item/rule，以及 occurrence key 相同的全部 administration-event chain、reminder-override chain 和每个 event 的 `HistoricalTimeRecord`；**不包含** rule-level `ReminderPreferenceRecord` | 完整 owned pending manifest并全局重排 |
| `draftRegimenVersion` | 必须是 version UUID | lowercase UUID；edit state 必须 draft；该 version、全部 child item/rule、这些 rule 的全部 preference 与全部 override chain、引用该 version 的全部 administration-event chain，以及每个 event 的 `HistoricalTimeRecord` | 完整 owned pending manifest并全局重排 |
| `sealedRegimenVersion` | 必须是 version UUID | lowercase UUID；edit state 必须 sealed；source snapshot 与 draft 相同 | 完整 owned pending manifest并全局重排 |
| `hrtJourney` | 必须 `nil` | `"primary-hrt-journey"`；唯一 legacy `HRTProfile`、`HrtJourneyProfileRecord`、全部 `HrtPeriodRecord` 与 `HrtJourneyLifecycleEventRecord` | canonical empty manifest，不调和 |

occurrence 即使从未产生 event，也由 version/item/rule 三条 revision、显式 display zone
与不含 `displayName` 的 identity/time projection 形成非空 token；不得伪造
`RecordRevision`。`dct1` 只保存 record key、revision、digest 与非正文身份/时间，
不保存药名、剂量、备注或其他 display string。持久
validator 从 `dct1` 重算 expected record/revision/digest 和 command，不使用设备当前
时区。occurrence 的 version/item/rule 以后合法变化时，`dct1` 仍是不可变历史预览，
不要求当前 mutable fact 回到旧 digest；receipt/ledger、tombstone revision 和 manifest
内部一致性提供审计。其他四种 target 的 source closure 在 terminal 后由下一段写屏障
保持不变，并可继续与当前 facts 交叉核对。

terminal overlay 同时是 typed writer 的写入屏障，并在每个 writer transaction 内、
任何 mutation 前核对：

- deleted journey entry 拒绝该 entry 的附件新增/替换/删除和其他后续 mutation；
- deleted occurrence 拒绝该 exact occurrence key 的新 administration/supersession
  与 reminder override；同 rule 的 preference 和其他 occurrence 仍允许；
- deleted draft/sealed version 拒绝 version、child item/rule、其 preference/override
  和引用它的 administration chain 的任何后续 mutation；
- deleted HRT journey 拒绝 profile/period/lifecycle 的新增、修改或追加。

命中屏障返回 `targetDeleted`、零写入；不得借新 operation 绕过。该规则既防止普通页面
复活 target，也保证需要当前交叉核对的历史 closure 不漂移。closure 中 receipt/ledger、
lifecycle/backfill 完整性仍由既有 validator 另行验证。`sourceNextLocalRevision`
冻结整个 dataset 水位，所以确认前任何 closure 外并发写也会使 command stale。

`attachmentManifest` 使用 ADR 0015 的 `dcm1-a` canonical codec，逐项承诺
attachment identity、size/hash 和 deletion operation ID；`notificationManifest`
使用 `dcm1-n` codec；只有上表三种 planner target 承诺确认时两个 App-owned
namespace 的完整 **pending** identifier 集合，另外两种必须是 canonical empty。
它不包含 delivered，也不承诺 hashed identifier 的 target association。持久
validator 从 manifest、terminal metadata、逐附件 receipt 和 tombstone 重建历史
影响；当前 pending 另按当前时间窗口与 overlay 重算。delivered 不属于持久重算事实。

用户确认后的 exact command 冻结为：

```text
DeleteDataControlTargetCommand
  operationID: UUID
  generationID: UUID
  datasetID: UUID
  expectedNextLocalRevision: Int64
  targetKindRawValue: String
  targetStableKey: String
  targetID: UUID?
  expectedRecordKey: String
  expectedLocalRevision: Int64
  expectedDigestHex: String
  targetSnapshotManifest: String
  impactDigest: String
  attachmentManifest: String
  notificationManifest: String
  committedAt: Date
  localYear/month/day/hour/minute/second/nanosecond: Int
  timeZoneIdentifier: String
  utcOffsetSeconds: Int
  precisionRawValue: String
  provenanceRawValue: String
```

command digest 的 domain 固定为
`recordType = "DeleteDataControlTargetCommand"`、`recordID = operationID`。字段名与
`RecordDigestV1.Value` 映射固定为：

```text
operationID/generationID/datasetID/targetID  -> .uuid（targetID nil -> .null）
expectedNextLocalRevision/expectedLocalRevision
localYear/localMonth/localDay/localHour/localMinute/localSecond/localNanosecond
utcOffsetSeconds                              -> .integer(Int64)
committedAt                                   -> .timestampMicroseconds
targetKindRawValue/targetStableKey/expectedRecordKey/expectedDigestHex
targetSnapshotManifest/impactDigest/attachmentManifest/notificationManifest
timeZoneIdentifier/precisionRawValue/provenanceRawValue -> .string
```

这里的每个路径名就是 command digest field name；`operationID` 虽也是 domain record
ID，仍作为 `.uuid` field 进入 digest。两个 manifest 必须先通过 ADR 0015 exact
decoder/re-encode，再作为完整 String 进入 digest。writer 先查 operation receipt，
再在 exclusive mutation lease 内重算 generation/dataset/next revision、target
token、两个 manifest 和 impact；任一不一致返回 conflict/stale，零写入。

成功写入时 tombstone 精确复制：

```text
sourceGenerationID       = command.generationID
sourceDatasetID          = command.datasetID
sourceNextLocalRevision  = command.expectedNextLocalRevision
targetSnapshotManifest   = command.targetSnapshotManifest
```

tombstone 自身 `RecordRevision.datasetID == sourceDatasetID` 且
`RecordRevision.localRevision == sourceNextLocalRevision`；transaction 成功后 metadata
next revision 恰为 `sourceNextLocalRevision + 1`。因此未来 generation copy 后仍能从
tombstone 保存的原 generation、dataset、水位与 `dct1` 重建历史 command digest，
不得拿当前 pointer generation 代替。

成功 tombstone 的 `id` 固定等于 `operationID`；receipt 的
`resultRecordType = "DataControlDeletionTombstoneRecord"`，
`resultRecordID = tombstone.id`。tombstone、receipt、receipt ledger 与各自
`RecordRevision` 在一个 transaction 共享 local revision 与 committed timestamp。
同 operation + 同 command digest 只有在 tombstone、receipt、ledger、revision 与
文件/通知 terminal 证据全部通过后，返回既有 tombstone 的历史结果且
`didApply = false`，不再次移动附件或写 DB。若 attachment journal 未完成，先进入
Recovery 收敛；若是 planner target 且当前 reminder coverage 尚未与当前 overlay/
时间窗口一致，可以幂等地重新执行**当前** pending reconciliation，但不重写历史
notification manifest，也绝不触碰 delivered。同 operation + 不同 digest 返回
`operationConflict`。不同 operation 指向已经 terminal 的
`targetKey` 返回 `targetAlreadyDeleted(existingTombstoneID)`、零写入且不产生第二张
receipt。不存在“换 operation 覆盖旧 tombstone”的合法路径。

每个 target 最多一个 terminal tombstone。tombstone 必须对应唯一 operation receipt、
RecordRevision 和 ledger entry；command/impact digest 从 tombstone 保存的 source
generation/dataset/watermark、`dct1` target snapshot 和两个 `dcm1` manifest 精确
重算。除 occurrence 允许其共享 source 后续合法变化外，其余 kind 还与写屏障保护的
当前 source facts 交叉核对。重复 operation + 相同 digest 幂等，重复 operation +
不同 digest、重复 target、unknown kind、codec/digest 漂移、孤立 receipt 或屏障内
payload 漂移均 fail closed。

迁移只建立 marker，不为既有记录伪造用户删除。V11/V12 backfill 本身不改变普通投影。

## 3. generation 分类

每次清单和清理先将 `Generations/` 的每个直接子项归入一个 primary classification，
再独立记录 journal roles。primary raw value 与 ADR 0015 category 的 exact crosswalk：

| Primary raw value | ADR 0015 category | 条件 |
| --- | --- | --- |
| `active` | `storage.generation.active` | direct UUID directory 通过 layout/tree/provenance 审计，且当前验证 pointer 精确指向 |
| `inactiveProven` | `storage.generation.inactive-proven` | 非 active 的 direct UUID directory 通过安全审计，且受验证 journal/provenance 精确证明来源 |
| `inactiveUnproven` | `storage.generation.unproven` | 非 active 的 direct UUID directory 可安全枚举，但没有足够 provenance |
| `invalid` | `storage.generation.invalid` | non-UUID、symlink、非 directory、嵌套/越界、未知 leaf，或 layout/tree/path 审计失败 |

journal role 是下列 ASCII raw value 的去重升序集合，不代替 primary：

- `journalSource` / `journalTarget`：未完成 migration/reset/restore journal 引用；
- `knownRollbackSource`：已激活 migration 留下、journal 可证明的直接 source；

`failedOwnedTarget` 不属于 App 1.0 可形成的 role：现有 journal 没有原子 failed phase
或历史 ownership set，不能从一个 unresolved target 猜测它已可安全删除。

分类顺序固定为：先做 file type/path/tree 安全审计，失败即 `invalid`；否则验证 pointer，
命中即 `active`；非 active 且至少有一个通过 journal typed decode/field/path
交叉核对的 role，或有后续版本冻结的 provenance sidecar，即 `inactiveProven`；其余为
`inactiveUnproven`。同一 entry 可以有多个语义相容 role；role 引用的路径/UUID 与实际
entry 不精确、journal typed decode/field/path 交叉核对失败或 source/target 指向同一
UUID 等不可能组合均令 entry `invalid`。现有 journal 没有内嵌 digest，不能把 sorted
JSON 伪装成 authenticated provenance；manifest 仅用原文件 SHA-256 承诺观察到的
control snapshot。non-UUID invalid entry 的 generation ID 为 nil，其 NFC entry name
与内部 tree tuple 只用于 Recovery 诊断/测试向量；按 ADR 0015，
`storage.generation.invalid` 必须 failed、count/digest 为 nil，invalid entry 不得进入
任何 complete category 或 manifest digest。

active、任何 unresolved `journalSource`/`journalTarget` 和
`inactiveUnproven` 永不自动删除。`invalid` 进入 Recovery。不得以修改时间、目录排序
或“最新 UUID”猜测身份。

## 4. Retention 决策

App 1.0 不对普通逐项删除重写整个 generation，也不承诺从旧 generation 或系统备份
清除历史 payload。普通删除在 manifest 中如实显示 retained history。

Schema migration 的 rollback source 采用保守策略：

- V11/V12 只记录并展示当前可证明的 rollback source；
- 在没有跨冷启动持久化 provenance ledger 之前，不自动 purge 已激活 source；
- 后续 schema 从 V12 开始必须为每个 generation 写不可变 provenance sidecar，才可
  另立“成功冷启动次数 + 最小保留时间”的自动清理数值；
- 磁盘空间不足不允许绕过来源证明删除 generation，只能提示用户执行全部重置或释放
  其他空间。

因此 App 1.0 **不执行任何 ordinary generation purge**。现有 migration journal
没有可原子证明 `failedOwnedTarget` 的 durable phase/history，unresolved target 仍可能
是下一次冷启动必须恢复的唯一候选；实现不得把它转成可删除身份。唯一允许删除
generation 的路径是用户明确确认的“全部数据重置”：reset journal 隔离整个旧 root 后，
按 ADR 0015 在下一次冷启动、任何 container 打开前精确 purge quarantine。这个决定
优先保护恢复能力，不把“清理合同”误写为自动删除未知历史。

## 5. Retention 执行边界

`GenerationRetentionService` 在 App 1.0 只负责分类、逐文件 durable tree 审计和向
manifest/UI 披露，不提供普通 `removeItem`、`GenerationPurgePlan` 或 purge journal。
任何 inactive/unproven/invalid entry 都保留；invalid 使 manifest incomplete 并进入
Recovery。reset 的 quarantine 计划、路径、phase 与 digest 只由 ADR 0015 的 reset
journal 冻结，执行前重读并逐项核对；它不是普通 generation cleanup。

## 6. Bootstrap 与 reset 顺序

启动先检查 reset control，再检查普通 migration pointer：

1. 若存在 reset journal，按 ADR 0015 的 phase 恢复，在任何 `ModelContainer` 打开前
   完成 managed root、独立 legacy main/WAL/SHM quarantine 与 purge；不允许普通
   bootstrap 把缺失 `Unmanual` root 当成新装；
2. reset 不存在时才执行既有 generation pointer/migration Recovery；
3. V10 pointer 升级到 V11，再从 V11 升级到 V12；
4. V12 active store 校验；
5. 分类 generation 并把 unknown/invalid 状态纳入 manifest；
6. 枚举并披露全部 inactive/unproven/invalid entry，不执行 ordinary purge；
7. 发布 ready session。

protected atomic JSON、路径验证、文件保护和 `.systemManaged` 实现提取为同一 internal
基础设施，让 pointer、migration journal 和 reset journal 消费相同原子写与读回门禁。

## 7. 复用与依赖调查

调查日期为 2026-07-28。

- Apple SwiftData/Core Data 继续承载 store 与轻量迁移；
- `FileManager` 只承担经过 journal 和路径验证的精确 move/remove；
- GRDB.swift（MIT）虽然提供更直接 SQLite 控制，但替换会重写 V1–V10，不采用；
- CareKitStore（BSD）的 versioned 思路不能替代项目 generation provenance；
- 不引入目录清理或 Keychain 第三方包。

项目自实现只覆盖 Apple API 没有提供的 generation identity、pointer/journal、
canonical digest、fail-closed Recovery 与产品级 retention 语义。

## 8. 验证门禁

- V10 → V11 → V12 每段 source bytes 不变、target reuse、pointer-last、reopen 与全
  关系校验；
- V1 → V12、V7/V8/V9/V10/V11 pointer 和新装全链；
- privacy/tombstone singleton、revision/digest/receipt/ledger 篡改；
- active/unresolved/proven/unproven/invalid generation 在 ordinary runtime 永不删除；
- 不存在 `failedOwnedTarget` 推断、普通 generation purge API 或 purge journal；
- non-UUID、unknown leaf、symlink、path traversal、父路径替换和计划 stale；
- reset 后所有 generation 只通过验证过的 quarantine root 删除；
- pointer/journal/reset 文件保护和 `.systemManaged` 读回；
- 完整 manifest 准确显示 retained/unknown history；
- 全量测试、Release contract、generic build 与项目专属 Simulator。

真机 data-protection class、备份恢复和底层文件系统行为仍在最终 signed RC 上验证。
