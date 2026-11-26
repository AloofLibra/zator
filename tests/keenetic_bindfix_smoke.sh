#!/usr/bin/env bash
# Keenetic: bind-fix (SO_BINDTODEVICE для сгенерированных пакетов) добавляется
# к аргументам nfqws2 ТОЛЬКО при активном PBR (несколько WAN либо политики
# доступа / fwmark-правила). При одном провайдере это лишний setsockopt на
# каждый rawsend, поэтому решение принимается на старте демона, а не в конфиге.
# Режим Z2R_KEENETIC_BINDFIX: auto | 1 (всегда) | 0 (никогда).
set -eu
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/bin"
ARGV_LOG="$WORK/argv.log"
POLICY_OUT="$WORK/policy.out"
IP_RULES="$WORK/ip-rules.out"
LSMOD_FILE="$WORK/lsmod"
TARGETS="$WORK/targets"
MODS="$WORK/mods"
mkdir -p "$BIN" "$WORK/run" "$MODS" "$WORK/zapret2/init.d/sysv"

cp "$REPO_DIR/Entware/zapret" "$WORK/zapret2/init.d/sysv/zapret"
chmod +x "$WORK/zapret2/init.d/sysv/zapret"

# Заглушки утилит: ip/ndmc отдают заранее заданные файлы (пустые = нет PBR).
cat > "$BIN/lsmod" <<'EOF'
#!/bin/sh
cat "$LSMOD_FILE" 2>/dev/null || true
EOF
cat > "$BIN/insmod" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$BIN/modprobe" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$BIN/ip" <<'EOF'
#!/bin/sh
case "$*" in
  *rule*) cat "$IP_RULES" 2>/dev/null ;;
esac
exit 0
EOF
cat > "$BIN/ndmc" <<'EOF'
#!/bin/sh
cat "$POLICY_OUT" 2>/dev/null || true
EOF
chmod +x "$BIN"/*
: > "$LSMOD_FILE"
: > "$POLICY_OUT"
: > "$IP_RULES"
printf 'NFQUEUE MARK MASQUERADE CONNMARK NDMMARK\n' > "$TARGETS"

# Фейковый nfqws2: запоминает argv.
cat > "$WORK/fake-nfqws2" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" > "$ARGV_LOG"
EOF
chmod +x "$WORK/fake-nfqws2"

# Заглушка библиотеки zapret2: do_start -> run_daemon (его переопределяет
# Entware/zapret, там и происходит подстановка bind-fix).
cat > "$WORK/zapret2/init.d/sysv/functions" <<EOF
INIT_APPLY_FW=0
PIDDIR="$WORK/run"
zapret_run_daemons() { run_daemon 1 "$WORK/fake-nfqws2" "\${FAKE_ARGS:---qnum=300 --lua-init=@x}"; }
zapret_apply_firewall() { :; }
zapret_stop_daemons() { :; }
zapret_unapply_firewall() { :; }
EOF

fail() { echo "FAIL: $*" >&2; exit 1; }

run_start() {
  : > "$ARGV_LOG"
  PATH="$BIN:$PATH" \
  POLICY_OUT="$POLICY_OUT" \
  IP_RULES="$IP_RULES" \
  LSMOD_FILE="$LSMOD_FILE" \
  Z2R_MODULE_DIRS="$MODS" \
  Z2R_IPT_TARGETS="$TARGETS" \
  sh "$WORK/zapret2/init.d/sysv/zapret" start >/dev/null 2>&1 || true
  local i=0
  while [ ! -s "$ARGV_LOG" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  cat "$ARGV_LOG" 2>/dev/null || true
}

# --- 1. PBR по нескольким WAN: префикс добавляется -----------------------
: > "$POLICY_OUT"
: > "$IP_RULES"
args="$(IFACE_WAN="ppp0 ppp1" Z2R_KEENETIC_BINDFIX=auto run_start)"
case "$args" in
  "--bind-fix4 --bind-fix6 --qnum=300"*) ;;
  *) fail "ожидался префикс bind-fix при двух WAN, получено: '$args'" ;;
esac

# --- 2. один WAN, политик нет: префикса нет ------------------------------
args="$(IFACE_WAN="ppp0" Z2R_KEENETIC_BINDFIX=auto run_start)"
[ "$args" = "--qnum=300 --lua-init=@x" ] || fail "при одном WAN bind-fix лишний: '$args'"

# --- 3. PBR по политикам Keenetic ---------------------------------------
printf '           policy, name = Policy3:\n                 mark: ffffaad\n' > "$POLICY_OUT"
args="$(IFACE_WAN="ppp0" Z2R_KEENETIC_BINDFIX=auto run_start)"
case "$args" in "--bind-fix4"*) ;; *) fail "PBR по политикам не обнаружен: '$args'" ;; esac

# --- 4. PBR по fwmark-правилам ip rule ----------------------------------
: > "$POLICY_OUT"
printf '1152:\tfrom all fwmark 0xffffaad lookup 4102\n' > "$IP_RULES"
args="$(IFACE_WAN="ppp0" Z2R_KEENETIC_BINDFIX=auto run_start)"
case "$args" in "--bind-fix4"*) ;; *) fail "PBR по ip rule не обнаружен: '$args'" ;; esac

# --- 5. принудительное включение без PBR --------------------------------
: > "$IP_RULES"
args="$(IFACE_WAN="ppp0" Z2R_KEENETIC_BINDFIX=1 run_start)"
case "$args" in "--bind-fix4"*) ;; *) fail "режим 1 не включил bind-fix: '$args'" ;; esac

# --- 6. принудительное выключение при PBR -------------------------------
args="$(IFACE_WAN="ppp0 ppp1" Z2R_KEENETIC_BINDFIX=0 run_start)"
[ "$args" = "--qnum=300 --lua-init=@x" ] || fail "режим 0 не выключил bind-fix: '$args'"

# --- 7. опция уже в аргументах: без дубля -------------------------------
args="$(IFACE_WAN="ppp0 ppp1" Z2R_KEENETIC_BINDFIX=auto \
        FAKE_ARGS="--qnum=300 --bind-fix4 --bind-fix6 --lua-init=@x" run_start)"
count="$(printf '%s' "$args" | grep -o -- '--bind-fix4' | wc -l | tr -d ' ')"
[ "$count" = "1" ] || fail "bind-fix задублирован ($count): '$args'"

exit 0
