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
# 本脚本下载官方 LibreOffice MSI, 用 msiexec 管理员解包 (不写注册表、
# 不进 Program Files), 把程序树按 tools/LibreOffice/... 布局打成独立 ZIP。
# 用户解压到 FileCollector 便携包根目录 (与 bin/ 同级) 即生效。
#
# 在 MSYS2 UCRT64 终端执行 (需要 curl/zip/unzip; msiexec 由 Windows 提供)。
set -euo pipefail

readonly DIST_DIR="dist"
readonly WORK_DIR="converter-work"
# 固定 LibreOffice "still" 分支版本; 升级时同步更新, 并确认 URL 有效:
#   https://download.documentfoundation.org/libreoffice/stable/
readonly LO_VERSION="25.8.4"
readonly LO_URL="https://download.documentfoundation.org/libreoffice/stable/${LO_VERSION}/win/x86_64/LibreOffice_${LO_VERSION}_Win_x86-64.msi"

rm -rf "${WORK_DIR}"
mkdir -p "${DIST_DIR}" "${WORK_DIR}/unpack" "${WORK_DIR}/staging/tools"

echo "Downloading LibreOffice ${LO_VERSION} MSI..."
curl --fail --location --retry 3 --output "${WORK_DIR}/LibreOffice.msi" "${LO_URL}"

MSI_WIN="$(cygpath -w "${PWD}/${WORK_DIR}/LibreOffice.msi")"
TARGET_WIN="$(cygpath -w "${PWD}/${WORK_DIR}/unpack")"

echo "Extracting MSI (msiexec /a, administrative extract, no install)..."
# msiexec 的 /a /qn 参数不能直接从 bash 传入: MSYS2 会把 "/a" 当 POSIX 路径
# 改写成 MSYS2 安装根路径 (与 meson --prefix=/usr 同一类陷阱), 借 cmd 复合
# 字符串绕过参数转换。
cmd //c "msiexec /a \"${MSI_WIN}\" /qn TARGETDIR=\"${TARGET_WIN}\""

# msi 解包的嵌套层级因版本而异, 按 soffice.exe 实际位置反推 LibreOffice 根
SOFFICE="$(find "${WORK_DIR}/unpack" -name soffice.exe -print -quit)"
test -n "${SOFFICE}"
LO_ROOT="$(dirname "$(dirname "${SOFFICE}")")"   # .../LibreOffice/program/soffice.exe → .../LibreOffice
test -f "${LO_ROOT}/program/soffice.exe"
test -d "${LO_ROOT}/share"

cp -r "${LO_ROOT}" "${WORK_DIR}/staging/tools/LibreOffice"
test -f "${WORK_DIR}/staging/tools/LibreOffice/program/soffice.exe"
test -f "${WORK_DIR}/staging/tools/LibreOffice/program/soffice.bin"

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
