# FileCollector

<div align="center">
  <img src="data/com.github.samfic.filecollector.svg" alt="FileCollector" width="128" height="128">
</div>

一个基于 GNOME 平台的文件收集工具，使用 Vala 语言编写，采用 GTK4 和 libadwaita 构建现代化的用户界面。

## 界面预览

![FileCollector Screenshot](https://github.com/Sam-Fic/filecollector-gnome/assets/your-user-id/your-image-id)

## 功能特性

- 项目管理：打开和保存项目
- 短语管理：管理和组织常用短语
- 现代化界面：采用 GNOME Human Interface Guidelines 设计

## 安装依赖

### Debian/Ubuntu

```bash
sudo apt install meson valac libgtk-4-dev libadwaita-1-dev libjson-glib-dev blueprint-compiler
```

### Fedora

```bash
sudo dnf install meson vala gtk4-devel libadwaita-devel json-glib-devel blueprint-compiler
```

## 构建与安装

```bash
mkdir builddir && cd builddir
meson setup ..
ninja
sudo ninja install
```

## 运行

```bash
filecollector
```

## Flatpak 构建

```bash
flatpak-builder build-dir com.github.samfic.filecollector.json --user --install
flatpak run com.github.samfic.filecollector
```

## 项目结构

```
.
├── data/           # 应用程序数据文件
│   ├── com.github.samfic.filecollector.desktop
│   ├── com.github.samfic.filecollector.metainfo.xml
│   ├── com.github.samfic.filecollector.svg
│   ├── filecollector.gresource.xml
│   └── style.css
├── src/            # 源代码
│   ├── main.vala   # 应用程序入口
│   ├── window.vala # 主窗口逻辑
│   └── window.blp  # Blueprint UI 描述
├── meson.build     # Meson 构建配置
└── com.github.samfic.filecollector.json  # Flatpak 构建配置
```

## 许可证

本项目采用 MIT 许可证。
