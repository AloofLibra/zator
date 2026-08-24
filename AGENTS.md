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

The project now uses **two runtime roots** (defined in `z2r.sh` as env-overridable
`ZAPRET2_ROOT="${ZAPRET2_ROOT:-/opt/zapret2}"` and `ZATOR_ROOT="${ZATOR_ROOT:-/opt/zator}"`):

- `$ZAPRET2_ROOT` (`/opt/zapret2`) — **zapret2-native**, recreated on every zapret2
  update. Holds upstream binaries (`nfq2/`, `tpws2/`), `install_easy.sh`,
  `install_bin.sh`, `install_prereq.sh`, `uninstall_easy.sh`, `common/`, `init.d/`,
  `blockcheck2.sh`, `blockcheck2.d/z4r/`, the deployed `keenetic-policy.sh` hook, and
  crucially **`config` and `config.default`**.
- `$ZATOR_ROOT` (`/opt/zator`) — **zator-owned content**, NOT touched by zapret2
  updates. Holds `z2r_lib/`, `lua/`, `webui/`, `extra_strats/` (incl.
  `cache/orchestra/`, `cache/webui`, `cache/provider.txt`, `cache/recommendations.txt`),
  `lists/`, `files/fake/`.

Splitting the roots means a zapret2 update (`rm -rf $ZAPRET2_ROOT` in `zapret_get`/
`remove_zapret`) no longer destroys zator content (strategy locks, cache, webui, lua).

`z2r.sh` runs `z2r_migrate_to_zator()` at startup (before sourcing libs): it moves any
zator-owned subtree still lingering under `/opt/zapret2` into `/opt/zator` and rewrites
the corresponding paths in the live `config`/`config.default`. This keeps existing user
installs and the external launcher (which still first-deploys libs to
`/opt/zapret2/z2r_lib`) compatible. `LIB_DIR` resolves to `$ZATOR_ROOT/z2r_lib` with a
fallback to `$ZAPRET2_ROOT/z2r_lib`.

Most runtime logic assumes these absolute paths:

- `$ZAPRET2_ROOT/config`, `$ZAPRET2_ROOT/config.default`
- `$ZAPRET2_ROOT/init.d/...`, `$ZAPRET2_ROOT/blockcheck2.sh`, `$ZAPRET2_ROOT/blockcheck2.d/z4r/...`
- `$ZATOR_ROOT/extra_strats/...` and `$ZATOR_ROOT/extra_strats/cache/orchestra/...`
- `$ZATOR_ROOT/lists/...`
- `$ZATOR_ROOT/files/fake/...`
- `$ZATOR_ROOT/lua/...`
- `$ZATOR_ROOT/webui/...`
- `$ZATOR_ROOT/z2r_lib/...`

> `config.default` is read by `nfqws2` literally (no shell expansion), so its
> `--lua-init`/`--blob`/`--hostlist` paths are absolute `/opt/zator/...` literals.

Normal flow:

1. `z2r.sh` detects OS and hardware.
2. It migrates any legacy zator content from `/opt/zapret2` into `/opt/zator`.
3. It installs or refreshes upstream `zapret2` (only under `$ZAPRET2_ROOT`).
4. It deploys this repository's zator assets into `/opt/zator` and the config +
   `keenetic-policy.sh` into `/opt/zapret2`.
5. It installs the custom config, extra strategy files, lists, fake payloads, Lua scripts, blockcheck inputs, WebUI files, and orchestra state files.
6. It manages `zapret2`, WebUI, blockcheck summaries, and manual strategy locks through an interactive menu.

## Layout

