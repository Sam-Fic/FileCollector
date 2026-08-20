#ifndef FILECOLLECTOR_WIN32_DPAPI_SHIM_H
#define FILECOLLECTOR_WIN32_DPAPI_SHIM_H

#include <windows.h>
#include <wincrypt.h>

/* Vala owns the FC_DATA_BLOB declaration in generated sources.  Keep the
 * ABI boundary opaque here so this header can be included before that code. */
BOOL fc_CryptProtectData(
    void *input,
    const char *description,
    void *optional_entropy,
    void *reserved,
    void *prompt_struct,
    DWORD flags,
    void *output
);

BOOL fc_CryptUnprotectData(
    void *input,
    void *description,
    void *optional_entropy,
    void *reserved,
    void *prompt_struct,
    DWORD flags,
    void *output
);

void fc_LocalFree(void *memory);

#endif
