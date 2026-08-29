/* Git 提交历史面板.
 *
 * 从 FileCollectorWindow 抽出的独立子功能 (第一梯队拆分): 负责左侧 "Git Commit History"
 * 页的列表、异步加载、diff 预览与导出. 通过构造时传入的控件引用操作 UI, 通过 signal
 * 把需要窗口层处理的动作 (撤销快照 / 刷新队列 / 预处理入队 / 提示 / 错误 / 空状态变化 /
 * 树勾选状态刷新 / 删除·清空队列) 回传给窗口, 沿用 AIController 的同款 signal 契约.
 *
 * 与队列共享 AppState (items / check_model / work_dir) 作为单一真相源. */

using GLib;
using Gtk;
using Adw;
using Gee;
using Gdk;
using Pango;
using GtkSource;

public class GitHistoryPanel : GLib.Object {
    // ─── 信号: 回调窗口层执行 UI / 状态变更 ─────────────────────────────
    public signal void refresh_list_requested ();
    public signal void undo_snapshot_requested ();
    public signal void preprocess_item_requested (string path);
    public signal void toast (string msg);
    public signal void error (string title, string msg);
    public signal void empty_state_changed ();
    public signal void refresh_tree_states_requested ();
    public signal void delete_requested ();
    public signal void clear_requested ();

    // ─── 构造时传入的引用 ──────────────────────────────────────────────
    private Gtk.Window parent_window;
    private AppState app_state;
    private Gtk.Box git_page;
    private Gtk.ListView git_list_view;
    private Gtk.ScrolledWindow git_scrolled;
    private Gtk.SearchEntry git_search_entry;
    private Gtk.Box git_actions;
    private Gtk.Button btn_git_add_all_changed;
    private Gtk.Button btn_git_export_working_diff;
    private Gtk.Button btn_git_export_commit_diff;
    private Gtk.Button btn_git_delete;
    private Gtk.Button btn_git_clear;
    private GtkSource.View preview_view;
    private Gtk.Stack preview_stack;
    private Gtk.Button btn_retry_preprocess;

    // ─── 内部状态 (原窗口 private 字段) ─────────────────────────────────
    private GLib.ListStore git_commit_store;
    private Gtk.MultiSelection git_selection;
    private Gee.ArrayList<GitCommit> git_commits;
    private string git_search_text = "";
    private bool git_loading = false;
    private bool git_all_loaded = false;
    private Adw.StatusPage git_empty_page_widget;
    // 预览请求代数: 快速连续点击不同提交时, 丢弃过期线程的 diff 结果
    private int preview_gen = 0;

    public bool is_git_mode { get; set; }

    private const int GIT_BATCH_SIZE = 100;

    public GitHistoryPanel (
        Gtk.Window parent,
        AppState app_state,
        Gtk.Box git_page,
        Gtk.ListView git_list_view,
        Gtk.ScrolledWindow git_scrolled,
        Gtk.SearchEntry git_search_entry,
        Gtk.Box git_actions,
        Gtk.Button btn_git_add_all_changed,
        Gtk.Button btn_git_export_working_diff,
        Gtk.Button btn_git_export_commit_diff,
        Gtk.Button btn_git_delete,
        Gtk.Button btn_git_clear,
        GtkSource.View preview_view,
        Gtk.Stack preview_stack,
        Gtk.Button btn_retry_preprocess
    ) {
        this.parent_window = parent;
        this.app_state = app_state;
        this.git_page = git_page;
        this.git_list_view = git_list_view;
        this.git_scrolled = git_scrolled;
        this.git_search_entry = git_search_entry;
        this.git_actions = git_actions;
        this.btn_git_add_all_changed = btn_git_add_all_changed;
        this.btn_git_export_working_diff = btn_git_export_working_diff;
        this.btn_git_export_commit_diff = btn_git_export_commit_diff;
        this.btn_git_delete = btn_git_delete;
        this.btn_git_clear = btn_git_clear;
        this.preview_view = preview_view;
        this.preview_stack = preview_stack;
        this.btn_retry_preprocess = btn_retry_preprocess;

        setup ();
    }

