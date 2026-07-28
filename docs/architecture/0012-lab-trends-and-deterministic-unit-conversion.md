# 0012：化验趋势与确定性单位换算

- 状态：Accepted
- 日期：2026-07-26
- 适用版本：App 1.0 / Personal Timeline
- 前置合同：[0007：化验、状态、附件与个人时间线](0007-labs-status-attachments-and-personal-timeline.md)

## 1. 决策与边界

趋势只连接同一个 `LabItemDefinitionRecord.id` 和完全相同的
`assayOrVariantOriginal`。名称、代码、大小写、`nil`、空字符串与仅空白字符串都不能
被猜测为同一身份。原始值、比较符、单位、参考区间与检测方法永久保留；换算只产生
read projection，不回写事实，也不换算报告参考区间。

趋势不输出正常/异常、安全/危险、目标范围、改善百分比、风险箭头、调药建议或因果
判断。`<`、`≤`、`>`、`≥` 表示删失边界，不是精确测量点：可以换算并在台账显示，
但不得作为普通精确点连接折线。

方案页停止创建 legacy `LabRecord`，与旅程页统一使用 canonical
`LabSampleRecord` / `LabResultRecord`。退休 API 在含 canonical models 的 schema
中也只能创建一条 canonical sample，不能再新增 `LabRecord`；它只在冻结的旧 schema
测试路径保留原行为。该兼容入口只 trim 用于完整性验证和 Decimal 派生，不得 trim
或改写 `rawValueOriginal`、`unitOriginal`。既有 legacy 事实继续保留。

方案页的六项化验摘要不得按用户可编辑的名称或 code 猜测 analyte 身份；只允许按
正式 bundled catalog 的稳定 ID 精确匹配。在正式 catalog seed 的来源、许可证、
稳定 ID 与人工复核责任冻结之前，这些映射保持未配置，custom definition 即使 code
写成 `E2`、`T` 等也不能自动落入摘要槽位。

V5 首次 backfill 完成后才产生、但尚未 canonicalize 的 legacy 记录，须由
`PersonalTimelineBackfill` 在同一 SwiftData transaction 中确定性补齐 definition、
sample、result、historical time、operation receipt 与 revisions。完整既有镜像必须
逐字段 digest 相等；部分镜像或内容冲突 fail closed。当前 V9 generation 在可写打开
阶段运行这一幂等 reconciliation；后续 schema upgrade 复用同一过程处理 inactive
target，并且必须在校验通过后才切换 pointer。同一次 reconciliation transaction
产生的 definition、sample、result、time、receipt 与 receipt-ledger projection
共享一个 `localRevision`。

## 2. 单位规则 v1

规则版本固定为 `lab-unit-conversion/1`。每个单位具有稳定 ID、展示符号、维度与到
维度基准的十进制因子；别名是封闭的精确表，允许 trim 首尾空白，但不做模糊匹配。
`µ`、`μ`、`u` 只有在表中逐项列出时才等价。

质量浓度以 `g/L` 为基准：

| 稳定 ID | 展示 | 到基准因子 |
| --- | --- | ---: |
| `mass.g-per-l` | `g/L` | `1` |
| `mass.mg-per-dl` | `mg/dL` | `0.01` |
| `mass.mg-per-l` | `mg/L` | `0.001` |
| `mass.microgram-per-l` | `µg/L` | `0.000001` |
| `mass.ng-per-ml` | `ng/mL` | `0.000001` |
| `mass.ng-per-dl` | `ng/dL` | `0.00000001` |
| `mass.pg-per-ml` | `pg/mL` | `0.000000001` |

物质的量浓度以 `mol/L` 为基准：

| 稳定 ID | 展示 | 到基准因子 |
| --- | --- | ---: |
| `amount.mol-per-l` | `mol/L` | `1` |
| `amount.mmol-per-l` | `mmol/L` | `0.001` |
| `amount.micromol-per-l` | `µmol/L` | `0.000001` |
| `amount.nmol-per-l` | `nmol/L` | `0.000000001` |
| `amount.pmol-per-l` | `pmol/L` | `0.000000000001` |

计算只使用 Foundation `Decimal` / `NSDecimalMultiply` /
`NSDecimalDivide`。因子从冻结十进制字符串解析；overflow、underflow、除零或
loss-of-precision 均显式失败。未知单位与跨维度换算显式拒绝。尤其禁止
`pg/mL ↔ pmol/L` 等质量浓度与摩尔浓度互换，直到项目身份、摩尔质量、来源与版本
另立合同。

## 3. 趋势读取与展示

单次读取按 `itemDefinitionID` 定向查询，再以 exact variant 过滤；result、
sample、historical time 三类事实合计最多扫描 4,096 条，而不是每张表各自 4,096
条；超过即 fail closed，不退化为无界查询。
页面最多返回 100 条，稳定倒序键为：

`historical instant → sampleID → result.sortOrder → resultID`

cursor 必须携带完整排序键，同一时刻的多个 sample 与重复测定不得丢失或重复。

从一条结果进入趋势。默认保留该结果的原始单位；只有用户主动选择 v1 规则中的同维
目标单位，才把兼容结果派生为同一显示序列。不兼容或未知单位不静默混入，并显示未
纳入数量。图表只是辅助，完整台账始终显示日期、原始值、派生显示值、单位、变体与
方案关联；辅助技术不依赖图形读取事实。

首次读取与分页都携带 request epoch；切换显示单位后，旧请求结果必须丢弃。分页失败
只在现有台账下方显示可重试错误，不得隐藏已经读取的事实。任一读取若报告
`corruptionSuspected`，必须清空投影并进入 Recovery，而不是把损坏资料伪装为空状态
或普通网络式重试。

## 4. 复用方案调查

调查日期为 2026-07-26：

- Foundation `Measurement` / `UnitConverterLinear` 使用 `Double`，可作为一般展示
  工具，但不能承担当前 Decimal canonical truth；
- HealthKit `HKUnit` / `HKQuantity` 同样以 `Double` 为核心，还会扩大健康数据权限
  与隐私范围，App 1.0 不引入；
- Apple FHIRModels（Apache-2.0）提供交换模型，不提供所需 Decimal 单位换算和本地
  事务，引入范围过大；
- Swift Numerics（Apache-2.0）不提供单位系统，也不替代现有 Foundation Decimal；
- UCUM 适合作为交换语义参考，但完整实现远超当前封闭规则，且自由文本报告单位不能
  被假设为合法 UCUM。

结论：使用系统 Foundation Decimal 与小型、版本化、可审计的本地规则表；不新增
第三方运行时、网络、HealthKit、遥测或数据外流边界。

## 5. 完成门禁

- 单位规则：全部因子、显式 alias、正反转换、比较符保持、科学计数法、未知单位、
  跨维度、overflow/underflow 与 locale 独立测试；
- 趋势：稳定 item identity、exact variant、同名不同 ID、同日/同 instant、多 sample、
  重复测定、cursor、比较符和不兼容单位测试；
- 写入统一：Release UI 不再调用 legacy lab writer；方案页新记录立即出现在 canonical
  详情、最近化验和趋势；
- 完整性：raw/parser comparator/canonical Decimal、非空单位与时间关系 fail closed；
- UI：empty/single/multi/mixed/loading/error、单位切换、重进和返回；
- render：320×568、390×844、430×932、768×1024、844×390 与
  320×568 Accessibility 5；
- accessibility：44 pt、动态字体、图表等价台账、减少动态、VoiceOver 完整事实；
- build/test：完整普通测试、UI、Release 合同、generic Simulator build 与项目专属
  Simulator smoke。
