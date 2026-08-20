#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local text="$1"
  local pattern="$2"
  local message="$3"

  grep -Eq -- "$pattern" <<<"$text" || fail "$message"
}

assert_not_contains() {
  local text="$1"
  local pattern="$2"
  local message="$3"

  ! grep -Eq -- "$pattern" <<<"$text" || fail "$message"
}

TMP_DIR="$(mktemp -d /tmp/zator-webui-settings.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

ROOT="$TMP_DIR/zapret2"
CFG="$ROOT/config"
export ORCH_DIR="$ROOT/extra_strats/cache/orchestra"
export ORCH_LOCK_FILE="$ORCH_DIR/locked.tsv"
export PROFILE_STATE_FILE="$TMP_DIR/profile.lock"
export ZAPRET2_INIT="$ROOT/init.d/sysv/zapret2"

mkdir -p "$ORCH_DIR" "$ROOT/init.d/sysv" "$TMP_DIR/backups"
tr -d '\r' < "$REPO_DIR/config.default" > "$CFG"
printf '#!/bin/sh\nexit 0\n' > "$ZAPRET2_INIT"
chmod +x "$ZAPRET2_INIT"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/config.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/orchestra_state.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/actions.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/provider.sh"

PROVIDER_CACHE="$TMP_DIR/provider.txt"
Z2R_BACKUP_DIR="$TMP_DIR/backups"

# == 0. Синтаксис изменённых файлов ==

for file in \
  "$REPO_DIR/lib/actions.sh" \
  "$REPO_DIR/lib/provider.sh" \
  "$REPO_DIR/webui/cgi-bin/_lib.sh" \
  "$REPO_DIR/webui/cgi-bin/settings.cgi" \
  "$REPO_DIR/webui/cgi-bin/backups.cgi"; do
  bash -n "$file"
done
command -v node >/dev/null 2>&1 && node --check "$REPO_DIR/webui/app.js"
command -v python >/dev/null 2>&1 && python -m py_compile "$REPO_DIR/webui/dev/fake_router_server.py"

# == 1. Статические инварианты wiring'а ==

assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" '\$LIB_DIR/actions\.sh' "_lib.sh не подключает lib/actions.sh"
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" '\$LIB_DIR/provider\.sh' "_lib.sh не подключает lib/provider.sh"

for fn in api_auto_mode_get api_hostlist_get api_rst_guard_get api_reasm_get api_quic443_get api_ports_get api_provider_get; do
  assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/settings.cgi")" "$fn" "settings.cgi GET не вызывает $fn"
done
for fn in api_auto_mode_set api_hostlist_set api_rst_guard_set api_reasm_set api_quic443_set api_ports_add api_ports_remove api_provider_set api_provider_redetect; do
  assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/settings.cgi")" "$fn" "settings.cgi POST не вызывает $fn"
done

[ -f "$REPO_DIR/webui/cgi-bin/backups.cgi" ] || fail "backups.cgi отсутствует"
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/backups.cgi")" '405 Method Not Allowed' "backups.cgi не отдаёт 405"

for key in auto_mode rst_guard reasm quic443 provider; do
  assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" "\\\"$key\\\"" "api_status не отдаёт поле $key"
done
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" 'rst-guard\.lua' "rst_guard set без guard на lua-файл"

for id in auto-mode-form hostlist-form rst-guard-form reasm-form quic443-form ports-tcp-form ports-udp-form provider-form backup-create-btn; do
  grep -q "id=\"$id\"" "$REPO_DIR/webui/index.html" || fail "index.html не содержит #$id"
done

app_js="$(cat "$REPO_DIR/webui/app.js")"
for needle in 'auto_mode_state' 'hostlist_state' 'rst_guard_state' 'reasm_state' 'quic443_state' 'ports_add' 'ports_remove' 'provider_set' 'provider_redetect' '/cgi-bin/backups.cgi'; do
  assert_contains "$app_js" "$needle" "app.js не использует $needle"
done
assert_contains "$app_js" 'AUTO_MODE_GATED_PROFILES' "app.js не гейтит профили 1-4 при авторотации"
assert_contains "$app_js" 'inlineCheck.classList.remove' "подсказка гейтинга скрыта классом empty (display:none)"
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" 'управляется авторотацией' "_lib.sh: set-lock/clear-lock без guard'а авторотации"

