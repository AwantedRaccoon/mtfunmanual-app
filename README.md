# MTF不全书 App

一个面向中文 MTF 用户、本地优先的个人 HRT 记录与就诊准备工具。它保存事实、串起方案与经历，但不替用户作医疗决定。

> **当前状态：开发中，尚未发布。**
> 用户版本为 **1.0（build 1）**，最低支持 iOS 17，同时面向 iPhone 与 iPad。当前工程已推进至 Batch 8C；Batch 9 的真机、内容、法律与发行门禁仍未完成，因此还不是 App Store ready。

网站负责解释一般性问题；App 负责回答与个人经历有关的问题：我现在是什么方案、今天发生了什么、过去如何变化，以及就诊时需要带上哪些事实。

## 它解决什么

核心体验由四个入口组成：

- **Today**：把已封存方案展开为今天的事项，记录已使用、跳过与纠错，并管理设备本地提醒。
- **Journey**：记录 HRT 开始、暂停、恢复与多段经历，把化验、状态、附件、Countdown 和重要事件放回时间线上。
- **Regimen**：保留方案版本与变更历史，为就诊沟通提供可追溯上下文。
- **Archive**：查看数据清单、就诊摘要、导出/备份能力，以及候选的离线随身附录。

产品希望把“方案 → 今日计划 → 实际执行 → 化验/变化/事件 → 时间线/就诊摘要 → 新方案版本”连成一条可回看、可更正的本地记录链。

### 它不是什么

- 不是处方、在线问诊、AI 医疗聊天或个体化化验解读工具。
- 不推荐剂量、停药、换药或自行调药。
- 不是药品商城、社区、打卡排行榜、新闻流或网站 WebView 套壳。
- App 1.0 不包含库存管理、OCR、HealthKit、Apple Watch、复杂小组件或个人资料自动上传。

## 当前可验证的实现

以下“已实现”指源码、自动化测试、Simulator 与已经列明的人工渲染检查范围，不代表真机安全、医疗内容批准或正式发行通过。

### 本地数据与首次设置

- SwiftUI + SwiftData 原生架构，Swift 6 严格并发检查。
- 本地 generation、journal、pointer、迁移、恢复模式与有界读写。
- 首次设置包含隐私说明、方案封存，以及可选的 HRT 开始日、提醒和 Countdown。
- 数据保护 entitlement 已配置；真机锁屏行为与系统备份恢复仍属于 Batch 9 门禁。

### Today、方案与提醒

- 方案草稿、封存和版本历史。
- 四类计划 occurrence，以及“已使用 / 跳过”的事实记录。
- append-only 纠错和一次性 snooze。
- 统一的设备本地提醒；不依赖 APNs 或远程服务。

### Journey、化验与时间线

- HRT 开始、暂停、恢复和多周期记录。
- Countdown 的建立、修改、继续计时、完成、归档、删除和时间线投影。
- 结构化化验、状态记录和本机附件。
- 单项趋势与确定性的同维单位换算。
- 父记录纠错、影响预览和终态删除。

### 隐私与数据控制

- App Lock、最近任务遮挡、全数据清单、关联删除和全部重置。
- App 内就诊摘要、PDF/CSV、Readable JSON v2、含附件完整备份与恢复协议。
- Files 导入/导出当前仍是内部验证能力，Release 入口保持关闭。

### Batch 8 候选能力

这些能力已经进入工程与 Debug/Test 验证，但候选数据不会进入当前 Release 包：

- **8A 药品目录**：33 个精确成分、31 个记录产品、44 个待逐产品监管核验的 presentation。
- **8B 确定性方案分析**：按版本化规则生成教育性讨论材料、停止分支和来源卡；不读取化验值来推断方案，也不作处方审核。
- **8C 离线场景内容**：48 张摘要、45 个来源、53 个 anchor，支持搜索、分类、收藏、阅读器和五个场景入口。

8A、8B、8C 必须在真实人类内容/医疗复核、发行分类和适用地区决定完成后，才能考虑进入 Release。

