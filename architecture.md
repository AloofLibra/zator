# Adaptive Strategy Selection

## 1. Проблема

Текущая autorotation построена вокруг последовательного перебора:

```text
strategy 1
   ↓ fail
strategy 2
   ↓ fail
strategy 3
...
strategy 43
```

Основные проблемы такой модели:

* новый domain всегда начинает практически с нулевого знания;
* пользователь может долго ждать до стратегии, которая уже хорошо зарекомендовала себя у этого провайдера;
* passive Lua detector может ошибочно ротировать рабочую strategy;
* результаты параллельных connections могут приходить после смены текущей strategy;
* обычный `curl` validator не гарантирует корректную оценку target;
* проблемы WAN/DNS/NFQUEUE могут ошибочно восприниматься как failure стратегии;
* TCP/QUIC и IPv4/IPv6 могут иметь совершенно разное поведение;
* линейный порядок создаёт сильный statistical bias — ранние стратегии тестируются намного чаще поздних.

Цель новой системы — перейти от **rotation** к **adaptive selection**.

---

# 2. Целевая архитектура

```text
                           Controller
                               │
          ┌────────────────────┼─────────────────────┐
          │                    │                     │
          ▼                    ▼                     ▼
   Evidence Engine       Probe Scheduler       Decision Engine
          │                    │                     │
          │                    ▼                     │
          │             Learning Plane               │
          │             nfqws-learning               │
          │                    │                     │
          │             synthetic probes             │
          │                    │                     │
          └──────────────┬─────┘                     │
                         ▼                           │
                    Evidence Store                  │
                         │                           │
                         └──────────────┬────────────┘
                                        │
                                        ▼
                              Strategy Policy
                                        │
                                        ▼
                                Production Plane
                                   nfqws-main
                                        │
                                  real traffic
                                        │
                                        ▼
                                  Flow Events
                                        │
                                        └──────────► Controller
```

---

# 3. Data Plane

## 3.1 Production Plane

`nfqws-main` обслуживает настоящий пользовательский traffic.

Его задачи:

* назначить flow конкретную strategy;
* применить packet manipulation;
* сохранить strategy attribution;
* собрать low-level telemetry;
* отправить события controller.

Он не должен самостоятельно реализовывать сложный adaptive selection.

---

## 3.2 Learning Plane

Отдельный instance:

```text
nfqws-learning
```

обслуживает исключительно test traffic.

Для него выделяется отдельная NFQUEUE.

Controller может независимо загрузить туда candidate strategy и выполнить synthetic request.

Это позволяет исследовать стратегии без риска сломать пользовательское соединение.

---

# 4. Flow attribution

Каждый новый flow получает immutable identity:

```text
flow_id
strategy_id
strategy_generation
host
scope
transport
ip_family
dst_ip
network_epoch
created_at
```

Все события flow должны сохранять эту attribution до конца его жизни.

Если controller уже поменял champion:

```text
generation 42 -> strategy 5
```

старый flow:

```text
generation 41 -> strategy 3
```

продолжает обновлять statistics strategy 3.

Это устраняет race между:

* параллельными connections;
* delayed packets;
* async validator;
* strategy promotion.

---

# 5. Evidence model

Passive detector перестаёт возвращать бинарное:

```text
success / fail
```

Использовать:

```text
STRONG_SUCCESS
WEAK_SUCCESS
UNKNOWN
WEAK_FAILURE
STRONG_FAILURE
```

Примеры.

### Strong success

* meaningful server application data;
* корректный HTTP response;
* устойчивый двусторонний stream;
* successful QUIC progress.

### Weak success

* ServerHello;
* небольшой server payload;
* connection progress без достаточного application evidence.

### Unknown

* client cancelled;
* проигравший Happy Eyeballs connection;
* connection слишком короткий;
* infrastructure issue;
* network unhealthy.

### Weak failure

* одиночный timeout;
* один подозрительный RST;
* небольшой stall;
* ClientHello retransmission.

### Strong failure

* несколько независимых flows одинаково fail;
* подтверждённый injected RST;
* ISP block response;
* controlled comparison: candidate A fails, candidate B succeeds.

---

# 6. Независимость observations

Несколько событий одного TCP connection не являются несколькими независимыми failures.

```text
RST
+
retransmit
+
stall
```

в одном flow — это один observation.

Основная единица learning:

```text
flow outcome
```

Параллельные flows одного browser burst также желательно группировать в short cohort, чтобы один page load не создавал десятки независимых votes.

---

# 7. Champion / Challenger

Для каждого context:

```text
(host, scope, transport, family, network_epoch)
```

хранятся:

```text
champion
challengers
candidate statistics
```

## Normal state

```text
champion = strategy 20
```

Большинство production flows получают 20.

## Suspicion

После накопления failure evidence:

```text
champion -> SUSPECT
```

Это ещё не означает rotation.

## Challenger test

Controller выбирает наиболее перспективный candidate:

```text
strategy 7
```

и проверяет его synthetic или natural flow.

## Promotion

```text
champion evidence bad
AND
challenger evidence good
```

только тогда:

```text
strategy 7 -> champion
strategy 20 -> quarantine
```

---

# 8. Synthetic validation

Synthetic validator используется как controlled experiment, а не как абсолютный oracle.

## Success

Корректный ответ реального server может считаться доказательством path success независимо от business result:

```text
200
301
401
403
404
429
5xx
anti-bot challenge
JS required page
```

если ответ явно пришёл от настоящего target.

## Explicit failures

Сильные failure:

* ISP block page;
* block redirect;
* deterministic TLS corruption;
* repeatable timeout, когда другой candidate в тех же условиях работает.

## Important

```text
probe FAIL != strategy FAIL
```

Если:

```text
A -> FAIL
B -> FAIL
C -> FAIL
```

результат:

```text
UNKNOWN / TARGET_UNPROBEABLE
```

Если:

```text
A -> FAIL
B -> SUCCESS
```

это сильное comparative evidence против A.

---

# 9. Probeability

Для host хранить:

```text
UNKNOWN
PROBEABLE
PARTIAL
UNRELIABLE
```

