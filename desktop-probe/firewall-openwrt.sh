#!/bin/sh
# Invoke from a firewall4 script include AFTER the existing zapret2 include.
[ -x /opt/zator/bin/zator-desktop-probe ] || exit 0
[ -f /opt/zator/desktop-probe.json ] || exit 0
exec /opt/zator/bin/zator-desktop-probe reconcile-transport
