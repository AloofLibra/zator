#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for tool in adaptive-agent.ps1 adaptive-agent-state.ps1 adaptive-agent-port.ps1 adaptive-agent-verdict.ps1 adaptive-agent-stats.ps1 adaptive-controller.sh adaptive-pair.sh adaptive-lan-reconcile.sh adaptive-ramp-proof.sh; do
  grep -Eq "for tool in .*${tool}" "$ROOT/z2r.sh" || {
    echo "adaptive Windows client dependency is missing from runtime deployment: $tool" >&2; exit 1;
  }
done
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/zator/tools" "$tmp/zator/z2r_lib" "$tmp/zator/extra_strats/cache/adaptive" \
  "$tmp/runs/0123456789abcdef0123456789abcdef"
cat > "$tmp/bin/id" <<'ID'
#!/bin/sh
echo 0
ID
cat > "$tmp/bin/chown" <<'CHOWN'
#!/bin/sh
exit 0
CHOWN
cat > "$tmp/bin/sleep" <<'SLEEP'
#!/bin/sh
exit 0
SLEEP
chmod +x "$tmp/bin/id"
chmod +x "$tmp/bin/chown"
chmod +x "$tmp/bin/sleep"
cp "$ROOT/tools/adaptive-pair.sh" "$tmp/zator/tools/adaptive-pair.sh"
cp "$ROOT/tools/adaptive-ramp-proof.sh" "$tmp/zator/tools/adaptive-ramp-proof.sh"
cp "$ROOT/lib/adaptive_rules.sh" "$tmp/zator/z2r_lib/adaptive_rules.sh"
cp "$ROOT/lib/adaptive_lan_transport.sh" "$tmp/zator/z2r_lib/adaptive_lan_transport.sh"
cp "$ROOT/lib/supersweep_transport.sh" "$ROOT/lib/config.sh" "$tmp/zator/z2r_lib/"
cp "$ROOT/lib/googlevideo_ips.sh" "$tmp/zator/z2r_lib/"
cp "$ROOT/tools/adaptive-controller.sh" "$tmp/zator/tools/adaptive-controller.sh"
chmod +x "$tmp/zator/tools/adaptive-controller.sh"
mkdir -p "$tmp/zapret2/nfq2"
printf 'FWTYPE=iptables\nNFQWS2_ENABLE=1\n' > "$tmp/zapret2/config"
printf '#!/bin/sh\nexit 0\n' > "$tmp/zapret2/nfq2/nfqws2"
chmod +x "$tmp/zapret2/nfq2/nfqws2"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/iptables"
chmod +x "$tmp/bin/iptables"
now="$(date +%s)"
printf '1\tcdn.example.org\t93.184.216.34\t1\ttls\tdefault\t7\tsha256:%064d\tsha256:%064d\t1:2\t%s\n' 0 0 "$((now + 3600))" > "$tmp/zator/extra_strats/cache/adaptive/rules.tsv"
printf '65535 4321 0 0 0 0 0 0\n' > "$tmp/queue"
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" Z2R_ADAPTIVE_DIR="$tmp/runs" \
  bash "$tmp/zator/tools/adaptive-pair.sh" create > "$tmp/create.out"
token="$(cat "$tmp/zator/extra_strats/cache/adaptive/token")"
expiry="$(cat "$tmp/zator/extra_strats/cache/adaptive/token.expires")"
now="$(date +%s)"
[[ "$token" =~ ^[a-f0-9]{64}$ && "$expiry" =~ ^[0-9]{10}$ && $expiry -gt $now && $expiry -le $((now + 2592000)) &&
   "$(stat -c '%a' "$tmp/zator/extra_strats/cache/adaptive/token")" = 600 &&
   "$(stat -c '%a' "$tmp/zator/extra_strats/cache/adaptive/token.expires")" = 600 ]] || {
  echo 'pair token invalid or over-permissive' >&2; exit 1;
}
status="$(PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" Z2R_ADAPTIVE_DIR="$tmp/runs" \
  Z2R_ADAPTIVE_QUEUE_FILE="$tmp/queue" bash "$tmp/zator/tools/adaptive-pair.sh" status)"
