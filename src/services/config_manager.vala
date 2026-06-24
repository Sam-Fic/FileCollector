using Gee;

public class ConfigManager : GLib.Object {
    public const string DEFAULT_AI_BASE_URL = "https://api.openai.com/v1";
    public const string DEFAULT_AI_MODEL = "gpt-4o-mini";
    public const double DEFAULT_AI_TIMEOUT = 60.0;

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

    public struct AISettings {
        public bool enabled;
        public string base_url;
        public string api_key;
        public string model;
        public string system_prompt_override;
        public double timeout;
    }

    // ─── libsecret Schema (延迟初始化) ──────────────────────────────────

    private static Secret.Schema? api_key_schema = null;

    private static Secret.Schema get_api_key_schema () {
        if (api_key_schema == null) {
            api_key_schema = new Secret.Schema ("com.github.samfic.filecollector.api_key",
                Secret.SchemaFlags.NONE,
                "type", Secret.SchemaAttributeType.STRING);
        }
        return api_key_schema;
    }

    // ─── 密钥存储 (libsecret) ──────────────────────────────────────────

    // 将 API Key 存入系统密钥环; key 为空时清除密钥环中的条目
    private static bool store_api_key_to_keyring (string api_key) {
        if (api_key.length > 0) {
            try {
                return Secret.password_store_sync (
                    get_api_key_schema (),
                    Secret.COLLECTION_DEFAULT,
                    "FileCollector AI API Key",
                    api_key,
                    null,
                    "type", "api_key", null);
            } catch (Error e) {
                warning ("Failed to store API key in keyring: %s", e.message);
                return false;
            }
        } else {
            try {
                Secret.password_clear_sync (get_api_key_schema (), null,
                    "type", "api_key", null);
            } catch (Error e) {
                warning ("Failed to clear API key from keyring: %s", e.message);
            }
            return true;
        }
    }

    // 从系统密钥环读取 API Key; 失败或不存在时返回 null
    private static string? load_api_key_from_keyring () {
        try {
            return Secret.password_lookup_sync (get_api_key_schema (), null,
                "type", "api_key", null);
        } catch (Error e) {
            warning ("Failed to lookup API key from keyring: %s", e.message);
            return null;
        }
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
            generator.to_file (file);
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
        public string base_url;
        public string api_key;
        public string model;
        public string system_prompt_override;
        public double timeout;
    }

    private static Secret.Schema? mm_api_key_schema = null;

    private static Secret.Schema get_mm_api_key_schema () {
        if (mm_api_key_schema == null) {
            mm_api_key_schema = new Secret.Schema ("com.github.samfic.filecollector.mm_api_key",
                Secret.SchemaFlags.NONE,
                "type", Secret.SchemaAttributeType.STRING);
        }
        return mm_api_key_schema;
    }

    private static bool store_mm_api_key_to_keyring (string api_key) {
        if (api_key.length > 0) {
            try {
                return Secret.password_store_sync (
                    get_mm_api_key_schema (),
                    Secret.COLLECTION_DEFAULT,
                    "FileCollector Multimodal AI API Key",
                    api_key,
                    null,
                    "type", "mm_api_key", null);
            } catch (Error e) {
                warning ("Failed to store mm API key in keyring: %s", e.message);
                return false;
            }
        } else {
            try {
                Secret.password_clear_sync (get_mm_api_key_schema (), null,
                    "type", "mm_api_key", null);
            } catch (Error e) {
                warning ("Failed to clear mm API key from keyring: %s", e.message);
            }
            return true;
        }
    }

    private static string? load_mm_api_key_from_keyring () {
        try {
            return Secret.password_lookup_sync (get_mm_api_key_schema (), null,
                "type", "mm_api_key", null);
        } catch (Error e) {
            warning ("Failed to lookup mm API key from keyring: %s", e.message);
            return null;
        }
    }

    public static MultimodalAISettings load_multimodal_ai_settings () {
        var defaults = MultimodalAISettings () {
            enabled = false,
            base_url = "https://api.openai.com/v1",
            api_key = "",
            model = "gpt-4o",
            system_prompt_override = "",
            timeout = 120.0
        };
        config_mutex.lock ();
        try {
            var root = load_settings_root_unlocked ();
            if (root == null) return defaults;
            var ai = root.get_object_member ("multimodal_ai");
            if (ai == null) return defaults;
            defaults.enabled = ai.get_boolean_member_with_default ("enabled", false);
            defaults.base_url = ai.get_string_member_with_default ("base_url", defaults.base_url);
            defaults.model = ai.get_string_member_with_default ("model", defaults.model);
            defaults.system_prompt_override = ai.get_string_member_with_default ("system_prompt_override", "");
            defaults.timeout = ai.get_double_member_with_default ("timeout", defaults.timeout);

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
                    }
                }
            }
        } catch (Error e) {
            warning ("Failed to load multimodal AI settings: %s", e.message);
        } finally {
            config_mutex.unlock ();
        }
        return defaults;
    }

    public static void save_multimodal_ai_settings (MultimodalAISettings s) {
        config_mutex.lock ();
        try {
            Json.Object root = load_settings_root_unlocked () ?? new Json.Object ();
            var ai = new Json.Object ();
            ai.set_boolean_member ("enabled", s.enabled);
            ai.set_string_member ("base_url", s.base_url ?? "");
            ai.set_string_member ("api_key", "");
            ai.set_string_member ("model", s.model ?? "");
            ai.set_string_member ("system_prompt_override", s.system_prompt_override ?? "");
            ai.set_double_member ("timeout", s.timeout > 0 ? s.timeout : 120.0);
            root.set_member ("multimodal_ai", AI.SchemaHelper.obj_to_node (ai));
            write_settings_root_unlocked (root);
            store_mm_api_key_to_keyring (s.api_key ?? "");
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
        gen.to_file (get_settings_file ());
    }

    public static AISettings load_ai_settings () {
        var defaults = AISettings () {
            enabled = false,
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
            var ai = root.get_object_member ("ai");
            if (ai == null) return defaults;
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
                    }
                }
            }
        } catch (Error e) {
            warning ("Failed to load AI settings: %s", e.message);
        } finally {
            config_mutex.unlock ();
        }
        return defaults;
    }

    public static void save_ai_settings (AISettings s) {
        config_mutex.lock ();
        try {
            Json.Object root = load_settings_root_unlocked () ?? new Json.Object ();
            var ai = new Json.Object ();
            ai.set_boolean_member ("enabled", s.enabled);
            ai.set_string_member ("base_url", s.base_url ?? "");
            // API Key 不再写入 JSON, 改用系统密钥环存储
            ai.set_string_member ("api_key", "");
            ai.set_string_member ("model", s.model ?? "");
            ai.set_string_member ("system_prompt_override", s.system_prompt_override ?? "");
            ai.set_double_member ("timeout", s.timeout > 0 ? s.timeout : DEFAULT_AI_TIMEOUT);
            root.set_member ("ai", AI.SchemaHelper.obj_to_node (ai));
            write_settings_root_unlocked (root);

            // 将 API Key 存入系统密钥环 (libsecret)
            store_api_key_to_keyring (s.api_key ?? "");
        } catch (Error e) {
            warning ("Failed to save AI settings: %s", e.message);
        } finally {
            config_mutex.unlock ();
        }
    }
}
