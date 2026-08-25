# Client scopes (Beta): краткий гайд

Client scopes позволяют назначать разные стратегии разным LAN-клиентам по IP.
Функция работает через firewall mark до NAT и выбор scoped lock в Lua.
По умолчанию функция выключена.

## 1. Правильное обновление

Перед обновлением:

1. Убедитесь, что доступен свободный объём на роутере.
2. В меню установки согласитесь на создание backup конфигурации.
3. Не закрывайте SSH-сессию во время остановки/запуска сервисов.
4. После обновления проверьте, что `nfqws2` запущен.

Для установки именно версии из ветки `develop` запускайте launcher с явной веткой:

```sh
Z2R_BRANCH=develop z2r
```

Если используется локальный/offline-архив, он должен быть собран именно из `develop`; нельзя смешивать `z2r.sh`, `lib/`, `lua/`, firewall-скрипты и `config.default` от разных веток.

После обновления проверьте:

```sh
ps w | grep '[n]fqws2'
grep -E '^(CLIENT_SCOPE_|DESYNC_MARK|DESYNC_MARK_POSTNAT)' /opt/zapret2/config
```

Нормальный безопасный результат до включения Beta:

```text
CLIENT_SCOPE_ENABLE=0
```

Обновление zapret2 пересоздаёт `/opt/zapret2`, но client-scope mapping и locks должны находиться в `/opt/zator` и сохраняться. Перед экспериментами всё равно рекомендуется сделать backup через штатное меню.

## 2. Где находятся пункты CLI

Откройте:

```text
Управление стратегиями
```

Пункты:

```text
11. Client scopes: IP и lock
22. Client scopes (Beta): включен/выключен
```

Пункт `22` — отдельный переключатель режима.
Пункт `11` — настройка IP-маппингов и scoped locks.

## 3. Настройка IP клиента

Откройте:

```text
Управление стратегиями → 11. Client scopes: IP и lock
```

Выберите добавление/изменение IP и укажите, например:

```text
IP клиента: 192.168.10.102
Scope: mark:101
```

Соответствие сохраняется в:

```text
/opt/zator/extra_strats/cache/client_scope.tsv
```

Каноническая строка файла:

```text
mark:101<TAB>192.168.10.102
```

Поддерживаются IPv4 и IPv6. Для одного IP можно задать только один scope; повторное добавление обновляет существующее соответствие.

Важно:

- `mark:0` запрещён;
- scope должен иметь вид `mark:число`;
- некорректные IP, табы и управляющие символы отклоняются;
- IP используется только firewall-правилом, Lua не пытается определять клиента по post-NAT source IP.

## 4. Включение режима Beta

После добавления хотя бы одного IP-маппинга выберите:

```text
Управление стратегиями → 22. Client scopes (Beta): выключен
```

CLI установит:

```ini
CLIENT_SCOPE_ENABLE=1
CLIENT_SCOPE_MARK_MASK=0xff00
CLIENT_SCOPE_MARK_SHIFT=8
CLIENT_SCOPE_MARK_MAX=255
```

и применит изолированные firewall-правила.

Без IP-маппинга режим не включается.

Для OpenWrt с nftables правило создаётся в отдельной таблице:

```text
inet zator_client_scope
```

Оно не должно смешиваться с таблицами zapret2, fw4 или сторонних сервисов.

## 5. Scoped lock для клиента

В том же пункте `11` выберите установку lock и укажите:

```text
Scope: mark:101
Профиль: 5
Протокол: udp
Стратегия: 7
```

Теперь для клиента с IP `192.168.10.102`:

```text
profile 5/udp → strategy 7
```

Для остальных клиентов продолжает действовать global/default lock, например:

```text
default + profile 5/udp → strategy 1
```

Пример для TCP:

```text
Scope: mark:101
Профиль: 3
Протокол: tls
Стратегия: 7
```

`strategy=0` — это корректный scoped disable: соответствующий профиль отключается только для указанного scope.

## 6. Проверка работы

1. С устройства с заданным IP откройте нужный сайт или приложение.
2. Убедитесь, что клиентский трафик проходит.
3. На роутере проверьте:

```sh
nft list table inet zator_client_scope
logread | grep -i nfqws2 | grep -E 'mark=|scope=|strategy'
```

Для успешного client-scope выбора в debug-логе должны быть признаки:

```text
mark=20006500
scope=mark:101
locked strategy 7 scope=mark:101
```

Значение `20006500` содержит служебную часть zapret2 и client-mark область. Наличие mark само по себе доказывает только работу firewall; выбор scoped strategy подтверждается строкой Lua про `scope=mark:101` и нужную стратегию.

Проверку для другого клиента выполняйте отдельно, с другим IP и другим scope, например `mark:102`. Его трафик не должен использовать lock `mark:101`.

## 7. Отключение и удаление

Чтобы временно выключить режим:

```text
Управление стратегиями → 22. Client scopes (Beta): включен/выключен
```

Отключение:

- устанавливает `CLIENT_SCOPE_ENABLE=0`;
- удаляет принадлежащую zator таблицу/правила firewall;
- возвращает legacy/default поведение.

Чтобы удалить конкретный IP:

```text
Управление стратегиями → 11. Client scopes: IP и lock
→ Удалить IP-маппинг
```

Если удалён последний mapping, режим автоматически выключается.

Scoped lock удаляется отдельно через сброс scoped lock. Отключение режима не должно удалять lock-файлы: это позволяет безопасно включить Beta снова после проверки.

## 8. Если что-то не работает

Проверьте по порядку:

```sh
cat /opt/zator/extra_strats/cache/client_scope.tsv
cat /opt/zator/extra_strats/cache/orchestra/locked.tsv
nft list table inet zator_client_scope
ps w | grep '[n]fqws2'
logread | grep -i nfqws2 | tail -100
```

Типовые причины:

- IP клиента изменился — нужен DHCP reservation;
- режим выключен (`CLIENT_SCOPE_ENABLE=0`);
- mark пересекается с `DESYNC_MARK` или `DESYNC_MARK_POSTNAT`;
- выбран неправильный профиль/proto (`tls`, `http`, `udp`);
- scoped lock отсутствует — тогда применяется `default`;
- есть конфликтующие строки lock — scoped слой пропускается с fallback к default;
- используется старый runtime из другой ветки — повторите обновление целиком из `develop`.

При проблемах сначала выключите `Client scopes (Beta)`, убедитесь, что обычный трафик восстановился, затем исправляйте mapping или lock.

## 9. Безопасные значения по умолчанию

Если mapping, mark или scoped lock некорректны, runtime использует `default`/legacy behavior. Client scopes не должны включаться автоматически.

Служебные marks zapret2 использовать нельзя:

```ini
DESYNC_MARK=0x40000000
DESYNC_MARK_POSTNAT=0x20000000
```

Для client scopes используется отдельная область mark, которую задаёт CLI.
