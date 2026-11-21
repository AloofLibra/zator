# Adaptive rotation baseline: OpenWrt router

Read-only snapshot collected 2026-11-20 17:24 +03:00 from `root@192.168.1.37` over SSH. The local transport source was staged in a private `/tmp` directory for read-only checks; SHA-256 matched before execution and the directory was removed afterward. No firewall rules or configuration were changed.

- Platform: OpenWrt `25.12.4`, Linux `6.12.87`, target `mediatek/filogic`, `aarch64_cortex-a53`.
- Configured backend: `FWTYPE=nftables`; nftables `1.1.6`; iptables compatibility frontend `1.8.10 (nf_tables)`.
- IPv4 forwarding is enabled. Ephemeral source ports are `32768–60999`, separate from the reserved adaptive test range `62000–62999`.
- LAN is `br-lan` (`192.168.10.1/24`); WAN is `wan` (`192.168.1.37/24`). Several VPN interfaces are configured, so a real test must verify the selected route instead of assuming `wan`.
- Production NFQUEUE 300 is registered. Rules in `inet zapret2` include `postnat_hook` and `prenat_hook` and direct production traffic to queue 300.
- Queue 65535 was unregistered; no nft rules targeted queue 65535; `z2r_adaptive_lan` was absent.
- The source helper's read-only queue availability check returned clear. `nft -c -f` accepted a proposed IPv4/TCP tuple-matched chain with ORIGINAL/REPLY direction, mark → queue 65535 (bypass enabled) → accept ordering, and jumps at `postnat_hook`/`prenat_hook`. A read-back confirmed the chain remained absent.

The same source/hash-verified, read-only queue check and `nft -c -f` parser check were repeated at 17:27 +03:00 against the current module; the queue remained clear and the adaptive chain remained absent.

This confirms the local nft syntax and current queue availability only. It does not prove LAN packet delivery, queue ownership at runtime, isolation from production NFQUEUE, strategy application, or cleanup under real traffic. No live rules were installed.

## Windows LAN-client path check (read-only, 2026-11-20 18:20 +03:00)

- The Windows test PC is dual-homed: Wi-Fi `192.168.10.117` via OpenWrt gateway `192.168.10.1`, and Ethernet `192.168.1.140` via Keenetic gateway `192.168.1.1`. Probes bind the intended source address and a single reserved source port so Windows' competing default routes do not choose the path implicitly.
- A Wi-Fi-bound HTTPS HEAD to `example.com` pinned to `93.184.216.34:443` used source port `62002`. OpenWrt WAN capture observed the translated outbound SYN as `192.168.1.37:62002 → 93.184.216.34:443`; no SYN-ACK followed and curl timed out (`HTTP 000`). This verifies one outbound forwarding/NAT path and source-port preservation, but **not** a completed TCP/TLS exchange or NFQUEUE delivery.
- Read-only policy inspection found `mt_f95ef0f9_4` marks destinations including `8.8.8.8`, `1.1.1.1`, and `208.67.222.222` with `0x7531`; the corresponding policy table has a blackhole default. Therefore the earlier timeout probes to these addresses are not valid evidence of ordinary WAN reachability. The pinned `93.184.216.34` target matched none of the inspected `mt_*_4` sets, yet still did not answer.
- No firewall rules or router configuration were changed. The current external target is not a working control endpoint, so the LAN→test-NFQUEUE acceptance test remains blocked pending a known-reachable target and the required narrowly scoped live-test approval.

## Reachable HTTPS control (read-only, 2026-11-20 18:30 +03:00)

- A single Wi-Fi-bound HEAD to the user's existing `https://music.alooflibra.fun/hermes/` service used `192.168.10.117:62004` and received HTTP `302` from `81.88.218.64:443` (login redirect). OpenWrt's route lookup for that destination selected `wan` via `192.168.1.1`; the destination was absent from the inspected `mt_*_4` policy sets.
- This is a reachable control endpoint for later tests, but this ordinary request does not prove test-NFQUEUE delivery or production-queue isolation. No firewall rules were changed.

