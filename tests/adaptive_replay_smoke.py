#!/usr/bin/env python3
"""Checks replay of authoritative C-side nfqws2 flow telemetry."""

import contextlib
import importlib.util
import io
import json
import sys

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("adaptive_replay", ROOT / "tools" / "adaptive_replay.py")
replay_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(replay_module)


def event(name, flow, strategy=0, *, host="", scope="default", server_bytes=0,
          reason="", timestamp=1000):
    values = ("v2", str(timestamp), name, str(flow), "0" if not strategy else "2",
              str(strategy), "1" if strategy else "0", scope, host, "tcp", "ipv4",
              "203.0.113.4", "443", "5", "3", "300", str(server_bytes),
              "1" if server_bytes else "1", "1" if server_bytes else "0",
              "0", "0", "1", "1", "900", "1000", "1", "0", reason)
    return "\t".join(values) + "\n"


def main():
    trace = "".join((
        event("FLOW_START", 1),
        event("STRATEGY_APPLIED", 1, 7, host="video.example"),
        event("FLOW_END", 1, 7, host="video.example", server_bytes=1200, reason="drop"),
        event("FLOW_START", 2),
        event("STRATEGY_APPLIED", 2, 9, host="silent.example"),
        event("FLOW_END", 2, 9, host="silent.example", reason="timeout_established"),
        event("FLOW_START", 3),
        event("STRATEGY_APPLIED", 3, 7, host="video.example"),
        event("FLOW_END", 3, 7, host="video.example", server_bytes=800, timestamp=12000),
        event("FLOW_START", 4),
        event("STRATEGY_APPLIED", 4, 9, host="video.example"),
        event("FLOW_END", 4, 9, host="video.example", server_bytes=900, timestamp=23000),
        event("FLOW_START", 5),
        event("STRATEGY_APPLIED", 5, 9, host="video.example"),
        event("FLOW_END", 5, 9, host="video.example", server_bytes=1100, timestamp=34000),
    ))
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        replay_module.replay(io.StringIO(trace))
    rows = [json.loads(line) for line in out.getvalue().splitlines()]
    assert len(rows) == 5
    assert rows[0]["strategy_id"] == 7
    assert rows[0]["hostname"] == "video.example"
    assert rows[0]["scope"] == "default"
    assert rows[0]["evidence"] == "WEAK_SUCCESS"
    assert rows[0]["action"] == "CANDIDATE_OBSERVED"
    assert rows[0]["progress"]["server_payload_bytes"] == 1200
    assert rows[0]["progress"]["clienthello_count"] == 1
    assert rows[1]["evidence"] == "UNKNOWN"  # silence is never inferred as failure
    assert rows[1]["network_health"] == "UNKNOWN"
    assert rows[1]["lifecycle"]["termination_reason"] == "timeout_established"
    assert rows[2]["action"] == "SHADOW_INITIAL_CHAMPION"
    assert rows[2]["shadow_champion"] == 7
    assert rows[3]["action"] == "CHALLENGER_OBSERVED"
    assert rows[4]["action"] == "CHALLENGER_READY"
    assert rows[4]["shadow_champion"] == 7  # no negative evidence, so no promotion

    # Two successful flows in one short burst are only one independent vote.
    burst = "".join((event("FLOW_START", 20),
                     event("STRATEGY_APPLIED", 20, 7, host="burst.example"),
                     event("FLOW_END", 20, 7, host="burst.example", server_bytes=500, timestamp=2000),
                     event("FLOW_START", 21),
                     event("STRATEGY_APPLIED", 21, 7, host="burst.example"),
                     event("FLOW_END", 21, 7, host="burst.example", server_bytes=600, timestamp=9000)))
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        replay_module.replay(io.StringIO(burst))
    burst_rows = [json.loads(line) for line in out.getvalue().splitlines()]
    assert all(row["action"] != "SHADOW_INITIAL_CHAMPION" for row in burst_rows)
    assert burst_rows[0]["independent_observation"] is True
    assert burst_rows[-1]["independent_observation"] is False
    assert burst_rows[-1]["independent_successes"] == 1

    # Outcomes from different scopes must not combine into one champion.
    scoped = "".join((event("FLOW_START", 40),
                      event("STRATEGY_APPLIED", 40, 7, host="scope.example", scope="lan"),
                      event("FLOW_END", 40, 7, host="scope.example", scope="lan", server_bytes=400),
                      event("FLOW_START", 41),
                      event("STRATEGY_APPLIED", 41, 7, host="scope.example", scope="wan"),
                      event("FLOW_END", 41, 7, host="scope.example", scope="wan", server_bytes=500, timestamp=12000)))
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        replay_module.replay(io.StringIO(scoped))
    scoped_rows = [json.loads(line) for line in out.getvalue().splitlines()]
    assert scoped_rows[0]["context"][2] == "lan"
    assert scoped_rows[1]["context"][2] == "wan"
    assert all(row["shadow_champion"] is None for row in scoped_rows)

    # Incomplete or conflicted strategy attribution cannot train a strategy.
    bad_trace = "".join((event("FLOW_START", 3),
                         event("FLOW_END", 3, reason="timeout_syn")))
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        replay_module.replay(io.StringIO(bad_trace))
    row = json.loads(out.getvalue())
    assert row["decision"] == "UNATTRIBUTED"
    assert row["evidence"] == "UNKNOWN"

    truncated_trace = event("FLOW_END", 30, 7, host="truncated.example", server_bytes=300)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        replay_module.replay(io.StringIO(truncated_trace))
    truncated_row = json.loads(out.getvalue())
    assert truncated_row["decision"] == "UNATTRIBUTED"
    assert truncated_row["assignment_event_seen"] is False

    conflict_trace = "".join((event("FLOW_START", 4),
                               event("STRATEGY_APPLIED", 4, 7, host="move.example"),
                               event("STRATEGY_CONFLICT", 4, 7, host="move.example"),
                               event("FLOW_END", 4, 7, host="move.example", server_bytes=25)))
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        replay_module.replay(io.StringIO(conflict_trace))
    assert json.loads(out.getvalue())["decision"] == "UNATTRIBUTED"

    mismatched_end = "".join((event("FLOW_START", 6),
                               event("STRATEGY_APPLIED", 6, 7, host="move.example"),
                               event("FLOW_END", 6, 9, host="move.example", server_bytes=25)))
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        replay_module.replay(io.StringIO(mismatched_end))
    mismatch_row = json.loads(out.getvalue())
    assert mismatch_row["decision"] == "UNATTRIBUTED"
    assert mismatch_row["strategy_conflict"] is True

    # A host learned after C attribution fills an initially empty hostname.
    late_host = "".join((event("FLOW_START", 60),
                         event("STRATEGY_APPLIED", 60, 7, host=""),
                         event("FLOW_END", 60, 7, host="late.example", server_bytes=300, timestamp=1000),
                         event("FLOW_START", 61),
                         event("STRATEGY_APPLIED", 61, 7, host="late.example"),
                         event("FLOW_END", 61, 7, host="late.example", server_bytes=300, timestamp=12000)))
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        replay_module.replay(io.StringIO(late_host))
    late_rows = [json.loads(line) for line in out.getvalue().splitlines()]
    assert late_rows[0]["hostname"] == "late.example"
    assert late_rows[1]["action"] == "SHADOW_INITIAL_CHAMPION"

    # A partial trace missing FLOW_START cannot establish a trustworthy flow.
    no_start = "".join((event("STRATEGY_APPLIED", 62, 7, host="partial.example"),
                        event("FLOW_END", 62, 7, host="partial.example", server_bytes=300)))
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        replay_module.replay(io.StringIO(no_start))
    assert json.loads(out.getvalue())["decision"] == "UNATTRIBUTED"

    # Resident shadow output may include valid flows that never received a
    # strategy assignment. Accept only the all-zero, explicitly unattributed
    # shape; it must remain diagnostic and never count as strategy evidence.
    flow_columns = ("FLOW_OUTCOME flow_id profile strategy generation evidence hostname champion "
                    "challenger action independent confidence_lcb95_milli rank candidate_count "
                    "top_strategy quarantine decision scope transport ip_family network_epoch "
                    "network_health network_health_reason client_packets server_packets client_bytes "
                    "server_bytes server_seen server_payload_seen client_rst server_rst client_fin "
                    "server_fin start_ms last_seen_ms clienthello_count clienthello_retransmissions "
                    "termination_reason source_port dst_port dst_ip").split()
    header = ("# ADAPTIVE_CONTROLLER_OUTPUT v7: " + " ".join(
        flow_columns + ["PROBE_OUTCOME", "redirect_host", "body_sample_bytes", "block_body_marker"]))
    unassigned_row = ["FLOW_OUTCOME", "77", "0", "0", "0", "WEAK_SUCCESS", "example.com",
                      "0", "0", "UNATTRIBUTED", "0", "0", "0", "0", "0", "NONE",
                      "UNATTRIBUTED", "default", "tcp", "ipv4", "1", "UNKNOWN",
                      "CANARY_REQUIRED", "1", "1", "100", "200", "1", "1", "0", "0",
                      "1", "0", "1000", "1200", "1", "0", "timeout_fin", "50000",
                      "443", "93.184.216.34"]
    assert len(unassigned_row) == len(flow_columns)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        replay_module.replay_controller_output(io.StringIO(
            header + "\n" + "\t".join(unassigned_row) + "\n"))
    controller_rows = [json.loads(line) for line in out.getvalue().splitlines()]
    assert controller_rows[0]["profile_id"] == 0
    assert controller_rows[0]["decision"] == "UNATTRIBUTED"
    assert controller_rows[-1]["unattributed_flow_count"] == 1
    assert controller_rows[-1]["attributed_flow_count"] == 0

    invalid_assignment = unassigned_row.copy()
    invalid_assignment[3] = "7"
    try:
        replay_module.replay_controller_output(io.StringIO(
            header + "\n" + "\t".join(invalid_assignment) + "\n"))
        raise AssertionError("profile zero with strategy must be rejected")
    except ValueError as exc:
        assert "outside allowed bounds" in str(exc)

    # A bounded C trace reports truncation; unmatched flows stay incomplete.
    partial = event("FLOW_START", 99) + "# TRACE_LIMIT\tmax_bytes=524288\n"
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        replay_module.replay(io.StringIO(partial))
    status = json.loads(out.getvalue())
    assert status["event"] == "TRACE_STATUS"
    assert status["trace_complete"] is False
    assert status["termination_reason"] == "max_bytes"
    assert status["incomplete_flow_count"] == 1

    # Verify the contract statically in the shipped fork patch.
    patch_path = ROOT / "patches" / "zapret2" / "adaptive-flow-telemetry.patch"
    assert patch_path.exists()
    patch_text = patch_path.read_text(encoding="utf-8")
    for primitive in ("FLOW_START", "STRATEGY_APPLIED", "FLOW_END", "adaptive-events", "v2"):
        assert primitive in patch_text
    assert 'strncmp(params.adaptive_events_file, "unix:", 5) && !t->strategy_assigned' in patch_text
    assert 'adaptive_emit(track, "FLOW_START", "")' in patch_text
    for lua_path in (ROOT / "orchestra" / "locked.lua",
                     ROOT / "lua" / "combined-detector.lua"):
        assert "flow_strategy_assign" in lua_path.read_text(encoding="utf-8")
    print("adaptive replay smoke ok")


if __name__ == "__main__":
    main()
