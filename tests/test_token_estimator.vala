// TokenEstimator 单元测试
// 验证 estimate_tokens_fast / estimate_file_tokens_fast / estimate_snippet_tokens_fast
// 的核心行为: 空输入、ASCII、CJK、数字、标点、accented Latin、文件大小上限等.

int pass_count = 0;
int fail_count = 0;

void pass (string desc) { print ("PASS: %s\n", desc); pass_count++; }
void fail (string desc, string detail = "") {
    print ("FAIL: %s%s%s\n", desc, detail.length > 0 ? " - " : "", detail);
    fail_count++;
}
void assert_true (string desc, bool cond) {
    if (cond) pass (desc); else fail (desc);
}
void assert_eq_int (string desc, int expected, int actual) {
    if (expected == actual) pass (desc);
    else fail (desc, @"期望 $expected, 实际 $actual");
}
void assert_ge (string desc, int actual, int min) {
    if (actual >= min) pass (desc);
    else fail (desc, @"实际 $actual < 最小 $min");
}

// ─── estimate_tokens_fast: 空输入 ───────────────────────────────
void test_estimate_tokens_fast_null () {
    print ("\n=== test_estimate_tokens_fast_null ===\n");
    assert_eq_int ("null 输入返回 0", 0, TokenEstimator.estimate_tokens_fast (null));
    assert_eq_int ("空字符串返回 0", 0, TokenEstimator.estimate_tokens_fast (""));
}

// ─── estimate_tokens_fast: 纯 ASCII ─────────────────────────────
// "hello" 5 字符, 每个非空 ASCII 算 0.25 token, 共 1.25, *1.05=1.3125 → ceil=2
void test_estimate_tokens_fast_ascii () {
    print ("\n=== test_estimate_tokens_fast_ascii ===\n");
    int n = TokenEstimator.estimate_tokens_fast ("hello");
    assert_ge ("纯 ASCII 至少 1 token", n, 1);
    // 100 个非空 ASCII 字符 → 25 token *1.05 ≈ 27
    var sb = new StringBuilder ();
    for (int i = 0; i < 100; i++) sb.append_c ('a');
    int n100 = TokenEstimator.estimate_tokens_fast (sb.str);
    assert_ge ("100 个 ASCII 字符 ≥ 25 token", n100, 25);
}

// ─── estimate_tokens_fast: CJK ──────────────────────────────────
// 每个汉字 = 1.0 token, "你好" 2 字 → 2.1 → ceil=3
void test_estimate_tokens_fast_cjk () {
    print ("\n=== test_estimate_tokens_fast_cjk ===\n");
    int n = TokenEstimator.estimate_tokens_fast ("你好");
    assert_eq_int ("2 个 CJK 字符 = 3 token (2*1.05 ceil)", 3, n);
    // 10 个汉字 = 10 * 1.05 = 10.5 → ceil=11
    int n10 = TokenEstimator.estimate_tokens_fast ("一二三四五六七八九十");
    assert_eq_int ("10 个 CJK 字符 = 11 token", 11, n10);
}

// ─── estimate_tokens_fast: 空白字符忽略 ─────────────────────────
void test_estimate_tokens_fast_whitespace_ignored () {
    print ("\n=== test_estimate_tokens_fast_whitespace_ignored ===\n");
    int a = TokenEstimator.estimate_tokens_fast ("ab");
    int b = TokenEstimator.estimate_tokens_fast ("a b");
    // 中间加空格不应改变 token 数 (空格被忽略)
    assert_eq_int ("空格不计入 token", a, b);
}

// ─── estimate_tokens_fast: 数字分组 ─────────────────────────────
// "123" 是一个数字组 = 1 token, *1.05 = 1.05 → ceil=2
void test_estimate_tokens_fast_digits_grouped () {
    print ("\n=== test_estimate_tokens_fast_digits_grouped ===\n");
    int one = TokenEstimator.estimate_tokens_fast ("123");
    int three = TokenEstimator.estimate_tokens_fast ("1 2 3");
    // "123" = 1 组, "1 2 3" = 3 组 (空格分隔)
    assert_true ("123 是 1 组 (少于 1 2 3 的 3 组)", one < three);
}

// ─── estimate_tokens_fast: 标点 ─────────────────────────────────
// 标点 0.5 token
void test_estimate_tokens_fast_punctuation () {
    print ("\n=== test_estimate_tokens_fast_punctuation ===\n");
    // "!!!" 3 个标点 = 1.5 *1.05 = 1.575 → ceil=2
    int n = TokenEstimator.estimate_tokens_fast ("!!!");
    assert_eq_int ("3 个标点 = 2 token", 2, n);
}

// ─── estimate_file_tokens_fast: 基本功能 ────────────────────────
void test_estimate_file_tokens_fast_basic () {
    print ("\n=== test_estimate_file_tokens_fast_basic ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_tok_XXXXXX");
    string path = Path.build_filename (tmpdir, "small.txt");
    try {
        FileUtils.set_contents (path, "hello world");
        int n = TokenEstimator.estimate_file_tokens_fast (path);
        // "hello world" 11 字节 / 3.5 ≈ 3.14 → ceil=4
        assert_eq_int ("小文件按体积估算", 4, n);
    } catch (Error e) {
        fail ("basic 异常", e.message);
    }
    FileUtils.unlink (path);
    DirUtils.remove (tmpdir);
}

