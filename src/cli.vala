using GLib;

public class CliController : GLib.Object {
    public File? work_dir { get; private set; }
    public GenericArray<ItemData> items { get; private set; }
    public bool use_absolute { get; private set; }
    public bool show_header { get; private set; }
    public HashTable<string, bool> checked_paths { get; private set; }
    public GenericArray<string> common_phrases { get; private set; }

    private string? export_path = null;
    private string? save_path = null;

    public CliController () {
        items = new GenericArray<ItemData> ();
        checked_paths = new HashTable<string, bool> (str_hash, str_equal);
        common_phrases = new GenericArray<string> ();
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
            } else if (arg == "--header") {
                show_header = true;
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
                stderr.printf (_("错误: 未知参数: %s\n"), arg);
                stderr.printf (_("使用 --help 查看帮助信息\n"));
                return false;
            }

            i++;
        }

        return true;
    }

    public int run (string[] args) {
        if (!parse_args (args)) return 1;

        if (save_path != null) {
            try {
                ProjectManager.write_project_file (
                    save_path, work_dir, use_absolute, show_header,
                    items, checked_paths, common_phrases
                );
                stdout.printf (_("项目已保存到: %s\n"), save_path);
            } catch (Error e) {
                stderr.printf (_("保存项目失败: %s\n"), e.message);
                return 1;
            }
        }

        if (export_path != null) {
            if (items.length == 0) {
                stderr.printf (_("错误: 编排列表为空，无法导出\n"));
                return 1;
            }
            try {
                FileGenerator.generate_file (export_path, items, use_absolute, show_header, work_dir);
                stdout.printf (_("合并文本已导出到: %s\n"), export_path);
            } catch (Error e) {
                stderr.printf (_("导出失败: %s\n"), e.message);
                return 1;
            }
        }

        return 0;
    }

    private static void show_missing_arg (string arg) {
        stderr.printf (_("错误: 参数 '%s' 缺少必要的值\n"), arg);
    }

    private void print_help () {
        stdout.printf (_("FileCollector %s — CLI 命令行模式\n"), Config.VERSION);
        stdout.printf ("\n");
        stdout.printf (_("用法: filecollector [选项...] [--gui]"));
        stdout.printf ("\n");
        stdout.printf ("\n");
        stdout.printf (_("工作目录:")); stdout.printf ("\n");
        stdout.printf ("  --work-dir DIR           "); stdout.printf (_("设置工作目录")); stdout.printf ("\n");
        stdout.printf ("\n");
        stdout.printf (_("文件选择:")); stdout.printf ("\n");
        stdout.printf ("  --select-file PATH       "); stdout.printf (_("添加文件到编排列表 (可多次使用)")); stdout.printf ("\n");
        stdout.printf ("  --add-text \"TEXT\"        "); stdout.printf (_("添加自定义文字 (可多次使用)")); stdout.printf ("\n");
        stdout.printf ("\n");
        stdout.printf (_("编排调整:")); stdout.printf ("\n");
        stdout.printf ("  --move FROM TO           "); stdout.printf (_("将索引 FROM 处的项目移动到索引 TO")); stdout.printf ("\n");
        stdout.printf ("  --remove INDEX           "); stdout.printf (_("删除索引 INDEX 处的项目")); stdout.printf ("\n");
        stdout.printf ("  --clear                  "); stdout.printf (_("清空编排列表")); stdout.printf ("\n");
        stdout.printf ("  --list-items             "); stdout.printf (_("列出当前编排列表")); stdout.printf ("\n");
        stdout.printf ("\n");
        stdout.printf (_("导出设置:")); stdout.printf ("\n");
        stdout.printf ("  --export PATH            "); stdout.printf (_("导出合并文本到 PATH")); stdout.printf ("\n");
        stdout.printf ("  --absolute               "); stdout.printf (_("使用绝对路径")); stdout.printf ("\n");
        stdout.printf ("  --header                 "); stdout.printf (_("添加头部信息 (工作目录路径)")); stdout.printf ("\n");
        stdout.printf ("\n");
        stdout.printf (_("项目文件:")); stdout.printf ("\n");
        stdout.printf ("  --load FILE              "); stdout.printf (_("从项目文件加载状态")); stdout.printf ("\n");
        stdout.printf ("  --save FILE              "); stdout.printf (_("将当前状态保存到项目文件")); stdout.printf ("\n");
        stdout.printf ("\n");
        stdout.printf (_("GUI 模式:")); stdout.printf ("\n");
        stdout.printf ("  --gui                    "); stdout.printf (_("使用其他 CLI 参数初始化后打开图形界面")); stdout.printf ("\n");
        stdout.printf ("\n");
        stdout.printf (_("其他:")); stdout.printf ("\n");
        stdout.printf ("  --help, -h               "); stdout.printf (_("显示此帮助信息")); stdout.printf ("\n");
        stdout.printf ("\n");
        stdout.printf (_("示例:"));
        stdout.printf ("\n");
        stdout.printf ("  1. "); stdout.printf (_("构建并导出:")); stdout.printf ("\n");
        stdout.printf ("     filecollector --work-dir ./project \\\n");
        stdout.printf ("         --select-file src/main.vala \\\n");
        stdout.printf ("         --select-file src/utils/helper.vala \\\n");
        stdout.printf ("         --add-text \"=== "); stdout.printf (_("配置文件")); stdout.printf (" ===\" \\\n");
        stdout.printf ("         --select-file config.ini \\\n");
        stdout.printf ("         --move 3 2 \\\n");
        stdout.printf ("         --export output.txt\n");
        stdout.printf ("\n");
        stdout.printf ("  2. "); stdout.printf (_("从项目文件导出:")); stdout.printf ("\n");
        stdout.printf ("     filecollector --load my.project.fcol --export output.txt\n");
        stdout.printf ("\n");
        stdout.printf ("  3. "); stdout.printf (_("构建并保存项目:")); stdout.printf ("\n");
        stdout.printf ("     filecollector --work-dir ./project \\\n");
        stdout.printf ("         --select-file a.txt --select-file b.txt \\\n");
        stdout.printf ("         --save my.project.fcol\n");
        stdout.printf ("\n");
        stdout.printf ("  4. "); stdout.printf (_("查看编排列表:")); stdout.printf ("\n");
        stdout.printf ("     filecollector --load my.project.fcol --list-items\n");
        stdout.printf ("\n");
        stdout.printf ("  5. "); stdout.printf (_("加载项目后打开 GUI 手动调整:")); stdout.printf ("\n");
        stdout.printf ("     filecollector --load my.project.fcol --gui\n");
        stdout.printf ("\n");
        stdout.printf ("  6. "); stdout.printf (_("用 CLI 参数初始化状态后打开 GUI:")); stdout.printf ("\n");
        stdout.printf ("     filecollector --work-dir ./project --select-file src/main.vala --gui\n");
        stdout.printf ("\n");
    }

    private bool apply_work_dir (string path) {
        var dir = File.new_for_path (path);
        if (!dir.query_exists ()) {
            stderr.printf (_("错误: 目录不存在: %s\n"), path);
            return false;
        }
        work_dir = dir;
        stdout.printf (_("✓ 工作目录已设置: %s\n"), path);
        return true;
    }

    private bool add_file (string path) {
        var file = File.new_for_path (path);
        if (!file.query_exists ()) {
            stderr.printf (_("错误: 文件不存在: %s\n"), path);
            return false;
        }
        var abs_path = file.get_path ();
        items.add (new ItemData ("file", abs_path, null, false));
        checked_paths.insert (abs_path, true);
        stdout.printf (_("✓ 已添加文件 [%d]: %s\n"), (int)items.length, abs_path);
        return true;
    }

    private void add_text (string text) {
        items.add (new ItemData ("text", null, text, false));
        stdout.printf (_("✓ 已添加文字 [%d]: %s\n"), (int)items.length, text);
    }

    private bool move_item (int from, int to) {
        if (from < 0 || from >= items.length) {
            stderr.printf (_("错误: 源索引 %d 超出范围 (0-%d)\n"), from, items.length - 1);
            return false;
        }
        if (to < 0 || to >= items.length) {
            stderr.printf (_("错误: 目标索引 %d 超出范围 (0-%d)\n"), to, items.length - 1);
            return false;
        }
        if (from == to) return true;
        var tmp = items.get (from);
        items.set (from, items.get (to));
        items.set (to, tmp);
        stdout.printf (_("✓ 已将项目从索引 %d 移动到 %d\n"), from, to);
        return true;
    }

    private bool remove_item (int index) {
        if (index < 0 || index >= items.length) {
            stderr.printf (_("错误: 索引 %d 超出范围 (0-%d)\n"), index, items.length - 1);
            return false;
        }
        var data = items.get (index);
        if (data.item_type == "file" && !data.force_absolute) {
            checked_paths.remove (data.file_path);
        }
        items.remove_index (index);
        stdout.printf (_("✓ 已删除索引 %d 处的项目\n"), index);
        return true;
    }

    private void clear_items () {
        items.remove_range (0, items.length);
        checked_paths.remove_all ();
        stdout.printf (_("✓ 已清空编排列表\n"));
    }

    private void list_items () {
        if (items.length == 0) {
            stdout.printf (_("编排列表为空\n"));
            return;
        }
        var dashes = new StringBuilder ();
        for (int j = 0; j < 60; j++) dashes.append_c('-');
        var dash_str = dashes.str;
        stdout.printf (_("当前编排列表 (%d 项):\n"), items.length);
        stdout.printf ("%s\n", dash_str);
        for (int i = 0; i < items.length; i++) {
            var data = items.get (i);
            if (data.item_type == "file") {
                stdout.printf ("  %d. [%s] %s\n", i, _("文件"), data.file_path);
            } else {
                var preview = data.content;
                if (preview.length > 60) preview = preview.substring (0, 60) + "...";
                stdout.printf ("  %d. [%s] %s\n", i, _("文字"), preview);
            }
        }
        stdout.printf ("%s\n", dash_str);
        stdout.printf (_("配置: 绝对路径=%s  头部=%s\n"),
                       use_absolute.to_string (), show_header.to_string ());
        if (work_dir != null) {
            stdout.printf (_("工作目录: %s\n"), work_dir.get_path ());
        }
    }

    private bool load_project (string path) {
        var file = File.new_for_path (path);
        if (!file.query_exists ()) {
            stderr.printf (_("错误: 项目文件不存在: %s\n"), path);
            return false;
        }

        try {
            string content;
            size_t len;
            FileUtils.get_contents (path, out content, out len);
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

            use_absolute = root.get_boolean_member_with_default ("use_absolute", false);
            show_header = root.get_boolean_member_with_default ("show_header", false);

            items.remove_range (0, items.length);
            checked_paths.remove_all ();

            var checked_arr = root.get_array_member ("checked_files");
            if (checked_arr != null) {
                for (int i = 0; i < checked_arr.get_length (); i++) {
                    var p = checked_arr.get_string_element (i);
                    checked_paths.insert (p, true);
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
                        items.add (new ItemData ("file", p, null, fa));
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

            stdout.printf (_("✓ 已从项目文件加载: %s (共 %d 项)\n"), path, items.length);
            return true;
        } catch (Error e) {
            stderr.printf (_("加载项目失败: %s\n"), e.message);
            return false;
        }
    }
}
