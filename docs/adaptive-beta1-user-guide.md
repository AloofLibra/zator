# Adaptive Agent Beta 1 operator guide

**Status: internal/test use only.** Beta 1 is not release-approved. OpenWrt and Keenetic each have a successful isolated TCP media path; OpenWrt has verified Ramp SYN/late-ACK media tests, but Keenetic's Ramp test has not verified the late ACK. Keep Keenetic Ramp auditing and exemptions unsupported until that evidence passes. Valid live exception revocation remains unverified. Keep the feature in `TEST_ONLY` unless you are intentionally evaluating the gated Beta behavior on a test router.

## Pair the Windows agent

On the router, run the pairing command as root:

```sh
/opt/zator/tools/adaptive-pair.sh create
```

Copy the one-time token into a protected local note long enough to start the agent. It expires after 30 days. Use `rotate` to revoke it and issue a replacement. Never publish the token or place it in a shared script/repository.

On Windows, run the agent from the installed Zator checkout with the router's LAN address and token:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\adaptive-agent.ps1 `
  -Router http://192.168.1.1 -Token '<pairing-token>' -ListEvents
```

`-ListEvents` is read-only. To watch and run ordinary isolated checks, start in `TEST_ONLY`:

```sh
/opt/zator/tools/adaptive-pair.sh test-only
```

Restart zapret2 when the command says the mode needs to be loaded. Then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\adaptive-agent.ps1 `
  -Router http://192.168.1.1 -Token '<pairing-token>' -Watch
```

`TEST_ONLY` can observe and probe, but does not apply stored strategy results. Optional low-priority exploration requires an explicit `-Watch -Explore`; it checks one observed target at a time and pauses when the machine or router exceeds its resource limits.

The WebUI reports whether the paired watcher is online and its current phase (FastSearch, DeepSearch, Explore, Ramp audit, or a retry cooldown). It also shows the watcher’s separate statistics-upload and shared-ranking opt-ins, plus aggregate counts and timing for its last strategy search. Search status is temporary and expires when the watcher stops checking in; it does not include the search target.

## Evaluate gated Beta behavior

Use this only on a test router after accepting the incomplete hardware coverage. Enable exact, explicitly scoped application with:

```sh
/opt/zator/tools/adaptive-pair.sh beta
```

This leaves default/LAN-scope rules in test-only behavior; only exact scopes explicitly marked by the user may apply. Restart zapret2 as instructed. To evaluate the low-priority Ramp comparison, use:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\adaptive-agent.ps1 `
  -Router http://192.168.1.1 -Token '<pairing-token>' -Watch -RampAudit
```

Ramp auditing uses only recently observed Googlevideo host/IP targets and bounded media probes. It can create an exact temporary exemption only after its proof sequence and local consent checks pass. A failed, missing, or inconclusive probe leaves Ramp enabled. A successful plain result does not revoke an exemption; revocation requires a bounded plain-media degradation bracketed by successful Ramp controls.

`beta-lan` grants consent for exact rules at default scope across the LAN. Do not use it for routine evaluation: it widens the affected clients. The mode remains experimental and does not enable legacy `AUTO`.

## Pause and roll back

Pause observation and stop adaptive activity:

```sh
/opt/zator/tools/adaptive-pair.sh pause
```

Restart zapret2 when prompted. To revoke pairing and clear adaptive state:

```sh
/opt/zator/tools/adaptive-pair.sh disable
```

`status` and `doctor` report current mode and cleanup state without printing the token. Keep automatic Beta rules disabled if cleanup is pending or `doctor` reports a failed prerequisite.

## Data and limits

- Probe decisions are local. `-UploadStatistics` and `-UseSharedRankings` are separate, explicit opt-ins; neither is required for local operation. Ranking requests disclose provider/profile/protocol. Signed media URLs and raw Googlevideo host/IP observations are not sent to the stats service.
- Media probes require Windows curl 8.4 or newer. Profile-5 checks require a curl build with HTTP/3 support and use HTTP/3-only mode.
- Beta rules match exact host/IP/profile/scope and expire. They do not propagate from one CDN sibling or IP to another. Existing connections keep their established flow behavior.
- If an adaptive rule expires, conflicts, or no longer matches the current runtime stamp, it is ignored for new connections. Manual domain/profile locks keep priority; otherwise Zator resumes its normal current-config strategy selection. No Redis request is needed for this fallback.
- This is not approved for general deployment: Keenetic TCP Ramp, a real degraded-plain exception revoke, alternate PBR/VPN/offload paths, both `nfqws2` builds, sustained resource limits, and two-agent/Supersweep contention are not yet verified. The current acceptance ledger is [adaptive-beta1-status.md](adaptive-beta1-status.md).
