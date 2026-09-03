using GLib;

/**
 * 跨平台密钥存储抽象层。
 *
 * 把"API Key 存哪里 / 怎么加密"按平台分流：
 *   - Linux   : 沿用 libsecret (GNOME Keyring / KWallet)
 *   - Windows : Win32 DPAPI (CryptProtectData), 加密后落盘到用户配置目录
 *   - macOS   : Security 框架 SecKeychain
 *
 * 任意平台实现失败时都降级返回 false / null, 上层 (ConfigManager) 已对
 * 密钥缺失做了容错, 不会因此崩溃。
 */

namespace SecretStore {

    // 标识不同密钥槽的属性键 (用于 libsecret schema / 文件名)
    private const string SCHEMA_NAME_API_KEY = "io.github.sam_fic.filecollector.api_key";
    private const string SCHEMA_NAME_MM_API_KEY = "io.github.sam_fic.filecollector.mm_api_key";
    private const string SCHEMA_NAME_PADDLEOCR_TOKEN = "io.github.sam_fic.filecollector.paddleocr_token";

#if WINDOWS
    // ─── Windows: DPAPI ────────────────────────────────────────────────
    // 通过 CCode 直接声明 Win32 API, 不引入额外依赖。
    // Vala 生成 secret_store_* wrapper, 内部调用下面这些唯一命名的 C 函数,
    // 真实实现见 src/win32_dpapi_shim.c (封装 CryptProtectData/LocalFree)。
    [CCode (cname = "fc_CryptProtectData", cheader_filename = "src/win32_dpapi_shim.h")]
    private extern static uint CryptProtectData (
        void* pDataIn, string? szDataDescr,
        void* pOptionalEntropy, void* pReserved,
        void* pPromptStruct, uint dwFlags, void* pDataOut);

    [CCode (cname = "fc_CryptUnprotectData", cheader_filename = "src/win32_dpapi_shim.h")]
    private extern static uint CryptUnprotectData (
        void* pDataIn, void* ppszDataDescr,
        void* pOptionalEntropy, void* pReserved,
        void* pPromptStruct, uint dwFlags, void* pDataOut);

    [CCode (cname = "FC_DATA_BLOB", has_type_id = false, cheader_filename = "src/win32_dpapi_shim.h")]
    private struct DATA_BLOB {
        public uint cbData;
        public void* pbData;
    }

    [CCode (cname = "fc_LocalFree", cheader_filename = "src/win32_dpapi_shim.h")]
    private extern static void LocalFree (void* hMem);

    private static string secret_file (string slot) {
        var dir = Path.build_filename (
            Environment.get_user_config_dir (), "filecollector");
        try {
            var f = File.new_for_path (dir);
            if (!f.query_exists ()) f.make_directory_with_parents (null);
        } catch (Error e) {
            warning ("SecretStore: cannot create config dir: %s", e.message);
        }
        return Path.build_filename (dir, "." + slot + ".bin");
    }

    // 构造一个 DATA_BLOB, 包装一段 UTF-8 字节流作为 DPAPI 熵. 存于堆, 调用方
    // 负责在 CryptProtectData / CryptUnprotectData 返回后调用 LocalFree 释放.
    private static DATA_BLOB make_entropy_blob (string slot) {
        unowned uint8[] bytes = slot.data;
        var blob = DATA_BLOB () { cbData = bytes.length, pbData = bytes };
        return blob;
    }

    private static bool dpapi_store (string slot, string value) {
        unowned uint8[] data = value.data;
        var in_blob = DATA_BLOB () { cbData = data.length, pbData = data };
        // 引入 per-scheme 熵: 以 slot 名作为 additional entropy. 这样:
        //   1. 不同槽位 (api_key / mm_api_key / paddleocr_token / profile_*) 互相隔离;
        //   2. 同用户其他应用即使拿到密文, 没有正确熵也解不出来;
        //   3. 未受信任进程无法以默认 NULL 熵调用 CryptUnprotectData 解密.
        var entropy = make_entropy_blob (slot);
        DATA_BLOB out_blob = DATA_BLOB ();
        if (CryptProtectData (&in_blob, "filecollector", &entropy, null, null, 0, &out_blob) == 0)
            return false;
        try {
            uint8[] enc = new uint8[out_blob.cbData];
            Memory.copy (enc, out_blob.pbData, out_blob.cbData);
            FileUtils.set_data (secret_file (slot), enc);
            return true;
        } catch (Error e) {
            warning ("SecretStore: write failed: %s", e.message);
            return false;
        } finally {
            LocalFree (out_blob.pbData);
        }
    }

