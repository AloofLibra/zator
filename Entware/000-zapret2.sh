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

# Правила изолированных проб суперавтопрогона тоже выметаются пересборкой:
# пока жив фоновый прогон (transport.env на месте), восстанавливаем их.
_ss_lib="${ZATOR_ROOT:-/opt/zator}/z2r_lib/supersweep_transport.sh"
_ss_env="${Z2R_SUPERSWEEP_DIR:-/tmp/z2r-supersweep}/probe/transport.env"
if [ -f "$_ss_env" ] && [ -f "$_ss_lib" ]; then
  . "$_ss_env"
  . "$_ss_lib"
  supersweep_transport_reconcile >>/tmp/z2r-supersweep-hook.log 2>&1 || true
fi

exit 0
