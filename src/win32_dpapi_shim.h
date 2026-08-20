#ifndef FILECOLLECTOR_WIN32_DPAPI_SHIM_H
#define FILECOLLECTOR_WIN32_DPAPI_SHIM_H

#include <windows.h>
#include <wincrypt.h>

struct _FC_DATA_BLOB {
    DWORD cbData;
    BYTE *pbData;
};

BOOL fc_CryptProtectData(
    struct _FC_DATA_BLOB *input,
    const char *description,
    struct _FC_DATA_BLOB *optional_entropy,
    void *reserved,
    void *prompt_struct,
    DWORD flags,
    struct _FC_DATA_BLOB *output
);

BOOL fc_CryptUnprotectData(
    struct _FC_DATA_BLOB *input,
    void *description,
    struct _FC_DATA_BLOB *optional_entropy,
    void *reserved,
    void *prompt_struct,
    DWORD flags,
    struct _FC_DATA_BLOB *output
);

void fc_LocalFree(void *memory);

#endif
