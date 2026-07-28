# 0015：Batch 6 全 App 数据清单、关联删除与全部重置

- 状态：Accepted
- 日期：2026-07-28
- 适用版本：App 1.0 / Schema V12
- 前置合同：[0002](0002-batch-0-contract-freeze.md)、[0003](0003-data-safety-foundation.md)、[0007](0007-labs-status-attachments-and-personal-timeline.md)、[0013](0013-parent-record-correction-and-deletion.md)
- 隐私表面：[0014](0014-batch-6-app-lock-and-privacy-shield.md)
- generation 合同：[0016](0016-schema-v11-and-generation-retention.md)

## 1. 决策与 Batch 7 边界

Batch 6 建立一个可信的全 App 数据 taxonomy，并让数据清单、逐项删除、关联影响预览和
全部重置共同消费同一份 manifest。Readable JSON v2、导入/合并/恢复、PDF/CSV 和含
附件的完整备份属于 Batch 7；Batch 6 不创建 Files 文件，也不读取外部备份。

旧 `AppArchiveSnapshot` 只统计少量 legacy 类型，不能作为删除或重置依据。新增
`DataInventoryManifest` 精确覆盖：

1. 当前有效个人事实；
2. 保留的历史、纠错、tombstone、receipt 与审计；
3. 附件 metadata、active bytes、staging、trash 与 journal；
4. reminder/notification 等可重建设备投影；
5. active/inactive generation、pointer、journal 和 preserved legacy bundle；
6. App 无法枚举或删除的系统备份、Photos/Files 原件、导出和截图边界。

任一必需类别读取、关系或文件审计失败时，manifest 标为 incomplete，不把错误显示成
零；逐项关联删除和全部重置入口保持不可执行并进入准确的 Recovery/重试路径。

## 2. Manifest 合同

### 2.1 固定结构与完整 taxonomy

`DataInventoryManifest` 是不可变、`Sendable` 的本机观察，exact shape 为：

```text
DataInventoryCategory
  key: String
  kind: database | fileTree | generation | notification | control
  status: complete | failed
  itemCount: Int64?
  byteCount: Int64?
  retainedSensitiveCount: Int64?
  identityDigest: String?

DataInventoryBoundary
  key: String
  state: notEnumerableByApp

DataInventoryManifest
  generationID: UUID
  datasetID: UUID
  nextLocalRevision: Int64
  capturedAt: Date
  completeness: complete | incomplete
  categories: [DataInventoryCategory]
  unmanagedBoundaries: [DataInventoryBoundary]
  stateDigest: String
  manifestDigest: String
```

每个 category 都必须出现且按下列 ASCII key 升序。V1–V12 的 54 个 SwiftData model
必须且只能映射到一个 database category：

| Category key | kind | exact models / contents |
| --- | --- | --- |
| `db.attachments` | database | `AttachmentRecord` |
| `db.audit` | database | `RecordRevision`, `OperationReceiptRecord`, `OperationReceiptLedgerRecord`, `HistoricalTimeRecord`, `ParentRecordLifecycleHeadRecord`, `ParentRecordMutationEventRecord`, `ParentRecordDeletionTombstoneRecord`, `DataControlDeletionTombstoneRecord` |
| `db.countdown` | database | `CountdownRecord`, `CountdownStateRecord`, `CountdownLifecycleEventRecord`, `CountdownReminderRuleRecord`, `CountdownCommandAuditRecord`, `CountdownV6AuditCheckpointRecord` |
| `db.execution` | database | `AdministrationEventRecord`, `ReminderOverrideRecord`, `ReminderPreferenceRecord` |
| `db.hrt` | database | `HRTProfile`, `HrtJourneyProfileRecord`, `HrtPeriodRecord`, `HrtJourneyLifecycleEventRecord` |
| `db.journey` | database | `JourneyEntry` |
| `db.labs` | database | `LabRecord`, `LabItemDefinitionRecord`, `LabSampleRecord`, `LabResultRecord`, `LabSampleCorrectionSnapshotRecord`, `LabResultCorrectionSnapshotRecord` |
| `db.preferences` | database | `UserPreferencesRecord`, `OnboardingProgressRecord`, `PrivacyControlRecord` |
| `db.regimen` | database | `RegimenVersion`, `RegimenPlanVersionRecord`, `RegimenItemRecord`, `ScheduleRuleRecord` |
| `db.status` | database | `StatusMetricDefinitionRecord`, `StatusObservationRecord`, `StatusObservationCorrectionSnapshotRecord` |
| `db.system` | database | `DatasetMetadata`, `MigrationBackfillState`, `MigrationIssue`, `CoreTimeRegimenBackfillState`, `TodayExecutionBackfillState`, `PersonalTimelineBackfillState`, `CountdownLifecycleBackfillState`, `CountdownIntegrityBackfillState`, `OnboardingBackfillState`, `HrtJourneyLifecycleBackfillState`, `ParentRecordLifecycleBackfillState`, `PrivacyControlBackfillState`, `DataControlBackfillState`, `NotificationCoverageRecord`, `CountdownNotificationCoverageRecord` |
| `files.attachments.active` | fileTree | `Files/Attachments` 下全部直接 UUID 目录及其 regular payload |
| `files.attachments.journal` | fileTree | `Files/.staging/<operation UUID>.json` |
| `files.attachments.staging` | fileTree | `Files/.staging/<operation UUID>/payload` |
| `files.attachments.trash` | fileTree | `Files/.trash/<operation UUID>/payload` |
| `notification.countdown.delivered` | notification | identifier prefix `unmanual.countdown.v1.` 的 delivered request |
| `notification.countdown.pending` | notification | identifier prefix `unmanual.countdown.v1.` 的 pending request |
| `notification.execution.delivered` | notification | identifier prefix `unmanual.exec.v1.` 的 delivered request |
| `notification.execution.pending` | notification | identifier prefix `unmanual.exec.v1.` 的 pending request |
| `storage.control` | control | 本节冻结的 pointer、migration 与 reset control regular file |
| `storage.generation.active` | generation | pointer 精确指向且通过 active V12 审计的 generation |
| `storage.generation.inactive-proven` | generation | 非 active、layout/dataset/schema/provenance 均可验证的 generation |
| `storage.generation.invalid` | generation | 非 UUID、symlink、非 directory、越界，或 layout/schema/文件审计失败的直接子项 |
| `storage.generation.unproven` | generation | 名称合法、文件树可安全枚举，但无法证明完整 provenance 的 generation |
| `storage.legacy` | control | `legacyStoreURL` 主文件及同路径 `-wal`、`-shm` 中实际存在的 regular file |

固定 unmanaged boundary 也全部出现，按 key 的 ASCII 升序排列：

