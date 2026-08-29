using GLib;
using Gtk;
using Gee;

// ─── 右键菜单构建器 ──────────────────────────────────────────────────
// 将菜单构建逻辑从 window.vala 中解耦, 通过委托回调绑定业务操作

public delegate void ContextMenuAction ();
public delegate void ContextMenuFileAction (ItemData item);

public class ContextMenus : GLib.Object {

    // 当前活动的右键菜单 popover, 持有强引用, 避免被 GC / 局部变量出作用域释放
    // 同时在 parent widget 销毁前能正确清理
    private static Gtk.PopoverMenu? active_popover = null;

    private static void close_active_popover () {
        if (active_popover != null) {
            var p = active_popover;
            active_popover = null;
            p.popdown ();
        }
    }

    // ─── 编排列表右键菜单 ──────────────────────────────────────────────

    public static void show_queue_menu (
        Gtk.Widget parent,
        ItemData item,
        int gx,
        int gy,
        Gee.ArrayList<int> selected_indices,
        Gee.ArrayList<ItemData> items,
        File? work_dir,
        bool use_absolute,
        ContextMenuAction on_edit_text,
        ContextMenuAction on_refresh_list,
        ContextMenuAction on_push_undo,
        ContextMenuFileAction on_retry_preprocess,
        ContextMenuAction on_copy_path,
        ContextMenuAction on_show_folder,
        ContextMenuAction on_export_cache,
        bool can_export_cache
    ) {
        var menu_model = new GLib.Menu ();
        var action_group = new GLib.SimpleActionGroup ();
        int count = selected_indices.size;
        bool single = (count == 1);

        if (single) {
            var section_edit = new GLib.Menu ();

            var act_edit = new GLib.SimpleAction ("ctx_edit", null);
            act_edit.set_enabled (item.item_type == "text");
            act_edit.activate.connect (() => { on_edit_text (); });
            action_group.add_action (act_edit);
            section_edit.append (_("Edit Text"), "ctx.ctx_edit");
            // 有全局等价快捷键的项直接引用 win.* action:
            // PopoverMenu 会自动展示 action 注册的 accelerator, 并复用 window 侧
            // 已有的崩溃规避逻辑 (delegate target 固定为 window 实例)
            section_edit.append (_("Insert Text Above"), "win.insert_text");
            section_edit.append (_("Insert Text Below"), "win.insert_text_no_header");

            menu_model.append_section (null, section_edit);
        }

        if (single) {
            var section_order = new GLib.Menu ();
            section_order.append (_("Move Up"), "win.move_up");
            section_order.append (_("Move Down"), "win.move_down");
            menu_model.append_section (null, section_order);
        }

        var section_file = new GLib.Menu ();
        bool can_retry_vlm = count > 0;
        bool has_external = false;

        foreach (int idx in selected_indices) {
            if (idx < 0 || idx >= items.size) continue;
            var it = items.get (idx);
            if (it.item_type != "file" || !it.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())
                || it.preprocess_status == PreprocessStatus.PROCESSING) {
                can_retry_vlm = false;
            }
            if (it.item_type == "file" && work_dir != null && it.file_path != null) {
                if (!it.file_path.has_prefix (work_dir.get_path () + "/")) {
                    has_external = true;
                }
            }
        }

        if (can_retry_vlm) {
            var act_retry = new GLib.SimpleAction ("ctx_retry_ai", null);
            act_retry.activate.connect (() => {
                foreach (int idx in selected_indices) {
                    if (idx >= 0 && idx < items.size) on_retry_preprocess (items.get (idx));
                }
            });
            action_group.add_action (act_retry);
            section_file.append (count > 1 ? _("Retry AI Conversion (%d items)").printf (count) : _("Re-run AI conversion"), "ctx.ctx_retry_ai");
        }

        if (has_external) {
            var act_toggle_abs = new GLib.SimpleAction ("ctx_toggle_absolute", null);
            act_toggle_abs.activate.connect (() => {
                on_push_undo ();
                foreach (int idx in selected_indices) {
                    if (idx >= 0 && idx < items.size) {
                        var it = items.get (idx);
                        if (it.item_type == "file") it.force_absolute = !it.force_absolute;
                    }
                }
                on_refresh_list ();
            });
            action_group.add_action (act_toggle_abs);
            section_file.append (count > 1 ? _("Switch absolute/relative path (%d items)").printf (count) : _("Switch absolute/relative path"), "ctx.ctx_toggle_absolute");
        }

        if (single && item.item_type == "file" && item.file_path != null) {
            var act_copy_path = new GLib.SimpleAction ("ctx_copy_path", null);
            act_copy_path.activate.connect (() => { on_copy_path (); });
            action_group.add_action (act_copy_path);
            section_file.append (_("Copy Path"), "ctx.ctx_copy_path");

            var act_show_folder = new GLib.SimpleAction ("ctx_show_folder", null);
            act_show_folder.activate.connect (() => { on_show_folder (); });
            action_group.add_action (act_show_folder);
            section_file.append (_("Show in File Manager"), "ctx.ctx_show_folder");

            var act_export_cache = new GLib.SimpleAction ("ctx_export_cache", null);
            act_export_cache.set_enabled (can_export_cache);
            act_export_cache.activate.connect (() => { on_export_cache (); });
            action_group.add_action (act_export_cache);
            section_file.append (_("Export Cache Folder"), "ctx.ctx_export_cache");
        }

