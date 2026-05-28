public class PhrasesPicker : GLib.Object {
    private Gtk.Window? parent_window;
    private GenericArray<string> common_phrases;

    public signal void phrase_selected (string phrase, bool above);
    public signal void phrases_changed ();

    public PhrasesPicker (Gtk.Window? parent, GenericArray<string> phrases) {
        this.parent_window = parent;
        this.common_phrases = phrases;
    }

    public void show_picker (bool above) {
        var window = new Adw.Window ();
        window.set_transient_for (parent_window);
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

    public void show_manage_window () {
        var window = new Adw.Window ();
        window.set_transient_for (parent_window);
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
                        ConfigManager.save_common_phrases (common_phrases);
                        refresh_phrases_list (list_box);
                        phrases_changed ();
                    }
                }
                add_dialog.destroy ();
            });
            add_dialog.present (window);
        });

        window.present ();
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
                    ConfigManager.save_common_phrases (common_phrases);
                    populate_phrases_picker_list (list_box, window, above);
                    phrases_changed ();
                });
                row.add_suffix (delete_btn);

                int phrase_index = i;
                row.activated.connect (() => {
                    var selected_phrase = common_phrases.get (phrase_index);
                    phrase_selected (selected_phrase, above);
                    window.close ();
                });

                list_box.append (row);
            }
        }
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
                    ConfigManager.save_common_phrases (common_phrases);
                }
            }
            dialog.destroy ();
            if (resp == "add") {
                if (list_box != null && picker_window != null) {
                    populate_phrases_picker_list (list_box, picker_window, above);
                } else {
                    show_picker (above);
                }
                phrases_changed ();
            }
        });

        dialog.present (picker_window != null ? picker_window : parent_window as Gtk.Widget);
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
                ConfigManager.save_common_phrases (common_phrases);
                refresh_phrases_list (list_box);
                phrases_changed ();
            });
            row.add_suffix (delete_btn);
            row.set_activatable_widget (delete_btn);

            list_box.append (row);
        }
    }
}
