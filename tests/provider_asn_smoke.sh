#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

TMP_DIR="$(mktemp -d /tmp/zator-provider-asn.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/cache"
COUNTER="$TMP_DIR/curl_calls"
: > "$COUNTER"

cat > "$TMP_DIR/bin/curl" <<'MOCK'
#!/bin/sh
echo 1 >> "$CURL_COUNTER"
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; fi
  prev="$arg"
done
case "${CURL_MODE:-ok}" in
  fail) exit 22 ;;
  http404) exit 22 ;;
  garbage) printf 'total junk\n' > "$out"; exit 0 ;;
  empty) : > "$out"; exit 0 ;;
  *)
    if [ -n "$out" ]; then cp "$CURL_FILE" "$out"; else cat "$CURL_FILE"; fi
    ;;
esac
MOCK
chmod +x "$TMP_DIR/bin/curl"
export CURL_COUNTER="$COUNTER"
export PATH="$TMP_DIR/bin:$PATH"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/provider.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/recommendations.sh"
RECS_FILE="$REPO_DIR/recommendations.txt"
cyan="" green="" yellow="" plain="" red=""

PROVIDER_CACHE="$TMP_DIR/provider.txt"
PROVIDER_ASN_DB_FILE="$TMP_DIR/absent/asn.txt"
PROVIDER_ASN_CACHE="$TMP_DIR/cache/provider_asn.txt"
PROVIDER_ASN_REMOTE="https://example.invalid/asn.txt"

curl_calls() {
  wc -l < "$COUNTER" | tr -d '[:space:]'
}

stale_touch() {
  touch -d '30 days ago' "$1" 2>/dev/null || touch -t 202001010000 "$1"
}

cat > "$TMP_DIR/remote_ok.txt" <<'EOF'
# ZATOR_PROVIDER_DB_VERSION=2099-01-01
# FORMAT=ASN:BRAND:ALIASES
99999:TestNet:
88888:TestProvider:Ufanet
60000:BrandX:AliasX
60001:BrandY:
60002:BrandZ:
47119:Ufanet2:
EOF

cat > "$TMP_DIR/remote_min.txt" <<'EOF'
70000:OldBase:
70001:OldTwo:
70002:OldThree:
70003:OldFour:
70004:OldFive:
EOF

bash -n "$REPO_DIR/lib/provider.sh"

# == 1. remote доступен -> cache обновился ==

export CURL_MODE=ok CURL_FILE="$TMP_DIR/remote_ok.txt"
rm -f "$PROVIDER_ASN_CACHE"
provider_update_database || fail "сценарий 1: update при живом remote должен пройти"
[ -f "$PROVIDER_ASN_CACHE" ] || fail "сценарий 1: cache не создан"
grep -q '^99999:TestNet:' "$PROVIDER_ASN_CACHE" || fail "сценарий 1: в cache нет строк remote-файла"
[ "$(curl_calls)" -ge 1 ] || fail "сценарий 1: curl не вызывался"

# == 2. remote недоступен -> старый cache цел ==

cp "$TMP_DIR/remote_min.txt" "$PROVIDER_ASN_CACHE"
stale_touch "$PROVIDER_ASN_CACHE"
export CURL_MODE=fail
if provider_update_database; then
  fail "сценарий 2: update при мёртвом remote должен вернуть 1"
fi
grep -q '^70000:OldBase:' "$PROVIDER_ASN_CACHE" || fail "сценарий 2: старый cache затёрт"

# == 3. cache нет -> builtin ==

rm -f "$PROVIDER_ASN_CACHE"
provider_load_database
[ "$PROVIDER_ASN_TABLE_SRC" = "builtin" ] || fail "сценарий 3: источник должен быть builtin"
provider_asn_lookup 47119
[ "$PROVIDER_BRAND" = "Ufanet" ] || fail "сценарий 3: builtin не знает 47119"

# == 4. remote битый -> рабочий cache не затирается ==

cp "$TMP_DIR/remote_min.txt" "$PROVIDER_ASN_CACHE"
stale_touch "$PROVIDER_ASN_CACHE"
export CURL_MODE=garbage
if provider_update_database; then
  fail "сценарий 4: битый remote должен давать 1"
