#!/usr/bin/env bash
set -eu
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
grep -q 'PARAM_SCOPE="default"' "$REPO_DIR/webui/cgi-bin/_lib.sh" || fail 'legacy scope default'
grep -q 'api_scopes' "$REPO_DIR/webui/cgi-bin/_lib.sh" || fail 'scope dispatcher'
grep -q 'scope' "$REPO_DIR/webui/cgi-bin/scopes.cgi" || fail 'scopes CGI'
grep -q 'scope: state.scope' "$REPO_DIR/webui/app.js" || fail 'client sends scope'
grep -q 'lock_source' "$REPO_DIR/webui/cgi-bin/_lib.sh" || fail 'effective source JSON'
grep -q ' Некорректный scope' "$REPO_DIR/webui/cgi-bin/_lib.sh" || grep -q 'Некорректный scope' "$REPO_DIR/webui/cgi-bin/_lib.sh" || fail 'invalid scope response'
grep -q 'scopes' "$REPO_DIR/webui/dev/fake_router_server.py" || fail 'fake router scopes'
bash -n "$REPO_DIR/webui/cgi-bin/_lib.sh" "$REPO_DIR/webui/cgi-bin/scopes.cgi"
python -m py_compile "$(cygpath -w "$REPO_DIR/webui/dev/fake_router_server.py")"
printf 'client scope webui smoke ok\n'
