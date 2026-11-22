#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export ZATOR_ROOT="$tmp/zator"
export Z2R_ADAPTIVE_DIR="$tmp/state"
source "$ROOT/lib/adaptive_browser.sh"

now="$(date +%s)"
host=rr1---sn-a5mekn6e.googlevideo.com
ip=142.250.72.3
scope=default
client=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
strategy=7
fingerprint="sha256:$(printf '%064d' 1)"
ids=(11111111111111111111111111111111 22222222222222222222222222222222 33333333333333333333333333333333 44444444444444444444444444444444)
for i in 0 1 2 3; do
  treatment=bypassed; ack=unknown
  if (( i == 0 || i == 3 )); then treatment=applied; ack=confirmed; fi
  adaptive_browser_media_quality_write "${ids[i]}" 1 "$client" "$scope" "$host" "$ip" \
    2 googlevideo-tcp "$strategy" "$fingerprint" "$treatment" "$ack" healthy \
    8000 6000 0 1 240 "$((now - 3 + i))"
done
id_list="$(IFS=,; printf '%s' "${ids[*]}")"
proof="$(adaptive_browser_ramp_canary_validate "$host" "$ip" "$scope" "$id_list" "$now" "$client")"
[[ "$proof" =~ ^[a-f0-9]{64}$ ]] || { echo 'healthy ordered Ramp/Plain/Plain/Ramp evidence was rejected' >&2; exit 1; }
if adaptive_browser_ramp_canary_validate "$host" "$ip" "$scope" "$id_list" "$now" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" >/dev/null 2>&1; then
  echo 'another paired browser client reused this canary evidence' >&2; exit 1
fi
expires=$((now + 600))
adaptive_browser_ramp_canary_lease_apply "$host" "$ip" "$scope" "$proof" "$expires"
lease="${Z2R_ADAPTIVE_DIR}/ramp-exempt.tsv"
[[ "$(wc -l < "$lease")" -eq 1 && "$(stat -c '%a' "$lease")" = 644 ]] ||
  { echo 'short Ramp canary lease was not written for the Lua worker' >&2; exit 1; }
if adaptive_browser_ramp_canary_lease_apply "$host" "$ip" "$scope" "$(printf '%064d' 9)" "$expires"; then
  echo 'Ramp canary replaced an independently owned exact exemption' >&2; exit 1
fi
if adaptive_browser_ramp_canary_lease_revoke "$host" "$ip" "$scope" "$(printf '%064d' 9)"; then
  echo 'stale canary proof revoked a newer exact exemption' >&2; exit 1
fi
adaptive_browser_ramp_canary_lease_revoke "$host" "$ip" "$scope" "$proof"
[[ ! -s "$lease" ]] || { echo 'matching canary proof did not revoke its own lease' >&2; exit 1; }

session=55555555555555555555555555555555
plain1=66666666666666666666666666666666
plain2=77777777777777777777777777777777
ramp2=88888888888888888888888888888888
adaptive_browser_ramp_canary_session_begin "$session" "$client" 192.168.1.42 "$scope" "$host" "$ip" \
  "$strategy" "$fingerprint" plain1 "$plain1" "${ids[0]}" "$proof" "$now"
if adaptive_browser_ramp_canary_session_begin "$session" "$client" 192.168.1.42 "$scope" "$host" "$ip" \
  "$strategy" "$fingerprint" plain1 "$plain1" "${ids[0]}" "$proof" "$now"; then
  echo 'overlapping canary replaced the active session' >&2; exit 1
fi
if adaptive_browser_ramp_canary_session_advance "$session" "$plain1" "$plain2" applied confirmed healthy >/dev/null 2>&1; then
  echo 'Ramp treatment advanced a Plain canary stage' >&2; exit 1
fi
[[ "$(adaptive_browser_ramp_canary_session_advance "$session" "$plain1" "$plain2" bypassed unknown healthy)" = plain2 ]]
if adaptive_browser_ramp_canary_session_advance "$session" "$plain1" "$plain2" bypassed unknown healthy >/dev/null 2>&1; then
  echo 'stale session attempt advanced the canary twice' >&2; exit 1
fi
[[ "$(adaptive_browser_ramp_canary_session_advance "$session" "$plain2" "$ramp2" bypassed pending healthy)" = ramp2 ]]
[[ "$(adaptive_browser_ramp_canary_session_advance "$session" "$ramp2" - applied confirmed healthy)" = complete ]]
canary_session="$(adaptive_browser_ramp_canary_session_file)"
[[ "$(cut -f10 "$canary_session")" = complete && "$(cut -f12 "$canary_session")" = "${ids[0]},$plain1,$plain2,$ramp2" ]]
adaptive_browser_ramp_canary_session_clear "$session"
[[ ! -e "$canary_session" ]] || { echo 'completed canary session was not cleared' >&2; exit 1; }
adaptive_browser_ramp_canary_cooldown_set "$now" 3600
adaptive_browser_ramp_canary_cooldown_active "$now"
if adaptive_browser_ramp_canary_cooldown_set "$now" 3600; then
  echo 'Ramp canary ignored its router-wide cooldown' >&2; exit 1
fi
if adaptive_browser_ramp_canary_cooldown_active "$((now + 3601))"; then
  echo 'expired Ramp canary cooldown remained active' >&2; exit 1
fi

canary_trial=99999999999999999999999999999999
trial_now="$(date +%s)"
adaptive_browser_trial_add "$canary_trial" 1 "$client" 192.168.1.42 "$scope" "$host" "$ip" 2 googlevideo-tcp \
  "$strategy" "$fingerprint" "$trial_now" "$((trial_now + 300))" ramp_canary
if adaptive_browser_trial_add aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2 "$client" 192.168.1.42 "$scope" "$host" "$ip" 2 googlevideo-tcp \
  "$strategy" "$fingerprint" "$trial_now" "$((trial_now + 301))" ramp_canary; then
  echo 'canary trial exceeded its five-minute flow window' >&2; exit 1
fi
adaptive_browser_trial_remove "$canary_trial" 1

evidence="$(adaptive_browser_state_dir)/media-quality/evidence.tsv"
sed -i $'3s/\\thealthy\\t/\\tdegraded\\t/' "$evidence"
if adaptive_browser_ramp_canary_validate "$host" "$ip" "$scope" "$id_list" "$now" "$client" >/dev/null; then
  echo 'degraded plain media was accepted as a Ramp canary' >&2; exit 1
fi
sed -i $'3s/\\tdegraded\\t/\\thealthy\\t/' "$evidence"
sed -i '4s/\t7\t/\t8\t/' "$evidence"
if adaptive_browser_ramp_canary_validate "$host" "$ip" "$scope" "$id_list" "$now" "$client" >/dev/null; then
  echo 'strategy mismatch was accepted as one controlled canary' >&2; exit 1
fi
if adaptive_browser_ramp_canary_validate "$host" "$ip" "$scope" "${ids[0]},${ids[1]},${ids[1]},${ids[3]}" "$now" "$client" >/dev/null 2>&1; then
  echo 'duplicate observation ID was accepted' >&2; exit 1
fi
echo 'adaptive browser Ramp canary evidence smoke: OK'
