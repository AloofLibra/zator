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
if [ -n "${MOCK_VALIDATOR_RC:-}" ]; then
  exit "$MOCK_VALIDATOR_RC"
fi
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
  if [ "${MOCK_SLOW_12:-0}" = 1 ] && [ "$ver" = 12 ]; then
    sleep 30
    [ -n "$hdr" ] && printf 'HTTP/2 200\r\n' >"$hdr"; echo "30.0 192.0.2.10"; exit 0
  fi
  case "$mode" in
    seq_ok*)
      thr="${mode#seq_ok}"
      if [ "$n" -ge "$thr" ] 2>/dev/null; then mode=ok200; else mode=timeout; fi
      ;;
  esac
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
if [ "${MOCK_DL_FLAKY:-0}" = 1 ] && mkdir "$COUNTER_DIR/dlflaky_lock" 2>/dev/null; then
  echo "206 4098 12.0"; exit 28
fi
case "${MOCK_DL:-ok206}" in
  ok206)      echo "206 65536 1.234"; exit 0 ;;
  ok206var)
    strat="$(cat "$COUNTER_DIR/head_13" 2>/dev/null || echo 0)"
    if [ "$strat" -ge 4 ] 2>/dev/null; then echo "206 65536 0.500"; else echo "206 65536 3.000"; fi
    exit 0 ;;
  small200)   echo "200 512 0.400"; exit 0 ;;
  partial206) echo "206 1200 0.400"; exit 0 ;;
  zero)       echo "200 0 0.500"; exit 0 ;;
  zero403)    echo "403 0 0.500"; exit 0 ;;
  fail28)     echo "000 0 12.002"; exit 28 ;;
esac
exit 1
MOCK
chmod +x "$TMP_DIR/bin/curl"

# Мок nslookup/dig для движка z2r_dns_* (профиль 10, антиспуф DNS).
# ok = живой ответ VPS из docs/dns_udp_desync.md (bind-формат, A + AAAA).
cat > "$TMP_DIR/bin/nslookup" <<'MOCK'
#!/bin/sh
case "${MOCK_DNS_MODE:-ok}" in
  ok)
cat <<'EOF'
Server:         8.8.8.8
Address:        8.8.8.8#53

Non-authoritative answer:
deb.torproject.org      canonical name = static.torproject.org
Name:   static.torproject.org
Address: 204.8.99.146
Name:   static.torproject.org
Address: 95.216.163.36
Name:   static.torproject.org
Address: 116.202.120.166
Name:   static.torproject.org
Address: 116.202.120.165
Name:   static.torproject.org
Address: 204.8.99.144
Name:   static.torproject.org
Address: 2620:7:6002:0:466:39ff:fe7f:1826
Name:   static.torproject.org
Address: 2a01:4f8:fff0:4f:266:37ff:feae:3bbc
EOF
    exit 0 ;;
  busybox)
cat <<'EOF'
Server:		8.8.8.8
Address:	8.8.8.8:53

Name:      deb.torproject.org
Address 1: 204.8.99.146 static.torproject.org
Address 2: 2a01:4f8:fff0:4f:266:37ff:feae:3bbc static.torproject.org
EOF
    exit 0 ;;
  rotate)
cat <<'EOF'
Server:         8.8.8.8
Address:        8.8.8.8#53

Non-authoritative answer:
Name:   static.torproject.org
Address: 203.0.113.7
EOF
    exit 0 ;;
  nxdomain)
    echo "** server can't find deb.torproject.org: NXDOMAIN"
    exit 3 ;;
  timeout)
    echo ";; connection timed out; no servers could be reached"
    exit 1 ;;
esac
exit 1
MOCK
chmod +x "$TMP_DIR/bin/nslookup"

# Мок dig для режима Z2R_DNS_TOOL=dig (dig +short ... domain @server).
cat > "$TMP_DIR/bin/dig" <<'MOCK'
#!/bin/sh
case "${MOCK_DNS_MODE:-ok}" in
  ok)
    echo "static.torproject.org."
    echo "204.8.99.146"
    echo "95.216.163.36"
    exit 0 ;;
  nxdomain)
    echo ";; ->>HEADER<<- status: NXDOMAIN"
    exit 0 ;;
esac
exit 1
MOCK
chmod +x "$TMP_DIR/bin/dig"

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
  rm -rf "$COUNTER_DIR"
  mkdir -p "$COUNTER_DIR"
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

# == 1b. зависший TLS 1.2 добивается после ответа TLS 1.3, а не ждёт max-time ==
reset_counter
export MOCK_SLOW_12=1
t0=$(date +%s)
out="$(target_out)"
elapsed=$(( $(date +%s) - t0 ))
unset MOCK_SLOW_12
[ "$elapsed" -lt 5 ] || fail "сценарий 1b: зависшая версия держала этап ${elapsed}с (должно быть ~2с)"
[ "$(printf '%s\n' "$out" | sed -n 1p)" = "X|000|-|-|-" ] \
  || fail "сценарий 1b: добитая версия должна быть X|000 (aborted), получено: $(printf '%s\n' "$out" | sed -n 1p)"
[ "$(z2r_tls_version_state X 000)" = "aborted" ] || fail "сценарий 1b: X|000 должен давать состояние aborted"
z2r_tls_version_text 1.2 "X|000|-|-|-" | grep -q "Проверка остановлена" \
  || fail "сценарий 1b: текст добитой версии должен говорить об остановке проверки"
