# FileCollector

<div align="center">
  <img src="data/com.github.samfic.filecollector.svg" alt="FileCollector" width="128" height="128">
</div>

[中文版](README.md) · [English Version](README_EN.md)

---

FileCollector is a cross-platform desktop tool for efficiently collecting, organizing files from your working directory, and generating merged text.  
It provides a checkable directory tree, flexible organization list, text insertion and automatic encoding detection, making it ideal for quickly consolidating key code or documents from a project into a single TXT file for further analysis or submission to large language models. The built-in AI assistant sidebar supports natural language-driven file exploration, selection, and orchestration.

## UI Preview

![FileCollector Screenshot](./screenshots/screenshot_en.png)

## Usage Guide

For the usage process and tips of the graphical interface, please refer to the [Usage Guide](docs/USAGE_EN.md).

## Features

- **CLI Mode**: Complete all core operations via terminal commands, ideal for scripting and automation
- **MCP Service**: Wrapped as an MCP (Model Context Protocol) service, callable directly by programming tools such as Cursor, VS Code + Copilot
- **Binary File Pre-conversion**: Automatically converts images, PDFs, Office documents, and other binary files into Markdown format, with caching and configurable extensions
- **AI Assistant Panel**: Built-in sidebar chat interface that lets AI directly drive file tree exploration, file selection, orchestration, and merged text generation
- **Progressive Experience**: Seamless handoff between CLI processing and GUI fine-tuning — AI can explore and organize files, then users can take over with the graphical interface at any time
- **Project Management**: Open and save projects
- **Phrase Management**: Manage and organize common phrases
- **Internationalization**: Supports Chinese and English UI, automatically follows system language
- **Modern UI**: Designed following GNOME Human Interface Guidelines

