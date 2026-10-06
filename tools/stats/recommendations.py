"""Anonymous provider recommendations from retained complete supersweeps."""
from collections import Counter
from fractions import Fraction
from pathlib import Path
import json
import re
import secrets
import threading
import time
import unicodedata

WORKERS = (("yt", 1), ("gv", 2), ("rkn", 3), ("ds", 4))
CACHE_KEY = "z4r:recommendations:v1:all"
LOCK_KEY = CACHE_KEY + ":lock"
REFRESH_LOCK = threading.Lock()


def validate_provider(provider):
    if (not isinstance(provider, str) or not provider.strip() or len(provider) > 120
            or any(unicodedata.category(c).startswith("C") or c in "\u2028\u2029" for c in provider)):
        raise ValueError("invalid provider")
    return provider.strip()


def canonical(provider, aliases=None):
    brand = provider.split(" - ", 1)[0].strip().casefold()
    aliases = aliases or {}
    # Старый детект сохранял holder (AS123): объединяем только известные ASN.
    asn = re.search(r"\(as([0-9]+)\)$", brand)
    return aliases.get(brand, aliases.get("as" + asn[1], brand) if asn else brand)


def load_aliases(path):
    aliases = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        fields = line.split(":")
        if len(fields) == 3 and fields[0].isdigit():
            brand = fields[1].strip().casefold()
            aliases["as" + fields[0]] = brand
            for name in [fields[1], *fields[2].split(",")]:
                if name.strip():
                    aliases[name.strip().casefold()] = brand
    return aliases


def kv(text, separator="="):
    return dict(line.split(separator, 1) for line in text.splitlines() if separator in line)


def completed(run):
    """Require actual full matrices: shell RKN interrupted flag alone is insufficient."""
    status = kv(run.get("raw:status", ""))
    if status.get("state") not in ("done", "applying"):
        return None
    workers = {}
    for line in run.get("raw:workers.tsv", "").splitlines():
        fields = line.split("\t")
        if len(fields) != 6 or fields[0] in workers:
            return None
        workers[fields[0]] = fields
    profiles = {}
    for worker, profile in WORKERS:
        fields = workers.get(worker)
        best = kv(run.get(f"raw:best.{worker}", ""))
        if not fields or fields[3] != str(profile) or best.get("interrupted") != "0":
            return None
        maximum = int(fields[5])
        if maximum < 1:
            return None
        domains = fields[4].split(",") if worker == "rkn" else [str(profile)]
        if not all(domains) or len(set(domains)) != len(domains):
            return None
        domain_set = set(domains)
        seen = set()
        probes = []
        raw = "raw:coverage.tsv" if worker == "rkn" else f"raw:progress.{worker}.tsv"
        for line in run.get(raw, "").splitlines():
            columns = line.split("\t")
            if len(columns) < 4 or columns[3] not in ("ok", "warn", "fail"):
                return None
            key = (columns[1], int(columns[2]))
            if key[0] not in domain_set or not 1 <= key[1] <= maximum or key in seen:
                return None
            seen.add(key)
            probes.append((key[1], columns[3]))
        if len(seen) != len(domains) * maximum:
            return None
        counts = Counter(verdict for _, verdict in probes)
        if worker == "rkn":
            if int(best.get("winner_total", "-1")) != len(domains):
                return None
        elif any(int(best.get(f"n_{v}", "-1")) != counts[v] for v in ("ok", "warn", "fail")):
            return None
        profiles[profile] = probes
    return profiles


def percent(ok, total):
    return f"{100 * ok / total:.6f}".rstrip("0").rstrip(".") if total else "-"


