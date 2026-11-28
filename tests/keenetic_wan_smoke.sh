#!/usr/bin/env bash
# Keenetic + несколько провайдеров: список WAN-интерфейсов в IFACE_WAN и общий
# парсер IFACE_*. Только во временной директории, без сети и /opt.
#
# Покрывает:
#   0. парсер config_get_iface_var/config_get_iface_wan: двойные и одинарные
#      кавычки, хвостовой комментарий, лишние пробелы, последнее присваивание,
#      игнор закомментированной строки;
#   1. config_keenetic_detect_default_ifaces: default-маршруты из main И из
#      policy-таблиц (у второго провайдера при PBR своего default в main нет),
#      дедуп, lo и виртуальные туннели (WireGuard/tun) не берутся;
#   2. config_keenetic_wan_merge: пользовательский список не сужается, новые
#      интерфейсы из автоопределения добавляются;
#   3. config_keenetic_set_wan_iface: "ppp0 ppp1" в IFACE_WAN, комментарии
#      шаблона целы, идемпотентность, нет маршрутов -> конфиг не тронут,
#      не-Keenetic -> конфиг не тронут;
#   4. config_set_var с '#' в значении (регрессия "ошибка sed" из ревью) и
#      перенос режима Z2R_KEENETIC_BINDFIX в новый конфиг.
#
# Запуск:  bash tests/keenetic_wan_smoke.sh

set -u
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/z2r_keenetic_wan.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
. "$REPO_DIR/lib/config.sh"

hardware=keenetic
yellow= green= red= plain= cyan=
CFG="$WORK/config"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Мок ip: ppp1 имеет default только в таблице политики (как на живом Keenetic
# с PBR), nwg1 — тоже (WireGuard), но в автосписок попасть не должен.
ip() {
  case "$*" in
    '-4 route show default')
      printf '%s\n' 'default dev ppp0 scope link  metric 1000 ' ;;
    '-4 route show table all')
      printf '%s\n' \
        'default dev nwg1 table 4096 scope link  metric 1000 ' \
        'default dev ppp1 table 4102 scope link  metric 1000 ' \
        'default dev ppp0 table 4100 scope link  metric 1000 ' \
        'default dev ppp0 scope link  metric 1000 ' \
        '10.0.0.0/8 dev br0 scope link ' ;;
    '-6 route show default')
      printf '%s\n' 'default dev ppp0  metric 1024 ' ;;
    '-6 route show table all')
      printf '%s\n' 'unreachable default dev lo  metric -1  error -101' ;;
    '-o link show dev nwg1')
      printf '%s\n' '44: nwg1: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1324 qdisc noqueue qlen 50\    link/[65534] ' ;;
    '-o link show dev ppp0')
      printf '%s\n' '39: ppp0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1492 qdisc fq_codel qlen 1000\    link/ppp ' ;;
    '-o link show dev ppp1')
      printf '%s\n' '42: ppp1: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1492 qdisc fq_codel qlen 1000\    link/ppp ' ;;
    '-o link show dev br0')
      printf '%s\n' '35: br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue\    link/ether d4:9c:53:25:79:95 brd ff:ff:ff:ff:ff:ff' ;;
    *) return 0 ;;
  esac
}

mkcfg() {
  cat > "$CFG" <<'EOF'
#IFACE_WAN=eth1
#IFACE_WAN6="ipsec0 wireguard0 he_net"
FWTYPE=iptables
NFQWS2_OPT="
"
EOF
}

# --- 0. Парсер IFACE_* ------------------------------------------------------
[ -z "$(config_get_iface_wan "$CFG")" ] \
  || fail "закомментированный IFACE_WAN должен игнорироваться"
printf 'IFACE_WAN="eth3"\n#IFACE_WAN=eth1\n' > "$CFG"
[ "$(config_get_iface_wan "$CFG")" = "eth3" ] || fail "двойные кавычки"
printf "IFACE_WAN='ppp0 ppp1'\n" > "$CFG"
[ "$(config_get_iface_wan "$CFG")" = "ppp0 ppp1" ] \
  || fail "одинарные кавычки: получено '$(config_get_iface_wan "$CFG")'"
printf 'IFACE_WAN=ppp0 # primary\n' > "$CFG"
[ "$(config_get_iface_wan "$CFG")" = "ppp0" ] || fail "хвостовой комментарий"
printf 'IFACE_WAN="ppp0 ppp1" # both providers\n' > "$CFG"
[ "$(config_get_iface_wan "$CFG")" = "ppp0 ppp1" ] \
  || fail "комментарий после цитаты: получено '$(config_get_iface_wan "$CFG")'"