```text
exports        -> notEnumerableByApp
filesSource    -> notEnumerableByApp
photosSource   -> notEnumerableByApp
screenshots    -> notEnumerableByApp
shares         -> notEnumerableByApp
systemBackup   -> notEnumerableByApp
```

它们不是零值 category，也不进入 `itemCount`。UI 必须逐项说明 App 无法枚举或删除这些
系统/外部副本。

### 2.2 计数、读取与失败语义

完整 category 的 `itemCount` 为该 category 下 exact row、file、generation 或 request
数量；`byteCount` 仅对 fileTree/generation/control 有值：fileTree/control 等于全部
in-scope regular file 的逻辑 byte size，generation 等于本节冻结的 durable tree scope
之 checked sum；其余 kind 为 `nil`。为避免把 ID、时间、digest 或通知存在性错误归类
为“不敏感”，完整 category 的 `retainedSensitiveCount` **精确等于** `itemCount`。

失败 category 的 `itemCount`、`byteCount`、`retainedSensitiveCount` 和
`identityDigest` 全部为 `nil`，不得使用零或部分结果。任何一个 category 失败、
category 缺失/重复/未知、database model 未映射或重复映射、boundary 不精确、关系/
revision/digest/文件保护审计失败，都会令全局 `completeness = incomplete`。只有全部
固定 category 为 complete 且全部 boundary 精确匹配时才可为 complete。
`storage.generation.invalid` 是必需的 empty-sentinel category：只有没有任何 invalid
direct child 时才为 complete，且精确 `itemCount = retainedSensitiveCount = 0`、
`byteCount = 0` 并产生 empty identity digest；发现任意 non-UUID、symlink、非
directory、越界或审计失败 entry 时该 category 立即 failed（所有 count/digest nil）且
全局 incomplete。invalid entry 的 `.null` generation identity/tree tuple 只用于内部
Recovery 诊断与测试向量，绝不能形成 complete manifest。

database inventory 必须在同一 actor 隔离只读 context 和冻结水位下：

1. 跑完 V12 foundation、relationship、receipt-ledger 与 overlay validator；
2. `DataInventoryCapacity.maximumRowsPerModel` 固定为 `1_000_000`；对上表每个 model
   先 `fetchCount`，超过上限即 failed；未超限时使用单个
   `fetchLimit = maximumRowsPerModel + 1` 的 bounded fetch 取得该 model 全集，再按下段
   identity tuple 在内存稳定排序。这里刻意不使用 cursor/page，避免 54 个 model 的
   并列 key 或损坏重复身份造成跳行/重行；实际 fetch 数与预先 count 不同也 failed；
3. 对所有 revision-covered fact 证明 `(recordKey, localRevision, digestHex)` 与唯一
   `RecordRevision` 双向一一对应；
4. `RecordRevision` 自身使用下段的 full persisted identity；不把它再次要求配对
   revision；
5. 下列未单独 revision-covered 的 control row 只按稳定 identity 纳入，内容完整性由
   第 1 步 validator 负责：

```text
DatasetMetadata.singletonKey
MigrationBackfillState.taskKey
MigrationIssue.issueKey
CoreTimeRegimenBackfillState.taskKey
TodayExecutionBackfillState.taskKey
NotificationCoverageRecord.coverageKey
PersonalTimelineBackfillState.taskKey
CountdownNotificationCoverageRecord.coverageKey
CountdownLifecycleBackfillState.taskKey
```

实现若发现除此清单外的未 revision-covered model，manifest 必须 incomplete；不得自行
扩大例外。

文件树只接受上述生产 layout 的 exact 路径、regular file/directory 和非 symlink。
active attachment entry 以 metadata 冻结的 relative path 定位并要求 ID、size、
SHA-256 双向一致；staging/trash/journal 必须通过既有事务 journal validator。未知
leaf、symlink、越界路径、重复 inode/path、读取或 hash 失败使对应 category failed。

generation 分类先遵守 ADR 0016 第 3 节的四个 primary classification 与 journal role
crosswalk。每个 `Generations/` 直接子项必须恰好出现一次；active 必须恰好一个并等于
manifest `generationID`。合法 UUID 目录使用 `.uuid` generation ID。non-UUID/其他
invalid entry 只以 `.null` 和 NFC 名称生成内部 Recovery 诊断 tuple；invalid category
立即 failed，不产生 category/manifest digest。对合法 generation，每个 regular file 都
进入下段 canonical tree digest，但 active generation 的 volatile/duplicate scope 使用
下段精确排除规则；所有 in-scope 同大小内容替换必须改变 digest。跨 category 重复、
未知 leaf、pointer/provenance 不一致、tree hash 失败或非法 journal role 使相关
category failed。

`storage.control` 的 base 是 Application Support，允许集合精确为：

```text
Unmanual/GenerationPointer/active.json
  ready manifest 时 required，且必须通过 GenerationPointerStore typed decode、
  generation/dataset/schema 与 active category 交叉核对
Unmanual/Recovery/migration-journal.json
  optional；存在时必须通过 MigrationJournalStore typed decode，并做
  phase/source/target/path/role 交叉核对
UnmanualResetControl/reset-journal.json
  normal ready manifest 时必须 absent；存在即进入 reset Recovery，storage.control
  failed，不发布可删除/重置的 complete manifest
```

`Unmanual/GenerationPointer/` 与 `Unmanual/Recovery/` 不允许其他 leaf；上述 optional
文件缺失记作零 entry，不是失败。pointer required 文件缺失、类型非 regular、symlink、
保护/`.systemManaged` 审计失败、typed decoder/field/cross-reference 失败或出现未知
control leaf 都使 `storage.control` failed。现有 pointer/journal format 没有内嵌
digest，合同不伪称它们有；manifest 使用该次读取的原始 regular-file bytes 的 size 与
SHA-256 承诺 exact control snapshot，语义有效性由 typed decode 与交叉核对保证。

managed layout 的 direct-child whitelist 同样固定：

```text
Application Support/Unmanual/
  Generations/          required directory
  GenerationPointer/    required directory
  Recovery/             required directory

Application Support/UnmanualResetControl/
  reset-journal.json    唯一允许 leaf；normal ready 时必须不存在

Application Support/
  Unmanual.reset-<lowercase operation UUID>/  仅对应有效 reset journal 时允许
```

`Unmanual/` 下其他 direct file/directory/symlink、`UnmanualResetControl/` 下未知或
嵌套 leaf、以及没有 matching typed reset journal 的任意 `Unmanual.reset-*`
quarantine 都使 `storage.control` failed、全局 incomplete 并进入 Recovery。空的
`UnmanualResetControl/` 可存在且 itemCount 为零；其他不以 `Unmanual.reset-` 开头的
Application Support sibling 不属于本 App 的 managed root，不能越界枚举或删除。
`Generations/` 的每个 direct child 由四个 generation category 恰好接管；
generation 内的 `Store/`、`Files/` 与其他 leaf 再按 durable tree 与 attachment layout
规则完整枚举，不能从 root whitelist 与 generation taxonomy 之间漏掉 payload。

