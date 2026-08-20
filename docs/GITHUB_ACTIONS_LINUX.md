# Linux 自动打包与发布

仓库现在使用 `.github/workflows/linux-packages.yml` 自动构建 **amd64 DEB** 和 **x86_64 Flatpak bundle**。该工作流把 Linux 打包从发布流程中独立出来：普通开发提交只产生可下载的构建产物，而版本标签会把同一批产物发布到 GitHub Release。

| 触发方式 | 执行结果 | 产物位置 |
| --- | --- | --- |
| 推送至 `main` | 构建并验证 DEB 与 Flatpak | 对应工作流的 Artifacts |
| 向 `main` 发起或更新拉取请求 | 构建并验证 DEB 与 Flatpak | 对应工作流的 Artifacts |
| 在 Actions 页面手动运行 | 构建并验证 DEB 与 Flatpak | 对应工作流的 Artifacts |
| 推送 `v*` 标签，例如 `v4.8.0` | 构建、验证并创建或更新同名 GitHub Release | Release Assets 与工作流 Artifacts |

DEB 打包使用 `tools/build-deb.sh`。脚本从 `meson.build` 读取唯一版本号，执行 Meson 构建和测试，将标准安装结果暂存到 `deb-root/`，再用 `dpkg-shlibdeps` 自动生成运行时依赖。这样不会把与构建环境不匹配的依赖版本硬编码进控制文件。为满足项目要求的 `libadwaita >= 1.9`，该构建步骤在 Ubuntu 26.04 容器中执行；Ubuntu 软件包仓库显示该版本提供 libadwaita 1.9.0。[1]

Flatpak 打包采用官方维护的 Flatpak 构建动作，并使用与项目清单一致的 GNOME 50 构建环境。该动作会依照 `io.github.sam_fic.filecollector.json` 创建名为 `filecollector-<版本>.flatpak` 的 bundle；其缓存由 manifest 和提交 SHA 区分，以加快重复构建同时避免复用不兼容的构建状态。[2]

## 日常使用

正常开发时直接推送到 `main` 或创建拉取请求即可。打开对应的 Actions 运行记录，在 **Artifacts** 区域下载 `filecollector-deb-amd64` 或 `filecollector-<版本>-x86_64.flatpak`，可用于安装前测试。

准备发布版本时，先完成版本提交（包括 `meson.build` 与 AppStream 元数据），然后推送版本标签。无需再在本地打包或手动上传文件：工作流通过仓库提供的令牌创建或更新同标签 Release，并上传以下三个文件。

| 文件 | 说明 |
| --- | --- |
| `filecollector_<版本>_amd64.deb` | Debian/Ubuntu 安装包 |
| `filecollector_<版本>_amd64.deb.sha256` | DEB 的 SHA-256 校验和 |
| `filecollector-<版本>.flatpak` | 可分发 Flatpak bundle |

```bash
# 示例：在版本提交已经推送后发布 v4.8.0
git tag v4.8.0
git push origin v4.8.0
```

> 若同标签 Release 已存在，工作流会更新该 Release 并上传当前构建产物；若不存在，则会自动创建 Release 并生成 GitHub 的默认发布说明。

## 参考

[1]: https://packages.ubuntu.com/en/resolute/libadwaita-1-dev "Ubuntu 26.04 libadwaita-1-dev"
[2]: https://github.com/flatpak/flatpak-github-actions "Flatpak GitHub Actions"
