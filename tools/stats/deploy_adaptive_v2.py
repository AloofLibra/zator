#!/usr/bin/env python3
"""Install the opt-in adaptive V2 API and its periodic Redis materializer."""
import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import shutil
import subprocess


MAX_TOKEN = re.compile(r"^[A-Za-z0-9_-]{32,128}$")
GET_ROUTE = '''        if parsed.path in ("/adaptive-v2/rankings", "/adaptive-v2/rankings.tsv"):
            providers = parse_qs(parsed.query, keep_blank_values=True).get("provider", [])
            profiles = parse_qs(parsed.query, keep_blank_values=True).get("profile", [])
            protocols = parse_qs(parsed.query, keep_blank_values=True).get("protocol", ["tls"])
            recipes = parse_qs(parsed.query, keep_blank_values=True).get("recipe", ["tls-http1-v1"])
            treatments = parse_qs(parsed.query, keep_blank_values=True).get("treatment", ["standard"])
            try:
                if (len(providers) != 1 or len(profiles) != 1 or len(protocols) != 1
                        or len(recipes) != 1 or len(treatments) != 1):
                    raise ValueError("invalid ranking request")
                global ADAPTIVE_V2_ALIASES
                if ADAPTIVE_V2_ALIASES is None:
                    ADAPTIVE_V2_ALIASES = load_aliases(ADAPTIVE_V2_ALIASES_PATH)
                result = get_adaptive_rankings(rdb, providers[0], profiles[0], protocols[0], ADAPTIVE_V2_ALIASES,
                                               recipe=recipes[0], treatment=treatments[0])
            except ValueError:
                self.send_json(400, {"ok": False, "error": "invalid ranking request"})
                return
            except Exception:
                self.send_json(503, {"ok": False, "error": "adaptive rankings unavailable"})
                return
            if parsed.path.endswith(".tsv"):
                body = render_adaptive_rankings_tsv(result).encode("ascii")
                self.send_response(200)
                self.send_header("content-type", "text/tab-separated-values; charset=us-ascii")
                self.send_header("cache-control", "public, max-age=600")
                self.send_header("content-length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_json(200, result)
            return
'''
POST_BROWSER_FLOW_ROUTE = '''        parsed = urlparse(self.path)
        if parsed.path == "/adaptive-v2/browser-flow":
            expected = os.environ.get("Z4R_ADAPTIVE_V2_INGEST_TOKEN", "")
            auth = self.headers.get("Authorization", "")
            supplied = auth[7:] if auth.startswith("Bearer ") else ""
            try:
                length = int(self.headers.get("content-length", "0"))
            except ValueError:
                length = 0
            if not expected:
                self.send_json(503, {"ok": False, "error": "adaptive ingestion unavailable"})
                return
            if not supplied:
                self.send_json(403, {"ok": False, "error": "forbidden"})
                return
            if length < 1 or length > 32768:
                self.send_json(413, {"ok": False, "error": "invalid or oversized batch"})
                return
            try:
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
                source = authenticate_adaptive_client(rdb, supplied, expected)
                if source is None:
                    self.send_json(403, {"ok": False, "error": "forbidden"})
                    return
                accepted = ingest_browser_flow_batch(rdb, payload, expected, aliases=adaptive_aliases(), source_digest=source)
            except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
                message = str(exc)
                status = 429 if "budget" in message else (409 if "request id" in message else 400)
                self.send_json(status, {"ok": False, "error": "invalid browser evidence batch"})
                return
            except Exception:
                self.send_json(503, {"ok": False, "error": "browser evidence ingestion unavailable"})
                return
            self.send_json(200, {"ok": True, "accepted": accepted, "source": "browser_flow"})
            return
'''
POST_ROUTE = '''        parsed = urlparse(self.path)
        if parsed.path == "/adaptive-v2/results":
            expected = os.environ.get("Z4R_ADAPTIVE_V2_INGEST_TOKEN", "")
            auth = self.headers.get("Authorization", "")
            supplied = auth[7:] if auth.startswith("Bearer ") else ""
            try:
                length = int(self.headers.get("content-length", "0"))
            except ValueError:
                length = 0
            if not expected:
                self.send_json(503, {"ok": False, "error": "adaptive ingestion unavailable"})
                return
            if not supplied:
                self.send_json(403, {"ok": False, "error": "forbidden"})
                return
            if length < 1 or length > 32768:
                self.send_json(413, {"ok": False, "error": "invalid or oversized batch"})
                return
            try:
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
                source = authenticate_adaptive_client(rdb, supplied, expected)
                if source is None:
                    self.send_json(403, {"ok": False, "error": "forbidden"})
                    return
                accepted = ingest_adaptive_batch(rdb, payload, expected, aliases=adaptive_aliases(), source_digest=source)
            except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
                message = str(exc)
                status = 429 if "budget" in message else (409 if "request id" in message else 400)
                self.send_json(status, {"ok": False, "error": "invalid adaptive batch"})
                return
            except Exception:
                self.send_json(503, {"ok": False, "error": "adaptive ingestion unavailable"})
                return
            self.send_json(200, {"ok": True, "accepted": accepted})
            return
'''


