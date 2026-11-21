#!/usr/bin/env python3
"""Exercise the gated production selector and its priority/cache semantics."""
import json
from pathlib import Path
import tempfile

from lupa import LuaRuntime

repo = Path(__file__).resolve().parents[1]
FP = "sha256:" + "c" * 64
CAT = "sha256:" + "d" * 64
STAMP = "1:2|3:4|5:6|7:8|9:10|11:12|13:14|15:16|17:18|19:20|21:22|23:24|25:26|27:28|29:30"


def lua_table(values):
    return "{" + ",".join(json.dumps(value) for value in values) + "}"


def run_selection(enabled, lock_rows=(), strategy=7, ip="93.184.216.34", repeat=False,
                  rule_stamp=STAMP, process_stamp=STAMP, mode=None):
    temporary = tempfile.TemporaryDirectory(prefix="adaptive-rule-mode-")
    root = Path(temporary.name)
    mode_path = root / "extra_strats/cache/adaptive/mode"
    mode_path.parent.mkdir(parents=True)
    mode_path.write_text((mode or ("AUTO" if enabled else "TEST_ONLY")) + "\n")
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
    expected_lookup = strategy if rule_stamp == process_stamp else "nil"
    lua.execute(f'''
      VERDICT_PASS = 0
      DLOG = function() end
      DLOG_ERR = function() end
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
        return table.concat({{"1", "cdn.example.org", "93.184.216.34", "1", "tls", "default",
          tostring(number), {json.dumps(FP)}, {json.dumps(CAT)}, {json.dumps(rule_stamp)}, tostring(os.time() + 3600)}}, string.char(9))
      end
      locked_load_adaptive_lines_for_tests({{rule_line({strategy})}}, os.time(), {json.dumps(process_stamp)})
      assert(locked_adaptive_strategy_for_tuple("cdn.example.org", "93.184.216.34", "1", "tls", "default") == {expected_lookup}, "runtime stamp validation failed")
      local state = {{lua_state = {{}}}}
      local function invoke(destination, port)
        local plan = {{}}
        for i = 1, 8 do plan[i] = {{arg = {{strategy = i}}}} end
        local desync = {{
          profile = "1", hostname = "cdn.example.org", dis = {{destination = destination, ip = {{}}, tcp = {{th_dport = port or 443}}}},
          track = state, arg = {{}}, plan = plan
        }}
        assert(circular_locked({{}}, desync) == VERDICT_PASS)
        local selected = executed[1]
        executed = {{}}
        return selected
      end
      selected_first = invoke({json.dumps(ip)})
      {'local_cached = nil' if not repeat else f'locked_load_adaptive_lines_for_tests({{rule_line({strategy + 1})}}, os.time(), {json.dumps(process_stamp)}); local_cached = invoke({json.dumps(ip)});'}
      selected_cached = local_cached
      selected_other_ip = invoke("93.184.216.35")
      selected_other_port = invoke("93.184.216.34", 8443)
    ''')
    result = (lua.globals().selected_first, lua.globals().selected_cached,
              lua.globals().selected_other_ip, lua.globals().selected_other_port)
    temporary.cleanup()
    return result


enabled = run_selection(True)
assert enabled[0] == 7, f"exact adaptive rule not applied: {enabled}"
manual_domain = run_selection(True, ["cdn.example.org\ttls\t2"])
assert manual_domain[0] == 2, f"manual domain lock did not win: {manual_domain}"
manual_profile = run_selection(True, ["1\ttls\t3"])
assert manual_profile[0] == 3, f"manual profile lock did not win: {manual_profile}"
other_ip = run_selection(True, ip="93.184.216.35")
assert other_ip[0] == 1, f"exact IP rule leaked to another destination: {other_ip}"
other_port = run_selection(True)
assert other_port[3] == 1, f"exact TLS rule leaked to another destination port: {other_port}"
disabled = run_selection(False)
assert disabled[0] == 1, f"disabled adaptive mode applied a rule: {disabled}"
test_only = run_selection(True, mode="TEST_ONLY")
assert test_only[0] == 1, f"TEST_ONLY applied an adaptive rule despite a stale env flag: {test_only}"
observe = run_selection(True, mode="OBSERVE")
assert observe[0] == 1, f"OBSERVE applied an adaptive rule: {observe}"
stale = run_selection(True, process_stamp="99:98|97:96|95:94|93:92|91:90|89:88|87:86")
assert stale[0] == 1, f"rule from an old runtime catalog was applied: {stale}"
cached = run_selection(True, repeat=True)
assert cached[0] == 7 and cached[1] == 7, f"connection changed strategy mid-flow: {cached}"
print("adaptive Lua strategy selection smoke ok")
