# AGENTS.md

## Purpose

This repository is a shell-based installer and management wrapper around `zapret2`, with:

- a custom `config.default`
- interactive maintenance menus
- strategy selection and locking
- shipped hostlists and fake payloads
- a small local WebUI for status, service control, checks, and strategy locks
- bundled `blockcheck2` z4r test inputs
- platform-specific patches for VPS, OpenWRT, Keenetic Entware, and Merlin
- an "orchestra" layer that tracks and pins working strategies
- Lua modules for desync orchestration, grouping, lock management, RST guard, and failure detection

Primary entrypoint:

- `z2r.sh`: main script for install, update, environment detection, config deployment, menu actions, and strategy lock lifecycle.

External launcher:

- [`AloofLibra/z4r:z2r`](https://github.com/AloofLibra/z4r/blob/z2r/z2r) is the POSIX `sh` bootstrap/update launcher distributed to users. It lives in a separate repository and installs the persistent `z2r` command, downloads this repository's `zator` branch into the `/opt` runtime layout (including `z2r.sh`, `lib/`, and orchestra files), then runs `/opt/z2r.sh`.
- Changes to download paths, branch names, deployed library or orchestra filenames, install layout, and bootstrap/update behavior must be checked for compatibility with this external launcher. If the launcher also needs a change, note that explicitly because it cannot be updated from this workspace.

Secondary helper scripts:

- `z4r_test.sh`
- `user_test2.sh`
- `merlin_wan_restart_zapret.sh`

## Current Runtime Model

This project is no longer centered on `/opt/zapret`. The active target layout is `/opt/zapret2`.

Most runtime logic assumes these absolute paths:

- `/opt/zapret2/config`
- `/opt/zapret2/config.default`
- `/opt/zapret2/extra_strats/...`
- `/opt/zapret2/extra_strats/cache/orchestra/...`
- `/opt/zapret2/lists/...`
- `/opt/zapret2/files/fake/...`
- `/opt/zapret2/lua/...`
- `/opt/zapret2/init.d/...`
- `/opt/zapret2/webui/...`
- `/opt/zapret2/z2r_lib/...`

Normal flow:

1. `z2r.sh` detects OS and hardware.
2. It installs or refreshes upstream `zapret2`.
3. It deploys this repository's assets into `/opt/zapret2`.
4. It installs the custom config, extra strategy files, lists, fake payloads, Lua scripts, blockcheck inputs, WebUI files, and orchestra state files.
5. It manages `zapret2`, WebUI, blockcheck summaries, and manual strategy locks through an interactive menu.

## Layout

- `z2r.sh`: top-level orchestration script. Sources runtime modules from `zapret2/z2r_lib` after deployment, while this repository stores their source versions in `lib/`.
- `config.default`: main shipped `zapret2` config. This is now a large profile-driven config with `--lua-init`, `--lua-desync`, profile blocks, fallback blocks, blob declarations, and strategy numbering that other scripts depend on.
- `lib/ui.sh`: generic menu and terminal UI helpers.
- `lib/provider.sh`: ISP/provider and location detection, cache, and manual override.
- `lib/telemetry.sh`: telemetry enable/disable and stats sending.
- `lib/recommendations.sh`: hint database and provider-based recommendations.
- `lib/netcheck.sh`: connectivity tests, CDN tests, and YouTube cluster probing.
- `lib/premium.sh`: easter-egg and premium menu branches.
- `lib/strategies.sh`: active strategy status, orchestra lock helpers, per-profile strategy trial flow, custom RKN domain handling.
- `lib/submenus.sh`: menu wiring for strategies, provider, offload, and related actions.
- `lib/actions.sh`: config reset, backup, firewall mode switch, UDP toggles, TLS blob switching, and other menu actions.
- `lib/config.sh`: shared shell helpers for reading/editing `/opt/zapret2/config`, mode labels, profile strategy counts, TLS blob mode, and Keenetic WAN interface detection.
- `lib/orchestra_state.sh`: shared shell helpers for reading/writing orchestra lock TSV files and checking `nfqws2`.
- `lists/`: shipped hostlists and ipsets.
- `fake/`: fake payload binaries, including TLS, QUIC, Discord UDP, SYN, and WireGuard initial payload variants.
- `fake_files.tar.gz`: archive deployed by `z2r.sh` for fake payload installation.
- `extra_strats/`: numbered strategy slots and special lists used by config and menu logic.
- `extra_strats/TCP/RKN/Discord.txt`: dedicated Discord-related list used by config and blob toggles.
- `blockcheck2.d/z4r/`: custom `blockcheck2` HTTPS test lists and installer snippet.
- `orchestra/locked.lua`: Lua lock adapter used by the config and manual lock state.
- `lua/strategy-lock-manager.lua`: centralized lock/block state and hostname normalization.
- `lua/combined-detector.lua`: combined quality/failure logic that uses orchestration state.
- `lua/domain-grouping.lua`: grouping logic for related domains.
- `lua/silent-drop-detector.lua`: silent-drop detection.
- `lua/rst-guard.lua`: runtime RST injection guard loaded from `config.default`.
- `webui/`: static assets, CGI endpoints, and runner for the local WebUI on port `17682`.
- `Entware/`: Entware/Keenetic startup and integration patches.

## Architecture Notes

The project now has three interacting layers:

- Shell/menu layer: deploys files, edits config, starts/stops services, and writes manual strategy locks.
- WebUI layer: uses the same shell helpers as the menu to read status, restart services, run checks, and write locks.
- Lua lock layer: applies automatic and manual strategy locks at runtime.

Important practical consequence:

- many changes that look "config-only" also affect shell menu actions
- many changes that look "shell-only" are actually constrained by Lua profile numbering and `strategy=N` semantics
- WebUI endpoints and menu code share `lib/config.sh` and `lib/orchestra_state.sh`; keep behavior centralized there when possible

## High-Risk Areas

- `config.default` is structurally coupled to shell code. Menu actions and strategy helpers depend on exact markers, profile ordering, and recognizable patterns such as `--lua-desync=...strategy=N`.
- `config.default` loads `/opt/zapret2/lua/locked.lua` and `/opt/zapret2/lua/rst-guard.lua`; deployed Lua filenames and config `--lua-init` lines must stay in sync.
- `lib/actions.sh` uses targeted `sed`/`awk` replacements against `/opt/zapret2/config`. Small wording changes in config blocks can silently break toggles.
- `lib/strategies.sh` derives max strategy counts from config content. If profile structure changes, strategy menus can go out of sync.
- `lib/config.sh` is shared by the menu and WebUI. Changes to mode detection or profile counting can affect both surfaces.
- `lib/orchestra_state.sh` reads and writes `locked.tsv`; `z2r.sh` also temporarily switches `ORCH_LOCK_FILE` to `locked.manual.tsv`.
- `z2r.sh` performs destructive operations on target machines, including removing or rebuilding `/opt/zapret2`.
- Strategy lock files under `/opt/zapret2/extra_strats/cache/orchestra` are read by Lua at runtime. Moving paths can break manual strategy locking.
- `lua/strategy-lock-manager.lua` is a shared source of truth for hostname normalization and lock/block state. Duplicating normalization elsewhere is likely to cause subtle bugs.
- `webui/cgi-bin/_lib.sh` has its own CGI parsing and JSON output, but intentionally reuses runtime libs. Keep it Bash-compatible and BusyBox/uhttpd-friendly for embedded systems.

## Editing Guidelines

- Preserve Bash compatibility and existing shell style. Do not introduce unnecessary dependencies.
- Prefer existing shell helpers in `lib/config.sh` and `lib/orchestra_state.sh` over duplicating parsing, mode detection, or lock-file writes.
- Prefer small, local changes in `lib/*.sh` or `lua/*.lua` rather than expanding `z2r.sh` unless the change is truly top-level.
- Treat `config.default` as an API surface for both shell and Lua code.
- Do not casually rename files or move assets. Many paths are hardcoded in shell, config, and Lua.
- Keep Russian comments and user-facing text consistent with surrounding code.
- Keep WebUI changes dependency-light: static files, shell CGI, BusyBox/uhttpd-friendly behavior.
- When changing strategy counts or profile composition, verify all related menu/status code.
- When changing orchestration or lock behavior, inspect both shell and Lua sides before editing.

## What To Check First For Typical Tasks

For install/bootstrap issues:

- `z2r.sh`
- `Entware/`
- `config.default`

For menu or toggle bugs:

- `lib/submenus.sh`
- `lib/actions.sh`
- `lib/ui.sh`
- `lib/config.sh`

For strategy selection or status issues:

- `lib/strategies.sh`
- `lib/orchestra_state.sh`
- `config.default`
- `orchestra/locked.lua`

For runtime adaptive behavior or locking bugs:

- `lua/strategy-lock-manager.lua`
- `lua/combined-detector.lua`
- `lua/domain-grouping.lua`
- `orchestra/locked.lua`

For blob or fake-payload issues:

- `config.default`
- `lib/actions.sh`
- `fake/`

For WebUI issues:

- `z2r.sh`
- `webui/run-webui.sh`
- `webui/cgi-bin/_lib.sh`
- `webui/app.js`
- `lib/config.sh`
- `lib/orchestra_state.sh`

For blockcheck2 issues:

- `z2r.sh`
- `blockcheck2.d/z4r/`

## Validation

Minimum validation after edits:

- read the affected shell or Lua file for quoting, path, and pattern regressions
- if `config.default` changed, re-check every `sed`, `awk`, `grep`, or profile-number assumption that touches the edited block
- if strategy counts changed, verify the matching limits in menu/status helpers
- if orchestration logic changed, verify path consistency across `z2r.sh`, `lib/orchestra_state.sh`, `webui/`, `orchestra/`, `lua/`, and `config.default`
- if shared config helpers changed, check both menu output and WebUI CGI users
- if file names or asset paths changed, search the entire repo for stale references

## Smoke tests

```bash
bash tests/profile_lock_smoke.sh
```

Тест работает только во временной директории в `/tmp`:

- не пишет в `/opt`;
- не запускает настоящий `zapret2`;
- проверяет `bash -n` для основных shell-файлов;
- проверяет persistent state: `auto` как отсутствие записи, `0`, `N`, `clear`;
- проверяет, что `locked.lua` содержит ветку `0 -> VERDICT_PASS`;
- проверяет повторное применение состояния к свежему `config`;
- проверяет `RKN`, `Discord TCP`, `VOICE UDP`, fallback TLS;
- проверяет, что `VOICE_UDP=0` убирает voice-порты из `NFQWS2_PORTS_UDP`;
- проверяет идемпотентность `profile_apply_all`.

Успешный результат:

```text
profile_lock smoke ok
```

## Local Inspection Notes

- The repository content is largely Russian UTF-8 text. On Windows PowerShell it may display as mojibake if the console encoding is not UTF-8.
- This workspace is the source repository, not the deployed `/opt/zapret2` tree. Edit source files here unless you are intentionally debugging a live deployment copy.
