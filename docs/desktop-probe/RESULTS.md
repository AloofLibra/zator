# Desktop Probe: результаты реализации

## TRANSPORT_CHANGED после обновления агента — 25.10.2026

Причина аппаратного отказа: при установке исправленного бинарника из рабочей /tmp-папки установщик повторно скопировал старый mangle-only hook. На nat-событии production правила снова вставали перед private hooks; отказ изоляции был корректным. На устройство заново установлен целый актуальный архив, SHA256 stage installer/hook и установленных binary/hook сверены с локальными файлами. Дополнительно здоровый reconcile больше не переписывает transport-generation: проверка целых правил является no-op; восстановление действительно повреждённых правил по-прежнему меняет поколение и не подтверждает старую попытку.

Аппаратная регрессия расширена: два здоровых reconcile в активной сессии не меняют поколение; после удаления собственного OUTPUT правила установленный nat-hook восстанавливает isolation.available; DIRECT/strategy 1 подтверждаются по queue/tuple/strategy/route, production PID/config/locks и чужие firewall/policy rules сохранены. Linux tests с -race и vet PASS; пять архитектур собраны.

Дополнительный живой прогон: восемь переключений YT-n/GV-n (1…8), HTTPS-пробы через private SOCKS и вызовы установленного nat-hook между status/telemetry. Session/strategy/route/firewall/transport generations совпали до/после каждой пробы; тест завершился штатным stop. Это проверка устойчивости транспорта, не открытия YouTube или воспроизведения видео; полного Chromium sweep в этом тесте нет.

## Ложная смена поколения на Keenetic — 25.10.2026

Воспроизведён SESSION_OR_GENERATION_CHANGED: при стабильном snapshot маршрутов и transport fingerprint route_generation вырос с 4 до 269. Трассировка показала RTM_NEWLINK от Wi-Fi ra0/rai0: нулевой change mask, только IFLA_IFNAME и IFLA_WIRELESS. Это уведомления драйвера, а не смена маршрута. Монитор исключает только такой набор; изменения флагов, MTU, operstate, адресов, маршрутов и policy rules продолжают повышать поколение, malformed события делают монитор unhealthy.

Исправление установлено на физический Keenetic. Повторная 40-секундная парная сессия с HTTPS-трафиком: сотни Wi-Fi notifications, route_generation 0/0/0, transport generation неизменен, snapshot маршрутов до/после совпадает. Unit test прошёл на ARM64 роутере; Linux Go tests с -race и vet PASS, все пять Linux бинарников собраны. Production PID/config/locks сохранены. Полный sweep и reboot для этой правки не выполнялись.

Chromium через SSH-туннель: DIRECT/strategy 1 получили HTTP 200, fresh connection и verified tuple/strategy/route, route/firewall generations 0→0; INVALID отсутствует. Общий generic harness вернул FAIL из-за функционального DOM-условия (DECLARED_SCENARIO_FAILED_TWICE), поэтому это подтверждение исправления транспорта, а не успешности сценария страницы.

## Keenetic и MagiTrickle — 25.10.2026

Проверен Netcraze Ultra NC-1812, KeeneticOS 5.2 Beta 1, Linux 4.9, Entware ARM64, WAN ppp0, установленный MagiTrickle. Прежняя побитовая классификация пересекалась с его метками; теперь iptables использует точный tag 0x04000000/0x0f000000. Полные маски чужих MARK/CONNMARK разрешены только при отсутствии конфликта с tag; частичные опасные записи и перехватывающие policy rules отклоняются. Неподдерживаемый BusyBox marked route lookup заменяется подтверждённым NFQUEUE egress для того же tuple/strategy/mark.

PASS: установка без ручного JSON (backend из FWTYPE, сохранение настроек при обновлении); отдельный поздний NDM hook; восстановление после удаления собственного OUTPUT hook на обоих событиях mangle/nat (штатный production hook перестраивает firewall на обоих); обычный HTTPS и TCP с SO_MARK MagiTrickle не увеличивают тестовую очередь; DIRECT и strategy 1 HTTPS 200 с ростом своей очереди и verified connection/strategy/route. Config, locked.tsv, production PID/queue и чужие firewall/policy rules сохранены. Парный YT-1/GV-2 тест подтверждает обе стратегии независимо; HTTP Googlevideo завершился таймаутом, воспроизведение этим тестом не проверяется.

