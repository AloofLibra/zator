# Clone fake mode — internals and live-test findings (2026-10-03)

Reference for agents working on this branch. Everything below was verified
on live hardware (Keenetic KN-1011, Entware, mipsel, wan eth3) with real
Discord app traffic and tcpdump captures on the wan interface. Do not
"optimize" these rules away without re-running the live A/B — each one was
paid for with a broken flow.

## What the clone mode is

Per-profile fake mode (`mode_override.tsv`, menu 16 / webui panel):
`clone` replaces the strategy blob value `maxru|fake_default_tls` at
runtime with a ClientHello clone built from the user's own packet
(`tls_client_hello_mod`, innocent SNI from `sni_override.tsv` or
www.google.com). Applies without restart (2s TTL cache in locked.lua).
`classic`/no row = config blobs as written.

## The 1200-byte TSPU rule (hard, live-verified)

ANY TLS fake larger than 1200 bytes on the wire is dropped by the
middlebox TOGETHER WITH THE FLOW (silently: zero server responses, client
retransmission storm). Boundary measured with a padded hcaptcha blob:

| fake size | discord.com from the router |
|---|---|
| 660 (native) | 200 OK |
| 1200 | 200 OK |
| 1210 / 1240 / 1250 | dead (000) |

`locked.lua` therefore caps every TLS fake it serves (`fake`,
`fakemultisplit`, `fakemultidisorder` only — QUIC/Discord-UDP/STUN fakes
untouched) to `Z2R_TLS_FAKE_LIMIT_MAX = 1200`.

## The Discord app ClientHello is post-quantum

The desktop app (Electron/Chromium) sends a ~1720-byte ClientHello
record: key_share carries X25519MLKEM768 (~1216B of it). A naive clone is
therefore ~1812 bytes — over the limit — and dies.

## Clone oversize pipeline (locked.lua)

For a clone larger than the profile limit (`clonesize.tsv`, default 1200):

1. `z2r_clone_key_share_drop_pq` — drop POST-QUANTUM entries from
   key_share only; classic entries (x25519/secp256r1/384/521) stay.
   Result: a coherent "pre-pq browser" CH, ~1812 → ~520B. DO NOT remove
   key_share entirely — a TLS 1.3 CH without any key_share does not exist
   in real clients and the middlebox kills it (the first cut build died
   exactly there).
2. If still over: coherent extension groups (ECH; key_share +
   supported_groups + ec_point_formats together — last resort; padding;
   GREASE; session_ticket; ALPN; psk trio). SNI, supported_versions,
   signature_algorithms, renegotiation_info are never removed.
3. `z2r_clone_rerandomize` — fresh random + same-length session_id. The
   clone used to mirror the real CH's values; two CHs with identical
   random and different SNI inside one flow read as an obvious forgery.
4. If even the minimal set does not fit — fall back to the config blob
   (never send a structurally broken fake; zero-padding a small CH up to
   the limit is also fatal: a record with a garbage tail gets dropped).

## THE PAIRING RULE (most important, live-verified three times)

A cut clone only survives on WHOLE-FAKE instances:

- `fake:blob=...:repeats=N` + splitting the real stream WITHOUT a blob
  (e.g. Discord strategy 25 in the default config): cut clone flies whole
  in one packet — big-CH gateway flow alive, app starts.
- Mirror-fake strategies (`multisplit:blob=`, `fakemultisplit`,
  `fakeddisorder:blob=`, `fakemultidisorder` — the fake is cut along the
  REAL packet's segmentation, e.g. Discord strategy 7): a cut clone of a
  big CH kills the flow under EVERY cut variant tested (natural,
  semantic, pq + re-randomized). The app hangs at splash.

These are findings from the upstream author's live tests, not a restriction
enforced by this branch. At the owner's request, `blob_override_execute`
allows structural clone shortening for ALL sending strategies, including
mirror instances. A config-blob fallback is used only when a valid clone
cannot be built within the size limit, not because the strategy mirrors
fake pieces. Successful shortening alone does not prove application startup
for every strategy; verify the actual application separately.

Live confirmations on Discord profile:
- strategy 25 + clones: app starts, 5+ established flows, owner-confirmed UI;
- strategy 7 + clones (cut allowed on mirror, test patch): splash hang, 0
  useful flows — reproduced three times;
- strategy 7 + classic: fast start (the strategy itself is fine);
- strategy 26 (multisplit seqovl + multidisorder): cold start gave zero
  flows — treat as suspicious for clones.

## Files involved

- `orchestra/locked.lua` — mode/clone/cap hooks (test setter:
  `locked_load_mode_override_for_tests`, `locked_load_clone_size_for_tests`).
- `lib/orchestra_state.sh` — `mode_override_*`, `clone_size_*` helpers.
- `lib/submenus.sh` — menu 16 submenus; TEMPORARY Discord gate: switching
  profile 4 to clones asks for explicit confirmation (owner's request, do
  not remove without asking).
- `webui/cgi-bin/_lib.sh` + `TlsBlobPanel.vue` — fake_mode/clone_size POST,
  profile_modes/profile_sizes in state.
- `tests/fake_mode_smoke.sh` — static wiring + helper tests (green).

## Known repo blobs over the limit

`fake/quic_3.bin` (1357B) and `fake/discord_udp_1.bin` (1250B) exceed
1200. QUIC/UDP fakes are currently not capped by design (owner's request:
TLS only); revisit before shipping them to TLS contexts.
