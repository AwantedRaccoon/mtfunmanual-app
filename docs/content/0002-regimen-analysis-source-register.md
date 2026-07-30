# Batch 8B 方案分析候选来源与逐药覆盖登记

- 状态：Candidate / 待真实人类内容与医疗复核
- 冻结日期：2026-07-30
- 用途：把已封存方案整理为讨论材料，不是诊断、处方审核或调药建议
- 技术合同：[ADR 0019](../architecture/0019-batch-8b-deterministic-regimen-analysis.md)

## 来源

### `endocrine-society-gender-incongruence-2017`

- 机构：Endocrine Society
- 文件：Endocrine Treatment of Gender-Dysphoric/Gender-Incongruent Persons:
  An Endocrine Society Clinical Practice Guideline
- 版本：JCEM 2017；官方资源页更新 2024-10-25
- 官方入口：https://www.endocrine.org/clinical-practice-guidelines/gender-dysphoria-gender-incongruence
- 查阅：2026-07-30
- 适用边界：跨性别与性别多元人群的临床内分泌照护框架，含成人和青少年章节
- 当前权利处理：`linkOnly`；只打包书目信息和项目原创概括
- 不能证明：某个个人方案适用、安全、有效或符合目标；不能证明任何地区产品批准

### `wpath-soc8-2022`

- 机构：World Professional Association for Transgender Health
- 文件：Standards of Care for the Health of Transgender and Gender Diverse
  People, Version 8
- 版本：2022，DOI 10.1080/26895269.2022.2100644
- 官方入口：https://wpath.org/publications/soc8/
- 查阅：2026-07-30
- 适用边界：跨性别与性别多元人群的跨学科照护框架
- 当前权利处理：`linkOnly`；Open Access 不自动等于允许复制/改编
- 不能证明：某个目录成分是推荐项、某个用量适合个人或当地存在批准产品

### `cdc-vte-2025`

- 机构：U.S. Centers for Disease Control and Prevention
- 文件：About Venous Thromboembolism
- 版本：页面日期 2025-03-05
- 官方入口：https://www.cdc.gov/blood-clots/about/
- 查阅：2026-07-30
- 适用边界：面向公众的一般血栓与紧急就医信息；不是个体风险评估
- 当前权利处理：美国政府公开网页；候选包仍只链接并使用项目原创概括
- 不能证明：用户存在血栓、雌激素导致了某个事件或应该更换途径/药物

### `ema-cyproterone-2020`

- 机构：European Medicines Agency
- 文件：Cyproterone-containing medicinal products referral
- 版本：2020-03-27；页面更新 2020-05-20
- 官方入口：https://www.ema.europa.eu/en/medicines/human/referrals/cyproterone-containing-medicinal-products
- 查阅：2026-07-30
- 适用边界：欧盟醋酸环丙孕酮监管安全审查；只支持建立“脑膜瘤病史需要专业核对”的
  停止卡
- 当前权利处理：`linkOnly`；不复制 EMA 图标、表格或第三方内容
- 不能证明：其他地区标签、个人因果关系，或 App 可以命令停药/换药

### `nlm-dailymed-about-2026`

- 机构：U.S. National Library of Medicine
- 文件：About DailyMed
- 版本：查阅 2026-07-30
- 官方入口：https://dailymed.nlm.nih.gov/dailymed/about-dailymed.cfm
- 查阅：2026-07-30
- 适用边界：解释美国 submitted “in use” labeling 的用途与局限
- 当前权利处理：`linkOnly`；不打包标签全文
- 不能证明：DailyMed 每条内容都已获 FDA 批准、一定是最新 FDA-approved label，
  或可泛化到美国以外

### `nlm-medlineplus-emergency-services-2026`

- 机构：U.S. National Library of Medicine
- 文件：Emergency Medical Services
- 版本：页面更新 2026-05-24
- 官方入口：https://medlineplus.gov/emergencymedicalservices.html
- 查阅：2026-07-30
- 适用边界：面向一般公众，只支持“急性或可能危及生命时不要等待 App，应联系当地
  急救服务”的通用停止边界；美国 911 只属于美国地区语境
- 当前权利处理：MedlinePlus 健康主题页按 NLM 使用说明作为公共领域内容处理；App
  仍使用项目原创短句并保留来源入口
- 不能证明：用户发生了何种急症、药物是否相关，或应该停止/更换任何药物

