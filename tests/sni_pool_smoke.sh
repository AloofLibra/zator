#!/usr/bin/env bash

# Тест SNI-пула с автосменой (sni_pool.tsv + sni_zator.txt/sni_user.txt +
# lua/sni-pool.lua): статический wiring (config.default, хук locked.lua,
# деплой z2r.sh, манифест pack-zator-tar, дефолтный пул, бэкап, меню 16,
# пин прогонов), отсутствие зашитых доменов в Lua, поведение шелл-хелперов
# (секции наборов, перекрытие проектных пользовательскими, валидация/дедуп/
# лимит/пин) и, при наличии lua-интерпретатора или fengari, живой прогон
# движка (ротация, липкость, приоритеты).
# Работает только во временной директории в /tmp: не пишет в /opt, не
# запускает настоящий zapret2.

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

TMP_DIR="$(mktemp -d /tmp/zator-sni-pool.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

ROOT="$TMP_DIR/zapret2"
export ORCH_DIR="$ROOT/extra_strats/cache/orchestra"
export ORCH_LOCK_FILE="$ORCH_DIR/locked.tsv"
export ZATOR_ROOT="$ROOT"
export ZAPRET2_ROOT="$ROOT"
export Z2R_SNI_ZATOR_FILE="$ROOT/extra_strats/sni_zator.txt"
export Z2R_SNI_USER_FILE="$ROOT/extra_strats/sni_user.txt"
mkdir -p "$ORCH_DIR" "$ROOT/extra_strats"

# --- 0. Синтаксис -----------------------------------------------------------

for f in lib/orchestra_state.sh lib/submenus.sh lib/strategies.sh \
  lib/supersweep.sh lib/actions.sh z2r.sh; do
  bash -n "$REPO_DIR/$f" || fail "bash -n: $f"
done

# --- 1. Статический wiring --------------------------------------------------

POOL_LUA_SRC="$(tr -d '\r' < "$REPO_DIR/lua/sni-pool.lua")"
LOCKED_LUA_SRC="$(tr -d '\r' < "$REPO_DIR/orchestra/locked.lua")"
Z2R_SRC="$(tr -d '\r' < "$REPO_DIR/z2r.sh")"
CONFIG_SRC="$(tr -d '\r' < "$REPO_DIR/config.default")"
STATE_SRC="$(tr -d '\r' < "$REPO_DIR/lib/orchestra_state.sh")"
SUBMENUS_SRC="$(tr -d '\r' < "$REPO_DIR/lib/submenus.sh")"
ACTIONS_SRC="$(tr -d '\r' < "$REPO_DIR/lib/actions.sh")"
STRATS_SRC="$(tr -d '\r' < "$REPO_DIR/lib/strategies.sh")"
SWEEP_SRC="$(tr -d '\r' < "$REPO_DIR/lib/supersweep.sh")"
PACK_SRC="$(tr -d '\r' < "$REPO_DIR/webui-src/scripts/pack-zator-tar.mjs")"

# 1a. Баннер авторства: атрибуция, офиц. репозиторий, GPL, DMCA, ИИ-разрешение
assert_contains "$POOL_LUA_SRC" 'АВТОРСКОЕ ПРАВО \(c\) 2026 Alexander Markin' \
  "sni-pool.lua: нет баннера авторства"
assert_contains "$POOL_LUA_SRC" 'https://github\.com/MarkinAlexander' \
  "sni-pool.lua: нет ссылки на GitHub автора"
assert_contains "$POOL_LUA_SRC" 'https://github\.com/AloofLibra/zator' \
  "sni-pool.lua: нет ссылки на официальный репозиторий zator"
assert_contains "$POOL_LUA_SRC" 'специально для проекта zator' \
  "sni-pool.lua: нет пометки «написан специально для проекта zator»"
