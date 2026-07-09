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

    public bool has_checked_descendant (string dir_path) {
        return implicit_checked_dirs.has_key (dir_path);
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
