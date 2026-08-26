#!/bin/sh

Z2R_CURL_UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36'

orch_scope_validate() {
  local scope="${1:-}" profile="${2:-}" proto="${3:-}" strategy="${4:-}" max custom_domain=0
  printf '%s' "$scope$profile$proto$strategy" | grep -q '[[:cntrl:]]' && { echo "Lock values must not contain tabs or newlines" >&2; return 1; }
  printf '%s' "$scope" | grep -Eq '^(default|mark:[0-9]+)$' || { echo "Invalid lock scope: $scope" >&2; return 1; }
  # Legacy custom-domain wrappers use the hostname as profile and TLS only.
  # Keep this explicit and restrictive instead of treating arbitrary strings
  # as profile identifiers.
  if [ "$scope" = "default" ] && printf '%s' "$profile" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'; then
    custom_domain=1
    case "$strategy:$proto" in
      auto:*|clear:*) ;;
      *:tls) ;;
      *) echo "Protocol $proto is not valid for custom domain $profile" >&2; return 1 ;;
    esac
  else
    [ -n "$(config_profile_proto_list "$profile")" ] || { echo "Invalid lock profile: $profile" >&2; return 1; }
    printf '%s\n' "$(config_profile_proto_list "$profile")" | tr ' ' '\n' | grep -Fxq "$proto" || { echo "Protocol $proto is not valid for profile $profile" >&2; return 1; }
  fi
  case "$strategy" in auto|clear|0) return 0 ;; esac
  printf '%s' "$strategy" | grep -Eq '^[1-9][0-9]*$' || { echo "Invalid lock strategy: $strategy" >&2; return 1; }
  if [ "$custom_domain" -eq 1 ]; then
    # Custom-domain probing uses the TCP_Custom/profile-3 strategy range.
    max="$(config_profile_max_strategy 3 "${CONFIG_FILE:-}")"
  else
    max="$(config_profile_max_strategy "$profile" "${CONFIG_FILE:-}")"
  fi
  if [ "$max" -gt 0 ] 2>/dev/null; then
    [ "$strategy" -le "$max" ] 2>/dev/null || { echo "Strategy $strategy is outside profile $profile range" >&2; return 1; }
  fi
}

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

# Parse a non-negative decimal or hexadecimal config number without eval.
config_client_scope_num() {
  local value="$1" digits
  case "$value" in
    0x[0-9a-fA-F]*|0X[0-9a-fA-F]*) printf '%u\n' "$((value))" 2>/dev/null ;;
    ''|*[!0-9]*) return 1 ;;
    *)
      digits="$(printf '%s' "$value" | sed 's/^0*//')"
      [ -n "$digits" ] || digits=0
      printf '%u\n' "$((digits))" 2>/dev/null
      ;;
  esac
}

# Ensure optional client-mark settings exist in fresh and legacy configs.
# Invalid or conflicting masks are disabled so nfqws2 keeps the safe no-op path.
config_client_scope_ensure() {
  local cfg="$1" enable mask shift max desync_mark desync_postnat
  local mask_n shift_n max_n desync_mark_n desync_postnat_n
  [ -f "$cfg" ] || return 1
  config_var_exists "$cfg" CLIENT_SCOPE_ENABLE || printf '%s\n' 'CLIENT_SCOPE_ENABLE=0' >> "$cfg"
  config_var_exists "$cfg" CLIENT_SCOPE_MARK_MASK || printf '%s\n' 'CLIENT_SCOPE_MARK_MASK=' >> "$cfg"
  config_var_exists "$cfg" CLIENT_SCOPE_MARK_SHIFT || printf '%s\n' 'CLIENT_SCOPE_MARK_SHIFT=0' >> "$cfg"
  config_var_exists "$cfg" CLIENT_SCOPE_MARK_MAX || printf '%s\n' 'CLIENT_SCOPE_MARK_MAX=255' >> "$cfg"
  enable="$(config_get_var "$cfg" CLIENT_SCOPE_ENABLE)"; mask="$(config_get_var "$cfg" CLIENT_SCOPE_MARK_MASK)"
  shift="$(config_get_var "$cfg" CLIENT_SCOPE_MARK_SHIFT)"; max="$(config_get_var "$cfg" CLIENT_SCOPE_MARK_MAX)"
  [ "$enable" = 0 ] && [ -z "$mask" ] && return 0
  case "$enable" in 0|1) ;; *) config_set_var "$cfg" CLIENT_SCOPE_ENABLE 0; return 0;; esac
  mask_n="$(config_client_scope_num "$mask")" || { config_set_var "$cfg" CLIENT_SCOPE_ENABLE 0; return 0; }
  shift_n="$(config_client_scope_num "$shift")" || { config_set_var "$cfg" CLIENT_SCOPE_ENABLE 0; return 0; }
  max_n="$(config_client_scope_num "$max")" || { config_set_var "$cfg" CLIENT_SCOPE_ENABLE 0; return 0; }
  desync_mark="$(config_get_var "$cfg" DESYNC_MARK)"
  desync_postnat="$(config_get_var "$cfg" DESYNC_MARK_POSTNAT)"
  desync_mark_n="$(config_client_scope_num "$desync_mark")" || desync_mark_n=0
  desync_postnat_n="$(config_client_scope_num "$desync_postnat")" || desync_postnat_n=0
  if [ "$shift_n" -gt 31 ] || [ "$max_n" -gt 255 ] ||
     [ $((mask_n & desync_mark_n)) -ne 0 ] ||
     [ $((mask_n & desync_postnat_n)) -ne 0 ]; then
    config_set_var "$cfg" CLIENT_SCOPE_ENABLE 0
  fi
}

