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

# libsecret 不再需要: macOS 走 Keychain shim, meson 中 libsecret 仅 Linux 必选
brew install \
  adwaita-icon-theme \
  blueprint-compiler \
  cmark-gfm \
  gettext \
  gtk4 \
  hicolor-icon-theme \
  json-glib \
  libadwaita \
  libgee \
  libsoup \
  meson \
  ninja \
  pkg-config \
  gtksourceview5 \
  vala

BREW_PREFIX="$(brew --prefix)"
ADWAITA_ICON_PREFIX="$(brew --prefix adwaita-icon-theme)"
HICOLOR_ICON_PREFIX="$(brew --prefix hicolor-icon-theme)"
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
# 运行时插件组件均放 Resources, 由 main.vala 在启动时用环境变量指向 bundle 内副本
readonly GIO_MODULES_DIR="${RESOURCES_PATH}/lib/gio/modules"
readonly PIXBUF_LOADERS_DIR="${RESOURCES_PATH}/lib/gdk-pixbuf-2.0/2.10.0/loaders"
readonly PIXBUF_CACHE_FILE="${RESOURCES_PATH}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
readonly FONTCONFIG_DIR="${RESOURCES_PATH}/etc/fonts"
mkdir -p "${MACOS_PATH}" \
  "${RESOURCES_PATH}/share/icons" \
  "${GIO_MODULES_DIR}" \
  "${PIXBUF_LOADERS_DIR}" \
  "${FONTCONFIG_DIR}"

cp "${BUILD_DIR}/filecollector" "${MACOS_PATH}/${APP_NAME}"
cp -R data "${RESOURCES_PATH}/data"

# 将完整 GNOME 图标主题随 .app 分发，使 non-GNOME macOS 环境也能按
# 与 Linux 相同的 Adwaita symbolic 图标名解析所有 UI 图标。
cp -R "${ADWAITA_ICON_PREFIX}/share/icons/Adwaita" "${RESOURCES_PATH}/share/icons/"
cp -R "${HICOLOR_ICON_PREFIX}/share/icons/hicolor" "${RESOURCES_PATH}/share/icons/"
# 叠加项目随附的原始 XApp symbolic 图标，保留 xsi-* 的既有界面语义。
cp -R data/icons/hicolor/. "${RESOURCES_PATH}/share/icons/hicolor/"
test -f "${RESOURCES_PATH}/share/icons/Adwaita/index.theme"
test -f "${RESOURCES_PATH}/share/icons/hicolor/index.theme"
test -n "$(find "${RESOURCES_PATH}/share/icons/Adwaita" -type f -name '*-symbolic.svg' -print -quit)"
python3 tools/verify_gnome_icon_theme.py "${RESOURCES_PATH}/share/icons"
if [[ -d "${INSTALL_ROOT}/usr/share/locale" ]]; then
  cp -R "${INSTALL_ROOT}/usr/share/locale" "${RESOURCES_PATH}/locale"
fi

