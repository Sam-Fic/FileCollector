using Gee;

// 纯 Vala 的 Office 文档 / PDF 文本抽取器 (可选的 "文本抽取" 处理模式)。
//
// 与视觉转换 (soffice → pdftoppm → VLM) 互补: 文本模式零网络、无需 VLM 凭据、
// 秒级完成, 但只覆盖文字与表格结构 —— 图表/公式/嵌入图片会丢失, 因此默认
// 模式仍为视觉转换 (ConfigManager.binary_process_mode)。
//
// 覆盖格式:
//   - OOXML (.docx/.xlsx/.pptx): ZIP 容器 + XML, 内置最小 ZIP 读取器解析
//   - ODF (.odt/.ods/.odp): 同为 ZIP + XML
//   - PDF: 调用捆绑的 pdftotext (与 pdftoppm 同属 poppler, Windows 包已捆绑;
//     其余平台回退 PATH 搜索)。抽不出文本 (扫描版) 抛 NOT_SUPPORTED,
//     调用方据此回退视觉/OCR 流程。
//
// ZIP 解析范围: PKZIP 经典布局 (EOCD + central directory + local header),
// 支持 STORED 与 DEFLATE; ZIP64 / 加密条目明确报错而不是静默给出错误结果。
public class OfficeTextExtractor : GLib.Object {

    // 单文件守卫: 防止超大容器把内存吃爆 (文本抽取场景下 50MB 已极宽裕)
    private const int MAX_FILE_SIZE = 50 * 1024 * 1024;
    // 抽出文本的上限, 超出截断 (导出与 token 估算不需要无限正文)
    private const int MAX_TEXT_SIZE = 8 * 1024 * 1024;

    private const string[] SUPPORTED_EXTS = {
        ".docx", ".xlsx", ".pptx", ".odt", ".ods", ".odp", ".pdf"
    };

    // ext 为带前导点的小写扩展名 (与 ItemData.is_allowed_binary_target 口径一致)
    public static bool supports (string ext_lower) {
        foreach (unowned string e in SUPPORTED_EXTS) {
            if (ext_lower == e) return true;
        }
        return false;
    }

    public static string extract_markdown (string path) throws Error {
        var f = File.new_for_path (path);
        var info = f.query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
        if (info.get_size () > MAX_FILE_SIZE) {
            throw new IOError.FAILED (_("File too large for text extraction: %s").printf (
                GLib.format_size ((int64) info.get_size ())));
        }

        string md;
        string lower = path.down ();
        if (lower.has_suffix (".pdf")) {
            md = extract_pdf (path);
        } else {
            uint8[] data;
            FileUtils.get_data (path, out data);
            var zip = new ZipReader (data);
            if (lower.has_suffix (".docx")) {
                md = extract_docx (zip);
            } else if (lower.has_suffix (".xlsx")) {
                md = extract_xlsx (zip);
            } else if (lower.has_suffix (".pptx")) {
                md = extract_pptx (zip);
            } else if (lower.has_suffix (".ods")) {
                md = extract_odf (zip, true);
            } else if (lower.has_suffix (".odt") || lower.has_suffix (".odp")) {
                md = extract_odf (zip, false);
            } else {
                throw new IOError.NOT_SUPPORTED (_("Unsupported format for text extraction"));
            }
        }

        if (md.length > MAX_TEXT_SIZE) {
            md = md.substring (0, MAX_TEXT_SIZE) + "\n\n"
                + _("Text truncated (over %s)").printf (GLib.format_size (MAX_TEXT_SIZE));
        }
        return md;
    }

    // ─── 各格式抽取 ───────────────────────────────────────────────────

    private static string extract_docx (ZipReader zip) throws Error {
        var entry = zip.find ("word/document.xml");
        if (entry == null) {
            throw new IOError.NOT_SUPPORTED (_("Not a valid DOCX (missing word/document.xml)"));
        }
        string xml = bytes_to_utf8 (entry.data);
        // 表格单元格 → \t, 行/段落 → \n, 软换行/制表符保留; 其余标签剥离
        string t = xml.replace ("</w:tc>", "\t")
                      .replace ("</w:tr>", "\n")
                      .replace ("</w:p>", "\n")
                      .replace ("<w:tab/>", "\t")
                      .replace ("<w:br/>", "\n");
        return tidy_text (decode_entities (strip_tags (t)));
    }

