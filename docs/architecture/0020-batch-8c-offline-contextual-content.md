# ADR 0020：Batch 8C 场景化离线内容与随身附页合同

- 状态：Accepted
- 日期：2026-07-31
- 适用版本：App 1.0 / Schema V13
- 关联：ADR 0002、0003、0005、0007、0012、0015、0017、0018、0019

## 背景

产品规划 6.12 要求把 MTF不全书内容放进用户正在完成的任务，而不是增加“网站”
Tab 或复制网站首页。首批入口包括方案字段、化验记录、方案分析来源、复诊准备、
记录详情和档案页“随身附页”；档案入口还必须支持搜索、收藏和离线查看。

“网站负责完整文章，App 只缓存必要摘要、来源信息和用户收藏”是本批次的首要边界。
因此这里的“离线查看”是可独立阅读、能说明适用边界和下一步的必要摘要，不是网站
全文镜像、HTML 缓存、WebView 或在线阅读器。方案分析已经由 Batch 8B 提供来源展开；
8C 复用它的固定外链边界，不复制第二套医疗来源卡。

当前档案页只有“查找 MTF不全书”的结构预览；全局搜索、收藏和离线阅读尚未实现。
收藏会透露用户关注的医疗、身份或现实路径主题，必须按敏感本地事实处理，不能放进
`UserDefaults`、日志、分析事件或不受数据清单约束的旁路文件。

## 调查与复用决定

实施前的独立产品/界面调查和数据/架构调查结论一致：

- 使用 Foundation `Codable` 解码 App Bundle 中的版本化 JSON，CryptoKit SHA-256
  校验规范化内容，项目自有闭集 validator 和确定性内存索引；
- 使用 SwiftUI `searchable`、现有 `NavigationStack`、设计令牌和 App 内外链确认；
- 只保存一类 SwiftData 收藏事实，不把正文、搜索历史或场景上下文写入数据库；
- V12 → V13 使用 lightweight migration，旧数据自然得到零收藏，不新增 backfill
  model；
- 不增加第三方运行时依赖，不引入全文检索数据库、Markdown/HTML runtime、FHIR、
  CareKit、远程内容 SDK 或第二套持久化系统；
- 小型、有上限的中文摘要包不需要 SQLite FTS、Typesense、Meilisearch、Lunr 或其他
  搜索依赖。它们会增加 schema、索引生命周期、许可证或网络/维护边界，而当前需求可由
  Foundation 的大小写、变音符号和宽度不敏感规范化搜索完成；
- 不读取同级 `mtfbook.com` 的未提交工作区作为构建事实源。

Apple 的 SwiftData `VersionedSchema` / `SchemaMigrationPlan`、SwiftUI `searchable`
和 Foundation 字符串比较足够表达本批次。搜索排序必须由项目冻结的字段权重和稳定 ID
决定，不能依赖当前 locale 下可能变化的自然排序作为语义结果。

## 内容事实源与许可证

首批候选摘要绑定：

- 仓库：`AwantedRaccoon/MTF-Unmanual`
- 来源 URL：`https://github.com/AwantedRaccoon/MTF-Unmanual`
- 来源提交：`f39474389831840366c23fd274208319802bf2a5`
- 来源路径：`archive/`、`cards/` 及其公开目录元数据
- 原创非代码内容许可证：CC BY-SA 4.0
- 指定署名：`MtF Manual contributors`

来源仓库明确说明：外部机构、指南、论文及链接目标保留各自权利，来源仓库不能替它们
再许可。因此 App 只打包项目原创摘要、项目原创适用边界和外部来源的书目信息/固定链接；
不复制外部文章、表格、图片、长段引文或受限数据。候选/正式内容包及 App 内新增的
改编摘要按 CC BY-SA 4.0 分发，必须在 `LICENSE-SCOPE.md` 中从 MPL 源码范围明确分离。

候选内容必须在 App 仓库内保存精确来源提交、文件相对路径、来源内容 digest、是否改编、
CC BY-SA 4.0 署名与共享方式。语义改写后同时记录 App 内容版本和修改说明。任何来源文件
不在冻结提交、许可证缺失、署名缺失或权利范围不清，都必须 fail closed。

## 内容包

Bundle JSON 固定包含：

1. `manifest`：schema version、content version、locale、生成/查阅/到期日期、来源提交、
   内容 digest、计数、复核与发行状态；
2. `sources`：稳定 ID、机构/权利人、标题、版本或发布日期、查阅日期、到期日期、
   `sourceStatus`、固定 HTTPS URL、许可证标识、可空许可证 URL、distribution mode、
   适用地区/人群和来源边界；这里描述卡片依据的外部书目，不代表外部权利人授权 App
   打包其正文；
3. `cards`：稳定 ID、标题、必要摘要、适用边界、内容类型、分类、别名、来源引用、
   `displayOrder`、内容版本、逐卡 `cardDigest`、查阅/到期日期和固定网站原文 URL；
