# FileCollector Windows 构建指南

> 本文档供 AI 编程助手在协助构建和发布 Windows 版本时参考。
> **AI 应自动化完成全部流程**：在 Flatpak 版本已发布的**基础上**，构建 Windows 二进制、打包为便携 zip、并上传到**已有的最新 Release**，无需用户手动执行任何步骤。
>
> ⚠️ **流程顺序约定**：本项目的发布流程**默认先打包 Flatpak，再打包 Windows 版本**。即：
> 1. 先按 `BUILD_FLATPAK.md` 完成版本号更新、commit、tag、push、Flatpak 构建、bundle 导出、**创建 GitHub Release**；
> 2. 本文档的流程**不新建 Release**，而是把 Windows 包**追加上传到最新一次 Release**（即 Flatpak 已创建的那个）。

## 一、前置条件

确保本机已安装 **MSYS2**（推荐）并配置好 MINGW64 环境：

```bash
# 检查 MSYS2 与 MINGW64 工具链（在 MSYS2 MINGW64 终端中执行）
pacman -S --needed base-devel mingw-w64-x86_64-toolchain
mingw-w64-x86_64-meson --version
mingw-w64-x86_64-ninja --version
gcc --version
```

需要安装的运行/构建依赖（MINGW64）：

```bash
pacman -S --needed \
  mingw-w64-x86_64-meson \
  mingw-w64-x86_64-ninja \
  mingw-w64-x86_64-gcc \
  mingw-w64-x86_64-pkgconf \
  mingw-w64-x86_64-gtk4 \
  mingw-w64-x86_64-libadwaita \
  mingw-w64-x86_64-json-glib \
  mingw-w64-x86_64-libsoup3 \
  mingw-w64-x86_64-libgee \
  mingw-w64-x86_64-gtksourceview5 \
  mingw-w64-x86_64-blueprint-compiler \
  mingw-w64-x86_64-gettext \
  mingw-w64-x86_64-libsecret \
  mingw-w64-x86_64-cmake \
  zip          # 打包用（注意：MINGW64 默认不带 zip，需显式安装）
```

> ⚠️ **`zip` 是必需的**：本地打包步骤使用 `zip -r`，但 MINGW64 基础环境默认**不安装** `zip`。
> 若未安装会报 `zip: 未找到命令`。CI（`windows.yml`）中能使用是因为 msys2 基础镜像已包含。
> 验证时可用 `unzip`（同样需 `pacman -S unzip`）。
>
> 💡 **非 UTF-8 区域设置的 Windows（如中文 GBK）必须设置 UTF-8**：本机若系统区域为 GBK/CP936，
> Python 读 `src/window.blp` 等源文件时会用 GBK 解码而崩溃（`UnicodeDecodeError: 'gbk' codec`）。
> 构建前务必导出：
>
> ```bash
> export PYTHONUTF8=1      # 强制 Python 以 UTF-8 读写文件
> export LANG=C.UTF-8      # 同时设置 locale 为 UTF-8
> ```
>
> 在标准的 MSYS2 MINGW64 终端中默认即为 UTF-8，通常无需手动设置；但从 PowerShell / 外部调用
> `bash -lc` 时 locale 会回落到系统 ANSI 编码，必须设置上述变量。
>
> 💡 **`ldd` 必须在 PATH 中**：`tools/collect_dlls.py` 通过 `ldd` 收集 DLL，`ldd` 位于 `/usr/bin`
> （不属于 `/mingw64/bin`）。请始终在完整的 MINGW64 终端中执行本流程，确保 `/usr/bin` 在 PATH 中。

> 💡 上述依赖与 `.github/workflows/windows.yml` 中的 `install:` 列表保持一致，本地构建与 CI 结果应一致。
> 在 MSYS2 中请始终使用 **MINGW64** 终端（开始菜单 → `MSYS2 MINGW64`），不要使用默认的 MSYS/UCRT64 终端，否则会链接到错误的运行时。

## 二、版本发布完整流程

