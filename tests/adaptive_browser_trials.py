#!/usr/bin/env python3
"""Production Lua parser and exact-key lookup for browser trials."""
import json
from pathlib import Path
import tempfile

from lupa import LuaRuntime

repo = Path(__file__).resolve().parents[1]
lua_source = (repo / "orchestra/locked.lua").read_text(encoding="utf-8")
quic_observation = lua_source.index('adaptive_observe_seen(host, dst_ip, base_profile, "quic", scope, desync.track)')
assert quic_observation > lua_source.index('if hostlist_has_host(desync.arg and desync.arg.exclude_hostlist, gate_host) then')
assert quic_observation > lua_source.index('if include_substrings and not substring_hostlist_matches_desync(desync, include_substrings, gate_host) then')
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
assert(flow_line and flow_line:match("^1\t" .. id .. "\t1\t" .. client .. "\tmark:7\tcdn%.example%.org\t8%.8%.8%.8\t1\ttls\t2\t" .. fingerprint .. "\t1000\t1000\tnot_applicable\tnot_applicable$"),
  "flow proof fields do not bind the new SYN and selected strategy")
local conflict_track = {lua_state={adaptive_browser_syn={ip="8.8.8.8",profile="1",proto="tcp",scope="mark:7",seen=1000}}}
for i = 1, 100 do
  assert(not locked_browser_record_flow_for_tests({track=conflict_track}, trial_obj, "cdn.example.org", "8.8.8.8", "1", "tls", "mark:7", 2),
    "a second flow was accepted for a single attempt")
end
flow_file = assert(io.open(fake_getenv("Z2R_ADAPTIVE_BROWSER_FLOW_DIR") .. "/" .. id .. ".1.tsv", "r"))
local ambiguous_flow = flow_file:read("*a"); flow_file:close()
assert(ambiguous_flow == "AMBIGUOUS\n", "repeated competing TCP flows must keep a single bounded ambiguity marker")
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

local video_host = "rr1---sn-a.googlevideo.com"
local video_trial = table.concat({"1", id, "3", client, "192.168.1.42", "mark:7", video_host,
  "8.8.8.8", "2", "googlevideo-tcp", "4", fingerprint, "990", "1045"}, "\t")
locked_load_browser_trials_for_tests({video_trial}, now)
local video_match = locked_browser_trial_for_tuple(video_host, "8.8.8.8", 2, "googlevideo-tcp", "mark:7", now)
local standard_video_trial = video_trial:gsub("\t1045$", "\t1180")
locked_load_browser_trials_for_tests({standard_video_trial}, now)
assert(locked_browser_trial_for_tuple(video_host, "8.8.8.8", 2, "googlevideo-tcp", "mark:7", now),
  "180-second Googlevideo trial was rejected before its CDN retry window")
local ramp_video_trial = video_trial:gsub("\t1045$", "\t1300")
locked_load_browser_trials_for_tests({ramp_video_trial}, now)
assert(locked_browser_trial_for_tuple(video_host, "8.8.8.8", 2, "googlevideo-tcp", "mark:7", now),
  "300-second Ramp canary trial was rejected")
local overlong_video_trial = video_trial:gsub("\t1045$", "\t1301")
locked_load_browser_trials_for_tests({overlong_video_trial}, now)
assert(locked_browser_trial_for_tuple(video_host, "8.8.8.8", 2, "googlevideo-tcp", "mark:7", now) == nil,
  "trial beyond the 300-second maximum was accepted")
locked_load_browser_trials_for_tests({video_trial}, now)
local alternate_video = "rr2---sn-b.googlevideo.com"
local alternate_match = locked_browser_trial_for_tuple(alternate_video, "1.1.1.1", 2, "googlevideo-tcp", "mark:7", now)
assert(alternate_match and alternate_match.id == video_match.id and alternate_match.strategy == video_match.strategy,
  "Googlevideo retry on another CDN host/IP did not reuse the scoped trial")
assert(locked_browser_trial_for_tuple(alternate_video, "1.1.1.1", 2, "googlevideo-tcp", "mark:8", now) == nil,
  "Googlevideo family trial escaped its client scope")
local video_track = {lua_state={adaptive_browser_syn={ip="8.8.8.8",profile="2",proto="tcp",scope="mark:7",seen=1000},
  wssize_ramp_treatment="applied",wssize_ramp_late_ack_confirmed=true}}
assert(locked_browser_record_flow_for_tests({track=video_track}, video_match, video_host, "8.8.8.8", "2", "googlevideo-tcp", "mark:7", 4),
  "Googlevideo production flow did not record the Ramp treatment")
local alternate_track = {lua_state={adaptive_browser_syn={ip="1.1.1.1",profile="2",proto="tcp",scope="mark:7",seen=1000},
  wssize_ramp_treatment="bypassed"}}
