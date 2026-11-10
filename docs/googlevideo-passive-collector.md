# Googlevideo passive DNS collector

The collector has one shared observation path (`googlevideo_observe_local`) and
two event sources:

- OpenWrt subscribes to `dnsmasq.dns` over UBus; it does not require
  `dnsmasq-full`.
- Entware/Keenetic uses the small `AF_PACKET` sniffer when a matching binary is
  available. Release assets cover the Linux targets in zapret2's build matrix;
  installation downloads only the router's matching binary. Other operating
  systems continue using the central feed.

Both paths validate the hostname and public IPv4 address, cap TTL at seven days,
deduplicate observations in RAM, update `z2r_googlevideo4` immediately, and put
local observations in tmpfs for consent-gated batch telemetry. Central feed rows
are not sent back as local observations. The sniffer itself prints TSV only;
the shell listener performs the existing validation, storage and set update.

## Build and size check

Build with a static-musl compiler for the target architecture:

```sh
CC=aarch64-openwrt-linux-musl-gcc \
STRIP=aarch64-openwrt-linux-musl-strip \
tools/build-googlevideo-dns-sniffer.sh tools/bin/googlevideo-dns-sniffer
```

The build script rejects binaries above 131072 bytes (128 KiB). The OpenWrt
25.12.4 `mediatek/filogic` build is about 67 KiB. Each Linux architecture is
built independently in the release workflow and must remain below 128 KiB.
The deployment tar contains no sniffer binaries; installation fetches only the
matching compressed release asset, keeping router storage independent of the
number of supported targets. Targets mirror zapret2's Linux package matrix:
ARM64, ARM, MIPS64, MIPSEL soft-float, MIPS soft-float, PowerPC, x86, x86_64,
RISC-V 64 and Lexra. Android, Windows and FreeBSD packages are outside this
Linux `AF_PACKET` collector's scope.

## Tests

```sh
python3 tests/googlevideo_dns_sniffer_smoke.py
bash tests/googlevideo_packet_listener_smoke.sh
bash tests/googlevideo_ubus_smoke.sh
bash tests/googlevideo_sniffer_arch_smoke.sh
```

`--check-filter` asks Linux to validate and attach the production classic BPF
filter without entering capture mode. Run it as root on the router. To inspect
real answers briefly, run the sniffer as root while making a DNS lookup:

```sh
/opt/zator/tools/bin/googlevideo-dns-sniffer > /tmp/googlevideo.tsv &
sniffer_pid=$!
nslookup rr2---sn-h5gtov-n8vl.googlevideo.com
sleep 1
kill "$sniffer_pid"
cat /tmp/googlevideo.tsv
```

The packet source observes unencrypted DNS replies visible on the router's
interfaces. It handles IPv4/IPv6 UDP and single-segment TCP DNS, and A/CNAME
answers (including CNAME chains in the answer section). IPv6 extension headers,
IP fragments and TCP DNS messages split across segments are currently skipped.
Encrypted DNS is not observable. Passive capture is asynchronous, so it does
not guarantee that a newly seen address is in the set before the first SYN.