[[ "$status" == *'pairing: paired'* && "$status" == *'Automatic strategy application: disabled'* &&
   "$status" == *'Active probes: 1'* && "$status" == *'Test NFQUEUE 65535: registered (PID 4321)'* &&
   "$status" == *'Stored exact rules: 1'* && "$status" != *'0123456789abcdef'* ]] || {
  echo "status diagnostic incomplete or leaked run id: $status" >&2; exit 1;
}
printf '1\n' > "$tmp/zator/extra_strats/cache/adaptive/token.expires"
expired_status="$(PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" Z2R_ADAPTIVE_DIR="$tmp/runs" \
  Z2R_ADAPTIVE_QUEUE_FILE="$tmp/queue" bash "$tmp/zator/tools/adaptive-pair.sh" status)"
[[ "$expired_status" == *'expired or invalid'* ]] || { echo 'status did not report an expired pairing token' >&2; exit 1; }
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" bash "$tmp/zator/tools/adaptive-pair.sh" rotate > "$tmp/rotate.out"
token="$(cat "$tmp/zator/extra_strats/cache/adaptive/token")"
expiry="$(cat "$tmp/zator/extra_strats/cache/adaptive/token.expires")"
[[ "$token" =~ ^[a-f0-9]{64}$ && "$expiry" -gt "$(date +%s)" ]] || { echo 'rotate did not renew an expired token' >&2; exit 1; }
: > "$tmp/queue"
doctor="$(PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2" \
  Z2R_ADAPTIVE_QUEUE_FILE="$tmp/queue" bash "$tmp/zator/tools/adaptive-pair.sh" doctor)"
[[ "$doctor" == *'zapret2 config'*' OK'* && "$doctor" == *'adaptive controller'*' OK'* &&
   "$doctor" == *'test NFQUEUE 65535'*' OK'* && "$doctor" == *'AUTO mode: unavailable'* ]] || {
  echo "doctor omitted local checks or overstated AUTO readiness: $doctor" >&2; exit 1;
}
printf '65535 4321 0 0 0 0 0 0\n' > "$tmp/queue"
if PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2" \
  Z2R_ADAPTIVE_QUEUE_FILE="$tmp/queue" bash "$tmp/zator/tools/adaptive-pair.sh" doctor >/dev/null 2>&1; then
  echo 'doctor reported a busy probe queue as ready' >&2; exit 1
fi
printf 'complete\n' > "$tmp/runs/0123456789abcdef0123456789abcdef/state"
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" bash "$tmp/zator/tools/adaptive-pair.sh" test-only >/dev/null
[[ "$(cat "$tmp/zator/extra_strats/cache/adaptive/mode")" = TEST_ONLY ]] || { echo 'test-only mode was not persisted' >&2; exit 1; }
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" bash "$tmp/zator/tools/adaptive-pair.sh" beta >/dev/null
[[ "$(cat "$tmp/zator/extra_strats/cache/adaptive/mode")" = AGENT_BETA &&
   ! -e "$tmp/zator/extra_strats/cache/adaptive/apply-default-scope" ]] || {
  echo 'scoped Beta mode enabled LAN-wide application without explicit consent' >&2; exit 1;
}
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" bash "$tmp/zator/tools/adaptive-pair.sh" beta-lan >/dev/null
[[ "$(cat "$tmp/zator/extra_strats/cache/adaptive/mode")" = AGENT_BETA &&
   "$(cat "$tmp/zator/extra_strats/cache/adaptive/apply-default-scope")" = 1 &&
   "$(stat -c '%a' "$tmp/zator/extra_strats/cache/adaptive/apply-default-scope")" = 600 ]] || {
  echo 'explicit LAN-wide Beta consent was not stored privately' >&2; exit 1;
}
mkdir -p "$tmp/zator/lua" "$tmp/zator/lists"
printf 'return {}\n' > "$tmp/zator/lua/wssize-ramp.lua"
printf '# googlevideo IPv4; generated=test\n142.250.72.14\n' > "$tmp/zator/lists/googlevideo-ipv4.txt"
cat >> "$tmp/zapret2/config" <<'RAMP_CONFIG'
Z2R_WSSIZE_RAMP_ENABLE=0
Z2R_WSSIZE_RAMP_MODE=adaptive
Z2R_WSSIZE_RAMP_WSIZE=1
Z2R_WSSIZE_RAMP_SCALE=3
Z2R_WSSIZE_RAMP_OPEN=1
Z2R_WSSIZE_RAMP_IPSET=/opt/zator/lists/googlevideo-ipv4.txt
--lua-desync=wssize_ramp
RAMP_CONFIG
printf '192.168.1.2\n' >> "$tmp/zator/lists/googlevideo-ipv4.txt"
if PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2" bash "$tmp/zator/tools/adaptive-pair.sh" ramp-pool-on >/dev/null 2>&1; then
  echo 'Ramp-first accepted a Googlevideo pool containing a private destination' >&2; exit 1
