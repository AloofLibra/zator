#!/usr/bin/env python3
"""Check exact adaptive-rule parsing and lookup in the production Lua module."""
import json
import os
from pathlib import Path
import tempfile
import time

from lupa import LuaRuntime

repo = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().fake_getenv = lambda key: {"Z2R_ADAPTIVE_RULES_FILE": "/nonexistent/adaptive-rules.tsv"}.get(key)
lua.execute("os.getenv = fake_getenv")
lua.execute(f"dofile({json.dumps(str(repo / 'orchestra/locked.lua'))})")
lua.execute(r'''
local fp = "sha256:" .. string.rep("a", 64)
local cat = "sha256:" .. string.rep("b", 64)
local stamp = "1:2|3:4|5:6|7:8|9:10|11:12|13:14"
local valid = table.concat({"1", "cdn.example.org", "93.184.216.34", "1", "tls", "default", "7", fp, cat, stamp, "5000"}, "\t")
locked_load_adaptive_lines_for_tests({valid}, 1000, stamp)
local n, found_fp, found_cat, expires = locked_adaptive_strategy_for_tuple("cdn.example.org", "93.184.216.34", "1", "tls", "default", 1000)
assert(n == 7 and found_fp == fp and found_cat == cat and expires == 5000, "exact rule not returned")
assert(locked_adaptive_strategy_for_tuple("cdn.example.org", "93.184.216.35", "1", "tls", "default", 1000) == 7, "same-scope strategy did not survive a client IP change")
assert(locked_adaptive_strategy_for_tuple("cdn.example.org", "93.184.216.34", "2", "tls", "default", 1000) == nil, "profile was not exact")
assert(locked_adaptive_strategy_for_tuple("cdn.example.org", "93.184.216.34", "1", "http", "default", 1000) == nil, "application protocol was not exact")
assert(locked_adaptive_strategy_for_tuple("cdn.example.org", "93.184.216.34", "1", "tls", "mark:4", 1000) == nil, "scope was not exact")
assert(locked_adaptive_strategy_for_tuple("cdn.example.org", "93.184.216.34", "1", "tls", "default", 5000) == nil, "expired rule was returned")
local private = valid:gsub("93%.184%.216%.34", "203.0.113.10")
locked_load_adaptive_lines_for_tests({private}, 1000, stamp)
assert(locked_adaptive_strategy_for_tuple("cdn.example.org", "203.0.113.10", "1", "tls", "default", 1000) == nil, "reserved destination was accepted")
locked_load_adaptive_lines_for_tests({valid, valid:gsub("\t7\t", "\t8\t")}, 1000, stamp)
assert(locked_adaptive_strategy_for_tuple("cdn.example.org", "93.184.216.34", "1", "tls", "default", 1000) == nil, "conflicting duplicate was accepted")
local long_stamp = string.rep("1", 500)
local long_row = table.concat({"1", "long.example.org", "93.184.216.34", "1", "tls", "default", "7", fp, cat, long_stamp, "5000"}, "\t")
locked_load_adaptive_lines_for_tests({long_row}, 1000, long_stamp)
assert(locked_adaptive_strategy_for_tuple("long.example.org", "93.184.216.34", "1", "tls", "default", 1000) == 7,
  "valid runtime stamp above 400 bytes was rejected")
local direct = valid:gsub("\t7\t", "\t0\t")
locked_load_adaptive_lines_for_tests({direct}, 1000, stamp)
assert(locked_adaptive_strategy_for_tuple("cdn.example.org", "93.184.216.34", "1", "tls", "default", 1000) == 0,
  "DIRECT sentinel was not preserved as a distinct exact rule")
local gv = table.concat({"1", "rr1---sn-a5mekn6e.googlevideo.com", "93.184.216.37", "2", "googlevideo-tcp", "default", "12", fp, cat, stamp, "5000"}, "\t")
locked_load_adaptive_lines_for_tests({gv}, 1000, stamp)
assert(locked_adaptive_strategy_for_tuple("rr1---sn-a5mekn6e.googlevideo.com", "93.184.216.37", "2", "googlevideo-tcp", "default", 1000) == 12,
  "exact Googlevideo media rule was rejected")
assert(locked_adaptive_strategy_for_tuple("rr1---sn-a5mekn6e.googlevideo.com", "93.184.216.37", "2", "tls", "default", 1000) == nil,
  "Googlevideo media result was mixed into the TLS recipe")
local quic = table.concat({"1", "rr1---sn-a5mekn6e.googlevideo.com", "93.184.216.41", "5", "quic", "mark:7", "9", fp, cat, stamp, "5000"}, "\t")
locked_load_adaptive_lines_for_tests({quic}, 1000, stamp)
assert(locked_adaptive_strategy_for_tuple("rr1---sn-a5mekn6e.googlevideo.com", "93.184.216.41", "5", "quic", "mark:7", 1000) == 9,
  "exact profile-5 QUIC rule was rejected")
assert(locked_adaptive_strategy_for_tuple("rr1---sn-a5mekn6e.googlevideo.com", "93.184.216.41", "5", "tls", "mark:7", 1000) == nil,
  "QUIC result leaked into the TCP strategy category")
assert(locked_adaptive_strategy_for_tuple("rr1---sn-a5mekn6e.googlevideo.com", "93.184.216.41", "5", "quic", "mark:8", 1000) == nil,
  "QUIC rule ignored its client scope")
local invalid_quic = quic:gsub("rr1%-%-%-sn%-a5mekn6e%.googlevideo%.com", "cdn.example.org")
locked_load_adaptive_lines_for_tests({invalid_quic}, 1000, stamp)
assert(locked_adaptive_strategy_for_tuple("cdn.example.org", "93.184.216.41", "5", "quic", "mark:7", 1000) == nil,
  "QUIC adaptive rule accepted a non-YouTube host")
local invalid_gv = gv:gsub("rr1%-%-%-sn%-a5mekn6e%.googlevideo%.com", "cdn.example.org")
locked_load_adaptive_lines_for_tests({invalid_gv}, 1000, stamp)
assert(locked_adaptive_strategy_for_tuple("cdn.example.org", "93.184.216.37", "2", "tls", "default", 1000) == nil,
  "media-derived rule accepted a non-Googlevideo host")
''')
print("adaptive Lua rule lookup smoke ok")

