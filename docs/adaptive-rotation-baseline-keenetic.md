# Adaptive rotation baseline: Keenetic router

Read-only snapshot collected 2026-11-20 13:57 +03:00 from `root@192.168.1.1` over SSH. No services, firewall rules, or configuration were changed.

- Platform: Keenetic NDMS, Linux `4.9-ndm-5`, `aarch64`.
- `nfqws2`: fork `v1.0.7-reasm-fix` (`c7bef3e8390b188fa42279ca3e5123ac75665f1c`); one production process running as `nobody` with `--fwmark=0x40000000`.
- Probe queue 65535: not registered at snapshot time.
- Memory (`free -m`): total 1,014,996 KiB; used 436,424 KiB; available 528,892 KiB; swap 3,145,720 KiB total, 0 used.
- `/opt` filesystem: 13.7G total, 181.2M used, 12.8G available.

This is a single idle-state observation, not a CPU/RAM/packet-load baseline. Redis is not measured here. Stage 1 still requires an isolated LAN probe with packet/queue evidence and confirmation that ordinary production traffic is unaffected; do not infer LAN isolation from the existing local Supersweep probe.

## Firewall inventory (read-only, same session)

- Configured backend: `FWTYPE=iptables`; device reports iptables `v1.4.21`; IPv4 forwarding is enabled.
- Read-only checks on this device confirmed `conntrack` match support for `--ctdir`, `--ctorigsrc`, `--ctorigsrcport`, `--ctorigdst`, and `--ctorigdstport`. `iptables-restore --test` accepted the proposed six tuple-matched ORIGINAL/REPLY rules for queue 65535; a read-back confirmed `Z2R_ADAPTIVE_LAN` remained absent. No firewall rules were installed. This proves parser compatibility only, not packet delivery or isolation from production NFQUEUE.
- Production mark: `DESYNC_MARK=0x40000000`; post-NAT mark: `0x20000000`.
- Production NFQUEUE: queue 300, active rules in `INPUT`, `FORWARD`, and `POSTROUTING`; WAN interface is `ppp0` in the current rules.
- No `Z2R_SS_*` probe-owned rules were present.
- Keenetic hook `/opt/etc/ndm/netfilter.d/000-zapret2.sh` restarts the zapret2 firewall on NDM rebuild; the currently deployed hook has no supersweep transport reconcile call.

This confirms the legacy iptables backend and a live LAN-forwarding path to investigate. It does not establish safe insertion order, LAN interface/address, NAT tuple matching, or queue delivery for a test-client flow. No rules were added or changed.

## LAN-path details (read-only)

- LAN-facing interfaces include `br0` (`192.168.1.1/24`) and `br1` (`10.1.30.1/24`); only `192.168.1.0/24` appears in the displayed IPv4 route table.
- Default route is `ppp0`, but several VPN interfaces/routes are also present. A probe must prove its actual WAN path; assuming every LAN destination exits `ppp0` is unsafe.
- Ephemeral ports are `49000–61001`, so reserved source ports `62000–62999` do not overlap on this snapshot.
- Queue 300 is registered to PID 1118. The queue listing contains other registered queue numbers too, but 65535 was absent in the preceding check.
- Production `FORWARD` currently has reply-direction NFQUEUE rules at the top; production outbound TCP rules are in `POSTROUTING` on `ppp0`. The full chains include Keenetic and VPN policy hooks, so inserting a probe rule based only on the WAN hook would not prove or preserve the selected LAN route.

This snapshot narrows implementation/test requirements; it is not approval to install firewall rules or evidence of test-queue delivery.

## Windows LAN-client path check (read-only, 2026-11-20 18:20 +03:00)

- The Windows test PC's Ethernet address is `192.168.1.140`, with Keenetic `192.168.1.1` as gateway; its Wi-Fi interface is separately bound to OpenWrt at `192.168.10.117`.
- An Ethernet-bound HTTPS HEAD to `example.com`, pinned to `93.184.216.34:443` and source port `62003`, timed out (`HTTP 000`) without establishing TCP. This same destination also failed to return a SYN-ACK on the OpenWrt path, so it is not a valid reachable control endpoint. No Keenetic firewall rules or configuration were changed; no queue-delivery claim is made.
- At 18:30 +03:00, a single HEAD to the user's existing `https://music.alooflibra.fun/hermes/` service, bound to Ethernet source `192.168.1.140:62005`, received HTTP `302` from `81.88.218.64:443` (login redirect). This confirms a reachable HTTPS control on the wired path, not test-NFQUEUE delivery or production-queue isolation; no firewall rules or configuration were changed.

## Follow-up preflight (read-only, 2026-11-20 17:00 +03:00)

