# Zator Desktop Probe — архитектура и протокол

**Версия проекта протокола:** draft v0.1. Поля и команды — предлагаемый контракт, их ещё нужно реализовать и закрепить тестами. Не считать примеры ниже существующими методами Zator.

## 1. Цель и границы

Десктопное приложение открывает сайты на своём Chromium и последовательно испытывает существующие стратегии из установленного Zator. Пользовательский трафик маршрутизируется и обрабатывается **исключительно рабочим** экземпляром Zator. Пробный браузерный TCP-трафик идёт через **отдельные** SOCKS5, NFQUEUE и `nfqws2` на роутере.

Сравнение двух транспортных режимов:

| Режим | В MVP | Источник TCP-соединения к сайту | UDP/QUIC | Репрезентативность |
| --- | --- | --- | --- | --- |
| `router_socks_tcp` | Да | Сам Keenetic (SOCKS5 CONNECT) | Нет | TLS/HTTP/WS близки к реальным, TCP fingerprint и путь могут отличаться |
| `tunnel_forwarded` | Нет | Виртуальный клиентский интерфейс в туннеле | Да при реализации | Ближе к forwarding через LAN→WAN, но остаются эффекты туннеля/NAT/MTU |

## 2. Потоки управления и данных

```text
WINDOWS: Zator Desktop Probe
  ├─ Electron UI + WebContentsView (страница сайта без Node.js privileges)
  │    └─ SOCKS5 127.0.0.1:<local_port>
  │          │
  │          └── SSH TCP forward (-L) ───────────┐
  └─ SSH adapter                                │
       └─ zator-desktop-probe --json <command>  │
                  │                              │
KEENETIC/ENTWARE  │                              │
  ┌───────────────┘                              │
  │  Router Agent CLI/daemon                     │
  │    ├─ session + strategy + telemetry          │
  │    └─ isolated nfqws2 (private Lua/locks)     │
  │                                               ▼
  └─ SOCKS5 (bind 127.0.0.1, dedicated PROXY_UID)
         └─ outbound TCP socket
             └─ static test classification (owner UID + conntrack)
                 └─ separate NFQUEUE (TCP in/out)
                     └─ isolated nfqws2 ── WAN ── website

  normal LAN/host connections ── existing production nfqws2 ── WAN
```

**Почему не только `ssh -D`:** при `ssh -D` TCP-соединения на роутере открывает SSH-сервер. Его UID и окружение не являются надёжным собственным селектором **только** тестовых соединений. Отдельный loopback SOCKS с самостоятельным непривилегированным UID формирует очевидный идентификатор для `OUTPUT`.

**Не использовать один UID для прокси и тестового nfqws2.** В нынешнем `supersweep_transport.sh` UID тестового `nfqws2` используется для распознавания raw-пакетов, отправляемых самим движком. При совпадении с SOCKS UID пакетные контуры перестанут быть однозначно разделены.

## 3. Проверка критического packet path

На этапе PoC документировать по факту реального Keenetic (цепочки и порядок ниже — **требования к поведению**, а не готовый набор iptables-команд):

