using Gee;

/**
 * AI 设置相关错误域。INSECURE_ENDPOINT 用于拒绝明文 HTTP 端点,
 * 防止 API Key 在网络上被明文传输.
 */
public errordomain ConfigError {
    INSECURE_ENDPOINT,
    INVALID_URL,
}

/**
 * 不安全 base_url 拒绝事件 (静态事件, 因为 ConfigManager 是纯静态类,
 * 无法通过 GLib.Object signal 派发). GUI 在初始化时注册回调,
 * 收到通知后用 toast 提示用户.
 */
public delegate void InsecureUrlHandler (string url, string reason);

/**
 * 明文密钥迁移失败事件.
 *
 * 当 settings.json 中检测到明文 api_key / paddleocr_token, 但调
 * SecretStore.store_* 写入密钥环返回 false (例如 libsecret 服务未启动,
 * macOS Keychain 拒绝访问, Windows DPAPI 失败等) 时调用.
 *
 * 参数 slot 是人类可读的密钥项名 (例如 "Sidebar API Key" /
 * "Multimodal API Key" / "PaddleOCR Token"). 警告内容应避免拼出明文.
 */
public delegate void KeyringMigrationFailedHandler (string slot, string reason);

public class ConfigManager : GLib.Object {
    public const string DEFAULT_AI_BASE_URL = "https://api.openai.com/v1";
    public const string DEFAULT_AI_MODEL = "gpt-4o-mini";
    public const double DEFAULT_AI_TIMEOUT = 60.0;

    // ── 不安全 base_url 通知 ──────────────────────────────────────────
    // ConfigManager 是纯静态类, GLib.Object signal 不能用. 用一个静态委托槽
    // 代替, GUI 初始化时注册一次, save_* 检测到不合法端点时调用, 走 toast 提示.
    private static InsecureUrlHandler? insecure_url_handler = null;
    public static void set_insecure_url_handler (InsecureUrlHandler? h) {
        insecure_url_handler = h;
    }
    private static void notify_insecure_url (string url, string reason) {
        warning ("ConfigManager: insecure base_url rejected: %s (%s)", url, reason);
        if (insecure_url_handler != null) insecure_url_handler (url, reason);
    }

    // ── 密钥环迁移失败通知 ────────────────────────────────────────
    // settings.json 中检测到明文密钥 -> 调用 SecretStore.store_*_api_key ->
    // 返回 false (libsecret 未启动 / Keychain 拒绝 / DPAPI 错误).
    // 此时 JSON 中的明文不能删除, 下次启动还会再看到. GUI 收到事件后
    // 应: 1) toast 一次性提示; 2) 在偏好设置/主窗口持久展示警告 banner,
    // 提醒用户在 config UI 里重新填一次 (本次保存会重试写入).
    private static KeyringMigrationFailedHandler? migration_failed_handler = null;
    public static void set_keyring_migration_failed_handler (KeyringMigrationFailedHandler? h) {
        migration_failed_handler = h;
    }
    private static void notify_migration_failed (string slot, string reason) {
        warning ("ConfigManager: keyring migration failed for %s: %s", slot, reason);
        if (migration_failed_handler != null) migration_failed_handler (slot, reason);
    }

    /**
     * 校验 base_url 是否安全 (HTTPS 或本地回环).
     * 非安全端点会抛 ConfigError.INSECURE_ENDPOINT, 阻止 save_* 写入磁盘.
     *
     * 允许的端点:
     *   - https:// 任意主机
     *   - http://localhost 或 http://127.0.0.0/8 (本地 Ollama 等)
     *
     * 不允许的端点 (示例):
     *   - http://192.168.x.x  (局域网明文, 易被中间人)
     *   - http://api.openai.com (公网明文, 严重风险)
     */
    public static void validate_base_url (string url) throws ConfigError {
        if (url == null || url.length == 0) {
            throw new ConfigError.INVALID_URL (_("API Base URL is empty"));
        }
        string trimmed = url.strip ();
        if (trimmed.has_prefix ("https://")) return;
        if (trimmed.has_prefix ("http://")) {
            // 提取 host 部分 (跳过 "http://" 前缀, 到 ':' / '/' / '?' / '#' / 末尾)
            string host = trimmed.substring (7);
            int cut = -1;
            for (int i = 0; i < host.length; i++) {
                char c = host[i];
                if (c == ':' || c == '/' || c == '?' || c == '#') {
                    cut = i; break;
                }
            }
            if (cut >= 0) host = host.substring (0, cut);
            host = host.down ();
            if (host == "localhost" || host == "127.0.0.1" || host == "::1"
                || host.has_prefix ("127.")) {
                return;
            }
            throw new ConfigError.INSECURE_ENDPOINT (
                _("Insecure endpoint: HTTP (non-HTTPS) is only allowed for localhost. " +
                  "Public/remote endpoints must use HTTPS to protect the API key."));
        }
        // 既不是 http 也不是 https, 可能是 file:// / ftp:// 等, 视为不安全
        throw new ConfigError.INVALID_URL (
            _("Unsupported URL scheme: only http(s) is accepted. URL was: %s").printf (url));
    }


    // 默认忽略的目录列表
    public const string[] DEFAULT_IGNORED_DIRS = {
        ".git", "node_modules", "__pycache__", "build", ".venv", "venv",
        "dist", "target", ".idea", ".vscode", "coverage"
    };

    // 默认允许被多模态 AI 转换的二进制扩展名
    public const string[] DEFAULT_ALLOWED_BINARY_EXTS = {
        ".pdf", ".docx", ".pptx", ".doc", ".ppt",
        ".xlsx", ".xls", ".ods", ".odt", ".odp", ".rtf", ".wps",
        ".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tiff", ".tif"
    };