fi
printf '# googlevideo IPv4; generated=test\n142.250.72.14\n' > "$tmp/zator/lists/googlevideo-ipv4.txt"
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2" bash "$tmp/zator/tools/adaptive-pair.sh" ramp-pool-arm > "$tmp/ramp-arm.out"
[[ "$(grep '^Z2R_WSSIZE_RAMP_ENABLE=' "$tmp/zapret2/config")" = Z2R_WSSIZE_RAMP_ENABLE=0 &&
   "$(cut -f2 "$tmp/zator/extra_strats/cache/adaptive/ramp-pool-armed")" = armed &&
   "$(stat -c '%a' "$tmp/zator/extra_strats/cache/adaptive/ramp-pool-armed")" = 600 &&
   "$(cat "$tmp/ramp-arm.out")" == *'Production config is unchanged'* ]] || {
  echo 'proof-triggered Ramp-first consent changed config or was not private' >&2; exit 1;
}
if PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2" bash "$tmp/zator/tools/adaptive-pair.sh" ramp-pool-on >/dev/null 2>&1; then
  echo 'manual Ramp-first enable bypassed an armed proof transition' >&2; exit 1
fi
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2" bash "$tmp/zator/tools/adaptive-pair.sh" ramp-pool-off > "$tmp/ramp-proof-off.out"
[[ "$(grep '^Z2R_WSSIZE_RAMP_ENABLE=' "$tmp/zapret2/config")" = Z2R_WSSIZE_RAMP_ENABLE=0 &&
   ! -e "$tmp/zator/extra_strats/cache/adaptive/ramp-pool" &&
   ! -e "$tmp/zator/extra_strats/cache/adaptive/ramp-pool-armed" ]] || {
  echo 'cancelling proof-triggered Ramp-first changed config or left consent behind' >&2; exit 1;
}
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2" bash "$tmp/zator/tools/adaptive-pair.sh" ramp-pool-arm >/dev/null
sed -i 's/^Z2R_WSSIZE_RAMP_WSIZE=1$/Z2R_WSSIZE_RAMP_WSIZE=2/' "$tmp/zapret2/config"
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2" bash "$tmp/zator/tools/adaptive-pair.sh" ramp-pool-off > "$tmp/ramp-stale-arm-off.out"
[[ "$(grep '^Z2R_WSSIZE_RAMP_ENABLE=' "$tmp/zapret2/config")" = Z2R_WSSIZE_RAMP_ENABLE=0 &&
   "$(grep '^Z2R_WSSIZE_RAMP_WSIZE=' "$tmp/zapret2/config")" = Z2R_WSSIZE_RAMP_WSIZE=2 &&
   ! -e "$tmp/zator/extra_strats/cache/adaptive/ramp-pool-armed" ]] || {
  echo 'stale Ramp-first arm blocked opt-out or changed the manually edited config' >&2; exit 1;
}
sed -i 's/^Z2R_WSSIZE_RAMP_WSIZE=2$/Z2R_WSSIZE_RAMP_WSIZE=1/' "$tmp/zapret2/config"
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2" bash "$tmp/zator/tools/adaptive-pair.sh" ramp-pool-on >/dev/null
[[ "$(grep '^Z2R_WSSIZE_RAMP_ENABLE=' "$tmp/zapret2/config")" = Z2R_WSSIZE_RAMP_ENABLE=1 &&
   "$(cut -f3 "$tmp/zator/extra_strats/cache/adaptive/ramp-pool")" = manual_unverified &&
   "$(stat -c '%a' "$tmp/zator/extra_strats/cache/adaptive/ramp-pool")" = 600 ]] || {
  echo 'explicit Ramp-first did not enable the configured pool with private manual_unverified state' >&2; exit 1;
}
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2" bash "$tmp/zator/tools/adaptive-pair.sh" ramp-pool-off > "$tmp/ramp-off.out"
[[ "$(grep '^Z2R_WSSIZE_RAMP_ENABLE=' "$tmp/zapret2/config")" = Z2R_WSSIZE_RAMP_ENABLE=0 &&
   ! -e "$tmp/zator/extra_strats/cache/adaptive/ramp-pool" &&
   "$(cat "$tmp/ramp-off.out")" == *'Restart zapret2 to apply any restored Ramp config'* ]] || {
  echo 'Ramp-first opt-out did not restore the preexisting disabled state' >&2; exit 1;
}
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2" bash "$tmp/zator/tools/adaptive-pair.sh" ramp-pool-on >/dev/null
sed -i 's/^Z2R_WSSIZE_RAMP_WSIZE=1$/Z2R_WSSIZE_RAMP_WSIZE=2/' "$tmp/zapret2/config"
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2" bash "$tmp/zator/tools/adaptive-pair.sh" ramp-pool-off > "$tmp/ramp-manual-preserved.out"
[[ "$(grep '^Z2R_WSSIZE_RAMP_ENABLE=' "$tmp/zapret2/config")" = Z2R_WSSIZE_RAMP_ENABLE=1 &&
   "$(grep '^Z2R_WSSIZE_RAMP_WSIZE=' "$tmp/zapret2/config")" = Z2R_WSSIZE_RAMP_WSIZE=2 &&
   ! -e "$tmp/zator/extra_strats/cache/adaptive/ramp-pool" &&
   "$(cat "$tmp/ramp-manual-preserved.out")" == *'preserving the current manual config'* ]] || {
  echo "Ramp-first rollback overwrote the user's later Ramp parameter edit" >&2; exit 1;
}
sed -i 's/^Z2R_WSSIZE_RAMP_ENABLE=1$/Z2R_WSSIZE_RAMP_ENABLE=0/; s/^Z2R_WSSIZE_RAMP_WSIZE=2$/Z2R_WSSIZE_RAMP_WSIZE=1/' "$tmp/zapret2/config"
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2" bash "$tmp/zator/tools/adaptive-pair.sh" ramp-pool-on >/dev/null
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2" bash "$tmp/zator/tools/adaptive-pair.sh" pause >/dev/null
[[ "$(grep '^Z2R_WSSIZE_RAMP_ENABLE=' "$tmp/zapret2/config")" = Z2R_WSSIZE_RAMP_ENABLE=0 &&
   ! -e "$tmp/zator/extra_strats/cache/adaptive/ramp-pool" ]] || {
  echo 'pausing Beta did not restore a Beta-managed Ramp setting' >&2; exit 1;
}
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2" bash "$tmp/zator/tools/adaptive-pair.sh" beta-lan >/dev/null
sed -i 's/^Z2R_WSSIZE_RAMP_ENABLE=0$/Z2R_WSSIZE_RAMP_ENABLE=1/' "$tmp/zapret2/config"
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2" bash "$tmp/zator/tools/adaptive-pair.sh" ramp-pool-on >/dev/null
[[ "$(cut -f2 "$tmp/zator/extra_strats/cache/adaptive/ramp-pool")" = preexisting ]] || {
  echo 'manually enabled Ramp was not recorded as preexisting' >&2; exit 1;
}
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2" bash "$tmp/zator/tools/adaptive-pair.sh" ramp-pool-off >/dev/null
[[ "$(grep '^Z2R_WSSIZE_RAMP_ENABLE=' "$tmp/zapret2/config")" = Z2R_WSSIZE_RAMP_ENABLE=1 ]] || {
  echo 'Ramp-first opt-out disabled a preexisting manual Ramp setting' >&2; exit 1;
}
sed -i 's/^Z2R_WSSIZE_RAMP_ENABLE=1$/Z2R_WSSIZE_RAMP_ENABLE=0/' "$tmp/zapret2/config"
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" bash "$tmp/zator/tools/adaptive-pair.sh" test-only >/dev/null
[[ ! -e "$tmp/zator/extra_strats/cache/adaptive/apply-default-scope" ]] || {
  echo 'leaving Beta retained LAN-wide scope consent' >&2; exit 1;
}
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" bash "$tmp/zator/tools/adaptive-pair.sh" beta-lan >/dev/null
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" bash "$tmp/zator/tools/adaptive-pair.sh" beta >/dev/null
[[ ! -e "$tmp/zator/extra_strats/cache/adaptive/apply-default-scope" ]] || {
  echo 'scoped Beta mode retained LAN-wide consent' >&2; exit 1;
}
mkdir -p "$tmp/zapret"
printf 'WS_USER=nobody\n' > "$tmp/zapret/config"
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret" Z2R_ADAPTIVE_DIR="$tmp/runs" \
  bash "$tmp/zator/tools/adaptive-pair.sh" observe > "$tmp/observe.out"
