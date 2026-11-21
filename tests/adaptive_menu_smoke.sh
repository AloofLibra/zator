#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/tools"
cat > "$TMP/tools/adaptive-pair.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$ADAPTIVE_MENU_ACTIONS"
[[ "${1:-}" != status ]] || printf 'Adaptive observation: OFF\n'
EOF
chmod +x "$TMP/tools/adaptive-pair.sh"
export ADAPTIVE_MENU_ACTIONS="$TMP/actions"
export ADAPTIVE_MENU_RESTARTS="$TMP/restarts"
touch "$ADAPTIVE_MENU_ACTIONS" "$ADAPTIVE_MENU_RESTARTS"

ZATOR_ROOT="$TMP"
cyan= green= red= yellow= plain=
. "$REPO_DIR/lib/submenus.sh"
clear() { :; }
submenu_item() { :; }
pause_enter() { :; }
pidof() { return 0; }
z2r_service_action() {
  [[ "$1" = restart ]] || return 1
  printf 'restart\n' >> "$ADAPTIVE_MENU_RESTARTS"
}

adaptive_submenu <<< $'5\n6\n7\n0\n' >/dev/null
expected_actions=$'status\ntest-only\nstatus\npause\nstatus\nevents\nstatus'
[[ "$(cat "$ADAPTIVE_MENU_ACTIONS")" = "$expected_actions" ]] || {
  echo 'FAIL: adaptive menu dispatched an unexpected action sequence' >&2
  exit 1
}
[[ "$(wc -l < "$ADAPTIVE_MENU_RESTARTS" | tr -d '[:space:]')" = 2 ]] || {
  echo 'FAIL: mode changes did not restart the running service exactly twice' >&2
  exit 1
}

: > "$ADAPTIVE_MENU_ACTIONS"
: > "$ADAPTIVE_MENU_RESTARTS"
adaptive_submenu <<< $'9\ny\n0\n' >/dev/null
[[ "$(cat "$ADAPTIVE_MENU_ACTIONS")" = $'status\ndisable\nstatus' ]] || {
  echo 'FAIL: disable was not confirmed or dispatched correctly' >&2
  exit 1
}
[[ "$(wc -l < "$ADAPTIVE_MENU_RESTARTS" | tr -d '[:space:]')" = 1 ]] || {
  echo 'FAIL: disable did not restart the running service' >&2
  exit 1
}

echo 'adaptive menu smoke ok (actions, confirmation, mode restart)'
