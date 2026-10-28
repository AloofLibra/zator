#!/usr/bin/env bash
# Изолированные пробы не меняют рабочие локи и не откатывают изменения меню.
set -euo pipefail
export Z2R_SUPERSWEEP_MEDIA=0 # Здесь mock TLS/iptables; подписанные media URL проверяются отдельно.
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap '[ "${SMOKE_KEEP:-0}" = 1 ] || rm -rf "$TMP"' EXIT
export Z2R_SUPERSWEEP_DIR="$TMP/run" ZATOR_ROOT="$TMP/zator" ZAPRET2_ROOT="$TMP/zapret2"
mkdir -p "$Z2R_SUPERSWEEP_DIR/probe" "$ZATOR_ROOT/lua" "$ZAPRET2_ROOT"
export ORCH_DIR="$TMP/live" ORCH_LOCK_FILE="$TMP/live/locked.tsv" CONFIG_FILE="$TMP/config"
mkdir -p "$ORCH_DIR"
printf '1\ttls\t7\n' > "$ORCH_LOCK_FILE"
source lib/config.sh
source lib/orchestra_state.sh
source lib/netcheck.sh
source lib/supersweep.sh
export Z2R_SUPERSWEEP_ISOLATED=1
printf 'r|1\nprofile|1|tls|2\n' > "$Z2R_SUPERSWEEP_DIR/cmd.yt"
_supersweep_apply_cmd "$Z2R_SUPERSWEEP_DIR/cmd.yt"
grep -q $'^1\ttls\t7$' "$ORCH_LOCK_FILE" || { echo 'FAIL: probe changed production lock'; exit 1; }
grep -q $'^1\ttls\t2$' "$Z2R_SUPERSWEEP_DIR/probe/locked.tsv"
(
    orch_locked_set() { return 1; }
    printf 'r|1\nprofile|1|tls|2\n' > "$Z2R_SUPERSWEEP_DIR/cmd.bad"
    ! _supersweep_apply_cmd "$Z2R_SUPERSWEEP_DIR/cmd.bad"
    [ ! -e "$Z2R_SUPERSWEEP_DIR/applied.bad" ]
)
rm -f "$Z2R_SUPERSWEEP_DIR/cmd.bad"
printf 'profile|1|tls|3\n' > "$Z2R_SUPERSWEEP_DIR/prev.tsv"
_supersweep_restore_prev
 grep -q $'^1\ttls\t7$' "$ORCH_LOCK_FILE"