    private static string extract_xlsx (ZipReader zip) throws Error {
        var shared = new Gee.ArrayList<string> ();
        var sst = zip.find ("xl/sharedStrings.xml");
        if (sst != null) {
            string xml = bytes_to_utf8 (sst.data);
            foreach (string si in extract_blocks (xml, "si")) {
                // <si> 内可能是单个 <t> 或富文本 <r><t>..</t></r> 多段: 拼接全部 <t>
                var sb2 = new StringBuilder ();
                foreach (string t in extract_tag_contents (si, "t")) {
                    sb2.append (t);
                }
                shared.add (decode_entities (sb2.str));
            }
        }

        // 工作表按文件名中的数字自然排序 (sheet1, sheet2, ... sheet10)
        var sheets = zip.entries_matching ("xl/worksheets/");
        sheets.sort ((a, b) => {
            return num_after (a.name, "sheet") - num_after (b.name, "sheet");
        });
        if (sheets.size == 0) {
            throw new IOError.NOT_SUPPORTED (_("Not a valid XLSX (no worksheet content)"));
        }

        var sb = new StringBuilder ();
        int sheet_idx = 0;
        foreach (var sheet in sheets) {
            sheet_idx++;
            if (sb.len > 0) sb.append ("\n");
            sb.append ("## Sheet ").append (sheet_idx.to_string ()).append ("\n");
            string xml = bytes_to_utf8 (sheet.data);
            foreach (string row in extract_blocks (xml, "row")) {
                var cells = new Gee.ArrayList<string> ();
                foreach (string cell in extract_blocks (row, "c")) {
                    // t="s" → sharedStrings 索引; 其余读 <v> 原值
                    var vs = extract_tag_contents (cell, "v");
                    string val = vs.size > 0 ? vs.get (0) : "";
                    if (val.length > 0 && cell.contains ("t=\"s\"")) {
                        int idx = int.parse (val);
                        val = (idx >= 0 && idx < shared.size) ? shared.get (idx) : "";
                    } else {
                        val = decode_entities (val);
                    }
                    cells.add (val);
                }
                if (cells.size == 0) continue;
                sb.append (string.joinv ("\t", cells.to_array ()));
                sb.append ("\n");
            }
        }
        return sb.str;
    }

    private static string extract_pptx (ZipReader zip) throws Error {
        var slides = zip.entries_matching ("ppt/slides/");
        slides.sort ((a, b) => {
            return num_after (a.name, "slide") - num_after (b.name, "slide");
        });
        if (slides.size == 0) {
            throw new IOError.NOT_SUPPORTED (_("Not a valid PPTX (no slides)"));
        }
        var sb = new StringBuilder ();
        int n = 0;
        foreach (var slide in slides) {
            n++;
            if (sb.len > 0) sb.append ("\n");
            sb.append ("## Slide ").append (n.to_string ()).append ("\n");
            string xml = bytes_to_utf8 (slide.data);
            string t = xml.replace ("</a:tc>", "\t")
                          .replace ("</a:p>", "\n")
                          .replace ("<a:br/>", "\n");
            sb.append (tidy_text (decode_entities (strip_tags (t))));
        }
        return sb.str;
    }

    // ODF 家族共用 content.xml; 电子表格额外处理单元格/行边界
    private static string extract_odf (ZipReader zip, bool spreadsheet) throws Error {
        var entry = zip.find ("content.xml");
        if (entry == null) {
            throw new IOError.NOT_SUPPORTED (_("Not a valid ODF document (missing content.xml)"));
        }
        string xml = bytes_to_utf8 (entry.data);
        string t = xml.replace ("</text:p>", "\n")
                      .replace ("</text:h>", "\n")
                      .replace ("<text:tab/>", "\t")
                      .replace ("<text:line-break/>", "\n");
        if (spreadsheet) {
            t = t.replace ("</table:table-cell>", "\t")
                 .replace ("</table:table-row>", "\n");
        }
        return tidy_text (decode_entities (strip_tags (t)));
    }

