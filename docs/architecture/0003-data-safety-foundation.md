# ADR 0003：数据安全底座

- 状态：Accepted；`.systemManaged` 产品策略已确认，真机文件保护、系统备份恢复和最低设备性能仍是完成门禁
- 日期：2026-07-21
- 适用版本：App 1.0，iOS / iPadOS 17.0+
- 上游合同：[ADR 0002](./0002-batch-0-contract-freeze.md)
- 性能证据协议：[ADR 0004](./0004-batch-1-performance-evidence-protocol.md)

## 1. 决定

Batch 1 继续采用系统 SwiftData，不升至 iOS 18，不引入第三方运行时依赖。实现必须先证明真实 V1 磁盘迁移、旧库保全、可重入 backfill、显式 store、短事务写入和有界读取；任一关键门禁无法由公开 API 和测试证明时，停止扩展业务模型，另立 `Core Data vs GRDB` ADR。

`foragent/` 中的方案仍是调查材料，不是工程事实源。本 ADR 解决其中与 ADR 0002 冲突或遗漏的部分。

## 2. Schema 与迁移图

```text
implicit legacy V1 store
  -> cold-start copy to inactive generation
  -> AppSchemaV1 (1.0.0)
  -> lightweight AppSchemaV2Bridge (2.0.0)
  -> idempotent post-open backfill
  -> validate and reopen
  -> atomic active-generation pointer
```

- `AppSchemaV1` 精确包含当前五个模型：`HRTProfile`、`CountdownRecord`、`RegimenVersion`、`JourneyEntry`、`LabRecord`。不得修改字段或实体名来伪造旧 fixture。
- `AppSchemaV2Bridge` 只 additive 增加底座实体：`DatasetMetadata`、`MigrationBackfillState`、`RecordRevision`、`MigrationIssue`。
- HrtPeriod、Schedule、Administration、Inventory、LabSample、附件等业务模型属于后续批次，不进入本 bridge。
- V1 legacy 模型在本批不删除；清理至少留到后续 App schema。

## 3. Dataset、revision 与 digest v1

- 每个 generation 恰有一条固定键的 `DatasetMetadata`。`datasetID` 只表示数据谱系。
- `nextLocalRevision` 由唯一 `AppWriteActor` 串行分配。一次成功语义事务涉及的记录共享 revision；revision 预约成功但业务事务失败时允许留下间隙，已提交 revision 永不复用。
- Bridge 通过独立 `RecordRevision` 关联 legacy 实体，不为冻结的 V1 类型增字段。
- V1 初始 revision 按固定类型顺序、`createdAt`、UUID 排序分配。
- digest v1 使用明确的二进制 canonical encoding 和 SHA-256；字段名排序、字符串 NFC、UUID 16 bytes、整数/IEEE-754 bit pattern 大端、时间为 Unix epoch 微秒。禁止把任意 `JSONEncoder` 输出当 canonical bytes。
- digest 排除 dataset、revision、导出时间和运行时元数据；它只用于完整性和冲突检测，不是签名或真实性证明。
- codec 必须有固定 bytes/hash golden vectors，并验证 locale、时区和进程无关性。
- 五类事实的 digest 字段编码只有一份共享实现，backfill、写入和 generation 校验必须消费同一实现。inactive generation 激活前与 active generation 可写打开前逐条重算并精确比较 digest；字段时间无法安全编码、digest 不匹配或 revision 分配器达到不可继续写入的上界时 fail closed，不得 trap 或把损坏库标成 ready。

## 4. Store 与 generation

```text
Library/Application Support/Unmanual/
├─ Generations/<generation-id>/Store/user.sqlite[-wal|-shm]
├─ GenerationPointer/active.json
└─ Recovery/migration-journal.json
```