# The same TLS engine must steer both HEAD and download; ordinary checks unchanged.
curl() { printf '%s\n' "$*" >> "$TMP/curl.args"; printf '206 64 1'; }
export Z2R_TLS_LOCAL_PORTS=62000-62999
z2r_tls_head_once https://example.com/ "$TMP/h" >/dev/null
z2r_tls_probe_download https://example.com/ >/dev/null
[ "$(grep -c -- '--local-port 62000-62999' "$TMP/curl.args")" = 2 ]
z2r_media_api https://www.youtube.com/youtubei/v1/visitor_id "$TMP/request" "$TMP/visitor" >/dev/null
z2r_media_api https://www.youtube.com/youtubei/v1/player "$TMP/request" "$TMP/player" >/dev/null
[ "$(grep -c -- '--local-port 62000-62999' "$TMP/curl.args")" = 4 ]
unset Z2R_TLS_LOCAL_PORTS
z2r_tls_probe_download https://example.com/ >/dev/null
z2r_media_api https://www.youtube.com/youtubei/v1/visitor_id "$TMP/request" "$TMP/visitor" >/dev/null
[ "$(grep -c -- '--local-port' "$TMP/curl.args")" = 4 ]
# Resolver uses the winning YT plan, never the last tested plan or the GV plan.
for resolver_case in winner no_winner resolve_fail start_fail lock_fail stop_fail; do
(
    Z2R_SUPERSWEEP_DIR="$TMP/resolver-$resolver_case"
    mkdir -p "$Z2R_SUPERSWEEP_DIR/probe"
    printf 'best=2\nbest_kind=ok\n' > "$Z2R_SUPERSWEEP_DIR/best.yt"
    [ "$resolver_case" != no_winner ] || echo 'best=' > "$Z2R_SUPERSWEEP_DIR/best.yt"
    supersweep_probe_start() {
        echo "start:$1" >> "$Z2R_SUPERSWEEP_DIR/events"
        test "$1" = 1
        [ "$resolver_case" != start_fail ] || return 1
        export Z2R_TLS_LOCAL_PORTS=62000-62999
    }
    supersweep_probe_stop() {
        echo stop >> "$Z2R_SUPERSWEEP_DIR/events"
        unset Z2R_TLS_LOCAL_PORTS
        [ "$resolver_case" != stop_fail ]
    }
    _supersweep_settle() { echo settle >> "$Z2R_SUPERSWEEP_DIR/events"; }
    if [ "$resolver_case" = lock_fail ]; then orch_locked_set() { return 1; }; fi
    z2r_media_prepare() {
        if [ "$resolver_case" = no_winner ]; then
            test -z "${Z2R_TLS_LOCAL_PORTS:-}"
        else
            test "$Z2R_TLS_LOCAL_PORTS" = 62000-62999
            grep -q $'^1\ttls\t2$' "$Z2R_SUPERSWEEP_DIR/probe/locked.tsv"
            grep -q $'^1\thttp\t2$' "$Z2R_SUPERSWEEP_DIR/probe/locked.tsv"
        fi
        grep -q $'^1\ttls\t7$' "$ORCH_LOCK_FILE"
        echo resolve >> "$Z2R_SUPERSWEEP_DIR/events"
        [ "$resolver_case" != resolve_fail ] || return 1
        Z2R_MEDIA_READY=1
    }
    rc=0; _supersweep_prepare_media "$CONFIG_FILE" > "$TMP/resolver.log" 2>&1 || rc=$?
    case "$resolver_case" in
        winner|resolve_fail)
            test "$rc" = 0
            test "$(cat "$Z2R_SUPERSWEEP_DIR/events")" = $'start:1\nsettle\nresolve\nstop'
            if [ "$resolver_case" = winner ]; then test "$Z2R_MEDIA_READY" = 1
            else test "$Z2R_MEDIA_READY" = 0; grep -q resolver_unavailable "$Z2R_SUPERSWEEP_DIR/media-status"; fi ;;
        no_winner) test "$rc" = 0; test "$(cat "$Z2R_SUPERSWEEP_DIR/events")" = resolve ;;
        *) test "$rc" = 1; test "$resolver_case" = stop_fail || ! grep -q '^resolve$' "$Z2R_SUPERSWEEP_DIR/events" ;;
    esac
    test -z "${Z2R_TLS_LOCAL_PORTS:-}"
) || { cat "$TMP/resolver.log" >&2; echo "FAIL: resolver route $resolver_case" >&2; exit 1; }
done
# Build from deployed source, not develop strategies or its adaptive extensions.
source lib/supersweep_probe.sh
# RKN must retain isolation errors in the run log, just like profile workers.
(
    Z2R_SUPERSWEEP_DIR="$TMP/rkn-error"
    mkdir -p "$Z2R_SUPERSWEEP_DIR"
    : > "$Z2R_SUPERSWEEP_DIR/coverage.tsv"
    _supersweep_request_lock() { return 0; }
    _supersweep_settle() { :; }
    _supersweep_check_target() {
        echo 'probe isolation failure' >&2
        : > "$Z2R_SUPERSWEEP_DIR/cancel"
        return 1
    }
    _supersweep_worker_rkn rkn 1 1 both 0 example.com 2> "$TMP/rkn-error.log"
    grep -q 'probe isolation failure' "$TMP/rkn-error.log"
) || { echo 'FAIL: RKN discarded the probe error' >&2; exit 1; }
# Router BusyBox can reject fractional sleep; no unguarded fractional waits.
if grep -nE 'sleep [0-9]+\.[0-9]+[[:space:]]*$' lib/supersweep_probe.sh lib/orchestra_state.sh; then
    echo 'FAIL: unguarded fractional sleep on router' >&2
    exit 1
