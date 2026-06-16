// cmark-gfm (GitHub Flavored Markdown) Vala 绑定
// 支持 table 扩展 (CMARK_NODE_TABLE 等是运行时动态注册的)
[CCode (cprefix = "cmark_", cheader_filename = "cmark-gfm.h,cmark-gfm-core-extensions.h,cmark-gfm-extension_api.h")]
namespace Cmark {

    [CCode (cname = "cmark_node_type", cprefix = "CMARK_NODE_")]
    public enum NodeType {
        NONE = 0,
        DOCUMENT = 0x8001,
        BLOCK_QUOTE = 0x8002,
        LIST = 0x8003,
        ITEM = 0x8004,
        CODE_BLOCK = 0x8005,
        HTML_BLOCK = 0x8006,
        CUSTOM_BLOCK = 0x8007,
        PARAGRAPH = 0x8008,
        HEADING = 0x8009,
        THEMATIC_BREAK = 0x800a,
        // 注意: TABLE/TABLE_ROW/TABLE_CELL 是运行时动态注册的,
        // 不在此枚举中, 需用 get_type_string() 判断
        TEXT = 0xc001,
        SOFTBREAK = 0xc002,
        LINEBREAK = 0xc003,
        CODE = 0xc004,
        HTML_INLINE = 0xc005,
        CUSTOM_INLINE = 0xc006,
        EMPH = 0xc007,
        STRONG = 0xc008,
        LINK = 0xc009,
        IMAGE = 0xc00a
    }

    [CCode (cname = "cmark_list_type", cprefix = "CMARK_")]
    public enum ListType {
        NO_LIST,
        BULLET_LIST,
        ORDERED_LIST
    }

    [CCode (cname = "int", cprefix = "CMARK_OPT_")]
    public enum Options {
        DEFAULT = 0,
        SOURCEPOS = 1,
        HARDBREAKS = 2,
        UNSAFE = 4,
        NOBREAKS = 8,
        VALIDATE_UTF8 = 16,
        SMART = 32,
        GITHUB_PRE_LANG = 64,
        LIBERAL_HTML_TAG = 128,
        FOOTNOTES = 256,
        STRIKETHROUGH_DOUBLE_TILDE = 512,
        TABLE_PREFER_STYLE_ATTRIBUTES = 1024,
        TABLE = 2048
    }

    [CCode (cname = "cmark_node", free_function = "cmark_node_free")]
    [Compact]
    public class Node {
        [CCode (cname = "cmark_node_next")]
        public unowned Node? next ();
        [CCode (cname = "cmark_node_first_child")]
        public unowned Node? first_child ();
        [CCode (cname = "cmark_node_get_type")]
        public NodeType get_type ();
        [CCode (cname = "cmark_node_get_type_string")]
        public unowned string get_type_string ();
        [CCode (cname = "cmark_node_get_literal")]
        public unowned string? get_literal ();
        [CCode (cname = "cmark_node_get_heading_level")]
        public int get_heading_level ();
        [CCode (cname = "cmark_node_get_list_type")]
        public ListType get_list_type ();
        [CCode (cname = "cmark_node_get_list_start")]
        public int get_list_start ();
        [CCode (cname = "cmark_node_get_url")]
        public unowned string? get_url ();
        [CCode (cname = "cmark_node_get_title")]
        public unowned string? get_title ();
        [CCode (cname = "cmark_node_get_fence_info")]
        public unowned string? get_fence_info ();
    }

    // Parser API (cmark-gfm 需要用 parser + 扩展来支持表格)
    [CCode (cname = "cmark_parser", free_function = "cmark_parser_free")]
    [Compact]
    public class Parser {
        [CCode (cname = "cmark_parser_new")]
        public Parser (int options);
        [CCode (cname = "cmark_parser_feed")]
        public void feed (string buffer, size_t len);
        [CCode (cname = "cmark_parser_finish")]
        public Node? finish ();
        [CCode (cname = "cmark_parser_attach_syntax_extension")]
        public int attach_syntax_extension (SyntaxExtension ext);
    }

    [CCode (cname = "cmark_syntax_extension")]
    [Compact]
    public class SyntaxExtension {
    }

    [CCode (cname = "cmark_find_syntax_extension")]
    public unowned SyntaxExtension? find_syntax_extension (string name);

    [CCode (cname = "cmark_gfm_core_extensions_ensure_registered")]
    public void core_extensions_ensure_registered ();

    // 表格行是否为表头
    [CCode (cname = "cmark_gfm_extensions_get_table_row_is_header")]
    public int get_table_row_is_header (Node node);

    [CCode (cname = "cmark_markdown_to_html")]
    public string markdown_to_html (string text, size_t len, int options);
}
