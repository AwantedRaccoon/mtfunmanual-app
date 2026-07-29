# ADR 0017：Batch 7 就诊摘要与可移植数据合同

- 状态：Accepted
- 日期：2026-07-28
- 适用版本：App 1.0 / Schema V12
- 关联：ADR 0002、0003、0007、0013、0015、0016

## 背景

Batch 7 要解决两个不同的用户任务：

1. 在就诊前快速核对并整理一份只包含用户事实的摘要；
2. 在不依赖账号或网络的前提下，预览并带走自己的原始数据与附件。

现有 `AppDataBackup` / `ArchiveDataTransferSheets` 是 DEBUG 原型，只覆盖
`HRTProfile`、`CountdownRecord`、`JourneyEntry`、`LabRecord` 和
`RegimenVersion` 五类旧模型。它没有覆盖当前 54-model schema，也没有
dataset、revision、digest、终态删除、附件、冲突或崩溃恢复合同。它不得改名后
充当正式备份。

本 ADR 只冻结 Batch 7。公共内容与方案讨论建议属于 Batch 8；真机 Files、
系统备份恢复、签名 Archive 和 App Store 合规属于 Batch 9 门禁。

## 调查与复用决定

实施前的三组独立调查分别核对了产品合同、54-model 数据/删除/恢复合同，以及
原生与开源方案的许可证和隐私影响。决定如下：

- 不增加第三方运行时依赖；
- PDF 使用 UIKit/CoreText 生成，PDFKit 只做预览和可读性验证；
- CSV 使用项目内小型 RFC 4180 编码器，只导出，不作为导入格式；
- JSON 使用 Foundation `Codable` 的显式 wire DTO，不使用 Swift reflection；
- SHA-256 使用 CryptoKit，只表示运输完整性，不表示签名、来源或真实性；
- 完整备份使用自定义 directory package，不使用 raw SQLite/WAL，也不在本批次
  引入 ZIP；
- 复用现有 coordinator read/exclusive lease、54-model inventory、RecordDigestV1、
  AttachmentFileStore 有界校验、generation pointer-last 和 journal readback 合同；
- 不为一次报告或不持久化的传输状态升级 Schema。Batch 7 保持 V12。

## 三种输出的职责

### 1. 就诊摘要 PDF

PDF 是给人阅读的终态投影，不是恢复格式。它只包含用户当前可见且明确选择的事实：

- 30、90、180 天或自定义范围；
- 当前方案与范围内方案变化；
- 执行、延迟、跳过和偏差；
- 化验与采样上下文；
- 用户选择的状态、事件和问题清单。

默认包含报告日期、方案、执行、化验、状态和问题；默认排除姓名、照片和敏感笔记。
姓名只有用户在当前预览中输入并打开开关时才出现。照片开关只决定是否披露附件清单；
Batch 7 不把照片二进制嵌入 PDF。

摘要只能陈述用户记录。它不生成方案评价、剂量建议、诊断、来源分析或讨论建议。
每份摘要必须包含：

> 数据来自用户记录，不是处方、诊断证明或医生签署的病历。

生成文件前必须显示与最终 bytes 来自同一冻结快照的完整 App 内预览。导出后明确提示
文件不再受 App Lock 保护。

### 2. CSV 原始表格导出

CSV 是表格分析输出，不是备份或导入格式。一个导出 package 内按领域生成多张固定
schema 表；空表仍保留表头。首批表为：

- `regimens.csv`
- `administrations.csv`
- `labs.csv`
- `status.csv`
- `journey.csv`

编码固定为 UTF-8、CRLF、RFC 4180 双引号转义、POSIX 日期格式和原始 Decimal 字符串。
任何以 `= + - @` 开头的用户字符串在写入单元格前加单引号，避免表格公式执行。

### 3. Readable JSON v2 与完整备份

Readable JSON v2 是版本化逻辑数据副本。它必须包含：

- 固定 format/version 和 App schema 版本；
- dataset ID、source generation ID、captured next-local-revision watermark；
- 54 个 SwiftData 模型的固定 taxonomy、数量和逐记录显式 payload；
- 稳定 ID/record key、local revision、RecordDigestV1 版本与 digest；
- 终态 deletion overlays、retained audit 和通知覆盖投影；
- active attachment manifest，但不在 standalone JSON 中嵌入附件 bytes；
- canonical entry 顺序和 envelope transport SHA-256。

“完整备份”定义为当前 active logical dataset 的 Readable JSON v2、所有 active
attachment 原始 bytes 和根 manifest。它不包含：

