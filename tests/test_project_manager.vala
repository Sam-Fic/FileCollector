// ProjectManager 单元测试
// 覆盖 4.10.1 / 4.10.2 的项目文件兼容性修复:
//   - checked_files / checked_entries 字段回退 (primary 非数组也要回退)
//   - 非字符串 / null / 空串元素防御
//   - 绝对路径与相对路径归一化
//   - work_dir 缺失时不得把相对路径绑到进程 CWD
// CLI 的 load_project 已改为复用 ProjectManager 的这两个 public helper,
// 因此这里覆盖了 GUI / CLI 共用的读取规则。

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
void assert_eq_int (string desc, int expected, int actual) {
    if (expected == actual) pass (desc);
    else fail (desc, @"期望 $expected, 实际 $actual");
}
void assert_eq_str (string desc, string expected, string actual) {
    if (expected == actual) pass (desc);
    else fail (desc, @"期望 '$expected', 实际 '$actual'");
}

private static string tmp_dir = "";
private static string real_file = "";
private static string expected_path = "";

private static void setup_fixture () throws Error {
    tmp_dir = GLib.Path.build_filename (
        GLib.Environment.get_tmp_dir (), "filecollector-pm-tests");
    GLib.DirUtils.create_with_parents (tmp_dir, 0755);
    real_file = GLib.Path.build_filename (tmp_dir, "a.txt");
    GLib.FileUtils.set_contents (real_file, "hello");
    expected_path = File.new_for_path (real_file).get_path () ?? "";
}

private static string write_json (string name, Json.Builder builder) throws Error {
    string path = GLib.Path.build_filename (tmp_dir, name);
    var gen = new Json.Generator ();
    gen.set_root (builder.get_root ());
    // to_stream / File.replace 都是项目里已使用的 API, 不依赖 to_data 绑定差异。
    var stream = File.new_for_path (path).replace (null, false, FileCreateFlags.NONE);
    gen.to_stream (stream, null);
    stream.close ();
    return path;
}

// Windows 上把 \ 换成 /, 模拟 Flet 版写出的正斜杠路径; Linux 上无变化。
private static string forward_slashes (string path) {
    var sb = new StringBuilder ();
    for (int i = 0; i < path.length; i++) {
        char c = path[i];
        sb.append_c (c == '\\' ? '/' : c);
    }
    return sb.str;
}

// ─── 1. 路径归一化 ────────────────────────────────────────────────

void test_canonicalize_checked_path () {
    print ("\n=== test_canonicalize_checked_path ===\n");
    var wd = File.new_for_path (tmp_dir);

    assert_eq_str ("absolute path normalizes to File.get_path()",
        expected_path,
        ProjectManager.canonicalize_checked_path (real_file, null) ?? "");

    assert_eq_str ("forward-slash absolute path normalizes",
        expected_path,
        ProjectManager.canonicalize_checked_path (forward_slashes (real_file), null) ?? "");

    assert_eq_str ("relative path resolves against work_dir",
        expected_path,
        ProjectManager.canonicalize_checked_path ("a.txt", wd) ?? "");

    // B3: File.new_for_path() 内部会把相对路径按 CWD 规范化, 不能用它兜底。
    assert_true ("relative path without work_dir is dropped (no CWD binding)",
        ProjectManager.canonicalize_checked_path ("a.txt", null) == null);

    assert_true ("empty path is dropped",
        ProjectManager.canonicalize_checked_path ("", wd) == null);
}

// ─── 2. 字段回退与 null 防御 ──────────────────────────────────────

void test_read_string_array () {
    print ("\n=== test_read_string_array ===\n");

    // primary 存在但值不是数组 -> 必须继续回退, 不能"命中即停"。
    var b = new Json.Builder ();
    b.begin_object ();
    b.set_member_name ("checked_files");
    b.add_null_value ();
    b.set_member_name ("checked_entries");
    b.begin_array ();
    b.add_string_value ("kept");
    b.add_null_value ();
    b.begin_object (); b.end_object ();
    b.add_string_value ("");
    b.end_array ();
    b.end_object ();
    Json.Object? obj = b.get_root ().get_object ();
    if (obj == null) { fail ("fallback fixture root is not an object"); return; }
    var values = ProjectManager.read_string_array (obj, "checked_files", "checked_entries");
    assert_eq_int ("falls back when primary is not an array", 1, values.size);
    if (values.size == 1) {
        assert_eq_str ("null/object/empty elements are skipped", "kept", values.get (0));
    }

    // primary 是正常数组时优先, 不读 fallback。
    var b2 = new Json.Builder ();
    b2.begin_object ();
    b2.set_member_name ("checked_files");
    b2.begin_array (); b2.add_string_value ("own"); b2.end_array ();
    b2.set_member_name ("checked_entries");
    b2.begin_array (); b2.add_string_value ("other"); b2.end_array ();
    b2.end_object ();
    Json.Object? obj2 = b2.get_root ().get_object ();
    if (obj2 == null) { fail ("primary fixture root is not an object"); return; }
    var own = ProjectManager.read_string_array (obj2, "checked_files", "checked_entries");
    assert_eq_int ("primary array wins", 1, own.size);
    if (own.size == 1) {
        assert_eq_str ("primary value kept", "own", own.get (0));
    }

    // 无回退字段: null 元素不能进入集合。
    var b3 = new Json.Builder ();
    b3.begin_object ();
    b3.set_member_name ("checked_dirs");
    b3.begin_array ();
    b3.add_null_value ();
    b3.add_string_value ("dir");
    b3.end_array ();
    b3.end_object ();
    Json.Object? obj3 = b3.get_root ().get_object ();
    if (obj3 == null) { fail ("checked_dirs fixture root is not an object"); return; }
    var dirs = ProjectManager.read_string_array (obj3, "checked_dirs", "");
    assert_eq_int ("checked_dirs null element skipped", 1, dirs.size);
}

