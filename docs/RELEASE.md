# 发版操作清单

本文档描述 FileCollector 的版本发布流程。涉及发布新版本、打 tag、Release 管理等工作时，请先阅读本文档。

> **适用场景**：准备发布新版本、修改版本号、管理 GitHub Release、回滚发版。

---

## 版本号唯一来源

版本号仅在 `meson.build` 第 2 行维护：

```meson
project('filecollector', 'vala', 'c',
  version: '4.8.0',
  ...
)
```

**不要**在其他文件中硬编码版本号。CI 脚本、DEB 打包脚本、Windows/macOS 打包脚本均从 `meson.build` 读取版本号。

---

## AppStream 元数据同步

每次发布新版本时，**必须**在 `data/io.github.sam_fic.filecollector.metainfo.xml` 的 `<releases>` 节点顶部新增一条 release 条目：

```xml
<release version="X.Y.Z" date="YYYY-MM-DD">
  <description>
    <p>版本主题概述：</p>
    <ul>
      <li>变更条目 1</li>
      <li>变更条目 2</li>
    </ul>
  </description>
</release>
```

- 新条目放在 `<releases>` 的**最上方**（最新的版本在前）。
- `date` 使用实际发布日期（ISO 8601 格式）。
- `version` 必须与 `meson.build` 中的版本号一致。
- 描述内容用 `<p>` 概述主题 + `<ul>` 列出主要变更。

---

## 发版步骤

### 1. 修改版本号

```bash
# 修改 meson.build 第 2 行的 version 字段
# 例如从 4.8.0 改为 4.9.0
```

### 2. 更新 AppStream 元数据

在 `data/io.github.sam_fic.filecollector.metainfo.xml` 的 `<releases>` 节点顶部添加新版本的 release 条目。

### 3. 提交变更

```bash
git add meson.build data/io.github.sam_fic.filecollector.metainfo.xml
git commit -m "release: vX.Y.Z"
```

### 4. 打标签并推送

```bash
git tag vX.Y.Z
git push origin main
git push origin vX.Y.Z
```

> 推送 `v*` 格式的标签后，GitHub Actions 会自动触发四平台并行构建（DEB、Flatpak、Windows x64、macOS ARM64）。四个平台构建全部成功后，CI 自动创建或更新同名 GitHub Release 并上传资产。**无需手动上传任何产物文件。**

### 5. 验证

- 在 GitHub Actions 页面确认四项构建任务全部通过。
- 在 Releases 页面确认 Release 资产已上传（见下表）。
- 确认 Release Notes 与 metainfo.xml 中的变更条目一致。

---

## CI 产物清单

推送 `v*` 标签后，CI 为同一 Release 生成以下资产：

| 平台 | 产物文件 | 构建环境 |
| --- | --- | --- |
| Linux amd64 | `filecollector_X.Y.Z_amd64.deb` + `.sha256` | Ubuntu 26.04 容器 |
| Flatpak | `filecollector-X.Y.Z.flatpak` | GNOME 50 SDK |
| Windows x64 | `filecollector-windows-X.Y.Z-x64.zip` + `.sha256` | MSYS2 MINGW64 |
| macOS ARM64 | `filecollector-macos-X.Y.Z-arm64.zip` + `.sha256` | macOS 14 (Apple Silicon) |

CI 工作流配置见 `.github/workflows/desktop-packages.yml`。CI 构建规则的详细说明见 [桌面端自动打包与发布](GITHUB_ACTIONS_DESKTOP.md)。

---

## 回滚与重发

### 回滚（撤销已发布的版本）

1. 删除 GitHub Release（在 Releases 页面操作）。
2. 删除本地和远程标签：
   ```bash
   git tag -d vX.Y.Z
   git push origin :refs/tags/vX.Y.Z
   ```
3. 如需修改后重新发布，回到步骤 1 重新操作。

### 重发（修复构建失败后重新发布）

1. 修复问题并提交到 `main`。
2. 删除旧标签（本地 + 远程）。
3. 重新打标签并推送：
   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

> 删除标签后重新推送会重新触发 CI 构建。如果 Release 已创建，可能需要先删除 Release 再让 CI 重新创建。

---

## 发版前检查清单

- [ ] `meson.build` 版本号已更新
- [ ] `data/io.github.sam_fic.filecollector.metainfo.xml` 已添加对应 release 条目
- [ ] 本地构建通过（`meson compile` 无错误）
- [ ] 本地测试运行功能正常
- [ ] 提交信息清晰
- [ ] 标签格式为 `vX.Y.Z`（如 `v4.9.0`）
- [ ] 推送后确认 CI 四平台构建全部通过
