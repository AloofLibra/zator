"""Byte-level clone cap regression using the deployed upstream Lua parser.

Run: python tests/clone_size_limit.py --deps <lupa-dir> --lib <zapret-lib.lua>
The dependency and parser paths are explicit; no router/network access required.
"""
import argparse
from pathlib import Path
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--deps', required=True)
parser.add_argument('--lib', required=True)
args = parser.parse_args()
sys.path.insert(0, args.deps)
from lupa import LuaRuntime

lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
lua.execute(b'''
NFQWS2_COMPAT_VER=6
function bitnot(a) return ~a end
function bitand(a,b) return a & b end
function bitor(a,b) return a | b end
function bitxor(a,b) return a ~ b end
function getpid() return 1 end
function gettid() return 1 end
function clock_gettime() return 1 end
function u8(s,o) return string.byte(s,o or 1) end
function u16(s,o) return string.unpack('>I2',s,o or 1) end
function u24(s,o) local a,b,c=string.byte(s,o or 1,(o or 1)+2); return a*65536+b*256+c end
function bu8(v) return string.pack('>I1',v) end
function bu16(v) return string.pack('>I2',v) end
function bu24(v) return string.char((v>>16)&255,(v>>8)&255,v&255) end
function divint(a,b) return a//b end
function DLOG() end
function DLOG_ERR() end
function brandom(n) return string.rep('Z',n) end
function direction_cutoff_opposite() end
function direction_check() return true end
function instance_cutoff_shim() end
''')
lua.execute(Path(args.lib).read_bytes())
lua.execute(b'''
function direction_cutoff_opposite() end
function direction_check() return true end
function instance_cutoff_shim() end
''')
lua.execute(Path('orchestra/locked.lua').read_bytes())
lua.execute(b'''
local function extension(t, data) return bu16(t)..bu16(#data)..data end
local function hello(padding, big, ech_size, opaque_size)
  local shares = bu16(0x0a0a)..bu16(1)..'G'
  if big then shares = shares..bu16(0x11ec)..bu16(1216)..string.rep('H',1216) end
  shares = shares..bu16(29)..bu16(32)..string.rep('X',32)
  local sni = bu8(0)..bu16(11)..'discord.com'
  local exts = extension(0,bu16(#sni)..sni)
    ..extension(51,bu16(#shares)..shares)
    ..extension(43,bu8(4)..bu16(0x0304)..bu16(0x0303))
    ..extension(65037,string.rep('E',ech_size or 186))
  if padding then exts = exts..extension(21,string.rep(string.char(0),padding)) end
  if opaque_size then exts = exts..extension(0x1234,string.rep('O',opaque_size)) end
  local body = bu16(0x0303)..string.rep('R',32)..bu8(32)..string.rep('S',32)
    ..bu16(2)..bu16(0x1301)..bu8(1)..bu8(0)..bu16(#exts)..exts
  local handshake = bu8(1)..bu24(#body)..body
  return bu8(22)..bu16(0x0301)..bu16(#handshake)..handshake
end
local source = hello(nil,true)
assert(#source>1200, 'test needs an oversized hybrid hello')
local args = {blob='test_clone',sni_del=true,sni_first='www.google.com',sni_snt_new=0}
local track = {lua_state={}}
local desync = {arg=args,track=track,l7payload='tls_client_hello',reasm_data=source,
  dis={tcp={th_seq=1000},payload=source}}
tls_client_hello_clone(nil,desync)
local compact = desync.test_clone
assert(compact and #compact<=1200, 'oversized native clone must be structurally capped at 1200')
local dis = tls_dissect(compact)
assert(dis and dis.handshake[1].dis, 'compact clone must dissect as ClientHello')
local before = tls_dissect(tls_client_hello_mod(source,args)).handshake[1].dis
local after = dis.handshake[1].dis
assert(after.random~=before.random and #after.random==#before.random, 'fake random not refreshed')
assert(after.session_id~=before.session_id and #after.session_id==#before.session_id, 'fake session id not refreshed')
local original_exts = {}
for _,e in ipairs(before.ext) do original_exts[e.type] = e.data end
local keyshare
for _,e in ipairs(after.ext) do
  if e.type==51 then keyshare=e else assert(e.data==original_exts[e.type], 'non-key-share extension changed') end
end
assert(keyshare and #keyshare.dis.list==1, 'PQ/GREASE shares not removed from oversized clone')
assert(keyshare.dis.list[1].group==29 and keyshare.dis.list[1].kex==string.rep('X',32), 'classical share changed')
assert(source:sub(1,3)==string.char(22,3,1), 'real hello changed')
assert(compact:sub(1,3)==string.char(22,3,3), 'fake record header not normalized')
local retransmit = {arg=args,track=track,l7payload='tls_client_hello',
  dis={tcp={th_seq=1000},payload=source:sub(1,1388)}}
tls_client_hello_clone(nil,retransmit)
assert(retransmit.test_clone==compact, 'partial replay lost capped clone')
print('PASS hybrid key_share compacted with ECH/SNI preserved; partial replay reuses result')
local function native(payload, state)
  local d = {arg=args,track=state or {lua_state={}},l7payload='tls_client_hello',
    reasm_data=payload,dis={tcp={th_seq=1000},payload=payload}}
  tls_client_hello_clone(nil,d)
  return d.test_clone, d
end
local small = hello(nil,false)
local function expected_clone(payload)
  local dis=tls_dissect(tls_client_hello_mod(payload,args))
  dis.handshake[1].dis.random=string.rep('Z',32)
  dis.handshake[1].dis.session_id=string.rep('Z',32)
  local value=tls_reconstruct(dis)
  return value:sub(1,2)..string.char(3)..value:sub(4)
end
local expected_small = expected_clone(small)
assert(native(small)==expected_small, 'small clone changed beyond SNI/header/randomization')
local padding_bytes = 1200-#expected_small-4
local boundary = hello(padding_bytes,false)
local expected_boundary = expected_clone(boundary)
assert(#expected_boundary==1200 and native(boundary)==expected_boundary, '1200-byte clone must stay unchanged')
local padded = native(hello(padding_bytes+1,false))
local padded_dis=tls_dissect(padded).handshake[1].dis
assert(#padded<=1200 and padded_dis.ext[1].data==before.ext[1].data, 'padding-only clone corrupted SNI')
assert(padded_dis.ext[4].data==string.rep('E',186), 'padding-only clone dropped ECH unnecessarily')
print('PASS small and 1200-byte boundary unchanged; padding-only oversize shrinks structurally')
local impossible = hello(nil,false,186,1600)
assert(native(impossible)==nil, 'irreducible oversized clone must not be emitted')
local broken = source:sub(1,#source-1)
assert(native(broken)==nil, 'incomplete hello must not be compacted')
print('PASS irreducible and incomplete clones are not emitted')
locked_load_mode_override_for_tests({'4\tclone'})
_G.maxru = 'static-fallback'
local seen
function plan_instance_execute(d,v,i) seen=blob(d,i.arg.blob); return v end
local mode_track={lua_state={}}
local instance={func='fake',arg={blob='maxru'}}
local mode={track=mode_track,l7payload='tls_client_hello',reasm_data=source,
  dis={tcp={th_seq=1000},payload=source}}
blob_override_execute(mode,0,instance,'4')
assert(seen and #seen<=1200 and seen==compact, 'mode wrapper bypassed clone size limit')
mode.reasm_data=nil
mode.dis.payload=source:sub(1,1388)
blob_override_execute(mode,0,instance,'4')
assert(seen==compact, 'mode partial replay lost compact cache')
assert(instance.arg.blob=='maxru', 'size limiter leaked temporary blob args')
print('PASS default mode wrapper and capped partial cache')
instance.func='multisplit'
mode.reasm_data=source
blob_override_execute(mode,0,instance,'4')
assert(seen==compact, 'mirroring instance did not receive the same capped clone')
for _,func in ipairs({'fakeddisorder','fakemultisplit','fakemultidisorder','multidisorder'}) do
  instance.func=func
  blob_override_execute(mode,0,instance,'4')
  assert(seen==compact, 'clone cap was disabled for '..func)
end
mode.reasm_data=small
mode.dis.payload=small
blob_override_execute(mode,0,instance,'4')
assert(seen==expected_small, 'mirroring instance rejected a whole small clone')
instance.func='fake'
mode.reasm_data=nil
mode.dis.payload=source:sub(1,1388)
print('PASS capped clone is used across all mirrored strategies')
Z2R_CLONE_MAX_SIZE=0
local unlimited= native(source)
assert(unlimited and #unlimited>1200, 'explicit full-clone diagnostic opt-out ignored')
blob_override_execute(mode,0,instance,'4')
assert(seen=='static-fallback', 'limit change reused cached compact clone on partial input')
mode.reasm_data=source
blob_override_execute(mode,0,instance,'4')
assert(#seen>1200, 'limit change did not rebuild full clone')
Z2R_CLONE_MAX_SIZE=nil
blob_override_execute(mode,0,instance,'4')
assert(seen==compact, 'restoring default limit did not rebuild compact clone')
print('PASS diagnostic opt-out and cache invalidation when size limit changes')
locked_load_clone_size_for_tests({'3\t512'})
local native_instance={func='tls_client_hello_clone',arg={
  blob='profile_clone',sni_del=true,sni_first='www.google.com',sni_snt_new=0}}
function plan_instance_execute(d,v,i)
  local saved=d.arg
  d.arg=i.arg
  tls_client_hello_clone(nil,d)
  d.arg=saved
  return v
end
local routed_source=hello(600,false)
local routed={profile_n=8,track={lua_state={}},l7payload='tls_client_hello',
  reasm_data=routed_source,dis={tcp={th_seq=1000},payload=routed_source}}
assert(#expected_clone(routed_source)>512 and #expected_clone(routed_source)<=1200)
blob_override_execute(routed,0,native_instance,'3')
assert(routed.profile_clone and #routed.profile_clone<=512,
  'native clone ignored the routed logical profile size limit')
assert(routed.z2r_clone_profile_key==nil, 'logical profile leaked after execution')
locked_load_clone_size_for_tests({})
print('PASS native producer uses routed logical profile size limit')
local other_args={blob='other_clone',sni_del=true,sni_first='www.example.com',sni_snt_new=0}
local shared={lua_state={}}
local multi={arg=args,track=shared,l7payload='tls_client_hello',reasm_data=source,
  dis={tcp={th_seq=1000},payload=source}}
tls_client_hello_clone(nil,multi)
local first=multi.test_clone
multi.arg=other_args
tls_client_hello_clone(nil,multi)
local second=multi.other_clone
assert(first and second and first~=second, 'two producer fixtures must create distinct clones')
multi.reasm_data=nil
multi.dis.payload=source:sub(1,1388)
multi.arg=args
tls_client_hello_clone(nil,multi)
assert(multi.test_clone==first, 'producer B evicted producer A on partial replay')
multi.arg=other_args
tls_client_hello_clone(nil,multi)
assert(multi.other_clone==second, 'producer A evicted producer B on partial replay')
print('PASS multiple native producers preserve independent partial-replay caches')
routed.z2r_clone_profile_key='outer-profile'
function plan_instance_execute(d,v,i)
  assert(d.z2r_clone_profile_key=='3', 'logical profile missing inside executor')
  error('PROFILE_EXEC_SENTINEL')
end
local ok,err=pcall(blob_override_execute,routed,0,native_instance,'3')
assert(not ok and tostring(err):find('PROFILE_EXEC_SENTINEL',1,true))
assert(routed.z2r_clone_profile_key=='outer-profile', 'exception leaked logical profile')
print('PASS logical profile restored after native executor exception')
_G.cap_test_blob=expected_clone(hello(padding_bytes+1,false))
assert(#cap_test_blob==1201, 'global-cap fixture must exceed the wire limit')
locked_load_blob_override_for_tests({'3\tcap_test_blob'})
local sni_overrides
for n=1,100 do
  local key,value=debug.getupvalue(blob_override_execute,n)
  if not key then break end
  if key=='SNI_OVERRIDES' then sni_overrides=value; break end
end
assert(sni_overrides, 'missing SNI override table')
sni_overrides['3']='innocent.example'
for _,func in ipairs({'fake','fakemultisplit','fakemultidisorder'}) do
  local cap_instance={func=func,arg={blob='maxru',fake_blob='fake_default_tls',sni_first='original.example'}}
  local cap_desync={z2r_mode_clone='saved-clone',z2r_blob_cap='saved-cap',z2r_clone_profile_key='outer-profile'}
  function plan_instance_execute(d,v,i)
    local cap_arg=func=='fake' and 'blob' or 'fake_blob'
    assert(i.arg[cap_arg]=='z2r_blob_cap', 'test did not activate global cap')
    assert(#d.z2r_blob_cap<=1200 and d.z2r_blob_cap~='saved-cap')
    assert(i.arg.sni_first=='innocent.example')
    assert(d.z2r_clone_profile_key=='3')
    error('CAP_EXEC_SENTINEL')
  end
  local ok,err=pcall(blob_override_execute,cap_desync,0,cap_instance,'3')
  assert(not ok and tostring(err):find('CAP_EXEC_SENTINEL',1,true), 'cap executor error not propagated: '..tostring(err))
  assert(cap_instance.arg.blob=='maxru' and cap_instance.arg.fake_blob=='fake_default_tls')
  assert(cap_instance.arg.sni_first=='original.example', 'exception leaked SNI override')
  assert(cap_desync.z2r_mode_clone=='saved-clone' and cap_desync.z2r_blob_cap=='saved-cap')
  assert(cap_desync.z2r_clone_profile_key=='outer-profile', 'cap exception leaked profile')
end
print('PASS blob override, global cap, SNI and temporary fields restored after executor errors')
''')
print('clone size limit regression ok')
