# Client scopes: контракт и ограничения

> Практическая инструкция по обновлению и использованию CLI: [`CLIENT_SCOPES_GUIDE.md`](CLIENT_SCOPES_GUIDE.md)

Этот документ фиксирует MVP-контракт для стратегий, выбираемых по устройству-клиенту. Он описывает формат Lua, shell API и firewall-интеграций. Runtime уже публикует privacy-safe диагностику scope, но включение client scope по умолчанию по-прежнему запрещено.

## Статус и совместимость

- MVP включается только явно: `CLIENT_SCOPE_ENABLE=1`. Значение по умолчанию — `0`.
- Отсутствие новых параметров в старом конфиге означает старое глобальное поведение.
- До завершения стендовых проверок нельзя включать client scopes по умолчанию.
- Внешний launcher `AloofLibra/z4r:z2r` для этого контракта менять не требуется.

Текущие точки интеграции:

- [`config.default`](../config.default) задаёт режим NAT и служебные zapret2 marks.
- [`orchestra/locked.lua`](../orchestra/locked.lua) сейчас читает глобальные `locked.tsv` и `locked.manual.tsv` по ключу profile/proto.
- [`lib/orchestra_state.sh`](../lib/orchestra_state.sh) сейчас предоставляет глобальные shell-обёртки для lock-файла.
- Реализация и smoke-проверки находятся в этом репозитории; отдельный план-файл в поставку не входит.

Runtime поддерживает чтение и диагностику перечисленных `CLIENT_SCOPE_*` параметров; это не означает автоматического включения scope-маршрутизации: без явного `CLIENT_SCOPE_ENABLE=1` сохраняется legacy global/default поведение.

## Канонические scopes MVP

Поддерживаются только два вида логического scope:

| Запись | Значение |
|---|---|
| `default` | Глобальный scope. Это также значение для всех legacy lock-записей. |
| `mark:<decimal>` | Scope, полученный из отдельной client-mark маски firewall, например `mark:101`. `<decimal>` — каноническое беззнаковое десятичное число; `0` не является client scope. |

`ip4:`, `ip6:` и `cidr:` могут появиться позднее как административные идентификаторы или входные значения firewall mapping. В MVP Lua не определяет их по адресу пакета и не преобразует post-NAT source IP в scope.

### Нормализация и безопасный fallback

1. При `CLIENT_SCOPE_ENABLE=0`, пустой или некорректной маске scope равен `default`.
2. Из `desync.fwmark` извлекаются только биты выделенной client-mark маски и применяется заданный shift. Биты служебных marks в scope не входят.
3. Нулевой, неизвестный, отрицательный, нечисловой или переполненный результат даёт `default`.
4. Неканоническая запись scope, tab/newline в scope и значение вне допустимого диапазона отклоняются на границе API/парсера.
5. Отсутствие `fwmark`, отсутствие `track` или невозможность безопасно извлечь mark не должны ронять Lua; результатом становится `default`.

Целевая конфигурация должна иметь один источник параметров для firewall и Lua:

```ini
# Параметры MVP читаются runtime для diagnostics; scope-маршрутизация
# по умолчанию не включена.
CLIENT_SCOPE_ENABLE=0
CLIENT_SCOPE_MARK_MASK=
CLIENT_SCOPE_MARK_SHIFT=0
CLIENT_SCOPE_MARK_MAX=255
```

Маска считается небезопасной, если пересекается с `DESYNC_MARK` или `DESYNC_MARK_POSTNAT`. В таком случае client scope не применяется и используется `default`; запуск старой схемы не должен ломаться.

## Client mark не является zapret mark

В [`config.default`](../config.default) сейчас определены служебные marks zapret2:

```ini
DESYNC_MARK=0x40000000
DESYNC_MARK_POSTNAT=0x20000000
```

Они нужны nfqws2 для защиты от повторной обработки/служебной маршрутизации и **не могут использоваться как идентификатор устройства**. `FILTER_MARK`, если он задан, также остаётся фильтром допуска трафика, а `POLICY_MARK` — частью policy-интеграции; ни один из них не становится client scope автоматически.

Client mark — отдельный namespace:

