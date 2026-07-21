// EncodingHelper 单元测试
// 编译: valac --pkg gee-0.8 --pkg glib-2.0 \
//   /home/sam/Desktop/filecollector/src/utils/encoding_helper.vala \
//   /home/sam/Desktop/filecollector/build/test_encoding_helper.vala \
//   -o /tmp/test_encoding_helper

int pass_count = 0;
int fail_count = 0;

void assert_eq (string desc, string expected, string actual) {
    if (expected == actual) {
        print ("PASS: %s\n", desc);
        pass_count++;
    } else {
        print ("FAIL: %s\n", desc);
        print ("  期望: \"%s\" (len=%zu)\n", expected, expected.length);
        print ("  实际: \"%s\" (len=%zu)\n", actual, actual.length);
        fail_count++;
    }
}

void assert_eq_int (string desc, int expected, int actual) {
    if (expected == actual) {
        print ("PASS: %s (%d)\n", desc, actual);
        pass_count++;
    } else {
        print ("FAIL: %s 期望 %d, 实际 %d\n", desc, expected, actual);
        fail_count++;
    }
}

void test_bytes_to_string_safe_basic () {
    print ("\n=== test_bytes_to_string_safe_basic ===\n");
    uint8[] buf = { (uint8)'h', (uint8)'e', (uint8)'l', (uint8)'l', (uint8)'o' };
    string s = EncodingHelper.bytes_to_string_safe (buf, buf.length);
    assert_eq ("基本 ASCII", "hello", s);
}

void test_bytes_to_string_safe_empty () {
    print ("\n=== test_bytes_to_string_safe_empty ===\n");
    uint8[] buf = { };
    string s = EncodingHelper.bytes_to_string_safe (buf, 0);
    assert_eq ("空 buffer", "", s);
}

void test_bytes_to_string_safe_no_trailing_null () {
    print ("\n=== test_bytes_to_string_safe_no_trailing_null ===\n");
    // 模拟 keychain/DPAPI 返回的数据: 末尾无 \0
    // 直接 (string) buf 会越界, bytes_to_string_safe 必须正确补 \0
    uint8[] buf = new uint8[5];
    buf[0] = (uint8)'w';
    buf[1] = (uint8)'o';
    buf[2] = (uint8)'r';
    buf[3] = (uint8)'l';
    buf[4] = (uint8)'d';
    string s = EncodingHelper.bytes_to_string_safe (buf, 5);
    assert_eq ("无 trailing null", "world", s);
    assert_eq_int ("字符串长度正确", 5, (int) s.length);
}

void test_bytes_to_string_safe_len_less_than_capacity () {
    print ("\n=== test_bytes_to_string_safe_len_less_than_capacity ===\n");
    // buf 容量 10, 但只有前 3 字节是有效数据
    uint8[] buf = new uint8[10];
    buf[0] = (uint8)'a';
    buf[1] = (uint8)'b';
    buf[2] = (uint8)'c';
    // 后 7 字节是垃圾 (这里是 \0, 但模拟非 \0 垃圾也应该被忽略)
    string s = EncodingHelper.bytes_to_string_safe (buf, 3);
    assert_eq ("len < buf.length 截断", "abc", s);
}

void test_bytes_to_string_safe_len_greater_than_capacity () {
    print ("\n=== test_bytes_to_string_safe_len_greater_than_capacity ===\n");
    // 调用方传了 len > buf.length, 应该 clamp 到 buf.length, 不能越界
    uint8[] buf = { (uint8)'x', (uint8)'y' };
    string s = EncodingHelper.bytes_to_string_safe (buf, 100);
    assert_eq ("len > buf.length clamp", "xy", s);
}

void test_bytes_to_string_safe_with_embedded_null () {
    print ("\n=== test_bytes_to_string_safe_with_embedded_null ===\n");
    // 嵌入式 \0: string 会按 C 字符串语义在第一个 \0 截断, 但 .length 应反映此行为
    uint8[] buf = { (uint8)'a', 0, (uint8)'b' };
    string s = EncodingHelper.bytes_to_string_safe (buf, 3);
    // C 字符串语义: "a"
    assert_eq ("embedded null 截断", "a", s);
}

