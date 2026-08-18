-- Run from repository root: lua tests/provisional_tcp_success.lua
local G = _G

G.DLOG = function() end
G.standard_failure_detector = function() return false end
G.standard_success_detector = function() return false end
G.bitand = function(a, b)
    local result, bit = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then result = result + bit end
        a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
    end
    return result
end
local TH_RST = 0x04
G.TH_RST = TH_RST

-- config.default loads locked.lua before combined-detector.lua. Load the real
-- module and require the shared gate exports, so a local-only helper cannot
-- be concealed by this harness.
dofile("orchestra/locked.lua")
assert(type(G.desync_allow_nohost) == "function")
assert(type(G.desync_hostname) == "function")
assert(type(G.hostlist_has_host) == "function")
assert(type(G.substring_hostlist_matches_desync) == "function")
dofile("lua/combined-detector.lua")

local combined_failure_detector = assert(G.combined_failure_detector)
local combined_success_detector = assert(G.combined_success_detector)
local circular_quality = assert(G.circular_quality)

local tcp_crec = {}
local tcp = {
    outgoing = false,
    dis = { tcp = { th_flags = 0 }, payload = "x" },
    track = {},
    arg = { soft_success_in = 3, soft_success_bytes = 0 },
}

for i = 1, 3 do
    assert(not combined_failure_detector(tcp, tcp_crec))
    assert(combined_success_detector(tcp, tcp_crec) == (i == 3), "soft TCP success timing is wrong")
end
assert(tcp_crec.provisional_success, "soft TCP progress must be provisional")
assert(tcp_crec.nocheck == nil, "soft TCP progress must not disable later checks")

tcp.outgoing = true
for i = 1, 4 do
    assert(not combined_failure_detector(tcp, tcp_crec), "soft TCP success must suppress later stall heuristic")
end
G.standard_failure_detector = function() return true end
assert(combined_failure_detector(tcp, tcp_crec), "soft TCP success must not suppress a hard failure")
G.standard_failure_detector = function() return false end

-- A browser may emit further TLS/data frames after a successful HEAD/no-body
-- exchange. Once soft success has observed enough peer progress, the stall
-- heuristic must not override it, even when dcounter keeps growing.
local head_crec = {}
local head = {
    outgoing = false,
    dis = { tcp = { th_flags = 0 }, payload = "encrypted response" },
    track = { pos = { direct = { dcounter = 2 }, reverse = { dcounter = 6 } } },
    arg = { soft_success_in = 3, soft_success_bytes = 0 },
}
for i = 1, 3 do
    assert(not combined_failure_detector(head, head_crec))
    assert(combined_success_detector(head, head_crec) == (i == 3), "HEAD soft success timing is wrong")
end
head_crec.tcp_in_count = 6
head_crec.stall_base_in = 6
head_crec.stall_base_out = 2
assert(head_crec.tcp_in_count == 6, "HEAD regression must model substantial inbound progress")
assert(not combined_failure_detector(head, head_crec))
head.outgoing = true
for i = 3, 5 do
    head.track.pos.direct.dcounter = i
    assert(not combined_failure_detector(head, head_crec), "post-success traffic must not stall")
end

-- Conversely, real new outgoing data after peer progress remains a stall.
local partial_crec = {}
local partial = {
    outgoing = false,
    dis = { tcp = { th_flags = 0 }, payload = "partial response" },
    track = { pos = { direct = { dcounter = 0 }, reverse = { dcounter = 2 } } },
    arg = { stall_out = 3 },
}
for _ = 1, 2 do
    assert(not combined_failure_detector(partial, partial_crec))
end
assert(partial_crec.tcp_in_count == 2, "partial-response regression must stay below soft success")
partial.outgoing = true
for i = 1, 4 do
    partial.track.pos.direct.dcounter = i
    assert(combined_failure_detector(partial, partial_crec) == (i == 4), "data stall after partial response must remain detectable")
end

G.standard_success_detector = function() return true end
tcp.outgoing = false
assert(combined_success_detector(tcp, tcp_crec), "standard success must remain visible after soft TCP success")
assert(tcp_crec.validated_success, "standard success must promote TCP state to validated")

local http_crec = {}
local http = {
    outgoing = false,
    dis = { tcp = { th_flags = 0 }, payload = "HTTP/1.1 400 Bad Request\r\n\r\n" },
    track = {},
    arg = {},
}
assert(not combined_failure_detector(http, http_crec), "HTTP 400 must not rotate strategy")
assert(combined_success_detector(http, http_crec), "HTTP 400 must validate transport success")
assert(http_crec.validated_success, "HTTP 400 must set validated success")

