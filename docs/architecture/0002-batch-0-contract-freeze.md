# 0002：Batch 0 本地后端合同冻结

- 日期：2026-07-21
- 状态：已接受
- 适用版本：App 1.0
- 关联产品范围：[MTF不全书 App 产品规划方案 1.0](../product/MTF不全书-App-产品规划方案-1.0.md)
- 前置决策：[0001：iOS 首发技术方向](0001-ios-technical-direction.md)

## 目的

在创建新的持久化模型、迁移、提醒、库存、附件、报告或公共内容链路之前，先冻结跨模块必须共享的语义和发行门禁。本 ADR 只确定合同，不把尚未完成的迁移、文件保护、App Review、许可证或真实设备验证描述成已经实现。

本 ADR 是仓库内本地后端合同的权威来源。`foragent/` 中的调查稿、实现方案和副本只用于交接；与本 ADR、产品规划、根 `AGENTS.md` 或用户当前指令冲突时，不具有更高优先级。

## 事实层级

本文使用两个状态：

- **已接受**：后续实现必须遵守；改变时需要新 ADR。
- **未决门禁**：当前没有足够授权或证据，明确记录负责人、阻塞范围和最迟解决批次；不得猜测为已确认。

## 已接受决策

### 1. 版本与平台

- App 首发 marketing version 为 `1.0`。当前 build number 是 `1`，以后随构建递增，不属于永久产品合同。
- `V2.5` 只是前端设计迭代名，可以留在设计文档、内部类型和文件名中，不得作为用户可见 App 版本、页面眉题、状态或 VoiceOver 文案。
- 最低部署版本继续为 iOS/iPadOS 17.0，同时支持 iPhone 与 iPad。`project.yml` 是工程配置真相，不在 Batch 0 升至 iOS 18。
- iOS 18 的复合 `#Unique`、`#Index`、SwiftData History 或 `ModelContainer.erase()` 可以在未来重新评估，但不能成为 1.0 数据正确性的前提。
- 升至 iOS 18 会移除部分当前覆盖的 iPad，必须由产品负责人明确接受设备影响并另立 ADR，不能以“设备列表完全相同”为理由静默升级。

### 2. 数据面与运行时网络

1.0 采用三个严格分离的数据面：

1. **本机私有数据面**：用户记录、方案、执行、库存、化验、附件、偏好和报告状态以本机为权威；无账号也能完整使用核心功能。
2. **构建期公共内容面**：药品目录、知识卡、来源和规则状态在构建期固定进 App bundle，只随 App 版本更新。
3. **未来同步面**：不属于 1.0，不创建生产空壳；若未来启动，必须另立安全、法律和 E2EE ADR。

“无运行时网络请求”的精确定义为：

- App 1.0 不包含由 App 编写或控制的出站网络请求，不引入网络客户端、WebView、CloudKit、APNs、远程配置、远程内容、账号、同步、遥测或崩溃上传 SDK。
- 本地通知使用 `UserNotifications`，不使用 APNs，也不把通知投递当作执行事实。
- App Store 安装/更新不属于 App 自己的请求。
- 用户显式打开系统浏览器、Files picker 或分享面板属于系统中介的数据外流，不得笼统描述为“不会联网”或“数据不会离开设备”。
- 打开外部来源前显示目标域和离开 App 提示；URL 不携带个人记录、稳定用户/设备 ID、搜索词或可推断具体记录上下文。
- Files 和分享必须先展示完整内容预览与敏感字段范围。
- 构建期 CI 可以取得公共内容，但制品必须锁定版本并经过来源、许可证和完整性校验；运行时不下载更新。

发行前通过 Release 源码、链接框架和 entitlement 静态检查，以及真机 App Privacy Report 或受控代理观察验证该合同。当前静态源码未发现网络实现，不等于动态验证已经完成。

### 3. iCloud、Files 与系统备份

