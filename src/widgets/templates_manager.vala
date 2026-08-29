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
        dialog.set_title (_("Prompt Templates"));
        dialog.set_content_width (400);
        dialog.set_content_height (400);

        var toolbar_view = new Adw.ToolbarView ();
        dialog.set_child (toolbar_view);

        var header_bar = new Adw.HeaderBar ();
        header_bar.set_title_widget (new Adw.WindowTitle (_("Prompt Templates"), ""));
        header_bar.set_show_end_title_buttons (false);
        toolbar_view.add_top_bar (header_bar);

        var cancel_btn = new Gtk.Button.with_label (_("Close"));
        header_bar.pack_start (cancel_btn);
        cancel_btn.clicked.connect (() => dialog.close ());

        var add_btn = new Gtk.Button.with_label (_("Add"));
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
        UIHelpers.clear_container (list_box);

        foreach (var tpl in templates) {
            var row = new Adw.ActionRow ();
            row.set_title (tpl.name);
            row.set_subtitle (tpl.description);

            var edit_btn = new Gtk.Button.from_icon_name ("document-edit-symbolic");
            edit_btn.add_css_class ("flat");
            edit_btn.valign = Gtk.Align.CENTER;
            edit_btn.tooltip_text = _("Edit Text");
            PromptTemplate captured = tpl;
            edit_btn.clicked.connect (() => show_edit_dialog (captured));
            row.add_suffix (edit_btn);

            var del_btn = new Gtk.Button.from_icon_name ("user-trash-symbolic");
            del_btn.add_css_class ("flat");
            del_btn.add_css_class ("destructive-action");
            del_btn.valign = Gtk.Align.CENTER;
            del_btn.tooltip_text = _("Delete");
            del_btn.clicked.connect (() => {
                // 破坏性操作: 与项目其他删除一致, 先弹确认对话框
                var confirm = new Adw.AlertDialog (
                    _("Confirm Delete"),
                    _("Are you sure you want to delete template \"%s\"?").printf (captured.name)
                );
                confirm.add_response ("cancel", _("Cancel"));
                confirm.add_response ("delete", _("Delete"));
                confirm.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
                confirm.set_default_response ("cancel");

                confirm.response.connect ((response) => {
                    if (response == "delete") {
                        templates.remove (captured);
                        ConfigManager.save_templates (templates);
                        refresh_list ();
                    }
                    confirm.destroy ();
                });

                confirm.present (parent_window);
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
        edit_dialog.set_title (is_new ? _("Add Template") : _("Edit Template"));
        edit_dialog.set_content_width (450);
        // 不设固定高度, 让 Adw.Dialog 按内容自然尺寸自适应 (ScrolledWindow 处理溢出)

        var toolbar_view = new Adw.ToolbarView ();
        var header = new Adw.HeaderBar ();
        header.set_show_end_title_buttons (false);
        toolbar_view.add_top_bar (header);

        var cancel_btn = new Gtk.Button.with_label (_("Cancel"));
        header.pack_start (cancel_btn);
        cancel_btn.clicked.connect (() => edit_dialog.close ());

        var save_btn = new Gtk.Button.with_label (_("Save"));
        save_btn.add_css_class ("suggested-action");
        header.pack_end (save_btn);

        var group = new Adw.PreferencesGroup ();
        group.set_title (_("Template Fields"));
        group.set_description (
            _("Type \"/\" + command ID in the AI assistant input box to trigger this template.\n" +
              "After triggering, the header/footer inserted text is auto-added to the first / last position of the orchestration list, " +
              "and the AI-driven prompt is sent to the AI as a user message."));

        var entry_id = new Adw.EntryRow ();
        entry_id.set_title (_("Command ID (e.g. bug)"));
        entry_id.set_text (tpl.id);
        var entry_name = new Adw.EntryRow ();
        entry_name.set_title (_("Display Name"));
        entry_name.set_text (tpl.name);
        var entry_desc = new Adw.EntryRow ();
        entry_desc.set_title (_("Description"));
        entry_desc.set_text (tpl.description);
        var entry_header = new Adw.EntryRow ();
        entry_header.set_title (_("Insert Text Above"));
        entry_header.set_text (tpl.header_text);
        var entry_footer = new Adw.EntryRow ();
        entry_footer.set_title (_("Insert Text Below"));
        entry_footer.set_text (tpl.footer_text);
        var entry_prompt = new Adw.EntryRow ();
        entry_prompt.set_title (_("AI Prompt"));
        entry_prompt.set_text (tpl.ai_prompt);

        group.add (entry_id);
        group.add (entry_name);
        group.add (entry_desc);
        group.add (entry_header);
        group.add (entry_footer);
        group.add (entry_prompt);

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

        var prefs_page = new Adw.PreferencesPage ();
        prefs_page.add (group);

        // Adw.PreferencesPage 自身处理滚动, 直接挂到 toolbar_view 即可自适应内容高度
        // (参考 preferences_dialog.vala: 用 ToastOverlay 包 prefs_page)
        toolbar_view.set_content (prefs_page);
        edit_dialog.set_child (toolbar_view);
        edit_dialog.present (dialog);
    }
}
