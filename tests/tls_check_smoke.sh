#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

TMP_DIR="$(mktemp -d /tmp/zator-tls-check.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/counter"

cat > "$TMP_DIR/bin/curl" <<'MOCK'
#!/bin/sh
hdr=""
head=0
ver=""
prev=""
for arg in "$@"; do
  [ "$prev" = "-D" ] && hdr="$arg"
  [ "$arg" = "-I" ] && head=1
  case "$arg" in
    --tlsv1.3) ver=13 ;;
    --tlsv1.2) ver=12 ;;
  esac
  prev="$arg"
done
if [ "$head" = 1 ]; then
  cnt="$COUNTER_DIR/head_${ver:-none}"
else
  cnt="$COUNTER_DIR/dl"
fi
n=1
[ -f "$cnt" ] && n=$(( $(cat "$cnt") + 1 ))
echo "$n" > "$cnt"
if [ "$head" = 1 ]; then
  eval "mode=\${MOCK_HEAD_${ver:-x}:-ok200}"
  eval "flaky=\${MOCK_FLAKY_${ver:-x}:-0}"
  if [ "$flaky" = 1 ] && [ "$n" = 1 ]; then mode=timeout; fi
  case "$mode" in
    ok200)   [ -n "$hdr" ] && printf 'HTTP/2 200\r\n' >"$hdr"; echo "0.800 192.0.2.10"; exit 0 ;;
    code403) [ -n "$hdr" ] && printf 'HTTP/1.1 403 Forbidden\r\n' >"$hdr"; echo "0.900 192.0.2.10"; exit 0 ;;
    code405) [ -n "$hdr" ] && printf 'HTTP/2 405\r\n' >"$hdr"; echo "0.700 192.0.2.10"; exit 0 ;;
    timeout) echo "8.004 -"; exit 28 ;;
    dns)     echo "- -"; exit 6 ;;
    tls)     echo "0.500 -"; exit 35 ;;
  esac
  exit 1
fi
case "${MOCK_DL:-ok206}" in
  ok206)      echo "206 65536 1.234"; exit 0 ;;
  small200)   echo "200 512 0.400"; exit 0 ;;
  partial206) echo "206 1200 0.400"; exit 0 ;;
  zero)       echo "200 0 0.500"; exit 0 ;;
  zero403)    echo "403 0 0.500"; exit 0 ;;
  fail28)     echo "000 0 12.002"; exit 28 ;;
esac
exit 1
MOCK
chmod +x "$TMP_DIR/bin/curl"

export COUNTER_DIR="$TMP_DIR/counter"
export PATH="$TMP_DIR/bin:$PATH"
export TMPDIR="$TMP_DIR"

for f in lib/netcheck.sh lib/strategies.sh webui/cgi-bin/_lib.sh z2r.sh lua/strategy-validator.sh; do
  bash -n "$REPO_DIR/$f" || fail "синтаксис $f"
done

# shellcheck source=/dev/null
source "$REPO_DIR/lib/netcheck.sh"
plain="" green="" yellow="" red=""

calls() {
  [ -f "$COUNTER_DIR/$1" ] && cat "$COUNTER_DIR/$1" || echo 0
}

