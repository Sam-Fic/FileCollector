using Gee;

// 多格式导出服务:
//   - Markdown (.md)   : # 文件名 作 H1, ```lang ... ``` 包裹代码
//   - JSON (.json)     : 结构化数组, 含 path/content/language/status 等字段
//   - JSONL (.jsonl)   : 每行一个 JSON 对象, 便于流式 RAG 管道
//   - Jupyter (.ipynb) : text 项→markdown cell, 代码文件→code cell
//
// 所有格式共用 resolve_items() 一次性把 missing/binary/too_large 等情况归一化,
// 避免每种格式各自重复处理。preprocessed_content (VLM 转写后的 Markdown) 优先使用。
public class MultiFormatExporter : GLib.Object {

    private const int64 MAX_FILE_CONTENT_SIZE = 10 * 1024 * 1024;

    public enum ItemKind {
        OK,         // 文本内容已就绪, content 字段可用
        MISSING,    // 文件不存在
        BINARY,     // 检测到 NULL 字节, 视为二进制
        TOO_LARGE,  // 超过 MAX_FILE_CONTENT_SIZE
        READ_ERROR  // 读取/query 失败
    }

    public class ResolvedItem : GLib.Object {
        public ItemData source;
        public string display_path = "";
        public string? content = null;
        public string? error_message = null;
        public ItemKind kind = ItemKind.OK;
        public string language = "";

        public ResolvedItem (ItemData source) {
            this.source = source;
        }
    }

    // ─── 入口: Markdown ───────────────────────────────────────────────

    public static void export_markdown (
        string file_path,
        Gee.ArrayList<ItemData> items,
        bool use_absolute,
        bool show_header,
        File? work_dir
    ) throws Error {
        // 流式写入: 逐项解析并立即落盘, 不再把全部内容拼进一个 StringBuilder,
        // 峰值内存仅为单个文件内容, 大队列导出时主线程占用更平稳.
        DataOutputStream? dos = null;
        try {
            var file = File.new_for_path (file_path);
            dos = new DataOutputStream (file.replace (null, false, FileCreateFlags.NONE));

            if (show_header && work_dir != null) {
                dos.put_string (_("# Working directory: %s\n\n").printf (work_dir.get_path ()));
            }

            bool first = true;
            foreach (var data in items) {
                var ri = resolve_single_item (data, use_absolute, work_dir);
                if (!first) dos.put_string ("\n\n");
                first = false;

                if (ri.source.item_type == "text") {
                    dos.put_string (ri.content ?? "");
                    continue;
                }

                dos.put_string ("# %s\n\n".printf (ri.display_path));
                if (ri.kind == ItemKind.OK) {
                    dos.put_string ("```%s\n".printf (ri.language));
                    dos.put_string (ri.content ?? "");
                    if (!(ri.content ?? "").has_suffix ("\n")) dos.put_string ("\n");
                    dos.put_string ("```\n");
                } else {
                    dos.put_string ("```\n");
                    dos.put_string (ri.error_message ?? "");
                    dos.put_string ("\n```\n");
                }
            }
        } finally {
            if (dos != null) {
                try { dos.close (); } catch (Error e) {}
            }
        }
    }

    // ─── 入口: JSON ───────────────────────────────────────────────────

    public static void export_json (
        string file_path,
        Gee.ArrayList<ItemData> items,
        bool use_absolute,
        bool show_header,
        File? work_dir
    ) throws Error {
        // 逐项解析 (resolve_single_item) 直接写入 builder, 避免先 resolve_items 把所有
        // 内容额外持有一份再构建 JSON 树, 降低峰值内存.
        var builder = new Json.Builder ();
        builder.begin_object ();

        if (show_header && work_dir != null) {
            builder.set_member_name ("work_dir");
            builder.add_string_value (work_dir.get_path ());
        }
        builder.set_member_name ("generated_at");
        builder.add_string_value (new DateTime.now_local ().format_iso8601 ());
        builder.set_member_name ("items");
        builder.begin_array ();
        foreach (var data in items) {
            var ri = resolve_single_item (data, use_absolute, work_dir);
            append_item_object (builder, ri);
        }
        builder.end_array ();
        builder.end_object ();

        write_json_file (file_path, builder, true);
    }

    // ─── 入口: JSONL ──────────────────────────────────────────────────

