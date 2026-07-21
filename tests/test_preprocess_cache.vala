// PreprocessCache 单元测试
// 重点验证:
//   C-9: compute_file_hash 异常时 FD 不泄漏 (try-finally 关闭 stream)
//   C-8: load_manifest_unlocked 全程持锁
//   静态缓存共享: 多个 PreprocessCache 实例复用同一 manifest

using GLib;
using Gee;

int pass_count = 0;
int fail_count = 0;

void pass (string desc) { print ("PASS: %s\n", desc); pass_count++; }
void fail (string desc, string detail = "") {
    print ("FAIL: %s%s%s\n", desc, detail.length > 0 ? " - " : "", detail);
    fail_count++;
}

void assert_eq (string desc, string expected, string actual) {
    if (expected == actual) pass (desc);
    else fail (desc, @"期望 '$expected', 实际 '$actual'");
}

void assert_true (string desc, bool cond) {
    if (cond) pass (desc);
    else fail (desc);
}

// 获取当前进程打开的 FD 数量 (Linux)
int count_open_fds () {
    try {
        var dir = Dir.open ("/proc/self/fd", 0);
        int count = 0;
        while (dir.read_name () != null) count++;
        return count;
    } catch (Error e) {
        return -1;
    }
}

void test_compute_file_hash_basic () {
    print ("\n=== test_compute_file_hash_basic ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_hash_XXXXXX");
    string filepath = Path.build_filename (tmpdir, "test.txt");
    try {
        FileUtils.set_contents (filepath, "hello world");
        string hash1 = PreprocessCache.compute_file_hash (filepath);
        string hash2 = PreprocessCache.compute_file_hash (filepath);
        assert_eq ("相同内容 hash 一致", hash1, hash2);
        // SHA256 of "hello world"
        assert_eq ("hash 值正确", "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9", hash1);
    } catch (Error e) {
        fail ("compute_file_hash_basic 异常", e.message);
    }
    FileUtils.unlink (filepath);
    DirUtils.remove (tmpdir);
}

void test_compute_file_hash_different_content () {
    print ("\n=== test_compute_file_hash_different_content ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_hash_XXXXXX");
    string f1 = Path.build_filename (tmpdir, "f1.txt");
    string f2 = Path.build_filename (tmpdir, "f2.txt");
    try {
        FileUtils.set_contents (f1, "content A");
        FileUtils.set_contents (f2, "content B");
        string h1 = PreprocessCache.compute_file_hash (f1);
        string h2 = PreprocessCache.compute_file_hash (f2);
        assert_true ("不同内容 hash 不同", h1 != h2);
    } catch (Error e) {
        fail ("different_content 异常", e.message);
    }
    FileUtils.unlink (f1);
    FileUtils.unlink (f2);
    DirUtils.remove (tmpdir);
}

void test_compute_file_hash_nonexistent () {
    print ("\n=== test_compute_file_hash_nonexistent ===\n");
    bool threw = false;
    try {
        PreprocessCache.compute_file_hash ("/nonexistent/path/to/file.txt");
    } catch (Error e) {
        threw = true;
    }
    assert_true ("不存在的文件抛异常", threw);
}

void test_compute_file_hash_fd_not_leaked () {
    print ("\n=== test_compute_file_hash_fd_not_leaked (C-9 验证) ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_hash_XXXXXX");
    string filepath = Path.build_filename (tmpdir, "test.txt");
    try {
        FileUtils.set_contents (filepath, "test content for fd leak");
    } catch (Error e) {
        fail ("创建测试文件失败", e.message);
    }

    int fds_before = count_open_fds ();
    // 多次调用, 如果 FD 泄漏, 数量会持续增长
    for (int i = 0; i < 100; i++) {
        try {
            PreprocessCache.compute_file_hash (filepath);
        } catch (Error e) {
            fail (@"compute_file_hash 第 $i 次调用失败", e.message);
            break;
        }
    }
    int fds_after = count_open_fds ();
    // 允许少量波动 (GC, 临时缓冲等), 但不应有大量 FD 泄漏
    int delta = fds_after - fds_before;
    print ("  FD 数量: before=%d, after=%d, delta=%d\n", fds_before, fds_after, delta);
    assert_true (@"100 次调用后 FD 不泄漏 (delta=$delta)", delta >= -5 && delta <= 5);

    FileUtils.unlink (filepath);
    DirUtils.remove (tmpdir);
}

void test_compute_file_hash_fd_leak_on_error () {
    print ("\n=== test_compute_file_hash_fd_leak_on_error (C-9 异常路径) ===\n");
    int fds_before = count_open_fds ();
    // 反复对不存在的文件调用, 每次都会抛异常, 但不应泄漏 FD
    for (int i = 0; i < 50; i++) {
        try {
            PreprocessCache.compute_file_hash ("/nonexistent/file_" + i.to_string ());
        } catch (Error e) {
            // 预期异常
        }
    }
    int fds_after = count_open_fds ();
    int delta = fds_after - fds_before;
    print ("  FD 数量: before=%d, after=%d, delta=%d\n", fds_before, fds_after, delta);
    assert_true (@"50 次异常调用后 FD 不泄漏 (delta=$delta)", delta >= -5 && delta <= 5);
}

void test_compute_file_hash_fast_format () {
    print ("\n=== test_compute_file_hash_fast_format ===\n");
    string tmpdir = DirUtils.make_tmp ("fc_hash_XXXXXX");
    string filepath = Path.build_filename (tmpdir, "test.txt");
    try {
        FileUtils.set_contents (filepath, "test");
        string fast = PreprocessCache.compute_file_hash_fast (filepath);
        // 格式应该是 size:mtime
        assert_true ("fast hash 包含冒号分隔符", fast.contains (":"));
        string[] parts = fast.split (":");
        assert_true ("fast hash 有两部分", parts.length == 2);
        assert_eq ("fast hash size 部分", "4", parts[0]); // "test" 是 4 字节
    } catch (Error e) {
        fail ("fast_format 异常", e.message);
    }
    FileUtils.unlink (filepath);
    DirUtils.remove (tmpdir);
}