4. `scenarioAnchors`：闭集场景、稳定 anchor ID、展示目的、排序和 card ID；
5. `attribution`：来源仓库、精确提交、CC BY-SA 4.0、署名和改编说明。

各 object 的 exact keys 冻结为：

- `manifest`：`schemaVersion / contentVersion / locale / generatedAt / retrievedAt /
  expiresAt / sourceCommit / contentDigest / sourceCount / cardCount /
  scenarioAnchorCount / review / classificationStatus`；
- `review`：`status / ownerRole / contentReviewerDisplayName /
  medicalReviewerDisplayName / completedAt / scope`；三个可空字段仍必须显式出现并编码为
  JSON `null`；
- `source`：`id / rightsHolder / title / versionOrPublishedAt / retrievedAt /
  expiresAt / sourceStatus / url / licenseIdentifier / licenseURL /
  distributionMode / applicableRegions / applicablePopulations / boundary`；
- `card`：`id / title / summary / applicabilityBoundary / contentType / category /
  aliases / sourceIDs / displayOrder / contentVersion / cardDigest / retrievedAt /
  expiresAt / originalURL / provenance`；
- `scenarioAnchor`：`id / scenario / purpose / displayOrder / cardID`；
- `attribution`：`sourceRepository / sourceCommit / creator / licenseIdentifier /
  licenseURL / adaptationStatus / modificationNote / shareAlikeStatement`。

`review.status` 和 attribution 的 `adaptationStatus` 分别使用本 ADR 的既有闭集。
`classificationStatus` 只允许 `pending / resolved`；内容类型只允许
`questionAnswer / recordingGuide / visitChecklist`；分类只允许
`identityAndTerms / hrtAndCare / recordsAndVisits / voiceAndPresentation / surgery /
sexualHealth / mentalWellbeing / privacyAndRelationships / legalAndDocuments /
preventiveCare`。新增值必须先修订合同和测试，不能由内容包自行扩展。

每张 card 另有必填、固定形状的 `provenance`，字段精确为：

- `sourceRepository`：固定的来源仓库 HTTPS URL；
- `sourceCommit`：40 位小写十六进制提交；
- `sourcePath`：冻结提交中的仓库相对路径；
- `sourceFileSHA256`：该路径原始 bytes 的 SHA-256，不是 Git object ID；
- `adaptationStatus`：`unmodified / modified`；
- `modificationNote`：明确说明是否及如何摘编；即使未修改也必须显式说明。

`sourcePath` 只接受以 ASCII `/` 分段的仓库相对路径；每段词法冻结为
`[A-Za-z0-9][A-Za-z0-9._-]*`。因此绝对路径、空段、`.`、`..`、`~` 展开、Windows
drive/colon、反斜杠、NUL、空格和其他本机路径表示都必须拒绝。`sourceIDs` 只表达外部
书目引用；项目原创摘要的授权链只由
`provenance + attribution` 表达，不能把外部机构误写成摘要授权方。外部资料为
`linkOnly` 时 `licenseURL` 必须显式为 JSON `null`，`licenseIdentifier` 仍须明确写出
`rights-reserved-link-only`；只有实际打包了可再分发来源内容时才允许
`redistributable`。

`manifest.sourceCommit`、`attribution.sourceCommit` 与每张 card provenance 的
`sourceCommit` 必须完全相等；每张 provenance 的 `sourceRepository` 必须等于
`attribution.sourceRepository`。同一 `sourcePath` 在 pack 内只能对应一个
`sourceFileSHA256`。构建期生成器必须用
`git show <sourceCommit>:<sourcePath>` 取得原始 bytes，逐项重算 SHA-256，并与
`docs/content/` 来源登记中的 path → digest 锁完全相等；任一不一致都不得生成候选
资源。运行时 validator 只能证明 pack 内部一致性，来源认证仍由这项构建门禁和签名
App bundle 承担。

首批 candidate 固定为 48 张：45 张来源短卡必须同时满足 claim/source 引用完整、每项
claim 都有 `next_review_due`、固定 URL 合同和禁止医疗输出边界；另有 3 张从冻结提交中
改编的方案字段、化验记录和首诊/复诊准备摘要。缺少下一次复核日期的 13 张短卡以及包含
高时效热线和不合格固定 URL 的危机短卡不进入本包。3 张改编摘要因没有可冒充的 App
内容/医疗复核日期，在 candidate 中按来源最后核验日设置为已经 `stale`；真实人类复核
重新建立有效期之前不得进入 Release。精确清单、排除原因、路径和 source-file SHA-256
记录在 `docs/content/` 的 Batch 8C 来源登记中。candidate 有 53 个 anchor：48 张卡各
有一个 `pocketAppendix` anchor，另五个新增场景各有一个显式 anchor；8B 的既有来源入口
只做复用核对，不新增第二套来源卡。

