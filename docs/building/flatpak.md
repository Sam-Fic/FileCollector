# 本地构建 Flatpak

本文件用于在本地复现和排查 Flatpak 构建。正式发布由 GitHub Actions 统一处理：推送与 `meson.build` 中版本相符的 `v*` 标签后，DEB、Flatpak、Windows x64 与 macOS ARM64 会并行构建，并在全部成功后作为同一个 Release 的资产上传。请参阅 [桌面端自动打包与发布](../GITHUB_ACTIONS_DESKTOP.md)。

## 前置条件

需要安装 Flatpak、Flatpak Builder，并配置项目使用的 GNOME 50 SDK/Runtime。构建清单为仓库根目录的 `io.github.sam_fic.filecollector.json`。

```bash
flatpak install flathub org.gnome.Platform//50 org.gnome.Sdk//50
flatpak install flathub org.flatpak.Builder
```

运行时名称或安装来源因发行版而异；若命令不可用，请依照发行版的 Flatpak 文档完成基础配置。

## 构建 bundle

在仓库根目录执行：

```bash
flatpak-builder --user --install --force-clean build-flatpak \
  io.github.sam_fic.filecollector.json
flatpak build-bundle --runtime-repo=https://sdk.gnome.org/repo/ \
  build-flatpak-repo filecollector-local.flatpak \
  io.github.sam_fic.filecollector
```

也可用项目的 CI 工作流获得与发布环境一致的构建结果。

## 资源验证

应用的 Meson 安装规则会把以下资源安装到 Flatpak 的 `/app/share/` 内；安装阶段会自动校验其存在：

```text
filecollector/gtksourceview-5/styles/filecollector-dark.xml
filecollector/gtksourceview-5/styles/filecollector-light.xml
icons/hicolor/scalable/actions/xsi-git-symbolic.svg
icons/hicolor/scalable/actions/xsi-text-case-symbolic.svg
```

这使 Flatpak 不依赖宿主系统的 XApp 图标或预览样式文件。若构建在安装阶段失败，请先确认上述源码文件仍在 `data/` 目录，且 `meson.build` 的 `install_subdir()` 规则未被修改。

## 清理本地构建目录

```bash
rm -rf build-flatpak build-flatpak-repo .flatpak-builder filecollector-local.flatpak
```

这些目录和 bundle 均已由 `.gitignore` 忽略，不能提交到仓库。
