#!/usr/bin/env python3
"""Install the Googlevideo DNS feed into the existing z4r stats stack.

Stage googlevideo_ips.py, googlevideo-seed-hosts.txt, dashboard.py and app.js
in /tmp on the stats host, then run this script as root.
"""
import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import shutil
import subprocess
import urllib.request


def checked(command):
    subprocess.run(command, check=True)


def install(stage, root):
    stats = root / "opt/z4r-stats"
    dashboard = root / "opt/z4r-dashboard"
    nginx_conf = root / "etc/nginx/snippets/z4r-stats.conf"
    systemd = root / "etc/systemd/system"
    files = {
        stats / "server_redis.py": None,
        root / "etc/z4r-stats.env": None,
        stats / "googlevideo_ips.py": stage / "googlevideo_ips.py",
        stats / "googlevideo-seed-hosts.txt": stage / "googlevideo-seed-hosts.txt",
        dashboard / "dashboard.py": None,
        dashboard / "app.js": None,
        nginx_conf: None,
        systemd / "z4r-googlevideo-refresh.service": None,
        systemd / "z4r-googlevideo-refresh.timer": None,
    }
    for source in (stage / "googlevideo_ips.py", stage / "googlevideo-seed-hosts.txt"):
        if not source.is_file():
            raise FileNotFoundError(source)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backups = {}
    for path in files:
        if path.exists():
            backup = path.with_name(path.name + ".bak-googlevideo-" + stamp)
            shutil.copy2(path, backup)
            backups[path] = backup
        else:
            backups[path] = None

    try:
        server = (stats / "server_redis.py").read_text(encoding="utf-8")
        if "from googlevideo_ips import render_ipset, observe_local_ips" not in server:
            server, count = re.subn(
                r"(?m)^(from recommendations import .*\n)",
                r"\1from googlevideo_ips import render_ipset, observe_local_ips\n",
                server, count=1)
            if count != 1:
                raise RuntimeError("cannot find recommendations import in server_redis.py")
        if 'parsed.path == "/googlevideo-ips.txt"' not in server:
            anchor = "    def do_GET(self):\n        parsed = urlparse(self.path)\n        params = parse_qs(parsed.query)\n"
            route = '''        if parsed.path == "/googlevideo-ips.txt":
            try:
                body = render_ipset(rdb).encode("ascii")
            except Exception:
                self.send_json(503, {"ok": False, "error": "googlevideo IP set unavailable"})
                return
            self.send_response(200)
            self.send_header("content-type", "text/plain; charset=utf-8")
            self.send_header("cache-control", "public, max-age=3600")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
'''
            if server.count(anchor) != 1:
                raise RuntimeError("cannot find unique do_GET anchor in server_redis.py")
            server = server.replace(anchor, anchor + route, 1)
        if 'parsed.path == "/googlevideo-observations"' not in server:
            anchor = "    def do_POST(self):\n"
            route = '''        parsed = urlparse(self.path)
        if parsed.path == "/googlevideo-observations":
            expected = os.environ.get("Z4R_GOOGLEVIDEO_INGEST_TOKEN", "")
            try:
                length = int(self.headers.get("content-length", "0"))
            except ValueError:
                length = 0
            if not expected or length < 1 or length > 8192:
                self.send_json(503 if not expected else 413, {"ok": False, "error": "invalid or unavailable ingest"})
                return
            fields = parse_qs(self.rfile.read(length).decode("utf-8", "replace"), keep_blank_values=True)
            token = fields.get("token", [""])[0]
            if not hmac.compare_digest(token, expected):
                self.send_json(403, {"ok": False, "error": "forbidden"})
                return
            values = fields.get("ips", [""])[0].split(",")
            try:
                accepted = observe_local_ips(rdb, values, now=int(time.time()))
            except ValueError:
                self.send_json(400, {"ok": False, "error": "invalid IP batch"})
                return
            self.send_json(200, {"ok": True, "accepted": accepted})
            return
'''
            if server.count(anchor) != 1:
                raise RuntimeError("cannot find unique do_POST anchor in server_redis.py")
            server = server.replace(anchor, anchor + route, 1)
        if "import hmac" not in server:
            server, count = re.subn(r"(?m)^import redis$", "import redis\nimport hmac", server, count=1)
            if count != 1:
                raise RuntimeError("cannot add request token comparison import")
        if "import time" not in server:
            server, count = re.subn(r"(?m)^import hmac$", "import hmac\nimport time", server, count=1)
            if count != 1:
                raise RuntimeError("cannot add ingest timestamp import")
        (stats / "server_redis.py").write_text(server, encoding="utf-8")

        if args.ingest_token:
            env_file = root / "etc/z4r-stats.env"
            if not env_file.exists():
                raise FileNotFoundError(env_file)
            env = env_file.read_text(encoding="utf-8")
            env = re.sub(r"(?m)^Z4R_GOOGLEVIDEO_INGEST_TOKEN=.*\n?", "", env)
            if not re.fullmatch(r"[A-Za-z0-9_-]{16,128}", args.ingest_token):
                raise ValueError("invalid --ingest-token format")
            env += "\nZ4R_GOOGLEVIDEO_INGEST_TOKEN=" + args.ingest_token + "\n"
            env_file.write_text(env, encoding="utf-8")

        dashboard_py = (dashboard / "dashboard.py").read_text(encoding="utf-8")
        if "def googlevideo_data():" not in dashboard_py:
            anchor = "snapshot_error = None\n"
            helper = "\n".join([
                "snapshot_error = None",
                "googlevideo_module = None",
                "",
                "",
                "def googlevideo_data():",
                "    if googlevideo_module is None:",
                "        return {\"generated_at\": int(time.time()), \"max_age\": 0, \"domain_count\": 0, \"ip_count\": 0, \"local_ip_count\": 0, \"local_ips\": [], \"domains\": [], \"cidrs\": []}",
                "    try:",
                "        return googlevideo_module.domain_summary(legacy.rdb)",
                "    except Exception:",
                "        logging.exception('googlevideo dashboard data unavailable')",
                "        return {\"generated_at\": int(time.time()), \"max_age\": 0, \"domain_count\": 0, \"ip_count\": 0, \"local_ip_count\": 0, \"local_ips\": [], \"domains\": [], \"cidrs\": []}",
                "",
            ])
            if dashboard_py.count(anchor) != 1:
                raise RuntimeError("cannot find dashboard insertion point")
            dashboard_py = dashboard_py.replace(anchor, helper, 1)
        data_key = "'quality':quality,'attention':attention[:40],'records':current}"
        if "'googlevideo':googlevideo_data()" not in dashboard_py:
            if dashboard_py.count(data_key) != 1:
                raise RuntimeError("cannot find dashboard API data object")
            dashboard_py = dashboard_py.replace(
                data_key, "'quality':quality,'attention':attention[:40],'googlevideo':googlevideo_data(),'records':current}", 1)
        if "import googlevideo_ips as googlevideo_module" not in dashboard_py:
            anchor = "    import server_redis as legacy\n"
            if dashboard_py.count(anchor) != 1:
                raise RuntimeError("cannot find dashboard legacy import")
            dashboard_py = dashboard_py.replace(anchor, anchor + "    import googlevideo_ips as googlevideo_module\n", 1)
        (dashboard / "dashboard.py").write_text(dashboard_py, encoding="utf-8")

        app_js = (dashboard / "app.js").read_text(encoding="utf-8")
        if "function googlevideoPanel(data)" not in app_js:
            anchor = "  function overview() {\n"
            panel = """  function googlevideoPanel(data) {
    const rows = Array.isArray(data?.domains) ? data.domains : [];
    const cidrs = Array.isArray(data?.cidrs) ? data.cidrs : [];
    if (!rows.length) return panel('Googlevideo · домены и IP', 'DNS-наблюдения только для googlevideo.com', empty('Пока нет свежих DNS-наблюдений. Обновление базы выполняется сервером.'), true);
    const hostTable = '<div class="table-scroll"><table><thead><tr><th>Hostname</th><th>IP · время наблюдения · resolver</th><th>Всего IP</th></tr></thead><tbody>' + rows.map(row => `<tr><td class="mono">${e(row.host)}</td><td>${(row.addresses || []).map(a => `<div class="mono">${e(a.ip)} <span class="muted">${e(dateTime(a.last_seen))} · ${e((a.resolvers || []).join(', '))}</span></div>`).join('')}</td><td>${fmt((row.ips || []).length)}</td></tr>`).join('') + '</tbody></table></div>';
    const cidrTable = cidrs.length ? '<div class="table-scroll"><table><thead><tr><th>CIDR</th><th>IP</th><th>Домены</th></tr></thead><tbody>' + cidrs.map(row => `<tr><td class="mono">${e(row.cidr)}</td><td>${fmt(row.ip_count)}</td><td>${(row.domains || []).map(e).join(', ')}${row.more_domains ? ` и ещё ${fmt(row.more_domains)}` : ''}</td></tr>`).join('') + '</tbody></table></div>' : empty();
    const age = Math.round((Number(data.max_age) || 0) / 86400);
    return panel('Googlevideo · hostname → IP', `${fmt(data.domain_count)} доменов · ${fmt(data.ip_count)} адресов · локальных GGC: ${fmt(data.local_ip_count || 0)} · наблюдения за ${age} дн.`, hostTable, true) + panel('Googlevideo · сгруппированные сети', 'Смежные адреса объединены в минимальные CIDR; списки доменов ограничены первыми 8 для читаемости.', cidrTable, true);
  }
"""
            if app_js.count(anchor) != 1:
                raise RuntimeError("cannot find dashboard overview renderer")
            app_js = app_js.replace(anchor, panel + anchor, 1)
        panel_call = "    html += googlevideoPanel(d.googlevideo);\n"
        if panel_call not in app_js:
            anchor = "    html += panel('Требуют внимания',"
            if app_js.count(anchor) != 1:
                raise RuntimeError("cannot find dashboard overview panel")
            app_js = app_js.replace(anchor, panel_call + anchor, 1)
        (dashboard / "app.js").write_text(app_js, encoding="utf-8")

        snippet = nginx_conf.read_text(encoding="utf-8")
        if "location = /z4r/googlevideo-ips.txt" not in snippet:
            anchor = "location = /z4r/recommendations.tsv {"
            route = '''location = /z4r/googlevideo-ips.txt {
    proxy_pass http://127.0.0.1:17683/googlevideo-ips.txt;
}

'''
            if snippet.count(anchor) != 1:
                raise RuntimeError("cannot find recommendations endpoint in nginx stats snippet")
            snippet = snippet.replace(anchor, route + anchor, 1)
        if "location = /z4r/googlevideo-observations" not in snippet:
            anchor = "location = /z4r/googlevideo-ips.txt {"
            route = '''location = /z4r/googlevideo-observations {
    client_max_body_size 8k;
    proxy_pass http://127.0.0.1:17683/googlevideo-observations;
}

'''
            if snippet.count(anchor) != 1:
                raise RuntimeError("cannot find Googlevideo feed route in nginx stats snippet")
            snippet = snippet.replace(anchor, route + anchor, 1)
        nginx_conf.write_text(snippet, encoding="utf-8")

        service = """[Unit]
Description=Refresh Googlevideo DNS observations
After=network-online.target redis-server.service z4r-stats.service
Wants=network-online.target

[Service]
Type=oneshot
User=z4rstats
Group=z4rstats
EnvironmentFile=/etc/z4r-stats.env
WorkingDirectory=/opt/z4r-stats
ExecStart=/usr/bin/python3 /opt/z4r-stats/googlevideo_ips.py refresh --seed /opt/z4r-stats/googlevideo-seed-hosts.txt
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
"""
        timer = """[Unit]
Description=Hourly Googlevideo DNS refresh

[Timer]
OnCalendar=hourly
Persistent=true
RandomizedDelaySec=5m
Unit=z4r-googlevideo-refresh.service

[Install]
WantedBy=timers.target
"""
        (systemd / "z4r-googlevideo-refresh.service").write_text(service, encoding="utf-8")
        (systemd / "z4r-googlevideo-refresh.timer").write_text(timer, encoding="utf-8")
        for destination, source in files.items():
            if source is not None:
                shutil.copy2(source, destination)
        for path in (stats / "googlevideo_ips.py", stats / "googlevideo-seed-hosts.txt"):
            os.chmod(path, 0o644)
        os.chmod(dashboard / "dashboard.py", 0o755)
        os.chmod(dashboard / "app.js", 0o644)

        checked(["/usr/bin/python3", "-m", "py_compile", str(stats / "server_redis.py"),
                 str(stats / "googlevideo_ips.py"), str(dashboard / "dashboard.py")])
        checked(["nginx", "-t"])
        checked(["systemctl", "daemon-reload"])
        checked(["systemctl", "restart", "z4r-stats.service", "z4r-dashboard.service"])
        checked(["systemctl", "reload", "nginx"])
        checked(["systemctl", "enable", "--now", "z4r-googlevideo-refresh.timer"])
        checked(["systemctl", "start", "z4r-googlevideo-refresh.service"])
        result = subprocess.check_output(
            ["systemctl", "show", "-p", "ExecMainStatus", "--value", "z4r-googlevideo-refresh.service"],
            text=True).strip()
        if result != "0":
            raise RuntimeError("initial Googlevideo DNS refresh failed; see journalctl -u z4r-googlevideo-refresh")
        with urllib.request.urlopen("http://127.0.0.1:17683/googlevideo-ips.txt", timeout=8) as response:
            payload = response.read(262145)
            if response.status != 200 or len(payload) > 262144:
                raise RuntimeError("local Googlevideo feed HTTP check failed")
            lines = [line for line in payload.decode("ascii").splitlines()
                     if line and not line.startswith("#")]
            if not lines:
                raise RuntimeError("initial refresh returned no Googlevideo addresses")
        with urllib.request.urlopen("http://127.0.0.1:17684/zator/admin/health", timeout=5) as response:
            if response.status != 200:
                raise RuntimeError("admin dashboard health check failed")
        print("googlevideo server deployed; backup suffix:", ".bak-googlevideo-" + stamp)
        print("feed_ipv4_count:", len(lines))
    except Exception:
        for path, backup in backups.items():
            try:
                if backup is None:
                    path.unlink(missing_ok=True)
                else:
                    shutil.copy2(backup, path)
            except OSError:
                pass
        subprocess.run(["systemctl", "disable", "--now", "z4r-googlevideo-refresh.timer"], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["systemctl", "daemon-reload"], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["systemctl", "restart", "z4r-stats.service", "z4r-dashboard.service"], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["nginx", "-t"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage-dir", default="/tmp")
    parser.add_argument("--root", default="/")
    parser.add_argument("--ingest-token", default="", help="shared token for consented router IP batches")
    args = parser.parse_args()
    install(Path(args.stage_dir), Path(args.root))