Go tests/vet и сборка пяти Linux архитектур PASS; shell quick 8/8 и desktop_probe_smoke PASS. Fixtures проверяют iptables с MagiTrickle и без него, отклонение чужих совпадений/опасных масок/маршрутов и отсутствие доказательства при неполных данных. MagiTrickle на физическом устройстве не отключался. Полный Chromium sweep, reboot, полный NDM/WAN reload и 128 МБ/OOM для этой версии не проверены. Изменения идут после опубликованного beta 1.

Дата: 24.10.2026. Реализован TCP MVP в `desktop-probe/`: Windows Electron UI, SSH adapter, изолированные Go agent/SOCKS/nfqws2, native nft и legacy iptables transport, отчёты и lifecycle. Инструкция: [README](../../desktop-probe/README.md); решения и аудит зависимостей: [ADR](ADR.md); ресурсы и ограничения: [compatibility](compatibility.md).

Пользователь перенёс физические Keenetic-тесты до получения устройства и предоставил OpenWrt 192.168.10.1 для первичных испытаний. Это позволяет проверить технический контур на OpenWrt, но не закрывает аппаратные критерии Keenetic и 128 МБ.

## Статус этапов плана

| Этап | Результат |
|---|---|
| 0: аудит и выбор SOCKS | Изучены закреплённые исходники Zator, mawg, MagiTrickle, sing-box-lx; отдельный sing-box измерен на устройстве. Выбран stdlib Go SOCKS без внешних runtime-зависимостей |
| 1–2: изоляция и CLI PoC | Подтверждены на ARM64 OpenWrt; Keenetic backend проверен mocks, физический G0/G1 остаётся открытым |
| 3: Router Agent | Сессии с owner token, отдельные nfqws2/SOCKS, heartbeat/lease, guardian и recover |
| 4: SSH и браузер | Реализованы строгая проверка SSH host key, loopback forwarding, sandbox WebContentsView, fresh partitions и CDP metadata |
| 5: runner и отчёты | DIRECT, стратегии, повторный DIRECT для длинных списков, паузы, bounded retry, cancel, partial JSON/Markdown report |
| 6: сценарии и verdict | Реализованы generic DOM condition, YouTube playback/data и Discord DOM/gateway frames; HTTP 200 отдельно не даёт OK. Живой тест выполнен только для generic сценария |
| 7: доставка и lifecycle | Пять статических Linux-сборок, Windows portable, установщик/rollback, backup/uninstall и NDM hook; реальные fault tests OpenWrt |
| 8: UDP/TUN | Отложен согласно границе TCP MVP |

## Проверки

- `go test ./...`, `go vet ./...`, Linux `go test -race ./...`: PASS. Проверяются parser, профили, SOCKS restrictions, evidence и iptables fault paths.
- `npm test`: 5/5 PASS; Electron UI smoke: PASS, включая renderer и IPC. Portable Windows сборка создана.
- Живой Electron integration через заполнение формы: DIRECT и strategy 1 на `https://example.org/`, условие `body`: оба OK. Проверены SSH/SOCKS, CDP и привязка hostname к router flow/evidence; это не тест YouTube/Discord.
- Quick shell suite: 8/8 PASS; WebUI suite: 5/5 PASS. Shell regressions, transport и background Supersweep пройдены; backup/background проверки выполнены в изолированном Linux окружении без доступа к существующему `/opt`.
- Новые desktop hook smoke и расширенный uninstall smoke: PASS. Проверки deploy tar включают core/offline hook payload.
- Cross-build: linux arm64, armv7, mipsle/mips softfloat, amd64. Выполнение на MIPS/ARMv7 не проверено.

## Аппаратный PoC

Устройство: Cudy WR3000P v1, OpenWrt 25.12.4, kernel 6.12.87, ARM64, около 512 МБ RAM. Использовались отдельные queue 65534, proxy UID 65531, nfqws2 UID 65532, loopback port 41081 и mark 0x04000000 после проверки конфликтов. Рабочая queue 300 и reserved Supersweep ресурсы не занимались.

