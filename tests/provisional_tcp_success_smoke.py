#!/usr/bin/env python3
"""Execute the Lua TCP success/failure detector regression script."""
from pathlib import Path

from lupa import LuaRuntime

repo = Path(__file__).resolve().parents[1]
LuaRuntime(unpack_returned_tuples=True).execute(
    (repo / "tests/provisional_tcp_success.lua").read_text(encoding="utf-8")
)
print("provisional TCP success smoke ok")
