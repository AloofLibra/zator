# Desktop Probe: обязательная проверка на физическом Keenetic

Статус 24.10.2026: устройство ещё не предоставлено, тесты отложены пользователем. OpenWrt PoC не закрывает этот checklist.

1. Записать модель, KeeneticOS/kernel, Entware ABI, RAM, свободную память, версии Zator/nfqws2 и соседних проектов.
2. Снять read-only snapshot UID/GID, proc queues, `iptables-save`, `ip rule`, всех route tables и production PID/start time/config/locks hashes. Проверить `owner`, `CONNMARK`, NFQUEUE, queue-bypass, SSH `-L`, procfs, subreaper и netlink.
3. Выбрать отдельные UID/GID/queue/bit/listener. Не копировать OpenWrt example без сверки. Должны быть свободны также passwd/group identities; UID proxy и nfqws2 различаются.
4. Установить компонент с `backend=iptables` и реальным WAN. Убедиться, что установлен обновлённый штатный `000-zapret2.sh`; `$type=iptables`, `$table=mangle`, client scope восстанавливается раньше Desktop Probe.
5. DIRECT и strategy 1 через Windows OpenSSH/Chromium: fresh socket/TLS, proxy hostname/tuple, conntrack mark, queue owner/counter, private Lua invocation, pcap normal/reply/raw fake на ожидаемом WAN.
6. Параллельный LAN-клиент не попадает в test queue. Production config/locks/PID и пользовательские VPN/groups остаются прежними.
7. Записать состояние до/после start/set-strategy/stop: никаких iptables mutations. 10 NDM/reconcile событий — без duplicate rules, прежняя попытка INVALID после смены generation.
8. С согласованным окном обслуживания проверить реальную WAN/firewall пересборку и reboot. Не перезапускать рабочий zapret2 ради самой пробы. Потерянная изоляция — INVALID, не успех через production.
9. Выполнить opt-in `TestHardwareAgentLifecycle`, `TestHardwareAgentFaults`: TERM nfqws2, SIGKILL контроллера, guardian/subreaper cleanup, stale-socket recover и TTL. Проверить отсутствие чужих сигналов и осиротевших test queues.
10. Измерить RSS/CPU/latency/нагрузку на 128 МБ с обычным пользовательским трафиком и активными mawg/MagiTrickle. Проверить IPv4-only/QUIC/WebRTC/DNS leak-матрицу на wire.

Сохранить доказательства с session/generation и очищенными URL. UNKNOWN/INVALID не включать в рейтинг; не переносить результаты router_socks_tcp на LAN как эквивалентные.

Пока пункты не пройдены, Keenetic hardware gate остаётся PARTIAL; GUI и сборки не являются сертификатом совместимости.
