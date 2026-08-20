# XApp Symbolic Icons：最小供应资产

FileCollector 仅随 Windows 与 macOS 便携包供应源码实际引用的两个 XApp Symbolic Icons（`xsi-*`）原始 SVG，而**不**复制完整图标集。

| 项目 | 信息 |
| --- | --- |
| 上游项目 | [xapp-project/xapp-symbolic-icons](https://github.com/xapp-project/xapp-symbolic-icons) |
| 固定来源提交 | 见 `SOURCE_COMMIT` |
| 上游许可证 | LGPL-3.0，完整文本见 `LICENSE` |
| 供应的原始图标 | `xsi-git-symbolic.svg`、`xsi-text-case-symbolic.svg` |
| 项目内资产位置 | `data/icons/hicolor/scalable/actions/` |
| 包内安装位置 | `share/icons/hicolor/scalable/actions/`（Windows）与 `FileCollector.app/Contents/Resources/share/icons/hicolor/scalable/actions/`（macOS） |

这些图标保持其上游原始名称和内容，以便 GTK 从完整 Adwaita/hicolor 主题搜索路径中解析 FileCollector 既有的 XApp symbolic 图标调用。
