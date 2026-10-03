-- Run from repository root: lua tests/full_clone.lua
-- nfqws2 API stubs isolate lifecycle; byte-level parser replay is tested separately.
-- This suite explicitly retains full clones; default cap uses the real TLS parser
-- in tests/clone_size_limit.py, including capped FULL -> PARTIAL replay.
Z2R_CLONE_MAX_SIZE = 0
DLOG = function() end
DLOG_ERR = function() end
local prefix = string.char(22,3,1,7,20,1,0,7,16)
hello = prefix .. string.rep("K",1808)
function tls_record_full(payload)
  return #payload >= 5 + payload:byte(4) * 256 + payload:byte(5)
end
function tls_client_hello_mod(payload, options)
  assert(tls_record_full(payload), "partial input reached parser")
  return payload .. (options.sni_first or "")
end
function blob(desync, name) return desync[name] or _G[name] end
function blob_exist(desync, name) return blob(desync, name) ~= nil end
function direction_cutoff_opposite() end
function direction_check() return true end
function instance_cutoff_shim() end
dofile("orchestra/locked.lua")
locked_load_mode_override_for_tests({'4\tclone'})
_G.maxru = 'static'
local modifier = tls_client_hello_mod
local parses = 0
function tls_client_hello_mod(...) parses = parses + 1; return modifier(...) end
local seen
function plan_instance_execute(desync, verdict, instance)
  seen = blob(desync, instance.arg.blob)
  return verdict
end
local instance = {arg={blob='maxru'}}
local track = {lua_state={}}
local desync = {track=track, l7payload='tls_client_hello', reasm_data=hello, dis={tcp={th_seq=1000},payload=hello}}
blob_override_execute(desync, 0, instance, '4')
local full = seen
assert(#full > 1700, 'full clone must preserve large hello')
assert(hello:sub(1,3) == string.char(22,3,1), 'fixture must contain original 0301')
assert(full:sub(1,3) == string.char(22,3,3), 'mode clone record header must become 0303')
local expected = modifier(hello,{sni_del=true,sni_first='www.google.com',sni_snt_new=0})
assert(full == expected:sub(1,2) .. string.char(3) .. expected:sub(4), 'header change modified other clone bytes')
assert(instance.arg.blob == 'maxru', 'args not restored after execution')
-- A fresh desync object on the SAME connection models replay/retransmission.
desync = {track=track,l7payload='tls_client_hello',dis={tcp={th_seq=1000},payload=hello:sub(1,1388)}}
blob_override_execute(desync,0,instance,'4')
assert(seen == full, 'FULL -> PARTIAL replaced complete clone with static fallback')
assert(parses == 1, 'partial replay must not invoke TLS parser')
print('PASS FULL -> PARTIAL reuse, parser called once')
local wrong_sequence = {track=track,l7payload='tls_client_hello',dis={tcp={th_seq=2000},payload=hello:sub(1,1388)}}
blob_override_execute(wrong_sequence,0,instance,'4')
assert(seen == 'static', 'partial clone reused at another TCP sequence')
local tail = {track=track,l7payload='tls_client_hello',dis={tcp={th_seq=2388},payload=hello:sub(1389)}}
blob_override_execute(tail,0,instance,'4')
assert(seen == 'static', 'full clone reused at tail sequence')
blob_override_execute(desync,0,instance,'4')
assert(seen == full, 'tail miss invalidated valid first-segment cache')
print('PASS sequence and tail guard')
-- A different connection must not receive the previous connection clone.
seen = nil
local other = {track={lua_state={}},l7payload='tls_client_hello',dis={payload=hello:sub(1,1388)}}
_G.maxru = 'static'
blob_override_execute(other,0,instance,'4')
assert(seen == 'static', 'clone leaked between connections')
assert(parses == 1, 'incomplete first input must not invoke parser')
print('PASS connection isolation and incomplete-first guard')
-- Configuration changes cannot reuse a clone made with the previous SNI.
for i=1,30 do
  local name = debug.getupvalue(blob_override_execute,i)
  if name == 'SNI_OVERRIDES' then
    debug.setupvalue(blob_override_execute,i,{['4']='hcaptcha.com'})
    break
  end
end
blob_override_execute(desync,0,instance,'4')
assert(seen == 'static', 'old SNI clone reused after settings change')
desync.reasm_data = hello
blob_override_execute(desync,0,instance,'4')
assert(seen ~= full and #seen > 1700, 'SNI change did not rebuild full clone')
print('PASS SNI invalidation')
local changed = hello:sub(1,11) .. string.char((hello:byte(12)+1)%256) .. hello:sub(13)
local partial_new = {track=track,l7payload='tls_client_hello',dis={tcp={th_seq=1000},payload=changed:sub(1,1388)}}
blob_override_execute(partial_new,0,instance,'4')
assert(seen == 'static', 'new partial ClientHello reused a stale previous hello clone')
print('PASS changed-hello prefix invalidation')
local clone_args = {blob='clone_hcaptcha',sni_del=true,sni_first='hcaptcha.com',sni_snt_new=0,fallback='maxru'}
local ct = {lua_state={}}
local explicit = {arg=clone_args,track=ct,outgoing=true,func_instance='tls_client_hello_clone_3_69',l7payload='tls_client_hello',reasm_data=hello,dis={tcp={th_seq=1000},payload=hello}}
tls_client_hello_clone(nil,explicit)
local explicit_full = explicit.clone_hcaptcha
assert(#explicit_full > 1700, 'explicit full clone missing')
assert(explicit_full:sub(1,3) == string.char(22,3,3), 'explicit clone record header must become 0303')
assert(hello:sub(1,3) == string.char(22,3,1), 'real ClientHello changed')
local before_partial = parses
explicit = {arg=clone_args,track=ct,outgoing=true,func_instance='tls_client_hello_clone_3_69',l7payload='tls_client_hello',dis={tcp={th_seq=1000},payload=hello:sub(1,1388)}}
tls_client_hello_clone(nil,explicit)
assert(explicit.clone_hcaptcha == explicit_full, 'explicit ECH clone lost on partial replay')
assert(parses == before_partial, 'explicit partial replay invoked parser')
print('PASS explicit strategy clone FULL -> PARTIAL')
-- desync_copy keeps the conntrack state; replay offsets identify the CH start.
local replay = {track=ct,arg=clone_args,outgoing=true,l7payload='tls_client_hello',
  reasm_data=hello,reasm_offset=1388,dis={tcp={th_seq=2388},payload=hello:sub(1389)}}
local replay_parses = parses
tls_client_hello_clone(nil,replay)
assert(replay.clone_hcaptcha == explicit_full, 'replay offset changed clone identity')
assert(parses == replay_parses, 'complete replay parsed identical hello again')
print('PASS shared conntrack and replay offset')
function plan_instance_execute(desync, verdict, instance) error('sentinel execution error') end
instance.arg.fake_blob = 'fake_default_tls'
instance.arg.sni_first = 'original.example'
desync.z2r_mode_clone = 'previous temporary value'
local ok, err = pcall(blob_override_execute,desync,0,instance,'4')
assert(not ok and tostring(err):find('sentinel execution error',1,true), 'error swallowed')
assert(instance.arg.blob == 'maxru', 'args leaked after execution error')
assert(instance.arg.fake_blob == 'fake_default_tls', 'fake_blob leaked after error')
assert(instance.arg.sni_first == 'original.example', 'SNI leaked after error')
assert(desync.z2r_mode_clone == 'previous temporary value', 'temporary clone leaked after error')
print('PASS execution-error restoration')

print('full clone smoke ok')
