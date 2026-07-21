// AIClient 单元测试
//
// 仅覆盖两个纯逻辑入口:
//   1. AIClient.parse_response_bytes — 解析 OpenAI 兼容 chat completions 响应
//   2. build_full_tool_schema        — 构造 function-calling 工具描述
//
// 不测 HTTP 行为 (需要 mock Soup.Session, 收益低).

using GLib;
using Json;

int pass_count = 0;
int fail_count = 0;

void pass (string desc) { print ("PASS: %s\n", desc); pass_count++; }
void fail (string desc, string detail = "") {
    print ("FAIL: %s%s%s\n", desc, detail.length > 0 ? " - " : "", detail);
    fail_count++;
}
void assert_true (string desc, bool cond) {
    if (cond) pass (desc); else fail (desc);
}
void assert_eq_int (string desc, int expected, int actual) {
    if (expected == actual) pass (desc);
    else fail (desc, @"期望 $expected, 实际 $actual");
}
void assert_eq_str (string desc, string expected, string actual) {
    if (expected == actual) pass (desc);
    else fail (desc, @"期望 '$expected', 实际 '$actual'");
}

// 把 string 转 uint8[] (不带 \0 终结符, 模拟真实 HTTP body)
uint8[] to_bytes (string s) {
    uint8[] buf = new uint8[s.length];
    Memory.copy (buf, s, s.length);
    return buf;
}

// ─── parse_response_bytes: 非 JSON ──────────────────────────────
void test_parse_invalid_json () {
    print ("\n=== test_parse_invalid_json ===\n");
    try {
        AIClient.parse_response_bytes (to_bytes ("not a json"));
        fail ("非 JSON 应抛 PROTOCOL");
    } catch (AIClientError e) {
        pass ("非 JSON 抛 PROTOCOL: %s".printf (e.message));
    }
}

// ─── parse_response_bytes: 顶层非对象 ───────────────────────────
void test_parse_top_level_not_object () {
    print ("\n=== test_parse_top_level_not_object ===\n");
    try {
        AIClient.parse_response_bytes (to_bytes ("[1,2,3]"));
        fail ("数组顶层应抛 PROTOCOL");
    } catch (AIClientError e) {
        pass ("数组顶层抛 PROTOCOL");
    }
    try {
        AIClient.parse_response_bytes (to_bytes ("\"string\""));
        fail ("字符串顶层应抛 PROTOCOL");
    } catch (AIClientError e) {
        pass ("字符串顶层抛 PROTOCOL");
    }
}

// ─── parse_response_bytes: 无 choices → 空内容 ──────────────────
void test_parse_no_choices () {
    print ("\n=== test_parse_no_choices ===\n");
    try {
        var r = AIClient.parse_response_bytes (to_bytes ("""{"id":"x"}"""));
        assert_eq_str ("无 choices 返回空 content", "", r.content);
        assert_eq_int ("无 choices 无 tool_calls", 0, r.tool_calls.size);
    } catch (AIClientError e) {
        fail ("不应抛异常", e.message);
    }
}

// ─── parse_response_bytes: choices 为空数组 ─────────────────────
void test_parse_empty_choices () {
    print ("\n=== test_parse_empty_choices ===\n");
    try {
        var r = AIClient.parse_response_bytes (to_bytes ("""{"choices":[]}"""));
        assert_eq_str ("空 choices 返回空 content", "", r.content);
    } catch (AIClientError e) {
        fail ("不应抛异常", e.message);
    }
}

// ─── parse_response_bytes: 纯文本 content ──────────────────────
void test_parse_plain_content () {
    print ("\n=== test_parse_plain_content ===\n");
    string body = """{
        "choices": [
            {"message": {"role":"assistant", "content":"hello world"}}
        ]
    }""";
    try {
        var r = AIClient.parse_response_bytes (to_bytes (body));
        assert_eq_str ("解析 content", "hello world", r.content);
        assert_eq_int ("无 tool_calls", 0, r.tool_calls.size);
    } catch (AIClientError e) {
        fail ("不应抛异常", e.message);
    }
}

// ─── parse_response_bytes: content 缺失 → 空串 ─────────────────
void test_parse_missing_content () {
    print ("\n=== test_parse_missing_content ===\n");
    string body = """{"choices":[{"message":{"role":"assistant"}}]}""";
    try {
        var r = AIClient.parse_response_bytes (to_bytes (body));
        assert_eq_str ("缺失 content 返回空串", "", r.content);
    } catch (AIClientError e) {
        fail ("不应抛异常", e.message);
    }
}