notification 只枚举两个固定 prefix；foreign request 不进入 category，也不被删除。
枚举失败使四个 notification category 全部 failed。

需要生成删除影响时只读取目标闭包；普通 Archive 概览可以用 bounded count，但形成
complete manifest 时必须生成下段 exact identity digest。任何读取都不能把错误伪装成
空集合。

### 2.3 Category identity digest

每个 complete category 的 `identityDigest` 使用 `RecordDigestV1.sha256Hex`：

```text
recordType = "DataInventoryCategoryV1"
recordID   = CoreTimeRegimenBackfill.stableUUID(
               for: "data-inventory-category:" + category.key
             )
```

exact common fields：

```text
key                    -> .string
kind                   -> .string
itemCount              -> .integer
byteCount              -> .integer 或 .null
retainedSensitiveCount -> .integer
entryCount             -> .integer
```

database entry 先带固定 `entryVariant`，variant rank 精确为 `fact = 0`、
`revision = 1`、`control = 2`；先按 rank 升序，再按各 variant 的下列 tuple 排序。
每个 entry 都使用 `entry.<zero-based-index>.variant -> .string`，再编码其 variant
字段：

- revision-covered database fact：按 `recordKey` UTF-8 升序；字段为 `recordKey`
  `.string`、`localRevision` `.integer`、`digestHex` `.string`，variant 为 `"fact"`；
- `RecordRevision`：按 `recordKey`、`localRevision` 升序；字段为 `recordKey`
  `.string`、`recordType` `.string`、`recordID` `.uuid`、`datasetID` `.uuid`、
  `localRevision` `.integer`、`digestVersion` `.integer`、`committedAt`
  `.timestampMicroseconds`、`digestHex` `.string`，variant 为 `"revision"`；
- 上段允许的 unrevisioned control row：按
  `modelType + ":" + stableIdentity` 的 UTF-8 升序；`modelType` 是 taxonomy 表中
  不含 module prefix 的 exact Swift type identifier（例如 `"DatasetMetadata"`），
  不得使用 `String(reflecting:)`；字段为 `modelType` `.string`、
  `stableIdentity` `.string`，variant 为 `"control"`；
- fileTree/control regular file：按 NFC relative path UTF-8 升序；字段为
  `relativePath` `.string`、`fileType` `.string("regular")`、`byteCount`
  `.integer`、`sha256Hex` `.string`；
- generation：先按 NFC `entryName` UTF-8 升序；字段为 `entryName` `.string`、
  `generationID` `.uuid` 或 `.null`、`primaryClassification` `.string`、
  `journalRoleCount` `.integer`、每个 ASCII 升序 role 的
  `journalRole.<j>` `.string`、`relativePath` `.string`、`byteCount`
  `.integer`、`treeDigest` `.string`；
- notification：按 identifier UTF-8 升序；字段为 `namespace` `.string`，其 exact
  value 只能是 `execution` 或 `countdown`，`deliveryState` `.string` 的 exact value
  只能是 `pending` 或 `delivered`，以及 `identifier` `.string`。

database category 的 stable tuple 是其所有 mapped model 的 entry 合集，不按 model
另起未声明层级；上述 variant rank 是跨 model 合集的唯一全序。非 database category
不编码 `variant`。空 category 合法，`entryCount = itemCount = 0`，仍必须产生
identityDigest。failed category 没有 digest。

每个 generation 的 `treeDigest` 使用 `RecordDigestV1.sha256Hex`：

```text
recordType = "DataInventoryGenerationTreeV1"
recordID   = generationID
             或 CoreTimeRegimenBackfill.stableUUID(
                  for: "invalid-generation-entry:" + NFC(entryName)
                )
```

exact fields：

```text
entryName              -> .string
generationID           -> .uuid 或 .null
primaryClassification  -> .string
journalRoleCount       -> .integer
journalRole.<j>        -> .string
fileCount              -> .integer
file.<i>.relativePath  -> .string
file.<i>.fileType      -> .string("regular")
file.<i>.byteCount     -> .integer
file.<i>.sha256Hex     -> .string
```

role 按 ASCII bytes 升序；regular file 按相对 generation 根的 NFC path UTF-8 bytes
升序。目录本身不产生 entry；空目录 `fileCount = 0`。inactive generation 的 durable
tree scope 是整个 generation 下所有 regular file。active generation 因 SwiftData
没有 close API，且 SQLite 只读连接也可能改变 `Store/user.sqlite-shm`，其 durable tree
scope **精确排除** `Store/user.sqlite`、`Store/user.sqlite-wal`、
`Store/user.sqlite-shm` 与整个 `Files/` subtree：active DB 的逻辑内容已由全部
`db.*` category 承诺，active Files 内容已由四个 `files.attachments.*` category
承诺。tree fields 额外固定：

```text
scopeRawValue -> .string("active-logical-overlay" | "closed-full-tree")
excludedCount -> .integer
excluded.<i>  -> .string
```

active 的 `excluded.<i>` 固定按 ASCII path 排序并逐项写入上述 4 个 token，其中
`Files/**` 使用 literal token；inactive 的 `excludedCount = 0`。active 仍必须验证
这些路径位于 exact generation、类型/layout/文件保护正确，只是不读取其 volatile/
重复内容进入 tree digest。active 其余 sidecar/未知 regular file 必须进入 tree；
`byteCount` 只等于 durable tree scope 内全部 `file.<i>.byteCount` 的 checked sum。
任何 symlink、非 regular leaf、路径重复/越界、scope 外未知结构、读取或 hash 失败都
不产生部分 tree digest，而是令该 generation 的 category failed。

### 2.4 State 与 Manifest digest

`stateDigest` 表示可比较的数据状态，不包含观察时间，使用
`RecordDigestV1.sha256Hex`：

```text
recordType = "DataInventoryStateV1"
recordID   = CoreTimeRegimenBackfill.stableUUID(
               for: "data-inventory-state-v1"
             )
```

exact fields 与下方 manifest fields 完全相同，但**排除** `capturedAt`、
`stateDigest` 和 `manifestDigest`。因此同一 generation/dataset/watermark/categories/
boundaries 的两次完整重算产生相同 state digest；任一 row/file/hash/generation/
notification/completeness 变化都会改变它。reset/删除 stale comparison 使用
`stateDigest`，不得比较包含观察时间的 `manifestDigest`。

