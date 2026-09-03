# FileCollector 安全审计报告

> **审计范围**：`src/` 目录下所有 Vala/C 源码，重点关注 Token / API Key 的存储、传输、清理、跨平台抽象。
> **审计时间**：基于当前 `src/` 树（约 424 处 token/key/secret/auth 相关引用）。
> **结论总览**：项目在密钥存储上**设计良好**（优先 libsecret / DPAPI / Keychain，配置文件不落明文），但仍有若干**可改进的纵深防御点**和**潜在风险**需要关注。

---

## 1. 整体安全设计（做得好的地方）

### 1.1 跨平台密钥存储抽象（`src/services/secret_store.vala`）

| 平台 | 存储方式 | 实现位置 |
|------|----------|----------|
| Linux | libsecret（GNOME Keyring / KWallet） | `secret_store.vala:212-243` |
| Windows | DPAPI（`CryptProtectData` / `CryptUnprotectData`） | `secret_store.vala:23-118` + `win32_dpapi_shim.c` |
| macOS | SecKeychain `SecKeychainAddGenericPassword` | `secret_store.vala:120-208` |

✅ **优点**：
- API Key / PaddleOCR Token **不写明文**到 `settings.json`（`config_manager.vala:478, 540, 624, 729` 等多处显式置空）。
- 支持从 JSON 中**自动迁移明文**到密钥环（`config_manager.vala:336-345, 497-505, 585-593, 695-703`），迁移成功后才清空明文。
- 使用**每 profile 独立槽位**（`secret_store.vala:262-275`），通过 `g_str_hash` 区分同名 profile，避免密钥混淆。
- 旧版 macOS bug 已修（`secret_store.vala:158-160` 注释：以前查询时误删条目，现已分离 `macos_find` / `macos_delete`）。
- DPAPI buffer 显式补 `\0`（`secret_store.vala:89-93`），避免越界。

### 1.2 配置文件权限

- 配置目录使用 `Environment.get_user_config_dir ()`（即 `~/.config/filecollector/`），**不**放在 `/tmp` 或共享目录。
- 用户级 0755 目录权限（`zip_exporter.vala:26, preprocess_cache.vala:22` 等）是合理的，因为密钥本身已经走系统密钥环，磁盘文件不含敏感信息。

### 1.3 .gitignore

- 包含 `build/`、`*.log`、`.vscode/`、`.trae/`、`.codebuddy/` 等常见敏感/构建目录。
- 但 **未忽略 `data/` 目录**（请见下方 §3.1）。

### 1.4 历史 commit 检查

- `git log --all -p` 中未发现真实 API Key 泄露（如 `sk-...`、`ghp_...`、`AKIA...`）。
- 仅发现 `"api_key": "ollama"`（Ollama 本地占位符，非真密钥）。

---

## 2. 风险等级与建议

### 🔴 高风险（建议尽快修复）

#### 2.1 明文 HTTP 端点无强制拦截

**位置**：`src/services/ai_client.vala:36-37`、`src/services/multimodal_ai_client.vala:6-14`、PaddleOCR / 多模态客户端。

**问题**：仅在 `preferences_dialog.vala:305` 给出**警告提示**，但**允许保存** `http://` 端点。代码注释也明说「用户若配 HTTP 端点, 自负本地网络安全」（`ai_client.vala:36`）。这意味着：
- API Key 会以**明文 HTTP**经网络明文传输；
- 任何同子网/MITM 攻击者可直接窃取 Bearer Token。

**修复建议**：
```vala
// 在 ConfigManager.save_ai_settings 中增加校验
if (s.base_url.has_prefix ("http://")
    && s.base_url != "http://localhost"
    && !s.base_url.has_prefix ("http://127.")) {
    throw new ConfigError.INSECURE_ENDPOINT (...);
}
```
或至少在 GUI 中要求二次确认（不是仅显示一行警告文字）。

#### 2.2 临时文件未清理

**位置**：`binary_converter.vala:108` 创建 `task_dir` 模式 0700（OK），但**未发现统一清理逻辑**——导出的临时文件、调试日志、PaddleOCR 测试上传的 1×1 PNG（`preferences_dialog.vala:1037-1047`）会**残留在磁盘**。

**风险**：如果未来加入新的文件类型临时落盘，可能跨用户留存。

**建议**：在应用退出/任务完成时统一清理 `Environment.get_tmp_dir ()/filecollector-*/`，或为每个临时目录注册 `try { ... } finally { cleanup (); }`。

---

### 🟡 中风险（建议在下个版本修复）

#### 2.3 macOS Keychain 调用使用已废弃 API

**位置**：`secret_store.vala:121-130, 150, 164, 188`。

**问题**：
- `SecKeychainAddGenericPassword` / `SecKeychainFindGenericPassword` 自 **macOS 12 (Monterey)** 起被 Apple 标记为 deprecated。
- 目标平台是 macOS（README 中明确支持），未来 SDK / macOS 版本可能编译失败或行为变化。
- Keychain API 在 sandbox / notarized app 下行为差异较大。