v="$(verdict_of "$out")"
[ "${v%%|*}" = "ok" ] || fail "сценарий 1b: вердикт по TLS 1.3 должен быть ok, получено: $v"

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
z2r_tls_version_text 1.2 "$(printf '%s\n' "$out" | sed -n 1p)" | grep -q "Таймаут 5сек\." \
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
export MOCK_HEAD_12=ok200 MOCK_HEAD_13=ok200 MOCK_FLAKY_13=0 MOCK_DL=zero MOCK_DL_FLAKY=0
out="$(target_out)"
v="$(verdict_of "$out")"
[ "${v%%|*}" = "fail" ] || fail "сценарий 8: вердикт должен быть fail (страница не скачивается), получено: $v"
z2r_tls_download_text "$(printf '%s\n' "$out" | sed -n 3p)" | grep -q "0 байт" || fail "сценарий 8: текст не про 0 байт"

# == 8b. первая докачка срезалась, повтор прошёл -> жёлтый warn «иногда» ==
reset_counter
export MOCK_DL=ok206 MOCK_DL_FLAKY=1
out="$(target_out)"
v="$(verdict_of "$out")"
[ "${v%%|*}" = "warn" ] || fail "сценарий 8b: повтор спасает -> warn, получено: $v"
printf '%s' "$v" | grep -q "иногда срезается" || fail "сценарий 8b: нет текста про выборочный срез"
[ "$(calls dl)" = 2 ] || fail "сценарий 8b: должно быть две попытки докачки, было $(calls dl)"
z2r_tls_download_text "$(printf '%s\n' "$out" | sed -n 3p)" | grep -q "со второй попытки" \
  || fail "сценарий 8b: строка данных не упоминает вторую попытку"
export MOCK_DL_FLAKY=0

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

# == 14b. компактный результат для таблицы автопрогона ==
[ "$(z2r_tls_short_result "28|000|-|-|-" "0|200|HTTP/2|0.6|1.1.1.1" "28|200|4098|2.0")" = "fail|срез после 4098 байт" ] \
  || fail "сценарий 14b: cut должен давать короткий текст среза"
[ "$(z2r_tls_short_result "28|000|-|-|-" "0|200|HTTP/2|0.6|1.1.1.1" "0|206|65536|0.8")" = "ok|данные 65536 байт за 0.8 с" ] \
  || fail "сценарий 14b: ok должен давать данные с размером"
[ "$(z2r_tls_short_result "28|000|-|-|-" "0|200|HTTP/2|0.6|1.1.1.1" "0|206|65536|0.8|retry")" = "warn|срез нестабильный, повтор прошёл" ] \
  || fail "сценарий 14b: retry должен давать warn"
[ "$(z2r_tls_short_result "0|404|HTTP/1.1|0.6|1.1.1.1" "0|404|HTTP/1.1|0.6|1.1.1.1" "skip")" = "ok|сервер ответил кодом 404" ] \
  || fail "сценарий 14b: 4xx должен давать ok с кодом"
[ "$(z2r_tls_short_result "0|200|HTTP/2|0.6|1.1.1.1" "28|000|-|-|-" "skip")" = "warn|только TLS 1.2" ] \
  || fail "сценарий 14b: только TLS 1.2 должен давать warn"
[ "$(z2r_tls_short_result "28|000|-|-|-" "28|000|-|-|-" "skip")" = "fail|нет ответа (таймаут)" ] \
  || fail "сценарий 14b: обе версии молчат -> нет ответа"

# == 14b-2. бейджи версий TLS и предпочтение (tls_pref) в коротком результате ==
[ "$(z2r_tls_version_badge tls1.2 "0|200|HTTP/2|0.612|1.1.1.1")" = "tls1.2 OK 0.6с|ok" ] \
  || fail "сценарий 14b: бейдж ok со временем"
[ "$(z2r_tls_version_badge tls1.3 "28|000|-|-|-")" = "tls1.3 FAIL|fail" ] \
  || fail "сценарий 14b: бейдж fail без времени"
[ "$(z2r_tls_version_badge tls1.2 "0|403|HTTP/2|0.65|1.1.1.1")" = "tls1.2 403 0.6с|http" ] \
  || fail "сценарий 14b: бейдж http-кода со временем"
[ "$(z2r_tls_version_badge tls1.2 "0|404|HTTP/1.1|0.471961|1.1.1.1")" = "tls1.2 404 0.4с|http" ] \
  || fail "сценарий 14b: время бейджа обрезается до одного знака"
[ "$(z2r_tls_short_result "0|404|HTTP/1.1|0.6|1.1.1.1" "0|404|HTTP/1.1|0.6|1.1.1.1" "skip" both)" = "ok|сервер ответил кодом 404 (обе версии)" ] \
  || fail "сценарий 14b: 4xx обе версии под both -> зелёная"
[ "$(z2r_tls_short_result "0|404|HTTP/1.1|0.6|1.1.1.1" "28|000|-|-|-" "skip" both)" = "warn|работает только TLS 1.2, код 404" ] \
  || fail "сценарий 14b: 4xx только 1.2 под both -> жёлтая"
