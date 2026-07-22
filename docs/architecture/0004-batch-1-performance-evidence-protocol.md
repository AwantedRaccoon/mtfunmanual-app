# ADR 0004：Batch 1 性能证据协议

- 状态：Accepted for local harness；真机阈值与跨设备冻结 fixture 待发布候选阶段决定
- 日期：2026-07-21
- 适用版本：App 1.0，iOS / iPadOS 17.0+
- 上游合同：[ADR 0003](./0003-data-safety-foundation.md)

## 1. 目标与边界

本 ADR 冻结 Batch 1 性能证据的操作边界、样本数量、统计方法、隔离方式和报告格式。它不冻结尚无产品预算依据的毫秒阈值，也不把 Simulator 结果当成 iPhone SE 2 / XR 的性能证据。

现阶段只建立 `UnmanualPerformanceTests` target 和 `UnmanualPerformancePreflight` scheme。普通 `Unmanual` scheme 不包含该 target，不会在日常测试中意外生成五年夹具。

`UnmanualPerformancePreflight` 使用 Release configuration、`-O`、whole-module optimization、关闭 coverage、关闭 debugger、禁止并行测试。由于性能 target 通过 `@testable import` 调用真实底座边界，命令需要临时传入 `ENABLE_TESTABILITY=YES`；报告必须称其为 “Release-config hosted XCTest build”，不得声称与最终 shipping binary 位级相同。

## 2. 四项冻结操作

每个正式样本使用一个全新的 legacy bundle 副本和空的 foundation root；同一 target store 不跨样本复用。

1. `migrationOpen`
   - 计时从调用 `AppDataStoreBootstrapper.open()` 开始，到返回已经校验的 active store 为止。
   - 当前夹具覆盖未版本化 V1 legacy adoption 贯穿 Schema V3 的生产路径，包含 inactive generation 复制、SwiftData migration、两层 backfill、释放后重开、pointer/journal 激活和启动文件保护审计。
   - 不包含测试 fixture 生成、source snapshot 到该样本 legacy URL 的预置复制、报告写入和测试清理。
   - 它不单独测量“已有 V2 active generation → inactive V3 copy”的升级性能；该路径的原子 pointer 切换与 source 不变性由 `StoreBootstrapTests` 覆盖，真机性能仍是未验证门禁。
2. `todaySnapshot`
   - 计时独立迁移后的第一次 `AppReadActor.todaySnapshot()`。
   - 这是“今天”首页真实使用的有界读取；不得用 Journey 第一页替代。
3. `archiveSnapshot`
   - 计时 `AppReadActor.archiveSnapshot()`。
   - ADR 0003 已要求 Archive 使用 count/极值而不是全表载入，因此本批“长读”冻结为这条真实产品路径。Journey cursor 的完整遍历属于正确性测试，不混入本指标。
4. `quickJourneyWrite`
   - 计时 `AppDataWriter.addJourneyEntry()`，包含提交后的 store/WAL/SHM 文件保护复核。
   - 只测 `AppWriteActor` 会漏掉生产 UI 安全边界的固定成本，不构成本指标。

## 3. 夹具与每轮正确性

逻辑夹具版本为 `batch1-five-year-logical-v1`：

- 1 个 HRTProfile；
- 24 个 RegimenVersion；
- 60 个 CountdownRecord，其中 1 个 active；
- 7,300 个 JourneyEntry；
- 1,200 个 LabRecord；
- 正常夹具的 MigrationIssue 固定为 0；异常迁移由功能测试覆盖；
- source V1 固定为 8,585 个 legacy facts；迁移后另有 8,527 个 V3 companion facts，总计 17,112 个事实与 17,112 个 RecordRevision；
- 迁移后固定为 1 个 DatasetMetadata、1 个 complete MigrationBackfillState 和 1 个 complete CoreTimeRegimenBackfillState，`nextLocalRevision == 17,113`。

当前 Simulator preflight 在计时外用固定 UUID、日期、内容和关联生成未版本化 V1 store，并在连接仍存活且静止时复制 main/WAL/SHM 为本次运行的 immutable source snapshot。报告记录三件套 SHA-256；每个样本只复制它，不直接打开或修改 source；全部样本完成后复核哈希未变化。

这份 runtime source-reconstructed snapshot 只保证同一次运行内所有样本输入一致。它不是生产用户样本，也不是跨设备冻结的二进制 fixture。发布候选阶段若要比较不同物理设备，必须先冻结一份可复核来源和 SHA-256 的五年二进制 bundle；否则物理运行仍只能称 characterization。

