# Desktop Probe: совместимость и ресурсы

Дата проверки: 24.10.2026. Значения ниже описывают один предоставленный OpenWrt; перед другой установкой нужен новый аудит.

| Среда | Статус |
|---|---|
| Windows, Node 24.20.0, Electron 45.0.0, TypeScript 7.0.2 | Сборка, unit tests и sandbox/IPC/form smoke |
| Cudy WR3000P v1, OpenWrt 25.12.4 r32933-4ccb782af7, kernel 6.12.87, ARM64, 496716 kB RAM | Реальный SSH/SOCKS/NFQUEUE/Lua/WAN PoC, отказные тесты |
| Installed nfqws2 | `v1.0.5.2`, commit `6b6c63e3385fa73f8af3be4a69171e947f5a319d`, Lua compat 6; не обновлялся |
| mawg + MagiTrickle | Оба активны при испытаниях; PID/конфиги/группы не менялись |
| KeeneticOS/Entware, 128 МБ, MIPS/MIPSLE/ARMv7 | Аппаратно не проверены; только сборка/моки соответствующих частей |

## Аудит ресурсов

| Ресурс | Уже используется | Desktop Probe на тестовом устройстве |
|---|---|---|
| Production queue / UID | queue **300**, UID **65534** (`nobody`) | Не используются |
| Supersweep | queue **65535**, UID/GID **65533**, mark **0x08000000**, ports **62000–62999**, `Z2R_SS_*` | Не используются |
| nfqws2 / proxy identity | Existing users/processes проверены | UID/GID **65532** / **65531** |
| Test queue / mark | Проверены nft, procfs, policy rules | **65534** / **0x04000000** |
| Native loop/post-NAT marks | **0x40000000**, **0x20000000**; client mask **0xff00** | Совместимый raw bypass; чужие bits сохраняются |
| Listener | Existing services не занимали порт | Только `127.0.0.1:41081` |
| PC forward | Отдельный SSH process | Случайный свободный loopback port |
| Kernel ephemeral range | **32768–60999** | Исходящий source port выбирает ядро; нет привязки к Supersweep ports |
| WAN / VPN | `pppoe-wan`; policy tables 30000–30006, marks 0x7530–0x7536; есть явные VPN routes | Проверяется наблюдаемый mark/route; mismatch не становится OK |

UID/GID сверяются с `/etc/passwd`, `/etc/group` и `/proc/*/status`; queue — с procfs и чужими firewall rules; mark — с config/firewall/policy. Порт проверяется до запуска и затем по UID listener. При конфликте отказ, автоматической смены ресурса нет.

## Packet path

`Chromium partition → PC loopback SSH -L → router loopback SOCKS (65531) → OUTPUT owner/ct mark → native postnat hook → queue 65534 / nfqws2 (65532) → pppoe-wan`.

Reply определяется conntrack direction/mark и попадает в test queue раньше production path. Raw fake имеет отдельный UID, loop mark и post-NAT bypass. Физический pcap для strategy 1 подтвердил sequence offset `-3000` на WAN. Обычный root TCP socket не увеличивал test counter; production config/locks hash и queue consumer сохранялись.

## Что ещё не подтверждено

- Физический Keenetic, значения NDM event variables/order на нём, 128-МБ нагрузка/OOM, MIPS ABI и старый kernel subreaper/netlink.
- Полный WAN/firewall reload, reboot и установка OpenWrt startup/include hook; тестировалась адресная потеря собственного правила с явным reconcile.
- Wire capture Windows UDP/WebRTC/DNS leakage; IPv6/UDP не обслуживаются SOCKS, QUIC отключён, permissions/WebRTC policy ограничены, но это не подменяет отдельную leak-матрицу.
- Настоящее YouTube video / Discord с авторизацией и вся матрица 44 стратегий. Проверенный generic сценарий — явно заданное DOM-условие на example.org.
- Windows signing и пиксельная QA: UI DOM/IPC проверены, compositor capture в тестовом окружении возвращал `UnknownVizError`.
