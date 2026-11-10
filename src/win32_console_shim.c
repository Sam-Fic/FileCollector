#include "win32_console_shim.h"

#include <stdio.h>

void win32_console_init (void) {
    /* stdout 已有有效句柄时 (Git Bash / CI 的管道、文件重定向、已附加的
     * 控制台) 不做任何事, 保住管道输出。GUI 子系统直启时 std 句柄为空,
     * GetFileType 返回 FILE_TYPE_UNKNOWN 并置 ERROR_INVALID_HANDLE。 */
    SetLastError (0);
    DWORD out_type = GetFileType (GetStdHandle (STD_OUTPUT_HANDLE));
    if (!(out_type == FILE_TYPE_UNKNOWN && GetLastError () == ERROR_INVALID_HANDLE)) {
        return;
    }

    /* 父进程没有控制台 (双击 / start 启动) 时附加失败, 直接返回, GUI 照常
     * 运行; 有控制台 (cmd / PowerShell 跑 CLI) 时接管 std 流。 */
    if (!AttachConsole (ATTACH_PARENT_PROCESS)) {
        return;
    }
    freopen ("CONOUT$", "w", stdout);
    freopen ("CONOUT$", "w", stderr);
    /* 程序输出恒为 UTF-8, 控制台默认码页 (中文系统 CP936) 下会乱码 */
    SetConsoleOutputCP (CP_UTF8);
}
