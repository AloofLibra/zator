#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export Z2R_ADAPTIVE_RULES_FILE="$tmp/rules.tsv"
export Z2R_ADAPTIVE_EVENTS_FILE="$tmp/events.tsv"
export ZATOR_ROOT="$tmp/zator" Z2R_ADAPTIVE_SNAPSHOT_DELAY=1 Z2R_ADAPTIVE_SNAPSHOT_INTERVAL=0
mkdir -p "$tmp/zapret2"
printf 'WS_USER=%s\n' "$(id -un)" > "$tmp/zapret2/config"
export ZAPRET2_ROOT="$tmp/zapret2"
source "$ROOT/lib/adaptive_rules.sh"
now="$(date +%s)"
fp="sha256:$(printf '%064d' 0 | tr 0 a)"
cat="sha256:$(printf '%064d' 0 | tr 0 b)"
stamp="$(printf '%0500d' 0 | tr 0 1)"
adaptive_rule_add cdn.example.org 93.184.216.34 1 tls default 7 "$fp" "$cat" "$stamp" "$((now + 3600))"
[[ "$(wc -l < "$Z2R_ADAPTIVE_RULES_FILE")" -eq 1 ]] || { echo 'rule was not stored' >&2; exit 1; }
found="$(adaptive_rule_lookup_local cdn.example.org 93.184.216.34 1 tls default "$stamp")"
[[ "${found%%$'\t'*}" = 7 ]] || { echo 'exact current local rule was not found' >&2; exit 1; }
if adaptive_rule_remove_if_matches cdn.example.org 93.184.216.34 1 tls default 8 "$fp" "$stamp"; then
  echo 'failed candidate evicted a different active strategy' >&2; exit 1;
fi
[[ -n "$(adaptive_rule_lookup_local cdn.example.org 93.184.216.34 1 tls default "$stamp")" ]] || {
  echo 'mismatched candidate removed the active rule' >&2; exit 1;
}
adaptive_rule_remove_if_matches cdn.example.org 93.184.216.34 1 tls default 7 "$fp" "$stamp" || {
  echo 'matching degraded active rule was not removed' >&2; exit 1;
}
if awk -F '\t' '$2=="cdn.example.org" && $3=="93.184.216.34" && $4==1 && $5=="tls" && $6=="default" {found=1} END {exit !found}' "$Z2R_ADAPTIVE_RULES_FILE"; then
  echo 'degraded exact-scope rule remained after exact revalidation failure' >&2; exit 1;
fi
if adaptive_rule_add cdn.example.org 93.184.216.34 1 tls shared 7 "$fp" "$cat" "$stamp" "$((now + 3600))"; then
  echo 'shared baseline was accepted without browser-confirmed provenance' >&2; exit 1
fi
adaptive_rule_add cdn.example.org 93.184.216.34 1 tls shared 9 "$fp" "$cat" "$stamp" "$((now + 3600))" browser-confirmed
shared_found="$(adaptive_rule_lookup_local cdn.example.org 93.184.216.34 1 tls default "$stamp")"
[[ "${shared_found%%$'\t'*}" = 9 ]] || { echo 'browser-confirmed shared rule was not available to a client without an exact rule' >&2; exit 1; }
if adaptive_rule_lookup_local cdn.example.org 93.184.216.34 1 tls mark:5 "$stamp" >/dev/null; then
  echo 'browser-confirmed shared rule leaked into a separately scoped client' >&2; exit 1