1. В `OUTPUT` исходящий TCP-socket от `PROXY_UID` получает уникальную метку test session; метка должна пережить текущую policy routing, не менять WAN/next-hop без явной необходимости и переноситься на flow через `CONNMARK`.
2. В `POSTROUTING` исходящие test-пакеты попадают в отдельную NFQUEUE **до** рабочего production перехвата, затем выходят без повторной доставки в production очередь.
3. Ответные пакеты в `PREROUTING`/`INPUT` сопоставляются по **conntrack и направлению**, а не по совпадению удалённого порта или только IP; test REPLY попадает в test queue и исключается из production queue.
4. Пакеты фейков/инъекций тестового `nfqws2` не должны снова проходить тестовый NFQUEUE, не должны попасть в production NFQUEUE и должны иметь ожидаемую маршрутизацию.
5. При отсутствии test `nfqws2` можно использовать безопасный `queue-bypass` с точки зрения доступности роутера, **но результат любой пробы, не подтверждённой фактической обработкой, всегда INVALID**.
6. Все используемые значения `NFQUEUE`, `PROXY_UID`, `NFQWS_UID`, `fwmark`, `connmark` проверяются на конфликт с реальными настройками. Выделить известный test mark только после аудита `DESYNC_MARK`, `DESYNC_MARK_POSTNAT`, `FILTER_MARK`, `CLIENT_SCOPE_MARK_MASK` и иных владельцев mark.
7. Статические правила устанавливаются/восстанавливаются netfilter hook. В `set-strategy`, `start`, `stop` нельзя запускать `iptables -I/-D/-F`/`nft add/delete/flush`. Просмотр без мутаций допустим.
8. Проверки изоляции выполняются отдельно для *одновременного* user browsing, proxy browsing, тестовых raw-фейков и активной policy routing (VPN при наличии).

**Внимание:** текущий `supersweep_transport.sh` распознаёт `curl` по TCP source ports `62000–62999` и по UID `65533` для raw-сегментов. SOCKS5 создаёт свои outbound source ports; старые rules нельзя просто переименовать и объявить готовым решением.

## 4. Router Agent — форма интерфейса

Рекомендуемый MVP — ограниченный CLI с JSON через SSH. Можно позже перейти на долгоживущий JSON-RPC over stdio; внешнего HTTP API в LAN/WAN не нужно.

Пример вызова (имена демонстрационные):

```bash
ssh zator@router.example '/opt/zator/bin/zator-desktop-probe capabilities --json'
ssh zator@router.example '/opt/zator/bin/zator-desktop-probe start --profile 1 --json'
ssh zator@router.example '/opt/zator/bin/zator-desktop-probe set-strategy --session <id> --strategy 7 --json'
ssh zator@router.example '/opt/zator/bin/zator-desktop-probe telemetry --session <id> --json'
ssh zator@router.example '/opt/zator/bin/zator-desktop-probe stop --session <id> --json'
```

Пример `capabilities`:

```json
{
  "api_version": "0.1",
  "platform": "keenetic-entware",
  "arch": "mipsel",
  "transport": ["router_socks_tcp"],
  "protocols": ["tcp", "tls", "http1", "http2", "websocket"],
  "ipv6_supported": false,
  "quic_supported": false,
  "ssh_forwarding_supported": true,
  "profiles": [1, 2, 3, 4],
  "isolation": {"available": true, "reason": null}
}
```

`start`:

```json
{
  "session_id": "probe-20261024-example",
  "lease_expires_at": "2026-10-24T08:59:00Z",
  "proxy": {"type": "socks5", "host": "127.0.0.1", "port": 41081},
  "queue": {"number": 65534, "healthy": true},
  "profile": 1,
  "strategy": "DIRECT",
  "strategy_generation": 1,
  "transport_generation": 4,
  "mode": "router_socks_tcp"
}
```

Номер `65534` и порт `41081` — **только примеры**; реальный выбор зависит от аудита и конфликта с существующим Supersweep.

`set-strategy`:

```json
{
  "session_id": "probe-20261024-example",
  "profile": 1,
  "strategy": 7,
  "strategy_generation": 2,
  "effective_at": "2026-10-24T08:45:10.000Z",
  "ready_for_new_flows": true
}
```

`telemetry`:

```json
{
  "session_id": "probe-20261024-example",
  "strategy_generation": 2,
  "transport_generation": 4,
  "queue": {"alive": true, "counter_before": 120, "counter_after": 138},
  "proxy": {"alive": true, "connections_started": 3},
  "nfqws": {"alive": true, "lua_errors": 0},
  "proof": {"connection_match": "verified", "strategy_invocation": "unavailable"},
  "warnings": []
}
```

