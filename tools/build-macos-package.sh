#!/usr/bin/env bash
# Build an unsigned-but-ad-hoc-signed macOS ARM64 app bundle and ZIP archive.
set -euo pipefail

readonly BUILD_DIR="build-macos"
readonly DIST_DIR="dist"
readonly INSTALL_ROOT="install-macos"
readonly APP_NAME="FileCollector"
readonly APP_ID="io.github.sam_fic.filecollector"

VERSION="$(sed -n "s/^[[:space:]]*version:[[:space:]]*'\([^']*\)'.*/\1/p" meson.build | head -n 1)"
if [[ -z "${VERSION}" ]]; then
  echo "Unable to read the project version from meson.build." >&2
  exit 1
fi

brew install \
  blueprint-compiler \
  cmark-gfm \
  gettext \
  gtk4 \
  json-glib \
  libadwaita \
  libgee \
  libsecret \
  libsoup \
  meson \
  ninja \
  pkg-config \
  gtksourceview5 \
  vala

BREW_PREFIX="$(brew --prefix)"
export PKG_CONFIG_PATH="${BREW_PREFIX}/lib/pkgconfig:${BREW_PREFIX}/share/pkgconfig:${PKG_CONFIG_PATH:-}"
export LDFLAGS="-L${BREW_PREFIX}/lib ${LDFLAGS:-}"
export CPPFLAGS="-I${BREW_PREFIX}/include ${CPPFLAGS:-}"

rm -rf "${BUILD_DIR}" "${DIST_DIR}" "${INSTALL_ROOT}"
mkdir -p "${DIST_DIR}"

meson setup "${BUILD_DIR}" --prefix=/usr --buildtype=release
meson compile -C "${BUILD_DIR}"
meson test -C "${BUILD_DIR}" --print-errorlogs --num-processes=1
DESTDIR="${PWD}/${INSTALL_ROOT}" meson install -C "${BUILD_DIR}"

APP_PATH="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_PATH="${APP_PATH}/Contents"
MACOS_PATH="${CONTENTS_PATH}/MacOS"
RESOURCES_PATH="${CONTENTS_PATH}/Resources"
mkdir -p "${MACOS_PATH}" "${RESOURCES_PATH}"

cp "${BUILD_DIR}/filecollector" "${MACOS_PATH}/${APP_NAME}"
cp -R data "${RESOURCES_PATH}/data"
if [[ -d "${INSTALL_ROOT}/usr/share/locale" ]]; then
  cp -R "${INSTALL_ROOT}/usr/share/locale" "${RESOURCES_PATH}/locale"
fi

cat > "${CONTENTS_PATH}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${APP_ID}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
</dict>
</plist>
EOF

python3 tools/fix_rpaths.py "${MACOS_PATH}/${APP_NAME}" "${MACOS_PATH}"

# Homebrew's opt/ symlinks can leave absolute install names after dependency
# collection. Rewrite every copied Mach-O binary to use its colocated copy.
for target in "${MACOS_PATH}"/*; do
  [[ -f "${target}" ]] || continue
  while IFS= read -r dependency; do
    case "${dependency}" in
      /opt/homebrew/*|/usr/local/*)
        install_name_tool -change "${dependency}" "@executable_path/$(basename "${dependency}")" "${target}"
        ;;
    esac
  done < <(otool -L "${target}" | tail -n +2 | sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')
done

if otool -L "${MACOS_PATH}"/* | grep -Eq '(/opt/homebrew|/usr/local)/(lib|opt)/'; then
  echo "Homebrew runtime references remain in the app bundle:" >&2
  otool -L "${MACOS_PATH}"/* >&2
  exit 1
fi

# This is an ad-hoc signature for bundle integrity. Distribution is not Developer-ID signed or notarized.
codesign --force --deep --sign - "${APP_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

PACKAGE_PATH="${DIST_DIR}/filecollector-macos-${VERSION}-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${PACKAGE_PATH}"
unzip -l "${PACKAGE_PATH}" | grep -Eq "${APP_NAME}\.app/Contents/MacOS/${APP_NAME}"
unzip -l "${PACKAGE_PATH}" | grep -Eq "${APP_NAME}\.app/Contents/Info\.plist"
shasum -a 256 "${PACKAGE_PATH}" > "${PACKAGE_PATH}.sha256"

echo "Built ${PACKAGE_PATH}"