    public static void export_jsonl (
        string file_path,
        Gee.ArrayList<ItemData> items,
        bool use_absolute,
        bool show_header,
        File? work_dir
    ) throws Error {
        // 流式写入: 每一项解析后立刻序列化为一行 JSON 落盘, 不再把所有行先攒进
        // 一个大 StringBuilder. 每行仍用一个 Json.Builder/Generator 序列化单个对象
        // (JSON 对象必须独立序列化), 但内存峰值仅为单行.
        DataOutputStream? dos = null;
        try {
            var file = File.new_for_path (file_path);
            dos = new DataOutputStream (file.replace (null, false, FileCreateFlags.NONE));

            foreach (var data in items) {
                var ri = resolve_single_item (data, use_absolute, work_dir);
                var builder = new Json.Builder ();
                append_item_object (builder, ri);

                var gen = new Json.Generator ();
                gen.set_root (builder.get_root ());
                gen.pretty = false;
                dos.put_string (gen.to_data (null));
                dos.put_byte ('\n');
            }
        } finally {
            if (dos != null) {
                try { dos.close (); } catch (Error e) {}
            }
        }
    }

    // ─── 入口: Jupyter Notebook (.ipynb) ──────────────────────────────

    public static void export_ipynb (
        string file_path,
        Gee.ArrayList<ItemData> items,
        bool use_absolute,
        bool show_header,
        File? work_dir
    ) throws Error {
        // 逐项解析 (resolve_single_item) 直接构建 cells, 避免先 resolve_items 把所有
        // 内容额外持有一份. ipynb 本身是单一 JSON 结构, 仍需整体持有, 但省去了重复存储.
        var builder = new Json.Builder ();
        builder.begin_object ();

        builder.set_member_name ("nbformat");
        builder.add_int_value (4);
        builder.set_member_name ("nbformat_minor");
        builder.add_int_value (5);

        builder.set_member_name ("metadata");
        builder.begin_object ();
        builder.set_member_name ("kernelspec");
        builder.begin_object ();
        builder.set_member_name ("display_name"); builder.add_string_value ("Python 3");
        builder.set_member_name ("language");     builder.add_string_value ("python");
        builder.set_member_name ("name");         builder.add_string_value ("python3");
        builder.end_object ();
        builder.set_member_name ("language_info");
        builder.begin_object ();
        builder.set_member_name ("name"); builder.add_string_value ("python");
        builder.end_object ();
        builder.end_object ();

        builder.set_member_name ("cells");
        builder.begin_array ();

        // 头部 markdown cell: 工作目录信息
        if (show_header && work_dir != null) {
            builder.begin_object ();
            builder.set_member_name ("cell_type"); builder.add_string_value ("markdown");
            builder.set_member_name ("metadata");  builder.begin_object (); builder.end_object ();
            builder.set_member_name ("source");
            builder.begin_array ();
            add_source_lines (builder, "# FileCollector Export\n");
            add_source_lines (builder, "\n");
            add_source_lines (builder, _("Working directory: `%s`\n").printf (work_dir.get_path ()));
            builder.end_array ();
            builder.end_object ();
        }

        foreach (var data in items) {
            var ri = resolve_single_item (data, use_absolute, work_dir);
            bool as_code = (ri.source.item_type == "file")
                           && ri.kind == ItemKind.OK
                           && is_code_language (ri.language);

            builder.begin_object ();
            builder.set_member_name ("cell_type");
            builder.add_string_value (as_code ? "code" : "markdown");

            if (as_code) {
                builder.set_member_name ("execution_count");
                builder.add_null_value ();
                builder.set_member_name ("outputs");
                builder.begin_array ();
                builder.end_array ();
            }

            builder.set_member_name ("metadata");
            builder.begin_object (); builder.end_object ();

            builder.set_member_name ("source");
            builder.begin_array ();

            if (ri.source.item_type == "text") {
                add_source_lines (builder, ri.content ?? "");
            } else if (ri.kind == ItemKind.OK) {
                add_source_lines (builder, "# %s\n\n".printf (ri.display_path));
                if (as_code) {
                    add_source_lines (builder, ri.content ?? "");
                } else if (ri.language == "md") {
                    add_source_lines (builder, ri.content ?? "");
                } else {
                    add_source_lines (builder, "```%s\n".printf (ri.language));
                    add_source_lines (builder, ri.content ?? "");
                    if (!(ri.content ?? "").has_suffix ("\n")) {
                        add_source_lines (builder, "\n");
                    }
                    add_source_lines (builder, "```\n");
                }
            } else {
                add_source_lines (builder, "# %s\n\n".printf (ri.display_path));
                add_source_lines (builder, "> %s\n".printf (ri.error_message ?? ""));
            }

            builder.end_array ();
            builder.end_object ();
        }

        builder.end_array ();
        builder.end_object ();

        write_json_file (file_path, builder, true);
    }

