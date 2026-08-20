#ifndef FILECOLLECTOR_WIN32_DPAPI_SHIM_H
#define FILECOLLECTOR_WIN32_DPAPI_SHIM_H

#include <windows.h>
#include <wincrypt.h>

typedef struct {
    DWORD cbData;
    BYTE *pbData;
} FC_DATA_BLOB;

BOOL fc_CryptProtectData(
    FC_DATA_BLOB *input,
    const char *description,
    FC_DATA_BLOB *optional_entropy,
    void *reserved,
    void *prompt_struct,
    DWORD flags,
    FC_DATA_BLOB *output
);

BOOL fc_CryptUnprotectData(
    FC_DATA_BLOB *input,
    void *description,
    FC_DATA_BLOB *optional_entropy,
    void *reserved,
    void *prompt_struct,
    DWORD flags,
    FC_DATA_BLOB *output
);

void fc_LocalFree(void *memory);

#endif
