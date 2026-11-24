TH_SYN, TH_ACK = 0x02, 0x10

function bitand(a, b)
  local out, bit = 0, 1
  while a > 0 and b > 0 do
    if a % 2 == 1 and b % 2 == 1 then out = out + bit end
    a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
  end
  return out
end

function dis_ipdst(dis) return dis.ip end
function ntop(ip) return ip end

local function qhm_initial(host, ip, track)
  local desync = {outgoing=true, l7payload="quic_initial", dis={udp={th_sport=51234, th_dport=443}, ip=ip}, track=track}
  locked_quic_health_observe_for_tests(desync, host, 5, "default")
end

local function qhm_response(host, ip, track)
  local desync = {outgoing=false, dis={udp={th_sport=443, th_dport=51234}}, track=track}
  locked_quic_health_observe_for_tests(desync, host, 5, "default")
end

local qhm_path = assert(os.getenv("Z2R_ADAPTIVE_QUIC_HEALTH_FILE"))
local track = {lua_state={}}
local host, ip = "r1---sn-a1.googlevideo.com", "142.250.72.14"
qhm_initial(host, ip, track)
qhm_initial(host, ip, track)
qhm_response(host, ip, track)
locked_quic_health_observe_for_tests({outgoing=true,
  dis={tcp={th_dport=443, th_flags=TH_SYN}, ip=ip}, track=track}, host, 5, "default")

local f = assert(io.open(qhm_path, "r"))
local first = f:read("*l")
f:close()
local fields = {}
for field in (first .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = field end
assert(#fields == 11 and fields[1] == "2" and fields[2] == host and fields[3] == ip
  and fields[5] == "51234" and fields[7] == "2" and fields[8] == "1"
  and fields[9] == "1" and fields[10] == "0",
  "QHM did not record Initial/retry/response/TCP fallback")

local fallback_track = {lua_state={}}
qhm_initial(host, ip, fallback_track)
locked_quic_health_observe_for_tests({outgoing=true,
  dis={tcp={th_dport=443, th_flags=TH_SYN}, ip=ip}, track=fallback_track}, host, 5, "default")
f = assert(io.open(qhm_path, "r"))
f:read("*l")
local fallback_line = f:read("*l")
f:close()
local fallback_fields = {}
for field in (fallback_line .. "\t"):gmatch("(.-)\t") do fallback_fields[#fallback_fields + 1] = field end
assert(#fallback_fields == 11 and fallback_fields[2] == host and fallback_fields[7] == "1"
  and fallback_fields[9] == "0" and fallback_fields[10] == "1",
  "QHM did not mark a separate unanswered QUIC connection with possible TCP fallback")

for i=1,70 do
  local h, t = string.format("h%d.googlevideo.com", i), {lua_state={}}
  qhm_initial(h, ip, t)
  if i == 70 then qhm_response(h, ip, t) end
end
f = assert(io.open(qhm_path, "r"))
local count = 0
for _ in f:lines() do count = count + 1 end
f:close()
assert(count == 64, "QHM row cap is not 64: " .. count)

local function router_failure(hostname, kind)
  local desync = {outgoing=true, l7payload="tls_client_hello", arg={proto="tls"},
    dis={tcp={th_dport=443}, ip="93.184.216.34"}, track={lua_state={}}}
  z2r_adaptive_observe_connection(desync, 1, hostname, "default", true)
  local context = assert(desync.track.lua_state.adaptive_observe_context, "router AUTO missed the tuple")
  context.selected_strategy, context.strategy_count = 1, 3
  z2r_adaptive_suspected_failure(desync, {}, kind)
end

router_failure("router-auto.example.org", "transport")
router_failure("router-auto.example.org", "transport")
router_failure("app-error.example.org", "application")
router_failure("app-error.example.org", "application")

local events_path = assert(os.getenv("Z2R_ADAPTIVE_EVENTS_FILE"))
f = assert(io.open(events_path, "r"))
local saw_trial, saw_ignored = false, false
for line in f:lines() do
  local _, status = line:match("^([^\t]+)\t([^\t]+)")
  if line:find("router-auto.example.org", 1, true) then saw_trial = status == "router_trial_2" end
  if line:find("app-error.example.org", 1, true) then saw_ignored = status == "seen" end
end
f:close()
assert(saw_trial, "two transport failures did not advance router AUTO to candidate 2")
assert(saw_ignored, "application failures incorrectly advanced router AUTO")

local gv_host, gv_ip = "rr1---sn-a1.googlevideo.com", "142.250.72.14"
local now, trial_id = os.time(), string.rep("a", 32)
local trial_row = table.concat({"1", trial_id, "1", string.rep("b", 32), "192.168.1.42", "mark:7",
  gv_host, gv_ip, "2", "googlevideo-tcp", "2", "sha256:" .. string.rep("c", 64),
  tostring(now), tostring(now + 600)}, "\t")
locked_load_browser_trials_for_tests({trial_row}, now)
assert(locked_browser_trial_for_tuple(gv_host, gv_ip, 2, "googlevideo-tcp", "mark:7", now),
  "OpenWrt LuaJIT rejected the ten-minute Googlevideo browser retry window")
local function googlevideo_failure()
  local d = {outgoing=true, l7payload="tls_client_hello", arg={proto="tls"},
    dis={tcp={th_dport=443}, ip=gv_ip}, track={lua_state={}}}
  z2r_adaptive_observe_connection(d, 2, gv_host, "mark:7", true)
  local context = assert(d.track.lua_state.adaptive_observe_context, "Googlevideo router AUTO missed the active trial tuple")
  context.selected_strategy, context.strategy_count = 1, 10
  z2r_adaptive_suspected_failure(d, {}, "transport")
end
googlevideo_failure(); googlevideo_failure()
local function googlevideo_status()
  local file = assert(io.open(events_path, "r"))
  local status
  for line in file:lines() do
    local _, row_status, row_host = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)")
    if row_host == gv_host then status = row_status end
  end
  file:close()
  return status
end
assert(googlevideo_status() == "seen", "passive AUTO raced the active browser trial to another strategy")
locked_load_browser_trials_for_tests({}, now)
googlevideo_failure(); googlevideo_failure()
assert(googlevideo_status() == "router_trial_2", "passive AUTO did not resume after the browser trial ended")
print("OpenWrt embedded LuaJIT smoke: router AUTO without browser, browser-trial arbitration/600s parsing, application exclusion, QHM counters and 64-row cap PASS")