fi
# A missing-traffic probe is retried on the same target; only its retry is returned.
for first_rc in 6 28; do
(
    Z2R_SUPERSWEEP_DIR="$TMP/retry-$first_rc"
    mkdir -p "$Z2R_SUPERSWEEP_DIR/probe"
    Z2R_SUPERSWEEP_QUEUE_FILE="$TMP/retry-queue"
    : > "$Z2R_SUPERSWEEP_QUEUE_FILE"
    FWTYPE=iptables
    iptables-save() { :; }
    ip() { :; }
    supersweep_probe_healthy() { return 0; }
    printf '0\n' > "$TMP/retry-count"
    supersweep_probe_sequence() {
        if [ "$(cat "$TMP/retry-count")" -lt 2 ]; then echo 0; else echo 1; fi
    }
    z2r_tls_check_target() {
        [ "$1" = https://example.com/ ] || return 1
        local count=$(( $(cat "$TMP/retry-count") + 1 ))
        printf '%s\n' "$count" > "$TMP/retry-count"
        [ ! -e "$Z2R_SUPERSWEEP_DIR/cancel" ] || return 1
        if [ "$count" = 1 ]; then
            printf '%s|000|-|-|-\n%s|000|-|-|-\nskip\n' "$first_rc" "$first_rc"
        else
            printf '0|200|HTTP/2|0.1|192.0.2.1\n0|200|HTTP/2|0.1|192.0.2.1\nskip\n'
        fi
    }
    out="$(_supersweep_check_target https://example.com/)" || exit 1
    [ "$(cat "$TMP/retry-count")" = 2 ]
    [ ! -e "$Z2R_SUPERSWEEP_DIR/cancel" ]
    [ "$out" = $'0|200|HTTP/2|0.1|192.0.2.1\n0|200|HTTP/2|0.1|192.0.2.1\nskip' ]
) || { echo 'FAIL: missing-traffic retry lost a working strategy' >&2; exit 1; }
done
# Cleanup failures remain retryable and must prevent starting the next phase.
for result in green warn http; do
(
    FWTYPE=iptables
    Z2R_SUPERSWEEP_QUEUE_FILE="$TMP/snapshot-queue"
    printf '65535 123 0 2 65531 0 0 0 1\n' > "$Z2R_SUPERSWEEP_QUEUE_FILE"
    iptables-save() { echo 'mangle counters snapshot'; }
    ip() { printf 'ip %s\n' "$*"; }
    supersweep_probe_healthy() { return 0; }
    supersweep_probe_sequence() { echo 0; }
    : > "$TMP/noqueue-calls"
    z2r_tls_check_target() {
        echo call >> "$TMP/noqueue-calls"
        case "$result" in
            green) printf '0|200|HTTP/2|0.1|192.0.2.1\n0|200|HTTP/2|0.1|192.0.2.1\nskip\n' ;;
            warn) printf '0|200|HTTP/2|0.1|192.0.2.1\n28|000|-|5|-\nskip\n' ;;
            http) printf '0|404|HTTP/2|0.1|192.0.2.1\n0|404|HTTP/2|0.1|192.0.2.1\nskip\n' ;;
        esac
    }
    ! _supersweep_check_target https://example.com/
    [ "$(wc -l < "$TMP/noqueue-calls")" = 2 ]
    [ -e "$Z2R_SUPERSWEEP_DIR/cancel" ]
    grep -q '^url=https://example.com/$' "$Z2R_SUPERSWEEP_DIR/probe/noqueue.log"
    grep -q '^sequence_before=0$' "$Z2R_SUPERSWEEP_DIR/probe/noqueue.log"
    grep -q '^sequence_after=0$' "$Z2R_SUPERSWEEP_DIR/probe/noqueue.log"
    grep -q '^0|' "$Z2R_SUPERSWEEP_DIR/probe/noqueue.log"
    grep -q '^65535 123 ' "$Z2R_SUPERSWEEP_DIR/probe/noqueue.log"
    grep -q '^mangle counters snapshot$' "$Z2R_SUPERSWEEP_DIR/probe/noqueue.log"
    grep -q '^ip route show table all$' "$Z2R_SUPERSWEEP_DIR/probe/noqueue.log"
    grep -q '^attempt=1$' "$Z2R_SUPERSWEEP_DIR/probe/noqueue.log"
    grep -q '^attempt=2$' "$Z2R_SUPERSWEEP_DIR/probe/noqueue.log"
)
rm -f "$Z2R_SUPERSWEEP_DIR/cancel"
done
# Even DNS failures get one retry rather than losing a potentially working strategy.
for rc in 6 7 28 35 45; do
(
    supersweep_probe_healthy() { return 0; }
    supersweep_probe_sequence() { echo 0; }
    : > "$TMP/noqueue-calls"
    z2r_tls_check_target() {
        echo call >> "$TMP/noqueue-calls"
        printf '%s|000|-|-|-\n%s|000|-|-|-\nskip\n' "$rc" "$rc"
    }
    ! _supersweep_check_target https://example.com/
    [ "$(wc -l < "$TMP/noqueue-calls")" = 2 ]
    [ -e "$Z2R_SUPERSWEEP_DIR/cancel" ]
    grep -q "^$rc|000|" "$Z2R_SUPERSWEEP_DIR/probe/noqueue.log"
) || exit 1
rm -f "$Z2R_SUPERSWEEP_DIR/cancel"
done
# A post-probe health failure invalidates the answer, even if health recovers.
for health_failure in transient reinstall repeated; do
(
    healthy_calls=0
    sleep() { :; }
    supersweep_probe_healthy() {
        healthy_calls=$((healthy_calls + 1))
        case "$health_failure:$healthy_calls" in
            transient:2|reinstall:[234]|repeated:[234789]) return 1 ;;
        esac
    }
    supersweep_transport_reinstall() { :; }
    printf '0\n' > "$TMP/reprobe-count"
    supersweep_probe_sequence() { cat "$TMP/reprobe-count"; }
    z2r_tls_check_target() {
        local count=$(( $(cat "$TMP/reprobe-count") + 1 ))
        printf '%s\n' "$count" > "$TMP/reprobe-count"
        printf 'answer-%s\n' "$count"
    }
    if out="$(_supersweep_check_target https://example.com/)"; then
        [ "$health_failure" != repeated ]
        [ "$out" = answer-2 ]
        [ ! -e "$Z2R_SUPERSWEEP_DIR/cancel" ]
    else
        [ "$health_failure" = repeated ]
        [ -z "$out" ]
        [ -e "$Z2R_SUPERSWEEP_DIR/cancel" ]
    fi
    [ "$(cat "$TMP/reprobe-count")" = 2 ]
)
rm -f "$Z2R_SUPERSWEEP_DIR/cancel"
done
# A failed health check must reinstall the transport and keep going.
(
    healthy_calls=0
    supersweep_probe_healthy() { healthy_calls=$((healthy_calls + 1)); [ "$healthy_calls" -ge 4 ]; }
    supersweep_transport_reinstall() { : > "$TMP/transport-reinstalled"; }
    printf '4
' > "$TMP/seqn"
    supersweep_probe_sequence() { echo $(( $(cat "$TMP/seqn") + 1 )) > "$TMP/seqn"; cat "$TMP/seqn"; }
    z2r_tls_check_target() { printf '0|200|HTTP/2|0.1|192.0.2.1\n0|200|HTTP/2|0.1|192.0.2.1\nskip\n'; }
    out="$(_supersweep_check_target https://example.com/)"
    [ -e "$TMP/transport-reinstalled" ]
    ! [ -e "$Z2R_SUPERSWEEP_DIR/cancel" ]
    printf '%s\n' "$out" | grep -q '0|200'
)
rm -f "$Z2R_SUPERSWEEP_DIR/cancel"
(
    supersweep_probe_healthy() { return 1; }
    supersweep_transport_reinstall() { :; }
    ! _supersweep_check_target https://example.com/ 2>/dev/null
    [ -e "$Z2R_SUPERSWEEP_DIR/cancel" ]
)
rm -f "$Z2R_SUPERSWEEP_DIR/cancel"
(
    printf 'best=1\nbest_kind=warn\ninterrupted=0\n' > "$Z2R_SUPERSWEEP_DIR/best.yt"
    [ -z "$(_supersweep_profile_best yt)" ]
    config_get_var() { echo 0; }
    profile_state_set_and_apply() { : > "$TMP/warn-applied"; }
    profile_strategy_restart_if_needed() { :; }
    telemetry_notify() { :; }
    _supersweep_settle_worker yt 1 'tls http' "$CONFIG_FILE"
    [ ! -e "$TMP/warn-applied" ]
    printf 'best=1\nbest_kind=best\ninterrupted=0\n' > "$Z2R_SUPERSWEEP_DIR/best.yt"
    [ "$(_supersweep_profile_best yt)" = 1 ]
)
(
    calls=0
    supersweep_transport_stop() { calls=$((calls + 1)); [ "$calls" -gt 3 ]; }
    Z2R_SUPERSWEEP_TRANSPORT_ACTIVE=1
    ! supersweep_probe_stop
    [ "$Z2R_SUPERSWEEP_TRANSPORT_ACTIVE" = 1 ]
    supersweep_probe_stop
    [ "$calls" = 4 ]
)
cp orchestra/locked.lua "$ZATOR_ROOT/lua/locked.lua"
tr -d '\r' < config.default > "$CONFIG_FILE"
mkdir -p "$ZAPRET2_ROOT/nfq2"
printf '#!/bin/sh\n[ "${1:-}" != --help ] || { printf " --autoexclude=[0|1]\\n"; exit 0; }\nexit 0\n' > "$ZAPRET2_ROOT/nfq2/nfqws2"
chmod +x "$ZAPRET2_ROOT/nfq2/nfqws2"
supersweep_probe_config 4 "$CONFIG_FILE"
grep -q -- '--lua-init=@.*/lua/zapret-auto.lua' "$Z2R_SUPERSWEEP_DIR/probe/nfqws2.args"
grep -q -- '--uid=65533:65533' "$Z2R_SUPERSWEEP_DIR/probe/nfqws2.args"
grep -q -- '--qnum=65535' "$Z2R_SUPERSWEEP_DIR/probe/nfqws2.args"
grep -q -- '--autoexclude=0' "$Z2R_SUPERSWEEP_DIR/probe/nfqws2.args"
grep -q -- '--blob=' "$Z2R_SUPERSWEEP_DIR/probe/nfqws2.args"
grep -q -- '--template=z2r_tcp_tls_common' "$Z2R_SUPERSWEEP_DIR/probe/nfqws2.args"
grep -qx -- '--new' "$Z2R_SUPERSWEEP_DIR/probe/nfqws2.args"
grep -q -- '--lua-desync=' "$Z2R_SUPERSWEEP_DIR/probe/nfqws2.args"
! grep -qE '^--lua-desync=[^ ]* --lua-desync=' "$Z2R_SUPERSWEEP_DIR/probe/nfqws2.args"
# A build without the autoexclude option must not receive it.
cat > "$ZAPRET2_ROOT/nfq2/nfqws2" <<'MOCK2'
#!/bin/sh
[ "${1:-}" != --help ] || { printf 'usage: nfqws2\n'; exit 0; }
exit 0
MOCK2
unset Z2R_SUPERSWEEP_AUTOEXCLUDE
supersweep_probe_config 4 "$CONFIG_FILE"
! grep -q -- '--autoexclude' "$Z2R_SUPERSWEEP_DIR/probe/nfqws2.args"
cat > "$ZAPRET2_ROOT/nfq2/nfqws2" <<'MOCK'
#!/bin/sh
[ "${1:-}" != --version ] || { echo 'nfqws2 smoke'; exit 0; }
[ "${1:-}" != --help ] || { printf 'usage: nfqws2\n --autoexclude=[0|1]\n'; exit 0; }
printf '%s\n' "$@" >> "$TMP/nfq.args"
printf '65535 0 0 2 65531 0 0 0 1\n' > "$Z2R_SUPERSWEEP_QUEUE_FILE"
echo "$$" >> "$TMP/nfq.pids"
trap ': > "$Z2R_SUPERSWEEP_QUEUE_FILE"; exit' TERM INT
while :; do sleep 0.1; done
MOCK
unset Z2R_SUPERSWEEP_AUTOEXCLUDE
supersweep_probe_config 4 "$CONFIG_FILE"
grep -q -- '--autoexclude=0' "$Z2R_SUPERSWEEP_DIR/probe/nfqws2.args"
(
    supersweep_transport_check() { return 0; }
    Z2R_SUPERSWEEP_NFQ_PID=$$
    printf 'LUA ERROR: missing runtime dependency\n' > "$Z2R_SUPERSWEEP_DIR/probe/nfqws2.log"
    ! supersweep_probe_healthy 2>/dev/null
)
rm -f "$Z2R_SUPERSWEEP_DIR/probe/nfqws2.log"
grep -q -- '--lua-desync=circular_locked:key=4' "$Z2R_SUPERSWEEP_DIR/probe/nfqws2.args"
grep -q -- 'strategy=25' "$Z2R_SUPERSWEEP_DIR/probe/nfqws2.args"
! grep -qE 'adaptive|circular_quality|validator=|hostlist=' "$Z2R_SUPERSWEEP_DIR/probe/nfqws2.args"
grep -Fq "$Z2R_SUPERSWEEP_DIR/probe/locked.tsv" "$Z2R_SUPERSWEEP_DIR/probe/locked.lua"
! grep -q '/opt/zator/extra_strats/cache/orchestra/locked' "$Z2R_SUPERSWEEP_DIR/probe/locked.lua"
supersweep_probe_config 3 "$CONFIG_FILE"
grep -q -- '--import=z2r_tcp_tls_common' "$Z2R_SUPERSWEEP_DIR/probe/nfqws2.args"
# Invalid/missing profile plans must fail, not silently test an empty plan.
! supersweep_probe_config 10 "$CONFIG_FILE"
# Detached runner is a real child bash; only nfqws2/firewall/network are mocked.
unset -f curl
mkdir -p "$TMP/bin" "$ZAPRET2_ROOT/nfq2"
export Z2R_SUPERSWEEP_QUEUE_FILE="$TMP/queue" Z2R_SUPERSWEEP_PORT_RANGE_FILE="$TMP/ports"
export Z2R_SUPERSWEEP_PHASE_PAUSE=0 Z2R_SUPERSWEEP_PROBE_GAP=0 Z2R_SUPERSWEEP_GREEN_PAUSE=0 Z2R_SUPERSWEEP_SETTLE=0
export Z2R_SUPERSWEEP_STATS_URL='' Z2R_SUPERSWEEP_ARCHIVE_DIR="$TMP/archives"
export LIB_DIR="$PWD/lib" TMP
printf '32768 60999\n' > "$TMP/ports"
: > "$TMP/queue"
cat > "$ZAPRET2_ROOT/nfq2/nfqws2" <<'MOCK'
#!/bin/sh
[ "${1:-}" != --version ] || { echo 'nfqws2 smoke'; exit 0; }
[ "${1:-}" != --help ] || { printf 'usage: nfqws2\n --autoexclude=[0|1]\n'; exit 0; }
printf '%s\n' "$@" >> "$TMP/nfq.args"
printf '65535 0 0 2 65531 0 0 0 1\n' > "$Z2R_SUPERSWEEP_QUEUE_FILE"
echo "$$" >> "$TMP/nfq.pids"
trap ': > "$Z2R_SUPERSWEEP_QUEUE_FILE"; exit' TERM INT
while :; do sleep 0.1; done
MOCK
cat > "$TMP/bin/iptables" <<'MOCK'
#!/bin/sh
echo "$*" >> "$TMP/iptables.args"
case "$*" in
    *' -S') printf '%s\n' '-A POSTROUTING -j Z2R_SS_POST' '-A INPUT -j Z2R_SS_IN' ;;
