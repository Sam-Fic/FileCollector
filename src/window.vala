using GLib;
using Gtk;
using Adw;
using Json;

[GtkTemplate (ui = "/com/github/samfic/filecollector/window.ui")]
public class FileCollectorWindow : Adw.ApplicationWindow {
    [GtkChild] private unowned Gtk.TreeView dir_tree;
    [GtkChild] private unowned Gtk.ListBox queue_list;
    [GtkChild] private unowned Gtk.TextView preview_view;
    [GtkChild] private unowned Gtk.Button open_folder_btn;
    [GtkChild] private unowned Gtk.Button btn_generate;
    [GtkChild] private unowned Gtk.Button btn_generate_clipboard;
    [GtkChild] private unowned Gtk.Button btn_add_ext;
    [GtkChild] private unowned Gtk.Button btn_add_text_above;
    [GtkChild] private unowned Gtk.Button btn_add_text_below;
    [GtkChild] private unowned Gtk.Button btn_move_up;
    [GtkChild] private unowned Gtk.Button btn_move_down;
    [GtkChild] private unowned Gtk.Button btn_delete;
    [GtkChild] private unowned Gtk.Button btn_clear;
    [GtkChild] private unowned Gtk.CheckButton check_absolute_path;
    [GtkChild] private unowned Gtk.CheckButton check_write_header;
    [GtkChild] private unowned Gtk.MenuButton menu_btn;
    [GtkChild] private unowned Adw.ToastOverlay toast_overlay;
    [GtkChild] private unowned Gtk.Paned outer_paned;
    [GtkChild] private unowned Gtk.Paned inner_paned;

    private Gtk.TreeStore tree_model;
    private File? work_dir = null;
    private string? project_file = null;
    private bool use_absolute = false;
    private bool show_header = false;

    private GenericArray<ItemData> items;
    private HashTable<string, bool> checked_paths;
    private GenericArray<string> common_phrases;

    private Adw.WindowTitle? _title_widget;

    private const int COL_NAME = 0;
    private const int COL_PATH = 1;
    private const int COL_IS_DIR = 2;
    private const int COL_CHECKED = 3;
    private const int COL_INCONSISTENT = 4;

    public FileCollectorWindow (Adw.Application app) {
        GLib.Object (application: app);
    }

    construct {
        items = new GenericArray<ItemData> ();
        checked_paths = new HashTable<string, bool> (str_hash, str_equal);
        common_phrases = new GenericArray<string> ();

        load_common_phrases ();
        load_css ();

        setup_tree_view ();
        setup_signals ();
        setup_pane_sizes ();
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

    private string get_config_dir () {
        var dir = Environment.get_user_config_dir ();
        var config_dir = GLib.Path.build_filename (dir, "filecollector");
        try {
            var config_file = File.new_for_path (config_dir);
            if (!config_file.query_exists ()) {
                config_file.make_directory_with_parents (null);
            }
        } catch (Error e) {
            warning ("Failed to create config dir: %s", e.message);
        }
        return config_dir;
    }

    private string get_phrases_file () {
        return GLib.Path.build_filename (get_config_dir (), "common_phrases.json");
    }

    private void load_common_phrases () {
        var file = get_phrases_file ();
        if (!FileUtils.test (file, FileTest.EXISTS)) {
            return;
        }
        try {
            string content;
            size_t len;
            FileUtils.get_contents (file, out content, out len);
            var parser = new Json.Parser ();
            parser.load_from_data (content);
            var root = parser.get_root ().get_array ();
            for (int i = 0; i < root.get_length (); i++) {
                common_phrases.add (root.get_string_element (i));
            }
        } catch (Error e) {
            warning ("Failed to load common phrases: %s", e.message);
        }
    }

    private void save_common_phrases () {
        try {
            var builder = new Json.Builder ();
            builder.begin_array ();
            for (int i = 0; i < common_phrases.length; i++) {
                builder.add_string_value (common_phrases.get (i));
            }
            builder.end_array ();

            var generator = new Json.Generator ();
            generator.set_root (builder.get_root ());
            generator.pretty = true;

            var file = get_phrases_file ();
            generator.to_file (file);
        } catch (Error e) {
            warning ("Failed to save common phrases: %s", e.message);
        }
    }

    private string get_settings_file () {
        return GLib.Path.build_filename (get_config_dir (), "settings.json");
    }

    public static string load_settings_language () {
        var dir = Environment.get_user_config_dir ();
        var config_dir = GLib.Path.build_filename (dir, "filecollector");
        var file = GLib.Path.build_filename (config_dir, "settings.json");
        if (!FileUtils.test (file, FileTest.EXISTS)) {
            return "";
        }
        try {
            string content;
            size_t len;
            FileUtils.get_contents (file, out content, out len);
            var parser = new Json.Parser ();
            parser.load_from_data (content);
            var root = parser.get_root ().get_object ();
            return root.get_string_member_with_default ("language", "");
        } catch (Error e) {
            warning ("Failed to load settings: %s", e.message);
            return "";
        }
    }

    private void save_language_setting (string lang) {
        try {
            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("language");
            builder.add_string_value (lang);
            builder.end_object ();

            var generator = new Json.Generator ();
            generator.set_root (builder.get_root ());
            generator.pretty = true;

            var file = get_settings_file ();
            generator.to_file (file);
        } catch (Error e) {
            warning ("Failed to save language setting: %s", e.message);
        }
    }

    private void setup_tree_view () {
        tree_model = new Gtk.TreeStore (5, typeof (string), typeof (string), typeof (bool), typeof (bool), typeof (bool));
        dir_tree.set_model (tree_model);

        var toggle_renderer = new Gtk.CellRendererToggle ();
        toggle_renderer.activatable = true;
        toggle_renderer.toggled.connect (on_tree_toggle_toggled);

        var text_renderer = new Gtk.CellRendererText ();

        var col = new Gtk.TreeViewColumn ();
        col.pack_start (toggle_renderer, false);
        col.pack_start (text_renderer, true);
        col.add_attribute (toggle_renderer, "active", COL_CHECKED);
        col.add_attribute (toggle_renderer, "inconsistent", COL_INCONSISTENT);
        col.add_attribute (text_renderer, "text", COL_NAME);
        dir_tree.append_column (col);

        dir_tree.row_expanded.connect (on_tree_row_expanded);
        dir_tree.get_selection ().mode = Gtk.SelectionMode.NONE;
    }

    private void setup_signals () {
        open_folder_btn.clicked.connect (() => on_open_folder_clicked.begin ());
        btn_add_ext.clicked.connect (on_add_external_files);
        btn_add_text_above.clicked.connect (() => insert_text (true));
        btn_add_text_below.clicked.connect (() => insert_text (false));
        btn_move_up.clicked.connect (on_move_up);
        btn_move_down.clicked.connect (on_move_down);
        btn_delete.clicked.connect (on_delete_item);
        btn_clear.clicked.connect (on_clear_items);
        btn_generate.clicked.connect (on_generate_clicked);
        btn_generate_clipboard.clicked.connect (on_generate_to_clipboard_clicked);
        check_absolute_path.notify["active"].connect (on_path_mode_changed);
        check_write_header.notify["active"].connect (on_header_check_changed);

        queue_list.row_selected.connect (on_queue_selection_changed);
        queue_list.row_activated.connect (on_queue_row_activated);
    }

    private void setup_pane_sizes () {
        outer_paned.notify["position"].connect (clamp_outer_paned_position);
        outer_paned.notify["width"].connect (clamp_outer_paned_position);
        inner_paned.notify["position"].connect (clamp_inner_paned_position);

        GLib.Idle.add (() => {
            measure_pane_minimums ();
            clamp_outer_paned_position ();
            clamp_inner_paned_position ();
            return Source.REMOVE;
        });
    }

    private const int PANED_SEP = 6;

    private bool _clamping_inner_from_outer = false;

    private int left_min_width = 0;
    private int center_min_width = 0;
    private int right_min_width = 0;

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
        var pw = outer_paned.get_width ();
        if (pw <= 0) return;
        var pos = outer_paned.position;
        var min_pos = left_min_width;
        var cw = pw - outer_paned.get_margin_start () - outer_paned.get_margin_end ();
        var inner_needed = inner_paned.get_margin_start () + center_min_width + PANED_SEP + right_min_width;
        var max_pos = int.max (min_pos, cw - PANED_SEP - inner_needed);
        if (pos < min_pos) {
            outer_paned.position = min_pos;
        } else if (pos > max_pos) {
            outer_paned.position = max_pos;
        }

        var inner_width = cw - PANED_SEP - outer_paned.position;
        var icw = inner_width - inner_paned.get_margin_start () - inner_paned.get_margin_end ();
        var ipos = inner_paned.position;
        var imin = center_min_width;
        var imax = int.max (imin, icw - PANED_SEP - right_min_width);
        _clamping_inner_from_outer = true;
        if (ipos < imin) {
            inner_paned.position = imin;
        } else if (ipos > imax) {
            inner_paned.position = imax;
        }
        _clamping_inner_from_outer = false;
    }

