#!/usr/bin/env bash
# Keenetic + PBR: bind-fix (SO_BINDTODEVICE для сгенерированных пакетов)
# добавляется к аргументам nfqws2 ТОЛЬКО при активном PBR (2+ WAN либо
# fwmark-правила политик) и только если сборка знает опцию (--help).
# При одном провайдере это лишний setsockopt на каждый rawsend.
# Режим Z2R_KEENETIC_BINDFIX: auto | 1 (всегда) | 0 (никогда).
# Только во временной директории, без сети и /opt.
#
# Запуск:  bash tests/keenetic_bindfix_smoke.sh

set -u
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/z2r_keenetic_bindfix.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

INIT="$REPO_DIR/Entware/zapret"
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- функции bind-fix из init-скрипта (тот же текст, что уезжает на роутер) --
sed -n '/^z2r_bindfix_wanted()/,/^}/p' "$INIT" > "$WORK/bindfix.sh"
sed -n '/^z2r_bindfix_args()/,/^}/p' "$INIT" >> "$WORK/bindfix.sh"
grep -q '^z2r_bindfix_args()' "$WORK/bindfix.sh" || fail "z2r_bindfix_args не найден в Entware/zapret"
. "$WORK/bindfix.sh"

# Мок ip: fwmark-правила политик Keenetic есть, если задан IP_RULES.
ip() {
  case "$*" in
    '-4 rule show'|'-6 rule show')
      [ -n "${IP_RULES:-}" ] && printf '%s\n' "$IP_RULES"
      ;;
  esac
  return 0
}

# Фейковый nfqws2: на --help печатает выбранные опции, на старте
# записывает argv в ARGV_LOG.
cat > "$WORK/fake-nfqws2" <<'EOF'
#!/bin/sh
if [ "$1" = "--help" ]; then
  echo " --qnum=<int>                     ; set queue number"
  case "${FAKE_BINDFIX:-both}" in both|4) echo " --bind-fix4 ; fix ipv4" ;; esac
  case "${FAKE_BINDFIX:-both}" in both|6) echo " --bind-fix6 ; fix ipv6" ;; esac
  exit 1
fi
printf '%s\n' "$*" > "${ARGV_LOG:-/dev/null}"
EOF
chmod +x "$WORK/fake-nfqws2"
export FAKE_BINDFIX=both

BASE='--qnum=300 --lua-init=@x'

# --- юнит-кейсы z2r_bindfix_args -------------------------------------------
case1() { # want desc
  local want="$1" desc="$2" out
  out="$(z2r_bindfix_args "$WORK/fake-nfqws2" "$BASE")"
  [ "$out" = "$want" ] || fail "$desc: ожидалось '$want', получено '$out'"
}

IFACE_WAN='ppp0 ppp1'; IP_RULES=''; Z2R_KEENETIC_BINDFIX=auto; FAKE_BINDFIX=both
case1 "--bind-fix4 --bind-fix6 $BASE" "два WAN должны включать bind-fix"

IFACE_WAN='ppp0'; IP_RULES=''
case1 "$BASE" "один WAN без политик: bind-fix лишний"

IP_RULES='1152: from all fwmark 0xffffaad lookup 4102'
case1 "--bind-fix4 --bind-fix6 $BASE" "PBR по fwmark-правилам"

IFACE_WAN='ppp0'; IP_RULES=''; Z2R_KEENETIC_BINDFIX=1; FAKE_BINDFIX=both
case1 "--bind-fix4 --bind-fix6 $BASE" "режим 1 включает bind-fix без PBR"

IFACE_WAN='ppp0 ppp1'; Z2R_KEENETIC_BINDFIX=0
case1 "$BASE" "режим 0 выключает bind-fix даже при PBR"

IFACE_WAN='ppp0 ppp1'; Z2R_KEENETIC_BINDFIX=auto
out="$(z2r_bindfix_args "$WORK/fake-nfqws2" "--bind-fix4 $BASE")"
[ "$out" = "--bind-fix6 --bind-fix4 $BASE" ] || fail "добавление отсутствующей IPv6-опции: '$out'"
out="$(z2r_bindfix_args "$WORK/fake-nfqws2" "--bind-fix6 $BASE")"
[ "$out" = "--bind-fix4 --bind-fix6 $BASE" ] || fail "добавление второй опции при заданной первой: '$out'"