`manifestDigest` 也使用 `RecordDigestV1.sha256Hex`：

```text
recordType = "DataInventoryManifestV1"
recordID   = CoreTimeRegimenBackfill.stableUUID(
               for: "data-inventory-manifest-v1"
             )
```

exact fields：

```text
generationID            -> .uuid
datasetID               -> .uuid
nextLocalRevision       -> .integer
capturedAt              -> .timestampMicroseconds
completeness            -> .string
stateDigest             -> .string
categoryCount           -> .integer
category.<i>.key        -> .string
category.<i>.kind       -> .string
category.<i>.status     -> .string
category.<i>.itemCount  -> .integer 或 .null
category.<i>.byteCount  -> .integer 或 .null
category.<i>.retainedSensitiveCount -> .integer 或 .null
category.<i>.identityDigest          -> .string 或 .null
boundaryCount            -> .integer
boundary.<i>.key         -> .string
boundary.<i>.state       -> .string
```

`categories` 与 `unmanagedBoundaries` 都先按 key 的 ASCII bytes 严格升序，拒绝重复；
`i` 为无前导零十进制下标。`stateDigest`/`manifestDigest` 自身分别不进入自己的
fields；manifest 只额外绑定已经独立重算通过的 state digest。固定 enum raw value就是
以上英文 token；字符串进入 `RecordDigestV1` 前使用 Unicode NFC。禁止把任意
`JSONEncoder` 输出当 canonical bytes。

## 3. 删除目标与保留语义

App 1.0 的用户可见删除目标是：

- 单附件；
- 化验或状态父记录；
- Countdown；
- Journey entry；
- 一次执行 occurrence；
- 一个未封存草稿；
- 某一个 sealed 方案版本；
- 整段 HRT 历程；
- 全部数据。

已有附件、父记录和 Countdown 命令继续复用原 typed repository。V12 新增通用但有明确
target kind 的 `DataControlDeletionTombstoneRecord`。它是不可变的 terminal overlay：
读取、计划、提醒与 Batch 7 export snapshot 必须先应用 overlay，但它绝不原地修改
V1–V11 sealed、append-only 或 digest-covered facts。tombstone 保存 target identity、
expected token、删除时 canonical attachment/notification manifest、impact digest、
committed timestamp 和计数。它不保存目标正文、药名、剂量、状态备注或 HRT 日期；
attachment manifest 为验证文件事务会保留 opaque path、原文件名、size/hash 与
deletion operation ID，属于 UI 必须列明的 retained audit。

不同目标的语义固定如下：

- **单附件**：删除 active generation 私有副本，metadata 终态 deleted；不删除原始
  Photos/Files 文件。
- **化验/状态父记录**：继续采用 ADR 0013 的有效投影删除与活动附件清除；V5 原始事实
  和纠错审计保留。
- **Countdown**：继续采用终态 deleted 和敏感标题清空；lifecycle/audit 保留。
- **Journey entry**：写 terminal tombstone，从普通投影移除；V1 row 和 revision 保持
  不变。其全部 active 私有附件按既有 journal 事务移入 trash、metadata 终态 deleted；
  任一步失败按逆序 rollback/finalize，不能留下普通视图不可见但仍可预览的图片。
- **执行 occurrence**：对 occurrence key 写 terminal tombstone，普通 Today/时间线
  不再展示该 occurrence；既有 event、note、receipt、revision 与 supersession chain
  完全不变，作为明确列出的 retained audit。
- **未封存草稿**：同样写 terminal tombstone，不物理删除 V3 facts 或 revisions。普通
  方案页不再展示，任何 schedule/reminder planner 都必须忽略其 item/rule。
- **sealed 方案版本**：写 terminal tombstone；既有 version/item/schedule、receipt、
  revision、有效日期和 lineage 完全不变。后继 `previousVersionID` 继续指向该 terminal
  node，不重连也不伪造历史；普通页面显示“已删除方案”。planner 从 tombstone
  生效点起忽略它的 schedule/reminder。由于现有 notification identifier 不可逆且
  delivered request 没有可靠 target association，逐项删除只清除全部 App-owned
  **pending** 后按剩余事实重新计划；不会删除任何 delivered 历史，也不宣称精确命中
  某条通知。历史执行关联仍只显示“已删除方案”，不恢复方案 payload。
- **整段 HRT 历程**：写 singleton target 的 terminal tombstone；普通 profile/period/
  lifecycle 投影不再展示。既有 profile、period、event、notes、receipt、revision 与
  chain 完全不变，作为 retained audit。方案、执行、化验和状态不级联删除，只在影响
  预览中说明会失去普通历程展示。

这些都是当前 active generation 的产品级逻辑删除，不是 payload purge 或闪存取证级
擦除。既有事实、保留 audit、inactive generation 与系统备份可能仍包含历史值；UI 和
manifest 必须在确认前准确说明“从普通页面移除，历史校验副本仍保留”。只有“全部数据
重置”承诺删除本机 App 当前管理的全部 generation 和个人资料。

## 4. 影响预览与事务

`DeletionImpact` 冻结：

- target kind/ID；
- generation、dataset、next revision；
- target head/revision/digest；
- 关联 records、历史投影、附件 identity/size/hash；
- reminder/pending notification IDs；
- 将保留的 opaque audit 与不会删除的外部副本说明；
- canonical impact digest。

impact digest 的 domain 固定为
`recordType = "DeletionImpactV1"`、`recordID =
CoreTimeRegimenBackfill.stableUUID(for: "data-control-target:" + targetKey)`。
exact fields 为：

```text
generationID/datasetID/targetID                  -> .uuid（nil -> .null）
expectedNextLocalRevision/expectedLocalRevision
retainedRecordCount/deletedAttachmentCount/deletedAttachmentBytes
affectedReminderCount                            -> .integer(Int64)
targetKindRawValue/targetStableKey/expectedRecordKey/expectedDigestHex
targetSnapshotManifest/attachmentManifest/notificationManifest
boundaryContractVersion                          -> .string
```

`boundaryContractVersion` 固定 `"batch6-impact-v1"`，它按 target kind 映射本 ADR 第 3 节
已冻结的 retained audit、外部 Photos/Files、系统备份和“逻辑删除而非物理擦除”说明；
UI 可以本地化显示，但不能让任意文案进入 digest。target/source/manifest/count 字段都
逐字复制到 tombstone，因此冷启动 validator 可重建 impact digest；不从当前 pointer
猜历史 generation 或水位。

`retainedRecordCount` 是删除完成后仍保留的**target-specific 持久 row** 数，不是
`dct1.sourceCount` 的别名。exact 公式为：

