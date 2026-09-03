using GLib;
using Gtk;
using Adw;
using Json;
using Soup;
using Gee;

public class PreferencesDialog : GLib.Object {
    public signal void ai_settings_changed ();
    public signal void context_settings_changed ();
    public signal void restart_requested ();

    private Gtk.Window? parent_window;
    private Adw.PreferencesDialog dialog;

    // ── AI 设置控件 ──
    private Switch chk_sidebar_enabled;
    private Adw.ComboRow combo_sb_profile;
    private EntryRow edit_sidebar_base_url;
    private PasswordEntryRow edit_sidebar_api_key;
    private EntryRow edit_sidebar_model;
    private SpinRow spin_sidebar_timeout;
    private EntryRow edit_sidebar_prompt;
    private Button btn_sidebar_test;

    private Gee.ArrayList<ConfigManager.AIProfile> sb_profiles;
    private bool switching_profile = false;

    private Gee.ArrayList<ConfigManager.VLMProfile> vlm_profiles;
    private bool switching_vlm_profile = false;

    private Switch chk_mm_enabled;
    private Adw.ComboRow combo_mm_provider;
    private Adw.ComboRow combo_vlm_profile;
    private EntryRow edit_mm_base_url;
    private PasswordEntryRow edit_mm_api_key;
    private EntryRow edit_mm_model;
    private SpinRow spin_mm_timeout;
    private SpinRow spin_mm_concurrency;
    private EntryRow edit_mm_prompt;
    private PasswordEntryRow edit_mm_paddleocr_token;
    private ActionRow edit_mm_paddleocr_token_help;
    private Button btn_mm_test;
    private EntryRow edit_mm_allowed_exts;
    private Button btn_mm_reset_exts;

    private EntryRow edit_ignored_dirs;

    private ConfigManager.AISettings sidebar_current;
    private ConfigManager.MultimodalAISettings mm_current;
    private uint ai_auto_save_id = 0;

    private Soup.Session? test_session = null;
    private Cancellable? test_cancellable = null;
    private bool testing_sidebar = false;

    // ── 上下文窗口设置控件 ──
    private SpinRow spin_context_size;

    // ── 语言设置控件 ──
    private ComboRow combo_language;
    private string current_language;

    // ── 外观设置控件 ──
    private ComboRow combo_color_scheme;

    public PreferencesDialog (Gtk.Window? parent) {
        this.parent_window = parent;
        this.sidebar_current = ConfigManager.load_ai_settings ();
        this.mm_current = ConfigManager.load_multimodal_ai_settings ();
        // 注册不安全 base_url 拒绝回调, 检测到明文 HTTP 端点时 toast 提示.
        ConfigManager.set_insecure_url_handler (on_insecure_base_url);
        // 注册密钥环迁移失败回调, 提示用户重新填写以重试写入.
        ConfigManager.set_keyring_migration_failed_handler (on_keyring_migration_failed);
    }

    private void on_insecure_base_url (string url, string reason) {
        // dialog 可能尚未初始化 (加载顺序问题), 此时仅记 warning.
        if (dialog == null) {
            warning ("PreferencesDialog: insecure base_url (%s): %s", url, reason);
            return;
        }
        // 不裸投 key, 也不跳转 URL, 仅提示错误原因.
        var toast = new Adw.Toast (
            _("Insecure endpoint rejected: ") + reason);
        toast.timeout = 6;
        toast.set_priority (Adw.ToastPriority.HIGH);
        dialog.add_toast (toast);
    }

    // 密钥环迁移失败回调: settings.json 中还有明文 key, 但 SecretStore.store
    // 失败 (libsecret 未启动 / Keychain 拒绝 / DPAPI 错误). 明文不会自动清除,
    // 下次启动会重试. 提示用户可以在本对话框里重新填一次, 写入会重试.
    private void on_keyring_migration_failed (string slot, string reason) {
        if (dialog == null) {
            warning ("PreferencesDialog: keyring migration failed (%s): %s", slot, reason);
            return;
        }
        var toast = new Adw.Toast (
            _("Keyring migration failed for ") + slot + ": " + reason);
        toast.timeout = 10;
        toast.set_priority (Adw.ToastPriority.HIGH);
        dialog.add_toast (toast);
    }

    public void present () {
        dialog = new Adw.PreferencesDialog ();
        dialog.set_title (_("Preferences..."));
        dialog.search_enabled = true;

        build_ai_page ();
        build_context_page ();
        build_appearance_page ();

        dialog.present (parent_window);
    }

