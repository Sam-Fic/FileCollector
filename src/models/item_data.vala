public class ItemData : GLib.Object {
    public string item_type { get; set; }
    public string? file_path { get; set; }
    public string? content { get; set; }
    public bool force_absolute { get; set; }

    public ItemData (string type, string? path, string? content, bool force_abs) {
        GLib.Object (
            item_type: type,
            file_path: path,
            content: content,
            force_absolute: force_abs
        );
    }
}
