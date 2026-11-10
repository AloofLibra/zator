#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("googlevideo_ips", ROOT / "tools/stats/googlevideo_ips.py")
MODULE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(MODULE)


class Pipeline:
    def __init__(self, db):
        self.db, self.ops = db, []
    def hgetall(self, key): self.ops.append(("hgetall", key))
    def zadd(self, key, mapping): self.ops.append(("zadd", key, mapping))
    def zremrangebyscore(self, key, low, high): self.ops.append(("zremrangebyscore", key, low, high))
    def zremrangebyrank(self, key, low, high): self.ops.append(("zremrangebyrank", key, low, high))
    def execute(self):
        result = []
        for op in self.ops:
            if op[0] == "hgetall": result.append(self.db.hashes.get(op[1], {}))
            elif op[0] == "zadd":
                self.db.zsets.setdefault(op[1], {}).update(op[2]); result.append(1)
            elif op[0] == "zremrangebyscore":
                z = self.db.zsets.setdefault(op[1], {})
                for member, score in list(z.items()):
                    if score <= float(op[3]): z.pop(member, None)
                result.append(0)
            elif op[0] == "zremrangebyrank": result.append(0)
        return result


class FakeRedis:
    def __init__(self): self.hashes, self.zsets = {}, {}
    def lrange(self, key, start, end): return [b"run1"]
    def pipeline(self, transaction=False): return Pipeline(self)
    def zrangebyscore(self, key, low, high, withscores=False):
        rows = sorted(self.zsets.get(key, {}).items(), key=lambda row: row[1])
        rows = [(member, score) for member, score in rows if score >= float(low) and (high == "+inf" or score <= float(high))]
        return rows if withscores else [member for member, _ in rows]
    def zadd(self, key, mapping): self.zsets.setdefault(key, {}).update(mapping)
    def zremrangebyscore(self, key, low, high):
        z = self.zsets.setdefault(key, {})
        for member, score in list(z.items()):
            if score <= float(high): z.pop(member, None)
    def zremrangebyrank(self, key, low, high): pass


