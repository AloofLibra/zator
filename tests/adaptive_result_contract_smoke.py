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
assert schema["properties"]["target"]["properties"]["protocol"] == {"const": "tcp"}
assert schema["properties"]["target"]["properties"]["port"] == {"const": 443}
assert schema["properties"]["target"]["properties"]["scope"]["pattern"] == r"^(default|mark:[1-9][0-9]{0,4})$"
assert schema["properties"]["strategy"]["properties"]["fingerprint"]["pattern"] == r"^sha256:[0-9a-f]{64}$"
success = next(rule["then"]["properties"] for rule in schema["allOf"] if rule["if"]["properties"]["overall"]["const"] == "SUCCESS")
assert success["route_verified"] == {"const": True}
assert success["transport"] == {"const": "OK"}
assert success["application"] == {"const": "OK"}
failed = next(rule["then"] for rule in schema["allOf"] if rule["if"]["properties"]["overall"]["const"] == "FAIL")
assert failed["properties"]["route_verified"] == {"const": True}
assert failed["anyOf"] == [
    {"properties": {"transport": {"const": "FAIL"}}},
    {"properties": {"application": {"const": "FAIL"}}},
]
print("adaptive result contract smoke ok")
