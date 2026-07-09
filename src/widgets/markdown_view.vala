// MarkdownView: 用 cmark-gfm AST 构建 GTK4 widget 树, 渲染 Markdown 内容.
// 支持: 标题, 段落, 粗体/斜体/代码, 链接, 列表, 代码块, 引用, 分割线, 表格.
using GLib;
using Gee;

public class MarkdownView : Gtk.Box {

    private static bool extensions_registered = false;

    public MarkdownView (string markdown) {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 6);
        set_hexpand (true);
        build (markdown);
    }

    private void build (string markdown) {
        // 防止极长/畸形 Markdown 导致解析资源耗尽: 超过 1MB 降级为纯文本
        const size_t MAX_MARKDOWN_BYTES = 1024 * 1024;
        if (markdown.length > (int) MAX_MARKDOWN_BYTES) {
            append (make_label (markdown.substring (0, 1000) + _("\n…(内容过长, 已截断)"), false));
            return;
        }

        // 注册 GFM 核心扩展 (table, strikethrough 等), 只需一次
        if (!extensions_registered) {
            Cmark.core_extensions_ensure_registered ();
            extensions_registered = true;
        }

        // 用 parser API + table 扩展解析
        // parser 为 owned Compact 实例, 作用域结束时自动调用 cmark_parser_free
        var parser = new Cmark.Parser (Cmark.Options.DEFAULT | Cmark.Options.SMART);
        unowned Cmark.SyntaxExtension? table_ext = Cmark.find_syntax_extension ("table");
        if (table_ext != null) {
            parser.attach_syntax_extension (table_ext);
        }
        parser.feed (markdown, markdown.length);
        // finish() 返回 owned Node?: 整棵 AST 的根, 释放根会递归释放所有子节点
        owned Cmark.Node? doc = parser.finish ();
        if (doc == null) {
            // 解析失败, 降级为纯文本 (parser 内部已清理任何中间节点)
            append (make_label (markdown, false));
            return;
        }
        // try-finally 确保 AST 在任何退出路径 (含异常) 下都被释放.
        // Vala 编译器已为 owned Compact 变量自动生成 finally 释放, 此处显式标注以明确意图.
        try {
            unowned Cmark.Node? child = doc.first_child ();
            while (child != null) {
                var widget = build_block (child);
                if (widget != null) append (widget);
                child = child.next ();
            }
        } finally {
            // doc 为 owned Compact 实例: 作用域结束时 Vala 自动调用 cmark_node_free,
            // 该函数会递归释放整棵 AST (所有子节点), 无需手动管理.
            // parser 同理, 由 cmark_parser_free 在作用域结束时释放.
        }
    }

    // ── 块级元素 ──────────────────────────────────────────────────

    private Gtk.Widget? build_block (Cmark.Node node) {
        // 先检查动态注册的节点类型 (table 等)
        string type_str = node.get_type_string ();
        if (type_str == "table") {
            return build_table (node);
        } else if (type_str == "table_row") {
            // table_row 由 build_table 处理, 不应单独出现
            return null;
        } else if (type_str == "table_cell") {
            return null;
        }

        switch (node.get_type ()) {
            case Cmark.NodeType.HEADING:
                return build_heading (node);
            case Cmark.NodeType.PARAGRAPH:
                return build_paragraph (node);
            case Cmark.NodeType.CODE_BLOCK:
                return build_code_block (node);
            case Cmark.NodeType.LIST:
                return build_list (node, false, 0);
            case Cmark.NodeType.BLOCK_QUOTE:
                return build_block_quote (node);
            case Cmark.NodeType.THEMATIC_BREAK:
                return build_thematic_break ();
            case Cmark.NodeType.HTML_BLOCK:
                var lit = node.get_literal ();
                if (lit != null && lit.strip ().length > 0)
                    return make_label (lit.strip (), false);
                return null;
            default:
                return null;
        }
    }

    private Gtk.Widget build_heading (Cmark.Node node) {
        var label = new Gtk.Label (null);
        label.xalign = 0;
        label.wrap = true;
        label.wrap_mode = Pango.WrapMode.WORD_CHAR;
        label.selectable = true;
        set_markup_safe (label, collect_inline_markup (node));
        int level = node.get_heading_level ();
        label.add_css_class ("md-heading");
        label.add_css_class (@"md-h$(level)");
        return label;
    }

    private Gtk.Widget build_paragraph (Cmark.Node node) {
        var label = make_label (null, false);
        set_markup_safe (label, collect_inline_markup (node));
        label.add_css_class ("md-paragraph");
        return label;
    }

    private Gtk.Widget build_code_block (Cmark.Node node) {
        var literal = node.get_literal () ?? "";
        var frame = new Gtk.Frame (null);
        frame.add_css_class ("md-code-block-frame");
        var code_label = new Gtk.Label (sanitize_utf8 (literal.strip ()));
        code_label.xalign = 0;
        code_label.halign = Gtk.Align.START;
        code_label.wrap = true;
        code_label.wrap_mode = Pango.WrapMode.CHAR;
        code_label.selectable = true;
        code_label.add_css_class ("md-code-block");
        code_label.set_margin_start (8);
        code_label.set_margin_end (8);
        code_label.set_margin_top (6);
        code_label.set_margin_bottom (6);
        frame.set_child (code_label);
        return frame;
    }

    private Gtk.Widget build_list (Cmark.Node node, bool ordered, int start_index) {
        bool is_ordered = (node.get_list_type () == Cmark.ListType.ORDERED_LIST);
        int index = is_ordered ? node.get_list_start () : 0;

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
        box.add_css_class ("md-list");
        box.set_margin_start (12);

        unowned Cmark.Node? item = node.first_child ();
        while (item != null) {
            if (item.get_type () == Cmark.NodeType.ITEM) {
                var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
                string marker = is_ordered ? @"$index. " : "•  ";
                var bullet = new Gtk.Label (marker);
                bullet.xalign = 0;
                bullet.valign = Gtk.Align.START;
                bullet.add_css_class ("md-list-marker");
                row.append (bullet);

                // 列表项内容: 可能是段落、嵌套列表等
                var content_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
                unowned Cmark.Node? item_child = item.first_child ();
                while (item_child != null) {
                    if (item_child.get_type () == Cmark.NodeType.PARAGRAPH) {
                        var lbl = make_label (null, false);
                        set_markup_safe (lbl, collect_inline_markup (item_child));
                        lbl.add_css_class ("md-list-item");
                        content_box.append (lbl);
                    } else if (item_child.get_type () == Cmark.NodeType.LIST) {
                        content_box.append (build_list (item_child, false, 0));
                    } else {
                        var w = build_block (item_child);
                        if (w != null) content_box.append (w);
                    }
                    item_child = item_child.next ();
                }
                row.append (content_box);
                box.append (row);
                if (is_ordered) index++;
            }
            item = item.next ();
        }
        return box;
    }

    private Gtk.Widget build_block_quote (Cmark.Node node) {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
        box.add_css_class ("md-blockquote");
        box.set_margin_start (12);
        unowned Cmark.Node? child = node.first_child ();
        while (child != null) {
            var w = build_block (child);
            if (w != null) box.append (w);
            child = child.next ();
        }
        return box;
    }

    private Gtk.Widget build_thematic_break () {
        // 改用原生 Gtk.Separator (水平), 配合 .md-hr 主题样式, 自带方向/无障碍语义
        var sep = new Gtk.Separator (Gtk.Orientation.HORIZONTAL);
        sep.add_css_class ("md-hr");
        return sep;
    }

    private Gtk.Widget build_table (Cmark.Node node) {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        box.add_css_class ("md-table");

        // 遍历 table_row
        unowned Cmark.Node? row = node.first_child ();
        while (row != null) {
            if (row.get_type_string () == "table_row") {
                bool is_header = (Cmark.get_table_row_is_header (row) != 0);
                var row_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
                row_box.add_css_class (is_header ? "md-table-header" : "md-table-row");

                unowned Cmark.Node? cell = row.first_child ();
                while (cell != null) {
                    if (cell.get_type_string () == "table_cell") {
                        var cell_label = make_label (null, false);
                        set_markup_safe (cell_label, collect_inline_markup (cell));
                        cell_label.add_css_class ("md-table-cell");
                        if (is_header) cell_label.add_css_class ("md-table-header-cell");
                        cell_label.hexpand = true;
                        cell_label.halign = Gtk.Align.START;
                        cell_label.set_margin_start (6);
                        cell_label.set_margin_end (6);
                        cell_label.set_margin_top (3);
                        cell_label.set_margin_bottom (3);
                        row_box.append (cell_label);
                    }
                    cell = cell.next ();
                }
                box.append (row_box);
            }
            row = row.next ();
        }
        return box;
    }

    // ── 行内元素: 收集为 Pango markup 字符串 ──────────────────────

    private string collect_inline_markup (Cmark.Node node) {
        var sb = new StringBuilder ();
        unowned Cmark.Node? child = node.first_child ();
        while (child != null) {
            render_inline (sb, child);
            child = child.next ();
        }
        return sb.str;
    }

    private void render_inline (StringBuilder sb, Cmark.Node node) {
        switch (node.get_type ()) {
            case Cmark.NodeType.TEXT:
                sb.append (escape_markup (node.get_literal () ?? ""));
                break;
            case Cmark.NodeType.SOFTBREAK:
            case Cmark.NodeType.LINEBREAK:
                sb.append ("\n");
                break;
            case Cmark.NodeType.CODE:
                sb.append ("<span font_family=\"monospace\" background=\"#00000010\">");
                sb.append (escape_markup (node.get_literal () ?? ""));
                sb.append ("</span>");
                break;
            case Cmark.NodeType.EMPH:
                sb.append ("<i>");
                render_children (sb, node);
                sb.append ("</i>");
                break;
            case Cmark.NodeType.STRONG:
                sb.append ("<b>");
                render_children (sb, node);
                sb.append ("</b>");
                break;
            case Cmark.NodeType.LINK:
                var url = node.get_url () ?? "";
                sb.append ("<span color=\"#3584e4\" underline=\"single\">");
                render_children (sb, node);
                sb.append ("</span>");
                // URL 作为注释附在后面 (GTK Label 无法直接做超链接)
                break;
            case Cmark.NodeType.IMAGE:
                // 忽略图片, 显示 alt 文本
                render_children (sb, node);
                break;
            case Cmark.NodeType.HTML_INLINE:
                sb.append (escape_markup (node.get_literal () ?? ""));
                break;
            default:
                render_children (sb, node);
                break;
        }
    }

    private void render_children (StringBuilder sb, Cmark.Node node) {
        unowned Cmark.Node? child = node.first_child ();
        while (child != null) {
            render_inline (sb, child);
            child = child.next ();
        }
    }

    // ── 辅助 ──────────────────────────────────────────────────────

    private Gtk.Label make_label (string? text, bool use_markup) {
        // 确保传入的文本是有效 UTF-8, 避免 Pango 警告
        string safe_text = sanitize_utf8 (text);
        var label = new Gtk.Label (safe_text);
        label.xalign = 0;
        label.wrap = true;
        label.wrap_mode = Pango.WrapMode.WORD_CHAR;
        label.selectable = true;
        label.use_markup = use_markup;
        return label;
    }

    // 安全设置 markup: 如果解析失败则回退到纯文本, 避免整个 label 为空
    private void set_markup_safe (Gtk.Label label, string markup) {
        try {
            // 用 Pango 解析验证 markup 是否有效
            Pango.parse_markup (markup, -1, 0, null, null, null);
            label.set_markup (markup);
        } catch (GLib.Error e) {
            // markup 无效, 回退到纯文本 (已转义)
            label.set_text (sanitize_utf8 (markup));
        }
    }

    // 清洗 UTF-8: 用 replacement character 替换无效字节, 确保字符串对 Pango 安全
    private string sanitize_utf8 (string? text) {
        return UIHelpers.sanitize_utf8 (text);
    }

    // 转义 Pango markup 特殊字符 (保留 UTF-8 多字节序列)
    private string escape_markup (string text) {
        // 先清洗 UTF-8, 再用 GLib 的标准转义函数
        return GLib.Markup.escape_text (sanitize_utf8 (text), -1);
    }
}
