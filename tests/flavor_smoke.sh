#!/usr/bin/env bash
#
# Smoke-тест выбора сборки zapret2 (official / fork) в z2r.sh.
# Только во временной директории, без сети и /opt.
#
# Покрывает:
#   0. bash -n z2r.sh, статические инварианты (форк-URL, рекомендация Keenetic);
#   1. zapret2_flavor_load/save: дефолт official, круговорот fork, мусор в файле;
#   2. z2r_version_valid: официальный формат против суффикса форка;
#   3. z2r_download_zapret2_release: fork качает только с GitHub форка
#      (зеркало и Яндекс.Диск не вызываются), official строит прежний URL;
#   4. zapret2_flavor_prompt: EOF = дефолт (Keenetic -> fork, остальные ->
#      official), сохранённый выбор сохраняется при EOF.
#
# Запуск:  bash tests/flavor_smoke.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
Z2R="$ROOT/z2r.sh"
TMP="$(mktemp -d /tmp/z2r_flavor_smoke.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }

plain=""; green=""; yellow=""; red=""; cyan=""
ZATOR_ROOT="$TMP/zator"
mkdir -p "$ZATOR_ROOT/extra_strats/cache"

# --- извлечение функций из z2r.sh (объявлены от колонки 0) ---
extract() {
  local fn="$1" out="$2"
  sed -n "/^${fn}()/,/^}/p" "$Z2R" > "$out"
  [ -s "$out" ]
}
for fn in zapret2_flavor_file zapret2_flavor_load zapret2_flavor_save \
           z2r_version_valid zapret2_flavor_prompt z2r_download_zapret2_release; do
  extract "$fn" "$TMP/$fn.sh" || { bad "извлечение $fn"; }
done
cat "$TMP"/zapret2_flavor_file.sh "$TMP"/zapret2_flavor_load.sh \
    "$TMP"/zapret2_flavor_save.sh "$TMP"/z2r_version_valid.sh \
    "$TMP"/zapret2_flavor_prompt.sh "$TMP"/z2r_download_zapret2_release.sh \
    > "$TMP/lib.sh"

# --- 0. синтаксис и статика ---
bash -n "$Z2R" && ok "bash -n z2r.sh" || bad "bash -n z2r.sh"
grep -q 'ZAPRET2_FORK_RELEASE_BASE="${ZAPRET2_FORK_RELEASE_BASE' "$Z2R" \
  && ok "статика: форк-база объявлена" || bad "статика: форк-база"
grep -q 'На Keenetic рекомендуется вариант 2' "$Z2R" \
  && ok "статика: рекомендация Keenetic" || bad "статика: рекомендация"
grep -q ' zapret2_flavor_prompt' "$Z2R" \
  && ok "статика: промпт вызывается" || bad "статика: вызов промпта"

# --- 1. flavor load/save ---
r="$(ZATOR_ROOT="$ZATOR_ROOT" bash -c ". '$TMP/lib.sh'; zapret2_flavor_load")"
[ "$r" = official ] && ok "load: дефолт official" || bad "load: дефолт = $r"
ZATOR_ROOT="$ZATOR_ROOT" bash -c ". '$TMP/lib.sh'; zapret2_flavor_save fork" \
  && ok "save: fork" || bad "save: fork"
r="$(ZATOR_ROOT="$ZATOR_ROOT" bash -c ". '$TMP/lib.sh'; zapret2_flavor_load")"
[ "$r" = fork ] && ok "load: fork прочитан" || bad "load: fork = $r"
ZATOR_ROOT="$ZATOR_ROOT" bash -c ". '$TMP/lib.sh'; zapret2_flavor_save мусор" \
  && bad "save: мусор принят" || ok "save: мусор отклонён"
echo "мусор" > "$ZATOR_ROOT/extra_strats/cache/zapret2_flavor"
r="$(ZATOR_ROOT="$ZATOR_ROOT" bash -c ". '$TMP/lib.sh'; zapret2_flavor_load")"
[ "$r" = official ] && ok "load: мусор в файле -> official" || bad "load: мусор = $r"
rm -f "$ZATOR_ROOT/extra_strats/cache/zapret2_flavor"