- inactive generations；
- 已终态删除且已经清除的附件 bytes；
- Files/Photos 中的外部原件；
- 已导出的报告、截图、系统通知队列或系统备份；
- App Lock 的本机认证状态。

目录结构固定为：

```text
manifest.json
data/readable-v2.json
attachments/<lowercase-attachment-uuid>/payload
```

目标路径只由 attachment ID 推导。导入端不得信任包中建议的 destination path。

## JSON v2 与 package 限额

读取外部文件时先在 security scope 有效期内有界复制到 App 私有 staging，再停止访问
provider URL。禁止 `Data(contentsOf:)` 无界读取。V2 固定限额：

| 项目 | 上限 |
| --- | ---: |
| `manifest.json` | 1 MiB |
| standalone JSON / `readable-v2.json` | 64 MiB |
| 单附件 | 20 MiB |
| active 附件数量 | 2,000 |
| package 普通文件数 | 2,100 |
| package 目录数 | 2,002 |
| package 内部树节点数 | 4,102 |
| package 总 bytes | 2 GiB |
| 单模型记录数 | 250,000 |
| 字符串 UTF-8 bytes | 1 MiB |
| JSON 容器深度 | 64 |
| 相对路径 UTF-8 bytes | 512 |

文件、目录和内部树节点分别计数；目录不能消耗普通文件预算。合法的 2,000 个 active
附件 package 会形成 2,002 个目录、2,002 个普通文件和 4,004 个内部节点，必须能通过
冻结与导出。namespace 冻结按当前递归深度持有 descriptor，不按附件总数持有全部
descriptor；该最大附件 fixture 的测试峰值是 3 个临时 descriptor。

2 GiB 是 portable package 的格式与导入上限，不是当前 DEBUG/internal
`FileDocument` 导出的常驻内存承诺。`FileWrapper` 交接必须拥有全部普通文件 bytes，
禁止依赖 mmap；当前内部导出因此另设 64 MiB（manifest + readable data + attachments）
内容 bytes 上限，并在冻结 namespace 或构建 wrapper 前用 checked arithmetic
拒绝超限。该 64 MiB 不包含 Foundation 对象、目录树、provider 或系统分享界面的运行时
开销，不能被描述成整个导出流程的总 RSS 保证。完整 2 GiB 的 file-backed 输出路径留待
Batch 9 与真机 provider/内存证据一起冻结，不能把当前 `FileDocument` 路径描述成已经
支持 2 GiB 导出。

所有整数加法使用 checked arithmetic。解析器拒绝：

附件同时继承 ADR 0007 的生产存储合同：只接受系统声明的 image 或 PDF；每个 owner
最多 6 个附件、合计最多 60 MiB。portable validator、导入预检与最终
`AttachmentFileStore` 必须消费同一组限制，不能让包在确认后才因存储边界失败。

- 绝对路径、空路径、`.`、`..`、反斜杠、NUL；
- symlink、hardlink、FIFO、device 和其他非普通文件/目录；
- 重复 entry、重复 inode、Unicode NFC 或大小写折叠碰撞；
- 未声明、缺失或额外 entry；
- size/hash/count/root digest 不一致；
- 重复稳定 ID、未知必需 enum、非有限浮点、越界日期或版本；
- 未通过关系、revision、digest、terminal overlay 和 attachment tree 验证的数据。

## 冻结快照与 TOCTOU

导出流程固定为：

1. 取得 coordinator read lease；
2. 读取 production inventory、终态可见投影、54-model typed payload 与 active
   attachment manifest；
3. 生成 `FrozenExportPlan`，包含 state digest、范围、数量和字节估算；
4. 释放 lease，仅保留经审计的紧凑事实并展示完整预览；此时不建立或持有
   `FileWrapper`；
5. 用户确认时重新取得 read lease并重算 state digest；
6. state 有任何变化即返回 `impactChanged`，不生成旧预览对应的文件；
7. 在同一 lease 内由文件层执行“校验 → 有界复制 → 复核 hash”；
8. 完整 staging 后核对 exact entry set/root digest，以 `.immediate` 加
   `.withoutMapping` 生成唯一一个拥有自有 bytes 的 wrapper，再做第二次 descriptor
   审计；确认流程同一时刻最多持有一个 wrapper；
9. wrapper 建立后、交给 UI 前，精确清理本次磁盘 package 与 ownership intent；
   UI 成功、取消或失败都不再持有磁盘临时副本。

