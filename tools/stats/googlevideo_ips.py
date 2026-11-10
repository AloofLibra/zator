"""Build a small, recent IPv4 set from consented YouTube media host observations."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import socket
import struct
import time

HOSTS_KEY = "z4r:googlevideo:v1:hosts"
OBSERVATIONS_KEY = "z4r:googlevideo:v1:observations"
LOCAL_IPS_KEY = "z4r:googlevideo:v1:local_ips"
RUNS_KEY = "z4r:supersweep:runs"
HOST_TTL = 45 * 86400
IP_TTL = 7 * 86400
OBSERVATION_TTL = 30 * 86400
MAX_HOSTS = 4000
MAX_IPS = 8192
DNS_RESOLVERS = {"google": "8.8.8.8", "cloudflare": "1.1.1.1", "quad9": "9.9.9.9"}
HOST_RE = re.compile(r"^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+googlevideo\.com\.?$", re.I)


def normalize_host(value):
    if not isinstance(value, str):
        return None
    host = value.strip().rstrip(".").lower()
    prefix = host[:-len(".googlevideo.com")] if host.endswith(".googlevideo.com") else ""
    try:
        ipaddress.IPv4Address(prefix)
        ip_literal_prefix = True
    except ipaddress.AddressValueError:
        ip_literal_prefix = False
    if len(host) <= 253 and HOST_RE.fullmatch(host) and host != "googlevideo.com" and not ip_literal_prefix:
        return host
    return None


def _decode(value):
    return value.decode("utf-8", "replace") if isinstance(value, bytes) else str(value or "")


def _hosts_in_media_meta(raw):
    try:
        data = json.loads(_decode(raw))
    except (ValueError, TypeError):
        return set()
    names = data.get("cdn_hostname", {}) if isinstance(data, dict) else {}
    if not isinstance(names, dict):
        return set()
    return {host for host in (normalize_host(names.get("audio")), normalize_host(names.get("video"))) if host}


def _decode_dns_name(packet, offset, depth=0):
    if depth > 8:
        raise ValueError("DNS compression loop")
    labels, jumped, end = [], False, offset
    while True:
        if offset >= len(packet):
            raise ValueError("truncated DNS name")
        size = packet[offset]
        if size & 0xC0 == 0xC0:
            if offset + 1 >= len(packet):
                raise ValueError("truncated DNS pointer")
            pointer = ((size & 0x3F) << 8) | packet[offset + 1]
            if not jumped:
                end = offset + 2
            suffix, _ = _decode_dns_name(packet, pointer, depth + 1)
            if suffix:
                labels.extend(suffix.split("."))
            break
        if size & 0xC0 or size > 63:
            raise ValueError("invalid DNS label")
        offset += 1
        if size == 0:
            if not jumped:
                end = offset
            break
        if offset + size > len(packet):
            raise ValueError("truncated DNS label")
        labels.append(packet[offset:offset + size].decode("ascii", "ignore"))
        offset += size
    return ".".join(labels).lower(), end


def dns_a_query(host, resolver, timeout=2.0):
    """Resolve A via a named public recursive resolver using the stdlib only."""
    labels = host.rstrip(".").split(".")
    qname = b"".join(bytes((len(label),)) + label.encode("ascii") for label in labels) + b"\0"
    ident = secrets.randbits(16)
    query = struct.pack("!HHHHHH", ident, 0x0100, 1, 0, 0, 0) + qname + struct.pack("!HH", 1, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout)
        sock.sendto(query, (resolver, 53))
        packet, peer = sock.recvfrom(4096)
    if peer[0] != resolver:
        return []
    if len(packet) < 12:
        return []
    rid, flags, questions, answers, _, _ = struct.unpack("!HHHHHH", packet[:12])
    if rid != ident or flags & 0x8000 == 0 or flags & 0x0200 or flags & 0x000F or questions != 1:
        return []
    question, offset = _decode_dns_name(packet, 12)
    offset += 4
    if question != host.rstrip(".").lower():
        return []
    records = []
    for _ in range(answers):
        owner, offset = _decode_dns_name(packet, offset)
        if offset + 10 > len(packet):
            return []
        rtype, rclass, _, size = struct.unpack("!HHIH", packet[offset:offset + 10])
        offset += 10
        data = packet[offset:offset + size]
        offset += size
        if rclass == 1 and rtype == 1 and size == 4:
            ip = str(ipaddress.IPv4Address(data))
            if ipaddress.IPv4Address(ip).is_global:
                records.append((owner, rtype, ip))
        elif rclass == 1 and rtype == 5:
            try:
                target, _ = _decode_dns_name(packet, offset - size)
                records.append((owner, rtype, target))
            except ValueError:
                continue
    reachable = {question}
    for _ in range(len(records) + 1):
        expanded = reachable | {value for owner, kind, value in records if kind == 5 and owner in reachable}
        if expanded == reachable:
            break
        reachable = expanded
    ips = {value for owner, kind, value in records if kind == 1 and owner in reachable}
    return sorted(ips)


def seed_hosts_from_url_list(url= "https://raw.githubusercontent.com/nickspaargaren/no-google/master/categories/youtubeparsed", timeout=8):
    """Accept only concrete googlevideo subdomains; the current source may contain none."""
    from urllib.request import urlopen
    with urlopen(url, timeout=timeout) as response:
        rows = response.read(512 * 1024).decode("utf-8", "replace").splitlines()
    return {host for host in (normalize_host(row.split("#", 1)[0].strip()) for row in rows) if host}


def collect_hosts(rdb, seed_file=None, now=None):
    now = int(time.time() if now is None else now)
    cutoff = now - HOST_TTL
    ids = rdb.lrange(RUNS_KEY, 0, 499)
    pipe = rdb.pipeline(transaction=False)
    for run_id in ids:
        pipe.hgetall("z4r:supersweep:run:" + _decode(run_id))
    hosts = {}
    for run in pipe.execute():
        if not isinstance(run, dict):
            continue
        try:
            run = {_decode(k): _decode(v) for k, v in run.items()}
            created = int(dict(line.split("\t", 1) for line in run.get("raw:meta.tsv", "").splitlines() if "\t" in line).get("created", now))
        except (ValueError, TypeError):
            created = now
        if now - HOST_TTL <= created <= now + 300:
            for host in _hosts_in_media_meta(run.get("raw:media-meta.json", "")):
                hosts[host] = max(created, hosts.get(host, 0))
    if seed_file:
        path = Path(seed_file)
        if path.is_file():
            for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
                host = normalize_host(line.split("#", 1)[0].strip())
                if host:
                    hosts[host] = max(now, hosts.get(host, 0))
    # Any live hostname already learned stays eligible until its host TTL expires.
    for host, seen in rdb.zrangebyscore(HOSTS_KEY, cutoff, "+inf", withscores=True):
        host = normalize_host(_decode(host))
        if host:
            hosts[host] = max(int(seen), hosts.get(host, 0))
    rdb.zremrangebyscore(HOSTS_KEY, "-inf", cutoff)
    if hosts:
        rdb.zadd(HOSTS_KEY, hosts)
    rdb.zremrangebyrank(HOSTS_KEY, 0, -MAX_HOSTS - 1)
    return sorted(hosts, key=lambda h: hosts[h], reverse=True)[:MAX_HOSTS]


def refresh(rdb, seed_file=None, source_url=None, now=None):
    now = int(time.time() if now is None else now)
    hosts = set(collect_hosts(rdb, seed_file, now))
    if source_url:
        try:
            hosts.update(seed_hosts_from_url_list(source_url))
        except Exception:
            pass
    if not hosts:
        return 0
    jobs = [(host, name, ip) for host in sorted(hosts)
            for name, ip in DNS_RESOLVERS.items()]
    observations = []
    with ThreadPoolExecutor(max_workers=32) as pool:
        futures = [(host, name, pool.submit(dns_a_query, host, resolver))
                   for host, name, resolver in jobs]
        for host, resolver, future in futures:
            try:
                for ip in future.result():
                    observations.append((host, resolver, ip))
            except (OSError, ValueError, socket.timeout):
                continue
    if observations:
        pipe = rdb.pipeline(transaction=False)
        pipe.zadd(OBSERVATIONS_KEY, {
            f"{host}\t{resolver}\t{ip}": now for host, resolver, ip in observations
        })
        pipe.zremrangebyscore(OBSERVATIONS_KEY, "-inf", now - OBSERVATION_TTL)
        pipe.zremrangebyrank(OBSERVATIONS_KEY, 0, -MAX_IPS * 3 - 1)
        pipe.execute()
    return len(observations)


def render_ipset(rdb, now=None, max_age=IP_TTL):
    now = int(time.time() if now is None else now)
    rows = rdb.zrangebyscore(OBSERVATIONS_KEY, now - max_age, now, withscores=True)
    ips = set()
    for member, _ in rows:
        fields = _decode(member).split("\t")
        if len(fields) != 3 or not normalize_host(fields[0]) or fields[1] not in DNS_RESOLVERS:
            continue
        try:
            address = ipaddress.IPv4Address(fields[2])
        except ipaddress.AddressValueError:
            continue
        if address.is_global:
            ips.add(str(address))
    for raw_ip, _ in rdb.zrangebyscore(LOCAL_IPS_KEY, now - IP_TTL, now, withscores=True):
        try:
            address = ipaddress.IPv4Address(_decode(raw_ip))
        except ipaddress.AddressValueError:
            continue
        if address.is_global:
            ips.add(str(address))
    stamp = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return "# googlevideo IPv4; generated={0}; max_age={1}s\n".format(stamp, max_age) + "".join(ip + "\n" for ip in sorted(ips, key=lambda x: int(ipaddress.IPv4Address(x))))


def observe_local_ips(rdb, values, now=None):
    """Store a bounded batch of consented router dnsmasq set observations."""
    if not isinstance(values, (list, tuple)) or len(values) > 512:
        raise ValueError("invalid local IP batch")
    now = int(time.time() if now is None else now)
    ips = set()
    for value in values:
        try:
            address = ipaddress.IPv4Address(value)
        except (ipaddress.AddressValueError, TypeError):
            raise ValueError("invalid IPv4 address")
        if not address.is_global:
            raise ValueError("non-public IPv4 address")
        ips.add(str(address))
    if ips:
        pipe = rdb.pipeline(transaction=False)
        pipe.zadd(LOCAL_IPS_KEY, {ip: now for ip in ips})
        pipe.zremrangebyscore(LOCAL_IPS_KEY, "-inf", now - IP_TTL)
        pipe.zremrangebyrank(LOCAL_IPS_KEY, 0, -MAX_IPS - 1)
        pipe.execute()
    return len(ips)


def domain_summary(rdb, now=None, max_age=OBSERVATION_TTL):
    """Return compact host/IP history for the authenticated Zator dashboard."""
    now = int(time.time() if now is None else now)
    rows = rdb.zrangebyscore(OBSERVATIONS_KEY, now - max_age, now, withscores=True)
    hosts, ip_hosts = {}, {}
    for member, score in rows:
        fields = _decode(member).split("\t")
        if len(fields) != 3:
            continue
        host, resolver, raw_ip = fields
        host = normalize_host(host)
        if not host or resolver not in DNS_RESOLVERS:
            continue
        try:
            address = ipaddress.IPv4Address(raw_ip)
        except ipaddress.AddressValueError:
            continue
        if not address.is_global:
            continue
        ip = str(address)
        item = hosts.setdefault(host, {"ips": {}, "last_seen": 0})
        ip_item = item["ips"].setdefault(ip, {"last_seen": 0, "resolvers": set()})
        ip_item["last_seen"] = max(ip_item["last_seen"], int(score))
        ip_item["resolvers"].add(resolver)
        item["last_seen"] = max(item["last_seen"], int(score))
        ip_hosts.setdefault(ip, set()).add(host)
    host_rows = []
    for host, data in hosts.items():
        ips = sorted(data["ips"], key=lambda value: int(ipaddress.IPv4Address(value)))
        address_rows = [{"ip": ip, "last_seen": data["ips"][ip]["last_seen"],
                         "resolvers": sorted(data["ips"][ip]["resolvers"])} for ip in ips]
        host_rows.append({"host": host, "ips": ips, "addresses": address_rows, "last_seen": data["last_seen"],
                          "resolvers": sorted({resolver for info in data["ips"].values() for resolver in info["resolvers"]})})
    host_rows.sort(key=lambda row: (-row["last_seen"], row["host"]))
    cidr_rows = []
    local_ips = []
    for raw_ip, score in rdb.zrangebyscore(LOCAL_IPS_KEY, now - IP_TTL, now, withscores=True):
        try:
            ip = str(ipaddress.IPv4Address(_decode(raw_ip)))
        except ipaddress.AddressValueError:
            continue
        if ipaddress.IPv4Address(ip).is_global:
            local_ips.append({"ip": ip, "last_seen": int(score)})
    local_ips.sort(key=lambda row: int(ipaddress.IPv4Address(row["ip"])))
    local_set = {row["ip"] for row in local_ips}
    known = set(ip_hosts)
    for network in ipaddress.collapse_addresses(ipaddress.IPv4Address(ip) for ip in known | local_set):
        members = [str(ip) for ip in network if str(ip) in known | local_set]
        domains = sorted({host for ip in members for host in ip_hosts.get(ip, set())})
        cidr_rows.append({"cidr": str(network), "ip_count": len(members), "domain_count": len(domains),
                          "domains": domains[:8], "more_domains": max(0, len(domains) - 8)})
    cidr_rows.sort(key=lambda row: (ipaddress.ip_network(row["cidr"]).network_address, ipaddress.ip_network(row["cidr"]).prefixlen))
    return {"generated_at": now, "max_age": max_age,
            "domain_count": len(host_rows), "ip_count": len(known | local_set),
            "local_ip_count": len(local_set), "local_ips": local_ips,
            "domains": host_rows, "cidrs": cidr_rows}


def redis_from_env():
    import redis
    return redis.Redis.from_url(os.environ.get("Z4R_STATS_REDIS", "redis://127.0.0.1:6379/0"))


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("refresh", "write"))
    parser.add_argument("--seed", default=os.environ.get("Z4R_GOOGLEVIDEO_SEEDS", ""))
    parser.add_argument("--output", default=os.environ.get("Z4R_GOOGLEVIDEO_OUTPUT", ""))
    parser.add_argument("--source-url", default=os.environ.get("Z4R_GOOGLEVIDEO_HOST_SOURCE", "https://raw.githubusercontent.com/nickspaargaren/no-google/master/categories/youtubeparsed"))
    args = parser.parse_args()
    db = redis_from_env()
    if args.command == "refresh":
        count = refresh(db, args.seed or None, args.source_url or None)
        print(f"observations_added={count}")
    else:
        payload = render_ipset(db)
        if args.output:
            target = Path(args.output)
            target.parent.mkdir(parents=True, exist_ok=True)
            temp = target.with_suffix(target.suffix + ".tmp")
            temp.write_text(payload, encoding="ascii")
            temp.replace(target)
        else:
            print(payload, end="")