# --- 2. z2r_version_valid ---
vv() { # vv flavor ver want(0/1)
  local got
  got="$(ZATOR_ROOT="$ZATOR_ROOT" FLAVOR="$1" V="$2" bash -c '
    . "'"$TMP"'/lib.sh"
    zapret2_flavor_save "$FLAVOR" >/dev/null 2>&1
    if z2r_version_valid "$V"; then echo 0; else echo 1; fi')"
  [ "$got" = "$3" ] && ok "version_valid $1 '$2' -> $3" \
    || bad "version_valid $1 '$2' -> $got (хотели $3)"
}
vv official 1.0.5.1 0
vv official 1.0.5.1-reasm-fix 1
vv official 1.0.51 0
vv official 100.0 0
vv official abc 1
vv fork     1.0.5.1 0
vv fork     1.0.5.1-reasm-fix 0
vv fork     abc 1
vv fork     1.0.5.1-$(printf 'a%.0s' $(seq 1 45)) 1
rm -f "$ZATOR_ROOT/extra_strats/cache/zapret2_flavor"

# --- 3. z2r_download_zapret2_release ---
cat > "$TMP/fetch_mock.sh" <<'EOF'
z2r_fetch_url_to_file() { echo "$2" >> "$CAPTURE"; return "${FETCH_RC:-0}"; }
z2r_yandex_public_for_release() { echo "YANDEX_CALLED" >> "$CAPTURE"; return 1; }
z2r_download_yandex_public_file() { echo "YAFILE_CALLED" >> "$CAPTURE"; return 1; }
EOF
ZAPRET2_FORK_RELEASE_BASE="https://github.com/example/fork/releases/download"
export ZAPRET2_FORK_RELEASE_BASE
ZAPRET2_RELEASE_BASE="https://github.com/bol-van/zapret2/releases/download"
export ZAPRET2_RELEASE_BASE

CAPTURE="$TMP/cap1"; export CAPTURE

# fork: только primary, без зеркала и яндекса
rm -f "$CAPTURE"
ZATOR_ROOT="$ZATOR_ROOT" bash -c '. "'"$TMP"'/lib.sh"; . "'"$TMP"'/fetch_mock.sh"
  zapret2_flavor_save fork >/dev/null
  z2r_download_zapret2_release /tmp/dst 1.0.5.1-reasm-fix zapret2-v1.0.5.1-reasm-fix.tar.gz' >/dev/null
cap="$(cat "$CAPTURE" 2>/dev/null)"
[ "$cap" = "$ZAPRET2_FORK_RELEASE_BASE/v1.0.5.1-reasm-fix/zapret2-v1.0.5.1-reasm-fix.tar.gz" ] \
  && ok "download fork: URL форка, без зеркал" || bad "download fork: cap='$cap'"

# fork: сбой primary -> сразу отказ, яндекс не дёргается
rm -f "$CAPTURE"; CAPTURE="$TMP/cap2"; export CAPTURE
ZATOR_ROOT="$ZATOR_ROOT" FETCH_RC=1 bash -c '. "'"$TMP"'/lib.sh"; . "'"$TMP"'/fetch_mock.sh"
  zapret2_flavor_save fork >/dev/null
  if z2r_download_zapret2_release /tmp/dst 1.0.5.1-reasm-fix file.tgz; then echo RCOK; else echo RCFAIL; fi' > "$TMP/rc2"
grep -q RCFAIL "$TMP/rc2" && ok "download fork: сбой -> отказ" || bad "download fork: сбой не обработан"
grep -q YANDEX "$TMP/cap2" 2>/dev/null && bad "download fork: яндекс вызван" || ok "download fork: яндекс не вызван"

# official: прежний URL
rm -f "$CAPTURE"; CAPTURE="$TMP/cap3"; export CAPTURE
ZATOR_ROOT="$ZATOR_ROOT" bash -c '. "'"$TMP"'/lib.sh"; . "'"$TMP"'/fetch_mock.sh"
  zapret2_flavor_save official >/dev/null
  z2r_download_zapret2_release /tmp/dst 1.0.5.1 zapret2-v1.0.5.1.tar.gz' >/dev/null
cap="$(cat "$CAPTURE" 2>/dev/null)"
[ "$cap" = "$ZAPRET2_RELEASE_BASE/v1.0.5.1/zapret2-v1.0.5.1.tar.gz" ] \
  && ok "download official: прежний URL" || bad "download official: cap='$cap'"
