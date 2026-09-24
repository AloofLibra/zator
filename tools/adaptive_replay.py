#!/usr/bin/env python3
"""Replay C-owned nfqws2 flow events offline; never contacts live targets.

The current C telemetry can confirm server payload, but silence is not a
reliable strategy failure. This phase therefore emits UNKNOWN for flows with
no server payload and does not rotate or promote on negative evidence.
"""

import argparse
from contextlib import ExitStack
import json
import sys
from collections import defaultdict


FIELDS_BY_VERSION = {"v1": 27, "v2": 28, "v3": 29}
COHORT_WINDOW_MS = 10_000


def replay(stream):
    flows = {}
    seen_flows = set()
    outcomes = []
    probe_results = []
    trace_limited = False
    candidates = defaultdict(lambda: defaultdict(lambda: {
        "successes": 0, "unknown": 0, "last_success_ms": None
    }))
    champions = {}
    for line_no, raw in enumerate(stream, 1):
        raw = raw.rstrip("\r\n")
        if raw.startswith("# TRACE_LIMIT"):
            trace_limited = True
            continue
        if not raw or raw.startswith("#"):
            continue
        cols = raw.split("\t")
        if cols[0] == "PROBE_RESULT":
            if len(cols) != 9 or cols[1] != "v1":
                raise ValueError(f"line {line_no}: unsupported probe result record")
            try:
                probe = {
                    "host": cols[2].lower(), "src_port": int(cols[3]),
                    "strategy": int(cols[4]), "generation": int(cols[5]),
                    "curl_rc": int(cols[6]), "http_status": cols[7],
                    "elapsed_ms": int(cols[8]),
                }
            except ValueError as exc:
                raise ValueError(f"line {line_no}: invalid probe result value") from exc
            if (not probe["host"] or not 1 <= probe["src_port"] <= 65535 or
                    not 1 <= probe["strategy"] <= 0xFFFFFFFF or
                    not 1 <= probe["generation"] <= 0xFFFFFFFFFFFFFFFF or
                    probe["curl_rc"] < 0 or probe["elapsed_ms"] < 0 or
                    len(probe["http_status"]) != 3 or not probe["http_status"].isdigit()):
                raise ValueError(f"line {line_no}: probe result outside allowed bounds")
            probe_results.append(probe)
            continue
        version = cols[0] if cols else ""
        expected_fields = FIELDS_BY_VERSION.get(version)
        if expected_fields is None or len(cols) != expected_fields:
            raise ValueError(f"line {line_no}: unsupported C telemetry version/field count")
        if version == "v3":
            (_, timestamp, event, flow_id, profile, strategy, generation, scope,
             host, transport, family, dst_ip, dst_port, src_port, client_packets,
             server_packets, client_bytes, server_bytes, server_seen, server_payload_seen,
             client_rst, server_rst, client_fin, server_fin, start_ms, last_ms,
             clienthello_count, clienthello_retransmissions, reason) = cols
        elif version == "v2":
            (_, timestamp, event, flow_id, profile, strategy, generation, scope,
             host, transport, family, dst_ip, dst_port, client_packets, server_packets,
             client_bytes, server_bytes, server_seen, server_payload_seen,
             client_rst, server_rst, client_fin, server_fin, start_ms, last_ms,
             clienthello_count, clienthello_retransmissions, reason) = cols
            src_port = "0"
        else:
            (_, timestamp, event, flow_id, profile, strategy, generation, host,
             transport, family, dst_ip, dst_port, client_packets, server_packets,
             client_bytes, server_bytes, server_seen, server_payload_seen,
             client_rst, server_rst, client_fin, server_fin, start_ms, last_ms,
            clienthello_count, clienthello_retransmissions, reason) = cols
            scope = "unknown"
            src_port = "0"
        if event not in {"FLOW_START", "STRATEGY_APPLIED", "FLOW_END", "STRATEGY_CONFLICT"}:
            continue
        try:
            flow_id_int = int(flow_id)
            strategy_int = int(strategy)
            profile_int = int(profile)
            generation_int = int(generation)
            src_port_int = int(src_port)
        except ValueError as exc:
            raise ValueError(f"line {line_no}: invalid flow/profile/strategy/generation id") from exc
        if not 0 <= src_port_int <= 65535:
            raise ValueError(f"line {line_no}: invalid source port")
        state = flows.setdefault(flow_id, {
            "profile": profile_int, "strategy": strategy_int,
            "generation": generation_int, "host": host, "transport": transport,
            "scope": scope, "family": family, "dst_ip": dst_ip, "dst_port": dst_port,
            "src_port": src_port_int,
            "flow_start_seen": False, "assignment_seen": False,
            "strategy_conflict": False, "identity_conflict": False,
        })
        if (state["transport"], state["family"], state["dst_ip"], state["dst_port"],
                state["src_port"]) != (transport, family, dst_ip, dst_port, src_port_int):
            state["identity_conflict"] = True
        if event == "FLOW_START":
            state["flow_start_seen"] = True
        elif event == "STRATEGY_APPLIED":
            if (state["strategy"] not in (0, strategy_int)
                    or state["profile"] not in (0, profile_int)
                    or state["generation"] not in (0, generation_int)):
                state["strategy_conflict"] = True
            else:
                state.update(profile=profile_int, strategy=strategy_int,
                             generation=generation_int, host=host, scope=scope)
                state["assignment_seen"] = True
        elif event == "STRATEGY_CONFLICT":
            state["strategy_conflict"] = True
        elif event == "FLOW_END":
            if not state["host"] and host:
                # Hostname discovery can happen after immutable strategy assignment.
                state["host"] = host
            elif host and state["host"] != host:
                state["identity_conflict"] = True
            if state["scope"] != scope:
                state["strategy_conflict"] = True
            if state["strategy"]:
                if (state["profile"], state["strategy"], state["generation"]) != (
                        profile_int, strategy_int, generation_int):
                    state["strategy_conflict"] = True
            elif profile_int or strategy_int or generation_int:
                # Attribution appeared without the C-side assignment event.
                state["strategy_conflict"] = True
            server_payload = server_payload_seen == "1"
            evidence = "WEAK_SUCCESS" if server_payload else "UNKNOWN"
            usable = (state["flow_start_seen"] and state["profile"] > 0 and state["strategy"] > 0
                      and state["generation"] > 0 and not state["strategy_conflict"]
                      and not state["identity_conflict"] and state["assignment_seen"]
                      and bool(state["host"]))
            context = (state["profile"], state["host"], state["scope"],
                       state["transport"], state["family"], "unknown_epoch")
            action = "UNATTRIBUTED"
            champion = champions.get(context)
            challenger = None
            independent_observation = False
            if flow_id in seen_flows:
                usable = False
                action = "DUPLICATE_FLOW_IGNORED"
            elif usable:
                seen_flows.add(flow_id)
                stats = candidates[context][state["strategy"]]
                if evidence == "WEAK_SUCCESS":
                    outcome_ms = int(timestamp)
                    last_success_ms = stats["last_success_ms"]
                    independent_observation = (last_success_ms is None or
                                               outcome_ms - last_success_ms >= COHORT_WINDOW_MS)
                    if independent_observation:
                        stats["successes"] += 1
                        stats["last_success_ms"] = outcome_ms
                else:
                    stats["unknown"] += 1
                if champion is None and stats["successes"] >= 2:
                    champion = state["strategy"]
                    champions[context] = champion
                    action = "SHADOW_INITIAL_CHAMPION"
                elif champion is None:
                    action = "CANDIDATE_OBSERVED" if evidence == "WEAK_SUCCESS" else "UNKNOWN_NO_UPDATE"
                elif state["strategy"] == champion:
                    action = "KEEP_CHAMPION" if evidence == "WEAK_SUCCESS" else "UNKNOWN_NO_UPDATE"
                else:
                    challenger = state["strategy"]
                    challenger_stats = candidates[context][challenger]
                    action = ("CHALLENGER_READY" if challenger_stats["successes"] >= 2
                              else "CHALLENGER_OBSERVED")
            elif action == "UNATTRIBUTED":
                action = "UNATTRIBUTED"
            outcomes.append({
                "event": "FLOW_OUTCOME", "flow_id": flow_id_int,
                "timestamp_ms": timestamp, "profile_id": state["profile"],
                "strategy_id": state["strategy"],
                "strategy_generation": state["generation"],
                "hostname": state["host"], "transport": state["transport"],
                "ip_family": state["family"], "dst_ip": state["dst_ip"],
                "dst_port": state["dst_port"], "evidence": evidence,
                "src_port": state["src_port"],
                "scope": state["scope"], "network_epoch": "unknown",
                "context": list(context), "shadow_champion": champion,
                "challenger": challenger, "action": action,
                "independent_observation": independent_observation,
                "independent_successes": (candidates[context][state["strategy"]]["successes"]
                                           if usable else 0),
                "cohort_window_ms": COHORT_WINDOW_MS,
                "attribution_usable": usable,
                "strategy_conflict": state["strategy_conflict"],
                "flow_identity_conflict": state["identity_conflict"],
                "assignment_event_seen": state["assignment_seen"],
                "network_health": "UNKNOWN",
                "progress": {
                    "client_packets": int(client_packets),
                    "server_packets": int(server_packets),
                    "client_payload_bytes": int(client_bytes),
                    "server_payload_bytes": int(server_bytes),
                    "client_rst": client_rst == "1", "server_rst": server_rst == "1",
                    "client_fin": client_fin == "1", "server_fin": server_fin == "1",
                    "clienthello_count": int(clienthello_count),
                    "clienthello_retransmissions": int(clienthello_retransmissions),
                },
                "lifecycle": {"start_monotonic_ms": start_ms,
                              "last_seen_monotonic_ms": last_ms,
                              "termination_reason": reason},
                "decision": "SHADOW_ONLY" if usable else "UNATTRIBUTED",
            })
            flows.pop(flow_id, None)

    for probe in probe_results:
        matches = [outcome for outcome in outcomes
                   if outcome["attribution_usable"] and outcome["scope"] == "learning"
                   and outcome["hostname"].lower() == probe["host"]
                   and outcome["src_port"] == probe["src_port"]
                   and outcome["strategy_id"] == probe["strategy"]
                   and outcome["strategy_generation"] == probe["generation"]]
        if len(matches) == 1:
            status = int(probe["http_status"])
            evidence = ("STRONG_SUCCESS" if probe["curl_rc"] == 0 and
                        100 <= status <= 599 else "UNKNOWN")
            matches[0]["active_probe"] = {
                **probe, "evidence": evidence,
                "correlated_flow_id": matches[0]["flow_id"],
            }
        else:
            outcomes.append({
                "event": "PROBE_UNCORRELATED", **probe,
                "reason": "no_matching_learning_flow" if not matches else "ambiguous_matching_flows",
            })

    for outcome in outcomes:
        print(json.dumps(outcome, separators=(",", ":")))

    if trace_limited or flows:
        print(json.dumps({
            "event": "TRACE_STATUS", "trace_complete": False,
            "termination_reason": "max_bytes" if trace_limited else "missing_flow_end",
            "incomplete_flow_count": len(flows),
        }, separators=(",", ":")))


def read_events(paths):
    with ExitStack() as stack:
        for path in paths:
            if path == "-":
                yield from sys.stdin
            else:
                source = stack.enter_context(open(path, encoding="utf-8"))
                yield from source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("events", nargs="*", help="TSV event files in chronological order (default: stdin)")
    args = parser.parse_args()
    try:
        replay(read_events(args.events or ["-"]))
    except (OSError, ValueError) as exc:
        parser.error(str(exc))


if __name__ == "__main__":
    main()
