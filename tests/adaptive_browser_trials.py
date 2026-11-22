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

    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().fake_getenv = lambda key: {
        "ZATOR_ROOT": str(root),
        "Z2R_ADAPTIVE_BROWSER_TRIALS_FILE": str(root / "trials.tsv"),
        "Z2R_ADAPTIVE_RULES_FILE": str(root / "rules.tsv"),
    }.get(key)
    lua.execute("os.getenv = fake_getenv")
    lua.execute(f"dofile({json.dumps(str(repo / 'orchestra/locked.lua'))})")
    lua.execute(r'''
local now = 1000
local id = string.rep("a", 32)
local client = string.rep("b", 32)
local function trial(ip, scope, proto, profile, strategy, expires)
  return table.concat({"1", id, "1", client, "192.168.1.42", scope,
    "cdn.example.org", ip, tostring(profile), proto, tostring(strategy), "-", "990", tostring(expires)}, "\t")
end
local valid = trial("8.8.8.8", "mark:7", "tls", 1, 2, 1045)
locked_load_browser_trials_for_tests({valid}, now)
local found = locked_browser_trial_for_tuple("cdn.example.org", "8.8.8.8", 1, "tls", "mark:7", now)
assert(found and found.id == id and found.generation == 1 and found.strategy == 2, "exact trial not returned")
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
