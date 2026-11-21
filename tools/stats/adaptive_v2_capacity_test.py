#!/usr/bin/env python3
"""Fill the V2 dimension budget with TLS, TCP media, and QUIC on DB 15.

The test refuses remote Redis and any non-empty database. It deletes only the
keys it records as its own and checks that a previously materialized ranking
survives a full dimension set and a rejected overflow request.
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import hashlib
import os
import threading
import time
from urllib.parse import urlparse

from adaptive_results import MAX_DIMENSIONS, RECIPES, get_rankings, ingest_batch, refresh_rankings, validate_batch
from recommendations import canonical, validate_provider


SECRET = "adaptive-v2-capacity-test-secret-32chars"
PROVIDER = "Adaptive Capacity Test ISP"
BASE_PROVIDER = "Adaptive Capacity Baseline ISP"
WORKERS = 32


def _payload(provider: str, label: str, observed: int, fingerprint_label: str | None = None,
             recipe: str = "tls-http1-v1", profile: int = 1, protocol: str = "tls",
             treatment: str = "standard") -> dict:
    digest = hashlib.sha256(label.encode("utf-8")).hexdigest()
    is_media = recipe != "tls-http1-v1"
    return {
        "schema_version": 2,
        "request_id": digest[:32],
        "source_id": hashlib.sha256(("source:" + label).encode("utf-8")).hexdigest(),
        "provider": provider,
        "observed_at": observed,
        "recipe_id": recipe,
        "client_profile": RECIPES[recipe][0],
        "results": [{
            "profile_id": profile,
            "protocol": protocol,
            "fingerprint": "sha256:" + hashlib.sha256(("fingerprint:" + (fingerprint_label or label)).encode("utf-8")).hexdigest(),
            "treatment_variant": treatment,
            "verdict": "SUCCESS",
            "route_verified": True,
            "failure_confirmations": 0,
            "transport": "OK",
            "application": "OK",
            "media_bytes": 1048576 if is_media else 0,
            "media_speed_bps": 1200000 if is_media else 0,
            "media_duration_ms": 800 if is_media else 0,
        }],
    }


def main() -> None:
    import redis

    url = os.environ.get("Z2R_ADAPTIVE_TEST_REDIS_URL", "redis://127.0.0.1:6379/15")
    parsed = urlparse(url)
    if parsed.hostname not in {"127.0.0.1", "localhost", "::1"} or parsed.path != "/15":
        raise SystemExit("refusing anything except loopback Redis database 15")
    db = redis.Redis.from_url(url, decode_responses=False, socket_timeout=20)
    if not db.ping():
        raise SystemExit("Redis ping failed")
    if db.dbsize() != 0:
        raise SystemExit("selected Redis database is not empty; refusing capacity test")

    baseline_provider_hash = hashlib.sha256(canonical(validate_provider(BASE_PROVIDER)).encode("utf-8")).hexdigest()[:24]
    owned: set[str] = {
        "z4r:adaptive:v2:dimensions:active",
        "z4r:adaptive:v2:rankings:refresh-lock",
        f"z4r:adaptive:v2:ranking:{baseline_provider_hash}:1:tls",
    }
    owned_lock = threading.Lock()
    memory_before = int(db.info("memory")["used_memory"])
    observed = int(time.time())

    def submit(payload: dict) -> int:
        batch = validate_batch(payload, SECRET, now=observed)
        source = batch["source"]
        day = batch["day"]
        keys = {
            "z4r:adaptive:v2:req:" + batch["request_id"],
            f"z4r:adaptive:v2:source:{source}:{day}",
        }
        for row in batch["rows"]:
            dim = row["dimension"]
            keys.update((f"z4r:adaptive:v2:agg:{day}:{dim}",
                         f"z4r:adaptive:v2:sources:{dim}",
                         f"z4r:adaptive:v2:meta:{dim}"))
        with owned_lock:
            owned.update(keys)
        return ingest_batch(db, payload, SECRET)

    try:
        # Keep a real published ranking in the same disposable DB before filling it.
        for i in range(10):
            if submit(_payload(BASE_PROVIDER, f"baseline-{i}", observed, "baseline-shared")) != 1:
                raise RuntimeError("baseline result was not accepted")
        published = refresh_rankings(db, now=observed, min_sources=10)
        if published != 1:
            dimensions = sorted(value.decode("utf-8") for value in db.smembers("z4r:adaptive:v2:dimensions:active"))
            dim = dimensions[0] if dimensions else ""
            day = time.strftime("%Y%m%d", time.gmtime(observed))
            print("capacity-test baseline diagnostics: published=%d dimensions=%d metadata=%r source_count=%d aggregate=%r" % (
                published, len(dimensions), db.hgetall("z4r:adaptive:v2:meta:" + dim),
                db.pfcount("z4r:adaptive:v2:sources:" + dim) if dim else 0,
                db.hgetall(f"z4r:adaptive:v2:agg:{day}:{dim}") if dim else {}))
            raise RuntimeError("baseline ranking was not published")
        baseline = get_rankings(db, BASE_PROVIDER, 1, now=observed)
        if baseline.get("status") != "fresh" or len(baseline.get("rankings", [])) != 1 or baseline["rankings"][0]["successes"] != 10:
            raise RuntimeError("baseline ranking did not materialize correctly")

        def capacity_payload(i: int) -> dict:
            label = f"dimension-{i}"
            modality = i % 3
            if modality == 1:
                return _payload(PROVIDER, label, observed, recipe="googlevideo-tcp-media-v1",
                                profile=2, protocol="tcp-media", treatment="gv_tcp_plain")
            if modality == 2:
                return _payload(PROVIDER, label, observed, recipe="googlevideo-quic-h3-media-v1",
                                profile=5, protocol="quic")
            return _payload(PROVIDER, label, observed)

        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            accepted = list(pool.map(lambda i: submit(capacity_payload(i)), range(MAX_DIMENSIONS - 1)))
        if any(count != 1 for count in accepted):
            raise RuntimeError("one or more capacity dimensions were not accepted")
        dimension_count = int(db.scard("z4r:adaptive:v2:dimensions:active"))
        if dimension_count != MAX_DIMENSIONS:
            raise RuntimeError(f"expected {MAX_DIMENSIONS} dimensions, found {dimension_count}")
        active_dimensions = {value.decode("utf-8") for value in db.smembers("z4r:adaptive:v2:dimensions:active")}
        provider_hash = hashlib.sha256(canonical(validate_provider(PROVIDER)).encode("utf-8")).hexdigest()[:24]
        provider_dimensions = [dimension.split("|") for dimension in active_dimensions
                               if dimension.startswith(provider_hash + "|")]
        observed_categories = {(int(parts[1]), parts[2], parts[4], parts[5]) for parts in provider_dimensions}
        required_categories = {
            (1, "tls", "tls-http1-v1", "standard"),
            (2, "tcp-media", "googlevideo-tcp-media-v1", "gv_tcp_plain"),
            (5, "quic", "googlevideo-quic-h3-media-v1", "standard"),
        }
        if not required_categories.issubset(observed_categories):
            raise RuntimeError("full dimension set did not include TLS, Googlevideo TCP media, and QUIC")

        overflow = _payload(PROVIDER, "overflow-dimension", observed)
        try:
            submit(overflow)
        except ValueError as exc:
            if "budget is full" not in str(exc):
                raise
        else:
            raise RuntimeError("an over-budget dimension was accepted")
        if int(db.scard("z4r:adaptive:v2:dimensions:active")) != MAX_DIMENSIONS:
            raise RuntimeError("overflow changed the bounded dimension set")
        refresh_started = time.perf_counter()
        refreshed = refresh_rankings(db, now=observed, min_sources=10)
        refresh_seconds = time.perf_counter() - refresh_started
        if refreshed != 1:
            raise RuntimeError(f"full mixed-dimension refresh published {refreshed} groups, expected baseline TLS only")
        baseline_after = get_rankings(db, BASE_PROVIDER, 1, now=observed)
        if baseline_after != baseline:
            raise RuntimeError("a published ranking changed when the dimension budget filled")

        print("dimensions=%d tls_tcp_media_quic=covered overflow=rejected refresh_seconds=%.3f baseline_ranking=preserved redis_used_before=%d redis_used_full=%d delta=%d" % (
            dimension_count, refresh_seconds,
            memory_before, int(db.info("memory")["used_memory"]),
            int(db.info("memory")["used_memory"]) - memory_before))
    finally:
        keys = sorted(owned)
        for start in range(0, len(keys), 500):
            db.delete(*keys[start:start + 500])
        leftovers = list(db.scan_iter(count=100))
        db.close()
        if leftovers:
            raise RuntimeError("capacity-test cleanup left keys in the initially empty DB 15")


if __name__ == "__main__":
    main()
