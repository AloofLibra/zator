# API-контракт WebUI (CGI)

Документ снят напрямую с кода `webui/cgi-bin/_lib.sh` и `*.cgi`.
Это «источник правды» для фейк-сервера `fake_router_server.py`: он обязан
воспроизводить ровно эти поля, коды ошибок и edge-case'ы.

Все эндпоинты живут под `/cgi-bin/`. CGI-скрипты — тонкие обёртки, вся логика
в функциях `api_*` из [`_lib.sh`](../cgi-bin/_lib.sh:1). Тело ответа — всегда
JSON, `Content-Type: application/json; charset=utf-8`.

Параметры разбираются функцией `parse_params()` ([`_lib.sh`](../cgi-bin/_lib.sh:68)):
для `GET` — из `QUERY_STRING`, для `POST` — из тела (`Content-Length`,
`application/x-www-form-urlencoded`). Распознаются ключи `profile`,
`strategy`, `action`, `setting`, `value`, `list`, `domain`, `name`, `city`,
`proto`. Значения URL-декодируются (`%xx` → символ, `+` → пробел).

---

## Жёстко зашитые пути и переменные окружения

| Где | Значение | Источник |
| --- | --- | --- |
| `WEBUI_ROOT` | `/opt/zapret2/webui` | [`_lib.sh:8`](../cgi-bin/_lib.sh:8) |
| `ZAPRET_ROOT` | `/opt/zapret2` | [`_lib.sh:9`](../cgi-bin/_lib.sh:9) |
| `CONFIG_FILE` | `/opt/zapret2/config` | [`_lib.sh:10`](../cgi-bin/_lib.sh:10) |
| `ORCH_DIR` | `/opt/zapret2/extra_strats/cache/orchestra` | [`_lib.sh:11`](../cgi-bin/_lib.sh:11) |
| `ORCH_LOCK_FILE` | `$ORCH_DIR/locked.tsv` (default) | [`orchestra_state.sh:4`](../../lib/orchestra_state.sh:4) |
| `locked.manual.tsv` | `$ORCH_DIR/locked.manual.tsv` | используется профилями 8/9 в `config.sh` |
| `PROFILE_STATE_FILE` | `/opt/etc/z2r/profile.lock` (default) | [`orchestra_state.sh:5`](../../lib/orchestra_state.sh:5) (env `Z2R_PROFILE_STATE_FILE`) |
| Порт WebUI | `17682` (env `WEBUI_PORT`) | [`run-webui.sh:13`](../run-webui.sh:13) |
| Поиск runtime-либ | `$ZAPRET_ROOT/z2r_lib`, `../../z2r_lib`, `../../lib`, `../lib` | [`_lib.sh:14`](../cgi-bin/_lib.sh:14) |

> Фейк-сервер **никогда** не лезет в эти пути: всё переопределяется во
> временную директорию (см. `fake_router_server.py`).

---

## Внешние команды и файлы, которые трогают эндпоинты

| Эндпоинт | Что реально вызывает |
| --- | --- |
| `status` | `pidof nfqws2` (через [`zapret2_running()`](../../lib/orchestra_state.sh:54)); чтение `CONFIG_FILE` (`config_mode_text`, `config_profile_max_strategy`); чтение `locked.tsv`, `locked.manual.tsv`, `profile.lock` (`strategy_locks_status_text`, `profile_state_display`) |
| `set-lock` | валидация по `config_profile_max_strategy`/`config_profile_proto_list`; запись `profile.lock` + `locked.tsv` (`profile_state_set_and_apply`); для профиля 6 — правка `NFQWS2_PORTS_UDP` в конфиге + `service_zapret2 restart`; `curl` к проверочным целям (`profile_check_json`); `send_stats` (telemetry, если есть) |
| `clear-lock` | запись `profile.lock` + `locked.tsv` в режим `auto`; для профиля 6 — правка портов + restart; telemetry |
| `service` | вызов init-скрипта `/opt/zapret2/init.d/{openwrt,sysv}/zapret2 {start,stop,restart}` |
| `check` | движок `z2r_tls_*` из `lib/netcheck.sh`: последовательная проверка 4 целей (внутри цели TLS 1.2/1.3 параллельно), HEAD-пробы `-L -k` + докачка до 64КБ при 2xx/3xx; `get_yt_cluster_domain` делает `curl` к `redirector.xn--ngstr-lra8j.com` (двойной запрос, fallback `rr1---sn-5goeenes.googlevideo.com`) |
| `domains` | списки/локи через `lib/strategies.sh`; для `custom_rkn` действия `add`/`set_strategy`/`check` дополнительно прогоняют домен через тот же движок `z2r_tls_*` и возвращают `"check"` |

---

## 1. `GET /cgi-bin/status.cgi` → `api_status`

Параметры: нет.

