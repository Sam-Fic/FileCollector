using Gee;

public enum PreprocessStatus {
    NONE,
    PENDING,
    CHECKING,    // 正在检查本地缓存, 区别于_("Actually invoking VLM for processing")
    PROCESSING,
    COMPLETED,
    FAILED
}

public class ItemData : GLib.Object {
    public string item_type { get; set; }
    public string? file_path { get; set; }
    public string? content { get; set; }
    public bool force_absolute { get; set; }
    public bool is_missing { get; set; }
    public PreprocessStatus preprocess_status { get; set; default = PreprocessStatus.NONE; }
    public string? preprocessed_content { get; set; }
    public bool from_cache { get; set; default = false; }
    public int start_line { get; set; default = 0; }
    public int end_line { get; set; default = 0; }
    // 文件被外部进程修改(例如用户切回 IDE 保存代码)时由 FileWatcherService 标记.
    // notify["is-externally-modified"] 信号触发 QueueListFactory 刷新"⚠ 已修改"徽标.
    public bool is_externally_modified { get; set; default = false; }

    private static string[] DOCUMENT_EXTENSIONS = {
        ".pdf", ".docx", ".pptx", ".doc", ".ppt",
        ".xlsx", ".xls", ".ods", ".odt", ".odp", ".rtf", ".wps"
    };

    private static string[] IMAGE_EXTENSIONS = {
        ".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tiff", ".tif"
    };

    public int cached_tokens { get; set; default = 0; }

    public ItemData (string type, string? path, string? content, bool force_abs, bool missing = false) {
        GLib.Object (
            item_type: type,
            file_path: path,
            content: content,
            force_absolute: force_abs,
            is_missing: missing
        );
            // preprocessed_content 赋值时自动刷新 cached_tokens, 避免遗漏调用点导致估算为 0.
        // 估算改为合并到空闲回调: 批量赋值时 (如一次导入数百文件 / VLM 批量完成) 不会
        // 每个文件都同步逐字符遍历, 而是在空闲时统一重算一次, 避免主线程被 token 估算阻塞.
        notify["preprocessed-content"].connect (() => schedule_token_stats ());
        schedule_token_stats ();
    }

    // 立即重算 token (供显式刷新点调用, 如编辑确认 / 批量导入后)
    public void update_token_stats () {
        string text = get_effective_content ();
        cached_tokens = TokenEstimator.estimate_tokens_fast (text);
    }

    private uint token_stats_source = 0;
    private void schedule_token_stats () {
        if (token_stats_source != 0) return;
        token_stats_source = GLib.Idle.add (() => {
            token_stats_source = 0;
            string text = get_effective_content ();
            cached_tokens = TokenEstimator.estimate_tokens_fast (text);
            return Source.REMOVE;
        });
    }

    ~ItemData () {
        // 析构时取消挂起的 Idle source, 避免回调触发时访问已释放的对象
        if (token_stats_source != 0) {
            GLib.Source.remove (token_stats_source);
            token_stats_source = 0;
        }
    }

    public string get_effective_content () {
        if (preprocessed_content != null && preprocessed_content.length > 0) return preprocessed_content;
        if (content != null && content.length > 0) return content;
        return "";
    }

    public bool is_snippet () {
        return item_type == "file" && start_line > 0 && end_line > 0;
    }

    public static bool is_document_file (string path) {
        string lower = path.down ();
        foreach (var ext in DOCUMENT_EXTENSIONS) {
            if (lower.has_suffix (ext)) return true;
        }
        return false;
    }

    public static bool is_image_file (string path) {
        string lower = path.down ();
        foreach (var ext in IMAGE_EXTENSIONS) {
            if (lower.has_suffix (ext)) return true;
        }
        return false;
    }

    public bool is_document_target () {
        if (item_type != "file" || file_path == null) return false;
        return is_document_file (file_path);
    }

    public bool is_image_target () {
        if (item_type != "file" || file_path == null) return false;
        return is_image_file (file_path);
    }

    public bool is_binary_target () {
        return is_document_target () || is_image_target ();
    }

    // 用户可配置的"允许被多模态 AI 转换的扩展名"判断;
    // 传入空数组相当于不允许任何文件被转换.
    public bool is_allowed_binary_target (string[] allowed_extensions) {
        if (item_type != "file" || file_path == null) return false;
        if (allowed_extensions.length == 0) return false;
        string lower = file_path.down ();
        foreach (var ext in allowed_extensions) {
            if (ext.length == 0) continue;
            string e = ext.down ();
            // 兼容用户输入 ".pdf" 或 "pdf", 没有前导点的自动补上
            if (!e.has_prefix (".")) e = "." + e;
            if (lower.has_suffix (e)) return true;
        }
        return false;
    }

    public string get_image_mime_type () {
        if (file_path == null) return "image/png";
        string lower = file_path.down ();
        if (lower.has_suffix (".jpg") || lower.has_suffix (".jpeg")) return "image/jpeg";
        if (lower.has_suffix (".webp")) return "image/webp";
        if (lower.has_suffix (".bmp")) return "image/bmp";
        if (lower.has_suffix (".tiff") || lower.has_suffix (".tif")) return "image/tiff";
        return "image/png";
    }
}
