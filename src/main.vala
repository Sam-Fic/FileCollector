using Gee;

public class FileCollectorApp : Adw.Application {
    private FileCollectorWindow? app_window = null;

    public FileCollectorApp () {
        Object (
            application_id: "io.github.sam_fic.filecollector",
            flags: ApplicationFlags.HANDLES_COMMAND_LINE
        );
    }

    protected override void activate () {
        var window = app_window;
        if (window == null) {
            window = new FileCollectorWindow (this);
            app_window = window;

            var open_action = lookup_action ("open_project");
            if (open_action != null) {
                ((GLib.SimpleAction) open_action).activate.connect (() => window.on_open_project ());
            }

            var save_action = lookup_action ("save_project");
            if (save_action != null) {
                ((GLib.SimpleAction) save_action).activate.connect (() => window.on_save_project ());
            }

            var save_as_action = lookup_action ("save_as_project");
            if (save_as_action != null) {
                ((GLib.SimpleAction) save_as_action).activate.connect (() => window.on_save_project_as ());
            }

            var about_action = lookup_action ("about");
            if (about_action != null) {
                ((GLib.SimpleAction) about_action).activate.connect (() => window.on_about ());
            }

            var phrases_action = lookup_action ("manage_phrases");
            if (phrases_action != null) {
                ((GLib.SimpleAction) phrases_action).activate.connect (() => window.on_manage_phrases ());
            }
            var templates_action = lookup_action ("manage_templates");
            if (templates_action != null) {
                ((GLib.SimpleAction) templates_action).activate.connect (() => window.on_manage_templates ());
            }

            var preferences_action = lookup_action ("preferences");
            if (preferences_action != null) {
                ((GLib.SimpleAction) preferences_action).activate.connect (() => window.on_preferences ());
            }

            var clear_cache_action = lookup_action ("clear_cache");
            if (clear_cache_action != null) {
                ((GLib.SimpleAction) clear_cache_action).activate.connect (() => window.on_clear_cache ());
            }

            var shortcuts_action = lookup_action ("shortcuts");
            if (shortcuts_action != null) {
                ((GLib.SimpleAction) shortcuts_action).activate.connect (() => window.on_show_shortcuts ());
            }

            var quit_action = lookup_action ("quit");
            if (quit_action != null) {
                ((GLib.SimpleAction) quit_action).activate.connect (() => window.close ());
            }
        }

        window.present ();

        // 确保从 build 目录运行时也能解析应用图标
        setup_app_icon_resource ();
    }

    protected override int command_line (ApplicationCommandLine command_line) {
        var args = command_line.get_arguments ();

        // 防御: get_arguments 理论上至少返回程序名, 但显式校验避免边界情况下越界
        if (args.length == 0) {
            return 0;
        }

        bool force_gui = false;
        var filtered = new Gee.ArrayList<string> ();
        filtered.add (args[0]);
        for (int i = 1; i < args.length; i++) {
            if (args[i] == "--gui") {
                force_gui = true;
            } else {
                filtered.add (args[i]);
            }
        }
        var filtered_args = (string[]) filtered.to_array ();

        bool has_cli_args = CliController.is_cli_mode (filtered_args);

        if (app_window != null) {
            if (has_cli_args) {
                var cli = app_window.create_cli_from_state ();
                if (cli.parse_args (filtered_args)) {
                    if (cli.execute_save_export ()) {
                        app_window.apply_cli_operations (cli);
                        for (int i = 0; i < cli.operation_messages.size; i++) {
                            command_line.print ("✓ %s\n".printf (cli.operation_messages.get (i)));
                        }
                    } else {
                        for (int i = 0; i < cli.operation_messages.size; i++) {
                            command_line.printerr ("✗ %s\n".printf (cli.operation_messages.get (i)));
                        }
                        return 1;
                    }
                } else {
                    return 1;
                }
            } else {
                app_window.present ();
            }
            return 0;
        }

        if (!force_gui && has_cli_args) {
            Intl.setlocale (LocaleCategory.ALL, "");
            setup_i18n_default ();
            var cli = new CliController ();
            return cli.run (filtered_args);
        }

        var lang_setting = FileCollectorWindow.load_settings_language ();
        if (lang_setting == "en") {
            GLib.Environment.set_variable ("LANGUAGE", "en", true);
        } else if (lang_setting == "zh") {
            GLib.Environment.set_variable ("LANGUAGE", "zh_CN", true);
        } else {
            GLib.Environment.unset_variable ("LANGUAGE");
        }

        Intl.setlocale (LocaleCategory.ALL, "");
        setup_i18n_default ();

        activate ();

        if (force_gui && has_cli_args) {
            var cli = new CliController ();
            if (cli.parse_args (filtered_args) || cli.items.size > 0 || cli.work_dir != null) {
                if (cli.execute_save_export ()) {
                    GLib.Idle.add (() => {
                        if (app_window != null) {
                            app_window.apply_cli_operations (cli);
                        }
                        return Source.REMOVE;
                    });
                }
            }
        }

        return 0;
    }