assert_contains "$POOL_LUA_SRC" 'GNU GPL v3' "sni-pool.lua: нет ссылки на лицензию GPL v3"
assert_contains "$POOL_LUA_SRC" 'DMCA' "sni-pool.lua: нет предупреждения DMCA"
assert_contains "$POOL_LUA_SRC" 'MAY use, study and modify this file' \
  "sni-pool.lua: нет разрешения использования для ИИ-агентов"
assert_contains "$POOL_LUA_SRC" 'attribution fully preserved' \
  "sni-pool.lua: нет условия полного сохранения атрибуции"

# 1b. Движок: пути, липкость, ротация, пин с TTL; домены НЕ зашиты в Lua
assert_contains "$POOL_LUA_SRC" 'POOL_TSV = "/opt/zator/extra_strats/cache/orchestra/sni_pool\.tsv"' \
  "sni-pool.lua: не тот путь пула"
assert_contains "$POOL_LUA_SRC" 'POOL_POLICY = "/opt/zator/extra_strats/cache/orchestra/sni_pool_policy\.tsv"' \
  "sni-pool.lua: нет пути файла политик чередования"
assert_contains "$POOL_LUA_SRC" 'math\.random\(pool_size - 1\)' \
  "sni-pool.lua: нет случайного выбора без повторов подряд"
assert_contains "$POOL_LUA_SRC" 'SETS_PROJECT = "/opt/zator/extra_strats/sni_zator\.txt"' \
  "sni-pool.lua: не тот путь проектных наборов"
assert_contains "$POOL_LUA_SRC" 'SETS_USER = "/opt/zator/extra_strats/sni_user\.txt"' \
  "sni-pool.lua: не тот путь пользовательских наборов"
assert_contains "$POOL_LUA_SRC" 'sni_pool\.pin' "sni-pool.lua: нет пина прогонов"
assert_contains "$POOL_LUA_SRC" 'PIN_AGE' "sni-pool.lua: нет TTL пина"
assert_contains "$POOL_LUA_SRC" 'track\.lua_state' "sni-pool.lua: нет липкости на соединение"
assert_contains "$POOL_LUA_SRC" 'rr\[' "sni-pool.lua: нет round-robin счётчика"
assert_contains "$POOL_LUA_SRC" 'function z2r_sni_pool_for_tests' "sni-pool.lua: нет тестового хука"
assert_contains "$POOL_LUA_SRC" 'match\("\^#%s\*set:' "sni-pool.lua: нет парсера секций «# set:»"
assert_contains "$POOL_LUA_SRC" 'parse_sets\(SETS_USER' \
  "sni-pool.lua: пользовательские наборы не перекрывают проектные"
for d in www.google.com developers.google.com codelabs.developers.google.com \
  www.gstatic.com accounts.google.com fonts.gstatic.com google.com \
  lh3.google.com fonts.googleapis.com; do
  if grep -qF "\"$d\"" "$REPO_DIR/lua/sni-pool.lua" || grep -qF "'$d'" "$REPO_DIR/lua/sni-pool.lua"; then
    fail "sni-pool.lua: домен $d зашит в коде (должен жить в sni_zator.txt)"
  fi
done
# комментарии в теле запрещены: после баннера не осталось строк-комментариев
[ "$(awk 'NR>27 && /^--/{c++} END{print c+0}' "$REPO_DIR/lua/sni-pool.lua")" -eq 0 ] \
  || fail "sni-pool.lua: в теле файла остались комментарии (разрешена только шапка)"

# 1c. Хук locked.lua: охраняемый, приоритет sni_override выше
assert_contains "$LOCKED_LUA_SRC" 'type\(z2r_sni_pool_pick\) == "function"' \
  "locked.lua: хук пула не охранён проверкой типа"
assert_contains "$LOCKED_LUA_SRC" 'sni == nil and type\(z2r_sni_pool_pick\) == "function"' \
  "locked.lua: пул не уступает приоритет явному sni_override"
