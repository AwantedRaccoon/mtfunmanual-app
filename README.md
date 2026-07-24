# MTF不全书 App / Unmanual

一个面向中文 MTF 用户、计划以非营利和开源方式建设的 iOS 项目。

Unmanual 是一个轻量、私密、可以长期使用的个人 HRT 记录工具：帮助用户记住今天、回看自己的旅程、保存方案变化，并在需要时整理自己的记录。

网站负责解释“这件事通常是什么”，App 负责帮助用户看见“这件事在我身上是怎样发生的”。完整知识内容仍由 [mtfbook.com](https://mtfbook.com/) 提供。

> **当前状态（2026-07-24）**
>
> - App 版本：`1.0`（build `1`）；`V2.5` 只是内部视觉迭代名。
> - 工程阶段：Batch 0 已完成；Batch 1 的本地实现与 Simulator 自动化已完成，但整体完成门禁尚未关闭；Batch 2 已在 Simulator 与自动化范围内完成；Batch 3 的今日执行与本地提醒模块已实现；Batch 5 的化验、状态、附件与统一时间线已在 Simulator 与自动化范围内完成。Batch 4 尚未开始。
> - 当前位置：Batch 5 已完成合同冻结、本地实现、四轮独立完整性审查与最终回归；最新 reviewer 结论为 `PASS`，P0–P3 均为 0。真机文件保护、系统备份恢复、最低设备性能与完整辅助技术人工矩阵仍保留到发布候选阶段。
> - GitHub 状态：Stage 0–3 与 Batch 5 阶段快照已进入 `origin/main`；它不是 GitHub Release。后续工作仍先提交并推送到 `chi-work`，只在维护者当次明确批准后合并到 `main`。
> - 发布状态：尚未达到 App Store release-ready，也尚未开始发布前真机测试。

## 我们在哪里

目前落地的是一套可迁移、可恢复、可审计的本地数据底座，以及稳定的时间事实、方案版本、今日执行、本地提醒、化验、状态、附件与统一个人时间线。用户可以封存个人方案、查看确定性派生的当日计划、记录已使用或跳过、追加纠错、为计划开启中性内容的设备本地提醒，并在本机保存化验与状态记录。

五个已启动阶段的当前进展是：

- **Batch 0 — 合同冻结**：确认 App 1.0、iOS 17+、本地优先、无 App 主动联网、`.systemManaged` 系统备份边界，以及时间、执行、库存、化验和数据谱系的跨模块合同；
- **Batch 1 — 数据安全底座**：实现 V1 → V2 bridge、generation copy/journal/pointer、幂等 backfill、revision/digest、Recovery Mode、读写 actor、有界查询和性能证据 harness；代码与 Simulator 自动化已完成，真机文件保护、系统备份恢复和最低设备性能仍是发布门禁；
- **Batch 2 — 时间与方案版本核心**：实现 additive Schema V3、civil date、historical timestamp、草稿/封存方案、组成项与计划数据、当前/未来/历史解析、变更校样和历史记录关联。
- **Batch 3 — 今日执行与本地提醒（部分完成）**：实现 additive Schema V4、四类确定性 occurrence、append-only 执行事实与纠错、一次 snooze、提醒偏好、覆盖投影和 UserNotifications 本地调度；Countdown 完整状态机不在本模块范围内。
- **Batch 5 — 化验、状态、附件与统一时间线**：实现 additive Schema V5、结构化化验样本与结果、可版本化状态指标、本机私有附件存储、旧化验幂等回填，以及跨化验、状态、执行与方案的有界统一时间线；未加入 App 主动联网、云同步或第三方运行时依赖。

### Batch 3 本次阶段实现

阶段提交 `7ceb86a` 完成的是“今日执行 + 设备本地提醒”闭环与对应安全加固，不包含 Countdown 完整状态机。

- **确定性计划派生**：按 sealed 方案生成 daily-times、weekly、every-N-days 和 one-off occurrence；统一 canonical key、civil date/time、方案半开区间、fixed/floating 时区、DST gap/overlap 和 fail-closed 容量上限。
- **Append-only 执行事实**：可记录“已使用”或“本次跳过”；未操作不制造事实，修改通过追加 correction 完成。`operationID` + canonical digest 保证幂等，冲突 replay 零写入失败，事实、revision、receipt 与 ledger 同事务可审计。
- **时间与方案关系保护**：执行时保存完整历史时间与计划快照；按实际当地日期解析方案关联，歧义保留可见复核项。封存后续方案不得让既有执行或 snooze 事实变成孤儿。
- **本地提醒意图与调和**：用户先看中性预览再主动申请系统权限；提醒偏好与方案分离，snooze 最长 24 小时。调度使用 14 个当地日窗口和 60 条保守预算，先保障每条启用规则的下一项，并保留非本 App 通知。
- **并发、系统时间与 Recovery**：调和采用单调请求序号和串行队列，旧请求不得覆盖新结果。App ready、回到前台、换日、显著时间变化和时区变化都会重读 Today 并调和提醒。Recovery Mode 会使在途工作失效，且只清理 `unmanual.exec.v1.` 前缀的本 App request。
- **数据完整性加固**：Schema V4 backfill 不创造执行事实，也不默认开启提醒。Canonical 时间编码在微秒精度上可失败检查，拒绝 NaN、无穷和超出 `Int64` 范围的时间；关系 validator 检查 occurrence、方案、receipt、event、override 与 coverage 之间的一致性。
- **可用性与辅助功能**：Today 台账覆盖 loading、error、empty、review、saving 和 recorded 状态；动作防重入，纠错与提醒授权 sheet 可滚动且主操作在窄屏与大字号下可达。辅助文字改用通过 WCAG AA 的语义颜色令牌。

### Batch 5 本次阶段实现

本次进入 `main` 的提交日志：

- `2e18332` — `docs: summarize Batch 3 implementation`：补齐 Batch 3 已实现范围与未完成边界；
- `2993027` — `feat: add labs status attachments and timeline`：落地 Schema V5、化验、状态、附件与统一个人时间线；
- `d342ee7` — `feat: harden labs status attachments and timeline`：闭环附件事务、Recovery、预览 lease、时间线并发与 V4 → V5 中断迁移。

- **结构化化验**：`LabDefinition`、`LabSample` 与 `LabResult` 分离；保留用户原始名称、代码、数值、单位、参考范围和上下文，同时使用独立规范化值支持确定性排序与验证。旧化验按稳定映射幂等回填，不改写旧事实。
- **状态记录**：指标定义、观察值、历史时间和附件元数据同一事务提交；新增指标与首次观察不会留下半成品。指标可以归档并释放活跃槽位，既有观察的历史快照继续可读。
- **私有附件**：附件保存在 App 私有 Application Support 目录，文件名使用不含原始名称的 opaque 标识；化验、状态与普通旅程记录都通过同一 generation 级 mutation service 提交附件。导入采用先写 journal、再暂存、再原子移动、最后提交数据库的恢复协议，并拒绝符号链接逃逸；跨 `await` 的事务由全局 mutation lease 串行化。Release 不暴露 Files 导入入口。
- **统一个人时间线**：化验、状态、执行与方案事件投影到统一条目；有明确时刻的事实按 instant 排序，无时刻的 civil-date 事实进入独立日期通道。查询按来源有界抓取、稳定游标分页，并保持同一时刻条目不丢失。
- **入口与回看**：旅程页可以新增化验与状态、查看附件和归档指标；Today 的最近化验来自 V5 canonical sample，并可直接打开同一条时间线详情。
- **完整性与恢复**：启动时恢复未完成附件 journal 并审计活动附件；缺失、越界或校验失败会进入 Recovery Mode，不把损坏状态伪装成正常启动。

## 当前实现

- “今天”：HRT 天数、基础 Countdown、快速记录，以及按封存方案派生的执行台账；可记录已使用/跳过、追加纠错、稍后提醒并管理本地提醒；
- “旅程”：通过统一时间线回看化验、状态、执行和方案事件，可新增结构化化验与状态记录；
- “方案”：用 civil date 区分当前、未来和历史版本；方案组成可保存为草稿，经变更与历史关联影响核对后封存；
- “检查”：保留 legacy 入口兼容，同时由 V5 `LabSample` / `LabResult` 作为新的 canonical 化验事实；
- “档案”：查看本机记录概况；当前实现只在 DEBUG 暴露 JSON v1 导入/导出原型，它尚不是完整或安全恢复协议；
- SwiftData 本地存储、真实旧库迁移、generation 恢复与 Recovery Mode，不要求注册账号；
- 1.0 采用系统管理备份：App 不主动上传或实时同步，iOS 可能按用户设置将 App 数据纳入系统备份；
- iPhone 与 iPad 原生 SwiftUI 界面，最低支持 iOS 17。

尚未实现的主要能力包括：Countdown 完整状态机及其提醒、库存与 lot ledger、应用锁、最近任务遮挡、删除/重置、Readable JSON v2、安全恢复、PDF/CSV/完整备份、正式药品目录、公共内容包和确定性分析。README 不把这些能力描述成已经完成。

## 最近验证

2026-07-24 的最近一次 Simulator / 自动化基线：

- generic iOS Simulator 无签名 Debug build 通过；
- Release Simulator build 通过；
- 单元、集成、渲染与 UI 测试合计 `327/327` 通过，其中普通测试 `308/308`、UI 测试 `19/19`；
- 当前分支的 V5 Release 合同测试 `9/9` 通过，其中包含一轮真实五年 worker 正确性回归；
- 当前分支的 Release-config Simulator performance preflight `1/1` 通过，完成 1 次预热与 20 个正式样本，测试体 291.580 秒、测试阶段 293.975 秒；该结果只验证 harness 可完整执行，`acceptance = not-evaluated`，数值阈值与跨设备冻结 fixture 仍未确定；
- 隐私清单已声明 App 容器文件元数据与用户明确选择文件元数据的 Required Reason API 用途，并通过 plist 语法检查；最终 Archive privacy report 仍属于发布门禁；
- 渲染矩阵覆盖 320×568、390×844、430×932、768×1024、844×390 横屏，以及 320×568 最大辅助字号场景；
- 自动渲染测试只验证冻结尺寸下能生成非空、高对比的画面；完整 VoiceOver、外接键盘、键盘遮挡、安全区和减少动态效果仍需要人工设备矩阵，不能由截图测试替代。

这些证据证明当前代码在 Simulator 和自动化边界内通过了既定基线，不代表 Batch 1 的整体完成门禁、真机或发布门禁已经通过。尚待整个 App 进入发布候选阶段后统一验证：真机文件保护与锁屏 I/O、系统备份与恢复、动态无网络、最低设备 Release 性能、完整 VoiceOver 和全状态人工矩阵。

## Roadmap

Batch 3 的今日执行与本地提醒由 ADR 0006 冻结；其余项目在对应 ADR 接受前仍是路线图，不是已经实现的工程事实。

| 阶段 | 状态 | 目标 |
| --- | --- | --- |
| Batch 0 | 已完成 | 本地后端合同冻结 |
| Batch 1 | 本地实现完成；真机门禁延期 | 数据安全、迁移、恢复与性能证据底座 |
| Batch 2 | 已完成（Simulator / 自动化范围） | 时间事实与方案版本核心 |
| **Batch 3** | **部分完成** | 今日执行与本地提醒已实现；Countdown 完整状态机待办 |
| Batch 4 | 计划中 | 库存闭环 |
| **Batch 5** | **已完成（Simulator / 自动化范围）** | 化验、状态、附件与统一时间线 |
| Batch 6 | 计划中 | 隐私与数据控制 |
| Batch 7 | 计划中 | 报告与完整备份 |
| Batch 8A | 计划中 | 构建期公共内容包 |
| Batch 8B | 计划中 | 确定性分析 |
| Batch 9 | 计划中 | 发布硬化与真机门禁 |

## GitHub 与 App Store 状态

“源码可以提交到 GitHub”和“App 可以上架”是两件事：

- **GitHub 阶段快照**：许可证、AppIcon 来源、Batch 0 合同、Batch 1–3 工程阶段报告以及 Batch 5 的化验、状态、附件与统一时间线已经进入 `origin/main`。内部工作日志、构建产物、Simulator 标识和本机路径不进入公开提交。阶段快照不是 App Release；
- **App Store**：当前不 ready。除 Batch 3 剩余 Countdown 与 Batch 4、6–9 的产品能力外，仍需完成真机、签名 Release Candidate、发行主体/地区、隐私与医疗分类、内容授权等发布门禁；
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

当前公开进度见 [Stage 0–2 开发快照](docs/progress/0001-stage-0-2-development-snapshot.md)。产品范围见 [产品规划方案 1.0](docs/product/MTF不全书-App-产品规划方案-1.0.md)，本地后端合同见 [ADR 0002](docs/architecture/0002-batch-0-contract-freeze.md)，数据安全底座见 [ADR 0003](docs/architecture/0003-data-safety-foundation.md)，性能证据边界见 [ADR 0004](docs/architecture/0004-batch-1-performance-evidence-protocol.md)，时间与方案核心见 [ADR 0005](docs/architecture/0005-time-and-regimen-core.md)，今日执行与本地提醒见 [ADR 0006](docs/architecture/0006-today-execution-and-local-reminders.md)，化验、状态、附件与个人时间线见 [ADR 0007](docs/architecture/0007-labs-status-attachments-and-personal-timeline.md)，工程约束见 [AGENTS.md](AGENTS.md)。

## 参与贡献

欢迎提交问题、设计反馈、可访问性改进和代码贡献。开始前请先阅读 `AGENTS.md`、[许可证适用范围](LICENSE-SCOPE.md) 和 `docs/` 中已经接受的产品与技术决策。

请勿向 Issue、测试、截图或提交记录中加入真实姓名、药品记录、检查结果、照片或其他个人数据。

## 许可证

- 项目自有软件源码、测试和工程配置使用 [Mozilla Public License 2.0](LICENSE)；
- 项目权利人原创的 README、AGENTS 和 `docs/` 文字与图示使用 [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)，文档中的软件源码仍使用 MPL-2.0；
- `MTF不全书`、`Unmanual`、Logo、AppIcon 和其他来源标识不在开放许可内；
- 第三方医疗指南、论文、引文、图表、截图、数据和未来 catalog seed 只遵循各自的来源与授权，项目不会再许可自身不拥有的权利。

完整边界见 [LICENSE-SCOPE.md](LICENSE-SCOPE.md) 和 [TRADEMARKS.md](TRADEMARKS.md)；当前 AppIcon 的生成来源、文件哈希与证据边界见 [ASSET-PROVENANCE.md](ASSET-PROVENANCE.md)。许可证选定、来源归档和阶段快照都不构成 GitHub Release、TestFlight 或 App Store 发布授权。