class GoogleVideoTests(unittest.TestCase):
    def test_strict_host_scope(self):
        self.assertEqual(MODULE.normalize_host("RR2---sn-x.googlevideo.com."), "rr2---sn-x.googlevideo.com")
        for host in ("googlevideo.com", "youtube.com", "rr.googlevideo.com.evil", "ytimg.com", "*.googlevideo.com", "127.0.0.1.googlevideo.com"):
            self.assertIsNone(MODULE.normalize_host(host), host)
        self.assertEqual(MODULE._hosts_in_media_meta(json.dumps({
            "video_id": "private-id-is-ignored",
            "audio_url": "https://signed.googlevideo.com/videoplayback?sig=secret",
            "cdn_hostname": {"audio": "audio.googlevideo.com", "video": "video.youtube.com"},
        })), {"audio.googlevideo.com"})

    def test_historical_host_poll_and_ipset_output(self):
        db = FakeRedis()
        db.hashes["z4r:supersweep:run:run1"] = {
            b"raw:meta.tsv": b"created\t900\nuuid\tabc\n",
            b"raw:media-meta.json": json.dumps({"cdn_hostname": {
                "audio": "audio.googlevideo.com", "video": "video.googlevideo.com"}}).encode(),
        }
        old_query = MODULE.dns_a_query
        MODULE.dns_a_query = lambda host, resolver: ["8.8.8.8"]
        try:
            with tempfile.TemporaryDirectory() as temp:
                seed = pathlib.Path(temp) / "seed.txt"
                seed.write_text("# strict seed\nrr2---sn-seed.googlevideo.com\nyoutube.com\n", encoding="utf-8")
                count = MODULE.refresh(db, str(seed), source_url=None, now=1000)
                self.assertEqual(count, 9)
                output = MODULE.render_ipset(db, now=1000)
                self.assertIn("8.8.8.8", output)
                self.assertNotIn("youtube.com", output)
                rows = db.zsets[MODULE.OBSERVATIONS_KEY]
                self.assertTrue(any("audio.googlevideo.com\tgoogle\t8.8.8.8" in row for row in rows))
                self.assertTrue(all(score == 1000 for score in rows.values()))
                db.zsets[MODULE.OBSERVATIONS_KEY]["future.googlevideo.com\tgoogle\t1.1.1.1"] = 1001
                self.assertNotIn("1.1.1.1", MODULE.render_ipset(db, now=1000))
        finally:
            MODULE.dns_a_query = old_query

    def test_dns_response_uses_only_requested_name_cname_chain(self):
        host = "rr.googlevideo.com"
        qname = b"".join(bytes((len(part),)) + part.encode() for part in host.split(".")) + b"\0"
        target = "cdn.googlevideo.com"
        target_wire = b"".join(bytes((len(part),)) + part.encode() for part in target.split(".")) + b"\0"
        question = qname + b"\0\1\0\1"
        cname_offset = 12 + len(question) + 12
        cname = b"\xc0\x0c" + b"\0\5\0\1\0\0\0\x3c" + len(target_wire).to_bytes(2, "big") + target_wire
        address = b"\xc0" + bytes((cname_offset,)) + b"\0\1\0\1\0\0\0\x3c\0\4\x08\x08\x04\x04"
        unrelated = b"\x03bad\x0bgooglevideo\x03com\0\0\1\0\1\0\0\0\x3c\0\4\x01\x01\x01\x01"
        class FakeSocket:
            def __init__(self, *_args): pass
            def __enter__(self): return self
            def __exit__(self, *_args): pass
            def settimeout(self, _value): pass
            def sendto(self, packet, _peer): self.ident = packet[:2]
            def recvfrom(self, _size):
                header = self.ident + b"\x81\x80\0\1\0\3\0\0\0\0"
                return header + question + cname + address + unrelated, ("8.8.8.8", 53)
        old_socket = MODULE.socket.socket
        MODULE.socket.socket = FakeSocket
        try:
            self.assertEqual(MODULE.dns_a_query(host, "8.8.8.8"), ["8.8.4.4"])
        finally:
            MODULE.socket.socket = old_socket

    def test_admin_summary_groups_domains_and_adjacent_cidr(self):
        db = FakeRedis()
        db.zsets[MODULE.OBSERVATIONS_KEY] = {
            "rr-a.googlevideo.com\tgoogle\t8.8.8.8": 100,
            "rr-a.googlevideo.com\tcloudflare\t8.8.8.9": 101,
            "rr-b.googlevideo.com\tquad9\t8.8.8.9": 102,
            "youtube.com\tgoogle\t8.8.8.10": 103,
            "rr-c.googlevideo.com\tgoogle\t10.0.0.1": 103,
        }
        summary = MODULE.domain_summary(db, now=110)
        self.assertEqual(summary["domain_count"], 2)
        self.assertEqual(summary["ip_count"], 2)
        self.assertEqual({row["cidr"] for row in summary["cidrs"]}, {"8.8.8.8/31"})
        self.assertEqual(summary["cidrs"][0]["domain_count"], 2)

    def test_consented_local_dns_batch_is_bounded_and_distributed(self):
        db = FakeRedis()
        self.assertEqual(MODULE.observe_local_ips(db, ["8.8.4.4", "1.1.1.1", "8.8.4.4"], now=2000), 2)
        body = MODULE.render_ipset(db, now=2000)
        self.assertIn("8.8.4.4", body)
        self.assertIn("1.1.1.1", body)
        with self.assertRaises(ValueError):
            MODULE.observe_local_ips(db, ["192.168.1.1"], now=2000)
        summary = MODULE.domain_summary(db, now=2000)
        self.assertEqual(summary["local_ip_count"], 2)
        self.assertEqual({row["ip"] for row in summary["local_ips"]}, {"8.8.4.4", "1.1.1.1"})


if __name__ == "__main__":
    unittest.main()
