// FileGenerator 单元测试
//
// 用 MemoryOutputStream 捕获 write_items_to_stream 的输出, 验证各分支:
//   empty / text 项 / file 项 (missing/binary/too_large/normal/snippet) /
//   preprocessed_content 优先 / show_header / display_path 计算.

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
void assert_contains (string desc, string haystack, string needle) {
    if (haystack.contains (needle)) pass (desc);
    else fail (desc, @"'%s' 不包含 '%s'".printf (haystack, needle));
}

// 调用 write_items_to_stream, 返回捕获的输出文本
string run_generator (Gee.ArrayList<ItemData> items, bool use_absolute,
                      bool show_header, File? work_dir) {
    // 用临时文件捕获输出, 比 MemoryOutputStream 更可靠 (后者需正确传 realloc_fn 才能 grow)
    string tmpdir = DirUtils.make_tmp ("fc_fg_run_XXXXXX");
    string path = Path.build_filename (tmpdir, "out.txt");
    string result = "";
    DataOutputStream? dos = null;
    try {
        var f = File.new_for_path (path);
        dos = new DataOutputStream (f.replace (null, false, FileCreateFlags.NONE));
        FileGenerator.write_items_to_stream (dos, items, use_absolute, show_header, work_dir);
        dos.close ();
        dos = null;
        string content;
        size_t len;
        FileUtils.get_contents (path, out content, out len);
        result = content;
    } catch (Error e) {
        fail ("write_items_to_stream 异常", e.message);
    } finally {
        if (dos != null) {
            try { dos.close (); } catch (Error e) {}
        }
    }
    FileUtils.unlink (path);
    DirUtils.remove (tmpdir);
    return result;
}

// ─── 空列表 ────────────────────────────────────────────────────
void test_empty_items () {
    print ("\n=== test_empty_items ===\n");
    var items = new Gee.ArrayList<ItemData> ();
    string result = run_generator (items, false, false, null);
    assert_eq_str ("空列表 → 空输出", "", result);
}

// ─── 单个 text 项 ──────────────────────────────────────────────
void test_single_text_item () {
    print ("\n=== test_single_text_item ===\n");
    var items = new Gee.ArrayList<ItemData> ();
    items.add (new ItemData ("text", null, "hello world", false));
    string result = run_generator (items, false, false, null);
    assert_eq_str ("text 项内容直接输出", "hello world", result);
}

// ─── 多个 text 项之间有分隔 ────────────────────────────────────
void test_multiple_text_items_separator () {
    print ("\n=== test_multiple_text_items_separator ===\n");
    var items = new Gee.ArrayList<ItemData> ();
    items.add (new ItemData ("text", null, "AAA", false));
    items.add (new ItemData ("text", null, "BBB", false));
    string result = run_generator (items, false, false, null);
    assert_eq_str ("两个 text 项用 \\n\\n 分隔", "AAA\n\nBBB", result);
}

// ─── show_header=true: 输出工作目录头 ──────────────────────────
void test_show_header () {
    print ("\n=== test_show_header ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_fg_XXXXXX");
    var work_dir = File.new_for_path (tmpdir);
    var items = new Gee.ArrayList<ItemData> ();
    items.add (new ItemData ("text", null, "body", false));
    string result = run_generator (items, false, true, work_dir);
    assert_contains ("含工作目录头", result, "# Working directory absolute path:");
    assert_contains ("头含路径", result, tmpdir);
    assert_contains ("正文仍输出", result, "body");

    DirUtils.remove (tmpdir);
}

// ─── file 项: missing ──────────────────────────────────────────
void test_missing_file () {
    print ("\n=== test_missing_file ===\n");
    var items = new Gee.ArrayList<ItemData> ();
    items.add (new ItemData ("file", "/nonexistent/x.txt", null, false));
    string result = run_generator (items, false, false, null);
    assert_contains ("含 [Missing file:", result, "[Missing file:");
    assert_contains ("含路径", result, "/nonexistent/x.txt");
}