- DIRECT и strategy 1: HTTPS 200, собственные queue counters, conntrack mark, запись фактического Lua invocation и WAN `pppoe-wan` подтверждены вместе. Pcap strategy 1 показывает raw fake с sequence offset −3000. Последний CLI lifecycle прогон: PASS, 6.38 s.
- Обычный root HTTPS socket не увеличивал test queue. Start/switch/stop не меняли firewall. Рабочие config/lock hashes и consumer queue 300 сохранились.
- Удаление собственного queue rule делает попытку INVALID. Десять reconcile не создают дубликатов; старое поколение отклоняется.
- Чужой owner и отсутствующий номер стратегии отклоняются. TERM тестового nfqws2 обнаруживается. SIGKILL контроллера закрывает тестовых детей через guardian/subreaper; recover позволяет новую сессию. Истечение 90-секундного lease закрывает очередь и listener. Fault прогон: PASS, 94.54 s.
- Отдельный sing-box: 3 HTTPS CONNECT, RSS 67188 kB, startup 4342 ms; компактный Go SOCKS: около 4588 kB RSS. Это измерения одного ARM64 устройства, не гарантия для 128 МБ.

## Незакрытые аппаратные критерии

Обновление 25.10.2026: добавлены «Все стратегии» для выбранного профиля и полный последовательный проход по профилям 1/2/4 и всем заданным RKN-сайтам (профиль 3), прогресс и покрытие по стратегиям. Unit tests — 8/8, Electron smoke проверяет оба режима. Повторный живой запуск остановлен с INVALID / ROUTE_MISMATCH после восстановления собственных transport rules: текущий policy path не соответствует настроенному WAN. Полный проход всех стратегий и сервисов на устройстве этим обновлением не подтверждён; рабочие VPN/policy settings не менялись.

Уточнение 25.10.2026: причиной ROUTE_MISMATCH оказался устаревший `wan: pppoe-wan` в настройках компонента. OpenWrt теперь использует DHCP и L3-интерфейс `wan`; `pppoe-wan` отсутствует. Исправлен только `/opt/zator/desktop-probe.json` с резервной копией, выполнен reconcile собственных правил. Повторный Electron browser integration: DIRECT и strategy 1 — оба OK. VPN/policy routing не менялись; полный суперсвип этим коротким прогоном не проверялся.

Следующее исправление 25.10.2026: ручная настройка WAN удалена из агента и примера JSON, старое поле игнорируется. Выход определяется по активным IPv4 default routes с минимальной метрикой, включая равнозначные и multipath маршруты. Unit tests покрывают DHCP, PPPoE, static/VLAN, USB, failover, ECMP, отсутствие маршрута и совместимость старого JSON. На OpenWrt установлен новый агент; аппаратный lifecycle DIRECT/strategy 1 с pcap и автоматическим `WAN=wan` прошёл за 7.02 s, production hashes и queue consumer сохранились. Физическое переключение типа WAN не выполнялось.

Таймауты 25.10.2026: default лимит браузерной пробы снижен с 20 до 10 секунд и теперь охватывает navigation, DOM и media вместе. DOM-ready разрешает начать функциональную проверку раньше полной загрузки ресурсов. Таймаут и явный отказ загрузки не повторяются; неоднозначное DOM-условие сохраняет один retry. Паузы 15/30 секунд оставлены и показываются явно. Unit tests — 10/10 PASS (deadline, cancel, отсутствие retry после timeout и сохранение проверки изоляции), Electron smoke PASS, живой browser DIRECT/strategy 1 — оба OK. Полный проход нерабочих стратегий на устройстве не выполнялся. Для медленного рабочего сайта лимит может потребоваться увеличить.

