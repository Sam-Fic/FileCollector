/* AI 助手后端客户端.
 *
 * 与多平台版本 ai_client.py 保持 1:1 行为:
 *  - 通过 OpenAI 兼容 Chat Completions 端点 (OpenAI, Azure OpenAI,
 *    Microsoft Foundry 上的 Fast Context 等特化模型, 任何兼容端点 / 本地 Ollama)
 *  - function-calling schema 1:1 镜像 ai_client.py::TOOL_SCHEMA
 *  - 避免引入额外依赖, 复用 libsoup-3 + glib
 *
 * 默认 HTTPS; 用户若配 HTTP 端点, 自负本地网络安全.
 *
 * 注: GNOME 版的 system prompt 与快照由 ai_panel.vala 维护 (state 形状不同),
 * 这里只暴露 HTTP 客户端 + 工具 schema 工厂 + 工具调用结果数据类.
 */

using GLib;
using Gee;
using Json;
using Soup;

public errordomain AIClientError {
    CONFIG,
    HTTP,
    NETWORK,
    TIMEOUT,
    PROTOCOL,
}


// ─── 工具调用结果数据类 (panel 用来 dispatch) ────────────────────────────

public class AIToolCall : GLib.Object {
    public string id;
    public string name;
    public string arguments_json;

    public AIToolCall (string id_, string n, string args) {
        id = id_;
        name = n;
        arguments_json = args;
    }
}

public class AIChatResult : GLib.Object {
    public string content;
    public Gee.ArrayList<AIToolCall> tool_calls = new Gee.ArrayList<AIToolCall> ();

    public AIChatResult (string c) {
        content = c;
    }
}


// ─── 工具 schema 工厂 (与 ai_client.py::TOOL_SCHEMA 1:1 镜像) ────────────
//
// 全部走 AI.SchemaHelper 命名空间, 提供 Object/Array → Node 的显式转换
// (json-glib 在 Vala 绑定里 Object/Array 不会自动转 Node).

