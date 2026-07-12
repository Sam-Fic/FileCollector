using Gee;

public class EncodingHelper {
    public static string decode_to_utf8 (uint8[] data) {
        size_t len = data.length;
        if (len == 0) return "";

        // 检测二进制文件: 扫描前 1024 字节, 遇到 \0 即判定为二进制
        size_t inspect_len = size_t.min (len, 1024);
        for (size_t i = 0; i < inspect_len; i++) {
            if (data[i] == 0) {
                return _("[Binary file detected: text decoding skipped]");
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

        // 修复: 当文件按任意字节边界读取时 (例如预览只读前 8KB), 末尾可能残留 1-3 字节
        // 不完整的 UTF-8 多字节序列, 导致 validate() 失败. 此时不应直接落入候选编码表
        // (GBK 会把 UTF-8 字节重新解释为 GBK 2 字节字符, 产生乱码), 而是先回退末尾几个
        // 字节再验证. UTF-8 一个码点最多 4 字节, 实际中文/日韩文 3 字节, 故回退 1-3 字节足够.
        int max_trim = (int) int.min (3, raw.length);
        for (int trim = 1; trim <= max_trim; trim++) {
            string trimmed = raw.substring (0, raw.length - trim);
            if (trimmed.validate ()) {
                return trimmed;
            }
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