YouTube 25.10.2026: воспроизведена остановка на strategy 1 с FLOW_OR_STRATEGY_NOT_PROVEN. Причины: один незавершённый/закрытый auxiliary flow сбрасывал aggregate proof; CDP HTTP/2 reuse внутри текущей пробы ошибочно считался старым соединением. Агент теперь возвращает `verified_hosts` только для точных tuple с conntrack mark, WAN route и Lua invocation; клиент требует подтверждения документа и фактических media/gateway hosts. Неизвестные auxiliary flows не считаются подтверждёнными и не сбрасывают чужое доказательство; известный неверный mark по-прежнему даёт ошибку. Добавлены регрессии, Go tests/vet PASS, frontend 11/11 и Electron smoke PASS. Живой короткий YouTube-прогон: DIRECT — FAIL/ATTEMPT_TIMEOUT; strategy 1 — WARN/FUNCTION_PASSED_WITH_RESOURCE_ERRORS, functional=true, 2753689 media bytes, требуемый Googlevideo host присутствует в verified_hosts. Проход продолжился после DIRECT и не остановился с INVALID. Строгий generic integration harness вернул FAIL, поскольку ожидает два OK; результат YouTube не объявляется двумя OK. Полный суперсвип и Discord не проверялись.

Оценка открывшейся страницы 25.10.2026: таймаут функции после получения HTTP 2xx/3xx или загрузки DOM теперь даёт UNKNOWN/FUNCTIONAL_CHECK_TIMED_OUT вместо FAIL. Плеер опрашивается до конца лимита, допускается его позднее появление; успех требует 2 секунд наблюдаемого прогресса и Googlevideo data. В таблице отдельно показаны страница и функция. Frontend 12/12 и Electron smoke PASS. Повторный живой прогон: DIRECT FAIL/ATTEMPT_TIMEOUT, strategy 1 UNKNOWN/FUNCTIONAL_CHECK_TIMED_OUT; открытие не объявлено ни провалом стратегии, ни доказанным воспроизведением. Harness с требованием двух OK по-прежнему возвращает FAIL; полный суперсвип не проверялся.

Связанный проход YT/GV 25.10.2026: реализован алгоритм пользователя с независимыми индексами, удержанием непроверенной GV при неудачной странице и добором через успешную YT. Агент одновременно применяет два номера в отдельных nfqws2 profiles, private locks содержат обе строки, Lua evidence дополнен номером профиля. Frontend требует подтверждения правильной стратегии/профиля для документа и медиаданных. Если обращения к GV с подтверждённой стратегией не было, её номер не получает FAIL; после исчерпания опорных страниц он остаётся UNKNOWN/tested=false и исключается из покрытия. Одинаковый сценарий используется в одиночном запуске и суперсвипе. JSON/Markdown содержат пару, стадию и tested. DOM-инспекция переведена на CDP Runtime.evaluate, поскольку Electron executeJavaScript мог ждать зависшую полную загрузку страницы после DOM-ready.

Проверки связки: Go tests/vet PASS, frontend 16/16, Electron smoke PASS. Unit tests покрывают ровно пример YT-1/GV-1 → YT-2/GV-2 (страница FAIL) → YT-3/GV-2, остаток GV, отсутствие рабочего YT/плеера, замену неработающей опоры, правильность фильтров, отсутствие изменений production locks и отказ принять evidence другого профиля. Живой browser integration PASS: DIRECT-страница FAIL, DIRECT-видео не проверялось, YT-1 OK и GV-1 OK с настоящим воспроизведением. Дополнительный аппаратный TestHardwareYouTubePair PASS, 9.81 s: одновременно доказаны YT-1 и GV-2, production config/locks hash сохранены. GV-2 HTTP response истёк по таймауту — этот тест доказывает применение двух разных номеров, а не работоспособность GV-2. Агент ARM64 установлен на 192.168.10.1. Полный проход 44×44 и физический Keenetic не проверялись.

Восстановление транспорта 25.10.2026: по указанному пользователем адресу 192.168.1.37 строгая проверка существующего SSH host key прошла; на 192.168.10.1 host key не заменялся и проверка не отключалась. Подтверждено отсутствие собственных цепочек в пересозданной таблице zapret2. Добавлен отдельный prepare-transport перед новым сканированием, с отказом при активной сессии и блокировкой параллельного start. Приложение восстанавливает только TRANSPORT_CHANGED и повторно проверяет capabilities; конфликты и несовместимый конфиг не маскируются. Go tests/vet PASS, frontend 18/18, Electron smoke PASS. TestHardwarePrepareTransport PASS, 1.41 s: отказ активной сессии, восстановление удалённых собственных цепочек, идемпотентность исправного транспорта, сохранение config/lock hashes. Живой browser integration после адресного удаления собственного queue rule: автоматическая подготовка, затем DIRECT и strategy 1 — оба OK. Полный fw4 reload/reboot и физический Keenetic этим не проверялись.

