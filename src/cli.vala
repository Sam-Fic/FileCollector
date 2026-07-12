using GLib;
using Gee;

public class CliController : GLib.Object {
    public File? work_dir { get; private set; }
    public Gee.ArrayList<ItemData> items { get; private set; }
    public bool use_absolute { get; private set; }
    public bool show_header { get; private set; }
    public Gee.HashSet<string> checked_paths { get; private set; }
    public Gee.HashSet<string> checked_dirs { get; private set; }
    public Gee.ArrayList<string> common_phrases { get; private set; }
    public Gee.ArrayList<string> operation_messages { get; private set; }

    private string? export_path = null;
    private string? save_path = null;
    private bool project_loaded = false;

    public CliController () {
        items = new Gee.ArrayList<ItemData> ();
        checked_paths = new Gee.HashSet<string> ();
        checked_dirs = new Gee.HashSet<string> ();
        common_phrases = new Gee.ArrayList<string> ();
        operation_messages = new Gee.ArrayList<string> ();
    }

    public void initialize_from_state (
        File? wdir,
        Gee.ArrayList<ItemData> existing_items,
        Gee.HashSet<string> existing_checked_paths,
        Gee.HashSet<string> existing_checked_dirs,
        Gee.ArrayList<string> existing_common_phrases,
        bool existing_use_absolute,
        bool existing_show_header
    ) {
        work_dir = wdir;
        use_absolute = existing_use_absolute;
        show_header = existing_show_header;

        items.clear ();
        for (int i = 0; i < existing_items.size; i++) {
            var item = existing_items.get (i);
            items.add (new ItemData (item.item_type, item.file_path, item.content, item.force_absolute, item.is_missing));
        }

        checked_paths.clear ();
        foreach (var path in existing_checked_paths) {
            checked_paths.add (path);
        }

        checked_dirs.clear ();
        foreach (var path in existing_checked_dirs) {
            checked_dirs.add (path);
        }

        common_phrases.clear ();
        for (int i = 0; i < existing_common_phrases.size; i++) {
            common_phrases.add (existing_common_phrases.get (i));
        }
    }

    // 从 AppState 初始化 CLI 状态
    public void initialize_from_app_state (AppState state) {
        initialize_from_state (
            state.work_dir,
            state.items,
            state.check_model.checked_files,
            state.check_model.checked_dirs,
            state.common_phrases,
            state.use_absolute,
            state.show_header
        );
    }

    // 将 CLI 操作结果应用回 AppState，返回 work_dir 是否变更
    public bool apply_to_state (AppState state) {
        bool work_dir_changed = false;
        if (work_dir != null) {
            if (state.work_dir == null || work_dir.get_path () != state.work_dir.get_path ()) {
                work_dir_changed = true;
            }
        }

        state.items.clear ();
        for (int i = 0; i < items.size; i++) state.items.add (items.get (i));
        // 常用语是全局设置, 仅在 CLI 加载了项目文件时才覆盖
        if (project_loaded) {
            state.common_phrases.clear ();
            for (int i = 0; i < common_phrases.size; i++) state.common_phrases.add (common_phrases.get (i));
        }
        state.check_model.replace_from (checked_paths, checked_dirs);
        state.use_absolute = use_absolute;
        state.show_header = show_header;

        if (work_dir_changed) {
            state.work_dir = work_dir;
        }

        state.items_changed ();
        state.state_changed ();
        return work_dir_changed;
    }

    public static bool is_cli_mode (string[] args) {
        foreach (var arg in args) {
            if (arg == "--work-dir" || arg == "--select-file" || arg == "--add-text" ||
                arg == "--move" || arg == "--remove" || arg == "--clear" ||
                arg == "--export" || arg == "--load" || arg == "--save" ||
                arg == "--absolute" || arg == "--header" || arg == "--help" ||
                arg == "-h" || arg == "--list-items") {
                return true;
            }
        }
        return false;
    }

