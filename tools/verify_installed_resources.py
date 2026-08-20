#!/usr/bin/env python3
"""Verify FileCollector resources after Meson installs them into a package root."""

from __future__ import annotations

import os
import sys
from pathlib import Path


REQUIRED_RELATIVE_PATHS = (
    Path("filecollector/gtksourceview-5/styles/filecollector-dark.xml"),
    Path("filecollector/gtksourceview-5/styles/filecollector-light.xml"),
    Path("icons/hicolor/scalable/actions/xsi-git-symbolic.svg"),
    Path("icons/hicolor/scalable/actions/xsi-text-case-symbolic.svg"),
)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify_installed_resources.py <datadir>", file=sys.stderr)
        return 2

    # Meson supplies this value during staged and regular installs. It already
    # incorporates DESTDIR when one is used by a package builder.
    install_prefix = os.environ.get("MESON_INSTALL_DESTDIR_PREFIX")
    if not install_prefix:
        print("MESON_INSTALL_DESTDIR_PREFIX is not set by Meson.", file=sys.stderr)
        return 2

    data_root = Path(install_prefix) / sys.argv[1]
    missing = [path for path in REQUIRED_RELATIVE_PATHS if not (data_root / path).is_file()]
    if missing:
        print("Required packaged resources are missing:", file=sys.stderr)
        print("\n".join(f"  - {data_root / path}" for path in missing), file=sys.stderr)
        return 1

    print(f"Verified {len(REQUIRED_RELATIVE_PATHS)} installed FileCollector resources in {data_root}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
