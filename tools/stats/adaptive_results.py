"""Bounded Redis aggregation for opt-in adaptive strategy measurements (v2)."""
from __future__ import annotations

from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import hmac
import json
import re
import secrets
import time

from recommendations import canonical, load_aliases, validate_provider

SCHEMA_VERSION = 2
PROTOCOLS = {"tls", "tcp-media", "quic"}
RECIPES = {
    "tls-http1-v1": ("curl-windows-v1", 1, 4, "tls", {"standard"}),
    "googlevideo-tcp-media-v1": ("curl-windows-media-v1", 2, 2, "tcp-media",
                                  {"standard", "gv_tcp_plain", "gv_tcp_ramp", "gv_tcp_ramp_syndata"}),
    "googlevideo-quic-h3-media-v1": ("curl-windows-quic-media-v1", 5, 5, "quic", {"standard"}),
}
MAX_BATCH_BYTES = 32768
MAX_BATCH_RESULTS = 50
MAX_FAILURE_CONFIRMATIONS = 5
MAX_DIMENSIONS = 2048
MAX_SOURCE_DAILY = 12
MAX_BROWSER_SOURCE_DAILY = 24
MAX_CLIENT_TOKENS = 10000
AGGREGATE_TTL = 8 * 86400
REQUEST_TTL = 6 * 3600
MIN_SOURCES = 10
RANKING_TTL = 1800
_HEX32 = re.compile(r"^[a-f0-9]{32}$")
_HEX64 = re.compile(r"^[a-f0-9]{64}$")
_SAFE_PROFILE = re.compile(r"^[1-4]$")
_BROWSER_PROTOCOLS = {1: "tls", 2: "googlevideo-tcp", 3: "tls", 4: "tls", 5: "quic"}
_BROWSER_STATES = {"PROVISIONAL_SUCCESS", "CONFIRMED_SUCCESS", "CONFIRMED_FAILURE", "UNKNOWN",
                   "NOT_TESTED", "TCP_FALLBACK", "PROTOCOL_UNKNOWN", "CANCELLED"}
_BROWSER_TREATMENTS = {"standard", "gv_tcp_plain", "gv_tcp_ramp", "gv_tcp_ramp_syndata"}


def _json_bytes(payload):
    try:
        raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise ValueError("invalid JSON payload") from exc
    if len(raw) > MAX_BATCH_BYTES:
        raise ValueError("batch too large")
    return raw


def _source_digest(source_id, secret):
    if not isinstance(source_id, str) or not _HEX64.fullmatch(source_id):
        raise ValueError("invalid source id")
    return hmac.new(secret.encode("utf-8"), source_id.encode("ascii"), hashlib.sha256).hexdigest()


def _client_token_digest(token, secret):
    if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_-]{40,64}", token):
        raise ValueError("invalid client token")
    return hmac.new(secret.encode("utf-8"), token.encode("ascii"), hashlib.sha256).hexdigest()


_TOKEN_ISSUE_SCRIPT = r"""
-- adaptive-token-issue
if redis.call('HEXISTS', KEYS[1], ARGV[1]) == 1 then return -1 end
if redis.call('HLEN', KEYS[1]) >= tonumber(ARGV[1 + 2]) then return 0 end
redis.call('HSET', KEYS[1], ARGV[1], ARGV[2])
return 1
"""


def issue_client_token(rdb, secret):
    """Create a revocable, per-install credential; only its keyed digest is stored."""
    if not isinstance(secret, str) or len(secret) < 32:
        raise ValueError("ingest secret unavailable")
    token = secrets.token_urlsafe(32)
    digest = _client_token_digest(token, secret)
    source_id = secrets.token_hex(32)
    source = hmac.new(secret.encode("utf-8"), source_id.encode("ascii"), hashlib.sha256).hexdigest()
    result = int(rdb.eval(_TOKEN_ISSUE_SCRIPT, 1, "z4r:adaptive:v2:client-tokens",
                          digest, source, str(MAX_CLIENT_TOKENS)))
    if result == 0:
        raise ValueError("adaptive client token limit reached")
    if result != 1:
        raise ValueError("adaptive client token collision")
    return token


