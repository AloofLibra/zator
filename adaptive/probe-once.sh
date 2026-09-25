#!/bin/sh
# Send exactly one HTTPS request through the opt-in learning NFQUEUE.
# The source-port range must match adaptive/90-zator-adaptive-learning.

MAX_SECONDS=15
CONNECT_SECONDS=7
BODY_SAMPLE_LIMIT=16384
SOURCE_PORT_FIRST=62000
SOURCE_PORT_LAST=62015
SOURCE_PORT="$SOURCE_PORT_FIRST"
SOURCE_PORT_FILE=/tmp/zator-adaptive-learning/probe-port.next
LOCK_DIR=/tmp/zator-adaptive-learning/experiment.lock
ZATOR_ROOT="${ZATOR_ROOT:-/opt/zator}"
ADAPTIVE_LIB="$ZATOR_ROOT/z2r_lib/adaptive_controller.sh"
BODY_FIFO=/tmp/zator-adaptive-learning/probe-body-fifo.$$
BODY_FILE=/tmp/zator-adaptive-learning/probe-body.$$
BODY_STATUS=/tmp/zator-adaptive-learning/probe-status.$$
CURL_PID=

cleanup_probe()
{
	if [ -n "$CURL_PID" ]; then
		kill "$CURL_PID" 2>/dev/null || :
		wait "$CURL_PID" 2>/dev/null || :
	fi
	rm -f "$BODY_FIFO" "$BODY_FILE" "$BODY_STATUS"
	rmdir "$LOCK_DIR" 2>/dev/null || :
}

usage()
{
	echo "Usage: $0 hostname [--reported-result]" >&2
	exit 2
}

case "$#" in 1|2) ;; *) usage ;; esac
host="$1"
report_only=0
if [ "$#" -eq 2 ]; then
	[ "$2" = --reported-result ] || usage
	report_only=1
fi
case "$host" in
	''|.*|*..*|*-.*|*.-*|*-.|*.|*[!A-Za-z0-9.-]*) usage ;;
esac
[ "${#host}" -le 253 ] || usage
host="$(printf '%s' "$host" | tr 'A-Z' 'a-z')"
command -v curl >/dev/null 2>&1 || {
	echo "curl is required for a one-shot adaptive probe." >&2
	exit 1
}
BODY_HEX_TOOL=
if command -v od >/dev/null 2>&1; then
	BODY_HEX_TOOL=od
elif command -v hexdump >/dev/null 2>&1 &&
	hexdump -v -e '1/1 "%02x"' /dev/null >/dev/null 2>&1; then
	BODY_HEX_TOOL=hexdump
fi
head -c 0 </dev/null >/dev/null 2>&1 && [ -n "$BODY_HEX_TOOL" ] || {
	echo "Bounded body-sample tools (head -c and od/hexdump) are unavailable." >&2
	exit 1
}
ephemeral_range="$(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null | awk 'NF == 2 { print $1, $2 }')" || {
	echo "Cannot verify the kernel ephemeral port range; refusing to steer probe traffic." >&2
	exit 1
}
set -- $ephemeral_range
[ "$#" -eq 2 ] || {
	echo "Invalid kernel ephemeral port range; refusing to steer probe traffic." >&2
	exit 1
}
ephemeral_first="$1"
ephemeral_last="$2"
case "$ephemeral_first:$ephemeral_last" in *[!0-9:]*)
	echo "Invalid kernel ephemeral port range; refusing to steer probe traffic." >&2
	exit 1
;; esac
[ "$ephemeral_first" -gt 0 ] && [ "$ephemeral_last" -ge "$ephemeral_first" ] &&
	[ "$ephemeral_last" -le 65535 ] &&
	{ [ "$SOURCE_PORT_LAST" -lt "$ephemeral_first" ] || [ "$SOURCE_PORT_FIRST" -gt "$ephemeral_last" ]; } || {
	echo "Probe source ports overlap the kernel ephemeral range; refusing to steer probe traffic." >&2
	exit 1
}
[ -f "${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive-learning.enabled" ] || {
	echo "Adaptive learning is not enabled." >&2
	exit 1
}
[ -S /tmp/zator-adaptive/events.sock ] || {
	echo "Adaptive Controller socket is unavailable." >&2
	exit 1
}
[ -d /tmp/zator-adaptive-learning ] && [ ! -L /tmp/zator-adaptive-learning ] || {
	echo "Learning runtime directory is unavailable." >&2
	exit 1
}
[ -r "$ADAPTIVE_LIB" ] || { echo "Adaptive controller library is unavailable." >&2; exit 1; }
. "$ADAPTIVE_LIB" || exit 1
adaptive_learning_runner_lock_check || exit 1
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
	echo "Another learning probe is running." >&2
	exit 1