// ─── estimate_file_tokens_fast: 不存在的文件 ────────────────────
void test_estimate_file_tokens_fast_nonexistent () {
    print ("\n=== test_estimate_file_tokens_fast_nonexistent ===\n");
    int n = TokenEstimator.estimate_file_tokens_fast ("/nonexistent/path/file.txt");
    assert_eq_int ("不存在的文件返回 0", 0, n);
}

// ─── estimate_file_tokens_fast: 超过 10MB ───────────────────────
void test_estimate_file_tokens_fast_too_large () {
    print ("\n=== test_estimate_file_tokens_fast_too_large ===\n");
    // 写一个 > 10MB 的真实文件 (1MB × 11 = 11MB)
    string tmpdir = DirUtils.make_tmp ("fc_tok_XXXXXX");
    string path = Path.build_filename (tmpdir, "large.txt");
    try {
        var f = File.new_for_path (path);
        var os = f.replace (null, false, FileCreateFlags.NONE);
        uint8[] chunk = new uint8[1024 * 1024];
        for (int i = 0; i < chunk.length; i++) chunk[i] = (uint8) 'x';
        for (int i = 0; i < 11; i++) {
            os.write (chunk);
        }
        os.close ();
        int n = TokenEstimator.estimate_file_tokens_fast (path);
        assert_eq_int (">10MB 文件返回 0 (跳过估算)", 0, n);
    } catch (Error e) {
        fail ("too_large 异常", e.message);
    }
    FileUtils.unlink (path);
    DirUtils.remove (tmpdir);
}

// ─── estimate_snippet_tokens_fast: 基本片段 ─────────────────────
void test_estimate_snippet_tokens_fast_basic () {
    print ("\n=== test_estimate_snippet_tokens_fast_basic ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_tok_XXXXXX");
    string path = Path.build_filename (tmpdir, "snippet.txt");
    try {
        // 5 行内容
        var sb = new StringBuilder ();
        for (int i = 1; i <= 5; i++) {
            sb.append_printf ("line %d\n", i);
        }
        FileUtils.set_contents (path, sb.str);

        // 取第 2-3 行
        int n = TokenEstimator.estimate_snippet_tokens_fast (path, 2, 3);
        assert_true ("第 2-3 行返回非零 token", n > 0);

        // 取所有 5 行
        int n_all = TokenEstimator.estimate_snippet_tokens_fast (path, 1, 5);
        assert_true ("全部 5 行 token > 第 2-3 行 token", n_all > n);
    } catch (Error e) {
        fail ("snippet_basic 异常", e.message);
    }
    FileUtils.unlink (path);
    DirUtils.remove (tmpdir);
}

// ─── estimate_snippet_tokens_fast: 越界参数 ─────────────────────
void test_estimate_snippet_tokens_fast_invalid_range () {
    print ("\n=== test_estimate_snippet_tokens_fast_invalid_range ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_tok_XXXXXX");
    string path = Path.build_filename (tmpdir, "x.txt");
    try { FileUtils.set_contents (path, "hello"); } catch (Error e) {}

    // start_line <= 0 → 返回 0
    assert_eq_int ("start_line=0 返回 0", 0,
        TokenEstimator.estimate_snippet_tokens_fast (path, 0, 5));
    // start_line > end_line → 返回 0
    assert_eq_int ("start>end 返回 0", 0,
        TokenEstimator.estimate_snippet_tokens_fast (path, 5, 1));

    FileUtils.unlink (path);
    DirUtils.remove (tmpdir);
}

// ─── estimate_snippet_tokens_fast: 不存在的文件 ─────────────────
void test_estimate_snippet_tokens_fast_nonexistent () {
    print ("\n=== test_estimate_snippet_tokens_fast_nonexistent ===\n");
    int n = TokenEstimator.estimate_snippet_tokens_fast (
        "/nonexistent/file.txt", 1, 10);
    assert_eq_int ("不存在的文件返回 0", 0, n);
}

public static int main (string[] args) {
    print ("========== TokenEstimator 测试开始 ==========\n");

    test_estimate_tokens_fast_null ();
    test_estimate_tokens_fast_ascii ();
    test_estimate_tokens_fast_cjk ();
    test_estimate_tokens_fast_whitespace_ignored ();
    test_estimate_tokens_fast_digits_grouped ();
    test_estimate_tokens_fast_punctuation ();
    test_estimate_file_tokens_fast_basic ();
    test_estimate_file_tokens_fast_nonexistent ();
    test_estimate_file_tokens_fast_too_large ();
    test_estimate_snippet_tokens_fast_basic ();
    test_estimate_snippet_tokens_fast_invalid_range ();
    test_estimate_snippet_tokens_fast_nonexistent ();

    print ("\n========== 测试结果 ==========\n");
    print ("PASS: %d, FAIL: %d\n", pass_count, fail_count);
    return fail_count > 0 ? 1 : 0;
}
