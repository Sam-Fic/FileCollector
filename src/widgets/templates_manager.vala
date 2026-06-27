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
        dialog.set_content_width (400);
        dialog.set_content_height (400);

        var toolbar_view = new Adw.ToolbarView ();
        dialog.set_child (toolbar_view);

        var header_bar = new Adw.HeaderBar ();
        header_bar.set_title_widget (new Adw.WindowTitle (_("场景模板管理"), ""));
        header_bar.set_show_end_title_buttons (false);
        toolbar_view.add_top_bar (header_bar);

        var cancel_btn = new Gtk.Button.with_label (_("关闭"));
        header_bar.pack_start (cancel_btn);
        cancel_btn.clicked.connect (() => dialog.close ());

        var add_btn = new Gtk.Button.with_label (_("添加"));
        add_btn.add_css_class ("suggested-action");
        header_bar.pack_end (add_btn);
        add_btn.clicked.connect (show_add_dialog);

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        box.margin_top = 0;
        box.margin_start = 12;
        box.margin_end = 12;
        box.margin_bottom = 12;

        list_box = new Gtk.ListBox ();
        list_box.set_selection_mode (Gtk.SelectionMode.NONE);
        list_box.add_css_class ("boxed-list");
        list_box.add_css_class ("phrases-list");
        list_box.set_vexpand (true);
        box.append (list_box);

        var scrolled = new Gtk.ScrolledWindow ();
        scrolled.set_child (box);
        scrolled.set_vexpand (true);
        toolbar_view.set_content (scrolled);
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
        edit_dialog.set_content_height (400);

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

        var list_box = new Gtk.ListBox ();
        list_box.add_css_class ("boxed-list");
        list_box.margin_top = 0;
        list_box.margin_bottom = 12;
        list_box.margin_start = 12;
        list_box.margin_end = 12;

        var entry_id = new Adw.EntryRow ();
        entry_id.set_title (_("指令 ID (如 bug)"));
        entry_id.set_text (tpl.id);
        var entry_name = new Adw.EntryRow ();
        entry_name.set_title (_("显示名称"));
        entry_name.set_text (tpl.name);
        var entry_desc = new Adw.EntryRow ();
        entry_desc.set_title (_("描述"));
        entry_desc.set_text (tpl.description);

        list_box.append (entry_id);
        list_box.append (entry_name);
        list_box.append (entry_desc);

        var entry_header = new Adw.EntryRow ();
        entry_header.set_title (_("头部插入文本"));
        entry_header.set_text (tpl.header_text);
        var entry_footer = new Adw.EntryRow ();
        entry_footer.set_title (_("尾部插入文本"));
        entry_footer.set_text (tpl.footer_text);
        var entry_prompt = new Adw.EntryRow ();
        entry_prompt.set_title (_("AI 驱动提示词"));
        entry_prompt.set_text (tpl.ai_prompt);

        list_box.append (entry_header);
        list_box.append (entry_footer);
        list_box.append (entry_prompt);

        save_btn.clicked.connect (() => {
            tpl.id = entry_id.get_text ().strip ();
            tpl.name = entry_name.get_text ().strip ();
            tpl.description = entry_desc.get_text ().strip ();
            tpl.header_text = entry_header.get_text ().strip ();
            tpl.footer_text = entry_footer.get_text ().strip ();
            tpl.ai_prompt = entry_prompt.get_text ().strip ();

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

        toolbar_view.set_content (list_box);
        edit_dialog.set_child (toolbar_view);
        edit_dialog.present (dialog);
    }
}
