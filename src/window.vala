using GLib;
using Gtk;
using Adw;
using Json;
using Gee;

[GtkTemplate (ui = "/com/github/samfic/filecollector/window.ui")]
public class FileCollectorWindow : Adw.ApplicationWindow {
    [GtkChild] private unowned Gtk.ScrolledWindow dir_scrolled;
    [GtkChild] private unowned Gtk.ListView queue_list;
    [GtkChild] private unowned Gtk.Box preview_container;
    [GtkChild] private unowned GtkSource.View preview_view;
    [GtkChild] private unowned Gtk.Button open_folder_btn;
    [GtkChild] private unowned Gtk.Button btn_undo;
    [GtkChild] private unowned Gtk.Button btn_redo;
    [GtkChild] private unowned Gtk.Button btn_generate;
    [GtkChild] private unowned Gtk.Button btn_generate_clipboard;
    [GtkChild] private unowned Gtk.Button btn_add_ext;
    [GtkChild] private unowned Gtk.Button btn_add_text_above;
    [GtkChild] private unowned Gtk.Button btn_add_text_below;
    [GtkChild] private unowned Gtk.Button btn_move_up;
    [GtkChild] private unowned Gtk.Button btn_move_down;
    [GtkChild] private unowned Gtk.Button btn_delete;
    [GtkChild] private unowned Gtk.Button btn_clear;
    [GtkChild] private unowned Gtk.CheckButton radio_relative_path;
    [GtkChild] private unowned Gtk.CheckButton radio_absolute_path;
    [GtkChild] private unowned Gtk.CheckButton check_write_header;
    [GtkChild] private unowned Gtk.Button btn_ai_toc;
    [GtkChild] private unowned Gtk.SearchEntry search_entry;
    [GtkChild] private unowned Adw.ToastOverlay toast_overlay;
    [GtkChild] private unowned Gtk.Paned outer_paned;
    [GtkChild] private unowned Gtk.Paned inner_paned;
    [GtkChild] private unowned Gtk.Button btn_ai_toggle;
    [GtkChild] private unowned Gtk.Paned ai_paned;
    [GtkChild] private unowned Gtk.Frame ai_sidebar;

    [GtkChild] private unowned Gtk.Button btn_retry_preprocess;

    // Git 模式切换
    [GtkChild] private unowned Gtk.Button btn_toggle_git;
    [GtkChild] private unowned Gtk.Button btn_global_search;
    [GtkChild] private unowned Gtk.Stack left_stack;
    [GtkChild] private unowned Gtk.Stack action_stack;
    [GtkChild] private unowned Gtk.Box tree_page;
    [GtkChild] private unowned Gtk.Box git_page;
    [GtkChild] private unowned Gtk.Box normal_actions;
    [GtkChild] private unowned Gtk.Box git_actions;
    [GtkChild] private unowned Gtk.ListView git_list_view;
    [GtkChild] private unowned Gtk.SearchEntry git_search_entry;
    [GtkChild] private unowned Gtk.Button btn_git_add_all_changed;
    [GtkChild] private unowned Gtk.Button btn_git_export_working_diff;
    [GtkChild] private unowned Gtk.Button btn_git_export_commit_diff;
    [GtkChild] private unowned Gtk.Button btn_git_delete;
    [GtkChild] private unowned Gtk.Button btn_git_clear;

    private Gtk.ColumnView dir_column_view;
    private Gtk.TreeListModel tree_list_model;
    private Gtk.FilterListModel filter_model;
    private Gtk.CustomFilter tree_filter;
    private Gtk.SingleSelection tree_selection;
    private GLib.ListStore root_store;
    private string search_text = "";

    private GLib.ListStore queue_store;
    private Gtk.MultiSelection queue_selection;

    private AppState app_state;
    // 向后兼容访问器, 逐步迁移到直接通过 app_state 访问
    private Gee.ArrayList<ItemData> items { get { return app_state.items; } }
    private CheckStateModel check_model { get { return app_state.check_model; } }
    private Gee.ArrayList<string> common_phrases { get { return app_state.common_phrases; } }
    private File? work_dir { get { return app_state.work_dir; } set { app_state.work_dir = value; } }
    private bool use_absolute { get { return app_state.use_absolute; } set { app_state.use_absolute = value; } }
    private bool show_header { get { return app_state.show_header; } set { app_state.show_header = value; } }
    private string? project_file { get { return app_state.project_file; } set { app_state.project_file = value; } }
    private string ai_mode { get { return app_state.ai_mode; } set { app_state.ai_mode = value; } }
    private string ai_file_extension { get { return app_state.ai_file_extension; } set { app_state.ai_file_extension = value; } }
    private string ai_file_label { get { return app_state.ai_file_label; } set { app_state.ai_file_label = value; } }
    private int ai_max_files { get { return app_state.ai_max_files; } set { app_state.ai_max_files = value; } }

    private UndoManager undo_manager;
    private ProjectController project_controller;
    private AIController ai_controller;

    private Adw.WindowTitle? _title_widget;

    private PhrasesPicker? phrases_picker_instance = null;

    // AI 助手
    private AIPanel? ai_panel_instance = null;
    private AISettingsDialog? ai_settings_dialog_instance = null;
    private bool ai_panel_visible = false;
    // 记录 AI 面板展开前的窗口宽度, 隐藏时恢复
    private int pre_ai_width = 0;
    // 缓存 col-resize 光标, 避免 motion 事件每次都创建新对象
    private Gdk.Cursor? col_resize_cursor = null;

    // 后台线程引用: 防止 Thread 对象被提前回收, 并在窗口关闭时 join 确保安全退出
    private Gee.ArrayList<GLib.Thread<void*>> bg_threads = new Gee.ArrayList<GLib.Thread<void*>> ();
    private bool window_closing = false;
    private GLib.Cancellable? app_cancellable = new GLib.Cancellable ();
    // 操作令牌: 目录勾选等分批任务递增, 旧令牌任务在 Idle 中自行放弃, 防止上下文切换后仍修改旧列表
    private uint current_operation_token = 0;
    private uint ensure_path_token = 0;

    // Git 模式状态
    private bool is_git_mode = false;
    private GLib.ListStore git_commit_store;

    // 目录加载进度条
    private Gtk.Revealer dir_load_revealer;
    private Gtk.ProgressBar dir_load_progress;
    private Gtk.Label dir_load_label;
    private Gtk.SingleSelection git_selection;
    private Gee.ArrayList<GitCommit> git_commits;
    private string git_search_text = "";

    // VLM 预处理队列
    private VLMQueueManager vlm_queue;
    private Gtk.Revealer vlm_progress_revealer;
    private Gtk.Label lbl_vlm_status;
    private Gtk.Button btn_vlm_pause;
    private Gtk.Button btn_vlm_cancel;
    private Gtk.ProgressBar progress_vlm;

    // 自动保存 / 崩溃恢复
    private uint auto_save_timeout_id = 0;
    private const uint AUTO_SAVE_DELAY_MS = 5000; // 状态变更后 5 秒触发自动保存


    public FileCollectorWindow (Adw.Application app) {
        GLib.Object (application: app);
    }

    construct {
        app_state = new AppState ();
        project_controller = new ProjectController (app_state);
        ai_controller = new AIController (app_state);
        undo_manager = new UndoManager ();

        ConfigManager.load_common_phrases (app_state.common_phrases);
        load_css ();

        bind_app_state_signals ();

        setup_queue_list ();
        setup_tree_view ();
        setup_git_view ();
        setup_vlm_queue ();
        setup_preview_syntax ();
        sync_path_mode_radios ();
        setup_signals ();
        setup_ai_panel ();
        setup_pane_sizes ();
        setup_shortcuts ();
        search_entry.visible = false;

        btn_retry_preprocess.clicked.connect (() => {
            var indices = get_selected_indices ();
            if (indices.size == 1) {
                int sel = indices.get (0);
                if (sel >= 0 && sel < items.size) {
                    on_retry_preprocess (items.get (sel));
                }
            }
        });

        this.close_request.connect (on_close_request);

        GLib.Idle.add (() => {
            cache_title_widget ();
            check_recovery_on_startup ();
            return Source.REMOVE;
        });
    }

    private void bind_app_state_signals () {
        app_state.items_changed.connect (refresh_list);
        app_state.items_changed.connect (schedule_auto_save);
        app_state.state_changed.connect (() => {
            sync_path_mode_radios ();
            sync_header_checkbox ();
            update_title ();
            update_undo_redo_buttons ();
            schedule_auto_save ();
        });

        // AIController 信号 → View 层 UI 操作
        ai_controller.undo_snapshot_requested.connect (() => push_undo_state ());
        ai_controller.undo_delta_requested.connect ((delta) => push_undo_delta (delta));
        ai_controller.tree_check_changed.connect ((path, checked) => set_tree_item_check (path, checked));
        ai_controller.work_dir_change_requested.connect ((path) => ai_apply_set_work_dir (path));
        ai_controller.clear_items_requested.connect (() => on_clear_items ());
        ai_controller.refresh_list_requested.connect (() => refresh_list ());
        // AI 侧边栏添文件后, 主动触发对应 item 的二进制预处理
        ai_controller.preprocess_item_requested.connect ((path) => {
            for (int i = 0; i < items.size; i++) {
                var it = items.get (i);
                if (it.item_type == "file" && it.file_path == path) {
                    if (it.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
                        vlm_queue.enqueue (it);
                    }
                    break;
                }
            }
        });
        ai_controller.ai_batch_operation_completed.connect (on_ai_batch_operation_completed);
    }

    private void on_ai_batch_operation_completed (string summary) {
        if (!undo_manager.can_undo) return;

        var toast = new Adw.Toast (summary);
        toast.set_button_label (_("撤销"));
        toast.set_timeout (6);

        toast.button_clicked.connect (() => {
            on_undo ();
            var confirm = new Adw.Toast (_("已撤销 AI 的操作"));
            confirm.set_timeout (2);
            toast_overlay.add_toast (confirm);
        });

        toast_overlay.add_toast (toast);
    }

    private bool on_close_request () {
        if (app_cancellable != null) {
            app_cancellable.cancel ();
        }
        window_closing = true;
        if (vlm_queue != null) {
            vlm_queue.cancel ();
        }
        if (ai_panel_instance != null) {
            ai_panel_instance.shutdown ();
        }
        // 正常退出时删除恢复文件
        cancel_auto_save ();
        delete_recovery_file ();
        // 不 join 后台线程: cancel + window_closing 标志已通知线程退出,
        // 进程终止时操作系统会自动回收线程资源, 避免 join 阻塞 GTK 主循环导致卡死
        bg_threads.clear ();
        return false;
    }

    // ─── 自动保存 / 崩溃恢复 ─────────────────────────────────────────────

    private void schedule_auto_save () {
        if (window_closing) return;
        cancel_auto_save ();
        auto_save_timeout_id = GLib.Timeout.add (AUTO_SAVE_DELAY_MS, () => {
            auto_save_timeout_id = 0;
            save_recovery_state ();
            return Source.REMOVE;
        });
    }

    private void cancel_auto_save () {
        if (auto_save_timeout_id != 0) {
            GLib.Source.remove (auto_save_timeout_id);
            auto_save_timeout_id = 0;
        }
    }

    private void save_recovery_state () {
        if (window_closing) return;
        if (items.size == 0 && work_dir == null) {
            // 空状态不需要恢复
            delete_recovery_file ();
            return;
        }
        try {
            ProjectManager.write_project_file (
                ConfigManager.get_recovery_file (),
                work_dir,
                use_absolute,
                show_header,
                items,
                check_model.checked_files,
                check_model.checked_dirs,
                common_phrases
            );
        } catch (Error e) {
            warning ("Auto-save recovery failed: %s", e.message);
        }
    }

    private void delete_recovery_file () {
        try {
            var f = File.new_for_path (ConfigManager.get_recovery_file ());
            if (f.query_exists ()) {
                f.delete ();
            }
        } catch (Error e) {
            debug ("Failed to delete recovery file: %s", e.message);
        }
    }

