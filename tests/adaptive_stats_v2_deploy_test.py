"""Install-script contract tests for adaptive V2 HTTP and timer integration."""
from pathlib import Path
from http.server import ThreadingHTTPServer
import importlib.util
import hashlib
import json
import os
import sys
import time
from threading import Thread
import tempfile
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("adaptive_stats_deploy", ROOT / "tools/stats/deploy_adaptive_v2.py")
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)

server_fixture = '''import os
import redis
from http.server import BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
REDIS_URL = os.environ.get("Z4R_STATS_REDIS", "redis://127.0.0.1:6379/0")
rdb = redis.Redis.from_url(REDIS_URL)
class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass
    def send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)
    def do_POST(self):
        pass
'''
patched = deploy.patch_server(server_fixture)
compile(patched, "server_redis.py", "exec")
assert 'get_rankings as get_adaptive_rankings' in patched
assert 'authenticate_client_token as authenticate_adaptive_client' in patched
assert '"/adaptive-v2/rankings.tsv"' in patched
assert '"/adaptive-v2/browser-rankings.tsv"' in patched
assert 'get_browser_rankings as get_adaptive_browser_rankings' in patched
assert 'parsed.path == "/adaptive-v2/results"' in patched
assert 'parsed.path == "/adaptive-v2/browser-flow"' in patched
assert 'source_digest=source' in patched
assert deploy.patch_server(patched) == patched
nginx = 'location = /z4r/recommendations.tsv {\n    proxy_pass http://127.0.0.1:17683/recommendations.tsv$is_args$args;\n}\n'
patched_nginx = deploy.patch_nginx(nginx)
assert ('/z4r/adaptive-v2/rankings' in patched_nginx and '/z4r/adaptive-v2/rankings.tsv' in patched_nginx
        and '/z4r/adaptive-v2/results' in patched_nginx and '/z4r/adaptive-v2/browser-flow' in patched_nginx)
assert '/z4r/adaptive-v2/browser-rankings.tsv' in patched_nginx
assert deploy.patch_nginx(patched_nginx) == patched_nginx

# Exercise the patched handler over a real loopback HTTP socket. The narrow
# Redis adapter below only models token lookup and request idempotency; Redis
# Lua compatibility and concurrent aggregation are covered separately.
sys.path.insert(0, str(ROOT / "tools/stats"))
import adaptive_results


class HttpRedis:
    def __init__(self):
        self.hashes = {}
        self.strings = {}

    def hget(self, key, field):
        return self.hashes.get(key, {}).get(field)

    def get(self, key):
        return self.strings.get(key)

    def eval(self, script, key_count, *args):
        keys, argv = args[:key_count], args[key_count:]
        request_key, request_hash = keys[0], argv[0]
        if request_key in self.strings:
            return 0 if self.strings[request_key] == request_hash else -2
        self.strings[request_key] = request_hash
        return 1


http_db = HttpRedis()
secret = "adaptive-v2-http-test-secret-0123456789abcdef"
client_token = "T" * 48
source = "a" * 64
token_digest = adaptive_results._client_token_digest(client_token, secret)
http_db.hashes["z4r:adaptive:v2:client-tokens"] = {token_digest: source}
redis_stub = type("RedisStub", (), {"Redis": type("Redis", (), {"from_url": staticmethod(lambda *a, **k: http_db)})})
os.environ["Z4R_ADAPTIVE_V2_INGEST_TOKEN"] = secret
os.environ["Z4R_STATS_PROVIDER_ASN"] = str(ROOT / "data/providers/asn.txt")
http_namespace = {"__file__": str(ROOT / "tools/stats/server_redis.py"), "redis": redis_stub}
previous_redis_module = sys.modules.get("redis")
sys.modules["redis"] = redis_stub
try:
    exec(compile(patched, "server_redis.py", "exec"), http_namespace)
finally:
    if previous_redis_module is None:
        del sys.modules["redis"]
    else:
        sys.modules["redis"] = previous_redis_module
Handler = http_namespace["Handler"]
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = Thread(target=server.serve_forever, daemon=True)
thread.start()
base_url = "http://127.0.0.1:%d" % server.server_port


def request(path, body=None, token=None):
    headers = {}
    data = None
    method = "GET"
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
        method = "POST"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = Request(base_url + path, data=data, headers=headers, method=method)
    try:
        with urlopen(req, timeout=5) as response:
            return response.status, response.headers, response.read()
    except HTTPError as response:
        return response.code, response.headers, response.read()