    public bool parse_args (string[] args) {
        int i = 1;
        while (i < args.length) {
            string arg = args[i];

            if (arg == "--help" || arg == "-h") {
                print_help ();
                return true;
            } else if (arg == "--work-dir") {
                i++;
                if (i >= args.length) { show_missing_arg (arg); return false; }
                if (!apply_work_dir (args[i])) return false;
            } else if (arg == "--select-file") {
                i++;
                if (i >= args.length) { show_missing_arg (arg); return false; }
                if (!add_file (args[i])) return false;
            } else if (arg == "--add-text") {
                i++;
                if (i >= args.length) { show_missing_arg (arg); return false; }
                add_text (args[i]);
            } else if (arg == "--move") {
                i++;
                if (i + 1 >= args.length) { show_missing_arg (arg); return false; }
                int from = int.parse (args[i]);
                int to = int.parse (args[i + 1]);
                if (!move_item (from, to)) return false;
                i++;
            } else if (arg == "--remove") {
                i++;
                if (i >= args.length) { show_missing_arg (arg); return false; }
                if (!remove_item (int.parse (args[i]))) return false;
            } else if (arg == "--clear") {
                clear_items ();
            } else if (arg == "--absolute") {
                use_absolute = true;
                operation_messages.add (_("Absolute paths enabled"));
            } else if (arg == "--header") {
                show_header = true;
                operation_messages.add (_("Header info enabled"));
            } else if (arg == "--export") {
                i++;
                if (i >= args.length) { show_missing_arg (arg); return false; }
                export_path = args[i];
            } else if (arg == "--load") {
                i++;
                if (i >= args.length) { show_missing_arg (arg); return false; }
                if (!load_project (args[i])) return false;
            } else if (arg == "--save") {
                i++;
                if (i >= args.length) { show_missing_arg (arg); return false; }
                save_path = args[i];
            } else if (arg == "--list-items") {
                list_items ();
            } else {
                stderr.printf (_("Error: Unknown argument: %s\n"), arg);
                stderr.printf (_("Use --help to see usage information\n"));
                return false;
            }

            i++;
        }

        return true;
    }

    public int run (string[] args) {
        if (!parse_args (args)) return 1;
        if (!execute_save_export ()) return 1;
        return 0;
    }

    public bool execute_save_export () {
        bool success = true;
        if (save_path != null) {
            try {
                ProjectManager.write_project_file (
                    save_path, work_dir, use_absolute, show_header,
                    items, checked_paths, checked_dirs, common_phrases
                );
                stdout.printf (_("Project saved to: %s\n"), save_path);
                operation_messages.add (_("Project saved to: %s").printf (save_path));
            } catch (Error e) {
                stderr.printf (_("Failed to save project: %s\n"), e.message);
                operation_messages.add (_("Failed to save project: %s").printf (e.message));
                success = false;
            }
        }

        if (export_path != null) {
            if (items.size == 0) {
                stderr.printf (_("Error: Queue is empty, cannot export\n"));
                operation_messages.add (_("Export failed: Queue is empty"));
                success = false;
            } else {
                try {
                    FileGenerator.generate_file (export_path, items, use_absolute, show_header, work_dir);
                    stdout.printf (_("Merged text exported to: %s\n"), export_path);
                    operation_messages.add (_("Merged text exported to: %s").printf (export_path));
                } catch (Error e) {
                    stderr.printf (_("Export failed: %s\n"), e.message);
                    operation_messages.add (_("Export failed: %s").printf (e.message));
                    success = false;
                }
            }
        }

        return success;
    }

    private static void show_missing_arg (string arg) {
        stderr.printf (_("Error: Argument '%s' requires a value\n"), arg);
    }

