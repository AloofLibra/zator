#!/bin/sh
# Low-overhead opt-in scheduler driver. The C controller owns task selection;
# this process only wakes it periodically and runs a due bounded probe.

ZATOR_ROOT="${ZATOR_ROOT:-/opt/zator}"
ZAPRET2_ROOT="${ZAPRET2_ROOT:-/opt/zapret2}"
LIB="$ZATOR_ROOT/z2r_lib/adaptive_controller.sh"
LOG=/tmp/zator-adaptive/scheduler.log
stop_requested=0

[ -r "$LIB" ] || exit 1
. "$LIB" || exit 1
trap 'stop_requested=1' HUP INT TERM

while [ "$stop_requested" -eq 0 ] && [ -f "$ZATOR_ROOT/extra_strats/cache/adaptive-learning.enabled" ]; do
	if [ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null)" -ge 65536 ]; then : >"$LOG"; fi
	if [ -S /tmp/zator-adaptive/events.sock ] && [ -S /tmp/zator-adaptive-learning/control.sock ]; then
		adaptive_learning_scheduled_step "" >>"$LOG" 2>&1 || :
	fi
	sleep 3600
done