try:
    assert request("/adaptive-v2/rankings?provider=ISP&profile=1")[0] == 200
    assert request("/adaptive-v2/rankings?provider=ISP")[0] == 400
    status, headers, body = request("/adaptive-v2/rankings.tsv?provider=ISP&profile=1")
    assert status == 200 and headers.get_content_type() == "text/tab-separated-values" and body.startswith(b"schema_version=2\nstatus=not_ready\n")
    phash = hashlib.sha256("Example ISP".casefold().encode()).hexdigest()[:24]
    browser_key = f"z4r:adaptive:v2:browser:ranking:{phash}:1:tls"
    http_db.strings[browser_key] = json.dumps({"schema_version": 2, "generated_at": int(time.time()),
        "profile_id": 1, "protocol": "tls", "recipe_id": "tls-http1-v1", "treatment_variant": "standard",
        "rankings": [{"fingerprint": "sha256:" + "c" * 64, "score": .75, "samples": 4,
                      "successes": 3, "failures": 1}]})
    status, _, body = request("/adaptive-v2/browser-rankings.tsv?provider=Example%20ISP&profile=1")
    assert status == 200 and body.startswith(b"schema_version=2\nsource=browser_feedback\nstatus=fresh\n")
    payload = {"schema_version": 2, "request_id": "b" * 32, "provider": "Example ISP", "observed_at": time.time_ns() // 1_000_000_000,
               "recipe_id": "tls-http1-v1", "client_profile": "curl-windows-v1",
               "results": [{"profile_id": 1, "protocol": "tls", "fingerprint": "sha256:" + "c" * 64,
                            "route_verified": True, "transport": "OK", "application": "OK", "verdict": "SUCCESS"}]}
    assert request("/adaptive-v2/results", payload)[0] == 403
    status, _, body = request("/adaptive-v2/results", payload, client_token)
    assert status == 200 and json.loads(body)["accepted"] == 1
    status, _, body = request("/adaptive-v2/results", payload, client_token)
    assert status == 200 and json.loads(body)["accepted"] == 0
    conflict = dict(payload)
    conflict["provider"] = "Other ISP"
    assert request("/adaptive-v2/results", conflict, client_token)[0] == 409
    assert request("/adaptive-v2/results", b"x" * 32769, client_token)[0] == 413
    browser_payload = {"schema_version": 1, "source": "browser_flow", "client_profile": "chromium-v1",
                       "request_id": "c" * 32, "provider": "Example ISP", "observed_at": time.time_ns() // 1_000_000_000,
                       "results": [{"profile_id": 5, "protocol": "quic", "fingerprint": "sha256:" + "d" * 64,
                                    "state": "PROTOCOL_UNKNOWN", "treatment_variant": "standard",
                                    "protocol_proven": False, "confidence": "low"}]}
    assert request("/adaptive-v2/browser-flow", browser_payload)[0] == 403
    status, _, body = request("/adaptive-v2/browser-flow", browser_payload, client_token)
    assert status == 200 and json.loads(body) == {"ok": True, "accepted": 1, "source": "browser_flow"}
    status, _, body = request("/adaptive-v2/browser-flow", browser_payload, client_token)
    assert status == 200 and json.loads(body)["accepted"] == 0
    browser_pii = dict(browser_payload)
    browser_pii["results"] = [dict(browser_payload["results"][0], hostname="private.example")]
    assert request("/adaptive-v2/browser-flow", browser_pii, client_token)[0] == 400
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)

with tempfile.TemporaryDirectory(prefix="adaptive-v2-deploy-") as directory:
    root = Path(directory) / "root"
    stage = Path(directory) / "stage"
    for path in (root / "opt/z4r-stats", root / "etc/nginx/snippets", root / "etc/systemd/system", stage):
        path.mkdir(parents=True, exist_ok=True)
    (root / "opt/z4r-stats/server_redis.py").write_text(server_fixture, encoding="utf-8")
    (root / "etc/z4r-stats.env").write_text("Z4R_ADAPTIVE_V2_INGEST_TOKEN=" + "x" * 48 + "\n", encoding="utf-8")
    (root / "etc/nginx/snippets/z4r-stats.conf").write_text(nginx, encoding="utf-8")
    (stage / "adaptive_results.py").write_text("# module fixture\n", encoding="utf-8")
    (stage / "refresh_adaptive_v2.py").write_text("# worker fixture\n", encoding="utf-8")
    (stage / "adaptive_client_token.py").write_text("# token CLI fixture\n", encoding="utf-8")
    backups = deploy.install(stage, root)
    assert len(backups) == 8
    installed = (root / "opt/z4r-stats/server_redis.py").read_text(encoding="utf-8")
    assert 'parsed.path == "/adaptive-v2/results"' in installed
    assert 'parsed.path == "/adaptive-v2/browser-flow"' in installed
    assert (root / "etc/systemd/system/z4r-adaptive-v2-refresh.timer").is_file()
    assert (root / "opt/z4r-stats/adaptive_client_token.py").is_file()
print("adaptive stats V2 deployment and HTTP smoke: ok")