    private void setup () {
        git_commits = new Gee.ArrayList<GitCommit> ();
        git_commit_store = new GLib.ListStore (typeof (GitCommit));
        git_selection = new Gtk.MultiSelection (git_commit_store);
        git_empty_page_widget = new Adw.StatusPage ();
        git_empty_page_widget.icon_name = "xsi-git-symbolic";

        var factory = new Gtk.SignalListItemFactory ();
        factory.setup.connect (setup_git_list_item);
        factory.bind.connect (bind_git_list_item);
        git_list_view.model = git_selection;
        git_list_view.factory = factory;

        // Git 列表滚动到底部时自动加载更多
        git_scrolled.edge_reached.connect ((pos) => {
            if (pos == Gtk.PositionType.BOTTOM && !git_loading && !git_all_loaded) {
                load_more_git_history ();
            }
        });

        git_search_entry.search_changed.connect (on_git_search_changed);

        btn_git_add_all_changed.clicked.connect (on_git_add_all_changed);
        btn_git_export_working_diff.clicked.connect (on_git_export_working_diff);
        btn_git_export_commit_diff.clicked.connect (on_git_export_commit_diff);
        btn_git_delete.clicked.connect (() => delete_requested ());
        btn_git_clear.clicked.connect (() => clear_requested ());

        git_selection.selection_changed.connect (on_git_selection_changed);
    }