```text
LAN-классификатор до NAT  ->  client mark  ->  connmark/пакет  ->  nfqws2
                                                          |
                                                          +-> desync.fwmark -> mark:<decimal>
```

Firewall должен выставлять client mark там, где ещё виден исходный LAN-клиент, и при необходимости сохранять его в connmark для всего flow. Lua не должна пытаться восстановить устройство по внешнему адресу роутера, `desync.dis.ip.ip_src`, IPv4/IPv6 source или MAC.

## Жизненный цикл scope в flow

- Scope определяется для исходящего направления по client mark.
- Для соединения scope сохраняется в `desync.track.lua_state`.
- Ответное направление использует сохранённый scope исходящего flow, а не заново вычисляет устройство по адресу ответа.
- Если track отсутствует, scope не может быть надёжно привязан к flow: используется `default` или безопасный no-op согласно текущему пути.
- Hostname normalization и grouping не зависят от client scope. Scope лишь добавляется к ключу выбора/обучения.

Целевой ключ автоматического состояния:

```text
(scope, askey/profile, normalized_hostname)
```

В нём должны быть раздельными тесты, успехи, blocked strategies, failure counters, in-flight state и lock. Успехи `mark:101` не могут изменять статистику `mark:102` или `default`.

## Приоритет выбора lock

Scope — внешний приоритет над уже существующей логикой profile/proto/hostname. Для каждой строки ниже сначала применяется действующая нормализация hostname и выбор effective profile, затем ищется lock:

| Приоритет | Scope и ключ | Результат |
|---:|---|---|
| 1 | точный client scope `mark:N` + effective profile + proto | scoped lock конкретного клиента |
| 2 | точный client scope `mark:N` + базовый profile + proto | scoped lock после существующего host-to-base fallback |
| 3 | `default` + effective profile + proto | legacy/global lock для этого профиля |
| 4 | `default` + базовый profile + proto | legacy/global lock после host-to-base fallback |
| 5 | lock не найден или слой пропущен из-за конфликта | автоматический выбор/текущее поведение без lock |

Отдельно, для будущих административных scope (`cidr:`/группа) должна применяться явная специфичность: точный scope → более узкий scope → `default` → automatic. В MVP такие scope не вычисляются Lua и не должны молча включаться.

`strategy=0` — действительная блокировка со значением `VERDICT_PASS`: она отключает соответствующий профиль только в выбранном scope. Например, `mark:101` со strategy `0` не отключает тот же профиль для `mark:102` и не переписывает `default`.

Если scoped lock отсутствует, выбирается `default`. Если scoped lock конфликтный, он не выбирается: реализация должна диагностировать конфликт и продолжить с `default`; при конфликте самого `default` — перейти к automatic/no-lock. «Последняя строка победила», порядок обхода Lua-таблицы и случайный выбор запрещены.

## Формат lock TSV

Разделитель — один tab. Пустые строки и строки, начинающиеся с `#`, игнорируются. Число стратегии — десятичное целое; `0` разрешён. Канонический scoped формат имеет четыре поля:

```text
scope    profile    proto    strategy
```

В примерах ниже между полями находятся реальные tab-разделители:

```text
# legacy: implicit scope=default, explicit proto
3	tls	5

# legacy: implicit scope=default and proto=tls
3	5

# scoped: one client can use another TLS strategy
mark:101	3	tls	7
mark:102	3	tls	3

# scoped strategy=0 means pass/disable only for mark:101
mark:101	4	udp	0
```

Для чтения и записи действуют правила:

- две legacy-формы эквивалентны `default\tprofile\ttls\tstrategy` и сохраняются ради обратной совместимости;
- legacy-запись не конфликтует с явным `default`, если после нормализации это одна и та же стратегия;
- новые записи всегда должны использовать четыре поля и канонический scope;
- profile/proto валидируются существующими правилами профилей; неизвестные или повреждённые поля не должны превращаться в случайный lock;
- shell writer обязан писать атомарно через временный файл и `mv`, не допуская tab/newline injection;
- старые `orch_locked_get/set/clear` остаются обёртками для `scope=default`.

### Конфликты

