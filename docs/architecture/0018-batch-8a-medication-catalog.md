# ADR 0018：Batch 8A 构建期药品目录合同

- 状态：Accepted
- 日期：2026-07-30
- 适用版本：App 1.0
- 关联：ADR 0001、0002、0005、0017

## 背景

Batch 8A 要把方案编辑器里的 DEBUG 占位目录替换为可版本化、可审计的构建期药品
目录。目录的用途是帮助用户忠实记录药盒、处方或既有方案，不是推荐药品、判断适应证、
比较疗效或生成剂量。

现有占位实现把成分、药理角色、给药途径和产品压在同一个 Swift 数组中，只覆盖五个
成分和八个示例产品。它不能表达：

- 一个成分同时具有多个目录角色；
- 盐、酯、水合物与母体活性成分的关系；
- 多成分产品；
- 植入剂、鼻喷、缓释注射等 presentation；
- 地区化监管状态、来源、查阅日期、许可证和人工复核；
- catalog version 在用户方案快照中的真实留存。

本 ADR 只冻结药品目录。方案分析、监测讨论和来源卡属于 Batch 8B；品牌库存、价格、
购买渠道、用量推荐、个体化解读和运行时目录更新均不属于 Batch 8A。

## 调查与复用决定

实施前的独立调查分别核对了产品范围、当前源码/持久化合同、官方登记来源和可复用开源
方案。决定如下：

- 使用 Foundation `Codable` 解码 App bundle 内的构建期 JSON；
- 使用项目自有 validator 和只读 repository；
- 不增加第三方运行时依赖，也不增加第二套数据库；
- RxNorm Current Prescribable Content 和 SAB=RXNORM 的规范名/RxCUI 只作为
  构建期事实源；App 不调用 RxNorm REST API；
- App 自有稳定 ID 是目录身份，RxCUI、批准号等只作为外部标识；
- 不打包完整 RxNorm/UMLS 文件，不复制受限 source atoms；
- 不采用 RxNormKit（LGPL、Realm、字段与维护证据不足）、CareKit（任务/结果系统且
  当前主线最低系统不匹配）、FHIRModels（交换模型过宽且没有目录事实）或
  Swift-SMART（运行时网络/OAuth 与维护边界不匹配）。

## 目录身份与分层

目录固定分成四种对象：

1. `MedicationIngredient`：精确活性成分身份；
2. `MedicationProduct`：某个监管或记录语境下的产品身份，可包含多个成分；
3. `MedicationPresentation`：剂型、授权途径、释放方式和包装/设备层；
4. `MedicationCatalogManifest`：schema、内容版本、来源集、digest 和人工复核状态。

### 成分身份

- estradiol、estradiol valerate 和 estradiol cypionate 是不同的精确成分；
- 盐、酯或水合物必须通过稳定 `parentActiveMoietyID` 关联母体，但不得据此推导剂量
  等价；母体不在首批可选目录时仍保存稳定 ID 与可读名称，不为了满足引用而伪造可选项；
- leuprolide/leuprorelin、norethindrone/norethisterone 等命名差异使用 alias，
  不复制成两个成分；
- micronized progesterone 是制剂属性，不是新的分子身份；
- 目录角色是数组。收录角色只用于索引，不表示适应证或推荐。

### 产品与 presentation

- 产品与成分是多对多；复方产品不能被强行归入单一成分；
- presentation 单独保存剂型、标签途径、释放方式和包装/设备；剂型与标签途径必须
  分开表达。例如植入剂是剂型，皮下是给药途径，不能把 `implantation` 或
  `implant` 当作植入剂的默认给药途径并与皮下混成一个枚举；
- 每个 presentation 必须声明 `candidateUnverified` 或 `regulatoryVerified`。
  候选模板只表示待核对的记录入口；Release 只接受逐条绑定同辖区、同监管机构
  `regulatoryProductRecord` 来源的 `regulatoryVerified` presentation；
- 地区监管状态不得折叠为一个全球 `approved` 布尔值；
- NDC、品牌名或 RxNorm active 状态均不得单独解释为 FDA 批准；
- 用户在方案里记录的途径、用量和单位仍保存原文，目录不得覆盖用户事实；
- 调配制剂没有统一监管产品身份时继续走自定义入口，不伪造 catalog ID。

## 首批药品范围

首批范围按“可记录性”分层，不按推荐强弱排序。精确清单和外部 ID 见
`docs/content/0001-medication-catalog-source-register.md`。

### 常用记录范围

- estradiol、estradiol valerate、estradiol cypionate；
- spironolactone、cyproterone acetate、finasteride、dutasteride；
- progesterone、medroxyprogesterone acetate；
- leuprolide/leuprorelin acetate、triptorelin pamoate/embonate、
  triptorelin acetate、histrelin acetate、goserelin acetate、
  nafarelin acetate、buserelin acetate。

### 扩展与仅供记录范围

扩展层覆盖准确记录可能遇到、但不应默认突出或不得暗示为常规方案的成分，包括其他
雌激素形式、部分孕激素、非甾体抗雄药和 GnRH 拮抗剂。历史、退出市场、仅复方、
仅调配或当前监管证据不足的项目必须带显式状态；没有足够来源或许可证的候选只留在
研究登记表，不进入 Release 内容包。