assert_contains "$LOCKED_LUA_SRC" 'z2r_sni_pool_pick\(desync, profile_key\)' \
  "locked.lua: хук не передаёт desync/profile_key"

# 1d. config.default: строка lua-init ровно одна, после locked.lua
assert_contains "$CONFIG_SRC" '^--lua-init=@/opt/zator/lua/sni-pool\.lua$' \
  "config.default не подключает sni-pool.lua"
[ "$(grep -c '^--lua-init=@/opt/zator/lua/sni-pool.lua$' "$REPO_DIR/config.default")" -eq 1 ] \
  || fail "config.default: lua-init sni-pool.lua дублирован"
locked_line="$(grep -n '^--lua-init=@/opt/zator/lua/locked.lua$' "$REPO_DIR/config.default" | head -n1 | cut -d: -f1)"
pool_line="$(grep -n '^--lua-init=@/opt/zator/lua/sni-pool.lua$' "$REPO_DIR/config.default" | head -n1 | cut -d: -f1)"
[ -n "$locked_line" ] && [ -n "$pool_line" ] && [ "$pool_line" -gt "$locked_line" ] \
  || fail "config.default: sni-pool.lua подключается до locked.lua"

# 1e. z2r.sh: переменная, докачка, миграция, наборы, дефолтный пул
assert_contains "$Z2R_SRC" 'SNI_POOL_LUA="\$ZATOR_ROOT/lua/sni-pool\.lua"' \
  "z2r.sh нет переменной SNI_POOL_LUA"
assert_contains "$Z2R_SRC" 'z2r_download_project_file "\$SNI_POOL_LUA" "lua/sni-pool\.lua"' \
  "z2r.sh не докачивает sni-pool.lua"
assert_contains "$Z2R_SRC" 'locked\.lua sni-pool\.lua rst-guard\.lua' \
  "миграция z2r.sh не переносит sni-pool.lua"
assert_contains "$Z2R_SRC" 's#/opt/zapret2/lua/sni-pool\.lua#/opt/zator/lua/sni-pool\.lua#g' \
  "миграция z2r.sh не переписывает путь sni-pool.lua"
assert_contains "$Z2R_SRC" '\[ ! -s "\$SNI_POOL_LUA" \]' \
  "z2r.sh не докачивает sni-pool.lua при отсутствии"
assert_contains "$Z2R_SRC" 'z2r_download_project_file "\$ZATOR_ROOT/extra_strats/sni_zator\.txt" \\' \
  "z2r.sh не обновляет проектный файл наборов"
assert_contains "$Z2R_SRC" 'if \[ ! -f "\$ZATOR_ROOT/extra_strats/sni_user\.txt" \]' \
  "z2r.sh перезаписывает пользовательский файл наборов"
assert_contains "$Z2R_SRC" "printf '1\\\\t@google\\\\n2\\\\t@google\\\\n'" \
  "z2r.sh не создаёт дефолтный sni_pool.tsv"
assert_contains "$Z2R_SRC" 'if \[ ! -f "\$ORCH_DIR/sni_pool\.tsv" \]' \
  "дефолтный пул создаётся не только при отсутствии файла"
if grep -q 'sni_sets' "$REPO_DIR/z2r.sh" "$REPO_DIR/lib/orchestra_state.sh" \
  "$REPO_DIR/lib/actions.sh" "$REPO_DIR/webui-src/scripts/pack-zator-tar.mjs"; then
  fail "остались ссылки на старую модель каталога sni_sets/"
fi

# 1f. Репо-файлы наборов: формат секций, google 9 имён, rkn непустой
[ -f "$REPO_DIR/extra_strats/sni_zator.txt" ] || fail "нет extra_strats/sni_zator.txt"
[ -f "$REPO_DIR/extra_strats/sni_user.txt" ] || fail "нет extra_strats/sni_user.txt"
assert_contains "$(tr -d '\r' < "$REPO_DIR/extra_strats/sni_zator.txt")" '^# set: google$' \
  "sni_zator.txt: нет секции google"
