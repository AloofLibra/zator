#!/bin/sh
# zator-desktop-probe owned hook
# Run after production and policy-routing hooks have rebuilt their chains.
[ "${table:-}" = mangle ] && [ "${type:-iptables}" = iptables ] || exit 0
[ -x /opt/zator/bin/zator-desktop-probe ] && [ -f /opt/zator/desktop-probe.json ] || exit 0
exec /opt/zator/bin/zator-desktop-probe reconcile-transport