unset CAPTURE ZAPRET2_FORK_RELEASE_BASE ZAPRET2_RELEASE_BASE

# --- 4. промпт (EOF = дефолт) ---
rm -f "$ZATOR_ROOT/extra_strats/cache/zapret2_flavor"
hardware="keenetic"
ZATOR_ROOT="$ZATOR_ROOT" hardware="$hardware" bash -c '
  . "'"$TMP"'/lib.sh"
  zapret2_flavor_prompt </dev/null >/dev/null 2>&1' \
  && r=ok || r=fail
r="$(ZATOR_ROOT="$ZATOR_ROOT" bash -c '. "'"$TMP"'/lib.sh"; zapret2_flavor_load')"
[ "$r" = fork ] && ok "prompt: Keenetic без выбора -> fork" || bad "prompt: Keenetic -> $r"

rm -f "$ZATOR_ROOT/extra_strats/cache/zapret2_flavor"
hardware=""
ZATOR_ROOT="$ZATOR_ROOT" hardware="$hardware" bash -c '
  . "'"$TMP"'/lib.sh"
  zapret2_flavor_prompt </dev/null >/dev/null 2>&1'
r="$(ZATOR_ROOT="$ZATOR_ROOT" bash -c '. "'"$TMP"'/lib.sh"; zapret2_flavor_load')"
[ "$r" = fork ] && ok "prompt: не-Keenetic без выбора -> fork (глобальный дефолт)" || bad "prompt: не-Keenetic -> $r"

ZATOR_ROOT="$ZATOR_ROOT" bash -c '. "'"$TMP"'/lib.sh"; zapret2_flavor_save official >/dev/null'
ZATOR_ROOT="$ZATOR_ROOT" hardware="" bash -c '
  . "'"$TMP"'/lib.sh"
  zapret2_flavor_prompt </dev/null >/dev/null 2>&1'
r="$(ZATOR_ROOT="$ZATOR_ROOT" bash -c '. "'"$TMP"'/lib.sh"; zapret2_flavor_load')"
[ "$r" = official ] && ok "prompt: сохранённый official держится при EOF" || bad "prompt: official потерян -> $r"

ZATOR_ROOT="$ZATOR_ROOT" bash -c '. "'"$TMP"'/lib.sh"; zapret2_flavor_save fork >/dev/null'
ZATOR_ROOT="$ZATOR_ROOT" hardware="" bash -c '
  . "'"$TMP"'/lib.sh"
  zapret2_flavor_prompt </dev/null >/dev/null 2>&1'
r="$(ZATOR_ROOT="$ZATOR_ROOT" bash -c '. "'"$TMP"'/lib.sh"; zapret2_flavor_load')"
[ "$r" = fork ] && ok "prompt: сохранённый fork держится при EOF" || bad "prompt: fork потерян -> $r"

# выбор цифрой: "1" на пустом префе сохраняет official
rm -f "$ZATOR_ROOT/extra_strats/cache/zapret2_flavor"
ZATOR_ROOT="$ZATOR_ROOT" hardware="" bash -c '
  . "'"$TMP"'/lib.sh"
  printf "1\n" | zapret2_flavor_prompt >/dev/null 2>&1'
r="$(ZATOR_ROOT="$ZATOR_ROOT" bash -c '. "'"$TMP"'/lib.sh"; zapret2_flavor_load')"
[ "$r" = official ] && ok "prompt: явный выбор 1 -> official" || bad "prompt: выбор 1 -> $r"

Z2R_OFFLINE=1 ZATOR_ROOT="$ZATOR_ROOT" bash -c '
  . "'"$TMP"'/lib.sh"
  zapret2_flavor_prompt </dev/null >/dev/null 2>&1'
r="$?"
[ "$r" = 0 ] && ok "prompt: offline пропускает" || bad "prompt: offline rc=$r"

# мёртвое зеркало git.px.rkn.quest не должно возвращаться в код/доки
if grep -rn "git.px.rkn.quest" "$ROOT"/z2r.sh "$ROOT"/lib/*.sh     "$ROOT"/webui-src/src "$ROOT"/tools 2>/dev/null; then
  bad "мёртвое зеркало git.px.rkn.quest снова в коде"
else
  ok "мёртвого зеркала git.px.rkn.quest нет"
fi

echo "==============================="
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ] && echo "flavor smoke ok"
[ "$fail" = 0 ]