// ─── file 项: is_missing=true 即使磁盘存在也判定 missing ────────
void test_is_missing_flag () {
    print ("\n=== test_is_missing_flag ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_fg_XXXXXX");
    string path = Path.build_filename (tmpdir, "real.txt");
    try { FileUtils.set_contents (path, "real"); } catch (Error e) {}

    var items = new Gee.ArrayList<ItemData> ();
    items.add (new ItemData ("file", path, null, false, true));
    string result = run_generator (items, false, false, null);
    assert_contains ("is_missing=true 仍输出 [Missing file:", result, "[Missing file:");

    FileUtils.unlink (path);
    DirUtils.remove (tmpdir);
}

// ─── file 项: 普通文本内容 ─────────────────────────────────────
void test_normal_text_file () {
    print ("\n=== test_normal_text_file ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_fg_XXXXXX");
    string path = Path.build_filename (tmpdir, "a.txt");
    try { FileUtils.set_contents (path, "line1\nline2\n"); } catch (Error e) {}

    var items = new Gee.ArrayList<ItemData> ();
    items.add (new ItemData ("file", path, null, false));
    string result = run_generator (items, false, false, null);
    assert_contains ("含路径前缀", result, path + ":");
    assert_contains ("含文件内容", result, "line1\nline2");

    FileUtils.unlink (path);
    DirUtils.remove (tmpdir);
}

// ─── file 项: preprocessed_content 优先 ────────────────────────
void test_preprocessed_content_priority () {
    print ("\n=== test_preprocessed_content_priority ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_fg_XXXXXX");
    string path = Path.build_filename (tmpdir, "doc.pdf");
    try { FileUtils.set_contents (path, "raw bytes"); } catch (Error e) {}

    var items = new Gee.ArrayList<ItemData> ();
    var data = new ItemData ("file", path, null, false);
    data.preprocessed_content = "# VLM Markdown";
    items.add (data);
    string result = run_generator (items, false, false, null);
    assert_contains ("输出 preprocessed_content", result, "# VLM Markdown");
    // 不应包含原始 "raw bytes"
    assert_true ("不输出 raw bytes", !result.contains ("raw bytes"));

    FileUtils.unlink (path);
    DirUtils.remove (tmpdir);
}

// ─── file 项: 二进制 (含 NUL) ──────────────────────────────────
void test_binary_file () {
    print ("\n=== test_binary_file ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_fg_XXXXXX");
    string path = Path.build_filename (tmpdir, "b.dat");
    try {
        var f = File.new_for_path (path);
        var os = f.replace (null, false, FileCreateFlags.NONE);
        uint8[] buf = { 'x', 0x00, 'y' };
        os.write (buf);
        os.close ();
    } catch (Error e) {}

    var items = new Gee.ArrayList<ItemData> ();
    items.add (new ItemData ("file", path, null, false));
    string result = run_generator (items, false, false, null);
    assert_contains ("输出 [Binary file detected:", result, "[Binary file detected:");

    FileUtils.unlink (path);
    DirUtils.remove (tmpdir);
}

// ─── file 项: 过大 (>10MB) ─────────────────────────────────────
void test_too_large_file () {
    print ("\n=== test_too_large_file ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_fg_XXXXXX");
    string path = Path.build_filename (tmpdir, "large.txt");
    try {
        var f = File.new_for_path (path);
        var os = f.replace (null, false, FileCreateFlags.NONE);
        uint8[] chunk = new uint8[1024 * 1024];
        for (int i = 0; i < chunk.length; i++) chunk[i] = (uint8) 'x';
        for (int i = 0; i < 11; i++) os.write (chunk);
        os.close ();
    } catch (Error e) {}

    var items = new Gee.ArrayList<ItemData> ();
    items.add (new ItemData ("file", path, null, false));
    string result = run_generator (items, false, false, null);
    assert_contains ("输出 [File too large", result, "[File too large");

    FileUtils.unlink (path);
    DirUtils.remove (tmpdir);
}

