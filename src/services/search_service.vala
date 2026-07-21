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

    /**
     * 同步多词布尔搜索 (AI search_files 工具专用).
     *
     * 与 search_async 的差异:
     *   - 同步执行, 直接返回格式化字符串 (AI 工具不能走信号/线程)
     *   - 接受已解析的 SearchQueryNode, 分离解析与搜索职责
     *   - 同时支持文件名匹配 (对 basename 求值 node.matches) 和内容匹配 (逐行求值)
     *
     * 复用 sanitize_ignored_dirs / MAX_FILE_SIZE / 二进制检测逻辑,
     * 避免与现有 search_async 产生重复实现.
     */
    public string search_multi_sync (
        string root_dir,
        SearchQueryNode query_node,
        bool case_sensitive,
        bool search_filename,
        bool search_content,
        int max_filename_results = 50,
        int max_content_results = 100,
        int max_depth = 8
    ) {
        var sb = new StringBuilder ();
        sb.append ("ROOT=").append (root_dir).append ("\n");
        sb.append ("QUERY=").append (query_node.to_debug_string ()).append ("\n\n");

        string[] ignored_dirs = sanitize_ignored_dirs (ConfigManager.get_ignored_dirs ());
        int scanned = 0;
        int fn_matched = 0;
        int content_matched = 0;
        int files_with_content_match = 0;

        try {
            scan_directory_multi (
                root_dir, root_dir, query_node, case_sensitive, ignored_dirs,
                sb, ref scanned, ref fn_matched, ref content_matched, ref files_with_content_match,
                max_filename_results, max_content_results, max_depth, 0
            );
        } catch (Error e) {
            warning ("search_multi_sync error: %s", e.message);
            sb.append ("\n# ERROR: ").append (e.message).append ("\n");
        }

        sb.append ("\n# scanned ").append (scanned.to_string ()).append (" file(s)");
        if (search_filename) {
            sb.append (", filename matches: ").append (fn_matched.to_string ());
        }
        if (search_content) {
            sb.append (", content matches: ").append (content_matched.to_string ())
              .append (" in ").append (files_with_content_match.to_string ()).append (" file(s)");
        }
        return sb.str;
    }

    private void scan_directory_multi (
        string root, string current_dir,
        SearchQueryNode query_node, bool case_sensitive, string[] ignored_dirs,
        StringBuilder sb,
        ref int scanned, ref int fn_matched, ref int content_matched, ref int files_with_content_match,
        int max_fn, int max_content, int max_depth, int depth
    ) throws Error {
        if (depth > max_depth) return;
        if (fn_matched >= max_fn && content_matched >= max_content) return;

        var dir = File.new_for_path (current_dir);
        var enumerator = dir.enumerate_children (
            FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_SIZE,
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS
        );

        FileInfo info;
        while ((info = enumerator.next_file ()) != null) {
            if (fn_matched >= max_fn && content_matched >= max_content) break;

            string name = info.get_name ();
            if (info.get_file_type () == FileType.DIRECTORY) {
                if (name in ignored_dirs || name.has_prefix (".")) continue;
                scan_directory_multi (
                    root, dir.get_child (name).get_path (),
                    query_node, case_sensitive, ignored_dirs, sb,
                    ref scanned, ref fn_matched, ref content_matched, ref files_with_content_match,
                    max_fn, max_content, max_depth, depth + 1
                );
            } else {
                if (info.get_size () > MAX_FILE_SIZE || info.get_size () == 0) continue;
                string file_path = dir.get_child (name).get_path ();
                scanned++;

                string rel_path = file_path;
                var root_dir = File.new_for_path (root);
                var rel = root_dir.get_relative_path (File.new_for_path (file_path));
                if (rel != null) rel_path = rel;

                // 文件名匹配: 对 basename 求值 node.matches
                // max_fn = 0 时 (search_filename=false) 条件 fn_matched < max_fn
                // 即 0 < 0 = false, 自动跳过, 无需额外检查 search_filename 标志.
                if (fn_matched < max_fn &&
                    query_node.matches (name, case_sensitive)) {
                    if (fn_matched == 0) sb.append ("=== Filename matches ===\n");
                    sb.append ("FILE ").append (rel_path)
                      .append ("  (").append (UIHelpers.format_size (info.get_size ())).append (")\n");
                    fn_matched++;
                }

                // 内容匹配: 逐行求值 (复用 search_in_file 的二进制检测 + 流式读取思路)
                // 同理 max_content = 0 时自动跳过.
                if (content_matched < max_content) {
                    int before = content_matched;
                    search_in_file_multi (
                        file_path, rel_path, query_node, case_sensitive,
                        sb, ref content_matched, max_content
                    );
                    if (content_matched > before) files_with_content_match++;
                }
            }
        }
    }

    private void search_in_file_multi (
        string file_path, string rel_path,
        SearchQueryNode query_node, bool case_sensitive,
        StringBuilder sb, ref int content_matched, int max_content
    ) {
        const int LINE_PREVIEW_LIMIT = 120;
        try {
            var file = File.new_for_path (file_path);
            FileInputStream? fis = null;
            try {
                fis = file.read ();
                // 二进制检测: 前 2048 字节含 \0 即跳过
                var head = fis.read_bytes (2048);
                unowned uint8[] head_data = head.get_data ();
                for (size_t i = 0; i < head_data.length; i++) {
                    if (head_data[i] == 0) return;
                }
                // 流式拼内容
                var content_builder = new StringBuilder ();
                content_builder.append (EncodingHelper.bytes_to_string_safe (head_data, head_data.length));
                const int BUFFER_SIZE = 8192;
                uint8[] buffer = new uint8[BUFFER_SIZE];
                ssize_t n;
                while ((n = fis.read (buffer)) > 0) {
                    content_builder.append (EncodingHelper.bytes_to_string_safe (buffer, (size_t) n));
                }
                string content = EncodingHelper.decode_to_utf8 (content_builder.str.data);
                string[] lines = content.split ("\n");

                bool header_written = false;
                for (int i = 0; i < lines.length && content_matched < max_content; i++) {
                    string line = lines[i];
                    if (line.length == 0) continue;
                    if (query_node.matches (line, case_sensitive)) {
                        if (!header_written) {
                            sb.append ("\n=== Content matches in ").append (rel_path).append (" ===\n");
                            header_written = true;
                        }
                        string preview = line.strip ();
                        if (preview.length > LINE_PREVIEW_LIMIT) {
                            preview = preview.substring (0, LINE_PREVIEW_LIMIT) + "…";
                        }
                        sb.append ("%4d: ".printf (i + 1)).append (preview).append ("\n");
                        content_matched++;
                    }
                }
            } finally {
                if (fis != null) {
                    try { fis.close (); } catch (Error e) {}
                }
            }
        } catch (Error e) {
            // 静默跳过无权限/读取失败的文件, 与 search_in_file 行为一致
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
