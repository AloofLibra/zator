# Zator Desktop Probe 0.1

Windows-приложение с Chromium и отдельным IPv4 HTTPS/WSS-контуром на роутере. Использует существующие стратегии установленного Zator. Рабочие `config`, `locked.tsv`, очередь и процесс zapret2 не изменяются.

Первичные аппаратные проверки проведены на **OpenWrt 25.12.4 / Cudy WR3000P / ARM64**. Keenetic/Entware и 128 МБ RAM пока не подтверждены: по указанию пользователя эти испытания отложены до получения устройства. Статус этапов и ограничения — [RESULTS](../docs/desktop-probe/RESULTS.md), решения — [ADR](../docs/desktop-probe/ADR.md).

## Сборка на Windows

Нужны Node.js 22+ и Go 1.27.3. На роутере Go, Node.js и Python не нужны.

```powershell
./desktop-probe/scripts/build-router.ps1
cd desktop-probe/app
npm ci
npm test
npm run smoke
npm run pack
```

`app/release/ZatorDesktopProbe-win32-x64/ZatorDesktopProbe.exe` — запускаемая portable-сборка. `dist/zator-desktop-probe-linux-{arm64,arm,mipsle,mips,amd64}` — статические router-бинарники. MIPS собирается с softfloat, ARM — ARMv7. Проверка сборки не означает подтверждение конкретного ABI/ядра; физически проверен ARM64 OpenWrt.

## Подготовка роутера

1. Нужны работающий Zator, `nfqws2`, root SSH, разрешённый SSH forwarding и проверенный host key. Используются штатные ключи/SSH agent. Приложение не принимает и не сохраняет пароль.
2. Скопируйте `settings.example.json` и сверяйте **каждое** значение с UID/GID, NFQUEUE, firewall и policy routing своего роутера. Пример содержит ресурсы тестового OpenWrt и не является универсальным назначением.
3. Для native nft выберите `backend: "nft"`; требуется штатная таблица `inet zapret2` с `postnat_hook`/`prenat_hook`. Для Keenetic предусмотрен `backend: "iptables"`, но его аппаратные испытания ещё не выполнены. Pre-NAT и нестандартный desync/post-NAT mark отклоняются.
4. Скопируйте соответствующий бинарник, настройки и `install-router.sh` в одну временную папку. Затем **на роутере**:

```sh
sh install-router.sh install ./zator-desktop-probe-linux-arm64 ./settings.json
/opt/zator/bin/zator-desktop-probe capabilities --json
```

Установщик проверяет файл настроек до остановки прежнего тестового компонента, сохраняет предыдущие component-файлы и пытается восстановить их при неудачной установке. Рабочий zapret2 не перезапускается. При ошибке cleanup файлы сохраняются для повторной попытки.

На Keenetic восстановление подключено к существующему `Entware/000-zapret2.sh` после рабочего firewall/client scope/Supersweep, только для IPv4 `mangle`. Перед установкой компонента нужен Zator с этим обновлённым hook.

Для OpenWrt предоставлен `firewall-openwrt.sh`: его можно вызывать из firewall4 script include **после создания таблицы zapret2** (`type=script`, `fw4_compatible=1`). Автоматическая правка UCI и перезагрузка firewall установщиком не выполняются. В первичных испытаниях потеря собственных правил моделировалась адресно; полный reload/reboot OpenWrt не проверялся. Пока hook не настроен, после пересоздания таблицы потребуется явный `reconcile-transport`; приложение отклонит прежнюю попытку.

## Работа приложения

Укажите SSH-адрес, пользователя, ключ/agent, HTTPS URL и номера стратегий. DIRECT выполняется первым. В длинном списке повторяется контрольный DIRECT. Доступны только номера из живого профиля; автоматический выбор профиля читает установленные hostlists и не угадывает неизвестный домен по подстроке.

Каждая стратегия получает свежие browser partition, TCP/TLS-соединения и тестовые процессы. Пауза — 15 секунд, для RKN — 30 секунд; повтор неоднозначной функциональной проверки ограничен двумя попытками. Firewall при start/set-strategy/stop не меняется.