namespace AI.SchemaHelper {

// Json.Object -> Json.Node
public static Json.Node obj_to_node (Json.Object o) {
    if (o == null) return new Json.Node (Json.NodeType.NULL);
    var n = new Json.Node (Json.NodeType.OBJECT);
    n.set_object (o);
    return n;
}

// Json.Array -> Json.Node
public static Json.Node arr_to_node (Json.Array a) {
    if (a == null) return new Json.Node (Json.NodeType.NULL);
    var n = new Json.Node (Json.NodeType.ARRAY);
    n.set_array (a);
    return n;
}

private static Json.Object make_param (string type, Json.Node? props, string[]? required = null) {
    var o = new Json.Object ();
    o.set_string_member ("type", type);
    if (props != null) {
        o.set_member ("properties", props);
    }
    if (required != null && required.length > 0) {
        var r = new Json.Array ();
        foreach (var s in required) r.add_string_element (s);
        o.set_member ("required", SchemaHelper.arr_to_node (r));
    }
    return o;
}

private static Json.Object str_prop (string desc) {
    var o = new Json.Object ();
    o.set_string_member ("type", "string");
    o.set_string_member ("description", desc);
    return o;
}

private static Json.Object int_prop (string desc) {
    var o = new Json.Object ();
    o.set_string_member ("type", "integer");
    o.set_string_member ("description", desc);
    return o;
}

private static Json.Object bool_prop (string desc) {
    var o = new Json.Object ();
    o.set_string_member ("type", "boolean");
    o.set_string_member ("description", desc);
    return o;
}

private static Json.Node path_params () {
    var props = new Json.Object ();
    props.set_member ("path", SchemaHelper.obj_to_node (str_prop ("Absolute path of the new working directory.")));
    return SchemaHelper.obj_to_node (make_param ("object", SchemaHelper.obj_to_node (props), { "path" }));
}

private static Json.Node add_files_params () {
    var inner = new Json.Object ();
    inner.set_string_member ("type", "string");
    var arr = new Json.Object ();
    arr.set_string_member ("type", "array");
    arr.set_member ("items", SchemaHelper.obj_to_node (inner));
    arr.set_string_member ("description", "Array of absolute file paths.");
    var props = new Json.Object ();
    props.set_member ("paths", SchemaHelper.obj_to_node (arr));
    return SchemaHelper.obj_to_node (make_param ("object", SchemaHelper.obj_to_node (props), { "paths" }));
}

private static Json.Node add_text_params () {
    var props = new Json.Object ();
    props.set_member ("text", SchemaHelper.obj_to_node (str_prop ("Text content to insert.")));
    var pos = new Json.Object ();
    pos.set_string_member ("type", "integer");
    pos.set_string_member ("description",
        "Optional 0-based insertion index. Omit to append to the end of the list.");
    props.set_member ("position", SchemaHelper.obj_to_node (pos));
    return SchemaHelper.obj_to_node (make_param ("object", SchemaHelper.obj_to_node (props), { "text" }));
}

private static Json.Node remove_item_params () {
    var props = new Json.Object ();
    props.set_member ("index", SchemaHelper.obj_to_node (int_prop ("0-based index of the item to delete.")));
    return SchemaHelper.obj_to_node (make_param ("object", SchemaHelper.obj_to_node (props), { "index" }));
}

private static Json.Node move_item_params () {
    var props = new Json.Object ();
    props.set_member ("from_index", SchemaHelper.obj_to_node (int_prop ("Source index.")));
    props.set_member ("to_index", SchemaHelper.obj_to_node (int_prop ("Destination index.")));
    return SchemaHelper.obj_to_node (make_param ("object", SchemaHelper.obj_to_node (props), { "from_index", "to_index" }));
}

private static Json.Node empty_params () {
    return SchemaHelper.obj_to_node (make_param ("object", null));
}

private static Json.Node use_abs_params () {
    var props = new Json.Object ();
    props.set_member ("value", SchemaHelper.obj_to_node (bool_prop ("True to use absolute paths.")));
    return SchemaHelper.obj_to_node (make_param ("object", SchemaHelper.obj_to_node (props), { "value" }));
}

private static Json.Node show_header_params () {
    var props = new Json.Object ();
    props.set_member ("value", SchemaHelper.obj_to_node (bool_prop ("True to enable the header")));
    return SchemaHelper.obj_to_node (make_param ("object", SchemaHelper.obj_to_node (props), { "value" }));
}

private static Json.Node list_files_params () {
    var props = new Json.Object ();
    props.set_member ("pattern", SchemaHelper.obj_to_node (str_prop (
        "Optional case-insensitive glob matched against the file name (not the full path). " +
        "Examples: '*ai*', '*.md', 'README*'.")));
    props.set_member ("directory", SchemaHelper.obj_to_node (str_prop (
        "Absolute directory to scan. Defaults to the current work directory.")));
    props.set_member ("max_depth", SchemaHelper.obj_to_node (int_prop (
        "Maximum recursion depth. Defaults to 8.")));
    props.set_member ("max_results", SchemaHelper.obj_to_node (int_prop (
        "Maximum number of paths to return. Defaults to 200.")));
    return SchemaHelper.obj_to_node (make_param ("object", SchemaHelper.obj_to_node (props)));
}

private static Json.Node read_file_params () {
    var props = new Json.Object ();
    props.set_member ("path", SchemaHelper.obj_to_node (str_prop ("Absolute path to the file to read.")));
    props.set_member ("start_line", SchemaHelper.obj_to_node (int_prop (
        "1-based line number to start reading from. Defaults to 1.")));
    props.set_member ("max_lines", SchemaHelper.obj_to_node (int_prop (
        "Maximum number of lines to return. Defaults to 500, hard cap 2000.")));
    props.set_member ("max_bytes", SchemaHelper.obj_to_node (int_prop (
        "Maximum total bytes to return. Defaults to 102400 (100KB), hard cap 524288 (512KB).")));
    return SchemaHelper.obj_to_node (make_param ("object", SchemaHelper.obj_to_node (props), { "path" }));
}

private static Json.Node list_items_params () {
    var props = new Json.Object ();
    props.set_member ("kind", SchemaHelper.obj_to_node (str_prop (
        "Optional filter: 'file' or 'text'. Omit to show everything.")));
    props.set_member ("max_items", SchemaHelper.obj_to_node (int_prop (
        "Maximum number of items to return. Defaults to 100, hard cap 500.")));
    return SchemaHelper.obj_to_node (make_param ("object", SchemaHelper.obj_to_node (props)));
}

private static Json.Node get_git_status_params () {
    return SchemaHelper.obj_to_node (make_param ("object", null));
}

private static Json.Node get_git_diff_params () {
    var props = new Json.Object ();
    props.set_member ("staged", SchemaHelper.obj_to_node (bool_prop (
        "Whether to get the staged diff (true) or unstaged working tree diff (false). Default is false.")));
    return SchemaHelper.obj_to_node (make_param ("object", SchemaHelper.obj_to_node (props)));
}

private static Json.Node get_git_log_params () {
    var props = new Json.Object ();
    props.set_member ("max_count", SchemaHelper.obj_to_node (int_prop (
        "Maximum number of commits to return. Default 10, max 50.")));
    return SchemaHelper.obj_to_node (make_param ("object", SchemaHelper.obj_to_node (props)));
}

private static Json.Node get_git_commit_diff_params () {
    var props = new Json.Object ();
    props.set_member ("commit_hash", SchemaHelper.obj_to_node (str_prop (
        "The hash of the commit to inspect.")));
    return SchemaHelper.obj_to_node (make_param ("object", SchemaHelper.obj_to_node (props), { "commit_hash" }));
}

private static Json.Node add_git_diff_params () {
    var props = new Json.Object ();
    props.set_member ("staged", SchemaHelper.obj_to_node (bool_prop (
        "Whether to add the staged diff (true) or unstaged working tree diff (false). Default is false.")));
    return SchemaHelper.obj_to_node (make_param ("object", SchemaHelper.obj_to_node (props)));
}

private static Json.Node add_git_commit_diff_params () {
    var props = new Json.Object ();
    props.set_member ("commit_hash", SchemaHelper.obj_to_node (str_prop (
        "The hash of the commit whose diff should be added to the list.")));
    return SchemaHelper.obj_to_node (make_param ("object", SchemaHelper.obj_to_node (props), { "commit_hash" }));
}

private static Json.Node add_git_diff_range_params () {
    var props = new Json.Object ();
    props.set_member ("from_hash", SchemaHelper.obj_to_node (str_prop (
        "The starting commit hash (exclusive). Use 'HEAD~N' or a specific hash.")));
    props.set_member ("to_hash", SchemaHelper.obj_to_node (str_prop (
        "The ending commit hash (inclusive). Defaults to 'HEAD'.")));
    return SchemaHelper.obj_to_node (make_param ("object", SchemaHelper.obj_to_node (props), { "from_hash" }));
}

private static Json.Node add_file_snippet_params () {
    var props = new Json.Object ();
    props.set_member ("path", SchemaHelper.obj_to_node (str_prop ("Absolute path to the file.")));
    props.set_member ("start_line", SchemaHelper.obj_to_node (int_prop ("1-based starting line number.")));
    props.set_member ("end_line", SchemaHelper.obj_to_node (int_prop ("1-based ending line number (inclusive).")));
    return SchemaHelper.obj_to_node (make_param ("object", SchemaHelper.obj_to_node (props), { "path", "start_line", "end_line" }));
}

private static Json.Object make_tool (string name, string desc, Json.Node params) {
    var fn = new Json.Object ();
    fn.set_string_member ("name", name);
    fn.set_string_member ("description", desc);
    fn.set_member ("parameters", params);

    var tool = new Json.Object ();
    tool.set_string_member ("type", "function");
    tool.set_member ("function", SchemaHelper.obj_to_node (fn));
    return tool;
}

} // namespace AI.SchemaHelper


