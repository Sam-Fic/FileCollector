// MultiFormatExporter 单元测试
//
// 覆盖 resolve_single_item 的各分支:
//   text 项 / missing / preprocessed 优先 / 普通文本 / 二进制 / 过大 /
//   display_path 计算 / 语言提取.

using GLib;
using Gee;

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
void assert_eq_str (string desc, string expected, string actual) {
    if (expected == actual) pass (desc);
    else fail (desc, @"期望 '$expected', 实际 '$actual'");
}

// ─── text 项: content 直接透传 ──────────────────────────────────
void test_resolve_text_item () {
    print ("\n=== test_resolve_text_item ===\n");
    var data = new ItemData ("text", null, "hello text", false);
    var ri = MultiFormatExporter.resolve_single_item (data, false, null);
    assert_true ("kind = OK", ri.kind == MultiFormatExporter.ItemKind.OK);
    assert_eq_str ("content 透传", "hello text", ri.content ?? "");
    assert_eq_str ("text 项 display_path 为空", "", ri.display_path);
}

// ─── file 项: 文件不存在 → MISSING ──────────────────────────────
void test_resolve_missing_file () {
    print ("\n=== test_resolve_missing_file ===\n");
    var data = new ItemData ("file", "/nonexistent/path/x.txt", null, false);
    var ri = MultiFormatExporter.resolve_single_item (data, false, null);
    assert_true ("kind = MISSING", ri.kind == MultiFormatExporter.ItemKind.MISSING);
    assert_true ("error_message 含 'Missing file'",
        (ri.error_message ?? "").contains ("Missing file"));
}

// ─── file 项: is_missing=true → MISSING (即使磁盘上存在) ───────
void test_resolve_is_missing_flag () {
    print ("\n=== test_resolve_is_missing_flag ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_mfe_XXXXXX");
    string path = Path.build_filename (tmpdir, "real.txt");
    try { FileUtils.set_contents (path, "real content"); } catch (Error e) {}

    var data = new ItemData ("file", path, null, false, true);  // is_missing=true
    var ri = MultiFormatExporter.resolve_single_item (data, false, null);
    assert_true ("is_missing=true 强制 MISSING", ri.kind == MultiFormatExporter.ItemKind.MISSING);

    FileUtils.unlink (path);
    DirUtils.remove (tmpdir);
}

// ─── file 项: preprocessed_content 优先于磁盘内容 ──────────────
void test_resolve_preprocessed_content_wins () {
    print ("\n=== test_resolve_preprocessed_content_wins ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_mfe_XXXXXX");
    string path = Path.build_filename (tmpdir, "doc.pdf");
    try { FileUtils.set_contents (path, "raw bytes"); } catch (Error e) {}

    var data = new ItemData ("file", path, null, false);
    data.preprocessed_content = "# VLM 转写的 markdown\nhello";
    var ri = MultiFormatExporter.resolve_single_item (data, false, null);
    assert_true ("kind = OK", ri.kind == MultiFormatExporter.ItemKind.OK);
    assert_eq_str ("content 来自 preprocessed_content",
        "# VLM 转写的 markdown\nhello", ri.content ?? "");

    FileUtils.unlink (path);
    DirUtils.remove (tmpdir);
}

// ─── file 项: 普通文本文件正常读取 ─────────────────────────────
void test_resolve_plain_text_file () {
    print ("\n=== test_resolve_plain_text_file ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_mfe_XXXXXX");
    string path = Path.build_filename (tmpdir, "hello.py");
    try { FileUtils.set_contents (path, "print('hi')\n"); } catch (Error e) {}

    var data = new ItemData ("file", path, null, false);
    var ri = MultiFormatExporter.resolve_single_item (data, false, null);
    assert_true ("kind = OK", ri.kind == MultiFormatExporter.ItemKind.OK);
    assert_eq_str ("content 读取", "print('hi')\n", ri.content ?? "");
    assert_eq_str ("language=py", "py", ri.language);

    FileUtils.unlink (path);
    DirUtils.remove (tmpdir);
}

// ─── file 项: 二进制 (含 NUL 字节) ─────────────────────────────
void test_resolve_binary_file () {
    print ("\n=== test_resolve_binary_file ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_mfe_XXXXXX");
    string path = Path.build_filename (tmpdir, "bin.dat");
    // 写入含 NUL 的二进制内容
    try {
        var f = File.new_for_path (path);
        var os = f.replace (null, false, FileCreateFlags.NONE);
        uint8[] buf = { 'a', 'b', 0x00, 'c' };
        os.write (buf);
        os.close ();
    } catch (Error e) {
        fail ("写入二进制失败", e.message);
    }

    var data = new ItemData ("file", path, null, false);
    var ri = MultiFormatExporter.resolve_single_item (data, false, null);
    assert_true ("kind = BINARY", ri.kind == MultiFormatExporter.ItemKind.BINARY);
    assert_true ("error_message 含 'Binary'",
        (ri.error_message ?? "").contains ("Binary"));

    FileUtils.unlink (path);
    DirUtils.remove (tmpdir);
}

