#!/usr/bin/env bash
# Called by the POSIX Keenetic NDM hook after firewall reconstruction.
set -u

ROOT="${ZATOR_ROOT:-/opt/zator}"
ZA_ROOT="${ZAPRET2_ROOT:-/opt/zapret2}"
export ZATOR_ROOT="$ROOT" ZAPRET2_ROOT="$ZA_ROOT"
LIB="$ROOT/z2r_lib"
CONFIG="$ZA_ROOT/config"

[ -f "$LIB/config.sh" ] && [ -f "$LIB/supersweep_transport.sh" ] &&
  [ -f "$LIB/adaptive_lan_transport.sh" ] || exit 0
. "$LIB/config.sh"
. "$LIB/supersweep_transport.sh"
. "$LIB/adaptive_lan_transport.sh"

FWTYPE="$(config_get_var "$CONFIG" FWTYPE 2>/dev/null | tr -d '"\047')"
DESYNC_MARK="$(config_get_var "$CONFIG" DESYNC_MARK 2>/dev/null | tr -d '"\047')"
DESYNC_MARK_POSTNAT="$(config_get_var "$CONFIG" DESYNC_MARK_POSTNAT 2>/dev/null | tr -d '"\047')"
FILTER_MARK="$(config_get_var "$CONFIG" FILTER_MARK 2>/dev/null | tr -d '"\047')"
CLIENT_SCOPE_MARK_MASK="$(config_get_var "$CONFIG" CLIENT_SCOPE_MARK_MASK 2>/dev/null | tr -d '"\047')"
export FWTYPE DESYNC_MARK DESYNC_MARK_POSTNAT FILTER_MARK CLIENT_SCOPE_MARK_MASK

adaptive_lan_transport_reconcile