assert_contains "$(tr -d '\r' < "$REPO_DIR/extra_strats/sni_zator.txt")" '^# set: rkn$' \
  "sni_zator.txt: нет секции rkn"
g_n="$(awk '/^# set: google/{f=1;next} /^# set:/{f=0} f&&NF&&!/^#/' "$REPO_DIR/extra_strats/sni_zator.txt" | wc -l)"
[ "$g_n" -eq 9 ] || fail "sni_zator.txt: секция google не 9 доменов ($g_n)"
r_n="$(awk '/^# set: rkn/{f=1;next} /^# set:/{f=0} f&&NF&&!/^#/' "$REPO_DIR/extra_strats/sni_zator.txt" | wc -l)"
[ "$r_n" -ge 1 ] || fail "sni_zator.txt: секция rkn пуста"

# 1g. Манифест релизов: пользовательский файл не перезаписывается
assert_contains "$PACK_SRC" "'extra_strats/sni_user\.txt', // пользовательские" \
  "pack-zator-tar.mjs: sni_user.txt не в KEEP_IF_EXISTS"

# 1h. Шелл-хелперы, бэкап, меню, пин прогонов
assert_contains "$STATE_SRC" 'ORCH_SNI_POOL_FILE="\$\{ORCH_SNI_POOL_FILE:-\$ORCH_DIR/sni_pool\.tsv\}"' \
  "orchestra_state.sh нет переменной файла пула"
for fn in sni_pool_set_name_valid sni_pool_sets_list sni_pool_set_origin \
  sni_pool_set_read sni_pool_set_write sni_pool_set_delete sni_pool_list \
  sni_pool_effective sni_pool_assign_set sni_pool_set_list sni_pool_clear \
  sni_pool_pin sni_pool_unpin sni_pool_pinned sni_pool_display \
  sni_pool_policy_get sni_pool_policy_set sni_pool_policy_valid \
  sni_pool_policy_label sni_pool_supported_profiles; do
  assert_contains "$STATE_SRC" "^${fn}\(\)" "orchestra_state.sh нет функции $fn"
done
assert_contains "$STATE_SRC" 'sni_override_valid "\$d" \|\| return 2' \
  "sni_pool_* валидирует не как sni_override"
assert_contains "$ACTIONS_SRC" 'extra_strats/cache/orchestra/sni_pool\.tsv' \
  "z2r_backup_state_files не бэкапит sni_pool.tsv"
assert_contains "$ACTIONS_SRC" 'extra_strats/cache/orchestra/sni_pool_policy\.tsv' \
  "z2r_backup_state_files не бэкапит sni_pool_policy.tsv"
assert_contains "$SUBMENUS_SRC" 'Чередование:' "меню пула не предлагает смену политики"
assert_contains "$ACTIONS_SRC" 'extra_strats/sni_user\.txt' \
  "z2r_backup_state_files не бэкапит файл пользовательских наборов"
assert_contains "$SUBMENUS_SRC" 'SNI-пул — наборы невинных имён с автосменой' \
  "меню 16 не содержит пункт SNI-пул"
assert_contains "$SUBMENUS_SRC" 'sni_pool_item' "меню 16 не диспатчит SNI-пул"
assert_contains "$SUBMENUS_SRC" '^sni_pool_profile_pick\(\)' "нет экрана профиля SNI-пула"
assert_contains "$SUBMENUS_SRC" '^sni_pool_sets_submenu\(\)' "нет экрана управления наборами"
assert_contains "$SUBMENUS_SRC" '^sni_pool_sets_view\(\)' "нет экрана просмотра проектного набора"
assert_contains "$SUBMENUS_SRC" 'Наборы SNI — создание/правка/удаление' \
  "список профилей пула не ведёт в управление наборами"
assert_contains "$SUBMENUS_SRC" 'sni_pool_effective "\$1"' \
  "fake_mode_sni_display не показывает пул"
