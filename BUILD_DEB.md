# 构建与发布 deb 包（Debian / Ubuntu）

> 本文档供 AI 编程助手在协助构建和发布 Debian 版本时参考。
> **AI 应自动化完成全部流程**：在 Flatpak 版本已发布的**基础上**，构建 `.deb`、并上传到
> **已有的最新 Release**，无需用户手动执行任何步骤。
>
> ⚠️ **前置前提**：`BUILD_FLATPAK.md` 的发布流程（版本号更新 → commit → 打 `vX.Y.Z` 标签
> → push → Flatpak 构建 → 导出 bundle → **创建 GitHub Release**）**已经完成**。即 Git 上
> 已经存在 `vX.Y.Z` 的 tag，且 GitHub 上已经存在对应的最新 Release。
>
> 📦 **发布约定**：本项目的发布流程**默认先打包 Flatpak，再打包 deb**（与
> `BUILD_WINDOWS.md` 的 Windows 版本一致）。deb 流程**不打新版本号、不打标签、不新建
> Release**，而是把 deb 包**追加上传到最新一次 Release**（即 Flatpak 已创建的那个）。

---

## 1. 前置条件

### 1.1 构建依赖（开发库）

本应用基于 GTK4 / libadwaita，构建需要以下工具与开发包（已在当前环境验证）：

```bash
sudo apt update
sudo apt install -y \
    meson ninja-build valac \
    libgtk-4-dev libadwaita-1-dev \
    libjson-glib-dev libsoup-3.0-dev \
    libgee-0.8-dev libsecret-1-dev \
    libcmark-gfm-dev libcmark-gfm-extensions-dev \
    libgtksourceview-5-dev \
    blueprint-compiler gettext \
    pkg-config
```

打包工具：

```bash
sudo apt install -y dpkg-dev dpkg-deb
```

### 1.2 运行时依赖（打包进 `.deb` 的 `Depends`）

通过 `dpkg-shlibdeps` 对编译产物 `filecollector` 二进制分析得到（当前环境实测）：

```
libadwaita-1-0 (>= 1.9~beta), libc6 (>= 2.38), libcairo2 (>= 1.2.4),
libcmark-gfm-extensions0.29.0.gfm.13 (>= 0.29.0.gfm.13),
libcmark-gfm0.29.0.gfm.13 (>= 0.29.0.gfm.13),
libgdk-pixbuf-2.0-0 (>= 2.22.0), libgee-0.8-2 (>= 0.8.3),
libglib2.0-0t64 (>= 2.76.0), libgtk-4-1 (>= 4.12.0),
libgtksourceview-5-0 (>= 2.91.4), libjson-glib-1.0-0 (>= 1.5.2),
libpango-1.0-0 (>= 1.14.0), libsecret-1-0 (>= 0.7),
libsoup-3.0-0 (>= 3.0.3)
```

> 注意：不同发行版 / 版本的包名（尤其是 `cmark-gfm` 的 SONAME）可能不同。
> 强烈建议每次构建都用第 3 节的 `dpkg-shlibdeps` 重新生成 `Depends`，
> 不要手工硬编码。

---

## 2. 完整发布流程（deb 在 Flatpak 之后）

> **版本号、commit、tag、`vX.Y.Z` 标签与 GitHub Release 都由 `BUILD_FLATPAK.md` 负责。**
> deb 流程不重复这些步骤。版本号信息（如 `4.6.0`）仅用于命名产物和 `DEBIAN/control`，
> **直接沿用 Flatpak 已发布的版本**，deb 流程本身不改动它们。

deb 流程只有两步：

1. **构建** `.deb`（见第 3 节）。
2. **上传**到现有最新 Release（见第 4 节）。

### 步骤 0：确认前置前提已满足

```bash
cd /home/sam/Desktop/filecollector   # 仓库根目录
git status                           # 确认工作区干净（deb 不新增提交/tag）

# 确认 Flatpak 已创建的最新 Release 标签存在
LATEST=$(gh release list --limit 1 --json tagName --jq '.[0].tagName')
echo "目标 Release 标签: $LATEST"     # 应形如 v4.6.0，与 Flatpak 一致
```

> 若上一步取不到标签 / Release，说明 **Flatpak 流程尚未完成**：请先按
> `BUILD_FLATPAK.md` 发布 Flatpak 版本（含创建 GitHub Release），再回来执行 deb 流程。
> **deb 流程绝不自行创建 Release。**

### 步骤 1：构建 `.deb`

见第 3 节。产物命名形如 `filecollector_4.6.0_amd64.deb`，版本号与 Flatpak 保持一致。

### 步骤 2：上传到现有最新 Release（追加，不新建）

见第 4 节。deb 包作为资产**追加到 Flatpak 已创建的那个最新 Release**，不会创建新 Release。

---

## 3. 从源码构建 `.deb`

采用 **meson + DESTDIR 暂存 + dpkg-deb** 的标准方式（无需 `debian/` 源码包结构）。

### 3.1 配置与编译

