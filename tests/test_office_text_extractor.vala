// OfficeTextExtractor 单元测试: 内存构造 ZIP fixture, 覆盖
// STORED/DEFLATE 两种压缩、docx/xlsx/pptx/odt 抽取、实体解码、
// 工作表/幻灯片自然排序、EOCD 注释容错、ZIP64/加密/垃圾数据的明确报错。
// PDF 分支依赖外部 pdftotext, 不在此覆盖 (属于集成验证)。
//
// fixture 侧的 ZIP 写入器是测试专用的最小实现: 只写 reader 关心的字段,
// CRC 一律置 0 (OfficeTextExtractor.ZipReader 不校验 CRC)。

using Gee;

static int failures = 0;

static void check (bool cond, string what) {
    if (cond) {
        print ("PASS: %s\n", what);
    } else {
        print ("FAIL: %s\n", what);
        failures++;
    }
}

delegate void TrialFunc () throws Error;

static void run (string name, TrialFunc f) {
    try {
        f ();
    } catch (Error e) {
        print ("FAIL: %s (unexpected throw: %s)\n", name, e.message);
        failures++;
    }
}

// ─── ZIP fixture 写入器 ──────────────────────────────────────────────

class ZipBuilder : GLib.Object {
    // vala 0.56 的 glib vapi 没有 GLib.BytesBuilder: 用 GLib.ByteArray 累积
    private GLib.ByteArray body = new GLib.ByteArray ();
    private uint32 written = 0;
    private Gee.ArrayList<EntryMeta> entries = new Gee.ArrayList<EntryMeta> ();

    private class EntryMeta : GLib.Object {
        public string name;
        public uint16 flags;
        public uint16 method;
        public uint32 comp_size;
        public uint32 uncomp_size;
        public uint32 offset;
    }

    public void add_stored (string name, uint8[] content, uint16 flags = 0) {
        add_entry_raw (name, content, content.length, 0, flags);
    }

    public void add_deflated (string name, uint8[] content) throws Error {
        uint8[] comp = deflate_bytes (content);
        add_entry_raw (name, comp, content.length, 8, 0);
    }

    private void add_entry_raw (string name, uint8[] stored_data,
                                uint32 uncomp_size, uint16 method, uint16 flags) {
        var meta = new EntryMeta ();
        meta.name = name;
        meta.flags = flags;
        meta.method = method;
        meta.comp_size = (uint32) stored_data.length;
        meta.uncomp_size = uncomp_size;
        meta.offset = written;
        entries.add (meta);

        uint8[] nb = name.data;
        u32 (0x04034b50u);
        u16 (20);          // version needed
        u16 (flags);
        u16 (method);
        u16 (0); u16 (0);  // time, date
        u32 (0);           // crc (reader 不校验)
        u32 (meta.comp_size);
        u32 (uncomp_size);
        u16 ((uint16) nb.length);
        u16 (0);           // extra len
        push (nb);
        push (stored_data);
    }

    public uint8[] finish () {
        uint32 cd_offset = written;
        foreach (var m in entries) {
            uint8[] nb = m.name.data;
            u32 (0x02014b50u);
            u16 (20); u16 (20);  // version made by / needed
            u16 (m.flags);
            u16 (m.method);
            u16 (0); u16 (0);
            u32 (0);
            u32 (m.comp_size);
            u32 (m.uncomp_size);
            u16 ((uint16) nb.length);
            u16 (0);             // extra
            u16 (0);             // comment
            u16 (0);             // disk start
            u16 (0);             // internal attrs
            u32 (0);             // external attrs
            u32 (m.offset);
            push (nb);
        }
        uint32 cd_size = written - cd_offset;
        u32 (0x06054b50u);
        u16 (0); u16 (0);        // disk numbers
        u16 ((uint16) entries.size);
        u16 ((uint16) entries.size);
        u32 (cd_size);
        u32 (cd_offset);
        u16 (0);                 // comment len
        return body.steal ();
    }

    private void push (uint8[] piece) {
        body.append (piece);
        written += (uint32) piece.length;
    }

    private void u16 (uint16 v) {
        push (new uint8[] { (uint8) (v & 0xFF), (uint8) ((v >> 8) & 0xFF) });
    }

    private void u32 (uint32 v) {
        push (new uint8[] {
            (uint8) (v & 0xFF), (uint8) ((v >> 8) & 0xFF),
            (uint8) ((v >> 16) & 0xFF), (uint8) ((v >> 24) & 0xFF)
        });
    }