```text
sourceCount                 = dct1 中唯一 source entry 数
associatedReceiptCount      = resultRecordType + resultRecordID
                              精确命中任一 source entry 的唯一 receipt 数
retainedRecordCount         =
    2 * sourceCount                       // source fact + 它的 RecordRevision
  + 2 * associatedReceiptCount            // 既有 receipt + 它的 RecordRevision
  + 6 * deletedAttachmentCount            // terminal metadata/current revision +
                                           // creation receipt/revision +
                                           // deletion receipt/revision
  + 4                                    // 新 tombstone/revision +
                                           // delete receipt/revision
```

dct1 对 supersession/lifecycle 明确包含全部 chain node，不只 head，因此逐节点计数。
source manifest 禁止包含 `AttachmentRecord` 与 `OperationReceiptRecord`，避免与
attachment manifest/receipt 双计。preview/确认水位时，每个将删除的 active
attachment 必须精确对应一张、且仅一张
`resultRecordType = "AttachmentRecord"` / `resultRecordID = attachmentID` 的原创建
receipt 与其唯一 revision；attachment manifest 预分配的独立 deletion operation ID
此时必须没有 receipt、tombstone 或其他既有 operation 占用。`retainedRecordCount`
可以据此预测成功后必然形成的六行闭包，但绝不要求未来 deletion receipt 提前存在。

DB commit 后，每个 terminal attachment 必须精确对应两张、且仅两张 matching receipt：
原 creation receipt 与本次预分配 operation 的 deletion receipt；两张 receipt 都有唯一
revision，且 deletion receipt/revision 与 terminal metadata 的 committed revision/
timestamp 一致。same-operation replay 走 post-commit 六行验证，不重新生成 pre-confirm
impact。缺少、额外、提前出现或错配时 fail closed。
共享
`OperationReceiptLedgerRecord`、全局 backfill marker 和 shared notification coverage
不是 target-specific，不进入这个数；确认页必须另行从全 App manifest 的 audit/system
category 说明它们仍存在。validator 从 dct1、receipt 双向映射和 attachment manifest
重算公式；preview 验证可预测的 creation 两行与未来 operation 空位，post-commit 验证
每个 attachment 的六行闭包，少报一行即 fail closed。

attachment manifest 按稳定顺序冻结 attachment ID、owner type/ID、relative path、
original filename、content type、createdAt、byte count、SHA-256 和独立 deletion
operation ID。只有 `administrationOccurrence`、`draftRegimenVersion` 和
`sealedRegimenVersion` 三种 planner target 的 notification manifest 才按稳定顺序
冻结删除前两个 App-owned namespace 内的全部 **pending** identifier 与 namespace，
且 `affectedReminderCount` 等于 entry count。`journeyEntry` 与 `hrtJourney` 使用
canonical empty notification manifest、count 为零并完全跳过通知 mutation/post-check。
manifest 不包含 delivered，也不声称把 hashed identifier 逆推出某个方案 target。
planner target 的确认页必须说明这是 pending 的全局重排，与目标无关的 delivered
通知历史会保留。两个 manifest 使用下一段冻结的版本化 canonical codec，不依赖任意
`JSONEncoder` 排序。

两个持久化 `String` 的 exact encoding 固定为：

```text
attachmentManifest   = "dcm1-a." + base64url(canonicalAttachmentBytes)
notificationManifest = "dcm1-n." + base64url(canonicalPendingNotificationBytes)
```

`base64url` 使用 RFC 4648 URL alphabet、无 `=` padding。canonical bytes 的整数均为
big-endian；UUID 使用 RFC 4122 的 16 个网络序 bytes；字符串先做 Unicode NFC，再以
`UInt32 byteLength + UTF-8 bytes` 编码；时间复用
`RecordDigestV1.timestampMicroseconds` 的 nearest-microsecond 舍入并编码为单个
`Int64`；SHA-256 是 32 个原始 bytes。payload 先写 `UInt32 entryCount`：

- attachment entry 固定字段顺序为 attachment UUID、owner type、owner UUID、
  relative path、original filename、content type、created timestamp、`Int64`
  byte count、SHA-256、deletion-operation UUID；按 attachment UUID bytes 升序；
- notification entry 固定字段顺序为 namespace byte（execution `0x01`、countdown
  `0x02`）和 identifier；按 namespace byte、identifier UTF-8 bytes 升序。

空集合编码为四个全零 count bytes。decoder 拒绝未知 prefix/version、padding、
非最短长度、非法 UTF-8/NFC、非法 UUID/hash/time/count、重复或非升序 entry、
路径越界/绝对路径、未知 namespace、trailing bytes，以及 decode 后重新编码不完全
等于原 String 的值。

UI 完整展示范围后才允许确认。确认时在 exclusive mutation lease 内重算 pointer、
manifest head 与 impact；planner target 还要重新枚举 pending，并要求其 canonical
`dcm1-n` **逐 byte 等于 command/确认预览中的 notification manifest**，同时把
delivered 集合只保存在本次调用内存作为 guard。任何变化返回 `impactChanged`，零写入
并保留用户上下文。持久 notification manifest 因此永远是 exclusive lease 下、任何
附件/DB/通知 mutation 之前的确认快照。

成功调用顺序固定为：

1. 阻止新 writer/read/attachment preview/reminder reconciliation，并等待既有 lease；
2. 对附件使用 generation-local journal 移入 recoverable trash；
3. 单个 SwiftData transaction 写 typed mutation/tombstone、revision、receipt 与
   ledger；禁止重写既有事实、revision、receipt 或 digest；
4. DB 失败显式 rollback，并逆序恢复附件；
5. DB 成功后强制 finalize trash；
6. 对上述三种 planner target，使用确认时已冻结的 notification manifest 与内存
   delivered guard；DB commit 后只重新枚举**当前** owned pending 作为实际 remove
   输入，不改写 tombstone 中的确认快照。移除当前全部 owned pending 并在重新计划前
   核对为零，再依据 tombstone overlay 后的剩余事实调和为当前 deterministic desired
   set。旧 identifier 若仍属于剩余 target 可以合法重新出现；delivered removal API
   完全不得调用。调和后立即再次枚举 delivered，与本次内存 guard 不同则进入可重试
   Recovery，不能显示本次成功；
7. 重跑关系、digest、附件树、notification coverage、manifest 和文件保护审计；
8. 任一 rollback/finalize/审计无法闭环都进入 Recovery，UI 不显示成功。

UI 不获得 raw `ModelContext`，也不自行拼装级联操作。

