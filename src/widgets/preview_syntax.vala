using Gtk;
using GtkSource;

// ─── 预览面板语法高亮管理 ─────────────────────────────────────────────

public class PreviewSyntaxManager : GLib.Object {
    private LanguageManager lang_manager;
    private StyleSchemeManager scheme_manager;
    private GtkSource.View preview_view;

    public PreviewSyntaxManager (GtkSource.View view) {
        this.preview_view = view;
        lang_manager = LanguageManager.get_default ();
        scheme_manager = new StyleSchemeManager ();

        // 注册应用自带主题目录 (平台差异由 Platform.get_data_dir() 处理)
        string app_data_dir = Platform.get_data_dir ();
        string theme_dir = GLib.Path.build_filename (app_data_dir, "gtksourceview-5", "styles");
        if (FileUtils.test (theme_dir, FileTest.EXISTS)) {
            string[] search_paths = scheme_manager.get_search_path ();
            var new_paths = new string[search_paths.length + 1];
            new_paths[0] = theme_dir;
            for (int i = 0; i < search_paths.length; i++) new_paths[i + 1] = search_paths[i];
            scheme_manager.set_search_path ((string?[]?) new_paths);
        }

        apply_scheme ();
        preview_view.set_wrap_mode (Gtk.WrapMode.WORD_CHAR);
        preview_view.add_css_class ("sourceview");
        preview_view.set_show_line_numbers (false);
        // 预览区是只读的: 设为不可编辑可避免用户在预览内输入时开启 user-action,
        // 否则随后程序化 set_text/insert 会在 user-action 进行中触发
        // "Cannot begin irreversible action while in user action" 等告警.
        preview_view.set_editable (false);
        // 预览无需撤销栈; 关闭 undo 可避免 GtkSource 撤销管理器对缓冲区
        // 增删操作的 user-action 包裹, 进一步消除上述告警及其引发的
        // 缓冲区迭代器/a11y 越界 (end >= start) 告警.
        var buf = preview_view.get_buffer () as Buffer;
        if (buf != null) {
            buf.set_enable_undo (false);
        }

        var style_manager = Adw.StyleManager.get_default ();
        style_manager.notify["dark"].connect (() => apply_scheme ());
    }

    public void apply_scheme () {
        bool dark = Adw.StyleManager.get_default ().dark;
        string scheme_id = dark ? "filecollector-dark" : "filecollector-light";
        var scheme = scheme_manager.get_scheme (scheme_id);
        if (scheme != null) {
            (preview_view.get_buffer () as Buffer).set_style_scheme (scheme);
        }
    }

    public Language? guess_language (string? file_path) {
        if (file_path == null) return null;
        var lang = lang_manager.guess_language (file_path, null);
        if (lang != null) return lang;
        var file = GLib.File.new_for_path (file_path);
        try {
            var info = file.query_info (FileAttribute.STANDARD_CONTENT_TYPE, FileQueryInfoFlags.NONE, null);
            string? mime = info.get_content_type ();
            if (mime != null) {
                lang = lang_manager.guess_language (null, mime);
            }
        } catch (Error e) { /* ignore */ }
        return lang;
    }

    public void apply_with_highlight (string text, string? file_path) {
        var buffer = preview_view.get_buffer () as Buffer;
        var lang = guess_language (file_path);
        buffer.set_language (lang);
        buffer.set_highlight_syntax (true);
        // 直接 set_text(text) 一次完成替换, 避免先 set_text("") 造成缓冲区瞬间
        // 为空, 否则 a11y 层可能在空缓冲区间歇读取而触发
        // "gtk_accessible_text_get_contents: assertion 'end >= start' failed".
        buffer.set_text (text, -1);
        preview_view.set_show_line_numbers (text.length > 0);
    }

    public void apply_no_highlight (string text) {
        var buffer = preview_view.get_buffer () as Buffer;
        buffer.set_highlight_syntax (false);
        buffer.set_text (text, -1);
        preview_view.set_show_line_numbers (text.length > 0);
    }
}