    private void build_ai_page () {
        var page = new PreferencesPage ();
        page.set_title (_("AI Settings"));
        page.set_icon_name ("applications-engineering-symbolic");

        // ── 侧边栏 AI 助手 ──
        var sidebar_group = new PreferencesGroup ();
        sidebar_group.set_title (_("AI Assistant (Sidebar)"));
        sidebar_group.set_description (_("Configure an OpenAI-compatible API to orchestrate files with natural language in the AI sidebar.\nSupports OpenAI, Azure OpenAI, and any compatible endpoint (e.g. local Ollama)."));
        page.add (sidebar_group);

        var sb_enabled_row = new ActionRow ();
        sb_enabled_row.set_title (_("Enable AI Assistant"));
        sb_enabled_row.set_subtitle (_("After closing, the AI sidebar is kept but no requests are sent"));
        chk_sidebar_enabled = new Switch ();
        chk_sidebar_enabled.valign = Align.CENTER;
        sb_enabled_row.add_suffix (chk_sidebar_enabled);
        sb_enabled_row.set_activatable_widget (chk_sidebar_enabled);
        sidebar_group.add (sb_enabled_row);

        // ── 模型配置方案下拉: 多个模型预设存于配置文件 ai_models 数组,
        //    GUI 选择/编辑会同步回配置文件, 反之配置文件也可手工预置多模型。
        var sb_profile_row = new ComboRow ();
        sb_profile_row.set_title (_("Model Profile"));
        sb_profile_row.set_subtitle (
            _("Switch between saved model profiles.\nProfiles are stored in: %s\nEdit the file to pre-configure multiple models.")
                .printf (ConfigManager.get_settings_file_path ()));
        combo_sb_profile = sb_profile_row;
        var btn_profile_add = build_profile_button ("list-add-symbolic",
            _("Create a new profile from the current settings"));
        btn_profile_add.clicked.connect (() => { on_profile_add (); });
        var btn_profile_del = build_profile_button ("list-remove-symbolic",
            _("Delete the selected profile"));
        btn_profile_del.clicked.connect (() => { on_profile_delete (); });
        sb_profile_row.add_suffix (btn_profile_add);
        sb_profile_row.add_suffix (btn_profile_del);
        sidebar_group.add (sb_profile_row);

        var sb_url_row = new EntryRow ();
        sb_url_row.set_title (_("API Base URL"));
        sb_url_row.set_show_apply_button (false);
        edit_sidebar_base_url = sb_url_row;
        sidebar_group.add (sb_url_row);

        var sb_key_row = new PasswordEntryRow ();
        sb_key_row.set_title (_("API Key"));
        edit_sidebar_api_key = sb_key_row;
        sidebar_group.add (sb_key_row);

        var sb_model_row = new EntryRow ();
        sb_model_row.set_title (_("Model Name"));
        sb_model_row.set_show_apply_button (false);
        edit_sidebar_model = sb_model_row;
        sidebar_group.add (sb_model_row);

        var sb_timeout_row = new SpinRow.with_range (5.0, 600.0, 5.0);
        sb_timeout_row.set_title (_("Request Timeout (seconds)"));
        spin_sidebar_timeout = sb_timeout_row;
        sidebar_group.add (sb_timeout_row);

        var sb_advanced = new PreferencesGroup ();
        sb_advanced.set_title (_("Advanced"));
        page.add (sb_advanced);

        var sb_prompt_row = new EntryRow ();
        sb_prompt_row.set_title (_("Custom System Prompt (Optional)"));
        sb_prompt_row.set_show_apply_button (false);
        edit_sidebar_prompt = sb_prompt_row;
        sb_advanced.add (sb_prompt_row);

        var sb_test_row = new ActionRow ();
        sb_test_row.set_title (_("Test Connection"));
        sb_test_row.set_subtitle (_("Verify sidebar AI configuration"));
        btn_sidebar_test = new Button.with_label (_("Test"));
        btn_sidebar_test.valign = Align.CENTER;
        btn_sidebar_test.add_css_class ("suggested-action");
        sb_test_row.add_suffix (btn_sidebar_test);
        sb_advanced.add (sb_test_row);

        // ── 视觉语言大模型 ──
        var mm_group = new PreferencesGroup ();
        mm_group.set_title (_("Vision-Language Model (VLM) (Binary File Preprocessing)"));
        mm_group.set_description (
            _("Configure the Vision Language Model (VLM) API to convert PDF, Word, PPT, images, etc. into Markdown."));
        page.add (mm_group);

        var mm_enabled_row = new ActionRow ();
        mm_enabled_row.set_title (_("Enable VLM"));
        mm_enabled_row.set_subtitle (_("Binary files will not be auto-converted when disabled"));
        chk_mm_enabled = new Switch ();
        chk_mm_enabled.valign = Align.CENTER;
        mm_enabled_row.add_suffix (chk_mm_enabled);
        mm_enabled_row.set_activatable_widget (chk_mm_enabled);
        mm_group.add (mm_enabled_row);

        // ── VLM 模型配置方案下拉: 预置存于配置文件 vlm_models 数组, 双向同步
        var mm_profile_row = new ComboRow ();
        mm_profile_row.set_title (_("Model Profile"));
        mm_profile_row.set_subtitle (
            _("Switch between saved model profiles.\nProfiles are stored in: %s\nEdit the file to pre-configure multiple models.")
                .printf (ConfigManager.get_settings_file_path ()));
        combo_vlm_profile = mm_profile_row;
        var btn_vlm_profile_add = build_profile_button ("list-add-symbolic",
            _("Create a new profile from the current settings"));
        btn_vlm_profile_add.clicked.connect (() => { on_vlm_profile_add (); });
        var btn_vlm_profile_del = build_profile_button ("list-remove-symbolic",
            _("Delete the selected profile"));
        btn_vlm_profile_del.clicked.connect (() => { on_vlm_profile_delete (); });
        mm_profile_row.add_suffix (btn_vlm_profile_add);
        mm_profile_row.add_suffix (btn_vlm_profile_del);
        mm_group.add (mm_profile_row);

        // 服务商下拉: OpenAI 兼容 / PaddleOCR 云端
        // 用 StringList 直接提供显示文本 (与现有 combo_language 一致),
        // 选中索引 0 = OpenAI 兼容, 1 = PaddleOCR 云端.
        var provider_model = new StringList (new string[] {
            _("OpenAI Compatible"), _("PaddleOCR Cloud")
        });
        combo_mm_provider = new Adw.ComboRow ();
        combo_mm_provider.set_title (_("Provider"));
        combo_mm_provider.set_model (provider_model);
        mm_group.add (combo_mm_provider);

        var mm_url_row = new EntryRow ();
        mm_url_row.set_title (_("API Base URL"));
        mm_url_row.set_show_apply_button (false);
        edit_mm_base_url = mm_url_row;
        mm_group.add (mm_url_row);

        var mm_key_row = new PasswordEntryRow ();
        mm_key_row.set_title (_("API Key"));
        edit_mm_api_key = mm_key_row;
        mm_group.add (mm_key_row);

        var mm_model_row = new EntryRow ();
        mm_model_row.set_title (_("Model Name"));
        mm_model_row.set_show_apply_button (false);
        edit_mm_model = mm_model_row;
        mm_group.add (mm_model_row);

        // PaddleOCR Access Token 行 (仅 PaddleOCR 模式可见)
        var mm_token_row = new PasswordEntryRow ();
        mm_token_row.set_title (_("Access Token"));
        mm_token_row.set_show_apply_button (false);
        edit_mm_paddleocr_token = mm_token_row;
        mm_group.add (mm_token_row);

        // Token 获取引导: 标题 + 右侧"Open AI Studio"按钮 (链接跳转, 样式同测试按钮)
        var mm_token_help = new ActionRow ();
        mm_token_help.set_title (_("Get your token from AI Studio"));
        var mm_token_btn = new Button.with_label (_("Open AI Studio"));
        mm_token_btn.valign = Align.CENTER;
        mm_token_btn.add_css_class ("suggested-action");
        mm_token_btn.clicked.connect (() => {
            try {
                Gtk.UriLauncher launcher = new Gtk.UriLauncher ("https://aistudio.baidu.com/account/accessToken");
                launcher.launch.begin (null, null, (obj, res) => {
                    try {
                        launcher.launch.end (res);
                    } catch (Error e) {
                        show_toast (_("Failed to open link: %s").printf (e.message));
                    }
                });
            } catch (Error e) {
                show_toast (_("Failed to open link: %s").printf (e.message));
            }
        });
        mm_token_help.add_suffix (mm_token_btn);
        edit_mm_paddleocr_token_help = mm_token_help;
        mm_group.add (mm_token_help);

        var mm_timeout_row = new SpinRow.with_range (5.0, 600.0, 5.0);
        mm_timeout_row.set_title (_("Request Timeout (seconds)"));
        spin_mm_timeout = mm_timeout_row;
        mm_group.add (mm_timeout_row);

        var mm_concurrency_row = new SpinRow.with_range (1.0, 16.0, 1.0);
        mm_concurrency_row.set_title (_("Concurrency (parallel tasks)"));
        mm_concurrency_row.set_subtitle (_("Max simultaneous VLM preprocessing tasks. Set per your model provider's rate/concurrency limit."));
        spin_mm_concurrency = mm_concurrency_row;
        mm_group.add (mm_concurrency_row);

        var mm_advanced = new PreferencesGroup ();
        mm_advanced.set_title (_("Advanced"));
        page.add (mm_advanced);

        var mm_exts_input_row = new EntryRow ();
        mm_exts_input_row.set_title (_("Allowed binary extensions (comma-separated, e.g. .pdf, .docx)"));
        mm_exts_input_row.set_show_apply_button (false);
        edit_mm_allowed_exts = mm_exts_input_row;
        mm_exts_input_row.set_hexpand (true);

        btn_mm_reset_exts = new Button.with_label (_("Default"));
        btn_mm_reset_exts.valign = Align.CENTER;
        btn_mm_reset_exts.set_tooltip_text (_("Reset to default extension list"));
        mm_exts_input_row.add_suffix (btn_mm_reset_exts);
        mm_advanced.add (mm_exts_input_row);

        var mm_prompt_row = new EntryRow ();
        mm_prompt_row.set_title (_("Custom System Prompt (Optional)"));
        mm_prompt_row.set_show_apply_button (false);
        edit_mm_prompt = mm_prompt_row;
        mm_advanced.add (mm_prompt_row);

        var mm_test_row = new ActionRow ();
        mm_test_row.set_title (_("Test Connection"));
        mm_test_row.set_subtitle (_("Verify VLM (Vision-Language Model) configuration"));
        btn_mm_test = new Button.with_label (_("Test"));
        btn_mm_test.valign = Align.CENTER;
        btn_mm_test.add_css_class ("suggested-action");
        mm_test_row.add_suffix (btn_mm_test);
        mm_advanced.add (mm_test_row);

        // ── 安全警告 ──
        var security_group = new PreferencesGroup ();
        security_group.set_title (_("Security Warning"));
        page.add (security_group);

        var security_row = new ActionRow ();
        security_row.set_title (_("HTTP Endpoint Security Risk"));
        security_row.set_subtitle (_("Using an HTTP (non-HTTPS) endpoint transmits the API key in plaintext over the network, posing a security risk."));

        var warning_icon = new Image.from_icon_name ("dialog-warning-symbolic");
        warning_icon.add_css_class ("warning");
        warning_icon.valign = Align.CENTER;
        security_row.add_prefix (warning_icon);
        security_group.add (security_row);

        dialog.add (page);

        // Load values
        load_ai_into_ui ();

        // Auto-save on any AI setting change (debounced 500ms)
        chk_sidebar_enabled.notify["active"].connect (schedule_ai_auto_save);
        edit_sidebar_base_url.notify["text"].connect (schedule_ai_auto_save);
        edit_sidebar_api_key.notify["text"].connect (schedule_ai_auto_save);
        edit_sidebar_model.notify["text"].connect (schedule_ai_auto_save);
        spin_sidebar_timeout.notify["value"].connect (schedule_ai_auto_save);
        edit_sidebar_prompt.notify["text"].connect (schedule_ai_auto_save);

        // 模型配置方案切换: 先把旧方案的未保存修改落盘, 再加载新方案
        combo_sb_profile.notify["selected"].connect (() => {
            if (switching_profile) return;
            flush_pending_ai_save ();
            int idx = (int) combo_sb_profile.get_selected ();
            if (idx < 0 || idx >= sb_profiles.size) return;
            switching_profile = true;
            apply_profile_to_ui (sb_profiles.get (idx));
            switching_profile = false;
            // 持久化激活方案选择 (配置文件 ai.active_profile)
            ConfigManager.save_ai_settings (collect_sidebar_from_ui ());
        });

        chk_mm_enabled.notify["active"].connect (schedule_ai_auto_save);
        edit_mm_base_url.notify["text"].connect (schedule_ai_auto_save);
        edit_mm_api_key.notify["text"].connect (schedule_ai_auto_save);
        edit_mm_model.notify["text"].connect (schedule_ai_auto_save);
        edit_mm_paddleocr_token.notify["text"].connect (schedule_ai_auto_save);
        spin_mm_timeout.notify["value"].connect (schedule_ai_auto_save);
        spin_mm_concurrency.notify["value"].connect (schedule_ai_auto_save);
        edit_mm_prompt.notify["text"].connect (schedule_ai_auto_save);

        // VLM 模型配置方案切换: 先落盘旧方案未保存修改, 再加载新方案
        combo_vlm_profile.notify["selected"].connect (() => {
            if (switching_vlm_profile) return;
            flush_pending_ai_save ();
            int idx = (int) combo_vlm_profile.get_selected ();
            if (idx < 0 || idx >= vlm_profiles.size) return;
            switching_vlm_profile = true;
            apply_vlm_profile_to_ui (vlm_profiles.get (idx));
            switching_vlm_profile = false;
            // 持久化激活方案选择 (配置文件 multimodal_ai.active_profile)
            ConfigManager.save_multimodal_ai_settings (collect_mm_from_ui ());
        });

        edit_mm_allowed_exts.notify["text"].connect (schedule_ai_auto_save);
        // 注意: edit_ignored_dirs 在 build_context_page() 中创建, 此处尚未赋值,
        // 其信号连接也已迁移到 build_context_page() 内, 避免连接空对象触发
        // g_signal_connect_object 的 NULL 断言告警.

        btn_sidebar_test.clicked.connect (() => { testing_sidebar = true; on_ai_test (); });
        btn_mm_test.clicked.connect (() => { testing_sidebar = false; on_ai_test (); });
        btn_mm_reset_exts.clicked.connect (() => {
            edit_mm_allowed_exts.set_text (string.joinv (", ", ConfigManager.DEFAULT_ALLOWED_BINARY_EXTS));
        });

        combo_mm_provider.notify["selected"].connect (() => {
            update_provider_visibility ();
            schedule_ai_auto_save ();
        });

        // 根据当前服务商初始化显隐状态
        update_provider_visibility ();
    }

