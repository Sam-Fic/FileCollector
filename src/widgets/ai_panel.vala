/* AI 助手聊天面板.
 *
 * 与多平台版本 ai_panel.py 行为 1:1:
 *  - 顶部: AI 助手标题
 *  - 中部: 聊天气泡 (用户右对齐蓝色, 助手左对齐白底, 系统居中黄色, 工具调用可折叠)
 *  - 底部: 多行输入框 + 发送/清空按钮
 *  - 状态行: 模型名 + 当前状态
 *
 * API 调用走 GLib.Thread + Worker, 不阻塞主线程.
 * 工具调用由主窗口注入的 tool_executor 回调执行; 这里只负责消息展示和对话循环.
 *
 * UI 风格: 与现有 left/middle/right 三栏卡片 (panel-frame + card) 完全一致 —
 * Frame + Box styles="card" + panel-title 标题.
 */

using GLib;
using Gtk;
using Adw;
using Gee;
using Json;
using AI;

public class AIMessage : GLib.Object {
    public string role;       // "user" | "assistant" | "system" | "tool"
    public string content;    // 纯文本 (markdown 不渲染, 跟现有三栏的纯文本风格一致)
    public string tool_name;  // tool 专用
    public string tool_args_repr;  // tool 专用
    public string tool_result;     // tool 专用
    public bool expanded;
    public int undo_token = -1;

    public AIMessage (string r, string c) {
        role = r;
        content = c ?? "";
    }
}


public class AIPanel : GLib.Object {
    private Gtk.Window? parent_window;

    // 控件
    private Gtk.Box root_box;
    private Gtk.Box chat_container;     // 直接放气泡的 Box
    private Gtk.ScrolledWindow chat_scroll;
    private Gtk.TextView input_view;
    private Gtk.Button btn_send;
    private Gtk.Label lbl_send;
    private Gtk.Image send_icon;
    private Gtk.Button btn_clear;
    private Gtk.Button btn_scroll_bottom;
    private Gtk.Label lbl_status;

    private Gtk.Frame completion_frame;
    private Gtk.ListBox completion_list;
    private Gtk.Label lbl_model;

    // 状态
    private AIClient? client;
    private string system_prompt_override = "";
    private AIToolExecutor? tool_executor;
    private AIStateProvider? state_provider;

    public signal int get_undo_token ();
    public signal void revert_to_undo_token (int token);
    public signal void template_triggered (string header, string footer);

    private GLib.Thread<void>? worker_thread = null;
    private bool busy = false;
    private bool stop_requested = false;
    private bool pending_welcome = true;
    private bool ai_enabled = false;
    private GLib.Cancellable? request_cancellable = null;
    // 用户是否停留在底部附近 (用于判断是否自动滚动)
    private bool auto_scroll = true;
    // 标记正在 rerender, 抑制 adj.changed 的自动滚动 (由 rerender 自行处理)
    private bool is_rerendering = false;

    private Gee.ArrayList<Json.Node> messages = new Gee.ArrayList<Json.Node> ();
    private Gee.ArrayList<AIMessage> rendered = new Gee.ArrayList<AIMessage> ();
    private int tool_counter = 0;

    // messages 在 worker 线程 (on_api_finished) 和主线程 (rebuild_system_message,
    // send_user_message, on_clear_chat) 之间并发读写, 必须用锁保护
    private GLib.Mutex messages_lock = GLib.Mutex ();

    // 由主窗口创建并配置; 本身只是个 widget 工厂
    public AIPanel (Gtk.Window? parent) {
        this.parent_window = parent;
    }

    public Gtk.Widget build_widget () {
        root_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

        // ── 标题 ──
        var title = new Gtk.Label (_("AI 助手"));
        title.halign = Gtk.Align.CENTER;
        title.add_css_class ("panel-title");
        root_box.append (title);

        // ── 聊天区 ──
        chat_container = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        chat_container.margin_start = 0;
        chat_container.margin_end = 0;
        chat_container.margin_top = 0;
        chat_container.margin_bottom = 6;
        chat_container.set_homogeneous (false);

        // 容器底部用 Box 撑开, 让内容少时也保持顶部对齐
        var chat_alignment = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        chat_alignment.append (chat_container);
        // 末尾 stretch
        var tail = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        tail.hexpand = true;
        tail.vexpand = true;
        chat_alignment.append (tail);

        chat_scroll = new Gtk.ScrolledWindow ();
        chat_scroll.set_child (chat_alignment);
        chat_scroll.set_vexpand (true);
        chat_scroll.set_hexpand (true);
        // 滚动条与滚动区分隔线整体内缩 12, 与其他卡片左右内边距对齐
        chat_scroll.set_margin_start (12);
        chat_scroll.set_margin_end (12);
        chat_scroll.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);

        // 滚动到底部按钮 (悬浮在聊天区右下角, 不在底部时显示)
        btn_scroll_bottom = new Gtk.Button.from_icon_name ("go-down-symbolic");
        btn_scroll_bottom.add_css_class ("circular");
        btn_scroll_bottom.add_css_class ("ai-scroll-bottom-btn");
        btn_scroll_bottom.set_tooltip_text (_("滚动到底部"));
        btn_scroll_bottom.set_halign (Gtk.Align.END);
        btn_scroll_bottom.set_valign (Gtk.Align.END);
        // 12 (scroll 内缩) + 8 (原视觉边距) = 20, 与内缩后的滚动区右下角对齐
        btn_scroll_bottom.set_margin_end (20);
        btn_scroll_bottom.set_margin_bottom (8);
        btn_scroll_bottom.set_visible (false);
        btn_scroll_bottom.clicked.connect (() => {
            scroll_to_bottom (true);
        });
        // 用 Overlay 让按钮悬浮在 ScrolledWindow 上
        var chat_overlay = new Gtk.Overlay ();
        chat_overlay.set_child (chat_scroll);
        chat_overlay.add_overlay (btn_scroll_bottom);
        root_box.append (chat_overlay);

        // 监听滚动位置: 判断用户是否在底部附近
        var adj = chat_scroll.get_vadjustment ();
        adj.changed.connect (() => {
            // rerender 期间不自动滚动, 由 rerender 自行恢复位置
            if (auto_scroll && !is_rerendering) {
                scroll_to_bottom (false);
            }
            update_scroll_bottom_btn ();
        });
        adj.value_changed.connect (() => {
            update_auto_scroll ();
            update_scroll_bottom_btn ();
        });