def patch_server(server):
    if "import json" not in server:
        server, count = re.subn(r"(?m)^(import redis\n)",
            r"\1import json\n", server, count=1)
        if count != 1:
            raise RuntimeError("cannot find redis import in stats server")
    if "import hmac" not in server:
        server, count = re.subn(r"(?m)^(import redis\n)", r"\1import hmac\n", server, count=1)
        if count != 1:
            raise RuntimeError("cannot find redis import in stats server")
    adaptive_import = re.search(r"(?m)^from adaptive_results import (.*)$", server)
    if adaptive_import:
        names = set(adaptive_import.group(1).split(", "))
        names.update(("authenticate_client_token as authenticate_adaptive_client", "get_rankings as get_adaptive_rankings",
                      "ingest_batch as ingest_adaptive_batch", "load_aliases",
                      "ingest_browser_batch as ingest_browser_flow_batch",
                      "render_rankings_tsv as render_adaptive_rankings_tsv"))
        server = server[:adaptive_import.start()] + "from adaptive_results import " + ", ".join(sorted(names)) + server[adaptive_import.end():]
    else:
        server, count = re.subn(r"(?m)^(import redis\n)",
            r"\1from adaptive_results import authenticate_client_token as authenticate_adaptive_client, get_rankings as get_adaptive_rankings, ingest_batch as ingest_adaptive_batch, ingest_browser_batch as ingest_browser_flow_batch, load_aliases, render_rankings_tsv as render_adaptive_rankings_tsv\n",
            server, count=1)
        if count != 1:
            raise RuntimeError("cannot find redis import in stats server")
    if "def adaptive_aliases():" not in server:
        anchor = "REDIS_URL = os.environ.get(\"Z4R_STATS_REDIS\", \"redis://127.0.0.1:6379/0\")\n"
        helper = '''ADAPTIVE_V2_ALIASES_PATH = os.environ.get(
    "Z4R_STATS_PROVIDER_ASN", os.path.join(os.path.dirname(__file__), "asn.txt"))
ADAPTIVE_V2_ALIASES = None

def adaptive_aliases():
    global ADAPTIVE_V2_ALIASES
    if ADAPTIVE_V2_ALIASES is None:
        ADAPTIVE_V2_ALIASES = load_aliases(ADAPTIVE_V2_ALIASES_PATH)
    return ADAPTIVE_V2_ALIASES

'''
        if server.count(anchor) != 1:
            raise RuntimeError("cannot find Redis URL insertion point")
        server = server.replace(anchor, helper + anchor, 1)
    route_start = server.find('        if parsed.path in ("/adaptive-v2/rankings", "/adaptive-v2/rankings.tsv"):\n')
    legacy_route = server.find('        if parsed.path == "/googlevideo-ips.txt":', route_start + 1)
    if route_start >= 0 and legacy_route > route_start:
        # V2 may already be installed. Replace its whole ranking block on
        # upgrades so new recipe dimensions do not get masked by the old code.
        server = server[:route_start] + GET_ROUTE + server[legacy_route:]
    elif '"/adaptive-v2/rankings.tsv"' not in server:
        anchor = "    def do_GET(self):\n        parsed = urlparse(self.path)\n        params = parse_qs(parsed.query)\n"
        if server.count(anchor) != 1:
            raise RuntimeError("cannot find unique GET insertion point")
        server = server.replace(anchor, anchor + GET_ROUTE, 1)
    if 'parsed.path == "/adaptive-v2/browser-flow"' not in server:
        anchor = "    def do_POST(self):\n"
        if server.count(anchor) != 1:
            raise RuntimeError("cannot find unique POST insertion point")
        server = server.replace(anchor, anchor + POST_BROWSER_FLOW_ROUTE, 1)
    if 'parsed.path == "/adaptive-v2/results"' not in server:
        anchor = "    def do_POST(self):\n"
        if server.count(anchor) != 1:
            raise RuntimeError("cannot find unique POST insertion point")
        server = server.replace(anchor, anchor + POST_ROUTE, 1)
    return server