    // 按服务商切换 base_url/api_key/model/自定义提示词 与 token 行的可见性:
    //   OpenAI 兼容 → 显示前四项, 隐藏 token
    //   PaddleOCR 云端 → 隐藏前四项 (写死服务端点和模型), 仅显示 token
    private void update_provider_visibility () {
        string provider = current_mm_provider ();
        bool is_paddleocr = (provider == ConfigManager.PROVIDER_PADDLEOCR);
        edit_mm_base_url.visible = !is_paddleocr;
        edit_mm_api_key.visible = !is_paddleocr;
        edit_mm_model.visible = !is_paddleocr;
        edit_mm_prompt.visible = !is_paddleocr;
        edit_mm_paddleocr_token.visible = is_paddleocr;
        edit_mm_paddleocr_token_help.visible = is_paddleocr;
    }

    private string current_mm_provider () {
        uint sel = combo_mm_provider.get_selected ();
        if (sel == 1) return ConfigManager.PROVIDER_PADDLEOCR;
        return ConfigManager.PROVIDER_OPENAI;
    }

    private void build_context_page () {
        var page = new PreferencesPage ();
        page.set_title (_("Scanning & Context"));
        page.set_icon_name ("document-properties-symbolic");

        var group = new PreferencesGroup ();
        group.set_title (_("Model Context Limit"));
        group.set_description (_("Set the target LLM's maximum token window, used for progress bar warnings."));
        page.add (group);

        spin_context_size = new SpinRow.with_range (1000, 2000000, 1000);
        spin_context_size.set_title (_("Context Window Size (Tokens)"));
        spin_context_size.set_value (ConfigManager.get_context_window_size ());
        group.add (spin_context_size);

        spin_context_size.notify["value"].connect (() => {
            int new_size = (int) spin_context_size.get_value ();
            ConfigManager.save_context_window_size (new_size);
            context_settings_changed ();
        });

        // ── 扫描忽略目录 ──
        var ignored_group = new PreferencesGroup ();
        ignored_group.set_title (_("Scan Ignored Directories"));
        ignored_group.set_description (
            _("These directories will not appear in the file tree and will not be collected automatically."));
        page.add (ignored_group);

        var ignored_row = new EntryRow ();
        ignored_row.set_title (_("Ignored Directory Names"));
        ignored_row.set_show_apply_button (false);
        string[] current_ignored = ConfigManager.get_ignored_dirs ();
        ignored_row.set_text (string.joinv (", ", current_ignored));
        edit_ignored_dirs = ignored_row;
        ignored_group.add (ignored_row);

        // edit_ignored_dirs 在此处已创建并赋值, 故其自动保存连接放在这里
        // (不能放在 build_ai_page(), 那时该字段仍为 null).
        edit_ignored_dirs.notify["text"].connect (schedule_ai_auto_save);

        dialog.add (page);
    }