        // ── 补全列表 (默认隐藏, 出现在输入框上方) ──
        completion_frame = new Gtk.Frame (null);
        completion_frame.add_css_class ("ai-input-frame");
        completion_frame.margin_start = 12;
        completion_frame.margin_end = 12;
        completion_frame.margin_bottom = 4;
        completion_frame.visible = false;

        completion_list = new Gtk.ListBox ();
        completion_list.add_css_class ("boxed-list");
        completion_list.set_selection_mode (Gtk.SelectionMode.SINGLE);

        var completion_scroll = new Gtk.ScrolledWindow ();
        completion_scroll.set_child (completion_list);
        completion_scroll.set_min_content_height (150);
        completion_scroll.set_max_content_height (200);
        completion_scroll.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        completion_frame.set_child (completion_scroll);
        root_box.append (completion_frame);

        // ── 输入区 ──
        var input_frame = new Gtk.Frame (null);
        input_frame.add_css_class ("card");
        input_frame.add_css_class ("ai-input-frame");
        input_frame.margin_start = 12;
        input_frame.margin_end = 12;
        input_frame.margin_top = 2;
        input_frame.margin_bottom = 6;

        var input_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        input_box.margin_start = 6;
        input_box.margin_end = 6;
        input_box.margin_top = 6;
        input_box.margin_bottom = 6;

        input_view = new Gtk.TextView ();
        input_view.set_wrap_mode (Gtk.WrapMode.WORD_CHAR);
        input_view.set_top_margin (4);
        input_view.set_bottom_margin (4);
        input_view.set_left_margin (6);
        input_view.set_right_margin (6);
        input_view.set_size_request (-1, 80);
        // GTK4 中 Gtk.TextView 没有 set_placeholder_text; 用 overlay 自行实现
        var input_overlay = new Gtk.Overlay ();
        input_overlay.set_child (input_view);
        var placeholder_lbl = new Gtk.Label (_("输入指令, Enter 发送, Ctrl+Enter 换行"));
        placeholder_lbl.add_css_class ("dim-label");
        placeholder_lbl.add_css_class ("ai-placeholder");
        placeholder_lbl.set_wrap (true);
        placeholder_lbl.set_wrap_mode (Pango.WrapMode.WORD_CHAR);
        placeholder_lbl.set_xalign (0);
        placeholder_lbl.set_halign (Gtk.Align.START);
        placeholder_lbl.set_valign (Gtk.Align.START);
        // 跟 TextView 自身边距一致, 让占位文字与光标基线对齐
        placeholder_lbl.set_margin_start (6);
        placeholder_lbl.set_margin_top (4);
        // 关键: 让占位标签不接收鼠标事件, 否则会盖在 TextView 上拦截点击
        placeholder_lbl.set_can_target (false);
        placeholder_lbl.set_can_focus (false);
        input_overlay.add_overlay (placeholder_lbl);
        input_view.get_buffer ().changed.connect (() => {
            Gtk.TextIter s, e;
            input_view.get_buffer ().get_bounds (out s, out e);
            placeholder_lbl.visible = input_view.get_buffer ().get_text (s, e, false).length == 0;
        });
        input_box.append (input_overlay);
        // Enter 发送, Ctrl+Enter 换行, 补全列表导航
        var key = new Gtk.EventControllerKey ();
        key.key_pressed.connect ((keyval, keycode, state) => {
            if (completion_frame.visible) {
                if (keyval == Gdk.Key.Down) {
                    move_completion_selection (1);
                    return true;
                } else if (keyval == Gdk.Key.Up) {
                    move_completion_selection (-1);
                    return true;
                } else if (keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter) {
                    var selected = completion_list.get_selected_row ();
                    if (selected != null) {
                        apply_completion (selected);
                        return true;
                    }
                } else if (keyval == Gdk.Key.Escape) {
                    hide_completion ();
                    return true;
                }
            }

            if (keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter) {
                if ((state & Gdk.ModifierType.CONTROL_MASK) != 0) {
                    input_view.get_buffer ().insert_at_cursor ("\n", 1);
                    Gtk.TextIter cursor_iter;
                    input_view.get_buffer ().get_iter_at_mark (out cursor_iter,
                        input_view.get_buffer ().get_insert ());
                    input_view.scroll_to_iter (cursor_iter, 0, false, 0, 0);
                    return true;
                }
                on_send_or_stop ();
                return true;
            }
            return false;
        });
        input_view.add_controller (key);

        // 监听输入变化以触发补全
        input_view.get_buffer ().changed.connect (on_input_changed);

        // 按钮行
        var btn_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        btn_clear = new Gtk.Button.from_icon_name ("user-trash-symbolic");
        btn_clear.set_tooltip_text (_("清空对话"));
        btn_clear.set_size_request (-1, -1);
        btn_clear.clicked.connect (on_clear_chat);
        btn_row.append (btn_clear);

        var spacer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        spacer.hexpand = true;
        btn_row.append (spacer);

        var send_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
        send_box.halign = Gtk.Align.CENTER;
        send_icon = new Gtk.Image.from_icon_name ("mail-send-symbolic");
        send_box.append (send_icon);
        lbl_send = new Gtk.Label (_("发送"));
        send_box.append (lbl_send);

        btn_send = new Gtk.Button ();
        btn_send.set_child (send_box);
        btn_send.add_css_class ("suggested-action");
        btn_send.clicked.connect (on_send_or_stop);
        btn_row.append (btn_send);
        input_box.append (btn_row);

        input_frame.set_child (input_box);
        root_box.append (input_frame);

        // ── 状态行 ──
        var status_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        status_row.margin_start = 12;
        status_row.margin_end = 12;
        status_row.margin_bottom = 8;
        lbl_status = new Gtk.Label (null);
        lbl_status.halign = Gtk.Align.START;
        lbl_status.add_css_class ("dim-label");
        lbl_status.add_css_class ("caption");
        lbl_status.hexpand = true;
        status_row.append (lbl_status);
        lbl_model = new Gtk.Label (null);
        lbl_model.halign = Gtk.Align.END;
        lbl_model.add_css_class ("dim-label");
        lbl_model.add_css_class ("caption");
        status_row.append (lbl_model);
        root_box.append (status_row);

