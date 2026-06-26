using Gtk;
using Adw;
using Gee;

public class GlobalSearchDialog : Adw.Dialog {
    private Gtk.Window parent_window;
    private string work_dir;

    private Gtk.SearchEntry search_entry;
    private Gtk.ToggleButton btn_case_sensitive;
    private Gtk.ListBox result_list;
    private Gtk.Label lbl_status;
    private Gtk.Button btn_toggle_select;
    private Gtk.Box status_box;
    private Gtk.Button btn_add_selected;
    private Gtk.Button btn_add_all;
    private Gtk.Spinner spinner;

    private SearchService search_service;
    private GLib.Cancellable cancellable;
    private Gee.HashSet<string> matched_files;
    private Gee.HashSet<string> selected_files;

    public signal void add_files_requested (string[] paths);

    public GlobalSearchDialog (Gtk.Window parent, string dir) {
        this.parent_window = parent;
        this.work_dir = dir;
        this.matched_files = new Gee.HashSet<string> ();
        this.selected_files = new Gee.HashSet<string> ();
        build_ui ();
    }

    private void build_ui () {
        set_title (_("全局内容搜索"));
        set_content_width (650);
        set_content_height (550);

        var toolbar_view = new Adw.ToolbarView ();
        var header = new Adw.HeaderBar ();
        toolbar_view.add_top_bar (header);

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        box.margin_top = 0;
        box.margin_bottom = 12;
        box.margin_start = 12;
        box.margin_end = 12;

        // 搜索栏
        var search_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        search_entry = new Gtk.SearchEntry ();
        search_entry.placeholder_text = _("输入要搜索的代码内容… (按 Enter 搜索)");
        search_entry.hexpand = true;
        search_entry.activate.connect (trigger_search);
        search_box.append (search_entry);

        btn_case_sensitive = new Gtk.ToggleButton ();
        btn_case_sensitive.icon_name = "xsi-text-case-symbolic";
        btn_case_sensitive.tooltip_text = _("区分大小写");
        search_box.append (btn_case_sensitive);

        var btn_search = new Gtk.Button.from_icon_name ("edit-find-symbolic");
        btn_search.tooltip_text = _("搜索");
        btn_search.clicked.connect (trigger_search);
        search_box.append (btn_search);

        box.append (search_box);

        // 状态栏 (搜索开始后才显示)
        status_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        status_box.visible = false;
        spinner = new Gtk.Spinner ();
        spinner.visible = false;
        status_box.append (spinner);
        lbl_status = new Gtk.Label (null);
        lbl_status.hexpand = true;
        lbl_status.xalign = 0;
        lbl_status.add_css_class ("dim-label");
        status_box.append (lbl_status);
        box.append (status_box);

        // 结果列表
        result_list = new Gtk.ListBox ();
        result_list.set_selection_mode (Gtk.SelectionMode.NONE);
        result_list.add_css_class ("boxed-list");
        result_list.add_css_class ("search-result-list");

        var scroll = new Gtk.ScrolledWindow ();
        scroll.set_child (result_list);
        scroll.vexpand = true;
        box.append (scroll);

        // 底部按钮区
        var btn_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        btn_box.halign = Gtk.Align.CENTER;

        btn_toggle_select = new Gtk.Button.with_label (_("全选"));
        btn_toggle_select.sensitive = false;
        btn_toggle_select.clicked.connect (() => {
            bool all_selected = matched_files.size > 0 && selected_files.size >= matched_files.size;
            if (all_selected) {
                selected_files.clear ();
            } else {
                foreach (var f in matched_files) selected_files.add (f);
            }
            sync_checkboxes ();
            update_button_labels ();
        });
        btn_box.append (btn_toggle_select);

        btn_add_selected = new Gtk.Button.with_label (_("添加选中文件到编排列表"));
        btn_add_selected.add_css_class ("suggested-action");
        btn_add_selected.sensitive = false;
        btn_add_selected.clicked.connect (on_add_selected_clicked);
        btn_box.append (btn_add_selected);

        btn_add_all = new Gtk.Button.with_label (_("添加全部"));
        btn_add_all.sensitive = false;
        btn_add_all.clicked.connect (on_add_all_clicked);
        btn_box.append (btn_add_all);

        box.append (btn_box);

        toolbar_view.set_content (box);
        set_child (toolbar_view);
    }

    public void cancel_and_close () {
        if (cancellable != null) cancellable.cancel ();
        this.close ();
    }

