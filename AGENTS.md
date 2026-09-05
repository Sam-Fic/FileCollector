# AGENTS.md - FileCollector 文档索引

本文件是仓库文档的统一入口。遇到特定场景时，按下方索引找到对应的详细文档。

---

## 红线

- 不要泄露私人数据。永远不要。
- 不要未经询问就执行破坏性命令。
- 有疑问时就问。

## 场景路由

| 触发场景 | 去哪里找详细文档 | 关键要点 |
| --- | --- | --- |
| **翻译 / i18n / 多语言 / 新增语言 / 更新 .po** | [docs/I18N.md](docs/I18N.md) | 翻译文件位于 `po/`；源码用 `_()` 标记可翻译字符串；修改了 UI 或 `_()` 字符串后**必须**重新生成 `.pot` 模板并 `msgmerge` 合并到 `zh_CN.po`；新增语言需在 `LINGUAS` 添加语言代码并创建对应 `.po` 文件；`msgmerge` 的 fuzzy 匹配不可信，合并后必须逐条检查 |
| **发布新版本 / Release / 打 tag / 版本号** | [docs/RELEASE.md](docs/RELEASE.md) | 版本号仅在 `meson.build` 第 2 行维护；每次发版**必须**在 `data/io.github.sam_fic.filecollector.metainfo.xml` 的 `<releases>` 顶部添加 release 条目；推送 `v*` 标签触发 CI 自动构建四平台并发布 Release，无需手动上传资产 |
| **CI / GitHub Actions / 自动构建 / 流水线** | [docs/GITHUB_ACTIONS_DESKTOP.md](docs/GITHUB_ACTIONS_DESKTOP.md) | 工作流配置在 `.github/workflows/desktop-packages.yml`；推送 main 或 PR 触发构建验证；推送 `v*` 标签触发 Release 发布；四平台并行构建 |
| **本地构建 / 编译 / 排错 / DEB / Flatpak / Windows / macOS 构建** | [docs/building/README.md](docs/building/README.md) → 各平台子文档 | 各平台构建环境、依赖安装、构建命令、资源验证；DEB 在 `docs/building/deb.md`，Flatpak 在 `docs/building/flatpak.md`，Windows 在 `docs/building/windows.md`，macOS 在 `docs/building/macos.md` |
| **安全 / 密钥 / API Key / Token 存储** | [docs/SECURITY_AUDIT.md](docs/SECURITY_AUDIT.md) | 密钥走 libsecret / DPAPI / Keychain，不落明文；HTTP 端点风险；配置文件权限；`.gitignore` 规则 |
| **GUI 使用 / 界面操作 / 工作流程 / Tips** | [docs/USAGE.md](docs/USAGE.md)（中文）/ [docs/USAGE_EN.md](docs/USAGE_EN.md)（英文） | 文件勾选、编排、导出、预览、常用语管理、项目管理、AI 多模型配置 |
| **代码风格 / lint / 命名约定 / 贡献 / 提 PR** | [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) | snake_case 方法/变量、PascalCase 类名、ALL_CAPS 常量；`io.elementary.vala-lint -c vala-lint.conf src/` 作为 CI 卡关；line-length 为 warn；新增全大写常量需加入 `vala-lint.conf` 的 `exceptions`；`.valalintignore` 创建后替代 `.gitignore`，需手动维护 |
| **项目概览 / 功能列表 / CLI / MCP / AI 助手 / Git 集成 / 快捷键** | [README.md](README.md) | 项目入口文档，包含功能特性概述、CLI 命令列表、MCP 服务说明、AI 助手配置、Git 历史集成、键盘快捷键 |

## 双语文档同步

项目维护两套手动维护的双语文档对。修改任一版本后**必须同步另一版本**：

| 中文 | 英文 |
| --- | --- |
| [README.md](README.md) | [README_EN.md](README_EN.md) |
| [docs/USAGE.md](docs/USAGE.md) | [docs/USAGE_EN.md](docs/USAGE_EN.md) |

同步时确保内容结构、章节编号、代码示例、图片路径完全对应，仅语言不同。

## 文档目录结构

```
├── AGENTS.md                  ← 本文件：文档索引
├── README.md                   ← 项目入口（中文）
├── README_EN.md                ← 项目入口（英文）
├── docs/
│   ├── USAGE.md               ← GUI 使用说明（中文）
│   ├── USAGE_EN.md            ← GUI 使用说明（英文）
│   ├── GITHUB_ACTIONS_DESKTOP.md ← CI/CD 自动构建与发布
│   ├── SECURITY_AUDIT.md       ← 安全审计报告
│   ├── I18N.md                ← 翻译/i18n 工作流
│   ├── RELEASE.md             ← 发版操作清单
│   ├── CONTRIBUTING.md         ← 代码风格与贡献指南
│   ├── building/              ← 本地构建与排错
│   │   ├── README.md          ← 构建指南索引
│   │   ├── deb.md             ← DEB 本地构建
│   │   ├── flatpak.md         ← Flatpak 本地构建
│   │   ├── windows.md         ← Windows 便携包本地构建
│   │   └── macos.md           ← macOS ARM64 本地构建
│   └── images/                ← 文档截图
└── data/icons/xapp-symbolic-icons/
    └── README.md              ← 第三方图标供应说明（跟随资产，不移动）
```
