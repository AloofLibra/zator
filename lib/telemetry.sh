# ---- Telemetry module integration ----
# Настройки z4r telemetry endpoint
STATS_ENDPOINT="https://alooflibra.fun/z4r/telemetry"
STATS_TOKEN="TzeiCfYn5DUIwjHJ6dPa4bSKrkFRZqts3BGWpA9l"
STATS_CHANNEL_ID="z4r-sql-v1"

# 2. Пути к файлам (используем простые форматы)
CACHE_DIR="/opt/zapret2/extra_strats/cache"
TELEMETRY_CFG="/opt/zapret2/z2r_lib/telemetry.config"
PROVIDER_TXT="$CACHE_DIR/provider.txt"

telemetry_save_config() {
    local enabled="$1"
    local uuid="$2"
    local channel_id="${3:-}"

    echo "tel_enabled=$enabled" > "$TELEMETRY_CFG"
    echo "tel_uuid=$uuid" >> "$TELEMETRY_CFG"
    [ -n "$channel_id" ] && echo "tel_channel_id=$channel_id" >> "$TELEMETRY_CFG"
}

# Функция инициализации (Спрашивает пользователя один раз)
init_telemetry() {
    mkdir -p "$CACHE_DIR"
    local tel_enabled=""
    local tel_uuid=""
    local tel_channel_id=""

    # 1. Загружаем конфиг, если он есть
    [ -f "$TELEMETRY_CFG" ] && source "$TELEMETRY_CFG"

    # 2. Если статус еще не задан — спрашиваем
    if [ -z "$tel_enabled" ]; then
        echo ""
        echo -e "${green}Хотите отправлять анонимную статистику (Провайдер + Стратегии)?${plain}"
        echo -e "Это поможет понять, какие стратегии работают лучше всего."
        read -p "Разрешить? (y/n): " stats_yn

        case "$stats_yn" in
            [Yy]*) tel_enabled="1" ;;
            *)     tel_enabled="0" ;;
        esac

        # Сразу сохраняем выбор
        telemetry_save_config "$tel_enabled" "$tel_uuid" "$tel_channel_id"

        if [ "$tel_enabled" == "1" ]; then
            echo -e "${green}Спасибо! Статистика включена.${plain}"
        else
            echo -e "${red}Статистика отключена.${plain}"
        fi
        sleep 1
    fi

    # 3. Генерация UUID (если включено и его нет)
    if [ "$tel_enabled" == "1" ] && [ -z "$tel_uuid" ]; then
        # Пытаемся взять системный UUID или генерируем md5 от времени
        if [ -f /proc/sys/kernel/random/uuid ]; then
            tel_uuid=$(cat /proc/sys/kernel/random/uuid | cut -c1-8)
        else
            tel_uuid=$(date +%s%N | md5sum | head -c 8)
        fi

        # Перезаписываем конфиг с новым UUID
        telemetry_save_config "$tel_enabled" "$tel_uuid" "$tel_channel_id"
    fi

    # 4. Принудительная первичная отправка после смены канала телеметрии.
    # Старые включенные установки не должны ждать ручной смены стратегии.
    if [ "$tel_enabled" == "1" ] && [ "$tel_channel_id" != "$STATS_CHANNEL_ID" ]; then
        send_stats
        telemetry_save_config "$tel_enabled" "$tel_uuid" "$STATS_CHANNEL_ID"
    fi
}

# Функция отправки статистики
send_stats() {
    # Если конфига нет, значит init_telemetry не запускался — выходим
    [ ! -f "$TELEMETRY_CFG" ] && return 0

    # Читаем переменные (tel_enabled, tel_uuid)
    source "$TELEMETRY_CFG"

    # Если пользователь запретил — выходим
    if [ "$tel_enabled" != "1" ]; then
        return 0
    fi

    # 1. Провайдер (Читаем из provider.txt, который создает Provider detector)
    local my_isp="Unknown"
    if [ -s "$PROVIDER_TXT" ]; then
        my_isp=$(cat "$PROVIDER_TXT")
    else
        # Фолбек: если provider.txt еще нет, пробуем быстро узнать
        my_isp=$(curl -s --max-time 3 "http://ip-api.com/line?fields=org" | tr -cd '[:alnum:] ._-')
    fi

    # Обрезаем до 60 символов и ставим заглушку если пусто
    my_isp=$(echo "$my_isp" | head -c 60)
    [ -z "$my_isp" ] && my_isp="Unknown"

    # 2. Определяем номера стратегий
    local s_udp=$(orch_locked_get 5 udp)
    local s_tcp=$(orch_locked_get 1 tls)
    local s_gv=$(orch_locked_get 2 tls)
    local s_rkn=$(orch_locked_get 3 tls)
    s_udp="${s_udp:-0}"
    s_tcp="${s_tcp:-0}"
    s_gv="${s_gv:-0}"
    s_rkn="${s_rkn:-0}"

    # 3. Отправка в z4r telemetry endpoint (Тихий режим, в фоне &)
    curl -sL --max-time 10 \
        -d "token=$STATS_TOKEN" \
        -d "uuid=$tel_uuid" \
        -d "isp=$my_isp" \
        -d "udp=$s_udp" \
        -d "tcp=$s_tcp" \
        -d "gv=$s_gv" \
        -d "rkn=$s_rkn" \
        "$STATS_ENDPOINT" > /dev/null 2>&1 &
}
# ---- /Telemetry module integration ----
