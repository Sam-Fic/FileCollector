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
                string content;
                size_t len;
                FileUtils.get_contents (data.file_path, out content, out len);
                dis.put_string (content);
            } else {
                dis.put_string (data.content);
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