    private static string extract_pdf (string path) throws Error {
        string? tool = BinaryConverter.resolve_bundled_tool ("pdftotext.exe");
        string[] argv = { tool ?? "pdftotext", "-layout", "-enc", "UTF-8", path, "-" };
        var launcher = BinaryConverter.new_poppler_launcher ();
        var proc = launcher.spawnv (argv);
        string out_str, err_str;
        proc.communicate_utf8 (null, null, out out_str, out err_str);
        if (!proc.get_successful ()) {
            throw new IOError.FAILED (_("pdftotext failed: %s").printf ((err_str ?? "").strip ()));
        }
        string text = (out_str ?? "").strip ();
        if (text.length == 0) {
            // 扫描版 PDF (纯图): 文本抽取无价值, 调用方据此回退视觉/OCR 流程
            throw new IOError.NOT_SUPPORTED (_("PDF appears to be scanned (no extractable text)"));
        }
        return tidy_text (text);
    }

    // ─── 文本收尾 ─────────────────────────────────────────────────────

    // 连续空行压缩到最多一个, 行尾空白清理 (顺带处理 CRLF 残留)
    private static string tidy_text (string text) {
        var sb = new StringBuilder ();
        int blank = 0;
        foreach (unowned string line in text.split ("\n")) {
            string trimmed = line.strip ();
            if (trimmed.length == 0) {
                blank++;
                if (blank <= 2) sb.append ("\n");
                continue;
            }
            blank = 0;
            sb.append (trimmed);
            sb.append ("\n");
        }
        return sb.str;
    }

    // ─── XML 处理 ─────────────────────────────────────────────────────

    // 剥掉全部标签 (含注释); 边界标签已在调用方 replace 为 \n/\t
    private static string strip_tags (string xml) {
        var sb = new GLib.StringBuilder.sized (xml.length);
        int pos = 0;
        while (pos < xml.length) {
            int lt = xml.index_of ("<", pos);
            if (lt < 0) {
                sb.append (xml.substring (pos));
                break;
            }
            if (lt > pos) sb.append (xml.substring (pos, lt - pos));
            if (lt + 3 < xml.length && xml[lt + 1] == '!' && xml[lt + 2] == '-'
                && xml[lt + 3] == '-') {
                int end = xml.index_of ("-->", lt + 4);
                pos = (end >= 0) ? end + 3 : xml.length;
            } else {
                int gt = xml.index_of (">", lt);
                pos = (gt >= 0) ? gt + 1 : xml.length;
            }
        }
        return sb.str;
    }

    private static string decode_entities (string s) {
        if (!s.contains ("&")) return s;
        var sb = new GLib.StringBuilder.sized (s.length);
        int pos = 0;
        while (pos < s.length) {
            int amp = s.index_of ("&", pos);
            if (amp < 0) {
                sb.append (s.substring (pos));
                break;
            }
            if (amp > pos) sb.append (s.substring (pos, amp - pos));
            int semi = s.index_of (";", amp);
            if (semi < 0 || semi - amp > 12) {
                // 不是实体: 原样输出 '&'
                sb.append ("&");
                pos = amp + 1;
                continue;
            }
            string ent = s.substring (amp + 1, semi - amp - 1);
            string? decoded = null;
            switch (ent) {
                case "amp": decoded = "&"; break;
                case "lt": decoded = "<"; break;
                case "gt": decoded = ">"; break;
                case "quot": decoded = "\""; break;
                case "apos": decoded = "'"; break;
                default:
                    if (ent.has_prefix ("#x") || ent.has_prefix ("#X")) {
                        int v = hex_val (ent.substring (2));
                        decoded = (v > 0 && v <= 0x10FFFF) ? ((unichar) v).to_string () : null;
                    } else if (ent.has_prefix ("#")) {
                        int v = int.parse (ent.substring (1));
                        decoded = (v > 0 && v <= 0x10FFFF) ? ((unichar) v).to_string () : null;
                    }
                    break;
            }
            if (decoded != null) {
                sb.append (decoded);
            } else {
                sb.append (s.substring (amp, semi - amp + 1));
            }
            pos = semi + 1;
        }
        return sb.str;
    }

    private static int hex_val (string hex) {
        if (hex.length == 0 || hex.length > 6) return -1;
        int v = 0;
        for (int i = 0; i < hex.length; i++) {
            char c = hex[i];
            v <<= 4;
            if (c >= '0' && c <= '9') v += c - '0';
            else if (c >= 'a' && c <= 'f') v += c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') v += c - 'A' + 10;
            else return -1;
        }
        return v;
    }