esac
MOCK
# OpenWrt may have setsid but no nohup; inherited ignored HUP is sufficient.
cat > "$TMP/bin/nohup" <<'MOCK'
#!/bin/sh
echo 'FAIL: background launch still requires nohup' >&2
exit 127
MOCK
cat > "$TMP/bin/curl" <<'MOCK'
#!/bin/sh
case "$*" in *report_mapping*) exit 0 ;; esac
echo "$*" >> "$TMP/network.args"
printf '%s\n' "${Z2R_MEDIA_VIDEO_ID:-missing}" > "$TMP/video.id"
sleep "${MOCK_BG_DELAY:-0.1}"
seq="$(awk '$1==65535 {print $8}' "$Z2R_SUPERSWEEP_QUEUE_FILE")"
printf '65535 0 0 2 65531 0 0 %s 1\n' "$(( ${seq:-0} + 1 ))" > "$Z2R_SUPERSWEEP_QUEUE_FILE.$$"
mv "$Z2R_SUPERSWEEP_QUEUE_FILE.$$" "$Z2R_SUPERSWEEP_QUEUE_FILE"
prev=''
for arg in "$@"; do
    [ "$prev" != -D ] || printf 'HTTP/2 200\r\n' > "$arg"
    prev="$arg"
done
case "$*" in *' -I '*) echo '0.1 192.0.2.1' ;; *) echo '206 64 0.1' ;; esac
MOCK
chmod +x "$ZAPRET2_ROOT/nfq2/nfqws2" "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
# Keep one strategy per plan so this lifecycle check stays short.
sed -E '/strategy=([2-9]|[1-9][0-9]+)([^0-9]|$)/d' "$CONFIG_FILE" > "$TMP/trimmed"
mv "$TMP/trimmed" "$CONFIG_FILE"
# Match the submenu: selected scope is a shell variable, not an environment var.
export -n ORCH_ACTIVE_SCOPE
ORCH_ACTIVE_SCOPE=mark:5
Z2R_MEDIA_VIDEO_ID=M7lc1UVf-VE
export -n Z2R_MEDIA_VIDEO_ID
mkdir -p "$ORCH_DIR/scopes"
printf '1\ttls\t7\n' > "$ORCH_DIR/scopes/mark_5.tsv"
cp "$ORCH_LOCK_FILE" "$TMP/global.before"
cp "$CONFIG_FILE" "$TMP/config.before"
# A process may disappear after the /proc glob, before cmdline is opened.
scan_glob='/proc/[0-9]*/cmdline'
scan_source="$(sed -n '/^    local proc_cmdline/,/^    # Старые Entware/{ /^    # Старые Entware/!p; }' lib/supersweep_probe.sh)"
[ -n "$scan_source" ]
scan_source="${scan_source//"$scan_glob"/"$TMP/disappeared-proc/cmdline"}"
scan_missing_proc() { eval "$scan_source"; }
scan_missing_proc 2>"$TMP/proc.error"
[ ! -s "$TMP/proc.error" ]
# A live runner without its lock must be found in NUL-separated argv.
bash -c 'while :; do sleep 0.1; done' "$TMP/supersweep_probe.sh" --run &
stale_pid=$!
sleep 0.1
stale_rc=0
supersweep_background_start "$CONFIG_FILE" both 0 0 0 1 example.com 2>"$TMP/stale.error" || stale_rc=$?
kill "$stale_pid" 2>/dev/null || true
wait "$stale_pid" 2>/dev/null || true
[ "$stale_rc" != 0 ]
grep -q 'Обнаружен живой процесс' "$TMP/stale.error"
[ ! -d "$Z2R_SUPERSWEEP_DIR.lock" ]
supersweep_background_start "$CONFIG_FILE" both 0 0 0 1 example.com
[ -d "$Z2R_SUPERSWEEP_DIR.lock" ]
! supersweep_background_start "$CONFIG_FILE" both 0 0 0 1 example.com 2>/dev/null
for ((i=0; i<200; i++)); do
    [ -s "$TMP/network.args" ] && break
    sleep 0.1
