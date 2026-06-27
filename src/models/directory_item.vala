using GLib;
using Gee;

// ─── 三态勾选状态模型 ────────────────────────────────────────────────
// 状态完全由 checked_files (文件路径集合) 推导, 目录的三态由其后代文件状态计算
public class CheckStateModel : GLib.Object {
    public Gee.HashSet<string> checked_files { get; private set; }
    public Gee.HashSet<string> checked_dirs { get; private set; }

    public signal void changed ();

    private Gee.HashMap<string, int> implicit_checked_dirs;

    public CheckStateModel () {
        checked_files = new Gee.HashSet<string> ();
        checked_dirs = new Gee.HashSet<string> ();
        implicit_checked_dirs = new Gee.HashMap<string, int> ();
    }

    public void clear () {
        checked_files.clear ();
        checked_dirs.clear ();
        implicit_checked_dirs.clear ();
        changed ();
    }

    public void replace_from (Gee.HashSet<string> other_files, Gee.HashSet<string>? other_dirs = null) {
        checked_files.clear ();
        checked_dirs.clear ();
        foreach (var k in other_files) {
            checked_files.add (k);
        }
        rebuild_implicit_dirs ();
        if (other_dirs != null) {
            foreach (var k in other_dirs) {
                checked_dirs.add (k);
            }
        }
        changed ();
    }

    public void set_dir_checked (string path, bool value) {
        if (value) {
            checked_dirs.add (path);
        } else {
            checked_dirs.remove (path);
        }
    }

    public void remove_ancestors_from_checked_dirs (string path) {
        var file = File.new_for_path (path);
        var parent = file.get_parent ();
        while (parent != null) {
            checked_dirs.remove (parent.get_path ());
            parent = parent.get_parent ();
        }
    }

    public int compute_state (DirectoryItem item) {
        if (!item.is_dir) {
            return item.path in checked_files ? 2 : 0;
        }
        return compute_dir_state (item);
    }

    private int compute_dir_state (DirectoryItem item) {
        bool is_loaded = (item.children.get_n_items () > 0);
        bool in_checked_dirs = item.path in checked_dirs;
        bool has_checked = has_checked_descendant (item.path);

        if (is_loaded) {
            var stats = new FileStats ();
            collect_file_stats (item, stats);
            bool has_unloaded;
            bool all_unloaded_checked;
            check_unloaded_subdirs (item, out has_unloaded, out all_unloaded_checked);
            if (stats.total > 0) {
                if (in_checked_dirs) {
                    if (stats.checked_count < stats.total) return 1;
                    return 2;
                } else {
                    if (stats.checked_count == 0) return has_checked ? 1 : 0;
                    if (stats.checked_count == stats.total && (!has_unloaded || all_unloaded_checked)) return 2;
                    return 1;
                }
            }
        }

        if (in_checked_dirs) return 2;
        if (has_checked) return 1;
        return 0;
    }

    private void check_unloaded_subdirs (DirectoryItem item, out bool has_unloaded, out bool all_in_checked_dirs) {
        has_unloaded = false;
        all_in_checked_dirs = true;
        for (uint i = 0; i < item.children.get_n_items (); i++) {
            var child = (DirectoryItem) item.children.get_item (i);
            if (child.is_dir) {
                if (!child.children_loaded) {
                    has_unloaded = true;
                    if (!(child.path in checked_dirs)) {
                        all_in_checked_dirs = false;
                    }
                } else {
                    bool child_has_unloaded;
                    bool child_all_checked;
                    check_unloaded_subdirs (child, out child_has_unloaded, out child_all_checked);
                    if (child_has_unloaded) {
                        has_unloaded = true;
                        if (!child_all_checked) {
                            all_in_checked_dirs = false;
                        }
                    }
                }
            }
        }
    }

    public bool has_checked_descendant (string dir_path) {
        return implicit_checked_dirs.has_key (dir_path);
    }

    private void collect_file_stats (DirectoryItem item, FileStats stats) {
        if (!item.is_dir) {
            stats.total++;
            if (item.path in checked_files) stats.checked_count++;
            return;
        }
        for (uint i = 0; i < item.children.get_n_items (); i++) {
            collect_file_stats ((DirectoryItem) item.children.get_item (i), stats);
        }
    }

    private class FileStats {
        public int total = 0;
        public int checked_count = 0;
    }

    private void add_to_implicit_dirs (string path) {
        var file = File.new_for_path (path);
        var parent = file.get_parent ();
        while (parent != null) {
            string p = parent.get_path ();
            int count = implicit_checked_dirs.has_key (p) ? implicit_checked_dirs.get (p) : 0;
            implicit_checked_dirs.set (p, count + 1);
            parent = parent.get_parent ();
        }
    }

