# MTF不全书 App / Unmanual

一个面向中文 MTF 用户的非营利、开源 iOS 项目。

Unmanual 不是网站套壳，也不是处方或诊断工具。它希望成为一个轻量、私密、可以长期使用的个人 HRT 记录工具：帮助用户记住今天、回看自己的旅程、保存方案变化，并在需要时整理自己的原始记录。

网站负责解释“这件事通常是什么”，App 负责帮助用户看见“这件事在我身上是怎样发生的”。完整知识内容仍由 [mtfbook.com](https://mtfbook.com/) 提供。

> 当前处于早期开发阶段，尚未上架 App Store，也不建议用于保存唯一一份重要医疗记录。

## 当前实现

- “今天”：HRT 天数、一个自定义 Countdown、快速记录入口；
- “旅程”：按真实日期回看记录，并添加此刻发生的事件；
- “方案”：查看当前方案和历史版本，添加、编辑药物；
- “检查”：保存并展示性激素相关原始检查项目，不自动判断正常或异常；
- “档案”：查看本机记录概况，以及就诊摘要、原始数据导出和隐私说明的结构预览；
- SwiftData 本地存储，不要求注册账号；
- iPhone 与 iPad 原生 SwiftUI 界面，最低支持 iOS 17。

仍在规划或开发中的能力包括：用药提醒、库存、完整 PDF/CSV 导出、应用锁、敏感预览遮挡、可靠的数据迁移、完整药品资料来源和经过审计的方案分析规则。README 不把这些能力描述成已经完成。

## 产品原则

- **本地优先**：医疗、身份与记录数据默认留在设备上；
- **温和克制**：不使用断签惩罚、排行榜或高压打卡；
- **保存事实**：记录用户输入，不替用户决定方案、剂量或停药；
- **来源清楚**：医疗解释必须标明来源、版本、适用边界与不确定性；
- **隐私如实表达**：只承诺已经实现并验证过的保护能力。

## 医疗边界

本项目仅用于个人记录与健康信息整理，不构成医疗建议、处方、诊断证明或医生签署的病历。

项目不会提供具体剂量推荐、购买渠道、注射教学、自行调药方法或个体化化验解读。有关 HRT、药物副作用、化验结果和身体不适的问题，应交由具备资质的医生或药师处理；急性危险情况应立即联系当地急救服务。

## 技术栈

- Swift 6
- SwiftUI
- SwiftData
- Observation
- XcodeGen 2.46.0
- iOS 17.0+
- iPhone 与 iPad

App 当前没有第三方运行时依赖，也没有广告或第三方分析 SDK。

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
  CODE_SIGNING_ALLOWED=NO \
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
docs/              产品、视觉与技术决策
project.yml        XcodeGen 工程定义
```

产品范围见 [产品规划方案 1.0](docs/product/MTF不全书-App-产品规划方案-1.0.md)，工程约束见 [AGENTS.md](AGENTS.md)。

## 参与贡献

欢迎提交问题、设计反馈、可访问性改进和代码贡献。开始前请先阅读 `AGENTS.md` 和 `docs/` 中已经接受的产品与技术决策。

涉及医疗内容的变更必须提供可访问的权威来源、版本或发布日期、查阅日期和适用人群。请勿向 Issue、测试、截图或提交记录中加入真实姓名、处方、化验单、照片或其他个人医疗数据。

## 许可状态

项目按非营利开源方向建设，但正式开源许可证尚未确定。在仓库加入 `LICENSE` 之前，公开源代码本身不自动授予复制、修改或再分发许可。许可证确定后会在这里同步说明。
