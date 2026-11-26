#!/usr/bin/env bash
# Keenetic: метки zapret2 не должны пересекаться с метками политик доступа.
#  * Keenetic матчит policy fwmark целым словом (ip rule без маски), поэтому
#    бит, занятый политикой, нельзя использовать для служебных нужд;
#  * Z2R_WSSIZE_MARK гейтит профиль wssize_ramp (--filter-mark). Метки политик
#    вида 0xffffaad уже содержат бит 0x04000000 — с прежним дефолтом профиль
#    получал весь TLS-трафик policy-устройств, а не только googlevideo;
#  * FLOWOFFLOAD=hardware/software при FWTYPE=iptables — no-op (offload в
#    zapret2 управляется только nftables), приводим к donttouch.
set -eu
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
. "$REPO_DIR/lib/config.sh"

CFG="$WORK/config"
hardware=keenetic
yellow= green= red= plain=

fail() { echo "FAIL: $*" >&2; exit 1; }

mkcfg() {
  cat > "$CFG" <<EOF
FWTYPE=${1:-iptables}
FLOWOFFLOAD=${2:-donttouch}
DESYNC_MARK=0x40000000
DESYNC_MARK_POSTNAT=0x20000000
CLIENT_SCOPE_MARK_MASK=
Z2R_WSSIZE_MARK=${3:-0x04000000}
Z2R_WSSIZE_RAMP_ENABLE=${4:-1}
EOF
}

# --- битовые проверки ------------------------------------------------------
config_keenetic_mark_conflicts 0x04000000 0xffffaad || fail '0x04000000 должен пересекаться с 0xffffaad'
config_keenetic_mark_conflicts 0x04000000 0xffffaaa || fail '0x04000000 должен пересекаться с 0xffffaaa'
config_keenetic_mark_conflicts 0x00000400 0xffffaad && fail '0x400 не должен пересекаться с 0xffffaad'
config_keenetic_mark_conflicts 0x40000000 0x0 && fail 'нулевая метка не должна давать конфликт'

# --- реальный набор политик NC-1812 --------------------------------------
ndmc() {
  case "$*" in
    "-c show ip policy") cat <<'EOF'
           policy, name = Policy2, description = Ростелеком: 
                 mark: ffffaac
               table4: 4100
           policy, name = Policy3, description = ККС: 
                 mark: ffffaad
               table4: 4102
EOF
    ;;
    *) return 1 ;;
  esac
}

mkcfg iptables donttouch 0x04000000 1
# Парсинг меток политик из ndmc — отдельная точка отказа (mark: ffffaad).
config_keenetic_used_marks "$CFG" | grep -qx '0xffffaad' \
  || fail "метки политик не распознаны: $(config_keenetic_used_marks "$CFG" | tr '\n' ' ')"
# Метки политик 28-битные (0x0FFFFFFF): бит 0x04000000 в них уже стоит, а
# свободен старший бит 0x80000000 — туда и переносим.
out="$(config_keenetic_ensure_wssize_mark "$CFG")"
[ "$(config_get_var "$CFG" Z2R_WSSIZE_MARK)" = "0x80000000" ] \
  || fail "ожидался перенос в 0x80000000, получено '$(config_get_var "$CFG" Z2R_WSSIZE_MARK)'"
[ "$(config_get_var "$CFG" Z2R_WSSIZE_RAMP_ENABLE)" = "1" ] || fail 'ramp не должен выключаться, когда бит найден'
printf '%s' "$out" | grep -q 'перенесён' || fail 'нет сообщения о переносе метки'

# Идемпотентность: второй прогон ничего не меняет и молчит.
out="$(config_keenetic_ensure_wssize_mark "$CFG")"
[ -z "$out" ] || fail "повторный прогон напечатал лишнее: $out"
[ "$(config_get_var "$CFG" Z2R_WSSIZE_MARK)" = "0x80000000" ]

# --- ramp выключен: конфиг не трогаем ------------------------------------
mkcfg iptables donttouch 0x04000000 0
config_keenetic_ensure_wssize_mark "$CFG" >/dev/null
[ "$(config_get_var "$CFG" Z2R_WSSIZE_MARK)" = "0x04000000" ] || fail 'при ENABLE=0 метка меняться не должна'

# --- заняты все биты: фичу выключаем -------------------------------------
ndmc() { [ "$*" = "-c show ip policy" ] && printf '                 mark: ffffffff\n'; }
mkcfg iptables donttouch 0x04000000 1
out="$(config_keenetic_ensure_wssize_mark "$CFG")"
[ "$(config_get_var "$CFG" Z2R_WSSIZE_RAMP_ENABLE)" = "0" ] || fail 'при отсутствии свободного бита ramp должен выключиться'
printf '%s' "$out" | grep -q 'выключен' || fail 'нет сообщения о выключении ramp'

# --- FLOWOFFLOAD при iptables приводим к donttouch -----------------------
ndmc() { [ "$*" = "-c show ip policy" ] && printf '                 mark: ffffaad\n'; }
mkcfg iptables hardware 0x00000400 1
config_keenetic_ensure_flowoffload "$CFG" >/dev/null
[ "$(config_get_var "$CFG" FLOWOFFLOAD)" = "donttouch" ] || fail 'hardware при iptables должен стать donttouch'
mkcfg iptables software 0x00000400 1
config_keenetic_ensure_flowoffload "$CFG" >/dev/null
[ "$(config_get_var "$CFG" FLOWOFFLOAD)" = "donttouch" ] || fail 'software при iptables должен стать donttouch'
mkcfg nftables hardware 0x00000400 1
config_keenetic_ensure_flowoffload "$CFG" >/dev/null
[ "$(config_get_var "$CFG" FLOWOFFLOAD)" = "hardware" ] || fail 'при nftables значение пользователя менять нельзя'

# --- не-Keenetic: ничего не трогаем --------------------------------------
mkcfg iptables hardware 0x04000000 1
hardware=generic
config_keenetic_ensure_safe_settings "$CFG" >/dev/null
[ "$(config_get_var "$CFG" FLOWOFFLOAD)" = "hardware" ] || fail 'generic: FLOWOFFLOAD изменён'
[ "$(config_get_var "$CFG" Z2R_WSSIZE_MARK)" = "0x04000000" ] || fail 'generic: метка изменена'

exit 0
