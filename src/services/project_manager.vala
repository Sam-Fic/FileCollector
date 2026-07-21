using Gee;

public class ProjectManager : GLib.Object {
    public static void load_project_file (
        string file_path,
        Gee.ArrayList<ItemData> items,
        Gee.HashSet<string> checked_paths,
        Gee.HashSet<string> checked_dirs,
        Gee.ArrayList<string> common_phrases,
        Gee.ArrayList<WorkspaceSnapshot> snapshots,
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

        var root_node = parser.get_root ();
        if (root_node == null || root_node.get_node_type () != Json.NodeType.OBJECT) {
            throw new IOError.INVALID_DATA (
                _("Project file %s has invalid format: root is not a JSON object").printf (file_path));
        }
        var root = root_node.get_object ();
        if (root == null) {
            throw new IOError.INVALID_DATA (
                _("Project file %s has invalid format: root object is null").printf (file_path));
        }

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
                var type = obj.get_string_member_with_default ("type", "file");
                if (type == "file") {
                    var p = obj.get_string_member_with_default ("path", "");
                    if (p == "") continue;  // 没有 path 的 file 项无意义, 跳过
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

        // 工作区快照（向后兼容：旧工程文件无 snapshots 字段时为空）
        snapshots.clear ();
        var snaps_arr = root.has_member ("snapshots") ? root.get_array_member ("snapshots") : null;
        if (snaps_arr != null) {
            for (int i = 0; i < snaps_arr.get_length (); i++) {
                var so = snaps_arr.get_object_element (i);
                if (so == null) continue;
                var snap = new WorkspaceSnapshot ();
                snap.name = so.get_string_member_with_default ("name", _("Snapshot %d").printf (i + 1));
                snap.id = so.get_string_member_with_default ("id", snap.id);
                snap.created_at = (int64) so.get_int_member_with_default ("created_at", snap.created_at);
                snap.icon_name = so.get_string_member_with_default ("icon", "view-grid-symbolic");

                var swd = so.get_string_member_with_default ("work_dir", "");
                snap.work_dir = (swd != "") ? File.new_for_path (swd) : null;
                snap.use_absolute = so.get_boolean_member_with_default ("use_absolute", false);
                snap.show_header = so.get_boolean_member_with_default ("show_header", false);

                var sitems = so.has_member ("items") ? so.get_array_member ("items") : null;
                if (sitems != null) {
                    for (int j = 0; j < sitems.get_length (); j++) {
                        var io = sitems.get_object_element (j);
                        if (io == null) continue;
                        var itype = io.get_string_member_with_default ("type", "file");
                        if (itype == "file") {
                            var p = io.get_string_member_with_default ("path", "");
                            if (p == "") continue;
                            var fa = io.get_boolean_member_with_default ("force_absolute", false);
                            var sl = (int) io.get_int_member_with_default ("start_line", 0);
                            var el = (int) io.get_int_member_with_default ("end_line", 0);
                            // is_missing 由当前磁盘状态决定, 与顶层 items 加载逻辑保持一致.
                            // JSON 中的 missing 字段仅作为保存时的记录, 加载时不直接使用;
                            // 否则文件被删除后快照仍显示为"存在", 或文件恢复后仍显示"缺失".
                            bool missing = !File.new_for_path (p).query_exists ();
                            var item = new ItemData ("file", p, null, fa, missing);
                            item.start_line = sl;
                            item.end_line = el;
                            snap.items.add (item);
                        } else {
                            var c = io.get_string_member_with_default ("content", "");
                            snap.items.add (new ItemData ("text", null, c, false));
                        }
                    }
                }

                var scp = so.has_member ("checked_files") ? so.get_array_member ("checked_files") : null;
                if (scp != null) {
                    for (int j = 0; j < scp.get_length (); j++) snap.checked_paths.add (scp.get_string_element (j));
                }
                var scd = so.has_member ("checked_dirs") ? so.get_array_member ("checked_dirs") : null;
                if (scd != null) {
                    for (int j = 0; j < scd.get_length (); j++) snap.checked_dirs.add (scd.get_string_element (j));
                }
                var sph = so.has_member ("common_phrases") ? so.get_array_member ("common_phrases") : null;
                if (sph != null) {
                    for (int j = 0; j < sph.get_length (); j++) snap.common_phrases.add (sph.get_string_element (j));
                }

                snap.ai_mode = so.get_string_member_with_default ("ai_mode", "default");
                snap.ai_file_extension = so.get_string_member_with_default ("ai_file_extension", "");
                snap.ai_file_label = so.get_string_member_with_default ("ai_file_label", _("File"));
                snap.ai_max_files = (int) so.get_int_member_with_default ("ai_max_files", 50);

                snapshots.add (snap);
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
        Gee.ArrayList<string> common_phrases,
        Gee.ArrayList<WorkspaceSnapshot> snapshots
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

        // 工作区快照
        builder.set_member_name ("snapshots");
        builder.begin_array ();
        for (int i = 0; i < snapshots.size; i++) {
            var snap = snapshots.get (i);
            builder.begin_object ();

            builder.set_member_name ("name");
            builder.add_string_value (snap.name);
            builder.set_member_name ("id");
            builder.add_string_value (snap.id);
            builder.set_member_name ("created_at");
            builder.add_int_value (snap.created_at);

            builder.set_member_name ("icon");
            builder.add_string_value (snap.icon_name);

            builder.set_member_name ("work_dir");
            if (snap.work_dir != null) {
                builder.add_string_value (snap.work_dir.get_path ());
            } else {
                builder.add_null_value ();
            }
            builder.set_member_name ("use_absolute");
            builder.add_boolean_value (snap.use_absolute);
            builder.set_member_name ("show_header");
            builder.add_boolean_value (snap.show_header);

            builder.set_member_name ("checked_files");
            builder.begin_array ();
            foreach (var key in snap.checked_paths) builder.add_string_value (key);
            builder.end_array ();

            builder.set_member_name ("checked_dirs");
            builder.begin_array ();
            foreach (var key in snap.checked_dirs) builder.add_string_value (key);
            builder.end_array ();

            builder.set_member_name ("items");
            builder.begin_array ();
            for (int j = 0; j < snap.items.size; j++) {
                var data = snap.items.get (j);
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
            for (int j = 0; j < snap.common_phrases.size; j++) {
                builder.add_string_value (snap.common_phrases.get (j));
            }
            builder.end_array ();

            builder.set_member_name ("ai_mode");
            builder.add_string_value (snap.ai_mode);
            builder.set_member_name ("ai_file_extension");
            builder.add_string_value (snap.ai_file_extension);
            builder.set_member_name ("ai_file_label");
            builder.add_string_value (snap.ai_file_label);
            builder.set_member_name ("ai_max_files");
            builder.add_int_value (snap.ai_max_files);

            builder.end_object ();
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