Если:

```text
real browser traffic -> works
synthetic -> consistently fails
```

host становится:

```text
UNRELIABLE
```

Synthetic evidence получает меньший вес либо временно отключается.

---

# 10. Natural experiments

Если synthetic validation невозможен, реальные client connections становятся experiment.

Например:

```text
champion 20 -> several failures

next suitable real flow
    -> challenger 7

7 -> strong success

=> promote 7
```

Так система не зависит от curl.

---

# 11. Provider / Network awareness

Главная цель — хороший cold start.

Knowledge hierarchy:

```text
GLOBAL
   ↓
PROVIDER
   ↓
NETWORK PROFILE
   ↓
HOST
```

Для нового host:

```text
host statistics = none
```

controller использует лучшие candidates network/provider model.

Пример:

```text
strategy 20 -> confidence high
strategy 7  -> confidence high
strategy 31 -> confidence medium
```

Первой пробуется 20, а не strategy 1.

---

# 12. Provider statistics

Не использовать raw usage count.

Старая sequential rotation даёт selection bias.

Для каждой strategy собирать минимум:

```text
unique_hosts_tested
unique_hosts_success
real_attempts
real_success
synthetic_attempts
synthetic_success
strong_failures
last_seen
```

---

# 13. Coverage и Reliability

Отдельно считать:

### Coverage

На какой доле различных hosts strategy оказывается рабочей.

### Reliability

Насколько стабильно strategy работает на hosts, где выбрана.

Например:

```text
strategy A
coverage = 85%
reliability = 94%

strategy B
coverage = 55%
reliability = 99.8%
```

Для cold start A может быть лучшим первым candidate.

Для конкретного уже изученного host B может быть лучшим champion.

---

# 14. Confidence

Нельзя считать:

```text
2/2 = 100%
```

надёжнее:

```text
950/1000 = 95%
```

Ranking должен учитывать sample size.

На первой реализации достаточно простой Bayesian/Beta-style confidence model или другой понятной статистической оценки.

Не требуется полноценный ML.

---

# 15. Context

Минимальный context:

```text
hostname
scope
transport
ip_family
network_epoch
```

Отдельно:

```text
TCP != QUIC
IPv4 != IPv6
```

`dst_ip` хранить как signal, но необязательно включать в primary state key, чтобы избежать state explosion на CDN.

---

# 16. Network Profile

Provider identity полезна, но недостаточна.

Один ISP может иметь разные DPI policies по:

* региону;
* BRAS/BNG;
* IPv4/IPv6;
* access network;
* subscriber pool.

Поэтому использовать concept:

```text
network_profile
```

который может включать доступные стабильные характеристики сети.

Provider/ASN используется как один из signals, а не единственный key.

---

# 17. Network Epoch

Создать `network_epoch`.

Новый epoch начинается после значимого изменения:

* WAN reconnect;
* смена внешней сети;
* изменение routing context;
* существенное изменение network profile.

Старая statistics:

```text
не удаляется
```

но превращается в prior.

Fresh observations нового epoch имеют больший вес.

---

# 18. Network Health Gate

Controller должен отличать:

```text
strategy failure
```

от:

```text
internet/router failure
```

Signals:

* WAN status;
* DNS health;
* default route;
* NFQUEUE drops;
* nfqws state;
* массовые failures unrelated hosts;
* system load.

Если network state плох:

```text
learning = frozen
promotion = frozen
quarantine = frozen
```

User traffic продолжает работать насколько возможно, но statistics не портится.

---

# 19. Failure classification

Не каждый failure лечится strategy selection.

Classifier:

```text
DNS
IP/ROUTE
DPI
SERVER
LOCAL
UNKNOWN
```

Пример:

```text
DNS poisoning
```

не должен приводить к перебору 43 DPI strategies.

---

# 20. Candidate Selector

Убирается:

```text
next = nstrategy + 1
```

Вместо него:

```text
select_candidate(context, failure)
```

Ranking учитывает:

```text
host history
network/provider prior
success probability
confidence
recency
coverage
reliability
failure affinity
strategy cost
quarantine
```

---

# 21. Strategy families

Желательно описать metadata strategy:

```text
family
aggressiveness
cost
useful_against
```

Например:

```text
strategy 20:
family = disorder
cost = medium
useful_against = clienthello_stall

strategy 31:
family = fake
cost = high
useful_against = rst
```

Failure type может изменять порядок candidates.

---

# 22. Strategy Cost

Когда несколько strategies одинаково надёжны, выбирать более дешёвую.

Cost может учитывать:

```text
fake packets
packet amplification
CPU
latency
disorder complexity
aggressiveness
```

Controller должен уметь:

```text
escalate
```

при проблемах и:

```text
de-escalate
```

если background learning нашёл более простую рабочую strategy.

---

# 23. Background Learning

Learning plane работает даже когда production исправен, но с небольшим request budget.

Цели:

* исследовать unknown strategies;
* устранить bias старой ротации;
* периодически revalidate good strategies;
* находить более дешёвую alternative;
* заранее иметь runner-up.

Пример:

```text
champion = 20
runner-up = 7
runner-up2 = 35
```

Если 20 деградирует:

```text
не начинаем поиск
```

а сразу имеем недавно проверенный candidate.

---

# 24. Adaptive Scheduler

Начальная версия:

```text
UNKNOWN
    -> test soon

PROMISING
    -> test more

GOOD
    -> occasional revalidation

CHAMPION
    -> periodic verification

BAD
    -> quarantine
       1m
       5m
       30m
       2h
```

Не делать permanent automatic ban.

---

# 25. Parallel comparative testing

При наличии ресурсов можно иметь несколько learning workers:

```text
test worker A -> strategy 7
test worker B -> strategy 20
```

и выполнять probes близко по времени.

Это улучшает сравнимость network conditions.

На router ограничить concurrency небольшим числом, например 2–3.

---

# 26. Prewarming

После определения network profile или нового epoch controller может выполнить небольшой calibration:

```text
top provider strategies
        ↓
learning plane
        ↓
current network ranking
```

Например:

```text
20 -> GOOD
7  -> GOOD
31 -> BAD
4  -> GOOD
```

Новый заблокированный host сразу начинает с:

```text
20
```

а не с 1.

---

# 27. Structured Event Log

Все важные события записывать machine-readable.

Минимальные types:

```text
FLOW_START
FLOW_END
SERVER_SEEN
FLOW_SUCCESS
FLOW_FAILURE

VALIDATION_START
VALIDATION_RESULT

CHAMPION_SUSPECT
CHALLENGER_TEST
STRATEGY_PROMOTE
STRATEGY_QUARANTINE

NETWORK_HEALTH
NETWORK_EPOCH
```

State хранить преимущественно в `/tmp`.

Избегать лишней записи во flash.

Phase 1 telemetry is sourced from the `nfqws2` conntrack C path in the user's
`AloofLibra/zapret2` fork. Apply
[`adaptive-flow-telemetry.patch`](patches/zapret2/adaptive-flow-telemetry.patch)
to that fork and build a binary supporting `--adaptive-events=<file>` before
enabling the option in a deployed config. The opt-in TSV v3 records flow start,
strategy attribution, its client scope, and flow end with C-owned tuple,
client source port, counters, timestamps,
RST/FIN flags, observed TLS ClientHello packet count and retransmissions of the
first observed ClientHello sequence, and termination reason. Flow IDs combine process ID and a local
sequence; strategy generation is assigned in C at attribution.

Conntrack table destruction now emits a terminal `FLOW_END` with reason
`process_exit` before freeing live entries, so orderly `nfqws2` shutdown no
longer leaves those observed flows open in a trace. Abrupt process death still
cannot emit a final event; replay must treat unmatched starts as incomplete,
never as strategy failures.

The optional file sink is capped at 4 MiB per trace and reserves room for a
`# TRACE_LIMIT` marker. On reaching the cap, C stops writing rather than
growing `/tmp`; replay emits a `TRACE_STATUS` row and counts any unmatched flow
starts as incomplete. This is a bounded capture sink for Phase 1, not the final
continuous controller IPC path.

The Lua compatibility hooks in the upstream `circular`, zator `circular_locked`,
and legacy `circular_quality` paths pass the strategy selection to C and execute
the id returned by C. They do not decide or rotate strategies. With no
`--adaptive-strategy` option, C returns the legacy-selected id unchanged. An
explicit `--adaptive-strategy=<profile>:<strategy>` pins only that profile in
that `nfqws2` process to the controller-supplied id; C stores the immutable
per-flow assignment and the Lua adapter only executes the matching plan
entries. This is a learning-instance primitive, not a production selector;
the option must not be added to the production daemon before a later canary
phase. Replay requires the `FLOW_END` attribution snapshot to match the
assignment event and rejects changes to the C-owned tuple context. A controller
must not act on missing or conflicting attribution.

