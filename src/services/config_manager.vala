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

    // VLM 服务商枚举. "openai" 为现有 OpenAI 兼容路径; "paddleocr" 为百度
    // 智能云 PaddleOCR 云端 API 预设 (仅需填写一个 TOKEN).
    public const string PROVIDER_OPENAI = "openai";
    public const string PROVIDER_PADDLEOCR = "paddleocr";

    public struct AISettings {
        public bool enabled;
        public string base_url;
        public string api_key;
        public string model;
        public string system_prompt_override;
        public double timeout;
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
            if (ai == null) return defaults;
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
            var ai = root.has_member ("ai") ? root.get_object_member ("ai") : null;
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
