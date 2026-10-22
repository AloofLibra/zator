"""Lazy controller regression; real upstream Lua, mocked native packet boundary.

uv run --no-project --with lupa python tests/lazy_orchestration.py --lib <zapret-lib.lua>
Use --locked <deployed-candidate.lua> to exercise an older runtime backport too.
No network, /opt writes, raw packets or real NFQUEUE listeners.
"""
import argparse
import os
from pathlib import Path
import re
import tempfile

from lupa import LuaRuntime

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--lib', type=Path, required=True)
parser.add_argument('--locked', type=Path, default=Path('orchestra/locked.lua'))
parser.add_argument('--config', type=Path, default=Path('config.default'))
args = parser.parse_args()
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute('''
NFQWS2_COMPAT_VER=6
VERDICT_PASS=0;VERDICT_MODIFY=1;VERDICT_DROP=2;VERDICT_MASK=3;VERDICT_PRESERVE_NEXT=4
TH_RST=4
function bitand(a,b) return a & b end
function bitor(a,b) return a | b end
function bitxor(a,b) return a ~ b end
function bitnot(a) return ~a end
function getpid() return 1 end
function gettid() return 1 end
function clock_gettime() return 100 end
function DLOG() end
function DLOG_ERR() end
os.time=function() return 100 end
io.popen=function() return nil end
''')
lua.execute(args.lib.read_text(encoding='utf-8'))
lua.execute(args.lib.with_name('zapret-auto.lua').read_text(encoding='utf-8'))
lua.execute(args.locked.read_text(encoding='utf-8'))
lua.globals()['HAS_CANARY'] = 'flow_strategy_canary_get' in args.locked.read_text(encoding='utf-8')
lua.execute(Path('lua/rst-guard.lua').read_text(encoding='utf-8'))
work = tempfile.TemporaryDirectory(prefix='z2r-lazy-', dir=os.environ['TMPDIR'])
for name, contents in [('domains', 'example.test\n'), ('substring', 'example\n'), ('absent', 'absent.example\n')]:
    path = Path(work.name) / name
    path.write_text(contents, encoding='utf-8')
    lua.globals()[name.upper() + '_PATH'] = path.as_posix()