    private void build_appearance_page () {
        var page = new PreferencesPage ();
        page.set_title (_("Appearance"));
        page.set_icon_name ("preferences-color-symbolic");

        // ── 颜色主题 ──
        var theme_group = new PreferencesGroup ();
        theme_group.set_title (_("Color Theme"));
        theme_group.set_description (_("Select the application color theme."));
        page.add (theme_group);

        var scheme_model = new StringList (new string[] {
            _("Follow System"), _("Light"), _("Dark")
        });

        combo_color_scheme = new ComboRow ();
        combo_color_scheme.set_title (_("Theme"));
        combo_color_scheme.set_model (scheme_model);

        string current_scheme = ConfigManager.load_color_scheme ();
        if (current_scheme == "default") {
            combo_color_scheme.set_selected (0);
        } else if (current_scheme == "light") {
            combo_color_scheme.set_selected (1);
        } else if (current_scheme == "dark") {
            combo_color_scheme.set_selected (2);
        }
        theme_group.add (combo_color_scheme);

        combo_color_scheme.notify["selected"].connect (() => {
            string scheme;
            Adw.ColorScheme adw_scheme;
            if (combo_color_scheme.selected == 0) {
                scheme = "default";
                adw_scheme = Adw.ColorScheme.DEFAULT;
            } else if (combo_color_scheme.selected == 1) {
                scheme = "light";
                adw_scheme = Adw.ColorScheme.FORCE_LIGHT;
            } else {
                scheme = "dark";
                adw_scheme = Adw.ColorScheme.FORCE_DARK;
            }
            Adw.StyleManager.get_default ().set_color_scheme (adw_scheme);
            ConfigManager.save_color_scheme (scheme);
        });

        // ── 界面语言 ──
        var lang_group = new PreferencesGroup ();
        lang_group.set_title (_("Interface Language"));
        lang_group.set_description (_("Restart the application for language changes to take effect."));
        page.add (lang_group);

        current_language = ConfigManager.load_settings_language ();
        var lang_model = new StringList (new string[] {
            _("Follow System"), _("Chinese"), _("English")
        });

        combo_language = new ComboRow ();
        combo_language.set_title (_("Interface Language"));
        combo_language.set_model (lang_model);

        if (current_language == "" || current_language == "system") {
            combo_language.set_selected (0);
        } else if (current_language == "zh") {
            combo_language.set_selected (1);
        } else if (current_language == "en") {
            combo_language.set_selected (2);
        }
        lang_group.add (combo_language);

        // 应用按钮
        var action_group = new PreferencesGroup ();
        var apply_row = new ActionRow ();
        apply_row.set_title (_("Apply Language Settings"));
        apply_row.set_subtitle (_("Save language settings and restart application"));
        var apply_btn = new Button.with_label (_("Apply"));
        apply_btn.add_css_class ("suggested-action");
        apply_btn.valign = Align.CENTER;
        apply_row.add_suffix (apply_btn);
        apply_row.set_activatable_widget (apply_btn);
        action_group.add (apply_row);
        page.add (action_group);

        dialog.add (page);

        apply_btn.clicked.connect (() => {
            string new_lang;
            if (combo_language.selected == 0) {
                new_lang = "system";
            } else if (combo_language.selected == 1) {
                new_lang = "zh";
            } else {
                new_lang = "en";
            }

            ConfigManager.save_language_setting (new_lang);
            current_language = new_lang;

            var restart_dialog = new Adw.AlertDialog (
                _("Notice"),
                _("Language setting saved; takes effect after restart. Restart now?")
            );
            restart_dialog.add_response ("later", _("Later"));
            restart_dialog.add_response ("restart", _("Restart Now"));
            restart_dialog.set_default_response ("restart");
            restart_dialog.set_close_response ("later");

            restart_dialog.response.connect ((r) => {
                if (r == "restart") {
                    restart_requested ();
                }
                restart_dialog.destroy ();
            });
            if (parent_window != null) {
                restart_dialog.present (parent_window);
            }
        });
    }

