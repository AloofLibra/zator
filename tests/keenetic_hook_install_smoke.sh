#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/zator-keenetic-hook.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

function_body="$(sed -n '/^z2r_install_keenetic_ndm_hook() {/,/^}/p' "$REPO_DIR/z2r.sh")"
[ -n "$function_body" ] || { echo 'FAIL: NDM hook installer function is missing' >&2; exit 1; }
eval "$function_body"

z2r_download_project_file() {
  local dest="$1" rel="$2"
  [ "$rel" = Entware/000-zapret2.sh ] || return 90
  case "${HOOK_DOWNLOAD_MODE:-valid}" in
    fail) return 1 ;;
    valid)
      cat > "$dest" <<'HOOK'
#!/bin/sh
[ "$table" != "mangle" ] && exit 0
/opt/zapret2/init.d/sysv/zapret2 restart-fw
HOOK
      ;;
    invalid) printf '%s\n' 'echo unrelated-valid-shell' > "$dest" ;;
    syntax) printf '%s\n' 'if [' > "$dest" ;;
    *) return 91 ;;
  esac
}

hook="$TMP_DIR/000-zapret2.sh"
printf '%s\n' '#!/bin/sh' 'echo old-hook' > "$hook"
chmod +x "$hook"
old_hash="$(sha256sum "$hook" | awk '{print $1}')"

if HOOK_DOWNLOAD_MODE=fail z2r_install_keenetic_ndm_hook "$hook"; then
  echo 'FAIL: download failure replaced the installed hook' >&2; exit 1
fi
[ "$(sha256sum "$hook" | awk '{print $1}')" = "$old_hash" ] \
  || { echo 'FAIL: download failure changed the installed hook' >&2; exit 1; }

if HOOK_DOWNLOAD_MODE=invalid z2r_install_keenetic_ndm_hook "$hook"; then
  echo 'FAIL: hook without restart-fw was accepted' >&2; exit 1
fi
[ "$(sha256sum "$hook" | awk '{print $1}')" = "$old_hash" ] \
  || { echo 'FAIL: invalid payload replaced the installed hook' >&2; exit 1; }

if HOOK_DOWNLOAD_MODE=syntax z2r_install_keenetic_ndm_hook "$hook"; then
  echo 'FAIL: syntactically invalid hook was accepted' >&2; exit 1
fi
[ "$(sha256sum "$hook" | awk '{print $1}')" = "$old_hash" ] \
  || { echo 'FAIL: syntax-invalid payload replaced the installed hook' >&2; exit 1; }

HOOK_DOWNLOAD_MODE=valid z2r_install_keenetic_ndm_hook "$hook"
grep -Fq '/opt/zapret2/init.d/sysv/zapret2 restart-fw' "$hook" \
  || { echo 'FAIL: verified hook was not installed' >&2; exit 1; }
[ -x "$hook" ] || { echo 'FAIL: installed hook is not executable' >&2; exit 1; }
[ ! -e "$hook.stage.$$" ] || { echo 'FAIL: staging file was left behind' >&2; exit 1; }

fresh="$TMP_DIR/fresh/000-zapret2.sh"
mkdir -p "$(dirname -- "$fresh")"
if HOOK_DOWNLOAD_MODE=invalid z2r_install_keenetic_ndm_hook "$fresh"; then
  echo 'FAIL: invalid initial hook payload was accepted' >&2; exit 1
fi
[ ! -e "$fresh" ] || { echo 'FAIL: invalid initial hook was installed' >&2; exit 1; }

echo 'Keenetic hook install smoke ok: validation, atomic replace, failure preservation'
