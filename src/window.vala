using GLib;
using Gtk;
using Adw;
using Json;

[GtkTemplate (ui = "/com/github/samfic/filecollector/window.ui")]
public class FileCollectorWindow : Adw.ApplicationWindow {
    [GtkChild] private unowned Gtk.TreeView dir_tree;
    [GtkChild] private unowned Gtk.ListView queue_list;
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
    [GtkChild] private unowned Adw.ToastOverlay toast_overlay;
    [GtkChild] private unowned Gtk.Paned outer_paned;
    [GtkChild] private unowned Gtk.Paned inner_paned;

    private Gtk.TreeStore tree_model;
    private File? work_dir = null;
    private string? project_file = null;
    private bool use_absolute = false;
    private bool show_header = false;

    private GLib.ListStore queue_store;
    private Gtk.SingleSelection queue_selection;

    private GenericArray<ItemData> items;
    private HashTable<string, bool> checked_paths;
    private GenericArray<string> common_phrases;

    private Adw.WindowTitle? _title_widget;

    private PhrasesPicker? phrases_picker_instance = null;



    public FileCollectorWindow (Adw.Application app) {
        GLib.Object (application: app);
    }

    construct {
        items = new GenericArray<ItemData> ();
        checked_paths = new HashTable<string, bool> (str_hash, str_equal);
        common_phrases = new GenericArray<string> ();

        ConfigManager.load_common_phrases (common_phrases);
        load_css ();

        setup_queue_list ();
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
            var data = list_item.get_item () as ItemData;
            var box = list_item.get_child () as Gtk.Box;

            var icon = box.get_first_child () as Gtk.Image;
            var label = icon.get_next_sibling () as Gtk.Label;

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

            var pos = list_item.get_position ();
            label.set_text ("%d. %s".printf ((int)pos + 1, display_name));
            icon.icon_name = icon_name;
        });

        queue_list.model = queue_selection;
        queue_list.factory = factory;
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
        col.add_attribute (toggle_renderer, "active", TreeHelper.COL_CHECKED);
        col.add_attribute (toggle_renderer, "inconsistent", TreeHelper.COL_INCONSISTENT);
        col.add_attribute (text_renderer, "text", TreeHelper.COL_NAME);
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

        queue_selection.selection_changed.connect (on_queue_selection_changed);
        queue_list.activate.connect (on_queue_row_activated);

        update_queue_buttons ();
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

    // ─── Tree View ───────────────────────────────────────────────────────

    private void on_tree_toggle_toggled (string path_str) {
        Gtk.TreeIter iter;
        var path = new Gtk.TreePath.from_string (path_str);
        if (!tree_model.get_iter (out iter, path)) return;

        bool checked;
        tree_model.get (iter, TreeHelper.COL_CHECKED, out checked, -1);
        checked = !checked;
        tree_model.set (iter, TreeHelper.COL_CHECKED, checked, TreeHelper.COL_INCONSISTENT, false, -1);

        bool is_dir;
        tree_model.get (iter, TreeHelper.COL_IS_DIR, out is_dir, -1);

        if (is_dir) {
            string dir_path;
            tree_model.get (iter, TreeHelper.COL_PATH, out dir_path, -1);
            toggle_directory_recursive (iter, checked);
            if (dir_path != null) {
                toggle_filesystem_recursive (dir_path, checked);
            }
        } else {
            string file_path;
            tree_model.get (iter, TreeHelper.COL_PATH, out file_path, -1);

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
            tree_model.get (child, TreeHelper.COL_IS_DIR, out child_is_dir, -1);
            tree_model.set (child, TreeHelper.COL_CHECKED, checked, TreeHelper.COL_INCONSISTENT, false, -1);
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
            tree_model.get (child_iter, TreeHelper.COL_PATH, out path, -1);
            if (path == null) continue;

            bool is_dir;
            tree_model.get (child_iter, TreeHelper.COL_IS_DIR, out is_dir, -1);
            bool child_checked;
            tree_model.get (child_iter, TreeHelper.COL_CHECKED, out child_checked, -1);

            if (is_dir) {
                var child_state = calculate_folder_state (child_iter);
                if (child_state.any_checked) {
                    checked++;
                }
                total++;
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

        while (tree_model.iter_parent (out iter, iter)) {
            var state = calculate_folder_state (iter);

            bool should_checked = state.all_checked;
            bool should_inconsistent = state.any_checked && !state.all_checked;

            bool current_checked;
            tree_model.get (iter, TreeHelper.COL_CHECKED, out current_checked, -1);
            bool current_inconsistent;
            tree_model.get (iter, TreeHelper.COL_INCONSISTENT, out current_inconsistent, -1);

            if (current_checked != should_checked || current_inconsistent != should_inconsistent) {
                tree_model.set (iter, TreeHelper.COL_CHECKED, should_checked, TreeHelper.COL_INCONSISTENT, should_inconsistent, -1);
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
            tree_model.set (root_iter, TreeHelper.COL_NAME, folder.get_basename (), TreeHelper.COL_PATH, folder.get_path (),
                            TreeHelper.COL_IS_DIR, true, TreeHelper.COL_CHECKED, false, TreeHelper.COL_INCONSISTENT, false, -1);

            load_directory_children_with_ancestor_update (root_iter, folder);

            var root_path = new Gtk.TreePath.from_indices (0);
            dir_tree.expand_row (root_path, false);
        } catch (Error e) {
            warning ("文件夹选择失败: %s", e.message);
        }
    }

    private void on_tree_row_expanded (Gtk.TreeIter iter, Gtk.TreePath path) {
        string dir_path;
        tree_model.get (iter, TreeHelper.COL_PATH, out dir_path, -1);
        if (dir_path == null) return;

        var dir = File.new_for_path (dir_path);
        if (!dir.query_exists ()) return;

        Gtk.TreeIter child;
        if (tree_model.iter_children (out child, iter)) {
            string name;
            tree_model.get (child, TreeHelper.COL_NAME, out name, -1);
            if (name == _("正在加载...") || name == "") {
                tree_model.remove (ref child);
            } else {
                return;
            }
        }

        load_directory_children_with_ancestor_update (iter, dir);
    }

    private void load_directory_children_with_ancestor_update (Gtk.TreeIter parent, File dir) {
        TreeHelper.load_directory_children (parent, dir, tree_model, checked_paths);
        var parent_path = tree_model.get_path (parent);
        if (parent_path != null) {
            GLib.Idle.add (() => {
                update_ancestor_states (parent_path);
                return Source.REMOVE;
            });
        }
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
            tree_model.get (iter, TreeHelper.COL_PATH, out path, -1);
            if (path == abs_path) {
                tree_model.set (iter, TreeHelper.COL_CHECKED, checked, TreeHelper.COL_INCONSISTENT, false, -1);
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
            tree_model.set (iter, TreeHelper.COL_CHECKED, false, TreeHelper.COL_INCONSISTENT, false, -1);
            Gtk.TreeIter child;
            if (tree_model.iter_children (out child, iter)) {
                unchecked_all_tree_recursive (child);
            }
        } while (tree_model.iter_next (ref iter));
    }

    // ─── Queue List ──────────────────────────────────────────────────────

    private void refresh_list () {
        bool had_selection = (int)queue_selection.selected >= 0;
        uint old_selected = queue_selection.selected;

        uint n = queue_store.get_n_items ();
        if (n > 0) {
            queue_store.splice (0, n, null);
        }

        for (int i = 0; i < items.length; i++) {
            queue_store.append (items.get (i));
        }

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
        btn_move_up.sensitive = has_selection;
        btn_move_down.sensitive = has_selection;
        btn_delete.sensitive = has_selection;
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
            get_phrases_picker ().show_picker (above);
        });

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
        items.insert (index, new ItemData ("text", null, text, false));
        refresh_list ();
    }

    private void on_move_up () {
        int index = (int)queue_selection.selected;
        if (index < 0) return;
        if (index <= 0) return;
        var tmp = items.get (index);
        items.set (index, items.get (index - 1));
        items.set (index - 1, tmp);
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
        refresh_list ();
        select_queue_row (index + 1);
    }

    private void on_delete_item () {
        int index = (int)queue_selection.selected;
        if (index < 0) return;
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
        if (index >= 0 && index < items.length) {
            queue_selection.selected = index;
        }
    }

    private void on_queue_selection_changed (uint position, uint n_items) {
        update_queue_buttons ();

        int sel = (int)queue_selection.selected;
        if (sel < 0 || sel >= items.length) {
            preview_view.get_buffer ().set_text ("", -1);
            return;
        }
        update_preview (items.get (sel));
    }

    private void on_queue_row_activated (uint position) {
        int index = (int)position;
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
            buffer.set_text (item.content.make_valid (), -1);
        } else {
            try {
                uint8[] file_data;
                FileUtils.get_data (item.file_path, out file_data);
                file_data += (uint8)'\0';
                string content = (string)file_data;
                var preview = content.make_valid ();
                if (preview.length > 2000) {
                    preview = preview.substring (0, 2000).make_valid ();
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

    // ─── Generate ────────────────────────────────────────────────────────

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
                FileGenerator.generate_file (path, items, use_absolute, show_header, work_dir);
                show_toast (_("合并文本已保存"));
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED || "Dismissed" in e.message) return;
                show_error (_("保存失败"), e.message);
            }
        });
    }

    private void on_generate_to_clipboard_clicked () {
        if (items.length == 0) {
            show_warning (_("编排列表为空"), _("请先勾选文件或添加文字内容。"));
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
        filter.name = _("项目文件 (*.project.json)");
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

                ProjectManager.load_project_file (
                    file.get_path (),
                    items,
                    checked_paths,
                    common_phrases,
                    tree_model,
                    dir_tree,
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
                } else {
                    update_subtitle (null);
                }

                check_absolute_path.active = use_absolute;
                check_write_header.active = show_header;
                refresh_list ();
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED || "Dismissed" in e.message) return;
                show_error (_("打开失败"), e.message);
            }
        });
    }

    public void on_save_project () {
        if (project_file == null) {
            save_project_as ();
            return;
        }
        try {
            ProjectManager.write_project_file (
                project_file, work_dir, use_absolute, show_header,
                items, checked_paths, common_phrases
            );
        } catch (Error e) {
            show_error (_("保存失败"), e.message);
        }
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
                ProjectManager.write_project_file (
                    project_file, work_dir, use_absolute, show_header,
                    items, checked_paths, common_phrases
                );
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED || "Dismissed" in e.message) return;
                show_error (_("保存失败"), e.message);
            }
        });
    }

    // ─── Subtitle ────────────────────────────────────────────────────────

    private void update_subtitle (string? text) {
        string subtitle = text ?? _("未设置工作目录");

        title = (text != null) ? text : _("FileCollector");

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

    private PhrasesPicker get_phrases_picker () {
        if (phrases_picker_instance == null) {
            phrases_picker_instance = new PhrasesPicker (this, common_phrases);
            phrases_picker_instance.phrase_selected.connect ((phrase, above) => {
                do_insert_text (phrase, above);
            });
        }
        return phrases_picker_instance;
    }
}
