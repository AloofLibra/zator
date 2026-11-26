#!/usr/bin/env bash
# Entware/zapret: загрузчик модулей ядра должен
#  * искать .ko и в /lib/modules, и в /lib/system-modules (NDMS 5.1.x),
#  * не завершать старт с exit 1, если модуля нет (иначе после обновления
#    прошивки роутер остаётся без правил, хотя мог бы работать без них),
#  * предупреждать, если недоступен таргет CONNMARK (нужен
#    FILTER_TTL_EXPIRED_ICMP).
set -eu
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/bin"
LOCAL="$WORK/mods-local"
SYS="$WORK/mods-sys"
FAILMOD="$WORK/mods-fail"
mkdir -p "$BIN" "$LOCAL" "$SYS" "$FAILMOD" "$WORK/zapret2/init.d/sysv"

cp "$REPO_DIR/Entware/zapret" "$WORK/zapret2/init.d/sysv/zapret"
chmod +x "$WORK/zapret2/init.d/sysv/zapret"

# Заглушки библиотеки функций zapret2: проверяем только do_start.
cat > "$WORK/zapret2/init.d/sysv/functions" <<'EOF'
INIT_APPLY_FW=1
zapret_run_daemons() { echo "DAEMONS-STARTED"; }
zapret_apply_firewall() { echo "FW-APPLIED"; }
zapret_unapply_firewall() { echo "FW-REMOVED"; }
zapret_stop_daemons() { echo "DAEMONS-STOPPED"; }
EOF

# Заглушки утилит: lsmod читает файл, insmod пишет лог и падает на «fail».
cat > "$BIN/lsmod" <<'EOF'
#!/bin/sh
cat "$LSMOD_FILE" 2>/dev/null || true
EOF
cat > "$BIN/insmod" <<'EOF'
#!/bin/sh
echo "$1" >> "$INSMOD_LOG"
case "$1" in *fail*) exit 1 ;; esac
exit 0
EOF
cat > "$BIN/modprobe" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$BIN/lsmod" "$BIN/insmod" "$BIN/modprobe"

LSMOD_FILE="$WORK/lsmod"
INSMOD_LOG="$WORK/insmod.log"
TARGETS="$WORK/targets"
: > "$LSMOD_FILE"
: > "$INSMOD_LOG"
printf 'NFQUEUE NFQUEUE MARK MASQUERADE CONNMARK NDMMARK CONNNDMMARK PPE\n' > "$TARGETS"

run_start() {
  PATH="$BIN:$PATH" \
  Z2R_MODULE_DIRS="$LOCAL $SYS" \
  Z2R_IPT_TARGETS="$TARGETS" \
  LSMOD_FILE="$LSMOD_FILE" \
  INSMOD_LOG="$INSMOD_LOG" \
  sh "$WORK/zapret2/init.d/sysv/zapret" start
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- 1. модули лежат только в /lib/system-modules -------------------------
: > "$INSMOD_LOG"
for m in xt_multiport xt_connbytes xt_NFQUEUE; do : > "$SYS/$m.ko"; done
out="$(run_start)"
printf '%s' "$out" | grep -q 'xt_connbytes.ko loaded' || fail "нет сообщения о загрузке xt_connbytes из /lib/system-modules: $out"
grep -q "$SYS/xt_connbytes.ko" "$INSMOD_LOG" || fail 'insmod не вызывался с путём из /lib/system-modules'
printf '%s' "$out" | grep -q 'DAEMONS-STARTED' || fail 'демоны не запущены'
printf '%s' "$out" | grep -q 'FW-APPLIED' || fail 'firewall не применён'

# --- 2. модулей нет: предупреждения, но старт продолжается ----------------
rm -f "$SYS"/*.ko
: > "$INSMOD_LOG"
out="$(run_start)"
printf '%s' "$out" | grep -q 'Cannot find xt_connbytes' || fail 'нет предупреждения про xt_connbytes'
printf '%s' "$out" | grep -qi 'aborting' && fail 'не должно быть aborting'
printf '%s' "$out" | grep -q 'DAEMONS-STARTED' || fail 'при отсутствии модулей старт должен продолжаться'
printf '%s' "$out" | grep -q 'FW-APPLIED' || fail 'firewall должен применяться и без модулей'

# --- 3. модуль уже загружен: insmod не вызывается ------------------------
printf 'xt_connbytes 1949 26\nxt_NFQUEUE 4060 30\n' > "$LSMOD_FILE"
: > "$INSMOD_LOG"
out="$(run_start)"
printf '%s' "$out" | grep -q 'xt_connbytes.ko is already loaded' || fail 'нет сообщения «already loaded»'
grep -q 'xt_connbytes' "$INSMOD_LOG" && fail 'insmod вызван для уже загруженного модуля'
: > "$LSMOD_FILE"

# --- 4. insmod падает: пробуем дальше, заканчиваем предупреждением -------
: > "$FAILMOD/xt_connbytes.ko"
out="$(PATH="$BIN:$PATH" Z2R_MODULE_DIRS="$FAILMOD" Z2R_IPT_TARGETS="$TARGETS" \
      LSMOD_FILE="$LSMOD_FILE" INSMOD_LOG="$INSMOD_LOG" \
      sh "$WORK/zapret2/init.d/sysv/zapret" start)"
printf '%s' "$out" | grep -q 'Cannot find xt_connbytes' || fail 'падение insmod должно давать предупреждение'
printf '%s' "$out" | grep -q 'DAEMONS-STARTED' || fail 'падение insmod не должно останавливать старт'

# --- 5. нет таргета CONNMARK: предупреждение -----------------------------
printf 'NFQUEUE MARK MASQUERADE\n' > "$TARGETS"
out="$(run_start)"
printf '%s' "$out" | grep -q 'CONNMARK target is not available' || fail 'нет предупреждения про CONNMARK'

exit 0