- 生产配置总是传入明确 URL，并显式设置 `cloudKitDatabase: .none`。
- 第一次升级只允许在 App 尚未打开 legacy store 的冷启动阶段复制完整 SQLite bundle；源文件始终保留。
- 指针缺失但 legacy store 存在时必须执行收养；不得直接创建空库并称为成功。
- pointer 与 journal 同时缺失时，只要 `Generations/` 存在任一非隐藏 generation 证据，就进入 `invalidGenerationPointer`，不得猜测最新 generation 或创建新的 active 空库。legacy 主文件缺失但 `-wal` / `-shm` 任一仍存在时进入损坏恢复；不得把 sidecar 静默遗弃为新安装。
- 指针损坏、目标缺失、迁移/校验失败进入 Recovery Mode；不得自动使用内存库、删除旧库或创建新的 active 空库。
- journal 按 `preparing -> prepared -> validated -> activated` 推进，且与 pointer 一样原子写入。`preparing` 表示目标 bundle 可能只复制了一部分；下次启动必须保留该半成品供调查，改用全新的 generation 从源 bundle 重新复制，不得在半成品上续写。
- 新安装的 `.prepared` 只表示空 generation 目录已经就绪；若进程在 SwiftData 首次创建 store 前中止，重启必须允许同一新装 generation 继续创建和验证。legacy adoption 的 `.prepared` 若缺失 store 仍视为迁移失败，不能用空库代替源资料。
- pointer v2 同时冻结 generation 的 `datasetID` 与激活时最低事实/revision 计数。它只能指向通过 backfill、释放后重开，以及五类事实与 revision 按 `recordKey / recordType / recordID / datasetID` 逐项一一对应校验的 generation；只比较总数不构成完整性证据。active store 再次打开前先检查 SQLite header，并用只读 bridge container 核对 dataset 身份、最低计数与逐记录对应关系；不允许在身份确认前执行 backfill 或可写打开。`validated` journal 尚未写入 pointer 时可安全重试激活；active pointer 一旦存在，启动只按 pointer 打开，不在运行期切换 generation。
- SwiftData 没有公开的 close、snapshot、WAL checkpoint 或 replace-store API。本批只实现和验证 cold-start adoption；未来 live generation 替换在独立 spike 通过前不得宣称支持。

## 5. 文件保护与系统备份

- App target 声明 `com.apple.developer.default-data-protection = NSFileProtectionComplete`，让新建文件先取得默认 Class A 基线；同时对受管根目录、`Generations`、`GenerationPointer`、`Recovery`、active generation、Store 目录、store、WAL、SHM、pointer 和 journal 逐项设置并读取属性。可观测的设置错误、属性读回错误、明确的非 complete 属性、必需角色未报告或必需路径缺失必须进入 Recovery，不得只记录报告后继续 ready。
- 模拟器报告只证明代码路径；完成门禁需要物理真机的属性、锁屏读写和重开证据。
- Simulator 测试使用 Xcode 本地 ad-hoc 签名，让构建系统处理 `CODE_SIGN_ENTITLEMENTS` 并生成可核对的 simulated xcent；无签名 generic build 只证明可编译。实测 Simulator 冷安装仍可能不把该 entitlement 嵌入 App 签名，容器 metadata 也可能保持 class 0，所以任何 Simulator 结果都不是设备数据保护证据。Simulator 若对 `.fileProtectionKey` 返回 `EPERM`，生产路径继续 fail-closed；磁盘单元测试与性能 preflight 只能显式注入 `simulatorTestHarness`，跳过 Simulator 无法提供的物理保护写入，同时继续写入并回读系统备份属性。该夹具不能进入真机目标，也不能被描述为数据保护通过；最终门禁仍以签名 RC 真机为准。
- 产品负责人已确认 App 1.0 采用 `.systemManaged`。生产启动与 Release 性能路径共同消费 `SystemBackupPolicy.production`，对全部必需角色写入并精确读回 `isExcludedFromBackup == false`；这不启用 CloudKit、主动上传或实时同步。若任一现有必需路径仍读回为 excluded，启动或写后门禁失败关闭。
- `.systemManaged` 不构成备份成功或恢复成功承诺。用户界面必须说明记录在 App 私有存储中、App 不主动上传或实时同步、iOS 可能按系统设置纳入 iCloud 或电脑备份，且 App 无法保证每次备份或恢复成功。
- 复制、替换或新建文件后必须重新审计；目录继承不是完成证据。
- legacy 收养必须先把全部存在的 SQLite bundle parts 复制并保护到 inactive generation，才可修改被保留源 bundle 的保护或备份元数据；部分复制失败时，唯一源文件必须保持原样。validated pointer 已存在后，每次打开都按当前生产策略重审计保留源 bundle，避免策略切换留下分裂元数据。

