#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIG="$ROOT/config.default"

[ "$(grep -Fxc -- '--lua-desync=wssize_ramp${Z2R_WSSIZE_RAMP_ARGS}' "$CONFIG")" -eq 1 ]
[ "$(grep -Fxc -- '--payload=all,empty' "$CONFIG")" -eq 1 ]
awk '
    $0 == "--template=z2r_tcp_tls_common" { template=1; next }
    template && $0 == "--new" { template=0; awaiting_profile=1; next }
    awaiting_profile && $0 == "--new" { exit 1 }
    awaiting_profile && /--filter-mark=\$\{Z2R_WSSIZE_MARK\}/ { found=1; exit }
    END { if (!found) exit 1 }
' "$CONFIG"
awk '
    $0 == "--template=z2r_tcp_tls_common" { common=1; next }
    common && $0 == "--new" { common=0; next }
    common && /wssize_ramp/ { exit 1 }
    $0 == "#Z2R_AUTO_STANDARD_1_BEGIN" && ! exact_done { exit 1 }
    /\$\{Z2R_WSSIZE_RAMP_SKIP\} --filter-l3=ipv4 --filter-tcp=443 --filter-mark=\$\{Z2R_WSSIZE_MARK\}\/\$\{Z2R_WSSIZE_MARK\}/ { exact=1; next }
    exact && $0 == "--out-range=a" { outall=1; next }
    exact && $0 == "--in-range=a" { inall=1; next }
    exact && $0 == "--payload=all,empty" { payloadall=1; next }
    exact && /--lua-desync=wssize_ramp/ { ramp++; next }
    exact && /--lua-desync=rst_guard_locked:key=2:/ { key2++; next }
    exact && /^--import=z2r_tcp_tls_common$/ { imported=1; exact_done=1; exact=0 }
    END { if (ramp != 1 || key2 != 1 || !imported || !outall || !inall || !payloadall) exit 1 }
' "$CONFIG"
grep -Fq -- '--lua-desync=circular_locked:key=2:exclude_substrings=/opt/zator/lists/netrogat_substrings.txt:payload=tls_client_hello' "$CONFIG"
! grep -Fq -- '--lua-desync=rst_guard_locked:key=1:' "$CONFIG"
echo "wssize_ramp config smoke ok"

TMP_DIR="$(mktemp -d /tmp/z2r-wssize-settings.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
CFG="$TMP_DIR/config"
cp "$CONFIG" "$CFG"
# shellcheck source=../lib/config.sh
. "$ROOT/lib/config.sh"
# shellcheck source=../lib/actions.sh
. "$ROOT/lib/actions.sh"
backup_smart_set_wssize_ramp "$CFG" 1 lite 8
[ "$(config_get_var "$CFG" Z2R_WSSIZE_RAMP_ENABLE)" = 1 ]
[ "$(config_get_var "$CFG" Z2R_WSSIZE_RAMP_MODE)" = lite ]
[ "$(config_get_var "$CFG" Z2R_WSSIZE_RAMP_SCALE)" = 8 ]
if backup_smart_set_wssize_ramp "$CFG" 1 other 5; then exit 1; fi
if backup_smart_set_wssize_ramp "$CFG" 1 full 15; then exit 1; fi
[ "$(config_get_var "$CFG" Z2R_WSSIZE_RAMP_MODE)" = lite ]
backup_smart_set_wssize_ramp "$CFG" 0 full 1
[ "$(config_get_var "$CFG" Z2R_WSSIZE_RAMP_ENABLE)" = 0 ]
echo "wssize_ramp settings smoke ok"