def patch_nginx(config):
    ranking = '''location = /z4r/adaptive-v2/rankings {
    proxy_pass http://127.0.0.1:17683/adaptive-v2/rankings$is_args$args;
}

'''
    ranking_tsv = '''location = /z4r/adaptive-v2/rankings.tsv {
    proxy_pass http://127.0.0.1:17683/adaptive-v2/rankings.tsv$is_args$args;
}

'''
    ingest = '''location = /z4r/adaptive-v2/results {
    client_max_body_size 32k;
    proxy_pass http://127.0.0.1:17683/adaptive-v2/results;
}

'''
    browser_flow = '''location = /z4r/adaptive-v2/browser-flow {
    client_max_body_size 32k;
    proxy_pass http://127.0.0.1:17683/adaptive-v2/browser-flow;
}

'''
    if "/z4r/adaptive-v2/rankings" not in config:
        anchor = "location = /z4r/recommendations.tsv {"
        if config.count(anchor) != 1:
            raise RuntimeError("cannot find recommendations nginx route")
        config = config.replace(anchor, ranking + anchor, 1)
    if "/z4r/adaptive-v2/rankings.tsv" not in config:
        anchor = "location = /z4r/recommendations.tsv {"
        if config.count(anchor) != 1:
            raise RuntimeError("cannot find recommendations nginx route")
        config = config.replace(anchor, ranking_tsv + anchor, 1)
    if "/z4r/adaptive-v2/results" not in config:
        anchor = "location = /z4r/recommendations.tsv {"
        if config.count(anchor) != 1:
            raise RuntimeError("cannot find recommendations nginx route")
        config = config.replace(anchor, ingest + anchor, 1)
    if "/z4r/adaptive-v2/browser-flow" not in config:
        anchor = "location = /z4r/recommendations.tsv {"
        if config.count(anchor) != 1:
            raise RuntimeError("cannot find recommendations nginx route")
        config = config.replace(anchor, browser_flow + anchor, 1)
    return config


SERVICE = """[Unit]
Description=Refresh adaptive strategy rankings
After=network-online.target redis-server.service z4r-stats.service

[Service]
Type=oneshot
User=z4rstats
Group=z4rstats
EnvironmentFile=/etc/z4r-stats.env
WorkingDirectory=/opt/z4r-stats
ExecStart=/usr/bin/python3 /opt/z4r-stats/refresh_adaptive_v2.py
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
"""
TIMER = """[Unit]
Description=Refresh adaptive strategy rankings every 10 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
RandomizedDelaySec=90
Persistent=true
Unit=z4r-adaptive-v2-refresh.service

[Install]
WantedBy=timers.target
"""


