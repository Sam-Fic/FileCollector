using Gee;

// 单一真相源 (Single Source of Truth)
// 持有 FileCollector 的核心业务状态，并通过信号通知 View/Controller 变更。
public class AppState : GLib.Object {
    // 内部可变列表: 外部代码应优先使用 add_item/remove_item_at 等方法修改,
    // 这些方法会自动触发 items_changed 信号.
    // 若直接修改 items (如 items.add/remove_at), 必须手动调用 items_changed() 通知 UI.
    public Gee.ArrayList<ItemData> items { get; private set; }
    public CheckStateModel check_model { get; private set; }
    public Gee.ArrayList<string> common_phrases { get; private set; }

    // 工作区快照列表：多组暂留的编排状态，支持快速切换 / 合并导出
    public Gee.ArrayList<WorkspaceSnapshot> snapshots { get; private set; }

    public File? work_dir { get; set; }
    public bool use_absolute { get; set; }
    public bool show_header { get; set; }
    public string? project_file { get; set; }

    // 应用级生命周期 / 取消语义: 供窗口与各子控制器/面板 (Git 历史、目录树、预览) 共享.
    // 原分散在 FileCollectorWindow 的 private 字段, 抽出子模块后为避免暴露窗口内部而下沉至此.
    public Gee.ArrayList<GLib.Thread<void*>> bg_threads { get; private set; }
    public bool window_closing { get; set; }
    public GLib.Cancellable? app_cancellable { get; private set; }

    // AI 配置状态 (未来可进一步拆分，但目前与 AppState 生命周期一致)
    public string ai_mode { get; set; }
    public string ai_file_extension { get; set; }
    public string ai_file_label { get; set; }
    public int ai_max_files { get; set; }

    public signal void items_changed ();
    public signal void state_changed ();
    public signal void snapshots_changed ();

    public AppState () {
        items = new Gee.ArrayList<ItemData> ();
        check_model = new CheckStateModel ();
        common_phrases = new Gee.ArrayList<string> ();
        snapshots = new Gee.ArrayList<WorkspaceSnapshot> ();
        bg_threads = new Gee.ArrayList<GLib.Thread<void*>> ();
        app_cancellable = new GLib.Cancellable ();
        window_closing = false;
        ai_mode = "default";
        ai_file_extension = "";
        ai_file_label = _("File");
        ai_max_files = 50;
    }

    // ─── 队列操作 ────────────────────────────────────────────────────────

    public void add_item (ItemData item, int index = -1) {
        if (index < 0 || index >= items.size) {
            items.add (item);
        } else {
            items.insert (index, item);
        }
        items_changed ();
    }

    public void add_file (string path, int index = -1) {
        add_item (new ItemData ("file", path, null, false), index);
    }

    public void add_text (string text, int index = -1) {
        add_item (new ItemData ("text", null, text, false), index);
    }

    public bool remove_item_at (int index) {
        if (index < 0 || index >= items.size) return false;
        var data = items.get (index);
        if (data.item_type == "file" && !data.force_absolute && data.file_path != null) {
            check_model.remove_files ({ data.file_path });
        }
        items.remove_at (index);
        items_changed ();
        return true;
    }

    public bool move_item (int from, int to) {
        if (from < 0 || from >= items.size) return false;
        if (to < 0 || to >= items.size) return false;
        if (from == to) return true;
        var tmp = items.remove_at (from);
        items.insert (to, tmp);
        items_changed ();
        return true;
    }

    public void clear_items () {
        items.clear ();
        check_model.clear ();
        items_changed ();
        state_changed ();
    }

    // ─── 勾选路径 ────────────────────────────────────────────────────────

    public void add_checked_path (string path) {
        check_model.add_files ({ path });
    }

    public void remove_checked_path (string path) {
        check_model.remove_files ({ path });
    }

    // ─── 整体状态替换 ────────────────────────────────────────────────────

    public void reset () {
        items.clear ();
        check_model.clear ();
        work_dir = null;
        use_absolute = false;
        show_header = false;
        project_file = null;
        snapshots.clear ();
        items_changed ();
        state_changed ();
        snapshots_changed ();
    }

    public void replace_from (
        File? new_work_dir,
        bool new_use_absolute,
        bool new_show_header,
        Gee.ArrayList<ItemData> new_items,
        Gee.HashSet<string> new_checked_paths,
        Gee.HashSet<string>? new_checked_dirs,
        Gee.ArrayList<string> new_common_phrases
    ) {
        work_dir = new_work_dir;
        use_absolute = new_use_absolute;
        show_header = new_show_header;

        items.clear ();
        for (int i = 0; i < new_items.size; i++) {
            var it = new_items.get (i);
            items.add (new ItemData (it.item_type, it.file_path, it.content, it.force_absolute, it.is_missing));
        }

        check_model.replace_from (new_checked_paths, new_checked_dirs);

        common_phrases.clear ();
        for (int i = 0; i < new_common_phrases.size; i++) {
            common_phrases.add (new_common_phrases.get (i));
        }

        items_changed ();
        state_changed ();
    }

    // ─── 配置/属性变更通知 ──────────────────────────────────────────────

    public void notify_state_changed () {
        state_changed ();
    }

    // ─── 工作区快照 ────────────────────────────────────────────────────

    // 保存当前完整状态为新快照（深拷贝，追加到列表末尾）
    public void save_snapshot (string name) {
        var snap = WorkspaceSnapshot.from_app_state (this, name);
        snapshots.add (snap);
        snapshots_changed ();
    }

    // 应用指定快照到当前状态（深拷贝写回，触发 items_changed / state_changed）
    public void apply_snapshot (int index) {
        if (index < 0 || index >= snapshots.size) return;
        snapshots.get (index).apply_to (this);
    }

    public void remove_snapshot (int index) {
        if (index < 0 || index >= snapshots.size) return;
        snapshots.remove_at (index);
        snapshots_changed ();
    }

    public void rename_snapshot (int index, string name) {
        if (index < 0 || index >= snapshots.size) return;
        snapshots.get (index).name = name;
        snapshots_changed ();
    }

    // 确保至少有一个工作区快照：首次启动 / 加载的项目不含任何快照时,
    // 以当前状态创建一个默认的 "Workspace 1", 避免侧栏显示空的 "No Snapshots".
    public void ensure_default_snapshot () {
        if (snapshots.size > 0) return;
        var snap = WorkspaceSnapshot.from_app_state (this, _("Workspace 1"));
        snapshots.add (snap);
        snapshots_changed ();
    }
}
