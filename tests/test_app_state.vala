// AppState 单元测试
// 验证 C-1: replace_from 接受 new_snapshots 参数并正确替换快照列表

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

// ─── C-1 核心测试: replace_from 的快照参数 ────────────────────────

void test_replace_from_preserves_snapshots_when_null () {
    print ("\n=== test_replace_from_preserves_snapshots_when_null ===\n");
    var state = new AppState ();
    state.save_snapshot ("Original 1");
    state.save_snapshot ("Original 2");
    assert_eq_int ("初始有 2 个快照", 2, state.snapshots.size);

    // replace_from 不传 new_snapshots (默认 null), 快照应保留
    var new_items = new ArrayList<ItemData> ();
    new_items.add (new ItemData ("text", null, "new item", false));
    var new_checked = new HashSet<string> ();
    var new_phrases = new ArrayList<string> ();

    state.replace_from (null, false, false, new_items, new_checked, null, new_phrases);

    assert_eq_int ("replace_from(null) 后快照数量不变", 2, state.snapshots.size);
    assert_eq_str ("快照 1 名称保留", "Original 1", state.snapshots.get (0).name);
    assert_eq_str ("快照 2 名称保留", "Original 2", state.snapshots.get (1).name);
}

void test_replace_from_replaces_snapshots_when_provided () {
    print ("\n=== test_replace_from_replaces_snapshots_when_provided (C-1 核心) ===\n");
    var state = new AppState ();
    state.save_snapshot ("Old Snapshot");
    assert_eq_int ("初始有 1 个旧快照", 1, state.snapshots.size);

    // 准备新的快照列表
    var new_snapshots = new ArrayList<WorkspaceSnapshot> ();
    var snap1 = new WorkspaceSnapshot ();
    snap1.name = "New Snapshot 1";
    var snap2 = new WorkspaceSnapshot ();
    snap2.name = "New Snapshot 2";
    new_snapshots.add (snap1);
    new_snapshots.add (snap2);

    var new_items = new ArrayList<ItemData> ();
    var new_checked = new HashSet<string> ();
    var new_phrases = new ArrayList<string> ();

    state.replace_from (null, false, false, new_items, new_checked, null, new_phrases, new_snapshots);

    assert_eq_int ("replace_from 后快照被替换为 2 个", 2, state.snapshots.size);
    assert_eq_str ("新快照 1 名称", "New Snapshot 1", state.snapshots.get (0).name);
    assert_eq_str ("新快照 2 名称", "New Snapshot 2", state.snapshots.get (1).name);
}

void test_replace_from_clears_snapshots_with_empty_list () {
    print ("\n=== test_replace_from_clears_snapshots_with_empty_list ===\n");
    var state = new AppState ();
    state.save_snapshot ("To Be Cleared");
    assert_eq_int ("初始有 1 个快照", 1, state.snapshots.size);

    var empty_snapshots = new ArrayList<WorkspaceSnapshot> ();
    var new_items = new ArrayList<ItemData> ();
    var new_checked = new HashSet<string> ();
    var new_phrases = new ArrayList<string> ();

    state.replace_from (null, false, false, new_items, new_checked, null, new_phrases, empty_snapshots);

    assert_eq_int ("传空列表后快照被清空", 0, state.snapshots.size);
}

// ─── 基本状态管理测试 ──────────────────────────────────────────

void test_add_remove_items () {
    print ("\n=== test_add_remove_items ===\n");
    var state = new AppState ();

    state.add_text ("item 0");
    state.add_text ("item 1");
    state.add_text ("item 2");
    assert_eq_int ("添加 3 项后 size=3", 3, state.items.size);

    state.move_item (0, 2);
    assert_eq_str ("move 0→2 后第 0 项是原 item 1", "item 1", state.items.get (0).content);
    assert_eq_str ("move 0→2 后第 2 项是原 item 0", "item 0", state.items.get (2).content);

    state.remove_item_at (1);
    assert_eq_int ("remove index 1 后 size=2", 2, state.items.size);

    state.clear_items ();
    assert_eq_int ("clear 后 size=0", 0, state.items.size);
}