- 禁用 SwiftData CloudKit、CKSyncEngine、App 管理的 iCloud Documents/ubiquity container，以及把个人健康数据自动写入 iCloud 的路径。
- 当前 `fileExporter` / `fileImporter` JSON 流程是开发期 legacy 原型，不是已获准发布的安全备份。
- Apple 对个人健康信息的 iCloud 限制与 Files provider 可能包含 iCloud Drive 之间存在发行门禁。在取得适用于本项目的 App Review/法律结论，或能够可靠限制不允许的 provider 前，不得把含个人健康信息的 JSON、package、CSV、PDF 或恢复文件描述成 Release 完成能力。
- 不能自行假定“用户主动选择”或“文件已加密”构成豁免；导入与导出都在同一门禁范围内。
- 产品负责人已于 2026-07-21 确认 App 1.0 采用 `.systemManaged`：记录保存在 App 私有容器中，不设置 `isExcludedFromBackup = true`，允许 iOS 按用户的系统设置把 App 数据纳入 iCloud 或电脑备份。该选择不启用 CloudKit、App 管理的 iCloud 容器、主动上传或跨设备实时同步。
- `.systemManaged` 只表示 App 不主动排除系统备份，不保证某次备份已经发生、一定成功或一定可以恢复。最终签名 RC 的实际纳入与恢复行为仍须按发布真机清单验证；用户文案必须明确区分本地存储、App 主动联网和系统备份。
- 该决定遵循 Apple 对难以重新创建的用户数据不应作为可丢弃缓存排除的指导；若未来改为 `.excluded`，必须新立 ADR，先提供经过发行评审的恢复路径，并明确 Finder、换机和设备丢失后果。[Apple：Optimizing Your App’s Data for iCloud Backup](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup)

### 4. 历史时间语义

领域层区分两类值，不继续用裸 `Date` 表达所有含义：

**`CivilDateFact`**

- 表示公历 `YYYY-MM-DD`；没有 instant，也没有跨时区换算语义。
- HRT 开始/暂停/恢复日、Countdown 目标日、方案生效/结束日等日期型事实使用该语义。
- 设备旅行或更改时区不会重算既有日期。

**`HistoricalTimestamp`**

- 保存 UTC instant、原始 local date、local time、IANA time-zone ID、事件发生时 UTC offset、精度和 provenance。
- 执行、旅程、采样等时间型事实使用该语义。
- 不存在的 DST 本地时间不得由 Foundation 静默归一；重复时间必须记录实际 offset。
- legacy 数据缺少时区时标记 `migrationAssumed` provenance，不能伪装成已知事实。

历史方案关联使用记录保存的 local date 与 sealed 方案半开区间 `[startLocalDate, endLocalDate)`。不得使用设备当前时区重新解释历史。若候选为 0 个或多个，关联保持空并产生可见核对项；用户修正需保存 provenance。

时间线中有 instant 的事实按 `instant → kind rank → stable ID` 排序。日期型事实不得伪造午夜 instant；在同一日期中使用独立、稳定且有测试的顺序。

### 5. 计划 occurrence、执行事实与幂等

- `occurrenceKey` 是计划槽位身份，不是 `AdministrationEvent` 的唯一键。初始事实和所有纠错事件共享同一个 occurrence key。
- occurrence key 使用冻结的 locale-neutral ASCII 编码，由不可变 schedule rule ID、schedule revision 和 civil occurrence 组成；禁止使用本地化日期字符串或 `Date.description`。
- 手工补录使用独立的 adhoc occurrence identity，不能伪造来自计划的 key。
- `AdministrationEvent` 是 append-only 事实；`taken` 和 `skipped` 是状态，未记录表示没有事件；snooze 属于 `ReminderOverride`。
- 纠错通过 `supersedesEventID`，必须属于同一 occurrence，链无环，每个事件最多一个直接 successor，每个 occurrence 只有一个有效 leaf。
- 纠错命令携带预期 leaf 身份/修订；过期命令拒绝并零写入。
- 每次用户意图或通知回调有稳定 `operationID`。相同 operationID 与相同 command digest 返回既有结果；相同 operationID 与不同 digest 拒绝并零写入。
- occurrence state 或 operation receipt 可以作为可重建的实现投影；事件链才是执行事实真相。具体 SwiftData 唯一字段和索引属于 Batch 1 存储设计，不在本 ADR 锁死。
- taken/skip/纠错与库存 consume/reversal 副作用必须处于一个事务；任一步失败则全部回滚。

