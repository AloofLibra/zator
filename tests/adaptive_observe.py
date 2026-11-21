#!/usr/bin/env python3
"""Verify bounded observation records without changing selected strategies."""
import json
from pathlib import Path
import tempfile

from lupa import LuaRuntime

repo = Path(__file__).resolve().parents[1]


def runtime(root: Path, mode: str):
    cache = root / "extra_strats/cache/adaptive"
    cache.mkdir(parents=True, exist_ok=True)
    (cache / "mode").write_text(mode + "\n")
    events = root / "events.tsv"
    events.touch()
    lua = LuaRuntime(unpack_returned_tuples=True)
    env = {
        "ZATOR_ROOT": str(root),
        "ZAPRET2_ROOT": "/nonexistent/zapret2",
        "Z2R_ADAPTIVE_RULES_FILE": str(root / "missing-rules.tsv"),
        "Z2R_ADAPTIVE_EVENTS_FILE": str(events),
        "Z2R_ADAPTIVE_RULES_APPLY": "0",
    }
    lua.globals().fake_getenv = lambda key: env.get(key)
    lua.execute("os.getenv = fake_getenv")
    lua.execute("test_now = 1000; os.time = function() return test_now end")
    lua.execute(f"dofile({json.dumps(str(repo / 'orchestra/locked.lua'))})")
    lua.execute("""
      VERDICT_PASS = 0
      DLOG = function() end
      DLOG_ERR = function() end
      dis_ipdst = function(dis) return dis.destination end
      ntop = function(address) return address end
      orchestrate = function() end
      automate_host_record = function() return {} end
      plan_instance_pop = function(desync) return table.remove(desync.plan, 1) end
      blob_override_execute = function(_, verdict) return verdict end
      local function invoke(host, ip, port, state)
        local desync = {
          profile="1", hostname=host, arg={proto="tls"},
          dis={destination=ip, ip={}, tcp={th_dport=port}},
          track=state or {lua_state={}}, plan={{arg={strategy=1}}}
        }
        circular_locked({}, desync)
      end
      local shared = {lua_state={}}
      invoke("cdn.example.org", "93.184.216.34", 443, shared)
      invoke("cdn.example.org", "93.184.216.34", 443, shared)
      invoke("cdn.example.org", "93.184.216.34", 443)
      invoke("cdn.example.org", "93.184.216.35", 443)
      invoke("cdn.example.org", "93.184.216.36", 8443)
      locked_load_lines_for_tests({"manual.example.org\\ttls\\t2"})
      invoke("manual.example.org", "93.184.216.37", 443)
      test_now = 5000
      invoke("cdn.example.org", "93.184.216.34", 443)
      test_invoke = invoke
    """)
    return lua, events


with tempfile.TemporaryDirectory(prefix="zator-adaptive-observe-") as tmp:
    root = Path(tmp)
    lua, events = runtime(root, "OBSERVE")
    rows = events.read_text().splitlines()
    assert len(rows) == 2, f"observation should dedupe tuples indefinitely and exclude other ports/manual lock: {rows!r}"
    assert all(len(row.split("\t")) == 8 and "http" not in row for row in rows), "event schema leaked unexpected fields"
    assert rows[0].split("\t")[:7] == ["1", "seen", "cdn.example.org", "93.184.216.34", "1", "tls", "default"]
    lua.execute('for i=1,130 do test_invoke("host"..i..".example.org", "94.0.0."..i, 443) end')
    rows = events.read_text().splitlines()
    assert len(rows) == 128, f"observation ring must stay bounded at 128 rows: {len(rows)}"
    assert rows[0].split("\t")[2] == "host3.example.org" and rows[-1].split("\t")[2] == "host130.example.org", \
        "observation ring must evict oldest rows and retain newest rows"

with tempfile.TemporaryDirectory(prefix="zator-adaptive-off-") as tmp:
    _, events = runtime(Path(tmp), "OFF")
    assert events.read_text() == "", "OFF mode wrote an observation"

with tempfile.TemporaryDirectory(prefix="zator-adaptive-test-only-") as tmp:
    _, events = runtime(Path(tmp), "TEST_ONLY")
    rows = events.read_text().splitlines()
    assert len(rows) == 2 and all(row.split("\t")[1] == "seen" for row in rows), \
        "TEST_ONLY must continue observing without applying production strategy rules"

with tempfile.TemporaryDirectory(prefix="zator-adaptive-suspected-") as tmp:
    lua, events = runtime(Path(tmp), "TEST_ONLY")
    lua.execute("""
      local function failure(track, crec)
        local desync = {outgoing=true, profile="1", hostname="cdn.example.org", arg={proto="tls"},
          dis={destination="93.184.216.34", ip={}, tcp={th_dport=443}}, track=track}
        z2r_adaptive_observe_connection(desync, "1", "cdn.example.org", "default", true)
        z2r_adaptive_suspected_failure(desync, crec)
      end
      test_failure = failure
    """)
    same_track = lua.eval("{lua_state={}}")
    same_crec = lua.eval("{}")
    lua.globals().test_failure(same_track, same_crec)
    assert events.read_text().split("\t")[1] == "seen", "one failed connection must remain a weak observation"
    lua.globals().test_failure(same_track, same_crec)
    assert events.read_text().split("\t")[1] == "seen", "same connection must not count twice"
    lua.globals().test_failure(lua.eval("{lua_state={}}"), lua.eval("{}"))
    assert events.read_text().split("\t")[1] == "suspected_failure", \
        "two independent failed connections should create a suspected_failure event"
    stored_rows = [row.split("\t") for row in events.read_text().splitlines() if row]
    tuple_rows = [row for row in stored_rows if row[2:4] == ["cdn.example.org", "93.184.216.34"]]
    assert len(tuple_rows) == 1 and len(stored_rows) == 2, \
        f"suspected failure must update its tuple row without duplication: {stored_rows!r}"

print("adaptive observation smoke ok")
