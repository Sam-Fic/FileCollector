# 本地构建 Windows 便携包

本文件只说明 Windows x64 便携包的本地复现与排错。正式发布由 GitHub Actions 统一完成：版本号仅从 `meson.build` 读取，推送 `v*` 标签后会自动构建四个平台并上传同一个 GitHub Release。请参阅 [桌面端自动打包与发布](../GITHUB_ACTIONS_DESKTOP.md)。

## 构建环境

在 **MSYS2 MINGW64** 终端中执行。CI 使用 `windows-latest` 与 MINGW64 工具链，建议本地也使用相同环境。

```bash
pacman -Syu
pacman -S --needed \
  mingw-w64-x86_64-blueprint-compiler \
  mingw-w64-x86_64-cmake \
  mingw-w64-x86_64-gcc \
  mingw-w64-x86_64-gtk4 \
  mingw-w64-x86_64-gtksourceview5 \
  mingw-w64-x86_64-json-glib \
  mingw-w64-x86_64-libadwaita \
  mingw-w64-x86_64-libgee \
  mingw-w64-x86_64-libsecret \
  mingw-w64-x86_64-libsoup3 \
  mingw-w64-x86_64-meson \
  mingw-w64-x86_64-ninja \
  mingw-w64-x86_64-pkgconf \
  mingw-w64-x86_64-vala unzip zip
```

## 构建与验证

在仓库根目录执行：

```bash
chmod +x tools/build-windows-package.sh
tools/build-windows-package.sh
```

脚本会下载并静态编译 cmark-gfm，运行 Meson 单元测试，收集 MinGW 动态库、GTK 动态模块、GSettings schema、完整 Adwaita/hicolor 图标主题，以及项目实际使用的两个 XApp symbolic 图标。然后它会验证所有源码引用的 symbolic 图标都能在包内主题中解析。

产物为：

```text
dist/filecollector-windows-<meson.build 中的版本>-x64.zip
dist/filecollector-windows-<meson.build 中的版本>-x64.zip.sha256
```

## 试运行

将 ZIP 解压后，始终通过下列启动器启动：

```text
bin/filecollector-launch.bat
```

该启动器设置图像加载器和 GIO TLS 模块路径。不要直接双击 `filecollector.exe` 作为便携包功能的验证方式。

## 清理

```bash
rm -rf build-windows staging install-windows dist
```

这些本地构建目录和 ZIP 均已被 `.gitignore` 忽略。