fi
grep -q '^70000:OldBase:' "$PROVIDER_ASN_CACHE" || fail "сценарий 4: cache затёрт битым ответом"

# == 5. TTL не истёк -> curl не вызывается ==

cp "$TMP_DIR/remote_min.txt" "$PROVIDER_ASN_CACHE"
: > "$COUNTER"
provider_update_database || fail "сценарий 5: свежий cache — update должен вернуть 0"
[ "$(curl_calls)" -eq 0 ] || fail "сценарий 5: при живом TTL был сетевой запрос"

# == 6. merge: remote приоритет, builtin не теряется ==

cp "$TMP_DIR/remote_ok.txt" "$PROVIDER_ASN_CACHE"
provider_load_database
[ "$PROVIDER_ASN_TABLE_SRC" = "cache" ] || fail "сценарий 6: источник должен быть cache"
provider_asn_lookup 99999
[ "$PROVIDER_BRAND" = "TestNet" ] || fail "сценарий 6: ASN из remote не найден"
provider_asn_lookup 47119
[ "$PROVIDER_BRAND" = "Ufanet2" ] || fail "сценарий 6: remote не переопределил builtin ASN"
provider_asn_lookup 8359
[ "$PROVIDER_BRAND" = "MTS" ] || fail "сценарий 6: builtin-ASN потерян при merge"

# == 7. remote-ASN + alias -> рекомендация находится ==

provider_asn_lookup 88888
[ "$PROVIDER_BRAND" = "TestProvider" ] || fail "сценарий 7: бренд TestProvider не найден"
[ "$(provider_brand_aliases TestProvider | tr '\n' ',')" = "Ufanet," ] || fail "сценарий 7: алиас Ufanet не получен"
rec="$(awk -F'|' -v b="Ufanet" 'index(tolower($1), tolower(b)) {print; exit}' "$RECS_FILE")"
[ -n "$rec" ] || fail "сценарий 7: рекомендация по алиасу не найдена"

# == 8. неизвестный ASN -> текущий fallback ==

if provider_asn_lookup 77777; then
  fail "сценарий 8: неизвестный ASN должен возвращать 1"
fi
[ -z "$PROVIDER_BRAND" ] || fail "сценарий 8: PROVIDER_BRAND должен быть пуст"

# == 9. manual provider не перезаписывается ==

provider_set_manual "MyISP - Town" || fail "сценарий 9: provider_set_manual упал"
export CURL_MODE=ok CURL_FILE="$TMP_DIR/remote_ok.txt"
rm -f "$PROVIDER_ASN_CACHE"
provider_update_database || fail "сценарий 9: update упал"
[ "$(head -n1 "$PROVIDER_CACHE")" = "MyISP - Town" ] || fail "сценарий 9: provider.txt перезаписан"

# == 10. fake-router и новый слой: статические инварианты ==

grep -q 'Ufanet - Podolsk' "$REPO_DIR/webui/dev/fake_router_server.py" \
  || fail "сценарий 10: fake-router redetect сменил формат"
grep -q 'provider_load_database' "$REPO_DIR/lib/provider.sh" || fail "сценарий 10: нет provider_load_database"
grep -q 'provider_update_database' "$REPO_DIR/lib/provider.sh" || fail "сценарий 10: нет provider_update_database"
grep -q '^25159:MegaFon:' "$REPO_DIR/lib/provider.sh" || fail "сценарий 10: builtin без подтверждённого MegaFon AS25159"
grep -q '^12958:T2:' "$REPO_DIR/lib/provider.sh" || fail "сценарий 10: builtin без подтверждённого T2 AS12958"

# == доп: data/providers/asn.txt валиден и парсится конвейером ==

[ -f "$REPO_DIR/data/providers/asn.txt" ] || fail "data/providers/asn.txt отсутствует"
_provider_asn_file_valid "$REPO_DIR/data/providers/asn.txt" \
  || fail "data/providers/asn.txt не проходит валидатор (формат/минимум 5 строк)"
grep -q '^# ZATOR_PROVIDER_DB_VERSION=' "$REPO_DIR/data/providers/asn.txt" \
  || fail "data/providers/asn.txt без строки версии"
grep -q 'Определено:' "$REPO_DIR/lib/provider.sh" \
  || fail "provider_force_redetect не сообщает результат детекта"