config_client_scope_apply() {
  local old_cfg="$1" new_cfg="$2" v
  [ -f "$old_cfg" ] && [ -f "$new_cfg" ] || return 0
  for v in ENABLE MARK_MASK MARK_SHIFT MARK_MAX; do
    config_var_exists "$old_cfg" "CLIENT_SCOPE_$v" || continue
    config_set_var "$new_cfg" "CLIENT_SCOPE_$v" "$(config_get_var "$old_cfg" "CLIENT_SCOPE_$v")"
  done
  config_client_scope_ensure "$new_cfg"
}

config_sed_ereg() {
  if printf "x" | sed -E 's/x/x/' >/dev/null 2>&1; then
    printf '%s' "-E"
  else
    printf '%s' "-r"
  fi
}

# Пары стандартного и автоматического блоков, фактически присутствующие в config.
config_auto_pair_ids() {
  local cfg id ids found mode auto_begin auto_end
  cfg="$(config_get_file "$1")" || return 1
  mode="${2:-paired}"

  [ "$(grep -c '^#Z2R_AUTO_STANDARD_BEGIN$' "$cfg")" -eq 1 ] || return 1
  [ "$(grep -c '^#Z2R_AUTO_STANDARD_END$' "$cfg")" -eq 1 ] || return 1
  [ "$(grep -c '^#Z2R_AUTO_BEGIN$' "$cfg")" -eq 1 ] || return 1
  [ "$(grep -c '^#Z2R_AUTO_END$' "$cfg")" -eq 1 ] || return 1

  ids="$(sed -n 's/^#Z2R_AUTO_STANDARD_\([[:alnum:]]\+\)_BEGIN$/\1/p' "$cfg")"
  for id in $ids; do
    [ "$(grep -c "^#Z2R_AUTO_STANDARD_${id}_BEGIN$" "$cfg")" -eq 1 ] || return 1
    [ "$(grep -c "^#Z2R_AUTO_STANDARD_${id}_END$" "$cfg")" -eq 1 ] || return 1
    if [ "$mode" != "standard" ]; then
      auto_begin="$(grep -c "^#Z2R_AUTO_${id}_BEGIN$" "$cfg")"
      auto_end="$(grep -c "^#Z2R_AUTO_${id}_END$" "$cfg")"
      [ "$auto_begin" -eq 0 ] && [ "$auto_end" -eq 0 ] && continue
      [ "$auto_begin" -eq 1 ] && [ "$auto_end" -eq 1 ] || return 1
    fi
    printf '%s\n' "$id"
    found=1
  done
  [ "$found" = "1" ]
}

config_auto_layout_valid() {
  local cfg standard_ids auto_ids
  cfg="$(config_get_file "$1")" || return 1
  standard_ids="$(config_auto_pair_ids "$cfg" standard)" || return 1
  auto_ids="$(config_auto_pair_ids "$cfg")" || return 1
  [ "$(printf '%s\n' "$standard_ids" | tr '\n' ' ')" = "1 2 3 4 8 3S 9 " ] || return 1
  [ "$(printf '%s\n' "$auto_ids" | tr '\n' ' ')" = "3 4 9 " ] || return 1
  [ "$(grep -c '^#Z2R_AUTO_FALLBACK_WAS=[01]$' "$cfg")" -eq 1 ]
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
  blob_file="$(sed -n -E 's#.*--blob=maxru:@/opt/(zapret2|zator)/files/fake/([^[:space:]]+).*#\2#p' "$cfg" | head -n1)"
  [ -n "$blob_file" ] && echo "$blob_file" || echo "неизвестно"
}

config_udp_games_active() {
  local cfg="$1" blk
  blk="$(sed -n '/#Стратегии для игрового UDP/,/^[[:space:]]*--new[[:space:]]*$/p' "$cfg" 2>/dev/null)"
  if printf "%s\n" "$blk" | grep -Eq '^[[:space:]]*--skip[[:space:]]+--filter-udp=1026'; then
    return 1
  fi
  printf "%s\n" "$blk" | grep -Eq '^[[:space:]]*--filter-udp=1026'
}

fwtype_nft_available() {
  if [ "$OSystem" = "entware" ]; then
    return 1
  fi
  command -v nft >/dev/null 2>&1 || return 1
  nft list tables >/dev/null 2>&1
}

fwtype_iptables_available() {
  command -v iptables >/dev/null 2>&1 || return 1
  iptables -L -n >/dev/null 2>&1
}

fwtype_unavailable_reason() {
  if [ "$1" = "nftables" ] && [ "$OSystem" = "entware" ]; then
    echo "на Keenetic/Entware работает только iptables"
  elif [ "$1" = "nftables" ]; then
    echo "нет утилиты nft или поддержки nftables в ядре"
  else
    echo "нет утилиты iptables или поддержки iptables в ядре"
  fi
}

# Client-scope firewall is isolated from zapret/policy rules. Missing backends
# are a safe no-op so legacy installs keep working.
client_scope_firewall_script() {
  local backend="${CLIENT_SCOPE_FIREWALL_BACKEND:-${FWTYPE:-}}" cfg
  if [ -z "$backend" ]; then
    cfg="$(config_get_file 2>/dev/null || true)"
    [ -n "$cfg" ] && backend="$(config_get_var "$cfg" FWTYPE 2>/dev/null || true)"
  fi
  case "${backend:-iptables}" in
    nftables|nft) echo "${ZATOR_ROOT:-/opt/zator}/firewall/client-scope-nft.sh" ;;
    iptables|*) echo "${ZATOR_ROOT:-/opt/zator}/firewall/client-scope-iptables.sh" ;;
  esac
}

