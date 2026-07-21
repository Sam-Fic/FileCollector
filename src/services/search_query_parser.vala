using Gee;

// 解析器内部抛出的语法错误类型. 必须声明在类外部 (Vala 不支持内部 errordomain).
// 用 SearchQueryParseError 而非 Error, 避免与 GLib.Error 在类作用域内混淆.
private errordomain SearchQueryParseError { INVALID }

// 布尔搜索查询解析器 (search_files 工具专用)
//
// 支持的语法:
//   term               裸词 (不含 & | ( ) " 的连续字符)
//   "..."              引号包裹的短语(可含空格 / 任意字符)
//   a & b              AND: 两个原子必须同时匹配
//   a | b              OR: 任一原子匹配即可
//   (a | b) & c        括号分组, & 优先级高于 |
//   a b                空格分隔的相邻原子也作 AND (与 a & b 等价)
//
// 解析失败时回退为"整个字符串当单个 TERM", 保证任何 query 都能用于搜索.
//
// 设计要点:
//   - 纯逻辑类, 不依赖 GTK / GFile, 便于单元测试.
//   - 用递归下降: expr → or_expr → and_expr → atom. 优先级: | < & < 隐式 AND.
//   - matches 方法对 AND/OR 递归求值; TERM 用 case-insensitive 子串匹配.
//   - 大小写敏感由调用方传入 case_sensitive, 解析阶段不处理大小写.

public class SearchQueryTerm : GLib.Object {
    public string text { get; set; }

    public SearchQueryTerm (string text) {
        this.text = text;
    }

    public bool matches (string line, bool case_sensitive) {
        if (text.length == 0) return true;
        if (case_sensitive) return line.contains (text);
        return line.down ().contains (text.down ());
    }
}

public class SearchQueryNode : GLib.Object {
    // 用 NodeType 而非 Type: Type 在 Vala 中与 GLib.Type 冲突, 且 type 作为属性名
    // 是 Vala 保留关键字 (用于 typeof). 改用 NodeType / node_type 避开限制.
    public enum NodeType { TERM, AND, OR }
    public NodeType node_type { get; set; }
    public SearchQueryTerm? term { get; set; }                       // 仅 NodeType.TERM 用
    public Gee.ArrayList<SearchQueryNode> children { get; set; default = new Gee.ArrayList<SearchQueryNode> (); }

    public static SearchQueryNode term_node (string text) {
        var n = new SearchQueryNode ();
        n.node_type = NodeType.TERM;
        n.term = new SearchQueryTerm (text);
        return n;
    }

    public static SearchQueryNode and_node (SearchQueryNode a, SearchQueryNode b) {
        var n = new SearchQueryNode ();
        n.node_type = NodeType.AND;
        // 同伴是 AND 时扁平化合并, 避免深嵌套
        if (a.node_type == NodeType.AND) n.children.add_all (a.children); else n.children.add (a);
        if (b.node_type == NodeType.AND) n.children.add_all (b.children); else n.children.add (b);
        return n;
    }

    public static SearchQueryNode or_node (SearchQueryNode a, SearchQueryNode b) {
        var n = new SearchQueryNode ();
        n.node_type = NodeType.OR;
        if (a.node_type == NodeType.OR) n.children.add_all (a.children); else n.children.add (a);
        if (b.node_type == NodeType.OR) n.children.add_all (b.children); else n.children.add (b);
        return n;
    }

    // 递归求值: AND 要求全部子节点匹配, OR 要求至少一个匹配, TERM 调用 term.matches.
    public bool matches (string line, bool case_sensitive) {
        switch (node_type) {
            case NodeType.TERM:
                return term != null ? term.matches (line, case_sensitive) : true;
            case NodeType.AND:
                foreach (var c in children) {
                    if (!c.matches (line, case_sensitive)) return false;
                }
                return children.size > 0;
            case NodeType.OR:
                foreach (var c in children) {
                    if (c.matches (line, case_sensitive)) return true;
                }
                return false;
            default:
                return false;
        }
    }

