// FileContentReader 单元测试
//
// 验证 read_text_streaming 的四种返回:
//   OK / TOO_LARGE / BINARY / READ_ERROR
// 以及回调被调用的次数和顺序与契约一致:
//   - OK: 回调至少 1 次 (含 peek 部分)
//   - TOO_LARGE / BINARY: 回调 0 次
//   - READ_ERROR (query_info 失败): 回调 0 次
//   - READ_ERROR (read 抛异常): 回调 0..N 次 (此处用合法文本文件, 不易触发)

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
void assert_eq_int (string desc, int expected, int actual) {
    if (expected == actual) pass (desc);
    else fail (desc, @"期望 $expected, 实际 $actual");
}

string make_tmp_file (string name, string content) throws Error {
    string tmpdir = DirUtils.make_tmp ("fc_fcr_XXXXXX");
    string path = Path.build_filename (tmpdir, name);
    FileUtils.set_contents (path, content);
    return path;
}

string make_tmp_file_bytes (string name, uint8[] data) throws Error {
    string tmpdir = DirUtils.make_tmp ("fc_fcr_XXXXXX");
    string path = Path.build_filename (tmpdir, name);
    var f = File.new_for_path (path);
    var os = f.replace (null, false, FileCreateFlags.NONE);
    os.write (data);
    os.close ();
    return path;
}

void cleanup_path (string path) {
    FileUtils.unlink (path);
    var parent = File.new_for_path (path).get_parent ();
    try { parent.delete (); } catch (Error e) {}
}

// 收集回调数据, 用于断言. 用 StringBuilder 累积 (GLib.Bytes 数组也行, 但
// Gee.ArrayList<uint8[]> 在 Vala 中不允许: 数组不能作为泛型参数).
class ChunkCollector {
    public StringBuilder sb = new StringBuilder ();
    public size_t total_bytes = 0;
    public int call_count = 0;
    public void consume (uint8[] buf, size_t len) {
        sb.append (EncodingHelper.bytes_to_string_safe (buf, len));
        total_bytes += len;
        call_count++;
    }
    public string content () {
        return sb.str;
    }
}

// ─── OK: 普通文本文件 ───────────────────────────────────────────────
void test_ok_small_text () {
    print ("\n=== test_ok_small_text ===\n");
    string content = "hello world\nline 2\nline 3";
    string path;
    try {
        path = make_tmp_file ("small.txt", content);
    } catch (Error e) {
        fail ("创建文件异常", e.message);
        return;
    }
    var collector = new ChunkCollector ();
    var outcome = FileContentReader.read_text_streaming (path, collector.consume);
    assert_eq_int ("小文件 result=OK", (int) FileContentReader.ReadResult.OK, (int) outcome.result);
    assert_true ("file_size 正确", outcome.file_size == content.length);
    assert_true ("回调至少 1 次", collector.call_count >= 1);
    assert_true ("总字节数 = 文件大小", collector.total_bytes == content.length);
    assert_true ("内容一致", collector.content () == content);
    cleanup_path (path);
}

// ─── OK: 大于 PEEK_SIZE 的文件 (会触发多次回调) ────────────────────
void test_ok_multi_chunk () {
    print ("\n=== test_ok_multi_chunk ===\n");
    // 20 KB 文本, 必然超过 PEEK_SIZE (8192)
    var sb = new StringBuilder ();
    for (int i = 0; i < 2000; i++) sb.append_printf ("line %d\n", i);
    string content = sb.str;
    string path;
    try {
        path = make_tmp_file ("multi.txt", content);
    } catch (Error e) {
        fail ("创建文件异常", e.message);
        return;
    }
    var collector = new ChunkCollector ();
    var outcome = FileContentReader.read_text_streaming (path, collector.consume);
    assert_eq_int ("大文件 result=OK", (int) FileContentReader.ReadResult.OK, (int) outcome.result);
    assert_true ("file_size 正确", outcome.file_size == content.length);
    assert_true ("回调 > 1 次 (多块)", collector.call_count > 1);
    assert_true ("总字节数 = 文件大小", collector.total_bytes == content.length);
    assert_true ("内容一致", collector.content () == content);
    cleanup_path (path);
}

// ─── TOO_LARGE: > 10 MB ────────────────────────────────────────────
void test_too_large () {
    print ("\n=== test_too_large ===\n");
    // 写一个 11 MB 文件
    string tmpdir;
    try {
        tmpdir = DirUtils.make_tmp ("fc_fcr_XXXXXX");
    } catch (Error e) {
        fail ("创建临时目录异常", e.message);
        return;
    }
    string path = Path.build_filename (tmpdir, "large.txt");
    try {
        var f = File.new_for_path (path);
        var os = f.replace (null, false, FileCreateFlags.NONE);
        uint8[] chunk = new uint8[1024 * 1024];
        for (int i = 0; i < chunk.length; i++) chunk[i] = (uint8) 'x';
        for (int i = 0; i < 11; i++) os.write (chunk);
        os.close ();
    } catch (Error e) {
        fail ("创建大文件异常", e.message);
        DirUtils.remove (tmpdir);
        return;
    }
    var collector = new ChunkCollector ();
    var outcome = FileContentReader.read_text_streaming (path, collector.consume);
    assert_eq_int ("大文件 result=TOO_LARGE", (int) FileContentReader.ReadResult.TOO_LARGE, (int) outcome.result);
    assert_true ("file_size > 10MB", outcome.file_size > FileContentReader.MAX_FILE_CONTENT_SIZE);
    assert_eq_int ("回调 0 次 (TOO_LARGE)", 0, collector.call_count);
    FileUtils.unlink (path);
    DirUtils.remove (tmpdir);
}

