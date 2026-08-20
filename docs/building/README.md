# 本地构建与排错指南

这里的文档用于在开发机上复现构建问题、检查打包内容和排查平台差异。它们**不**是正式发布流程：项目版本只在 `meson.build` 中维护；推送 `v*` 标签后，GitHub Actions 会并行构建 DEB、Flatpak、Windows x64 与 macOS ARM64，并在四项构建全部成功后更新同一个 GitHub Release。

正式发布规则和 CI 产物说明请参阅 [桌面端自动打包与发布](../GITHUB_ACTIONS_DESKTOP.md)。

| 平台 | 本地构建与排错文档 | 主要产物 |
| --- | --- | --- |
| Debian / Ubuntu | [DEB](deb.md) | `.deb` 与 SHA-256 校验文件 |
| Flatpak | [Flatpak](flatpak.md) | 本地安装的应用或 `.flatpak` bundle |
| Windows x64 | [Windows 便携包](windows.md) | 可解压运行的 ZIP 与 SHA-256 校验文件 |
| macOS ARM64 | [macOS](macos.md) | `.app` ZIP 与 SHA-256 校验文件 |

所有平台都应保留并验证自定义 GtkSourceView 深浅色样式，以及 `xsi-git-symbolic.svg`、`xsi-text-case-symbolic.svg` 两个项目实际使用的 XApp 图标。