    private static string? dpapi_lookup (string slot) {
        string path = secret_file (slot);
        if (!FileUtils.test (path, FileTest.EXISTS)) return null;
        try {
            uint8[] raw;
            FileUtils.get_data (path, out raw);
            var in_blob = DATA_BLOB () { cbData = raw.length, pbData = raw };
            // 写入时使用的熵在读取时必须保持一致, 否则 CryptUnprotectData 返回失败.
            var entropy = make_entropy_blob (slot);
            DATA_BLOB out_blob = DATA_BLOB ();
            if (CryptUnprotectData (&in_blob, null, &entropy, null, null, 0, &out_blob) == 0)
                return null;
            // DPAPI 解密后的 buf 不保证末尾有 \0, (string) buf 会越界。
            // 显式分配 +1 字节并补 \0。
            uint8[] buf = new uint8[out_blob.cbData + 1];
            Memory.copy (buf, out_blob.pbData, out_blob.cbData);
            buf[out_blob.cbData] = 0;
            string result = (string) buf;
            LocalFree (out_blob.pbData);
            return result;
        } catch (Error e) {
            warning ("SecretStore: read failed: %s", e.message);
            return null;
        }
    }

    public static bool store (string slot, string api_key) {
        if (api_key.length == 0) {
            // 清空: 删除落盘文件
            string path = secret_file (slot);
            if (FileUtils.test (path, FileTest.EXISTS))
                FileUtils.remove (path);
            return true;
        }
        return dpapi_store (slot, api_key);
    }

    public static string? lookup (string slot) {
        return dpapi_lookup (slot);
    }

#elif MACOS
    // ─── macOS: SecKeychain ────────────────────────────────────────────
    [CCode (cheader_filename = "Security/Security.h", cname = "SecKeychainAddGenericPassword")]
    private extern static int SecKeychainAddGenericPassword (
        void* keychain, uint32 serviceNameLength, string serviceName,
        uint32 accountNameLength, string accountName,
        uint32 passwordLength, void* passwordData,
        void* itemRef);

    [CCode (cheader_filename = "Security/Security.h", cname = "SecKeychainFindGenericPassword")]
    private extern static int SecKeychainFindGenericPassword (
        void* keychainOrArray, uint32 serviceNameLength, string serviceName,
        uint32 accountNameLength, string accountName,
        uint32* passwordLength, void** passwordData, void* itemRef);

    [CCode (cheader_filename = "Security/Security.h", cname = "SecKeychainItemFreeContent")]
    private extern static int SecKeychainItemFreeContent (
        void* attrList, void* data);

    [CCode (cheader_filename = "Security/Security.h", cname = "SecKeychainItemDelete")]
    private extern static int SecKeychainItemDelete (void* itemRef);

    [CCode (cheader_filename = "CoreFoundation/CoreFoundation.h", cname = "CFRelease")]
    private extern static void CFRelease (void* cf);

    private static int macos_store (string slot, string api_key) {
        // 先删后写, 避免重复条目
        macos_delete (slot);
        unowned uint8[] pw = api_key.data;
        return SecKeychainAddGenericPassword (
            null, (uint32) slot.length, slot,
            (uint32) slot.length, slot,
            (uint32) pw.length, pw, null);
    }

    // 查询密钥: 仅读取, 不删除 keychain 条目.
    // (历史 bug: 旧版 macos_lookup 同时调用 SecKeychainItemDelete,
    //  导致每次查询都会清空已存的 API Key, 第二次启动就读不到了.)
    private static string? macos_find (string slot) {
        uint32 len = 0;
        void* data = null;
        void* item = null;
        int rc = SecKeychainFindGenericPassword (
            null, (uint32) slot.length, slot,
            (uint32) slot.length, slot,
            &len, &data, &item);
        if (rc != 0 || data == null) {
            if (item != null) CFRelease (item);
            return null;
        }
        // Keychain 返回的 data 不保证末尾有 \0, 显式拷贝并补 \0
        uint8[] buf = new uint8[len + 1];
        Memory.copy (buf, data, len);
        buf[len] = 0;
        string result = (string) buf;
        SecKeychainItemFreeContent (null, data);
        if (item != null) CFRelease (item);
        return result;
    }

    // 删除指定槽位的 keychain 条目 (供 store 的"先删后写"和清空流程使用).
    // 查询流程绝不能调用此函数, 否则会破坏已存密钥.
    private static void macos_delete (string slot) {
        void* item = null;
        int rc = SecKeychainFindGenericPassword (
            null, (uint32) slot.length, slot,
            (uint32) slot.length, slot,
            null, null, &item);
        if (rc != 0 || item == null) return;
        SecKeychainItemDelete (item);
        CFRelease (item);
    }

