#!/usr/bin/env python3
"""Verify that every symbolic icon referenced by the application exists in a packaged GTK theme."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ICON_RE = re.compile(r'"([A-Za-z0-9-]+-symbolic)"')
SOURCE_SUFFIXES = {".vala", ".blp"}


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify_gnome_icon_theme.py <icons-root>", file=sys.stderr)
        return 2

    icons_root = Path(sys.argv[1])
    project_root = Path(__file__).resolve().parent.parent
    adwaita_index = icons_root / "Adwaita" / "index.theme"
    hicolor_index = icons_root / "hicolor" / "index.theme"
    if not adwaita_index.is_file() or not hicolor_index.is_file():
        print("Packaged icon root must contain Adwaita/index.theme and hicolor/index.theme.", file=sys.stderr)
        return 1

    names: set[str] = set()
    for source in (project_root / "src").rglob("*"):
        if source.suffix not in SOURCE_SUFFIXES:
            continue
        for line in source.read_text(encoding="utf-8").splitlines():
            # 项目 Vala/Blueprint 的单行注释不属于运行时图标引用。
            names.update(ICON_RE.findall(line.split("//", 1)[0]))

    missing: list[str] = []
    for name in sorted(names):
        if not any(icons_root.rglob(f"{name}.svg")):
            missing.append(name)

    if missing:
        print("Missing symbolic icons from packaged GTK themes:", file=sys.stderr)
        print("\n".join(f"  - {name}" for name in missing), file=sys.stderr)
        return 1

    print(f"Verified {len(names)} symbolic icon names against {icons_root}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
