public class TokenEstimator : GLib.Object {

    // 文本 token 估算 (见 estimate_tokens_fast)
    public static int estimate_tokens_fast (string? text) {
        if (text == null || text.length == 0) return 0;

        double tokens = 0.0;
        int i = 0;
        int len = text.length;

        while (i < len) {
            unichar c;
            text.get_next_char (ref i, out c);

            if (c.isspace ()) {
                continue;
            }

            if (is_cjk (c)) {
                tokens += 1.0;
            } else if (c.isdigit ()) {
                while (i < len) {
                    unichar next_c;
                    int next_i = i;
                    text.get_next_char (ref next_i, out next_c);
                    if (next_c.isdigit () || next_c == '.' || next_c == ',') {
                        i = next_i;
                    } else {
                        break;
                    }
                }
                tokens += 1.0;
            } else if (is_punctuation (c)) {
                tokens += 0.5;
            } else if (is_accented_latin (c)) {
                tokens += 0.33;
            } else {
                tokens += 0.25;
            }
        }

        return (int) Math.ceil (tokens * 1.05);
    }

    private static bool is_cjk (unichar c) {
        return (c >= 0x4E00 && c <= 0x9FFF) ||
               (c >= 0x3400 && c <= 0x4DBF) ||
               (c >= 0x3040 && c <= 0x30FF) ||
               (c >= 0xAC00 && c <= 0xD7AF) ||
               (c >= 0xF900 && c <= 0xFAFF);
    }

    private static bool is_punctuation (unichar c) {
        return c.ispunct () || c == '`' || c == '~' || c == '|' || c == '\\';
    }

    private static bool is_accented_latin (unichar c) {
        return (c >= 0x00C0 && c <= 0x00FF) ||
               (c >= 0x0100 && c <= 0x017F) ||
               (c >= 0x1E00 && c <= 0x1EFF);
    }

    // 整个文件的 token 估算: 按体积粗略估算 (约 3.5 字节/token), 超过 10MB 不估算.
    public static int estimate_file_tokens_fast (string path) {
        var file = File.new_for_path (path);
        if (!file.query_exists ()) return 0;

        try {
            var info = file.query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
            if (info.get_size () > 10 * 1024 * 1024) return 0;
            return (int) Math.ceil (info.get_size () / 3.5);
        } catch (Error e) {
            return 0;
        }
    }

    // 文件片段 (指定行范围) 的 token 估算: 流式读取目标行范围并直接估算,
    // 不再把整个文件读入内存. 对大文件取小片段的场景 (如在 10MB 文件中取 50 行)
    // 显著降低内存与时间开销, 同时估算更准确 (基于实际内容而非体积按比例缩放).
    public static int estimate_snippet_tokens_fast (string path, int start_line, int end_line) {
        if (start_line <= 0 || end_line < start_line) return 0;
        var file = File.new_for_path (path);
        if (!file.query_exists ()) return 0;

        try {
            var info = file.query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
            // 10MB 上限作为 sanity check, 避免对异常大文件流式遍历过久
            if (info.get_size () > 10 * 1024 * 1024) return 0;

            var sb = new StringBuilder ();
            FileInputStream fis = file.read ();
            try {
                var dis = new DataInputStream (fis);
                int current_line = 1;
                string? line;
                while ((line = dis.read_line ()) != null) {
                    if (current_line > end_line) break;
                    if (current_line >= start_line) {
                        sb.append (line);
                        sb.append_c ('\n');
                    }
                    current_line++;
                }
            } finally {
                try { fis.close (); } catch (Error e) {}
            }
            return estimate_tokens_fast (sb.str);
        } catch (Error e) {
            return 0;
        }
    }
}
