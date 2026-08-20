# 本地构建 macOS ARM64 应用包

本文件用于在 Apple Silicon Mac 上复现和排查本地打包。正式发布由 GitHub Actions 统一完成：推送 `v*` 标签后，DEB、Flatpak、Windows x64 与 macOS ARM64 会同时构建；全部成功后才更新 GitHub Release。请参阅 [桌面端自动打包与发布](../GITHUB_ACTIONS_DESKTOP.md)。

## 前置条件

本地构建需要 Homebrew。打包脚本会自动安装 GTK4、libadwaita、GtkSourceView 5、cmark-gfm 和其他开发依赖，并从 Homebrew keg 中收集图标主题。

```bash
xcode-select --install
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

## 构建与验证

在仓库根目录执行：

```bash
chmod +x tools/build-macos-package.sh
tools/build-macos-package.sh
```

脚本会在 `macos-14` CI 环境同类的 Apple Silicon 环境中构建、运行测试、创建 `FileCollector.app`、复制运行时库和完整 Adwaita/hicolor 图标主题，并叠加两个项目实际使用的 XApp symbolic 图标。它会使用 ad-hoc 签名检查 bundle 完整性。

产物为：

```text
dist/filecollector-macos-<meson.build 中的版本>-arm64.zip
dist/filecollector-macos-<meson.build 中的版本>-arm64.zip.sha256
```

## 分发说明

当前产物使用 ad-hoc 签名，**未使用 Apple Developer ID 签名或公证**。在其他 Mac 上首次打开时，macOS 可能显示来自未验证开发者的提示；这属于当前分发方式的预期行为，而非构建失败。

## 清理

```bash
rm -rf build-macos install-macos dist
```

以上本地构建目录和 ZIP 文件均已由 `.gitignore` 忽略。