// ─── parse_response_bytes: OpenAI 标准 tool_calls ──────────────
// arguments 在 tc.function 下
void test_parse_tool_calls_standard () {
    print ("\n=== test_parse_tool_calls_standard ===\n");
    string body = """{
        "choices": [{
            "message": {
                "role": "assistant",
                "content": null,
                "tool_calls": [
                    {"id":"call_1","type":"function","function":{"name":"add_files","arguments":"{\"paths\":[\"/a\"]}"}},
                    {"id":"call_2","type":"function","function":{"name":"add_text","arguments":"{\"text\":\"hi\"}"}}
                ]
            }
        }]
    }""";
    try {
        var r = AIClient.parse_response_bytes (to_bytes (body));
        assert_eq_int ("2 个 tool_calls", 2, r.tool_calls.size);
        var first = r.tool_calls.get (0);
        assert_eq_str ("第一个 id", "call_1", first.id);
        assert_eq_str ("第一个 name", "add_files", first.name);
        assert_eq_str ("第一个 arguments", "{\"paths\":[\"/a\"]}", first.arguments_json);
        var second = r.tool_calls.get (1);
        assert_eq_str ("第二个 name", "add_text", second.name);
    } catch (AIClientError e) {
        fail ("不应抛异常", e.message);
    }
}

// ─── parse_response_bytes: 非标准 tool_calls (顶层 arguments) ───
// 兼容少数非标准端点
void test_parse_tool_calls_nonstandard () {
    print ("\n=== test_parse_tool_calls_nonstandard ===\n");
    string body = """{
        "choices": [{
            "message": {
                "tool_calls": [
                    {"id":"x","name":"clear_items","arguments":"{}"}
                ]
            }
        }]
    }""";
    try {
        var r = AIClient.parse_response_bytes (to_bytes (body));
        assert_eq_int ("1 个 tool_calls", 1, r.tool_calls.size);
        var tc = r.tool_calls.get (0);
        assert_eq_str ("name 从顶层读取", "clear_items", tc.name);
        assert_eq_str ("arguments 从顶层读取", "{}", tc.arguments_json);
    } catch (AIClientError e) {
        fail ("不应抛异常", e.message);
    }
}

// ─── parse_response_bytes: tool_calls 缺失 id/name 兜底 ─────────
void test_parse_tool_calls_missing_fields () {
    print ("\n=== test_parse_tool_calls_missing_fields ===\n");
    string body = """{
        "choices": [{
            "message": {
                "tool_calls": [{}]
            }
        }]
    }""";
    try {
        var r = AIClient.parse_response_bytes (to_bytes (body));
        assert_eq_int ("1 个 tool_calls", 1, r.tool_calls.size);
        var tc = r.tool_calls.get (0);
        assert_eq_str ("缺失 id 空串兜底", "", tc.id);
        assert_eq_str ("缺失 name 空串兜底", "", tc.name);
        assert_eq_str ("缺失 arguments 空串兜底", "", tc.arguments_json);
    } catch (AIClientError e) {
        fail ("不应抛异常", e.message);
    }
}

// ─── parse_response_bytes: 末尾无 \0 也能解析 ──────────────────
// 真实 HTTP body 不带 \0 终结符, 验证 bytes_to_string_safe 起作用
void test_parse_no_null_terminator () {
    print ("\n=== test_parse_no_null_terminator ===\n");
    string body = """{"choices":[{"message":{"content":"ok"}}]}""";
    try {
        var r = AIClient.parse_response_bytes (to_bytes (body));
        assert_eq_str ("无 \\0 终结符也能解析", "ok", r.content);
    } catch (AIClientError e) {
        fail ("不应抛异常", e.message);
    }
}

// ─── build_full_tool_schema: 返回结构 ───────────────────────────
void test_build_schema_structure () {
    print ("\n=== test_build_schema_structure ===\n");
    var node = build_full_tool_schema ();
    assert_true ("非 null", node != null);
    assert_true ("是 ARRAY 类型", node.get_node_type () == Json.NodeType.ARRAY);
    var arr = node.get_array ();
    assert_true ("数组非空", arr.get_length () > 0);

    // 第一个 tool 应该有 type=function + function.name + function.description + function.parameters
    var first = arr.get_object_element (0);
    assert_eq_str ("第一个 type=function", "function", first.get_string_member_with_default ("type", ""));
    var fn = first.get_object_member ("function");
    assert_true ("function 子对象非 null", fn != null);
    assert_true ("function.name 非空", fn.get_string_member_with_default ("name", "").length > 0);
    assert_true ("function.description 非空", fn.get_string_member_with_default ("description", "").length > 0);
    assert_true ("function.parameters 非 null", fn.get_member ("parameters") != null);
}

