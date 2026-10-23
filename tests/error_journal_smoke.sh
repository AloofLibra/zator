#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eval "$(sed -n '/^z2r_err_journal()/,/^}/p' z2r.sh)"
cat > "$TMP/invalid" <<'EOF'
rawsend: sendto (732): Invalid argument
rawsend: sendto (53): Invalid argument
rawsend: sendto (1500): Invalid argument
EOF
cat > "$TMP/real" <<'EOF'
LUA ERROR: Invalid argument
rawsend: sendto (732): Permission denied
rawsend: sendto (bad): Invalid argument
EOF
{
  printf 'seccomp: note\nrawsend: sendto (10): Network is unreachable\nrawsend: sendto (20): Operation not permitted\nrawsend: sendto (30): Message too large\n'
  cat "$TMP/invalid" "$TMP/real"
} > "$TMP/journal"
cp "$TMP/journal" "$TMP/original"
OSystem=entware
for hardware in keenetic merlin ''; do
  z2r_err_journal "$TMP/journal" > "$TMP/actual"
  cmp -s "$TMP/real" "$TMP/actual" || fail "Entware '$hardware': exact sendto EINVAL must be hidden, real errors retained"
done
for OSystem in WRT VPS ''; do
  cat "$TMP/invalid" "$TMP/real" > "$TMP/expected"
  z2r_err_journal "$TMP/journal" > "$TMP/actual"
  cmp -s "$TMP/expected" "$TMP/actual" || fail "unexpected suppression on platform '$OSystem'"
done
unset OSystem
z2r_err_journal "$TMP/journal" > "$TMP/actual"
cmp -s "$TMP/expected" "$TMP/actual" || fail 'unset OSystem under set -u'
cmp -s "$TMP/original" "$TMP/journal" || fail 'source journal modified'
# Exercise the actual 666 branch with a missing stderr file and prefixed syslog.
branch="$(awk '/^  "666"\)/ {on=1; next} on && /^    ;;$/ {exit} on {print}' z2r.sh)"
branch="${branch//\/tmp\/nfqws2_1.err/\$TMP\/missing.err}"
eval "show_errors() { $branch
}"
ZATOR_ROOT="$TMP"
yellow='' plain='' green=''
pause_enter() { :; }
logread() { sed 's/^/router nfqws2[123]: /' "$TMP/invalid"; }
OSystem=entware
show_errors > "$TMP/menu"
! grep -q 'rawsend:' "$TMP/menu" || fail '666 syslog fallback leaked Entware EINVAL'
grep -q 'Ошибок нет' "$TMP/menu" || fail '666 noise-only log reported errors'
OSystem=WRT
show_errors > "$TMP/menu"
grep -q 'rawsend: sendto (732): Invalid argument' "$TMP/menu" || fail '666 hid errors outside Entware'
printf 'error journal smoke ok\n'