client_scope_firewall_action() {
  local action="$1" script shell rc
  [ "$action" = cleanup ] || [ "${CLIENT_SCOPE_ENABLE:-0}" = 1 ] || return 0
  script="$(client_scope_firewall_script)"
  [ -f "$script" ] || return 0
  # Run in a subshell so Entware's /opt/bin PATH does not leak to the caller.
  (
    PATH="/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin:${PATH:-}"
    export PATH
    shell="$(command -v bash 2>/dev/null || true)"
    if [ -n "$shell" ] && [ -x "$shell" ]; then
      "$shell" "$script" "$action"
    elif [ -x "$script" ]; then
      "$script" "$action"
    else
      exit 127
    fi
  )
  rc=$?
  [ "$rc" -eq 0 ] || {
    echo "client-scope firewall $action failed; continuing safely" >&2
    return "$rc"
  }
}

client_scope_lua_config_sync() {
  local cfg="${1:-${ZAPRET2_ROOT:-/opt/zapret2}/config}" file tmp
  local enable mask shift max desync postnat
  [ -f "$cfg" ] || return 0
  file="${ZATOR_ROOT:-/opt/zator}/lua/client-scope-config.lua"
  tmp="${file}.tmp.$$"
  enable="$(config_get_var "$cfg" CLIENT_SCOPE_ENABLE 2>/dev/null || printf 0)"
  [ "$enable" = 1 ] || enable=0
  mask="$(config_client_scope_num "$(config_get_var "$cfg" CLIENT_SCOPE_MARK_MASK 2>/dev/null || true)" 2>/dev/null || printf 0)"
  shift="$(config_client_scope_num "$(config_get_var "$cfg" CLIENT_SCOPE_MARK_SHIFT 2>/dev/null || true)" 2>/dev/null || printf 0)"
  max="$(config_client_scope_num "$(config_get_var "$cfg" CLIENT_SCOPE_MARK_MAX 2>/dev/null || true)" 2>/dev/null || printf 255)"
  desync="$(config_client_scope_num "$(config_get_var "$cfg" DESYNC_MARK 2>/dev/null || true)" 2>/dev/null || printf 1073741824)"
  postnat="$(config_client_scope_num "$(config_get_var "$cfg" DESYNC_MARK_POSTNAT 2>/dev/null || true)" 2>/dev/null || printf 536870912)"
  mkdir -p "$(dirname "$file")" || return 1
  {
    printf '%s\n' '-- Generated by z2r; do not edit.'
    printf 'CLIENT_SCOPE_ENABLE=%s\n' "$enable"
    printf 'CLIENT_SCOPE_MARK_MASK=%s\n' "$mask"
    printf 'CLIENT_SCOPE_MARK_SHIFT=%s\n' "$shift"
    printf 'CLIENT_SCOPE_MARK_MAX=%s\n' "$max"
    printf 'DESYNC_MARK=%s\n' "$desync"
    printf 'DESYNC_MARK_POSTNAT=%s\n' "$postnat"
  } > "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

client_scope_firewall_reconcile() {
  local cfg="${ZAPRET2_ROOT:-/opt/zapret2}/config" enabled
  client_scope_lua_config_sync "$cfg" || return 1
  enabled="$(config_get_var "$cfg" CLIENT_SCOPE_ENABLE 2>/dev/null || printf 0)"
  CLIENT_SCOPE_ENABLE="$enabled"
  if [ "$enabled" = 1 ]; then
    client_scope_firewall_action apply
  else
    client_scope_firewall_action cleanup
  fi
}

client_scope_config_prepare() {
  local cfg="${1:-${ZAPRET2_ROOT:-/opt/zapret2}/config}"
  config_set_var "$cfg" CLIENT_SCOPE_MARK_MASK 0xff00 || return 1
  config_set_var "$cfg" CLIENT_SCOPE_MARK_SHIFT 8 || return 1
  config_set_var "$cfg" CLIENT_SCOPE_MARK_MAX 255 || return 1
}

config_mode_text() {
  local mode="$1"
  local cfg="$2"

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
      local fallback_blocks
      if grep -q '^#Z2R_AUTO_MODE=1$' "$cfg"; then
        echo "недоступен"
        return
      else
        fallback_blocks="$(sed -n '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/p' "$cfg"; sed -n '/#Z2R_FALLBACK_HTTP_BEGIN/,/#Z2R_FALLBACK_HTTP_END/p' "$cfg")"
      fi
      if printf '%s\n' "$fallback_blocks" | grep -q '^[[:space:]]*--skip[[:space:]]'; then
        echo "выключен"
      elif printf '%s\n' "$fallback_blocks" | grep -q '^[[:space:]]*--filter-tcp='; then
        echo "включен"
      else
        echo "неизвестно"
      fi
      ;;
    auto_mode)
      if grep -q '^#Z2R_AUTO_MODE=1$' "$cfg"; then
        echo "включен"
      elif grep -q '^#Z2R_AUTO_MODE=0$' "$cfg"; then
        echo "выключен"
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
      if ! config_var_exists "$cfg" NFQWS2_PORTS_UDP; then
        echo "Неизвестно"
      elif printf "%s" "$(config_get_var "$cfg" NFQWS2_PORTS_UDP)" | grep -Eq '(^|,)1026-65531(,|$)' \
           && config_udp_games_active "$cfg"; then
        echo "Включен"
      else
        echo "Выключен"
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

config_last_modified() {
  local header
  header="$(sed -n 's/^# Last modified:[[:space:]]*//p' "$1" 2>/dev/null | head -n1 | tr -d '\r')"
  printf '%s\n' "${header:-Неизвестно}"
}

menu_config_snapshot() {
  local cfg="$1"

  MENU_FWTYPE="неизвестно"
  MENU_FLOWOFFLOAD="неизвестно"
  MENU_HOSTLIST="неизвестно"
  MENU_FALLBACK="неизвестно"
  MENU_AUTO_MODE="неизвестно"
  MENU_TLS_BLOB="неизвестно"
  MENU_RST_GUARD="выключен"
  MENU_UDP_GAMES="Неизвестно"
  MENU_PORTS="дефолт"
  MENU_CONFIG_DATE="Неизвестно"
  MENU_CLIENT_SCOPE="выключен"
  MENU_PROFILE_MAX_1=0
  MENU_PROFILE_MAX_2=0
  MENU_PROFILE_MAX_3=0
  MENU_PROFILE_MAX_4=0
  MENU_PROFILE_MAX_5=0
  MENU_PROFILE_MAX_6=0
  MENU_PROFILE_MAX_7=0
  MENU_PROFILE_MAX_8=0
  MENU_PROFILE_MAX_9=0

  [ -n "$cfg" ] && [ -f "$cfg" ] || return 0

  MENU_CONFIG_DATE="$(config_last_modified "$cfg")"

  local fwtype flowoffload mode_filter auto_mode has_skip has_filter_tcp
  local has_tls_maxru has_tls_default has_rst blob_file udp_games ports
  fwtype="" flowoffload="" mode_filter=""
  udp_games="" ports=""
  auto_mode="" has_skip=0 has_filter_tcp=0 has_tls_maxru=0 has_tls_default=0 has_rst=0 blob_file=""

  local _k _v _tmp _profile
  _tmp="/tmp/z2r_menu_cfg_$$"
  awk '
    function scan_strategies(line, num) {
      while (match(line, /strategy=[0-9]+/)) {
        num = substr(line, RSTART + 9, RLENGTH - 9) + 0
        if (in_template && num > tplmax[tpl]) tplmax[tpl] = num
        if (!in_template && key_active && num > keymax[key_active]) keymax[key_active] = num
        if (!in_template && pos_active && prof <= 9 && num > posmax[prof]) posmax[prof] = num
        if (!in_template && fb_profile && num > fbmax[fb_profile]) fbmax[fb_profile] = num
        line = substr(line, RSTART + RLENGTH)
      }
    }
    function import_template(line, imp) {
      imp = line
      sub(/^--import[=[:space:]]+/, "", imp)
      sub(/[[:space:]].*$/, "", imp)
      if (key_active && tplmax[imp] > keymax[key_active]) keymax[key_active] = tplmax[imp]
      if (pos_active && prof <= 9 && tplmax[imp] > posmax[prof]) posmax[prof] = tplmax[imp]
      if (fb_profile && tplmax[imp] > fbmax[fb_profile]) fbmax[fb_profile] = tplmax[imp]
    }
    { sub(/\r$/, "") }
    /^[[:space:]]*FWTYPE=/ {
      v = $0; sub(/^[[:space:]]*FWTYPE=/, "", v)
      print "_fwtype=" v
    }
    /^[[:space:]]*FLOWOFFLOAD=/ {
      v = $0; sub(/^[[:space:]]*FLOWOFFLOAD=/, "", v)
      print "_flowoffload=" v
    }
    /^[[:space:]]*MODE_FILTER=/ {
      v = $0; sub(/^[[:space:]]*MODE_FILTER=/, "", v)
      print "_mode_filter=" v
    }
    /^[[:space:]]*NFQWS2_PORTS_TCP=/ {
      v = $0; sub(/^[[:space:]]*NFQWS2_PORTS_TCP=/, "", v)
      ports_tcp = v
    }
    /^[[:space:]]*NFQWS2_PORTS_UDP=/ {
      v = $0; sub(/^[[:space:]]*NFQWS2_PORTS_UDP=/, "", v)
      ports_udp = v
    }
    /^#Z2R_AUTO_MODE=[01][[:space:]]*$/ {
      v = $0; sub(/^#Z2R_AUTO_MODE=/, "", v)
      print "_auto_mode=" v
    }
    /#Стратегии для игрового UDP/ { in_game_udp = 1 }
    in_game_udp && /^[[:space:]]*--new[[:space:]]*$/ { in_game_udp = 0 }
    in_game_udp && /^[[:space:]]*--skip[[:space:]]+--filter-udp=1026/ { game_udp_skip = 1 }
    in_game_udp && /^[[:space:]]*--filter-udp=1026/ { game_udp_on = 1 }
    /^[[:space:]]*#Z2R_FALLBACK_BEGIN[[:space:]]*$/      { in_fb = 1; fb_profile = 8 }
    /^[[:space:]]*#Z2R_FALLBACK_END[[:space:]]*$/        { in_fb = 0; fb_profile = 0 }
    /^[[:space:]]*#Z2R_FALLBACK_HTTP_BEGIN[[:space:]]*$/ { in_fb = 1; fb_profile = 9 }
    /^[[:space:]]*#Z2R_FALLBACK_HTTP_END[[:space:]]*$/   { in_fb = 0; fb_profile = 0 }
    {
      if (in_fb) {
        if ($0 ~ /^[[:space:]]*--skip([[:space:]]|$)/) print "_has_skip=1"
        if ($0 ~ /^[[:space:]]*--filter-tcp=/) print "_has_filter_tcp=1"
      }
      if ($0 ~ /--lua-desync=/ && $0 ~ /blob=maxru/ && $0 !~ /strategy=26/) print "_has_tls_maxru=1"
      if ($0 ~ /--lua-desync=/ && $0 ~ /blob=fake_default_tls/ && $0 !~ /strategy=26/) print "_has_tls_default=1"
      if ($0 ~ /--lua-desync=rst_guard_locked:key=/) print "_has_rst=1"
      if (blob_done == 0 && match($0, /--blob=maxru:@\/opt\/(zapret2|zator)\/files\/fake\/[^[:space:]]+/)) {
        # Имя файла извлекаем независимо от корня (zapret2|zator).
        bs = $0
        sub(/^.*--blob=maxru:@\/opt\/(zapret2|zator)\/files\/fake\//, "", bs)
        sub(/[[:space:]].*$/, "", bs)
        print "_blob_file=" bs
        blob_done = 1
      }

      if ($0 ~ /^NFQWS2_OPT="/) inopt = 1
      if (inopt) {
        if ($0 ~ /^--template=/) {
          in_template = 1
          key_active = 0
          pos_active = 0
          tpl = $0
          sub(/^--template=/, "", tpl)
          sub(/[[:space:]].*$/, "", tpl)
        } else if ($0 ~ /^[[:space:]]*--new[[:space:]]*$/) {
          in_template = 0
          key_active = 0
          pos_active = 0
          tpl = ""
        } else if (!in_template) {
          if (!pos_active && $0 ~ /^--/ && $0 !~ /^--new/ &&
              $0 !~ /^--lua-init/ && $0 !~ /^--blob=/ && $0 !~ /^--reasm-disable/) {
            prof++
            pos_active = 1
          }
          if (match($0, /--lua-desync=(circular_locked|circular_quality|rst_guard_locked):key=[0-9]+/)) {
            key_active = substr($0, RSTART, RLENGTH)
            sub(/^.*:key=/, "", key_active)
            key_active += 0
            if (key_active < 1 || key_active > 9) key_active = 0
          }
          if ($0 ~ /^--import([=[:space:]]|$)/) import_template($0)
        }
        scan_strategies($0)
        if ($0 ~ /^"$/) inopt = 0
      }
    }
    END {
      if (ports_udp == "") out_udp = "Неизвестно"
      else {
        udp_re = "(^|,)1026-65531(,|$)"
        if (ports_udp ~ udp_re && game_udp_on && !game_udp_skip) out_udp = "Включен"
        else out_udp = "Выключен"
      }
      n = 0
      for (idx = 1; idx <= 2; idx++) {
        if (idx == 1) { line = ports_tcp; anchor = "80" }
        else          { line = ports_udp; anchor = "443" }
        u = ""; started = 0
        nc = split(line, tk, ",")
        for (i = 1; i <= nc; i++) {
          if (!started && tk[i] == anchor) started = 1
          if (!started && tk[i] != "") u = (u == "" ? u : u ",") tk[i]
        }
        if (u != "") { nu = split(u, dummy, ","); n += nu }
      }
      out_ports = (n > 0 ? "добавлено портов: " n : "дефолт")
      print "_udp_games=" out_udp
      print "_ports=" out_ports
      for (pid = 1; pid <= 9; pid++) {
        value = keymax[pid] + 0
        if (!value && (pid == 8 || pid == 9)) value = fbmax[pid] + 0
        if (!value) value = posmax[pid] + 0
        print "_profile_max_" pid "=" value
      }
    }
  ' "$cfg" > "$_tmp"

  while IFS='=' read -r _k _v; do
    case "$_k" in
      _fwtype) fwtype="$_v" ;;
      _flowoffload) flowoffload="$_v" ;;
      _mode_filter) mode_filter="$_v" ;;
      _auto_mode) auto_mode="$_v" ;;
      _has_skip) has_skip="$_v" ;;
      _has_filter_tcp) has_filter_tcp="$_v" ;;
      _has_tls_maxru) has_tls_maxru="$_v" ;;
      _has_tls_default) has_tls_default="$_v" ;;
      _has_rst) has_rst="$_v" ;;
      _blob_file) blob_file="$_v" ;;
      _udp_games) udp_games="$_v" ;;
      _ports) ports="$_v" ;;
      _profile_max_[1-9])
        _profile="${_k#_profile_max_}"
        printf -v "MENU_PROFILE_MAX_${_profile}" '%s' "$_v"
        ;;
    esac
  done < "$_tmp"
  rm -f "$_tmp"

  MENU_FWTYPE="$fwtype"
  MENU_FLOWOFFLOAD="$flowoffload"

  case "$mode_filter" in
    autohostlist) MENU_HOSTLIST="авто" ;;
    hostlist) MENU_HOSTLIST="по листам" ;;
  esac

  case "$auto_mode" in
    1) MENU_AUTO_MODE="включен" ;;
    0) MENU_AUTO_MODE="выключен" ;;
  esac

  if [ "$auto_mode" = "1" ]; then
    MENU_FALLBACK="недоступен"
  elif [ "$has_skip" = "1" ]; then
    MENU_FALLBACK="выключен"
  elif [ "$has_filter_tcp" = "1" ]; then
    MENU_FALLBACK="включен"
  fi

  local _blob_mode=""
  if [ "$has_tls_maxru" = "1" ] && [ "$has_tls_default" = "0" ]; then
    _blob_mode="maxru"
  elif [ "$has_tls_default" = "1" ] && [ "$has_tls_maxru" = "0" ]; then
    _blob_mode="fake_default_tls"
  elif [ "$has_tls_default" = "1" ] && [ "$has_tls_maxru" = "1" ]; then
    _blob_mode="mixed"
  fi
  case "$_blob_mode" in
    fake_default_tls) MENU_TLS_BLOB="default" ;;
    mixed) MENU_TLS_BLOB="mixed" ;;
    *)
      [ -n "$blob_file" ] && MENU_TLS_BLOB="$blob_file"
      ;;
  esac

  # Присвоения через if, а не [ ... ] &&: пустые значения не должны отдавать
  # из функции ненулевой статус (вызывается как инструкция под set -e в z2r.sh).
  if [ "$has_rst" = "1" ]; then
    MENU_RST_GUARD="включен"
  fi
  if [ -n "$udp_games" ]; then
    MENU_UDP_GAMES="$udp_games"
  fi
  if [ -n "$ports" ]; then
    MENU_PORTS="$ports"
  fi
  if [ "$(config_get_var "$cfg" CLIENT_SCOPE_ENABLE 2>/dev/null || printf 0)" = "1" ]; then
    MENU_CLIENT_SCOPE="включен"
  fi
  return 0
}