local abort_crec = { tcp_in_count = 1 }
local abort = {
    outgoing = true,
    dis = { tcp = { th_flags = TH_RST } },
    track = {},
    arg = {},
}
assert(combined_failure_detector(abort, abort_crec), "early client RST after TCP progress must fail")
assert(not combined_failure_detector(abort, abort_crec), "client RST failure must be one-shot")
abort_crec = { tcp_in_count = 1, validated_success = true }
assert(not combined_failure_detector(abort, abort_crec), "validated connection client RST must stay benign")

local stun_crec = {}
local stun = {
    outgoing = false,
    dis = {
        udp = true,
        payload = string.char(0x01, 0x01, 0, 0, 0x21, 0x12, 0xA4, 0x42) .. string.rep("\0", 12),
    },
    arg = {},
}
assert(combined_success_detector(stun, stun_crec), "valid STUN response must succeed")
assert(stun_crec.nocheck, "valid STUN response must remain terminal")
assert(stun_crec.validated_success, "valid STUN response must be validated")
assert(stun_crec.provisional_success == nil, "validated UDP success must not be provisional")
assert(not combined_failure_detector(stun, stun_crec), "terminal STUN success must suppress later failure checks")

-- Minimal circular_quality harness: a provisional result may be recorded for
-- learning, but must not reset failure state or count as a locked success.
local reset_calls, lock_checks, result_calls, failure_counter_calls = 0, 0, 0, 0
local mock_locked = nil
local mock_failure = false
local mock_validated = false

local orchestrate_calls = 0
G.orchestrate = function() orchestrate_calls = orchestrate_calls + 1 end
G.automate_host_record = function(desync) return desync._hrec end
G.automate_conn_record = function(desync) return desync._crec end
G.standard_hostkey = function() return "test.example" end
G.slm_normalize_hostkey = function(host) return host end
G.slm_should_keep_full_hostname = function() return false end
G.get_grouped_hostname = nil
G.slm_get_locked = function() return mock_locked end
G.slm_is_blocked = function() return false end
G.slm_record_result = function() result_calls = result_calls + 1 end
G.slm_should_lock = function() lock_checks = lock_checks + 1 return false end
G.automate_failure_counter_reset = function() reset_calls = reset_calls + 1 end
G.automate_failure_counter = function() failure_counter_calls = failure_counter_calls + 1 return false end
G.plan_instance_pop = function() return nil end
G.test_provisional_failure = function() return mock_failure end
G.test_provisional_success = function(_, crec)
    crec.provisional_success = true
    if mock_validated then crec.validated_success = true end
    return true
end

local empty_ack = {
    outgoing = false,
    dis = { tcp = { th_flags = 0 }, payload = "" },
}
circular_quality(nil, empty_ack)
assert(orchestrate_calls == 0, "empty non-RST TCP packets must bypass orchestration")

-- Auto counterparts of fallback/substrings blocks must retain circular_locked
-- routing: they are not catch-all and route matching no-host traffic to key 3.
local cutoff_calls, routed_key = 0, nil
G.hostlist_has_host = function() return false end
G.substring_hostlist_matches_desync = function(_, path, host)
    return path == "route-list" and host == "route.example"
end
G.lua_cutoff = function() cutoff_calls = cutoff_calls + 1 end
local prior_get_locked = G.slm_get_locked
G.slm_get_locked = function(key)
    routed_key = key
    return nil
end
local route_only = {
    arg = { key = 8, allow_nohost = 1, route_key = 3, route_substrings = "route-list", failure_detector = "test_provisional_failure", success_detector = "test_provisional_success" },
    plan = { { arg = { strategy = 1 } } },
    hostname = "Route.Example.",
    _crec = {},
}
circular_quality(nil, route_only)
assert(route_only.arg.key == "3" and routed_key == "3", "allow_nohost route must use route_key")
local include_only = {
    arg = { key = 3, allow_nohost = 1, include_substrings = "include-list", failure_detector = "test_provisional_failure", success_detector = "test_provisional_success" },
    plan = { { arg = { strategy = 1 } } },
    hostname = "other.example",
    _crec = {},
}
circular_quality(nil, include_only)
assert(cutoff_calls == 1, "include_substrings auto counterpart must cut off non-matching host")
G.slm_get_locked = prior_get_locked
result_calls, reset_calls, lock_checks, failure_counter_calls = 0, 0, 0, 0

local circular = {
    arg = { key = "test", failure_detector = "test_provisional_failure", success_detector = "test_provisional_success", unlock_fails = 4 },
    plan = { { arg = { strategy = 1 } } },
    track = { hostname = "test.example" },
    _hrec = {},
    _crec = {},
}
circular_quality(nil, circular)
assert(result_calls == 1, "provisional success must remain in learning statistics")
assert(reset_calls == 0 and lock_checks == 0, "provisional success must not reset or auto-lock")

mock_failure = true
circular_quality(nil, circular)
assert(failure_counter_calls == 1, "late nonlocked failure must reach the failure counter once")
mock_failure = false

