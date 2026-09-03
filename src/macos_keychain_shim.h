#ifndef FILECOLLECTOR_MACOS_KEYCHAIN_SHIM_H
#define FILECOLLECTOR_MACOS_KEYCHAIN_SHIM_H

#include <stdint.h>
#include <stdbool.h>
#include <CoreFoundation/CoreFoundation.h>

/* Modern macOS Keychain API (SecItem*). Replaces the deprecated
 * SecKeychain* family that was removed in macOS 14 SDK.
 *
 * Each function takes UTF-8 service+account strings and a UTF-8 password
 * (caller-owned buffers). Return values follow the convention:
 *   0     = success
 *   < 0   = platform/OSStatus error (negative for easy errno-style checks)
 *
 * The C shim owns the CFDictionary bookkeeping so Vala callers can stay
 * type-safe on managed strings.
 */

/**
 * 写入 keychain. 若同 (service, account) 条目已存在则覆盖 (先删后写).
 * @param service  UTF-8 service name, e.g. "io.github.sam_fic.filecollector"
 * @param service_len  byte length, excluding trailing NUL
 * @param account  UTF-8 account name, e.g. "io.github.sam_fic.filecollector.api_key"
 * @param account_len  byte length
 * @param password  UTF-8 password bytes (caller-provided, not NUL-terminated required)
 * @param password_len  byte length
 * @return 0 on success, non-zero OSStatus on failure.
 */
int fc_keychain_add(const char *service, uint32_t service_len,
                    const char *account, uint32_t account_len,
                    const char *password, uint32_t password_len);

/**
 * 查询 keychain. 返回的密码通过回调传出 (避免 glib 与 CoreFoundation 内存模型冲突).
 *
 * @param service  UTF-8 service name
 * @param service_len  byte length
 * @param account  UTF-8 account name
 * @param account_len  byte length
 * @param out_buf  caller-provided buffer; if too small, returns required size
 *                via out_buf_len and caller should retry with a larger buffer.
 *                If out_buf is NULL, only writes the required size to out_buf_len.
 * @param out_buf_len  in/out: caller provides buffer size, shim writes actual size
 * @return 0 on success, positive required-size hint when buffer too small,
 *         negative OSStatus on error.
 */
int fc_keychain_find(const char *service, uint32_t service_len,
                     const char *account, uint32_t account_len,
                     char *out_buf, uint32_t *out_buf_len);

/**
 * 删除 (service, account) 对应的条目. 不存在时返回 0 (成功语义).
 */
int fc_keychain_delete(const char *service, uint32_t service_len,
                       const char *account, uint32_t account_len);

#endif /* FILECOLLECTOR_MACOS_KEYCHAIN_SHIM_H */
