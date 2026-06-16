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
    private Gtk.Label lbl_test;
    private Gtk.Button btn_test;

    private ConfigManager.AISettings current;

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
        toolbar_view.set_content (prefs_page);

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
        prompt_row.set_show_apply_button (true);
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
        lbl_test = new Gtk.Label (null);
        lbl_test.valign = Gtk.Align.CENTER;
        lbl_test.add_css_class ("dim-label");
        lbl_test.set_wrap (true);
        lbl_test.set_xalign (1.0f);
        test_row.add_suffix (lbl_test);
        advanced_group.add (test_row);

        cancel_btn.clicked.connect (() => window.close ());
        ok_btn.clicked.connect (on_save);
        btn_test.clicked.connect (on_test);

        window.close_request.connect (() => {
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
        current = collect_from_ui ();
        ConfigManager.save_ai_settings (current);
        settings_changed ();
        window.close ();
    }

    private void on_test () {
        var s = collect_from_ui ();
        if (s.base_url == "" || s.api_key == "" || s.model == "") {
            lbl_test.set_text (_("请先填写 API 基础地址、密钥和模型名称。"));
            lbl_test.remove_css_class ("success");
            lbl_test.remove_css_class ("error");
            lbl_test.add_css_class ("error");
            return;
        }
        btn_test.set_sensitive (false);
        lbl_test.remove_css_class ("error");
        lbl_test.remove_css_class ("success");
        lbl_test.set_text (_("正在测试..."));

        // 异步发起测试请求, 不阻塞 UI
        var session = new Soup.Session ();
        session.timeout = (uint) (s.timeout > 0 ? s.timeout : 60.0);

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
        unowned uint8[] body_view = (uint8[]) body;
        var body_bytes = new Bytes (body_view);

        string url = s.base_url.has_suffix ("/") ? s.base_url + "chat/completions"
                                                 : s.base_url + "/chat/completions";
        var msg = new Soup.Message ("POST", url);
        msg.set_request_body_from_bytes ("application/json", body_bytes);
        msg.request_headers.append ("Content-Type", "application/json");
        msg.request_headers.append ("Authorization", "Bearer " + s.api_key);

        session.send_and_read_async (msg, GLib.Priority.DEFAULT, null, (obj, res) => {
            on_test_done (session, msg, res);
        });
    }

    private static Json.Object build_msg (string role, string content) {
        var o = new Json.Object ();
        o.set_string_member ("role", role);
        o.set_string_member ("content", content);
        return o;
    }

    private void on_test_done (Soup.Session session, Soup.Message msg, AsyncResult res) {
        btn_test.set_sensitive (true);
        try {
            var bytes = session.send_and_read_async.end (res);
            uint status = msg.status_code;
            if (status >= 200 && status < 300) {
                lbl_test.remove_css_class ("error");
                lbl_test.add_css_class ("success");
                lbl_test.set_text (_("✓ 连接成功"));
            } else {
                string detail = "";
                if (bytes != null && bytes.length > 0) {
                    detail = ((string) bytes.get_data ()).substring (0, (long) bytes.length);
                    if (detail.length > 200) detail = detail.substring (0, 200) + "…";
                }
                lbl_test.remove_css_class ("success");
                lbl_test.add_css_class ("error");
                lbl_test.set_text (_("✗ 失败: HTTP %u %s".printf (
                    status, Soup.status_get_phrase (status))
                    + (detail.length > 0 ? " — " + detail : "")));
            }
        } catch (Error e) {
            lbl_test.remove_css_class ("success");
            lbl_test.add_css_class ("error");
            lbl_test.set_text (_("✗ 失败: %s").printf (e.message));
        }
    }
}
