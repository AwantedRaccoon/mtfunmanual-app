# Batch 8A 药品候选清单与来源登记

- 状态：Candidate / 待产品负责人人工内容复核
- 冻结日期：2026-07-30
- 目录用途：忠实记录，不是推荐、处方、适应证判断或当地可获得性证明
- 当前候选规模：33 个精确成分、31 个 `notAsserted` 记录模板、44 个
  `candidateUnverified` presentation；已核验监管产品数为 0
- 技术合同：[ADR 0018](../architecture/0018-batch-8a-medication-catalog.md)

## 使用规则

本清单中的“常用”“扩展”“仅供记录”和“历史”只控制目录呈现，不代表疗效、安全性
排序或推荐等级。RxCUI 是外部别名，App 自有 stable ID 才是持久化身份。

盐、酯、水合物和母体成分保持精确区分，但不会据此计算等效剂量。GnRH 项目按精确
成分去重，成人抑制与青春期抑制不是两套重复药品。微粒化黄体酮作为 formulation
属性处理，不创建第二个 progesterone 分子。

## A. 常用记录范围

| App stable ID | 中文名 | 规范英文名 | RxCUI | 角色索引 | 首批记录模板 |
| --- | --- | --- | ---: | --- | --- |
| `estradiol` | 雌二醇 | Estradiol | 4083 | 雌激素 | 口服片、经皮贴、凝胶、喷雾、阴道制剂、半水合物按标签记录 |
| `estradiol-valerate` | 戊酸雌二醇 | Estradiol valerate | 24395 | 雌激素 | 口服片、注射剂 |
| `estradiol-cypionate` | 环戊丙酸雌二醇 | Estradiol cypionate | 1000146 | 雌激素 | 注射剂 |
| `spironolactone` | 螺内酯 | Spironolactone | 9997 | 抗雄相关 | 口服片、口服混悬液 |
| `cyproterone-acetate` | 醋酸环丙孕酮 | Cyproterone acetate | 22054 | 抗雄相关、孕激素 | 口服片 |
| `finasteride` | 非那雄胺 | Finasteride | 25025 | 5α 还原酶抑制剂 | 口服片 |
| `dutasteride` | 度他雄胺 | Dutasteride | 228790 | 5α 还原酶抑制剂 | 口服胶囊 |
| `progesterone` | 黄体酮／孕酮 | Progesterone | 8727 | 孕激素 | 微粒化口服胶囊、阴道制剂、注射剂 |
| `medroxyprogesterone-acetate` | 醋酸甲羟孕酮 | Medroxyprogesterone acetate | 1000112 | 孕激素 | 口服片、肌内/皮下注射 |
| `leuprolide-acetate` | 醋酸亮丙瑞林 | Leuprolide acetate | 203217 | GnRH 激动剂 | 肌内/皮下缓释注射；历史植入产品不并入该模板 |
| `triptorelin-pamoate` | 双羟萘酸曲普瑞林 | Triptorelin pamoate | 338529 | GnRH 激动剂 | 肌内缓释注射 |
| `triptorelin-acetate` | 醋酸曲普瑞林 | Triptorelin acetate | 236538 | GnRH 激动剂 | 注射剂 |
| `histrelin-acetate` | 醋酸组氨瑞林 | Histrelin acetate | 1294622 | GnRH 激动剂 | 皮下植入剂 |
| `goserelin-acetate` | 醋酸戈舍瑞林 | Goserelin acetate | 203146 | GnRH 激动剂 | 皮下植入剂 |
| `nafarelin-acetate` | 醋酸那法瑞林 | Nafarelin acetate | 203147 | GnRH 激动剂 | 鼻喷剂 |
| `buserelin-acetate` | 醋酸布舍瑞林 | Buserelin acetate | 42569 | GnRH 激动剂 | 鼻喷剂、注射剂 |

## B. 扩展记录范围

扩展项可以被搜索，但不在默认首屏突出。

| App stable ID | 中文名 | 规范英文名 | RxCUI | 目录边界 |
| --- | --- | --- | ---: | --- |
| `estradiol-acetate` | 醋酸雌二醇 | Estradiol acetate | 405416 | 精确酯型；不能与 estradiol 静默合并 |
| `estradiol-benzoate` | 苯甲酸雌二醇 | Estradiol 3-benzoate | 60661 | `Estradiol benzoate` 为显示简写；地区性产品；美国批准状态不成立 |
| `estriol` | 雌三醇 | Estriol | 4094 | 不与 estradiol 等价 |
| `conjugated-estrogens` | 结合雌激素 | estrogens, conjugated (USP) | 4099 | 混合成分；显示名可简写，但 exact substance name 保留 RxNorm 原文 |
| `dydrogesterone` | 地屈孕酮 | Dydrogesterone | 3706 | 地区性口服产品 |
| `norethindrone-acetate` | 醋酸炔诺酮 | Norethindrone acetate | 31983 | norethisterone 是命名 alias；常见于复方 |
| `drospirenone` | 屈螺酮 | Drospirenone | 11636 | 单方/复方语境必须分开 |
| `gonadorelin` | 戈那瑞林 | Gonadorelin | 6384 | 仅作精确历史/地区记录，不等同常规目录建议 |

