#!/usr/bin/env python3
"""Production Lua parser and exact-key lookup for browser trials."""
import json
from pathlib import Path
import tempfile

from lupa import LuaRuntime

repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="zator-browser-trial-") as temp:
    root = Path(temp)
    state = root / "extra_strats/cache/adaptive"
    state.mkdir(parents=True)
    (state / "mode").write_text("AGENT_BETA\n")
    (state / "apply-default-scope").write_text("1\n")
    flow_dir = root / "browser-flows"
    flow_dir.mkdir()

    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().fake_getenv = lambda key: {
        "ZATOR_ROOT": str(root),
        "Z2R_ADAPTIVE_BROWSER_TRIALS_FILE": str(root / "trials.tsv"),
        "Z2R_ADAPTIVE_BROWSER_FLOW_DIR": str(flow_dir),
        "Z2R_ADAPTIVE_RULES_FILE": str(root / "rules.tsv"),
    }.get(key)
    lua.execute("os.getenv = fake_getenv")
    lua.globals().TH_SYN = 2
    lua.globals().TH_ACK = 16
    lua.globals().bitand = lambda left, right: int(left) & int(right)
    lua.globals().dis_ipdst = lambda packet: packet["dst"]
    lua.globals().ntop = lambda address: address
    lua.execute("local py_bitand, py_dis_ipdst, py_ntop = bitand, dis_ipdst, ntop; bitand=function(a,b) return py_bitand(a,b) end; dis_ipdst=function(d) return py_dis_ipdst(d) end; ntop=function(ip) return py_ntop(ip) end")
    lua.execute(f"dofile({json.dumps(str(repo / 'orchestra/locked.lua'))})")
    lua.execute("os.time = function() return 1000 end")
    lua.execute(r'''
local now = 1000
assert(type(bitand) == "function" and type(TH_SYN) == "number" and type(TH_ACK) == "number",
  "test TCP helpers missing: " .. type(bitand) .. "/" .. type(TH_SYN) .. "/" .. type(TH_ACK))
local id = string.rep("a", 32)
local client = string.rep("b", 32)
local fingerprint = "sha256:" .. string.rep("c", 64)
local function trial(ip, scope, proto, profile, strategy, expires)
  return table.concat({"1", id, "1", client, "192.168.1.42", scope,
    "cdn.example.org", ip, tostring(profile), proto, tostring(strategy), fingerprint, "990", tostring(expires)}, "\t")
end
local valid = trial("8.8.8.8", "mark:7", "tls", 1, 2, 1045)
locked_load_browser_trials_for_tests({valid}, now)
local found = locked_browser_trial_for_tuple("cdn.example.org", "8.8.8.8", 1, "tls", "mark:7", now)
assert(found and found.id == id and found.generation == 1 and found.strategy == 2, "exact trial not returned")
local track = {}
local syn = {outgoing=true, track=track, dis={dst="8.8.8.8", tcp={th_dport=443, th_flags=2}}}
local captured, capture_reason = locked_browser_capture_syn_for_tests(syn, "1", "mark:7")
assert(captured, "SYN capture refused: " .. tostring(capture_reason))
assert(track.lua_state and track.lua_state.adaptive_browser_syn and track.lua_state.adaptive_browser_syn.ip == "8.8.8.8", "new TCP SYN was not captured")
local trial_obj = locked_browser_trial_for_tuple("cdn.example.org", "8.8.8.8", 1, "tls", "mark:7", now)
assert(locked_browser_record_flow_for_tests({track=track}, trial_obj, "cdn.example.org", "8.8.8.8", "1", "tls", "mark:7", 2),
  "matching post-trial SYN did not create production flow evidence")
local flow_file = assert(io.open(fake_getenv("Z2R_ADAPTIVE_BROWSER_FLOW_DIR") .. "/" .. id .. ".1.tsv", "r"))
local flow_line = flow_file:read("*l")
flow_file:close()
assert(flow_line and flow_line:match("^1\t" .. id .. "\t1\t" .. client .. "\tmark:7\tcdn%.example%.org\t8%.8%.8%.8\t1\ttls\t2\t" .. fingerprint .. "\t1000\t1000$"),
  "flow proof fields do not bind the new SYN and selected strategy")
local no_syn = {track={}}
assert(not locked_browser_record_flow_for_tests(no_syn, trial_obj, "cdn.example.org", "8.8.8.8", "1", "tls", "mark:7", 2),
  "strategy selection without a SYN was accepted")
assert(locked_browser_trial_for_tuple("cdn.example.org", "8.8.4.4", 1, "tls", "mark:7", now) == nil, "destination was not exact")
locked_load_browser_trials_for_tests({valid:gsub("192%.168%.1%.42", "8.8.8.8")}, now)
assert(locked_browser_trial_for_tuple("cdn.example.org", "8.8.8.8", 1, "tls", "mark:7", now) == nil, "public client IP accepted")
locked_load_browser_trials_for_tests({valid}, now)
assert(locked_browser_trial_for_tuple("cdn.example.org", "8.8.8.8", 2, "tls", "mark:7", now) == nil, "profile was not exact")
assert(locked_browser_trial_for_tuple("cdn.example.org", "8.8.8.8", 1, "tls", "mark:8", now) == nil, "scope was not exact")
locked_load_browser_trials_for_tests({trial("203.0.113.10", "mark:7", "tls", 1, 2, 1045)}, now)
assert(locked_browser_trial_for_tuple("cdn.example.org", "203.0.113.10", 1, "tls", "mark:7", now) == nil, "reserved IP accepted")
local conflict = valid:gsub("\t2\t", "\t3\t", 1)
assert(conflict ~= valid, "conflicting candidate fixture did not change strategy")
locked_load_browser_trials_for_tests({valid, conflict}, now)
assert(locked_browser_trial_count_for_tests() == 0, "conflicting trial rows were not removed")
local duplicate_result = locked_browser_trial_for_tuple("cdn.example.org", "8.8.8.8", 1, "tls", "mark:7", now)
assert(duplicate_result == nil, "conflicting duplicate accepted: " .. tostring(duplicate_result and duplicate_result.strategy))
locked_load_browser_trials_for_tests({valid}, 1045)
assert(locked_browser_trial_for_tuple("cdn.example.org", "8.8.8.8", 1, "tls", "mark:7", 1045) == nil, "expired trial accepted")
local default_trial = trial("8.8.8.8", "default", "tls", 1, 2, 1045)
locked_load_browser_trials_for_tests({default_trial}, now)
assert(locked_browser_trial_for_tuple("cdn.example.org", "8.8.8.8", 1, "tls", "default", now), "explicitly consented default trial rejected")
''')

    off_root = root / "off"
    off_state = off_root / "extra_strats/cache/adaptive"
    off_state.mkdir(parents=True)
    (off_state / "mode").write_text("OFF\n")
    lua_off = LuaRuntime(unpack_returned_tuples=True)
    lua_off.globals().fake_getenv = lambda key: {
        "ZATOR_ROOT": str(off_root),
        "Z2R_ADAPTIVE_BROWSER_TRIALS_FILE": str(root / "trials.tsv"),
  "Z2R_ADAPTIVE_RULES_FILE": str(root / "rules.tsv"),
    }.get(key)
    lua_off.execute("os.getenv = fake_getenv")
    lua_off.execute(f"dofile({json.dumps(str(repo / 'orchestra/locked.lua'))})")
    lua_off.execute(r'''
local row = table.concat({"1", string.rep("a", 32), "1", string.rep("b", 32), "192.168.1.42", "mark:7",
  "cdn.example.org", "8.8.8.8", "1", "tls", "2", "-", "990", "1045"}, "\t")
locked_load_browser_trials_for_tests({row}, 1000)
assert(locked_browser_trial_for_tuple("cdn.example.org", "8.8.8.8", 1, "tls", "mark:7", 1000) == nil,
  "browser trial remained active while adaptive mode was OFF")
''')

print("adaptive browser trial Lua smoke: PASS")