assert_contains "$(cat "$REPO_DIR/lib/actions.sh")" 'ports_apply_add "\$proto" "\$input"' "CLI ports_add не использует ядро ports_apply_add"
assert_contains "$(cat "$REPO_DIR/lib/actions.sh")" 'ports_apply_remove "\$proto" "\$target"' "CLI ports_manage не использует ядро ports_apply_remove"
assert_contains "$(cat "$REPO_DIR/lib/actions.sh")" 'backup_create_core 2>/dev/null' "CLI menu_action_backup_create не использует ядро backup_create_core"

fake_py="$(cat "$REPO_DIR/webui/dev/fake_router_server.py")"
for needle in 'auto_mode_state' 'hostlist_state' 'rst_guard_state' 'reasm_state' 'quic443_state' 'ports_add' 'provider_set' 'provider_redetect' 'apply_backup_create' 'ConflictError'; do
  assert_contains "$fake_py" "$needle" "fake_router_server.py не реализует $needle"
done
assert_contains "$fake_py" 'netrogat_substring' "fake_router_server.py не поддерживает список netrogat_substring"
assert_contains "$fake_py" 'AUTO_MODE_GATED_PROFILES' "fake_router_server.py не гейтит профили 1-4 при авторотации"

html="$(cat "$REPO_DIR/webui/index.html")"
auto_line="$(printf '%s\n' "$html" | grep -n 'id="auto-mode-form"' | cut -d: -f1)"
settings_line="$(printf '%s\n' "$html" | grep -n 'id="view-settings"' | cut -d: -f1)"
[ -n "$auto_line" ] && [ -n "$settings_line" ] && [ "$auto_line" -gt "$settings_line" ] \
  || fail "панель авторотации должна быть во вкладке Настройки (внутри view-settings)"

# == 2. Hostlist: autohostlist и плейсхолдер <HOSTLIST> ==

[ "$(config_mode_text hostlist "$CFG")" != "неизвестно" ] || fail "config.default: hostlist режим не определён"
backup_smart_set_hostlist "$CFG" 1
grep -q '^MODE_FILTER=autohostlist' "$CFG" || fail "hostlist set 1 не переключил MODE_FILTER"
grep -q 'TCP_RKN_list\.txt <HOSTLIST>' "$CFG" || fail "hostlist set 1 не добавил плейсхолдер <HOSTLIST>"
[ "$(config_mode_text hostlist "$CFG")" = "авто" ] || fail "config_mode_text hostlist не видит авто"
backup_smart_set_hostlist "$CFG" 0
grep -q '^MODE_FILTER=hostlist' "$CFG" || fail "hostlist set 0 не вернул MODE_FILTER"
grep -q 'TCP_RKN_list\.txt <HOSTLIST>' "$CFG" && fail "hostlist set 0 не убрал плейсхолдер <HOSTLIST>"

# == 3. reasm-disable ==

backup_smart_set_reasm "$CFG" 1
[ "$(config_mode_text reasm_disable "$CFG")" = "включено" ] || fail "reasm set 1 не виден в config_mode_text"
awk '/^NFQWS2_OPT="/ {found=1; next} found && /^--reasm-disable$/ {ok=1} found && /^"$/ {exit} END {exit !ok}' "$CFG" \
  || fail "--reasm-disable не внутри блока NFQWS2_OPT"
backup_smart_set_reasm "$CFG" 1
[ "$(grep -c '^--reasm-disable$' "$CFG")" -eq 1 ] || fail "reasm set 1 не идемпотентен"
backup_smart_set_reasm "$CFG" 0
[ "$(config_mode_text reasm_disable "$CFG")" = "выключено" ] || fail "reasm set 0 не удалил параметр"

# == 4. QUIC443 ==

backup_smart_set_quic443 "$CFG" 0
[ "$(backup_smart_quic443_state "$CFG")" = "0" ] || fail "quic443 set 0 не определился"
backup_smart_set_quic443 "$CFG" 1
[ "$(backup_smart_quic443_state "$CFG")" = "1" ] || fail "quic443 set 1 не определился"
sed -n '/#Z2R_QUIC443_BEGIN/,/#Z2R_QUIC443_END/p' "$CFG" | grep -Eq '^[[:space:]]*--skip[[:space:]]+--filter-udp=443' \
  && fail "quic443 включен, но --skip остался"

# == 5. RST guard ==

