#!/usr/bin/env bash
# Build a self-contained Windows x64 portable ZIP in an MSYS2 UCRT64 shell.
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

# MSYS2 前缀: 兼容 MINGW64/UCRT64, 默认 UCRT64 (MINGW64 已被 MSYS2 弃用, GTK4 等包已迁往 UCRT64)
MSYS_PREFIX="${MSYSTEM_PREFIX:-/ucrt64}"
export PYTHONUTF8=1
export LANG=C.UTF-8
# meson --prefix=/usr 会被 MSYS2 参数转换改写为 MSYS2 安装根下的真实路径
# (实测 --prefix=/usr → --prefix=D:/<msys2根>/usr), locale 因此被装进
# install-windows/a/_temp/msys64/usr/... 错误嵌套路径, 打包时静默丢掉全部
# 翻译 (v4.9.1 及之前的 Windows 包均为纯英文界面)。排除这两类参数;
# cmark 的 -DCMAKE_INSTALL_PREFIX=/ucrt64 指向真实环境根, 不在排除之列。
export MSYS2_ARG_CONV_EXCL="/usr;--prefix"
export PKG_CONFIG_PATH="${MSYS_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CPATH="${MSYS_PREFIX}/include:${CPATH:-}"
export LIBRARY_PATH="${MSYS_PREFIX}/lib:${LIBRARY_PATH:-}"

rm -rf "${BUILD_DIR}" "${STAGING_DIR}" "${DIST_DIR}" "${INSTALL_ROOT}" "${CMARK_SOURCE}" "${CMARK_BUILD}"
mkdir -p "${DIST_DIR}"

curl --fail --location --retry 3 --output "${CMARK_ARCHIVE}" \
  "https://github.com/github/cmark-gfm/archive/refs/tags/${CMARK_VERSION}.tar.gz"
tar -xzf "${CMARK_ARCHIVE}" -C /tmp

cmake -S "${CMARK_SOURCE}" -B "${CMARK_BUILD}" \
  -G Ninja \
  -DCMAKE_INSTALL_PREFIX=${MSYS_PREFIX} \
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
# --min 20 是防呆线: 一个 GTK4 应用的运行时闭包不可能少于 20 个 DLL。
# 历史上 collect_dlls.py 写死 /mingw64, 迁到 UCRT64 后静默收集 0 个 DLL
# 却仍然出包发布, 导致用户启动时连续弹「找不到 xxx.dll」。
python3 tools/collect_dlls.py --min 20 "${STAGING_DIR}/bin/filecollector.exe" "${STAGING_DIR}/bin"

cp -r data "${STAGING_DIR}/share/data"
if [[ -d "${INSTALL_ROOT}/usr/share/locale" ]]; then
  cp -r "${INSTALL_ROOT}/usr/share/locale" "${STAGING_DIR}/locale"
fi
# 翻译缺失曾静默出包 (v4.9.1 及之前的 Windows 包均为纯英文界面, 见上方
# MSYS2_ARG_CONV_EXCL 注释), 此处硬性卡关: .mo 不在 staging 直接构建失败。
test -f "${STAGING_DIR}/locale/zh_CN/LC_MESSAGES/filecollector.mo"

