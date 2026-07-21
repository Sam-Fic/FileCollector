public class BinaryConverter : GLib.Object {
    public const int MAX_IMAGE_DIMENSION = 2048;

    // 复用临时基目录, 避免每次转换都创建/销毁顶层临时目录.
    // 子目录以互斥锁保护的自增计数器命名, 保证 VLM 队列并发调用时不冲突.
    private static string? temp_base_dir = null;
    private static int task_counter = 0;
    private static Mutex task_counter_lock = Mutex ();

    private static string? get_temp_base () {
        // 用互斥锁保护 check-then-set, 防止 VLM 队列多线程并发初始化
        // 导致前一个 mkdtemp 目录被覆盖而泄漏.
        task_counter_lock.lock ();
        if (temp_base_dir == null) {
            temp_base_dir = DirUtils.make_tmp ("fc_temp_XXXXXX");
        }
        task_counter_lock.unlock ();
        return temp_base_dir;
    }

    private static int next_task_id () {
        task_counter_lock.lock ();
        int n = task_counter++;
        task_counter_lock.unlock ();
        return n;
    }

    // 程序退出时调用, 清理复用的基目录.
    // main() 在 app.run() 返回后调用, 覆盖 GUI 与 CLI 两种退出路径.
    public static void cleanup_temp_dir () {
        if (temp_base_dir != null) {
            cleanup_dir (temp_base_dir);
            temp_base_dir = null;
        }
    }

    public static string? convert_image_to_base64 (string path) {
        try {
            var pixbuf = new Gdk.Pixbuf.from_file (path);
            if (pixbuf == null) return null;

            int orig_w = pixbuf.get_width ();
            int orig_h = pixbuf.get_height ();
            int max_dim = int.max (orig_w, orig_h);

            if (max_dim > MAX_IMAGE_DIMENSION) {
                double scale = (double) MAX_IMAGE_DIMENSION / max_dim;
                int new_w = (int) (orig_w * scale);
                int new_h = (int) (orig_h * scale);
                pixbuf = pixbuf.scale_simple (new_w, new_h, Gdk.InterpType.BILINEAR);
                if (pixbuf == null) return null;
            }

            string format = "png";
            string lower = path.down ();
            if (lower.has_suffix (".jpg") || lower.has_suffix (".jpeg")) {
                format = "jpeg";
            }

            uint8[] buffer;
            pixbuf.save_to_buffer (out buffer, format, null);

            string b64 = GLib.Base64.encode (buffer);
            return b64;

        } catch (Error e) {
            warning ("Image load failed (%s): %s", path, e.message);
            return null;
        }
    }

    public static string get_output_mime_for_image (string path) {
        string lower = path.down ();
        if (lower.has_suffix (".jpg") || lower.has_suffix (".jpeg")) return "image/jpeg";
        return "image/png";
    }

    public static string[]? convert_to_base64_images (string path) {
        string pdf_path = path;
        string lower = path.down ();
        string? tmp_pdf = null;

        if (!lower.has_suffix (".pdf")) {
            tmp_pdf = convert_office_to_pdf (path);
            if (tmp_pdf == null) return null;
            pdf_path = tmp_pdf;
        }

        var result = render_pdf_to_base64_images (pdf_path);

        // 清理临时目录及其中的 PDF, 避免污染用户工作目录
        if (tmp_pdf != null) {
            string tmp_dir = Path.get_dirname (tmp_pdf);
            cleanup_dir (tmp_dir);
        }

        return result;
    }

    private static string? convert_office_to_pdf (string src) {
        // 复用基目录, 在其中创建本次任务的子目录, 避免并发冲突.
        // 子目录名使用互斥锁保护的自增计数器, 保证 VLM 队列多线程下唯一.
        string? tmp_base = get_temp_base ();
        string task_dir;
        if (tmp_base != null) {
            int n = next_task_id ();
            task_dir = Path.build_filename (tmp_base, "pdf_%d".printf (n));
            if (DirUtils.create_with_parents (task_dir, 0700) < 0) {
                // 子目录创建失败时回退到独立 mkdtemp, 保证转换流程能继续
                task_dir = DirUtils.make_tmp ("fc_pdf_XXXXXX");
                if (task_dir == null) {
                    warning ("Failed to create tmp dir for PDF");
                    return null;
                }
            }
        } else {
            // 基目录创建失败时回退到独立 mkdtemp
            task_dir = DirUtils.make_tmp ("fc_pdf_XXXXXX");
            if (task_dir == null) {
                warning ("Failed to create tmp dir for PDF");
                return null;
            }
        }

        string[] argv = {"soffice", "--headless", "--convert-to", "pdf", "--outdir", task_dir, src};
        try {
            int status;
            string stdout_str, stderr_str;
            Process.spawn_sync (null, argv, null, SpawnFlags.SEARCH_PATH, null,
                                out stdout_str, out stderr_str, out status);
            if (status == 0) {
                string basename = Path.get_basename (src);
                int dot = basename.last_index_of (".");
                string pdf_name = (dot > 0 ? basename.substring (0, dot) : basename) + ".pdf";
                return Path.build_filename (task_dir, pdf_name);
            } else {
                // 捕获 soffice 的 stderr 输出, 便于诊断转换失败原因
                // (如文件损坏/格式不支持/LibreOffice 未安装等)
                warning ("LibreOffice conversion failed (status %d): %s",
                         status, (stderr_str ?? "").strip ());
            }
        } catch (Error e) {
            warning ("LibreOffice conversion failed: %s", e.message);
        }
        return null;
    }

    private static string[]? render_pdf_to_base64_images (string pdf_path) {
        string? tmp_dir = DirUtils.make_tmp ("fc_vlm_XXXXXX");
        if (tmp_dir == null) {
            warning ("Failed to create tmp dir for VLM");
            return null;
        }

        string prefix = Path.build_filename (tmp_dir, "page");
        string[] argv = {"pdftoppm", "-png", "-r", "200", pdf_path, prefix};
        try {
            int status;
            string stdout_str, stderr_str;
            // 捕获 stderr: pdftoppm 失败时 (如 PDF 损坏/poppler 未安装) 会把
            // 诊断信息写到 stderr, 原实现丢弃 stderr 只打印退出码, 无法诊断。
            Process.spawn_sync (null, argv, null, SpawnFlags.SEARCH_PATH, null,
                                out stdout_str, out stderr_str, out status);
            if (status != 0) {
                warning ("pdftoppm failed (status %d): %s",
                         status, (stderr_str ?? "").strip ());
                cleanup_dir (tmp_dir);
                return null;
            }
        } catch (Error e) {
            warning ("pdftoppm failed: %s", e.message);
            cleanup_dir (tmp_dir);
            return null;
        }

        var png_files = new Gee.ArrayList<string> ();
        try {
            var dir = Dir.open (tmp_dir);
            string? name;
            while ((name = dir.read_name ()) != null) {
                if (name.has_suffix (".png")) {
                    png_files.add (Path.build_filename (tmp_dir, name));
                }
            }
            png_files.sort ((a, b) => { return strcmp (a, b); });
        } catch (Error e) {
            warning ("Failed to read rendered PNGs: %s", e.message);
            cleanup_dir (tmp_dir);
            return null;
        }

        var result = new string[png_files.size];
        for (int i = 0; i < png_files.size; i++) {
            try {
                uint8[] data;
                FileUtils.get_data (png_files.get (i), out data);
                result[i] = GLib.Base64.encode (data);
            } catch (Error e) {
                warning ("Failed to read PNG %s: %s", png_files.get (i), e.message);
                cleanup_dir (tmp_dir);
                return null;
            }
        }

        cleanup_dir (tmp_dir);
        if (result.length == 0) return null;
        return result;
    }

    private static void cleanup_dir (string dir_path) {
        // 递归清理: 基目录下可能含子目录 (例如复用基目录场景下的 pdf_N/),
        // 单层 FileUtils.unlink 无法删除子目录, 必须先递归清空再 remove.
        try {
            var dir = Dir.open (dir_path);
            string? name;
            while ((name = dir.read_name ()) != null) {
                string child = Path.build_filename (dir_path, name);
                if (FileUtils.test (child, FileTest.IS_DIR)) {
                    cleanup_dir (child);
                } else {
                    FileUtils.unlink (child);
                }
            }
            DirUtils.remove (dir_path);
        } catch (Error e) {
            warning ("Failed to cleanup tmp dir: %s", e.message);
        }
    }
}