**Важно:** ненулевой delta queue-counter — только один из сигналов. Если невозможно подтвердить, что очередь получила пакеты нужного proxy-flow, `proof.connection_match` не должен становиться `verified`. Подтверждение фактической Lua-стратегии требует соответствующей инструментализации; не выдумывать поле `strategy_invocation=verified` при отсутствии события.

## 5. Ошибки и состояния

Рекомендованный единый envelope ошибки:

```json
{
  "ok": false,
  "error": {"code": "NFQUEUE_NOT_ACTIVE", "message": "Test queue is unavailable", "retryable": true}
}
```

Коды ошибок как минимум:

| Код | Реакция |
| --- | --- |
| `UNSUPPORTED_PLATFORM`, `UNSUPPORTED_CAPABILITY` | Остановить подготовку, показать причину |
| `UID_COLLISION`, `QUEUE_COLLISION`, `MARK_COLLISION` | Не запускать сессию; запрещён автоматический fallback |
| `SESSION_BUSY`, `SESSION_EXPIRED`, `SESSION_NOT_OWNER` | Не затрагивать чужую сессию |
| `SSH_FORWARDING_UNAVAILABLE`, `SOCKS_DOWN`, `PROXY_UNREACHABLE` | INVALID, транспортный сбой |
| `NFQUEUE_NOT_ACTIVE`, `TRANSPORT_CHANGED`, `ROUTE_MISMATCH` | INVALID, повтор после восстановления |
| `NFQWS_EXITED`, `NFQWS_LUA_ERROR` | INVALID, лог диагностики |
| `STRATEGY_UNKNOWN`, `PROFILE_UNKNOWN` | Ошибка входных данных, не менять состояние |
| `BROWSER_TIMEOUT`, `TLS_FAILURE`, `RESOURCE_ERROR` | Сетевой результат, анализировать на уровне сервиса |
| `CANCELLED` | Отмена без ошибочного FAIL |

Состояния сессии: `created`, `ready`, `switching`, `testing`, `stopping`, `stopped`, `expired`, `error`. Не путать состояние инфраструктуры с verdict конкретной стратегии.

## 6. Контракт стратегии и результата

```json
{
  "test_id": "uuid",
  "session_id": "probe-20261024-example",
  "site": "https://example.org/",
  "profile": 1,
  "strategy": 7,
  "mode": "router_socks_tcp",
  "protocol_scope": "TCP_ONLY_IPV4",
  "strategy_generation": 2,
  "transport_generation_start": 4,
  "transport_generation_end": 4,
  "network": {"main_document_http_status": 200, "tls_ok": true},
  "functionality": {"scenario": "generic_page", "passed": null},
  "isolation": {"queue_verified": true, "flow_verified": true},
  "verdict": "UNKNOWN",
  "reason": "Page loads; required functional condition was not proven"
}
```

Вердикты:

- `OK`: тестовая инфраструктура подтверждена **и** условия выбранного сценария доказанно выполнены.
- `FAIL`: тестовая инфраструктура подтверждена, а ожидаемое соединение или обязательное действие устойчиво не выполняется по явно определённому условию после предусмотренных повторов.
- `WARN`: частично работает или нестабильно; доказано, что часть проверки прошла, но обязательные условия не гарантированы.
- `UNKNOWN`: недостаточно данных, нужна авторизация/капча, лимитированное наблюдение, неопределённые требования сценария.
- `INVALID`: проблема маршрута, queue, агента, смены поколения, недостаточного подтверждения обработки; **не участвует** в ранжировании стратегии.

Сетевые ошибки, HTTP status и функциональный результат сохраняются **отдельными полями**, а не схлопываются в бинарный статус. Каждая новая попытка получает новый `attempt_id` и browser context. `DIRECT` сохраняется как отдельная стратегия, без DPI-подмен, но по идентичному каналу доставки.

## 7. Браузер и сетевые наблюдения