    // ── AI 设置辅助方法 ──

    // 下拉框旁的扁平图标按钮 (自然宽度, GTK 默认内边距)
    private Button build_profile_button (string icon_name, string tooltip) {
        var btn = new Button ();
        btn.icon_name = icon_name;
        btn.valign = Align.CENTER;
        btn.add_css_class ("flat");
        btn.set_tooltip_text (tooltip);
        return btn;
    }

    private void on_profile_add () {
        flush_pending_ai_save ();
        // 以当前表单值新建方案, 名称自动去重
        int n = sb_profiles.size + 1;
        string name = _("Profile %d").printf (n);
        while (find_profile_index (name) >= 0) {
            n++;
            name = _("Profile %d").printf (n);
        }
        var p = new ConfigManager.AIProfile ();
        p.name = name;
        p.base_url = edit_sidebar_base_url.get_text ().strip ();
        p.api_key = edit_sidebar_api_key.get_text ().strip ();
        p.model = edit_sidebar_model.get_text ().strip ();
        p.system_prompt_override = edit_sidebar_prompt.get_text ();
        p.timeout = spin_sidebar_timeout.get_value ();
        sb_profiles.add (p);
        sidebar_current.profile_name = name;
        ConfigManager.save_ai_profiles (sb_profiles);
        refresh_profile_combo (sb_profiles.size - 1);
        // 同步激活方案到配置文件
        ConfigManager.save_ai_settings (collect_sidebar_from_ui ());
    }

    private void on_profile_delete () {
        int idx = (int) combo_sb_profile.get_selected ();
        if (idx < 0 || idx >= sb_profiles.size) return;
        if (sb_profiles.size <= 1) {
            show_toast (_("At least one profile must be kept."));
            return;
        }
        flush_pending_ai_save ();
        var removed = sb_profiles.get (idx);
        sb_profiles.remove_at (idx);
        ConfigManager.delete_ai_profile_key (removed.name);
        ConfigManager.save_ai_profiles (sb_profiles);
        int new_idx = idx > 0 ? idx - 1 : 0;
        if (new_idx >= sb_profiles.size) new_idx = sb_profiles.size - 1;
        sidebar_current.profile_name = sb_profiles.get (new_idx).name;
        refresh_profile_combo (new_idx);
        apply_profile_to_ui (sb_profiles.get (new_idx));
        ConfigManager.save_ai_settings (collect_sidebar_from_ui ());
    }

    private int find_profile_index (string name) {
        for (int i = 0; i < sb_profiles.size; i++) {
            if (sb_profiles.get (i).name == name) return i;
        }
        return -1;
    }

    // 用指定方案的值刷新表单 (含 sidebar_current 镜像)
    private void apply_profile_to_ui (ConfigManager.AIProfile p) {
        sidebar_current.profile_name = p.name;
        sidebar_current.base_url = p.base_url;
        sidebar_current.api_key = p.api_key;
        sidebar_current.model = p.model;
        sidebar_current.system_prompt_override = p.system_prompt_override;
        sidebar_current.timeout = p.timeout > 0 ? p.timeout : 60.0;

        edit_sidebar_base_url.set_text (p.base_url ?? "");
        edit_sidebar_api_key.set_text (p.api_key ?? "");
        edit_sidebar_model.set_text (p.model ?? "");
        spin_sidebar_timeout.set_value (sidebar_current.timeout);
        edit_sidebar_prompt.set_text (p.system_prompt_override ?? "");
    }