## Controlled live NFQUEUE check (2026-11-20)

- With the user's approval, a temporary nft chain matched only `192.168.10.117:62000 → 142.251.155.119:443` (`www.google.com`) and queued that flow to 65535. The queue packet counter moved from 0 to 232; the pinned HTTPS request completed with HTTP 200 and TLS verification result 0. This confirms delivery of the selected flow to the separate test queue and a complete HTTPS response through the probe.
- The first automatic cleanup exposed a real-parser bug: `nft -a list chain` includes the `table inet zapret2 {` wrapper, which `_adaptive_lan_nft_handles` had treated as foreign chain content. Recovery removed only the verified test handles, stopped probe PID 28540, and read back no adaptive rules, no queue 65535, and no shared lock. The parser now skips the table header; the regression smoke passes, and a subsequent no-traffic install/remove using the real nft backend reported `LIVE_NFT_CLEANUP_OK`.
- No production configuration was changed. Production queue 300 remained registered. The corrected cleanup was live-verified without sending a second client request; the successful HTTP result above predates that parser fix.

## Controller end-to-end checks (2026-11-21)

- A staged controller run exposed a critical mark collision: LAN test packets were marked with the production `DESYNC_MARK`, so nfqws2 identified them as its own generated packets and ignored them. The transport now uses the isolated probe mark `0x08000000` (and validates the production mark before installing rules). The regression smoke checks both nftables and iptables rule generation.
- After this fix, one direct-strategy run for the same tightly scoped tuple (`192.168.10.117:62000 → 142.251.155.119:443`) completed through the temporary test controller: curl received HTTP 200, Lua wrote the matching test ACK, and the controller returned `SUCCESS` with `route_verified:true`, transport/application `OK`, reason `probe_ok`. Debug log counts showed no generated-packet drops and no Lua/desync errors. Queue 65535 and the shared lock were gone after cleanup.
- A subsequent strategy-1 run for that tuple returned `INCONCLUSIVE` / `route_unverified`; no Lua ACK was present. It is not evidence that strategy 1 works or fails. The test controller and temporary queue were cleaned up; queue 65535 is absent, queue 300 remains registered, and the shared lock is free.
- At the time of these staged-harness checks, they were not acceptance of the complete authenticated CGI/client path. The successful controller result was submitted through the temporary harness; the follow-up result was inconclusive. Production queue 300 stayed registered, but its global packet counter was not tuple-specific. No files under `/opt` or production config were changed; staged assets were under `/tmp/z2r-adaptive-live-20261121`.
- At that point, AUTO remained disabled pending route/queue attribution, ordinary browser-flow isolation, Keenetic iptables plus NDM rebuild, both nfqws2 builds, crash/reboot cleanup, resource measurements, and authenticated Windows-agent/API acceptance. Later sections record subsequent live acceptance evidence; remaining gates are summarized in the current contract document.

## Post-test read-only state check (2026-11-21 01:31 UTC)

- The router was reachable for a read-only check. Production queue 300 was still registered to nfqws2 PID 26630; queue 65535 was absent.
- `inet zapret2` had no `z2r_adaptive_lan` chain. The prior `/tmp/z2r-adaptive-live-20261121` staging directory was absent, and no adaptive controller process was running.
- At the time of this check, it confirmed cleanup only; no repeat probe or ordinary same-domain isolation test had yet been run. The later paired-flow acceptance sections record the subsequent tests.

## Paired-flow isolation acceptance (2026-11-21)

- With the user's approval, a temporary `/tmp` harness installed only tuple-scoped test rules. A Windows LAN probe for the selected hostname completed through queue 65535 and produced the matching Lua strategy ACK.
- An ordinary HTTPS request to the same hostname completed through the production queue 300; the test queue did not capture that ordinary flow.
- The harness removed its temporary rules, files, and probe process. Follow-up checks found queue 65535 free and no adaptive chain or shared lock. Production config and persistent strategy locks were not changed.
- This closes the basic paired-flow routing check for this OpenWrt topology. It does not cover alternate routes/VPN/offload, negative-verdict cases, NDM/firewall rebuild or crash/reboot recovery on hardware, both nfqws2 builds, or sustained resource limits. AUTO remains disabled.

