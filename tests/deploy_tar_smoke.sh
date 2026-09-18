#!/usr/bin/env bash
#
# Smoke-тест tar-развёртывания zator: сборщик pack-zator-tar.mjs и функции
# lib/deploy.sh (deploy_from_tar, защиты keep-if-exists, выбор режима
# staging A/B/C, слияние version.env, целостность, сброс к эталону).
#
# Покрывает:
#   1. bash -n lib/deploy.sh; статический wiring: z2r.sh source-ит deploy.sh,
#      п.5 ведёт в deploy_update_menu с деградацией, Enter-подсказка обновлена.
#      Плюс busybox-sh совместимость deploy.sh: при недоступном bash (Merlin,
#      слетевшее монтирование Entware) лаунчер выполняет его под ash, где
#      bash-измы дают «syntax error: bad substitution» (кейс r1616: line 142).
#   2. Сборщик (node): три варианта одним прогоном, latest.json со схемой и
#      размерами, version.env/manifest.tsv внутри архива, sha256sum -c.
#   3. deploy_from_tar из локального full-архива (режим A): файлы установлены,
#      _root/z2r.sh и _payload разложены, symlink webui/www/cgi-bin.
#   4. Защиты: существующие netrogat.txt/TCP_Custom.txt не перезаписаны,
#      autohostlist.txt и runtime-файлы cache/ не тронуты.
#   5. Обновление поверх установки (webui-вариантом): version.env слит —
#      ZATOR_* от прежней сборки, WEBUI_* от новой.
#   6. Режим C (мок df со тесным /tmp): перестановка каталогов, runtime
#      перенесён, пользовательский netrogat.txt сохранён.
#   7. deploy_integrity_check после деплоя — все файлы совпадают.
#   8. deploy_reset_user_files: изменённый TCP_Custom.txt возвращается к
#      эталону через stdin-ответ.
#   9. --version попадает в version.env/latest.json (номер релиза).
#
# ИЗОЛЯЦИЯ: всё во временной папке /tmp (trap EXIT); ZATOR_ROOT,
# Z2R_SCRIPT_DEST переопределяются ДО source lib/deploy.sh; deploy_dest_for
# перегоняет канонические /opt/... из манифеста в тестовые пути.
#
# Возврат: 0 — успех («deploy tar smoke ok»), 1 — ошибка.
# Запуск: bash tests/deploy_tar_smoke.sh
# Требует: bash, node, tar, gzip, sha256sum, df, awk.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PASS=0
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ok() {
  PASS=$((PASS + 1))
  echo "ok $PASS: $*"
}

command -v sha256sum >/dev/null 2>&1 || fail "sha256sum не найден"

# SMOKE_DIST: каталог с готовыми zator-{core,webui,full}.tar.gz (+.sha256,
# +.manifest.tsv) — сборка пропускается, node не нужен (запуск на роутере).
WORK="$(mktemp -d /tmp/z2r_deploy_smoke.XXXXXX)" || fail "mktemp"
trap 'rm -rf "$WORK"' EXIT
export ZATOR_ROOT="$WORK/zator"
export Z2R_SCRIPT_DEST="$WORK/z2r.sh"
if [ -n "${SMOKE_DIST:-}" ]; then
  DIST="$SMOKE_DIST"
else
  DIST="$WORK/dist"
fi

# MSYS/Windows разворачивает симлинки из tar копиями — полноценную проверку
# линков делаем только на Linux, на MSYS достаточно существования пути.
check_symlink() {
  [ -L "$1" ] && return 0
  command -v cygpath >/dev/null 2>&1 && [ -e "$1" ] && return 0
  return 1
}

# --- 1. статика ---

bash -n "$REPO_DIR/lib/deploy.sh" || fail "bash -n lib/deploy.sh"
bash -n "$REPO_DIR/z2r.sh" || fail "bash -n z2r.sh"
grep -q 'source "$LIB_DIR/deploy.sh"' "$REPO_DIR/z2r.sh" || fail "z2r.sh не source-ит deploy.sh"
grep -q 'deploy_update_menu' "$REPO_DIR/z2r.sh" || fail "п.5 не ведёт в deploy_update_menu"
grep -q 'Enter (без цифр)' "$REPO_DIR/z2r.sh" && fail "Enter-подсказка не убрана: Enter должен ничего не делать"
grep -q 'DEPLOY_WANT_REINSTALL' "$REPO_DIR/z2r.sh" || fail "п.5 не запускает переустановку zapret2"
grep -q 'DEPLOY_PAYLOAD_DIR' "$REPO_DIR/z2r.sh" || fail "z2r_download_project_file без payload-источника"
ok "статика z2r.sh"

# --- 1b. busybox-sh совместимость deploy.sh ---
# Лаунчер при недоступном bash выполняет deploy.sh под ash (наблюдалось на
# Merlin RT-BE92U: «deploy.sh: line 142: syntax error: bad substitution»).
# Запрещённые bash-измы: ${var^^}/${var,,}/${var~}/${var@}/массивы, ${!var},
# BASH_SOURCE, RETURN-ловушки, declare/mapfile/read -a, &>. Грепаем код без
# полнолинейных комментариев (в шапке файл объясняет эти же запреты словами).
BUSYISM_RE='\$\{[A-Za-z_][A-Za-z0-9_]*[\^,~@]|\$\{![A-Za-z_]|BASH_SOURCE|trap[[:space:]].*RETURN|\$\{[A-Za-z_][A-Za-z0-9_]*\[|=[[:space:]]*\(|local -[aA]|\bdeclare[[:space:]]|\bmapfile\b|read[[:space:]]+-[aA][[:space:]]|&>>?'
printf 'eval "X_${v^^}_Y=1"\ntrap "rm" RETURN\narr=(1 2)\n' | grep -qE "$BUSYISM_RE" \
  || fail "BUSYISM_RE ничего не ловит — сломан сам предохранитель"
