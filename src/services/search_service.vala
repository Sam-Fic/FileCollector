using Gee;

public class SearchService : GLib.Object {
    public signal void result_found (SearchResult result);
    public signal void progress_updated (int scanned, int matched);
    public signal void finished (int total_scanned, int total_matched);

    private const int64 MAX_FILE_SIZE = 2 * 1024 * 1024;
    private const int MAX_RESULTS = 2000;
    // 批量发射结果: 把短时间内的多次匹配聚合成一批, 用一次 Idle 回主线程统一发射,
    // 避免每个匹配都单独 Idle.add (几百个匹配 = 几百次主线程回调, 每次都新建 GTK
    // 行 widget, 造成 UI 频繁刷新与卡顿).
    private const int BATCH_SIZE = 50;
    private Gee.ArrayList<SearchResult> pending_results = new Gee.ArrayList<SearchResult> ();

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

        string[] ignored_dirs = sanitize_ignored_dirs (ConfigManager.get_ignored_dirs ());
        int scanned = 0;
        int matched = 0;

        string search_keyword = case_sensitive ? keyword : keyword.down ();

        try {
            scan_directory (root_dir, root_dir, search_keyword, case_sensitive, ignored_dirs, cancellable, ref scanned, ref matched);
        } catch (Error e) {
            warning ("Search error: %s", e.message);
        }

        // 收尾: 把最后不足一批的残留结果一并发射 (内部会检查取消)
        flush_pending_results (cancellable);

        if (!cancellable.is_cancelled ()) {
            Idle.add (() => {
                finished (scanned, matched);
                return Source.REMOVE;
            });
        }
    }

    /**
     * 将累积的待发射结果成批回主线程: 在一次 Idle 中逐个发射本批结果, 把 N 次主线程
     * 回调降为 N/BATCH_SIZE 次, 显著减少 UI 刷新次数. 取消时整批丢弃.
     */
    private void flush_pending_results (GLib.Cancellable cancellable) {
        if (pending_results.size == 0) return;
        var batch = new Gee.ArrayList<SearchResult> ();
        batch.add_all (pending_results);
        pending_results.clear ();
        Idle.add (() => {
            if (!cancellable.is_cancelled ()) {
                foreach (var r in batch) {
                    result_found (r);
                }
            }
            return Source.REMOVE;
        });
    }

    /**
     * 净化忽略目录列表：剔除空串与空白项（空串会使 name in ignored_dirs 的比较
     * 行为异常，导致整个子树被错误跳过），并去重。忽略目录只按 basename 比较，
     * 故此处无需路径规范化。结果按原始配置内容做静态缓存, 配置不变时直接复用,
     * 避免每次搜索都重建去重列表.
     */
    private static Mutex sanitize_lock;
    private static string[]? cached_raw_dirs = null;
    private static string[]? cached_sanitized_dirs = null;
    private static string[] sanitize_ignored_dirs (string[] raw) {
        // 静态缓存可能被多个搜索线程并发访问, 必须加锁保护
        // (Gee.ArrayList / 数组重写不是线程安全的, 并发写会破坏内部状态)
        sanitize_lock.lock ();
        try {
            if (cached_raw_dirs != null && cached_raw_dirs.length == raw.length) {
                bool same = true;
                for (int i = 0; i < raw.length; i++) {
                    if (cached_raw_dirs[i] != raw[i]) { same = false; break; }
                }
                if (same && cached_sanitized_dirs != null) return cached_sanitized_dirs;
            }
            var cleaned = new Gee.ArrayList<string> ();
            foreach (var d in raw) {
                if (d == null) continue;
                string s = d.strip ();
                if (s.length == 0) continue;
                if (!cleaned.contains (s)) cleaned.add (s);
            }
            cached_raw_dirs = raw;
            cached_sanitized_dirs = cleaned.to_array ();
            return cached_sanitized_dirs;
        } finally {
            sanitize_lock.unlock ();
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
            var file = File.new_for_path (file_path);
            FileInputStream? fis = null;
            try {
                fis = file.read ();

                // 先读前 2048 字节做二进制检测: 含 \0 即视为二进制文件, 跳过
                var head = fis.read_bytes (2048);
                unowned uint8[] head_data = head.get_data ();
                for (size_t i = 0; i < head_data.length; i++) {
                    if (head_data[i] == 0) return;
                }

                // 流式拼接文件内容, 避免一次性把整个文件读入内存
                // (总大小已由 scan_directory 的 MAX_FILE_SIZE 上限控制).
                var content_builder = new StringBuilder ();
                content_builder.append (EncodingHelper.bytes_to_string_safe (head_data, head_data.length));

                const int BUFFER_SIZE = 8192;
                uint8[] buffer = new uint8[BUFFER_SIZE];
                ssize_t n;
                while ((n = fis.read (buffer)) > 0) {
                    if (cancellable.is_cancelled ()) break;
                    content_builder.append (EncodingHelper.bytes_to_string_safe (buffer, (size_t) n));
                }
                if (cancellable.is_cancelled ()) return;

                string content = EncodingHelper.decode_to_utf8 (content_builder.str.data);
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
                        // 累积到批次, 由 flush_pending_results 成批回主线程发射,
                        // 避免每个匹配都单独 Idle.add 造成 UI 频繁刷新.
                        pending_results.add (new SearchResult (file_path, rel_path, ln, lc));
                        if (pending_results.size >= BATCH_SIZE) {
                            flush_pending_results (cancellable);
                        }
                        if (matched >= MAX_RESULTS) break;
                    }
                }
            } finally {
                if (fis != null) {
                    try { fis.close (); } catch (Error e) {}
                }
            }
        } catch (Error e) {
            // 忽略无权限或读取失败的文件
        }
    }
}