## 逐药覆盖

下表覆盖 Batch 8A 的全部 33 个精确 ingredient ID。“类别框架”只表示公开资料中存在
可供专业讨论的上位框架，不表示该精确药品被推荐；“仅核对记录”表示当前候选规则包
没有建立该精确成分的医疗监测卡。

| ingredient ID | 候选处理 | 药品特异安全停止 |
| --- | --- | --- |
| `estradiol` | 雌激素类别框架 | 雌激素 + 血栓病史/风险未知或有 |
| `estradiol-valerate` | 雌激素类别框架 | 同上 |
| `estradiol-cypionate` | 雌激素类别框架 | 同上 |
| `estradiol-acetate` | 雌激素类别框架；地区/用途另核对 | 同上 |
| `estradiol-benzoate` | 雌激素类别框架；地区/用途另核对 | 同上 |
| `estriol` | 雌激素类别框架；不与 estradiol 等价 | 同上 |
| `conjugated-estrogens` | 雌激素类别框架；混合成分 | 同上 |
| `ethinyl-estradiol` | 仅供记录；不生成常规监测卡 | 同上 |
| `esterified-estrogens` | 历史记录；不生成常规监测卡 | 同上 |
| `estetrol` | 仅供记录；不生成常规监测卡 | 同上 |
| `spironolactone` | 抗雄激素上位框架；提供电解质/钾的中性讨论主题，不给阈值、频率或解读 | 无药品特异停止卡 |
| `cyproterone-acetate` | 当前只核对原始记录与正式标签 | 脑膜瘤病史未知或有 |
| `finasteride` | 当前只核对原始记录与正式标签 | 无药品特异卡 |
| `dutasteride` | 当前只核对原始记录与正式标签 | 无药品特异卡 |
| `bicalutamide` | 仅供记录；不生成常规监测卡 | 无药品特异卡 |
| `flutamide` | 仅供记录；不生成常规监测卡 | 无药品特异卡 |
| `nilutamide` | 仅供记录；不生成常规监测卡 | 无药品特异卡 |
| `progesterone` | 只提供上位框架与标签核对 | 无药品特异卡 |
| `medroxyprogesterone-acetate` | 只提供上位框架与标签核对 | 无药品特异卡 |
| `dydrogesterone` | 只提供上位框架与标签核对 | 无药品特异卡 |
| `norethindrone-acetate` | 只提供上位框架与标签核对 | 无药品特异卡 |
| `drospirenone` | 只提供上位框架与标签核对 | 无药品特异卡 |
| `leuprolide-acetate` | 青少年/青春期抑制专科框架；成人用途另核对 | 年龄未知/未成年停止 |
| `triptorelin-pamoate` | 同上 | 同上 |
| `triptorelin-acetate` | 同上 | 同上 |
| `histrelin-acetate` | 同上 | 同上 |
| `goserelin-acetate` | 同上 | 同上 |
| `nafarelin-acetate` | 同上 | 同上 |
| `buserelin-acetate` | 同上 | 同上 |
| `gonadorelin` | 仅核对历史/地区记录 | 无药品特异卡 |
| `degarelix-acetate` | GnRH 拮抗剂，仅供记录 | 无药品特异卡 |
| `relugolix` | GnRH 拮抗剂，仅供记录 | 无药品特异卡 |
| `elagolix` | 其他适应证语境，仅供记录 | 无药品特异卡 |

## 人工复核门禁

- [ ] 33 个 ingredient ID 与 8A 候选包完全一致；
- [ ] 每个 profile 的卡片没有把目录角色写成医疗证据；
- [ ] 每个方案组成项均显示“是什么、为什么出现、适用边界、可讨论事项和原始来源”；
- [ ] 停止文案明确指“停止 App 分析”，没有停药/换药命令；
- [ ] 监测卡没有化验阈值、目标范围、复诊日程或剂量解析；
- [ ] 来源卡的日期、适用人群、地区、许可与边界逐项复核；
- [ ] 外链均为固定 HTTPS，无 query/fragment/用户上下文；
- [ ] 内容复核人与医疗内容复核人的姓名、日期、资质/责任范围写入 manifest；
- [ ] App Review/法律分类和首发地区已经解决；
- [ ] 每项语义文字变化均升 content/rule version 并重新复核。

这些门禁关闭前，候选包不得进入 Release。
