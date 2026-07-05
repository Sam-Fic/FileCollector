using Gee;

public class SettingsDialog : GLib.Object {
    public signal void language_changed (string new_lang);
    public signal void restart_requested ();

    private Gtk.Window? parent_window;

    public SettingsDialog (Gtk.Window? parent) {
        this.parent_window = parent;
    }

    public void present () {
        var current_lang = ConfigManager.load_settings_language ();

        var dialog = new Adw.Dialog ();
        dialog.set_title (_("设置界面语言"));
        dialog.set_content_width (380);

        var toolbar_view = new Adw.ToolbarView ();
        var header = new Adw.HeaderBar ();
        header.set_show_end_title_buttons (false);
        toolbar_view.add_top_bar (header);

        var cancel_btn = new Gtk.Button.with_label (_("取消"));
        header.pack_start (cancel_btn);
        cancel_btn.clicked.connect (() => dialog.close ());

        var apply_btn = new Gtk.Button.with_label (_("应用"));
        apply_btn.add_css_class ("suggested-action");
        header.pack_end (apply_btn);

        var lang_model = new Gtk.StringList (new string[] {
            _("跟随系统"), _("中文"), _("English")
        });

        var combo = new Adw.ComboRow ();
        combo.set_title (_("界面语言"));
        combo.set_model (lang_model);

        if (current_lang == "" || current_lang == "system") {
            combo.set_selected (0);
        } else if (current_lang == "zh") {
            combo.set_selected (1);
        } else if (current_lang == "en") {
            combo.set_selected (2);
        }

        var group = new Adw.PreferencesGroup ();
        group.add (combo);

        var page = new Adw.PreferencesPage ();
        page.add (group);

        toolbar_view.set_content (page);
        dialog.set_child (toolbar_view);

        apply_btn.clicked.connect (() => {
            string new_lang;
            if (combo.selected == 0) {
                new_lang = "system";
            } else if (combo.selected == 1) {
                new_lang = "zh";
            } else {
                new_lang = "en";
            }

            ConfigManager.save_language_setting (new_lang);
            language_changed (new_lang);
            dialog.close ();

            var restart_dialog = new Adw.AlertDialog (
                _("提示"),
                _("语言设置已保存，重启应用后生效。是否现在重启？")
            );
            restart_dialog.add_response ("later", _("稍后"));
            restart_dialog.add_response ("restart", _("立即重启"));
            restart_dialog.set_default_response ("restart");
            restart_dialog.set_close_response ("later");

            restart_dialog.response.connect ((r) => {
                if (r == "restart") {
                    restart_requested ();
                }
                restart_dialog.destroy ();
            });
            if (parent_window != null) {
                restart_dialog.present (parent_window);
            }
        });

        dialog.present (parent_window);
    }
}
