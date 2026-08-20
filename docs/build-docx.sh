#!/usr/bin/env bash
# Genera el .docx de la especificación a partir del Markdown (fuente de verdad).
# Requiere: pandoc >= 3.1
set -euo pipefail

cd "$(dirname "$0")"
SRC="especificacion-tecnica-v2.md"
OUT="Especificacion_Tecnica_App_Deportiva_v2.docx"

pandoc "$SRC" -o "$OUT" \
  --reference-doc=assets/reference.docx \
  --toc --toc-depth=2 \
  --highlight-style=tango

# pandoc reescribe word/settings.xml, así que reinyectamos dos ajustes:
#  - updateFields: Word rellena el índice al abrir el documento
#  - idioma es-AR para corrector ortográfico y separador decimal
python3 - "$OUT" <<'PY'
import re, shutil, sys, zipfile
path = sys.argv[1]
tmp = path + ".tmp"
with zipfile.ZipFile(path) as zin, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        data = zin.read(item.filename)
        if item.filename == "word/settings.xml":
            s = data.decode("utf-8")
            if "updateFields" not in s:
                s = s.replace("</w:settings>", '<w:updateFields w:val="true"/></w:settings>')
            s = s.replace('w:themeFontLang w:val="en-US"', 'w:themeFontLang w:val="es-AR"')
            s = s.replace('<w:decimalSymbol w:val="." />', '<w:decimalSymbol w:val="," />')
            data = s.encode("utf-8")
        zout.writestr(item, data)
shutil.move(tmp, path)
print("ok:", path)
PY

echo "Generado: $OUT"
