"""Bounded adaptive-results V2 validation, idempotency, and ranking tests."""
from pathlib import Path
import importlib.util
import json
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools/stats"))
import adaptive_results as adaptive


class Pipeline:
    def __init__(self, db):
        self.db = db
        self.ops = []

    def hgetall(self, key):
        self.ops.append(("hgetall", key))
        return self

    def pfcount(self, key):
        self.ops.append(("pfcount", key))
        return self

    def srem(self, key, member):
        self.ops.append(("srem", key, member))
        return self

    def execute(self):
        output = []
        for op in self.ops:
            if op[0] == "hgetall":
                output.append(self.db.hashes.get(op[1], {}).copy())
            elif op[0] == "pfcount":
                output.append(len(self.db.hlls.get(op[1], set())))
            elif op[0] == "srem":
                output.append(int(op[2] in self.db.sets.get(op[1], set())))
                self.db.sets.get(op[1], set()).discard(op[2])
        return output


class FakeRedis:
    def __init__(self):
        self.strings = {}
        self.sets = {}
        self.hashes = {}
        self.hlls = {}
        self.setex_calls = []
        self.scan_calls = 0

    def set(self, key, value, nx=False, ex=None):
        if nx and key in self.strings:
            return False
        self.strings[key] = value
        return True

    def get(self, key):
        return self.strings.get(key)

    def eval(self, script, key_count, *args):
        keys = args[:key_count]
        argv = args[key_count:]
        if "adaptive-token-issue" in script:
            registry = self.hashes.setdefault(keys[0], {})
            if argv[0] in registry:
                return -1
            if len(registry) >= int(argv[2]):
                return 0
            registry[argv[0]] = argv[1]
            return 1
        if "local maxdims" not in script:
            if self.strings.get(keys[0]) == argv[0]:
                del self.strings[keys[0]]
                return 1
            return 0
        request_key, source_key, dimension_set = keys[:3]
        request_hash, count, maxdims, ttl, max_source = argv[:5]
        count, maxdims = int(count), int(maxdims)
        if request_key in self.strings:
            return 0 if self.strings[request_key] == request_hash else -2
        dimensions = argv[5:5 + count]
        verdicts = argv[5 + count:5 + 2 * count]
        sources = argv[5 + 2 * count:5 + 3 * count]
        providers = argv[5 + 3 * count:5 + 4 * count]
        profiles = argv[5 + 4 * count:5 + 5 * count]
        protocols = argv[5 + 5 * count:5 + 6 * count]
        fingerprints = argv[5 + 6 * count:5 + 7 * count]
        request_ttl = argv[5 + 7 * count]
        agg_keys = keys[3:3 + count]
        hll_keys = keys[3 + count:3 + 2 * count]
        meta_keys = keys[3 + 2 * count:3 + 3 * count]
        accepted = [i for i, dim in enumerate(dimensions) if dim not in self.sets.get(source_key, set())]
        if len(self.sets.get(source_key, set())) + len(accepted) > int(max_source):
            return -3
        newdims = set(dimensions[i] for i in accepted) - self.sets.get(dimension_set, set())
        if len(self.sets.get(dimension_set, set())) + len(newdims) > maxdims:
            return -1
        self.sets.setdefault(source_key, set()).update(dimensions[i] for i in accepted)
        self.sets.setdefault(dimension_set, set()).update(dimensions[i] for i in accepted)
        for i in accepted:
            self.hashes.setdefault(agg_keys[i], {})[verdicts[i]] = self.hashes.setdefault(agg_keys[i], {}).get(verdicts[i], 0) + 1
            self.hlls.setdefault(hll_keys[i], set()).add(sources[i])
            self.hashes[meta_keys[i]] = {"provider": providers[i], "profile_id": profiles[i],
                                         "protocol": protocols[i], "fingerprint": fingerprints[i]}
        self.strings[request_key] = request_hash
        assert int(request_ttl) > 0 and int(ttl) > 0
        return len(accepted)

    def smembers(self, key):
        self.scan_calls += 1
        return self.sets.get(key, set()).copy()

    def pipeline(self, transaction=False):
        return Pipeline(self)

    def hgetall(self, key):
        return self.hashes.get(key, {}).copy()

    def hget(self, key, field):
        return self.hashes.get(key, {}).get(field)

    def hdel(self, key, field):
        return int(self.hashes.get(key, {}).pop(field, None) is not None)

    def setex(self, key, ttl, value):
        self.setex_calls.append(key)
        self.strings[key] = value


NOW = 1_800_000_000
SECRET = "s" * 32
FP1 = "sha256:" + "a" * 64
FP2 = "sha256:" + "b" * 64


def batch(source, request, verdicts=("SUCCESS",), fingerprints=(FP1,), observed=NOW):
    rows = []
    for verdict, fingerprint in zip(verdicts, fingerprints):
        rows.append({"profile_id": 1, "protocol": "tls", "fingerprint": fingerprint,
                     "verdict": verdict, "route_verified": True,
                     "failure_confirmations": 2 if verdict == "FAIL" else 0,
                     "transport": "OK" if verdict == "SUCCESS" else "FAIL",
                     "application": "OK" if verdict == "SUCCESS" else "UNKNOWN"})
    return {"schema_version": 2, "request_id": f"{request:032x}", "source_id": f"{source:064x}",
            "provider": "Example ISP", "observed_at": observed, "recipe_id": "tls-http1-v1",
            "client_profile": "curl-windows-v1", "results": rows}


