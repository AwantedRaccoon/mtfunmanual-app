# 0014：Batch 6 应用锁与隐私遮挡

- 状态：Accepted
- 日期：2026-07-28
- 适用版本：App 1.0 / Schema V11
- 前置合同：[0001](0001-ios-technical-direction.md)、[0002](0002-batch-0-contract-freeze.md)、[0003](0003-data-safety-foundation.md)
- 数据控制合同：[0015](0015-batch-6-data-inventory-deletion-and-reset.md)
- generation 合同：[0016](0016-schema-v11-and-generation-retention.md)

## 1. 决策

App 1.0 使用 Apple `LocalAuthentication` 的
`LAPolicy.deviceOwnerAuthentication` 实现用户主动启用的应用锁。系统可以按设备状态
使用 Face ID、Touch ID 或设备密码；App 不自制 PIN，不读取或保存生物识别信息，也不
把认证结果派生为数据库加密密钥。

应用锁与最近任务遮挡是两个独立能力：

- 应用锁决定敏感根视图能否构造和显示；
- 隐私遮挡在 scene 不是 `.active` 时始终启用，不依赖应用锁设置；
- 温和模式只替换 App 内部分敏感名称，不能代替锁或遮挡；
- `NSFileProtectionComplete` 保护静态文件，不能代替 UI 门禁。

应用锁默认关闭。新安装和 V10 → V11 升级都不得替用户自动开启。启用和关闭都先完成
一次当前设备所有者认证，认证成功后才写权威偏好。

## 2. 权威状态与 V11

权威设置保存在 privacy-only V11 additive `PrivacyControlRecord`，不写入
`UserDefaults`、`@AppStorage` 或 Keychain，也不向 V3–V10 共用的
`UserPreferencesRecord` 添加字段。V11 只增加两个冻结 model：

```text
PrivacyControlRecord
  singletonKey: String unique = "primary-privacy-control"
  contractVersion: Int = 1
  appLockEnabled: Bool
  lastOperationID: UUID?
  createdAt: Date
  updatedAt: Date

PrivacyControlBackfillState
  taskKey: String unique = "v10-to-v11-privacy-control"
  sourceRawValue: String
  initialPrivacyDigest: String
  completedAt: Date?
  updatedAt: Date
```

两条记录各有唯一 `RecordRevision`；privacy digest 精确编码 singleton key、contract
version、enabled、last operation、created/updated timestamps，backfill digest 精确编码上述 marker
字段。backfill 的 `initialPrivacyDigest` 是新建默认 privacy 记录的 digest，不是旧 schema
中不存在的历史事实。初始形状固定为 `appLockEnabled = false`、
`lastOperationID = nil`、`createdAt = updatedAt`，并要求
`record.createdAt == marker.completedAt == marker.updatedAt`；validator 必须用
`record.createdAt` 重建这个初始形状并重算 `initialPrivacyDigest`，不能只检查摘要格式。
V11 以后不得向这两个 model 原位补字段；Batch 6 data control 使用独立 additive V12。

`PrivacyControlBackfillState` 证明 V10 → V11 采用已完成。新装和升级都建立
`appLockEnabled = false` 的合法单例。重复单例、非法版本、revision/digest 漂移或读取
失败均 fail closed；不得把异常当成关闭。

backfill source 只描述当前一步，接受 `bootstrapV11` 或 `schemaUpgradeV10`。
`bootstrapV11` 同时用于无 pointer 的新安装和 legacy adoption，因为二者都在初始
generation 直接采用 V11；`schemaUpgradeV10` 只用于已验证 V10 pointer。两种路径都
创建 privacy 与 completed marker，各自各有 revision；中断与否不会改变 source。
不存在“新装不需要 marker”的第二合法形状。source 进入 marker digest。

应用锁只保护已能打开的 ready store。store 尚未打开时显示中性 opening；store
Recovery 只显示不含用户投影的通用恢复说明和“重新检查”。Recovery 成功进入 ready
后重新读取权威锁设置并执行完整门禁，不能把锁状态复制到未经审计的第二事实源。

