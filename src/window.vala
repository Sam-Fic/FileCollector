using GLib;
using Gtk;
using Adw;
using Json;

// ─── Directory Item Model ───────────────────────────────────────────────

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

[GtkTemplate (ui = "/com/github/samfic/filecollector/window.ui")]
public class FileCollectorWindow : Adw.ApplicationWindow {
    [GtkChild] private unowned Gtk.TreeView dir_tree;
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
    [GtkChild] private unowned Gtk.CheckButton check_absolute_path;
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
    private HashTable<string, bool> checked_paths;
    private GenericArray<string> common_phrases;

    private UndoManager undo_manager;

    private Adw.WindowTitle? _title_widget;

    private PhrasesPicker? phrases_picker_instance = null;

    // AI 助手
    private AIPanel? ai_panel_instance = null;
    private AISettingsDialog? ai_settings_dialog_instance = null;
    private bool ai_panel_visible = false;
    // 编排模式: "default" | "directory" | "single" (与多平台版本 1:1)
    private string ai_mode = "default";
    private string ai_file_extension = "";
    private string ai_file_label = "文件";
    private int ai_max_files = 50;



    public FileCollectorWindow (Adw.Application app) {
        GLib.Object (application: app);
    }

    construct {
        items = new GenericArray<ItemData> ();
        checked_paths = new HashTable<string, bool> (str_hash, str_equal);
        common_phrases = new GenericArray<string> ();
        undo_manager = new UndoManager ();

        ConfigManager.load_common_phrases (common_phrases);
        load_css ();

        setup_queue_list ();
        setup_tree_view ();
        setup_signals ();
        setup_ai_panel ();
        setup_pane_sizes ();
        setup_shortcuts ();
        search_entry.visible = false;
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

            string display_name;
            string icon_name;
            if (data.item_type == "file") {
                var file = File.new_for_path (data.file_path);
                display_name = file.get_basename ();
                icon_name = data.force_absolute ? "document-open-symbolic" : "text-x-generic-symbolic";
            } else {
                var preview = data.content;
                if (preview.char_count () > 40) {
                    int byte_pos = 0;
                    int char_idx = 0;
                    while (byte_pos < preview.length && char_idx < 40) {
                        char b = preview[byte_pos];
                        int char_bytes;
                        if ((b & 0x80) == 0) char_bytes = 1;
                        else if ((b & 0xE0) == 0xC0) char_bytes = 2;
                        else if ((b & 0xF0) == 0xE0) char_bytes = 3;
                        else if ((b & 0xF8) == 0xF0) char_bytes = 4;
                        else char_bytes = 1;
                        if (byte_pos + char_bytes > preview.length) break;
                        byte_pos += char_bytes;
                        char_idx++;
                    }
                    preview = preview.substring (0, byte_pos) + "…";
                }
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
                    if (row.get_expanded () && item.children.get_n_items () == 0) {
                        load_directory_children_lazy (item);
                        if (item.checked) {
                            sync_children_to_checked_paths (item);
                        }
                        update_directory_states_recursive (item);
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

        var scrolled = dir_tree.get_parent () as Gtk.ScrolledWindow;
        if (scrolled != null) {
            dir_tree.visible = false;
            scrolled.set_child (dir_column_view);
        }

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
        item.set_checked_recursive (new_checked);

        update_ancestor_states_modern (item);
        dir_column_view.queue_draw ();

        GLib.Idle.add (() => {
            update_items_from_tree (item, new_checked);
            refresh_list ();
            return Source.REMOVE;
        });
    }

    private void update_items_from_tree (DirectoryItem item, bool new_checked) {
        if (item.is_dir) {
            toggle_filesystem_recursive_modern (item.path, new_checked);
        } else {
            if (new_checked) {
                if (!(item.path in checked_paths)) {
                    checked_paths.insert (item.path, true);
                    items.add (new ItemData ("file", item.path, null, false));
                }
            } else {
                checked_paths.remove (item.path);
                remove_items_by_path (item.path);
            }
        }
    }

    private void sync_children_to_checked_paths (DirectoryItem item) {
        if (!item.is_dir) return;

        for (uint i = 0; i < item.children.get_n_items (); i++) {
            var child = (DirectoryItem) item.children.get_item (i);
            if (child.is_dir) {
                sync_children_to_checked_paths (child);
            } else {
                if (child.checked && !(child.path in checked_paths)) {
                    checked_paths.insert (child.path, true);
                    items.add (new ItemData ("file", child.path, null, false));
                }
            }
        }
    }

    private void toggle_filesystem_recursive_modern (string dir_path, bool checked) {
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
                    toggle_filesystem_recursive_modern (child.get_path (), checked);
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
            warning ("toggle_filesystem_recursive_modern: %s", e.message);
        }
    }

    private void update_ancestor_states_modern (DirectoryItem item) {
        for (uint i = 0; i < root_store.get_n_items (); i++) {
            var root = (DirectoryItem) root_store.get_item (i);
            if (update_ancestor_states_recursive (root, item)) {
                break;
            }
        }
    }

    private bool update_ancestor_states_recursive (DirectoryItem current, DirectoryItem target) {
        if (current == target) {
            return true;
        }

        if (!current.is_dir) return false;

        for (uint i = 0; i < current.children.get_n_items (); i++) {
            var child = (DirectoryItem) current.children.get_item (i);
            if (update_ancestor_states_recursive (child, target)) {
                update_single_item_state (current);
                return true;
            }
        }

        return false;
    }

    private void update_single_item_state (DirectoryItem item) {
        int total = 0;
        int checked_count = 0;
        bool any_inconsistent = false;

        for (uint i = 0; i < item.children.get_n_items (); i++) {
            var child = (DirectoryItem) item.children.get_item (i);
            total++;
            if (child.is_dir) {
                if (child.inconsistent) {
                    any_inconsistent = true;
                }
                if (child.checked || child.inconsistent) {
                    checked_count++;
                }
            } else {
                if (child.checked) {
                    checked_count++;
                }
            }
        }

        if (total == 0) {
            return;
        }

        bool all_checked = !any_inconsistent && (checked_count == total);
        bool any_checked = (checked_count > 0) || any_inconsistent;

        item.checked = all_checked;
        item.inconsistent = any_checked && !all_checked;
    }

    private void update_directory_states_recursive (DirectoryItem item) {
        if (!item.is_dir) return;

        if (item.children.get_n_items () > 0) {
            for (uint i = 0; i < item.children.get_n_items (); i++) {
                var child = (DirectoryItem) item.children.get_item (i);
                if (child.is_dir) {
                    update_directory_states_recursive (child);
                }
            }
            update_single_item_state (item);
        } else {
            compute_dir_state_from_filesystem (item);
        }
    }

    private void compute_dir_state_from_filesystem (DirectoryItem item) {
        int total = 0;
        int checked_count = 0;
        count_checked_files_in_dir (item.path, ref total, ref checked_count);

        if (total == 0) return;

        bool all_checked = (checked_count == total);
        bool any_checked = (checked_count > 0);

        item.checked = all_checked;
        item.inconsistent = any_checked && !all_checked;
    }

    private void count_checked_files_in_dir (string dir_path, ref int total, ref int checked_count) {
        var dir = File.new_for_path (dir_path);
        if (!dir.query_exists ()) return;

        try {
            var enumerator = dir.enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NONE
            );
            FileInfo info;
            while ((info = enumerator.next_file ()) != null) {
                var child = dir.get_child (info.get_name ());
                if (info.get_file_type () == FileType.DIRECTORY) {
                    count_checked_files_in_dir (child.get_path (), ref total, ref checked_count);
                } else {
                    total++;
                    if (child.get_path () in checked_paths) {
                        checked_count++;
                    }
                }
            }
        } catch (Error e) {
            warning ("count_checked_files_in_dir: %s", e.message);
        }
    }