config_profile_max_strategy() {
  local profile="$1"
  local cfg keyed_max
  cfg="$(config_get_file "$2")" || { echo 0; return 0; }

  # Профиль задаётся логическим key=N, а не позицией блока между --new.
  # Порядок блоков может меняться (в том числе в локальных конфигах и авто-режиме),
  # поэтому сначала ищем стратегии в блоках с нужным ключом.
  keyed_max="$(awk -v pid="$profile" '
      function scan_strategies(line) {
          while (match(line, /strategy=[0-9]+/)) {
              num=substr(line, RSTART+9, RLENGTH-9)+0
              if (in_template && num>tplmax[tpl]) tplmax[tpl]=num
              if (!in_template && active && num>max) max=num
              line=substr(line, RSTART+RLENGTH)
          }
      }
      BEGIN {
          inopt=0
          in_template=0
          active=0
          tpl=""
          max=0
          key_re="--lua-desync=(circular_locked|circular_quality|rst_guard_locked):key=" pid "([^0-9]|$)"
      }
      /^NFQWS2_OPT="/ {inopt=1}
      inopt {
          if ($0 ~ /^--template=/) {
              in_template=1
              active=0
              tpl=$0
              sub(/^--template=/, "", tpl)
              sub(/[[:space:]].*$/, "", tpl)
          } else if ($0 ~ /^[[:space:]]*--new[[:space:]]*$/) {
              in_template=0
              active=0
              tpl=""
          } else if (!in_template && $0 ~ key_re) {
              active=1
          }
          if (!in_template && active && $0 ~ /^--import([=[:space:]]|$)/) {
              imp=$0
              sub(/^--import[=[:space:]]+/, "", imp)
              sub(/[[:space:]].*$/, "", imp)
              if (tplmax[imp]>max) max=tplmax[imp]
          }
          scan_strategies($0)
          if ($0 ~ /^"$/) exit
      }
      END {print max}
  ' "$cfg")"
  if [ -n "$keyed_max" ] && [ "$keyed_max" -gt 0 ]; then
    echo "$keyed_max"
    return 0
  fi

  # Совместимость со старыми конфигами без логических key=N.
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

config_profile_proto_list() {
  case "$1" in
    1) echo "tls http" ;;
    2|3|4|8) echo "tls" ;;
    5|6|7) echo "udp" ;;
    9) echo "http" ;;
    *) echo "" ;;
  esac
}