- **Страница:** без обязательного CSS selector результат `UNKNOWN`. Selector задаёт проверяемое DOM-условие, а не универсальное доказательство работоспособности сервиса.
- **YouTube:** нужна прямая ссылка на видео; проверяются прогресс `currentTime` и приход данных с Googlevideo. Проверка запускает видео без звука. Главная страница и неподтверждённое воспроизведение не получают `OK`.
- **Discord:** нужны DOM-условие и полученные WebSocket frames от `gateway.discord.gg`. Авторизация/капча дают `UNKNOWN`; голос/UDP не проверяются.
- **Ручной режим:** до пяти минут на осмотр; оценка хранится отдельно и не меняет автоматический verdict.

Потеря очереди/процесса/SSH, смена поколения firewall или маршрутов, отсутствие связи конкретного browser host → proxy tuple → conntrack → Lua invocation дают `INVALID`. Неожиданный переход на другой домен — `UNKNOWN`. Один HTTP 200 не даёт `OK`.

JSON/Markdown экспортируются кнопкой. URL очищаются до origin, заголовки/cookie/тела запросов не собираются. Последний частичный отчёт сохраняется локально в Electron `userData/last-report.json`; SSH-настройки и owner token в него не входят. Снимок страницы сохраняется только по кнопке.

## CLI/RPC

Команды управления принимают JSON через stdin и выдают JSON в stdout. Owner — 64 hex-символа, session ID — 32. `DIRECT` в реализованном draft API обозначается числом **0**.

```text
capabilities
resolve-profile       {command, hostname}
start                 {command, owner, profile}
set-strategy          {command, owner, session, strategy}
status / telemetry    {command, owner, session}
heartbeat             {command, owner, session}
stop / recover        {command, owner, session}
```

Привилегированные локальные install-команды: `install-transport`, `reconcile-transport`, `uninstall-transport`; `admin-stop` завершает только сессию компонента. Они не входят в allowlist desktop SSH adapter. Unix control socket имеет mode 0600; управляющего HTTP-порта нет.

Lease — 90 секунд, heartbeat — 15. Linux guardian/subreaper завершает осиротевших тестовых детей при SIGKILL контроллера: собственный `setuid` nfqws2 сбрасывает обычный parent-death signal. После краша `recover` снимает stale socket только под lock; PID рабочего zapret2 не ищется и не завершается.

Удаление компонента:

```sh
sh install-router.sh uninstall
```

Полное удаление Zator также вызывает component cleanup. При неуспешной очистке каталог сохраняется. Настройки компонента включены в обычный backup. Внешний bootstrap `AloofLibra/z4r:z2r` продолжает работать без изменений; он не устанавливает необязательные Go-бинарники. Обновлённый NDM hook добавлен в core/offline payload.

## Проверки

```powershell
cd desktop-probe/router
go test ./...
go vet ./...
cd ../app
npm test
npm run smoke
```

Linux: дополнительно `go test -race ./...`. Физические тесты opt-in, требуют подготовленного компонента и свободной сессии:

```sh
ZATOR_PROBE_HARDWARE_BENCH=1 ./router-tests -test.v -test.run TestHardwareSingBoxCandidate
ZATOR_PROBE_HARDWARE_LIFECYCLE=1 ZATOR_PROBE_HARDWARE_FAULTS=1 ./router-tests -test.v -test.run TestHardwareAgent -test.timeout 150s
```

`go test -c` создаёт `router-tests` под нужную GOOS/GOARCH. Эти проверки адресно меняют **только собственные** правила и завершают **только собственные** процессы; рабочие конфиги/локи проверяются по hash. Не запускайте opt-in hardware tests параллельно с приложением.

Не входят в TCP MVP: UDP/QUIC/HTTP3, IPv6, WebRTC, TUN/WFP, автоматическое применение результата в production, эквивалентность LAN-клиенту и подпись Windows-бинарника. TLS-проверка браузера остаётся включённой.
