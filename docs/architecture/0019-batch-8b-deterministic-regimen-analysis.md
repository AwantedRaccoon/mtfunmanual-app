# ADR 0019：Batch 8B 确定性方案分析合同

- 状态：Accepted
- 日期：2026-07-30
- 适用版本：App 1.0
- 关联：ADR 0001、0002、0005、0007、0012、0018

## 背景

Batch 8B 要把已经封存的方案整理成可读、可核对的教育性讨论材料。它不是方案匹配、
自动诊断、处方审核或化验解释器。Batch 8A 已经提供版本化药品快照；8B 只能消费快照
中的精确成分身份，不能按用户输入的药名、别名、备注或可编辑化验名称猜测医疗含义。

产品合同要求固定输出方案摘要、记录情况、公开框架、待确认事项、监测与复诊准备、
来源边界和规则版本，并要求未成年人、妊娠可能、血栓风险、急性危险和关键信息未知
进入明确停止分支。

## 调查与复用决定

实施前的两路独立调查分别核对了产品/医疗合同和现有代码/开源方案，结论一致：

- 复用 `CoreRegimenVersionSnapshot` 和
  `MedicationCatalogSelectionSnapshotV1`，不新增 SwiftData model；
- 结果是瞬态值对象，不触发 Schema V13、迁移、备份、恢复或删除语义；
- 使用 Foundation `Codable`、Bundle JSON、CryptoKit digest 和项目自有闭集 validator；
- 借鉴 FHIR PlanDefinition 和 CQL 的版本/来源思想，但不引入 FHIRModels、CareKit、
  CQL runtime、CDS Hooks 或 OpenCDS；这些方案要么过宽、建立第二套存储，要么依赖
  网络/服务器，与 App 1.0 不匹配；
- 不增加第三方运行时依赖，不创建脚本规则语言，不允许运行时内容更新。

## 输入与身份

`RegimenAnalysisRequestV1` 只接受一个已封存方案的值快照：

- 方案版本 ID、编号、标题和生效日期；
- 每项的稳定 ID、显示顺序、用户原始名称、剂型、途径、用量、单位和计划摘要；
- 8A product snapshot 中的精确 ingredient ID、presentation ID、catalog version；
- 快照完整性状态：已核对 catalog、自定义原文或 catalog 快照不可读。

规则匹配只使用精确 ingredient ID。8A 的 role 只是目录索引，不是医疗证据；显示名、
英文名、别名、`doseOriginal`、`unitOriginal`、可编辑化验名称和 code 均不得成为
规则键。复方按完整精确成分集合读取；相同讨论卡按稳定 ID 去重。

历史方案使用自己保存的 8A 快照，不依赖当前 catalog 重解释。页面必须说明它使用的是
当前规则包重新整理，而不是永久保存的历史分析结论。

8B 内容 manifest 必须固定 `requiredCatalogVersion` 与
`requiredCatalogContentDigest`。候选包只能绑定完整覆盖同一 33 个 ingredient ID 的
8A 候选包；Release repository 还必须拿到已经通过 8A Release validator 的目录状态，
版本、内容 digest 和成分全集全部相同，否则显示内容不可用。

## 临时安全边界

分析页以当前页面内存收集以下边界；关闭页面即丢弃，不持久化、不写日志、不用于通知：

- 年龄范围：成人、未满 18 岁、不确定；
- 妊娠可能：有、无、不适用、不确定；
- 是否正因急性情况寻求判断：有、无、不确定；
- 当精确成分命中雌激素规则时：已知血栓病史/风险有、无、不确定；
- 当精确成分命中醋酸环丙孕酮时：已知脑膜瘤病史有、无、不确定。

App 不从身份、称呼、身体结构、药名或其他记录推断答案。规则优先级固定为：

每一项初始值都是真正的“未回答”，与用户主动选择“不确定”不同。未回答使用瞬态
optional `nil` 表示，不进入任何 `unknown` 停止规则，也不能在界面中显示为已选择。
用户主动选择“不确定”后，才进入相应的停止分支。若已经明确命中更高优先级停止条件，
立即停止；否则只要当前方案实际显示的安全问题仍有未回答项，就保持 `unanswered`，
不输出药品特异讨论卡。

1. catalog 快照损坏；
2. 急性情况；
3. 未成年人或年龄未知；
4. 妊娠可能或未知；
5. 雌激素相关且血栓病史/风险有或未知；
6. 醋酸环丙孕酮且脑膜瘤病史有或未知；
7. 自定义/未知成分导致的有限分析；
8. 普通教育性讨论卡。

“停止”始终表示停止 App 的药品特异分析，不表示停止、减少或更换任何药物。急性分支
只能提示寻求及时医疗帮助，不诊断疾病。停止后仍显示用户原始方案摘要、停止原因、
来源和边界，但不继续输出药品特异监测卡。

## 输出

`RegimenAnalysisSnapshot` 固定包含：

1. 方案摘要：逐项原样显示名称、剂型、途径、用量/单位和计划；
2. 记录情况：中性说明哪些记录字段未填写，不称为医学上“不完整”；
3. 语义状态：`unanswered`、`ready`、`limited` 或 `stopped`；
4. 公开框架卡；
5. 需要确认的事项；
6. 监测与复诊讨论卡；
7. 实际引用的来源卡和适用边界；
8. 每个方案组成项下的“是什么、为什么出现、适用边界、可讨论事项和原始来源”；
9. rule set version、content pack version 和语义输入 digest。

同一规范化输入、安全边界、规则版本和来源包版本必须得到同一语义输出。页面生成时间
不进入结果 equality 或 digest。

## 化验硬边界

