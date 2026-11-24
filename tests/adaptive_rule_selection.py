#!/usr/bin/env python3
"""Exercise the gated production selector and its priority/cache semantics."""
import json
from pathlib import Path
import tempfile
import time

from lupa import LuaRuntime

repo = Path(__file__).resolve().parents[1]
FP = "sha256:" + "c" * 64
CAT = "sha256:" + "d" * 64
STAMP = "1:2|3:4|5:6|7:8|9:10|11:12|13:14|15:16|17:18|19:20|21:22|23:24|25:26|27:28|29:30"


def lua_table(values):
    return "{" + ",".join(json.dumps(value) for value in values) + "}"


def run_selection(enabled, lock_rows=(), strategy=7, ip="93.184.216.34", repeat=False,
                  rule_stamp=STAMP, process_stamp=STAMP, mode=None, allow_default_scope=False,
                  hostname="cdn.example.org", profile="1", rule_proto="tls", expiry_offset=3600):
    temporary = tempfile.TemporaryDirectory(prefix="adaptive-rule-mode-")
    root = Path(temporary.name)
    mode_path = root / "extra_strats/cache/adaptive/mode"
    mode_path.parent.mkdir(parents=True)
    mode_path.write_text((mode or ("AUTO" if enabled else "TEST_ONLY")) + "\n")
    if allow_default_scope:
        (mode_path.parent / "apply-default-scope").write_text("1\n")
    lua = LuaRuntime(unpack_returned_tuples=True)
    env = {
        "Z2R_ADAPTIVE_RULES_FILE": "/nonexistent/adaptive-rules.tsv",
        "Z2R_ADAPTIVE_RULES_APPLY": "1" if enabled else "0",
        "ZATOR_ROOT": str(root),
    }
    lua.globals().fake_getenv = lambda key: env.get(key)
    lua.execute("os.getenv = fake_getenv")
    lua.execute(f"dofile({json.dumps(str(repo / 'orchestra/locked.lua'))})")
    locks = lua_table(lock_rows)
    expected_lookup = strategy if rule_stamp == process_stamp and expiry_offset > 0 else "nil"
    lua.execute(f'''
      VERDICT_PASS = 0
      DLOG = function() end
      DLOG_ERR = function() end
      execution_plan_cancel = function() end
      plan_clear = function(desync) desync.plan = {{}} end
      dis_ipdst = function(dis) return dis.destination end
      ntop = function(address) return address end
      orchestrate = function() end
      local record = {{}}
      automate_host_record = function() return record end
      plan_instance_pop = function(desync) return table.remove(desync.plan, 1) end
      plan_instance_execute = function(desync, verdict, instance) return verdict end
      local executed = {{}}
      blob_override_execute = function(desync, verdict, instance)
        executed[#executed + 1] = tonumber(instance.arg.strategy)
        return verdict
      end
      locked_load_lines_for_tests({locks})
      local function rule_line(number)
        return table.concat({{"1", {json.dumps(hostname)}, "93.184.216.34", {json.dumps(profile)}, {json.dumps(rule_proto)}, "default",
          tostring(number), {json.dumps(FP)}, {json.dumps(CAT)}, {json.dumps(rule_stamp)}, tostring(os.time() + {expiry_offset})}}, string.char(9))
      end
      locked_load_adaptive_lines_for_tests({{rule_line({strategy})}}, os.time(), {json.dumps(process_stamp)})
      assert(locked_adaptive_strategy_for_tuple({json.dumps(hostname)}, "93.184.216.34", {json.dumps(profile)}, {json.dumps(rule_proto)}, "default") == {expected_lookup}, "runtime stamp validation failed")
      local state = {{lua_state = {{}}}}
      local function invoke(destination, port, flow_state)
        local plan = {{}}
        for i = 1, 8 do plan[i] = {{arg = {{strategy = i}}}} end
        local desync = {{
          profile = {json.dumps(profile)}, hostname = {json.dumps(hostname)}, dis = {{destination = destination, ip = {{}}, tcp = {{th_dport = port or 443}}}},
          track = flow_state or {{lua_state = {{}}}}, arg = {{}}, plan = plan
        }}
        assert(circular_locked({{}}, desync) == VERDICT_PASS)
        local selected = executed[1]
        executed = {{}}
        return selected
      end
      selected_first = invoke({json.dumps(ip)}, nil, {'state' if repeat else 'nil'})
      {'local_cached = nil' if not repeat else f'locked_load_adaptive_lines_for_tests({{rule_line({strategy + 1})}}, os.time(), {json.dumps(process_stamp)}); local_cached = invoke({json.dumps(ip)}, nil, state);'}
      selected_cached = local_cached
      selected_other_ip = invoke("93.184.216.35")
      selected_other_port = invoke("93.184.216.34", 8443)
      state.lua_state.adaptive_quality_flow = {{host={json.dumps(hostname)}, profile={json.dumps(profile)}, scope="default",
        strategy={strategy}, source="browser_confirmed", ip={json.dumps(ip)}, proto={json.dumps(rule_proto)}}}
      local inbound = {{outgoing=false, profile={json.dumps(profile)}, hostname={json.dumps(hostname)}, arg={{proto="tls"}},
        dis={{ip={{}}, tcp={{th_sport=443}}}}, track=state}}
      inbound_selected, inbound_source, ignored_trial, inbound_ip = locked_adaptive_quality_selection(
        inbound, {json.dumps(hostname)}, {json.dumps(profile)}, "default", 1, {json.dumps(hostname)})
    ''')
    result = (lua.globals().selected_first, lua.globals().selected_cached,
              lua.globals().selected_other_ip, lua.globals().selected_other_port,
              lua.globals().inbound_selected, lua.globals().inbound_source, lua.globals().inbound_ip)
    temporary.cleanup()
    return result