    // 依据 sb_profiles 重建下拉框模型并选中 select_index
    private void refresh_profile_combo (int select_index) {
        switching_profile = true;
        string[] names = new string[sb_profiles.size];
        for (int i = 0; i < sb_profiles.size; i++) {
            names[i] = sb_profiles.get (i).name;
        }
        combo_sb_profile.set_model (new Gtk.StringList (names));
        if (select_index >= 0 && select_index < sb_profiles.size) {
            combo_sb_profile.set_selected ((uint) select_index);
        }
        switching_profile = false;
    }

    // 立即执行挂起的延迟自动保存 (切换/增删方案前调用, 防止修改归属错方案)
    private void flush_pending_ai_save () {
        if (ai_auto_save_id > 0) {
            Source.remove (ai_auto_save_id);
            ai_auto_save_id = 0;
            var sb = collect_sidebar_from_ui ();
            var mm = collect_mm_from_ui ();
            save_all (sb, mm);
        }
    }

    // ── VLM 模型配置方案辅助方法 (与侧边栏方案逻辑对称) ──

    private void on_vlm_profile_add () {
        flush_pending_ai_save ();
        // 以当前表单值新建方案, 名称自动去重
        int n = vlm_profiles.size + 1;
        string name = _("Profile %d").printf (n);
        while (find_vlm_profile_index (name) >= 0) {
            n++;
            name = _("Profile %d").printf (n);
        }
        var p = new ConfigManager.VLMProfile ();
        p.name = name;
        p.provider = current_mm_provider ();
        p.base_url = edit_mm_base_url.get_text ().strip ();
        p.api_key = edit_mm_api_key.get_text ().strip ();
        p.model = edit_mm_model.get_text ().strip ();
        p.paddleocr_token = edit_mm_paddleocr_token.get_text ().strip ();
        p.system_prompt_override = edit_mm_prompt.get_text ();
        p.timeout = spin_mm_timeout.get_value ();
        p.max_concurrency = (int) spin_mm_concurrency.get_value ();
        vlm_profiles.add (p);
        mm_current.profile_name = name;
        ConfigManager.save_vlm_profiles (vlm_profiles);
        refresh_vlm_profile_combo (vlm_profiles.size - 1);
        // 同步激活方案到配置文件
        ConfigManager.save_multimodal_ai_settings (collect_mm_from_ui ());
    }

    private void on_vlm_profile_delete () {
        int idx = (int) combo_vlm_profile.get_selected ();
        if (idx < 0 || idx >= vlm_profiles.size) return;
        if (vlm_profiles.size <= 1) {
            show_toast (_("At least one profile must be kept."));
            return;
        }
        flush_pending_ai_save ();
        var removed = vlm_profiles.get (idx);
        vlm_profiles.remove_at (idx);
        ConfigManager.delete_vlm_profile_keys (removed.name);
        ConfigManager.save_vlm_profiles (vlm_profiles);
        int new_idx = idx > 0 ? idx - 1 : 0;
        if (new_idx >= vlm_profiles.size) new_idx = vlm_profiles.size - 1;
        mm_current.profile_name = vlm_profiles.get (new_idx).name;
        refresh_vlm_profile_combo (new_idx);
        apply_vlm_profile_to_ui (vlm_profiles.get (new_idx));
        ConfigManager.save_multimodal_ai_settings (collect_mm_from_ui ());
    }

    private int find_vlm_profile_index (string name) {
        for (int i = 0; i < vlm_profiles.size; i++) {
            if (vlm_profiles.get (i).name == name) return i;
        }
        return -1;
    }

    // 用指定 VLM 方案的值刷新表单 (含 mm_current 镜像)
    private void apply_vlm_profile_to_ui (ConfigManager.VLMProfile p) {
        mm_current.profile_name = p.name;
        mm_current.provider = p.provider;
        mm_current.base_url = p.base_url;
        mm_current.api_key = p.api_key;
        mm_current.model = p.model;
        mm_current.paddleocr_token = p.paddleocr_token;
        mm_current.system_prompt_override = p.system_prompt_override;
        mm_current.timeout = p.timeout > 0 ? p.timeout : 120.0;
        mm_current.max_concurrency = p.max_concurrency > 0 ? p.max_concurrency : 3;

        combo_mm_provider.set_selected (
            p.provider == ConfigManager.PROVIDER_PADDLEOCR ? 1 : 0);
        edit_mm_base_url.set_text (p.base_url ?? "");
        edit_mm_api_key.set_text (p.api_key ?? "");
        edit_mm_model.set_text (p.model ?? "");
        edit_mm_paddleocr_token.set_text (p.paddleocr_token ?? "");
        spin_mm_timeout.set_value (mm_current.timeout);
        spin_mm_concurrency.set_value ((double) mm_current.max_concurrency);
        edit_mm_prompt.set_text (p.system_prompt_override ?? "");
        update_provider_visibility ();
    }

    // 依据 vlm_profiles 重建下拉框模型并选中 select_index
    private void refresh_vlm_profile_combo (int select_index) {
        switching_vlm_profile = true;
        string[] names = new string[vlm_profiles.size];
        for (int i = 0; i < vlm_profiles.size; i++) {
            names[i] = vlm_profiles.get (i).name;
        }
        combo_vlm_profile.set_model (new Gtk.StringList (names));
        if (select_index >= 0 && select_index < vlm_profiles.size) {
            combo_vlm_profile.set_selected ((uint) select_index);
        }
        switching_vlm_profile = false;
    }