assert_contains "$STRATS_SRC" 'sni_pool_pin' "автопрогон не пинит SNI-пул"
assert_contains "$STRATS_SRC" 'sni_pool_unpin' "автопрогон не снимает пин пула"
assert_contains "$SWEEP_SRC" 'sni_pool_pin' "суперавтопрогон не пинит SNI-пул"
assert_contains "$SWEEP_SRC" 'type sni_pool_unpin' \
  "cleanup суперавтопрогона не снимает пин безусловно"

# --- 2. Поведение шелл-хелперов (настоящий sni_zator.txt из репо) ----------

# shellcheck source=/dev/null
source "$REPO_DIR/lib/config.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/orchestra_state.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/ui.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/actions.sh"

tr -d '\r' < "$REPO_DIR/extra_strats/sni_zator.txt" > "$Z2R_SNI_ZATOR_FILE"
tr -d '\r' < "$REPO_DIR/extra_strats/sni_user.txt" > "$Z2R_SNI_USER_FILE"

# чтение проектных секций настоящего файла; origin
[ "$(sni_pool_set_read google | wc -l)" -eq 9 ] || fail "проектная секция google читается неверно"
[ "$(sni_pool_set_read rkn | wc -l)" -ge 1 ] || fail "проектная секция rkn читается неверно"
[ "$(sni_pool_set_origin google)" = "zator" ] || fail "origin(google) != zator"
[ -z "$(sni_pool_set_origin nosuch)" ] || fail "origin(nosuch) не пуст"
sni_pool_sets_list | grep -qx 'google' || fail "sets_list не видит проектный google"
sni_pool_sets_list | grep -qx 'rkn' || fail "sets_list не видит проектный rkn"

# свой набор: пишется секцией в sni_user.txt, читается, origin=user
sni_pool_set_write my www.Example.COM b.example.org www.example.com
[ "$(sni_pool_set_read my | tr '\n' ' ')" = "www.example.com b.example.org " ] \
  || fail "sni_pool_set_write/read: нормализация или дедуп сломаны"
[ "$(sni_pool_set_origin my)" = "user" ] || fail "origin(my) != user"
grep -q '^# set: my$' "$Z2R_SNI_USER_FILE" || fail "секция не записана в sni_user.txt"
if sni_pool_set_write "Bad Name" x.example.org; then fail "sni_pool_set_write принял плохое имя"; fi
if sni_pool_set_write ok "bad domain!"; then fail "sni_pool_set_write принял мусорный домен"; fi

# одноимённый пользовательский набор перекрывает проектный
sni_pool_set_write google g1.example.org g2.example.org
[ "$(sni_pool_set_read google | tr '\n' ' ')" = "g1.example.org g2.example.org " ] \
  || fail "пользовательский набор не перекрывает проектный"
sni_pool_set_delete google || fail "не удалился пользовательский google"
[ "$(sni_pool_set_read google | wc -l)" -eq 9 ] || fail "проектный google не восстановился после снятия перекрытия"

# удаление: проектный нельзя, занятый @ссылкой нельзя
if sni_pool_set_delete rkn; then fail "удалился проектный набор rkn"; fi
sni_pool_assign_set 3 my
if sni_pool_set_delete my; then fail "удалился набор, на который ссылается профиль 3"; fi

# замена существующей секции на месте: заголовок файла и соседние секции целы
sni_pool_set_write my x.example.org y.example.org z.example.org
[ "$(sni_pool_set_read my | tr '\n' ' ')" = "x.example.org y.example.org z.example.org " ] \
  || fail "замена секции сломана"
grep -q 'Ваши SNI-наборы' "$Z2R_SNI_USER_FILE" || fail "замена секции снесла заголовок файла"
[ "$(grep -c '^# set: ' "$Z2R_SNI_USER_FILE")" -eq 1 ] \
  || fail "замена секции размножила секции"

