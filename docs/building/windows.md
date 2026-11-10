# 本地构建 Windows 便携包

本文件只说明 Windows x64 便携包的本地复现与排错。正式发布由 GitHub Actions 统一完成：版本号仅从 `meson.build` 读取，推送 `v*` 标签后会自动构建四个平台并上传同一个 GitHub Release。请参阅 [桌面端自动打包与发布](../GITHUB_ACTIONS_DESKTOP.md)。

## 构建环境

在 **MSYS2 UCRT64** 终端中执行。CI 使用 `windows-latest` 与 UCRT64 工具链，建议本地也使用相同环境。

```bash
pacman -Syu
pacman -S --needed \
  mingw-w64-ucrt-x86_64-blueprint-compiler \
  mingw-w64-ucrt-x86_64-cmake \
  mingw-w64-ucrt-x86_64-gcc \
  mingw-w64-ucrt-x86_64-gtk4 \
  mingw-w64-ucrt-x86_64-gtksourceview5 \
  mingw-w64-ucrt-x86_64-json-glib \
  mingw-w64-ucrt-x86_64-libadwaita \
  mingw-w64-ucrt-x86_64-libgee \
  mingw-w64-ucrt-x86_64-libsecret \
  mingw-w64-ucrt-x86_64-libsoup3 \
  mingw-w64-ucrt-x86_64-meson \
  mingw-w64-ucrt-x86_64-ninja \
  mingw-w64-ucrt-x86_64-pkgconf \
  mingw-w64-ucrt-x86_64-vala unzip zip
```

## 构建与验证

在仓库根目录执行：

```bash
chmod +x tools/build-windows-package.sh
tools/build-windows-package.sh
```

脚本会下载并静态编译 cmark-gfm，运行 Meson 单元测试，递归收集 UCRT64 运行时 DLL（含 GTK 图像加载器的间接依赖）、GTK 动态模块、GSettings schema、完整 Adwaita/hicolor 图标主题、zh_CN 翻译文件（.mo）、项目实际使用的两个 XApp symbolic 图标，以及 ZIP 导出依赖的 zip.exe（含 msys-2.0.dll）。然后它会验证所有源码引用的 symbolic 图标都能在包内主题中解析，并在打包前后用 `tools/verify_windows_package.py` 对全部 PE 文件做导入表闭包校验；运行时 DLL 数量不足或存在未解析的非系统 DLL 时，构建直接失败。

> 注意：locale 与 zip.exe 曾因 MSYS2 参数路径转换（`meson --prefix=/usr` 的
> 参数被改写为 MSYS2 安装根下的路径）而静默缺失，导致 v4.9.1 及之前的
> Windows 包为纯英文界面且 ZIP 导出不可用。脚本现通过 `MSYS2_ARG_CONV_EXCL`
> 排除转换，并在打包后硬性校验 `locale/zh_CN/LC_MESSAGES/filecollector.mo`
> 与 `bin/zip.exe` 存在于 ZIP 内。

排错提示：DLL 收集脚本按 `MSYSTEM_PREFIX` 判定运行时目录，并用 `ldd` 递归解析依赖。若本地构建得到的 `bin/` 里几乎没有 DLL，先确认是在 MSYS2 **UCRT64** 终端中执行（`echo $MSYSTEM_PREFIX` 应为 `/ucrt64`），以及 `ldd staging/bin/filecollector.exe` 能正常解析。

产物为：

```text
dist/filecollector-windows-<meson.build 中的版本>-x64.zip
dist/filecollector-windows-<meson.build 中的版本>-x64.zip.sha256
```

## LibreOffice 转换器包（可选）

主包不捆绑 LibreOffice（体积原因）。Office 文档的**视觉转换**链路（soffice → PDF → pdftoppm → VLM）依赖 LibreOffice，通过独立的转换器包交付：

```bash
tools/build-converter-package.sh
```

脚本下载官方 LibreOffice MSI（版本固定于脚本内 `LO_VERSION`），用 `msiexec /a` 管理员解包（不写注册表、不进 Program Files），打包为：

```text
dist/filecollector-converter-windows-<LO_VERSION>-x64.zip
dist/filecollector-converter-windows-<LO_VERSION>-x64.zip.sha256
```

布局为 `tools/LibreOffice/program/soffice.exe`，解压到便携包根目录（与 `bin/` 同级）即生效；应用通过 `BinaryConverter.resolve_soffice()` 自动探测。CI 中该包在 main/tag 推送时构建，tag 推送时随 Release 发布。

注意：`msiexec` 的 `/a` 参数从 bash 直接传入会被 MSYS2 改写为路径（与 `--prefix=/usr` 同类陷阱），脚本通过 `cmd //c` 复合字符串绕过。

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