    private void print_help () {
        stdout.printf (_("FileCollector %s — CLI Mode\n"), Config.VERSION);
        stdout.printf ("\n");
        stdout.printf (_("Usage: filecollector [options...] [--gui]"));
        stdout.printf ("\n");
        stdout.printf ("\n");
        stdout.printf (_("Working Directory:")); stdout.printf ("\n");
        stdout.printf ("  --work-dir DIR           "); stdout.printf (_("Set working directory")); stdout.printf ("\n");
        stdout.printf ("\n");
        stdout.printf (_("File Selection:")); stdout.printf ("\n");
        stdout.printf ("  --select-file PATH       "); stdout.printf (_("Add file to queue (can be used multiple times)")); stdout.printf ("\n");
        stdout.printf ("  --add-text \"TEXT\"        "); stdout.printf (_("Add custom text (can be used multiple times)")); stdout.printf ("\n");
        stdout.printf ("\n");
        stdout.printf (_("Queue Management:")); stdout.printf ("\n");
        stdout.printf ("  --move FROM TO           "); stdout.printf (_("Move item at index FROM to index TO")); stdout.printf ("\n");
        stdout.printf ("  --remove INDEX           "); stdout.printf (_("Remove item at INDEX")); stdout.printf ("\n");
        stdout.printf ("  --clear                  "); stdout.printf (_("Clear the queue")); stdout.printf ("\n");
        stdout.printf ("  --list-items             "); stdout.printf (_("List current queue items")); stdout.printf ("\n");
        stdout.printf ("\n");
        stdout.printf (_("Export Settings:")); stdout.printf ("\n");
        stdout.printf ("  --export PATH            "); stdout.printf (_("Export merged text to PATH")); stdout.printf ("\n");
        stdout.printf ("  --absolute               "); stdout.printf (_("Use Absolute Paths")); stdout.printf ("\n");
        stdout.printf ("  --header                 "); stdout.printf (_("Add header (working directory path)")); stdout.printf ("\n");
        stdout.printf ("\n");
        stdout.printf (_("Project Files:")); stdout.printf ("\n");
        stdout.printf ("  --load FILE              "); stdout.printf (_("Load state from project file")); stdout.printf ("\n");
        stdout.printf ("  --save FILE              "); stdout.printf (_("Save current state to project file")); stdout.printf ("\n");
        stdout.printf ("\n");
        stdout.printf (_("GUI Mode:")); stdout.printf ("\n");
        stdout.printf ("  --gui                    "); stdout.printf (_("Initialize with CLI args then open the GUI")); stdout.printf ("\n");
        stdout.printf ("\n");
        stdout.printf (_("Other:")); stdout.printf ("\n");
        stdout.printf ("  --help, -h               "); stdout.printf (_("Show this help message")); stdout.printf ("\n");
        stdout.printf ("\n");
        stdout.printf (_("Examples:"));
        stdout.printf ("\n");
        stdout.printf ("  1. "); stdout.printf (_("Build and export:")); stdout.printf ("\n");
        stdout.printf ("     filecollector --work-dir ./project \\\n");
        stdout.printf ("         --select-file src/main.vala \\\n");
        stdout.printf ("         --select-file src/utils/helper.vala \\\n");
        stdout.printf ("         --add-text \"=== "); stdout.printf (_("Configuration Files")); stdout.printf (" ===\" \\\n");
        stdout.printf ("         --select-file config.ini \\\n");
        stdout.printf ("         --move 3 2 \\\n");
        stdout.printf ("         --export output.txt\n");
        stdout.printf ("\n");
        stdout.printf ("  2. "); stdout.printf (_("Export from project file:")); stdout.printf ("\n");
        stdout.printf ("     filecollector --load my.project.fcol --export output.txt\n");
        stdout.printf ("\n");
        stdout.printf ("  3. "); stdout.printf (_("Build and save project:")); stdout.printf ("\n");
        stdout.printf ("     filecollector --work-dir ./project \\\n");
        stdout.printf ("         --select-file a.txt --select-file b.txt \\\n");
        stdout.printf ("         --save my.project.fcol\n");
        stdout.printf ("\n");
        stdout.printf ("  4. "); stdout.printf (_("View the queue:")); stdout.printf ("\n");
        stdout.printf ("     filecollector --load my.project.fcol --list-items\n");
        stdout.printf ("\n");
        stdout.printf ("  5. "); stdout.printf (_("Load project then open GUI for adjustments:")); stdout.printf ("\n");
        stdout.printf ("     filecollector --load my.project.fcol --gui\n");
        stdout.printf ("\n");
        stdout.printf ("  6. "); stdout.printf (_("Initialize state via CLI then open GUI:")); stdout.printf ("\n");
        stdout.printf ("     filecollector --work-dir ./project --select-file src/main.vala --gui\n");
        stdout.printf ("\n");
    }