    // VLM 服务商枚举. "openai" 为现有 OpenAI 兼容路径; "paddleocr" 为百度
    // 智能云 PaddleOCR 云端 API 预设 (仅需填写一个 TOKEN).
    public const string PROVIDER_OPENAI = "openai";
    public const string PROVIDER_PADDLEOCR = "paddleocr";

    public struct AISettings {
        public bool enabled;
        public string profile_name;  // 当前激活的 ai_models 配置方案名, 空串表示尚未选择
        public string base_url;
        public string api_key;
        public string model;
        public string system_prompt_override;
        public double timeout;
    }

    /**
     * 单个 AI 模型配置方案 (多模型预设)。
     *
     * 持久化于 settings.json 的 "ai_models" 数组, 每项形如:
     *   { "name": "...", "base_url": "...", "model": "...", "timeout": 60.0,
     *     "system_prompt_override": "", "api_key": "" }
     * api_key 在 JSON 中恒为空串, 实际密钥按 profile 名存入系统密钥环;
     * 手写在 JSON 里的明文密钥会在加载时自动迁移到密钥环并清空。
     */
    public class AIProfile : GLib.Object {
        public string name = "";
        public string base_url = "";
        public string api_key = "";   // 仅内存持有, 落盘走 SecretStore
        public string model = "";
        public string system_prompt_override = "";
        public double timeout = DEFAULT_AI_TIMEOUT;
    }

    // ─── 密钥存储 (跨平台: Linux libsecret / Win DPAPI / macOS Keychain) ──
    // 由 SecretStore 命名空间统一处理平台差异, 见 src/services/secret_store.vala

    // 将 API Key 存入系统密钥环; key 为空时清除密钥环中的条目
    private static bool store_api_key_to_keyring (string api_key) {
        return SecretStore.store_api_key (api_key);
    }

    // 从系统密钥环读取 API Key; 失败或不存在时返回 null
    private static string? load_api_key_from_keyring () {
        return SecretStore.load_api_key ();
    }

    // ─── 配置目录 / 文件路径 ───────────────────────────────────────────

    private static string get_config_dir () {
        var dir = Environment.get_user_config_dir ();
        var config_dir = GLib.Path.build_filename (dir, "filecollector");
        try {
            var config_file = File.new_for_path (config_dir);
            if (!config_file.query_exists ()) {
                config_file.make_directory_with_parents (null);
            }
        } catch (Error e) {
            warning ("Failed to create config dir: %s", e.message);
        }
        return config_dir;
    }

    private static string get_phrases_file () {
        return GLib.Path.build_filename (get_config_dir (), "common_phrases.json");
    }

    private static string get_settings_file () {
        return GLib.Path.build_filename (get_config_dir (), "settings.json");
    }

    // 供 GUI 展示配置文件位置 (多模型方案 ai_models 所在文件)
    public static string get_settings_file_path () {
        return get_settings_file ();
    }

    public static string get_recovery_file () {
        return GLib.Path.build_filename (get_config_dir (), "recovery.fcol");
    }

    // ─── 全局互斥锁，保护配置文件原子操作 ──────────────────────────────

    private static GLib.Mutex config_mutex;

    // ─── 通用设置读写 ──────────────────────────────────────────────────

    public static string load_settings_language () {
        config_mutex.lock ();
        try {
            var root = load_settings_root_unlocked ();
            if (root == null) return "";
            return root.get_string_member_with_default ("language", "");
        } catch (Error e) {
            warning ("Failed to load settings: %s", e.message);
            return "";
        } finally {
            config_mutex.unlock ();
        }
    }

    public static void save_language_setting (string lang) {
        config_mutex.lock ();
        try {
            Json.Object root = load_settings_root_unlocked () ?? new Json.Object ();
            root.set_string_member ("language", lang);
            write_settings_root_unlocked (root);
        } catch (Error e) {
            warning ("Failed to save language setting: %s", e.message);
        } finally {
            config_mutex.unlock ();
        }
    }

    public static void load_common_phrases (Gee.ArrayList<string> common_phrases) {
        var file = get_phrases_file ();
        if (!FileUtils.test (file, FileTest.EXISTS)) {
            return;
        }
        try {
            string content;
            size_t len;
            FileUtils.get_contents (file, out content, out len);
            var parser = new Json.Parser ();
            parser.load_from_data (content);
            var root = parser.get_root ().get_array ();
            for (int i = 0; i < root.get_length (); i++) {
                common_phrases.add (root.get_string_element (i));
            }
        } catch (Error e) {
            warning ("Failed to load common phrases: %s", e.message);
        }
    }

    public static void save_common_phrases (Gee.ArrayList<string> common_phrases) {
        try {
            var builder = new Json.Builder ();
            builder.begin_array ();
            for (int i = 0; i < common_phrases.size; i++) {
                builder.add_string_value (common_phrases.get (i));
            }
            builder.end_array ();

            var generator = new Json.Generator ();
            generator.set_root (builder.get_root ());
            generator.pretty = true;

            var file = get_phrases_file ();
            atomic_write_json (generator, file);
        } catch (Error e) {
            warning ("Failed to save common phrases: %s", e.message);
        }
    }

    // ─── 忽略目录列表读写 ────────────────────────────────────────────────

    public static string[] get_ignored_dirs () {
        config_mutex.lock ();
        try {
            var root = load_settings_root_unlocked ();
            if (root != null && root.has_member ("ignored_dirs")) {
                var arr = root.get_array_member ("ignored_dirs");
                if (arr != null && arr.get_length () > 0) {
                    string[] result = new string[arr.get_length ()];
                    for (int i = 0; i < arr.get_length (); i++) {
                        result[i] = arr.get_string_element (i);
                    }
                    return result;
                }
            }
        } catch (Error e) {
            warning ("Failed to load ignored_dirs: %s", e.message);
        } finally {
            config_mutex.unlock ();
        }
        return DEFAULT_IGNORED_DIRS;
    }