Ключ lock — `(scope, profile, proto)`. Повтор одной и той же записи с одинаковой strategy можно дедуплицировать. Две записи с одинаковым ключом и разными strategy — конфликт, даже если они находятся в разных lock-файлах (`locked.tsv` и `locked.manual.tsv`):

```text
mark:101	3	tls	7
mark:101	3	tls	9   # конфликт, не выбирать 7 или 9 по порядку строк
```

Конфликт должен иметь детерминированный результат: scoped layer пропускается с диагностикой и выполняется fallback на следующий приоритет. Если конфликтуют все доступные default-записи, применяется automatic/no-lock. Источник записи может быть показан в диагностике, но сам по себе порядок файлов не является приоритетом. Умышленное ручное переопределение в будущем должно получить отдельное явно описанное правило приоритета, а не зависеть от порядка чтения.

## Legacy и scoped lookup: пример

Пусть в файле есть:

```text
# старый глобальный lock
3	tls	5

# lock только для двух firewall scopes
mark:101	3	tls	7
mark:102	3	tls	3
```

Тогда для одного и того же hostname/profile `3`:

| Runtime scope | Effective strategy |
|---|---:|
| `mark:101` | 7 |
| `mark:102` | 3 |
| `mark:103` | 5, через `default` |
| отсутствующий/невалидный mark | 5, через `default` |
| client scopes выключены | 5, через `default` |

Если `mark:101` имеет scoped `strategy=0`, для него результат — pass; глобальная strategy 5 не подменяет явное scoped disable. Если у `mark:101` две разные scoped strategies, результатом не может быть ни 7, ни 9: конфликт диагностируется, после чего применяется global strategy 5.

## Post-NAT и privacy ограничения

### Что гарантируется

- В обычном post-NAT режиме Lua видит маркер flow, а не LAN source IP. Внешний WAN-адрес роутера не является идентификатором клиента.
- Устройство связывается с `mark:N` на firewall-слое до NAT; для стабильности IPv4 mapping обычно нужен DHCP reservation или другой контролируемый классификатор.
- Randomized MAC не используется как Lua identity. Если нужен стабильный scope, он должен быть обеспечен mapping/group policy, а не попыткой читать L2-данные после NAT.
- IPv6 без NAT не превращается автоматически в client identity: адрес может измениться, быть приватным или не быть доступным на нужном hook. Для MVP нужен тот же явно выставленный client mark.
- Включение pre-NAT не является автоматическим решением. Оно может менять forwarded-traffic поведение и должно проверяться отдельно для каждого firewall/backend.

### Что не обещается

- Переживание смены DHCP-адреса без reservation или обновления внешнего mapping.
- Универсальная совместимость одного набора правил с iptables, nftables, Keenetic и Merlin без стендовой проверки.
- Восстановление LAN-клиента по одному post-NAT пакету.
- Сохранение scope при flow offload, если конкретный backend обходит классификационный hook.

### Логи и данные

Обычная диагностика может показывать только обезличенные значения `scope`, profile, proto, strategy, направление и причину fallback. Полные пользовательские IP, MAC и payload в обычный log не записываются. Расширенный debug — только opt-in и только для стендовой проверки.

Минимальные причины fallback, которые должны быть различимы в диагностике:

- `disabled` — scopes выключены;
- `missing-mark` — mark отсутствует;
- `invalid-mark` — mark не прошёл нормализацию;
- `mask-conflict` — маска пересекается со служебным mark;
- `scope-conflict` — одинаково специфичные lock-записи конфликтуют;
- `no-scoped-lock` — client scope корректен, но scoped lock отсутствует, поэтому использован `default`.

### Runtime diagnostics

`client_scope_diagnostics()` в `orchestra/locked.lua` и поле `client_scope` в
WebUI `status.cgi`/`scopes.cgi` дают только безопасный агрегат:

- `mode`: `disabled` или `mark`;
- `mask`, `shift`, `max_scope`;
- `scoped_lock_count` и `conflicts`;
- `last_seen_scope` и `fallback_reason`.

