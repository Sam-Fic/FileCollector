# 桌面端自动打包与发布

仓库使用 `.github/workflows/desktop-packages.yml` 自动构建 **amd64 DEB**、**x86_64 Flatpak bundle**、**Windows x64 便携 ZIP** 和 **macOS ARM64 应用包 ZIP**。普通开发提交仅产生可下载的构建产物；版本标签会把同一批已经验证的产物发布到 GitHub Release。

| 触发方式 | 执行结果 | 产物位置 |
| --- | --- | --- |
| 推送至 `main` | 构建并验证四个平台安装包 | 对应工作流的 Artifacts |
| 向 `main` 发起或更新拉取请求 | 构建并验证四个平台安装包 | 对应工作流的 Artifacts |
| 在 Actions 页面手动运行 | 构建并验证四个平台安装包 | 对应工作流的 Artifacts |
| 推送 `v*` 标签，例如 `v4.8.0` | 构建、验证并创建或更新同名 GitHub Release | Release Assets 与工作流 Artifacts |

DEB 打包使用 `tools/build-deb.sh`。脚本从 `meson.build` 读取唯一版本号，执行 Meson 构建和测试，将标准安装结果暂存到 `deb-root/`，再用 `dpkg-shlibdeps` 自动生成运行时依赖。这样不会把与构建环境不匹配的依赖版本硬编码进控制文件。为满足项目要求的 `libadwaita >= 1.9`，该构建步骤在 Ubuntu 26.04 容器中执行；Ubuntu 软件包仓库显示该版本提供 libadwaita 1.9.0。[1]

Flatpak 打包采用官方维护的 Flatpak 构建动作，并使用与项目清单一致的 GNOME 50 构建环境。该动作会依照 `io.github.sam_fic.filecollector.json` 创建名为 `filecollector-<版本>.flatpak` 的 bundle；其缓存由 manifest 和提交 SHA 区分，以加快重复构建同时避免复用不兼容的构建状态。[2]

Windows 打包在 MSYS2 的 MINGW64 环境中编译。构建脚本会从源码编译 cmark-gfm、运行测试、递归收集 MinGW DLL，并额外打包 GTK 图像加载器、GSettings、完整的 GNOME `Adwaita` 与 `hicolor` 图标主题，以及 GIO TLS 模块。应用启动时会明确注册包内主题目录，因此 Windows 不依赖宿主系统图标；所有代码中引用的 `*-symbolic` 图标都会在打包阶段与实际主题资产逐一校验。下载后应解压并通过 `bin/filecollector-launch.bat` 启动，以正确设置图片加载器与 HTTPS 模块路径。[3]

macOS 打包固定在 Apple Silicon 的 `macos-14` 运行器上，产出 ARM64 `.app` 并将 Homebrew 动态库重定位到应用包内。`FileCollector.app/Contents/Resources/share/icons/` 同样携带完整的 GNOME `Adwaita` 与 `hicolor` 主题，应用会优先在该目录解析所有 symbolic 图标，从而保持与 GNOME 桌面一致的图标来源与视觉语义。产物使用临时的 ad-hoc 签名用于完整性验证，但**不含 Apple Developer ID 签名或公证**；首次在其他 Mac 上打开时，系统仍可能显示未验证开发者提示。[4]

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
[4]: https://github.com/actions/runner-images/blob/main/images/macos/macos-14-arm64-Readme.md "GitHub Actions macOS 14 ARM64 runner image"