- Rechecked the kernel queue registry and scanned available `raw`, `mangle`, `nat`, `filter`, and `security` tables for queue 65535 (including queue-balance ranges). No matching rules were reported; the kernel queue remains unregistered and `Z2R_ADAPTIVE_LAN` remains absent.
- At 17:27 +03:00, the current `lib/adaptive_lan_transport.sh` was staged to a private `/tmp` directory (remote SHA-256 matched), and its read-only iptables queue check returned clear. The temporary file was removed. No firewall mutation was performed; packet delivery and production-flow isolation remain unproven.

## Controlled live NFQUEUE check (2026-11-20)

- With the user's approval, a temporary mangle-chain rule matched only `192.168.1.140:62000 → 142.251.155.119:443` (`www.google.com`) and sent matching packets to queue 65535. The queue packet counter moved from 0 to 4, proving that packets from the selected flow reached the separate test queue.
- The pinned HTTPS request timed out after 15 seconds (`curl` 28, HTTP 000). A direct Google HTTPS check had previously succeeded outside the test queue, so this run does not establish end-to-end success under the probe's profile-1 strategy. Probe logs were removed by the harness after its normal cleanup, so the timeout cannot be attributed to the transport helper versus the selected strategy.
- Cleanup reported `CLEANUP_OK`: the adaptive chain and FORWARD hook were absent, queue 65535 was free, the shared lock was absent, and the probe process stopped. Production queue 300 remained registered. No production config or service was changed.

## Paired-flow isolation acceptance (2026-11-21)

- With the user's approval, a temporary `/tmp` harness installed tuple-scoped iptables rules. A Windows LAN probe for the selected hostname completed through queue 65535 and produced the matching Lua strategy ACK.
- An ordinary HTTPS request to the same hostname completed through the production queue 300; the temporary test rules did not capture that ordinary flow.
- The harness removed its temporary rules, files, and probe process. Follow-up checks found queue 65535 free and no adaptive chain, shared lock, or probe process. Production config and persistent strategy locks were not changed.
- This closes the basic paired-flow routing check for this Keenetic topology. A NDM rebuild reconciliation hook has since been implemented and mock-tested, but not exercised during a live probe on the router. Crash/power-loss recovery on hardware, alternate PBR/VPN paths, both nfqws2 builds, negative-verdict cases, or sustained resource limits also remain open. AUTO remains disabled.

## Active-probe NDM rebuild check (2026-11-21)

- With the user's approval, staged the current repository hook and adaptive runtime files under `/tmp` only. The installed `/opt/etc/ndm/netfilter.d/000-zapret2.sh` and persistent config were not changed.
- Started a TEST_ONLY probe from the wired Windows client (`192.168.1.140:62050`) to `www.google.com` (`142.251.155.119:443`). Invoking the staged hook with `table=mangle` triggered the Keenetic `restart-fw`; the staged hook then ran the reconcile helper (`HELPER_RC=0`). The test completed with `route_verified:true`, HTTP transport/application `OK`, `overall=SUCCESS`, and a matching Lua ACK. This verifies the active path across an NDM rebuild, though the controller also periodically reconciles, so the hook was not the sole possible source of rule restoration.
- The restart emitted the existing warning `/opt/zapret2/init.d/sysv/keenetic-policy.sh: not found`; the test queue and flow still recovered. This deployment warning was not changed as part of the test.
- Cleanup removed the exact staged `/tmp` tree and files. Final checks showed no adaptive rules or temporary files, no queue 65535 registration, and no test process; production queue 300 remained registered to PID 30998. No persistent config or strategy locks were changed.
- This is live evidence for one NDM rebuild and one IPv4 TCP/443 flow on this router. It does not cover power loss, a controller crash during rebuild, alternate PBR/VPN paths, sustained load, or other nfqws2 builds. AUTO remains disabled.

## Read-only idle resource sample (2026-11-21 07:28 UTC)

Two read-only 30-second samples were collected with no adaptive rules, no queue 65535, and no adaptive controller. Production NFQUEUE 300 remained registered to PID 30998.

- Three online CPU cores were reported. System load average changed from `0.12` to `0.14`; `MemAvailable` moved from 533,004 KiB to 532,352 KiB. Aggregate `/proc/stat` deltas correspond to about 1.3% busy time across the interval.
- `nfqws2` PID 30998 had RSS 22,772 KiB. Over a separate 30-second process-counter sample it accumulated one user tick and one system tick at `CLK_TCK=100` (about 0.067% of one core for the interval). `MemAvailable` was 533,808 KiB after that sample; queue 65535 remained absent.

These are idle/background baselines, not adaptive-probe overhead or a sustained-capacity result. No user traffic was generated by the sampling commands. They do not test CPU/RAM/WAN limits under a real candidate search, hardware offload behavior, or memory pressure.
