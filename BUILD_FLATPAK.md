# FileCollector Flatpak 构建指南

> 本文档供 AI 编程助手在协助构建和发布 Flatpak 版本时参考。
> **AI 应自动化完成全部流程**：版本号更新、commit、tag、push、flatpak 构建、bundle 导出、GitHub Release 创建，无需用户手动执行任何步骤。

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

> **AI 执行说明**：以下所有步骤应由 AI 自动完成，无需用户手动操作。AI 应按顺序执行：查看 git 历史 → 更新版本号 → 更新 metainfo → commit → tag → push → flatpak 构建 → bundle 导出 → 安装验证 → GitHub Release 创建。

### 2.1 版本发布提交规范

**每次版本发布包含多个功能提交 + 1 个版本更新提交**：

1. **功能提交**：将代码变更提交到主分支（数量不限）
2. **发布提交**：修改版本号到 meson.build 和 metainfo.xml

**版本发布 commit 格式**：

```bash
git commit -m "release: v2.0.4"
```

> `metainfo.xml` 中的 `version` 属性为纯版本号（如 `2.0.4`），不含 `v` 前缀。

### 2.2 确定更新内容范围

在填写版本更新日志时，需要通过 Git 提交历史来确定新版本包含的变更：

```bash
# 查看当前版本与上一版本之间的所有提交
git log v2.0.3..HEAD --oneline

# 查看详细变更内容（用于总结更新日志）
git log v2.0.3..HEAD --stat --name-only
```

**版本阶段示例**（基于项目历史）：

| 版本   | 包含的提交（从旧到新）                     | 变更内容摘要                                       |
| ------ | ------------------------------------------ | -------------------------------------------------- |
| v2.0.2 | `2505ddc`                                  | 初始版本发布                                       |
| v2.0.3 | `2403273`, `ca99c89`                       | 添加剪贴板功能、重构常用语选择器                   |
| v2.0.4 | `c646de4`, `0dd54d6`, `4b6572e`, `fc586d0` | 添加 Flatpak 包下载、优化窗口布局、添加 Toast 提示 |

> 💡 **提示**：当 Git 提交记录中没有明确的版本标记时，请查看最近 20-50 条提交历史，结合 README 和代码变更来判断版本边界。通常版本号更新提交会包含 `meson.build` 和 `metainfo.xml` 的修改。

---

### 2.3 更新版本号

需要修改 **2 个文件**：

| 文件           | 修改内容                                                          |
| -------------- | ----------------------------------------------------------------- |
| `meson.build`  | 第 2 行 `version: 'x.y.z'`（此为唯一版本源）                      |
| `metainfo.xml` | 在 `<releases>` 内新增 `<release>` 条目，按版本号**从新到旧**排列，`date` 使用当天日期（格式 `YYYY-MM-DD`） |

`metainfo.xml` 新增条目的格式示例：

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

> 💡 `date` 属性使用当天日期，格式为 `YYYY-MM-DD`。

### 2.4 提交、打标签与推送

AI 应直接执行以下命令，无需询问用户：

```bash
git add meson.build data/io.github.sam_fic.filecollector.metainfo.xml
git commit -m "release: vX.Y.Z"
git tag vX.Y.Z
git push && git push origin vX.Y.Z
```

### 2.5 构建 Flatpak 包

#### 方式 A：仅本地安装（快速验证）

```bash
flatpak-builder build-dir io.github.sam_fic.filecollector.json --user --install --force-clean
```

- `build-dir/` 是临时构建目录（已在 `.gitignore` 中忽略）
- `--force-clean` 会删除旧的构建目录，避免缓存冲突
- `--user --install` 构建完成后自动安装到当前用户环境

#### 方式 B：构建可分发的 .flatpak 文件（用于发布）

> ⚠️ **重要说明**：`flatpak-builder --repo=flatpak-repo build-dir ...` 会创建两个独立的目录：
>
> - `build-dir/` — **构建目录**，存放编译产物（可被 `--force-clean` 清理，已在 `.gitignore` 中忽略）
> - `flatpak-repo/` — **仓库目录**，由 `--repo` 指定的地方，`build-bundle` 必须从此读取仓库数据
>
> 如果将 `build-dir` 误用作 `build-bundle` 的参数会报错：

