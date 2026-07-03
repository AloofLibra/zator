#!/bin/sh

config_get_file() {
  if [ -n "$1" ] && [ -f "$1" ]; then
    echo "$1"
    return 0
  fi
  if [ -f /opt/zapret2/config ]; then
    echo /opt/zapret2/config
    return 0
  fi
  if [ -f /opt/zapret2/config.default ]; then
    echo /opt/zapret2/config.default
    return 0
  fi
  return 1
}

get_config_file() {
  config_get_file "$@"
}

config_var_exists() {
  local cfg="$1"
  local var="$2"
  [ -f "$cfg" ] || return 1
  grep -q "^[[:space:]]*${var}=" "$cfg"
}

config_get_var() {
  local cfg="$1"
  local var="$2"
  [ -z "$cfg" ] && cfg="$(config_get_file)" || true
  [ -f "$cfg" ] || return 1
  sed -n "s/^[[:space:]]*${var}=//p" "$cfg" | head -n1
}

config_set_var() {
  local cfg="$1"
  local var="$2"
  local val="$3"
  local esc_val

  [ -f "$cfg" ] || return 1
  esc_val=$(printf '%s' "$val" | sed 's/[\/&]/\\&/g')
  if grep -q "^[[:space:]]*${var}=" "$cfg"; then
    sed -i "s#^[[:space:]]*${var}=.*#${var}=${esc_val}#" "$cfg"
  else
    printf '%s=%s\n' "$var" "$val" >> "$cfg"
  fi
}

# Определяет Linux-имя WAN интерфейса по default route.
# На Keenetic это может быть ppp0, eth*, nwg*, wwan0 и т.п.
config_keenetic_detect_default_iface() {
  local family="$1"

  command -v ip >/dev/null 2>&1 || return 1
  ip "-$family" route show default 2>/dev/null | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "dev" && $(i + 1) != "" && $(i + 1) != "lo") {
          print $(i + 1)
          exit
        }
      }
    }
  '
}

# Прописывает IFACE_WAN/IFACE_WAN6 в указанный конфиг только для Keenetic.
# Если IPv6 default route не найден, IFACE_WAN6 не трогаем: zapret2 возьмёт IFACE_WAN.
config_keenetic_set_wan_iface() {
  local cfg="$1"
  local wan4 wan6

  [ "$hardware" = "keenetic" ] || return 0
  [ -f "$cfg" ] || return 0

  wan4="$(config_keenetic_detect_default_iface 4)"
  wan6="$(config_keenetic_detect_default_iface 6)"

  if [ -z "$wan4" ]; then
    echo -e "${yellow}Не удалось автоматически определить WAN интерфейс Keenetic. IFACE_WAN не изменён.${plain}"
    return 0
  fi

  config_set_var "$cfg" IFACE_WAN "\"$wan4\""
  if [ -n "$wan6" ]; then
    config_set_var "$cfg" IFACE_WAN6 "\"$wan6\""
    if [ "$wan6" != "$wan4" ]; then
      echo -e "${green}WAN интерфейсы Keenetic для $cfg: IPv4=$wan4, IPv6=$wan6${plain}"
    else
      echo -e "${green}WAN интерфейс Keenetic для $cfg: $wan4${plain}"
    fi
  else
    echo -e "${green}WAN интерфейс Keenetic для $cfg: $wan4${plain}"
  fi
}

# Применяет автоподстановку WAN к шаблону и рабочему конфигу, если они уже существуют.
config_keenetic_set_wan_iface_all() {
  config_keenetic_set_wan_iface /opt/zapret2/config.default
  config_keenetic_set_wan_iface /opt/zapret2/config
}

config_tls_blob_mode_value() {
  local cfg
  local has_tls_maxru=0
  local has_tls_default=0
  cfg="$(config_get_file "$1")" || { echo "не определён"; return 0; }

  if awk '
      /--lua-desync=/ && /blob=maxru/ && $0 !~ /strategy=26/ {found=1}
      END {exit(found?0:1)}
    ' "$cfg"; then
    has_tls_maxru=1
  fi
  if awk '
      /--lua-desync=/ && /blob=fake_default_tls/ && $0 !~ /strategy=26/ {found=1}
      END {exit(found?0:1)}
    ' "$cfg"; then
    has_tls_default=1
  fi

  if [ "$has_tls_maxru" -eq 1 ] && [ "$has_tls_default" -eq 0 ]; then
    echo "maxru"
  elif [ "$has_tls_default" -eq 1 ] && [ "$has_tls_maxru" -eq 0 ]; then
    echo "fake_default_tls"
  elif [ "$has_tls_default" -eq 1 ] && [ "$has_tls_maxru" -eq 1 ]; then
    echo "mixed"
  else
    echo "не определён"
  fi
}