V12 持久 validator 从 tombstone 解码两个 manifest，核对 count/bytes、唯一
attachment/deletion operation、terminal metadata、逐附件 deletion receipt、
historical pending-set commitment 和 impact/command digest。文件删除后不从已不存在
的 bytes 猜 identity；证据来自冻结 manifest、terminal metadata 与 receipt。
notification manifest 是“删除确认时看到什么”的不可变审计，不是未来 pending
集合；重开或 same-op replay 只按**当前** overlay 与时间窗口运行幂等 reconciliation，
不得要求旧 ID 永久消失。delivered pre/post equality 只属于同一次 runtime mutation
的瞬时 guard，不写入 tombstone，也不由冷启动 validator 伪造重算。manifest codec
损坏、同大小附件替换、pending manifest identity 漂移或孤立 receipt 都 fail closed。

## 5. Runtime quiesce

新增 `AppDataControlCoordinator`，统一发放 read lease、typed mutation lease 和 reset
exclusive lease。现有 writer、read actor、附件 preview/mutation、提醒调和和隐私
coordinator 都绑定 session epoch 与 generation ID。

进入 exclusive reset 后：

- 拒绝所有新 lease；
- 等待现有有限任务完成或取消；
- drain 后先把仍有效的 `AppDataSession` 转为 reset coordinator 独占只读所有权，不
  释放 container/reader，用它完成 lease 内 state manifest 重算；
- state 变化时把同一未失效 session 原样还给 runtime，再开放 lease；
- state 一致后才 invalidate 旧 session epoch，从根视图移除并释放
  `AppDataSession`、container、writer、reader、附件与提醒引用，然后持锁写第一份
  `quiesced` journal；
- 旧 Task 即使稍后完成也不能发布状态或再次写入。

quiesce 超时或无法证明 lease drain 时零删除，保持原资料并显示失败。不能为了重置调用
`exit(0)` 或假装 App 能自行重启。

## 6. 全部数据重置

全部重置使用 App Support 下经过路径验证的控制与 quarantine 目录：

```text
Library/Application Support/Unmanual/
Library/Application Support/UnmanualResetControl/
Library/Application Support/Unmanual.reset-<operation-id>/
<ModelConfiguration legacy store URL>[-wal|-shm]
```

reset control 只保存受 complete protection 和 `.systemManaged` 审计的原子 JSON
journal；不保存个人 payload。exact Codable shape 为：

```text
DataResetJournalV1
  formatVersion: Int                         // 必须 1
  operationID: UUID
  phaseRawValue: String
  confirmedStateDigest: String
  exclusiveManifestDigest: String
  createdAt: Date
  updatedAt: Date
  managedRootSourcePath: String
  managedRootQuarantinePath: String
  oldManagedRootStateRawValue: String
  quarantineRootPath: String
  quarantineStateRawValue: String
  legacyParts: [DataResetLegacyPartV1]       // 精确 3 项
  ownedNotifications: [DataResetNotificationV1]
  notificationClearEpoch: Int64
  notificationClearRound: Int
  freshGenerationID: UUID
  freshDatasetID: UUID
  freshNextLocalRevision: Int64?
  journalDigest: String

DataResetLegacyPartV1
  roleRawValue: String
  sourcePath: String
  quarantinePath: String
  wasPresent: Bool
  stateRawValue: String

DataResetNotificationV1
  namespaceRawValue: String
  deliveryStateRawValue: String
  identifier: String
```

enum raw values 精确为：

```text
phase:
  quiesced | quarantinePrepared | managedRootQuarantined |
  legacyPartsQuarantined | restartRequired | quarantinePurged |
  freshStorePrepared | freshStoreOpened | ownedNotificationsConvergedToZero |
  verifiedEmpty | complete

oldManagedRootState:
  sourceExpected | quarantined | purged

quarantineState:
  absent | created | purged

legacy role:
  main | wal | shm

legacy state:
  sourceExpected | absentConfirmed | quarantined | purged

notification namespace:
  execution | countdown

notification delivery state:
  pending | delivered
```

`legacyParts` 必须按 `main, wal, shm` 的以上固定顺序恰好三项；source 分别是
`legacyStoreURL`、`legacyStoreURL + "-wal"`、`legacyStoreURL + "-shm"`，quarantine
分别是 `<quarantineRoot>/legacy/main`、`.../wal`、`.../shm`。`wasPresent = false`
只能配 `absentConfirmed` 且永不变；`wasPresent = true` 从 `sourceExpected` 到
`quarantined` 再到 `purged`。owned notifications 按 namespace、delivery state、
identifier 的 UTF-8 bytes 严格升序且无重复，只接受两个冻结 prefix 的匹配 request；
identifier 不允许进入其他 namespace。

所有 path 都是创建 journal 前用 production layout 取得并 standardize/resolve 后冻结的
绝对 path；decoder 每次重开都重新从 production layout 推导 expected path 并逐字比对，
还要验证共同 App Support 容器、非 symlink、direct-child/quarantine 关系。不得信任
journal 自己提供路径作为授权来源。

`journalDigest` 使用 `RecordDigestV1.sha256Hex`：

```text
recordType = "DataResetJournalV1"
recordID   = operationID
```

exact fields：

```text
formatVersion                           -> .integer
operationID                             -> .uuid
phaseRawValue/confirmedStateDigest
exclusiveManifestDigest                -> .string
createdAt/updatedAt                     -> .timestampMicroseconds
managedRootSourcePath
managedRootQuarantinePath
oldManagedRootStateRawValue
quarantineRootPath
quarantineStateRawValue                 -> .string
legacyPartCount                         -> .integer(3)
legacy.<i>.roleRawValue
legacy.<i>.sourcePath
legacy.<i>.quarantinePath
legacy.<i>.stateRawValue                -> .string
legacy.<i>.wasPresent                   -> .bool
ownedNotificationCount                 -> .integer
notification.<i>.namespaceRawValue
notification.<i>.deliveryStateRawValue
notification.<i>.identifier             -> .string
notificationClearEpoch                  -> .integer
notificationClearRound                  -> .integer
freshGenerationID/freshDatasetID        -> .uuid
freshNextLocalRevision                  -> .integer 或 .null
```

`journalDigest` 自身不进入 fields。JSON 仅是 transport：使用项目 sorted-key/
ISO-8601 protected atomic writer；canonical identity 只以上述 RecordDigestV1 为准。
`oldManagedRootStateRawValue` 始终描述确认时那一份旧 root；fresh bootstrap 后即使同一
source path 被新 root 复用，它仍保持 `purged`，新 root 身份只由预分配 fresh IDs、
pointer 与 V12 post-audit 证明。
由于该 writer 的 ISO-8601 transport 不承诺保存小数秒，`createdAt`/`updatedAt` 在构造
value 前必须归一到 UTC 整秒，decode 后仍精确相等，再以
`.timestampMicroseconds`（必为 1,000,000 的整数倍）进入 digest。
每次写入先生成新的完整 value/digest，原子替换，随后立即重读、typed decode、重算
digest、路径/保护/backup policy 核对；失败不执行下一项 destructive action。

