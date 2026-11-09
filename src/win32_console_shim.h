#ifndef FILECOLLECTOR_WIN32_CONSOLE_SHIM_H
#define FILECOLLECTOR_WIN32_CONSOLE_SHIM_H

#include <windows.h>

/* CLI 输出接管: exe 为 GUI 子系统 (GUI 启动不弹黑框), 在 cmd/PowerShell
 * 里直接跑 CLI 时 stdout 无句柄, 输出完全不可见。此函数在检测到该场景时
 * 附加父进程控制台并接管 std 流。Git Bash / CI 等管道环境不做任何事。 */
void win32_console_init (void);

#endif
