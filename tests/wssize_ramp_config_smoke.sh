#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIG="$ROOT/config.default"
TMP_DIR="$(mktemp -d /tmp/z2r-wssize-settings.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

[ "$(grep -Fxc -- '--lua-desync=wssize_ramp${Z2R_WSSIZE_RAMP_ARGS}' "$CONFIG")" -eq 1 ]
[ "$(grep -Fxc -- '--payload=all,empty' "$CONFIG")" -eq 1 ]
[ "$(grep -Fxc -- 'Z2R_WSSIZE_RAMP_SYNDATA=0' "$CONFIG")" -eq 1 ]
grep -Fq -- 'Z2R_WSSIZE_RAMP_SYNDATA" = 1' "$CONFIG"
grep -Fq -- '--out-range=-n1 --in-range=x --payload=empty --lua-desync=z2r_googlevideo_syndata' "$CONFIG"
render_config() {
    local enabled="$1" syndata="$2" blob="${3:-}" rendered
    rendered="$TMP_DIR/config.$enabled.$syndata"
    cp "$CONFIG" "$rendered"
    sed -i "s/^Z2R_WSSIZE_RAMP_ENABLE=.*/Z2R_WSSIZE_RAMP_ENABLE=$enabled/; s/^Z2R_WSSIZE_RAMP_SYNDATA=.*/Z2R_WSSIZE_RAMP_SYNDATA=$syndata/" "$rendered"
    if [ "$#" -ge 3 ]; then sed -i "s/^Z2R_WSSIZE_RAMP_SYN_BLOB=.*/Z2R_WSSIZE_RAMP_SYN_BLOB=$blob/" "$rendered"; fi
    bash -c '. "$1"; printf "%s\n" "$NFQWS2_OPT"' _ "$rendered"
}
for combo in '0 0' '0 1' '1 0'; do
    set -- $combo
    ! render_config "$1" "$2" | grep -Fq -- 'z2r_googlevideo_syndata'
done
rendered="$(render_config 1 1)"
printf '%s\n' "$rendered" | grep -Fq -- '--out-range=-n1 --in-range=x --payload=empty --lua-desync=z2r_googlevideo_syndata'
printf '%s\n' "$rendered" | grep -Fq -- '--lua-desync=z2r_googlevideo_syndata:blob=tlsgoogle'
rendered_zero="$(render_config 1 1 '')"
printf '%s\n' "$rendered_zero" | grep -Fq -- '--lua-desync=z2r_googlevideo_syndata'
! printf '%s\n' "$rendered_zero" | grep -Fq -- 'z2r_googlevideo_syndata:blob='
grep -Fq -- 'Z2R_WSSIZE_RAMP_SYN_BLOB=tlsgoogle' "$CONFIG"
grep -Fq -- '--blob=tlsgoogle:@/opt/zator/files/fake/tls_clienthello_www_google_com_2.bin' "$CONFIG"
tar -tzf "$ROOT/fake_files.tar.gz" | grep -Fxq 'tls_clienthello_www_google_com_2.bin'
grep -Fq -- 'tls_clienthello_www_google_com_2.bin' "$ROOT/z2r.sh"
syn_line="$(printf '%s\n' "$rendered" | grep -nF -- '--out-range=-n1 --in-range=x --payload=empty --lua-desync=z2r_googlevideo_syndata' | cut -d: -f1 | head -n 1)"
ramp_line="$(printf '%s\n' "$rendered" | grep -nF -- '--lua-desync=wssize_ramp:mode=full:wsize=1:scale=1:open=1' | cut -d: -f1 | head -n 1)"
rst_line="$(printf '%s\n' "$rendered" | grep -nF -- '--in-range=-s32768 --lua-desync=rst_guard_locked:key=2:' | cut -d: -f1 | head -n 1)"
import_line="$(printf '%s\n' "$rendered" | grep -nFx -- '--import=z2r_tcp_tls_common' | cut -d: -f1 | head -n 1)"
[ "$ramp_line" -lt "$syn_line" ] && [ "$syn_line" -lt "$rst_line" ] && [ "$rst_line" -lt "$import_line" ]
printf '%s\n' "$rendered" | grep -Fq -- '--out-range=a'
printf '%s\n' "$rendered" | grep -Fq -- '--in-range=a'
printf '%s\n' "$rendered" | grep -Fq -- '--payload=all,empty'
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
    exact && /\$\{Z2R_WSSIZE_RAMP_SYN_OPT\}/ { syndata++; next }
    exact && /--lua-desync=rst_guard_locked:key=2:/ { key2++; next }
    exact && /^--import=z2r_tcp_tls_common$/ { imported=1; exact_done=1; exact=0 }
    END { if (ramp != 1 || syndata != 1 || key2 != 1 || !imported || !outall || !inall || !payloadall) exit 1 }
' "$CONFIG"
grep -Fq -- '--lua-desync=circular_locked:key=2:exclude_substrings=/opt/zator/lists/netrogat_substrings.txt:payload=tls_client_hello' "$CONFIG"
! grep -Fq -- '--lua-desync=rst_guard_locked:key=1:' "$CONFIG"
echo "wssize_ramp config smoke ok"

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
backup_smart_set_wssize_ramp "$CFG" 1 lite 8 1
[ "$(config_get_var "$CFG" Z2R_WSSIZE_RAMP_SYNDATA)" = 1 ]
backup_smart_set_wssize_ramp "$CFG" 1 full 2
[ "$(config_get_var "$CFG" Z2R_WSSIZE_RAMP_SYNDATA)" = 1 ] # Old callers preserve the setting.
if backup_smart_set_wssize_ramp "$CFG" 1 other 5; then exit 1; fi
if backup_smart_set_wssize_ramp "$CFG" 1 full 15; then exit 1; fi
if backup_smart_set_wssize_ramp "$CFG" 1 full 5 3; then exit 1; fi
[ "$(config_get_var "$CFG" Z2R_WSSIZE_RAMP_MODE)" = full ]
backup_smart_set_wssize_ramp "$CFG" 0 full 1
[ "$(config_get_var "$CFG" Z2R_WSSIZE_RAMP_ENABLE)" = 0 ]
[ "$(config_get_var "$CFG" Z2R_WSSIZE_RAMP_SYNDATA)" = 0 ]
echo "wssize_ramp settings smoke ok"