    private void check_recovery_on_startup () {
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
                    delete_recovery_file ();
                    return;
                }
            } catch (Error e) {
                // 无法比较，继续提示恢复
            }
        }

        var dialog = new Adw.AlertDialog (
            _("发现未保存的会话"),
            _("上次运行存在未保存的更改。是否恢复？")
        );
        dialog.add_response ("discard", _("丢弃"));
        dialog.add_response ("restore", _("恢复"));
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

                    ProjectManager.load_project_file (
                        recovery_path, new_items, new_checked, new_dirs, new_phrases,
                        out wd, out pf, out ua, out sh
                    );

                    app_state.replace_from (wd, ua, sh, new_items, new_checked, new_dirs, new_phrases);
                    undo_manager.clear ();
                    refresh_list ();
                    update_title ();
                    toast_overlay.add_toast (new Adw.Toast (_("已恢复未保存的会话")));
                } catch (Error e) {
                    warning ("Recovery failed: %s", e.message);
                    toast_overlay.add_toast (new Adw.Toast (_("恢复失败: ") + e.message));
                }
            }
            delete_recovery_file ();
            dialog.destroy ();
        });
        dialog.present (this);
    }

    private void load_css () {
        var provider = new Gtk.CssProvider ();
        try {
            provider.load_from_resource ("/com/github/samfic/filecollector/style.css");
            Gtk.StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        } catch (Error e) {
            warning ("Failed to load CSS: %s", e.message);
        }
    }

    public static string load_settings_language () {
        return ConfigManager.load_settings_language ();
    }

    private void setup_queue_list () {
        queue_store = new GLib.ListStore (typeof (ItemData));
        queue_selection = new Gtk.MultiSelection (queue_store);

        var factory = new Gtk.SignalListItemFactory ();
        factory.setup.connect ((obj) => {
            var list_item = obj as Gtk.ListItem;

            var icon = new Gtk.Image ();
            icon.add_css_class ("dim-label");

            var label = new Gtk.Label ("");
            label.ellipsize = Pango.EllipsizeMode.END;
            label.xalign = 0;
            label.hexpand = true;

            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            box.margin_top = 6;
            box.margin_bottom = 6;
            box.margin_start = 8;
            box.margin_end = 8;
            box.append (icon);
            box.append (label);

            var right_click = new Gtk.GestureClick ();
            right_click.set_button (Gdk.BUTTON_SECONDARY);
            right_click.pressed.connect ((n_press, gx, gy) => {
                var li = obj as Gtk.ListItem;
                if (li == null) return;
                uint pos = li.get_position ();
                var bitset = queue_selection.get_selection ();
                if (!bitset.contains (pos)) {
                    queue_selection.unselect_all ();
                    queue_selection.select_item (pos, false);
                }
                var data = li.get_item () as ItemData;
                if (data != null) {
                    show_queue_context_menu (box, data, (int)pos, (int)gx, (int)gy);
                }
            });
            box.add_controller (right_click);

            // 左键单击: 配合 MultiSelection, selection_changed 信号会自动处理预览更新
            var left_click = new Gtk.GestureClick ();
            left_click.set_button (Gdk.BUTTON_PRIMARY);
            left_click.pressed.connect ((n_press, gx, gy) => {
                clear_tree_selection ();
            });
            box.add_controller (left_click);

            list_item.set_child (box);
        });

        factory.bind.connect ((obj) => {
            var list_item = obj as Gtk.ListItem;
            if (list_item == null) return;

            var data = list_item.get_item () as ItemData;
            if (data == null) return;

            var box = list_item.get_child () as Gtk.Box;
            if (box == null) return;

            var icon = box.get_first_child () as Gtk.Image;
            if (icon == null) return;

            var label = icon.get_next_sibling () as Gtk.Label;
            if (label == null) return;

            // 初始渲染
            render_queue_row (list_item, data, label, icon);

            // 监听 position 变化: 上下移动时 ListView 可能复用 ListItem 跟随 item 移动,
            // 而不触发 bind, 仅更新 position; 需监听 position 以重新渲染编号
            ulong pos_handler = list_item.notify["position"].connect (() => {
                var current_data = list_item.get_item () as ItemData;
                if (current_data != null) {
                    render_queue_row (list_item, current_data, label, icon);
                }
            });

            // 监听 content 变化: 编辑确认后 edit_data.content = text 会触发 notify,
            // 实时刷新行内预览 (splice 复用同一对象引用时 ListView 不会重新 bind)
            ulong handler_id = data.notify["content"].connect (() => {
                if (list_item != null && list_item.get_item () != null) {
                    render_queue_row (list_item, data, label, icon);
                }
            });

            // 监听 preprocess_status 变化: 多模态 AI 预处理完成后刷新状态标签
            // 属性变更已在主线程执行 (通过 Idle.add 调度), 此处可直接渲染
            // 注意: GObject 属性名用连字符, 不是下划线
            ulong status_handler_id = data.notify["preprocess-status"].connect (() => {
                if (list_item != null && list_item.get_item () != null) {
                    render_queue_row (list_item, data, label, icon);
                }
                // 同步刷新右侧预览区, 避免状态变化后预览内容未更新
                uint sel = list_item.get_position ();
                var sel_bitset = queue_selection.get_selection ();
                if (sel < queue_store.get_n_items () && sel_bitset.contains (sel) && queue_store.get_item (sel) == data) {
                    update_preview (data);
                }
            });

            // 监听 from_cache 变化: COMPLETED 状态下显示"已缓存"/"已转换"依赖此属性
            ulong cache_handler_id = data.notify["from-cache"].connect (() => {
                if (list_item != null && list_item.get_item () != null) {
                    render_queue_row (list_item, data, label, icon);
                }
            });

            // 将句柄 ID 与所监视的数据模型指针弱挂载到 ListItem 容器上,
            // 供 unbind 时双重校验安全剥离信号
            list_item.set_data<ulong> ("content_notify_id", handler_id);
            list_item.set_data<ulong> ("status_notify_id", status_handler_id);
            list_item.set_data<ulong> ("cache_notify_id", cache_handler_id);
            list_item.set_data<ulong> ("position_notify_id", pos_handler);
            list_item.set_data<ItemData> ("monitored_data_ptr", data);
        });

        factory.unbind.connect ((obj) => {
            var list_item = obj as Gtk.ListItem;
            if (list_item == null) return;

            ulong handler_id = list_item.get_data<ulong> ("content_notify_id");
            ulong status_handler_id = list_item.get_data<ulong> ("status_notify_id");
            ulong cache_handler_id = list_item.get_data<ulong> ("cache_notify_id");
            ulong pos_handler = list_item.get_data<ulong> ("position_notify_id");
            var data = list_item.get_data<ItemData> ("monitored_data_ptr");

            // 安全双重校验: 确认句柄未失效且数据对象依然存在于内存中, 方能安全剥离信号
            if (handler_id != 0 && data != null && GLib.SignalHandler.is_connected (data, handler_id)) {
                GLib.SignalHandler.disconnect (data, handler_id);
            }
            if (status_handler_id != 0 && data != null && GLib.SignalHandler.is_connected (data, status_handler_id)) {
                GLib.SignalHandler.disconnect (data, status_handler_id);
            }
            if (cache_handler_id != 0 && data != null && GLib.SignalHandler.is_connected (data, cache_handler_id)) {
                GLib.SignalHandler.disconnect (data, cache_handler_id);
            }
            if (pos_handler != 0 && GLib.SignalHandler.is_connected (list_item, pos_handler)) {
                GLib.SignalHandler.disconnect (list_item, pos_handler);
            }

            // 显式清空存储节点引用, 防止生命周期残留导致内存泄露
            list_item.set_data ("content_notify_id", null);
            list_item.set_data ("status_notify_id", null);
            list_item.set_data ("cache_notify_id", null);
            list_item.set_data ("position_notify_id", null);
            list_item.set_data ("monitored_data_ptr", null);
        });

        queue_list.model = queue_selection;
        queue_list.factory = factory;
    }

    // 渲染编排列表单行: 根据 item_type 计算 display_name 和 icon, 写入 label/icon
    private void render_queue_row (Gtk.ListItem list_item, ItemData data, Gtk.Label label, Gtk.Image icon) {
        string display_name;
        string icon_name;
        if (data.item_type == "file") {
            var file = File.new_for_path (data.file_path);
            display_name = file.get_basename ();
            if (data.is_missing) {
                icon_name = "dialog-warning-symbolic";
                display_name = _("⚠ %s (缺失)").printf (display_name);
            } else {
                // 根据文件类型选择 GTK 原生图标
                if (data.is_image_target ()) {
                    icon_name = "image-x-generic-symbolic";
                } else if (data.is_document_target ()) {
                    icon_name = "x-office-document-symbolic";
                } else if (data.force_absolute) {
                    icon_name = "document-open-symbolic";
                } else {
                    icon_name = "text-x-generic-symbolic";
                }

                if (data.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
                    switch (data.preprocess_status) {
                        case PreprocessStatus.PENDING:
                            display_name += _(" [等待处理]");
                            break;
                        case PreprocessStatus.CHECKING:
                            // 正在查缓存, 还没真去调 VLM; 复用缓存时只闪这一行
                            display_name += _(" [检查缓存]");
                            break;
                        case PreprocessStatus.PROCESSING:
                            display_name += _(" [处理中...]");
                            break;
                        case PreprocessStatus.COMPLETED:
                            string cache_tag = data.from_cache ? _("已缓存") : _("已转换");
                            display_name += " [%s]".printf (cache_tag);
                            break;
                        case PreprocessStatus.FAILED:
                            display_name += _(" [转换失败]");
                            break;
                    }
                }
                if (data.force_absolute) {
                    display_name += " [%s]".printf (_("来自外部文件"));
                }
            }
        } else {
            var preview = data.content ?? "";
            if (preview.char_count () > 40) {
                int byte_pos = preview.index_of_nth_char (40);
                preview = preview.substring (0, byte_pos) + "…";
            }
            display_name = preview;
            icon_name = "edit-symbolic";
        }

        var pos = list_item.get_position ();
        label.set_text ("%d. %s".printf ((int)pos + 1, display_name));
        icon.icon_name = icon_name;
    }

    private void setup_tree_view () {
        root_store = new GLib.ListStore (typeof (DirectoryItem));

        tree_list_model = new Gtk.TreeListModel (
            root_store,
            false,
            false,
            (item) => ((DirectoryItem)item).children
        );

        tree_filter = new Gtk.CustomFilter (filter_tree_func);
        filter_model = new Gtk.FilterListModel (tree_list_model, tree_filter);

        tree_selection = new Gtk.SingleSelection (filter_model);
        tree_selection.set_autoselect (false);

        dir_column_view = new Gtk.ColumnView (tree_selection);
        dir_column_view.add_css_class ("file-tree");

        var expander_factory = new Gtk.SignalListItemFactory ();
        expander_factory.setup.connect ((obj) => {
            var list_item = obj as Gtk.ListItem;

            var expander = new Gtk.TreeExpander ();
            expander.set_indent_for_icon (true);

            var check = new Gtk.CheckButton ();
            check.add_css_class ("tree-check");
            check.valign = Gtk.Align.CENTER;

            var label = new Gtk.Label ("");
            label.ellipsize = Pango.EllipsizeMode.END;
            label.xalign = 0;
            label.hexpand = true;
            label.valign = Gtk.Align.CENTER;

            var click = new Gtk.GestureClick ();
            click.pressed.connect (() => {
                var row = list_item.get_item () as Gtk.TreeListRow;
                if (row == null) return;
                var item = row.get_item () as DirectoryItem;
                if (item == null || item.is_dir) return;

                var pos = list_item.get_position ();
                tree_selection.selected = pos;
                // preview_tree_item_at 已包含缓存检查, 不要再用
                // 无缓存的 temp_item 调用 update_preview, 否则会覆盖正确预览
                preview_tree_item_at (pos);
                queue_selection.unselect_all ();
            });
            label.add_controller (click);

            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            box.margin_top = 0;
            box.margin_bottom = 0;
            box.margin_start = 2;
            box.margin_end = 2;
            box.append (check);
            box.append (label);

            var right_click_tree = new Gtk.GestureClick ();
            right_click_tree.set_button (Gdk.BUTTON_SECONDARY);
            right_click_tree.pressed.connect ((n_press, gx, gy) => {
                var li = obj as Gtk.ListItem;
                if (li == null) return;
                var row = li.get_item () as Gtk.TreeListRow;
                if (row == null) return;
                var dir_item = row.get_item () as DirectoryItem;
                if (dir_item == null) return;
                tree_selection.selected = li.get_position ();
                // 传 box 而非 li.get_child() (expander), 保证 popover parent 与
                // 手势坐标的参考系一致, 否则菜单会偏移到 expander 左上角附近
                show_tree_context_menu (box, dir_item, (int)gx, (int)gy);
            });
            box.add_controller (right_click_tree);

            expander.set_child (box);
            list_item.set_child (expander);
        });

        expander_factory.bind.connect ((obj) => {
            var list_item = obj as Gtk.ListItem;
            if (list_item == null) return;

            var row = list_item.get_item () as Gtk.TreeListRow;
            if (row == null) return;

            var item = row.get_item () as DirectoryItem;
            if (item == null) return;

            var expander = list_item.get_child () as Gtk.TreeExpander;
            if (expander == null) return;

            var box = expander.get_child () as Gtk.Box;
            if (box == null) return;

            var check = box.get_first_child () as Gtk.CheckButton;
            if (check == null) return;

            var label = check.get_next_sibling () as Gtk.Label;
            if (label == null) return;

            expander.set_list_row (row);
            expander.set_hide_expander (!item.is_dir);

            check.active = item.checked;
            check.inconsistent = item.inconsistent;

            check.set_data<DirectoryItem> ("item", item);
            ulong handler_id = check.notify["active"].connect (on_check_toggled);
            check.set_data<ulong?> ("handler_id", handler_id);

            ulong state_handler_id = item.state_changed.connect (() => {
                var hid = check.get_data<ulong?> ("handler_id");
                if (hid != null) {
                    SignalHandler.block (check, hid);
                }
                check.active = item.checked;
                check.inconsistent = item.inconsistent;
                if (hid != null) {
                    SignalHandler.unblock (check, hid);
                }
            });
            check.set_data<ulong?> ("state_handler_id", state_handler_id);

            highlight_tree_label (label, item.name);

            if (item.is_dir) {
                ulong expanded_handler_id = row.notify["expanded"].connect (() => {
                    if (row.get_expanded () && item.children.get_n_items () == 0 && !item.children_loading) {
                        load_directory_children_lazy (item);
                    }
                });
                row.set_data<ulong?> ("expanded-handler", expanded_handler_id);
            }
        });

        expander_factory.unbind.connect ((obj) => {
            var list_item = obj as Gtk.ListItem;
            if (list_item == null) return;

            var expander = list_item.get_child () as Gtk.TreeExpander;
            if (expander == null) return;

            var box = expander.get_child () as Gtk.Box;
            if (box == null) return;

            var check = box.get_first_child () as Gtk.CheckButton;
            if (check == null) return;

            var handler_id = check.get_data<ulong?> ("handler_id");
            if (handler_id != null) {
                GLib.SignalHandler.disconnect (check, handler_id);
            }

            var state_handler_id = check.get_data<ulong?> ("state_handler_id");
            var item = check.get_data<DirectoryItem> ("item");
            if (state_handler_id != null && item != null) {
                GLib.SignalHandler.disconnect (item, state_handler_id);
            }

            var row = list_item.get_item () as Gtk.TreeListRow;
            if (row != null) {
                var expanded_handler_id = row.get_data<ulong?> ("expanded-handler");
                if (expanded_handler_id != null) {
                    GLib.SignalHandler.disconnect (row, expanded_handler_id);
                }
            }

            expander.set_list_row (null);
        });

        var column = new Gtk.ColumnViewColumn (null, expander_factory);
        column.set_expand (true);
        dir_column_view.append_column (column);

        dir_column_view.show_column_separators = false;
        dir_column_view.show_row_separators = false;

        GLib.Idle.add (() => {
            var child = dir_column_view.get_first_child ();
            if (child != null) {
                child.visible = false;
            }
            return Source.REMOVE;
        });

        dir_scrolled.set_child (dir_column_view);

        tree_selection.selection_changed.connect (on_tree_selection_changed);
        dir_column_view.activate.connect (on_column_view_activated);
    }

    private void on_column_view_activated (uint position) {
        preview_tree_item_at (position);
        queue_selection.unselect_all ();
    }

    private void on_tree_selection_changed (uint position, uint n_items) {
        if (position == Gtk.INVALID_LIST_POSITION) return;
        preview_tree_item_at (position);
        queue_selection.unselect_all ();
    }

    private void preview_tree_item_at (uint position) {
        var row = filter_model.get_item (position) as Gtk.TreeListRow;
        if (row == null) return;

        var item = row.get_item () as DirectoryItem;
        if (item == null || item.is_dir) return;

        var temp_item = new ItemData ("file", item.path, null, false);

        // 二进制文件仅检查缓存, 命中则直接展示; 未命中不触发 VLM 转换
        if (temp_item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
            if (work_dir != null) {
                try {
                    string? cached = BinaryPreprocessor.try_cache_only (temp_item, work_dir.get_path ());
                    if (cached != null) {
                        temp_item.preprocess_status = PreprocessStatus.COMPLETED;
                        temp_item.preprocessed_content = cached;
                        temp_item.from_cache = true;
                    }
                } catch (Error e) {
                    // 缓存检查失败, 保持 NONE 状态, 展示"预览不可用"
                }
            }
        }

        update_preview (temp_item);
    }

    private void clear_tree_selection () {
        tree_selection.selected = Gtk.INVALID_LIST_POSITION;
    }

    private void on_search_changed () {
        search_text = search_entry.text;
        tree_filter.changed (Gtk.FilterChange.DIFFERENT);
    }

    private void highlight_tree_label (Gtk.Label label, string name) {
        if (search_text.length == 0) {
            label.set_text (name);
            return;
        }
        string lower_name = name.casefold ();
        string lower_search = search_text.casefold ();
        int idx = lower_name.index_of (lower_search);
        if (idx < 0) {
            label.set_text (name);
            return;
        }
        string escaped = GLib.Markup.escape_text (name);
        string escaped_search = GLib.Markup.escape_text (name.substring (idx, search_text.length));
        // 重新搜索转义后的文本 (因为 escape 可能改变长度)
        string lower_escaped = escaped.casefold ();
        string lower_escaped_search = escaped_search.casefold ();
        int esc_idx = lower_escaped.index_of (lower_escaped_search);
        if (esc_idx < 0) {
            label.set_markup (escaped);
            return;
        }
        string before = escaped.substring (0, esc_idx);
        string match = escaped.substring (esc_idx, escaped_search.length);
        string after = escaped.substring (esc_idx + escaped_search.length);
        label.set_markup (before + "<b><u>" + match + "</u></b>" + after);
    }

    private bool filter_tree_func (GLib.Object item) {
        if (search_text == "") return true;
        var row = item as Gtk.TreeListRow;
        if (row == null) return true;
        var dir_item = row.get_item () as DirectoryItem;
        if (dir_item == null) return true;

        if (dir_item.name.casefold ().contains (search_text.casefold ()))
            return true;

        if (dir_item.is_dir && has_matching_descendant (dir_item))
            return true;

        return false;
    }

    private bool has_matching_descendant (DirectoryItem item) {
        for (uint i = 0; i < item.children.get_n_items (); i++) {
            var child = item.children.get_item (i) as DirectoryItem;
            if (child == null) continue;
            if (child.name.casefold ().contains (search_text.casefold ()))
                return true;
            if (child.is_dir && has_matching_descendant (child))
                return true;
        }
        return false;
    }

    private void on_check_toggled (GLib.Object obj, GLib.ParamSpec pspec) {
        var check = obj as Gtk.CheckButton;
        if (check == null) return;

        var item = check.get_data<DirectoryItem> ("item");
        if (item == null) return;

        push_undo_state ();

        bool new_checked = check.active;
        // 统一入口: 通过 check_model 修改状态, 再同步 items 和 UI
        apply_check_change (item, new_checked);
    }

    // 统一的勾选变更处理: 修改 check_model -> 同步 items -> 刷新 UI 三态
    private void apply_check_change (DirectoryItem item, bool new_checked) {
        if (item.is_dir) {
            // 立即更新 checked_dirs 确保未展开目录状态正确
            check_model.set_dir_checked (item.path, new_checked);
            refresh_all_tree_states ();
            dir_column_view.queue_draw ();

            // 目录: 后台线程递归收集文件路径和子目录路径, 完成后在主线程更新 UI, 避免阻塞
            string dir_path = item.path;
            try {
                GLib.Thread<void*>? thread = null;
                thread = new Thread<void*> ("collect-files", () => {
                    var file_paths = new Gee.ArrayList<string> ();
                    var dir_paths = new Gee.ArrayList<string> ();
                    collect_files_from_filesystem (dir_path, file_paths, dir_paths);
                    Idle.add (() => {
                        if (window_closing) {
                            return Source.REMOVE;
                        }
                        apply_dir_check_result (new_checked, dir_paths, file_paths);
                        if (thread != null) bg_threads.remove (thread);
                        return Source.REMOVE;
                    });
                    return null;
                });
                bg_threads.add (thread);
            } catch (ThreadError e) {
                warning ("Failed to create collect-files thread: %s", e.message);
                // 后备: 同步执行
                var file_paths = new Gee.ArrayList<string> ();
                var dir_paths = new Gee.ArrayList<string> ();
                collect_files_from_filesystem (dir_path, file_paths, dir_paths);
                apply_dir_check_result (new_checked, dir_paths, file_paths);
            }
        } else {
            // 文件: 直接切换 (无 I/O, 同步即可)
            check_model.toggle_file (item.path);
            if (new_checked) {
                    if (!path_in_items (item.path)) {
                    var new_item = new ItemData ("file", item.path, null, false);
                    items.add (new_item);
                    if (new_item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
                        vlm_queue.enqueue (new_item);
                    }
                }
            } else {
                remove_items_by_path (item.path);
            }
            refresh_all_tree_states ();
            dir_column_view.queue_draw ();
            refresh_list ();
        }
    }

    // 目录勾选/取消勾选的后台收集结果处理 (主线程)
    // items 增删分批在 Idle 中执行, 避免数万文件一次性处理阻塞 UI
    private void apply_dir_check_result (bool new_checked, Gee.ArrayList<string> dir_paths, Gee.ArrayList<string> file_paths) {
        current_operation_token++;
        uint my_token = current_operation_token;

        // check_model 操作: 同步执行 (数据结构操作, 相对快速)
        if (new_checked) {
            // 先加文件 (内部会移除祖先目录的 checked_dirs 标记)
            check_model.add_files ((string[]) file_paths.to_array ());
            // 再把当前目录及其所有子孙目录加回 checked_dirs
            foreach (var d in dir_paths) {
                check_model.set_dir_checked (d, true);
            }
        } else {
            foreach (var d in dir_paths) {
                check_model.set_dir_checked (d, false);
            }
            check_model.remove_files ((string[]) file_paths.to_array ());
            // 将取消勾选的目录的祖先从 checked_dirs 中移除, 使其降级为半选
            check_model.remove_ancestors_from_checked_dirs (dir_paths.get (0));
        }
        // 树状态立即刷新 (基于 check_model, 已同步更新)
        refresh_all_tree_states ();
        dir_column_view.queue_draw ();

        // items 增删: 分批在 Idle 中执行, 每批 200 个, 避免阻塞主循环
        int chunk_size = 200;
        int idx = 0;
        Idle.add (() => {
            if (window_closing || my_token != current_operation_token) return Source.REMOVE;
            int count = 0;
            while (idx < file_paths.size && count < chunk_size) {
                var p = file_paths.get (idx);
                if (new_checked) {
                    if (!path_in_items (p)) {
                        var new_item = new ItemData ("file", p, null, false);
                        items.add (new_item);
                        if (new_item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
                            vlm_queue.enqueue (new_item);
                        }
                    }
                } else {
                    remove_items_by_path (p);
                }
                idx++;
                count++;
            }
            if (idx < file_paths.size) {
                return Source.CONTINUE;
            }
            if (!window_closing && my_token == current_operation_token) {
                refresh_list ();
            }
            return Source.REMOVE;
        });
    }

    // 从文件系统递归收集目录下所有文件路径和子目录路径
    private void collect_files_from_filesystem (string dir_path, Gee.ArrayList<string> out_files, Gee.ArrayList<string> out_dirs) {
        if (app_cancellable != null && app_cancellable.is_cancelled ()) return;
        out_dirs.add (dir_path);
        var dir = File.new_for_path (dir_path);
        try {
            var enumerator = dir.enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_IS_SYMLINK,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS
            );
            FileInfo info;
            while ((info = enumerator.next_file ()) != null) {
                if (app_cancellable != null && app_cancellable.is_cancelled ()) return;
                string child_name = info.get_name ();
                if (child_name == ".filecollector_cache") continue;
                var child = dir.get_child (child_name);
                if (info.get_is_symlink () && info.get_file_type () == FileType.DIRECTORY) {
                    continue;
                }
                if (info.get_file_type () == FileType.DIRECTORY) {
                    collect_files_from_filesystem (child.get_path (), out_files, out_dirs);
                } else {
                    out_files.add (child.get_path ());
                }
            }
        } catch (Error e) {
            warning ("collect_files_from_filesystem: %s", e.message);
        }
    }

    // 从 check_model 重新计算所有可见节点的三态
    // 辅助结构体：自底向上递归中收集子树统计信息, 消除双重递归
    private struct SubtreeStats {
        public int total_files;
        public int checked_files;
        public bool has_unloaded_descendants;
        public bool all_unloaded_in_checked_dirs;
    }

    private void refresh_all_tree_states () {
        for (uint i = 0; i < root_store.get_n_items (); i++) {
            refresh_and_collect_stats ((DirectoryItem) root_store.get_item (i));
        }
    }

    // 自底向上刷新并收集统计信息, 消除原有的 refresh_subtree_states + compute_state + collect_file_stats 三重递归
    private SubtreeStats refresh_and_collect_stats (DirectoryItem item) {
        SubtreeStats stats = SubtreeStats ();

        if (!item.is_dir) {
            // 文件节点：直接查 check_model
            bool is_checked = item.path in check_model.checked_files;
            item.checked = is_checked;
            item.inconsistent = false;

            stats.total_files = 1;
            stats.checked_files = is_checked ? 1 : 0;
            return stats;
        }

        // 目录节点：先递归处理所有子节点, 顺带收集统计
        stats.total_files = 0;
        stats.checked_files = 0;
        stats.has_unloaded_descendants = false;
        stats.all_unloaded_in_checked_dirs = true; // 默认真空为真
        for (uint i = 0; i < item.children.get_n_items (); i++) {
            var child = (DirectoryItem) item.children.get_item (i);
            var child_stats = refresh_and_collect_stats (child);
            stats.total_files += child_stats.total_files;
            stats.checked_files += child_stats.checked_files;
            if (child_stats.has_unloaded_descendants) {
                stats.has_unloaded_descendants = true;
                if (!child_stats.all_unloaded_in_checked_dirs) {
                    stats.all_unloaded_in_checked_dirs = false;
                }
            }
            // 子目录未加载时, 其后代文件不在树中, stats 无法覆盖
            if (child.is_dir && !child.children_loaded) {
                stats.has_unloaded_descendants = true;
                // 未加载的子目录若不在 checked_dirs 中, 则无法确认其后代是否全选
                if (!(child.path in check_model.checked_dirs)) {
                    stats.all_unloaded_in_checked_dirs = false;
                }
            }
        }

        // 根据子节点统计结果推导当前目录的三态 (统一状态机)
        bool has_checked = check_model.has_checked_descendant (item.path);
        bool in_checked_dirs = item.path in check_model.checked_dirs;

        if (stats.total_files > 0) {
            if (in_checked_dirs) {
                // 用户显式勾选该目录，但子文件可能还在后台加入 checked_files，或用户手动取消了部分
                if (stats.checked_files < stats.total_files) {
                    item.checked = false;
                    item.inconsistent = true; // 半选 (加载中或部分取消)
                } else {
                    item.checked = true;
                    item.inconsistent = false; // 全选
                }
            } else {
                // 目录未被显式勾选，状态完全由已加载的子文件决定
                if (stats.checked_files == 0) {
                    item.checked = false;
                    item.inconsistent = has_checked; // 若未加载的深层后代有选中，则半选；否则未选
                } else if (stats.checked_files == stats.total_files
                           && (!stats.has_unloaded_descendants || stats.all_unloaded_in_checked_dirs)) {
                    // 所有已加载文件均勾选, 且无未加载后代或未加载后代均在 checked_dirs 中 → 确认全选
                    item.checked = true;
                    item.inconsistent = false;
                } else {
                    // 有未加载后代且不在 checked_dirs 中, 无法确认是否所有文件均勾选 → 半选 (保守)
                    item.checked = false;
                    item.inconsistent = true;
                }
            }
        } else {
            // 空目录或未加载子节点的目录 (懒加载占位逻辑)
            // checked_dirs 已在项目加载时清理过时条目 (移除有缺失文件的目录)
            // 因此 in_checked_dirs 可靠地表示全选态
            if (in_checked_dirs) {
                item.checked = true;
                item.inconsistent = false; // 全选态 (占位)
            } else if (has_checked) {
                item.checked = false;
                item.inconsistent = true; // 半选态 (占位)
            } else {
                item.checked = false;
                item.inconsistent = false; // 彻底未勾选
            }
        }
        return stats;
    }

    // 保留兼容接口
    private void refresh_subtree_states (DirectoryItem item) {
        refresh_and_collect_stats (item);
    }

    private void push_undo_state () {
        undo_manager.push (new UndoDelta.for_snapshot (
            new UndoState (items, check_model.checked_files, check_model.checked_dirs, work_dir, use_absolute, show_header)));
    }

    private void push_undo_delta (UndoDelta delta) {
        undo_manager.push (delta);
    }

    private int find_item_index (ItemData data) {
        for (int i = 0; i < items.size; i++) {
            if (items.get (i) == data) return i;
        }
        return -1;
    }

    private void on_undo () {
        undo_manager.set_in_progress (true);
        var delta = undo_manager.pop_undo ();
        if (delta == null) { undo_manager.set_in_progress (false); return; }
        var redo_delta = build_redo_delta (delta);
        apply_undo_delta (delta);
        undo_manager.push_redo (redo_delta);
        undo_manager.set_in_progress (false);
        if (delta.op != UndoOp.SNAPSHOT) {
            refresh_list ();
        }
        update_undo_redo_buttons ();
    }

    private void on_redo () {
        undo_manager.set_in_progress (true);
        var delta = undo_manager.pop_redo ();
        if (delta == null) { undo_manager.set_in_progress (false); return; }
        var undo_delta = build_undo_delta (delta);
        apply_redo_delta (delta);
        undo_manager.push_undo (undo_delta);
        undo_manager.set_in_progress (false);
        if (delta.op != UndoOp.SNAPSHOT) {
            refresh_list ();
        }
        update_undo_redo_buttons ();
    }

    // 根据 undo delta 构建对应的 redo delta (捕获当前状态作为 redo 依据)
    private UndoDelta build_redo_delta (UndoDelta d) {
        switch (d.op) {
            case UndoOp.SNAPSHOT:
                return new UndoDelta.for_snapshot (
                    new UndoState (items, check_model.checked_files, check_model.checked_dirs, work_dir, use_absolute, show_header));
            case UndoOp.INSERT:
                // redo = 重新插入同样的 items
                return new UndoDelta.for_insert (d.index, d.items);
            case UndoOp.REMOVE:
                // redo = 再次移除
                return new UndoDelta.for_remove (d.index, d.items, d.removed_checked_paths);
            case UndoOp.EDIT:
                return new UndoDelta.for_edit (d.index, d.old_content, d.new_content);
            case UndoOp.SWAP:
                return new UndoDelta.for_swap (d.index, d.index2);
            case UndoOp.MOVE:
                return new UndoDelta.for_move (d.from_index, d.to_index);
            case UndoOp.SET_ABSOLUTE:
                return new UndoDelta.for_absolute (d.old_bool_value, d.new_bool_value,
                                                    d.old_show_header, show_header);
            case UndoOp.SET_HEADER:
                return new UndoDelta.for_header (d.old_bool_value, d.new_bool_value);
            default:
                return new UndoDelta.for_snapshot (
                    new UndoState (items, check_model.checked_files, check_model.checked_dirs, work_dir, use_absolute, show_header));
        }
    }

    // 根据 redo delta 构建对应的 undo delta
    private UndoDelta build_undo_delta (UndoDelta d) {
        switch (d.op) {
            case UndoOp.SNAPSHOT:
                return new UndoDelta.for_snapshot (
                    new UndoState (items, check_model.checked_files, check_model.checked_dirs, work_dir, use_absolute, show_header));
            case UndoOp.INSERT:
                return new UndoDelta.for_insert (d.index, d.items);
            case UndoOp.REMOVE:
                return new UndoDelta.for_remove (d.index, d.items, d.removed_checked_paths);
            case UndoOp.EDIT:
                return new UndoDelta.for_edit (d.index, d.old_content, d.new_content);
            case UndoOp.SWAP:
                return new UndoDelta.for_swap (d.index, d.index2);
            case UndoOp.MOVE:
                return new UndoDelta.for_move (d.from_index, d.to_index);
            case UndoOp.SET_ABSOLUTE:
                return new UndoDelta.for_absolute (d.old_bool_value, d.new_bool_value,
                                                    d.old_show_header, show_header);
            case UndoOp.SET_HEADER:
                return new UndoDelta.for_header (d.old_bool_value, d.new_bool_value);
            default:
                return new UndoDelta.for_snapshot (
                    new UndoState (items, check_model.checked_files, check_model.checked_dirs, work_dir, use_absolute, show_header));
        }
    }

    private void apply_undo_delta (UndoDelta d) {
        switch (d.op) {
            case UndoOp.SNAPSHOT:
                restore_undo_state (d.snapshot);
                return;
            case UndoOp.INSERT:
                // undo 插入 = 移除
                for (int i = 0; i < d.items.size; i++) items.remove_at (d.index);
                break;
            case UndoOp.REMOVE:
                // undo 移除 = 重新插入
                for (int i = 0; i < d.items.size; i++) {
                    items.insert (d.index + i, d.items.get (i));
                }
                if (d.removed_checked_paths != null) {
                    for (int i = 0; i < d.removed_checked_paths.size; i++) {
                        set_tree_item_check (d.removed_checked_paths.get (i), true);
                    }
                }
                break;
            case UndoOp.EDIT:
                items.get (d.index).content = d.old_content;
                break;
            case UndoOp.SWAP:
                var tmp = items.get (d.index);
                items.set (d.index, items.get (d.index2));
                items.set (d.index2, tmp);
                break;
            case UndoOp.MOVE:
                // undo: 从 to_index 移回 from_index
                if (d.to_index < 0 || d.to_index >= items.size ||
                    d.from_index < 0 || d.from_index > items.size) break;
                var it = items.get (d.to_index);
                items.remove_at (d.to_index);
                items.insert (d.from_index, it);
                break;
            case UndoOp.SET_ABSOLUTE:
                apply_absolute_change (d.old_bool_value, d.old_show_header);
                break;
            case UndoOp.SET_HEADER:
                apply_header_change (d.old_bool_value);
                break;
        }
    }

    private void apply_redo_delta (UndoDelta d) {
        switch (d.op) {
            case UndoOp.SNAPSHOT:
                restore_undo_state (d.snapshot);
                return;
            case UndoOp.INSERT:
                for (int i = 0; i < d.items.size; i++) {
                    items.insert (d.index + i, d.items.get (i));
                }
                break;
            case UndoOp.REMOVE:
                for (int i = 0; i < d.items.size; i++) items.remove_at (d.index);
                if (d.removed_checked_paths != null) {
                    for (int i = 0; i < d.removed_checked_paths.size; i++) {
                        set_tree_item_check (d.removed_checked_paths.get (i), false);
                    }
                }
                break;
            case UndoOp.EDIT:
                items.get (d.index).content = d.new_content;
                break;
            case UndoOp.SWAP:
                var tmp = items.get (d.index);
                items.set (d.index, items.get (d.index2));
                items.set (d.index2, tmp);
                break;
            case UndoOp.MOVE:
                if (d.from_index < 0 || d.from_index >= items.size ||
                    d.to_index < 0 || d.to_index > items.size) break;
                var it = items.get (d.from_index);
                items.remove_at (d.from_index);
                items.insert (d.to_index, it);
                break;
            case UndoOp.SET_ABSOLUTE:
                apply_absolute_change (d.new_bool_value, d.new_show_header);
                break;
            case UndoOp.SET_HEADER:
                apply_header_change (d.new_bool_value);
                break;
        }
    }

    // 同步单选按钮到 use_absolute 状态
    private void sync_path_mode_radios () {
        radio_absolute_path.notify["active"].disconnect (on_path_mode_changed);
        radio_relative_path.notify["active"].disconnect (on_path_mode_changed);
        radio_absolute_path.active = use_absolute;
        radio_relative_path.active = !use_absolute;
        radio_absolute_path.notify["active"].connect (on_path_mode_changed);
        radio_relative_path.notify["active"].connect (on_path_mode_changed);
    }

    // 同步头部复选框到 show_header 状态
    private void sync_header_checkbox () {
        check_write_header.notify["active"].disconnect (on_header_check_changed);
        check_write_header.active = show_header;
        check_write_header.notify["active"].connect (on_header_check_changed);
    }

    // 根据 work_dir 更新窗口标题/副标题
    private void update_title () {
        if (work_dir != null) {
            update_subtitle (work_dir.get_path ());
        } else {
            update_subtitle (null);
        }
    }

    // 统一应用 use_absolute 变更 (undo/redo 共用)
    private void apply_absolute_change (bool new_abs, bool new_hdr) {
        use_absolute = new_abs;
        show_header = new_hdr;
        radio_absolute_path.notify["active"].disconnect (on_path_mode_changed);
        radio_relative_path.notify["active"].disconnect (on_path_mode_changed);
        check_write_header.notify["active"].disconnect (on_header_check_changed);
        radio_absolute_path.active = new_abs;
        radio_relative_path.active = !new_abs;
        check_write_header.active = new_hdr;
        radio_absolute_path.notify["active"].connect (on_path_mode_changed);
        radio_relative_path.notify["active"].connect (on_path_mode_changed);
        check_write_header.notify["active"].connect (on_header_check_changed);
    }

    // 统一应用 show_header 变更 (undo/redo 共用)
    private void apply_header_change (bool new_hdr) {
        show_header = new_hdr;
        check_write_header.notify["active"].disconnect (on_header_check_changed);
        check_write_header.active = new_hdr;
        check_write_header.notify["active"].connect (on_header_check_changed);
    }

    private void restore_undo_state (UndoState state) {
        items.clear ();
        for (int i = 0; i < state.n_items; i++) {
            items.add (state.get_item (i));
        }

        check_model.replace_from (state.checked_paths, state.checked_dirs);

        use_absolute = state.use_absolute;
        show_header = state.show_header;
        radio_absolute_path.notify["active"].disconnect (on_path_mode_changed);
        radio_relative_path.notify["active"].disconnect (on_path_mode_changed);
        check_write_header.notify["active"].disconnect (on_header_check_changed);
        radio_absolute_path.active = use_absolute;
        radio_relative_path.active = !use_absolute;
        check_write_header.active = show_header;
        radio_absolute_path.notify["active"].connect (on_path_mode_changed);
        radio_relative_path.notify["active"].connect (on_path_mode_changed);
        check_write_header.notify["active"].connect (on_header_check_changed);

        bool work_dir_changed = false;
        if (state.work_dir != null && work_dir != null) {
            work_dir_changed = state.work_dir.get_path () != work_dir.get_path ();
        } else if (state.work_dir != null || work_dir != null) {
            work_dir_changed = true;
        }

        if (work_dir_changed) {
            work_dir = state.work_dir;
            if (work_dir != null) {
                update_subtitle (work_dir.get_path ());
                root_store.remove_all ();
                var root_item = new DirectoryItem (work_dir.get_basename (), work_dir.get_path (), true);
                root_store.append (root_item);
                load_directory_children_lazy (root_item);
                search_entry.visible = true;
                var root_row = tree_list_model.get_item (0) as Gtk.TreeListRow;
                if (root_row != null) root_row.set_expanded (true);
            } else {
                update_subtitle (null);
                root_store.remove_all ();
                search_entry.visible = false;
            }
        } else if (work_dir != null && root_store.get_n_items () > 0) {
            refresh_all_tree_states ();
        }

        refresh_list ();
        update_undo_redo_buttons ();
    }

    private void update_undo_redo_buttons () {
        btn_undo.sensitive = undo_manager.can_undo;
        btn_redo.sensitive = undo_manager.can_redo;
    }

    private void setup_signals () {
        open_folder_btn.clicked.connect (() => on_open_folder_clicked.begin ());
        btn_undo.clicked.connect (on_undo);
        btn_redo.clicked.connect (on_redo);
        btn_add_ext.clicked.connect (on_add_external_files);
        btn_add_text_above.clicked.connect (() => insert_text (true));
        btn_add_text_below.clicked.connect (() => insert_text (false));
        btn_move_up.clicked.connect (on_move_up);
        btn_move_down.clicked.connect (on_move_down);
        btn_delete.clicked.connect (on_delete_item);
        btn_clear.clicked.connect (on_clear_items_with_confirm);
        btn_generate.clicked.connect (on_generate_clicked);
        btn_generate_clipboard.clicked.connect (on_generate_to_clipboard_clicked);
        radio_absolute_path.notify["active"].connect (on_path_mode_changed);
        radio_relative_path.notify["active"].connect (on_path_mode_changed);
        check_write_header.notify["active"].connect (on_header_check_changed);
        btn_ai_toc.clicked.connect (on_ai_toc_clicked);

        queue_selection.selection_changed.connect (on_queue_selection_changed);
        queue_list.activate.connect (on_queue_row_activated);

        search_entry.search_changed.connect (on_search_changed);

        update_queue_buttons ();
    }

    // ─── Git 模式 ────────────────────────────────────────────────────────

    private void setup_git_view () {
        git_commits = new Gee.ArrayList<GitCommit> ();
        git_commit_store = new GLib.ListStore (typeof (GitCommit));
        git_selection = new Gtk.SingleSelection (git_commit_store);
        git_selection.set_autoselect (false);

        var factory = new Gtk.SignalListItemFactory ();
        factory.setup.connect (setup_git_list_item);
        factory.bind.connect (bind_git_list_item);
        git_list_view.model = git_selection;
        git_list_view.factory = factory;

        // Register stack pages by name
        left_stack.get_page (tree_page).set_name ("tree_page");
        left_stack.get_page (git_page).set_name ("git_page");
        action_stack.get_page (normal_actions).set_name ("normal_actions");
        action_stack.get_page (git_actions).set_name ("git_actions");
        left_stack.visible_child = tree_page;
        action_stack.visible_child = normal_actions;

        // 目录加载进度条 (添加到 left_stack 的父容器)
        dir_load_label = new Gtk.Label (null);
        dir_load_label.xalign = 0;
        dir_load_label.add_css_class ("dim-label");
        dir_load_label.add_css_class ("caption");

        dir_load_progress = new Gtk.ProgressBar ();
        dir_load_progress.add_css_class ("osd");

        var dir_load_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
        dir_load_box.margin_start = 12;
        dir_load_box.margin_end = 12;
        dir_load_box.margin_bottom = 6;
        dir_load_box.append (dir_load_label);
        dir_load_box.append (dir_load_progress);

        dir_load_revealer = new Gtk.Revealer ();
        dir_load_revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN;
        dir_load_revealer.reveal_child = false;
        dir_load_revealer.set_child (dir_load_box);

        var parent_box = left_stack.get_parent () as Gtk.Box;
        if (parent_box != null) {
            parent_box.append (dir_load_revealer);
        }

        btn_toggle_git.clicked.connect (on_toggle_git_mode);
        git_search_entry.search_changed.connect (on_git_search_changed);

        btn_git_add_all_changed.clicked.connect (on_git_add_all_changed);
        btn_git_export_working_diff.clicked.connect (on_git_export_working_diff);
        btn_git_export_commit_diff.clicked.connect (on_git_export_commit_diff);
        btn_git_delete.clicked.connect (on_delete_item);
        btn_git_clear.clicked.connect (on_clear_items_with_confirm);

        git_selection.selection_changed.connect (on_git_selection_changed);
    }

    private void setup_git_list_item (GLib.Object obj) {
        var list_item = obj as Gtk.ListItem;

        var hash_label = new Gtk.Label ("");
        hash_label.add_css_class ("monospace");
        hash_label.add_css_class ("dim-label");
        hash_label.xalign = 0;
        hash_label.ellipsize = Pango.EllipsizeMode.END;
        hash_label.width_chars = 8;

        var msg_label = new Gtk.Label ("");
        msg_label.xalign = 0;
        msg_label.hexpand = true;
        msg_label.ellipsize = Pango.EllipsizeMode.END;

        var date_label = new Gtk.Label ("");
        date_label.add_css_class ("dim-label");
        date_label.add_css_class ("caption");
        date_label.xalign = 1;

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        box.margin_top = 4;
        box.margin_bottom = 4;
        box.margin_start = 4;
        box.margin_end = 4;
        box.append (hash_label);
        box.append (msg_label);
        box.append (date_label);

        // 右键菜单: 复制提交哈希
        var right_click = new Gtk.GestureClick ();
        right_click.set_button (Gdk.BUTTON_SECONDARY);
        right_click.pressed.connect ((n_press, gx, gy) => {
            var li = obj as Gtk.ListItem;
            if (li == null) return;
            var commit = li.get_item () as GitCommit;
            if (commit == null) return;

            var menu = new GLib.Menu ();
            menu.append (_("复制短哈希"), "git.copy_short_hash");
            menu.append (_("复制完整哈希"), "git.copy_full_hash");
            menu.append (_("复制提交信息"), "git.copy_message");

            var actions = new GLib.SimpleActionGroup ();

            var act_short = new GLib.SimpleAction ("copy_short_hash", null);
            act_short.activate.connect (() => {
                get_clipboard ().set_text (commit.short_hash);
                show_toast (_("已复制: %s").printf (commit.short_hash));
            });
            actions.add_action (act_short);

            var act_full = new GLib.SimpleAction ("copy_full_hash", null);
            act_full.activate.connect (() => {
                get_clipboard ().set_text (commit.hash);
                show_toast (_("已复制: %s").printf (commit.short_hash));
            });
            actions.add_action (act_full);

            var act_msg = new GLib.SimpleAction ("copy_message", null);
            act_msg.activate.connect (() => {
                get_clipboard ().set_text (commit.message);
                show_toast (_("已复制提交信息"));
            });
            actions.add_action (act_msg);

            var popover = new Gtk.PopoverMenu.from_model (menu);
            popover.set_has_arrow (false);
            popover.set_parent (box);
            popover.insert_action_group ("git", actions);
            popover.add_css_class ("ctx-menu");
            popover.set_halign (Gtk.Align.START);
            popover.set_valign (Gtk.Align.START);
            Gdk.Rectangle rect = { (int) gx, (int) gy, 1, 1 };
            popover.set_pointing_to (rect);
            popover.popup ();
        });
        box.add_controller (right_click);

        // 左键点击: 强制刷新预览 (解决点击同一行不触发 selection_changed 的问题)
        var left_click = new Gtk.GestureClick ();
        left_click.set_button (Gdk.BUTTON_PRIMARY);
        left_click.pressed.connect ((n_press, gx, gy) => {
            // 延迟一帧, 等 SingleSelection 先更新选中项
            Idle.add (() => {
                refresh_git_preview ();
                return Source.REMOVE;
            });
        });
        box.add_controller (left_click);

        list_item.set_child (box);
    }

    private void bind_git_list_item (GLib.Object obj) {
        var list_item = obj as Gtk.ListItem;
        if (list_item == null) return;

        var commit = list_item.get_item () as GitCommit;
        if (commit == null) return;

        var box = list_item.get_child () as Gtk.Box;
        if (box == null) return;

        var hash_label = box.get_first_child () as Gtk.Label;
        if (hash_label == null) return;

        var msg_label = hash_label.get_next_sibling () as Gtk.Label;
        if (msg_label == null) return;

        var date_label = msg_label.get_next_sibling () as Gtk.Label;
        if (date_label == null) return;

        hash_label.set_text (commit.short_hash);
        msg_label.set_text (commit.message);
        date_label.set_text (commit.date);
    }

    private void on_toggle_git_mode () {
        is_git_mode = !is_git_mode;

        if (is_git_mode) {
            left_stack.visible_child_name = "git_page";
            action_stack.visible_child_name = "git_actions";
            btn_toggle_git.icon_name = "folder-symbolic";
            btn_toggle_git.tooltip_text = _("切换到文件树");
            git_search_entry.visible = work_dir != null;
            btn_git_add_all_changed.sensitive = work_dir != null;
            btn_git_export_working_diff.sensitive = work_dir != null;

            if (git_commits.size == 0 && work_dir != null) {
                load_git_history_async ();
            }
        } else {
            left_stack.visible_child_name = "tree_page";
            action_stack.visible_child_name = "normal_actions";
            btn_toggle_git.icon_name = "xsi-git-symbolic";
            btn_toggle_git.tooltip_text = _("切换到 Git 提交历史");
        }
    }

    private void on_git_search_changed () {
        git_search_text = git_search_entry.text;
        refresh_git_list ();
    }

    private void refresh_git_list () {
        git_commit_store.remove_all ();
        foreach (var commit in git_commits) {
            if (git_search_text != "" &&
                !commit.message.down ().contains (git_search_text.down ()) &&
                !commit.short_hash.down ().contains (git_search_text.down ())) {
                continue;
            }
            git_commit_store.append (commit);
        }
    }

    private void load_git_history_async () {
        if (work_dir == null) return;
        string dir = work_dir.get_path ();

        try {
            GLib.Thread<void*>? thread = null;
            thread = new Thread<void*> ("git-log", () => {
                load_git_history_in_thread (dir, thread);
                return null;
            });
            bg_threads.add (thread);
        } catch (ThreadError e) {
            warning ("Failed to create git-log thread: %s", e.message);
        }
    }

    private void load_git_history_in_thread (string dir, GLib.Thread<void*>? thread) {
        string? error_msg = null;
        Gee.ArrayList<GitCommit>? result = null;
        try {
            result = GitService.get_log (dir, 100);
        } catch (GLib.Error e) {
            error_msg = e.message;
        }

        Idle.add (() => {
            if (window_closing) return Source.REMOVE;
            if (error_msg != null) {
                show_toast (_("Git 日志加载失败: %s").printf (error_msg));
            } else if (result != null) {
                git_commits.clear ();
                foreach (var c in result) git_commits.add (c);
                refresh_git_list ();
            }
            if (thread != null) bg_threads.remove (thread);
            return Source.REMOVE;
        });
    }

    private void on_git_selection_changed (uint position, uint n_items) {
        refresh_git_preview ();
    }

    private void refresh_git_preview () {
        uint pos = git_selection.selected;
        if (pos == Gtk.INVALID_LIST_POSITION || pos >= git_commit_store.get_n_items ()) {
            btn_git_export_commit_diff.sensitive = false;
            return;
        }

        var commit = git_commit_store.get_item (pos) as GitCommit;
        if (commit == null) {
            btn_git_export_commit_diff.sensitive = false;
            return;
        }

        btn_git_export_commit_diff.sensitive = true;
        load_and_preview_commit_diff.begin (commit.hash);
    }

    private async void load_and_preview_commit_diff (string hash) {
        if (work_dir == null) return;

        btn_retry_preprocess.visible = false;
        apply_preview_raw (_("正在加载 Diff..."));

        string dir = work_dir.get_path ();
        string diff_text = "";
        try {
            diff_text = GitService.get_commit_diff (dir, hash);
        } catch (Error e) {
            diff_text = "Error: " + e.message;
        }

        render_diff_to_preview (diff_text);
    }

    private void render_diff_to_preview (string diff_text) {
        Gtk.Widget? child = preview_container.get_first_child ();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling ();
            preview_container.remove (child);
            child = next;
        }
        preview_container.append (preview_view);

        var buffer = preview_view.get_buffer () as GtkSource.Buffer;
        buffer.set_highlight_syntax (false);
        buffer.set_text ("", -1);

        if (buffer.get_tag_table ().lookup ("diff-add") == null) {
            buffer.create_tag ("diff-add",
                "foreground", "rgba(39,166,69,1.0)", null);
            buffer.create_tag ("diff-del",
                "foreground", "rgba(214,59,74,1.0)", null);
            buffer.create_tag ("diff-hunk",
                "foreground", "rgba(3,102,214,1.0)",
                "weight", Pango.Weight.BOLD, null);
            buffer.create_tag ("diff-header",
                "foreground", "rgba(3,102,214,1.0)",
                "weight", Pango.Weight.BOLD, null);
            buffer.create_tag ("diff-file",
                "foreground", "rgba(145,65,172,1.0)",
                "weight", Pango.Weight.BOLD, null);
            buffer.create_tag ("diff-sep",
                "foreground", "rgba(128,128,128,0.5)", null);
        }

        Gtk.TextIter iter;
        buffer.get_start_iter (out iter);
        string? last_file = null;
        foreach (var line in diff_text.split ("\n")) {
            // 提取文件名并插入分隔标题
            if (line.has_prefix ("diff ")) {
                // diff --git a/path b/path → 提取 path
                string fname = extract_diff_filename (line);
                if (fname != null && fname != last_file) {
                    last_file = fname;
                    buffer.insert_with_tags_by_name (ref iter, "\n", -1, "diff-sep");
                    buffer.insert_with_tags_by_name (ref iter,
                        "━━━ %s ━━━\n".printf (fname), -1, "diff-file");
                }
            }

            string? tag = null;
            if (line.has_prefix ("+++") || line.has_prefix ("---") ||
                line.has_prefix ("diff ") || line.has_prefix ("index ")) {
                tag = "diff-header";
            } else if (line.has_prefix ("@@")) {
                tag = "diff-hunk";
            } else if (line.has_prefix ("+")) {
                tag = "diff-add";
            } else if (line.has_prefix ("-")) {
                tag = "diff-del";
            }

            if (tag != null) {
                buffer.insert_with_tags_by_name (ref iter, line + "\n", -1, tag);
            } else {
                buffer.insert (ref iter, line + "\n", -1);
            }
        }
    }

    private static string? extract_diff_filename (string diff_line) {
        // diff --git a/src/foo.vala b/src/foo.vala → src/foo.vala
        int a_pos = diff_line.index_of (" a/");
        int b_pos = diff_line.index_of (" b/");
        if (b_pos > a_pos && a_pos >= 0) {
            return diff_line.substring (b_pos + 3);
        }
        if (a_pos >= 0) {
            string rest = diff_line.substring (a_pos + 3);
            int space = rest.index_of (" ");
            return space >= 0 ? rest.substring (0, space) : rest;
        }
        return null;
    }

    // 简单的预览文本设置 (无 Markdown)
    private void apply_preview_raw (string text) {
        apply_preview_no_highlight (text);
    }

    // ─── Git 中栏按钮操作 ────────────────────────────────────────────────

    private void on_git_add_all_changed () {
        if (work_dir == null) {
            show_toast (_("请先设置工作目录"));
            return;
        }

        try {
            string status = GitService.get_status (work_dir.get_path ());
            if (status.strip ().length == 0) {
                show_toast (_("当前工作区没有未提交的改动"));
                return;
            }

            var files_to_add = new Gee.ArrayList<string> ();
            foreach (var line in status.split ("\n")) {
                string trimmed = line.strip ();
                if (trimmed.length < 4) continue;
                // porcelain v1 format: XY <path>
                string path_part = trimmed.substring (3).strip ();
                // 处理 rename: "old -> new"
                if (path_part.contains (" -> ")) {
                    string[] ren = path_part.split (" -> ", 2);
                    path_part = ren[1];
                }
                string abs = GLib.Path.build_filename (work_dir.get_path (), path_part);
                if (FileUtils.test (abs, FileTest.EXISTS) && !FileUtils.test (abs, FileTest.IS_DIR)) {
                    files_to_add.add (abs);
                }
            }

            if (files_to_add.size == 0) {
                show_toast (_("没有可添加的文件"));
                return;
            }

            push_undo_state ();
            int added = 0;
            foreach (var path in files_to_add) {
                if (!path_in_items (path)) {
                    var new_item = new ItemData ("file", path, null, false);
                    items.add (new_item);
                    if (new_item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
                        vlm_queue.enqueue (new_item);
                    }
                    if (!(path in check_model.checked_files)) {
                        check_model.add_files ({ path });
                    }
                    added++;
                }
            }
            refresh_all_tree_states ();
            refresh_list ();
            show_toast (_("已添加 %d 个改动文件到编排列表").printf (added));
        } catch (Error e) {
            show_error (_("Git 错误"), e.message);
        }
    }

    private void on_git_export_working_diff () {
        if (work_dir == null) {
            show_toast (_("请先设置工作目录"));
            return;
        }

        try {
            string diff = GitService.get_working_tree_diff (work_dir.get_path ());
            if (diff.strip ().length == 0) {
                show_toast (_("当前工作区没有未提交的改动"));
                return;
            }
            push_undo_state ();
            string md_text = "# Git Working Tree Diff\n\n```diff\n%s\n```".printf (diff);
            items.insert (0, new ItemData ("text", null, md_text, false));
            refresh_list ();
            show_toast (_("已将工作区 Diff 插入编排列表"));
        } catch (Error e) {
            show_error (_("Git 错误"), e.message);
        }
    }

    private void on_git_export_commit_diff () {
        uint pos = git_selection.selected;
        if (pos == Gtk.INVALID_LIST_POSITION || pos >= git_commit_store.get_n_items ()) return;
        var commit = git_commit_store.get_item (pos) as GitCommit;
        if (commit == null || work_dir == null) return;

        try {
            string diff = GitService.get_commit_diff (work_dir.get_path (), commit.hash);
            push_undo_state ();
            string md_text = "# Git Commit: %s (%s)\n\n```diff\n%s\n```".printf (
                commit.short_hash, commit.message, diff);
            items.insert (0, new ItemData ("text", null, md_text, false));
            refresh_list ();
            show_toast (_("已将 Commit Diff 插入编排列表"));
        } catch (Error e) {
            show_error (_("Git 错误"), e.message);
        }
    }

    // ─── 语法高亮 ────────────────────────────────────────────────────────

    private GtkSource.LanguageManager lang_manager;
    private GtkSource.StyleSchemeManager scheme_manager;

    private void setup_preview_syntax () {
        lang_manager = GtkSource.LanguageManager.get_default ();
        scheme_manager = new GtkSource.StyleSchemeManager ();

        // 注册应用自带主题目录
        string app_data_dir = "/usr/share/filecollector";
        if (!FileUtils.test (app_data_dir, FileTest.EXISTS)) {
            app_data_dir = GLib.Path.build_filename (Environment.get_current_dir (), "data");
        }
        string theme_dir = GLib.Path.build_filename (app_data_dir, "gtksourceview-5", "styles");
        if (FileUtils.test (theme_dir, FileTest.EXISTS)) {
            string[] search_paths = scheme_manager.get_search_path ();
            var new_paths = new string[search_paths.length + 1];
            new_paths[0] = theme_dir;
            for (int i = 0; i < search_paths.length; i++) new_paths[i + 1] = search_paths[i];
            scheme_manager.set_search_path ((string?[]?) new_paths);
        }

        apply_preview_scheme ();

        preview_view.set_wrap_mode (Gtk.WrapMode.WORD_CHAR);
        preview_view.add_css_class ("sourceview");
        preview_view.set_show_line_numbers (false);

        // 监听系统深浅色模式变化
        var style_manager = Adw.StyleManager.get_default ();
        style_manager.notify["dark"].connect (() => apply_preview_scheme ());
    }

    private void apply_preview_scheme () {
        bool dark = Adw.StyleManager.get_default ().dark;
        string scheme_id = dark ? "filecollector-dark" : "filecollector-light";
        var scheme = scheme_manager.get_scheme (scheme_id);
        if (scheme != null) {
            (preview_view.get_buffer () as GtkSource.Buffer).set_style_scheme (scheme);
        }
    }

    private GtkSource.Language? guess_language (string? file_path) {
        if (file_path == null) return null;
        // 先按文件名猜测 (如 Makefile, Dockerfile)
        var lang = lang_manager.guess_language (file_path, null);
        if (lang != null) return lang;
        // fallback: 按 MIME 类型
        var file = File.new_for_path (file_path);
        try {
            var info = file.query_info (FileAttribute.STANDARD_CONTENT_TYPE, FileQueryInfoFlags.NONE, null);
            string? mime = info.get_content_type ();
            if (mime != null) {
                lang = lang_manager.guess_language (null, mime);
            }
        } catch (Error e) { /* ignore */ }
        return lang;
    }

    private void apply_preview_with_highlight (string text, string? file_path) {
        Gtk.Widget? child = preview_container.get_first_child ();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling ();
            preview_container.remove (child);
            child = next;
        }
        preview_container.append (preview_view);

        var buffer = preview_view.get_buffer () as GtkSource.Buffer;
        buffer.set_text ("", -1);
        buffer.set_language (guess_language (file_path));
        buffer.set_highlight_syntax (true);
        buffer.set_text (text, -1);
        preview_view.set_show_line_numbers (text.length > 0);
    }

    private void apply_preview_no_highlight (string text) {
        Gtk.Widget? child = preview_container.get_first_child ();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling ();
            preview_container.remove (child);
            child = next;
        }
        preview_container.append (preview_view);

        var buffer = preview_view.get_buffer () as GtkSource.Buffer;
        buffer.set_highlight_syntax (false);
        buffer.set_text (text, -1);
        preview_view.set_show_line_numbers (text.length > 0);
    }

    // ─── VLM 预处理队列 ────────────────────────────────────────────────

    private void setup_vlm_queue () {
        vlm_queue = new VLMQueueManager ();
        vlm_queue.executor = vlm_task_executor;

        // 构建悬浮进度卡片 (programmatic, 避免 Blueprint 嵌套问题)
        lbl_vlm_status = new Gtk.Label (_("正在预处理 0/0 个文件..."));
        lbl_vlm_status.hexpand = true;
        lbl_vlm_status.xalign = 0;
        lbl_vlm_status.ellipsize = Pango.EllipsizeMode.END;
        lbl_vlm_status.add_css_class ("heading");

        btn_vlm_pause = new Gtk.Button.from_icon_name ("media-playback-pause-symbolic");
        btn_vlm_pause.tooltip_text = _("暂停");
        btn_vlm_pause.add_css_class ("flat");
        btn_vlm_pause.add_css_class ("circular");

        btn_vlm_cancel = new Gtk.Button.from_icon_name ("process-stop-symbolic");
        btn_vlm_cancel.tooltip_text = _("取消全部");
        btn_vlm_cancel.add_css_class ("flat");
        btn_vlm_cancel.add_css_class ("circular");

        var header_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        header_box.append (lbl_vlm_status);
        header_box.append (btn_vlm_pause);
        header_box.append (btn_vlm_cancel);

        progress_vlm = new Gtk.ProgressBar ();
        progress_vlm.add_css_class ("osd");

        var card_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        card_box.margin_top = 12;
        card_box.margin_bottom = 12;
        card_box.margin_start = 12;
        card_box.margin_end = 12;
        card_box.set_size_request (280, -1);
        card_box.append (header_box);
        card_box.append (progress_vlm);

        var card_frame = new Gtk.Frame (null);
        card_frame.add_css_class ("card");
        card_frame.add_css_class ("vlm-progress-card");
        card_frame.set_child (card_box);

        vlm_progress_revealer = new Gtk.Revealer ();
        vlm_progress_revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_UP;
        vlm_progress_revealer.reveal_child = false;
        vlm_progress_revealer.halign = Gtk.Align.END;
        vlm_progress_revealer.valign = Gtk.Align.END;
        vlm_progress_revealer.margin_end = 12;
        vlm_progress_revealer.margin_bottom = 12;
        vlm_progress_revealer.set_child (card_frame);

        // 用 Gtk.Overlay 包裹 ToolbarView, 使进度卡片能悬浮在窗口右下角
        var main_overlay = new Gtk.Overlay ();
        var toolbar_view = toast_overlay.child;
        toast_overlay.child = null;
        main_overlay.child = toolbar_view;
        main_overlay.add_overlay (vlm_progress_revealer);
        toast_overlay.child = main_overlay;

        // 信号连接
        vlm_queue.progress_changed.connect (on_vlm_progress_changed);
        vlm_queue.state_changed.connect (on_vlm_state_changed);

        btn_vlm_pause.clicked.connect (() => {
            if (vlm_queue.is_paused) {
                vlm_queue.resume ();
                btn_vlm_pause.icon_name = "media-playback-pause-symbolic";
                btn_vlm_pause.tooltip_text = _("暂停");
            } else {
                vlm_queue.pause ();
                btn_vlm_pause.icon_name = "media-playback-start-symbolic";
                btn_vlm_pause.tooltip_text = _("继续");
            }
        });

        btn_vlm_cancel.clicked.connect (() => {
            vlm_queue.cancel ();
            show_toast (_("已取消所有预处理任务"));
        });
    }

    private void on_vlm_progress_changed (int completed, int total, int active) {
        lbl_vlm_status.set_text (_("正在预处理 %d/%d 个文件...").printf (completed, total));
        progress_vlm.set_fraction (total > 0 ? (double) completed / total : 0);
    }

    private void on_vlm_state_changed (bool has_tasks) {
        vlm_progress_revealer.set_reveal_child (has_tasks);
    }

    private void vlm_task_executor (ItemData item, VLMQueueManager manager) {
        // 捕获 work_dir 到本地变量, 防止主线程并发修改
        File? local_work_dir = work_dir;

        // 1. 检查缓存
        string? cached_md = null;
        string hash = "";
        try {
            hash = PreprocessCache.compute_file_hash (item.file_path);
            if (local_work_dir != null) {
                var cache = new PreprocessCache (local_work_dir.get_path ());
                cached_md = cache.get_cached_markdown (item.file_path, hash);
            }
        } catch (Error e) {
            warning ("Cache check failed: %s", e.message);
        }

        if (manager.check_cancelled ()) {
            manager.notify_finished (item);
            return;
        }

        if (cached_md != null) {
            Idle.add (() => {
                item.preprocessed_content = cached_md;
                item.preprocess_status = PreprocessStatus.COMPLETED;
                item.from_cache = true;
                refresh_list ();
                return Source.REMOVE;
            });
            manager.notify_finished (item);
            return;
        }

        // 2. 调用 VLM
        Idle.add (() => {
            item.preprocess_status = PreprocessStatus.PROCESSING;
            refresh_list ();
            return Source.REMOVE;
        });

        var settings = ConfigManager.load_multimodal_ai_settings ();
        if (!settings.enabled || settings.api_key == "") {
            Idle.add (() => {
                item.preprocess_status = PreprocessStatus.FAILED;
                refresh_list ();
                return Source.REMOVE;
            });
            manager.notify_finished (item);
            return;
        }

        try {
            string[] base64_images;
            string[] mime_types;

            if (item.is_image_target ()) {
                string? b64 = BinaryConverter.convert_image_to_base64 (item.file_path);
                if (b64 == null) throw new IOError.FAILED ("Image load failed");
                base64_images = { b64 };
                mime_types = { BinaryConverter.get_output_mime_for_image (item.file_path) };
            } else {
                string[]? images = BinaryConverter.convert_to_base64_images (item.file_path);
                if (images == null) throw new IOError.FAILED ("Document render failed");
                base64_images = images;
                mime_types = new string[images.length];
                for (int i = 0; i < images.length; i++) mime_types[i] = "image/png";
            }

            if (manager.check_cancelled ()) { manager.notify_finished (item); return; }

            string prompt = (settings.system_prompt_override != null && settings.system_prompt_override.length > 0)
                ? settings.system_prompt_override
                : get_prompt_for_item (item);

            var client = new MultimodalAIClient (
                settings.base_url, settings.api_key, settings.model,
                prompt, settings.timeout
            );
            string md = client.process_images (base64_images, mime_types);

            if (manager.check_cancelled ()) { manager.notify_finished (item); return; }

            if (local_work_dir != null) {
                var cache = new PreprocessCache (local_work_dir.get_path ());
                cache.save_markdown (item.file_path, hash, md);
            }

            Idle.add (() => {
                item.preprocessed_content = md;
                item.preprocess_status = PreprocessStatus.COMPLETED;
                refresh_list ();
                return Source.REMOVE;
            });
        } catch (Error e) {
            warning ("VLM Task failed: %s", e.message);
            Idle.add (() => {
                item.preprocess_status = PreprocessStatus.FAILED;
                refresh_list ();
                return Source.REMOVE;
            });
        }

        manager.notify_finished (item);
    }

    private void setup_pane_sizes () {
        outer_paned.notify["position"].connect (clamp_outer_paned_position);
        outer_paned.notify["width"].connect (clamp_outer_paned_position);
        inner_paned.notify["position"].connect (clamp_inner_paned_position);

        GLib.Idle.add (() => {
            if (window_closing) return Source.REMOVE;
            measure_pane_minimums ();
            update_window_min_size ();
            clamp_outer_paned_position ();
            clamp_inner_paned_position ();
            return Source.REMOVE;
        });
    }

    private const int PANED_SEP = 6;

    private bool _clamping_inner_from_outer = false;
    // 阻断 clamp_outer_paned_position 在修改 outer_paned.position 时
    // 触发 notify["position"] 信号导致的递归调用
    private bool _clamping_outer = false;

    private int left_min_width = 0;
    private int center_min_width = 0;
    private int right_min_width = 0;

    // 根据当前可见面板的最小宽度, 计算并设置 ai_paned 的最小宽度,
    // 防止窗口缩小到导致面板内容被裁剪.
    private void update_window_min_size () {
        int min_w = 0;

        // ai_paned 自身的 margin
        min_w += ai_paned.get_margin_start () + ai_paned.get_margin_end ();

        // AI 边栏 (可见时才计入)
        if (ai_sidebar.visible) {
            min_w += ai_sidebar.get_margin_start () + ai_sidebar.get_margin_end ();
            min_w += 280; // ai_sidebar 的 width-request
            min_w += PANED_SEP; // ai_paned 分隔条
        }

        // outer_paned margin
        min_w += outer_paned.get_margin_start () + outer_paned.get_margin_end ();

        // 左栏
        var left_child = outer_paned.get_start_child ();
        if (left_child != null) {
            min_w += left_child.get_margin_start () + left_child.get_margin_end ();
            min_w += left_min_width;
            min_w += PANED_SEP; // outer_paned 分隔条
        }

        // inner_paned margin
        min_w += inner_paned.get_margin_start () + inner_paned.get_margin_end ();

        // 中栏
        var center_child = inner_paned.get_start_child ();
        if (center_child != null) {
            min_w += center_child.get_margin_start () + center_child.get_margin_end ();
            min_w += center_min_width;
            min_w += PANED_SEP; // inner_paned 分隔条
        }

        // 右栏
        var right_child = inner_paned.get_end_child ();
        if (right_child != null) {
            min_w += right_child.get_margin_start () + right_child.get_margin_end ();
            min_w += right_min_width;
        }

        ai_paned.set_size_request (min_w, -1);
    }

    private void measure_pane_minimums () {
        int min, nat;

        var left_child = outer_paned.get_start_child ();
        if (left_child != null) {
            left_child.measure (Gtk.Orientation.HORIZONTAL, -1, out min, out nat, null, null);
            left_min_width = int.max (min, 200);
        }

        var center_child = inner_paned.get_start_child ();
        if (center_child != null) {
            center_child.measure (Gtk.Orientation.HORIZONTAL, -1, out min, out nat, null, null);
            center_min_width = int.max (min, 400);
        }

        var right_child = inner_paned.get_end_child ();
        if (right_child != null) {
            right_child.measure (Gtk.Orientation.HORIZONTAL, -1, out min, out nat, null, null);
            right_min_width = int.max (min, 200);
        }
    }

    private void clamp_outer_paned_position () {
        if (_clamping_outer) return;
        _clamping_outer = true;
        var pw = outer_paned.get_width ();
        if (pw <= 0) {
            _clamping_outer = false;
            return;
        }
        var pos = outer_paned.position;
        var cw = pw - outer_paned.get_margin_start () - outer_paned.get_margin_end ();

        // 子项 margin: measure() 返回的 min 不含 margin, 需额外计入
        var left_child = outer_paned.get_start_child ();
        int left_margin = (left_child != null)
            ? left_child.get_margin_start () + left_child.get_margin_end () : 0;

        var center_child = inner_paned.get_start_child ();
        var right_child = inner_paned.get_end_child ();
        int center_margin = (center_child != null)
            ? center_child.get_margin_start () + center_child.get_margin_end () : 0;
        int right_margin = (right_child != null)
            ? right_child.get_margin_start () + right_child.get_margin_end () : 0;
        int inner_margin = inner_paned.get_margin_start () + inner_paned.get_margin_end ();

        var min_pos = left_min_width + left_margin;
        // inner_paned 需要的最小宽度 = 自身 margin + 中栏(含margin) + 分隔条 + 右栏(含margin)
        var inner_needed = inner_margin + center_margin + center_min_width
            + PANED_SEP + right_margin + right_min_width;
        var max_pos = int.max (min_pos, cw - PANED_SEP - inner_needed);
        if (pos < min_pos) {
            outer_paned.position = min_pos;
        } else if (pos > max_pos) {
            outer_paned.position = max_pos;
        }

        // 同步 clamp inner_paned
        var inner_width = cw - PANED_SEP - outer_paned.position;
        var icw = inner_width - inner_paned.get_margin_start () - inner_paned.get_margin_end ();
        var ipos = inner_paned.position;
        var imin = center_min_width + center_margin;
        var imax = int.max (imin, icw - PANED_SEP - right_min_width - right_margin);
        _clamping_inner_from_outer = true;
        if (ipos < imin) {
            inner_paned.position = imin;
        } else if (ipos > imax) {
            inner_paned.position = imax;
        }
        _clamping_inner_from_outer = false;
        _clamping_outer = false;
    }

    private void clamp_inner_paned_position () {
        if (_clamping_inner_from_outer) return;
        var pw = inner_paned.get_width ();
        if (pw <= 0) return;
        var pos = inner_paned.position;
        var cw = pw - inner_paned.get_margin_start () - inner_paned.get_margin_end ();

        var center_child = inner_paned.get_start_child ();
        var right_child = inner_paned.get_end_child ();
        int center_margin = (center_child != null)
            ? center_child.get_margin_start () + center_child.get_margin_end () : 0;
        int right_margin = (right_child != null)
            ? right_child.get_margin_start () + right_child.get_margin_end () : 0;

        var min_pos = center_min_width + center_margin;
        var max_pos = int.max (min_pos, cw - PANED_SEP - right_min_width - right_margin);
        if (pos < min_pos) {
            inner_paned.position = min_pos;
        } else if (pos > max_pos) {
            inner_paned.position = max_pos;
        }
    }

    // ─── Keyboard Shortcuts ───────────────────────────────────────────────

    private void setup_shortcuts () {
        // 使用 GAction + set_accels_for_action 替代 ShortcutController,
        // 避免 GTK4 bug (#6246): widget 销毁后 controller 仍留在 manager 中导致崩溃

        var act_generate = new GLib.SimpleAction ("generate", null);
        act_generate.activate.connect (() => on_generate_clicked ());
        this.add_action (act_generate);

        var act_generate_clipboard = new GLib.SimpleAction ("generate_to_clipboard", null);
        act_generate_clipboard.activate.connect (() => on_generate_to_clipboard_clicked ());
        this.add_action (act_generate_clipboard);

        var act_undo = new GLib.SimpleAction ("undo", null);
        act_undo.activate.connect (() => on_undo ());
        this.add_action (act_undo);

        var act_redo = new GLib.SimpleAction ("redo", null);
        act_redo.activate.connect (() => on_redo ());
        this.add_action (act_redo);

        var act_clear = new GLib.SimpleAction ("clear_items", null);
        act_clear.activate.connect (() => on_clear_items_with_confirm ());
        this.add_action (act_clear);

        var act_delete = new GLib.SimpleAction ("delete_item", null);
        act_delete.activate.connect (() => on_delete_item ());
        this.add_action (act_delete);

        var act_move_up = new GLib.SimpleAction ("move_up", null);
        act_move_up.activate.connect (() => on_move_up ());
        this.add_action (act_move_up);

        var act_move_down = new GLib.SimpleAction ("move_down", null);
        act_move_down.activate.connect (() => on_move_down ());
        this.add_action (act_move_down);

        var act_add_external = new GLib.SimpleAction ("add_external_files", null);
        act_add_external.activate.connect (() => on_add_external_files ());
        this.add_action (act_add_external);

        var act_insert = new GLib.SimpleAction ("insert_text", null);
        act_insert.activate.connect (() => insert_text (true));
        this.add_action (act_insert);

        var act_insert_no_header = new GLib.SimpleAction ("insert_text_no_header", null);
        act_insert_no_header.activate.connect (() => insert_text (false));
        this.add_action (act_insert_no_header);

        var act_toggle_ai = new GLib.SimpleAction ("toggle_ai_panel", null);
        act_toggle_ai.activate.connect (() => toggle_ai_panel ());
        this.add_action (act_toggle_ai);

        var act_global_search = new GLib.SimpleAction ("global_search", null);
        act_global_search.activate.connect (() => on_global_search ());
        this.add_action (act_global_search);

        // 延迟注册快捷键, 等待 application 就绪
        GLib.Idle.add (() => {
            var app = this.application;
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

    public CliController create_cli_from_state () {
        var cli = new CliController ();
        cli.initialize_from_app_state (app_state);
        return cli;
    }

    public void apply_cli_operations (CliController cli) {
        push_undo_state ();
        bool work_dir_changed = cli.apply_to_state (app_state);

        if (work_dir_changed) {
            update_subtitle (work_dir.get_path ());
            root_store.remove_all ();
            var root_item = new DirectoryItem (work_dir.get_basename (), work_dir.get_path (), true);
            root_store.append (root_item);
            load_directory_children_lazy (root_item);
            GLib.Idle.add (() => {
                var root_row = tree_list_model.get_item (0) as Gtk.TreeListRow;
                if (root_row != null) {
                    root_row.set_expanded (true);
                }
                return Source.REMOVE;
            });
            search_entry.visible = true;
        } else if (work_dir != null && root_store.get_n_items () > 0) {
            foreach (var path in check_model.checked_files) {
                ensure_path_loaded (path);
            }
            refresh_all_tree_states ();
        }

        refresh_list ();

        if (cli.operation_messages.size > 0) {
            var messages = new Gee.ArrayList<string> ();
            for (int i = 0; i < cli.operation_messages.size; i++) {
                messages.add (cli.operation_messages.get (i));
            }
            GLib.Idle.add (() => {
                for (int i = 0; i < messages.size; i++) {
                    var toast = new Adw.Toast (messages.get (i));
                    toast.timeout = 2;
                    toast_overlay.add_toast (toast);
                }
                return Source.REMOVE;
            });
        }
    }

    public void initialize_from_cli (CliController cli) {
        apply_cli_operations (cli);
    }

    // ─── Tree View ───────────────────────────────────────────────────────

    private void remove_items_by_path (string path) {
        for (int i = items.size - 1; i >= 0; i--) {
            var item = items.get (i);
            if (item.item_type == "file" && item.file_path == path) {
                items.remove_at (i);
            }
        }
    }

    // 检查 items 中是否已存在指定路径的文件项 (含 force_absolute 外部文件)
    private bool path_in_items (string path) {
        for (int i = 0; i < items.size; i++) {
            var item = items.get (i);
            if (item.item_type == "file" && item.file_path == path) {
                return true;
            }
        }
        return false;
    }

    private async void on_open_folder_clicked () {
        var dialog = new Gtk.FileDialog ();
        dialog.title = _("选择工作文件夹");
        try {
            var folder = yield dialog.select_folder (this, null);
            if (folder == null) return;
            this.work_dir = folder;

            update_subtitle (folder.get_path ());

            root_store.remove_all ();
            check_model.clear ();
            items.clear ();
            undo_manager.clear ();
            update_undo_redo_buttons ();

            var root_item = new DirectoryItem (folder.get_basename (), folder.get_path (), true);
            root_store.append (root_item);

            load_directory_children_lazy (root_item);
            search_entry.visible = true;

            var root_row = tree_list_model.get_item (0) as Gtk.TreeListRow;
            if (root_row != null) {
                root_row.set_expanded (true);
            }

            GLib.Idle.add (() => {
                refresh_list ();
                // 打开新目录后刷新 Git 状态
                git_commits.clear ();
                refresh_git_list ();
                btn_git_add_all_changed.sensitive = true;
                btn_git_export_working_diff.sensitive = true;
                git_search_entry.visible = true;
                if (is_git_mode) {
                    load_git_history_async ();
                }
                return Source.REMOVE;
            });
        } catch (Error e) {
            warning ("文件夹选择失败: %s", e.message);
        }
    }

    // 后台线程: 枚举单个目录的子条目 (纯文件系统 I/O, 不访问实例状态)
    private static Gee.ArrayList<DirChildInfo> enumerate_dir_children (string dir_path, GLib.Cancellable? cancellable = null) {
        var dirs = new Gee.ArrayList<DirChildInfo> ();
        var files = new Gee.ArrayList<DirChildInfo> ();
        var dir = File.new_for_path (dir_path);
        if (!dir.query_exists ()) return new Gee.ArrayList<DirChildInfo> ();
        try {
            var enumerator = dir.enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_IS_SYMLINK,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS
            );
            FileInfo info;
            while ((info = enumerator.next_file ()) != null) {
                if (cancellable != null && cancellable.is_cancelled ()) break;
                string entry_name = info.get_name ();
                if (entry_name == ".filecollector_cache") continue;
                if (info.get_is_symlink () && info.get_file_type () == FileType.DIRECTORY) {
                    continue;
                }
                var child_path = dir.get_child (entry_name).get_path ();
                bool is_dir = info.get_file_type () == FileType.DIRECTORY;
                var entry = new DirChildInfo (info.get_name (), child_path, is_dir);
                if (is_dir) {
                    dirs.add (entry);
                } else {
                    files.add (entry);
                }
            }
        } catch (Error e) {
            warning ("enumerate_dir_children: %s", e.message);
        }
        // 排序: 点文件优先, 然后大小写不敏感
        dirs.sort ((a, b) => {
            bool a_dot = a.name.has_prefix (".");
            bool b_dot = b.name.has_prefix (".");
            if (a_dot != b_dot) return a_dot ? -1 : 1;
            return a.name.casefold ().collate (b.name.casefold ());
        });
        files.sort ((a, b) => {
            bool a_dot = a.name.has_prefix (".");
            bool b_dot = b.name.has_prefix (".");
            if (a_dot != b_dot) return a_dot ? -1 : 1;
            return a.name.casefold ().collate (b.name.casefold ());
        });
        var result = new Gee.ArrayList<DirChildInfo> ();
        for (int i = 0; i < dirs.size; i++) result.add (dirs.get (i));
        for (int i = 0; i < files.size; i++) result.add (files.get (i));
        return result;
    }

    // 同步版本: 直接在调用线程加载子节点 (用于需要立即获取结果的场景, 如 ensure_path_loaded)
    private void load_directory_children_sync (DirectoryItem parent_item) {
        if (!parent_item.is_dir) return;
        var entries = enumerate_dir_children (parent_item.path);
        for (int i = 0; i < entries.size; i++) {
            var e = entries.get (i);
            parent_item.children.append (new DirectoryItem (e.name, e.path, e.is_dir));
        }
        refresh_subtree_states (parent_item);
        parent_item.children_loaded = true; // 强制标记已尝试加载, 防止 ensure_path_loaded 无限重试
    }

    // 异步版本: 后台线程枚举目录, 完成后通过 Idle 批量更新 UI, 避免阻塞主线程
    private void load_directory_children_lazy (DirectoryItem parent_item) {
        if (!parent_item.is_dir) return;
        if (parent_item.children_loading) return;
        if (window_closing) return;
        parent_item.children_loading = true;
        string dir_path = parent_item.path;
        var cancellable = app_cancellable;
        try {
            GLib.Thread<void*>? thread = null;
            thread = new Thread<void*> ("load-dir-children", () => {
                var entries = enumerate_dir_children (dir_path, cancellable);
                // 分批流式插入 (Idle 回调在主线程执行, 防止大项目卡死 UI)
                apply_directory_children_lazy (parent_item, entries, thread);
                return null;
            });
            bg_threads.add (thread);
        } catch (ThreadError e) {
            parent_item.children_loading = false;
            warning ("Failed to create load-dir-children thread: %s", e.message);
            load_directory_children_sync (parent_item);
        }
    }

    // 分批流式插入子节点 (每帧 100 个), 防止加载大项目时卡死 UI.
    // 在主线程通过 Idle 分批执行; 完成后刷新子树状态并清理后台线程引用.
    // 边界检查确保父容器没有在中途被销毁.
    private void apply_directory_children_lazy (DirectoryItem parent,
                                                 Gee.ArrayList<DirChildInfo> children,
                                                 GLib.Thread<void*>? thread = null) {
        int total_items = (int) children.size;
        int chunk_size = 100;
        int current_offset = 0;

        // 显示进度条
        if (total_items > chunk_size) {
            Idle.add (() => {
                dir_load_label.set_text (_("正在加载 %d 个项目...").printf (total_items));
                dir_load_progress.set_fraction (0);
                dir_load_revealer.reveal_child = true;
                return Source.REMOVE;
            });
        }

        GLib.Idle.add (() => {
            if (window_closing) {
                return GLib.Source.REMOVE;
            }
            if (parent == null || parent.children == null) {
                dir_load_revealer.reveal_child = false;
                return GLib.Source.REMOVE;
            }

            int limit = int.min (current_offset + chunk_size, total_items);
            for (int i = current_offset; i < limit; i++) {
                var child_info = children.get (i);
                var child_item = new DirectoryItem (child_info.name, child_info.path, child_info.is_dir);
                parent.children.append (child_item);
            }

            current_offset = limit;

            // 更新进度
            if (total_items > chunk_size) {
                double frac = (double) current_offset / total_items;
                dir_load_progress.set_fraction (frac);
                dir_load_label.set_text (_("已加载 %d / %d").printf (current_offset, total_items));
            }

            if (current_offset < total_items) {
                return GLib.Source.CONTINUE;
            }

            // 加载完毕: 隐藏进度条
            dir_load_revealer.reveal_child = false;
            parent.children_loading = false;
            parent.children_loaded = true;
            refresh_all_tree_states ();
            dir_column_view.queue_draw ();
            if (thread != null) bg_threads.remove (thread);
            return GLib.Source.REMOVE;
        });
    }

    // AI 工具入口: 设置某个文件路径的勾选状态
    private void set_tree_item_check (string abs_path, bool checked) {
        // 1. 更新 check_model (单一真相源)
        if (checked) {
            check_model.add_files ({ abs_path });
            if (!path_in_items (abs_path)) {
                var new_item = new ItemData ("file", abs_path, null, false);
                items.add (new_item);
                if (new_item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
                    vlm_queue.enqueue (new_item);
                }
            }
        } else {
            check_model.remove_files ({ abs_path });
            remove_items_by_path (abs_path);
        }

        // 2. 触发懒加载, 确保该路径的父目录已加载 (这样 UI 才能显示)
        ensure_path_loaded (abs_path);

        // 3. 刷新整个可见树的三态
        refresh_all_tree_states ();
        refresh_list ();
    }

    // 确保指定文件路径的所有父目录都已加载到树中
    private void ensure_path_loaded (string abs_path) {
        if (work_dir == null || !abs_path.has_prefix (work_dir.get_path () + "/")) return;
        if (root_store.get_n_items () == 0) return;
        ensure_path_token++;
        uint my_token = ensure_path_token;

        string rel = abs_path.substring (work_dir.get_path ().length + 1);
        string[] parts = rel.split ("/");
        var current = (DirectoryItem) root_store.get_item (0);

        for (int p = 0; p < parts.length - 1; p++) {
            bool found = false;
            for (uint c = 0; c < current.children.get_n_items (); c++) {
                var child = (DirectoryItem) current.children.get_item (c);
                if (child.name == parts[p]) {
                    current = child;
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (current.children_loaded) return;
                load_directory_children_lazy (current);
                schedule_ensure_path_retry (abs_path, my_token);
                return;
            }
        }

        bool target_found = false;
        for (uint c = 0; c < current.children.get_n_items (); c++) {
            var child = (DirectoryItem) current.children.get_item (c);
            if (child.path == abs_path) {
                target_found = true;
                break;
            }
        }
        if (!target_found) {
            if (current.children_loaded) return;
            load_directory_children_lazy (current);
        }
    }

    private void schedule_ensure_path_retry (string abs_path, uint token) {
        GLib.Timeout.add (50, () => {
            if (window_closing || token != ensure_path_token) {
                return Source.REMOVE;
            }
            ensure_path_loaded (abs_path);
            return Source.REMOVE;
        });
    }

    // ─── Queue List ──────────────────────────────────────────────────────

    private void refresh_list () {
        // 1. 记录当前选中的 ItemData 对象引用
        var selected_items = new Gee.ArrayList<ItemData> ();
        var bitset = queue_selection.get_selection ();
        for (uint i = 0; i < queue_store.get_n_items (); i++) {
            if (bitset.contains (i)) {
                selected_items.add ((ItemData) queue_store.get_item (i));
            }
        }

        uint n = queue_store.get_n_items ();
        int m = items.size;

        // 差分同步: 只替换发生变化的段, 避免全量重建
        // 2. 寻找第一个不一致的索引
        int first_diff = -1;
        int min_len = (int) uint.min (n, (uint) m);
        for (int i = 0; i < min_len; i++) {
            if (queue_store.get_item (i) != items.get (i)) {
                first_diff = i;
                break;
            }
        }

        // 3. 根据差异类型执行最小化 splice
        if (first_diff == -1) {
            if (n == m) {
                // 完全一致，无需任何操作
            } else if (n < m) {
                // 仅尾部追加
                GLib.Object[] adds = new GLib.Object[m - n];
                for (int i = (int)n; i < m; i++) adds[i - (int)n] = items.get (i);
                queue_store.splice (n, 0, adds);
            } else {
                // 仅尾部删除
                queue_store.splice (m, n - m, new GLib.Object[0]);
            }
        } else {
            // 4. 存在中间差异，寻找最后一个不一致的索引
            int last_diff_old = (int)n - 1;
            int last_diff_new = m - 1;
            while (last_diff_old >= first_diff && last_diff_new >= first_diff) {
                if (queue_store.get_item (last_diff_old) == items.get (last_diff_new)) {
                    last_diff_old--;
                    last_diff_new--;
                } else {
                    break;
                }
            }

            int replace_len_old = last_diff_old - first_diff + 1;
            int replace_len_new = last_diff_new - first_diff + 1;

            GLib.Object[] adds = new GLib.Object[replace_len_new];
            for (int i = 0; i < replace_len_new; i++) {
                adds[i] = items.get (first_diff + i);
            }
            // 仅替换发生变化的中间段
            queue_store.splice (first_diff, replace_len_old, adds);
        }

        // 5. 恢复选择状态 (基于对象引用)
        queue_selection.unselect_all ();
        bool any_selected = false;
        foreach (var sel_item in selected_items) {
            int idx = find_item_index (sel_item);
            if (idx >= 0) {
                queue_selection.select_item (idx, false);
                any_selected = true;
            }
        }
        if (!any_selected && items.size > 0) {
            queue_selection.select_item (0, false);
        }

        update_queue_buttons ();

        // 6. 更新预览面板
        var new_indices = get_selected_indices ();
        if (new_indices.size == 1) {
            int sel = new_indices.get (0);
            if (sel >= 0 && sel < items.size) {
                update_preview (items.get (sel));
            }
        } else if (new_indices.size > 1) {
            show_multi_selection_preview (new_indices.size);
        } else {
            clear_preview ();
        }
    }

    private Gee.ArrayList<int> get_selected_indices () {
        var indices = new Gee.ArrayList<int> ();
        var bitset = queue_selection.get_selection ();
        var iter = Gtk.BitsetIter ();
        uint value;
        if (iter.init_first (bitset, out value)) {
            indices.add ((int) value);
            while (iter.next (out value)) {
                indices.add ((int) value);
            }
        }
        return indices;
    }

    private void show_multi_selection_preview (int count) {
        Gtk.Widget? child = preview_container.get_first_child ();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling ();
            preview_container.remove (child);
            child = next;
        }
        var label = new Gtk.Label (_("已选择 %d 个项目").printf (count));
        label.add_css_class ("dim-label");
        label.valign = Gtk.Align.CENTER;
        label.halign = Gtk.Align.CENTER;
        label.vexpand = true;
        label.hexpand = true;
        preview_container.append (label);
    }

    private void clear_preview () {
        Gtk.Widget? child = preview_container.get_first_child ();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling ();
            preview_container.remove (child);
            child = next;
        }
    }

    private void update_queue_buttons () {
        var indices = get_selected_indices ();
        int count = indices.size;
        bool has_selection = count > 0;
        bool single = count == 1;
        bool has_items = items.size > 0;
        btn_add_text_above.sensitive = single;
        btn_add_text_below.sensitive = single;
        btn_move_up.sensitive = single && items.size > 1 && indices.get (0) > 0;
        btn_move_down.sensitive = single && items.size > 1 && indices.get (0) < items.size - 1;
        btn_delete.sensitive = has_selection;
        btn_clear.sensitive = has_items;
        btn_git_delete.sensitive = has_selection;
        btn_git_clear.sensitive = has_items;
    }

    private void on_add_external_files () {
        var dialog = new Gtk.FileDialog ();
        dialog.title = _("选择外部文件");
        dialog.open_multiple.begin (this, null, (obj, res) => {
            try {
                var files = dialog.open_multiple.end (res);
                if (files.get_n_items () == 0) return;
                int added = 0;
                int skipped = 0;
                var to_add = new Gee.ArrayList<ItemData> ();
                for (uint i = 0; i < files.get_n_items (); i++) {
                    var file = (File) files.get_item (i);
                    var path = file.get_path ();
                    bool exists = false;
                    for (int j = 0; j < items.size; j++) {
                        var existing = items.get (j);
                        if (existing.item_type == "file" && existing.file_path == path) {
                            exists = true;
                            break;
                        }
                    }
                    if (exists) {
                        skipped++;
                    } else {
                        to_add.add (new ItemData ("file", path, null, true));
                    }
                }
                if (to_add.size > 0) {
                    push_undo_state ();
                    foreach (var item in to_add) {
                        items.add (item);
                        if (item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
                            vlm_queue.enqueue (item);
                        }
                        added++;
                    }
                    refresh_list ();
                }
                if (added > 0 && skipped > 0) {
                    show_toast (_("已添加 %d 个文件，跳过 %d 个重复文件").printf (added, skipped));
                } else if (added > 0) {
                    show_toast (_("已添加 %d 个文件").printf (added));
                } else if (skipped > 0) {
                    show_toast (_("所选文件已全部存在，跳过 %d 个重复文件").printf (skipped));
                }
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED) return;
                warning ("添加文件失败: %s", e.message);
            }
        });
    }

    private void insert_text (bool above, string? existing_text = null, owned ItemData? edit_data = null) {
        var window = new Adw.Window ();
        window.set_transient_for (this);
        window.set_modal (true);
        window.set_default_size (450, 350);
        window.set_title (edit_data != null ? _("编辑文字") : _("插入自定义文字"));

        var toolbar_view = new Adw.ToolbarView ();
        window.set_content (toolbar_view);

        var header_bar = new Adw.HeaderBar ();
        header_bar.set_decoration_layout ("");
        toolbar_view.add_top_bar (header_bar);

        var cancel_btn = new Gtk.Button ();
        cancel_btn.set_label (_("取消"));
        header_bar.pack_start (cancel_btn);

        var ok_btn = new Gtk.Button ();
        ok_btn.set_label (_("确定"));
        ok_btn.add_css_class ("suggested-action");
        header_bar.pack_end (ok_btn);

        var btn_size_group = new Gtk.SizeGroup (Gtk.SizeGroupMode.HORIZONTAL);
        btn_size_group.add_widget (cancel_btn);
        btn_size_group.add_widget (ok_btn);

        var phrases_btn = new Gtk.Button ();
        phrases_btn.set_label (_("常用语"));
        header_bar.pack_end (phrases_btn);

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        content.set_margin_top (0);
        content.set_margin_start (12);
        content.set_margin_end (12);
        content.set_margin_bottom (12);

        var frame = new Gtk.Frame (null);
        frame.add_css_class ("text-input-frame");

        var scrolled = new Gtk.ScrolledWindow ();
        scrolled.set_vexpand (true);
        scrolled.set_min_content_height (120);

        var text_view = new Gtk.TextView ();
        text_view.set_wrap_mode (Gtk.WrapMode.WORD_CHAR);
        text_view.set_top_margin (12);
        text_view.set_bottom_margin (12);
        text_view.set_left_margin (12);
        text_view.set_right_margin (12);

        if (existing_text != null) {
            text_view.get_buffer ().set_text (existing_text, -1);
        }

        scrolled.set_child (text_view);
        frame.set_child (scrolled);
        content.append (frame);

        toolbar_view.set_content (content);

        cancel_btn.clicked.connect (() => {
            window.destroy ();
        });

        ok_btn.clicked.connect (() => {
            var buffer = text_view.get_buffer ();
            Gtk.TextIter start, end;
            buffer.get_start_iter (out start);
            buffer.get_end_iter (out end);
            var text = buffer.get_text (start, end, false);
            if (text != null && text.strip () != "") {
                if (edit_data != null) {
                    // Bug #12 修复: 编辑文本项时记录 undo delta
                    int edit_index = find_item_index (edit_data);
                    string old_content = edit_data.content;
                    edit_data.content = text;
                    if (edit_index >= 0) {
                        push_undo_delta (new UndoDelta.for_edit (edit_index, old_content, text));
                    }
                    refresh_list ();
                    update_preview (edit_data);
                } else {
                    do_insert_text (text, above);
                }
            }
            window.destroy ();
        });

        if (edit_data != null) {
            phrases_btn.visible = false;
        } else {
            phrases_btn.clicked.connect (() => {
                window.destroy ();
                get_phrases_picker ().show_picker (above);
            });
        }

        window.present ();
    }

    private void do_insert_text (string text, bool above) {
        var indices = get_selected_indices ();
        int current = indices.size == 1 ? indices.get (0) : -1;
        int index;
        if (current < 0) {
            index = above ? 0 : (int) items.size;
        } else {
            index = above ? current : current + 1;
        }
        var inserted = new Gee.ArrayList<ItemData> ();
        var item = new ItemData ("text", null, text, false);
        items.insert (index, item);
        inserted.add (item);
        push_undo_delta (new UndoDelta.for_insert (index, inserted));
        refresh_list ();
    }

    private void on_move_up () {
        var indices = get_selected_indices ();
        if (indices.size != 1) return;
        int index = indices.get (0);
        if (index <= 0) return;
        var tmp = items.get (index);
        items.set (index, items.get (index - 1));
        items.set (index - 1, tmp);
        push_undo_delta (new UndoDelta.for_swap (index - 1, index));
        refresh_list ();
        select_queue_row (index - 1);
    }

    private void on_move_down () {
        var indices = get_selected_indices ();
        if (indices.size != 1) return;
        int index = indices.get (0);
        if (index >= items.size - 1) return;
        var tmp = items.get (index);
        items.set (index, items.get (index + 1));
        items.set (index + 1, tmp);
        push_undo_delta (new UndoDelta.for_swap (index, index + 1));
        refresh_list ();
        select_queue_row (index + 1);
    }

    private void on_delete_item () {
        var indices = get_selected_indices ();
        if (indices.size == 0) return;

        push_undo_state ();

        indices.sort ((a, b) => b - a);

        var paths_to_uncheck = new Gee.ArrayList<string> ();
        foreach (int idx in indices) {
            if (idx < 0 || idx >= items.size) continue;
            var data = items.get (idx);
            if (data.item_type == "file" && !data.force_absolute && data.file_path != null) {
                if (data.file_path in check_model.checked_files) {
                    paths_to_uncheck.add (data.file_path);
                }
            }
        }

        if (paths_to_uncheck.size > 0) {
            check_model.remove_files ((string[]) paths_to_uncheck.to_array ());
        }

        foreach (int idx in indices) {
            if (idx >= 0 && idx < items.size) {
                items.remove_at (idx);
            }
        }

        refresh_all_tree_states ();
        refresh_list ();
    }

    private void on_clear_items () {
        if (items.size == 0) return;
        push_undo_state ();
        items.clear ();
        check_model.clear ();
        refresh_all_tree_states ();
        refresh_list ();
    }

    private void on_clear_items_with_confirm () {
        if (items.size == 0) return;

        var dialog = new Adw.AlertDialog (
            _("确认清空"),
            _("确定要清空编排列表中的所有 %d 个项目吗？").printf (items.size)
        );
        dialog.add_response ("cancel", _("取消"));
        dialog.add_response ("clear", _("清空"));
        dialog.set_response_appearance ("clear", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_default_response ("cancel");

        dialog.response.connect ((response) => {
            if (response == "clear") {
                on_clear_items ();
            }
            dialog.destroy ();
        });

        dialog.present (this);
    }

    private void select_queue_row (int index) {
        if (index >= 0 && index < items.size) {
            queue_selection.unselect_all ();
            queue_selection.select_item (index, false);
        }
    }

    private void on_queue_selection_changed (uint position, uint n_items) {
        update_queue_buttons ();
        var indices = get_selected_indices ();
        if (indices.size == 1) {
            int sel = indices.get (0);
            if (sel >= 0 && sel < items.size) {
                update_preview (items.get (sel));
            }
            clear_tree_selection ();
        } else if (indices.size > 1) {
            show_multi_selection_preview (indices.size);
            clear_tree_selection ();
        } else {
            clear_preview ();
        }
    }

    private void on_queue_row_activated (uint position) {
        int index = (int)position;
        if (index < 0 || index >= items.size) return;
        var data = items.get (index);
        if (data.item_type == "text") {
            insert_text (false, data.content, data);
        }
    }

    private void update_preview (ItemData item) {
        bool show_action_bar = false;

        if (item.item_type == "file" && item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
            btn_retry_preprocess.sensitive = true;
            switch (item.preprocess_status) {
                case PreprocessStatus.COMPLETED:
                    show_action_bar = true;
                    btn_retry_preprocess.tooltip_text = item.from_cache
                        ? _("已读取本地缓存\n点击强制重新调用视觉语言大模型 (VLM) 转换")
                        : _("AI 转换完成\n点击强制重新调用视觉语言大模型 (VLM) 转换");
                    break;
                case PreprocessStatus.FAILED:
                    show_action_bar = true;
                    btn_retry_preprocess.tooltip_text = _("AI 转换失败\n点击重试转换");
                    break;
                case PreprocessStatus.PROCESSING:
                    // 正在转换中, 隐藏按钮而不是置灰, 避免给用户"可点"错觉
                    btn_retry_preprocess.tooltip_text = _("正在处理中...");
                    btn_retry_preprocess.sensitive = false;
                    break;
                default:
                    btn_retry_preprocess.tooltip_text = _("等待处理");
                    btn_retry_preprocess.sensitive = false;
                    break;
            }
        }

        btn_retry_preprocess.visible = show_action_bar;

        if (item.item_type == "text") {
            apply_preview_content (item, item.content.make_valid ());
        } else if (item.item_type == "file" && item.preprocess_status == PreprocessStatus.COMPLETED && item.preprocessed_content != null) {
            apply_preview_content (item, item.preprocessed_content.strip ());
        } else if (item.item_type == "file" && item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
            // 二进制文件未完成转换时, 根据预处理状态显示对应提示
            switch (item.preprocess_status) {
                case PreprocessStatus.PROCESSING:
                    apply_preview_content (item, _("[正在处理中，请稍候...]"));
                    break;
                case PreprocessStatus.FAILED:
                    apply_preview_content (item, _("[AI 转换失败，点击工具栏的重试按钮可重新转换]"));
                    break;
                case PreprocessStatus.CHECKING:
                    apply_preview_content (item, _("[正在检查缓存...]"));
                    break;
                case PreprocessStatus.PENDING:
                    apply_preview_content (item, _("[正在准备 AI 转换...]"));
                    break;
                default: // NONE
                    apply_preview_content (item, _(_("[二进制文件，预览不可用]")));
                    break;
            }
        } else {
            try {
                var file = File.new_for_path (item.file_path);
                int64 file_size = 0;
                try {
                    var info = file.query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                        file_size = info.get_size ();
                    } catch (Error e) {
                        apply_preview_content (item, _("[读取错误: ") + e.message + "]");
                        return;
                    }
                const int64 PREVIEW_MAX_BYTES = 8192;
                int64 read_size = int64.min (file_size, PREVIEW_MAX_BYTES);
                FileInputStream? fis = null;
                try {
                    fis = file.read ();
                    uint8[] buf = new uint8[read_size];
                    size_t bytes_read = 0;
                    while (bytes_read < (size_t) read_size) {
                        size_t chunk = size_t.min (4096, (size_t) read_size - bytes_read);
                        ssize_t n = fis.read (buf[bytes_read:bytes_read + chunk]);
                        if (n <= 0) break;
                        bytes_read += (size_t) n;
                    }
                    buf.resize ((int) bytes_read);
                    bool is_binary = false;
                    for (size_t i = 0; i < bytes_read; i++) {
                        if (buf[i] == 0) { is_binary = true; break; }
                    }
                    string preview;
                    if (is_binary) {
                        preview = _("[二进制文件，预览不可用]");
                    } else {
                        preview = EncodingHelper.decode_to_utf8 (buf);
                        if (preview.length > 2000) {
                            preview = truncate_utf8 (preview, 2000);
                            if (file_size > PREVIEW_MAX_BYTES) {
                                preview += _("\n\n... [预览截断，文件总大小: %s]").printf (format_preview_size (file_size));
                            } else {
                                preview += _("\n\n... [预览截断]");
                            }
                        } else if (file_size > PREVIEW_MAX_BYTES) {
                            preview += _("\n\n... [文件较大 (%s)，预览仅显示前 %s]").printf (
                                format_preview_size (file_size), format_preview_size (read_size));
                        }
                    }
                    apply_preview_content (item, preview);
                } finally {
                    if (fis != null) {
                        try { fis.close (); } catch (Error e) { debug ("Close failed: %s", e.message); }
                    }
                }
            } catch (Error e) {
                apply_preview_content (item, _("[读取错误: ") + e.message + "]");
            }
        }
    }

    // 根据文件扩展名判断是否按 Markdown 渲染 (.md / .markdown),
    // 复用 AI 侧边栏的 MarkdownView (基于 cmark-gfm) 支持标题/列表/代码块/表格等.
    private static bool is_markdown_path (string? path) {
        if (path == null) return false;
        string lower = path.down ();
        return lower.has_suffix (".md") || lower.has_suffix (".markdown");
    }

    // 切换 preview_container 内容: Markdown 文件或已被多模态 AI 预解析的
    // 二进制文件用 MarkdownView 渲染 (基于 cmark-gfm, 支持标题/列表/代码块/表格等),
    // 其余文件继续用 TextView 显示纯文本.
    private void apply_preview_content (ItemData item, string text) {
        bool use_markdown = item.item_type == "file"
            && (is_markdown_path (item.file_path)
                || (item.preprocess_status == PreprocessStatus.COMPLETED && item.preprocessed_content != null));

        Gtk.Widget? child = preview_container.get_first_child ();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling ();
            preview_container.remove (child);
            child = next;
        }

        if (use_markdown) {
            preview_container.append (new MarkdownView (text));
        } else {
            apply_preview_with_highlight (text, item.file_path);
        }
    }

    private void on_retry_preprocess (ItemData item) {
        if (item == null || item.item_type != "file" || !item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) return;
        if (item.preprocess_status == PreprocessStatus.PROCESSING) return;

        if (work_dir != null) {
            var cache = new PreprocessCache (work_dir.get_path ());
            cache.invalidate_cache (item.file_path);
        }

        item.preprocessed_content = null;
        item.from_cache = false;
        item.preprocess_status = PreprocessStatus.PENDING;

        refresh_list ();
        update_preview (item);
        vlm_queue.enqueue (item);
    }

    public void on_clear_cache () {
        if (work_dir == null) {
            show_toast (_("尚未设置工作目录"));
            return;
        }

        var dialog = new Adw.AlertDialog (
            _("确认清除缓存？"),
            _("这将删除当前工作目录下的 .filecollector_cache 隐藏文件夹。\n下次处理图片及 PDF 等文件时，将重新调用 VLM 并消耗 API Token。")
        );
        dialog.add_response ("cancel", _("取消"));
        dialog.add_response ("clear", _("清除"));
        dialog.set_response_appearance ("clear", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_default_response ("cancel");

        dialog.response.connect ((resp) => {
            if (resp == "clear") {
                var cache = new PreprocessCache (work_dir.get_path ());
                cache.clear_all ();

                for (int i = 0; i < items.size; i++) {
                    var item = items.get (i);
                    if (item.item_type == "file" && item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
                        item.preprocess_status = PreprocessStatus.NONE;
                        item.preprocessed_content = null;
                        item.from_cache = false;
                    }
                }

                refresh_list ();
                var indices = get_selected_indices ();
                if (indices.size == 1) {
                    int sel = indices.get (0);
                    if (sel >= 0 && sel < items.size) {
                        update_preview (items.get (sel));
                    }
                }

                show_toast (_("工作区缓存已清除"));
            }
        });
        dialog.present (this);
    }

    // ─── 编排列表右键菜单 ───────────────────────────────────────────────────

    private void show_queue_context_menu (Gtk.Widget parent, ItemData item, int index, int gx, int gy) {
        var indices = get_selected_indices ();
        ContextMenus.show_queue_menu (
            parent, item, index, gx, gy,
            indices, items, work_dir, use_absolute,
            () => { insert_text (false, item.content, item); },
            () => { insert_text (true); },
            () => { insert_text (false); },
            () => { on_move_up (); },
            () => { on_move_down (); },
            () => { on_delete_item (); },
            () => { refresh_list (); },
            () => { push_undo_state (); },
            (it) => { on_retry_preprocess (it); },
            () => {
                string path_to_copy = item.file_path;
                if (!item.force_absolute && work_dir != null && !use_absolute) {
                    string wd = work_dir.get_path () + "/";
                    if (path_to_copy.has_prefix (wd)) {
                        path_to_copy = path_to_copy.substring (wd.length);
                    }
                }
                get_clipboard ().set_text (path_to_copy);
                show_toast (_("路径已复制到剪贴板"));
            },
            () => { show_file_in_folder (item.file_path); }
        );
    }

    // ─── 目录树右键菜单 ─────────────────────────────────────────────────────

    private void show_tree_context_menu (Gtk.Widget parent, DirectoryItem item, int gx, int gy) {
        ContextMenus.show_tree_menu (
            parent, item, gx, gy, work_dir,
            () => {
                string path_to_copy = item.path;
                if (work_dir != null) {
                    string wd = work_dir.get_path () + "/";
                    if (path_to_copy.has_prefix (wd)) {
                        path_to_copy = path_to_copy.substring (wd.length);
                    }
                }
                get_clipboard ().set_text (path_to_copy);
                show_toast (_("路径已复制到剪贴板"));
            },
            () => {
                string target_path = item.is_dir ? item.path : GLib.Path.get_dirname (item.path);
                show_file_in_folder (target_path);
            },
            () => {
                try {
                    uint8[] data;
                    FileUtils.get_data (item.path, out data);
                    if (data.length > 1048576) {
                        show_toast (_("文件过大，无法复制内容"));
                        return;
                    }
                    string content = EncodingHelper.decode_to_utf8 (data);
                    get_clipboard ().set_text (content);
                    show_toast (_("文件内容已复制"));
                } catch (Error e) {
                    show_toast (_("读取文件失败"));
                }
            }
        );
    }

    // ─── 系统级辅助方法 ─────────────────────────────────────────────────────

    private void show_file_in_folder (string path) {
        UIHelpers.show_file_in_folder (this, path);
    }

    private static string format_preview_size (int64 size) {
        return UIHelpers.format_size (size);
    }

    private static string truncate_utf8 (string text, int max_bytes) {
        return UIHelpers.truncate_utf8 (text, max_bytes);
    }

    // ─── Options ─────────────────────────────────────────────────────────

    private void on_path_mode_changed () {
        bool old_abs = use_absolute;
        bool old_hdr = show_header;
        use_absolute = radio_absolute_path.active;
        push_undo_delta (new UndoDelta.for_absolute (old_abs, use_absolute, old_hdr, show_header));
        refresh_list ();
    }

    private void on_header_check_changed () {
        bool old_val = show_header;
        show_header = check_write_header.active;
        push_undo_delta (new UndoDelta.for_header (old_val, show_header));
    }

    // ─── Generate ────────────────────────────────────────────────────────

    private void on_generate_clicked () {
        if (items.size == 0) {
            show_toast (_("编排列表为空，请先勾选文件或添加文字内容"));
            return;
        }

        var dialog = new Gtk.FileDialog ();
        dialog.title = _("保存合并文本");
        var filter = new Gtk.FileFilter ();
        filter.name = _("文本文件 (*.txt)");
        filter.add_pattern ("*.txt");
        var filters_list = new GLib.ListStore (typeof (Gtk.FileFilter));
        filters_list.append (filter);
        dialog.set_filters (filters_list);

        dialog.save.begin (this, null, (obj, res) => {
            try {
                var file = dialog.save.end (res);
                var path = file.get_path ();
                if (!path.has_suffix (".txt")) {
                    path += ".txt";
                }
                FileGenerator.generate_file (path, items, use_absolute, show_header, work_dir);
                show_toast (_("合并文本已保存"));
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED || e is Gtk.DialogError.DISMISSED) {
                    show_toast (_("保存已取消"));
                    return;
                }
                show_error (_("保存失败"), e.message);
            }
        });
    }

    private void on_generate_to_clipboard_clicked () {
        if (items.size == 0) {
            show_toast (_("编排列表为空，请先勾选文件或添加文字内容"));
            return;
        }

        try {
            FileGenerator.generate_to_clipboard (items, use_absolute, show_header, work_dir, this.get_display ());
            show_toast (_("合并文本已复制到剪贴板"));
        } catch (Error e) {
            show_error (_("复制失败"), e.message);
        }
    }

    // ─── AI 阅读指南生成 ─────────────────────────────────────────────────

    private void on_ai_toc_clicked () {
        if (items.size == 0) {
            show_toast (_("编排列表为空，请先添加文件"));
            return;
        }

        var s = ConfigManager.load_ai_settings ();
        if (!s.enabled || s.base_url == "" || s.api_key == "" || s.model == "") {
            show_toast (_("请先在 AI 设置中配置 API"));
            return;
        }

        btn_ai_toc.sensitive = false;
        btn_generate.sensitive = false;
        btn_generate_clipboard.sensitive = false;
        show_toast (_("正在让 AI 生成阅读指南..."));

        var client = new AIClient (s.base_url, s.api_key, s.model, s.timeout);
        string context = build_toc_prompt_context ();
        string prompt = build_toc_prompt (context);

        var msgs = new Gee.ArrayList<Json.Node> ();
        var o = new Json.Object ();
        o.set_string_member ("role", "user");
        o.set_string_member ("content", prompt);
        var node = new Json.Node (Json.NodeType.OBJECT);
        node.set_object (o);
        msgs.add (node);

        try {
            new GLib.Thread<void*> ("toc-gen", () => {
                string toc_result = "";
                try {
                    var result = client.chat (msgs, null, null);
                    toc_result = clean_ai_markdown (result.content);
                } catch (Error e) {
                    warning ("TOC Gen failed: %s", e.message);
                }

                Idle.add (() => {
                    btn_ai_toc.sensitive = true;
                    btn_generate.sensitive = true;
                    btn_generate_clipboard.sensitive = true;

                    if (toc_result.length == 0) {
                        show_toast (_("AI 生成阅读指南失败"));
                    } else {
                        push_undo_state ();
                        items.insert (0, new ItemData ("text", null, toc_result, false));
                        refresh_list ();
                        show_toast (_("AI 阅读指南已插入编排列表顶部"));
                    }
                    return Source.REMOVE;
                });
                return null;
            });
        } catch (ThreadError e) {
            btn_ai_toc.sensitive = true;
            btn_generate.sensitive = true;
            btn_generate_clipboard.sensitive = true;
            show_toast (_("无法启动 AI 生成线程"));
        }
    }

    private string build_toc_prompt_context () {
        return UIHelpers.build_toc_prompt_context (items, work_dir);
    }

    private string build_toc_prompt (string context) {
        return UIHelpers.build_toc_prompt (context);
    }

    private string clean_ai_markdown (string raw) {
        return UIHelpers.clean_ai_markdown (raw);
    }

    // ─── Project ─────────────────────────────────────────────────────────

    public void on_open_project () {
        var dialog = new Gtk.FileDialog ();
        dialog.title = _("打开项目");
        var filter = new Gtk.FileFilter ();
        filter.name = _("项目文件 (*.fcol, *.fcol.json, *.project.json)");
        filter.add_pattern ("*.fcol");
        filter.add_pattern ("*.fcol.json");
        filter.add_pattern ("*.project.json");
        var filters_list = new GLib.ListStore (typeof (Gtk.FileFilter));
        filters_list.append (filter);
        dialog.set_filters (filters_list);

        dialog.open.begin (this, null, (obj, res) => {
            try {
                var file = dialog.open.end (res);
                project_controller.load (file.get_path ());
                undo_manager.clear ();
                update_ui_after_project_load ();
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED) return;
                show_error (_("打开失败"), e.message);
            }
        });
    }

    private void update_ui_after_project_load () {
        if (work_dir != null) {
            update_subtitle (work_dir.get_path ());
            root_store.remove_all ();
            var root_item = new DirectoryItem (work_dir.get_basename (), work_dir.get_path (), true);
            root_store.append (root_item);

            // 【核心修复】清理 checked_dirs 中的过时条目
            // checked_paths 在加载时按文件系统存在性过滤, 但 checked_dirs 未过滤
            // 若文件在保存后被删除, 其所在目录仍留在 checked_dirs 中, 但实际已非全选
            // 遍历 items, 找出不在 checked_files 中的文件 (缺失文件), 移除其祖先目录的 checked_dirs 标记
            foreach (var item in items) {
                if (item.item_type == "file" && !(item.file_path in check_model.checked_files)) {
                    check_model.remove_ancestors_from_checked_dirs (item.file_path);
                }
            }

            // 确保所有已勾选文件的祖先目录被标记或预加载
            // 防止深层目录因未展开导致 implicit_checked_dirs 断层或统计遗漏
            foreach (var path in check_model.checked_files) {
                ensure_path_loaded (path);
            }

            load_directory_children_lazy (root_item);
            search_entry.visible = true;
            var root_row = tree_list_model.get_item (0) as Gtk.TreeListRow;
            if (root_row != null) root_row.set_expanded (true);
        } else {
            update_subtitle (null);
        }
        update_undo_redo_buttons ();
        refresh_list ();
    }

    public void on_save_project () {
        try {
            if (project_controller.save_current ()) {
                show_toast (_("项目文件已更新"));
            } else {
                on_save_project_as ();
            }
        } catch (Error e) {
            show_error (_("保存失败"), e.message);
        }
    }

    public void on_save_project_as () {
        var dialog = new Gtk.FileDialog ();
        dialog.title = _("保存项目");
        var filter = new Gtk.FileFilter ();
        filter.name = _("项目文件 (*.fcol)");
        filter.add_pattern ("*.fcol");
        var filters_list = new GLib.ListStore (typeof (Gtk.FileFilter));
        filters_list.append (filter);
        dialog.set_filters (filters_list);

        dialog.save.begin (this, null, (obj, res) => {
            try {
                var file = dialog.save.end (res);
                var path = file.get_path ();
                if (!path.has_suffix (".fcol")) {
                    path += ".fcol";
                }
                project_controller.save (path);
                show_toast (_("项目文件已保存"));
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED) return;
                show_error (_("保存失败"), e.message);
            }
        });
    }

    // ─── Subtitle ────────────────────────────────────────────────────────

    private void cache_title_widget () {
        if (_title_widget == null) {
            var header = get_titlebar () as Adw.HeaderBar;
            if (header != null && header.title_widget is Adw.WindowTitle) {
                _title_widget = (Adw.WindowTitle) header.title_widget;
            } else {
                _title_widget = find_window_title (this);
            }
        }
    }

    private void update_subtitle (string? text) {
        string subtitle = text ?? _("未设置工作目录");

        title = (text != null) ? text : _("FileCollector");

        if (_title_widget == null) {
            cache_title_widget ();
        }
        if (_title_widget != null) {
            _title_widget.set_subtitle (subtitle);
        }
    }

    private Adw.WindowTitle? find_window_title (Gtk.Widget root) {
        if (root is Adw.WindowTitle) {
            return (Adw.WindowTitle) root;
        }

        var child = root.get_first_child ();
        while (child != null) {
            var found = find_window_title (child);
            if (found != null) {
                return found;
            }
            child = child.get_next_sibling ();
        }
        return null;
    }

    // ─── Dialogs ─────────────────────────────────────────────────────────

    public void on_about () {
        var about = new Adw.AboutDialog ();
        about.application_name = _("FileCollector");
        about.version = Config.VERSION;
        about.application_icon = "com.github.samfic.filecollector";
        about.comments = _("文件收集与编排工具");
        about.developers = { "Sam-Fic" };
        about.website = "https://github.com/Sam-Fic/filecollector-gnome";
        about.license_type = Gtk.License.MIT_X11;

        about.present (this);
    }

    public void on_show_shortcuts () {
        try {
            var builder = new Gtk.Builder ();
            builder.set_translation_domain (Config.GETTEXT_PACKAGE);
            builder.add_from_string (build_shortcuts_ui (), -1);
            var win = builder.get_object ("sw") as Gtk.ShortcutsWindow;
            if (win == null) return;
            win.set_transient_for (this);
            win.present ();
        } catch (Error e) {
            warning ("Failed to show shortcuts: %s", e.message);
        }
    }

    private string build_shortcuts_ui () {
        _("常用操作");
        _("列表操作");
        _("应用程序");
        _("清空列表");
        _("生成到剪贴板");
        _("打开项目");
        _("切换 AI 面板");
        _("关于");
        _("退出");
        return """<?xml version="1.0" encoding="UTF-8"?>
<interface>
  <object class="GtkShortcutsWindow" id="sw">
    <property name="modal">true</property>
    <property name="title" translatable="yes">键盘快捷键</property>
    <child>
      <object class="GtkShortcutsSection">
        <child>
          <object class="GtkShortcutsGroup">
            <property name="title" translatable="yes">常用操作</property>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">撤销</property>
                <property name="accelerator">&lt;Control&gt;z</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">重做</property>
                <property name="accelerator">&lt;Control&gt;&lt;Shift&gt;z</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">打开项目</property>
                <property name="accelerator">&lt;Control&gt;o</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">保存项目</property>
                <property name="accelerator">&lt;Control&gt;s</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">清空列表</property>
                <property name="accelerator">&lt;Control&gt;n</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">添加外部文件</property>
                <property name="accelerator">&lt;Control&gt;e</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">切换 AI 面板</property>
                <property name="accelerator">&lt;Control&gt;j</property>
              </object>
            </child>
          </object>
        </child>
        <child>
          <object class="GtkShortcutsGroup">
            <property name="title" translatable="yes">列表操作</property>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">上方插入文本</property>
                <property name="accelerator">&lt;Control&gt;i</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">下方插入文本</property>
                <property name="accelerator">&lt;Control&gt;&lt;Shift&gt;i</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">上移</property>
                <property name="accelerator">&lt;Control&gt;Up</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">下移</property>
                <property name="accelerator">&lt;Control&gt;Down</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">删除</property>
                <property name="accelerator">Delete</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">生成合并文本</property>
                <property name="accelerator">&lt;Control&gt;g</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">生成到剪贴板</property>
                <property name="accelerator">&lt;Control&gt;&lt;Shift&gt;c</property>
              </object>
            </child>
          </object>
        </child>
        <child>
          <object class="GtkShortcutsGroup">
            <property name="title" translatable="yes">应用程序</property>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">语言设置</property>
                <property name="accelerator">&lt;Control&gt;comma</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">键盘快捷键</property>
                <property name="accelerator">&lt;Control&gt;slash</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">关于</property>
                <property name="accelerator">F1</property>
              </object>
            </child>
            <child>
              <object class="GtkShortcutsShortcut">
                <property name="title" translatable="yes">退出</property>
                <property name="accelerator">&lt;Control&gt;q</property>
              </object>
            </child>
          </object>
        </child>
      </object>
    </child>
  </object>
</interface>""";
    }

    public void on_settings () {
        var settings_dialog = new SettingsDialog (this);
        settings_dialog.restart_requested.connect (() => {
            try {
                string exec_path = FileUtils.read_link ("/proc/self/exe");
                var app = (FileCollectorApp) this.application;
                app.quit ();
                Process.spawn_async (
                    null,
                    {exec_path},
                    null,
                    0,
                    null,
                    null
                );
            } catch (Error e) {
                warning ("Failed to restart: %s", e.message);
            }
        });
        settings_dialog.present ();
    }

    public void on_manage_phrases () {
        get_phrases_picker ().show_manage_window ();
    }

    private TemplatesManager? templates_manager_instance = null;

    public void on_manage_templates () {
        if (templates_manager_instance == null) {
            templates_manager_instance = new TemplatesManager (this);
        }
        templates_manager_instance.present ();
    }

    private void show_warning (string title, string msg) {
        var d = new Adw.AlertDialog (title, msg);
        d.add_response ("ok", _("确定"));
        d.present (this);
    }

    private void show_error (string title, string msg) {
        var d = new Adw.AlertDialog (title, msg);
        d.add_response ("ok", _("确定"));
        d.present (this);
    }

    private void show_toast (string title) {
        var toast = new Adw.Toast (title);
        toast.timeout = 2;
        toast_overlay.add_toast (toast);
    }

    private void show_edit_phrase_dialog (string old_text, int index) {
        var picker = get_phrases_picker ();
        var dialog = new Adw.Dialog ();
        dialog.set_title (_("编辑常用语"));
        dialog.set_content_width (450);
        dialog.set_content_height (350);

        var toolbar_view = new Adw.ToolbarView ();
        dialog.set_child (toolbar_view);

        var header_bar = new Adw.HeaderBar ();
        header_bar.set_title_widget (new Adw.WindowTitle (_("编辑常用语"), ""));
        header_bar.set_show_end_title_buttons (false);
        toolbar_view.add_top_bar (header_bar);

        var cancel_btn = new Gtk.Button ();
        cancel_btn.set_label (_("取消"));
        header_bar.pack_start (cancel_btn);

        var ok_btn = new Gtk.Button ();
        ok_btn.set_label (_("确定"));
        ok_btn.add_css_class ("suggested-action");
        header_bar.pack_end (ok_btn);

        var btn_size_group = new Gtk.SizeGroup (Gtk.SizeGroupMode.HORIZONTAL);
        btn_size_group.add_widget (cancel_btn);
        btn_size_group.add_widget (ok_btn);

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        content.set_margin_top (0);
        content.set_margin_start (12);
        content.set_margin_end (12);
        content.set_margin_bottom (12);

        var frame = new Gtk.Frame (null);
        frame.add_css_class ("text-input-frame");

        var scrolled = new Gtk.ScrolledWindow ();
        scrolled.set_vexpand (true);
        scrolled.set_min_content_height (120);

        var text_view = new Gtk.TextView ();
        text_view.set_wrap_mode (Gtk.WrapMode.WORD_CHAR);
        text_view.set_top_margin (12);
        text_view.set_bottom_margin (12);
        text_view.set_left_margin (12);
        text_view.set_right_margin (12);
        text_view.get_buffer ().set_text (old_text, -1);

        scrolled.set_child (text_view);
        frame.set_child (scrolled);
        content.append (frame);

        toolbar_view.set_content (content);

        cancel_btn.clicked.connect (() => {
            dialog.close ();
        });

        ok_btn.clicked.connect (() => {
            var buffer = text_view.get_buffer ();
            Gtk.TextIter start, end;
            buffer.get_start_iter (out start);
            buffer.get_end_iter (out end);
            var text = buffer.get_text (start, end, false);
            if (text != null && text.strip () != "") {
                picker.update_phrase (index, text);
            }
            dialog.close ();
        });

        dialog.present (this);
    }

    private PhrasesPicker get_phrases_picker () {
        if (phrases_picker_instance == null) {
            phrases_picker_instance = new PhrasesPicker (this, common_phrases);
            phrases_picker_instance.phrase_selected.connect ((phrase, above) => {
                do_insert_text (phrase, above);
            });
            phrases_picker_instance.edit_phrase_requested.connect ((old_text, index) => {
                show_edit_phrase_dialog (old_text, index);
            });
        }
        return phrases_picker_instance;
    }

    // ─── 多模态 AI 预处理 ────────────────────────────────────────────────

    private string get_prompt_for_item (ItemData item) {
        if (item.is_image_target ()) {
            string lower = item.file_path.down ();
            if (lower.contains ("screenshot") || lower.contains ("error") || lower.contains ("bug")) {
                return "这是一张系统截图。请提取图中所有可见文本内容（包括错误信息、堆栈跟踪、UI 元素）。" +
                       "保留原始格式，使用代码块包裹命令行输出或报错信息。";
            }
            if (lower.contains ("diagram") || lower.contains ("flow") || lower.contains ("arch")) {
                return "这是一张技术图表。请描述图表的结构和逻辑关系。" +
                       "如果可能，使用 Mermaid 语法重构此图表。";
            }
            return "请提取图片中的所有文本内容，并将其转换为结构清晰的 Markdown。" +
                   "保留标题层级、列表结构和表格。";
        }
        if (item.is_document_target ()) {
            string lower = item.file_path.down ();
            if (lower.has_suffix (".xlsx") || lower.has_suffix (".xls") || lower.has_suffix (".ods")) {
                return "请将图片中的电子表格数据转换为标准 Markdown 表格。" +
                       "保留表头结构、合并单元格的语义以及数值精度。";
            }
            if (lower.has_suffix (".pptx") || lower.has_suffix (".ppt") || lower.has_suffix (".odp")) {
                return "这是演示文稿的页面截图。请将每页内容提取为 Markdown，" +
                       "使用二级标题 (##) 分隔每页幻灯片，保留要点列表。";
            }
        }
        return "请将图片中的内容转换为结构清晰的 Markdown 格式。保留标题、列表和表格。";
    }

    // ─── AI 助手集成 ───────────────────────────────────────────────────

    private void setup_ai_panel () {
        ai_sidebar.visible = false;
        ai_panel_visible = false;
        // AI 边栏不可被压缩, 与其他三栏保持一致, 防止内容被裁剪
        ai_paned.set_shrink_start_child (false);
        ai_paned.set_shrink_end_child (false);
        btn_ai_toggle.clicked.connect (toggle_ai_panel);
        ai_paned.notify["position"].connect (clamp_ai_paned_position);

        // ai_paned 的 separator 宽度为 0 (CSS), GTK 默认抓取区域会溢出到 end_child,
        // 而 end_child (outer_paned) 不显示 col-resize 光标, 导致只有左半区域有光标.
        // 用 EventControllerMotion 检测鼠标在 separator 附近时设置光标.
        col_resize_cursor = new Gdk.Cursor.from_name ("col-resize", null);
        var motion = new Gtk.EventControllerMotion ();
        motion.motion.connect ((x, y) => {
            // AI 边栏隐藏时不处理
            if (!ai_sidebar.visible) return;
            int pos = (int) ai_paned.position;
            // 鼠标在 separator 附近 ±6px 范围内
            if ((x >= pos - 6) && (x <= pos + 6)) {
                ai_paned.set_cursor (col_resize_cursor);
            } else {
                ai_paned.set_cursor (null);
            }
        });
        motion.leave.connect (() => {
            ai_paned.set_cursor (null);
        });
        ai_paned.add_controller (motion);
    }

    private void clamp_ai_paned_position () {
        // 防止 AI 边栏被用户拖到太大 / 太小
        var pw = ai_paned.get_width ();
        if (pw <= 0) return;
        var pos = (int) ai_paned.position;
        if (pos < 260) {
            ai_paned.position = 260;
        } else if (pos > 480) {
            ai_paned.position = 480;
        }
    }

    // ─── 全局内容搜索 ────────────────────────────────────────────────────

    private void on_global_search () {
        if (work_dir == null) {
            show_toast (_("请先设置工作目录"));
            return;
        }
        var dialog = new GlobalSearchDialog (this, work_dir.get_path ());
        dialog.add_files_requested.connect ((paths) => {
            push_undo_state ();
            int added = 0;
            foreach (var p in paths) {
                if (!path_in_items (p)) {
                    var new_item = new ItemData ("file", p, null, false);
                    items.add (new_item);
                    if (new_item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
                        vlm_queue.enqueue (new_item);
                    }
                    if (!(p in check_model.checked_files)) {
                        check_model.add_files ({ p });
                    }
                    added++;
                }
            }
            refresh_all_tree_states ();
            refresh_list ();
            show_toast (_("已从搜索结果添加 %d 个文件").printf (added));
        });
        dialog.present (this);
    }

    private void toggle_ai_panel () {
        ai_panel_visible = !ai_panel_visible;
        if (ai_panel_visible) {
            show_ai_panel ();
        } else {
            hide_ai_panel ();
        }
    }

    private void show_ai_panel () {
        ai_panel_visible = true;
        ai_sidebar.visible = true;
        // 第一次显示时构建 panel
        if (ai_panel_instance == null) {
            ai_panel_instance = new AIPanel (this);
            var content = ai_panel_instance.build_widget ();
            // Frame 内部包一个 card Box, 与现有三栏完全一致
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.set_size_request (-1, -1);
            box.add_css_class ("card");
            box.append (content);
            ai_sidebar.set_child (box);

            ai_panel_instance.get_undo_token.connect (() => {
                return undo_manager.get_stack_size ();
            });
            ai_panel_instance.revert_to_undo_token.connect ((token) => {
                bool needs_refresh = false;
                undo_manager.set_in_progress (true);
                while (undo_manager.can_undo && undo_manager.get_stack_size () > token) {
                    var delta = undo_manager.pop_undo ();
                    if (delta == null) break;
                    var redo_delta = build_redo_delta (delta);
                    apply_undo_delta (delta);
                    undo_manager.push_redo (redo_delta);
                    if (delta.op != UndoOp.SNAPSHOT) {
                        needs_refresh = true;
                    }
                }
                undo_manager.set_in_progress (false);
                if (needs_refresh) {
                    refresh_list ();
                    refresh_all_tree_states ();
                    dir_column_view.queue_draw ();
                }
                update_undo_redo_buttons ();
            });
            ai_panel_instance.template_triggered.connect ((header, footer) => {
                push_undo_state ();
                if (header != null && header.strip ().length > 0) {
                    app_state.add_item (new ItemData ("text", null, header, false), 0);
                }
                if (footer != null && footer.strip ().length > 0) {
                    app_state.add_item (new ItemData ("text", null, footer, false), -1);
                }
                refresh_list ();
            });
        }
        // 重新应用当前设置
        apply_ai_settings_to_panel ();

        // 更新窗口最小宽度 (AI 边栏可见时需要更大)
        update_window_min_size ();

        // 展开 AI 侧边栏时自动加宽窗口, 防止现有栏被挤出画面
        expand_window_for_ai ();
    }

    private void expand_window_for_ai () {
        int cur_w = get_width ();
        int cur_h = get_height ();
        if (cur_w <= 0) {
            // 后备: 使用 default_width / default_height
            cur_w = default_width;
            cur_h = default_height;
        }
        if (cur_w <= 0) return;

        // 记录展开前的宽度, 隐藏时恢复 (仅首次记录, 避免反复展开覆盖)
        if (pre_ai_width <= 0) {
            pre_ai_width = cur_w;
        }

        const int AI_EXTRA_WIDTH = 300;
        int target_w = cur_w + AI_EXTRA_WIDTH;

        // 不超过显示器宽度
        var disp = Gdk.Display.get_default ();
        if (disp != null) {
            var surface = this.get_surface ();
            if (surface != null) {
                var monitor = disp.get_monitor_at_surface (surface);
                if (monitor != null) {
                    var geo = monitor.get_geometry ();
                    if (target_w > geo.width) {
                        target_w = geo.width;
                    }
                }
            }
        }

        set_default_size (target_w, cur_h);
    }

    private void hide_ai_panel () {
        ai_panel_visible = false;
        ai_sidebar.visible = false;
        // 更新窗口最小宽度 (AI 边栏隐藏后可以更小)
        update_window_min_size ();

        // 恢复 AI 面板展开前的窗口宽度
        if (pre_ai_width > 0) {
            int cur_h = get_height ();
            if (cur_h <= 0) cur_h = default_height;
            set_default_size (pre_ai_width, cur_h);
            pre_ai_width = 0;
        }
    }

    private void apply_ai_settings_to_panel () {
        if (ai_panel_instance == null) return;
        var s = ConfigManager.load_ai_settings ();
        if (!s.enabled) {
            ai_panel_instance.configure (s, ai_controller.execute_tool, ai_controller.get_system_snapshot);
            return;
        }
        ai_panel_instance.configure (s, ai_controller.execute_tool, ai_controller.get_system_snapshot);
    }

    public void on_ai_settings () {
        if (ai_settings_dialog_instance == null) {
            ai_settings_dialog_instance = new AISettingsDialog (this);
        }
        ai_settings_dialog_instance.settings_changed.connect (() => {
            apply_ai_settings_to_panel ();
            // 允许的扩展名列表变更后, 重新评估编排列表: 新允许的后缀需要触发转换,
            // 移除的后缀需要清掉已有的预处理状态以避免误导.
            reevaluate_queue_against_allowed_exts ();
        });
        ai_settings_dialog_instance.present ();
    }

    // 允许扩展名列表变化后, 重新评估编排列表中各项
    private void reevaluate_queue_against_allowed_exts () {
        string[] allowed = ConfigManager.get_allowed_binary_extensions ();
        foreach (var item in items) {
            if (item.item_type != "file") continue;
            if (item.is_allowed_binary_target (allowed)) {
                // 重新进入允许列表: 此前因为不在列表中而未触发缓存检查, 现在补上
                if (item.preprocess_status == PreprocessStatus.NONE
                    || item.preprocess_status == PreprocessStatus.FAILED) {
                    vlm_queue.enqueue (item);
                }
            } else {
                // 移出允许列表: 清空预处理状态, 不再显示 AI 相关 UI
                if (item.preprocess_status != PreprocessStatus.NONE) {
                    item.preprocess_status = PreprocessStatus.NONE;
                    item.preprocessed_content = null;
                    item.from_cache = false;
                }
            }
        }
        refresh_list ();
    }

    // AIController.work_dir_change_requested 信号处理: 切换工作目录并刷新 UI
    private void ai_apply_set_work_dir (string path) {
        push_undo_state ();
        app_state.items.clear ();
        app_state.check_model.clear ();
        var folder = File.new_for_path (path);
        work_dir = folder;
        update_subtitle (path);
        root_store.remove_all ();
        var root_item = new DirectoryItem (folder.get_basename (), path, true);
        root_store.append (root_item);
        load_directory_children_lazy (root_item);
        search_entry.visible = true;
        var root_row = tree_list_model.get_item (0) as Gtk.TreeListRow;
        if (root_row != null) {
            root_row.set_expanded (true);
        }
        refresh_list ();
    }
}
