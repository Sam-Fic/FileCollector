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

        window.present ();
    }

    protected override void startup () {
        base.startup ();

        add_action (new GLib.SimpleAction ("open_project", null));
        add_action (new GLib.SimpleAction ("save_project", null));
        add_action (new GLib.SimpleAction ("about", null));
        add_action (new GLib.SimpleAction ("manage_phrases", null));
        add_action (new GLib.SimpleAction ("settings", null));
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
        Intl.bindtextdomain (Config.GETTEXT_PACKAGE, Config.LOCALE_DIR);
        Intl.bind_textdomain_codeset (Config.GETTEXT_PACKAGE, "UTF-8");
        Intl.textdomain (Config.GETTEXT_PACKAGE);

        var app = new FileCollectorApp ();
        return app.run (args);
    }
}
