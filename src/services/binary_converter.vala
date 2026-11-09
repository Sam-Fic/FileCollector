public class BinaryConverter : GLib.Object {
    public const int MAX_IMAGE_DIMENSION = 2048;

    // ─── 捆绑工具解析 ────────────────────────────────────────────────
    // Windows 便携包把 poppler 工具 (pdftoppm/pdftotext) 放在主程序同目录
    // (bin/); 绝对路径优先, 找不到回退裸名 PATH 搜索 (Linux/macOS 现状)。

    // 解析捆绑的外部工具, 找不到返回 null (调用方回退裸名 + SpawnFlags.SEARCH_PATH)。
    public static string? resolve_bundled_tool (string exe_name) {
        string exe = Platform.get_executable_path ();
        if (exe == "." || exe.length == 0) return null;
        var candidate = Path.build_filename (Path.get_dirname (exe), exe_name);
        return FileUtils.test (candidate, FileTest.EXISTS) ? candidate : null;
    }

    // poppler 工具专用 launcher: 中文 PDF 需要 CMap 数据, 运行时把
    // POPPLER_DATADIR 指向便携包内 share/poppler (打包脚本已捆绑)。
    public static SubprocessLauncher new_poppler_launcher () throws Error {
        var launcher = new SubprocessLauncher (
            SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE
        );
        string exe = Platform.get_executable_path ();
        if (exe != "." && exe.length > 0) {
            var data_dir = Path.build_filename (
                Path.get_dirname (exe), "..", "share", "poppler");
            if (FileUtils.test (data_dir, FileTest.IS_DIR)) {
                launcher.setenv ("POPPLER_DATADIR", data_dir, true);
            }
        }
        return launcher;
    }

    // 解析 soffice 可执行文件。探测顺序:
    //   1. 转换器包约定布局: <exe>/../tools/LibreOffice/program/soffice.exe
    //   2. Windows 常见安装路径 (官方安装器默认目录, soffice.exe 不进 PATH)
    //   3. null → 调用方回退裸名 PATH 搜索 (Linux/macOS 现状)
    public static string? resolve_soffice () {
        string exe = Platform.get_executable_path ();
        if (exe != "." && exe.length > 0) {
            var portable = Path.build_filename (
                Path.get_dirname (exe), "..", "tools", "LibreOffice",
                "program", "soffice.exe");
            if (FileUtils.test (portable, FileTest.EXISTS)) return portable;
        }
        string[] roots = {
            GLib.Environment.get_variable ("ProgramFiles"),
            GLib.Environment.get_variable ("ProgramFiles(x86)")
        };
        foreach (unowned string? root in roots) {
            if (root == null || root.length == 0) continue;
            var candidate = Path.build_filename (
                root, "LibreOffice", "program", "soffice.exe");
            if (FileUtils.test (candidate, FileTest.EXISTS)) return candidate;
        }
        return null;
    }

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

    public static string[]? convert_to_base64_images (string path) throws Error {
        string pdf_path = path;
        string lower = path.down ();
        string? tmp_pdf = null;

        if (!lower.has_suffix (".pdf")) {
            // soffice 缺失/转换失败会抛出带指引的错误 (NOT_FOUND/FAILED),
            // 由调用方捕获后作为失败原因展示
            tmp_pdf = convert_office_to_pdf (path);
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

    private static string convert_office_to_pdf (string src) throws Error {
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
                    throw new IOError.FAILED (_("Failed to create tmp dir for PDF conversion"));
                }
            }
        } else {
            // 基目录创建失败时回退到独立 mkdtemp
            task_dir = DirUtils.make_tmp ("fc_pdf_XXXXXX");
            if (task_dir == null) {
                throw new IOError.FAILED (_("Failed to create tmp dir for PDF conversion"));
            }
        }

        try {
            // 转换器包 / 官方安装路径命中 → 绝对路径; 否则裸名 PATH 搜索
            string[] argv = { resolve_soffice () ?? "soffice", "--headless",
                              "--convert-to", "pdf", "--outdir", task_dir, src };
            int status;
            string stdout_str, stderr_str;
            Process.spawn_sync (null, argv, null, SpawnFlags.SEARCH_PATH, null,
                                out stdout_str, out stderr_str, out status);
            if (status != 0) {
                // 捕获 soffice 的 stderr 输出, 便于诊断转换失败原因
                // (如文件损坏/格式不支持/LibreOffice 未安装等)
                throw new IOError.FAILED (_("LibreOffice conversion failed (exit %d): %s").printf (
                    status, (stderr_str ?? "").strip ()));
            }
            string basename = Path.get_basename (src);
            int dot = basename.last_index_of (".");
            string pdf_name = (dot > 0 ? basename.substring (0, dot) : basename) + ".pdf";
            return Path.build_filename (task_dir, pdf_name);
        } catch (SpawnError e) {
            // 裸名搜索也找不到: Windows 上既没有转换器包也没装 LibreOffice。
            // 失败路径必须清理本次的 task_dir, 否则每次尝试都泄漏一个目录。
            cleanup_dir (task_dir);
            throw new IOError.NOT_FOUND (_(
                "LibreOffice is required to convert Office documents. Download the converter package (see README) or install LibreOffice, then retry."));
        } catch (Error e) {
            cleanup_dir (task_dir);
            throw e;
        }
    }

    private static string[]? render_pdf_to_base64_images (string pdf_path) {
        string? tmp_dir = DirUtils.make_tmp ("fc_vlm_XXXXXX");
        if (tmp_dir == null) {
            warning ("Failed to create tmp dir for VLM");
            return null;
        }

        string prefix = Path.build_filename (tmp_dir, "page");
        try {
            // 捕获 stderr: pdftoppm 失败时 (如 PDF 损坏/poppler 未安装) 会把
            // 诊断信息写到 stderr, 原实现丢弃 stderr 只打印退出码, 无法诊断。
            // Windows 便携包用捆绑的 pdftoppm (绝对路径 + POPPLER_DATADIR),
            // 其余平台回退裸名 PATH 搜索。
            string? tool = resolve_bundled_tool ("pdftoppm.exe");
            string[] argv = { tool ?? "pdftoppm", "-png", "-r", "200", pdf_path, prefix };
            var launcher = new_poppler_launcher ();
            var proc = launcher.spawnv (argv);
            string out_str, err_str;
            proc.communicate_utf8 (null, null, out out_str, out err_str);
            if (!proc.get_successful ()) {
                warning (_("pdftoppm failed: %s"), (err_str ?? "").strip ());
                cleanup_dir (tmp_dir);
                return null;
            }
        } catch (Error e) {
            warning (_("pdftoppm failed: %s"), e.message);
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

    /**
     * 解析适合直传给 PaddleOCR 云端 API 的源文件路径。
     *
     * 策略 (按用户确认):
     *   - PDF / 图片: 直接返回原文件路径, is_temp = false (不上传过程中创建临时文件)
     *   - Office 文档 (docx/pptx/xlsx/odt/...): 调用 LibreOffice 先转成 PDF,
     *     返回临时 PDF 路径, is_temp = true. 调用方处理完毕后须调用
     *     cleanup_dir(Path.get_dirname(result)) 清理临时目录.
     *
     * soffice 缺失/转换失败时抛出带指引的错误 (NOT_FOUND/FAILED),
     * 不再返回 null —— 调用方捕获后作为失败原因展示。
     */
    public static string resolve_upload_source (string path, out bool is_temp) throws Error {
        is_temp = false;
        string lower = path.down ();

        // 图片与 PDF: 直接原文件上传
        if (lower.has_suffix (".pdf") ||
            lower.has_suffix (".png") || lower.has_suffix (".jpg") ||
            lower.has_suffix (".jpeg") || lower.has_suffix (".webp") ||
            lower.has_suffix (".bmp") || lower.has_suffix (".tiff") ||
            lower.has_suffix (".tif")) {
            return path;
        }

        // 其余 (Office 等): 转 PDF 后上传
        string tmp_pdf = convert_office_to_pdf (path);
        is_temp = true;
        return tmp_pdf;
    }

    // 公开供调用方清理 resolve_upload_source 生成的临时 PDF 所在目录:
    // cleanup_dir(Path.get_dirname(upload_source)).
    public static void cleanup_dir (string dir_path) {
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
