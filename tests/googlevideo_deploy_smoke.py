import importlib.util
import pathlib
import py_compile
import tempfile
from types import SimpleNamespace

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("deploy_googlevideo", ROOT / "tools/stats/deploy_googlevideo_server.py")
DEPLOY = importlib.util.module_from_spec(spec)
spec.loader.exec_module(DEPLOY)


class Response:
    status = 200
    def __init__(self, body=b"# googlevideo IPv4; generated=test\n8.8.8.8\n"):
        self.body = body
    def __enter__(self): return self
    def __exit__(self, *_args): pass
    def read(self, _limit=-1): return self.body


with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    stage = root / "stage"
    stats = root / "opt/z4r-stats"
    dashboard = root / "opt/z4r-dashboard"
    (stage).mkdir()
    stats.mkdir(parents=True)
    dashboard.mkdir(parents=True)
    (root / "etc/nginx/snippets").mkdir(parents=True)
    (root / "etc/systemd/system").mkdir(parents=True)
    (root / "etc/z4r-stats.env").write_text("Z4R_STATS_REDIS=redis://localhost/0\n")
    (stage / "googlevideo_ips.py").write_bytes((ROOT / "tools/stats/googlevideo_ips.py").read_bytes())
    (stage / "googlevideo-seed-hosts.txt").write_text("rr1---sn-test.googlevideo.com\n")
    (stats / "server_redis.py").write_text('''import os, time
from urllib.parse import parse_qs, quote_plus, urlparse
import redis
from recommendations import load_aliases, recommendations_tsv, validate_provider
class Handler:
    def send_json(self, *_args): pass
    def do_GET(self):
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)
    def do_POST(self):
        pass
''')
    (dashboard / "dashboard.py").write_text('''import time, logging
snapshot_error = None
def api():
    import server_redis as legacy
    data = {'quality':quality,'attention':attention[:40],'records':current}
''')
    (dashboard / "app.js").write_text("  function overview() {\n    html += panel('Требуют внимания',\n", encoding="utf-8")
    nginx = root / "etc/nginx/snippets/z4r-stats.conf"
    nginx.write_text("location = /z4r/recommendations.tsv {\n}\n")

    original_checked = DEPLOY.checked
    original_check_output = DEPLOY.subprocess.check_output
    original_urlopen = DEPLOY.urllib.request.urlopen
    original_run = DEPLOY.subprocess.run
    DEPLOY.checked = lambda _cmd: None
    DEPLOY.subprocess.check_output = lambda *_args, **_kwargs: "0"
    DEPLOY.subprocess.run = lambda *_args, **_kwargs: None
    DEPLOY.urllib.request.urlopen = lambda *_args, **_kwargs: Response()
    DEPLOY.args = SimpleNamespace(ingest_token="shared_token_1234567890")
    try:
        DEPLOY.install(stage, root)
    finally:
        DEPLOY.checked = original_checked
        DEPLOY.subprocess.check_output = original_check_output
        DEPLOY.subprocess.run = original_run
        DEPLOY.urllib.request.urlopen = original_urlopen

    server = stats / "server_redis.py"
    deployed = server.read_text()
    assert 'parsed.path == "/googlevideo-observations"' in deployed
    assert "observe_local_ips(rdb" in deployed
    assert "import hmac" in deployed and "import time" in deployed
    assert "Z4R_GOOGLEVIDEO_INGEST_TOKEN=shared_token_1234567890" in (root / "etc/z4r-stats.env").read_text()
    assert "location = /z4r/googlevideo-observations" in nginx.read_text()
    py_compile.compile(str(server), doraise=True)
    py_compile.compile(str(dashboard / "dashboard.py"), doraise=True)

print("googlevideo deploy smoke ok")