    private void push_undo_state () {
        undo_manager.push (new UndoState (items, checked_paths, use_absolute, show_header));
    }

    private void on_undo () {
        var current = new UndoState (items, checked_paths, use_absolute, show_header);
        var state = undo_manager.undo (current);
        if (state != null) {
            restore_undo_state (state);
        }
    }

    private void on_redo () {
        var current = new UndoState (items, checked_paths, use_absolute, show_header);
        var state = undo_manager.redo (current);
        if (state != null) {
            restore_undo_state (state);
        }
    }

    private void restore_undo_state (UndoState state) {
        items.remove_range (0, items.length);
        for (int i = 0; i < state.items.length; i++) {
            var it = state.items.get (i);
            items.add (new ItemData (it.item_type, it.file_path, it.content, it.force_absolute));
        }

        checked_paths.remove_all ();
        foreach (var key in state.checked_paths.get_keys ()) {
            checked_paths.insert (key, true);
        }

        use_absolute = state.use_absolute;
        show_header = state.show_header;
        check_absolute_path.notify["active"].disconnect (on_path_mode_changed);
        check_absolute_path.active = use_absolute;
        check_write_header.active = show_header;
        check_absolute_path.notify["active"].connect (on_path_mode_changed);

        if (work_dir != null && root_store.get_n_items () > 0) {
            unchecked_all_tree ();
            foreach (var path in checked_paths.get_keys ()) {
                set_tree_item_check (path, true);
            }
            var root = (DirectoryItem) root_store.get_item (0);
            update_directory_states_recursive (root);
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
        check_absolute_path.notify["active"].connect (on_path_mode_changed);
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
            measure_pane_minimums ();
            update_window_min_size ();
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
        var pw = outer_paned.get_width ();
        if (pw <= 0) return;
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
        var controller = new Gtk.ShortcutController ();

        controller.add_shortcut (new Gtk.Shortcut (
            new Gtk.KeyvalTrigger (Gdk.keyval_from_name ("g"), Gdk.ModifierType.CONTROL_MASK),
            new Gtk.CallbackAction ((widget, shortcut) => {
                on_generate_clicked ();
                return true;
            })
        ));

        controller.add_shortcut (new Gtk.Shortcut (
            new Gtk.KeyvalTrigger (Gdk.keyval_from_name ("c"), Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK),
            new Gtk.CallbackAction ((widget, shortcut) => {
                on_generate_to_clipboard_clicked ();
                return true;
            })
        ));

        controller.add_shortcut (new Gtk.Shortcut (
            new Gtk.KeyvalTrigger (Gdk.keyval_from_name ("z"), Gdk.ModifierType.CONTROL_MASK),
            new Gtk.CallbackAction ((widget, shortcut) => {
                on_undo ();
                return true;
            })
        ));

        controller.add_shortcut (new Gtk.Shortcut (
            new Gtk.KeyvalTrigger (Gdk.keyval_from_name ("z"), Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK),
            new Gtk.CallbackAction ((widget, shortcut) => {
                on_redo ();
                return true;
            })
        ));

        controller.add_shortcut (new Gtk.Shortcut (
            new Gtk.KeyvalTrigger (Gdk.keyval_from_name ("n"), Gdk.ModifierType.CONTROL_MASK),
            new Gtk.CallbackAction ((widget, shortcut) => {
                on_clear_items ();
                return true;
            })
        ));

        controller.add_shortcut (new Gtk.Shortcut (
            new Gtk.KeyvalTrigger (Gdk.keyval_from_name ("Delete"), (Gdk.ModifierType) 0),
            new Gtk.CallbackAction ((widget, shortcut) => {
                on_delete_item ();
                return true;
            })
        ));

        controller.add_shortcut (new Gtk.Shortcut (
            new Gtk.KeyvalTrigger (Gdk.keyval_from_name ("Up"), Gdk.ModifierType.CONTROL_MASK),
            new Gtk.CallbackAction ((widget, shortcut) => {
                on_move_up ();
                return true;
            })
        ));

        controller.add_shortcut (new Gtk.Shortcut (
            new Gtk.KeyvalTrigger (Gdk.keyval_from_name ("Down"), Gdk.ModifierType.CONTROL_MASK),
            new Gtk.CallbackAction ((widget, shortcut) => {
                on_move_down ();
                return true;
            })
        ));

        controller.add_shortcut (new Gtk.Shortcut (
            new Gtk.KeyvalTrigger (Gdk.keyval_from_name ("e"), Gdk.ModifierType.CONTROL_MASK),
            new Gtk.CallbackAction ((widget, shortcut) => {
                on_add_external_files ();
                return true;
            })
        ));

        controller.add_shortcut (new Gtk.Shortcut (
            new Gtk.KeyvalTrigger (Gdk.keyval_from_name ("i"), Gdk.ModifierType.CONTROL_MASK),
            new Gtk.CallbackAction ((widget, shortcut) => {
                insert_text (true);
                return true;
            })
        ));

        controller.add_shortcut (new Gtk.Shortcut (
            new Gtk.KeyvalTrigger (Gdk.keyval_from_name ("i"), Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK),
            new Gtk.CallbackAction ((widget, shortcut) => {
                insert_text (false);
                return true;
            })
        ));

        controller.add_shortcut (new Gtk.Shortcut (
            new Gtk.KeyvalTrigger (Gdk.keyval_from_name ("j"), Gdk.ModifierType.CONTROL_MASK),
            new Gtk.CallbackAction ((widget, shortcut) => {
                toggle_ai_panel ();
                return true;
            })
        ));

        this.add_controller (controller);
    }

    public CliController create_cli_from_state () {
        var cli = new CliController ();
        cli.initialize_from_state (
            work_dir,
            items,
            checked_paths,
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
        check_absolute_path.notify["active"].disconnect (on_path_mode_changed);
        check_absolute_path.active = use_absolute;
        check_write_header.active = show_header;
        check_absolute_path.notify["active"].connect (on_path_mode_changed);

        if (work_dir_changed) {
            work_dir = cli.work_dir;
            update_subtitle (work_dir.get_path ());
            root_store.remove_all ();
            var root_item = new DirectoryItem (work_dir.get_basename (), work_dir.get_path (), true);
            root_store.append (root_item);
            load_directory_children_lazy (root_item);
            update_directory_states_recursive (root_item);
            GLib.Idle.add (() => {
                var root_row = tree_list_model.get_item (0) as Gtk.TreeListRow;
                if (root_row != null) {
                    root_row.set_expanded (true);
                }
                return Source.REMOVE;
            });
            search_entry.visible = true;
        } else if (work_dir != null && root_store.get_n_items () > 0) {
            unchecked_all_tree ();
            foreach (var path in checked_paths.get_keys ()) {
                set_tree_item_check (path, true);
            }
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

    private void load_directory_children_lazy (DirectoryItem parent_item) {
        if (!parent_item.is_dir) return;

        var dir = File.new_for_path (parent_item.path);
        if (!dir.query_exists ()) return;

        try {
            var enumerator = dir.enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NONE
            );

            var dirs = new GenericArray<FileInfo> ();
            var files = new GenericArray<FileInfo> ();

            FileInfo info;
            while ((info = enumerator.next_file ()) != null) {
                if (info.get_file_type () == FileType.DIRECTORY) {
                    dirs.add (info);
                } else {
                    files.add (info);
                }
            }

            dirs.sort ((a, b) => {
                bool a_dot = a.get_name ().has_prefix (".");
                bool b_dot = b.get_name ().has_prefix (".");
                if (a_dot != b_dot) return a_dot ? -1 : 1;
                return a.get_name ().casefold ().collate (b.get_name ().casefold ());
            });
            files.sort ((a, b) => {
                bool a_dot = a.get_name ().has_prefix (".");
                bool b_dot = b.get_name ().has_prefix (".");
                if (a_dot != b_dot) return a_dot ? -1 : 1;
                return a.get_name ().casefold ().collate (b.get_name ().casefold ());
            });

            for (int i = 0; i < dirs.length; i++) {
                var fi = dirs.get (i);
                var child_path = dir.get_child (fi.get_name ()).get_path ();
                var child_item = new DirectoryItem (fi.get_name (), child_path, true);
                child_item.checked = (child_path in checked_paths) || parent_item.checked;
                parent_item.children.append (child_item);
            }

            for (int i = 0; i < files.length; i++) {
                var fi = files.get (i);
                var child_path = dir.get_child (fi.get_name ()).get_path ();
                var child_item = new DirectoryItem (fi.get_name (), child_path, false);
                child_item.checked = (child_path in checked_paths) || parent_item.checked;
                parent_item.children.append (child_item);
            }
        } catch (Error e) {
            warning ("load_directory_children_lazy: %s", e.message);
        }
    }

    private void set_tree_item_check (string abs_path, bool checked) {
        for (uint i = 0; i < root_store.get_n_items (); i++) {
            var root = (DirectoryItem) root_store.get_item (i);
            if (set_tree_item_check_recursive (root, abs_path, checked)) {
                update_ancestor_states_modern (root);
                return;
            }
        }
    }

    private bool set_tree_item_check_recursive (DirectoryItem item, string abs_path, bool checked) {
        if (item.path == abs_path) {
            item.checked = checked;
            item.inconsistent = false;
            return true;
        }

        for (uint i = 0; i < item.children.get_n_items (); i++) {
            var child = (DirectoryItem) item.children.get_item (i);
            if (set_tree_item_check_recursive (child, abs_path, checked)) {
                return true;
            }
        }
        return false;
    }

    private void unchecked_all_tree () {
        for (uint i = 0; i < root_store.get_n_items (); i++) {
            var root = (DirectoryItem) root_store.get_item (i);
            unchecked_all_tree_recursive (root);
        }
    }

    private void unchecked_all_tree_recursive (DirectoryItem item) {
        item.checked = false;
        item.inconsistent = false;
        for (uint i = 0; i < item.children.get_n_items (); i++) {
            var child = (DirectoryItem) item.children.get_item (i);
            unchecked_all_tree_recursive (child);
        }
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
                    edit_data.content = text;
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
        push_undo_state ();
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
        push_undo_state ();
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
        push_undo_state ();
        var tmp = items.get (index);
        items.set (index, items.get (index + 1));
        items.set (index + 1, tmp);
        refresh_list ();
        select_queue_row (index + 1);
    }

    private void on_delete_item () {
        int index = (int)queue_selection.selected;
        if (index < 0) return;
        push_undo_state ();
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
        push_undo_state ();
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
        push_undo_state ();
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
        push_undo_state ();
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

                ProjectManager.load_project_file (
                    file.get_path (),
                    items,
                    checked_paths,
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

                    var root_item = new DirectoryItem (work_dir.get_basename (), work_dir.get_path (), true);
                    root_store.append (root_item);

                    load_directory_children_lazy (root_item);
                    update_directory_states_recursive (root_item);
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
                    update_subtitle (null);
                }

                check_absolute_path.active = use_absolute;
                check_write_header.active = show_header;
                undo_manager.clear ();
                update_undo_redo_buttons ();
                refresh_list ();
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED || "Dismissed" in e.message) return;
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
                items, checked_paths, common_phrases
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
                    items, checked_paths, common_phrases
                );
                show_toast (_("项目文件已保存"));
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
        var window = new Adw.Window ();
        window.set_transient_for (this);
        window.set_modal (true);
        window.set_default_size (450, 350);
        window.set_title (_("编辑常用语"));

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
        text_view.get_buffer ().set_text (old_text, -1);

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
                picker.update_phrase (index, text);
            }
            window.destroy ();
        });

        window.present ();
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
        var motion = new Gtk.EventControllerMotion ();
        motion.motion.connect ((x, y) => {
            // AI 边栏隐藏时不处理
            if (!ai_sidebar.visible) return;
            int pos = (int) ai_paned.position;
            // 鼠标在 separator 附近 ±6px 范围内
            if ((x >= pos - 6) && (x <= pos + 6)) {
                ai_paned.set_cursor (new Gdk.Cursor.from_name ("col-resize", null));
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
                var arr = new string[snap.custom_instructions.length + 1];
                for (int k = 0; k < snap.custom_instructions.length; k++) {
                    arr[k] = snap.custom_instructions[k];
                }
                arr[snap.custom_instructions.length] = t;
                snap.custom_instructions = arr;
            }
        }
        snap.selected_paths = paths.to_array ();
        return snap;
    }

    // ── AI 工具执行 (主线程上跑, 通过 Idle + Cond 跨线程同步) ──────
    // AI worker 线程调用 → Idle 投递到主线程 → 主线程执行工具
    // 完成 → 通过 Cond 唤醒 worker 线程返回结果.
    private static GLib.Mutex ai_exec_mutex = GLib.Mutex ();
    private static GLib.Cond ai_exec_cond = GLib.Cond ();
    private static string? ai_exec_result = null;
    private static bool ai_exec_done = false;

    private string ai_tool_executor_cb (string name, Json.Node args) throws GLib.Error {
        string json_str = json_serialize_for_main (args);
        string name_local = name;
        string json_local = json_str;
        ai_exec_mutex.lock ();
        ai_exec_result = null;
        ai_exec_done = false;
        GLib.Idle.add (() => {
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
        while (!ai_exec_done) {
            ai_exec_cond.wait (ai_exec_mutex);
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

        // 空模式 → 匹配所有文件; PatternSpec("") 只匹配空字符串, 会导致无结果
        if (pattern.strip () == "") pattern = "*";
        // schema 声明大小写不敏感: PatternSpec 是大小写敏感的, 转小写后匹配
        var matcher = new PatternSpec (pattern.down ());

        var sb = new StringBuilder ();
        sb.append ("ROOT=").append (work_dir.get_path ()).append ("\n");
        int count = 0;
        int total = 0;
        try {
            list_files_recursive (work_dir.get_path (), work_dir.get_path (), 0, (int) max_depth,
                matcher, sb, ref count, ref total, (int) max_results);
        } catch (Error e) {
            return "读取目录失败: " + e.message;
        }
        sb.append ("\n# total ").append (total.to_string ())
          .append (" matched, listed ").append (count.to_string ());
        return sb.str;
    }

    private static void list_files_recursive (string root, string dir, int depth, int max_depth,
            PatternSpec matcher, StringBuilder sb, ref int count, ref int total, int max_results)
            throws Error {
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
                if (name == ".git" || name == "node_modules" || name == "__pycache__"
                    || name == "build" || name == ".venv" || name == "venv") {
                    continue;
                }
                if (matcher.match_string (name.down ()) && count < max_results) {
                    sb.append ("DIR  ").append (rel_path (root, full)).append ("\n");
                    count++;
                }
                list_files_recursive (root, full, depth + 1, max_depth, matcher, sb,
                    ref count, ref total, max_results);
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

        // 路径解析: 相对路径基于 work_dir
        string abs = path;
        if (work_dir != null && !GLib.Path.is_absolute (path)) {
            abs = GLib.Path.build_filename (work_dir.get_path (), path);
        }
        var file = File.new_for_path (abs);
        if (!file.query_exists ()) return "文件不存在: " + abs;

        uint8[] raw;
        try {
            FileUtils.get_data (abs, out raw);
        } catch (Error e) {
            return "读取失败: " + e.message;
        }
        string content = EncodingHelper.decode_to_utf8 (raw);
        // 行过滤
        string[] lines = content.split ("\n");
        // start_line 是 1-based, 转为 0-based 数组索引
        int start = (int) start_line - 1;
        if (start < 0) start = 0;
        if (start >= lines.length) {
            return "[文件总行数: %d, start_line %lld 越界]".printf (lines.length, start_line);
        }
        int end = int.min (lines.length, start + (int) max_lines);
        var sb = new StringBuilder ();
        sb.append ("# file: ").append (rel_path (work_dir != null ? work_dir.get_path () : "/", abs))
          .append ("  (").append (format_size (raw.length)).append (", ")
          .append (lines.length.to_string ()).append (" lines)\n");
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
        if (!GLib.Path.is_absolute (path)) {
            if (work_dir != null) {
                path = GLib.Path.build_filename (work_dir.get_path (), path);
            }
        }
        var file = File.new_for_path (path);
        if (!file.query_exists ()) return "目录不存在: " + path;
        // 已在主线程 (ai_tool_executor_cb 通过 Idle 投递), 直接执行
        ai_apply_set_work_dir (path);
        return "工作目录已切换到: " + path;
    }

    private void ai_apply_set_work_dir (string path) {
        push_undo_state ();
        items.remove_range (0, items.length);
        checked_paths.remove_all ();
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
            string abs = p;
            if (work_dir != null && !GLib.Path.is_absolute (p)) {
                abs = GLib.Path.build_filename (work_dir.get_path (), p);
            }
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
            string abs = p;
            if (work_dir != null && !GLib.Path.is_absolute (p)) {
                abs = GLib.Path.build_filename (work_dir.get_path (), p);
            }
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
        push_undo_state ();
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
        items.insert (insert_at, new ItemData ("text", null, text, false));
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
        push_undo_state ();
        var removed = items.get (idx);
        if (removed.item_type == "file" && removed.file_path != null) {
            if (removed.file_path in checked_paths) {
                checked_paths.remove (removed.file_path);
                set_tree_item_check (removed.file_path, false);
            }
        }
        items.remove_index (idx);
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
        push_undo_state ();
        var item = items.get (from);
        items.remove_index (from);
        items.insert (to, item);
        refresh_list ();
        return "已移动: %d → %d".printf (from, to);
    }

    private string ai_tool_set_use_absolute (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        var o = args.get_object ();
        if (!o.has_member ("value")) return "缺少 value";
        bool val = o.get_boolean_member ("value");
        push_undo_state ();
        use_absolute = val;
        // 临时断开信号, 避免 on_path_mode_changed 重复 push_undo_state / 联动 header
        check_absolute_path.notify["active"].disconnect (on_path_mode_changed);
        check_absolute_path.active = val;
        if (val) {
            check_write_header.active = false;
            check_write_header.sensitive = false;
            show_header = false;
        } else {
            check_write_header.sensitive = true;
        }
        check_absolute_path.notify["active"].connect (on_path_mode_changed);
        refresh_list ();
        return "use_absolute=" + val.to_string ();
    }

    private string ai_tool_set_show_header (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        var o = args.get_object ();
        if (!o.has_member ("value")) return "缺少 value";
        bool val = o.get_boolean_member ("value");
        if (use_absolute) {
            return "无法设置 show_header: 当前为绝对路径模式, header 已禁用";
        }
        push_undo_state ();
        show_header = val;
        check_write_header.notify["active"].disconnect (on_header_check_changed);
        check_write_header.active = val;
        check_write_header.notify["active"].connect (on_header_check_changed);
        return "show_header=" + val.to_string ();
    }

    private string ai_tool_remove_text (Json.Node args) throws GLib.Error {
        if (args.get_node_type () != Json.NodeType.OBJECT) return "参数错误";
        if (!args.get_object ().has_member ("index")) return "缺少 index";
        int idx = (int) args.get_object ().get_int_member ("index");
        // 已在主线程 (ai_tool_executor_cb 通过 Idle 投递), 直接执行
        push_undo_state ();
        int removed = 0;
        for (int i = items.length - 1; i >= 0; i--) {
            if (items.get (i).item_type == "text") {
                if (idx == 0) {
                    items.remove_index (i);
                    removed = 1;
                    break;
                } else {
                    idx--;
                }
            }
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
