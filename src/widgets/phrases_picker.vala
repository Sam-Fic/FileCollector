using Gee;

public class PhrasesPicker : GLib.Object {
    private Gtk.Window parent_window;
    private Gee.ArrayList<string> common_phrases;
    private Gtk.ListBox? current_list_box;

    public signal void phrase_selected (string phrase, bool above);
    public signal void phrases_changed ();
    public signal void edit_phrase_requested (string old_text, int index);

    public PhrasesPicker (Gtk.Window parent, Gee.ArrayList<string> phrases) {
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
        var dialog = new Adw.Dialog ();
        dialog.set_title (_("Select Common Phrase"));
        dialog.set_content_width (400);
        dialog.set_content_height (400);

        var toolbar_view = new Adw.ToolbarView ();
        dialog.set_child (toolbar_view);

        var header_bar = new Adw.HeaderBar ();
        header_bar.set_title_widget (new Adw.WindowTitle (_("Select Common Phrase"), ""));
        header_bar.set_show_end_title_buttons (false);
        toolbar_view.add_top_bar (header_bar);

        var cancel_btn = new Gtk.Button ();
        cancel_btn.set_label (_("Cancel"));
        header_bar.pack_start (cancel_btn);

        var add_btn = new Gtk.Button ();
        add_btn.set_label (_("Add"));
        header_bar.pack_end (add_btn);

        var btn_size_group = new Gtk.SizeGroup (Gtk.SizeGroupMode.HORIZONTAL);
        btn_size_group.add_widget (cancel_btn);
        btn_size_group.add_widget (add_btn);

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        box.set_margin_top (0);
        box.set_margin_start (12);
        box.set_margin_end (12);
        box.set_margin_bottom (12);

        current_list_box = new Gtk.ListBox ();
        current_list_box.set_selection_mode (Gtk.SelectionMode.NONE);
        current_list_box.add_css_class ("boxed-list");
        current_list_box.add_css_class ("phrases-list");
        current_list_box.set_vexpand (true);
        box.append (current_list_box);

        var scrolled = new Gtk.ScrolledWindow ();
        scrolled.set_child (box);
        scrolled.set_vexpand (true);
        toolbar_view.set_content (scrolled);

        populate_phrases_picker_list (current_list_box, dialog, above);

        cancel_btn.clicked.connect (() => {
            dialog.close ();
        });

        add_btn.clicked.connect (() => {
            show_add_phrase_dialog (above, current_list_box, dialog);
        });

        dialog.present (parent_window);
    }

    public void show_manage_window () {
        var dialog = new Adw.Dialog ();
        dialog.set_title (_("Manage Common Phrases"));
        dialog.set_content_width (400);
        dialog.set_content_height (400);

        var toolbar_view = new Adw.ToolbarView ();
        dialog.set_child (toolbar_view);

        var header_bar = new Adw.HeaderBar ();
        header_bar.set_title_widget (new Adw.WindowTitle (_("Manage Common Phrases"), ""));
        header_bar.set_show_end_title_buttons (false);
        toolbar_view.add_top_bar (header_bar);

        var cancel_btn = new Gtk.Button ();
        cancel_btn.set_label (_("Cancel"));
        header_bar.pack_start (cancel_btn);

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        box.set_margin_top (0);
        box.set_margin_start (12);
        box.set_margin_end (12);
        box.set_margin_bottom (12);

        current_list_box = new Gtk.ListBox ();
        current_list_box.set_selection_mode (Gtk.SelectionMode.SINGLE);
        current_list_box.add_css_class ("boxed-list");
        current_list_box.add_css_class ("phrases-list");
        current_list_box.set_vexpand (true);
        box.append (current_list_box);

        var scrolled = new Gtk.ScrolledWindow ();
        scrolled.set_child (box);
        scrolled.set_vexpand (true);
        toolbar_view.set_content (scrolled);

        refresh_phrases_list (current_list_box);

        var add_btn = new Gtk.Button ();
        add_btn.set_label (_("Add"));
        add_btn.add_css_class ("suggested-action");
        header_bar.pack_end (add_btn);

        var btn_size_group = new Gtk.SizeGroup (Gtk.SizeGroupMode.HORIZONTAL);
        btn_size_group.add_widget (cancel_btn);
        btn_size_group.add_widget (add_btn);

        cancel_btn.clicked.connect (() => {
            dialog.close ();
        });

        add_btn.clicked.connect (() => {
            show_add_phrase_dialog (false, current_list_box, dialog, true);
        });

        dialog.present (parent_window);
    }