来源短卡仍不是可原样搬运的 Release 文案。生成器在来源认证完成后执行一层精确、可测试
的 candidate 改编：只移除五张已登记卡中没有被该卡 `sourceIDs` 支持的中国大陆地区性
断言，并把 Markdown 引用前缀转换为 App 的纯文本段落。改编使用 card ID 与完整原句的
闭集映射；预期原句缺失、重复或发生漂移时生成失败，不做模糊替换。每张受影响卡的
`provenance.adaptationStatus` 必须为 `modified`，`modificationNote` 必须披露这两项
处理。冻结文件 digest 继续指向未经修改的来源 bytes，生成后的 card digest 则绑定实际
候选摘要，两者不得混用。

场景闭集为：

- `regimenField`
- `labRecording`
- `regimenAnalysisSource`
- `visitPreparation`
- `timelineRecord`
- `pocketAppendix`

单张卡只提供教育性摘要，不读取用户数值，不生成剂量、目标范围、个体化化验解释、
诊断、方案建议或停换药指令。场景映射只能使用页面已知的闭集产品语义，例如“正在录入
化验”或“正在查看化验记录”；不得按用户自由文本、药名、备注或数值猜测主题。

## 严格校验与容量

校验分为不能混淆的两层：

1. 结构/完整性 validator 决定 bytes 能否成为只读内容快照；
2. exposure validator 决定完整快照能否进入 candidate 或 Release。

结构/完整性 validator 必须先执行原始 bytes 大小门禁和 duplicate-key scanner，再在
`Codable` 解码前逐层执行 exact-key equality（不只是拒绝额外字段），并拒绝：

- duplicate key、未知字段、未知枚举、非法或 Unicode 混淆的稳定 ID；
- schema/content version 不支持、计数或规范化 SHA-256 不符；
- 重复 ID、悬空 source/card/anchor 引用、场景闭集或排序不一致；
- 空摘要、空适用边界、空许可证标识、空查阅日期、空署名或缺少逐卡 provenance /
  改编说明；`redistributable` 来源还必须有允许打包的许可证 URL；
- 非固定 HTTPS URL、非允许 host、URL 携带 query/fragment/userinfo；
- 不可再分发内容进入 `redistributable`，或把实际打包的项目原创摘要错误标成
  `linkOnly`；
- 剂量、目标范围、个体化解释、购买渠道、注射或自行调药字段；
- 日期顺序无效，或 `sourceStatus` 不是闭集 `current / knownUnavailable`。

当前唯一受支持的 `contentVersion` 精确为
`offline-contextual-content-candidate.1`。manifest、每张 card 和 release-state 必须
全部使用同一版本；任一不支持或不一致都 fail closed。真实人类批准只改变 review、
classification 与独立 release-state，不改变该批内容的版本身份。

首批 host allowlist 是编译期常量，精确为：

`academic.oup.com`、`ashpublications.org`、`creativecommons.org`、`github.com`、
`glaad.org`、`pflag.org`、`pubmed.ncbi.nlm.nih.gov`、`transcare.ucsf.edu`、
`wpath.org`、`www.asha.org`、`www.asrm.org`、`www.cdc.gov`、
`www.endocrine.org`、`www.hopkinsmedicine.org`、`www.mayoclinic.org`、
`www.nhc.gov.cn`、`www.plannedparenthood.org`、`www.psychiatry.org`、
`www.rainbowhealthontario.ca`、`www.samhsa.gov`、`www.thetrevorproject.org`、
`www.transcarebc.ca`、`www.transhub.org.au`、`www.who.int`。

host 必须与上表 ASCII lowercase 值完全相等，不能由内容包自行声明或扩展；同时拒绝
port、trailing dot、IP literal、userinfo、query、fragment、反斜杠、dot segment 和
对 `/`、反斜杠或 `@` 的 percent encoding。新增或移除 host 必须先修订来源登记、合同
与测试。

结构完整但已过期的卡片/来源仍可进入 typed snapshot，repository 标记为 `stale`；
`knownUnavailable` 来源保留书目信息和已经缓存的项目原创摘要，但禁用原文按钮并明确写
“来源入口当前不可用”。固定 URL 缺失/非法、状态字段损坏、引用悬空或任一卡片不能
通过结构校验时，整个 pack load state 为不可用，不展示部分 pack。单卡
`unavailable` 只用于 V13 收藏仍指向当前 pack 已不存在的稳定 content ID，不用于挽救
损坏 pack。candidate exposure 可以显示 `stale` 与
`sourceUnavailable` 供核对；Release exposure 必须额外拒绝：

- candidate/rejected、缺少真实内容与医疗复核或缺少复核日期/范围；
- 卡片或其任何引用来源在构建日期已过期；
- 任何引用来源为 `knownUnavailable`；
- 医疗/内容/App Review 分类未解决。

日期按 UTC Gregorian 的严格 `YYYY-MM-DD` 比较；`expiresAt` 当天仍有效，从下一 UTC
自然日开始 `stale`。repository 必须注入 `statusDate` 以便测试，不能依赖当前时区；
Release exposure 以构建时注入的日期判定，运行时日期只允许把既有内容自然降级为
`stale`，不能把候选或失效来源升级。