// ─── 公开的 schema 入口 (与 ai_client.py::TOOL_SCHEMA 等价) ──────────────

public static Json.Node build_full_tool_schema () {
    var arr = new Json.Array ();
    arr.add_object_element (AI.SchemaHelper.make_tool (
        "set_work_dir",
        "Switch the working directory. This clears the current "
        + "orchestration list and refreshes the file tree.",
        AI.SchemaHelper.path_params ()));
    arr.add_object_element (AI.SchemaHelper.make_tool (
        "add_files",
        "Add one or more files to the orchestration list. Paths must "
        + "be absolute. Only files are added — directories are skipped.",
        AI.SchemaHelper.add_files_params ()));
    arr.add_object_element (AI.SchemaHelper.make_tool (
        "add_text",
        "Insert a custom text block into the orchestration list "
        + "(e.g. a task description, a guiding prompt, or a question). "
        + "By default the block is appended; pass `position` to insert "
        + "at a specific 0-based index instead.",
        AI.SchemaHelper.add_text_params ()));
    arr.add_object_element (AI.SchemaHelper.make_tool (
        "remove_item",
        "Delete an item from the orchestration list by its 0-based index.",
        AI.SchemaHelper.remove_item_params ()));
    arr.add_object_element (AI.SchemaHelper.make_tool (
        "move_item",
        "Move an item in the orchestration list from one 0-based index to another.",
        AI.SchemaHelper.move_item_params ()));
    arr.add_object_element (AI.SchemaHelper.make_tool (
        "clear_items",
        "Empty the entire orchestration list. Does not modify the working directory.",
        AI.SchemaHelper.empty_params ()));
    arr.add_object_element (AI.SchemaHelper.make_tool (
        "set_use_absolute",
        "Toggle path mode: True = export absolute paths, False = export paths "
        + "relative to the working directory.",
        AI.SchemaHelper.use_abs_params ()));
    arr.add_object_element (AI.SchemaHelper.make_tool (
        "set_show_header",
        "Whether to prepend the work-directory header to exported files.",
        AI.SchemaHelper.show_header_params ()));
    arr.add_object_element (AI.SchemaHelper.make_tool (
        "list_files",
        "List files under a directory (defaults to the current work directory). "
        + "Supports an optional case-insensitive glob pattern (e.g. '*ai*.py' or 'README*') "
        + "and an optional max_depth to limit recursion (default 8). Hidden files and "
        + "common build/VCS directories are skipped. Returns up to `max_results` paths "
        + "(default 200). Use this whenever the user gives a vague instruction like "
        + "'add all files about X' or 'find anything related to Y' — explore first, "
        + "then call add_files with the chosen absolute paths in batches. "
        + "NOTE: a list result is a CANDIDATE set, not a final answer. Filenames alone "
        + "are often misleading; the only reliable way to confirm relevance is to "
        + "read_file each candidate's first ~20-40 lines (or its module-level docstring / "
        + "config schema) before adding. When a file's name is ambiguous or several "
        + "candidates share similar names, you MUST call read_file — never judge by name alone.",
        AI.SchemaHelper.list_files_params ()));
    arr.add_object_element (AI.SchemaHelper.make_tool (
        "read_file",
        "Read the text content of a file (with a 1-based line-numbered view). "
        + "Use this to inspect a file's contents — for example to verify what a "
        + "config or source file actually contains before deciding whether to add it. "
        + "Binary files (containing NUL bytes) are detected and rejected with a clear "
        + "message. For large files, content is truncated to `max_bytes` (default "
        + "100KB, hard cap 512KB) and `max_lines` (default 500). Use `start_line` "
        + "(1-based) and `max_lines` to read a specific region in chunks. "
        + "TYPICAL USE: after list_files, call read_file with max_lines=30-50 to peek "
        + "at the top of each candidate (docstring / imports / class names) so you "
        + "don't add the wrong file based on its name.",
        AI.SchemaHelper.read_file_params ()));
    arr.add_object_element (AI.SchemaHelper.make_tool (
        "list_items",
        "Inspect the current orchestration list (the items the user will export). "
        + "Returns a numbered view of all items — both file entries (with their "
        + "absolute path) and text blocks (with a content preview). Use this to "
        + "verify the result of add_files / add_text / move_item / remove_item "
        + "before reporting back to the user. If `kind` is provided, only that "
        + "type is shown: 'file' or 'text'. Truncated to `max_items` (default 100).",
        AI.SchemaHelper.list_items_params ()));
    arr.add_object_element (AI.SchemaHelper.make_tool (
        "get_git_status",
        "Get the current Git working tree status (modified, added, untracked files). "
        + "Use this to understand what the user is currently working on before selecting files.",
        AI.SchemaHelper.get_git_status_params ()));
    arr.add_object_element (AI.SchemaHelper.make_tool (
        "get_git_diff",
        "Get the Git diff of the working tree or staged area. "
        + "Use this to read the exact code changes and decide which files are relevant to the context.",
        AI.SchemaHelper.get_git_diff_params ()));
    arr.add_object_element (AI.SchemaHelper.make_tool (
        "get_git_log",
        "List recent Git commits in reverse chronological order (newest first). "
        + "Each entry includes: short hash, author, date (YYYY-MM-DD), and commit message. "
        + "Use this to find commit hashes for range operations or to understand recent history.",
        AI.SchemaHelper.get_git_log_params ()));
    arr.add_object_element (AI.SchemaHelper.make_tool (
        "get_git_commit_diff",
        "Get the diff of a specific Git commit by its hash.",
        AI.SchemaHelper.get_git_commit_diff_params ()));
    arr.add_object_element (AI.SchemaHelper.make_tool (
        "add_git_diff",
        "Inject the current Git working tree or staged diff directly into the orchestration list as a Markdown code block. "
        + "Use this instead of reading the diff and using add_text, to save tokens and avoid API limits.",
        AI.SchemaHelper.add_git_diff_params ()));
    arr.add_object_element (AI.SchemaHelper.make_tool (
        "add_git_commit_diff",
        "Inject the diff of a specific Git commit directly into the orchestration list. "
        + "Requires the commit hash. Use this to export historical changes without passing the diff text through the LLM.",
        AI.SchemaHelper.add_git_commit_diff_params ()));
    arr.add_object_element (AI.SchemaHelper.make_tool (
        "add_git_diff_range",
        "Inject the combined diff of a range of commits (from_hash..to_hash) directly into the orchestration list. "
        + "Use this when the user asks to 'add all diffs from commit X to Y' or 'export changes since commit X'. "
        + "This is much more efficient than calling add_git_commit_diff for each commit individually.",
        AI.SchemaHelper.add_git_diff_range_params ()));
    arr.add_object_element (AI.SchemaHelper.make_tool (
        "add_file_snippet",
        "Add a specific line range (snippet) of a file to the orchestration list. "
        + "Use this after `read_file` to extract only the relevant function, class, or code block, "
        + "saving massive amounts of tokens compared to adding the whole file.",
        AI.SchemaHelper.add_file_snippet_params ()));
    return AI.SchemaHelper.arr_to_node (arr);
}