    // 提取 <tag ...> ... </tag> 整块 (含标签); start 精确匹配 "<tag" 且其后是
    // '>' / '/' / 空白, 排除 <rowBreaks> 这类前缀碰撞
    private static Gee.ArrayList<string> extract_blocks (string xml, string tag) {
        var result = new Gee.ArrayList<string> ();
        string open = "<" + tag;
        string close = "</" + tag + ">";
        int pos = 0;
        while (true) {
            int s = find_exact_open (xml, open, pos);
            if (s < 0) break;
            int e = xml.index_of (close, s);
            if (e < 0) break;
            result.add (xml.substring (s, e - s + close.length));
            pos = e + close.length;
        }
        return result;
    }

    // 提取 <tag ...>内容</tag> 的内容 (不含标签); 空元素 <tag/> 记为 ""
    private static Gee.ArrayList<string> extract_tag_contents (string xml, string tag) {
        var result = new Gee.ArrayList<string> ();
        string open = "<" + tag;
        string close = "</" + tag + ">";
        int pos = 0;
        while (true) {
            int s = find_exact_open (xml, open, pos);
            if (s < 0) break;
            int gt = xml.index_of (">", s);
            if (gt < 0) break;
            if (gt > s && xml[gt - 1] == '/') {
                result.add ("");
                pos = gt + 1;
                continue;
            }
            int e = xml.index_of (close, gt);
            if (e < 0) break;
            result.add (xml.substring (gt + 1, e - gt - 1));
            pos = e + close.length;
        }
        return result;
    }

    // 查找 "<tag" 且其后紧跟 '>' / '/' / 空白的出现位置; 找不到返回 -1
    private static int find_exact_open (string xml, string open, int from) {
        int s = xml.index_of (open, from);
        while (s >= 0) {
            char nxt = (s + open.length < xml.length) ? xml[s + open.length] : '\0';
            if (nxt == '>' || nxt == '/' || nxt == ' '
                || nxt == '\t' || nxt == '\n' || nxt == '\r') {
                return s;
            }
            s = xml.index_of (open, s + 1);
        }
        return -1;
    }

    // 文件名中 prefix 之后的连续数字 (sheet1.xml → 1); 无数字排到最后
    private static int num_after (string name, string prefix) {
        int p = name.index_of (prefix);
        if (p < 0) return int.MAX;
        int v = 0;
        bool any = false;
        for (int i = p + prefix.length; i < name.length; i++) {
            char c = name[i];
            if (c >= '0' && c <= '9') {
                v = v * 10 + (c - '0');
                any = true;
            } else if (any) {
                break;
            }
        }
        return any ? v : int.MAX;
    }

    private static string bytes_to_utf8 (uint8[] data) {
        var sb = new GLib.StringBuilder.sized (data.length);
        sb.append_len ((string) data, data.length);
        return sb.str;
    }

    // ─── 最小 ZIP 读取器 ──────────────────────────────────────────────

    private class ZipEntry : GLib.Object {
        public string name;
        public uint8[] data;
        public ZipEntry (string name, uint8[] data) {
            this.name = name;
            this.data = data;
        }
    }

    private class ZipReader : GLib.Object {
        private Gee.HashMap<string, ZipEntry> map =
            new Gee.HashMap<string, ZipEntry> ();

        public ZipReader (uint8[] data) throws Error {
            parse (data);
        }

        public ZipEntry? find (string name) {
            return map[name];
        }

        public Gee.ArrayList<ZipEntry> entries_matching (string prefix) {
            var result = new Gee.ArrayList<ZipEntry> ();
            foreach (var e in map.values) {
                if (e.name.has_prefix (prefix)) result.add (e);
            }
            return result;
        }

