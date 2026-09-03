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
 * 查询 keychain. shim 内部 g_malloc 缓冲区并 g_strdup 出一份新缓冲区作为
 * *out_buf 返回 (Vala 端按 owned string 接收, 由 GLib.Object 释药器管理).
 *
 * 这样设计是为了避免 Vala 与 C 双重释药问题: Vala 对 out string? 默认
 * 会调用 _g_free0, 而 shim 出的 buffer 也需 g_free. 分两步 strdup 让
 * Vala 接管副本, shim 自己 free 原 buffer, 不冲突.
 *
 * @param service  UTF-8 service name
 * @param service_len  byte length
 * @param account  UTF-8 account name
 * @param account_len  byte length
 * @param out_buf  out: caller-owned NUL-terminated string (g_strdup'd from
 *                 keychain contents). NULL when entry not found.
 * @param out_buf_len  out: byte length excluding trailing NUL
 * @return 0 on success, 1 if not found, negative OSStatus on error.
 */
int fc_keychain_find(const char *service, uint32_t service_len,
                     const char *account, uint32_t account_len,
                     char **out_buf, uint32_t *out_buf_len);

/**
 * 删除 (service, account) 对应的条目. 不存在时返回 0 (成功语义).
 */
int fc_keychain_delete(const char *service, uint32_t service_len,
                       const char *account, uint32_t account_len);

#endif /* FILECOLLECTOR_MACOS_KEYCHAIN_SHIM_H */