# назначение набора профилю: @ссылка, effective разворачивает
[ "$(sni_pool_list 3)" = "@my" ] || fail "assign_set не записал @ссылку"
[ "$(sni_pool_effective 3 | head -n1)" = "x.example.org" ] \
  || fail "effective не разворачивает @ссылку"
sni_pool_display 3 | grep -q 'набор my (3' || fail "display не показывает набор"

# свой список: полная замена, порядок, @домены запрещены
sni_pool_set_list 3 c.example.org a.example.org c.example.org
[ "$(sni_pool_list 3 | tr '\n' ' ')" = "c.example.org a.example.org " ] \
  || fail "свой список: порядок/дедуп сломаны"
sni_pool_display 3 | grep -q 'свой список (2' || fail "display не показывает свой список"
if sni_pool_set_list 3 "@my"; then fail "sni_pool_set_list принял @ссылку"; fi

# комбинированный пул: @набор + свои строки (эффективный = набор + свои)
{
  printf '4\t@my\n4\tzz.example.org\n'
} >> "$ORCH_SNI_POOL_FILE"
[ "$(sni_pool_effective 4 | tr '\n' ' ')" = "x.example.org y.example.org z.example.org zz.example.org " ] \
  || fail "комбинированный пул (набор+свои) не собирается"
sni_pool_display 4 | grep -q 'набор my + свои (4' || fail "display не показывает набор+свои"

# регистр @ссылки: имя набора приводится к нижнему (как в lua/sni-pool.lua)
printf '5\t@MY\r\n' >> "$ORCH_SNI_POOL_FILE"
[ "$(sni_pool_effective 5 | head -n1)" = "x.example.org" ] \
  || fail "@ссылка с регистром/CRLF не разрешается"

# clear убирает только свой профиль; файл остаётся (держит дефолт z2r.sh)
printf '# комментарий\n' > "$ORCH_SNI_POOL_FILE"
sni_pool_set_list 5 solo.example.net
grep -q '# комментарий' "$ORCH_SNI_POOL_FILE" || fail "set_list снёс комментарий"
sni_pool_clear 5
[ -z "$(sni_pool_list 5)" ] || fail "clear не убрал профиль 5"
[ -f "$ORCH_SNI_POOL_FILE" ] || fail "clear удалил файл пула (дефолт вернётся)"
sni_pool_display 5 | grep -q 'нет пула' || fail "display не показывает отсутствие пула"

# лимит 32 (секция и свой список)
big=()
for i in $(seq 1 33); do big+=("d$i.example.org"); done
if sni_pool_set_list 5 "${big[@]}"; then fail "sni_pool_set_list принял 33 имени"; fi
if sni_pool_set_write big "${big[@]}"; then fail "sni_pool_set_write принял 33 имени"; fi

# пин: числовая метка, pinned, снятие
sni_pool_pin
sni_pool_pinned || fail "sni_pool_pinned не видит свежий пин"
grep -Eq '^[0-9]+$' "$ORCH_SNI_POOL_PIN" || fail "пин не числовая метка времени"
sni_pool_unpin
! sni_pool_pinned || fail "unpin не снял пин"

# политика чередования: дефолт пуст (rr), валидация, метки, display
[ -z "$(sni_pool_policy_get 1)" ] || fail "политика без файла не пуста"
[ "$(sni_pool_policy_label "")" = "по кругу" ] || fail "label(rr) неверен"
sni_pool_policy_set 1 rand
[ "$(sni_pool_policy_get 1)" = "rand" ] || fail "policy_set(rand) не записался"
[ "$(sni_pool_policy_label "$(sni_pool_policy_get 1)")" = "случайно" ] || fail "label(rand) неверен"
sni_pool_assign_set 1 google
sni_pool_display 1 | grep -q 'случайно' || fail "display не показывает политику"
sni_pool_clear 1
if sni_pool_policy_set 1 "bad"; then fail "policy_set принял мусор"; fi
sni_pool_policy_set 1 rr
[ "$(sni_pool_policy_get 1)" = "rr" ] || fail "policy_set(rr) не записался"

