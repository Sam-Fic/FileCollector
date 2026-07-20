using Gtk;
using Gee;

/**
 * 自动保存 / 崩溃恢复管理器
 *
 * 负责三件事:
 *   1. 状态变更后延迟 (AUTO_SAVE_DELAY_MS) 将当前会话写入恢复文件;
 *   2. 维护定时器 (schedule/cancel);
 *   3. 启动时检测恢复文件, 弹窗询问是否还原.
 *
 * 纯数据侧逻辑 (序列化/反序列化/文件 I/O/弹窗) 全部在此完成;
 * 还原后需要刷新的 View 层 UI 通过 restored/restore_failed 信号交回窗口处理,
 * 避免本类持有任何窗口控件引用.
 */
public class RecoveryManager : GLib.Object {
    public const uint AUTO_SAVE_DELAY_MS = 5000; // 状态变更后 5 秒触发自动保存

    private AppState app_state;
    private uint auto_save_timeout_id = 0;

    // 还原成功: 携带还原出的工作目录 (可能为 null), 窗口据此刷新 UI
    public signal void restored (File? work_dir);
    // 还原失败: 携带错误信息
    public signal void restore_failed (string msg);

    public RecoveryManager (AppState app_state) {
        this.app_state = app_state;
    }

    public void schedule () {
        if (app_state.window_closing) return;
        cancel ();
        auto_save_timeout_id = GLib.Timeout.add (AUTO_SAVE_DELAY_MS, () => {
            auto_save_timeout_id = 0;
            save ();
            return Source.REMOVE;
        });
    }

    public void cancel () {
        if (auto_save_timeout_id != 0) {
            GLib.Source.remove (auto_save_timeout_id);
            auto_save_timeout_id = 0;
        }
    }

    public void save () {
        if (app_state.window_closing) return;
        if (app_state.items.size == 0 && app_state.work_dir == null) {
            // 空状态不需要恢复
            delete_file ();
            return;
        }
        try {
            ProjectManager.write_project_file (
                ConfigManager.get_recovery_file (),
                app_state.work_dir,
                app_state.use_absolute,
                app_state.show_header,
                app_state.items,
                app_state.check_model.checked_files,
                app_state.check_model.checked_dirs,
                app_state.common_phrases,
                app_state.snapshots
            );
        } catch (Error e) {
            warning ("Auto-save recovery failed: %s", e.message);
        }
    }

    public void delete_file () {
        try {
            var f = File.new_for_path (ConfigManager.get_recovery_file ());
            if (f.query_exists ()) {
                f.delete ();
            }
        } catch (Error e) {
            debug ("Failed to delete recovery file: %s", e.message);
        }
    }

    /**
     * 启动时检测恢复文件并在需要时弹窗询问.
     * project_file 用于与已保存项目比较时间戳: 项目更新则不提示.
     */
    public void maybe_prompt_restore (Gtk.Window parent, string? project_file) {
        var recovery_path = ConfigManager.get_recovery_file ();
        var recovery_file = File.new_for_path (recovery_path);
        if (!recovery_file.query_exists ()) return;

        // 如果有未保存的项目文件，比较时间戳决定是否提示
        if (project_file != null) {
            try {
                var recovery_info = recovery_file.query_info (FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                var project_info = File.new_for_path (project_file).query_info (FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                if (project_info.get_modification_time ().tv_sec >= recovery_info.get_modification_time ().tv_sec) {
                    // 项目文件比恢复文件新，不需要恢复
                    delete_file ();
                    return;
                }
            } catch (Error e) {
                // 无法比较，继续提示恢复
            }
        }

        var dialog = new Adw.AlertDialog (
            _("Unsaved Session Found"),
            _("There are unsaved changes from the last session. Restore?")
        );
        dialog.add_response ("discard", _("Discard"));
        dialog.add_response ("restore", _("Restore"));
        dialog.set_response_appearance ("restore", Adw.ResponseAppearance.SUGGESTED);
        dialog.set_default_response ("restore");
        dialog.response.connect ((response) => {
            if (response == "restore") {
                try {
                    File? wd;
                    string? pf;
                    bool ua;
                    bool sh;
                    var new_items = new Gee.ArrayList<ItemData> ();
                    var new_checked = new Gee.HashSet<string> ();
                    var new_dirs = new Gee.HashSet<string> ();
                    var new_phrases = new Gee.ArrayList<string> ();
                    var new_snaps = new Gee.ArrayList<WorkspaceSnapshot> ();

                    ProjectManager.load_project_file (
                        recovery_path, new_items, new_checked, new_dirs, new_phrases, new_snaps,
                        out wd, out pf, out ua, out sh
                    );

                    app_state.replace_from (wd, ua, sh, new_items, new_checked, new_dirs, new_phrases);
                    restored (wd);
                } catch (Error e) {
                    warning ("Recovery failed: %s", e.message);
                    restore_failed (e.message);
                }
            }
            delete_file ();
            dialog.destroy ();
        });
        dialog.present (parent);
    }
}
