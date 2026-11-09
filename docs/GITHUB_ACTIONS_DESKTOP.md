# 桌面端自动打包与发布

仓库使用 `.github/workflows/desktop-packages.yml` 自动构建 **amd64 DEB**、**x86_64 Flatpak bundle**、**Windows x64 便携 ZIP** 和 **macOS ARM64 应用包 ZIP**。普通开发提交仅产生可下载的构建产物；版本标签会把同一批已经验证的产物发布到 GitHub Release。

| 触发方式 | 执行结果 | 产物位置 |
| --- | --- | --- |
| 推送至 `main` | 运行 vala-lint 风格检查并构建、验证四个平台安装包 | 对应工作流的 Artifacts |
| 向 `main` 发起或更新拉取请求 | 运行 vala-lint 风格检查并构建、验证四个平台安装包 | 对应工作流的 Artifacts |
| 在 Actions 页面手动运行 | 运行 vala-lint 风格检查并构建、验证四个平台安装包 | 对应工作流的 Artifacts |
| 推送 `v*` 标签，例如 `v4.8.0` | 构建、验证并创建或更新同名 GitHub Release | Release Assets 与工作流 Artifacts |

DEB 打包使用 `tools/build-deb.sh`。脚本从 `meson.build` 读取唯一版本号，执行 Meson 构建和测试，将标准安装结果暂存到 `deb-root/`，再用 `dpkg-shlibdeps` 自动生成运行时依赖。这样不会把与构建环境不匹配的依赖版本硬编码进控制文件。为满足项目要求的 `libadwaita >= 1.9`，该构建步骤在 Ubuntu 26.04 容器中执行；Ubuntu 软件包仓库显示该版本提供 libadwaita 1.9.0。[1]

Flatpak 打包采用官方维护的 Flatpak 构建动作，并使用与项目清单一致的 GNOME 50 构建环境。该动作会依照 `io.github.sam_fic.filecollector.json` 创建名为 `filecollector-<版本>.flatpak` 的 bundle；其缓存由 manifest 和提交 SHA 区分，以加快重复构建同时避免复用不兼容的构建状态。[2]

Windows 打包在 MSYS2 的 UCRT64 环境中编译。构建脚本会从源码编译 cmark-gfm、运行测试、递归收集 UCRT64 运行时 DLL（包含 GTK 图像加载器与 GIO TLS 模块的间接依赖，避免出现 AVIF/HEIF/SVG 加载器缺库），并额外打包 GTK 图像加载器、GSettings、完整的 GNOME `Adwaita` 与 `hicolor` 图标主题、项目随附且实际使用的两个原始 XApp symbolic（`xsi-*`）图标，以及 GIO TLS 模块。DLL 收集脚本按 `MSYSTEM_PREFIX` 判定运行时目录，且设有数量下限；打包前后还会用 `tools/verify_windows_package.py` 解析全部 PE 导入表做依赖闭包校验，任何一个非系统 DLL 缺失都会直接让构建失败，不再产出用户启动时报「找不到 xxx.dll」的坏包。应用启动时会明确注册包内主题目录，因此 Windows 不依赖宿主系统图标；所有代码中引用的 `*-symbolic` 图标都会在打包阶段与实际主题资产逐一校验。下载后应解压并通过 `bin/filecollector-launch.bat` 启动，以正确设置图片加载器与 HTTPS 模块路径。[3]

macOS 打包固定在 Apple Silicon 的 `macos-latest` 运行器上，产出 ARM64 `.app` 并将 Homebrew 动态库重定位到应用包内（依赖闭包收集覆盖 `@rpath` 传递依赖并删除全部 `LC_RPATH`）。除动态库外，`Contents/Resources/` 还携带运行时按需加载的组件：GIO TLS 模块（`libgiognutls.so`，HTTPS/AI 功能必需）、gdk-pixbuf loader 插件与指向包内的 `loaders.cache`（图片加载与 SVG 图标必需）、fontconfig 配置（含 Apple 系统字体目录）、完整 GNOME `Adwaita` 与 `hicolor` 图标主题（叠加项目随附且实际使用的两个原始 XApp symbolic（`xsi-*`）图标）、`zh_CN` locale 与 `FileCollector.icns`；应用启动时在 `main.vala` 中用环境变量指向这些包内副本。`tools/verify_macos_package.py` 会在签名前解析全部 Mach-O 加载命令做依赖闭包审计（`@rpath` 悬空、缺失依赖、指向构建机的路径都会让构建失败），随后以 ad-hoc 冒烟测试（`fc-list` 字体扫描 + `broadwayd` 无头启动）验证应用可运行。产物要求 macOS 15+；使用临时的 ad-hoc 签名用于完整性验证，但**不含 Apple Developer ID 签名或公证**；首次在其他 Mac 上打开时，系统仍可能显示未验证开发者提示。[4]

工作流还包含一个 `lint` job：在 Ubuntu 运行器上以固定 tag（0.1.0）从源码构建 vala-lint，并按仓库根目录的 `vala-lint.conf` 对 `src/` 执行代码风格检查。固定 tag 是为了避免上游 master 变动导致规则漂移。四个平台构建与 `publish` job 均依赖 lint 通过，error 级风格回归会同时阻塞日常构建与版本发布；`line-length`、`ellipsis`、`note` 目前为 warn 级别（只报告不阻塞），升降级说明见 `vala-lint.conf` 头部注释。[5]

## 日常使用

正常开发时直接推送到 `main` 或创建拉取请求即可。打开对应的 Actions 运行记录，在 **Artifacts** 区域下载 `filecollector-deb-amd64`、`filecollector-<版本>-x86_64.flatpak`、`filecollector-windows-x64` 或 `filecollector-macos-arm64`，可用于安装前测试。

准备发布版本时，先完成版本提交（包括 `meson.build` 与 AppStream 元数据），然后推送版本标签。无需再在本地打包或手动上传文件：工作流通过仓库提供的令牌创建或更新同标签 Release，并上传以下七个文件。

| 文件 | 说明 |
| --- | --- |
| `filecollector_<版本>_amd64.deb` | Debian/Ubuntu 安装包 |
| `filecollector_<版本>_amd64.deb.sha256` | DEB 的 SHA-256 校验和 |
| `filecollector-<版本>.flatpak` | 可分发 Flatpak bundle |
| `filecollector-windows-<版本>-x64.zip` | Windows x64 便携包；请经由包内启动器启动 |
| `filecollector-windows-<版本>-x64.zip.sha256` | Windows 包的 SHA-256 校验和 |
| `filecollector-macos-<版本>-arm64.zip` | macOS ARM64 应用包 |
| `filecollector-macos-<版本>-arm64.zip.sha256` | macOS 包的 SHA-256 校验和 |

```bash
# 示例：在版本提交已经推送后发布 v4.8.0
git tag v4.8.0
git push origin v4.8.0
```

> 若同标签 Release 已存在，工作流会更新该 Release 并上传当前构建产物；若不存在，则会自动创建 Release 并生成 GitHub 的默认发布说明。

## 参考

[1]: https://packages.ubuntu.com/en/resolute/libadwaita-1-dev "Ubuntu 26.04 libadwaita-1-dev"
[2]: https://github.com/flatpak/flatpak-github-actions "Flatpak GitHub Actions"
[3]: https://www.msys2.org/docs/ci/ "Using MSYS2 in CI"
[4]: https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md "GitHub Actions macOS ARM64 runner image"
[5]: https://github.com/vala-lang/vala-lint "vala-lint"
