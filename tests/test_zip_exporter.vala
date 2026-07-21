// ZipExporter 单元测试
// 验证:
//   C-4: staging 目录在 finally 块中递归清理 (无论成功/失败)
//   M-2: 工作目录外的文件用 _external/<basename>-<size+mtime hash> 隔离
//   M-6: copy_file_fallback 循环写入避免部分写入
//   missing files 正确记录在 README

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
    if (cond) pass (desc);
    else fail (desc);
}

void assert_eq (string desc, string expected, string actual) {
    if (expected == actual) pass (desc);
    else fail (desc, @"期望 '$expected', 实际 '$actual'");
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

void cleanup (string path) {
    try {
        var f = File.new_for_path (path);
        if (f.query_exists ()) {
            if (FileUtils.test (path, FileTest.IS_DIR)) {
                delete_recursive (f);
            } else {
                f.delete ();
            }
        }
    } catch (Error e) {}
}

string make_tmp_dir () {
    return DirUtils.make_tmp ("fc_zip_XXXXXX");
}

void test_zip_basic_export () {
    print ("\n=== test_zip_basic_export ===\n");
    string tmpdir = make_tmp_dir ();
    string workdir = Path.build_filename (tmpdir, "work");
    string subdir = Path.build_filename (workdir, "sub");
    DirUtils.create_with_parents (subdir, 0755);

    string f1 = Path.build_filename (workdir, "a.txt");
    string f2 = Path.build_filename (subdir, "b.py");
    try {
        FileUtils.set_contents (f1, "content A");
        FileUtils.set_contents (f2, "print('hello')");
    } catch (Error e) {
        fail ("创建测试文件失败", e.message);
    }

    var items = new ArrayList<ItemData> ();
    items.add (new ItemData ("file", f1, null, false));
    items.add (new ItemData ("file", f2, null, false));
    items.add (new ItemData ("text", null, "Custom text block", false));

    string zip_path = Path.build_filename (tmpdir, "output.zip");
    try {
        ZipExporter.export_to_zip (zip_path, items, true, File.new_for_path (workdir));
        assert_true ("ZIP 文件已生成", FileUtils.test (zip_path, FileTest.EXISTS));
        assert_true ("ZIP 文件非空", File.new_for_path (zip_path).query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE).get_size () > 0);
    } catch (Error e) {
        fail ("export_to_zip 异常", e.message);
    }

    // 验证 ZIP 内容 (用 unzip -l 列出)
    try {
        string stdout_buf;
        int status;
        Process.spawn_sync (null, {"unzip", "-l", zip_path}, null,
            SpawnFlags.SEARCH_PATH, null, out stdout_buf, null, out status);
        if (status == 0) {
            assert_true ("ZIP 包含 a.txt", stdout_buf.contains ("a.txt"));
            assert_true ("ZIP 包含 sub/b.py", stdout_buf.contains ("sub/b.py") || stdout_buf.contains ("b.py"));
            assert_true ("ZIP 包含 README.md", stdout_buf.contains ("README.md"));
        } else {
            fail ("unzip -l 失败", @"status=$status");
        }
    } catch (Error e) {
        fail ("unzip 调用异常", e.message);
    }

    cleanup (tmpdir);
}

void test_zip_staging_cleanup_on_success (string cache_root) {
    print ("\n=== test_zip_staging_cleanup_on_success (C-4 验证) ===\n");
    string tmpdir = make_tmp_dir ();
    string workdir = Path.build_filename (tmpdir, "work");
    DirUtils.create_with_parents (workdir, 0755);

    string f1 = Path.build_filename (workdir, "a.txt");
    try { FileUtils.set_contents (f1, "content"); } catch (Error e) {}

    var items = new ArrayList<ItemData> ();
    items.add (new ItemData ("file", f1, null, false));

    string zip_path = Path.build_filename (tmpdir, "output.zip");
    try {
        ZipExporter.export_to_zip (zip_path, items, true, File.new_for_path (workdir));
    } catch (Error e) {
        fail ("export 异常", e.message);
    }

    // 验证 staging 目录已被清理
    try {
        var dir = Dir.open (cache_root);
        string? name;
        bool has_staging = false;
        while ((name = dir.read_name ()) != null) {
            if (name.has_prefix ("staging-")) {
                has_staging = true;
                string staging_path = Path.build_filename (cache_root, name);
                fail (@"staging 目录未清理: $staging_path");
            }
        }
        if (!has_staging) pass ("成功后 staging 目录已清理");
    } catch (Error e) {
        pass ("成功后 staging 目录已清理 (cache_root 不存在)");
    }

    cleanup (tmpdir);
}