## 6. 访问边界

- `AppWriteActor` 关闭 autosave，只暴露具体、可审计的 Repository 命令；Release 业务代码不保留可绕过 actor 的 raw `ModelContext` 写服务，也不向 UI 暴露 raw context 或通用写 closure。
- 写入在事务外完成解析，在短事务内重新校验、写业务对象与 `RecordRevision`，失败显式 rollback。
- 读取使用独立 context，返回不可变 `Sendable` DTO。主页面必须有 predicate、sort 和 fetchLimit；Journey 采用稳定 cursor，Archive 采用 count/极值而不是全表载入。
- cold-start 打开、迁移、backfill 与重开由独立 `AppDataBootstrapWorker` actor 执行；MainActor 只发布 `opening / ready / recovery` 状态，不能同步承担五年 fixture 的迁移工作。
- `@Model` 不进入长期后台任务。generation 切换需要写入屏障和 read lease drain；live switch 在本批 spike 通过前保持不可用。

## 7. Recovery Mode

启动状态至少区分：`opening`、`ready`、`protectedDataUnavailable`、`storageUnavailable`、`migrationFailed`、`corruptionSuspected`、`invalidGenerationPointer`。

Recovery UI 可安全重试，并明确说明不会自动删除原数据。外部恢复包、Files 导出/导入和“完整备份”属于后续门禁，不进入本批 Release 能力。

SwiftData/Core Data 可能把文件权限错误包在 `NSUnderlyingErrorKey` 或 detailed errors 中；分类器必须递归保留 `protectedDataUnavailable`，避免锁屏场景落入错误的恢复说明。

## 8. Batch 1 专属五年 fixture

不提前创建未来业务模型。性能 fixture 只使用五个 legacy 模型及 bridge 元数据：

- 1 个 HRTProfile；
- 24 个 RegimenVersion；
- 60 个 CountdownRecord（含已归档记录）；
- 7,300 个 JourneyEntry；
- 1,200 个 LabRecord；
- 对应 DatasetMetadata、RecordRevision 和少量 MigrationIssue。

固定设备/系统/commit 的 Release 构建至少采样 20 次，记录原始值并用 nearest-rank 计算 p95。它只判定 Batch 1 的迁移、首屏有界读取和长读/快写；未来 Administration/Inventory/Attachment 规模在对应批次另测。

四项操作的计时边界、样本隔离、失败语义与 Simulator 证据限制由 ADR 0004 冻结。当前数值阈值和跨设备冻结的五年二进制 fixture 尚未确定，因此已有 Simulator 结果只能验证 harness，不能判定性能通过。

## 9. 完成与阻塞门禁

代码完成证据：

1. 空、正常、异常 V1 真实磁盘 fixture 可迁移、释放后重开、重复 backfill；
2. 故障注入只留下完整旧或完整新 generation，旧库不被自动删除；
3. revision/rollback/digest golden vector 通过；
4. Release 路径主要页面无无界全表查询；
5. XcodeGen、单元测试、Debug 与 Release 无签名构建通过；
6. 无 CloudKit、网络、第三方运行时或 Release placeholder 回归。

仓库同时冻结一份改造前 commit 的未版本化 schema 形态所生成的 main/WAL/SHM bundle 与 SHA-256 清单。由于没有已发布 App 二进制或真实用户库可供采集，它被明确标为“source-reconstructed fixture”，不能冒充生产样本；测试只打开临时复制件并复核源 bundle 哈希未变。

仍会阻止“数据安全底座已完成”的外部门禁：

- 尚无物理真机 store/WAL/SHM 锁屏文件保护证据；
- 尚无最终签名 RC 在 iCloud/电脑备份及设备恢复中的实际纳入与恢复证据；
- 尚无 iPhone SE 2 / XR 等最低设备的 20 次 Release 性能证据。

