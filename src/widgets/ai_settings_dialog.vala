/* AI 助手设置对话框.
 *
 * 与多平台版本 ai_settings_dialog.py 行为 1:1:
 *  - 启用开关 / API 基础地址 / 密钥 / 模型名 / 超时 / 自定义提示词
 *  - 写入 settings.json 的 ``ai`` 字段
 *  - 测试连接按钮在线调用一次, 反馈成功 / 失败原因
 *
 * UI 用 Adw.PreferencesPage 风格, 跟现有 设置 弹窗 / 常用语 弹窗保持一致
 * (都是 transient Adw.Window + 工具栏布局).
 */

using GLib;
using Gtk;
using Adw;
using Json;
using Soup;
using Gee;

public class AISettingsDialog : GLib.Object {
    public signal void settings_changed ();

    private Adw.Window? window;
    private Gtk.Window? parent_window;

    // 控件引用
    private Gtk.Switch chk_enabled;
    private Adw.EntryRow edit_base_url;
    private Adw.PasswordEntryRow edit_api_key;
    private Adw.EntryRow edit_model;
    private Adw.SpinRow spin_timeout;
    private Adw.EntryRow edit_prompt;
    private Adw.EntryRow edit_ignored_dirs;
    private Gtk.Button btn_test;
    private Adw.ToastOverlay toast_overlay;

    private ConfigManager.AISettings current;

    // 测试连接用的 Session: 提升为成员变量, 避免异步请求完成前局部变量超出作用域被回收
    private Soup.Session? test_session = null;
    // 测试连接用的 Cancellable: 关闭对话框时取消请求, 防止回调访问已销毁的 widget
    private GLib.Cancellable? test_cancellable = null;

    public AISettingsDialog (Gtk.Window? parent) {
        this.parent_window = parent;
        this.current = ConfigManager.load_ai_settings ();
    }

    public void present () {
        if (window != null) {
            window.present ();
            return;
        }
        build_ui ();
        load_into_ui ();
        window.present ();
    }