“进入目录”只表示能够准确记录。它不表示 App 认为该药适合跨性别医疗、适合某个年龄、
在用户所在地获批或可以自行使用。

## 来源与许可

每个正式内容对象必须能追溯到一个或多个 source record。source record 至少包含：

- source ID、机构、标题、版本或发布日期；
- 官方 URL、查阅日期；
- 机器可读辖区、发布/监管机构代码和证据类型（术语身份、当前可处方术语或监管产品记录）；
- 许可证/公共领域依据与允许的再分发范围；
- 来源适用地区与它能够证明的事实类型。

首批可打包来源限于权利边界明确、且只提取规范名、标识和监管事实的官方资料：

- NLM RxNorm Current Prescribable Content 2026-07-06；
- SAB=RXNORM 规范名与 RxCUI 公共领域数据；
- openFDA / Drugs@FDA 的 CC0 或美国政府公共领域事实；
- 经过逐项登记的其他政府开放数据。

只定位到网页、但尚未确认再分发范围或未完成逐产品提取的 NMPA、港澳台及其他地区
来源保留在研究登记表，不进入正式 seed。链接存在不等于获得复制或再分发授权。

## 人工复核与 Release 门禁

内容包有 `candidate`、`approved`、`rejected` 三种复核状态。

- agent 调查、自动化 validator 和代码 review 不能冒充医疗内容的人类复核；
- `candidate` 或 `rejected` 内容包只允许 DEBUG、Preview 和 Test；
- Release repository 只暴露 `approved` 且通过全部 validator 的内容包；
- 人工复核必须记录责任角色、复核人显示名、复核日期和复核范围；
- 内容发生任何语义变化后必须生成新 catalog version，并重新复核；
- 解码失败、digest 不符、未知枚举、来源缺失或门禁不合格必须显示明确不可用状态，
  不得静默伪装成“搜索无结果”。

当前候选清单的 31 个 product 都是 `notAsserted` 记录模板，44 个 presentation 都是
`candidateUnverified`；它们不是已经核对的监管产品。产品负责人完成人工内容复核也
不能单独把模板升级成监管事实，仍须逐产品补齐官方登记证据。Release bundle 只保留
独立状态清单并显示 `pendingHumanReview`；候选 JSON 在 Release 构建期被排除。
自定义药物入口始终保留。

## 运行时与持久化

- 目录是只读 bundle 内容，不写入 SwiftData；
- 查询在内存中完成，不读取用户资料，不联网；
- 只有用户明确选择条目时，方案项才保存 catalog product/presentation ID、
  catalog version，以及包含中英文名、全部成分、剂型、途径、地区、监管状态、
  批准号、持有人、来源版本/查阅日期、边界、释放方式、设备和精确 formulation
  的版本化 JSON product snapshot；
- product snapshot 同时保存 catalog 内容 digest，并为全部语义字段生成本地完整性
  digest；同版本目录存在时还要把 presentation、product、显示名、成分、剂型、
  途径、地区、监管事实、来源、边界、释放方式、设备与精确 formulation 全量复核，
  损坏或任一同版本语义不一致时不得进入 8B 精确成分分析；
- 历史方案永远读取自己的快照，不随新 catalog 版本改写；
- 目录更新只随 App 版本发布，不创建远程配置或内容刷新空壳。

## Validator 门禁

validator 至少拒绝：

- 非法或重复的 App stable ID；
- 原始 JSON 任意层出现 allowlist 之外的字段；必须在 `Codable` 解码前 fail closed；
- 重复外部标识；
- 不存在的 parent、product ingredient、presentation、route 或 source 引用；
- 空角色、空成分产品或无 presentation 产品；
- 缺少地区、监管状态、来源、查阅日期或许可证；
- 不受支持的 schema/catalog version；
- manifest digest 与规范化内容不一致；
- Release 中未批准、无复核人、无复核日期或引用不可再分发来源的内容。
- Release 中只有术语事实、未断言监管状态或只有调配语境的产品。
- 具体监管状态没有绑定同辖区、同监管机构的 `regulatoryProductRecord` 来源，
  或把 RxNorm 等术语来源当成批准事实。
- precise formulation 不属于对应产品成分，或其外部 ID 为空、重复或与目录冲突。
- Release presentation 没有 `regulatoryVerified` 状态，或只引用术语来源而没有与
  product 同辖区、同监管机构的监管产品记录。

## 验证要求

Batch 8A 至少需要：

1. JSON 解码、schema、唯一性、交叉引用、来源、许可证、digest 和 Release gate 测试；
2. 搜索中文、英文、alias、外部 ID、产品名和复方成分；
3. catalog version 与完整 product snapshot 持久化测试；
4. pending/invalid pack 的明确 UI 状态和自定义入口回退；
5. 320 × 568、390 × 844、430 × 932 与 768 × 1024 的真实渲染；
6. Release 构建确认待复核 seed 不可选择，Debug/Test 可审查候选内容。

## 非目标

- 不提供用量、换算、注射教学、自行调药或购买渠道；
- 不把目录收录解释为医疗建议、适应证或当地可获得性；
- 不承诺覆盖全球每个品牌、包装、复方或调配制剂；
- 不在 Batch 8A 建立收藏、知识文章、方案分析或远程更新。