grep -q 'document.activeElement' "$REPO_DIR/webui/app.js" \
  || fail "renderProvider не обновляет подставленные значения после редетекта"

# == 11. Успешное обновление recommendations заменяет базу ==

cat > "$TMP_DIR/recs_new.txt" <<'EOF'
NewBase|UDP:1|TCP:2|GV:3|RKN:4
OldKey|UDP:0|TCP:0|GV:0|RKN:0
EOF
RECS_FILE="$TMP_DIR/recs_work.txt"
printf 'OldBase|UDP:9|TCP:9|GV:9|RKN:9\n' > "$RECS_FILE"
stale_touch "$RECS_FILE"
export CURL_MODE=ok CURL_FILE="$TMP_DIR/recs_new.txt"
update_recommendations
grep -q '^NewBase|' "$RECS_FILE" || fail "сценарий 11: успешное обновление не заменило базу"

# == 12. Ошибка curl сохраняет старую базу ==

printf 'OldBase|UDP:9|TCP:9|GV:9|RKN:9\n' > "$RECS_FILE"
stale_touch "$RECS_FILE"
export CURL_MODE=fail
update_recommendations
grep -q '^OldBase|' "$RECS_FILE" || fail "сценарий 12: ошибка curl затёрла рабочую базу"

# == 13. HTTP 404/500 сохраняет старую базу ==

printf 'OldBase|UDP:9|TCP:9|GV:9|RKN:9\n' > "$RECS_FILE"
stale_touch "$RECS_FILE"
export CURL_MODE=http404
update_recommendations
grep -q '^OldBase|' "$RECS_FILE" || fail "сценарий 13: HTTP-ошибка затёрла рабочую базу"

# == 14. Пустой файл не заменяет рабочую базу ==

printf 'OldBase|UDP:9|TCP:9|GV:9|RKN:9\n' > "$RECS_FILE"
stale_touch "$RECS_FILE"
export CURL_MODE=empty
update_recommendations
grep -q '^OldBase|' "$RECS_FILE" || fail "сценарий 14: пустая загрузка затёрла рабочую базу"
ls "$TMP_DIR"/recs_work.tmp.* >/dev/null 2>&1 && fail "сценарий 14: остался мусорный .tmp"

RECS_FILE="$REPO_DIR/recommendations.txt"

# == 15. Exact match не ловит частичное совпадение ==

hint_out() {
  printf '%s' "$1" > "$PROVIDER_CACHE"
  show_hint "$2" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}
[ -z "$(hint_out "UDP:0" RKN)" ] || fail "сценарий 15: ключ 'UDP:0' ложно сматчился (частичное совпадение)"
[ -n "$(hint_out "JSC Ufanet" RKN)" ] || fail "сценарий 15: точный ключ 'JSC Ufanet' не сматчился"

# == 16. Alias с пробелом не разбивается на слова ==

PROVIDER_ASN_TABLE="$PROVIDER_ASN_TABLE
55555:SpaceBrand:JSC Ufanet"
out16="$(hint_out "SpaceBrand - Nowhere" RKN)"
case "$out16" in
  *выбирают:*5*) ;;
  *) fail "сценарий 16: alias 'JSC Ufanet' с пробелом не сработал целиком: $out16" ;;
esac
case "$out16" in
  *выбирают:*2*) fail "сценарий 16: сработал split-фрагмент 'JSC' (чужая строка ER-Telecom)" ;;
esac

# == доп: классические связки продолжают работать ==

out_u="$(hint_out "Ufanet - Odintsovo" RKN)"
case "$out_u" in *выбирают:*5*) ;; *) fail "Ufanet - Odintsovo: подсказка не найдена";; esac
out_m="$(hint_out "MTS - Kazan" RKN)"
case "$out_m" in *выбирают:*5*) ;; *) fail "MTS - Kazan: подсказка не найдена (ожидалась строка Kazan - MTS PJSC, RKN:5)";; esac

# == доп: обычный init не делает сетевых запросов ==

echo "Init - No Net" > "$PROVIDER_CACHE"
: > "$COUNTER"
PROVIDER_INIT_DONE=0
provider_init_once
[ "$(curl_calls)" -eq 0 ] || fail "init при готовом provider.txt дёргает сеть"

echo "provider asn smoke ok"