// ─── BINARY: 含 NULL 字节 ──────────────────────────────────────────
void test_binary () {
    print ("\n=== test_binary ===\n");
    uint8[] data = { (uint8) 'a', (uint8) 'b', (uint8) 'c', 0, (uint8) 'x', (uint8) 'y' };
    string path;
    try {
        path = make_tmp_file_bytes ("binary.bin", data);
    } catch (Error e) {
        fail ("创建二进制文件异常", e.message);
        return;
    }
    var collector = new ChunkCollector ();
    var outcome = FileContentReader.read_text_streaming (path, collector.consume);
    assert_eq_int ("含 NULL result=BINARY", (int) FileContentReader.ReadResult.BINARY, (int) outcome.result);
    assert_eq_int ("回调 0 次 (BINARY)", 0, collector.call_count);
    cleanup_path (path);
}

// ─── BINARY: NULL 在 peek 末尾 (边界) ──────────────────────────────
void test_binary_null_at_peek_end () {
    print ("\n=== test_binary_null_at_peek_end ===\n");
    // 构造刚好 PEEK_SIZE 字节, 最后一个字节是 NULL
    uint8[] data = new uint8[FileContentReader.PEEK_SIZE];
    for (int i = 0; i < data.length - 1; i++) data[i] = (uint8) 'a';
    data[data.length - 1] = 0;
    string path;
    try {
        path = make_tmp_file_bytes ("boundary.bin", data);
    } catch (Error e) {
        fail ("创建边界文件异常", e.message);
        return;
    }
    var collector = new ChunkCollector ();
    var outcome = FileContentReader.read_text_streaming (path, collector.consume);
    assert_eq_int ("PEEK 末尾 NULL result=BINARY", (int) FileContentReader.ReadResult.BINARY, (int) outcome.result);
    assert_eq_int ("回调 0 次", 0, collector.call_count);
    cleanup_path (path);
}

// ─── READ_ERROR: 文件不存在 ────────────────────────────────────────
void test_read_error_nonexistent () {
    print ("\n=== test_read_error_nonexistent ===\n");
    var collector = new ChunkCollector ();
    var outcome = FileContentReader.read_text_streaming ("/nonexistent/file.txt", collector.consume);
    assert_eq_int ("不存在 result=READ_ERROR", (int) FileContentReader.ReadResult.READ_ERROR, (int) outcome.result);
    assert_eq_int ("回调 0 次", 0, collector.call_count);
    assert_true ("error_message 非空", outcome.error_message != null && outcome.error_message.length > 0);
}

// ─── 边界: 空文件 ──────────────────────────────────────────────────
void test_empty_file () {
    print ("\n=== test_empty_file ===\n");
    string path;
    try {
        path = make_tmp_file ("empty.txt", "");
    } catch (Error e) {
        fail ("创建空文件异常", e.message);
        return;
    }
    var collector = new ChunkCollector ();
    var outcome = FileContentReader.read_text_streaming (path, collector.consume);
    assert_eq_int ("空文件 result=OK", (int) FileContentReader.ReadResult.OK, (int) outcome.result);
    assert_eq_int ("file_size = 0", 0, (int) outcome.file_size);
    // 注: peek 0 字节, 不会进入 binary 检测; 回调被调用 1 次 (head_read=0)
    assert_eq_int ("回调 1 次 (空 peek)", 1, collector.call_count);
    assert_eq_int ("总字节数 0", 0, (int) collector.total_bytes);
    cleanup_path (path);
}

// ─── 边界: 只有 NULL 字节 ──────────────────────────────────────────
void test_all_null () {
    print ("\n=== test_all_null ===\n");
    uint8[] data = { 0, 0, 0, 0 };
    string path;
    try {
        path = make_tmp_file_bytes ("nulls.bin", data);
    } catch (Error e) {
        fail ("创建 null 文件异常", e.message);
        return;
    }
    var collector = new ChunkCollector ();
    var outcome = FileContentReader.read_text_streaming (path, collector.consume);
    assert_eq_int ("全 NULL result=BINARY", (int) FileContentReader.ReadResult.BINARY, (int) outcome.result);
    assert_eq_int ("回调 0 次", 0, collector.call_count);
    cleanup_path (path);
}

public static int main (string[] args) {
    print ("========== FileContentReader 测试开始 ==========\n");

    test_ok_small_text ();
    test_ok_multi_chunk ();
    test_too_large ();
    test_binary ();
    test_binary_null_at_peek_end ();
    test_read_error_nonexistent ();
    test_empty_file ();
    test_all_null ();

    print ("\n========== 测试结果 ==========\n");
    print ("PASS: %d, FAIL: %d\n", pass_count, fail_count);
    return fail_count > 0 ? 1 : 0;
}
