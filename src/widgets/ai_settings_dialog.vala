/* AI 助手设置对话框.
 *
 * 整合侧边栏 AI 与多模态 AI 设置于同一入口:
 *  Section 1 — 侧边栏 AI 助手 (文本编排)
 *  Section 2 — 多模态 AI (二进制文件→Markdown 预处理)
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

    // ── 侧边栏 AI 控件 ──
    private Gtk.Switch chk_sidebar_enabled;
    private Adw.EntryRow edit_sidebar_base_url;
    private Adw.PasswordEntryRow edit_sidebar_api_key;
    private Adw.EntryRow edit_sidebar_model;
    private Adw.SpinRow spin_sidebar_timeout;
    private Adw.EntryRow edit_sidebar_prompt;
    private Gtk.Button btn_sidebar_test;

    // ── 多模态 AI 控件 ──
    private Gtk.Switch chk_mm_enabled;
    private Adw.EntryRow edit_mm_base_url;
    private Adw.PasswordEntryRow edit_mm_api_key;
    private Adw.EntryRow edit_mm_model;
    private Adw.SpinRow spin_mm_timeout;
    private Adw.EntryRow edit_mm_prompt;
    private Gtk.Button btn_mm_test;
    private Adw.EntryRow edit_mm_allowed_exts;
    private Gtk.Button btn_mm_reset_exts;

    // ── 共享 ──
    private Adw.EntryRow edit_ignored_dirs;
    private Adw.ToastOverlay toast_overlay;

    private ConfigManager.AISettings sidebar_current;
    private ConfigManager.MultimodalAISettings mm_current;

    private Soup.Session? test_session = null;
    private GLib.Cancellable? test_cancellable = null;
    private bool testing_sidebar = false;

    public AISettingsDialog (Gtk.Window? parent) {
        this.parent_window = parent;
        this.sidebar_current = ConfigManager.load_ai_settings ();
        this.mm_current = ConfigManager.load_multimodal_ai_settings ();
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
        window.set_default_size (520, 700);
        window.set_title (_("AI 设置"));

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

        var prefs_page = new Adw.PreferencesPage ();

        // ═══════════════════════════════════════════════════════
        // Section 1: 侧边栏 AI 助手
        // ═══════════════════════════════════════════════════════
        var sidebar_group = new Adw.PreferencesGroup ();
        sidebar_group.set_title (_("AI 助手 (侧边栏)"));
        sidebar_group.set_description (_("配置 OpenAI 兼容 API，即可在 AI 边栏使用自然语言编排文件。\n支持 OpenAI、Azure OpenAI 及任何兼容端点（例如本地 Ollama）。"));
        prefs_page.add (sidebar_group);

        var sb_enabled_row = new Adw.ActionRow ();
        sb_enabled_row.set_title (_("启用 AI 助手"));
        sb_enabled_row.set_subtitle (_("关闭后 AI 边栏会保留, 但不会发送任何请求"));
        chk_sidebar_enabled = new Gtk.Switch ();
        chk_sidebar_enabled.valign = Gtk.Align.CENTER;
        sb_enabled_row.add_suffix (chk_sidebar_enabled);
        sb_enabled_row.set_activatable_widget (chk_sidebar_enabled);
        sidebar_group.add (sb_enabled_row);

        var sb_url_row = new Adw.EntryRow ();
        sb_url_row.set_title (_("API 基础地址"));
        sb_url_row.set_show_apply_button (false);
        edit_sidebar_base_url = sb_url_row;
        sidebar_group.add (sb_url_row);

        var sb_key_row = new Adw.PasswordEntryRow ();
        sb_key_row.set_title (_("API 密钥"));
        edit_sidebar_api_key = sb_key_row;
        sidebar_group.add (sb_key_row);

        var sb_model_row = new Adw.EntryRow ();
        sb_model_row.set_title (_("模型名称"));
        sb_model_row.set_show_apply_button (false);
        edit_sidebar_model = sb_model_row;
        sidebar_group.add (sb_model_row);

        var sb_timeout_row = new Adw.SpinRow.with_range (5.0, 600.0, 5.0);
        sb_timeout_row.set_title (_("请求超时 (秒)"));
        spin_sidebar_timeout = sb_timeout_row;
        sidebar_group.add (sb_timeout_row);

        var sb_advanced = new Adw.PreferencesGroup ();
        sb_advanced.set_title (_("高级"));
        prefs_page.add (sb_advanced);

        var sb_prompt_row = new Adw.EntryRow ();
        sb_prompt_row.set_title (_("自定义系统提示词 (可选)"));
        sb_prompt_row.set_show_apply_button (false);
        edit_sidebar_prompt = sb_prompt_row;
        sb_advanced.add (sb_prompt_row);

        var sb_test_row = new Adw.ActionRow ();
        sb_test_row.set_title (_("测试连接"));
        sb_test_row.set_subtitle (_("验证侧边栏 AI 配置是否可用"));
        btn_sidebar_test = new Gtk.Button.with_label (_("测试"));
        btn_sidebar_test.valign = Gtk.Align.CENTER;
        btn_sidebar_test.add_css_class ("suggested-action");
        sb_test_row.add_suffix (btn_sidebar_test);
        sb_advanced.add (sb_test_row);

        // ═══════════════════════════════════════════════════════
        // Section 2: 多模态 AI
        // ═══════════════════════════════════════════════════════
        var mm_group = new Adw.PreferencesGroup ();
        mm_group.set_title (_("视觉语言大模型 (VLM) (二进制文件预处理)"));
        mm_group.set_description (
            _("配置视觉语言大模型 (VLM) API，用于将 PDF、Word、PPT、图片等文件转换为 Markdown。"));
        prefs_page.add (mm_group);

        var mm_enabled_row = new Adw.ActionRow ();
        mm_enabled_row.set_title (_("启用 VLM"));
        mm_enabled_row.set_subtitle (_("关闭后二进制文件将不会自动转换"));
        chk_mm_enabled = new Gtk.Switch ();
        chk_mm_enabled.valign = Gtk.Align.CENTER;
        mm_enabled_row.add_suffix (chk_mm_enabled);
        mm_enabled_row.set_activatable_widget (chk_mm_enabled);
        mm_group.add (mm_enabled_row);

        var mm_url_row = new Adw.EntryRow ();
        mm_url_row.set_title (_("API 基础地址"));
        mm_url_row.set_show_apply_button (false);
        edit_mm_base_url = mm_url_row;
        mm_group.add (mm_url_row);

        var mm_key_row = new Adw.PasswordEntryRow ();
        mm_key_row.set_title (_("API 密钥"));
        edit_mm_api_key = mm_key_row;
        mm_group.add (mm_key_row);

        var mm_model_row = new Adw.EntryRow ();
        mm_model_row.set_title (_("模型名称"));
        mm_model_row.set_show_apply_button (false);
        edit_mm_model = mm_model_row;
        mm_group.add (mm_model_row);

        var mm_timeout_row = new Adw.SpinRow.with_range (5.0, 600.0, 5.0);
        mm_timeout_row.set_title (_("请求超时 (秒)"));
        spin_mm_timeout = mm_timeout_row;
        mm_group.add (mm_timeout_row);

        var mm_advanced = new Adw.PreferencesGroup ();
        mm_advanced.set_title (_("高级"));
        prefs_page.add (mm_advanced);

        // 允许被 AI 转换的二进制文件扩展名 (以英文逗号分隔, 不含点或含点皆可, 如 ".pdf, png")
        var mm_exts_input_row = new Adw.EntryRow ();
        mm_exts_input_row.set_title (_("允许转换的二进制扩展名 (逗号分隔, 如 .pdf, .docx)"));
        mm_exts_input_row.set_show_apply_button (false);
        edit_mm_allowed_exts = mm_exts_input_row;
        mm_exts_input_row.set_hexpand (true);

        btn_mm_reset_exts = new Gtk.Button.with_label (_("默认"));
        btn_mm_reset_exts.valign = Gtk.Align.CENTER;
        btn_mm_reset_exts.set_tooltip_text (_("恢复为默认扩展名列表"));
        mm_exts_input_row.add_suffix (btn_mm_reset_exts);
        mm_advanced.add (mm_exts_input_row);

        var mm_prompt_row = new Adw.EntryRow ();
        mm_prompt_row.set_title (_("自定义系统提示词 (可选)"));
        mm_prompt_row.set_show_apply_button (false);
        edit_mm_prompt = mm_prompt_row;
        mm_advanced.add (mm_prompt_row);

        var mm_test_row = new Adw.ActionRow ();
        mm_test_row.set_title (_("测试连接"));
        mm_test_row.set_subtitle (_("验证视觉语言大模型 (VLM) 配置是否可用"));
        btn_mm_test = new Gtk.Button.with_label (_("测试"));
        btn_mm_test.valign = Gtk.Align.CENTER;
        btn_mm_test.add_css_class ("suggested-action");
        mm_test_row.add_suffix (btn_mm_test);
        mm_advanced.add (mm_test_row);

        // ═══════════════════════════════════════════════════════
        // 扫描忽略目录
        // ═══════════════════════════════════════════════════════
        var ignored_group = new Adw.PreferencesGroup ();
        ignored_group.set_title (_("扫描忽略目录"));
        ignored_group.set_description (
            _("这些目录不会出现在文件树中，也不会被自动收集。"));
        prefs_page.add (ignored_group);

        var ignored_row = new Adw.EntryRow ();
        ignored_row.set_title (_("忽略的目录名"));
        ignored_row.set_show_apply_button (false);
        string[] current_ignored = ConfigManager.get_ignored_dirs ();
        ignored_row.set_text (string.joinv (", ", current_ignored));
        edit_ignored_dirs = ignored_row;
        ignored_group.add (ignored_row);

        // ═══════════════════════════════════════════════════════
        // 安全警告
        // ═══════════════════════════════════════════════════════
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
        btn_sidebar_test.clicked.connect (() => { testing_sidebar = true; on_test (); });
        btn_mm_test.clicked.connect (() => { testing_sidebar = false; on_test (); });
        btn_mm_reset_exts.clicked.connect (() => {
            edit_mm_allowed_exts.set_text (string.joinv (", ", ConfigManager.DEFAULT_ALLOWED_BINARY_EXTS));
        });

        window.close_request.connect (() => {
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
        // 侧边栏 AI
        chk_sidebar_enabled.set_active (sidebar_current.enabled);
        edit_sidebar_base_url.set_text (sidebar_current.base_url ?? "");
        edit_sidebar_api_key.set_text (sidebar_current.api_key ?? "");
        edit_sidebar_model.set_text (sidebar_current.model ?? "");
        spin_sidebar_timeout.set_value (sidebar_current.timeout > 0 ? sidebar_current.timeout : 60.0);
        edit_sidebar_prompt.set_text (sidebar_current.system_prompt_override ?? "");

        // 多模态 AI
        chk_mm_enabled.set_active (mm_current.enabled);
        edit_mm_base_url.set_text (mm_current.base_url ?? "");
        edit_mm_api_key.set_text (mm_current.api_key ?? "");
        edit_mm_model.set_text (mm_current.model ?? "");
        spin_mm_timeout.set_value (mm_current.timeout > 0 ? mm_current.timeout : 120.0);
        edit_mm_prompt.set_text (mm_current.system_prompt_override ?? "");

        // 允许被多模态 AI 转换的扩展名列表
        string[] current_exts = ConfigManager.get_allowed_binary_extensions ();
        edit_mm_allowed_exts.set_text (string.joinv (", ", current_exts));
    }

    private void on_save () {
        var sb = collect_sidebar_from_ui ();
        var mm = collect_mm_from_ui ();
        bool any_http = false;
        if (sb.base_url.has_prefix ("http://") && !sb.base_url.has_prefix ("https://")) any_http = true;
        if (mm.base_url.has_prefix ("http://") && !mm.base_url.has_prefix ("https://")) any_http = true;
        if (any_http) {
            show_http_warning_dialog (sb, mm);
        } else {
            save_all (sb, mm);
        }
    }

    private void show_http_warning_dialog (ConfigManager.AISettings sb, ConfigManager.MultimodalAISettings mm) {
        var warning_dialog = new Adw.AlertDialog (
            _("安全警告"),
            _("您正在配置 HTTP (非 HTTPS) 端点。\n\n"
              + _("这将导致 API 密钥在传输过程中以明文形式发送，存在被第三方截获的风险。\n\n")
              + _("是否仍要继续保存？"))
        );
        warning_dialog.add_response ("cancel", _("取消"));
        warning_dialog.add_response ("continue", _("继续保存"));
        warning_dialog.set_response_appearance ("continue", Adw.ResponseAppearance.DESTRUCTIVE);
        warning_dialog.set_default_response ("cancel");
        warning_dialog.set_close_response ("cancel");
        warning_dialog.response.connect ((response) => {
            if (response == "continue") {
                save_all (sb, mm);
            }
            warning_dialog.destroy ();
        });
        warning_dialog.present (window);
    }

    private void save_all (ConfigManager.AISettings sb, ConfigManager.MultimodalAISettings mm) {
        sidebar_current = sb;
        ConfigManager.save_ai_settings (sidebar_current);
        mm_current = mm;
        ConfigManager.save_multimodal_ai_settings (mm_current);

        string raw_text = edit_ignored_dirs.get_text ();
        string[] parts = raw_text.split (",");
        var clean_list = new Gee.ArrayList<string> ();
        foreach (unowned string p in parts) {
            string trimmed = p.strip ();
            if (trimmed.length > 0) clean_list.add (trimmed);
        }
        ConfigManager.save_ignored_dirs ((string[]) clean_list.to_array ());

        // 解析并保存允许的扩展名 (自动为缺少前导点的扩展名补上)
        string raw_exts = edit_mm_allowed_exts.get_text ();
        string[] ext_parts = raw_exts.split (",");
        var clean_exts = new Gee.ArrayList<string> ();
        foreach (unowned string p in ext_parts) {
            string trimmed = p.strip ();
            if (trimmed.length == 0) continue;
            string t = trimmed.down ();
            if (!t.has_prefix (".")) t = "." + t;
            clean_exts.add (t);
        }
        if (clean_exts.size == 0) {
            // 留空等同于不允许转换, 保持空数组 (覆盖默认值)
            ConfigManager.save_allowed_binary_extensions (new string[0]);
        } else {
            ConfigManager.save_allowed_binary_extensions ((string[]) clean_exts.to_array ());
        }

        settings_changed ();
        window.close ();
    }

    private ConfigManager.AISettings collect_sidebar_from_ui () {
        return ConfigManager.AISettings () {
            enabled = chk_sidebar_enabled.get_active (),
            base_url = edit_sidebar_base_url.get_text ().strip (),
            api_key = edit_sidebar_api_key.get_text ().strip (),
            model = edit_sidebar_model.get_text ().strip (),
            system_prompt_override = edit_sidebar_prompt.get_text (),
            timeout = spin_sidebar_timeout.get_value ()
        };
    }

    private ConfigManager.MultimodalAISettings collect_mm_from_ui () {
        return ConfigManager.MultimodalAISettings () {
            enabled = chk_mm_enabled.get_active (),
            base_url = edit_mm_base_url.get_text ().strip (),
            api_key = edit_mm_api_key.get_text ().strip (),
            model = edit_mm_model.get_text ().strip (),
            system_prompt_override = edit_mm_prompt.get_text (),
            timeout = spin_mm_timeout.get_value ()
        };
    }

    private void show_toast (string title) {
        var toast = new Adw.Toast (title);
        toast.timeout = 3;
        toast_overlay.add_toast (toast);
    }

    private void on_test () {
        string base_url, api_key, model;
        double timeout;

        if (testing_sidebar) {
            var s = collect_sidebar_from_ui ();
            base_url = s.base_url; api_key = s.api_key; model = s.model; timeout = s.timeout;
        } else {
            var s = collect_mm_from_ui ();
            base_url = s.base_url; api_key = s.api_key; model = s.model; timeout = s.timeout;
        }

        if (base_url == "" || api_key == "" || model == "") {
            show_toast (_("请先填写 API 基础地址、密钥和模型名称。"));
            return;
        }

        var active_btn = testing_sidebar ? btn_sidebar_test : btn_mm_test;
        active_btn.set_sensitive (false);
        show_toast (_("正在测试..."));

        if (test_cancellable != null) { test_cancellable.cancel (); }
        if (test_session != null) { test_session.abort (); }

        var session = new Soup.Session ();
        session.timeout = (uint) (timeout > 0 ? timeout : 60.0);
        var cancellable = new GLib.Cancellable ();
        test_session = session;
        test_cancellable = cancellable;

        var payload = new Json.Object ();
        payload.set_string_member ("model", model);
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

        string url = base_url.has_suffix ("/") ? base_url + "chat/completions"
                                                : base_url + "/chat/completions";
        var msg = new Soup.Message ("POST", url);
        msg.set_request_body_from_bytes ("application/json", body_bytes);
        msg.request_headers.append ("Content-Type", "application/json");
        msg.request_headers.append ("Authorization", "Bearer " + api_key);

        bool is_sidebar = testing_sidebar;
        weak AISettingsDialog self = this;
        session.send_and_read_async (msg, GLib.Priority.DEFAULT, cancellable, (obj, res) => {
            if (self.window == null) return;
            if (self.test_session != session) return;
            self.test_session = null;
            self.test_cancellable = null;
            self.on_test_done (session, msg, res, is_sidebar);
        });
    }

    private static Json.Object build_msg (string role, string content) {
        var o = new Json.Object ();
        o.set_string_member ("role", role);
        o.set_string_member ("content", content);
        return o;
    }

    private void on_test_done (Soup.Session session, Soup.Message msg, AsyncResult res, bool is_sidebar) {
        if (window == null) {
            test_session = null;
            test_cancellable = null;
            return;
        }
        var active_btn = is_sidebar ? btn_sidebar_test : btn_mm_test;
        active_btn.set_sensitive (true);
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
        test_session = null;
    }
}