> **AI 执行说明**：以下所有步骤应由 AI 自动完成，无需用户手动操作。
> **前置前提**：Flatpak 版本的发布流程（`BUILD_FLATPAK.md`）已经完成，即 Git 上已经存在 `vX.Y.Z` 的 tag，且 GitHub 上已经存在对应的最新 Release。
>
> AI 应按顺序执行：确认最新 Release 存在 → 构建 Windows 二进制 → 打包便携 zip → 验证 → 上传到最新 Release。

### 2.1 确认最新 Release 已存在

Windows 包是**追加**到已有 Release，因此第一步必须确认 Flatpak 流程已经创建好了 Release：

```bash
# 确认 gh 已登录
gh auth status 2>&1 || { echo "未登录 GitHub CLI，请先执行 gh auth login"; exit 1; }

# 查看最新一次 Release（Flatpak 流程已创建）
gh release list --limit 1

# 记录其 tag，后续所有上传都指向该 tag
LATEST_TAG=$(gh release list --limit 1 --json tagName --jq '.[0].tagName')
echo "最新 Release tag: $LATEST_TAG"
```

> ⚠️ **如果 `gh release list` 为空**（说明 Flatpak 流程还没跑完），请先完成 `BUILD_FLATPAK.md` 的 2.4–2.8 与第七章，**不要**在本流程中新建 Release。本流程只负责“追加上传”。

### 2.2 构建 cmark-gfm（Windows 需源码编译）

Windows 环境下没有现成的 cmark-gfm 包，必须从源码编译（与 `windows.yml` 一致）：

```bash
curl -L -o /tmp/cmark-gfm.tar.gz https://github.com/github/cmark-gfm/archive/refs/tags/0.29.0.gfm.13.tar.gz
tar -xzf /tmp/cmark-gfm.tar.gz -C /tmp
cmake -S /tmp/cmark-gfm-0.29.0.gfm.13 -B /tmp/cmark-gfm-build \
  -G "MSYS Makefiles" -DCMAKE_INSTALL_PREFIX=/usr/local \
  -DCMARK_TESTS=OFF -DCMARK_STATIC=ON
cmake --build /tmp/cmark-gfm-build
cmake --install /tmp/cmark-gfm-build
```

> 如果 `/tmp` 不可写（部分 Windows 环境），可改用 `$TMPDIR` 或项目内的临时目录。

### 2.3 使用 Meson 构建 Windows 二进制

```bash
# 非 UTF-8 区域设置的 Windows（如中文 GBK）必须设置，否则 blueprint-compiler 会崩溃
export PYTHONUTF8=1
export LANG=C.UTF-8

# 清理旧构建目录，避免缓存冲突
rm -rf build

# 配置并编译（host_machine.system() 会自动识别为 windows，
# meson.build 会启用 -DWINDOWS 宏与 advapi32/crypt32 链接参数）
meson setup build
meson compile -C build
```

构建产物为 `build/filecollector.exe`。

> 💡 若 configure 阶段找不到蓝图编译器或 cmark 头文件，请确认 `blueprint-compiler` 已安装且 cmark-gfm 2.2 节已正确安装到 `/usr/local`。

### 2.4 打包便携 zip（含 DLL 与资源）

应用是**便携版**，需要把 exe、依赖 DLL、data、locale 一起打包：

