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
    private Gtk.Stack result_stack;
    private Adw.StatusPage empty_page;
    private Adw.StatusPage guide_page;

    private SearchService search_service;
    private GLib.Cancellable cancellable;
    private Gee.HashSet<string> matched_files;
    private Gee.HashSet<string> selected_files;
    private Gee.HashMap<string, Gtk.Revealer> file_revealers;
    private Gee.HashMap<string, Gtk.Box> file_matches_boxes;
    private Gee.HashMap<string, Gtk.CheckButton> file_checks;
    private Gee.HashMap<string, Gtk.Button> file_arrow_buttons;

    public signal void add_files_requested (string[] paths);

    public GlobalSearchDialog (Gtk.Window parent, string dir) {
        this.parent_window = parent;
        this.work_dir = dir;
        this.matched_files = new Gee.HashSet<string> ();
        this.selected_files = new Gee.HashSet<string> ();
        this.file_revealers = new Gee.HashMap<string, Gtk.Revealer> ();
        this.file_matches_boxes = new Gee.HashMap<string, Gtk.Box> ();
        this.file_checks = new Gee.HashMap<string, Gtk.CheckButton> ();
        this.file_arrow_buttons = new Gee.HashMap<string, Gtk.Button> ();
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
        search_entry.placeholder_text = _("输入要搜索的代码内容…");
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

        // 结果列表 / 空状态
        result_list = new Gtk.ListBox ();
        result_list.set_selection_mode (Gtk.SelectionMode.NONE);
        result_list.add_css_class ("boxed-list");
        result_list.add_css_class ("search-result-list");

        var scroll = new Gtk.ScrolledWindow ();
        scroll.set_child (result_list);
        scroll.vexpand = true;

        empty_page = new Adw.StatusPage ();
        empty_page.icon_name = "edit-find-symbolic";
        empty_page.title = _("未找到匹配项");
        empty_page.description = _("没有文件包含该关键词。请尝试其他关键词或调整搜索选项。");
        empty_page.vexpand = true;

        guide_page = new Adw.StatusPage ();
        guide_page.icon_name = "edit-find-symbolic";
        guide_page.title = _("全局内容搜索");
        guide_page.description = _("输入关键词并按下 Enter 或点击搜索按钮，即可在整个工作目录中查找匹配的代码与文本。");
        guide_page.vexpand = true;

        result_stack = new Gtk.Stack ();
        result_stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
        result_stack.add_named (scroll, "results");
        result_stack.add_named (empty_page, "empty");
        result_stack.add_named (guide_page, "guide");
        result_stack.visible_child_name = "guide";
        result_stack.vexpand = true;
        box.append (result_stack);

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

        result_stack.visible_child_name = "results";

        result_list.remove_all ();
        matched_files.clear ();
        selected_files.clear ();
        file_revealers.clear ();
        file_matches_boxes.clear ();
        file_checks.clear ();
        file_arrow_buttons.clear ();
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
        ensure_file_row (res.file_path, res.rel_path);
        add_match_row (res);
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
        result_stack.visible_child_name = has ? "results" : "empty";
        update_button_labels ();
    }

    private void update_button_labels () {
        bool all_selected = matched_files.size > 0 && selected_files.size >= matched_files.size;
        btn_toggle_select.label = all_selected ? _("全不选") : _("全选");
        btn_add_selected.label = _("添加选中文件到编排列表 (%d)").printf (selected_files.size);
        btn_add_all.label = _("添加全部 (%d)").printf (matched_files.size);
    }

    private void sync_checkboxes () {
        foreach (string fp in file_checks.keys) {
            file_checks[fp].active = (fp in selected_files);
        }
    }

    private void ensure_file_row (string file_path, string rel_path) {
        if (file_revealers.has_key (file_path)) {
            return;
        }

        var check = new Gtk.CheckButton ();
        check.valign = Gtk.Align.CENTER;
        check.set_data<string> ("file_path", file_path);
        check.active = (file_path in selected_files);

        var arrow_btn = new Gtk.Button.from_icon_name ("pan-end-symbolic");
        arrow_btn.add_css_class ("flat");
        arrow_btn.valign = Gtk.Align.CENTER;
        arrow_btn.tooltip_text = _("展开");

        var filename_lbl = new Gtk.Label (rel_path);
        filename_lbl.xalign = 0;
        filename_lbl.hexpand = true;
        filename_lbl.ellipsize = Pango.EllipsizeMode.START;
        filename_lbl.add_css_class ("heading");

        var file_hbox = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        file_hbox.margin_top = 8;
        file_hbox.margin_bottom = 8;
        file_hbox.margin_start = 8;
        file_hbox.margin_end = 8;
        file_hbox.append (arrow_btn);
        file_hbox.append (check);
        file_hbox.append (filename_lbl);

        var matches_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        matches_box.margin_start = 52;
        matches_box.margin_end = 8;
        matches_box.margin_bottom = 8;

        var revealer = new Gtk.Revealer ();
        revealer.set_child (matches_box);
        revealer.reveal_child = false;

        var vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        vbox.append (file_hbox);
        vbox.append (revealer);

        var row = new Gtk.ListBoxRow ();
        row.set_child (vbox);
        row.activatable = false;

        result_list.append (row);

        arrow_btn.clicked.connect (() => {
            bool expanded = !revealer.reveal_child;
            revealer.reveal_child = expanded;
            arrow_btn.icon_name = expanded ? "pan-down-symbolic" : "pan-end-symbolic";
            arrow_btn.tooltip_text = expanded ? _("收起") : _("展开");
        });

        check.toggled.connect (() => {
            if (check.active) {
                selected_files.add (file_path);
            } else {
                selected_files.remove (file_path);
            }
            update_button_labels ();
        });

        file_revealers[file_path] = revealer;
        file_matches_boxes[file_path] = matches_box;
        file_checks[file_path] = check;
        file_arrow_buttons[file_path] = arrow_btn;
    }

    private void add_match_row (SearchResult res) {
        var matches_box = file_matches_boxes[res.file_path];

        var hbox = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        hbox.margin_top = 4;
        hbox.margin_bottom = 4;

        var line_lbl = new Gtk.Label ("%d".printf (res.line_number));
        line_lbl.xalign = 0;
        line_lbl.add_css_class ("dim-label");

        string keyword = search_entry.text.strip ();
        string highlighted = highlight_keyword (res.line_content, keyword, btn_case_sensitive.active);

        var content_lbl = new Gtk.Label (null);
        content_lbl.set_markup (highlighted);
        content_lbl.xalign = 0;
        content_lbl.hexpand = true;
        content_lbl.wrap = true;
        content_lbl.wrap_mode = Pango.WrapMode.WORD_CHAR;

        hbox.append (line_lbl);
        hbox.append (content_lbl);
        matches_box.append (hbox);
    }

    private string highlight_keyword (string text, string keyword, bool case_sensitive) {
        if (keyword.length == 0) {
            return GLib.Markup.escape_text (text);
        }

        var result = new StringBuilder ();
        int text_chars = text.char_count ();
        int kw_chars = keyword.char_count ();
        int last = 0;
        int i = 0;

        while (i <= text_chars - kw_chars) {
            int byte_start = text.index_of_nth_char (i);
            int byte_end = text.index_of_nth_char (i + kw_chars);
            string candidate = text.slice (byte_start, byte_end);

            bool is_match = case_sensitive
                ? candidate == keyword
                : candidate.down () == keyword.down ();

            if (is_match) {
                int prev_byte_end = text.index_of_nth_char (last);
                result.append (GLib.Markup.escape_text (text.slice (prev_byte_end, byte_start)));
                result.append ("<b><span foreground='#3584e4'>");
                result.append (GLib.Markup.escape_text (candidate));
                result.append ("</span></b>");
                last = i + kw_chars;
                i = last;
            } else {
                i++;
            }
        }

        result.append (GLib.Markup.escape_text (text.slice (text.index_of_nth_char (last), text.length)));
        return result.str;
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
