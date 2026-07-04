using Gee;

// ─── Diff-based 撤销系统 ──────────────────────────────────────────────
// 用轻量差异 (UndoDelta) 替代全量快照 (UndoState), 避免大列表深拷贝导致内存膨胀。
// 常见操作 (插入/删除/编辑/交换/移动/设置模式) 仅存储变更部分;
// 复杂操作 (清空/批量应用/切换工作目录) 仍回退到全量快照。

public enum UndoOp {
    SNAPSHOT,       // 全量快照 (复杂操作回退)
    INSERT,         // 在 index 处插入了 items
    REMOVE,         // 在 index 处移除了 items (含可能被同步移除的 checked_paths)
    EDIT,           // items[index] 的 content 从 old_content 变为 new_content
    SWAP,           // items[index] 与 items[index2] 互换
    MOVE,           // items 从 from_index 移到 to_index
    SET_ABSOLUTE,   // use_absolute 变更 (可能连带 show_header)
    SET_HEADER;     // show_header 变更
}

// ─── 全量快照 (仅 SNAPSHOT 使用) ─────────────────────────────────────
// 使用紧凑的并行数组存储, 避免为每个条目创建 GObject 实例;
// 字符串通过引用计数共享, 无需深拷贝。

public class UndoState : GLib.Object {
    internal string[] _types;
    internal string?[] _paths;
    internal string?[] _contents;
    internal bool[] _force_abs;
    internal bool[] _is_missing;
    internal int[] _start_lines;
    internal int[] _end_lines;
    public Gee.HashSet<string> checked_paths { get; private set; }
    public Gee.HashSet<string> checked_dirs { get; private set; }
    public File? work_dir { get; private set; }
    public bool use_absolute { get; private set; }
    public bool show_header { get; private set; }
    public int n_items { get { return _types.length; } }

    public UndoState (
        Gee.ArrayList<ItemData> src_items,
        Gee.HashSet<string> src_checked_paths,
        Gee.HashSet<string> src_checked_dirs,
        File? src_work_dir,
        bool src_use_absolute,
        bool src_show_header
    ) {
        int n = (int) src_items.size;
        _types = new string[n];
        _paths = new string?[n];
        _contents = new string?[n];
        _force_abs = new bool[n];
        _is_missing = new bool[n];
        _start_lines = new int[n];
        _end_lines = new int[n];
        for (int i = 0; i < n; i++) {
            var it = src_items.get (i);
            _types[i] = it.item_type;
            _paths[i] = it.file_path;
            _contents[i] = it.content;
            _force_abs[i] = it.force_absolute;
            _is_missing[i] = it.is_missing;
            _start_lines[i] = it.start_line;
            _end_lines[i] = it.end_line;
        }
        checked_paths = new Gee.HashSet<string> ();
        foreach (var key in src_checked_paths) {
            checked_paths.add (key);
        }
        checked_dirs = new Gee.HashSet<string> ();
        foreach (var key in src_checked_dirs) {
            checked_dirs.add (key);
        }
        work_dir = src_work_dir;
        use_absolute = src_use_absolute;
        show_header = src_show_header;
    }

    public ItemData get_item (int index) {
        var item = new ItemData (_types[index], _paths[index], _contents[index], _force_abs[index], _is_missing[index]);
        item.start_line = _start_lines[index];
        item.end_line = _end_lines[index];
        return item;
    }
}

// ─── 差异记录 ─────────────────────────────────────────────────────────

public class UndoDelta : GLib.Object {
    public UndoOp op { get; set; }

    // SNAPSHOT
    public UndoState? snapshot { get; set; }

    // INSERT / REMOVE: 起始索引 + 涉及的条目
    public int index { get; set; }
    public Gee.ArrayList<ItemData>? items { get; set; }

    // REMOVE: 被同步移除的 checked_paths (仅文件条目)
    public Gee.ArrayList<string>? removed_checked_paths { get; set; }

    // EDIT: 索引 + 旧/新内容
    public string? old_content { get; set; }
    public string? new_content { get; set; }