enabled = run_selection(True)
assert enabled[0] == 7, f"exact adaptive rule not applied: {enabled}"
direct = run_selection(True, strategy=0)
assert direct[0] is None, f"verified DIRECT did not pass through without executing a numbered strategy: {direct}"
direct_manual = run_selection(True, ["cdn.example.org\ttls\t2"], strategy=0)
assert direct_manual[0] == 2, f"manual domain lock did not override adaptive DIRECT: {direct_manual}"
manual_domain = run_selection(True, ["cdn.example.org\ttls\t2"])
assert manual_domain[0] == 2, f"manual domain lock did not win: {manual_domain}"
manual_profile = run_selection(True, ["1\ttls\t3"])
assert manual_profile[0] == 3, f"manual profile lock did not win: {manual_profile}"
other_ip = run_selection(True, ip="93.184.216.35")
assert other_ip[0] == 7, f"same-scope strategy did not follow a DNS/IP change: {other_ip}"
other_port = run_selection(True)
assert other_port[3] == 1, f"exact TLS rule leaked to another destination port: {other_port}"
googlevideo_media = run_selection(True, strategy=7, hostname="rr1---sn-a5mekn6e.googlevideo.com", profile="2", rule_proto="googlevideo-tcp")
assert googlevideo_media[0] == 7, f"exact Googlevideo media rule was not applied to its TCP profile-2 flow: {googlevideo_media}"
assert googlevideo_media[4:] == (7, "browser_confirmed", "93.184.216.34"), \
    f"incoming packet did not reuse the outgoing flow's strategy/source/IP: {googlevideo_media}"

with tempfile.TemporaryDirectory(prefix="adaptive-googlevideo-family-") as tmp:
    root = Path(tmp)
    mode = root / "extra_strats/cache/adaptive/mode"
    mode.parent.mkdir(parents=True)
    mode.write_text("AUTO\n")
    lua = LuaRuntime(unpack_returned_tuples=True)
    env = {"Z2R_ADAPTIVE_RULES_FILE": "/nonexistent/adaptive-rules.tsv",
           "Z2R_ADAPTIVE_RULES_APPLY": "1", "ZATOR_ROOT": str(root)}
    lua.globals().fake_getenv = lambda key: env.get(key)
    lua.execute("os.getenv = fake_getenv")
    lua.execute(f"dofile({json.dumps(str(repo / 'orchestra/locked.lua'))})")
    lua.execute("""
      locked_load_lines_for_tests({})
      locked_load_adaptive_lines_for_tests({"1\\tgooglevideo.com\\t93.184.216.34\\t2\\tgooglevideo-tcp\\tshared\\t7\\t" ..
        "sha256:" .. string.rep("c", 64) .. "\\tsha256:" .. string.rep("d", 64) .. "\\t" ..
        "1:2|3:4|5:6|7:8|9:10|11:12|13:14|15:16|17:18|19:20|21:22|23:24|25:26|27:28|29:30\\t9999999999"},
        1000, "1:2|3:4|5:6|7:8|9:10|11:12|13:14|15:16|17:18|19:20|21:22|23:24|25:26|27:28|29:30")
    """)
    family_baseline = lua.eval('locked_adaptive_shared_strategy_for_tuple("rr3---sn-example.googlevideo.com", "93.184.216.35", "2", "googlevideo-tcp", 5000)')
    assert family_baseline[0] == 7, f"Googlevideo family baseline failed across CDN hosts: {family_baseline!r}"
