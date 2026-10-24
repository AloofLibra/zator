# Матрица тестирования Zator Desktop Probe

**Версия:** draft v0.1. Файл предназначен для coding-агента и ручной приёмки. До Gate G1 критические пункты должны быть пройдены **на реальном Keenetic/Entware**, а не только на эмуляторах.

## 1. Правила исполнения

- На каждом запуске протоколировать: `build SHA`, модель/архитектуру Keenetic, KeeneticOS/Entware версии, `nfqws2` build, версию Zator, установлен ли `mawg`, MagiTrickle, `sing-box-lx`, режим SOCKS, активные VPN/policy.
- Для каждого теста записывать исходное состояние production `nfqws2` (PID, queue, config/locks hash и по возможности counters), policy rules и сетевые интерфейсы.
- Никогда не принимать HTTP 200, факт загрузки UI и даже счётчик queue как **единственное** доказательство выполнения конкретной стратегии. Критичны identity test flow + отдельная NFQUEUE + поколение стратегии + при возможности telemetry фактического Lua invocation.
- Различать `OK`, `FAIL`, `WARN`, `UNKNOWN`, `INVALID` — определения в `ARCHITECTURE_AND_PROTOCOL.md`.
- Тестирование на физическом роутере проводить с контролируемым клиентским потоком и правом безопасно остановить тестовые процессы. Не очищать production правила даже ради негативного теста.
- Автоматизированные mock/unit проверки не замещают проверку фактического order в iptables, conntrack и маршрута raw packets.
- Если тесты влияют на реальный пользовательский сервис — не продолжать; записать блокер, восстановить состояние, добиться независимости.

## 2. Gate G0: совместимость, reuse и безопасность ресурсов

| ID | Проверка | Доказательство PASS | Тип |
| --- | --- | --- | --- |
| G0-01 | Entware + SSH `-L` + procfs NFQUEUE + owner/connmark доступны | результаты capability probes и команды | Physical |
| G0-02 | Зафиксированы все конфликтующие queue/UID/marks | таблица ресурсов, отсутствие коллизий | Physical |
| G0-03 | `sing-box-lx` isolated SOCKS кандидат проверен | `sing-box check`, TCP CONNECT, loopback-only, отдельный UID | Physical |
| G0-04 | Компактный SOCKS fallback проверен/документирован | сравнение корректности, RSS, CPU и совместимости ABI | Physical |
| G0-05 | Рабочий `mawg` / sing-box не перезапускаются при start/stop теста | PID/конфиги без изменений | Physical |
| G0-06 | MagiTrickle и policy routing могут быть определены без записи в конфиг | read-only snapshot, перечень правил | Physical |
| G0-07 | Слабый роутер (ориентир 128 МБ) выдерживает выбранный runtime | замеры RAM/RSS/CPU при обычной нагрузке; нет OOM | Physical |
| G0-08 | Go/Entware/сторонние лицензии проверены на фиксированных SHA | ADR: версия, лицензия, allowed usage | Review |
| G0-09 | Если test WAN path нельзя подтвердить, испытания не продолжаются как «успешные» | переход в `ROUTE_MISMATCH`/`INVALID` | Physical |

## 3. Gate G1: packet path и строгая изоляция

| ID | Действие | Ожидаемый результат |
| --- | --- | --- |
| G1-01 | Из ПК через SSH-forward открыть HTTPS через test SOCKS | Socks TCP CONNECT, роутер создаёт upstream socket под `PROXY_UID` |
| G1-02 | Пройти DIRECT без DPI fake | Пакеты *тестового* flow видны в test queue, нет fake; baseline честно сопоставим |
| G1-03 | Переключить на заданную стратегию и создать **новое** соединение | Тот же flow path; зафиксирована новая generation, применена Lua стратегия |
| G1-04 | Параллельно открыть сайт из LAN, не через test SOCKS | В test queue нет пакетов LAN flow; production traffic не меняется |
| G1-05 | Послать test flow через proxy при живом production `nfqws2` | Test flow не попадает в production queue, fakes не вызывают recursive NFQUEUE |
| G1-06 | Обработать входящий SYN-ACK/TLS-reply | Reply принадлежит тому же test conntrack flow и test queue |
| G1-07 | Прервать test `nfqws2`, не трогая proxy | Только этот тест — INVALID; нет ложного `OK` из queue-bypass |
| G1-08 | Изменить firewall состоянием WAN/NDM в середине навигации | Старый attempt INVALID, восстановление правил идемпотентно; не FAIL стратегии |
| G1-09 | Вызвать Keenetic netfilter hook 10 раз | Нет дублей, сохранён порядок, production chains не flush |
| G1-10 | Запускать DIRECT/N стратегии подряд | **Ни одного** изменения iptables/nft от test start/set/stop |
| G1-11 | Принудительно убить test `nfqws2` и proxy | Production PID/rules/locks без изменений; test cleanup без чужих ресурсов |
| G1-12 | Оставить существующие production VPN/policy routing | Действительный egress через заявленный WAN; при VPN reroute INVALID |
| G1-13 | Создать известную коллизию queue/UID/mark | Явная ошибка до активации, никакого fallback на production |
| G1-14 | Проверить IPv6/AAAA при IPv4-only MVP | Не допускается тихая отправка IPv6 в обход тестового контура |

