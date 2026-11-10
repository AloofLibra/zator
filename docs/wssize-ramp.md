# Experimental `wssize_ramp`

`wssize_ramp` is an opt-in, single-IPv4 experiment. It is loaded by the shipped
config but skipped by default. The profile is selected by destination IP on the
SYN, then imports Zator's existing TLS strategy template so ClientHello
desynchronization remains active. Its exact-IP profile is placed before the
no-host TLS/RKN router profile so profile selection does not switch away after
the ClientHello is parsed.

## Enable on an OpenWrt nftables router

Edit `/opt/zapret2/config` and set:

```sh
Z2R_WSSIZE_RAMP_ENABLE=1
Z2R_WSSIZE_RAMP_IP=188.244.8.77
Z2R_WSSIZE_RAMP_MODE=full # or lite
```

Keep the existing `NFQWS2_TCP_PKT_OUT=20` and `NFQWS2_TCP_PKT_IN=10` values.
The custom hook adds only the selected address's TCP/443 packets after those
limits to the existing NFQUEUE. For iptables it uses owned mangle chains,
appended after zapret2's standard limiter; outbound rules preserve the
`DESYNC_MARK` bypass. It installs one queue rule per direction and is
idempotent across firewall reapplication. Disable by setting
`Z2R_WSSIZE_RAMP_ENABLE=0` and restarting zapret2. The shipped hook supports
nftables on OpenWrt and iptables through the SysV custom hook directory.

`full` re-scales the advertised window on every later ACK after `open` bytes of
server data have been acknowledged. `lite` leaves the window at the original
TCP stack value after that threshold and cuts off its own per-flow Lua callback
for the remaining outgoing packets. Both keep the reduced SYN window and
Window Scale through the opening phase. The default `open=1` permits the ramp
as soon as at least one server byte is cumulatively acknowledged. The shipped
scale target is 5; it is clamped to the client's original scale if that value
is lower.

## Router checks

Run from a shell with SSH access. Replace the address and interface as needed.
Start the capture on the router, then run the download from a client whose
traffic passes through that router:

```sh
IP=188.244.8.77
IFACE=br-lan
tcpdump -i "$IFACE" -nn -s 0 -w /tmp/wssize-full.pcap "host $IP and tcp port 443" &
CAP=$!
```

On the client, use a real large HTTPS object whose hostname resolves to the
selected IP; a signed Googlevideo URL is suitable if its host currently maps
to that IP. `--resolve` pins just this request to the test address while
preserving the required TLS SNI and HTTP Host:

```sh
URL='https://<host>/<large-object-or-signed-media-url>'
HOST='<host>'
curl -L --fail --resolve "$HOST:443:188.244.8.77" \
  --output /dev/null --write-out 'code=%{http_code} bytes=%{size_download} seconds=%{time_total}\n' \
  "$URL"
```

Use the same URL and client for each run. Save the output under separate names
and compare bytes, elapsed time, and retransmissions. Do not treat a short
error/redirect body as a throughput measurement. A direct request to the IP
without its matching hostname/SNI is only a queue and SYN smoke test.

Inspect the capture and queue counters:

```sh
kill -INT "$CAP"
tcpdump -nn -vv -r /tmp/wssize-full.pcap
cat /proc/net/netfilter/nfnetlink_queue
nft -a list table inet zapret2 | grep '188.244.8.77'
```

For a clean A/B series, restart zapret2 between runs and set mode to `full`,
then `lite`, then disable the ramp (`ENABLE=0`) for the Zator baseline. The
full/lite comparison requires enough acknowledged server data to pass the
opening threshold and a large successful response.

## Development checks

```sh
sh tests/wssize_ramp_firewall_smoke.sh
bash tests/wssize_ramp_iptables_smoke.sh
lua tests/wssize_ramp_smoke.lua
```

The Lua unit test checks SYN edits, pre-open ACK behavior, Full rescaling, Lite
pass-through, threshold tracking, saturation and missing state/options. The
firewall smoke test covers both directions, install, idempotent reapply,
remove/reapply lifecycle, disabled mode and invalid addresses. A router with
the production `nfqws2` is still required for API/NFQUEUE and wire checks.
