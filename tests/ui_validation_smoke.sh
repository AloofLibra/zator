#!/usr/bin/env bash
#
# Smoke-тест общих функций валидации ввода.
#
# Покрывает:
#   • ui_is_number_in_range()  — из lib/ui.sh (граничные значения: вхождение в
#     диапазон, ниже/выше границы, не-число, пустая строка, отрицательные,
#     лидирующие нули, дробные, очень большие числа).
#   • ports_validate()         — из lib/actions.sh (одиночный порт, диапазон,
#     0, 65535, 65536, перевёрнутый диапазон, двойной дефис, буквы, пусто).
#   • ui_invalid_input()       — из lib/ui.sh (должна отрабатывать без ошибок).
#
# ИЗОЛЯЦИЯ: тест не создаёт файлов в /opt и не трогает config. Все проверки
# работают с аргументами функций в памяти. Временных директорий не требуется.
#
# Возврат: 0 — успех, 1 — любая ошибка (с сообщением "FAIL: ...").
# Запуск:  bash tests/ui_validation_smoke.sh

# Намеренно БЕЗ `set -e`: тестируемые функции возвращают ненулевой код для
# невалидного ввода — это и есть предмет проверки.

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

# --- Заглушки глобалей, нужных только при source lib/*.sh ---
plain=""; cyan=""; green=""; red=""; yellow=""
Fcyan=""; Fyellow=""
ZAPRET2_INIT="/bin/true"
hardware="vps"

# shellcheck source=/dev/null
. "$REPO_DIR/lib/config.sh"
# shellcheck source=/dev/null
. "$REPO_DIR/lib/ui.sh"
# shellcheck source=/dev/null
. "$REPO_DIR/lib/actions.sh"

# Синтаксис библиотек не должен быть сломан.
for f in "$REPO_DIR/lib/ui.sh" "$REPO_DIR/lib/actions.sh" "$REPO_DIR/lib/config.sh"; do
  bash -n "$f" || fail "bash -n failed for $f"
done

# Проверка наличия тестируемых функций.
type ui_is_number_in_range >/dev/null 2>&1 || fail "ui_is_number_in_range не определена"
type ports_validate        >/dev/null 2>&1 || fail "ports_validate не определена"
type ui_invalid_input      >/dev/null 2>&1 || fail "ui_invalid_input не определена"

# ===========================================================================
# 1. ui_is_number_in_range — граничные значения
# ===========================================================================
echo "== 1. ui_is_number_in_range (границы) =="

# Хелпер: ожидаем успех (rc=0).
expect_in_range() {
  local val="$1" lo="$2" hi="$3" label="$4"
  if ui_is_number_in_range "$val" "$lo" "$hi"; then
    ok "$label: '$val' в [$lo..$hi] → принят"
  else
    fail "$label: '$val' должен быть в [$lo..$hi], но отклонён"
  fi
}
# Хелпер: ожидаем отказ (rc!=0).
expect_out_of_range() {
  local val="$1" lo="$2" hi="$3" label="$4"
  if ui_is_number_in_range "$val" "$lo" "$hi"; then
    fail "$label: '$val' должен быть отклонён для [$lo..$hi], но принят"
  else
    ok "$label: '$val' в [$lo..$hi] → отклонён"
  fi
}

expect_in_range   5    1 10 "середина"
expect_in_range   1    1 10 "нижняя граница"
expect_in_range   10   1 10 "верхняя граница"
expect_out_of_range 0    1 10 "ниже нижней границы"
expect_out_of_range 11   1 10 "выше верхней границы"
expect_out_of_range -1   1 10 "отрицательное"
expect_out_of_range abc  1 10 "не-число (буквы)"
expect_out_of_range ""   1 10 "пустая строка"
expect_out_of_range "5 " 1 10 "число с пробелом"
expect_out_of_range 5.5  1 10 "дробное"
expect_out_of_range "1e3" 1 10 "экспонента"
expect_in_range    007  1 10 "лидирующие нули (007==7, в диапазоне)"
expect_out_of_range 99999999999999999999 1 10 "очень большое число"
# Диапазон из одной точки.
expect_in_range   5    5 5  "диапазон-точка: точное попадание"
expect_out_of_range 4    5 5  "диапазон-точка: мимо"

# ===========================================================================
# 2. ports_validate — корректность портов и диапазонов
# ===========================================================================
echo "== 2. ports_validate (порты и диапазоны) =="

expect_valid_port() {
  local val="$1" label="$2"
  if ports_validate "$val"; then
    ok "$label: '$val' → валиден"
  else
    fail "$label: '$val' должен быть валидным портом"
  fi
}
expect_invalid_port() {
  local val="$1" label="$2"
  if ports_validate "$val"; then
    fail "$label: '$val' должен быть НЕвалидным портом"
  else
    ok "$label: '$val' → отклонён"
  fi
}

expect_valid_port   1       "минимальный порт"
expect_valid_port   80      "обычный порт"
expect_valid_port   65535   "максимальный порт"
expect_valid_port   "1000-2000" "корректный диапазон"
expect_valid_port   "65534-65535" "диапазон у верхней границы"
expect_valid_port   "80-80" "диапазон-точка"

expect_invalid_port 0       "ноль"
expect_invalid_port 65536   "превышение максимума"
expect_invalid_port -1      "отрицательный порт"
expect_invalid_port ""      "пустая строка"
expect_invalid_port "abc"   "буквы"
expect_invalid_port "80a"   "буквы после цифр"
expect_invalid_port "2000-1000" "перевёрнутый диапазон"
expect_invalid_port "80-100-200" "двойной дефис"
expect_invalid_port "1-65536" "диапазон с превышением"
expect_invalid_port "0-100" "диапазон с нулём"
expect_invalid_port "999999999" "слишком большое число"
expect_invalid_port "80,443" "csv-список (не одиночный токен)"

# ===========================================================================
# 3. ui_invalid_input — должна выполняться без ошибок
# ===========================================================================
echo "== 3. ui_invalid_input (отработка без ошибок) =="
# Функция содержит sleep 1; подменяем sleep, чтобы тест был мгновенным.
sleep() { :; }
if ui_invalid_input >/dev/null 2>&1; then
  ok "ui_invalid_input отработала без ошибок (rc=0)"
else
  fail "ui_invalid_input вернула ненулевой код"
fi
unset -f sleep

echo ""
echo "============================="
printf 'ui_validation smoke ok (assertions: %d)\n' "$PASS"