这些门禁不阻止本地实现与自动化测试，但最终交付必须逐项标为未验证，不能用模拟器或文档代替。

## 10. 候选方案与开源调研记录

- 核查日期：2026-07-21。
- 核查范围：许可证、维护状态、事务/迁移与 store 控制、安全与隐私影响、与 iOS 17 本地优先需求的匹配程度。
- 事实来源仅使用官方文档或项目官方仓库；本记录在本轮底座完成审计与修复前完成。后续后端模块仍必须在实施前重新核查，不得把本次快照永久当作最新状态。

| 候选 | 许可证与维护证据 | 能力匹配 | 安全、隐私与采用决定 |
| --- | --- | --- | --- |
| **SwiftData** | Apple 系统框架；[ModelContainer](https://developer.apple.com/documentation/swiftdata/modelcontainer)、[ModelConfiguration](https://developer.apple.com/documentation/swiftdata/modelconfiguration) 与 [SchemaMigrationPlan](https://developer.apple.com/documentation/swiftdata/schemamigrationplan) 官方文档仍提供显式 schema、URL、只读/可写配置与迁移计划。随 Apple SDK 发行，不形成 App 内第三方运行时许可证。 | 与现有五模型和 SwiftUI/SwiftData 代码直接兼容，能保持 iOS 17、无第三方依赖和本地 `.none` CloudKit 配置。 | 默认不要求网络；但公开 API 缺少完整 close/snapshot/replace-store 生命周期控制，文件保护与真实 store 行为必须以 fail-closed 包装、磁盘 fixture 和真机证据补足。**本批采用。** |
| **Core Data** | Apple 系统框架；[NSPersistentStoreDescription](https://developer.apple.com/documentation/coredata/nspersistentstoredescription) 提供 URL、只读、自动迁移和 store options，[NSPersistentStoreFileProtectionKey](https://developer.apple.com/documentation/coredata/nspersistentstorefileprotectionkey) 提供 store 文件保护选项。随 Apple SDK 发行，不增加第三方运行时许可证。 | store lifecycle、迁移与保护控制比 SwiftData 表层更明确，适合作为第一方后备。 | 可保持纯本地；但当前切换会引入 SwiftData/Core Data 模型 hash、迁移重写或双栈一致性风险，现有磁盘迁移与测试已能满足本轮本地代码门禁。**不在本批切换；若 SwiftData 真实设备门禁失败，另立 ADR。** |
| **GRDB.swift** | 官方仓库 [groue/GRDB.swift](https://github.com/groue/GRDB.swift) 使用 [MIT License](https://github.com/groue/GRDB.swift/blob/master/LICENSE)；核查时 release feed 显示 7.x 持续发布，当前要求 Swift 6 系列并支持 iOS 13+。 | 事务、迁移、WAL、备份、观察和 SQLite 生命周期控制成熟，最匹配“需要直接控制 store”的第三方后备。 | 库本身可纯本地且不要求账号/遥测；但会增加第三方供应链、许可证归档和隐私清单审计面，并要求重写现有持久化层，违反本批无第三方运行时方向。**作为首选第三方后备，不引入本批。** |
| **SQLite.swift** | 官方仓库 [stephencelis/SQLite.swift](https://github.com/stephencelis/SQLite.swift) 使用 MIT；核查时最新 release 为 0.16.0，README 记录 migration、WAL/checkpoint 与 Swift Package Manager 支持。 | 提供较薄的类型安全 SQLite 层和直接 WAL 控制。 | 可纯本地；但本项目仍需自行补齐迁移编排、actor 并发、观察、revision/digest、备份和恢复不变量，供应链审计成本不低于 GRDB，却缺少同等高层能力。**不采用。** |

当前决定不是“自行重造数据库”：底层继续复用 Apple SwiftData/Core Data store 与系统加密/文件保护能力；项目自实现的部分只限于本产品冻结合同要求、而现有公开 API 未直接提供的 generation pointer、journal、record lineage、digest 与 fail-closed 恢复编排。
