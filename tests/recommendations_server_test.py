"""Stdlib checks: python tests/recommendations_server_test.py."""
import importlib.util
import copy
import json
import os
import sys
import types
import threading
import urllib.request
import urllib.error
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("recommendations", ROOT / "tools/stats/recommendations.py")
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def run(uuid, timestamp=1, mode="classic", verdicts=("ok", "warn", "fail", "ok"), domains=("a.test", "b.test")):
    meta = "provider\tMTS - Moscow\n" + "".join(f"mode_{p}\t{mode}\n" for p in range(1, 5))
    result = {"uuid": uuid, "received_at": str(timestamp), "raw:meta.tsv": meta,
              "raw:status": f"state=applying\nstarted={timestamp}\n"}
    workers = []
    for worker, p in (("yt", 1), ("gv", 2), ("rkn", 3), ("ds", 4)):
        workers.append(f"{worker}\t{worker}\t{'rkn' if p == 3 else 'profile'}\t{p}\t{','.join(domains) if p == 3 else 'https://target.test/'}\t{len(verdicts)}")
        result[f"raw:best.{worker}"] = "interrupted=0\n" + (
            f"winner_total={len(domains)}\n" if p == 3 else "".join(
                f"n_{v}={verdicts.count(v)}\n" for v in ("ok", "warn", "fail")))
        result["raw:coverage.tsv" if p == 3 else f"raw:progress.{worker}.tsv"] = "".join(
            f"1\t{d}\t{s}\t{v}\t0\t0\n" for d in (domains if p == 3 else (str(p),))
            for s, v in enumerate(verdicts, 1))
    result["raw:workers.tsv"] = "\n".join(workers)
    return result


def rows(runs, provider="MTS", aliases=None):
    return [line.split("\t") for line in MODULE.render_tsv(
        MODULE.aggregate(runs, generated_at=123, aliases=aliases), provider, aliases).splitlines()]


class FakeRedis:
    def __init__(self, runs):
        self.runs = runs
        self.values = {}
        self.reads = 0
        self.locked = False
        self.ttl = {}

    def get(self, key):
        return self.values.get(key)

    def set(self, key, value, nx=False, ex=None):
        if nx and (key in self.values or self.locked):
            return False
        self.values[key] = value
        self.ttl[key] = ex
        return True

    def lrange(self, key, start, end):
        self.reads += 1
        assert key == "z4r:supersweep:runs" and (start, end) == (0, 499)
        return list(range(len(self.runs)))[:500]

    def pipeline(self, transaction=False):
        parent = self
        class Pipeline:
            def __init__(self):
                self.ids = []
            def hgetall(self, key):
                self.ids.append(int(key.rsplit(":", 1)[1]))
                return self
            def execute(self):
                return [parent.runs[i] for i in self.ids]
        return Pipeline()

    def eval(self, script, count, *args):
        keys, argv = args[:count], args[count:]
        if self.values.get(keys[0]) != argv[0]:
            return 0
        if count == 2:
            self.set(keys[1], argv[1], ex=int(argv[2]))
        self.values.pop(keys[0], None)
        return 1


