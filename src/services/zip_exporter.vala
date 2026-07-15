using Gee;

// ZIP 导出服务:
//  1. 在用户缓存目录建临时 staging 目录
//  2. 按 work_dir 相对路径复制/链接 items 中的文件
//  3. 把 text 类型 items 聚合为 README.md 的一部分
//  4. 生成完整 README.md (元数据 + 自定义文本 + 文件索引 + 缺失文件)
//  5. 调用外部 `zip` 命令打包
//  6. 无论成功失败都清理临时目录
//
// 设计上走外部 `zip` 命令而不是 libzip 是因为:
//   - 项目已有 git/soffice/pdftoppm 等用 Process.spawn_sync 的先例
//   - 零额外依赖 (系统装 libreoffice 时通常也带了 zip)
//   - 不会因为 libzip 版本差异出 ABI 兼容问题
public class ZipExporter : GLib.Object {

    // 单个文件大小上限 (100 MB), 超过此大小仍会复制但加提示,
    // 防止单个超大文件把 ZIP 卡住
    private const int64 MAX_FILE_SIZE = 100 * 1024 * 1024;

    public static void export_to_zip (
        string zip_path,
        Gee.ArrayList<ItemData> items,
        bool show_header,
        File? work_dir
    ) throws Error {
        var cache_root = Path.build_filename (
            Environment.get_user_cache_dir (), "filecollector", "zip-staging"
        );
        DirUtils.create_with_parents (cache_root, 0755);

        var now = new DateTime.now_local ();
        var staging_dir = Path.build_filename (
            cache_root, "staging-%s".printf (now.format ("%Y%m%d-%H%M%S-%N"))
        );
        DirUtils.create_with_parents (staging_dir, 0755);

        try {
            // 1. 摆文件 + 收集 text 项
            var copied_files = new Gee.ArrayList<CopiedEntry> ();
            var missing_files = new Gee.ArrayList<string> ();
            var text_blocks = new Gee.ArrayList<string> ();
            int64 total_size = 0;

            int file_index = 0;
            for (int i = 0; i < items.size; i++) {
                var data = items.get (i);
                if (data.item_type == "file") {
                    file_index++;
                    var src = File.new_for_path (data.file_path);
                    if (!src.query_exists () || data.is_missing) {
                        missing_files.add (data.file_path);
                        continue;
                    }

                    string rel = compute_relative_path (data.file_path, work_dir);
                    var dest_path = Path.build_filename (staging_dir, rel);
                    var dest_dir = Path.get_dirname (dest_path);
                    DirUtils.create_with_parents (dest_dir, 0755);

                    copy_file (data.file_path, dest_path);

                    int64 sz = 0;
                    try {
                        sz = src.query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE).get_size ();
                    } catch (Error e) { /* 大小拿不到就当 0 */ }
                    total_size += sz;
                    copied_files.add (new CopiedEntry (
                        file_index, rel, sz, detect_kind (data.file_path)
                    ));
                } else {
                    // text / 其他非文件类型 → 作为自定义文本段
                    var c = (data.content ?? "").strip ();
                    if (c.length > 0) text_blocks.add (c);
                }
            }

            // 2. 写 README.md
            var readme_path = Path.build_filename (staging_dir, "README.md");
            write_readme (readme_path, now, work_dir, text_blocks,
                          copied_files, missing_files, total_size);

            // 3. 调用 zip 命令
            run_zip_command (zip_path, staging_dir);

        } finally {
            // 不管成功失败都清掉 staging
            try {
                DirUtils.remove (staging_dir);
            } catch (Error e) {
                debug ("清理 ZIP staging 失败: %s", e.message);
            }
        }
    }

    // ─── helpers ──────────────────────────────────────────────────────

    private static void run_zip_command (string zip_path, string staging_dir) throws Error {
        // 先把目标文件删掉, 避免 zip 往已有文件里追加
        var target = File.new_for_path (zip_path);
        if (target.query_exists ()) {
            try { target.delete (); } catch (Error e) {
                throw new IOError.FAILED (_("Cannot overwrite existing ZIP file: %s").printf (e.message));
            }
        }

        // zip -r <output> <staging_dir>  (默认 deflate 压缩)
        string[] argv = { "zip", "-r", zip_path, "." };
        int status;
        string stdout_buf;
        string stderr_buf;
        Process.spawn_sync (
            staging_dir, argv, null,
            SpawnFlags.SEARCH_PATH,
            null,
            out stdout_buf, out stderr_buf, out status
        );
        if (status != 0) {
            throw new IOError.FAILED (
                "zip command failed (exit code %d): %s".printf (status, stderr_buf.strip ())
            );
        }
    }

    private static string compute_relative_path (string abs_path, File? work_dir) {
        if (work_dir == null) {
            // 没有工作目录: 用去掉前导 / 的全路径, 避免同名冲突
            var p = abs_path;
            while (p.has_prefix ("/")) p = p.substring (1);
            return p;
        }
        var wd = work_dir.get_path ();
        if (wd != null && abs_path.has_prefix (wd + "/")) {
            return abs_path.substring (wd.length + 1);
        }
        // 文件在工作目录外: 用 _external/<basename>-<hash> 隔离
        var basename = Path.get_basename (abs_path);
        return Path.build_filename ("_external", basename);
    }

    private static void copy_file (string src_path, string dest_path) throws Error {
        var src = File.new_for_path (src_path);
        var dest = File.new_for_path (dest_path);
        // 强制覆盖, 不用 FOLLOW (用户期望按字面路径打包, 不跟随符号链接指向的"真"文件)
        try {
            src.copy (dest, FileCopyFlags.OVERWRITE);
        } catch (Error e) {
            // copy 失败时 (比如稀疏文件/特殊文件) 退回读-写方式
            try {
                copy_file_fallback (src, dest);
            } catch (Error e2) {
                throw new IOError.FAILED (
                    _("Failed to copy file (%s → %s): %s").printf (src_path, dest_path, e2.message)
                );
            }
        }
    }

    private static void copy_file_fallback (File src, File dest) throws Error {
        FileInputStream? fis = null;
        FileOutputStream? fos = null;
        try {
            fis = src.read ();
            fos = dest.replace (null, false, FileCreateFlags.NONE);
            uint8[] buf = new uint8[64 * 1024];
            while (true) {
                ssize_t n = fis.read (buf);
                if (n <= 0) break;
                fos.write (buf[0:n]);
            }
        } finally {
            if (fis != null) try { fis.close (); } catch (Error e) { }
            if (fos != null) try { fos.close (); } catch (Error e) { }
        }
    }

    private static string detect_kind (string path) {
        var lower = path.down ();
        if (lower.has_suffix (".py")) return "Python";
        if (lower.has_suffix (".js") || lower.has_suffix (".mjs")) return "JavaScript";
        if (lower.has_suffix (".ts")) return "TypeScript";
        if (lower.has_suffix (".vala")) return "Vala";
        if (lower.has_suffix (".c") || lower.has_suffix (".h")) return "C";
        if (lower.has_suffix (".cpp") || lower.has_suffix (".hpp") || lower.has_suffix (".cc")) return "C++";
        if (lower.has_suffix (".rs")) return "Rust";
        if (lower.has_suffix (".go")) return "Go";
        if (lower.has_suffix (".java")) return "Java";
        if (lower.has_suffix (".md")) return "Markdown";
        if (lower.has_suffix (".json")) return "JSON";
        if (lower.has_suffix (".yaml") || lower.has_suffix (".yml")) return "YAML";
        if (lower.has_suffix (".toml")) return "TOML";
        if (lower.has_suffix (".xml")) return "XML";
        if (lower.has_suffix (".html") || lower.has_suffix (".htm")) return "HTML";
        if (lower.has_suffix (".css")) return "CSS";
        if (lower.has_suffix (".sh")) return "Shell";
        if (lower.has_suffix (".sql")) return "SQL";
        if (lower.has_suffix (".png") || lower.has_suffix (".jpg") ||
            lower.has_suffix (".jpeg") || lower.has_suffix (".webp") ||
            lower.has_suffix (".gif") || lower.has_suffix (".bmp")) return "Image";
        if (lower.has_suffix (".pdf")) return "PDF";
        int dot = lower.last_index_of (".");
        if (dot < 0 || dot == lower.length - 1) return "Text";
        return lower.substring (dot + 1).up ();
    }

    private static string format_size (int64 bytes) {
        if (bytes < 1024) return "%lld B".printf (bytes);
        if (bytes < 1024 * 1024) return "%.1f KB".printf (bytes / 1024.0);
        if (bytes < 1024L * 1024 * 1024) return "%.1f MB".printf (bytes / (1024.0 * 1024));
        return "%.2f GB".printf (bytes / (1024.0 * 1024 * 1024));
    }

    // ─── README 生成 ──────────────────────────────────────────────────

    private static void write_readme (
        string readme_path,
        DateTime now,
        File? work_dir,
        Gee.ArrayList<string> text_blocks,
        Gee.ArrayList<CopiedEntry> copied_files,
        Gee.ArrayList<string> missing_files,
        int64 total_size
    ) throws Error {
        var sb = new StringBuilder ();

        sb.append ("# FileCollector Export\n\n");
        sb.append (_("> Generated by FileCollector at %s\n\n").printf (now.format ("%Y-%m-%d %H:%M:%S")));

        if (work_dir != null && work_dir.get_path () != null) {
            sb.append (_("## Working Directory\n\n`%s`\n\n").printf (work_dir.get_path ()));
        } else {
            sb.append (_("## Working Directory\n\nNo working directory set, files archived by absolute path\n\n"));
        }

        // 用户自定义文本
        if (text_blocks.size > 0) {
            sb.append (_("## Custom Text\n\n"));
            for (int i = 0; i < text_blocks.size; i++) {
                var block = text_blocks.get (i);
                // 如果文本本身不是以 markdown 元素开头, 用引用块包起来, 视觉更清晰
                if (block.has_prefix ("#") || block.has_prefix ("```") || block.has_prefix ("> ")) {
                    sb.append (block);
                } else {
                    sb.append ("> ");
                    sb.append (block.replace ("\n", "\n> "));
                }
                sb.append ("\n\n");
            }
        }

        // 文件索引
        sb.append (_("## File Index\n\n"));
        sb.append (_("Total %d files, total size %s\n\n").printf (copied_files.size, format_size (total_size)));
        if (copied_files.size > 0) {
            sb.append ("| # | Relative Path | Size | Type |\n");
            sb.append ("|---|---------|------|------|\n");
            foreach (var e in copied_files) {
                sb.append ("| %d | `%s` | %s | %s |\n".printf (
                    e.index, e.rel_path, format_size (e.size), e.kind
                ));
            }
            sb.append ("\n");
        }

        // 缺失文件
        if (missing_files.size > 0) {
            sb.append (_("## Missing Files\n\n"));
            sb.append (_("The following files did not exist during export and were skipped:\n\n"));
            foreach (var p in missing_files) {
                sb.append ("- `%s`\n".printf (p));
            }
            sb.append ("\n");
        }

        var os = File.new_for_path (readme_path).replace (null, false, FileCreateFlags.NONE);
        var dos = new DataOutputStream (os);
        try {
            dos.put_string (sb.str);
        } finally {
            try { dos.close (); } catch (Error e) { }
        }
    }

    // 简单的内部记录类型 (Vala 顶层 class 不能在类内嵌套, 用 plain record 风格)
    private class CopiedEntry : GLib.Object {
        public int index;
        public string rel_path;
        public int64 size;
        public string kind;
        public CopiedEntry (int index, string rel_path, int64 size, string kind) {
            this.index = index;
            this.rel_path = rel_path;
            this.size = size;
            this.kind = kind;
        }
    }
}