fi
adaptive_rule_add cdn.example.org 93.184.216.34 1 tls mark:4 6 "$fp" "$cat" "$stamp" "$((now + 3600))"
scoped_found="$(adaptive_rule_lookup_local cdn.example.org 93.184.216.34 1 tls mark:4 "$stamp")"
[[ "${scoped_found%%$'\t'*}" = 6 ]] || { echo 'client-specific rule did not take precedence over shared baseline' >&2; exit 1; }
adaptive_rules_invalidate || { echo 'could not isolate shared-baseline regression fixture' >&2; exit 1; }
adaptive_rule_add cdn.example.org 93.184.216.34 1 tls default 7 "$fp" "$cat" "$stamp" "$((now + 3600))"
adaptive_rule_add direct.example.org 93.184.216.36 1 tls default 0 "$fp" "$cat" "$stamp" "$((now + 3600))"
direct_found="$(adaptive_rule_lookup_local direct.example.org 93.184.216.36 1 tls default "$stamp")"
[[ "${direct_found%%$'\t'*}" = 0 ]] || { echo 'DIRECT runtime sentinel was not stored as strategy zero' >&2; exit 1; }
adaptive_rule_remove direct.example.org 93.184.216.36 1 default || { echo 'DIRECT rule could not be removed' >&2; exit 1; }
gv_host=rr1---sn-a5mekn6e.googlevideo.com
adaptive_rule_add "$gv_host" 93.184.216.37 2 googlevideo-tcp default 12 "$fp" "$cat" "$stamp" "$((now + 3600))"
gv_found="$(adaptive_rule_lookup_local "$gv_host" 93.184.216.37 2 googlevideo-tcp default "$stamp")"
[[ "${gv_found%%$'\t'*}" = 12 ]] || { echo 'Googlevideo media rule was not stored in its own recipe category' >&2; exit 1; }
if adaptive_rule_lookup_local "$gv_host" 93.184.216.37 2 tls default "$stamp" >/dev/null; then
  echo 'Googlevideo media rule leaked into the TLS-only category' >&2; exit 1
fi
adaptive_rule_remove "$gv_host" 93.184.216.37 2 default googlevideo-tcp || { echo 'Googlevideo media rule could not be removed by exact category' >&2; exit 1; }
quic_host=rr1---sn-a5mekn6e.googlevideo.com
adaptive_rule_add "$quic_host" 93.184.216.41 5 quic mark:4 9 "$fp" "$cat" "$stamp" "$((now + 3600))"
quic_found="$(adaptive_rule_lookup_local "$quic_host" 93.184.216.41 5 quic mark:4 "$stamp")"
[[ "${quic_found%%$'\t'*}" = 9 ]] || { echo 'profile-5 QUIC rule was not stored in its exact scoped category' >&2; exit 1; }
[[ "$(adaptive_rules_ranked_candidates 5 quic mark:4 "$stamp" 20)" = 9 ]] || { echo 'profile-5 QUIC confirmation was not available to candidate ranking' >&2; exit 1; }
if adaptive_rule_add example.org 93.184.216.42 5 quic mark:4 9 "$fp" "$cat" "$stamp" "$((now + 3600))"; then
  echo 'profile-5 QUIC rule accepted a non-YouTube host' >&2; exit 1;
fi
if adaptive_rule_add "$quic_host" 93.184.216.41 4 quic mark:4 9 "$fp" "$cat" "$stamp" "$((now + 3600))"; then
  echo 'QUIC rule accepted a non-profile-5 tuple' >&2; exit 1;
fi
adaptive_rule_remove "$quic_host" 93.184.216.41 5 mark:4 quic || { echo 'profile-5 QUIC rule could not be removed by exact category' >&2; exit 1; }
if adaptive_rule_lookup_local cdn.example.org 93.184.216.34 1 tls mark:4 "$stamp" >/dev/null; then
  echo 'local rule lookup ignored client scope' >&2; exit 1;