所有临时文件使用 `.complete` data protection、排除系统备份、文件名不含姓名/药物，
并在成功、取消、失败或启动恢复后清理。

创建任何导出、导入或恢复 staging 之前，必须先把 `kind + operationID + state +
canonical relative path + contract digest` 写入 App 私有的 durable cleanup journal。
`active` 表示 package 正在构建或仍由当前界面持有；当前会话的泛化重试不得删除它。
显式丢弃必须先把同一 intent 原子推进为 `cleanupPending`，再开始删除；删除失败保留
`cleanupPending` 作为重试依据。只有尚未建立 live owner 的冷启动恢复可以把崩溃遗留
的 `active` 一并推进并清理。

generation pointer、migration journal、cleanup journal 与 restore journal 的控制文件
写入共享同一套确定性原子事务：新值和旧值的 sibling 名称分别包含内容 SHA-256，
进程内写入由同一递归锁串行化。冷启动只接受由 canonical leaf、已验证 digest 和语义
有效 payload 共同证明的 pre-swap、post-swap 或 old-cleanup 状态；随后确定性完成
rename 或清理。digest 不匹配、语义无效、未知 sibling、symlink、hardlink 或身份/类型
变化均 fail closed，并保留外来条目，不得用随机临时文件名或“最后一个文件获胜”猜测
事务结果。

临时路径只能由 operation ID 重新推导；清理器不得按名称扫描目录，也不得删除未登记的
普通或 UUID-looking sibling。删除失败时保留 intent，删除成功后再 pointer-last 移除
intent。冷启动必须在建立任何 `ModelContainer` 前重放这些 intent；若主 restore
journal 已存在，则精确保留它绑定的 staging operation，直到
`activationCleanupPending` 完成。journal、根目录、operation directory 或 package
root 出现 symlink、未知类型、路径篡改或摘要不一致时零删除失败。

恢复 staging 的生产清理必须以 no-follow 目录 file descriptor 逐级打开 App root、
`Recovery` 与 `PortableImports`，用 `fstatat` 复核 operation/package 的类型与 inode，
再把已登记 operation 原子改名为同目录、可由 operation ID 重算的 quarantine 名称，
最后仅通过锚定 descriptor 的 `unlinkat` 删除。清理中断时 intent 保留，下一启动既能
识别 canonical 名称，也能识别该确定性 quarantine 名称；不得退回字符串前缀校验后
调用递归路径删除。

恢复 staging 的创建、敏感内容写入、`fsync`、readback 与 exact-tree/root-digest 审计
必须保持在同一次 descriptor lease 内。创建出的 operation/package inode 不得在关闭
descriptor 后通过 URL 重新打开并建立新基线；每一级目录和文件都用相对 FD 的
`mkdirat/openat`、no-follow 类型与 inode 复核完成。清理在 quarantine 前冻结整棵已登记
子树的 inode/type snapshot，mutation 后及逐项 `unlinkat` 前再次核对；任意 foreign
replacement 或新增条目都 fail closed，并保留 cleanup intent。

## 导入、合并和整库恢复

### 公共前置状态

```text
选择文件
→ 私有 staging 有界复制
→ 严格 package 审计
→ 只读预览 dataset / 分类 / 附件 / 删除 / 冲突
→ 选择 restore 或 replace
→ 再次明确确认
→ exclusive lease
→ journal
→ 写入非活动目标或专用 transaction
→ 验证并只读 reopen
→ pointer-last / receipt
```

dry-run token 必须绑定 package root digest、本机 state digest、模式、冲突选择和附件计划。
确认时任一 digest 改变即零写入失败。

### Merge 冲突分析（1.0 不落库）

- 1.0 可以只读计算同 dataset、跨 dataset、revision、digest、UUID、缺失记录和
  terminal tombstone 冲突矩阵，但不提供 merge 确认或落库入口；
- 同 ID/revision/digest 只标为 no-op；同 revision/不同 digest 标为损坏；
- 不同 revision/不同内容、跨 dataset UUID 碰撞、缺少父关系、命中 terminal
  tombstone 或本机缺少记录都必须明确显示，禁止 last-write-wins；
- 用户需要采用外部资料时，必须选择 `restore`（仅 fresh/reset 合同允许）或
  `replace`（非空设备二次确认）。这样不会把两个 dataset 的修订谱系和附件事务
  伪装成一条历史；
- 将来若要开放 merge 写入，必须另立 ADR，冻结逐模型冲突选择、重新分配本机
  revision、跨附件 transaction journal 和撤销/恢复语义。

