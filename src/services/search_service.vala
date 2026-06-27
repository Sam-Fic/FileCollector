using Gee;

public class SearchService : GLib.Object {
    public signal void result_found (SearchResult result);
    public signal void progress_updated (int scanned, int matched);
    public signal void finished (int total_scanned, int total_matched);

    private const int64 MAX_FILE_SIZE = 2 * 1024 * 1024;
    private const int MAX_RESULTS = 2000;

    public void search_async (string root_dir, string keyword, bool case_sensitive, GLib.Cancellable cancellable) {
        new GLib.Thread<void*> ("global-search", () => {
            perform_search (root_dir, keyword, case_sensitive, cancellable);
            return null;
        });
    }

    private void perform_search (string root_dir, string keyword, bool case_sensitive, GLib.Cancellable cancellable) {
        if (keyword.length == 0) {
            if (!cancellable.is_cancelled ()) {
                Idle.add (() => { finished (0, 0); return Source.REMOVE; });
            }
            return;
        }

        string[] ignored_dirs = ConfigManager.get_ignored_dirs ();
        int scanned = 0;
        int matched = 0;

        string search_keyword = case_sensitive ? keyword : keyword.down ();

        try {
            scan_directory (root_dir, root_dir, search_keyword, case_sensitive, ignored_dirs, cancellable, ref scanned, ref matched);
        } catch (Error e) {
            warning ("Search error: %s", e.message);
        }

        if (!cancellable.is_cancelled ()) {
            Idle.add (() => {
                finished (scanned, matched);
                return Source.REMOVE;
            });
        }
    }

    private void scan_directory (string root, string current_dir, string keyword, bool case_sensitive,
                                  string[] ignored_dirs, GLib.Cancellable cancellable,
                                  ref int scanned, ref int matched) throws Error {
        if (cancellable.is_cancelled ()) return;
        if (matched >= MAX_RESULTS) return;

        var dir = File.new_for_path (current_dir);
        var enumerator = dir.enumerate_children (
            FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_SIZE,
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
            cancellable
        );

        FileInfo info;
        while ((info = enumerator.next_file (cancellable)) != null) {
            if (cancellable.is_cancelled () || matched >= MAX_RESULTS) break;

            string name = info.get_name ();
            if (info.get_file_type () == FileType.DIRECTORY) {
                if (name in ignored_dirs || name.has_prefix (".")) continue;
                scan_directory (root, dir.get_child (name).get_path (), keyword, case_sensitive,
                                ignored_dirs, cancellable, ref scanned, ref matched);
            } else {
                if (info.get_size () > MAX_FILE_SIZE || info.get_size () == 0) continue;

                string file_path = dir.get_child (name).get_path ();
                scanned++;

                if (scanned % 50 == 0) {
                    int s = scanned;
                    int m = matched;
                    Idle.add (() => { progress_updated (s, m); return Source.REMOVE; });
                }

                search_in_file (file_path, root, keyword, case_sensitive, cancellable, ref matched);
            }
        }
    }

    private void search_in_file (string file_path, string root, string keyword, bool case_sensitive,
                                  GLib.Cancellable cancellable, ref int matched) {
        try {
            uint8[] content_bytes;
            FileUtils.get_data (file_path, out content_bytes);
            if (content_bytes == null || content_bytes.length == 0) return;

            size_t check_len = size_t.min (content_bytes.length, 2048);
            for (size_t i = 0; i < check_len; i++) {
                if (content_bytes[i] == 0) return;
            }

            string content = EncodingHelper.decode_to_utf8 (content_bytes);
            string[] lines = content.split ("\n");

            string rel_path = file_path;
            var root_dir = File.new_for_path (root);
            var rel = root_dir.get_relative_path (File.new_for_path (file_path));
            if (rel != null) rel_path = rel;

            for (int i = 0; i < lines.length; i++) {
                if (cancellable.is_cancelled ()) break;
                string line = lines[i];
                string cmp_line = case_sensitive ? line : line.down ();

                if (cmp_line.contains (keyword)) {
                    matched++;
                    int ln = i + 1;
                    string lc = line.strip ();
                    string fp = file_path;
                    string rp = rel_path;
                    Idle.add (() => {
                        if (!cancellable.is_cancelled ()) {
                            result_found (new SearchResult (fp, rp, ln, lc));
                        }
                        return Source.REMOVE;
                    });
                    if (matched >= MAX_RESULTS) break;
                }
            }
        } catch (Error e) {
            // 忽略无权限或读取失败的文件
        }
    }
}