fi
trap cleanup_probe 0
trap 'exit 1' HUP INT TERM
if [ -f "$SOURCE_PORT_FILE" ] && [ ! -L "$SOURCE_PORT_FILE" ]; then
	IFS= read -r saved_port <"$SOURCE_PORT_FILE" || saved_port=
	case "$saved_port" in ''|*[!0-9]*) saved_port= ;; esac
	if [ -n "$saved_port" ] && [ "$saved_port" -ge "$SOURCE_PORT_FIRST" ] && [ "$saved_port" -le "$SOURCE_PORT_LAST" ]; then
		SOURCE_PORT="$saved_port"
	fi
fi
next_port=$((SOURCE_PORT + 1))
[ "$next_port" -le "$SOURCE_PORT_LAST" ] || next_port="$SOURCE_PORT_FIRST"
printf '%s\n' "$next_port" >"$SOURCE_PORT_FILE.tmp.$$" || exit 1
chmod 600 "$SOURCE_PORT_FILE.tmp.$$" && mv -f "$SOURCE_PORT_FILE.tmp.$$" "$SOURCE_PORT_FILE" || exit 1
strategy_file="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive-learning.strategy"
IFS= read -r strategy <"$strategy_file" || {
	echo "No learning strategy is configured." >&2
	exit 1
}
case "$strategy" in ''|*[!0-9]*) echo "Invalid learning strategy." >&2; exit 1 ;; esac
controller="${ZATOR_ROOT:-/opt/zator}/adaptive/bin/adaptive-controller"
[ -x "$controller" ] || { echo "adaptive-controller is not installed." >&2; exit 1; }
provider_key=unknown
provider_key_file="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/provider_learning_key.txt"
if [ -f "$provider_key_file" ] && [ ! -L "$provider_key_file" ]; then
	IFS="$(printf '\t')" read -r saved_provider_key saved_provider_at <"$provider_key_file" || saved_provider_key=
	case "$saved_provider_key" in
		asn:[1-9][0-9]*)
			case "${saved_provider_key#asn:}:$saved_provider_at" in *[!0-9:]*|'') ;; *)
				now="$(date +%s 2>/dev/null)"
				case "$now" in ''|*[!0-9]*) ;; *)
					if [ "${#saved_provider_key}" -le 14 ] && [ "$now" -ge "$saved_provider_at" ] &&
						[ $((now - saved_provider_at)) -le 86400 ]; then
						provider_key="$saved_provider_key"
					fi
				;; esac
			;; esac
		;;
	esac
fi
candidate="$($controller --get-candidate /tmp/zator-adaptive-learning/control.sock)" || exit 1
candidate_fields="$(printf '%s\n' "$candidate" | awk -F '\t' '
  $1 == "candidate_current" && $2 ~ /^profile=[0-9]+$/ && $3 ~ /^strategy=[0-9]+$/ && $4 ~ /^generation=[0-9]+$/ { print $2, $3, $4 }
')"
set -- $candidate_fields
[ "$#" -eq 3 ] || { echo "C candidate status has an unexpected format." >&2; exit 1; }
profile="${1#profile=}"
current_strategy="${2#strategy=}"
candidate_generation="${3#generation=}"
[ "$profile" = 1 ] && [ "$current_strategy" = "$strategy" ] || {
	echo "C candidate differs from the configured learning strategy; refusing probe." >&2
	exit 1
}
case "$candidate_generation" in ''|*[!0-9]*) echo "Invalid candidate generation." >&2; exit 1 ;; esac
umask 077
mkfifo "$BODY_FIFO" || { echo "Cannot create bounded probe FIFO." >&2; exit 1; }
: >"$BODY_FILE" && : >"$BODY_STATUS" || exit 1
probe_lease="$($controller --probe-begin /tmp/zator-adaptive/events.sock \
	"$host" "$SOURCE_PORT" "$profile" "$current_strategy" "$candidate_generation" "$provider_key")" || {
	echo "Controller refused to start the probe." >&2
	exit 1
}
probe_id="$(printf '%s\n' "$probe_lease" | awk -F= '$1 == "probe_id" && $2 ~ /^[0-9]+$/ { print $2 }')"
case "$probe_id" in ''|*[!0-9]*) echo "Controller returned an invalid probe lease." >&2; exit 1 ;; esac
started_at="$(date +%s 2>/dev/null || echo 0)"

