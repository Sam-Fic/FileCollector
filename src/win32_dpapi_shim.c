#include "win32_dpapi_shim.h"

static wchar_t *utf8_to_wide(const char *text) {
    if (text == NULL || text[0] == '\0') {
        return NULL;
    }

    int length = MultiByteToWideChar(CP_UTF8, 0, text, -1, NULL, 0);
    if (length <= 0) {
        return NULL;
    }

    wchar_t *result = (wchar_t *) LocalAlloc(LMEM_FIXED, (SIZE_T) length * sizeof(wchar_t));
    if (result == NULL) {
        return NULL;
    }

    if (MultiByteToWideChar(CP_UTF8, 0, text, -1, result, length) <= 0) {
        LocalFree(result);
        return NULL;
    }

    return result;
}

BOOL fc_CryptProtectData(
    FC_DATA_BLOB *input,
    const char *description,
    FC_DATA_BLOB *optional_entropy,
    void *reserved,
    void *prompt_struct,
    DWORD flags,
    FC_DATA_BLOB *output
) {
    wchar_t *wide_description = utf8_to_wide(description);
    BOOL success = CryptProtectData(
        (DATA_BLOB *) input,
        wide_description,
        (DATA_BLOB *) optional_entropy,
        reserved,
        (CRYPTPROTECT_PROMPTSTRUCT *) prompt_struct,
        flags,
        (DATA_BLOB *) output
    );
    if (wide_description != NULL) {
        LocalFree(wide_description);
    }
    return success;
}

BOOL fc_CryptUnprotectData(
    FC_DATA_BLOB *input,
    void *description,
    FC_DATA_BLOB *optional_entropy,
    void *reserved,
    void *prompt_struct,
    DWORD flags,
    FC_DATA_BLOB *output
) {
    return CryptUnprotectData(
        (DATA_BLOB *) input,
        (LPWSTR *) description,
        (DATA_BLOB *) optional_entropy,
        reserved,
        (CRYPTPROTECT_PROMPTSTRUCT *) prompt_struct,
        flags,
        (DATA_BLOB *) output
    );
}

void fc_LocalFree(void *memory) {
    if (memory != NULL) {
        LocalFree((HLOCAL) memory);
    }
}