# Dynamically loaded GTK/GIO components are not visible to ldd and must be staged explicitly.
cp ${MSYS_PREFIX}/lib/gdk-pixbuf-2.0/2.10.0/loaders/*.dll \
  "${STAGING_DIR}/lib/gdk-pixbuf-2.0/2.10.0/loaders/"
# 图像加载器由 GDK 运行时 dlopen, 主 exe 的 ldd 看不到它们;
# 单独递归收集一次, 否则 AVIF/HEIF/SVG 加载器会因缺 libavif/libheif/librsvg 而失效。
python3 tools/collect_dlls.py \
  "${STAGING_DIR}"/lib/gdk-pixbuf-2.0/2.10.0/loaders/*.dll \
  "${STAGING_DIR}/bin"
cp ${MSYS_PREFIX}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache \
  "${STAGING_DIR}/lib/gdk-pixbuf-2.0/2.10.0/"
cp ${MSYS_PREFIX}/share/glib-2.0/schemas/gschemas.compiled \
  "${STAGING_DIR}/share/glib-2.0/schemas/"
# 打包完整 GNOME 图标主题（含全部 symbolic SVG），而非仅应用图标。
# 这样 Windows 与 GNOME 桌面使用同一套 Adwaita 图标名称和视觉语言。
cp -r ${MSYS_PREFIX}/share/icons/Adwaita "${STAGING_DIR}/share/icons/"
cp -r ${MSYS_PREFIX}/share/icons/hicolor "${STAGING_DIR}/share/icons/"
# 叠加项目随附的原始 XApp symbolic 图标，保留 xsi-* 的既有界面语义。
cp -r data/icons/hicolor/. "${STAGING_DIR}/share/icons/hicolor/"
test -f "${STAGING_DIR}/share/icons/Adwaita/index.theme"
test -f "${STAGING_DIR}/share/icons/hicolor/index.theme"
test -n "$(find "${STAGING_DIR}/share/icons/Adwaita" -type f -name '*-symbolic.svg' -print -quit)"
python3 tools/verify_gnome_icon_theme.py "${STAGING_DIR}/share/icons"
cp ${MSYS_PREFIX}/lib/gio/modules/libgiognutls.dll "${STAGING_DIR}/lib/gio/modules/"
python3 tools/collect_dlls.py "${STAGING_DIR}/lib/gio/modules/libgiognutls.dll" "${STAGING_DIR}/bin"

# zip_exporter 通过外部 zip 命令打包, 普通用户机器没有 Info-ZIP, 便携包
# 必须自带。MSYS2 的 zip 位于 msys 层 (/usr/bin), 依赖 msys-2.0.dll;
# 两者都要进 bin/ (CreateProcess 搜索调用方 exe 所在目录优先于 PATH,
# zip_exporter 的裸 "zip" 命令无需改 PATH 即可命中)。
test -f /usr/bin/zip.exe
test -f /usr/bin/msys-2.0.dll
cp /usr/bin/zip.exe "${STAGING_DIR}/bin/zip.exe"
cp /usr/bin/msys-2.0.dll "${STAGING_DIR}/bin/msys-2.0.dll"

# 二进制预处理 (视觉转换模式) 需要 poppler 工具: pdftoppm 把 PDF 渲染成页图
# 送 VLM, pdftotext 供 "文本抽取" 模式抽纯文本。其依赖 (cairo/freetype/
# fontconfig/jpeg/png/tiff) GTK 已带, collect_dlls.py 递归收集剩余部分。
test -f "${MSYS_PREFIX}/bin/pdftoppm.exe"
test -f "${MSYS_PREFIX}/bin/pdftotext.exe"
cp "${MSYS_PREFIX}/bin/pdftoppm.exe" "${STAGING_DIR}/bin/pdftoppm.exe"
cp "${MSYS_PREFIX}/bin/pdftotext.exe" "${STAGING_DIR}/bin/pdftotext.exe"
python3 tools/collect_dlls.py \
  "${STAGING_DIR}/bin/pdftoppm.exe" "${STAGING_DIR}/bin/pdftotext.exe" \
  "${STAGING_DIR}/bin"

# poppler 数据文件 (CJK CID 字体 CMap 等): 中文 PDF 没有它, pdftoppm/pdftotext
# 会输出乱码或空文本。优先取 MSYS2 环境内的 share/poppler; 没有则下载上游
# poppler-data 补齐。
if [[ -d "${MSYS_PREFIX}/share/poppler" ]]; then
  cp -r "${MSYS_PREFIX}/share/poppler" "${STAGING_DIR}/share/poppler"
else
  readonly POPPLER_DATA_VERSION="0.4.12"
  curl --fail --location --retry 3 --output /tmp/poppler-data.tar.gz \
    "https://poppler.freedesktop.org/releases/poppler-data-${POPPLER_DATA_VERSION}.tar.gz"
  tar -xzf /tmp/poppler-data.tar.gz -C /tmp
  mkdir -p "${STAGING_DIR}/share/poppler"
  # 上游 tarball 顶层即 cidToUnicode/ cMap/ unicodeMap/ 三目录 (无 share/ 嵌套)
  for d in cidToUnicode cMap unicodeMap; do
    cp -r "/tmp/poppler-data-${POPPLER_DATA_VERSION}/${d}" "${STAGING_DIR}/share/poppler/${d}"
  done
fi
test -d "${STAGING_DIR}/share/poppler/cidToUnicode"

cat > "${STAGING_DIR}/bin/filecollector-launch.bat" <<'BAT'
@echo off
set "GDK_PIXBUF_MODULEDIR=%~dp0..\lib\gdk-pixbuf-2.0\2.10.0\loaders"
set "GIO_MODULE_DIR=%~dp0..\lib\gio\modules"
start "" "%~dp0filecollector.exe" %*
BAT

# 打包前用 PE 导入表做依赖闭包校验, 任何一个非系统 DLL 缺失都直接失败。
python3 tools/verify_windows_package.py "${STAGING_DIR}"

# ─── i18n 运行时冒烟 ──────────────────────────────────────────────────
# 验证"应用自己"能把偏好设置 / 跟随系统落地, 而不只是 .mo 文件存在。
# 旧写法用外部 LANG=zh_CN.UTF-8 跑 --help, 恰好绕过了 CLI 分支的语言设置,
# 测不到设置不生效的回归。这里用干净环境 + 临时 XDG_CONFIG_HOME 里的
# settings.json 驱动, 由应用自己完成 locale 解析。
SMOKE_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${SMOKE_TMP_DIR}"' EXIT
mkdir -p "${SMOKE_TMP_DIR}/filecollector"
# Windows 原生 exe 不认 MSYS2 的 POSIX 路径; -m 产出 C:/... 形式, GLib 可解析
# 且不会被 MSYS2 当成 POSIX 绝对路径改写。
if command -v cygpath >/dev/null 2>&1; then
  SMOKE_CONFIG_HOME="$(cygpath -m "${SMOKE_TMP_DIR}")"
else
  SMOKE_CONFIG_HOME="$(cd "${SMOKE_TMP_DIR}" && pwd -W)"
fi
SMOKE_SETTINGS="${SMOKE_TMP_DIR}/filecollector/settings.json"
SMOKE_ERR="${SMOKE_TMP_DIR}/help.stderr"

# $1 用例名, $2 期望语言 (zh|en), $3 额外的 env 赋值 (可为空)
run_i18n_smoke () {
  local label="$1" expected="$2" extra="$3" out
  # env -u 清掉所有外部语言变量; timeout 防止 GUI 子系统 exe 挂起拖死 CI。
  if ! out="$(cd "${STAGING_DIR}/bin" && env -u LANG -u LC_ALL -u LC_MESSAGES \
        -u LANGUAGE -u FILECOLLECTOR_LANG_MANAGED \
        XDG_CONFIG_HOME="${SMOKE_CONFIG_HOME}" ${extra} \
        timeout 30 ./filecollector.exe --help 2>"${SMOKE_ERR}")"; then
    echo "i18n smoke [${label}]: filecollector.exe failed or timed out" >&2
    sed -n '1,20p' "${SMOKE_ERR}" >&2
    return 1
  fi
  # 用 bash 字符串匹配, 不经过管道: 避免 pipefail 下 grep -q 的 SIGPIPE(141) 误报。
  if [[ "${expected}" == "zh" && "${out}" != *"命令行模式"* ]] ||
     [[ "${expected}" == "en" && ( "${out}" != *"CLI Mode"* || "${out}" == *"命令行模式"* ) ]]; then
    echo "i18n smoke [${label}]: --help language mismatch (expected ${expected})" >&2
    printf '%s\n' "${out}" >&2
    sed -n '1,10p' "${SMOKE_ERR}" >&2
    return 1
  fi
  echo "i18n smoke [${label}]: OK"
}

echo '{"language": "zh"}' > "${SMOKE_SETTINGS}"
run_i18n_smoke "preferences=zh, clean env" zh ""

echo '{"language": "en"}' > "${SMOKE_SETTINGS}"
run_i18n_smoke "preferences=en, clean env" en ""

# LC_ALL 优先级高于 LANG: 应用显式选中文时必须能压过外部 LC_ALL=C。
echo '{"language": "zh"}' > "${SMOKE_SETTINGS}"
run_i18n_smoke "preferences=zh, LC_ALL=C" zh "LC_ALL=C"

# 跟随系统分支不得覆盖用户在 shell 里明确设置的真实语言。
echo '{}' > "${SMOKE_SETTINGS}"
run_i18n_smoke "follow-system, external LANG respected" zh "LANG=zh_CN.UTF-8"

# 干净环境走 g_win32_getlocale; CI runner 是 en-US, 应回退到英文原文。
echo '{}' > "${SMOKE_SETTINGS}"
run_i18n_smoke "follow-system, clean env" en ""

PACKAGE_PATH="${DIST_DIR}/filecollector-windows-${VERSION}-x64.zip"
(
  cd "${STAGING_DIR}"
  zip -r "../${PACKAGE_PATH}" .
)
unzip -l "${PACKAGE_PATH}" | grep -Eq 'bin/filecollector\.exe'
unzip -l "${PACKAGE_PATH}" | grep -Eq 'bin/filecollector-launch\.bat'
unzip -l "${PACKAGE_PATH}" | grep -Eq 'lib/gio/modules/libgiognutls\.dll'
unzip -l "${PACKAGE_PATH}" | grep -Eq 'share/glib-2\.0/schemas/gschemas\.compiled'
unzip -l "${PACKAGE_PATH}" | grep -Eq 'locale/zh_CN/LC_MESSAGES/filecollector\.mo'
unzip -l "${PACKAGE_PATH}" | grep -Eq 'bin/zip\.exe'
unzip -l "${PACKAGE_PATH}" | grep -Eq 'bin/pdftoppm\.exe'
unzip -l "${PACKAGE_PATH}" | grep -Eq 'bin/pdftotext\.exe'
# 再校验 ZIP 本体, 防止打包环节漏拷文件。
python3 tools/verify_windows_package.py "${PACKAGE_PATH}"
sha256sum "${PACKAGE_PATH}" > "${PACKAGE_PATH}.sha256"

echo "Built ${PACKAGE_PATH}"