FLOW_MARK_MISMATCH 25.10.2026: в сохранённых потоках пары YT-5/GV-2 обнаружен conntrack mark 0x44000000 вместо 0x04000000. OUTPUT распознавал только UID прокси; поздние пакеты без этой socket identity могли попадать в production NFQUEUE. Добавлено восстановление только test packet bit из test conntrack bit независимо от UID, без копирования остальных битов. Проверка production bit в evidence не ослаблена. Native nft теперь содержит 11 собственных правил, legacy iptables получил OUTPUT connmark fallback после UID hooks.

Регрессия TestHardwareOwnerlessPacket моделирует потерю packet mark/UID-привязки: собственное маркированное TCP-соединение root отправляет данные после SO_MARK=0. На старом агенте тест FAIL за 0.96 s с conntrack=0x44000000; на исправленном PASS за 0.96 s с conntrack=0x04000000. Go tests/vet PASS, пять Linux-сборок обновлены. Hardware lifecycle PASS за 6.57 s: DIRECT/strategy 1, pcap raw fake, обычный root трафик вне тестовой очереди, 10 reconcile без дубликатов и неизменные production config/locks/queue consumer. Реальный связанный browser-проход 1–5 завершился без INVALID: YT [OK, FAIL, FAIL, FAIL, OK], GV [OK, FAIL, OK, OK, OK]. GV-2 удерживалась при неудачных YT-2/3/4 и была оценена только с YT-5; оставшиеся GV-3/4/5 проверены с успешной YT-5. Агент и транспорт на 192.168.1.37 обновлены; frontend для этого исправления менять не требуется. Временные trace/fixture tables удалены. Полный набор стратегий и физический iptables/Keenetic не проверялись.

Неполный снимок 25.10.2026: фактический пользовательский отчёт остановился на YT-7/GV-3 с FLOW_OR_STRATEGY_NOT_PROVEN: queue delta=17, поколения не менялись, один proxy flow, но aggregate proof был unavailable. При последующей проверке существовали и точная Lua-запись 7/profile 1, и conntrack с test mark, и корректный WAN route; точный момент потери доказательства задним числом не установлен. Устранена ошибка классификации: неполное доказательство при работающем транспорте теперь UNKNOWN/FLOW_EVIDENCE_INCOMPLETE, без зачёта успеха и без остановки других стратегий. Явные ошибки mark/route/process/generation и отсутствие новых queue packets по-прежнему INVALID. Telemetry делает максимум три чтения с двумя паузами по 100 мс; диагностирует число observed/matched/invoked/routed flows и число чтений. Ошибки чтения conntrack/Lua больше не маскируются пустым snapshot.

Go tests/vet и пять Linux-сборок PASS; frontend 19/19, Electron smoke PASS. Тесты подтверждают ограниченные повторные чтения без выдумывания proof, отсутствие повторов при явной ошибке транспорта, UNKNOWN для недоказанной пробы и сохранение INVALID для реальных нарушений. Живой связанный проход 7–8 PASS: YT-7 FAIL по таймауту, YT-8 OK; GV-7 FAIL по таймауту с опорой YT-8, GV-8 OK. Все четыре номера проверены, INVALID отсутствовал. Агент обновлён на 192.168.1.37; новая клиентская обработка требует новой portable-сборки. Полный набор стратегий и физический Keenetic не проверялись.

DOCUMENT_FLOW_NOT_PROVEN 25.10.2026: в реальном отчёте YT-10/GV-5 документ и видео работали, но из 42 proxy flows в позднем conntrack snapshot совпали только 41; отсутствовал именно www.youtube.com. Lua adapter теперь сохраняет исходные NFQUEUE fwmark и ifout в той же строке точного tuple/strategy/profile. Для уже исчезнувшей conntrack-записи принимается только полный снимок с корректным test bit, без production bit и с фактическим egress из активных uplinks. Неправильная текущая conntrack-запись не заменяется исторической. Legacy строка без mark/egress, другой tuple/номер/профиль, неправильная метка или VPN egress не дают положительного доказательства. Счётчик packet_snapshot_flows показывает число таких восстановленных потоков. Неполное доказательство отдельных document/media hosts выровнено с общей политикой UNKNOWN: оно не даёт успеха и не прерывает остальные стратегии.