    public static bool store (string slot, string api_key) {
        if (api_key.length == 0) {
            // 清空: 找到即删
            macos_delete (slot);
            return true;
        }
        return macos_store (slot, api_key) == 0;
    }

    public static string? lookup (string slot) {
        return macos_find (slot);
    }

#else
    // ─── Linux: libsecret ──────────────────────────────────────────────
    private static Secret.Schema? schema_for (string name) {
        return new Secret.Schema (name, Secret.SchemaFlags.NONE,
            "type", Secret.SchemaAttributeType.STRING);
    }

    public static bool store (string slot, string api_key) {
        var schema = schema_for (slot);
        if (api_key.length == 0) {
            try {
                Secret.password_clear_sync (schema, null, "type", slot, null);
            } catch (Error e) {
                warning ("SecretStore: clear failed: %s", e.message);
            }
            return true;
        }
        try {
            return Secret.password_store_sync (
                schema, Secret.COLLECTION_DEFAULT,
                "FileCollector API Key", api_key, null,
                "type", slot, null);
        } catch (Error e) {
            warning ("SecretStore: store failed: %s", e.message);
            return false;
        }
    }

    public static string? lookup (string slot) {
        var schema = schema_for (slot);
        try {
            return Secret.password_lookup_sync (schema, null, "type", slot, null);
        } catch (Error e) {
            warning ("SecretStore: lookup failed: %s", e.message);
            return null;
        }
    }
#endif

    // ─── 语义化包装 (供 ConfigManager 调用) ─────────────────────────────
    public static bool store_api_key (string api_key) {
        return store (SCHEMA_NAME_API_KEY, api_key);
    }

    public static string? load_api_key () {
        return lookup (SCHEMA_NAME_API_KEY);
    }

    public static bool store_multimodal_api_key (string api_key) {
        return store (SCHEMA_NAME_MM_API_KEY, api_key);
    }

    public static string? load_multimodal_api_key () {
        return lookup (SCHEMA_NAME_MM_API_KEY);
    }

    public static bool store_paddleocr_token (string token) {
        return store (SCHEMA_NAME_PADDLEOCR_TOKEN, token);
    }

    public static string? load_paddleocr_token () {
        return lookup (SCHEMA_NAME_PADDLEOCR_TOKEN);
    }

    // ─── 多模型配置 (profile) 槽位 ──────────────────────────────────────
    // 每个模型配置方案的 API Key 独立存储, 槽位名 = 基础槽名 + "-" + 清洗后的
    // profile 名 + "-" + 原名哈希 (g_str_hash 算法跨平台稳定, 用于区分中文等
    // 清洗后同名的 profile; Windows 落盘文件名也依赖此清洗避免非法字符).

    private static string profile_slot (string base_name, string profile_name) {
        var sb = new StringBuilder ();
        foreach (uint8 c in profile_name.data) {
            char ch = (char) c;
            if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')
                || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == '.') {
                sb.append_c (ch);
            } else {
                sb.append_c ('_');
            }
        }
        return base_name + "-" + sb.str + "-" + profile_name.hash ().to_string ();
    }

    // 侧边栏 AI 助手方案的 API Key
    public static bool store_profile_api_key (string profile_name, string api_key) {
        if (profile_name.length == 0) return false;
        return store (profile_slot (SCHEMA_NAME_API_KEY, profile_name), api_key);
    }

    public static string? load_profile_api_key (string profile_name) {
        if (profile_name.length == 0) return null;
        return lookup (profile_slot (SCHEMA_NAME_API_KEY, profile_name));
    }

    // VLM (多模态) 方案的 API Key (OpenAI 兼容路径)
    public static bool store_profile_mm_api_key (string profile_name, string api_key) {
        if (profile_name.length == 0) return false;
        return store (profile_slot (SCHEMA_NAME_MM_API_KEY, profile_name), api_key);
    }

    public static string? load_profile_mm_api_key (string profile_name) {
        if (profile_name.length == 0) return null;
        return lookup (profile_slot (SCHEMA_NAME_MM_API_KEY, profile_name));
    }

    // VLM (多模态) 方案的 PaddleOCR Access Token (PaddleOCR 云端路径)
    public static bool store_profile_paddleocr_token (string profile_name, string token) {
        if (profile_name.length == 0) return false;
        return store (profile_slot (SCHEMA_NAME_PADDLEOCR_TOKEN, profile_name), token);
    }

    public static string? load_profile_paddleocr_token (string profile_name) {
        if (profile_name.length == 0) return null;
        return lookup (profile_slot (SCHEMA_NAME_PADDLEOCR_TOKEN, profile_name));
    }
}