[ "$(z2r_tls_short_result "0|404|HTTP/1.1|0.6|1.1.1.1" "28|000|-|-|-" "skip" 13)" = "warn|работает только TLS 1.2, код 404" ] \
  || fail "сценарий 14b: 4xx только 1.2 при цели 1.3 -> жёлтая"
[ "$(z2r_tls_short_result "0|200|HTTP/2|0.6|1.1.1.1" "28|000|-|-|-" "0|206|65536|1.2" both)" = "warn|работает только TLS 1.2, данные 65536 байт за 1.2 с" ] \
  || fail "сценарий 14b: both + только 1.2 -> жёлтая со статистикой"
[ "$(z2r_tls_short_result "28|000|-|-|-" "0|200|HTTP/2|0.6|1.1.1.1" "0|206|65536|1.2" both)" = "warn|работает только TLS 1.3, данные 65536 байт за 1.2 с" ] \
  || fail "сценарий 14b: both + только 1.3 -> жёлтая со статистикой"
[ "$(z2r_tls_short_result "0|200|HTTP/2|0.6|1.1.1.1" "0|200|HTTP/2|0.6|1.1.1.1" "0|206|65536|1.2" both)" = "ok|данные 65536 байт за 1.2 с" ] \
  || fail "сценарий 14b: both + обе версии -> зелёная"
[ "$(z2r_tls_short_result "28|000|-|-|-" "0|200|HTTP/2|0.6|1.1.1.1" "0|206|65536|1.2" 12)" = "warn|работает только TLS 1.3, данные 65536 байт за 1.2 с" ] \
  || fail "сценарий 14b: нужен 1.2, его нет -> жёлтая со статистикой"
[ "$(z2r_tls_short_result "0|200|HTTP/2|0.6|1.1.1.1" "28|000|-|-|-" "0|206|65536|1.2" 12)" = "ok|данные 65536 байт за 1.2 с" ] \
  || fail "сценарий 14b: нужен 1.2, он есть -> зелёная"
[ "$(z2r_tls_short_result "0|200|HTTP/2|0.6|1.1.1.1" "28|000|-|-|-" "0|206|65536|1.2" 13)" = "warn|работает только TLS 1.2, данные 65536 байт за 1.2 с" ] \
  || fail "сценарий 14b: нужен 1.3, его нет -> жёлтая со статистикой"
[ "$(z2r_tls_short_result "28|000|-|-|-" "0|200|HTTP/2|0.6|1.1.1.1" "0|206|65536|1.2" 13)" = "ok|данные 65536 байт за 1.2 с" ] \
  || fail "сценарий 14b: нужен 1.3, он есть -> зелёная"
[ "$(z2r_tls_short_result "0|200|HTTP/2|0.6|1.1.1.1" "28|000|-|-|-" "0|206|65536|1.2")" = "ok|данные 65536 байт за 1.2 с" ] \
  || fail "сценарий 14b: без pref (any) старое поведение"