    private void build_ui () {
        window = new Adw.Window ();
        window.set_transient_for (parent_window);
        window.set_modal (true);
        window.set_default_size (520, 540);
        window.set_title (_("AI 助手设置"));

        var toolbar_view = new Adw.ToolbarView ();
        window.set_content (toolbar_view);

        var header = new Adw.HeaderBar ();
        header.set_decoration_layout ("");
        toolbar_view.add_top_bar (header);

        var cancel_btn = new Gtk.Button ();
        cancel_btn.set_label (_("取消"));
        header.pack_start (cancel_btn);

        var ok_btn = new Gtk.Button ();
        ok_btn.set_label (_("保存"));
        ok_btn.add_css_class ("suggested-action");
        header.pack_end (ok_btn);

        // 主区域: PreferencesPage
        var prefs_page = new Adw.PreferencesPage ();

        // ── 通用组 ──
        var general_group = new Adw.PreferencesGroup ();
        general_group.set_title (_("通用"));
        general_group.set_description (
            _("配置 OpenAI 兼容 API, 即可在 AI 边栏使用自然语言编排文件。\n"
              + "支持 OpenAI、Azure OpenAI、Microsoft Foundry 上的 Fast Context 等特化模型, "
              + "以及任何兼容端点 (例如本地 Ollama)。"));
        prefs_page.add (general_group);

        // 启用
        var enabled_row = new Adw.ActionRow ();
        enabled_row.set_title (_("启用 AI 助手"));
        enabled_row.set_subtitle (_("关闭后 AI 边栏会保留, 但不会发送任何请求"));
        chk_enabled = new Gtk.Switch ();
        chk_enabled.valign = Gtk.Align.CENTER;
        enabled_row.add_suffix (chk_enabled);
        enabled_row.set_activatable_widget (chk_enabled);
        general_group.add (enabled_row);

        // 基础地址
        var base_url_row = new Adw.EntryRow ();
        base_url_row.set_title (_("API 基础地址"));
        base_url_row.set_show_apply_button (false);
        base_url_row.set_text (current.base_url);
        edit_base_url = base_url_row;
        general_group.add (base_url_row);

        // 密钥
        var api_key_row = new Adw.PasswordEntryRow ();
        api_key_row.set_title (_("API 密钥"));
        edit_api_key = api_key_row;
        general_group.add (api_key_row);

        // 模型
        var model_row = new Adw.EntryRow ();
        model_row.set_title (_("模型名称"));
        model_row.set_show_apply_button (false);
        edit_model = model_row;
        general_group.add (model_row);

        // 超时
        var timeout_row = new Adw.SpinRow.with_range (5.0, 600.0, 5.0);
        timeout_row.set_title (_("请求超时 (秒)"));
        timeout_row.set_value (current.timeout > 0 ? current.timeout : 60.0);
        spin_timeout = timeout_row;
        general_group.add (timeout_row);

        // 高级组
        var advanced_group = new Adw.PreferencesGroup ();
        advanced_group.set_title (_("高级"));
        prefs_page.add (advanced_group);

        var prompt_row = new Adw.EntryRow ();
        prompt_row.set_title (_("自定义系统提示词"));
        prompt_row.set_show_apply_button (false);
        edit_prompt = prompt_row;
        advanced_group.add (prompt_row);

        // 测试连接
        var test_row = new Adw.ActionRow ();
        test_row.set_title (_("测试连接"));
        test_row.set_subtitle (_("用当前配置向 API 发送一次最小请求, 验证是否可用"));

        btn_test = new Gtk.Button.with_label (_("测试"));
        btn_test.valign = Gtk.Align.CENTER;
        btn_test.add_css_class ("suggested-action");
        test_row.add_suffix (btn_test);
        advanced_group.add (test_row);

        // 扫描忽略目录组
        var ignored_group = new Adw.PreferencesGroup ();
        ignored_group.set_title (_("扫描忽略目录"));
        ignored_group.set_description (
            _("AI 扫描工作目录时将跳过这些目录名，用英文逗号分隔。"));
        prefs_page.add (ignored_group);

        var ignored_row = new Adw.EntryRow ();
        ignored_row.set_title (_("忽略的目录名"));
        ignored_row.set_show_apply_button (false);
        string[] current_ignored = ConfigManager.get_ignored_dirs ();
        ignored_row.set_text (string.joinv (", ", current_ignored));
        edit_ignored_dirs = ignored_row;
        ignored_group.add (ignored_row);

        // 安全警告组
        var security_group = new Adw.PreferencesGroup ();
        security_group.set_title (_("安全警告"));
        prefs_page.add (security_group);

        var security_row = new Adw.ActionRow ();
        security_row.set_title (_("HTTP 端点安全风险"));
        security_row.set_subtitle (_("使用 HTTP (非 HTTPS) 端点时，API 密钥将在网络中明文传输，存在安全风险。"));

        var warning_icon = new Gtk.Image.from_icon_name ("dialog-warning-symbolic");
        warning_icon.add_css_class ("warning");
        warning_icon.valign = Gtk.Align.CENTER;
        security_row.add_prefix (warning_icon);

        security_group.add (security_row);

        // Toast overlay
        toast_overlay = new Adw.ToastOverlay ();
        toast_overlay.set_child (prefs_page);
        toolbar_view.set_content (toast_overlay);

        cancel_btn.clicked.connect (() => window.close ());
        ok_btn.clicked.connect (on_save);
        btn_test.clicked.connect (on_test);

        window.close_request.connect (() => {
            // 取消正在进行的测试请求, 防止回调访问已销毁的 widget
            if (test_cancellable != null) {
                test_cancellable.cancel ();
                test_cancellable = null;
            }
            if (test_session != null) {
                test_session.abort ();
                test_session = null;
            }
            window = null;
            return false;
        });
    }

    private void load_into_ui () {
        chk_enabled.set_active (current.enabled);
        edit_base_url.set_text (current.base_url ?? "");
        edit_api_key.set_text (current.api_key ?? "");
        edit_model.set_text (current.model ?? "");
        spin_timeout.set_value (current.timeout > 0 ? current.timeout : 60.0);
        edit_prompt.set_text (current.system_prompt_override ?? "");
    }

    private ConfigManager.AISettings collect_from_ui () {
        var s = ConfigManager.AISettings () {
            enabled = chk_enabled.get_active (),
            base_url = edit_base_url.get_text ().strip (),
            api_key = edit_api_key.get_text ().strip (),
            model = edit_model.get_text ().strip (),
            system_prompt_override = edit_prompt.get_text (),
            timeout = spin_timeout.get_value ()
        };
        return s;
    }

    private void on_save () {
        var s = collect_from_ui ();
        if (s.base_url.has_prefix ("http://") && !s.base_url.has_prefix ("https://")) {
            show_http_warning_dialog (s);
        } else {
            save_settings (s);
        }
    }

