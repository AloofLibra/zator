#!/bin/bash

set -e

REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/z2r_updater_cli.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

RUNTIME_DIR="$TEST_DIR/runtime"
STATE_DIR="$TEST_DIR/state"
mkdir -p "$RUNTIME_DIR/zapret2/z2r_lib"
cp "$REPO_DIR/z2r.sh" "$RUNTIME_DIR/z2r.sh"
cp "$REPO_DIR/lib/"*.sh "$RUNTIME_DIR/zapret2/z2r_lib/"

run_z2r() {
  Z2R_DISABLE_SELF_REFRESH=1 \
  Z2R_UPDATE_DIR="$STATE_DIR" \
  Z2R_UPDATE_CONFIG="$STATE_DIR/update.conf" \
  bash "$RUNTIME_DIR/z2r.sh" "$@"
}

run_z2r source set Sehat1137/zator zator > "$TEST_DIR/set.out"
grep -F 'Z2R_PROJECT_RAW_BASE="Sehat1137/zator"' "$STATE_DIR/update.conf" >/dev/null
grep -F 'Z2R_BRANCH="zator"' "$STATE_DIR/update.conf" >/dev/null

commit="0123456789abcdef0123456789abcdef01234567"
run_z2r source pin "$commit" > "$TEST_DIR/pin.out"
grep -F "Z2R_BRANCH=\"$commit\"" "$STATE_DIR/update.conf" >/dev/null

run_z2r source show > "$TEST_DIR/show.out"
grep -F 'Настроенный источник: Sehat1137/zator' "$TEST_DIR/show.out" >/dev/null
grep -F "Запрошенный ref: $commit" "$TEST_DIR/show.out" >/dev/null

echo "updater cli smoke ok"
