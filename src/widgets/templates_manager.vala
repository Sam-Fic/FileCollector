using Gtk;
using Adw;
using Gee;

public class TemplatesManager : GLib.Object {
    private Gtk.Window? parent_window;
    private Adw.Dialog dialog;
    private Gtk.ListBox list_box;
    private Gee.ArrayList<PromptTemplate> templates;

    public TemplatesManager (Gtk.Window? parent) {
        this.parent_window = parent;
        this.templates = ConfigManager.load_templates ();
    }

    public void present () {
        dialog = new Adw.Dialog ();
        dialog.set_title (_("场景模板管理"));
        dialog.set_content_width (500);
        dialog.set_content_height (550);

        var toolbar_view = new Adw.ToolbarView ();
        var header_bar = new Adw.HeaderBar ();
        header_bar.set_show_end_title_buttons (false);
        toolbar_view.add_top_bar (header_bar);

        var cancel_btn = new Gtk.Button.with_label (_("关闭"));
        header_bar.pack_start (cancel_btn);
        cancel_btn.clicked.connect (() => dialog.close ());

        var add_btn = new Gtk.Button.with_label (_("添加模板"));
        add_btn.add_css_class ("suggested-action");
        header_bar.pack_end (add_btn);
        add_btn.clicked.connect (show_add_dialog);

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        box.margin_top = 12;
        box.margin_bottom = 12;
        box.margin_start = 12;
        box.margin_end = 12;

        list_box = new Gtk.ListBox ();
        list_box.set_selection_mode (Gtk.SelectionMode.NONE);
        list_box.add_css_class ("boxed-list");
        list_box.set_vexpand (true);

        var scrolled = new Gtk.ScrolledWindow ();
        scrolled.set_child (list_box);
        scrolled.set_vexpand (true);
        box.append (scrolled);

        toolbar_view.set_content (box);
        dialog.set_child (toolbar_view);

        refresh_list ();
        dialog.present (parent_window);
    }

    private void refresh_list () {
        var child = list_box.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            list_box.remove (child);
            child = next;
        }

        foreach (var tpl in templates) {
            var row = new Adw.ActionRow ();
            row.set_title (tpl.name);
            row.set_subtitle (tpl.description);

            var edit_btn = new Gtk.Button.from_icon_name ("document-edit-symbolic");
            edit_btn.add_css_class ("flat");
            edit_btn.valign = Gtk.Align.CENTER;
            edit_btn.tooltip_text = _("编辑");
            PromptTemplate captured = tpl;
            edit_btn.clicked.connect (() => show_edit_dialog (captured));
            row.add_suffix (edit_btn);

            var del_btn = new Gtk.Button.from_icon_name ("user-trash-symbolic");
            del_btn.add_css_class ("flat");
            del_btn.add_css_class ("destructive-action");
            del_btn.valign = Gtk.Align.CENTER;
            del_btn.tooltip_text = _("删除");
            del_btn.clicked.connect (() => {
                templates.remove (captured);
                ConfigManager.save_templates (templates);
                refresh_list ();
            });
            row.add_suffix (del_btn);

            list_box.append (row);
        }
    }

    private void show_add_dialog () {
        show_edit_dialog (new PromptTemplate ("", "", "", "", "", ""));
    }

    private void show_edit_dialog (PromptTemplate tpl) {
        bool is_new = (tpl.id == "");
        var edit_dialog = new Adw.Dialog ();
        edit_dialog.set_title (is_new ? _("添加模板") : _("编辑模板"));
        edit_dialog.set_content_width (450);
        edit_dialog.set_content_height (600);

        var toolbar_view = new Adw.ToolbarView ();
        var header = new Adw.HeaderBar ();
        header.set_show_end_title_buttons (false);
        toolbar_view.add_top_bar (header);

        var cancel_btn = new Gtk.Button.with_label (_("取消"));
        header.pack_start (cancel_btn);
        cancel_btn.clicked.connect (() => edit_dialog.close ());

        var save_btn = new Gtk.Button.with_label (_("保存"));
        save_btn.add_css_class ("suggested-action");
        header.pack_end (save_btn);

        var page = new Adw.PreferencesPage ();
        var group = new Adw.PreferencesGroup ();
        page.add (group);

        var entry_id = new Adw.EntryRow ();
        entry_id.set_title (_("指令 ID (如 bug)"));
        entry_id.set_text (tpl.id);
        var entry_name = new Adw.EntryRow ();
        entry_name.set_title (_("显示名称"));
        entry_name.set_text (tpl.name);
        var entry_desc = new Adw.EntryRow ();
        entry_desc.set_title (_("描述"));
        entry_desc.set_text (tpl.description);

        group.add (entry_id);
        group.add (entry_name);
        group.add (entry_desc);

        var text_group = new Adw.PreferencesGroup ();
        text_group.set_title (_("内容配置"));
        page.add (text_group);

        var text_header = make_text_area (_("头部插入文本"), tpl.header_text);
        var text_footer = make_text_area (_("尾部插入文本"), tpl.footer_text);
        var text_prompt = make_text_area (_("AI 驱动提示词"), tpl.ai_prompt);

        text_group.add (text_header);
        text_group.add (text_footer);
        text_group.add (text_prompt);

        save_btn.clicked.connect (() => {
            tpl.id = entry_id.get_text ().strip ();
            tpl.name = entry_name.get_text ().strip ();
            tpl.description = entry_desc.get_text ().strip ();
            tpl.header_text = get_text_area_content (text_header);
            tpl.footer_text = get_text_area_content (text_footer);
            tpl.ai_prompt = get_text_area_content (text_prompt);

            if (tpl.id == "" || tpl.name == "") return;

            bool exists = false;
            for (int i = 0; i < templates.size; i++) {
                if (templates.get (i).id == tpl.id) {
                    templates.set (i, tpl);
                    exists = true;
                    break;
                }
            }
            if (!exists) templates.add (tpl);

            ConfigManager.save_templates (templates);
            refresh_list ();
            edit_dialog.close ();
        });

        toolbar_view.set_content (page);
        edit_dialog.set_child (toolbar_view);
        edit_dialog.present (dialog);
    }

    private Adw.ExpanderRow make_text_area (string title, string content) {
        var row = new Adw.ExpanderRow ();
        row.set_title (title);
        var scrolled = new Gtk.ScrolledWindow ();
        scrolled.set_min_content_height (100);
        var tv = new Gtk.TextView ();
        tv.set_wrap_mode (Gtk.WrapMode.WORD_CHAR);
        tv.set_top_margin (6);
        tv.set_bottom_margin (6);
        tv.set_left_margin (6);
        tv.set_right_margin (6);
        tv.get_buffer ().set_text (content, -1);
        scrolled.set_child (tv);
        row.add_row (scrolled);
        return row;
    }

    private string get_text_area_content (Adw.ExpanderRow row) {
        var child = row.get_last_child ();
        if (child == null) return "";
        var scrolled = child as Gtk.ScrolledWindow;
        if (scrolled == null) return "";
        var tv = scrolled.get_child () as Gtk.TextView;
        if (tv == null) return "";
        Gtk.TextIter s, e;
        tv.get_buffer ().get_bounds (out s, out e);
        return tv.get_buffer ().get_text (s, e, false);
    }
}
