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
    private Json.Object manifest;

    public PreprocessCache (string work_dir) {
        work_dir_path = work_dir;
        cache_dir = GLib.Path.build_filename (work_dir, ".filecollector_cache");
        manifest_path = GLib.Path.build_filename (cache_dir, "manifest.json");

        DirUtils.create_with_parents (cache_dir, 0755);
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
        try {
            var checksum = new Checksum (ChecksumType.SHA256);
            uint8[] buffer = new uint8[16384];
            ssize_t read_bytes;
            while ((read_bytes = stream.read (buffer)) > 0) {
                checksum.update (buffer, read_bytes);
            }
            return checksum.get_string ();
        } finally {
            try { stream.close (); } catch (Error e) {
                debug ("Close hash stream failed: %s", e.message);
            }
        }
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
                string? md_path = resolve_md_path (entry, cached_hash);
                if (md_path != null && FileUtils.test (md_path, FileTest.EXISTS)) {
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

    // 根据 manifest 条目解析 markdown 文件绝对路径: 扁平结构 {hash}/content.md.
    private string? resolve_md_path (Json.Object entry, string fallback_hash) {
        string subdir = entry.get_string_member_with_default ("cache_subdir", "");
        if (subdir != "") {
            string p = GLib.Path.build_filename (cache_dir, subdir, "content.md");
            if (FileUtils.test (p, FileTest.EXISTS)) {
                return p;
            }
        }
        return null;
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
                string? md_path = resolve_md_path (entry, entry.get_string_member_with_default ("hash", ""));
                if (md_path != null && FileUtils.test (md_path, FileTest.EXISTS)) {
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
        // 扁平结构: 以 hash 命名的独立子文件夹 cache_dir/{hash}/, 内含 content.md 与
        // (可选) imgs/; markdown 内相对路径 "imgs/xxx.jpg" 相对 {hash}/ 基点, 可正确
        // 命中图片目录. 无插图时仅有 content.md, 不创建 imgs/.
        string sub_dir = GLib.Path.build_filename (cache_dir, current_hash);
        string md_path = GLib.Path.build_filename (sub_dir, "content.md");

        cache_mutex.lock ();
        try {
            DirUtils.create_with_parents (sub_dir, 0755);
            FileUtils.set_contents (md_path, markdown_content);
            var entry = new Json.Object ();
            entry.set_string_member ("hash", current_hash);
            // 记录轻量指纹, 供后续 get_cached_markdown_quick 跳过 SHA256 计算
            entry.set_string_member ("quick", compute_file_hash_fast (abs_path));
            // 新结构标记: 缓存子文件夹名 (= hash), 读取时据此定位独立目录
            entry.set_string_member ("cache_subdir", current_hash);
            entry.set_boolean_member ("has_images", has_imgs_for (current_hash));
            entry.set_int_member ("timestamp", new DateTime.now_utc ().to_unix ());
            manifest.set_member (rel_path, AI.SchemaHelper.obj_to_node (entry));
            save_manifest_unlocked ();
        } catch (Error e) {
            warning ("Save cache failed: %s", e.message);
        }
        cache_mutex.unlock ();
    }

    // 将缓存图片落盘到 cache_dir/{hash}/imgs/<relpath>, 供 markdown 内相对路径引用.
    // 调用时机: PaddleOCR 解析完成后, 逐张下载并写盘. 同时把 has_images 标记写回 manifest.
    public void save_image (string current_hash, string relpath, uint8[] data) {
        string sub_dir = GLib.Path.build_filename (cache_dir, current_hash);
        // 以 {hash}/ 为基点: relpath = "imgs/xxx.jpg" → {hash}/imgs/xxx.jpg,
        // 与 {hash}/content.md 内 "imgs/xxx.jpg" (相对 {hash}/) 形成一致映射.
        string img_dir = GLib.Path.build_filename (sub_dir, GLib.Path.get_dirname (relpath));
        string img_path = GLib.Path.build_filename (sub_dir, relpath);

        cache_mutex.lock ();
        try {
            DirUtils.create_with_parents (img_dir, 0755);
            FileUtils.set_data (img_path, data);
            mark_has_images (current_hash);
        } catch (Error e) {
            warning ("Save image cache failed: %s", e.message);
        }
        cache_mutex.unlock ();
    }

    private bool has_imgs_for (string current_hash) {
        var imgs_dir = GLib.Path.build_filename (cache_dir, current_hash, "imgs");
        return FileUtils.test (imgs_dir, FileTest.IS_DIR);
    }

    private void mark_has_images (string current_hash) {
        // 遍历 manifest 找到 cache_subdir 匹配当前 hash 的条目, 标记为含图片
        var members = manifest.get_members ();
        foreach (var m in members) {
            var entry = manifest.get_object_member (m);
            if (entry.get_string_member_with_default ("cache_subdir", "") == current_hash) {
                entry.set_boolean_member ("has_images", true);
                save_manifest_unlocked ();
                return;
            }
        }
    }

    // 返回某缓存图片的本地绝对路径 (存在时), 供预览/导出未来使用
    public string? get_cached_image_path (string current_hash, string relpath) {
        string img_path = GLib.Path.build_filename (cache_dir, current_hash, relpath);
        if (FileUtils.test (img_path, FileTest.EXISTS)) {
            return img_path;
        }
        return null;
    }

    public void invalidate_cache (string abs_path) {
        cache_mutex.lock ();
        string rel_path = get_rel_path (abs_path);

        if (manifest.has_member (rel_path)) {
            var entry = manifest.get_object_member (rel_path);
            // 删除整个 hash 子文件夹 (含 content.md 与 imgs/)
            string subdir = entry.get_string_member_with_default ("cache_subdir", "");
            if (subdir != "") {
                string sub_path = GLib.Path.build_filename (cache_dir, subdir);
                if (FileUtils.test (sub_path, FileTest.EXISTS)) {
                    try {
                        delete_recursive (File.new_for_path (sub_path));
                    } catch (Error e) {
                        warning ("Delete cache subdir failed: %s", e.message);
                    }
                }
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
        // 全程持锁: 避免 check-then-set 间隙多个线程同时加载磁盘并各自构造
        // Json.Object, 后写入的会覆盖前者, 导致 manifest 更新丢失。
        manifest_cache_mutex.lock ();
        try {
            if (manifest_cache.has_key (manifest_path)) {
                return manifest_cache.get (manifest_path);
            }

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
            manifest_cache.set (manifest_path, result);
            return result;
        } finally {
            manifest_cache_mutex.unlock ();
        }
    }

    public void clear_all () {
        cache_mutex.lock ();
        try {
            var dir = File.new_for_path (cache_dir);
            if (dir.query_exists ()) {
                delete_recursive (dir);
                DirUtils.create_with_parents (cache_dir, 0755);
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

    /**
     * 判断指定 hash 对应的完整独立缓存子文件夹 ({hash}/) 是否存在.
     * 供 UI 在导出前判断该项是否可导出.
     */
    public bool has_cache (string hash) {
        string sub_path = GLib.Path.build_filename (cache_dir, hash);
        return FileUtils.test (sub_path, FileTest.IS_DIR);
    }

    /**
     * 把完整独立缓存子文件夹 ({hash}/, 扁平结构内含 content.md 与 imgs/) 整体递归拷贝到
     * dest_parent 下, 目标文件夹命名为 folder_name (由调用方基于原二进制文件名 + "_md"
     * 后缀生成, 例如 report.pdf -> report_md). 目标布局:
     *   report_md/content.md
     *   report_md/imgs/...
     * markdown 内相对路径 "imgs/xxx.jpg" 在导出后仍可命中图片.
     *
     * @param hash          缓存子文件夹名 (SHA256)
     * @param dest_parent   用户选定的目标父目录
     * @param folder_name   导出后的目标文件夹名 (不含路径, 不带尾斜杠)
     * @return              实际写入的目标文件夹绝对路径
     */
    public string export_cache_folder (string hash, File dest_parent, string folder_name) throws Error {
        File src = File.new_for_path (GLib.Path.build_filename (cache_dir, hash));
        if (!src.query_exists ()) {
            throw new IOError.NOT_FOUND (_("Cache folder not found for %s").printf (hash));
        }
        // 目标文件夹可能已存在 (同名文件重复导出), 先在父目录下寻找一个不冲突的命名.
        File dest = File.new_for_path (GLib.Path.build_filename (dest_parent.get_path (), folder_name));
        if (dest.query_exists ()) {
            int n = 1;
            while (true) {
                File cand = File.new_for_path (
                    GLib.Path.build_filename (dest_parent.get_path (), "%s_%d".printf (folder_name, n)));
                if (!cand.query_exists ()) { dest = cand; break; }
                n++;
            }
        }
        copy_recursive (src, dest);
        return dest.get_path ();
    }

    // 递归拷贝目录: 在 dest 下重建 src 的完整子结构.
    private void copy_recursive (File src, File dest) throws Error {
        FileInfo info = src.query_info (
            FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        if (info.get_file_type () == FileType.DIRECTORY) {
            DirUtils.create_with_parents (dest.get_path (), 0755);
            var enumerator = src.enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo child_info;
            while ((child_info = enumerator.next_file ()) != null) {
                copy_recursive (src.get_child (child_info.get_name ()),
                                dest.get_child (child_info.get_name ()));
            }
        } else {
            DirUtils.create_with_parents (GLib.Path.get_dirname (dest.get_path ()), 0755);
            src.copy (dest, FileCopyFlags.NONE);
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