void test_preprocess_cache_save_and_get () {
    print ("\n=== test_preprocess_cache_save_and_get ===\n");
    string tmpdir = Dirutils_make_tmp ();
    string workdir = Path.build_filename (tmpdir, "work");
    DirUtils.create_with_parents (workdir, 0755);

    string filepath = Path.build_filename (workdir, "doc.pdf");
    try {
        FileUtils.set_contents (filepath, "fake pdf content");
    } catch (Error e) {
        fail ("创建测试文件失败", e.message);
    }

    try {
        string hash = PreprocessCache.compute_file_hash (filepath);
        var cache = new PreprocessCache (workdir);

        // 第一次查询: 应该 miss
        string? md = cache.get_cached_markdown (filepath, hash);
        assert_true ("首次查询 miss", md == null);

        // 保存缓存
        cache.save_markdown (filepath, hash, "# Fake PDF\nThis is markdown.");
        pass ("save_markdown 成功");

        // 第二次查询: 应该 hit
        md = cache.get_cached_markdown (filepath, hash);
        assert_true ("保存后查询 hit", md != null);
        assert_true ("缓存内容正确", md != null && md.contains ("Fake PDF"));

        // 错误 hash 查询: 应该 miss
        md = cache.get_cached_markdown (filepath, "wrong_hash");
        assert_true ("错误 hash miss", md == null);
    } catch (Error e) {
        fail ("save_and_get 异常", e.message);
    }

    cleanup_dir_recursive (tmpdir);
}

void test_preprocess_cache_invalidate () {
    print ("\n=== test_preprocess_cache_invalidate ===\n");
    string tmpdir = Dirutils_make_tmp ();
    string workdir = Path.build_filename (tmpdir, "work");
    DirUtils.create_with_parents (workdir, 0755);

    string filepath = Path.build_filename (workdir, "doc.pdf");
    try { FileUtils.set_contents (filepath, "fake pdf"); } catch (Error e) {}

    try {
        string hash = PreprocessCache.compute_file_hash (filepath);
        var cache = new PreprocessCache (workdir);
        cache.save_markdown (filepath, hash, "cached content");

        // invalidate 前能查到
        string? md = cache.get_cached_markdown (filepath, hash);
        assert_true ("invalidate 前能查到", md != null);

        cache.invalidate_cache (filepath);
        pass ("invalidate_cache 成功");

        // invalidate 后查不到
        md = cache.get_cached_markdown (filepath, hash);
        assert_true ("invalidate 后查不到", md == null);
    } catch (Error e) {
        fail ("invalidate 异常", e.message);
    }

    cleanup_dir_recursive (tmpdir);
}

void test_preprocess_cache_static_sharing () {
    print ("\n=== test_preprocess_cache_static_sharing (C-8 验证) ===\n");
    string tmpdir = Dirutils_make_tmp ();
    string workdir = Path.build_filename (tmpdir, "work");
    DirUtils.create_with_parents (workdir, 0755);

    string filepath = Path.build_filename (workdir, "doc.pdf");
    try { FileUtils.set_contents (filepath, "fake pdf"); } catch (Error e) {}

    try {
        string hash = PreprocessCache.compute_file_hash (filepath);
        // 两个实例共享同一份 manifest (静态缓存)
        var cache1 = new PreprocessCache (workdir);
        cache1.save_markdown (filepath, hash, "shared content");

        // cache2 应该能立即看到 cache1 的写入 (共享 manifest 对象)
        var cache2 = new PreprocessCache (workdir);
        string? md = cache2.get_cached_markdown (filepath, hash);
        assert_true ("第二个实例看到第一个实例的写入 (静态缓存共享)", md != null);
        assert_true ("内容正确", md != null && md.contains ("shared content"));
    } catch (Error e) {
        fail ("static_sharing 异常", e.message);
    }

    cleanup_dir_recursive (tmpdir);
}

// 辅助函数
string Dirutils_make_tmp () {
    return DirUtils.make_tmp ("fc_cache_XXXXXX");
}

void cleanup_dir_recursive (string path) {
    try {
        var dir = File.new_for_path (path);
        if (dir.query_exists ()) {
            delete_recursive (dir);
        }
    } catch (Error e) {}
}

void delete_recursive (File dir) throws Error {
    var enumerator = dir.enumerate_children (
        FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
        FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
    FileInfo info;
    while ((info = enumerator.next_file ()) != null) {
        var child = dir.get_child (info.get_name ());
        if (info.get_file_type () == FileType.DIRECTORY) {
            delete_recursive (child);
        } else {
            child.delete ();
        }
    }
    dir.delete ();
}

public static int main (string[] args) {
    print ("========== PreprocessCache 测试开始 ==========\n");

    test_compute_file_hash_basic ();
    test_compute_file_hash_different_content ();
    test_compute_file_hash_nonexistent ();
    test_compute_file_hash_fd_not_leaked ();
    test_compute_file_hash_fd_leak_on_error ();
    test_compute_file_hash_fast_format ();
    test_preprocess_cache_save_and_get ();
    test_preprocess_cache_invalidate ();
    test_preprocess_cache_static_sharing ();

    print ("\n========== 测试结果 ==========\n");
    print ("PASS: %d, FAIL: %d\n", pass_count, fail_count);
    return fail_count > 0 ? 1 : 0;
}
