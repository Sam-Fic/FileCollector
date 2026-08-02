using GLib;
using Json;
using Soup;

/**
 * PaddleOCR 云端 API 客户端 (百度 AI Studio).
 *
 * 与 OpenAI 兼容的同步 chat/completions 路径不同, PaddleOCR 是"提交作业 →
 * 轮询 → 二次下载"的三段式异步协议:
 *   (1) submit_job : 以 multipart/form-data 上传原文件, 返回 jobId
 *   (2) poll_job   : 周期性 GET /jobs/{jobId}, 直到 state == "done" / "failed"
 *   (3) fetch_and_merge: GET 返回的 jsonUrl (预签名, 不带鉴权头), 逐行解析
 *                       JSONL, 把各页 markdown.text 顺序拼接为最终 Markdown.
 *
 * 仅提取 Markdown 文本, 结果中的配图一律忽略 (按需求确认).
 *
 * 取消机制: 轮询在每 500ms 小睡眠后检查 CancelCheck 委托, 若返回 true 则
 * 立即抛出 IOError.CANCELLED, 避免取消队列时线程卡死在 5s 睡眠中.
 */
public class PaddleOCRClient : GLib.Object {
    // 服务端点与模型名写死, 不暴露给用户.
    public const string JOB_URL = "https://paddleocr.aistudio-app.com/api/v2/ocr/jobs";
    public const string MODEL = "PaddleOCR-VL-1.6";

    // 轮询参数: 总间隔 5s, 拆成 10 个 500ms 小睡眠以支持可中断轮询.
    private const uint POLL_INTERVAL_MS = 5000;
    private const uint POLL_SLICE_MS = 500;

    public string token { get; construct; }
    // 单次 HTTP 请求超时 (秒); 同时也是轮询总时长上限 (秒).
    public double timeout { get; construct; }

    private Soup.Session session;

    public PaddleOCRClient (string token, double timeout) {
        GLib.Object (token: token, timeout: timeout > 0 ? timeout : 120.0);
        session = new Soup.Session ();
        session.timeout = (uint) (this.timeout);
    }

    /**
     * 上传文件 → 轮询 → 下载 → 拼接, 返回合并后的 Markdown.
     *
     * @param file_path 已解析好的上传源 (图片/PDF 原文件或 Office 转出的临时 PDF)
     * @param is_cancelled 取消检查回调, CLI 路径传 null 表示不可取消
     * @return 各页 Markdown 顺序拼接后的字符串
     * @throws IOError.CANCELLED 任务被取消
     * @throws IOError.TIMED_OUT 轮询超过总时长上限
     * @throws IOError.FAILED 提交失败 / 作业失败 / 网络错误 / 解析错误
     */
    public string process_file (string file_path, CancelCheck? is_cancelled = null) throws Error {
        string job_id = submit_job (file_path);
        string json_url = poll_job (job_id, is_cancelled);
        return fetch_and_merge (json_url);
    }

    // (1) 提交作业: multipart 上传文件, 返回 jobId
    private string submit_job (string file_path) throws Error {
        string? content_type = guess_mime (file_path);
        uint8[] file_bytes;
        FileUtils.get_data (file_path, out file_bytes);
        if (file_bytes.length == 0) {
            throw new IOError.FAILED (_("Upload file is empty: %s").printf (file_path));
        }

        var multipart = new Soup.Multipart ("multipart/form-data");

        // data={"model": ..., "optionalPayload": "<json.dumps of optional_payload>"}
        var optional = new Json.Object ();
        optional.set_boolean_member ("useDocOrientationClassify", false);
        optional.set_boolean_member ("useDocUnwarping", false);
        optional.set_boolean_member ("useChartRecognition", false);
        var opt_gen = new Json.Generator ();
        opt_gen.set_root (AI.SchemaHelper.obj_to_node (optional));
        string optional_str = opt_gen.to_data (null);

        // append_form_string 配合 append_form_file, 与 Python 示例一一对应
        var data_obj = new Json.Object ();
        data_obj.set_string_member ("model", MODEL);
        var data_gen = new Json.Generator ();
        data_gen.set_root (AI.SchemaHelper.obj_to_node (data_obj));
        // 注意: Python 示例中 data 字段的 optionalPayload 是 JSON 字符串
        multipart.append_form_string ("model", MODEL);
        multipart.append_form_string ("optionalPayload", optional_str);

        multipart.append_form_file (
            "file", GLib.Path.get_basename (file_path), content_type, new Bytes (file_bytes));

        var msg = new Soup.Message.from_multipart (JOB_URL, multipart);
        msg.request_headers.append ("Authorization", "bearer " + token);

        var resp = session.send_and_read (msg, null);
        if (msg.status_code != 200) {
            string detail = "";
            if (resp != null && resp.length > 0) {
                uint8[] raw = resp.get_data ();
                int safe_len = (int) int64.min (resp.length, 2048);
                detail = EncodingHelper.bytes_to_string_safe (raw, (size_t) safe_len);
            }
            throw new IOError.FAILED (
                _("PaddleOCR job submission failed (HTTP %u): %s").printf (msg.status_code, detail));
        }

        var parser = new Json.Parser ();
        parser.load_from_data (EncodingHelper.bytes_to_string_safe (resp.get_data (), resp.length));
        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
            throw new IOError.FAILED (_("Invalid submission response: not a JSON object"));

        var root_obj = root.get_object ();
        var data = root_obj.get_object_member ("data");
        if (data == null) throw new IOError.FAILED (_("Missing 'data' in submission response"));
        string? job_id = data.get_string_member ("jobId");
        if (job_id == null || job_id.length == 0)
            throw new IOError.FAILED (_("Missing 'jobId' in submission response"));

        return job_id;
    }