[[ "$(cat "$tmp/zator/extra_strats/cache/adaptive/mode")" = OBSERVE &&
   "$(stat -c '%a' "$tmp/runs/events.tsv")" = 600 &&
   "$(stat -c '%a' "$tmp/runs/quic-health.tsv")" = 600 &&
   "$(cat "$tmp/observe.out")" == *'strategy selection remains unchanged'* ]] || {
  echo 'observe mode did not create a private queue and explicit mode file' >&2; exit 1;
}
printf '1\tseen\tcdn.example.org\t93.184.216.34\t1\ttls\tdefault\t%s\n' "$now" > "$tmp/runs/events.tsv"
events="$(PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" Z2R_ADAPTIVE_DIR="$tmp/runs" \
  bash "$tmp/zator/tools/adaptive-pair.sh" events)"
[[ "$events" == *'cdn.example.org'* && "$events" == *'93.184.216.34'* ]] || { echo 'events command omitted a valid observation' >&2; exit 1; }
printf '1\trr1.googlevideo.com\t93.184.216.34\tmark:4\t2\t1\t1\t1\t%s\n' "$now" > "$tmp/runs/quic-health.tsv"
quic_health="$(PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" Z2R_ADAPTIVE_DIR="$tmp/runs" \
  bash "$tmp/zator/tools/adaptive-pair.sh" quic-health)"