lua.execute('''
function pos_check_range() return true end
function cutoff_shim_check() return false end
SOURCE_PLAN={
 {func='test_tamper',func_instance='test_tamper_1',func_n=1,arg={strategy='1'},payload_filter='all'},
 {func='test_tamper',func_instance='test_tamper_2',func_n=2,arg={strategy='2'},payload_filter='all'}
}
function execution_plan_cancel(ctx)
 assert(ctx, 'nested plans must not call native cancellation with nil ctx')
 ctx.cancelled=true
 ctx.cancels=ctx.cancels+1
end
function execution_plan(ctx)
 ctx.builds=ctx.builds+1
 return deepcopy(SOURCE_PLAN)
end
function test_tamper(_,d)
 EXECUTED[#EXECUTED+1]=tonumber(d.arg.strategy)
 return VERDICT_MODIFY
end
function fixture(payload)
 locked_load_lines_for_tests({})
 autostate=nil
 EXECUTED={}
 return {builds=0,cancels=0}, {
  track={hostname='example.test',lua_state={}},
  target={},
  arg={key='8',allow_nohost='1'},
  dis={tcp={th_flags=16},ip={ip_ttl=64},payload=''},
  l7payload=payload or 'tls_client_hello',outgoing=true
 }
end
function dispatch(ctx,d,controller)
 local verdict=(controller or circular_locked)(ctx,d)
 if not ctx.cancelled then
  -- Native engine continues every trailing instance unless explicitly cancelled.
  for _,instance in ipairs(SOURCE_PLAN) do
   verdict=plan_instance_execute(d,verdict,instance)
  end
 end
 return verdict
end
local ctx,d=fixture('empty')
d.arg.payload='tls_client_hello'
assert(dispatch(ctx,d)==VERDICT_PASS, 'explicit payload miss must pass untouched')
assert(ctx.builds==0, 'payload miss must not construct the full native plan')
assert(ctx.cancels==1 and #EXECUTED==0, 'payload miss must cancel native trailing actions')
print('PASS payload miss cancels without materializing plan')

ctx,d=fixture('empty')
assert(dispatch(ctx,d)==VERDICT_MODIFY)
assert(ctx.builds==1 and #EXECUTED==1 and EXECUTED[1]==1,
 'no explicit payload filter must preserve custom empty-payload actions')
print('PASS absent payload filter preserves custom action semantics')

local function assert_lazy(ctx,d,label)
 assert(dispatch(ctx,d)==VERDICT_PASS, label..': pass verdict')
 assert(ctx.builds==0, label..': must not construct native plan')
 assert(ctx.cancels==1 and #EXECUTED==0, label..': must cancel native tail')
 local shared=deepcopy(SOURCE_PLAN)
 d.plan=shared;ctx.cancelled=false;ctx.cancels=0
 assert(dispatch(ctx,d)==VERDICT_PASS, label..': shared-plan pass verdict')
 assert(ctx.builds==0 and ctx.cancels==1 and d.plan==shared and #shared==0 and #EXECUTED==0,
  label..': cancel native tail AND clear aliased Lua remainder')
end
ctx,d=fixture()
locked_load_lines_for_tests({'8\\ttls\\t0'})
assert_lazy(ctx,d,'disabled profile')

ctx,d=fixture()
locked_load_lines_for_tests({'example.test\\ttls\\t0','8\\ttls\\t2'})
assert_lazy(ctx,d,'disabled domain beats profile lock')

ctx,d=fixture()
d.track=nil;d.arg.allow_nohost=nil
assert_lazy(ctx,d,'missing required conntrack')

ctx,d=fixture()
d.arg.exclude_hostlist=DOMAINS_PATH
assert_lazy(ctx,d,'excluded hostname')

ctx,d=fixture()
d.arg.exclude_substrings=SUBSTRING_PATH
assert_lazy(ctx,d,'excluded substring')

ctx,d=fixture()
d.arg.include_substrings=ABSENT_PATH
local cutoffs=0
lua_cutoff=function() cutoffs=cutoffs+1 end
assert_lazy(ctx,d,'include gate miss')
assert(cutoffs==2, 'include gate must retain connection cutoff')

ctx,d=fixture()
d.arg.route_substrings=SUBSTRING_PATH;d.arg.route_key='3'
locked_load_lines_for_tests({'3\\ttls\\t0','8\\ttls\\t2'})
assert_lazy(ctx,d,'disabled routed logical profile')
assert(d.arg.key=='3')

ctx,d=fixture()
d.arg.allow_nohost=nil
local host_record=automate_host_record
automate_host_record=function() return nil end
assert_lazy(ctx,d,'missing required host record')
automate_host_record=host_record
print('PASS early gates cancel without native-plan allocation')

ctx,d=fixture('empty')
d.arg.payload='tls_client_hello'
local shared=deepcopy(SOURCE_PLAN)
d.plan=shared
assert(circular_locked(nil,d)==VERDICT_PASS)
assert(d.plan==shared and #shared==0 and ctx.builds==0 and ctx.cancels==0,
 'nested reject must clear the shared Lua plan in place, without nil native ctx')
print('PASS nested plan ownership')

ctx,d=fixture('tls_server_hello')
d.outgoing=false;d.dis.payload='response';d.arg.payload='tls_client_hello'
assert(dispatch(ctx,d,rst_guard_locked)==VERDICT_PASS)
assert(d.track.lua_state.z2r_rst_guard.seen_real_response and ctx.builds==0,
 'RST guard must observe real response before payload preflight')
ctx,d=fixture('empty')
d.outgoing=false;d.dis.tcp.th_flags=TH_RST;d.arg.payload='tls_client_hello'
assert(dispatch(ctx,d,rst_guard_locked)==VERDICT_DROP and ctx.builds==0 and #EXECUTED==0,
 'suspicious RST must still drop before controller rejection')
print('PASS RST guard precedes payload preflight')

ctx,d=fixture()
d.arg.payload='tls_client_hello'
locked_load_lines_for_tests({'8\\ttls\\t2'})
assert(dispatch(ctx,d)==VERDICT_MODIFY)
assert(ctx.builds==1 and #EXECUTED==1 and EXECUTED[1]==2)

ctx,d=fixture('unknown')
d.dis.tcp=nil;d.dis.udp={};d.arg.key='6';d.arg.proto='udp'
locked_load_lines_for_tests({'6\\tudp\\t2'})
assert(dispatch(ctx,d)==VERDICT_MODIFY and #EXECUTED==1 and EXECUTED[1]==2,
 'unconfigured UDP controllers must retain original behavior')
print('PASS selected action and unconfigured UDP unchanged')

ctx,d=fixture('empty')
d.arg.payload='tls_client_hello'
local track=d.track
local before_cutoffs=cutoffs
assert_lazy(ctx,d,'per-packet payload reject')
ctx,d=fixture('tls_client_hello')
d.track=track;d.arg.payload='tls_client_hello';d.replay=true
assert(dispatch(ctx,d)==VERDICT_MODIFY and #EXECUTED==1)
assert(cutoffs==before_cutoffs, 'payload miss must not cut off a later ClientHello/replay')

CLIENT_SCOPE_ENABLE=1;CLIENT_SCOPE_MARK_MASK=0x00ff0000
CLIENT_SCOPE_MARK_SHIFT=16;CLIENT_SCOPE_MARK_MAX=255
ctx,d=fixture()
d.fwmark=0x00010000
locked_load_lines_for_tests({'default\\t8\\ttls\\t2','mark:1\\t8\\ttls\\t0'})
assert_lazy(ctx,d,'scoped zero beats global strategy')
CLIENT_SCOPE_ENABLE=nil
print('PASS replay after rejected payload and scoped zero lock')

if HAS_CANARY then
 ctx,d=fixture()
 flow_strategy_canary_get=function() return 2 end
 flow_strategy_assign=function() return nil end
 assert(dispatch(ctx,d)==VERDICT_PASS and ctx.builds==1 and #d.plan==0 and #EXECUTED==0,
  'failed installed canary assignment must discard the materialized remainder')
 ctx,d=fixture()
 locked_load_lines_for_tests({'8\\ttls\\t2'})
 flow_strategy_canary_get=function() error('explicit lock must take precedence') end
 flow_strategy_assign=function(_,strategy) return strategy end
 assert(dispatch(ctx,d)==VERDICT_MODIFY and EXECUTED[1]==2)
 flow_strategy_canary_get=nil;flow_strategy_assign=nil
 print('PASS installed canary failure cancellation and explicit-lock precedence')
end
''')
work.cleanup()
controllers = re.findall(r'--lua-desync=(?:circular_locked|rst_guard_locked):key=([12348])(:[^\s]+)',
                         args.config.read_text(encoding='utf-8'))
assert sorted(key for key, _ in controllers) == ['1', '2', '3', '3', '4', '8']
for key, fields in controllers:
    expected = 'tls_client_hello,discord_ip_discovery' if key == '4' else 'tls_client_hello'
    payload = re.search(r':payload=([^:]+)', fields)
    assert payload and payload.group(1) == expected, f'missing explicit controller payload filter: {key}'
print('PASS standard TCP controllers declare their action payloads')
print('lazy orchestration ok:', args.locked)