    // ─── 共用解析 ─────────────────────────────────────────────────────

    // 解析单个 item: 归一化 missing/binary/too_large/read_error 等情况, 返回 ResolvedItem.
    // 抽出来供各 export 函数逐项流式调用, 避免一次性把全部文件内容读入内存.
    public static ResolvedItem resolve_single_item (
        ItemData data,
        bool use_absolute,
        File? work_dir
    ) {
        var ri = new ResolvedItem (data);

        if (data.item_type == "text") {
            ri.content = data.content ?? "";
            ri.kind = ItemKind.OK;
            return ri;
        }

        // file 项
        ri.display_path = compute_display_path (
            data.file_path, data.force_absolute, use_absolute, work_dir
        );
        ri.language = extract_language (data.file_path);

        var f = File.new_for_path (data.file_path);
        if (!f.query_exists () || data.is_missing) {
            ri.kind = ItemKind.MISSING;
            ri.error_message = _("[Missing file: %s]").printf (data.file_path);
            return ri;
        }

        if (data.preprocessed_content != null && data.preprocessed_content.length > 0) {
            ri.kind = ItemKind.OK;
            ri.content = data.preprocessed_content;
            return ri;
        }

        int64 file_size = 0;
        try {
            var info = f.query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
            file_size = info.get_size ();
        } catch (Error e) {
            ri.kind = ItemKind.READ_ERROR;
            ri.error_message = _("[Unable to get file info: %s]").printf (e.message);
            return ri;
        }
        if (file_size > MAX_FILE_CONTENT_SIZE) {
            ri.kind = ItemKind.TOO_LARGE;
            ri.error_message = _("[File too large (%s), content reading skipped]").printf (UIHelpers.format_size (file_size));
            return ri;
        }

        FileInputStream? fis = null;
        try {
            fis = f.read ();
            const int PEEK_SIZE = 8192;
            uint8[] head_buf = new uint8[PEEK_SIZE];
            var peek_bytes = fis.read_bytes (PEEK_SIZE);
            unowned uint8[] peek_data = peek_bytes.get_data ();
            size_t head_read = peek_data.length;
            Memory.copy (head_buf, peek_data, head_read);

            bool is_binary = false;
            for (size_t j = 0; j < head_read; j++) {
                if (head_buf[j] == 0) {
                    is_binary = true;
                    break;
                }
            }
            if (is_binary) {
                ri.kind = ItemKind.BINARY;
                ri.error_message = _("[Binary file detected: text content reading skipped]");
                return ri;
            }

            var sb = new StringBuilder ();
            sb.append_len ((string) head_buf[0:head_read], (ssize_t) head_read);
            size_t remaining = (size_t) file_size - head_read;
            uint8[] chunk_buf = new uint8[8192];
            while (remaining > 0) {
                size_t to_read = size_t.min (8192, remaining);
                ssize_t n = fis.read (chunk_buf[0:to_read]);
                if (n <= 0) break;
                sb.append_len ((string) chunk_buf[0:n], (ssize_t) n);
                remaining -= (size_t) n;
            }
            ri.kind = ItemKind.OK;
            ri.content = sb.str;
        } catch (Error e) {
            ri.kind = ItemKind.READ_ERROR;
            ri.error_message = _("[Failed to read file: %s]").printf (e.message);
        } finally {
            if (fis != null) {
                try { fis.close (); } catch (Error e) {}
            }
        }
        return ri;
    }

