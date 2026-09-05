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
# shellcheck source=/dev/null
source "$REPO_DIR/lib/ui.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/strategies.sh"

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
command -v python >/dev/null 2>&1 && python -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$REPO_DIR/webui/dev/fake_router_server.py"

# == 1. Статические инварианты wiring'а ==

assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" '\$LIB_DIR/actions\.sh' "_lib.sh не подключает lib/actions.sh"
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" '\$LIB_DIR/provider\.sh' "_lib.sh не подключает lib/provider.sh"

for fn in api_auto_mode_get api_hostlist_get api_rst_guard_get api_reasm_get api_quic443_get api_dns_desync_get api_ports_get api_provider_get; do
  assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/settings.cgi")" "$fn" "settings.cgi GET не вызывает $fn"
done
for fn in api_auto_mode_set api_hostlist_set api_rst_guard_set api_reasm_set api_quic443_set api_dns_desync_set api_ports_add api_ports_remove api_provider_set api_provider_redetect; do
  assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/settings.cgi")" "$fn" "settings.cgi POST не вызывает $fn"
done

[ -f "$REPO_DIR/webui/cgi-bin/backups.cgi" ] || fail "backups.cgi отсутствует"
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/backups.cgi")" '405 Method Not Allowed' "backups.cgi не отдаёт 405"
for fn in api_backups_list api_backups_create api_backups_delete api_backups_download api_backups_upload; do
  assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/backups.cgi")" "$fn" "backups.cgi не вызывает $fn"
done
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" 'send_tar_file' "_lib.sh не отдаёт tar-файлы"

# Агрегирующий state.cgi: одна загрузка вместо ~15 CGI при старте webui
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" 'api_state\(\)' "_lib.sh: нет агрегирующего api_state"
[ -f "$REPO_DIR/webui/cgi-bin/state.cgi" ] || fail "state.cgi отсутствует"
grep -q 'api_state' "$REPO_DIR/webui/cgi-bin/state.cgi" || fail "state.cgi не вызывает api_state"
grep -q 'cgi-bin/state.cgi' "$REPO_DIR/z2r.sh" || fail "z2r.sh не устанавливает state.cgi"
grep -rq 'state\.cgi' "$REPO_DIR/webui-src/src" || fail "webui-src не использует state.cgi"
grep -q '"state"' "$REPO_DIR/webui/dev/fake_router_server.py" || fail "fake_router_server.py без эндпоинта state"
grep -q 'state\.cgi' "$REPO_DIR/webui/dev/API_CONTRACT.md" || fail "API_CONTRACT.md без state.cgi"

for key in auto_mode rst_guard reasm quic443 provider; do
  assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" "\\\"$key\\\"" "api_status не отдаёт поле $key"
done
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" 'rst-guard\.lua' "rst_guard set без guard на lua-файл"

for id in auto-mode-form hostlist-form rst-guard-form reasm-form quic443-form dns-desync-form ports-tcp-form ports-udp-form provider-form backup-create-btn backup-import-btn backup-import-file; do
  grep -rq "$id" "$REPO_DIR/webui-src/src" || fail "webui-src не содержит #$id"
done

app_js="$(find "$REPO_DIR/webui-src/src" -type f \( -name '*.vue' -o -name '*.ts' \) -exec cat {} +)"
for needle in 'auto_mode_state' 'hostlist_state' 'rst_guard_state' 'reasm_state' 'quic443_state' 'dns_desync_state' 'ports_add' 'ports_remove' 'provider_set' 'provider_redetect' '/cgi-bin/backups.cgi' "action: 'create'" "action: 'delete'" 'action=download' 'action=upload' 'download-btn' 'backups-toggle' 'confirmDialog'; do
  assert_contains "$app_js" "$needle" "webui-src не использует $needle"
done
assert_contains "$app_js" 'AUTO_MODE_GATED_PROFILES' "webui-src не гейтит профили 1-4 при авторотации"
assert_contains "$app_js" 'fallback-hint' "webui-src без подсказки гейтинга профиля"
assert_contains "$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")" 'управляется авторотацией' "_lib.sh: set-lock/clear-lock без guard'а авторотации"

