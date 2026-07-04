public class ContextSettingsDialog : GLib.Object {
    private Gtk.Window? parent_window;
    private Adw.Dialog dialog;
    private Adw.SpinRow spin_context_size;

    public signal void settings_changed ();

    public ContextSettingsDialog (Gtk.Window? parent) {
        this.parent_window = parent;
    }

    public void present () {
        dialog = new Adw.Dialog ();
        dialog.set_title (_("上下文窗口设置"));
        dialog.set_content_width (400);

        var toolbar_view = new Adw.ToolbarView ();
        var header_bar = new Adw.HeaderBar ();
        header_bar.set_show_end_title_buttons (false);
        toolbar_view.add_top_bar (header_bar);

        var cancel_btn = new Gtk.Button.with_label (_("取消"));
        header_bar.pack_start (cancel_btn);
        cancel_btn.clicked.connect (() => dialog.close ());

        var save_btn = new Gtk.Button.with_label (_("保存"));
        save_btn.add_css_class ("suggested-action");
        header_bar.pack_end (save_btn);

        var page = new Adw.PreferencesPage ();
        var group = new Adw.PreferencesGroup ();
        group.set_title (_("模型上下文限制"));
        group.set_description (_("设置目标 LLM 的最大 Token 窗口，用于进度条预警。"));
        page.add (group);

        spin_context_size = new Adw.SpinRow.with_range (1000, 2000000, 1000);
        spin_context_size.set_title (_("上下文窗口大小 (Tokens)"));
        spin_context_size.set_value (ConfigManager.get_context_window_size ());
        group.add (spin_context_size);

        save_btn.clicked.connect (() => {
            int new_size = (int) spin_context_size.get_value ();
            ConfigManager.save_context_window_size (new_size);
            settings_changed ();
            dialog.close ();
        });

        toolbar_view.set_content (page);
        dialog.set_child (toolbar_view);
        dialog.present (parent_window);
    }
}
