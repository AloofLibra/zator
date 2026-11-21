#!/usr/bin/env python3
"""Verify bounded observation records without changing selected strategies."""
import json
from pathlib import Path
import tempfile

from lupa import LuaRuntime

repo = Path(__file__).resolve().parents[1]


def runtime(root: Path, mode: str, default_scope: bool = False):
    cache = root / "extra_strats/cache/adaptive"
    cache.mkdir(parents=True, exist_ok=True)
    (cache / "mode").write_text(mode + "\n")
    if default_scope:
        (cache / "apply-default-scope").write_text("1\n")
    events = root / "events.tsv"
    events.touch()
    ramp_targets = root / "ramp-targets.tsv"
    ramp_targets.touch()
    lua = LuaRuntime(unpack_returned_tuples=True)
    env = {
        "ZATOR_ROOT": str(root),
        "ZAPRET2_ROOT": "/nonexistent/zapret2",
        "Z2R_ADAPTIVE_RULES_FILE": str(root / "missing-rules.tsv"),
        "Z2R_ADAPTIVE_EVENTS_FILE": str(events),
        "Z2R_ADAPTIVE_RAMP_TARGETS_FILE": str(ramp_targets),
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
    return lua, events, ramp_targets


with tempfile.TemporaryDirectory(prefix="zator-adaptive-observe-") as tmp:
    root = Path(tmp)
    lua, events, ramp_targets = runtime(root, "OBSERVE")
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
    _, events, ramp_targets = runtime(Path(tmp), "OFF")
    assert events.read_text() == "" and ramp_targets.read_text() == "", "OFF mode wrote an observation"

with tempfile.TemporaryDirectory(prefix="zator-adaptive-test-only-") as tmp:
    _, events, ramp_targets = runtime(Path(tmp), "TEST_ONLY")
    rows = events.read_text().splitlines()
    assert len(rows) == 2 and all(row.split("\t")[1] == "seen" for row in rows), \
        "TEST_ONLY must continue observing without applying production strategy rules"
    assert ramp_targets.read_text() == "", "TEST_ONLY must not create the AGENT_BETA Ramp audit catalog"

with tempfile.TemporaryDirectory(prefix="zator-adaptive-beta-") as tmp:
    lua, events, ramp_targets = runtime(Path(tmp), "AGENT_BETA")
    rows = events.read_text().splitlines()
    assert len(rows) == 2 and all(row.split("\t")[1] == "seen" for row in rows), \
        "AGENT_BETA must keep discovery active while applying verified rules"
    lua.execute("""
      function observe_ramp(host, ip, scope)
        local d = {outgoing=true, profile="2", hostname=host, arg={proto="tls"},
          dis={destination=ip, tcp={th_dport=443}}, track={lua_state={}}}
        z2r_adaptive_observe_connection(d, "2", host, scope or "mark:4", true)
      end
      local hosts = {
        "rr1-index.googlevideo.com", "rr2-index.googlevideo.com",
        "rr1-index2.googlevideo.com", "r1---sn-abcd.googlevideo.com",
        "r2---sn-abcd.googlevideo.com", "r2---sn-efgh.googlevideo.com",
        "redirector.googlevideo.com", "evilgooglevideo.com"
      }
      for i, host in ipairs(hosts) do observe_ramp(host, "94.0.0."..i, "mark:4") end
      observe_ramp("rr3-index.googlevideo.com", "94.0.0.1", "mark:4")
      observe_ramp("rr1-index.googlevideo.com", "192.168.1.1", "mark:4")
      observe_ramp("rr1-index.googlevideo.com", "94.0.0.1", "default")
      test_observe_ramp = observe_ramp
    """)
    targets = [row.split("\t") for row in ramp_targets.read_text().splitlines()]
    assert len(targets) == 9, f"Ramp catalog should contain only strict Googlevideo tuples and distinct scopes: {targets!r}"
    by_host = {row[1]: row for row in targets if row[3] == "mark:4"}
    assert by_host["rr1-index.googlevideo.com"][6] == by_host["rr2-index.googlevideo.com"][6] == "gv1:rr:index"
    assert by_host["rr1-index2.googlevideo.com"][6] == "gv1:rr:index2"
    assert by_host["r1---sn-abcd.googlevideo.com"][6] == by_host["r2---sn-abcd.googlevideo.com"][6] == "gv1:r:---sn-abcd"
    assert by_host["r2---sn-efgh.googlevideo.com"][6] == "gv1:r:---sn-efgh"
    by_host = {row[1]: row for row in targets if row[3] == "mark:4"}
    assert by_host["rr1-index.googlevideo.com"][7] == by_host["rr3-index.googlevideo.com"][7] == "conflict", \
        f"different observed hostnames sharing an IP/scope must preserve Ramp and report conflict: {targets!r}"
    assert all(row[5] == "tls-observed" and row[7:] == ["pending", "0", "unknown"]
               for row in targets if row[1] not in {"rr1-index.googlevideo.com", "rr3-index.googlevideo.com"})
    lua.globals().test_observe_ramp("rr1-index.googlevideo.com", "94.0.0.1", "mark:4")
    assert len(ramp_targets.read_text().splitlines()) == 9, "a repeated host/IP/scope should update, not duplicate, the Ramp target"
    lua.execute('for i=1,130 do test_observe_ramp("rr1-x"..i..".googlevideo.com", "94.0.1."..i, "mark:4") end')
    targets = ramp_targets.read_text().splitlines()
    assert len(targets) == 128 and "rr1-x130.googlevideo.com" in targets[-1] and "rr1-index.googlevideo.com" not in "\n".join(targets), \
        "Ramp target ring must stay bounded and evict the oldest targets"

with tempfile.TemporaryDirectory(prefix="zator-adaptive-suspected-") as tmp:
    lua, events, _ = runtime(Path(tmp), "TEST_ONLY")
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

with tempfile.TemporaryDirectory(prefix="zator-adaptive-degraded-") as tmp:
    lua, events, _ = runtime(Path(tmp), "AGENT_BETA", default_scope=True)
    lua.execute("""
      locked_load_lines_for_tests({})
      locked_load_adaptive_lines_for_tests({"1\tcdn.example.org\t93.184.216.34\t1\ttls\tdefault\t1\t" ..
        "sha256:" .. string.rep("a", 64) .. "\tsha256:" .. string.rep("b", 64) .. "\t123:456\t10000"}, 1000, "123:456")
      local function applied_failure()
        local desync = {outgoing=true, profile="1", hostname="cdn.example.org", arg={proto="tls"},
          dis={destination="93.184.216.34", ip={}, tcp={th_dport=443}},
          track={lua_state={}}, plan={{arg={strategy=1}}}}
        circular_locked({}, desync)
        z2r_adaptive_suspected_failure(desync, {})
      end
      test_failure = applied_failure
    """)
    selected_test_rule = lua.eval('(locked_adaptive_strategy_for_tuple("cdn.example.org", "93.184.216.34", "1", "tls", "default", 5000))')
    assert selected_test_rule == 1, f"test fixture did not load the exact adaptive rule: {selected_test_rule!r}"
    lua.globals().test_failure()
    assert events.read_text().split("\t")[1] == "seen", "one failed connection must not mark an active rule degraded"
    lua.globals().test_failure()
    assert events.read_text().split("\t")[1] == "active_rule_degraded", \
        f"two failures on flows where the exact adaptive rule was selected must identify active_rule_degraded: {events.read_text()!r}"

print("adaptive observation smoke ok")