多来源卡片的展示状态优先级固定为：

1. 卡片或引用结构损坏：整个 pack `unavailable`，不展示任何摘要；
2. 任一引用来源为 `knownUnavailable`：`sourceUnavailable`；
3. 卡片本身或任一引用来源在构建日期已到期：`stale`；
4. 其余：`current`。

`sourceUnavailable` 和 `stale` 都可显示已校验的项目原创摘要。来源台账逐行计算按钮：
`knownUnavailable` 的来源禁用按钮；`current` 但已过期的来源仍可打开，不过确认页必须
显示“该来源需要重新核验”；其余 current 来源正常打开。卡片自己的固定网站原文 URL
独立于外部来源行，只有卡片状态不是 `unavailable` 且 URL 结构有效时才可打开。

`cardDigest` 唯一定义为：对单张 card 除 `cardDigest` 本身外的全部 fixed-shape 字段
执行 NFC 字符串规范化、对象 key UTF-8 字典序、数字十进制规范化和无额外空白的 canonical
JSON 编码，数组严格保留 authored order，再计算 SHA-256 小写 64 位十六进制。它不是
manifest 整包 digest，也不是来源文件 digest。修改标题、摘要、边界、分类、别名顺序、
来源引用顺序、display order、版本、日期或 URL 中任一语义字段，都必须得到新的
`cardDigest`。

manifest `contentDigest` 唯一定义为：对完整 top-level fixed-shape semantic object
执行同一 canonical JSON 编码，只移除 `manifest.contentDigest` 本身；所有 source、
card（包含已经校验的 `cardDigest`）、scenario anchor 与 attribution 都保留，所有数组
保留 authored order。digest 不负责来源认证；来源认证由签名 App bundle 与后续签名
Release 门禁承担。

fixed shape 中唯一允许的 JSON number 是三个 manifest count 和 card/anchor 的
`displayOrder`；它们都必须是非负、无前导零的 canonical integer token，词法只接受
`0` 或 `[1-9][0-9]*`。`1.0`、`1e0`、`-0`、负数和超出 Swift `Int` 的值在 typed
decode 前拒绝。canonical writer 原样写十进制 ASCII integer，因此不存在浮点或指数
等价形式。

首批上限冻结为：

- 原始 JSON：4 MiB；
- card：100；
- source：256；
- scenario anchor：128；
- 单标题：160 个 Unicode scalar；
- 单摘要：2,000 个 Unicode scalar；
- 单适用边界：1,000 个 Unicode scalar；
- 单卡别名：24；
- 单别名：80 个 Unicode scalar；
- 规范化搜索 query：80 个 Unicode scalar、最多 8 个非空 token。

raw scanner 另设最大嵌套深度 32 和单个 JSON string 16 KiB；超限必须显示内容不可用，
不能截断后继续解码。搜索只在已校验快照上执行，结果上限 100，因此空 query 可以返回
当前 pack 的全部卡片。

## 确定性搜索

搜索输入只保留在当前页面内存，关闭随身附页即丢弃；不写数据库、日志、通知或外链。
原始 query 和规范化 query 都必须满足 80 Unicode scalar 上限。查询按 NFKC、固定
`en_US_POSIX` 大小写/变音符号/宽度 folding 与固定 whitespace tokenization 处理；
不得使用当前 locale 的自然语言排序。每个 token 必须命中同一卡片的标题、别名、分类、
内容类型或摘要；空 query 返回由内容包显式 `displayOrder` 确定的全部卡片。

结果权重固定为：

1. 标题完整匹配；
2. 标题前缀；
3. 标题包含；
4. 别名完整匹配；
5. 别名包含；
6. 分类/内容类型；
7. 摘要包含；
8. `displayOrder`；
9. stable card ID。

多 token 排序精确冻结为：先计算完整规范化 query 的最佳 1–7 权重，完全不命中连续
短语时记为 8；再为每个 token 计算其最佳 1–7 权重，把 token 权重从最差到最好排序后
作为向量。先比较完整 query 权重，再按该向量字典序比较，数值较小者优先，最后比较
`displayOrder` 与 ASCII stable card ID。所有结果的 token 数相同，因此该向量同时冻结
混合字段命中的聚合语义，且不受 token 输入顺序影响。

收藏筛选只改变可见集合，不改变卡片权重。相同内容包、query 和收藏集合必须得到相同
顺序，不受时区、当前 locale、输入数组顺序或生成时间影响。

## 收藏与 Schema V13

V13 只新增 `ContentFavoriteRecord`，模型总数从 54 增至 55。其 persisted shape
精确冻结为：

- `@Attribute(.unique) id: UUID`；
- `@Attribute(.unique) contentID: String`；
- `contentVersion: String`；
- `cardDigest: String`；
- `createdAt: Date`；
- `updatedAt: Date`；
- `removedAt: Date?`；
- `lastOperationID: UUID`。