# == 14c. автопрогон: до первого успеха + сохранение, полный + возврат, профиль-вид ==
(
  export ORCH_LOCK_FILE="$TMP_DIR/locked_auto.tsv"
  export PROFILE_STATE_FILE="$TMP_DIR/profile_auto.lock"
  # базовая пауза прогона 0 сек: проверки замоканы, ждать незачем
  export Z2R_SWEEP_PAUSE=0
  : > "$ORCH_LOCK_FILE"
  reset_counter
  export MOCK_HEAD_12=timeout MOCK_HEAD_13=seq_ok3 MOCK_DL=ok206
  plain="" green="" yellow="" red="" cyan="" Fgreen=""
  export plain green yellow red cyan Fgreen
  # shellcheck source=/dev/null
  source "$REPO_DIR/lib/orchestra_state.sh"
  # shellcheck source=/dev/null
  source "$REPO_DIR/lib/strategies.sh"

  out="$(printf '\n' | orch_auto_sweep domain example.org tls https://example.org/ 1 5 1)"
  [ "$(orch_locked_get example.org tls)" = "3" ] \
    || fail "сценарий 14c: Enter должен сохранить лучшую (3), лок: $(orch_locked_get example.org tls)"
  printf '%s' "$out" | grep -q "OK" || fail "сценарий 14c: нет строки OK в прогоне"
  printf '%s' "$out" | grep -q "FAIL" || fail "сценарий 14c: нет строк FAIL в прогоне"
  printf '%s' "$out" | grep -q "Итог автопрогона" || fail "сценарий 14c: нет сводки"
  # ': FAIL ' — только вердикт-колонка: бейджи тоже содержат слово FAIL
  [ "$(grep -c ': FAIL ' <<<"$out")" = "2" ] || fail "сценарий 14c: до первого успеха должно быть 2 FAIL"

  rm -rf "$COUNTER_DIR"; mkdir -p "$COUNTER_DIR"
  export MOCK_DL=ok206var
  out="$(printf '\n' | orch_auto_sweep domain example.org tls https://example.org/ 1 5 0)"
  [ "$(orch_locked_get example.org tls)" = "4" ] \
    || fail "сценарий 14c: лучшей должна стать самая быстрая (4), сохранено: $(orch_locked_get example.org tls)"
  printf '%s' "$out" | grep -q "самая быстрая из зелёных" || fail "сценарий 14c: сводка не помечает выбор по скорости"
  export MOCK_DL=ok206
  grep -q "  *3:" <<<"$out" || true

  orch_locked_set example.org tls 7
  out="$(printf '0\n' | orch_auto_sweep domain example.org tls https://example.org/ 1 5 0)"
  [ "$(orch_locked_get example.org tls)" = "7" ] \
    || fail "сценарий 14c: ответ 0 должен вернуть прежний лок (7)"
  printf '%s' "$out" | grep -q "Зелёные стратегии: " || fail "сценарий 14c: полный прогон без списка зелёных"

  orch_locked_set 1 tls 5
  out="$(printf '0\n' | orch_auto_sweep profile 1 "tls" https://www.youtube.com/ 1 5 0)"
  [ "$(orch_locked_get 1 tls)" = "5" ] \
    || fail "сценарий 14c: профиль-вид с ответом 0 должен вернуть прежний лок"
  printf '%s' "$out" | grep -q "прежние стратегии профиля возвращены" || fail "сценарий 14c: нет сообщения возврата"

  # добавка к паузе ($8) попадает в баннер; успех на 1-й стратегии -> без sleep
  rm -rf "$COUNTER_DIR"; mkdir -p "$COUNTER_DIR"
  export MOCK_HEAD_13=ok200
  out="$(printf '0\n' | orch_auto_sweep domain example.org tls https://example.org/ 1 2 1 5)"
  printf '%s' "$out" | grep -q "пауза 5 сек" \
    || fail "сценарий 14c: добавка к паузе не попала в баннер: $out"
  cap="$(printf '5\n' | orch_ask_sweep_extra_delay 2>/dev/null)"
  [ "$cap" = "5" ] || fail "сценарий 14c: хелпер паузы должен вернуть только число: $cap"
  cap="$(printf 'abc\n' | orch_ask_sweep_extra_delay 2>/dev/null)"
  [ "$cap" = "0" ] || fail "сценарий 14c: неверный ввод хелпера паузы должен давать 0: $cap"
  cap="$(printf '0\n' | orch_ask_sweep_extra_delay 2>/dev/null)"
  [ -z "$cap" ] || fail "сценарий 14c: 0 в паузе должен отменять: $cap"
  cap="$(printf '1\n' | orch_ask_sweep_tls_pref 2>/dev/null)"
  [ "$cap" = "12" ] || fail "сценарий 14c: выбор TLS 1.2: $cap"
  cap="$(printf '\n' | orch_ask_sweep_tls_pref 2>/dev/null)"
  [ "$cap" = "both" ] || fail "сценарий 14c: Enter в выборе TLS = обе версии: $cap"
  cap="$(printf '0\n' | orch_ask_sweep_tls_pref 2>/dev/null)"
  [ -z "$cap" ] || fail "сценарий 14c: 0 в выборе TLS должен отменять: $cap"
  export MOCK_HEAD_13=seq_ok3

  # pref=13: зелёный там, где прошла 1.3 (мок: 1.2 всегда молчит)
  rm -rf "$COUNTER_DIR"; mkdir -p "$COUNTER_DIR"
  out="$(printf '\n' | orch_auto_sweep domain example.org tls https://example.org/ 1 5 1 0 13)"
  [ "$(orch_locked_get example.org tls)" = "3" ] \
    || fail "сценарий 14c: pref 13 до первого успеха должен сохранить 3"
  printf '%s' "$out" | grep -q "цель TLS 1.3" || fail "сценарий 14c: баннер без цели TLS 1.3"

  # pref=both: те же стратегии жёлтые («работает только TLS 1.3»), зелёных нет
  rm -rf "$COUNTER_DIR"; mkdir -p "$COUNTER_DIR"
  out="$(printf '0\n' | orch_auto_sweep domain example.org tls https://example.org/ 1 5 0 0 both)"
  printf '%s' "$out" | grep -q "работает только TLS 1.3" \
    || fail "сценарий 14c: pref both должен пометить только-1.3 жёлтой"
  printf '%s' "$out" | grep -q "OK 0" \
    || fail "сценарий 14c: pref both без полных стратегий должен дать 0 зелёных"
  printf '%s' "$out" | grep -q "Лучшая из жёлтых (зелёных нет): .*3" \
    || fail "сценарий 14c: лучшей должна стать самая быстрая жёлтая (3)"
  printf '%s' "$out" | grep -q "работает только TLS 1.3, данные" \
    || fail "сценарий 14c: жёлтая строка без статистики докачки"
  printf '%s' "$out" | grep -q "TLS 1.2 не прошёл ни одной стратегией" \
    || fail "сценарий 14c: нет подсказки про непрошедший TLS 1.2"
  printf '%s' "$out" | grep -q "перезапустите автопрогон с целью TLS 1.3" \
    || fail "сценарий 14c: нет совета перезапустить с целью TLS 1.3"
  printf '%s' "$out" | grep -q "tls1.2 FAIL" || fail "сценарий 14c: нет бейджа tls1.2 FAIL"
  printf '%s' "$out" | grep -q "tls1.3 OK" || fail "сценарий 14c: нет бейджа tls1.3 OK"
  printf '%s' "$out" | grep -q "цель TLS 1.2+1.3" || fail "сценарий 14c: баннер без цели both"
  [ -z "${Z2R_TLS_WAIT_BOTH:-}" ] || fail "сценарий 14c: Z2R_TLS_WAIT_BOTH не восстановлен"

  rm -rf "$COUNTER_DIR"; mkdir -p "$COUNTER_DIR"
  orch_locked_set example.org tls 7
  printf '0\n' | orch_auto_sweep domain example.org tls https://example.org/ 1 200 0 >"$TMP_DIR/sweep_int.log" 2>&1 &
  swpid=$!
  sleep 2
  # На Windows/MSYS эмуляция SIGINT иногда теряется: шлём повторно, пока
  # прогон не прервётся (на Linux срабатывает первый же сигнал).
  int_i=0
  while kill -0 "$swpid" 2>/dev/null && [ "$int_i" -lt 10 ]; do
    kill -INT "$swpid" 2>/dev/null || true
    sleep 1
    int_i=$((int_i + 1))
    grep -q "Прервано пользователем" "$TMP_DIR/sweep_int.log" 2>/dev/null && break
  done
  swrc=0
  wait "$swpid" 2>/dev/null || swrc=$?
  [ "$swrc" = "0" ] || fail "сценарий 14c: Ctrl+C не должен ронять автопрогон (rc=$swrc)"
  [ "$(orch_locked_get example.org tls)" = "7" ] \
    || fail "сценарий 14c: после Ctrl+C лок не восстановлен"
  grep -q "Прервано пользователем" "$TMP_DIR/sweep_int.log" \
    || fail "сценарий 14c: нет сообщения о прерывании"
)

