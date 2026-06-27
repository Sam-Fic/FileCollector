using Gee;

// 单一真相源 (Single Source of Truth)
// 持有 FileCollector 的核心业务状态，并通过信号通知 View/Controller 变更。
public class AppState : GLib.Object {
    public Gee.ArrayList<ItemData> items { get; private set; }
    public CheckStateModel check_model { get; private set; }
    public Gee.ArrayList<string> common_phrases { get; private set; }

    public File? work_dir { get; set; }
    public bool use_absolute { get; set; }
    public bool show_header { get; set; }
    public bool generate_ai_toc { get; set; }
    public string? project_file { get; set; }

    // AI 配置状态 (未来可进一步拆分，但目前与 AppState 生命周期一致)
    public string ai_mode { get; set; }
    public string ai_file_extension { get; set; }
    public string ai_file_label { get; set; }
    public int ai_max_files { get; set; }

    public signal void items_changed ();
    public signal void state_changed ();

    public AppState () {
        items = new Gee.ArrayList<ItemData> ();
        check_model = new CheckStateModel ();
        common_phrases = new Gee.ArrayList<string> ();
        ai_mode = "default";
        ai_file_extension = "";
        ai_file_label = _("文件");
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
        var tmp = items.get (from);
        if (from < to) {
            for (int i = from; i < to; i++) {
                items.set (i, items.get (i + 1));
            }
        } else {
            for (int i = from; i > to; i--) {
                items.set (i, items.get (i - 1));
            }
        }
        items.set (to, tmp);
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
        generate_ai_toc = false;
        project_file = null;
        items_changed ();
        state_changed ();
    }

    public void replace_from (
        File? new_work_dir,
        bool new_use_absolute,
        bool new_show_header,
        Gee.ArrayList<ItemData> new_items,
        Gee.HashSet<string> new_checked_paths,
        Gee.HashSet<string>? new_checked_dirs,
        Gee.ArrayList<string> new_common_phrases,
        bool new_generate_ai_toc = false
    ) {
        work_dir = new_work_dir;
        use_absolute = new_use_absolute;
        show_header = new_show_header;
        generate_ai_toc = new_generate_ai_toc;

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
}
