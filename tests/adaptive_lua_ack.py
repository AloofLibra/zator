#!/usr/bin/env python3
"""Verify the adaptive probe ACK follows the selected host/profile/strategy."""
import json
from pathlib import Path
import tempfile

from lupa import LuaRuntime

repo = Path(__file__).resolve().parents[1]


def run_ack(expected_strategy):
    with tempfile.TemporaryDirectory(prefix="zator-adaptive-ack-") as tmp:
        ack = Path(tmp) / "ack.tsv"
        ack.touch()
        lua = LuaRuntime(unpack_returned_tuples=True)
        env = {
            "Z2R_ADAPTIVE_ACK_PATH": str(ack),
            "Z2R_ADAPTIVE_ACK_HOST": "probe.example",
            "Z2R_ADAPTIVE_ACK_PROFILE": "1",
            "Z2R_ADAPTIVE_ACK_STRATEGY": str(expected_strategy),
            "Z2R_ADAPTIVE_TEST_ID": "test-123",
            "Z2R_ADAPTIVE_RULES_FILE": "/nonexistent/adaptive-rules.tsv",
            "Z2R_ADAPTIVE_BROWSER_TRIALS_FILE": "/nonexistent/browser-trials.tsv",
            "Z2R_ADAPTIVE_BROWSER_FLOW_DIR": "/nonexistent/browser-flows",
            "Z2R_ADAPTIVE_RULES_APPLY": "0",
            "Z2R_ADAPTIVE_EVENTS_FILE": "/nonexistent/adaptive-events.tsv",
            "Z2R_ADAPTIVE_QUIC_HEALTH_FILE": "/nonexistent/quic-health.tsv",
            "Z2R_ADAPTIVE_RAMP_TARGETS_FILE": "/nonexistent/ramp-targets.tsv",
            "ZAPRET2_ROOT": "/nonexistent/zapret2",
            "ZATOR_ROOT": "/nonexistent/zator",
        }
        lua.globals().ack_env = env
        lua.execute("os.getenv = function(key) return ack_env[key] end")
        lua.execute(f"dofile({json.dumps(str(repo / 'orchestra/locked.lua'))})")
        lua.execute("""
            VERDICT_PASS = 0
            DLOG = function() end
            DLOG_ERR = function() end
            execution_plan_cancel = function() end
            plan_clear = function(desync) desync.plan = {} end
            orchestrate = function() end
            automate_host_record = function() return {} end
            plan_instance_pop = function(desync) return table.remove(desync.plan, 1) end
            plan_instance_execute = function(desync, verdict, instance) return verdict end
            locked_load_lines_for_tests({"probe.example\\ttls\\t2"})
            local desync = {
                profile = "1", hostname = "probe.example", track = {lua_state = {}},
                arg = {}, plan = {{arg = {strategy = 1}}, {arg = {strategy = 2}}}
            }
            assert(circular_locked({}, desync) == VERDICT_PASS)
        """)
        return ack.read_text()


def run_direct_ack():
    with tempfile.TemporaryDirectory(prefix="zator-adaptive-direct-ack-") as tmp:
        ack = Path(tmp) / "ack.tsv"
        ack.touch()
        lua = LuaRuntime(unpack_returned_tuples=True)
        env = {
            "Z2R_ADAPTIVE_ACK_PATH": str(ack),
            "Z2R_ADAPTIVE_ACK_HOST": "probe.example",
            "Z2R_ADAPTIVE_ACK_PROFILE": "1",
            "Z2R_ADAPTIVE_ACK_STRATEGY": "0",
            "Z2R_ADAPTIVE_TEST_ID": "direct-123",
            "Z2R_ADAPTIVE_RULES_FILE": "/nonexistent/adaptive-rules.tsv",
            "Z2R_ADAPTIVE_BROWSER_TRIALS_FILE": "/nonexistent/browser-trials.tsv",
            "Z2R_ADAPTIVE_BROWSER_FLOW_DIR": "/nonexistent/browser-flows",
            "Z2R_ADAPTIVE_RULES_APPLY": "0",
            "Z2R_ADAPTIVE_EVENTS_FILE": "/nonexistent/adaptive-events.tsv",
            "Z2R_ADAPTIVE_QUIC_HEALTH_FILE": "/nonexistent/quic-health.tsv",
            "Z2R_ADAPTIVE_RAMP_TARGETS_FILE": "/nonexistent/ramp-targets.tsv",
            "ZAPRET2_ROOT": "/nonexistent/zapret2",
            "ZATOR_ROOT": "/nonexistent/zator",
        }
        lua.globals().ack_env = env
        lua.execute("os.getenv = function(key) return ack_env[key] end")
        lua.execute(f"dofile({json.dumps(str(repo / 'orchestra/locked.lua'))})")
        lua.execute("""
            VERDICT_PASS = 0
            DLOG = function() end
            DLOG_ERR = function() end
            execution_plan_cancel = function() end
            plan_clear = function(desync) desync.plan = {} end
            orchestrate = function() end
            automate_host_record = function() return {} end
            locked_load_lines_for_tests({"probe.example\\ttls\\t0"})
            local desync = { profile = "1", hostname = "probe.example", track = {lua_state = {}}, arg = {}, plan = {{arg = {strategy = 1}}} }
            assert(circular_locked({}, desync) == VERDICT_PASS)
        """)
        return ack.read_text()


assert run_ack(2) == "test-123\tprobe.example\t1\t2\n", "matching selection did not write ACK"
assert run_ack(1) == "", "mismatched strategy wrote a false ACK"
assert run_direct_ack() == "direct-123\tprobe.example\t1\t0\n", "direct passthrough did not write an isolated ACK"
print("adaptive Lua strategy ACK smoke ok")
