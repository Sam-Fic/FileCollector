public class ProjectManager : GLib.Object {
    public static void load_project_file (
        string file_path,
        GenericArray<ItemData> items,
        HashTable<string, bool> checked_paths,
        GenericArray<string> common_phrases,
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

        checked_paths.remove_all ();
        items.remove_range (0, items.length);

        use_absolute = root.get_boolean_member_with_default ("use_absolute", false);
        show_header = root.get_boolean_member_with_default ("show_header", false);

        var checked_arr = root.get_array_member ("checked_files");
        if (checked_arr != null) {
            for (int i = 0; i < checked_arr.get_length (); i++) {
                var p = checked_arr.get_string_element (i);
                if (File.new_for_path (p).query_exists ()) {
                    checked_paths.insert (p, true);
                }
            }
        }

        var items_arr = root.get_array_member ("items");
        if (items_arr != null) {
            for (int i = 0; i < items_arr.get_length (); i++) {
                var obj = items_arr.get_object_element (i);
                var type = obj.get_string_member ("type");
                if (type == "file") {
                    var p = obj.get_string_member ("path");
                    var fa = obj.get_boolean_member_with_default ("force_absolute", false);
                    if (File.new_for_path (p).query_exists ()) {
                        items.add (new ItemData ("file", p, null, fa));
                    } else {
                        items.add (new ItemData ("text", null, _("[缺失文件: %s]").printf (p), false));
                    }
                } else {
                    var c = obj.get_string_member_with_default ("content", "");
                    items.add (new ItemData ("text", null, c, false));
                }
            }
        }

        common_phrases.remove_range (0, common_phrases.length);
        var phrases_arr = root.get_array_member ("common_phrases");
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
        GenericArray<ItemData> items,
        HashTable<string, bool> checked_paths,
        GenericArray<string> common_phrases
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
        checked_paths.foreach ((key, val) => {
            builder.add_string_value ((string) key);
        });
        builder.end_array ();

        builder.set_member_name ("items");
        builder.begin_array ();
        for (int i = 0; i < items.length; i++) {
            var data = items.get (i);
            builder.begin_object ();
            builder.set_member_name ("type");
            builder.add_string_value (data.item_type);
            if (data.item_type == "file") {
                builder.set_member_name ("path");
                builder.add_string_value (data.file_path);
                builder.set_member_name ("force_absolute");
                builder.add_boolean_value (data.force_absolute);
            } else {
                builder.set_member_name ("content");
                builder.add_string_value (data.content);
            }
            builder.end_object ();
        }
        builder.end_array ();

        builder.set_member_name ("common_phrases");
        builder.begin_array ();
        for (int i = 0; i < common_phrases.length; i++) {
            builder.add_string_value (common_phrases.get (i));
        }
        builder.end_array ();

        builder.end_object ();

        var generator = new Json.Generator ();
        generator.set_root (builder.get_root ());
        generator.pretty = true;

        try {
            var file_stream = File.new_for_path (file_path).replace (null, false, FileCreateFlags.NONE);
            generator.to_stream (file_stream, null);
        } catch (Error e) {
            var str = generator.to_data (null);
            FileUtils.set_contents (file_path, str);
        }
    }
}