# бэкап-лист: файл пула и пользовательские наборы
z2r_backup_state_files 2>/dev/null | grep -q 'extra_strats/cache/orchestra/sni_pool.tsv' \
  || fail "z2r_backup_state_files не бэкапит sni_pool.tsv"
z2r_backup_state_files 2>/dev/null | grep -q 'extra_strats/sni_user.txt' \
  || fail "z2r_backup_state_files не бэкапит sni_user.txt"

# --- 3. Живой прогон Lua-движка (нативный lua или fengari-VM на node) -------

cat > "$TMP_DIR/pool_body.lua" <<'LUAEOF'
DLOG = function() end
local function ok(cond, msg)
  if not cond then error("sni-pool lua: " .. msg, 0) end
end
local function fresh() return { track = { lua_state = {} } } end
local G = { "g1.example.org", "g2.example.org", "g3.example.org" }
local sets = { google = G }

-- без строк профиля пула нет
z2r_sni_pool_for_tests({}, sets, false)
ok(z2r_sni_pool_pick(fresh(), "1") == nil, "нет строк -> не nil")

-- @набор: ротация по набору, липкость в соединении
z2r_sni_pool_for_tests({ "1\t@google" }, sets, false)
local t1 = fresh()
ok(z2r_sni_pool_pick(t1, "1") == G[1], "первый выбор != первый SNI набора")
ok(z2r_sni_pool_pick(t1, "1") == G[1], "липкость: тот же трек сменил SNI")
local t2 = fresh()
ok(z2r_sni_pool_pick(t2, "1") == G[2], "второе соединение != второй SNI")
local seen = {}
for i = 3, 7 do
  local t = fresh()
  seen[#seen + 1] = z2r_sni_pool_pick(t, "1")
end
for i = 1, 5 do
  ok(seen[i] == G[((i + 1) % 3) + 1], "ротация сбилась на шаге " .. i)
end

-- @набор + свои строки: набор, затем свои
z2r_sni_pool_for_tests({ "2\t@google", "2\tmy.example.org" }, sets, false)
local pool2 = {}
for i = 1, 8 do
  local t = fresh()
  pool2[#pool2 + 1] = z2r_sni_pool_pick(t, "2")
end
ok(pool2[1] == G[1] and pool2[4] == "my.example.org" and pool2[5] == G[1],
  "комбо набор+свои собирается неверно")

-- строки файла: валидация, дедуп, регистр, CRLF, комментарии
z2r_sni_pool_for_tests({
  "# comment", "",
  "3\ta.example.org", "3\tA.example.org", "3\tb.example.org\r",
  "3\tbad domain", "3\t",
}, sets, false)
local p = fresh()
ok(z2r_sni_pool_pick(p, "3") == "a.example.org", "первый SNI файла неверен")
ok(z2r_sni_pool_pick(p, "3") == "a.example.org", "липкость файла нарушилась")
local p2 = fresh()
ok(z2r_sni_pool_pick(p2, "3") == "b.example.org", "дедуп/CRLF: второй SNI неверен")

-- @ссылка на несуществующий набор -> пула нет
z2r_sni_pool_for_tests({ "3\t@nosuch" }, sets, false)
ok(z2r_sni_pool_pick(fresh(), "3") == nil, "несуществующий набор дал не nil")

-- одиночный пул: без ротации
z2r_sni_pool_for_tests({ "4\tsolo.example.org" }, sets, false)
ok(z2r_sni_pool_pick(fresh(), "4") == "solo.example.org", "одиночный пул неверен")

-- пин: всегда первый SNI пула
z2r_sni_pool_for_tests({ "1\t@google" }, sets, true)
ok(z2r_sni_pool_pick(fresh(), "1") == G[1], "пин не зафиксировал первый SNI")
ok(z2r_sni_pool_pick(fresh(), "1") == G[1], "пин пропустил ротацию")

-- политика rand: случайно, без двух одинаковых подряд
local R = {}
for i = 1, 5 do R[i] = "r" .. i .. ".example.org" end
local rlines = {}
for i = 1, 5 do rlines[i] = "6\t" .. R[i] end
z2r_sni_pool_for_tests(rlines, sets, false, { ["6"] = "rand" })
local prev
for i = 1, 40 do
  local t = fresh()
  local v = z2r_sni_pool_pick(t, "6")
  ok(v ~= nil, "rand: pick вернул nil")
  ok(prev == nil or v ~= prev, "rand: два одинаковых подряд (" .. tostring(v) .. ")")
  local known = false
  for _, x in ipairs(R) do if x == v then known = true end end
  ok(known, "rand: pick вне пула: " .. tostring(v))
  prev = v
end
-- rr-политика по умолчанию: строгий порядок
z2r_sni_pool_for_tests(rlines, sets, false, nil)
local seq = {}
for i = 1, 7 do
  local t = fresh()
  seq[i] = z2r_sni_pool_pick(t, "6")
end
for i = 1, 7 do
  ok(seq[i] == R[((i - 1) % 5) + 1], "rr: порядок сбился на шаге " .. i)
end

-- лимит 32 на стороне Lua
local many = {}
for i = 1, 34 do many[#many + 1] = "5\td" .. i .. ".example.org" end
z2r_sni_pool_for_tests(many, sets, false)
local cnt, names = 0, {}
for i = 1, 60 do
  local t = fresh()
  local v = z2r_sni_pool_pick(t, "5")
  if v and not names[v] then names[v] = true; cnt = cnt + 1 end
end
ok(cnt == 32, "лимит 32 не соблюдён: " .. cnt)
print("lua ok")
LUAEOF

LUA_BIN=""
for c in lua5.1 lua5.2 lua5.3 lua5.4 lua luajit; do
  command -v "$c" >/dev/null 2>&1 && { LUA_BIN="$c"; break; }
done

if [ -n "$LUA_BIN" ]; then
  { printf 'dofile("lua/sni-pool.lua")\n'; cat "$TMP_DIR/pool_body.lua"; } > "$TMP_DIR/pool_driver.lua"
  ( cd "$REPO_DIR" && "$LUA_BIN" "$TMP_DIR/pool_driver.lua" ) >/dev/null \
    || fail "живой прогон lua/sni-pool.lua провалился (см. вывод выше)"
elif command -v node >/dev/null 2>&1 \
  && ( cd "$REPO_DIR" && node -e "require('fengari')" >/dev/null 2>&1 ); then
  # fengari — Lua VM на чистом JS (резолвится через NODE_PATH или локальный
  # node_modules); драйвер идёт через тестовый хук, io не нужен
  cat > "$TMP_DIR/pool_run.js" <<'JSEOF'
const fengari = require('fengari');
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
const L = fengari.lauxlib.luaL_newstate();
fengari.lualib.luaL_openlibs(L);
const code = fengari.lauxlib.luaL_dostring(L, fengari.to_luastring(src));
if (code !== fengari.lua.LUA_OK) {
  console.error('LUA FAIL:', fengari.to_jsstring(fengari.lauxlib.lua_tolstring(L, -1)));
  process.exit(1);
}
JSEOF
  cat "$REPO_DIR/lua/sni-pool.lua" "$TMP_DIR/pool_body.lua" > "$TMP_DIR/pool_combined.lua"
  ( cd "$REPO_DIR" && node "$TMP_DIR/pool_run.js" "$TMP_DIR/pool_combined.lua" ) >/dev/null \
    || fail "живой прогон lua/sni-pool.lua (fengari) провалился (см. вывод выше)"
else
  echo "SKIP: lua-интерпретатор и fengari не найдены — живой прогон sni-pool.lua пропущен"
fi

echo "sni pool smoke ok"
