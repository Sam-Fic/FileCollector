public class SettingsDialog : GLib.Object {
    public signal void language_changed (string new_lang);
    public signal void restart_requested ();

    private Gtk.Window? parent_window;

    public SettingsDialog (Gtk.Window? parent) {
        this.parent_window = parent;
    }

    public void present () {
        var current_lang = ConfigManager.load_settings_language ();

        var dialog = new Adw.AlertDialog (
            _("设置界面语言"),
            null
        );

        var group = new Gtk.CheckButton ();

        var system_btn = new Gtk.CheckButton.with_label (_("跟随系统"));
        var zh_btn = new Gtk.CheckButton.with_label ("中文");
        var en_btn = new Gtk.CheckButton.with_label ("English");

        system_btn.set_group (group);
        zh_btn.set_group (group);
        en_btn.set_group (group);

        if (current_lang == "" || current_lang == "system") {
            system_btn.active = true;
        } else if (current_lang == "zh") {
            zh_btn.active = true;
        } else if (current_lang == "en") {
            en_btn.active = true;
        }

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        box.set_margin_start (12);
        box.set_margin_end (12);
        box.set_margin_top (12);
        box.set_margin_bottom (12);
        box.append (system_btn);
        box.append (zh_btn);
        box.append (en_btn);

        dialog.set_extra_child (box);
        dialog.add_response ("cancel", _("取消"));
        dialog.add_response ("apply", _("应用"));
        dialog.set_default_response ("apply");
        dialog.set_close_response ("cancel");

        dialog.response.connect ((resp) => {
            if (resp == "apply") {
                string new_lang;
                if (system_btn.active) {
                    new_lang = "system";
                } else if (zh_btn.active) {
                    new_lang = "zh";
                } else {
                    new_lang = "en";
                }
                ConfigManager.save_language_setting (new_lang);
                language_changed (new_lang);

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
            }
            dialog.destroy ();
        });

        if (parent_window != null) {
            dialog.present (parent_window);
        }
    }
}
