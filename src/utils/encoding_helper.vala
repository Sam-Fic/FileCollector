public class EncodingHelper {
    public static string decode_to_utf8 (uint8[] data) {
        size_t len = data.length;
        if (len == 0) return "";

        uint8[] content;
        if (len >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) {
            content = data[3:len];
        } else {
            content = data;
        }

        content += (uint8)'\0';
        string raw = (string)content;

        if (raw.validate ()) {
            return raw;
        }

        if (len >= 2) {
            if (data[0] == 0xFE && data[1] == 0xFF) {
                return convert_encoding (data[2:len], "UTF-16BE");
            }
            if (data[0] == 0xFF && data[1] == 0xFE) {
                return convert_encoding (data[2:len], "UTF-16LE");
            }
        }

        string[] candidates = {"GBK", "GB2312", "GB18030", "SHIFT_JIS", "EUC-JP", "EUC-KR", "ISO-8859-1", "WINDOWS-1252"};
        foreach (var enc in candidates) {
            string? result = convert_encoding (data, enc);
            if (result != null) return result;
        }

        return raw.make_valid ();
    }

    private static string? convert_encoding (uint8[] data, string from_enc) {
        try {
            string input = (string)data;
            size_t bytes_read, bytes_written;
            string converted = GLib.convert (input, (ssize_t)data.length - 1,
                                             "UTF-8", from_enc,
                                             out bytes_read, out bytes_written);
            if (converted != null && converted.validate ()) {
                return converted;
            }
        } catch (Error e) {
        }
        return null;
    }
}