- `z2r.sh`: top-level orchestration script. Sources runtime modules from `zapret2/z2r_lib` after deployment, while this repository stores their source versions in `lib/`.
- `config.default`: main shipped `zapret2` config. This is now a large profile-driven config with `--lua-init`, `--lua-desync`, profile blocks, fallback blocks, blob declarations, and strategy numbering that other scripts depend on.
- `lib/ui.sh`: generic menu and terminal UI helpers.
- `lib/provider.sh`: ASN-based ISP/provider detection (ipwho.is → ipinfo.io → ip-api), city, cache, and manual override. The ASN→brand table is layered: builtin minimal table in `PROVIDER_ASN_BUILTIN` merged with the updatable `data/providers/asn.txt` (remote-priority, see `provider_load_database`/`provider_update_database`, cache in `extra_strats/cache/provider_asn.txt`, TTL 7 days, GitHub is never a runtime dependency).
- `data/providers/asn.txt`: maintainable ASN:BRAND:ALIASES database deployed to `/opt/zator/data/providers/asn.txt`; remote updates from the same path on the `zator` branch.
- `lib/telemetry.sh`: telemetry enable/disable and stats sending.
- `lib/recommendations.sh`: hint database and provider-based recommendations.
- `lib/netcheck.sh`: connectivity tests, DNS-spoof analysis, YouTube cluster probing, and the shared TLS-check engine `z2r_tls_*` (parallel single-attempt TLS 1.2/TLS 1.3 HEAD probes with `-L -k` + a Range download of up to 64KB when HEAD returns 2xx/3xx; classification by curl rc and HTTP code; any HTTP code including 4xx/5xx means the server answered → green ok, e.g. googlevideo root 404 is normal). The engine is the single source of truth for CLI `check_access` and WebUI `check_one_target_json` — verdict texts live here and are shared by both surfaces.
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
- WebUI layer: uses the same shell helpers as the menu to read status, restart services, run checks, and write locks. Now includes fallback (безразборный режим) management for TLS (profile 8) and HTTP (profile 9) strategies.
- Lua lock layer: applies automatic and manual strategy locks at runtime.

Important practical consequence:

- many changes that look "config-only" also affect shell menu actions
- many changes that look "shell-only" are actually constrained by Lua profile numbering and `strategy=N` semantics
- WebUI endpoints and menu code share `lib/config.sh` and `lib/orchestra_state.sh`; keep behavior centralized there when possible
- WebUI fallback functions (`_fallback_*` in `webui/cgi-bin/_lib.sh`) are local copies of CLI logic from `lib/actions.sh` (`backup_smart_set_fallback`) and must stay in sync

## High-Risk Areas