    public static void save_ignored_dirs (string[] dirs) {
        config_mutex.lock ();
        try {
            Json.Object root = load_settings_root_unlocked () ?? new Json.Object ();
            var arr = new Json.Array ();
            foreach (var dir in dirs) {
                arr.add_string_element (dir);
            }
            root.set_member ("ignored_dirs", AI.SchemaHelper.arr_to_node (arr));
            write_settings_root_unlocked (root);
        } catch (Error e) {
            warning ("Failed to save ignored_dirs: %s", e.message);
        } finally {
            config_mutex.unlock ();
        }
    }

    // ─── 允许被多模态 AI 转换的二进制扩展名列表读写 ──────────────────────

    public static string[] get_allowed_binary_extensions () {
        config_mutex.lock ();
        try {
            var root = load_settings_root_unlocked ();
            if (root != null && root.has_member ("allowed_binary_extensions")) {
                var arr = root.get_array_member ("allowed_binary_extensions");
                if (arr != null && arr.get_length () > 0) {
                    string[] result = new string[arr.get_length ()];
                    for (int i = 0; i < arr.get_length (); i++) {
                        result[i] = arr.get_string_element (i);
                    }
                    return result;
                }
            }
        } catch (Error e) {
            warning ("Failed to load allowed_binary_extensions: %s", e.message);
        } finally {
            config_mutex.unlock ();
        }
        return DEFAULT_ALLOWED_BINARY_EXTS;
    }

    public static void save_allowed_binary_extensions (string[] exts) {
        config_mutex.lock ();
        try {
            Json.Object root = load_settings_root_unlocked () ?? new Json.Object ();
            var arr = new Json.Array ();
            foreach (var ext in exts) {
                arr.add_string_element (ext);
            }
            root.set_member ("allowed_binary_extensions", AI.SchemaHelper.arr_to_node (arr));
            write_settings_root_unlocked (root);
        } catch (Error e) {
            warning ("Failed to save allowed_binary_extensions: %s", e.message);
        } finally {
            config_mutex.unlock ();
        }
    }

    // ─── 多模态 AI 设置 ──────────────────────────────────────────────────

    public struct MultimodalAISettings {
        public bool enabled;
        public string profile_name;  // 当前激活的 vlm_models 配置方案名, 空串表示尚未选择
        public string provider;  // PROVIDER_OPENAI | PROVIDER_PADDLEOCR, 缺省 "openai"
        public string base_url;
        public string api_key;
        public string model;
        public string paddleocr_token;  // 仅 PaddleOCR 模式使用, 走 SecretStore
        public string system_prompt_override;
        public double timeout;
        // 并发预处理任务的线程数. 不同模型提供商的速率限制/并发上限不同,
        // 故开放为设置项由用户按其提供商的约束填写 (默认 3).
        public int max_concurrency;
    }

    /**
     * 单个 VLM (多模态) 模型配置方案。
     *
     * 持久化于 settings.json 的 "vlm_models" 数组, 字段结构同 AIProfile,
     * 额外多出 provider (openai | paddleocr) 与 paddleocr_token。
     * api_key / paddleocr_token 在 JSON 中恒为空串, 按方案名存入系统密钥环。
     */
    public class VLMProfile : GLib.Object {
        public string name = "";
        public string provider = PROVIDER_OPENAI;
        public string base_url = "";
        public string api_key = "";
        public string model = "";
        public string paddleocr_token = "";
        public string system_prompt_override = "";
        public double timeout = 120.0;
        public int max_concurrency = 3;
    }

    private static bool store_mm_api_key_to_keyring (string api_key) {
        return SecretStore.store_multimodal_api_key (api_key);
    }

    private static string? load_mm_api_key_from_keyring () {
        return SecretStore.load_multimodal_api_key ();
    }

    private static bool store_paddleocr_token_to_keyring (string token) {
        return SecretStore.store_paddleocr_token (token);
    }

    private static string? load_paddleocr_token_from_keyring () {
        return SecretStore.load_paddleocr_token ();
    }