fi
adaptive_rule_add cdn.example.org 93.184.216.34 1 tls default 8 "$fp" "$cat" "$stamp" "$((now + 3600))"
[[ "$(wc -l < "$Z2R_ADAPTIVE_RULES_FILE")" -eq 1 && "$(cut -f7 "$Z2R_ADAPTIVE_RULES_FILE")" = 8 ]] || { echo 'exact tuple was not replaced' >&2; exit 1; }
found="$(adaptive_rule_lookup_local cdn.example.org 93.184.216.34 1 tls default "$stamp")"
[[ "${found%%$'\t'*}" = 8 ]] || { echo 'updated exact local rule was not found' >&2; exit 1; }
flip_a="sha256:$(printf '%064d' 0 | tr 0 c)"
flip_b="sha256:$(printf '%064d' 0 | tr 0 d)"
flip_host=flip.example.org
adaptive_rule_add "$flip_host" 93.184.216.38 1 tls default 1 "$flip_a" "$cat" "$stamp" "$((now + 3600))"
adaptive_rule_add "$flip_host" 93.184.216.38 1 tls default 2 "$flip_b" "$cat" "$stamp" "$((now + 3600))"
[[ "$(adaptive_rules_flipflop_total)" = 0 ]] || { echo 'single rule change was miscounted as a flip-flop' >&2; exit 1; }
adaptive_rule_add "$flip_host" 93.184.216.38 1 tls default 1 "$flip_a" "$cat" "$stamp" "$((now + 3600))"
[[ "$(adaptive_rules_flipflop_total)" = 1 ]] || { echo 'A-B-A semantic rule sequence was not counted once' >&2; exit 1; }
flip_data_after_aba="$(cat "$(adaptive_rules_flipflop_file)")"
adaptive_rule_add "$flip_host" 93.184.216.38 1 tls default 1 "$flip_a" "$cat" "$stamp" "$((now + 3600))"
[[ "$(adaptive_rules_flipflop_total)" = 1 ]] || { echo 'identical rule refresh was counted as a flip-flop' >&2; exit 1; }
adaptive_rule_add "$flip_host" 93.184.216.38 1 tls default 2 "$flip_b" "$cat" "$stamp" "$((now + 3600))"
adaptive_rule_add "$flip_host" 93.184.216.38 1 tls default 1 "$flip_a" "$cat" "$stamp" "$((now + 3600))"
flip_total="$(adaptive_rules_flipflop_total)"; flip_mode="$(stat -c '%a' "$(adaptive_rules_flipflop_file)")"; flip_data="$(cat "$(adaptive_rules_flipflop_file)")"
[[ "$flip_total" = 2 && "$flip_mode" = 600 && "$flip_data" != *"$flip_host"* && "$flip_data" != *'93.184.216.38'* ]] || {
  echo "semantic flip-flop history failed: total=$flip_total mode=$flip_mode after_aba=$flip_data_after_aba data=$flip_data" >&2; exit 1;
}
flip_file="$(adaptive_rules_flipflop_file)"
cp "$flip_file" "$tmp/flipflops-v2.tsv"
legacy_key="$(printf '%s\n' 'legacy.example.org|93.184.216.40|1|tls|default' | sha256sum | awk '{print $1}')"
printf '1\t%s\t%s\t%s\t4\t%s\n' "$legacy_key" "$flip_a" "$flip_b" "$now" > "$flip_file"
chmod 600 "$flip_file"
adaptive_rules_flipflop_record legacy.example.org 93.184.216.40 1 tls default "$flip_b" "$flip_a"
[[ "$(adaptive_rules_flipflop_total)" = 5 && "$(tail -n 1 "$flip_file" | cut -f5)" = 5 ]] || {
  echo 'legacy per-tuple flip-flop history was not migrated into the cumulative total' >&2; exit 1;
}
cp "$tmp/flipflops-v2.tsv" "$flip_file"; chmod 600 "$flip_file"
adaptive_rule_remove "$flip_host" 93.184.216.38 1 default || { echo 'flip-flop test rule could not be removed' >&2; exit 1; }
for n in $(seq 1 255); do
  adaptive_rules_flipflop_record "evict$n.example.org" 93.184.216.39 1 tls default "$flip_a" "$flip_b"
done
[[ "$(adaptive_rules_flipflop_total)" = 2 && "$(wc -l < "$(adaptive_rules_flipflop_file)")" -eq 256 ]] || {
  echo 'flip-flop total was lost when bounded tuple history evicted an identity' >&2; exit 1;
}
for _ in $(seq 1 30); do
  if [[ -s "$ZATOR_ROOT/extra_strats/cache/adaptive/rules.tsv" ]] &&
     [[ "$(cut -f7 "$ZATOR_ROOT/extra_strats/cache/adaptive/rules.tsv" | head -n 1)" = 8 ]] &&
     ! grep -q $'\tflip.example.org\t' "$ZATOR_ROOT/extra_strats/cache/adaptive/rules.tsv"; then break; fi
  sleep 0.1
done
[[ -s "$ZATOR_ROOT/extra_strats/cache/adaptive/rules.tsv" && "$(stat -c '%a' "$ZATOR_ROOT/extra_strats/cache/adaptive/rules.tsv")" = 600 ]] || { echo 'delayed snapshot was not written privately' >&2; exit 1; }
[[ "$(stat -c '%u' "$Z2R_ADAPTIVE_RULES_FILE")" = "$(id -u)" &&
   "$(stat -c '%u' "$ZATOR_ROOT/extra_strats/cache/adaptive/rules.tsv")" = "$(id -u)" ]] || { echo 'runtime/snapshot files are not readable by the daemon owner' >&2; exit 1; }