# ── 运行时插件: GIO TLS / pixbuf loaders / fontconfig 配置 ───────────────
# 这些组件由 GLib/GTK 运行时按目录动态加载 (dlopen), 不出现在 otool -L 的
# 链接闭包里; 不收集则干净机器上 HTTPS (AI 功能)、图片加载、SVG 图标、
# 字体扫描全部失效。glib-networking / gdk-pixbuf / fontconfig / librsvg
# 均已在 GTK 依赖树中, 无需新增 brew 依赖。
cp "${BREW_PREFIX}"/lib/gio/modules/*.so "${GIO_MODULES_DIR}/"
test -f "${GIO_MODULES_DIR}/libgiognutls.so"

cp "${BREW_PREFIX}"/lib/gdk-pixbuf-2.0/2.10.0/loaders/*.so "${PIXBUF_LOADERS_DIR}/"
test -n "$(find "${PIXBUF_LOADERS_DIR}" -name 'libpixbufloader-*.so' -print -quit)"

# 生成 pixbuf loaders 缓存并把模块路径改写为 @executable_path 相对形式
# (dlopen 支持 @executable_path 展开, GTK 便携包的标准做法)。
# 必须在 fix_rpaths 之前执行: query-loaders 会 dlopen 每个 staged loader,
# 此时其依赖还是 Homebrew 绝对路径, 在 CI 上可以解析; 改写后 dlopen 会
# 相对 query-loaders 自身解析而失败。改写仅影响 Mach-O 依赖, cache 只记录
# 模块路径与格式签名, 不受影响。
"${BREW_PREFIX}/bin/gdk-pixbuf-query-loaders" "${PIXBUF_LOADERS_DIR}"/*.so \
  > "${PIXBUF_CACHE_FILE}"
sed -i '' "s|${PIXBUF_LOADERS_DIR}|@executable_path/../Resources/lib/gdk-pixbuf-2.0/2.10.0/loaders|g" \
  "${PIXBUF_CACHE_FILE}"
grep -q '@executable_path/../Resources/lib/gdk-pixbuf-2.0/2.10.0/loaders' "${PIXBUF_CACHE_FILE}"

cp -R "${BREW_PREFIX}/etc/fonts/." "${FONTCONFIG_DIR}/"
test -f "${FONTCONFIG_DIR}/fonts.conf"
# 干净机器上没有 /opt/homebrew/etc/fonts: 依赖 Homebrew 路径的 cachedir 会
# 失效; cachedir 改为用户 XDG 数据目录, Apple 系统字体目录若无则显式注入。
sed -i '' \
  -e 's|<cachedir>[^<]*/opt/homebrew/var/cache/fontconfig</cachedir>|<cachedir prefix="xdg">cache/fontconfig</cachedir>|g' \
  -e 's|/opt/homebrew/var/cache/fontconfig|cache/fontconfig|g' \
  "${FONTCONFIG_DIR}/fonts.conf"
if ! grep -q '/System/Library/Fonts' "${FONTCONFIG_DIR}/fonts.conf"; then
  sed -i '' 's|</fontconfig>|<dir>/System/Library/Fonts</dir><dir>/Library/Fonts</dir><dir>~/Library/Fonts</dir></fontconfig>|' \
    "${FONTCONFIG_DIR}/fonts.conf"
fi

# Info.plist。macOS 26 (Tahoe) 的 Homebrew bottle 以 macOS 15 为部署目标,
# 14.0 的历史声明会在旧系统上以 dyld 符号错误告终, 如实声明 15.0。
ICON_PLIST_ENTRY=""
ICON_SVG="data/icons/hicolor/scalable/apps/io.github.sam_fic.filecollector.svg"
if command -v rsvg-convert >/dev/null 2>&1 && [[ -f "${ICON_SVG}" ]]; then
  ICONSET_DIR="$(mktemp -d)/FileCollector.iconset"
  mkdir -p "${ICONSET_DIR}"
  for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
              "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" "512:icon_256x256@2x" \
              "512:icon_512x512" "1024:icon_512x512@2x"; do
    size="${spec%%:*}"
    name="${spec##*:}"
    rsvg-convert -w "${size}" -h "${size}" "${ICON_SVG}" -o "${ICONSET_DIR}/${name}.png"
  done
  iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_PATH}/FileCollector.icns"
  rm -rf "$(dirname "${ICONSET_DIR}")"
  ICON_PLIST_ENTRY='  <key>CFBundleIconFile</key>
  <string>FileCollector</string>'
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
  <key>NSHighResolutionCapable</key>
  <true/>
${ICON_PLIST_ENTRY}
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
</dict>
</plist>
EOF