    public static MultimodalAISettings load_multimodal_ai_settings () {
        var defaults = MultimodalAISettings () {
            enabled = false,
            profile_name = "",
            provider = PROVIDER_OPENAI,
            base_url = "https://api.openai.com/v1",
            api_key = "",
            model = "gpt-4o",
            paddleocr_token = "",
            system_prompt_override = "",
            timeout = 120.0,
            max_concurrency = 3
        };
        config_mutex.lock ();
        try {
            var root = load_settings_root_unlocked ();
            if (root == null) return defaults;
            var ai = root.has_member ("multimodal_ai") ? root.get_object_member ("multimodal_ai") : null;
            if (ai != null) {
                defaults.enabled = ai.get_boolean_member_with_default ("enabled", false);
                defaults.provider = ai.get_string_member_with_default ("provider", PROVIDER_OPENAI);
                defaults.base_url = ai.get_string_member_with_default ("base_url", defaults.base_url);
                defaults.model = ai.get_string_member_with_default ("model", defaults.model);
                defaults.system_prompt_override = ai.get_string_member_with_default ("system_prompt_override", "");
                defaults.timeout = ai.get_double_member_with_default ("timeout", defaults.timeout);
                defaults.max_concurrency = (int) ai.get_int_member_with_default ("max_concurrency", defaults.max_concurrency);

                // OpenAI 兼容路径的密钥: 优先密钥环, 其次从 JSON 明文迁移
                string? keyring_key = load_mm_api_key_from_keyring ();
                if (keyring_key != null && keyring_key.length > 0) {
                    defaults.api_key = keyring_key;
                } else {
                    string json_key = ai.get_string_member_with_default ("api_key", "");
                    if (json_key.length > 0) {
                        defaults.api_key = json_key;
                        if (store_mm_api_key_to_keyring (json_key)) {
                            ai.set_string_member ("api_key", "");
                            write_settings_root_unlocked (root);
                        } else {
                            // 迁移失败: 明文仍在 JSON 中, 提示用户重新填写一次.
                            notify_migration_failed (
                                "Multimodal API Key",
                                _("Failed to store key in system keyring. " +
                                  "The plaintext key remains in settings.json. " +
                                  "Re-saving the configuration will retry."));
                        }
                    }
                }

                // PaddleOCR 路径的 TOKEN: 同样优先密钥环, 其次从 JSON 明文迁移
                string? keyring_token = load_paddleocr_token_from_keyring ();
                if (keyring_token != null && keyring_token.length > 0) {
                    defaults.paddleocr_token = keyring_token;
                } else {
                    string json_token = ai.get_string_member_with_default ("paddleocr_token", "");
                    if (json_token.length > 0) {
                        defaults.paddleocr_token = json_token;
                        if (store_paddleocr_token_to_keyring (json_token)) {
                            ai.set_string_member ("paddleocr_token", "");
                            write_settings_root_unlocked (root);
                        } else {
                            notify_migration_failed (
                                "PaddleOCR Token",
                                _("Failed to store token in system keyring. " +
                                  "The plaintext token remains in settings.json. " +
                                  "Re-saving the configuration will retry."));
                        }
                    }
                }
            }

            // VLM 多模型配置方案: 存在 vlm_models 时, 以激活方案的值覆盖内联字段
            var profiles = load_vlm_profiles_unlocked (root);
            if (profiles.size > 0) {
                string active_name = ai != null
                    ? ai.get_string_member_with_default ("active_profile", "") : "";
                VLMProfile? found = null;
                foreach (var p in profiles) {
                    if (p.name == active_name) { found = p; break; }
                }
                if (found == null) found = profiles.get (0);
                defaults.profile_name = found.name;
                defaults.provider = found.provider;
                defaults.base_url = found.base_url;
                defaults.api_key = found.api_key;
                defaults.model = found.model;
                defaults.paddleocr_token = found.paddleocr_token;
                defaults.system_prompt_override = found.system_prompt_override;
                defaults.timeout = found.timeout > 0 ? found.timeout : 120.0;
                defaults.max_concurrency = found.max_concurrency > 0 ? found.max_concurrency : 3;
            }
        } catch (Error e) {
            warning ("Failed to load multimodal AI settings: %s", e.message);
        } finally {
            config_mutex.unlock ();
        }
        return defaults;
    }

    public static void save_multimodal_ai_settings (MultimodalAISettings s) {
        // PaddleOCR 服务端点写死为 https, 这里只对 OpenAI 路径校验.
        if (s.provider == PROVIDER_OPENAI) {
            try {
                validate_base_url (s.base_url);
            } catch (ConfigError e) {
                notify_insecure_url (s.base_url ?? "", e.message);
                return;
            }
        }
        config_mutex.lock ();
        try {
            Json.Object root = load_settings_root_unlocked () ?? new Json.Object ();
            var ai = new Json.Object ();
            ai.set_boolean_member ("enabled", s.enabled);
            ai.set_string_member ("active_profile", s.profile_name ?? "");
            ai.set_string_member ("provider", s.provider ?? PROVIDER_OPENAI);
            ai.set_string_member ("base_url", s.base_url ?? "");
            ai.set_string_member ("api_key", "");
            ai.set_string_member ("model", s.model ?? "");
            ai.set_string_member ("paddleocr_token", "");
            ai.set_string_member ("system_prompt_override", s.system_prompt_override ?? "");
            ai.set_double_member ("timeout", s.timeout > 0 ? s.timeout : 120.0);
            ai.set_int_member ("max_concurrency", s.max_concurrency > 0 ? s.max_concurrency : 3);
            root.set_member ("multimodal_ai", AI.SchemaHelper.obj_to_node (ai));
            write_settings_root_unlocked (root);

            // 双向同步: 把当前编辑值写回 vlm_models 中的激活方案 (不存在则创建)
            var profiles = load_vlm_profiles_unlocked (root);
            string pname = (s.profile_name != null && s.profile_name.length > 0)
                ? s.profile_name : DEFAULT_PROFILE_NAME;
            VLMProfile? target = null;
            foreach (var p in profiles) {
                if (p.name == pname) { target = p; break; }
            }
            if (target == null) {
                target = new VLMProfile ();
                target.name = pname;
                profiles.add (target);
            }
            target.provider = s.provider ?? PROVIDER_OPENAI;
            target.base_url = s.base_url ?? "";
            target.api_key = s.api_key ?? "";
            target.model = s.model ?? "";
            target.paddleocr_token = s.paddleocr_token ?? "";
            target.system_prompt_override = s.system_prompt_override ?? "";
            target.timeout = s.timeout > 0 ? s.timeout : 120.0;
            target.max_concurrency = s.max_concurrency > 0 ? s.max_concurrency : 3;
            save_vlm_profiles_unlocked (profiles);

            // 同步旧版单密钥槽, 保证配置文件被手动还原为无 vlm_models 时仍能回退
            store_mm_api_key_to_keyring (s.api_key ?? "");
            store_paddleocr_token_to_keyring (s.paddleocr_token ?? "");
        } catch (Error e) {
            warning ("Failed to save multimodal AI settings: %s", e.message);
        } finally {
            config_mutex.unlock ();
        }
    }

    // ─── AI 设置读写 ─────────────────────────────────────────────────────

