using Gee;

public enum PreprocessStatus {
    NONE,
    PENDING,
    CHECKING,    // 正在检查本地缓存, 区别于"真正在调用 VLM 处理中"
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

    private static string[] DOCUMENT_EXTENSIONS = {
        ".pdf", ".docx", ".pptx", ".doc", ".ppt",
        ".xlsx", ".xls", ".ods", ".odt", ".odp", ".rtf", ".wps"
    };

    private static string[] IMAGE_EXTENSIONS = {
        ".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tiff", ".tif"
    };

    public ItemData (string type, string? path, string? content, bool force_abs, bool missing = false) {
        GLib.Object (
            item_type: type,
            file_path: path,
            content: content,
            force_absolute: force_abs,
            is_missing: missing
        );
    }

    public bool is_document_target () {
        if (item_type != "file" || file_path == null) return false;
        string lower = file_path.down ();
        foreach (var ext in DOCUMENT_EXTENSIONS) {
            if (lower.has_suffix (ext)) return true;
        }
        return false;
    }

    public bool is_image_target () {
        if (item_type != "file" || file_path == null) return false;
        string lower = file_path.down ();
        foreach (var ext in IMAGE_EXTENSIONS) {
            if (lower.has_suffix (ext)) return true;
        }
        return false;
    }

    public bool is_binary_target () {
        return is_document_target () || is_image_target ();
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
