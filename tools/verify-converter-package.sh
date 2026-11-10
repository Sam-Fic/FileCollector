#!/usr/bin/env bash
# 校验 Windows 转换器包真的能用 (不只是 zip 清单里有 soffice.exe)。
#
# 只查文件清单是不够的: 早期版本 staging 时漏掉了根目录的 presets/, 包能打出来、
# 清单校验也过, 但 LibreOffice 启动阶段直接失败:
#   "The application cannot be started. / User installation could not be
#    completed." (exit 77)
# 转换根本走不到文档加载, 用户侧表现为"Office 转换全部失败"。
#
# 这里做真实端到端: 解包 → 造最小 docx → soffice headless 转 PDF → 校验产物。
set -euo pipefail

PACKAGE_PATH="${1:?usage: verify-converter-package.sh <converter-package.zip>}"
readonly WORK_DIR="converter-smoke"
readonly LO_DIR="${WORK_DIR}/unpack/tools/LibreOffice"
readonly SOFFICE="${LO_DIR}/program/soffice.com"

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}/unpack" "${WORK_DIR}/out" "${WORK_DIR}/docx/_rels" \
         "${WORK_DIR}/docx/word/_rels" "${WORK_DIR}/docx/docProps"

echo "Unpacking ${PACKAGE_PATH} ..."
unzip -q "${PACKAGE_PATH}" -d "${WORK_DIR}/unpack"

echo "Checking layout ..."
for f in "${SOFFICE}" \
         "${LO_DIR}/program/soffice.exe" \
         "${LO_DIR}/program/soffice.bin" \
         "${LO_DIR}/program/vcruntime140.dll" \
         "${LO_DIR}/share/registry/main.xcd"; do
  if [[ ! -f "${f}" ]]; then
    echo "converter package is missing: ${f}" >&2
    exit 1
  fi
done
# presets/ 是 LibreOffice 启动必需项 (缺了就起不来), 单独提示
if [[ ! -d "${LO_DIR}/presets" ]]; then
  echo "converter package is missing presets/ (required at LibreOffice startup)" >&2
  exit 1
fi

echo "Building minimal docx fixture ..."
cat > "${WORK_DIR}/docx/[Content_Types].xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
  <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
</Types>
EOF
cat > "${WORK_DIR}/docx/_rels/.rels" <<'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>
EOF
cat > "${WORK_DIR}/docx/word/_rels/document.xml.rels" <<'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>
EOF
cat > "${WORK_DIR}/docx/word/document.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>FileCollector converter smoke test</w:t></w:r></w:p>
    <w:p><w:r><w:t>转换器包冒烟测试 — 简体中文</w:t></w:r></w:p>
    <w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr>
  </w:body>
</w:document>
EOF
cat > "${WORK_DIR}/docx/word/styles.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
</w:styles>
EOF
cat > "${WORK_DIR}/docx/docProps/core.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
  xmlns:dc="http://purl.org/dc/elements/1.1/">
  <dc:title>converter smoke test</dc:title>
  <dc:creator>verify-converter-package.sh</dc:creator>
</cp:coreProperties>
EOF
cat > "${WORK_DIR}/docx/docProps/app.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">
  <Application>verify-converter-package.sh</Application>
</Properties>
EOF
DOCX_BUILD_ROOT="$(pwd)/${WORK_DIR}"
(
  cd "${WORK_DIR}/docx"
  if command -v zip >/dev/null 2>&1; then
    zip -q -r "../smoke.docx" .
  else
    # 兜底: 没有 zip CLI 时用 python 打包 (MSYS2 job 一定有 zip)
    python - "${DOCX_BUILD_ROOT}" <<'PY'
import os
import sys
import zipfile

work = sys.argv[1]
root = os.path.join(work, "docx")
with zipfile.ZipFile(os.path.join(work, "smoke.docx"), "w", zipfile.ZIP_DEFLATED) as z:
    for dirpath, _dirs, files in os.walk(root):
        for fn in files:
            full = os.path.join(dirpath, fn)
            z.write(full, os.path.relpath(full, root).replace(os.sep, "/"))
PY
  fi
)

echo "Running LibreOffice headless conversion ..."
# 独立用户配置目录: 共用默认 profile 时并发/已有实例会串台 (单实例 IPC),
# 转换请求被转交给别的实例, 本进程拿不到 PDF。
PROFILE_WIN="$(cygpath -w "${PWD}/${WORK_DIR}/profile")"
case "${PROFILE_WIN}" in
  *" "*)
    echo "profile path contains a space, needs percent-encoding: ${PROFILE_WIN}" >&2
    exit 1
    ;;
esac
PROFILE_URL="file:///$(printf '%s' "${PROFILE_WIN}" | tr '\\' '/')"

set +e
"${SOFFICE}" "-env:UserInstallation=${PROFILE_URL}" --headless \
    --convert-to pdf --outdir "${WORK_DIR}/out" "${WORK_DIR}/smoke.docx"
SOFFICE_EXIT=$?
set -e
if [[ ${SOFFICE_EXIT} -ne 0 ]]; then
  echo "soffice exited with ${SOFFICE_EXIT}" >&2
  exit 1
fi

PDF_PATH="${WORK_DIR}/out/smoke.pdf"
if [[ ! -s "${PDF_PATH}" ]]; then
  echo "conversion produced no PDF at ${PDF_PATH}" >&2
  exit 1
fi
if [[ "$(head -c 5 "${PDF_PATH}")" != "%PDF-" ]]; then
  echo "output is not a PDF: ${PDF_PATH}" >&2
  exit 1
fi

echo "OK: converter package produced a $(stat -c%s "${PDF_PATH}") byte PDF"