    // 不加锁的内部读取
    private static Json.Object? load_settings_root_unlocked () throws Error {
        var file = get_settings_file ();
        if (!FileUtils.test (file, FileTest.EXISTS)) {
            return null;
        }
        string content;
        size_t len;
        FileUtils.get_contents (file, out content, out len);
        var parser = new Json.Parser ();
        parser.load_from_data (content);
        if (parser.get_root () == null || parser.get_root ().get_node_type () != Json.NodeType.OBJECT) {
            return null;
        }
        return parser.get_root ().get_object ();
    }

    // 不加锁的内部写入
    private static void write_settings_root_unlocked (Json.Object root) throws Error {
        var gen = new Json.Generator ();
        gen.set_root (AI.SchemaHelper.obj_to_node (root));
        gen.pretty = true;
        atomic_write_json (gen, get_settings_file ());
    }

    // ─── 多模型配置方案 (ai_models) 读写 ─────────────────────────────────

    public const string DEFAULT_PROFILE_NAME = "default";

    // 不加锁的内部读取。root 可为 null (调用方已解析时直接传入, 避免重复读盘)。
    private static Gee.ArrayList<AIProfile> load_ai_profiles_unlocked (Json.Object? root) throws Error {
        var list = new Gee.ArrayList<AIProfile> ();
        if (root == null) return list;
        var arr = root.has_member ("ai_models") ? root.get_array_member ("ai_models") : null;
        if (arr == null) return list;
        for (int i = 0; i < arr.get_length (); i++) {
            var obj = arr.get_object_element (i);
            if (obj == null) continue;
            string name = obj.get_string_member_with_default ("name", "");
            if (name.length == 0) continue;  // 无名方案无法寻址, 跳过
            var p = new AIProfile ();
            p.name = name;
            p.base_url = obj.get_string_member_with_default ("base_url", DEFAULT_AI_BASE_URL);
            p.model = obj.get_string_member_with_default ("model", DEFAULT_AI_MODEL);
            p.system_prompt_override = obj.get_string_member_with_default ("system_prompt_override", "");
            p.timeout = obj.get_double_member_with_default ("timeout", DEFAULT_AI_TIMEOUT);

            // 密钥: 优先密钥环, 其次 JSON 明文迁移 (迁移后清空明文)
            string? keyring_key = SecretStore.load_profile_api_key (name);
            if (keyring_key != null && keyring_key.length > 0) {
                p.api_key = keyring_key;
            } else {
                string json_key = obj.get_string_member_with_default ("api_key", "");
                if (json_key.length > 0) {
                    p.api_key = json_key;
                    if (SecretStore.store_profile_api_key (name, json_key)) {
                        obj.set_string_member ("api_key", "");
                        write_settings_root_unlocked (root);
                    } else {
                        notify_migration_failed (
                            @"Sidebar API Key (profile: $name)",
                            _("Failed to store key in system keyring. " +
                              "The plaintext key remains in settings.json. " +
                              "Re-saving the configuration will retry."));
                    }
                }
            }
            list.add (p);
        }
        return list;
    }

    public static Gee.ArrayList<AIProfile> load_ai_profiles () {
        config_mutex.lock ();
        try {
            return load_ai_profiles_unlocked (load_settings_root_unlocked ());
        } catch (Error e) {
            warning ("Failed to load AI profiles: %s", e.message);
            return new Gee.ArrayList<AIProfile> ();
        } finally {
            config_mutex.unlock ();
        }
    }

    // 不加锁的内部写入。API Key 不落 JSON, 按 profile 名存入密钥环。
    private static void save_ai_profiles_unlocked (Gee.ArrayList<AIProfile> profiles) throws Error {
        Json.Object root = load_settings_root_unlocked () ?? new Json.Object ();
        var arr = new Json.Array ();
        foreach (var p in profiles) {
            var obj = new Json.Object ();
            obj.set_string_member ("name", p.name ?? "");
            obj.set_string_member ("base_url", p.base_url ?? "");
            obj.set_string_member ("api_key", "");
            obj.set_string_member ("model", p.model ?? "");
            obj.set_string_member ("system_prompt_override", p.system_prompt_override ?? "");
            obj.set_double_member ("timeout", p.timeout > 0 ? p.timeout : DEFAULT_AI_TIMEOUT);
            arr.add_object_element (obj);
            SecretStore.store_profile_api_key (p.name ?? "", p.api_key ?? "");
        }
        root.set_member ("ai_models", AI.SchemaHelper.arr_to_node (arr));
        write_settings_root_unlocked (root);
    }

    public static void save_ai_profiles (Gee.ArrayList<AIProfile> profiles) {
        // 拒绝任何不安全端点 (https:// 必需, localhost 例外).
        foreach (var p in profiles) {
            try {
                validate_base_url (p.base_url);
            } catch (ConfigError e) {
                notify_insecure_url (p.base_url ?? "", e.message);
                return;
            }
        }
        config_mutex.lock ();
        try {
            save_ai_profiles_unlocked (profiles);
        } catch (Error e) {
            warning ("Failed to save AI profiles: %s", e.message);
        } finally {
            config_mutex.unlock ();
        }
    }

    // 删除指定 profile 在密钥环中的 API Key (供 GUI 删除方案时调用)
    public static void delete_ai_profile_key (string profile_name) {
        SecretStore.store_profile_api_key (profile_name, "");
    }

    // ─── VLM 多模型配置方案 (vlm_models) 读写 ────────────────────────────

