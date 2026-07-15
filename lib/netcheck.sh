# Network / access checks

# Цвета (определяются глобально в z2r.sh; fallback для автономного запуска)
[ -z "$plain" ] && plain='\033[0m'
[ -z "$red" ] && red='\033[0;31m'
[ -z "$green" ] && green='\033[0;32m'
[ -z "$yellow" ] && yellow='\033[0;33m'

get_yt_cluster_domain() {
    local letters_map_a="u z p k f a 5 0 v q l g b 6 1 w r m h c 7 2 x s n i d 8 3 y t o j e 9 4 -"
    local letters_map_b="0 1 2 3 4 5 6 7 8 9 a b c d e f g h i j k l m n o p q r s t u v w x y z -"
    
    cluster_codename=$(curl -s --max-time 2 "https://redirector.xn--ngstr-lra8j.com/report_mapping?di=no"| sed -n 's/.*=>[[:space:]]*\([^ (:)]*\).*/\1/p')
	#Второй раз для пробития нерелевантного ответа
    cluster_codename=$(curl -s --max-time 2 "https://redirector.xn--ngstr-lra8j.com/report_mapping?di=no"| sed -n 's/.*=>[[:space:]]*\([^ (:)]*\).*/\1/p')
    
    [ -z "$cluster_codename" ] && {
        echo "Не удалось получить cluster_codename. Используем тогда rr1---sn-5goeenes.googlevideo.com" >&2
        echo "rr1---sn-5goeenes.googlevideo.com"
        return
    }
    
    local converted_name=""
    local i=0
    while [ $i -lt ${#cluster_codename} ]; do
        char=$(echo "$cluster_codename" | cut -c$((i+1)))
        idx=1
        for a in $letters_map_a; do
            [ "$a" = "$char" ] && break
            idx=$((idx+1))
        done
        b=$(echo "$letters_map_b" | cut -d' ' -f $idx)
        converted_name="${converted_name}${b}"
        i=$((i+1))
    done
    
    echo "rr1---sn-${converted_name}.googlevideo.com"
}

check_access() {
	local TestURL="$1"
	# Проверка TLS 1.2
	if curl --tls-max 1.2 --max-time 1 -s -o /dev/null "$TestURL"; then
		echo -e "${green}Есть ответ по TLS 1.2 (важно для ТВ и т.п.). ${yellow}Тест может быть ошибочен.${plain}"
	else
		echo -e "${yellow}Нет ответа по TLS 1.2 (важно для ТВ и т.п.) Таймаут 2сек. ${red}Проверьте доступность вручную. Возможно ошибка теста.${plain}"
	fi
	# Проверка TLS 1.3
	if curl --tlsv1.3 --max-time 1 -s -o /dev/null "$TestURL"; then
		echo -e "${green}Есть ответ по TLS 1.3 (важно в основном для всего современного) ${yellow}Тест может быть ошибочен.${plain}"
	else
		echo -e "${yellow}Нет ответа по TLS 1.3 (важно в основном для всего современного) Таймаут 2сек. ${red}Проверьте доступность вручную. Возможно ошибка теста.${plain}"
	fi
}


check_dns() {
    local DOMAIN="${1:-rutracker.org}"
    local DOH_RAW DOH_IPS NS_RAW NS_IPS MATCH_IPS MATCH_COUNT DOH_COUNT NS_COUNT ip


    echo "================================================"
    echo " Анализ DNS для домена: $DOMAIN"
    echo "================================================"

    DOH_RAW=$(curl -s --max-time 5 "https://dns.google/resolve?name=${DOMAIN}&type=A")

    if [ -z "$DOH_RAW" ]; then
        echo -e "${red}[-] Ошибка: Google DoH недоступен${plain}"
        return 1
    fi

    DOH_IPS=$(
        echo "$DOH_RAW" \
        | grep -E -o '([0-9]{1,3}\.){3}[0-9]{1,3}' \
        | sort -u
    )

    if [ -z "$DOH_IPS" ]; then
        echo -e "${red}[-] Ошибка: Google DoH не вернул IPv4 адреса${plain}"
        return 1
    fi

    echo -e "${yellow}-> Эталонные IP от DoH:${plain}"
    for ip in $DOH_IPS; do
        echo "  $ip"
    done

    echo "----------------------------------------"

    NS_RAW=$(nslookup "$DOMAIN" 2>/dev/null)

    if [ -z "$NS_RAW" ]; then
        echo -e "${red}[-] Ошибка: nslookup не смог разрешить домен${plain}"
        return 1
    fi

    NS_IPS=$(
        echo "$NS_RAW" \
        | awk '
            /^Name:[[:space:]]/ { in_answer=1; next }
            in_answer && /^Address([[:space:]][0-9]+)?:/ { print }
        ' \
        | grep -E -o '([0-9]{1,3}\.){3}[0-9]{1,3}' \
        | sort -u
    )

    echo -e "${yellow}-> Полученные IP от nslookup:${plain}"

    if [ -z "$NS_IPS" ]; then
        echo "  Пустой ответ"
    else
        for ip in $NS_IPS; do
            echo "  $ip"
        done
    fi

    echo "================================================"

    if [ -z "$NS_IPS" ]; then
        echo -e "${red} ВНИМАНИЕ: DNS не вернул ни одного IPv4 адреса${plain}"
        echo "================================================"
        return 2
    fi

    if echo "$NS_IPS" | grep -Eq '^(127\.0\.0\.1|0\.0\.0\.0)$'; then
        echo -e "${red} ВНИМАНИЕ: ОБНАРУЖЕНА ЯВНАЯ DNS-ПОДМЕНА${plain}"
        echo " DNS вернул адрес блокировки: $NS_IPS"
        echo "================================================"
        return 2
    fi

    MATCH_IPS=""
    MATCH_COUNT=0

    for ip in $NS_IPS; do
        if echo "$DOH_IPS" | grep -Fxq "$ip"; then
            MATCH_IPS="$MATCH_IPS $ip"
            MATCH_COUNT=$((MATCH_COUNT + 1))
        fi
    done

    DOH_COUNT=$(echo "$DOH_IPS" | wc -w | tr -d ' ')
    NS_COUNT=$(echo "$NS_IPS" | wc -w | tr -d ' ')

    if [ "$MATCH_COUNT" -eq "$DOH_COUNT" ] && [ "$DOH_COUNT" -eq "$NS_COUNT" ]; then

        echo -e "${green} ВЕРДИКТ: ВСЁ ЧИСТО${plain}"
        echo " IP из локального DNS полностью совпадают с DoH."
        echo " Явной подмены DNS не обнаружено."
        echo "================================================"
        return 0

    fi

    if [ "$MATCH_COUNT" -gt 0 ]; then

        echo -e "${green} ВЕРДИКТ: DNS РАБОТАЕТ КОРРЕКТНО${plain}"
        echo " Найдены совпадающие IP:"
        echo "$MATCH_IPS" | tr ' ' '\n' | grep -v "^$" | sed 's/^/  /'
        echo ""
        echo " Ответы отличаются частично."
        echo " Для Cloudflare/CDN это является нормальным поведением."
        echo " Признаков DNS-подмены не обнаружено."
        echo "================================================"
        return 0

    fi

    echo -e "${red} ВНИМАНИЕ: ВОЗМОЖНА DNS-ПОДМЕНА${plain}"
    echo " Совпадающих IP между DoH и локальным DNS не найдено."
    echo ""
    echo " Возможные причины:"
    echo " - DNS фильтрация провайдера"
    echo " - Подмена DNS"
    echo " - Некорректная работа DNS сервера"
    echo "================================================"

    return 2
}

check_access_list() {
   if ! check_dns "rutracker.org"; then
      echo -e "${yellow}DNS-проверка завершилась предупреждением, продолжаю остальные тесты.${plain}"
   fi

   echo "Проверка доступности youtube.com (YT TCP)"
   check_access "https://www.youtube.com/"
   echo "Проверка доступности $(get_yt_cluster_domain) (YT TCP)"
   check_access "https://$(get_yt_cluster_domain)"
   echo "Проверка доступности meduza.io (RKN list)"
   check_access "https://meduza.io"
   echo "Проверка доступности www.instagram.com (RKN list + нужен рабочий DNS)"
   check_access "https://www.instagram.com/"

}
