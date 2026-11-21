# Adaptive statistics V2 server API

This is a separate opt-in Redis contract for aggregated adaptive probe outcomes. It does not change `/z4r/recommendations.tsv` or the existing SuperSweep collector. Server handlers, Redis aggregation, precomputed JSON/TSV rankings, a refresh worker, and a safe staging installer exist in this repository. The Windows agent has explicit, separate `-UploadStatistics` and `-UseSharedRankings` switches. Ranking GETs are disabled by default because they disclose the provider, profile, and protocol; without `-UseSharedRankings`, FastSearch does not request provider identity or contact the rankings endpoint. V2 is installed on an isolated test server only; the production stats host has not been changed.

## Data contract

`POST /z4r/adaptive-v2/results` accepts JSON up to 32 KiB with:

- `schema_version: 2` and a random 32-hex `request_id`;
- normalized provider, timestamp, fixed recipe `tls-http1-v1`, and client profile `curl-windows-v1`;
- at most 50 rows containing only profile, protocol `tls`, semantic strategy fingerprint, verified route, transport/application verdicts, and `SUCCESS`/`FAIL`. The Windows agent uploads exact `SUCCESS` rows and only the narrowly controlled Explore `FAIL` case described below. A `FAIL` must include 2–5 repeated failure confirmations; a single timeout or HTTP status cannot lower the ranking.

No hostname, destination IP, URL, source IP, raw installation UUID, or client-supplied source pseudonym is accepted or stored. A stats-host command issues a distinct random bearer token per installation. Redis stores only a keyed digest of that token and its server-generated HMAC pseudonym; the server derives the contributor identity from the credential, so clients cannot choose or spoof it. Tokens can be revoked individually. The server master secret remains on the stats host and must never be copied into a Windows agent or router image. The endpoint rejects unverified routes, contradictory verdicts, unsupported protocols, stale timestamps, and duplicate dimensions within one request. Rankings are advisory evidence only and must never trigger AUTO application.

## Redis bounds and aggregation

- One source may contribute at most 12 distinct dimensions per server UTC day and only once per dimension/day. The short-lived source dedupe keys expire after 48 hours.
- At most 2,048 active provider/profile/protocol/fingerprint dimensions are admitted globally. The 8-day counters and HyperLogLog contributor estimates expire automatically. The refresh worker prunes dimension registry entries whose metadata expired.
- A per-request idempotency key expires after six hours. Reusing an active request ID with a different payload is rejected.
- HyperLogLog estimates distinct sources; rankings require at least 10 estimated contributors and 10 measurements. Counts are freshness weighted with a one-day half-life and a Beta(2,2) prior. Ranking documents contain fingerprints and aggregate counts only.
- The active-dimension HyperLogLog ceiling alone is about 24 MiB at 2,048 dimensions. Other Redis keys and source sets add memory; the 32–64 MiB target is not measured or proven. Run the planned Redis memory and 100/1,000/10,000-client load tests before production activation.

`GET /z4r/adaptive-v2/rankings?provider=…&profile=1&protocol=tls` reads only the precomputed key and returns JSON. `GET /z4r/adaptive-v2/rankings.tsv` exposes the same bounded ranking in a strict TSV format for BusyBox routers without a JSON parser. Both return `not_ready`, `fresh`, or `stale`; neither scans aggregates. The systemd worker materializes rankings every 10 minutes with jitter. No endpoint sends commands, URLs, or auto-apply instructions to routers.

## Installation

Stage `adaptive_results.py`, `refresh_adaptive_v2.py`, and `adaptive_client_token.py` beside `deploy_adaptive_v2.py` on the stats host, provision the ingest master secret in `/etc/z4r-stats.env`, then review the generated backups and run:

```sh
python3 deploy_adaptive_v2.py --stage-dir /tmp --activate
```

The installer backs up the existing stats handler, env file, nginx snippet, and systemd files before patching. `--activate` runs Python compilation, `nginx -t`, restarts the stats service, reloads nginx, and enables the refresh timer. It does not activate any client uploader or AUTO strategy application. The ingest master secret in `/etc/z4r-stats.env` is server-only; never copy it into a released Windows agent or router image. Client authentication uses separately issued per-install credentials.