    // 不加锁的内部读取。root 可为 null。
    private static Gee.ArrayList<VLMProfile> load_vlm_profiles_unlocked (Json.Object? root) throws Error {
        var list = new Gee.ArrayList<VLMProfile> ();
        if (root == null) return list;
        var arr = root.has_member ("vlm_models") ? root.get_array_member ("vlm_models") : null;
        if (arr == null) return list;
        for (int i = 0; i < arr.get_length (); i++) {
            var obj = arr.get_object_element (i);
            if (obj == null) continue;
            string name = obj.get_string_member_with_default ("name", "");
            if (name.length == 0) continue;  // 无名方案无法寻址, 跳过
            var p = new VLMProfile ();
            p.name = name;
            p.provider = obj.get_string_member_with_default ("provider", PROVIDER_OPENAI);
            p.base_url = obj.get_string_member_with_default ("base_url", "https://api.openai.com/v1");
            p.model = obj.get_string_member_with_default ("model", "gpt-4o");
            p.system_prompt_override = obj.get_string_member_with_default ("system_prompt_override", "");
            p.timeout = obj.get_double_member_with_default ("timeout", 120.0);
            p.max_concurrency = (int) obj.get_int_member_with_default ("max_concurrency", 3);

            // OpenAI 兼容路径的密钥: 优先密钥环, 其次 JSON 明文迁移
            string? keyring_key = SecretStore.load_profile_mm_api_key (name);
            if (keyring_key != null && keyring_key.length > 0) {
                p.api_key = keyring_key;
            } else {
                string json_key = obj.get_string_member_with_default ("api_key", "");
                if (json_key.length > 0) {
                    p.api_key = json_key;
                    if (SecretStore.store_profile_mm_api_key (name, json_key)) {
                        obj.set_string_member ("api_key", "");
                        write_settings_root_unlocked (root);
                    } else {
                        notify_migration_failed (
                            @"Multimodal API Key (profile: $name)",
                            _("Failed to store key in system keyring. " +
                              "The plaintext key remains in settings.json. " +
                              "Re-saving the configuration will retry."));
                    }
                }
            }

            // PaddleOCR 路径的 TOKEN: 同样优先密钥环, 其次 JSON 明文迁移
            string? keyring_token = SecretStore.load_profile_paddleocr_token (name);
            if (keyring_token != null && keyring_token.length > 0) {
                p.paddleocr_token = keyring_token;
            } else {
                string json_token = obj.get_string_member_with_default ("paddleocr_token", "");
                if (json_token.length > 0) {
                    p.paddleocr_token = json_token;
                    if (SecretStore.store_profile_paddleocr_token (name, json_token)) {
                        obj.set_string_member ("paddleocr_token", "");
                        write_settings_root_unlocked (root);
                    } else {
                        notify_migration_failed (
                            @"PaddleOCR Token (profile: $name)",
                            _("Failed to store token in system keyring. " +
                              "The plaintext token remains in settings.json. " +
                              "Re-saving the configuration will retry."));
                    }
                }
            }
            list.add (p);
        }
        return list;
    }

    public static Gee.ArrayList<VLMProfile> load_vlm_profiles () {
        config_mutex.lock ();
        try {
            return load_vlm_profiles_unlocked (load_settings_root_unlocked ());
        } catch (Error e) {
            warning ("Failed to load VLM profiles: %s", e.message);
            return new Gee.ArrayList<VLMProfile> ();
        } finally {
            config_mutex.unlock ();
        }
    }

    // 不加锁的内部写入。密钥不落 JSON, 按方案名存入密钥环。
    private static void save_vlm_profiles_unlocked (Gee.ArrayList<VLMProfile> profiles) throws Error {
        Json.Object root = load_settings_root_unlocked () ?? new Json.Object ();
        var arr = new Json.Array ();
        foreach (var p in profiles) {
            var obj = new Json.Object ();
            obj.set_string_member ("name", p.name ?? "");
            obj.set_string_member ("provider", p.provider ?? PROVIDER_OPENAI);
            obj.set_string_member ("base_url", p.base_url ?? "");
            obj.set_string_member ("api_key", "");
            obj.set_string_member ("model", p.model ?? "");
            obj.set_string_member ("paddleocr_token", "");
            obj.set_string_member ("system_prompt_override", p.system_prompt_override ?? "");
            obj.set_double_member ("timeout", p.timeout > 0 ? p.timeout : 120.0);
            obj.set_int_member ("max_concurrency", p.max_concurrency > 0 ? p.max_concurrency : 3);
            arr.add_object_element (obj);
            SecretStore.store_profile_mm_api_key (p.name ?? "", p.api_key ?? "");
            SecretStore.store_profile_paddleocr_token (p.name ?? "", p.paddleocr_token ?? "");
        }
        root.set_member ("vlm_models", AI.SchemaHelper.arr_to_node (arr));
        write_settings_root_unlocked (root);
    }

    public static void save_vlm_profiles (Gee.ArrayList<VLMProfile> profiles) {
        // 拒绝任何 OpenAI 路径下的不安全端点. PaddleOCR 端点写死为 https.
        foreach (var p in profiles) {
            if (p.provider == PROVIDER_OPENAI) {
                try {
                    validate_base_url (p.base_url);
                } catch (ConfigError e) {
                    notify_insecure_url (p.base_url ?? "", e.message);
                    return;
                }
            }
        }
        config_mutex.lock ();
        try {
            save_vlm_profiles_unlocked (profiles);
        } catch (Error e) {
            warning ("Failed to save VLM profiles: %s", e.message);
        } finally {
            config_mutex.unlock ();
        }
    }

    // 删除指定 VLM 方案在密钥环中的 API Key 与 PaddleOCR Token
    public static void delete_vlm_profile_keys (string profile_name) {
        SecretStore.store_profile_mm_api_key (profile_name, "");
        SecretStore.store_profile_paddleocr_token (profile_name, "");
    }