done
grep -q -- '--qnum=65535' "$TMP/nfq.args"
grep -q -- '--uid=65533:65533' "$TMP/nfq.args"
grep -q -- '--lua-init=@' "$TMP/nfq.args"
grep -q -- '--import=' "$TMP/nfq.args"
grep -q -- '--lua-desync=circular_locked:key=1' "$TMP/nfq.args"
! grep -q '^@' "$TMP/nfq.args"
[ "$(grep -cx -- '--new' "$TMP/nfq.args")" = 1 ]
printf 'r|99\nprofile|invalid|tls|1\n' > "$Z2R_SUPERSWEEP_DIR/cmd.yt.tmp.poison"
for ((i=0; i<1800; i++)); do
    [ -d "$Z2R_SUPERSWEEP_DIR.lock" ] || break
    sleep 0.1
done
[ ! -d "$Z2R_SUPERSWEEP_DIR.lock" ] || { cat "$Z2R_SUPERSWEEP_DIR.log"; exit 1; }
grep -q '^state=done$' "$Z2R_SUPERSWEEP_DIR/status" || { cat "$Z2R_SUPERSWEEP_DIR.log"; exit 1; }
[ -s "$Z2R_SUPERSWEEP_ARCHIVE_DIR/last-report.tsv" ] || { echo 'FAIL: completed run did not persist its report' >&2; exit 1; }
supersweep_report_json > "$TMP/completed-report.json"
python3 - "$TMP/completed-report.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r['state']=='done' and not r['active'] and r['scope']=='mark:5'
assert r['completed']==r['total'] and len(r['workers'])==4
assert {a['target'] for a in r['applied'] if a['kind']=='profile'}=={'1','2','3','4'}
PY
[ "$(wc -l < "$TMP/nfq.pids")" = 4 ]
test "$(cat "$TMP/video.id")" = M7lc1UVf-VE
grep -q -- '--local-port 62000-62999' "$TMP/network.args"
grep -q -- '-D OUTPUT' "$TMP/iptables.args"
while read -r pid; do ! kill -0 "$pid" 2>/dev/null; done < "$TMP/nfq.pids"
regression_failed=0
if ! cmp -s "$TMP/global.before" "$ORCH_LOCK_FILE" \
    || ! cmp -s "$TMP/config.before" "$CONFIG_FILE" \
    || ! grep -q $'^1\ttls\t1$' "$ORCH_DIR/scopes/mark_5.tsv" \
    || ! grep -q $'^2\ttls\t1$' "$ORCH_DIR/scopes/mark_5.tsv" \
    || ! grep -q $'^4\ttls\t1$' "$ORCH_DIR/scopes/mark_5.tsv" \
    || ! grep -q $'^3\ttls\t1$' "$ORCH_DIR/scopes/mark_5.tsv"; then
    echo 'FAIL: detached winners lost selected scope or changed global state' >&2
    regression_failed=1
