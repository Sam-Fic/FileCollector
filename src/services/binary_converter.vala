public class BinaryConverter : GLib.Object {
    public const int MAX_IMAGE_DIMENSION = 2048;

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
        // 输出到临时目录, 避免 PDF 落在用户工作目录中被文件收集器扫描
        string? tmp_dir = DirUtils.make_tmp ("fc_pdf_XXXXXX");
        if (tmp_dir == null) {
            warning ("Failed to create tmp dir for PDF");
            return null;
        }
        string[] argv = {"soffice", "--headless", "--convert-to", "pdf", "--outdir", tmp_dir, src};
        try {
            int status;
            Process.spawn_sync (null, argv, null, SpawnFlags.SEARCH_PATH, null, null, null, out status);
            if (status == 0) {
                string basename = Path.get_basename (src);
                int dot = basename.last_index_of (".");
                string pdf_name = (dot > 0 ? basename.substring (0, dot) : basename) + ".pdf";
                return Path.build_filename (tmp_dir, pdf_name);
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
            Process.spawn_sync (null, argv, null, SpawnFlags.SEARCH_PATH, null, null, null, out status);
            if (status != 0) {
                warning ("pdftoppm failed with status %d", status);
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
        try {
            var dir = Dir.open (dir_path);
            string? name;
            while ((name = dir.read_name ()) != null) {
                FileUtils.unlink (Path.build_filename (dir_path, name));
            }
            DirUtils.remove (dir_path);
        } catch (Error e) {
            warning ("Failed to cleanup tmp dir: %s", e.message);
        }
    }
}