assert(locked_browser_record_flow_for_tests({track=alternate_track}, alternate_match, alternate_video, "1.1.1.1", "2", "googlevideo-tcp", "mark:7", 4),
  "second Googlevideo CDN flow was treated as an ambiguous attempt")
local video_file = assert(io.open(fake_getenv("Z2R_ADAPTIVE_BROWSER_FLOW_DIR") .. "/" .. id .. ".3.tsv", "r"))
local video_line = video_file:read("*l"); video_file:close()
assert(video_line and video_line:match("\t1000\t1000\tapplied\tconfirmed$"), "Googlevideo Ramp treatment/ACK evidence was not serialized: " .. tostring(video_line))
local bypass_trial = {id=id,generation=4,client_id=client,created=990,expires=1045,host=video_host,ip="8.8.8.8",
  profile="2",proto="googlevideo-tcp",scope="mark:7",strategy=4,fingerprint=fingerprint}
local bypass_track = {lua_state={adaptive_browser_syn={ip="8.8.8.8",profile="2",proto="tcp",scope="mark:7",seen=1000},
  wssize_ramp_treatment="bypassed"}}
assert(locked_browser_record_flow_for_tests({track=bypass_track}, bypass_trial, video_host, "8.8.8.8", "2", "googlevideo-tcp", "mark:7", 4),
  "Googlevideo bypass flow was not recorded")
video_file = assert(io.open(fake_getenv("Z2R_ADAPTIVE_BROWSER_FLOW_DIR") .. "/" .. id .. ".4.tsv", "r"))
video_line = video_file:read("*l"); video_file:close()
assert(video_line and video_line:match("\tbypassed\tnot_applicable$"), "Googlevideo Ramp bypass was not serialized")

local qhost = "rr1---sn-a.googlevideo.com"
local qtrial = table.concat({"1", id, "2", client, "192.168.1.42", "mark:7", qhost,
  "8.8.8.8", "5", "quic", "2", fingerprint, "990", "1045"}, "\t")
locked_load_browser_trials_for_tests({qtrial}, now)
local qmatch = locked_browser_trial_for_tuple(qhost, "8.8.8.8", 5, "quic", "mark:7", now)
assert(qmatch and qmatch.proto == "quic" and qmatch.profile == "5", "exact profile-5 QUIC trial not returned")
local qtrack = {}
local qinitial = {outgoing=true, l7payload="quic_initial", hostname=qhost, track=qtrack,
  dis={dst="8.8.8.8", udp={th_dport=443}}}
local qcaptured, qreason = locked_browser_capture_quic_for_tests(qinitial, qhost, "5", "mark:7")
assert(qcaptured, "QUIC Initial capture refused: " .. tostring(qreason))
assert(locked_browser_record_flow_for_tests({track=qtrack}, qmatch, qhost, "8.8.8.8", "5", "quic", "mark:7", 2),
  "matching QUIC Initial did not create production flow evidence")
local qflow = assert(io.open(fake_getenv("Z2R_ADAPTIVE_BROWSER_FLOW_DIR") .. "/" .. id .. ".2.tsv", "r"))
local qline = qflow:read("*l")
qflow:close()
local qfields = {}
for field in (qline .. "\t"):gmatch("(.-)\t") do qfields[#qfields + 1] = field end
assert(qfields[1] == "1" and qfields[2] == id and qfields[3] == "2" and qfields[4] == client
  and qfields[5] == "mark:7" and qfields[6] == qhost and qfields[7] == "8.8.8.8"
  and qfields[8] == "5" and qfields[9] == "quic" and qfields[10] == "2" and qfields[11] == fingerprint,
  "QUIC flow proof did not bind host, profile, and selected strategy: " .. tostring(qline))
qtrack.lua_state.adaptive_browser_trial_id = id
qtrack.lua_state.adaptive_browser_trial_generation = 2
local qagain = {outgoing=true, l7payload="quic_initial", hostname=qhost, track=qtrack,
  dis={dst="8.8.8.8", udp={th_dport=443}}}
assert(not locked_browser_capture_quic_for_tests(qagain, qhost, "5", "mark:7"), "repeat QUIC Initial was treated as a new flow")
for i = 1, 100 do
  assert(not locked_browser_capture_quic_for_tests(qagain, qhost, "5", "mark:7"), "repeat QUIC Initial was treated as a new flow")
end
local qambiguous = assert(io.open(fake_getenv("Z2R_ADAPTIVE_BROWSER_FLOW_DIR") .. "/" .. id .. ".2.tsv", "r"))
local qcontents = qambiguous:read("*a")
qambiguous:close()
assert(qcontents == "AMBIGUOUS\n", "repeated QUIC Initial must invalidate its proof with one bounded marker")
local nonvideo = qtrial:gsub(qhost, "example.org")
locked_load_browser_trials_for_tests({nonvideo}, now)
assert(locked_browser_trial_for_tuple("example.org", "8.8.8.8", 5, "quic", "mark:7", now) == nil,
  "profile-5 QUIC trial accepted a non-YouTube host")
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
