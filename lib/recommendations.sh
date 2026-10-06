# Подсказки: сервер агрегирует Redis, роутер читает не более 17 строк TSV.
RECS_URL="${Z2R_RECS_URL:-https://alooflibra.fun/z4r/recommendations.tsv}"
RECS_FILE="${RECS_FILE:-${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/recommendations.tsv}"

recommendations_provider() {
  [ -s "${PROVIDER_CACHE:-/opt/zator/extra_strats/cache/provider.txt}" ] || return 0
  head -n1 "${PROVIDER_CACHE:-/opt/zator/extra_strats/cache/provider.txt}" | tr -d '\r'
}

# Не доверяем сети: лимиты, точный провайдер, фиксированная схема, только числа.
recommendations_valid() {
  [ -s "$1" ] && [ "$(wc -c < "$1")" -le 8192 ] || return 1
  RECS_PROVIDER_VALUE="$2" awk -F'\t' '
    BEGIN { provider=ENVIRON["RECS_PROVIDER_VALUE"] }
    function uint(s) { return s ~ /^[0-9]+$/ && length(s) <= 10 }
    function pct(s) { return s ~ /^[0-9]+(\.[0-9]+)?$/ && s+0 <= 100 }
    NR == 1 {
      if (NF != 5 || $1 != "meta" || $2 != "1" || $3 != provider || !uint($4) || !uint($5) || $5+0 <= 0) bad=1
      total=$4+0; next
    }
    $1 == "profile" {
      if (NF != 6 || $2 !~ /^[1-4]$/ || profiles[$2]++ || !uint($3) || $3+0 > total || $4 !~ /^[01]$/ || ($5 != "-" && !pct($5)) || ($6 != "-" && !pct($6))) bad=1
      if ($4 == 1 && (total < 10 || $5 == "-" || $6 == "-" || $6+0 <= $5+0)) bad=1
      next
    }
    $1 == "strategy" {
      if (NF != 6 || $2 !~ /^[1-4]$/ || !uint($3) || $3+0 < 1 || !pct($4) || !uint($5) || $5+0 < 1 || $5+0 > total || $6 !~ /^(classic|clone|mixed)$/ || ++tops[$2] > 3 || seen[$2 SUBSEP $3]++ || total < 10) bad=1
      next
    }
    { bad=1 }
    END { if (NR > 17 || NR < 5 || !profiles[1] || !profiles[2] || !profiles[3] || !profiles[4]) bad=1; exit bad ? 1 : 0 }
  ' "$1"
}

# Успехи И ошибки кешируются на сутки: открытие панели не создаёт цикл запросов.
# mkdir — общий замок CGI/CLI; старый замок после аварии освобождаем через минуту.
update_recommendations() {
  local provider request
  provider="$(recommendations_provider)"
  case "$provider" in ''|'Не определён'|Unknown) return 0 ;; esac
  request="${RECS_FILE}.request"
  mkdir -p "$(dirname "$RECS_FILE")" 2>/dev/null || return 0
  if [ -f "$request" ] && [ -n "$(find "$request" -mtime -1 2>/dev/null)" ] \
      && [ "$(head -n1 "$request")" = "$provider" ]; then return 0; fi
  [ ! -d "${RECS_FILE}.lock" ] || find "${RECS_FILE}.lock" -mmin +1 -exec rmdir '{}' \; 2>/dev/null
  (
    mkdir "${RECS_FILE}.lock" 2>/dev/null || exit 0
    local tmp="${RECS_FILE}.tmp.$$"
    trap 'rm -f "$tmp"; rmdir "${RECS_FILE}.lock" 2>/dev/null || true' EXIT
    # Повторная проверка после захвата замка.
    if [ -f "$request" ] && [ -n "$(find "$request" -mtime -1 2>/dev/null)" ] \
        && [ "$(head -n1 "$request")" = "$provider" ]; then exit 0; fi
    if curl -4 -fsS --connect-timeout 2 --max-time 5 --max-filesize 8192 \
        --get --data-urlencode "provider=$provider" "$RECS_URL" -o "$tmp" 2>/dev/null \
        && recommendations_valid "$tmp" "$provider" && mv -f "$tmp" "$RECS_FILE"; then
      printf '%s\nok\n' "$provider" > "${request}.tmp.$$"
    else
      printf '%s\nfailed\n' "$provider" > "${request}.tmp.$$"
    fi
    mv -f "${request}.tmp.$$" "$request"
  ) || true
  return 0
}