// ─── 3. 端到端加载 ────────────────────────────────────────────────

private static string build_project_fixture (string name, bool with_work_dir) throws Error {
    var b = new Json.Builder ();
    b.begin_object ();
    if (with_work_dir) {
        b.set_member_name ("work_dir");
        b.add_string_value (tmp_dir);
    }
    b.set_member_name ("checked_entries");
    b.begin_array ();
    b.add_string_value (forward_slashes (real_file));
    b.add_null_value ();
    b.begin_object (); b.end_object ();
    b.add_string_value ("missing.txt");
    b.end_array ();
    b.set_member_name ("checked_dirs");
    b.begin_array ();
    b.add_null_value ();
    b.add_string_value ("some-dir");
    b.end_array ();
    b.set_member_name ("common_phrases");
    b.begin_array ();
    b.add_null_value ();
    b.add_string_value ("phrase");
    b.end_array ();
    b.end_object ();
    return write_json (name, b);
}

private static void load_fixture (
    string path,
    out Gee.HashSet<string> checked,
    out Gee.HashSet<string> dirs,
    out Gee.ArrayList<string> phrases
) throws Error {
    var items = new Gee.ArrayList<ItemData> ();
    var snaps = new Gee.ArrayList<WorkspaceSnapshot> ();
    checked = new Gee.HashSet<string> ();
    dirs = new Gee.HashSet<string> ();
    phrases = new Gee.ArrayList<string> ();
    File? wd = null;
    string? pf = null;
    bool ua = false;
    bool sh = false;
    ProjectManager.load_project_file (
        path, items, checked, dirs, phrases, snaps,
        out wd, out pf, out ua, out sh);
}

void test_load_project_file () {
    print ("\n=== test_load_project_file ===\n");
    try {
        string path = build_project_fixture ("flet-compat.fcol", true);
        Gee.HashSet<string> checked;
        Gee.HashSet<string> dirs;
        Gee.ArrayList<string> phrases;
        load_fixture (path, out checked, out dirs, out phrases);

        // 正斜杠绝对路径 + 存在性过滤后只剩 1 条; null / 对象 / 不存在项都被剔除。
        assert_eq_int ("only existing checked path survives", 1, checked.size);
        assert_true ("forward-slash path matches canonical path",
            checked.contains (expected_path));
        assert_eq_int ("checked_dirs null element skipped", 1, dirs.size);
        assert_eq_int ("common_phrases null element skipped", 1, phrases.size);
    } catch (Error e) {
        fail ("load_project_file with checked_entries", e.message);
    }
}

void test_relative_path_without_work_dir () {
    print ("\n=== test_relative_path_without_work_dir ===\n");
    try {
        // 项目文件缺 work_dir, 只写相对勾选路径。
        // 若实现用 File.new_for_path() 兜底, 会绑到 CWD 并可能误命中同名文件。
        var b = new Json.Builder ();
        b.begin_object ();
        b.set_member_name ("checked_entries");
        b.begin_array ();
        b.add_string_value ("a.txt");
        b.end_array ();
        b.end_object ();
        string path = write_json ("no-work-dir.fcol", b);

        Gee.HashSet<string> checked;
        Gee.HashSet<string> dirs;
        Gee.ArrayList<string> phrases;
        load_fixture (path, out checked, out dirs, out phrases);
        assert_eq_int ("relative paths dropped when work_dir is missing", 0, checked.size);
    } catch (Error e) {
        fail ("load_project_file without work_dir", e.message);
    }
}

public static int main (string[] args) {
    print ("========== ProjectManager 测试开始 ==========\n");
    try {
        setup_fixture ();
    } catch (Error e) {
        print ("FAIL: fixture setup - %s\n", e.message);
        return 1;
    }

    test_canonicalize_checked_path ();
    test_read_string_array ();
    test_load_project_file ();
    test_relative_path_without_work_dir ();

    print ("\n========== 测试结果 ==========\n");
    print ("PASS: %d, FAIL: %d\n", pass_count, fail_count);
    return fail_count > 0 ? 1 : 0;
}