busyism_hits="$(grep -vE '^[[:space:]]*#' "$REPO_DIR/lib/deploy.sh" | grep -nE "$BUSYISM_RE")"
if [ -n "$busyism_hits" ]; then
  echo "$busyism_hits" >&2
  fail "lib/deploy.sh содержит bash-измы — файл обязан работать под busybox sh"
fi
if command -v busybox >/dev/null 2>&1; then
  # sh -n у busybox не выявляет bad substitution — исполняем файл с заведомо
  # неверным аргументом: полный парс всего файла, затем usage (rc=2), без
  # побочных эффектов (верхний уровень ничего не пишет на диск).
  bb_out="$(busybox sh "$REPO_DIR/lib/deploy.sh" __busybox_parse__ 2>&1)"
  bb_rc=$?
  [ "$bb_rc" = 2 ] || fail "busybox sh deploy.sh упал с rc=$bb_rc: $bb_out"
  case "$bb_out" in
    *использование*) ;;
    *) fail "busybox sh deploy.sh без usage (rc=$bb_rc): $bb_out" ;;
  esac
fi
ok "busybox-sh совместимость deploy.sh (bash-измы запрещены)"

# --- 2. сборка (пропускается при SMOKE_DIST) ---

if [ -n "${SMOKE_DIST:-}" ]; then
  for v in core webui full; do
    [ -f "$DIST/zator-$v.tar.gz" ] || fail "SMOKE_DIST: нет zator-$v.tar.gz"
  done
  ok "готовые архивы из SMOKE_DIST"
else
  # node под MSYS понимает только нативные пути: /tmp/... превращается в корень диска
  DIST_OUT="$DIST"
if command -v cygpath >/dev/null 2>&1; then
  DIST_OUT="$(cygpath -w "$DIST")"
fi
(cd "$REPO_DIR/webui-src" && node scripts/pack-zator-tar.mjs --version=deploy-smoke-1010 --out "$DIST_OUT") >/dev/null \
  || fail "сборщик упал"
for v in core webui full; do
  [ -f "$DIST/zator-$v.tar.gz" ] || fail "нет zator-$v.tar.gz"
  (cd "$DIST" && sha256sum -c "zator-$v.sha256") >/dev/null 2>&1 || fail "sha256 не сходится: $v"
  [ -f "$DIST/zator-$v.manifest.tsv" ] || fail "нет manifest.tsv: $v"
done
grep -q '"release": "deploy-smoke-1010"' "$DIST/latest.json" || fail "latest.json без номера версии"
grep -q '"unpackedSize"' "$DIST/latest.json" || fail "latest.json без unpackedSize"
node -e '
  const m = require(process.argv[1]);
  if (m.schemaVersion !== 1) process.exit(1);
  for (const v of ["core", "webui", "full"]) {
    const a = m.assets[v];
    if (!a || !a.size || !a.sha256 || !a.unpackedSize) process.exit(1);
  }
' "$DIST/latest.json" 2>/dev/null || fail "схема latest.json неполная"
ok "сборщик: 3 варианта, latest.json, sha256"
fi

STAGE="$WORK/unpack"
mkdir -p "$STAGE"
tar -xzf "$DIST/zator-full.tar.gz" -C "$STAGE" || fail "распаковка full"
grep -q '^ZATOR_VERSION="..*"$' "$STAGE/extra_strats/cache/deploy/version.env" || fail "version.env без версии"
grep -q 'TRACKING="latest"' "$STAGE/extra_strats/cache/deploy/version.env" || fail "version.env без TRACKING"
head -1 "$STAGE/extra_strats/cache/deploy/manifest.tsv" | grep -q '^# path|dest|class|sha256|size|exec$' || fail "заголовок manifest.tsv"
grep -q '^_root/z2r.sh|/opt/z2r.sh|auto|' "$STAGE/extra_strats/cache/deploy/manifest.tsv" || fail "manifest без _root/z2r.sh"
grep -q '^_payload/config.default|/opt/zator/.deploy-payload/config.default|payload|' "$STAGE/extra_strats/cache/deploy/manifest.tsv" || fail "manifest без payload"
grep -q '^lists/netrogat.txt|.*|keep-if-exists|' "$STAGE/extra_strats/cache/deploy/manifest.tsv" || fail "manifest без keep-if-exists у netrogat"
check_symlink "$STAGE/webui/www/cgi-bin" || fail "нет symlink webui/www/cgi-bin"
grep -q $'\r' "$STAGE/lists/netrogat.txt" 2>/dev/null && fail "CRLF в netrogat.txt"
expected_ver="$(sed -n 's/^ZATOR_VERSION="\(.*\)"$/\1/p' "$STAGE/extra_strats/cache/deploy/version.env")"
ok "архив: version.env, manifest.tsv, symlink, LF"

# --- 3-4. deploy_from_tar, режим A, защиты ---

# предустановка «старого» пользователя: изменённые netrogat.txt и TCP_Custom,
# runtime-состояние, которого нет в архиве
mkdir -p "$ZATOR_ROOT/lists" "$ZATOR_ROOT/extra_strats" "$ZATOR_ROOT/extra_strats/cache/orchestra" "$ZATOR_ROOT/webui/run"
printf 'user-domain.example\n' > "$ZATOR_ROOT/lists/netrogat.txt"
printf 'custom.example\n' > "$ZATOR_ROOT/extra_strats/TCP_Custom.txt"
printf 'autohost-runtime\n' > "$ZATOR_ROOT/lists/autohostlist.txt"
printf 'lock-runtime\n' > "$ZATOR_ROOT/extra_strats/cache/orchestra/locked.tsv"
printf 'pid\n' > "$ZATOR_ROOT/webui/run/webui.pid"