```bash
# 清理旧构建（可选）
rm -rf build deb-root

# 配置：安装前缀必须为 /usr，符合 FHS 与 deb 规范
meson setup build --prefix=/usr --buildtype=release

# 编译
meson compile -C build
```

### 3.2 安装到暂存目录（DESTDIR）

```bash
DESTDIR=$PWD/deb-root meson install -C build
```

安装完成后暂存目录结构（实测）：

```
deb-root/
└── usr/
    ├── bin/filecollector
    ├── share/applications/io.github.sam_fic.filecollector.desktop
    ├── share/icons/hicolor/scalable/apps/io.github.sam_fic.filecollector.svg
    ├── share/locale/zh_CN/LC_MESSAGES/filecollector.mo
    └── share/metainfo/io.github.sam_fic.filecollector.metainfo.xml
```

> 应用图标、.desktop、metainfo、翻译均已由 `meson install` 安装到标准路径，
> 无需手工复制。本应用未定义私有 GSettings schema，故无需 `glib-compile-schemas`
> 的 postinst 脚本。

### 3.3 生成 `DEBIAN/control`（自动计算依赖）

先创建 `DEBIAN` 目录，并用 `dpkg-shlibdeps` 让系统自动算出 `Depends`：

```bash
mkdir -p deb-root/DEBIAN

# 临时 debian/control 供 dpkg-shlibdeps 读取（用完即删）
mkdir -p debian && cat > debian/control <<'EOF'
Source: filecollector
Section: utils
Priority: optional
Maintainer: Sam-Fic <2401894494@qq.com>

Package: filecollector
Architecture: amd64
Description: File Collector
 A tool to collect files.
EOF

# 输出形如：shlibs:Depends=libadwaita-1-0 (>= ...) ...
dpkg-shlibdeps -O deb-root/usr/bin/filecollector

rm -rf debian   # 清理临时文件，避免污染仓库
```

把上一步 `shlibs:Depends=` 后面的值填入正式 `DEBIAN/control`：

```bash
cat > deb-root/DEBIAN/control <<'EOF'
Package: filecollector
Version: 4.6.0
Section: utils
Priority: optional
Architecture: amd64
Maintainer: Sam-Fic <2401894494@qq.com>
Homepage: https://github.com/Sam-Fic/filecollector
Depends: libadwaita-1-0 (>= 1.9~beta), libc6 (>= 2.38), libcairo2 (>= 1.2.4), libcmark-gfm-extensions0.29.0.gfm.13 (>= 0.29.0.gfm.13), libcmark-gfm0.29.0.gfm.13 (>= 0.29.0.gfm.13), libgdk-pixbuf-2.0-0 (>= 2.22.0), libgee-0.8-2 (>= 0.8.3), libglib2.0-0t64 (>= 2.76.0), libgtk-4-1 (>= 4.12.0), libgtksourceview-5-0 (>= 2.91.4), libjson-glib-1.0-0 (>= 1.5.2), libpango-1.0-0 (>= 1.14.0), libsecret-1-0 (>= 0.7), libsoup-3.0-0 (>= 3.0.3)
Installed-Size: 1320
Description: File Collector (文件收集器)
 A cross-platform desktop tool for collecting, organizing and exporting
 files. Built with GTK4 / libadwaita.
EOF
```

> `Installed-Size` 单位为 KB，可用 `du -sk deb-root/usr | cut -f1` 得到。

### 3.4 打包

```bash
PKG=filecollector_4.6.0_amd64
dpkg-deb --build --root-owner-group deb-root ${PKG}.deb
```

`--root-owner-group` 会把包内所有文件归属重置为 `root:root`，避免打包进当前用户
的 uid/gid。

### 3.5 校验

```bash
dpkg-deb -I ${PKG}.deb     # 查看控制信息
dpkg-deb -c ${PKG}.deb     # 查看文件列表
dpkg -i --dry-run ${PKG}.deb   # 干跑，确认可安装（需 root 写日志权限）
```

### 3.6 一键构建脚本（可选）

把上述步骤保存为 `build_deb.sh` 可复用（记得把版本号参数化）：

```bash
#!/usr/bin/env bash
set -euo pipefail
VER="4.6.0"
PKG="filecollector_${VER}_amd64"

rm -rf build deb-root
meson setup build --prefix=/usr --buildtype=release
meson compile -C build
DESTDIR=$PWD/deb-root meson install -C build

mkdir -p deb-root/DEBIAN
mkdir -p debian && cat > debian/control <<'EOF'
Source: filecollector
Section: utils
Priority: optional
Maintainer: Sam-Fic <2401894494@qq.com>

Package: filecollector
Architecture: amd64
Description: File Collector
 A tool to collect files.
EOF
DEPS=$(dpkg-shlibdeps -O deb-root/usr/bin/filecollector | sed 's/^shlibs:Depends=//')
rm -rf debian

SIZE=$(du -sk deb-root/usr | cut -f1)
cat > deb-root/DEBIAN/control <<EOF
Package: filecollector
Version: ${VER}
Section: utils
Priority: optional
Architecture: amd64
Maintainer: Sam-Fic <2401894494@qq.com>
Homepage: https://github.com/Sam-Fic/filecollector
Depends: ${DEPS}
Installed-Size: ${SIZE}
Description: File Collector (文件收集器)
 A cross-platform desktop tool for collecting, organizing and exporting
 files. Built with GTK4 / libadwaita.
EOF

dpkg-deb --build --root-owner-group deb-root ${PKG}.deb
echo "Built: ${PKG}.deb"
```