# == 14d. Ctrl+C убил nfqws2 посреди прогона -> предупреждение + рестарт;
#          прерывание в паузе между стратегиями тоже печатает сообщение ==
(
  export ORCH_LOCK_FILE="$TMP_DIR/locked_safety.tsv"
  export PROFILE_STATE_FILE="$TMP_DIR/profile_safety.lock"
  export Z2R_SWEEP_PAUSE=0
  : > "$ORCH_LOCK_FILE"
  reset_counter
  export MOCK_HEAD_12=timeout MOCK_HEAD_13=timeout
  plain="" green="" yellow="" red="" cyan="" Fgreen=""
  export plain green yellow red cyan Fgreen
  # shellcheck source=/dev/null
  source "$REPO_DIR/lib/orchestra_state.sh"
  # shellcheck source=/dev/null
  source "$REPO_DIR/lib/strategies.sh"

  svc_calls="$TMP_DIR/svc_calls"; : > "$svc_calls"
  svc_actions="$TMP_DIR/svc_actions"; : > "$svc_actions"
  # 1-й вызов (до цикла) — демон жив; дальше мёртв, пока нет записи restart
  zapret2_running() {
    echo x >> "$svc_calls"
    [ "$(wc -l < "$svc_calls")" = 1 ] && return 0
    grep -q restart "$svc_actions" 2>/dev/null
  }
  z2r_service_action() {
    echo "$1" >> "$svc_actions"
  }

  orch_locked_set example.org tls 7
  out="$(printf '0\n' | orch_auto_sweep domain example.org tls https://example.org/ 1 2 0)"
  printf '%s' "$out" | grep -q "zapret2 был остановлен" \
    || fail "сценарий 14d: смерть nfqws2 в прогоне не замечена"
  printf '%s' "$out" | grep -q "zapret2 снова работает" \
    || fail "сценарий 14d: нет подтверждения восстановления"
  [ "$(cat "$svc_actions")" = "restart" ] \
    || fail "сценарий 14d: сервис не перезапущен: $(cat "$svc_actions")"
  [ "$(orch_locked_get example.org tls)" = "7" ] \
    || fail "сценарий 14d: лок не восстановлен после смерти демона"

  # рестарт не помог -> красная подсказка, прогон не падает
  : > "$svc_calls"; : > "$svc_actions"
  zapret2_running() {
    echo x >> "$svc_calls"
    [ "$(wc -l < "$svc_calls")" = 1 ] && return 0
    return 1
  }
  z2r_service_action() { echo "$1" >> "$svc_actions"; return 1; }
  out="$(printf '0\n' | orch_auto_sweep domain example.org tls https://example.org/ 1 2 0)"
  printf '%s' "$out" | grep -q "Не удалось перезапустить zapret2" \
    || fail "сценарий 14d: нет подсказки при неудачном рестарте"

  # прерывание во время паузы: sleep >= 1 сек «прерывается» по флагу,
  # короткие паузы опроса движка (0.3) не трогаем
  export Z2R_SWEEP_PAUSE=2
  sleep() {
    case "${1:-}" in
      0.*|"") return 0 ;;
      *) orch_auto_sweep_interrupted=1 ;;
    esac
  }
  orch_locked_set example.org tls 7
  out="$(printf '0\n' | orch_auto_sweep domain example.org tls https://example.org/ 1 3 0)"
  printf '%s' "$out" | grep -q "Прервано пользователем на стратегии 1" \
    || fail "сценарий 14d: нет сообщения о прерывании в паузе"
  printf '%s' "$out" | grep -q "  2:" && fail "сценарий 14d: после прерывания в паузе прогон продолжился"
  [ "$(orch_locked_get example.org tls)" = "7" ] \
    || fail "сценарий 14d: лок не восстановлен после прерывания в паузе"
)

