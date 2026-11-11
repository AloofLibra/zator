#!/usr/bin/env bash
# Выбор firewall при применении обновлённого конфига совпадает с установкой.
set -eu
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export ZAPRET2_ROOT="$WORK/zapret2"
mkdir -p "$ZAPRET2_ROOT"
. "$REPO_DIR/lib/config.sh"
. "$REPO_DIR/lib/actions.sh"

# Только конфиг: никаких сервисов, сети и настоящих firewall-правил.
change_user() { :; }
profile_apply_all() { :; }
client_scope_lua_config_sync() { :; }
nft() { [ "$*" = 'list tables' ] && [ "$NFT_OK" = 1 ]; }
iptables() { return 0; }
hardware=generic

check_update() {
  OSystem="$1" NFT_OK="$2"
  printf 'FWTYPE=iptables\n' > "$ZAPRET2_ROOT/config.default"
  printf 'FWTYPE=%s\n' "$3" > "$ZAPRET2_ROOT/config"
  config_apply_from_default
  actual="$(config_get_var "$ZAPRET2_ROOT/config" FWTYPE)"
  [ "$actual" = "$4" ] || {
    echo "FAIL: $OSystem nft=$NFT_OK: expected $4, got $actual" >&2
    exit 1
  }
  [ "$(config_get_var "$ZAPRET2_ROOT/config.default" FWTYPE)" = "$4" ]
}

check_update WRT 1 iptables nftables
check_update VPS 1 iptables nftables
check_update WRT 0 nftables iptables
check_update entware 1 nftables iptables

# Установка использует тот же выбор, без отдельной копии условия.
sed -n '/^get_repo() {/,/^}/p' "$REPO_DIR/z2r.sh" | grep -q 'config_fwtype_apply_default' || {
  echo 'FAIL: get_repo must use the shared firewall selection' >&2
  exit 1
}
echo 'fwtype update smoke ok'