source "$REPO_DIR/lib/deploy.sh"

# изоляция zapret2-корня для deploy_apply_config_default (эталон config.default)
export ZAPRET2_ROOT="$WORK/zapret2"

# регрессия коллизии имён: контентный webuiSha из latest.json не должен
# затираться sha256 ассета (цикл по вариантам в deploy_fetch_release_meta)
SMOKE_JSON_SRC="$DIST/latest.json"
z2r_fetch_url_to_file() { cp "$SMOKE_JSON_SRC" "$1"; }
deploy_fetch_release_meta latest
exp_webui_sha="$(grep '"webuiSha":' "$SMOKE_JSON_SRC" | head -n1 | sed 's/.*: *"//; s/".*//')"
[ -n "$exp_webui_sha" ] || fail "latest.json без webuiSha"
[ "$DEPLOY_META_WEBUI_SHA" = "$exp_webui_sha" ] || fail "DEPLOY_META_WEBUI_SHA не контентный webuiSha (коллизия с ассетом)"
[ -n "$DEPLOY_META_ASSET_WEBUI_SHA" ] || fail "DEPLOY_META_ASSET_WEBUI_SHA пуст"
[ "$DEPLOY_META_ASSET_WEBUI_SHA" != "$exp_webui_sha" ] || fail "тест не различает контентный и ассетный sha"
ok "deploy_fetch_release_meta: контентный и ассетный sha разделены"

# регрессия set -e: deploy_menu_header с отсутствующими version.env/latest.env
# не должен ронять вызывающий скрипт; без установленной панели шапка не должна
# упоминать Web-панель (поля WEBUI_* есть даже в core-сборке)
rm -rf "$WORK/empty-zator"
mkdir -p "$WORK/empty-zator"
( cd "$REPO_DIR" && ZATOR_ROOT="$WORK/empty-zator" bash -c 'set -e; source lib/deploy.sh >/dev/null 2>&1; deploy_menu_header; echo SURVIVED; echo "PART=[$MENU_WEBUI_PART]"' ) > "$WORK/hdr.out" 2>&1
grep -q SURVIVED "$WORK/hdr.out" || fail "deploy_menu_header роняет set -e при пустом окружении"
grep -q 'PART=\[\]' "$WORK/hdr.out" || fail "шапка пишет про Web-панель без установленной панели"
ok "deploy_menu_header безопасен под set -e и молчит про отсутствующую панель"

# --- config_update_pending + уведомление «Есть новый конфиг» в шапке ---
source "$REPO_DIR/lib/config.sh"
grep -q 'config_update_pending' "$REPO_DIR/webui-src/src/api/types.ts" || fail "types.ts без config_update_pending"
grep -q 'config_update_pending' "$REPO_DIR/webui-src/src/components/status/StatusCards.vue" || fail "StatusCards без config_update_pending"
grep -q 'config_update_pending' "$REPO_DIR/webui/cgi-bin/_lib.sh" || fail "_lib.sh без config_update_pending"
grep -q 'config_update_pending' "$REPO_DIR/webui/dev/fake_router_server.py" || fail "fake_router_server без config_update_pending"
mkdir -p "$ZAPRET2_ROOT"
printf '# Last modified: 2026-09-05 12:17:37 UTC\n' > "$ZAPRET2_ROOT/config"
printf '# Last modified: 2026-09-05 12:17:37 UTC\n' > "$ZAPRET2_ROOT/config.default"
config_update_pending && fail "pending при равных датах"
printf '# Last modified: 2026-09-06 00:00:00 UTC\n' > "$ZAPRET2_ROOT/config.default"
config_update_pending || fail "pending не сработал при новом эталоне"
printf '# Last modified: 2026-09-04 00:00:00 UTC\n' > "$ZAPRET2_ROOT/config.default"
config_update_pending && fail "pending при эталоне старее живого конфига"
printf '# Last modified: 2026-09-06 00:00:00 UTC\r\n' > "$ZAPRET2_ROOT/config.default"
config_update_pending || fail "pending не работает с CRLF-заголовком"
mv "$ZAPRET2_ROOT/config.default" "$ZAPRET2_ROOT/config.default.bak"
config_update_pending && fail "pending без config.default"
mv "$ZAPRET2_ROOT/config.default.bak" "$ZAPRET2_ROOT/config.default"
printf 'нет заголовка\n' > "$ZAPRET2_ROOT/config"
config_update_pending && fail "pending без заголовка в живом конфиге"
printf '# Last modified: 2026-09-05 12:17:37 UTC\n' > "$ZAPRET2_ROOT/config"
deploy_menu_header >/dev/null 2>&1
case "$MENU_DEPLOY_NOTICE" in *"Есть новый конфиг от 2026-09-06. Для применения: п.5 -> п.7"*) ;; *) fail "шапка без уведомления о новом конфиге" ;; esac
printf '# Last modified: 2026-09-06 00:00:00 UTC\n' > "$ZAPRET2_ROOT/config"
deploy_menu_header >/dev/null 2>&1
case "$MENU_DEPLOY_NOTICE" in *"Есть новый конфиг"*) fail "шапка показывает уведомление при применённом конфиге" ;; esac
rm -f "$ZAPRET2_ROOT/config" "$ZAPRET2_ROOT/config.default"
ok "config_update_pending и уведомление шапки"

