using GLib;
using Json;

public class PreprocessCache : GLib.Object {
    private static Mutex cache_mutex = Mutex ();
    // manifest 静态缓存: 同一进程内多次 new PreprocessCache(work_dir) 复用同一份已解析的
    // manifest, 避免每个 VLM 任务都重新从磁盘读取并解析 manifest.json. 以 manifest_path
    // 为键 (不同 work_dir 互不影响). 共享的是同一个 Json.Object 引用, save/clear 均原地
    // 修改该对象, 因此各实例立即可见彼此的写入, 无需重新读盘.
    private static Mutex manifest_cache_mutex = Mutex ();
    private static Gee.HashMap<string, Json.Object> manifest_cache = new Gee.HashMap<string, Json.Object> ();
    private string work_dir_path;
    private string cache_dir;
    private string manifest_path;
    private string md_dir;
    private Json.Object manifest;

    public PreprocessCache (string work_dir) {
        work_dir_path = work_dir;
        cache_dir = GLib.Path.build_filename (work_dir, ".filecollector_cache");
        manifest_path = GLib.Path.build_filename (cache_dir, "manifest.json");
        md_dir = GLib.Path.build_filename (cache_dir, "markdown");

        DirUtils.create_with_parents (md_dir, 0755);
        manifest = load_manifest_unlocked ();
    }

    /**
     * 完整内容哈希 (SHA256). 作为缓存文件名与 manifest 比对的主键, 格式固定以保证
     * 与磁盘上已有缓存兼容 —— 切勿更改为其它格式, 否则会令所有旧缓存失效.
     * 缓冲区由 8KB 提升到 16KB, 减少大文件读取系统调用次数.
     */
    public static string compute_file_hash (string path) throws Error {
        var file = File.new_for_path (path);
        var stream = file.read ();
        var checksum = new Checksum (ChecksumType.SHA256);
        uint8[] buffer = new uint8[16384];
        ssize_t read_bytes;
        while ((read_bytes = stream.read (buffer)) > 0) {
            checksum.update (buffer, read_bytes);
        }
        return checksum.get_string ();
    }

    /**
     * 轻量指纹: 由文件大小 + mtime 组成, O(1) 不读取文件内容. 用于"文件未改动"的快速
     * 判定 —— 若与 manifest 中记录的 quick 一致, 可直接命中缓存而无需计算 SHA256,
     * 对大文件 (PDF/图片) 的重复加载 (如重新打开项目) 收益显著. 注意: 此指纹仅用于
     * 短路, 不替代 SHA256 主键, 故不会改变磁盘缓存的命名/比对格式.
     */
    public static string compute_file_hash_fast (string path) {
        try {
            var info = File.new_for_path (path).query_info (
                FileAttribute.STANDARD_SIZE + "," + FileAttribute.TIME_MODIFIED,
                FileQueryInfoFlags.NONE);
            return "%lld:%lld".printf (
                (int64) info.get_size (),
                (int64) info.get_modification_time ().tv_sec);
        } catch (Error e) {
            // 取不到元数据时退回完整哈希, 保证仍能走缓存路径
            try {
                return compute_file_hash (path);
            } catch (Error e2) {
                return path; // 极端情况: 以路径兜底, 至少不崩溃
            }
        }
    }

    public string? get_cached_markdown (string abs_path, string current_hash) {
        cache_mutex.lock ();
        string? result = null;
        string rel_path = get_rel_path (abs_path);

        if (manifest.has_member (rel_path)) {
            var entry = manifest.get_object_member (rel_path);
            string cached_hash = entry.get_string_member_with_default ("hash", "");
            if (cached_hash == current_hash) {
                string md_filename = entry.get_string_member_with_default ("md_file", "");
                string md_path = GLib.Path.build_filename (md_dir, md_filename);
                if (FileUtils.test (md_path, FileTest.EXISTS)) {
                    try {
                        FileUtils.get_contents (md_path, out result);
                        result = result.strip ();
                    } catch (Error e) {
                        warning ("Read cache failed: %s", e.message);
                    }
                }
            }
        }
        cache_mutex.unlock ();
        return result;
    }

    /**
     * 轻量缓存命中检查: 仅比对 quick 指纹 (size:mtime), 命中即返回缓存 Markdown,
     * 全程无需读取文件内容计算 SHA256. 适用于文件未改动的高频重载场景 (重新打开项目).
     * 旧版缓存条目未记录 quick 字段时会 miss, 此时调用方回退到 get_cached_markdown
     * (走 SHA256 路径) 以兼容既有磁盘缓存.
     */
    public string? get_cached_markdown_quick (string abs_path, string quick_fp) {
        cache_mutex.lock ();
        string? result = null;
        string rel_path = get_rel_path (abs_path);

        if (manifest.has_member (rel_path)) {
            var entry = manifest.get_object_member (rel_path);
            string cached_quick = entry.get_string_member_with_default ("quick", "");
            if (cached_quick == quick_fp) {
                string md_filename = entry.get_string_member_with_default ("md_file", "");
                string md_path = GLib.Path.build_filename (md_dir, md_filename);
                if (FileUtils.test (md_path, FileTest.EXISTS)) {
                    try {
                        FileUtils.get_contents (md_path, out result);
                        result = result.strip ();
                    } catch (Error e) {
                        warning ("Read cache failed: %s", e.message);
                    }
                }
            }
        }
        cache_mutex.unlock ();
        return result;
    }