// ─── build_full_tool_schema: 必备工具是否齐全 ───────────────────
// 抽样校验若干关键工具名, 防止误删
void test_build_schema_contains_expected_tools () {
    print ("\n=== test_build_schema_contains_expected_tools ===\n");
    var node = build_full_tool_schema ();
    var arr = node.get_array ();
    var names = new Gee.HashSet<string> ();
    for (uint i = 0; i < arr.get_length (); i++) {
        var t = arr.get_object_element (i);
        var fn = t.get_object_member ("function");
        names.add (fn.get_string_member_with_default ("name", ""));
    }
    string[] expected = {
        "set_work_dir", "add_files", "add_text", "remove_item", "move_item",
        "clear_items", "set_use_absolute", "set_show_header",
        "list_files", "read_file", "list_items",
        "get_git_status", "get_git_diff", "get_git_log", "get_git_commit_diff",
        "add_git_diff", "add_git_commit_diff", "add_git_diff_range",
        "add_file_snippet"
    };
    foreach (var n in expected) {
        assert_true (@"包含工具 '$n'", names.contains (n));
    }
}

// ─── build_full_tool_schema: 必填字段正确性 ─────────────────────
// 抽样校验 set_work_dir 必填 path, add_text 必填 text, 等
void test_build_schema_required_fields () {
    print ("\n=== test_build_schema_required_fields ===\n");
    var node = build_full_tool_schema ();
    var arr = node.get_array ();
    var by_name = new Gee.HashMap<string, Json.Object> ();
    for (uint i = 0; i < arr.get_length (); i++) {
        var t = arr.get_object_element (i);
        var fn = t.get_object_member ("function");
        by_name[fn.get_string_member_with_default ("name", "")] = fn;
    }

    // set_work_dir → required: ["path"]
    // (by_name[key] 返回 nullable, 但下面 has_key 检查 + (!) 断言保证非空)
    assert_true ("包含 set_work_dir", by_name.has_key ("set_work_dir"));
    Json.Object set_wd = (!)by_name["set_work_dir"];
    Json.Object set_wd_params = (!)set_wd.get_object_member ("parameters");
    var set_wd_req = set_wd_params.get_array_member ("required");
    assert_eq_int ("set_work_dir.required 长度", 1, (int) set_wd_req.get_length ());
    assert_eq_str ("set_work_dir.required[0]=path", "path", set_wd_req.get_string_element (0));

    // add_files → required: ["paths"]
    Json.Object add_files = (!)by_name["add_files"];
    Json.Object add_files_params = (!)add_files.get_object_member ("parameters");
    var add_files_req = add_files_params.get_array_member ("required");
    assert_eq_str ("add_files.required[0]=paths", "paths", add_files_req.get_string_element (0));

    // move_item → required: ["from_index","to_index"]
    Json.Object move_item = (!)by_name["move_item"];
    Json.Object move_item_params = (!)move_item.get_object_member ("parameters");
    var move_item_req = move_item_params.get_array_member ("required");
    assert_eq_int ("move_item.required 长度", 2, (int) move_item_req.get_length ());

    // clear_items → parameters 是 object, 但没有 required (空参数)
    Json.Object clear_items = (!)by_name["clear_items"];
    Json.Object clear_params = (!)clear_items.get_object_member ("parameters");
    assert_true ("clear_items 无 required 字段", !clear_params.has_member ("required"));
}

public static int main (string[] args) {
    print ("========== AIClient 测试开始 ==========\n");

    test_parse_invalid_json ();
    test_parse_top_level_not_object ();
    test_parse_no_choices ();
    test_parse_empty_choices ();
    test_parse_plain_content ();
    test_parse_missing_content ();
    test_parse_tool_calls_standard ();
    test_parse_tool_calls_nonstandard ();
    test_parse_tool_calls_missing_fields ();
    test_parse_no_null_terminator ();
    test_build_schema_structure ();
    test_build_schema_contains_expected_tools ();
    test_build_schema_required_fields ();

    print ("\n========== 测试结果 ==========\n");
    print ("PASS: %d, FAIL: %d\n", pass_count, fail_count);
    return fail_count > 0 ? 1 : 0;
}
