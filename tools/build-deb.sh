#!/usr/bin/env bash
# Build a native amd64 Debian package from the Meson install staging area.
set -euo pipefail

readonly APP_ID="filecollector"
readonly PACKAGE_NAME="filecollector"
readonly ARCHITECTURE="amd64"
readonly BUILD_DIR="build-deb"
readonly STAGING_DIR="deb-root"
readonly DIST_DIR="dist"

VERSION="$(sed -n "s/^[[:space:]]*version:[[:space:]]*'\([^']*\)'.*/\1/p" meson.build | head -n 1)"
if [[ -z "${VERSION}" ]]; then
  echo "Unable to read the project version from meson.build." >&2
  exit 1
fi

rm -rf "${BUILD_DIR}" "${STAGING_DIR}" "${DIST_DIR}" debian
trap 'rm -rf debian' EXIT

meson setup "${BUILD_DIR}" --prefix=/usr --buildtype=release
meson compile -C "${BUILD_DIR}"
meson test -C "${BUILD_DIR}" --print-errorlogs --num-processes=1

DESTDIR="${PWD}/${STAGING_DIR}" meson install -C "${BUILD_DIR}"
install -d "${STAGING_DIR}/DEBIAN" debian "${DIST_DIR}"

cat > debian/control <<'EOF'
Source: filecollector
Section: utils
Priority: optional
Maintainer: Sam-Fic <2401894494@qq.com>

Package: filecollector
Architecture: amd64
Description: File Collector
 A tool to collect files.
EOF

DEPENDENCIES="$(dpkg-shlibdeps -O "${STAGING_DIR}/usr/bin/${APP_ID}" | sed 's/^shlibs:Depends=//')"
if [[ -z "${DEPENDENCIES}" ]]; then
  echo "Unable to determine shared-library dependencies." >&2
  exit 1
fi

INSTALLED_SIZE="$(du -sk "${STAGING_DIR}/usr" | awk '{print $1}')"
cat > "${STAGING_DIR}/DEBIAN/control" <<EOF
Package: ${PACKAGE_NAME}
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${ARCHITECTURE}
Maintainer: Sam-Fic <2401894494@qq.com>
Homepage: https://github.com/Sam-Fic/FileCollector
Depends: ${DEPENDENCIES}
Installed-Size: ${INSTALLED_SIZE}
Description: File Collector (文件收集器)
 A cross-platform desktop tool for collecting, organizing and exporting
 files. Built with GTK4 / libadwaita.
EOF

PACKAGE_PATH="${DIST_DIR}/${PACKAGE_NAME}_${VERSION}_${ARCHITECTURE}.deb"
dpkg-deb --build --root-owner-group "${STAGING_DIR}" "${PACKAGE_PATH}"
dpkg-deb --info "${PACKAGE_PATH}"
dpkg-deb --contents "${PACKAGE_PATH}"
sha256sum "${PACKAGE_PATH}" > "${PACKAGE_PATH}.sha256"

echo "Built ${PACKAGE_PATH}"