```bash
# 创建临时打包目录
mkdir -p staging/bin
cp build/filecollector.exe staging/bin/

# 自动收集 MinGW 运行时 DLL 到 exe 同目录
python3 tools/collect_dlls.py staging/bin/filecollector.exe staging/bin

# 拷贝资源目录（data 含 .gresource / desktop / metainfo / svg，locale 含翻译）
mkdir -p staging/share
cp -r data staging/share/ 2>/dev/null || true
cp -r locale staging/ 2>/dev/null || true

# ── 以下为运行时“动态加载”的组件，ldd 看不到，collect_dlls.py 也不会收集，
#    但 GTK 启动时必须存在，否则图标/图片/设置会异常 ──

# 1) gdk-pixbuf 图像加载器（PNG/JPEG/GIF/... 格式支持）及其缓存
#    GTK 按 libgdk_pixbuf DLL 的位置（staging/bin）回退查找 staging/lib/...
mkdir -p staging/lib/gdk-pixbuf-2.0/2.10.0/loaders
cp /mingw64/lib/gdk-pixbuf-2.0/2.10.0/loaders/*.dll staging/lib/gdk-pixbuf-2.0/2.10.0/loaders/ 2>/dev/null || true
cp /mingw64/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache staging/lib/gdk-pixbuf-2.0/2.10.0/ 2>/dev/null || true

# 2) 编译后的 GSettings schema（应用设置/主题依赖，缺失则回落默认值）
#    GTK 按 libglib DLL 位置回退查找 staging/share/glib-2.0/schemas/...
mkdir -p staging/share/glib-2.0/schemas
cp /mingw64/share/glib-2.0/schemas/gschemas.compiled staging/share/glib-2.0/schemas/ 2>/dev/null || true

# 3) 启动器：设置 GDK_PIXBUF_MODULEDIR 后启动 exe。
#    gdk-pixbuf 的 loaders.cache 内是“构建机绝对路径”，在他人电脑上失效；
#    通过此变量让 GTK 直接扫描我们打包的 loaders 目录，图片格式（PNG/JPEG…）才能正常加载。
#    别人解压后请双击本启动器（而非直接双击 exe）。
cat > staging/bin/filecollector-launch.bat <<'BAT'
@echo off
set GDK_PIXBUF_MODULEDIR=%~dp0lib\gdk-pixbuf-2.0\2.10.0\loaders
start "" "%~dp0filecollector.exe" %*
BAT

# 打包为 zip，文件名带版本号（与 Flatpak 的 filecollector-X.Y.Z.flatpak 对应）
VERSION=$(grep -m1 "version:" meson.build | sed "s/.*version:[[:space:]]*'\([^']*\)'.*/\1/")
cd staging && zip -r ../filecollector-windows-${VERSION}-x64.zip . && cd ..
```

最终产物：`filecollector-windows-X.Y.Z-x64.zip`。

> ⚠️ **关于“别人下载后能否直接双击运行”**：便携包已自带全部 MinGW 运行时 DLL（GTK/Adwaita 等），
> 且 MinGW 链接的是 Windows 自带通用 C 运行时（ucrtbase 等，Win10/11 内置），因此
> **无需在目标机器上安装 MSYS2、GTK 或 Visual C++ Redistributable**。
> - **推荐**：解压后双击 `bin/filecollector-launch.bat` 启动（它会设置 `GDK_PIXBUF_MODULEDIR`，保证图片格式正常加载）。
> - 直接双击 `bin/filecollector.exe` 也能打开窗口，但图像文件（PNG/JPEG 等）渲染可能异常，因为
>   `loaders.cache` 内是构建机的绝对路径、在他人电脑上失效。`filecollector-launch.bat` 解决了这一点。
> 详见上文第 1、2、3 步（gdk-pixbuf 加载器、GSettings schema、启动器）。

> 💡 版本号从 `meson.build` 第 2 行的 `version: 'x.y.z'` 读取（这是**唯一版本源**，与 Flatpak 共用），确保 Windows 包版本与 Flatpak 包版本一致。

### 2.5 验证打包结果

```bash
# 检查 zip 大小与内容
ls -lh filecollector-windows-*.zip
unzip -l filecollector-windows-*.zip | head -n 20

# 确认关键的运行时模块都在 zip 内
unzip -l filecollector-windows-*.zip | grep -E "loaders/|gschemas.compiled|libgtk-4-1|libadwaita"

# （可选）在 Windows 上解压后双击 filecollector.exe 验证能否启动
```

> 💡 `tools/collect_dlls.py` 通过 `ldd`/依赖分析自动拷贝 MinGW 的 GTK/Adwaita 等**静态链接** DLL。
> 但 GTK 还会**动态加载** gdk-pixbuf 图像加载器与 GSettings schema（见上文第 1、2 步），
> 这两类不在 `ldd` 依赖树中，必须单独拷贝。

