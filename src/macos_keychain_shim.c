#include "macos_keychain_shim.h"
#import <Security/Security.h>

/* 内部工具: 把 UTF-8 (length, data) 包成 CFString, 失败时返回 NULL.
 * 释放责任交回调用方 (CFRelease). */
static CFStringRef make_cfstring(const char *bytes, uint32_t len) {
    if (bytes == NULL) return NULL;
    /* CFStringCreateWithBytes 不要求 NUL 终止, 但需要明确字符集. */
    CFStringRef s = CFStringCreateWithBytes(
        kCFAllocatorDefault,
        (const UInt8 *) bytes,
        (CFIndex) len,
        kCFStringEncodingUTF8,
        /* isExternalRepresentation */ false);
    return s;
}

/* 内部工具: CFDataRef -> char* 拷贝 (到调用方 buffer), 并写回实际长度. */
static int copy_cfdata_to_buffer(CFDataRef data, char *out_buf, uint32_t *out_buf_len) {
    if (data == NULL) return -1;
    CFIndex len = CFDataGetLength(data);
    if (len < 0) len = 0;
    if (out_buf == NULL) {
        /* 调用方只想知道所需大小. */
        *out_buf_len = (uint32_t) len;
        return (int) len;  /* 正数: 提示调用方分配更大 buffer */
    }
    if (*out_buf_len < (uint32_t) len) {
        /* buffer 太小, 返回所需大小让调用方重试. */
        *out_buf_len = (uint32_t) len;
        return (int) len;
    }
    CFDataGetBytes(data, CFRangeMake(0, len), (UInt8 *) out_buf);
    *out_buf_len = (uint32_t) len;
    return 0;
}

int fc_keychain_add(const char *service, uint32_t service_len,
                    const char *account, uint32_t account_len,
                    const char *password, uint32_t password_len) {
    if (service == NULL || account == NULL || password == NULL) {
        return -1;  /* errSecParam */
    }

    CFStringRef cf_service = make_cfstring(service, service_len);
    CFStringRef cf_account = make_cfstring(account, account_len);
    if (cf_service == NULL || cf_account == NULL) {
        if (cf_service) CFRelease(cf_service);
        if (cf_account) CFRelease(cf_account);
        return -2;
    }

    CFDataRef cf_password = CFDataCreate(
        kCFAllocatorDefault,
        (const UInt8 *) password,
        (CFIndex) password_len);
    if (cf_password == NULL) {
        CFRelease(cf_service);
        CFRelease(cf_account);
        return -3;
    }

    /* 查询是否已存在 (用 kSecClass + kSecAttrService + kSecAttrAccount 三元组). */
    CFMutableDictionaryRef query = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(query, kSecAttrService, cf_service);
    CFDictionarySetValue(query, kSecAttrAccount, cf_account);

    /* 已存在 -> 先删, 避免 errSecDuplicateItem (-25299). */
    OSStatus del_rc = SecItemDelete(query);
    (void) del_rc;  /* 不存在时 errSecItemNotFound 也是 OK */

    /* 写入: 加上 kSecAttrAccessible = WhenUnlocked (默认 user keychain). */
    CFDictionarySetValue(query, kSecValueData, cf_password);
    CFDictionarySetValue(query, kSecAttrAccessible, kSecAttrAccessibleWhenUnlocked);

    OSStatus rc = SecItemAdd(query, NULL);
    if (rc != errSecSuccess) {
        /* 写入失败时清理已分配资源. */
        CFRelease(query);
        CFRelease(cf_service);
        CFRelease(cf_account);
        CFRelease(cf_password);
        return (int) rc;  /* 负 OSStatus, 方便 Vala 端检查 */
    }

    CFRelease(query);
    CFRelease(cf_service);
    CFRelease(cf_account);
    CFRelease(cf_password);
    return 0;
}

int fc_keychain_find(const char *service, uint32_t service_len,
                     const char *account, uint32_t account_len,
                     char *out_buf, uint32_t *out_buf_len) {
    if (service == NULL || account == NULL || out_buf_len == NULL) {
        return -1;
    }

    CFStringRef cf_service = make_cfstring(service, service_len);
    CFStringRef cf_account = make_cfstring(account, account_len);
    if (cf_service == NULL || cf_account == NULL) {
        if (cf_service) CFRelease(cf_service);
        if (cf_account) CFRelease(cf_account);
        return -2;
    }

    CFMutableDictionaryRef query = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(query, kSecAttrService, cf_service);
    CFDictionarySetValue(query, kSecAttrAccount, cf_account);
    CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
    CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);

    CFTypeRef result = NULL;
    OSStatus rc = SecItemCopyMatching(query, &result);
    CFRelease(query);
    CFRelease(cf_service);
    CFRelease(cf_account);

    if (rc == errSecItemNotFound) {
        /* 不存在视为未找到, 不算错误. */
        *out_buf_len = 0;
        if (out_buf != NULL && *out_buf_len > 0) out_buf[0] = '\0';
        return 0;
    }
    if (rc != errSecSuccess) {
        if (result) CFRelease(result);
        return (int) rc;
    }
    if (result == NULL) {
        return -4;
    }

    int copy_rc = copy_cfdata_to_buffer((CFDataRef) result, out_buf, out_buf_len);
    CFRelease(result);

    if (copy_rc > 0) {
        /* buffer 不足, 返回正值作为所需大小提示. */
        return copy_rc;
    }
    return copy_rc;  /* 0 或负错误码 */
}

int fc_keychain_delete(const char *service, uint32_t service_len,
                       const char *account, uint32_t account_len) {
    if (service == NULL || account == NULL) return -1;

    CFStringRef cf_service = make_cfstring(service, service_len);
    CFStringRef cf_account = make_cfstring(account, account_len);
    if (cf_service == NULL || cf_account == NULL) {
        if (cf_service) CFRelease(cf_service);
        if (cf_account) CFRelease(cf_account);
        return -2;
    }

    CFMutableDictionaryRef query = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(query, kSecAttrService, cf_service);
    CFDictionarySetValue(query, kSecAttrAccount, cf_account);

    OSStatus rc = SecItemDelete(query);
    CFRelease(query);
    CFRelease(cf_service);
    CFRelease(cf_account);

    if (rc == errSecSuccess || rc == errSecItemNotFound) {
        return 0;
    }
    return (int) rc;
}