**Приёмочный артефакт G1:** pcap или эквивалентная запись по конкретной пробе, conntrack identifier, queue counter/delta, контроль production flow, поколение стратегии, фактический outgoing WAN. При невозможности связать пакет и стратегию — `UNKNOWN`/`INVALID`, не PASS.

## 4. Gate G2: CLI Agent, протокол и жизненный цикл

| ID | Сценарий | Ожидание |
| --- | --- | --- |
| G2-01 | `capabilities --json` до запуска | Версии, платформы, TCP-only, queue/UID-conflict, точные ограничения |
| G2-02 | `start`, DIRECT, `set-strategy`, `status`, `telemetry`, `stop` | Валидный JSON, согласованные ID/generation, независимость от GUI |
| G2-03 | Два одновременных `start` | Единственная session; понятная `SESSION_BUSY` или безопасный owner-idempotent ответ |
| G2-04 | `stop` два раза | Идемпотентность, нет опасного изменения production |
| G2-05 | Пропал SSH во время loading | Агент lease истекает, clean-up собственных процессов |
| G2-06 | Зафиксирован `SIGKILL` управляющего процесса | `recover` обнаруживает orphan и убирает только owned процессы |
| G2-07 | Некорректные profile/strategy/session ID | Валидируемая ошибка, ни shell injection, ни рабочих config changes |
| G2-08 | Нет SSH forwarding | `SSH_FORWARDING_UNAVAILABLE`, запуск не считается готовым |
| G2-09 | Конфигурация тестового nfqws с Lua ошибкой | Детект fault до OK; состояние ошибки изолировано |
| G2-10 | Произошёл reboot | Восстановление только постоянного firewall transport; тестовая сессия не возобновляется вслепую |

## 5. Gate G3: браузер, сетевой контекст и утечки

| ID | Проверка | Ожидание |
| --- | --- | --- |
| G3-01 | Chromium встроен в окно Electron | Открывает внешний HTTPS через SSH-forward → test SOCKS |
| G3-02 | Открыть 2 последовательные стратегии | Раздельные browser sessions; новые sockets/TLS handshake, нет connection reuse |
| G3-03 | Проверить redirects/CDN/HTTP2/WS | CDP показывает запросы и ошибки; статусы ресурсов не смешиваются |
| G3-04 | Проверить DNS путь и URL с hostname | DNS не уходит напрямую с ПК для тестового браузера; при утечке INVALID |
| G3-05 | Попытка QUIC/WebRTC/UDP в TCP MVP | Не исполняется как успешно протестированное UDP; виден `UNSUPPORTED_CAPABILITY` |
| G3-06 | Поддельный/битый TLS сертификат | Ошибка TLS видна; проверка сертификата **не отключена** |
| G3-07 | Сайт пытается получить filesystem/Node/Electron IPC | Привилегии недоступны, sandbox/permissions проверены |
| G3-08 | Нет proxy/SSH в середине загрузки | Отображение транспортной ошибки, не FAIL стратегии |
| G3-09 | Страница требует логин/капчу | Не записывать токены; функциональная часть `UNKNOWN` или manual |
| G3-10 | Загрузка нескольких десятков ресурсов | По каждому известны тип, домен, статус, критичность, timing |

## 6. Gates G4–G5: тестирование стратегии и функциональность