# Автоперезапуск после изменения настройки: общий хелпер в CGI, тосты в JS,
# симуляция в fake-сервере; ручных «Перезапустите zapret2» больше нет.
_lib_sh="$(cat "$REPO_DIR/webui/cgi-bin/_lib.sh")"
assert_contains "$_lib_sh" '_service_apply_restart\(\)' "_lib.sh: нет общего хелпера автоперезапуска"
assert_not_contains "$_lib_sh" 'reboot_required' "_lib.sh: остался старый флаг reboot_required"
assert_contains "$app_js" 'announceRestart' "webui-src: нет тоста о перезапуске"
assert_contains "$app_js" 'restartSuffix' "webui-src: нет суффикса про перезапуск"
assert_not_contains "$app_js" 'Перезапустите zapret2' "webui-src: остался ручной призыв перезапустить"
assert_contains "$(cat "$REPO_DIR/webui/dev/fake_router_server.py")" '_apply_restart' "fake_router_server.py: нет симуляции автоперезапуска"

assert_contains "$(cat "$REPO_DIR/lib/actions.sh")" 'ports_apply_add "\$proto" "\$input"' "CLI ports_add не использует ядро ports_apply_add"
assert_contains "$(cat "$REPO_DIR/lib/actions.sh")" 'ports_apply_remove "\$proto" "\$target"' "CLI ports_manage не использует ядро ports_apply_remove"
assert_contains "$(cat "$REPO_DIR/lib/actions.sh")" 'backup_create_core 2>/dev/null' "CLI menu_action_backup_create не использует ядро backup_create_core"

fake_py="$(cat "$REPO_DIR/webui/dev/fake_router_server.py")"
for needle in 'auto_mode_state' 'hostlist_state' 'rst_guard_state' 'reasm_state' 'quic443_state' 'dns_desync_state' 'ports_add' 'provider_set' 'provider_redetect' 'apply_backup_create' 'apply_backup_delete' 'apply_backup_import' 'ConflictError'; do
  assert_contains "$fake_py" "$needle" "fake_router_server.py не реализует $needle"
done
assert_contains "$fake_py" 'netrogat_substring' "fake_router_server.py не поддерживает список netrogat_substring"
assert_contains "$fake_py" 'AUTO_MODE_GATED_PROFILES' "fake_router_server.py не гейтит профили 1-4 при авторотации"

# Панель авторотации обязана жить в реестре панелей настроек (роут /settings/auto-mode)
grep -q "'auto-mode'" "$REPO_DIR/webui-src/src/components/settings/panels.ts" \
  || fail "панель авторотации отсутствует в реестре настроек"

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

# == 4a. Антиспуф DNS (профиль 10): ядро тумблера WebUI/CLI ==
# Дефолт апстрима: блок активен (без --skip) И порт 53 в NFQWS2_PORTS_UDP —
# config_mode_text dns_desync = Включен. Тумблер меняет блок + порт.

[ "$(config_mode_text dns_desync "$CFG")" = "Включен" ] \
  || fail "свежий config.default: антиспуф DNS должен быть Включен (блок + порт 53)"
sed -n '/#Z2R_DNS_BEGIN/,/#Z2R_DNS_END/p' "$CFG" | grep -q '^--filter-udp=53$' \
  || fail "блок #Z2R_DNS_* должен быть активен по умолчанию (без --skip)"
assert_contains "$(config_get_var "$CFG" NFQWS2_PORTS_UDP)" '(^|,)53(,|$)' \
  "порт 53 должен быть в NFQWS2_PORTS_UDP по умолчанию"

# повторное включение не дублирует порт
backup_smart_set_dns_desync "$CFG" 1
config_profile_dns_ports_apply "$CFG" 1
assert_not_contains "$(config_get_var "$CFG" NFQWS2_PORTS_UDP)" '(^|,)53,53(,|$)' "dns_desync set 1 задублировал порт 53"

backup_smart_set_dns_desync "$CFG" 0
config_profile_dns_ports_apply "$CFG" 0
[ "$(config_mode_text dns_desync "$CFG")" = "Выключен" ] || fail "dns_desync set 0 не выключился"
assert_not_contains "$(config_get_var "$CFG" NFQWS2_PORTS_UDP)" '(^|,)53(,|$)' "dns_desync set 0 не убрал порт 53"
sed -n '/#Z2R_DNS_BEGIN/,/#Z2R_DNS_END/p' "$CFG" | grep -q '^--skip --filter-udp=53$' \
  || fail "dns_desync set 0 не вернул --skip в блок #Z2R_DNS_*"
# возврат в дефолтное состояние (блок активен, порт на месте)
backup_smart_set_dns_desync "$CFG" 1
config_profile_dns_ports_apply "$CFG" 1
[ "$(config_mode_text dns_desync "$CFG")" = "Включен" ] || fail "dns_desync set 1 не включился обратно"

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

