#!/bin/sh
# Экономное обновление core: только временные корни, сервис и ресурсы замоканы.
set -e
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/z2r_economy_smoke.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

export ZATOR_ROOT="$WORK/zator" ZAPRET2_ROOT="$WORK/zapret2" Z2R_SCRIPT_DEST="$WORK/z2r.sh"
. "$REPO_DIR/lib/deploy.sh"
mkdir -p "$WORK/package/z2r_lib" "$WORK/package/lists" "$WORK/package/_payload" "$WORK/package/extra_strats/cache/deploy"
printf 'NEW\n' > "$WORK/package/z2r_lib/demo.sh"
printf 'SAME\n' > "$WORK/package/lists/same.txt"
printf 'DEFAULT\n' > "$WORK/package/lists/user.txt"
printf 'NEW-CONFIG\n' > "$WORK/package/_payload/config.default"
printf 'ZATOR_VERSION="economy-test"\nZATOR_DATE="2026-10-28 00:00"\n' > "$WORK/package/extra_strats/cache/deploy/version.env"
for path in z2r_lib/demo.sh lists/same.txt lists/user.txt _payload/config.default; do
  cls=auto
  dest="/opt/zator/$path"
  [ "$path" != lists/user.txt ] || cls=keep-if-exists
  [ "$path" != _payload/config.default ] || dest=/opt/zator/.deploy-payload/config.default
  printf '%s|%s|%s|%s|%s|0\n' "$path" "$dest" "$cls" "$(file_sha256 "$WORK/package/$path")" "$(wc -c < "$WORK/package/$path")"
done > "$WORK/package/extra_strats/cache/deploy/manifest.tsv"
tar -czf "$WORK/core.tar.gz" -C "$WORK/package" .

reset_install() {
  rm -rf "$ZATOR_ROOT" "$ZAPRET2_ROOT"
  mkdir -p "$ZATOR_ROOT/z2r_lib" "$ZATOR_ROOT/lists" "$ZAPRET2_ROOT"
  printf 'OLD\n' > "$ZATOR_ROOT/z2r_lib/demo.sh"
  chmod 755 "$ZATOR_ROOT/z2r_lib/demo.sh"
  command cp "$WORK/package/lists/same.txt" "$ZATOR_ROOT/lists/same.txt"
  printf 'USER\n' > "$ZATOR_ROOT/lists/user.txt"
  printf 'LIVE\n' > "$ZAPRET2_ROOT/config"
  rm -f "$WORK/stopped" "$WORK/bad-order" "$WORK/trace" "$WORK/copied" "$WORK/backup-prompt" "$WORK/consent"
  FAIL_COPY=0 CORRUPT_COPY=0 FAIL_RESTORE=0 SIGNAL_COPY=0 LOW_MEMORY=0 RUNNING=1 TMP_FREE=100000 OPT_FREE=512
}
free_kb() { case "$1" in /tmp) echo "$TMP_FREE";; *) echo "$OPT_FREE";; esac; }
deploy_check_memory() { [ "$LOW_MEMORY" = 0 ] || [ -f "$WORK/stopped" ]; }
pidof() { [ "$RUNNING" = 1 ] && echo 123; }
sync() { :; }
z2r_service_action() {
  echo "$1" >> "$WORK/trace"
  case "$1" in
    stop)
      [ -f "$WORK/consent" ] || { touch "$WORK/bad-order"; return 1; }
      touch "$WORK/stopped"
      ;;
    start)
      [ ! -e "$tmpbase" ] || { touch "$WORK/bad-order"; return 1; }
      rm -f "$WORK/stopped"
      ;;
    *) touch "$WORK/bad-order"; return 1;;
  esac
}
config_apply_from_default() {
  [ ! -e "$tmpbase" ] && [ -f "$WORK/stopped" ] || { touch "$WORK/bad-order"; return 1; }
  echo apply >> "$WORK/trace"
}
backup_helper_ask_and_create() { touch "$WORK/backup-prompt"; return 1; }
cp() {
  if [ "$1" = -p ] && [ "$2" = "$tmpbase/old-file" ] && [ "$FAIL_RESTORE" = 1 ]; then return 1; fi
  if [ "$1" = "$tmpbase/stage/lists/same.txt" ]; then
    touch "$WORK/bad-order"
    return 1
  fi
  if [ "$1" = "$tmpbase/stage/z2r_lib/demo.sh" ]; then
    [ ! -e "$2" ] && [ -f "$tmpbase/old-file" ] || { touch "$WORK/bad-order"; return 1; }
    touch "$WORK/copied"
    if [ "$SIGNAL_COPY" = 1 ]; then
      printf 'PARTIAL\n' > "$2"
      read -r signal_pid rest < /proc/self/stat
      kill -TERM "$signal_pid"
      return 1
    fi
    if [ "$FAIL_COPY" = 1 ]; then printf 'PARTIAL\n' > "$2"; return 1; fi
    if [ "$CORRUPT_COPY" = 1 ]; then printf 'CORRUPT\n' > "$2"; return 0; fi
  fi
  command cp "$@"
}
check_cleanup() {
  [ ! -e "$WORK/bad-order" ] || fail "нарушен порядок замены/очистки/старта"
  [ ! -e "$WORK/backup-prompt" ] || fail "экономный режим создал обычный бэкап на /opt"
  [ ! -e "/tmp/z2r_deploy_$$" ] || fail "временные файлы остались после обновления"
}

