# Adaptive Strategy Selection: Router Validation

This procedure validates the opt-in controller path on OpenWrt and Keenetic
Entware. Run it on a test router first. Canary changes only the listed TLS
hosts, but it changes production traffic for those hosts while enabled.

## Prerequisites

- Install a zapret2 fork build that supports `--adaptive-events`,
  `--adaptive-control`, `--adaptive-canary-profile`, and
  `--adaptive-strategy`. The normal zator installer does not install the
  patched fork build automatically.
- Deploy the current zator controller and service files.
- Back up the live zapret2 config and record the currently working strategy
  for each test hostname.
- Confirm the controlled hostname is matched by the active profile-1 TLS
  hostlist and reaches the `circular_locked` strategy block. The C canary
  execution adapter is attached there; do not enable legacy `circular_quality`
  autorotation for this validation. If needed, add only the controlled test
  hostname to that hostlist before starting the test.
- Use an exact TLS hostname you control for both learning and canary, because
  promotion evidence is host-scoped. Its server must be switchable between a
  healthy HTTPS response and terminating TCP connections with RST after
  ClientHello but before server application payload.
- Keep a local console or another management path available while restarting
  zapret2.

### Install the beta `nfqws2` binary for a controlled test

The beta archive is a complete upstream tree, so do not unpack it over the
router installation. On a PC, extract only `binaries/linux-<target>/nfqws2`
from [`v1.0.5.2-adaptive-beta.3`](https://github.com/AloofLibra/zapret2/releases/tag/v1.0.5.2-adaptive-beta.3),
then copy that one file to `/tmp/nfqws2-adaptive` on the router. Select the
archive directory from `uname -m`:

| `uname -m` | Archive directory |
| --- | --- |
| `aarch64`, `arm64` | `linux-arm64` |
| `armv6l`, `armv7l`, `armv8l` | `linux-arm` |
| `i586`, `i686`, `i786` | `linux-x86` |
| `x86_64`, `amd64` | `linux-x86_64` |
| `mips` | `linux-mips` |
| `mipsel`, `mipsle` | `linux-mipsel` |
| `mips64` | `linux-mips64` |
| `riscv64` | `linux-riscv64` |
| `ppc`, `powerpc` | `linux-ppc` |

Only use an exact matching target. In particular, beta.3's `linux-mips64`
binary is big-endian; it is not suitable for `mips64el`/`mips64le`. If the
router architecture is not listed, do not substitute another archive binary.

On the router, check the staged binary before stopping the service:

```sh
chmod 755 /tmp/nfqws2-adaptive
/tmp/nfqws2-adaptive --help 2>&1 | grep -E -- '--adaptive-events|--adaptive-control|--adaptive-canary-profile|--adaptive-strategy'
```

Require all four options. Then stop zapret2 using `/etc/init.d/zapret2` on
OpenWrt or `/opt/etc/init.d/S90-zapret2` on Keenetic, and run:

```sh
BIN=/opt/zapret2/nfq2/nfqws2
cp -p "$BIN" /tmp/nfqws2.pre-beta3 || exit 1
cp /tmp/nfqws2-adaptive "$BIN.new" && chmod 755 "$BIN.new" && mv -f "$BIN.new" "$BIN" || exit 1
```

Start zapret2 and verify its service log before enabling shadow or learning.
For rollback during the same router uptime, stop zapret2, then run:

```sh
BIN=/opt/zapret2/nfq2/nfqws2
cp /tmp/nfqws2.pre-beta3 "$BIN.new" && chmod 755 "$BIN.new" && mv -f "$BIN.new" "$BIN" || exit 1
```

Start the service again. The backup is in tmpfs and is lost on reboot; keep
the normal zapret2 reinstall path available as the durable recovery option.

This is a temporary test install. A regular zapret2 update replaces the fork
binary with the build selected by the existing zator flavor setting.

## OpenWrt

Validate on the target firewall backend in use (nftables or iptables). Keep the
backend, config, hostnames, and router firmware version with the resulting
journal.

1. Confirm the installed `nfqws2 --help` lists all four adaptive options.
2. Enable Learning from menu item 25. Run a bounded comparison for the
   controlled hostname and confirm the journal reports correlated
   `PROBE_OUTCOME` records with `STRONG_SUCCESS` only when both HTTP and C flow
   attribution succeed.
3. Enable Canary from menu item 26 with only the controlled canary hostname.
   Confirm the host file is root-owned and mode `600`, and that the service
   command contains the controller's canary options.
4. Open new TCP/443 connections to that hostname. Confirm C journal rows carry
   `scope=production_canary`, the selected strategy, and a non-zero generation.
   Existing established flows should retain their original strategy and
   generation.
5. After the candidate meets the learning threshold, confirm a
   `CANARY_SET` record and query the C map:

   ```sh
   /opt/zator/adaptive/bin/adaptive-controller \
     --production-get-host /tmp/zator-adaptive/production-control.sock \
     1 canary.example.net
   ```

   The returned strategy and generation must match subsequent new-flow
   telemetry.
6. On the controlled RST endpoint, create three separate connections. Each
   must have ClientHello and client bytes, server RST, and no server payload.
   Confirm one `CANARY_ROLLBACK` record identifies profile, host, strategy,
   generation, epoch, and the triggering flow ID. The C host-map query must
   then report `no_host_strategy`; new connections must return to the legacy
   path. A timeout or a reset without these exact flow facts must not roll
   back.
7. Disable Canary with menu item 26. Confirm C host mappings are cleared, the
   production-control socket option disappears after nfqws2 restart, and the
   learning/shadow controller remains running if either mode is still enabled.

## Keenetic Entware

Repeat the same sequence using the Entware `S89z2r-adaptive-controller` and
`S90-zapret2` services. Confirm the custom firewall hook routes only the
reserved learning source-port range to the learning queue and that ordinary
production traffic continues through its existing queue. Verify canary
rollback and disable behavior independently from the OpenWrt result.

## Review the journal on a PC

Copy `/tmp/zator-adaptive/shadow.tsv` off the router and run:

```sh
python3 tools/adaptive_replay.py --controller-output shadow.tsv
```

The analyzer should emit canary promotion/pending/restoration/rollback events
and a `CANARY_HOST_SUMMARY` per host and network epoch. A pending assignment is
not an applied promotion; it means the desired assignment was checkpointed but
the C control endpoint did not acknowledge it. The analyzer also distinguishes
`CANARY_RESTORE_PENDING` from `CANARY_RESTORED`; pending means C has not
acknowledged re-applying the checkpointed assignment.
`CANARY_RECONCILE_PENDING` means the C control endpoint is missing or its reads
are unavailable; it is reported once per host until a read succeeds and does not
confirm an applied assignment. When control returns, the controller first
clears the allowlist in C, then restores only checkpointed assignments allowed
by the current network gate. Each rollback should emit `CANARY_ROLLBACK_AUDIT`
with `status=MATCHED`, confirming the
three distinct evidence flows' C assignment, TCP/443 RST/payload fields, and
controller-monotonic timestamps within the ten-minute window.
Require `CONTROLLER_OUTPUT_STATUS.complete=true` and
`rollback_audit_incomplete_count=0` before accepting the capture. A missing flow,
incomplete old rollback record, output limit, or event gap makes the capture
incomplete even when a `CANARY_ROLLBACK` row is present.
Also require `CANARY_PENDING_STATUS.clear=true` for every canary host at the end
of the capture; earlier pending rows are acceptable only if later confirmed
events resolve them.
If a flow is absent, check for journal truncation; do not treat a missing audit
row as a passed rollback review. Preserve the original TSV; the analyzer is
read-only and Python is a developer-side dependency only.

## Acceptance criteria

- Both platform service paths start and stop cleanly with shadow, learning,
  and canary independently enabled or disabled.
- `nfqws2` C telemetry is the source of flow ID, selected strategy, generation,
  destination IP/port, packet counters, RST/payload facts, and terminal event.
- Learning probes are correlated to exactly one C flow and never update
  production policy directly.
- Only exact allowlisted canary hosts use controller assignments. Manual
  locks retain precedence; unmapped hosts keep the legacy path.
- Rollback requires three distinct, exactly attributed TCP/443 flows within
  ten minutes and clears only the affected host assignment.
- On canary disable, no C host assignment remains and legacy routing resumes.
- There are no unexplained event gaps, controller overflows, or ambiguous
  flow joins during the observation window.

Record the router model, firmware, zapret2 fork commit, zator commit, firewall
backend, test hostname, observation interval, journal, and any service logs.
Do not proceed to Phase 10 until both platform runs pass and the captured
production-canary observations have been reviewed.