    public static AISettings load_ai_settings () {
        var defaults = AISettings () {
            enabled = false,
            profile_name = "",
            base_url = DEFAULT_AI_BASE_URL,
            api_key = "",
            model = DEFAULT_AI_MODEL,
            system_prompt_override = "",
            timeout = DEFAULT_AI_TIMEOUT
        };
        config_mutex.lock ();
        try {
            var root = load_settings_root_unlocked ();
            if (root == null) return defaults;
            var ai = root.has_member ("ai") ? root.get_object_member ("ai") : null;
            if (ai != null) {
                defaults.enabled = ai.get_boolean_member_with_default ("enabled", false);
                defaults.base_url = ai.get_string_member_with_default ("base_url", DEFAULT_AI_BASE_URL);
                defaults.model = ai.get_string_member_with_default ("model", DEFAULT_AI_MODEL);
                defaults.system_prompt_override = ai.get_string_member_with_default (
                    "system_prompt_override", "");
                defaults.timeout = ai.get_double_member_with_default ("timeout", DEFAULT_AI_TIMEOUT);

                // API Key: 优先从系统密钥环读取
                string? keyring_key = load_api_key_from_keyring ();
                if (keyring_key != null && keyring_key.length > 0) {
                    defaults.api_key = keyring_key;
                } else {
                    // 迁移: 如果密钥环中没有, 但 JSON 中有明文密钥, 迁移到密钥环并清除明文
                    string json_key = ai.get_string_member_with_default ("api_key", "");
                    if (json_key.length > 0) {
                        defaults.api_key = json_key;
                        if (store_api_key_to_keyring (json_key)) {
                            // 迁移成功, 清除 JSON 中的明文密钥
                            ai.set_string_member ("api_key", "");
                            write_settings_root_unlocked (root);
                        } else {
                            // 迁移失败: 明文仍在 JSON 中. 提示用户重新填写.
                            notify_migration_failed (
                                "Sidebar API Key",
                                _("Failed to store key in system keyring. " +
                                  "The plaintext key remains in settings.json. " +
                                  "Re-saving the configuration will retry."));
                        }
                    }
                }
            }

            // 多模型配置方案: 存在 ai_models 时, 以激活方案的值覆盖内联字段
            // (旧的 ai 内联字段仅作为无 ai_models 时的向后兼容回退)
            var profiles = load_ai_profiles_unlocked (root);
            if (profiles.size > 0) {
                string active_name = ai != null
                    ? ai.get_string_member_with_default ("active_profile", "") : "";
                AIProfile? found = null;
                foreach (var p in profiles) {
                    if (p.name == active_name) { found = p; break; }
                }
                if (found == null) found = profiles.get (0);
                defaults.profile_name = found.name;
                defaults.base_url = found.base_url;
                defaults.api_key = found.api_key;
                defaults.model = found.model;
                defaults.system_prompt_override = found.system_prompt_override;
                defaults.timeout = found.timeout > 0 ? found.timeout : DEFAULT_AI_TIMEOUT;
            }
        } catch (Error e) {
            warning ("Failed to load AI settings: %s", e.message);
        } finally {
            config_mutex.unlock ();
        }
        return defaults;
    }

    public static void save_ai_settings (AISettings s) {
        // 拒绝不安全端点: 仅允许 https:// 或 http://localhost/127.0.0.1
        try {
            validate_base_url (s.base_url);
        } catch (ConfigError e) {
            notify_insecure_url (s.base_url ?? "", e.message);
            return;
        }
        config_mutex.lock ();
        try {
            Json.Object root = load_settings_root_unlocked () ?? new Json.Object ();
            var ai = new Json.Object ();
            ai.set_boolean_member ("enabled", s.enabled);
            ai.set_string_member ("active_profile", s.profile_name ?? "");
            ai.set_string_member ("base_url", s.base_url ?? "");
            // API Key 不再写入 JSON, 改用系统密钥环存储
            ai.set_string_member ("api_key", "");
            ai.set_string_member ("model", s.model ?? "");
            ai.set_string_member ("system_prompt_override", s.system_prompt_override ?? "");
            ai.set_double_member ("timeout", s.timeout > 0 ? s.timeout : DEFAULT_AI_TIMEOUT);
            root.set_member ("ai", AI.SchemaHelper.obj_to_node (ai));
            write_settings_root_unlocked (root);

            // 双向同步: 把当前编辑值写回 ai_models 中的激活方案 (不存在则创建),
            // 保证 GUI 中配置的模型同步进配置文件。
            var profiles = load_ai_profiles_unlocked (root);
            string pname = (s.profile_name != null && s.profile_name.length > 0)
                ? s.profile_name : DEFAULT_PROFILE_NAME;
            AIProfile? target = null;
            foreach (var p in profiles) {
                if (p.name == pname) { target = p; break; }
            }
            if (target == null) {
                target = new AIProfile ();
                target.name = pname;
                profiles.add (target);
            }
            target.base_url = s.base_url ?? "";
            target.api_key = s.api_key ?? "";
            target.model = s.model ?? "";
            target.system_prompt_override = s.system_prompt_override ?? "";
            target.timeout = s.timeout > 0 ? s.timeout : DEFAULT_AI_TIMEOUT;
            save_ai_profiles_unlocked (profiles);

            // 将 API Key 存入系统密钥环 (libsecret)。同时更新旧版单密钥槽,
            // 保证配置文件被手动还原为无 ai_models 时仍能回退读取。
            store_api_key_to_keyring (s.api_key ?? "");
        } catch (Error e) {
            warning ("Failed to save AI settings: %s", e.message);
        } finally {
            config_mutex.unlock ();
        }
    }

    // ─── 色彩主题 ─────────────────────────────────────────────────────

    public static string load_color_scheme () {
        config_mutex.lock ();
        try {
            var root = load_settings_root_unlocked ();
            if (root != null && root.has_member ("color_scheme")) {
                return root.get_string_member ("color_scheme");
            }
        } catch (Error e) {} finally {
            config_mutex.unlock ();
        }
        return "default";
    }