### Restore / Replace

- `restore` 只用于空设备或完成 reset 后采用备份 dataset；
- `replace` 用于非空设备，经明确确认后采用备份 dataset；
- 两者都写入新的 inactive generation；
- 生成 dry-run plan 前，以及 exclusive lease 内写 restore journal 前，均须把 package
  重新审计并插入隔离的 V12 `ModelContainer`，运行同一套 enum、关系、revision、
  digest、54-model foundation 与 active attachment 可恢复性校验；未知 enum、无效
  owner/type/limit 或关系缺失必须在 durable restore journal 之前失败；
- 完成关系、revision、digest、附件、保护属性和只读 reopen 后停在
  `restartRequired`；
- 下一次冷启动且尚未打开 active ModelContainer 时重验 target；在语义验证后为
  Store bundle 与完整 Files tree 建立 `path + inode/type/nlink/size + mode +
  mtime/ctime + streaming SHA-256` 内容封印；同时为 App root 到 generation 的每一级
  祖先、Store/Files/Attachments 目录和 Files root 建立 descriptor identity、
  mode、mtime 与 ctime 封印。App 自有目录只接受 `0700` 或已封印的 `0500`，普通
  App 文件只接受 `0600` 或已封印的 `0400`；历史 SQLite bundle 的 `0644/0444`
  会先规范化到 App 自有模式。激活窗口把目录设为 `0500`、普通文件设为 `0400`，
  pointer 写入前后都复核 exact tree、内容和目录 seal；成功或可恢复失败后精确恢复为
  `0700/0600`。通过激活钩子持有的旧可写 descriptor 对 SQLite/WAL/SHM 或 attachment
  payload 的同 inode 写入、截断、扩展、mode/ctime ABA 或目录替换都会拒绝激活并保持
  来源 pointer。该同步激活门禁不宣称能防御最后一次复核之后的任意恶意同进程代码；
- 内容与 namespace 复核通过后才执行 pointer-last；
- pointer 切换后先持久化 `activationCleanupPending`，精确清理 journal 绑定的
  staging 成功后才写入 `activated`；清理或最终 journal 写入失败都可在下次冷启动
  幂等继续，不得遗失重放依据或永久保留敏感 package；
- 原 active generation 保留为 inactive rollback source，不在 Batch 7 自动清除。

## Release 门禁

Apple App Review Guidelines 对个人健康信息与 iCloud 的组合存在未解决边界，而系统
Files picker/exporter 可能显示 iCloud Drive 或第三方 provider。因此：

- App 内报告预览、纯格式引擎和安全审计代码可以进入 Release；
- 向 Files/Share 的 PDF、CSV、JSON、完整备份出口，以及外部 import/restore UI，
  在 DEBUG / internal feature gate 下提供；
- 关闭这些入口不等于删除实现或测试；
- 只有 Batch 9 形成法律/App Review 结论并完成真机 provider、文件保护和系统备份
  恢复测试后，才能打开 Release 外流入口并称为发布能力。

## 完成门禁

Batch 7 只有同时满足以下项目才可标为完成：

1. 54-model taxonomy 的每一类都有显式 wire adapter、field coverage 和固定顺序测试；
2. JSON golden、exact decoder、limits、重复/未知/截断/非有限值和版本拒绝测试；
3. 终态删除 export → restore 不复活，retained audit 关系仍通过 validator；
4. package path/symlink/hardlink/collision/size/hash/entry-set 测试；
5. preview 后本机或 package 改变时零写入；
6. merge 只读冲突矩阵证明无 last-write-wins；restore/replace 覆盖每个
   journal failpoint；
7. active attachment size/type/hash/path 一一对应，已删除附件不进入 package；
8. PDF 中文长文本、多页、隐私开关和免责声明测试；
9. CSV quoting、换行、Decimal、日期和公式注入测试；
10. 320 × 568、390 × 844、430 × 932、768 × 1024 与 iPhone/iPad 主流程渲染；
11. 动态字体、VoiceOver 标签、取消、错误、重新进入和 Reduce Motion 检查；
12. 全套单元测试、无签名 Release/Debug 构建和项目专属 Simulator 测试通过；
13. 全新独立 reviewer 审查实际 diff 和证据后明确通过。

Files provider、iCloud/系统备份恢复、真机 data-protection class 与 App Store 政策结论
若未完成，必须继续标为 Batch 9 未验证门禁，不得伪装为 Batch 7 已验证。
