# 许可证适用范围

本文件说明仓库中不同类型材料的许可边界。若具体文件带有更明确的许可或权利声明，以该文件的声明为准。

## 软件源码：MPL-2.0

除下文明确排除的材料外，本项目自有的软件源码、测试源码、工程配置和构建配置使用 [Mozilla Public License 2.0](LICENSE)：

- `Unmanual/` 中的 Swift 源码、非品牌资源描述与工程配置；
- `UnmanualTests/`、`UnmanualUITests/` 和 `UnmanualPerformanceTests/` 中的测试源码及项目自有测试支持材料；
- `project.yml`、`Unmanual.xcodeproj/` 中的项目元数据，以及未来明确加入仓库的项目自有构建脚本；
- 文档中明确作为项目源码示例提供的代码片段，但第三方示例除外。

上述文件的许可证通知统一附着于仓库根目录的 `LICENSE` 和本文件。将受 MPL-2.0 约束的源码或可执行形式对外分发时，必须遵守 MPL-2.0，尤其是对 Covered Software 源码、修改、通知和获取方式的要求。

`UnmanualTests/Fixtures/LegacyUnversionedV1/` 是一个具名的、确定性的、完全合成且不可关联个人的迁移测试 fixture。其固定 UUID、日期、方案、旅程和化验值均由项目测试生成器构造，不来自真实用户或生产数据库。该目录中的生成器、来源说明和 SQLite main/WAL/SHM 三件套作为项目自有测试支持材料按 MPL-2.0 提供；来源、生成方式、限制和精确哈希见该目录的 `PROVENANCE.md`。这项明确声明不自动延伸到未来 fixture 或任何真实、用户派生、第三方或未经审查的数据。

## 项目原创文档：CC BY-SA 4.0

在项目权利人拥有授权权利的范围内，以下项目原创文字与原创图示使用 [Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/legalcode)：

- `README.md`；
- `AGENTS.md`；
- `ASSET-PROVENANCE.md` 中的项目原创来源记录文字；
- `docs/` 下的项目原创产品、架构、设计和测试文档。

转载或改编这些材料时，必须提供适当署名、链接至许可证、说明是否修改，并按 CC BY-SA 4.0 或兼容许可证共享改编材料。该许可不表示项目权利人认可、赞助或认证任何转载或改编版本。

文档中的软件源码与代码片段仍按上一节的 MPL-2.0 处理；文档中明确标记的第三方材料不因位于这些文件内而改用 CC BY-SA 4.0。

指定公开署名方为 **“MTF不全书项目贡献者”**，来源为 [AwantedRaccoon/mtfunmanual-app](https://github.com/AwantedRaccoon/mtfunmanual-app)。在合理可行范围内，推荐写作：

> 《[文档标题]》由 MTF不全书项目贡献者提供，来源：https://github.com/AwantedRaccoon/mtfunmanual-app ，依据 CC BY-SA 4.0 使用；[未修改 / 已修改，并简述修改]。

如果文件另有作者、版权、来源或既有修改说明，也必须保留。该署名只用于履行许可证归属要求，不表示项目认可、赞助或认证复用者及其衍生版本。

## 不在上述开放许可内的材料

以下材料不受仓库根目录 MPL-2.0 或上述 CC BY-SA 4.0 授权：

1. **品牌与来源标识**：`MTF不全书`、`Unmanual` 及其他项目名称、Logo、AppIcon、服务标记和足以指示官方来源的品牌组合。详见 [TRADEMARKS.md](TRADEMARKS.md)。
2. **当前 AppIcon 位图**：`Unmanual/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`。其经用户确认的 ChatGPT 生成来源、当前文件哈希、仓库角色与证据边界已记录在 [ASSET-PROVENANCE.md](ASSET-PROVENANCE.md)；该记录不把图标纳入开放许可，也不构成新增的项目使用授权。仓库不通过 MPL-2.0 或 CC BY-SA 4.0 授予复制、修改、再分发或用于分叉应用标识的权利。
3. **第三方医疗与研究材料**：指南、标准、论文、逐字引文、图表、图片、截图、数据集、药品目录、第三方商标及链接目标。它们只按各自原始权利声明、许可证、书面授权或适用法律例外使用。
4. **内部与个人材料**：`agent-work.md`、本地路径、Simulator 标识、构建结果、诊断产物、真实个人健康数据、用户派生数据、未经来源与隐私审查的样本，以及未明确列入公开阶段快照的内部记录。这些材料不属于计划中的公开分发内容；公开可读本身也不自动授予使用权。上一节具名的全合成迁移 fixture 不属于本项排除材料。
5. **另有声明的文件**：未来加入的第三方依赖、字体、插图、catalog seed、fixtures 或其他资源必须随文件或来源清单提供自己的许可证与来源记录。

任何第三方内容清单至少应记录权利人、标题、版本或日期、来源 URL、查阅日期、许可证或授权依据，以及允许的使用与再分发范围。项目不得授权自身没有权利再许可的内容。

## App Store 二进制分发

App Store 的最终用户许可与本仓库的源码许可是两个边界。未来若使用 Apple Standard EULA 或符合 Apple 最低条款的 Custom EULA，该 EULA 不得限制或改变接收者对 MPL-2.0 源码已经取得的权利。此项仍需在签名 Release Candidate 和 App Store 法务门禁中复核。

## 贡献

除非在提交前另有明确书面约定，向本仓库提交贡献即表示贡献者同意按适用于目标材料的许可证提供该贡献：软件源码、测试和工程配置按 MPL-2.0；上述公开文档的原创文字与原创图示按 CC BY-SA 4.0。该入站授权与项目对外许可证一致，并自提交时生效。提交公开文档贡献也表示同意把“MTF不全书项目贡献者”列为指定署名方；文件中已经提供的个人作者、版权、来源和修改声明仍必须保留，不会被项目化署名覆盖。贡献者必须确认自己拥有相应授权权利；不得提交真实个人健康数据，未经事先审查和明确标记也不得提交第三方材料。

## 其他权利

除上述许可证明确授予的权利外，所有其他权利均予保留。本文件是项目的许可范围说明，不替代针对具体司法辖区的法律意见。
