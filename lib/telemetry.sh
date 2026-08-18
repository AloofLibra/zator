# ---- Telemetry module integration ----
# Настройки z4r telemetry endpoint
STATS_ENDPOINT="https://alooflibra.fun/z4r/telemetry"
STATS_TOKEN="TzeiCfYn5DUIwjHJ6dPa4bSKrkFRZqts3BGWpA9l"
STATS_CHANNEL_ID="z4r-sql-v2"

# 2. Пути к файлам (используем простые форматы)
CACHE_DIR="/opt/zator/extra_strats/cache"
TELEMETRY_CFG="/opt/zator/z2r_lib/telemetry.config"
PROVIDER_TXT="$CACHE_DIR/provider.txt"

telemetry_save_config() {
    local enabled="$1"
    local uuid="$2"
    local channel_id="${3:-}"

    echo "tel_enabled=$enabled" > "$TELEMETRY_CFG"
    echo "tel_uuid=$uuid" >> "$TELEMETRY_CFG"
    # Пустой channel_id не должен делать возврат функции ненулевым (set -e в z2r.sh).
    if [ -n "$channel_id" ]; then
        echo "tel_channel_id=$channel_id" >> "$TELEMETRY_CFG"
    fi
    return 0
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
        read -p "Разрешить? (Enter - да, n - нет): " stats_yn

        case "$stats_yn" in
            [NnНн]*) tel_enabled="0" ;;
            *)       tel_enabled="1" ;;
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

    # 2. Определяем номера стратегий во всех профилях (auto передаём как 0).
    local s_udp s_tcp s_gv s_rkn s_ds s_voice s_games s_fb_tls s_fb_http
    s_tcp="$(profile_state_display 1 tls)"
    s_gv="$(profile_state_display 2 tls)"
    s_rkn="$(profile_state_display 3 tls)"
    s_ds="$(profile_state_display 4 tls)"
    s_udp="$(profile_state_display 5 udp)"
    s_voice="$(profile_state_display 6 udp)"
    s_games="$(profile_state_display 7 udp)"
    s_fb_tls="$(profile_state_display 8 tls)"
    s_fb_http="$(profile_state_display 9 http)"
    local strategy_var
    for strategy_var in s_udp s_tcp s_gv s_rkn s_ds s_voice s_games s_fb_tls s_fb_http; do
        [ "${!strategy_var}" = "auto" ] && printf -v "$strategy_var" '%s' 0
    done

    # 3. Платформа и наличие установленного WebUI.
    local router_os="unknown"
    if [ -d /jffs ] || uname -a 2>/dev/null | grep -qi merlin; then
        router_os="merlin"
    elif grep -Eqi 'netcraze' /proc/version /bin/ndmc 2>/dev/null; then
        router_os="netcraze"
    elif command -v ndmc >/dev/null 2>&1 || grep -Eqi 'keenetic' /proc/version 2>/dev/null; then
        router_os="keenetic"
    elif [ -f /etc/os-release ]; then
        router_os="$(sed -n 's/^ID=//p' /etc/os-release | head -n1 | tr -d '\"' | tr '[:upper:]' '[:lower:]')"
    elif [ -f /usr/lib/os-release ]; then
        router_os="$(sed -n 's/^ID=//p' /usr/lib/os-release | head -n1 | tr -d '\"' | tr '[:upper:]' '[:lower:]')"
    elif [ -f /opt/etc/entware_release ] || [ -f /etc/entware_release ]; then
        router_os="entware"
    fi
    [ -n "$router_os" ] || router_os="unknown"
    local webui=0
    [ -x /opt/zator/webui/run-webui.sh ] && webui=1

    # 4. Отправка в z4r telemetry endpoint (Тихий режим, в фоне &)
    curl -sL --max-time 10 \
        -d "token=$STATS_TOKEN" \
        -d "uuid=$tel_uuid" \
        -d "isp=$my_isp" \
        -d "udp=$s_udp" \
        -d "tcp=$s_tcp" \
        -d "gv=$s_gv" \
        -d "rkn=$s_rkn" \
        -d "ds_tls=$s_ds" \
        -d "voice_udp=$s_voice" \
        -d "games_udp=$s_games" \
        -d "fb_tls=$s_fb_tls" \
        -d "fb_http=$s_fb_http" \
        -d "os=$router_os" \
        -d "webui=$webui" \
        "$STATS_ENDPOINT" > /dev/null 2>&1 &
}
# ---- /Telemetry module integration ----