    // (2) 轮询作业状态, 返回结果 JSON 的下载 URL
    private string poll_job (string job_id, CancelCheck? is_cancelled) throws Error {
        string poll_url = "%s/%s".printf (JOB_URL, job_id);
        double elapsed = 0.0;
        double slice_sec = (double) POLL_SLICE_MS / 1000.0;
        double limit_sec = timeout > 0 ? timeout : 120.0;

        while (true) {
            // 可中断睡眠: 拆成 10×500ms, 每次醒来检查取消
            uint slices = POLL_INTERVAL_MS / POLL_SLICE_MS;
            for (uint i = 0; i < slices; i++) {
                if (is_cancelled != null && is_cancelled ()) {
                    throw new IOError.CANCELLED (_("PaddleOCR job cancelled"));
                }
                Thread.usleep (POLL_SLICE_MS * 1000);
            }
            elapsed += (double) POLL_INTERVAL_MS / 1000.0;
            if (elapsed >= limit_sec) {
                throw new IOError.TIMED_OUT (
                    _("PaddleOCR job polling timed out after %.0f s").printf (limit_sec));
            }

            var msg = new Soup.Message ("GET", poll_url);
            msg.request_headers.append ("Authorization", "bearer " + token);
            var resp = session.send_and_read (msg, null);
            if (msg.status_code != 200) {
                string detail = "";
                if (resp != null && resp.length > 0) {
                    uint8[] raw = resp.get_data ();
                    int safe_len = (int) int64.min (resp.length, 2048);
                    detail = EncodingHelper.bytes_to_string_safe (raw, (size_t) safe_len);
                }
                throw new IOError.FAILED (
                    _("PaddleOCR job polling failed (HTTP %u): %s").printf (msg.status_code, detail));
            }

            var parser = new Json.Parser ();
            parser.load_from_data (EncodingHelper.bytes_to_string_safe (resp.get_data (), resp.length));
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
                throw new IOError.FAILED (_("Invalid polling response: not a JSON object"));
            var root_obj = root.get_object ();
            var data = root_obj.get_object_member ("data");
            if (data == null) throw new IOError.FAILED (_("Missing 'data' in polling response"));

            string? state = data.get_string_member ("state");
            if (state == null) throw new IOError.FAILED (_("Missing 'state' in polling response"));

            if (state == "failed") {
                string? err = data.get_string_member ("errorMsg");
                throw new IOError.FAILED (
                    _("PaddleOCR job failed: %s").printf (err ?? _("unknown error")));
            } else if (state == "done") {
                var result_url = data.get_object_member ("resultUrl");
                if (result_url == null)
                    throw new IOError.FAILED (_("Missing 'resultUrl' in done response"));
                string? json_url = result_url.get_string_member ("jsonUrl");
                if (json_url == null || json_url.length == 0)
                    throw new IOError.FAILED (_("Missing 'jsonUrl' in done response"));
                return json_url;
            }
            // pending / running: 继续轮询
        }
    }

    // (3) 下载 JSONL 并拼接各页 Markdown 文本
    private string fetch_and_merge (string json_url) throws Error {
        // 预签名 URL, 不带鉴权头 (与 Python 示例 requests.get(jsonl_url) 一致)
        var msg = new Soup.Message ("GET", json_url);
        var resp = session.send_and_read (msg, null);
        if (msg.status_code != 200) {
            string detail = "";
            if (resp != null && resp.length > 0) {
                uint8[] raw = resp.get_data ();
                int safe_len = (int) int64.min (resp.length, 2048);
                detail = EncodingHelper.bytes_to_string_safe (raw, (size_t) safe_len);
            }
            throw new IOError.FAILED (
                _("PaddleOCR result download failed (HTTP %u): %s").printf (msg.status_code, detail));
        }

        string jsonl = EncodingHelper.bytes_to_string_safe (resp.get_data (), resp.length);
        var builder = new StringBuilder ();
        bool first = true;

        foreach (string line in jsonl.split ("\n")) {
            string trimmed = line.strip ();
            if (trimmed.length == 0) continue;

            var parser = new Json.Parser ();
            parser.load_from_data (trimmed);
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                warning ("PaddleOCR: skipping invalid JSONL line");
                continue;
            }
            var root_obj = root.get_object ();
            var result = root_obj.get_object_member ("result");
            if (result == null) continue;
            var layout_results = result.get_array_member ("layoutParsingResults");
            if (layout_results == null) continue;

            for (uint i = 0; i < layout_results.get_length (); i++) {
                var item = layout_results.get_object_element (i);
                if (item == null) continue;
                var markdown = item.get_object_member ("markdown");
                if (markdown == null) continue;
                string? text = markdown.get_string_member ("text");
                if (text == null || text.length == 0) continue;

                if (!first) builder.append ("\n\n");
                first = false;
                builder.append (text);
            }
        }

        return builder.str;
    }

    // 根据扩展名猜测上传用的 MIME 类型 (PaddleOCR 接受宽松的 content-type).
    private static string guess_mime (string path) {
        string lower = path.down ();
        if (lower.has_suffix (".pdf")) return "application/pdf";
        if (lower.has_suffix (".jpg") || lower.has_suffix (".jpeg")) return "image/jpeg";
        if (lower.has_suffix (".png")) return "image/png";
        if (lower.has_suffix (".webp")) return "image/webp";
        if (lower.has_suffix (".bmp")) return "image/bmp";
        if (lower.has_suffix (".tiff") || lower.has_suffix (".tif")) return "image/tiff";
        return "application/octet-stream";
    }
}

// 取消检查回调: VLMTaskRunner 注入 VLMQueueManager.check_cancelled(),
// CLI 路径传 null 表示不可取消.
public delegate bool CancelCheck ();
