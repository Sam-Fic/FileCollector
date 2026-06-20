using Gee;

public class ItemData : GLib.Object {
    public string item_type { get; set; }
    public string? file_path { get; set; }
    public string? content { get; set; }
    public bool force_absolute { get; set; }
    public bool is_missing { get; set; }

    public ItemData (string type, string? path, string? content, bool force_abs, bool missing = false) {
        GLib.Object (
            item_type: type,
            file_path: path,
            content: content,
            force_absolute: force_abs,
            is_missing: missing
        );
    }
}