    private void clamp_inner_paned_position () {
        if (_clamping_inner_from_outer) return;
        var pw = inner_paned.get_width ();
        if (pw <= 0) return;
        var pos = inner_paned.position;
        var min_pos = center_min_width;
        var cw = pw - inner_paned.get_margin_start () - inner_paned.get_margin_end ();
        var max_pos = int.max (min_pos, cw - PANED_SEP - right_min_width);
        if (pos < min_pos) {
            inner_paned.position = min_pos;
        } else if (pos > max_pos) {
            inner_paned.position = max_pos;
        }
    }

    private void on_tree_toggle_toggled (string path_str) {
        Gtk.TreeIter iter;
        var path = new Gtk.TreePath.from_string (path_str);
        if (!tree_model.get_iter (out iter, path)) return;

        bool checked;
        tree_model.get (iter, COL_CHECKED, out checked, -1);
        checked = !checked;
        tree_model.set (iter, COL_CHECKED, checked, COL_INCONSISTENT, false, -1);

        bool is_dir;
        tree_model.get (iter, COL_IS_DIR, out is_dir, -1);

        if (is_dir) {
            string dir_path;
            tree_model.get (iter, COL_PATH, out dir_path, -1);
            toggle_directory_recursive (iter, checked);
            if (dir_path != null) {
                toggle_filesystem_recursive (dir_path, checked);
            }
        } else {
            string file_path;
            tree_model.get (iter, COL_PATH, out file_path, -1);

            if (checked) {
                if (!(file_path in checked_paths)) {
                    checked_paths.insert (file_path, true);
                    items.add (new ItemData ("file", file_path, null, false));
                }
            } else {
                checked_paths.remove (file_path);
                remove_items_by_path (file_path);
            }
        }
        refresh_list ();
        var _child_path = path.copy ();
        GLib.Idle.add (() => {
            update_ancestor_states (_child_path);
            return Source.REMOVE;
        });
    }

    private void toggle_directory_recursive (Gtk.TreeIter parent_iter, bool checked) {
        Gtk.TreeIter child;
        if (!tree_model.iter_children (out child, parent_iter)) return;

        do {
            bool child_is_dir;
            tree_model.get (child, COL_IS_DIR, out child_is_dir, -1);
            tree_model.set (child, COL_CHECKED, checked, COL_INCONSISTENT, false, -1);
            if (child_is_dir) {
                toggle_directory_recursive (child, checked);
            }
        } while (tree_model.iter_next (ref child));
    }