# A reboot removes the tmpfs store; the loader may then recover the delayed snapshot.
with tempfile.TemporaryDirectory(prefix="zator-adaptive-snapshot-") as tmp:
    root = Path(tmp)
    snapshot = root / "extra_strats/cache/adaptive/rules.tsv"
    snapshot.parent.mkdir(parents=True)
    fp = "sha256:" + "a" * 64
    cat = "sha256:" + "b" * 64
    stamp = "|".join(["0:0"] * 24)
    expiry = int(time.time()) + 3600
    snapshot.write_text(f"1\tpersist.example.org\t93.184.216.34\t1\ttls\tdefault\t7\t{fp}\t{cat}\t{stamp}\t{expiry}\n")
    runtime = LuaRuntime(unpack_returned_tuples=True)
    env = {"Z2R_ADAPTIVE_RULES_FILE": str(root / "missing/rules.tsv"), "ZATOR_ROOT": str(root)}
    runtime.globals().fake_getenv = lambda key: env.get(key)
    runtime.execute("os.getenv = fake_getenv; stat = function(path) return {mtime=0, size=0} end")
    runtime.execute(f"dofile({json.dumps(str(repo / 'orchestra/locked.lua'))})")
    recovered = runtime.eval('locked_adaptive_strategy_for_tuple("persist.example.org", "93.184.216.34", "1", "tls", "default")')
    assert recovered[0] == 7, f"snapshot rule was not recovered: {recovered!r}"
print("adaptive Lua snapshot recovery smoke ok")

# Blob payload edits invalidate the production selector even when size is unchanged.
with tempfile.TemporaryDirectory(prefix="zator-adaptive-blob-stamp-") as tmp:
    root = Path(tmp)
    zator = root / "zator"
    zapret = root / "zapret2"
    blob = zator / "files/fake/test.bin"
    blob.parent.mkdir(parents=True)
    zapret.mkdir(parents=True)
    blob.write_bytes(b"blob-A")
    config = zapret / "config"
    config.write_text('NFQWS2_OPT="\n--blob=test_blob:@/opt/zator/files/fake/test.bin\n"\n')
    env = {
        "Z2R_ADAPTIVE_RULES_FILE": str(root / "missing/rules.tsv"),
        "ZATOR_ROOT": str(zator),
        "ZAPRET2_ROOT": str(zapret),
    }
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.globals().fake_getenv = lambda key: env.get(key)

    def runtime_stat(path):
        try:
            info = Path(str(path)).stat()
        except OSError:
            return None
        return runtime.table_from({"mtime": int(info.st_mtime), "size": info.st_size})

    runtime.globals().fake_stat = runtime_stat
    runtime.execute("os.getenv = fake_getenv; stat = function(path) return fake_stat(path) end")
    runtime.execute(f"dofile({json.dumps(str(repo / 'orchestra/locked.lua'))})")
    old_stamp = runtime.globals().locked_adaptive_runtime_stamp_for_tests()
    old_stat = blob.stat()
    blob.write_bytes(b"blob-B")
    os.utime(blob, (old_stat.st_atime, old_stat.st_mtime + 5))
    runtime.execute(f"dofile({json.dumps(str(repo / 'orchestra/locked.lua'))})")
    new_stamp = runtime.globals().locked_adaptive_runtime_stamp_for_tests()
    assert old_stamp != new_stamp, f"runtime stamp ignored a same-size blob payload change: {old_stamp!r} == {new_stamp!r}"
    expiry = int(time.time()) + 3600
    fp = "sha256:" + "c" * 64
    cat = "sha256:" + "d" * 64
    stale_row = "\t".join(["1", "blob.example.org", "93.184.216.34", "1", "tls", "default", "7", fp, cat, str(old_stamp), str(expiry)])
    runtime.globals().stale_rule = stale_row
    runtime.execute("locked_load_adaptive_lines_for_tests({stale_rule}, os.time(), nil)")
    assert runtime.eval('locked_adaptive_strategy_for_tuple("blob.example.org", "93.184.216.34", "1", "tls", "default")') is None, \
        "rule created against the previous blob payload remained applicable"
print("adaptive Lua blob invalidation smoke ok")
