using GLib;

// 文件内容读取服务: 统一封装 "size 检查 + 二进制探测 + 分块流式读取" 三段逻辑.
//
// 抽出原因: file_generator.vala 和 multi_format_exporter.vala 原本各自重复实现
// 这三段逻辑 (常量 MAX_FILE_CONTENT_SIZE = 10 MB 重复定义、PEEK_SIZE = 8192
// 二进制探测、8192 字节分块读取). 任何一处发现 bug (如 NULL 字节判定边界、
// file_size 下溢) 都要同步修改两份, 容易遗漏. 此处合并为单一权威实现.
//
// 设计要点:
//   - 通过回调 (ChunkConsumer) 把读取到的字节块交给调用方, 不强制内存模型.
//     file_generator 用回调把数据写入 DataOutputStream (流式, 低内存);
//     multi_format_exporter 用回调解把数据追加到 StringBuilder (整体持有).
//   - 行为与原两份实现一致: BINARY/TOO_LARGE 时回调从未被调用 (不输出半截内容);
//     READ_ERROR 时回调可能已被调用若干次 (半截内容已落盘), 由调用方决定
//     如何处理 (file_generator: 追加错误消息; multi_format_exporter: 丢弃).
//   - error_message 字段为原始异常消息 (未本地化), 由调用方包装 _("[Failed...: %s]").
public class FileContentReader : GLib.Object {

    // 单个文件内容大小上限 (10 MB), 超过此大小跳过内容读取避免 OOM.
    // 与原 file_generator/multi_format_exporter 中的常量保持一致.
    public const int64 MAX_FILE_CONTENT_SIZE = 10 * 1024 * 1024;

    // 二进制探测缓冲区: 扫描前 PEEK_SIZE 字节, 含 NULL 字节视为二进制.
    public const int PEEK_SIZE = 8192;

    // 分块读取缓冲区: peek 之后的剩余内容按 CHUNK_SIZE 字节流式读取.
    public const int CHUNK_SIZE = 8192;

    public enum ReadResult {
        OK,          // 文本内容读取完成 (回调至少被调用一次, 含已 peek 的部分)
        TOO_LARGE,   // file_size > MAX_FILE_CONTENT_SIZE (回调从未被调用)
        BINARY,      // 前 PEEK_SIZE 字节含 NULL 字节 (回调从未被调用)
        READ_ERROR   // query_info 或 read 抛异常 (回调可能已被调用 0..N 次)
    }

    public struct ReadOutcome {
        public ReadResult result;
        public int64 file_size;       // query_info 成功时填实际大小, 失败时为 0
        public string? error_message; // result != OK 时填原始异常消息 (未本地化)
    }

    // 接收一块字节. buf 是函数内部缓冲区, 调用方应在回调内同步消费 (复制或写出),
    // 不要持有引用 (下一次回调可能复用同一缓冲区).
    public delegate void ChunkConsumer (uint8[] buf, size_t len);

    // 流式读取文本文件: 先 query_info 检查大小, 再 peek PEEK_SIZE 字节检测二进制,
    // 最后按 CHUNK_SIZE 分块读取剩余内容, 每块回调 chunk_callback.
    //
    // 调用方应预先检查文件存在性 (query_exists / is_missing), 此函数不重复检查.
    //
    // 返回 ReadOutcome:
    //   - OK: 回调至少被调用一次 (含 peek 的部分); 调用方应保留已写出的数据.
    //   - TOO_LARGE: 回调从未被调用; outcome.file_size 为实际大小, 调用方据此格式化消息.
    //   - BINARY: 回调从未被调用; 调用方应输出 "Binary file detected" 消息.
    //   - READ_ERROR: 回调可能已被调用 0..N 次; outcome.error_message 为异常消息.
    //                file_generator 风格: 已写出半截内容 + 追加错误消息;
    //                multi_format_exporter 风格: 丢弃已收集内容, 仅返回错误.
    public static ReadOutcome read_text_streaming (
        string path,
        ChunkConsumer chunk_callback
    ) {
        ReadOutcome outcome = ReadOutcome ();
        outcome.result = ReadResult.OK;
        outcome.file_size = 0;
        outcome.error_message = null;

        var f = File.new_for_path (path);

        // 1. 查询文件大小
        int64 file_size = 0;
        try {
            var info = f.query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
            file_size = info.get_size ();
        } catch (Error e) {
            outcome.result = ReadResult.READ_ERROR;
            outcome.error_message = e.message;
            return outcome;
        }
        outcome.file_size = file_size;

        // 2. 超过上限直接返回, 不读流
        if (file_size > MAX_FILE_CONTENT_SIZE) {
            outcome.result = ReadResult.TOO_LARGE;
            return outcome;
        }

        // 3. peek PEEK_SIZE 字节, 检测 NULL 字节 (二进制)
        FileInputStream? fis = null;
        try {
            fis = f.read ();
            uint8[] head_buf = new uint8[PEEK_SIZE];
            var peek_bytes = fis.read_bytes (PEEK_SIZE);
            unowned uint8[] peek_data = peek_bytes.get_data ();
            size_t head_read = peek_data.length;
            Memory.copy (head_buf, peek_data, head_read);

            bool is_binary = false;
            for (size_t j = 0; j < head_read; j++) {
                if (head_buf[j] == 0) {
                    is_binary = true;
                    break;
                }
            }
            if (is_binary) {
                outcome.result = ReadResult.BINARY;
                return outcome;
            }

            // 4. 文本: 先回调已 peek 的部分
            chunk_callback (head_buf, head_read);

            // 5. 流式读取剩余部分. 用 int64 避免 head_read > file_size 时无符号下溢.
            int64 remaining = file_size - (int64) head_read;
            if (remaining < 0) remaining = 0;
            uint8[] chunk_buf = new uint8[CHUNK_SIZE];
            while (remaining > 0) {
                size_t to_read = (size_t) size_t.min (CHUNK_SIZE, (size_t) remaining);
                ssize_t n = fis.read (chunk_buf[0:to_read]);
                if (n <= 0) break;
                chunk_callback (chunk_buf, (size_t) n);
                remaining -= n;
            }
        } catch (Error e) {
            outcome.result = ReadResult.READ_ERROR;
            outcome.error_message = e.message;
        } finally {
            if (fis != null) {
                try { fis.close (); } catch (Error e) { debug ("Close failed: %s", e.message); }
            }
        }
        return outcome;
    }
}
