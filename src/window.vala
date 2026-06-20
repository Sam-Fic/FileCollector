using GLib;
using Gtk;
using Adw;
using Json;

// ─── Directory Item Model ───────────────────────────────────────────────

// 三态勾选状态模型 - 单一真相源
// 状态完全由 checked_files (文件路径集合) 推导, 目录的三态由其后代文件状态计算
public class CheckStateModel : GLib.Object {
    // 唯一的状态存储: 已勾选的文件绝对路径
    public HashTable<string, bool> checked_files { get; private set; }
    // 被用户整体勾选的目录路径 (用于懒加载未展开目录的状态推导)
    public HashTable<string, bool> checked_dirs { get; private set; }

    public signal void changed ();

    // 缓存所有包含已选文件的祖先目录, 用于 O(1) 查询 has_checked_descendant
    private HashTable<string, bool> implicit_checked_dirs;

    public CheckStateModel () {
        checked_files = new HashTable<string, bool> (str_hash, str_equal);
        checked_dirs = new HashTable<string, bool> (str_hash, str_equal);
        implicit_checked_dirs = new HashTable<string, bool> (str_hash, str_equal);
    }

    public void clear () {
        checked_files.remove_all ();
        checked_dirs.remove_all ();
        implicit_checked_dirs.remove_all ();
        changed ();
    }

    public void replace_from (HashTable<string, bool> other_files, HashTable<string, bool>? other_dirs = null) {
        checked_files.remove_all ();
        implicit_checked_dirs.remove_all ();
        foreach (var k in other_files.get_keys ()) {
            checked_files.insert (k, true);
            add_to_implicit_dirs (k);
        }
        checked_dirs.remove_all ();
        if (other_dirs != null) {
            foreach (var k in other_dirs.get_keys ()) {
                checked_dirs.insert (k, true);
            }
        }
        changed ();
    }

    public void set_dir_checked (string path, bool value) {
        if (value) {
            checked_dirs.insert (path, true);
        } else {
            checked_dirs.remove (path);
        }
    }

    // 将指定路径的所有祖先目录从 checked_dirs 中移除 (子节点局部变更时, 祖先降级用)
    public void remove_ancestors_from_checked_dirs (string path) {
        var file = File.new_for_path (path);
        var parent = file.get_parent ();
        while (parent != null) {
            checked_dirs.remove (parent.get_path ());
            parent = parent.get_parent ();
        }
    }

    // 计算节点的三态: 0=未勾选, 1=部分勾选, 2=全勾选
    public int compute_state (DirectoryItem item) {
        if (!item.is_dir) {
            return item.path in checked_files ? 2 : 0;
        }
        return compute_dir_state (item);
    }

    private int compute_dir_state (DirectoryItem item) {
        bool is_loaded = (item.children.get_n_items () > 0);
        bool in_checked_dirs = item.path in checked_dirs;
        bool has_checked = has_checked_descendant (item.path);

        if (is_loaded) {
            var stats = new FileStats ();
            collect_file_stats (item, stats);

            if (stats.total > 0) {
                if (in_checked_dirs) {
                    if (stats.checked_count < stats.total) return 1;
                    return 2;
                }
                if (stats.checked_count == 0) {
                    return has_checked ? 1 : 0;
                }
                if (stats.checked_count == stats.total) {
                    return 1;
                }
                return 1;
            } else {
                if (in_checked_dirs) return 2;
                return has_checked ? 1 : 0;
            }
        } else {
            if (in_checked_dirs) return 2;
            return has_checked ? 1 : 0;
        }
    }

    // O(1) 查询: 利用 implicit_checked_dirs 缓存
    public bool has_checked_descendant (string dir_path) {
        return dir_path in implicit_checked_dirs;
    }

    private void collect_file_stats (DirectoryItem item, FileStats stats) {
        if (!item.is_dir) {
            stats.total++;
            if (item.path in checked_files) stats.checked_count++;
            return;
        }
        for (uint i = 0; i < item.children.get_n_items (); i++) {
            collect_file_stats ((DirectoryItem) item.children.get_item (i), stats);
        }
    }

    private class FileStats {
        public int total = 0;
        public int checked_count = 0;
    }

    // ── implicit_checked_dirs 缓存维护 ──────────────────────────────────

    private void add_to_implicit_dirs (string path) {
        var file = File.new_for_path (path);
        var parent = file.get_parent ();
        while (parent != null) {
            string p = parent.get_path ();
            if (p in implicit_checked_dirs) break;
            implicit_checked_dirs.insert (p, true);
            parent = parent.get_parent ();
        }
    }

    private void rebuild_implicit_dirs () {
        implicit_checked_dirs.remove_all ();
        checked_files.foreach ((key, val) => {
            add_to_implicit_dirs ((string)key);
        });
    }

    // ── 文件/目录勾选操作 ──────────────────────────────────────────────

    // 切换文件勾选状态, 返回新状态
    public bool toggle_file (string path) {
        bool is_checked = path in checked_files;
        if (is_checked) {
            checked_files.remove (path);
            rebuild_implicit_dirs ();
        } else {
            checked_files.insert (path, true);
            add_to_implicit_dirs (path);
        }
        remove_ancestors_from_checked_dirs (path);
        changed ();
        return !is_checked;
    }

    // 设置目录的勾选状态 (递归应用到所有后代文件)
    public void set_subtree_checked (DirectoryItem item, bool value) {
        if (!item.is_dir) {
            if (value) {
                if (!(item.path in checked_files)) {
                    checked_files.insert (item.path, true);
                    add_to_implicit_dirs (item.path);
                }
            } else {
                checked_files.remove (item.path);
                rebuild_implicit_dirs ();
            }
            return;
        }
        set_dir_checked (item.path, value);
        set_subtree_files (item, value);
        rebuild_implicit_dirs ();
        changed ();
    }

    private void set_subtree_files (DirectoryItem item, bool value) {
        for (uint i = 0; i < item.children.get_n_items (); i++) {
            var child = (DirectoryItem) item.children.get_item (i);
            if (!child.is_dir) {
                if (value) {
                    if (!(child.path in checked_files)) {
                        checked_files.insert (child.path, true);
                    }
                } else {
                    checked_files.remove (child.path);
                }
            } else {
                set_subtree_files (child, value);
            }
        }
    }

    // 同步外部添加的文件 (如 AI 工具), 批量勾选
    public void add_files (string[] paths) {
        bool any = false;
        foreach (var p in paths) {
            if (!(p in checked_files)) {
                checked_files.insert (p, true);
                add_to_implicit_dirs (p);
                remove_ancestors_from_checked_dirs (p);
                any = true;
            }
        }
        if (any) changed ();
    }

    public void remove_files (string[] paths) {
        bool any = false;
        foreach (var p in paths) {
            if (p in checked_files) {
                checked_files.remove (p);
                remove_ancestors_from_checked_dirs (p);
                any = true;
            }
        }
        if (any) {
            rebuild_implicit_dirs ();
            changed ();
        }
    }
}

public class DirectoryItem : GLib.Object {
    public string name { get; set; }
    public string path { get; set; }
    public bool is_dir { get; set; }
    private bool _checked = false;
    public bool checked {
        get { return _checked; }
        set {
            if (_checked != value) {
                _checked = value;
                notify_property ("checked");
                state_changed ();
            }
        }
    }
    private bool _inconsistent = false;
    public bool inconsistent {
        get { return _inconsistent; }
        set {
            if (_inconsistent != value) {
                _inconsistent = value;
                notify_property ("inconsistent");
                state_changed ();
            }
        }
    }
    public GLib.ListStore children { get; private set; }
    // 标记子节点是否正在后台加载, 防止重复加载
    public bool children_loading = false;

    public signal void state_changed ();

    public DirectoryItem (string name, string path, bool is_dir) {
        this.name = name;
        this.path = path;
        this.is_dir = is_dir;
        this.children = new GLib.ListStore (typeof (DirectoryItem));
    }

    public void set_checked_recursive (bool value) {
        _checked = value;
        _inconsistent = false;
        notify_property ("checked");
        notify_property ("inconsistent");
        state_changed ();
        for (uint i = 0; i < children.get_n_items (); i++) {
            var child = (DirectoryItem) children.get_item (i);
            child.set_checked_recursive (value);
        }
    }
}

// 目录条目信息 (用于后台线程收集, 主线程创建 DirectoryItem)
private class DirChildInfo {
    public string name;
    public string path;
    public bool is_dir;
    public DirChildInfo (string name, string path, bool is_dir) {
        this.name = name;
        this.path = path;
        this.is_dir = is_dir;
    }
}

[GtkTemplate (ui = "/com/github/samfic/filecollector/window.ui")]
public class FileCollectorWindow : Adw.ApplicationWindow {
    [GtkChild] private unowned Gtk.ScrolledWindow dir_scrolled;
    [GtkChild] private unowned Gtk.ListView queue_list;
    [GtkChild] private unowned Gtk.TextView preview_view;
    [GtkChild] private unowned Gtk.Button open_folder_btn;
    [GtkChild] private unowned Gtk.Button btn_undo;
    [GtkChild] private unowned Gtk.Button btn_redo;
    [GtkChild] private unowned Gtk.Button btn_generate;
    [GtkChild] private unowned Gtk.Button btn_generate_clipboard;
    [GtkChild] private unowned Gtk.Button btn_add_ext;
    [GtkChild] private unowned Gtk.Button btn_add_text_above;
    [GtkChild] private unowned Gtk.Button btn_add_text_below;
    [GtkChild] private unowned Gtk.Button btn_move_up;
    [GtkChild] private unowned Gtk.Button btn_move_down;
    [GtkChild] private unowned Gtk.Button btn_delete;
    [GtkChild] private unowned Gtk.Button btn_clear;
    [GtkChild] private unowned Gtk.CheckButton radio_relative_path;
    [GtkChild] private unowned Gtk.CheckButton radio_absolute_path;
    [GtkChild] private unowned Gtk.CheckButton check_write_header;
    [GtkChild] private unowned Gtk.SearchEntry search_entry;
    [GtkChild] private unowned Adw.ToastOverlay toast_overlay;
    [GtkChild] private unowned Gtk.Paned outer_paned;
    [GtkChild] private unowned Gtk.Paned inner_paned;
    [GtkChild] private unowned Gtk.Button btn_ai_toggle;
    [GtkChild] private unowned Gtk.Paned ai_paned;
    [GtkChild] private unowned Gtk.Frame ai_sidebar;

    private Gtk.ColumnView dir_column_view;
    private Gtk.TreeListModel tree_list_model;
    private Gtk.FilterListModel filter_model;
    private Gtk.CustomFilter tree_filter;
    private Gtk.SingleSelection tree_selection;
    private GLib.ListStore root_store;
    private File? work_dir = null;
    private string search_text = "";
    private string? project_file = null;
    private bool use_absolute = false;
    private bool show_header = false;

    private GLib.ListStore queue_store;
    private Gtk.SingleSelection queue_selection;

    private GenericArray<ItemData> items;
    private HashTable<string, bool> checked_paths;  // 保留用于向后兼容 (undo/redo/cli)
    private CheckStateModel check_model;  // 单一真相源: 三态勾选状态
    private GenericArray<string> common_phrases;

    private UndoManager undo_manager;

    private Adw.WindowTitle? _title_widget;

    private PhrasesPicker? phrases_picker_instance = null;

    // AI 助手
    private AIPanel? ai_panel_instance = null;
    private AISettingsDialog? ai_settings_dialog_instance = null;
    private bool ai_panel_visible = false;
    // 记录 AI 面板展开前的窗口宽度, 隐藏时恢复
    private int pre_ai_width = 0;
    // 缓存 col-resize 光标, 避免 motion 事件每次都创建新对象
    private Gdk.Cursor? col_resize_cursor = null;
    // 编排模式: "default" | "directory" | "single" (与多平台版本 1:1)
    private string ai_mode = "default";
    private string ai_file_extension = "";
    private string ai_file_label = "文件";
    private int ai_max_files = 50;

    // 后台线程引用: 防止 Thread 对象被提前回收, 并在窗口关闭时 join 确保安全退出
    private Gee.ArrayList<GLib.Thread<void*>> bg_threads = new Gee.ArrayList<GLib.Thread<void*>> ();
    private bool window_closing = false;
    private GLib.Cancellable? app_cancellable = new GLib.Cancellable ();


    public FileCollectorWindow (Adw.Application app) {
        GLib.Object (application: app);
    }

    construct {
        items = new GenericArray<ItemData> ();
        checked_paths = new HashTable<string, bool> (str_hash, str_equal);
        check_model = new CheckStateModel ();
        common_phrases = new GenericArray<string> ();
        undo_manager = new UndoManager ();

        ConfigManager.load_common_phrases (common_phrases);
        load_css ();

        setup_queue_list ();
        setup_tree_view ();
        sync_path_mode_radios ();
        setup_signals ();
        setup_ai_panel ();
        setup_pane_sizes ();
        setup_shortcuts ();
        search_entry.visible = false;

        this.close_request.connect (on_close_request);

        GLib.Idle.add (() => {
            cache_title_widget ();
            return Source.REMOVE;
        });
    }

    private bool on_close_request () {
        if (app_cancellable != null) {
            app_cancellable.cancel ();
        }
        window_closing = true;
        if (ai_panel_instance != null) {
            ai_panel_instance.shutdown ();
        }
        // Join 所有后台线程, 确保线程退出后再销毁窗口, 防止 Idle 回调访问已释放的 widget
        foreach (var t in bg_threads) {
            t.join ();
        }
        bg_threads.clear ();
        return false;
    }

    private void load_css () {
        var provider = new Gtk.CssProvider ();
        try {
            provider.load_from_resource ("/com/github/samfic/filecollector/style.css");
            Gtk.StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        } catch (Error e) {
            warning ("Failed to load CSS: %s", e.message);
        }
    }

    public static string load_settings_language () {
        return ConfigManager.load_settings_language ();
    }

    private void setup_queue_list () {
        queue_store = new GLib.ListStore (typeof (ItemData));
        queue_selection = new Gtk.SingleSelection (queue_store);

        var factory = new Gtk.SignalListItemFactory ();
        factory.setup.connect ((obj) => {
            var list_item = obj as Gtk.ListItem;

            var icon = new Gtk.Image ();
            icon.add_css_class ("dim-label");

            var label = new Gtk.Label ("");
            label.ellipsize = Pango.EllipsizeMode.END;
            label.xalign = 0;
            label.hexpand = true;

            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            box.margin_top = 6;
            box.margin_bottom = 6;
            box.margin_start = 8;
            box.margin_end = 8;
            box.append (icon);
            box.append (label);

            list_item.set_child (box);
        });

        factory.bind.connect ((obj) => {
            var list_item = obj as Gtk.ListItem;
            if (list_item == null) return;

            var data = list_item.get_item () as ItemData;
            if (data == null) return;

            var box = list_item.get_child () as Gtk.Box;
            if (box == null) return;

            var icon = box.get_first_child () as Gtk.Image;
            if (icon == null) return;

            var label = icon.get_next_sibling () as Gtk.Label;
            if (label == null) return;

            // 初始渲染
            render_queue_row (list_item, data, label, icon);

            // 监听 content 变化: 编辑确认后 edit_data.content = text 会触发 notify,
            // 实时刷新行内预览 (splice 复用同一对象引用时 ListView 不会重新 bind)
            ulong handler_id = data.notify["content"].connect (() => {
                if (list_item != null && list_item.get_item () != null) {
                    render_queue_row (list_item, data, label, icon);
                }
            });

            // 将句柄 ID 与所监视的数据模型指针弱挂载到 ListItem 容器上,
            // 供 unbind 时双重校验安全剥离信号
            list_item.set_data<ulong> ("content_notify_id", handler_id);
            list_item.set_data<ItemData> ("monitored_data_ptr", data);
        });

        factory.unbind.connect ((obj) => {
            var list_item = obj as Gtk.ListItem;
            if (list_item == null) return;

            ulong handler_id = list_item.get_data<ulong> ("content_notify_id");
            var data = list_item.get_data<ItemData> ("monitored_data_ptr");

            // 安全双重校验: 确认句柄未失效且数据对象依然存在于内存中, 方能安全剥离信号
            if (handler_id != 0 && data != null && GLib.SignalHandler.is_connected (data, handler_id)) {
                GLib.SignalHandler.disconnect (data, handler_id);
            }

            // 显式清空存储节点引用, 防止生命周期残留导致内存泄露
            list_item.set_data ("content_notify_id", null);
            list_item.set_data ("monitored_data_ptr", null);
        });

        queue_list.model = queue_selection;
        queue_list.factory = factory;
    }