`recordType` 固定为 `ContentFavoriteRecord`，`recordID` 固定为 `id`，`recordKey`
固定为 `ContentFavoriteRecord:<lowercase UUID>`。`id` 在首次收藏时生成，恢复时保持
原值；`contentID` 创建后不可修改，数据库唯一约束和 writer 的显式唯一性检查必须同时
成立。`removedAt == nil` 表示当前已收藏，非空表示已经取消收藏。

事实表不重复保存 `datasetID`、`localRevision`、`digestVersion` 或 `digestHex`；
它们只存在对应的唯一 `RecordRevision`。`RecordDigestV1` 的 `recordID` 已包含 `id`，
字段清单精确为：

- `contentID`
- `contentVersion`
- `cardDigest`
- `createdAt`
- `updatedAt`
- `removedAt`
- `lastOperationID`

时间按 `RecordDigestV1.timestampMicroseconds`，字符串按其 NFC 规范化，nil
`removedAt` 编码为 `.null`。不得增加或遗漏字段而不升级 digest contract/version。
收藏 snapshot 从事实及 revision 联合投影出 `localRevision` 和 `digestHex`。

收藏/取消收藏通过 `AppDataWriter` 串行执行，并在同一事务中写当前事实、
`RecordRevision`、`OperationReceiptRecord` 和 receipt ledger。command 精确包含
`operationID`、`recordID`、`contentID`、当前 `contentVersion/cardDigest`、
`desiredFavorite`、可空 `expectedLocalRevision/expectedDigestHex` 和 `committedAt`；
首次收藏时两个 expected 字段都必须为 nil，已有事实的修改时都必须非 nil。首次调用由
调用方生成 `recordID`；同一 operation 重试必须携带同一 ID。已有 content ID 的 command
必须使用既有 record ID，ID 不一致按 operation conflict 拒绝。command digest 使用
`recordType = SetContentFavoriteCommand`、`recordID = operationID`，并覆盖上述全部
字段以及解析后的目标 `recordKey`。

receipt 的 `resultRecordType/resultRecordID` 必须分别等于
`ContentFavoriteRecord` 和目标 `id`；事实 `lastOperationID`、receipt、事实 revision、
receipt revision 与 receipt ledger 的 revision/`committedAt` 必须满足现有 receipt
完整性合同。operation ID 提供幂等重放；同 operation ID 但 command digest 不同必须
报冲突。expected revision/digest 防止过期页面覆盖新状态。command digest 中的两个
optional expected token 缺失时必须编码为 `RecordDigestV1.Value.null`，不能省略字段。
首次/再次收藏写当前卡片的 version/card digest；取消收藏保留上次收藏时的
version/card digest，只设置 `removedAt`。
内容包更新或卡片暂时不存在时仍保留收藏事实，但 UI 显示“收藏内容当前不可用”，不能
把它静默删除或错误映射到同名卡片。

写入语义进一步冻结如下：

- `contentID` 必须满足本 ADR 既有 ASCII stable card ID 语法；`contentVersion`
  必须是 NFC、非空且不超过 128 UTF-8 bytes，`cardDigest` 必须是 lowercase
  64-hex。恢复历史或当前不可用收藏时不要求其版本等于当前内容包版本；
- `desiredFavorite == false` 时，command 的 `contentVersion/cardDigest` 必须精确等于
  事实中上次收藏的值，writer 不覆盖它们；因此当前内容包已经移除该卡时仍可取消收藏；
- 新 operation 要求的目标状态与事实已经相同时返回 `staleRecord`，不新增 revision 或
  receipt；只有相同 operation ID 且 command digest 完全相同才返回
  `didApply == false` 的幂等 replay；
- expected revision/digest 只有“同时为 nil”或“同时非 nil”两种合法形状。首次命令遇到
  已存在的同 `contentID + recordID` 为 stale；同 contentID 绑定不同 recordID，或同
  recordID 绑定不同 contentID，为 operation conflict；已有事实不存在或 token 不匹配为
  stale；
- `committedAt` 必须是有限、可编码为微秒的时间，且不早于当前事实 `updatedAt` 和
  `DatasetMetadata.lastCommittedAt`（若后者非 nil），防止局部或全局提交时间倒退。

取消收藏使用 `removedAt` 保留本地可审计事实；界面必须说明取消收藏不等于抹除 revision
与 receipt。全部数据重置会删除收藏及其审计；若未来增加“永久删除单个收藏”的宣称，
必须先扩展 ADR 0015 的删除 target、tombstone 和 retained-audit 合同。

V13 必须同步扩展：

- `AppSchemaMigrationPlan`、container factory、StoreBootstrap 与 recovery 验证；
- 55-model `DataInventoryTaxonomy` 和 production capture；
- Readable JSON v2 的 schema 13 / 55-model 严格 wire contract；
- V13 导出/恢复 adapter、完整备份、冲突计划和 restore 预检；
- 保留 V12 / 54-model 输入 decoder，把旧备份迁移为 V13 零收藏；
- reset fresh-store verifier、数据清单、revision/digest 完整性和性能 fixture。

