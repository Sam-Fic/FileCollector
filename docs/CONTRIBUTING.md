# 代码风格与贡献指南

本文档说明 FileCollector 的代码风格约定、lint 工具使用方式和提 PR 前的检查流程。涉及代码修改、提交 PR、运行 lint 等工作时，请先阅读本文档。

> **适用场景**：修改 `src/` 下任何源码、提交 Pull Request、运行或配置 vala-lint。

---

## 代码风格

项目遵循 [elementary Code-Style guidelines](https://docs.elementary.io/develop/os/code/style)，主要约定如下：

| 类别 | 约定 | 示例 |
| --- | --- | --- |
| 方法名、变量名 | `snake_case` | `get_file_path()`、`item_data` |
| 类名 | `PascalCase` | `AiClient`、`ProjectManager` |
| 常量 | `ALL_CAPS` | `MAX_FILE_SIZE`、`UUID` |

其他要点：
- 使用 4 空格缩进，**不用 Tab**。
- 行尾不留空白字符。
- 文件末尾保留一个空行。
- 字符串模板中不使用多余的花括号（Vala 字符串模板为 `@"..."`）。
- 大括号前保留一个空格。

---

## vala-lint

项目使用 [io.elementary.vala-lint](https://github.com/elementary/vala-lint) 校验代码风格。

### 运行 lint

```bash
# 仅检查
io.elementary.vala-lint -c vala-lint.conf src/

# 自动修复部分问题
io.elementary.vala-lint -c vala-lint.conf --fix src/
```

### lint 规则

配置文件为 `vala-lint.conf`，规则分三个等级：

| 等级 | 含义 | CI 影响 |
| --- | --- | --- |
| `error` | 触发非零退出码 | CI 构建失败 |
| `warn` | 仅打印警告 | 不影响 CI |
| `off` | 完全关闭 | 不检查 |

当前设为 `error` 的规则：`block-opening-brace-space-before`、`double-semicolon`、`double-spaces`、`ellipsis`、`naming-convention`、`no-space`、`space-before-paren`、`use-of-tabs`、`trailing-newlines`、`trailing-whitespace`、`unnecessary-string-template`。

当前设为 `warn` 的规则：
- `line-length`：最大 120 字符。设为 warn 而非 error，因为 AI 提示词、中文注释、URL 行常超 120 字符，设为 error 会立刻阻塞 CI。后续可逐步收紧。
- `note`：扫描 `TODO`、`FIXME`、`XXX`、`HACK` 标记。

### 命名约定例外

`vala-lint.conf` 中 `[naming-convention]` 的 `exceptions` 字段列出了全大写标识符（Vala 常量约定），不算违反命名约定：

```ini
[naming-convention]
exceptions=UUID,MAX_FILE_CONTENT_SIZE,MAX_FILE_SIZE,PEEK_SIZE
```

如果新增了全大写常量，需要将其添加到此列表中，否则 lint 会报 `naming-convention` error。

---

## .valalintignore

创建 `.valalintignore` 后，vala-lint **不再读取 `.gitignore`**，因此需要在 `.valalintignore` 中手动重复 `.gitignore` 中仍要忽略的模式。

当前 `.valalintignore` 忽略的目录和模式：

| 类别 | 忽略模式 |
| --- | --- |
| 构建产物 | `build`、`builddir`、`build-dir`、`build-flatpak`、`_build` |
| Meson/Ninja | `.ninja_deps`、`.ninja_log`、`compile_commands.json`、`meson-private`、`meson-info`、`meson-logs` |
| Vala 编译生成 | `*.c`、`*.h` |
| GTK 资源 | `*-resources.c`、`*-resources.h` |
| 第三方 VAPI | `src/vapi` |
| 翻译 | `po`、`locale` |
| 数据/文档/截图 | `data`、`docs`、`screenshots`、`tools` |

> **注意**：如果修改了 `.gitignore` 的忽略规则，需要同步检查 `.valalintignore` 是否也需要更新。两者不会自动同步。

---

## .c / .h 文件与 .gitignore 的关系

`.gitignore` 中 `*.c` 和 `*.h` 规则会忽略所有 C 源码和头文件，这主要针对 Vala 编译器生成的中间文件。但项目中有少量手写的 C 源码需要纳入版本库：

| 文件 | 用途 |
| --- | --- |
| `src/win32_dpapi_shim.c` | Windows DPAPI 密钥存储的 C shim |
| `src/win32_dpapi_shim.h` | 上述文件的声明 |
| `src/macos_keychain_shim.c` | macOS Keychain 密钥存储的 C shim |
| `src/macos_keychain_shim.h` | 上述文件的声明 |

这些文件已通过 `git add -f` 强制追踪。如果新增了需要追踪的 `.c` 或 `.h` 文件，使用 `git add -f <file>` 强制添加，否则会被 `.gitignore` 忽略。

---

## 提 PR 前检查清单

- [ ] 本地运行 `io.elementary.vala-lint -c vala-lint.conf src/` 无 error
- [ ] 新增的全大写常量已添加到 `vala-lint.conf` 的 `exceptions`
- [ ] 修改了 `.gitignore` 后同步检查了 `.valalintignore`
- [ ] 新增的手写 `.c` / `.h` 文件已用 `git add -f` 追踪
- [ ] `meson compile` 构建通过
- [ ] 提交信息清晰描述变更内容和原因
- [ ] 不包含 `build/` 目录、`*.o`、`*.log` 等构建产物