## Active lease across fw4 reload (2026-11-21)

- The current controller and transport were staged under `/tmp/z2r-adaptive-fw4-live`; no files under `/opt`, production config, or persistent strategy locks were changed.
- A pinned Windows LAN request from `192.168.10.117:62028` to `142.251.155.119:443` (`www.google.com/robots.txt`) ran through a live TEST_ONLY controller while `fw4 reload` executed during the body transfer. Curl returned HTTP 200 with 12,510 bytes. The q65535 sequence counter rose from 0 to 56 during the reload and to 66 by completion, and `probe/applied.tsv` contained the matching host/profile/DIRECT ACK.
- The controller returned `route_verified:true`, `transport=OK`, `application=OK`, `overall=SUCCESS`, `reason=probe_ok`. This run exposed two reconcile defects before passing: mark selection counted the adaptive chain's own mark, and the OpenWrt BusyBox image has no `stat`; both are now covered by `adaptive_lan_nft_reconcile_smoke.sh`.
- After controller cleanup, an ordinary HTTPS request to the same hostname/IP using source port 62029 returned HTTP 200. Production queue 300 advanced from sequence 100251 to 100275, while q65535 was unregistered.
- Follow-up checks found no adaptive chain, transport state file, shared probe lock, or q65535 owner. Production nfqws2 PID 26630 and queue 300 remained active. The staging directory and local response bodies were removed.

This validates one active IPv4/TCP topology and the normal fw4 reload path on OpenWrt 25.12.4. It does not cover loss/recreation of the separate zapret2 nft table, which is a different failure mode, or alternative PBR/VPN/offload paths and sustained load.

## Read-only idle resource sample (2026-11-21 07:28 UTC)

Two read-only 30-second samples were collected with no adaptive rules, no queue 65535, and no adaptive controller. Production NFQUEUE 300 remained registered to PID 26630.

- The router exposed two online CPU cores. System load average changed from `0.00` to `0.08`; `MemAvailable` moved from 274,492 KiB to 263,340 KiB. Aggregate `/proc/stat` deltas correspond to about 7.9% busy time across the interval.
- `nfqws2` PID 26630 had RSS 19,728 KiB. Over a separate 30-second process-counter sample it accumulated one user CPU tick and no system tick at `CLK_TCK=100` (about 0.033% of one core for the interval). `MemAvailable` was 270,948 KiB after that sample; queue 65535 remained absent.

These are idle/background baselines, not adaptive-probe overhead or a sustained-capacity result. No user traffic was generated by the sampling commands. They do not test CPU/RAM/WAN limits under a real candidate search, hardware offload behavior, or memory pressure.

## Authenticated probe crash cleanup (2026-11-21)

- The Windows PowerShell 5.1 agent used a temporary authenticated `adaptive.cgi` served by uhttpd on the LAN. CGI, controller, and state were staged only under `/tmp`; the test used the live nfqws2 binary/config read-only and did not alter persistent locks or configuration.
- A temporary monitor waited until the exact test flow incremented queue 65535, then sent SIGKILL only to the private probe nfqws2 PID. The test queue counter reached 250 packets before termination.
- The agent posted completion and received `route_verified:false`, `transport=UNKNOWN`, `application=UNKNOWN`, `overall=INCONCLUSIVE`, `reason=route_unverified`. Controller cleanup removed the adaptive nft rules and shared probe lock; queue 65535 disappeared, while production queue 300 remained registered to PID 26630.
- The initial run exposed two real defects: OpenWrt lacks the BusyBox `od` applet used for test IDs, and Windows PowerShell 5.1 treated curl stderr as a terminating error before completion was posted. CGI now uses `/proc/sys/kernel/random/uuid`; `Invoke-AdaptiveCurlNative` preserves curl's exit status and continues to the verdict/complete path. Both have regression coverage.