    private void remove_from_implicit_dirs (string path) {
        var file = File.new_for_path (path);
        var parent = file.get_parent ();
        while (parent != null) {
            string p = parent.get_path ();
            if (!implicit_checked_dirs.has_key (p)) break;
            int count = implicit_checked_dirs.get (p);
            if (count <= 1) {
                implicit_checked_dirs.unset (p);
            } else {
                implicit_checked_dirs.set (p, count - 1);
            }
            parent = parent.get_parent ();
        }
    }

    private void rebuild_implicit_dirs () {
        implicit_checked_dirs.clear ();
        foreach (var key in checked_files) {
            add_to_implicit_dirs (key);
        }
    }

    public bool toggle_file (string path) {
        bool is_checked = path in checked_files;
        if (is_checked) {
            checked_files.remove (path);
            remove_from_implicit_dirs (path);
        } else {
            checked_files.add (path);
            add_to_implicit_dirs (path);
        }
        remove_ancestors_from_checked_dirs (path);
        changed ();
        return !is_checked;
    }

    public void set_subtree_checked (DirectoryItem item, bool value) {
        if (!item.is_dir) {
            if (value) {
                if (!(item.path in checked_files)) {
                    checked_files.add (item.path);
                    add_to_implicit_dirs (item.path);
                }
            } else {
                if (item.path in checked_files) {
                    checked_files.remove (item.path);
                    remove_from_implicit_dirs (item.path);
                }
            }
            return;
        }
        set_dir_checked (item.path, value);
        set_subtree_files (item, value);
        changed ();
    }

    private void set_subtree_files (DirectoryItem item, bool value) {
        for (uint i = 0; i < item.children.get_n_items (); i++) {
            var child = (DirectoryItem) item.children.get_item (i);
            if (!child.is_dir) {
                if (value) {
                    if (!(child.path in checked_files)) {
                        checked_files.add (child.path);
                        add_to_implicit_dirs (child.path);
                    }
                } else {
                    if (child.path in checked_files) {
                        checked_files.remove (child.path);
                        remove_from_implicit_dirs (child.path);
                    }
                }
            } else {
                set_subtree_files (child, value);
            }
        }
    }

    public void add_files (string[] paths) {
        bool any = false;
        foreach (var p in paths) {
            if (!(p in checked_files)) {
                checked_files.add (p);
                add_to_implicit_dirs (p);
                remove_ancestors_from_checked_dirs (p);
                any = true;
            }
        }
        if (any) changed ();
    }

    public void remove_files (string[] paths) {
        bool any = false;
        foreach (var p in paths) {
            if (p in checked_files) {
                checked_files.remove (p);
                remove_from_implicit_dirs (p);
                remove_ancestors_from_checked_dirs (p);
                any = true;
            }
        }
        if (any) {
            changed ();
        }
    }
}

// ─── 目录树节点模型 ──────────────────────────────────────────────────

public class DirectoryItem : GLib.Object {
    public string name { get; set; }
    public string path { get; set; }
    public bool is_dir { get; set; }
    private bool _checked = false;
    public bool checked {
        get { return _checked; }
        set {
            if (_checked != value) {
                _checked = value;
                notify_property ("checked");
                state_changed ();
            }
        }
    }
    private bool _inconsistent = false;
    public bool inconsistent {
        get { return _inconsistent; }
        set {
            if (_inconsistent != value) {
                _inconsistent = value;
                notify_property ("inconsistent");
                state_changed ();
            }
        }
    }
    public GLib.ListStore children { get; private set; }
    public bool children_loading = false;
    public bool children_loaded = false;

    public signal void state_changed ();

    public DirectoryItem (string name, string path, bool is_dir) {
        this.name = name;
        this.path = path;
        this.is_dir = is_dir;
        this.children = new GLib.ListStore (typeof (DirectoryItem));
    }

    public void set_checked_recursive (bool value) {
        _checked = value;
        _inconsistent = false;
        notify_property ("checked");
        notify_property ("inconsistent");
        state_changed ();
        for (uint i = 0; i < children.get_n_items (); i++) {
            var child = (DirectoryItem) children.get_item (i);
            child.set_checked_recursive (value);
        }
    }
}

// ─── 目录条目信息 (后台线程收集用) ──────────────────────────────────

public class DirChildInfo {
    public string name;
    public string path;
    public bool is_dir;
    public DirChildInfo (string name, string path, bool is_dir) {
        this.name = name;
        this.path = path;
        this.is_dir = is_dir;
    }
}
