#!/usr/bin/env python3
"""从翻转后的源码生成 po/zh_CN.po。

流程:
1. xgettext 提取 (由 meson i18n 或本脚本调用) 得到 pot (msgid=英文)
2. 用原 en.po (中文->英文) 与 FALLBACK 反向构建 英文->中文 映射
3. 把中文填进 zh_CN.po 的 msgstr
"""
import re
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PO_DIR = os.path.join(ROOT, "po")
EN_PO = os.path.join(ROOT, "en.po")
POTFILES = os.path.join(ROOT, "POTFILES")


def load_en_po():
    """返回 (zh->en 映射, 所有 en.po 原始块)。"""
    txt = open(EN_PO, encoding="utf-8").read()
    zh_en = {}
    for b in re.split(r"\n\n+", txt):
        m = re.search(r'msgid "(.*?)"', b, re.S)
        s = re.search(r'msgstr "(.*?)"', b, re.S)
        if not m:
            continue
        msgid = m.group(1)
        msgstr = s.group(1) if s else ""
        if not msgid:
            continue
        zh_en[msgid] = msgstr
    return zh_en


def load_fallback():
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    import flip_i18n
    return flip_i18n.FALLBACK


def build_en_zh(zh_en, fallback):
    en_zh = {}
    # en.po: 中文 -> 英文, 反向为 英文 -> 中文 (仅英文非空)
    for zh, en in zh_en.items():
        if en.strip():
            en_zh[en] = zh
    # fallback: 中文 -> 英文, 反向
    for zh, en in fallback.items():
        if en.strip():
            en_zh[en] = zh
    return en_zh


def extract_pot():
    os.makedirs(PO_DIR, exist_ok=True)
    pot = os.path.join(PO_DIR, "filecollector.pot")
    files = open(POTFILES, encoding="utf-8").read().split()
    files = [os.path.join(ROOT, f) for f in files]
    subprocess.run(
        ["xgettext", "--language=Vala", "--from-code=UTF-8",
         "--add-comments=TRANSLATORS", "--omit-header",
         "--keyword=_", "--keyword=dgettext:2", "--keyword=dcgettext:2",
         "--keyword=N_", "--keyword=Q_",
         "--output=" + pot] + files,
        check=True,
    )
    return pot


def main():
    zh_en = load_en_po()
    fallback = load_fallback()
    en_zh = build_en_zh(zh_en, fallback)

    pot = extract_pot()
    pot_txt = open(pot, encoding="utf-8").read()

    # 逐块替换 msgstr
    missing = []
    out_blocks = []
    for b in re.split(r'(?=\n\n)', pot_txt):
        if not b.strip():
            continue
        m = re.search(r'msgid "(.*?)"', b, re.S)
        if not m:
            out_blocks.append(b)
            continue
        msgid = m.group(1)
        if not msgid:  # 头部
            out_blocks.append(b)
            continue
        zh = en_zh.get(msgid)
        if zh is not None:
            # 格式符对齐: 保证 msgstr 包含 msgid 中的所有 %s/%d/%n 占位符
            import re as _re
            specs = _re.findall(r'%(?:[0-9]*\$)?[sdfcnu]', msgid)
            for sp in specs:
                if sp not in zh:
                    zh = zh.rstrip() + " " + sp
            # 替换 msgstr "" 为 msgstr "中文"
            nb = re.sub(r'msgstr ""', 'msgstr "%s"' % zh.replace('\\', '\\\\').replace('"', '\\"'), b, count=1)
            out_blocks.append(nb)
        else:
            # 无对应中文翻译 (多为本就英文的 CLI/UI 串): msgstr 回退为 msgid 自身
            nb = re.sub(r'msgstr ""', 'msgstr "%s"' % msgid.replace('\\', '\\\\').replace('"', '\\"'), b, count=1)
            out_blocks.append(nb)
    result = "".join(out_blocks)
    # 写 zh_CN.po
    zh_path = os.path.join(PO_DIR, "zh_CN.po")
    header = (
        'msgid ""\n'
        'msgstr ""\n'
        '"Project-Id-Version: filecollector\\n"\n'
        '"Report-Msgid-Bugs-To: \\n"\n'
        '"POT-Creation-Date: 2026-07-12\\n"\n'
        '"PO-Revision-Date: 2026-07-12 00:00+0800\\n"\n'
        '"Last-Translator: Sam-Fic\\n"\n'
        '"Language-Team: Chinese (China)\\n"\n'
        '"Language: zh_CN\\n"\n'
        '"MIME-Version: 1.0\\n"\n'
        '"Content-Type: text/plain; charset=UTF-8\\n"\n'
        '"Content-Transfer-Encoding: 8bit\\n"\n'
        '"Plural-Forms: nplurals=1; plural=0;\\n"\n'
    )
    # 丢弃 pot 自带的空 msgid 头部块 (避免重复 msgid "")
    body = re.sub(r'^msgid ""\nmsgstr ""\n(?:".*?\n)*\n', '', result, flags=re.S)
    open(zh_path, "w", encoding="utf-8").write(header + "\n" + body)
    print("zh_CN.po written:", zh_path)
    print("missing (英文msgid 无中文翻译):", len(missing))
    for x in missing[:20]:
        print("  MISSING:", x[:70])


if __name__ == "__main__":
    main()