# Человекочитаемое имя профиля для меню и WebUI.
config_profile_title() {
  case "$1" in
    1) echo "TCP 443 (YouTube)" ;;
    2) echo "TCP 443 (Googlevideo)" ;;
    3) echo "TCP 443 (RKN)" ;;
    4) echo "TCP 443 (Discord)" ;;
    5) echo "UDP 443 (QUIC)" ;;
    6) echo "UDP Voice (Discord/STUN)" ;;
    7) echo "UDP Games (1026-65531)" ;;
    8) echo "Fallback TLS" ;;
    9) echo "Fallback HTTP" ;;
    *) echo "Профиль $1" ;;
  esac
}

# Централизованный setter режима Client scopes (CLI + будущий WebUI).
# $1 = 0|1. Обновляет config, Lua-глобалы и firewall; перезапускает работающий
# демон, т.к. client-scope-config.lua загружается однократно при старте nfqws2
# через --lua-init и без рестарта новые глобалы не вступят в силу.
client_scope_mode_set() {
  local want="$1" cfg backup rc was_running=0
  cfg="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  [ -f "$cfg" ] || { echo "Не найден config: $cfg" >&2; return 1; }
  if [ "$want" = 1 ]; then
    [ -n "$(client_scope_ip_list 2>/dev/null)" ] || { echo "Нельзя включить Client scopes: нет IP-маппингов" >&2; return 1; }
  elif [ "$want" != 0 ]; then
    echo "Некорректное состояние Client scopes: $want" >&2
    return 2
  fi

  backup="${cfg}.client-scope.$$"
  cp "$cfg" "$backup" || return 1
  if [ -n "${ZAPRET2_INIT:-}" ] && zapret2_running; then
    was_running=1
  fi

  if config_set_var "$cfg" CLIENT_SCOPE_ENABLE "$want"; then :; else
    rc=$?
    mv -f "$backup" "$cfg" 2>/dev/null || true
    return "$rc"
  fi
  if [ "$want" = 1 ]; then
    if client_scope_config_prepare "$cfg"; then :; else
      rc=$?
      _client_scope_mode_rollback "$cfg" "$backup" 0 || true
      return "$rc"
    fi
  fi
  if client_scope_firewall_reconcile; then :; else
    rc=$?
    _client_scope_mode_rollback "$cfg" "$backup" 0 || true
    return "$rc"
  fi
  if client_scope_daemon_reload "$was_running"; then :; else
    rc=$?
    _client_scope_mode_rollback "$cfg" "$backup" "$was_running" || true
    return "$rc"
  fi

  rm -f "$backup" 2>/dev/null || true
  return 0
}