printf '  IFACE_WAN=   ppp0    ppp1   \n' > "$CFG"
[ "$(config_get_iface_wan "$CFG")" = "ppp0 ppp1" ] \
  || fail "лишние пробелы: получено '$(config_get_iface_wan "$CFG")'"
printf 'IFACE_WAN=ppp0\nIFACE_WAN="ppp1"\n' > "$CFG"
[ "$(config_get_iface_wan "$CFG")" = "ppp1" ] \
  || fail "должно браться последнее присваивание (как у shell)"
printf 'IFACE_WAN6="ipsec0 wireguard0"\n' > "$CFG"
[ -z "$(config_get_iface_wan "$CFG")" ] || fail "config_get_iface_wan читает только IFACE_WAN"
[ "$(config_get_iface_var "$CFG" IFACE_WAN6)" = "ipsec0 wireguard0" ] \
  || fail "config_get_iface_var с другим именем"

# --- 1. Автоопределение WAN ------------------------------------------------
[ "$(config_keenetic_detect_default_ifaces 4 | tr '\n' ' ')" = "ppp0 ppp1 " ] \
  || fail "detect4: ожидалось 'ppp0 ppp1', получено '$(config_keenetic_detect_default_ifaces 4 | tr '\n' ' ')'"
[ "$(config_keenetic_detect_default_ifaces 6 | tr '\n' ' ')" = "ppp0 " ] \
  || fail "detect6: ожидалось 'ppp0', получено '$(config_keenetic_detect_default_ifaces 6 | tr '\n' ' ')'"

# --- 2. Слияние списков ----------------------------------------------------
[ "$(config_keenetic_wan_merge 'ppp0 ppp1' 'ppp0 ppp1')" = "ppp0 ppp1" ] \
  || fail "merge: дубли не схлопнулись"
[ "$(config_keenetic_wan_merge 'ppp1 ppp0' 'ppp0 ppp2')" = "ppp1 ppp0 ppp2" ] \
  || fail "merge: пользовательский порядок/актуализация: '$(config_keenetic_wan_merge 'ppp1 ppp0' 'ppp0 ppp2')'"
[ "$(config_keenetic_wan_merge '' 'ppp0 ppp1')" = "ppp0 ppp1" ] \
  || fail "merge: пустой текущий список"
[ "$(config_keenetic_wan_merge 'nwg0' '')" = "nwg0" ] \
  || fail "merge: без автоопределения пользовательское значение сохраняется"
[ "$(config_keenetic_wan_merge 'ANY' 'ppp0 ppp1')" = "ppp0 ppp1" ] \
  || fail "merge: плейсхолдер install_easy ANY не должен попасть в правила"

# --- 3. config_keenetic_set_wan_iface --------------------------------------
mkcfg
config_keenetic_set_wan_iface "$CFG"
[ "$(config_get_iface_wan "$CFG")" = "ppp0 ppp1" ] \
  || fail "IFACE_WAN: ожидалось 'ppp0 ppp1', получено '$(config_get_iface_wan "$CFG")'"
[ "$(config_get_iface_var "$CFG" IFACE_WAN6)" = "ppp0" ] || fail "IFACE_WAN6"
grep -qx '#IFACE_WAN=eth1' "$CFG" || fail "закомментированный шаблон потерян"
sum1="$(md5sum "$CFG" | awk '{print $1}')"
config_keenetic_set_wan_iface "$CFG"
sum2="$(md5sum "$CFG" | awk '{print $1}')"
[ "$sum1" = "$sum2" ] || fail "set_wan_iface не идемпотентен"

# Пользовательский список из 2+ интерфейсов не сужается, даже если авто
# находит один (второй провайдер доступен только через PBR).
printf "IFACE_WAN='ppp0 ppp1'\nFWTYPE=iptables\n" > "$CFG"
config_keenetic_set_wan_iface "$CFG"
[ "$(config_get_iface_wan "$CFG")" = "ppp0 ppp1" ] \
  || fail "пользовательский список сузился до '$(config_get_iface_wan "$CFG")'"

# Актуализация: новый интерфейс из автоопределения добавляется.
printf 'IFACE_WAN=ppp0\nFWTYPE=iptables\n' > "$CFG"
config_keenetic_set_wan_iface "$CFG"
[ "$(config_get_iface_wan "$CFG")" = "ppp0 ppp1" ] \
  || fail "список не актуализировался: '$(config_get_iface_wan "$CFG")'"