recommendations_load() {
  RECS_PROVIDER="$(recommendations_provider)"
  RECS_STATUS=unknown_provider
  case "$RECS_PROVIDER" in ''|'Не определён'|Unknown) return 0 ;; esac
  update_recommendations
  RECS_STATUS=unavailable
  if recommendations_valid "$RECS_FILE" "$RECS_PROVIDER"; then
    RECS_STATUS=ready
    [ "$(awk -F'\t' 'NR==1 {print $4+0}' "$RECS_FILE")" -ge 10 ] || RECS_STATUS=insufficient
    if [ "$(head -n1 "${RECS_FILE}.request" 2>/dev/null)" = "$RECS_PROVIDER" ] \
        && [ "$(sed -n '2p' "${RECS_FILE}.request" 2>/dev/null)" = failed ]; then RECS_STATUS=stale; fi
  fi
  return 0
}

# Один маленький awk для CGI; никакого jq/python и обработки сырых прогонов.
recommendations_json() {
  recommendations_load
  local file="$RECS_FILE"
  case "$RECS_STATUS" in unavailable|unknown_provider) file=/dev/null ;; esac
  RECS_PROVIDER_VALUE="$RECS_PROVIDER" awk -F'\t' -v status="$RECS_STATUS" '
    BEGIN { provider=ENVIRON["RECS_PROVIDER_VALUE"] }
    function esc(s, i,c,out) {
      for (i=1;i<=length(s);i++) {
        c=substr(s,i,1)
        if (c == "\\" || c == "\"") out=out "\\" c
        else if (c !~ /[[:cntrl:]]/) out=out c
      }
      return out
    }
    function percent(s) { return s == "-" ? "null" : s+0 }
    $1 == "meta" { samples=$4+0; at=$5+0 }
    $1 == "profile" { n[$2]=$3+0; clone[$2]=$4; classic[$2]=percent($5); cpct[$2]=percent($6) }
    $1 == "strategy" { p=$2; top[p]=top[p] sep[p] "{\"strategy\":" ($3+0) ",\"success_pct\":" ($4+0) ",\"samples\":" ($5+0) ",\"mode\":\"" $6 "\"}"; sep[p]="," }
    END {
      printf "{\"provider\":\"%s\",\"samples\":%d,\"minimum\":10,\"generated_at\":%d,\"status\":\"%s\",\"profiles\":{", esc(provider), samples, at, status
      for (p=1;p<=4;p++) {
        printf "%s\"%d\":{\"samples\":%d,\"top\":[%s],\"clone_recommended\":%s,\"classic_pct\":%s,\"clone_pct\":%s}", p==1?"":",", p, n[p], top[p], clone[p]==1?"true":"false", classic[p]==""?"null":classic[p], cpct[p]==""?"null":cpct[p]
      }
      print "}}"
    }
  ' "$file"
}

show_hint() {
  local profile label mode="classic"
  case "$1" in TCP|1) profile=1; label=YouTube ;; GV|2) profile=2; label=Googlevideo ;;
    RKN|3) profile=3; label=RKN ;; DS|4) profile=4; label=Discord ;; *) return 0 ;; esac
  recommendations_load
  case "$RECS_STATUS" in
    unknown_provider) printf '\nПодсказки появятся после определения провайдера (меню «Провайдер / подсказки»).\n'; return 0 ;;
    unavailable) printf '\nНе удалось получить подсказки: сервер статистики временно недоступен.\n'; return 0 ;;
    stale) printf '\nПоказаны сохранённые подсказки: обновление статистики временно недоступно.\n' ;;
  esac
  if [ "$(awk -F'\t' 'NR==1 {print $4+0}' "$RECS_FILE")" -lt 10 ]; then
    printf '\nДля подсказок пока недостаточно статистики вашего провайдера: нужно 10 завершённых суперсвипов от разных установок.\n'
    return 0
  fi
  if type mode_override_get >/dev/null 2>&1; then mode="$(mode_override_get "$profile" 2>/dev/null)"; fi
  RECS_PROVIDER_VALUE="$RECS_PROVIDER" awk -F'\t' -v p="$profile" -v label="$label" -v mode="$mode" '
    BEGIN { provider=ENVIRON["RECS_PROVIDER_VALUE"] }
    $1 == "meta" { n=$4 }
    $1 == "strategy" && $2 == p {
      if (!shown++) printf "\nПодсказки · %s · %s (%s уникальных установок):\n", label, provider, n
      m=$6=="clone"?"клоны":($6=="classic"?"классика":"оба режима")
      printf "  №%s — %s%% успешных проверок, установок: %s (%s)\n", $3,$4,$5,m
    }
    $1 == "profile" && $2 == p { recommend=$4; classic=$5; cpct=$6 }
    END {
      if (!shown) print "\nДля этого блока пока нет успешных стратегий в статистике провайдера."
      else print "Это ориентир по суперсвипам, а не гарантия: проверьте стратегию на своём подключении."
      if (recommend == 1 && mode != "clone") printf "Попробуйте включить клонирование ClientHello для %s (меню 16): успех %s%% против %s%% у классики.\n", label,cpct,classic
    }
  ' "$RECS_FILE"
  return 0
}
