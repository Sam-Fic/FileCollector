// SearchQueryParser 单元测试
//
// 覆盖: 裸词 / 引号短语 / & (AND) / | (OR) / 括号分组 / 隐式 AND /
//       解析失败回退 / matches 求值逻辑 / 空字符串.

int pass_count = 0;
int fail_count = 0;

void assert_eq (string desc, string expected, string actual) {
    if (expected == actual) {
        print ("PASS: %s\n", desc);
        pass_count++;
    } else {
        print ("FAIL: %s\n", desc);
        print ("  期望: %s\n", expected);
        print ("  实际: %s\n", actual);
        fail_count++;
    }
}

void assert_true (string desc, bool cond) {
    if (cond) {
        print ("PASS: %s\n", desc);
        pass_count++;
    } else {
        print ("FAIL: %s (期望 true)\n", desc);
        fail_count++;
    }
}

void assert_false (string desc, bool cond) {
    if (!cond) {
        print ("PASS: %s\n", desc);
        pass_count++;
    } else {
        print ("FAIL: %s (期望 false)\n", desc);
        fail_count++;
    }
}

void test_basic_term () {
    print ("\n=== test_basic_term ===\n");
    var node = SearchQueryParser.parse ("hello");
    assert_true ("裸词解析为非 null", node != null);
    assert_eq ("裸词结构", "\"hello\"", node.to_debug_string ());
}

void test_quoted_term () {
    print ("\n=== test_quoted_term ===\n");
    var node = SearchQueryParser.parse ("\"hello world\"");
    assert_true ("引号短语解析为非 null", node != null);
    assert_eq ("引号短语结构", "\"hello world\"", node.to_debug_string ());
}

void test_explicit_and () {
    print ("\n=== test_explicit_and ===\n");
    var node = SearchQueryParser.parse ("foo & bar");
    assert_eq ("foo & bar 结构", "AND(\"foo\", \"bar\")", node.to_debug_string ());
}

void test_implicit_and () {
    print ("\n=== test_implicit_and ===\n");
    var node = SearchQueryParser.parse ("foo bar");
    assert_eq ("foo bar (空格隐式 AND) 结构", "AND(\"foo\", \"bar\")", node.to_debug_string ());
}

void test_explicit_or () {
    print ("\n=== test_explicit_or ===\n");
    var node = SearchQueryParser.parse ("foo | bar");
    assert_eq ("foo | bar 结构", "OR(\"foo\", \"bar\")", node.to_debug_string ());
}

void test_precedence_and_over_or () {
    print ("\n=== test_precedence_and_over_or ===\n");
    // foo & bar | baz => OR(AND(foo, bar), baz)
    var node = SearchQueryParser.parse ("foo & bar | baz");
    assert_eq ("foo & bar | baz 结构",
               "OR(AND(\"foo\", \"bar\"), \"baz\")",
               node.to_debug_string ());
}

void test_parens () {
    print ("\n=== test_parens ===\n");
    // (a | b) & c => AND(OR(a, b), c)
    var node = SearchQueryParser.parse ("(a | b) & c");
    assert_eq ("(a | b) & c 结构",
               "AND(OR(\"a\", \"b\"), \"c\")",
               node.to_debug_string ());
}

void test_parens_override_precedence () {
    print ("\n=== test_parens_override_precedence ===\n");
    // a | (b & c) => OR(a, AND(b, c))
    var node = SearchQueryParser.parse ("a | (b & c)");
    assert_eq ("a | (b & c) 结构",
               "OR(\"a\", AND(\"b\", \"c\"))",
               node.to_debug_string ());
}

void test_matches_and () {
    print ("\n=== test_matches_and ===\n");
    var node = SearchQueryParser.parse ("foo & bar");
    assert_true ("AND 同时含两词 -> 匹配", node.matches ("foo and bar are here", false));
    assert_false ("AND 仅含一个词 -> 不匹配", node.matches ("only foo here", false));
    assert_false ("AND 都不含 -> 不匹配", node.matches ("nothing relevant", false));
}

void test_matches_or () {
    print ("\n=== test_matches_or ===\n");
    var node = SearchQueryParser.parse ("foo | bar");
    assert_true ("OR 含左词 -> 匹配", node.matches ("foo here", false));
    assert_true ("OR 含右词 -> 匹配", node.matches ("bar here", false));
    assert_false ("OR 都不含 -> 不匹配", node.matches ("nothing", false));
}

