#!/usr/bin/env python3
"""Small stdlib guard for the adaptive-result v1 schema contract."""
import json
from pathlib import Path

schema = json.loads((Path(__file__).parents[1] / "docs/adaptive-result-v1.schema.json").read_text())
assert schema["properties"]["schema_version"] == {"const": 1}
assert set(schema["required"]) == set(schema["properties"])
assert schema["properties"]["overall"]["enum"] == ["SUCCESS", "FAIL", "INCONCLUSIVE"]
assert schema["properties"]["transport"]["enum"] == ["OK", "FAIL", "UNKNOWN"]
assert schema["properties"]["application"]["enum"] == ["OK", "FAIL", "NOT_TESTED", "UNKNOWN"]
assert schema["properties"]["recipe_id"]["enum"] == ["tls-http1-v1", "googlevideo-tcp-media-v1", "googlevideo-quic-h3-media-v1"]
assert schema["properties"]["treatment_variant"]["enum"] == ["standard", "gv_tcp_plain", "gv_tcp_ramp", "gv_tcp_ramp_syndata"]
assert schema["properties"]["queue_seen"]["type"] == "boolean"
assert schema["properties"]["strategy_ack_seen"]["type"] == "boolean"
assert schema["properties"]["syn_stage_confirmed"]["type"] == "boolean"
assert schema["properties"]["late_ack_stage_confirmed"]["type"] == "boolean"
assert schema["properties"]["media_bytes"]["maximum"] == 16777216
assert schema["properties"]["media_speed_bps"]["maximum"] == 1073741824
assert schema["properties"]["media_duration_ms"]["maximum"] == 60000
route_verified = next(rule["then"]["properties"] for rule in schema["allOf"] if rule["if"].get("properties", {}).get("route_verified", {}).get("const") is True)
assert route_verified["queue_seen"] == {"const": True}
assert route_verified["strategy_ack_seen"] == {"const": True}
ramp_treatment = next(rule["then"]["properties"] for rule in schema["allOf"] if rule["if"].get("allOf", [{}])[0].get("properties", {}).get("treatment_variant", {}).get("enum") == ["gv_tcp_ramp", "gv_tcp_ramp_syndata"])
assert ramp_treatment["syn_stage_confirmed"] == {"const": True}
assert ramp_treatment["late_ack_stage_confirmed"] == {"const": True}
tls_recipe = next(rule["then"]["properties"] for rule in schema["allOf"] if rule["if"].get("properties", {}).get("recipe_id", {}).get("const") == "tls-http1-v1")
assert tls_recipe["treatment_variant"] == {"const": "standard"}
assert tls_recipe["media_bytes"] == {"const": 0}
media_recipe = next(rule["then"]["properties"] for rule in schema["allOf"] if rule["if"].get("properties", {}).get("recipe_id", {}).get("const") == "googlevideo-tcp-media-v1")
assert media_recipe["target"]["properties"]["profile_id"] == {"const": 2}
quic_recipe = next(rule["then"]["properties"] for rule in schema["allOf"] if rule["if"].get("properties", {}).get("recipe_id", {}).get("const") == "googlevideo-quic-h3-media-v1")
assert quic_recipe["target"]["properties"]["profile_id"] == {"const": 5}
assert quic_recipe["target"]["properties"]["protocol"] == {"const": "udp"}
assert schema["properties"]["target"]["properties"]["protocol"]["enum"] == ["tcp", "udp"]
assert schema["properties"]["target"]["properties"]["port"] == {"const": 443}
assert schema["properties"]["target"]["properties"]["scope"]["pattern"] == r"^(default|mark:[1-9][0-9]{0,4})$"
assert schema["properties"]["strategy"]["properties"]["fingerprint"]["pattern"] == r"^sha256:[0-9a-f]{64}$"
success = next(rule["then"]["properties"] for rule in schema["allOf"] if rule["if"].get("properties", {}).get("overall", {}).get("const") == "SUCCESS")
assert success["route_verified"] == {"const": True}
assert success["transport"] == {"const": "OK"}
assert success["application"] == {"const": "OK"}
failed = next(rule["then"] for rule in schema["allOf"] if rule["if"].get("properties", {}).get("overall", {}).get("const") == "FAIL")
assert failed["properties"]["route_verified"] == {"const": True}
assert failed["anyOf"] == [
    {"properties": {"transport": {"const": "FAIL"}}},
    {"properties": {"application": {"const": "FAIL"}}},
]
print("adaptive result contract smoke ok")