# == 8a. Бэкапы: ядра resolve/delete/import ==

backup_name="$(basename "$backup_tar")"
resolved="$(backup_resolve_archive "$backup_name")" || fail "backup_resolve_archive не нашёл свежий архив"
[ "$resolved" = "$backup_tar" ] || fail "backup_resolve_archive вернул не тот путь: $resolved"
if backup_resolve_archive "../$backup_name" >/dev/null 2>&1; then
  fail "backup_resolve_archive должен отклонять path traversal"
fi
if backup_resolve_archive "z2r_backup_20990101_000000.tar" >/dev/null 2>&1; then
  fail "backup_resolve_archive должен отклонять отсутствующий архив"
fi
if backup_resolve_archive "evil.tar" >/dev/null 2>&1; then
  fail "backup_resolve_archive должен отклонять имя мимо шаблона"
fi

deleted="$(backup_delete_core "$backup_name")" || fail "backup_delete_core упал"
[ ! -f "$deleted" ] || fail "backup_delete_core не удалил архив"
if backup_delete_core "$backup_name" >/dev/null 2>&1; then
  fail "backup_delete_core должен отклонять отсутствующий архив"
fi

import_stage="$TMP_DIR/import_stage"
mkdir -p "$import_stage"
printf 'MODE_FILTER=hostlist\n' > "$import_stage/config"
import_src="$TMP_DIR/upload.tar"
tar -cf "$import_src" -C "$import_stage" .
imported="$(backup_import_core "$import_src" "z2r_backup_20990101_000000.tar")" \
  || fail "backup_import_core упал на валидном tar"
[ "$imported" = "z2r_backup_20990101_000000.tar" ] || fail "backup_import_core не сохранил оригинальное имя: $imported"
[ -f "$Z2R_BACKUP_DIR/$imported" ] || fail "импортированный архив не в каталоге бэкапов"
[ ! -f "$import_src" ] || fail "backup_import_core не перенёс файл"

tar -cf "$import_src" -C "$import_stage" .
imported2="$(backup_import_core "$import_src" "my_router.tar")" \
  || fail "backup_import_core упал на валидном tar без шаблонного имени"
printf '%s\n' "$imported2" | grep -Eq '^z2r_backup_[0-9]{8}_[0-9]{6}(_[0-9]+)?\.tar$' \
  || fail "сгенерированное имя не по шаблону: $imported2"

bad_stage="$TMP_DIR/bad_stage"
mkdir -p "$bad_stage"
printf 'junk\n' > "$bad_stage/readme.txt"
bad_src="$TMP_DIR/bad.tar"
tar -cf "$bad_src" -C "$bad_stage" .
if backup_import_core "$bad_src" >/dev/null 2>&1; then
  fail "backup_import_core должен отклонять tar без config/lists/extra_strats"
fi
[ -f "$bad_src" ] || fail "при отказе backup_import_core не должен удалять исходный файл"

garbage="$TMP_DIR/garbage.bin"
printf 'not a tar\n' > "$garbage"
if backup_import_core "$garbage" >/dev/null 2>&1; then
  fail "backup_import_core должен отклонять не-tar файл"
fi

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

# == 10. Кастомные домены: самолечение из locked.tsv и переименование ==
# Старые обновления затирали TCP_Custom.txt пустым Custom.txt из репозитория,
# при этом локи доменов в locked.tsv переживали: список пуст, локи живы.

export ZATOR_ROOT="$TMP_DIR/zator"
CUSTOM_FILE="$ZATOR_ROOT/extra_strats/TCP_Custom.txt"
mkdir -p "$ZATOR_ROOT/extra_strats"

# locked.tsv: числовые профили, mark-строки, IP и домены. В список переезжают
# только домены, отсутствующие в нём, в порядке lock-файла.
cat > "$ORCH_LOCK_FILE" <<'EOF'
1	tls	28
3	tls	26
mark:2	tls	7
10.0.0.1	tls	5
rustorka.com	tls	20
amnezia.org	tls	27
EOF
printf 'amnezia.org\n' > "$CUSTOM_FILE"

