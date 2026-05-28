public class ConfigManager : GLib.Object {
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
            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("language");
            builder.add_string_value (lang);
            builder.end_object ();

            var generator = new Json.Generator ();
            generator.set_root (builder.get_root ());
            generator.pretty = true;

            var file = get_settings_file ();
            generator.to_file (file);
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
}