# Комментарий в значении раньше ломал sed при записи.
printf 'IFACE_WAN=ppp0 # primary\nFWTYPE=iptables\n' > "$CFG"
config_keenetic_set_wan_iface "$CFG" || fail "set_wan_iface на значении с комментарием"
[ "$(config_get_iface_wan "$CFG")" = "ppp0 ppp1" ] \
  || fail "значение с комментарием разобрано неверно"

# Маршрутов нет: конфиг не меняем, печатаем предупреждение.
printf 'IFACE_WAN=\nFWTYPE=iptables\n' > "$CFG"
cat > "$WORK/no-routes.sh" <<'EOF'
ip() { return 0; }
EOF
( . "$WORK/no-routes.sh"; config_keenetic_set_wan_iface "$CFG" ) > "$WORK/no-routes.out" 2>&1
[ -z "$(config_get_iface_wan "$CFG")" ] || fail "без маршрутов IFACE_WAN изменён"
grep -q 'Не удалось автоматически определить' "$WORK/no-routes.out" \
  || fail "без маршрутов нет предупреждения"

# Не-Keenetic: не трогаем IFACE_WAN и не пишем bind-fix в конфиг.
printf 'IFACE_WAN=\nFWTYPE=iptables\n' > "$CFG"
hardware=generic
config_keenetic_set_wan_iface "$CFG"
[ -z "$(config_get_iface_wan "$CFG")" ] || fail "generic: IFACE_WAN изменён"
grep -q -- '--bind-fix' "$CFG" && fail "generic: в конфиг попал bind-fix"
hardware=keenetic

# --- 3b. атомарная синхронизация init из локального payload -----------------
INIT_SRC="$WORK/payload-zapret"
INIT_DEST="$WORK/init.d/zapret2"
mkdir -p "$WORK/init.d"
printf '# old init\n' > "$INIT_DEST"
printf '# updated init\n' > "$INIT_SRC"
config_keenetic_init_sync "$INIT_SRC" "$INIT_DEST" || fail "init sync завершился ошибкой"
cmp -s "$INIT_SRC" "$INIT_DEST" || fail "init не заменён содержимым payload"
[ -x "$INIT_DEST" ] || fail "init после замены потерял executable bit"
[ ! -e "$INIT_DEST.z2r.$$" ] || fail "временный init остался после замены"

# --- 4. config_set_var с '#' и перенос настроек Keenetic -------------------
printf 'FWTYPE=iptables\n' > "$CFG"
config_set_var "$CFG" TEST_VAR 'a#b'
( . "$CFG"; [ "$TEST_VAR" = 'a#b' ] ) || fail "config_set_var не сохранил значение с '#'"

printf 'POLICY_NAME=new\nPOLICY_MARK=1\nPOLICY_EXCLUDE=0\nZ2R_KEENETIC_BINDFIX=auto\n' > "$CFG"
printf 'POLICY_NAME=old\nPOLICY_MARK=2\nPOLICY_EXCLUDE=1\nZ2R_KEENETIC_BINDFIX=1\n' > "$WORK/old-config"
config_keenetic_policy_apply "$WORK/old-config" "$CFG"
[ "$(config_get_var "$CFG" POLICY_NAME)" = "old" ] || fail "POLICY_NAME не перенесён"
[ "$(config_get_var "$CFG" POLICY_MARK)" = "2" ] || fail "POLICY_MARK не перенесён"
[ "$(config_get_var "$CFG" POLICY_EXCLUDE)" = "1" ] || fail "POLICY_EXCLUDE не перенесён"
[ "$(config_get_var "$CFG" Z2R_KEENETIC_BINDFIX)" = "1" ] \
  || fail "режим bind-fix не перенесён: '$(config_get_var "$CFG" Z2R_KEENETIC_BINDFIX)'"
printf 'FWTYPE=iptables\nZ2R_KEENETIC_BINDFIX=\n' > "$WORK/old-config"
printf 'Z2R_KEENETIC_BINDFIX=auto\n' > "$CFG"
config_keenetic_policy_apply "$WORK/old-config" "$CFG"
[ "$(config_get_var "$CFG" Z2R_KEENETIC_BINDFIX)" = "auto" ] \
  || fail "без ключа в старом конфиге значение нового изменилось"

echo "keenetic wan smoke ok"

