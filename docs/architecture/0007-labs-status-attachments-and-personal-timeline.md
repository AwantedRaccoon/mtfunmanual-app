# 0007：化验、状态、附件与个人时间线

- 日期：2026-07-23
- 状态：Accepted for Batch 5 local implementation；Files/真机/发行门禁仍未关闭
- 适用版本：App 1.0
- 前置决策：[0002：Batch 0 本地后端合同冻结](0002-batch-0-contract-freeze.md)、[0003：数据安全底座](0003-data-safety-foundation.md)、[0005：时间与方案版本核心](0005-time-and-regimen-core.md)

## 1. 范围和完成边界

Batch 5 建立 additive Schema V5「Personal Timeline」，完成以下本地闭环：

- 一次真实采样或报告的 `LabSampleRecord`，以及不会因同日、同名或相同 code 被覆盖的 `LabResultRecord`；
- 用户自建、最多五个 active 的 `StatusMetricDefinitionRecord`，以及一次一个项目、四级 ordinal 的 `StatusObservationRecord`；
- `LabSampleRecord`、`StatusObservationRecord`、legacy `JourneyEntry` 可拥有的私有 `AttachmentRecord`；
- 由现有事实源有界合并得到的首批个人时间线。

首批时间线包含：

1. legacy `JourneyEntry`；
2. `LabSampleRecord`；
3. `StatusObservationRecord`；
4. 每个 occurrence 的有效 `AdministrationEventRecord` leaf；
5. sealed `RegimenPlanVersionRecord` 的 date-only 生效路标。

附件继承父记录的时间与方案上下文，不成为独立时间线事件。完整 Countdown 状态机及归档路标不在本批，因此本批只能称「首批个人时间线」，不能称 1.0 时间线完整。

本批不实现 OCR、自动化验解读、医学正常/异常判色、因果分析、HealthKit、CloudKit、账号、同步、网络内容、报告导出或完整备份。化验与状态不提供原地覆盖；纠错、父记录删除和级联删除必须在另一个 additive 合同中冻结后再做。单个附件删除属于本批，且不得删除父记录。

## 2. Schema V5 与 legacy backfill

V1–V4 模型继续保留，V5 只增加：

- `LabItemDefinitionRecord`
- `LabSampleRecord`
- `LabResultRecord`
- `StatusMetricDefinitionRecord`
- `StatusObservationRecord`
- `AttachmentRecord`
- `PersonalTimelineBackfillState`

采样和状态时间继续使用 `HistoricalTimeRecord`。`sourceRecordType` 分别为 `LabSampleRecord` 与 `StatusObservationRecord`；方案关联由记录冻结的 local date 与 canonical regimen timeline 解析，零个或多个候选时保持 unresolved 并产生可见核对状态。

V4 → V5 必须在 inactive generation copy 上完成 lightweight migration、幂等 backfill、关系与文件校验、释放并重开校验，最后切换 `5.0.0` pointer。失败时 active pointer 仍指向 V4。

附件 journal 恢复与全树 audit 只在 bootstrap 的独占、可写 UI 尚未出现阶段执行；进入 `.ready` 后不得用陈旧 metadata snapshot 再做第二次恢复，否则可能与新导入竞态。活动附件不设未冻结的全局 4,096 魔法上限；审计必须覆盖全部活动 metadata。

legacy `LabRecord` 没有 sample/group identity。不能按同日、同 timestamp、名称或 code 猜测合并。每条 legacy `LabRecord` 保守生成：

- 一个 deterministic synthetic sample；
- 一个沿用 legacy result UUID 的 result；
- 一个 deterministic custom item definition；
- 一个绑定 legacy 原始事实、迁移后 sample/result/definition/time 的 deterministic sample operation receipt。

原始 name/code/value/unit/reference/context、canonical historical timestamp 和方案关联必须逐字节/逐字段保留。legacy `Double` 只作为兼容字段，不成为 V5 原始值真相。receipt、receipt revision 与 receipt ledger 必须和本批其他回填事实在同一事务内更新；validator 不得仅凭 synthetic ID 形状或单 result 形状豁免 sample receipt。没有经许可和人工复核的版本化 alias/catalog 之前，不自动把 legacy 项目合并为内置 analyte。

## 3. 化验合同

