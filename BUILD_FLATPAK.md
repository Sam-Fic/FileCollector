# FileCollector Flatpak 构建指南

> 本文档供 AI 编程助手（如 Copilot）在协助构建和发布 Flatpak 版本时参考。

## 一、前置条件

确保系统已安装：

```bash
flatpak --version       # 需要 >= 1.12
flatpak-builder --version
```

需要添加 Flathub 运行时源（首次）：

```bash
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user flathub org.gnome.Platform//50 org.gnome.Sdk//50
```

## 二、版本发布完整流程

### 2.1 版本发布提交规范

**每个版本发布需要两个 commit**：

1. **功能提交**：将代码变更提交到主分支
2. **发布提交**：修改版本号并打标签（格式见下文）

**版本发布 commit 格式**：
```bash
git commit -m "release: v2.0.4"
git tag v2.0.4
```

> 标签名称格式必须为 `v` + 版本号（如 `v2.0.4`），与 `metainfo.xml` 中的 `version` 属性一致。

---

### 2.2 确定更新内容范围

在填写版本更新日志时，需要通过 Git 提交历史来确定新版本包含的变更：

```bash
# 查看当前版本与上一版本之间的所有提交
git log v2.0.3..HEAD --oneline

# 查看详细变更内容（用于总结更新日志）
git log v2.0.3..HEAD --stat --name-only
```

**版本阶段示例**（基于项目历史）：

| 版本 | 包含的提交（从旧到新） | 变更内容摘要 |
|------|----------------------|-------------|
| v2.0.2 | `2505ddc` | 初始版本发布 |
| v2.0.3 | `2403273`, `ca99c89` | 添加剪贴板功能、重构常用语选择器 |
| v2.0.4 | `c646de4`, `0dd54d6`, `4b6572e`, `fc586d0` | 添加 Flatpak 包下载、优化窗口布局、添加 Toast 提示 |

> 💡 **提示**：当 Git 提交记录中没有明确的版本标记时，请查看最近 20-50 条提交历史，结合 README 和代码变更来判断版本边界。通常版本号更新提交会包含 `meson.build` 和 `metainfo.xml` 的修改。

---

### 2.3 更新版本号

需要修改 **1 个文件**：

| 文件 | 修改内容 |
|---|---|
| `meson.build` | 第 2 行 `version: 'x.y.z'`（此为唯一版本源，`configure_file` 自动生成 `Config.VERSION` 供 `window.vala` 使用） |

`metainfo.xml` 需在 `<releases>` 内新增 `<release>` 条目。请查看 git 提交记录，
获取上版本到新版本之间的变更内容，简要描述在 `<description>` 中。

`metainfo.xml` 新增条目的格式示例（请严格遵守规范）：

```xml
<release version="2.0.4" date="2026-05-27">
  <description>
    <p>新特性与修复：</p>
    <ul>
      <li>简单描述：具体变更 1</li>
      <li>简单描述：具体变更 2</li>
    </ul>
  </description>
</release>
```

> ⚠️ 注意：`<release>` 条目应按版本号**从新到旧**排列，最新的在最上面。

### 2.4 提交并打标签

```bash
git add -A
git commit -m "release: v2.0.4"
git tag v2.0.4
```

> 💡 **发布到 GitHub Releases 时**：`metainfo.xml` 里的发布描述不会自动同步到 GitHub。创建 Release 时，记得把 `<release>` 中的 `<description>` 内容复制到 Release notes 中，这样用户可以在 GitHub 页面上直接看到更新日志。

### 2.5 构建 Flatpak 包

#### 方式 A：仅本地安装（快速验证）

```bash
flatpak-builder build-dir com.github.samfic.filecollector.json --user --install --force-clean
```

- `build-dir/` 是临时构建目录（已在 `.gitignore` 中忽略）
- `--force-clean` 会删除旧的构建目录，避免缓存冲突
- `--user --install` 构建完成后自动安装到当前用户环境

#### 方式 B：构建可分发的 .flatpak 文件（用于发布）

```bash
# 步骤 1：构建到本地仓库
flatpak-builder --repo=flatpak-repo build-dir com.github.samfic.filecollector.json --force-clean

# 步骤 2：从本地仓库导出单文件 bundle
flatpak build-bundle flatpak-repo filecollector-2.0.4.flatpak com.github.samfic.filecollector
```

> ⚠️ **常见错误**：`build-bundle` 的第一个参数必须是 **本地仓库目录**（即 `--repo=` 指定的目录），**不是**构建目录 `build-dir/`。如果传入 `build-dir/` 会报错：
> ```
> error: 'build-dir' is not a valid repository: opening repo: opendir(objects): No such file or directory
> ```

### 2.6 验证构建结果

```bash
# 检查 bundle 文件大小
ls -lh filecollector-*.flatpak

# 安装并运行验证
flatpak install --user --or-update filecollector-2.0.4.flatpak
flatpak run com.github.samfic.filecollector

# 确认 metainfo 中的版本号正确
grep "release version" build-dir/files/share/metainfo/com.github.samfic.filecollector.metainfo.xml
```