    private void load_ai_into_ui () {
        chk_sidebar_enabled.set_active (sidebar_current.enabled);
        edit_sidebar_base_url.set_text (sidebar_current.base_url ?? "");
        edit_sidebar_api_key.set_text (sidebar_current.api_key ?? "");
        edit_sidebar_model.set_text (sidebar_current.model ?? "");
        spin_sidebar_timeout.set_value (sidebar_current.timeout > 0 ? sidebar_current.timeout : 60.0);
        edit_sidebar_prompt.set_text (sidebar_current.system_prompt_override ?? "");

        // 加载模型配置方案; 配置文件尚无 ai_models 时, 以当前设置合成一项,
        // 首次保存时即会同步写回配置文件。
        sb_profiles = ConfigManager.load_ai_profiles ();
        if (sb_profiles.size == 0) {
            var p = new ConfigManager.AIProfile ();
            p.name = ConfigManager.DEFAULT_PROFILE_NAME;
            p.base_url = sidebar_current.base_url ?? "";
            p.api_key = sidebar_current.api_key ?? "";
            p.model = sidebar_current.model ?? "";
            p.system_prompt_override = sidebar_current.system_prompt_override ?? "";
            p.timeout = sidebar_current.timeout > 0 ? sidebar_current.timeout : 60.0;
            sb_profiles.add (p);
        }
        int sel = find_profile_index (sidebar_current.profile_name);
        if (sel < 0) sel = 0;
        sidebar_current.profile_name = sb_profiles.get (sel).name;
        refresh_profile_combo (sel);

        chk_mm_enabled.set_active (mm_current.enabled);
        combo_mm_provider.set_selected (
            mm_current.provider == ConfigManager.PROVIDER_PADDLEOCR ? 1 : 0);
        edit_mm_base_url.set_text (mm_current.base_url ?? "");
        edit_mm_api_key.set_text (mm_current.api_key ?? "");
        edit_mm_model.set_text (mm_current.model ?? "");
        edit_mm_paddleocr_token.set_text (mm_current.paddleocr_token ?? "");
        spin_mm_timeout.set_value (mm_current.timeout > 0 ? mm_current.timeout : 120.0);
        spin_mm_concurrency.set_value (mm_current.max_concurrency > 0 ? (double) mm_current.max_concurrency : 3.0);
        edit_mm_prompt.set_text (mm_current.system_prompt_override ?? "");
        update_provider_visibility ();

        // 加载 VLM 模型配置方案; 配置文件尚无 vlm_models 时, 以当前设置合成一项,
        // 首次保存时即会同步写回配置文件。
        vlm_profiles = ConfigManager.load_vlm_profiles ();
        if (vlm_profiles.size == 0) {
            var p = new ConfigManager.VLMProfile ();
            p.name = ConfigManager.DEFAULT_PROFILE_NAME;
            p.provider = mm_current.provider ?? ConfigManager.PROVIDER_OPENAI;
            p.base_url = mm_current.base_url ?? "";
            p.api_key = mm_current.api_key ?? "";
            p.model = mm_current.model ?? "";
            p.paddleocr_token = mm_current.paddleocr_token ?? "";
            p.system_prompt_override = mm_current.system_prompt_override ?? "";
            p.timeout = mm_current.timeout > 0 ? mm_current.timeout : 120.0;
            p.max_concurrency = mm_current.max_concurrency > 0 ? mm_current.max_concurrency : 3;
            vlm_profiles.add (p);
        }
        int vlm_sel = find_vlm_profile_index (mm_current.profile_name);
        if (vlm_sel < 0) vlm_sel = 0;
        mm_current.profile_name = vlm_profiles.get (vlm_sel).name;
        refresh_vlm_profile_combo (vlm_sel);

        string[] current_exts = ConfigManager.get_allowed_binary_extensions ();
        edit_mm_allowed_exts.set_text (string.joinv (", ", current_exts));
    }

    private void schedule_ai_auto_save () {
        if (switching_profile || switching_vlm_profile) return;  // 程序化填充表单期间不触发保存
        if (ai_auto_save_id > 0) {
            Source.remove (ai_auto_save_id);
        }
        ai_auto_save_id = Timeout.add (500, () => {
            ai_auto_save_id = 0;
            var sb = collect_sidebar_from_ui ();
            var mm = collect_mm_from_ui ();
            save_all (sb, mm);
            return Source.REMOVE;
        });
    }

    private void save_all (ConfigManager.AISettings sb, ConfigManager.MultimodalAISettings mm) {
        sidebar_current = sb;
        ConfigManager.save_ai_settings (sidebar_current);
        mm_current = mm;
        ConfigManager.save_multimodal_ai_settings (mm_current);

        string raw_text = edit_ignored_dirs.get_text ();
        string[] parts = raw_text.split (",");
        var clean_list = new ArrayList<string> ();
        foreach (unowned string p in parts) {
            string trimmed = p.strip ();
            if (trimmed.length > 0) clean_list.add (trimmed);
        }
        ConfigManager.save_ignored_dirs ((string[]) clean_list.to_array ());

        string raw_exts = edit_mm_allowed_exts.get_text ();
        string[] ext_parts = raw_exts.split (",");
        var clean_exts = new ArrayList<string> ();
        foreach (unowned string p in ext_parts) {
            string trimmed = p.strip ();
            if (trimmed.length == 0) continue;
            string t = trimmed.down ();
            if (!t.has_prefix (".")) t = "." + t;
            clean_exts.add (t);
        }
        if (clean_exts.size == 0) {
            ConfigManager.save_allowed_binary_extensions (new string[0]);
        } else {
            ConfigManager.save_allowed_binary_extensions ((string[]) clean_exts.to_array ());
        }

        ai_settings_changed ();
    }

