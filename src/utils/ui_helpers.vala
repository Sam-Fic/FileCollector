using GLib;

// ─── UI 辅助方法 (纯函数, 无状态依赖) ────────────────────────────────

namespace UIHelpers {
    public static string format_size (int64 size) {
        if (size < 1024) return size.to_string () + " B";
        if (size < 1024 * 1024) return "%.1f KB".printf (size / 1024.0);
        if (size < 1024 * 1024 * 1024) return "%.1f MB".printf (size / 1024.0 / 1024.0);
        return "%.1f GB".printf (size / 1024.0 / 1024.0 / 1024.0);
    }

    // 按字节长度截断, 但不切断多字节 UTF-8 字符, 避免乱码
    public static string truncate_utf8 (string text, int max_bytes) {
        if (text.length <= max_bytes) return text;
        int cut = max_bytes;
        while (cut > 0 && !text[0:cut].validate (-1)) {
            cut--;
        }
        return text[0:cut];
    }

    public static string clean_ai_markdown (string raw) {
        string s = raw.strip ();
        if (s.has_prefix ("```markdown")) {
            s = s.substring (11).strip ();
        } else if (s.has_prefix ("```")) {
            s = s.substring (3).strip ();
        }
        if (s.has_suffix ("```")) {
            s = s.substring (0, s.length - 3).strip ();
        }
        return s;
    }

    public static string build_toc_prompt (string context) {
        return "你是一个高级软件架构师和文档专家。我将提供一个项目中的一系列文件路径及其开头部分的代码/内容摘要。\n" +
               "请你根据这些信息，为这些文件生成一份结构化的 Markdown 格式的「阅读指南与目录」，并包含「文件关联性分析」。\n" +
               "要求：\n" +
               "1. 使用 Markdown 语法。\n" +
               "2. 将文件按逻辑模块或功能进行分类（如：核心逻辑、配置文件、UI 组件、工具类等）。\n" +
               "3. 为每个文件提供一句话的简要说明（基于文件名和代码内容推断）。\n" +
               "4. 在「文件关联性分析」部分，简述这些文件是如何协同工作的，数据流或调用关系是怎样的。\n" +
               "5. 直接输出 Markdown 内容，不要包含任何额外的解释或前言后语。\n\n" +
               "以下是文件列表及摘要：\n\n" + context;
    }

    public static string build_toc_prompt_context (Gee.ArrayList<ItemData> items, File? work_dir) {
        var sb = new StringBuilder ();
        foreach (var item in items) {
            if (item.item_type == "file" && item.file_path != null) {
                string rel_path = item.file_path;
                if (work_dir != null && rel_path.has_prefix (work_dir.get_path () + "/")) {
                    rel_path = rel_path.substring (work_dir.get_path ().length + 1);
                }
                sb.append ("### ").append (rel_path).append ("\n");
                try {
                    var file = File.new_for_path (item.file_path);
                    var dis = new DataInputStream (file.read ());
                    string? line;
                    int count = 0;
                    while ((line = dis.read_line (null)) != null && count < 15) {
                        sb.append (line).append ("\n");
                        count++;
                    }
                } catch (Error e) {
                    sb.append (_("[无法读取文件内容]\n"));
                }
                sb.append ("\n");
            } else if (item.item_type == "text") {
                sb.append (_("### [自定义文本片段]\n"));
                string preview = item.content ?? "";
                if (preview.length > 200) preview = preview.substring (0, 200) + "...";
                sb.append (preview).append ("\n\n");
            }
        }
        return sb.str;
    }

    public static void show_file_in_folder (Gtk.Window parent, string path) {
        var file = File.new_for_path (path);
        if (!file.query_exists ()) return;

        File target = file;
        if (file.query_file_type (FileQueryInfoFlags.NONE) != FileType.DIRECTORY) {
            target = file.get_parent ();
            if (target == null) return;
        }

        try {
            Gtk.show_uri (parent, target.get_uri (), Gdk.CURRENT_TIME);
        } catch (Error e) {
            warning ("Failed to open folder: %s", e.message);
        }
    }
}