- `LabSampleRecord.id` 是一次采样或报告身份；同日允许多个 sample。
- sample 至少有一条完整 result 或一个 ready attachment；全空命令零写入失败。
- `LabResultRecord.id` 是每条结果身份，不设置 `sample + item` 唯一。
- `LabItemDefinitionRecord.id` 是 dataset 内稳定身份；名称、大小写、空格和 editable code 都不是身份。
- result 永久保存 item identity、name/code snapshot、原始数值、规范 Decimal 字符串、原始单位、原始参考范围、specimen/assay/variant snapshot。
- 新建自定义项目时 UI 必须允许录入报告原始代码；选择既有定义时显示并锁定名称/代码，详情页同时展示非空 code snapshot，不能让底层支持的代码事实成为用户不可录入、不可核对的隐藏字段。
- 单个 sample 最多 256 条 result；全部 `LabItemDefinitionRecord` 最多 2,048 条。V5 对每条 legacy 化验保守生成独立 definition，因而定义上限必须覆盖已冻结的 1,200 条五年迁移 fixture；写入与读取使用同一上限，超限持久化状态 fail closed。
- 「原始」字段保存调用方提供的完整字符串，包括首尾空白与全角符号；trim/全角小数点处理只用于非空验证和 Decimal 派生，不回写原文。legacy 空名称只允许 definition 使用明确迁移占位，result snapshot 仍保存 legacy 原文。
- operation digest 绑定命令中所有原始字符串以及 `nil`/空字符串差异；规范 Decimal 仅作为附加派生字段，不能让原始空白变化被误判为同一次 replay。
- Decimal parser 接受有限十进制文本，不使用二进制 `Double` 作为新事实真相。
- 趋势只连接相同 item identity、相同原始单位和相同 variant 的可比结果；不同单位不得静默连线。
- Foundation `Measurement` 只能用于已冻结的同维换算。质量浓度与摩尔浓度之间的换算需要版本化 analyte/molar-mass 规则、来源和测试；这些内容尚未冻结，本批不提供换算结果。
- UI 不显示「正常、异常、安全、危险」，不根据值生成调药、停药或诊断建议。

## 4. 状态合同

- active `StatusMetricDefinitionRecord` 最多五个；同名不同 ID 不自动合并。
- active 与 archived 合计最多 256 个状态指标定义；读取超过上限的持久化状态必须 fail closed，不能因归档而无限增长。
- 定义可归档，归档不删除或改写历史 observation；历史保存 metric name snapshot。
- 归档操作 ID 明确写入 definition，并与创建 receipt 分离；V5 receipt validator 必须对 sample、metric 创建/归档、observation、attachment 创建/删除做记录与 receipt 的双向精确集合核对。仅凭 `resultRecordType` allowlist 不足以激活 generation。
- 一次命令只保存一个 metric 的一条 observation，ordinal 必须为 `1...4`，可有一句备注。新 metric、observation 与本次全部 attachment metadata 使用同一 SwiftData 事务；文件准备失败或 DB 拒绝时不得留下部分 metric/observation，重放使用同一 operation digest。
- UI 固定表达为「第 N 级，共 4 级」「1 到 4 从低到高；这是个人记录刻度，不是医学等级。」，同一句必须进入选择控件的辅助功能提示；不使用好/坏、正常/异常或症状默认框架。
- legacy `JourneyEntry.kind == .feeling` 没有 ordinal，不迁移为 observation，继续作为自由文本事件显示。

## 5. 附件合同

允许 owner：

- `LabSampleRecord`
- `StatusObservationRecord`
- `JourneyEntry`

每个 attachment 使用随机 UUID 路径，不以文件名或内容哈希去重。metadata 保存 owner、原始显示名 snapshot、UTType、byte count、SHA-256、generation-relative path 和 createdAt。允许类型限于系统声明的 image 与 PDF。Batch 5 的保守工程上限冻结为：单文件 20 MiB、每个 owner 最多 6 个、每个 owner 合计最多 60 MiB；总量必须在 UI 保留新 payload 前及任何 staging 文件创建前各自检查，超限不得留下瞬时 final/staging。它是内存/磁盘安全门禁，不是发行容量承诺，后续改变需更新 ADR 和边界测试。