This closes probe-process SIGKILL cleanup for the tested OpenWrt nft/official queue configuration. It does not test controller SIGKILL, reboot/power loss, a mismatch where packets reach a different registered NFQUEUE, or alternate nfqws2 builds and routes.

## Controller SIGKILL and stale recovery (2026-11-21)

- A second isolated uhttpd/CGI setup and adaptive state were staged in `/tmp/z2r-adaptive-controller-crash`; the installed `adaptive-pair.sh` logic was copied into the temporary root. No persistent mode, config, or strategy locks changed.
- The monitor observed 230 packets in q65535, verified the shared-lock owner PID's command line pointed to the staged adaptive controller, then SIGKILLed only that controller. The private nfqws2 remained registered to queue 65535, and the lease state remained `leased` with its original owner record.
- Running `adaptive-pair.sh pause` against the temporary root switched only the staged mode to OFF, waited for normal cleanup, then invoked stale recovery. Recovery verified the dead controller, matching boot ID, queue PID, `nfqws2` binary, `--qnum=65535`, and private `locked.lua` path before stopping the orphan. The run ended `failed` with `controller_crash_recovered`; q65535, the adaptive nft rules, and shared lock were gone. Production queue 300 remained registered to PID 26630.

This verifies recovery after controller SIGKILL when the operator invokes the pause/cleanup path on the current OpenWrt build. It does not simulate reboot/power loss or prove automatic recovery without a CLI, lifecycle, or hook trigger.

## HTTP 200 without test-queue proof (2026-11-21)

- A temporary API lease bound source port 62050 for `www.google.com` → `142.251.155.119:443`. The Windows host then made an ordinary pinned HTTPS request from source port 62061, outside the exact lease tuple; curl returned HTTP 200.
- The test submitted a well-formed completion claiming `transport=OK` and `application=OK`, while correctly marking the client route as unverified. The controller had no matching q65535 packet/ACK evidence and returned `route_verified:false`, `overall=INCONCLUSIVE`, `reason=route_unverified`.
- The exact temporary rules and lock were removed at completion. Queue 65535 is free; production queue 300 remains registered to PID 26630. The temporary CGI/uhttpd root and client response file were removed.

This confirms that an HTTP 200 from a different source port cannot produce a verified success on this OpenWrt setup. It is not a negative test across alternate routing or nfqws2 builds.

## Authenticated LAN agent and paired-flow acceptance (2026-11-21)

- A temporary uhttpd/CGI root, controller, config copy, and runtime assets were staged under `/tmp/z2r-adaptive-resource-test`. The Windows agent connected through the OpenWrt LAN (`192.168.10.117 → 192.168.10.1`); the test used a one-hour test token and `TEST_ONLY` only in the staged root. Temporary nft input allowances were restricted to the PC address and port 17783. No files under `/opt`, persistent config, or strategy locks changed.
- The authenticated PowerShell agent ran one DIRECT probe for `www.google.com` pinned to `142.251.155.119:443`. The controller returned `route_verified=true`, `transport=OK`, and queue 65535 advanced from sequence 0 to 238 packets. The HTTP response exceeded the client's 64 KiB limit, so application status stayed `UNKNOWN` and overall verdict was `INCONCLUSIVE` (`response_too_large`); this validates routing and transport isolation, not a successful bounded application recipe.
- During the short run, the private test `nfqws2` peaked at 1,704 KiB RSS (about 1.66 MiB). Across the sampled four-second interval it accumulated 3 user and 1 system CPU ticks at `CLK_TCK=100` (about 1% of one core during that interval). Sampled `MemAvailable` ranged from 252,216 to 263,532 KiB and load average from 0.03 to 0.11. This is a single short DIRECT probe, not a sustained-search or worst-case resource bound.
- After the probe stopped and q65535 was gone, an ordinary Windows HTTPS HEAD to the same hostname/IP, bound to the OpenWrt LAN address but without a reserved test port, returned HTTP 200. Production NFQUEUE 300's sequence advanced from 119100 to 119120; it remained owned by production PID 26630. The ordinary flow therefore used the production queue while the scoped test probe used 65535.
- Cleanup removed both temporary uhttpd listeners, the exact nft/iptables input allowances, monitor, and staged `/tmp` tree. Final read-back found no listener on 17783, no temporary firewall rule, no adaptive chain or shared lock, and no q65535 registration. Production queue 300 remained registered; persistent settings and locks were untouched.