Readable JSON 的 format 仍为 v2，但 payload schema 必须明确为 `13.0.0`；不得把原先
只接受 V12/54-model 的合同静默改义。V12 输入继续使用冻结 decoder，V13 使用新增
adapter。收藏属于 `db.content`，进入 App Lock、本机清单、导出/备份、恢复、全部重置
与系统管理备份边界。

V13 `PortableDataRecord.fields` 精确冻结为：

| 字段 | kind | 可空 |
| --- | --- | --- |
| `contentID` | String | 否 |
| `contentVersion` | String | 否 |
| `cardDigest` | String | 否 |
| `createdAt` | timestamp microseconds | 否 |
| `updatedAt` | timestamp microseconds | 否 |
| `removedAt` | timestamp microseconds | 是 |
| `lastOperationID` | UUID | 否 |

持久化事实的 `id` 只映射到 portable envelope 的 `recordID`，绝不重复出现在
`PortableDataRecord.fields`。`recordType/modelType` 都为 `ContentFavoriteRecord`，
`recordKey` 使用上述 lowercase UUID 合同；dataset、local revision、digest version 和
record digest 继续只存在 envelope/revision 层。portable validator 使用 envelope
`recordID` 加上表内 fields 重算 `RecordDigestV1`，必须与唯一 `RecordRevision.digestHex`
完全相同。

## 场景入口与导航

- 方案编辑：在方案组成附近解释字段、剂型、途径与“忠实记录而非推荐”；
- 化验记录：在采样信息和结果台账附近解释单位、采样上下文与保留原报告；
- 方案分析：复用 8B 已实现的来源展开与固定外链确认；可显示对应离线摘要入口，但
  不能让摘要绕过 8B 停止分支；
- 复诊准备：从就诊摘要配置页主动打开独立清单。清单不进入 PDF/CSV，除非未来修订
  ADR 0017；不根据 Countdown 名称猜测“临近复诊”；
- 记录详情：按记录闭集类型显示相关摘要，永远不读取值、单位或备注做医疗匹配；
- 档案：把现有结构预览替换为随身附页搜索、收藏筛选和离线摘要阅读。

保持四个主 Tab，不增加“网站”Tab。各入口使用值类型 route 或 item-driven sheet；
返回后保留调用页状态。内容加载、内容不可用、空 query、无结果、无收藏、过期、
来源失效和收藏写入冲突必须是不同状态。

## 外链与网络边界

App 1.0 不发起网络请求。外部来源与网站原文只使用内容包内固定、无参数 HTTPS URL。
按钮先显示目标域名、将离开 App、系统浏览器可能产生网络记录，以及不会携带搜索词、
content ID、收藏、药品、方案、化验、记录、用户或设备信息；用户再次确认后才交给
系统浏览器。

不提供 URL 拼接、站内搜索 URL、query/fragment、Universal Link 回流、预取、连通性
探测、远程过期检查或后台刷新。来源失效由随 App 发布的新内容包明确标记，运行时不
自行联网核验。

## 人工复核与 Release 门禁

内容包状态为 `candidate`、`approved` 或 `rejected`。Release 必须同时满足：

- 内容和医疗复核均为真实人类，记录显示名、日期、范围；
- `completedAt` 必须是严格 UTC 日期，并满足
  `max(generatedAt, retrievedAt) <= completedAt <= min(expiresAt, statusDate)`；
- 来源提交、许可证、署名、改编说明、digest、引用、host allowlist 全部通过；
- 全部 Release 卡片未过期，且外部来源 distribution mode 与实际打包内容一致；
- 医疗/内容/App Review 分类已解决；
- candidate JSON 在 Release 构建中排除，独立 release-state manifest 显示精确未闭环
  原因。

release-state JSON 自身也必须执行大小、duplicate-key、exact-key 和 typed validator。
其 exact keys 为 `schemaVersion / status / contentVersion / message /
candidateResourceExcluded / contentReviewApproved / medicalReviewApproved /
classificationResolved / approvedResourceName`；`status` 只允许
`pendingHumanReviewAndClassification / rejected / approved`。
真值表唯一冻结为：

| status | candidateResourceExcluded | contentReviewApproved | medicalReviewApproved | classificationResolved | approvedResourceName |
| --- | --- | --- | --- | --- | --- |
| `pendingHumanReviewAndClassification` | `true` | `false` | `false` | `false` | `null` |
| `rejected` | `true` | `false` | `false` | `false` | `null` |
| `approved` | `true` | `true` | `true` | `true` | 非空正式 basename |