[[ "$quic_health" == *'rr1.googlevideo.com'* && "$quic_health" == *$'\t1\t1\t1\t'* ]] || { echo 'QUIC Health Monitor status command omitted a valid passive row' >&2; exit 1; }
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" Z2R_ADAPTIVE_DIR="$tmp/runs" \
  bash "$tmp/zator/tools/adaptive-pair.sh" clear-events >/dev/null
[[ ! -s "$tmp/runs/events.tsv" && "$(stat -c '%a' "$tmp/runs/events.tsv")" = 400 &&
   ! -s "$tmp/runs/quic-health.tsv" && "$(stat -c '%a' "$tmp/runs/quic-health.tsv")" = 400 &&
   "$(cat "$tmp/zator/extra_strats/cache/adaptive/mode")" = OFF ]] || { echo 'clear-events did not empty and pause the queue' >&2; exit 1; }
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" Z2R_ADAPTIVE_DIR="$tmp/runs" \
  bash "$tmp/zator/tools/adaptive-pair.sh" pause >/dev/null
[[ "$(cat "$tmp/zator/extra_strats/cache/adaptive/mode")" = OFF && "$(stat -c '%a' "$tmp/runs/events.tsv")" = 400 &&
   -e "$tmp/runs/0123456789abcdef0123456789abcdef/cancel" ]] || {
  echo 'pause did not stop event writes' >&2; exit 1;
}
if PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" bash "$tmp/zator/tools/adaptive-pair.sh" create >/dev/null 2>&1; then
  echo 'create replaced an existing pairing' >&2; exit 1
fi
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" bash "$tmp/zator/tools/adaptive-pair.sh" rotate > "$tmp/rotate.out"
[[ "$(cat "$tmp/zator/extra_strats/cache/adaptive/token")" != "$token" ]] || { echo 'rotate retained the old token' >&2; exit 1; }
printf 'failed\n' > "$tmp/runs/0123456789abcdef0123456789abcdef/state"
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" Z2R_ADAPTIVE_DIR="$tmp/runs" \
  bash "$tmp/zator/tools/adaptive-pair.sh" disable >/dev/null