    protected override void startup () {
        base.startup ();

        // Windows HiDPI：GTK4 的 Win32 后端只做整数缩放（150% DPI 被 floor 成 1×），
        // 且忽略 GDK_SCALE，导致组件布局锁在 1× 而文字按真实 144 DPI 渲染成 1.5×，
        // 出现「组件小、文字大」的错位。这里强制把文字 DPI 设为 96（1×），与组件对齐，
        // 使两者比例正确、清晰（代价：在 150% 屏上整体偏小）。无需 DPI 感知 hack，
        // 与 Setzer 的「真原生 1×」方案一致。仅 Windows 需要。
#if WINDOWS
        var hidpi_settings = Gtk.Settings.get_default ();
        if (hidpi_settings != null) {
            hidpi_settings.gtk_xft_dpi = 96 * 1024;
        }
#endif

        add_action (new GLib.SimpleAction ("open_project", null));
        add_action (new GLib.SimpleAction ("save_project", null));
        add_action (new GLib.SimpleAction ("save_as_project", null));
        add_action (new GLib.SimpleAction ("about", null));
        add_action (new GLib.SimpleAction ("manage_phrases", null));
        add_action (new GLib.SimpleAction ("manage_templates", null));
        add_action (new GLib.SimpleAction ("preferences", null));
        add_action (new GLib.SimpleAction ("clear_cache", null));
        add_action (new GLib.SimpleAction ("shortcuts", null));
        add_action (new GLib.SimpleAction ("quit", null));

        set_accels_for_action ("app.open_project", {"<Control>o"});
        set_accels_for_action ("app.save_project", {"<Control>s"});
        set_accels_for_action ("app.save_as_project", {"<Control><Shift>s"});
        set_accels_for_action ("app.about", {"F1"});
        set_accels_for_action ("app.shortcuts", {"<Control>slash"});
        set_accels_for_action ("app.preferences", {"<Control>comma"});
        set_accels_for_action ("app.quit", {"<Control>q"});

        setup_app_icon_resource ();
    }

    private void setup_app_icon_resource () {
        var display = Gdk.Display.get_default ();
        if (display == null) return;

        var icon_theme = Gtk.IconTheme.get_for_display (display);
        var paths = icon_theme.resource_path ?? new string[] {};
        if (paths.length > 0 && paths[0] == "/io/github/sam_fic/filecollector/icons") {
            return;
        }

        var new_paths = new string[paths.length + 1];
        new_paths[0] = "/io/github/sam_fic/filecollector/icons";
        for (int i = 0; i < paths.length; i++) {
            new_paths[i + 1] = paths[i];
        }
        icon_theme.set_resource_path (new_paths);
    }

    private static void setup_i18n (string locale_dir) {
        Intl.bindtextdomain (Config.GETTEXT_PACKAGE, locale_dir);
        Intl.bind_textdomain_codeset (Config.GETTEXT_PACKAGE, "UTF-8");
        Intl.textdomain (Config.GETTEXT_PACKAGE);
    }

    private static void setup_i18n_default () {
        string locale_dir = Config.LOCALE_DIR;
        bool mo_found = false;

        // 1. 绿色版 / AppImage / 便携包: 相对 exe 或 APPDIR 的 locale 目录
        //    (平台差异由 Platform.get_portable_locale_dir() 内部处理)
        var portable_locale = Platform.get_portable_locale_dir ();
        if (!mo_found && portable_locale != null) {
            locale_dir = portable_locale;
            mo_found = true;
        }

        // 2. AppImage 部署规范: APPDIR 才是程序真正挂载的沙盒内虚拟根路径
        //    (例如 /tmp/.mount_xxxxx/), 多语言文件封包于 $APPDIR/usr/share/locale
        var appdir = GLib.Environment.get_variable ("APPDIR");
        if (!mo_found && appdir != null && appdir.length > 0) {
            var candidate = Path.build_filename (appdir, "usr", "share", "locale");
            if (FileUtils.test (Path.build_filename (candidate, "en", "LC_MESSAGES", Config.GETTEXT_PACKAGE + ".mo"), FileTest.EXISTS)) {
                locale_dir = candidate;
                mo_found = true;
            }
        }

        // 3. XDG 用户数据目录 (如 ~/.local/share), meson install --prefix=~/.local 安装在此
        if (!mo_found) {
            var user_data = GLib.Environment.get_user_data_dir ();
            var candidate = Path.build_filename (user_data, "locale");
            if (FileUtils.test (Path.build_filename (candidate, "en", "LC_MESSAGES", Config.GETTEXT_PACKAGE + ".mo"), FileTest.EXISTS)) {
                locale_dir = candidate;
                mo_found = true;
            }
        }

        // 4. 终极回退: 扫描 XDG 系统层级目录全盘兜底搜索
        if (!mo_found) {
            foreach (unowned string data_dir in GLib.Environment.get_system_data_dirs ()) {
                var candidate = Path.build_filename (data_dir, "locale");
                if (FileUtils.test (Path.build_filename (candidate, "en", "LC_MESSAGES", Config.GETTEXT_PACKAGE + ".mo"), FileTest.EXISTS)) {
                    locale_dir = candidate;
                    break;
                }
            }
        }

        setup_i18n (locale_dir);
    }

    public static int main (string[] args) {
        var app = new FileCollectorApp ();
        int ret = app.run (args);
        // 清理 BinaryConverter 复用的临时基目录, 防止 /tmp 下泄漏
        BinaryConverter.cleanup_temp_dir ();
        return ret;
    }
}