    // SWAP: 两个索引
    public int index2 { get; set; }

    // MOVE: from → to
    public int from_index { get; set; }
    public int to_index { get; set; }

    // SET_ABSOLUTE / SET_HEADER: 旧/新值
    public bool old_bool_value { get; set; }
    public bool new_bool_value { get; set; }
    // SET_ABSOLUTE 连带保存旧/新 show_header
    public bool old_show_header { get; set; }
    public bool new_show_header { get; set; }

    // ─── 便捷构造 ──────────────────────────────────────────────────

    public UndoDelta.for_snapshot (UndoState state) {
        op = UndoOp.SNAPSHOT;
        snapshot = state;
    }

    public UndoDelta.for_insert (int idx, Gee.ArrayList<ItemData> inserted) {
        op = UndoOp.INSERT;
        index = idx;
        items = inserted;
    }

    public UndoDelta.for_remove (int idx, Gee.ArrayList<ItemData> removed,
                                  owned Gee.ArrayList<string>? rm_checked = null) {
        op = UndoOp.REMOVE;
        index = idx;
        items = removed;
        removed_checked_paths = rm_checked;
    }

    public UndoDelta.for_edit (int idx, string old_c, string new_c) {
        op = UndoOp.EDIT;
        index = idx;
        old_content = old_c;
        new_content = new_c;
    }

    public UndoDelta.for_swap (int idx1, int idx2) {
        op = UndoOp.SWAP;
        index = idx1;
        index2 = idx2;
    }

    public UndoDelta.for_move (int from, int to) {
        op = UndoOp.MOVE;
        from_index = from;
        to_index = to;
    }

    public UndoDelta.for_absolute (bool old_abs, bool new_abs,
                                    bool old_hdr, bool new_hdr) {
        op = UndoOp.SET_ABSOLUTE;
        old_bool_value = old_abs;
        new_bool_value = new_abs;
        old_show_header = old_hdr;
        new_show_header = new_hdr;
    }

    public UndoDelta.for_header (bool old_val, bool new_val) {
        op = UndoOp.SET_HEADER;
        old_bool_value = old_val;
        new_bool_value = new_val;
    }
}

// ─── 撤销管理器 ──────────────────────────────────────────────────────

public class UndoManager : GLib.Object {
    public bool can_undo { get { return undo_stack.size > 0; } }
    public bool can_redo { get { return redo_stack.size > 0; } }

    public int get_stack_size () {
        return undo_stack.size;
    }

    private Gee.ArrayList<UndoDelta> undo_stack;
    private Gee.ArrayList<UndoDelta> redo_stack;
    private bool in_progress = false;
    private const int MAX_STACK_DEPTH = 50;

    public UndoManager () {
        undo_stack = new Gee.ArrayList<UndoDelta> ();
        redo_stack = new Gee.ArrayList<UndoDelta> ();
    }

    public void push (UndoDelta delta) {
        if (in_progress) return;
        undo_stack.add (delta);
        if (undo_stack.size > MAX_STACK_DEPTH) {
            undo_stack.remove_at (0);
        }
        redo_stack.clear ();
    }

    public UndoDelta? pop_undo () {
        if (undo_stack.size == 0) return null;
        var delta = undo_stack.get ((int) undo_stack.size - 1);
        undo_stack.remove_at ((int) undo_stack.size - 1);
        return delta;
    }

    public void push_redo (UndoDelta delta) {
        redo_stack.add (delta);
    }

    public void push_undo (UndoDelta delta) {
        undo_stack.add (delta);
    }

    public UndoDelta? pop_redo () {
        if (redo_stack.size == 0) return null;
        var delta = redo_stack.get ((int) redo_stack.size - 1);
        redo_stack.remove_at ((int) redo_stack.size - 1);
        return delta;
    }

    // 调用方应在 undo/redo 操作序列前后手动设置
    public void set_in_progress (bool val) {
        in_progress = val;
    }

    public void clear () {
        undo_stack.clear ();
        redo_stack.clear ();
    }
}