// ─── file 项: snippet (start_line/end_line) ────────────────────
void test_snippet () {
    print ("\n=== test_snippet ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_fg_XXXXXX");
    string path = Path.build_filename (tmpdir, "s.txt");
    var sb = new StringBuilder ();
    for (int i = 1; i <= 5; i++) sb.append_printf ("line%d\n", i);
    try { FileUtils.set_contents (path, sb.str); } catch (Error e) {}

    var items = new Gee.ArrayList<ItemData> ();
    var data = new ItemData ("file", path, null, false);
    data.start_line = 2;
    data.end_line = 4;
    items.add (data);
    string result = run_generator (items, false, false, null);
    assert_contains ("含第 2 行", result, "line2");
    assert_contains ("含第 4 行", result, "line4");
    assert_true ("不含第 1 行", !result.contains ("line1\n"));
    assert_true ("不含第 5 行", !result.contains ("line5"));

    FileUtils.unlink (path);
    DirUtils.remove (tmpdir);
}

// ─── file 项: snippet start>end 自动 swap ──────────────────────
void test_snippet_swap () {
    print ("\n=== test_snippet_swap ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_fg_XXXXXX");
    string path = Path.build_filename (tmpdir, "s.txt");
    try { FileUtils.set_contents (path, "a\nb\nc\n"); } catch (Error e) {}

    var items = new Gee.ArrayList<ItemData> ();
    var data = new ItemData ("file", path, null, false);
    data.start_line = 3;  // 反向: start > end
    data.end_line = 1;
    items.add (data);
    string result = run_generator (items, false, false, null);
    assert_contains ("含 swap 提示", result, "auto-swapped");
    assert_contains ("仍输出第 1-3 行内容", result, "a");

    FileUtils.unlink (path);
    DirUtils.remove (tmpdir);
}

// ─── display_path: 相对路径计算 ────────────────────────────────
void test_display_path_relative () {
    print ("\n=== test_display_path_relative ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_fg_XXXXXX");
    string subdir = Path.build_filename (tmpdir, "sub");
    DirUtils.create_with_parents (subdir, 0755);
    string path = Path.build_filename (subdir, "x.txt");
    try { FileUtils.set_contents (path, "hi"); } catch (Error e) {}

    var work_dir = File.new_for_path (tmpdir);
    var items = new Gee.ArrayList<ItemData> ();
    items.add (new ItemData ("file", path, null, false));
    string result = run_generator (items, false, false, work_dir);
    assert_contains ("用相对路径前缀", result, "sub/x.txt:");
    assert_true ("不含绝对路径前缀", !result.contains (path + ":"));

    FileUtils.unlink (path);
    DirUtils.remove (subdir);
    DirUtils.remove (tmpdir);
}

// ─── display_path: use_absolute=true 强制绝对 ──────────────────
void test_display_path_use_absolute () {
    print ("\n=== test_display_path_use_absolute ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_fg_XXXXXX");
    string subdir = Path.build_filename (tmpdir, "sub");
    DirUtils.create_with_parents (subdir, 0755);
    string path = Path.build_filename (subdir, "x.txt");
    try { FileUtils.set_contents (path, "hi"); } catch (Error e) {}

    var work_dir = File.new_for_path (tmpdir);
    var items = new Gee.ArrayList<ItemData> ();
    items.add (new ItemData ("file", path, null, false));
    string result = run_generator (items, true, false, work_dir);
    assert_contains ("use_absolute=true 用绝对路径", result, path + ":");

    FileUtils.unlink (path);
    DirUtils.remove (subdir);
    DirUtils.remove (tmpdir);
}

public static int main (string[] args) {
    print ("========== FileGenerator 测试开始 ==========\n");

    test_empty_items ();
    test_single_text_item ();
    test_multiple_text_items_separator ();
    test_show_header ();
    test_missing_file ();
    test_is_missing_flag ();
    test_normal_text_file ();
    test_preprocessed_content_priority ();
    test_binary_file ();
    test_too_large_file ();
    test_snippet ();
    test_snippet_swap ();
    test_display_path_relative ();
    test_display_path_use_absolute ();

    print ("\n========== 测试结果 ==========\n");
    print ("PASS: %d, FAIL: %d\n", pass_count, fail_count);
    return fail_count > 0 ? 1 : 0;
}