def aggregate(runs, generated_at=0, aliases=None):
    latest = {}
    modes = {}
    for run in runs:
        try:
            profiles = completed(run)
            if profiles is None:
                continue
            meta = kv(run.get("raw:meta.tsv", ""), "\t")
            if any(meta.get(f"mode_{p}", "classic") not in ("classic", "clone") for p in profiles):
                continue
            uuid = str(run.get("uuid") or meta.get("uuid") or "").strip().casefold()
            provider = canonical(validate_provider(meta.get("provider", "")), aliases)
            timestamp = (int(kv(run.get("raw:status", "")).get("started", "0")),
                         int(run.get("received_at", "0")), str(run.get("run_id", "")))
            if not uuid:
                continue
            entry = (timestamp, meta, profiles)
            # zapret2 version is not a strategy-schema version; do not invent a cutoff.
            key = (provider, uuid)
            if key not in latest or timestamp > latest[key][0]:
                latest[key] = entry
            for p in profiles:
                mode = meta.get(f"mode_{p}", "classic")
                key = (provider, uuid, p, mode)
                if key not in modes or timestamp > modes[key][0]:
                    modes[key] = entry
        except (ValueError, TypeError, AttributeError):
            continue
    providers = {}
    for provider, uuid in latest:
        providers.setdefault(provider, {"samples": 0, "profiles": {}})["samples"] += 1
    for provider, item in providers.items():
        for p in range(1, 5):
            cells = {}
            samples = 0
            for (brand, uuid), (_, meta, profiles) in latest.items():
                if brand != provider:
                    continue
                samples += 1
                mode = meta.get(f"mode_{p}", "classic")
                for strategy, verdict in profiles[p]:
                    cell = cells.setdefault(strategy, {"ok": 0, "total": 0, "uuids": set(), "modes": set()})
                    cell["ok"] += verdict == "ok"
                    cell["total"] += 1
                    cell["uuids"].add(uuid)
                    cell["modes"].add(mode)
            evidence = {}
            for mode in ("classic", "clone"):
                ok = total = count = 0
                for (brand, uuid, profile, measured), (_, meta, profiles) in modes.items():
                    if (brand, profile, measured) == (provider, p, mode):
                        count += 1
                        ok += sum(v == "ok" for _, v in profiles[p])
                        total += len(profiles[p])
                evidence[mode] = (ok, total, count)
            classic, clone = evidence["classic"], evidence["clone"]
            recommend = (item["samples"] >= 10 and classic[2] >= 3 and clone[2] >= 3
                         and clone[0] * classic[1] > classic[0] * clone[1])
            ranked = sorted((s for s in cells if cells[s]["ok"]), key=lambda s: (
                -Fraction(cells[s]["ok"], cells[s]["total"]), -len(cells[s]["uuids"]), s))[:3]
            strategies = [[s, percent(cells[s]["ok"], cells[s]["total"]), len(cells[s]["uuids"]),
                           next(iter(cells[s]["modes"])) if len(cells[s]["modes"]) == 1 else "mixed"]
                          for s in ranked] if item["samples"] >= 10 else []
            item["profiles"][str(p)] = [samples, int(recommend), percent(*classic[:2]), percent(*clone[:2]), strategies]
    return {"generated_at": generated_at, "providers": providers}


def render_tsv(data, provider, aliases=None):
    provider = validate_provider(provider)
    item = data["providers"].get(canonical(provider, aliases), {"samples": 0, "profiles": {}})
    lines = [f"meta\t1\t{provider}\t{item['samples']}\t{data['generated_at']}"]
    strategies = []
    for p in range(1, 5):
        samples, hint, classic, clone, ranked = item["profiles"].get(str(p), [0, 0, "-", "-", []])
        lines.append(f"profile\t{p}\t{samples}\t{hint}\t{classic}\t{clone}")
        strategies.extend("\t".join(map(str, ["strategy", p, *row])) for row in ranked)
    return "\n".join(lines + strategies) + "\n"


def recommendations_tsv(rdb, provider, aliases=None):
    provider = validate_provider(provider)
    cached = rdb.get(CACHE_KEY)
    if cached is not None:
        return render_tsv(json.loads(cached), provider, aliases)
    # ponytail: one process/global Redis lock; 500 retained uploads bound refresh work.
    if not REFRESH_LOCK.acquire(timeout=3):
        raise RuntimeError("recommendations refresh busy")
    token = secrets.token_hex(16)
    acquired = False
    try:
        cached = rdb.get(CACHE_KEY)
        if cached is not None:
            return render_tsv(json.loads(cached), provider, aliases)
        acquired = bool(rdb.set(LOCK_KEY, token, nx=True, ex=300))
        if not acquired:
            raise RuntimeError("recommendations refresh busy")
        ids = rdb.lrange("z4r:supersweep:runs", 0, 499)
        pipe = rdb.pipeline(transaction=False)
        for run_id in ids:
            pipe.hgetall("z4r:supersweep:run:" + str(run_id))
        data = aggregate(pipe.execute(), generated_at=int(time.time()), aliases=aliases)
        payload = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
        # Publish only while still owning the lease; an expired writer cannot overwrite.
        published = rdb.eval("""
            if redis.call('GET', KEYS[1]) == ARGV[1] then
                redis.call('SET', KEYS[2], ARGV[2], 'EX', ARGV[3])
                redis.call('DEL', KEYS[1])
                return 1
            end
            return 0
        """, 2, LOCK_KEY, CACHE_KEY, token, payload, 86400)
        if not published:
            raise RuntimeError("recommendations refresh lease expired")
        acquired = False
        return render_tsv(data, provider, aliases)
    finally:
        try:
            if acquired:
                rdb.eval("""
                    if redis.call('GET', KEYS[1]) == ARGV[1] then
                        return redis.call('DEL', KEYS[1])
                    end
                    return 0
                """, 1, LOCK_KEY, token)
        finally:
            REFRESH_LOCK.release()