    private void show_http_warning_dialog (ConfigManager.AISettings s) {
        var warning_dialog = new Adw.AlertDialog (
            _("安全警告"),
            _("您正在配置 HTTP (非 HTTPS) 端点。\n\n"
              + "这将导致 API 密钥在传输过程中以明文形式发送，存在被第三方截获的风险。\n\n"
              + "建议使用 HTTPS 端点以确保安全。\n\n"
              + "是否仍要继续保存？")
        );

        warning_dialog.add_response ("cancel", _("取消"));
        warning_dialog.add_response ("continue", _("继续保存"));
        warning_dialog.set_response_appearance ("continue", Adw.ResponseAppearance.DESTRUCTIVE);
        warning_dialog.set_default_response ("cancel");
        warning_dialog.set_close_response ("cancel");

        warning_dialog.response.connect ((response) => {
            if (response == "continue") {
                save_settings (s);
            }
            warning_dialog.destroy ();
        });

        warning_dialog.present (window);
    }

    private void save_settings (ConfigManager.AISettings s) {
        current = s;
        ConfigManager.save_ai_settings (current);

        // 保存忽略目录列表
        string raw_text = edit_ignored_dirs.get_text ();
        string[] parts = raw_text.split (",");
        var clean_list = new Gee.ArrayList<string> ();
        foreach (unowned string p in parts) {
            string trimmed = p.strip ();
            if (trimmed.length > 0) {
                clean_list.add (trimmed);
            }
        }
        ConfigManager.save_ignored_dirs ((string[]) clean_list.to_array ());

        settings_changed ();
        window.close ();
    }

    private void show_toast (string title) {
        var toast = new Adw.Toast (title);
        toast.timeout = 3;
        toast_overlay.add_toast (toast);
    }

    private void on_test () {
        var s = collect_from_ui ();
        if (s.base_url == "" || s.api_key == "" || s.model == "") {
            show_toast (_("请先填写 API 基础地址、密钥和模型名称。"));
            return;
        }
        btn_test.set_sensitive (false);
        show_toast (_("正在测试..."));

        // 异步发起测试请求, 不阻塞 UI
        // Session 存为成员变量, 确保异步回调执行时引用仍然有效
        test_session = new Soup.Session ();
        test_session.timeout = (uint) (s.timeout > 0 ? s.timeout : 60.0);
        test_cancellable = new GLib.Cancellable ();

        var payload = new Json.Object ();
        payload.set_string_member ("model", s.model);
        var msgs = new Json.Array ();
        msgs.add_object_element (build_msg ("system", "ping"));
        msgs.add_object_element (build_msg ("user", "hi"));
        payload.set_member ("messages", AI.SchemaHelper.arr_to_node (msgs));

        var gen = new Json.Generator ();
        gen.set_root (AI.SchemaHelper.obj_to_node (payload));
        gen.pretty = false;
        size_t body_len = 0;
        string body = gen.to_data (out body_len);
        uint8[] body_buf = new uint8[body_len];
        GLib.Memory.copy (body_buf, body, body_len);
        var body_bytes = new Bytes (body_buf);

        string url = s.base_url.has_suffix ("/") ? s.base_url + "chat/completions"
                                                 : s.base_url + "/chat/completions";
        var msg = new Soup.Message ("POST", url);
        msg.set_request_body_from_bytes ("application/json", body_bytes);
        msg.request_headers.append ("Content-Type", "application/json");
        msg.request_headers.append ("Authorization", "Bearer " + s.api_key);

        test_session.send_and_read_async (msg, GLib.Priority.DEFAULT, test_cancellable, (obj, res) => {
            on_test_done (test_session, msg, res);
        });
    }

    private static Json.Object build_msg (string role, string content) {
        var o = new Json.Object ();
        o.set_string_member ("role", role);
        o.set_string_member ("content", content);
        return o;
    }

    private void on_test_done (Soup.Session session, Soup.Message msg, AsyncResult res) {
        // 窗口已关闭时不再访问 widget, 防止 use-after-free
        if (window == null) {
            test_session = null;
            test_cancellable = null;
            return;
        }
        btn_test.set_sensitive (true);
        try {
            var bytes = session.send_and_read_async.end (res);
            uint status = msg.status_code;
            if (status >= 200 && status < 300) {
                show_toast (_("✓ 连接成功"));
            } else {
                string detail = "";
                if (bytes != null && bytes.length > 0) {
                    try {
                        uint8[] raw = bytes.get_data ();
                        int safe_len = (int) int64.min (bytes.length, 4096);
                        detail = ((string) raw).substring (0, safe_len);
                    } catch (Error e) { warning ("Failed to read error response body: %s", e.message); }
                    if (detail.length > 200) detail = detail.substring (0, 200) + "…";
                }
                string phrase = Soup.status_get_phrase (status);
                string msg_str = _("✗ 失败: HTTP %u %s").printf (status, phrase)
                    + (detail.length > 0 ? " — " + detail : "");
                show_toast (msg_str);
            }
        } catch (Error e) {
            show_toast (_("✗ 失败: %s").printf (e.message));
        }
        // 请求完成, 释放 Session 引用
        test_session = null;
    }
}