        update_status ();
        return root_box;
    }

    // 公共 API: 主窗口初始化或设置变更时调用
    public void configure (
        ConfigManager.AISettings ai,
        AIToolExecutor executor,
        AIStateProvider provider
    ) {
        this.tool_executor = executor;
        this.state_provider = provider;

        // 显式类型 + 不同变量名, 避免字段遮蔽与 GLib.Object 推断问题
        ConfigManager.AISettings s = ai;
        string base_url_str = s.base_url;
        string api_key_str = s.api_key;
        string model_str = s.model;
        string sp_str = s.system_prompt_override;
        if (base_url_str == null) base_url_str = "";
        if (api_key_str == null) api_key_str = "";
        if (model_str == null) model_str = "";
        if (sp_str == null) sp_str = "";
        this.system_prompt_override = sp_str.strip ();

        base_url_str = base_url_str.strip ();
        api_key_str = api_key_str.strip ();
        model_str = model_str.strip ();
        double timeout_v = s.timeout > 0 ? s.timeout : 60.0;

        lbl_model.set_text (model_str.length > 0 ? model_str : _("未配置模型"));
        bool has_config = base_url_str.length > 0 && api_key_str.length > 0 && model_str.length > 0;

        bool was_enabled = this.ai_enabled;
        this.ai_enabled = ai.enabled;

        if (has_config && ai.enabled) {
            client = new AIClient (base_url_str, api_key_str, model_str, timeout_v);
            if (!was_enabled && ai.enabled) {
                pending_welcome = true;
            }
        } else {
            client = null;
        }
        bool was_first = pending_welcome;
        update_status ();
        if (ai.enabled && was_first) {
            pending_welcome = false;
            render_assistant (_("你好, 我是 AI 编排助手。告诉我你想收集哪些文件, 我来帮你编排。\n"
                + "例如: \"把 src 目录下所有 Python 文件加进去, 然后在开头插入一段任务说明。\""));
        }
    }

    public void shutdown () {
        stop_requested = true;
        if (request_cancellable != null) {
            request_cancellable.cancel ();
        }
        if (worker_thread != null) {
            worker_thread.join ();
            worker_thread = null;
        }
    }

    // 供外部 (如 FileCollectorWindow) 查询 AI 是否已被用户停止
    public bool is_stop_requested () {
        return stop_requested;
    }


    // ─── 渲染 ────────────────────────────────────────────────────────────

    private void render_user (string text, int token = -1) {
        var stripped = text.strip ();
        if (stripped.length == 0) return;
        var msg = new AIMessage ("user", stripped);
        msg.undo_token = token;
        rendered.add (msg);
        rerender ();
    }

    private void render_assistant (string text) {
        var stripped = text.strip ();
        // 内容为空或纯空白时不渲染气泡 (避免工具调用间出现空白气泡)
        if (stripped.length == 0) return;
        var msg = new AIMessage ("assistant", stripped);
        rendered.add (msg);
        rerender ();
    }

    private void render_system (string text) {
        var stripped = text.strip ();
        if (stripped.length == 0) return;
        var msg = new AIMessage ("system", stripped);
        rendered.add (msg);
        rerender ();
    }

    private void render_tool (string name, string args_repr, string result) {
        tool_counter++;
        var msg = new AIMessage ("tool", "");
        msg.tool_name = name;
        msg.tool_args_repr = args_repr;
        msg.tool_result = result ?? "OK";
        msg.expanded = false;
        rendered.add (msg);
        rerender ();
    }

    // 清洗 UTF-8: 用 replacement character 替换无效字节, 避免 Pango 警告
    private string sanitize_utf8 (string? text) {
        if (text == null) return "";
        if (text.validate (-1)) return text;
        return text.make_valid (-1);
    }

    // 按字节长度截断, 但不切断多字节 UTF-8 字符, 避免乱码
    private static string truncate_utf8 (string text, int max_bytes) {
        if (text.length <= max_bytes) return text;
        // 向前回退到字符边界
        int cut = max_bytes;
        while (cut > 0 && !text[0:cut].validate (-1)) {
            cut--;
        }
        return text[0:cut];
    }

    private void rerender () {
        // 保存当前滚动位置 (相对底部的偏移), 用于重建后恢复
        var adj_before = chat_scroll.get_vadjustment ();
        double saved_offset_from_bottom = -1;
        if (adj_before != null) {
            saved_offset_from_bottom = adj_before.get_upper () - adj_before.get_value () - adj_before.get_page_size ();
            if (saved_offset_from_bottom < 0) saved_offset_from_bottom = 0;
        }

        // 标记正在 rerender, 抑制 adj.changed 的自动滚动
        is_rerendering = true;

        // 清空旧气泡
        Gtk.Widget? child = chat_container.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            chat_container.remove (child);
            child = next;
        }
        foreach (var msg in rendered) {
            chat_container.append (build_bubble (msg));
        }
        // 重建后恢复滚动位置: 工具展开/折叠时不应该跳动
        // 用 Idle 确保布局完成后再设置
        GLib.Idle.add (() => {
            is_rerendering = false;
            var a = chat_scroll.get_vadjustment ();
            if (a != null) {
                if (auto_scroll && saved_offset_from_bottom < 30) {
                    // 用户原本在底部附近, 滚动到底部
                    a.set_value (a.get_upper () - a.get_page_size ());
                } else if (saved_offset_from_bottom >= 0) {
                    // 用户不在底部, 保持相对底部的位置
                    double new_value = a.get_upper () - a.get_page_size () - saved_offset_from_bottom;
                    if (new_value < 0) new_value = 0;
                    a.set_value (new_value);
                }
            }
            update_scroll_bottom_btn ();
            return GLib.Source.REMOVE;
        });
    }

    // 滚动到底部. force=true 时强制滚动并重置 auto_scroll.
    private void scroll_to_bottom (bool force) {
        if (force) {
            auto_scroll = true;
        }
        var adj = chat_scroll.get_vadjustment ();
        if (adj == null) return;
        // 用 Idle 确保在布局更新后再滚动
        GLib.Idle.add (() => {
            var a = chat_scroll.get_vadjustment ();
            if (a != null) {
                a.set_value (a.get_upper () - a.get_page_size ());
            }
            update_scroll_bottom_btn ();
            return GLib.Source.REMOVE;
        });
    }

    // 根据当前滚动位置更新 auto_scroll 标志.
    // 在底部附近 (30px 容差) 视为"在底部", 允许自动滚动.
    private void update_auto_scroll () {
        var adj = chat_scroll.get_vadjustment ();
        if (adj == null) return;
        double current = adj.get_value ();
        double upper = adj.get_upper ();
        double page = adj.get_page_size ();
        double bottom = upper - page;
        auto_scroll = (current >= bottom - 30);
    }

    // 根据是否在底部更新滚动按钮的可见性
    private void update_scroll_bottom_btn () {
        var adj = chat_scroll.get_vadjustment ();
        if (adj == null) {
            btn_scroll_bottom.set_visible (false);
            return;
        }
        double current = adj.get_value ();
        double upper = adj.get_upper ();
        double page = adj.get_page_size ();
        double bottom = upper - page;
        // 内容不足以滚动时隐藏按钮
        if (upper <= page + 1) {
            btn_scroll_bottom.set_visible (false);
        } else {
            btn_scroll_bottom.set_visible (current < bottom - 30);
        }
    }

    private Gtk.Widget build_bubble (AIMessage msg) {
        // 外层: 决定左/右/居中对齐
        var outer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        outer.set_size_request (-1, -1);

        var bubble = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
        bubble.add_css_class ("ai-bubble");
        switch (msg.role) {
            case "user":
                bubble.add_css_class ("ai-bubble-user");
                break;
            case "assistant":
                bubble.add_css_class ("ai-bubble-assistant");
                break;
            case "system":
                bubble.add_css_class ("ai-bubble-system");
                break;
            case "tool":
                bubble.add_css_class ("ai-bubble-tool");
                break;
        }

        switch (msg.role) {
            case "user": {
                var hbox = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
                hbox.hexpand = true;

                var label = new Gtk.Label (sanitize_utf8 (msg.content));
                label.xalign = 0;
                label.wrap = true;
                label.wrap_mode = Pango.WrapMode.WORD_CHAR;
                label.selectable = true;
                label.hexpand = true;
                label.halign = Gtk.Align.FILL;
                label.add_css_class ("ai-bubble-content");
                hbox.append (label);

                var revert_btn = new Gtk.Button.from_icon_name ("edit-undo-symbolic");
                revert_btn.add_css_class ("flat");
                revert_btn.add_css_class ("ai-revert-btn");
                revert_btn.set_tooltip_text (_("撤回此消息及后续所有 AI 回复与操作"));
                revert_btn.valign = Gtk.Align.CENTER;
                revert_btn.halign = Gtk.Align.END;
                revert_btn.margin_start = 8;
                revert_btn.opacity = 0.6;

                int captured_token = msg.undo_token;
                string captured_text = msg.content;
                revert_btn.clicked.connect (() => {
                    on_revert_requested (captured_token, captured_text);
                });

                hbox.append (revert_btn);
                bubble.append (hbox);
                break;
            }
            case "assistant": {
                // 用 Markdown 渲染 (cmark AST → GTK widget 树)
                var md = new MarkdownView (msg.content);
                md.add_css_class ("ai-bubble-content");
                bubble.append (md);
                break;
            }
            case "system": {
                var label = new Gtk.Label (sanitize_utf8 (msg.content));
                label.xalign = 0;
                label.wrap = true;
                label.wrap_mode = Pango.WrapMode.WORD_CHAR;
                label.selectable = true;
                label.hexpand = true;
                label.halign = Gtk.Align.FILL;
                label.add_css_class ("ai-bubble-content");
                label.valign = Gtk.Align.CENTER;
                bubble.append (label);
                break;
            }
            case "tool": {
                // 工具调用卡片: 头部 (icon + name + args + action) + body/preview (可折叠)
                var header_btn = new Gtk.Button ();
                header_btn.add_css_class ("flat");
                header_btn.add_css_class ("ai-tool-header");
                header_btn.set_size_request (-1, 32);
                header_btn.halign = Gtk.Align.FILL;

                var header_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);

                // 用 GTK 原生 disclosure 图标 (与文件树文件夹展开箭头同款)
                var arrow = new Gtk.Image ();
                arrow.icon_name = msg.expanded ? "pan-down-symbolic" : "pan-end-symbolic";
                arrow.add_css_class ("ai-tool-arrow");
                arrow.valign = Gtk.Align.CENTER;
                header_box.append (arrow);

                var name_lbl = new Gtk.Label (sanitize_utf8 (msg.tool_name));
                name_lbl.add_css_class ("ai-tool-name");
                name_lbl.valign = Gtk.Align.CENTER;
                header_box.append (name_lbl);

                var args_lbl = new Gtk.Label (sanitize_utf8 (msg.tool_args_repr));
                args_lbl.add_css_class ("ai-tool-args");
                args_lbl.valign = Gtk.Align.CENTER;
                args_lbl.ellipsize = Pango.EllipsizeMode.END;
                args_lbl.hexpand = true;
                args_lbl.halign = Gtk.Align.START;
                header_box.append (args_lbl);

                var action = new Gtk.Label (msg.expanded ? _("收起") : _("查看结果"));
                action.add_css_class ("ai-tool-action");
                action.valign = Gtk.Align.CENTER;
                header_box.append (action);

                header_btn.set_child (header_box);

                // Body (展开时显示完整结果)
                var body = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
                body.add_css_class ("ai-tool-body");
                var result_lbl = new Gtk.Label (sanitize_utf8 (msg.tool_result ?? ""));
                result_lbl.xalign = 0;
                result_lbl.yalign = 0;
                result_lbl.wrap = true;
                result_lbl.wrap_mode = Pango.WrapMode.WORD_CHAR;
                result_lbl.selectable = true;
                result_lbl.add_css_class ("ai-tool-result");
                body.append (result_lbl);

                // Preview (折叠时显示截断预览)
                var preview = msg.tool_result ?? "";
                if (preview.length > 80) preview = truncate_utf8 (preview, 80) + "…";
                var preview_lbl = new Gtk.Label (sanitize_utf8 (preview));
                preview_lbl.xalign = 0;
                preview_lbl.wrap = true;
                preview_lbl.add_css_class ("ai-tool-preview");

                // 初始可见性
                body.set_visible (msg.expanded);
                preview_lbl.set_visible (!msg.expanded);

                // 展开/折叠: 直接切换可见性, 不重建整个聊天区
                header_btn.clicked.connect (() => {
                    msg.expanded = !msg.expanded;
                    // 保存头部在视口中的相对位置, 展开后恢复
                    var adj_save = chat_scroll.get_vadjustment ();
                    double saved_value = adj_save != null ? adj_save.get_value () : 0;
                    body.set_visible (msg.expanded);
                    preview_lbl.set_visible (!msg.expanded);
                    arrow.icon_name = msg.expanded ? "pan-down-symbolic" : "pan-end-symbolic";
                    action.label = msg.expanded ? _("收起") : _("查看结果");

                    // 展开时保持头部位置不动 (内容向下展开)
                    if (msg.expanded) {
                        GLib.Idle.add (() => {
                            var a = chat_scroll.get_vadjustment ();
                            if (a != null) {
                                a.set_value (saved_value);
                            }
                            update_scroll_bottom_btn ();
                            return GLib.Source.REMOVE;
                        });
                    }
                });

                bubble.append (header_btn);
                bubble.append (body);
                bubble.append (preview_lbl);
                break;
            }
        }

        switch (msg.role) {
            case "user":
            case "assistant":
            case "system":
            case "tool":
            default:
                // 所有气泡都填满整个宽度, 不再左右留白自适应
                bubble.hexpand = true;
                bubble.halign = Gtk.Align.FILL;
                outer.append (bubble);
                break;
        }

        return outer;
    }


    // ─── 交互 ────────────────────────────────────────────────────────────

    private void on_send_or_stop () {
        if (busy) {
            request_stop ();
            return;
        }
        on_send ();
    }

    private void request_stop () {
        stop_requested = true;
        if (request_cancellable != null) {
            request_cancellable.cancel ();
        }
        lbl_status.set_text (_("已停止"));
        set_busy (false);
    }

    private void on_input_changed () {
        Gtk.TextIter cursor_iter;
        input_view.get_buffer ().get_iter_at_mark (out cursor_iter, input_view.get_buffer ().get_insert ());
        Gtk.TextIter line_start = cursor_iter;
        line_start.set_line_offset (0);
        string line_text = line_start.get_text (cursor_iter);

        if (line_text.has_prefix ("/t") || line_text.has_prefix ("/template")) {
            string query = "";
            if (line_text.has_prefix ("/template ")) {
                query = line_text.substring (10).strip ();
            } else if (line_text.has_prefix ("/t ")) {
                query = line_text.substring (3).strip ();
            } else if (line_text == "/t" || line_text == "/template") {
                query = "";
            } else {
                query = line_text.has_prefix ("/template") ? line_text.substring (9) : line_text.substring (2);
            }
            show_completion (query);
        } else {
            hide_completion ();
        }
    }

    private void show_completion (string query) {
        while (completion_list.get_first_child () != null) {
            completion_list.remove (completion_list.get_first_child ());
        }

        var templates = ConfigManager.load_templates ();
        int match_count = 0;

        foreach (var tpl in templates) {
            if (query == "" || tpl.id.down ().contains (query.down ()) || tpl.name.down ().contains (query.down ())) {
                var row = new Adw.ActionRow ();
                row.set_title (tpl.name);
                row.set_subtitle ("/" + tpl.id + "  •  " + tpl.description);
                row.set_activatable (true);
                row.set_data<string> ("template_id", tpl.id);

                var click = new Gtk.GestureClick ();
                click.set_button (Gdk.BUTTON_PRIMARY);
                click.pressed.connect ((n_press, x, y) => {
                    apply_completion (row);
                });
                row.add_controller (click);

                completion_list.append (row);
                match_count++;
            }
        }

        if (match_count > 0) {
            completion_frame.visible = true;
            completion_list.select_row (completion_list.get_first_child () as Gtk.ListBoxRow);
        } else {
            hide_completion ();
        }
    }

    private void hide_completion () {
        completion_frame.visible = false;
    }

    private void move_completion_selection (int direction) {
        var selected = completion_list.get_selected_row ();
        if (selected == null) {
            if (direction > 0) {
                completion_list.select_row (completion_list.get_first_child () as Gtk.ListBoxRow);
            }
            return;
        }
        Gtk.Widget? next = direction > 0 ? selected.get_next_sibling () : selected.get_prev_sibling ();
        if (next != null && next is Gtk.ListBoxRow) {
            completion_list.select_row ((Gtk.ListBoxRow) next);
        }
    }

    private void apply_completion (Gtk.ListBoxRow row) {
        string id = row.get_data<string> ("template_id");
        hide_completion ();
        input_view.get_buffer ().set_text ("", 0);
        execute_template_by_id (id);
    }

    private void execute_template_by_id (string id) {
        var templates = ConfigManager.load_templates ();
        PromptTemplate? tpl = null;
        foreach (var t in templates) {
            if (t.id == id) { tpl = t; break; }
        }

        if (tpl == null) {
            render_system (_("未找到模板: %s").printf (id));
            return;
        }

        template_triggered (tpl.header_text, tpl.footer_text);
        send_user_message (_("[应用模板: %s]\n%s").printf (tpl.name, tpl.ai_prompt));
    }

    private void on_send () {
        if (busy) return;

        Gtk.TextBuffer buf = input_view.get_buffer ();
        Gtk.TextIter start, end;
        buf.get_bounds (out start, out end);
        string text = buf.get_text (start, end, false).strip ();
        if (text.length == 0) return;

        if (text.has_prefix ("/template ") || text.has_prefix ("/t ") || text == "/template" || text == "/t") {
            buf.set_text ("", 0);
            hide_completion ();
            string[] parts = text.split (" ", 2);
            string id = parts.length > 1 ? parts[1].strip () : "";
            execute_template_by_id (id);
            return;
        }

        if (client == null) {
            if (!ai_enabled) {
                render_system (_("请先在 设置 → AI 设置 中启用 AI 助手。"));
            } else {
                render_system (_("请先在 设置 → AI 设置 中配置 API。"));
            }
            return;
        }

        buf.set_text ("", 0);
        send_user_message (text);
    }

    private void on_clear_chat () {
        Gtk.Widget? child = chat_container.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            chat_container.remove (child);
            child = next;
        }
        messages_lock.lock ();
        messages.clear ();
        messages_lock.unlock ();
        rendered.clear ();
        tool_counter = 0;
        pending_welcome = true;
    }

    private void on_revert_requested (int token, string text) {
        if (token < 0) return;

        var dialog = new Adw.AlertDialog (
            _("确认撤回"),
            _("这将撤销此消息之后 AI 的所有回复以及对文件列表的修改。是否继续？")
        );
        dialog.add_response ("cancel", _("取消"));
        dialog.add_response ("revert", _("撤回"));
        dialog.set_response_appearance ("revert", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_default_response ("cancel");

        dialog.response.connect ((response) => {
            if (response == "revert") {
                if (busy) {
                    request_stop ();
                }

                revert_to_undo_token (token);

                int revert_index = -1;
                for (int i = 0; i < rendered.size; i++) {
                    if (rendered.get (i).undo_token == token && rendered.get (i).role == "user") {
                        revert_index = i;
                        break;
                    }
                }

                if (revert_index >= 0) {
                    while (rendered.size > revert_index) {
                        rendered.remove_at (rendered.size - 1);
                    }

                    messages_lock.lock ();
                    messages.clear ();
                    messages_lock.unlock ();

                    rerender ();

                    input_view.get_buffer ().set_text (text, -1);
                    input_view.grab_focus ();
                }
            }
            dialog.destroy ();
        });

        dialog.present (parent_window);
    }


    // ─── 对话循环 ────────────────────────────────────────────────────────

    // 与 ai_client.py::build_system_prompt 行为 1:1 镜像
    private static string build_system_prompt (AISystemSnapshot snap) {
        string work_dir_str = (snap.work_dir != null && snap.work_dir.length > 0)
                              ? snap.work_dir : "(not set)";
        int file_count = snap.selected_paths != null ? snap.selected_paths.length : 0;
        int text_count = snap.custom_instructions != null ? snap.custom_instructions.length : 0;
        string path_mode = snap.use_absolute ? "absolute" : "relative";
        string header_mode = snap.show_header ? "on" : "off";

        var item_block = new StringBuilder ();
        if (file_count + text_count == 0) {
            item_block.append ("  (empty)");
        } else {
            if (snap.selected_paths != null) {
                for (int i = 0; i < snap.selected_paths.length; i++) {
                    string p = snap.selected_paths[i] ?? "";
                    string name = GLib.Path.get_basename (p);
                    if (name.length == 0) name = p;
                    string tag = snap.use_absolute ? "abs" : "rel";
                    item_block.append ("  [").append (i.to_string ())
                              .append ("] file(").append (tag).append ("): ")
                              .append (name).append ("\n");
                }
            }
            if (snap.custom_instructions != null) {
                int text_idx = 0;
                for (int i = 0; i < snap.custom_instructions.length; i++) {
                    string txt = snap.custom_instructions[i] ?? "";
                    if (txt.length == 0) continue;
                    string preview = txt;
                    if (preview.length > 40) preview = truncate_utf8 (preview, 40) + "…";
                    // 用 split/join 替代 string.replace, 避免 Vala 的 Regex 实现在某些情况下 assert_not_reached
                    preview = string.joinv (" ", preview.split ("\n"));
                    item_block.append ("  [").append ((file_count + text_idx).to_string ())
                              .append ("] text: ").append (preview).append ("\n");
                    text_idx++;
                }
            }
        }

        return (
            "You are the AI assistant for FileCollector, a file-collecting and "
            + "orchestration tool. The user picks files in a working directory; you "
            + "understand their intent and use the provided tools to manipulate the "
            + "orchestration list.\n\n"
            + "Current state:\n"
            + "- Work directory: " + work_dir_str + "\n"
            + "- Orchestration list: " + (file_count + text_count).to_string ()
            +   " item(s) (" + file_count.to_string () + " file(s), "
            +   text_count.to_string () + " text block(s))\n"
            + "- Path mode: " + path_mode + "\n"
            + "- Header info: " + header_mode + "\n"
            + "- List contents:\n" + item_block.str + "\n"
            + "Available tools:\n"
            + "- set_work_dir(path): switch the working directory (clears the list)\n"
            + "- list_files(pattern?, directory?, max_depth?, max_results?): scan a directory for files; "
            + "pattern is a case-insensitive glob on the file name. Use this to explore before adding.\n"
            + "- read_file(path, start_line?, max_lines?, max_bytes?): read a file's text content "
            + "with 1-based line numbers. Use to inspect a file before deciding whether to add it, "
            + "or to look up specific information (config values, doc strings, etc.). Binary files are rejected.\n"
            + "- list_items(kind?, max_items?): inspect the current orchestration list; "
            + "kind='file' or 'text' to filter. Always call this after add_files / add_text / "
            + "move_item / remove_item to verify the result before telling the user what was done.\n"
            + "- add_files(paths): add files (absolute paths required; missing files are skipped)\n"
            + "- add_text(text, position?): insert a text block (appends if position is omitted)\n"
            + "- remove_item(index): delete an item by 0-based index\n"
            + "- move_item(from_index, to_index): move an item\n"
            + "- clear_items(): empty the orchestration list\n"
            + "- set_use_absolute(value): toggle absolute/relative path mode\n"
            + "- set_show_header(value): toggle writing the work-directory header in exports\n"
            + "- get_git_status(): check what files are modified/untracked in the working tree.\n"
            + "- get_git_diff(staged?): read the exact code changes to understand the user's current task.\n"
            + "- get_git_log(max_count?): list recent commits to find historical context.\n"
            + "- get_git_commit_diff(commit_hash): inspect the code changes of a specific past commit.\n"
            + "- add_git_diff(staged?): inject the current Git diff directly into the list (bypasses LLM context, saves tokens).\n"
            + "- add_git_commit_diff(commit_hash): inject a specific commit's diff directly into the list.\n\n"
            + "Workflow rules:\n"
            + "1. Prefer tool calls over asking the user for paths you can discover yourself. "
            + "If the user says 'add all files about X' or 'find files matching Y', call "
            + "list_files first with a sensible pattern (e.g. '*x*'), inspect the results, "
            + "then call add_files with the chosen absolute paths in batches.\n"
            + "2. NEVER add a file based on its name alone. After list_files, the result is a "
            + "CANDIDATE set. For each candidate you intend to add (or when in doubt), call "
            + "read_file with max_lines=30-50 to peek at the top of the file — module docstring, "
            + "imports, class/function names, config schema — to confirm it really matches the "
            + "user's intent. Skip this only for very short, unambiguous files (e.g. a single "
            + "README.md whose first line clearly states the topic).\n"
            + "3. Pass absolute paths to add_files. The server decides how to store them: files "
            + "inside the current work directory are stored as relative paths and reflected as "
            + "checked items in the file tree; files outside the work directory are stored as "
            + "absolute paths and will not appear in the file tree.\n"
            + "4. The UI refreshes in real time after each tool call, so the user can see results immediately.\n"
            + "5. After any mutation (add_files / add_text / move_item / remove_item / clear_items), "
            + "call list_items to confirm what actually landed in the list before reporting to the user. "
            + "If something is missing or wrong, fix it in the same turn — don't assume success.\n"
            + "6. Be concise and professional. Reply in the same language the user uses. "
            + "When no tool call is needed, just explain in natural language.\n"
            + "7. When the user asks to 'collect files for my current PR' or 'gather context for "
            + "the bug I just fixed', ALWAYS call `get_git_status` and `get_git_diff` first. "
            + "Analyze the diff to identify ALL related files (including headers, configs, or "
            + "test files that might not show up in the diff but are relevant), then use "
            + "`add_files` to collect them.\n"
            + "8. CRITICAL: When the user asks to 'export diff', 'add changes to context', or 'collect PR diff', "
            + "NEVER use `get_git_diff` combined with `add_text`. Passing large diffs through the LLM context wastes tokens "
            + "and risks API truncation. ALWAYS use the dedicated `add_git_diff` or `add_git_commit_diff` tools. "
            + "These tools fetch the diff locally and inject it into the list bypassing the LLM context entirely."
        );
    }

    private void send_user_message (string text) {
        int token = get_undo_token ();
        rebuild_system_message ();
        messages_lock.lock ();
        messages.add (build_chat_node ("user", text));
        messages_lock.unlock ();
        render_user (text, token);
        next_turn ();
    }

    private void rebuild_system_message () {
        // 移除已有 system 消息 (加锁保护并发读写)
        messages_lock.lock ();
        var keep = new Gee.ArrayList<Json.Node> ();
        foreach (var m in messages) {
            if (get_role (m) != "system") keep.add (m);
        }
        messages = keep;
        messages_lock.unlock ();
        if (state_provider == null) return;
        var snap = state_provider ();
        string prompt;
        if (system_prompt_override.length > 0) {
            prompt = system_prompt_override + "\n\n" + build_system_prompt (snap);
        } else {
            prompt = build_system_prompt (snap);
        }
        messages_lock.lock ();
        messages.insert (0, build_chat_node ("system", prompt));
        messages_lock.unlock ();
    }

    private static string get_role (Json.Node n) {
        if (n.get_node_type () != Json.NodeType.OBJECT) return "";
        return n.get_object ().get_string_member_with_default ("role", "");
    }

    private static Json.Node build_chat_node (string role, string content) {
        var o = new Json.Object ();
        o.set_string_member ("role", role);
        o.set_string_member ("content", content ?? "");
        return AI.SchemaHelper.obj_to_node (o);
    }

    private void next_turn () {
        if (client == null) return;
        set_busy (true);

        // 浅拷贝消息列表传给 worker 线程, 避免读写竞争 (加锁保护遍历)
        var msgs_copy = new Gee.ArrayList<Json.Node> ();
        messages_lock.lock ();
        foreach (var m in messages) msgs_copy.add (m);
        messages_lock.unlock ();

        stop_requested = false;
        request_cancellable = new GLib.Cancellable ();
        worker_thread = new GLib.Thread<void> ("ai-worker", () => {
            run_worker.begin (msgs_copy);
        });
    }

    private async void run_worker (Gee.ArrayList<Json.Node> msgs) {
        AIClient local = client;
        if (local == null) {
            on_api_failed (_("客户端未配置"));
            return;
        }
        try {
            var result = local.chat (msgs, build_full_tool_schema (), request_cancellable);
            if (stop_requested) {
                GLib.Idle.add (() => { set_busy (false); return GLib.Source.REMOVE; });
                return;
            }
            yield on_api_finished (result);
        } catch (Error e) {
            if (stop_requested) {
                GLib.Idle.add (() => { set_busy (false); return GLib.Source.REMOVE; });
                return;
            }
            on_api_failed (e.message);
        }
    }

    private async void on_api_finished (AIChatResult result) {
        // 网络响应目前在 worker 线程; 先通过 yield 切换到主线程,
        // 后续所有 GTK/状态操作都在主线程执行, 避免跨线程访问 GTK4 widget.
        if (!GLib.MainContext.default ().is_owner ()) {
            GLib.Idle.add (() => {
                on_api_finished.callback ();
                return GLib.Source.REMOVE;
            });
            yield;
        }
        if (stop_requested) {
            set_busy (false);
            return;
        }

        // 数据: 构建 assistant 消息并写入历史
        var assistant_msg = new Json.Object ();
        assistant_msg.set_string_member ("role", "assistant");
        assistant_msg.set_string_member ("content", result.content ?? "");
        if (result.tool_calls.size > 0) {
            var arr = new Json.Array ();
            int idx = 0;
            foreach (var tc in result.tool_calls) {
                var tc_obj = new Json.Object ();
                tc_obj.set_string_member ("id", tc.id);
                tc_obj.set_string_member ("type", "function");
                var fn = new Json.Object ();
                fn.set_string_member ("name", tc.name);
                fn.set_string_member ("arguments", tc.arguments_json);
                tc_obj.set_member ("function", AI.SchemaHelper.obj_to_node (fn));
                tc_obj.set_int_member ("index", idx++);
                arr.add_object_element (tc_obj);
            }
            assistant_msg.set_member ("tool_calls", AI.SchemaHelper.arr_to_node (arr));
        }
        messages_lock.lock ();
        messages.add (AI.SchemaHelper.obj_to_node (assistant_msg));
        messages_lock.unlock ();

        if (result.content.length > 0) {
            render_assistant (result.content);
        }

        if (stop_requested) return;

        if (result.tool_calls.size > 0) {
            foreach (var tc in result.tool_calls) {
                if (stop_requested) break;
                string args_repr = format_tool_args (tc.name, tc.arguments_json);
                string result_str = yield execute_tool_async (tc.name, tc.arguments_json);
                if (stop_requested) break;
                render_tool (tc.name, args_repr, result_str);
                messages_lock.lock ();
                messages.add (build_tool_response (tc.id, result_str));
                messages_lock.unlock ();
            }
            if (!stop_requested) {
                next_turn ();
            } else {
                set_busy (false);
            }
        } else {
            set_busy (false);
        }
    }

    // 异步工具执行: 若已在主线程则直接调用 tool_executor;
    // 否则通过 Idle 投递到主线程, yield 等待结果, 不阻塞 worker 线程.
    private async string execute_tool_async (string name, string args_json) {
        if (stop_requested) return "";
        if (GLib.MainContext.default ().is_owner ()) {
            try {
                if (tool_executor == null) return _("未配置工具执行器");
                return tool_executor (name, parse_args (args_json));
            } catch (Error e) {
                return _("执行出错: %s").printf (e.message);
            }
        }
        string result = "";
        GLib.Idle.add (() => {
            if (stop_requested) {
                result = "";
            } else {
                try {
                    if (tool_executor == null) {
                        result = _("未配置工具执行器");
                    } else {
                        result = tool_executor (name, parse_args (args_json));
                    }
                } catch (Error e) {
                    result = _("执行出错: %s").printf (e.message);
                }
            }
            execute_tool_async.callback ();
            return GLib.Source.REMOVE;
        });
        yield;
        return result;
    }

    private static Json.Node parse_args (string raw) {
        if (raw == null || raw.strip () == "") return AI.SchemaHelper.obj_to_node (new Json.Object ());
        var parser = new Json.Parser ();
        try {
            parser.load_from_data (raw, raw.length);
            var root = parser.get_root ();
            if (root != null && root.get_node_type () == Json.NodeType.OBJECT) {
                return root;
            }
        } catch (Error e) { warning ("Failed to parse JSON args: %s", e.message); }
        return AI.SchemaHelper.obj_to_node (new Json.Object ());
    }

    private static Json.Node build_tool_response (string tool_call_id, string content) {
        var o = new Json.Object ();
        o.set_string_member ("role", "tool");
        o.set_string_member ("tool_call_id", tool_call_id);
        o.set_string_member ("content", content ?? "");
        return AI.SchemaHelper.obj_to_node (o);
    }

    private void on_api_failed (string err) {
        GLib.Idle.add (() => {
            set_busy (false);
            render_system (_("调用失败: %s").printf (err));
            return GLib.Source.REMOVE;
        });
    }


    // ─── 工具参数格式化 (与 ai_panel._format_tool_args 1:1) ──────────────

    private static string format_tool_args (string name, string raw) {
        if (name == "add_files") {
            var arr = parse_args (raw);
            if (arr.get_node_type () == Json.NodeType.OBJECT) {
                var o = arr.get_object ();
                if (o.has_member ("paths")) {
                    var paths = o.get_array_member ("paths");
                    if (paths != null) {
                        var parts = new Gee.ArrayList<string> ();
                        int n = (int) paths.get_length ();
                        if (n <= 8) {
                            for (int i = 0; i < n; i++) {
                                parts.add ("\"" + paths.get_string_element (i) + "\"");
                            }
                            return "paths=[" + string.joinv (", ", (string[]) parts.to_array ()) + "]";
                        } else {
                            for (int i = 0; i < 5; i++) {
                                parts.add ("\"" + paths.get_string_element (i) + "\"");
                            }
                            return "paths=[" + string.joinv (", ", (string[]) parts.to_array ())
                                 + ", … (+%d more)".printf (n - 5) + "]";
                        }
                    }
                }
            }
        }
        if (name == "read_file") {
            var arr = parse_args (raw);
            if (arr.get_node_type () == Json.NodeType.OBJECT) {
                var o = arr.get_object ();
                string p = o.get_string_member_with_default ("path", "");
                var extras = new Gee.ArrayList<string> ();
                if (o.has_member ("start_line"))
                    extras.add ("start_line=%s".printf (o.get_int_member ("start_line").to_string ()));
                if (o.has_member ("max_lines"))
                    extras.add ("max_lines=%s".printf (o.get_int_member ("max_lines").to_string ()));
                if (o.has_member ("max_bytes"))
                    extras.add ("max_bytes=%s".printf (o.get_int_member ("max_bytes").to_string ()));
                if (extras.size > 0) {
                    return "\"" + p + "\", " + string.joinv (", ", (string[]) extras.to_array ());
                }
                return "\"" + p + "\"";
            }
        }
        if (name == "list_files") {
            var arr = parse_args (raw);
            if (arr.get_node_type () == Json.NodeType.OBJECT) {
                var o = arr.get_object ();
                var parts = new Gee.ArrayList<string> ();
                if (o.has_member ("pattern"))
                    parts.add ("pattern='" + o.get_string_member ("pattern") + "'");
                if (o.has_member ("directory"))
                    parts.add ("directory='" + o.get_string_member ("directory") + "'");
                if (o.has_member ("max_depth"))
                    parts.add ("max_depth=%s".printf (o.get_int_member ("max_depth").to_string ()));
                if (o.has_member ("max_results"))
                    parts.add ("max_results=%s".printf (o.get_int_member ("max_results").to_string ()));
                return parts.size > 0 ? string.joinv (", ", (string[]) parts.to_array ()) : "(no filter)";
            }
        }
        if (name == "list_items") {
            var arr = parse_args (raw);
            if (arr.get_node_type () == Json.NodeType.OBJECT) {
                var o = arr.get_object ();
                var parts = new Gee.ArrayList<string> ();
                if (o.has_member ("kind"))
                    parts.add ("kind='" + o.get_string_member ("kind") + "'");
                if (o.has_member ("max_items"))
                    parts.add ("max_items=%s".printf (o.get_int_member ("max_items").to_string ()));
                return parts.size > 0 ? string.joinv (", ", (string[]) parts.to_array ()) : "(all items)";
            }
        }
        // 默认: 直接展示原始 JSON
        return raw ?? "";
    }


    // ─── 状态 ────────────────────────────────────────────────────────────

    private void set_busy (bool b) {
        busy = b;
        if (b) {
            lbl_send.set_text (_("停止"));
            send_icon.icon_name = "media-playback-stop-symbolic";
            btn_send.remove_css_class ("suggested-action");
            btn_send.add_css_class ("destructive-action");
            lbl_status.set_text (_("正在思考..."));
        } else {
            lbl_send.set_text (_("发送"));
            send_icon.icon_name = "mail-send-symbolic";
            btn_send.remove_css_class ("destructive-action");
            btn_send.add_css_class ("suggested-action");
            update_status ();
        }
        input_view.set_editable (!b);
        input_view.set_cursor_visible (!b);
        btn_clear.set_sensitive (!b);
    }

    private void update_status () {
        if (!ai_enabled) {
            lbl_status.set_text (_("未启用"));
            lbl_status.remove_css_class ("ai-status-ok");
            lbl_status.add_css_class ("ai-status-warn");
        } else if (client == null) {
            lbl_status.set_text (_("未配置"));
            lbl_status.remove_css_class ("ai-status-ok");
            lbl_status.add_css_class ("ai-status-warn");
        } else {
            lbl_status.set_text (_("就绪"));
            lbl_status.remove_css_class ("ai-status-warn");
            lbl_status.add_css_class ("ai-status-ok");
        }
    }
}
