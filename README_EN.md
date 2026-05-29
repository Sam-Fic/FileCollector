# FileCollector

<div align="center">
  <img src="data/com.github.samfic.filecollector.svg" alt="FileCollector" width="128" height="128">
</div>

[中文版](README.md) · [English Version](README_EN.md)

---

FileCollector is a cross-platform desktop tool for efficiently collecting, organizing files from your working directory, and generating merged text.  
It provides a checkable directory tree, flexible organization list, text insertion and automatic encoding detection, making it ideal for quickly consolidating key code or documents from a project into a single TXT file for further analysis or submission to large language models.

## UI Preview

![FileCollector Screenshot](./screenshots/screenshot_en.png)

## Features

- **CLI Mode**: Complete all core operations via terminal commands, ideal for scripting and automation
- **Project Management**: Open and save projects
- **Phrase Management**: Manage and organize common phrases
- **Internationalization**: Supports Chinese and English UI, automatically follows system language
- **Modern UI**: Designed following GNOME Human Interface Guidelines

> **Tip**: If you are on a non-GNOME platform (such as Windows or macOS), please check out the [PySide6 version repository](https://github.com/Sam-Fic/filecollector). This version supports Windows, macOS, and Linux, and is built with PySide6.

## Pre-built Flatpak (Recommended)

Pre-built Flatpak packages are available in the [Releases](https://github.com/Sam-Fic/filecollector-gnome/releases) section. If you prefer not to build from source, you can directly download and install the `.flatpak` files.

```bash
flatpak install --user <the-downloaded.flatpak-file>
```

Then run:

```bash
flatpak run com.github.samfic.filecollector
```

## Build from Source

### Install Dependencies

#### Debian/Ubuntu

```bash
sudo apt install meson valac libgtk-4-dev libadwaita-1-dev libjson-glib-dev blueprint-compiler gettext
```

#### Fedora

```bash
sudo dnf install meson vala gtk4-devel libadwaita-devel json-glib-devel blueprint-compiler gettext
```

### Build & Install

```bash
mkdir -p build && cd build
meson setup ..
meson compile
sudo meson install
```

> **Tip**: If you have built before, re-run `meson compile` inside the `build/` directory for incremental compilation of the binary. If you modified translation files (`en.po` or `_()` strings in UI), also re-run `sudo meson install` to deploy the updated `.mo` file to the system path.

### Run

```bash
filecollector          # Launch GUI
filecollector --help   # Show CLI help
```

> **Tip**:
> - The application automatically uses Chinese or English UI based on your system language. To temporarily switch languages, use the `LANGUAGE` environment variable, e.g. `LANGUAGE=en filecollector` to force English display. You can also edit the `en.po` file to modify the English translations.
> - For CLI mode usage, see the [CLI Mode](#cli-mode) section below.

### Flatpak Build

```bash
flatpak-builder build-dir com.github.samfic.filecollector.json --user --install --force-clean
flatpak run com.github.samfic.filecollector
```

## Project Structure

```
.
├── data/                                  # Application data files
│   ├── com.github.samfic.filecollector.desktop
│   ├── com.github.samfic.filecollector.metainfo.xml
│   ├── com.github.samfic.filecollector.svg
│   ├── filecollector.gresource.xml
│   └── style.css
├── screenshots/                           # Screenshots
├── src/                                   # Source code
│   ├── main.vala                          # Application entry point (auto-detects CLI or GUI)
│   ├── cli.vala                           # CLI controller
│   ├── window.vala                        # Main window logic
│   ├── window.blp                         # Blueprint UI description
│   ├── config.vala.in                     # Config template (version, etc.)
│   ├── models/
│   │   └── item_data.vala                 # Queue item data model
│   ├── services/
│   │   ├── config_manager.vala            # Config/settings/phrases persistence
│   │   ├── file_generator.vala            # File merging and clipboard copy
│   │   └── project_manager.vala           # Project save and load
│   ├── utils/
│   │   ├── tree_helper.vala               # Directory tree utility functions
│   │   └── encoding_helper.vala           # Encoding auto-detection and conversion
│   └── widgets/
│       ├── settings_dialog.vala           # Settings dialog
│       └── phrases_picker.vala            # Common phrases picker and management
├── en.po                                  # English UI translation file
├── POTFILES                               # List of translatable source files (for gettext)
├── LINGUAS                                # List of supported languages
├── BUILD_FLATPAK.md                       # Flatpak build guide (for AI assistants)
├── meson.build                            # Meson build configuration
└── com.github.samfic.filecollector.json   # Flatpak build manifest
```

## CLI Mode

FileCollector features a built-in CLI mode that allows you to perform all core operations through the terminal without launching the GUI, making it ideal for scripting and automation.

### Usage

Simply run `filecollector` with CLI arguments to enter command-line mode. If no CLI arguments are detected, the GUI starts normally.

```bash
filecollector [options...]
```

### Command Reference

| Option | Description |
|---|---|
| `--work-dir DIR` | Set the working directory |
| `--select-file PATH` | Add a file to the queue (can be used multiple times) |
| `--add-text "TEXT"` | Add custom text (can be used multiple times) |
| `--move FROM TO` | Move item at index FROM to index TO |
| `--remove INDEX` | Remove item at INDEX |
| `--clear` | Clear all items from the queue |
| `--list-items` | List all items in the current queue |
| `--export PATH` | Export merged text to file |
| `--absolute` | Use absolute paths |
| `--header` | Add header with working directory info |
| `--load FILE` | Load state from a project file |
| `--save FILE` | Save current state to a project file |
| `--help`, `-h` | Show this help message |

### Workflow Examples

**Build and export:**

```bash
filecollector --work-dir ./project \
    --select-file src/main.vala \
    --select-file src/utils/helper.vala \
    --add-text "=== Configuration Files ===" \
    --select-file config.ini \
    --move 3 2 \
    --header \
    --export output.txt
```

**Export from a project file:**

```bash
filecollector --load my.project.json --export output.txt
```

**Build and save a project (for use in GUI):**

```bash
filecollector --work-dir ./project \
    --select-file file1.txt --select-file file2.txt \
    --save my.project.json
```

**List the current queue:**

```bash
filecollector --load my.project.json --list-items
```

### Design Notes

CLI mode shares the same data model and business services (`ItemData`, `FileGenerator`, `ProjectManager`) with GUI mode, but does not depend on the GTK/Adw graphics libraries, making startup faster. The core CLI code resides in the standalone [cli.vala](src/cli.vala) file.

## Why Use This Tool?

1. **Solve the Context Dilemma in Programming Tools**: In programming tools, models need to make many tool calls to explore the workspace, which can easily be distracted by irrelevant files and deviate from the topic. Large projects can also trigger context compression. Additionally, large amounts of system prompts in programming tools consume a lot of tokens. This tool allows manual selection of important files, consolidating the context into a single file and handing it over to a web-based model (with relatively fewer system prompts) for deep reasoning such as bug analysis, maximizing model inference performance.

2. **Cost Control**: Most web-based models are free (or have free quotas), right?

## MCP (Model Context Protocol) Service

FileCollector has been wrapped as an MCP service, allowing LLMs in programming tools (such as Cursor, VS Code + Copilot) to directly call it to complete the following workflow:

1. The user gives the model in the programming tool a question or task (e.g., "This project has xx issues, please find the related files and export a single TXT file").
2. The model performs file exploration and uses this tool to select key files related to the issue.
3. The model inserts instructions (the problem to solve) at appropriate positions.
4. Call the tool to generate a structured TXT file.
5. The user uploads this TXT file to a web-based LLM (such as Claude, ChatGPT, etc.) for deep reasoning and problem-solving planning.
6. Based on the plan returned by the model, the user can use low-cost models in the programming tool to execute actual problem-solving operations.

This design separates **file exploration and code selection** (done by the model inside the programming tool) from **complex reasoning** (done by the web-based model), fully leveraging the strengths of different models while keeping costs controllable.

**Visit [filecollector-mcp-server](https://github.com/Sam-Fic/filecollector-mcp-server) for more details and installation instructions**

> Contributions and ideas are welcome!

## License

This project is licensed under the MIT License.

> This project was developed entirely through **vibe coding**.
