public class FileGenerator : GLib.Object {

    // 单个文件内容大小上限 (10 MB), 超过此大小跳过内容读取
    private const int64 MAX_FILE_CONTENT_SIZE = 10 * 1024 * 1024;

    public static void write_items_to_stream (
        DataOutputStream dis,
        GenericArray<ItemData> items,
        bool use_absolute,
        bool show_header,
        File? work_dir
    ) throws Error {
        if (show_header && work_dir != null) {
            var header = _("# 工作目录绝对路径: %s\n\n").printf (work_dir.get_path ());
            dis.put_string (header);
        }

        for (int i = 0; i < items.length; i++) {
            if (i > 0) dis.put_string ("\n\n");
            var data = items.get (i);
            if (data.item_type == "file") {
                var f = File.new_for_path (data.file_path);
                if (!f.query_exists ()) {
                    dis.put_string (_("[文件不存在: %s]\n").printf (data.file_path));
                    continue;
                }
                string display;
                if (data.force_absolute || use_absolute || work_dir == null) {
                    display = data.file_path;
                } else {
                    var wd_path = work_dir.get_path () + "/";
                    if (data.file_path.has_prefix (wd_path)) {
                        display = data.file_path.substring (wd_path.length);
                    } else {
                        display = data.file_path;
                    }
                }
                dis.put_string ("%s:\n".printf (display));

                // 检查文件大小, 超过上限则跳过内容读取, 避免 OOM
                int64 file_size = 0;
                try {
                    var info = f.query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                    file_size = info.get_size ();
                } catch (Error e) {
                    dis.put_string (_("[无法获取文件信息: %s]\n").printf (e.message));
                    continue;
                }
                if (file_size > MAX_FILE_CONTENT_SIZE) {
                    dis.put_string (_("[文件过大 (%s), 已跳过内容读取]\n").printf (format_gen_size (file_size)));
                    continue;
                }

                // 流式读取文件内容, 使用 try-finally 确保流关闭
                FileInputStream? fis = null;
                try {
                    fis = f.read ();
                    // 扫描前 2048 字节判定是否为二进制文件 (含 NULL 字节)
                    uint8[] head_buf = new uint8[2048];
                    size_t head_read = 0;
                    var peek_bytes = fis.read_bytes (2048);
                    unowned uint8[] peek_data = peek_bytes.get_data ();
                    head_read = peek_data.length;
                    Memory.copy (head_buf, peek_data, head_read);

                    bool is_binary = false;
                    for (size_t j = 0; j < head_read; j++) {
                        if (head_buf[j] == 0) {
                            is_binary = true;
                            break;
                        }
                    }

                    if (is_binary) {
                        dis.put_string (_("[检测到二进制文件: 已跳过文本内容读取]\n"));
                    } else {
                        // 读取剩余内容: 先写入已 peek 的部分, 再读取剩余
                        var content_buf = new uint8[file_size + 1];
                        Memory.copy (content_buf, head_buf, head_read);
                        size_t total_read = head_read;
                        // 继续读取剩余部分
                        while (total_read < (size_t) file_size) {
                            size_t chunk = size_t.min (8192, (size_t) file_size - total_read);
                            ssize_t n = fis.read (content_buf[total_read:total_read + chunk]);
                            if (n <= 0) break;
                            total_read += (size_t) n;
                        }
                        content_buf[total_read] = 0;

                        string text_content = (string) content_buf;
                        if (text_content.validate ()) {
                            dis.put_string (text_content);
                        } else {
                            dis.put_string (text_content.make_valid ());
                        }
                    }
                } catch (Error e) {
                    dis.put_string (_("[读取文件失败: %s]\n").printf (e.message));
                } finally {
                    if (fis != null) {
                        try { fis.close (); } catch (Error e) { debug ("Close failed: %s", e.message); }
                    }
                }
            } else {
                dis.put_string (data.content ?? "");
            }
        }
    }

    public static void generate_file (
        string file_path,
        GenericArray<ItemData> items,
        bool use_absolute,
        bool show_header,
        File? work_dir
    ) throws Error {
        var file = File.new_for_path (file_path);
        DataOutputStream? dis = null;
        try {
            var os = file.replace (null, false, FileCreateFlags.NONE);
            dis = new DataOutputStream (os);
            write_items_to_stream (dis, items, use_absolute, show_header, work_dir);
        } finally {
            if (dis != null) {
                try { dis.close (); } catch (Error e) { debug ("Close failed: %s", e.message); }
            }
        }
    }

    public static void generate_to_clipboard (
        GenericArray<ItemData> items,
        bool use_absolute,
        bool show_header,
        File? work_dir,
        Gdk.Display display
    ) throws Error {
        var cache_dir_path = Path.build_filename (
            Environment.get_user_cache_dir (), "filecollector", "clipboard"
        );
        DirUtils.create_with_parents (cache_dir_path, 0755);

        cleanup_old_clipboard_files (cache_dir_path);

        var now = new DateTime.now_local ();
        var filename = "export-%s.txt".printf (now.format ("%Y%m%d-%H%M%S"));
        var file_path = Path.build_filename (cache_dir_path, filename);

        generate_file (file_path, items, use_absolute, show_header, work_dir);
        var file = File.new_for_path (file_path);
        display.get_clipboard ().set (typeof (File), file);
    }

    private static void cleanup_old_clipboard_files (string dir_path) {
        var dir = File.new_for_path (dir_path);
        try {
            var enumerator = dir.enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE + "," + FileAttribute.TIME_MODIFIED,
                FileQueryInfoFlags.NONE
            );
            FileInfo info;
            var files = new GenericArray<FileInfo> ();
            while ((info = enumerator.next_file ()) != null) {
                if (info.get_file_type () == FileType.REGULAR &&
                    info.get_name ().has_prefix ("export-") &&
                    info.get_name ().has_suffix (".txt")) {
                    files.add (info);
                }
            }

            if (files.length > 10) {
                files.sort ((a, b) => {
                    uint64 time_a = a.get_attribute_uint64 (FileAttribute.TIME_MODIFIED);
                    uint64 time_b = b.get_attribute_uint64 (FileAttribute.TIME_MODIFIED);
                    if (time_a < time_b) return -1;
                    if (time_a > time_b) return 1;
                    return 0;
                });

                int to_delete = files.length - 10;
                for (int i = 0; i < to_delete; i++) {
                    var f = dir.get_child (files.get (i).get_name ());
                    try {
                        f.delete ();
                    } catch (Error e) {
                        debug ("清理剪贴板缓存文件失败: %s", e.message);
                    }
                }
            }
        } catch (Error e) {
            debug ("枚举剪贴板缓存目录失败: %s", e.message);
        }
    }

    private static string format_gen_size (int64 size) {
        if (size < 1024) return "%lld B".printf (size);
        if (size < 1024 * 1024) return "%.1f KB".printf (size / 1024.0);
        if (size < 1024 * 1024 * 1024) return "%.1f MB".printf (size / 1024.0 / 1024.0);
        return "%.1f GB".printf (size / 1024.0 / 1024.0 / 1024.0);
    }
}