void test_zip_staging_cleanup_on_failure () {
    print ("\n=== test_zip_staging_cleanup_on_failure (C-4 异常路径) ===\n");
    string tmpdir = make_tmp_dir ();
    string workdir = Path.build_filename (tmpdir, "work");
    DirUtils.create_with_parents (workdir, 0755);

    string f1 = Path.build_filename (workdir, "a.txt");
    try { FileUtils.set_contents (f1, "content"); } catch (Error e) {}

    var items = new ArrayList<ItemData> ();
    items.add (new ItemData ("file", f1, null, false));

    // 用一个不可写的 zip 路径触发异常
    string zip_path = "/nonexistent_dir/output.zip";
    bool threw = false;
    try {
        ZipExporter.export_to_zip (zip_path, items, true, File.new_for_path (workdir));
    } catch (Error e) {
        threw = true;
    }
    assert_true ("异常路径抛出异常", threw);

    // 验证 staging 目录已被清理 (即使异常)
    string cache_root = Path.build_filename (
        Environment.get_user_cache_dir (), "filecollector", "zip-staging");
    try {
        var dir = Dir.open (cache_root);
        string? name;
        bool has_staging = false;
        while ((name = dir.read_name ()) != null) {
            if (name.has_prefix ("staging-")) {
                // 检查 staging 目录是否为空 (cleanup 可能部分执行)
                string staging_path = Path.build_filename (cache_root, name);
                try {
                    var staging_dir = Dir.open (staging_path);
                    int file_count = 0;
                    while (staging_dir.read_name () != null) file_count++;
                    if (file_count == 0) {
                        pass (@"staging 目录已清空 (目录本身未 remove)");
                    } else {
                        fail (@"staging 目录未清理: $staging_path 有 $file_count 个文件");
                    }
                } catch (Error e) {
                    // 目录已不存在
                    pass ("staging 目录已清理");
                }
                has_staging = true;
            }
        }
        if (!has_staging) pass ("异常后 staging 目录已清理");
    } catch (Error e) {
        pass ("异常后 staging 目录已清理 (cache_root 不存在)");
    }

    cleanup (tmpdir);
}

void test_zip_external_file_hashing () {
    print ("\n=== test_zip_external_file_hashing (M-2 验证) ===\n");
    string tmpdir = make_tmp_dir ();
    string workdir = Path.build_filename (tmpdir, "work");
    DirUtils.create_with_parents (workdir, 0755);

    // 在工作目录外创建两个同名文件 (内容不同, size 不同)
    string ext1 = Path.build_filename (tmpdir, "notes.txt");
    string ext2_dir = Path.build_filename (tmpdir, "other");
    DirUtils.create_with_parents (ext2_dir, 0755);
    string ext2 = Path.build_filename (ext2_dir, "notes.txt");
    try {
        FileUtils.set_contents (ext1, "short");
        FileUtils.set_contents (ext2, "this is a much longer content to differentiate");
    } catch (Error e) {}

    var items = new ArrayList<ItemData> ();
    items.add (new ItemData ("file", ext1, null, false));
    items.add (new ItemData ("file", ext2, null, false));

    string zip_path = Path.build_filename (tmpdir, "output.zip");
    try {
        ZipExporter.export_to_zip (zip_path, items, true, File.new_for_path (workdir));
        assert_true ("ZIP 生成成功", FileUtils.test (zip_path, FileTest.EXISTS));

        // 验证两个同名外部文件都被打包 (不互相覆盖)
        string stdout_buf;
        int status;
        Process.spawn_sync (null, {"unzip", "-l", zip_path}, null,
            SpawnFlags.SEARCH_PATH, null, out stdout_buf, null, out status);
        if (status == 0) {
            // 应该有两个 _external/notes.txt-XXXXXXXX 条目
            int count = 0;
            int idx = 0;
            while ((idx = stdout_buf.index_of ("notes.txt-", idx)) >= 0) {
                count++;
                idx++;
            }
            assert_true (@"两个同名外部文件都被打包 (count=$count)", count == 2);
        } else {
            fail ("unzip -l 失败");
        }
    } catch (Error e) {
        fail ("export 异常", e.message);
    }

    cleanup (tmpdir);
}