Проверки: Go tests/vet PASS, пять Linux-сборок; frontend 19/19 и Electron smoke PASS. Регрессии покрывают исчезнувшую основную conntrack-запись при живом auxiliary flow, независимый GV profile, неподходящую/неполную историю, неправильные mark и egress. Hardware lifecycle PASS, 6.59 s: реальные Lua mark/ifout подтвердили поток даже при намеренно пустом conntrack snapshot в проверке; production config/locks/queue consumer сохранились. Живой browser integration PASS: YT-10 и GV-10 получили OK, packet_snapshot_flows=1 и www.youtube.com присутствует в verified_hosts. Агент на 192.168.1.37 обновлён, клиент собран в release/document-proof. Полный набор стратегий и физический Keenetic не проверялись.

FRESH_CONNECTION_NOT_PROVEN 25.10.2026: реальный отчёт YT-5/GV-2 содержал ERR_SOCKS_CONNECTION_FAILED, отсутствие HTTP-ответа, ноль установленных proxy flows и queue delta=2. Установленного соединения не было, поэтому его свежесть нельзя было подтвердить; это не доказывало повторное использование старого соединения или поломку изоляции. Теперь при здоровом транспорте такое состояние — UNKNOWN/CONNECTION_NOT_ESTABLISHED; отсутствие новых packets и недоказанная свежесть также UNKNOWN без положительной оценки. Успех по-прежнему требует fresh connection и роста счётчика. Регрессия счётчика, мёртвый процесс/очередь, ошибки mark/route и смена поколения остаются INVALID. Неподтверждённая YT не оценивает GV.

Frontend 20/20 и Electron smoke PASS. Отдельный отрицательный browser-тест на 203.0.113.1 с лимитом 5 s прошёл DIRECT → strategy 5 → strategy 6: все UNKNOWN/CONNECTION_NOT_ESTABLISHED, ни одного INVALID/OK/WARN. Внешняя проверка CONNECT_FAILURE_SCAN=PASS подтверждает продолжение перебора и отсутствие ложных успехов; стандартный harness с требованием двух OK закономерно вернул FAIL для этого отрицательного сценария. Новая portable-сборка — release/connection-failure. Это клиентское исправление; агент не менялся. Полный набор стратегий и физический Keenetic не проверялись.

## Полный живой проход 25.10.2026

Electron UI integration на OpenWrt `192.168.1.37` завершился штатно: `FULLSCAN_INTEGRATION=PASS`, 258/258 строк, 248 проверок стратегий и 10 DIRECT. Все номера взяты из live capabilities: 44 YT, 44 GV, 28 Discord и по 44 на каждом из трёх RKN-сайтов. `missing=[]`, `untested=[]`, INVALID=0; отмены и перезапуска сканирования не было. Лимит браузерной попытки — 10 секунд, штатные паузы 15/30 секунд и межсайтовые паузы сохранены. Видео открывались без звука.

Итоги стратегий (DIRECT в таблицу не включён):

| Профиль / сайт | Проверено | OK | WARN | FAIL | UNKNOWN |
|---|---:|---:|---:|---:|---:|
| 1 / YouTube | 44 | 25 | 0 | 17 | 2 |
| 2 / Googlevideo | 44 | 37 | 0 | 7 | 0 |
| 4 / Discord | 28 | 0 | 0 | 2 | 26 |
| 3 / xhamster.com | 44 | 25 | 13 | 2 | 4 |
| 3 / anidub.com | 44 | 0 | 0 | 27 | 17 |
| 3 / amnezia.org | 44 | 13 | 7 | 22 | 2 |

Рабочая YT-44 использована для оставшихся GV-26–44 после окончания списка YT. Ни одна GV-стратегия не осталась непроверенной. Успешное завершение сканера не означает успех каждого сайта: Discord gateway не подтверждён, anidub не получил положительных результатов; TLS-проверка не отключалась. Для RKN проверялось DOM-условие `body`, не полная функциональность сервиса.