    // 渲染编排列表单行: 根据 item_type 计算 display_name 和 icon, 写入 label/icon
    private void render_queue_row (Gtk.ListItem list_item, ItemData data, Gtk.Label label, Gtk.Image icon) {
        string display_name;
        string icon_name;
        if (data.item_type == "file") {
            var file = File.new_for_path (data.file_path);
            display_name = file.get_basename ();
            icon_name = data.force_absolute ? "document-open-symbolic" : "text-x-generic-symbolic";
        } else {
            var preview = data.content ?? "";
            if (preview.char_count () > 40) {
                int byte_pos = preview.index_of_nth_char (40);
                preview = preview.substring (0, byte_pos) + "…";
            }
            display_name = preview;
            icon_name = "edit-symbolic";
        }

        var pos = list_item.get_position ();
        label.set_text ("%d. %s".printf ((int)pos + 1, display_name));
        icon.icon_name = icon_name;
    }

    private void setup_tree_view () {
        root_store = new GLib.ListStore (typeof (DirectoryItem));

        tree_list_model = new Gtk.TreeListModel (
            root_store,
            false,
            false,
            (item) => ((DirectoryItem)item).children
        );

        tree_filter = new Gtk.CustomFilter (filter_tree_func);
        filter_model = new Gtk.FilterListModel (tree_list_model, tree_filter);

        tree_selection = new Gtk.SingleSelection (filter_model);
        tree_selection.set_autoselect (false);

        dir_column_view = new Gtk.ColumnView (tree_selection);
        dir_column_view.add_css_class ("file-tree");

        var expander_factory = new Gtk.SignalListItemFactory ();
        expander_factory.setup.connect ((obj) => {
            var list_item = obj as Gtk.ListItem;

            var expander = new Gtk.TreeExpander ();
            expander.set_indent_for_icon (true);

            var check = new Gtk.CheckButton ();
            check.add_css_class ("tree-check");
            check.valign = Gtk.Align.CENTER;

            var label = new Gtk.Label ("");
            label.ellipsize = Pango.EllipsizeMode.END;
            label.xalign = 0;
            label.hexpand = true;
            label.valign = Gtk.Align.CENTER;

            var click = new Gtk.GestureClick ();
            click.pressed.connect (() => {
                var row = list_item.get_item () as Gtk.TreeListRow;
                if (row == null) return;
                var item = row.get_item () as DirectoryItem;
                if (item == null || item.is_dir) return;

                var pos = list_item.get_position ();
                tree_selection.selected = pos;

                var temp_item = new ItemData ("file", item.path, null, false);
                update_preview (temp_item);
                queue_selection.selected = Gtk.INVALID_LIST_POSITION;
            });
            label.add_controller (click);

            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            box.margin_top = 0;
            box.margin_bottom = 0;
            box.margin_start = 2;
            box.margin_end = 2;
            box.append (check);
            box.append (label);

            expander.set_child (box);
            list_item.set_child (expander);
        });

        expander_factory.bind.connect ((obj) => {
            var list_item = obj as Gtk.ListItem;
            if (list_item == null) return;

            var row = list_item.get_item () as Gtk.TreeListRow;
            if (row == null) return;

            var item = row.get_item () as DirectoryItem;
            if (item == null) return;

            var expander = list_item.get_child () as Gtk.TreeExpander;
            if (expander == null) return;

            var box = expander.get_child () as Gtk.Box;
            if (box == null) return;

            var check = box.get_first_child () as Gtk.CheckButton;
            if (check == null) return;

            var label = check.get_next_sibling () as Gtk.Label;
            if (label == null) return;

            expander.set_list_row (row);
            expander.set_hide_expander (!item.is_dir);

            check.active = item.checked;
            check.inconsistent = item.inconsistent;

            check.set_data<DirectoryItem> ("item", item);
            ulong handler_id = check.notify["active"].connect (on_check_toggled);
            check.set_data<ulong?> ("handler_id", handler_id);

            ulong state_handler_id = item.state_changed.connect (() => {
                var hid = check.get_data<ulong?> ("handler_id");
                if (hid != null) {
                    SignalHandler.block (check, hid);
                }
                check.active = item.checked;
                check.inconsistent = item.inconsistent;
                if (hid != null) {
                    SignalHandler.unblock (check, hid);
                }
            });
            check.set_data<ulong?> ("state_handler_id", state_handler_id);

            label.set_text (item.name);

            if (item.is_dir) {
                ulong expanded_handler_id = row.notify["expanded"].connect (() => {
                    if (row.get_expanded () && item.children.get_n_items () == 0 && !item.children_loading) {
                        load_directory_children_lazy (item);
                    }
                });
                row.set_data<ulong?> ("expanded-handler", expanded_handler_id);
            }
        });

        expander_factory.unbind.connect ((obj) => {
            var list_item = obj as Gtk.ListItem;
            if (list_item == null) return;

            var expander = list_item.get_child () as Gtk.TreeExpander;
            if (expander == null) return;

            var box = expander.get_child () as Gtk.Box;
            if (box == null) return;

            var check = box.get_first_child () as Gtk.CheckButton;
            if (check == null) return;

            var handler_id = check.get_data<ulong?> ("handler_id");
            if (handler_id != null) {
                GLib.SignalHandler.disconnect (check, handler_id);
            }

            var state_handler_id = check.get_data<ulong?> ("state_handler_id");
            var item = check.get_data<DirectoryItem> ("item");
            if (state_handler_id != null && item != null) {
                GLib.SignalHandler.disconnect (item, state_handler_id);
            }

            var row = list_item.get_item () as Gtk.TreeListRow;
            if (row != null) {
                var expanded_handler_id = row.get_data<ulong?> ("expanded-handler");
                if (expanded_handler_id != null) {
                    GLib.SignalHandler.disconnect (row, expanded_handler_id);
                }
            }

            expander.set_list_row (null);
        });

        var column = new Gtk.ColumnViewColumn (null, expander_factory);
        column.set_expand (true);
        dir_column_view.append_column (column);

        dir_column_view.show_column_separators = false;
        dir_column_view.show_row_separators = false;

        GLib.Idle.add (() => {
            var child = dir_column_view.get_first_child ();
            if (child != null) {
                child.visible = false;
            }
            return Source.REMOVE;
        });

        dir_scrolled.set_child (dir_column_view);

        tree_selection.selection_changed.connect (on_tree_selection_changed);
        dir_column_view.activate.connect (on_column_view_activated);
    }

    private void on_column_view_activated (uint position) {
        preview_tree_item_at (position);
        queue_selection.selected = Gtk.INVALID_LIST_POSITION;
    }

    private void on_tree_selection_changed (uint position, uint n_items) {
        if (position == Gtk.INVALID_LIST_POSITION) return;
        preview_tree_item_at (position);
        queue_selection.selected = Gtk.INVALID_LIST_POSITION;
    }

    private void preview_tree_item_at (uint position) {
        var row = filter_model.get_item (position) as Gtk.TreeListRow;
        if (row == null) return;

        var item = row.get_item () as DirectoryItem;
        if (item == null || item.is_dir) return;

        var temp_item = new ItemData ("file", item.path, null, false);
        update_preview (temp_item);
    }

    private void clear_tree_selection () {
        tree_selection.selected = Gtk.INVALID_LIST_POSITION;
    }

    private void on_search_changed () {
        search_text = search_entry.text;
        tree_filter.changed (Gtk.FilterChange.DIFFERENT);
    }

    private bool filter_tree_func (GLib.Object item) {
        if (search_text == "") return true;
        var row = item as Gtk.TreeListRow;
        if (row == null) return true;
        var dir_item = row.get_item () as DirectoryItem;
        if (dir_item == null) return true;

        if (dir_item.name.casefold ().contains (search_text.casefold ()))
            return true;

        if (dir_item.is_dir && has_matching_descendant (dir_item))
            return true;

        return false;
    }

    private bool has_matching_descendant (DirectoryItem item) {
        for (uint i = 0; i < item.children.get_n_items (); i++) {
            var child = item.children.get_item (i) as DirectoryItem;
            if (child == null) continue;
            if (child.name.casefold ().contains (search_text.casefold ()))
                return true;
            if (child.is_dir && has_matching_descendant (child))
                return true;
        }
        return false;
    }

    private void on_check_toggled (GLib.Object obj, GLib.ParamSpec pspec) {
        var check = obj as Gtk.CheckButton;
        if (check == null) return;

        var item = check.get_data<DirectoryItem> ("item");
        if (item == null) return;

        push_undo_state ();

        bool new_checked = check.active;
        // 统一入口: 通过 check_model 修改状态, 再同步 items 和 UI
        apply_check_change (item, new_checked);
    }

    // 统一的勾选变更处理: 修改 check_model -> 同步 items -> 刷新 UI 三态
    private void apply_check_change (DirectoryItem item, bool new_checked) {
        if (item.is_dir) {
            // 立即更新 checked_dirs 确保未展开目录状态正确
            check_model.set_dir_checked (item.path, new_checked);
            refresh_all_tree_states ();
            dir_column_view.queue_draw ();

            // 目录: 后台线程递归收集文件路径和子目录路径, 完成后在主线程更新 UI, 避免阻塞
            string dir_path = item.path;
            try {
                GLib.Thread<void*>? thread = null;
                thread = new Thread<void*> ("collect-files", () => {
                    var file_paths = new GenericArray<string> ();
                    var dir_paths = new GenericArray<string> ();
                    collect_files_from_filesystem (dir_path, file_paths, dir_paths);
                    Idle.add (() => {
                        if (window_closing) {
                            if (thread != null) bg_threads.remove (thread);
                            return Source.REMOVE;
                        }
                        apply_dir_check_result (new_checked, dir_paths, file_paths);
                        if (thread != null) bg_threads.remove (thread);
                        return Source.REMOVE;
                    });
                    return null;
                });
                bg_threads.add (thread);
            } catch (ThreadError e) {
                warning ("Failed to create collect-files thread: %s", e.message);
                // 后备: 同步执行
                var file_paths = new GenericArray<string> ();
                var dir_paths = new GenericArray<string> ();
                collect_files_from_filesystem (dir_path, file_paths, dir_paths);
                apply_dir_check_result (new_checked, dir_paths, file_paths);
            }
        } else {
            // 文件: 直接切换 (无 I/O, 同步即可)
            check_model.toggle_file (item.path);
            if (new_checked) {
                if (!(item.path in checked_paths) && !path_in_items (item.path)) {
                    checked_paths.insert (item.path, true);
                    items.add (new ItemData ("file", item.path, null, false));
                }
            } else {
                checked_paths.remove (item.path);
                remove_items_by_path (item.path);
            }
            refresh_all_tree_states ();
            dir_column_view.queue_draw ();
            refresh_list ();
        }
    }

    // 目录勾选/取消勾选的后台收集结果处理 (主线程)
    // items 增删分批在 Idle 中执行, 避免数万文件一次性处理阻塞 UI
    private void apply_dir_check_result (bool new_checked, GenericArray<string> dir_paths, GenericArray<string> file_paths) {
        // check_model 操作: 同步执行 (数据结构操作, 相对快速)
        if (new_checked) {
            // 先加文件 (内部会移除祖先目录的 checked_dirs 标记)
            check_model.add_files (file_paths.data);
            // 再把当前目录及其所有子孙目录加回 checked_dirs
            foreach (var d in dir_paths) {
                check_model.set_dir_checked (d, true);
            }
        } else {
            foreach (var d in dir_paths) {
                check_model.set_dir_checked (d, false);
            }
            check_model.remove_files (file_paths.data);
            // 将取消勾选的目录的祖先从 checked_dirs 中移除, 使其降级为半选
            check_model.remove_ancestors_from_checked_dirs (dir_paths.get (0));
        }
        // 树状态立即刷新 (基于 check_model, 已同步更新)
        refresh_all_tree_states ();
        dir_column_view.queue_draw ();

        // items 增删: 分批在 Idle 中执行, 每批 200 个, 避免阻塞主循环
        int chunk_size = 200;
        int idx = 0;
        Idle.add (() => {
            if (window_closing) return Source.REMOVE;
            int count = 0;
            while (idx < file_paths.length && count < chunk_size) {
                var p = file_paths.get (idx);
                if (new_checked) {
                    if (!(p in checked_paths) && !path_in_items (p)) {
                        checked_paths.insert (p, true);
                        items.add (new ItemData ("file", p, null, false));
                    }
                } else {
                    if (p in checked_paths) {
                        checked_paths.remove (p);
                        remove_items_by_path (p);
                    }
                }
                idx++;
                count++;
            }
            if (idx < file_paths.length) {
                return Source.CONTINUE;
            }
            if (!window_closing) {
                refresh_list ();
            }
            return Source.REMOVE;
        });
    }

