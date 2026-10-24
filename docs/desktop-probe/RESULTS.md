# Desktop Probe: результаты реализации

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

Физический Keenetic/Entware, 128 МБ/OOM, MIPS ABI/старое ядро, полный firewall/WAN reload и reboot остаются непроверенными. OpenWrt firewall include поставляется отдельно и автоматически в UCI не регистрируется. После пересоздания таблицы нужен hook либо явный reconcile; потеря транспорта отклоняет попытку.

Не выполнены живая авторизованная проверка YouTube/Discord, вся матрица стратегий, Windows packet capture для DNS/UDP/WebRTC leakage и подпись Windows executable. UI DOM/IPC проверены; пиксельная QA недоступна из-за `UnknownVizError` compositor capture в текущем окружении. SOCKS поддерживает только IPv4 TCP/443; результат router sockets не доказывает эквивалентность LAN forwarding. Автоматическое применение в production не входит в MVP.
