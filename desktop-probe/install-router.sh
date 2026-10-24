#!/bin/sh
# Explicit optional component install; no package downloads or service restart.
set -eu
cd "$(dirname "$0")"
case "${1:-}" in
  install)
    [ "$#" = 3 ] || { echo 'usage: sh install-router.sh install <binary> <audited-settings.json>' >&2; exit 2; }
    [ "$(id -u)" = 0 ] || exit 1
    mkdir -p /opt/zator/bin
    cp "$2" /opt/zator/bin/zator-desktop-probe.new
    chmod 755 /opt/zator/bin/zator-desktop-probe.new
    cp "$3" /opt/zator/desktop-probe.json.new
    chmod 600 /opt/zator/desktop-probe.json.new
    /opt/zator/bin/zator-desktop-probe.new --check-settings /opt/zator/desktop-probe.json.new
    # A running session must be stopped before replacing its executable/config.
    if [ -x /opt/zator/bin/zator-desktop-probe ] && [ -f /opt/zator/desktop-probe.json ]; then
      /opt/zator/bin/zator-desktop-probe admin-stop
      /opt/zator/bin/zator-desktop-probe shutdown
      /opt/zator/bin/zator-desktop-probe uninstall-transport
    fi
    # Keep previous assets for a failed installation; they are never production data.
    [ ! -f /opt/zator/desktop-probe.json ] || cp /opt/zator/desktop-probe.json /opt/zator/desktop-probe.json.previous
    [ ! -f /opt/zator/bin/zator-desktop-probe ] || cp /opt/zator/bin/zator-desktop-probe /opt/zator/bin/zator-desktop-probe.previous
    mv /opt/zator/desktop-probe.json.new /opt/zator/desktop-probe.json
    mv /opt/zator/bin/zator-desktop-probe.new /opt/zator/bin/zator-desktop-probe
    if ! /opt/zator/bin/zator-desktop-probe install-transport; then
      if ! /opt/zator/bin/zator-desktop-probe uninstall-transport; then
        echo 'Installation and cleanup failed; current component files retained for retry.' >&2
        exit 1
      fi
      if [ -f /opt/zator/bin/zator-desktop-probe.previous ] && [ -f /opt/zator/desktop-probe.json.previous ]; then
        cp /opt/zator/bin/zator-desktop-probe.previous /opt/zator/bin/zator-desktop-probe
        cp /opt/zator/desktop-probe.json.previous /opt/zator/desktop-probe.json
        /opt/zator/bin/zator-desktop-probe install-transport || { echo 'Rollback needs transport repair.' >&2; exit 1; }
      fi
      echo 'Installation failed; previous component restored when available.' >&2
      exit 1
    fi
    /opt/zator/bin/zator-desktop-probe capabilities
    ;;
  uninstall)
    [ -x /opt/zator/bin/zator-desktop-probe ] || exit 0
    /opt/zator/bin/zator-desktop-probe uninstall-transport
    rm -f /opt/zator/bin/zator-desktop-probe /opt/zator/desktop-probe.json
    ;;
  *) echo 'usage: sh install-router.sh install <binary> <audited-settings.json> | uninstall' >&2; exit 2 ;;
esac