After a reviewed deployment, issue one credential for each explicitly opted-in pilot installation with `python3 adaptive_client_token.py issue`. Deliver the printed token through a secure, per-device channel. Revoke a leaked or withdrawn credential with `python3 adaptive_client_token.py revoke` and enter that token at the hidden prompt. Do not reuse the server master token as a client credential. Token issuance is bounded to 10,000 active credentials; the API does not offer a public enrollment endpoint.

On Windows, place the issued credential in the current user's `Z4R_ADAPTIVE_V2_CLIENT_TOKEN` environment and start the agent with `-UploadStatistics`; `-Watch -UploadStatistics` is needed for a continuously running sender. Without `-UploadStatistics`, the agent neither records nor sends collaborative statistics. Ranking reads are a separate opt-in through `-UseSharedRankings` and transmit provider/profile/protocol only; the switch is propagated through Watch-launched FastSearch subprocesses. The local spool contains provider, profile, protocol, fingerprint, and verdict only; it excludes target host/IP, scope, URL, test ID, and the token. Verified SUCCESS rows can come from normal FastSearch and exploration. Negative rows are currently restricted to opt-in `-Explore -UploadStatistics`: two identical route-verified `timeout` or `http_rejected` results for one exact strategy/target must be bracketed by successful DIRECT controls using the same TLS/HTTP recipe. A timeout is then recorded as transport FAIL; a repeated HTTP rejection is application FAIL. 429, 5xx, route-unverified, mixed, or inconclusive outcomes are never promoted. This is a conservative signal, not proof that every origin or client will behave the same way. Statistics-enabled exploration runs at least one 240-second cycle for its DIRECT+candidate pair; after four-probe failure confirmation it adds an eight-minute cooldown to stay below the intended low-priority budget. A 15–30 minute random delay batches at most 12 dimensions per request to respect the per-source daily cap; one-shot runs retain results until a later invocation if that delay has not elapsed. Pending spool data can be removed by deleting `%LOCALAPPDATA%\Zator\adaptive-stats-v2.json`. Upload failures retain the same request ID and payload for an idempotent retry and back off 15–30 minutes.

## Local checks

```sh
python3 tests/adaptive_stats_v2_test.py
python3 tests/adaptive_stats_v2_deploy_test.py
```

The aggregation tests use an in-memory Redis-compatible fixture. They check validation, client-token issue/auth/revocation, payload/idempotency rules, source and dimension caps, and ranking materialization. The deployment smoke applies the patch to a fixture server and exercises its handler over loopback HTTP with a narrow in-memory Redis adapter. The live test-server deployment below additionally covers the current stats handler, Redis Lua, and HTTPS routes on that test instance. Production compatibility and capacity remain unverified.

For an isolated real-Redis concurrency check, set `Z2R_ADAPTIVE_TEST_REDIS_URL` to a **disposable empty local database** (default `redis://127.0.0.1:6379/15`) and run `python3 tools/stats/adaptive_v2_load_test.py`. The runner submits 100, 1,000, then 10,000 synthetic clients with up to 64 concurrent workers, checks exact aggregate totals, reports p50/p95 latency and Redis memory, and removes only its adaptive V2 keys. It refuses non-loopback Redis and a non-empty database. The isolated test-server results below include this same run against the test VM's Redis 7.0.15 instance; they are not production measurements.

### Isolated test-server deployment and load (2026-11-21)

The installer was first applied to a fixture made from the test server's current `server_redis.py` and nginx snippet. Python compilation and `nginx -t` passed. V2 was then installed and activated on the isolated 1-vCPU test VM only. The installer retained backups of the handler, environment file, and nginx snippet. A random server-only ingest secret is stored in `/etc/z4r-stats.env` with mode `0600`; no client token was retained. The production stats host was not changed.

The existing stats, nginx, and Redis services remained active. `z4r-adaptive-v2-refresh.timer` is enabled and active; its first run completed successfully and published zero ranking groups, as expected before any pilot results exist. Direct HTTPS checks to the test VM returned `200` for JSON and TSV rankings (`status=not_ready`) and for the legacy recommendations endpoint. A POST without a bearer token returned `403`. An authenticated synthetic HTTPS submission returned `200 accepted=1`; replay returned `200 accepted=0`; reusing the request ID with a changed payload returned `409`. The temporary client token was revoked and every V2 Redis key from this integration check was removed.