    private ConfigManager.AISettings collect_sidebar_from_ui () {
        return ConfigManager.AISettings () {
            enabled = chk_sidebar_enabled.get_active (),
            profile_name = sidebar_current.profile_name,
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
            profile_name = mm_current.profile_name,
            provider = current_mm_provider (),
            base_url = edit_mm_base_url.get_text ().strip (),
            api_key = edit_mm_api_key.get_text ().strip (),
            model = edit_mm_model.get_text ().strip (),
            paddleocr_token = edit_mm_paddleocr_token.get_text ().strip (),
            system_prompt_override = edit_mm_prompt.get_text (),
            timeout = spin_mm_timeout.get_value (),
            max_concurrency = (int) spin_mm_concurrency.get_value ()
        };
    }

    private void show_toast (string title) {
        var toast = new Adw.Toast (title);
        toast.timeout = 3;
        dialog.add_toast (toast);
    }

    private void on_ai_test () {
        string base_url, api_key, model;
        double timeout;

        if (!testing_sidebar) {
            var s = collect_mm_from_ui ();
            if (s.provider == ConfigManager.PROVIDER_PADDLEOCR) {
                on_paddleocr_test (s);
                return;
            }
            base_url = s.base_url; api_key = s.api_key; model = s.model; timeout = s.timeout;
        } else {
            var s = collect_sidebar_from_ui ();
            base_url = s.base_url; api_key = s.api_key; model = s.model; timeout = s.timeout;
        }

        if (base_url == "" || api_key == "" || model == "") {
            show_toast (_("Please fill in the API Base URL, Key, and Model Name first."));
            return;
        }

        var active_btn = testing_sidebar ? btn_sidebar_test : btn_mm_test;
        active_btn.set_sensitive (false);
        show_toast (_("Testing..."));

        if (test_cancellable != null) { test_cancellable.cancel (); }
        if (test_session != null) { test_session.abort (); }

        var session = new Soup.Session ();
        session.timeout = (uint) (timeout > 0 ? timeout : 60.0);
        var cancellable = new Cancellable ();
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
        Memory.copy (body_buf, body, body_len);
        var body_bytes = new Bytes (body_buf);

        string url = base_url.has_suffix ("/") ? base_url + "chat/completions"
                                                : base_url + "/chat/completions";
        var msg = new Soup.Message ("POST", url);
        msg.set_request_body_from_bytes ("application/json", body_bytes);
        msg.request_headers.append ("Content-Type", "application/json");
        msg.request_headers.append ("Authorization", "Bearer " + api_key);

        bool is_sidebar = testing_sidebar;
        weak PreferencesDialog self = this;
        session.send_and_read_async (msg, Priority.DEFAULT, cancellable, (obj, res) => {
            if (self.dialog == null) return;
            if (self.test_session != session) return;
            self.test_session = null;
            self.test_cancellable = null;
            self.on_ai_test_done (session, msg, res, is_sidebar);
        });
    }

    private static Json.Object build_msg (string role, string content) {
        var o = new Json.Object ();
        o.set_string_member ("role", role);
        o.set_string_member ("content", content);
        return o;
    }

    private void on_ai_test_done (Soup.Session session, Soup.Message msg, AsyncResult res, bool is_sidebar) {
        if (dialog == null) {
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
                show_toast (_("Connected successfully"));
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
                string msg_str = _("✗ Failed: HTTP %u %s").printf (status, phrase)
                    + (detail.length > 0 ? " — " + detail : "");
                show_toast (msg_str);
            }
        } catch (Error e) {
            show_toast (_("✗ Failed: %s").printf (e.message));
        }
        test_session = null;
    }

    // PaddleOCR 模式下的"测试连接": 上传一个最小 PNG 验证 Token 鉴权.
    // 仅检查提交阶段 (submit_job) 的响应: 200 表示 Token 有效, 4xx 表示鉴权失败.
    private void on_paddleocr_test (ConfigManager.MultimodalAISettings s) {
        if (s.paddleocr_token.length == 0) {
            show_toast (_("Please fill in the Access Token first."));
            return;
        }

        btn_mm_test.set_sensitive (false);
        show_toast (_("Testing..."));

        if (test_cancellable != null) { test_cancellable.cancel (); }
        if (test_session != null) { test_session.abort (); }

        var session = new Soup.Session ();
        session.timeout = (uint) (s.timeout > 0 ? s.timeout : 120.0);
        var cancellable = new Cancellable ();
        test_session = session;
        test_cancellable = cancellable;

        // 1x1 透明 PNG (最小合法图片), 仅用于触发鉴权校验
        uint8[] png = {
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
            0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
            0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
        };

        var multipart = new Soup.Multipart ("multipart/form-data");
        multipart.append_form_string ("model", PaddleOCRClient.MODEL);
        multipart.append_form_file ("file", "test.png", "image/png", new Bytes (png));

        var msg = new Soup.Message.from_multipart (PaddleOCRClient.JOB_URL, multipart);
        msg.request_headers.append ("Authorization", "bearer " + s.paddleocr_token);

        weak PreferencesDialog self = this;
        session.send_and_read_async (msg, Priority.DEFAULT, cancellable, (obj, res) => {
            if (self.dialog == null) return;
            if (self.test_session != session) return;
            self.test_session = null;
            self.test_cancellable = null;
            self.btn_mm_test.set_sensitive (true);
            try {
                var bytes = session.send_and_read_async.end (res);
                uint status = msg.status_code;
                if (status >= 200 && status < 300) {
                    show_toast (_("Connected successfully (token valid)"));
                } else {
                    string detail = "";
                    if (bytes != null && bytes.length > 0) {
                        uint8[] raw = bytes.get_data ();
                        int safe_len = (int) int64.min (bytes.length, 4096);
                        detail = ((string) raw).substring (0, safe_len);
                        if (detail.length > 200) detail = detail.substring (0, 200) + "…";
                    }
                    string phrase = Soup.Status.get_phrase (status);
                    show_toast (_("✗ Failed: HTTP %u %s").printf (status, phrase)
                        + (detail.length > 0 ? " — " + detail : ""));
                }
            } catch (Error e) {
                show_toast (_("✗ Failed: %s").printf (e.message));
            }
        });
    }
}