> ⚠️ **安装失败处理**：如果已安装同版本 bundle，需使用 `--or-update` 覆盖，或先卸载再安装：
> ```bash
> flatpak uninstall --user -y com.github.samfic.filecollector
> flatpak install --user filecollector-2.0.4.flatpak
> ```

### 2.7 修改源码后重新构建

如果在构建 flatpak **之后**又修改了源码（如添加 Website 链接、修正版本号等），**必须重新执行 2.5 节的完整构建流程**（flatpak-builder + build-bundle），否则安装的仍是旧构建。仅重新 `meson compile` 不会影响已安装的 flatpak 包。

## 三、项目结构说明

```
com.github.samfic.filecollector.json   ← Flatpak 构建清单（manifest）
meson.build                             ← Meson 构建配置（**唯一版本源**）
src/config.vala.in                      ← 版本号模板，meson 构建时从 meson.build 读取版本自动生成
data/
  com.github.samfic.filecollector.metainfo.xml  ← AppStream 元数据（版本记录在此）
```

### 构建清单结构

`com.github.samfic.filecollector.json` 包含两个模块：

1. **`blueprint-compiler`**：从 Git 源码构建 Blueprint 编译器（用于编译 `.blp` UI 文件）
2. **`filecollector`**：主应用，`"type": "dir", "path": "."` 表示使用本地源码

> 注意：在 CI/CD 环境中，`"type": "dir"` 可能无法使用，需要改用 `"type": "git"` 指向 GitHub 仓库。

## 四、构建配置的关键细节

### 4.1 运行时版本

当前使用 `org.gnome.Platform` **runtime-version: 50**（对应 GNOME 50）。

如果需要升级运行时版本（例如 GNOME 51 发布后），需要同时更新：
- `com.github.samfic.filecollector.json` 中的 `runtime-version`
- CI/CD 中安装的运行时版本

### 4.2 权限（finish-args）

```json
"--filesystem=host"    # 允许访问整个文件系统（核心功能需求）
"--socket=wayland"     # Wayland 显示协议
"--socket=fallback-x11" # X11 回退
"--device=dri"         # GPU 硬件加速
"--share=ipc"          # 进程间通信（X11 需要）
```

### 4.3 清理规则（cleanup）

构建后的文件中，以下内容会被删除以减小包体积：
- `/include`、`/man`、`*.vapi` 等开发文件
- `/lib/pkgconfig` 等 pkg-config 文件
- `/share/vala` 等 Vala 相关文件

## 五、常见问题排查

### 5.1 构建失败：缺少依赖

```
Run-time dependency xxx found: NO (tried pkgconfig and cmake)
```

**解决**：在 `com.github.samfic.filecollector.json` 的 `modules` 中添加缺失依赖的构建步骤，或确保 runtime 已包含该依赖。

### 5.2 构建失败：blueprint-compiler 版本不兼容

**解决**：更新 `com.github.samfic.filecollector.json` 中 `blueprint-compiler` 的 `tag` 字段。

### 5.3 本地安装时交互式提示

```
Configure this as new remote 'flathub' [Y/n]:
```

如果在自动化脚本中运行，可以预先添加 flathub 远程源避免提示：

```bash
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
```

### 5.4 文件路径不被 Git 跟踪

构建产生的 `*.flatpak`、`build-dir/`、`flatpak-repo/`、`.flatpak-builder/` 等均已包含在 `.gitignore` 中。如果希望保留某个版本的 bundle，手动复制到其他目录或发布到 GitHub Releases。

### 5.5 跨版本构建注意事项

从旧版本构建升级时，注意 `.flatpak-builder/` 缓存可能导致问题。使用 `--force-clean` 可确保完全重新构建。

## 六、快速参考命令

```bash
# ──────────────────────────────────────
# 仅本地安装验证
# ──────────────────────────────────────
flatpak-builder build-dir com.github.samfic.filecollector.json --user --install --force-clean

# ──────────────────────────────────────
# 生成分发文件
# ──────────────────────────────────────
flatpak-builder --repo=flatpak-repo build-dir com.github.samfic.filecollector.json --force-clean
flatpak build-bundle flatpak-repo filecollector-2.0.x.flatpak com.github.samfic.filecollector

# ──────────────────────────────────────
# 完整的版本发布流程
# ──────────────────────────────────────
# 1. git log 查看上一版本到现在的提交，总结更新内容
# 2. 编辑 meson.build 更新版本号
# 3. 编辑 metainfo.xml 添加发布记录
# 4. git add -A && git commit -m "release: vX.Y.Z"
# 5. git tag vX.Y.Z
# 6. 执行上面的构建 + bundle 命令
# 7. 上传 .flatpak 文件到 GitHub Releases
```