[[ ! -e "$tmp/zator/extra_strats/cache/adaptive/token" && ! -e "$tmp/zator/extra_strats/cache/adaptive/token.expires" && "$(cat "$tmp/zator/extra_strats/cache/adaptive/mode")" = OFF && ! -e "$tmp/runs/events.tsv" && ! -e "$tmp/runs/quic-health.tsv" &&
   -e "$tmp/runs/0123456789abcdef0123456789abcdef/cancel" &&
   ! -s "$tmp/runs/rules.tsv" ]] || { echo 'disable did not revoke/cancel/clear state' >&2; exit 1; }

# Browser-only beta activation must not require the separate Windows-agent token.
browser_expiry=$(( $(date +%s) + 3600 ))
if PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret" Z2R_ADAPTIVE_DIR="$tmp/runs" \
  bash "$tmp/zator/tools/adaptive-pair.sh" beta >/dev/null 2>&1; then
  echo 'Beta enabled without either agent or browser pairing' >&2; exit 1;
fi
printf '1\t12121212121212121212121212121212\t%s\t192.168.1.42\tmark:7\t%s\n' \
  "$(printf '%064d' 0 | tr 0 b)" "$(( $(date +%s) - 1 ))" > "$tmp/zator/extra_strats/cache/adaptive/browser-clients.tsv"
if PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret" Z2R_ADAPTIVE_DIR="$tmp/runs" \
  bash "$tmp/zator/tools/adaptive-pair.sh" beta >/dev/null 2>&1; then
  echo 'expired browser pairing enabled Beta' >&2; exit 1;
fi
printf '1\t12121212121212121212121212121212\t%s\t192.168.1.42\tmark:7\t%s\n' \
  "$(printf '%064d' 0 | tr 0 b)" "$browser_expiry" > "$tmp/zator/extra_strats/cache/adaptive/browser-clients.tsv"
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret" Z2R_ADAPTIVE_DIR="$tmp/runs" \
  bash "$tmp/zator/tools/adaptive-pair.sh" beta > "$tmp/browser-beta.out"
[[ "$(cat "$tmp/zator/extra_strats/cache/adaptive/mode")" = AGENT_BETA &&
   "$(cat "$tmp/browser-beta.out")" == *'Windows agent is optional'* ]] || {
  echo 'browser pairing could not enable scoped Beta without a Windows-agent token' >&2; exit 1;
}

crash_id=abcdef0123456789abcdef0123456789
mkdir -p "$tmp/runs/$crash_id/leases" "$tmp/runs/$crash_id/probe" "$tmp/shared.lock" "$tmp/proc"
touch "$tmp/runs/$crash_id/probe/locked.lua"
printf 'probing\n' > "$tmp/runs/$crash_id/state"
printf '%s\t192.168.1.20\t62000\t142.250.72.14\t443\t2000000000\ttls-http1-v1\n' "$crash_id" \
  > "$tmp/runs/$crash_id/leases/$crash_id.tsv"
printf 'adaptive-lan\t2147483000\tboot-test\n' > "$tmp/shared.lock/owner"
: > "$tmp/queue"
printf 'boot-test\n' > "$tmp/boot_id"
PATH="$tmp/bin:$PATH" ZATOR_ROOT="$tmp/zator" ZAPRET2_ROOT="$tmp/zapret2" Z2R_ADAPTIVE_DIR="$tmp/runs" \
  Z2R_ADAPTIVE_LOCK_DIR="$tmp/shared.lock" Z2R_ADAPTIVE_QUEUE_FILE="$tmp/queue" \
  Z2R_ADAPTIVE_PROC_ROOT="$tmp/proc" Z2R_ADAPTIVE_BOOT_ID_FILE="$tmp/boot_id" \
  bash "$tmp/zator/tools/adaptive-pair.sh" disable > "$tmp/recover.out"
[[ "$(cat "$tmp/runs/$crash_id/state")" = failed &&
   "$(cat "$tmp/runs/$crash_id/error")" = controller_crash_recovered &&
   ! -e "$tmp/shared.lock" && "$(cat "$tmp/zator/extra_strats/cache/adaptive/mode")" = OFF &&
   "$(cat "$tmp/recover.out")" == *'Restart zapret2 to apply any restored Ramp config'* ]] || {
  echo 'disable did not recover a stale adaptive controller' >&2; exit 1;
}
echo 'adaptive pairing smoke: ok'