def authenticate_client_token(rdb, token, secret):
    """Return the server-bound source pseudonym for a provisioned client token."""
    if not isinstance(secret, str) or len(secret) < 32:
        raise ValueError("ingest secret unavailable")
    digest = _client_token_digest(token, secret)
    source = rdb.hget("z4r:adaptive:v2:client-tokens", digest)
    if source is None:
        return None
    source = source.decode("ascii") if isinstance(source, bytes) else str(source)
    return source if _HEX64.fullmatch(source) else None


def revoke_client_token(rdb, token, secret):
    """Revoke one client credential without retaining or printing its plaintext."""
    if not isinstance(secret, str) or len(secret) < 32:
        raise ValueError("ingest secret unavailable")
    return int(rdb.hdel("z4r:adaptive:v2:client-tokens", _client_token_digest(token, secret)))


def validate_batch(payload, secret, aliases=None, now=None, source_digest=None):
    """Validate only exact, route-verified local probe outcomes; return normalized rows."""
    _json_bytes(payload)
    if not isinstance(payload, dict) or payload.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("unsupported schema")
    request_id = payload.get("request_id")
    if not isinstance(request_id, str) or not _HEX32.fullmatch(request_id):
        raise ValueError("invalid request id")
    if not isinstance(secret, str) or len(secret) < 32:
        raise ValueError("ingest secret unavailable")
    if source_digest is not None:
        if not _HEX64.fullmatch(source_digest) or "source_id" in payload:
            raise ValueError("invalid authenticated source")
        source = source_digest
    else:
        source = _source_digest(payload.get("source_id"), secret)
    provider = canonical(validate_provider(payload.get("provider")), aliases)
    observed = payload.get("observed_at")
    if isinstance(observed, bool) or not isinstance(observed, int):
        raise ValueError("invalid timestamp")
    now = int(time.time()) if now is None else int(now)
    if observed < now - 7 * 86400 or observed > now + 300:
        raise ValueError("timestamp outside retention window")
    recipe = payload.get("recipe_id")
    if not isinstance(recipe, str) or recipe not in RECIPES or payload.get("client_profile") != RECIPES[recipe][0]:
        raise ValueError("unsupported probe recipe")
    results = payload.get("results")
    if not isinstance(results, list) or not 1 <= len(results) <= MAX_BATCH_RESULTS:
        raise ValueError("invalid result count")
    phash = hashlib.sha256(provider.casefold().encode("utf-8")).hexdigest()[:24]
    # Rate limits use server time so a client cannot replay old timestamps to
    # obtain another daily contribution allowance.
    day = datetime.fromtimestamp(now, timezone.utc).strftime("%Y%m%d")
    rows = []
    seen = set()
    for row in results:
        if not isinstance(row, dict):
            raise ValueError("invalid result row")
        profile = row.get("profile_id")
        protocol = row.get("protocol")
        fingerprint = row.get("fingerprint")
        verdict = row.get("verdict")
        transport = row.get("transport")
        application = row.get("application")
        failure_confirmations = row.get("failure_confirmations", 0)
        treatment = row.get("treatment_variant", "standard")
        media_bytes = row.get("media_bytes", 0)
        media_speed_bps = row.get("media_speed_bps", 0)
        media_duration_ms = row.get("media_duration_ms", 0)
        client_profile, min_profile, max_profile, expected_protocol, treatments = RECIPES[recipe]
        if (isinstance(profile, bool) or not isinstance(profile, int)
                or profile < min_profile or profile > max_profile
                or not isinstance(protocol, str) or protocol != expected_protocol or not isinstance(fingerprint, str)
                or not isinstance(treatment, str) or treatment not in treatments
                or any(isinstance(value, bool) or not isinstance(value, int) or value < 0
                       for value in (media_bytes, media_speed_bps, media_duration_ms))
                or media_bytes > 16777216 or media_speed_bps > 1073741824 or media_duration_ms > 60000
                or not fingerprint.startswith("sha256:") or not _HEX64.fullmatch(fingerprint[7:])
                or verdict not in ("SUCCESS", "FAIL") or row.get("route_verified") is not True):
            raise ValueError("result lacks exact verified evidence")
        is_media = recipe != "tls-http1-v1"
        if (is_media and (media_bytes < 65536 or media_speed_bps <= 0 or media_duration_ms <= 0)
                or not is_media and any((media_bytes, media_speed_bps, media_duration_ms))):
            raise ValueError("media recipe lacks bounded transfer evidence")
        if ((verdict == "SUCCESS" and (transport != "OK" or application != "OK"))
                or (verdict == "FAIL" and transport != "FAIL" and application != "FAIL")):
            raise ValueError("verdict conflicts with probe evidence")
        if (isinstance(failure_confirmations, bool) or not isinstance(failure_confirmations, int)
                or (verdict == "FAIL" and not 2 <= failure_confirmations <= MAX_FAILURE_CONFIRMATIONS)
                or (verdict == "SUCCESS" and failure_confirmations != 0)):
            raise ValueError("failure requires repeated confirmation")
        dim = f"{phash}|{profile}|{protocol}|{fingerprint[7:]}|{recipe}|{treatment}"
        if dim in seen:
            raise ValueError("duplicate result dimension")
        seen.add(dim)
        rows.append({"dimension": dim, "provider": provider, "profile_id": profile,
                     "protocol": protocol, "fingerprint": fingerprint,
                     "recipe_id": recipe, "treatment_variant": treatment,
                     "media_bytes": media_bytes, "media_speed_bps": media_speed_bps,
                     "media_duration_ms": media_duration_ms,
                     "verdict": verdict, "day": day})
    return {"request_id": request_id, "request_hash": hashlib.sha256(_json_bytes(payload)).hexdigest(),
            "source": source, "provider_hash": phash, "day": day, "rows": rows}


