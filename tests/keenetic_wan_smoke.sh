#!/usr/bin/env bash
# Keenetic + несколько провайдеров (PPPoE ppp0/ppp1, PBR-политики):
#  * IFACE_WAN покрывает ВСЕ default-route интерфейсы (иначе правила zapret2
#    создаются только для основного и резервный остаётся без обхода);
#  * список актуализируется, пока его не правили руками: рядом пишется маркер
#    #Z2R_IFACE_WAN_AUTO с последним авто-значением;
#  * пользовательский список сохраняется и сопровождается подсказкой;
#  * парсер (config_get_iface_var) понимает двойные и одинарные кавычки и
#    trailing-комментарий;
#  * bind-fix в конфиг не пишется — его решает init-скрипт при старте (PBR).
set -eu
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
. "$REPO_DIR/lib/config.sh"

CFG="$WORK/config"
hardware=keenetic
yellow= green= plain=

fail() { echo "FAIL: $*" >&2; exit 1; }

mkcfg() {
  cat > "$CFG" <<'EOF'
#IFACE_WAN=eth1
FWTYPE=iptables
Z2R_WSSIZE_MARK=0x80000000
Z2R_WSSIZE_RAMP_ENABLE=0
FLOWOFFLOAD=donttouch
EOF
}

# Два default route (ppp0 + ppp1) и IPv6 через ppp0. Набор меняется через
# FAKE_DEFAULT4, чтобы проверить актуализацию списка.
FAKE_DEFAULT4="default dev ppp0 scope link  metric 1000
default dev ppp1 scope link  metric 1001"
ip() {
  case "$*" in
    "-4 route show default") printf '%s\n' "$FAKE_DEFAULT4" ;;
    "-6 route show default") printf '%s\n' 'default dev ppp0  metric 1024 ' ;;
    *) return 1 ;;
  esac
}

# --- 1. пустой конфиг: пишем все default-route интерфейсы + маркер ---------
mkcfg
config_keenetic_set_wan_iface "$CFG" >/dev/null
[ "$(config_get_iface_var "$CFG" IFACE_WAN)" = "ppp0 ppp1" ] \
  || fail "ожидался IFACE_WAN='ppp0 ppp1', получено '$(config_get_iface_var "$CFG" IFACE_WAN)'"
[ "$(config_get_iface_var "$CFG" IFACE_WAN6)" = "ppp0" ] \
  || fail "ожидался IFACE_WAN6='ppp0'"
[ "$(config_keenetic_wan_marker_get "$CFG" IFACE_WAN)" = "ppp0 ppp1" ] \
  || fail "маркер авто-значения не записан"
# Комментарий в шаблоне не должен считаться значением.
grep -qx '#IFACE_WAN=eth1' "$CFG" || fail "закомментированный IFACE_WAN потерян"
grep -qx -- '--bind-fix4' "$CFG" && fail "bind-fix не должен попадать в конфиг"

# --- 2. список не правили руками: актуализируем (провайдер ушёл/вернулся) --
FAKE_DEFAULT4="default dev ppp0 scope link  metric 1000"
config_keenetic_set_wan_iface "$CFG" >/dev/null
[ "$(config_get_iface_var "$CFG" IFACE_WAN)" = "ppp0" ] \
  || fail "авто-список не актуализировался: '$(config_get_iface_var "$CFG" IFACE_WAN)'"
[ "$(config_keenetic_wan_marker_get "$CFG" IFACE_WAN)" = "ppp0" ] \
  || fail "маркер не обновился"
FAKE_DEFAULT4="default dev ppp0 scope link  metric 1000
default dev ppp1 scope link  metric 1001"
config_keenetic_set_wan_iface "$CFG" >/dev/null
[ "$(config_get_iface_var "$CFG" IFACE_WAN)" = "ppp0 ppp1" ] \
  || fail "авто-список не расширился обратно"

# --- 3. список правили руками: сохраняем и подсказываем -------------------
cat > "$CFG" <<'EOF'
#Z2R_IFACE_WAN_AUTO="ppp0 ppp1"
IFACE_WAN="ppp0 ppp9"
FWTYPE=iptables
Z2R_WSSIZE_MARK=0x80000000
Z2R_WSSIZE_RAMP_ENABLE=0
FLOWOFFLOAD=donttouch
EOF
out="$(config_keenetic_set_wan_iface "$CFG")"
[ "$(config_get_iface_var "$CFG" IFACE_WAN)" = "ppp0 ppp9" ] \
  || fail "пользовательский список затёрт: '$(config_get_iface_var "$CFG" IFACE_WAN)'"
printf '%s' "$out" | grep -q 'ведётся вручную' || fail "нет подсказки про ручной список"
printf '%s' "$out" | grep -q 'очистите IFACE_WAN' || fail "нет подсказки, как вернуть автосписок"

# --- 4. парсер: одинарные кавычки, комментарий, пустое значение -----------
printf "IFACE_WAN='ppp0 ppp1'\n" > "$CFG"
[ "$(config_get_iface_var "$CFG" IFACE_WAN)" = "ppp0 ppp1" ] \
  || fail "одинарные кавычки не сняты: '$(config_get_iface_var "$CFG" IFACE_WAN)'"
printf 'IFACE_WAN=ppp0 # primary\n' > "$CFG"
[ "$(config_get_iface_var "$CFG" IFACE_WAN)" = "ppp0" ] \
  || fail "trailing-комментарий не срезан: '$(config_get_iface_var "$CFG" IFACE_WAN)'"
printf 'IFACE_WAN=""\n' > "$CFG"
[ -z "$(config_get_iface_var "$CFG" IFACE_WAN)" ] || fail "пустое значение должно давать пусто"

# --- 5. config_set_var не ломается на '#' --------------------------------
printf 'X=1\n' > "$CFG"
config_set_var "$CFG" X 'value # hash' || fail "config_set_var упал на значении с '#'"
[ "$(config_get_var "$CFG" X)" = 'value # hash' ] \
  || fail "config_set_var испортил значение с '#': '$(config_get_var "$CFG" X)'"

# --- 6. не-Keenetic: конфиг не трогаем -----------------------------------
printf 'IFACE_WAN=\n' > "$CFG"
hardware=generic
config_keenetic_set_wan_iface "$CFG" >/dev/null
[ -z "$(config_get_iface_var "$CFG" IFACE_WAN)" ] || fail "generic: IFACE_WAN изменён"

exit 0
