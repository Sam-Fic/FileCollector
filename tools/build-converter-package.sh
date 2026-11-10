#!/usr/bin/env bash
# Build the OPTIONAL Windows LibreOffice converter package.
#
# 主包不捆绑 LibreOffice (体积原因)。Office 文档视觉转换链路
# (soffice → PDF → pdftoppm → VLM) 依赖 BinaryConverter.resolve_soffice ()
# 按以下顺序探测:
#   1. <应用包根>/tools/LibreOffice/program/soffice.exe   ← 本转换器包的布局
#   2. C:\Program Files\LibreOffice\program\soffice.exe   ← 官方安装器默认目录
#   3. PATH 中的 soffice                                   ← Linux/macOS 现状
#
# 本脚本下载官方 LibreOffice MSI, 用 msiexec /a 管理员解包 (不写注册表、
# 不进 Program Files), 把程序树按 tools/LibreOffice/... 布局打成独立 ZIP。
# 用户解压到 FileCollector 便携包根目录 (与 bin/ 同级) 即生效。
#
# 在 MSYS2 UCRT64 终端执行 (需要 curl/zip/unzip; msiexec 由 Windows 提供)。
set -euo pipefail

readonly DIST_DIR="dist"
readonly WORK_DIR="converter-work"
# 固定 LibreOffice "still" 分支版本; 升级时同步更新, 并确认 URL 有效:
#   https://www.libreoffice.org/download/download-libreoffice/
# 注意版本号必须真实存在 (25.8.4 曾因不存在而 404, 2026-11 实测 26.2.7 可用)
readonly LO_VERSION="26.2.7"
readonly LO_URL="https://download.documentfoundation.org/libreoffice/stable/${LO_VERSION}/win/x86_64/LibreOffice_${LO_VERSION}_Win_x86-64.msi"

rm -rf "${WORK_DIR}"
mkdir -p "${DIST_DIR}" "${WORK_DIR}/unpack" "${WORK_DIR}/staging/tools"

echo "Downloading LibreOffice ${LO_VERSION} MSI..."
curl --fail --location --retry 3 --output "${WORK_DIR}/LibreOffice.msi" "${LO_URL}"

MSI_WIN="$(cygpath -w "${PWD}/${WORK_DIR}/LibreOffice.msi")"
TARGET_WIN="$(cygpath -w "${PWD}/${WORK_DIR}/unpack")"
LOG_WIN="$(cygpath -w "${PWD}/${WORK_DIR}/msi-extract.log")"

echo "Extracting MSI (msiexec /a, administrative extract, no install)..."
# msiexec 的 /a /qn 参数不能直接从 bash 传入: MSYS2 会把 "/a" 当 POSIX 路径
# 改写成 MSYS2 安装根路径 (与 meson --prefix=/usr 同类陷阱); cmd //c 复合
# 字符串的嵌套引号同样会污染路径 (实测 msi 报 2203, 路径变成 D:\"D:\...")。
# 用 PowerShell Start-Process 逐参数传递最可靠, 且 -Wait 拿得到真实退出码。
MSI_EXIT="$(powershell -NoProfile -Command "
\$p = Start-Process msiexec.exe -ArgumentList '/a','${MSI_WIN}','/qn','/L*V','${LOG_WIN}','TARGETDIR=${TARGET_WIN}' -Wait -PassThru; \$p.ExitCode")"
if [[ "${MSI_EXIT}" != "0" ]]; then
  echo "msiexec /a failed with exit code ${MSI_EXIT}:" >&2
  # 日志是 UTF-16LE, 转码后抓 2203 (路径非法) 等关键错误行
  iconv -f UTF-16LE -t UTF-8 "${WORK_DIR}/msi-extract.log" 2>/dev/null \
    | grep -E "Note: 1: 2203|MainEngineThread is returning" | tail -5 >&2 || true
  exit 1
fi

# MSI /a 的 TARGETDIR 布局 (LO 26.2.7 实测): program/ share/ presets/ 直接位于
# 解包根, 无 LibreOffice/ 嵌套层, 且 MSI 本体也会被拷进去。按 soffice.exe 实际
# 位置兜底定位 program/ 目录, 把 program+share+presets 组装成 tools/LibreOffice/ 布局。
#
# presets/ 是启动必需项 (仅 182K): 缺它时 LibreOffice 引导阶段直接失败,
# 报 "The application cannot be started. / User installation could not be
# completed." (exit 77), 转换根本走不到文档加载。
SOFFICE="$(find "${WORK_DIR}/unpack" -name soffice.exe -print -quit)"
test -n "${SOFFICE}"
PROGRAM_DIR="$(dirname "${SOFFICE}")"
UNPACK_ROOT="$(dirname "${PROGRAM_DIR}")"
test -f "${PROGRAM_DIR}/soffice.bin"
test -d "${UNPACK_ROOT}/share"
test -d "${UNPACK_ROOT}/presets"

echo "Staging tools/LibreOffice from ${UNPACK_ROOT} ..."
mkdir -p "${WORK_DIR}/staging/tools/LibreOffice"
cp -r "${PROGRAM_DIR}" "${WORK_DIR}/staging/tools/LibreOffice/program"
cp -r "${UNPACK_ROOT}/share" "${WORK_DIR}/staging/tools/LibreOffice/share"
cp -r "${UNPACK_ROOT}/presets" "${WORK_DIR}/staging/tools/LibreOffice/presets"

# System64/ 装的是 MSVC 运行时 (msvcp140/vcruntime140/...): 正常安装时 MSI 把它
# 装进 Windows\System32, 但便携包不能假设用户装了 VC++ 2015-2022 发行版,
# 所以把这几个 DLL 一并塞进 program/ 做 app-local 加载 (soffice.bin 直接依赖
# VCRUNTIME140.dll, mergedlo.dll 依赖 msvcp140.dll)。
if test -d "${UNPACK_ROOT}/System64"; then
  cp "${UNPACK_ROOT}/System64"/*.dll "${WORK_DIR}/staging/tools/LibreOffice/program/"
fi

test -f "${WORK_DIR}/staging/tools/LibreOffice/program/soffice.exe"
test -f "${WORK_DIR}/staging/tools/LibreOffice/program/soffice.bin"
test -f "${WORK_DIR}/staging/tools/LibreOffice/program/vcruntime140.dll"
test -d "${WORK_DIR}/staging/tools/LibreOffice/share"
test -d "${WORK_DIR}/staging/tools/LibreOffice/presets"

PACKAGE_PATH="${DIST_DIR}/filecollector-converter-windows-x64-${LO_VERSION}.zip"
(
  cd "${WORK_DIR}/staging"
  zip -r "../../${PACKAGE_PATH}" tools
)
unzip -l "${PACKAGE_PATH}" | grep -Eq 'tools/LibreOffice/program/soffice\.exe'
unzip -l "${PACKAGE_PATH}" | grep -Eq 'tools/LibreOffice/program/soffice\.bin'
sha256sum "${PACKAGE_PATH}" > "${PACKAGE_PATH}.sha256"

du -h "${PACKAGE_PATH}"
echo "Built ${PACKAGE_PATH}"
echo "Usage: extract into the FileCollector portable package root (alongside bin/), keeping the tools/ layout."