config_tls_blob_menu_value() {
  local cfg blob_file mode
  cfg="$(config_get_file "$1")" || { echo "неизвестно"; return 0; }
  mode="$(config_tls_blob_mode_value "$cfg")"
  case "$mode" in
    fake_default_tls) echo "default"; return ;;
    mixed) echo "mixed"; return ;;
  esac
  blob_file="$(sed -n -E 's#.*--blob=maxru:@/opt/zapret2/files/fake/([^[:space:]]+).*#\1#p' "$cfg" | head -n1)"
  [ -n "$blob_file" ] && echo "$blob_file" || echo "неизвестно"
}

config_mode_text() {
  local mode="$1"
  local cfg="$2"
  local ports voice_block_active

  cfg="$(config_get_file "$cfg")" || {
    case "$mode" in
      rst_guard) echo "нет config" ;;
      tls_blob_mode) echo "не определён" ;;
      *) echo "неизвестно" ;;
    esac
    return 0
  }

  case "$mode" in
    flowoffload)
      config_get_var "$cfg" FLOWOFFLOAD
      ;;
    fwtype)
      config_get_var "$cfg" FWTYPE
      ;;
    hostlist)
      if grep -q '^MODE_FILTER=autohostlist' "$cfg"; then
        echo "авто"
      elif grep -q '^MODE_FILTER=hostlist' "$cfg"; then
        echo "по листам"
      else
        echo "неизвестно"
      fi
      ;;
    fallback)
      if { sed -n '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/p' "$cfg"; sed -n '/#Z2R_FALLBACK_HTTP_BEGIN/,/#Z2R_FALLBACK_HTTP_END/p' "$cfg"; } | grep -q '^[[:space:]]*--skip[[:space:]]'; then
        echo "выключен"
      elif sed -n '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/p' "$cfg" | grep -q '^[[:space:]]*--filter-tcp=443\([[:space:]].*\)\?$'; then
        echo "включен"
      else
        echo "неизвестно"
      fi
      ;;
    rst_guard)
      if grep -q -- '--lua-desync=rst_guard_locked:key=' "$cfg"; then
        echo "включен"
      else
        echo "выключен"
      fi
      ;;
    reasm_disable)
      if sed -n '/^NFQWS2_OPT="/,/^"$/p' "$cfg" | grep -q '^[[:space:]]*--reasm-disable'; then
        echo "включено"
      else
        echo "выключено"
      fi
      ;;
    udp_games)
      if printf "%s" "$(config_get_var "$cfg" NFQWS2_PORTS_UDP)" | grep -Eq '(^|,)1026-65531(,|$)'; then
        echo "Включен"
      elif config_var_exists "$cfg" NFQWS2_PORTS_UDP; then
        echo "Выключен"
      else
        echo "Неизвестно"
      fi
      ;;
    voice)
      ports="$(config_get_var "$cfg" NFQWS2_PORTS_UDP)"
      voice_block_active=0
      if sed -n '/#Стратегии для голосовой связи/,/^[[:space:]]*--new[[:space:]]*$/p' "$cfg" | grep -q '^[[:space:]]*--filter-udp='; then
        voice_block_active=1
      fi
      if printf "%s" "$ports" | grep -Eq '(^|,)50000-50099(,|$)' && [ "$voice_block_active" -eq 1 ]; then
        echo "Кастомные стратегии"
      elif ! printf "%s" "$ports" | grep -Eq '(^|,)50000-50099(,|$)' && [ "$voice_block_active" -eq 0 ]; then
        echo "Скрипты bol-van"
      else
        echo "неизвестно"
      fi
      ;;
    tls_blob_mode)
      config_tls_blob_mode_value "$cfg"
      ;;
    tls_blob_menu)
      config_tls_blob_menu_value "$cfg"
      ;;
    *)
      echo "неизвестно"
      ;;
  esac
}