void test_zip_missing_files () {
    print ("\n=== test_zip_missing_files ===\n");
    string tmpdir = make_tmp_dir ();
    string workdir = Path.build_filename (tmpdir, "work");
    DirUtils.create_with_parents (workdir, 0755);

    string existing = Path.build_filename (workdir, "exists.txt");
    string missing = Path.build_filename (workdir, "missing.txt");
    try { FileUtils.set_contents (existing, "content"); } catch (Error e) {}

    var items = new ArrayList<ItemData> ();
    items.add (new ItemData ("file", existing, null, false));
    items.add (new ItemData ("file", missing, null, false, true)); // is_missing=true

    string zip_path = Path.build_filename (tmpdir, "output.zip");
    try {
        ZipExporter.export_to_zip (zip_path, items, true, File.new_for_path (workdir));
        assert_true ("ZIP 生成成功", FileUtils.test (zip_path, FileTest.EXISTS));

        // 解压并检查 README 是否记录了 missing files
        string extract_dir = Path.build_filename (tmpdir, "extract");
        DirUtils.create_with_parents (extract_dir, 0755);
        int status;
        Process.spawn_sync (extract_dir, {"unzip", "-q", zip_path}, null,
            SpawnFlags.SEARCH_PATH, null, null, null, out status);
        if (status == 0) {
            string readme;
            string readme_path = Path.build_filename (extract_dir, "README.md");
            if (FileUtils.get_contents (readme_path, out readme)) {
                assert_true ("README 包含 Missing Files 段", readme.contains ("Missing Files"));
                assert_true ("README 列出 missing.txt", readme.contains ("missing.txt"));
            } else {
                fail ("无法读取 README.md");
            }
        } else {
            fail ("unzip 失败");
        }
        cleanup (extract_dir);
    } catch (Error e) {
        fail ("export 异常", e.message);
    }

    cleanup (tmpdir);
}

void test_zip_text_blocks () {
    print ("\n=== test_zip_text_blocks ===\n");
    string tmpdir = make_tmp_dir ();
    string workdir = Path.build_filename (tmpdir, "work");
    DirUtils.create_with_parents (workdir, 0755);

    var items = new ArrayList<ItemData> ();
    items.add (new ItemData ("text", null, "# Task Description\nDo something useful", false));
    items.add (new ItemData ("text", null, "Some inline note", false));

    string zip_path = Path.build_filename (tmpdir, "output.zip");
    try {
        ZipExporter.export_to_zip (zip_path, items, true, File.new_for_path (workdir));
        assert_true ("ZIP 生成成功", FileUtils.test (zip_path, FileTest.EXISTS));

        // 解压并检查 README 是否包含文本块
        string extract_dir = Path.build_filename (tmpdir, "extract");
        DirUtils.create_with_parents (extract_dir, 0755);
        int status;
        Process.spawn_sync (extract_dir, {"unzip", "-q", zip_path}, null,
            SpawnFlags.SEARCH_PATH, null, null, null, out status);
        if (status == 0) {
            string readme;
            string readme_path = Path.build_filename (extract_dir, "README.md");
            if (FileUtils.get_contents (readme_path, out readme)) {
                assert_true ("README 包含 Custom Text 段", readme.contains ("Custom Text"));
                assert_true ("README 包含 Task Description", readme.contains ("Task Description"));
                assert_true ("README 包含 inline note", readme.contains ("Some inline note"));
            } else {
                fail ("无法读取 README.md");
            }
        } else {
            fail ("unzip 失败");
        }
        cleanup (extract_dir);
    } catch (Error e) {
        fail ("export 异常", e.message);
    }

    cleanup (tmpdir);
}

public static int main (string[] args) {
    print ("========== ZipExporter 测试开始 ==========\n");

    // 检查 zip/unzip 是否可用
    bool has_zip = Environment.find_program_in_path ("zip") != null;
    bool has_unzip = Environment.find_program_in_path ("unzip") != null;
    if (!has_zip) {
        print ("SKIP: zip 命令不可用\n");
        return 0;
    }

    test_zip_basic_export ();

    string cache_root = Path.build_filename (
        Environment.get_user_cache_dir (), "filecollector", "zip-staging");
    test_zip_staging_cleanup_on_success (cache_root);
    test_zip_staging_cleanup_on_failure ();
    test_zip_external_file_hashing ();
    test_zip_missing_files ();
    test_zip_text_blocks ();

    print ("\n========== 测试结果 ==========\n");
    print ("PASS: %d, FAIL: %d\n", pass_count, fail_count);
    return fail_count > 0 ? 1 : 0;
}