def install(stage, root, ingest_token=None, activate=False):
    stats = root / "opt/z4r-stats"
    env_path = root / "etc/z4r-stats.env"
    nginx_path = root / "etc/nginx/snippets/z4r-stats.conf"
    service_path = root / "etc/systemd/system/z4r-adaptive-v2-refresh.service"
    timer_path = root / "etc/systemd/system/z4r-adaptive-v2-refresh.timer"
    module_src = stage / "adaptive_results.py"
    worker_src = stage / "refresh_adaptive_v2.py"
    token_src = stage / "adaptive_client_token.py"
    for source in (module_src, worker_src, token_src):
        if not source.is_file():
            raise FileNotFoundError(source)
    if not env_path.is_file():
        raise FileNotFoundError(env_path)
    if not nginx_path.is_file():
        raise FileNotFoundError(nginx_path)
    env = env_path.read_text(encoding="utf-8")
    if ingest_token is not None:
        if not MAX_TOKEN.fullmatch(ingest_token):
            raise ValueError("invalid adaptive V2 token")
        env = re.sub(r"(?m)^Z4R_ADAPTIVE_V2_INGEST_TOKEN=.*\n?", "", env)
        env += "\nZ4R_ADAPTIVE_V2_INGEST_TOKEN=" + ingest_token + "\n"
    token_match = re.search(r"(?m)^Z4R_ADAPTIVE_V2_INGEST_TOKEN=([A-Za-z0-9_-]{32,128})\s*$", env)
    if not token_match:
        raise ValueError("set a secure Z4R_ADAPTIVE_V2_INGEST_TOKEN before installation")

    paths = [stats / "server_redis.py", env_path, nginx_path, service_path, timer_path,
             stats / "adaptive_results.py", stats / "refresh_adaptive_v2.py"]
    paths.append(stats / "adaptive_client_token.py")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backups = {}
    for path in paths:
        backups[path] = path.with_name(path.name + ".bak-adaptive-v2-" + stamp) if path.exists() else None
        if backups[path]:
            shutil.copy2(path, backups[path])
    try:
        server_path = stats / "server_redis.py"
        server_path.write_text(patch_server(server_path.read_text(encoding="utf-8")), encoding="utf-8")
        env_path.write_text(env, encoding="utf-8")
        nginx_path.write_text(patch_nginx(nginx_path.read_text(encoding="utf-8")), encoding="utf-8")
        shutil.copy2(module_src, stats / "adaptive_results.py")
        shutil.copy2(worker_src, stats / "refresh_adaptive_v2.py")
        shutil.copy2(token_src, stats / "adaptive_client_token.py")
        os.chmod(stats / "refresh_adaptive_v2.py", 0o644)
        os.chmod(stats / "adaptive_client_token.py", 0o755)
        service_path.write_text(SERVICE, encoding="utf-8")
        timer_path.write_text(TIMER, encoding="utf-8")
        if activate:
            subprocess.run(["/usr/bin/python3", "-m", "py_compile", str(server_path),
                            str(stats / "adaptive_results.py"), str(stats / "refresh_adaptive_v2.py"),
                            str(stats / "adaptive_client_token.py")], check=True)
            subprocess.run(["nginx", "-t"], check=True)
            subprocess.run(["systemctl", "restart", "z4r-stats.service"], check=True)
            subprocess.run(["systemctl", "reload", "nginx.service"], check=True)
            subprocess.run(["systemctl", "enable", "--now", "z4r-adaptive-v2-refresh.timer"], check=True)
    except Exception:
        for path, backup in backups.items():
            if backup and backup.exists():
                shutil.copy2(backup, path)
            elif path.exists():
                path.unlink()
        raise
    return backups


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage-dir", type=Path, default=Path("/tmp"))
    parser.add_argument("--root", type=Path, default=Path("/"))
    parser.add_argument("--ingest-token")
    parser.add_argument("--activate", action="store_true")
    args = parser.parse_args()
    backups = install(args.stage_dir, args.root, args.ingest_token, args.activate)
    print("adaptive V2 API installed; backups:")
    for path, backup in backups.items():
        print(f"  {path}: {backup or '(new file)'}")


if __name__ == "__main__":
    main()