持久状态机：

```text
quiesced
  -> quarantinePrepared
  -> managedRootQuarantined
  -> legacyPartsQuarantined
  -> restartRequired
  -- 下一次冷启动、任何 ModelContainer 打开前 -->
  -> quarantinePurged
  -> freshStorePrepared
  -> freshStoreOpened
  -> ownedNotificationsConvergedToZero
  -> verifiedEmpty
  -> complete
```

`selected` 只是确认 UI 的内存状态，不写 journal。用户确认后必须先取得 exclusive
reset lease、drain 全部 writer/read/preview/reminder task，但暂时由 reset coordinator
独占持有现有 session/container。它使用这份仍可读、已无并发 writer 的 session 重算
complete manifest、production paths 和当前 owned notifications；新
`stateDigest` 必须与确认预览逐 byte 相等，`capturedAt` 和新的 manifest digest 可以
不同。任一 state 变化返回 `impactChanged`，释放 lease并把未失效 session 原样还给
runtime，零 journal、零文件动作。

只有 state 一致时才预分配 operation/fresh IDs，随后 invalidate 旧 session epoch、从
根视图移除所有 reader/writer/preview 引用并释放 reset-owned session/container；exclusive
lease 全程不释放。最后把第一份 `phase = quiesced` journal 原子写入和读回，其中
`confirmedStateDigest` 是两次相同的 state digest，`exclusiveManifestDigest` 是 lease
内重算的完整 observation digest。journal 写失败进入无 destructive action 的
Recovery；旧 root 保持原位，下次冷启动可正常重新打开。这样既不会先释放后又尝试读取
54 个 model，也不存在“确认后仍可写入、随后被未预览地删除”的窗口。合法
shape/transition固定：

- `quiesced`：managed root `sourceExpected`、quarantine `absent`；
  present legacy 为 `sourceExpected`，absent legacy 为 `absentConfirmed`；
  notification epoch/round 都为 `0`。`freshGenerationID` 与 `freshDatasetID` 在这次
  journal 写入前预分配并从此不可变，`freshNextLocalRevision` 为 nil；
- 创建 exact quarantine parent、`managed-root/` 尚不存在且 `legacy/` 为空/仅含创建
  所需空目录，反向枚举通过后原子写 `quarantinePrepared`：managed root 仍
  `sourceExpected`、quarantine `created`。若在 mkdir 后、写 journal 前崩溃，
  `quiesced` replay 只接受同一 exact path 的上述空结构并补写
  `quarantinePrepared`；出现任何 regular file、symlink 或未知 leaf 都 Recovery；
- 只有从 `quarantinePrepared` 完成 root move 并反向确认后，才原子更新为
  `managedRootQuarantined`：managed root `quarantined`、quarantine `created`；
- 三个 legacy part 按固定顺序逐项 move。每完成一项就保持
  `managedRootQuarantined` phase 但原子更新该 part 为 `quarantined`；全部 present
  part 已 quarantined 后才进入 `legacyPartsQuarantined`，随后
  `restartRequired` 只改变 phase；
- root/legacy 每一个 move 都使用同一 exact replay matrix。对 journal 仍为
  `sourceExpected` 的 present item：`source present + target absent` 才执行 move；
  `source absent + exact target present` 表示 move 已完成但 journal 更新前崩溃，必须
  对 target 的 real path、类型、非 symlink、父目录和冻结 role 做完整反向审计后补写
  `quarantined`；两者同时存在或同时缺失均 Recovery。`wasPresent = false` /
  `absentConfirmed` 的 legacy item 要求 source 与 target 始终都 absent。journal 已为
  `quarantined` 时，在 purge 前只接受 `source absent + target present`；其他组合仅能
  走下述 cold-launch purge-after-action 特例，不能重新 move 或覆盖 target；
- 当前进程不得越过 `restartRequired`。下一次 cold launch 在任何 container 前，
  先按 source/target 实际存在性幂等收敛未记账 move；source 与 target 同时存在、
  expected present 却两者都缺失、内容角色/path 不符都进入 Recovery；
- 精确删除 quarantine 并反向确认后进入 `quarantinePurged`：managed root与所有
  wasPresent legacy 为 `purged`、absent legacy 保持 `absentConfirmed`、quarantine
  `purged`；若 cold-launch `restartRequired` replay 发现全部 source 与整个 exact
  quarantine 都已不存在，视为上次 `removeItem` 已完成但 journal 更新前崩溃，可以在
  再次反向枚举后直接写 `quarantinePurged`，不得据此接受任何非 exact path 缺失；
- `quarantinePurged` 反向审计通过后先写 `freshStorePrepared`，授权
  `.freshAfterReset(expectedGenerationID:expectedDatasetID:)` 只使用 journal 已冻结的
  exact IDs。该 bootstrap 必须幂等：root 不存在则创建；若崩溃留下 root，则只接受
  exact generation/dataset 的允许新装 layout，继续 backfill/validation/pointer-last；
  mismatched ID、unknown leaf 或无法证明为空的新事实进入 Recovery，绝不普通收养或
  猜测删除。崩溃于 pointer/store 创建后、journal 更新前时仍保持
  `freshStorePrepared`，下次用相同 IDs 重放；
- `freshStoreOpened` 才允许 `freshNextLocalRevision` 非 nil，且等于 V12 新装完成后的
  实际 allocator；此前只有该字段为 nil，两个 fresh ID 始终非 nil；
- notification 每完成一轮枚举/移除/重枚举就把 round 加一并原子写回，每个 epoch 的
  round 范围 `0...3`；
  只有 owned pending/delivered 同时为零时进入
  `ownedNotificationsConvergedToZero`；
- 某 epoch 第 3 轮后仍非零或遇到可重试系统错误，当前调用返回 Recovery，不继续忙等；
  下一次明确 retry/cold launch 在任何新 notification mutation 前，原子执行
  `notificationClearEpoch += 1`、round 重置为 `0`，再允许最多三轮。epoch 必须非负且
  checked increment；溢出 fail closed。这样“三轮”是每次尝试的有限上限，不是永久
  放弃清理；
- 从 `quiesced` 到 `freshStorePrepared` 的所有 phase 强制
  epoch/round 都为 `0/0`。只有 `freshStoreOpened` phase 允许清理进度：
  `epoch >= 0` 且 round 为 `0...3`；若第一次枚举已经 owned-zero，可以保持 round `0`
  直接前进。进入 `ownedNotificationsConvergedToZero` 后，epoch/round 冻结，
  `verifiedEmpty`、`complete` 与 crash replay 都不得再改变；
