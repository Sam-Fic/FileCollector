using Gee;

public class ProjectManager : GLib.Object {
    public static void load_project_file (
        string file_path,
        Gee.ArrayList<ItemData> items,
        Gee.HashSet<string> checked_paths,
        Gee.HashSet<string> checked_dirs,
        Gee.ArrayList<string> common_phrases,
        out File? work_dir,
        out string? project_file,
        out bool use_absolute,
        out bool show_header
    ) throws Error {
        work_dir = null;
        project_file = null;
        use_absolute = false;
        show_header = false;

        string content;
        size_t len;
        FileUtils.get_contents (file_path, out content, out len);
        var parser = new Json.Parser ();
        parser.load_from_data (content);

        var root = parser.get_root ().get_object ();

        var wd_str = root.get_string_member_with_default ("work_dir", "");
        if (wd_str != "") {
            var wd = File.new_for_path (wd_str);
            if (wd.query_exists ()) {
                work_dir = wd;
            }
        }

        checked_paths.clear ();
        checked_dirs.clear ();
        items.clear ();

        use_absolute = root.get_boolean_member_with_default ("use_absolute", false);
        show_header = root.get_boolean_member_with_default ("show_header", false);

        var checked_arr = root.has_member ("checked_files") ? root.get_array_member ("checked_files") : null;
        if (checked_arr != null) {
            for (int i = 0; i < checked_arr.get_length (); i++) {
                var p = checked_arr.get_string_element (i);
                if (File.new_for_path (p).query_exists ()) {
                    checked_paths.add (p);
                }
            }
        }

        var checked_dirs_arr = root.has_member ("checked_dirs") ? root.get_array_member ("checked_dirs") : null;
        if (checked_dirs_arr != null) {
            for (int i = 0; i < checked_dirs_arr.get_length (); i++) {
                checked_dirs.add (checked_dirs_arr.get_string_element (i));
            }
        }

        var items_arr = root.has_member ("items") ? root.get_array_member ("items") : null;
        if (items_arr != null) {
            for (int i = 0; i < items_arr.get_length (); i++) {
                var obj = items_arr.get_object_element (i);
                if (obj == null) continue;
                var type = obj.get_string_member ("type");
                if (type == "file") {
                    var p = obj.get_string_member ("path");
                    var fa = obj.get_boolean_member_with_default ("force_absolute", false);
                    var sl = (int) obj.get_int_member_with_default ("start_line", 0);
                    var el = (int) obj.get_int_member_with_default ("end_line", 0);
                    if (File.new_for_path (p).query_exists ()) {
                        var item = new ItemData ("file", p, null, fa);
                        item.start_line = sl;
                        item.end_line = el;
                        items.add (item);
                    } else {
                        var item = new ItemData ("file", p, null, fa, true);
                        item.start_line = sl;
                        item.end_line = el;
                        items.add (item);
                    }
                } else {
                    var c = obj.get_string_member_with_default ("content", "");
                    items.add (new ItemData ("text", null, c, false));
                }
            }
        }

        common_phrases.clear ();
        var phrases_arr = root.has_member ("common_phrases") ? root.get_array_member ("common_phrases") : null;
        if (phrases_arr != null) {
            for (int i = 0; i < phrases_arr.get_length (); i++) {
                common_phrases.add (phrases_arr.get_string_element (i));
            }
        }

        project_file = file_path;
    }

    public static void write_project_file (
        string file_path,
        File? work_dir,
        bool use_absolute,
        bool show_header,
        Gee.ArrayList<ItemData> items,
        Gee.HashSet<string> checked_paths,
        Gee.HashSet<string> checked_dirs,
        Gee.ArrayList<string> common_phrases
    ) throws Error {
        var builder = new Json.Builder ();
        builder.begin_object ();

        builder.set_member_name ("work_dir");
        if (work_dir != null) {
            builder.add_string_value (work_dir.get_path ());
        } else {
            builder.add_null_value ();
        }

        builder.set_member_name ("use_absolute");
        builder.add_boolean_value (use_absolute);

        builder.set_member_name ("show_header");
        builder.add_boolean_value (show_header);

        builder.set_member_name ("checked_files");
        builder.begin_array ();
        foreach (var key in checked_paths) {
            builder.add_string_value (key);
        }
        builder.end_array ();

        builder.set_member_name ("checked_dirs");
        builder.begin_array ();
        foreach (var key in checked_dirs) {
            builder.add_string_value (key);
        }
        builder.end_array ();

        builder.set_member_name ("items");
        builder.begin_array ();
        for (int i = 0; i < items.size; i++) {
            var data = items.get (i);
            builder.begin_object ();
            builder.set_member_name ("type");
            builder.add_string_value (data.item_type);
            if (data.item_type == "file") {
                builder.set_member_name ("path");
                builder.add_string_value (data.file_path);
                builder.set_member_name ("force_absolute");
                builder.add_boolean_value (data.force_absolute);
                if (data.is_missing) {
                    builder.set_member_name ("missing");
                    builder.add_boolean_value (true);
                }
                if (data.start_line > 0) {
                    builder.set_member_name ("start_line");
                    builder.add_int_value (data.start_line);
                }
                if (data.end_line > 0) {
                    builder.set_member_name ("end_line");
                    builder.add_int_value (data.end_line);
                }
            } else {
                builder.set_member_name ("content");
                builder.add_string_value (data.content);
            }
            builder.end_object ();
        }
        builder.end_array ();

        builder.set_member_name ("common_phrases");
        builder.begin_array ();
        for (int i = 0; i < common_phrases.size; i++) {
            builder.add_string_value (common_phrases.get (i));
        }
        builder.end_array ();

        builder.end_object ();

        var generator = new Json.Generator ();
        generator.set_root (builder.get_root ());
        generator.pretty = true;

        try {
            ConfigManager.atomic_write_json (generator, file_path);
        } catch (Error e) {
            warning ("Failed to save project file %s: %s", file_path, e.message);
            throw e;
        }
    }
}