```jsonc
{
  "zapret2_running": true,                 // bool: pidof nfqws2
  "strategy_locks_status": "Есть",         // "Есть" | "Нет"
  "hostlist_mode": "по листам",            // config_mode_text hostlist
  "fwtype": "iptables",                    // config_get_var FWTYPE
  "flowoffload": "donttouch",              // config_get_var FLOWOFFLOAD
  "tls_blob_mode": "default",              // config_mode_text tls_blob_menu
  "wireguard": "выключено",                // "включено" | "выключено" | "недоступно" (_wg_state_get)
  "auto_mode": "выключен",                 // config_mode_text auto_mode
  "rst_guard": "выключен",                 // config_mode_text rst_guard
  "reasm": "выключено",                    // config_mode_text reasm_disable
  "quic443": "выключены",                  // _quic443_state_text (backup_smart_quic443_state)
  "provider": "MTS - Moscow",              // _provider_cache_text (cache/provider.txt)
  "profiles": [
    {"profile":1,"label":"YouTube TCP","description":"Основной TCP профиль для YouTube","current_lock":"auto","max_strategy":30},
    {"profile":2,"label":"Googlevideo","description":"Видео-домены YouTube","current_lock":"auto","max_strategy":30},
    {"profile":3,"label":"RKN Лист","description":"Основные блокировки сайтов","current_lock":"auto","max_strategy":30},
    {"profile":4,"label":"Discord TCP","description":"TCP профиль Discord","current_lock":"auto","max_strategy":28},
    {"profile":5,"label":"YouTube QUIC","description":"UDP 443 для YouTube","current_lock":"auto","max_strategy":13},
    {"profile":6,"label":"Voice UDP","description":"Discord/STUN и голосовые сервисы","current_lock":"auto","max_strategy":32},
    {"profile":7,"label":"UDP Games","description":"Игровой UDP (порты 1026-65531)","current_lock":"auto","max_strategy":11,"is_udp_games":true,"udp_games_enabled":false},
    {"profile":8,"label":"Fallback TLS","description":"Безразборный режим TLS (profile 8)","current_lock":"auto","max_strategy":30,"is_fallback":true,"fallback_enabled":false},
    {"profile":9,"label":"Fallback HTTP","description":"Безразборный режим HTTP (profile 9)","current_lock":"auto","max_strategy":8,"is_fallback":true,"fallback_enabled":false}
  ]
}
```

Поле `current_lock` — результат `profile_state_display(profile, proto)`:
сначала читается `profile.lock` (`profile_state_stored_get`), при `auto` —
`locked.tsv` (`orch_locked_state_get`, default `auto`). Значения: `"auto"`,
`"0"` (выключен), либо номер стратегии строкой.