# --- зеркало релизов: резолв sources.env и приоритет env ---
grep -q 'deploy_sources_menu' "$REPO_DIR/lib/deploy.sh" || fail "нет подменю источников"
grep -q 'submenu_item 10' "$REPO_DIR/lib/deploy.sh" || fail "нет п.10 в меню 5"
mkdir -p "$ZATOR_ROOT/extra_strats/cache/deploy"
printf 'RELEASES_MIRROR="https://mirror.example.com/zator"\n' > "$(deploy_sources_file)"
[ "$(deploy_releases_base)" = "https://mirror.example.com/zator" ] || fail "deploy_releases_base не читает зеркало из sources.env"
deploy_menu_header >/dev/null 2>&1
case "$MENU_DEPLOY_SOURCE" in *"зеркало mirror.example.com"*) ;; *) fail "шапка не показывает источник-зеркало" ;; esac
( export Z2R_RELEASES_BASE="https://env.example.com/dl"
  [ "$(deploy_releases_base)" = "https://env.example.com/dl" ] ) \
  || fail "env Z2R_RELEASES_BASE не приоритетнее sources.env"
rm -f "$(deploy_sources_file)"
case "$(deploy_releases_base)" in https://github.com/*) ;; *) fail "сброс не вернул GitHub-источник" ;; esac
ok "зеркало релизов: резолв, приоритет env, сброс"

# --- п.4: список номерных релизов через GitHub API ---
grep -q 'api.github.com' "$REPO_DIR/lib/deploy.sh" || fail "список релизов не использует GitHub API"
[ "$(deploy_releases_list_url)" = "https://api.github.com/repos/AloofLibra/zator/releases?per_page=20" ] \
  || fail "deploy_releases_list_url неверный для GitHub-источника"
rel_json="$WORK/releases_api.json"
rel_html="$WORK/releases_html.txt"
cat > "$rel_json" <<'JSON'
[
  { "tag_name": "1.0.1", "published_at": "2026-09-13T09:15:16Z" },
  { "tag_name": "latest", "published_at": "2026-09-13T09:15:12Z" },
  { "tag_name": "1.0", "published_at": "2026-09-12T08:05:02Z" }
]
JSON
printf '<html>releases page</html>\n' > "$rel_html"
rel_src="$rel_json"
z2r_fetch_url_to_file() { cat "$rel_src" > "$1"; }
rel_out="$(deploy_list_releases)" || fail "deploy_list_releases упал на валидном ответе API"
printf '%s\n' "$rel_out" | grep -q '1\.0\.1  2026-09-13' || fail "список без 1.0.1 с датой"
printf '%s\n' "$rel_out" | grep -q '1\.0  2026-09-12' || fail "список без 1.0 с датой"
[ "$(wc -l < "$DEPLOY_RELEASES_LIST")" -eq 2 ] || fail "rolling-тег latest должен фильтроваться"
[ "$(sed -n 1p "$DEPLOY_RELEASES_LIST" | awk '{print $2}')" = "1.0.1" ] || fail "номер 1 указывает не на 1.0.1"
[ "$(sed -n 2p "$DEPLOY_RELEASES_LIST" | awk '{print $2}')" = "1.0" ] || fail "номер 2 указывает не на 1.0"
rel_src="$rel_html"
if rel_out="$(deploy_list_releases)"; then
  fail "HTML вместо JSON API должен давать отказ"
fi
printf '%s\n' "$rel_out" | grep -q 'не найдены или ответ источника не распознан' || fail "нет диагностики пустого списка"
rel_src=/nonexistent
if rel_out="$(deploy_list_releases)"; then
  fail "ошибка загрузки должна давать отказ"
fi
printf '%s\n' "$rel_out" | grep -q 'Не удалось получить список релизов' || fail "нет диагностики ошибки загрузки"
printf 'RELEASES_MIRROR="https://mirror.example.com/zator"\n' > "$(deploy_sources_file)"
if rel_out="$(deploy_list_releases)"; then
  fail "зеркало должно честно отказывать в списке релизов"
fi
printf '%s\n' "$rel_out" | grep -q 'не отдаёт список релизов' || fail "нет подсказки для зеркала"
rm -f "$(deploy_sources_file)"
ok "список номерных релизов: API, фильтр latest, диагностика"

# --- п.6: локальный архив zapret2 ---
[ "$(deploy_parse_zapret2_tarball_name /x/y/zapret2-v1.0.5.1.tar.gz)" = "1.0.5.1" ] || fail "парсер: обычная версия"
[ "$(deploy_parse_zapret2_tarball_name zapret2-v1.0.5.1-reasm-fix.tar.gz)" = "1.0.5.1-reasm-fix" ] || fail "парсер: суффикс форка"
[ "$(deploy_parse_zapret2_tarball_name zapret2-v1.0.5.1-openwrt-embedded.tar.gz)" = "1.0.5.1" ] || fail "парсер: openwrt-embedded"
deploy_parse_zapret2_tarball_name zapret2-v.tar.gz >/dev/null 2>&1 && fail "парсер принял пустую версию"
deploy_parse_zapret2_tarball_name zator-full.tar.gz >/dev/null 2>&1 && fail "парсер принял чужой архив"
Z2R_TMP_DIR="$WORK/z2rtmp"
FLAVOR_MARK="$WORK/flavor.mark"
zapret2_flavor_save() { echo "$1" >> "$FLAVOR_MARK"; }

rm -rf "$Z2R_TMP_DIR"; mkdir -p "$Z2R_TMP_DIR"; rm -f "$FLAVOR_MARK"
printf 'gz' > "$Z2R_TMP_DIR/zapret2-v1.0.5.1-reasm-fix.tar.gz"
deploy_local_zapret2_pick <<< "1" >/dev/null 2>&1 || fail "выбор локального архива упал"
[ "$ZAPRET2_VERSION" = "1.0.5.1-reasm-fix" ] || fail "ZAPRET2_VERSION из имени архива"
[ "$ZAPRET2_ARCHIVE_DIR" = "$Z2R_TMP_DIR/z2r_local_zapret2" ] || fail "ZAPRET2_ARCHIVE_DIR не подготовлен"
[ -f "$ZAPRET2_ARCHIVE_DIR/zapret2-v1.0.5.1-reasm-fix.tar.gz" ] || fail "нет канонического имени архива"
grep -q '^fork$' "$FLAVOR_MARK" || fail "суффикс версии не закрепил флэвор fork"
[ "$DEPLOY_WANT_REINSTALL" = 1 ] || fail "локальный архив не запросил переустановку"
DEPLOY_WANT_REINSTALL=0