每轮计时外必须验证：

- 五类 legacy facts、七类 V3 companion facts 与 revision 的精确计数；
- foundation metadata、complete state、legacy adoption pointer 和下一个 revision；
- `todaySnapshot` 的 `1 / 1 / 24 / 32 / 8` 有界结果；
- Archive 的 `1 / 24 / 60 / 7,300 / 1,200` 计数；
- 快写后 Journey 为 7,301、HistoricalTimeRecord 为 8,501、Revision 为 17,114；Journey 与 sidecar revision 共享 `localRevision == 17,113`，两者可读、dataset 未切换、digest 非空，`nextLocalRevision == 17,114`；
- 写后保护审计没有失败；
- 样本目录精确清理成功。

## 4. 样本与统计

- 先完成 1 次完整预热，不把它写入正式样本。
- 随后完成 20 个正式样本；四项操作各有 20 个原始整数纳秒值。
- 使用 `ContinuousClock`；不得使用 wall clock。
- nearest-rank p95：将 `n` 个值升序排列，取 `ceil(0.95 × n)` 的 1-based 位置；`n = 20` 时取第 19 小值，不插值。
- 任一轮操作、正确性或清理失败时，整次报告为 `invalid`，保留已经取得的原始样本，不计算有效 p95，不剔除慢值，也不静默补跑。

## 5. 报告

XCTest 无论成功或失败都应保存 `keepAlways` 附件：

- `batch1-performance.json`：合同/报告版本、四项定义、请求模式与运行平台、原始样本、rank/p95、fixture 计数与哈希、设备/系统/App 版本、配置/testability、commit/tree state、低电量模式、起止 thermal state、整轮临时根目录清理结果和失败原因；完整环境校验前失败时，仍保留 invocation 元信息并把尚未验证的 environment 留空；
- `batch1-performance.csv`：成功时为 20 行原始纳秒值和每轮清理状态；前置校验或中途失败时保留表头及截至失败前已取得的样本，不伪造或补跑缺失行。

报告不得记录 UDID、设备序列号或任何用户医疗资料。`.xcresult` 和导出的附件保留在已忽略的 `.build/`，不进入仓库和发布包。

在阈值未冻结时：

- `thresholdNanoseconds` 必须为空；
- `acceptance` 必须写明 `not-evaluated`；
- 测试通过只表示 harness、正确性门禁、样本数、统计和附件正常，不表示 SwiftData 性能合格。

## 6. Simulator preflight

先取得一个项目专属 Simulator UDID，再执行：

```bash
xcodebuild \
  -project Unmanual.xcodeproj \
  -scheme UnmanualPerformancePreflight \
  -configuration Release \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath .build/Batch1PerformancePreflight \
  -resultBundlePath .build/Batch1PerformancePreflight.xcresult \
  -only-testing:UnmanualPerformanceTests/Batch1ReleasePerformanceTests/testFiveYearReleasePerformance \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 3600 \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_TESTABILITY=YES \
  test
```

导出附件：

```bash
xcrun xcresulttool export attachments \
  --path .build/Batch1PerformancePreflight.xcresult \
  --output-path .build/Batch1PerformancePreflight-Attachments
```

Simulator preflight 只能证明 Release scheme、fixture 隔离、四条调用链、20 个原始样本、p95 算法、失败语义、附件与精确清理正常。它不能证明物理 CPU/存储/thermal 性能、锁屏文件保护、签名/provisioning 或最终 shipping binary。

## 7. 延期的物理门禁

用户已经决定：等完整 App 达到发布候选状态后再做真机测试，并在 App 发布 ready 时再购买 Apple Developer Program。因此当前不得为性能 harness 提前购买计划或声称完成真机门禁。

进入真机阶段前还必须冻结：

1. 跨设备共用的五年二进制 fixture 与 SHA-256；
2. 四项各自的最大 p95 纳秒/毫秒预算；
3. 精确设备（SE 2、XR 或两者）、OS build、剩余空间、低电量模式、thermal/cooldown 和超时规则；
4. 干净的完整 40 位 commit SHA；
5. 独立物理 scheme/命令和 Developer Team，不复用 `simulator-preflight` 环境。

只有这些合同冻结、真机完成 20 个有效样本且阈值全部通过后，才可关闭 ADR 0003 的最低设备性能门禁。
