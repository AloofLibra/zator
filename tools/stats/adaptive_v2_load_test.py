#!/usr/bin/env python3
"""Exercise adaptive V2 Redis ingestion with synthetic concurrent clients.

Use only a disposable, empty Redis database. This tool removes only the
adaptive V2 keys it creates after collecting latency and memory measurements.
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import hashlib
import os
from statistics import median
from threading import Lock
import time
from urllib.parse import urlparse

from adaptive_results import ingest_batch, refresh_rankings, get_rankings, validate_batch


def _owned_ingest_keys(batch):
    keys = {
        "z4r:adaptive:v2:req:" + batch["request_id"],
        f"z4r:adaptive:v2:source:{batch['source']}:{batch['day']}",
        "z4r:adaptive:v2:dimensions:active",
    }
    for row in batch["rows"]:
        dimension = row["dimension"]
        keys.update((f"z4r:adaptive:v2:agg:{row['day']}:{dimension}",
                     f"z4r:adaptive:v2:sources:{dimension}",
                     f"z4r:adaptive:v2:meta:{dimension}"))
    return keys


def _percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int((len(ordered) - 1) * fraction))]


def main():
    import redis

    url = os.environ.get("Z2R_ADAPTIVE_TEST_REDIS_URL", "redis://127.0.0.1:6379/15")
    parsed = urlparse(url)
    if parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
        raise SystemExit("refusing non-local Redis; run a disposable local staging Redis")
    db = redis.Redis.from_url(url, decode_responses=False, socket_timeout=10)
    if not db.ping():
        raise SystemExit("Redis ping failed")
    if db.dbsize() != 0:
        raise SystemExit("selected Redis database is not empty; refusing to add load-test data")

    secret = "adaptive-v2-local-load-test-secret-32chars"
    workers = 64
    owned_keys = set()
    owned_keys_lock = Lock()
    try:
        for client_count in (100, 1000, 10000):
            fingerprint = "sha256:" + hashlib.sha256(f"load-profile-1-{client_count}".encode()).hexdigest()
            provider_hash = hashlib.sha256("adaptive load test isp".encode()).hexdigest()[:24]

            def submit(client_index):
                source_id = hashlib.sha256(f"adaptive-load-{client_count}-{client_index}".encode()).hexdigest()
                request_id = hashlib.sha256(f"request-{client_count}-{client_index}".encode()).hexdigest()[:32]
                payload = {
                    "schema_version": 2,
                    "request_id": request_id,
                    "source_id": source_id,
                    "provider": "Adaptive Load Test ISP",
                    "observed_at": int(time.time()),
                    "recipe_id": "tls-http1-v1",
                    "client_profile": "curl-windows-v1",
                    "results": [{"profile_id": 1, "protocol": "tls", "fingerprint": fingerprint,
                                 "route_verified": True, "transport": "OK", "application": "OK",
                                 "verdict": "SUCCESS"}],
                }
                batch = validate_batch(payload, secret)
                with owned_keys_lock:
                    owned_keys.update(_owned_ingest_keys(batch))
                started = time.perf_counter()
                accepted = ingest_batch(db, payload, secret)
                elapsed_ms = (time.perf_counter() - started) * 1000
                if accepted != 1:
                    raise RuntimeError(f"client {client_index} ingested {accepted} rows")
                return elapsed_ms

            started = time.perf_counter()
            with ThreadPoolExecutor(max_workers=workers) as pool:
                latencies = list(pool.map(submit, range(client_count)))
            wall_seconds = time.perf_counter() - started
            with owned_keys_lock:
                owned_keys.add(f"z4r:adaptive:v2:ranking:{provider_hash}:1:tls")
                owned_keys.add("z4r:adaptive:v2:rankings:refresh-lock")
            refresh_rankings(db, min_sources=10)
            ranking = get_rankings(db, "Adaptive Load Test ISP", 1)
            row = next((item for item in ranking.get("rankings", [])
                        if item["fingerprint"] == fingerprint), None)
            if row is None or row["successes"] != client_count:
                raise RuntimeError(f"exact aggregate mismatch at {client_count} clients: {row!r}")
            used_memory = int(db.info("memory")["used_memory"])
            print("clients=%d workers=%d accepted=%d wall=%.3fs rate=%.1f/s p50=%.3fms p95=%.3fms redis_used=%d bytes" % (
                client_count, workers, client_count, wall_seconds,
                client_count / max(wall_seconds, 0.000001), median(latencies),
                _percentile(latencies, 0.95), used_memory))
    finally:
        keys = list(owned_keys)
        for start in range(0, len(keys), 500):
            db.delete(*keys[start:start + 500])
        leftovers = list(db.scan_iter(count=100))
        db.close()
        if leftovers:
            raise RuntimeError(f"load-test cleanup left {len(leftovers)} keys in the initially empty DB 15")


if __name__ == "__main__":
    main()
