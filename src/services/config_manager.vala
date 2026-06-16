public class ConfigManager : GLib.Object {
    public const string DEFAULT_AI_BASE_URL = "https://api.openai.com/v1";
    public const string DEFAULT_AI_MODEL = "gpt-4o-mini";
    public const double DEFAULT_AI_TIMEOUT = 60.0;

    public struct AISettings {
        public bool enabled;
        public string base_url;
        public string api_key;
        public string model;
        public string system_prompt_override;
        public double timeout;
    }

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

    public static string load_settings_language () {
        var file = get_settings_file ();
        if (!FileUtils.test (file, FileTest.EXISTS)) {
            return "";
        }
        try {
            string content;
            size_t len;
            FileUtils.get_contents (file, out content, out len);
            var parser = new Json.Parser ();
            parser.load_from_data (content);
            var root = parser.get_root ().get_object ();
            return root.get_string_member_with_default ("language", "");
        } catch (Error e) {
            warning ("Failed to load settings: %s", e.message);
            return "";
        }
    }

    public static void save_language_setting (string lang) {
        try {
            // 先读取现有配置, 保留其他字段 (如 ai 设置), 只更新 language
            Json.Object root;
            var existing = load_settings_root ();
            if (existing == null) {
                root = new Json.Object ();
            } else {
                root = existing;
            }
            root.set_string_member ("language", lang);
            write_settings_root (root);
        } catch (Error e) {
            warning ("Failed to save language setting: %s", e.message);
        }
    }

    public static void load_common_phrases (GenericArray<string> common_phrases) {
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

    public static void save_common_phrases (GenericArray<string> common_phrases) {
        try {
            var builder = new Json.Builder ();
            builder.begin_array ();
            for (int i = 0; i < common_phrases.length; i++) {
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

    // ─── AI 设置读写 ─────────────────────────────────────────────────────

    private static Json.Object? load_settings_root () throws Error {
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

    private static void write_settings_root (Json.Object root) throws Error {
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
        try {
            var root = load_settings_root ();
            if (root == null) return defaults;
            var ai = root.get_object_member ("ai");
            if (ai == null) return defaults;
            defaults.enabled = ai.get_boolean_member_with_default ("enabled", false);
            defaults.base_url = ai.get_string_member_with_default ("base_url", DEFAULT_AI_BASE_URL);
            defaults.api_key = ai.get_string_member_with_default ("api_key", "");
            defaults.model = ai.get_string_member_with_default ("model", DEFAULT_AI_MODEL);
            defaults.system_prompt_override = ai.get_string_member_with_default (
                "system_prompt_override", "");
            defaults.timeout = ai.get_double_member_with_default ("timeout", DEFAULT_AI_TIMEOUT);
        } catch (Error e) {
            warning ("Failed to load AI settings: %s", e.message);
        }
        return defaults;
    }

    public static void save_ai_settings (AISettings s) {
        try {
            Json.Object root;
            var existing = load_settings_root ();
            if (existing == null) {
                root = new Json.Object ();
            } else {
                root = existing;
            }
            var ai = new Json.Object ();
            ai.set_boolean_member ("enabled", s.enabled);
            ai.set_string_member ("base_url", s.base_url ?? "");
            ai.set_string_member ("api_key", s.api_key ?? "");
            ai.set_string_member ("model", s.model ?? "");
            ai.set_string_member ("system_prompt_override", s.system_prompt_override ?? "");
            ai.set_double_member ("timeout", s.timeout > 0 ? s.timeout : DEFAULT_AI_TIMEOUT);
            root.set_member ("ai", AI.SchemaHelper.obj_to_node (ai));
            write_settings_root (root);
        } catch (Error e) {
            warning ("Failed to save AI settings: %s", e.message);
        }
    }
}
