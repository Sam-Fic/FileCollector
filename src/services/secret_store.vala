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

#if WINDOWS
    // ─── Windows: DPAPI ────────────────────────────────────────────────
    // 通过 CCode 直接声明 Win32 API, 不引入额外依赖。
    [CCode (cheader_filename = "windows.h")]
    private extern static uint CryptProtectData (
        void* pDataIn, string? szDataDescr,
        void* pOptionalEntropy, void* pReserved,
        void* pPromptStruct, uint dwFlags, void* pDataOut);

    [CCode (cheader_filename = "windows.h")]
    private extern static uint CryptUnprotectData (
        void* pDataIn, void* ppszDataDescr,
        void* pOptionalEntropy, void* pReserved,
        void* pPromptStruct, uint dwFlags, void* pDataOut);

    [CCode (cheader_filename = "windows.h", cname = "DATA_BLOB")]
    private struct DATA_BLOB {
        public uint cbData;
        public void* pbData;
    }

    [CCode (cheader_filename = "windows.h")]
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

    private static bool dpapi_store (string slot, string value) {
        unowned uint8[] data = value.data;
        var in_blob = DATA_BLOB () { cbData = data.length, pbData = data };
        DATA_BLOB out_blob = DATA_BLOB ();
        if (CryptProtectData (&in_blob, "filecollector", null, null, null, 0, &out_blob) == 0)
            return false;
        try {
            FileUtils.set_data (secret_file (slot),
                (uint8[]) (out_blob.pbData[0:out_blob.cbData]));
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
            DATA_BLOB out_blob = DATA_BLOB ();
            if (CryptUnprotectData (&in_blob, null, null, null, null, 0, &out_blob) == 0)
                return null;
            var buf = (uint8[]) (out_blob.pbData[0:out_blob.cbData]);
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
    [CCode (cheader_filename = "Security/Security.h")]
    private extern static int SecKeychainAddGenericPassword (
        void* keychain, uint32 serviceNameLength, string serviceName,
        uint32 accountNameLength, string accountName,
        uint32 passwordLength, void* passwordData,
        void* itemRef);

    [CCode (cheader_filename = "Security/Security.h")]
    private extern static int SecKeychainFindGenericPassword (
        void* keychainOrArray, uint32 serviceNameLength, string serviceName,
        uint32 accountNameLength, string accountName,
        uint32* passwordLength, void** passwordData, void* itemRef);

    [CCode (cheader_filename = "Security/Security.h")]
    private extern static int SecKeychainItemFreeContent (
        void* attrList, void* data);

    [CCode (cheader_filename = "Security/Security.h")]
    private extern static int SecKeychainItemDelete (void* itemRef);

    [CCode (cheader_filename = "CoreFoundation/CoreFoundation.h")]
    private extern static void CFRelease (void* cf);

    private static int macos_store (string slot, string api_key) {
        // 先删后写, 避免重复条目
        macos_lookup (slot);
        unowned uint8[] pw = api_key.data;
        return SecKeychainAddGenericPassword (
            null, (uint32) slot.length, slot,
            (uint32) slot.length, slot,
            (uint32) pw.length, pw, null);
    }

    private static string? macos_lookup (string slot) {
        uint32 len = 0;
        void* data = null;
        void* item = null;
        int rc = SecKeychainFindGenericPassword (
            null, (uint32) slot.length, slot,
            (uint32) slot.length, slot,
            &len, &data, &item);
        if (rc != 0 || data == null) return null;
        unowned uint8[] view = (uint8[]) ((uint8*) data);
        view.length = (int) len;
        string result = (string) view;
        SecKeychainItemFreeContent (null, data);
        if (item != null) {
            SecKeychainItemDelete (item);
            CFRelease (item);
        }
        return result;
    }

    public static bool store (string slot, string api_key) {
        if (api_key.length == 0) {
            // 清空: 找到即删
            macos_lookup (slot);
            return true;
        }
        return macos_store (slot, api_key) == 0;
    }

    public static string? lookup (string slot) {
        return macos_lookup (slot);
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
}