reset_counter() {
  rm -f "$COUNTER_DIR"/*
}

target_out() {
  z2r_tls_check_target "https://example.org/"
}

verdict_of() {
  z2r_tls_target_verdict "$(printf '%s\n' "$1" | sed -n 1p)" "$(printf '%s\n' "$1" | sed -n 2p)" "$(printf '%s\n' "$1" | sed -n 3p)"
}

# == 1. обе версии 200 + данные 206 -> ok ==
reset_counter
export MOCK_HEAD_12=ok200 MOCK_HEAD_13=ok200 MOCK_DL=ok206 MOCK_FLAKY_12=0 MOCK_FLAKY_13=0
out="$(target_out)"
v="$(verdict_of "$out")"
[ "${v%%|*}" = "ok" ] || fail "сценарий 1: вердикт должен быть ok, получено: $v"
z2r_tls_version_text 1.3 "$(printf '%s\n' "$out" | sed -n 2p)" | grep -q "HTTP/2 200" || fail "сценарий 1: нет HTTP/2 200 в тексте TLS 1.3"
z2r_tls_download_text "$(printf '%s\n' "$out" | sed -n 3p)" | grep -q "65536" || fail "сценарий 1: нет размера в тексте данных"

# == 2. TLS 1.2 не отвечает, TLS 1.3 работает -> итог ok, строка 1.2 с подсказкой ==
reset_counter
export MOCK_HEAD_12=tls MOCK_HEAD_13=ok200 MOCK_DL=ok206
out="$(target_out)"
v="$(verdict_of "$out")"
[ "${v%%|*}" = "ok" ] || fail "сценарий 2: вердикт должен быть ok (сайт работает), получено: $v"
t12="$(z2r_tls_version_text 1.2 "$(printf '%s\n' "$out" | sed -n 1p)")"
printf '%s' "$t12" | grep -q "Ошибка TLS-рукопожатия" || fail "сценарий 2: нет причины сбоя TLS 1.2"
printf '%s' "$t12" | grep -q "Проверьте доступность вручную" || fail "сценарий 2: нет подсказки у TLS 1.2"
if printf '%s' "$t12" | grep -q "отключён на стороне сайта"; then fail "сценарий 2: остался длинный override-текст"; fi

# == 3. обе версии отвечают 403 -> зелёный ok (сервер ответил, TLS пробит), докачки нет ==
reset_counter
export MOCK_HEAD_12=code403 MOCK_HEAD_13=code403 MOCK_DL=ok206
out="$(target_out)"
[ "$(printf '%s\n' "$out" | sed -n 3p)" = "skip" ] || fail "сценарий 3: докачка должна быть пропущена"
v="$(verdict_of "$out")"
[ "${v%%|*}" = "ok" ] || fail "сценарий 3: вердикт должен быть ok (сервер ответил), получено: $v"
printf '%s' "$v" | grep -q "403" || fail "сценарий 3: в тексте нет кода 403"
z2r_tls_version_text 1.2 "$(printf '%s\n' "$out" | sed -n 1p)" | grep -q "HTTP/1.1 403" \
  || fail "сценарий 3: строка версии не в формате успеха с кодом"

# == 4. HEAD 405 -> транспорт работает ==
reset_counter
export MOCK_HEAD_12=ok200 MOCK_HEAD_13=code405 MOCK_DL=ok206
out="$(target_out)"
state="$(z2r_tls_version_state "$(printf '%s\n' "$out" | sed -n 2p | cut -d'|' -f1)" "$(printf '%s\n' "$out" | sed -n 2p | cut -d'|' -f2)")"
[ "$state" = "http" ] || fail "сценарий 4: 405 должен давать состояние http, получено: $state"
v="$(verdict_of "$out")"
[ "${v%%|*}" = "ok" ] || fail "сценарий 4: вердикт должен быть ok, получено: $v"

# == 5. обе версии таймаут -> fail, одна попытка без ретрая ==
reset_counter
export MOCK_HEAD_12=timeout MOCK_HEAD_13=timeout MOCK_DL=ok206
out="$(target_out)"
v="$(verdict_of "$out")"
[ "${v%%|*}" = "fail" ] || fail "сценарий 5: вердикт должен быть fail, получено: $v"
[ "$(calls head_12)" = 1 ] || fail "сценарий 5: должна быть одна попытка, было $(calls head_12)"
[ "$(calls dl)" = 0 ] || fail "сценарий 5: докачка не должна была запускаться"
z2r_tls_version_text 1.2 "$(printf '%s\n' "$out" | sed -n 1p)" | grep -q "Таймаут 8сек\." \
  || fail "сценарий 5: текст таймаута без упоминания попыток"

# == 6. DNS не разрешается -> fail с указанием на DNS ==
reset_counter
export MOCK_HEAD_12=dns MOCK_HEAD_13=dns
out="$(target_out)"
v="$(verdict_of "$out")"
[ "${v%%|*}" = "fail" ] || fail "сценарий 6: вердикт должен быть fail"
printf '%s' "$v" | grep -q "DNS" || fail "сценарий 6: в тексте нет упоминания DNS"

# == 7. ретрая нет: единственный сбой TLS 1.3 даёт warn «только TLS 1.2» ==
reset_counter
export MOCK_HEAD_12=ok200 MOCK_HEAD_13=ok200 MOCK_FLAKY_13=1 MOCK_DL=ok206
out="$(target_out)"
v="$(verdict_of "$out")"
[ "${v%%|*}" = "warn" ] || fail "сценарий 7: без ретрая сбой TLS 1.3 должен давать warn, получено: $v"
printf '%s' "$v" | grep -q "только по TLS 1.2" || fail "сценарий 7: нет пояснения про TLS 1.2"
[ "$(calls head_13)" = 1 ] || fail "сценарий 7: должна быть одна попытка, было $(calls head_13)"

# == 8. хендшейк есть, тело не приходит (0 байт) -> красный fail ==
reset_counter
export MOCK_HEAD_12=ok200 MOCK_HEAD_13=ok200 MOCK_FLAKY_13=0 MOCK_DL=zero
out="$(target_out)"
v="$(verdict_of "$out")"
[ "${v%%|*}" = "fail" ] || fail "сценарий 8: вердикт должен быть fail (страница не скачивается), получено: $v"
z2r_tls_download_text "$(printf '%s\n' "$out" | sed -n 3p)" | grep -q "0 байт" || fail "сценарий 8: текст не про 0 байт"

# == 9. маленькая страница целиком (206, меньше запрошенного) -> зелёный ok ==
reset_counter
export MOCK_DL=partial206
out="$(target_out)"
[ "$(z2r_tls_download_state 0 206 1200)" = "ok" ] || fail "сценарий 9: целиком дошедшая маленькая страница должна быть ok"
v="$(verdict_of "$out")"
[ "${v%%|*}" = "ok" ] || fail "сценарий 9: вердикт должен быть ok, получено: $v"
z2r_tls_download_text "$(printf '%s\n' "$out" | sed -n 3p)" | grep -q "1200" || fail "сценарий 9: в тексте нет 1200"
if z2r_tls_download_text "$(printf '%s\n' "$out" | sed -n 3p)" | grep -q "из 64КБ"; then
  fail "сценарий 9: остался текст сравнения с 64КБ"
fi

# == 10. 200 без Range с малым телом -> данные идут ==
[ "$(z2r_tls_download_state 0 200 512)" = "ok" ] || fail "сценарий 10: 200+512 должен быть ok"

# == 10b. таймаут докачки -> человеческий текст без curl rc ==
z2r_tls_download_text "28|000|0|12.0" | grep -q "таймаут — тело ответа не начало приходать" \
  || fail "сценарий 10b: rc=28 должен давать текст про таймаут"
z2r_tls_download_text "56|000|0|1.0" | grep -q "curl rc=56" \
  || fail "сценарий 10b: прочие rc должны показывать код ошибки"

# == 11. докачка оборвалась (rc=28) -> красный fail ==
reset_counter
export MOCK_DL=fail28
out="$(target_out)"
v="$(verdict_of "$out")"
[ "${v%%|*}" = "fail" ] || fail "сценарий 11: вердикт должен быть fail, получено: $v"

# == 11b. поток срезался на середине (код есть, байты шли, потом таймаут) ==
[ "$(z2r_tls_download_state 28 200 4300)" = "cut" ] || fail "сценарий 11b: rc=28 code=200 size=4300 должно быть cut"
[ "$(z2r_tls_download_state 28 206 500)" = "cut" ] || fail "сценарий 11b: rc=28 code=206 size=500 должно быть cut"
z2r_tls_download_text "28|200|4300|12.0" | grep -q "Данные оборвались: получено 4300 байт" \
  || fail "сценарий 11b: текст не показывает обрыв с размером"
v="$(z2r_tls_target_verdict "0|200|0.4|HTTP/2|1.1.1.1" "0|200|0.4|HTTP/2|1.1.1.1" "28|200|4300|12.0")"
[ "${v%%|*}" = "fail" ] || fail "сценарий 11b: вердикт по cut должен быть fail"
printf '%s' "$v" | grep -q "срезается после 4300 байт" || fail "сценарий 11b: вердикт без размера среза"
[ "$(z2r_tls_download_state 0 200 512)" = "ok" ] || fail "сценарий 11b: rc=0 малый размер должен остаться ok"

# == 12. докачка 403/0 байт -> zero с кодом ==
z2r_tls_download_text "0|403|0|0.5" | grep -q "код 403" || fail "сценарий 12: текст не содержит код 403"
[ "$(z2r_tls_download_state 0 403 0)" = "zero" ] || fail "сценарий 12: состояние должно быть zero"

# == 13. CLI check_access: важность TLS + подсказка проверить вручную ==
reset_counter
export MOCK_HEAD_12=tls MOCK_HEAD_13=ok200 MOCK_DL=ok206
cli_out="$(check_access "https://example.org/" 2>&1)"
printf '%s' "$cli_out" | grep -q "Итог: Сайт доступен" || fail "сценарий 13: нет итога ok: $cli_out"
printf '%s' "$cli_out" | grep -q "важно для ТВ" || fail "сценарий 13: нет пометки 'важно для ТВ' у TLS 1.2"
printf '%s' "$cli_out" | grep -q "всего современного" || fail "сценарий 13: нет пометки 'всего современного' у TLS 1.3"
if printf '%s' "$cli_out" | grep -q "Таймаут 2сек"; then fail "сценарий 13: остался старый текст 'Таймаут 2сек'"; fi
reset_counter
export MOCK_HEAD_12=timeout MOCK_HEAD_13=timeout
cli_out="$(check_access "https://example.org/" 2>&1)"
printf '%s' "$cli_out" | grep -q "Итог: Нет ответа" || fail "сценарий 13: нет итога fail: $cli_out"
printf '%s' "$cli_out" | grep -q "Проверьте доступность вручную" || fail "сценарий 13: нет подсказки проверить вручную"

# == 14. set -e: сбой curl не роняет вызывающий код (меню z2r.sh) ==
(
  set -e
  export MOCK_HEAD_12=timeout MOCK_HEAD_13=dns
  check_access "https://example.org/" >/dev/null 2>&1
  echo survived
) | grep -q survived || fail "сценарий 14: set -e роняет check_access при сбоях curl"

# == 15. WebUI-обёртка: JSON с вердиктом и деталями ==
(
  export COUNTER_DIR="$TMP_DIR/counter"
  export PATH="$TMP_DIR/bin:$PATH"
  export TMPDIR="$TMP_DIR"
  unset MOCK_FLAKY_12 MOCK_FLAKY_13
  # shellcheck source=/dev/null
  source "$REPO_DIR/webui/cgi-bin/_lib.sh"
  rm -f "$COUNTER_DIR"/*
  export MOCK_HEAD_12=tls MOCK_HEAD_13=ok200 MOCK_DL=ok206
  json="$(check_one_target_json "Test" "https://example.org/")"
  printf '%s' "$json" | grep -q '"verdict":"ok"' || fail "сценарий 15: в JSON нет verdict ok: $json"
  printf '%s' "$json" | grep -q '"tls13":1' || fail "сценарий 15: в JSON нет tls13=1"
  printf '%s' "$json" | grep -q '"tls12":0' || fail "сценарий 15: в JSON нет tls12=0"
  printf '%s' "$json" | grep -q '"tls12_detail":{"code":0' || fail "сценарий 15: нет detail TLS 1.2"
  printf '%s' "$json" | grep -q '"state":"ok","text":"Есть ответ по TLS 1.3' || fail "сценарий 15: нет текста TLS 1.3"
  printf '%s' "$json" | grep -q '"download":{"code":206,"size":65536' || fail "сценарий 15: нет объекта download"
  rm -f "$COUNTER_DIR"/*
  export MOCK_HEAD_12=timeout MOCK_HEAD_13=timeout
  json="$(check_one_target_json "Test" "https://example.org/")"
  printf '%s' "$json" | grep -q '"verdict":"fail"' || fail "сценарий 15: в JSON нет verdict fail"
  printf '%s' "$json" | grep -q '"download":null' || fail "сценарий 15: download должен быть null"
  printf '{"results":[%s]}' "$json" | python -c "import sys, json; json.load(sys.stdin)" \
    || fail "сценарий 15: JSON невалиден (например code с ведущими нулями): $json"

  rm -f "$COUNTER_DIR"/*
  export MOCK_HEAD_12=tls MOCK_HEAD_13=ok200 MOCK_DL=ok206
  json="$(_domains_check_json "example.org")"
  printf '%s' "$json" | grep -q '"results":\[' || fail "сценарий 15: _domains_check_json без results"
  printf '%s' "$json" | grep -q '"label":"example.org"' || fail "сценарий 15: label должен быть доменом"
  printf '%s' "$json" | grep -q '"verdict":"ok"' || fail "сценарий 15: _domains_check_json без verdict ok: $json"
  printf '%s' "$json" | grep -q 'Проверьте доступность вручную\|проверьте вручную' || fail "сценарий 15: в тексте TLS 1.2 нет подсказки проверить вручную"
  printf '%s' "$json" | python -c "import sys, json; json.load(sys.stdin)" \
    || fail "сценарий 15: JSON доменной проверки невалиден: $json"
)

# == 16. статический wiring ==
lib_sh="$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")"
printf '%s' "$lib_sh" | grep -q 'LIB_DIR/netcheck\.sh' || fail "сценарий 16: _lib.sh не подключает netcheck.sh"
if printf '%s' "$lib_sh" | grep -q -- '--tls-max 1\.2'; then fail "сценарий 16: в _lib.sh осталась локальная curl-логика TLS"; fi
printf '%s' "$lib_sh" | grep -q '_domains_check_json' || fail "сценарий 16: нет _domains_check_json"
printf '%s' "$lib_sh" | grep -q '^    check)' || fail "сценарий 16: нет действия check в domains"
grep -q 'checkVerdictClass' "$REPO_DIR/webui/app.js" || fail "сценарий 16: app.js не рендерит verdict"
grep -q 'renderDomainCheck' "$REPO_DIR/webui/app.js" || fail "сценарий 16: app.js без renderDomainCheck"
grep -q "action: 'check'" "$REPO_DIR/webui/app.js" || fail "сценарий 16: app.js не дергает action=check"
if grep -q 'domain-check-results' "$REPO_DIR/webui/app.js" "$REPO_DIR/webui/index.html"; then
  fail "сценарий 16: осталась глобальная коробка domain-check-results"
fi
grep -q 'class="checks domain-check"' "$REPO_DIR/webui/index.html" || fail "сценарий 16: index.html без inline-бокса проверки в строке домена"
grep -q 'domain-check-btn' "$REPO_DIR/webui/index.html" || fail "сценарий 16: index.html без кнопки Проверить"
grep -A 4 '^\.check-pair {' "$REPO_DIR/webui/styles.css" | grep -q 'flex-direction: column' \
  || fail "сценарий 16: строки проверки не вертикальные"
grep -q '\.domain-row \.domain-check \.check-title' "$REPO_DIR/webui/styles.css" \
  || fail "сценарий 16: нет компактных стилей проверки в строке домена"
grep -q '\.warn' "$REPO_DIR/webui/styles.css" || fail "сценарий 16: styles.css без .warn"
fake="$REPO_DIR/webui/dev/fake_router_server.py"
grep -q 'verdict' "$fake" || fail "сценарий 16: fake_router_server без verdict"
grep -q 'check_result == "random"' "$fake" || fail "сценарий 16: fake_router_server без режима random"
grep -q '_download_zero_detail' "$fake" || fail "сценарий 16: fake_router_server без жёлтого сценария zero-download"
grep -q 'action == "check"' "$fake" || fail "сценарий 16: fake_router_server без domains check"
grep -q 'import random' "$fake" || fail "сценарий 16: fake_router_server без import random"
grep -q '`check` | `list=custom_rkn&domain`' "$REPO_DIR/webui/dev/API_CONTRACT.md" \
  || fail "сценарий 16: API_CONTRACT без действия check"
cat "$fake" | python -c "import sys, ast; ast.parse(sys.stdin.read())" \
  || fail "сценарий 16: синтаксис fake_router_server.py"

echo "tls check smoke ok"
