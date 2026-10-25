# ADR: Desktop Probe TCP MVP

Дата: **24.10.2026**. Состояние: программная реализация, первичный OpenWrt PoC. Пользователь отложил физические Keenetic-тесты и предоставил OpenWrt для первых испытаний; это изменение порядка проверки, не подтверждение Keenetic-совместимости.

## Решения

1. Electron + TypeScript + `WebContentsView`; у сайта нет preload, Node, privileged IPC, popup/download/permission-доступа. Контрольное окно локальное, с CSP и проверкой sender/frame.
2. OpenSSH с обязательным host-key checking. CLI JSON передаётся через stdin; удалённые команды фиксированы. SOCKS router ingress и PC forwarding слушают loopback. HTTP API в LAN/WAN не добавляется.
3. Небольшой Go agent и независимый SOCKS TCP CONNECT, Go standard library без внешних модулей. SOCKS поддерживает только публичный IPv4 TCP/443, исключает локальные адреса самого роутера, UDP ASSOCIATE и IPv6; максимум 32 соединения и 20 новых подключений/с.
4. Приватная копия deployed `locked.lua` и override TSV, реальный argv nfqws2, один separator `--new`, capability-detected `--autoexclude=0`. Номера стратегий читаются из живого config/template; никаких eval/source shell-config.
5. Отдельные UID/GID для proxy и nfqws2. Метка сохраняется в conntrack; test flow обходит production queue в обе стороны. Native nft добавляет post-NAT mark для raw fake. Нет fallback на production.
6. Статический транспорт устанавливается явно. Start/switch/stop не вызывают firewall mutations. Keenetic hook — существующий `000-zapret2.sh`; OpenWrt backend использует native `inet zapret2`, поскольку отдельная nft base chain с ACCEPT не исключает следующие base chains.
7. Потеря правил, изменение конфигов/маршрутов или event generations делает попытку недостоверной. Linux netlink monitors учитывают маршрутные и nft-события, в том числе изменения, после которых snapshot вернулся к прежнему виду. Для legacy iptables generation обновляется hook/reconcile.
8. Подтверждение результата связывает hostname SOCKS, исходящий tuple, conntrack mark, владельца очереди и запись фактического Lua invocation. В приватную Lua-копию добавлена только запись tuple/strategy; алгоритм стратегии не меняется. HTTP 200 и счётчик отдельно недостаточны.
9. Переключение перезапускает только тестовые процессы и сбрасывает browser context: не зависит от Lua host-record cache и не оставляет старые sockets под новым номером стратегии. Lease и Linux guardian/subreaper закрывают lifecycle после отказа контроллера; один PDEATHSIG недостаточен после native setuid nfqws2.
10. Уточнение пользователя 25.10.2026: YouTube/GV проверяются связанной парой с независимыми индексами. Один приватный nfqws2 содержит GV profile с `googlevideo.com` перед YT fallback; private locks и Lua evidence различают профили 1/2. Неудачная YT не расходует номер GV. После исчерпания YT оставшиеся GV проверяются с известной рабочей страницей; при её отсутствии остаются непроверенными. Страница и видео получают отдельные результаты, а ошибки сторонних ресурсов не переносятся между стадиями.
11. При TRANSPORT_CHANGED до начала прогона приложение вызывает отдельный prepare-transport и повторяет capabilities. Команда требует отсутствия активной сессии и держит manager lock вместе с transport lock, поэтому не может переписать правила между проверкой idle и чужим start. Исправный транспорт не переписывается. Подготовка не восстанавливает инвалидированную попытку во время измерения и не запускает рабочий zapret2.

## Reuse / measurements

| Кандидат | Наблюдение на ARM64 OpenWrt | Решение |
|---|---|---|
| Installed sing-box-lx 1.14.2-lx.12, revision `f7ab0516c0d291deffff1e0e2b103b08b3a1d969` | Отдельный config прошёл check; 3 HTTPS CONNECT; RSS **67188 kB**, start **4342 ms**, CPU ticks за запросы 425→427 | Не делать обязательным runtime, особенно для 128 МБ |
| Compact Go SOCKS | Независимый UID, loopback, IPv4/443; RSS около **4588 kB** в первичном измерении; DIRECT и strategy 1 проверены через SSH и Chromium | Выбран для MVP |
| mawg | Изучены detection/platform/probe/client patterns, runtime не изменялся | Ни SDK, ни обязательный daemon |
| MagiTrickle | Изучены DNS/policy роль и API-контракт; на устройстве есть VPN policies | Только диагностика kernel routing, никаких записей в группы |

Это замеры одного устройства 512 МБ. Они не заменяют RSS/CPU/OOM и ABI-тесты 128-МБ MIPS/Keenetic.

## Зафиксированные исходники аудита

| Проект | Commit / прочитанные части |
|---|---|
| Zator checkout | `386959d3cce9568f191066289e339e6ad52c22fe` до изменений; ветка реализации `codex/desktop-probe` |
| [mawg](https://github.com/MarkinAlexander/mawg/tree/c27bb6d78237f55f5c765a31e25974d7e7818505) | `c27bb6d78237f55f5c765a31e25974d7e7818505`: README, LICENSE, `internal/rotator/probe_linux.go`, `internal/magitrickle/client.go`, `internal/singbox/engine.go`, Keenetic/OpenWrt platform backends |
| [MagiTrickle](https://github.com/MarkinAlexander/magitrickle/tree/199a0ae027b231453af4a97d6fcac200e11e8c0b) | `199a0ae027b231453af4a97d6fcac200e11e8c0b`: README, LICENSE, backend tree/API layout; mawg client подтверждает read/write группы |
| [sing-box-lx](https://github.com/MarkinAlexander/sing-box-lx/tree/3261f3ccd5487d6284328b49827b385e918d4686) | `3261f3ccd5487d6284328b49827b385e918d4686`: README, LICENSE, `docs-lx/lxd-daemon.md`, `protocol/socks/inbound.go`, `option/simple.go` |

В LICENSE mawg/MagiTrickle — текст GPLv3; sing-box-lx — GPLv3-or-later с дополнительным ограничением именования. Код этих проектов не копировался. Audited source SHA sing-box и revision установленного бинарника отмечены отдельно и не объявляются одним build.

## Совместимость доставки

`ZAPRET2_ROOT` не заполняется новыми runtime-данными. Компонент ставится отдельно в `/opt/zator/bin`, настройки — `/opt/zator/desktop-probe.json`, временная сессия — `/tmp/zator-desktop-probe`. Canonical `/opt` layout — текущий install-контракт. Обновления zapret2 не удаляют компонент. `config.default` и старые Supersweep-модули не изменены.

Имена файлов внешнего bootstrap не меняются. Для автоматической загрузки необязательных router-бинарников самим `AloofLibra/z4r:z2r` потребовалось бы отдельное изменение внешнего репозитория; текущая установка компонента явная. Core/offline payload содержит актуальный `Entware/000-zapret2.sh`.

## Ограничения метода

Транспорт **router_socks_tcp** создаёт sockets из роутера. Его TCP fingerprint, NAT и policy path не равны LAN forwarding. Нет UDP/QUIC/WebRTC/IPv6 и гарантии для голоса Discord. Generic DOM selector — объявленное условие, не универсальная проверка сервиса. Авторизация/капча и недоказанная media/WS-функция остаются UNKNOWN. Отчёт не применяет стратегии в production и не объявляет самую быструю по одному прогону.