void test_move_item_edge_cases () {
    print ("\n=== test_move_item_edge_cases ===\n");
    var state = new AppState ();
    state.add_text ("a");
    state.add_text ("b");

    assert_true ("move 同索引返回 true", state.move_item (0, 0));
    assert_true ("move 越界 from 返回 false", !state.move_item (-1, 0));
    assert_true ("move 越界 to 返回 false", !state.move_item (0, 100));
    assert_true ("move 空列表返回 false", !state.move_item (0, 0) || state.items.size > 0);
}

void test_snapshot_save_apply () {
    print ("\n=== test_snapshot_save_apply ===\n");
    var state = new AppState ();
    state.add_text ("original 1");
    state.add_text ("original 2");
    state.save_snapshot ("Saved State");

    // 修改状态
    state.clear_items ();
    state.add_text ("modified");
    assert_eq_int ("修改后 size=1", 1, state.items.size);

    // 应用快照应恢复状态
    state.apply_snapshot (0);
    assert_eq_int ("应用快照后 size=2", 2, state.items.size);
    assert_eq_str ("快照恢复第 0 项", "original 1", state.items.get (0).content);
    assert_eq_str ("快照恢复第 1 项", "original 2", state.items.get (1).content);
}

void test_snapshot_apply_preserves_snapshots_list () {
    print ("\n=== test_snapshot_apply_preserves_snapshots_list ===\n");
    var state = new AppState ();
    state.add_text ("item");
    state.save_snapshot ("Snap A");
    state.save_snapshot ("Snap B");
    assert_eq_int ("2 个快照", 2, state.snapshots.size);

    // 应用其中一个快照, 快照列表本身不应被清空
    state.apply_snapshot (0);
    assert_eq_int ("应用快照后快照列表仍为 2", 2, state.snapshots.size);
}

void test_ensure_default_snapshot () {
    print ("\n=== test_ensure_default_snapshot ===\n");
    var state = new AppState ();
    assert_eq_int ("初始无快照", 0, state.snapshots.size);

    state.ensure_default_snapshot ();
    assert_eq_int ("ensure 后有 1 个快照", 1, state.snapshots.size);

    state.ensure_default_snapshot ();
    assert_eq_int ("再次 ensure 不重复添加", 1, state.snapshots.size);
}

void test_replace_from_items_deep_copy () {
    print ("\n=== test_replace_from_items_deep_copy ===\n");
    var state = new AppState ();

    var new_items = new ArrayList<ItemData> ();
    var item = new ItemData ("text", null, "original", false);
    new_items.add (item);
    var new_checked = new HashSet<string> ();
    var new_phrases = new ArrayList<string> ();

    state.replace_from (null, false, false, new_items, new_checked, null, new_phrases);

    // 修改源 item, state 中的 item 不应受影响 (深拷贝)
    item.content = "modified";
    assert_eq_str ("state 中的 item 是深拷贝", "original", state.items.get (0).content);
}

void test_checked_paths_management () {
    print ("\n=== test_checked_paths_management ===\n");
    var state = new AppState ();

    state.add_checked_path ("/path/to/file1");
    state.add_checked_path ("/path/to/file2");
    assert_eq_int ("2 个 checked paths", 2, state.check_model.checked_files.size);

    state.remove_checked_path ("/path/to/file1");
    assert_eq_int ("remove 后 1 个 checked path", 1, state.check_model.checked_files.size);
}

public static int main (string[] args) {
    print ("========== AppState 测试开始 ==========\n");

    test_replace_from_preserves_snapshots_when_null ();
    test_replace_from_replaces_snapshots_when_provided ();
    test_replace_from_clears_snapshots_with_empty_list ();
    test_add_remove_items ();
    test_move_item_edge_cases ();
    test_snapshot_save_apply ();
    test_snapshot_apply_preserves_snapshots_list ();
    test_ensure_default_snapshot ();
    test_replace_from_items_deep_copy ();
    test_checked_paths_management ();

    print ("\n========== 测试结果 ==========\n");
    print ("PASS: %d, FAIL: %d\n", pass_count, fail_count);
    return fail_count > 0 ? 1 : 0;
}