IFACE_WAN='ppp0'; IP_RULES='100: from all fwmark 0xffffa00 lookup main'
case1 "$BASE" "системное fwmark lookup main не включает bind-fix"
IP_RULES=''

IFACE_WAN='ppp0 ppp1'
FAKE_BINDFIX=none
case1 "$BASE" "сборка без опции: демон стартует как раньше"
FAKE_BINDFIX=4
case1 "--bind-fix4 $BASE" "сборка поддерживает только bind-fix4"
FAKE_BINDFIX=6
case1 "--bind-fix6 $BASE" "сборка поддерживает только bind-fix6"
FAKE_BINDFIX=both

IFACE_WAN='ppp0 ppp1'
out="$(z2r_bindfix_args "$WORK/fake-nfqws2" "")"
[ "$out" = "--bind-fix4 --bind-fix6" ] || fail "пустые аргументы: '$out'"

# --- полный прогон: префикс доезжает до argv демона ------------------------
mkdir -p "$WORK/bin" "$WORK/run" "$WORK/zapret2/init.d/sysv"
cp "$INIT" "$WORK/zapret2/init.d/sysv/zapret"
chmod +x "$WORK/zapret2/init.d/sysv/zapret"
cat > "$WORK/bin/lsmod" <<'EOF'
#!/bin/sh
echo "xt_multiport xt_connbytes xt_NFQUEUE"
EOF
cat > "$WORK/bin/insmod" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WORK/bin/lsmod" "$WORK/bin/insmod"
cat > "$WORK/zapret2/init.d/sysv/functions" <<EOF
INIT_APPLY_FW=0
PIDDIR="$WORK/run"
zapret_run_daemons() { run_daemon 1 "$WORK/fake-nfqws2" "--qnum=300 --lua-init=@x"; }
zapret_apply_firewall() { :; }
zapret_stop_daemons() { :; }
zapret_unapply_firewall() { :; }
EOF

run_start() {
  local i=0
  : > "$WORK/argv.log"
  PATH="$WORK/bin:$PATH" ARGV_LOG="$WORK/argv.log" \
    sh "$WORK/zapret2/init.d/sysv/zapret" start >/dev/null 2>&1
  while [ ! -s "$WORK/argv.log" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  cat "$WORK/argv.log" 2>/dev/null || true
}

args="$(IFACE_WAN='ppp0 ppp1' Z2R_KEENETIC_BINDFIX=auto FAKE_BINDFIX=both run_start)"
[ "$args" = "--bind-fix4 --bind-fix6 --qnum=300 --lua-init=@x" ] \
  || fail "run_daemon не добавил bind-fix при двух WAN: '$args'"
args="$(IFACE_WAN='ppp0' Z2R_KEENETIC_BINDFIX=auto FAKE_BINDFIX=both run_start)"
[ "$args" = "--qnum=300 --lua-init=@x" ] \
  || fail "run_daemon добавил bind-fix при одном WAN без PBR: '$args'"
args="$(IFACE_WAN='ppp0 ppp1' Z2R_KEENETIC_BINDFIX=auto FAKE_BINDFIX=none run_start)"
[ "$args" = "--qnum=300 --lua-init=@x" ] \
  || fail "run_daemon добавил bind-fix в сборке без опции: '$args'"

# --- статический wiring ----------------------------------------------------
grep -q '\*nfqws2) set --' "$INIT" || fail "run_daemon не заменяет третий аргумент для nfqws2"
[ "$(grep -c -- '"\$2" \$3' "$INIT")" = "3" ] \
  || fail "все три ветки спавна должны использовать третий аргумент"
grep -qx 'Z2R_KEENETIC_BINDFIX=auto' "$REPO_DIR/config.default" \
  || fail "config.default: нет Z2R_KEENETIC_BINDFIX=auto"
grep -q '^--bind-fix' "$REPO_DIR/config.default" \
  && fail "bind-fix не должен писаться в config: только на старте демона"
if command -v busybox >/dev/null 2>&1; then
  busybox sh -n "$INIT" || fail "busybox sh -n Entware/zapret"
fi

echo "keenetic bindfix smoke ok"

