#!/usr/bin/env bash
# Keenetic + несколько провайдеров (PPPoE ppp0/ppp1, PBR-политики):
#  * IFACE_WAN должен покрывать ВСЕ default-route интерфейсы, иначе правила
#    zapret2 создаются только для основного и резервный остаётся без обхода;
#  * пользовательский список из 2+ интерфейсов не сужается;
#  * NFQWS2_OPT получает --bind-fix4/--bind-fix6: nfqws2 домешивает в fwmark
#    сгенерированных пакетов бит 0x40000000, а KeeneticOS матчит fwmark в
#    ip rule целым словом — без bind-fix raw-пакеты уходят мимо таблицы
#    политики (в main) и теряются на втором провайдере.
set -eu
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
. "$REPO_DIR/lib/config.sh"

CFG="$WORK/config"
hardware=keenetic
yellow= green= plain=

mkcfg() {
  cat > "$CFG" <<'EOF'
#IFACE_WAN=eth1
FWTYPE=iptables
NFQWS2_OPT="
--lua-init=@/opt/zator/lua/client-scope-config.lua
"
EOF
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# Два default route (ppp0 + ppp1) и IPv6 через ppp0.
ip() {
  case "$*" in
    "-4 route show default")
      printf '%s\n' \
        'default dev ppp0 scope link  metric 1000 ' \
        'default dev ppp1 scope link  metric 1001 ' \
        'default dev ppp0 scope link  metric 2000 ' ;;
    "-6 route show default") printf '%s\n' 'default dev ppp0  metric 1024 ' ;;
    *) return 1 ;;
  esac
}

mkcfg
config_keenetic_set_wan_iface "$CFG"
[ "$(config_keenetic_wan_get "$CFG" IFACE_WAN)" = "ppp0 ppp1" ] \
  || fail "ожидался IFACE_WAN='ppp0 ppp1', получено '$(config_keenetic_wan_get "$CFG" IFACE_WAN)'"
[ "$(config_keenetic_wan_get "$CFG" IFACE_WAN6)" = "ppp0" ] \
  || fail "ожидался IFACE_WAN6='ppp0'"
grep -qx -- '--bind-fix4' "$CFG" || fail "нет --bind-fix4 в NFQWS2_OPT"
grep -qx -- '--bind-fix6' "$CFG" || fail "нет --bind-fix6 в NFQWS2_OPT"
# Комментарий в шаблоне не должен считаться значением.
grep -qx '#IFACE_WAN=eth1' "$CFG" || fail "закомментированный IFACE_WAN потерян"

# Повторный вызов не дублирует опции.
config_keenetic_set_wan_iface "$CFG"
[ "$(grep -c -- '^--bind-fix4$' "$CFG")" = 1 ] || fail "--bind-fix4 задублирован"

# Пользовательский список из двух интерфейсов не сужается, даже если
# default route сейчас один (второй провайдер доступен только через PBR).
cat > "$CFG" <<'EOF'
IFACE_WAN="ppp0 ppp1"
FWTYPE=iptables
NFQWS2_OPT="
--bind-fix4
"
EOF
ip() {
  [ "$*" = '-4 route show default' ] && printf '%s\n' 'default dev ppp0 scope link  metric 1000 '
}
config_keenetic_set_wan_iface "$CFG"
[ "$(config_keenetic_wan_get "$CFG" IFACE_WAN)" = "ppp0 ppp1" ] \
  || fail "пользовательский список сузился до '$(config_keenetic_wan_get "$CFG" IFACE_WAN)'"
[ "$(grep -c -- '^--bind-fix4$' "$CFG")" = 1 ] || fail "--bind-fix4 задублирован после повторного вызова"

# Один default route и пустой IFACE_WAN -> один интерфейс.
cat > "$CFG" <<'EOF'
IFACE_WAN=
FWTYPE=iptables
NFQWS2_OPT="
"
EOF
config_keenetic_set_wan_iface "$CFG"
[ "$(config_keenetic_wan_get "$CFG" IFACE_WAN)" = "ppp0" ] \
  || fail "ожидался IFACE_WAN='ppp0', получено '$(config_keenetic_wan_get "$CFG" IFACE_WAN)'"

# Не-Keenetic: конфиг не трогаем.
cat > "$CFG" <<'EOF'
IFACE_WAN=
FWTYPE=iptables
NFQWS2_OPT="
"
EOF
hardware=generic
config_keenetic_set_wan_iface "$CFG"
[ -z "$(config_keenetic_wan_get "$CFG" IFACE_WAN)" ] || fail "generic: IFACE_WAN изменён"
grep -qx -- '--bind-fix4' "$CFG" && fail "generic: --bind-fix4 добавлен"

exit 0