result_calls, reset_calls, lock_checks, failure_counter_calls = 0, 0, 0, 0
circular._hrec = {}
circular._crec = {}
circular_quality(nil, circular)
mock_validated = true
circular_quality(nil, circular)
assert(result_calls == 1, "validated promotion must not add a second quality test")
assert(reset_calls == 1 and lock_checks == 1, "validated promotion must reset and auto-lock once")

mock_locked = 1
mock_validated = false
result_calls = 0
circular._hrec = { locked_fail_count = 2 }
circular._crec = {}
circular_quality(nil, circular)
assert(result_calls == 0 and circular._hrec.locked_fail_count == 2, "provisional success must not count as locked success")

mock_failure = true
circular_quality(nil, circular)
assert(result_calls == 1 and circular._hrec.locked_fail_count == 3, "late failure must advance locked auto-unlock streak")

-- Validator queue: use an in-memory /tmp and a fake background launcher.
local files, now = {}, 100
local real_io, real_os = G.io, G.os
G.io = {
    open = function(path, mode)
        if mode == "w" then
            local chunks = {}
            return { write = function(_, ...) for i = 1, select("#", ...) do chunks[#chunks + 1] = select(i, ...) end end,
                     close = function() files[path] = table.concat(chunks) end }
        end
        if mode == "r" and files[path] then
            return { read = function() return files[path]:match("^([^\n]*)") end, close = function() end }
        end
    end,
}
G.os = { time = function() return now end, date = real_os.date,
         rename = function(a, b) files[b], files[a] = files[a], nil return true end,
         remove = function(path) files[path] = nil end,
         execute = function() error("validator must not call os.execute") end }

local commits, resets, blocks, blocked, mock_candidate = 0, 0, 0, {}, nil
G.slm_should_lock = function(askey, _, arg) assert(askey == 3 and arg.validator) return mock_candidate ~= nil, mock_candidate end
G.slm_commit_auto_lock = function(askey, _, strategy) assert(askey == 3); commits = commits + 1; mock_locked = strategy; return true end
G.slm_reset = function(askey) assert(askey == 3); resets = resets + 1; mock_locked = nil end
G.slm_preload_blocked = function(askey, _, strategies) assert(askey == 3); blocks = blocks + 1; blocked[strategies[1]] = true end
G.slm_is_blocked = function(askey, _, strategy) assert(askey == 3); return blocked[strategy] or false end

mock_locked, mock_failure, mock_validated = nil, false, false
circular.arg.key = 3
circular.arg.validator = "/opt/zator/lua/strategy-validator.sh"
circular.plan = { { arg = { strategy = 1 } }, { arg = { strategy = 2 } } }
circular._hrec, circular._crec = {}, {}
circular_quality(nil, circular)
assert(circular._hrec.validator_hostname == "test.example", "observed hostname must be retained in host record")
circular.track.hostname = nil
circular._crec = {}
mock_candidate = 1
circular_quality(nil, circular)
local pending = assert(circular._hrec.validator_pending, "provisional candidate must request validation")
assert(pending.askey == "3" and pending.slm_askey == 3, "numeric profile key must be serialized without changing SLM key")
assert(commits == 0 and files["/tmp/z2r-strategy-validation/request." .. pending.id], "candidate must queue without os.execute")
files["/tmp/z2r-strategy-validation/result." .. pending.id] = pending.id .. "\tOK\t" .. pending.askey .. "\t" .. pending.hostkey .. "\t" .. pending.strategy .. "\n"
circular_quality(nil, circular)
assert(commits == 1, "validator OK must commit exactly once")
circular_quality(nil, circular)
assert(commits == 1, "committed validator result must not repeat")

mock_locked, commits, resets, blocks, blocked = nil, 0, 0, 0, {}
circular.track.hostname = "test.example"
circular._hrec, circular._crec = {}, {}
circular_quality(nil, circular)
pending = assert(circular._hrec.validator_pending, "FAIL case must enqueue candidate")
files["/tmp/z2r-strategy-validation/result." .. pending.id] = pending.id .. "\tFAIL\t" .. pending.askey .. "\t" .. pending.hostkey .. "\t" .. pending.strategy .. "\n"
circular_quality(nil, circular)
assert(commits == 0 and resets == 1 and blocks == 1 and circular._hrec.nstrategy == 2, "validator FAIL must reset, block, and rotate")

mock_locked, blocked, now = nil, {}, 100
circular.track.hostname = "test.example"
circular._hrec, circular._crec = {}, {}
circular_quality(nil, circular)
pending = assert(circular._hrec.validator_pending, "timeout case must enqueue candidate")
now = 131
circular_quality(nil, circular)
assert(not circular._hrec.validator_pending and not files["/tmp/z2r-strategy-validation/request." .. pending.id], "validator timeout must clear stale request")
G.io, G.os = real_io, real_os

print("provisional TCP success regression ok")