// ─── HTTP 客户端 (与 ai_client.py::AIClient.chat 行为一致) ───────────────

public class AIClient : GLib.Object {
    public string base_url { get; construct; }
    public string api_key { get; construct; }
    public string model { get; construct; }
    public double timeout { get; construct; default = 60.0; }

    private Soup.Session session;

    public AIClient (string base_url_, string api_key_, string model_, double timeout_ = 60.0) {
        GLib.Object (
            base_url: (base_url_ ?? "").strip (),
            api_key: api_key_ ?? "",
            model: model_ ?? "",
            timeout: double.max (5.0, timeout_)
        );
        session = new Soup.Session ();
        session.timeout = (uint) timeout;
    }

    // 同步 chat: 在 worker 线程中调用, 完成后由 main loop 把结果发回主线程.
    public AIChatResult chat (Gee.ArrayList<Json.Node> messages, Json.Node? tools_node = null,
            GLib.Cancellable? cancellable = null)
            throws AIClientError {
        if (base_url == "")
            throw new AIClientError.CONFIG (_("API Base URL not configured. Please fill it in Settings → AI Settings."));
        if (api_key == "")
            throw new AIClientError.CONFIG (_("API Key not configured. Please fill it in Settings → AI Settings."));
        if (model == "")
            throw new AIClientError.CONFIG (_("Model Name not configured. Please fill it in Settings → AI Settings."));

        var payload = new Json.Object ();
        payload.set_string_member ("model", model);

        var msgs_arr = new Json.Array ();
        foreach (var m in messages) msgs_arr.add_element (m);
        payload.set_member ("messages", AI.SchemaHelper.arr_to_node (msgs_arr));

        if (tools_node != null) {
            payload.set_member ("tools", tools_node);
            payload.set_string_member ("tool_choice", "auto");
        }

        var gen = new Json.Generator ();
        var root_node = AI.SchemaHelper.obj_to_node (payload);
        gen.set_root (root_node);
        gen.pretty = false;
        size_t body_len = 0;
        string body = gen.to_data (out body_len);

        string url = base_url.has_suffix ("/") ? base_url + "chat/completions"
                                               : base_url + "/chat/completions";

        var msg = new Soup.Message ("POST", url);
        uint8[] body_buf = new uint8[body_len];
        GLib.Memory.copy (body_buf, body, body_len);
        var body_bytes = new Bytes (body_buf);
        msg.set_request_body_from_bytes ("application/json", body_bytes);
        msg.request_headers.append ("Content-Type", "application/json");
        msg.request_headers.append ("Authorization", "Bearer " + api_key);

        Bytes? resp_bytes = null;
        try {
            // 同步发送 (libsoup-3 的 sync API); worker 线程中执行, 不阻塞主线程.
            resp_bytes = session.send_and_read (msg, cancellable);
        } catch (Error e) {
            throw new AIClientError.NETWORK (_("Network error: ") + e.message);
        }

        uint status = msg.status_code;

        if (status >= 400) {
            string detail = "";
            if (resp_bytes != null && resp_bytes.length > 0) {
                try {
                    uint8[] raw = resp_bytes.get_data ();
                    int safe_len = (int) int64.min (resp_bytes.length, 4096);
                    detail = ((string) raw).substring (0, safe_len);
                } catch (Error e) { warning ("Failed to read error response body: %s", e.message); }
                if (detail.length > 500) detail = detail.substring (0, 500);
            }
            throw new AIClientError.HTTP (
                _("HTTP %u %s: %s").printf (status, Soup.status_get_phrase (status), detail).strip ());
        }

        if (resp_bytes == null || resp_bytes.length == 0) {
            throw new AIClientError.PROTOCOL (_("Empty response"));
        }

        return parse_response_bytes (resp_bytes.get_data ());
    }