    public static void save_color_scheme (string scheme) {
        config_mutex.lock ();
        try {
            Json.Object root = load_settings_root_unlocked () ?? new Json.Object ();
            root.set_string_member ("color_scheme", scheme);
            write_settings_root_unlocked (root);
        } catch (Error e) {} finally {
            config_mutex.unlock ();
        }
    }

    // ─── 上下文窗口大小 ─────────────────────────────────────────────────

    public static int get_context_window_size () {
        config_mutex.lock ();
        try {
            var root = load_settings_root_unlocked ();
            if (root != null && root.has_member ("context_window_size")) {
                return (int) root.get_int_member ("context_window_size");
            }
        } catch (Error e) {} finally {
            config_mutex.unlock ();
        }
        return 128000;
    }

    public static void save_context_window_size (int size) {
        config_mutex.lock ();
        try {
            Json.Object root = load_settings_root_unlocked () ?? new Json.Object ();
            root.set_int_member ("context_window_size", size);
            write_settings_root_unlocked (root);
        } catch (Error e) {} finally {
            config_mutex.unlock ();
        }
    }

    // ─── 场景化编排模板 ─────────────────────────────────────────────────

    private static string get_templates_file () {
        return GLib.Path.build_filename (get_config_dir (), "templates.json");
    }

    public static Gee.ArrayList<PromptTemplate> get_default_templates () {
        var list = new Gee.ArrayList<PromptTemplate> ();
        list.add (new PromptTemplate (
            "bug", "Bug 分析", "排查逻辑错误与异常",
            "# 问题描述\n[请在此补充具体的 Bug 现象、复现步骤及报错日志]",
            "# 期望输出\n[请提供修复方案或代码补丁]",
            "请分析当前编排列表中的代码，重点排查与 Bug 相关的逻辑错误、异常处理及日志输出。如果需要，请使用 list_files 和 add_files 工具补充相关的日志文件或配置文件。"
        ));
        list.add (new PromptTemplate (
            "api", "API 文档生成", "梳理 RESTful 接口",
            "# API 接口文档\n",
            "\n# 附录与数据字典",
            "请根据当前列表中的 Controller/Router 文件，梳理并生成结构化的 RESTful API 文档。如果缺少相关路由文件，请自行探索并添加。"
        ));
        list.add (new PromptTemplate (
            "refactor", "代码重构", "优化代码结构",
            "# 重构目标\n[请说明重构的目的，如降低耦合、提升性能]",
            "# 验收标准",
            "请审查以下代码，寻找重复逻辑、过长函数及不符合 SOLID 原则的设计，并提供重构建议。"
        ));
        return list;
    }

    public static Gee.ArrayList<PromptTemplate> load_templates () {
        config_mutex.lock ();
        try {
            var file = get_templates_file ();
            if (!FileUtils.test (file, FileTest.EXISTS)) {
                return get_default_templates ();
            }
            string content;
            size_t len;
            FileUtils.get_contents (file, out content, out len);
            var parser = new Json.Parser ();
            parser.load_from_data (content);
            var root_node = parser.get_root ();
            if (root_node == null || root_node.get_node_type () != Json.NodeType.ARRAY) {
                return get_default_templates ();
            }
            var root = root_node.get_array ();
            var list = new Gee.ArrayList<PromptTemplate> ();
            for (int i = 0; i < root.get_length (); i++) {
                var obj = root.get_object_element (i);
                if (obj == null) continue;
                list.add (new PromptTemplate (
                    obj.get_string_member_with_default ("id", ""),
                    obj.get_string_member_with_default ("name", ""),
                    obj.get_string_member_with_default ("description", ""),
                    obj.get_string_member_with_default ("header_text", ""),
                    obj.get_string_member_with_default ("footer_text", ""),
                    obj.get_string_member_with_default ("ai_prompt", "")
                ));
            }
            return list;
        } catch (Error e) {
            warning ("Failed to load templates: %s", e.message);
            return get_default_templates ();
        } finally {
            config_mutex.unlock ();
        }
    }

    public static void save_templates (Gee.ArrayList<PromptTemplate> templates) {
        config_mutex.lock ();
        try {
            var builder = new Json.Builder ();
            builder.begin_array ();
            foreach (var tpl in templates) {
                builder.begin_object ();
                builder.set_member_name ("id"); builder.add_string_value (tpl.id);
                builder.set_member_name ("name"); builder.add_string_value (tpl.name);
                builder.set_member_name ("description"); builder.add_string_value (tpl.description);
                builder.set_member_name ("header_text"); builder.add_string_value (tpl.header_text);
                builder.set_member_name ("footer_text"); builder.add_string_value (tpl.footer_text);
                builder.set_member_name ("ai_prompt"); builder.add_string_value (tpl.ai_prompt);
                builder.end_object ();
            }
            builder.end_array ();
            var generator = new Json.Generator ();
            generator.set_root (builder.get_root ());
            generator.pretty = true;
            atomic_write_json (generator, get_templates_file ());
        } catch (Error e) {
            warning ("Failed to save templates: %s", e.message);
        } finally {
            config_mutex.unlock ();
        }
    }

    /**
     * 原子写入 JSON 文件：先写临时文件再 rename 替换目标。
     * 写入中途崩溃（断电/被杀）只会留下临时文件，原文件保持完整，
     * 下次加载不会损坏。
     */
    public static void atomic_write_json (Json.Generator generator, string target_path) throws Error {
        var target = File.new_for_path (target_path);
        var dir = target.get_parent ();
        // 临时文件与目标同目录，确保 rename 是同一文件系统上的原子操作。
        var tmp = File.new_for_path (
            Path.build_filename (dir != null ? dir.get_path () : ".", "." + target.get_basename () + ".tmp")
        );

        var stream = tmp.replace (null, false, FileCreateFlags.NONE);
        generator.to_stream (stream, null);
        stream.close ();

        tmp.move (target, FileCopyFlags.OVERWRITE);
    }
}