    private void toggle_filesystem_recursive (string dir_path, bool checked) {
        var dir = File.new_for_path (dir_path);
        try {
            var enumerator = dir.enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NONE
            );
            FileInfo info;
            while ((info = enumerator.next_file ()) != null) {
                var child = dir.get_child (info.get_name ());
                if (info.get_file_type () == FileType.DIRECTORY) {
                    toggle_filesystem_recursive (child.get_path (), checked);
                } else {
                    var file_path = child.get_path ();
                    if (checked) {
                        if (!(file_path in checked_paths)) {
                            checked_paths.insert (file_path, true);
                            items.add (new ItemData ("file", file_path, null, false));
                        }
                    } else {
                        checked_paths.remove (file_path);
                        remove_items_by_path (file_path);
                    }
                }
            }
        } catch (Error e) {
            warning ("toggle_filesystem_recursive: %s", e.message);
        }
    }

    private struct FolderState {
        bool all_checked;
        bool any_checked;
    }

    private FolderState calculate_folder_state (Gtk.TreeIter parent_iter) {
        int total = 0;
        int checked = 0;

        Gtk.TreeIter child_iter;
        if (!tree_model.iter_children (out child_iter, parent_iter)) {
            return FolderState () { all_checked = false, any_checked = false };
        }

        do {
            string path;
            tree_model.get (child_iter, COL_PATH, out path, -1);
            // 跳过占位条目（无路径的）
            if (path == null) continue;

            bool is_dir;
            tree_model.get (child_iter, COL_IS_DIR, out is_dir, -1);
            bool child_checked;
            tree_model.get (child_iter, COL_CHECKED, out child_checked, -1);

            if (is_dir) {
                var child_state = calculate_folder_state (child_iter);
                if (child_state.any_checked) {
                    checked++;
                }
                total++;
                if (!child_state.all_checked) {
                    // 如果子文件夹不是全选，则整个文件夹也不是全选
                    // 但我们仍然需要计数
                }
            } else {
                if (child_checked) {
                    checked++;
                }
                total++;
            }
        } while (tree_model.iter_next (ref child_iter));

        if (total == 0) {
            return FolderState () { all_checked = false, any_checked = false };
        }

        bool all_checked = (checked == total);
        bool any_checked = (checked > 0);

        return FolderState () { all_checked = all_checked, any_checked = any_checked };
    }

    private void update_ancestor_states (Gtk.TreePath? child_path) {
        if (child_path == null) return;

        Gtk.TreeIter iter;
        if (!tree_model.get_iter (out iter, child_path)) return;

        // 从子节点开始，向上遍历每一级父节点
        while (tree_model.iter_parent (out iter, iter)) {
            // 计算该文件夹状态
            var state = calculate_folder_state (iter);

            // 更新 TreeModel
            bool should_checked = state.all_checked;
            bool should_inconsistent = state.any_checked && !state.all_checked;

            bool current_checked;
            tree_model.get (iter, COL_CHECKED, out current_checked, -1);
            bool current_inconsistent;
            tree_model.get (iter, COL_INCONSISTENT, out current_inconsistent, -1);

            if (current_checked != should_checked || current_inconsistent != should_inconsistent) {
                tree_model.set (iter, COL_CHECKED, should_checked, COL_INCONSISTENT, should_inconsistent, -1);
            }
        }
    }

    private void remove_items_by_path (string path) {
        for (int i = items.length - 1; i >= 0; i--) {
            var item = items.get (i);
            if (item.item_type == "file" && item.file_path == path) {
                items.remove_index (i);
            }
        }
    }

    private async void on_open_folder_clicked () {
        var dialog = new Gtk.FileDialog ();
        dialog.title = _("选择工作文件夹");
        try {
            var folder = yield dialog.select_folder (this, null);
            this.work_dir = folder;

            update_subtitle (folder.get_path ());

            tree_model.clear ();
            checked_paths.remove_all ();

            Gtk.TreeIter root_iter;
            tree_model.append (out root_iter, null);
            tree_model.set (root_iter, COL_NAME, folder.get_basename (), COL_PATH, folder.get_path (),
                            COL_IS_DIR, true, COL_CHECKED, false, COL_INCONSISTENT, false, -1);

            // Preload first-level children immediately (so expand will stick)
            load_directory_children (root_iter, folder);

            var root_path = new Gtk.TreePath.from_indices (0);
            dir_tree.expand_row (root_path, false);
        } catch (Error e) {
            warning ("文件夹选择失败: %s", e.message);
        }
    }

    private void update_subtitle (string? text) {
        string subtitle = text ?? _("未设置工作目录");

        // 更新窗口标题（兜底）
        title = (text != null) ? text : _("FileCollector");

        // 查找并更新 Adw.WindowTitle 的副标题
        if (_title_widget == null) {
            var header = get_titlebar () as Adw.HeaderBar;
            if (header != null && header.title_widget is Adw.WindowTitle) {
                _title_widget = (Adw.WindowTitle) header.title_widget;
            } else {
                _title_widget = find_window_title (this);
            }
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

    private void on_tree_row_expanded (Gtk.TreeIter iter, Gtk.TreePath path) {
        string dir_path;
        tree_model.get (iter, COL_PATH, out dir_path, -1);
        if (dir_path == null) return;

        var dir = File.new_for_path (dir_path);
        if (!dir.query_exists ()) return;

        Gtk.TreeIter child;
        if (tree_model.iter_children (out child, iter)) {
            string name;
            tree_model.get (child, COL_NAME, out name, -1);
            if (name == "正在加载..." || name == "") {
                tree_model.remove (ref child);
            } else {
                return;
            }
        }

        load_directory_children (iter, dir);
    }

    private void load_directory_children (Gtk.TreeIter parent, File dir) {
        try {
            var enumerator = dir.enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NONE
            );

            var dirs = new GenericArray<FileInfo> ();
            var files = new GenericArray<FileInfo> ();

            FileInfo info;
            while ((info = enumerator.next_file ()) != null) {
                if (info.get_name ().has_prefix (".")) continue;
                if (info.get_file_type () == FileType.DIRECTORY) {
                    dirs.add (info);
                } else {
                    files.add (info);
                }
            }

            dirs.sort ((a, b) => a.get_name ().collate (b.get_name ()));
            files.sort ((a, b) => a.get_name ().collate (b.get_name ()));

            foreach (var dir_info in dirs) {
                var file = dir.get_child (dir_info.get_name ());
                Gtk.TreeIter iter;
                tree_model.append (out iter, parent);
                var file_path_str = file.get_path ();
                bool is_checked = (file_path_str in checked_paths);
                tree_model.set (iter, COL_NAME, dir_info.get_name (), COL_PATH, file_path_str,
                                 COL_IS_DIR, true, COL_CHECKED, is_checked, COL_INCONSISTENT, false, -1);

                Gtk.TreeIter dummy;
                tree_model.append (out dummy, iter);
                tree_model.set (dummy, COL_NAME, "正在加载...", -1);
            }

            foreach (var file_info in files) {
                var file = dir.get_child (file_info.get_name ());
                Gtk.TreeIter iter;
                tree_model.append (out iter, parent);
                var file_path_str = file.get_path ();
                bool is_checked = (file_path_str in checked_paths);
                tree_model.set (iter, COL_NAME, file_info.get_name (), COL_PATH, file_path_str,
                                 COL_IS_DIR, false, COL_CHECKED, is_checked, COL_INCONSISTENT, false, -1);
            }

            var parent_path = tree_model.get_path (parent);
            if (parent_path != null) {
                GLib.Idle.add (() => {
                    update_ancestor_states (parent_path);
                    return Source.REMOVE;
                });
            }
        } catch (Error e) {
            warning ("无法读取目录: %s", e.message);
        }
    }

    private void refresh_list () {
        while (true) {
            var row = queue_list.get_first_child ();
            if (row == null) break;
            queue_list.remove (row);
        }

        for (int i = 0; i < items.length; i++) {
            var data = items.get (i);
            var row = new Adw.ActionRow ();

            string display_name;
            string icon_name;
            if (data.item_type == "file") {
                var file = File.new_for_path (data.file_path);
                display_name = file.get_basename ();
                icon_name = data.force_absolute ? "pin-symbolic" : "text-x-generic-symbolic";
            } else {
                var preview = data.content;
                if (preview.length > 40) preview = preview.substring (0, 40) + "...";
                display_name = preview;
                icon_name = "edit-symbolic";
            }

            row.set_title ("%d. %s".printf (i + 1, display_name));

            var icon = new Gtk.Image.from_icon_name (icon_name);
            icon.add_css_class ("dim-label");
            row.add_prefix (icon);

            row.set_activatable (true);
            queue_list.append (row);
        }
    }

    private void on_add_external_files () {
        var dialog = new Gtk.FileDialog ();
        dialog.title = _("选择外部文件");
        dialog.open_multiple.begin (this, null, (obj, res) => {
            try {
                var files = dialog.open_multiple.end (res);
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

    private void insert_text (bool above) {
        var window = new Adw.Window ();
        window.set_transient_for (this);
        window.set_modal (true);
        window.set_default_size (450, 350);
        window.set_title (_("插入自定义文字"));

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

        var phrases_btn = new Gtk.Button ();
        phrases_btn.set_label (_("常用语"));
        header_bar.pack_end (phrases_btn);

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        content.set_margin_top (12);
        content.set_margin_start (12);
        content.set_margin_end (12);
        content.set_margin_bottom (12);

        var frame = new Gtk.Frame (null);
        frame.add_css_class ("card");

        var scrolled = new Gtk.ScrolledWindow ();
        scrolled.set_vexpand (true);
        scrolled.set_min_content_height (120);

        var text_view = new Gtk.TextView ();
        text_view.set_wrap_mode (Gtk.WrapMode.WORD_CHAR);
        text_view.set_top_margin (12);
        text_view.set_bottom_margin (12);
        text_view.set_left_margin (12);
        text_view.set_right_margin (12);

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
                do_insert_text (text, above);
            }
            window.destroy ();
        });

        phrases_btn.clicked.connect (() => {
            window.destroy ();
            show_phrases_picker (above);
        });

        window.present ();
    }

    private void do_insert_text (string text, bool above) {
        var sel = queue_list.get_selected_row ();
        int current = (sel != null) ? sel.get_index () : -1;
        int index;
        if (current < 0) {
            index = above ? 0 : (int) items.length;
        } else {
            index = above ? current : current + 1;
        }
        items.insert (index, new ItemData ("text", null, text, false));
        refresh_list ();
    }

    private void populate_phrases_picker_list (Gtk.ListBox list_box, Adw.Window window, bool above) {
        while (list_box.get_first_child () != null) {
            list_box.remove (list_box.get_first_child ());
        }

        if (common_phrases.length == 0) {
            var empty_label = new Gtk.Label (_("暂无常用语"));
            empty_label.set_halign (Gtk.Align.CENTER);
            list_box.append (empty_label);
        } else {
            for (int i = 0; i < common_phrases.length; i++) {
                var phrase = common_phrases.get (i);
                var row = new Adw.ActionRow ();
                if (phrase.length > 40) {
                    row.set_title (phrase.substring (0, 40) + "...");
                } else {
                    row.set_title (phrase);
                }
                row.set_subtitle (phrase);
                row.set_activatable (true);

                var delete_btn = new Gtk.Button ();
                delete_btn.set_icon_name ("user-trash-symbolic");
                delete_btn.add_css_class ("destructive-action");
                delete_btn.add_css_class ("flat");
                delete_btn.set_valign (Gtk.Align.CENTER);
                int captured_index = i;
                delete_btn.clicked.connect (() => {
                    common_phrases.remove_index (captured_index);
                    save_common_phrases ();
                    populate_phrases_picker_list (list_box, window, above);
                });
                row.add_suffix (delete_btn);

                int phrase_index = i;
                row.activated.connect (() => {
                    var selected_phrase = common_phrases.get (phrase_index);
                    do_insert_text (selected_phrase, above);
                    window.close ();
                });

                list_box.append (row);
            }
        }
    }

    private void show_phrases_picker (bool above) {
        var window = new Adw.Window ();
        window.set_transient_for (this);
        window.set_modal (true);
        window.set_default_size (400, 400);
        window.set_title (_("选择常用语"));

        var toolbar_view = new Adw.ToolbarView ();
        window.set_content (toolbar_view);

        var header_bar = new Adw.HeaderBar ();
        header_bar.set_title_widget (new Adw.WindowTitle (_("选择常用语"), null));
        header_bar.set_decoration_layout ("");
        toolbar_view.add_top_bar (header_bar);

        var cancel_btn = new Gtk.Button ();
        cancel_btn.set_label (_("取消"));
        header_bar.pack_start (cancel_btn);

        var add_btn = new Gtk.Button ();
        add_btn.set_label (_("添加"));
        header_bar.pack_end (add_btn);

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        box.set_margin_top (12);
        box.set_margin_start (12);
        box.set_margin_end (12);
        box.set_margin_bottom (12);

        var list_box = new Gtk.ListBox ();
        list_box.set_selection_mode (Gtk.SelectionMode.NONE);
        list_box.add_css_class ("boxed-list");
        list_box.set_vexpand (true);
        box.append (list_box);

        var scrolled = new Gtk.ScrolledWindow ();
        scrolled.set_child (box);
        scrolled.set_vexpand (true);
        toolbar_view.set_content (scrolled);

        populate_phrases_picker_list (list_box, window, above);

        cancel_btn.clicked.connect (() => {
            window.close ();
        });

        add_btn.clicked.connect (() => {
            show_add_phrase_dialog (above, list_box, window);
        });

        window.present ();
    }

    private void show_add_phrase_dialog (bool above, Gtk.ListBox? list_box = null, Adw.Window? picker_window = null) {
        var dialog = new Adw.AlertDialog (_("添加常用语"), null);
        dialog.set_default_response ("add");
        dialog.add_response ("cancel", _("取消"));
        dialog.add_response ("add", _("添加"));

        var entry = new Gtk.Entry ();
        entry.set_placeholder_text (_("输入常用语"));
        entry.set_hexpand (true);
        dialog.set_extra_child (entry);

        dialog.response.connect ((resp) => {
            if (resp == "add") {
                var text = entry.get_text ().strip ();
                if (text != "") {
                    common_phrases.add (text);
                    save_common_phrases ();
                }
            }
            dialog.destroy ();
            if (resp == "add") {
                if (list_box != null && picker_window != null) {
                    populate_phrases_picker_list (list_box, picker_window, above);
                } else {
                    show_phrases_picker (above);
                }
            }
        });

        dialog.present (picker_window != null ? picker_window : this as Gtk.Widget);
    }

    private void on_move_up () {
        var row = queue_list.get_selected_row ();
        if (row == null) return;
        int index = row.get_index ();
        if (index <= 0) return;
        var tmp = items.get (index);
        items.set (index, items.get (index - 1));
        items.set (index - 1, tmp);
        refresh_list ();
        select_queue_row (index - 1);
    }

    private void on_move_down () {
        var row = queue_list.get_selected_row ();
        if (row == null) return;
        int index = row.get_index ();
        if (index >= items.length - 1) return;
        var tmp = items.get (index);
        items.set (index, items.get (index + 1));
        items.set (index + 1, tmp);
        refresh_list ();
        select_queue_row (index + 1);
    }

    private void on_delete_item () {
        var row = queue_list.get_selected_row ();
        if (row == null) return;
        int index = row.get_index ();
        var data = items.get (index);
        if (data.item_type == "file" && !data.force_absolute) {
            if (data.file_path in checked_paths) {
                checked_paths.remove (data.file_path);
                set_tree_item_check (data.file_path, false);
            }
        }
        items.remove_index (index);
        refresh_list ();
    }

    private void on_clear_items () {
        items.remove_range (0, items.length);
        checked_paths.remove_all ();
        unchecked_all_tree ();
        refresh_list ();
    }

    private void select_queue_row (int index) {
        var row = queue_list.get_row_at_index (index);
        if (row != null) queue_list.select_row (row);
    }

    private void set_tree_item_check (string abs_path, bool checked) {
        Gtk.TreeIter? iter = null;
        if (tree_model.get_iter_first (out iter)) {
            set_tree_item_check_recursive (iter, abs_path, checked);
        }
    }

    private bool set_tree_item_check_recursive (Gtk.TreeIter iter, string abs_path, bool checked) {
        do {
            string path;
            tree_model.get (iter, COL_PATH, out path, -1);
            if (path == abs_path) {
                tree_model.set (iter, COL_CHECKED, checked, COL_INCONSISTENT, false, -1);
                // 更新父级
                var current_path = tree_model.get_path (iter);
                if (current_path != null) {
                    update_ancestor_states (current_path);
                }
                return true;
            }
            Gtk.TreeIter child;
            if (tree_model.iter_children (out child, iter)) {
                if (set_tree_item_check_recursive (child, abs_path, checked))
                    return true;
            }
        } while (tree_model.iter_next (ref iter));
        return false;
    }

    private void unchecked_all_tree () {
        Gtk.TreeIter iter;
        if (!tree_model.get_iter_first (out iter)) return;
        unchecked_all_tree_recursive (iter);
    }

    private void unchecked_all_tree_recursive (Gtk.TreeIter iter) {
        do {
            tree_model.set (iter, COL_CHECKED, false, COL_INCONSISTENT, false, -1);
            Gtk.TreeIter child;
            if (tree_model.iter_children (out child, iter)) {
                unchecked_all_tree_recursive (child);
            }
        } while (tree_model.iter_next (ref iter));
    }

    private void on_queue_selection_changed (Gtk.ListBoxRow? row) {
        if (row == null) {
            preview_view.get_buffer ().set_text ("", -1);
            return;
        }
        int index = row.get_index ();
        if (index < 0 || index >= items.length) return;
        update_preview (items.get (index));
    }

    private void on_queue_row_activated (Gtk.ListBoxRow row) {
        int index = row.get_index ();
        if (index < 0 || index >= items.length) return;
        var data = items.get (index);
        if (data.item_type == "text") {
            var dialog = new Adw.AlertDialog (_("编辑文字"), _("修改文字内容："));
            var entry = new Gtk.Entry ();
            entry.set_text (data.content);
            dialog.set_extra_child (entry);
            dialog.add_response ("cancel", _("取消"));
            dialog.add_response ("ok", _("确定"));
            dialog.set_default_response ("ok");
            dialog.set_close_response ("cancel");
            dialog.response.connect ((response) => {
                if (response == "ok") {
                    var text = entry.get_text ();
                    if (text != null && text.strip () != "") {
                        data.content = text;
                        refresh_list ();
                        update_preview (data);
                    }
                }
                dialog.destroy ();
            });
            dialog.present (this);
        }
    }

    private void update_preview (ItemData item) {
        var buffer = preview_view.get_buffer ();
        if (item.item_type == "text") {
            buffer.set_text (item.content, -1);
        } else {
            try {
                string content;
                size_t length;
                FileUtils.get_contents (item.file_path, out content, out length);
                var preview = content.length > 2000 ? content.substring (0, 2000) + "\n\n... [预览截断]" : content;
                buffer.set_text (preview, -1);
            } catch (Error e) {
                buffer.set_text ("[读取错误: " + e.message + "]", -1);
            }
        }
    }

    private void on_path_mode_changed () {
        use_absolute = check_absolute_path.active;
        if (use_absolute) {
            check_write_header.active = false;
            check_write_header.sensitive = false;
        } else {
            check_write_header.sensitive = true;
        }
        refresh_list ();
    }

    private void on_header_check_changed () {
        show_header = check_write_header.active;
    }

    private void on_generate_clicked () {
        if (items.length == 0) {
            show_warning (_("编排列表为空"), _("请先勾选文件或添加文字内容。"));
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
                generate_file (path);
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED || "Dismissed" in e.message) return;
                show_error (_("保存失败"), e.message);
            }
        });
    }

    private void write_items_to_stream (DataOutputStream dis) throws Error {
        if (!use_absolute && show_header && work_dir != null) {
            var header = "# 工作目录绝对路径: %s\n\n".printf (work_dir.get_path ());
            dis.put_string (header);
        }

        for (int i = 0; i < items.length; i++) {
            if (i > 0) dis.put_string ("\n\n");
            var data = items.get (i);
            if (data.item_type == "file") {
                var f = File.new_for_path (data.file_path);
                if (!f.query_exists ()) {
                    dis.put_string ("[文件不存在: %s]\n".printf (data.file_path));
                    continue;
                }
                string display;
                if (data.force_absolute || use_absolute || work_dir == null) {
                    display = data.file_path;
                } else {
                    var wd_path = work_dir.get_path () + "/";
                    if (data.file_path.has_prefix (wd_path)) {
                        display = data.file_path.substring (wd_path.length);
                    } else {
                        display = data.file_path;
                    }
                }
                dis.put_string ("%s:\n".printf (display));
                string content;
                size_t len;
                FileUtils.get_contents (data.file_path, out content, out len);
                dis.put_string (content);
            } else {
                dis.put_string (data.content);
            }
        }
    }

    private void generate_file (string file_path) {
        try {
            var file = File.new_for_path (file_path);
            var os = file.replace (null, false, FileCreateFlags.NONE);
            var dis = new DataOutputStream (os);
            write_items_to_stream (dis);
            dis.close ();
            show_toast (_("合并文本已保存"));
        } catch (Error e) {
            show_error (_("生成失败"), e.message);
        }
    }

    private void on_generate_to_clipboard_clicked () {
        if (items.length == 0) {
            show_warning (_("编排列表为空"), _("请先勾选文件或添加文字内容。"));
            return;
        }

        try {
            var tmp_dir = Environment.get_tmp_dir ();
            var rand = Random.next_int ();
            var tmp_path = GLib.Path.build_filename (tmp_dir, "filecollector_%u.txt".printf (rand));

            var dis = new DataOutputStream (File.new_for_path (tmp_path).create (FileCreateFlags.REPLACE_DESTINATION));
            write_items_to_stream (dis);
            dis.close ();

            string content;
            size_t len;
            FileUtils.get_contents (tmp_path, out content, out len);

            File.new_for_path (tmp_path).delete ();

            var bytes = new Bytes (content.data);
            var provider = new Gdk.ContentProvider.for_bytes ("text/plain", bytes);

            var display = this.get_display ();
            display.get_clipboard ().set_content (provider);

            show_toast (_("合并文本已复制到剪贴板"));
        } catch (Error e) {
            show_error (_("复制失败"), e.message);
        }
    }

    public void on_open_project () {
        var dialog = new Gtk.FileDialog ();
        dialog.title = _("打开项目");
        var filter = new Gtk.FileFilter ();
        filter.name = _("项目文件 (*.project.json)");
        filter.add_pattern ("*.project.json");
        var filters_list = new GLib.ListStore (typeof (Gtk.FileFilter));
        filters_list.append (filter);
        dialog.set_filters (filters_list);

        dialog.open.begin (this, null, (obj, res) => {
            try {
                var file = dialog.open.end (res);
                load_project_file (file.get_path ());
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED || "Dismissed" in e.message) return;
                show_error (_("打开失败"), e.message);
            }
        });
    }

    private void load_project_file (string file_path) {
        try {
            string content;
            size_t len;
            FileUtils.get_contents (file_path, out content, out len);
            var parser = new Json.Parser ();
            parser.load_from_data (content);

            var root = parser.get_root ().get_object ();

            var wd_str = root.get_string_member_with_default ("work_dir", "");
            if (wd_str != "") {
                var wd = File.new_for_path (wd_str);
                if (wd.query_exists ()) {
                    work_dir = wd;
                    update_subtitle (wd.get_path ());
                } else {
                    work_dir = null;
                    update_subtitle (null);
                }
            } else {
                work_dir = null;
                update_subtitle (null);
            }

            tree_model.clear ();
            checked_paths.remove_all ();
            items.remove_range (0, items.length);

            if (work_dir != null) {
                Gtk.TreeIter root_iter;
                tree_model.append (out root_iter, null);
                tree_model.set (root_iter, COL_NAME, work_dir.get_basename (), COL_PATH, work_dir.get_path (),
                            COL_IS_DIR, true, COL_CHECKED, false, COL_INCONSISTENT, false, -1);
                // Preload first-level children immediately (so expand will stick)
                load_directory_children (root_iter, work_dir);

                var root_path = new Gtk.TreePath.from_indices (0);
                dir_tree.expand_row (root_path, false);
            }

            use_absolute = root.get_boolean_member_with_default ("use_absolute", false);
            show_header = root.get_boolean_member_with_default ("show_header", false);
            check_absolute_path.active = use_absolute;
            check_write_header.active = show_header;

            var checked_arr = root.get_array_member ("checked_files");
            if (checked_arr != null) {
                for (int i = 0; i < checked_arr.get_length (); i++) {
                    var p = checked_arr.get_string_element (i);
                    if (File.new_for_path (p).query_exists ()) {
                        checked_paths.insert (p, true);
                    }
                }
            }

            var items_arr = root.get_array_member ("items");
            if (items_arr != null) {
                for (int i = 0; i < items_arr.get_length (); i++) {
                    var obj = items_arr.get_object_element (i);
                    var type = obj.get_string_member ("type");
                    if (type == "file") {
                        var p = obj.get_string_member ("path");
                        var fa = obj.get_boolean_member_with_default ("force_absolute", false);
                        if (File.new_for_path (p).query_exists ()) {
                            items.add (new ItemData ("file", p, null, fa));
                        } else {
                            items.add (new ItemData ("text", null, "[缺失文件: %s]".printf (p), false));
                        }
                    } else {
                        var c = obj.get_string_member_with_default ("content", "");
                        items.add (new ItemData ("text", null, c, false));
                    }
                }
            }

            common_phrases.remove_range (0, common_phrases.length);
            var phrases_arr = root.get_array_member ("common_phrases");
            if (phrases_arr != null) {
                for (int i = 0; i < phrases_arr.get_length (); i++) {
                    common_phrases.add (phrases_arr.get_string_element (i));
                }
            }

            restore_tree_checks ();
            project_file = file_path;
            refresh_list ();
        } catch (Error e) {
            show_error (_("加载失败"), _("项目文件损坏或格式不正确:\n%s").printf (e.message));
        }
    }

    private void restore_tree_checks () {
        Gtk.TreeIter iter;
        if (!tree_model.get_iter_first (out iter)) return;
        restore_tree_checks_recursive (iter);
    }

    private void restore_tree_checks_recursive (Gtk.TreeIter iter) {
        do {
            string path;
            tree_model.get (iter, COL_PATH, out path, -1);
            if (path != null && path in checked_paths) {
                tree_model.set (iter, COL_CHECKED, true, COL_INCONSISTENT, false, -1);
            }
            Gtk.TreeIter child;
            if (tree_model.iter_children (out child, iter)) {
                restore_tree_checks_recursive (child);
            }
        } while (tree_model.iter_next (ref iter));
    }

    public void on_save_project () {
        if (project_file == null) {
            save_project_as ();
            return;
        }
        write_project_file (project_file);
    }

    private void save_project_as () {
        var dialog = new Gtk.FileDialog ();
        dialog.title = _("保存项目");
        var filter = new Gtk.FileFilter ();
        filter.name = _("项目文件 (*.project.json)");
        filter.add_pattern ("*.project.json");
        var filters_list = new GLib.ListStore (typeof (Gtk.FileFilter));
        filters_list.append (filter);
        dialog.set_filters (filters_list);

        dialog.save.begin (this, null, (obj, res) => {
            try {
                var file = dialog.save.end (res);
                project_file = file.get_path ();
                write_project_file (project_file);
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED || "Dismissed" in e.message) return;
                show_error (_("保存失败"), e.message);
            }
        });
    }

    private void write_project_file (string file_path) {
        try {
            var builder = new Json.Builder ();
            builder.begin_object ();

            builder.set_member_name ("work_dir");
            if (work_dir != null) {
                builder.add_string_value (work_dir.get_path ());
            } else {
                builder.add_null_value ();
            }

            builder.set_member_name ("use_absolute");
            builder.add_boolean_value (use_absolute);

            builder.set_member_name ("show_header");
            builder.add_boolean_value (show_header);

            builder.set_member_name ("checked_files");
            builder.begin_array ();
            var checked_list = new GenericArray<string> ();
            checked_paths.foreach ((key, val) => {
                checked_list.add (key);
            });
            for (int ci = 0; ci < checked_list.length; ci++) {
                builder.add_string_value (checked_list.get (ci));
            }
            builder.end_array ();

            builder.set_member_name ("items");
            builder.begin_array ();
            for (int i = 0; i < items.length; i++) {
                var data = items.get (i);
                builder.begin_object ();
                builder.set_member_name ("type");
                builder.add_string_value (data.item_type);
                if (data.item_type == "file") {
                    builder.set_member_name ("path");
                    builder.add_string_value (data.file_path);
                    builder.set_member_name ("force_absolute");
                    builder.add_boolean_value (data.force_absolute);
                } else {
                    builder.set_member_name ("content");
                    builder.add_string_value (data.content);
                }
                builder.end_object ();
            }
            builder.end_array ();

            builder.set_member_name ("common_phrases");
            builder.begin_array ();
            for (int i = 0; i < common_phrases.length; i++) {
                builder.add_string_value (common_phrases.get (i));
            }
            builder.end_array ();

            builder.end_object ();

            var generator = new Json.Generator ();
            generator.set_root (builder.get_root ());
            generator.pretty = true;

            try {
                var file_stream = File.new_for_path (file_path).replace (null, false, FileCreateFlags.NONE);
                generator.to_stream (file_stream, null);
            } catch (Error e) {
                var str = generator.to_data (null);
                FileUtils.set_contents (file_path, str);
            }

            project_file = file_path;
        } catch (Error e) {
            show_error (_("保存失败"), e.message);
        }
    }

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

    public void on_settings () {
        var current_lang = load_settings_language ();

        var dialog = new Adw.AlertDialog (
            _("设置"),
            _("选择界面语言：")
        );

        var group = new Gtk.CheckButton ();

        var system_btn = new Gtk.CheckButton.with_label (_("跟随系统"));
        var zh_btn = new Gtk.CheckButton.with_label ("中文");
        var en_btn = new Gtk.CheckButton.with_label ("English");

        system_btn.set_group (group);
        zh_btn.set_group (group);
        en_btn.set_group (group);

        if (current_lang == "" || current_lang == "system") {
            system_btn.active = true;
        } else if (current_lang == "zh") {
            zh_btn.active = true;
        } else if (current_lang == "en") {
            en_btn.active = true;
        }

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        box.set_margin_start (12);
        box.set_margin_end (12);
        box.set_margin_top (12);
        box.set_margin_bottom (12);
        box.append (system_btn);
        box.append (zh_btn);
        box.append (en_btn);

        dialog.set_extra_child (box);
        dialog.add_response ("cancel", _("取消"));
        dialog.add_response ("apply", _("应用"));
        dialog.set_default_response ("apply");
        dialog.set_close_response ("cancel");

        dialog.response.connect ((resp) => {
            if (resp == "apply") {
                string new_lang;
                if (system_btn.active) {
                    new_lang = "system";
                } else if (zh_btn.active) {
                    new_lang = "zh";
                } else {
                    new_lang = "en";
                }
                save_language_setting (new_lang);

                var restart_dialog = new Adw.AlertDialog (
                    _("提示"),
                    _("语言设置已保存，重启应用后生效。是否现在重启？")
                );
                restart_dialog.add_response ("later", _("稍后"));
                restart_dialog.add_response ("restart", _("立即重启"));
                restart_dialog.set_default_response ("restart");
                restart_dialog.set_close_response ("later");

                restart_dialog.response.connect ((r) => {
                    if (r == "restart") {
                        try {
                            var app = (FileCollectorApp) this.application;
                            app.quit ();
                            Process.spawn_async (
                                null,
                                {"filecollector"},
                                null,
                                SpawnFlags.SEARCH_PATH,
                                null,
                                null
                            );
                        } catch (Error e) {
                            warning ("Failed to restart: %s", e.message);
                        }
                    }
                    restart_dialog.destroy ();
                });
                restart_dialog.present (this);
            }
            dialog.destroy ();
        });

        dialog.present (this);
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

    public void on_manage_phrases () {
        var window = new Adw.Window ();
        window.set_transient_for (this);
        window.set_modal (true);
        window.set_default_size (400, 400);
        window.set_title (_("常用语管理"));

        var toolbar_view = new Adw.ToolbarView ();
        window.set_content (toolbar_view);

        var header_bar = new Adw.HeaderBar ();
        header_bar.set_title_widget (new Adw.WindowTitle (_("常用语管理"), null));
        header_bar.set_decoration_layout ("");
        toolbar_view.add_top_bar (header_bar);

        var cancel_btn = new Gtk.Button ();
        cancel_btn.set_label (_("取消"));
        header_bar.pack_start (cancel_btn);

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        box.set_margin_top (12);
        box.set_margin_start (12);
        box.set_margin_end (12);
        box.set_margin_bottom (12);

        var list_box = new Gtk.ListBox ();
        list_box.set_selection_mode (Gtk.SelectionMode.SINGLE);
        list_box.add_css_class ("boxed-list");
        list_box.set_vexpand (true);
        box.append (list_box);

        var scrolled = new Gtk.ScrolledWindow ();
        scrolled.set_child (box);
        scrolled.set_vexpand (true);
        toolbar_view.set_content (scrolled);

        refresh_phrases_list (list_box);

        var add_btn = new Gtk.Button ();
        add_btn.set_label (_("添加"));
        add_btn.add_css_class ("suggested-action");
        header_bar.pack_end (add_btn);

        cancel_btn.clicked.connect (() => {
            window.close ();
        });

        add_btn.clicked.connect (() => {
            var add_dialog = new Adw.AlertDialog (_("添加常用语"), null);
            add_dialog.add_response ("cancel", _("取消"));
            add_dialog.add_response ("add", _("添加"));
            add_dialog.set_default_response ("add");

            var entry = new Gtk.Entry ();
            entry.set_placeholder_text (_("输入常用语"));
            add_dialog.set_extra_child (entry);

            add_dialog.response.connect ((r) => {
                if (r == "add") {
                    var text = entry.get_text ().strip ();
                    if (text != "") {
                        common_phrases.add (text);
                        save_common_phrases ();
                        refresh_phrases_list (list_box);
                    }
                }
                add_dialog.destroy ();
            });
            add_dialog.present (window);
        });

        window.present ();
    }

    private void refresh_phrases_list (Gtk.ListBox list_box) {
        while (list_box.get_first_child () != null) {
            list_box.remove (list_box.get_first_child ());
        }
        for (int i = 0; i < common_phrases.length; i++) {
            var phrase = common_phrases.get (i);
            var row = new Adw.ActionRow ();
            if (phrase.length > 40) {
                row.set_title (phrase.substring (0, 40) + "...");
            } else {
                row.set_title (phrase);
            }

            var delete_btn = new Gtk.Button ();
            delete_btn.set_icon_name ("user-trash-symbolic");
            delete_btn.add_css_class ("destructive-action");
            delete_btn.add_css_class ("flat");
            delete_btn.set_valign (Gtk.Align.CENTER);
            int captured_index = i;
            delete_btn.clicked.connect (() => {
                common_phrases.remove_index (captured_index);
                save_common_phrases ();
                refresh_phrases_list (list_box);
            });
            row.add_suffix (delete_btn);
            row.set_activatable_widget (delete_btn);

            list_box.append (row);
        }
    }

    private void insert_text_above (string content) {
        var sel = queue_list.get_selected_row ();
        int current = (sel != null) ? sel.get_index () : -1;
        int index = (current >= 0) ? current : items.length;
        items.insert (index, new ItemData ("text", null, content, false));
        refresh_list ();
        select_queue_row (index);
    }
}

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