fi
grep -q $'^example.com\ttls\t1$' "$Z2R_SUPERSWEEP_DIR/probe/locked.tsv"
[ ! -d "$Z2R_SUPERSWEEP_DIR/probe/scopes" ]
# Cancel a detached run during its first probe; no production rollback/write.
printf '1\ttls\t7\n' > "$ORCH_LOCK_FILE"
: > "$TMP/network.args"
export MOCK_BG_DELAY=1
(
    # Also exercise the Entware fallback without setsid or a controlling tty.
    command() {
        [ "$*" != '-v setsid' ] || return 1
        builtin command "$@"
    }
    supersweep_background_start "$CONFIG_FILE" both 0 0 0 1 example.com
)
for ((i=0; i<200; i++)); do
    [ -s "$TMP/network.args" ] && break
    sleep 0.1
done
[ -s "$TMP/network.args" ]
kill -HUP "$(cat "$Z2R_SUPERSWEEP_DIR.lock/pid")"
kill -INT "$(cat "$Z2R_SUPERSWEEP_DIR.lock/pid")"
supersweep_cancel_running
for ((i=0; i<1800; i++)); do
    [ -d "$Z2R_SUPERSWEEP_DIR.lock" ] || break
    sleep 0.1
done
[ ! -d "$Z2R_SUPERSWEEP_DIR.lock" ]
grep -q '^state=cancelled$' "$Z2R_SUPERSWEEP_DIR/status"
grep -q $'^1\ttls\t7$' "$ORCH_LOCK_FILE"
[ ! -s "$Z2R_SUPERSWEEP_DIR/applied.tsv" ]
rm -rf "$Z2R_SUPERSWEEP_DIR"
supersweep_report_json | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["state"]=="cancelled" and r["source"]=="saved" and not r["active"] and r["applied"]==[]'
# TERM targets the exact PID advertised to callers, not an inferred worker PID.
: > "$TMP/network.args"
cp "$ORCH_LOCK_FILE" "$TMP/term.global.before"
cp "$ORCH_DIR/scopes/mark_5.tsv" "$TMP/term.scope.before"
supersweep_background_start "$CONFIG_FILE" both 0 0 0 1 example.com
for ((i=0; i<200; i++)); do
    [ -s "$TMP/network.args" ] && break
    sleep 0.1
