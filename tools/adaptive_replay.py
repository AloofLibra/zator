#!/usr/bin/env python3
"""Replay C-owned nfqws2/controller events offline; never contacts live targets.

The current C telemetry can confirm server payload, but silence is not a
reliable strategy failure. This phase therefore emits UNKNOWN for flows with
no server payload and does not rotate or promote on negative evidence. Use
--controller-output to summarize settled active-probe records from shadow.tsv.
Correlated redirect divergence is diagnostic evidence only; it is never a
failure vote without a trusted explicit block signature.
"""

import argparse
from contextlib import ExitStack
import ipaddress
import json
import sys
from collections import defaultdict


FIELDS_BY_VERSION = {"v1": 27, "v2": 28, "v3": 29, "v4": 31}
COHORT_WINDOW_MS = 10_000


def parse_u64(text):
    """Parse one canonical unsigned decimal value from a C journal field."""
    if not text or any(ch < "0" or ch > "9" for ch in text):
        raise ValueError("expected unsigned decimal")
    value = int(text)
    if value > 0xffffffffffffffff:
        raise ValueError("unsigned decimal exceeds uint64")
    return value


def replay_controller_output(stream):
    """Summarize resident-controller output, especially settled active probes."""
    probes = []
    probe_begins = []
    comparative_failures = []
    canary_events = []
    flow_outcomes = []
    integrity_events = []
    header_seen = False
    header_version = None
    header_flow_columns = None
    output_limited = False
    rollback_audit_incomplete_count = 0
    for line_no, raw in enumerate(stream, 1):
        line = raw.rstrip("\r\n")
        if line.startswith("# ADAPTIVE_CONTROLLER_OUTPUT "):
            header_seen = True
            parts = line.split()
            version_field = parts[2] if len(parts) > 2 else ""
            version = version_field[:-1] if version_field.endswith(":") else ""
            try:
                flow_marker = parts.index("FLOW_OUTCOME")
                probe_marker = parts.index("PROBE_OUTCOME", flow_marker + 1)
                flow_columns = probe_marker - flow_marker
                if flow_marker != 3 or flow_columns not in {39, 40, 41}:
                    raise ValueError("invalid flow schema")
            except (ValueError, IndexError):
                flow_columns = None
            if version not in {"v5", "v6", "v7"} or flow_columns is None:
                integrity_events.append({"event": "UNSUPPORTED_CONTROLLER_HEADER",
                                         "line": line_no, "version": version_field or "missing"})
                header_version = None
                header_flow_columns = None
            else:
                if (header_version and
                        (header_version != version or header_flow_columns != flow_columns)):
                    integrity_events.append({"event": "MIXED_CONTROLLER_HEADER_VERSION",
                                             "line": line_no, "previous": header_version,
                                             "current": version})
                header_version = version
                header_flow_columns = flow_columns
            continue
        if line.startswith("# OUTPUT_LIMIT"):
            output_limited = True
            continue
        if not line or line.startswith("#"):
            continue
        cols = line.split("\t")
        if cols[0] in {"TRACE_INCOMPLETE", "CONTROLLER_OVERFLOW", "INPUT_REJECTED",
                       "CANARY_STATE_SAVE_FAILED"}:
            integrity_events.append({"event": cols[0], "fields": cols[1:]})
            continue
        if cols[0] == "PROBE_COMPARATIVE_FAILURE":
            if not header_seen:
                raise ValueError(f"line {line_no}: unsupported comparative failure record")
            if len(cols) != 10 or cols[1] != "v1":
                raise ValueError(f"line {line_no}: unsupported comparative failure record")
            try:
                comparison = {
                    "candidate_probe_id": parse_u64(cols[2]),
                    "control_before_probe_id": parse_u64(cols[3]),
                    "control_after_probe_id": parse_u64(cols[4]),
                    "flow_id": parse_u64(cols[5]), "hostname": cols[6].lower(),
                    "provider_key": cols[7], "strategy_id": parse_u64(cols[8]),
                    "network_epoch": parse_u64(cols[9]),
                }
            except ValueError as exc:
                raise ValueError(f"line {line_no}: invalid comparative failure value") from exc
            if (min(comparison["candidate_probe_id"], comparison["control_before_probe_id"],
                    comparison["control_after_probe_id"], comparison["flow_id"],
                    comparison["strategy_id"]) <= 0 or
                    comparison["control_before_probe_id"] >= comparison["control_after_probe_id"] or
                    not comparison["control_before_probe_id"] < comparison["candidate_probe_id"] <
                    comparison["control_after_probe_id"] or
                    comparison["strategy_id"] >= 0xffffffff or comparison["network_epoch"] <= 0 or
                    not 0 < len(comparison["hostname"]) <= 253 or
                    comparison["hostname"].startswith(".") or comparison["hostname"].endswith(".") or
                    ".." in comparison["hostname"] or
                    any(ch not in "abcdefghijklmnopqrstuvwxyz0123456789.-"
                        for ch in comparison["hostname"]) or
                    not (comparison["provider_key"] in {"unknown", "global"} or
                         (comparison["provider_key"].startswith("asn:") and
                          comparison["provider_key"][4:].isdigit() and
                          1 <= len(comparison["provider_key"][4:]) <= 10 and
                          comparison["provider_key"][4] != "0"))):
                raise ValueError(f"line {line_no}: comparative failure outside allowed bounds")
            comparative_failures.append(comparison)
            continue
        if cols[0] in {"CANARY_SET", "CANARY_SET_PENDING", "CANARY_RESTORED", "CANARY_RESTORE_PENDING", "CANARY_RECONCILE_PENDING", "CANARY_ROLLBACK", "CANARY_CLEAR"}:
            if not header_seen:
                raise ValueError(f"line {line_no}: unsupported canary event")
            values = {}
            for item in cols[1:]:
                if "=" not in item:
                    raise ValueError(f"line {line_no}: malformed canary event field")
                key, value = item.split("=", 1)
                if not key or key in values:
                    raise ValueError(f"line {line_no}: duplicate canary event field")
                values[key] = value
            required = {
                "CANARY_SET": {"profile", "host", "strategy", "active_successes", "runnerup", "epoch"},
                "CANARY_SET_PENDING": {"profile", "host", "strategy", "active_successes", "runnerup", "epoch", "reason"},
                "CANARY_RESTORED": {"profile", "host", "strategy", "epoch"},
                "CANARY_RESTORE_PENDING": {"profile", "host", "strategy", "epoch", "reason"},
                "CANARY_RECONCILE_PENDING": {"profile", "host", "strategy", "epoch", "reason"},
                "CANARY_CLEAR": {"profile", "host", "strategy", "generation", "epoch", "reason"},
                "CANARY_ROLLBACK": {"profile", "host", "strategy", "generation", "epoch",
                                    "flow_id", "flows", "reason"},
            }[cols[0]]
            optional = (({"selection"} if cols[0] in {"CANARY_SET", "CANARY_SET_PENDING"} else set()) |
                        ({"flow_ids", "evidence_ms", "rollback_ms"}
                         if cols[0] == "CANARY_ROLLBACK" else set()))
            if not required.issubset(values) or not set(values).issubset(required | optional):
                raise ValueError(f"line {line_no}: unexpected canary event fields")
            if cols[0] == "CANARY_ROLLBACK" and (set(values) & optional) not in (set(), optional):
                raise ValueError(f"line {line_no}: incomplete canary rollback audit fields")
            try:
                event = {"event": cols[0], "profile_id": parse_u64(values["profile"]),
                         "hostname": values["host"].lower(),
                         "strategy_id": parse_u64(values["strategy"]),
                         "network_epoch": parse_u64(values["epoch"])}
                if cols[0] in {"CANARY_SET", "CANARY_SET_PENDING"}:
                    event.update({"active_successes": parse_u64(values["active_successes"]),
                                  "runnerup": parse_u64(values["runnerup"])})
                    if "selection" in values:
                        if values["selection"] not in {"active_success_lead", "lower_injection_cost"}:
                            raise ValueError("unsupported canary selection reason")
                        event["selection"] = values["selection"]
                    if cols[0] == "CANARY_SET_PENDING":
                        event["reason"] = values["reason"]
                elif cols[0] in {"CANARY_RESTORE_PENDING", "CANARY_RECONCILE_PENDING"}:
                    event["reason"] = values["reason"]
                elif cols[0] == "CANARY_ROLLBACK":
                    evidence_ids = values.get("flow_ids")
                    evidence_ms = values.get("evidence_ms")
                    event.update({"strategy_generation": parse_u64(values["generation"]),
                                  "flow_id": parse_u64(values["flow_id"]),
                                  "distinct_flows": parse_u64(values["flows"]),
                                  "evidence_flow_ids_recorded": evidence_ids is not None,
                                  "evidence_flow_ids": ([parse_u64(flow_id) for flow_id in
                                                         evidence_ids.split(",")]
                                                        if evidence_ids is not None else []),
                                  "evidence_ms_recorded": evidence_ms is not None,
                                  "evidence_ms": ([parse_u64(stamp) for stamp in evidence_ms.split(",")]
                                                  if evidence_ms is not None else []),
                                  "rollback_ms": parse_u64(values["rollback_ms"])
                                                  if "rollback_ms" in values else None,
                                  "reason": values["reason"]})
                elif cols[0] == "CANARY_CLEAR":
                    event.update({"strategy_generation": parse_u64(values["generation"]),
                                  "reason": values["reason"]})
            except (KeyError, ValueError) as exc:
                raise ValueError(f"line {line_no}: invalid canary event value") from exc
            host = event["hostname"]
            strategy_id_valid = (0 <= event["strategy_id"] <= 0xffffffff if cols[0] in {"CANARY_CLEAR", "CANARY_RECONCILE_PENDING"}
                                 else 0 < event["strategy_id"] <= 0xffffffff)
            if (event["profile_id"] != 1 or not strategy_id_valid or
                    not 0 < len(host) <= 253 or host.startswith(".") or host.endswith(".") or
                    ".." in host or any(ch not in "abcdefghijklmnopqrstuvwxyz0123456789.-" for ch in host) or
                    (event["network_epoch"] <= 0 and cols[0] not in {"CANARY_CLEAR", "CANARY_RECONCILE_PENDING"})):
                raise ValueError(f"line {line_no}: canary event outside allowed bounds")
            if cols[0] == "CANARY_CLEAR" and (
                    event["strategy_id"] > 0xffffffff or
                    (event["strategy_id"] == 0) != (event["reason"] == "controller_reconcile") or
                    event["reason"] not in {"network_snapshot_unavailable", "network_epoch_changed", "network_degraded", "controller_reconcile"}):
                raise ValueError(f"line {line_no}: invalid canary clear record")
            if cols[0] == "CANARY_RESTORE_PENDING" and event["reason"] != "control_ack_failed":
                raise ValueError(f"line {line_no}: invalid pending canary restore")
            if cols[0] == "CANARY_RECONCILE_PENDING" and event["reason"] != "control_unavailable":
                raise ValueError(f"line {line_no}: invalid pending canary reconciliation")
            if cols[0] == "CANARY_ROLLBACK" and (
                    event["strategy_generation"] <= 0 or event["flow_id"] <= 0 or
                    event["distinct_flows"] != 3 or
                    (event["evidence_flow_ids_recorded"] and
                     (len(event["evidence_flow_ids"]) != event["distinct_flows"] or
                      len(set(event["evidence_flow_ids"])) != event["distinct_flows"] or
                      any(flow_id <= 0 for flow_id in event["evidence_flow_ids"]) or
                      event["flow_id"] != event["evidence_flow_ids"][-1])) or
                    (event["evidence_ms_recorded"] and
                     (len(event["evidence_ms"]) != event["distinct_flows"] or
                      any(stamp < 0 for stamp in event["evidence_ms"]) or
                      event["evidence_ms"] != sorted(event["evidence_ms"]) or
                      event["rollback_ms"] != event["evidence_ms"][-1] or
                      event["evidence_ms"][-1] - event["evidence_ms"][0] > 600000)) or
                    event["reason"] != "server_rst_before_payload"):
                raise ValueError(f"line {line_no}: invalid canary rollback evidence")
            if cols[0] == "CANARY_SET_PENDING" and (
                    event["active_successes"] < 0 or event["runnerup"] < 0 or
                    event["reason"] != "control_ack_failed"):
                raise ValueError(f"line {line_no}: invalid pending canary assignment")
            canary_events.append(event)
            continue
        if cols[0] == "FLOW_OUTCOME":
            if not header_seen or len(cols) not in {39, 40, 41}:
                raise ValueError(f"line {line_no}: unsupported FLOW_OUTCOME record")
            if header_flow_columns is not None and len(cols) != header_flow_columns:
                integrity_events.append({"event": "FLOW_SCHEMA_MISMATCH", "line": line_no,
                                         "header_version": header_version,
                                         "columns": len(cols),
                                         "expected_columns": header_flow_columns})
            try:
                number = {index: parse_u64(cols[index]) for index in
                          (1, 2, 3, 4, 10, 11, 12, 13, 14, 23, 24, 25, 26,
                           33, 34, 35, 36, 38)}
                if len(cols) >= 40:
                    number[39] = parse_u64(cols[39])
                epoch = None if cols[20] == "unknown" else parse_u64(cols[20])
                if epoch == 0:
                    raise ValueError("network epoch must be positive")
                boolean_fields = cols[27:33]
                if any(value not in {"0", "1"} for value in boolean_fields):
                    raise ValueError("invalid flow boolean")
                flow = {
                    "event": "FLOW_OUTCOME", "flow_id": number[1],
                    "profile_id": number[2], "strategy_id": number[3],
                    "strategy_generation": number[4], "evidence": cols[5],
                    "hostname": cols[6].lower(), "action": cols[9],
                    "independent": number[10], "confidence_lcb95_milli": number[11],
                    "rank": number[12], "candidate_count": number[13],
                    "top_strategy": number[14], "quarantine": cols[15],
                    "decision": cols[16], "scope": cols[17], "transport": cols[18],
                    "ip_family": cols[19], "network_epoch": epoch,
                    "network_health": cols[21], "network_health_reason": cols[22],
                    "progress": {
                        "client_packets": number[23], "server_packets": number[24],
                        "client_bytes": number[25], "server_bytes": number[26],
                        "server_seen": cols[27] == "1", "server_payload_seen": cols[28] == "1",
                        "client_rst": cols[29] == "1", "server_rst": cols[30] == "1",
                        "client_fin": cols[31] == "1", "server_fin": cols[32] == "1",
                        "start_ms": number[33], "last_seen_ms": number[34],
                        "clienthello_count": number[35],
                        "clienthello_retransmissions": number[36],
                    },
                    "termination_reason": cols[37], "source_port": number[38],
                    "dst_port": number[39] if len(cols) >= 40 else None,
                    "dst_ip": cols[40] if len(cols) == 41 else None,
                }
            except ValueError as exc:
                raise ValueError(f"line {line_no}: invalid FLOW_OUTCOME value") from exc
            flags = cols[10:11] + cols[27:33]
            unassigned = (flow["profile_id"] == 0 and flow["strategy_id"] == 0 and
                          flow["strategy_generation"] == 0 and
                          flow["action"] == "UNATTRIBUTED" and
                          flow["decision"] == "UNATTRIBUTED")
            if (flow["flow_id"] <= 0 or (flow["profile_id"] <= 0 and not unassigned) or
                    not 0 <= flow["strategy_id"] <= 0xffffffff or
                    flow["strategy_generation"] < 0 or flow["independent"] not in {0, 1} or
                    (flow["hostname"] and
                     (not 0 < len(flow["hostname"]) <= 253 or
                      flow["hostname"].startswith(".") or flow["hostname"].endswith(".") or
                      ".." in flow["hostname"] or
                      any(ch not in "abcdefghijklmnopqrstuvwxyz0123456789.-"
                          for ch in flow["hostname"]))) or
                    flow["ip_family"] not in {"ipv4", "ipv6", "unknown"} or
                    flow["transport"] not in {"tcp", "udp", "quic", "unknown"} or
                    flow["network_health"] not in {"UNKNOWN", "DEGRADED"} or
                    flow["progress"]["last_seen_ms"] < flow["progress"]["start_ms"] or
                    flow["progress"]["clienthello_retransmissions"] >
                    flow["progress"]["clienthello_count"] or
                    not 0 <= flow["source_port"] <= 65535 or
                    (flow["dst_port"] is not None and not 0 <= flow["dst_port"] <= 65535)):
                raise ValueError(f"line {line_no}: FLOW_OUTCOME outside allowed bounds")
            if flow["dst_ip"] is not None and flow["dst_ip"]:
                try:
                    parsed_ip = ipaddress.ip_address(flow["dst_ip"])
                except ValueError as exc:
                    raise ValueError(f"line {line_no}: invalid FLOW_OUTCOME destination IP") from exc
                if ((flow["ip_family"] == "ipv4" and parsed_ip.version != 4) or
                        (flow["ip_family"] == "ipv6" and parsed_ip.version != 6) or
                        flow["ip_family"] not in {"ipv4", "ipv6"}):
                    raise ValueError(f"line {line_no}: destination IP family mismatch")
            flow_outcomes.append(flow)
            continue
        if cols[0] == "PROBE_BEGIN":
            if not header_seen or len(cols) != 7:
                raise ValueError(f"line {line_no}: unsupported PROBE_BEGIN record")
            try:
                event = {"event": "PROBE_BEGIN", "probe_id": parse_u64(cols[1]),
                         "hostname": cols[2].lower(), "source_port": parse_u64(cols[3]),
                         "profile_id": parse_u64(cols[4]), "strategy_id": parse_u64(cols[5]),
                         "strategy_generation": parse_u64(cols[6])}
            except ValueError as exc:
                raise ValueError(f"line {line_no}: invalid PROBE_BEGIN value") from exc
            host = event["hostname"]
            if (event["probe_id"] <= 0 or event["profile_id"] != 1 or
                    not 0 < event["strategy_id"] <= 0xffffffff or
                    event["strategy_generation"] <= 0 or
                    not 62000 <= event["source_port"] <= 62015 or
                    not 0 < len(host) <= 253 or host.startswith(".") or host.endswith(".") or
                    ".." in host or any(ch not in "abcdefghijklmnopqrstuvwxyz0123456789.-" for ch in host)):
                raise ValueError(f"line {line_no}: PROBE_BEGIN outside allowed bounds")
            probe_begins.append(event)
            continue
        if cols[0] != "PROBE_OUTCOME":
            integrity_events.append({"event": "UNRECOGNIZED_RECORD",
                                     "line": line_no, "record_type": cols[0]})
            continue
        if not header_seen:
            raise ValueError(f"line {line_no}: unsupported PROBE_OUTCOME record")
        try:
            if ((len(cols) == 38 and cols[1] == "v5") or
                    (len(cols) == 36 and cols[1] == "v4") or
                    (len(cols) == 35 and cols[1] == "v3")):
                has_redirect_host = cols[1] in {"v4", "v5"}
                has_body_signature = cols[1] == "v5"
                probe = {
                    "probe_id": int(cols[2]), "outcome": cols[3], "reason": cols[4],
                    "profile_id": int(cols[5]), "strategy_id": int(cols[6]),
                    "strategy_generation": int(cols[7]), "hostname": cols[8].lower(),
                    "source_port": int(cols[9]), "curl_rc": int(cols[10]),
                    "http_status": int(cols[11]), "elapsed_ms": int(cols[12]),
                    "flow_id": int(cols[13]), "network_epoch": int(cols[14]),
                    "transport": cols[15], "ip_family": cols[16],
                    "network_health": cols[17], "network_health_reason": int(cols[18]),
                    "network_context_usable": cols[19] == "1",
                    "flow_metrics_seen": cols[20] == "1",
                    "flow_metrics": {
                        "client_packets": int(cols[21]), "server_packets": int(cols[22]),
                        "client_bytes": int(cols[23]), "server_bytes": int(cols[24]),
                        "server_seen": cols[25] == "1", "server_payload_seen": cols[26] == "1",
                        "client_rst": cols[27] == "1", "server_rst": cols[28] == "1",
                        "client_fin": cols[29] == "1", "server_fin": cols[30] == "1",
                        "clienthello_count": int(cols[31]),
                        "clienthello_retransmissions": int(cols[32]),
                    },
                    "termination_reason": cols[33], "provider_key": cols[34],
                    "redirect_host": cols[35] if has_redirect_host else "none",
                    "body_sample_bytes": int(cols[36]) if has_body_signature else 0,
                    "block_body_marker": cols[37] if has_body_signature else "none",
                }
                if not (probe["provider_key"] == "unknown" or
                        (probe["provider_key"].startswith("asn:") and
                         probe["provider_key"][4:].isdigit() and
                         1 <= len(probe["provider_key"][4:]) <= 10 and
                         probe["provider_key"][4] != "0")):
                    raise ValueError("invalid provider key")
                flag_cols = cols[19:21] + cols[25:27] + cols[27:31]
                if any(flag not in {"0", "1"} for flag in flag_cols):
                    raise ValueError("invalid boolean field")
                context_flag = cols[19]
            elif len(cols) == 34 and cols[1] == "v2":
                probe = {
                    "probe_id": int(cols[2]), "outcome": cols[3], "reason": cols[4],
                    "profile_id": int(cols[5]), "strategy_id": int(cols[6]),
                    "strategy_generation": int(cols[7]), "hostname": cols[8].lower(),
                    "source_port": int(cols[9]), "curl_rc": int(cols[10]),
                    "http_status": int(cols[11]), "elapsed_ms": int(cols[12]),
                    "flow_id": int(cols[13]), "network_epoch": int(cols[14]),
                    "transport": cols[15], "ip_family": cols[16],
                    "network_health": cols[17], "network_health_reason": int(cols[18]),
                    "network_context_usable": cols[19] == "1",
                    "flow_metrics_seen": cols[20] == "1",
                    "flow_metrics": {
                        "client_packets": int(cols[21]), "server_packets": int(cols[22]),
                        "client_bytes": int(cols[23]), "server_bytes": int(cols[24]),
                        "server_seen": cols[25] == "1", "server_payload_seen": cols[26] == "1",
                        "client_rst": cols[27] == "1", "server_rst": cols[28] == "1",
                        "client_fin": cols[29] == "1", "server_fin": cols[30] == "1",
                        "clienthello_count": int(cols[31]),
                        "clienthello_retransmissions": int(cols[32]),
                    },
                    "termination_reason": cols[33],
                }
                probe["provider_key"] = "unknown"
                flag_cols = cols[19:21] + cols[25:27] + cols[27:31]
                if any(flag not in {"0", "1"} for flag in flag_cols):
                    raise ValueError("invalid boolean field")
                context_flag = cols[19]
            elif len(cols) == 20 and cols[1] == "v1":
                probe = {
                    "probe_id": int(cols[2]), "outcome": cols[3], "reason": cols[4],
                    "profile_id": int(cols[5]), "strategy_id": int(cols[6]),
                    "strategy_generation": int(cols[7]), "hostname": cols[8].lower(),
                    "source_port": int(cols[9]), "curl_rc": int(cols[10]),
                    "http_status": int(cols[11]), "elapsed_ms": int(cols[12]),
                    "flow_id": int(cols[13]), "network_epoch": int(cols[14]),
                    "transport": cols[15], "ip_family": cols[16],
                    "network_health": cols[17], "network_health_reason": int(cols[18]),
                    "network_context_usable": cols[19] == "1",
                }
                probe["flow_metrics_seen"] = False
                probe["flow_metrics"] = None
                probe["termination_reason"] = "unknown"
                probe["provider_key"] = "unknown"
                context_flag = cols[19]
            elif len(cols) == 13:
                # beta.3 journal rows predate the versioned network context.
                probe = {
                    "probe_id": int(cols[1]), "outcome": cols[2], "reason": cols[3],
                    "profile_id": int(cols[4]), "strategy_id": int(cols[5]),
                    "strategy_generation": int(cols[6]), "hostname": cols[7].lower(),
                    "source_port": int(cols[8]), "curl_rc": int(cols[9]),
                    "http_status": int(cols[10]), "elapsed_ms": int(cols[11]),
                    "flow_id": int(cols[12]), "network_epoch": 0,
                    "transport": "tcp", "ip_family": "unknown",
                    "network_health": "UNKNOWN", "network_health_reason": 0,
                    "network_context_usable": False,
                }
                probe["flow_metrics_seen"] = False
                probe["flow_metrics"] = None
                probe["termination_reason"] = "unknown"
                probe["provider_key"] = "unknown"
                context_flag = "0"
            else:
                raise ValueError("unsupported record version")
        except (ValueError, IndexError) as exc:
            raise ValueError(f"line {line_no}: invalid PROBE_OUTCOME value") from exc
        if (probe["outcome"] not in {"STRONG_SUCCESS", "UNKNOWN", "CONTROL_SUCCESS", "CONTROL_UNKNOWN"} or
                probe["probe_id"] <= 0 or probe["profile_id"] <= 0 or
                probe["strategy_id"] <= 0 or probe["strategy_generation"] <= 0 or
                (probe["outcome"].startswith("CONTROL_") !=
                 (probe["strategy_id"] == 0xffffffff)) or
                not probe["hostname"] or not 62000 <= probe["source_port"] <= 62015 or
                probe["curl_rc"] < 0 or not 0 <= probe["http_status"] <= 599 or
                probe["elapsed_ms"] < 0 or probe["flow_id"] < 0 or
                probe["network_epoch"] < 0 or context_flag not in {"0", "1"}):
            raise ValueError(f"line {line_no}: PROBE_OUTCOME value outside allowed bounds")
        if cols[1] == "v5" and probe["outcome"] in {"STRONG_SUCCESS", "CONTROL_SUCCESS"}:
            expected_reason = ("HTTP_RESPONSE_AND_C_FLOW" if probe["outcome"] == "STRONG_SUCCESS"
                               else "NO_STRATEGY_HTTP_RESPONSE")
            if (probe["reason"] != expected_reason or probe["curl_rc"] != 0 or
                    not 100 <= probe["http_status"] <= 599 or probe["flow_id"] <= 0 or
                    not probe["network_context_usable"] or not probe["flow_metrics_seen"] or
                    probe["transport"] != "tcp" or
                    probe["ip_family"] not in {"ipv4", "ipv6"}):
                raise ValueError(f"line {line_no}: success lacks correlated HTTP and C evidence")
        metrics = probe["flow_metrics"]
        redirect_host = probe.get("redirect_host", "none")
        if redirect_host != "none" and not (
                0 < len(redirect_host) <= 253 and
                all(ch in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"
                    for ch in redirect_host) and
                not redirect_host.startswith(".") and not redirect_host.endswith(".") and
                ".." not in redirect_host):
            raise ValueError(f"line {line_no}: invalid redirect host")
        if (not 0 <= probe.get("body_sample_bytes", 0) <= 16384 or
                probe.get("block_body_marker", "none") not in {
                    "ov.google.com", "blocked.mgts.ru", "warning.rt.ru",
                    "block.mts.ru", "zapret.mts.ru",
                    "none", "eais.rkn.gov.ru", "vigruzki.rkn.gov.ru",
                    "blocklist.rkn.gov.ru", "reestr.rublacklist.net", "nap.rkn.gov.ru",
                    "zapret-info.gov.ru", "blacklist.rkn.gov.ru", "rkn.megafon.ru",
                    "blocked.beeline.ru", "block.beeline.ru", "blocked.tele2.ru",
                    "restriction.tele2.ru", "blocked.yota.ru", "blocking.ttk.ru",
                    "block.ttk.ru", "blocked.domru.ru", "block.domru.ru",
                    "blocked.2kom.ru", "blocked.ugmk-telecom.ru",
                }):
            raise ValueError(f"line {line_no}: invalid bounded body signature")
        has_body_marker = probe.get("block_body_marker", "none") != "none"
        if (has_body_marker != (probe["reason"] == "KNOWN_BLOCK_BODY_MARKER") or
                (has_body_marker and probe.get("body_sample_bytes", 0) == 0)):
            raise ValueError(f"line {line_no}: inconsistent bounded body marker")
        if metrics is not None and any(value < 0 for name, value in metrics.items()
                                       if name.endswith("packets") or name.endswith("bytes") or
                                       name in {"clienthello_count", "clienthello_retransmissions"}):
            raise ValueError(f"line {line_no}: negative flow metric")
        if metrics is not None and probe["flow_metrics_seen"]:
            facts = []
            if metrics["client_packets"]:
                facts.append("CLIENT_PACKETS_SEEN")
            if metrics["server_seen"] or metrics["server_packets"]:
                facts.append("SERVER_RESPONSE_SEEN")
            if metrics["server_payload_seen"] or metrics["server_bytes"]:
                facts.append("SERVER_PAYLOAD_SEEN")
            if metrics["client_rst"]:
                facts.append("CLIENT_RST_SEEN")
            if metrics["server_rst"]:
                facts.append("SERVER_RST_SEEN")
            if metrics["client_fin"]:
                facts.append("CLIENT_FIN_SEEN")
            if metrics["server_fin"]:
                facts.append("SERVER_FIN_SEEN")
            if metrics["clienthello_retransmissions"]:
                facts.append("CLIENTHELLO_RETRANSMISSION_SEEN")
            if metrics["client_packets"] and not metrics["server_packets"]:
                facts.append("CLIENT_ACTIVITY_WITHOUT_SERVER_PACKETS")
            probe["packet_evidence"] = facts
        else:
            probe["packet_evidence"] = ["C_FLOW_METRICS_UNAVAILABLE"]
        curl_diagnostics = {
            6: "DNS_RESOLUTION_ERROR", 7: "CONNECT_ERROR", 28: "CURL_TIMEOUT",
            35: "TLS_HANDSHAKE_ERROR", 52: "EMPTY_SERVER_REPLY",
            56: "RECEIVE_ERROR", 60: "TLS_CERTIFICATE_ERROR",
        }
        if probe["curl_rc"] == 0:
            probe["curl_diagnostic"] = ("HTTP_RESPONSE" if 100 <= probe["http_status"] <= 599
                                        else "HTTP_STATUS_MISSING")
        else:
            probe["curl_diagnostic"] = curl_diagnostics.get(probe["curl_rc"], "CURL_ERROR")
        probes.append(probe)

    begins_by_id = defaultdict(list)
    outcomes_by_id = defaultdict(list)
    for event in probe_begins:
        begins_by_id[event["probe_id"]].append(event)
    for probe in probes:
        outcomes_by_id[probe["probe_id"]].append(probe)
    for probe_id, outcomes in outcomes_by_id.items():
        if len(outcomes) > 1 and probe_id not in begins_by_id:
            integrity_events.append({"event": "AMBIGUOUS_PROBE_JOURNAL_JOIN",
                                     "probe_id": probe_id, "begin_records": 0,
                                     "outcome_records": len(outcomes)})
    for probe_id, begins in begins_by_id.items():
        outcomes = outcomes_by_id.get(probe_id, [])
        if len(begins) != 1 or len(outcomes) > 1:
            integrity_events.append({"event": "AMBIGUOUS_PROBE_JOURNAL_JOIN",
                                     "probe_id": probe_id,
                                     "begin_records": len(begins),
                                     "outcome_records": len(outcomes)})
        elif not outcomes:
            integrity_events.append({"event": "UNSETTLED_PROBE_BEGIN",
                                     "probe_id": probe_id})
        else:
            begin, outcome = begins[0], outcomes[0]
            if any(begin[key] != outcome[target] for key, target in (
                    ("hostname", "hostname"), ("source_port", "source_port"),
                    ("profile_id", "profile_id"), ("strategy_id", "strategy_id"),
                    ("strategy_generation", "strategy_generation"))):
                integrity_events.append({"event": "PROBE_ATTRIBUTION_MISMATCH",
                                         "probe_id": probe_id})

    for comparison in comparative_failures:
        candidate_rows = outcomes_by_id.get(comparison["candidate_probe_id"], [])
        before_rows = outcomes_by_id.get(comparison["control_before_probe_id"], [])
        after_rows = outcomes_by_id.get(comparison["control_after_probe_id"], [])
        status = "MATCHED"
        if len(candidate_rows) != 1 or len(before_rows) != 1 or len(after_rows) != 1:
            status = "PROBE_ROWS_MISSING_OR_AMBIGUOUS"
        else:
            candidate, before, after = candidate_rows[0], before_rows[0], after_rows[0]
            candidate_matches = (
                candidate["outcome"] == "UNKNOWN" and
                candidate["flow_id"] == comparison["flow_id"] and
                candidate["hostname"] == comparison["hostname"] and
                candidate["profile_id"] == 1 and
                candidate["strategy_id"] == comparison["strategy_id"] and
                candidate["provider_key"] == comparison["provider_key"] and
                candidate["network_epoch"] == comparison["network_epoch"] and
                candidate["transport"] == "tcp" and
                candidate["ip_family"] in {"ipv4", "ipv6"} and
                candidate["network_context_usable"] and candidate["flow_metrics_seen"] and
                candidate["flow_metrics"]["client_packets"] > 0)
            controls_match = all(
                control["outcome"] == "CONTROL_SUCCESS" and
                control["strategy_id"] == 4294967295 and control["hostname"] == comparison["hostname"] and
                control["profile_id"] == 1 and control["provider_key"] == comparison["provider_key"] and
                control["network_epoch"] == comparison["network_epoch"] and
                control["transport"] == "tcp" and
                control["ip_family"] == candidate["ip_family"] and
                control["network_context_usable"]
                for control in (before, after))
            if not candidate_matches or not controls_match:
                status = "PROBE_FACTS_MISMATCH"
        comparison["audit_status"] = status
        if status != "MATCHED":
            integrity_events.append({"event": "COMPARATIVE_FAILURE_AUDIT_INCOMPLETE",
                                     "candidate_probe_id": comparison["candidate_probe_id"],
                                     "status": status})

    groups = defaultdict(lambda: {"attempts": 0, "strong_success": 0,
                                  "unknown": 0, "elapsed_ms": []})
    host_groups = defaultdict(lambda: {"attempts": 0, "strong_success": 0,
                                       "unknown": 0, "strategies": set()})
    provider_groups = defaultdict(lambda: {
        "hosts_tested": set(), "hosts_success": set(), "attempts": 0,
        "strong_success": 0, "unknown": 0, "first_probe_success": 0,
        "first_probe_hosts": 0, "first_probe_unknown": 0, "strategies": {},
    })
    control_groups = defaultdict(lambda: {"attempts": 0, "success": 0, "unknown": 0})
    comparative_by_provider_strategy = defaultdict(set)
    for failure in comparative_failures:
        if failure.get("audit_status") != "MATCHED":
            continue
        key = (failure["provider_key"], failure["strategy_id"])
        # The resident C prior is deduplicated by host/strategy. Keep replay
        # summaries on the same unit even when a host has multiple brackets.
        comparative_by_provider_strategy[key].add(failure["hostname"])
    for failure in comparative_failures:
        print(json.dumps({
            "event": "PROBE_COMPARATIVE_FAILURE",
            "evidence": "BRACKETED_NO_STRATEGY_CONTROLS",
            **failure, "failure_votes": int(failure.get("audit_status") == "MATCHED"),
        }, separators=(",", ":")))
    bracketed_probe_ids = {failure["candidate_probe_id"] for failure in comparative_failures
                           if failure.get("audit_status") == "MATCHED"}
    for probe in probes:
        if probe["reason"] == "KNOWN_BLOCK_REDIRECT":
            print(json.dumps({
                "event": "EXPLICIT_BLOCK_REDIRECT",
                "evidence": "EXACT_KNOWN_ISP_REDIRECT_HOST",
                "probe_id": probe["probe_id"], "flow_id": probe["flow_id"],
                "hostname": probe["hostname"], "provider_key": probe["provider_key"],
                "network_epoch": probe["network_epoch"],
                "strategy_id": probe["strategy_id"],
                "redirect_host": probe.get("redirect_host", "none"),
                "bracketed_strategy_failure": probe["probe_id"] in bracketed_probe_ids,
                "failure_votes": 0,
            }, separators=(",", ":")))
        elif probe["reason"] == "KNOWN_BLOCK_BODY_MARKER":
            print(json.dumps({
                "event": "EXPLICIT_BLOCK_BODY_MARKER",
                "evidence": "EXACT_KNOWN_ISP_DOMAIN_IN_BOUNDED_BODY_SAMPLE",
                "probe_id": probe["probe_id"], "flow_id": probe["flow_id"],
                "hostname": probe["hostname"], "provider_key": probe["provider_key"],
                "network_epoch": probe["network_epoch"],
                "strategy_id": probe["strategy_id"],
                "body_sample_bytes": probe.get("body_sample_bytes", 0),
                "marker": probe.get("block_body_marker", "none"),
                "bracketed_strategy_failure": probe["probe_id"] in bracketed_probe_ids,
                "failure_votes": 0,
            }, separators=(",", ":")))
    redirect_controls = {}
    redirect_candidates = defaultdict(list)
    for probe in probes:
        context = (probe["profile_id"], probe["hostname"], probe["provider_key"],
                   probe["transport"], probe["ip_family"], probe["network_epoch"])
        if probe["outcome"] == "CONTROL_UNKNOWN":
            redirect_controls.pop(context, None)
            redirect_candidates.pop(context, None)
        elif probe["outcome"] == "CONTROL_SUCCESS":
            before = redirect_controls.get(context)
            if before:
                if before.get("redirect_host", "none") == probe.get("redirect_host", "none"):
                    for candidate in redirect_candidates.pop(context, []):
                        redirect_host = candidate.get("redirect_host", "none")
                        if (candidate["flow_id"] > 0 and redirect_host != "none" and
                                redirect_host != before.get("redirect_host", "none")):
                            print(json.dumps({
                                "event": "PROBE_REDIRECT_DIVERGENCE",
                                "evidence": "C_FLOW_CORRELATED_CONTROL_BRACKET",
                                "candidate_probe_id": candidate["probe_id"],
                                "control_before_probe_id": before["probe_id"],
                                "control_after_probe_id": probe["probe_id"],
                                "flow_id": candidate["flow_id"],
                                "hostname": candidate["hostname"],
                                "provider_key": candidate["provider_key"],
                                "network_epoch": candidate["network_epoch"],
                                "strategy_id": candidate["strategy_id"],
                                "control_redirect_host": before.get("redirect_host", "none"),
                                "candidate_redirect_host": redirect_host,
                                "failure_votes": 0,
                            }, separators=(",", ":")))
                else:
                    redirect_candidates.pop(context, None)
            redirect_controls[context] = probe
        elif probe["outcome"] == "STRONG_SUCCESS":
            if context in redirect_controls:
                redirect_candidates[context].append(probe)
    first_provider_probe = set()
    for probe in probes:
        if probe["outcome"].startswith("CONTROL_"):
            provider_key = probe["provider_key"]
            control_stats = control_groups[provider_key]
            control_stats["attempts"] += 1
            if probe["outcome"] == "CONTROL_SUCCESS":
                control_stats["success"] += 1
            else:
                control_stats["unknown"] += 1
            print(json.dumps({
                "event": "CONTROL_PROBE_OUTCOME", **probe,
                "strategy_semantics": "NO_DESYNC",
                "failure_votes": 0,
            }, separators=(",", ":")))
            continue
        key = (probe["profile_id"], probe["hostname"], probe["transport"],
               probe["ip_family"], probe["network_epoch"], probe["strategy_id"])
        host_key = key[:-1]
        stats = groups[key]
        host_stats = host_groups[host_key]
        stats["attempts"] += 1
        host_stats["attempts"] += 1
        host_stats["strategies"].add(probe["strategy_id"])
        provider_key = probe["provider_key"]
        if provider_key != "unknown":
            provider_stats = provider_groups[provider_key]
            candidate_stats = provider_stats["strategies"].setdefault(
                probe["strategy_id"], {
                    "hosts_tested": set(), "hosts_success": set(),
                    "attempts": 0, "success": 0, "unknown": 0,
                })
            provider_host = (provider_key, probe["hostname"])
            provider_stats["hosts_tested"].add(probe["hostname"])
            provider_stats["attempts"] += 1
            candidate_stats["hosts_tested"].add(probe["hostname"])
            candidate_stats["attempts"] += 1
            if probe["outcome"] == "STRONG_SUCCESS":
                provider_stats["hosts_success"].add(probe["hostname"])
                provider_stats["strong_success"] += 1
                candidate_stats["hosts_success"].add(probe["hostname"])
                candidate_stats["success"] += 1
            else:
                provider_stats["unknown"] += 1
                candidate_stats["unknown"] += 1
            if provider_host not in first_provider_probe:
                first_provider_probe.add(provider_host)
                provider_stats["first_probe_hosts"] += 1
                provider_stats["first_probe_success"] += int(
                    probe["outcome"] == "STRONG_SUCCESS")
                provider_stats["first_probe_unknown"] += int(
                    probe["outcome"] == "UNKNOWN")
        if probe["outcome"] == "STRONG_SUCCESS":
            stats["strong_success"] += 1
            stats["elapsed_ms"].append(probe["elapsed_ms"])
            host_stats["strong_success"] += 1
        else:
            stats["unknown"] += 1
            host_stats["unknown"] += 1
        print(json.dumps({"event": "PROBE_OUTCOME", **probe}, separators=(",", ":")))

    for event in probe_begins:
        print(json.dumps(event, separators=(",", ":")))

    for key, stats in sorted(groups.items()):
        profile, host, transport, family, epoch, strategy = key
        elapsed = sorted(stats["elapsed_ms"])
        mid = len(elapsed) // 2
        median = (elapsed[mid] if len(elapsed) % 2 else
                  (elapsed[mid - 1] + elapsed[mid]) // 2) if elapsed else None
        print(json.dumps({
            "event": "PROBE_COMPARISON_SUMMARY", "profile_id": profile,
            "hostname": host, "transport": transport, "ip_family": family,
            "network_epoch": epoch, "strategy_id": strategy,
            "attempts": stats["attempts"], "strong_success": stats["strong_success"],
            "unknown": stats["unknown"],
            "probeability": "PROBEABLE" if stats["strong_success"] else "UNKNOWN",
            "median_success_elapsed_ms": median,
            "failure_votes": 0,
        }, separators=(",", ":")))

    for key, stats in sorted(host_groups.items()):
        profile, host, transport, family, epoch = key
        probeability = ("UNKNOWN" if not stats["strong_success"] else
                        "PARTIAL" if stats["unknown"] else "PROBEABLE")
        print(json.dumps({
            "event": "HOST_PROBEABILITY", "profile_id": profile,
            "hostname": host, "transport": transport, "ip_family": family,
            "network_epoch": epoch, "strategies_attempted": sorted(stats["strategies"]),
            "attempts": stats["attempts"], "confirmed_successes": stats["strong_success"],
            "unknown": stats["unknown"], "probeability": probeability,
            "failure_votes": 0,
        }, separators=(",", ":")))

    for provider_key, stats in sorted(provider_groups.items()):
        denominator = stats["first_probe_hosts"]
        print(json.dumps({
            "event": "PROVIDER_PRIOR_SUMMARY", "provider_key": provider_key,
            "unique_hosts_tested": len(stats["hosts_tested"]),
            "unique_hosts_success": len(stats["hosts_success"]),
            "real_attempts": stats["attempts"],
            "real_success": stats["strong_success"],
            "unknown": stats["unknown"],
            "comparative_failure_votes": sum(
                len(votes) for (key, _), votes in comparative_by_provider_strategy.items()
                if key == provider_key),
            "coverage_success_hosts": len(stats["hosts_success"]),
            "coverage_tested_hosts": len(stats["hosts_tested"]),
            "reliability": "UNKNOWN",
            "reliability_reason": "NO_TRUSTED_NEGATIVE_EVIDENCE",
            "first_probe_hosts": denominator,
            "first_probe_confirmed_successes": stats["first_probe_success"],
            "first_probe_unknown": stats["first_probe_unknown"],
            "provider_prediction_hit_rate": None,
            "provider_prediction_status": "NOT_AVAILABLE_NO_FAILURE_CLASSIFIER",
            "failure_votes": 0,
        }, separators=(",", ":")))
        for strategy, candidate in sorted(stats["strategies"].items()):
            print(json.dumps({
                "event": "PROVIDER_STRATEGY_PRIOR_SUMMARY",
                "provider_key": provider_key, "strategy_id": strategy,
                "unique_hosts_tested": len(candidate["hosts_tested"]),
                "unique_hosts_success": len(candidate["hosts_success"]),
                "real_attempts": candidate["attempts"],
                "real_success": candidate["success"],
                "unknown": candidate["unknown"],
                "comparative_failure_votes": len(comparative_by_provider_strategy[
                    (provider_key, strategy)]),
                "reliability": ("COMPARATIVE_EVIDENCE_ONLY" if comparative_by_provider_strategy[
                    (provider_key, strategy)] else "UNKNOWN"),
                "reliability_reason": ("NO_GENERAL_FAILURE_RATE" if comparative_by_provider_strategy[
                    (provider_key, strategy)] else "NO_TRUSTED_NEGATIVE_EVIDENCE"),
                "failure_votes": len(comparative_by_provider_strategy[(provider_key, strategy)]),
            }, separators=(",", ":")))
    for provider_key, stats in sorted(control_groups.items()):
        print(json.dumps({
            "event": "CONTROL_PROBE_SUMMARY", "provider_key": provider_key,
            "synthetic_attempts": stats["attempts"],
            "synthetic_success": stats["success"],
            "unknown": stats["unknown"], "failure_votes": 0,
        }, separators=(",", ":")))

    canary_groups = defaultdict(lambda: {"promotions": 0, "pending_assignments": 0, "restores": 0,
                                         "pending_restorations": 0,
                                         "pending_reconciliations": 0,
                                         "rollbacks": 0, "clears": 0, "rollback_strategies": set(),
                                         "clear_reasons": set()})
    canary_pending_state = defaultdict(lambda: {"assignment": False,
                                                "restoration": False,
                                                "reconciliation": False})
    for event in canary_events:
        key = (event["profile_id"], event["hostname"], event["network_epoch"])
        stats = canary_groups[key]
        pending = canary_pending_state[(event["profile_id"], event["hostname"])]
        if event["event"] == "CANARY_SET":
            stats["promotions"] += 1
            pending["assignment"] = False
            pending["restoration"] = False
            pending["reconciliation"] = False
        elif event["event"] == "CANARY_SET_PENDING":
            stats["pending_assignments"] += 1
            pending["assignment"] = True
        elif event["event"] == "CANARY_RESTORED":
            stats["restores"] += 1
            pending["assignment"] = False
            pending["restoration"] = False
            pending["reconciliation"] = False
        elif event["event"] == "CANARY_RESTORE_PENDING":
            stats["pending_restorations"] += 1
            pending["restoration"] = True
        elif event["event"] == "CANARY_RECONCILE_PENDING":
            stats["pending_reconciliations"] += 1
            pending["reconciliation"] = True
        elif event["event"] == "CANARY_CLEAR":
            stats["clears"] += 1
            stats["clear_reasons"].add(event["reason"])
            pending["assignment"] = False
            pending["restoration"] = False
            pending["reconciliation"] = False
        elif event["event"] == "CANARY_ROLLBACK":
            stats["rollbacks"] += 1
            stats["rollback_strategies"].add(event["strategy_id"])
        else:
            continue
        print(json.dumps(event, separators=(",", ":")))
    for (profile, host, epoch), stats in sorted(canary_groups.items()):
        print(json.dumps({"event": "CANARY_HOST_SUMMARY", "profile_id": profile,
                          "hostname": host, "network_epoch": epoch,
                          "promotions": stats["promotions"],
                          "pending_assignments": stats["pending_assignments"],
                          "restores": stats["restores"],
                          "pending_restorations": stats["pending_restorations"],
                          "pending_reconciliations": stats["pending_reconciliations"],
                          "clears": stats["clears"],
                          "clear_reasons": sorted(stats["clear_reasons"]),
                          "rollbacks": stats["rollbacks"],
                          "rollback_strategies": sorted(stats["rollback_strategies"])},
                         separators=(",", ":")))
    for (profile, host), pending in sorted(canary_pending_state.items()):
        print(json.dumps({"event": "CANARY_PENDING_STATUS", "profile_id": profile,
                          "hostname": host, "assignment_pending": pending["assignment"],
                          "restoration_pending": pending["restoration"],
                          "reconciliation_pending": pending["reconciliation"],
                          "clear": not any(pending.values())}, separators=(",", ":")))

    flows_by_id = defaultdict(list)
    unattributed_flow_count = 0
    for flow in flow_outcomes:
        flows_by_id[flow["flow_id"]].append(flow)
        if flow["profile_id"] == 0:
            unattributed_flow_count += 1
        print(json.dumps(flow, separators=(",", ":")))
    for event in canary_events:
        if event["event"] != "CANARY_ROLLBACK":
            continue
        audit = {"event": "CANARY_ROLLBACK_AUDIT", "hostname": event["hostname"],
                 "network_epoch": event["network_epoch"], "trigger_flow_id": event["flow_id"],
                 "evidence_flow_ids": event["evidence_flow_ids"],
                 "evidence_ms": event["evidence_ms"], "rollback_ms": event["rollback_ms"]}
        if not event["evidence_flow_ids_recorded"]:
            audit["status"] = "EVIDENCE_FLOW_IDS_UNAVAILABLE_OLD_RECORD"
            rollback_audit_incomplete_count += 1
            print(json.dumps(audit, separators=(",", ":")))
            continue
        flow_statuses = []
        for evidence_index, flow_id in enumerate(event["evidence_flow_ids"]):
            matches = flows_by_id.get(flow_id, [])
            if not matches:
                status = "FLOW_NOT_IN_JOURNAL"
            elif len(matches) != 1:
                status = "AMBIGUOUS_FLOW_ID"
            else:
                flow = matches[0]
                facts_match = (
                    flow["profile_id"] == event["profile_id"] and
                    flow["hostname"] == event["hostname"] and
                    flow["strategy_id"] == event["strategy_id"] and
                    flow["strategy_generation"] == event["strategy_generation"] and
                    flow["network_epoch"] == event["network_epoch"] and
                    flow["scope"] == "production_canary" and flow["transport"] == "tcp" and
                    flow["dst_port"] == 443 and flow["progress"]["client_bytes"] > 0 and
                    flow["progress"]["clienthello_count"] > 0 and
                    flow["progress"]["server_rst"] and
                    not flow["progress"]["server_payload_seen"])
                if facts_match and event["evidence_ms_recorded"]:
                    observed_ms = event["evidence_ms"][evidence_index]
                    progress = flow["progress"]
                    # nfqws2 timestamps the packet; the controller timestamps
                    # receipt of FLOW_END. Allow bounded IPC/scheduling delay.
                    time_match = (observed_ms + 1000 >= progress["start_ms"] and
                                  observed_ms <= progress["last_seen_ms"] + 2000)
                    status = "MATCHED" if time_match else "FLOW_TIME_MISMATCH"
                else:
                    status = "MATCHED" if facts_match else "FLOW_FACTS_MISMATCH"
            flow_statuses.append({"flow_id": flow_id, "status": status})
        audit["flows"] = flow_statuses
        facts_matched = all(item["status"] == "MATCHED" for item in flow_statuses)
        if not facts_matched:
            audit["status"] = "INCOMPLETE"
        elif not event["evidence_ms_recorded"]:
            audit["status"] = "EVIDENCE_TIMING_UNAVAILABLE_OLD_RECORD"
        else:
            audit["status"] = "MATCHED"
        if audit["status"] != "MATCHED":
            rollback_audit_incomplete_count += 1
        print(json.dumps(audit, separators=(",", ":")))

    for event in integrity_events:
        print(json.dumps(event, separators=(",", ":")))
    print(json.dumps({
        "event": "CONTROLLER_OUTPUT_STATUS",
        "complete": (header_seen and not output_limited and not integrity_events and
                      rollback_audit_incomplete_count == 0),
        "header_present": header_seen,
        "output_limited": output_limited,
        "attributed_flow_count": len(flow_outcomes) - unattributed_flow_count,
        "unattributed_flow_count": unattributed_flow_count,
        "integrity_event_count": len(integrity_events),
        "rollback_audit_incomplete_count": rollback_audit_incomplete_count,
    }, separators=(",", ":")))


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
        if version == "v4":
            (_, timestamp, event, flow_id, profile, strategy, generation, scope,
             host, transport, family, dst_ip, dst_port, src_port, client_packets,
             server_packets, client_bytes, server_bytes, server_seen, server_payload_seen,
             client_rst, server_rst, client_fin, server_fin, start_ms, last_ms,
             clienthello_count, clienthello_retransmissions, injected_packets,
             injected_bytes, reason) = cols
        elif version == "v3":
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
            injected_packet_count = parse_u64(injected_packets) if version == "v4" else 0
            injected_byte_count = parse_u64(injected_bytes) if version == "v4" else 0
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
                    "strategy_injected_packets": injected_packet_count,
                    "strategy_injected_bytes": injected_byte_count,
                    "strategy_injection_cost_observed": version == "v4",
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

    injection_cost = defaultdict(lambda: {
        "flow_count": 0, "flows_with_injection": 0,
        "injected_packets": 0, "injected_bytes": 0,
        "weak_success_flows": 0,
    })
    for outcome in outcomes:
        progress = outcome.get("progress", {})
        if (outcome.get("event") != "FLOW_OUTCOME" or
                not outcome.get("attribution_usable") or
                not progress.get("strategy_injection_cost_observed")):
            continue
        key = (outcome["hostname"], outcome["scope"], outcome["transport"],
               outcome["ip_family"], outcome["strategy_id"])
        summary = injection_cost[key]
        summary["flow_count"] += 1
        packets = progress["strategy_injected_packets"]
        byte_count = progress["strategy_injected_bytes"]
        if packets or byte_count:
            summary["flows_with_injection"] += 1
        summary["injected_packets"] += packets
        summary["injected_bytes"] += byte_count
        if outcome["evidence"] == "WEAK_SUCCESS":
            summary["weak_success_flows"] += 1
    for key, summary in sorted(injection_cost.items()):
        hostname, scope, transport, family, strategy = key
        print(json.dumps({
            "event": "STRATEGY_COST_OBSERVATION", "hostname": hostname,
            "scope": scope, "transport": transport, "ip_family": family,
            "strategy_id": strategy, **summary,
            "cost_source": "successful_local_rawsend_submissions",
        }, separators=(",", ":")))

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
    parser.add_argument("--controller-output", action="store_true",
                        help="summarize resident controller output including active probe evidence")
    args = parser.parse_args()
    try:
        stream = read_events(args.events or ["-"])
        (replay_controller_output if args.controller_output else replay)(stream)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))


if __name__ == "__main__":
    main()