- Использовать Electron `WebContentsView` и in-memory partitions `session.fromPartition()` для тестовых страниц. Каждой стратегии выделять новый контекст; если фактически остаются прежние сокеты или connection pool, усиливать изоляцию до отдельного browser process.
- Проксировать только тестовые webContents; управляющее окно, обновления приложения и служебные API не должны использовать тестовый SOCKS.
- Проверять `session.setProxy({ proxyRules: 'socks5://127.0.0.1:<port>' })`, блокировать unproxied fallback и явно отключать QUIC/неподдерживаемые UDP-вызовы. Проверить на wire capture, а не предполагать, что флаг гарантирует отсутствие всех обходов.
- Наблюдать CDP `Network.*`, `Page.*`, события webContents, WebSocket handshake, `media` progress. CDP attachment может конфликтовать с DevTools; обеспечить безопасный lifecycle detach.
- Не собирать cookies, Authorization, request/response bodies, парольные формы, localStorage, полные query string. Скриншоты только по запросу или по явному opt-in.
- Определить защиту от локального DNS leak: в Chromium SOCKS5 hostname resolution выполняется на стороне proxy, но необходимо проверить фактический DNS путь на роутере и поведение нестандартных URL/компонентов.
- Сертификаты TLS проверяются штатным образом; не отключать их глобально ради «зелёной» проверки.

## 8. Жизненный цикл и восстановление

1. Клиент проверяет SSH host key, выполняет `capabilities`, запрашивает `start`.
2. Agent атомарно резервирует session lock, проверяет UID/marks/queue, запускает тестовый `nfqws2` и SOCKS, ждёт реально активной NFQUEUE.
3. Клиент запускает SSH `-L` к loopback SOCKS, проверяет соединение, затем открывает браузер.
4. Перед каждым тестом клиент проверяет поколение стратегии и транспорта; после теста подтверждает, что поколение не изменилось и пакеты были атрибутированы сессии.
5. Heartbeat обновляет lease. При потере связи агент прекращает новые тесты и по TTL очищает дочерние процессы, но не удаляет статические firewall rules.
6. `stop` идемпотентен. Сломанный cleanup должен быть видимым, логируемым и повторяемым.
7. После reboot восстановятся только статические правила. **Нельзя** автоматически возобновлять старый browser test без проверки сессии и версии стратегий.

## 9. Security requirements

- SSH public-key/agent и проверка host key; минимально необходимые права и явное доверие роутеру.
- CLI-параметры — enum/числа/валидированные ID; никаких неконтролируемых shell snippets, динамических путей или сериализации JSON в `/bin/sh -c`.
- Сетевой SOCKS слушает исключительно loopback на роутере; локальный SSH forward — только `127.0.0.1` ПК.
- Управляющий процесс с привилегиями разделяется с непривилегированным SOCKS-процессом.
- Web UI не отдаёт полномочия приложению открытой странице: Node integration выключен, context isolation/sandbox включены, нет произвольного IPC из сайта, permissions/downloads/popup — deny по умолчанию.
- Логи и отчёты не содержат паролей, личных токенов, auth headers и приватных URL-параметров.
- Параллельные сессии по умолчанию запрещены; сессии привязывать к владельцу/случайному токену, hash токена хранить в root-only state.

## 10. Решения, которые необходимо подтвердить во время PoC

| Вопрос | Что проверить | Влияние |
| --- | --- | --- |
| Поддержка SSH port forwarding | Физический Keenetic и конкретный SSH-сервер/порт | Без неё нужен другой канал данных |
| Способ запуска SOCKS под отдельным UID | Наличие `setpriv`/`su`/нативного drop privileges | Без этого owner-based селектор требует замены |
| Защита от пересечения mark | Реальные конфиги и policy routing | Коллизии запрещают запуск |
| Фактическая цепочка перехвата для local OUTPUT | iptables/nfnetlink counters и pcap | Порядок нельзя определять только по документации |
| Применение стратегии внутри `nfqws2` | логирование/доказательство вызова Lua на нужном flow | Без подтверждения verdict может быть UNKNOWN/INVALID |
| Режим DIRECT | Настоящий passthrough того же тестового flow | Иначе baseline несопоставим |
| Трафик IPv6 | Проверка отсутствия обхода очереди | До поддержки IPv6 — безопасный отказ |
| Эффект браузерного cache/connection pool | TCP/TLS handshakes на каждой попытке | Иначе переключение стратегии недостоверно |

