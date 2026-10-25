#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for file in desktop-probe/install-router.sh desktop-probe/firewall-openwrt.sh desktop-probe/firewall-keenetic.sh Entware/000-zapret2.sh; do bash -n "$file"; done
export ZATOR_ROOT="$tmp/zator" DP_LOG="$tmp/hook.log"
mkdir -p "$ZATOR_ROOT/bin" "$ZATOR_ROOT/z2r_lib"
printf '{}' > "$ZATOR_ROOT/desktop-probe.json"
cat > "$ZATOR_ROOT/z2r_lib/config.sh" <<'EOF'
client_scope_firewall_reconcile() { printf 'client\n' >> "$DP_LOG"; }
EOF
cat > "$ZATOR_ROOT/bin/zator-desktop-probe" <<'EOF'
#!/bin/sh
printf '%s:%s:%s\n' "$table" "$type" "$1" >> "$DP_LOG"
EOF
chmod +x "$ZATOR_ROOT/bin/zator-desktop-probe"
# The production restart is stubbed; no command or file under /opt is touched.
sed 's@^/opt/zapret2/init.d/sysv/zapret2 restart-fw$@printf "restart\\n" >> "$DP_LOG"@' Entware/000-zapret2.sh > "$tmp/hook.sh"
export table=mangle type=iptables
bash "$tmp/hook.sh"
diff -u <(printf 'restart\nclient\nmangle:iptables:reconcile-transport\n') "$DP_LOG"
for pair in 'mangle ip6tables' 'nat iptables' 'filter iptables'; do
  read -r table type <<< "$pair"
  : > "$DP_LOG"
  bash "$tmp/hook.sh"
  ! grep -q reconcile-transport "$DP_LOG"
done
table=mangle type=iptables
rm "$ZATOR_ROOT/desktop-probe.json"
: > "$DP_LOG"
bash "$tmp/hook.sh"
! grep -q reconcile-transport "$DP_LOG"
grep -q '^desktop-probe.json$' lib/actions.sh
# Exercise the separately installed late Keenetic hook without writing /opt.
sed "s@/opt/zator@$ZATOR_ROOT@g" desktop-probe/firewall-keenetic.sh > "$tmp/late-hook.sh"
printf '{}' > "$ZATOR_ROOT/desktop-probe.json"
table=mangle type=iptables
: > "$DP_LOG"
bash "$tmp/late-hook.sh"
diff -u <(printf 'mangle:iptables:reconcile-transport\n') "$DP_LOG"
table=nat
: > "$DP_LOG"
bash "$tmp/late-hook.sh"
[ ! -s "$DP_LOG" ]

# Installer creates defaults once, preserves settings on upgrade and owns only its hook.
mkdir -p "$tmp/opt/etc/ndm/netfilter.d" "$tmp/install"
sed "s@/opt/@$tmp/opt/@g" desktop-probe/install-router.sh > "$tmp/install/install-router.sh"
cp desktop-probe/firewall-keenetic.sh "$tmp/install/"
cat > "$tmp/install/agent" <<'EOF'
#!/bin/sh
if [ "$1" = --default-settings ]; then printf '{"backend":"iptables"}\n'; fi
EOF
chmod +x "$tmp/install/agent"
printf '#!/bin/sh\necho 0\n' > "$tmp/install/id"
chmod +x "$tmp/install/id"
export PATH="$tmp/install:$PATH"
bash "$tmp/install/install-router.sh" install "$tmp/install/agent"
grep -q iptables "$tmp/opt/zator/desktop-probe.json"
printf '{"backend":"custom-preserved"}\n' > "$tmp/opt/zator/desktop-probe.json"
bash "$tmp/install/install-router.sh" install "$tmp/install/agent"
grep -q custom-preserved "$tmp/opt/zator/desktop-probe.json"
bash "$tmp/install/install-router.sh" uninstall
[ ! -e "$tmp/opt/etc/ndm/netfilter.d/999-zator-desktop-probe.sh" ]
printf 'foreign\n' > "$tmp/opt/etc/ndm/netfilter.d/999-zator-desktop-probe.sh"
if bash "$tmp/install/install-router.sh" install "$tmp/install/agent"; then exit 1; fi
grep -qx foreign "$tmp/opt/etc/ndm/netfilter.d/999-zator-desktop-probe.sh"
echo 'desktop probe smoke ok'