The patch applies to `AloofLibra/zapret2` HEAD
`00f5aaa36de500971faf6db440dd7d8b25672281`. Current branch
`codex/adaptive-flow-telemetry` is pushed through `b44cf55`. Commit `2aca66d` adds the
acknowledged candidate control endpoint, v3 source-port telemetry, and aligns
pinned flow strategy generations with the acknowledged candidate generation.
It now also supports `GET_CANDIDATE v1`, so the probe reads the active
strategy/generation from C after worker restarts; commit `b44cf55` contains that
query and its clean Linux build passed.
The Linux `nfq2` build succeeds and `nfqws2 --help` exposes
`--adaptive-events`, `--adaptive-strategy`, and `--adaptive-control`.
The fork's active `build.yml` workflow covers its Linux cross-build matrix,
Android, Windows, and FreeBSD. Manual run
[`36010286865`](https://github.com/AloofLibra/zapret2/actions/runs/36010286865)
on branch `codex/adaptive-flow-telemetry` has completed all ten Linux target
builds successfully, including ARMv6, AArch64 and MIPSel. Its Android and
FreeBSD jobs also passed. The newer matrix run
[`36015382913`](https://github.com/AloofLibra/zapret2/actions/runs/36015382913)
completed successfully for Linux, Android, FreeBSD, and Windows at commit
`2aca66d`.
The C telemetry privilege-drop fix is pushed to that branch at `b1a9504`
(following `58671fb`). The MIPSel artifact is ELF32 little-endian MIPS R3000
and contains both adaptive CLI options. Draft PR #1 remains closed without
merge. The telemetry file sink checks write results and disables further trace
writes after a short or failed record write. The fork beta
`v1.0.5.2-adaptive-beta.1` is published as a prerelease with Linux, OpenWrt
embedded, Windows, Android, and FreeBSD archives; CI run
[`36021707984`](https://github.com/AloofLibra/zapret2/actions/runs/36021707984)
passed all platform builds. The matching zator prerelease `adaptive-beta.1`
is published from `develop`; its CI run
[`36023851594`](https://github.com/AloofLibra/zator/actions/runs/36023851594)
passed all ten static controller targets and assembled the deployable archives.
The rolling `latest` release now also contains the controller binaries used by
the opt-in installer.

Replay C telemetry with `python tools/adaptive_replay.py /path/to/events.tsv`.
Server payload is `WEAK_SUCCESS`; no server payload is `UNKNOWN`, never inferred
as strategy failure. The replay tool keeps a small shadow-only per-context
candidate/champion ledger: it needs two independent weak successes to name an
initial shadow champion; successes within the same 10-second interval per host,
scope, strategy, and transport/family context count once to reduce browser-burst bias.
It reports challengers after observations. It never
promotes over a champion because this telemetry version has no reliable
strategy-specific negative evidence. Replay network epoch and health remain
`unknown`; provider priors and active validation are later phases. v1 traces
remain readable with scope marked unknown.

---

# 28. Replay

Создать механизм:

```text
event trace
    ↓
controller replay
    ↓
decision output
```

Это позволяет воспроизводить реальные false rotation cases.

Regression test должен отвечать на вопрос:

> Принял бы новый controller то же ошибочное решение?

---

# 29. Shadow Mode

Новый controller сначала работает:

```text
observe
learn
decide
log
```

но не меняет production policy.

Сравнивать:

```text
legacy decision
new decision
actual observed outcome
```

Это позволит получить реальные метрики до включения нового механизма.

---

# 30. Метрики

Измерять минимум:

```text
time_to_working_strategy
false_rotation_rate
missed_failure_rate
strategy_changes_per_host
synthetic_probe_count
unknown_rate
recovery_time
provider_prediction_hit_rate
```

Особенно важна:

```text
provider_prediction_hit_rate
```

— как часто первая предложенная provider model strategy работает на новом host.

---

# 31. Этапы внедрения

## Phase 1 — Observability

Добавить:

* flow id;
* strategy attribution;
* generation;
* structured events;
* replay.

Не менять behaviour.

---

## Phase 2 — Evidence Engine

Перевести detectors на evidence model.

Добавить:

```text
strong/weak success/failure
unknown
```

Legacy autorotation пока остаётся production.

---

## Phase 3 — Network Context

Добавить:

* TCP/QUIC separation;
* IPv4/IPv6 separation;
* network epoch;
* health gate.

`lib/adaptive_context.sh` now exposes `adaptive_network_context_snapshot()` as
a BusyBox-compatible primitive collector. It fingerprints default routes,
default-interface addresses/MAC and resolver configuration, advances an
epoch counter under `/tmp`, and emits raw route, DNS-config, nfqws2,
NFQUEUE-presence, memory and load signals. These are observations, not a
`HEALTHY` verdict. In live socket mode, the native controller now independently
samples `/proc/net/route`, `/proc/net/ipv6_route`, and `/etc/resolv.conf` at
most once every 30 seconds, without shell subprocesses or
new packages. It binds the current sampled epoch to a flow when its C-owned
`FLOW_START` arrives and partitions candidate contexts by that epoch. Replay
from a saved v2 trace continues to report the epoch as unknown because that
trace has no network snapshot.

The shell collector's diagnostic epoch file and the controller's live epoch
counter are independent; they must not be compared or treated as the same
identifier.

The live epoch is a coarse controller context sample, not a low-level C flow
fact: a change immediately after a sample can remain undetected for up to 30
seconds. Flow identity, attribution and lifecycle still come only from C.
In live socket mode, flows that start without a readable route snapshot are
logged but excluded from candidate aggregates; the controller does not merge
them into a shared epoch-zero bucket. Offline v2 replay can still compare
unknown-epoch flows diagnostically, but that output is not a production prior.
Live health is `DEGRADED` only after two consecutive samples show no default
route in the main route tables or no configured resolver. A single such sample is `UNKNOWN` with reason
`CONFIG_DEGRADATION_UNCONFIRMED`; when both are present it is `UNKNOWN` with
reason `CANARY_REQUIRED`. Missing configuration is a warning signal, not proof
of Internet failure.
The controller never emits `HEALTHY` from route/DNS configuration alone and
does not infer strategy failure from absent server payload.
When a flow is attributed to a confirmed `DEGRADED` snapshot, the controller
still journals its C-owned outcome but freezes candidate/context updates for
that flow. `UNKNOWN` does not freeze positive weak-success evidence; missing
server payload remains unknown and never becomes negative strategy evidence.

This shell collector remains a bootstrap/diagnostic primitive and is not called
from packet handling or once per connection. The live controller's coarse
native snapshot keeps runtime dependencies small and bounded.

---

## Phase 4 — Shadow Controller

Реализовать:

* candidate statistics;
* champion/challenger;
* confidence;
* quarantine;
* ranking.

Работает только shadow.

`tools/adaptive_controller.c` is the first native Phase 4 implementation. It
consumes C-owned TSV v2/v3 on stdin or Linux Unix datagrams, uses only POSIX/C library facilities, keeps
fixed-capacity flow/context/candidate tables, expires idle aggregate state,
and emits TSV shadow outcomes. It requires an explicit `FLOW_START` plus an
immutable strategy assignment; weak success needs server payload, while silence
remains unknown. Two successes separated by the 10-second cohort window can
name an initial shadow champion or mark a challenger ready. It never promotes,
quarantines, or changes a production strategy.

Candidate attribution also requires a non-empty hostname at `FLOW_END`. When
hostname discovery never succeeds, the flow remains visible as
`UNATTRIBUTED`, but it cannot update a shared empty-host candidate context.
This avoids combining unrelated destinations until the C event contract and
controller expose a stable fallback host key.

Build/run locally with a C99 compiler, then pipe TSV events to the binary:

```sh
OUT_DIR=/tmp/adaptive-build tools/build-adaptive-controller.sh host
/tmp/adaptive-build/adaptive-controller-host < events.tsv
sh tests/adaptive_controller_smoke.sh
```

The smoke checks champion/challenger,
unknown evidence, delayed hostname discovery, missing start events, trace
truncation, bounded-table overflow, Unix-socket gap invalidation and rejection
of a second listener on an active socket path.

Cross-build all router Linux targets with the matching `*-gcc` cross compilers
on `PATH`:

```sh
OUT_DIR=/tmp/adaptive-build tools/build-adaptive-controller.sh all
```

This is a controller core/prototype, not yet connected to adaptive policy
changes or deployed by default. The `deploy-tar` workflow cross-builds a static
binary per supported Linux target and attaches each as a separate release
asset plus a SHA-256 sidecar. This keeps the normal zator archives free of
unused architecture binaries and lets the opt-in installer fetch only the
matching small binary; `lib/adaptive_controller.sh` maps router `uname -m`,
checks the digest and 144 KiB size ceiling, and refuses to fetch in offline
mode. The workflow also rejects dynamically linked or unexpectedly large
outputs. No process starts and no runtime dependency is added unless the
operator explicitly enables menu item 24. The menu is
available on OpenWrt and Keenetic Entware and is guarded by the installed
`nfqws2 --help` option check. On OpenWrt, procd supervises a controller
service started before zapret2; on Keenetic, the Entware `S89` service starts
before `S90-zapret2`. C telemetry is added
to the nfqws2 arguments only while the marker file is present. Both service
paths stop cleanly when disabled, and full zator removal uninstalls their init
entries. The controller writes a 256 KiB maximum decision log under tmpfs,
keeps evidence only in bounded memory, and never modifies production
strategy. It still requires the telemetry patch in the deployed nfqws2 fork;
the release installer refuses to turn on shadow mode without that support.
The service checkpoints only aggregate candidate/context data to a 128 KiB
bounded file in `/tmp`, every five minutes and on graceful stop. A checkpoint
is restored only during the same system uptime; after reboot or a bad/partial
checkpoint the controller starts with empty aggregates. Open flows are never
restored, and an interrupted flow cannot become negative evidence. No
checkpoint is written to flash. The v2 checkpoint also carries the current
network fingerprint and epoch; on same-uptime restart an unchanged fingerprint
continues the epoch, while a changed fingerprint starts a fresh context. The
route/DNS sampling estimate has at most 30 seconds of detection lag.
Production-calibrated confidence,
negative-evidence quarantine, and reboot-safe learning remain later work.
Current ranking is a deterministic ordering
by independent weak-success count, with strategy id as a tie-breaker. The
reported `confidence_lcb95_milli` is a conservative integer lower-bound proxy
`successes / (successes + 4)` on a 0–100000 scale; unknown outcomes do not count
as failures, and quarantine is always `NONE` until reliable negative evidence
exists. Native decision-journal TSV v3 preserves the C flow's packet/byte
counters, server visibility/payload, RST/FIN flags, connection timestamps,
ClientHello counts/retransmissions, termination reason, and source port alongside
`network_epoch`, `network_health`, and `network_health_reason`. These are
reported as C telemetry, not reinterpreted as extra evidence. Replay retains
`UNKNOWN` health unless future traces carry a validated network snapshot.
Output is TSV, not JSON.

The controller uses fixed limits (256 open flows, 128 contexts, 384 candidates)
and expires idle aggregate records after seven days. Static cross-builds for
all ten supported Linux targets succeeded after adding the bounded journal,
network epoch and health observations, and tmpfs checkpoint; stripped ARMv6,
MIPSel, and PowerPC binaries are 45.4 KiB, 82.0 KiB, and 65.2 KiB,
respectively, with about 164 KiB of BSS. The build disables C unwind tables to
avoid unnecessary static text and linker page-padding on small targets. The
Python replay remains the development analyzer; it accepts C telemetry v1/v2/v3
and `PROBE_RESULT v1` records. It reports strong active success only when curl
received an HTTP status and one usable learning flow matches hostname, source
port, strategy, and C candidate generation. Missing or ambiguous matches stay
uncorrelated/unknown. Neither router controller source nor its smoke test
depends on Python at runtime.

The core also has a Linux Unix-datagram listener mode:
`adaptive-controller --socket /tmp/zator-adaptive/events.sock`. This is the
intended low-cost streaming IPC path; the controller blocks in `recv`, while
`nfqws2` sends each small event with a nonblocking datagram. Send failures are
counted by C and reported with a `# EVENT_GAP` marker on the next successful
send. The controller clears in-flight attribution on a gap so a partial flow
cannot update candidate statistics. The C sender is available as
`--adaptive-events=unix:/tmp/zator-adaptive/events.sock`. The zator menu
installs the target-specific controller only on explicit enable, prepares a
private tmpfs directory, starts its platform service, then restarts nfqws2.
The telemetry argument is conditional on the marker and runtime help check;
disabling stops the controller and removes the argument on restart.

For supervised shadow mode, the controller accepts optional
`--output /tmp/zator-adaptive/shadow.tsv`. That append-only output is owner-only
and capped at 256 KiB; once full, it writes a single `# OUTPUT_LIMIT` marker
and continues learning in memory without further disk writes. The default
stdout/replay path is unchanged. The output is an inspectable bounded decision
journal, not a checkpoint. The separate `--state /tmp/zator-adaptive/state.tsv`
option enables the bounded same-uptime checkpoint described above.

---

## Phase 5 — Learning Plane

Создать:

```text
nfqws-learning
dedicated NFQUEUE
probe steering
```

Реализовать deterministic candidate attribution.

`nfqws2 --adaptive-strategy=<profile>:<strategy>` provides the C-owned initial
pin primitive for a dedicated learning instance. The fork patch adds
`--adaptive-control=<unix_path>` and a bounded `SET_CANDIDATE v1` datagram
protocol with an ACK. C binds the private socket before dropping privileges,
validates the configured profile and positive strategy ID, then snapshots the
candidate and candidate generation into new conntrack entries. Changing the
candidate therefore affects only new flows; existing assignments remain
immutable. A small `adaptive-controller --set-candidate` client sends the
command and waits for the C ACK. The shell validates the requested strategy
against the extracted TLS plan before updating the live worker. Lua reads the
C-pinned id only to execute configured plan entries; production gets no
control endpoint. The C telemetry is v3 and includes the client source port,
so learning probe flows can be separated from other flows to the same host.
The bounded candidate selector and operator-started comparison runner are now
implemented; a learning instance must not use the legacy `circular_quality`
state-writing path.

An execution-only Lua adapter now exists at `lua/adaptive-executor.lua`. It
asks `flow_strategy_assign` for the C/conntrack-pinned strategy and executes
only plan instances tagged with that ID; if the C assignment is unavailable,
it passes the packet. `z2r.sh` deploys and preserves this adapter, and the tar
builder includes it with the other Lua runtime files. This is a primitive for
the isolated worker, not a runnable learning integration by itself.

`adaptive_learning_config_write` in `lib/adaptive_controller.sh` now constructs
a single-profile TLS learning config from only the shared
`z2r_tcp_tls_common` template and its blob declarations. It adds the C strategy
pin and telemetry socket and deliberately excludes the production Lua init
entries. The deployed `custom.d` hook calls this writer when learning is
explicitly enabled and a candidate strategy is supplied. The acknowledged C
control path can update that candidate without restarting the worker. The
bounded selector and operator-started comparative probe runner are implemented
in Phase 5; live firewall and flow-correlation validation remains outstanding.

The generated executor uses the reserved scope `learning` and sends C telemetry
to the existing controller socket. Scope is part of the controller's
host/profile/transport context key and its persisted checkpoint, so learning
observations do not update the production default/client-mark context and do
not require a second resident controller process.

The C telemetry transport now connects its Unix datagram socket while
`nfqws2` is still privileged, before `--user` drops it. Packet-path telemetry
uses the retained nonblocking connection, so the controller's private
`0700` directory and `0600` socket do not need to be opened to `nobody`. File
telemetry is likewise opened once before privilege drop and kept bounded.

The generated `--adaptive-strategy=1:N` profile number is grounded in the
fork parser: `nfqws2` starts its first active profile at `dp->n == 1`, and a
`--new` that closes a template does not increment the active profile count.
The learning config therefore closes the extracted template before defining
its one active profile, which retains ID 1 for both C pinning and telemetry.

`adaptive_learning_wrapper_install` now creates the minimal exec wrapper
required by `nfqws2 @<config_file>` and the shared `do_nfqws` API. It validates
the binary path and executes the isolated config as the sole argument, ignoring
the shared args appended by zapret2. The disabled-by-default
`adaptive/90-zator-adaptive-learning` custom daemon hook now calls the writer
and wrapper when both `adaptive-learning.enabled` and a numeric
`adaptive-learning.strategy` are present, and the z2r deploy path installs it
under both platform `custom.d` directories. It feeds the existing controller
through `scope=learning`. It also installs scoped firewall rules for TCP/443
sockets bound to the dedicated local source-port range 62000–62015. The
iptables callbacks mark router-originated packets, save/restore the adaptive
bit in conntrack, queue request and reply packets, and add scoped ACCEPT rules
after NFQUEUE so accepted probes cannot fall through to the production queue.
The nft callbacks use dedicated subchains, conntrack mark restoration, and
parent-chain return guards for the same isolation. Queue bypass preserves
connectivity if the learning daemon is absent. The adaptive mark defaults to
`0x08000000`; steering is refused if it overlaps DESYNC_MARK,
DESYNC_MARK_POSTNAT, or FILTER_MARK. Other mark owners must reserve or change
this bit before opting in. `adaptive/probe-once.sh` provides one explicitly
requested HTTPS probe using a serialized local source port selected
round-robin from 62000–62015. Firewall setup and the probe driver verify that
this range does not overlap the kernel's configured ephemeral range; steering
is refused when the range cannot be verified. It has a 15-second request bound, does not retry
or schedule background traffic, and requires the opt-in marker and controller
socket. Before curl starts, it registers a bounded probe lease with the
resident controller using the current C worker strategy and generation; after
curl exits it reports its exit code, HTTP status, and elapsed time over the
same private socket, including when curl fails. The controller joins this
report with one C `FLOW_END` using learning scope, normalized host, source
port, profile, actual strategy, and generation. It accepts either arrival
order, requires one unique `FLOW_START` candidate and a one-second quiet
interval, and emits one `PROBE_OUTCOME`. A valid HTTP response plus an
attributable, usable, non-degraded C flow contributes exactly one active-probe
success to that candidate. Leased flows bypass the passive `server_seen`
success update; invalid, failed, incomplete, ambiguous, or missing joins add no
negative vote. The lease expires after 90 seconds, and short-lived source-port
tombstones prevent late terminal events from being re-counted as passive
observations. Manual candidate updates and probes share an exclusive runtime
lock. `adaptive-learning.strategy` persists the worker's current id; a bounded
C selector is available through
`adaptive-controller --next-candidate`. The caller must provide the explicit
TLS-plan allowlist, host, profile, and total settled-attempt budget. C picks the
least-tried allowed candidate (numeric id breaks ties), consumes budget only
when a probe lease settles, and counts `UNKNOWN` only as a scheduling attempt,
never as negative evidence. It refuses unknown/degraded network state or an
active probe, with limits of 64 candidates and 1024 settled attempts. Menu
item 25 offers an operator-started comparison runner bounded to 64 attempts
per invocation: it extracts the
allowlist from the live TLS template, asks C for each next candidate, applies
the acknowledged worker update, and starts one probe at a time. It stops on
the total attempt budget or any setup error. Failed or uncorrelated leases
remain `UNKNOWN`. Probe correlation has not yet been validated
on a live router and depends on the deployed nfqws2 emitting the v3 client
source-port field.

Menu item 25 enables/disables this learning-only worker and asks for the TLS
strategy id. While enabled it can also set a new candidate or start the bounded
comparison runner; it validates that
the strategy exists in the extracted TLS plan, sends it to C, waits for ACK,
and persists it for worker restart. It checks mark overlap and C option support,
starts the controller, installs the custom hook and restarts zapret2. The controller init services now start
when either shadow or learning is enabled; previously their shadow-only guard
made learning-only mode impossible. Menu item 24 remains the separate passive
production shadow switch and does not change production strategy.

**Deployment gate:** patched `nfqws2` binaries are available in the
`AloofLibra/zapret2` prerelease `v1.0.5.2-adaptive-beta.1`; zator prerelease
`adaptive-beta.6` ships controller executables for ten Linux targets. Zator's normal zapret2
installer and carried-forward offline archive still use the MarkinAlexander
build, so they do not automatically install the patched C binary. Install the
matching fork archive separately before enabling shadow telemetry or learning.
The runtime checks `--adaptive-events`, `--adaptive-strategy`, and
`--adaptive-control`, and refuses to enable either mode when an option is
missing. Live router verification of firewall steering, source-port attribution,
and probe correlation is still required.

### Integration constraints verified against the zapret2 fork

The supported `init.d/{openwrt,sysv}/custom.d` hook can allocate independent
daemon and queue numbers (`alloc_dnum`, `alloc_qnum`), start an additional
`nfqws2` (`do_nfqws`), and add/remove firewall rules through its lifecycle
callbacks. This is the intended integration point; do not patch the upstream
standard daemon's queue rules to capture learning probes.

However, a custom daemon is not isolated merely by giving it another queue:
`do_nfqws` prepends the platform's shared `NFQWS2_OPT_BASE`. On OpenWrt this
base loads upstream `zapret-auto.lua`; on Keenetic the zator init loads the same
Lua stack. Passing the production `NFQWS2_OPT` also loads zator's
`combined-detector.lua`, whose `circular_quality` path rotates strategies and
writes automatic locks. Therefore the learning worker must receive a
purpose-built option/config slice and an execution-only adapter that consumes
the C-pinned strategy. Reusing the production option string or merely adding a
second NFQUEUE would violate the controller/Lua ownership boundary.

Probe steering uses a paired contract: the probe client must bind the reserved
local source-port range, and custom firewall callbacks route that traffic into
the learning queue with queue bypass. A scoped ACCEPT or subchain return after
the learning queue prevents a packet accepted by NFQUEUE from falling through
to the production queue. The worker sees reply packets only when conntrack
retains the adaptive mark. The iptables and nft callbacks and one-shot probe
driver now exist; rule order and teardown still require validation on
representative OpenWrt nftables and Keenetic iptables routers. The controller
joins each probe's HTTP result to a unique learning flow using the reserved
source-port range and C-owned strategy generation; ambiguous or missing joins
remain unknown. The workflow supports manual candidate changes and bounded
operator-started comparative probes. Automatic background exploration and
production decisions remain future phases, so this is an operator-driven
learning PoC.

There are two additional mechanics to account for in that integration:

* `nfqws2 @<config_file>` is explicitly a config-only invocation. The generic
  `do_nfqws` prepends `NFQWS2_OPT_BASE`, so it cannot launch an isolated config
  as `@file`; use a small exec wrapper (or extend the C CLI to support a
  config-plus-runtime-arguments form) and put queue, mark, telemetry and
  strategy pin in the isolated config itself.
* The zapret2 iptables helper inserts rules at the head of POSTROUTING, and
  nftables uses `insert rule`; in either backend an NFQUEUE ACCEPT verdict
  resumes processing at subsequent rules. The current steering callbacks put
  a scoped ACCEPT or parent-chain return after the learning verdict to keep
  the probe out of production NFQUEUE. Queue bypass keeps the request moving
  when the learning daemon is absent.

---

## Phase 6 — Active Validation

Добавить:

* synthetic probes;
* comparative validation;
* probeability;
* adaptive retry.

The first active comparison runner uses one HTTPS HEAD request per candidate,
correlated to exactly one C learning flow. Settled `PROBE_OUTCOME` rows are
written into the bounded controller journal as versioned v2 records with the
probe id, outcome, reason, assigned strategy/generation, host, source port,
HTTP result, correlated flow id, network epoch/health and context usability.
When C flow correlation succeeds, the record also carries raw packet/byte
counters, server/RST/FIN flags, ClientHello retransmissions and termination
reason. The PC analyzer emits these as observed facts; they are diagnostic and
does not turn them or curl error classes (DNS, connect, timeout, TLS, receive)
into strategy failure votes.
`python tools/adaptive_replay.py --controller-output
/tmp/zator-adaptive/shadow.tsv` reports attempts,
confirmed successes, unknowns, and host/strategy probeability by network epoch;
it also reads v1 and unversioned probe rows left by earlier beta upgrades.
Unknown outcomes do not become failures, and the analyzer reports zero failure
votes because this probe has no trusted explicit-block classifier. Synthetic
no-strategy controls, explicit block classification, and retry after
independently verified infrastructure recovery remain open Phase 6 work.

---

## Phase 7 — Provider Learning

Добавить:

* global priors;
* provider/network profile priors;
* coverage/reliability;
* cold-start ranking.

---

## Phase 8 — Background Exploration

Добавить scheduler:

* unknown exploration;
* revalidation;
* runner-up maintenance;
* strategy de-escalation.

---

## Phase 9 — Canary Production

Включить новый controller для ограниченного числа profiles/hosts.

Legacy fallback оставить.

---

## Phase 10 — Full Migration

После получения метрик и replay regression:

```text
legacy circular_quality -> deprecated
adaptive controller -> default
```

---

# 32. Что оставить из существующей реализации

Можно переиспользовать:

* strategy definitions;
* host normalization;
* manual locks;
* detector heuristics;
* deployment/service scripts;
* async validator infrastructure;
* platform support.

Не нужно сохранять ради совместимости:

* sequential rotation semantics;
* `nstrategy++`;
* passive auto-lock logic;
* permanent auto-block;
* текущие lock success thresholds.

---

# 33. MVP

Первая версия не обязана сразу реализовывать всю систему.

Минимальный полезный MVP:

```text
flow attribution
+
evidence model
+
network health gate
+
champion/challenger
+
learning NFQUEUE
+
provider-ranked candidate selector
+
shadow mode
+
replay
```

Без ML.

Без distributed statistics.

Без headless browser.

Без модификации nfqws2 сверх необходимой telemetry/strategy attribution, если это можно реализовать существующими средствами.

---

# 34. Главные инварианты

Эти правила не должны нарушаться ни одной оптимизацией:

1. Один flow никогда не меняет strategy задним числом.
2. Один uncertain failure не переключает champion.
3. `probe failed` не равно `strategy failed`.
4. Global network failure не ухудшает strategy statistics.
5. TCP/QUIC и IPv4/IPv6 не смешиваются.
6. Manual user decisions сильнее automatic learning.
7. Automatic negative knowledge всегда имеет TTL.
8. Новый host не обязан начинать со strategy 1.
9. Background exploration не должно ломать user traffic.
10. Любое automatic decision должно быть объяснимо через event history.


# 35. Important implementation clarification
Не пытайся исправлять надёжность текущего механизма за счёт дальнейшего усложнения circular_quality.lua, combined-detector.lua или другой Lua-логики autorotation.
Lua-реализация считается legacy и не является целевой точкой развития.
Если для нового механизма не хватает достоверных данных о состоянии connection, применённой strategy или lifecycle flow — дорабатывай C-часть ****nfqws2, а не добавляй новые эвристики в Lua.
В частности, при необходимости добавляй в C/conntrack:
flow_id
strategy_id
strategy_generation

hostname / hostkey
transport
ip_family
dst_ip

bytes_in / bytes_out
packets_in / packets_out

server_seen
server_payload_seen

clienthello_count / retransmissions

RST / FIN information
connection timestamps
connection lifecycle / termination reason
C-часть должна быть authoritative source of truth для:
- идентичности flow;
- фактически применённой к flow strategy;
- connection state;
- packet/byte progress;
- low-level transport events.
Не реконструируй эти данные в Lua, если их можно получить непосредственно из conntrack/nfqws2.
Целевая ответственность компонентов:
nfqws2 C
    -> применяет strategy
    -> ведёт conntrack
    -> собирает достоверную flow telemetry
    -> выдаёт primitive events

Controller
    -> агрегирует evidence
    -> хранит статистику
    -> выполняет provider/network learning
    -> управляет champion/challenger
    -> выбирает и меняет strategy

Lua
    -> legacy / optional lightweight detector layer
    -> не владеет autorotation state
    -> не выполняет nstrategy++
    -> не выполняет auto-lock/unlock
    -> не принимает окончательное решение о смене strategy
Не переносить весь adaptive algorithm в C.
Правило:
Если вопрос “что произошло с конкретным flow?” — источник истины должен быть в nfqws2/C.
Если вопрос “какую strategy выбрать дальше?” — это задача controller.

Приоритет реализации:
1. Сначала определить, каких flow-level данных сейчас не хватает.
2. Добавить необходимые primitives/telemetry в nfqws2.
3. Только после этого строить новый controller.
4. Не тратить время на полировку существующей Lua autorotation, кроме изменений, необходимых для совместимости, shadow mode или постепенной миграции.
Текущая Lua autorotation должна рассматриваться как временный legacy fallback до завершения нового механизма, а не как база, которую нужно улучшать.


## Router resource constraints

Целевая среда — в первую очередь OpenWrt/Keenetic и другие маломощные роутеры.

Новый механизм **не должен требовать тяжёлых runtime-зависимостей**.

Запрещено делать обязательными:

```text
Python
Node.js
Java/JVM
.NET
headless Chromium
Playwright/Selenium
Redis
PostgreSQL
SQLite
отдельный application framework
```

Не предполагать, что на роутере доступен полноценный GNU userspace.

Ориентироваться на:

```text
C
BusyBox / POSIX sh
существующие библиотеки nfqws/zapret2
стандартные возможности Linux/OpenWrt
```

### Controller

Если adaptive controller реализуется отдельным процессом, он должен быть **небольшим native binary**, предпочтительно на C.

Пример целевой архитектуры:

```text
nfqws-main
     │
     │ flow telemetry
     ▼
z2r-controller      <- small native C daemon
     │
     ├── evidence state
     ├── champion/challenger
     ├── provider/network statistics
     ├── candidate ranking
     ├── health gate
     └── learning scheduler
     │
     ▼
nfqws-learning
```

Разделение Control Plane и Data Plane является логическим и не требует тяжёлого отдельного runtime.

### IPC

Предпочитать простые системные механизмы:

```text
Unix domain socket
FIFO
small binary protocol
simple line-oriented protocol
```

Не добавлять message broker.

Протокол должен быть:

* дешёвым по CPU;
* дешёвым по RAM;
* простым для debug;
* versioned;
* устойчивым к restart одного из компонентов.

### Runtime state

Основное learning state держать в памяти controller.

Временные файлы размещать в:

```text
/tmp
```

Не выполнять постоянную запись counters/events во flash.

Если требуется переживать reboot, сохранять только компактный агрегированный snapshot:

```text
provider/network priors
known champions
strategy statistics
```

с редкими checkpoint, а не после каждого flow.

Не использовать embedded database без серьёзной необходимости.

### Logging / replay

Structured event log также должен быть lightweight.

Допустимы:

```text
compact TSV
line-oriented records
compact binary records
```

JSON допустим только если его можно генерировать/читать без добавления тяжёлого JSON runtime и он не создаёт заметной нагрузки.

Replay tooling для разработки **может быть более тяжёлым и работать на PC**, но runtime-компоненты роутера не должны зависеть от него.

Например:

```text
router:
    writes compact trace

developer PC:
    Python/other tooling may analyse/replay trace
```

То есть запрет на Python относится к **router runtime**, а не к development/test tooling на рабочей машине.

### Active probes

Не делать архитектуру зависимой от headless browser.

Также не считать наличие `curl` фундаментальным требованием системы.

Для первого PoC допускается использовать `curl`, если он уже присутствует в поддерживаемом окружении.

Production design должен позволять заменить его:

* небольшим native probe helper;
* уже доступным системным HTTP client;
* либо минимальной реализацией поверх библиотек, которые уже присутствуют в firmware/zapret2.

Не добавлять крупную TLS/HTTP-зависимость только ради validator, если необходимая функциональность уже доступна другим способом.

### Resource budget

При проектировании считать RAM, CPU и размер firmware такими же важными критериями, как correctness.

Новый механизм должен:

* практически ничего не потреблять в idle;
* ограничивать число parallel probes;
* иметь bounded caches;
* иметь bounded event/history storage;
* удалять устаревший host state;
* не создавать отдельный process/thread на каждый host или flow;
* избегать частых fork/exec в hot path.

Initial router acceptance criteria:

* no new mandatory package beyond the supported firmware/base system and existing zapret2 dependencies;
* idle controller must not poll frequently or spawn per-flow subprocesses;
* RAM, event queue, host cache and probe concurrency are bounded; overflow drops or marks evidence rather than blocking nfqws2;
* event and temporary state writes go to `/tmp`; persistent writes are limited to infrequent compact aggregate checkpoints;
* replay/analyzer and build tooling may use Python or other developer-machine dependencies, but router operation and recovery must not depend on them.

`nfqws-learning` также не должен постоянно генерировать background traffic. Exploration работает с ограниченным request budget.

### Implementation rule

Если есть выбор между:

```text
простая native реализация
```

и:

```text
более удобная реализация с новым тяжёлым runtime/dependency
```

для router runtime выбирать native реализацию.

Не добавлять dependency только ради удобства разработки.