This closes one authenticated Windows-agent paired-flow check on the current OpenWrt nftables build and provides a short direct-probe resource sample. It does not close alternate PBR/VPN/offload paths, other nfqws2 builds, sustained multi-candidate load, failure/reboot recovery, or the application-size recipe gap. AUTO remains disabled.

## Profile-5 QUIC media paired-flow check (2026-11-21)

- With the user's approval, a temporary authenticated listener and probe root were staged under `/tmp/z2r-adaptive-quic-test`; the temporary input rule allowed only the LAN PC to the test port. No persistent config or strategy locks changed.
- After the isolated profile-5 argv builder was corrected to preload upstream Lua modules, numbered UDP strategy 18 completed a real HTTP/3 Googlevideo media range of 1 MiB. The verdict was `SUCCESS` / `media_ok`, `route_verified=true`, with queue 65535 evidence and the matching strategy ACK. Measured transfer was 1,972,334 B/s over 532 ms.
- Strategy 1 returned `INCONCLUSIVE` (`route_unverified`) without media bytes. A DIRECT control against the same selected media host succeeded over HTTP/3 for 1 MiB, confirming the endpoint was reachable during the test.
- An ordinary HTTP/3 control to the same hostname/IP used a non-reserved source port and returned HTTP 404 (curl then reported exit 56 after the response). Production queue 300 advanced from 150301 to 150319; q65535 was absent. A separate ordinary TCP control timed out, so it is not counted as a successful application exchange.
- Cleanup removed the temporary listener, firewall rule, and staged router files. Final queue read-back showed only production queue 300 owned by PID 26630; queue 65535 and the temporary nft rule were absent.

This verifies one OpenWrt profile-5 strategy-18 HTTP/3 media flow and one same-host queue-isolation control. It does not cover Keenetic, alternate routes/VPN/offload, firewall rebuild or crash recovery during QUIC, both nfqws2 builds, or sustained search/resource limits. AUTO remains disabled.

## Profile-2 TCP Ramp media paired-flow check (2026-11-21)

- With the user's approval, a temporary authenticated listener and isolated probe root were staged under `/tmp/z2r-adaptive-ramp-beta1-rerun`; temporary input access was restricted to the LAN PC. No persistent config, strategy locks, or production NFQUEUE settings were changed.
- The first run proved queue 65535 and strategy ACK but revealed the isolated profile omitted the production Ramp all-packet ranges, so Lua never saw the SYN. `lib/supersweep_probe.sh` now mirrors the production profile's `--out-range=a`, `--in-range=a`, and `--payload=all,empty` only for explicit Ramp treatments; default Supersweep remains Ramp-free. The focused background smoke passed with argv assertions for those ranges.
- After that correction, a profile-2 DIRECT Ramp treatment on `rr2---sn-h5gtov-n8vl.googlevideo.com` pinned to `188.244.8.77` returned `SUCCESS` / `media_ok`, `route_verified=true`, queue and strategy ACK evidence, both SYN and late-ACK Ramp audit flags, and 1 MiB transferred at 994,451 B/s. Numbered strategy 1 on the same target reached queue/strategy ACK and SYN audit but returned `INCONCLUSIVE` (`ramp_stage_unconfirmed`) with no media bytes; it is not counted as a strategy success.
- A normal pinned HTTPS request to the same host/IP returned HTTP 404 for `/`. Queue 300 remained registered to production PID 26630 and queue 65535 was absent after each probe. Its procfs packet counter did not change during the bounded before/after control sample, so that control proves the ordinary endpoint response and queue isolation state, not packet-level q300 routing.
- Cleanup removed the exact temporary nft input rule, uhttpd listener, staged router tree/archive, and local token directory. Persistent settings and locks were untouched.