    // 从文件系统递归收集目录下所有文件路径和子目录路径
    private void collect_files_from_filesystem (string dir_path, GenericArray<string> out_files, GenericArray<string> out_dirs) {
        if (app_cancellable != null && app_cancellable.is_cancelled ()) return;
        out_dirs.add (dir_path);
        var dir = File.new_for_path (dir_path);
        try {
            var enumerator = dir.enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NONE
            );
            FileInfo info;
            while ((info = enumerator.next_file ()) != null) {
                if (app_cancellable != null && app_cancellable.is_cancelled ()) return;
                var child = dir.get_child (info.get_name ());
                if (info.get_file_type () == FileType.DIRECTORY) {
                    collect_files_from_filesystem (child.get_path (), out_files, out_dirs);
                } else {
                    out_files.add (child.get_path ());
                }
            }
        } catch (Error e) {
            warning ("collect_files_from_filesystem: %s", e.message);
        }
    }

    // 从 check_model 重新计算所有可见节点的三态
    // 辅助结构体：自底向上递归中收集子树统计信息, 消除双重递归
    private struct SubtreeStats {
        public int total_files;
        public int checked_files;
    }

    private void refresh_all_tree_states () {
        for (uint i = 0; i < root_store.get_n_items (); i++) {
            refresh_and_collect_stats ((DirectoryItem) root_store.get_item (i));
        }
    }

    // 自底向上刷新并收集统计信息, 消除原有的 refresh_subtree_states + compute_state + collect_file_stats 三重递归
    private SubtreeStats refresh_and_collect_stats (DirectoryItem item) {
        SubtreeStats stats = SubtreeStats ();

        if (!item.is_dir) {
            // 文件节点：直接查 check_model
            bool is_checked = item.path in check_model.checked_files;
            item.checked = is_checked;
            item.inconsistent = false;

            stats.total_files = 1;
            stats.checked_files = is_checked ? 1 : 0;
            return stats;
        }

        // 目录节点：先递归处理所有子节点, 顺带收集统计
        stats.total_files = 0;
        stats.checked_files = 0;
        for (uint i = 0; i < item.children.get_n_items (); i++) {
            var child_stats = refresh_and_collect_stats ((DirectoryItem) item.children.get_item (i));
            stats.total_files += child_stats.total_files;
            stats.checked_files += child_stats.checked_files;
        }

        // 根据子节点统计结果推导当前目录的三态 (保持原 compute_dir_state 逻辑)
        bool in_checked_dirs = item.path in check_model.checked_dirs;
        bool has_checked = check_model.has_checked_descendant (item.path);

        if (stats.total_files > 0) {
            if (in_checked_dirs) {
                if (stats.checked_files < stats.total_files) {
                    item.checked = false;
                    item.inconsistent = true; // 部分选中
                } else {
                    item.checked = true;
                    item.inconsistent = false; // 全选中
                }
            } else {
                if (stats.checked_files == 0) {
                    item.checked = false;
                    item.inconsistent = has_checked; // 无选中但后代可能有选中
                } else if (stats.checked_files == stats.total_files) {
                    item.checked = false;
                    item.inconsistent = true; // 全选但未标记为 checked_dirs
                } else {
                    item.checked = false;
                    item.inconsistent = true; // 部分选中
                }
            }
        } else {
            // 空目录或未加载子节点的目录
            if (in_checked_dirs) {
                item.checked = true;
                item.inconsistent = false;
            } else {
                item.checked = false;
                item.inconsistent = has_checked;
            }
        }
        return stats;
    }

    // 保留兼容接口
    private void refresh_subtree_states (DirectoryItem item) {
        refresh_and_collect_stats (item);
    }

    private void push_undo_state () {
        undo_manager.push (new UndoDelta.for_snapshot (
            new UndoState (items, checked_paths, check_model.checked_dirs, work_dir, use_absolute, show_header)));
    }

    private void push_undo_delta (UndoDelta delta) {
        undo_manager.push (delta);
    }

    private int find_item_index (ItemData data) {
        for (int i = 0; i < items.length; i++) {
            if (items.get (i) == data) return i;
        }
        return -1;
    }

    private void on_undo () {
        var delta = undo_manager.pop_undo ();
        if (delta == null) return;
        var redo_delta = build_redo_delta (delta);
        apply_undo_delta (delta);
        undo_manager.push_redo (redo_delta);
        if (delta.op != UndoOp.SNAPSHOT) {
            refresh_list ();
        }
        update_undo_redo_buttons ();
    }

    private void on_redo () {
        var delta = undo_manager.pop_redo ();
        if (delta == null) return;
        var undo_delta = build_undo_delta (delta);
        apply_redo_delta (delta);
        undo_manager.push_undo (undo_delta);
        if (delta.op != UndoOp.SNAPSHOT) {
            refresh_list ();
        }
        update_undo_redo_buttons ();
    }

    // 根据 undo delta 构建对应的 redo delta (捕获当前状态作为 redo 依据)
    private UndoDelta build_redo_delta (UndoDelta d) {
        switch (d.op) {
            case UndoOp.SNAPSHOT:
                return new UndoDelta.for_snapshot (
                    new UndoState (items, checked_paths, check_model.checked_dirs, work_dir, use_absolute, show_header));
            case UndoOp.INSERT:
                // redo = 重新插入同样的 items
                return new UndoDelta.for_insert (d.index, d.items);
            case UndoOp.REMOVE:
                // redo = 再次移除
                return new UndoDelta.for_remove (d.index, d.items, d.removed_checked_paths);
            case UndoOp.EDIT:
                return new UndoDelta.for_edit (d.index, d.old_content, d.new_content);
            case UndoOp.SWAP:
                return new UndoDelta.for_swap (d.index, d.index2);
            case UndoOp.MOVE:
                return new UndoDelta.for_move (d.from_index, d.to_index);
            case UndoOp.SET_ABSOLUTE:
                return new UndoDelta.for_absolute (d.old_bool_value, d.new_bool_value,
                                                    d.old_show_header, show_header);
            case UndoOp.SET_HEADER:
                return new UndoDelta.for_header (d.old_bool_value, d.new_bool_value);
            default:
                return new UndoDelta.for_snapshot (
                    new UndoState (items, checked_paths, check_model.checked_dirs, work_dir, use_absolute, show_header));
        }
    }

    // 根据 redo delta 构建对应的 undo delta
    private UndoDelta build_undo_delta (UndoDelta d) {
        switch (d.op) {
            case UndoOp.SNAPSHOT:
                return new UndoDelta.for_snapshot (
                    new UndoState (items, checked_paths, check_model.checked_dirs, work_dir, use_absolute, show_header));
            case UndoOp.INSERT:
                return new UndoDelta.for_insert (d.index, d.items);
            case UndoOp.REMOVE:
                return new UndoDelta.for_remove (d.index, d.items, d.removed_checked_paths);
            case UndoOp.EDIT:
                return new UndoDelta.for_edit (d.index, d.old_content, d.new_content);
            case UndoOp.SWAP:
                return new UndoDelta.for_swap (d.index, d.index2);
            case UndoOp.MOVE:
                return new UndoDelta.for_move (d.from_index, d.to_index);
            case UndoOp.SET_ABSOLUTE:
                return new UndoDelta.for_absolute (d.old_bool_value, d.new_bool_value,
                                                    d.old_show_header, show_header);
            case UndoOp.SET_HEADER:
                return new UndoDelta.for_header (d.old_bool_value, d.new_bool_value);
            default:
                return new UndoDelta.for_snapshot (
                    new UndoState (items, checked_paths, check_model.checked_dirs, work_dir, use_absolute, show_header));
        }
    }

    private void apply_undo_delta (UndoDelta d) {
        switch (d.op) {
            case UndoOp.SNAPSHOT:
                restore_undo_state (d.snapshot);
                return;
            case UndoOp.INSERT:
                // undo 插入 = 移除
                items.remove_range (d.index, d.items.length);
                break;
            case UndoOp.REMOVE:
                // undo 移除 = 重新插入
                for (int i = 0; i < d.items.length; i++) {
                    items.insert (d.index + i, d.items.get (i));
                }
                if (d.removed_checked_paths != null) {
                    for (int i = 0; i < d.removed_checked_paths.length; i++) {
                        checked_paths.insert (d.removed_checked_paths.get (i), true);
                        set_tree_item_check (d.removed_checked_paths.get (i), true);
                    }
                }
                break;
            case UndoOp.EDIT:
                items.get (d.index).content = d.old_content;
                break;
            case UndoOp.SWAP:
                var tmp = items.get (d.index);
                items.set (d.index, items.get (d.index2));
                items.set (d.index2, tmp);
                break;
            case UndoOp.MOVE:
                // undo: 从 to_index 移回 from_index
                var it = items.get (d.to_index);
                items.remove_index (d.to_index);
                items.insert (d.from_index, it);
                break;
            case UndoOp.SET_ABSOLUTE:
                apply_absolute_change (d.old_bool_value, d.old_show_header);
                break;
            case UndoOp.SET_HEADER:
                apply_header_change (d.old_bool_value);
                break;
        }
    }

    private void apply_redo_delta (UndoDelta d) {
        switch (d.op) {
            case UndoOp.SNAPSHOT:
                restore_undo_state (d.snapshot);
                return;
            case UndoOp.INSERT:
                for (int i = 0; i < d.items.length; i++) {
                    items.insert (d.index + i, d.items.get (i));
                }
                break;
            case UndoOp.REMOVE:
                items.remove_range (d.index, d.items.length);
                if (d.removed_checked_paths != null) {
                    for (int i = 0; i < d.removed_checked_paths.length; i++) {
                        checked_paths.remove (d.removed_checked_paths.get (i));
                        set_tree_item_check (d.removed_checked_paths.get (i), false);
                    }
                }
                break;
            case UndoOp.EDIT:
                items.get (d.index).content = d.new_content;
                break;
            case UndoOp.SWAP:
                var tmp = items.get (d.index);
                items.set (d.index, items.get (d.index2));
                items.set (d.index2, tmp);
                break;
            case UndoOp.MOVE:
                var it = items.get (d.from_index);
                items.remove_index (d.from_index);
                items.insert (d.to_index, it);
                break;
            case UndoOp.SET_ABSOLUTE:
                apply_absolute_change (d.new_bool_value, d.old_show_header);
                break;
            case UndoOp.SET_HEADER:
                apply_header_change (d.new_bool_value);
                break;
        }
    }

    // 同步单选按钮到 use_absolute 状态
    private void sync_path_mode_radios () {
        radio_absolute_path.notify["active"].disconnect (on_path_mode_changed);
        radio_relative_path.notify["active"].disconnect (on_path_mode_changed);
        radio_absolute_path.active = use_absolute;
        radio_relative_path.active = !use_absolute;
        radio_absolute_path.notify["active"].connect (on_path_mode_changed);
        radio_relative_path.notify["active"].connect (on_path_mode_changed);
    }

    // 统一应用 use_absolute 变更 (undo/redo 共用)
    private void apply_absolute_change (bool new_abs, bool new_hdr) {
        use_absolute = new_abs;
        show_header = new_hdr;
        radio_absolute_path.notify["active"].disconnect (on_path_mode_changed);
        radio_relative_path.notify["active"].disconnect (on_path_mode_changed);
        check_write_header.notify["active"].disconnect (on_header_check_changed);
        radio_absolute_path.active = new_abs;
        radio_relative_path.active = !new_abs;
        check_write_header.active = new_hdr;
        radio_absolute_path.notify["active"].connect (on_path_mode_changed);
        radio_relative_path.notify["active"].connect (on_path_mode_changed);
        check_write_header.notify["active"].connect (on_header_check_changed);
    }

    // 统一应用 show_header 变更 (undo/redo 共用)
    private void apply_header_change (bool new_hdr) {
        show_header = new_hdr;
        check_write_header.notify["active"].disconnect (on_header_check_changed);
        check_write_header.active = new_hdr;
        check_write_header.notify["active"].connect (on_header_check_changed);
    }

    private void restore_undo_state (UndoState state) {
        items.remove_range (0, items.length);
        for (int i = 0; i < state.n_items; i++) {
            items.add (state.get_item (i));
        }

        checked_paths.remove_all ();
        foreach (var key in state.checked_paths.get_keys ()) {
            checked_paths.insert (key, true);
        }

        use_absolute = state.use_absolute;
        show_header = state.show_header;
        radio_absolute_path.notify["active"].disconnect (on_path_mode_changed);
        radio_relative_path.notify["active"].disconnect (on_path_mode_changed);
        check_write_header.notify["active"].disconnect (on_header_check_changed);
        radio_absolute_path.active = use_absolute;
        radio_relative_path.active = !use_absolute;
        check_write_header.active = show_header;
        radio_absolute_path.notify["active"].connect (on_path_mode_changed);
        radio_relative_path.notify["active"].connect (on_path_mode_changed);
        check_write_header.notify["active"].connect (on_header_check_changed);

        bool work_dir_changed = false;
        if (state.work_dir != null && work_dir != null) {
            work_dir_changed = state.work_dir.get_path () != work_dir.get_path ();
        } else if (state.work_dir != null || work_dir != null) {
            work_dir_changed = true;
        }

        if (work_dir_changed) {
            work_dir = state.work_dir;
            if (work_dir != null) {
                update_subtitle (work_dir.get_path ());
                root_store.remove_all ();
                check_model.replace_from (checked_paths, state.checked_dirs);
                var root_item = new DirectoryItem (work_dir.get_basename (), work_dir.get_path (), true);
                root_store.append (root_item);
                load_directory_children_lazy (root_item);
                search_entry.visible = true;
                var root_row = tree_list_model.get_item (0) as Gtk.TreeListRow;
                if (root_row != null) root_row.set_expanded (true);
            } else {
                update_subtitle (null);
                root_store.remove_all ();
                search_entry.visible = false;
            }
        } else if (work_dir != null && root_store.get_n_items () > 0) {
            check_model.replace_from (checked_paths, state.checked_dirs);
            refresh_all_tree_states ();
        }

        refresh_list ();
        update_undo_redo_buttons ();
    }

    private void update_undo_redo_buttons () {
        btn_undo.sensitive = undo_manager.can_undo;
        btn_redo.sensitive = undo_manager.can_redo;
    }

    private void setup_signals () {
        open_folder_btn.clicked.connect (() => on_open_folder_clicked.begin ());
        btn_undo.clicked.connect (on_undo);
        btn_redo.clicked.connect (on_redo);
        btn_add_ext.clicked.connect (on_add_external_files);
        btn_add_text_above.clicked.connect (() => insert_text (true));
        btn_add_text_below.clicked.connect (() => insert_text (false));
        btn_move_up.clicked.connect (on_move_up);
        btn_move_down.clicked.connect (on_move_down);
        btn_delete.clicked.connect (on_delete_item);
        btn_clear.clicked.connect (on_clear_items);
        btn_generate.clicked.connect (on_generate_clicked);
        btn_generate_clipboard.clicked.connect (on_generate_to_clipboard_clicked);
        radio_absolute_path.notify["active"].connect (on_path_mode_changed);
        radio_relative_path.notify["active"].connect (on_path_mode_changed);
        check_write_header.notify["active"].connect (on_header_check_changed);

        queue_selection.selection_changed.connect (on_queue_selection_changed);
        queue_list.activate.connect (on_queue_row_activated);

        search_entry.search_changed.connect (on_search_changed);

        update_queue_buttons ();
    }

    private void setup_pane_sizes () {
        outer_paned.notify["position"].connect (clamp_outer_paned_position);
        outer_paned.notify["width"].connect (clamp_outer_paned_position);
        inner_paned.notify["position"].connect (clamp_inner_paned_position);

        GLib.Idle.add (() => {
            if (window_closing) return Source.REMOVE;
            measure_pane_minimums ();
            update_window_min_size ();
            clamp_outer_paned_position ();
            clamp_inner_paned_position ();
            return Source.REMOVE;
        });
    }

    private const int PANED_SEP = 6;

    private bool _clamping_inner_from_outer = false;
    // 阻断 clamp_outer_paned_position 在修改 outer_paned.position 时
    // 触发 notify["position"] 信号导致的递归调用
    private bool _clamping_outer = false;

    private int left_min_width = 0;
    private int center_min_width = 0;
    private int right_min_width = 0;

    // 根据当前可见面板的最小宽度, 计算并设置 ai_paned 的最小宽度,
    // 防止窗口缩小到导致面板内容被裁剪.
    private void update_window_min_size () {
        int min_w = 0;

        // ai_paned 自身的 margin
        min_w += ai_paned.get_margin_start () + ai_paned.get_margin_end ();

        // AI 边栏 (可见时才计入)
        if (ai_sidebar.visible) {
            min_w += ai_sidebar.get_margin_start () + ai_sidebar.get_margin_end ();
            min_w += 280; // ai_sidebar 的 width-request
            min_w += PANED_SEP; // ai_paned 分隔条
        }

        // outer_paned margin
        min_w += outer_paned.get_margin_start () + outer_paned.get_margin_end ();

        // 左栏
        var left_child = outer_paned.get_start_child ();
        if (left_child != null) {
            min_w += left_child.get_margin_start () + left_child.get_margin_end ();
            min_w += left_min_width;
            min_w += PANED_SEP; // outer_paned 分隔条
        }

        // inner_paned margin
        min_w += inner_paned.get_margin_start () + inner_paned.get_margin_end ();

        // 中栏
        var center_child = inner_paned.get_start_child ();
        if (center_child != null) {
            min_w += center_child.get_margin_start () + center_child.get_margin_end ();
            min_w += center_min_width;
            min_w += PANED_SEP; // inner_paned 分隔条
        }

        // 右栏
        var right_child = inner_paned.get_end_child ();
        if (right_child != null) {
            min_w += right_child.get_margin_start () + right_child.get_margin_end ();
            min_w += right_min_width;
        }

        ai_paned.set_size_request (min_w, -1);
    }

    private void measure_pane_minimums () {
        int min, nat;

        var left_child = outer_paned.get_start_child ();
        if (left_child != null) {
            left_child.measure (Gtk.Orientation.HORIZONTAL, -1, out min, out nat, null, null);
            left_min_width = int.max (min, 200);
        }

        var center_child = inner_paned.get_start_child ();
        if (center_child != null) {
            center_child.measure (Gtk.Orientation.HORIZONTAL, -1, out min, out nat, null, null);
            center_min_width = int.max (min, 400);
        }

        var right_child = inner_paned.get_end_child ();
        if (right_child != null) {
            right_child.measure (Gtk.Orientation.HORIZONTAL, -1, out min, out nat, null, null);
            right_min_width = int.max (min, 200);
        }
    }

    private void clamp_outer_paned_position () {
        if (_clamping_outer) return;
        _clamping_outer = true;
        var pw = outer_paned.get_width ();
        if (pw <= 0) {
            _clamping_outer = false;
            return;
        }
        var pos = outer_paned.position;
        var cw = pw - outer_paned.get_margin_start () - outer_paned.get_margin_end ();

        // 子项 margin: measure() 返回的 min 不含 margin, 需额外计入
        var left_child = outer_paned.get_start_child ();
        int left_margin = (left_child != null)
            ? left_child.get_margin_start () + left_child.get_margin_end () : 0;

        var center_child = inner_paned.get_start_child ();
        var right_child = inner_paned.get_end_child ();
        int center_margin = (center_child != null)
            ? center_child.get_margin_start () + center_child.get_margin_end () : 0;
        int right_margin = (right_child != null)
            ? right_child.get_margin_start () + right_child.get_margin_end () : 0;
        int inner_margin = inner_paned.get_margin_start () + inner_paned.get_margin_end ();

        var min_pos = left_min_width + left_margin;
        // inner_paned 需要的最小宽度 = 自身 margin + 中栏(含margin) + 分隔条 + 右栏(含margin)
        var inner_needed = inner_margin + center_margin + center_min_width
            + PANED_SEP + right_margin + right_min_width;
        var max_pos = int.max (min_pos, cw - PANED_SEP - inner_needed);
        if (pos < min_pos) {
            outer_paned.position = min_pos;
        } else if (pos > max_pos) {
            outer_paned.position = max_pos;
        }

        // 同步 clamp inner_paned
        var inner_width = cw - PANED_SEP - outer_paned.position;
        var icw = inner_width - inner_paned.get_margin_start () - inner_paned.get_margin_end ();
        var ipos = inner_paned.position;
        var imin = center_min_width + center_margin;
        var imax = int.max (imin, icw - PANED_SEP - right_min_width - right_margin);
        _clamping_inner_from_outer = true;
        if (ipos < imin) {
            inner_paned.position = imin;
        } else if (ipos > imax) {
            inner_paned.position = imax;
        }
        _clamping_inner_from_outer = false;
        _clamping_outer = false;
    }

    private void clamp_inner_paned_position () {
        if (_clamping_inner_from_outer) return;
        var pw = inner_paned.get_width ();
        if (pw <= 0) return;
        var pos = inner_paned.position;
        var cw = pw - inner_paned.get_margin_start () - inner_paned.get_margin_end ();

        var center_child = inner_paned.get_start_child ();
        var right_child = inner_paned.get_end_child ();
        int center_margin = (center_child != null)
            ? center_child.get_margin_start () + center_child.get_margin_end () : 0;
        int right_margin = (right_child != null)
            ? right_child.get_margin_start () + right_child.get_margin_end () : 0;

        var min_pos = center_min_width + center_margin;
        var max_pos = int.max (min_pos, cw - PANED_SEP - right_min_width - right_margin);
        if (pos < min_pos) {
            inner_paned.position = min_pos;
        } else if (pos > max_pos) {
            inner_paned.position = max_pos;
        }
    }

    // ─── Keyboard Shortcuts ───────────────────────────────────────────────

    private void setup_shortcuts () {
        // 使用 GAction + set_accels_for_action 替代 ShortcutController,
        // 避免 GTK4 bug (#6246): widget 销毁后 controller 仍留在 manager 中导致崩溃

        var act_generate = new GLib.SimpleAction ("generate", null);
        act_generate.activate.connect (() => on_generate_clicked ());
        this.add_action (act_generate);

        var act_generate_clipboard = new GLib.SimpleAction ("generate_to_clipboard", null);
        act_generate_clipboard.activate.connect (() => on_generate_to_clipboard_clicked ());
        this.add_action (act_generate_clipboard);

        var act_undo = new GLib.SimpleAction ("undo", null);
        act_undo.activate.connect (() => on_undo ());
        this.add_action (act_undo);

        var act_redo = new GLib.SimpleAction ("redo", null);
        act_redo.activate.connect (() => on_redo ());
        this.add_action (act_redo);

        var act_clear = new GLib.SimpleAction ("clear_items", null);
        act_clear.activate.connect (() => on_clear_items ());
        this.add_action (act_clear);

        var act_delete = new GLib.SimpleAction ("delete_item", null);
        act_delete.activate.connect (() => on_delete_item ());
        this.add_action (act_delete);

        var act_move_up = new GLib.SimpleAction ("move_up", null);
        act_move_up.activate.connect (() => on_move_up ());
        this.add_action (act_move_up);

        var act_move_down = new GLib.SimpleAction ("move_down", null);
        act_move_down.activate.connect (() => on_move_down ());
        this.add_action (act_move_down);

        var act_add_external = new GLib.SimpleAction ("add_external_files", null);
        act_add_external.activate.connect (() => on_add_external_files ());
        this.add_action (act_add_external);

        var act_insert = new GLib.SimpleAction ("insert_text", null);
        act_insert.activate.connect (() => insert_text (true));
        this.add_action (act_insert);

        var act_insert_no_header = new GLib.SimpleAction ("insert_text_no_header", null);
        act_insert_no_header.activate.connect (() => insert_text (false));
        this.add_action (act_insert_no_header);

        var act_toggle_ai = new GLib.SimpleAction ("toggle_ai_panel", null);
        act_toggle_ai.activate.connect (() => toggle_ai_panel ());
        this.add_action (act_toggle_ai);

        // 延迟注册快捷键, 等待 application 就绪
        GLib.Idle.add (() => {
            var app = this.application;
            if (app != null) {
                app.set_accels_for_action ("win.generate", { "<Control>g" });
                app.set_accels_for_action ("win.generate_to_clipboard", { "<Control><Shift>c" });
                app.set_accels_for_action ("win.undo", { "<Control>z" });
                app.set_accels_for_action ("win.redo", { "<Control><Shift>z" });
                app.set_accels_for_action ("win.clear_items", { "<Control>n" });
                app.set_accels_for_action ("win.delete_item", { "Delete" });
                app.set_accels_for_action ("win.move_up", { "<Control>Up" });
                app.set_accels_for_action ("win.move_down", { "<Control>Down" });
                app.set_accels_for_action ("win.add_external_files", { "<Control>e" });
                app.set_accels_for_action ("win.insert_text", { "<Control>i" });
                app.set_accels_for_action ("win.insert_text_no_header", { "<Control><Shift>i" });
                app.set_accels_for_action ("win.toggle_ai_panel", { "<Control>j" });
            }
            return GLib.Source.REMOVE;
        });
    }

    public CliController create_cli_from_state () {
        var cli = new CliController ();
        cli.initialize_from_state (
            work_dir,
            items,
            checked_paths,
            check_model.checked_dirs,
            common_phrases,
            use_absolute,
            show_header
        );
        return cli;
    }

    public void apply_cli_operations (CliController cli) {
        push_undo_state ();
        bool work_dir_changed = false;
        if (cli.work_dir != null) {
            if (work_dir == null || cli.work_dir.get_path () != work_dir.get_path ()) {
                work_dir_changed = true;
            }
        }

        items = cli.items;
        checked_paths = cli.checked_paths;
        common_phrases = cli.common_phrases;
        use_absolute = cli.use_absolute;
        show_header = cli.show_header;
        radio_absolute_path.notify["active"].disconnect (on_path_mode_changed);
        radio_relative_path.notify["active"].disconnect (on_path_mode_changed);
        check_write_header.notify["active"].disconnect (on_header_check_changed);
        radio_absolute_path.active = use_absolute;
        radio_relative_path.active = !use_absolute;
        check_write_header.active = show_header;
        radio_absolute_path.notify["active"].connect (on_path_mode_changed);
        radio_relative_path.notify["active"].connect (on_path_mode_changed);
        check_write_header.notify["active"].connect (on_header_check_changed);

        if (work_dir_changed) {
            work_dir = cli.work_dir;
            update_subtitle (work_dir.get_path ());
            root_store.remove_all ();
            var root_item = new DirectoryItem (work_dir.get_basename (), work_dir.get_path (), true);
            root_store.append (root_item);
            check_model.replace_from (checked_paths, cli.checked_dirs);
            load_directory_children_lazy (root_item);
            GLib.Idle.add (() => {
                var root_row = tree_list_model.get_item (0) as Gtk.TreeListRow;
                if (root_row != null) {
                    root_row.set_expanded (true);
                }
                return Source.REMOVE;
            });
            search_entry.visible = true;
        } else if (work_dir != null && root_store.get_n_items () > 0) {
            check_model.replace_from (checked_paths, cli.checked_dirs);
            foreach (var path in checked_paths.get_keys ()) {
                ensure_path_loaded (path);
            }
            refresh_all_tree_states ();
        }

        refresh_list ();

        if (cli.operation_messages.length > 0) {
            var messages = new GenericArray<string> ();
            for (int i = 0; i < cli.operation_messages.length; i++) {
                messages.add (cli.operation_messages.get (i));
            }
            GLib.Idle.add (() => {
                for (int i = 0; i < messages.length; i++) {
                    var toast = new Adw.Toast (messages.get (i));
                    toast.timeout = 2;
                    toast_overlay.add_toast (toast);
                }
                return Source.REMOVE;
            });
        }
    }

    public void initialize_from_cli (CliController cli) {
        apply_cli_operations (cli);
    }

    // ─── Tree View ───────────────────────────────────────────────────────

    private void remove_items_by_path (string path) {
        for (int i = items.length - 1; i >= 0; i--) {
            var item = items.get (i);
            if (item.item_type == "file" && item.file_path == path) {
                items.remove_index (i);
            }
        }
    }

    // 检查 items 中是否已存在指定路径的文件项 (含 force_absolute 外部文件)
    private bool path_in_items (string path) {
        for (int i = 0; i < items.length; i++) {
            var item = items.get (i);
            if (item.item_type == "file" && item.file_path == path) {
                return true;
            }
        }
        return false;
    }

    private async void on_open_folder_clicked () {
        var dialog = new Gtk.FileDialog ();
        dialog.title = _("选择工作文件夹");
        try {
            var folder = yield dialog.select_folder (this, null);
            this.work_dir = folder;

            update_subtitle (folder.get_path ());

            root_store.remove_all ();
            checked_paths.remove_all ();
            items.remove_range (0, items.length);
            check_model.clear ();
            undo_manager.clear ();
            update_undo_redo_buttons ();

            var root_item = new DirectoryItem (folder.get_basename (), folder.get_path (), true);
            root_store.append (root_item);

            load_directory_children_lazy (root_item);
            search_entry.visible = true;

            var root_row = tree_list_model.get_item (0) as Gtk.TreeListRow;
            if (root_row != null) {
                root_row.set_expanded (true);
            }

            GLib.Idle.add (() => {
                refresh_list ();
                return Source.REMOVE;
            });
        } catch (Error e) {
            warning ("文件夹选择失败: %s", e.message);
        }
    }

    // 后台线程: 枚举单个目录的子条目 (纯文件系统 I/O, 不访问实例状态)
    private static GenericArray<DirChildInfo> enumerate_dir_children (string dir_path, GLib.Cancellable? cancellable = null) {
        var dirs = new GenericArray<DirChildInfo> ();
        var files = new GenericArray<DirChildInfo> ();
        var dir = File.new_for_path (dir_path);
        if (!dir.query_exists ()) return new GenericArray<DirChildInfo> ();
        try {
            var enumerator = dir.enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NONE
            );
            FileInfo info;
            while ((info = enumerator.next_file ()) != null) {
                if (cancellable != null && cancellable.is_cancelled ()) break;
                var child_path = dir.get_child (info.get_name ()).get_path ();
                bool is_dir = info.get_file_type () == FileType.DIRECTORY;
                var entry = new DirChildInfo (info.get_name (), child_path, is_dir);
                if (is_dir) {
                    dirs.add (entry);
                } else {
                    files.add (entry);
                }
            }
        } catch (Error e) {
            warning ("enumerate_dir_children: %s", e.message);
        }
        // 排序: 点文件优先, 然后大小写不敏感
        dirs.sort ((a, b) => {
            bool a_dot = a.name.has_prefix (".");
            bool b_dot = b.name.has_prefix (".");
            if (a_dot != b_dot) return a_dot ? -1 : 1;
            return a.name.casefold ().collate (b.name.casefold ());
        });
        files.sort ((a, b) => {
            bool a_dot = a.name.has_prefix (".");
            bool b_dot = b.name.has_prefix (".");
            if (a_dot != b_dot) return a_dot ? -1 : 1;
            return a.name.casefold ().collate (b.name.casefold ());
        });
        var result = new GenericArray<DirChildInfo> ();
        for (int i = 0; i < dirs.length; i++) result.add (dirs.get (i));
        for (int i = 0; i < files.length; i++) result.add (files.get (i));
        return result;
    }

    // 同步版本: 直接在调用线程加载子节点 (用于需要立即获取结果的场景, 如 ensure_path_loaded)
    private void load_directory_children_sync (DirectoryItem parent_item) {
        if (!parent_item.is_dir) return;
        var entries = enumerate_dir_children (parent_item.path);
        for (int i = 0; i < entries.length; i++) {
            var e = entries.get (i);
            parent_item.children.append (new DirectoryItem (e.name, e.path, e.is_dir));
        }
        refresh_subtree_states (parent_item);
    }

    // 异步版本: 后台线程枚举目录, 完成后通过 Idle 批量更新 UI, 避免阻塞主线程
    private void load_directory_children_lazy (DirectoryItem parent_item) {
        if (!parent_item.is_dir) return;
        if (parent_item.children_loading) return;
        if (window_closing) return;
        parent_item.children_loading = true;
        string dir_path = parent_item.path;
        var cancellable = app_cancellable;
        try {
            GLib.Thread<void*>? thread = null;
            thread = new Thread<void*> ("load-dir-children", () => {
                var entries = enumerate_dir_children (dir_path, cancellable);
                // 分批流式插入 (Idle 回调在主线程执行, 防止大项目卡死 UI)
                apply_directory_children_lazy (parent_item, entries, thread);
                return null;
            });
            bg_threads.add (thread);
        } catch (ThreadError e) {
            parent_item.children_loading = false;
            warning ("Failed to create load-dir-children thread: %s", e.message);
            load_directory_children_sync (parent_item);
        }
    }

    // 分批流式插入子节点 (每帧 100 个), 防止加载大项目时卡死 UI.
    // 在主线程通过 Idle 分批执行; 完成后刷新子树状态并清理后台线程引用.
    // 边界检查确保父容器没有在中途被销毁.
    private void apply_directory_children_lazy (DirectoryItem parent,
                                                 GenericArray<DirChildInfo> children,
                                                 GLib.Thread<void*>? thread = null) {
        int total_items = (int) children.length;
        int chunk_size = 100;
        int current_offset = 0;

        GLib.Idle.add (() => {
            // 窗口关闭时不再更新 UI, 直接清理线程引用
            if (window_closing) {
                if (thread != null) bg_threads.remove (thread);
                return GLib.Source.REMOVE;
            }
            // 边界检查: 父容器可能在中途被销毁
            if (parent == null || parent.children == null) {
                if (thread != null) bg_threads.remove (thread);
                return GLib.Source.REMOVE;
            }

            int limit = int.min (current_offset + chunk_size, total_items);
            for (int i = current_offset; i < limit; i++) {
                var child_info = children.get (i);
                var child_item = new DirectoryItem (child_info.name, child_info.path, child_info.is_dir);
                parent.children.append (child_item);
            }

            current_offset = limit;
            if (current_offset < total_items) {
                return GLib.Source.CONTINUE; // 未完成, 下一帧主循环继续分批加载
            }

            // 加载完毕: 刷新子树勾选状态, 清理后台线程引用
            parent.children_loading = false;
            refresh_subtree_states (parent);
            if (thread != null) bg_threads.remove (thread);
            return GLib.Source.REMOVE;
        });
    }

    // AI 工具入口: 设置某个文件路径的勾选状态
    private void set_tree_item_check (string abs_path, bool checked) {
        // 1. 更新 check_model (单一真相源)
        if (checked) {
            check_model.add_files ({ abs_path });
            if (!(abs_path in checked_paths)) {
                checked_paths.insert (abs_path, true);
                items.add (new ItemData ("file", abs_path, null, false));
            }
        } else {
            check_model.remove_files ({ abs_path });
            if (abs_path in checked_paths) {
                checked_paths.remove (abs_path);
                remove_items_by_path (abs_path);
            }
        }

        // 2. 触发懒加载, 确保该路径的父目录已加载 (这样 UI 才能显示)
        ensure_path_loaded (abs_path);

        // 3. 刷新整个可见树的三态
        refresh_all_tree_states ();
        refresh_list ();
    }

    // 确保指定文件路径的所有父目录都已加载到树中
    private void ensure_path_loaded (string abs_path) {
        if (work_dir == null || !abs_path.has_prefix (work_dir.get_path () + "/")) return;
        if (root_store.get_n_items () == 0) return;

        string rel = abs_path.substring (work_dir.get_path ().length + 1);
        string[] parts = rel.split ("/");
        var current = (DirectoryItem) root_store.get_item (0);

        for (int p = 0; p < parts.length - 1; p++) {
            bool found = false;
            for (uint c = 0; c < current.children.get_n_items (); c++) {
                var child = (DirectoryItem) current.children.get_item (c);
                if (child.name == parts[p]) {
                    current = child;
                    found = true;
                    break;
                }
            }
            if (!found) {
                load_directory_children_sync (current);
                for (uint c = 0; c < current.children.get_n_items (); c++) {
                    var child = (DirectoryItem) current.children.get_item (c);
                    if (child.name == parts[p]) {
                        current = child;
                        found = true;
                        break;
                    }
                }
                if (!found) return;
            }
        }
        // 确保目标文件所在目录也已加载
        bool target_found = false;
        for (uint c = 0; c < current.children.get_n_items (); c++) {
            var child = (DirectoryItem) current.children.get_item (c);
            if (child.path == abs_path) {
                target_found = true;
                break;
            }
        }
        if (!target_found) {
            load_directory_children_lazy (current);
        }
    }

    // ─── Queue List ──────────────────────────────────────────────────────

    private void refresh_list () {
        bool had_selection = (int)queue_selection.selected >= 0;
        uint old_selected = queue_selection.selected;
        uint n = queue_store.get_n_items ();
        int m = items.length;

        // 差分同步: 只替换发生变化的段, 避免全量重建
        // 1. 寻找第一个不一致的索引
        int first_diff = -1;
        int min_len = (int) uint.min (n, (uint) m);
        for (int i = 0; i < min_len; i++) {
            if (queue_store.get_item (i) != items.get (i)) {
                first_diff = i;
                break;
            }
        }

        // 2. 根据差异类型执行最小化 splice
        if (first_diff == -1) {
            if (n == m) {
                // 完全一致，无需任何操作
            } else if (n < m) {
                // 仅尾部追加
                GLib.Object[] adds = new GLib.Object[m - n];
                for (int i = (int)n; i < m; i++) adds[i - (int)n] = items.get (i);
                queue_store.splice (n, 0, adds);
            } else {
                // 仅尾部删除
                queue_store.splice (m, n - m, {});
            }
        } else {
            // 3. 存在中间差异，寻找最后一个不一致的索引
            int last_diff_old = (int)n - 1;
            int last_diff_new = m - 1;
            while (last_diff_old >= first_diff && last_diff_new >= first_diff) {
                if (queue_store.get_item (last_diff_old) == items.get (last_diff_new)) {
                    last_diff_old--;
                    last_diff_new--;
                } else {
                    break;
                }
            }

            int replace_len_old = last_diff_old - first_diff + 1;
            int replace_len_new = last_diff_new - first_diff + 1;

            GLib.Object[] adds = new GLib.Object[replace_len_new];
            for (int i = 0; i < replace_len_new; i++) {
                adds[i] = items.get (first_diff + i);
            }
            // 仅替换发生变化的中间段
            queue_store.splice (first_diff, replace_len_old, adds);
        }

        // 4. 恢复选择状态
        if (had_selection && old_selected < items.length) {
            queue_selection.selected = old_selected;
        } else if (items.length > 0) {
            queue_selection.selected = 0;
        }

        update_queue_buttons ();

        int sel = (int)queue_selection.selected;
        if (sel >= 0 && sel < items.length) {
            update_preview (items.get (sel));
        } else {
            preview_view.get_buffer ().set_text ("", -1);
        }
    }

    private void update_queue_buttons () {
        int sel = (int)queue_selection.selected;
        bool has_selection = sel >= 0 && sel < items.length;
        btn_add_text_above.sensitive = has_selection;
        btn_add_text_below.sensitive = has_selection;
        btn_move_up.sensitive = has_selection && items.length > 1 && sel > 0;
        btn_move_down.sensitive = has_selection && items.length > 1 && sel < items.length - 1;
        btn_delete.sensitive = has_selection;
    }

    private void on_add_external_files () {
        var dialog = new Gtk.FileDialog ();
        dialog.title = _("选择外部文件");
        dialog.open_multiple.begin (this, null, (obj, res) => {
            try {
                var files = dialog.open_multiple.end (res);
                if (files.get_n_items () == 0) return;
                push_undo_state ();
                for (uint i = 0; i < files.get_n_items (); i++) {
                    var file = (File) files.get_item (i);
                    var path = file.get_path ();
                    items.add (new ItemData ("file", path, null, true));
                }
                refresh_list ();
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED) return;
                warning ("添加文件失败: %s", e.message);
            }
        });
    }

    private void insert_text (bool above, string? existing_text = null, owned ItemData? edit_data = null) {
        var window = new Adw.Window ();
        window.set_transient_for (this);
        window.set_modal (true);
        window.set_default_size (450, 350);
        window.set_title (edit_data != null ? _("编辑文字") : _("插入自定义文字"));

        var toolbar_view = new Adw.ToolbarView ();
        window.set_content (toolbar_view);

        var header_bar = new Adw.HeaderBar ();
        header_bar.set_decoration_layout ("");
        toolbar_view.add_top_bar (header_bar);

        var cancel_btn = new Gtk.Button ();
        cancel_btn.set_label (_("取消"));
        header_bar.pack_start (cancel_btn);

        var ok_btn = new Gtk.Button ();
        ok_btn.set_label (_("确定"));
        ok_btn.add_css_class ("suggested-action");
        header_bar.pack_end (ok_btn);

        var btn_size_group = new Gtk.SizeGroup (Gtk.SizeGroupMode.HORIZONTAL);
        btn_size_group.add_widget (cancel_btn);
        btn_size_group.add_widget (ok_btn);

        var phrases_btn = new Gtk.Button ();
        phrases_btn.set_label (_("常用语"));
        header_bar.pack_end (phrases_btn);

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        content.set_margin_top (0);
        content.set_margin_start (12);
        content.set_margin_end (12);
        content.set_margin_bottom (12);

        var frame = new Gtk.Frame (null);
        frame.add_css_class ("text-input-frame");

        var scrolled = new Gtk.ScrolledWindow ();
        scrolled.set_vexpand (true);
        scrolled.set_min_content_height (120);

        var text_view = new Gtk.TextView ();
        text_view.set_wrap_mode (Gtk.WrapMode.WORD_CHAR);
        text_view.set_top_margin (12);
        text_view.set_bottom_margin (12);
        text_view.set_left_margin (12);
        text_view.set_right_margin (12);

        if (existing_text != null) {
            text_view.get_buffer ().set_text (existing_text, -1);
        }

        scrolled.set_child (text_view);
        frame.set_child (scrolled);
        content.append (frame);

        toolbar_view.set_content (content);

        cancel_btn.clicked.connect (() => {
            window.destroy ();
        });

        ok_btn.clicked.connect (() => {
            var buffer = text_view.get_buffer ();
            Gtk.TextIter start, end;
            buffer.get_start_iter (out start);
            buffer.get_end_iter (out end);
            var text = buffer.get_text (start, end, false);
            if (text != null && text.strip () != "") {
                if (edit_data != null) {
                    // Bug #12 修复: 编辑文本项时记录 undo delta
                    int edit_index = find_item_index (edit_data);
                    string old_content = edit_data.content;
                    edit_data.content = text;
                    if (edit_index >= 0) {
                        push_undo_delta (new UndoDelta.for_edit (edit_index, old_content, text));
                    }
                    refresh_list ();
                    update_preview (edit_data);
                } else {
                    do_insert_text (text, above);
                }
            }
            window.destroy ();
        });

        if (edit_data != null) {
            phrases_btn.visible = false;
        } else {
            phrases_btn.clicked.connect (() => {
                window.destroy ();
                get_phrases_picker ().show_picker (above);
            });
        }

        window.present ();
    }

    private void do_insert_text (string text, bool above) {
        int current = (int)queue_selection.selected;
        int index;
        if (current < 0) {
            index = above ? 0 : (int) items.length;
        } else {
            index = above ? current : current + 1;
        }
        var inserted = new GenericArray<ItemData> ();
        var item = new ItemData ("text", null, text, false);
        items.insert (index, item);
        inserted.add (item);
        push_undo_delta (new UndoDelta.for_insert (index, inserted));
        refresh_list ();
    }

    private void on_move_up () {
        int index = (int)queue_selection.selected;
        if (index < 0) return;
        if (index <= 0) return;
        var tmp = items.get (index);
        items.set (index, items.get (index - 1));
        items.set (index - 1, tmp);
        push_undo_delta (new UndoDelta.for_swap (index - 1, index));
        refresh_list ();
        select_queue_row (index - 1);
    }

    private void on_move_down () {
        int index = (int)queue_selection.selected;
        if (index < 0) return;
        if (index >= items.length - 1) return;
        var tmp = items.get (index);
        items.set (index, items.get (index + 1));
        items.set (index + 1, tmp);
        push_undo_delta (new UndoDelta.for_swap (index, index + 1));
        refresh_list ();
        select_queue_row (index + 1);
    }

    private void on_delete_item () {
        int index = (int)queue_selection.selected;
        if (index < 0) return;
        var data = items.get (index);
        var removed = new GenericArray<ItemData> ();
        removed.add (data);
        var rm_checked = new GenericArray<string> ();
        if (data.item_type == "file" && !data.force_absolute) {
            if (data.file_path in checked_paths) {
                rm_checked.add (data.file_path);
                checked_paths.remove (data.file_path);
                set_tree_item_check (data.file_path, false);
            }
        }
        items.remove_index (index);
        push_undo_delta (new UndoDelta.for_remove (index, removed, rm_checked));
        refresh_list ();
    }

    private void on_clear_items () {
        push_undo_state ();
        items.remove_range (0, items.length);
        checked_paths.remove_all ();
        check_model.clear ();
        refresh_all_tree_states ();
        refresh_list ();
    }

    private void select_queue_row (int index) {
        if (index >= 0 && index < items.length) {
            queue_selection.selected = index;
        }
    }

    private void on_queue_selection_changed (uint position, uint n_items) {
        update_queue_buttons ();

        int sel = (int)queue_selection.selected;
        if (sel < 0 || sel >= items.length) {
            return;
        }
        update_preview (items.get (sel));
        clear_tree_selection ();
    }

    private void on_queue_row_activated (uint position) {
        int index = (int)position;
        if (index < 0 || index >= items.length) return;
        var data = items.get (index);
        if (data.item_type == "text") {
            insert_text (false, data.content, data);
        }
    }

    private void update_preview (ItemData item) {
        var buffer = preview_view.get_buffer ();
        if (item.item_type == "text") {
            buffer.set_text (item.content.make_valid (), -1);
        } else {
            try {
                uint8[] file_data;
                FileUtils.get_data (item.file_path, out file_data);
                var preview = EncodingHelper.decode_to_utf8 (file_data);
                if (preview.length > 2000) {
                    preview = truncate_utf8 (preview, 2000);
                    preview += "\n\n... [预览截断]";
                }
                buffer.set_text (preview, -1);
            } catch (Error e) {
                buffer.set_text ("[读取错误: " + e.message + "]", -1);
            }
        }
    }

    // ─── Options ─────────────────────────────────────────────────────────

    private void on_path_mode_changed () {
        bool old_abs = use_absolute;
        bool old_hdr = show_header;
        use_absolute = radio_absolute_path.active;
        push_undo_delta (new UndoDelta.for_absolute (old_abs, use_absolute, old_hdr, show_header));
        refresh_list ();
    }

    private void on_header_check_changed () {
        bool old_val = show_header;
        show_header = check_write_header.active;
        push_undo_delta (new UndoDelta.for_header (old_val, show_header));
    }

    // ─── Generate ────────────────────────────────────────────────────────

    private void on_generate_clicked () {
        if (items.length == 0) {
            show_toast (_("编排列表为空，请先勾选文件或添加文字内容"));
            return;
        }

        var dialog = new Gtk.FileDialog ();
        dialog.title = _("保存合并文本");
        var filter = new Gtk.FileFilter ();
        filter.name = _("文本文件 (*.txt)");
        filter.add_pattern ("*.txt");
        var filters_list = new GLib.ListStore (typeof (Gtk.FileFilter));
        filters_list.append (filter);
        dialog.set_filters (filters_list);

        dialog.save.begin (this, null, (obj, res) => {
            try {
                var file = dialog.save.end (res);
                var path = file.get_path ();
                if (!path.has_suffix (".txt")) {
                    path += ".txt";
                }
                FileGenerator.generate_file (path, items, use_absolute, show_header, work_dir);
                show_toast (_("合并文本已保存"));
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED || e is Gtk.DialogError.DISMISSED) {
                    show_toast (_("保存已取消"));
                    return;
                }
                show_error (_("保存失败"), e.message);
            }
        });
    }

    private void on_generate_to_clipboard_clicked () {
        if (items.length == 0) {
            show_toast (_("编排列表为空，请先勾选文件或添加文字内容"));
            return;
        }

        try {
            FileGenerator.generate_to_clipboard (items, use_absolute, show_header, work_dir, this.get_display ());
            show_toast (_("合并文本已复制到剪贴板"));
        } catch (Error e) {
            show_error (_("复制失败"), e.message);
        }
    }

    // ─── Project ─────────────────────────────────────────────────────────

    public void on_open_project () {
        var dialog = new Gtk.FileDialog ();
        dialog.title = _("打开项目");
        var filter = new Gtk.FileFilter ();
        filter.name = _("项目文件 (*.fcol, *.fcol.json, *.project.json)");
        filter.add_pattern ("*.fcol");
        filter.add_pattern ("*.fcol.json");
        filter.add_pattern ("*.project.json");
        var filters_list = new GLib.ListStore (typeof (Gtk.FileFilter));
        filters_list.append (filter);
        dialog.set_filters (filters_list);

        dialog.open.begin (this, null, (obj, res) => {
            try {
                var file = dialog.open.end (res);
                File? loaded_work_dir;
                string? loaded_project_file;
                bool loaded_use_absolute;
                bool loaded_show_header;

                var loaded_checked_dirs = new HashTable<string, bool> (str_hash, str_equal);
                ProjectManager.load_project_file (
                    file.get_path (),
                    items,
                    checked_paths,
                    loaded_checked_dirs,
                    common_phrases,
                    out loaded_work_dir,
                    out loaded_project_file,
                    out loaded_use_absolute,
                    out loaded_show_header
                );

                work_dir = loaded_work_dir;
                project_file = loaded_project_file;
                use_absolute = loaded_use_absolute;
                show_header = loaded_show_header;

                if (work_dir != null) {
                    update_subtitle (work_dir.get_path ());

                    root_store.remove_all ();

                    check_model.replace_from (checked_paths, loaded_checked_dirs);

                    var root_item = new DirectoryItem (work_dir.get_basename (), work_dir.get_path (), true);
                    root_store.append (root_item);

                    load_directory_children_lazy (root_item);
                    search_entry.visible = true;

                    var root_row = tree_list_model.get_item (0) as Gtk.TreeListRow;
                    if (root_row != null) {
                        root_row.set_expanded (true);
                    }

                    GLib.Idle.add (() => {
                        refresh_list ();
                        return Source.REMOVE;
                    });
                } else {
                    check_model.replace_from (checked_paths, loaded_checked_dirs);
                    update_subtitle (null);
                }

                radio_absolute_path.notify["active"].disconnect (on_path_mode_changed);
                radio_relative_path.notify["active"].disconnect (on_path_mode_changed);
                check_write_header.notify["active"].disconnect (on_header_check_changed);
                radio_absolute_path.active = use_absolute;
                radio_relative_path.active = !use_absolute;
                check_write_header.active = show_header;
                radio_absolute_path.notify["active"].connect (on_path_mode_changed);
                radio_relative_path.notify["active"].connect (on_path_mode_changed);
                check_write_header.notify["active"].connect (on_header_check_changed);
                undo_manager.clear ();
                update_undo_redo_buttons ();
                refresh_list ();
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED) return;
                show_error (_("打开失败"), e.message);
            }
        });
    }

    public void on_save_project () {
        if (project_file == null) {
            on_save_project_as ();
            return;
        }
        try {
            ProjectManager.write_project_file (
                project_file, work_dir, use_absolute, show_header,
                items, checked_paths, check_model.checked_dirs, common_phrases
            );
            show_toast (_("项目文件已更新"));
        } catch (Error e) {
            show_error (_("保存失败"), e.message);
        }
    }

    public void on_save_project_as () {
        var dialog = new Gtk.FileDialog ();
        dialog.title = _("保存项目");
        var filter = new Gtk.FileFilter ();
        filter.name = _("项目文件 (*.fcol)");
        filter.add_pattern ("*.fcol");
        var filters_list = new GLib.ListStore (typeof (Gtk.FileFilter));
        filters_list.append (filter);
        dialog.set_filters (filters_list);

        dialog.save.begin (this, null, (obj, res) => {
            try {
                var file = dialog.save.end (res);
                var path = file.get_path ();
                if (!path.has_suffix (".fcol")) {
                    path += ".fcol";
                }
                project_file = path;
                ProjectManager.write_project_file (
                    project_file, work_dir, use_absolute, show_header,
                    items, checked_paths, check_model.checked_dirs, common_phrases
                );
                show_toast (_("项目文件已保存"));
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED) return;
                show_error (_("保存失败"), e.message);
            }
        });
    }

    // ─── Subtitle ────────────────────────────────────────────────────────

    private void cache_title_widget () {
        if (_title_widget == null) {
            var header = get_titlebar () as Adw.HeaderBar;
            if (header != null && header.title_widget is Adw.WindowTitle) {
                _title_widget = (Adw.WindowTitle) header.title_widget;
            } else {
                _title_widget = find_window_title (this);
            }
        }
    }

    private void update_subtitle (string? text) {
        string subtitle = text ?? _("未设置工作目录");

        title = (text != null) ? text : _("FileCollector");

        if (_title_widget == null) {
            cache_title_widget ();
        }
        if (_title_widget != null) {
            _title_widget.set_subtitle (subtitle);
        }
    }

    private Adw.WindowTitle? find_window_title (Gtk.Widget root) {
        if (root is Adw.WindowTitle) {
            return (Adw.WindowTitle) root;
        }

        var child = root.get_first_child ();
        while (child != null) {
            var found = find_window_title (child);
            if (found != null) {
                return found;
            }
            child = child.get_next_sibling ();
        }
        return null;
    }

    // ─── Dialogs ─────────────────────────────────────────────────────────

    public void on_about () {
        var about = new Adw.AboutDialog ();
        about.application_name = _("FileCollector");
        about.version = Config.VERSION;
        about.application_icon = "com.github.samfic.filecollector";
        about.comments = _("文件收集与编排工具");
        about.developers = { "Sam-Fic" };
        about.website = "https://github.com/Sam-Fic/filecollector-gnome";
        about.license_type = Gtk.License.MIT_X11;

        about.present (this);
    }

    public void on_show_shortcuts () {
        try {
            var builder = new Gtk.Builder ();
            builder.set_translation_domain (Config.GETTEXT_PACKAGE);
            builder.add_from_string (build_shortcuts_ui (), -1);
            var win = builder.get_object ("sw") as Gtk.ShortcutsWindow;
            if (win == null) return;
            win.set_transient_for (this);
            win.present ();
        } catch (Error e) {
            warning ("Failed to show shortcuts: %s", e.message);
        }
    }

    private string build_shortcuts_ui () {
        _("常用操作");
        _("列表操作");
        _("应用程序");
        _("清空列表");
        _("生成到剪贴板");
        _("打开项目");
        _("切换 AI 面板");
        _("关于");
        _("退出");
        return """<?xml version="1.0" encoding="UTF-8"?>
<interface>
  <object class="GtkShortcutsWindow" id="sw">
    <property name="modal">true</property>
    <property name="title" translatable="yes">键盘快捷键</property>
    <child>
      <object class="GtkShortcutsSection">
        <child>
          <object class="GtkShortcutsGroup">
            <property name="title" translatable="yes">常用操作</property>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">撤销</property>
                <property name="accelerator">&lt;Control&gt;z</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">重做</property>
                <property name="accelerator">&lt;Control&gt;&lt;Shift&gt;z</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">打开项目</property>
                <property name="accelerator">&lt;Control&gt;o</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">保存项目</property>
                <property name="accelerator">&lt;Control&gt;s</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">清空列表</property>
                <property name="accelerator">&lt;Control&gt;n</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">添加外部文件</property>
                <property name="accelerator">&lt;Control&gt;e</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">切换 AI 面板</property>
                <property name="accelerator">&lt;Control&gt;j</property>
              </object>
            </child>
          </object>
        </child>
        <child>
          <object class="GtkShortcutsGroup">
            <property name="title" translatable="yes">列表操作</property>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">上方插入文本</property>
                <property name="accelerator">&lt;Control&gt;i</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">下方插入文本</property>
                <property name="accelerator">&lt;Control&gt;&lt;Shift&gt;i</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">上移</property>
                <property name="accelerator">&lt;Control&gt;Up</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">下移</property>
                <property name="accelerator">&lt;Control&gt;Down</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">删除</property>
                <property name="accelerator">Delete</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">生成合并文本</property>
                <property name="accelerator">&lt;Control&gt;g</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">生成到剪贴板</property>
                <property name="accelerator">&lt;Control&gt;&lt;Shift&gt;c</property>
              </object>
            </child>
          </object>
        </child>
        <child>
          <object class="GtkShortcutsGroup">
            <property name="title" translatable="yes">应用程序</property>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">语言设置</property>
                <property name="accelerator">&lt;Control&gt;comma</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">键盘快捷键</property>
                <property name="accelerator">&lt;Control&gt;slash</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">关于</property>
                <property name="accelerator">F1</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">退出</property>
                <property name="accelerator">&lt;Control&gt;q</property>
              </object>
            </child>
          </object>
        </child>
      </object>
    </child>
  </object>
</interface>""";
    }

    public void on_settings () {
        var settings_dialog = new SettingsDialog (this);
        settings_dialog.restart_requested.connect (() => {
            try {
                string exec_path = FileUtils.read_link ("/proc/self/exe");
                var app = (FileCollectorApp) this.application;
                app.quit ();
                Process.spawn_async (
                    null,
                    {exec_path},
                    null,
                    0,
                    null,
                    null
                );
            } catch (Error e) {
                warning ("Failed to restart: %s", e.message);
            }
        });
        settings_dialog.present ();
    }

    public void on_manage_phrases () {
        get_phrases_picker ().show_manage_window ();
    }

    private void show_warning (string title, string msg) {
        var d = new Adw.AlertDialog (title, msg);
        d.add_response ("ok", _("确定"));
        d.present (this);
    }

    private void show_error (string title, string msg) {
        var d = new Adw.AlertDialog (title, msg);
        d.add_response ("ok", _("确定"));
        d.present (this);
    }

    private void show_toast (string title) {
        var toast = new Adw.Toast (title);
        toast.timeout = 2;
        toast_overlay.add_toast (toast);
    }

    private void show_edit_phrase_dialog (string old_text, int index) {
        var picker = get_phrases_picker ();
        var dialog = new Adw.Dialog ();
        dialog.set_title (_("编辑常用语"));
        dialog.set_content_width (450);
        dialog.set_content_height (350);

        var toolbar_view = new Adw.ToolbarView ();
        dialog.set_child (toolbar_view);

        var header_bar = new Adw.HeaderBar ();
        header_bar.set_title_widget (new Adw.WindowTitle (_("编辑常用语"), ""));
        header_bar.set_show_end_title_buttons (false);
        toolbar_view.add_top_bar (header_bar);

        var cancel_btn = new Gtk.Button ();
        cancel_btn.set_label (_("取消"));
        header_bar.pack_start (cancel_btn);

        var ok_btn = new Gtk.Button ();
        ok_btn.set_label (_("确定"));
        ok_btn.add_css_class ("suggested-action");
        header_bar.pack_end (ok_btn);

        var btn_size_group = new Gtk.SizeGroup (Gtk.SizeGroupMode.HORIZONTAL);
        btn_size_group.add_widget (cancel_btn);
        btn_size_group.add_widget (ok_btn);

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        content.set_margin_top (0);
        content.set_margin_start (12);
        content.set_margin_end (12);
        content.set_margin_bottom (12);

        var frame = new Gtk.Frame (null);
        frame.add_css_class ("text-input-frame");

        var scrolled = new Gtk.ScrolledWindow ();
        scrolled.set_vexpand (true);
        scrolled.set_min_content_height (120);

        var text_view = new Gtk.TextView ();
        text_view.set_wrap_mode (Gtk.WrapMode.WORD_CHAR);
        text_view.set_top_margin (12);
        text_view.set_bottom_margin (12);
        text_view.set_left_margin (12);
        text_view.set_right_margin (12);
        text_view.get_buffer ().set_text (old_text, -1);

        scrolled.set_child (text_view);
        frame.set_child (scrolled);
        content.append (frame);

        toolbar_view.set_content (content);

        cancel_btn.clicked.connect (() => {
            dialog.close ();
        });

        ok_btn.clicked.connect (() => {
            var buffer = text_view.get_buffer ();
            Gtk.TextIter start, end;
            buffer.get_start_iter (out start);
            buffer.get_end_iter (out end);
            var text = buffer.get_text (start, end, false);
            if (text != null && text.strip () != "") {
                picker.update_phrase (index, text);
            }
            dialog.close ();
        });

        dialog.present (this);
    }

    private PhrasesPicker get_phrases_picker () {
        if (phrases_picker_instance == null) {
            phrases_picker_instance = new PhrasesPicker (this, common_phrases);
            phrases_picker_instance.phrase_selected.connect ((phrase, above) => {
                do_insert_text (phrase, above);
            });
            phrases_picker_instance.edit_phrase_requested.connect ((old_text, index) => {
                show_edit_phrase_dialog (old_text, index);
            });
        }
        return phrases_picker_instance;
    }

    // ─── AI 助手集成 ───────────────────────────────────────────────────

    private void setup_ai_panel () {
        ai_sidebar.visible = false;
        ai_panel_visible = false;
        // AI 边栏不可被压缩, 与其他三栏保持一致, 防止内容被裁剪
        ai_paned.set_shrink_start_child (false);
        ai_paned.set_shrink_end_child (false);
        btn_ai_toggle.clicked.connect (toggle_ai_panel);
        ai_paned.notify["position"].connect (clamp_ai_paned_position);

        // ai_paned 的 separator 宽度为 0 (CSS), GTK 默认抓取区域会溢出到 end_child,
        // 而 end_child (outer_paned) 不显示 col-resize 光标, 导致只有左半区域有光标.
        // 用 EventControllerMotion 检测鼠标在 separator 附近时设置光标.
        col_resize_cursor = new Gdk.Cursor.from_name ("col-resize", null);
        var motion = new Gtk.EventControllerMotion ();
        motion.motion.connect ((x, y) => {
            // AI 边栏隐藏时不处理
            if (!ai_sidebar.visible) return;
            int pos = (int) ai_paned.position;
            // 鼠标在 separator 附近 ±6px 范围内
            if ((x >= pos - 6) && (x <= pos + 6)) {
                ai_paned.set_cursor (col_resize_cursor);
            } else {
                ai_paned.set_cursor (null);
            }
        });
        motion.leave.connect (() => {
            ai_paned.set_cursor (null);
        });
        ai_paned.add_controller (motion);
    }

    private void clamp_ai_paned_position () {
        // 防止 AI 边栏被用户拖到太大 / 太小
        var pw = ai_paned.get_width ();
        if (pw <= 0) return;
        var pos = (int) ai_paned.position;
        if (pos < 260) {
            ai_paned.position = 260;
        } else if (pos > 480) {
            ai_paned.position = 480;
        }
    }

    private void toggle_ai_panel () {
        ai_panel_visible = !ai_panel_visible;
        if (ai_panel_visible) {
            show_ai_panel ();
        } else {
            hide_ai_panel ();
        }
    }

    private void show_ai_panel () {
        ai_panel_visible = true;
        ai_sidebar.visible = true;
        // 第一次显示时构建 panel
        if (ai_panel_instance == null) {
            ai_panel_instance = new AIPanel (this);
            var content = ai_panel_instance.build_widget ();
            // Frame 内部包一个 card Box, 与现有三栏完全一致
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.set_size_request (-1, -1);
            box.add_css_class ("card");
            box.append (content);
            ai_sidebar.set_child (box);
        }
        // 重新应用当前设置
        apply_ai_settings_to_panel ();

        // 更新窗口最小宽度 (AI 边栏可见时需要更大)
        update_window_min_size ();

        // 展开 AI 侧边栏时自动加宽窗口, 防止现有栏被挤出画面
        expand_window_for_ai ();
    }

    private void expand_window_for_ai () {
        int cur_w = get_width ();
        int cur_h = get_height ();
        if (cur_w <= 0) {
            // 后备: 使用 default_width / default_height
            cur_w = default_width;
            cur_h = default_height;
        }
        if (cur_w <= 0) return;

        // 记录展开前的宽度, 隐藏时恢复 (仅首次记录, 避免反复展开覆盖)
        if (pre_ai_width <= 0) {
            pre_ai_width = cur_w;
        }

        const int AI_EXTRA_WIDTH = 300;
        int target_w = cur_w + AI_EXTRA_WIDTH;

        // 不超过显示器宽度
        var disp = Gdk.Display.get_default ();
        if (disp != null) {
            var surface = this.get_surface ();
            if (surface != null) {
                var monitor = disp.get_monitor_at_surface (surface);
                if (monitor != null) {
                    var geo = monitor.get_geometry ();
                    if (target_w > geo.width) {
                        target_w = geo.width;
                    }
                }
            }
        }

        set_default_size (target_w, cur_h);
    }

    private void hide_ai_panel () {
        ai_panel_visible = false;
        ai_sidebar.visible = false;
        // 更新窗口最小宽度 (AI 边栏隐藏后可以更小)
        update_window_min_size ();

        // 恢复 AI 面板展开前的窗口宽度
        if (pre_ai_width > 0) {
            int cur_h = get_height ();
            if (cur_h <= 0) cur_h = default_height;
            set_default_size (pre_ai_width, cur_h);
            pre_ai_width = 0;
        }
    }

    private void apply_ai_settings_to_panel () {
        if (ai_panel_instance == null) return;
        var s = ConfigManager.load_ai_settings ();
        if (!s.enabled) {
            // 即使用户把开关关掉, 面板仍可显示, 但提示未启用
            ai_panel_instance.configure (s, ai_tool_executor_cb, ai_state_provider_cb);
            return;
        }
        ai_panel_instance.configure (s, ai_tool_executor_cb, ai_state_provider_cb);
    }

    public void on_ai_settings () {
        if (ai_settings_dialog_instance == null) {
            ai_settings_dialog_instance = new AISettingsDialog (this);
        }
        ai_settings_dialog_instance.settings_changed.connect (() => {
            apply_ai_settings_to_panel ();
        });
        ai_settings_dialog_instance.present ();
    }

    // ── AI 状态提供 (供 AIPanel 在生成 system prompt 时调用) ──────────
    private AISystemSnapshot ai_state_provider_cb () {
        var snap = AISystemSnapshot ();
        snap.work_dir = (work_dir != null) ? work_dir.get_path () : "";
        snap.mode = ai_mode;
        snap.file_extension = ai_file_extension;
        snap.file_label = ai_file_label;
        snap.max_files = ai_max_files;
        snap.use_absolute = use_absolute;
        snap.show_header = show_header;
        snap.selected_paths = new string[0];
        snap.custom_instructions = new string[0];

        var paths = new Gee.ArrayList<string> ();
        var instructions = new Gee.ArrayList<string> ();
        for (int i = 0; i < items.length; i++) {
            var it = items.get (i);
            if (it.item_type == "file") {
                if (it.file_path != null) {
                    string rel;
                    if (work_dir != null && it.file_path.has_prefix (work_dir.get_path ())) {
                        rel = it.file_path.substring (work_dir.get_path ().length);
                        while (rel.has_prefix ("/")) rel = rel.substring (1);
                    } else {
                        rel = it.file_path;
                    }
                    paths.add (rel);
                }
            } else if (it.item_type == "text") {
                string t = it.content ?? "";
                t = t.strip ();
                instructions.add (t);
            }
        }
        snap.selected_paths = paths.to_array ();
        snap.custom_instructions = instructions.to_array ();
        return snap;
    }

    // ── AI 工具执行 (主线程上跑, 通过 Idle + Cond 跨线程同步) ──────
    // AI worker 线程调用 → Idle 投递到主线程 → 主线程执行工具
    // 完成 → 通过 Cond 唤醒 worker 线程返回结果.
    private GLib.Mutex ai_exec_mutex = GLib.Mutex ();
    private GLib.Cond ai_exec_cond = GLib.Cond ();
    private string? ai_exec_result = null;
    private bool ai_exec_done = false;

    private string ai_tool_executor_cb (string name, Json.Node args) throws GLib.Error {
        string json_str = json_serialize_for_main (args);
        string name_local = name;
        string json_local = json_str;
        ai_exec_mutex.lock ();
        ai_exec_result = null;
        ai_exec_done = false;
        GLib.Idle.add (() => {
            // 窗口关闭或 AI 停止时跳过工具执行, 避免访问已销毁的 widget
            if (window_closing || (ai_panel_instance != null && ai_panel_instance.is_stop_requested ())) {
                ai_exec_mutex.lock ();
                ai_exec_result = "";
                ai_exec_done = true;
                ai_exec_cond.broadcast ();
                ai_exec_mutex.unlock ();
                return GLib.Source.REMOVE;
            }
            string r = "";
            try {
                var a = json_parse_args (json_local);
                r = ai_tool_executor_main (name_local, a);
            } catch (Error e) {
                r = "工具执行失败: " + e.message;
            }
            ai_exec_mutex.lock ();
            ai_exec_result = r;
            ai_exec_done = true;
            ai_exec_cond.broadcast ();
            ai_exec_mutex.unlock ();
            return GLib.Source.REMOVE;
        });
        // 使用超时等待, 周期性检查停止条件, 使"停止"按钮能打断工具执行等待
        while (!ai_exec_done) {
            if (window_closing || (ai_panel_instance != null && ai_panel_instance.is_stop_requested ())) {
                ai_exec_mutex.unlock ();
                return "";
            }
            int64 end_time = GLib.get_monotonic_time () + 200 * 1000; // 200ms 超时
            ai_exec_cond.wait_until (ai_exec_mutex, end_time);
        }
        ai_exec_mutex.unlock ();
        return ai_exec_result ?? "";
    }

    // 工具真实执行 (必须在主线程调用)
    private string ai_tool_executor_main (string name, Json.Node args) throws GLib.Error {
        switch (name) {
            case "list_files": return ai_tool_list_files (args);
            case "read_file":  return ai_tool_read_file (args);
            case "set_work_dir": return ai_tool_set_work_dir (args);
            case "add_files":  return ai_tool_add_files (args);
            case "remove_files": return ai_tool_remove_files (args);
            // add_text (schema 名) / insert_text (旧名)
            case "add_text":
            case "add_custom_instruction":
            case "insert_text": return ai_tool_add_text (args);
            // remove_item (schema 名, 按 0-based 索引删除任意项) / remove_text (旧名, 按文本索引)
            case "remove_item": return ai_tool_remove_item (args);
            case "remove_custom_instruction": return ai_tool_remove_text (args);
            case "move_item": return ai_tool_move_item (args);
            // clear_items (schema 名) / clear_all (旧名)
            case "clear_items":
            case "clear_all":   return ai_tool_clear_all (args);
            case "list_items":  return ai_tool_list_items (args);
            case "set_use_absolute": return ai_tool_set_use_absolute (args);
            case "set_show_header": return ai_tool_set_show_header (args);
            case "set_mode":
            case "set_file_extension":
            case "set_file_label":
            case "set_max_files":
                return ai_tool_set_meta (name, args);
            default:
                return "未知工具: " + name;
        }
    }

    // 跨线程传递 Json 工具参数: 序列化为字符串 (主线程收到后重新解析)
    private static string json_serialize_for_main (Json.Node n) {
        if (n == null) return "{}";
        var g = new Json.Generator ();
        g.set_root (n);
        g.pretty = false;
        size_t len = 0;
        return g.to_data (out len) ?? "{}";
    }

    private static Json.Node json_parse_args (string raw) throws Error {
        var p = new Json.Parser ();
        p.load_from_data (raw, raw.length);
        var r = p.get_root ();
        if (r == null) return AI.SchemaHelper.obj_to_node (new Json.Object ());
        return r;
    }

    private string ai_tool_list_files (Json.Node args) throws GLib.Error {
        if (work_dir == null) return "工作目录未设置";
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        var o = args.get_object ();

        string pattern = o.has_member ("pattern") ? o.get_string_member ("pattern") : "";
        int64 max_results = o.has_member ("max_results") ? o.get_int_member ("max_results") : 500;
        int64 max_depth = o.has_member ("max_depth") ? o.get_int_member ("max_depth") : 8;

        if (max_results <= 0) max_results = 500;
        if (max_depth <= 0) max_depth = 8;

        if (pattern.strip () == "") pattern = "*";

        var sb = new StringBuilder ();
        sb.append ("ROOT=").append (work_dir.get_path ()).append ("\n");

        if (pattern.contains ("**")) {
            string[] ignored_dirs = ConfigManager.get_ignored_dirs ();
            var results = GlobHelper.expand_glob (
                work_dir.get_path (),
                pattern,
                (int) max_depth,
                (int) max_results
            );

            int count = 0;
            foreach (var path in results) {
                if (count >= max_results) break;
                var file = File.new_for_path (path);
                try {
                    var info = file.query_info (
                        FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_SIZE,
                        FileQueryInfoFlags.NONE
                    );
                    string name = file.get_basename ();
                    if (name in ignored_dirs) continue;
                    if (info.get_file_type () == FileType.DIRECTORY) {
                        sb.append ("DIR  ").append (rel_path (work_dir.get_path (), path)).append ("\n");
                    } else {
                        sb.append ("FILE ").append (rel_path (work_dir.get_path (), path))
                          .append ("  (").append (format_size (info.get_size ())).append (")\n");
                    }
                    count++;
                } catch (Error e) {
                }
            }
            sb.append ("\n# total ").append (results.length.to_string ())
              .append (" matched, listed ").append (count.to_string ());
        } else {
            var matcher = new PatternSpec (pattern.down ());
            int count = 0;
            int total = 0;
            try {
                string[] ignored_dirs = ConfigManager.get_ignored_dirs ();
                list_files_recursive (work_dir.get_path (), work_dir.get_path (), 0, (int) max_depth,
                    matcher, sb, ref count, ref total, (int) max_results, ignored_dirs);
            } catch (Error e) {
                return "读取目录失败: " + e.message;
            }
            sb.append ("\n# total ").append (total.to_string ())
              .append (" matched, listed ").append (count.to_string ());
        }
        return sb.str;
    }

    private static void list_files_recursive (string root, string dir, int depth, int max_depth,
            PatternSpec matcher, StringBuilder sb, ref int count, ref int total, int max_results,
            string[] ignored_dirs)
            throws Error {
        if (count >= max_results) return;
        if (depth > max_depth) return;
        var dir_file = File.new_for_path (dir);
        if (!dir_file.query_exists ()) return;
        var en = dir_file.enumerate_children (
            FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_SIZE,
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo info;
        while ((info = en.next_file ()) != null) {
            if (count >= max_results) break;
            string name = info.get_name ();
            string full = dir_file.get_child (name).get_path ();
            if (info.get_file_type () == FileType.DIRECTORY) {
                if (name in ignored_dirs) {
                    continue;
                }
                if (matcher.match_string (name.down ()) && count < max_results) {
                    sb.append ("DIR  ").append (rel_path (root, full)).append ("\n");
                    count++;
                }
                list_files_recursive (root, full, depth + 1, max_depth, matcher, sb,
                    ref count, ref total, max_results, ignored_dirs);
            } else {
                total++;
                if (matcher.match_string (name.down ())) {
                    sb.append ("FILE ").append (rel_path (root, full))
                      .append ("  (").append (format_size (info.get_size ())).append (")\n");
                    count++;
                }
            }
        }
    }

    private static string rel_path (string root, string full) {
        if (full.has_prefix (root)) {
            string r = full.substring (root.length);
            while (r.has_prefix ("/")) r = r.substring (1);
            return r.length > 0 ? r : full;
        }
        return full;
    }

    // 按字节长度截断, 但不切断多字节 UTF-8 字符, 避免乱码
    private static string truncate_utf8 (string text, int max_bytes) {
        if (text.length <= max_bytes) return text;
        int cut = max_bytes;
        while (cut > 0 && !text[0:cut].validate (-1)) {
            cut--;
        }
        return text[0:cut];
    }

    private static string format_size (int64 size) {
        if (size < 1024) return "%lld B".printf (size);
        if (size < 1024 * 1024) return "%.1f KB".printf (size / 1024.0);
        if (size < 1024 * 1024 * 1024) return "%.1f MB".printf (size / 1024.0 / 1024.0);
        return "%.1f GB".printf (size / 1024.0 / 1024.0 / 1024.0);
    }

    // ─── AI 工具路径安全校验 ────────────────────────────────────────────

    // 将路径规范化: 解析 . 和 .., 消除重复 /, 防止路径遍历攻击
    private static string normalize_path (string path) {
        var stack = new GenericArray<string> ();
        foreach (unowned string part in path.split ("/")) {
            if (part == "" || part == ".") continue;
            if (part == "..") {
                if (stack.length > 0) stack.remove_index (stack.length - 1);
            } else {
                stack.add ((string) part);
            }
        }
        string joined = string.joinv ("/", (string*[]) stack.data);
        return path.has_prefix ("/") ? "/" + joined : joined;
    }

    // 解析 AI 工具的路径参数: 相对路径基于 work_dir, 然后规范化
    private string? resolve_ai_path (string path) {
        string abs = path;
        if (!GLib.Path.is_absolute (path)) {
            if (work_dir != null) {
                abs = GLib.Path.build_filename (work_dir.get_path (), path);
            } else {
                return null; // 无 work_dir 时无法解析相对路径
            }
        }
        return normalize_path (abs);
    }

    // 检查规范化路径是否在 work_dir 内 (防止路径遍历读取敏感文件)
    private bool is_path_in_work_dir (string normalized_path) {
        if (work_dir == null) return false;
        string allowed = normalize_path (work_dir.get_path ());
        return normalized_path == allowed || normalized_path.has_prefix (allowed + "/");
    }

    // 检查规范化路径是否允许作为新工作目录 (必须在当前 work_dir 树内或用户主目录内)
    private bool is_path_allowed_for_work_dir (string normalized_path) {
        // 允许在用户主目录内
        string home = normalize_path (Environment.get_home_dir ());
        if (normalized_path == home || normalized_path.has_prefix (home + "/")) return true;
        // 允许在当前工作目录树内
        if (work_dir != null) {
            string wd = normalize_path (work_dir.get_path ());
            if (normalized_path == wd || normalized_path.has_prefix (wd + "/")) return true;
        }
        return false;
    }

    private string ai_tool_read_file (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        var o = args.get_object ();
        string path = o.has_member ("path") ? o.get_string_member ("path") : "";
        if (path == "") return "缺少 path";
        // 默认值与 schema 一致: max_bytes=102400, start_line=1 (1-based), max_lines=500
        int64 max_bytes = o.has_member ("max_bytes") ? o.get_int_member ("max_bytes") : 102400;
        int64 start_line = o.has_member ("start_line") ? o.get_int_member ("start_line") : 1;
        int64 max_lines = o.has_member ("max_lines") ? o.get_int_member ("max_lines") : 500;
        if (max_bytes <= 0) max_bytes = 102400;
        if (max_lines <= 0) max_lines = 500;

        // 路径解析与安全校验: 相对路径基于 work_dir, 必须在 work_dir 内
        string? resolved = resolve_ai_path (path);
        if (resolved == null) return "无法解析路径 (未设置工作目录)";
        if (!is_path_in_work_dir (resolved)) return "拒绝访问: 路径超出工作目录范围";
        string abs = resolved;
        var file = File.new_for_path (abs);
        if (!file.query_exists ()) return "文件不存在: " + abs;

        // 获取文件大小 (不加载内容到内存)
        int64 file_size = 0;
        try {
            var info = file.query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
            file_size = info.get_size ();
        } catch (Error e) {
            return "读取文件信息失败: " + e.message;
        }

        // 流式读取: 只读取前 max_bytes 字节, 避免全量加载大文件导致 OOM
        Bytes? bytes = null;
        FileInputStream? fis = null;
        try {
            fis = file.read ();
            bytes = fis.read_bytes ((size_t) max_bytes);
        } catch (Error e) {
            return "读取失败: " + e.message;
        } finally {
            if (fis != null) {
                try { fis.close (); } catch (Error e) { debug ("Close failed: %s", e.message); }
            }
        }
        unowned uint8[] raw = bytes.get_data ();
        bool read_all = (raw.length >= file_size);

        string content = EncodingHelper.decode_to_utf8 (raw);
        // 行过滤
        string[] lines = content.split ("\n");
        // start_line 是 1-based, 转为 0-based 数组索引
        int start = (int) start_line - 1;
        if (start < 0) start = 0;
        if (start >= lines.length) {
            if (read_all) {
                return "[文件总行数: %d, start_line %lld 越界]".printf (lines.length, start_line);
            }
            return "[start_line %lld 超出前 %lld 字节可读范围, 请减小 start_line 或增大 max_bytes]".printf (start_line, max_bytes);
        }
        int end = int.min (lines.length, start + (int) max_lines);
        var sb = new StringBuilder ();
        sb.append ("# file: ").append (rel_path (work_dir != null ? work_dir.get_path () : "/", abs))
          .append ("  (").append (format_size (file_size));
        if (!read_all) {
            sb.append (", 前 ").append (max_bytes.to_string ()).append (" 字节");
        }
        sb.append (", ").append (lines.length.to_string ()).append (" lines)\n");
        for (int i = start; i < end; i++) {
            sb.append ("%4d  ".printf (i + 1)).append (lines[i]).append ("\n");
            if (sb.str.length > max_bytes) {
                sb.append ("\n# ... [内容过长, 截断到 ").append (max_bytes.to_string ()).append (" 字节]");
                break;
            }
        }
        return sb.str;
    }

    private string ai_tool_set_work_dir (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        string path = args.get_object ().get_string_member_with_default ("path", "");
        if (path == "") return "缺少 path";
        // 路径解析与安全校验: 新工作目录必须在当前 work_dir 树内或用户主目录内
        string? resolved = resolve_ai_path (path);
        if (resolved == null) return "无法解析路径 (未设置工作目录)";
        if (!is_path_allowed_for_work_dir (resolved))
            return "拒绝访问: 工作目录必须在当前项目目录或用户主目录内";
        var file = File.new_for_path (resolved);
        if (!file.query_exists ()) return "目录不存在: " + resolved;
        // 已在主线程 (ai_tool_executor_cb 通过 Idle 投递), 直接执行
        ai_apply_set_work_dir (resolved);
        return "工作目录已切换到: " + resolved;
    }

    private void ai_apply_set_work_dir (string path) {
        push_undo_state ();
        items.remove_range (0, items.length);
        checked_paths.remove_all ();
        check_model.clear ();
        var folder = File.new_for_path (path);
        work_dir = folder;
        update_subtitle (path);
        root_store.remove_all ();
        var root_item = new DirectoryItem (folder.get_basename (), path, true);
        root_store.append (root_item);
        load_directory_children_lazy (root_item);
        search_entry.visible = true;
        var root_row = tree_list_model.get_item (0) as Gtk.TreeListRow;
        if (root_row != null) {
            root_row.set_expanded (true);
        }
        refresh_list ();
    }

    private string ai_tool_add_files (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        var o = args.get_object ();
        if (!o.has_member ("paths")) return "缺少 paths";
        var paths_arr = o.get_array_member ("paths");
        if (paths_arr == null) return "paths 必须是数组";

        string? after = o.has_member ("after_path") ? o.get_string_member ("after_path") : null;
        int added = 0;
        int total = (int) paths_arr.get_length ();
        // 已在主线程 (ai_tool_executor_cb 通过 Idle 投递), 直接执行
        push_undo_state ();
        int insert_at = items.length;
        if (after != null) {
            for (int i = 0; i < items.length; i++) {
                var it = items.get (i);
                if (it.item_type == "file" && it.file_path == after) {
                    insert_at = i + 1;
                    break;
                }
            }
        }
        for (int i = 0; i < total; i++) {
            string p = paths_arr.get_string_element (i);
            string? resolved = resolve_ai_path (p);
            if (resolved == null || !is_path_in_work_dir (resolved)) continue;
            string abs = resolved;
            if (!FileUtils.test (abs, FileTest.EXISTS)) continue;
            // 是否已存在
            bool exists = false;
            for (int j = 0; j < items.length; j++) {
                if (items.get (j).file_path == abs) { exists = true; break; }
            }
            if (exists) continue;
            items.insert (insert_at + added, new ItemData ("file", abs, null, false));
            if (!(abs in checked_paths)) {
                checked_paths.insert (abs, true);
            }
            set_tree_item_check (abs, true);
            added++;
        }
        refresh_list ();
        return "已添加 %d 个文件 (请求 %d)".printf (added, total);
    }

    private string ai_tool_remove_files (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        if (!args.get_object ().has_member ("paths")) return "缺少 paths";
        var arr = args.get_object ().get_array_member ("paths");
        if (arr == null) return "paths 必须是数组";
        int total = (int) arr.get_length ();
        // 已在主线程 (ai_tool_executor_cb 通过 Idle 投递), 直接执行
        int result = 0;
        push_undo_state ();
        for (int i = 0; i < total; i++) {
            string p = arr.get_string_element (i);
            string? resolved = resolve_ai_path (p);
            if (resolved == null || !is_path_in_work_dir (resolved)) continue;
            string abs = resolved;
            // 从 items 移除
            for (int j = items.length - 1; j >= 0; j--) {
                var it = items.get (j);
                if (it.item_type == "file" && it.file_path == abs) {
                    items.remove_index (j);
                    result++;
                }
            }
            if (abs in checked_paths) {
                checked_paths.remove (abs);
                set_tree_item_check (abs, false);
            }
        }
        refresh_list ();
        return "已移除 %d 个文件 (请求 %d)".printf (result, total);
    }

    // add_text (schema 名) / insert_text (旧名): 支持 position (0-based) 和旧版 after_path/before_path
    private string ai_tool_add_text (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        var o = args.get_object ();
        string text = o.has_member ("text") ? o.get_string_member ("text") :
                      (o.has_member ("content") ? o.get_string_member ("content") : "");
        if (text == "") return "缺少 text / content";
        string? after = o.has_member ("after_path") ? o.get_string_member ("after_path") : null;
        string? before = o.has_member ("before_path") ? o.get_string_member ("before_path") : null;
        // 已在主线程 (ai_tool_executor_cb 通过 Idle 投递), 直接执行
        int insert_at = items.length;
        if (o.has_member ("position")) {
            // schema 标准: position 是 0-based 索引
            int pos = (int) o.get_int_member ("position");
            if (pos < 0) pos = 0;
            if (pos > items.length) pos = items.length;
            insert_at = pos;
        } else if (after != null) {
            for (int i = 0; i < items.length; i++) {
                var it = items.get (i);
                if (it.item_type == "file" && it.file_path == after) {
                    insert_at = i + 1;
                    break;
                }
            }
        } else if (before != null) {
            insert_at = 0;
            for (int i = 0; i < items.length; i++) {
                var it = items.get (i);
                if (it.item_type == "file" && it.file_path == before) {
                    insert_at = i;
                    break;
                }
            }
        }
        var inserted = new GenericArray<ItemData> ();
        var new_item = new ItemData ("text", null, text, false);
        items.insert (insert_at, new_item);
        inserted.add (new_item);
        push_undo_delta (new UndoDelta.for_insert (insert_at, inserted));
        refresh_list ();
        return "已插入文本 (位置 %d)".printf (insert_at);
    }

    // remove_item (schema 名): 按 0-based 索引删除任意项 (file 或 text)
    private string ai_tool_remove_item (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        if (!args.get_object ().has_member ("index")) return "缺少 index";
        int idx = (int) args.get_object ().get_int_member ("index");
        if (idx < 0 || idx >= items.length) {
            return "索引越界: %d (列表共 %d 项)".printf (idx, items.length);
        }
        var removed = items.get (idx);
        var rm_items = new GenericArray<ItemData> ();
        rm_items.add (removed);
        var rm_checked = new GenericArray<string> ();
        if (removed.item_type == "file" && removed.file_path != null) {
            if (removed.file_path in checked_paths) {
                rm_checked.add (removed.file_path);
                checked_paths.remove (removed.file_path);
                set_tree_item_check (removed.file_path, false);
            }
        }
        items.remove_index (idx);
        push_undo_delta (new UndoDelta.for_remove (idx, rm_items, rm_checked));
        refresh_list ();
        return "已删除第 %d 项 (%s)".printf (idx, removed.item_type);
    }

    // move_item (schema 名): 从 from_index 移到 to_index
    private string ai_tool_move_item (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        var o = args.get_object ();
        if (!o.has_member ("from_index") || !o.has_member ("to_index")) return "缺少 from_index / to_index";
        int from = (int) o.get_int_member ("from_index");
        int to = (int) o.get_int_member ("to_index");
        if (from < 0 || from >= items.length) {
            return "from_index 越界: %d (列表共 %d 项)".printf (from, items.length);
        }
        if (to < 0 || to >= items.length) {
            return "to_index 越界: %d (列表共 %d 项)".printf (to, items.length);
        }
        var item = items.get (from);
        items.remove_index (from);
        items.insert (to, item);
        push_undo_delta (new UndoDelta.for_move (from, to));
        refresh_list ();
        return "已移动: %d → %d".printf (from, to);
    }

    private string ai_tool_set_use_absolute (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        var o = args.get_object ();
        if (!o.has_member ("value")) return "缺少 value";
        bool val = o.get_boolean_member ("value");
        bool old_abs = use_absolute;
        bool old_hdr = show_header;
        use_absolute = val;
        // 临时断开信号, 避免 on_path_mode_changed / on_header_check_changed 重复 push_undo_delta
        radio_absolute_path.notify["active"].disconnect (on_path_mode_changed);
        radio_relative_path.notify["active"].disconnect (on_path_mode_changed);
        check_write_header.notify["active"].disconnect (on_header_check_changed);
        radio_absolute_path.active = val;
        radio_relative_path.active = !val;
        radio_absolute_path.notify["active"].connect (on_path_mode_changed);
        radio_relative_path.notify["active"].connect (on_path_mode_changed);
        check_write_header.notify["active"].connect (on_header_check_changed);
        push_undo_delta (new UndoDelta.for_absolute (old_abs, val, old_hdr, show_header));
        refresh_list ();
        return "use_absolute=" + val.to_string ();
    }

    private string ai_tool_set_show_header (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        var o = args.get_object ();
        if (!o.has_member ("value")) return "缺少 value";
        bool val = o.get_boolean_member ("value");
        bool old_val = show_header;
        show_header = val;
        check_write_header.notify["active"].disconnect (on_header_check_changed);
        check_write_header.active = val;
        check_write_header.notify["active"].connect (on_header_check_changed);
        push_undo_delta (new UndoDelta.for_header (old_val, val));
        return "show_header=" + val.to_string ();
    }

    private string ai_tool_remove_text (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        if (!args.get_object ().has_member ("index")) return "缺少 index";
        int idx = (int) args.get_object ().get_int_member ("index");
        // 已在主线程 (ai_tool_executor_cb 通过 Idle 投递), 直接执行
        int removed = 0;
        int remove_at = -1;
        ItemData? removed_item = null;
        for (int i = items.length - 1; i >= 0; i--) {
            if (items.get (i).item_type == "text") {
                if (idx == 0) {
                    remove_at = i;
                    removed_item = items.get (i);
                    items.remove_index (i);
                    removed = 1;
                    break;
                } else {
                    idx--;
                }
            }
        }
        if (removed > 0 && removed_item != null) {
            var rm_items = new GenericArray<ItemData> ();
            rm_items.add (removed_item);
            push_undo_delta (new UndoDelta.for_remove (remove_at, rm_items));
        }
        refresh_list ();
        return "已删除文本 (removed=%d)".printf (removed);
    }

    private string ai_tool_clear_all (Json.Node args) throws GLib.Error {
        // 已在主线程 (ai_tool_executor_cb 通过 Idle 投递), 直接执行
        on_clear_items ();
        return "已清空编排列表";
    }

    private string ai_tool_list_items (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        var o = args.get_object ();
        string kind = o.has_member ("kind") ? o.get_string_member ("kind") : "all";
        int max_items = o.has_member ("max_items") ? (int) o.get_int_member ("max_items") : 200;
        if (max_items <= 0) max_items = 200;
        var sb = new StringBuilder ();
        int count = 0;
        for (int i = 0; i < items.length && count < max_items; i++) {
            var it = items.get (i);
            if (kind == "file" && it.item_type != "file") continue;
            if (kind == "text" && it.item_type != "text") continue;
            if (it.item_type == "file") {
                string rel;
                if (work_dir != null && it.file_path.has_prefix (work_dir.get_path ())) {
                    rel = it.file_path.substring (work_dir.get_path ().length);
                    while (rel.has_prefix ("/")) rel = rel.substring (1);
                } else {
                    rel = it.file_path;
                }
                sb.append ("#" + (i + 1).to_string () + "  [file] ").append (rel).append ("\n");
            } else {
                string preview = it.content ?? "";
                if (preview.length > 80) preview = truncate_utf8 (preview, 80) + "…";
                // 用 split/join 替代 string.replace, 避免 Vala 的 Regex 实现在某些情况下 assert_not_reached
                preview = string.joinv ("\\n", preview.split ("\n"));
                sb.append ("#").append ((i + 1).to_string ()).append ("  [text] ").append (preview).append ("\n");
            }
            count++;
        }
        sb.append ("\n# total ").append (items.length.to_string ());
        return sb.str;
    }

    private string ai_tool_set_meta (string name, Json.Node args) throws GLib.Error {
        switch (name) {
            case "set_mode": {
                if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
                string m = args.get_object ().get_string_member_with_default ("mode", "default");
                if (m != "default" && m != "directory" && m != "single") {
                    return "无效 mode: " + m;
                }
                ai_mode = m;
                return "mode=" + m;
            }
            case "set_file_extension": {
                if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
                ai_file_extension = args.get_object ().get_string_member_with_default ("extension", "");
                return "extension=" + ai_file_extension;
            }
            case "set_file_label": {
                if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
                ai_file_label = args.get_object ().get_string_member_with_default ("label", "文件");
                return "label=" + ai_file_label;
            }
            case "set_max_files": {
                if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
                int n = (int) args.get_object ().get_int_member ("max_files");
                if (n < 1) n = 1;
                ai_max_files = n;
                return "max_files=" + ai_max_files.to_string ();
            }
        }
        return "未知 meta 工具: " + name;
    }
}
