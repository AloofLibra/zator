#!/bin/sh
[ "$table" != "mangle" ] && [ "$table" != "nat" ] && exit 0

/opt/zapret2/init.d/sysv/zapret2 restart-fw

# Keenetic ndm пересобирает firewall при любом событии в сети: правила
# client scope (mangle/ZATOR_CLIENT_SCOPE) при этом пропадают, режим
# остаётся включённым, и клиенты молча падают в default scope.
# Переустанавливаем их централизованным reconcile (no-op при выключенном режиме).
if [ -f "${ZATOR_ROOT:-/opt/zator}/z2r_lib/config.sh" ]; then
  . "${ZATOR_ROOT:-/opt/zator}/z2r_lib/config.sh" && client_scope_firewall_reconcile || true
fi

exit 0