This closes one OpenWrt profile-2 DIRECT Ramp media path through the isolated queue. It does not validate a numbered Ramp strategy, Keenetic, alternate routes/offload, sustained traffic, or automatic Ramp exemption decisions. AUTO remains disabled.

### Numbered strategy and exact Ramp exemption follow-up (2026-11-21)

- Repeated the same-host/IP/strategy-2 media comparison in order Ramp → plain → plain → Ramp. All four probes used `rr2---sn-h5gtov-n8vl.googlevideo.com` → `188.244.8.77` and the same signed-media URL fingerprint. Every probe returned `SUCCESS`, transferred 1 MiB, and showed queue 65535 plus the strategy ACK. Ramp runs recorded both SYN and late-ACK stages; plain runs recorded neither. Measured rates were about 0.58 MB/s and 0.62 MB/s for Ramp, and 1.61 MB/s and 1.66 MB/s for plain. This demonstrates one working numbered Ramp strategy and the expected effect of the exact exception on this route.
- Applied the exception for the four exact controller result IDs. The API returned `ramp_exempt`, and `ramp_targets` showed the exact host/IP/scope as exempt. A subsequent Ramp-labeled probe initially transferred 1 MiB but correctly remained `INCONCLUSIVE` because the active exception suppressed both Ramp callbacks. This exposed a missing control path: the isolated Ramp control inherited the exemption.
- Updated `adaptive-controller.sh` to construct a mode-644 per-probe copy of the exemption file with only a matching active host/IP/scope row removed, and point the isolated Lua process at that copy. The production exemption file was not modified. A fresh strategy-2 Ramp probe against the still-exempt tuple then returned `SUCCESS`, with queue/ACK, SYN and late-ACK evidence, 1 MiB transferred, and the same URL fingerprint. The temporary probe copy contained only the unrelated rows and had mode 644.
- A revoke attempt using Ramp/plain/Ramp evidence was rejected because the plain result in this successful A-B-B-A series showed media success, not bounded degradation. This is the intended safety gate; no exception was removed by that request. The apply path and the negative revoke gate are live-checked; a genuine degraded-plain sequence and successful live revoke remain unverified.
- Temporary listener, firewall rule, probe root, archive, and token were removed. Final queue read-back showed only production queue 300 owned by PID 26630; the temporary listener/rule and q65535 were absent. Persistent config and strategy locks were untouched.

This adds one successful numbered strategy-2 Ramp path and verifies active-exemption Ramp control on OpenWrt. It does not pass Keenetic Ramp, demonstrate a valid degraded-plain revocation, or cover alternate routes/offload, sustained traffic, both nfqws2 builds, or the other Beta gates. AUTO remains disabled.

### Reboot cleanup follow-up (2026-11-22)

- With the user's approval to reboot OpenWrt only, the router restarted after the temporary paired-flow stage, listener, and firewall rule had been removed. The direct LAN SSH endpoint at `192.168.10.1` then presented an ED25519 host key different from the previously trusted key. The new key was not accepted and `known_hosts` was not changed.
- Read-only access through the already trusted WAN endpoint `192.168.1.37` confirmed the same Cudy WR3000P v1 (`br-lan` MAC `d4:0d:ab:65:e5:fb`). Production NFQUEUE 300 was registered to PID 3753; queue 65535 was absent; the temporary paired-flow stage, adaptive rules, and shared lock were absent.
- The live `/opt/zapret2/config` SHA-256 after reboot was `3ff9f5c87976eda4fea680993b4031355edd339b598aee5b6583096a81a1c323`, different from the recorded pre-reboot hash `7ed4556e2d5719b111e627beb5c9a322b30a1fd583989fe3abb9b304ed29e5d9`. The file timestamp is `Nov 22 02:17`, and the reason for the content change is undetermined. No config was restored or edited.

This verifies post-reboot cleanup and production queue ownership via the trusted endpoint. It does not explain the changed live config or the LAN SSH host-key mismatch, and no claim is made about a live HTTPS check after reboot. AUTO remains disabled.