    private bool apply_work_dir (string path) {
        var dir = File.new_for_path (path);
        if (!dir.query_exists ()) {
            stderr.printf (_("Error: Directory does not exist: %s\n"), path);
            return false;
        }
        work_dir = dir;
        stdout.printf (_("✓ Working directory set: %s\n"), path);
        operation_messages.add (_("Working directory set: %s").printf (path));
        return true;
    }

    private bool add_file (string path) {
        var file = File.new_for_path (path);
        if (!file.query_exists ()) {
            stderr.printf (_("Error: File does not exist: %s\n"), path);
            return false;
        }
        var abs_path = file.get_path ();
        var item = new ItemData ("file", abs_path, null, false);
        items.add (item);
        checked_paths.add (abs_path);
        stdout.printf (_("✓ File added [%d]: %s\n"), (int)items.size, abs_path);
        operation_messages.add (_("File added: %s").printf (file.get_basename ()));

        // 二进制文件: 同步触发预处理 (CLI 没有异步线程, 直接 block 调 VLM)
        // 命中缓存则直接复用, miss 则调 VLM 写入缓存, 并把 Markdown 挂到 item 上,
        // 后续 FileGenerator 导出时直接使用 preprocessed_content.
        if (work_dir != null &&
            item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
            try {
                bool from_cache;
                string md = BinaryPreprocessor.preprocess_sync (
                    item, work_dir.get_path (), out from_cache
                );
                item.preprocessed_content = md;
                item.preprocess_status = PreprocessStatus.COMPLETED;
                item.from_cache = from_cache;
                stdout.printf (_("  ↳ %s: %s\n"),
                    from_cache ? _("Reused from cache") : _("VLM conversion called"),
                    file.get_basename ());
            } catch (Error e) {
                stderr.printf (_("  ⚠ Preprocessing %s failed: %s\n"),
                    file.get_basename (), e.message);
                item.preprocess_status = PreprocessStatus.FAILED;
            }
        }
        return true;
    }

    private void add_text (string text) {
        items.add (new ItemData ("text", null, text, false));
        stdout.printf (_("✓ Text added [%d]: %s\n"), (int)items.size, text);
        var preview = text;
        if (preview.length > 30) preview = preview.substring (0, 30) + "...";
        operation_messages.add (_("Text added: %s").printf (preview));
    }

    private bool move_item (int from, int to) {
        if (items.size == 0) {
            stderr.printf (_("Error: Queue is empty\n"));
            return false;
        }
        if (from < 0 || from >= items.size) {
            stderr.printf (_("Error: Source index %d out of range (0-%d)\n"), from, items.size - 1);
            return false;
        }
        if (to < 0 || to >= items.size) {
            stderr.printf (_("Error: Target index %d out of range (0-%d)\n"), to, items.size - 1);
            return false;
        }
        if (from == to) return true;
        var tmp = items.remove_at (from);
        items.insert (to, tmp);
        stdout.printf (_("✓ Item moved from index %d to %d\n"), from, to);
        operation_messages.add (_("Item moved %d → %d").printf (from, to));
        return true;
    }

    private bool remove_item (int index) {
        if (index < 0 || index >= items.size) {
            stderr.printf (_("Error: Index %d out of range (0-%d)\n"), index, items.size - 1);
            return false;
        }
        var data = items.get (index);
        if (data.item_type == "file" && !data.force_absolute) {
            checked_paths.remove (data.file_path);
        }
        items.remove_at (index);
        stdout.printf (_("✓ Item at index %d deleted\n"), index);
        operation_messages.add (_("Item %d deleted").printf (index));
        return true;
    }

