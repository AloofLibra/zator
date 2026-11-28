# Experimental `wssize_ramp`

`wssize_ramp` is disabled by default. It uses the managed IPv4 file
`/opt/zator/lists/googlevideo-ipv4.txt`; the previous single-IP setting is no
longer used. The profile is placed before the hostlist profiles and imports
Zator's existing TLS strategy template, so ClientHello desynchronization stays
active.

> **Warning (Keenetic/Netcraze).** Enabling the feature may break video
> playback. Verified on a live Netcraze Ultra NC-1812 (2026-11-28): with the
> shipped `scale=1` the client received no stream at all, while the router's own
> 8 MB download ran fine (6.4–8.6 MB/s). The bisect showed the Window Scale
> rewrite itself is the breaker — `wsize=1`, `1460` and `65535` all failed with
> `scale=1`, and only `scale=7` (no rewrite, i.e. the feature does nothing)
> restored playback. Keep it disabled if video matters; the CLI submenu shows
> the warning and asks for confirmation on Keenetic, the WebUI panel shows the
> same note.

Set `Z2R_WSSIZE_RAMP_ENABLE=1`, `Z2R_WSSIZE_RAMP_MODE=full` and
`Z2R_WSSIZE_RAMP_SCALE=1` in `/opt/zapret2/config`, or use CLI menu 19 → 7 / the
WebUI Settings panel. The list can be refreshed from CLI menu 19 → 8. On
OpenWrt, menu 19 → 9 enables local dnsmasq collection and menu 19 → 10 merges
that set with the central list. When the feature is enabled, refreshing or
merging the list restarts zapret2 so the late-packet firewall rules use the
current addresses.

The custom hook adds only Googlevideo IPv4 TCP/443 packets after the existing
`NFQWS2_TCP_PKT_OUT` / `NFQWS2_TCP_PKT_IN` limits to the existing NFQUEUE. It
handles both directions; the nftables path accounts for OpenWrt's NAT hooks,
and the iptables path uses owned chains appended after the normal limiter.
Disable the feature with `Z2R_WSSIZE_RAMP_ENABLE=0` and restart zapret2.

`full` rescales the advertised window on later ACKs after `open` bytes of server
data have been acknowledged. `lite` stops changing the window after those
first confirmed bytes and cuts off its Lua callback for the rest of the flow.
The default scale target is 1; it is clamped to the value negotiated by the
client. Both modes preserve the reduced SYN window and Window Scale during the
opening phase.