def validate_browser_batch(payload, secret, aliases=None, now=None, source_digest=None):
    """Validate privacy-minimized browser-flow outcomes, kept outside probe rankings."""
    _json_bytes(payload)
    if (not isinstance(payload, dict) or payload.get("schema_version") != 1
            or payload.get("source") != "browser_flow" or payload.get("client_profile") != "chromium-v1"
            or "source_id" in payload):
        raise ValueError("unsupported browser evidence schema")
    allowed = {"schema_version", "source", "client_profile", "request_id", "provider", "observed_at", "results"}
    if set(payload) != allowed:
        raise ValueError("invalid browser evidence fields")
    request_id = payload.get("request_id")
    if not isinstance(request_id, str) or not _HEX32.fullmatch(request_id):
        raise ValueError("invalid request id")
    if not isinstance(secret, str) or len(secret) < 32:
        raise ValueError("ingest secret unavailable")
    if source_digest is None or not isinstance(source_digest, str) or not _HEX64.fullmatch(source_digest):
        raise ValueError("authenticated browser source required")
    provider = canonical(validate_provider(payload.get("provider")), aliases)
    observed = payload.get("observed_at")
    if isinstance(observed, bool) or not isinstance(observed, int):
        raise ValueError("invalid timestamp")
    now = int(time.time()) if now is None else int(now)
    if observed < now - 7 * 86400 or observed > now + 300:
        raise ValueError("timestamp outside retention window")
    results = payload.get("results")
    if not isinstance(results, list) or not 1 <= len(results) <= MAX_BATCH_RESULTS:
        raise ValueError("invalid result count")
    phash = hashlib.sha256(provider.casefold().encode("utf-8")).hexdigest()[:24]
    day = datetime.fromtimestamp(now, timezone.utc).strftime("%Y%m%d")
    rows, seen = [], set()
    row_fields = {"profile_id", "protocol", "fingerprint", "state", "treatment_variant", "protocol_proven", "confidence"}
    for row in results:
        if not isinstance(row, dict) or set(row) != row_fields:
            raise ValueError("invalid browser result fields")
        profile, protocol = row["profile_id"], row["protocol"]
        fingerprint, state = row["fingerprint"], row["state"]
        treatment, proven, confidence = row["treatment_variant"], row["protocol_proven"], row["confidence"]
        if (isinstance(profile, bool) or not isinstance(profile, int) or profile not in _BROWSER_PROTOCOLS
                or not isinstance(protocol, str) or protocol != _BROWSER_PROTOCOLS[profile] or not isinstance(fingerprint, str)
                or not re.fullmatch(r"sha256:[a-f0-9]{64}", fingerprint)
                or not isinstance(state, str) or state not in _BROWSER_STATES
                or not isinstance(treatment, str) or treatment not in _BROWSER_TREATMENTS
                or not isinstance(proven, bool) or confidence not in ("low", "medium", "high")):
            raise ValueError("invalid browser outcome")
        if (protocol == "quic" and treatment != "standard"
                or protocol != "googlevideo-tcp" and treatment != "standard"):
            raise ValueError("treatment does not match browser protocol")
        if state == "CONFIRMED_SUCCESS" and not proven:
            raise ValueError("browser success requires protocol proof")
        if protocol == "quic" and state == "CONFIRMED_SUCCESS" and confidence != "high":
            raise ValueError("QUIC success requires high confidence")
        dim = f"{phash}|{profile}|{protocol}|{fingerprint[7:]}|{treatment}|{state}|{int(proven)}|{confidence}"
        if dim in seen:
            raise ValueError("duplicate browser result dimension")
        seen.add(dim)
        rows.append({"dimension": dim, "state": state})
    source = hmac.new(secret.encode("utf-8"), source_digest.encode("ascii"), hashlib.sha256).hexdigest()
    return {"request_id": request_id, "request_hash": hashlib.sha256(_json_bytes(payload)).hexdigest(),
            "source": source, "provider_hash": phash, "day": day, "rows": rows}