curl --local-port "$SOURCE_PORT" --http1.1 --range "0-$((BODY_SAMPLE_LIMIT - 1))" \
	--connect-timeout "$CONNECT_SECONDS" --max-time "$MAX_SECONDS" \
	--silent --show-error --output "$BODY_FIFO" \
	--write-out '%{http_code}\n%{redirect_url}' "https://$host/" >"$BODY_STATUS" &
CURL_PID=$!
head -c "$BODY_SAMPLE_LIMIT" <"$BODY_FIFO" >"$BODY_FILE"
head_rc=$?
wait "$CURL_PID"
rc=$?
CURL_PID=
response="$(cat "$BODY_STATUS")"
code="$(printf '%s\n' "$response" | sed -n '1p')"
redirect_url="$(printf '%s\n' "$response" | sed -n '2p')"
redirect_host="$(printf '%s\n' "$redirect_url" | awk '
  {
    url=tolower($0)
    sub(/^[^:]+:\/\//, "", url)
    split(url, parts, "/")
    authority=parts[1]
    sub(/[?#].*/, "", authority)
    sub(/^.*@/, "", authority)
    if (substr(authority,1,1)=="[") next
    sub(/:[0-9]+$/, "", authority)
    if (length(authority)<=253 && authority ~ /^[a-z0-9.-]+$/ &&
        authority !~ /^\./ && authority !~ /\.$/ && authority !~ /\.\./)
      print authority
  }
')"
[ -n "$redirect_host" ] || redirect_host=none
body_bytes="$(wc -c <"$BODY_FILE" | awk '{print $1}')"
case "$body_bytes" in ''|*[!0-9]*) body_bytes=0 ;; esac
if [ "$rc" -eq 23 ] && [ "$head_rc" -eq 0 ] &&
	[ "$body_bytes" -eq "$BODY_SAMPLE_LIMIT" ] &&
	case "$code" in [1-5][0-9][0-9]) true ;; *) false ;; esac; then
	# head closed the FIFO at the sample cap; curl's write error is intentional.
	rc=0
fi
if [ "$BODY_HEX_TOOL" = od ]; then
	body_hex="$(od -An -v -tx1 "$BODY_FILE" | tr -d ' \t\n\r')"
else
	body_hex="$(hexdump -v -e '1/1 "%02x"' "$BODY_FILE" | tr -d ' \t\n\r')"
fi
body_hex_chars=${#body_hex}
case "$body_hex" in *[!0-9a-fA-F]*) rc=255 ;; esac
[ "$body_hex_chars" -eq $((body_bytes * 2)) ] || rc=255
finished_at="$(date +%s 2>/dev/null || echo "$started_at")"
case "$started_at:$finished_at" in *[!0-9:]*) elapsed_ms=0 ;; *) elapsed_ms=$(( (finished_at - started_at) * 1000 )) ;; esac
[ "$elapsed_ms" -ge 0 ] || elapsed_ms=0
printf 'probe_id=%s host=%s http_status=%s curl_rc=%s redirect_host=%s body_sample_bytes=%s source_port=%s strategy=%s generation=%s elapsed_ms=%s\n' \
	"$probe_id" "$host" "${code:-000}" "$rc" "$redirect_host" "$body_bytes" "$SOURCE_PORT" "$strategy" "$candidate_generation" "$elapsed_ms"
case "${code:-000}" in ''|*[!0-9]*) code=0 ;; esac
if ! "$controller" --probe-result /tmp/zator-adaptive/events.sock \
	"$probe_id" "$rc" "$code" "$elapsed_ms" "$redirect_host" "$body_hex"; then
	echo "Controller did not accept the probe result; it will expire as unknown." >&2
	exit 1
fi
[ "$report_only" -eq 1 ] && exit 0
exit "$rc"
