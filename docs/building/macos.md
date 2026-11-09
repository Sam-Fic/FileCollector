# 本地构建 macOS ARM64 应用包

本文件用于在 Apple Silicon Mac 上复现和排查本地打包。正式发布由 GitHub Actions 统一完成：推送 `v*` 标签后，DEB、Flatpak、Windows x64 与 macOS ARM64 会同时构建；全部成功后才更新 GitHub Release。请参阅 [桌面端自动打包与发布](../GITHUB_ACTIONS_DESKTOP.md)。

## 系统要求

产物要求 **macOS 15 (Sequoia) 及以上**。CI 使用的 `macos-latest` 运行器上，Homebrew bottle 以 macOS 15 为部署目标，`Info.plist` 的 `LSMinimumSystemVersion` 与此保持一致（历史上声明 14.0 但 bottle 实际不兼容 macOS 14，会在启动时报 dyld 符号错误）。

## 前置条件

本地构建需要 Homebrew。打包脚本会自动安装 GTK4、libadwaita、GtkSourceView 5、cmark-gfm 和其他开发依赖，并从 Homebrew keg 中收集图标主题。libsecret 不再需要（macOS 走 Keychain，libsecret 仅 Linux 必选）。

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

脚本会在与 `macos-latest` CI 同类的 Apple Silicon 环境中构建、运行测试、创建 `FileCollector.app`，并做以下打包处理：

- **dylib 依赖闭包**：`tools/fix_rpaths.py` 把主程序与动态加载模块的全部非系统依赖（含 Homebrew bottle 里以 `@rpath` 形式引用的 brotli/webp/cmark-gfm 等传递依赖）收集进 `Contents/MacOS/`，统一改写为 `@executable_path` 相对引用，并删除所有 `LC_RPATH`。
- **GIO TLS 模块**：`libgiognutls.so`（glib-networking）复制到 `Contents/Resources/lib/gio/modules/`，`main.vala` 启动时设置 `GIO_MODULE_DIR` 指向它；缺失会导致无 Homebrew 机器上 libsoup 报 "no TLS support"，所有 AI 功能失效。
- **pixbuf loaders**：全部 loader 插件复制到 `Contents/Resources/lib/gdk-pixbuf-2.0/2.10.0/loaders/`，并生成路径已改写为 `@executable_path` 的 `loaders.cache`（启动时经 `GDK_PIXBUF_MODULE_FILE` 生效）；缺失会导致图片加载（多模态/VLM 输入）与 SVG 图标失效。
- **fontconfig 配置**：复制 Homebrew `etc/fonts` 并注入 Apple 系统字体目录（`/System/Library/Fonts` 等）、cachedir 改为用户 XDG 目录（启动时经 `FONTCONFIG_FILE` 生效）；缺失会导致干净机器上无字体可用。
- **图标主题与翻译**：完整 Adwaita/hicolor 主题随包分发并叠加项目 XApp symbolic 图标；`zh_CN` locale 位于 `Contents/Resources/locale/`。
- **Dock 图标**：由项目 SVG 经 `rsvg-convert` + `iconutil` 生成 `FileCollector.icns`。

签名与验证环节：

- `tools/verify_macos_package.py` 解析全部 Mach-O 加载命令做静态依赖闭包审计：任何 `@rpath`/`LC_RPATH`/指向构建机的引用/缺失依赖都会让构建失败；
- ad-hoc 签名检查 bundle 完整性；
- 无头冒烟测试：`fc-list` 用包内配置验证字体可见，`broadwayd` + `GDK_BACKEND=broadway` 真正拉起应用 20 秒，捕捉 dyld/GTK 初始化级失败。

产物为：

```text
dist/filecollector-macos-<meson.build 中的版本>-arm64.zip
dist/filecollector-macos-<meson.build 中的版本>-arm64.zip.sha256
```

## 外部功能依赖（不随包分发）

以下功能依赖外部命令行工具，用户机器上未安装时对应功能静默降级：

| 功能 | 依赖 | 安装 |
| --- | --- | --- |
| PDF / Office 文件转图片（多模态输入） | `pdftoppm`（poppler） | `brew install poppler` |
| Office 文档转 PDF | `soffice`（LibreOffice） | 安装 LibreOffice.app |
| Git 历史面板 | `git` | `brew install git` 或 Xcode Command Line Tools |

## 分发说明

当前产物使用 ad-hoc 签名，**未使用 Apple Developer ID 签名或公证**。在其他 Mac 上首次打开时，macOS 可能显示来自未验证开发者的提示（右键 → 打开，或在系统设置中允许）；这属于当前分发方式的预期行为，而非构建失败。

## 清理

```bash
rm -rf build-macos install-macos dist
```

以上本地构建目录和 ZIP 文件均已由 `.gitignore` 忽略。
