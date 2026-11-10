#!/usr/bin/env python3
"""Build and exercise the standalone passive DNS parser."""
import os
import pathlib
import struct
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tools/googlevideo-dns-sniffer.c"


def wire_name(host):
    return b"".join(bytes([len(label)]) + label.encode("ascii")
                   for label in host.rstrip(".").split(".")) + b"\0"


def response(host, address, ttl=300, cname=None, cname_ttl=600, extra_addresses=()):
    qname = wire_name(host)
    msg = bytearray(struct.pack("!HHHHHH", 0x1234, 0x8180, 1,
                                (2 if cname else 1) + len(extra_addresses), 0, 0))
    msg += qname + struct.pack("!HH", 1, 1)
    if not cname:
        msg += b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, ttl, 4)
        msg += bytes(map(int, address.split(".")))
    else:
        target = wire_name(cname)
        msg += b"\xc0\x0c" + struct.pack("!HHIH", 5, 1, cname_ttl, len(target)) + target
        target_offset = 12 + len(qname) + 4 + 12
        msg += bytes([0xC0 | (target_offset >> 8), target_offset & 0xFF])
        msg += struct.pack("!HHIH", 1, 1, ttl, 4) + bytes(map(int, address.split(".")))
    for extra in extra_addresses:
        owner = wire_name(cname) if cname else b"\xc0\x0c"
        msg += owner + struct.pack("!HHIH", 1, 1, ttl, 4) + bytes(map(int, extra.split(".")))
    return bytes(msg)


def parse(binary, data):
    return subprocess.run([str(binary), "--replay"], input=data,
                          stdout=subprocess.PIPE, check=True).stdout.decode()


def packet(dns, source_port=53):
    udp = struct.pack("!HHHH", source_port, 53000, len(dns) + 8, 0) + dns
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, len(udp) + 20, 1, 0, 64, 17, 0,
                     bytes((8, 8, 8, 8)), bytes((192, 0, 2, 1)))
    return bytes(12) + b"\x08\x00" + ip + udp


def tcp_packet(dns):
    framed = struct.pack("!H", len(dns)) + dns
    tcp = struct.pack("!HHIIHHHH", 53, 53000, 1, 1, 0x5000, 65535, 0, 0) + framed
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, len(tcp) + 20, 1, 0, 64, 6, 0,
                     bytes((8, 8, 8, 8)), bytes((192, 0, 2, 1)))
    return bytes(12) + b"\x08\x00" + ip + tcp


def ipv6_packet(dns):
    udp = struct.pack("!HHHH", 53, 53000, len(dns) + 8, 0) + dns
    ip = struct.pack("!IHBB16s16s", 6 << 28, len(udp), 17, 64,
                     bytes.fromhex("20010db8000000000000000000000001"),
                     bytes.fromhex("20010db8000000000000000000000002"))
    return bytes(12) + b"\x86\xdd" + ip + udp


def parse_packet(binary, data):
    return subprocess.run([str(binary), "--replay-packet"], input=data,
                          stdout=subprocess.PIPE, check=True).stdout.decode()


def parse_stream(binary, messages):
    data = b"".join(struct.pack("!H", len(msg)) + msg for msg in messages)
    return subprocess.run([str(binary), "--replay-stream"], input=data,
                          stdout=subprocess.PIPE, check=True).stdout.decode()


def main():
    with tempfile.TemporaryDirectory(prefix="googlevideo-sniffer-") as tmp:
        binary = pathlib.Path(tmp) / "sniffer"
        subprocess.run([os.environ.get("CC", "cc"), "-std=c99", "-Os", "-Wall", "-Wextra", "-Werror",
                        "-o", str(binary), str(SOURCE)], check=True)
        host = "rr9---sn-h5gtov-n8vl.googlevideo.com"
        assert parse(binary, response(host, "8.8.8.8", ttl=120)) == f"{host}\t8.8.8.8\t120\n"
        assert parse(binary, response(host, "8.8.8.8", ttl=120, extra_addresses=("1.1.1.1",))) == (
            f"{host}\t8.8.8.8\t120\n{host}\t1.1.1.1\t120\n")
        chained = parse(binary, response(host, "1.1.1.1", cname="edge.example", ttl=90, cname_ttl=180))
        assert chained == f"{host}\t1.1.1.1\t90\n", chained
        assert parse(binary, response(host, "192.168.1.1")) == ""
        assert parse(binary, response("rr.example.com", "8.8.8.8")) == ""
        assert parse(binary, b"\0" * 12) == ""
        duplicate = response(host, "8.8.8.8", ttl=120)
        assert parse_stream(binary, (duplicate, duplicate)) == f"{host}\t8.8.8.8\t120\n"
        pkt = packet(response(host, "8.8.4.4", ttl=240))
        assert parse_packet(binary, pkt) == f"{host}\t8.8.4.4\t240\n"
        assert parse_packet(binary, tcp_packet(response(host, "8.8.4.4", ttl=240))) == f"{host}\t8.8.4.4\t240\n"
        assert parse_packet(binary, ipv6_packet(response(host, "8.8.4.4", ttl=240))) == f"{host}\t8.8.4.4\t240\n"
        assert parse_packet(binary, packet(response(host, "8.8.4.4"), source_port=53000)) == ""
    print("googlevideo DNS sniffer parser smoke ok")


if __name__ == "__main__":
    main()
