local calls, lite_cutoffs = 0, 0
TH_SYN, TH_ACK, TH_FIN, TH_RST = 0x02, 0x10, 0x01, 0x04
TCP_KIND_SCALE, VERDICT_MODIFY = 3, 2
function bitand(a, b)
  local out, bit = 0, 1
  while a > 0 and b > 0 do
    if a % 2 == 1 and b % 2 == 1 then out = out + bit end
    a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
  end
  return out
end
function direction_cutoff_opposite() end
function direction_check() return true end
function instance_cutoff_shim(_, desync, dir)
  if dir == true then
    lite_cutoffs = lite_cutoffs + 1
    desync.track.lua_state.wssize_ramp_lite_cutoff = true
  else
    calls = calls + 1
  end
end
function find_tcp_option(opts, kind)
  for i, opt in ipairs(opts) do if opt.kind == kind then return i end end
end
function u8(s) return string.byte(s, 1) end
function bu8(n) return string.char(n) end
function DLOG() end
dofile(os.getenv("WSSIZE_RAMP_LUA") or "lua/wssize-ramp.lua")

local state = {}
local d = { dis={tcp={th_flags=TH_SYN, th_win=64240, options={{kind=TCP_KIND_SCALE,data="\8"}}}},
  track={lua_state=state}, outgoing=true, arg={ip="188.244.8.77",mode="full"} }
d.dis.ip = {ip_dst=string.char(188,244,8,77)}
assert(wssize_ramp({}, d) == VERDICT_MODIFY)
assert(d.dis.tcp.th_win == 1 and u8(d.dis.tcp.options[1].data) == 1)
assert(state.wssize_ramp_shift == 7)

local function packet(ack, win)
  return {dis={ip={ip_dst=string.char(188,244,8,77)},tcp={th_flags=TH_ACK, th_ack=ack, th_win=win or 1, options={}}},
    track={lua_state=state,pos={server={tcp={seq0=1000}}}},outgoing=true,arg={ip="188.244.8.77",mode="full"}}
end
local before = packet(1001)
assert(wssize_ramp({}, before) == nil and before.dis.tcp.th_win == 1)
local open = packet(1002, 65535)
assert(wssize_ramp({}, open) == nil and open.dis.tcp.th_win == 65535)
local after = packet(1001, 100)
assert(wssize_ramp({}, after) == VERDICT_MODIFY and after.dis.tcp.th_win == 12800)

local lite_state = {}
lite_state.wssize_ramp_shift, lite_state.wssize_ramp_opened = 7, false
lite_state.wssize_ramp_open, lite_state.wssize_ramp_wsize = 1, 1
lite_state.wssize_ramp_multiplier, lite_state.wssize_ramp_mode = 128, "lite"
local lite = packet(1002, 100)
lite.track.lua_state = lite_state
lite.arg.mode = "lite"
assert(wssize_ramp({}, lite) == nil and lite.dis.tcp.th_win == 100)
assert(lite_cutoffs == 1 and lite_state.wssize_ramp_lite_cutoff)
local lite_after = packet(1001, 200)
lite_after.track.lua_state = lite_state
lite_after.arg.mode = "lite"
assert(lite_after.dis.tcp.th_win == 200 and lite_state.wssize_ramp_lite_cutoff)

local missing_seq_state = {
  wssize_ramp_shift=7, wssize_ramp_multiplier=128, wssize_ramp_mode="full",
  wssize_ramp_wsize=1, wssize_ramp_open=1, wssize_ramp_opened=false
}
local missing_seq = {dis={ip={ip_dst=string.char(188,244,8,77)},tcp={th_flags=TH_ACK,th_ack=1002,th_win=100}},
  track={lua_state=missing_seq_state},outgoing=true,arg={ip="188.244.8.77"}}
assert(wssize_ramp({}, missing_seq) == VERDICT_MODIFY and missing_seq.dis.tcp.th_win == 12800)
assert(missing_seq_state.wssize_ramp_opened)

local narrow_scale = packet(1002, 100)
narrow_scale.dis.tcp.th_flags = TH_SYN
narrow_scale.dis.tcp.options = {{kind=TCP_KIND_SCALE,data="\1"}}
narrow_scale.arg.scale = 5
narrow_scale.arg.mode = "full"
narrow_scale.track.lua_state = {}
assert(wssize_ramp({}, narrow_scale) == VERDICT_MODIFY)
assert(narrow_scale.dis.tcp.options[1].data == "\1" and narrow_scale.track.lua_state.wssize_ramp_shift == 0)
local narrow_ack = packet(1002, 100)
narrow_ack.track.lua_state = narrow_scale.track.lua_state
assert(wssize_ramp({}, narrow_ack) == nil and narrow_ack.dis.tcp.th_win == 100)

-- Destination selection is done by the NFQWS2 profile's managed ipset filter.
local missing = {dis={tcp={th_flags=TH_SYN,th_win=100,options={}}},track={lua_state={}},outgoing=true,arg={}}
wssize_ramp({}, missing)
assert(calls == 1 and missing.dis.tcp.th_win == 100)

local no_track = {dis={tcp={th_flags=TH_ACK,th_ack=1002,th_win=100,options={}}},outgoing=true,arg={}}
wssize_ramp({}, no_track)
assert(calls == 2 and no_track.dis.tcp.th_win == 100)
print("wssize_ramp smoke ok")