    private void populate_phrases_picker_list (Gtk.ListBox list_box, Adw.Dialog dialog, bool above) {
        list_box.remove_all ();

        if (common_phrases.size == 0) {
            var empty_label = new Gtk.Label (_("No Common Phrases Yet"));
            empty_label.set_halign (Gtk.Align.CENTER);
            list_box.append (empty_label);
        } else {
            for (int i = 0; i < common_phrases.size; i++) {
                var phrase = common_phrases.get (i);
                var row = new Adw.ActionRow ();
                apply_phrase_title (row, phrase);
                row.set_activatable (true);

                int phrase_index = i;
                row.activated.connect (() => {
                    var selected_phrase = common_phrases.get (phrase_index);
                    phrase_selected (selected_phrase, above);
                    dialog.close ();
                });

                var edit_btn = new Gtk.Button.from_icon_name ("document-edit-symbolic");
                edit_btn.add_css_class ("flat");
                edit_btn.valign = Gtk.Align.CENTER;
                edit_btn.tooltip_text = _("Edit Text");
                edit_btn.clicked.connect (() => {
                    edit_phrase_requested (common_phrases.get (phrase_index), phrase_index);
                });
                row.add_suffix (edit_btn);

                var delete_btn = new Gtk.Button ();
                delete_btn.set_icon_name ("user-trash-symbolic");
                delete_btn.add_css_class ("destructive-action");
                delete_btn.add_css_class ("flat");
                delete_btn.set_valign (Gtk.Align.CENTER);
                delete_btn.set_tooltip_text (_("Delete"));
                string captured_phrase = phrase;
                delete_btn.clicked.connect (() => {
                    int idx = common_phrases.index_of (captured_phrase);
                    if (idx < 0) return;
                    common_phrases.remove_at (idx);
                    ConfigManager.save_common_phrases (common_phrases);
                    populate_phrases_picker_list (list_box, dialog, above);
                    phrases_changed ();
                });
                row.add_suffix (delete_btn);

                list_box.append (row);
            }
        }
    }

    private void refresh_phrases_list (Gtk.ListBox list_box) {
        list_box.remove_all ();
        for (int i = 0; i < common_phrases.size; i++) {
            var phrase = common_phrases.get (i);
            var row = new Adw.ActionRow ();
            apply_phrase_title (row, phrase);

            var edit_btn = new Gtk.Button.from_icon_name ("document-edit-symbolic");
            edit_btn.add_css_class ("flat");
            edit_btn.valign = Gtk.Align.CENTER;
            edit_btn.tooltip_text = _("Edit Text");
            int edit_index = i;
            edit_btn.clicked.connect (() => {
                edit_phrase_requested (common_phrases.get (edit_index), edit_index);
            });
            row.add_suffix (edit_btn);

            var delete_btn = new Gtk.Button ();
            delete_btn.set_icon_name ("user-trash-symbolic");
            delete_btn.add_css_class ("destructive-action");
            delete_btn.add_css_class ("flat");
            delete_btn.set_valign (Gtk.Align.CENTER);
            delete_btn.set_tooltip_text (_("Delete"));
            string captured_phrase = phrase;
            delete_btn.clicked.connect (() => {
                int idx = common_phrases.index_of (captured_phrase);
                if (idx < 0) return;
                common_phrases.remove_at (idx);
                ConfigManager.save_common_phrases (common_phrases);
                refresh_phrases_list (list_box);
                phrases_changed ();
            });
            row.add_suffix (delete_btn);

            list_box.append (row);
        }
    }

    private static void apply_phrase_title (Adw.ActionRow row, string phrase) {
        if (phrase.char_count () > 40) {
            int split_at = phrase.index_of_nth_char (40);
            row.set_title (phrase.substring (0, split_at) + "…");
            row.set_subtitle (phrase.substring (split_at));
        } else {
            row.set_title (phrase);
        }
    }

    private void show_add_phrase_dialog (bool above, Gtk.ListBox? list_box = null, Adw.Dialog? picker_dialog = null, bool is_manage = false) {
        var dialog = new Adw.Dialog ();
        dialog.set_title (_("Add Common Phrase"));
        dialog.set_content_width (450);
        dialog.set_content_height (350);

        var toolbar_view = new Adw.ToolbarView ();
        dialog.set_child (toolbar_view);

        var header_bar = new Adw.HeaderBar ();
        header_bar.set_title_widget (new Adw.WindowTitle (_("Add Common Phrase"), ""));
        header_bar.set_show_end_title_buttons (false);
        toolbar_view.add_top_bar (header_bar);

        var cancel_btn = new Gtk.Button ();
        cancel_btn.set_label (_("Cancel"));
        header_bar.pack_start (cancel_btn);

        var ok_btn = new Gtk.Button ();
        ok_btn.set_label (_("Add"));
        ok_btn.add_css_class ("suggested-action");
        header_bar.pack_end (ok_btn);

        var btn_size_group = new Gtk.SizeGroup (Gtk.SizeGroupMode.HORIZONTAL);
        btn_size_group.add_widget (cancel_btn);
        btn_size_group.add_widget (ok_btn);

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        content.set_margin_top (0);
        content.set_margin_start (12);
        content.set_margin_end (12);
        content.set_margin_bottom (12);

        var frame = new Gtk.Frame (null);
        frame.add_css_class ("card");
        frame.add_css_class ("ai-input-frame");

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
            dialog.close ();
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
                if (is_manage && list_box != null) {
                    refresh_phrases_list (list_box);
                } else if (list_box != null && picker_dialog != null) {
                    populate_phrases_picker_list (list_box, picker_dialog, above);
                } else {
                    show_picker (above);
                }
                phrases_changed ();
            }
            dialog.close ();
        });

        dialog.present (parent_window);
    }
}