> **Tip**: If you are on a non-GNOME platform (such as Windows or macOS), please check out the [Flet version repository](https://github.com/Sam-Fic/filecollector). This version supports Windows, macOS, and Linux, and is built with Flet.

## Why Use This Tool?

1. **Solve the Context Dilemma in Programming Tools**: In programming tools, models need to make many tool calls to explore the workspace, which can easily be distracted by irrelevant files and deviate from the topic. Large projects can also trigger context compression. Additionally, large amounts of system prompts in programming tools consume a lot of tokens. This tool allows manual or MCP-assisted selection of important files, consolidating the context into a single file and handing it over to a web-based model (with relatively fewer system prompts) for deep reasoning such as bug analysis, maximizing model inference performance.

2. **Cost Control**: Most web-based models are free (or have free quotas), right?

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
sudo apt install meson valac libgtk-4-dev libadwaita-1-dev libjson-glib-dev libsoup-3.0-dev libgee-0.8-dev libcmark-gfm-dev blueprint-compiler gettext
```

#### Fedora

```bash
sudo dnf install meson vala gtk4-devel libadwaita-devel json-glib-devel libsoup3-devel libgee-devel cmark-gfm-devel blueprint-compiler gettext
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
filecollector --gui    # Force GUI mode (same as the first command when no other CLI args)
```

> **Tip**:
>
> - The application automatically uses Chinese or English UI based on your system language. To temporarily switch languages, use the `LANGUAGE` environment variable, e.g. `LANGUAGE=en filecollector` to force English display. This works for both GUI and CLI modes.
> - For CLI mode usage, see the [CLI Mode](#cli-mode) section below.
> - **GUI vs CLI behavior**: When any CLI arguments (`--work-dir`, `--select-file`, `--load`, etc.) are detected, the app runs in CLI mode without opening the GUI. **Exception**: Adding `--gui` forces GUI mode — CLI arguments are used only to initialize the interface state, then you can use the GUI for manual adjustments, if the GUI is running, CLI operations will be reflected in the GUI. This is useful when switching from MCP automation to human review.

### Flatpak Build

```bash
flatpak-builder build-dir com.github.samfic.filecollector.json --user --install --force-clean
flatpak run com.github.samfic.filecollector
```

You can also hand [BUILD_FLATPAK.md](BUILD_FLATPAK.md) directly to programming tools or AI Agents to leverage the existing mature workflow for standardized packaging.

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
│   ├── controllers/
│   │   ├── ai_controller.vala             # AI assistant controller
│   │   └── project_controller.vala        # Project controller
│   ├── models/
│   │   ├── app_state.vala                 # Application state model
│   │   └── item_data.vala                 # Queue item data model
│   ├── services/
│   │   ├── ai_client.vala                 # AI assistant backend (OpenAI-compatible API + Function Calling)
│   │   ├── ai_types.vala                  # AI shared type definitions
│   │   ├── binary_converter.vala          # Binary file to Base64 conversion (image scaling + document-to-PDF rendering)
│   │   ├── config_manager.vala            # Config/settings/phrases persistence
│   │   ├── file_generator.vala            # File merging and clipboard copy
│   │   ├── multimodal_ai_client.vala      # Multimodal AI client (sends Base64 images to vision models)
│   │   ├── preprocess_cache.vala          # Preprocessing cache (SHA256 hash + manifest management)
│   │   ├── project_manager.vala           # Project save and load
│   │   └── undo_manager.vala              # Undo/redo management
│   ├── utils/
│   │   ├── encoding_helper.vala           # Encoding auto-detection and conversion
│   │   └── glob_helper.vala               # Glob pattern matching utilities
│   ├── vapi/
│   │   └── cmark.vapi                     # cmark (Markdown) Vala bindings
│   └── widgets/
│       ├── ai_panel.vala                  # AI assistant chat panel (bubbles + tool call cards)
│       ├── ai_settings_dialog.vala        # AI assistant settings dialog
│       ├── markdown_view.vala             # Markdown rendering view
│       ├── phrases_picker.vala            # Common phrases picker and management
│       └── settings_dialog.vala           # Settings dialog
├── docs/                                  # Usage documentation
│   ├── images/                            # Documentation images
│   ├── USAGE.md                           # Chinese usage guide
│   └── USAGE_EN.md                        # English usage guide
├── en.po                                  # English UI translation file
├── POTFILES                               # List of translatable source files (for gettext)
├── LINGUAS                                # List of supported languages
├── BUILD_FLATPAK.md                       # Flatpak build guide (for AI assistants)
├── meson.build                            # Meson build configuration
└── com.github.samfic.filecollector.json   # Flatpak build manifest
```

### Keyboard Shortcuts

| Shortcut       | Action                  |
| -------------- | ----------------------- |
| `Ctrl+O`       | Open project            |
| `Ctrl+S`       | Save project            |
| `Ctrl+N`       | Clear all items         |
| `Ctrl+E`       | Add external files      |
| `Ctrl+I`       | Insert text above       |
| `Ctrl+Shift+I` | Insert text below       |
| `Ctrl+↑`       | Move item up            |
| `Ctrl+↓`       | Move item down          |
| `Delete`       | Delete selected item    |
| `Ctrl+G`       | Generate merged text    |
| `Ctrl+Shift+C` | Generate to clipboard   |
| `Ctrl+,`       | Language settings       |
| `Ctrl+/`       | Show keyboard shortcuts |
| `F1`           | About                   |
| `Ctrl+Q`       | Quit                    |

All shortcuts are also viewable via the **Keyboard Shortcuts** menu item.

## CLI Mode

FileCollector features a built-in CLI mode that allows you to perform all core operations through the terminal without launching the GUI, making it ideal for scripting and automation. Meanwhile, when the GUI is active, CLI mode can seamlessly integrate with the GUI to reflect its progress and status.

### Usage

Simply run `filecollector` with CLI arguments to enter command-line mode. If no CLI arguments are detected, the GUI starts normally.

```bash
filecollector [options...]
```

### Command Reference

| Option               | Description                                          |
| -------------------- | ---------------------------------------------------- |
| `--work-dir DIR`     | Set the working directory                            |
| `--select-file PATH` | Add a file to the queue (can be used multiple times) |
| `--add-text "TEXT"`  | Add custom text (can be used multiple times)         |
| `--move FROM TO`     | Move item at index FROM to index TO                  |
| `--remove INDEX`     | Remove item at INDEX                                 |
| `--clear`            | Clear all items from the queue                       |
| `--list-items`       | List all items in the current queue                  |
| `--export PATH`      | Export merged text to file                           |
| `--absolute`         | Use absolute paths                                   |
| `--header`           | Add header with working directory info               |
| `--load FILE`        | Load state from a project file                       |
| `--save FILE`        | Save current state to a project file                 |
| `--gui`              | Initialize state with CLI args then open the GUI     |
| `--help`, `-h`       | Show this help message                               |

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
filecollector --load my.project.fcol --export output.txt
```

**Build and save a project (for use in GUI):**

```bash
filecollector --work-dir ./project \
    --select-file file1.txt --select-file file2.txt \
    --save my.project.fcol
```

**List the current queue:**

```bash
filecollector --load my.project.fcol --list-items
```

**Load a project and open GUI for manual adjustment:**

```bash
filecollector --load my.project.fcol --gui
```

### Design Notes

CLI mode shares the same data model and business services (`ItemData`, `FileGenerator`, `ProjectManager`) with GUI mode, but does not depend on the GTK/Adw graphics libraries, making startup faster. The core CLI code resides in the standalone [cli.vala](src/cli.vala) file.

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

## AI Assistant Panel

FileCollector includes a built-in **sidebar AI assistant** that lets you drive the entire workflow using natural language directly in the GUI, without needing programming tools or MCP services. Click the **AI** button in the top-left corner of the toolbar to expand/collapse the sidebar.

### Key Capabilities

- **Natural Language Orchestration**: Tell the AI "add all Python files in the `src` directory, then insert a task description at the top" — the AI will automatically call tools to handle file selection, text insertion, reordering, and all other steps.
- **File Exploration & Reading**: The AI can browse the working directory's file tree and read file contents on demand to aid decision-making.
- **Real-time Feedback**: Every tool call (set working directory, add files, read files, reorder items, etc.) is displayed as an expandable tool card in real time, making results immediately clear.
- **Live GUI Sync**: When the AI modifies the orchestration list, the center panel updates the preview immediately, and you can take over to fine-tune at any time.

### Supported Tools (Function Calling)

The AI interacts with the GUI engine through the following tools (sharing the same semantics as CLI / MCP):

| Tool               | Purpose                                          |
| ------------------ | ------------------------------------------------ |
| `set_work_dir`     | Switch the working directory                     |
| `add_files`        | Batch-add files to the orchestration list        |
| `add_text`         | Insert custom text into the list                 |
| `remove_item`      | Remove a list item by id                         |
| `move_item`        | Reorder items                                    |
| `clear_items`      | Clear the orchestration list                     |
| `set_use_absolute` | Toggle absolute/relative path mode               |
| `set_show_header`  | Toggle whether to annotate the working directory |
| `list_files`       | Browse the working directory (recursive file listing) |
| `read_file`        | Read file contents (with line numbers)           |

### Binary File Pre-conversion (Multimodal AI)

FileCollector can automatically convert binary files into formats that multimodal AI can understand before sending them, eliminating manual preprocessing.

- **Image files** (PNG, JPEG, WebP, BMP, TIFF, etc.): Automatically scaled to a maximum of 2048px and encoded as Base64, then sent directly to multimodal AI for text extraction or content understanding.
- **Document files** (PDF, DOCX, PPTX, XLSX, ODT, ODP, ODS, RTF, etc.): First converted to PDF via LibreOffice, then rendered as image sequences via `pdftoppm`, and sent page-by-page to multimodal AI.
- **Conversion cache**: Converted results are cached in the `.filecollector_cache/` directory under the working directory. The system uses SHA256 file hashes to determine whether re-conversion is needed, avoiding redundant processing.
- **Configurable extensions**: In the AI Settings dialog, you can customize the list of binary file extensions allowed for multimodal AI processing. Changes automatically trigger re-evaluation of the preprocessing queue.

### Multimodal AI Configuration

Open **AI Settings** (Menu → AI Settings) and switch to the **Multimodal AI** tab:

1. Check **Enable Multimodal AI**.
2. Enter the **API Base URL** (compatible with OpenAI Chat Completions protocol, e.g., `https://api.openai.com/v1`).
3. Enter the **API Key** and **Model Name** (e.g., `gpt-4o`, `claude-3-opus`, or other vision-capable models).
4. (Optional) Customize the **Preprocessing Prompt** — leave empty to use the built-in prompt.
5. Click **Test Connection** to verify the configuration, then save.

### Configuration

Open **AI Settings** (Menu → AI Settings):

1. Check **Enable AI Assistant**.
2. Enter the **API Base URL** (compatible with OpenAI Chat Completions protocol, e.g., `https://api.openai.com/v1`; also works with Azure OpenAI, self-hosted gateways, local models like Ollama, etc.).
3. Enter the **API Key** and **Model Name** (e.g., `gpt-4o-mini`, `deepseek-chat`, etc.).
4. (Optional) Customize the **System Prompt** — leave empty to use the built-in orchestration prompt.
5. Click **Test Connection** to verify the configuration, then save.

All settings are stored in the `ai` field of `settings.json`. **API keys are stored locally only** and are never uploaded to any remote service.

### Usage Examples

> Please add all AI sidebar-related files in this project to the orchestration, then insert a description text at the beginning.

AI's processing flow: calls `list_files` to locate AI sidebar-related files (`ai_panel.vala`, `ai_client.vala`, `ai_settings_dialog.vala`) → `add_files` to batch-add them to the orchestration list → `add_text` to insert explanatory text at the beginning.

> Export to `output.txt` using relative paths, and include a working directory header.

AI's processing flow: calls `set_use_absolute(False)` and `set_show_header(True)`, then triggers the GUI export process.

### Progressive Experience

GUI and CLI are combined to enable seamless human-AI collaboration:

1. Use MCP service in Cursor for the LLM to automatically explore and organize project files.
2. When the generated file list requires manual adjustment, run `filecollector --load ~/.config/filecollector/mcp_state.fcol --gui` in the terminal. The `--gui` flag ensures the GUI opens (without it, the command runs in CLI mode only).
3. The GUI opens, displaying the model's selected file list. You can check, reorder, and save.
4. Return to Cursor for the LLM to continue subsequent work.

## License

This project is licensed under the MIT License.

> This project was developed entirely through **vibe coding**.

> Contributions and ideas are welcome!