    // 异步非阻塞版本: 接收预构建的 JSON payload, 通过 Cancellable 支持即时取消.
    // 适用于主线程或需要协程化调用的场景; 现有 worker 线程仍可使用同步 chat().
    // 可被窗口关闭或用户点击"停止"时通过 cancellable 即时打断, 绝不卡死 UI.
    public async string chat_async (string json_payload, GLib.Cancellable? cancellable) throws GLib.Error {
        string url = base_url.has_suffix ("/") ? base_url + "chat/completions"
                                              : base_url + "/chat/completions";
        var msg = new Soup.Message ("POST", url);
        msg.request_headers.append ("Authorization", "Bearer " + api_key);
        msg.request_headers.append ("Content-Type", "application/json");
        msg.set_request_body_from_bytes ("application/json", new Bytes (json_payload.data));

        // 异步等待网络响应, 可被外部 cancellable 随时中断
        var bytes = yield session.send_and_read_async (msg, GLib.Priority.DEFAULT, cancellable);

        if (cancellable != null && cancellable.is_cancelled ()) {
            throw new GLib.IOError.CANCELLED (_("AI request was cancelled by user"));
        }

        if (msg.status_code != 200) {
            throw new GLib.IOError.FAILED (_("API returned error status code: %u").printf (msg.status_code));
        }

        return (string) bytes.get_data ();
    }