void test_bytes_to_string_safe_utf8_multibyte () {
    print ("\n=== test_bytes_to_string_safe_utf8_multibyte ===\n");
    // 中文 "你好" UTF-8 编码: e4 bd a0 e5 a5 bd
    uint8[] buf = { 0xe4, 0xbd, 0xa0, 0xe5, 0xa5, 0xbd };
    string s = EncodingHelper.bytes_to_string_safe (buf, buf.length);
    assert_eq ("UTF-8 多字节", "你好", s);
}

void test_decode_to_utf8_pure_ascii () {
    print ("\n=== test_decode_to_utf8_pure_ascii ===\n");
    uint8[] buf = "Hello, World!".data;
    string s = EncodingHelper.decode_to_utf8 (buf);
    assert_eq ("纯 ASCII 解码", "Hello, World!", s);
}

void test_decode_to_utf8_with_bom () {
    print ("\n=== test_decode_to_utf8_with_bom ===\n");
    uint8[] buf = { 0xEF, 0xBB, 0xBF, (uint8)'H', (uint8)'i' };
    string s = EncodingHelper.decode_to_utf8 (buf);
    assert_eq ("UTF-8 BOM 剥离", "Hi", s);
}

void test_decode_to_utf8_binary_detection () {
    print ("\n=== test_decode_to_utf8_binary_detection ===\n");
    // 含 \0 的数据应识别为二进制
    uint8[] buf = { (uint8)'a', (uint8)'b', 0, (uint8)'c' };
    string s = EncodingHelper.decode_to_utf8 (buf);
    assert_eq ("二进制检测", "[Binary file detected: text decoding skipped]", s);
}

void test_decode_to_utf8_empty () {
    print ("\n=== test_decode_to_utf8_empty ===\n");
    uint8[] buf = { };
    string s = EncodingHelper.decode_to_utf8 (buf);
    assert_eq ("空 buffer", "", s);
}

void test_decode_to_utf8_utf16_be () {
    print ("\n=== test_decode_to_utf8_utf16_be ===\n");
    // UTF-16BE "Hi" = 0x00 0x48 0x00 0x69, 加 BOM: 0xFE 0xFF
    uint8[] buf = { 0xFE, 0xFF, 0x00, 0x48, 0x00, 0x69 };
    string s = EncodingHelper.decode_to_utf8 (buf);
    assert_eq ("UTF-16BE 解码", "Hi", s);
}

void test_decode_to_utf8_utf16_le () {
    print ("\n=== test_decode_to_utf8_utf16_le ===\n");
    // UTF-16LE "Hi" = 0x48 0x00 0x69 0x00, 加 BOM: 0xFF 0xFE
    uint8[] buf = { 0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00 };
    string s = EncodingHelper.decode_to_utf8 (buf);
    assert_eq ("UTF-16LE 解码", "Hi", s);
}

void test_decode_to_utf8_chinese () {
    print ("\n=== test_decode_to_utf8_chinese ===\n");
    string orig = "你好,世界";
    uint8[] buf = orig.data;
    string s = EncodingHelper.decode_to_utf8 (buf);
    assert_eq ("中文 UTF-8", orig, s);
}

public static int main (string[] args) {
    print ("========== EncodingHelper 测试开始 ==========\n");

    test_bytes_to_string_safe_basic ();
    test_bytes_to_string_safe_empty ();
    test_bytes_to_string_safe_no_trailing_null ();
    test_bytes_to_string_safe_len_less_than_capacity ();
    test_bytes_to_string_safe_len_greater_than_capacity ();
    test_bytes_to_string_safe_with_embedded_null ();
    test_bytes_to_string_safe_utf8_multibyte ();

    test_decode_to_utf8_pure_ascii ();
    test_decode_to_utf8_with_bom ();
    test_decode_to_utf8_binary_detection ();
    test_decode_to_utf8_empty ();
    test_decode_to_utf8_utf16_be ();
    test_decode_to_utf8_utf16_le ();
    test_decode_to_utf8_chinese ();

    print ("\n========== 测试结果 ==========\n");
    print ("PASS: %d, FAIL: %d\n", pass_count, fail_count);
    return fail_count > 0 ? 1 : 0;
}