    private void setup_git_list_item (GLib.Object obj) {
        var list_item = obj as Gtk.ListItem;

        var hash_label = new Gtk.Label ("");
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

        // 右键菜单: 复制提交哈希 (右键与触屏长按共用同一菜单逻辑)
        ContextMenus.ContextMenuPosCallback open_commit_menu = (gx, gy) => {
            var li = obj as Gtk.ListItem;
            if (li == null) return;
            var commit = li.get_item () as GitCommit;
            if (commit == null) return;

            var menu = new GLib.Menu ();
            menu.append (_("Copy Short Hash"), "git.copy_short_hash");
            menu.append (_("Copy Full Hash"), "git.copy_full_hash");
            menu.append (_("Copy Commit Message"), "git.copy_message");

            var actions = new GLib.SimpleActionGroup ();

            var act_short = new GLib.SimpleAction ("copy_short_hash", null);
            act_short.activate.connect (() => {
                parent_window.get_clipboard ().set_text (commit.short_hash);
            });
            actions.add_action (act_short);

            var act_full = new GLib.SimpleAction ("copy_full_hash", null);
            act_full.activate.connect (() => {
                parent_window.get_clipboard ().set_text (commit.hash);
            });
            actions.add_action (act_full);

            var act_msg = new GLib.SimpleAction ("copy_message", null);
            act_msg.activate.connect (() => {
                parent_window.get_clipboard ().set_text (commit.message);
            });
            actions.add_action (act_msg);

            var popover = new Gtk.PopoverMenu.from_model (menu);
            popover.set_has_arrow (false);
            popover.set_parent (box);
            popover.insert_action_group ("git", actions);
            popover.add_css_class ("ctx-menu");
            popover.set_halign (Gtk.Align.START);
            popover.set_valign (Gtk.Align.START);
            Gdk.Rectangle rect = { gx, gy, 1, 1 };
            popover.set_pointing_to (rect);
            popover.popup ();
        };
        var right_click = new Gtk.GestureClick ();
        right_click.set_button (Gdk.BUTTON_SECONDARY);
        right_click.pressed.connect ((n_press, gx, gy) => open_commit_menu ((int) gx, (int) gy));
        box.add_controller (right_click);
        ContextMenus.attach_long_press (box, open_commit_menu);

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

    private void append_git_commits (Gee.ArrayList<GitCommit> new_commits) {
        foreach (var commit in new_commits) {
            git_commits.add (commit);
            // 如果有搜索过滤, 只添加匹配的
            if (git_search_text != "" &&
                !commit.message.down ().contains (git_search_text.down ()) &&
                !commit.short_hash.down ().contains (git_search_text.down ())) {
                continue;
            }
            git_commit_store.append (commit);
        }
    }

    private void load_git_history_async () {
        if (app_state.work_dir == null) return;
        git_commits.clear ();
        git_commit_store.remove_all ();
        git_all_loaded = false;
        load_more_git_history ();
    }

    private void load_more_git_history () {
        if (app_state.work_dir == null || git_loading || git_all_loaded) return;
        git_loading = true;
        string dir = app_state.work_dir.get_path ();
        int skip = git_commits.size;

        try {
            GLib.Thread<void*>? thread = null;
            thread = new Thread<void*> ("git-log", () => {
                load_git_batch_in_thread (dir, skip, thread);
                return null;
            });
            app_state.bg_threads.add (thread);
        } catch (ThreadError e) {
            git_loading = false;
            warning ("Failed to create git-log thread: %s", e.message);
        }
    }

    private void load_git_batch_in_thread (string dir, int skip, GLib.Thread<void*>? thread) {
        string? error_msg = null;
        Gee.ArrayList<GitCommit>? result = null;
        try {
            result = GitService.get_log_with_skip (dir, GIT_BATCH_SIZE, skip);
        } catch (GLib.Error e) {
            error_msg = e.message;
        }

        Idle.add (() => {
            if (app_state.window_closing) return Source.REMOVE;
            if (error_msg != null) {
                string display_msg = error_msg;
                if (display_msg.has_prefix ("Git error: ")) {
                    display_msg = display_msg.substring (11);
                }
                if (display_msg.contains ("fatal:")) {
                    display_msg = display_msg.replace ("fatal: ", "").replace ("fatal:", "");
                }
                display_msg = display_msg.strip ();
                if (display_msg.char_count () > 60) {
                    int byte_pos = display_msg.index_of_nth_char (57);
                    display_msg = display_msg.substring (0, byte_pos) + "...";
                }
                toast (_("Failed to load Git log: %s").printf (display_msg));
            } else if (result != null) {
                if (result.size < GIT_BATCH_SIZE) {
                    git_all_loaded = true;
                }
                append_git_commits (result);
            }
            git_loading = false;
            empty_state_changed ();
            if (thread != null) app_state.bg_threads.remove (thread);
            return Source.REMOVE;
        });
    }

    private void on_git_selection_changed (uint position, uint n_items) {
        refresh_git_preview ();
    }

    private void refresh_git_preview () {
        uint first_selected = Gtk.INVALID_LIST_POSITION;
        uint n = git_commit_store.get_n_items ();
        for (uint i = 0; i < n; i++) {
            if (git_selection.is_selected (i)) {
                first_selected = i;
                break;
            }
        }

        if (first_selected == Gtk.INVALID_LIST_POSITION || first_selected >= n) {
            btn_git_export_commit_diff.sensitive = false;
            return;
        }

        var commit = git_commit_store.get_item (first_selected) as GitCommit;
        if (commit == null) {
            btn_git_export_commit_diff.sensitive = false;
            return;
        }

        btn_git_export_commit_diff.sensitive = true;
        load_and_preview_commit_diff (commit.hash);
    }

    private void load_and_preview_commit_diff (string hash) {
        if (app_state.work_dir == null) return;

        btn_retry_preprocess.visible = false;
        apply_preview_raw (_("Loading Diff..."));

        string dir = app_state.work_dir.get_path ();
        int gen = ++preview_gen;

        try {
            GLib.Thread<void*>? thread = null;
            thread = new Thread<void*> ("git-commit-diff", () => {
                load_preview_diff_in_thread (dir, hash, gen, thread);
                return null;
            });
            app_state.bg_threads.add (thread);
        } catch (ThreadError e) {
            warning ("Failed to create git-commit-diff thread: %s", e.message);
        }
    }

    private void load_preview_diff_in_thread (string dir, string hash, int gen, GLib.Thread<void*>? thread) {
        string diff_text;
        try {
            diff_text = GitService.get_commit_diff (dir, hash);
        } catch (Error e) {
            diff_text = "Error: " + e.message;
        }

        Idle.add (() => {
            if (thread != null) app_state.bg_threads.remove (thread);
            if (app_state.window_closing) return Source.REMOVE;
            // 已切换到其他提交或面板被重置: 丢弃过期结果, 避免旧 diff 覆盖新预览
            if (gen != preview_gen) return Source.REMOVE;
            render_diff_to_preview (diff_text);
            return Source.REMOVE;
        });
    }

    private void render_diff_to_preview (string diff_text) {
        preview_stack.visible_child = preview_view;

        var buffer = preview_view.get_buffer () as GtkSource.Buffer;
        var lang_manager = GtkSource.LanguageManager.get_default ();
        var diff_lang = lang_manager.guess_language (null, "text/x-diff");
        buffer.set_language (diff_lang);
        buffer.set_highlight_syntax (diff_lang != null);
        preview_view.set_show_line_numbers (true);

        // 插入文件名分隔标题 + 原始 diff 文本
        var sb = new StringBuilder ();
        string? last_file = null;
        foreach (var line in diff_text.split ("\n")) {
            if (line.has_prefix ("diff ")) {
                string fname = extract_diff_filename (line);
                if (fname != null && fname != last_file) {
                    last_file = fname;
                    sb.append ("\n━━━ ").append (fname).append (" ━━━\n");
                }
            }
            sb.append (line).append ("\n");
        }
        buffer.set_text (sb.str, -1);
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

    private void apply_preview_raw (string text) {
        preview_stack.visible_child = preview_view;
        var buffer = preview_view.get_buffer () as GtkSource.Buffer;
        buffer.set_language (null);
        buffer.set_highlight_syntax (false);
        buffer.set_text (text, -1);
    }

    // ─── 中栏按钮操作 ────────────────────────────────────────────────

    private void on_git_add_all_changed () {
        if (app_state.work_dir == null) {
            toast (_("Set working directory"));
            return;
        }

        string dir = app_state.work_dir.get_path ();
        try {
            GLib.Thread<void*>? thread = null;
            thread = new Thread<void*> ("git-status", () => {
                git_add_all_changed_in_thread (dir, thread);
                return null;
            });
            app_state.bg_threads.add (thread);
        } catch (ThreadError e) {
            warning ("Failed to create git-status thread: %s", e.message);
        }
    }

    private void git_add_all_changed_in_thread (string dir, GLib.Thread<void*>? thread) {
        string? error_msg = null;
        string status = "";
        try {
            status = GitService.get_status (dir);
        } catch (Error e) {
            error_msg = e.message;
        }

        Idle.add (() => {
            if (thread != null) app_state.bg_threads.remove (thread);
            if (app_state.window_closing) return Source.REMOVE;
            if (error_msg != null) {
                error (_("Git Error"), error_msg);
                return Source.REMOVE;
            }

            if (status.strip ().length == 0) {
                toast (_("No uncommitted changes in working tree"));
                return Source.REMOVE;
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
                string abs = GLib.Path.build_filename (app_state.work_dir.get_path (), path_part);
                if (FileUtils.test (abs, FileTest.EXISTS) && !FileUtils.test (abs, FileTest.IS_DIR)) {
                    files_to_add.add (abs);
                }
            }

            if (files_to_add.size == 0) {
                toast (_("No files to add"));
                return Source.REMOVE;
            }

            undo_snapshot_requested ();
            int added = 0;
            foreach (var path in files_to_add) {
                if (!UIHelpers.path_in_items (app_state.items, path)) {
                    var new_item = new ItemData ("file", path, null, false);
                    app_state.items.add (new_item);
                    if (new_item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
                        preprocess_item_requested (new_item.file_path);
                    }
                    if (!(path in app_state.check_model.checked_files)) {
                        app_state.check_model.add_files ({ path });
                    }
                    added++;
                }
            }
            refresh_tree_states_requested ();
            refresh_list_requested ();
            return Source.REMOVE;
        });
    }

    private void on_git_export_working_diff () {
        if (app_state.work_dir == null) {
            toast (_("Set working directory"));
            return;
        }

        string dir = app_state.work_dir.get_path ();
        try {
            GLib.Thread<void*>? thread = null;
            thread = new Thread<void*> ("git-working-diff", () => {
                git_export_working_diff_in_thread (dir, thread);
                return null;
            });
            app_state.bg_threads.add (thread);
        } catch (ThreadError e) {
            warning ("Failed to create git-working-diff thread: %s", e.message);
        }
    }

    private void git_export_working_diff_in_thread (string dir, GLib.Thread<void*>? thread) {
        string? error_msg = null;
        string diff = "";
        try {
            diff = GitService.get_working_tree_diff (dir);
        } catch (Error e) {
            error_msg = e.message;
        }

        Idle.add (() => {
            if (thread != null) app_state.bg_threads.remove (thread);
            if (app_state.window_closing) return Source.REMOVE;
            if (error_msg != null) {
                error (_("Git Error"), error_msg);
                return Source.REMOVE;
            }
            if (diff.strip ().length == 0) {
                toast (_("No uncommitted changes in working tree"));
                return Source.REMOVE;
            }
            undo_snapshot_requested ();
            string md_text = "# Git Working Tree Diff\n\n```diff\n%s\n```".printf (diff);
            app_state.items.insert (0, new ItemData ("text", null, md_text, false));
            refresh_list_requested ();
            return Source.REMOVE;
        });
    }

    private void on_git_export_commit_diff () {
        if (app_state.work_dir == null) return;

        var selected_commits = new Gee.ArrayList<GitCommit> ();
        uint n = git_commit_store.get_n_items ();
        for (uint i = 0; i < n; i++) {
            if (git_selection.is_selected (i)) {
                var commit = git_commit_store.get_item (i) as GitCommit;
                if (commit != null) {
                    selected_commits.add (commit);
                }
            }
        }

        if (selected_commits.size == 0) return;

        string dir = app_state.work_dir.get_path ();
        try {
            GLib.Thread<void*>? thread = null;
            thread = new Thread<void*> ("git-commits-diff", () => {
                git_export_commit_diff_in_thread (dir, selected_commits, thread);
                return null;
            });
            app_state.bg_threads.add (thread);
        } catch (ThreadError e) {
            warning ("Failed to create git-commits-diff thread: %s", e.message);
        }
    }

    private void git_export_commit_diff_in_thread (
            string dir, Gee.ArrayList<GitCommit> selected_commits, GLib.Thread<void*>? thread) {
        string? error_msg = null;
        // 与选择顺序一致 (git_commit_store 中索引 0 为最新提交, 即最新在前)
        var md_texts = new Gee.ArrayList<string> ();
        foreach (var commit in selected_commits) {
            try {
                string diff = GitService.get_commit_diff (dir, commit.hash);
                md_texts.add ("# Git Commit: %s (%s)\n\n```diff\n%s\n```".printf (
                    commit.short_hash, commit.message, diff));
            } catch (Error e) {
                error_msg = e.message;
                break;
            }
        }

        Idle.add (() => {
            if (thread != null) app_state.bg_threads.remove (thread);
            if (app_state.window_closing) return Source.REMOVE;
            if (error_msg != null) {
                error (_("Git Error"), error_msg);
                return Source.REMOVE;
            }
            undo_snapshot_requested ();
            // 依次在位置 0 插入, 最终列表为提交先后顺序（最旧在前）
            foreach (var md_text in md_texts) {
                app_state.items.insert (0, new ItemData ("text", null, md_text, false));
            }
            refresh_list_requested ();
            return Source.REMOVE;
        });
    }

    // ─── 供窗口调用的公共 API ─────────────────────────────────────────

    public bool has_data () {
        if (app_state.work_dir == null) return false;
        if (!GitService.is_git_repo (app_state.work_dir.get_path ())) return false;
        if (git_commits.size > 0) return true;
        if (!git_all_loaded) return true;
        return false;
    }

    public void configure_empty_page () {
        if (app_state.work_dir == null) return;
        if (!GitService.is_git_repo (app_state.work_dir.get_path ())) {
            git_empty_page_widget.title = _("No Git Repository Detected");
            git_empty_page_widget.description = _("The current working directory is not a Git repository, so commit history cannot be read. Run git init there, or open the app in a working directory that contains a repository.");
        } else {
            git_empty_page_widget.title = _("No Commits Yet");
            git_empty_page_widget.description = _("The current Git repository has no commits yet. The commit history will appear here after the first git commit.");
        }
    }

    public Gtk.Widget empty_page_widget {
        get { return git_empty_page_widget; }
    }

    // 进入 Git 模式: 刷新按钮可用性, 必要时加载历史
    public void maybe_load_history () {
        refresh_sensitivity ();
        if (app_state.work_dir == null) return;
        if (!GitService.is_git_repo (app_state.work_dir.get_path ())) return;
        if (git_commits.size == 0 && !git_all_loaded) {
            load_git_history_async ();
        }
    }

    // 工作目录变更: 重置并 (若处于 Git 模式) 重新加载
    public void on_work_dir_changed () {
        preview_gen++; // 使在途的预览 diff 线程结果失效
        git_commits.clear ();
        git_commit_store.remove_all ();
        git_all_loaded = false;
        git_search_text = "";
        git_search_entry.text = "";
        refresh_git_list ();
        git_search_entry.visible = app_state.work_dir != null;
        refresh_sensitivity ();
        if (is_git_mode) {
            maybe_load_history ();
        }
        empty_state_changed ();
    }

    public void refresh_sensitivity () {
        bool has_wd = app_state.work_dir != null;
        btn_git_add_all_changed.sensitive = has_wd;
        btn_git_export_working_diff.sensitive = has_wd;
    }
}