### 6. 库存事实与 lot 分配

- 库存功能保持用户自愿启用；执行事实不依赖库存功能成功。
- 自动扣减只在存在一条明确、可执行且单位兼容的 `ConsumptionRule` 时发生；禁止从药名、剂型或目录资料猜测数量。
- lot 分配策略必须显式且版本化。允许 `manual` 和确定性的 `fefoV1` 等策略，但默认策略由产品决定，本 ADR 不代选。
- 自动策略是库存估算，不是“用户实际用了某一盒”的医疗事实。ledger 必须记录实际分配的 lot 和 policy version；改变策略只影响未来事务。
- 过期/未知有效期、手选 lot、跨 lot 分摊和稳定 tie-break 必须由对应 policy spec 完整定义并测试。
- 库存不足、规则歧义、单位/换算版本不兼容、只剩不可用 lot 或投影不一致时：仍保存执行事实，库存 ledger 零写入，持久化并显示 reconciliation issue；不得静默猜测或部分扣减。
- reversal 精确引用原 consume；同一 consume 最多被反转一次；余额缓存必须能从 ledger 重建。

### 7. 化验 sample、result 与项目身份

- `LabSample.id` 表示一次真实采样或报告，使用稳定 ID；同一天允许多个 sample，日期不能充当 sample 身份。
- `LabResult.id` 是每条结果的稳定身份。不得因同日、同名称或同 item code 覆盖既有结果。
- 内置 analyte 使用公共内容包中的稳定 ID；用户自定义项目使用数据集内稳定 ID。显示名、大小写、空格和可编辑 code 都不是身份。
- Result 保存项目身份关联以及名称/code 快照、原始值、原始单位、原始参考范围和必要上下文；换算不能覆盖原始事实。
- 同一 sample 可能存在重复测定、不同 assay、specimen 或 variant。本 ADR 不强制 `sample + item` 唯一；若具体录入流程需要单值限制，必须将 variant 纳入身份并由 Repository 验证，且不得丢弃原报告事实。
- legacy 六项仅通过版本化 alias 映射；无法确定时保守创建自定义项目或迁移核对项，不凭显示名猜测合并。

### 8. dataset、revision、digest 与导入冲突

- `datasetID` 表示数据谱系，不是账号、设备标识或用户身份。
- `localRevision` 仅在同一 dataset 内单调且可比较；它不是因果时钟，也不自动决定冲突胜者。
- 同一成功语义事务中的相关变化共享一次 revision；失败后允许存在未使用间隙，但已提交 revision 不复用。
- 空设备完整恢复或用户明确确认的整库替换可以采用备份 dataset；不同 dataset 合并保留本机 dataset，并为接受的外部变化分配本机 revision。
- record digest 只用于完整性和冲突检测，不是签名或真实性证明。算法与 canonicalization 必须带版本，排除运行时/导出元数据，并在实现前提供跨 locale、时区和进程稳定的 golden vectors。
- 禁止把任意 `JSONEncoder` 输出当作长期 canonical bytes。具体 digest v1 编码规范属于 Batch 1 的可测试 spec，在完成测试向量前不得称为已冻结实现。
- 同 dataset、同 ID、同 revision、同 digest 才是相同记录；同 revision 不同 digest 是损坏；不同 revision 且内容不同进入冲突；不同 dataset 的 UUID 碰撞是不可信冲突。不得静默 last-write-wins。
- 在没有 tombstone 的 1.0 合并中，“本机缺少某 ID”不等于“备份新增”，应标记 ambiguous restore candidate。用户明确选择整库恢复/替换时，完整快照缺失才可以表示该数据集中不存在。
- Readable JSON 是结构副本/恢复材料，不是同步协议。