backup_smart_set_rst_guard "$CFG" 1
[ "$(config_mode_text rst_guard "$CFG")" = "включен" ] || fail "rst_guard set 1 не виден"
grep -q -- '--lua-desync=rst_guard_locked:key=1' "$CFG" || fail "rst_guard set 1 не заменил circular_locked:key=1"
sed -n '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/p' "$CFG" | grep -q '^--skip --filter-tcp=443 --filter-l7=tls$' \
  && fail "rst_guard set 1 не упростил filter-tcp в fallback-блоке"
backup_smart_set_rst_guard "$CFG" 0
[ "$(config_mode_text rst_guard "$CFG")" = "выключен" ] || fail "rst_guard set 0 не вернул circular_locked"
sed -n '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/p' "$CFG" | grep -q '^--skip --filter-tcp=443 --filter-l7=tls$' \
  || fail "rst_guard set 0 не вернул filter-l7=tls в fallback-блоке"

# == 6. Fallback: guard авторотации и восстановление состояния ==

backup_smart_set_fallback "$CFG" 1
[ "$(config_mode_text fallback "$CFG")" = "включен" ] || fail "fallback set 1 не включился"
backup_smart_set_fallback "$CFG" 0
[ "$(config_mode_text fallback "$CFG")" = "выключен" ] || fail "fallback set 0 не выключился"
backup_smart_set_fallback "$CFG" 1
[ "$(config_mode_text fallback "$CFG")" = "включен" ] || fail "подготовка fallback к тесту авторотации не удалась"

config_auto_layout_valid "$CFG" || fail "config.default не проходит config_auto_layout_valid"
config_set_auto_mode "$CFG" 1
[ "$(config_mode_text auto_mode "$CFG")" = "включен" ] || fail "config_set_auto_mode 1 не сработал"
[ "$(config_mode_text fallback "$CFG")" = "недоступен" ] || fail "fallback не 'недоступен' при авторотации"
backup_smart_set_fallback "$CFG" 0
[ "$(config_mode_text fallback "$CFG")" = "недоступен" ] || fail "fallback сеттер не no-op при авторотации"
config_set_auto_mode "$CFG" 0
[ "$(config_mode_text auto_mode "$CFG")" = "выключен" ] || fail "config_set_auto_mode 0 не сработал"
[ "$(config_mode_text fallback "$CFG")" = "включен" ] || fail "после выключения авторотации fallback не восстановлен (AUTO_FALLBACK_WAS)"

# == 7. Порты NFQWS2: add/remove + синхронизация RKN --filter-tcp ==

ports_apply_add tcp "8080,9000-9100,abc,8080" "$CFG" \
  || fail "ports_apply_add отклонил валидные порты"
[ "$PORTS_APPLY_ADDED" = "8080,9000-9100" ] || fail "PORTS_APPLY_ADDED неверен: $PORTS_APPLY_ADDED"
[ "$PORTS_APPLY_SKIPPED" = "abc,8080" ] || fail "PORTS_APPLY_SKIPPED неверен: $PORTS_APPLY_SKIPPED"
tcp_line="$(config_get_var "$CFG" NFQWS2_PORTS_TCP)"
printf '%s\n' "$tcp_line" | grep -q '^8080,9000-9100,' || fail "порты не встали в начало NFQWS2_PORTS_TCP: $tcp_line"
sed -n '/#Z2R_AUTO_STANDARD_3_BEGIN/,/#Z2R_AUTO_STANDARD_3_END/p' "$CFG" | grep -q -- '--filter-tcp=8080,9000-9100,' \
  || fail "RKN --filter-tcp не синхронизировался с пользовательскими TCP-портами"

if ports_apply_add tcp "8080" "$CFG"; then
  fail "ports_apply_add должен отклонять дубликат"
fi

ports_apply_remove tcp "8080" "$CFG" || fail "ports_apply_remove не удалил порт"
tcp_line="$(config_get_var "$CFG" NFQWS2_PORTS_TCP)"
case ",$tcp_line," in
  *",8080,"*) fail "порт 8080 не удалён из NFQWS2_PORTS_TCP: $tcp_line" ;;
esac
sed -n '/#Z2R_AUTO_STANDARD_3_BEGIN/,/#Z2R_AUTO_STANDARD_3_END/p' "$CFG" | grep -q -- '--filter-tcp=8080' \
  && fail "порт 8080 не убран из RKN --filter-tcp"
if ports_apply_remove tcp "8080" "$CFG"; then
  fail "ports_apply_remove должен отклонять отсутствующий порт"
fi

