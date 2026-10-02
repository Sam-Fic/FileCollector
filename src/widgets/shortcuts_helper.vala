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
                // 清空列表为破坏性操作, 不设默认快捷键:
                // <Control>n 是 HIG 中 "New" 的保留键, 不可挪作他用
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

    // 快捷键帮助界面 (AdwShortcutsDialog) 的 UI 定义.
    // 源串统一为英文 (与项目其他 UI 字符串一致), zh_CN 由 .po 提供;
    // XML 内嵌字符串不被 xgettext 扫描, 顶部 _() 标记即提取锚点, 需与 XML 保持一致.
    public static string build_ui () {
        _("Keyboard Shortcuts");
        _("Common Operations");
        _("List Operations");
        _("Application");
        _("Undo");
        _("Redo");
        _("Open Project");
        _("Save Project");
        _("Save Project As...");
        _("Open Working Directory");
        _("Add External Files");
        _("Toggle AI Panel");
        _("Global Search");
        _("Insert Text Above");
        _("Insert Text Below");
        _("Move Up");
        _("Move Down");
        _("Delete");
        _("Generate Merged Text");
        _("Generate to Clipboard");
        _("Export as ZIP");
        _("AI Reading Guide");
        _("Preferences");
        _("Keyboard Shortcuts...");
        _("About");
        _("Quit");
        return """<?xml version="1.0" encoding="UTF-8"?>
<interface>
  <object class="AdwShortcutsDialog" id="sw">
    <property name="title" translatable="yes">Keyboard Shortcuts</property>
    <child>
      <object class="AdwShortcutsSection">
        <property name="title" translatable="yes">Common Operations</property>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Undo</property>
            <property name="action-name">win.undo</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Redo</property>
            <property name="action-name">win.redo</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Open Project</property>
            <property name="accelerator">&lt;Control&gt;o</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Save Project</property>
            <property name="accelerator">&lt;Control&gt;s</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Save Project As...</property>
            <property name="accelerator">&lt;Control&gt;&lt;Shift&gt;s</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Open Working Directory</property>
            <property name="accelerator">&lt;Control&gt;&lt;Shift&gt;o</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Add External Files</property>
            <property name="action-name">win.add_external_files</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Toggle AI Panel</property>
            <property name="action-name">win.toggle_ai_panel</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Global Search</property>
            <property name="action-name">win.global_search</property>
          </object>
        </child>
      </object>
    </child>
    <child>
      <object class="AdwShortcutsSection">
        <property name="title" translatable="yes">List Operations</property>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Insert Text Above</property>
            <property name="action-name">win.insert_text</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Insert Text Below</property>
            <property name="action-name">win.insert_text_no_header</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Move Up</property>
            <property name="action-name">win.move_up</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Move Down</property>
            <property name="action-name">win.move_down</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Delete</property>
            <property name="action-name">win.delete_item</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Generate Merged Text</property>
            <property name="action-name">win.generate</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Generate to Clipboard</property>
            <property name="action-name">win.generate_to_clipboard</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Export as ZIP</property>
            <property name="action-name">win.export_zip</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">AI Reading Guide</property>
            <property name="action-name">win.ai_reading_guide</property>
          </object>
        </child>
      </object>
    </child>
    <child>
      <object class="AdwShortcutsSection">
        <property name="title" translatable="yes">Application</property>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Preferences</property>
            <property name="accelerator">&lt;Control&gt;comma</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Keyboard Shortcuts...</property>
            <property name="accelerator">&lt;Control&gt;slash</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">About</property>
            <property name="accelerator">F1</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">Quit</property>
            <property name="accelerator">&lt;Control&gt;q</property>
          </object>
        </child>
      </object>
    </child>
  </object>
</interface>""";
    }
}