class RecommendationsTest(unittest.TestCase):
    def test_empty_retention_has_four_profiles_without_hints(self):
        text = MODULE.render_tsv(MODULE.aggregate([], generated_at=123), "MTS - Moscow")
        self.assertEqual(text, "meta\t1\tMTS - Moscow\t0\t123\n" + "".join(
            f"profile\t{p}\t0\t0\t-\t-\n" for p in range(1, 5)))

    def test_complete_matrix_rank_and_unique_threshold(self):
        runs = [run(f"uuid{i}") for i in range(10)]
        output = rows(runs)
        self.assertEqual(output[0], ["meta", "1", "MTS", "10", "123"])
        self.assertEqual(output[1], ["profile", "1", "10", "0", "50", "-"])
        self.assertEqual([r for r in output if r[:2] == ["strategy", "1"]], [
            ["strategy", "1", "1", "100", "10", "classic"],
            ["strategy", "1", "4", "100", "10", "classic"]])
        self.assertEqual(len(rows(runs[:9])), 5)
        self.assertEqual(len(rows([run("same") for _ in range(20)])), 5)

    def test_rejects_incomplete_cancelled_and_summary_only(self):
        originals = [run(str(i)) for i in range(10)]
        changes = (
            ("raw:status", "state=cancelled\n"),
            ("raw:progress.yt.tsv", "1\t1\t1\tok\n"),
            ("raw:coverage.tsv", originals[0]["raw:coverage.tsv"].splitlines()[0] + "\n"),
            ("raw:best.ds", "interrupted=1\nn_ok=2\nn_warn=1\nn_fail=1\n"),
            ("raw:best.yt", "interrupted=0\nn_ok=99\nn_warn=1\nn_fail=1\n"),
        )
        for key, value in changes:
            with self.subTest(key=key):
                bad = copy.deepcopy(originals)
                bad[0][key] = value
                self.assertEqual(rows(bad)[0][3], "9")
        self.assertEqual(rows([{"uuid": "x", "summary": json.dumps({"state": "done"})}])[0][3], "0")

    def test_latest_uuid_prevents_upload_bias_but_preserves_mode_evidence(self):
        classic = [run(str(i), 1, verdicts=("ok", "fail", "fail", "fail")) for i in range(10)]
        clone = [run(str(i), 2, mode="clone") for i in range(3)]
        output = rows(classic + clone + [clone[0]] * 20)
        self.assertEqual(output[1], ["profile", "1", "10", "1", "25", "50"])
        self.assertEqual([r for r in output if r[:3] == ["strategy", "1", "1"]][0][-1], "mixed")
        self.assertEqual(rows(classic + clone[:2])[1][3], "0")
        newer = run("0", 3, verdicts=("fail",) * 4)
        self.assertEqual([r for r in rows(classic + clone + [newer]) if r[:3] == ["strategy", "1", "1"]][0][3], "90")

    def test_exact_alias_and_provider_validation(self):
        aliases = MODULE.load_aliases(ROOT / "data/providers/asn.txt")
        self.assertEqual(rows([run(str(i)) for i in range(10)], "mgts - Town", aliases)[0][3], "10")
        self.assertEqual(rows([run(str(i)) for i in range(10)], "MTS competitor", aliases)[0][3], "0")
        for value in ("", "x" * 121, "MTS\tattack", "MTS\nattack", "MTS\x7f", "MTS\u0085"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                MODULE.render_tsv(MODULE.aggregate([]), value)

    def test_bad_modes_and_duplicate_matrix_rows_are_not_evidence(self):
        originals = [run(str(i)) for i in range(10)]
        bad = copy.deepcopy(originals)
        bad[0]["raw:meta.tsv"] = bad[0]["raw:meta.tsv"].replace("mode_1\tclassic", "mode_1\tbogus")
        self.assertEqual(rows(bad)[0][3], "9")
        bad = copy.deepcopy(originals)
        bad[0]["raw:coverage.tsv"] += bad[0]["raw:coverage.tsv"].splitlines()[0] + "\n"
        self.assertEqual(rows(bad)[0][3], "9")
        done = copy.deepcopy(originals)
        for item in done:
            item["raw:status"] = "state=done\nstarted=1\n"
            item["raw:meta.tsv"] = "provider\tMTS\n"
        self.assertEqual(rows(done)[0][3], "10")
        self.assertEqual(rows(done)[1][-1], "-")

    def test_legacy_asn_provider_is_grouped_by_the_shared_database(self):
        aliases = MODULE.load_aliases(ROOT / "data/providers/asn.txt")
        runs = [run(str(i)) for i in range(10)]
        for item in runs[:5]:
            item["raw:meta.tsv"] = item["raw:meta.tsv"].replace("MTS - Moscow", "Legacy holder (AS8359) - Moscow")
        self.assertEqual(rows(runs, "MTS", aliases)[0][3], "10")
        self.assertEqual(rows(runs, "Legacy holder (AS8359)", aliases)[0][3], "10")
        self.assertEqual(rows(runs, "Legacy holder (AS83590)", aliases)[0][3], "0")

    def test_three_positive_ranks_and_independent_sample_tiebreak(self):
        runs = [run(str(i), verdicts=("ok",) * 4) for i in range(9)]
        runs.append(run("9", verdicts=("ok",) * 5))
        ranked = [r for r in rows(runs) if r[:2] == ["strategy", "1"]]
        self.assertEqual([r[2] for r in ranked], ["1", "2", "3"])
        self.assertEqual([r[4] for r in ranked], ["10", "10", "10"])
        self.assertEqual(MODULE.percent(1, 100000), "0.001")

    def test_clone_comparison_weights_probes_not_run_percentages(self):
        # Classic average 66.7%, weighted 2/12; clone 50% must win.
        classic = [run(str(i), verdicts=("ok",)) for i in range(2)]
        classic.append(run("2", verdicts=("fail",) * 10))
        clone = [run(str(i), 2, "clone", ("ok", "fail")) for i in range(3, 10)]
        self.assertEqual(rows(classic + clone)[1], ["profile", "1", "10", "1", "16.666667", "50"])
        equal = [run(str(i), 3, "clone", ("ok", "fail", "fail", "fail", "fail", "fail")) for i in range(10)]
        self.assertEqual(rows(classic + equal + clone)[1][3], "0")

    def test_clone_hint_is_per_profile_and_gated_globally(self):
        classic = [run(str(i), verdicts=("fail",) * 4) for i in range(10)]
        clone = [run(str(i), 2) for i in range(3)]
        for item in clone:
            item["raw:meta.tsv"] = item["raw:meta.tsv"].replace("mode_1\tclassic", "mode_1\tclone")
        output = rows(classic + clone)
        self.assertEqual([r[3] for r in output[1:5]], ["1", "0", "0", "0"])
        output = rows(classic[:9] + clone)
        self.assertEqual(len(output), 5)
        self.assertEqual([r[3] for r in output[1:5]], ["0"] * 4)

    def test_cache_is_global_compact_and_daily(self):
        redis = FakeRedis([run(str(i)) for i in range(10)])
        first = MODULE.recommendations_tsv(redis, "MTS")
        self.assertIn("\t10\t", first.splitlines()[0])
        for provider in ("Other", "Random ISP", "MTS - Another City"):
            MODULE.recommendations_tsv(redis, provider)
        self.assertEqual(redis.reads, 1)
        cached = redis.values[MODULE.CACHE_KEY]
        self.assertNotIn("uuid", cached)
        self.assertNotIn("a.test", cached)
        self.assertEqual(redis.ttl[MODULE.CACHE_KEY], 86400)
        self.assertEqual(redis.ttl[MODULE.LOCK_KEY], 300)
        with self.assertRaises(ValueError):
            MODULE.recommendations_tsv(redis, "MTS\n")

    def test_refresh_contention_and_failure_do_not_publish_empty_cache(self):
        redis = FakeRedis([])
        redis.locked = True
        with self.assertRaises(RuntimeError):
            MODULE.recommendations_tsv(redis, "MTS")
        self.assertEqual(redis.reads, 0)
        redis.locked = False
        def broken(*args):
            raise OSError("Redis unavailable")
        redis.lrange = broken
        with self.assertRaises(OSError):
            MODULE.recommendations_tsv(redis, "MTS")
        self.assertNotIn(MODULE.CACHE_KEY, redis.values)
        self.assertNotIn(MODULE.LOCK_KEY, redis.values)

    def test_expired_lock_never_publishes_or_deletes_new_owner(self):
        redis = FakeRedis([run("one")])
        original = redis.eval
        def expire_before_publish(script, count, *args):
            if count == 2:
                redis.values[MODULE.LOCK_KEY] = "new-owner"
            return original(script, count, *args)
        redis.eval = expire_before_publish
        with self.assertRaises(RuntimeError):
            MODULE.recommendations_tsv(redis, "MTS")
        self.assertNotIn(MODULE.CACHE_KEY, redis.values)
        self.assertEqual(redis.values[MODULE.LOCK_KEY], "new-owner")

    def test_concurrent_requests_refresh_once(self):
        from concurrent.futures import ThreadPoolExecutor
        redis = FakeRedis([run(str(i)) for i in range(10)])
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda i: MODULE.recommendations_tsv(redis, f"Unknown {i}"), range(30)))
        self.assertEqual(redis.reads, 1)
        self.assertEqual(len(results), 30)

    def test_http_endpoint_public_utf8_tsv_and_errors(self):
        if not os.environ.get("ZATOR_STATS_SERVER"):
            self.skipTest("set ZATOR_STATS_SERVER to integration collector")
        path = Path(os.environ["ZATOR_STATS_SERVER"])
        self.assertTrue(path.exists(), "set ZATOR_STATS_SERVER to integration collector")
        fake = FakeRedis([run(str(i)) for i in range(10)])
        stub = types.ModuleType("redis")
        stub.Redis = types.SimpleNamespace(from_url=lambda *a, **k: fake)
        old_redis = sys.modules.get("redis")
        old_module = sys.modules.get("recommendations")
        sys.modules["redis"] = stub
        sys.modules["recommendations"] = MODULE
        spec = importlib.util.spec_from_file_location("collector_test", path)
        assert spec and spec.loader
        collector = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(collector)
            collector.RECOMMENDATION_ALIASES_PATH = ROOT / "data/providers/asn.txt"
            server = collector.ThreadingHTTPServer(("127.0.0.1", 0), collector.Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f"http://127.0.0.1:{server.server_port}/recommendations.tsv?provider="
            try:
                with urllib.request.urlopen(base + "MGTS%20-%20Town") as response:
                    self.assertEqual(response.status, 200)
                    self.assertIn("text/tab-separated-values", response.headers["Content-Type"])
                    body = response.read().decode()
                    self.assertEqual(body.splitlines()[0].split("\t")[2:4], ["MGTS - Town", "10"])
                    self.assertNotIn("a.test", body)
                for provider in ("", "MTS%09bad", "x" * 121, "MTS&provider=MTS", "MTS&provider="):
                    with self.assertRaises(urllib.error.HTTPError) as caught:
                        urllib.request.urlopen(base + provider)
                    self.assertEqual(caught.exception.code, 400)
                    caught.exception.close()
                fake.values.clear()
                fake.locked = True
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    urllib.request.urlopen(base + "MTS")
                self.assertEqual(caught.exception.code, 503)
                caught.exception.close()
            finally:
                server.shutdown()
                server.server_close()
                thread.join()
        finally:
            for name, old in (("redis", old_redis), ("recommendations", old_module)):
                if old is None:
                    sys.modules.pop(name, None)
                else:
                    sys.modules[name] = old


if __name__ == "__main__":
    unittest.main()