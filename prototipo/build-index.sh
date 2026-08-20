#!/usr/bin/env bash
# Genera el index.html de la raíz (documento HTML completo, apto para GitHub Pages)
# a partir de motor-decision.html, que es la fuente y se publica también como Artifact.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
src = open('prototipo/motor-decision.html', encoding='utf-8').read()
marker = '<div class="wrap">'
i = src.index(marker)
head, body = src[:i], src[i:]
out = ('<!doctype html>\n<html lang="es">\n<head>\n<meta charset="utf-8">\n'
       + head.rstrip() + '\n</head>\n<body>\n'
       + body.rstrip() + '\n</body>\n</html>\n')
open('index.html', 'w', encoding='utf-8').write(out)
PY

echo "Generado: index.html ($(wc -c < index.html) bytes)"
