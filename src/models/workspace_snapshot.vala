using Gee;

// 工作区快照：深拷贝 AppState 的完整业务状态，便于在不同上下文组之间快速切换。
// 仅保存可序列化的"编排状态"，不持有 UI 引用 / 后台线程句柄。
public class WorkspaceSnapshot : GLib.Object {
    public string id { get; set; }
    public string name { get; set; }
    public int64 created_at { get; set; }

    // 侧栏显示用的图标 (Adwaita symbolic 图标名), 纯展示属性, 不写回 AppState
    public string icon_name { get; set; default = "view-grid-symbolic"; }

    public File? work_dir { get; set; }
    public bool use_absolute { get; set; }
    public bool show_header { get; set; }

    // 深拷贝后的编排队列（快照独立拥有，不受后续编辑影响）
    public Gee.ArrayList<ItemData> items { get; set; }
    public Gee.HashSet<string> checked_paths { get; set; }
    public Gee.HashSet<string> checked_dirs { get; set; }
    public Gee.ArrayList<string> common_phrases { get; set; }

    // 当前状态里哪些 UI 模式处于激活（用于切回时恢复），可选
    public string ai_mode { get; set; }
    public string ai_file_extension { get; set; }
    public string ai_file_label { get; set; }
    public int ai_max_files { get; set; }

    private static int id_counter = 0;

    public WorkspaceSnapshot () {
        Object ();
        items = new Gee.ArrayList<ItemData> ();
        checked_paths = new Gee.HashSet<string> ();
        checked_dirs = new Gee.HashSet<string> ();
        common_phrases = new Gee.ArrayList<string> ();
        created_at = (int64) GLib.get_real_time ();
        id = "snap-%lld-%d".printf (created_at, id_counter++);
    }

    // 从 AppState 深拷贝当前状态
    public static WorkspaceSnapshot from_app_state (AppState s, string snap_name) {
        var snap = new WorkspaceSnapshot ();
        snap.name = snap_name;
        snap.icon_name = "view-grid-symbolic";
        snap.work_dir = s.work_dir;
        snap.use_absolute = s.use_absolute;
        snap.show_header = s.show_header;

        foreach (var it in s.items) {
            snap.items.add (new ItemData (
                it.item_type, it.file_path, it.content, it.force_absolute, it.is_missing));
            // 复制关键标量字段
            var copy = snap.items.get (snap.items.size - 1);
            copy.preprocessed_content = it.preprocessed_content;
            copy.start_line = it.start_line;
            copy.end_line = it.end_line;
        }

        foreach (var p in s.check_model.checked_files) snap.checked_paths.add (p);
        foreach (var d in s.check_model.checked_dirs) snap.checked_dirs.add (d);
        foreach (var ph in s.common_phrases) snap.common_phrases.add (ph);

        snap.ai_mode = s.ai_mode;
        snap.ai_file_extension = s.ai_file_extension;
        snap.ai_file_label = s.ai_file_label;
        snap.ai_max_files = s.ai_max_files;
        return snap;
    }

    // 把快照状态写回 AppState（复用 replace_from）
    public void apply_to (AppState s) {
        var cloned_items = new Gee.ArrayList<ItemData> ();
        foreach (var it in items) {
            cloned_items.add (new ItemData (
                it.item_type, it.file_path, it.content, it.force_absolute, it.is_missing));
            var copy = cloned_items.get (cloned_items.size - 1);
            copy.preprocessed_content = it.preprocessed_content;
            copy.start_line = it.start_line;
            copy.end_line = it.end_line;
        }
        s.replace_from (
            work_dir, use_absolute, show_header,
            cloned_items, checked_paths, checked_dirs, common_phrases);
    }

    // 深拷贝（用于重命名前的复制等场景）
    public WorkspaceSnapshot clone () {
        var snap = new WorkspaceSnapshot ();
        snap.name = name;
        snap.icon_name = icon_name;
        snap.work_dir = work_dir;
        snap.use_absolute = use_absolute;
        snap.show_header = show_header;
        foreach (var it in items) {
            var c = new ItemData (it.item_type, it.file_path, it.content, it.force_absolute, it.is_missing);
            c.preprocessed_content = it.preprocessed_content;
            c.start_line = it.start_line;
            c.end_line = it.end_line;
            snap.items.add (c);
        }
        foreach (var p in checked_paths) snap.checked_paths.add (p);
        foreach (var d in checked_dirs) snap.checked_dirs.add (d);
        foreach (var ph in common_phrases) snap.common_phrases.add (ph);
        snap.ai_mode = ai_mode;
        snap.ai_file_extension = ai_file_extension;
        snap.ai_file_label = ai_file_label;
        snap.ai_max_files = ai_max_files;
        return snap;
    }
}