valid = batch(1, 1)
assert len(adaptive.validate_batch(valid, SECRET, now=NOW)["rows"]) == 1
tokens = FakeRedis()
token_a = adaptive.issue_client_token(tokens, SECRET)
token_b = adaptive.issue_client_token(tokens, SECRET)
source_a = adaptive.authenticate_client_token(tokens, token_a, SECRET)
source_b = adaptive.authenticate_client_token(tokens, token_b, SECRET)
assert source_a and source_b and source_a != source_b
assert source_a == adaptive.authenticate_client_token(tokens, token_a, SECRET)
assert token_a not in repr(tokens.hashes)
client_cap = adaptive.MAX_CLIENT_TOKENS
adaptive.MAX_CLIENT_TOKENS = 1
capped_tokens = FakeRedis()
adaptive.issue_client_token(capped_tokens, SECRET)
try:
    adaptive.issue_client_token(capped_tokens, SECRET)
except ValueError as exc:
    assert "limit" in str(exc)
else:
    raise AssertionError("adaptive client token registry exceeded its cap")
adaptive.MAX_CLIENT_TOKENS = client_cap
try:
    adaptive.authenticate_client_token(tokens, SECRET, SECRET)
except ValueError:
    pass
else:
    raise AssertionError("server master secret was accepted as a client credential")
assert adaptive.revoke_client_token(tokens, token_a, SECRET) == 1
assert adaptive.authenticate_client_token(tokens, token_a, SECRET) is None
anonymous_batch = batch(1, 500)
anonymous_batch.pop("source_id")
assert len(adaptive.validate_batch(anonymous_batch, SECRET, now=NOW, source_digest=source_b)["rows"]) == 1
for mutate in (
    lambda x: x.update(schema_version=1),
    lambda x: x.update(request_id="short"),
    lambda x: x.update(source_id="bad"),
    lambda x: x.update(observed_at=NOW + 301),
    lambda x: x["results"][0].update(route_verified=False),
    lambda x: x["results"][0].update(verdict="SUCCESS", transport="FAIL"),
    lambda x: x["results"][0].update(verdict="FAIL", failure_confirmations=1),
    lambda x: x["results"][0].update(protocol="quic"),
):
    import copy
    bad = copy.deepcopy(valid)
    mutate(bad)
    try:
        adaptive.validate_batch(bad, SECRET, now=NOW)
    except ValueError:
        pass
    else:
        raise AssertionError(f"invalid adaptive report accepted: {bad!r}")

db = FakeRedis()
assert adaptive.ingest_batch(db, valid, SECRET, now=NOW, max_dimensions=2) == 1
assert adaptive.ingest_batch(db, valid, SECRET, now=NOW, max_dimensions=2) == 0
conflict = batch(1, 1, verdicts=("FAIL",))
try:
    adaptive.ingest_batch(db, conflict, SECRET, now=NOW, max_dimensions=2)
except ValueError as exc:
    assert "request id" in str(exc)
else:
    raise AssertionError("request id payload conflict was accepted")

for source in range(2, 11):
    verdict = "SUCCESS" if source < 9 else "FAIL"
    assert adaptive.ingest_batch(db, batch(source, source, (verdict,), (FP1,)), SECRET, now=NOW, max_dimensions=2) == 1
    assert adaptive.ingest_batch(db, batch(source + 100, source + 100, ("SUCCESS",), (FP2,)), SECRET, now=NOW, max_dimensions=2) == 1
assert adaptive.ingest_batch(db, batch(1, 202, ("SUCCESS",), (FP1,)), SECRET, now=NOW, max_dimensions=2) == 0
try:
    adaptive.ingest_batch(db, batch(50, 50, ("SUCCESS",), ("sha256:" + "c" * 64,)), SECRET, now=NOW, max_dimensions=2)
except ValueError as exc:
    assert "budget" in str(exc)
else:
    raise AssertionError("dimension budget was not enforced")

source_rows = tuple("sha256:" + f"{i:064x}" for i in range(adaptive.MAX_SOURCE_DAILY + 1))
over_budget = batch(777, 777, ("SUCCESS",) * len(source_rows), source_rows)
try:
    adaptive.ingest_batch(db, over_budget, SECRET, now=NOW, max_dimensions=100)
except ValueError as exc:
    assert "source daily" in str(exc)
else:
    raise AssertionError("per-source daily contribution limit was ignored")

published = adaptive.refresh_rankings(db, now=NOW, min_sources=10)
assert published == 1, published
ranking = adaptive.get_rankings(db, "Example ISP", 1, now=NOW)
assert ranking["status"] == "fresh" and ranking["rankings"][0]["fingerprint"] == FP1
assert ranking["rankings"][0]["samples"] == 10
tsv = adaptive.render_rankings_tsv(ranking)
assert tsv.startswith("schema_version=2\nstatus=fresh\n") and "strategy\t" + FP1 in tsv
assert "example isp" not in tsv and len(tsv.encode("ascii")) <= 8192
assert db.scan_calls == 1, "rankings GET unexpectedly scanned/aggregated Redis"
assert len(db.setex_calls) == 1
print("adaptive stats V2 smoke: ok")
