using Gee;

public class FileGenerator : GLib.Object {

    // 单个文件内容大小上限 (10 MB), 超过此大小跳过内容读取
    private const int64 MAX_FILE_CONTENT_SIZE = 10 * 1024 * 1024;

    public static void write_items_to_stream (
        DataOutputStream dis,
        Gee.ArrayList<ItemData> items,
        bool use_absolute,
        bool show_header,
        File? work_dir
    ) throws Error {
        if (show_header && work_dir != null) {
            var header = _("# 工作目录绝对路径: %s\n\n").printf (work_dir.get_path ());
            dis.put_string (header);
        }

        for (int i = 0; i < items.size; i++) {
            if (i > 0) dis.put_string ("\n\n");
            var data = items.get (i);
            if (data.item_type == "file") {
                var f = File.new_for_path (data.file_path);
                if (!f.query_exists () || data.is_missing) {
                    dis.put_string (_("[缺失文件: %s]\n").printf (data.file_path));
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

                if (data.is_snippet ()) {
                    try {
                        // 逐行流式读取：只读所需行区间，避免大文件整读 OOM。
                        FileInputStream? fis = null;
                        DataInputStream? dis_in = null;
                        try {
                            fis = f.read ();
                            dis_in = new DataInputStream (fis);
                            dis_in.set_newline_type (DataStreamNewlineType.ANY);

                            // 规范化行区间：行号从 1 起算，且 start 必须 <= end。
                            // 用户可能填反（start > end）或编辑后行数变动，此处
                            // 自动纠正顺序，避免静默丢失内容。
                            int start = int.max (1, data.start_line);
                            int end = int.max (1, data.end_line);
                            bool swapped = false;
                            if (start > end) {
                                int t = start; start = end; end = t;
                                swapped = true;
                            }

                            // 1-based 行号：需要跳过的行数与需要读取的行数。
                            int skip = start - 1;
                            int want = end - start + 1;
                            for (int ln = 1; ln <= skip; ln++) {
                                if (dis_in.read_line () == null) break;
                            }
                            var sb = new StringBuilder ();
                            for (int ln = 0; ln < want; ln++) {
                                string? line = dis_in.read_line ();
                                if (line == null) break;
                                sb.append (line).append ("\n");
                            }
                            if (swapped) {
                                dis.put_string (_("[提示: 起始行(%d)大于结束行(%d)，已自动交换]\n").printf (data.start_line, data.end_line));
                            }
                            dis.put_string (sb.str);
                        } finally {
                            if (dis_in != null) {
                                try { dis_in.close (); } catch (Error e) { debug ("Close failed: %s", e.message); }
                            }
                        }
                    } catch (Error e) {
                        dis.put_string (_("[读取片段失败: %s]\n").printf (e.message));
                    }
                    continue;
                }

                // 优先使用已预处理好的 Markdown 内容 (二进制文件经 VLM 转换后)
                if (data.preprocessed_content != null && data.preprocessed_content.length > 0) {
                    dis.put_string (data.preprocessed_content);
                    dis.put_string ("\n");
                    continue;
                }

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
                    dis.put_string (_("[文件过大 (%s), 已跳过内容读取]\n").printf (UIHelpers.format_size (file_size)));
                    continue;
                }

                // 流式读取文件内容, 使用 try-finally 确保流关闭
                FileInputStream? fis = null;
                try {
                    fis = f.read ();
                    // 扫描前 8192 字节判定是否为二进制文件 (含 NULL 字节)
                    const int PEEK_SIZE = 8192;
                    uint8[] head_buf = new uint8[PEEK_SIZE];
                    size_t head_read = 0;
                    var peek_bytes = fis.read_bytes (PEEK_SIZE);
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
                        // 流式写入：先写入已 peek 的部分
                        dis.put_string ((string) head_buf[0:head_read]);
                        // 流式读取剩余部分，分块写入
                        size_t remaining = (size_t) file_size - head_read;
                        uint8[] chunk_buf = new uint8[8192];
                        while (remaining > 0) {
                            size_t to_read = size_t.min (8192, remaining);
                            ssize_t n = fis.read (chunk_buf[0:to_read]);
                            if (n <= 0) break;
                            dis.put_string ((string) chunk_buf[0:n]);
                            remaining -= (size_t) n;
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
        Gee.ArrayList<ItemData> items,
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
        Gee.ArrayList<ItemData> items,
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
            var files = new Gee.ArrayList<FileInfo> ();
            while ((info = enumerator.next_file ()) != null) {
                if (info.get_file_type () == FileType.REGULAR &&
                    info.get_name ().has_prefix ("export-") &&
                    info.get_name ().has_suffix (".txt")) {
                    files.add (info);
                }
            }

            if (files.size > 5) {
                files.sort ((a, b) => {
                    uint64 time_a = a.get_attribute_uint64 (FileAttribute.TIME_MODIFIED);
                    uint64 time_b = b.get_attribute_uint64 (FileAttribute.TIME_MODIFIED);
                    if (time_a < time_b) return -1;
                    if (time_a > time_b) return 1;
                    return 0;
                });

                int to_delete = files.size - 5;
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
}
