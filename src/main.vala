public class FileCollectorApp : Adw.Application {
    private FileCollectorWindow? app_window = null;

    public FileCollectorApp () {
        Object (
            application_id: "com.github.samfic.filecollector",
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

            var about_action = lookup_action ("about");
            if (about_action != null) {
                ((GLib.SimpleAction) about_action).activate.connect (() => window.on_about ());
            }

            var phrases_action = lookup_action ("manage_phrases");
            if (phrases_action != null) {
                ((GLib.SimpleAction) phrases_action).activate.connect (() => window.on_manage_phrases ());
            }

            var settings_action = lookup_action ("settings");
            if (settings_action != null) {
                ((GLib.SimpleAction) settings_action).activate.connect (() => window.on_settings ());
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
    }

    protected override int command_line (ApplicationCommandLine command_line) {
        var args = command_line.get_arguments ();

        bool force_gui = false;
        var filtered = new GenericArray<string> ();
        filtered.add (args[0]);
        for (int i = 1; i < args.length; i++) {
            if (args[i] == "--gui") {
                force_gui = true;
            } else {
                filtered.add (args[i]);
            }
        }
        var filtered_args = filtered.data;

        bool has_cli_args = CliController.is_cli_mode (filtered_args);

        if (app_window != null) {
            if (has_cli_args) {
                var cli = app_window.create_cli_from_state ();
                if (cli.parse_args (filtered_args)) {
                    cli.execute_save_export ();
                    app_window.apply_cli_operations (cli);
                    for (int i = 0; i < cli.operation_messages.length; i++) {
                        command_line.print ("✓ %s\n".printf (cli.operation_messages.get (i)));
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
            if (cli.parse_args (filtered_args) || cli.items.length > 0 || cli.work_dir != null) {
                cli.execute_save_export ();
                GLib.Idle.add (() => {
                    if (app_window != null) {
                        app_window.apply_cli_operations (cli);
                    }
                    return Source.REMOVE;
                });
            }
        }

        return 0;
    }

    protected override void startup () {
        base.startup ();

        add_action (new GLib.SimpleAction ("open_project", null));
        add_action (new GLib.SimpleAction ("save_project", null));
        add_action (new GLib.SimpleAction ("about", null));
        add_action (new GLib.SimpleAction ("manage_phrases", null));
        add_action (new GLib.SimpleAction ("settings", null));
        add_action (new GLib.SimpleAction ("shortcuts", null));
        add_action (new GLib.SimpleAction ("quit", null));

        set_accels_for_action ("app.open_project", {"<Control>o"});
        set_accels_for_action ("app.save_project", {"<Control>s"});
        set_accels_for_action ("app.about", {"F1"});
        set_accels_for_action ("app.shortcuts", {"<Control>slash"});
        set_accels_for_action ("app.settings", {"<Control>comma"});
        set_accels_for_action ("app.quit", {"<Control>q"});
    }

    private static void setup_i18n (string locale_dir) {
        Intl.bindtextdomain (Config.GETTEXT_PACKAGE, locale_dir);
        Intl.bind_textdomain_codeset (Config.GETTEXT_PACKAGE, "UTF-8");
        Intl.textdomain (Config.GETTEXT_PACKAGE);
    }

    private static void setup_i18n_default () {
        string locale_dir = Config.LOCALE_DIR;
        var mo_path = Path.build_filename (locale_dir, "en", "LC_MESSAGES", Config.GETTEXT_PACKAGE + ".mo");
        if (!FileUtils.test (mo_path, FileTest.EXISTS)) {
            try {
                string exe_path = FileUtils.read_link ("/proc/self/exe");
                locale_dir = Path.get_dirname (exe_path);
            } catch (Error e) {
            }
        }
        setup_i18n (locale_dir);
    }

    public static int main (string[] args) {
        var app = new FileCollectorApp ();
        return app.run (args);
    }
}