| ID | Проверка | Ожидание |
| --- | --- | --- |
| G4-01 | DIRECT и 2+ стратегии в одном прогоне | Все попытки используют один mode, свежие соединения, разные strategy generation |
| G4-02 | `page.goto()` вернул document 200, но не загрузился JS | Не `OK`; resource/functional failure/warn |
| G4-03 | Появился рекламный request 404 | Не FAIL всего сайта без обязательного сценария |
| G4-04 | Сайт недоступен из-за DNS / auth / captcha | Состояние диагностировано отдельно, а не автоматически FAIL DPI |
| G4-05 | YouTube открывает home, но видео стоит | Functional не `OK`; `video.currentTime`/сеть media учитываются |
| G4-06 | YouTube video и `*.googlevideo.com` | Доказана реально загруженная и воспроизведённая порция контента |
| G4-07 | Discord UI есть, но gateway WS не открылся | Не `OK`; WS status и ошибки видны |
| G4-08 | Стратегия флапает между повторными попытками | `WARN`, статистика стабильности, не «лучший вариант» с одной удачи |
| G4-09 | `NFQUEUE` counters выросли от постороннего flow | Без корреляции target flow результат `INVALID` |
| G4-10 | Заменить стратегию, пока старый браузер держит сокеты | Сначала закрытие контекста и подтверждение новой generation |
| G4-11 | Прервать прогон вручную | Сохраняются завершённые попытки, cleanup, нет авто-изменения рабочих locks |
| G4-12 | Экспорт JSON/Markdown | Нет cookie, auth headers, секретов/личных query, токенов VPN |

## 7. G5: coexistence с mawg / MagiTrickle / sing-box-lx

| ID | Условие | Ожидание |
| --- | --- | --- |
| CO-01 | mawg, MagiTrickle отсутствуют | Тестовый инструмент полностью работоспособен |
| CO-02 | mawg/MagiTrickle установлены, выключены | Ничего не запускается и не меняется без явного выбора |
| CO-03 | mawg активно использует WG/AWG/VLESS pool | Test flow не переходит в этот pool без явного перевода в INVALID |
| CO-04 | mawg переключает pool/выполняет fallback | Test session сохраняет заявленный путь или инвалидируется; production не затронут |
| CO-05 | MagiTrickle обновляет группы или firewall | Тест не пишет группы; обнаруживает route/rule changes, не выдает ложноположительный PASS |
| CO-06 | Рабочий sing-box-lx обслуживает трафик mawg | Отдельный test sing-box не использует чужой PID/конфиг/UID/порт |
| CO-07 | Смерть test sing-box-lx | mawg не перезапускается, не изменяется его health/rotation из-за test cleanup |
| CO-08 | На роутере ограниченная RAM | измеренная p95 RSS/CPU, отсутствие OOM, приемлемая деградация throughput production |
| CO-09 | Agent не видит mawg/MagiTrickle API | Продолжает независимую проверку маршрута без read-only интеграции |
| CO-10 | mawg DNS/route меняет egress на VPN, но HTTP 200 | `ROUTE_MISMATCH` / `INVALID`, никогда `OK` как DPI result |

## 8. G6: UDP/QUIC (после TCP MVP)

| ID | Проверка | Ожидание |
| --- | --- | --- |
| UDP-01 | Туннель от управляемого browser process | Не меняет системный default route и другие приложения Windows |
| UDP-02 | Создать QUIC Initial / HTTP3 | UDP/443 есть в test flow и test NFQUEUE, не проходит production |
| UDP-03 | Ответные UDP и raw fake | Правильная корреляция UDP state и routes, нет loop/production queue |
| UDP-04 | QUIC timeout → fallback на HTTP/2 | Отдельные статусы, не смешивать с успешностью QUIC стратегии |
| UDP-05 | Туннель упал в середине проверки | `INVALID`, маршруты Windows/router восстановлены, утечек нет |
| UDP-06 | Активна VPN-политика mawg/MagiTrickle | Тестовый путь не скрывает DPI за VPN, иначе `INVALID` |

## 9. Формат отчёта о тестах

После каждого Gate агент сохраняет Markdown со следующими данными:

```text
Gate:
Статус: PASS / PARTIAL / BLOCKED
Оборудование и прошивки:
Commit SHA: zator / mawg / magitrickle / sing-box-lx / desktop-probe
SOCKS runtime + версия:
Test UID / Nfqws UID / NFQUEUE / marks:
Тестовый egress (iface/IP), DNS, policy:
Запущенные тесты и результаты:
Фактические логи/pcap/conntrack доказательства:
Влияние на production (PID, locks, routes, uptime):
CPU/RAM observations:
Непроверенное и риски:
Решение о переходе к следующему Gate:
```

**Общее правило приёмки:** нельзя заменить физический тест заглушкой и отметить PASS. Если доказательств недостаточно — `PARTIAL` или `BLOCKED` с подробной причиной.