正式 basename 词法精确为
`^offline-contextual-content-release-[a-z0-9]+(?:[.-][a-z0-9]+)*$`，不含扩展名；
因此 `/`、反斜杠、`..`、candidate 名或其他资源名都不能通过。`approved` 资源仍要重新
跑完整 Release exposure validator。`candidateResourceExcluded` 只是声明，不是证据；
`project.yml`、生成后的 Xcode 工程和实际 Release `.app` 缺一项审计都不能关闭门禁。

Agent 调查、自动测试、代码 review 或来源仓库已有内容不能冒充 App 版本的真实内容与
医疗复核。当前首批内容保持 candidate，只进入 DEBUG/Preview/Test；Release 必须显示
`pendingHumanReviewAndClassification`，不得显示空搜索结果冒充内容可用。

### 已实现的 Release 日期与资源审计语义

同一份 approved 内容在构建审计与安装后运行时使用两个不同、不可互换的日期：

- 构建/发行审计把实际构建日期注入完整 Release exposure validator；若内容或引用来源
  当时已经过期，构建必须 fail closed；
- 已经通过上述构建门禁的签名 App 安装后，repository 用 release-state 所绑定内容中的
  `review.completedAt` 证明它在人工批准时满足 Release exposure；当前 UTC 日期只计算
  `current / stale / sourceUnavailable` 展示状态。自然过期后摘要继续离线可读并显著
  标为需要重新核验，不能在运行时把既有 approved 包整体变成“内容不可用”；
- candidate Bundle 加载路径在非 `DEBUG` 编译中直接关闭，即使调用方显式请求
  candidate exposure，也只能得到 pending，不读取候选 bytes。

`UnmanualReleaseContracts` scheme 在 Release 配置中验证上述分支。实际无签名
Simulator `.app` 另按根 `AGENTS.md` 的 Release 构建命令生成，并由
`Scripts/audit_release_bundle.sh` 核对三个 candidate 均未打包、三个 release-state
与仓库完全一致，以及 Batch 8C 在真实人工复核前保持 pending。该 artifact 不是签名
Archive，也不能替代 Batch 9 的真机和 App Store 门禁。

## UI 与可访问性

- 随身附页采用目录/台账/校样语法，不复制网站 Header、首页区块或圆角卡片墙；
- 搜索框有持久提示，分类和“只看收藏”同时用文字、位置和选中状态表达；
- 收藏按钮最小 44 × 44 pt，有明确“已收藏/未收藏”标签、VoiceOver value 和状态播报；
- 阅读页先显示摘要与适用边界，再显示版本、查阅/到期、来源和许可；
- 过期内容仍可阅读已缓存摘要，但必须在标题附近显著标为“需要重新核验”；损坏或未通过
  validator 的内容不可展示；
- 每张摘要和随身附页底部都必须能进入 App 内“内容来源与许可”页。该页完整显示
  “MtF Manual contributors”、来源仓库与精确提交、是否改编及修改说明、
  `CC BY-SA 4.0` 名称、正式许可证 URL 和“改编内容按相同或兼容许可证共享”的说明；
  来源仓库与许可证 URL 都经过同一固定域名外流确认后才交给系统浏览器；
- 支持 Dynamic Type、Accessibility 5、VoiceOver、外接键盘、横屏、iPad 和减少动态
  效果；搜索结果更新不能对每次输入做冗长播报。

## 验证要求

Batch 8C 至少覆盖：

1. 原始 JSON exact-key、duplicate key、schema、ID、引用、URL、许可证、署名、digest、
   过期、来源失效 typed state、复核和 Release 门禁；
2. 搜索的中文/英文/别名、大小写/宽度、token、排序、上限、空 query、无结果和确定性；
3. V12 → V13、V12 备份 → V13、V13 完整 round-trip、55-model inventory、reset、
   并发、幂等重放、过期写入、回滚与持久化重开；
4. 六场景入口、返回/重进、过期/损坏/内容不可用、收藏/取消/冲突和固定外链确认；
   每卡及随身附页还要覆盖可访问的 CC BY-SA 署名/修改/许可证入口；
5. 静态源码/构建产物与动态离线检查，证明无网络 API、WebView、远程配置或 URL 参数；
6. 320 × 568、390 × 844、430 × 932、768 × 1024、844 × 390 和
   320 × 568 Accessibility 5 渲染；
7. 44 pt、VoiceOver、外接键盘、键盘遮挡、安全区、Reduce Motion 和内存内搜索词清理；
8. Release bundle 不含 candidate JSON，release-state 明确说明门禁。

## 实施模块

1. 版本化内容包、validator、确定性 repository/search；
2. Schema V13 收藏、迁移、55-model inventory、便携数据与 reset 合同；
3. 随身附页搜索、筛选、收藏和离线摘要阅读；
4. 五个新增场景入口，以及对 Batch 8B 方案分析来源入口的复用核对；
5. Release 资源、全量回归、真实渲染、离线/隐私审计。

每个模块独立执行调查、计划、TDD 实施和全新 reviewer 门禁；前一模块未通过不得进入
下一模块。