    private static uint8[] deflate_bytes (uint8[] input) throws Error {
        var comp = new GLib.ZlibCompressor (GLib.ZlibCompressorFormat.RAW);
        var out_acc = new GLib.ByteArray ();
        uint8[] out_buf = new uint8[input.length * 2 + 4096];
        size_t bytes_read;
        size_t bytes_written;
        // 第一次: 喂入全部输入 (zlib 在输入耗尽后仍需显式 FLUSH 才输出终止流)
        comp.convert (input, out_buf, GLib.ConverterFlags.NONE, out bytes_read, out bytes_written);
        out_acc.append (out_buf[0 : (int) bytes_written]);
        // 带 FLUSH 循环收尾, 直到 FINISHED
        bool finished = false;
        for (int i = 0; i < 4 && !finished; i++) {
            var res = comp.convert (new uint8[0], out_buf, GLib.ConverterFlags.FLUSH,
                                    out bytes_read, out bytes_written);
            out_acc.append (out_buf[0 : (int) bytes_written]);
            finished = (res == GLib.ConverterResult.FINISHED);
        }
        if (!finished) {
            error ("fixture deflate not finished after flush");
        }
        return out_acc.steal ();
    }
}

// ─── 工具 ────────────────────────────────────────────────────────────

static string write_fixture (string name, uint8[] data) throws Error {
    string dir = DirUtils.make_tmp ("fc_ext_test_XXXXXX");
    string path = GLib.Path.build_filename (dir, name);
    FileUtils.set_data (path, data);
    return path;
}

// ─── 测试用例 ────────────────────────────────────────────────────────

static void test_supports () {
    check (OfficeTextExtractor.supports (".docx"), "supports .docx");
    check (OfficeTextExtractor.supports (".pdf"), "supports .pdf");
    check (OfficeTextExtractor.supports (".odp"), "supports .odp");
    check (!OfficeTextExtractor.supports (".doc"), "rejects legacy .doc");
    check (!OfficeTextExtractor.supports (".txt"), "rejects .txt");
}

static void test_docx_stored () throws Error {
    var xml = """<?xml version="1.0"?><w:document><w:body>
<w:p><w:r><w:t>标题：项目说明</w:t></w:r></w:p>
<w:p><w:r><w:t>带有 &amp; 符号与 &lt;标签&gt; 的文本</w:t></w:r></w:p>
<w:tbl><w:tr><w:tc><w:r><w:t>单元格A</w:t></w:r></w:tc><w:tc><w:r><w:t>单元格B</w:t></w:r></w:tc></w:tr></w:tbl>
<w:p><w:r><w:t>结尾</w:t></w:r></w:p>
</w:body></w:document>""";
    var builder = new ZipBuilder ();
    builder.add_stored ("word/document.xml", xml.data);
    builder.add_stored ("[Content_Types].xml", "<Types/>".data);
    string path = write_fixture ("t.docx", builder.finish ());
    string md = OfficeTextExtractor.extract_markdown (path);
    check (md.contains ("标题：项目说明"), "docx: 中文段落提取");
    check (md.contains ("带有 & 符号与 <标签> 的文本"), "docx: 实体解码");
    check (md.contains ("单元格A\t单元格B"), "docx: 表格单元格按 \\t 分隔");
    check (md.contains ("结尾"), "docx: 尾段保留");
}

static void test_docx_deflate () throws Error {
    var xml = "<w:document><w:body><w:p><w:r><w:t>压缩条目正文</w:t></w:r></w:p></w:body></w:document>";
    var builder = new ZipBuilder ();
    builder.add_deflated ("word/document.xml", xml.data);
    string path = write_fixture ("t2.docx", builder.finish ());
    string md = OfficeTextExtractor.extract_markdown (path);
    check (md.contains ("压缩条目正文"), "docx: DEFLATE 条目可解压");
}

static void test_xlsx () throws Error {
    var sst = """<sst><si><t>名称</t></si><si><t>数值列</t></si><si><t>第二张表</t></si><si><t>最后一张</t></si></sst>""";
    var sheet1 = """<worksheet><sheetData>
<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
<row r="2"><c r="A2"><v>42</v></c><c r="B2"><v>3.14</v></c></row>
</sheetData><rowBreaks/></worksheet>""";
    var sheet2 = "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>2</v></c></row></sheetData></worksheet>";
    var sheet10 = "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>3</v></c></row></sheetData></worksheet>";
    var builder = new ZipBuilder ();
    // 故意乱序加入, 验证 sheet1/sheet2/sheet10 按数字自然排序
    builder.add_stored ("xl/worksheets/sheet10.xml", sheet10.data);
    builder.add_stored ("xl/worksheets/sheet2.xml", sheet2.data);
    builder.add_stored ("xl/worksheets/sheet1.xml", sheet1.data);
    builder.add_stored ("xl/sharedStrings.xml", sst.data);
    string path = write_fixture ("t.xlsx", builder.finish ());
    string md = OfficeTextExtractor.extract_markdown (path);
    check (md.contains ("名称\t数值列"), "xlsx: sharedStrings 引用解析");
    check (md.contains ("42\t3.14"), "xlsx: 数值单元格原样输出");
    check (md.contains ("<rowBreaks>") == false, "xlsx: rowBreaks 未被误当成 row");
    check (md.contains ("第二张表"), "xlsx: 第二张表存在");
    int pos_sheet2 = md.index_of ("第二张表");
    int pos_sheet10 = md.index_of ("最后一张");
    check (pos_sheet2 >= 0 && pos_sheet10 > pos_sheet2, "xlsx: sheet2 在 sheet10 之前 (自然排序)");
}

