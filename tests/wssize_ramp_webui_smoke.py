#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import threading
import urllib.error
import urllib.parse
import urllib.request
from http.server import ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("fake_router_server", ROOT / "webui/dev/fake_router_server.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
state = mod.FakeRouterState(
    config_default_path=str(ROOT / "config.default"), service_state="running",
    lock_state="none", check_result="ok", simulate_error=[], provider="test",
    fake_dir=str(ROOT / "fake"), repo_root=str(ROOT), delay=0, status_delay=0)
server = ThreadingHTTPServer(("127.0.0.1", 0), mod.FakeRouterHandler)
server.router_state = state
server.webui_root = str(ROOT / "webui")
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
base = "http://127.0.0.1:{0}/cgi-bin/settings.cgi".format(server.server_port)
try:
    with urllib.request.urlopen(base + "?setting=wssize_ramp") as response:
        initial = json.load(response)
    assert initial == {"enabled": False, "mode": "full", "scale": 1, "googlevideo_ips": 0,
                       "googlevideo_local_collection": "unsupported"}, initial

    body = urllib.parse.urlencode({
        "setting": "wssize_ramp", "value": "1", "mode": "lite", "scale": "8",
    }).encode()
    request = urllib.request.Request(base, data=body, method="POST")
    with urllib.request.urlopen(request) as response:
        applied = json.load(response)
    assert applied["enabled"]
    assert applied["mode"] == "lite" and applied["scale"] == 8
    assert applied["restarted"] is True

    body = urllib.parse.urlencode({
        "setting": "wssize_ramp", "value": "0", "mode": "full", "scale": "1",
    }).encode()
    with urllib.request.urlopen(urllib.request.Request(base, data=body, method="POST")) as response:
        disabled = json.load(response)
    assert disabled["enabled"] is False and disabled["scale"] == 1
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=2)
    import shutil
    shutil.rmtree(state.tmpdir, ignore_errors=True)

print("wssize_ramp webui smoke ok")
