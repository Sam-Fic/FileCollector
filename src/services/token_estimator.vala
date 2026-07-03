public class TokenEstimator : GLib.Object {

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
}
