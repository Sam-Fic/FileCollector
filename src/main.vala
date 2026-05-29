public class FileCollectorApp : Adw.Application {
    public FileCollectorApp () {
        Object (
            application_id: "com.github.samfic.filecollector",
            flags: ApplicationFlags.DEFAULT_FLAGS
        );
    }

    protected override void activate () {
        var window = new FileCollectorWindow (this);

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

        window.present ();
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

    public static int main (string[] args) {
        if (CliController.is_cli_mode (args)) {
            Intl.setlocale (LocaleCategory.ALL, "");
            var cli = new CliController ();
            return cli.run (args);
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

        string locale_dir = Config.LOCALE_DIR;
        var mo_path = Path.build_filename (locale_dir, "en", "LC_MESSAGES", Config.GETTEXT_PACKAGE + ".mo");
        if (!FileUtils.test (mo_path, FileTest.EXISTS)) {
            try {
                string exe_path = FileUtils.read_link ("/proc/self/exe");
                locale_dir = Path.get_dirname (exe_path);
            } catch (Error e) {
                // keep default locale_dir
            }
        }
        Intl.bindtextdomain (Config.GETTEXT_PACKAGE, locale_dir);
        Intl.bind_textdomain_codeset (Config.GETTEXT_PACKAGE, "UTF-8");
        Intl.textdomain (Config.GETTEXT_PACKAGE);

        var app = new FileCollectorApp ();
        return app.run (args);
    }
}