    // 调试 / 测试用: 把解析树序列化为可读字符串, 用于断言解析结构.
    public string to_debug_string () {
        switch (node_type) {
            case NodeType.TERM:
                return "\"" + (term != null ? term.text : "") + "\"";
            case NodeType.AND:
                var parts = new Gee.ArrayList<string> ();
                foreach (var c in children) parts.add (c.to_debug_string ());
                return "AND(" + string.joinv (", ", (string[]) parts.to_array ()) + ")";
            case NodeType.OR:
                var parts = new Gee.ArrayList<string> ();
                foreach (var c in children) parts.add (c.to_debug_string ());
                return "OR(" + string.joinv (", ", (string[]) parts.to_array ()) + ")";
            default:
                return "?";
        }
    }
}

public class SearchQueryParser : GLib.Object {

    // ─── Token ──────────────────────────────────────────────────────
    // 用 class 而非 struct: Gee.ArrayList<T> 要求 T 是引用类型或可空装箱值类型,
    // struct 无法直接作为泛型参数 (Vala 限制). Token 实例数量有限 (查询长度),
    // 引用语义的额外开销可忽略.
    private enum TokenType { AND, OR, LPAREN, RPAREN, TERM, EOF }
    private class Token {
        public TokenType type;
        public string text;
        public Token (TokenType t, string s = "") { type = t; text = s; }
    }

    // ─── 入口: 解析查询字符串, 失败回退为单 TERM ───────────────────────
    // 空字符串 / 仅空白 / 仅运算符 → 返回 null, 调用方据此跳过搜索.
    public static SearchQueryNode? parse (string query) {
        var tokens = tokenize (query);
        // 必须含至少一个 TERM token; 只有运算符/括号/EOF 的查询无意义, 返回 null.
        // (tokenize 总会追加 EOF 哨兵, 故 tokens.is_empty 永远为 false, 不能用它判断.)
        bool has_term = false;
        foreach (var t in tokens) {
            if (t.type == TokenType.TERM) { has_term = true; break; }
        }
        if (!has_term) return null;

        var p = new ParserState ();
        p.tokens = tokens;
        p.pos = 0;
        try {
            var node = parse_or (p);
            // 解析后必须到 EOF, 否则视为语法错误 → 回退
            if (p.peek ().type != TokenType.EOF) {
                return fallback (query);
            }
            return node;
        } catch (SearchQueryParseError e) {
            return fallback (query);
        }
    }

    // 回退: 把整个原始字符串作为单个 TERM. 适用于 query 是裸词
    // 或包含无法解析的运算符序列的情况, 保证搜索总能进行.
    private static SearchQueryNode? fallback (string query) {
        string trimmed = query.strip ();
        if (trimmed.length == 0) return null;
        return SearchQueryNode.term_node (trimmed);
    }