_BROWSER_INGEST_SCRIPT = r"""
-- adaptive-browser-flow-ingest
if redis.call('GET', KEYS[1]) then
  if redis.call('GET', KEYS[1]) == ARGV[1] then return 0 else return -2 end
end
local count = tonumber(ARGV[2])
local maxdims = tonumber(ARGV[3])
local ttl = tonumber(ARGV[4])
local maxsource = tonumber(ARGV[5])
local newdims = {}
local accepted = {}
local dimcount = redis.call('SCARD', KEYS[3])
for i = 1, count do
  local dimension = ARGV[5 + i]
  if redis.call('SISMEMBER', KEYS[2], dimension) == 0 then
    accepted[i] = true
    if redis.call('SISMEMBER', KEYS[3], dimension) == 0 and not newdims[dimension] then
      newdims[dimension] = true
      dimcount = dimcount + 1
    end
  end
end
if redis.call('SCARD', KEYS[2]) + (function() local n=0; for i=1,count do if accepted[i] then n=n+1 end end; return n end)() > maxsource then return -3 end
if dimcount > maxdims then return -1 end
local accepted_count = 0
for i = 1, count do
  if accepted[i] then
    local dimension = ARGV[5 + i]
    local state = ARGV[5 + count + i]
    redis.call('SADD', KEYS[2], dimension)
    redis.call('SADD', KEYS[3], dimension)
    redis.call('HINCRBY', KEYS[3 + i], state, 1)
    redis.call('PFADD', KEYS[3 + count + i], ARGV[5 + count * 2 + i])
    redis.call('EXPIRE', KEYS[3 + i], ttl)
    redis.call('EXPIRE', KEYS[3 + count + i], ttl)
    accepted_count = accepted_count + 1
  end
end
redis.call('EXPIRE', KEYS[2], 172800)
redis.call('EXPIRE', KEYS[3], ttl)
redis.call('SET', KEYS[1], ARGV[1], 'EX', tonumber(ARGV[6 + count * 3]))
return accepted_count
"""


