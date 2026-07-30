# MTF不全书 App / Unmanual

一个面向中文 MTF 用户、计划以非营利和开源方式建设的 iOS 项目。

Unmanual 是一个轻量、私密、可以长期使用的个人 HRT 记录工具：帮助用户记住今天、回看自己的旅程、保存方案变化，并在需要时整理自己的记录。

网站负责解释“这件事通常是什么”，App 负责帮助用户看见“这件事在我身上是怎样发生的”。完整知识内容仍由 [mtfbook.com](https://mtfbook.com/) 提供。

> **当前状态（2026-07-30）**
>
> - App 版本：`1.0`（build `1`）；`V2.5` 只是内部视觉迭代名。
> - 工程阶段：Batch 0 已完成；Batch 1 的本地实现与 Simulator 自动化已完成，但整体完成门禁尚未关闭；Batch 2、Batch 3、Batch 5、正式首次设置、HRT 历程生命周期、Batch 5 后续专项、Batch 6 与 Batch 7，均已完成本地实现。Batch 4 库存不进入 App 1.0，保留阶段编号但后置为需求验证项。
> - 当前位置：当前本地工作树使用 Schema V12；除应用锁、最近任务隐私遮挡、54-model 数据清单、关联删除与全部数据重置外，现已实现就诊摘要、PDF/CSV、Readable JSON v2、含 active 附件的完整备份，以及以 inactive generation、durable journal 和 pointer-last 激活完成的恢复/替换协议。本轮进一步闭环了控制 JSON 的独立回滚副本、restore journal v1 → v2 严格迁移、激活期间 Store/Files namespace 只读与流式内容封印、完整备份的双重审计、无 mmap 的冻结 FileWrapper 交接和交接前临时 package 清理，以及设备投影策略校验。这里的“完成”只限于源码、自动化、Simulator 与独立审查范围；外部 Files 导入/导出仍只在 DEBUG/internal 暴露，不包含真机或 App Store 门禁。
> - GitHub 阶段报告：仓库按模块保留阶段快照；Batch 7 继续使用同一方式合并到 `main`，不创建 GitHub Release，也不上传内部工作日志或构建产物。
> - 发布状态：尚未达到 App Store release-ready，也尚未开始发布前真机测试。

## 我们在哪里

目前落地的是一套可迁移、可恢复、可审计的本地数据底座，以及正式首次设置、稳定的时间事实、HRT 暂停/恢复与多周期、方案版本、今日执行、Countdown 生命周期、本地提醒、化验、状态、附件、统一个人时间线和就诊材料整理。新用户先了解真实存储边界，再建立可供 Today 确定性使用的封存方案；之后可以查看当日计划、记录已使用或跳过、追加纠错、管理 HRT 历程与一个当前目标日、为计划和 Countdown 开启中性内容的设备本地提醒，并在本机保存、回看、比较、更正或删除化验与状态记录。需要就诊时，可以先预览选定时间范围内的摘要，再生成 PDF 或 CSV；完整数据则由版本化、可审计且包含附件的本地备份协议承载。

当前已落地的阶段与专项进展是：

- **Batch 0 — 合同冻结**：确认 App 1.0、iOS 17+、本地优先、无 App 主动联网、`.systemManaged` 系统备份边界，以及时间、执行、化验和数据谱系的跨模块合同；当时冻结的库存安全合同保留为历史边界，但不再构成 App 1.0 的实现范围；
- **Batch 1 — 数据安全底座**：实现 V1 → V2 bridge、generation copy/journal/pointer、幂等 backfill、revision/digest、Recovery Mode、读写 actor、有界查询和性能证据 harness；代码与 Simulator 自动化已完成，真机文件保护、系统备份恢复和最低设备性能仍是发布门禁；
- **Batch 2 — 时间与方案版本核心**：实现 additive Schema V3、civil date、historical timestamp、草稿/封存方案、组成项与计划数据、当前/未来/历史解析、变更校样和历史记录关联。
- **Batch 3 — 今日执行、Countdown 与本地提醒**：实现 additive Schema V4、V6 与 V7、四类确定性 occurrence、append-only 执行事实与纠错、一次 snooze、完整 Countdown 生命周期、typed command 审计、提醒偏好、覆盖投影和 UserNotifications 统一设备本地调度。
- **Batch 5 — 化验、状态、附件与统一时间线**：实现 additive Schema V5、结构化化验样本与结果、可版本化状态指标、本机私有附件存储、旧化验幂等回填，以及跨化验、状态、执行与方案的有界统一时间线；未加入 App 主动联网、云同步或第三方运行时依赖。
- **Batch 6 — 隐私与数据控制**：实现 additive Schema V11/V12、默认关闭且需系统认证启用的应用锁、非 active 场景不透明遮挡、完整数据 manifest 与清单、跨模块 read/mutation/reset 协调、关联逻辑删除，以及通过 quarantine 和 reset journal 跨两次启动完成的全部数据重置；系统备份与外部副本边界保持如实可见。
- **Batch 7 — 报告与完整备份**：实现可选时间范围的就诊摘要、PDF/CSV、冻结 54 类记录和 9 类控制事实的 Readable JSON v2、含当前 active 附件及双重摘要校验的 `.unmanualbackup` package，以及恢复/替换前预检、显式二次确认、inactive generation 写入、逐阶段 durable journal、冷启动续做和 pointer-last 激活；generation pointer 与三类 journal 共享内容寻址、可冷启动重放且语义校验的原子控制文件事务，发布过的 restore journal v1 会按 pointer/phase 矩阵严格迁移到带 identity/state digest 的 v2。激活窗口会把 App 自有目录与 Store/Files 普通文件规范化并设为只读，对祖先目录、Files root、SQLite bundle、attachment payload 与 exact tree 建立 identity、mode、时间戳和流式摘要封印；旧可写 descriptor 的同 inode 内容或目录 mode/ctime ABA 会拒绝激活并保持来源 pointer，退出窗口后精确恢复 `0700/0600`。完整备份预览只保留紧凑审计事实，不建立 wrapper；确认且 state 未变化后才在 retained lease 内冻结 namespace，以有界递归深度 descriptor 复核证据，并用 `.withoutMapping` 建立唯一一个拥有自有 bytes 的 wrapper。普通文件、目录和内部节点分别限制为 `2100/2002/4102`，合法 2,000 附件 fixture 的 4,004 节点已覆盖，临时 descriptor 峰值为 3。磁盘 package 与 ownership intent 在快照交给 UI 前即被精确清理。当前 DEBUG/internal `FileDocument` 导出另有 64 MiB 内容 bytes 上限，不是总 RSS 保证；2 GiB 仍是格式/导入上限，完整 file-backed 2 GiB 输出留待 Batch 9。自动合并只提供无写入的冲突分析，不在 1.0 中静默拼接两条历史。对 Files 的完整数据导入/导出仍只在 DEBUG/internal 暴露，等待 Batch 9 完成发行政策、真机文件保护与外部文件提供方门禁。
- **正式首次设置 — Schema V8**：新安装在主标签页之前进入可恢复的根门禁；隐私说明先于敏感资料写入，封存方案是唯一必需业务设置，开始日、提醒和 Countdown 可明确跳过。legacy 与 V7 升级使用 grandfathering，读取或迁移不一致时 fail closed。
- **HRT 历程生命周期 — Schema V9**：把单一开始日扩展为可审计的开始、暂停、恢复与多个半开区间周期；Today 同时显示当前周期日，以及从首次开始后经过的自然日（包括暂停日），暂停时不伪造当前周期天数。生命周期事件进入统一时间线，温和模式使用中性名称；暂停不会改写已封存方案、执行事实、提醒偏好、化验或状态关系。
- **化验趋势与确定性单位换算 — ADR 0012**：按稳定项目身份和检测变体读取有界历史，原始值与原始单位始终保留；只允许规则表中冻结的同维、纯比例显示换算，未知单位、比较符边界和不可比较数据不会被伪装成连续趋势。
- **父记录纠错与删除 — Schema V10 / ADR 0013**：化验与状态使用 append-only lifecycle，不原地覆盖 V5 原始事实；纠错先显示完整变化复核，终态删除先冻结关联影响，并把附件文件、元数据、数据库事件、receipt、revision 与 Recovery journal 纳入同一事务边界。correction/delete 的 command digest 会从 typed snapshot、前序 head、删除影响和附件 operation manifest 重新计算，不只依赖 event/receipt 互相相等。

### Batch 3 本次阶段实现

提交 `b4e6b10` 与 `7ceb86a` 完成“今日执行 + 设备本地提醒”基础闭环；`2867b83` 补齐 Countdown 完整状态机与统一提醒调度，`3ae9a60` 经完整独立审查加固 V7 完整性、旧库迁移和附件 generation copy。这些变更已作为阶段报告进入 `main`。

- **确定性计划派生**：按 sealed 方案生成 daily-times、weekly、every-N-days 和 one-off occurrence；统一 canonical key、civil date/time、方案半开区间、fixed/floating 时区、DST gap/overlap 和 fail-closed 容量上限。
- **Append-only 执行事实**：可记录“已使用”或“本次跳过”；未操作不制造事实，修改通过追加 correction 完成。`operationID` + canonical digest 保证幂等，冲突 replay 零写入失败，事实、revision、receipt 与 ledger 同事务可审计。
- **时间与方案关系保护**：执行时保存完整历史时间与计划快照；按实际当地日期解析方案关联，歧义保留可见复核项。封存后续方案不得让既有执行或 snooze 事实变成孤儿。
- **本地提醒意图与调和**：用户先看中性预览再主动申请系统权限；提醒偏好与方案分离，snooze 最长 24 小时。调度使用 14 个当地日窗口和 60 条保守预算，先保障每条启用规则的下一项，并保留非本 App 通知。
- **并发、系统时间与 Recovery**：调和采用单调请求序号和串行队列，旧请求不得覆盖新结果。App ready、回到前台、换日、显著时间变化和时区变化都会重读 Today 并调和提醒。Recovery Mode 会使在途工作失效，且只清理 `unmanual.exec.v1.` 与 `unmanual.countdown.v1.` 两类本 App 自有 request。
- **数据完整性加固**：Schema V4 backfill 不创造执行事实，也不默认开启提醒。Canonical 时间编码在微秒精度上可失败检查，拒绝 NaN、无穷和超出 `Int64` 范围的时间；关系 validator 检查 occurrence、方案、receipt、event、override 与 coverage 之间的一致性。
- **可用性与辅助功能**：Today 台账覆盖 loading、error、empty、review、saving 和 recorded 状态；动作防重入，纠错与提醒授权 sheet 可滚动且主操作在窄屏与大字号下可达。辅助文字改用通过 WCAG AA 的语义颜色令牌。
- **Countdown 完整生命周期**：以 civil date 保存目标日，覆盖建立、修改、到期后继续计时、完成、归档、删除和原子替换；生命周期事件、V7 typed command audit、revision、receipt、digest 与 opaque tombstone 保持可审计，删除后不保留标题等敏感载荷。
- **旧数据复核与有界回看**：V6/V7 幂等回填不会悄悄挑选多个旧当前目标；冲突记录进入可见复核区，解决前禁止直接建立新目标，也禁止通过“删除并建立新的目标日”原子替换绕过门禁。V6 中已启用但缺少 typed command 来源的提醒在升级后停止调度，必须由用户在 V7 显式重新保存。当前项、复核项和历史事件使用独立有界查询与分页，完成或归档的 Countdown 进入统一个人时间线。
- **统一提醒预算与可见覆盖**：执行提醒和 Countdown 共享 60 条保守预算，同时只管理各自拥有的 request 前缀，不删除其他 App 的通知。权限拒绝、系统设置、预算不足、DST 无效时间、调度失败和覆盖过期都会保存并显示，不再静默吞掉失败。

### Batch 3 2026-07-25 完整复核

三名全新只读调查者分别从提醒调度、生命周期数据与 SwiftUI/辅助功能角度重新检查当前源码。主审复核证据后补齐：

- 任意提醒 add/remove/readback 失败都会清理全部本 App owned pending；清理无法确认时不会伪装成 disabled。过期调和不会刷新 Today，schedule 与 Countdown coverage 也会做状态/数量/错误码一致性校验；
- “继续计算”在同一个 target 周期只能从待决定状态执行一次；改期会开启新的周期，新目标日到达后可再次继续计日，单纯改标题或提醒不会重置门禁。命令的 `today` 必须与历史时间的当地日期一致，目标日前伪造 continue 会被关系校验拒绝。内容编辑不再按当前时区重写 legacy target，历史事件显示使用记录时捕获的 civil time；
- V6 已落盘模型保持冻结，完整性增强进入纯 additive V7。新写入由 typed command v2 audit 绑定私有标题 commitment、目标日、Today/提醒意图、事件时间与语义、前后 materialized facts、终态提醒快照和前序 audit 链；receipt 引用该 command digest。联合改写 state/event/legacy/reminder 并重算普通 revision 仍无法伪造合法命令。既有 V6 前缀使用诚实的 checkpoint，不伪装拥有历史 typed command；升级前已启用的提醒必须经过 V7 update/replace 才重新调度；
- 设备时钟被校正后，后写事件的 wall-clock instant 可能早于创建时间；逻辑先后继续由 event 链与 local revision 决定，不会让一次成功编辑在下次启动时自发进入 Recovery。任意生命周期的未解决 legacy review 都在写层阻止新建目标，不能只依赖 UI 隐藏入口；台账未加载完时用“至少 N 项”说明分页数量；
- Today、Countdown 编辑器与档案温和模式的读取错误不再被吞成空内容；Today 主投影或档案摘要读取失败时会隐藏依赖事实、伪空状态与导出操作，只保留错误和重试。档案摘要与温和模式错误彼此独立，保存偏好不会清掉仍存在的摘要错误。温和模式可在正式档案页切换，保存期间阻止跳到仍显示旧名称的页面，温和模式下新建或替换目标时不会先暴露原始标题字段，开启后可见文本与辅助功能树均不暴露原始标题；
- 历史/复核分页改为由不可变排序键驱动的 `limit + 1` keyset cursor；每页查询保持有界，不再读取整张表或维护会话级全量 ID 集合，并以请求代次阻止旧首刷或旧分页覆盖新结果；
- 最后一轮完整性复核进一步确认：任意 archived legacy review 仍未解决时，原子替换与直接新建一样会在事务前及事务内失败且零写入；历史详情读取失败会清除旧投影，只显示通用标题、错误与重试，不会继续暴露路由快照里的旧名称、日期、状态或提醒事实，也不会永久停在“读取中”。
- 调和期间 foreign request 数量变化时，最终回读会重新冻结仍被允许的 authoritative request 前缀。只要有界收缩能把总数降到 60 条以内，就保留该前缀，并按 Schedule / Countdown 两个域分别报告 `limitedByBudget`、确认数量和首个未覆盖时间；不会因为它少于初始计划就误删全部 owned request。只有有界收缩仍无法满足总预算或回读不一致时才 fail closed。
- 调和开始时总数已经超过 60 也会先区分 foreign 与 owned：59 条 foreign + 2 条匹配 owned 会保留第 1 条 authoritative owned，60 条 foreign + 1 条 owned 只清除 owned 并报告预算受限；foreign 本身超过预算才进入无法收敛的失败路径。V6 关系校验还会沿事件链找到最近一次真正建立或改变 target 的时区锚点，把 legacy `Date` 还原为 civil date，并把普通创建的 state / legacy `createdAt` 锚回 `.created` 根事件，拒绝同步重算 revision 的跨记录篡改。
- 历史详情的完成/归档 civil time 由当前生命周期、latest event kind 与显式事件链接共同解析；`keepArchived` 后的 `.reviewResolved` 必须沿 `previousEventID` 使用真正归档的 predecessor。即使复核和归档恰好发生在同一 instant，也不会按时间相等误选复核事件的时区。
- 后续独立迁移/完整性复核又发现并修复三类阻塞：completed lifecycle backfill marker 不再把首次迁移数量误当作永久基数；V6 模型不再被原位扩字段，V6 → V7 使用兼容的 SwiftData configuration 与 inactive generation；V5/V6 升级会复制并审计完整 `Files/` 树、拒绝 symlink，并在附件与 V7 完整性验证全部成功后才切换 pointer。

本轮重新验证普通单元、集成与多尺寸渲染 `394/394`、完整 UI `28/28`，合计 `422/422`；Release-config 合同 `9/9` 与 generic iOS Simulator 无签名 Debug build 均通过。当前 V7 的完整 Release-config performance preflight 也通过 `1/1`，完成 1 次预热与 20 个正式样本；该结果只证明 harness 与证据链可完整执行，`acceptance = not-evaluated`，不冒充数值性能或真机门禁通过。

### Batch 5 本次阶段实现

已进入 `main` 的阶段提交日志：

- `b4e6b10` — `feat: add today execution and local reminders`：实现今日执行与设备本地提醒基础闭环；
- `7ceb86a` — `fix: harden today execution and reminders`：修复提醒覆盖、并发与错误可见性；
- `2e18332` — `docs: summarize Batch 3 implementation`：补齐 Batch 3 已实现范围与未完成边界；
- `2993027` — `feat: add labs status attachments and timeline`：落地 Schema V5、化验、状态、附件与统一个人时间线；
- `d342ee7` — `feat: harden labs status attachments and timeline`：闭环附件事务、Recovery、预览 lease、时间线并发与 V4 → V5 中断迁移；
- `2867b83` — `feat: complete countdown lifecycle`：完成 Countdown 生命周期、复核、时间线与统一提醒调度；
- `3ae9a60` — `fix: harden countdown lifecycle integrity`：冻结 V6、引入 additive V7 typed command audit，并闭环 V5/V6 → V7 与附件迁移门禁。

- **结构化化验**：`LabDefinition`、`LabSample` 与 `LabResult` 分离；保留用户原始名称、代码、数值、单位、参考范围和上下文，同时使用独立规范化值支持确定性排序与验证。旧化验按稳定映射幂等回填，不改写旧事实。
- **状态记录**：指标定义、观察值、历史时间和附件元数据同一事务提交；新增指标与首次观察不会留下半成品。指标可以归档并释放活跃槽位，既有观察的历史快照继续可读。
- **私有附件**：附件保存在 App 私有 Application Support 目录，文件名使用不含原始名称的 opaque 标识；化验、状态与普通旅程记录都通过同一 generation 级 mutation service 提交附件。导入采用先写 journal、再暂存、再原子移动、最后提交数据库的恢复协议，并拒绝符号链接逃逸；跨 `await` 的事务由全局 mutation lease 串行化。Release 不暴露 Files 导入入口。
- **统一个人时间线**：化验、状态、执行与方案事件投影到统一条目；有明确时刻的事实按 instant 排序，无时刻的 civil-date 事实进入独立日期通道。查询按来源有界抓取、稳定游标分页，并保持同一时刻条目不丢失。
- **入口与回看**：旅程页可以新增化验与状态、查看附件和归档指标；Today 的最近化验来自 V5 canonical sample，并可直接打开同一条时间线详情。
- **完整性与恢复**：启动时恢复未完成附件 journal 并审计活动附件；缺失、越界或校验失败会进入 Recovery Mode，不把损坏状态伪装成正常启动。

### 正式 onboarding 本次阶段实现

- **根门禁与准确恢复**：App 在构造主标签页前读取专用 onboarding 快照；新安装从隐私说明开始，进程退出后按持久化的准确步骤恢复。读取错误、重复事实、超限或不一致引用不会被当作空资料绕过。
- **六步克制流程**：依次覆盖隐私与系统备份边界、可选开始日、必需封存方案、可选本地提醒、可选 Countdown 和完成核对；不要求录入库存，也不把草稿或待迁移复核方案当成有效方案。
- **明确权限边界**：进入提醒步骤不会申请通知权限。只有用户选择具体计划时段、看过中性锁屏预览并确认后才请求系统权限；“用户选择了提醒”和“系统实际已安排”分别读取并呈现，权限拒绝、受限或调和失败不会删除方案，也不会伪装成已成功安排。
- **V8 安全采用**：V8 只新增 onboarding progress 与 backfill facts；V7 先复制到 inactive generation，完成回填、关系与 digest 校验、附件树审计和文件保护检查后才切换 pointer。legacy 与 V7 用户明确 grandfathered，新用户不会被误判为旧用户。
- **事务与并发保护**：步骤转换带 expected-step 门禁；完成状态、用户偏好、revision 与 dataset metadata 同事务提交。提醒绑定精确的 schedule rule ID 与 revision，避免旧页面为已变化的计划开启提醒。
- **完成前修改与再次进入**：完成核对页修改某项时会重新打开对应的持久化步骤，清除需要重新确认的跳过事实；档案页使用与快照绑定的单一呈现状态再次打开设置，避免旧页面闭包造成永久“正在读取”。
- **可访问性与回归**：六个步骤覆盖手机、平板、横屏与最大辅助字号渲染；UI 回归覆盖新装门禁、进程重启续走、方案硬门禁、可选步骤、权限拒绝、完成页修改、错误 fail-closed、档案再次进入和大字号横屏可达性。

### 化验趋势与父记录生命周期本次阶段实现

- **趋势读取而非二次事实源**：趋势从当前有效化验记录即时投影，不新增可漂移的缓存表；按稳定 `itemDefinitionID`、检测变体、发生时刻与稳定 ID 分组排序，同日多次结果全部保留。
- **确定性显示换算**：换算表带稳定规则 ID 与版本，只覆盖已冻结的同维单位组合；Decimal 计算保留原始输入，换算仅改变显示，不改写记录、参考区间或医疗含义。未知单位、跨维单位和不精确比较符会明确分组或只进入台账。
- **可读趋势界面**：化验详情可进入项目变化页；折线不是唯一信息载体，每个点都有日期、原始值、显示值、单位和检测变体对应的台账行。普通模式与温和模式使用不同表面标题，但用户主动打开的事实仍如实显示。
- **Append-only 纠错**：化验和状态的最初录入事实永久保留；每次纠错追加带前后 facts digest、operation receipt、revision 与完整历史时间的事件。`nil`、空字符串、原始 Decimal、检测变体、结果增删与重排不会被界面静默归一化。
- **终态父记录删除**：删除前先显示结果、附件与纠错次数影响并冻结 digest；确认时在全局 mutation lease 内再次核对 head、revision 和附件集合。附件逐个进入 recoverable trash，数据库失败会回滚，回滚或 finalize 不完整会进入 Recovery，不把部分删除伪装成成功。
- **V9 → V10 安全采用**：旧 generation 复制到 inactive V10，完成 lifecycle backfill、事件链、revision/digest、附件树、文件保护和持久化重开验证后才切换 pointer；删除后的记录从正常详情、Today、趋势和统一时间线消失，但保留不含医疗正文的审计墓碑。

### 2026-07-27 全量回归收口

- **迁移与完整性**：HRT 生命周期迁移统一使用秒级 canonical timestamp，迁移事件、状态、revision 与 metadata 不再因分数秒产生不一致；收据台账只接受正常同 revision 写入，或有明确 Countdown backfill marker 证明的相邻 reconciliation revision，任意后续 revision 前移会 fail closed。HRT 生命周期损坏会进入 Recovery，不把损坏事实伪装成正常状态。
- **可选表面与有界读取**：没有 HRT 历程或化验记录时，Today 不显示虚假的可选模块；化验趋势改为按目标项目分批定向读取，即使存在超过 4,096 条无关活动结果，也不会因此误判目标趋势损坏。
- **纠错、附件与温和模式**：化验纠错界面支持结果顺序调整并在变化复核中明确展示；父记录 mutation 期间会阻断附件并发操作；化验的 Today、Journey、详情与趋势表面统一遵守温和模式。终态删除预览逐个冻结附件的稳定 UUID 身份，不能仅凭数量、大小或摘要把附件互换当作同一集合。
- **大字号可达性**：自定义标签栏在 Accessibility 5 下验证存在且位于屏内；关键主动作验证存在、位于标签栏上方且可点击，不再把 accessibility tree 中的屏外元素误算为可达。

## 功能完成度

这里的“已完成”只表示源码、自动化与 Simulator 范围内已经闭环并通过独立审查，不表示真机或 App Store 发布门禁已经通过。“实施中”不会因为已经有 ADR、模型或测试草稿而提前计入已实现。

| 能力 | 当前状态 | 已闭环范围或剩余边界 |
| --- | --- | --- |
| 数据安全、迁移与恢复底座 | 已完成本地实现；真机门禁待验证 | V1 → V12 migration、generation copy/journal/pointer、revision/digest、Recovery Mode、有界读写与性能证据 harness 已落地 |
| 正式 onboarding | 已完成（本地，Simulator / 自动化范围） | 隐私说明、可选开始日、必需封存方案、可选提醒与 Countdown、准确续走、grandfathering 与 V7 → V8 安全采用 |
| 方案版本与 Today 执行 | 已完成（Simulator / 自动化范围） | 草稿/封存方案、四类 occurrence、已使用/跳过、append-only 纠错、一次 snooze 与本地提醒 |
| Countdown | 已完成（Simulator / 自动化范围） | 建立、修改、到期后继续、完成、归档、删除、替换、统一提醒与时间线 |
| 化验、状态、附件与统一时间线 | 已完成（Simulator / 自动化范围） | 结构化录入、状态观察、私有附件、跨来源回看与有效 V10 父记录投影 |
| HRT 暂停、恢复与多周期 | 已完成（Simulator / 自动化范围） | V9 repository、审计事件、canonical 秒级迁移、receipt/ledger 原子性、V8 → V9 安全采用、Today 状态、管理界面、统一时间线与温和模式 |
| 化验趋势与确定性单位换算 | 已完成（Simulator / 自动化范围） | 稳定项目身份、变体分组、目标项目分批有界读取、冻结规则版本、同维显示换算、台账与温和模式 |
| 化验/状态父记录纠错与删除 | 已完成（Simulator / 自动化范围） | V10 append-only 纠错、结果重排与完整变化复核、关联影响预览、稳定附件身份、附件事务、终态删除、恢复与并发门禁 |
| 应用锁、最近任务遮挡与全 App 数据控制 | 已完成（Simulator / 自动化范围） | V11/V12、LocalAuthentication、非 active 遮挡、54-model manifest、关联逻辑删除、exclusive reset 与两次启动重置恢复 |
| 就诊摘要、PDF/CSV 与完整备份 | 已完成（Simulator / 自动化范围；Release 外流门禁待验证） | 预览优先的就诊摘要、Readable JSON v2、含附件 package、完整性审计、恢复/替换计划、inactive generation、journal 续做与 pointer-last 激活；Files 导入/导出只在 DEBUG/internal 暴露 |
| 库存与 lot ledger | 已移出 App 1.0 | 不是遗漏或发布待办；只有真实需求得到验证并重新立项后才会评估 |
| Batch 8A 构建期药品目录 | 候选实现已落地（Debug/Test；Release 关闭） | 33 个精确成分、31 个记录产品、44 个待监管核验 presentation、版本化完整性快照、来源/许可/digest validator 与逐条监管证据门禁 |
| Batch 8B 确定性方案分析 | 候选实现已落地（Debug/Test；Release 关闭） | 精确 ingredient ID、瞬态安全边界、逐组成项解释、来源卡/产品规则卡和规则版本；Release 精确依赖已批准的 8A 目录，不解析剂量或化验 |
| Batch 9 发布硬化 | 计划中 | Files 外流、真机、签名 RC、发行分类与内容批准等发布门禁 |

### 已闭环的当前能力

- 正式 onboarding：先说明本地存储、系统管理备份和当前尚未实现的隐私能力，再建立必需封存方案；开始日、提醒和 Countdown 可跳过，完成后可从“档案”再次进入相关设置；
- “今天”：基于 HRT 多周期事实显示当前周期日，以及从首次开始后经过的自然日（包括暂停日），并提供暂停/恢复入口；同时展示完整 Countdown、快速记录和按封存方案派生的执行台账，可记录已使用/跳过、追加纠错、稍后提醒并管理本地提醒；
- “旅程”：通过统一时间线回看 HRT 历程、化验、状态、执行、方案和终态 Countdown 事件；可新增结构化化验与状态记录、查看单项趋势、追加纠错或在关联影响复核后终态删除，并管理当前及历史目标日；
- “方案”：用 civil date 区分当前、未来和历史版本；方案组成可保存为草稿，经变更与历史关联影响核对后封存；Debug/Test 候选目录可按 33 个精确成分记录版本化 product snapshot，当前与历史封存版本可用 Batch 8B 的当前候选规则生成教育性讨论材料；
- “检查”：保留 legacy 入口兼容，V5 `LabSample` / `LabResult` 是不可变原始事实，V10 lifecycle leaf 是当前有效投影；
- “档案”：查看由同一份 54-model manifest 驱动的本机数据清单与外部边界，管理应用锁、关联删除和全部数据重置，整理就诊摘要并生成 PDF/CSV；Readable JSON v2、含附件完整备份和恢复/替换界面已完成 internal 验证，但对 Files 的入口在 Release 中保持隐藏，Legacy JSON v1 合并器继续隔离；
- 最近任务遮挡：scene 离开 active 时以无动画中性表面覆盖全部 App 内容；它不等于温和模式，也不承诺阻止 active 状态截图、录屏或清除系统备份；
- SwiftData 本地存储、真实旧库迁移、generation 恢复与 Recovery Mode，不要求注册账号；
- 1.0 采用系统管理备份：App 不主动上传或实时同步，iOS 可能按用户设置将 App 数据纳入系统备份；
- iPhone 与 iPad 原生 SwiftUI 界面，最低支持 iOS 17。

### 不再属于 App 1.0

库存与 lot ledger 已明确移出 App 1.0。App 1.0 继续使用 Batch 3 已实现的“封存方案 → 今日事项 → 中性设备本地提醒”，不要求用户维护批次、余量、开封日或有效期；库存不再是 App Store 发布阻塞项。若未来用户研究证明存在足够需求，将重新立项并建立新的产品与架构决策。

### 尚未实现或尚未闭环

尚未实现或尚未闭环的主要能力包括：

- HRT 任意历史周期的 append-only 纠错，以及是否需要让方案或提醒随暂停联动，仍需另立合同；当前暂停只改变历程状态，不改写方案、执行或提醒事实；
- 8A/8B 候选内容仍需真实人类内容复核、医疗内容复核、首发地区与医疗分析发行分类；门禁关闭前 Release 目录与方案分析均保持关闭；
- 离线资料的全局搜索、收藏和文章阅读器尚未立项为已实现能力；8B 当前只提供与封存方案关联的来源卡；
- 对外 Files 导入/导出的发行政策、第三方文件提供方失败/取消矩阵，以及真机数据保护与完整备份恢复；
- 真机通知、系统备份恢复、最低设备性能、完整辅助技术人工矩阵，以及签名 Archive、隐私/医疗分类、内容授权等发布门禁。

档案页的就诊摘要与 PDF/CSV 已是当前 App 能力；完整数据协议虽然已在 Simulator 和自动化边界内闭环，但 Files 导入/导出仍只在 DEBUG/internal 提供，不能称为正式发布能力。Legacy JSON v1 合并器也不是恢复真实资料的入口。

## 最近验证

2026-07-30 当前本地 Schema V12 Simulator / 自动化基线：

- 2026-07-30 Batch 8A/8B 最新定向目录、来源、严格 schema、快照完整性、确定性规则与 Release 合同合计 `54/54` 通过；候选范围为 33 个精确成分、31 个记录产品和 44 个 `candidateUnverified` presentation。候选目录为 candidate.2；盐酯使用稳定母体 ID，剂型与标签途径分离，Release 只接受逐条 `regulatoryVerified` 且绑定同辖区、同监管机构产品来源的 presentation；
- 2026-07-30 Batch 8B 真实当前与两个独立历史入口、关闭重进、内容不可用、目录检索和自定义回退 UI `7/7` 通过；同输入确定性、冻结停止顺序、逐层严格 JSON schema、33 个 ingredient profile 全覆盖、逐组成项解释、来源与产品规则分离、只要求实际显示的安全问题、未知/损坏/语义漂移快照 fail closed、固定无参数外链，以及 8B Release 对已批准 8A 版本、digest 与成分集合的精确依赖均有回归。这些工程证据不能替代真实人类内容与医疗复核；
- generic iOS Simulator 无签名 Debug build 与 Release Simulator build 均通过；
- 当前完整测试套件（单元、集成、多尺寸渲染与 UI）合计 `910/910` 通过，失败 `0`、跳过 `0`；其中单元/集成/渲染 `844/844`、真实 UI `66/66`。既有 V5 migration fixture 的低概率 WAL checkpoint 竞态已改为独立冻结副本，原始 main/WAL 字节哈希合同仍保留；
- Batch 7 回归覆盖就诊摘要范围与脱敏选择、仅含附件的化验披露、中文/emoji 单条长记录 PDF 分页、CSV 精确格式，以及在同一 read lease 内复核身份并生成最终 PDF/CSV/JSON/完整备份字节；Readable JSON v2 覆盖 54-record/9-control schema、未知字段与重复身份拒绝、大小与单模型 250,000 条上限；附件 package 覆盖与正式附件存储一致的 20 MiB 单文件、image/PDF 类型、每 owner 6 个/60 MiB 上限，以及路径、symlink、hardlink 和摘要审计；
- 恢复/替换回归另覆盖写 journal 前与 durable staging 后各一次隔离内存 V12 语义预检、冲突计划过期与乱序请求门禁、durable journal 后旧会话立即失效、来源状态变化拒绝、`activationCleanupPending` 及所有 durable 阶段的冷启动续做；generation pointer、migration journal、cleanup journal 与 restore journal 采用内容寻址的确定性原子 sibling，测试覆盖 pre-swap、post-swap、old-cleanup 冷重放和 digest 不匹配的外来条目保留，语义无效 canonical 会映射为各自的领域损坏错误。restore journal v1 覆盖 source-active partial target、target-active restart、合同篡改和迁移持久化失败重放。临时 package 使用带 `active / cleanupPending` 生命周期的持久化 ownership intent，当前会话的泛化重试不会删除仍在构建或仍由界面持有的 active package，显式丢弃会先持久化清理状态，崩溃遗留则在 ModelContainer 打开前精确回放。恢复 staging 的创建、写入、readback 与 exact-tree/root-digest 审计保持在同一次 no-follow 目录 FD lease 内；激活窗口把 App 自有目录与 Store/Files 普通文件规范化并设为只读，在 pointer 写入前后复核祖先及 Files root 的 identity/mode/mtime/ctime，以及常规文件的 inode、链接数、大小、mode、时间戳和流式 SHA-256 内容封印；旧 descriptor 的同 inode 内容改写、文件或目录 mode/ctime ABA 会拒绝激活并保持来源 pointer，退出窗口后精确恢复 `0700/0600`。清理在 quarantine 前冻结整棵已登记子树的 inode/type snapshot，并在 mutation 后及逐项 `unlinkat` 前复核；祖先、目标或子项 symlink、未知类型、验证后 foreign replacement 与新增条目都会零外部写入/删除失败，未登记 sibling 不会被扫描或删除。完整备份预览不建立 wrapper，确认时恰好建立一个；普通文件、目录和内部节点限额分离，2,000 附件形成的 4,004 节点压力 fixture 通过且临时 descriptor 峰值为 3。导出快照回归证明 `.withoutMapping` 取得的自有 FileWrapper 在来源 manifest 被同 inode 改写后仍保留原始 bytes，磁盘 package 与 ownership intent 在交给 UI 前已清理；边界测试覆盖 64 MiB 内容 bytes 上限及连续失败清理。真实 UI 覆盖就诊摘要生成/修改/重入、JSON v2 与完整备份预览、外流边界、取消、临时文件清理，以及确认导出时状态已变化则在打开 Files 前终止；
- Batch 6 回归覆盖 V10 → V11 → V12、新装与 legacy adoption、应用锁状态机和过期认证回调、最近任务遮挡、54-model manifest、完整性失败语义、五类关联删除的真实持久化重开、通知点击后等待解锁再路由、exclusive reset、首次与后续 journal 写盘失败、各阶段续做、清理失败、quarantine 路径与 symlink 防护、旧任务失效、全新 dataset 身份与 post-audit；真实 UI 另覆盖逐项删除取消/确认/重开，以及整库重置取消/确认/冷启动/再次重开；
- V10 回归覆盖新装、legacy adoption、V7 → V8、V8 → V9、V9 → V10、新 generation pointer 中断恢复、pointer 前附件树与文件保护审计、onboarding 准确步骤持久化、HRT 多周期与迁移原子性，以及趋势定向读取、分组/换算、父记录连续纠错、结果重排、时间线重排、并发、附件 stage、稳定附件身份、数据库回滚、rollback/finalize Recovery 和 mutation 后持久化重开；
- 当前 V12 Release-config 合同测试 `9/9` 通过；它包含一轮真实五年 worker 正确性回归，但不等同于当前 V12 的完整 20 样本性能 preflight；
- 上一轮 V10 完整 Release-config Simulator performance preflight `1/1` 通过，完成 1 次预热与 20 个正式样本；当前 V12 尚未重跑该门禁。历史结果为 `acceptance = not-evaluated`，只证明当时的 harness 与证据链可完整执行，不能称为当前数值性能、最低设备或真机门禁通过；
- 隐私清单已声明 App 容器文件元数据与用户明确选择文件元数据的 Required Reason API 用途，并通过 plist 语法检查；最终 Archive privacy report 仍属于发布门禁；
- 渲染矩阵覆盖 320×568、390×844、430×932、768×1024、844×390 横屏，以及 320×568 最大辅助字号场景；HRT 管理、化验趋势与父记录纠错/删除均有独立状态矩阵，Countdown 最大辅助字号页面另通过触控区域、元素说明、文字裁切与语义自动审计；
- 父记录的真实 UI 自动化目前覆盖一条化验“纠错 → 结果重排 → 完整变化复核 → 保存 → 影响预览 → 终态删除”主流程；状态记录纠错、结果增删、`nil` 与空字符串区分、过期页面重载、取消/重新进入和真实 Recovery 表面仍属于发布前人工设备矩阵，不以 repository 测试或静态渲染冒充完整 UI 覆盖；
- 自动渲染测试只验证冻结尺寸下能生成非空、高对比的画面；完整 VoiceOver、外接键盘、键盘遮挡、安全区和减少动态效果仍需要人工设备矩阵，不能由截图测试替代。
这些证据证明当前 V12 工作树在 Simulator 和自动化边界内通过，不代表 Batch 1 的整体完成门禁、真机或发布门禁已经通过。尚待整个 App 进入发布候选阶段后统一验证：真机应用锁和最近任务遮挡、文件保护与锁屏 I/O、系统备份与恢复、动态无网络、最低设备 Release 性能、完整 VoiceOver 和全状态人工矩阵。

## Roadmap

Batch 3 的今日执行与基础本地提醒由 ADR 0006 冻结，Countdown 生命周期与统一提醒由 ADR 0008 冻结，正式 onboarding 与 V8 采用策略由 ADR 0010 冻结，HRT 历程生命周期由 ADR 0011 冻结，化验趋势与父记录生命周期分别由 ADR 0012、0013 冻结，Batch 7 报告与完整数据协议由 ADR 0017 冻结。ADR 0009 已正式将库存从 App 1.0 后置；Batch 4 保留编号以维持既有文档和阶段引用稳定，不再构成 1.0 实现或发布门禁。ADR 已接受只表示合同已决定，不等于对应功能已经实现。

| 阶段 | 状态 | 目标 |
| --- | --- | --- |
| Batch 0 | 已完成 | 本地后端合同冻结 |
| Batch 1 | 本地实现完成；真机门禁延期 | 数据安全、迁移、恢复与性能证据底座 |
| Batch 2 | 已完成（Simulator / 自动化范围） | 时间事实与方案版本核心 |
| **Batch 3** | **已完成（Simulator / 自动化范围）** | 今日执行、Countdown 完整生命周期与统一设备本地提醒 |
| Batch 4 | 已移出 App 1.0；后置验证 | 库存与 lot ledger 仅在真实需求得到验证后重新立项 |
| **Batch 5** | **已完成（Simulator / 自动化范围）** | 化验、状态、附件与统一时间线 |
| 正式 onboarding | 已完成（Simulator / 自动化范围） | 根门禁、隐私说明、必需方案、可选提醒与 V8 安全采用 |
| HRT 历程生命周期 / Schema V9 | 已完成（Simulator / 自动化范围） | 暂停、恢复、多周期、Today 投影、统一时间线、温和模式与 V8 → V9 安全采用 |
| Batch 5 后续专项 / Schema V10 | 已完成（Simulator / 自动化范围） | 化验趋势、确定性同维单位换算、化验/状态父记录 append-only 纠错与终态删除 |
| **Batch 6** | **已完成（Simulator / 自动化范围）** | 应用锁、最近任务遮挡、全 App 数据清单、关联删除与全部重置 |
| **Batch 7** | **已完成（Simulator / 自动化范围；Release 外流门禁待 Batch 9）** | 就诊摘要、PDF/CSV、Readable JSON v2、含附件完整备份与安全恢复/替换 |
| Batch 8A | 候选实现已落地；Release 待真实人类内容复核 | 构建期药品目录、来源/许可/digest 门禁、版本化选择快照 |
| Batch 8B | 候选实现已落地；Release 待内容/医疗复核与发行分类 | 确定性摘要、停止分支、讨论卡、来源卡和规则版本 |
| Batch 9 | 计划中 | 发布硬化与真机门禁 |

## GitHub 与 App Store 状态

“源码可以提交到 GitHub”和“App 可以上架”是两件事：

- **GitHub 阶段快照**：许可证、AppIcon 来源、Batch 0 合同、Batch 1–3 工程阶段报告、Batch 5 的化验/状态/附件/统一时间线、Batch 3 Countdown、库存后置、正式 onboarding、HRT 生命周期、化验趋势、父记录生命周期、Batch 6 与 Batch 7 按模块形成阶段报告。内部工作日志、构建产物、Simulator 标识和本机路径不进入公开提交。阶段快照不是 App Release；
- **App Store**：当前不 ready。Batch 8A/8B 的候选工程实现已经落地，但正式内容仍需真实人类内容/医疗复核、首发地区与医疗分析发行分类；Batch 9 还要关闭 Files 外流、真机、签名 Release Candidate、发行主体、隐私声明和内容授权等门禁。库存不再是 1.0 发布前置条件；
- 任何 `git push`、TestFlight 上传或 App Store 提交都需要当次明确授权，不由本地构建或测试自动触发。

## 产品原则

- **本地优先**：个人记录由 App 在设备内处理；iOS 系统备份是由设备设置管理的独立边界；
- **温和克制**：不使用断签惩罚、排行榜或高压打卡；
- **忠实记录**：保留用户输入、发生时间和每次方案变化；
- **容易回看**：让今天、旅程、方案和检查彼此关联；
- **隐私如实表达**：只承诺已经实现并验证过的保护能力。

## 技术栈

- Swift 6
- SwiftUI
- SwiftData
- Observation
- XcodeGen 2.46.0
- iOS 17.0+
- iPhone 与 iPad

App 当前没有第三方运行时依赖，也没有广告或第三方分析 SDK。1.0 不由 App 发起网络请求；用户显式打开系统浏览器、Files 或分享面板属于可能离开 App/设备的独立边界，必须另行预览和提示。

App 1.0 不设置系统备份排除标记。记录保存在 App 私有容器中，不使用 CloudKit，也不由 App 主动上传或跨设备实时同步；iOS 可能按用户的系统设置将数据纳入 iCloud 或电脑备份。App 不保证某次备份已经发生或一定可以恢复，最终行为须在发布候选版本上完成真机验证。

## 本地运行

需要 macOS、Xcode，以及已经安装的 iOS Simulator Runtime。没有 Apple Developer 账号也可以在模拟器中运行。

```bash
brew install xcodegen
xcodegen generate --spec project.yml
open Unmanual.xcodeproj
```

在 Xcode 中选择 `Unmanual` scheme 和一个本地 iPhone 或 iPad 模拟器后运行。

无签名编译：

```bash
xcodebuild \
  -project Unmanual.xcodeproj \
  -scheme Unmanual \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

运行单元测试前，先查找一个可用模拟器的 UDID：

```bash
xcrun simctl list devices available
```

然后运行：

```bash
xcodebuild \
  -project Unmanual.xcodeproj \
  -scheme Unmanual \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath .build/DerivedData \
  test
```

本机空间有限时，请复用已有 Runtime；只删除自己为本项目新建的 Simulator 设备和已经核对过的项目专属构建产物。

## 项目结构

```text
Unmanual/
  App/             App 入口与主导航
  Data/            SwiftData 模型
  DesignSystem/    设计令牌与通用组件
  Domain/          与界面分离的业务事实和计算
  Features/        今天、旅程、方案、档案
  Resources/       本地化、隐私清单与 App 图标
UnmanualTests/     单元测试
UnmanualUITests/   UI 与可访问性回归测试
UnmanualPerformanceTests/  Release 性能 harness（默认不随普通测试运行）
docs/              产品、视觉与技术决策
project.yml        XcodeGen 工程定义
```

历史早期进度见 [Stage 0–2 开发快照](docs/progress/0001-stage-0-2-development-snapshot.md)；它不是当前状态事实源。产品范围见 [产品规划方案 1.0](docs/product/MTF不全书-App-产品规划方案-1.0.md)，本地后端合同见 [ADR 0002](docs/architecture/0002-batch-0-contract-freeze.md)，数据安全底座见 [ADR 0003](docs/architecture/0003-data-safety-foundation.md)，性能证据边界见 [ADR 0004](docs/architecture/0004-batch-1-performance-evidence-protocol.md)，时间与方案核心见 [ADR 0005](docs/architecture/0005-time-and-regimen-core.md)，今日执行与基础本地提醒见 [ADR 0006](docs/architecture/0006-today-execution-and-local-reminders.md)，化验、状态、附件与个人时间线见 [ADR 0007](docs/architecture/0007-labs-status-attachments-and-personal-timeline.md)，Countdown 生命周期与统一本地提醒见 [ADR 0008](docs/architecture/0008-countdown-lifecycle-and-unified-local-reminders.md)，库存后置决策见 [ADR 0009](docs/architecture/0009-inventory-deferred-from-app-1.0.md)，正式 onboarding 与 V8 采用策略见 [ADR 0010](docs/architecture/0010-formal-onboarding-and-v8-adoption.md)，HRT 历程生命周期见 [ADR 0011](docs/architecture/0011-hrt-journey-lifecycle-and-multiple-cycles.md)，化验趋势与确定性单位换算见 [ADR 0012](docs/architecture/0012-lab-trends-and-deterministic-unit-conversion.md)，父记录纠错与删除见 [ADR 0013](docs/architecture/0013-parent-record-correction-and-deletion.md)，应用锁与最近任务遮挡见 [ADR 0014](docs/architecture/0014-batch-6-app-lock-and-privacy-shield.md)，全 App 数据清单、关联删除与全部重置见 [ADR 0015](docs/architecture/0015-batch-6-data-inventory-deletion-and-reset.md)，Schema V11/V12 与 generation retention 见 [ADR 0016](docs/architecture/0016-schema-v11-and-generation-retention.md)，报告、便携数据与完整备份见 [ADR 0017](docs/architecture/0017-batch-7-reports-and-portable-data.md)，构建期药品目录见 [ADR 0018](docs/architecture/0018-batch-8a-medication-catalog.md)，确定性方案分析见 [ADR 0019](docs/architecture/0019-batch-8b-deterministic-regimen-analysis.md)，工程约束见 [AGENTS.md](AGENTS.md)。

## 参与贡献

欢迎提交问题、设计反馈、可访问性改进和代码贡献。开始前请先阅读 `AGENTS.md`、[许可证适用范围](LICENSE-SCOPE.md) 和 `docs/` 中已经接受的产品与技术决策。

请勿向 Issue、测试、截图或提交记录中加入真实姓名、药品记录、检查结果、照片或其他个人数据。

## 许可证

- 项目自有软件源码、测试和工程配置使用 [Mozilla Public License 2.0](LICENSE)；
- 项目权利人原创的 README、AGENTS 和 `docs/` 文字与图示使用 [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)，文档中的软件源码仍使用 MPL-2.0；
- `MTF不全书`、`Unmanual`、Logo、AppIcon 和其他来源标识不在开放许可内；
- 第三方医疗指南、论文、引文、图表、截图、数据和未来 catalog seed 只遵循各自的来源与授权，项目不会再许可自身不拥有的权利。

完整边界见 [LICENSE-SCOPE.md](LICENSE-SCOPE.md) 和 [TRADEMARKS.md](TRADEMARKS.md)；当前 AppIcon 的生成来源、文件哈希与证据边界见 [ASSET-PROVENANCE.md](ASSET-PROVENANCE.md)。许可证选定、来源归档和阶段快照都不构成 GitHub Release、TestFlight 或 App Store 发布授权。
