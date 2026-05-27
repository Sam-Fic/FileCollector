public class FileCollectorApp : Adw.Application {
    public signal void open_project_request ();
    public signal void save_project_request ();
    public signal void about_request ();
    public signal void manage_phrases_request ();

    public FileCollectorApp () {
        Object (
            application_id: "com.github.samfic.filecollector",
            flags: ApplicationFlags.DEFAULT_FLAGS
        );
    }

    protected override void activate () {
        var window = new FileCollectorWindow (this);

        open_project_request.connect (() => window.on_open_project ());
        save_project_request.connect (() => window.on_save_project ());
        about_request.connect (() => window.on_about ());
        manage_phrases_request.connect (() => window.on_manage_phrases ());

        window.present ();
    }

    protected override void startup () {
        base.startup ();

        var open_action = new GLib.SimpleAction ("open_project", null);
        open_action.activate.connect (() => open_project_request ());
        add_action (open_action);

        var save_action = new GLib.SimpleAction ("save_project", null);
        save_action.activate.connect (() => save_project_request ());
        add_action (save_action);

        var about_action = new GLib.SimpleAction ("about", null);
        about_action.activate.connect (() => about_request ());
        add_action (about_action);

        var phrases_action = new GLib.SimpleAction ("manage_phrases", null);
        phrases_action.activate.connect (() => manage_phrases_request ());
        add_action (phrases_action);
    }

    public static int main (string[] args) {
        Intl.setlocale (LocaleCategory.ALL, "");
        Intl.bindtextdomain (Config.GETTEXT_PACKAGE, Config.LOCALE_DIR);
        Intl.bind_textdomain_codeset (Config.GETTEXT_PACKAGE, "UTF-8");
        Intl.textdomain (Config.GETTEXT_PACKAGE);

        var app = new FileCollectorApp ();
        return app.run (args);
    }
}