После завершения `session_active=false`, тестовые nfqws2, queue 65534 и listener 41081 отсутствуют. Production nfqws2 сохранил PID 3132 и queue 300; SHA256 config (`561b85e7…829cc`) и locked.tsv (`4bd7aa60…fb94`) совпадают с исходными. Во время прогона дополнительных исправлений транспорта не потребовалось.

Integration harness теперь проверяет весь ожидаемый охват, сохраняет промежуточный JSON и отдельную сводку, использует отдельный userData и не возвращает PASS после ошибки или неуспешной очистки. Frontend 21/21, Go tests/vet и smoke portable-сборки PASS. Сборка: `desktop-probe/app/release/full-scan/ZatorDesktopProbe-win32-x64/`. Локальные данные прогона: `desktop-probe/dist/fullscan-2026-10-25.json` и `.json.summary.json`; SHA256 JSON: `ee28c51cd500ab5bdcfe46f24353ae6fffc866fd16eb806fa2d43e61e5399df0`.

## Компактный интерфейс и ускорение 25.10.2026

После OK следующая межстратегийная пауза — 5 секунд; пара YT/GV ускоряется только при обоих OK, пока проверяются оба этапа. WARN/FAIL/UNKNOWN сохраняют прежние 15 секунд (RKN — 30). Межсайтовые паузы и задержка перед повтором неоднозначной пробы не изменены. Новый компактный итог показывает категории и постоянно видимые списки номеров отдельно для каждого профиля/сайта, без DIRECT и опорных YT; неподтверждённые и непроверенные стратегии не выдаются за успешные.

Настройки сворачиваются и блокируются при старте, освобождая место журналу. В журнале разделены сайт/стратегия, этап страницы/видео, причина результата и ручная оценка; строки общей YT/GV-пробы имеют одинаковый короткий attempt ID. Журнал следует за новыми строками, если пользователь не прокрутил его назад. Маленький предпросмотр раскрывается и сворачивается без пересоздания WebContents; Escape обрабатывается также внутри браузера. Размеры передаются только от доверенного UI через проверяемый IPC и ограничены клиентской областью окна. Фоновое замедление таймеров браузера выключено.

Проверки: frontend 23/23 PASS; Electron smoke PASS — сворачивание и блокировка настроек, все пять категорий сводки, маленький/раскрытый/восстановленный preview, окно 960×700, отклонение неверных координат, разблокировка после завершения. Живой OpenWrt browser integration PASS: YT-1/GV-1 и YT-5/GV-5 — все OK; тестовая трассировка подтвердила паузы 15000 мс после неуспешного DIRECT и 5000 мс после успешной пары. Native Escape и изменение размеров сохранили тот же WebContents без навигации при отдельной проверке перед загрузкой. Итоговый UI проверен по PNG. Данные: `desktop-probe/dist/compact-youtube-final.json`, `compact-ui-final.png`. Portable: `desktop-probe/app/release/compact-scan/ZatorDesktopProbe-win32-x64/`. Полный многочасовой проход с новыми паузами не повторялся; предыдущий полный проход описан выше.

Физический Keenetic/Entware, 128 МБ/OOM, MIPS ABI/старое ядро, полный firewall/WAN reload и reboot остаются непроверенными. OpenWrt firewall include поставляется отдельно и автоматически в UCI не регистрируется. После пересоздания таблицы нужен hook либо явный reconcile; потеря транспорта отклоняет попытку.

Не выполнены живая авторизованная проверка YouTube/Discord, Windows packet capture для DNS/UDP/WebRTC leakage и подпись Windows executable. UI DOM/IPC проверены; пиксельная QA недоступна из-за `UnknownVizError` compositor capture в текущем окружении. SOCKS поддерживает только IPv4 TCP/443; результат router sockets не доказывает эквивалентность LAN forwarding. Автоматическое применение в production не входит в MVP.

Уточнение интерфейса 25.10.2026: убрано сворачивание общей сводки и отдельных профилей, номера стратегий видны сразу. Electron smoke подтверждает все пять категорий без details в панели покрытия. Portable: desktop-probe/app/release/compact-summary/ZatorDesktopProbe-win32-x64/. Сетевой прогон для этой правки отображения не повторялся.

