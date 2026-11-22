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
  local desync = {outgoing=true, l7payload="quic_initial", dis={udp={th_dport=443}, ip=ip}, track=track}
  locked_quic_health_observe_for_tests(desync, host, 5, "default")
end

local function qhm_response(host, ip, track)
  local desync = {outgoing=false, dis={udp={th_sport=443}}, track=track}
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
assert(#fields == 9 and fields[1] == "1" and fields[2] == host and fields[3] == ip
  and fields[5] == "2" and fields[6] == "1" and fields[7] == "1" and fields[8] == "1",
  "QHM did not record Initial/retry/response/TCP fallback")

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
print("OpenWrt embedded LuaJIT smoke: router AUTO without browser, application exclusion, QHM counters and 64-row cap PASS")