# Best-effort откат config + производных Lua/firewall/daemon после сбоя setter'а.
_client_scope_mode_rollback() {
  local cfg="$1" backup="$2" was_running="${3:-0}"
  if ! mv -f "$backup" "$cfg"; then
    echo "Не удалось восстановить config после ошибки Client scopes" >&2
    return 1
  fi
  client_scope_firewall_reconcile || true
  [ "$was_running" = 1 ] && client_scope_daemon_reload 1 || true
  return 0
}

# client-scope-config.lua загружается однократно при старте nfqws2 (--lua-init),
# поэтому работающему демону нужен рестарт, чтобы увидеть новые глобалы.
# $1=1 принудительно выполняет restart (для восстановления после неудачного restart).
client_scope_daemon_reload() {
  local force="${1:-0}"
  [ -n "${ZAPRET2_INIT:-}" ] || return 0
  [ "$force" = 1 ] || zapret2_running || return 0
  z2r_service_action restart
}

csv_contains_token() {
  local csv="$1"
  local token="$2"
  local old_ifs="$IFS"
  local t

  [ -n "$csv" ] || return 1
  IFS=','
  for t in $csv; do
    [ "$t" = "$token" ] && { IFS="$old_ifs"; return 0; }
  done
  IFS="$old_ifs"
  return 1
}

