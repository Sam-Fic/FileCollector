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

    // 快捷键帮助界面 (AdwShortcutsDialog) 的 UI 定义.
    // 顶部的 _("...") 仅为 gettext 提取标记, 实际返回的 XML 中标题已用 translatable="yes" 标记.
    public static string build_ui () {
        _("Common Operations");
        _("List Operations");
        _("Application");
        _("Generate to Clipboard");
        _("Open Project");
        _("Add External Files");
        _("Toggle AI Panel");
        _("Insert Text Above");
        _("Insert Text Below");
        _("Generate Merged Text");
        _("Apply Language Settings");
        _("Keyboard Shortcuts...");
        _("About");
        _("Quit");
        return """<?xml version="1.0" encoding="UTF-8"?>
<interface>
  <object class="AdwShortcutsDialog" id="sw">
    <property name="title" translatable="yes">键盘快捷键</property>
    <child>
      <object class="AdwShortcutsSection">
        <property name="title" translatable="yes">常用操作</property>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">撤销</property>
            <property name="action-name">win.undo</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">重做</property>
            <property name="action-name">win.redo</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">打开项目</property>
            <property name="accelerator">&lt;Control&gt;o</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">保存项目</property>
            <property name="accelerator">&lt;Control&gt;s</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">清空列表</property>
            <property name="action-name">win.clear_items</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">添加外部文件</property>
            <property name="action-name">win.add_external_files</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">切换 AI 面板</property>
            <property name="action-name">win.toggle_ai_panel</property>
          </object>
        </child>
      </object>
    </child>
    <child>
      <object class="AdwShortcutsSection">
        <property name="title" translatable="yes">列表操作</property>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">上方插入文本</property>
            <property name="action-name">win.insert_text</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">下方插入文本</property>
            <property name="action-name">win.insert_text_no_header</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">上移</property>
            <property name="action-name">win.move_up</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">下移</property>
            <property name="action-name">win.move_down</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">删除</property>
            <property name="action-name">win.delete_item</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">生成合并文本</property>
            <property name="action-name">win.generate</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">生成到剪贴板</property>
            <property name="action-name">win.generate_to_clipboard</property>
          </object>
        </child>
      </object>
    </child>
    <child>
      <object class="AdwShortcutsSection">
        <property name="title" translatable="yes">应用程序</property>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">语言设置</property>
            <property name="accelerator">&lt;Control&gt;comma</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">键盘快捷键</property>
            <property name="accelerator">&lt;Control&gt;slash</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">关于</property>
            <property name="accelerator">F1</property>
          </object>
        </child>
        <child>
          <object class="AdwShortcutsItem">
            <property name="title" translatable="yes">退出</property>
            <property name="accelerator">&lt;Control&gt;q</property>
          </object>
        </child>
      </object>
    </child>
  </object>
</interface>""";
    }
}
