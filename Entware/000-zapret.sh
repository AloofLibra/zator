#!/bin/sh
[ "$table" != "mangle" ] && [ "$table" != "nat" ] && exit 0

/opt/zapret2/init.d/sysv/zapret2 restart-fw

exit 0
