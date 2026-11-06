#!/usr/bin/env python3
"""Exercise the read-only nfqws2 packet observer with synthetic decoded packets."""
from pathlib import Path
import tempfile

from lupa import LuaRuntime

repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="z2r-observer-") as tmp:
    events = Path(tmp) / "events.tsv"
    source = (repo / "orchestra/locked.lua").read_text(encoding="utf-8")
    source = source.replace(
        'local Z2R_SS_EVENT_PATH = "/tmp/z2r-supersweep/probe/events.tsv"',
        f'local Z2R_SS_EVENT_PATH = "{events.as_posix()}"',
    )
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("VERDICT_PASS=0; TH_FIN=1; TH_SYN=2; TH_RST=4; TH_ACK=16; function bitand(a,b) return a & b end")
    lua.execute(source)
    lua.execute('''
      local d={outgoing=true,track={lua_state={}},dis={tcp={th_sport=62001,th_dport=443,th_flags=TH_SYN,th_seq=100,th_ack=0},payload=""},l7payload="empty"}
      assert(z2r_supersweep_observe(nil,d)==VERDICT_PASS)
      d.dis.tcp.th_flags=TH_ACK; d.dis.tcp.th_seq=101; d.dis.payload="hello"; d.reasm_data="hello"; d.l7payload="tls_client_hello"
      assert(z2r_supersweep_observe(nil,d)==VERDICT_PASS)
      d.outgoing=false; d.dis.tcp.th_sport=443; d.dis.tcp.th_dport=62001; d.dis.tcp.th_flags=TH_ACK; d.dis.tcp.th_ack=106; d.dis.payload=""; d.l7payload="unknown"
      assert(z2r_supersweep_observe(nil,d)==VERDICT_PASS)
      d.dis.tcp.th_flags=TH_ACK+TH_RST
      assert(z2r_supersweep_observe(nil,d)==VERDICT_PASS)
      d.outgoing=true; d.dis.tcp.th_sport=62001; d.dis.tcp.th_dport=443; d.dis.tcp.th_flags=TH_ACK+TH_FIN
      assert(z2r_supersweep_observe(nil,d)==VERDICT_PASS)
    ''')
    rows = events.read_text(encoding="utf-8").splitlines()
    assert rows[0] == "READY"
    kinds = [row.split("\t")[2] for row in rows[1:]]
    assert kinds == ["TCP_SYN", "CLIENT_HELLO_SENT", "CLIENT_HELLO_ACKED", "RST_IN", "FIN_OUT"], kinds
print("supersweep observer smoke ok")
