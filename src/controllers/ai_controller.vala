using Gee;
using Json;

// 封装 AI 工具调用路由，与 AppState 交互。
// 纯逻辑工具 (list_files, read_file, list_items) 直接执行；
// 状态变更工具操作 AppState 并通过信号通知 View 层执行 UI 刷新。
public class AIController : GLib.Object {
    public AppState app_state { get; construct; }

    // 信号: 通知 View 层执行 UI 相关操作
    public signal void undo_snapshot_requested ();
    public signal void undo_delta_requested (UndoDelta delta);
    public signal void tree_check_changed (string path, bool checked);
    public signal void work_dir_change_requested (string path);
    public signal void clear_items_requested ();
    public signal void refresh_list_requested ();
    // 通知 View 层对刚加入的 item 触发二进制预处理 (AI 走 app_state.add_file 后
    // path_in_items 变 true, 后续 tree_check_changed 不会再调 check_and_apply_cache,
    // 所以需要这个独立信号兜底)
    public signal void preprocess_item_requested (string path);
    public signal void ai_batch_operation_completed (string summary);

    public AIController (AppState state) {
        GLib.Object (app_state: state);
    }

    // ── AI 状态提供 (供 AIPanel 在生成 system prompt 时调用) ──────────
    public AISystemSnapshot get_system_snapshot () {
        var snap = AISystemSnapshot ();
        snap.work_dir = (app_state.work_dir != null) ? app_state.work_dir.get_path () : "";
        snap.mode = app_state.ai_mode;
        snap.file_extension = app_state.ai_file_extension;
        snap.file_label = app_state.ai_file_label;
        snap.max_files = app_state.ai_max_files;
        snap.use_absolute = app_state.use_absolute;
        snap.show_header = app_state.show_header;
        snap.selected_paths = new string[0];
        snap.custom_instructions = new string[0];

        var paths = new Gee.ArrayList<string> ();
        var instructions = new Gee.ArrayList<string> ();
        for (int i = 0; i < app_state.items.size; i++) {
            var it = app_state.items.get (i);
            if (it.item_type == "file") {
                if (it.file_path != null) {
                    string rel = it.file_path;
                    if (app_state.work_dir != null) {
                        var r = app_state.work_dir.get_relative_path (File.new_for_path (it.file_path));
                        if (r != null) rel = r;
                    }
                    paths.add (rel);
                }
            } else if (it.item_type == "text") {
                string t = it.content ?? "";
                t = t.strip ();
                instructions.add (t);
            }
        }
        snap.selected_paths = (string[]) paths.to_array ();
        snap.custom_instructions = (string[]) instructions.to_array ();
        return snap;
    }

    // ── AI 工具执行路由 ───────────────────────────────────────────────
    public string execute_tool (string name, Json.Node args) throws GLib.Error {
        switch (name) {
            case "list_files": return tool_list_files (args);
            case "read_file":  return tool_read_file (args);
            case "set_work_dir": return tool_set_work_dir (args);
            case "add_files":  return tool_add_files (args);
            case "remove_files": return tool_remove_files (args);
            case "add_text":
            case "add_custom_instruction":
            case "insert_text": return tool_add_text (args);
            case "remove_item": return tool_remove_item (args);
            case "remove_custom_instruction": return tool_remove_text (args);
            case "move_item": return tool_move_item (args);
            case "clear_items":
            case "clear_all":   return tool_clear_all (args);
            case "list_items":  return tool_list_items (args);
            case "set_use_absolute": return tool_set_use_absolute (args);
            case "set_show_header": return tool_set_show_header (args);
            case "set_mode":
            case "set_file_extension":
            case "set_file_label":
            case "set_max_files":
                return tool_set_meta (name, args);
            case "get_git_status": return tool_get_git_status (args);
            case "get_git_diff": return tool_get_git_diff (args);
            case "get_git_log": return tool_get_git_log (args);
            case "get_git_commit_diff": return tool_get_git_commit_diff (args);
            case "add_git_diff": return tool_add_git_diff (args);
            case "add_git_commit_diff": return tool_add_git_commit_diff (args);
            case "add_git_diff_range": return tool_add_git_diff_range (args);
            case "add_file_snippet": return tool_add_file_snippet (args);
            default:
                return _("未知工具: ") + name;
        }
    }

    // ─── 工具实现 ────────────────────────────────────────────────────

