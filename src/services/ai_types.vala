/* AI 助手共享类型定义.
 *
 * 把 AISystemSnapshot 结构体和 AIStateProvider 委托独立出来, 避免
 * ai_panel.c 生成的 C 代码被 window.c 引用时出现隐式声明错误
 * (Vala 不会为非 GObject 的 struct/委托自动生成头文件).
 */

using Gtk;

public struct AISystemSnapshot {
    public string work_dir;            // 当前工作目录
    public string[] selected_paths;    // 已勾选文件 (相对 work_dir)
    public string[] custom_instructions; // 自定义文本指令列表
    public string mode;                // "default" | "directory" | "single"
    public string file_extension;      // 单文件模式下的扩展名
    public string file_label;          // 标签
    public int max_files;
    public bool use_absolute;          // 绝对 / 相对路径导出模式
    public bool show_header;           // 是否在导出文件中写入工作目录头
}

public delegate AISystemSnapshot AIStateProvider ();
public delegate string AIToolExecutor (string name, Json.Node args) throws GLib.Error;