8B 不读取、解析、换算或比较任何化验数值。当前正式 bundled analyte stable ID 尚未
冻结，不能把用户可编辑的 “E2”“T”“K” 或 code 自动识别成某项监测。

监测卡只能写“公开资料涉及哪些可与医生或药师讨论的主题”。它不能显示：

- 已做/未做某项化验；
- 正常/异常、安全/危险；
- 目标范围、阈值、趋势风险或改善百分比；
- 治疗是否充分、药物是否有效；
- 剂量、停药、减量、换药、注射或自行调整建议。

每张卡还必须声明证据性质：`externalAuthority` 必须至少引用一个来源；
`productRule` 只能表达 App 自身门禁或完整性规则且不得挂接外部来源。profile 只能引用
framework、confirmation 或 monitoring 卡；全局边界和有限分析入口也必须引用正确
kind，防止卡片被错误挂载后越过停止边界。

## 构建期内容与来源

规则、药品 profile、卡片和来源元数据放入版本化 Bundle JSON。每个来源保存机构、
标题、版本/发布日期、查阅日期、适用人群、地区、固定 HTTPS 原文 URL、许可和边界。

Endocrine Society、WPATH 等未完成逐篇再分发许可核对的资料按 `linkOnly` 处理：
只打包书目信息、固定链接和项目原创概括，不复制表格、长段正文或图片。外链 URL 不得
包含 query、fragment、药名、方案内容、搜索词、用户/设备 ID；打开前显示域名和离开
App 提示。

候选来源和逐药覆盖登记在
`docs/content/0002-regimen-analysis-source-register.md`。

## 人工复核与 Release 门禁

内容包有 `candidate`、`approved`、`rejected` 三种状态。Release 必须同时满足：

- 内容包与规则包均为 `approved`；
- 记录真实内容复核人、医疗内容复核人、日期和范围；
- digest、source/card/profile/rule 交叉引用和固定 URL 全部通过；
- 医疗分析 App Review/法律分类已明确为 `resolved`；
- 8A 对应药品目录及精确产品事实满足其独立 Release 门禁。
- 8B 的 required catalog version、content digest 和 ingredient 全集与该 Release
  目录完全一致；候选目录状态不能冒充 Release 依赖。

任何 agent 调查、自动化测试或代码 review 都不能冒充真实人类医疗内容复核。当前包保持
`candidate`，只进入 DEBUG/Preview/Test；Release 明确排除 candidate JSON，并始终
打包独立 release-state manifest，显示 `pendingHumanReviewAndClassification`。

## Validator 门禁

validator 至少拒绝：

- 不支持的 schema/version、重复或非法稳定 ID；
- 先按逐层 JSON key allowlist 检查原始输入；任何未知字段都必须在 `Codable` 解码前
  fail closed，不能让 `script`、`expression`、剂量/化验阈值或未来未审字段被静默忽略；
- digest 不符、未知 source/card/profile/rule 引用；
- 非固定 HTTPS、带 query 或 fragment 的外链；
- 空适用人群、地区、许可、来源边界或卡片边界；
- 自由脚本/表达式、药名模糊匹配、剂量/化验阈值字段；
- 停止规则的 condition、稳定 ID、stop card ID、精确 priority 或排列与冻结映射不一致；
- profile 没有精确 ingredient ID，或候选包未覆盖 8A 的全部候选成分；
- 卡片中出现“最佳方案”“推荐剂量”“目标范围”或停药/换药命令；
- 外部资料卡没有来源、产品规则卡伪挂外部来源，或 profile/manifest 引用错误 card kind；
- Release 中未批准、缺少真实双重复核人/日期，或分类门禁未解决的内容。

## UI

- 当前方案卡提供“查看方案分析”；
- 历史版本从静态计数改为可访问台账，每个版本可用当前规则包重新核对；
- 分析页先显示原始方案与可访问的当前语义状态定位条，再显示不持久化说明和安全边界；
- 未回答、停止、有限、内容不可用和可显示状态必须明确区分；
- 用户执行“关闭”时必须先清空全部瞬态答案再 dismiss；页面消失时再次清空作为系统
  退出路径兜底，SwiftUI presentation 被复用也不能保留上一次答案；
- 来源按钮先打开 App 内边界页，显示目标域名和不会携带个人资料，再由用户确认进入
  系统浏览器；
- 每个重复选择保持四个固定列位：否/低风险事实、是/高风险事实、不适用、不确定；
  某题没有对应答案时保留空槽，不得让“不确定”换列。Accessibility 字号改为单列，
  并继续支持 44 pt、VoiceOver 和减少动态效果。

## 验证要求

Batch 8B 至少覆盖：

1. 同输入/规则/来源在 locale、时区和输入排列变化下的确定性；
2. digest、版本、唯一性、交叉引用、URL、许可、人工复核和 Release gate；
3. 损坏快照、急性情况、年龄、妊娠、雌激素+血栓、CPA+脑膜瘤停止优先级；
4. 33 个 8A ingredient ID 全覆盖、复方去重、历史快照、自定义和未知成分；
5. 修改用量/单位不改变讨论主题，化验名称/数值不能进入输入或改变结果；
6. forbidden 医疗输出负向扫描；
7. 当前/历史入口、返回、重进、来源边界和内容不可用 UI；
8. 320 × 568、390 × 844、430 × 932、768 × 1024、横屏和 Accessibility 5；
9. Release bundle 不含 candidate JSON，状态清单明确 pending。

## 非目标

- 离线知识库全局搜索、收藏和文章阅读器；
- 方案匹配、推荐、评分或“符合指南”结论；
- 个体化化验解释、风险计算、用量换算或复诊日程；
- 运行时联网搜索、AI 医疗问答、WebView 或远程更新；
- 永久保存安全问答或分析结果。