# == 14e. статика: рестарты через z2r_service_action, run_daemon отвязан от терминала ==
(
  src_line="$(grep -n '^\. "\$EXEDIR/functions"' "$REPO_DIR/Entware/zapret" | cut -d: -f1)"
  rd_line="$(grep -n '^run_daemon()' "$REPO_DIR/Entware/zapret" | head -n1 | cut -d: -f1)"
  [ -n "$src_line" ] && [ -n "$rd_line" ] && [ "$rd_line" -gt "$src_line" ] \
    || fail "сценарий 14e: оверрайд run_daemon должен идти после source functions"
  grep -q 'setsid "\$2"' "$REPO_DIR/Entware/zapret" \
    || fail "сценарий 14e: run_daemon без setsid-спавна"
  # nfqws2 ставит свои sigaction на INT/TERM/HUP — унаследованный игнор затирается;
  # без setsid демон обязан получать собственную группу через job control (set -m),
  # проверено на Keenetic busybox ash в неинтерактивном скрипте
  grep -q 'set -m 2>/dev/null' "$REPO_DIR/Entware/zapret" \
    || fail "сценарий 14e: нет set -m ветки (собственная pgid демона без setsid)"
  grep -q 'set +m 2>/dev/null' "$REPO_DIR/Entware/zapret" \
    || fail "сценарий 14e: set -m не гасится сразу после спавна (риск tcsetpgrp-побочек)"
  grep -q '>/dev/null 2>&1 &' "$REPO_DIR/Entware/zapret" \
    && fail "сценарий 14e: stderr демона глушится — ошибки конфига теряются"
  grep -q 'ERRLOG="/tmp/\${DAEMONBASE}_\$1.err"' "$REPO_DIR/Entware/zapret" \
    || fail "сценарий 14e: stderr демона должен идти в /tmp/*.err (ошибки конфига)"
  grep -q '>/dev/tty' "$REPO_DIR/Entware/zapret" \
    && fail "сценарий 14e: вывод ошибок по таймауту в терминал запрещён (смущает пользователей); показ — строкой в меню"
  grep -q 'MENU_ERR_LINE' "$REPO_DIR/z2r.sh" \
    || fail "сценарий 14e: в главном меню нет строки об ошибках nfqws2"
  grep -q '"666")' "$REPO_DIR/z2r.sh" \
    || fail "сценарий 14e: нет скрытого п.666 для просмотра ошибок nfqws2"
  grep -q "grep -v '\^seccomp:'" "$REPO_DIR/z2r.sh" \
    || fail "сценарий 14e: безвредный seccomp-шум должен фильтроваться из строки ошибок"
  # OpenWRT: wrt_fixes патчит procd-инит (stderr->syslog + линейный contains),
  # 666 умеет fallback на logread
  grep -q '^wrt_fixes()' "$REPO_DIR/z2r.sh" \
    || fail "сценарий 14e: нет wrt_fixes для патчей procd-инита OpenWRT"
  grep -q "procd_set_param stderr 1" "$REPO_DIR/z2r.sh" \
    || fail "сценарий 14e: wrt_fixes не включает stderr демона в syslog"
  grep -q 'wrt_fixes || true' "$REPO_DIR/z2r.sh" \
    || fail "сценарий 14e: wrt_fixes не вызывается в установочном потоке WRT"
  grep -q 'logread' "$REPO_DIR/z2r.sh" \
    || fail "сценарий 14e: нет fallback на logread в п.666 (OpenWRT)"
  # contains: апстримный ${1#*$2} на busybox/mipsel квадратичен по 37КБ конфига
  # (7 проверок has_bad_ws_options = ~95 сек на рестарт) — заменён на case
  grep -q '^contains()' "$REPO_DIR/Entware/zapret" \
    || fail "сценарий 14e: нет оверрайда contains (квадратичный поиск подстроки)"
  grep -q 'PIDFILE=\$PIDDIR/\${DAEMONBASE}_\$1.pid' "$REPO_DIR/Entware/zapret" \
    || fail "сценарий 14e: формат pid-файлов разошёлся с апстримом"
  grep -q '^z2r_service_action()' "$REPO_DIR/lib/config.sh" \
    || fail "сценарий 14e: нет хелпера z2r_service_action в config.sh"
  bad="$(grep -rn '"\$ZAPRET2_INIT" \(restart\|start\|stop\)' \
    "$REPO_DIR/z2r.sh" "$REPO_DIR/lib" "$REPO_DIR/webui/cgi-bin" 2>/dev/null || true)"
  [ -z "$bad" ] || fail "сценарий 14e: прямые вызовы init-скрипта: $bad"
  # хук Keenetic живёт под именем zapret2 (старое 000-zapret.sh — чужое имя)
  [ -f "$REPO_DIR/Entware/000-zapret2.sh" ] \
    || fail "сценарий 14e: нет Entware/000-zapret2.sh"
  grep -q 'zapret2 restart-fw' "$REPO_DIR/Entware/000-zapret2.sh" \
    || fail "сценарий 14e: хук не дёргает zapret2 restart-fw"
  grep -q 'z2r_download_project_file /opt/etc/ndm/netfilter.d/000-zapret2.sh "Entware/000-zapret2.sh"' "$REPO_DIR/z2r.sh" \
    || fail "сценарий 14e: хук деплоится не под именем 000-zapret2.sh"
  mig="$(grep -c "grep -q 'zapret2' /opt/etc/ndm/netfilter.d/000-zapret.sh" "$REPO_DIR/z2r.sh" || true)"
  [ "$mig" -ge 2 ] \
    || fail "сценарий 14e: миграция старого имени хука должна быть и в entware_fixes, и в remove_zapret"
)