### 9. 公共内容与 placeholder

- 正式 catalog seed 必须具备 stable ID、适用地区、批准/状态信息、官方来源、查阅日期、逐来源许可证和明确人工复核责任。
- 在这些门禁完成前，placeholder 只能用于 DEBUG、Preview 或 Test，不得进入 Release 可选目录、正式持久化事实或发布包。
- 截至 2026-07-21，placeholder 数据已用编译条件限制在 DEBUG、Preview 或 Test；Release 的内置目录为空，不再包含这些条目。正式 seed 在来源、许可证、stable ID 和人工复核责任完成前仍不得进入 Release。
- 自定义药物入口不依赖 catalog，可以保留。

## 未决门禁

| 门禁 | 当前状态与负责人 | 阻塞范围 | 最迟解决批次 |
| --- | --- | --- | --- |
| 代码与项目原创文档许可证 | 2026-07-21 已选择：自有软件源码 MPL-2.0，项目原创文档 CC BY-SA 4.0；以根 `LICENSE` 与 `LICENSE-SCOPE.md` 为准 | 该许可证选择已闭环；不替代逐来源内容授权 | 已解决 |
| 品牌与 AppIcon | 名称、Logo、AppIcon 保留权利；当前 AppIcon 经用户确认的 ChatGPT 生成来源、精确 SHA-256、仓库角色与证据边界已记录在根 `ASSET-PROVENANCE.md` | 来源记录子门禁已闭环；该记录不是新增使用授权，第三方相似性、目标市场商标与最终发行法律复核仍未验证 | 来源记录已解决；法律复核在发布硬化前 |
| 远端仓库治理 | 当前事实仅为 `AWantedRaccoon/mtfunmanual-app`；未授权创建、改名或 push | 新内容仓库、公开历史、自动发布 | 任何远端操作之前 |
| 上架地区与法律实体 | 产品负责人未确认 | App Store 提交、医疗/健康应用主体审查 | 发布硬化之前 |
| Files / iCloud Drive 结论 | 需 App Review/法律确认或可靠 provider 限制 | 含健康数据的 JSON/package/CSV/PDF 导入导出 | 报告与完整备份发布之前 |
| catalog 来源授权与复核责任 | 尚无已审核 seed、再分发许可或责任人 | Release 药品目录、内容仓库 | 方案目录进入 Release 前 |
| 库存默认 lot policy | 产品负责人未选择 | 自动库存扣减的默认 UX | 库存实现前 |
| record digest v1 canonical spec | 工程需产出测试向量并评审 | JSON v2、完整备份和冲突检测 | 数据安全底座/备份实现前 |
| 医疗分析 App Review 分类 | 需发行与法律复核 | 确定性方案分析的发布 | 分析接入 Release 前 |

2026-07-21，产品负责人批准分层许可：项目自有软件源码使用 MPL-2.0，项目权利人原创文档使用 CC BY-SA 4.0，品牌名、Logo 与 AppIcon 不进入开放许可，第三方医疗与研究材料逐项沿用原始授权。根 `LICENSE`、`LICENSE-SCOPE.md` 与 `TRADEMARKS.md` 共同定义范围。产品负责人随后确认当前 AppIcon 由 ChatGPT 图像生成能力生成；根 `ASSET-PROVENANCE.md` 记录其精确文件身份、仓库角色、当前 OpenAI 合同依据与未知项，但不增加未被用户明确授予的项目使用范围。该决定关闭了许可证类型和当前 AppIcon 来源记录门禁，但没有自动证明当前脏工作树适合公开，也没有关闭第三方相似性、目标市场商标、第三方内容、catalog seed、公开提交选择或远端操作门禁。

## iOS 17 实现后果

- 单实体稳定 ID 可以继续使用 iOS 17 支持的单字段唯一约束。
- 复合业务不变量由串行写入边界、Repository、规范化派生键和单事务校验承担；不能虚构 iOS 18 数据库宏已经提供兜底。
- occurrence 单 leaf、方案区间不重叠、库存一致性和导入冲突都必须能在无 UI 环境测试。
- 查询先使用 predicate、sort、fetchLimit 和有界 read model；用 5 年 fixture 测量。若 SwiftData 无法满足迁移、事务、查询或文件保护门禁，触发 GRDB ADR，而不是偷偷升最低系统或混用两套数据库。