```bash
# 步骤 1：构建到本地仓库
flatpak-builder --repo=flatpak-repo build-dir io.github.sam_fic.filecollector.json --force-clean

# 步骤 2：从本地仓库导出单文件 bundle
flatpak build-bundle flatpak-repo filecollector-2.0.4.flatpak io.github.sam_fic.filecollector
```

> ⚠️ **常见错误**：`build-bundle` 的第一个参数必须是 **本地仓库目录**（即 `--repo=` 指定的目录），**不是**构建目录 `build-dir/`。如果传入 `build-dir/` 会报错：
>
> ```
> error: 'build-dir' is not a valid repository: opening repo: opendir(objects): No such file or directory
> ```

### 2.6 验证构建结果

```bash
# 检查 bundle 文件大小
ls -lh filecollector-*.flatpak

# 确认 flathub 源已添加（首次需要）
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# 安装并运行验证
flatpak install --user --or-update -y filecollector-2.0.4.flatpak
flatpak run io.github.sam_fic.filecollector

# 确认 metainfo 中的版本号正确
flatpak info io.github.sam_fic.filecollector
```

> 💡 **交互式确认**：`flatpak install` 可能弹出确认提示 `[Y/n]`，在脚本中可添加 `--noninteractive` 标志：
>
> ```bash
> flatpak install --noninteractive --user --or-update filecollector-2.0.4.flatpak
> ```
>
> 💡 **验证构建结果**：
>
> ```bash
> # 检查 bundle 文件大小
> ls -lh filecollector-*.flatpak
>
> # 验证 metainfo 中的版本号
> flatpak info io.github.sam_fic.filecollector  # 安装后
> ```
>
> ```bash
> flatpak uninstall --user -y io.github.sam_fic.filecollector
> flatpak install --user filecollector-2.0.4.flatpak
> ```

### 2.7 构建可分发 .flatpak 文件

构建完成后，从仓库导出单文件 bundle：

```bash
flatpak build-bundle flatpak-repo filecollector-2.0.x.flatpak io.github.sam_fic.filecollector
```

### 2.8 修改源码后重新构建

如果在构建 flatpak **之后**又修改了源码（如添加 Website 链接、修正版本号等），**必须重新执行完整构建流程**（`flatpak-builder --repo=...` + `build-bundle`），否则安装的仍是旧构建。仅重新 `meson compile` 不会影响已安装的 flatpak 包。

## 三、项目结构说明

```
io.github.sam_fic.filecollector.json   ← Flatpak 构建清单（manifest）
meson.build                             ← Meson 构建配置（**唯一版本源**）
src/config.vala.in                      ← 版本号模板，meson 构建时从 meson.build 读取版本自动生成
data/
  io.github.sam_fic.filecollector.metainfo.xml  ← AppStream 元数据（版本记录在此）
```

### 构建清单结构

`io.github.sam_fic.filecollector.json` 包含两个模块：

1. **`blueprint-compiler`**：从 Git 源码构建 Blueprint 编译器（用于编译 `.blp` UI 文件）
2. **`filecollector`**：主应用，`"type": "dir", "path": "."` 表示使用本地源码

> 注意：在 CI/CD 环境中，`"type": "dir"` 可能无法使用，需要改用 `"type": "git"` 指向 GitHub 仓库。

## 四、构建配置的关键细节

### 4.1 运行时版本

当前使用 `org.gnome.Platform` **runtime-version: 50**（对应 GNOME 50）。

如果需要升级运行时版本（例如 GNOME 51 发布后），需要同时更新：

- `io.github.sam_fic.filecollector.json` 中的 `runtime-version`
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

**解决**：在 `io.github.sam_fic.filecollector.json` 的 `modules` 中添加缺失依赖的构建步骤，或确保 runtime 已包含该依赖。

### 5.2 构建失败：blueprint-compiler 版本不兼容

**解决**：更新 `io.github.sam_fic.filecollector.json` 中 `blueprint-compiler` 的 `tag` 字段。