config_profile_max_strategy() {
  local profile="$1"
  local cfg
  cfg="$(config_get_file "$2")" || { echo 0; return 0; }

  if [ "$profile" = "8" ] || [ "$profile" = "9" ]; then
    local begin_marker end_marker fallback_max
    if [ "$profile" = "9" ]; then
      begin_marker="#Z2R_FALLBACK_HTTP_BEGIN"
      end_marker="#Z2R_FALLBACK_HTTP_END"
    else
      begin_marker="#Z2R_FALLBACK_BEGIN"
      end_marker="#Z2R_FALLBACK_END"
    fi
    fallback_max="$(awk -v begin="$begin_marker" -v end="$end_marker" '
        function scan_strategies(line) {
            while (match(line, /strategy=[0-9]+/)) {
                num=substr(line, RSTART+9, RLENGTH-9)+0
                if (in_template && num>tplmax[tpl]) tplmax[tpl]=num
                if (inblk && num>max) max=num
                line=substr(line, RSTART+RLENGTH)
            }
        }
        BEGIN{inblk=0; in_template=0; tpl=""; max=0}
        /^--template=/ {
            in_template=1
            tpl=$0
            sub(/^--template=/, "", tpl)
            sub(/[[:space:]].*$/, "", tpl)
        }
        /^[[:space:]]*--new[[:space:]]*$/ {in_template=0; tpl=""}
        index($0, begin) {inblk=1; next}
        index($0, end) {inblk=0; exit}
        inblk {
            if ($0 ~ /^--import([=[:space:]]|$)/) {
                imp=$0
                sub(/^--import[=[:space:]]+/, "", imp)
                sub(/[[:space:]].*$/, "", imp)
                if (tplmax[imp]>max) max=tplmax[imp]
            }
        }
        { scan_strategies($0) }
        END{print max}
    ' "$cfg")"
    if [ -n "$fallback_max" ] && [ "$fallback_max" -gt 0 ]; then
      echo "$fallback_max"
      return 0
    fi
  fi

  awk -v pid="$profile" '
      function scan_strategies(line) {
          while (match(line, /strategy=[0-9]+/)) {
              num=substr(line, RSTART+9, RLENGTH-9)+0
              if (in_template && num>tplmax[tpl]) tplmax[tpl]=num
              if (!in_template && active && prof==pid && num>max) max=num
              line=substr(line, RSTART+RLENGTH)
          }
      }
      function start_profile_if_needed() {
          if (!in_template && !active &&
              $0 ~ /^--/ &&
              $0 !~ /^--new/ &&
              $0 !~ /^--lua-init/ &&
              $0 !~ /^--blob=/ &&
              $0 !~ /^--reasm-disable/) {
              prof++
              active=1
          }
      }
      BEGIN{inopt=0; prof=0; active=0; in_template=0; tpl=""; max=0}
      /^NFQWS2_OPT="/ {inopt=1}
      inopt {
          if ($0 ~ /^--template=/) {
              in_template=1
              tpl=$0
              sub(/^--template=/, "", tpl)
              sub(/[[:space:]].*$/, "", tpl)
          } else {
              start_profile_if_needed()
          }
          if (!in_template && active && prof==pid && $0 ~ /^--import([=[:space:]]|$)/) {
              imp=$0
              sub(/^--import[=[:space:]]+/, "", imp)
              sub(/[[:space:]].*$/, "", imp)
              if (tplmax[imp]>max) max=tplmax[imp]
          }
          scan_strategies($0)
          if ($0 ~ /^--new/) {active=0; in_template=0; tpl=""}
          if ($0 ~ /^"$/) exit
      }
      END{print max}
  ' "$cfg"
}

config_tcp443_current_strategy() {
  local cfg
  cfg="$(config_get_file "$1")" || { echo 0; return 0; }
  awk '
    /^[[:space:]]*#Z2R_TCP443_BEGIN$/ {inblk=1; next}
    /^[[:space:]]*#Z2R_TCP443_END$/ {inblk=0; exit}
    inblk && $0 ~ /^--filter-tcp=443 --hostlist-domains=/ {
      n++
      if ($0 ~ /^--filter-tcp=443 --hostlist-domains= --/) {print n; found=1; exit}
    }
    END{if (!found) print 0}
  ' "$cfg"
}

config_tcp443_set_strategy() {
  local strategy="$1"
  local cfg
  cfg="$(config_get_file "$2")" || return 1
  awk -v target="$strategy" '
    /^[[:space:]]*#Z2R_TCP443_BEGIN$/ {inblk=1; print; next}
    /^[[:space:]]*#Z2R_TCP443_END$/ {inblk=0; print; next}
    inblk && $0 ~ /^--filter-tcp=443 --hostlist-domains=/ {
      count++
      sub(/--hostlist-domains= --/, "--hostlist-domains=none.dom --")
      if (target > 0 && count == target) {
        sub(/--hostlist-domains=none\.dom --/, "--hostlist-domains= --")
        changed=1
      }
    }
    {print}
    END{exit((target==0 || changed)?0:1)}
  ' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
}
