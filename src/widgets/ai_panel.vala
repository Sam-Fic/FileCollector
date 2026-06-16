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
    private Gtk.Button btn_clear;
    private Gtk.Label lbl_status;
    private Gtk.Label lbl_model;

    // 状态
    private AIClient? client;
    private string system_prompt_override = "";
    private AIToolExecutor? tool_executor;
    private AIStateProvider? state_provider;

    private GLib.Thread<void>? worker_thread = null;
    private bool busy = false;
    private bool stop_requested = false;
    private bool pending_welcome = true;

    private Gee.ArrayList<Json.Node> messages = new Gee.ArrayList<Json.Node> ();
    private Gee.ArrayList<AIMessage> rendered = new Gee.ArrayList<AIMessage> ();
    private int tool_counter = 0;

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
        chat_container.margin_start = 10;
        chat_container.margin_end = 10;
        chat_container.margin_top = 4;
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
        chat_scroll.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        root_box.append (chat_scroll);

        // ── 输入区 ──
        var input_frame = new Gtk.Frame (null);
        input_frame.add_css_class ("card");
        input_frame.add_css_class ("ai-input-frame");
        input_frame.margin_start = 8;
        input_frame.margin_end = 8;
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
        var placeholder_lbl = new Gtk.Label (_("输入指令, Ctrl+Enter 发送"));
        placeholder_lbl.add_css_class ("dim-label");
        placeholder_lbl.add_css_class ("ai-placeholder");
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
        // Ctrl+Enter 发送
        var key = new Gtk.EventControllerKey ();
        key.key_pressed.connect ((keyval, state) => {
            if (keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter) {
                if ((state & Gdk.ModifierType.CONTROL_MASK) != 0) {
                    on_send_or_stop ();
                    return true;
                }
            }
            return false;
        });
        input_view.add_controller (key);
        input_box.append (input_view);

        // 按钮行
        var btn_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        btn_clear = new Gtk.Button.with_label (_("清空对话"));
        btn_clear.set_size_request (90, 36);
        btn_clear.clicked.connect (on_clear_chat);
        btn_row.append (btn_clear);

        var spacer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        spacer.hexpand = true;
        btn_row.append (spacer);

        btn_send = new Gtk.Button.with_label (_("发送"));
        btn_send.add_css_class ("suggested-action");
        btn_send.set_size_request (90, 36);
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
        if (has_config) {
            client = new AIClient (base_url_str, api_key_str, model_str, timeout_v);
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
        if (worker_thread != null) {
            worker_thread.join ();
            worker_thread = null;
        }
    }


    // ─── 渲染 ────────────────────────────────────────────────────────────

    private void render_user (string text) {
        var msg = new AIMessage ("user", text);
        rendered.add (msg);
        rerender ();
    }

    private void render_assistant (string text) {
        var msg = new AIMessage ("assistant", text);
        rendered.add (msg);
        rerender ();
    }

    private void render_system (string text) {
        var msg = new AIMessage ("system", text);
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

    private void rerender () {
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
        // 滚到底
        GLib.Idle.add (() => {
            var adj = chat_scroll.get_vadjustment ();
            if (adj != null) {
                adj.set_value (adj.get_upper () - adj.get_page_size ());
            }
            return GLib.Source.REMOVE;
        });
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
            case "user":
            case "assistant":
            case "system": {
                var label = new Gtk.Label (msg.content);
                label.xalign = 0;
                label.wrap = true;
                label.wrap_mode = Pango.WrapMode.WORD_CHAR;
                label.selectable = true;
                label.add_css_class ("ai-bubble-content");
                bubble.append (label);
                break;
            }
            case "tool": {
                // 工具调用卡片: 头部 (icon + name + args + action) + body (result, 可折叠)
                var header_btn = new Gtk.Button ();
                header_btn.add_css_class ("flat");
                header_btn.add_css_class ("ai-tool-header");
                header_btn.set_size_request (-1, 32);
                header_btn.halign = Gtk.Align.FILL;

                var header_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
                var arrow = new Gtk.Label (msg.expanded ? "▼" : "▶");
                arrow.add_css_class ("ai-tool-arrow");
                arrow.valign = Gtk.Align.CENTER;
                header_box.append (arrow);

                var icon = new Gtk.Label ((msg.tool_name.length >= 2 ? msg.tool_name.substring (0, 2)
                                            : msg.tool_name).up ());
                icon.add_css_class ("ai-tool-icon");
                icon.valign = Gtk.Align.CENTER;
                header_box.append (icon);

                var name_lbl = new Gtk.Label (msg.tool_name);
                name_lbl.add_css_class ("ai-tool-name");
                name_lbl.valign = Gtk.Align.CENTER;
                header_box.append (name_lbl);

                var args_lbl = new Gtk.Label (msg.tool_args_repr);
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
                header_btn.clicked.connect (() => {
                    msg.expanded = !msg.expanded;
                    rerender ();
                });
                bubble.append (header_btn);

                if (msg.expanded) {
                    var body = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
                    body.add_css_class ("ai-tool-body");

                    var result_lbl = new Gtk.Label (msg.tool_result ?? "");
                    result_lbl.xalign = 0;
                    result_lbl.yalign = 0;
                    result_lbl.wrap = true;
                    result_lbl.wrap_mode = Pango.WrapMode.WORD_CHAR;
                    result_lbl.selectable = true;
                    result_lbl.add_css_class ("ai-tool-result");
                    body.append (result_lbl);
                    bubble.append (body);
                } else {
                    var preview = msg.tool_result ?? "";
                    if (preview.length > 80) preview = preview.substring (0, 80) + "…";
                    var preview_lbl = new Gtk.Label (preview);
                    preview_lbl.xalign = 0;
                    preview_lbl.wrap = true;
                    preview_lbl.add_css_class ("ai-tool-preview");
                    bubble.append (preview_lbl);
                }
                break;
            }
        }

        switch (msg.role) {
            case "user":
                var spacer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
                spacer.hexpand = true;
                outer.append (spacer);
                outer.append (bubble);
                break;
            case "tool":
            case "system": {
                var left = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
                left.hexpand = true;
                outer.append (left);
                outer.set_halign (Gtk.Align.CENTER);
                bubble.halign = Gtk.Align.CENTER;
                outer.append (bubble);
                var right = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
                right.hexpand = true;
                outer.append (right);
                break;
            }
            default:  // assistant
                outer.append (bubble);
                var spacer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
                spacer.hexpand = true;
                outer.append (spacer);
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
        lbl_status.set_text (_("已停止"));
        set_busy (false);
    }

    private void on_send () {
        if (busy) return;

        Gtk.TextBuffer buf = input_view.get_buffer ();
        Gtk.TextIter start, end;
        buf.get_bounds (out start, out end);
        string text = buf.get_text (start, end, false).strip ();
        if (text.length == 0) return;

        if (client == null) {
            render_system (_("请先在 设置 → AI 设置 中启用并配置 API。"));
            return;
        }

        render_user (text);
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
        messages.clear ();
        rendered.clear ();
        tool_counter = 0;
        pending_welcome = true;
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
                    if (preview.length > 40) preview = preview.substring (0, 40) + "…";
                    preview = preview.replace ("\n", " ");
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
            + "- set_show_header(value): toggle writing the work-directory header in exports\n\n"
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
            + "When no tool call is needed, just explain in natural language."
        );
    }

    private void send_user_message (string text) {
        rebuild_system_message ();
        messages.add (build_chat_node ("user", text));
        next_turn ();
    }

    private void rebuild_system_message () {
        // 移除已有 system 消息
        var keep = new Gee.ArrayList<Json.Node> ();
        foreach (var m in messages) {
            if (get_role (m) != "system") keep.add (m);
        }
        messages = keep;
        if (state_provider == null) return;
        var snap = state_provider ();
        string prompt;
        if (system_prompt_override.length > 0) {
            prompt = system_prompt_override + "\n\n" + build_system_prompt (snap);
        } else {
            prompt = build_system_prompt (snap);
        }
        messages.insert (0, build_chat_node ("system", prompt));
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

        // 浅拷贝消息列表传给 worker 线程, 避免读写竞争
        var msgs_copy = new Gee.ArrayList<Json.Node> ();
        foreach (var m in messages) msgs_copy.add (m);

        stop_requested = false;
        worker_thread = new GLib.Thread<void> ("ai-worker", () => {
            run_worker (msgs_copy);
        });
    }

    private void run_worker (Gee.ArrayList<Json.Node> msgs) {
        AIClient local = client;
        if (local == null) {
            on_api_failed (_("客户端未配置"));
            return;
        }
        try {
            var result = local.chat (msgs, build_full_tool_schema ());
            if (stop_requested) return;
            on_api_finished (result);
        } catch (Error e) {
            if (stop_requested) return;
            on_api_failed (e.message);
        }
    }

    private void on_api_finished (AIChatResult result) {
        // 把 assistant 消息写回历史
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
        messages.add (AI.SchemaHelper.obj_to_node (assistant_msg));

        if (result.content.length > 0) {
            render_assistant (result.content);
        }

        if (result.tool_calls.size > 0) {
            // 同步执行所有工具, 写回 tool 消息
            foreach (var tc in result.tool_calls) {
                string args_repr = format_tool_args (tc.name, tc.arguments_json);
                var args_node = parse_args (tc.arguments_json);
                string result_str;
                try {
                    if (tool_executor == null) {
                        result_str = _("未配置工具执行器");
                    } else {
                        result_str = tool_executor (tc.name, args_node);
                    }
                } catch (Error e) {
                    result_str = _("执行出错: %s").printf (e.message);
                }
                render_tool (tc.name, args_repr, result_str);
                messages.add (build_tool_response (tc.id, result_str));
            }
            // 继续下一轮让 LLM 总结
            next_turn ();
        } else {
            set_busy (false);
        }
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
        } catch (Error e) { /* ignore */ }
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
                var paths = arr.get_object ().get_array_member ("paths");
                if (paths != null) {
                    var parts = new Gee.ArrayList<string> ();
                    int n = (int) paths.get_length ();
                    if (n <= 8) {
                        for (int i = 0; i < n; i++) {
                            parts.add ("\"" + paths.get_string_element (i) + "\"");
                        }
                        return "paths=[" + string.joinv (", ", parts.to_array ()) + "]";
                    } else {
                        for (int i = 0; i < 5; i++) {
                            parts.add ("\"" + paths.get_string_element (i) + "\"");
                        }
                        return "paths=[" + string.joinv (", ", parts.to_array ())
                             + ", … (+%d more)".printf (n - 5) + "]";
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
                    extras.add ("start_line=%lld".printf (o.get_int_member ("start_line")));
                if (o.has_member ("max_lines"))
                    extras.add ("max_lines=%lld".printf (o.get_int_member ("max_lines")));
                if (o.has_member ("max_bytes"))
                    extras.add ("max_bytes=%lld".printf (o.get_int_member ("max_bytes")));
                if (extras.size > 0) {
                    return "\"" + p + "\", " + string.joinv (", ", extras.to_array ());
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
                    parts.add ("max_depth=%lld".printf (o.get_int_member ("max_depth")));
                if (o.has_member ("max_results"))
                    parts.add ("max_results=%lld".printf (o.get_int_member ("max_results")));
                return parts.size > 0 ? string.joinv (", ", parts.to_array ()) : "(no filter)";
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
                    parts.add ("max_items=%lld".printf (o.get_int_member ("max_items")));
                return parts.size > 0 ? string.joinv (", ", parts.to_array ()) : "(all items)";
            }
        }
        // 默认: 直接展示原始 JSON
        return raw ?? "";
    }


    // ─── 状态 ────────────────────────────────────────────────────────────

    private void set_busy (bool b) {
        busy = b;
        if (b) {
            btn_send.set_label (_("停止"));
            btn_send.remove_css_class ("suggested-action");
            btn_send.add_css_class ("destructive-action");
            lbl_status.set_text (_("正在思考..."));
        } else {
            btn_send.set_label (_("发送"));
            btn_send.remove_css_class ("destructive-action");
            btn_send.add_css_class ("suggested-action");
            update_status ();
        }
        input_view.set_editable (!b);
        input_view.set_cursor_visible (!b);
        btn_clear.set_sensitive (!b);
    }

    private void update_status () {
        if (client == null) {
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