## 2026-07-31 实施与验证证据

- 模块 1–4 已分别完成独立调查、实现、定向验证和全新 reviewer 门禁；模块 5 关闭了
  非 Debug candidate loader、构建审计日期与安装后 stale 日期混用、实际 Release
  `.app` 资源审计和独立 Release 配置测试目标等缺口。
- 当前候选包包含 48 张摘要卡与 53 个场景 anchor；Schema V13 将收藏纳入 55-model
  inventory、便携数据、restore、关联删除与全部重置，不保存搜索词。
- Python 生成器测试 `9/9`、独立 `UnmanualReleaseContracts` 测试 `6/6` 通过。
  当前冻结源码的组合机器证据为 `988/988`：单元、集成与渲染 `918/918`、
  UI `70/70`，失败和跳过均为 0。首次完整 `Unmanual` scheme 的 918 项非 UI
  全部通过，3 项既有方案 UI 用例因 XCUITest 在控件滚出屏幕时直接查询而失败；
  只修改测试滚动定位后，三项定向回归 `3/3`、完整 UI `70/70` 通过，生产代码
  没有随之改变。
- 交付复审另关闭了中文可见分类与内容类型搜索、逐来源日期/状态/适用地区与人群、
  不可用收藏筛选计数、source lock 重复 key 与逐层 exact schema、五条没有同地域
  来源支持的中国大陆断言、Markdown blockquote 标记泄漏，以及改编原句重复出现时
  会被全部替换而非 fail closed 的门禁缺口。生成器现在要求每条冻结改编原句精确出现
  一次并只替换一次。重新生成的候选包仍为 48 张卡、45 个来源与 53 个 anchor；
  48 张卡均有改编说明，45 个来源均有地区、人群与当前状态。
- generic Debug 与 Release Simulator build 均通过；对实际 Release `.app` 执行
  `Scripts/audit_release_bundle.sh` 后确认三个 candidate 都不存在，三个 release-state
  与仓库逐字节一致，Batch 8C 状态仍为
  `pendingHumanReviewAndClassification`。Privacy manifest 与 App/源码 plist 均通过
  语法检查。
- 静态源码、工程和实际 App 依赖审计未发现 App 发起网络、WebView、CloudKit/APNs、
  遥测、崩溃上传、远程包或第三方 runtime。固定 `openURL` 仍是用户二次确认后进入
  系统浏览器的独立外流边界，不属于自动联网。
- 已从完整 `.xcresult` 导出并人工查看随身附页的 320 × 568、390 × 844、
  430 × 932、768 × 1024、844 × 390 与 320 × 568 Accessibility 5，
  以及五个场景入口、loading、Release pending、来源不可用和窄屏 AX5 阅读器。
  未发现横向截断、不可读状态或敏感资料泄漏；窄屏最大字号依赖纵向滚动。
- 当前 Schema V13 Release-config Simulator performance preflight `1/1` 通过，
  完成 1 次预热和 20 个正式样本，测试体 1006.644 秒、测试会话 1017.283 秒；
  导出的 JSON/CSV 为 20 个完整样本、root cleanup 成功、结束热状态 nominal；
  原始 JSON 明确记录
  `acceptance = not-evaluated; numeric thresholds and a frozen cross-device fixture are pending`，
  因而不能解释为最低设备、跨设备数值性能或真机门禁通过。
- 五个实施模块均通过各自的独立 reviewer；整批上一轮 reviewer
  `/root/batch8ab_full_failure_sqlite` 未参与 Batch 8C 调查、实现或模块审查，并在只读
  核对完整 tracked/untracked diff、三个结果包、实际 Release `.app` 与渲染附件后给出
  `FINAL PASS`，P0/P1/P2/P3 均为 0。上述交付复审修复完成后必须再由一名从未参与
  调查、实现或前序审查的全新 reviewer 核对冻结候选；其明确零问题前不得提交或推送。

以上证据仍不能代替真实人类内容/医疗复核、首发地区与医疗分析发行分类、动态网络
抓取、签名 Archive、真机数据保护/系统备份、人工 VoiceOver、外接键盘、键盘遮挡、
Reduce Motion 和全状态设备矩阵。正式 release pack 仍不存在，这是刻意的发行门禁，
不是由 Agent 自动批准的待生成文件。

## 非目标

- 网站全文、HTML/Markdown runtime、WebView、网站首页或“网站”Tab；
- 运行时联网搜索、内容下载、远程更新、AI 医疗问答或搜索历史；
- 按用户药名、备注、化验值、单位或自由文本做医疗语义推断；
- 把摘要写进就诊 PDF/CSV，或把公共内容伪装成用户病历事实；
- 方案匹配、剂量、目标范围、个体化化验解释、购买或自行调药；
- 用 `UserDefaults`、日志、通知、分析事件或旁路文件保存收藏/搜索词；
- 在 Batch 9 前宣称真机数据保护、签名 Archive、App Store 分类或内容批准已通过。