# == 15. WebUI-обёртка: JSON с вердиктом и деталями ==
(
  export COUNTER_DIR="$TMP_DIR/counter"
  export PATH="$TMP_DIR/bin:$PATH"
  export TMPDIR="$TMP_DIR"
  unset MOCK_FLAKY_12 MOCK_FLAKY_13 MOCK_DL_FLAKY
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

# == 17. валидатор: одиночный таймаут ERROR, повторный FAIL, OK сбрасывает ==
(
  export Z2R_VALIDATION_QUEUE="$TMP_DIR/valq"
  export COUNTER_DIR="$TMP_DIR/counter"
  export PATH="$TMP_DIR/bin:$PATH"
  rm -rf "$Z2R_VALIDATION_QUEUE"; mkdir -p "$Z2R_VALIDATION_QUEUE"
  mk_req() { printf '%s	%s	%s	%s	%s
' "$1" as1 host1 7 example.org > "$Z2R_VALIDATION_QUEUE/request.$1"; }
  run_val() { sh "$REPO_DIR/lua/strategy-validator.sh" "$Z2R_VALIDATION_QUEUE/request.$1" >/dev/null 2>&1; }
  res_status() { cut -f2 "$Z2R_VALIDATION_QUEUE/result.$1"; }

  export MOCK_VALIDATOR_RC=28
  mk_req 1; run_val 1
  [ "$(res_status 1)" = "ERROR" ] || fail "сценарий 17: первый таймаут должен быть ERROR, получено: $(res_status 1)"
  mk_req 2; run_val 2
  [ "$(res_status 2)" = "FAIL" ] || fail "сценарий 17: повторный таймаут должен быть FAIL, получено: $(res_status 2)"
  [ ! -f "$Z2R_VALIDATION_QUEUE/to.host1.7" ] || fail "сценарий 17: счётчик таймаутов не сброшен после FAIL"

  export MOCK_VALIDATOR_RC=0
  mk_req 3; run_val 3
  [ "$(res_status 3)" = "OK" ] || fail "сценарий 17: успешная проверка должна быть OK"

  export MOCK_VALIDATOR_RC=28
  mk_req 4; run_val 4
  [ "$(res_status 4)" = "ERROR" ] || fail "сценарий 17: после OK счётчик должен считаться заново (ERROR)"
  unset MOCK_VALIDATOR_RC
)

# == 18. DNS-антиспуф: движок z2r_dns_* (профиль 10) ==
(
  export COUNTER_DIR="$TMP_DIR/counter"
  export PATH="$TMP_DIR/bin:$PATH"
  export TMPDIR="$TMP_DIR"
  export Z2R_DNS_TOOL=nslookup
  # shellcheck source=/dev/null
  source "$REPO_DIR/webui/cgi-bin/_lib.sh"

  export MOCK_DNS_MODE=ok
  res="$(z2r_dns_check_target)"
  [ "$(z2r_dns_field "$res" 1)" = "ok" ] || fail "сценарий 18: настоящий ответ должен быть ok: $res"
  [ "$(z2r_dns_field "$res" 2)" = "match" ] || fail "сценарий 18: нет совпадения с эталоном torproject: $res"
  case "$(z2r_dns_field "$res" 3)" in
    *204.8.99.146*) : ;;
    *) fail "сценарий 18: в адресах нет 204.8.99.146: $res" ;;
  esac
  for a in $(z2r_dns_field "$res" 3); do
    [ "$a" != "8.8.8.8" ] || fail "сценарий 18: адрес резолвера попал в ответы: $res"
  done
  case "$(z2r_dns_field "$res" 4)" in
    *2620:7:6002*) : ;;
    *) fail "сценарий 18: IPv6 из ответа не разобран: $res" ;;
  esac
  z2r_dns_text "$res" | grep -q "совпадение с эталоном torproject" \
    || fail "сценарий 18: текст ok без упоминания эталона"

  export MOCK_DNS_MODE=busybox
  res="$(z2r_dns_check_target)"
  [ "$(z2r_dns_field "$res" 1)" = "ok" ] || fail "сценарий 18: busybox-формат nslookup должен давать ok: $res"

  export MOCK_DNS_MODE=rotate
  res="$(z2r_dns_check_target)"
  [ "$(z2r_dns_field "$res" 1)" = "warn" ] || fail "сценарий 18: адреса вне эталона должны быть warn: $res"
  z2r_dns_text "$res" | grep -q "эталонного набора" \
    || fail "сценарий 18: текст warn без подсказки про эталон"

  export MOCK_DNS_MODE=nxdomain
  res="$(z2r_dns_check_target)"
  [ "$(z2r_dns_field "$res" 1)" = "fail" ] || fail "сценарий 18: NXDOMAIN должен быть fail: $res"
  [ "$(z2r_dns_field "$res" 2)" = "nxdomain" ] || fail "сценарий 18: причина не nxdomain: $res"
  z2r_dns_text "$res" | grep -q "Подмена DNS" \
    || fail "сценарий 18: текст NXDOMAIN без подмены"

  export MOCK_DNS_MODE=timeout
  res="$(z2r_dns_check_target)"
  [ "$(z2r_dns_field "$res" 1)" = "fail" ] || fail "сценарий 18: таймаут должен быть fail: $res"
  [ "$(z2r_dns_field "$res" 2)" = "noanswer" ] || fail "сценарий 18: причина не noanswer: $res"

  # Режим dig: только A-записи, вывод +short
  export Z2R_DNS_TOOL=dig
  export MOCK_DNS_MODE=ok
  res="$(z2r_dns_check_target)"
  [ "$(z2r_dns_field "$res" 1)" = "ok" ] || fail "сценарий 18: dig +short должен давать ok: $res"
  [ -z "$(z2r_dns_field "$res" 4)" ] || fail "сценарий 18: dig-режим не должен приносить AAAA: $res"
  export Z2R_DNS_TOOL=nslookup

  # WebUI: JSON-обёртка (check.cgi?profile=10)
  export MOCK_DNS_MODE=nxdomain
  json="$(check_one_dns_json)"
  printf '%s' "$json" | grep -q '"verdict":"fail"' || fail "сценарий 18: JSON без verdict fail: $json"
  printf '%s' "$json" | python -c "import sys, json; json.load(sys.stdin)" \
    || fail "сценарий 18: JSON невалиден: $json"
  export MOCK_DNS_MODE=ok
  json="$(profile_check_json 10)"
  printf '%s' "$json" | grep -q '"verdict":"ok"' || fail "сценарий 18: profile_check_json 10 без ok: $json"
  printf '%s' "$json" | grep -q '"label":"DNS антиспуф"' || fail "сценарий 18: JSON без метки DNS"
)