**建议**：迁移到 `kSecClassGenericPassword` + `SecItemAdd` / `SecItemCopyMatching`（Security framework 现代 API）。

#### 2.4 Windows DPAPI 缺少熵参数

**位置**：`secret_store.vala:60-62, 79-81`、`win32_dpapi_shim.c:18-37`。

**问题**：`optional_entropy` 传 `NULL` 而非应用级熵值（"filecollector-<scheme>"）。
- DPAPI 默认熵为 NULL 时，**同一用户的所有 CryptProtectData 数据可被任意知道 application description 的进程解密**。
- 加入 per-scheme 熵（`pOptionalEntropy` 传入 "io.github.sam_fic.filecollector.api_key" 字节）可让不同槽位相互隔离，并防止其他应用误用。

**建议**：
```vala
var entropy_blob = DATA_BLOB () {
    cbData = slot.length,
    pbData = (void*) slot
};
CryptProtectData (&in_blob, "filecollector", &entropy_blob, ...);
```

#### 2.5 settings.json 中仍可能短暂存在明文 key

**位置**：`config_manager.vala:336-345, 497-505, 585-593, 695-703` 的"迁移路径"。

**流程**：
1. 用户手动把 `"api_key": "sk-real-key"` 写到 `settings.json`。
2. 下次启动：`load_xxx_settings` 读取 → 写入密钥环 → **清空 JSON**。

**风险**：
- "清空 JSON" 通过 `write_settings_root_unlocked` 走 `atomic_write_json`（`config_manager.vala:933-947`），是**先写 tmp 再 rename**——OK。
- 但如果**密钥环 store 失败**（`store_api_key_to_keyring (json_key)` 返回 false），代码**不会回滚**，下次启动仍会再次尝试迁移。**不是漏洞但增加攻击面**：用户可能误以为迁移成功而把 `settings.json` 同步到云盘。

**建议**：在迁移失败时给出明确 GUI 警告，并增加「不持久化明文」的回退策略。

#### 2.6 Token 在内存中无显式擦除

**位置**：`AIClient.api_key`（`ai_client.vala:439-447`），`MultimodalAIClient.api_key`，`PaddleOCRClient.token`，`ConfigManager.AIProfile.api_key`。

**问题**：Vala 字符串在 GObject 析构后底层 `g_free` 释放，**原始字节仍残留在堆上**直到被覆盖。如果攻击者能 dump 进程内存（例如 `/proc/<pid>/mem` 在 ptrace 关闭下仍可读 root 进程），可恢复密钥。

**建议（可选）**：
- 不存储时用 `SecureMemory.wipe (buf)`（GLib 2.78+ 提供 `g_steal_fd` 但无 wipe API，可自实现 `memset_explicit`）。
- 对于桌面端 LLM 工具，这通常**不是优先项**，因为 OS 已经隔离了用户进程。

#### 2.7 VLM 客户端池的 settings_signature 包含密钥

**位置**：`vlm_task_runner.vala:34`。

```vala
string token_key = (s.provider == ConfigManager.PROVIDER_PADDLEOCR) ? s.paddleocr_token : s.api_key;
return "%s|%s|%s|%s|%g".printf (s.provider, token_key, ...);
```

**风险**：低。`settings_signature` 是私有方法，仅在客户端池复用判断中调用，**未**写入日志。但若未来加 `debug ("signature=%s", sig)` 类的日志，会**完整泄露 api_key**。

**建议**：在注释中加"Do not log"警示，或对 signature 做一次 `HashFunc` 摘要。

---

### 🟢 低风险 / 改进建议

#### 2.8 API Key 不会因为进程崩溃/被杀而泄露到 coredump

✅ 代码未发现把 key 写入临时文件、未序列化进 JSON / GLib Variant 持久化层。崩溃时一般不会泄露。

#### 2.9 Tool 调用中的路径白名单

✅ `ai_controller.vala:940-952` 实现了 `is_path_in_work_dir` / `is_path_allowed_for_work_dir`，AI 不能跨工作目录读文件，且有 `normalize_path` 防御 symlink 逃逸。

**小问题**：仅允许 `home_dir` 和 `work_dir` 两个根，但 AI 调用 `set_work_dir` 后可以**切换**到 home 之外的目录（前提是本身在 home 下）——这本身是 feature。

#### 2.10 缺少针对"全屏 PaddleOCR 上传"的速率限制

**位置**：`paddleocr_client.vala:60-90` 直接读整个 `file_bytes` 一次性上传。

**风险**：大文件（数百 MB）上传会被一次性加载到内存。如果用户错误指向 `/dev/zero` 或巨型文件，可能 OOM。

**建议**：增加 `max_upload_size` 配置和预检查。

#### 2.11 `preferences_dialog.vala:1047` 1×1 PNG 测试上传不撤销

测试用 PNG 字节流直接 inline 在源码中（`preferences_dialog.vala:1037-1047`），会真**实打**到 PaddleOCR 生产服务。
- 不是安全问题，但**滥用风险**：用户每天点 100 次 Test，会触发对方后端的作业排队与计费（如果是按作业计费的 SaaS）。
- 建议：客户端 throttle（每分钟最多 1 次测试），并在 UI 上显示「上次测试时间」。