    private void trigger_search () {
        string keyword = search_entry.text.strip ();
        if (keyword.length == 0) return;

        if (cancellable != null) cancellable.cancel ();
        cancellable = new GLib.Cancellable ();

        result_list.remove_all ();
        matched_files.clear ();
        selected_files.clear ();
        btn_add_selected.sensitive = false;
        btn_add_all.sensitive = false;
        btn_toggle_select.sensitive = false;

        spinner.visible = true;
        spinner.spinning = true;
        status_box.visible = true;
        lbl_status.label = _("正在扫描文件树...");

        search_service = new SearchService ();
        search_service.result_found.connect (on_result_found);
        search_service.progress_updated.connect (on_progress);
        search_service.finished.connect (on_finished);

        search_service.search_async (work_dir, keyword, btn_case_sensitive.active, cancellable);
    }

    private void on_result_found (SearchResult res) {
        matched_files.add (res.file_path);
        var row = create_result_row (res);
        result_list.append (row);
    }

    private void on_progress (int scanned, int matched) {
        lbl_status.label = _("已扫描 %d 个文件，找到 %d 个匹配项...").printf (scanned, matched);
    }

    private void on_finished (int total_scanned, int total_matched) {
        spinner.spinning = false;
        spinner.visible = false;
        lbl_status.label = _("搜索完成：扫描 %d 个文件，找到 %d 个匹配项（涉及 %d 个独立文件）").printf (
            total_scanned, total_matched, matched_files.size);

        bool has = matched_files.size > 0;
        btn_add_selected.sensitive = has;
        btn_add_all.sensitive = has;
        btn_toggle_select.sensitive = has;
        update_button_labels ();
    }

    private void update_button_labels () {
        bool all_selected = matched_files.size > 0 && selected_files.size >= matched_files.size;
        btn_toggle_select.label = all_selected ? _("全不选") : _("全选");
        btn_add_selected.label = _("添加选中文件到编排列表 (%d)").printf (selected_files.size);
        btn_add_all.label = _("添加全部 (%d)").printf (matched_files.size);
    }

    private void sync_checkboxes () {
        Gtk.Widget? child = result_list.get_first_child ();
        while (child != null) {
            var row = child as Gtk.ListBoxRow;
            if (row != null) {
                var hbox = row.get_child () as Gtk.Box;
                if (hbox != null) {
                    var check = hbox.get_first_child () as Gtk.CheckButton;
                    if (check != null) {
                        string? fp = check.get_data<string> ("file_path");
                        if (fp != null) {
                            check.active = (fp in selected_files);
                        }
                    }
                }
            }
            child = child.get_next_sibling ();
        }
    }

    private Gtk.ListBoxRow create_result_row (SearchResult res) {
        var hbox = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        hbox.margin_top = 6;
        hbox.margin_bottom = 6;
        hbox.margin_start = 8;
        hbox.margin_end = 8;

        var check = new Gtk.CheckButton ();
        check.valign = Gtk.Align.CENTER;
        check.set_data<string> ("file_path", res.file_path);
        check.active = (res.file_path in selected_files);

        var vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
        vbox.hexpand = true;

        var lbl_path = new Gtk.Label ("%s : %d".printf (res.rel_path, res.line_number));
        lbl_path.xalign = 0;
        lbl_path.add_css_class ("heading");
        lbl_path.ellipsize = Pango.EllipsizeMode.START;

        string keyword = search_entry.text.strip ();
        var lbl_code = new Gtk.Label (null);
        lbl_code.xalign = 0;
        lbl_code.add_css_class ("monospace");
        lbl_code.ellipsize = Pango.EllipsizeMode.END;
        if (keyword.length > 0 && btn_case_sensitive.active) {
            string escaped = GLib.Markup.escape_text (res.line_content);
            string escaped_kw = GLib.Markup.escape_text (keyword);
            string highlighted = escaped.replace (escaped_kw, "<b><span foreground='#3584e4'>" + escaped_kw + "</span></b>");
            lbl_code.set_markup (highlighted);
        } else {
            lbl_code.set_text (res.line_content);
        }

        vbox.append (lbl_path);
        vbox.append (lbl_code);
        hbox.append (check);
        hbox.append (vbox);

        string fp = res.file_path;
        check.toggled.connect (() => {
            if (check.active) {
                selected_files.add (fp);
            } else {
                selected_files.remove (fp);
            }
            update_button_labels ();
        });

        var row = new Gtk.ListBoxRow ();
        row.set_child (hbox);
        row.activatable = false;
        return row;
    }

    private void on_add_selected_clicked () {
        if (selected_files.size == 0) return;
        string[] paths = selected_files.to_array ();
        add_files_requested (paths);
        cancel_and_close ();
    }

    private void on_add_all_clicked () {
        string[] paths = matched_files.to_array ();
        add_files_requested (paths);
        cancel_and_close ();
    }
}
