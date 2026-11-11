using Gee;

public class ProjectManager : GLib.Object {

    // 项目文件里勾选路径的归一化: Flet 版可能写正斜杠或相对 work_dir 的路径,
    // 而本版勾选匹配 (path in checked_files) 是字符串精确比较, 必须转成
    // File.get_path () 的规范形态才能命中。
    //
    // 关键边界: File.new_for_path () 内部会 g_canonicalize_filename (path, NULL),
    // 相对路径在 relative_to == NULL 时会被绑到当前工作目录。work_dir 缺失时
    // 绝不能让它按 CWD 解析 —— 便携包双击启动的 CWD 是任意的, 会勾错同名文件,
    // 还会被 CLI 的 --save 写回项目文件。此时返回 null, 由调用方丢弃该条目。
    public static string? canonicalize_checked_path (string path, File? work_dir) {
        if (path == "") return null;
        try {
            File f;
            if (GLib.Path.is_absolute (path)) {
                f = File.new_for_path (path);
            } else if (work_dir != null) {
                f = work_dir.resolve_relative_path (path);
            } else {
                return null;
            }
            var canonical = f.get_path ();
            return (canonical != null && canonical != "") ? canonical : null;
        } catch (Error e) {
            return null;
        }
    }

    // 字符串数组读取的统一规则, GUI (load_project_file) 与 CLI (load_project)
    // 共用: 取到 Json.Array 才算命中, 命中失败继续回退到 fallback 字段;
    // 非字符串元素会被 get_string_element 返回 null, 一律跳过, 不能塞进集合。
    // fallback 传 "" 表示无回退字段。
    public static Gee.ArrayList<string> read_string_array (
        Json.Object obj, string primary, string fallback
    ) {
        var result = new Gee.ArrayList<string> ();
        Json.Array? arr = null;
        if (obj.has_member (primary)) {
            arr = obj.get_array_member (primary);
        }
        if (arr == null && fallback != "" && obj.has_member (fallback)) {
            arr = obj.get_array_member (fallback);
        }
        if (arr == null) return result;
        for (int i = 0; i < arr.get_length (); i++) {
            var value = arr.get_string_element (i);
            if (value == null || value == "") continue;
            result.add (value);
        }
        return result;
    }

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

        // checked_files / checked_entries 兼容 + 路径归一化; GUI 与 CLI 走同一套规则。
        foreach (var p in read_string_array (root, "checked_files", "checked_entries")) {
            var canonical = canonicalize_checked_path (p, work_dir);
            if (canonical != null && File.new_for_path (canonical).query_exists ()) {
                checked_paths.add (canonical);
            }
        }

        // 目录勾选只做 null / 类型防御, 不改路径形态: checked_dirs 在 UI 里
        // 与 checked_files 的生成路径不同, 贸然归一化会改变既有树状态语义。
        foreach (var d in read_string_array (root, "checked_dirs", "")) {
            checked_dirs.add (d);
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
        foreach (var phrase in read_string_array (root, "common_phrases", "")) {
            common_phrases.add (phrase);
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

                // 快照同样兼容 checked_entries 并做 null 防御; 路径不做归一化,
                // 保留保存时的原样, 避免恢复快照时改变既有勾选语义。
                foreach (var p in read_string_array (so, "checked_files", "checked_entries")) {
                    snap.checked_paths.add (p);
                }
                foreach (var d in read_string_array (so, "checked_dirs", "")) {
                    snap.checked_dirs.add (d);
                }
                foreach (var ph in read_string_array (so, "common_phrases", "")) {
                    snap.common_phrases.add (ph);
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