The test VM had one CPU core, 1,967 MiB RAM, Redis 7.0.15, 417 existing DB 0 keys, and 17.3 MB Redis `used_memory` before the load run. AOF was disabled, the last RDB save status was `ok`, and `maxmemory` was unlimited; none of these settings were changed. Redis DB 15 was empty before and after the run. The measurements below are cumulative within that disposable database, so the final row covers 11,100 accepted synthetic clients and three dimensions.

| New synthetic clients | Workers | Ingest wall time | Throughput | p50 / p95 per ingest | Redis `used_memory` after stage |
|---:|---:|---:|---:|---:|---:|
| 100 | 64 | 0.034 s | 2,941/s | 1.432 / 2.741 ms | 17.91 MB |
| 1,000 | 64 | 0.401 s | 2,492/s | 11.705 / 42.305 ms | 20.73 MB |
| 10,000 | 64 | 2.706 s | 3,696/s | 14.217 / 37.249 ms | 26.78 MB |

This run added about 9.5 MB above the pre-run Redis memory baseline. It verifies concurrent ingestion and exact aggregation on the test VM, but does not measure CPU peak, AOF/RDB fork overhead during a write, long-term timer load, production traffic, or the production host's configuration. No production capacity claim follows from this result.

### Disposable Redis concurrency run (2026-11-21)

The load runner was executed against Redis 8.0.5 on loopback with persistence disabled. All exact aggregate checks passed; the runner removed its keys and the temporary Redis process was stopped afterward.

| New synthetic clients | Workers | Ingest wall time | Throughput | p50 / p95 per ingest | Redis `used_memory` after stage |
|---:|---:|---:|---:|---:|---:|
| 100 | 64 | 0.058 s | 1,726/s | 5.930 / 18.100 ms | 1.69 MB |
| 1,000 | 64 | 0.391 s | 2,560/s | 13.933 / 33.404 ms | 3.04 MB |
| 10,000 | 64 | 3.250 s | 3,077/s | 19.615 / 34.637 ms | 8.85 MB |

Each step adds to the prior synthetic population, so the last memory figure covers 11,100 accepted clients and three dimensions. This measures direct Python-to-Redis ingestion on one local WSL host, not concurrent HTTP requests, existing server data, other workloads, AOF/RDB fork overhead, disk pressure, or the production VM's CPU/memory limits. Production capacity and HTTP-layer acceptance remain open.

### Disposable real-Redis smoke (2026-11-21)

The Lua ingest and ranking path was additionally exercised against an isolated Redis 8.0.5 process in WSL, bound to localhost and stopped after the run. The disposable database contained only synthetic `Example ISP` results. Ingested 100, 1,000, then 10,000 unique sources into one dimension; duplicate request replay returned zero and request-ID reuse with a changed payload was rejected. Ranking materialization returned 10,000 exact successes and an HLL estimate of 9,946 distinct sources. The rendered TSV was 183 bytes. At 10,000 rows, the measured client-side ingest latency was p50 0.203 ms and p95 0.252 ms; Redis reported 7.63 MiB used memory and 20,005 keys.

This is a local single-process smoke, not a production capacity result: it does not include concurrent HTTP clients, other Redis workloads, AOF/RDB fork overhead, disk pressure, or the target VM's CPU and memory limits. HyperLogLog is approximate, so `samples` is an estimate; exact success/failure counters remain separate. The first validation assertion incorrectly expected HLL to return exactly 10,000; it was corrected to allow estimation error, and the ranking was verified against exact success totals.

### Read-only test-server follow-up (2026-11-21 07:57 UTC)

After the synthetic load run, a read-only SSH snapshot confirmed the test VM still has one vCPU and 1,967 MiB RAM, with 1,094,884 KiB `MemAvailable` and load average `0.00, 0.00, 0.00`. Redis 7.0.15 was active with 16.89 MiB `used_memory`, 30.04 MiB RSS, 28.97 MiB peak memory, and 418 DB 0 keys. AOF remains disabled, RDB reports `ok`, `maxmemory` remains unlimited, and DB 15 remains disposable. `nginx`, `redis-server`, `z4r-stats`, `z4r-dashboard`, and the adaptive refresh timer were active; the timer was waiting for its next run. No settings, services, or Redis keys were changed by this snapshot. These are current test-host values, not production measurements or a sustained CPU/fork-overhead result.