文件保存在当前 generation 的私有 `Attachments/<attachment-id>/payload.<type-extension>`；固定 `payload` leaf 不泄露原始显示名，UTType 扩展名只帮助系统预览识别，原始显示名只在 metadata 中保留。安全操作顺序：

1. 从 PhotosPicker 或 fileImporter 得到用户明确选择的内容；Photos 使用 `FileRepresentation`，以实际传输文件的 content type 为准，不使用 provider advertised type 列表的第一项猜测 bytes 类型。一次 selection batch 必须拥有独立代次身份；传输期间同时禁用 Picker、开发态 Files 入口与保存，只有当前代次可以清空 selection 和解除门禁。Picker 的系统 selection limit 永远不得以 `0` 表达「已满」（系统会把它解释为不限制），容量已满必须禁用入口并显示明确状态。超出剩余槽位的 selection、旧代次中已确认的失败，以及传输、iCloud 下载、文件面板、类型、大小或总量失败都必须计数并给出可见错误；不能用 `prefix`、`try?`、nil guard 或 stale completion 静默遗漏用户已经选择的附件，更不能继续保存父记录。关闭错误提示不能解除失败门禁；编辑器必须持续显示未解决失败数量，用户重新选择或检查附件后，只有明确确认不再使用未导入附件，才能清除门禁；
2. 先核对实际 regular file、非 symlink 与 file size，再以 `maximum + 1` 的有界读取确认没有 TOCTOU 增长；不得在 20 MiB 检查前把完整资源载入内存。随后写入受保护 staging；commit 在移动前必须再次按相同的属性 → stat size → 有界读取 → hash 顺序复核 staging，不能用 mmap/full read 处理 stage 后膨胀或替换的文件。最终私有文件拒绝 symbolic link、越界大小和不允许的 UTType；
3. 计算 SHA-256，原子移动到随机 final path，显式应用 `.complete`，并保持当前 `.systemManaged`（不设置排除系统备份）；
4. 短事务提交 owner、attachment metadata、revision 和 operation receipt；attachment-only 化验的 owner 与全部 attachment metadata 必须在同一事务中提交；
5. 数据库提交后的 import journal 清理与 delete trash 销毁都属于成功返回的强制步骤，不能使用 best-effort `try?`。返回成功前须按「保护属性与 regular/non-symlink → stat size → 至多 `maximum + 1` 有界读取 → hash」顺序复核；提交后 finalization 失败必须立即令当前 generation 进入 Recovery，UI 不得显示保存或删除成功。`.complete` 的真实映射只在真机门禁验证，Simulator 只验证代码路径。

文件系统与 SwiftData 不能伪装成原子事务。每个导入/删除使用 generation-local 操作 journal：

- import journal 必须先于 staging payload 建立；恢复不能依赖 journal phase 猜测 final 是否存在，DB 未提交时应同时清理匹配 final、staging 与无 journal 的私有 staging orphan；
- move 成功但 DB 未提交时，启动恢复隔离并删除 orphan；
- DB 已提交时，ready metadata 必须与 regular file 一一对应；import journal 的 attachment ID、operation ID、relative path 与 canonical UTType 必须和数据库活动 metadata 精确匹配，随后再核对 size/hash。缺失、身份错配、hash 不符、路径逃逸或 symbolic link 进入 Recovery；
- 删除先原子移动到可恢复 trash，DB 将 metadata 标为 deleted 并写 attachment tombstone/revision/operation receipt，提交后销毁 trash；失败或中断按 journal 和 DB 状态恢复。
- journal 文件名必须与 payload 内的 `operationID` 一致，路径中的 attachment UUID 必须与 `attachmentID` 一致，action/phase 组合也必须有效；重复 operation 或 attachment journal、身份错配和非 `payload.<type-extension>` 路径一律 fail closed。
- journal 同时冻结 canonical UTType identifier；恢复时 `typeIdentifier` 必须能精确重建同一个 `payload.<type-extension>`。同一 operation ID、同一 attachment final path 或被篡改的 staging bytes 不得覆盖既有操作或文件。
- metadata 只保存 `UTType(...).identifier` 返回的 canonical identifier；删除只有在 journal 到达 `deletionStaged`，且 journal `operationID` 与已提交 metadata 的 `deleteOperationID` 精确一致后才能 finalize，`deletionPrepared` 只能恢复或回滚。
- journal 恢复完成后必须反向枚举整个 `Attachments/` final tree，并与活动 metadata ID 集合一一相等；无 journal 的 final、缺少 final 的 metadata、额外 leaf、非 canonical UUID 目录、非 regular file、symlink 与无 journal 的 trash 都 fail closed，不能把未知健康资料静默删除或忽略。
- attachment-only 化验删除其最后一个 ready attachment 时拒绝并回滚文件移动；单附件删除不级联删除父 sample。

