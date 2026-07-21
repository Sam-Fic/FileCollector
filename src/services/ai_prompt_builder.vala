// AI 提示词与工具调用参数格式化的纯逻辑构建器
//
// 从 widgets/ai_panel.vala 中提取的两个最大纯函数:
//   - build_system_prompt (~115 行): 构造系统 prompt, 依赖 AISystemSnapshot struct
//   - format_tool_args    (~84 行): 把 tool call 的 raw JSON 参数格式化成可读字符串
//   - parse_args          (~10 行): 解析 raw JSON 为 Json.Node, format_tool_args 依赖
//
// 这些逻辑与 AIPanel 的 UI/对话循环属于不同维度 (纯字符串/JSON 处理 vs GtkWidget
// 生命周期), 提取后 ai_panel.vala 专注于 UI 与对话编排, PromptBuilder 专注于
// 静态文本构造, 可独立单元测试.

public class AIPromptBuilder : GLib.Object {

    // ─── 系统提示词 ───────────────────────────────────────────────────
    // 与 ai_client.py::build_system_prompt 行为 1:1 镜像
    public static string build_system_prompt (AISystemSnapshot snap) {
        string work_dir_str = (snap.work_dir != null && snap.work_dir.length > 0)
                              ? snap.work_dir : "(not set)";
        int file_count = snap.selected_paths != null ? snap.selected_paths.length : 0;
        int text_count = snap.custom_instructions != null ? snap.custom_instructions.length : 0;
        string path_mode = snap.use_absolute ? "absolute" : "relative";
        string header_mode = snap.show_header ? "on" : "off";

        var item_block = new StringBuilder ();
        if (file_count + text_count == 0) {
            item_block.append ("  (empty)");
        } else {
            if (snap.selected_paths != null) {
                for (int i = 0; i < snap.selected_paths.length; i++) {
                    string p = snap.selected_paths[i] ?? "";
                    string name = GLib.Path.get_basename (p);
                    if (name.length == 0) name = p;
                    string tag = snap.use_absolute ? "abs" : "rel";
                    item_block.append ("  [").append (i.to_string ())
                              .append ("] file(").append (tag).append ("): ")
                              .append (name).append ("\n");
                }
            }
            if (snap.custom_instructions != null) {
                int text_idx = 0;
                for (int i = 0; i < snap.custom_instructions.length; i++) {
                    string txt = snap.custom_instructions[i] ?? "";
                    if (txt.length == 0) continue;
                    string preview = txt;
                    if (preview.length > 40) preview = UIHelpers.truncate_utf8 (preview, 40) + "…";
                    // 用 split/join 替代 string.replace, 避免 Vala 的 Regex 实现在某些情况下 assert_not_reached
                    preview = string.joinv (" ", preview.split ("\n"));
                    item_block.append ("  [").append ((file_count + text_idx).to_string ())
                              .append ("] text: ").append (preview).append ("\n");
                    text_idx++;
                }
            }
        }

        return (
            "You are the AI assistant for FileCollector, a file-collecting and "
            + "orchestration tool. The user picks files in a working directory; you "
            + "understand their intent and use the provided tools to manipulate the "
            + "orchestration list.\n\n"
            + "Current state:\n"
            + "- Work directory: " + work_dir_str + "\n"
            + "- Orchestration list: " + (file_count + text_count).to_string ()
            +   " item(s) (" + file_count.to_string () + " file(s), "
            +   text_count.to_string () + " text block(s))\n"
            + "- Path mode: " + path_mode + "\n"
            + "- Header info: " + header_mode + "\n"
            + "- List contents:\n" + item_block.str + "\n"
            + "Available tools:\n"
            + "- set_work_dir(path): switch the working directory (clears the list)\n"
            + "- list_files(pattern?, directory?, max_depth?, max_results?): scan a directory for files; "
            + "pattern is a case-insensitive glob on the file name. Use this to explore before adding.\n"
            + "- read_file(path, start_line?, max_lines?, max_bytes?): read a file's text content "
            + "with 1-based line numbers. Use to inspect a file before deciding whether to add it, "
            + "or to look up specific information (config values, doc strings, etc.). Binary files are rejected.\n"
            + "- list_items(kind?, max_items?): inspect the current orchestration list; "
            + "kind='file' or 'text' to filter. Always call this after add_files / add_text / "
            + "move_item / remove_item to verify the result before telling the user what was done.\n"
            + "- add_files(paths): add files (absolute paths required; missing files are skipped)\n"
            + "- add_text(text, position?): insert a text block (appends if position is omitted)\n"
            + "- remove_item(index): delete an item by 0-based index\n"
            + "- move_item(from_index, to_index): move an item\n"
            + "- clear_items(): empty the orchestration list\n"
            + "- set_use_absolute(value): toggle absolute/relative path mode\n"
            + "- set_show_header(value): toggle writing the work-directory header in exports\n"
            + "- get_git_status(): check what files are modified/untracked in the working tree.\n"
            + "- get_git_diff(staged?): read the exact code changes to understand the user's current task.\n"
            + "- get_git_log(max_count?): list recent commits to find historical context.\n"
            + "- get_git_commit_diff(commit_hash): inspect the code changes of a specific past commit.\n"
            + "- add_git_diff(staged?): inject the current Git diff directly into the list (bypasses LLM context, saves tokens).\n"
            + "- add_git_commit_diff(commit_hash): inject a specific commit's diff directly into the list.\n"
            + "- add_git_diff_range(from_hash, to_hash?): inject the combined diff of a commit range (from..to) into the list.\n"
            + "- add_file_snippet(path, start_line, end_line): add only a specific line range of a file. "
            + "Use this after read_file to extract just the relevant function/class, saving tokens.\n"
            + "- search_files(query, kind?, case_sensitive?, max_results?, max_depth?, directory?): "
            + "boolean multi-word search over file names AND/OR contents. Supports & (AND), | (OR), "
            + "parentheses, \"quoted phrases\", implicit AND via whitespace. Use to locate files by "
            + "keywords in large projects — far more efficient than list_files + read_file guessing. "
            + "kind: 'filename', 'content', or 'both' (default).\n\n"
            + "Workflow rules:\n"
            + "1. Prefer tool calls over asking the user for paths you can discover yourself. "
            + "If the user says 'add all files about X' or 'find files matching Y', call "
            + "list_files first with a sensible pattern (e.g. '*x*'), inspect the results, "
            + "then call add_files with the chosen absolute paths in batches.\n"
            + "2. NEVER add a file based on its name alone. After list_files, the result is a "
            + "CANDIDATE set. For each candidate you intend to add (or when in doubt), call "
            + "read_file with max_lines=30-50 to peek at the top of the file — module docstring, "
            + "imports, class/function names, config schema — to confirm it really matches the "
            + "user's intent. Skip this only for very short, unambiguous files (e.g. a single "
            + "README.md whose first line clearly states the topic).\n"
            + "3. Pass absolute paths to add_files. The server decides how to store them: files "
            + "inside the current work directory are stored as relative paths and reflected as "
            + "checked items in the file tree; files outside the work directory are stored as "
            + "absolute paths and will not appear in the file tree.\n"
            + "4. The UI refreshes in real time after each tool call, so the user can see results immediately.\n"
            + "5. After any mutation (add_files / add_text / move_item / remove_item / clear_items), "
            + "call list_items to confirm what actually landed in the list before reporting to the user. "
            + "If something is missing or wrong, fix it in the same turn — don't assume success.\n"
            + "6. Be concise and professional. Reply in the same language the user uses. "
            + "When no tool call is needed, just explain in natural language.\n"
            + "7. When the user asks to 'collect files for my current PR' or 'gather context for "
            + "the bug I just fixed', ALWAYS call `get_git_status` and `get_git_diff` first. "
            + "Analyze the diff to identify ALL related files (including headers, configs, or "
            + "test files that might not show up in the diff but are relevant), then use "
            + "`add_files` to collect them.\n"
            + "8. CRITICAL: When the user asks to 'export diff', 'add changes to context', or 'collect PR diff', "
            + "NEVER use `get_git_diff` combined with `add_text`. Passing large diffs through the LLM context wastes tokens "
            + "and risks API truncation. ALWAYS use the dedicated `add_git_diff` or `add_git_commit_diff` tools. "
            + "These tools fetch the diff locally and inject it into the list bypassing the LLM context entirely.\n"
            + "9. When the user asks to 'add all diffs from commit X to Y' or 'export changes since commit X', "
            + "use `add_git_diff_range(from_hash, to_hash)` instead of calling `add_git_commit_diff` multiple times. "
            + "This is much more efficient. First call `get_git_log` to find the exact hashes if needed.\n"
            + "10. When a file is large but only a specific function or class is relevant, use `read_file` to locate the exact line numbers, "
            + "then use `add_file_snippet` instead of `add_files` to avoid bloating the context window with irrelevant code.\n"
            + "11. For large projects (thousands of files), NEVER explore blindly with list_files + "
            + "read_file. Use `search_files` first with a precise boolean query to narrow the candidate "
            + "set — e.g. `search_files(query=\"ItemData & (notify | connect)\", kind=\"both\")` returns "
            + "only files whose names or contents mention those terms. Then call `read_file` on the few "
            + "returned candidates to confirm. This avoids token exhaustion and aimless wandering. "
            + "`search_files` is also the right tool when the user gives specific identifiers "
            + "(class names, function names, error strings) — search by those tokens directly."
        );
    }