- `verifiedEmpty` 需要 fresh IDs/watermark、root/layout/V12/notification 全部 post-audit
  成功；`complete` 只在同样证据重读仍成立后写入。随后精确删除
  `reset-journal.json` 和空 control directory；若崩溃留下 complete journal，下一次启动
  重验同样证据后只执行这一步清理；
- phase 不得回退或跳跃；唯一允许的同 phase 更新是逐 legacy part、notification round
  或上述 retry epoch 的进度。每一 mutation 先满足当前 shape，再完成一个文件/通知
  动作，再读回文件系统事实并原子写下一 shape。

过程如下：

1. manifest 完整且用户二次确认后，获取 exclusive reset lease并 drain；由 reset
   coordinator 暂持 session，在 lease 内重算 complete manifest、精确路径和当前
   App-owned notification IDs，与确认 `stateDigest` 不同则 `impactChanged`、零写入；
2. state 一致后预分配 operation/fresh IDs，invalidate epoch、移除发布引用并释放
   session/container；保持 exclusive，原子写并读回第一份 `quiesced` reset journal，冻结
   managed source root、`legacyStoreURL` 主文件/WAL/SHM 的存在状态与每一条精确路径、
   quarantine root、confirmed state/exclusive manifest digest 和 lease 内枚举的
   notification IDs；
3. 再次验证 managed source、legacy bundle parts 和 quarantine 都是 production layout 返回的精确
   路径、位于相同 App Support 容器、不是 symlink，且 quarantine 不存在；
4. 创建唯一 quarantine，按 journal 的逐项 phase 把 `Unmanual` root 移到
   `quarantine/managed-root`，把所有实际存在的 legacy main/WAL/SHM 移到
   `quarantine/legacy/`；第一项 source move 是不可取消点，逐项中断由 journal 恢复；
5. runtime 保持无敏感内容的 `restartRequired`，不在当前进程 purge quarantine、打开
   新 store 或宣称完成。SwiftData 没有公开 close API，因此只有进程结束才是旧
   container/context/file handle 的完成门禁；
6. 下一次冷启动在创建任何 `ModelContainer` 之前先读取 reset journal，完成遗漏的
   legacy quarantine，确认 managed root 和所有 legacy bundle part 都已离开原路径，
   再精确删除 quarantine 并反向枚举确认不存在；
7. 使用显式 `.freshAfterReset` bootstrap 建立全新 dataset、V12 空 store 和 onboarding
   未完成状态，并强制使用 journal 预分配的 generation/dataset IDs。该 mode 要求
   legacy main/WAL/SHM 全部不存在，并禁止 legacy adoption；不满足即 Recovery，绝不能
   调用普通新装探测重新收养旧资料；
8. 通知清理先枚举 owned pending 与 delivered，移除后二次枚举；若清理过程中 request
   从 pending 变为 delivered，则继续收敛。每个 retry epoch 最多三轮，每轮只处理两个
   冻结 namespace，直到 pending/delivered owned count 同时为零；foreign
   notification 不动；
9. 重开核对新 root 只含允许的新装文件、V12 关系、文件保护与 `.systemManaged`，且
   legacy 原路径、quarantine 和 owned notifications 都为零；
10. 删除 reset journal/control 空目录，进入新 onboarding。

quarantine 与 root 都只能用预先冻结的绝对 URL；禁止 glob、未解析环境变量、宽泛
Application Support 删除或“清空全部通知”。

### 崩溃与失败语义

- source move 前失败：旧 root 保持 active，下次启动可安全取消未开始 journal；
- source move 后失败：启动先读取 reset control，不得把缺失 root 当新装成功；逐项完成
  managed root 与 legacy main/WAL/SHM 的 quarantine；
- 当前进程永远不 purge quarantine；只有下一次 cold launch、任何 container 打开前
  才能证明旧 handle 已结束并执行 purge；
- fresh store 未验证：继续留在中性 reset Recovery，可重试建立新 root；
- 通知清理或 post-clear owned-zero 核对失败：不能宣称完成；
- quarantine 删除失败：不得打开新 store或显示“已全部清除”；
- 每个 phase 重复执行必须幂等；
- source quarantine 一旦 purge，不允许回滚到旧资料。

重置删除当前设备 App 管理的 active/inactive generations、store/WAL/SHM、附件、
staging/trash、pointer、migration/recovery journal、`legacyStoreURL` 外部 preserved
legacy main/WAL/SHM、隐私/onboarding 偏好和项目临时资料。它不删除 iOS 已生成的系统
备份、Photos/Files 原件、已导出/分享副本、截图或 bundle 内公共内容；也不承诺取证级
安全擦除。

## 7. 复用与依赖调查

调查日期为 2026-07-28。

| 候选 | 许可证与维护 | 匹配与风险 | 决定 |
| --- | --- | --- | --- |
| Apple SwiftData / Core Data | 系统框架 | 与既有 V1–V12 兼容；公开 API 缺少显式 close/replace，因此当前进程只 quarantine，purge 与 fresh open 延后到下次冷启动 | 继续采用 |
| GRDB.swift | MIT，持续维护 | SQLite 生命周期与事务控制成熟，但会重写既有 schema/generation/SwiftData 测试和迁移 | 不引入 |
| CareKitStore | BSD，Apple 开源 | append-only/versioned store 有参考价值，但 patient/task/outcome 模型不替代本项目 tombstone、receipt/digest 和 DB/FS journal | 不引入 |
| Apple FileManager 原子 rename + complete protection | 系统能力 | 同一卷同级目录移动提供清晰 point of no return；仍需 journal、路径和 symlink 防护 | 采用 |

## 8. 验证门禁

- manifest 覆盖每个 V1–V12 model、active/deleted/audit/attachment/projection/generation；
- 稳定排序、golden digest、空/普通/上限/损坏与读取失败不伪零；
- 每种删除目标的 preview/cancel/confirm/reopen、stale token 和关系变化；
- 第 N 个 attachment stage、DB rollback、rollback/finalize、通知失败与 post-audit；
- terminal overlay 后 Today/方案/时间线不展示目标原文，既有事实、revision 与 digest
  逐字节不变；
- reset 每个 journal phase 的 crash、磁盘满、路径错误、symlink、old Task 和重启续做；
- 只清除 owned notification，foreign 保留；
- reset 成功后旧 root/quarantine/外部 legacy bundle/generation/附件确实不存在，新
  onboarding 可用；
- 文案明确普通删除、全重置、系统备份和外部副本边界；
- 全尺寸、动态字体、VoiceOver、取消/返回/错误/重新进入；
- 全量普通测试、Release contract、generic build 与项目专属 Simulator。

真机文件保护、系统备份中历史资料的实际恢复、最近任务快照与最终 signed RC 仍属于
Batch 9 真机门禁。