---

## 4. 上传到 GitHub Release（追加到现有最新 Release）

> 约定：deb **不新建 Release**，直接追加到 Flatpak 流程已创建的那个最新 Release 资产列表中。
> deb 流程**永远不会**调用 `gh release create`。若仓库尚无 Release，应先完成 `BUILD_FLATPAK.md`。

### 4.1 准备工作

确保已安装并登录 GitHub CLI：

```bash
which gh || sudo apt install -y gh
gh auth login          # 浏览器授权，选择仓库范围
gh auth status         # 确认已登录且能访问 Sam-Fic/filecollector
```

### 4.2 获取现有最新 Release 的标签

```bash
# 取仓库「最新」Release 的 tag（即 Flatpak 流程创建的那一个）
LATEST=$(gh release list --limit 1 --json tagName --jq '.[0].tagName')
echo "目标 Release 标签: $LATEST"
```

> 若你明确知道版本号，也可直接写死：`LATEST=v4.6.0`。

### 4.3 上传 deb 资产

```bash
PKG=filecollector_4.6.0_amd64.deb

# 追加到现有最新 Release（不新建）
gh release upload "$LATEST" "$PKG"
```

`gh release upload` 会把文件追加到该 Release 的 Download 资产列表，不影响已有资产。

### 4.4 生成校验和（可选但推荐）

```bash
sha256sum ${PKG} > ${PKG}.sha256
gh release upload "$LATEST" ${PKG}.sha256
```

### 4.5 前置缺失时的处理

deb 流程**不创建 Release**。若执行 4.2 取不到最新 Release（仓库里还没有任何 Release），
说明 Flatpak 流程未完成：请先按 `BUILD_FLATPAK.md` 完成版本号更新、打 `vX.Y.Z` 标签、
push、构建并创建 GitHub Release，再回来执行 4.2–4.4 追加 deb 资产。

### 4.6 在仓库页面查看

打开 `https://github.com/Sam-Fic/filecollector/releases`，确认 deb 已作为
Download 资产出现在**最新** Release 下。

---

## 5. 排错

| 现象 | 原因 / 解决 |
| --- | --- |
| `error: cannot read debian/control` | `dpkg-shlibdeps` 需要在当前目录有 `debian/control`。按 3.3 节先建临时文件。 |
| 安装后桌面无图标 / 启动器找不到 | 确认 `meson install` 把 `.desktop` 装到了 `usr/share/applications/`，且 `Icon=` 字段指向 `io.github.sam_fic.filecollector`（不含扩展名）。 |
| `dpkg: dependency problems` 安装失败 | 目标系统缺运行库。在 `DEBIAN/control` 的 `Depends` 补齐，或让用户先 `sudo apt -f install`。 |
| `cmark-gfm` 依赖版本不符 | 不同发行版 SONAME 不同（如 `0.29.0.gfm.13`）。务必用 `dpkg-shlibdeps` 重新生成 `Depends`。 |
| 包内文件属主异常 | 构建时必须加 `--root-owner-group`，否则会带入当前用户的 uid/gid。 |
| lintian 报 `wrong-file-owner` | 同上，使用 `--root-owner-group` 重新打包。 |

---

## 6. 速查表

```bash
# 构建
rm -rf build deb-root && meson setup build --prefix=/usr --buildtype=release \
  && meson compile -C build \
  && DESTDIR=$PWD/deb-root meson install -C build

# 打包（版本号替换为你实际的）
VER=4.6.0
# ← 先按 3.3 生成 DEBIAN/control
dpkg-deb --build --root-owner-group deb-root filecollector_${VER}_amd64.deb

# 发布（追加到现有最新 Release，不新建）
LATEST=$(gh release list --limit 1 --json tagName --jq '.[0].tagName')
gh release upload "$LATEST" filecollector_${VER}_amd64.deb
```

---

## 7. 项目结构说明（与 deb 相关）

```
filecollector/
├── meson.build                      # 版本号、构建目标、i18n 安装规则
├── data/
│   ├── io.github.sam_fic.filecollector.desktop   # 桌面入口（装到 /usr/share/applications）
│   ├── io.github.sam_fic.filecollector.metainfo.xml  # AppStream（装到 /usr/share/metainfo）
│   ├── io.github.sam_fic.filecollector.svg       # 图标（装到 hicolor/scalable/apps）
│   └── filecollector.gresource.xml  # 资源（窗口 UI、样式、图标，编译进二进制）
├── po/                              # 翻译（.mo 装到 /usr/share/locale）
└── src/                             # Vala 源码，编译为 /usr/bin/filecollector
```

> deb 包只需关心 `meson install` 产出的标准路径文件；gresource 内的资源已被
> 链接进 `filecollector` 二进制，无需单独打包。