    private string tool_list_files (Json.Node args) throws GLib.Error {
        if (app_state.work_dir == null) return _("工作目录未设置");
        if (args.get_node_type () != Json.NodeType.OBJECT) return _("参数错误");
        var o = args.get_object ();

        string pattern = o.has_member ("pattern") ? o.get_string_member ("pattern") : "";
        int64 max_results = o.has_member ("max_results") ? o.get_int_member ("max_results") : 500;
        int64 max_depth = o.has_member ("max_depth") ? o.get_int_member ("max_depth") : 8;

        if (max_results <= 0) max_results = 500;
        if (max_depth <= 0) max_depth = 8;

        if (pattern.strip () == "") pattern = "*";

        var sb = new StringBuilder ();
        sb.append ("ROOT=").append (app_state.work_dir.get_path ()).append ("\n");

        if (pattern.contains ("**")) {
            string[] ignored_dirs = ConfigManager.get_ignored_dirs ();
            var results = GlobHelper.expand_glob (
                app_state.work_dir.get_path (),
                pattern,
                (int) max_depth,
                (int) max_results
            );

            int count = 0;
            foreach (var path in results) {
                if (count >= max_results) break;
                var file = File.new_for_path (path);
                try {
                    var info = file.query_info (
                        FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_SIZE,
                        FileQueryInfoFlags.NONE
                    );
                    string name = file.get_basename ();
                    if (name in ignored_dirs) continue;
                    if (info.get_file_type () == FileType.DIRECTORY) {
                        sb.append ("DIR  ").append (rel_path (app_state.work_dir.get_path (), path)).append ("\n");
                    } else {
                        sb.append ("FILE ").append (rel_path (app_state.work_dir.get_path (), path))
                          .append ("  (").append (UIHelpers.format_size (info.get_size ())).append (")\n");
                    }
                    count++;
                } catch (Error e) {
                }
            }
            sb.append ("\n# total ").append (results.size.to_string ())
              .append (" matched, listed ").append (count.to_string ());
        } else {
            var matcher = new PatternSpec (pattern.down ());
            int count = 0;
            int total = 0;
            try {
                string[] ignored_dirs = ConfigManager.get_ignored_dirs ();
                list_files_recursive (app_state.work_dir.get_path (), app_state.work_dir.get_path (), 0, (int) max_depth,
                    matcher, sb, ref count, ref total, (int) max_results, ignored_dirs);
            } catch (Error e) {
                return _("读取目录失败: ") + e.message;
            }
            sb.append ("\n# total ").append (total.to_string ())
              .append (" matched, listed ").append (count.to_string ());
        }
        return sb.str;
    }