        if (section_file.get_n_items () > 0) {
            menu_model.append_section (null, section_file);
        }

        var section_delete = new GLib.Menu ();
        section_delete.append (count > 1 ? _("Delete (%d items)").printf (count) : _("Delete"), "win.delete_item");
        menu_model.append_section (null, section_delete);

        show_popover (parent, menu_model, action_group, "ctx", gx, gy);
    }

    // ─── 目录树右键菜单 ──────────────────────────────────────────────

    public static void show_tree_menu (
        Gtk.Widget parent,
        DirectoryItem item,
        int gx,
        int gy,
        File? work_dir,
        ContextMenuAction on_copy_path,
        ContextMenuAction on_show_folder,
        ContextMenuAction on_copy_content,
        ContextMenuAction on_select_lines,
        ContextMenuAction on_export_cache,
        bool can_export_cache
    ) {
        var menu_model = new GLib.Menu ();
        var action_group = new GLib.SimpleActionGroup ();

        var act_copy_path = new GLib.SimpleAction ("tree_copy_path", null);
        act_copy_path.activate.connect (() => { on_copy_path (); });
        action_group.add_action (act_copy_path);
        menu_model.append (_("Copy Path"), "tree.tree_copy_path");

        var act_show_folder = new GLib.SimpleAction ("tree_show_folder", null);
        act_show_folder.activate.connect (() => { on_show_folder (); });
        action_group.add_action (act_show_folder);
        menu_model.append (_("Show in File Manager"), "tree.tree_show_folder");

        if (!item.is_dir) {
            var act_copy_content = new GLib.SimpleAction ("tree_copy_content", null);
            bool is_likely_text = true;
            string lower = item.path.down ();
            string[] bin_exts = { ".pdf", ".docx", ".pptx", ".xlsx", ".zip", ".tar", ".gz",
                                  ".png", ".jpg", ".jpeg", ".exe", ".so", ".dylib" };
            foreach (var ext in bin_exts) {
                if (lower.has_suffix (ext)) { is_likely_text = false; break; }
            }
            act_copy_content.set_enabled (is_likely_text);
            act_copy_content.activate.connect (() => { on_copy_content (); });
            action_group.add_action (act_copy_content);
            menu_model.append (_("Copy File Content"), "tree.tree_copy_content");

            var act_select_lines = new GLib.SimpleAction ("tree_select_lines", null);
            act_select_lines.activate.connect (() => { on_select_lines (); });
            action_group.add_action (act_select_lines);
            menu_model.append (_("Select lines..."), "tree.tree_select_lines");

            var act_export_cache = new GLib.SimpleAction ("tree_export_cache", null);
            act_export_cache.set_enabled (can_export_cache);
            act_export_cache.activate.connect (() => { on_export_cache (); });
            action_group.add_action (act_export_cache);
            menu_model.append (_("Export Cache Folder"), "tree.tree_export_cache");
        }

        show_popover (parent, menu_model, action_group, "tree", gx, gy);
    }

    private static void show_popover (Gtk.Widget parent, GLib.Menu menu_model,
                                       GLib.SimpleActionGroup action_group, string ns,
                                       int gx, int gy) {
        // 关闭任何已存在的 popover, 避免多个 popover 同时显示
        close_active_popover ();

        var popover = new Gtk.PopoverMenu.from_model (menu_model);
        popover.set_has_arrow (false);
        popover.set_parent (parent);
        popover.insert_action_group (ns, action_group);
        popover.add_css_class ("ctx-menu");
        popover.set_halign (Gtk.Align.START);
        popover.set_valign (Gtk.Align.START);

        Gdk.Rectangle rect = Gdk.Rectangle () { x = gx, y = gy, width = 1, height = 1 };
        popover.set_pointing_to (rect);

        // popover 关闭后 (包括外部点击 / action 触发 / Esc) 自动释放 class 引用,
        // 避免野指针
        popover.closed.connect (() => {
            if (active_popover == popover) {
                active_popover = null;
            }
        });

        active_popover = popover;
        popover.popup ();
    }

    // ─── 触屏支持 ─────────────────────────────────────────────────────

    public delegate void ContextMenuPosCallback (int gx, int gy);

    // 触屏长按等价鼠标右键 (HIG): 触屏设备没有 secondary button,
    // 没有该手势则右键菜单完全无法唤出. 各右键 GestureClick 处应成对调用.
    public static void attach_long_press (Gtk.Widget widget, ContextMenuPosCallback cb) {
        var long_press = new Gtk.GestureLongPress ();
        long_press.pressed.connect ((gx, gy) => {
            cb ((int) gx, (int) gy);
        });
        widget.add_controller (long_press);
    }
}