void test_matches_case_insensitive () {
    print ("\n=== test_matches_case_insensitive ===\n");
    var node = SearchQueryParser.parse ("Foo");
    assert_true ("大小写不敏感 -> 匹配", node.matches ("this is FOO text", false));
    assert_false ("大小写敏感 -> 不匹配", node.matches ("this is FOO text", true));
}

void test_matches_quoted_phrase () {
    print ("\n=== test_matches_quoted_phrase ===\n");
    var node = SearchQueryParser.parse ("\"hello world\"");
    assert_true ("短语完整出现 -> 匹配", node.matches ("say hello world loudly", false));
    assert_false ("短语被打断 -> 不匹配", node.matches ("say hello there world", false));
}

void test_matches_complex () {
    print ("\n=== test_matches_complex ===\n");
    // (foo | bar) & baz
    var node = SearchQueryParser.parse ("(foo | bar) & baz");
    assert_true ("(foo|bar)&baz - 含 foo+baz -> 匹配", node.matches ("foo baz", false));
    assert_true ("(foo|bar)&baz - 含 bar+baz -> 匹配", node.matches ("bar baz", false));
    assert_false ("(foo|bar)&baz - 只含 baz -> 不匹配", node.matches ("baz only", false));
    assert_false ("(foo|bar)&baz - 含 foo 但无 baz -> 不匹配", node.matches ("foo only", false));
}

void test_empty_query () {
    print ("\n=== test_empty_query ===\n");
    var node = SearchQueryParser.parse ("");
    assert_true ("空字符串 -> null", node == null);

    var node2 = SearchQueryParser.parse ("   ");
    assert_true ("仅空白 -> null", node2 == null);
}

void test_operators_only_fallback () {
    print ("\n=== test_operators_only_fallback ===\n");
    // 仅运算符: 解析失败, 应返回 null (没有有效 term)
    var node = SearchQueryParser.parse ("& | &");
    // & 和 | 在 tokenizer 阶段直接转 token, 无 term 进入 tokens 列表,
    // 故 tokens 为空, parse 返回 null
    assert_true ("仅运算符 -> null", node == null);
}

void test_invalid_parens_fallback () {
    print ("\n=== test_invalid_parens_fallback ===\n");
    // 不闭合括号: 解析失败 -> 回退为单 TERM (整段字符串)
    var node = SearchQueryParser.parse ("(foo");
    // 回退分支把 "(foo" strip 后作为单 TERM
    assert_eq ("(foo 不闭合 -> 单 TERM", "\"(foo\"", node.to_debug_string ());
    // 单 TERM 仍然能用于搜索: 直接子串匹配
    assert_true ("回退 TERM 匹配包含 '(foo' 的行", node.matches ("(foo bar", false));
}

void test_three_term_and () {
    print ("\n=== test_three_term_and ===\n");
    var node = SearchQueryParser.parse ("a & b & c");
    // AND 扁平化: AND(a, b, c) 而非 AND(AND(a, b), c)
    assert_eq ("a & b & c 扁平化", "AND(\"a\", \"b\", \"c\")", node.to_debug_string ());
}

void test_mixed_implicit_and_explicit () {
    print ("\n=== test_mixed_implicit_and_explicit ===\n");
    // foo bar & baz => AND(foo, bar, baz) (混合也扁平化)
    var node = SearchQueryParser.parse ("foo bar & baz");
    assert_eq ("foo bar & baz 混合", "AND(\"foo\", \"bar\", \"baz\")", node.to_debug_string ());
}

int main () {
    test_basic_term ();
    test_quoted_term ();
    test_explicit_and ();
    test_implicit_and ();
    test_explicit_or ();
    test_precedence_and_over_or ();
    test_parens ();
    test_parens_override_precedence ();
    test_matches_and ();
    test_matches_or ();
    test_matches_case_insensitive ();
    test_matches_quoted_phrase ();
    test_matches_complex ();
    test_empty_query ();
    test_operators_only_fallback ();
    test_invalid_parens_fallback ();
    test_three_term_and ();
    test_mixed_implicit_and_explicit ();

    print ("\n=== Summary ===\n");
    print ("PASS: %d, FAIL: %d\n", pass_count, fail_count);
    return fail_count > 0 ? 1 : 0;
}
