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
    quic_health = root / "quic-health.tsv"
    quic_health.touch()
    lua = LuaRuntime(unpack_returned_tuples=True)
    env = {
        "ZATOR_ROOT": str(root),
        "ZAPRET2_ROOT": "/nonexistent/zapret2",
        "Z2R_ADAPTIVE_RULES_FILE": str(root / "missing-rules.tsv"),
        "Z2R_ADAPTIVE_EVENTS_FILE": str(events),
        "Z2R_ADAPTIVE_QUIC_HEALTH_FILE": str(quic_health),
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
    assert len(rows) == 1, f"observation should dedupe host/scope across client IPs and exclude other ports/manual lock: {rows!r}"
    assert len(rows[0].split("\t")) == 10 and "http" not in rows[0], "event schema leaked unexpected fields"
    assert rows[0].split("\t")[:7] == ["1", "seen", "cdn.example.org", "93.184.216.34", "1", "tls", "default"]
    assert rows[0].split("\t")[7] == "5000", "re-observed production tuple must refresh stale discovery time"
    lua.execute('test_now = 5029; test_invoke("cdn.example.org", "93.184.216.34", 443)')
    assert events.read_text().splitlines()[0].split("\t")[7] == "5000", \
        "repeat flows inside the refresh interval must not rewrite the bounded observation journal"
    lua.execute('test_now = 5030; test_invoke("cdn.example.org", "93.184.216.34", 443)')
    assert events.read_text().splitlines()[0].split("\t")[7] == "5030", \
        "observation timestamp should refresh again after the throttle interval"
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
    assert len(rows) == 1 and all(row.split("\t")[1] == "seen" for row in rows), \
        "TEST_ONLY must continue observing without applying production strategy rules"
    assert ramp_targets.read_text() == "", "TEST_ONLY must not create the AGENT_BETA Ramp audit catalog"

with tempfile.TemporaryDirectory(prefix="zator-adaptive-beta-") as tmp:
    lua, events, ramp_targets = runtime(Path(tmp), "AGENT_BETA")
    rows = events.read_text().splitlines()
    assert len(rows) == 1 and all(row.split("\t")[1] == "seen" for row in rows), \
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
    assert len(tuple_rows) == 1 and len(stored_rows) == 1, \
        f"suspected failure must update its tuple row without duplication: {stored_rows!r}"

with tempfile.TemporaryDirectory(prefix="zator-adaptive-router-auto-") as tmp:
    lua, events, _ = runtime(Path(tmp), "AUTO")
    def router_status():
        return next(row.split("\t")[1] for row in events.read_text().splitlines()
                    if row.split("\t")[2] == "router-auto.example.org")
    lua.execute("""
      locked_load_lines_for_tests({})
      local function flow()
        local desync = {outgoing=true, profile="1", hostname="router-auto.example.org", arg={proto="tls"},
          dis={destination="93.184.216.44", ip={}, tcp={th_dport=443}}, track={lua_state={}},
          plan={{arg={strategy=1}}, {arg={strategy=2}}, {arg={strategy=3}}}}
        circular_locked({}, desync)
        return desync
      end
      function auto_fail()
        local desync = flow()
        z2r_adaptive_suspected_failure(desync, {})
        return desync.track.lua_state.adaptive_observe_context.selected_strategy
      end
      function auto_application_failure()
        local desync = flow()
        z2r_adaptive_suspected_failure(desync, {}, "application")
        return desync.track.lua_state.adaptive_observe_context.selected_strategy
      end
      function auto_ambiguous_failure()
        local desync = flow()
        z2r_adaptive_suspected_failure(desync, {}, "ambiguous")
        return desync.track.lua_state.adaptive_observe_context.selected_strategy
      end
    """)
    assert lua.globals().auto_application_failure() == 1 and lua.globals().auto_application_failure() == 1 \
        and lua.globals().auto_ambiguous_failure() == 1 and router_status() == "seen", \
        "router AUTO must ignore application failures and ambiguous upstream redirect signals"
    assert lua.globals().auto_fail() == 1 and router_status() == "seen", \
        "router AUTO must not rotate on only one failed production flow"
    assert lua.globals().auto_fail() == 1 and router_status() == "router_trial_2", \
        "router AUTO should start a low-confidence next-strategy trial after two independent failures"
    assert lua.globals().auto_fail() == 2 and router_status() == "router_trial_2", \
        "router AUTO should keep the current trial after one failure"
    assert lua.globals().auto_fail() == 2 and router_status() == "router_trial_3", \
        "router AUTO should advance only after two failures on the current candidate"
    assert lua.globals().auto_fail() == 3 and router_status() == "router_trial_3", \
        "router AUTO should test the next configured strategy in production"
    assert lua.globals().auto_fail() == 3 and router_status() == "router_exhausted", \
        "router AUTO should stop after the configured candidates fail"
    assert lua.globals().auto_fail() == 1 and router_status() == "router_exhausted", \
        "exhaustion should return to the configured first strategy without claiming success"

with tempfile.TemporaryDirectory(prefix="zator-adaptive-router-auto-quic-") as tmp:
    lua, events, _ = runtime(Path(tmp), "AUTO")
    def quic_router_status():
        return next(row.split("\t")[1] for row in events.read_text().splitlines()
                    if row.split("\t")[2] == "rr1.googlevideo.com")
    lua.execute("""
      local function flow(track)
        local desync = {outgoing=true, profile="5", hostname="rr1.googlevideo.com", l7payload="quic_initial",
          arg={proto="udp"}, dis={destination="94.0.3.5", ip={}, udp={th_dport=443, th_sport=49152}}, track=track,
          plan={{arg={strategy=1}}, {arg={strategy=2}}, {arg={strategy=3}}}}
        circular_locked({}, desync)
        return desync
      end
      function quic_one_initial(track)
        return flow(track).track.lua_state.adaptive_observe_context.selected_strategy
      end
      function quic_retry(track)
        return flow(track).track.lua_state.adaptive_observe_context.selected_strategy
      end
      function quic_auto_selected()
        return flow({lua_state={}}).track.lua_state.adaptive_observe_context.selected_strategy
      end
    """)
    quic_track = lua.eval("{lua_state={}}")
    assert lua.globals().quic_one_initial(quic_track) == 1 and quic_router_status() == "seen", \
        "one unanswered QUIC Initial must remain a weak observation"
    quic_second_selected = lua.globals().quic_retry(quic_track)
    assert quic_second_selected == 1 and quic_router_status() == "router_trial_2", \
        f"a repeated Initial on the same QUIC connection should start a low-confidence next-strategy trial: selected={quic_second_selected!r}, event={quic_router_status()!r}, health={(Path(tmp) / 'quic-health.tsv').read_text()!r}"
    assert lua.globals().quic_auto_selected() == 2, "QUIC router AUTO did not apply the next production strategy"

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
    assert events.read_text().split("\t")[1] == "router_exhausted", \
        f"passive rotation should exhaust only its own router candidates while preserving the browser rule: {events.read_text()!r}"
    retained_rule = lua.eval('locked_adaptive_strategy_for_tuple("cdn.example.org", "93.184.216.34", "1", "tls", "default", 5000)')
    assert retained_rule[0] == 1, f"passive failure suspicion overwrote the browser-confirmed strategy: {retained_rule!r}"

with tempfile.TemporaryDirectory(prefix="zator-adaptive-shared-rule-") as tmp:
    lua, _, _ = runtime(Path(tmp), "AGENT_BETA")
    lua.execute("""
      locked_load_lines_for_tests({})
      locked_load_adaptive_lines_for_tests({"1\\tcdn.example.org\\t93.184.216.34\\t1\\ttls\\tshared\\t9\\t" ..
        "sha256:" .. string.rep("a", 64) .. "\\tsha256:" .. string.rep("b", 64) .. "\\t123:456\\t10000"}, 1000, "123:456")
      local desync = {profile="1", hostname="cdn.example.org", arg={proto="tls"},
        dis={destination="93.184.216.34", ip={}, tcp={th_dport=443}},
        track={lua_state={}}, plan={}}
      for i=1,9 do desync.plan[i] = {arg={strategy=i}} end
      circular_locked({}, desync)
      test_shared_strategy = desync.track.lua_state.adaptive_rule_strategy
      test_shared_applied = desync.track.lua_state.adaptive_observe_context.adaptive_rule_applied
      locked_load_lines_for_tests({"cdn.example.org\\ttls\\t1"})
      local manual = {profile="1", hostname="cdn.example.org", arg={proto="tls"},
        dis={destination="93.184.216.34", ip={}, tcp={th_dport=443}},
        track={lua_state={}}, plan={{arg={strategy=1}}}}
      circular_locked({}, manual)
      test_manual_skipped_shared = manual.track.lua_state.adaptive_rule_strategy == nil
    """)
    assert lua.globals().test_shared_strategy == 9 and lua.globals().test_shared_applied is True, \
        f"browser-confirmed shared strategy should apply to default-scope clients without beta-lan consent: strategy={lua.globals().test_shared_strategy!r}, applied={lua.globals().test_shared_applied!r}"
    assert lua.eval('locked_adaptive_strategy_for_tuple("cdn.example.org", "93.184.216.34", "1", "tls", "mark:5", 5000)') is None, \
        "a marked client must not inherit the shared default-scope baseline"
    assert lua.globals().test_manual_skipped_shared is True, \
        "manual strategy lock must override browser-confirmed shared baseline"

with tempfile.TemporaryDirectory(prefix="zator-adaptive-shared-auto-") as tmp:
    lua, _, _ = runtime(Path(tmp), "AUTO")
    lua.execute("""
      locked_load_lines_for_tests({})
      locked_load_adaptive_lines_for_tests({"1\\tcdn.example.org\\t93.184.216.34\\t1\\ttls\\tshared\\t9\\t" ..
        "sha256:" .. string.rep("a", 64) .. "\\tsha256:" .. string.rep("b", 64) .. "\\t123:456\\t10000"}, 1000, "123:456")
      local desync = {profile="1", hostname="cdn.example.org", arg={proto="tls"},
        dis={destination="93.184.216.34", ip={}, tcp={th_dport=443}}, track={lua_state={}}, plan={}}
      for i=1,10 do desync.plan[i] = {arg={strategy=i}} end
      circular_locked({}, desync)
      test_auto_shared_applied = desync.track.lua_state.adaptive_rule_strategy
      test_auto_shared_selected = desync.track.lua_state.adaptive_observe_context.selected_strategy
      test_auto_shared_low_conf = desync.track.lua_state.adaptive_observe_context.adaptive_rule_applied
    """)
    assert lua.globals().test_auto_shared_applied == 9 and lua.globals().test_auto_shared_selected == 9 \
        and lua.globals().test_auto_shared_low_conf is True, \
        "router AUTO without browser pairing must apply a browser-confirmed default-scope baseline"

with tempfile.TemporaryDirectory(prefix="zator-quic-health-") as tmp:
    lua, _, _ = runtime(Path(tmp), "AGENT_BETA")
    lua.execute("""
      bitand = function(a, b) return (a % (b * 2)) >= b and b or 0 end
      TH_SYN, TH_ACK = 2, 16
      local state = {lua_state={}}
      local function qinitial(port)
        locked_quic_health_observe_for_tests({outgoing=true, l7payload="quic_initial",
          dis={destination="94.0.1.5", udp={th_dport=443, th_sport=port}}, track=state},
          "rr1.googlevideo.com", "5", "mark:4")
      end
      qinitial(49152); qinitial(49152)
      locked_quic_health_observe_for_tests({outgoing=false,
        dis={udp={th_sport=443}}, track=state}, "rr1.googlevideo.com", "5", "mark:4")
      local fallback_state = {lua_state={}}
      locked_quic_health_observe_for_tests({outgoing=true, l7payload="quic_initial",
        dis={destination="94.0.1.5", udp={th_dport=443, th_sport=49153}}, track=fallback_state},
        "rr1.googlevideo.com", "5", "mark:4")
      locked_quic_health_observe_for_tests({outgoing=true,
        dis={destination="94.0.1.5", tcp={th_dport=443, th_flags=2}}, track={lua_state={}}},
        "rr1.googlevideo.com", "1", "mark:4")
    """)
    health_rows = [row.split("\t") for row in (Path(tmp) / "quic-health.tsv").read_text().splitlines() if row]
    assert len(health_rows) == 2 and health_rows[0][4] == "49152" and health_rows[0][6:10] == ["2", "1", "1", "0"] \
        and health_rows[1][4] == "49153" and health_rows[1][9] == "1", \
        f"QUIC monitor should count per-connection Initial/retry/response/fallback: {health_rows!r}"

    lua.execute("""
      for i=1,70 do
        test_now = test_now + 2
        locked_quic_health_observe_for_tests({outgoing=true, l7payload="quic_initial",
          dis={destination="94.0.2."..i, udp={th_dport=443, th_sport=50000+i}}, track={lua_state={}}},
          "v"..i..".youtube.com", "5", "mark:4")
      end
    """)
    health_rows = [row for row in (Path(tmp) / "quic-health.tsv").read_text().splitlines() if row]
    assert len(health_rows) == 64 and "v70.youtube.com" in health_rows[-1] and "rr1.googlevideo.com" not in "\n".join(health_rows), \
        "QUIC health monitor must keep a bounded 64-target ring"

print("adaptive observation smoke ok")