rm -rf "$Z2R_TMP_DIR"; mkdir -p "$Z2R_TMP_DIR"; rm -f "$FLAVOR_MARK"
printf 'gz' > "$Z2R_TMP_DIR/zapret2-v1.0.5.tar.gz"
printf 'gz' > "$Z2R_TMP_DIR/zapret2-v1.0.5-openwrt-embedded.tar.gz"
deploy_local_zapret2_pick <<< "2" >/dev/null 2>&1 || fail "выбор без суффикса упал"
[ "$ZAPRET2_VERSION" = "1.0.5" ] || fail "версия без суффикса не распознана"
[ -f "$ZAPRET2_ARCHIVE_DIR/zapret2-v1.0.5.tar.gz" ] || fail "нет канонического имени (standard)"
[ -f "$ZAPRET2_ARCHIVE_DIR/zapret2-v1.0.5-openwrt-embedded.tar.gz" ] || fail "openwrt-вариант не подтянут рядом"
[ -s "$FLAVOR_MARK" ] && fail "версия без суффикса сменила флэвор"
DEPLOY_WANT_REINSTALL=0

deploy_local_zapret2_pick <<< "0" >/dev/null 2>&1 || fail "отмена упала"
[ "$DEPLOY_WANT_REINSTALL" = 0 ] || fail "отмена не отменила переустановку"
unset ZAPRET2_ARCHIVE_DIR ZAPRET2_VERSION
unset -f zapret2_flavor_save
ok "п.6: локальный архив zapret2, парсер, флэвор, отмена"

# --- харденинг: отказ на небезопасных tar и манифестах ---
EVIL_DIR="$WORK/evil"
mkdir -p "$EVIL_DIR/deep"
printf 'x' > "$EVIL_DIR/deep/plain"
GOOD_TAR="$EVIL_DIR/good.tar.gz"
tar -czf "$GOOD_TAR" -C "$EVIL_DIR/deep" plain
deploy_tar_paths_ok "$GOOD_TAR" || fail "валидатор отклонил чистый tar"
# GNU tar срезает ../ при создании, поэтому скармливаем листинг моком tar
MOCK_TAR="$WORK/mockbin/tar"
mkdir -p "$WORK/mockbin"
Z2R_EVIL_TAR="$GOOD_TAR"
export Z2R_EVIL_TAR
cat > "$MOCK_TAR" <<'MOCKEOF'
#!/bin/sh
if [ "$1" = "-tzf" ] && [ "$2" = "$Z2R_EVIL_TAR" ]; then
  printf '%s\n' '../evil' 'plain'
  exit 0
fi
exec /usr/bin/tar "$@"
MOCKEOF
chmod +x "$MOCK_TAR"
if PATH="$WORK/mockbin:$PATH" deploy_tar_paths_ok "$GOOD_TAR"; then
  fail "валидатор пропустил tar с ../-членом"
fi
PATH="$WORK/mockbin:$PATH" deploy_from_tar "$GOOD_TAR" >/dev/null 2>&1 \
  && fail "deploy_from_tar принял tar с ../-членом"
unset Z2R_EVIL_TAR
BAD_MAN_DIR="$WORK/badman"
mkdir -p "$BAD_MAN_DIR/stage"
printf 'x' > "$BAD_MAN_DIR/stage/file"
mkdir -p "$BAD_MAN_DIR/stage/extra_strats/cache/deploy"
printf 'file|/etc/cron.d/pwn|auto|%s|1|0\n' "$(file_sha256 "$BAD_MAN_DIR/stage/file")" \
  > "$BAD_MAN_DIR/stage/extra_strats/cache/deploy/manifest.tsv"