    public void save_markdown (string abs_path, string current_hash, string markdown_content) {
        string rel_path = get_rel_path (abs_path);
        string md_filename = current_hash + ".md";
        string md_path = GLib.Path.build_filename (md_dir, md_filename);

        cache_mutex.lock ();
        try {
            FileUtils.set_contents (md_path, markdown_content);
            var entry = new Json.Object ();
            entry.set_string_member ("hash", current_hash);
            // 记录轻量指纹, 供后续 get_cached_markdown_quick 跳过 SHA256 计算
            entry.set_string_member ("quick", compute_file_hash_fast (abs_path));
            entry.set_string_member ("md_file", md_filename);
            entry.set_int_member ("timestamp", new DateTime.now_utc ().to_unix ());
            manifest.set_member (rel_path, AI.SchemaHelper.obj_to_node (entry));
            save_manifest_unlocked ();
        } catch (Error e) {
            warning ("Save cache failed: %s", e.message);
        }
        cache_mutex.unlock ();
    }

    public void invalidate_cache (string abs_path) {
        cache_mutex.lock ();
        string rel_path = get_rel_path (abs_path);

        if (manifest.has_member (rel_path)) {
            var entry = manifest.get_object_member (rel_path);
            string md_filename = entry.get_string_member_with_default ("md_file", "");
            string md_path = GLib.Path.build_filename (md_dir, md_filename);

            if (FileUtils.test (md_path, FileTest.EXISTS)) {
                FileUtils.unlink (md_path);
            }

            manifest.remove_member (rel_path);
            save_manifest_unlocked ();
        }
        cache_mutex.unlock ();
    }

    private string get_rel_path (string abs_path) {
        if (abs_path.has_prefix (work_dir_path)) {
            string rel = abs_path.substring (work_dir_path.length);
            if (rel.has_prefix ("/") || rel.has_prefix ("\\")) rel = rel.substring (1);
            return rel;
        }
        return abs_path;
    }

    private Json.Object load_manifest_unlocked () {
        manifest_cache_mutex.lock ();
        if (manifest_cache.has_key (manifest_path)) {
            var cached = manifest_cache.get (manifest_path);
            manifest_cache_mutex.unlock ();
            return cached;
        }
        manifest_cache_mutex.unlock ();

        Json.Object result;
        if (FileUtils.test (manifest_path, FileTest.EXISTS)) {
            try {
                string content;
                FileUtils.get_contents (manifest_path, out content);
                var parser = new Json.Parser ();
                parser.load_from_data (content);
                if (parser.get_root () != null && parser.get_root ().get_node_type () == Json.NodeType.OBJECT) {
                    result = parser.get_root ().get_object ();
                } else {
                    result = new Json.Object ();
                }
            } catch (Error e) {
                warning ("Load manifest failed: %s", e.message);
                result = new Json.Object ();
            }
        } else {
            result = new Json.Object ();
        }

        // 写入静态缓存共享: 后续 new PreprocessCache 复用同一对象, save/clear 均原地修改
        manifest_cache_mutex.lock ();
        manifest_cache.set (manifest_path, result);
        manifest_cache_mutex.unlock ();
        return result;
    }

    public void clear_all () {
        cache_mutex.lock ();
        try {
            var dir = File.new_for_path (cache_dir);
            if (dir.query_exists ()) {
                delete_recursive (dir);
                DirUtils.create_with_parents (md_dir, 0755);
            }
            // 原地清空共享 manifest 对象 (而非 new 一个新对象), 保证静态缓存引用仍有效,
            // 且其它 PreprocessCache 实例立即可见清空结果. Json.Object 无 remove_all,
            // 故逐成员移除.
            var members = manifest.get_members ();
            foreach (var m in members) {
                manifest.remove_member (m);
            }
            save_manifest_unlocked ();
        } catch (Error e) {
            warning ("Clear cache failed: %s", e.message);
        }
        cache_mutex.unlock ();
    }

    private void delete_recursive (File dir) throws Error {
        var enumerator = dir.enumerate_children (
            FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS
        );
        FileInfo info;
        while ((info = enumerator.next_file ()) != null) {
            var child = dir.get_child (info.get_name ());
            if (info.get_file_type () == FileType.DIRECTORY) {
                delete_recursive (child);
            }
            child.delete ();
        }
    }

    private void save_manifest_unlocked () {
        var gen = new Json.Generator ();
        var node = new Json.Node (Json.NodeType.OBJECT);
        node.set_object (manifest);
        gen.set_root (node);
        gen.pretty = true;
        ConfigManager.atomic_write_json (gen, manifest_path);
    }
}
