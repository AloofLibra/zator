"""Run with python webui-src/scripts/check-recommendations.py (stdlib only)."""
import importlib.util
import json
from pathlib import Path
import shutil
import os
import tempfile
import threading
from urllib.request import Request, urlopen

import sys
sys.dont_write_bytecode = True
scratch = Path.home() / 'AppData/Local/hermes/cache/scratch' if os.name == 'nt' else Path(os.environ.get('TMPDIR', '/tmp'))
scratch.mkdir(parents=True, exist_ok=True)
tempfile.tempdir = str(scratch)
root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('fake_router', root / 'webui/dev/fake_router_server.py')
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
state = module.FakeRouterState(str(root / 'config.default'), 'running', 'none', 'ok', [], 'TEST', str(root / 'fake'), repo_root=str(root), delay=0)
server = module.ThreadingHTTPServer(('127.0.0.1', 0), module.FakeRouterHandler)
server.router_state = state
server.webui_root = str(root / 'webui')
threading.Thread(target=server.serve_forever, daemon=True).start()
base = 'http://127.0.0.1:%s' % server.server_port

def get():
    with urlopen(base + '/cgi-bin/settings.cgi?setting=recommendations') as response:
        return json.load(response)

try:
    data = get()
    assert data.get('status') == 'ready', 'independent recommendations GET must return simulated ready data'
    assert 'симуляция' in data['provider'].lower()
    assert data['minimum'] == 10 and data['samples'] >= 10
    assert set(data['profiles']) == {'1', '2', '3', '4'}
    for profile in data['profiles'].values():
        assert len(profile['top']) == 3
        assert isinstance(profile['clone_recommended'], bool)
        assert all(row['samples'] > 0 and 0 <= row['success_pct'] <= 100 for row in profile['top'])
    for status in ['insufficient', 'stale', 'unavailable', 'unknown_provider']:
        request = Request(base + '/__dev/state', data=json.dumps({'recommendations_status': status}).encode(), headers={'Content-Type': 'application/json'})
        with urlopen(request) as response:
            assert json.load(response)['recommendations_status'] == status
        result = get()
        assert result['status'] == status
        assert bool(result['profiles']['1']['top']) == (status == 'stale')
        if status == 'insufficient':
            assert result['samples'] < 10
    print('recommendations fake GET smoke ok')
finally:
    server.shutdown()
    server.server_close()
    shutil.rmtree(state.tmpdir)