        private void parse (uint8[] data) throws Error {
            // 1. 从尾部扫描 EOCD (0x06054b50): 结构 22 字节 + 注释最长 65535
            int eocd = -1;
            int min_scan = int.max (0, data.length - 22 - 65535);
            for (int i = data.length - 22; i >= min_scan; i--) {
                if (le32 (data, i) == 0x06054b50u) {
                    eocd = i;
                    break;
                }
            }
            if (eocd < 0) {
                throw new IOError.NOT_SUPPORTED (_("Not a ZIP container (EOCD not found)"));
            }
            uint16 total = le16 (data, eocd + 10);
            uint32 cd_size = le32 (data, eocd + 12);
            uint32 cd_offset = le32 (data, eocd + 16);
            if (total == 0xFFFFu || cd_offset == 0xFFFFFFFFu || cd_size == 0xFFFFFFFFu) {
                throw new IOError.NOT_SUPPORTED (_("ZIP64 archives are not supported"));
            }
            if ((int) cd_offset + (int) cd_size > data.length) {
                throw corrupted ();
            }
            // 2. 遍历 central directory
            int p = (int) cd_offset;
            for (uint16 i = 0; i < total; i++) {
                if (p + 46 > data.length || le32 (data, p) != 0x02014b50u) {
                    throw corrupted ();
                }
                uint16 flags = le16 (data, p + 8);
                uint16 method = le16 (data, p + 10);
                uint32 comp_size = le32 (data, p + 20);
                uint16 name_len = le16 (data, p + 28);
                uint16 extra_len = le16 (data, p + 30);
                uint16 comment_len = le16 (data, p + 32);
                uint32 local_offset = le32 (data, p + 42);
                if ((flags & 0x1u) != 0) {
                    throw new IOError.NOT_SUPPORTED (_("Encrypted ZIP entries are not supported"));
                }
                if (p + 46 + name_len > data.length) {
                    throw corrupted ();
                }
                string name = bytes_to_utf8 (data[p + 46 : p + 46 + name_len]);
                // 3. local header 定位数据区 (local 与 central 的 name/extra 长度可能不同)
                if (local_offset + 30 > (uint32) data.length
                    || le32 (data, (int) local_offset) != 0x04034b50u) {
                    throw corrupted ();
                }
                uint16 lname_len = le16 (data, (int) local_offset + 26);
                uint16 lextra_len = le16 (data, (int) local_offset + 28);
                int start = (int) local_offset + 30 + lname_len + lextra_len;
                if (start < 0 || start + (int) comp_size > data.length) {
                    throw corrupted ();
                }
                uint8[] content;
                if (method == 0) {
                    content = data[start : start + (int) comp_size];
                } else if (method == 8) {
                    content = inflate (data[start : start + (int) comp_size]);
                } else {
                    throw new IOError.NOT_SUPPORTED (
                        _("Unsupported ZIP compression method %u").printf (method));
                }
                map[name] = new ZipEntry (name, content);
                p += 46 + name_len + extra_len + comment_len;
            }
        }

        private uint8[] inflate (uint8[] raw) throws Error {
            // 注意: vala 0.56 的 glib vapi 没有 GLib.BytesBuilder, 用
            // GLib.ByteArray 累积; ZlibDecompressor 构造参数复用
            // ZlibCompressorFormat 枚举 (0.56 vapi 无独立的
            // ZlibDecompressorFormat 绑定)。
            var mins = new MemoryInputStream.from_data (raw);
            var decomp = new GLib.ZlibDecompressor (GLib.ZlibCompressorFormat.RAW);
            var cis = new GLib.ConverterInputStream (mins, decomp);
            // Gee 泛型不支持数组类型参数, 二进制累积用 GLib.ByteArray
            var out_buf = new GLib.ByteArray ();
            var buf = new uint8[64 * 1024];
            while (true) {
                ssize_t n = cis.read (buf);
                if (n < 0) {
                    throw new IOError.FAILED (_("ZIP deflate decompression failed"));
                }
                if (n == 0) break;
                out_buf.append (buf[0 : (int) n]);
            }
            return out_buf.steal ();
        }

        private static Error corrupted () {
            return new IOError.FAILED (_("Corrupted ZIP container"));
        }

        private static uint16 le16 (uint8[] d, int off) {
            return (uint16) (d[off] | (d[off + 1] << 8));
        }

        private static uint32 le32 (uint8[] d, int off) {
            return ((uint32) d[off]) | ((uint32) d[off + 1] << 8)
                | ((uint32) d[off + 2] << 16) | ((uint32) d[off + 3] << 24);
        }
    }
}