## 3. 设置写入与幂等

`SetAppLockCommand` 精确冻结：

```text
operationID: UUID
expectedLocalRevision: Int64
expectedDigestHex: String
isEnabled: Bool
committedAt: Date
```

`operationID` 同时就是 authentication request ID；禁止为一次认证另造第二身份。
coordinator 只有在对应 request 仍是最新、scene active、generation
不变且认证成功时才能构造命令。command digest 使用明确 canonical encoding 覆盖以上
全部字段和 privacy singleton record key。

writer 在单个 SwiftData transaction 内重新读取 privacy `RecordRevision` 并核对
expected local revision/digest；任何偏好变化、generation 变化或旧认证 callback 都
返回 stale，零写入。成功时更新 privacy record、`lastOperationID` 与 revision，写唯一
`OperationReceiptRecord`，更新 `OperationReceiptLedgerRecord`；这些事实共享同一个
local revision 和 committed timestamp。

receipt 的 `resultRecordType` 固定为 `"PrivacyControlRecord"`，
`resultRecordID` 固定为由 singleton key 生成的稳定 UUID。同 operation + 相同 command
digest 在 receipt/ledger 完整性验证后返回历史 `didApply = false` 和当前 privacy
snapshot，绝不把 head 回滚到旧结果；若它仍是 head，`lastOperationID`、revision 与
当前结果还必须吻合。同 operation + 不同 digest、expected token stale 或 receipt
孤立均 fail closed。因为 operation 就是认证 request ID，同一次认证不可能提交两个
不同 command。启用和关闭都使用该合同，不允许 Toggle 先乐观改变 UI 再异步覆盖。
首次 privacy receipt 之前允许既有 migration 把 ledger 放在最后 receipt 后的独立
revision；一旦存在任一 privacy receipt，当前 ledger revision 必须精确等于全部 receipt
的最大 local revision，且 ledger `updatedAt`、revision `committedAt` 与该最大
revision 上的 receipt committed time 一致，不能只检查大于等于或 revision 范围。

## 4. 状态机

`AppPrivacyCoordinator` 至少区分：

```text
bootstrapping
  -> disabled
  -> locked
  -> authenticating(requestID)
  -> unlocked
  -> unavailable(reason)
```

冷启动默认是不透明遮挡。`AppDataRuntime` 可以在遮挡后打开 store，但在
`PrivacyControlSnapshot` 被验证前不得构造 `OnboardingGateView`、`AppShellView` 或
任何用户数据投影。

每次认证使用新的 `LAContext`。认证结果只有同时满足以下条件才能解锁：

1. request ID 仍是最新；
2. coordinator 没有被取消或替换；
3. scene 当前是 `.active`；
4. 权威设置仍要求本次认证；
5. ready session 的 generation ID 没有变化。

任何旧 callback、重复点击、scene 切换、Recovery/retry 或 reset 都使 request token
失效。`LAContext.invalidate()` 后不复用实例，也不缓存
`canEvaluatePolicy(_:error:)` 结果。

用户取消、认证失败、系统取消、App 取消、不可交互和未知错误都保持锁定；它们不是数据
Recovery。设备没有设置密码时，启用操作不写入；已经启用后设备密码变为不可用时保持
fail closed，不自动关闭锁。`.deviceOwnerAuthentication` 的系统密码回退是唯一回退，
App 不显示自制密码输入界面。

首版没有 grace period。只有真正进入 `.background` 才要求下一次 active 重新认证；
短暂 `.inactive` 始终遮挡，但不单独撤销已经解锁的会话。认证弹窗引起的 transient
inactive 不得被误判成 background，也不得接受 scene 非 active 时返回的成功。

## 5. 最近任务与辅助技术

根窗口在 `scenePhase != .active` 时立即、无动画显示覆盖全部安全区的不透明中性遮挡。
遮挡包住 opening、ready、Recovery、sheet 和 full-screen cover，而不是只放在 tab
内容内部。底层同时：