## 隐私与医疗边界

- 个人数据面默认在本机处理，不要求账号。
- App 1.0 不发起运行时网络请求，不包含 WebView、CloudKit、APNs、远程配置、远程内容、遥测、崩溃上传或第三方运行时依赖。
- 用户主动打开固定来源链接时，会先看到边界提示，再交给系统浏览器。
- Files、系统分享面板和系统浏览器属于数据离开 App 的独立边界；离开后不再受 App 的本地保护控制。
- 持久化采用 `systemManaged`：App 不主动上传或实时同步，但 iOS 可能按用户的系统设置将 App 数据纳入 iCloud 或电脑系统备份；这不等于 CloudKit，也不保证某次备份或恢复一定成功。
- App Lock 和最近任务遮挡不是“无痕模式”，也不能替代设备密码、系统文件保护或真实设备验证。
- 医疗内容只用于记录、整理和确定性对照公开资料，不构成诊断、处方或医嘱。

## 开发路线

| 阶段 | 当前状态 |
| --- | --- |
| Batch 0 · 合同冻结 | 完成；冻结本地数据、时间、执行、化验、迁移、无网络与发布门禁 |
| Batch 1 · 本地后端 | 工程与 Simulator/自动化范围完成；真机文件保护、系统备份和最低设备门禁未关闭 |
| Batch 2 · 时间事实与方案版本核心 | Simulator/自动化范围完成 |
| Batch 3 · Today、Countdown、提醒 | Simulator/自动化范围完成 |
| Batch 4 · 库存 | **已移出 App 1.0**，不是当前待补功能 |
| Batch 5 · 化验、状态、附件、时间线 | Simulator/自动化范围完成 |
| 正式首次设置 · Schema V8 | Simulator/自动化范围完成 |
| Batch 6 · App Lock、遮挡、删除、重置 | Simulator/自动化范围完成；真机隐私门禁仍待验证 |
| Batch 7 · 报告与可移植数据 | 内部实现与自动化完成；Release Files 外流仍关闭 |
| Batch 8A · 药品目录 | 候选实现完成；Release 等人工复核与逐产品监管证据 |
| Batch 8B · 确定性方案分析 | 候选实现完成；Release 等医疗/内容复核与发行分类 |
| Batch 8C · 离线场景内容 | 工程、Simulator 和已列渲染范围完成；Release 候选内容仍关闭 |
| Batch 9 · 发布硬化 | 待完成 |

### Batch 9 还需要完成

- 将 Files/Share 正式出口、第三方文件 provider、取消/失败路径和大文件行为推进到发行门禁。
- 在真机验证文件保护、锁屏 I/O、App Lock、最近任务遮挡、通知、Focus/Scheduled Summary、DST/旅行和系统备份恢复。
- 完成最低支持设备与跨设备性能阈值；冻结正式 fixture。
- 对 8A、8B、8C 做真实人类内容、医疗、监管证据与分类复核，并决定首发地区。
- 完成动态无网络核验、隐私报告、法律/许可证/商标审查。
- 完成 VoiceOver、外接键盘、键盘遮挡、安全区、Reduce Motion 和完整设备/状态矩阵。
- 生成签名 Archive，经过 TestFlight、App Review 与 App Store 发布流程。

## 验证基线

截至 **2026-07-31**，Batch 8C 阶段的已记录证据包括：

- 内容生成器测试：9/9。
- 组合测试：988/988，其中 918 项 non-UI、70 项 UI。
- Release 合同测试：6/6；Release bundle 审计通过，三组候选内容保持排除。
- 性能 preflight：1/1，20 个正式样本完整；由于最低设备阈值和冻结 fixture 尚未确定，验收结论仍为 `not-evaluated`。

这些数字证明当前工程合同和测试范围，不证明真机、跨设备性能、医疗正确性或发布就绪。详细证据与限制见 [ADR 0020](docs/architecture/0020-batch-8c-offline-contextual-content.md)。

## 本地构建

### 环境

