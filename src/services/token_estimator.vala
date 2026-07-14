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

    // 文件片段 (指定行范围) 的 token 估算: 估算整文件后按行比例缩放.
    public static int estimate_snippet_tokens_fast (string path, int start_line, int end_line) {
        var file = File.new_for_path (path);
        if (!file.query_exists ()) return 0;

        try {
            var info = file.query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
            if (info.get_size () > 10 * 1024 * 1024) return 0;
            int total_lines = 0;
            try {
                uint8[] raw;
                FileUtils.get_data (path, out raw);
                string content = EncodingHelper.decode_to_utf8 (raw);
                total_lines = content.split ("\n").length;
            } catch (Error e) {
                return (int) Math.ceil (info.get_size () / 3.5);
            }
            if (total_lines <= 0) return 0;
            double ratio = (double) (end_line - start_line + 1) / total_lines;
            return (int) Math.ceil (info.get_size () / 3.5 * ratio * 1.05);
        } catch (Error e) {
            return 0;
        }
    }
}