#### 2.12 VLM 测试连接的最小图片是 hardcoded 字节流

`preferences_dialog.vala:1037-1047`：1×1 透明 PNG 内联。这是必要的功能，但要注意这是**用户启动的请求**，不会被自动滥用。

#### 2.13 `.gitignore` 未覆盖 `data/` 下的运行时产物

```gitignore
# 没有忽略 ~/.config 目录 (当然这是运行时的，不在 repo)
# 但要注意: data/ 目录被提交, 请确认其中不含 token
```

`data/` 目录从 git 历史看是图标和资源，但**建议**在 `data/` 下加一个 `*.local.json` 之类的约定，开发者本地配置不进入仓库。

#### 2.14 `data/` 目录内容核查

✅ `data/` 目录**只包含**应用资源（图标、grsource、metainfo、桌面文件、gtksourceview 主题、style.css），**无任何敏感信息**。

#### 2.15 macOS Keychain 调用没有明确的 Access Control

`secret_store.vala:155-160` 的 `SecKeychainAddGenericPassword` 使用 `null` keychain，等价于默认 keychain。任何**同一用户**的进程都能读取——这是预期行为（同用户应用共享），但如果项目未来打算上架 Mac App Store，需要 `kSecAttrAccessGroup` + `kSecAttrAccessible` 限定为 `kSecAttrAccessibleWhenUnlocked`。

#### 2.16 `paddleocr_client.vala:106` 的 `optionalPayload` JSON 拼接

```vala
string optional_str = opt_gen.to_data (null);
multipart.append_form_string ("optionalPayload", optional_str);
```

`to_data (null)` 在 GLib 2.70+ 返回 `string?`，需要 null check。虽然 `opt_gen` 是局部变量，这里**没有空指针风险**，但建议显式 `to_data (out size_t len)` 拿到长度，更稳。

#### 2.17 HTTP 客户端未配置 TLS 证书固定或严格校验

`Soup.Session` 默认接受系统 CA 链。**没有问题**——大多数 LLM 工具不应做证书固定（会破坏 forward secrecy），但建议：

- 在 About/Preferences 增加「使用系统 CA 池」说明。
- 若未来支持企业代理，确保 `Soup.Session` 不被 `set_property ("proxy-resolver", ...)` 改写为可疑代理。

#### 2.18 Multi-format 导出器未对输出文件名做消毒

**位置**：`multi_format_exporter.vala`（未深入审计）—— 导出到 ZIP / Markdown 时文件名直接来自工作目录。如果工作目录含奇怪 Unicode / control chars，可能在某些解压工具上触发 CVE。建议在 `zip_exporter.vala` 增加 `Path.get_basename` 校验并替换非法字符。

---

## 3. 总结

| 维度 | 评估 |
|------|------|
| **API Key 静态存储** | ✅ 优秀（libsecret / DPAPI / Keychain，配置无明文） |
| **API Key 传输** | ⚠️ 依赖用户配置 HTTPS 端点；未拦截 `http://` |
| **代码质量与安全意识** | ✅ 注释清晰，路径白名单、原子写入、buffer 越界防护都做得到位 |
| **跨平台抽象** | ✅ 优雅，但 macOS 端使用 deprecated API |
| **内存安全** | ✅ 没有 `strcpy` 风格代码，但密钥无显式擦除（可接受） |
| **历史 commit** | ✅ 无密钥泄露（仅 `api_key: "ollama"` 占位符） |
| **Tool 权限** | ✅ AI 工具调用有路径白名单 + symlink 防护 |

### 优先修复顺序

1. **§2.1**：明文 HTTP 端点硬拦截（`save_ai_settings` 校验）。
2. **§2.4**：DPAPI 引入 per-scheme 熵。
3. **§2.3**：macOS 迁移到 `SecItem*` API。
4. **§2.5**：密钥环 store 失败时 GUI 警告。
5. **§2.11**：PaddleOCR 测试连接加 throttle。

### 不需要修复（已是最佳实践）

- §1.1 SecretStore 跨平台抽象
- §1.2 配置目录位置
- §2.6 内存擦除（OS 已隔离用户进程）
- §2.9 AI 工具路径白名单
- §2.17 TLS 信任系统 CA（合理默认）

---

## 4. 附录：审计方法

```bash
# 1. 搜索所有 token / key 相关引用
grep -rn -E "(api_key|token|secret|password|Bearer|Authorization)" src/

# 2. 搜索硬编码密钥模式
grep -rn -iE "(sk-[a-zA-Z0-9]{20,}|sk-proj-|ghp_|AKIA[A-Z0-9]{16})" .

# 3. 扫描 git 历史
git log --all -p | grep -iE "(api_key|sk-|token|secret|password)"

# 4. 检查 .gitignore 与运行时配置目录
cat .gitignore
ls -la ~/.config/filecollector/  # 运行时生成, 不在仓库
```

---

**审计人**: MiniMax-M3
**审计依据**: 源码静态分析 + git 历史扫描 + 跨平台最佳实践对照