csv_add_tokens() {
  local csv="$1"
  local tokens="$2"
  local old_ifs="$IFS"
  local token out

  out="$csv"
  IFS=','
  for token in $tokens; do
    [ -n "$token" ] || continue
    if ! csv_contains_token "$out" "$token"; then
      if [ -n "$out" ]; then
        out="$out,$token"
      else
        out="$token"
      fi
    fi
  done
  IFS="$old_ifs"
  printf '%s' "$out"
}

csv_remove_tokens() {
  local csv="$1"
  local tokens="$2"
  local old_ifs="$IFS"
  local token current out="" keep remove

  IFS=','
  for current in $csv; do
    [ -n "$current" ] || continue
    keep=1
    for remove in $tokens; do
      if [ "$current" = "$remove" ]; then
        keep=0
        break
      fi
    done
    if [ "$keep" -eq 1 ]; then
      if [ -n "$out" ]; then
        out="$out,$current"
      else
        out="$current"
      fi
    fi
  done
  IFS="$old_ifs"
  printf '%s' "$out"
}

config_profile_voice_ports() {
  echo "50000-50099,1400,3478-3481,5349,19294-19344"
}

config_profile_voice_ports_apply() {
  local cfg="$1"
  local state="$2"
  local ports new_ports

  [ -f "$cfg" ] || return 0
  ports="$(config_profile_voice_ports)"
  case "$state" in
    0)
      new_ports="$(csv_remove_tokens "$(config_get_var "$cfg" NFQWS2_PORTS_UDP)" "$ports")"
      [ -n "$new_ports" ] || new_ports="443"
      ;;
    *)
      new_ports="$(csv_add_tokens "$(config_get_var "$cfg" NFQWS2_PORTS_UDP)" "$ports")"
      ;;
  esac
  [ "$(config_get_var "$cfg" NFQWS2_PORTS_UDP)" = "$new_ports" ] || config_set_var "$cfg" NFQWS2_PORTS_UDP "$new_ports"
}