- `config.default` is structurally coupled to shell code. Menu actions and strategy helpers depend on exact markers, profile ordering, and recognizable patterns such as `--lua-desync=...strategy=N`.
- `config.default` loads `/opt/zator/lua/locked.lua` and `/opt/zator/lua/rst-guard.lua`; deployed Lua filenames and config `--lua-init` lines must stay in sync.
- `lib/actions.sh` uses targeted `sed`/`awk` replacements against `/opt/zapret2/config`. Small wording changes in config blocks can silently break toggles.
- `lib/strategies.sh` derives max strategy counts from config content. If profile structure changes, strategy menus can go out of sync.
- `lib/config.sh` is shared by the menu and WebUI. Changes to mode detection or profile counting can affect both surfaces.
- `lib/orchestra_state.sh` reads and writes `locked.tsv`; `z2r.sh` also temporarily switches `ORCH_LOCK_FILE` to `locked.manual.tsv`.
- `z2r.sh` performs destructive operations on target machines, including removing or rebuilding `/opt/zapret2`.
- All zapret2 init-script invocations must go through `z2r_service_action` (`lib/config.sh`): it detaches the init script from the terminal's process group (setsid, INT/QUIT/HUP-ignored fallback) so Ctrl+C/SIGHUP in an interactive session cannot kill a restart midway or the daemon itself. `Entware/zapret` overrides upstream `run_daemon` (setsid spawn, upstream pidfile format `${DAEMONBASE}_N.pid`; daemon stderr goes to `/tmp/${DAEMONBASE}_N.err`, truncated on each start — upstream left stderr on the terminal, which both hung `restart | tail` and lost config errors once detached; stdout stays at /dev/null as upstream) and upstream `contains` (busybox `${1#*$2}` is quadratic on the 37KB config string — ~95s per restart on mipsel; the `case`-based override is linear) — keep both overrides after `. "$EXEDIR/functions"` and in sync with upstream when it changes.
- `orch_auto_sweep` remembers whether nfqws2 was running before the sweep and restarts it (with a red warning) if Ctrl+C killed it mid-sweep; interruption during the inter-strategy pause must still print «Прервано пользователем…» (covered by `tests/tls_check_smoke.sh` scenarios 14c–14e).
- Reinstall/update flow invariants (z2r.sh body, menu 2/44): before `remove_zapret` a backup is offered via `backup_helper_ask_and_create` (only when `$ZAPRET2_ROOT/config` exists) and `WEBUI_WAS_RUNNING` is captured from `webui_status_text`. `remove_zapret` must NEVER delete WebUI files (`$ZATOR_ROOT/webui`) — it only calls `webui_stop_service` while zapret2 is being wiped; the service is restored after the WebUI prompt and in menu 44. Full WebUI removal belongs exclusively to `zator_remove` (menu 4). The WebUI install prompt is presence-aware («уже установлена. Обновить?» vs «Установить?»), and `get_menu` is opened right after `install_zapret_reboot`.
- Keenetic netfilter hook must be installed under its own name `/opt/etc/ndm/netfilter.d/000-zapret2.sh` (source `Entware/000-zapret2.sh`); the legacy name `000-zapret.sh` belongs to the old zapret project and must only be removed when its content references zapret2 (migration guard greps for `zapret2`) — both in `entware_fixes` and in `remove_zapret`.
- Strategy lock files under `/opt/zator/extra_strats/cache/orchestra` are read by Lua at runtime. Moving paths can break manual strategy locking.
- `lua/strategy-lock-manager.lua` is a shared source of truth for hostname normalization and lock/block state. Duplicating normalization elsewhere is likely to cause subtle bugs.
- `webui/cgi-bin/_lib.sh` has its own CGI parsing and JSON output, but intentionally reuses runtime libs (it sources `lib/config.sh`, `lib/orchestra_state.sh`, `lib/strategies.sh`, and `lib/netcheck.sh` for the shared TLS-check engine, plus `lib/actions.sh` and `lib/provider.sh` for shared setters). Keep it Bash-compatible and BusyBox/uhttpd-friendly for embedded systems.
- `webui/cgi-bin/_lib.sh` reuses shared setters from `lib/actions.sh` (`backup_smart_set_*`, `ports_apply_add`/`ports_apply_remove`, `backup_create_core`) and `lib/provider.sh` (`provider_set_manual`) instead of duplicating sed logic. The local `_fallback_set_state` is only a legacy fallback used when `lib/actions.sh` is unavailable; `api_fallback_state_set` normally calls `backup_smart_set_fallback` with the same auto-rotation guard as CLI `toggle_fallback_mode`. Changes to those lib functions affect both CLI and WebUI.
- WebUI settings (auto-rotation, hostlist, RST guard, reasm, QUIC443, NFQWS2 ports, provider, backups) are exposed via `settings.cgi`/`backups.cgi` and mirrored in `webui/dev/fake_router_server.py` and `webui/dev/API_CONTRACT.md` — keep all three in sync when changing behavior. Update/install actions stay CLI-only by design.

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

For fallback (безразборный режим) issues:

- `webui/cgi-bin/_lib.sh` (functions `_fallback_*`)
- `webui/app.js` (functions `renderFallbackSettings`, `refreshFallbackSettings`, `applyFallbackState`)
- `webui/index.html` (fallback panel UI)
- `lib/actions.sh` (`backup_smart_set_fallback`, `toggle_fallback_mode`)
- `config.default` (fallback blocks `#Z2R_FALLBACK_*`)

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
- проверяет идемпотентность `profile_apply_all`;
- проверяет чтение даты изменения config (`# Last modified`) для главного меню (`config_last_modified`, `MENU_CONFIG_DATE`).

Успешный результат:

```text
profile_lock smoke ok
```

```bash
bash tests/webui_smoke.sh
```

Тест Web-панели (Web UI) в `z2r.sh`, тоже только во временной директории в `/tmp`:

- не пишет в `/opt`, не запускает настоящий web-сервер;
- извлекает `webui_*` функции из `z2r.sh` (объявлены от колонки 0) и гоняет их с моками
  (`clear`, раннер `run-webui.sh`, перехватывающий `rm`);
- имитирует точки поломок (падение запуска/остановки/удаления, отсутствующий раннер)
  и проверяет, что сбои локализованы: `set -e` не роняет вызывающий код,
  пользователь видит сообщение об ошибке;
- проверяет терминологию («Web-панель управления», отсутствие web-ssh/ttyd/web-терминал)
  и то, что промпт удаления Web-панели стоит под guard'ом `[ -d "$WEBUI_ROOT" ]`;
- проверяет, что пункт «Перезапустить Web UI» в подменю показывается только при running.

Успешный результат:

```text
webui smoke ok
```

```bash
bash tests/uninstall_smoke.sh
```

Тест удаления (пункты меню 4 = zator + zapret2 и 44 = только zapret2, функция
`zator_remove` в `z2r.sh`), тоже только во временной директории в `/tmp`:

- не пишет в `/opt` (`ZATOR_ROOT` переопределяется на временную папку);
- проверяет инварианты меню: 4 вызывает `remove_zapret` + `zator_remove`,
  44 — только `remove_zapret`, вызовы обёрнуты в `|| echo`;
- проверяет `zator_remove`: штатное удаление (каталог снесён, сервисы
  validator/Web-панель остановлены), отсутствие каталога, сбой `rm` (мок)
  с локализацией под `set -e`.

Успешный результат:

```text
uninstall smoke ok
```

```bash
bash tests/webui_settings_smoke.sh
```

Тест новых настроек WebUI (тумблеры, порты, бэкапы, провайдер), тоже только во
временной директории в `/tmp`:

- не пишет в `/opt`; mock-config собирается из `config.default` с нормализацией
  CRLF (работает и на LF-, и на CRLF-checkout);
- проверяет синтаксис `lib/actions.sh`, `lib/provider.sh`, `_lib.sh`,
  `settings.cgi`, `backups.cgi`, `app.js`, `fake_router_server.py`;
- проверяет статический wiring: `_lib.sh` source-ит actions/provider, dispatcher
  знает все новые ключи, `app.js`/`index.html` содержат все новые панели и вызовы;
- проверяет логику ядер на mock-config: hostlist (+`<HOSTLIST>`), reasm,
  QUIC443, RST guard, fallback c guard'ом авторотации и восстановлением
  `#Z2R_AUTO_FALLBACK_WAS`, `config_set_auto_mode`, `ports_apply_add/remove`
  (включая синхронизацию `--filter-tcp` RKN-блока и дубликаты), `backup_create_core`,
  `provider_set_manual`.

Успешный результат:

```text
webui settings smoke ok
```

```bash
bash tests/provider_asn_smoke.sh
```

Тест внешней ASN-базы провайдеров (второй слой детекта), только во временной
директории в `/tmp`, с моком `curl` в PATH:

- 10 сценариев: remote доступен → cache обновился; remote недоступен → старый
  cache цел; нет cache → builtin; битый remote → cache не затирается; живой TTL
  → сетевого запроса нет; merge (remote приоритет, builtin не теряется);
  remote-ASN + алиас → рекомендация находится; неизвестный ASN → fallback;
  manual-провайдер не перезаписывается; fake-router redetect не менял формат;
- плюс: `provider_init_once` при готовом provider.txt не делает сетевых запросов.

Успешный результат:

```text
provider asn smoke ok
```

```bash
bash tests/tls_check_smoke.sh
```

Тест TLS-проверок (пункт меню 01, перебор стратегий, WebUI), только во временной
директории в `/tmp`, с моком `curl` в PATH:

- не пишет в `/opt`;
- движок `z2r_tls_*` из `lib/netcheck.sh`: HEAD-проба (`-L -k`, одна попытка,
  следует за редиректами) с парсингом последней статусной строки из дампа
  заголовков, классификация кодов возврата curl (DNS / таймаут / TLS / соединение,
  rc=77 → TLS, нет CA-бандла в CGI);
- этап докачки (Range до 64КБ, фактические байты) после успешного HEAD
  с одним повтором при сбое (DPI режет выборочно: повтор прошёл — warn
  «иногда срезается», оба среза — fail):
  ok / zero / cut / fail (маленькая страница, целиком дошедшая за 206, — ok;
  обрыв фиксируется только по ошибке curl после начавшихся байтов),
  405 на HEAD считается работающим транспортом;
- вердикты: `ok` — сервер ответил: 2xx/3xx и данные идут, либо любой HTTP-код
  включая 4xx/5xx (сервер ответил, TLS пробит — googlevideo на корневом пути
  отдаёт 404, это норма; зелёный, даже если TLS 1.2 не отвечает, пока работает
  TLS 1.3); `warn` — только TLS 1.2 (жёлтый); `fail` — обе версии не ответили
  транспортом либо данные не приходят (красный).
  Строки версий: факт жёлтым/зелёным + подсказка «Проверьте доступность вручную.
  Возможно ошибка теста.» красным (как в эталонном выводе старого меню);
- CLI `check_access` (тексты итога, отсутствие старого «Таймаут 2сек») и WebUI
  `check_one_target_json` (форма JSON: verdict / tls*_detail / download;
  JSON обязан быть валидным — `code` без ведущих нулей);
- автопрогон стратегий `orch_auto_sweep` (профили 1-4 и кастомные домены,
  опция A в промптах перебора; диалог `orch_run_auto_sweep`: режим → требуемый
  TLS (any|12|13|both, Enter - обе) → добавка к паузе; 0 на любом вопросе =
  отмена): в строках прогона цветные статусы обеих версий TLS
  (`z2r_tls_version_badge`; движок с `Z2R_TLS_WAIT_BOTH=1` ждёт обе пробы),
  зелёность — по выбранным версиям (жёлтые «работает только TLS X» несут
  статистику докачки), режимы «до первого успеха»/«полный»,
  пауза между стратегиями против блока ТСПУ (база `${Z2R_SWEEP_PAUSE:-3}` сек
  + добавка), сводка с «полными» (TLS 1.2 и 1.3), самой быстрой полной,
  лучшей из жёлтых по скорости (если зелёных нет) и подсказкой перезапуска
  с другой целью, когда нужная версия TLS не прошла ни одной стратегией,
  Enter=лучшая / номер / 0=возврат прежних локов, Ctrl+C с восстановлением;
  safety net: если nfqws2 был жив до прогона и умер (Ctrl+C убил процесс) —
  предупреждение + рестарт через `z2r_service_action` до сводки; прерывание
  в паузе между стратегиями тоже печатает «Прервано пользователем…» (14d),
  статика: рестарты только через `z2r_service_action`, оверрайд `run_daemon`
  в `Entware/zapret` после source functions, pid-формат как в апстриме (14e);
- валидатор `lua/strategy-validator.sh`: одиночный таймаут (rc=28) → ERROR
  (повтор разрешён), подряд идущие таймауты → FAIL (ротация), успех сбрасывает
  счётчик (живёт 10 минут);
- статический wiring: `_lib.sh` source-ит `netcheck.sh` и не содержит локальной
  curl-логики TLS, `app.js`/`styles.css`/`fake_router_server.py` синхронны.

Успешный результат:

```text
tls check smoke ok
```

## Local Inspection Notes

- The repository content is largely Russian UTF-8 text. On Windows PowerShell it may display as mojibake if the console encoding is not UTF-8.
- This workspace is the source repository, not the deployed `/opt/zapret2` tree. Edit source files here unless you are intentionally debugging a live deployment copy.
