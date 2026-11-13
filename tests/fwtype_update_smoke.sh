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

# Routine deployment keeps user Ramp controls and regenerates derived argv.
cat > "$ZAPRET2_ROOT/config.default" <<'EOF'
FWTYPE=iptables
Z2R_WSSIZE_RAMP_ENABLE=0
Z2R_WSSIZE_RAMP_MODE=full
Z2R_WSSIZE_RAMP_WSIZE=1
Z2R_WSSIZE_RAMP_SCALE=1
Z2R_WSSIZE_RAMP_OPEN=1
Z2R_WSSIZE_RAMP_ARGS=
Z2R_WSSIZE_RAMP_SKIP=--skip
EOF
cat > "$ZAPRET2_ROOT/config" <<'EOF'
FWTYPE=iptables
Z2R_WSSIZE_RAMP_ENABLE=1
Z2R_WSSIZE_RAMP_MODE=lite
Z2R_WSSIZE_RAMP_SCALE=8
EOF
config_apply_from_default preserve_wssize
[ "$(config_get_var "$ZAPRET2_ROOT/config" Z2R_WSSIZE_RAMP_ENABLE)" = 1 ]
[ "$(config_get_var "$ZAPRET2_ROOT/config" Z2R_WSSIZE_RAMP_MODE)" = lite ]
[ "$(config_get_var "$ZAPRET2_ROOT/config" Z2R_WSSIZE_RAMP_SCALE)" = 8 ]
[ "$(config_get_var "$ZAPRET2_ROOT/config" Z2R_WSSIZE_RAMP_ARGS)" = ':mode=lite:wsize=1:scale=8:open=1' ]
[ -z "$(config_get_var "$ZAPRET2_ROOT/config" Z2R_WSSIZE_RAMP_SKIP)" ]

# Explicit reset without preserve flag still applies the disabled default.
config_apply_from_default
[ "$(config_get_var "$ZAPRET2_ROOT/config" Z2R_WSSIZE_RAMP_ENABLE)" = 0 ]
[ "$(config_get_var "$ZAPRET2_ROOT/config" Z2R_WSSIZE_RAMP_MODE)" = full ]
[ "$(config_get_var "$ZAPRET2_ROOT/config" Z2R_WSSIZE_RAMP_SCALE)" = 1 ]
[ "$(config_get_var "$ZAPRET2_ROOT/config" Z2R_WSSIZE_RAMP_SKIP)" = --skip ]

# Both normal and economy deploy paths must request preservation.
sed -n '/^deploy_apply_config_to_live() {/,/^}/p' "$REPO_DIR/lib/deploy.sh" | grep -q 'config_apply_from_default preserve_wssize' || {
  echo 'FAIL: deploy must preserve user Ramp settings' >&2
  exit 1
}

# Установка использует тот же выбор, без отдельной копии условия.
sed -n '/^get_repo() {/,/^}/p' "$REPO_DIR/z2r.sh" | grep -q 'config_fwtype_apply_default' || {
  echo 'FAIL: get_repo must use the shared firewall selection' >&2
  exit 1
}
echo 'fwtype update smoke ok'