restored="$(custom_rkn_restore_from_locks)"
[ "$restored" = "1" ] || fail "custom_rkn_restore_from_locks должен добавить 1 домен, добавлено: $restored"
[ "$(cat "$CUSTOM_FILE")" = "amnezia.org
rustorka.com" ] || fail "восстановление вставило домен не туда/не то: $(cat "$CUSTOM_FILE" | tr '\n' ',')"
restored="$(custom_rkn_restore_from_locks)"
[ "$restored" = "0" ] || fail "повторное восстановление должно быть no-op, добавлено: $restored"

# Переименование: позиция строки в списке и в lock-файле сохраняется.
printf 'rustorka.com\namnezia.org\n' > "$CUSTOM_FILE"
custom_rkn_rename_domain "amnezia.org" "nova.example.org" || fail "custom_rkn_rename_domain упал"
[ "$(cat "$CUSTOM_FILE")" = "rustorka.com
nova.example.org" ] || fail "переименование не сохранило позицию строки в списке"
awk -F '\t' '$1=="nova.example.org" && $2=="tls" && $3=="27" {ok=1} END{exit !ok}' "$ORCH_LOCK_FILE" \
  || fail "лок домена не переименован"
awk -F '\t' '$1=="rustorka.com" && $2=="tls" && $3=="20" {ok=1} END{exit !ok}' "$ORCH_LOCK_FILE" \
  || fail "чужие локи повреждены при переименовании"
rm_rc=0
custom_rkn_rename_domain "absent.example" "x.example.org" 2>/dev/null || rm_rc=$?
[ "$rm_rc" = "2" ] || fail "переименование отсутствующего домена должно давать 2, получено: $rm_rc"

# Общий случай: любой список (исключения, подстроки) — без локов, позиция строки
# сохраняется; код 2 для отсутствующей записи.
RENAME_LIST="$TMP_DIR/rename_list.txt"
printf 'first.com\nsecond.com\n' > "$RENAME_LIST"
domain_list_rename "$RENAME_LIST" "first.com" "renamed.com" || fail "domain_list_rename упал"
[ "$(cat "$RENAME_LIST")" = "renamed.com
second.com" ] || fail "domain_list_rename не сохранил позицию строки: $(cat "$RENAME_LIST" | tr '\n' ',')"
rm_rc=0
domain_list_rename "$RENAME_LIST" "absent.com" "x.com" 2>/dev/null || rm_rc=$?
[ "$rm_rc" = "2" ] || fail "domain_list_rename отсутствующей записи должен давать 2, получено: $rm_rc"

# Статика: деплой TCP_Custom в z2r.sh не безусловный, самолечение подключено
# на старте z2r и в CGI чтения списка, rename присутствует во всех слоях.
tcp_custom_downloads="$(grep -c 'z2r_download_project_file "\$ZATOR_ROOT/extra_strats/TCP_Custom\.txt"' "$REPO_DIR/z2r.sh")"
tcp_custom_guards="$(grep -c 'if \[ ! -f "\$ZATOR_ROOT/extra_strats/TCP_Custom\.txt" \]; then' "$REPO_DIR/z2r.sh")"
[ "$tcp_custom_downloads" -ge 1 ] && [ "$tcp_custom_downloads" = "$tcp_custom_guards" ] \
  || fail "z2r.sh: есть скачивание TCP_Custom.txt без guard'а [ ! -f ] (затирает список)"
grep -q 'custom_rkn_restore_from_locks' "$REPO_DIR/z2r.sh" || fail "z2r.sh не вызывает custom_rkn_restore_from_locks на старте"
assert_contains "$_lib_sh" 'custom_rkn_restore_from_locks' "_lib.sh: чтение custom_rkn не лечит список"
assert_contains "$_lib_sh" 'rename)' "_lib.sh: нет действия rename в api_domains_action"
assert_contains "$_lib_sh" 'PARAM_NEW_DOMAIN' "_lib.sh: нет параметра new_domain"
assert_contains "$(cat "$REPO_DIR/lib/strategies.sh")" 'custom_rkn_rename_domain\(\)' "lib/strategies.sh: нет custom_rkn_rename_domain"
assert_contains "$(cat "$REPO_DIR/lib/orchestra_state.sh")" 'orch_locked_rename_everywhere\(\)' "lib/orchestra_state.sh: нет orch_locked_rename_everywhere"
for needle in 'orch_locked_rename' 'orch_locked_domain_names' '"rename"'; do
  assert_contains "$fake_py" "$needle" "fake_router_server.py не реализует $needle"
done
src_all="$(find "$REPO_DIR/webui-src/src" -type f \( -name '*.vue' -o -name '*.ts' \) -exec cat {} +)"
for needle in "action: 'rename'" 'new_domain' 'domain-rename-input' 'rename-btn'; do
  assert_contains "$src_all" "$needle" "webui-src не использует $needle"
done

echo "webui settings smoke ok"