reset_install
if deploy_from_tar "$WORK/core.tar.gz" core < /dev/null > "$WORK/result" 2>&1; then
  fail "экономный режим запущен без интерактивного подтверждения"
fi
grep -q 'отключении питания' "$WORK/result" || fail "нет предупреждения о риске"
grep -q 'ручное восстановление' "$WORK/result" || fail "нет предупреждения о восстановлении"
[ ! -e "$WORK/trace" ] && [ ! -e "$WORK/copied" ] || fail "нет терминала: сервис/файлы изменены"
check_cleanup
echo 'ok: no terminal refuses economy update before stop/write'

deploy_confirm_economy() { return 1; }
reset_install
if deploy_from_tar "$WORK/core.tar.gz" core > "$WORK/result" 2>&1; then fail "отказ пользователя проигнорирован"; fi
[ ! -e "$WORK/trace" ] && [ ! -e "$WORK/copied" ] || fail "отказ пользователя изменил сервис/файлы"
check_cleanup
echo 'ok: declined consent leaves service and files untouched'

# Дальнейшие сценарии проверяют обновление после явного согласия.
deploy_confirm_economy() { touch "$WORK/consent"; }
reset_install
LOW_MEMORY=1
deploy_from_tar "$WORK/core.tar.gz" core > "$WORK/result" 2>&1 || { cat "$WORK/result"; fail "обновление при 512 КБ на /opt и нехватке ОЗУ"; }
check_cleanup
[ -f "$WORK/copied" ] || fail "изменённый файл не заменён"
grep -q '^NEW$' "$ZATOR_ROOT/z2r_lib/demo.sh" || fail "неверное содержимое нового файла"
grep -q '^USER$' "$ZATOR_ROOT/lists/user.txt" || fail "пользовательский файл перезаписан"
[ "$(cat "$WORK/trace")" = "$(printf 'stop\napply\nstart')" ] || fail "лишний/ранний запуск сервиса"
grep -q 'без изменений: 1' "$WORK/result" || fail "совпадающий файл не пропущен"
echo 'ok: low resources, SHA256 skip, user files, cleanup before apply/start'

reset_install
FAIL_COPY=1
if deploy_from_tar "$WORK/core.tar.gz" core > "$WORK/result" 2>&1; then fail "сбой записи скрыт"; fi
check_cleanup
grep -q '^OLD$' "$ZATOR_ROOT/z2r_lib/demo.sh" || fail "старый файл не восстановлен после сбоя записи"
# MSYS не сохраняет POSIX execute bit через временный файл без расширения.
command -v cygpath >/dev/null 2>&1 || [ -x "$ZATOR_ROOT/z2r_lib/demo.sh" ] || fail "права старого файла не восстановлены"
[ "$(cat "$WORK/trace")" = "$(printf 'stop\nstart')" ] || fail "сервис не восстановлен после сбоя"
echo 'ok: copy failure restores old file before cleanup/start'

reset_install
CORRUPT_COPY=1
if deploy_from_tar "$WORK/core.tar.gz" core > "$WORK/result" 2>&1; then fail "повреждение после записи не обнаружено"; fi
check_cleanup
grep -q '^OLD$' "$ZATOR_ROOT/z2r_lib/demo.sh" || fail "старый файл не восстановлен после несовпадения SHA256"
echo 'ok: installed hash checked, corruption rolled back'

if [ -r /proc/self/stat ] && ! command -v cygpath >/dev/null 2>&1; then
  reset_install
  SIGNAL_COPY=1
  if deploy_from_tar "$WORK/core.tar.gz" core > "$WORK/result" 2>&1; then fail "TERM скрыт"; fi
  check_cleanup
  grep -q '^OLD$' "$ZATOR_ROOT/z2r_lib/demo.sh" || fail "TERM не восстановил старый файл"
  [ "$(cat "$WORK/trace")" = "$(printf 'stop\nstart')" ] || fail "TERM не вернул сервис"
  echo 'ok: TERM during replacement restores old file before cleanup/start'