- Xcode 与可用的 iOS Simulator runtime
- [XcodeGen 2.46.0](https://github.com/yonaskolb/XcodeGen)

项目最低部署目标为 iOS 17.0，使用 SwiftUI、SwiftData 和 Swift 6；没有第三方运行时依赖。

### 生成并打开工程

```sh
brew install xcodegen
xcodegen generate --spec project.yml
open Unmanual.xcodeproj
```

在 Xcode 中选择 `Unmanual` scheme 和本地 Simulator 后运行。

### 无签名编译

```sh
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

### Simulator 测试

先找到可用设备的 UDID：

```sh
xcrun simctl list devices available
```

再运行：

```sh
xcodebuild \
  -project Unmanual.xcodeproj \
  -scheme Unmanual \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath .build/DerivedData \
  test
```

Simulator 测试不要加入 `CODE_SIGNING_ALLOWED=NO`。完整工程命令、性能 harness 和模拟器清理要求见 [AGENTS.md](AGENTS.md)。

## 仓库结构

```text
Unmanual/
  App/                       生命周期与根导航
  Data/                      SwiftData、迁移、存储、备份与恢复
  DesignSystem/              设计令牌与通用组件
  Domain/                    可独立测试的业务规则
  Export/                    PDF、CSV 与数据导出
  Features/                  Today、Journey、Regimen、Archive 等功能
  Resources/                 本地化、图标、隐私清单与内容状态
  System/                    系统能力适配
UnmanualTests/               单元、集成、迁移、合同与渲染测试
UnmanualUITests/             UI 回归
UnmanualPerformanceTests/    Release 性能证据 harness
Scripts/                     内容生成和 Release bundle 审计
docs/                        产品、架构、设计、内容来源与阶段记录
project.yml                  XcodeGen 工程事实源
Unmanual.xcodeproj/          已生成并提交的 Xcode 工程
```

## 关键文档

- [产品规划方案 1.0](docs/product/MTF不全书-App-产品规划方案-1.0.md)
- [ADR 0002：Batch 0 合同冻结](docs/architecture/0002-batch-0-contract-freeze.md)
- [ADR 0009：库存移出 App 1.0](docs/architecture/0009-inventory-deferred-from-app-1.0.md)
- [ADR 0017：报告与可移植数据](docs/architecture/0017-batch-7-reports-and-portable-data.md)
- [ADR 0018：药品目录](docs/architecture/0018-batch-8a-medication-catalog.md)
- [ADR 0019：确定性方案分析](docs/architecture/0019-batch-8b-deterministic-regimen-analysis.md)
- [ADR 0020：离线场景内容](docs/architecture/0020-batch-8c-offline-contextual-content.md)
- [工程与协作合同](AGENTS.md)
- [MTF不全书网站](https://mtfbook.com/)

## 参与贡献

开始修改前请先阅读 [AGENTS.md](AGENTS.md) 以及目标目录下更具体的合同。工程变更应保持业务规则与界面分离，医疗规则可独立测试、版本化和审计。

请勿提交密钥、构建产物、生成报告、依赖目录、真实医疗数据、真实问卷样本或其他敏感个人资料。新增依赖、网络能力、医疗规则或正式内容前，必须先完成对应的技术与隐私决策。

## 许可证与品牌

- 源码、测试、脚本和工程配置按 [MPL-2.0](LICENSE) 提供。
- 项目原创文档，以及 [LICENSE-SCOPE.md](LICENSE-SCOPE.md) 明确列出的原创或改编内容，按 CC BY-SA 4.0 提供。
- “MTF不全书”、`mtfbook.com`、相关标识与 App Icon 不随上述开源许可授权；详见 [TRADEMARKS.md](TRADEMARKS.md)。
- 第三方医疗材料、外部来源内容和未明确列入许可范围的内部工作材料不因进入仓库而改变原许可；详见 [LICENSE-SCOPE.md](LICENSE-SCOPE.md) 与 [ASSET-PROVENANCE.md](ASSET-PROVENANCE.md)。
