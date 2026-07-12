#!/usr/bin/env python3
"""翻转 i18n 方向: 把源码里 _(\"中文\") 替换为 _(\"English\")。

- 主映射来自现有 en.po (中文 msgid -> 英文 msgstr)
- 缺失/空英文的, 用 FALLBACK 手工补译 (key/value 均用字面 \\n 与源码/xgettext 对齐)
- 保留 @ 前缀形态 (dgettext context)
- 跳过含 + 拼接的 _() 调用 (单独手工处理), 并打印出来

用法: python3 tools/flip_i18n.py [--dry-run]
"""
import re
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
EN_PO = os.path.join(ROOT, "en.po")

# 32 条 en.po 缺失/空英文, 人工补译的中文 -> 英文
# 注意: key 与 value 中的换行均为字面 \\n (两字符), 与 Vala 源码及 xgettext 提取一致
FALLBACK = {
    "# 工作目录绝对路径: %s\\n\\n": "# Working directory absolute path: %s\\n\\n",
    "AI 转换失败\\n点击重试转换": "AI conversion failed\\nClick to retry conversion",
    "[AI 转换失败，点击工具栏的重试按钮可重新转换]": "[AI conversion failed; click the retry button on the toolbar to reconvert]",
    "AI 转换完成\\n点击强制重新调用视觉语言大模型 (VLM) 转换": "AI conversion complete\\nClick to force re-invoke VLM conversion",
    "[应用模板: %s]\\n%s": "[Apply template: %s]\\n%s",
    "[提示: 起始行(%d)大于结束行(%d)，已自动交换]\\n": "[Hint: start line (%d) > end line (%d), auto-swapped]\\n",
    "\\n…(内容过长, 已截断)": "\\n...(content too long, truncated)",
    "\\n跳过 %d 个:\\n": "\\nSkipped %d:\\n",
    "，跳过 %d 个": ", skipped %d",
    "你好, 我是 AI 编排助手。告诉我你想收集哪些文件, 我来帮你编排。\\n": "Hello, I am the AI orchestration assistant. Tell me which files you want to collect and I will help you organize them.\\n",
    "使用 HTTP (非 HTTPS) 端点时，API 密钥将在网络中明文传输，存在安全风险。": "Using an HTTP (non-HTTPS) endpoint transmits the API key in plaintext over the network, posing a security risk.",
    "关闭后 AI 边栏会保留, 但不会发送任何请求": "After closing, the AI sidebar is kept but no requests are sent",
    "在 AI 助手输入框中输入 \"/\" + 指令 ID 即可触发该模板。\\n": "Type \"/\" + command ID in the AI assistant input box to trigger this template.\\n",
    "已自动交换起始/结束行。": "Start/end lines auto-swapped.",
    "已读取本地缓存\\n点击强制重新调用视觉语言大模型 (VLM) 转换": "Local cache loaded\\nClick to force re-invoke VLM conversion",
    "当前 Git 仓库中还没有任何提交。完成首次 git commit 后，提交历史将显示在此处。": "The current Git repository has no commits yet. The commit history will appear here after the first git commit.",
    "当前工作目录不是一个 Git 仓库，无法读取提交历史。请在该目录下执行 git init 进行初始化，或在包含版本库的工作目录中打开本应用。": "The current working directory is not a Git repository, so commit history cannot be read. Run git init there, or open the app in a working directory that contains a repository.",
    "当前编排列表中有未保存的内容。\\n关闭后下次启动将不再提示恢复, 确定要关闭吗？": "There is unsaved content in the current orchestration list.\\nAfter closing, recovery will not be prompted on next launch. Close anyway?",
    "您正在配置 HTTP (非 HTTPS) 端点。\\n\\n": "You are configuring an HTTP (non-HTTPS) endpoint.\\n\\n",
    "打开一个文件夹作为工作目录，即可开始收集与编排文件。": "Open a folder as the working directory to start collecting and orchestrating files.",
    "未找到匹配项": "No matches found",
    "没有文件包含该关键词。请尝试其他关键词或调整搜索选项。": "No files contain this keyword. Try another keyword or adjust search options.",
    "真正在调用 VLM 处理中": "Actually invoking VLM for processing",
    "行范围 %s 起始行大于结束行，已自动交换": "Line range %s: start line > end line, auto-swapped",
    "设置目标 LLM 的最大 Token 窗口，用于进度条预警。": "Set the target LLM's maximum token window, used for progress bar warnings.",
    "语言设置已保存，重启应用后生效。是否现在重启？": "Language setting saved; takes effect after restart. Restart now?",
    "输入关键词并按下 Enter 或点击搜索按钮，即可在整个工作目录中查找匹配的代码与文本。": "Enter a keyword and press Enter or click search to find matching code and text across the working directory.",
    "输入行范围，用逗号分隔，用连字符表示区间。\\n例如：1-10,15,20-25": "Enter line ranges, comma-separated, hyphen for intervals.\\nExample: 1-10,15,20-25",
    "这些目录不会出现在文件树中，也不会被自动收集。": "These directories will not appear in the file tree and will not be collected automatically.",
    "这将删除当前工作目录下的 .filecollector_cache 隐藏文件夹。\\n下次处理图片及 PDF 等文件时，将重新调用 VLM 并消耗 API Token。": "This will delete the .filecollector_cache hidden folder under the working directory.\\nNext time images/PDFs are processed, VLM will be re-invoked and consume API tokens.",
    "这将导致 API 密钥在传输过程中以明文形式发送，存在被第三方截获的风险。\\n\\n": "This will send the API key in plaintext during transmission, risking interception by third parties.\\n\\n",
    "这将撤销此消息之后 AI 的所有回复以及对文件列表的修改。是否继续？": "This will undo all AI replies after this message and modifications to the file list. Continue?",
    "配置 OpenAI 兼容 API，即可在 AI 边栏使用自然语言编排文件。\\n支持 OpenAI、Azure OpenAI 及任何兼容端点（例如本地 Ollama）。": "Configure an OpenAI-compatible API to orchestrate files with natural language in the AI sidebar.\\nSupports OpenAI, Azure OpenAI, and any compatible endpoint (e.g. local Ollama).",
    "配置视觉语言大模型 (VLM) API，用于将 PDF、Word、PPT、图片等文件转换为 Markdown。": "Configure the Vision Language Model (VLM) API to convert PDF, Word, PPT, images, etc. into Markdown.",
    # --- window.blp UI 标签 (从未进过 en.po, 需补英文作为新 msgid) ---
    "FileCollector - 文件收集与编排工具": "FileCollector - File Collection & Orchestration Tool",
    "显示 / 隐藏 AI 助手 (Ctrl+J)": "Show / Hide AI Assistant (Ctrl+J)",
    "打开工作目录": "Open Working Directory",
    "切换到 Git 提交历史": "Switch to Git Commit History",
    "全局内容搜索 (Ctrl+Shift+F)": "Global Content Search (Ctrl+Shift+F)",
    "撤销": "Undo",
    "重做": "Redo",
    "未设置工作目录": "No working directory set",
    "资源管理器": "Explorer",
    "搜索…": "Search…",
    "搜索提交信息…": "Search commit messages…",
    "输出编排列表": "Output Orchestration List",
    "添加外部文件": "Add External File",
    "上方插入文本": "Insert Text Above",
    "下方插入文本": "Insert Text Below",
    "上移": "Move Up",
    "下移": "Move Down",
    "AI 生成阅读指南": "AI Reading Guide",
    "删除": "Delete",
    "清空": "Clear",
    "一键添加所有改动文件": "Add All Changed Files",
    "导出工作区 Diff": "Export Workspace Diff",
    "导出选中 Commit Diff": "Export Selected Commit Diff",
    "使用相对路径": "Use Relative Paths",
    "使用绝对路径": "Use Absolute Paths",
    "在文件头部标注工作目录信息": "Annotate working directory info at file header",
    "预估上下文: 0 / 128000 Tokens": "Estimated context: 0 / 128000 Tokens",
    "生成合并文本": "Generate Merged Text",
    "更多操作": "More Actions",
    "预览": "Preview",
    "重新进行 AI 转换": "Re-run AI Conversion",
    "打开项目...": "Open Project...",
    "保存项目": "Save Project",
    "项目另存为...": "Save Project As...",
    "常用语管理...": "Manage Phrases...",
    "场景模板管理...": "Manage Scene Templates...",
    "偏好设置...": "Preferences...",
    "清除工作区缓存": "Clear Workspace Cache",
    "键盘快捷键...": "Keyboard Shortcuts...",
    "关于 FileCollector": "About FileCollector",
    "生成合并文本到剪贴板": "Copy Merged Text to Clipboard",
    "导出为 ZIP": "Export as ZIP",
}


