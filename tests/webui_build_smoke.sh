#!/usr/bin/env bash
# Проверка собранных артефактов WebUI (webui/index.html, app.js, styles.css):
# - файловый состав прежний (контракт установки z2r.sh), лишних файлов сборки нет;
# - classic-script в конце body, стили в head;
# - ?v= в index.html совпадает с sha256 содержимого app.js/styles.css.
set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
fail() { printf 'webui build smoke: FAIL: %s\n' "$*" >&2; exit 1; }

WWW="$REPO_DIR/webui"
hash8() { sha256sum "$1" | cut -c1-8; }

for f in index.html app.js styles.css favicon.svg run-webui.sh; do
  [ -s "$WWW/$f" ] || fail "webui/$f пуст или отсутствует"
done
[ -d "$WWW/cgi-bin" ] || fail "webui/cgi-bin отсутствует"

# никаких артефактов сборки сверх договора
if find "$WWW" -maxdepth 1 \( -name '*.map' -o -name 'index-*.js' -o -name 'index-*.css' \) | grep -q .; then
  fail "в webui/ остались лишние файлы сборки (map/чанки)"
fi
[ ! -d "$WWW/assets" ] || fail "в webui/ остался каталог assets от сборки"

html="$(cat "$WWW/index.html")"

# app.js — classic script в конце body (монтируется в #app), без module
printf '%s' "$html" | grep -q '<div id="app">' || fail "index.html без точки монтирования #app"
printf '%s' "$html" | grep -q '<script src="app.js?v=' || fail "app.js подключён не как classic script с ?v="
if printf '%s' "$html" | grep -q 'type="module"'; then fail "в index.html остался module script"; fi

# styles.css в head, до скрипта
css_pos="$(printf '%s\n' "$html" | grep -n 'styles.css?v=' | head -1 | cut -d: -f1)"
js_pos="$(printf '%s\n' "$html" | grep -n '<script src="app.js?v=' | head -1 | cut -d: -f1)"
[ -n "$css_pos" ] && [ -n "$js_pos" ] && [ "$css_pos" -lt "$js_pos" ] \
  || fail "styles.css должен подключаться раньше app.js (иначе FOUC при монтировании)"

# ?v= совпадает с хэшем содержимого
app_v="$(printf '%s' "$html" | grep -o 'app\.js?v=[0-9a-f]\{8\}' | head -1 | cut -d= -f2)"
css_v="$(printf '%s' "$html" | grep -o 'styles\.css?v=[0-9a-f]\{8\}' | head -1 | cut -d= -f2)"
[ -n "$app_v" ] || fail "index.html без app.js?v="
[ -n "$css_v" ] || fail "index.html без styles.css?v="
[ "$app_v" = "$(hash8 "$WWW/app.js")" ] || fail "app.js?v= не совпадает с sha256 файла"
[ "$css_v" = "$(hash8 "$WWW/styles.css")" ] || fail "styles.css?v= не совпадает с sha256 файла"

# валидный JS (минифицированный IIFE обязан парситься)
if command -v node >/dev/null 2>&1; then
  node --check "$WWW/app.js" || fail "webui/app.js не парсится как JS"
fi

# сорсы сборки существуют и типизируются конфигурацией
[ -f "$REPO_DIR/webui-src/package.json" ] || fail "webui-src/package.json отсутствует"

echo "webui build smoke ok"