done
[ -s "$TMP/network.args" ]
published_pid="$(cat "$Z2R_SUPERSWEEP_DIR.lock/pid")"
# Retain children only to clean up the intentionally broken RED run.
children="$(ps --ppid "$published_pid" -o pid=)"
worker_pid="$(ps --ppid "$published_pid" -o pid=,comm= | awk '$2=="bash" {print $1; exit}')"
[ -n "$worker_pid" ]
nfq_pid="$(tail -n1 "$TMP/nfq.pids")"
deletes_before="$(grep -c -- '-D OUTPUT' "$TMP/iptables.args")"
kill -TERM "$published_pid"
for ((i=0; i<100; i++)); do
    [ -d "$Z2R_SUPERSWEEP_DIR.lock" ] || break
    sleep 0.1
done
if [ -d "$Z2R_SUPERSWEEP_DIR.lock" ] || kill -0 "$nfq_pid" 2>/dev/null \
    || kill -0 "$worker_pid" 2>/dev/null \
    || [ "$(grep -c -- '-D OUTPUT' "$TMP/iptables.args")" -le "$deletes_before" ]; then
    echo 'FAIL: TERM to published PID left its daemon/firewall/lock alive' >&2
    regression_failed=1
    touch "$Z2R_SUPERSWEEP_DIR/cancel"
    kill -TERM $children 2>/dev/null || true
