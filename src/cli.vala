using GLib;

public class CliController : GLib.Object {
    private File? work_dir = null;
    private GenericArray<ItemData> items;
    private bool use_absolute = false;
    private bool show_header = false;
    private string? export_path = null;
    private string? save_path = null;

    private HashTable<string, bool> checked_paths;
    private GenericArray<string> common_phrases;

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

    public int run (string[] args) {
        int i = 1;
        while (i < args.length) {
            string arg = args[i];

            if (arg == "--help" || arg == "-h") {
                print_help ();
                return 0;
            } else if (arg == "--work-dir") {
                i++;
                if (i >= args.length) { print_missing_arg (arg); return 1; }
                if (!set_work_dir (args[i])) return 1;
            } else if (arg == "--select-file") {
                i++;
                if (i >= args.length) { print_missing_arg (arg); return 1; }
                if (!add_file (args[i])) return 1;
            } else if (arg == "--add-text") {
                i++;
                if (i >= args.length) { print_missing_arg (arg); return 1; }
                add_text (args[i]);
            } else if (arg == "--move") {
                i++;
                if (i + 1 >= args.length) { print_missing_arg (arg); return 1; }
                int from = int.parse (args[i]);
                int to = int.parse (args[i + 1]);
                if (!move_item (from, to)) return 1;
                i++;
            } else if (arg == "--remove") {
                i++;
                if (i >= args.length) { print_missing_arg (arg); return 1; }
                if (!remove_item (int.parse (args[i]))) return 1;
            } else if (arg == "--clear") {
                clear_items ();
            } else if (arg == "--absolute") {
                use_absolute = true;
            } else if (arg == "--header") {
                show_header = true;
            } else if (arg == "--export") {
                i++;
                if (i >= args.length) { print_missing_arg (arg); return 1; }
                export_path = args[i];
            } else if (arg == "--load") {
                i++;
                if (i >= args.length) { print_missing_arg (arg); return 1; }
                if (!load_project (args[i])) return 1;
            } else if (arg == "--save") {
                i++;
                if (i >= args.length) { print_missing_arg (arg); return 1; }
                save_path = args[i];
            } else if (arg == "--list-items") {
                list_items ();
            } else {
                stderr.printf ("错误: 未知参数: %s\n", arg);
                stderr.printf ("使用 --help 查看帮助信息\n");
                return 1;
            }

            i++;
        }

        if (save_path != null) {
            try {
                ProjectManager.write_project_file (
                    save_path, work_dir, use_absolute, show_header,
                    items, checked_paths, common_phrases
                );
                stdout.printf ("项目已保存到: %s\n", save_path);
            } catch (Error e) {
                stderr.printf ("保存项目失败: %s\n", e.message);
                return 1;
            }
        }

        if (export_path != null) {
            if (items.length == 0) {
                stderr.printf ("错误: 编排列表为空，无法导出\n");
                return 1;
            }
            try {
                FileGenerator.generate_file (export_path, items, use_absolute, show_header, work_dir);
                stdout.printf ("合并文本已导出到: %s\n", export_path);
            } catch (Error e) {
                stderr.printf ("导出失败: %s\n", e.message);
                return 1;
            }
        }

        return 0;
    }

    private void print_help () {
        stdout.printf ("""
FileCollector %s — CLI 命令行模式

用法: filecollector [选项...]

工作目录:
  --work-dir DIR           设置工作目录

文件选择:
  --select-file PATH       添加文件到编排列表 (可多次使用)
  --add-text "TEXT"        添加自定义文字 (可多次使用)

编排调整:
  --move FROM TO           将索引 FROM 处的项目移动到索引 TO
  --remove INDEX           删除索引 INDEX 处的项目
  --clear                  清空编排列表
  --list-items             列出当前编排列表

导出设置:
  --export PATH            导出合并文本到 PATH
  --absolute               使用绝对路径
  --header                 添加头部信息 (工作目录路径)

项目文件:
  --load FILE              从项目文件加载状态
  --save FILE              将当前状态保存到项目文件

其他:
  --help, -h               显示此帮助信息

示例:
  1. 构建并导出:
     filecollector --work-dir ./project \\
         --select-file src/main.vala \\
         --select-file src/utils/helper.vala \\
         --add-text "=== 配置文件 ===" \\
         --select-file config.ini \\
         --move 3 2 \\
         --export output.txt

  2. 从项目文件导出:
     filecollector --load my.project.json --export output.txt

  3. 构建并保存项目:
     filecollector --work-dir ./project \\
         --select-file a.txt --select-file b.txt \\
         --save my.project.json

  4. 查看编排列表:
     filecollector --load my.project.json --list-items
""", Config.VERSION);
    }