def ingest_browser_batch(rdb, payload, secret, aliases=None, now=None, max_dimensions=MAX_DIMENSIONS,
                         source_digest=None):
    """Store browser-flow metrics separately; never feed them into probe rankings."""
    batch = validate_browser_batch(payload, secret, aliases, now, source_digest)
    max_dimensions = max(1, min(int(max_dimensions), MAX_DIMENSIONS))
    day, count = batch["day"], len(batch["rows"])
    req_key = f"z4r:adaptive:v2:browser:req:{batch['source']}:{batch['request_id']}"
    source_key = f"z4r:adaptive:v2:browser:source:{batch['source']}:{day}"
    dimset_key = f"z4r:adaptive:v2:browser:dimensions:{day}"
    keys = [req_key, source_key, dimset_key]
    for row in batch["rows"]:
        keys.append(f"z4r:adaptive:v2:browser:agg:{day}:{row['dimension']}")
    for row in batch["rows"]:
        keys.append(f"z4r:adaptive:v2:browser:sources:{day}:{row['dimension']}")
    args = [batch["request_hash"], str(count), str(max_dimensions), str(AGGREGATE_TTL),
            str(MAX_BROWSER_SOURCE_DAILY)]
    args.extend(row["dimension"] for row in batch["rows"])
    args.extend(row["state"] for row in batch["rows"])
    args.extend(batch["source"] for row in batch["rows"])
    args.append(str(REQUEST_TTL))
    result = int(rdb.eval(_BROWSER_INGEST_SCRIPT, len(keys), *keys, *args))
    if result == -1:
        raise ValueError("browser evidence dimension budget is full")
    if result == -2:
        raise ValueError("request id was reused with a different payload")
    if result == -3:
        raise ValueError("browser source daily contribution budget is full")
    return result


_INGEST_SCRIPT = r"""
if redis.call('GET', KEYS[1]) then
  if redis.call('GET', KEYS[1]) == ARGV[1] then return 0 else return -2 end
end
local count = tonumber(ARGV[2])
local maxdims = tonumber(ARGV[3])
local ttl = tonumber(ARGV[4])
local maxsource = tonumber(ARGV[5])
local sourcekey = KEYS[2]
local dimset = KEYS[3]
local newdims = {}
local accepted = {}
local accepted_count = 0
local seen_count = redis.call('SCARD', dimset)
for i = 1, count do
  local dimension = ARGV[5 + i]
  local verdict = ARGV[5 + count + i]
  if redis.call('SISMEMBER', sourcekey, dimension) == 0 then
    accepted[i] = true
    if redis.call('SISMEMBER', dimset, dimension) == 0 and not newdims[dimension] then
      newdims[dimension] = true
      seen_count = seen_count + 1
    end
  end
end
if seen_count > maxdims then return -1 end
local accepted_source_count = 0
for i = 1, count do
  if accepted[i] then accepted_source_count = accepted_source_count + 1 end
end
if redis.call('SCARD', sourcekey) + accepted_source_count > maxsource then return -3 end
for i = 1, count do
  if accepted[i] then
    local dimension = ARGV[5 + i]
    local verdict = ARGV[5 + count + i]
    local aggkey = KEYS[3 + i]
    local hllkey = KEYS[3 + count + i]
    local metakey = KEYS[3 + count * 2 + i]
    redis.call('SADD', sourcekey, dimension)
    redis.call('SADD', dimset, dimension)
    redis.call('HINCRBY', aggkey, verdict, 1)
    redis.call('HINCRBY', aggkey, 'MEDIA_BYTES', ARGV[5 + count * 9 + i])
    redis.call('HINCRBY', aggkey, 'MEDIA_SPEED_BPS', ARGV[5 + count * 10 + i])
    redis.call('HINCRBY', aggkey, 'MEDIA_DURATION_MS', ARGV[5 + count * 11 + i])
    redis.call('PFADD', hllkey, ARGV[5 + count * 2 + i])
    redis.call('HSET', metakey, 'provider', ARGV[5 + count * 3 + i],
      'profile_id', ARGV[5 + count * 4 + i],
      'protocol', ARGV[5 + count * 5 + i],
      'fingerprint', ARGV[5 + count * 6 + i],
      'recipe_id', ARGV[5 + count * 7 + i],
      'treatment_variant', ARGV[5 + count * 8 + i])
    redis.call('EXPIRE', aggkey, ttl)
    redis.call('EXPIRE', hllkey, ttl)
    redis.call('EXPIRE', metakey, ttl)
    accepted_count = accepted_count + 1
  end
end
redis.call('EXPIRE', sourcekey, 172800)
redis.call('EXPIRE', dimset, ttl)
redis.call('SET', KEYS[1], ARGV[1], 'EX', tonumber(ARGV[6 + count * 12]))
return accepted_count
"""