    private void clear_items () {
        items.clear ();
        checked_paths.clear ();
        checked_dirs.clear ();
        stdout.printf (_("✓ Queue cleared\n"));
        operation_messages.add (_("Queue cleared"));
    }

    private void list_items () {
        if (items.size == 0) {
            stdout.printf (_("Queue is empty\n"));
            return;
        }
        var dashes = new StringBuilder ();
        for (int j = 0; j < 60; j++) dashes.append_c('-');
        var dash_str = dashes.str;
        stdout.printf (_("Current queue (%d items):\n"), items.size);
        stdout.printf ("%s\n", dash_str);
        for (int i = 0; i < items.size; i++) {
            var data = items.get (i);
            if (data.item_type == "file") {
                stdout.printf ("  %d. [%s] %s\n", i, _("File"), data.file_path);
            } else {
                var preview = data.content;
                if (preview.length > 60) preview = preview.substring (0, 60) + "...";
                stdout.printf ("  %d. [%s] %s\n", i, _("Text"), preview);
            }
        }
        stdout.printf ("%s\n", dash_str);
        stdout.printf (_("Settings: Absolute paths=%s  Header=%s\n"),
                       use_absolute.to_string (), show_header.to_string ());
        if (work_dir != null) {
            stdout.printf (_("Working directory: %s\n"), work_dir.get_path ());
        }
    }

    private bool load_project (string path) {
        var file = File.new_for_path (path);
        if (!file.query_exists ()) {
            stderr.printf (_("Error: Project file does not exist: %s\n"), path);
            return false;
        }

        try {
            string content;
            size_t len;
            FileUtils.get_contents (path, out content, out len);
            var parser = new Json.Parser ();
            parser.load_from_data (content);

            var root = parser.get_root ().get_object ();
            project_loaded = true;

            var wd_str = root.get_string_member_with_default ("work_dir", "");
            if (wd_str != "") {
                var wd = File.new_for_path (wd_str);
                if (wd.query_exists ()) {
                    work_dir = wd;
                }
            }

            use_absolute = root.get_boolean_member_with_default ("use_absolute", false);
            show_header = root.get_boolean_member_with_default ("show_header", false);

            items.clear ();
            checked_paths.clear ();
            checked_dirs.clear ();

            var checked_arr = root.has_member ("checked_files") ? root.get_array_member ("checked_files") : null;
            if (checked_arr != null) {
                for (int i = 0; i < checked_arr.get_length (); i++) {
                    var p = checked_arr.get_string_element (i);
                    checked_paths.add (p);
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
                        var miss = obj.get_boolean_member_with_default ("missing", false);
                        var item = new ItemData ("file", p, null, fa, miss);
                        items.add (item);

                        // 二进制文件: 尝试从 .filecollector_cache 复用已转换的 Markdown
                        // (不主动调 VLM, 避免 load 时产生 API 费用/等待)
                        if (work_dir != null &&
                            !miss &&
                            item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
                            try {
                                string? md = BinaryPreprocessor.try_cache_only (
                                    item, work_dir.get_path ()
                                );
                                if (md != null) {
                                    item.preprocessed_content = md;
                                    item.preprocess_status = PreprocessStatus.COMPLETED;
                                    item.from_cache = true;
                                }
                            } catch (Error e) {
                                // 缓存读取失败, 保持 NONE, 导出时按二进制处理
                            }
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

            stdout.printf (_("✓ Loaded from project file: %s (%d items)\n"), path, items.size);
            operation_messages.add (_("Project loaded: %s (%d items)").printf (File.new_for_path (path).get_basename (), items.size));
            return true;
        } catch (Error e) {
            stderr.printf (_("Failed to load project: %s\n"), e.message);
            return false;
        }
    }
}