    private void print_missing_arg (string arg) {
        stderr.printf ("错误: 参数 '%s' 缺少必要的值\n", arg);
    }

    private bool set_work_dir (string path) {
        var dir = File.new_for_path (path);
        if (!dir.query_exists ()) {
            stderr.printf ("错误: 目录不存在: %s\n", path);
            return false;
        }
        work_dir = dir;
        stdout.printf ("✓ 工作目录已设置: %s\n", path);
        return true;
    }

    private bool add_file (string path) {
        var file = File.new_for_path (path);
        if (!file.query_exists ()) {
            stderr.printf ("错误: 文件不存在: %s\n", path);
            return false;
        }
        var abs_path = file.get_path ();
        items.add (new ItemData ("file", abs_path, null, false));
        checked_paths.insert (abs_path, true);
        stdout.printf ("✓ 已添加文件 [%d]: %s\n", (int)items.length, abs_path);
        return true;
    }

    private void add_text (string text) {
        items.add (new ItemData ("text", null, text, false));
        stdout.printf ("✓ 已添加文字 [%d]: %s\n", (int)items.length, text);
    }

    private bool move_item (int from, int to) {
        if (from < 0 || from >= items.length) {
            stderr.printf ("错误: 源索引 %d 超出范围 (0-%d)\n", from, items.length - 1);
            return false;
        }
        if (to < 0 || to >= items.length) {
            stderr.printf ("错误: 目标索引 %d 超出范围 (0-%d)\n", to, items.length - 1);
            return false;
        }
        if (from == to) return true;
        var tmp = items.get (from);
        items.set (from, items.get (to));
        items.set (to, tmp);
        stdout.printf ("✓ 已将项目从索引 %d 移动到 %d\n", from, to);
        return true;
    }

    private bool remove_item (int index) {
        if (index < 0 || index >= items.length) {
            stderr.printf ("错误: 索引 %d 超出范围 (0-%d)\n", index, items.length - 1);
            return false;
        }
        var data = items.get (index);
        if (data.item_type == "file" && !data.force_absolute) {
            checked_paths.remove (data.file_path);
        }
        items.remove_index (index);
        stdout.printf ("✓ 已删除索引 %d 处的项目\n", index);
        return true;
    }

    private void clear_items () {
        items.remove_range (0, items.length);
        checked_paths.remove_all ();
        stdout.printf ("✓ 已清空编排列表\n");
    }

    private void list_items () {
        if (items.length == 0) {
            stdout.printf ("编排列表为空\n");
            return;
        }
        var dashes = new StringBuilder ();
        for (int j = 0; j < 60; j++) dashes.append_c('-');
        var dash_str = dashes.str;
        stdout.printf ("当前编排列表 (%d 项):\n", items.length);
        stdout.printf ("%s\n", dash_str);
        for (int i = 0; i < items.length; i++) {
            var data = items.get (i);
            if (data.item_type == "file") {
                stdout.printf ("  %d. [文件] %s\n", i, data.file_path);
            } else {
                var preview = data.content;
                if (preview.length > 60) preview = preview.substring (0, 60) + "...";
                stdout.printf ("  %d. [文字] %s\n", i, preview);
            }
        }
        stdout.printf ("%s\n", dash_str);
        stdout.printf ("配置: 绝对路径=%s  头部=%s\n",
                       use_absolute.to_string (), show_header.to_string ());
        if (work_dir != null) {
            stdout.printf ("工作目录: %s\n", work_dir.get_path ());
        }
    }

    private bool load_project (string path) {
        var file = File.new_for_path (path);
        if (!file.query_exists ()) {
            stderr.printf ("错误: 项目文件不存在: %s\n", path);
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

            stdout.printf ("✓ 已从项目文件加载: %s (共 %d 项)\n", path, items.length);
            return true;
        } catch (Error e) {
            stderr.printf ("加载项目失败: %s\n", e.message);
            return false;
        }
    }
}