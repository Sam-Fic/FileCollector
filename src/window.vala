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
            save_project_as ();
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

    private void save_project_as () {
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
}
