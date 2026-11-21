#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export Z2R_ADAPTIVE_RULES_FILE="$tmp/rules.tsv"
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
if adaptive_rule_lookup_local cdn.example.org 93.184.216.34 1 tls mark:4 "$stamp" >/dev/null; then
  echo 'local rule lookup ignored client scope' >&2; exit 1;
fi
adaptive_rule_add cdn.example.org 93.184.216.34 1 tls default 8 "$fp" "$cat" "$stamp" "$((now + 3600))"
[[ "$(wc -l < "$Z2R_ADAPTIVE_RULES_FILE")" -eq 1 && "$(cut -f7 "$Z2R_ADAPTIVE_RULES_FILE")" = 8 ]] || { echo 'exact tuple was not replaced' >&2; exit 1; }
found="$(adaptive_rule_lookup_local cdn.example.org 93.184.216.34 1 tls default "$stamp")"
[[ "${found%%$'\t'*}" = 8 ]] || { echo 'updated exact local rule was not found' >&2; exit 1; }
for _ in $(seq 1 30); do [[ -s "$ZATOR_ROOT/extra_strats/cache/adaptive/rules.tsv" ]] && break; sleep 0.1; done
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
if adaptive_rule_add cdn.example.org 93.184.216.34 1 tls default 7 "$fp" "$cat" "$stamp" "$((now + 604900))"; then
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
source "$ROOT/lib/config.sh"
eval "$(sed -n '/^z2r_backup_state_files()/,/^}/p' "$ROOT/lib/actions.sh")"
backup_state="$(z2r_backup_state_files)"
[[ "$backup_state" == *'extra_strats/cache/adaptive/rules.tsv'* && "$backup_state" != *'extra_strats/cache/adaptive/token'* ]] || {
  echo 'backup must preserve adaptive rules without copying the pairing secret' >&2; exit 1;
}
for _ in $(seq 1 30); do [[ -s "$ZATOR_ROOT/extra_strats/cache/adaptive/rules.tsv" ]] && break; sleep 0.1; done
cat > "$tmp/init" <<'INIT'
#!/bin/sh
exit 0
INIT
chmod +x "$tmp/init"
ZAPRET2_INIT="$tmp/init" z2r_service_action restart
[[ ! -e "$Z2R_ADAPTIVE_RULES_FILE" && -s "$ZATOR_ROOT/extra_strats/cache/adaptive/rules.tsv" ]] || { echo 'service restart did not retain the stamp-checked snapshot' >&2; exit 1; }
adaptive_rules_runtime_reset
adaptive_rule_add cdn.example.org 93.184.216.34 1 tls default 7 "$fp" "$cat" "$stamp" "$((now + 3600))"
printf 'TEST_VALUE=before\n' > "$tmp/config"
config_set_var "$tmp/config" TEST_VALUE after
[[ ! -e "$Z2R_ADAPTIVE_RULES_FILE" && ! -e "$ZATOR_ROOT/extra_strats/cache/adaptive/rules.tsv" ]] || { echo 'config_set_var left stale adaptive rules' >&2; exit 1; }
echo 'adaptive rule store smoke: ok'