    // ─── 工具调用参数格式化 ───────────────────────────────────────────
    // 把 tool call 的 raw JSON 参数格式化成可读字符串, 用于聊天界面展示.
    // 对常见 tool (add_files/read_file/list_files/list_items) 做定制化展示,
    // 其余 tool 退化为美化 JSON 输出.
    public static string format_tool_args (string name, string raw) {
        if (name == "add_files") {
            var arr = parse_args (raw);
            if (arr.get_node_type () == Json.NodeType.OBJECT) {
                var o = arr.get_object ();
                if (o.has_member ("paths")) {
                    var paths = o.get_array_member ("paths");
                    if (paths != null) {
                        var parts = new Gee.ArrayList<string> ();
                        int n = (int) paths.get_length ();
                        if (n <= 8) {
                            for (int i = 0; i < n; i++) {
                                parts.add ("\"" + paths.get_string_element (i) + "\"");
                            }
                            return "paths=[" + string.joinv (", ", (string[]) parts.to_array ()) + "]";
                        } else {
                            for (int i = 0; i < 5; i++) {
                                parts.add ("\"" + paths.get_string_element (i) + "\"");
                            }
                            return "paths=[" + string.joinv (", ", (string[]) parts.to_array ())
                                 + ", … (+%d more)".printf (n - 5) + "]";
                        }
                    }
                }
            }
        }
        if (name == "read_file") {
            var arr = parse_args (raw);
            if (arr.get_node_type () == Json.NodeType.OBJECT) {
                var o = arr.get_object ();
                string p = o.get_string_member_with_default ("path", "");
                var extras = new Gee.ArrayList<string> ();
                if (o.has_member ("start_line"))
                    extras.add ("start_line=%s".printf (o.get_int_member ("start_line").to_string ()));
                if (o.has_member ("max_lines"))
                    extras.add ("max_lines=%s".printf (o.get_int_member ("max_lines").to_string ()));
                if (o.has_member ("max_bytes"))
                    extras.add ("max_bytes=%s".printf (o.get_int_member ("max_bytes").to_string ()));
                if (extras.size > 0) {
                    return "\"" + p + "\", " + string.joinv (", ", (string[]) extras.to_array ());
                }
                return "\"" + p + "\"";
            }
        }
        if (name == "list_files") {
            var arr = parse_args (raw);
            if (arr.get_node_type () == Json.NodeType.OBJECT) {
                var o = arr.get_object ();
                var parts = new Gee.ArrayList<string> ();
                if (o.has_member ("pattern"))
                    parts.add ("pattern='" + o.get_string_member ("pattern") + "'");
                if (o.has_member ("directory"))
                    parts.add ("directory='" + o.get_string_member ("directory") + "'");
                if (o.has_member ("max_depth"))
                    parts.add ("max_depth=%s".printf (o.get_int_member ("max_depth").to_string ()));
                if (o.has_member ("max_results"))
                    parts.add ("max_results=%s".printf (o.get_int_member ("max_results").to_string ()));
                return parts.size > 0 ? string.joinv (", ", (string[]) parts.to_array ()) : "(no filter)";
            }
        }
        if (name == "list_items") {
            var arr = parse_args (raw);
            if (arr.get_node_type () == Json.NodeType.OBJECT) {
                var o = arr.get_object ();
                var parts = new Gee.ArrayList<string> ();
                if (o.has_member ("kind"))
                    parts.add ("kind='" + o.get_string_member ("kind") + "'");
                if (o.has_member ("max_items"))
                    parts.add ("max_items=%s".printf (o.get_int_member ("max_items").to_string ()));
                return parts.size > 0 ? string.joinv (", ", (string[]) parts.to_array ()) : "(all items)";
            }
        }
        if (name == "search_files") {
            var arr = parse_args (raw);
            if (arr.get_node_type () == Json.NodeType.OBJECT) {
                var o = arr.get_object ();
                var parts = new Gee.ArrayList<string> ();
                if (o.has_member ("query"))
                    parts.add ("query=\"" + o.get_string_member ("query") + "\"");
                if (o.has_member ("kind"))
                    parts.add ("kind='" + o.get_string_member ("kind") + "'");
                if (o.has_member ("case_sensitive") && o.get_boolean_member ("case_sensitive"))
                    parts.add ("case_sensitive=true");
                if (o.has_member ("max_results"))
                    parts.add ("max_results=%s".printf (o.get_int_member ("max_results").to_string ()));
                if (o.has_member ("max_depth"))
                    parts.add ("max_depth=%s".printf (o.get_int_member ("max_depth").to_string ()));
                if (o.has_member ("directory"))
                    parts.add ("directory='" + o.get_string_member ("directory") + "'");
                return parts.size > 0 ? string.joinv (", ", (string[]) parts.to_array ()) : "(no filter)";
            }
        }
        // 默认: 美化 JSON 输出
        try {
            var parser = new Json.Parser ();
            parser.load_from_data (raw, -1);
            var gen = new Json.Generator ();
            gen.set_root (parser.get_root ());
            gen.pretty = true;
            return gen.to_data (null);
        } catch (Error e) {
            return raw ?? "";
        }
    }

    // ─── 辅助: 解析 raw JSON 为 Json.Node ─────────────────────────────
    // 空字符串/解析失败时返回空 JsonObject, 避免调用方每个分支都判空.
    public static Json.Node parse_args (string raw) {
        if (raw == null || raw.strip () == "") return AI.SchemaHelper.obj_to_node (new Json.Object ());
        var parser = new Json.Parser ();
        try {
            parser.load_from_data (raw, raw.length);
            var root = parser.get_root ();
            if (root != null && root.get_node_type () == Json.NodeType.OBJECT) {
                return root;
            }
        } catch (Error e) { warning ("Failed to parse JSON args: %s", e.message); }
        return AI.SchemaHelper.obj_to_node (new Json.Object ());
    }
}