( cd "$REPO_DIR" && ZATOR_ROOT="$WORK/badman-target" bash -c '
    source lib/deploy.sh >/dev/null 2>&1
    deploy_apply_staging "'"$BAD_MAN_DIR"'/stage" latest' ) > "$BAD_MAN_DIR/out.txt" 2>&1
grep -q '/etc/cron.d/pwn' "$BAD_MAN_DIR/out.txt" || fail "манифест с /etc dest не отклонён"
ok "харденинг: tar с ../ и манифест с чужим dest отклоняются"

deploy_from_tar "$DIST/zator-full.tar.gz" >/dev/null 2>&1 || fail "deploy_from_tar (A) упал"
[ -f "$ZATOR_ROOT/z2r_lib/config.sh" ] || fail "z2r_lib не установлен"
[ -f "$Z2R_SCRIPT_DEST" ] || fail "_root/z2r.sh не установлен в Z2R_SCRIPT_DEST"
[ -f "$ZATOR_ROOT/.deploy-payload/config.default" ] || fail "payload config.default не разложен"
[ -f "$ZATOR_ROOT/.deploy-payload/Entware/keenetic-policy.sh" ] || fail "payload keenetic-policy.sh не разложен"
# payload config.default применяется к эталону в корне zapret2
# (живой config в standalone-контексте смоука отсутствует)
[ -f "$ZAPRET2_ROOT/config.default" ] || fail "payload config.default не скопирован в эталон zapret2"
cmp -s "$ZAPRET2_ROOT/config.default" "$ZATOR_ROOT/.deploy-payload/config.default" \
  || fail "эталон config.default отличается от payload"
[ -x "$ZATOR_ROOT/webui/run-webui.sh" ] || fail "run-webui.sh не исполняемый"
check_symlink "$ZATOR_ROOT/webui/www/cgi-bin" || fail "symlink cgi-bin не создан"
ok "deploy_from_tar A: файлы, payload, z2r.sh, symlink"

grep -q 'user-domain.example' "$ZATOR_ROOT/lists/netrogat.txt" || fail "netrogat.txt перезаписан"
grep -q 'custom.example' "$ZATOR_ROOT/extra_strats/TCP_Custom.txt" || fail "TCP_Custom.txt перезаписан"
grep -q 'autohost-runtime' "$ZATOR_ROOT/lists/autohostlist.txt" || fail "autohostlist.txt тронут"
grep -q 'lock-runtime' "$ZATOR_ROOT/extra_strats/cache/orchestra/locked.tsv" || fail "locked.tsv тронут"
grep -q 'pid' "$ZATOR_ROOT/webui/run/webui.pid" || fail "webui/run тронут"
ok "защиты keep-if-exists и runtime"

# --- 4b. payload config.default применяется к живому конфигу ---
# мокаем окружение меню: живой config есть, функции применителя доступны;
# проверяем связку stop -> apply -> restart внутри deploy_from_tar
mkdir -p "$ZAPRET2_ROOT"
printf 'LIVE-CONFIG\n' > "$ZAPRET2_ROOT/config"
APPLY_MARK="$WORK/apply.mark" RESTART_MARK="$WORK/restart.mark"
export APPLY_MARK RESTART_MARK
config_apply_from_default() { echo applied >> "$APPLY_MARK"; }
z2r_service_action() { echo "$1" >> "$RESTART_MARK"; }
backup_helper_ask_and_create() { BACKUP_HELPER_CREATED=0; return 0; }
deploy_from_tar "$DIST/zator-full.tar.gz" >/dev/null 2>&1 || fail "deploy_from_tar (apply) упал"
[ -s "$APPLY_MARK" ] || fail "config_apply_from_default не вызван при живом config"
grep -q '^stop$' "$RESTART_MARK" || fail "нет stop перед применением config.default"
grep -q '^restart$' "$RESTART_MARK" || fail "нет restart после применения config.default"
ok "payload config.default применяется к живому конфигу (stop -> apply -> restart)"
unset -f config_apply_from_default z2r_service_action backup_helper_ask_and_create

# --- 4c. лёгкий путь п.7: применить установленный config.default без сети ---
APPLY2_MARK="$WORK/apply2.mark"
config_apply_from_default() { echo applied >> "$APPLY2_MARK"; }
z2r_service_action() { :; }
backup_helper_ask_and_create() { BACKUP_HELPER_CREATED=0; return 0; }
rm -f "$ZAPRET2_ROOT/config" "$ZAPRET2_ROOT/config.default" "$ZATOR_ROOT/.deploy-payload/config.default"
deploy_apply_installed_config >/dev/null 2>&1 && fail "лёгкий путь без эталона должен вернуть ошибку"
printf '# Last modified: 2026-09-06 00:00:00 UTC\n' > "$ZATOR_ROOT/.deploy-payload/config.default"
printf '# Last modified: 2026-09-05 00:00:00 UTC\n' > "$ZAPRET2_ROOT/config"
rm -f "$APPLY2_MARK"
deploy_apply_installed_config >/dev/null 2>&1 || fail "лёгкий путь из payload упал"
[ -s "$APPLY2_MARK" ] || fail "лёгкий путь не вызвал config_apply_from_default"
[ -f "$ZAPRET2_ROOT/config.default" ] || fail "эталон не скопирован из payload в корень zapret2"
cmp -s "$ZAPRET2_ROOT/config.default" "$ZATOR_ROOT/.deploy-payload/config.default" || fail "payload рассинхронизирован после применения"
printf '# Last modified: 2026-09-06 00:00:00 UTC\n' > "$ZAPRET2_ROOT/config"
rm -f "$APPLY2_MARK"
deploy_apply_installed_config >/dev/null 2>&1 || fail "лёгкий путь при равных датах упал"
[ -s "$APPLY2_MARK" ] && fail "лёгкий путь применил конфиг при равных датах"
rm -f "$ZAPRET2_ROOT/config"
rm -f "$APPLY2_MARK"
deploy_apply_installed_config >/dev/null 2>&1 || fail "лёгкий путь без живого конфига упал"
[ -s "$APPLY2_MARK" ] && fail "лёгкий путь применил конфиг без живого config"
printf '# Last modified: 2026-09-05 00:00:00 UTC\n' > "$ZAPRET2_ROOT/config"
unset -f config_apply_from_default z2r_service_action backup_helper_ask_and_create
ok "лёгкий путь п.7: применение без скачивания и self-heal payload"

# --- 4d. standalone-подсказка лаунчера печатается только при новом эталоне ---
STANDALONE_OUT="$WORK/standalone.out"
( cd "$REPO_DIR" && ZATOR_ROOT="$ZATOR_ROOT" ZAPRET2_ROOT="$ZAPRET2_ROOT" bash -c '
    source lib/deploy.sh >/dev/null 2>&1
    deploy_apply_config_to_live' ) > "$STANDALONE_OUT" 2>&1
grep -q 'примените его к живому конфигу' "$STANDALONE_OUT" || fail "новый эталон: standalone-подсказка не напечатана"
printf '# Last modified: 2026-09-06 00:00:00 UTC\n' > "$ZAPRET2_ROOT/config"
( cd "$REPO_DIR" && ZATOR_ROOT="$ZATOR_ROOT" ZAPRET2_ROOT="$ZAPRET2_ROOT" bash -c '
    source lib/deploy.sh >/dev/null 2>&1
    deploy_apply_config_to_live' ) > "$STANDALONE_OUT" 2>&1
grep -q 'примените его к живому конфигу' "$STANDALONE_OUT" && fail "равные даты: standalone-подсказка напечатана зря"
ok "standalone-подсказка условна (только при новом эталоне)"

# --- 5. обновление webui-вариантом: слияние version.env ---

# подменяем даты в текущем version.env, чтобы увидеть слияние полей
sed -i 's/^ZATOR_DATE=.*/ZATOR_DATE="2000-01-01 00:00"/' "$ZATOR_ROOT/extra_strats/cache/deploy/version.env"
deploy_from_tar "$DIST/zator-webui.tar.gz" >/dev/null 2>&1 || fail "deploy_from_tar (webui) упал"
grep -q '^ZATOR_DATE="2000-01-01 00:00"$' "$ZATOR_ROOT/extra_strats/cache/deploy/version.env" || fail "webui-деплой затёр ZATOR_*"
grep -q "^WEBUI_VERSION=\"$expected_ver\"$" "$ZATOR_ROOT/extra_strats/cache/deploy/version.env" || fail "webui-деплой не обновил WEBUI_*"
[ -f "$ZATOR_ROOT/extra_strats/cache/deploy/manifest.webui.tsv" ] || fail "нет manifest.webui.tsv"
[ -f "$ZATOR_ROOT/extra_strats/cache/deploy/manifest.core.tsv" ] || fail "нет manifest.core.tsv"
grep -q '^webui/' "$ZATOR_ROOT/extra_strats/cache/deploy/manifest.webui.tsv" || fail "manifest.webui без webui-строк"
! grep -q '^webui/' "$ZATOR_ROOT/extra_strats/cache/deploy/manifest.core.tsv" || fail "manifest.core содержит webui-строки"
ok "слияние version.env по компонентам, манифесты по компонентам"

# --- 6. режим C: тесный /tmp, перестановка каталогов ---

# мок df с параметрами: TMP_FREE_KB/OPT_FREE_KB (по умолчанию тесный /tmp)
mkdir -p "$WORK/bin"
cat > "$WORK/bin/df" <<'EOF'
#!/bin/sh
hdr="Filesystem 1024-blocks Used Available Capacity Mounted"
case " $* " in
  *" /tmp "*) echo "$hdr"; echo "/dev/tmp 1000 900 ${TMP_FREE_KB:-100} 90% /tmp" ;;
  *) echo "$hdr"; echo "/dev/opt 1000000 900000 ${OPT_FREE_KB:-100000} 10% /opt" ;;
esac
EOF
chmod +x "$WORK/bin/df"

# A: просторный /tmp; C: /tmp тесный, /opt хватает на базу, но не на staging с архивом
DEPLOY_MODE=""
TMP_FREE_KB=100000 OPT_FREE_KB=100000 PATH="$WORK/bin:$PATH" deploy_space_mode_select 5000 3000 >/dev/null 2>&1 \
  && [ "$DEPLOY_MODE" = "A" ] || fail "режим не A при просторном /tmp ($DEPLOY_MODE)"
DEPLOY_MODE=""
TMP_FREE_KB=100 OPT_FREE_KB=13000 PATH="$WORK/bin:$PATH" deploy_space_mode_select 900 3000 >/dev/null 2>&1 \
  || fail "space_select упал на тесном /tmp"
[ "$DEPLOY_MODE" = "C" ] || fail "режим не C при тесном /tmp (получили $DEPLOY_MODE)"
DEPLOY_MODE=""
TMP_FREE_KB=100 OPT_FREE_KB=100000 PATH="$WORK/bin:$PATH" deploy_space_mode_select 900 3000 >/dev/null 2>&1 \
  && [ "$DEPLOY_MODE" = "B" ] || fail "режим не B при тесном /tmp и просторном /opt ($DEPLOY_MODE)"
ok "выбор режима A/B/C по df"

printf 'user-domain-2.example\n' > "$ZATOR_ROOT/lists/netrogat.txt"
TMP_FREE_KB=100 OPT_FREE_KB=13000 PATH="$WORK/bin:$PATH" deploy_from_tar "$DIST/zator-full.tar.gz" >/dev/null 2>&1 \
  || fail "deploy_from_tar (C) упал"
[ -f "$ZATOR_ROOT/z2r_lib/config.sh" ] || fail "режим C: z2r_lib не на месте"
[ ! -d "$ZATOR_ROOT.old.$$" ] || fail "старый каталог не убран"
[ ! -d "$ZATOR_ROOT.deploy.new.$$" ] || fail "новый каталог не перенесён"
grep -q 'user-domain-2.example' "$ZATOR_ROOT/lists/netrogat.txt" || fail "режим C: netrogat.txt перезаписан"
grep -q 'lock-runtime' "$ZATOR_ROOT/extra_strats/cache/orchestra/locked.tsv" || fail "режим C: locked.tsv не перенесён"
grep -q 'autohost-runtime' "$ZATOR_ROOT/lists/autohostlist.txt" || fail "режим C: autohostlist не перенесён"
ok "режим C: перестановка каталогов, переносы runtime и защит"

# --- 7. целостность ---

integrity_out="$(deploy_integrity_check 2>/dev/null)" || fail "integrity_check упал"
printf '%s\n' "$integrity_out" | grep -q 'отсутствует: ' && fail "integrity_check: есть отсутствующие файлы ($integrity_out)"
printf 'tampered\n' >> "$ZATOR_ROOT/lua/dns-clone.lua"
integrity_out="$(deploy_integrity_check 2>/dev/null)" || fail "integrity_check упал после изменения"
printf '%s\n' "$integrity_out" | grep -q 'lua/dns-clone.lua' || fail "integrity_check не заметил изменение"
ok "integrity_check замечает изменения"

# --- 8. сброс к эталону ---

# сначала получаем список изменённых (ответ 0 = отмена), выбираем номер TCP_Custom.txt
reset_list="$(deploy_reset_user_files "$DIST/zator-full.tar.gz" <<< "0" 2>/dev/null)" || fail "reset_user_files (список) упал"
custom_num="$(printf '%s\n' "$reset_list" | sed -n 's/^\([0-9]*\)\. extra_strats\/TCP_Custom.txt$/\1/p' | head -1)"
[ -n "$custom_num" ] || fail "TCP_Custom.txt не попал в список изменённых"

deploy_reset_user_files "$DIST/zator-full.tar.gz" <<< "all" >/dev/null 2>&1 || fail "reset_user_files (all) упал"
grep -q 'custom.example' "$ZATOR_ROOT/extra_strats/TCP_Custom.txt" && fail "TCP_Custom не сброшен к эталону (all)"
grep -q 'user-domain-2.example' "$ZATOR_ROOT/lists/netrogat.txt" && fail "netrogat не сброшен к эталону (all)"

printf 'user-domain-3.example\n' > "$ZATOR_ROOT/lists/netrogat.txt"
printf 'custom-2.example\n' > "$ZATOR_ROOT/extra_strats/TCP_Custom.txt"
deploy_reset_user_files "$DIST/zator-full.tar.gz" <<< "$custom_num" >/dev/null 2>&1 || fail "reset_user_files (выборочный) упал"
grep -q 'user-domain-3.example' "$ZATOR_ROOT/lists/netrogat.txt" || fail "выборочный reset тронул не выбранный файл"
grep -q 'custom-2.example' "$ZATOR_ROOT/extra_strats/TCP_Custom.txt" && fail "выбранный файл не сброшен"
ok "reset_user_files: all и выборочный"

# --- оффлайн-сборка: bundle (zator-full + zapret2) и установка без сети ---
OFFLINE_DIR="$WORK/offline"
mkdir -p "$OFFLINE_DIR/fake-z/zapret2-v1.0.5.1-reasm-fix"
printf '#!/bin/sh\n' > "$OFFLINE_DIR/fake-z/zapret2-v1.0.5.1-reasm-fix/install_bin.sh"
printf '#!/bin/sh\n' > "$OFFLINE_DIR/fake-z/zapret2-v1.0.5.1-reasm-fix/install_easy.sh"
tar -czf "$OFFLINE_DIR/zapret2-v1.0.5.1-reasm-fix.tar.gz" -C "$OFFLINE_DIR/fake-z" zapret2-v1.0.5.1-reasm-fix
tar -czf "$OFFLINE_DIR/zapret2-v1.0.5.1-reasm-fix-openwrt-embedded.tar.gz" -C "$OFFLINE_DIR/fake-z" zapret2-v1.0.5.1-reasm-fix
bash "$REPO_DIR/tools/build-offline-archive.sh" \
  --zator-tar "$DIST/zator-full.tar.gz" \
  --zapret2 "$OFFLINE_DIR/zapret2-v1.0.5.1-reasm-fix.tar.gz" \
  --zapret2-openwrt "$OFFLINE_DIR/zapret2-v1.0.5.1-reasm-fix-openwrt-embedded.tar.gz" \
  --version 1.0.5.1-reasm-fix \
  --project-dir "$REPO_DIR" \
  --output "$OFFLINE_DIR/zator-offline-test.tar.gz" >/dev/null || fail "сборка офлайн-бандла упала"
tar -tzf "$OFFLINE_DIR/zator-offline-test.tar.gz" | grep -q 'zator-full.tar.gz' || fail "в бандле нет zator-full.tar.gz"
tar -tzf "$OFFLINE_DIR/zator-offline-test.tar.gz" | grep -q 'README.txt' || fail "в бандле нет README.txt"
rm -rf "$OFFLINE_DIR/run" "$OFFLINE_DIR/optroot" "$OFFLINE_DIR/bin"
mkdir -p "$OFFLINE_DIR/run" "$OFFLINE_DIR/bin"
tar -xzf "$OFFLINE_DIR/zator-offline-test.tar.gz" -C "$OFFLINE_DIR/run"
Z2R_INSTALL_DIR="$OFFLINE_DIR/optroot" Z2R_BIN_PATH="$OFFLINE_DIR/bin/z2r" Z2R_NO_EXEC=1 \
  sh "$OFFLINE_DIR/run/zator-offline-1.0.5.1-reasm-fix/z2r" > "$OFFLINE_DIR/install.out" 2>&1 \
  || fail "офлайн-установка упала"
grep -q 'OFFLINE_READY version=1.0.5.1-reasm-fix' "$OFFLINE_DIR/install.out" || fail "нет OFFLINE_READY"
[ -f "$OFFLINE_DIR/optroot/z2r.sh" ] || fail "офлайн: нет z2r.sh"
[ -f "$OFFLINE_DIR/optroot/zator/z2r_lib/deploy.sh" ] || fail "офлайн: нет z2r_lib"
[ -f "$OFFLINE_DIR/optroot/zator/.deploy-payload/config.default" ] || fail "офлайн: нет payload config.default"
[ -f "$OFFLINE_DIR/optroot/zator/.deploy-payload/fake_files.tar.gz" ] || fail "офлайн: нет payload fake_files.tar.gz"
[ -f "$OFFLINE_DIR/optroot/zator/.deploy-payload/Entware/z2r-strategy-validator" ] || fail "офлайн: нет payload validator"
grep -q '^TRACKING="offline-1.0.5.1-reasm-fix"$' "$OFFLINE_DIR/optroot/zator/extra_strats/cache/deploy/version.env" || fail "офлайн: TRACKING не закреплён"
grep -q '^AUTOUPDATE=off$' "$OFFLINE_DIR/optroot/z2r.conf" || fail "офлайн: AUTOUPDATE не выключен"
[ -f "$OFFLINE_DIR/bin/z2r" ] || fail "офлайн: команда z2r не установлена"
ok "офлайн-сборка: bundle, установка, пин версии, AUTOUPDATE=off"

echo
echo "deploy tar smoke ok"