    // 保留的批量解析入口: 复用 resolve_single_item, 行为不变.
    // (当前各 export 已改为逐项流式解析, 此方法仅作为兼容 API 保留.)
    public static Gee.ArrayList<ResolvedItem> resolve_items (
        Gee.ArrayList<ItemData> items,
        bool use_absolute,
        File? work_dir
    ) {
        var result = new Gee.ArrayList<ResolvedItem> ();
        foreach (var data in items) {
            result.add (resolve_single_item (data, use_absolute, work_dir));
        }
        return result;
    }

    // ─── helpers ──────────────────────────────────────────────────────

    private static void append_item_object (Json.Builder builder, ResolvedItem ri) {
        builder.begin_object ();
        if (ri.source.item_type == "text") {
            builder.set_member_name ("type");     builder.add_string_value ("text");
            builder.set_member_name ("content");  builder.add_string_value (ri.content ?? "");
        } else {
            builder.set_member_name ("type");     builder.add_string_value ("file");
            builder.set_member_name ("path");     builder.add_string_value (ri.display_path);
            builder.set_member_name ("language"); builder.add_string_value (ri.language);
            builder.set_member_name ("status");   builder.add_string_value (kind_to_status (ri.kind));
            if (ri.kind == ItemKind.OK) {
                builder.set_member_name ("content");
                builder.add_string_value (ri.content ?? "");
            } else if (ri.error_message != null) {
                builder.set_member_name ("note");
                builder.add_string_value (ri.error_message);
            }
        }
        builder.end_object ();
    }

    private static void add_source_lines (Json.Builder builder, string text) {
        if (text.length == 0) return;
        string[] parts = text.split ("\n", -1);
        for (int i = 0; i < parts.length - 1; i++) {
            builder.add_string_value (parts[i] + "\n");
        }
        if (parts[parts.length - 1].length > 0) {
            builder.add_string_value (parts[parts.length - 1]);
        }
    }

    private static string kind_to_status (ItemKind k) {
        switch (k) {
            case ItemKind.OK:         return "ok";
            case ItemKind.MISSING:    return "missing";
            case ItemKind.BINARY:     return "binary";
            case ItemKind.TOO_LARGE:  return "too_large";
            case ItemKind.READ_ERROR: return "read_error";
        }
        return "unknown";
    }

    // 经典编程语言 → code cell; 文档/数据/配置类 → markdown cell
    private static bool is_code_language (string lang) {
        switch (lang) {
            case "py":     case "python":
            case "js":     case "javascript": case "mjs":
            case "ts":     case "typescript":
            case "vala":
            case "c":      case "h":
            case "cpp":    case "hpp": case "cc": case "cxx":
            case "rs":     case "rust":
            case "go":
            case "java":
            case "kt":     case "kts":
            case "swift":
            case "rb":     case "ruby":
            case "php":
            case "sh":     case "bash": case "zsh":
            case "sql":
            case "r":
            case "lua":
            case "pl":     case "perl":
            case "scala":
            case "hs":     case "haskell":
            case "clj":
            case "ex":     case "exs":
            case "jl":
            case "dart":
            case "cs":     case "csharp":
            case "fs":
            case "vim":
            case "ps1":
                return true;
            default:
                return false;
        }
    }

    private static string compute_display_path (string file_path, bool force_absolute,
                                                bool use_absolute, File? work_dir) {
        if (force_absolute || use_absolute || work_dir == null) {
            return file_path;
        }
        var wd_path = work_dir.get_path () + "/";
        if (file_path.has_prefix (wd_path)) {
            return file_path.substring (wd_path.length);
        }
        return file_path;
    }

    private static string extract_language (string path) {
        var lower = path.down ();
        int dot = lower.last_index_of (".");
        if (dot < 0 || dot == lower.length - 1) return "";
        return lower.substring (dot + 1);
    }

    private static void write_text_file (string path, string content) throws Error {
        var file = File.new_for_path (path);
        DataOutputStream? dos = null;
        try {
            var os = file.replace (null, false, FileCreateFlags.NONE);
            dos = new DataOutputStream (os);
            dos.put_string (content);
        } finally {
            if (dos != null) {
                try { dos.close (); } catch (Error e) {}
            }
        }
    }

    private static void write_json_file (string path, Json.Builder builder, bool pretty) throws Error {
        var gen = new Json.Generator ();
        gen.set_root (builder.get_root ());
        gen.pretty = pretty;
        if (pretty) gen.indent = 2;
        gen.to_file (path);
    }
}