### 5.3 本地安装时交互式提示

```
Configure this as new remote 'flathub' [Y/n]:
```

如果在自动化脚本中运行，可以预先添加 flathub 远程源避免提示：

```bash
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
```

### 5.4 网络超时/重试

构建时下载 Git 源（blueprint-compiler、cmark-gfm）可能因网络不稳定失败：

```bash
# 失败后直接重试即可，部分下载会被缓存
flatpak-builder --repo=flatpak-repo build-dir io.github.sam_fic.filecollector.json --force-clean
```

如果多次失败，可尝试手动预下载：

```bash
flatpak-builder --repo=flatpak-repo build-dir io.github.sam_fic.filecollector.json 2>&1 | tee build.log
```

### 5.5 文件路径不被 Git 跟踪

构建产生的 `*.flatpak`、`build-dir/`、`flatpak-repo/`、`.flatpak-builder/` 等均已包含在 `.gitignore` 中。如果希望保留某个版本的 bundle，手动复制到其他目录或发布到 GitHub Releases。

### 5.6 构建产物清理

构建产物不会自动清理，建议定期删除旧版本 bundle 以节省磁盘空间：

```bash
# 删除旧版本 bundle，保留当前版本
find . -name "filecollector-*.flatpak" ! -name "filecollector-4.3.0.flatpak" -delete

# 清理旧的 flatpak 安装（如有）
flatpak uninstall --user -y io.github.sam_fic.filecollector  # 重新安装新版本
```

### 5.7 跨版本构建注意事项

从旧版本构建升级时，注意 `.flatpak-builder/` 缓存可能导致问题。使用 `--force-clean` 可确保完全重新构建。

## 六、快速参考命令

> 以下所有步骤由 AI 自动执行，用户无需手动操作。

```bash
# ──────────────────────────────────────
# 完整的版本发布流程（AI 全自动执行）
# ──────────────────────────────────────
# 1. git log 查看上一版本到现在的提交，总结更新内容
# 2. 编辑 meson.build 更新版本号
# 3. 编辑 metainfo.xml 添加发布记录
# 4. git add meson.build data/io.github.sam_fic.filecollector.metainfo.xml && git commit -m "release: vX.Y.Z" && git tag vX.Y.Z && git push && git push origin vX.Y.Z
# 5. flatpak-builder --repo=flatpak-repo build-dir io.github.sam_fic.filecollector.json --force-clean
# 6. flatpak build-bundle flatpak-repo filecollector-X.Y.Z.flatpak io.github.sam_fic.filecollector
# 7. flatpak install --user --or-update -y filecollector-X.Y.Z.flatpak
# 8. gh release create vX.Y.Z --title "FileCollector vX.Y.Z" --notes "..." filecollector-X.Y.Z.flatpak

# ──────────────────────────────────────
# 仅本地安装验证（快速开发测试）
# ──────────────────────────────────────
flatpak-builder build-dir io.github.sam_fic.filecollector.json --user --install --force-clean
```

---

## 七、发布到 GitHub Releases

AI 应使用 `gh` CLI 自动完成，无需用户手动操作。

### 7.1 前置检查

```bash
# 确认 gh 已安装
gh --version

# 确认已登录（未登录则提示）
gh auth status 2>&1 || {
  echo "未登录 GitHub CLI，请先执行 gh auth login"
  exit 1
}
```

### 7.2 创建 Release

创建 Release 并上传 Flatpak bundle（注意格式按照模板写，中英文日志都有冒号）：

```bash
gh release create vX.Y.Z --title "FileCollector vX.Y.Z" --notes "$(cat <<'EOF'
### 主要改进

- **简洁描述**：详细内容
- **简洁描述**：详细内容
- **简洁描述**：详细内容

### Improvements

- **Brief description**: Detailed content
- **Brief description**: Detailed content
- **Brief description**: Detailed content

EOF
)" filecollector-X.Y.Z.flatpak
```

> 💡 Release notes 内容应从 `metainfo.xml` 的 `<release>` 条目中提取，保持一致。