## 最低测试不变量

后续批次至少覆盖：

- **事件**：相同 operation 重试恰好一次；相同 operation 不同 digest 零写入；重复初始事实冲突；过期 leaf 拒绝；多层纠错仍单 leaf；库存 reversal/consume 恰好一次。
- **时间**：旅行后历史 local date 和方案关联不变；DST gap/overlap；方案半开区间边界；date-only 不伪造 instant；legacy assumed provenance；相同 instant 稳定全序。
- **库存**：各 policy 的稳定排序与 tie-break；规则歧义、单位不兼容、过期或不足时零扣减并产生核对项；不部分扣减；projection rebuild 等于缓存。
- **化验**：同日多 sample 保留；重复测定不被覆盖；同名自定义项目不自动合并；原文/Decimal/单位/范围保留；旅行后关联不漂移。
- **dataset**：事务 revision、失败间隙、异源合并、完整恢复；digest golden vectors；四类冲突；无 tombstone 时的 missing ambiguity；稳定导出顺序和重复 envelope 拒绝。
- **网络与发行**：Release 静态依赖/entitlement 扫描；真机动态域名观察；placeholder 和敏感 fixture 不进入 Release。

## 非目标

Batch 0 不实现：

- 新 SwiftData schema、真实 store fixture、迁移或 backfill；
- AppWriteActor、Repository、索引或性能优化；
- 文件保护、系统备份排除或 generation 恢复；
- 通知、库存、附件、报告、公共内容或分析；
- 正式备份、Files/iCloud 发布结论；
- 许可证选择、远端仓库创建/改名、公开历史或 push。

上述工作分别属于后续数据安全、功能闭环、可携带数据、公共内容和发布批次。

## 被取代的外部方案断言

以下外部规划断言不再作为实现依据：

- “最低 iOS 18 且不淘汰设备”；
- 依赖 iOS 18 复合 `#Unique`、`#Index`、History 或 erase 保证 1.0 正确性；
- `AdministrationEvent.occurrenceKey` 唯一；
- 同一 sample 的结果仅以可编辑 item code 唯一；
- MIT、品牌例外、`AWantedRaccoon/mtf-app` 和内容仓库已经在 canonical 仓库确认；
- 当前 JSON v1 是安全备份、同步或已通过 Files/iCloud 发布门禁。

## 官方依据

- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Apple Standard EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/)
- [Apple：SwiftData updates](https://developer.apple.com/documentation/updates/swiftdata)
- [Apple：iOS 17 / iPadOS 17 支持设备证据](https://support.apple.com/en-us/120949)
- [Apple：iPadOS 18 兼容设备](https://support.apple.com/en-mide/104986)
- [Apple：Inspecting app activity data](https://developer.apple.com/documentation/network/inspecting-app-activity-data)
- [Mozilla Public License 2.0](https://www.mozilla.org/en-US/MPL/2.0/)
- [Creative Commons Attribution-ShareAlike 4.0](https://creativecommons.org/licenses/by-sa/4.0/)
- [Creative Commons FAQ：软件、文档、Logo 与第三方材料](https://creativecommons.org/faq/)

## Batch 0 完成定义

- 仓库 canonical 文档不再把相互冲突的事项同时写成“已确认”；
- 已接受合同与未决门禁清楚分开；
- 用户可见界面和辅助功能文案不再把 `V2.5` 当作 App 版本；
- iOS 17 工程配置不变；
- 当前脏工作树中的用户改动被保留；
- `foragent/mtf-app` 只保留带来源说明的同步快照；
- Batch 0 合同冻结当时未执行任何远端、发行、法律或许可证动作；后续许可证决定以上述 2026-07-21 记录为准，远端与发行授权仍未发生。