## 11. Границы переиспользования mawg / MagiTrickle / sing-box-lx

См. подробный аудит и actionable задачи в [`EXISTING_PROJECT_REUSE.md`](EXISTING_PROJECT_REUSE.md).

- `sing-box-lx` может быть **реализацией отдельного SOCKS5 data-plane** на роутере. Для тестов запускать собственный процесс с отдельными конфигом, PID, логами, UID, loopback ingress и строго `direct` outbound. Никаких рабочих VLESS/AWG/chain/mixed policy. `lxd` пригоден для управления *sing-box*, но не заменяет ни NFQUEUE, ни доказательство срабатывания `nfqws2`; в MVP использовать его необязательно.
- `mawg` — возможный источник адаптеров платформы и идей проверок выхода интерфейсов (`internal/platform/keenetic`, `internal/platform/openwrt`, `internal/rotator/probe_linux.go`); также read-only сведения о текущих туннелях. Его демону, пулам, fallback и health rotation **не поручать** тестовые соединения, чтобы не изменить маршрут production.
- MagiTrickle отвечает за policy/DNS-маршрутизацию, а не за DPI-desync. Его API можно опрашивать *read-only* для обнаружения возможного влияния, но нельзя выполнять тестовую маршрутизацию через модификации production групп; в роутере правила могут перезаписываться. Для реальной изоляции надо доказать outgoing WAN path по conntrack/pcap/маркам, не только по HTTP 200.
- Отсутствие всех трёх проектов **не мешает** работе Probe; зависимости диагностируются как optional. Любое прямое заимствование Go-кода требует отдельной проверки лицензий и состояния API на выбранном SHA.

Приоритет решения: сначала isolated packet path + пригодность `sing-box-lx` по ресурсам; после этого optional mawg/MagiTrickle-интеграции. Если выделенный sing-box не проходит испытания на 128 МБ RAM, заменить только SOCKS-реализацию, не менять контракт `router_socks_tcp`.

## 12. Справочная документация

- Zator `lib/supersweep_probe.sh`: https://github.com/AloofLibra/zator/blob/zator/lib/supersweep_probe.sh
- Zator `lib/supersweep_transport.sh`: https://github.com/AloofLibra/zator/blob/zator/lib/supersweep_transport.sh
- Keenetic OPKG/netfilter.d: https://support.keenetic.ua/titan/kn-1811/en/42407-opkg-component-description.html
- Chromium SOCKS5 (remote DNS, TCP only): https://chromium.googlesource.com/chromium/src/+/312b6bf/net/docs/proxy.md
- Electron WebContentsView: https://www.electronjs.org/docs/latest/api/web-contents-view
- Electron webContents: https://www.electronjs.org/docs/latest/api/web-contents/

- mawg: https://github.com/MarkinAlexander/mawg
- mawg platform/probe: https://github.com/MarkinAlexander/mawg/blob/main/internal/rotator/probe_linux.go
- mawg MagiTrickle client: https://github.com/MarkinAlexander/mawg/blob/main/internal/magitrickle/client.go
- MagiTrickle fork: https://github.com/MarkinAlexander/magitrickle
- sing-box-lx: https://github.com/MarkinAlexander/sing-box-lx
- sing-box-lx `lxd`: https://github.com/MarkinAlexander/sing-box-lx/blob/lx/docs-lx/lxd-daemon.md
