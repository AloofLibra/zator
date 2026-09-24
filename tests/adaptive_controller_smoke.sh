#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
controller_pid=
cleanup() {
  [ -z "$controller_pid" ] || kill -TERM "$controller_pid" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM

${CC:-cc} -std=c99 -O2 -Wall -Wextra -Werror \
  -o "$TMP/adaptive-controller" "$ROOT/tools/adaptive_controller.c"

record() {
  ts=$1 event=$2 flow=$3 strategy=$4 host=$5 bytes=$6 reason=$7
  profile=0 generation=0
  [ "$strategy" -eq 0 ] || { profile=2; generation=1; }
  payload=0
  [ "$bytes" -eq 0 ] || payload=1
  printf 'v2\t%s\t%s\t%s\t%s\t%s\t%s\tdefault\t%s\ttcp\tipv4\t203.0.113.4\t443\t5\t3\t300\t%s\t1\t%s\t0\t0\t1\t1\t900\t1000\t1\t0\t%s\n' \
    "$ts" "$event" "$flow" "$profile" "$strategy" "$generation" \
    "$host" "$bytes" "$payload" "$reason"
}

{
  record 1000 FLOW_START 1 0 "" 0 ""
  record 1000 STRATEGY_APPLIED 1 7 "" 0 ""
  record 1000 FLOW_END 1 7 example.test 500 process_exit
  record 12000 FLOW_START 2 0 "" 0 ""
  record 12000 STRATEGY_APPLIED 2 7 example.test 0 ""
  record 12000 FLOW_END 2 7 example.test 400 timeout_established
  record 23000 FLOW_START 3 0 "" 0 ""
  record 23000 STRATEGY_APPLIED 3 9 example.test 0 ""
  record 23000 FLOW_END 3 9 example.test 300 process_exit
  record 34000 FLOW_START 4 0 "" 0 ""
  record 34000 STRATEGY_APPLIED 4 9 example.test 0 ""
  record 34000 FLOW_END 4 9 example.test 300 process_exit
} | "$TMP/adaptive-controller" > "$TMP/out"

grep -q 'FLOW_OUTCOME.*WEAK_SUCCESS.*SHADOW_INITIAL_CHAMPION' "$TMP/out" || {
  cat "$TMP/out" >&2
  echo "controller failed to establish the shadow champion" >&2
  exit 1
}
grep -q 'FLOW_OUTCOME.*CHALLENGER_OBSERVED' "$TMP/out" || {
  cat "$TMP/out" >&2
  echo "controller failed to report challenger evidence" >&2
  exit 1
}
awk -F '\t' '$1 == "FLOW_OUTCOME" && $4 == 9 && $10 == "CHALLENGER_READY" { if ($8 != 7 || $9 != 9 || $12 != 33333 || $13 != 2 || $14 != 2 || $15 != 7 || $16 != "NONE") exit 1; found=1 } END { exit !found }' "$TMP/out" || {
  cat "$TMP/out" >&2
  echo "challenger evidence promoted or obscured the incumbent champion" >&2
  exit 1
}
awk -F '\t' '$1 == "FLOW_OUTCOME" && $10 == "SHADOW_INITIAL_CHAMPION" { if ($12 != 33333 || $13 != 1 || $14 != 1 || $15 != 7 || $16 != "NONE" || $18 != "default" || $19 != "tcp" || $20 != "ipv4" || $21 != "unknown") exit 1; found=1 } END { exit !found }' "$TMP/out" || {
  cat "$TMP/out" >&2
  echo "controller confidence, rank, or quarantine output is inconsistent" >&2
  exit 1
}

record 30000 FLOW_START 99 0 "" 0 "" | "$TMP/adaptive-controller" > "$TMP/incomplete"
grep -q '^TRACE_INCOMPLETE.*open_flows=1$' "$TMP/incomplete" || {
  cat "$TMP/incomplete" >&2
  echo "controller did not flag an unmatched flow start" >&2
  exit 1
}

{
  record 40000 STRATEGY_APPLIED 100 7 example.test 0 ""
  record 40000 FLOW_END 100 7 example.test 600 process_exit
} | "$TMP/adaptive-controller" > "$TMP/missing-start"
grep -q 'UNATTRIBUTED' "$TMP/missing-start" || {
  cat "$TMP/missing-start" >&2
  echo "controller trained from a flow without FLOW_START" >&2
  exit 1
}

{
  record 45000 FLOW_START 101 0 "" 0 ""
  record 45000 STRATEGY_APPLIED 101 13 unknown.test 0 ""
  record 45000 FLOW_END 101 13 unknown.test 0 timeout_established
} | "$TMP/adaptive-controller" > "$TMP/unknown"
awk -F '\t' '$1 == "FLOW_OUTCOME" { if ($6 != "UNKNOWN" || $12 != 0 || $13 != 0 || $15 != 0) exit 1; found=1 } END { exit !found }' "$TMP/unknown" || {
  cat "$TMP/unknown" >&2
  echo "unknown evidence was ranked as a working candidate" >&2
  exit 1
}

i=1
while [ "$i" -le 257 ]; do
  record 50000 FLOW_START "$i" 0 "" 0 ""
  i=$((i + 1))
done | "$TMP/adaptive-controller" > "$TMP/overflow"
grep -q '^CONTROLLER_OVERFLOW[[:space:]]open_flow_capacity$' "$TMP/overflow" || {
  cat "$TMP/overflow" >&2
  echo "controller did not report bounded open-flow capacity" >&2
  exit 1
}

cat > "$TMP/socket-sender.c" <<'SENDER'
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
int main(int argc, char **argv) {
  int fd;
  struct sockaddr_un addr;
  char line[2048];
  if (argc != 2 || strlen(argv[1]) >= sizeof(addr.sun_path)) return 2;
  fd = socket(AF_UNIX, SOCK_DGRAM, 0);
  if (fd < 0) return 1;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strcpy(addr.sun_path, argv[1]);
  while (fgets(line, sizeof(line), stdin))
    if (sendto(fd, line, strlen(line), 0, (struct sockaddr *)&addr, sizeof(addr)) < 0) return 1;
  close(fd);
  return 0;
}
SENDER
${CC:-cc} -std=c99 -O2 -Wall -Wextra -Werror \
  -o "$TMP/socket-sender" "$TMP/socket-sender.c"
"$TMP/adaptive-controller" --socket "$TMP/events.sock" > "$TMP/socket-out" &
controller_pid=$!
tries=0
while [ ! -S "$TMP/events.sock" ]; do
  tries=$((tries + 1))
  [ "$tries" -lt 10 ] || { echo "controller did not create its socket" >&2; exit 1; }
  sleep 1
done
if "$TMP/adaptive-controller" --socket "$TMP/events.sock" >/dev/null 2>&1; then
  echo "controller unexpectedly replaced an active socket" >&2
  exit 1
fi
[ -S "$TMP/events.sock" ] || { echo "active controller socket was unlinked" >&2; exit 1; }
{
  record 60000 FLOW_START 500 0 "" 0 ""
  record 60000 STRATEGY_APPLIED 500 7 socket.test 0 ""
  printf '# EVENT_GAP\t3\n'
  record 60001 FLOW_END 500 7 socket.test 800 process_exit
} | "$TMP/socket-sender" "$TMP/events.sock"
sleep 1
kill -TERM "$controller_pid"
wait "$controller_pid"
controller_pid=
grep -q '^TRACE_INCOMPLETE[[:space:]]event_gap[[:space:]]dropped=3[[:space:]]open_flows_discarded=1$' "$TMP/socket-out" || {
  cat "$TMP/socket-out" >&2
  echo "controller failed to invalidate open flows after an event gap" >&2
  exit 1
}
grep -q 'FLOW_OUTCOME.*UNATTRIBUTED' "$TMP/socket-out" || {
  cat "$TMP/socket-out" >&2
  echo "controller trained from flow evidence after a socket gap" >&2
  exit 1
}

printf '%s\n' "adaptive controller smoke ok"