profile_config_voice_ports_changed() {
  [ "$1" = "6" ] && [ "$(config_get_var "$2" NFQWS2_PORTS_UDP)" != "$3" ]
}

profile_config_orch_set() {
  local profile="$1"
  local proto="$2"
  local strategy="$3"
  local saved_lock_file="$ORCH_LOCK_FILE"
  local rc=0

  if [ "$profile" = "8" ] || [ "$profile" = "9" ]; then
    ORCH_LOCK_FILE="$ORCH_DIR/locked.manual.tsv"
  fi
  orch_scoped_locked_set default "$profile" "$proto" "$strategy" || rc=$?
  ORCH_LOCK_FILE="$saved_lock_file"
  return "$rc"
}

profile_config_orch_clear() {
  local profile="$1"
  local proto="$2"
  local saved_lock_file="$ORCH_LOCK_FILE"
  local rc=0

  if [ "$profile" = "8" ] || [ "$profile" = "9" ]; then
    ORCH_LOCK_FILE="$ORCH_DIR/locked.manual.tsv"
  fi
  orch_scoped_locked_clear default "$profile" "$proto" || rc=$?
  ORCH_LOCK_FILE="$saved_lock_file"
  return "$rc"
}

profile_config_apply_state() {
  local profile="$1"
  local proto_list="$2"
  local state="$3"
  local cfg="$4"
  local proto normalized max

  cfg="$(config_get_file "$cfg")" || return 0
  [ -n "$proto_list" ] || proto_list="$(config_profile_proto_list "$profile")"
  [ -n "$proto_list" ] || return 0
  normalized="$(profile_state_normalize "$state")" || return 2

  case "$normalized" in
    auto)
      for proto in $proto_list; do
        profile_config_orch_clear "$profile" "$proto" || return 1
      done
      if [ "$profile" = "6" ]; then
        config_profile_voice_ports_apply "$cfg" auto
      fi
      ;;
    0)
      for proto in $proto_list; do
        profile_config_orch_set "$profile" "$proto" 0 || return 1
      done
      if [ "$profile" = "6" ]; then
        config_profile_voice_ports_apply "$cfg" 0
      fi
      ;;
    *)
      max="$(config_profile_max_strategy "$profile" "$cfg")"
      if ! printf '%s' "$max" | grep -Eq '^[1-9][0-9]*$' || [ "$normalized" -gt "$max" ]; then
        echo "Пропуск сохранённого состояния профиля $profile: стратегия $normalized вне диапазона."
        return 0
      fi
      for proto in $proto_list; do
        profile_config_orch_set "$profile" "$proto" "$normalized" || return 1
      done
      if [ "$profile" = "6" ]; then
        config_profile_voice_ports_apply "$cfg" "$normalized"
      fi
      ;;
  esac
}

profile_state_set_and_apply() {
  local profile="$1"
  local proto_list="$2"
  local state="$3"
  local cfg="$4"
  local proto normalized

  normalized="$(profile_state_normalize "$state")" || return 1
  [ -n "$proto_list" ] || proto_list="$(config_profile_proto_list "$profile")"
  [ -n "$proto_list" ] || return 1

  if [ "${ORCH_ACTIVE_SCOPE:-default}" != default ]; then
    # Контекст mark'и (client scopes): фиксируем только per-mark лок.
    # Глобальный profile state и config не трогаем — они описывают default-скоп.
    for proto in $proto_list; do
      if [ "$normalized" = "auto" ]; then
        orch_scoped_locked_clear "$ORCH_ACTIVE_SCOPE" "$profile" "$proto" || return 1
      else
        orch_scoped_locked_set "$ORCH_ACTIVE_SCOPE" "$profile" "$proto" "$normalized" || return 1
      fi
    done
    return 0
  fi

  for proto in $proto_list; do
    if [ "$normalized" = "auto" ]; then
      profile_state_clear "$profile" "$proto" || return 1
    else
      profile_state_set "$profile" "$proto" "$normalized" || return 1
    fi
  done
  profile_config_apply_state "$profile" "$proto_list" "$normalized" "$cfg"
}

profile_apply_all() {
  local cfg="$1"
  local file profile proto state rest rc

  cfg="$(config_get_file "$cfg")" || return 0
  file="$(profile_state_file)"
  [ -f "$file" ] || return 0

  while read -r profile proto state rest; do
    case "$profile" in
      ""|\#*) continue ;;
    esac
    if [ -z "$state" ]; then
      state="$proto"
      proto="$(config_profile_proto_list "$profile")"
    fi
    if profile_config_apply_state "$profile" "$proto" "$state" "$cfg"; then
      continue
    else
      rc=$?
    fi
    if [ "$rc" -eq 2 ]; then
      echo "Пропуск сохранённого состояния профиля $profile: некорректное состояние '$state'."
      continue
    fi
    return "$rc"
  done < "$file"
  return 0
}

z2r_service_action() {
  local action="$1"
  [ -n "${ZAPRET2_INIT:-}" ] || return 1
  if command -v setsid >/dev/null 2>&1; then
    setsid "$ZAPRET2_INIT" "$action"
  else
    ( trap '' INT QUIT HUP; exec "$ZAPRET2_INIT" "$action" )
  fi
}