// ─── file 项: 超过 10MB → TOO_LARGE ────────────────────────────
// 用 1MB × 11 = 11MB 真实数据
void test_resolve_too_large_file () {
    print ("\n=== test_resolve_too_large_file ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_mfe_XXXXXX");
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
    } catch (Error e) {
        fail ("写入大文件失败", e.message);
    }

    var data = new ItemData ("file", path, null, false);
    var ri = MultiFormatExporter.resolve_single_item (data, false, null);
    assert_true ("kind = TOO_LARGE", ri.kind == MultiFormatExporter.ItemKind.TOO_LARGE);
    assert_true ("error_message 含 'too large'",
        (ri.error_message ?? "").contains ("too large"));

    FileUtils.unlink (path);
    DirUtils.remove (tmpdir);
}

// ─── display_path: 相对路径计算 ─────────────────────────────────
void test_resolve_display_path_relative () {
    print ("\n=== test_resolve_display_path_relative ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_mfe_XXXXXX");
    string subdir = Path.build_filename (tmpdir, "sub");
    DirUtils.create_with_parents (subdir, 0755);
    string path = Path.build_filename (subdir, "x.txt");
    try { FileUtils.set_contents (path, "hi"); } catch (Error e) {}

    var work_dir = File.new_for_path (tmpdir);
    var data = new ItemData ("file", path, null, false);
    var ri = MultiFormatExporter.resolve_single_item (data, false, work_dir);
    assert_eq_str ("相对路径剥离 work_dir 前缀", "sub/x.txt", ri.display_path);

    // use_absolute=true → 不剥离
    var ri2 = MultiFormatExporter.resolve_single_item (data, true, work_dir);
    assert_eq_str ("use_absolute=true 保留绝对路径", path, ri2.display_path);

    // force_absolute=true → 不剥离
    var data_force = new ItemData ("file", path, null, true);
    var ri3 = MultiFormatExporter.resolve_single_item (data_force, false, work_dir);
    assert_eq_str ("force_absolute=true 保留绝对路径", path, ri3.display_path);

    FileUtils.unlink (path);
    DirUtils.remove (subdir);
    DirUtils.remove (tmpdir);
}

// ─── language: 扩展名提取 ───────────────────────────────────────
void test_resolve_language_extraction () {
    print ("\n=== test_resolve_language_extraction ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_mfe_XXXXXX");

    // .vala → "vala"
    string p1 = Path.build_filename (tmpdir, "a.vala");
    try { FileUtils.set_contents (p1, ""); } catch (Error e) {}
    var d1 = new ItemData ("file", p1, null, false);
    var r1 = MultiFormatExporter.resolve_single_item (d1, false, null);
    assert_eq_str ("a.vala → language=vala", "vala", r1.language);

    // 大写扩展名 → 小写
    string p2 = Path.build_filename (tmpdir, "B.PY");
    try { FileUtils.set_contents (p2, ""); } catch (Error e) {}
    var d2 = new ItemData ("file", p2, null, false);
    var r2 = MultiFormatExporter.resolve_single_item (d2, false, null);
    assert_eq_str ("B.PY → language=py (小写)", "py", r2.language);

    // 无扩展名 → 空串
    string p3 = Path.build_filename (tmpdir, "Makefile");
    try { FileUtils.set_contents (p3, ""); } catch (Error e) {}
    var d3 = new ItemData ("file", p3, null, false);
    var r3 = MultiFormatExporter.resolve_single_item (d3, false, null);
    assert_eq_str ("Makefile → language 为空", "", r3.language);

    FileUtils.unlink (p1);
    FileUtils.unlink (p2);
    FileUtils.unlink (p3);
    DirUtils.remove (tmpdir);
}

// ─── display_path: work_dir=null 时强制绝对路径 ────────────────
void test_resolve_display_path_no_work_dir () {
    print ("\n=== test_resolve_display_path_no_work_dir ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_mfe_XXXXXX");
    string path = Path.build_filename (tmpdir, "x.txt");
    try { FileUtils.set_contents (path, "hi"); } catch (Error e) {}

    // work_dir=null: 即使 use_absolute=false 也走绝对路径
    var data = new ItemData ("file", path, null, false);
    var ri = MultiFormatExporter.resolve_single_item (data, false, null);
    assert_eq_str ("work_dir=null 保留绝对路径", path, ri.display_path);

    FileUtils.unlink (path);
    DirUtils.remove (tmpdir);
}

public static int main (string[] args) {
    print ("========== MultiFormatExporter 测试开始 ==========\n");

    test_resolve_text_item ();
    test_resolve_missing_file ();
    test_resolve_is_missing_flag ();
    test_resolve_preprocessed_content_wins ();
    test_resolve_plain_text_file ();
    test_resolve_binary_file ();
    test_resolve_too_large_file ();
    test_resolve_display_path_relative ();
    test_resolve_language_extraction ();
    test_resolve_display_path_no_work_dir ();

    print ("\n========== 测试结果 ==========\n");
    print ("PASS: %d, FAIL: %d\n", pass_count, fail_count);
    return fail_count > 0 ? 1 : 0;
}