disabled = run_selection(False)
assert disabled[0] == 1, f"disabled adaptive mode applied a rule: {disabled}"
test_only = run_selection(True, mode="TEST_ONLY")
assert test_only[0] == 1, f"TEST_ONLY applied an adaptive rule despite a stale env flag: {test_only}"
observe = run_selection(True, mode="OBSERVE")
assert observe[0] == 1, f"OBSERVE applied an adaptive rule: {observe}"
beta_default_blocked = run_selection(False, mode="AGENT_BETA")
assert beta_default_blocked[0] == 7, f"confirmed default-scope strategy was not shared without browser trial consent: {beta_default_blocked}"
beta_default_allowed = run_selection(False, mode="AGENT_BETA", allow_default_scope=True)
assert beta_default_allowed[0] == 7, f"explicit Beta LAN-scope consent did not apply the exact rule: {beta_default_allowed}"
stale = run_selection(True, process_stamp="99:98|97:96|95:94|93:92|91:90|89:88|87:86")
assert stale[0] == 1, f"rule from an old runtime catalog was applied: {stale}"
expired = run_selection(True, expiry_offset=-1)
assert expired[0] == 1, f"expired adaptive rule did not return to the installed profile fallback: {expired}"
expired_manual = run_selection(True, ["cdn.example.org\ttls\t3"], expiry_offset=-1)
assert expired_manual[0] == 3, f"manual domain fallback did not retain priority after adaptive expiry: {expired_manual}"
expired_profile = run_selection(True, ["1\ttls\t4"], expiry_offset=-1)
assert expired_profile[0] == 4, f"manual profile fallback did not retain priority after adaptive expiry: {expired_profile}"
stale_manual = run_selection(True, ["1\ttls\t4"], process_stamp="99:98|97:96|95:94|93:92|91:90|89:88|87:86")
assert stale_manual[0] == 4, f"manual profile fallback did not retain priority after catalog invalidation: {stale_manual}"
cached = run_selection(True, repeat=True)
assert cached[0] == 7 and cached[1] == 7, f"connection changed strategy mid-flow: {cached}"

with tempfile.TemporaryDirectory(prefix="adaptive-rule-renewal-") as tmp:
    root = Path(tmp)
    adaptive = root / "extra_strats/cache/adaptive"
    adaptive.mkdir(parents=True)
    (adaptive / "mode").write_text("AUTO\n")
    renewal_file = root / "rule-renewals.tsv"
    rules_file = root / "rules.tsv"
    lua = LuaRuntime(unpack_returned_tuples=True)
    env = {"ZATOR_ROOT": str(root), "Z2R_ADAPTIVE_RULE_RENEWALS_FILE": str(renewal_file),
           "Z2R_ADAPTIVE_RULES_FILE": str(rules_file)}
    lua.globals().fake_getenv = lambda key: env.get(key)
    lua.execute("os.getenv = fake_getenv")
    lua.execute(f"dofile({json.dumps(str(repo / 'orchestra/locked.lua'))})")
    lua.globals().renewal_stamp = STAMP
    lua.execute(f'''\n      local now = os.time()
      local line = table.concat({{"1", "cdn.example.org", "93.184.216.34", "1", "tls", "shared", "7",
        {json.dumps(FP)}, {json.dumps(CAT)}, renewal_stamp, tostring(now + 60)}}, string.char(9))
      locked_load_lines_for_tests({{}})
      locked_load_adaptive_lines_for_tests({{line}}, now, renewal_stamp)
      assert(z2r_adaptive_confirmed_rule_success({{host="cdn.example.org", ip="93.184.216.34", profile="1",
        proto="tls", scope="default", adaptive_source="browser_confirmed_shared"}}, 7),
        "confirmed browser success did not renew its rule")
    ''')
    rows = renewal_file.read_text().splitlines()
    assert len(rows) == 1 and int(rows[0].split("\t")[-1]) >= int(time.time()) - 2, rows
    rules_file.write_text("\t".join(["1", "cdn.example.org", "93.184.216.34", "1", "tls", "shared", "7",
                                      FP, CAT, STAMP, str(int(time.time()) - 1)] ) + "\n")
    renewed_lua = LuaRuntime(unpack_returned_tuples=True)
    renewed_lua.globals().fake_getenv = lambda key: env.get(key)
    renewed_lua.execute("os.getenv = fake_getenv")
    renewed_lua.execute(f"dofile({json.dumps(str(repo / 'orchestra/locked.lua'))})")
    renewed_lua.execute(f'''\n      locked_reload_adaptive_rules_for_tests({json.dumps(STAMP)})
      assert(locked_adaptive_shared_strategy_for_tuple("cdn.example.org", "93.184.216.34", "1", "tls") == 7,
        "recent confirmed-traffic renewal did not preserve the rule across reload")
    ''')

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(f'''\n  DLOG = function() end
  autostate = {{}}
  automate_host_record = function() return {{}} end
  desync_client_scope = function(d) return d.scope end
  host_or_ip = function(d) return d.track.hostname end
  local history = nil
  get_best_strategy_from_history = history
  dofile({json.dumps(str(repo / "lua/domain-grouping.lua"))})
  local function get(scope)
    return automate_host_record({{arg={{reqhost=true,key="2"}}, track={{hostname="rr1---sn-cdn.googlevideo.com"}}, scope=scope}})
  end
  local marked = get("mark:7"); marked.nstrategy = 3
  assert(get("mark:8").nstrategy == nil, "host state leaked across marks")
  assert(get("mark:7").nstrategy == 3, "same-mark host state did not persist")
  assert(get("default").nstrategy == nil, "marked host state leaked into default scope")
  assert(get_grouped_hostname("rr1---sn-cdn.googlevideo.com") == "rr1---sn-cdn.googlevideo.com",
    "Googlevideo CDN host was collapsed into the shared family record")
''')
print("adaptive Lua strategy selection smoke ok")
