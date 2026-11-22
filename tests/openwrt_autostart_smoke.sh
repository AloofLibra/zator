#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

awk '
  /^z2r_openwrt_enable_zapret2_init\(\) \{/ { copying=1; depth=0 }
  copying {
    print
    line=$0
    opens=gsub(/\{/, "{", line)
    closes=gsub(/\}/, "}", line)
    depth += opens - closes
    if (depth == 0) exit
  }
' "$ROOT/z2r.sh" > "$tmp/helper.sh"
grep -q '^z2r_openwrt_enable_zapret2_init()' "$tmp/helper.sh"

source "$tmp/helper.sh"
export OSystem=WRT
export ZAPRET2_ROOT="$tmp/zapret2"
export ZAPRET2_INIT="$ZAPRET2_ROOT/init.d/openwrt/zapret2"
export Z2R_OPENWRT_INIT_LINK="$tmp/etc/init.d/zapret2"
mkdir -p "$(dirname "$ZAPRET2_INIT")"
cat > "$ZAPRET2_INIT" <<'MOCK'
#!/bin/sh
case "$1" in
  enable) touch "${MOCK_ENABLED:?}" ;;
  enabled) test -f "${MOCK_ENABLED:?}" ;;
  *) exit 2 ;;
esac
MOCK
chmod +x "$ZAPRET2_INIT"
export MOCK_ENABLED="$tmp/enabled"

z2r_openwrt_enable_zapret2_init
[[ -L "$Z2R_OPENWRT_INIT_LINK" ]]
[[ "$(readlink -f "$Z2R_OPENWRT_INIT_LINK")" = "$(readlink -f "$ZAPRET2_INIT")" ]]
[[ -f "$MOCK_ENABLED" ]]
z2r_openwrt_enable_zapret2_init

# Do not replace a pre-existing unrelated init link.
rm -f "$Z2R_OPENWRT_INIT_LINK" "$MOCK_ENABLED"
printf '#!/bin/sh\nexit 0\n' > "$tmp/other-init"
chmod +x "$tmp/other-init"
ln -s "$tmp/other-init" "$Z2R_OPENWRT_INIT_LINK"
if z2r_openwrt_enable_zapret2_init >/dev/null 2>&1; then
  echo 'unrelated OpenWrt init link was accepted' >&2
  exit 1
fi
[[ "$(readlink -f "$Z2R_OPENWRT_INIT_LINK")" = "$(readlink -f "$tmp/other-init")" ]]

OSystem=entware
z2r_openwrt_enable_zapret2_init
echo 'OpenWrt zapret2 autostart registration passed'
