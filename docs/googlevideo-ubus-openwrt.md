# Проверка локального Googlevideo-сбора на OpenWrt

Сбор запускается автоматически при включённом Ramp и `NFQWS2_ENABLE=1` на OpenWrt с объектом `dnsmasq.dns`. Поддержка `ipset`/`nftset` в dnsmasq не требуется. На других платформах остаётся центральный список.

После установки сборки проверьте состояние и подписку:

```sh
/opt/zator/tools/googlevideo-dns-listener.sh status && echo running
ubus list | grep -Fx dnsmasq.dns
```

В отдельной SSH-сессии запустите:

```sh
ubus subscribe dnsmasq.dns
```

Затем запросите новый адрес Googlevideo:

```sh
nslookup rr4---sn-h5gtov-n8vl.googlevideo.com 127.0.0.1
```

В событии `dns_result` должны быть `type: A`, Googlevideo hostname, `address` и `ttl`. Проверьте локальную запись и ядровый set (подставьте `inet` table из `/opt/zapret2/config`):

```sh
cat /tmp/z2r-googlevideo/local.tsv
nft list set inet zapret2 z2r_googlevideo4
# Для iptables:
ipset list z2r_googlevideo4
```

Убедитесь, что nfqws2 не перезапускался и число firewall-правил не менялось:

```sh
pidof nfqws2
nft -a list ruleset | grep -c z2r_googlevideo4
```

Для проверки повторного подключения по очереди перезапустите dnsmasq и убедитесь, что новый запрос снова отражается в `local.tsv`. Перезапуск `ubus` прерывает SSH и сеть на время восстановления; выполнять его следует только при доступе к локальной консоли/автоматическому восстановлению. После отключения Ramp должен исчезнуть pid-файл подписчика:

```sh
/opt/zator/tools/googlevideo-dns-listener.sh status || echo stopped
```

Локальные записи находятся только в tmpfs и автоматически устаревают по DNS TTL (максимум 7 дней). Они попадают в централизованную отправку только при включённой телеметрии; адреса из центрального списка отфильтровываются перед отправкой.

## Сравнение baseline, Full и Lite

Используйте один и тот же достаточно большой видеопоток/подписанный URL, свежий URL для каждого прогона и один выбранный Googlevideo IP. Сохраните текущий config и верните его после измерений:

```sh
cp /opt/zapret2/config /tmp/z2r-config.before-wssize-test
IP=188.244.8.77
PLAYBACK_URL='ВСТАВЬТЕ_СВЕЖУЮ_ПОДПИСАННУЮ_ССЫЛКУ'

set_mode() {
  mode="$1" enabled="$2"
  sed -i "s/^Z2R_WSSIZE_RAMP_ENABLE=.*/Z2R_WSSIZE_RAMP_ENABLE=$enabled/" /opt/zapret2/config
  sed -i "s/^Z2R_WSSIZE_RAMP_MODE=.*/Z2R_WSSIZE_RAMP_MODE=$mode/" /opt/zapret2/config
  /etc/init.d/zapret2 restart
  sleep 3
}

run_capture() {
  label="$1"
  tcpdump -ni wan -s 128 -w "/tmp/wssize-$label.pcap" "host $IP and tcp port 443" &
  cap=$!
  curl -4 -L --connect-timeout 10 --max-time 60 -o /dev/null \
    -w "$label http=%{http_code} bytes=%{size_download} seconds=%{time_total} Bps=%{speed_download}\n" \
    "$PLAYBACK_URL"
  kill -INT "$cap" 2>/dev/null || true
  wait "$cap" 2>/dev/null || true
  tcpdump -nn -tt -r "/tmp/wssize-$label.pcap" "host $IP and tcp port 443" \
    > "/tmp/wssize-$label.txt"
  top -b -n 2 | tail -n 20 > "/tmp/wssize-$label.top"
}

set_mode full 0; run_capture baseline
set_mode full 1; run_capture full
set_mode lite 1; run_capture lite

cp /tmp/z2r-config.before-wssize-test /opt/zapret2/config
/etc/init.d/zapret2 restart
```

Run the three captures several times in shuffled order because CDN node load changes. Compare downloaded bytes, elapsed time, retransmissions and CPU samples. The `-vv` live capture form shows the advertised SYN window and Window Scale option:

```sh
tcpdump -ni wan -vv "host $IP and tcp[tcpflags] & tcp-syn != 0"
```

Full should retain the two Ramp late-ACK rules; Lite should show only the address-mark rules. The total firewall rule count should stay constant as `z2r_googlevideo4` grows.