ports_apply_add udp "12345" "$CFG" || fail "ports_apply_add udp не работает"
udp_line="$(config_get_var "$CFG" NFQWS2_PORTS_UDP)"
printf '%s\n' "$udp_line" | grep -q '^12345,' || fail "UDP-порт не в начале NFQWS2_PORTS_UDP: $udp_line"
ports_apply_remove udp "12345" "$CFG" || fail "ports_apply_remove udp не работает"

# == 8. Бэкапы: ядро создания ==

backup_out="$TMP_DIR/backup_out"
if ! backup_create_core >"$backup_out" 2>/dev/null; then
  fail "backup_create_core упал"
fi
backup_tar="$(cat "$backup_out")"
[ -f "$backup_tar" ] || fail "архив бэкапа не создан: $backup_tar"
[ "$backup_tar" = "$BACKUP_LAST_ARCHIVE" ] || fail "BACKUP_LAST_ARCHIVE не совпадает с путём архива"
basename "$backup_tar" | grep -Eq '^z2r_backup_[0-9]{8}_[0-9]{6}\.tar$' || fail "имя архива не по шаблону: $backup_tar"
[ -s "$backup_tar" ] || fail "архив бэкапа пуст"

# == 9. Провайдер ==

provider_asn_lookup 47119
[ "$PROVIDER_BRAND" = "Ufanet" ] || fail "ASN 47119 должен давать бренд Ufanet, получен: $PROVIDER_BRAND"
provider_asn_lookup 20485
[ "$PROVIDER_BRAND" = "Rostelecom" ] || fail "ASN 20485 должен давать бренд Rostelecom"
[ "$(provider_brand_aliases Rostelecom | tr '\n' ',')" = "TTK," ] || fail "алиасы Rostelecom должны быть TTK"
provider_asn_lookup 8369
[ "$PROVIDER_BRAND" = "Dom.ru" ] || fail "ASN 8369 должен давать бренд Dom.ru"
[ "$(provider_brand_aliases 'Dom.ru' | tr '\n' ',')" = "ER-Telecom," ] || fail "алиасы Dom.ru должны быть ER-Telecom"
if provider_asn_lookup 99999; then
  fail "неизвестный ASN должен возвращать 1"
fi

[ "$(_provider_json_num '{"connection":{"asn":47119,"org":"JSC Ufanet"}}' asn)" = "47119" ] \
  || fail "_provider_json_num не извлекает asn"
[ "$(_provider_json_str '{"as":"AS47119 JSC Ufanet","isp":"JSC Ufanet"}' isp)" = "JSC Ufanet" ] \
  || fail "_provider_json_str не извлекает isp"
[ "$(_provider_json_str '{"as":"AS47119 JSC Ufanet"}' as)" = "AS47119 JSC Ufanet" ] \
  || fail "_provider_json_str не извлекает as"

provider_sh="$(cat "$REPO_DIR/lib/provider.sh")"
who_line="$(printf '%s\n' "$provider_sh" | grep -n 'curl.*ipwho\.is' | head -1 | cut -d: -f1)"
info_line="$(printf '%s\n' "$provider_sh" | grep -n 'curl.*ipinfo\.io' | head -1 | cut -d: -f1)"
apiline="$(printf '%s\n' "$provider_sh" | grep -n 'curl.*ip-api\.com' | head -1 | cut -d: -f1)"
[ -n "$who_line" ] && [ -n "$info_line" ] && [ -n "$apiline" ] && [ "$who_line" -lt "$info_line" ] && [ "$info_line" -lt "$apiline" ] \
  || fail "каскад детекта должен быть ipwho.is -> ipinfo.io -> ip-api.com"
grep -q 'tr -cd' "$REPO_DIR/lib/provider.sh" && fail "provider.sh не должен калечить строки через tr -cd"
grep -q 'provider_brand_aliases' "$REPO_DIR/lib/recommendations.sh" || fail "show_hint не использует алиасы ASN-таблицы"
grep -q '_detect_api_simple' "$REPO_DIR/lib/telemetry.sh" || fail "фоллбек телеметрии не использует общий детектор"

provider_set_manual "MTS" "Moscow" || fail "provider_set_manual упал"
[ "$(cat "$PROVIDER_CACHE")" = "MTS - Moscow" ] || fail "provider_set_manual не записал кэш"
provider_set_manual "Beeline" "" || fail "provider_set_manual без города упал"
[ "$(cat "$PROVIDER_CACHE")" = "Beeline" ] || fail "provider_set_manual без города записал лишнее"
if provider_set_manual "" "City"; then
  fail "provider_set_manual должен отклонять пустое имя"
fi

echo "webui settings smoke ok"
