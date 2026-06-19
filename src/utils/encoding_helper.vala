public class EncodingHelper {
    public static string decode_to_utf8 (uint8[] data) {
        size_t len = data.length;
        if (len == 0) return "";

        // 检测二进制文件: 扫描前 1024 字节, 遇到 \0 即判定为二进制
        size_t inspect_len = size_t.min (len, 1024);
        for (size_t i = 0; i < inspect_len; i++) {
            if (data[i] == 0) {
                return "[Binary file detected: Text decoding skipped]";
            }
        }

        uint8[] content;
        if (len >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) {
            content = data[3:len];
        } else {
            content = data;
        }

        // 安全拷贝: 添加 \0 终结符, 避免 Vala string 强转越界读取
        uint8[] safe = new uint8[content.length + 1];
        Memory.copy (safe, content, content.length);
        safe[content.length] = 0;
        string raw = (string)safe;

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
        if (data.length <= 1) return "";
        // 添加 \0 终结符, 确保 GLib.convert 不越界
        uint8[] safe = new uint8[data.length + 1];
        Memory.copy (safe, data, data.length);
        safe[data.length] = 0;
        string input = (string)safe;
        try {
            size_t bytes_read, bytes_written;
            string converted = GLib.convert (input, (ssize_t)data.length,
                                             "UTF-8", from_enc,
                                             out bytes_read, out bytes_written);
            if (converted != null && converted.validate ()) {
                return converted;
            }
        } catch (Error e) {
            debug ("Encoding conversion from %s failed: %s", from_enc, e.message);
        }
        return null;
    }
}
