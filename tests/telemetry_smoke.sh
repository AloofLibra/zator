#!/usr/bin/env bash
#
# Smoke-тест промпта телеметрии (init_telemetry в lib/telemetry.sh):
# Enter (пустой ввод) = согласие, отключение — только явное n/N/нет.
#
# Покрывает:
#   1. Ответы на промпт: пустая строка (Enter), y/Y, мусор — статистика
#      включается; n/N/no/нет — отключается.
#   2. При включении: конфиг tel_enabled=1, UUID сгенерирован, первичная
#      отправка выполнена один раз, при повторном запуске не дублируется.
#   3. При отказе: tel_enabled=0, отправки нет.
#   4. Существующий конфиг не переспрашивает: tel_enabled=0 остаётся 0,
#      tel_enabled=1 с актуальным каналом не отправляет повторно.
#
# ИЗОЛЯЦИЯ:
#   • Всё во временной папке /tmp (trap EXIT); пути CACHE_DIR/TELEMETRY_CFG/
#     PROVIDER_TXT переопределяются на временные ПОСЛЕ source (функции
#     читают их в момент вызова), реальный /opt не затрагивается.
#   • send_stats подменён логирующим моком — сеть не используется.
#   • sleep подменён no-op — тест мгновенный.
#
# Возврат: 0 — успех, 1 — любая ошибка (с сообщением "FAIL: ...").
# Запуск:  bash tests/telemetry_smoke.sh

# Намеренно БЕЗ `set -e`: init_telemetry может возвращать ненулевой код.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PASS=0
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ok() {
  printf '  [PASS] %s\n' "$1"
  PASS=$((PASS + 1))
}

TMP_DIR="$(mktemp -d /tmp/zator-telemetry-smoke.XXXXXX 2>/dev/null || fail "mktemp failed")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

plain=""; green=""; red=""; yellow=""

# shellcheck source=/dev/null
. "$REPO_DIR/lib/telemetry.sh"

# Переопределяем пути на временные (функции читают глобалы при вызове).
CACHE_DIR="$TMP_DIR/cache"
TELEMETRY_CFG="$TMP_DIR/telemetry.config"
PROVIDER_TXT="$CACHE_DIR/provider.txt"

# Моки: сеть и паузы.
SEND_LOG="$TMP_DIR/send.log"
: > "$SEND_LOG"
send_stats() {
  echo "sent" >> "$SEND_LOG"
  return 0
}
sleep() { :; }

bash -n "$REPO_DIR/lib/telemetry.sh" || fail "bash -n failed for lib/telemetry.sh"

tel_config_value() {
  sed -n 's/^tel_enabled=//p' "$TELEMETRY_CFG"
}

tel_uuid_value() {
  sed -n 's/^tel_uuid=//p' "$TELEMETRY_CFG"
}

# Прогон init_telemetry с заранее заданным ответом на промпт.
run_init() {
  printf '%s\n' "$1" | init_telemetry 2>&1
}

# ===========================================================================
# 1. Ответы на промпт: дефолт — согласие
# ===========================================================================
echo "== 1. Дефолт промпта: Enter = да =="

expect_enabled() {
  local answer="$1"
  rm -f "$TELEMETRY_CFG"; : > "$SEND_LOG"
  local out
  out="$(run_init "$answer")"
  [ "$(tel_config_value)" = "1" ] \
    || fail "ответ '$answer': статистика должна включаться (tel_enabled=$(tel_config_value))"
  printf '%s\n' "$out" | grep -q 'Статистика включена' \
    || fail "ответ '$answer': нет сообщения о включении"
}

expect_disabled() {
  local answer="$1"
  rm -f "$TELEMETRY_CFG"; : > "$SEND_LOG"
  local out
  out="$(run_init "$answer")"
  [ "$(tel_config_value)" = "0" ] \
    || fail "ответ '$answer': статистика должна отключаться (tel_enabled=$(tel_config_value))"
  printf '%s\n' "$out" | grep -q 'Статистика отключена' \
    || fail "ответ '$answer': нет сообщения об отключении"
  [ ! -s "$SEND_LOG" ] || fail "ответ '$answer': отправка при отключённой статистике"
}

expect_enabled ""      # Enter — главный кейс: пропустившие вопрос
expect_enabled "y"
expect_enabled "Y"
expect_enabled "yes"
expect_enabled "да"
expect_disabled "n"
expect_disabled "N"
expect_disabled "no"
expect_disabled "нет"
ok "Enter/y/да — включено; n/no/нет — отключено"

# ===========================================================================
# 2. Включение: UUID, однократная первичная отправка
# ===========================================================================
echo "== 2. UUID и однократная отправка =="
rm -f "$TELEMETRY_CFG"; : > "$SEND_LOG"
run_init "" >/dev/null
[ -n "$(tel_uuid_value)" ] || fail "UUID не сгенерирован при включении"
[ "$(wc -l < "$SEND_LOG")" -eq 1 ] \
  || fail "ожидалась ровно одна первичная отправка (было: $(wc -l < "$SEND_LOG"))"

# Повторный запуск: конфиг полный, канал актуален — отправки быть не должно.
run_init "" >/dev/null
[ "$(wc -l < "$SEND_LOG")" -eq 1 ] || fail "повторный запуск вызвал лишнюю отправку"
ok "UUID сгенерирован, первичная отправка ровно одна, повторов нет"

# ===========================================================================
# 3. Существующий конфиг не переспрашивает
# ===========================================================================
echo "== 3. Существующий конфиг не переспрашивает =="
mkdir -p "$CACHE_DIR"
printf 'tel_enabled=0\ntel_uuid=\n' > "$TELEMETRY_CFG"
: > "$SEND_LOG"
out="$(run_init "y")"   # ответ игнорируется — промпта быть не должно
[ "$(tel_config_value)" = "0" ] || fail "существующий отказ был перезаписан"
if printf '%s\n' "$out" | grep -q 'Разрешить?'; then
  fail "промпт показан при уже заданном tel_enabled"
fi
[ ! -s "$SEND_LOG" ] || fail "отправка при tel_enabled=0"

printf 'tel_enabled=1\ntel_uuid=abcd1234\ntel_channel_id=%s\n' "$STATS_CHANNEL_ID" > "$TELEMETRY_CFG"
out="$(run_init "n")"
if printf '%s\n' "$out" | grep -q 'Разрешить?'; then
  fail "промпт показан при уже заданном tel_enabled=1"
fi
[ ! -s "$SEND_LOG" ] || fail "лишняя отправка при актуальном канале"
ok "готовый конфиг не переспрашивает и не меняет решение"

echo ""
echo "============================="
printf 'telemetry smoke ok (assertions: %d)\n' "$PASS"