static void test_pptx () throws Error {
    var s1 = "<p:sld><p:txBody><a:p><a:r><a:t>第一页要点</a:t></a:r></a:p><a:p><a:r><a:t>副要点</a:t></a:r></a:p></p:txBody></p:sld>";
    var s2 = "<p:sld><p:txBody><a:p><a:r><a:t>第二页内容</a:t></a:r></a:p></p:txBody></p:sld>";
    var s10 = "<p:sld><p:txBody><a:p><a:r><a:t>第十页内容</a:t></a:r></a:p></p:txBody></p:sld>";
    var builder = new ZipBuilder ();
    builder.add_stored ("ppt/slides/slide10.xml", s10.data);
    builder.add_stored ("ppt/slides/slide1.xml", s1.data);
    builder.add_stored ("ppt/slides/slide2.xml", s2.data);
    string path = write_fixture ("t.pptx", builder.finish ());
    string md = OfficeTextExtractor.extract_markdown (path);
    check (md.contains ("## Slide 1") && md.contains ("第一页要点"), "pptx: 首页提取");
    check (md.contains ("副要点"), "pptx: 段落边界换行");
    int pos2 = md.index_of ("第二页内容");
    int pos10 = md.index_of ("第十页内容");
    check (pos2 >= 0 && pos10 > pos2, "pptx: slide2 在 slide10 之前 (自然排序)");
}

static void test_odt () throws Error {
    var xml = """<office:document-content><office:body><office:text>
<text:h>一级标题</text:h><text:p>段落一</text:p>
<text:p>段落二<text:line-break/>续行</text:p>
</office:text></office:body></office:document-content>""";
    var builder = new ZipBuilder ();
    builder.add_stored ("content.xml", xml.data);
    string path = write_fixture ("t.odt", builder.finish ());
    string md = OfficeTextExtractor.extract_markdown (path);
    check (md.contains ("一级标题"), "odt: 标题提取");
    check (md.contains ("段落二\n续行"), "odt: line-break 处理");
}

static void test_eocd_trailing_comment () throws Error {
    var builder = new ZipBuilder ();
    builder.add_stored ("word/document.xml",
        "<w:document><w:body><w:p><w:r><w:t>注释容错</w:t></w:r></w:p></w:body></w:document>".data);
    uint8[] zip = builder.finish ();
    // 模拟 ZIP 尾部注释: EOCD 之后附带任意字节
    uint8[] garbage = "this is a zip comment, not part of the archive".data;
    uint8[] padded = new uint8[zip.length + garbage.length];
    for (int i = 0; i < zip.length; i++) padded[i] = zip[i];
    for (int i = 0; i < garbage.length; i++) padded[zip.length + i] = garbage[i];
    string path = write_fixture ("t3.docx", padded);
    string md = OfficeTextExtractor.extract_markdown (path);
    check (md.contains ("注释容错"), "docx: EOCD 尾部注释容错");
}

static void expect_not_supported (string name, uint8[] data) throws Error {
    string path = write_fixture (name, data);
    bool threw = false;
    try {
        OfficeTextExtractor.extract_markdown (path);
    } catch (Error e) {
        threw = (e is IOError.NOT_SUPPORTED);
    }
    check (threw, name + " → NOT_SUPPORTED");
}

static void test_error_paths () throws Error {
    // 完全不是 ZIP 的垃圾数据
    expect_not_supported ("garbage.docx", "definitely not a zip archive........".data);
    // ZIP64: EOCD 中 cd_offset = 0xFFFFFFFF
    expect_not_supported ("zip64.xlsx", new uint8[] {
        0x50, 0x4b, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
        0x01, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00
    });
    // 加密条目: central directory flags bit0 = 1
    var builder = new ZipBuilder ();
    builder.add_stored ("word/document.xml", "<w:document/>".data, 0x0001);
    expect_not_supported ("enc.docx", builder.finish ());
}

static void test_txt_rejected () throws Error {
    string path = write_fixture ("t.txt", "plain text".data);
    bool threw = false;
    try {
        OfficeTextExtractor.extract_markdown (path);
    } catch (Error e) {
        threw = (e is IOError.NOT_SUPPORTED);
    }
    check (threw, "txt → NOT_SUPPORTED (模式外格式由调用方门禁拦截)");
}

int main () {
    run ("supports", () => { test_supports (); });
    run ("docx stored", () => { test_docx_stored (); });
    run ("docx deflate", () => { test_docx_deflate (); });
    run ("xlsx", () => { test_xlsx (); });
    run ("pptx", () => { test_pptx (); });
    run ("odt", () => { test_odt (); });
    run ("eocd comment", () => { test_eocd_trailing_comment (); });
    run ("error paths", () => { test_error_paths (); });
    run ("txt rejected", () => { test_txt_rejected (); });

    print ("\n%s\n", failures == 0 ? "ALL TESTS PASSED" : "%d TEST(S) FAILED".printf (failures));
    return failures == 0 ? 0 : 1;
}