adaptive_rules_runtime_reset
[[ ! -e "$Z2R_ADAPTIVE_RULES_FILE" && -s "$ZATOR_ROOT/extra_strats/cache/adaptive/rules.tsv" ]] || { echo 'runtime reset did not preserve the snapshot for restart recovery' >&2; exit 1; }
found="$(adaptive_rule_lookup_local cdn.example.org 93.184.216.34 1 tls default "$stamp")"
[[ "${found%%$'\t'*}" = 8 ]] || { echo 'snapshot recovery lookup lost the exact local rule' >&2; exit 1; }
adaptive_rule_add other.example.org 93.184.216.35 1 tls default 9 "$fp" "$cat" "$stamp" "$((now + 3600))"
[[ "$(wc -l < "$Z2R_ADAPTIVE_RULES_FILE")" -eq 2 ]] || { echo 'first post-restart rule replaced rather than merged the snapshot' >&2; exit 1; }
adaptive_rule_remove cdn.example.org 93.184.216.34 1 default || { echo 'exact adaptive rule could not be reset' >&2; exit 1; }
[[ "$(wc -l < "$Z2R_ADAPTIVE_RULES_FILE")" -eq 1 && "$(cut -f2 "$Z2R_ADAPTIVE_RULES_FILE")" = other.example.org ]] || { echo 'reset removed a different rule or left the target rule' >&2; exit 1; }
if adaptive_rule_remove cdn.example.org 93.184.216.34 1 default; then
  echo 'reset reported success for a missing rule' >&2; exit 1
fi
if adaptive_rule_add cdn.example.org 93.184.216.34 1 tls mark:123456 7 "$fp" "$cat" "$stamp" "$((now + 3600))"; then
  echo 'invalid scope accepted' >&2; exit 1
fi
excessive_expiry=$(( $(date +%s) + 604900 ))
if adaptive_rule_add cdn.example.org 93.184.216.34 1 tls default 7 "$fp" "$cat" "$stamp" "$excessive_expiry"; then
  echo 'excessive TTL accepted' >&2; exit 1
fi
if adaptive_rule_add cdn.example.org 192.168.1.1 1 tls default 7 "$fp" "$cat" "$stamp" "$((now + 3600))"; then
  echo 'private destination accepted' >&2; exit 1
fi
: > "$Z2R_ADAPTIVE_RULES_FILE"
for n in $(seq 1 256); do
  host="h$n.example.org"
  ip="93.184.216.$(( (n % 250) + 1 ))"
  printf '1\t%s\t%s\t1\ttls\tdefault\t1\t%s\t%s\t%s\t%s\n' "$host" "$ip" "$fp" "$cat" "$stamp" "$((now + 3600))" >> "$Z2R_ADAPTIVE_RULES_FILE"
done
chmod 600 "$Z2R_ADAPTIVE_RULES_FILE"
if adaptive_rule_add overflow.example.org 93.184.216.34 1 tls default 1 "$fp" "$cat" "$stamp" "$((now + 3600))"; then
  echo 'rule capacity limit was ignored' >&2; exit 1
