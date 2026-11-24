#!/usr/bin/env python3
"""Exercise the Ramp stage audit emitted by the Lua desync callback."""
import os
from pathlib import Path
import tempfile

from lupa import LuaRuntime

repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="zator-adaptive-ramp-") as tmp:
    audit = Path(tmp) / "ramp-audit.tsv"
    audit.write_text("1\t0\t0\n")
    root = Path(tmp) / "zator"
    adaptive = root / "extra_strats/cache/adaptive"
    adaptive.mkdir(parents=True)
    (adaptive / "mode").write_text("AUTO\n")
    (adaptive / "apply-default-scope").write_text("1\n")
    targets = Path(tmp) / "ramp-targets.tsv"
    exemptions = Path(tmp) / "ramp-exempt.tsv"
    targets.touch()
    exemptions.touch()
    old_cwd = Path.cwd()
    env_keys = ["WSSIZE_RAMP_LUA", "Z2R_ADAPTIVE_RAMP_AUDIT_PATH", "ZATOR_ROOT",
                "Z2R_ADAPTIVE_RAMP_TARGETS_FILE", "Z2R_ADAPTIVE_RAMP_EXEMPT_FILE"]
    old_env = {key: os.environ.get(key) for key in env_keys}
    try:
        os.environ["WSSIZE_RAMP_LUA"] = str(repo / "lua/wssize-ramp.lua").replace("\\", "/")
        os.environ["Z2R_ADAPTIVE_RAMP_AUDIT_PATH"] = str(audit).replace("\\", "/")
        os.environ["ZATOR_ROOT"] = str(root).replace("\\", "/")
        os.environ["Z2R_ADAPTIVE_RAMP_TARGETS_FILE"] = str(targets).replace("\\", "/")
        os.environ["Z2R_ADAPTIVE_RAMP_EXEMPT_FILE"] = str(exemptions).replace("\\", "/")
        os.chdir(repo)
        LuaRuntime(unpack_returned_tuples=True).execute((repo / "tests/wssize_ramp_smoke.lua").read_text())
        assert audit.read_text() == "1\t1\t1\n", "Ramp stage audit did not persist both confirmed stages"
        (adaptive / "mode").write_text("AGENT_BETA\n")
        audit.write_text("1\t0\t0\n")
        LuaRuntime(unpack_returned_tuples=True).execute((repo / "tests/wssize_ramp_smoke.lua").read_text())
        assert audit.read_text() == "1\t1\t1\n", "legacy Ramp exemption compatibility regressed"
    finally:
        os.chdir(old_cwd)
        for key, value in old_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
print("adaptive Ramp SYN/ACK audit smoke ok")