## C. 仅供忠实记录

这些成分可能出现在既有记录、历史处方或其他适应证产品中。目录必须明确显示
“仅供记录”，不能把它们排成推荐替代项。

| App stable ID | 中文名 | 规范英文名 | RxCUI | 边界 |
| --- | --- | --- | ---: | --- |
| `ethinyl-estradiol` | 炔雌醇 | Ethinyl estradiol | 4124 | 主要见于复方；不与 estradiol 等价 |
| `esterified-estrogens` | 酯化雌激素 | estrogens, esterified (USP) | 214549 | 主要为历史或退出市场记录；exact substance name 保留 RxNorm 原文 |
| `estetrol` | 雌四醇 | Estetrol | 2539031 | 已核对产品主要为固定复方，不生成虚假单方 |
| `bicalutamide` | 比卡鲁胺 | Bicalutamide | 83008 | 其他适应证的正式药品；不暗示 HRT 适应证 |
| `flutamide` | 氟他胺 | Flutamide | 4508 | 其他适应证或历史记录 |
| `nilutamide` | 尼鲁米特 | Nilutamide | 31805 | 其他适应证或历史记录 |
| `degarelix-acetate` | 醋酸地加瑞克 | Degarelix acetate | 835863 | GnRH 拮抗剂；不归入常规青春期抑制索引 |
| `relugolix` | 瑞卢戈利 | Relugolix | 2472778 | GnRH 拮抗剂；记录不表示建议 |
| `elagolix` | 艾拉戈克 | Elagolix | 2049846 | 其他适应证；记录不表示建议 |

## D. 精确形式与历史导入

下列项目不作为 App 1.0 默认独立可选成分：

- `estradiol hemihydrate`（RxCUI 236859）：作为 estradiol presentation 的精确
  ingredient/formulation 属性；
- `polyestradiol phosphate`（RxCUI 34120）：历史记录或导入映射；
- estradiol undecylate、estradiol enanthate、estradiol dipropionate、
  estradiol phenylpropionate、estradiol hexahydrobenzoate：保留在后续逐地区
  注册库扫描队列，来源不足时不进入正式 seed；
- deslorelin acetate、abarelix、quinestrol、mestranol、diethylstilbestrol：
  兽药、退出市场或遗留语境，默认不进入可选目录；
- Bi-est、Tri-est、调配雌二醇植入丸及其他调配制剂：没有统一监管产品身份，只能按
  标签原文自定义记录；
- 只在复方中存在的 presentation：必须建成多成分 product，不得生成虚假单方。

## E. 复方模型验收范围

首批 schema 必须能表达多成分产品，但具体复方只有在逐产品官方登记和许可证完成后才
进入正式 seed。验收 fixture 至少覆盖：

- cyproterone acetate + ethinyl estradiol；
- cyproterone acetate + estradiol valerate；
- estradiol cypionate + medroxyprogesterone acetate；
- estradiol valerate + norethisterone enanthate。

fixture 只测试模型和搜索，不代表 Release 收录。

## presentation 路径核对边界

- histrelin 的“植入剂”是 dosage form，当前美国标签 route 记录为 `SUBCUTANEOUS`；
- goserelin 当前 ZOLADEX 官方标签的 dosage form 是 implant，route 为
  `SUBCUTANEOUS`；与 histrelin 一样，仍要分别保存剂型与途径；
- leuprolide 的皮下候选只表达 depot injection。历史 VIADUR implant 不与当前皮下
  注射模板合并；如未来重新收录，必须建立独立 product/presentation 与状态；
- 上述字段仍为候选抽取，只有逐条绑定监管产品记录并通过人工复核后才能把
  `evidenceStatus` 改为 `regulatoryVerified`。

`ethinyl-estradiol` 和 `estetrol` 只保留成分检索身份。候选 seed 没有足够的完整
复方产品事实，因此点击后进入按标签自定义记录，不生成单成分 product/presentation。

## 官方来源登记

### `rxnorm-cpc-2026.07.06`