fi

reset_install
FAIL_COPY=1 FAIL_RESTORE=1
if deploy_from_tar "$WORK/core.tar.gz" core > "$WORK/result" 2>&1; then fail "сбой восстановления скрыт"; fi
grep -q '^OLD$' "/tmp/z2r_deploy_$$/old-file" || fail "последняя резервная копия удалена после сбоя восстановления"
[ "$(cat "$WORK/trace")" = stop ] || fail "сервис запущен после сбоя восстановления"
rm -rf "/tmp/z2r_deploy_$$"
echo 'ok: failed restore retains backup and leaves service stopped'

reset_install
LOW_MEMORY=1 OPT_FREE=100000
deploy_from_tar "$WORK/core.tar.gz" core > "$WORK/result" 2>&1 || fail "экономный режим не включился только по нехватке ОЗУ"
check_cleanup
[ -f "$WORK/copied" ] || fail "обновление по нехватке ОЗУ пропущено"
echo 'ok: low RAM alone selects economy mode'

reset_install
TMP_FREE=1
if deploy_from_tar "$WORK/core.tar.gz" core > "$WORK/result" 2>&1; then fail "тесный /tmp пропущен"; fi
check_cleanup
grep -q '^OLD$' "$ZATOR_ROOT/z2r_lib/demo.sh" || fail "нехватка /tmp изменила установку"
[ "$(cat "$WORK/trace")" = "$(printf 'stop\nstart')" ] || fail "сервис не запущен после ошибки /tmp"
echo 'ok: /tmp preflight failure cleans up and restarts'

reset_install
RUNNING=0
deploy_from_tar "$WORK/core.tar.gz" core > "$WORK/result" 2>&1 || fail "обновление с остановленным сервисом"
check_cleanup
[ "$(cat "$WORK/trace")" = "$(printf 'stop\napply')" ] || fail "изначально остановленный сервис запущен"
echo 'ok: initially stopped service stays stopped'

reset_install
deploy_fetch_release_meta() { return 1; }
if deploy_from_tar https://invalid.example/core.tar.gz core > "$WORK/result" 2>&1; then fail "ошибка сети скрыта"; fi
check_cleanup
[ "$(cat "$WORK/trace")" = "$(printf 'stop\nstart')" ] || fail "сбой сети оставил сервис остановленным"
echo 'ok: network failure cleans up before restart'

reset_install
deploy_fetch_release_meta() {
  DEPLOY_META_ASSET_CORE_SHA="$(file_sha256 "$WORK/core.tar.gz")"
  return 0
}
z2r_fetch_url_to_file() { command cp "$WORK/core.tar.gz" "$1"; }
deploy_from_tar https://invalid.example/core.tar.gz core > "$WORK/result" 2>&1 || fail "URL-обновление"
check_cleanup
[ "$(cat "$WORK/trace")" = "$(printf 'stop\napply\nstart')" ] || fail "скачанный архив не очищен до старта"
[ -f "$WORK/core.tar.gz" ] || fail "удалён исходный локальный архив пользователя"
echo 'ok: downloaded archive removed before restart, local input retained'

reset_install
unset -f z2r_service_action
command cp "$REPO_DIR/lib/config.sh" "$ZATOR_ROOT/z2r_lib/config.sh"
export DEPLOY_TEST_WORK="$WORK" DEPLOY_TEST_TMPBASE="/tmp/z2r_deploy_$$"
mkdir -p "$ZAPRET2_ROOT/init.d/sysv"
cat > "$ZAPRET2_ROOT/init.d/sysv/zapret2" <<'EOF'
#!/bin/sh
echo "$1" >> "$DEPLOY_TEST_WORK/trace"
case "$1" in
  stop) touch "$DEPLOY_TEST_WORK/stopped";;
  start)
    [ ! -e "$DEPLOY_TEST_TMPBASE" ] || { touch "$DEPLOY_TEST_WORK/bad-order"; exit 1; }
    rm -f "$DEPLOY_TEST_WORK/stopped"
    ;;
  *) exit 1;;
esac
EOF
chmod 755 "$ZAPRET2_ROOT/init.d/sysv/zapret2"
deploy_from_tar "$WORK/core.tar.gz" core > "$WORK/result" 2>&1 || { cat "$WORK/result"; fail "standalone service helper"; }
check_cleanup
[ "$(cat "$WORK/trace")" = "$(printf 'stop\napply\nstart')" ] || fail "standalone не использовал общий z2r_service_action"
echo 'ok: standalone sources shared service helper and detects init'

echo 'deploy economy smoke ok'