### 2.6 修改源码后重新构建

如果在构建 Windows 包**之后**又修改了源码，**必须重新执行完整构建流程**（`meson setup build` + `meson compile` + 重新打包 zip），否则上传的仍是旧构建。仅重新 `meson compile` 若 `build/` 未被清理通常可增量，但打包前务必确认 `staging/` 已被清空重建。

## 三、项目结构说明

```
meson.build                                  ← Meson 构建配置（**唯一版本源**，Windows 与 Flatpak 共用）
src/config.vala.in                           ← 版本号模板，构建时从 meson.build 读取版本自动生成
src/win32_dpapi_shim.c                       ← Windows DPAPI (CryptProtectData) 封装
tools/collect_dlls.py                        ← 自动收集 MinGW 运行时 DLL 到 exe 目录
.github/workflows/windows.yml                ← Windows CI 构建工作流（本地构建步骤与其一致）
.github/workflows/release.yml                ← 多平台发布工作流（含 gh release 上传）
```

> 在 `meson.build` 中，`host_machine.system() == 'windows'` 分支会：
> - 给 Vala 传递 `-DWINDOWS` 宏
> - 额外链接 `-ladvapi32 -lcrypt32`（DPAPI 加密密钥）
> - 强制先包含 `windows.h` / `dpapi.h`，避免 Vala 生成的头文件顺序导致编译失败

## 四、构建配置的关键细节

### 4.1 GTK4 / Libadwaita 运行时版本

Windows 包依赖 MINGW64 提供的 `gtk4` 与 `libadwaita`。若 Flatpak 侧升级了 GNOME 运行时（见 `BUILD_FLATPAK.md` 4.1），本地 MINGW64 也应尽量保持相近版本，避免两端行为差异。

### 4.2 密钥存储（Windows 分支）

Windows 下不使用 libsecret，而是用 `src/win32_dpapi_shim.c` + `advapi32`/`crypt32` 走系统 DPAPI 加密。无需额外安装密钥环组件。

### 4.3 打包目录结构（便携版）

```
filecollector-windows-X.Y.Z-x64.zip
├── bin/
│   ├── filecollector.exe
│   ├── *.dll                       ← MinGW GTK/Adwaita 等运行时（由 collect_dlls.py 收集）
│   └── ...
├── share/
│   └── data/                       ← .gresource / desktop / metainfo / svg
└── locale/                         ← 翻译 .mo 文件
```

## 五、常见问题排查

### 5.1 构建失败：找不到 cmark-gfm 头文件

```
Run-time dependency cmark-gfm found: NO
```

**解决**：确认 2.2 节已从源码编译并 `cmake --install` 到 `/usr/local`，且 `pkgconf` 能找到 `cmark-gfm.pc`。可在 MINGW64 终端执行 `pkg-config --modversion cmark-gfm` 验证。

### 5.2 编译失败：dpapi.h / windows.h 宏未定义

**解决**：`meson.build` 已通过 `-include windows.h -include dpapi.h` 与 `-D_WIN32_WINNT=0x0A00` 处理。若仍报错，确认使用的是 MINGW64（不是 UCRT64/CLANG64）终端。

### 5.3 运行失败：缺少 DLL

双击 exe 报“由于找不到 xxx.dll，无法继续执行代码”。

**解决**：`tools/collect_dlls.py` 未覆盖到该 DLL。可手动从 MINGW64 的 `bin/` 目录拷贝缺失 DLL 到 `staging/bin/`，并排查 `collect_dlls.py` 的依赖解析逻辑。

### 5.4 网络超时/重试（cmark-gfm 下载）

2.2 节从 GitHub 下载 cmark-gfm 源码可能超时：

```bash
# 失败后直接重试即可，已下载的部分通常会命中缓存
curl -L -o /tmp/cmark-gfm.tar.gz https://github.com/github/cmark-gfm/archive/refs/tags/0.29.0.gfm.13.tar.gz
```

### 5.5 打包产物清理