Lua обновляет `last_seen_scope` при обработке flow и хранит только scope в
`track.lua_state`. Shell/WebUI не притворяются runtime-событиями: пока нет
канала чтения Lua-состояния, `last_seen_scope` там имеет значение
`unavailable`. Обычный UI/API не возвращает payload, source IP, MAC или список
клиентов; маска показывается как конфигурационное значение. Поэтому
`mask-conflict`, `missing-mask`, `invalid-mask`, `missing-mark`,
`invalid-mark`, `scope-conflict` и `no-scoped-lock` можно отличить без утечки
сетевых данных. Полные данные допустимы только в явно включённом стендовом
debug-режиме и не входят в этот контракт.

## Проверки перед реализацией

Контракт считается зафиксированным, если последующие реализации и тесты подтверждают:

1. legacy 2-/3-полевые строки читаются как `scope=default`;
2. четыре поля читаются как scoped lock;
3. `mark:N` имеет приоритет над `default`;
4. `strategy=0` действует только в своём scope;
5. отсутствующий, нулевой, неизвестный или переполненный mark даёт `default`;
6. `DESYNC_MARK` и `DESYNC_MARK_POSTNAT` не используются как client scope;
7. конфликт одинакового `(scope, profile, proto)` не разрешается порядком строк;
8. scope сохраняется для обратного направления flow;
9. hostname grouping остаётся независимым от scope;
10. старый конфиг без `CLIENT_SCOPE_*` работает без изменений;
11. firewall apply/cleanup не удаляет чужие правила и выполняется идемпотентно;
12. privacy-диагностика не содержит payload и лишние пользовательские адреса.

До прохождения Lua/shell smoke-тестов и проверки хотя бы на предусмотренных iptables и nftables стендах значение остаётся `CLIENT_SCOPE_ENABLE=0`.

## Release-gate: фактические результаты и ограничения

На момент выпуска проверены локальные изолированные сценарии:

- `tests/client_scope_config_smoke.sh` — OK: значения по умолчанию, перенос параметров и конфликт служебной маски.
- `tests/client_scope_shell_smoke.sh` — OK: legacy/scoped TSV, `strategy=0`, очистка и валидация.
- `tests/client_scope_firewall_smoke.sh` — OK: идемпотентный apply/cleanup для mock iptables и mock nft, IPv4/IPv6, сохранение чужих правил и безопасный no-op при отключении.
- `tests/client_scope_webui_smoke.sh` — OK: CGI/fake-router diagnostics, effective source и privacy-safe поля.
- `tests/profile_lock_smoke.sh`, `tests/webui_smoke.sh`, `tests/uninstall_smoke.sh`, `tests/provider_asn_smoke.sh`, `tests/telemetry_smoke.sh`, `tests/ui_validation_smoke.sh` — OK.

Эти тесты не применяют реальные firewall-правила: iptables/nft вызываются только через локальные mock-команды и временные файлы. Они не заменяют проверку на физических роутерах и не доказывают работу pre-NAT/NAT, connmark, обратного направления, `desync.fwmark`, Lua выбора стратегии или flow-offload.

Оставшиеся ограничения release gate:

- Полный тест `tests/tls_check_smoke.sh` в текущем окружении не завершился за 300 секунд; результат не считается успешным.
- `tests/backup_smart_smoke.sh` не запустился, потому что окружение не разрешает создавать временные файлы в жёстко заданном `/opt/zator/files/fake`; результат не считается успешным.
- `tests/webui_settings_smoke.sh` остановился на проверке `node --check`: Windows/MSYS передал нативному Node путь `/c/...` как `C:\c\...`; это ограничение запуска теста, а не доказательство корректности проверки.
- Реальный стенд доступен только для OpenWRT `192.168.10.1`; стенды OpenWRT iptables, OpenWRT nftables IPv4/IPv6, Merlin и Keenetic/Entware отсутствуют. Поэтому hardware/NAT gate остаётся невыполненным.

Внешний launcher `AloofLibra/z4r:z2r` проверен по ветке `z2r`: он загружает `z2r.sh` и zator-библиотеки в `/opt/zator`, а `z2r.sh` сам загружает firewall helpers. Изменение launcher для текущего контракта не требуется. Это не является стендовой проверкой runtime.

До закрытия перечисленных ограничений client scopes не включаются автоматически: `CLIENT_SCOPE_ENABLE=0` остаётся обязательным default и release-safe fallback — `default`/legacy global behavior.