## Публичная страница Discord — 25.10.2026

Полное сканирование профиля 4 теперь использует официальную публичную страницу https://discord.com/download и DOM-условие `a[href*="/api/download"]`. Проверяется наличие ссылок, без перехода по ним и скачивания установщика. Это generic_page: открытие страницы не подтверждает работу клиента, gateway и голоса. Отдельный сценарий discord (DOM + WebSocket) сохранён с прежними строгими требованиями.

Первый живой тест стратегий 1/5 подтвердил HTTP 200, auth_required=false, functional=true и трафик discord.com, но дал WARN из-за внутреннего data:-ресурса. Ошибки data:/blob:/about: теперь сохраняются в requests, не понижая сетевой verdict; HTTP(S)/WS и неизвестные запросы учитываются как прежде. Повторный DISCORD_PUBLIC_PAGE=PASS: стратегии 1 и 5 — OK с подтверждёнными flow/strategy, DIRECT — FAIL/ATTEMPT_TIMEOUT. Общий generic harness вернул FAIL из-за требования двух OK; отдельная проверка ожидаемых результатов JSON прошла. Отчёт: desktop-probe/dist/discord-public-final.json.

Frontend 24/24, Electron smoke PASS. Smoke проверяет новые URL/selector; unit tests — схемы ресурсов, generic_page полного режима и сохранение отдельного discord-сценария. Production PID 3132/queue 300 сохранён, тестовая очередь очищена. Portable: desktop-probe/app/release/discord-public/ZatorDesktopProbe-win32-x64/. Полный перебор 28 стратегий не повторялся.

## Ложный AUTH_REQUIRED на anidub.com — 25.10.2026

В полном прогоне 16 из 17 UNKNOWN на anidub.com имели причину AUTH_REQUIRED при HTTP 200, выполненном DOM-условии и подтверждённом flow; ещё один был FUNCTIONAL_CHECK_TIMED_OUT. Повторный живой тест strategy 1 воспроизвёл AUTH_REQUIRED. Диагностика обнаружила одно поле авторизации, но ноль отображаемых полей, без признака входа/challenge в title: скрытая форма входа публичной страницы ошибочно считалась обязательной авторизацией. Ошибки дополнительных TLS-ресурсов не были причиной этих AUTH_REQUIRED.

Общий детектор теперь проверяет отображение через native checkVisibility (включая visibility/opacity предков) и ненулевой размер. Скрытые login/captcha widgets игнорируются; отображаемые поля и challenge/login title по-прежнему дают UNKNOWN. DOM-условия, TLS и доказательства маршрута/стратегии не ослаблены. Старые результаты автоматически не пересчитываются.

Frontend 23/23 PASS; Electron smoke authGate PASS на 11 DOM-сценариях: скрытые через предка, visibility и opacity поля, скрытая CAPTCHA, нулевой iframe, отображаемые поля/капча/iframe, заголовки challenge/login и обычная страница. Живой ANIDUB_AUTH_FIX=PASS: стратегии 1 и 31 получили OK с auth_required=false, HTTP 200, functional=true и verified_hosts с anidub.com; DIRECT остался FAIL/ATTEMPT_TIMEOUT. Стандартный generic integration harness вернул FAIL из-за своего требования двух OK, отдельная проверка ожидаемых результатов из JSON прошла. До/после: desktop-probe/dist/anidub-before.json и anidub-after.json. Production config/locks hashes и PID 3132/queue 300 сохранились; тестовая очередь очищена. Агент не менялся. Portable: desktop-probe/app/release/anidub-auth/ZatorDesktopProbe-win32-x64/. Полный набор стратегий повторно не запускался.


Подготовка desktop-probe - beta 1 (25.10.2026): CI собирает полный релиз Zator, Windows ZIP и отдельный опциональный router-agent tar. При локальной проверке CI-бинарника выявлена зависимость preview layout от requestAnimationFrame скрытого окна. Расчёт переведён на queueMicrotask с явным запуском при инициализации и обновлении состояния. Hidden-window smoke готового приложения теперь PASS; такой запуск добавлен в обязательные проверки релизной сборки. Первую сборку остановили до публикации, latest не изменён.