- 机构：U.S. National Library of Medicine
- 标题：RxNorm Current Prescribable Content Monthly Release
- 版本：2026-07-06
- URL：https://www.nlm.nih.gov/research/umls/rxnorm/docs/rxnormfiles.html
- 查阅：2026-07-30
- 权利：SAB=RXNORM 规范名和 RxCUI 为美国政府作品／公共领域；CPC 下载不要求
  UMLS license
- 用途：美国当前可处方内容的规范名、RxCUI 和关系近似集
- 机器证据：辖区 `US`、机构 `NLM`、`terminologyIdentity` /
  `currentPrescribableTerminology`；不得作为产品批准来源
- 边界：不是逐产品 FDA 批准证明，也不是全球在售目录；产品内应显示内容冻结日期
- 致谢要求：使用公开数据时注明数据 courtesy of NLM，并明确 NLM 不背书本产品

### `rxnorm-api-2026.07.30`

- 机构：U.S. National Library of Medicine
- 标题：RxNorm API / SAB=RXNORM normalized names and codes
- URL：https://rxnav.nlm.nih.gov/RxNormAPIs.html
- 查阅：2026-07-30
- 权利：只使用 NLM 创建的 SAB=RXNORM 规范名与 RxCUI 公共领域数据
- 用途：核对精确成分身份、同义名和 active/retired 状态
- 机器证据：辖区 `US`、机构 `NLM`、`terminologyIdentity`
- 边界：不复制 UMLS 完整包、商业 source atoms 或受限词表；App 不运行时调用 API

### `openfda-drugsfda-2026.07.30`

- 机构：U.S. Food and Drug Administration
- 标题：Drugs@FDA data files / openFDA drug approval data
- URL：https://open.fda.gov/data/drugsfda/
- 查阅：2026-07-30
- 权利：openFDA 未另行标记的内容和数据以 CC0 1.0 提供；美国政府事实通常为公共领域
- 用途：核对美国是否存在某成分/剂型的正式申请与产品记录
- 机器证据：辖区 `US`、机构 `FDA`、`regulatoryProductRecord`
- 边界：不把 NDC、RxNorm active 或单一品牌存在解释为全类别批准或当前在售

本轮 route/form 分离复核还使用了以下 NLM DailyMed 当前标签页作为只读核对入口；
它们尚未被建成独立 Release product source record，因此不能把候选模板升级为正式产品：

- histrelin / SUPPRELIN LA：
  https://dailymed.nlm.nih.gov/dailymed/drugInfo.cfm?setid=d8fb000e-3cc9-4803-b71d-2cc597661977
- goserelin / ZOLADEX 10.8 mg：
  https://dailymed.nlm.nih.gov/dailymed/drugInfo.cfm?setid=e4cb3c20-2738-400a-b522-3f36f71fe6c5
- leuprolide acetate subcutaneous injection：
  https://dailymed.nlm.nih.gov/dailymed/fda/fdaDrugXsl.cfm?setid=290b0716-2fd5-43a1-8d3c-4857c1b2eefa

### 其他地区官方定位源

下列来源已经定位，但在完成逐产品 ID、状态与再分发复核前不进入首批 Release seed：

| 地区 | 官方来源 | 当前处理 |
| --- | --- | --- |
| 欧盟 | European Commission Union Register | 只作逐产品核对队列 |
| 英国 | NHS dm+d、MHRA Products | 只作逐产品核对队列 |
| 加拿大 | CCDD、Drug Product Database | 可按 Open Government Licence 逐项登记，尚未完成产品抽取 |
| 中国大陆 | NMPA 数据查询 | 未确认批量再分发范围，只保留官方链接 |
| 香港 | 卫生署注册药品资料 | 未完成逐产品许可与状态核对 |
| 台湾 | TFDA 药品许可证查询 | 未完成逐产品许可与状态核对 |
| 澳大利亚 | TGA ARTG | 未完成逐产品许可与状态核对 |
| 新西兰 | Medsafe Data Sheets | 未完成逐产品许可与状态核对 |

## 人工复核清单

产品负责人批准候选内容前，需要逐项确认：

- [ ] 首批 stable ID、中文名、英文规范名和 RxCUI 对应正确；
- [ ] 盐、酯、别名和母体关系没有暗示剂量等价；
- [ ] “常用／扩展／仅供记录／历史”只表示 UI 记录层级；
- [ ] 每个 Release presentation 有地区、监管状态、官方来源、查阅日期和许可；
- [ ] 复方没有被拆成虚假单方；
- [ ] UI 没有把收录写成推荐、当地获批或可获得；
- [ ] NLM 致谢和内容冻结日期在 App 中可见；
- [ ] 复核人、责任角色、日期和 catalog version 已写入 manifest。

在这些项目由真实人类完成前，候选内容包必须保持 `candidate`，Release 目录为空。