def ingest_batch(rdb, payload, secret, aliases=None, now=None, max_dimensions=MAX_DIMENSIONS, source_digest=None):
    """Atomically dedupe requests/source-day and update bounded counters/HLLs.

    Returns accepted-dimension count. A duplicate request returns 0; validation,
    provider-cardinality overflow, and request-id conflicts raise ValueError.
    """
    batch = validate_batch(payload, secret, aliases, now, source_digest)
    now = int(time.time()) if now is None else int(now)
    max_dimensions = max(1, min(int(max_dimensions), MAX_DIMENSIONS))
    day = batch["day"]
    req_key = "z4r:adaptive:v2:req:" + batch["request_id"]
    source_key = f"z4r:adaptive:v2:source:{batch['source']}:{day}"
    dimset_key = "z4r:adaptive:v2:dimensions:active"
    keys = [req_key, source_key, dimset_key]
    for row in batch["rows"]:
        keys.append(f"z4r:adaptive:v2:agg:{day}:{row['dimension']}")
    for row in batch["rows"]:
        keys.append(f"z4r:adaptive:v2:sources:{row['dimension']}")
    for row in batch["rows"]:
        keys.append(f"z4r:adaptive:v2:meta:{row['dimension']}")
    n = len(batch["rows"])
    args = [batch["request_hash"], str(n), str(max_dimensions), str(AGGREGATE_TTL), str(MAX_SOURCE_DAILY)]
    args.extend(row["dimension"] for row in batch["rows"])
    args.extend(row["verdict"] for row in batch["rows"])
    args.extend(batch["provider_hash"] + ":" + batch["source"] for row in batch["rows"])
    args.extend(row["provider"] for row in batch["rows"])
    args.extend(str(row["profile_id"]) for row in batch["rows"])
    args.extend(row["protocol"] for row in batch["rows"])
    args.extend(row["fingerprint"] for row in batch["rows"])
    args.extend(row["recipe_id"] for row in batch["rows"])
    args.extend(row["treatment_variant"] for row in batch["rows"])
    args.extend(str(row["media_bytes"]) for row in batch["rows"])
    args.extend(str(row["media_speed_bps"]) for row in batch["rows"])
    args.extend(str(row["media_duration_ms"]) for row in batch["rows"])
    args.append(str(REQUEST_TTL))
    result = int(rdb.eval(_INGEST_SCRIPT, len(keys), *keys, *args))
    if result == -1:
        raise ValueError("adaptive dimension budget is full")
    if result == -2:
        raise ValueError("request id was reused with a different payload")
    if result == -3:
        raise ValueError("source daily contribution budget is full")
    return result


def _decode(value):
    return value.decode("utf-8") if isinstance(value, bytes) else str(value)


