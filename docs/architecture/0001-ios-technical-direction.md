# 0001：iOS 首发技术方向

- 日期：2026-07-18
- 状态：已接受，用于初始化阶段
- 关联产品范围：[MTF不全书 App 产品规划方案 1.0](../product/MTF不全书-App-产品规划方案-1.0.md)
- 后续合同：[0002：Batch 0 本地后端合同冻结](0002-batch-0-contract-freeze.md)

## 决策

首发平台确定为 iOS，采用原生 Swift 与 SwiftUI。初始化阶段不引入第三方运行时依赖，先使用 Apple 平台能力验证核心闭环；只有系统能力无法可靠满足需求时，才通过单独决策引入依赖。

当前开发环境：

- Xcode 26.4；
- Swift 6.3；
- Git 主分支 `main`；
- 本地优先、离线可用；
- 最低部署版本确定为 iOS 17.0；最老覆盖 iPhone XR、iPhone XS 系列和 iPhone SE（第 2 代）。

本地化名称已经确定：

| 语言 | App Store 名称 | `CFBundleDisplayName` |
| --- | --- | --- |
| 中文 | `MTF不全书` | `不全书` |
| 英文 | `Mtfunmanual` | `Unmanual` |

工程通过本地化的 `InfoPlist.strings` 提供桌面名称；App Store Connect 分别维护中英文商店名称。

## 原生能力映射

| 产品需要 | 初始技术选择 |
| --- | --- |
| 界面与导航 | SwiftUI |
| 并发与状态 | Swift Concurrency、Observation |
| 本地数据 | SwiftData；当前切片已验证基础持久化、版本关联和重新启动读取，迁移仍需单独验证 |
| 本地通知 | UserNotifications |
| 应用锁 | LocalAuthentication |
| 敏感文件保护 | iOS Data Protection；需要额外加密时使用 CryptoKit |
| 日期、时区和单位 | Foundation、Calendar、Measurement |
| PDF 与预览 | PDFKit、系统分享面板 |
| CSV 和原始导出 | 原生 Swift 编码与文件导出 |
| 附件选择 | PhotosPicker、fileImporter |
| 辅助功能 | SwiftUI Accessibility、Dynamic Type、Reduce Motion |
| 确定性规则 | 独立纯 Swift 模块，规则与来源版本分离 |

## 数据与隐私方向

- 方案、化验、记录、库存和 Countdown 默认只保存在设备；
- 1.0 不要求账号，也不建立自有云端；
- 数据库与附件放在应用私有容器，设置合适的文件保护等级；
- 生物识别只负责解锁，不把认证结果当作加密密钥；
- 后台时遮挡敏感预览；
- 通知默认使用中性文本；
- 导出前生成完整预览，默认排除姓名、照片和非必要敏感记录；
- 不接入第三方分析、广告或包含敏感字段的崩溃日志。

## 业务架构方向

应用至少分为三层：

1. **Domain**：方案版本、提醒计划、日期、单位换算、库存和匹配规则；不依赖 SwiftUI。
2. **Data**：本地持久化、附件、迁移、导入与导出。
3. **App/UI**：今天、旅程、方案、档案和设置；单位换算与知识搜索作为档案附页。

医疗规则放在可独立测试的模块中。生成式模型不参与方案分析、风险分支、化验判断或任何医疗动作。

## 依赖政策

App 当前不引入第三方运行时依赖。开发阶段使用 XcodeGen 2.46.0 生成并提交 `Unmanual.xcodeproj`：它只读取仓库内的 `project.yml`，不进入 App 包、不处理用户数据，安装体积约 7.4 MB。以后每个新增依赖都必须说明：

- 解决的具体问题；
- Apple 原生能力为何不足；
- 维护状态和许可证；
- 对包体、隐私、离线能力和数据迁移的影响；
- 可替代方案和移除成本。

若 SwiftData 后续无法稳定满足复杂迁移、附件关系和可测试性要求，再评估 SQLite/GRDB 等替代方案；在出现证据之前不提前引入。

## 本机空间与模拟器纪律

开发机可用空间有限，测试必须控制模拟器和构建缓存占用：

- 优先复用已经安装的 iOS 17 或更新版本运行时，不为了单次检查重复下载运行时；
- 只创建验证矩阵确实需要的模拟器设备，并记录本项目新建设备的 UDID；
- 一轮项目冒烟测试完成后，关闭并删除本项目新建的模拟器设备；
- 清理时只处理已核对的本项目设备、DerivedData 和测试结果，不删除用户已有的共享模拟器；
- iOS Simulator Runtime 可能被其他项目共用，未经用户明确确认不卸载；
- 每次执行删除前先列出精确目标，删除后重新检查占用和剩余设备。

## 已确认与暂缓项

- Bundle Identifier 暂定为 `com.mtfbook.unmanual`；申请开发者账号后、首次上架前再次确认归属与可用性。
- 当前没有 Apple Developer 账号，不填写 `DEVELOPMENT_TEAM`，仅做模拟器无签名构建与测试。
- 工程同时支持 iPhone 与 iPad，最低 iOS 17.0。
- 1.0 当前采用本地 SwiftData；加密备份暂缓，先实现可预览、可选择字段的本地导出。
- 本地后端的时间、执行、库存、化验、导入、无网络和发行门禁以 ADR 0002 为准；它不改变本 ADR 的 iOS 17.0 基线。
