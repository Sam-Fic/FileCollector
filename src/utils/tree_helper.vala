public class TreeHelper : GLib.Object {
    public const int COL_NAME = 0;
    public const int COL_PATH = 1;
    public const int COL_IS_DIR = 2;
    public const int COL_CHECKED = 3;
    public const int COL_INCONSISTENT = 4;

    public static void load_directory_children (
        Gtk.TreeIter parent,
        File dir,
        Gtk.TreeStore tree_model,
        HashTable<string, bool> checked_paths
    ) {
        try {
            var enumerator = dir.enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NONE
            );

            var dirs = new GenericArray<FileInfo> ();
            var files = new GenericArray<FileInfo> ();

            FileInfo info;
            while ((info = enumerator.next_file ()) != null) {
                if (info.get_name ().has_prefix (".")) continue;
                if (info.get_file_type () == FileType.DIRECTORY) {
                    dirs.add (info);
                } else {
                    files.add (info);
                }
            }

            dirs.sort ((a, b) => a.get_name ().collate (b.get_name ()));
            files.sort ((a, b) => a.get_name ().collate (b.get_name ()));

            foreach (var dir_info in dirs) {
                var file = dir.get_child (dir_info.get_name ());
                Gtk.TreeIter iter;
                tree_model.append (out iter, parent);
                var file_path_str = file.get_path ();
                bool is_checked = (file_path_str in checked_paths);
                tree_model.set (iter, COL_NAME, dir_info.get_name (), COL_PATH, file_path_str,
                                 COL_IS_DIR, true, COL_CHECKED, is_checked, COL_INCONSISTENT, false, -1);

                Gtk.TreeIter dummy;
                tree_model.append (out dummy, iter);
                tree_model.set (dummy, COL_NAME, _("正在加载..."), -1);
            }

            foreach (var file_info in files) {
                var file = dir.get_child (file_info.get_name ());
                Gtk.TreeIter iter;
                tree_model.append (out iter, parent);
                var file_path_str = file.get_path ();
                bool is_checked = (file_path_str in checked_paths);
                tree_model.set (iter, COL_NAME, file_info.get_name (), COL_PATH, file_path_str,
                                 COL_IS_DIR, false, COL_CHECKED, is_checked, COL_INCONSISTENT, false, -1);
            }
        } catch (Error e) {
            warning (_("无法读取目录: %s"), e.message);
        }
    }

    public static void restore_tree_checks (
        Gtk.TreeStore tree_model,
        HashTable<string, bool> checked_paths
    ) {
        Gtk.TreeIter iter;
        if (!tree_model.get_iter_first (out iter)) return;
        restore_tree_checks_recursive (iter, tree_model, checked_paths);
    }

    private static void restore_tree_checks_recursive (
        Gtk.TreeIter iter,
        Gtk.TreeStore tree_model,
        HashTable<string, bool> checked_paths
    ) {
        do {
            string path;
            tree_model.get (iter, COL_PATH, out path, -1);
            if (path != null && path in checked_paths) {
                tree_model.set (iter, COL_CHECKED, true, COL_INCONSISTENT, false, -1);
            }
            Gtk.TreeIter child;
            if (tree_model.iter_children (out child, iter)) {
                restore_tree_checks_recursive (child, tree_model, checked_paths);
            }
        } while (tree_model.iter_next (ref iter));
    }
}