```bash
# 删除旧版本 zip，保留当前版本
find . -name "filecollector-windows-*.zip" ! -name "filecollector-windows-X.Y.Z-x64.zip" -delete

# 清理构建与打包目录
rm -rf build staging
```

> 💡 构建产生的 `build/`、`staging/`、`*.zip` 等应加入 `.gitignore`（参考 `BUILD_FLATPAK.md` 5.5），避免误提交。保留某个版本请手动发布到 GitHub Releases。

## 六、快速参考命令

> 以下所有步骤由 AI 自动执行，用户无需手动操作。
> **前提**：Flatpak 流程已完成并创建了最新 Release。

```bash
# ──────────────────────────────────────
# 完整的 Windows 版本发布流程（AI 全自动执行）
# ──────────────────────────────────────
# 0. export PYTHONUTF8=1 && export LANG=C.UTF-8   # 非 UTF-8 区域（如中文 GBK）必须
# 1. gh auth status 确认已登录
# 2. LATEST_TAG=$(gh release list --limit 1 --json tagName --jq '.[0].tagName')  确认最新 Release 存在
# 3. 编译并安装 cmark-gfm（见 2.2）
# 4. rm -rf build && meson setup build && meson compile -C build
# 5. 打包便携 zip（见 2.4）-> filecollector-windows-X.Y.Z-x64.zip
# 6. ls -lh / unzip -l 验证产物
# 7. gh release upload "$LATEST_TAG" filecollector-windows-X.Y.Z-x64.zip
#    # 注意：是 upload 到已有 Release，不是 create 新 Release

# ──────────────────────────────────────
# 仅本地构建验证（快速开发测试，不上传）
# ──────────────────────────────────────
export PYTHONUTF8=1 && export LANG=C.UTF-8
rm -rf build && meson setup build && meson compile -C build
./build/filecollector.exe
```

---

## 七、上传到 GitHub Releases（追加到最新 Release）

> ⚠️ **本流程不创建新 Release**。Flatpak 流程（`BUILD_FLATPAK.md` 第七章）已经用
> `gh release create vX.Y.Z ...` 创建了 Release 并上传了 `.flatpak` 包。
> 本步骤只把 Windows 包**追加上传到那个最新 Release**。

### 7.1 前置检查

```bash
# 确认 gh 已安装
gh --version

# 确认已登录
gh auth status 2>&1 || {
  echo "未登录 GitHub CLI，请先执行 gh auth login"
  exit 1
}
```

### 7.2 上传到最新 Release

先确定最新 Release 的 tag（即 Flatpak 流程创建的那个），再追加上传：

```bash
# 获取最新一次 Release 的 tag（Flatpak 流程已创建）
LATEST_TAG=$(gh release list --limit 1 --json tagName --jq '.[0].tagName')
echo "将上传到最新 Release: $LATEST_TAG"

# 追加上传 Windows 包（不会覆盖已有的 .flatpak 等资产）
VERSION=$(grep -m1 "version:" meson.build | sed "s/.*version:[[:space:]]*'\([^']*\)'.*/\1/")
gh release upload "$LATEST_TAG" "filecollector-windows-${VERSION}-x64.zip"
```

> 💡 **`gh release upload` vs `gh release create`**：
> - **不要**使用 `gh release create` —— 会重复创建 Release 导致冲突。
> - 使用 `gh release upload <tag> <file>` 把资产追加到指定 tag 的已有 Release。
> - 这里 `<tag>` 一律取**最新一次 Release**（即 Flatpak 刚创建的 `vX.Y.Z`），从而保证 Windows 包与 Flatpak 包落在同一个版本发布下。

### 7.3 验证上传结果

```bash
# 列出该 Release 的所有资产，确认 Windows 包已存在
gh release view "$LATEST_TAG" --json assets --jq '.assets[].name'
```

> 💡 如果上传后发现包有问题，可先 `gh release delete-asset "$LATEST_TAG" filecollector-windows-X.Y.Z-x64.zip` 删除资产，再重新 `gh release upload`。注意不要删除 Flatpak 的 `.flatpak` 资产。
