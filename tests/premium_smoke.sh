#!/usr/bin/env bash

# Тест premium-пунктов (lib/premium.sh): 777 — активация/сброс титула,
# 999 — показывается только при активном premium. Живой кейс: повторный 777
# должен скрывать/обнулять титул (и заодно убирать пункт 999 из меню).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

TMP_DIR="$(mktemp -d /tmp/zator-premium.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

export CACHE_DIR="$TMP_DIR/cache"
mkdir -p "$CACHE_DIR"

# цвета из z2r.sh — в песочнице заглушки
green=""; yellow=""; pink=""; red=""; plain=""; Bred=""; Fplain=""; Fcyan=""; Fcyan2=""

# shellcheck source=/dev/null
source "$REPO_DIR/lib/premium.sh"

# без пауз: спиннер в заглушку (2s на каждую активацию)
spinner_for_seconds() { :; }

PREMIUM_FLAG="$CACHE_DIR/premium.enabled"
PREMIUM_TITLE_FILE="$CACHE_DIR/premium.title"

# --- 0. Синтаксис + статический wiring ----------------------------------------

bash -n "$REPO_DIR/lib/premium.sh" || fail "bash -n: lib/premium.sh"
bash -n "$REPO_DIR/z2r.sh" || fail "bash -n: z2r.sh"
Z2R_SRC="$(tr -d '\r' < "$REPO_DIR/z2r.sh")"
grep -qF '999. Секретный пункт' <<<"$Z2R_SRC" || fail "z2r.sh: нет пункта 999"
# строка «Титул:» и пункт 999 показываются только по флагу premium
grep -qF 'PREMIUM_TITLE_FILE' <<<"$Z2R_SRC" || fail "z2r.sh: титул в меню не привязан к файлу титула"

# --- 1. Стартовое состояние: ни флага, ни титула ------------------------------

[[ ! -f "$PREMIUM_FLAG" ]] || fail "старт: флаг premium не должен существовать"
[[ ! -e "$PREMIUM_TITLE_FILE" ]] || fail "старт: файл титула не должен существовать"

# --- 2. Активация: флаг + титул, 999 показывается -----------------------------

out="$(zefeer_premium_777)"
grep -qF 'Присвоен титул' <<<"$out" || fail "777: титул не присвоен"
[[ -f "$PREMIUM_FLAG" ]] || fail "777: флаг не создан"
[[ -s "$PREMIUM_TITLE_FILE" ]] || fail "777: титул пуст"
old_title="$(cat "$PREMIUM_TITLE_FILE")"
[ -n "$old_title" ] || fail "777: титул не должен быть пустым"

# --- 3. Повторный 777 — сброс: флаг и титул исчезают --------------------------

out="$(zefeer_premium_777)"
grep -qF 'деактивирован' <<<"$out" || fail "777 повторный: нет сообщения о деактивации"
[[ ! -f "$PREMIUM_FLAG" ]] || fail "сброс: флаг premium должен быть удалён"
[[ ! -e "$PREMIUM_TITLE_FILE" ]] || fail "сброс: титул должен быть обнулён"

# --- 4. Повторная активация выдаёт титул заново -------------------------------

out="$(zefeer_premium_777)"
grep -qF 'Присвоен титул' <<<"$out" || fail "777 повторная активация: титул не присвоен"
[[ -s "$PREMIUM_TITLE_FILE" ]] || fail "повторная активация: титул пуст"

# --- 5. Симуляция условий главного меню ---------------------------------------

# меню показывает 999 и строку «Титул:» только при живом флаге/титуле
menu_shows_999() { [[ -f "$PREMIUM_FLAG" ]]; }
menu_shows_title() { [[ -s "$PREMIUM_TITLE_FILE" ]]; }
menu_shows_999 || fail "меню: 999 должен показываться при активном premium"
menu_shows_title || fail "меню: титул должен показываться при активном premium"

zefeer_premium_777 >/dev/null
if menu_shows_999; then fail "меню: после сброса 999 должен скрыться"; fi
if menu_shows_title; then fail "меню: после сброса титул должен скрыться"; fi

# --- 6. Переключатель: деактивация -> реактивация -> деактивация --------------

out="$(zefeer_premium_777)"
grep -qF 'Присвоен титул' <<<"$out" || fail "деактивация-реактивация: титул не присвоен"
[[ -f "$PREMIUM_FLAG" && -s "$PREMIUM_TITLE_FILE" ]] || fail "реактивация: файлы должны вернуться"
zefeer_premium_777 >/dev/null
[[ ! -f "$PREMIUM_FLAG" && ! -e "$PREMIUM_TITLE_FILE" ]] \
  || fail "финальный сброс: файлы должны быть удалены"

echo "premium smoke ok"
