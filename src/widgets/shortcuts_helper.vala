using GLib;
using Gtk;

// ─── 快捷键注册辅助 ──────────────────────────────────────────────────
// 使用 GAction + set_accels_for_action 替代 ShortcutController,
// 避免 GTK4 bug (#6246): widget 销毁后 controller 仍留在 manager 中导致崩溃

public class ShortcutsHelper : GLib.Object {

    public delegate void SimpleAction ();

    public static void setup (Adw.ApplicationWindow window,
                               SimpleAction on_generate,
                               SimpleAction on_generate_clipboard,
                               SimpleAction on_undo,
                               SimpleAction on_redo,
                               SimpleAction on_clear,
                               SimpleAction on_delete,
                               SimpleAction on_move_up,
                               SimpleAction on_move_down,
                               SimpleAction on_add_external,
                               SimpleAction on_insert_text,
                               SimpleAction on_insert_text_no_header,
                               SimpleAction on_toggle_ai,
                               SimpleAction on_global_search) {

        add_action (window, "generate", on_generate);
        add_action (window, "generate_to_clipboard", on_generate_clipboard);
        add_action (window, "undo", on_undo);
        add_action (window, "redo", on_redo);
        add_action (window, "clear_items", on_clear);
        add_action (window, "delete_item", on_delete);
        add_action (window, "move_up", on_move_up);
        add_action (window, "move_down", on_move_down);
        add_action (window, "add_external_files", on_add_external);
        add_action (window, "insert_text", on_insert_text);
        add_action (window, "insert_text_no_header", on_insert_text_no_header);
        add_action (window, "toggle_ai_panel", on_toggle_ai);
        add_action (window, "global_search", on_global_search);

        GLib.Idle.add (() => {
            var app = window.application;
            if (app != null) {
                app.set_accels_for_action ("win.generate", { "<Control>g" });
                app.set_accels_for_action ("win.generate_to_clipboard", { "<Control><Shift>c" });
                app.set_accels_for_action ("win.undo", { "<Control>z" });
                app.set_accels_for_action ("win.redo", { "<Control><Shift>z" });
                app.set_accels_for_action ("win.clear_items", { "<Control>n" });
                app.set_accels_for_action ("win.delete_item", { "Delete" });
                app.set_accels_for_action ("win.move_up", { "<Control>Up" });
                app.set_accels_for_action ("win.move_down", { "<Control>Down" });
                app.set_accels_for_action ("win.add_external_files", { "<Control>e" });
                app.set_accels_for_action ("win.insert_text", { "<Control>i" });
                app.set_accels_for_action ("win.insert_text_no_header", { "<Control><Shift>i" });
                app.set_accels_for_action ("win.toggle_ai_panel", { "<Control>j" });
                app.set_accels_for_action ("win.global_search", { "<Control><Shift>f" });
            }
            return GLib.Source.REMOVE;
        });
    }

    private static void add_action (Adw.ApplicationWindow window, string name, owned SimpleAction cb) {
        var act = new GLib.SimpleAction (name, null);
        act.activate.connect (() => { cb (); });
        window.add_action (act);
    }
}
