#!/usr/bin/env bash
# Build a self-contained Windows x64 portable ZIP in an MSYS2 MINGW64 shell.
set -euo pipefail

readonly BUILD_DIR="build-windows"
readonly STAGING_DIR="staging"
readonly DIST_DIR="dist"
readonly INSTALL_ROOT="install-windows"
readonly CMARK_VERSION="0.29.0.gfm.13"
readonly CMARK_ARCHIVE="/tmp/cmark-gfm-${CMARK_VERSION}.tar.gz"
readonly CMARK_SOURCE="/tmp/cmark-gfm-${CMARK_VERSION}"
readonly CMARK_BUILD="/tmp/cmark-gfm-build-${CMARK_VERSION}"

VERSION="$(sed -n "s/^[[:space:]]*version:[[:space:]]*'\([^']*\)'.*/\1/p" meson.build | head -n 1)"
if [[ -z "${VERSION}" ]]; then
  echo "Unable to read the project version from meson.build." >&2
  exit 1
fi

export PYTHONUTF8=1
export LANG=C.UTF-8
export PKG_CONFIG_PATH="/mingw64/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CPATH="/mingw64/include:${CPATH:-}"
export LIBRARY_PATH="/mingw64/lib:${LIBRARY_PATH:-}"

rm -rf "${BUILD_DIR}" "${STAGING_DIR}" "${DIST_DIR}" "${INSTALL_ROOT}" "${CMARK_SOURCE}" "${CMARK_BUILD}"
mkdir -p "${DIST_DIR}"

curl --fail --location --retry 3 --output "${CMARK_ARCHIVE}" \
  "https://github.com/github/cmark-gfm/archive/refs/tags/${CMARK_VERSION}.tar.gz"
tar -xzf "${CMARK_ARCHIVE}" -C /tmp

cmake -S "${CMARK_SOURCE}" -B "${CMARK_BUILD}" \
  -G Ninja \
  -DCMAKE_INSTALL_PREFIX=/mingw64 \
  -DCMARK_TESTS=OFF \
  -DCMARK_STATIC=ON \
  -DCMARK_SHARED=OFF \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "${CMARK_BUILD}"
cmake --install "${CMARK_BUILD}"

meson setup "${BUILD_DIR}" --prefix=/usr --buildtype=release
meson compile -C "${BUILD_DIR}"
meson test -C "${BUILD_DIR}" --print-errorlogs --num-processes=1
DESTDIR="${PWD}/${INSTALL_ROOT}" meson install -C "${BUILD_DIR}"

install -d \
  "${STAGING_DIR}/bin" \
  "${STAGING_DIR}/lib/gdk-pixbuf-2.0/2.10.0/loaders" \
  "${STAGING_DIR}/lib/gio/modules" \
  "${STAGING_DIR}/share/glib-2.0/schemas" \
  "${STAGING_DIR}/share/icons"

cp "${BUILD_DIR}/filecollector.exe" "${STAGING_DIR}/bin/filecollector.exe"
python3 tools/collect_dlls.py "${STAGING_DIR}/bin/filecollector.exe" "${STAGING_DIR}/bin"

cp -r data "${STAGING_DIR}/share/data"
if [[ -d "${INSTALL_ROOT}/usr/share/locale" ]]; then
  cp -r "${INSTALL_ROOT}/usr/share/locale" "${STAGING_DIR}/locale"
fi

# Dynamically loaded GTK/GIO components are not visible to ldd and must be staged explicitly.
cp /mingw64/lib/gdk-pixbuf-2.0/2.10.0/loaders/*.dll \
  "${STAGING_DIR}/lib/gdk-pixbuf-2.0/2.10.0/loaders/"
cp /mingw64/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache \
  "${STAGING_DIR}/lib/gdk-pixbuf-2.0/2.10.0/"
cp /mingw64/share/glib-2.0/schemas/gschemas.compiled \
  "${STAGING_DIR}/share/glib-2.0/schemas/"
# 打包完整 GNOME 图标主题（含全部 symbolic SVG），而非仅应用图标。
# 这样 Windows 与 GNOME 桌面使用同一套 Adwaita 图标名称和视觉语言。
cp -r /mingw64/share/icons/Adwaita "${STAGING_DIR}/share/icons/"
cp -r /mingw64/share/icons/hicolor "${STAGING_DIR}/share/icons/"
test -f "${STAGING_DIR}/share/icons/Adwaita/index.theme"
test -f "${STAGING_DIR}/share/icons/hicolor/index.theme"
test -n "$(find "${STAGING_DIR}/share/icons/Adwaita" -type f -name '*-symbolic.svg' -print -quit)"
python3 tools/verify_gnome_icon_theme.py "${STAGING_DIR}/share/icons"
cp /mingw64/lib/gio/modules/libgiognutls.dll "${STAGING_DIR}/lib/gio/modules/"
python3 tools/collect_dlls.py "${STAGING_DIR}/lib/gio/modules/libgiognutls.dll" "${STAGING_DIR}/bin"

cat > "${STAGING_DIR}/bin/filecollector-launch.bat" <<'BAT'
@echo off
set "GDK_PIXBUF_MODULEDIR=%~dp0..\lib\gdk-pixbuf-2.0\2.10.0\loaders"
set "GIO_MODULE_DIR=%~dp0..\lib\gio\modules"
start "" "%~dp0filecollector.exe" %*
BAT

PACKAGE_PATH="${DIST_DIR}/filecollector-windows-${VERSION}-x64.zip"
(
  cd "${STAGING_DIR}"
  zip -r "../${PACKAGE_PATH}" .
)
unzip -l "${PACKAGE_PATH}" | grep -Eq 'bin/filecollector\.exe'
unzip -l "${PACKAGE_PATH}" | grep -Eq 'bin/filecollector-launch\.bat'
unzip -l "${PACKAGE_PATH}" | grep -Eq 'lib/gio/modules/libgiognutls\.dll'
unzip -l "${PACKAGE_PATH}" | grep -Eq 'share/glib-2\.0/schemas/gschemas\.compiled'
sha256sum "${PACKAGE_PATH}" > "${PACKAGE_PATH}.sha256"

echo "Built ${PACKAGE_PATH}"