def load_en_po():
    txt = open(EN_PO, encoding="utf-8").read()
    mapping = {}
    for b in re.split(r"\n\n+", txt):
        m = re.search(r'msgid "(.*?)"', b, re.S)
        s = re.search(r'msgstr "(.*?)"', b, re.S)
        if not m:
            continue
        msgid = m.group(1)
        msgstr = s.group(1) if s else ""
        if not msgid:
            continue
        mapping[msgid] = msgstr
    return mapping


def main():
    dry = "--dry-run" in sys.argv
    mapping = load_en_po()
    merged = dict(mapping)
    merged.update(FALLBACK)

    pat = re.compile(r'_\((@?)"((?:[^"\\]|\\.)*)"\)')

    replaced = 0
    skipped = 0
    skipped_examples = []
    unmatched = 0
    unmatched_examples = []

    for root, _, files in os.walk(SRC):
        for f in files:
            if not (f.endswith(".vala") or f.endswith(".blp")):
                continue
            p = os.path.join(root, f)
            s = open(p, encoding="utf-8").read()
            out = []
            last = 0
            for m in pat.finditer(s):
                # 跳过后面紧跟 + 的拼接 _() 调用 (已手工处理)
                after = s[m.end():m.end()+8]
                if re.match(r'\s*\+', after):
                    skipped += 1
                    out.append(s[last:m.end()])
                    last = m.end()
                    continue
                zh = m.group(2)
                if zh.isascii() or not zh:
                    out.append(s[last:m.end()])
                    last = m.end()
                    continue
                if zh in merged and merged[zh].strip():
                    en = merged[zh]
                    out.append(s[last:m.start()] + '_(' + m.group(1) + '"' + en + '")')
                    replaced += 1
                else:
                    out.append(s[last:m.end()])
                    unmatched += 1
                    unmatched_examples.append((os.path.relpath(p, ROOT), zh[:70]))
                last = m.end()
            out.append(s[last:])
            if not dry:
                open(p, "w", encoding="utf-8").write("".join(out))

    print(f"replaced: {replaced}")
    print(f"skipped (concat +): {skipped} -> {skipped_examples}")
    print(f"unmatched (no english): {unmatched}")
    for e in unmatched_examples[:30]:
        print("  UNMATCHED", e)


if __name__ == "__main__":
    main()