附件 root、Attachments、owner directory、staging、trash、operation directory、journal、staging/trash payload 与每个 ready file 都纳入文件保护、系统备份策略和 generation 校验。每次创建、移动或原子替换后都必须重新应用并精确 read back：`.systemManaged` 要求 `isExcludedFromBackup == false`；真机另要求 `.complete`，Simulator 只可延后 protection class，不可跳过 backup 属性。动态附件不能只依赖打开 store 时生成的静态 protection plan。

Batch 5 保留选择文件的原始 bytes、UTType 与 hash，不静默 OCR、转码、裁切、去 EXIF 或生成被称为「原件」的替代文件。首批预览直接使用受控的原文件 lease；每次交给 Quick Look 前都必须按 metadata 重新执行 opaque path、regular/non-symlink、保护/备份、size 和 hash 审计，失败即进入 Recovery；不持久化 thumbnail。删除只承诺从当前 active generation 移除该附件；inactive generation 和系统备份可能仍含历史副本，不能宣称取证级擦除。未来第一次包含附件的 schema generation 升级前，必须另行冻结 inactive generation retention/purge。

选择文案必须说明：App 建立私有副本；原件仍留在照片或文件提供方；App 不主动上传或实时同步；私有副本可能按 iOS 设置进入系统备份；App 不保证某次备份或恢复成功。当前没有 App Lock，不得宣称附件受应用锁单独保护。

含健康资料的 Files/PDF 导入仍受 ADR 0002 的 Files/iCloud Drive/App Review/法律门禁阻塞。代码和 Simulator 测试通过不等于该 Release 能力获准。

## 6. 统一时间线

时间线是 `AppReadActor` 的可重建、有界 read projection，不新增持久化 `TimelineRecord`，避免 correction、方案重关联或隐藏策略产生第二事实源。

- time facts 按 `instant → kind rank → stable ID` 稳定倒序，不以 local date 覆盖 instant 全序；
- date-only regimen facts 保留 `CivilDateFact`，进入 timed facts 之后的独立稳定 lane，并在 lane 内按 `civil date → kind rank → stable ID` 倒序；这样不伪造午夜 instant，也不制造 timed/date-only 之间不可传递的比较；
- 每个普通事实源使用 predicate、sort、`limit + 1` 和批量 payload 装载；
- cursor 后同一 instant/civil date 的 tie 查询使用有界 256 项缓冲；若边界仍未收敛则 fail closed，不退化为全表扫描；
- Administration 按时间倒序分块扫描 raw event time，按 occurrence 批量补齐完整 correction chain，再选出有效 leaf；游标 instant 的 raw event time 必须先精确计数，超过 256 立即 fail closed，不能因提前获得 `limit + 1` 个 leaf 而绕过。已读取的 event/chain 必须缓存，不能在每批后重新读取全部累计链。必须继续扫描到取得 `limit + 1` 个有效 occurrence leaf 或源耗尽，不能先对 raw correction 使用 page limit 再折叠。单页所有数据库读取合计最多 4,096 行，包括 raw time、按 ID 读取的 event、完整 correction chain event 和缺失 leaf time；探测溢出也不得实际读取第 4,097 行，预算耗尽且无法证明查询完整时保守 fail closed；
- 每页化验 payload 的聚合结果容量按本页实际 sample 数量乘以「每 sample 最多 256 条」动态、溢出检查地计算；不得用低于合法页容量的固定魔法数把可写事实误判为损坏；
- 聚合总量通过后仍须逐 sample 验证不超过 256；不能让一个 sample 的超限被同页另一个 sample 的空余容量抵消；
- timeline cursor 带完整 sort key，重复读取不丢失、不重复；
- SwiftUI 行身份使用 `kind + stable ID` 复合键；不同事实种类即使 UUID 相同也不能在 diffing 中相互吞并；
- 超出任何源的显式上限、关系损坏或 N+1 无界退化都 fail closed。

