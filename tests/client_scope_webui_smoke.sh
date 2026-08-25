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
PYTHONDONTWRITEBYTECODE=1 python - <<'PY'
import ast, importlib.util, pathlib
path = pathlib.Path("webui/dev/fake_router_server.py")
ast.parse(path.read_text(encoding="utf-8"))
spec = importlib.util.spec_from_file_location("fake_router_server", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
valid = mod.FakeRouterHandler._valid_scope
assert valid("default") and valid("mark:0") and valid("mark:123"), "valid scopes rejected"
for bad in ("bad", "mark:", "mark:-1", "mark:1x", "mark:1\t"):
    assert not valid(bad), "invalid scope accepted: %r" % bad
PY
test ! -e "$REPO_DIR/webui/dev/__pycache__/fake_router_server.cpython-311.pyc" || fail 'compiled pyc artifact'
grep -q 'profile_scoped_state_display' "$REPO_DIR/webui/cgi-bin/_lib.sh" || fail 'scoped effective lock reader'
grep -q 'orch_scoped_effective' "$REPO_DIR/webui/dev/fake_router_server.py" || fail 'fake effective lock reader'
grep -q 'client_scope_diagnostics' "$REPO_DIR/webui/dev/fake_router_server.py" || fail 'fake diagnostics contract'
grep -q 'client_scope_diagnostics_json' "$REPO_DIR/webui/cgi-bin/_lib.sh" || fail 'scope diagnostics API'
grep -q 'fallback_reason' "$REPO_DIR/webui/cgi-bin/_lib.sh" || fail 'fallback reason API'
grep -q 'last_seen_scope' "$REPO_DIR/webui/app.js" || fail 'scope diagnostics UI'
PYTHONDONTWRITEBYTECODE=1 python - <<'PY'
from pathlib import Path
text = Path('webui/cgi-bin/_lib.sh').read_text(encoding='utf-8')
body = text.split('client_scope_diagnostics_json() {', 1)[1].split('\n}\n\nclient_scopes_json()', 1)[0]
assert 'payload' not in body and 'source_ip' not in body and 'client_ip' not in body, 'scope diagnostics leak private data'
PY
printf 'client scope webui smoke ok\n'