fi
[[ "$(wc -l < "$Z2R_ADAPTIVE_RULES_FILE")" -eq 256 ]] || { echo 'rule store exceeded capacity' >&2; exit 1; }
[[ "$(stat -c '%a' "$Z2R_ADAPTIVE_RULES_FILE")" = 600 ]] || { echo 'rule store permissions are too broad' >&2; exit 1; }
adaptive_rules_invalidate
[[ ! -e "$Z2R_ADAPTIVE_RULES_FILE" && ! -e "$ZATOR_ROOT/extra_strats/cache/adaptive/rules.tsv" ]] || { echo 'invalidation did not clear runtime and snapshot rules' >&2; exit 1; }
adaptive_rule_add cdn.example.org 93.184.216.34 1 tls default 7 "$fp" "$cat" "$stamp" "$((now + 3600))"
printf '1\tmanaged\tmanual_unverified\t%s\n' "$fp" > "$ZATOR_ROOT/extra_strats/cache/adaptive/ramp-pool"
chmod 600 "$ZATOR_ROOT/extra_strats/cache/adaptive/ramp-pool"
source "$ROOT/lib/config.sh"
eval "$(sed -n '/^z2r_backup_state_files()/,/^}/p' "$ROOT/lib/actions.sh")"
backup_state="$(z2r_backup_state_files)"
[[ "$backup_state" == *'extra_strats/cache/adaptive/rules.tsv'* &&
   "$backup_state" == *'extra_strats/cache/adaptive/ramp-pool'* &&
   "$backup_state" != *'extra_strats/cache/adaptive/token'* &&
   "$backup_state" != *'browser-flow-upload'* &&
   "$backup_state" != *'browser-flow-queue'* &&
   "$backup_state" != *'browser-rankings-opt-in'* ]] || {
  echo 'backup must preserve adaptive rules and Ramp ownership without copying the pairing secret' >&2; exit 1;
}
for _ in $(seq 1 30); do [[ -s "$ZATOR_ROOT/extra_strats/cache/adaptive/rules.tsv" ]] && break; sleep 0.1; done
source "$ROOT/lib/actions.sh"
export Z2R_BACKUP_DIR="$tmp/backups"
archive="$(backup_create_core)"
[[ -s "$archive" ]] || { echo 'adaptive backup archive was not created' >&2; exit 1; }
restore="$tmp/backup-restore"
mkdir -p "$restore"
"$(z2r_pick_tar)" -xf "$archive" -C "$restore"
[[ -s "$restore/extra_strats/cache/adaptive/rules.tsv" ]] || {
  echo 'backup archive omitted adaptive rules.tsv' >&2; exit 1;
}
[[ -s "$restore/extra_strats/cache/adaptive/ramp-pool" &&
   "$(stat -c '%a' "$restore/extra_strats/cache/adaptive/ramp-pool")" = 600 ]] || {
  echo 'backup archive omitted private Ramp ownership state' >&2; exit 1;
}
cmp -s "$ZATOR_ROOT/extra_strats/cache/adaptive/rules.tsv" "$restore/extra_strats/cache/adaptive/rules.tsv" || {
  echo 'adaptive rules changed during backup round-trip' >&2; exit 1;
}
if "$(z2r_pick_tar)" -tf "$archive" | grep -Eq '(^|/)extra_strats/cache/adaptive/token$'; then
  echo 'backup archive copied the adaptive pairing secret' >&2; exit 1;
fi
cmp -s "$ZATOR_ROOT/extra_strats/cache/adaptive/ramp-pool" "$restore/extra_strats/cache/adaptive/ramp-pool" || {
  echo 'backup round-trip changed Ramp ownership state' >&2; exit 1;
}
cat > "$tmp/init" <<'INIT'
#!/bin/sh
exit 0
INIT
chmod +x "$tmp/init"
ZAPRET2_INIT="$tmp/init" z2r_service_action restart
[[ ! -e "$Z2R_ADAPTIVE_RULES_FILE" && -s "$ZATOR_ROOT/extra_strats/cache/adaptive/rules.tsv" ]] || { echo 'service restart did not retain the stamp-checked snapshot' >&2; exit 1; }
adaptive_rules_runtime_reset
adaptive_rule_add cdn.example.org 93.184.216.34 1 tls default 7 "$fp" "$cat" "$stamp" "$((now + 3600))"
printf '1\trouter_trial_2\tcdn.example.org\t93.184.216.34\t1\ttls\tdefault\t%s\n1\trouter_exhausted\tother.example.org\t93.184.216.35\t1\ttls\tdefault\t%s\n' "$now" "$now" > "$Z2R_ADAPTIVE_EVENTS_FILE"
chmod 600 "$Z2R_ADAPTIVE_EVENTS_FILE"
printf 'TEST_VALUE=before\n' > "$tmp/config"
config_set_var "$tmp/config" TEST_VALUE after
[[ ! -e "$Z2R_ADAPTIVE_RULES_FILE" && ! -e "$ZATOR_ROOT/extra_strats/cache/adaptive/rules.tsv" ]] || { echo 'config_set_var left stale adaptive rules' >&2; exit 1; }
[[ "$(cut -f2 "$Z2R_ADAPTIVE_EVENTS_FILE" | tr '\n' ' ')" = 'seen seen ' && "$(stat -c '%a' "$Z2R_ADAPTIVE_EVENTS_FILE")" = 600 ]] || {
  echo 'config invalidation did not clear router AUTO trials while preserving private event state' >&2; exit 1;
}
echo 'adaptive rule store smoke: ok'
