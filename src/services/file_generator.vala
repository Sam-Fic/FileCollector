public class FileGenerator : GLib.Object {
    public static void write_items_to_stream (
        DataOutputStream dis,
        GenericArray<ItemData> items,
        bool use_absolute,
        bool show_header,
        File? work_dir
    ) throws Error {
        if (!use_absolute && show_header && work_dir != null) {
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

                // 以 uint8[] 原始字节流载入, 防止 \0 截断 (FileUtils.get_contents 的
                // string 重载遇到二进制文件会丢失 \0 之后的内容)
                uint8[] raw_contents;
                if (FileUtils.get_data (data.file_path, out raw_contents)) {
                    size_t raw_len = raw_contents.length;

                    // 扫描前 2048 字节判定是否为二进制文件 (含 NULL 字节)
                    bool is_binary = false;
                    size_t check_len = size_t.min (raw_len, 2048);
                    for (size_t j = 0; j < check_len; j++) {
                        if (raw_contents[j] == 0) {
                            is_binary = true;
                            break;
                        }
                    }

                    if (is_binary) {
                        dis.put_string (_("[检测到二进制文件: 已跳过文本内容读取]\n"));
                    } else {
                        // 构建带安全终止符的副本, 防止越界
                        uint8[] safe_buf = new uint8[raw_len + 1];
                        Memory.copy (safe_buf, raw_contents, raw_len);
                        safe_buf[raw_len] = 0;

                        string text_content = (string) safe_buf;
                        if (text_content.validate ()) {
                            dis.put_string (text_content);
                        } else {
                            // 非 UTF-8 异常字节: 柔性容错而非硬性崩坏
                            dis.put_string (text_content.make_valid ());
                        }
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
        var os = file.replace (null, false, FileCreateFlags.NONE);
        var dis = new DataOutputStream (os);
        write_items_to_stream (dis, items, use_absolute, show_header, work_dir);
        dis.close ();
    }

    public static void generate_to_clipboard (
        GenericArray<ItemData> items,
        bool use_absolute,
        bool show_header,
        File? work_dir,
        Gdk.Display display
    ) throws Error {
        var config_dir = Path.build_filename (
            Environment.get_user_config_dir (), "filecollector"
        );
        DirUtils.create_with_parents (config_dir, 0755);

        var file_path = Path.build_filename (config_dir, "merged.txt");
        generate_file (file_path, items, use_absolute, show_header, work_dir);

        var file = File.new_for_path (file_path);
        display.get_clipboard ().set (typeof (File), file);
    }
}