Для fallback-профилей **8/9** дополнительно есть `"is_fallback":true` и
`"fallback_enabled":bool` (см. [§7](#7-fallback-безразборный-режим)). Их
`current_lock` читается из того же `profile.lock`, но orchestra-lock пишется в
`locked.manual.tsv` (см. [`profile_config_orch_set`](../../lib/config.sh:461)),
который читает runtime `circular_locked:key=8/9`.

`strategy_locks_status` = `"Есть"`, если непустой хотя бы один из
`locked.tsv`, `locked.manual.tsv`, `profile.lock`; иначе `"Нет"`
([`_lib.sh:139`](../cgi-bin/_lib.sh:139)).

`max_strategy` для `config.default`: **1→30, 2→30, 3→30, 4→28, 5→13, 6→32,
8→30, 9→8** (см. `config_profile_max_strategy`; профиль 7=11 в WebUI не виден).
Профили 8/9 — это fallback-блоки `#Z2R_FALLBACK_*` (TLS/HTTP).

Ошибок через `send_error` нет (при отсутствии runtime-либ — `500` + `{"error":"missing z2r runtime libs"}`).

---

## 2. `POST /cgi-bin/set-lock.cgi` → `api_set_lock`

Параметры: `profile` (обяз.), `strategy` (обяз.).

Валидация (порядок важен, [`_lib.sh:214`](../cgi-bin/_lib.sh:214)):

| Условие | Код | Сообщение |
| --- | --- | --- |
| `profile` не `^[1-9]$` | `400 Bad Request` | `Некорректный профиль` |
| `strategy` не `^[0-9]+$` | `400 Bad Request` | `Некорректная стратегия` |
| авторотация включена, `profile` 1–4 | `409 Conflict` | `Профиль <N> управляется авторотацией TCP/HTTP. Сначала выключите авторотацию.` |
| `strategy != 0` и вне `[1..max]` | `400 Bad Request` | `Стратегия вне диапазона` |
| пустой `proto_list` | `400 Bad Request` | `Не удалось определить протокол профиля` |
| `profile_state_set_and_apply` упала | `500 Internal Server Error` | `Не удалось сохранить состояние профиля` |

Успех (`200 OK`):

```jsonc
{
  "ok": true
}
```

`set-lock` отвечает **быстро** (только запись состояния, без проверки):
долгий CGI упирается в таймаут httpd («Bad Gateway») и оставляет процессы.
Инлайн-проверка после применения делается отдельным запросом
[`check.cgi?profile=N`](#5-post-cgi-bincheckcgi--api_check) с фронтенда.

Формат `check` (для справки, теперь возвращает `check.cgi?profile=N`):

```jsonc
{
  "results": [
      {"label":"YouTube","target":"https://www.youtube.com/","tls12":1,"tls13":1,
       "verdict":"ok","text":"Сайт доступен: TLS работает, данные идут.",
     "tls12_detail":{"code":200,"proto":"HTTP/2","time":"0.8","ip":"203.0.113.1","state":"ok","text":"Есть ответ по TLS 1.2 (важно для ТВ и т.п.): HTTP/2 200 за 0.8 с"},
     "tls13_detail":{"code":200,"proto":"HTTP/2","time":"0.7","ip":"203.0.113.1","state":"ok","text":"Есть ответ по TLS 1.3 (важно в основном для всего современного): HTTP/2 200 за 0.7 с"},
     "download":{"code":206,"size":65536,"time":"1.2","state":"ok","text":"Данные: получено 65536 байт за 1.2 с (код 206)"}}
    ]
  }
}
```

Структура `check.results` зависит от профиля
([`_lib.sh:180`](../cgi-bin/_lib.sh:180)):

| profile | label / target |
| --- | --- |
| 1 | `YouTube` / `https://www.youtube.com/` |
| 2 | `Googlevideo` / `https://<yt-cluster-domain>` |
| 3 | `Blocked Sites` / `https://meduza.io` |
| 4 | `Discord` / `https://discord.com/` |
| 5, 6 | `results: []` + `message`: «Для UDP-профиля быстрая TLS-проверка неприменима. Проверьте работу в браузере или приложении.» |
| прочее | `results: []` |

Каждый элемент результата — общий формат проверки цели (см. [§5](#5-post-cgi-bincheckcgi--api_check)).
`tls12`/`tls13` —legacy-булевы (транспорт ответил любым HTTP-кодом), `verdict` —
`ok|warn|fail`, `download: null` — этап данных пропущен (не было 2xx/3xx на HEAD).

> Для профиля 6 дополнительно выполняется `service_zapret2 restart` (результат
> игнорируется) и правка голосовых портов в конфиге.

---

## 3. `POST /cgi-bin/clear-lock.cgi` → `api_clear_lock`

Параметры: `profile` (обяз.).

| Условие | Код | Сообщение |
| --- | --- | --- |
| `profile` не `^[1-9]$` | `400 Bad Request` | `Некорректный профиль` |
| авторотация включена, `profile` 1–4 | `409 Conflict` | `Профиль <N> управляется авторотацией TCP/HTTP. Сначала выключите авторотацию.` |
| пустой `proto_list` | `400 Bad Request` | `Не удалось определить протокол профиля` |
| apply упала | `500 Internal Server Error` | `Не удалось сбросить состояние профиля` |

Успех (`200 OK`):

```json
{ "ok": true }
```

Сбрасывает профиль в `auto` (удаляет запись из `profile.lock` и `locked.tsv`).
Для профиля 6 — restart + правка портов.

---

## 4. `POST /cgi-bin/service.cgi` → `api_service`

Параметры: `action` (обяз.).

| Условие | Код | Сообщение |
| --- | --- | --- |
| `action` не `start\|stop\|restart` | `400 Bad Request` | `Некорректное действие` |
| `service_zapret2` упала (нет init-скрипта / ненулевой код) | `500 Internal Server Error` | `Не удалось выполнить команду zapret2` |

Успех (`200 OK`):

```json
{ "ok": true }
```

`service_zapret2` ([`_lib.sh:125`](../cgi-bin/_lib.sh:125)) выбирает
`init.d/openwrt/zapret2`, иначе `init.d/sysv/zapret2`; если файла нет —
возвращает ненулевой код → `500`.

---

## 5. `POST /cgi-bin/check.cgi` → `api_check`

Параметры: необязательный `profile` (`1..9`) — проверка одной цели профиля
(`profile_check_json`, используется фронтендом после `set-lock.cgi`);
без параметра — полная проверка 4 целей. (Метод для этого эндпоинта не важен.)

Проверка выполняется движком `z2r_tls_*` из `lib/netcheck.sh` (единый модуль
с CLI-меню; `_lib.sh` его source-ит): для каждой цели параллельно пробуются
TLS 1.2 (`--tlsv1.2 --tls-max 1.2`) и TLS 1.3 (`--tlsv1.3`) — HEAD-запрос
(`curl -4 -s -L -k -I`: следует за редиректами, без проверки сертификата —
в CGI-окружении uhttpd нет CA-бандла и curl падает с rc=77), без тела,
`--connect-timeout 3 --max-time 5`, одна попытка; если хоть одна версия дала
2xx/3xx — докачка `Range: bytes=0-65535` (запрос до 64КБ, `--max-time 10`,
`--speed-limit 2048 --speed-time 1` — срезанный поток прерывается через 1 сек
простоя вместо ожидания полного таймаута, тоже `-L -k`) для проверки, что
данные реально идут (покрывает 1КБ/32КБ блоки
анализа DPI; байты считаются фактические — сервер может игнорировать Range;
докачка выполняется двумя параллельными попытками — DPI режет поток
выборочно, и успех второй при провале первой различает «иногда срезает»
(warn) и «срезает всегда» (fail); зависшая HEAD-версия добивается на первом
тике опроса ~0.3с после успеха второй).
Коды 4xx/5xx — сервер ответил, TLS пробит: итог ok (googlevideo на корневом
пути отдаёт 404 — это норма). 4 цели проверяются **последовательно**, по одной
(внутри цели версии TLS 1.2/1.3 — два параллельных curl); `get_yt_cluster_domain`
запрашивает реальный кластер googlevideo с `-4 -k --max-time 4` (двойной запрос,
fallback `rr1---sn-5goeenes.googlevideo.com`).

Успех (`200 OK`):

```jsonc
{
  "results": [
    {"label":"YouTube","target":"https://www.youtube.com/","tls12":1,"tls13":1,
     "verdict":"ok","text":"Сайт доступен: TLS работает, данные идут.",
     "tls12_detail":{"code":200,"proto":"HTTP/2","time":"0.8","ip":"203.0.113.1","state":"ok","text":"Есть ответ по TLS 1.2 (важно для ТВ и т.п.): HTTP/2 200 за 0.8 с"},
     "tls13_detail":{"code":200,"proto":"HTTP/2","time":"0.7","ip":"203.0.113.1","state":"ok","text":"Есть ответ по TLS 1.3 (важно в основном для всего современного): HTTP/2 200 за 0.7 с"},
     "download":{"code":206,"size":65536,"time":"1.2","state":"ok","text":"Данные: получено 65536 байт за 1.2 с (код 206)"}},
    {"label":"Blocked Sites","target":"https://meduza.io","tls12":0,"tls13":1,
     "verdict":"ok","text":"Сайт доступен: TLS работает, данные идут.",
     "tls12_detail":{"code":0,"proto":"-","time":"-","ip":"-","state":"tls","text":"Нет ответа по TLS 1.2 (важно для ТВ и т.п.) Ошибка TLS-рукопожатия. Проверьте доступность вручную. Возможно ошибка теста."},
     "tls13_detail":{"code":200,"proto":"HTTP/2","time":"0.9","ip":"203.0.113.2","state":"ok","text":"Есть ответ по TLS 1.3 (важно в основном для всего современного): HTTP/2 200 за 0.9 с"},
     "download":{"code":206,"size":65536,"time":"1.4","state":"ok","text":"Данные: получено 65536 байт за 1.4 с (код 206)"}}
  ]
}
```

Поля элемента:

| поле | значение |
| --- | --- |
| `tls12`/`tls13` | legacy-булевы: транспорт ответил любым HTTP-кодом (включая 404/405) |
| `verdict` | `ok` — сервер ответил: 2xx/3xx с данными, либо любой HTTP-код (4xx/5xx — сервер ответил, TLS пробит; googlevideo на корневом пути отдаёт 404 — это норма); `warn` — сайт отвечает только по TLS 1.2, либо поток срезается не каждый раз (первая докачка оборвалась, повтор прошёл); `fail` — обе версии не ответили транспортом либо данные не приходят |
| `text` | сводный текст вердикта (тот же, что печатает CLI-меню) |
| `tls12_detail`/`tls13_detail` | `code` (число, `0` = ответа нет), `proto` (например `HTTP/2`), `time` (сек), `ip`, `state` (`ok/http/dns/timeout/tls/conn/unsupported/none`), `text` |
| `download` | `null`, если этап пропущен; иначе `code`, `size` (байт), `time`, `state` (`ok/zero/cut/fail`), `text` |

`get_yt_cluster_domain` делает `curl` к
`redirector.xn--ngstr-lra8j.com` (двойной запрос, fallback
`rr1---sn-5goeenes.googlevideo.com`) — теперь тоже из `lib/netcheck.sh`.

Ошибок через `send_error` нет.

---

## 6. `GET/POST /cgi-bin/settings.cgi` → `api_tls_blob_*` / `api_wg_blob_*`

Единый эндпоинт настроек. Выбор ветви — по параметру `setting`
(и в `QUERY_STRING` для GET, и в теле для POST; разбирается
[`parse_params()`](../cgi-bin/_lib.sh:58), которая теперь понимает ключи
`setting` и `value`).

### GET — чтение настроек

| `setting` | Функция | Возвращает |
| --- | --- | --- |
| _(отсутствует)_ или иное | `api_tls_blob_get` | TLS-блоб |
| `wg_blob` | `api_wg_blob_get` | WG-блоб + repeats |
| `wg_state` | `api_wg_state_get` | состояние WG (вкл/выкл) |
| `fallback` | `api_fallback_get` | состояние fallback ([§7](#7-fallback-безразборный-режим)) |
| `udp-games` | `api_udp_games_get` | состояние игрового UDP (профиль 7) |
| `auto_mode` | `api_auto_mode_get` | авторотация TCP/HTTP |
| `hostlist` | `api_hostlist_get` | режим фильтрации по спискам |
| `rst_guard` | `api_rst_guard_get` | защита от RST-инъекций |
| `reasm` | `api_reasm_get` | `--reasm-disable` |
| `quic443` | `api_quic443_get` | фейки QUIC на UDP 443 |
| `ports` | `api_ports_get` | пользовательские порты NFQWS2 |
| `provider` | `api_provider_get` | провайдер (cache/provider.txt) |

**TLS** (`GET /cgi-bin/settings.cgi`):

```jsonc
{
  "current_mode": "maxru",            // maxru | fake_default_tls | mixed | "не определён"
  "current_blob": "tls_clienthello_1.bin",
  "available_blobs": ["tls_clienthello_1.bin", "..."]
}
```

**WireGuard** (`GET /cgi-bin/settings.cgi?setting=wg_blob`):

```jsonc
{
  "current_blob": "wg_initial_fake_1.bin",
  "current_repeats": "10",            // строка; "" если стратегии WG нет в конфиге
  "available_blobs": ["wg_initial_fake_1.bin", "wg_initial_fake_2.bin", "..."]
}
```

`available_blobs` — только файлы `wg_initial_fake_*` из `/opt/zapret2/files/fake`
(как в [`menu_action_set_wg_blob`](../../lib/actions.sh:424)).

**WireGuard state** (`GET /cgi-bin/settings.cgi?setting=wg_state`):

```jsonc
{
  "state": "0",        // "1" = вкл, "0" = выкл, "" = блока #Z2R_WG_* нет в конфиге
  "enabled": false     // bool: state == "1"
}
```

Состояние определяется по наличию `--skip` перед `--filter-l7=wireguard` в блоке
`#Z2R_WG_BEGIN`/`#Z2R_WG_END` ([`_wg_state_get`](../cgi-bin/_lib.sh) ↔
[`backup_smart_wg_state`](../../lib/actions.sh:1287)).

**Режимы** (`GET ?setting=auto_mode|hostlist|rst_guard|reasm|quic443`):

```jsonc
// auto_mode
{ "state": "выключен", "enabled": false }   // state: "включен" | "выключен" | "неизвестно"
// hostlist
{ "state": "по листам", "auto": false }     // state: "авто" | "по листам" | "неизвестно"
// rst_guard
{ "state": "выключен", "enabled": false, "lua_available": true }  // lua_available: есть ли /opt/zator/lua/rst-guard.lua
// reasm
{ "state": "выключено", "enabled": false }  // state: "включено" | "выключено"
// quic443
{ "state": "выключены", "enabled": false }  // state: "включены" | "выключены"
```

**Порты** (`GET ?setting=ports`):

```jsonc
{
  "tcp": { "full": "8080,80,443", "user": ["8080"], "base": "80,443" },
  "udp": { "full": "443,51820",   "user": ["51820"], "base": "443" }
}
```

`user` — порты слева от якоря (TCP 80 / UDP 443), именно ими управляет WebUI.
`1026-65531` в UDP управляется тумблером игрового UDP и не удаляется через
`ports_remove`.

**Провайдер** (`GET ?setting=provider`):

```jsonc
{ "provider": "MTS - Moscow" }   // "Не определён" при пустом кэше
```

### POST — применение настроек

Тело: `setting=<...>&value=<...>` (для портов/провайдера — свои ключи, см. ниже).

| `setting` | параметры | Что делает |
| --- | --- | --- |
| `tls_blob` | `fake_default_tls` \| `tls_*.bin` \| `custom_tls.bin` | смена TLS-блоба: `fake_default_tls` — вернуться на встроенный (декларация `--blob=maxru:@...` сохраняется для обратного переключения); файл — активировать внешний (`fake_default_tls`→`maxru` в ссылках стратегий + замена пути, path-agnostic `zapret2\|zator`) |
| `wg_blob` | `value=<wg_initial_fake_*>` | замена `--blob=fakewgblob:@.../<файл>` |
| `wg_repeats` | `value=<2..99>` | замена `blob=fakewgblob:repeats=N` |
| `wg_state` | `value=0\|1` | вкл/выкл стратегии WG (`--skip` перед `--filter-l7=wireguard`) |
| `fallback_state` | `value=0\|1` | вкл/выкл безразборного режима ([§7](#7-fallback-безразборный-режим)) |
| `udp_games_state` | `value=0\|1` | вкл/выкл игрового UDP (порты + `--skip`) |
| `auto_mode_state` | `value=0\|1` | вкл/выкл авторотации (`config_set_auto_mode` для config+config.default; авто-рестарт, если nfqws2 запущен) |
| `hostlist_state` | `value=0\|1` | `1`=autohostlist, `0`=hostlist (`backup_smart_set_hostlist` для config+config.default) |
| `rst_guard_state` | `value=0\|1` | вкл/выкл RST-guard (`backup_smart_set_rst_guard`) |
| `reasm_state` | `value=0\|1` | вкл/выкл `--reasm-disable` (`backup_smart_set_reasm`) |
| `quic443_state` | `value=0\|1` | вкл/выкл фейков QUIC 443 (`backup_smart_set_quic443`) |
| `ports_add` | `proto=tcp\|udp&value=<порты>` | добавить пользовательские порты (`ports_apply_add`; TCP синхронизирует `--filter-tcp` RKN) |
| `ports_remove` | `proto=tcp\|udp&value=<порт>` | удалить пользовательский порт (`ports_apply_remove`) |
| `provider_set` | `name=<строка>&city=<строка>` | ручная установка провайдера (`provider_set_manual`) |
| `provider_redetect` | — | переопределить провайдера по IP (`provider_force_redetect`, до ~20 с) |

Успех (`200 OK`):

```jsonc
{ "ok": true, "reboot_required": true }
// auto_mode_state: { "ok": true, "restarted": true|false, "state": "включен|выключен" }
// ports_add:       { "ok": true, "added": "8080,9000-9100", "skipped": "", "reboot_required": true }
// provider_*:      { "ok": true, "provider": "MTS - Moscow" }
// hostlist/rst_guard/reasm/quic443 также возвращают актуальное "state"
```

Ошибки режимов и портов:

| Условие | Код | Сообщение |
| --- | --- | --- |
| `value` не `0\|1` | `400` | `Некорректное значение: <value>` |
| `auto_mode=1` при включённом безразборе | `409 Conflict` | `Авторотация недоступна при включённом безразборном режиме. Сначала выключите безразборный режим.` |
| `auto_mode`: маркеры авторежима не найдены | `500` | `В <cfg> не найдены маркеры авторежима. Обновите конфиг через CLI (пункт 5 главного меню).` |
| `rst_guard=1` без `/opt/zator/lua/rst-guard.lua` | `500` | `Файл rst-guard.lua отсутствует на устройстве. Включите защиту один раз через CLI (пункт 18)...` |
| `reasm`: нет `NFQWS2_OPT="` | `500` | `Не найден блок NFQWS2_OPT в конфиге. Обновите конфиг через CLI (пункт 5 главного меню).` |
| `quic443`: нет блока `#Z2R_QUIC443_*` | `500` | `Блок QUIC (UDP443) не найден в конфиге. Обновите конфиг через CLI (пункт 5 главного меню).` |
| `ports_add`: `proto` не tcp/udp | `400` | `Некорректный протокол: <proto>` |
| `ports_add`: ничего не добавлено | `400` | `Ничего не добавлено (некорректные значения или дубликаты): <список>` |
| `ports_remove`: UDP `1026-65531` | `400` | `Диапазон 1026-65531 управляется переключателем игрового UDP на вкладке Настройки` |
| `ports_remove`: порта нет в пользовательских | `400` | `Порт не найден среди добавленных: <порт>` |
| `provider_set` без имени | `400` | `Укажите название провайдера` |
| неизвестный `setting` | `400` | `Неизвестная настройка` |

Ошибки WG и TLS-блоба (`400 Bad Request` / `500 Internal Server Error`):

| Условие | Код | Сообщение |
| --- | --- | --- |
| `wg_blob`: имя не `wg_initial_fake_*` | `400` | `Некорректное значение блоба: <name>` |
| `wg_blob`: файла нет в fake/ | `400` | `Файл блоба не существует: <name>` |
| `wg_blob`: нет `--blob=fakewgblob:@...` в конфиге | `500` | `Стратегия WireGuard не найдена в конфиге (нет --blob=fakewgblob:@...)` |
| `wg_repeats`: не число / вне `2..99` | `400` | `Некорректное значение repeats` / `Значение repeats должно быть от 2 до 99` |
| `wg_repeats`: нет `blob=fakewgblob:repeats=` в конфиге | `500` | `Стратегия WireGuard не найдена в конфиге (нет blob=fakewgblob:repeats=)` |
| `wg_state`: нет блока `#Z2R_WG_*` в конфиге | `500` | `Стратегия WireGuard не найдена в конфиге (нет блока #Z2R_WG_*)` |

> sed-замены 1:1 повторяют CLI-функции
> [`menu_action_set_wg_blob`](../../lib/actions.sh:424) и
> [`menu_action_wg_repeats`](../../lib/actions.sh:372) (пункт 19 меню).
> Вкл/выкл стратегии WG (`wg_state`) повторяет
> [`menu_action_toggle_wireguard_fake`](../../lib/actions.sh:340) ↔
> [`backup_smart_set_wireguard`](../../lib/actions.sh:1242) (пункт 19 меню).

---

---

## 7. Fallback (безразборный режим)

Безразборный режим (fallback) — профили **8 (TLS)** и **9 (HTTP)**, блоки
`#Z2R_FALLBACK_BEGIN`/`#Z2R_FALLBACK_END` и `#Z2R_FALLBACK_HTTP_BEGIN`/`#Z2R_FALLBACK_HTTP_END`
в `config.default`.

### Механизм фиксации стратегии (важно)

Выбор стратегии fallback **не хранится в config-блоке**. Config содержит набор
стратегий (`--lua-desync=...:strategy=N`) и runtime-переключатель
`--lua-desync=circular_locked:key=8` / `key=9`. Реальная активная стратегия
определяется в рантайме: `circular_locked` читает orchestra-lock из
**`locked.manual.tsv`** (см. [`profile_config_orch_set`](../../lib/config.sh:461),
который перенаправляет 8/9 с `locked.tsv` на `locked.manual.tsv`).

Поэтому фиксация стратегии 8/9 — **lock-file based**, как и у обычных профилей:

| Действие | Куда пишет |
| --- | --- |
| `set-lock.cgi` / `clear-lock.cgi` (карточки стратегий) | `profile.lock` + `locked.manual.tsv` (`profile_state_set_and_apply`) |

`current_lock` для 8/9 читается через `profile_state_display` (сначала
`profile.lock`, затем orchestra-lock). Фейк-сервер воспроизводит это 1:1:
профили 8/9 пишут/читают `locked.manual.tsv`.

> Включение/выключение режима (`--skip` в блоках) — отдельный механизм:
> `api_fallback_state_set` вызывает общий сеттер [`backup_smart_set_fallback`](../../lib/actions.sh)
> для config+config.default (паритет с CLI `toggle_fallback_mode`), с guard'ом
> авторотации. Он правит config, а не lock-файлы.

### GET `/cgi-bin/settings.cgi?setting=fallback` → `api_fallback_get`

```jsonc
{
  "state": "выключен",          // "включен" | "выключен" | "недоступен" (авторотация вкл) | "неизвестно"
  "enabled": false              // bool: state == "включен"
}
```

### POST `/cgi-bin/settings.cgi`

| `setting` | параметры | что делает |
| --- | --- | --- |
| `fallback_state` | `value=0\|1` | вкл/выкл режима (`--skip` в блоках, config+config.default) |

Стратегии профилей 8/9 фиксируются через общий `set-lock.cgi`
(`profile=8|9&strategy=N`), не через settings.cgi.

| Условие | Код | Сообщение |
| --- | --- | --- |
| `value` не `0\|1` | `400` | `Некорректное значение: <value>` |
| авторотация включена | `409 Conflict` | `Безразборный режим недоступен при включённой авторотации TCP/HTTP. Сначала выключите авторотацию.` |

Успех: `{"ok":true,"reboot_required":true}`.

Блокировка взаимная: включить `auto_mode_state=1` при включённом безразборе тоже
нельзя — `409 Conflict` (см. таблицу ошибок режимов в §6).

---

## 8. `GET/POST /cgi-bin/domains.cgi` → `api_domains_list` / `api_domains_action`

Управление четырьмя списками доменов (порт пункта 6 CLI-меню `z2r.sh` →
[`lib/strategies.sh`](../../lib/strategies.sh)). Все операции — локальные копии
CLI-логики в [`_lib.sh`](../cgi-bin/_lib.sh) (`netrogat_file`, `custom_rkn_file`,
`rkn_substring_file`, `netrogat_substring_file`, `z2r_normalize_domain`, `_domain_list_*`,
`_custom_rkn_remove_domain`), см. [High-Risk Areas](../../AGENTS.md) про синхронизацию
с CLI.

### Списки и их файлы

| `list` | файл | `kind` | назначение |
| --- | --- | --- | --- |
| `netrogat` | `/opt/zator/lists/netrogat.txt` | `domain` | исключения (`--hostlist-exclude`) |
| `custom_rkn` | `/opt/zator/extra_strats/TCP_Custom.txt` | `domain` | RKN-домены с per-domain стратегией |
| `substring` | `/opt/zator/extra_strats/TCP_RKN_domains_by_substring.txt` | `substring` | подстроки имени (без нормализации) |
| `netrogat_substring` | `/opt/zator/lists/netrogat_substrings.txt` | `substring` | подстроки-исключения (lua `exclude_substrings`, без нормализации) |

> Списки подхватываются nfqws2 runtime — **перезапуск сервиса не требуется**
> для add/remove/import/clear. Per-domain стратегия для `custom_rkn` пишется в
> `locked.tsv` (`orch_locked_set "$domain" "tls" "$N"`), как в CLI.

### GET `/cgi-bin/domains.cgi?list=<name>` → `api_domains_list`

Параметр `list` — один из `netrogat|custom_rkn|substring|netrogat_substring`. Неизвестное имя →
`400` `Неизвестный список`.

```jsonc
// netrogat / substring
{
  "list": "netrogat",
  "title": "Исключения (netrogat.txt)",
  "description": "Домены, исключаемые из обработки zapret2 (--hostlist-exclude).",
  "kind": "domain",
  "is_custom_rkn": false,
  "max_strategy": 0,
  "items": [{"value": "pinterest.com"}, {"value": "avito.ru"}]
}

// custom_rkn — каждому домену сопоставлена стратегия из locked.tsv (0 = авто)
{
  "list": "custom_rkn",
  "title": "TCP_Custom (RKN-домены)",
  "description": "...",
  "kind": "domain",
  "is_custom_rkn": true,
  "max_strategy": 30,                       // orch_max_strategy_for_profile 3 (fallback 19)
  "items": [{"value": "meduza.io", "strategy": 5}, {"value": "dw.com", "strategy": 0}]
}
```

### POST `/cgi-bin/domains.cgi`

| `action` | параметры | что делает | ответ |
| --- | --- | --- | --- |
| `add` | `list&domain` | нормализация (для `domain`), дедупликация | `{"ok":true,"duplicate":false\|true}`; для `custom_rkn` дополнительно `"check":{...}` |
| `remove` | `list&domain` | удаление; для `custom_rkn` — чистка `locked.tsv` tls/http/udp | `{"ok":true}` |
| `import` | `list&domain=<многострочник>` | построчно: нормализация+дедуп | `{"ok":true,"added":N,"duplicates":N,"skipped":N}` |
| `clear` | `list` | `: > file`; для `custom_rkn` — очистка per-domain локов | `{"ok":true,"cleared":N}` |
| `set_strategy` | `list=custom_rkn&domain&strategy=N` | `orch_locked_set domain tls N` (1..max) + проверка домена | `{"ok":true,"strategy":N,"check":{...}}` |
| `clear_strategy` | `list=custom_rkn&domain` | `orch_locked_clear domain tls` (возврат к авто) | `{"ok":true}` |
| `check` | `list=custom_rkn&domain` | быстрая проверка `https://<domain>/` движком `z2r_tls_*` из `lib/netcheck.sh` (как в CLI при подборе стратегии) | `{"ok":true,"check":{...}}` |

`"check"` — тот же формат, что у [`check.cgi`](#5-post-cgi-bincheckcgi--api_check):
`{"results":[{...одна цель...}]}` с `verdict`/`text`/`tls12_detail`/`tls13_detail`/
`download` (label = домен). WebUI показывает его при добавлении домена, в панели
«Подобрать» после каждой применённой стратегии и по кнопке «Проверить» у строки —
тексты включают подсказку «Проверьте доступность вручную. Возможно ошибка теста.».

**Коды ошибок (400 Bad Request):**

| условие | сообщение |
| --- | --- |
| неизвестный `list` | `Неизвестный список` |
| `add` без `domain` | `Не указан домен` |
| `add` невалидный домен (`kind=domain`) | `Некорректный домен: <value>` |
| `add` пустая подстрока (`kind=substring`) | `Пустая подстрока` |
| `set_strategy` на не-custom_rkn | `Стратегия применяется только к TCP_Custom` |
| `set_strategy` домена нет в списке | `Домена нет в списке` |
| `set_strategy` вне диапазона | `Стратегия вне диапазона (1..<max>)` |
| `set_strategy` не число | `Некорректная стратегия` |
| `check` на не-custom_rkn | `Проверка применяется только к TCP_Custom` |
| `check` без `domain` | `Не указан домен` |
| неизвестный `action` | `Неизвестное действие: <action>` |

**409 Conflict** (взаимоисключение с автосбором списков):

| условие | сообщение |
| --- | --- |
| `add`/`import` в `custom_rkn` или `substring` при `hostlist=авто` | `Автосбор списков включён: домены RKN zapret2 определяет автоматически. Выключите автосбор в настройках, чтобы пополнять список вручную.` |

Списки исключений (`netrogat`, `netrogat_substring`) ограничению не подлежат;
`remove`/`clear`/`set_strategy` доступны всегда.

Метод не из {GET,POST} → `405` `Метод не поддерживается`.

> Ответы доменных действий **не содержат** `reboot_required` (списки не требуют
> рестарта). В отличие от `set-lock.cgi`, `set_strategy` для домена меняет только
> `locked.tsv`, который читается Lua-стороной runtime.

---

## 9. `GET/POST /cgi-bin/backups.cgi` → `api_backups_*`

Бэкапы: список архивов, создание, скачивание, удаление и импорт. Восстановление —
только CLI (пункт 21 меню). Все операции используют общие ядра из
[`lib/actions.sh`](../../lib/actions.sh) (тот же код, что и CLI): архив `.tar` в
`/opt/zator_backup` с config, списками доменов и lock-файлами.

### GET → `api_backups_list`

```jsonc
{
  "items": [
    { "name": "z2r_backup_20260820_141857.tar", "size": 16896, "date": "2026-08-20 14:18:57" }
  ]
}
```

`date` разбирается из имени файла (`z2r_backup_YYYYmmdd_HHMMSS.tar`), `size` —
байты.

### GET `?action=download&name=<архив>` → `api_backups_download`

Бинарный ответ: `Content-Type: application/x-tar`,
`Content-Disposition: attachment; filename="<архив>"`, тело — байты tar-архива.
Фронтенд скачивает обычной навигацией по ссылке (без fetch).

| Условие | Код | Сообщение |
| --- | --- | --- |
| нет `name` | `400` | `Не указано имя файла` |
| архив не найден / имя мимо шаблона | `404` | `Бэкап не найден` |

### POST → `api_backups_create`

Тело: `action=create`.

| Условие | Код | Сообщение |
| --- | --- | --- |
| `action` не `create`/`delete` | `400` | `Неизвестное действие` |
| `backup_create_core` упала | `500` | `Не удалось создать бэкап` |

Успех: `{"ok":true,"name":"z2r_backup_<ts>.tar"}`.

### POST `action=delete&name=<архив>` → `api_backups_delete`

| Условие | Код | Сообщение |
| --- | --- | --- |
| нет `name` | `400` | `Не указано имя файла` |
| архив не найден / имя мимо шаблона | `404` | `Бэкап не найден` |

Успех: `{"ok":true,"name":"<архив>"}`. Имя валидируется ядром
`backup_resolve_archive` (шаблон `z2r_backup_*.tar` + присутствие в списке
каталога — path traversal исключён).

### POST `?action=upload&name=<оригинальное имя>` → `api_backups_upload`

Тело — сырые байты tar-архива (`Content-Type: application/x-tar`), не
url-encoded: `parse_params` в этом случае не вызывается. Лимит — 32 МБ.

| Условие | Код | Сообщение |
| --- | --- | --- |
| пустое тело / `CONTENT_LENGTH=0` | `400` | `Пустой файл` |
| тело больше 32 МБ | `413` | `Файл слишком большой (максимум 32 МБ)` |
| принято меньше байт, чем заявлено | `400` | `Файл получен не полностью` |
| не tar или без ожидаемых записей | `400` | `Файл не является архивом бэкапа` |

Успех: `{"ok":true,"name":"<итоговое имя>"}`. Итоговое имя выбирает ядро
`backup_import_core`: оригинальное, если оно строго
`z2r_backup_YYYYmmdd_HHMMSS.tar` и не занято, иначе `z2r_backup_<ts>.tar`
(при коллизии — суффикс `_N`). Архив обязан содержать `config` или файлы из
`lists/` / `extra_strats/`.

Метод не из {GET,POST} → `405` `Метод не поддерживается`.

---

## Что фронтенд реально вызывает (`app.js`)

| Вызов | Метод | Тело |
| --- | --- | --- |
| [`api('/cgi-bin/status.cgi')`](../app.js:292) | GET | — |
| [`api('/cgi-bin/set-lock.cgi', POST)`](../app.js:215) | POST | `profile=<id>&strategy=<n>` |
| [`api('/cgi-bin/clear-lock.cgi', POST)`](../app.js:232) | POST | `profile=<id>` |
| [`api('/cgi-bin/service.cgi', POST)`](../app.js:322) | POST | `action=<start\|stop\|restart>` |
| [`api('/cgi-bin/check.cgi', POST)`](../app.js:347) | POST | — |
| [`api('/cgi-bin/settings.cgi')`](../app.js:411) | GET | — (TLS-блоб) |
| [`api('/cgi-bin/settings.cgi?setting=wg_blob')`](../app.js:484) | GET | — (WG-блоб + repeats) |
| [`api('/cgi-bin/settings.cgi?setting=wg_state')`](../app.js) | GET | — (состояние WG вкл/выкл) |
| [`api('/cgi-bin/settings.cgi', POST)`](../app.js:421) | POST | `setting=tls_blob&value=<blob>` |
| [`api('/cgi-bin/settings.cgi', POST)`](../app.js:493) | POST | `setting=wg_blob&value=<wg_initial_fake_*>` |
| [`api('/cgi-bin/settings.cgi', POST)`](../app.js:500) | POST | `setting=wg_repeats&value=<2..99>` |
| [`api('/cgi-bin/settings.cgi', POST)`](../app.js) | POST | `setting=wg_state&value=<0\|1>` |
| [`api('/cgi-bin/settings.cgi?setting=fallback')`](../app.js) | GET | — (состояние fallback) |
| [`api('/cgi-bin/settings.cgi', POST)`](../app.js) | POST | `setting=fallback_state&value=<0\|1>` |
| [`api('/cgi-bin/settings.cgi?setting=auto_mode\|hostlist\|rst_guard\|reasm\|quic443', GET)`](../app.js) | GET | — (тумблеры «Режим работы») |
| [`api('/cgi-bin/settings.cgi', POST)`](../app.js) | POST | `setting=auto_mode_state\|hostlist_state\|rst_guard_state\|reasm_state\|quic443_state&value=<0\|1>` |
| [`api('/cgi-bin/settings.cgi?setting=ports')`](../app.js) | GET | — (порты NFQWS2) |
| [`api('/cgi-bin/settings.cgi', POST)`](../app.js) | POST | `setting=ports_add\|ports_remove&proto=tcp\|udp&value=<порты>` |
| [`api('/cgi-bin/settings.cgi?setting=provider')`](../app.js) | GET | — (провайдер) |
| [`api('/cgi-bin/settings.cgi', POST)`](../app.js) | POST | `setting=provider_set&name=<...>&city=<...>` / `setting=provider_redetect` |
| [`api('/cgi-bin/backups.cgi')`](../app.js) | GET | — (список бэкапов) |
| [`api('/cgi-bin/backups.cgi', POST)`](../app.js) | POST | `action=create` |
| `location /cgi-bin/backups.cgi?action=download&name=...` | GET | — (скачивание архива) |
| [`api('/cgi-bin/backups.cgi', POST)`](../app.js) | POST | `action=delete&name=<архив>` |
| [`api('/cgi-bin/backups.cgi?action=upload&name=...', POST)`](../app.js) | POST | raw tar (тело — `File`) |
| [`api('/cgi-bin/set-lock.cgi', POST)`](../app.js) | POST | `profile=<8\|9>&strategy=<n>` (карточки fallback) |
| [`api('/cgi-bin/clear-lock.cgi', POST)`](../app.js) | POST | `profile=<8\|9>` (сброс карточки fallback) |
| [`api('/cgi-bin/domains.cgi?list=...')`](../app.js:987) | GET | — (содержимое списка доменов) |
| [`api('/cgi-bin/domains.cgi', POST)`](../app.js:991) | POST | `list=<n>&action=add\|remove\|import\|clear\|set_strategy\|clear_strategy\|check&domain=<...>&strategy=<n>` |

Статика: `index.html`, `styles.css`, `app.js` (отдаются как есть).

> Провайдер теперь реально читается из `cache/provider.txt` (`_provider_cache_text`)
> и отображается в статусе и панели «Провайдер». Флаг `--provider` фейк-сервера
> задаёт стартовое значение; `provider_set`/`provider_redetect` меняют его.