# 收集链接期与 @rpath/@loader_path 依赖闭包, 统一改写为 @executable_path。
# 输入包括主程序和两个动态加载的模块目录, 共享同一个收集表。
python3 tools/fix_rpaths.py "${MACOS_PATH}" \
  "${MACOS_PATH}/${APP_NAME}" \
  "${GIO_MODULES_DIR}"/*.so \
  "${PIXBUF_LOADERS_DIR}"/*.so

# Homebrew 的 opt/ symlinks 可能留下绝对 install ID。GIO/pixbuf 模块按路径
# dlopen, LC_ID 不参与解析, 只有 MacOS/ 下的 dylib 需要统一为相对 ID。
for dylib in "${MACOS_PATH}"/*.dylib; do
  [[ -f "${dylib}" ]] || continue
  install_name_tool -id "@executable_path/$(basename "${dylib}")" "${dylib}"
done

OTOL_OUTPUT="$(otool -L "${MACOS_PATH}"/* "${GIO_MODULES_DIR}"/*.so "${PIXBUF_LOADERS_DIR}"/*.so)"
if echo "${OTOL_OUTPUT}" | grep -Eq '(/opt/homebrew|/usr/local)/(lib|opt)/'; then
  echo "Homebrew runtime references remain in the app bundle (matching lines):" >&2
  echo "${OTOL_OUTPUT}" | grep -nE '(/opt/homebrew|/usr/local)/(lib|opt)/' >&2
  exit 1
fi

# 静态闭包审计: Mach-O 加载命令逐条解析, @rpath/LC_RPATH/缺失依赖即失败。
python3 tools/verify_macos_package.py "${APP_PATH}"

# This is an ad-hoc signature for bundle integrity. Distribution is not Developer-ID signed or notarized.
codesign --force --deep --sign - "${APP_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

# ── 无头冒烟测试 ─────────────────────────────────────────────────────────
# 字体: 用包内 fontconfig 配置扫描, 确认清机器语义下能看到系统字体。
if command -v fc-list >/dev/null 2>&1; then
  FONT_COUNT="$(FONTCONFIG_FILE="${FONTCONFIG_DIR}/fonts.conf" fc-list | wc -l | tr -d ' ')"
  if [[ "${FONT_COUNT}" -lt 10 ]]; then
    echo "Smoke test: bundled fontconfig config sees only ${FONT_COUNT} fonts" >&2
    exit 1
  fi
  echo "Smoke test: bundled fontconfig config sees ${FONT_COUNT} fonts"
fi
# 应用: broadway 后端无头拉起主程序, 捕捉 dyld / GTK 初始化级失败。
# 不依赖 GNU timeout (macOS 无自带): 后台启动 + 探活, 20 秒后回收。
if command -v broadwayd >/dev/null 2>&1; then
  SMOKE_LOG="$(mktemp)"
  broadwayd :5 > "${SMOKE_LOG}" 2>&1 &
  BROADWAYD_PID=$!
  sleep 2
  set +e
  GDK_BACKEND=broadway "${MACOS_PATH}/${APP_NAME}" >> "${SMOKE_LOG}" 2>&1 &
  APP_PID=$!
  sleep 20
  if kill -0 "${APP_PID}" 2>/dev/null; then
    SMOKE_RC=0  # 20 秒后仍存活, 冒烟通过
  else
    wait "${APP_PID}"
    SMOKE_RC=$?
  fi
  kill "${APP_PID}" 2>/dev/null
  wait "${APP_PID}" 2>/dev/null
  kill "${BROADWAYD_PID}" 2>/dev/null
  wait "${BROADWAYD_PID}" 2>/dev/null
  set -e
  if grep -Eq 'dyld\[|GLib-GObject-ERROR|Gtk-ERROR|Segmentation fault|traps:' "${SMOKE_LOG}"; then
    echo "Smoke test: fatal error in app output:" >&2
    cat "${SMOKE_LOG}" >&2
    exit 1
  fi
  if [[ "${SMOKE_RC}" -ne 0 ]]; then
    echo "Smoke test: app exited early (rc=${SMOKE_RC}):" >&2
    cat "${SMOKE_LOG}" >&2
    exit 1
  fi
  echo "Smoke test: app stayed alive under GDK_BACKEND=broadway"
else
  echo "broadwayd not available; runtime smoke test skipped (static audit already passed)" >&2
fi

PACKAGE_PATH="${DIST_DIR}/filecollector-macos-${VERSION}-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${PACKAGE_PATH}"
unzip -l "${PACKAGE_PATH}" | grep -Eq "${APP_NAME}\.app/Contents/MacOS/${APP_NAME}"
unzip -l "${PACKAGE_PATH}" | grep -Eq "${APP_NAME}\.app/Contents/Info\.plist"
unzip -l "${PACKAGE_PATH}" | grep -Eq "${APP_NAME}\.app/Contents/Resources/lib/gio/modules/libgiognutls\.so"
unzip -l "${PACKAGE_PATH}" | grep -Eq "${APP_NAME}\.app/Contents/Resources/lib/gdk-pixbuf-2\.0/2\.10\.0/loaders\.cache"
shasum -a 256 "${PACKAGE_PATH}" > "${PACKAGE_PATH}.sha256"

echo "Built ${PACKAGE_PATH}"