    private static void list_files_recursive (string root, string dir, int depth, int max_depth,
            PatternSpec matcher, StringBuilder sb, ref int count, ref int total, int max_results,
            string[] ignored_dirs)
            throws Error {
        if (count >= max_results) return;
        if (depth > max_depth) return;
        var dir_file = File.new_for_path (dir);
        if (!dir_file.query_exists ()) return;
        var en = dir_file.enumerate_children (
            FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_SIZE,
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo info;
        while ((info = en.next_file ()) != null) {
            if (count >= max_results) break;
            string name = info.get_name ();
            string full = dir_file.get_child (name).get_path ();
            if (info.get_file_type () == FileType.DIRECTORY) {
                if (name in ignored_dirs) {
                    continue;
                }
                if (matcher.match_string (name.down ()) && count < max_results) {
                    sb.append ("DIR  ").append (rel_path (root, full)).append ("\n");
                    count++;
                }
                list_files_recursive (root, full, depth + 1, max_depth, matcher, sb,
                    ref count, ref total, max_results, ignored_dirs);
            } else {
                total++;
                if (matcher.match_string (name.down ())) {
                    sb.append ("FILE ").append (rel_path (root, full))
                      .append ("  (").append (UIHelpers.format_size (info.get_size ())).append (")\n");
                    count++;
                }
            }
        }
    }

    private string tool_read_file (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        var o = args.get_object ();
        string path = o.has_member ("path") ? o.get_string_member ("path") : "";
        if (path == "") return _("缺少 path");
        int64 max_bytes = o.has_member ("max_bytes") ? o.get_int_member ("max_bytes") : 102400;
        int64 start_line = o.has_member ("start_line") ? o.get_int_member ("start_line") : 1;
        int64 max_lines = o.has_member ("max_lines") ? o.get_int_member ("max_lines") : 500;
        if (max_bytes <= 0) max_bytes = 102400;
        if (max_bytes > 524288) max_bytes = 524288; // 512KB hard cap
        if (max_lines <= 0) max_lines = 500;

        string? resolved = resolve_ai_path (path);
        if (resolved == null) return _("无法解析路径 (未设置工作目录)");
        if (!is_path_in_work_dir (resolved)) return _("拒绝访问: 路径超出工作目录范围");
        string abs = resolved;
        var file = File.new_for_path (abs);
        if (!file.query_exists ()) return _("文件不存在: ") + abs;

        int64 file_size = 0;
        try {
            var info = file.query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
            file_size = info.get_size ();
        } catch (Error e) {
            return _("读取文件信息失败: ") + e.message;
        }

        uint8[] raw = new uint8[max_bytes];
        FileInputStream? fis = null;
        size_t bytes_read = 0;
        try {
            fis = file.read ();
            bytes_read = fis.read (raw);
        } catch (Error e) {
            return _("读取失败: ") + e.message;
        } finally {
            if (fis != null) {
                try { fis.close (); } catch (Error e) { debug ("Close failed: %s", e.message); }
            }
        }
        raw.resize ((int) bytes_read);
        bool read_all = (bytes_read >= file_size);

        string content = EncodingHelper.decode_to_utf8 (raw);
        string[] lines = content.split ("\n");
        int start = (int) start_line - 1;
        if (start < 0) start = 0;
        if (start >= lines.length) {
            if (read_all) {
                return "[文件总行数: %d, start_line %s 越界]".printf (lines.length, start_line.to_string ());
            }
            return "[start_line %s 超出前 %s 字节可读范围, 请减小 start_line 或增大 max_bytes]".printf (start_line.to_string (), max_bytes.to_string ());
        }
        int end = int.min (lines.length, start + (int) max_lines);
        var sb = new StringBuilder ();
        sb.append ("# file: ").append (rel_path (app_state.work_dir != null ? app_state.work_dir.get_path () : "/", abs))
          .append ("  (").append (UIHelpers.format_size (file_size));
        if (!read_all) {
            sb.append (", 前 ").append (max_bytes.to_string ()).append (" 字节");
        }
        sb.append (", ").append (lines.length.to_string ()).append (" lines)\n");
        for (int i = start; i < end; i++) {
            sb.append ("%4d  ".printf (i + 1)).append (lines[i]).append ("\n");
            if (sb.str.length > max_bytes) {
                sb.append ("\n# ... [内容过长, 截断到 ").append (max_bytes.to_string ()).append (" 字节]");
                break;
            }
        }
        return sb.str;
    }

    private string tool_set_work_dir (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        string path = args.get_object ().get_string_member_with_default ("path", "");
        if (path == "") return "缺少 path";
        string? resolved = resolve_ai_path (path);
        if (resolved == null) return "无法解析路径 (未设置工作目录)";
        if (!is_path_allowed_for_work_dir (resolved))
            return _("拒绝访问: 工作目录必须在当前项目目录或用户主目录内");
        var file = File.new_for_path (resolved);
        if (!file.query_exists ()) return _("目录不存在: ") + resolved;
        work_dir_change_requested (resolved);
        return _("工作目录已切换到: ") + resolved;
    }

    private string tool_add_files (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        var o = args.get_object ();
        if (!o.has_member ("paths")) return _("缺少 paths");
        var paths_arr = o.get_array_member ("paths");
        if (paths_arr == null) return _("paths 必须是数组");

        string? after = o.has_member ("after_path") ? o.get_string_member ("after_path") : null;
        int added = 0;
        int total = (int) paths_arr.get_length ();
        var skipped = new Gee.ArrayList<string> ();
        undo_snapshot_requested ();
        int insert_at = app_state.items.size;
        if (after != null) {
            for (int i = 0; i < app_state.items.size; i++) {
                var it = app_state.items.get (i);
                if (it.item_type == "file" && it.file_path == after) {
                    insert_at = i + 1;
                    break;
                }
            }
        }
        for (int i = 0; i < total; i++) {
            string p = paths_arr.get_string_element (i);
            string? resolved = resolve_ai_path (p);
            if (resolved == null) {
                skipped.add (@_("$p (无法解析路径)"));
                continue;
            }
            if (!is_path_in_work_dir (resolved)) {
                skipped.add (@_("$p (路径超出工作目录)"));
                continue;
            }
            string abs = resolved;
            if (!FileUtils.test (abs, FileTest.EXISTS)) {
                skipped.add (@_("$p (文件不存在)"));
                continue;
            }
            bool exists = false;
            for (int j = 0; j < app_state.items.size; j++) {
                if (app_state.items.get (j).file_path == abs) { exists = true; break; }
            }
            if (exists) {
                skipped.add (@_("$p (已在列表中)"));
                continue;
            }
            app_state.add_file (abs, insert_at + added);
            if (!(abs in app_state.check_model.checked_files)) {
                app_state.check_model.add_files ({ abs });
            }
            // 触发二进制预处理 (修复: tree_check_changed 走 set_tree_item_check
            // 时 path 已在 items 中, 会跳过 check_and_apply_cache)
            preprocess_item_requested (abs);
            tree_check_changed (abs, true);
            added++;
        }
        refresh_list_requested ();
        string summary = _("AI 添加了 %d 个文件").printf (added);
        if (skipped.size > 0) {
            summary += _("，跳过 %d 个").printf (skipped.size);
        }
        ai_batch_operation_completed (summary);
        var sb = new StringBuilder ();
        sb.append ("已添加 %d 个文件 (请求 %d)".printf (added, total));
        if (skipped.size > 0) {
            sb.append (_("\n跳过 %d 个:\n").printf (skipped.size));
            foreach (var s in skipped) {
                sb.append ("  - ").append (s).append ("\n");
            }
        }
        return sb.str;
    }

    private string tool_remove_files (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        if (!args.get_object ().has_member ("paths")) return "缺少 paths";
        var arr = args.get_object ().get_array_member ("paths");
        if (arr == null) return "paths 必须是数组";
        int total = (int) arr.get_length ();
        int result = 0;
        undo_snapshot_requested ();
        for (int i = 0; i < total; i++) {
            string p = arr.get_string_element (i);
            string? resolved = resolve_ai_path (p);
            if (resolved == null || !is_path_in_work_dir (resolved)) continue;
            string abs = resolved;
            for (int j = app_state.items.size - 1; j >= 0; j--) {
                var it = app_state.items.get (j);
                if (it.item_type == "file" && it.file_path == abs) {
                    bool was_checked = abs in app_state.check_model.checked_files;
                    app_state.remove_item_at (j);
                    result++;
                    if (was_checked) {
                        tree_check_changed (abs, false);
                    }
                }
            }
        }
        refresh_list_requested ();
        ai_batch_operation_completed (_("AI 移除了 %d 个文件").printf (result));
        return "已移除 %d 个文件 (请求 %d)".printf (result, total);
    }

    private string tool_add_text (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        var o = args.get_object ();
        string text = o.has_member ("text") ? o.get_string_member ("text") :
                      (o.has_member ("content") ? o.get_string_member ("content") : "");
        if (text == "") return _("缺少 text / content");
        string? after = o.has_member ("after_path") ? o.get_string_member ("after_path") : null;
        string? before = o.has_member ("before_path") ? o.get_string_member ("before_path") : null;
        int insert_at = app_state.items.size;
        if (o.has_member ("position")) {
            int pos = (int) o.get_int_member ("position");
            if (pos < 0) pos = 0;
            if (pos > app_state.items.size) pos = app_state.items.size;
            insert_at = pos;
        } else if (after != null) {
            for (int i = 0; i < app_state.items.size; i++) {
                var it = app_state.items.get (i);
                if (it.item_type == "file" && it.file_path == after) {
                    insert_at = i + 1;
                    break;
                }
            }
        } else if (before != null) {
            insert_at = 0;
            for (int i = 0; i < app_state.items.size; i++) {
                var it = app_state.items.get (i);
                if (it.item_type == "file" && it.file_path == before) {
                    insert_at = i;
                    break;
                }
            }
        }
        var inserted = new Gee.ArrayList<ItemData> ();
        var new_item = new ItemData ("text", null, text, false);
        app_state.add_item (new_item, insert_at);
        inserted.add (new_item);
        undo_delta_requested (new UndoDelta.for_insert (insert_at, inserted));
        refresh_list_requested ();
        ai_batch_operation_completed (_("AI 插入了自定义文本"));
        return "已插入文本 (位置 %d)".printf (insert_at);
    }

    private string tool_remove_item (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        if (!args.get_object ().has_member ("index")) return _("缺少 index");
        int idx = (int) args.get_object ().get_int_member ("index");
        if (idx < 0 || idx >= app_state.items.size) {
            return "索引越界: %d (列表共 %d 项)".printf (idx, app_state.items.size);
        }
        var removed = app_state.items.get (idx);
        var rm_items = new Gee.ArrayList<ItemData> ();
        rm_items.add (removed);
        var rm_checked = new Gee.ArrayList<string> ();
        if (removed.item_type == "file" && removed.file_path != null) {
            if (removed.file_path in app_state.check_model.checked_files) {
                rm_checked.add (removed.file_path);
                tree_check_changed (removed.file_path, false);
            }
        }
        app_state.remove_item_at (idx);
        undo_delta_requested (new UndoDelta.for_remove (idx, rm_items, rm_checked));
        refresh_list_requested ();
        return "已删除第 %d 项 (%s)".printf (idx, removed.item_type);
    }

    private string tool_move_item (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        var o = args.get_object ();
        if (!o.has_member ("from_index") || !o.has_member ("to_index")) return _("缺少 from_index / to_index");
        int from = (int) o.get_int_member ("from_index");
        int to = (int) o.get_int_member ("to_index");
        if (from < 0 || from >= app_state.items.size) {
            return "from_index 越界: %d (列表共 %d 项)".printf (from, app_state.items.size);
        }
        if (to < 0 || to >= app_state.items.size) {
            return "to_index 越界: %d (列表共 %d 项)".printf (to, app_state.items.size);
        }
        app_state.move_item (from, to);
        undo_delta_requested (new UndoDelta.for_move (from, to));
        refresh_list_requested ();
        return "已移动: %d → %d".printf (from, to);
    }

    private string tool_set_use_absolute (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        var o = args.get_object ();
        if (!o.has_member ("value")) return _("缺少 value");
        bool val = o.get_boolean_member ("value");
        bool old_abs = app_state.use_absolute;
        bool old_hdr = app_state.show_header;
        app_state.use_absolute = val;
        undo_delta_requested (new UndoDelta.for_absolute (old_abs, val, old_hdr, app_state.show_header));
        app_state.notify_state_changed ();
        refresh_list_requested ();
        return "use_absolute=" + val.to_string ();
    }

    private string tool_set_show_header (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        var o = args.get_object ();
        if (!o.has_member ("value")) return "缺少 value";
        bool val = o.get_boolean_member ("value");
        bool old_val = app_state.show_header;
        app_state.show_header = val;
        undo_delta_requested (new UndoDelta.for_header (old_val, val));
        app_state.notify_state_changed ();
        return "show_header=" + val.to_string ();
    }

    private string tool_remove_text (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        if (!args.get_object ().has_member ("index")) return "缺少 index";
        int idx = (int) args.get_object ().get_int_member ("index");
        int removed = 0;
        int remove_at = -1;
        ItemData? removed_item = null;
        for (int i = app_state.items.size - 1; i >= 0; i--) {
            if (app_state.items.get (i).item_type == "text") {
                if (idx == 0) {
                    remove_at = i;
                    removed_item = app_state.items.get (i);
                    app_state.remove_item_at (i);
                    removed = 1;
                    break;
                } else {
                    idx--;
                }
            }
        }
        if (removed > 0 && removed_item != null) {
            var rm_items = new Gee.ArrayList<ItemData> ();
            rm_items.add (removed_item);
            undo_delta_requested (new UndoDelta.for_remove (remove_at, rm_items));
        }
        refresh_list_requested ();
        return "已删除文本 (removed=%d)".printf (removed);
    }

    private string tool_clear_all (Json.Node args) throws GLib.Error {
        clear_items_requested ();
        ai_batch_operation_completed (_("AI 清空了编排列表"));
        return "已清空编排列表";
    }

    private string tool_list_items (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        var o = args.get_object ();
        string kind = o.has_member ("kind") ? o.get_string_member ("kind") : "all";
        int max_items = o.has_member ("max_items") ? (int) o.get_int_member ("max_items") : 200;
        if (max_items <= 0) max_items = 200;
        var sb = new StringBuilder ();
        int count = 0;
        for (int i = 0; i < app_state.items.size && count < max_items; i++) {
            var it = app_state.items.get (i);
            if (kind == "file" && it.item_type != "file") continue;
            if (kind == "text" && it.item_type != "text") continue;
            if (it.item_type == "file") {
                string rel = it.file_path;
                if (app_state.work_dir != null) {
                    var r = app_state.work_dir.get_relative_path (File.new_for_path (it.file_path));
                    if (r != null) rel = r;
                }
                sb.append ("#" + (i + 1).to_string () + "  [file] ").append (rel).append ("\n");
            } else {
                string preview = it.content ?? "";
                if (preview.length > 80) preview = UIHelpers.truncate_utf8 (preview, 80) + "…";
                preview = string.joinv ("\\n", preview.split ("\n"));
                sb.append ("#").append ((i + 1).to_string ()).append ("  [text] ").append (preview).append ("\n");
            }
            count++;
        }
        sb.append ("\n# total ").append (app_state.items.size.to_string ());
        return sb.str;
    }

    private string tool_set_meta (string name, Json.Node args) throws GLib.Error {
        switch (name) {
            case "set_mode": {
                if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
                string m = args.get_object ().get_string_member_with_default ("mode", "default");
                if (m != "default" && m != "directory" && m != "single") {
                    return _("无效 mode: ") + m;
                }
                app_state.ai_mode = m;
                return "mode=" + m;
            }
            case "set_file_extension": {
                if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
                app_state.ai_file_extension = args.get_object ().get_string_member_with_default ("extension", "");
                return "extension=" + app_state.ai_file_extension;
            }
            case "set_file_label": {
                if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
                app_state.ai_file_label = args.get_object ().get_string_member_with_default ("label", _("文件"));
                return "label=" + app_state.ai_file_label;
            }
            case "set_max_files": {
                if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
                int n = (int) args.get_object ().get_int_member ("max_files");
                if (n < 1) n = 1;
                app_state.ai_max_files = n;
                return "max_files=" + app_state.ai_max_files.to_string ();
            }
        }
        return _("未知 meta 工具: ") + name;
    }

    // ─── Git 工具实现 ────────────────────────────────────────────────

    private string tool_get_git_status (Json.Node args) throws GLib.Error {
        if (app_state.work_dir == null) return "Error: Work directory not set.";
        string output = GitService.get_status (app_state.work_dir.get_path ());
        if (output.strip ().length == 0) return "Working tree is clean. No uncommitted changes.";

        string repo_root = "";
        try {
            repo_root = GitService.run_git (app_state.work_dir.get_path (), { "rev-parse", "--show-toplevel" }).strip ();
        } catch (Error e) {
            repo_root = app_state.work_dir.get_path ();
        }

        return "REPO_ROOT=" + repo_root + "\n" + output;
    }

    private string tool_get_git_diff (Json.Node args) throws GLib.Error {
        if (app_state.work_dir == null) return "Error: Work directory not set.";
        bool staged = false;
        if (args.get_node_type () == Json.NodeType.OBJECT) {
            var o = args.get_object ();
            if (o.has_member ("staged")) staged = o.get_boolean_member ("staged");
        }
        string output = staged
            ? GitService.get_staged_diff (app_state.work_dir.get_path ())
            : GitService.get_working_tree_diff (app_state.work_dir.get_path ());
        if (output.strip ().length == 0) return staged ? "No staged changes." : "No unstaged changes.";
        const int MAX_DIFF_BYTES = 81920;
        if (output.length > MAX_DIFF_BYTES) {
            return output.substring (0, MAX_DIFF_BYTES) + "\n\n... [Diff truncated due to size]";
        }
        return output;
    }

    private string tool_get_git_log (Json.Node args) throws GLib.Error {
        if (app_state.work_dir == null) return "Error: Work directory not set.";
        int max_count = 10;
        if (args.get_node_type () == Json.NodeType.OBJECT) {
            var o = args.get_object ();
            if (o.has_member ("max_count")) max_count = (int) o.get_int_member ("max_count");
        }
        if (max_count <= 0) max_count = 10;
        if (max_count > 50) max_count = 50;
        var commits = GitService.get_log (app_state.work_dir.get_path (), max_count);
        var sb = new StringBuilder ();
        foreach (var c in commits) {
            sb.append (c.short_hash).append (" | ").append (c.author)
              .append (" | ").append (c.date).append (" | ").append (c.message).append ("\n");
        }
        if (sb.len == 0) return "No commits found.";
        return sb.str;
    }

    private string tool_get_git_commit_diff (Json.Node args) throws GLib.Error {
        if (app_state.work_dir == null) return "Error: Work directory not set.";
        if (args.get_node_type () != Json.NodeType.OBJECT) return _("参数错误");
        var o = args.get_object ();
        if (!o.has_member ("commit_hash")) return "Missing commit_hash";
        string hash = o.get_string_member ("commit_hash");
        if (hash.length < 4 || hash.length > 64) return "Error: Invalid commit hash format.";
        string output = GitService.get_commit_diff (app_state.work_dir.get_path (), hash);
        const int MAX_DIFF_BYTES = 81920;
        if (output.length > MAX_DIFF_BYTES) {
            return output.substring (0, MAX_DIFF_BYTES) + "\n\n... [Commit Diff truncated]";
        }
        return output;
    }

    private string tool_add_git_diff (Json.Node args) throws GLib.Error {
        if (app_state.work_dir == null) return "Error: Work directory not set.";
        bool staged = false;
        if (args.get_node_type () == Json.NodeType.OBJECT) {
            var o = args.get_object ();
            if (o.has_member ("staged")) staged = o.get_boolean_member ("staged");
        }

        string diff = staged
            ? GitService.get_staged_diff (app_state.work_dir.get_path ())
            : GitService.get_working_tree_diff (app_state.work_dir.get_path ());

        if (diff.strip ().length == 0) {
            return staged ? _("当前没有已暂存的改动。") : _("当前工作区没有未提交的改动。");
        }

        string md_text = "# Git %s Diff\n\n```diff\n%s\n```".printf (staged ? "Staged" : "Working Tree", diff);
        var item = new ItemData ("text", null, md_text, false);
        int insert_idx = app_state.items.size;
        var inserted = new Gee.ArrayList<ItemData> ();
        inserted.add (item);
        undo_delta_requested (new UndoDelta.for_insert (insert_idx, inserted));
        app_state.add_item (item, insert_idx);
        refresh_list_requested ();

        int lines = diff.split ("\n").length;
        return _("已成功将 Git Diff 注入编排列表 (%d 行)。").printf (lines);
    }

    private string tool_add_git_commit_diff (Json.Node args) throws GLib.Error {
        if (app_state.work_dir == null) return "Error: Work directory not set.";
        if (args.get_node_type () != Json.NodeType.OBJECT) return _("参数错误");
        var o = args.get_object ();
        if (!o.has_member ("commit_hash")) return "Missing commit_hash";
        string hash = o.get_string_member ("commit_hash");
        if (hash.length < 7 || hash.length > 40) return "Invalid commit hash.";

        string diff = GitService.get_commit_diff (app_state.work_dir.get_path (), hash);
        if (diff.strip ().length == 0) {
            return _("未找到该 Commit 的 Diff 或 Commit 不存在。");
        }

        string info = "";
        try {
            info = GitService.run_git (app_state.work_dir.get_path (), { "log", "-1", "--pretty=format:%s", hash }).strip ();
        } catch (Error e) {
            info = hash.substring (0, 7);
        }

        string md_text = "# Git Commit: %s (%s)\n\n```diff\n%s\n```".printf (
            hash.substring (0, int.min (7, hash.length)), info, diff);
        var item = new ItemData ("text", null, md_text, false);
        int insert_idx = app_state.items.size;
        var inserted = new Gee.ArrayList<ItemData> ();
        inserted.add (item);
        undo_delta_requested (new UndoDelta.for_insert (insert_idx, inserted));
        app_state.add_item (item, insert_idx);
        refresh_list_requested ();

        int lines = diff.split ("\n").length;
        return _("已成功将 Commit %s 的 Diff 注入编排列表 (%d 行)。").printf (hash.substring (0, 7), lines);
    }

    private string tool_add_git_diff_range (Json.Node args) throws GLib.Error {
        if (app_state.work_dir == null) return "Error: Work directory not set.";
        if (args.get_node_type () != Json.NodeType.OBJECT) return _("参数错误");
        var o = args.get_object ();
        if (!o.has_member ("from_hash")) return "Missing from_hash";
        string from_hash = o.get_string_member ("from_hash");
        string to_hash = o.has_member ("to_hash") ? o.get_string_member ("to_hash") : "HEAD";

        if (from_hash.length < 4 || from_hash.length > 64) return "Invalid from_hash.";
        if (to_hash.length < 1 || to_hash.length > 64) return "Invalid to_hash.";

        string wd = app_state.work_dir.get_path ();

        // Get commits in range (newest first), inclusive of both endpoints.
        // git log from~1..to includes 'from' itself (from~1 = parent of from).
        string log_output;
        try {
            log_output = GitService.run_git (wd, {
                "log", "--pretty=format:%H|%s", from_hash + "~1.." + to_hash
            });
        } catch (Error e) {
            // from_hash might be a root commit (~1 fails), fall back to from..to + manual include
            log_output = GitService.run_git (wd, {
                "log", "--pretty=format:%H|%s", from_hash + ".." + to_hash
            });
            // Prepend the from commit itself
            string from_msg = GitService.run_git (wd, {
                "log", "-1", "--pretty=format:%H|%s", from_hash
            }).strip ();
            if (from_msg.length > 0) {
                log_output = from_msg + "\n" + log_output;
            }
        }

        var commit_hashes = new Gee.ArrayList<string> ();
        var commit_msgs = new Gee.ArrayList<string> ();
        foreach (var line in log_output.split ("\n")) {
            string trimmed = line.strip ();
            if (trimmed.length == 0) continue;
            int sep = trimmed.index_of ("|");
            if (sep < 0) continue;
            commit_hashes.add (trimmed.substring (0, sep));
            commit_msgs.add (trimmed.substring (sep + 1));
        }

        if (commit_hashes.size == 0) {
            return _("从 %s 到 %s 没有新的提交。").printf (from_hash, to_hash);
        }

        // Reverse to chronological order (oldest first), then add each as separate item
        var inserted = new Gee.ArrayList<ItemData> ();
        int base_idx = app_state.items.size;
        int total_lines = 0;

        for (int i = commit_hashes.size - 1; i >= 0; i--) {
            string hash = commit_hashes[i];
            string message = commit_msgs[i];
            string diff = GitService.run_git (wd, { "show", "--format=", "--patch-with-stat", hash });

            if (diff.strip ().length == 0) continue;

            string short_hash = hash.substring (0, int.min (7, hash.length));
            string md_text = "# Git Commit: %s (%s)\n\n```diff\n%s\n```".printf (short_hash, message, diff);
            var item = new ItemData ("text", null, md_text, false);
            app_state.add_item (item, base_idx + inserted.size);
            inserted.add (item);
            total_lines += diff.split ("\n").length;
        }

        if (inserted.size > 0) {
            undo_delta_requested (new UndoDelta.for_insert (base_idx, inserted));
            refresh_list_requested ();
        }

        return _("已成功将 %d 个 Commit 的 Diff 注入编排列表 (%d 行)。").printf (inserted.size, total_lines);
    }

    private string tool_add_file_snippet (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return _("参数错误");
        var o = args.get_object ();
        string path = o.get_string_member_with_default ("path", "");
        int sl = (int) o.get_int_member ("start_line");
        int el = (int) o.get_int_member ("end_line");

        if (path == "" || sl <= 0 || el <= 0) return "参数无效";
        // 起始/结束填反时自动纠正顺序，并在返回信息中说明。
        bool swapped = false;
        if (sl > el) { int t = sl; sl = el; el = t; swapped = true; }

        string? resolved = resolve_ai_path (path);
        if (resolved == null || !is_path_in_work_dir (resolved)) return "路径无效或越界";
        if (!FileUtils.test (resolved, FileTest.EXISTS)) return "文件不存在";

        undo_snapshot_requested ();

        var item = new ItemData ("file", resolved, null, false);
        item.start_line = sl;
        item.end_line = el;
        app_state.add_item (item, -1);

        preprocess_item_requested (resolved);
        refresh_list_requested ();

        return (swapped ? _("已自动交换起始/结束行。") : "") +
            "已添加片段: %s [L%d-L%d]".printf (GLib.Path.get_basename (resolved), sl, el);
    }

    // ─── 静态辅助方法 ────────────────────────────────────────────────

    private static string rel_path (string root, string full) {
        if (full.has_prefix (root)) {
            string r = full.substring (root.length);
            while (r.has_prefix ("/")) r = r.substring (1);
            return r.length > 0 ? r : full;
        }
        return full;
    }

    private static string normalize_path (string path) {
        var stack = new Gee.ArrayList<string> ();
        foreach (unowned string part in path.split ("/")) {
            if (part == "" || part == ".") continue;
            if (part == "..") {
                if (stack.size > 0) stack.remove_at (stack.size - 1);
            } else {
                stack.add ((string) part);
            }
        }
        string joined = string.joinv ("/", (string[]) stack.to_array ());
        return path.has_prefix ("/") ? "/" + joined : joined;
    }

    private string? resolve_ai_path (string path) {
        string abs = path;
        if (!GLib.Path.is_absolute (path)) {
            if (app_state.work_dir != null) {
                abs = GLib.Path.build_filename (app_state.work_dir.get_path (), path);
            } else {
                return null;
            }
        }
        return normalize_path (abs);
    }

    private bool is_path_in_work_dir (string normalized_path) {
        if (app_state.work_dir == null) return false;
        string allowed = normalize_path (app_state.work_dir.get_path ());
        return normalized_path == allowed || normalized_path.has_prefix (allowed + "/");
    }

    private bool is_path_allowed_for_work_dir (string normalized_path) {
        string home = normalize_path (Environment.get_home_dir ());
        if (normalized_path == home || normalized_path.has_prefix (home + "/")) return true;
        if (app_state.work_dir != null) {
            string wd = normalize_path (app_state.work_dir.get_path ());
            if (normalized_path == wd || normalized_path.has_prefix (wd + "/")) return true;
        }
        return false;
    }
}