Journey 是正式入口：顶部一个「添加记录」主动作，分流「记录化验 / 记录状态 / 记下一件事」。Today 的最近化验应导航到对应 sample 详情，而不是只切到空泛 Journey tab。

## 7. 原生方案与开源调查

本批使用 Apple 原生 SwiftData、PhotosPicker、Core Transferable/FileRepresentation、`fileImporter`、UniformTypeIdentifiers、CryptoKit 和系统预览能力，不新增第三方运行时。

调查过但不采用：

- [GRDB.swift](https://github.com/groue/GRDB.swift)（MIT，持续维护）：只有 SwiftData 迁移、事务、查询或附件压力出现可复现实证失败时才触发替换 ADR；当前切换会制造第二持久化体系和高迁移成本。
- [apple/FHIRModels](https://github.com/apple/FHIRModels)（Apache-2.0，持续维护）：FHIR 模型面远超本地 sample/result/status 所需，不能替代本项目的 revision、历史时间、附件和隐私合同。
- [Stanford Spezi](https://github.com/StanfordSpezi/Spezi)（MIT，持续维护）：会引入不需要的应用架构，仍不能替代本地数据语义。
- [Kingfisher](https://github.com/onevcat/Kingfisher) 与 [SDWebImage](https://github.com/SDWebImage/SDWebImage)（MIT，持续维护）：核心价值是网络图片下载与缓存；1.0 无运行时网络且附件是原始私有文件。
- [WeScan](https://github.com/WeTransfer/WeScan)（MIT，已归档）：文档扫描/OCR 超出 1.0，且维护状态不适合作为新依赖。
- [swift-collections](https://github.com/apple/swift-collections)（Apache-2.0，持续维护）：少量有界源的 k-way merge 用标准库即可，不值得增加依赖。

Apple 官方依据：

- [Selecting Photos and Videos in iOS](https://developer.apple.com/documentation/photokit/selecting-photos-and-videos-in-ios)
- [Uniform Type Identifiers](https://developer.apple.com/documentation/uniformtypeidentifiers/)
- [Optimizing Your App’s Data for iCloud Backup](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup)

## 8. 最低验证门禁

- migration：V4 source 不变；中断重试同 generation；backfill 幂等；逐事实 count/digest/revision/关系/重开校验；legacy 同日/同名不合并；每个 synthetic sample 都有确定性 receipt，删除 sample receipt 或伪造无 legacy 来源的 synthetic 形状必须 fail closed，ledger count/digest/revision 必须同步；
- labs：同日多 sample；同 sample 重复 result；同名自定义 item 不合并；Decimal/raw/unit/range/variant 原样保留；空 sample 拒绝；跨时区关联不漂移；
- status：第六个 active definition 拒绝；ordinal 越界拒绝；归档不改历史 snapshot；legacy feeling 不迁移；
- attachments：取消与超限零正式写入；60 MiB 在 UI 保留和 staging 前双门禁；DB/FS/crash failpoint；提交后 finalization 失败转 Recovery；bootstrap-only 恢复；超过 4,096 个合法活动文件；path traversal、symlink、读前 size、bounded read、hash、journal type/phase、无 journal final/trash 反查、所有动态目录与文件的保护和 backup readback；Photos `FileRepresentation` 的实际类型与读前大小门禁；单附件删除不动父记录；Photos/Files 原件不受影响；
- timeline：混合事实、稳定同 instant 顺序、超过 256 同刻/同日 tie 时 fail closed、date-only 路标、effective leaf、长 correction chain 穿越 cursor 的分页无丢失/重复、administration 合并读取 4,096 行预算、合法多 sample 结果容量、关系损坏 fail closed；
- UI：320×568、390×844、430×932、768×1024、844×390 和 320×568 Accessibility 5；loading/error/empty/populated/review/saving；键盘、安全区、44 pt、VoiceOver、减少动态；
- build/test：generic Simulator build、全部单元/集成/渲染/UI 测试、Release 合同和专属 Simulator smoke；
- deferred：真机文件保护、系统备份/恢复、Files/App Review/法律、最低设备附件压力与完整 VoiceOver 人工矩阵仍属于发布门禁。
