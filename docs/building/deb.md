# 本地构建 DEB

本文件用于在 Debian/Ubuntu 环境中**本地复现和排查** DEB 构建问题。正式发布不应手工上传资产：版本号由 `meson.build` 唯一管理，向 GitHub 推送 `v*` 标签会触发统一工作流，并在四个平台构建均成功后发布同一个 Release。发布流程请参阅 [桌面端自动打包与发布](../GITHUB_ACTIONS_DESKTOP.md)。

## 构建环境

当前项目要求 GTK 4、libadwaita、GtkSourceView 5、libsoup 3、libsecret 和 cmark-gfm。CI 在 Ubuntu 26.04 容器中构建，以满足 `libadwaita >= 1.9` 的版本要求。建议使用同等或更高版本的环境进行本地复现。

```bash
sudo apt update
sudo apt install -y \
  build-essential ca-certificates dpkg-dev gettext \
  libadwaita-1-dev libcmark-gfm-dev libcmark-gfm-extensions-dev \
  libgee-0.8-dev libgtk-4-dev libgtksourceview-5-dev \
  libjson-glib-dev libsecret-1-dev libsoup-3.0-dev \
  meson ninja-build pkg-config python3 valac blueprint-compiler
```

## 构建与验证

在仓库根目录执行：

```bash
chmod +x tools/build-deb.sh
tools/build-deb.sh
```

脚本会清理临时目录、编译并运行单元测试、把 Meson 安装结果暂存到 `deb-root/`、验证自定义 GtkSourceView 样式和 XApp symbolic 图标、用 `dpkg-shlibdeps` 计算依赖，并生成下列文件：

```text
dist/filecollector_<meson.build 中的版本>_amd64.deb
dist/filecollector_<meson.build 中的版本>_amd64.deb.sha256
```

## 结果检查

```bash
dpkg-deb --info dist/filecollector_*.deb
dpkg-deb --contents dist/filecollector_*.deb
sha256sum --check dist/filecollector_*.deb.sha256
```

包内应包含以下项目资源：

```text
usr/share/filecollector/gtksourceview-5/styles/filecollector-dark.xml
usr/share/filecollector/gtksourceview-5/styles/filecollector-light.xml
usr/share/icons/hicolor/scalable/actions/xsi-git-symbolic.svg
usr/share/icons/hicolor/scalable/actions/xsi-text-case-symbolic.svg
```

若本地系统的依赖版本不满足项目要求，请以 CI 的 Ubuntu 26.04 容器结果为准，不要为兼容旧系统而手工修改生成包的依赖或版本号。
