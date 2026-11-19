TH_SYN, TH_ACK, TH_FIN, TH_RST = 0x02, 0x10, 0x01, 0x04
TCP_KIND_SCALE, VERDICT_MODIFY, VERDICT_DROP = 3, 1, 2
local sent, raw_ok, seen_win, seen_scale, seen_blob = 0, true, nil, nil, nil

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
function instance_cutoff_shim() end
function find_tcp_option(opts, kind)
  for i, opt in ipairs(opts) do if opt.kind == kind then return i end end
end
function u8(s) return string.byte(s, 1) end
function bu8(n) return string.char(n) end
function DLOG() end
function syndata(_, desync)
  sent = sent + 1
  seen_win = desync.dis.tcp.th_win
  seen_scale = u8(desync.dis.tcp.options[1].data)
  seen_blob = desync.arg.blob
  return raw_ok and VERDICT_DROP or nil
end

dofile(os.getenv("WSSIZE_RAMP_LUA") or "lua/wssize-ramp.lua")

local function syn(track, outgoing)
  return {
    dis={tcp={th_flags=TH_SYN,th_win=64240,options={{kind=TCP_KIND_SCALE,data="\8"}}}},
    track=track, outgoing=outgoing ~= false, arg={mode="full"},
  }
end

-- Ramp runs first and mutates the shared dissect; stock syndata sees that SYN.
local d = syn({lua_state={}})
d.arg.blob = "tlsgoogle"
assert(wssize_ramp({}, d) == VERDICT_MODIFY)
assert(z2r_googlevideo_syndata({}, d) == VERDICT_DROP)
assert(sent == 1 and seen_win == 1 and seen_scale == 1 and seen_blob == "tlsgoogle")
-- Replay/re-entry must not emit another synthetic SYN.
assert(z2r_googlevideo_syndata({}, d) == nil and sent == 1)

-- Lite uses the same one-time SYN path.
local lite = syn({lua_state={}})
lite.arg.mode = "lite"
assert(wssize_ramp({}, lite) == VERDICT_MODIFY)
assert(z2r_googlevideo_syndata({}, lite) == VERDICT_DROP and sent == 2)

-- Failed rawsend returns no DROP, so NFQWS2 delivers the Ramp-modified SYN.
raw_ok = false
local failed = syn({lua_state={}})
assert(wssize_ramp({}, failed) == VERDICT_MODIFY)
assert(z2r_googlevideo_syndata({}, failed) == nil)
assert(failed.dis.tcp.th_win == 1 and failed.track.lua_state.wssize_ramp_syndata_attempted)

-- No Ramp state (no Window Scale/track), ACK, and opposite direction pass through.
local no_ramp = syn({lua_state={}})
assert(z2r_googlevideo_syndata({}, no_ramp) == nil and sent == 3)
local no_track = syn(nil)
wssize_ramp({}, no_track)
assert(z2r_googlevideo_syndata({}, no_track) == nil and sent == 3)
local no_scale = syn({lua_state={}})
no_scale.dis.tcp.options = {}
wssize_ramp({}, no_scale)
assert(z2r_googlevideo_syndata({}, no_scale) == nil and sent == 3)
local ack = syn({lua_state={wssize_ramp_shift=7}})
ack.dis.tcp.th_flags = TH_ACK
assert(z2r_googlevideo_syndata({}, ack) == nil and sent == 3)
local incoming = syn({lua_state={wssize_ramp_shift=7}}, false)
assert(z2r_googlevideo_syndata({}, incoming) == nil and sent == 3)
print("wssize_ramp syndata smoke ok")