# == 16. статический wiring ==
lib_sh="$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")"
printf '%s' "$lib_sh" | grep -q 'LIB_DIR/netcheck\.sh' || fail "сценарий 16: _lib.sh не подключает netcheck.sh"
if printf '%s' "$lib_sh" | grep -q -- '--tls-max 1\.2'; then fail "сценарий 16: в _lib.sh осталась локальная curl-логика TLS"; fi
printf '%s' "$lib_sh" | grep -q '_domains_check_json' || fail "сценарий 16: нет _domains_check_json"
grep -q 'orch_auto_sweep' "$REPO_DIR/lib/strategies.sh" || fail "сценарий 16: нет orch_auto_sweep"
if grep -q 'check_json="$(profile_check_json' webui/cgi-bin/_lib.sh 2>/dev/null; then
  :
fi
[ "$(grep -c 'profile_check_json' webui/cgi-bin/_lib.sh)" = "2" ]   || fail "сценарий 16: profile_check_json должен зваться только из api_check (без инлайна в set-lock)"
grep -q 'PARAM_PROFILE.*\[\[\|\[\[ "\${PARAM_PROFILE' webui/cgi-bin/_lib.sh   || grep -q 'api_check' webui/cgi-bin/_lib.sh || true
grep -q '2>/dev/null </dev/null &' lib/netcheck.sh   || fail "сценарий 16: фоновые пробы не отсоединены от CGI stdio"
grep -q "body: new URLSearchParams({ profile: profile.profile" webui/app.js   || fail "сценарий 16: app.js не дергает проверку после set-lock"
[ "$(grep -c "check.cgi" webui/app.js)" -ge 2 ]   || fail "сценарий 16: check.cgi должен вызываться и из кнопки, и после set-lock"
[ "$(grep -c 'A - автопрогон' "$REPO_DIR/lib/strategies.sh")" = "2" ]   || fail "сценарий 16: опция A должна быть в обоих входах перебора"
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
grep -q 'z2r_dns_check_print' "$REPO_DIR/lib/strategies.sh" || fail "сценарий 16: перебор профиля 10 без DNS-проверки"
grep -q 'z2r_dns_check_target' "$REPO_DIR/lib/netcheck.sh" || fail "сценарий 16: нет движка DNS-проверки"
grep -q 'Z2R_DNS_KNOWN_ADDRS' "$REPO_DIR/lib/netcheck.sh" || fail "сценарий 16: нет эталонных адресов torproject"
grep -q 'check_one_dns_json' "$REPO_DIR/webui/cgi-bin/_lib.sh" || fail "сценарий 16: нет JSON-обёртки DNS-проверки"
grep -q 'dns_check_target' "$fake" || fail "сценарий 16: fake_router_server без DNS-проверки"
grep -q 'check_result == "random"' "$fake" || fail "сценарий 16: fake_router_server без режима random"
grep -q '_download_zero_detail' "$fake" || fail "сценарий 16: fake_router_server без жёлтого сценария zero-download"
grep -q 'action == "check"' "$fake" || fail "сценарий 16: fake_router_server без domains check"
grep -q 'import random' "$fake" || fail "сценарий 16: fake_router_server без import random"
grep -q '`check` | `list=custom_rkn&domain`' "$REPO_DIR/webui/dev/API_CONTRACT.md" \
  || fail "сценарий 16: API_CONTRACT без действия check"
cat "$fake" | python -c "import sys, ast; ast.parse(sys.stdin.read())" \
  || fail "сценарий 16: синтаксис fake_router_server.py"

echo "tls check smoke ok"