- 禁止 hit testing；
- 从 accessibility tree 隐藏；
- 暂停敏感附件预览和待处理导航。

active 恢复时，只有 privacy 状态已经是 `.disabled` 或 `.unlocked` 才移除遮挡。
通知 tap、URL 或其他导航请求在锁定时只允许排队非敏感目的标识；认证成功后再解析实际
目标，禁止在锁后预构造敏感详情。

遮挡只能减少系统最近任务快照泄露。它不承诺阻止 App 处于 active 时的用户截图、录屏、
外部摄像、系统备份或已导出文件。

锁屏使用现有米纸、靛蓝、芥末金和规则线令牌，不使用 blur、毛玻璃或动画来隐藏内容。
主动作是“解锁本地资料”，触控区域至少 44 pt；错误信息不得输出 `LAError` 内部详情。

## 6. 与附件、通知、备份和温和模式的边界

- 附件私有副本继续使用 opaque 路径和 complete protection；锁定时不得构造附件预览。
- 本地提醒继续使用冻结的中性标题、正文和 `userInfo`；Batch 6 不新增敏感通知选项。
- 通知点击先经过根锁门禁；后台通知本身不因应用锁而获得额外系统加密承诺。
- `.systemManaged` 保持不变。应用锁不加密、排除或删除 iOS 系统备份。
- Photos/Files 原件、用户导出或分享的副本不受应用锁保护。
- 温和模式文案必须说明：名称替换由温和模式负责，最近任务遮挡由独立隐私保护负责。

`project.yml` 必须声明 `NSFaceIDUsageDescription`。中英文 purpose string 只说明
“用于解锁本机资料”，不声称 App 读取生物数据。

## 7. 复用与依赖调查

调查日期为 2026-07-28。没有复制候选源码，也不新增第三方运行时依赖。

| 候选 | 许可证与维护 | 匹配与隐私影响 | 决定 |
| --- | --- | --- | --- |
| Apple LocalAuthentication | iOS 系统框架，随系统维护 | 直接提供设备所有者认证；App 不获得生物模板，不要求网络 | 采用 |
| iOS 18+ 系统 Require Face ID / Hide App | Apple 用户级系统能力 | 用户可额外开启，但 App 无法跨 iOS 17 强制或验证 | 只作为可叠加保护，不作为实现 |
| Square Valet | Apache-2.0，持续维护 | 保护 Keychain secret，不解决 SwiftUI 根门禁、scene、Recovery 或 accessibility；增加依赖与审计面 | 不引入 |
| KeychainAccess | MIT，成熟 | 同样解决 Keychain item，不提供本合同状态机 | 不引入 |
| AuthenticationOverlay | 调查时没有可确认许可证，维护与使用规模很小 | 旧 scene 插入方式，缺少 async token、Recovery 与辅助技术合同 | 拒绝 |

## 8. 验证门禁

- V10 → V11 与新装偏好；缺失、重复、损坏和 digest/revision 漂移；
- SetAppLock exact/conflict replay、stale token、旧认证 callback、
  receipt/ledger/revision 关系和写失败 rollback；
- fake authentication client 覆盖 success、failed、user/system/app cancel、
  notInteractive、passcodeNotSet、biometry unavailable/not enrolled/lockout 和未知错误；
- stale success、连续重试、scene 快速切换、Recovery → ready、reset 后旧 callback；
- cold launch 不构造敏感根；锁定时底层不在 accessibility tree；
- `.inactive`、`.background`、Control Center、通知中心和 App Switcher 的无动画遮挡；
- 通知 tap 必须先认证；
- 320×568、390×844、430×932、768×1024、844×390 与最大辅助字号；
- VoiceOver、外接键盘、减少动态效果、iPhone/iPad；
- generic build、完整测试、Release contract 与项目专属 Simulator smoke。

Simulator 可以证明状态机和 UI 路径，不能替代 Face ID/Touch ID、设备密码变化、真实最近
任务快照和文件保护的真机证据。真机门禁未完成时只能称“本地/Simulator 实现完成”，
不能称 release-ready。