def _refresh_rankings_locked(rdb, now=None, min_sources=MIN_SOURCES, limit=10):
    """Cron-only aggregation over capped dimensions; online GETs never scan Redis."""
    now = int(time.time()) if now is None else int(now)
    min_sources = max(2, min(int(min_sources), 1000))
    limit = max(1, min(int(limit), 20))
    dimensions = rdb.smembers("z4r:adaptive:v2:dimensions:active")
    pipe = rdb.pipeline(transaction=False)
    decoded = [_decode(x) for x in dimensions]
    for dim in decoded:
        pipe.hgetall("z4r:adaptive:v2:meta:" + dim)
    metadata = pipe.execute()
    metrics = rdb.pipeline(transaction=False)
    days = [datetime.fromtimestamp(now - delta * 86400, timezone.utc).strftime("%Y%m%d")
            for delta in range(8)]
    for dim in decoded:
        for day in days:
            metrics.hgetall(f"z4r:adaptive:v2:agg:{day}:{dim}")
        metrics.pfcount("z4r:adaptive:v2:sources:" + dim)
    metric_rows = metrics.execute()
    grouped = defaultdict(list)
    stale_dimensions = []
    stride = len(days) + 1
    for index, (dim, meta) in enumerate(zip(decoded, metadata)):
        if not meta:
            stale_dimensions.append(dim)
            continue
        meta = {_decode(k): _decode(v) for k, v in meta.items()}
        parts = dim.split("|", 5)
        phash, profile, protocol, fingerprint = parts[:4]
        recipe = parts[4] if len(parts) > 4 else "tls-http1-v1"
        treatment = parts[5] if len(parts) > 5 else "standard"
        group_key = (phash, profile, protocol, recipe, treatment)
        successes = failures = sources = 0
        weighted_successes = weighted_failures = 0.0
        media_bytes = media_speed_bps = media_duration_ms = 0
        start = index * stride
        for day_delta, agg in enumerate(metric_rows[start:start + len(days)]):
            if agg:
                values = {_decode(k): int(v) for k, v in agg.items()}
                day_successes = values.get("SUCCESS", 0)
                day_failures = values.get("FAIL", 0)
                media_bytes += values.get("MEDIA_BYTES", 0)
                media_speed_bps += values.get("MEDIA_SPEED_BPS", 0)
                media_duration_ms += values.get("MEDIA_DURATION_MS", 0)
                successes += day_successes
                failures += day_failures
                freshness_weight = 0.5 ** day_delta
                weighted_successes += day_successes * freshness_weight
                weighted_failures += day_failures * freshness_weight
        sources = int(metric_rows[start + len(days)] or 0)
        total = successes + failures
        if sources < min_sources or total < min_sources:
            continue
        if recipe != "tls-http1-v1" and successes:
            media_bytes = round(media_bytes / successes)
            media_speed_bps = round(media_speed_bps / successes)
            media_duration_ms = round(media_duration_ms / successes)
        # Beta(2,2) prior; enough evidence matters as well as raw success share.
        score = (weighted_successes + 2) / (weighted_successes + weighted_failures + 4)
        grouped[group_key].append({"fingerprint": "sha256:" + fingerprint, "successes": successes,
                                   "failures": failures, "samples": sources,
                                   "weighted_successes": round(weighted_successes, 3),
                                   "weighted_failures": round(weighted_failures, 3),
                                   "score": round(score, 6), "recipe_id": recipe,
                                   "treatment_variant": treatment,
                                   "media_bytes": media_bytes, "media_speed_bps": media_speed_bps,
                                   "media_duration_ms": media_duration_ms})
    if stale_dimensions:
        prune = rdb.pipeline(transaction=False)
        for dim in stale_dimensions:
            prune.srem("z4r:adaptive:v2:dimensions:active", dim)
        prune.execute()
    published = 0
    providers = {}
    for dim, meta in zip(decoded, metadata):
        if meta:
            meta = {_decode(k): _decode(v) for k, v in meta.items()}
            phash = dim.split("|", 1)[0]
            providers[phash] = meta.get("provider", "")
    for (phash, profile, protocol, recipe, treatment), rows in grouped.items():
        rows.sort(key=lambda x: (-x["score"],
                                 -(x["media_speed_bps"] if recipe != "tls-http1-v1" else 0),
                                 -x["samples"], x["fingerprint"]))
        payload = {"schema_version": 2, "generated_at": now, "provider": providers.get(phash, ""),
                   "profile_id": int(profile), "protocol": protocol, "recipe_id": recipe,
                   "treatment_variant": treatment, "rankings": rows[:limit]}
        suffix = "" if recipe == "tls-http1-v1" and treatment == "standard" else f":{recipe}:{treatment}"
        key = f"z4r:adaptive:v2:ranking:{phash}:{profile}:{protocol}{suffix}"
        rdb.setex(key, RANKING_TTL, json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
        published += 1
    return published


def refresh_rankings(rdb, now=None, min_sources=MIN_SOURCES, limit=10):
    """Serialize cron refreshes; requests never perform this work."""
    lock_key = "z4r:adaptive:v2:rankings:refresh-lock"
    lock_token = secrets.token_hex(16)
    if not rdb.set(lock_key, lock_token, nx=True, ex=300):
        return 0
    try:
        return _refresh_rankings_locked(rdb, now, min_sources, limit)
    finally:
        rdb.eval("if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) else return 0 end",
                 1, lock_key, lock_token)


def get_rankings(rdb, provider, profile, protocol="tls", aliases=None, now=None,
                 recipe="tls-http1-v1", treatment="standard"):
    """Read only a precomputed ranking key; never aggregate or scan in request path."""
    provider = canonical(validate_provider(provider), aliases)
    try:
        profile_number = int(profile)
    except (TypeError, ValueError):
        raise ValueError("invalid ranking dimension")
    if (isinstance(profile, bool) or not isinstance(protocol, str) or protocol not in PROTOCOLS
            or recipe not in RECIPES or treatment not in RECIPES[recipe][4]
            or profile_number < RECIPES[recipe][1] or profile_number > RECIPES[recipe][2]
            or protocol != RECIPES[recipe][3]):
        raise ValueError("invalid ranking dimension")
    phash = hashlib.sha256(provider.casefold().encode("utf-8")).hexdigest()[:24]
    suffix = "" if recipe == "tls-http1-v1" and treatment == "standard" else f":{recipe}:{treatment}"
    raw = rdb.get(f"z4r:adaptive:v2:ranking:{phash}:{profile}:{protocol}{suffix}")
    if raw is None:
        return {"schema_version": 2, "status": "not_ready", "provider": provider,
                "profile_id": profile_number, "protocol": protocol, "recipe_id": recipe,
                "treatment_variant": treatment, "rankings": []}
    data = json.loads(_decode(raw))
    if (data.get("provider") != provider or data.get("profile_id") != profile_number
            or data.get("protocol") != protocol or data.get("recipe_id", "tls-http1-v1") != recipe
            or data.get("treatment_variant", "standard") != treatment):
        return {"schema_version": 2, "status": "not_ready", "rankings": []}
    now = int(time.time()) if now is None else int(now)
    age = now - int(data.get("generated_at", 0))
    data["status"] = "fresh" if 0 <= age <= 900 else "stale"
    return data


def render_rankings_tsv(data):
    """Strict bounded text format for BusyBox clients without a JSON library."""
    if data.get("schema_version") != SCHEMA_VERSION or data.get("status") not in ("fresh", "stale", "not_ready"):
        raise ValueError("invalid ranking document")
    lines = [f"schema_version={SCHEMA_VERSION}", f"status={data['status']}"]
    if data["status"] == "not_ready":
        return "\n".join(lines) + "\n"
    generated = data.get("generated_at")
    profile = data.get("profile_id")
    protocol = data.get("protocol")
    rows = data.get("rankings")
    if (isinstance(generated, bool) or not isinstance(generated, int) or generated < 0
            or not isinstance(profile, int) or not isinstance(protocol, str) or protocol not in PROTOCOLS
            or data.get("recipe_id", "tls-http1-v1") not in RECIPES
            or not isinstance(rows, list) or len(rows) > 20):
        raise ValueError("invalid ranking document")
    lines.extend((f"generated_at={generated}", f"profile_id={profile}", f"protocol={protocol}"))
    if data.get("recipe_id", "tls-http1-v1") != "tls-http1-v1":
        lines.extend((f"recipe_id={data['recipe_id']}", f"treatment_variant={data.get('treatment_variant', 'standard')}"))
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("invalid ranking row")
        fingerprint = row.get("fingerprint")
        score = row.get("score")
        samples = row.get("samples")
        successes = row.get("successes")
        failures = row.get("failures")
        if (not isinstance(fingerprint, str) or not fingerprint.startswith("sha256:")
                or not _HEX64.fullmatch(fingerprint[7:])
                or isinstance(score, bool) or not isinstance(score, (int, float)) or not 0 <= score <= 1
                or any(isinstance(x, bool) or not isinstance(x, int) or x < 0 for x in (samples, successes, failures))):
            raise ValueError("invalid ranking row")
        lines.append("strategy\t%s\t%.6f\t%d\t%d\t%d" % (fingerprint, score, samples, successes, failures))
    body = "\n".join(lines) + "\n"
    if len(body.encode("ascii")) > 8192:
        raise ValueError("ranking response too large")
    return body