    private static AIChatResult parse_response_bytes (uint8[] raw) throws AIClientError {
        var parser = new Json.Parser ();
        try {
            parser.load_from_data ((string) raw, (long) raw.length);
        } catch (Error e) {
            throw new AIClientError.PROTOCOL (_("Response is not valid JSON: ") + e.message);
        }
        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
            throw new AIClientError.PROTOCOL (_("Response top-level is not an object"));
        var obj = root.get_object ();
        if (obj == null)
            throw new AIClientError.PROTOCOL (_("Response top-level is not an object"));

        var choices = obj.has_member ("choices") ? obj.get_array_member ("choices") : null;
        if (choices == null || choices.get_length () == 0) {
            return new AIChatResult ("");
        }
        var first = choices.get_object_element (0);
        if (first == null) return new AIChatResult ("");

        var msg = first.has_member ("message") ? first.get_object_member ("message") : null;
        if (msg == null) return new AIChatResult ("");

        string content = msg.get_string_member_with_default ("content", "");
        if (content == null) content = "";

        var result = new AIChatResult (content);

        var tcs = msg.has_member ("tool_calls") ? msg.get_array_member ("tool_calls") : null;
        if (tcs != null && tcs.get_length () > 0) {
            for (uint i = 0; i < tcs.get_length (); i++) {
                var tc = tcs.get_object_element (i);
                if (tc == null) continue;
                string id = tc.get_string_member_with_default ("id", "");
                // OpenAI 标准: name 和 arguments 都在 tc.function 下
                // 兼容少数非标准端点直接把 arguments 放在 tc 顶层
                var fn = tc.has_member ("function") ? tc.get_object_member ("function") : null;
                string name = "";
                string raw_args = "";
                if (fn != null) {
                    name = fn.get_string_member_with_default ("name", "");
                    raw_args = fn.get_string_member_with_default ("arguments", "");
                } else {
                    name = tc.get_string_member_with_default ("name", "");
                    raw_args = tc.get_string_member_with_default ("arguments", "");
                }
                if (raw_args == null) raw_args = "";
                result.tool_calls.add (new AIToolCall (id, name, raw_args));
            }
        }
        return result;
    }
}