    // ─── Tokenizer ──────────────────────────────────────────────────
    // 把原始字符串切成 Token 流. 引号内所有字符都进入 TERM text (含空格 / 运算符).
    // 裸词遇到 & | ( ) 或空白即终止. 连续的空白合并为一个隐式 AND.
    private static Gee.ArrayList<Token> tokenize (string s) {
        var tokens = new Gee.ArrayList<Token> ();
        var sb = new StringBuilder ();
        bool in_term = false;

        int i = 0;
        while (i < s.length) {
            unichar c = s.get_char (s.index_of_nth_char (i));
            i++;

            // 引号: 读到下一个引号(无转义), 整体作为 TERM. 空引号也算一个空 TERM
            // (虽然没意义但不报错). 跨行引号不支持, 遇到 \n 也结束.
            if (c == '"') {
                if (in_term) {
                    // 之前的裸词先收尾, 再开始读引号短语
                    flush_term (sb, tokens, ref in_term);
                }
                sb = new StringBuilder ();
                bool closed = false;
                while (i < s.length) {
                    unichar d = s.get_char (s.index_of_nth_char (i));
                    i++;
                    if (d == '"') { closed = true; break; }
                    sb.append_unichar (d);
                }
                // 即使没闭合也把已读内容当 TERM (容错)
                tokens.add (new Token (TokenType.TERM, sb.str));
                sb = new StringBuilder ();
                in_term = false;
                continue;
            }

            if (c == '&') {
                flush_term (sb, tokens, ref in_term);
                tokens.add (new Token (TokenType.AND));
                continue;
            }
            if (c == '|') {
                flush_term (sb, tokens, ref in_term);
                tokens.add (new Token (TokenType.OR));
                continue;
            }
            if (c == '(') {
                flush_term (sb, tokens, ref in_term);
                tokens.add (new Token (TokenType.LPAREN));
                continue;
            }
            if (c == ')') {
                flush_term (sb, tokens, ref in_term);
                tokens.add (new Token (TokenType.RPAREN));
                continue;
            }
            if (c.isspace ()) {
                flush_term (sb, tokens, ref in_term);
                continue;
            }
            // 普通字符: 累积到当前裸词
            sb.append_unichar (c);
            in_term = true;
        }
        flush_term (sb, tokens, ref in_term);
        // 末尾追加 EOF 哨兵: peek()/next() 在 parse_or/and/atom 中会被调用,
        // 没有哨兵时 pos 越界会触发 gee_array_list 的 assertion. 有了 EOF,
        // parse_atom 看到 EOF 会抛 INVALID, 由上层 fallback 接住.
        tokens.add (new Token (TokenType.EOF));
        return tokens;
    }

    private static void flush_term (StringBuilder sb, Gee.ArrayList<Token> tokens, ref bool in_term) {
        if (!in_term) return;
        if (sb.len > 0) {
            tokens.add (new Token (TokenType.TERM, sb.str));
        }
        sb.erase ();
        in_term = false;
    }

    // ─── Parser (递归下降) ───────────────────────────────────────────
    private class ParserState {
        public Gee.ArrayList<Token> tokens;
        public int pos;
        public Token peek () { return tokens[pos]; }
        public Token next () { return tokens[pos++]; }
    }

    // or_expr := and_expr ('|' and_expr)*
    private static SearchQueryNode parse_or (ParserState p) throws SearchQueryParseError {
        var left = parse_and (p);
        while (p.peek ().type == TokenType.OR) {
            p.next ();
            var right = parse_and (p);
            left = SearchQueryNode.or_node (left, right);
        }
        return left;
    }

    // and_expr := atom (('&' | 隐式) atom)*
    // 隐式 AND: 当下一个 token 是 TERM / LPAREN 时, 不需要显式 & 也作 AND.
    // 这样 "foo bar" 与 "foo & bar" 等价, 贴近用户对"多词搜索"的直觉.
    private static SearchQueryNode parse_and (ParserState p) throws SearchQueryParseError {
        var left = parse_atom (p);
        while (true) {
            var t = p.peek ().type;
            if (t == TokenType.AND) {
                p.next ();
                var right = parse_atom (p);
                left = SearchQueryNode.and_node (left, right);
            } else if (t == TokenType.TERM || t == TokenType.LPAREN) {
                // 隐式 AND
                var right = parse_atom (p);
                left = SearchQueryNode.and_node (left, right);
            } else {
                break;
            }
        }
        return left;
    }

    // atom := '(' expr ')' | TERM
    // 空括号或意外 EOF → 抛 SearchQueryParseError, 由上层 fallback 接住.
    private static SearchQueryNode parse_atom (ParserState p) throws SearchQueryParseError {
        var t = p.peek ();
        if (t.type == TokenType.LPAREN) {
            p.next ();
            var node = parse_or (p);
            if (p.peek ().type != TokenType.RPAREN) {
                throw new SearchQueryParseError.INVALID ("expected )");
            }
            p.next ();
            return node;
        }
        if (t.type == TokenType.TERM) {
            p.next ();
            return SearchQueryNode.term_node (t.text);
        }
        throw new SearchQueryParseError.INVALID ("expected atom, got %d".printf ((int) t.type));
    }
}