fi
wait "$published_pid" 2>/dev/null || true
for ((i=0; i<100; i++)); do
    [ -d "$Z2R_SUPERSWEEP_DIR.lock" ] || break
    sleep 0.1
done
[ ! -d "$Z2R_SUPERSWEEP_DIR.lock" ]
! kill -0 "$nfq_pid" 2>/dev/null
! kill -0 "$worker_pid" 2>/dev/null
cmp "$TMP/term.global.before" "$ORCH_LOCK_FILE"
cmp "$TMP/term.scope.before" "$ORCH_DIR/scopes/mark_5.tsv"
rm -rf "$Z2R_SUPERSWEEP_DIR"
supersweep_report_json | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["state"]=="interrupted" and r["source"]=="saved" and not r["active"] and r["applied"]==[]'
[ "$regression_failed" = 0 ]
# ensure_nfqws2_stopped must not murder the isolated probe by name.
sed -n '/^ensure_nfqws2_stopped()/,/^}/p' z2r.sh > "$TMP/ensure.sh"
grep -q 'qnum=65535' "$TMP/ensure.sh"
! grep -qE 'killall|pkill' "$TMP/ensure.sh"
# The ndm hook must reinstall probe transport while a run is live.
grep -q 'supersweep_transport_reconcile' Entware/000-zapret2.sh
grep -q 'transport.env' Entware/000-zapret2.sh
sh -n Entware/000-zapret2.sh
# Probe lifecycle must publish/remove the hook env file.
sed -n '/^supersweep_probe_stop()/,/^}/p' lib/supersweep_probe.sh > "$TMP/pstop.sh"
grep -q 'rm -f.*transport.env' "$TMP/pstop.sh"
grep -q 'transport.env' lib/supersweep_probe.sh
echo 'supersweep background smoke ok'
