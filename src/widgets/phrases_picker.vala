public class PhrasesPicker : GLib.Object {
    private Gtk.Window? parent_window;
    private GenericArray<string> common_phrases;
    private Gtk.ListBox? current_list_box;

    public signal void phrase_selected (string phrase, bool above);
    public signal void phrases_changed ();
    public signal void edit_phrase_requested (string old_text, int index);

    public PhrasesPicker (Gtk.Window? parent, GenericArray<string> phrases) {
        this.parent_window = parent;
        this.common_phrases = phrases;
    }

    public void update_phrase (int index, string new_text) {
        common_phrases.set (index, new_text);
        ConfigManager.save_common_phrases (common_phrases);
        if (current_list_box != null) {
            refresh_phrases_list (current_list_box);
        }
        phrases_changed ();
    }

    public void show_picker (bool above) {
        current_list_box = null;
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

        current_list_box = new Gtk.ListBox ();
        current_list_box.set_selection_mode (Gtk.SelectionMode.NONE);
        current_list_box.add_css_class ("boxed-list");
        current_list_box.set_vexpand (true);
        box.append (current_list_box);

        var scrolled = new Gtk.ScrolledWindow ();
        scrolled.set_child (box);
        scrolled.set_vexpand (true);
        toolbar_view.set_content (scrolled);

        populate_phrases_picker_list (current_list_box, window, above);

        cancel_btn.clicked.connect (() => {
            window.close ();
        });

        add_btn.clicked.connect (() => {
            show_add_phrase_dialog (above, current_list_box, window);
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

        current_list_box = new Gtk.ListBox ();
        current_list_box.set_selection_mode (Gtk.SelectionMode.SINGLE);
        current_list_box.add_css_class ("boxed-list");
        current_list_box.set_vexpand (true);
        box.append (current_list_box);

        var scrolled = new Gtk.ScrolledWindow ();
        scrolled.set_child (box);
        scrolled.set_vexpand (true);
        toolbar_view.set_content (scrolled);

        refresh_phrases_list (current_list_box);

        var add_btn = new Gtk.Button ();
        add_btn.set_label (_("添加"));
        add_btn.add_css_class ("suggested-action");
        header_bar.pack_end (add_btn);

        cancel_btn.clicked.connect (() => {
            window.close ();
        });

        add_btn.clicked.connect (() => {
            show_add_phrase_dialog (false, current_list_box, window);
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
        var window = new Adw.Window ();
        window.set_transient_for (parent_window);
        window.set_modal (true);
        window.set_default_size (450, 350);
        window.set_title (_("添加常用语"));

        var toolbar_view = new Adw.ToolbarView ();
        window.set_content (toolbar_view);

        var header_bar = new Adw.HeaderBar ();
        header_bar.set_decoration_layout ("");
        toolbar_view.add_top_bar (header_bar);

        var cancel_btn = new Gtk.Button ();
        cancel_btn.set_label (_("取消"));
        header_bar.pack_start (cancel_btn);

        var ok_btn = new Gtk.Button ();
        ok_btn.set_label (_("添加"));
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
                common_phrases.add (text);
                ConfigManager.save_common_phrases (common_phrases);
                if (list_box != null && picker_window != null) {
                    populate_phrases_picker_list (list_box, picker_window, above);
                } else {
                    show_picker (above);
                }
                phrases_changed ();
            }
            window.destroy ();
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
                refresh_phrases_list (list_box);
                phrases_changed ();
            });
            row.add_suffix (delete_btn);

            int phrase_index = i;
            row.activated.connect (() => {
                edit_phrase_requested (common_phrases.get (phrase_index), phrase_index);
            });

            list_box.append (row);
        }
    }
}
