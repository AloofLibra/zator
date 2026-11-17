# --- Кастомные пользовательские стратегии (custom_strategies.tsv) -------------
# Пользовательские --lua-desync=стратегии, дописываемые в config после штатных
# стратегий выбранного блока. Хранение: extra_strats/cache/orchestra/
# custom_strategies.tsv (runtime-файл: в релизы не пакуется, едет в бэкапах
# z2r_backup_state_files). Номера strategy=N принадлежат инжектору: назначаются
# после текущего максимума блока и автоматически смещаются при обновлениях
# конфига; локи locked.tsv / locked.manual.tsv / scopes/*.tsv и auto_locked.tsv
# ремапятся по старым назначениям. Инжект идемпотентен (маркерные пары
# #Z2R_CUSTOM_<BLK>_BEGIN/END внутри блока), применяется во все пути перезаписи
# конфига (config_apply_from_default, установка) и из меню (п.1 -> 14).
# В отличие от tsv-override'ов (blob/sni/mode) меняет сам config — нужен
# рестарт zapret2.
#
# Формат TSV: id <TAB> block <TAB> spec <TAB> enabled <TAB> comment <TAB> assigned
#   id       — стабильный порядковый номер без дыр (сдвигается при удалении);
#   block    — tpl | p4 | p5 | p6 | p7 (см. custom_strategies_blocks);
#   spec     — канонический вид БЕЗ strategy=: группа или несколько групп через
#              « --lua-desync=» (комбо-стратегии, как строки 295+ конфига);
#   enabled  — 1 | 0 (выключенные не инжектятся, нумерация сжимается);
#   comment  — произвольная пометка (только в TSV и меню);
#   assigned — номер, назначенный последним инжектом (для ремапа локов).

CUSTOM_STRATS_FILE="${CUSTOM_STRATS_FILE:-${ORCH_DIR:-/opt/zator/extra_strats/cache/orchestra}/custom_strategies.tsv}"

# block <TAB> короткое имя <TAB> профили <TAB> протоколы <TAB> транспорт
custom_strategies_blocks() {
  printf 'tpl\tTCP TLS (профили 1/2/3/8 — общий набор)\t1 2 3 8\ttls http\ttcp\n'
  printf 'p4\tDiscord TCP (профиль 4)\t4\ttls\ttcp\n'
  printf 'p5\tQUIC (профиль 5, UDP 443)\t5\tudp\tudp\n'
  printf 'p6\tГолосовой UDP (профиль 6)\t6\tudp\tudp\n'
  printf 'p7\tИгровой UDP (профиль 7)\t7\tudp\tudp\n'
}

custom_strategies_block_field() {
  local block="$1" field="$2" row
  while IFS="$(printf '\t')" read -r b label profiles protos transport; do
    [ "$b" = "$block" ] || continue
    case "$field" in
      label) echo "$label" ;;
      profiles) echo "$profiles" ;;
      protos) echo "$protos" ;;
      transport) echo "$transport" ;;
    esac
    return 0
  done < <(custom_strategies_blocks)
  return 1
}

custom_strategies_block_valid() {
  custom_strategies_block_field "$1" label >/dev/null
}

custom_strategies_block_transport() {
  custom_strategies_block_field "$1" transport 2>/dev/null || echo tcp
}

custom_strategies_block_profiles() {
  custom_strategies_block_field "$1" profiles 2>/dev/null || echo ""
}

custom_strategies_block_protos() {
  custom_strategies_block_field "$1" protos 2>/dev/null || echo tls
}

custom_strategies_block_label() {
  custom_strategies_block_field "$1" label 2>/dev/null || echo "$1"
}

# Имена маркеров — в верхнем регистре (#Z2R_CUSTOM_P5_BEGIN), как в config.default.
custom_strategies_marker_begin() { local b="${1^^}"; echo "#Z2R_CUSTOM_${b}_BEGIN"; }
custom_strategies_marker_end()   { local b="${1^^}"; echo "#Z2R_CUSTOM_${b}_END"; }

# --- чтение TSV ---------------------------------------------------------------

# Печатает строки TSV (без комментариев): id block spec enabled comment assigned.
custom_strategies_list() {
  local filter_block="${1:-}"
  [ -f "$CUSTOM_STRATS_FILE" ] || return 0
  awk -F '\t' -v blk="$filter_block" '
    /^[[:space:]]*#/ || NF < 5 { next }
    blk != "" && $2 != blk { next }
    { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $(6) }
  ' "$CUSTOM_STRATS_FILE"
}

custom_strategies_count() {
  custom_strategies_list | wc -l | tr -d '[:space:]'
}

custom_strategies_next_id() {
  local max=0 id
  while IFS="$(printf '\t')" read -r id _rest; do
    case "$id" in ''|*[!0-9]*) continue ;; esac
    [ "$id" -gt "$max" ] && max="$id"
  done < <(custom_strategies_list)
  echo $((max + 1))
}

custom_strategies_row() {
  local id="$1"
  custom_strategies_list | awk -F '\t' -v want="$id" '$1 == want { print; exit }'
}

# --- нормализация ввода -------------------------------------------------------

# Приводит вставленную пользователем строку к каноническому виду: срезает
# ведущий «--lua-desync=» и хвостовые «:strategy=N» у каждой группы (номера
# принадлежат инжектору). stdout — канонический spec; rc=1, если strategy=
# остался в середине группы или строка пустая.
custom_strategies_normalize() {
  local input="$1" out="" g rest
  input="$(printf '%s' "$input" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  case "$input" in
    --lua-desync=*) input="${input#--lua-desync=}" ;;
  esac
  rest="${input// --lua-desync=/$'\x01'}"
  while IFS= read -r g; do
    # хвостовые :strategy=N срезаем (по одному с конца группы)
    while :; do
      case "$g" in
        *:strategy=[0-9][0-9]*) g="${g%:strategy=[0-9]*}" ;;
        *:strategy=[0-9]) g="${g%:strategy=[0-9]}" ;;
        *) break ;;
      esac
    done
    case "$g" in
      ""|*"strategy="*) return 1 ;;
    esac
    if [ -z "$out" ]; then out="$g"; else out="$out --lua-desync=$g"; fi
  done <<<"$(printf '%s\n' "${rest//$'\x01'/$'\n'}")"
  [ -n "$out" ] || return 1
  echo "$out"
}

# --- валидация ----------------------------------------------------------------

# Таблицы примитивов/параметров (зеркало строк config.default; при добавлении
# новых возможностей zapret2 расширять здесь). Z2R_CUSTOM_STRICT=0 понижает
# неизвестные ключи/флаги до предупреждения.
custom_strategies_primitives_tcp="fake multisplit multidisorder fakeddisorder fakedsplit fakemultisplit fakemultidisorder hostfakesplit send tls_client_hello_clone"
custom_strategies_primitives_udp="fake send udplen dnsclone"

custom_strategies_keys_tcp="fake_blob fallback host pos seqovl seqovl_pattern sni_first sni_snt_new tcp_seq tcp_ack tcp_ts fake_count"
custom_strategies_keys_udp="increment min pattern ipfrag_pos_udp"
custom_strategies_keys_both="blob repeats out_range ip_autottl ip6_autottl ip_ttl ip6_ttl ip_id payload"

custom_strategies_flags_tcp="tcp_md5 ip6_destopt disorder_after nofake1 nofake3 fake_all nodrop tcp_ts_up sni_del"
custom_strategies_flags_udp=""
custom_strategies_flags_both="badsum ipfrag ipfrag_disorder"

_custom_in_list() {
  local word="$1" list="$2" item
  for item in $list; do [ "$item" = "$word" ] && return 0; done
  return 1
}

# Объявленные в конфиге имена блобов (--blob=ИМЯ:@...) + встроенные/литеральные.
custom_strategies_blob_names() {
  local cfg="${1:-${ZAPRET2_ROOT:-/opt/zapret2}/config}"
  [ -f "$cfg" ] || cfg="${ZAPRET2_ROOT:-/opt/zapret2}/config.default"
  [ -f "$cfg" ] || return 0
  sed -n -E 's/^[[:space:]]*--blob=([A-Za-z0-9_]+):.*/\1/p' "$cfg" | sort -u
  printf '%s\n' fake_default_tls fake_default_http \
    clone_vk clone_hcaptcha clone_vk_fmd clone_hcaptcha_fms
}

_custom_blob_known() {
  local name="$1" cfg="$2" known
  case "$name" in
    0x*[!0-9A-Fa-f]*|0x) return 0 ;; # литеральный hex: валиден по форме, не объявлен
    0x*) return 0 ;;
  esac
  while IFS= read -r known; do
    [ "$known" = "$name" ] && return 0
  done < <(custom_strategies_blob_names "$cfg")
  return 1
}

# Валидирует spec блока. Сообщения — в stderr; rc: 0 — годен (возможны warning),
# 2 — фатальная ошибка.
custom_strategies_validate() {
  local block="$1" spec="$2" cfg="${3:-${ZAPRET2_ROOT:-/opt/zapret2}/config}"
  local transport rcwarn=0
  transport="$(custom_strategies_block_transport "$block")"
  [ -n "$transport" ] || { echo "Неизвестный блок: $block" >&2; return 2; }

  [ -n "$spec" ] || { echo "Пустая стратегия." >&2; return 2; }
  [ "${#spec}" -le 500 ] || { echo "Стратегия длиннее 500 символов." >&2; return 2; }
  case "$spec" in
    *[!A-Za-z0-9_=:,.\-+\ ]*)
      echo "Запрещённые символы в стратегии (допустимы буквы, цифры и .,:=+-_)." >&2
      return 2 ;;
  esac

  local rest="${spec// --lua-desync=/$'\x01'}" ngroups=0 g
  while IFS= read -r g; do
    ngroups=$((ngroups + 1))
    _custom_validate_group "$g" "$transport" "$cfg" || return 2
  done <<<"$(printf '%s\n' "${rest//$'\x01'/$'\n'}")"
  [ "$ngroups" -ge 1 ] && [ "$ngroups" -le 8 ] || {
    echo "От 1 до 8 групп --lua-desync= в одной стратегии." >&2
    return 2
  }
  return 0
}

_custom_validate_group() {
  local group="$1" transport="$2" cfg="$3"
  case "$group" in
    *' '*) echo "Пробел внутри группы (группы разделяются « --lua-desync=»)." >&2; return 1 ;;
  esac
  local prim="${group%%:*}"
  local rest="$group"
  if _custom_in_list "$prim" "$custom_strategies_primitives_tcp" \
     || _custom_in_list "$prim" "$custom_strategies_primitives_udp"; then
    :
  else
    echo "Неизвестный примитив: $prim" >&2
    return 1
  fi
  case "$transport" in
    udp) _custom_in_list "$prim" "$custom_strategies_primitives_udp" \
            || { echo "Примитив $prim не работает в UDP-блоке." >&2; return 1; } ;;
    *) _custom_in_list "$prim" "$custom_strategies_primitives_tcp" \
            || { echo "Примитив $prim не работает в TCP-блоке." >&2; return 1; } ;;
  esac

  # разбираем остаток по «:»
  local body="${group#*:}" tok key val
  while [ -n "$body" ]; do
    tok="${body%%:*}"
    [ "$tok" = "$body" ] && body="" || body="${body#*:}"
    [ -n "$tok" ] || continue
    if case "$tok" in *=*) true ;; *) false ;; esac; then
      key="${tok%%=*}"; val="${tok#*=}"
      _custom_validate_kv "$key" "$val" "$transport" || return 1
      case "$key" in
        blob|fake_blob|fallback)
          if ! _custom_blob_known "$val" "$cfg"; then
            echo "Блоб «$val» не объявлен в конфиге." >&2
            echo "Доступные: $(custom_strategies_blob_names "$cfg" | tr '\n' ' ')0x…" >&2
            return 1
          fi ;;
      esac
    else
      _custom_validate_flag "$tok" "$transport" || return 1
    fi
  done
  return 0
}

_custom_validate_kv() {
  local key="$1" val="$2" transport="$3"
  local known=0
  _custom_in_list "$key" "$custom_strategies_keys_both" && known=1
  case "$transport" in
    udp) _custom_in_list "$key" "$custom_strategies_keys_udp" && known=1 ;;
    *)   _custom_in_list "$key" "$custom_strategies_keys_tcp" && known=1 ;;
  esac
  if [ "$known" = "0" ]; then
    if [ "${Z2R_CUSTOM_STRICT:-1}" = "0" ]; then
      echo "Предупреждение: неизвестный ключ $key= (принят принудительно)." >&2
      return 0
    fi
    echo "Неизвестный ключ: $key=" >&2
    return 1
  fi
  case "$key" in
    repeats|fake_count|tcp_seq|tcp_ack|tcp_ts|seqovl|increment|min|ipfrag_pos_udp|sni_snt_new)
      printf '%s' "$val" | grep -Eq '^-?[0-9]+$' || { echo "Ключ $key= ждёт целое число." >&2; return 1; } ;;
    ip_autottl|ip6_autottl)
      printf '%s' "$val" | grep -Eq '^-?[0-9]+([,-][0-9]+)*' || { echo "Ключ $key= ждёт диапазон вида -1,4-20." >&2; return 1; } ;;
    out_range)
      printf '%s' "$val" | grep -Eq '^-[dnsp][0-9]+$' || { echo "Ключ out_range= ждёт вид -dN/-nN/-sN." >&2; return 1; } ;;
    pattern)
      printf '%s' "$val" | grep -Eq '^(0x[0-9A-Fa-f]+|[0-9]+)$' || { echo "Ключ pattern= ждёт hex или число." >&2; return 1; } ;;
    seqovl_pattern)
      printf '%s' "$val" | grep -Eq '^[0-9A-Za-z_]+$' || { echo "Ключ seqovl_pattern= ждёт имя/шаблон." >&2; return 1; } ;;
    blob|fake_blob|fallback)
      printf '%s' "$val" | grep -Eq '^[0-9A-Za-z_]+$' || { echo "Ключ $key= ждёт имя блоба." >&2; return 1; } ;;
    ip_id)
      printf '%s' "$val" | grep -Eq '^(zero|0x[0-9A-Fa-f]+|[0-9]+)$' || { echo "Ключ ip_id= ждёт zero/hex/число." >&2; return 1; } ;;
    payload)
      printf '%s' "$val" | grep -Eq '^[a-z_,0-9]+$' || { echo "Ключ payload= ждёт список l7-протоколов." >&2; return 1; } ;;
    pos)
      printf '%s' "$val" | grep -Eq '^[0-9A-Za-z_,+-]+$' || { echo "Ключ pos= ждёт позиции (sniext+1,midsld,...)." >&2; return 1; } ;;
    host|sni_first)
      printf '%s' "$val" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' || { echo "Ключ $key= ждёт домен." >&2; return 1; } ;;
  esac
  return 0
}

_custom_validate_flag() {
  local flag="$1" transport="$2" known=0
  _custom_in_list "$flag" "$custom_strategies_flags_both" && known=1
  case "$transport" in
    udp) _custom_in_list "$flag" "$custom_strategies_flags_udp" && known=1 ;;
    *)   _custom_in_list "$flag" "$custom_strategies_flags_tcp" && known=1 ;;
  esac
  if [ "$known" = "0" ]; then
    if [ "${Z2R_CUSTOM_STRICT:-1}" = "0" ]; then
      echo "Предупреждение: неизвестный флаг $flag (принят принудительно)." >&2
      return 0
    fi
    echo "Неизвестный флаг: $flag" >&2
    return 1
  fi
  return 0
}

# --- запись TSV ---------------------------------------------------------------

_custom_strats_write() {
  local tmp content="$1"
  # нормализуем хвост: ровно один завершающий перевод строки
  while :; do
    case "$content" in *$'\n') content="${content%$'\n'}" ;; *) break ;; esac
  done
  mkdir -p "$ORCH_DIR" || return 1
  tmp="${CUSTOM_STRATS_FILE}.tmp.$$"
  printf '%s\n' "$content" > "$tmp" && mv -f "$tmp" "$CUSTOM_STRATS_FILE" || {
    rm -f "$tmp"
    return 1
  }
  return 0
}

_custom_strats_header() {
  printf '# zator custom strategies: id, block, spec (без strategy=), enabled, comment, assigned\n'
}

# Добавляет запись (валидирует). rc: 0 ок, 2 — ошибка валидации, 1 — I/O.
custom_strategies_add() {
  local block="$1" spec="$2" comment="${3:-}" id
  custom_strategies_validate "$block" "$spec" || return 2
  comment="${comment//$'\t'/ }"
  [ "${#comment}" -le 64 ] || comment="${comment:0:64}"
  id="$(custom_strategies_next_id)"
  local content rows
  rows="$(custom_strategies_list)"
  [ -n "$rows" ] && rows="$rows
"
  content="$(_custom_strats_header)
$rows$(printf '%s\t%s\t%s\t1\t%s\t' "$id" "$block" "$spec" "$comment")"
  _custom_strats_write "$content" || return 1
  echo "$id"
}

# Полная замена строки (сбрасывает assigned — нужен повторный «Применить»).
custom_strategies_replace() {
  local id="$1" block="$2" spec="$3" enabled="$4" comment="${5:-}"
  custom_strategies_row "$id" >/dev/null || return 2
  custom_strategies_validate "$block" "$spec" || return 2
  comment="${comment//$'\t'/ }"
  [ "${#comment}" -le 64 ] || comment="${comment:0:64}"
  local content row
  content="$(_custom_strats_header)"$'
'
  while IFS="$(printf '\t')" read -r rid rblock rspec renabled rcomment rassigned; do
    if [ "$rid" = "$id" ]; then
      row="$(printf '%s\t%s\t%s\t%s\t%s\t' "$rid" "$block" "$spec" "$enabled" "$comment")"
    else
      row="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$rid" "$rblock" "$rspec" "$renabled" "$rcomment" "${rassigned:-}")"
    fi
    content="$content$row
"
  done < <(custom_strategies_list)
  _custom_strats_write "$content" || return 1
}

custom_strategies_set_enabled() {
  local id="$1" enabled="$2"
  local content row changed=0
  content="$(_custom_strats_header)"$'
'
  while IFS="$(printf '\t')" read -r rid rblock rspec renabled rcomment rassigned; do
    [ "$rid" = "$id" ] && { renabled="$enabled"; changed=1; }
    row="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$rid" "$rblock" "$rspec" "$renabled" "$rcomment" "${rassigned:-}")"
    content="$content$row
"
  done < <(custom_strategies_list)
  [ "$changed" = "1" ] || return 2
  _custom_strats_write "$content" || return 1
}

# Удаление с уплотнением id (пропусков нет).
custom_strategies_delete() {
  local id="$1" content row newid=0
  content="$(_custom_strats_header)"$'
'
  while IFS="$(printf '\t')" read -r rid rblock rspec renabled rcomment rassigned; do
    [ "$rid" = "$id" ] && continue
    newid=$((newid + 1))
    row="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$newid" "$rblock" "$rspec" "$renabled" "$rcomment" "${rassigned:-}")"
    content="$content$row
"
  done < <(custom_strategies_list)
  _custom_strats_write "$content" || return 1
}

# --- инжект в конфиг ----------------------------------------------------------

# Регион блока в конфиге: (start_re; end_re). Для tpl/p5/p6/p7 конец — первый
# «--new» после старта; p4 ограничен парой маркеров стандартного блока Discord.
custom_strategies_region() {
  case "$1" in
    tpl) echo '^--template=z2r_tcp_tls_common' ;;
    p4)  echo '^#Z2R_AUTO_STANDARD_4_BEGIN' ;;
    p5)  echo '^--lua-desync=circular_locked:key=5([^0-9]|$)' ;;
    p6)  echo '^--lua-desync=circular_locked:key=6([^0-9]|$)' ;;
    p7)  echo '^--lua-desync=circular_locked:key=7([^0-9]|$)' ;;
    *) return 1 ;;
  esac
}

custom_strategies_region_end() {
  case "$1" in
    p4) echo '^#Z2R_AUTO_STANDARD_4_END' ;;
    *) echo '^--new[[:space:]]*$' ;;
  esac
}

# Добавляет пустые маркерные пары в конфиги без них (старые установки).
custom_strategies_ensure_markers() {
  local cfg="$1" block mb me start_re end_re tmp
  [ -f "$cfg" ] || return 1
  tmp="${cfg}.custom.$$"
  for block in tpl p4 p5 p6 p7; do
    mb="$(custom_strategies_marker_begin "$block")"
    me="$(custom_strategies_marker_end "$block")"
    grep -qxF "$mb" "$cfg" && continue
    start_re="$(custom_strategies_region "$block")"
    end_re="$(custom_strategies_region_end "$block")"
    awk -v re_start="$start_re" -v re_end="$end_re" -v mb="$mb" -v me="$me" '
      { lines[NR] = $0 }
      END {
        in_region = 0
        for (i = 1; i <= NR; i++) {
          if (lines[i] ~ re_start) in_region = 1
          if (in_region && lines[i] ~ re_end) {
            print mb
            print me
            in_region = 0
          }
          print lines[i]
        }
      }
    ' "$cfg" > "$tmp" && mv -f "$tmp" "$cfg" || { rm -f "$tmp"; return 1; }
  done
  return 0
}

# Максимум strategy=N региона блока (содержимое кастомных маркеров исключено).
_custom_block_stock_max() {
  local cfg="$1" block="$2" start_re end_re mb me
  start_re="$(custom_strategies_region "$block")"
  end_re="$(custom_strategies_region_end "$block")"
  mb="$(custom_strategies_marker_begin "$block")"
  me="$(custom_strategies_marker_end "$block")"
  awk -v re_start="$start_re" -v re_end="$end_re" -v mb="$mb" -v me="$me" '
    $0 == mb { in_custom = 1 }
    $0 == me { in_custom = 0; next }
    in_custom { next }
    $0 ~ re_start { in_region = 1 }
    in_region && $0 ~ re_end { in_region = 0 }
    in_region {
      line = $0
      while (match(line, /strategy=[0-9]+/)) {
        n = substr(line, RSTART + 9, RLENGTH - 9) + 0
        if (n > m) m = n
        line = substr(line, RSTART + RLENGTH)
      }
    }
    END { print m + 0 }
  ' "$cfg"
}

# Заменяет содержимое между маркерами блока строками из файла $3 (пусто — вычистить).
_custom_block_fill() {
  local cfg="$1" block="$2" ins="$3" mb me tmp
  mb="$(custom_strategies_marker_begin "$block")"
  me="$(custom_strategies_marker_end "$block")"
  tmp="${cfg}.custom.$$"
  awk -v mb="$mb" -v me="$me" -v ins="$ins" '
    $0 == mb {
      print
      if (ins != "") {
        while ((getline line < ins) > 0) print line
        close(ins)
      }
      wiping = 1
      next
    }
    $0 == me { wiping = 0; print; next }
    !wiping { print }
  ' "$cfg" > "$tmp" && mv -f "$tmp" "$cfg" || { rm -f "$tmp"; return 1; }
}

# Применяет TSV к конфигу $1 (по умолчанию живой config): добавляет маркеры,
# вычищает старое, назначает номера после максимума блока, обновляет assigned,
# ремапит локи и вычищает локи за пределами новых диапазонов. Молчаливая (для
# хуков config_apply_from_default/установки и WebUI-контекста): прогресс — в
# stderr. rc!=0 только при I/O-ошибках; кривые строки TSV пропускаются с warning.
custom_strategies_apply_file() {
  local cfg="${1:-${ZAPRET2_ROOT:-/opt/zapret2}/config}"
  [ -f "$cfg" ] || { echo "custom strategies: нет конфига $cfg" >&2; return 1; }

  local work="/tmp/z2r-custom-$$"
  mkdir -p "$work" || return 1

  # валидные (по блоку) записи; кривые блоки — warning и skip
  local tsv="$work/all.tsv" had_entries=0
  : > "$tsv"
  local id bblock spec enabled comment assigned
  while IFS="$(printf '\t')" read -r id bblock spec enabled comment assigned; do
    if ! custom_strategies_block_valid "$bblock"; then
      echo "custom strategies: строка $id с неизвестным блоком «$bblock» пропущена" >&2
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$bblock" "$spec" "${enabled:-1}" "$comment" "${assigned:-}" >> "$tsv"
    had_entries=1
  done < <(custom_strategies_list)

  custom_strategies_ensure_markers "$cfg" || { rm -rf "$work"; return 1; }

  local mapfile="$work/remap.tsv" amapfile="$work/amap.tsv" dropfile="$work/drop.tsv"
  local newtsv="$work/new.tsv"
  : > "$mapfile"; : > "$amapfile"; : > "$dropfile"
  printf '%s\n' "$(_custom_strats_header)" > "$newtsv"

  local block askey
  for block in tpl p4 p5 p6 p7; do
    local ins="$work/ins.$block" n=0 maxnow num p pr line g rest
    : > "$ins"
    maxnow="$(_custom_block_stock_max "$cfg" "$block")"
    # auto_locked askey: общий TCP-шаблон -> tls, QUIC -> quic (остальные
    # неоднозначны — SLM перенаучится сам)
    case "$block" in
      tpl) askey="tls" ;;
      p5)  askey="quic" ;;
      *)   askey="" ;;
    esac
    # записи блока в порядке id; включённые получают номера max+1..
    while IFS="$(printf '\t')" read -r id bblock spec enabled comment assigned; do
      [ "$bblock" = "$block" ] || continue
      num=""
      if [ "${enabled:-1}" = "1" ]; then
        n=$((n + 1)); num=$((maxnow + n))
        # строка конфига: каждой группе дописываем :strategy=N
        line=""
        rest="${spec// --lua-desync=/$'\x01'}"
        while IFS= read -r g; do
          if [ -z "$line" ]; then line="--lua-desync=$g:strategy=$num"
          else line="$line --lua-desync=$g:strategy=$num"; fi
        done <<<"$(printf '%s\n' "${rest//$'\x01'/$'\n'}")"
        printf '%s\n' "$line" >> "$ins"
      fi
      # новый TSV с фактическим номером
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$bblock" "$spec" "${enabled:-1}" "$comment" "${num:-}" >> "$newtsv"
      # ремап локов: старый номер -> новый (пусто/0 = стратегия исчезла)
      if [ -n "$assigned" ] && [ "$assigned" != "$num" ]; then
        for p in $(custom_strategies_block_profiles "$block"); do
          for pr in $(custom_strategies_block_protos_for "$block" "$p"); do
            printf '%s\t%s\t%s\t%s\n' "$p" "$pr" "$assigned" "${num:-0}" >> "$mapfile"
          done
        done
        [ -n "$askey" ] && printf '%s\t%s\t%s\n' "$askey" "$assigned" "${num:-0}" >> "$amapfile"
      fi
    done < "$tsv"

    _custom_block_fill "$cfg" "$block" "$ins"

    # локи за пределами нового максимума блока -> сброс в auto
    local newmax=$((maxnow + n))
    for p in $(custom_strategies_block_profiles "$block"); do
      for pr in $(custom_strategies_block_protos_for "$block" "$p"); do
        printf '%s\t%s\t%s\n' "$p" "$pr" "$newmax" >> "$dropfile"
      done
    done
  done

  # TSV обновляем, только если он уже существует или в нём есть записи
  if [ "$had_entries" = "1" ] || [ -f "$CUSTOM_STRATS_FILE" ]; then
    cp -f "$newtsv" "$CUSTOM_STRATS_FILE"
  fi

  _custom_remap_locks "$mapfile" "$amapfile" "$dropfile"
  rm -rf "$work"
  return 0
}

# профили→протоколы: у tpl профиль 1 несёт tls+http, остальные tls
custom_strategies_block_protos_for() {
  local block="$1" profile="$2"
  if [ "$block" = "tpl" ] && [ "$profile" = "1" ]; then
    echo "tls http"
  else
    custom_strategies_block_protos "$block"
  fi
}

# Ремап locked.tsv / locked.manual.tsv / scopes/*.tsv по map (profile proto old new),
# auto_locked.tsv по amap (askey old new), удаление локов с номером > max (drop:
# profile proto max). single-pass map — цепочки коллизий невозможны.
_custom_remap_locks() {
  local mapfile="$1" amapfile="$2" dropfile="$3"
  [ -s "$mapfile" ] || mapfile=""
  [ -s "$dropfile" ] || dropfile=""

  local files=()
  [ -f "$ORCH_LOCK_FILE" ] && files+=("$ORCH_LOCK_FILE")
  [ -f "$ORCH_DIR/locked.manual.tsv" ] && files+=("$ORCH_DIR/locked.manual.tsv")
  local sc f
  for sc in "$ORCH_DIR"/scopes/*.tsv; do
    [ -f "$sc" ] && files+=("$sc")
  done

  for f in "${files[@]}"; do
    local tmp="${f}.custom.$$" moved=0
    awk -F '\t' -v OFS='\t' \
        -v mapf="$mapfile" -v dropf="$dropfile" '
      BEGIN {
        if (mapf != "") {
          while ((getline line < mapf) > 0) {
            split(line, m, "\t")
            remap[m[1] "/" m[2] "/" m[3]] = m[4]
          }
          close(mapf)
        }
        if (dropf != "") {
          while ((getline line < dropf) > 0) {
            split(line, d, "\t")
            if (d[3] + 0 > maxof[d[1] "/" d[2]] + 0) maxof[d[1] "/" d[2]] = d[3] + 0
          }
          close(dropf)
        }
      }
      /^[[:space:]]*#/ { print; next }
      NF >= 3 {
        pkey = $1 "/" $2
        if ((pkey in maxof) && ($3 + 0) > maxof[pkey]) {
          printf("custom strategies: лок профиля %s (%s) стратегия %s вне диапазона — сброшен в auto\n", $1, $2, $3) > "/dev/stderr"
          dropped++
          next
        }
        key = pkey "/" $3
        if (key in remap) {
          nv = remap[key]
          if (nv + 0 <= 0) {
            printf("custom strategies: лок профиля %s (%s) стратегия %s без нового номера — сброшен в auto\n", $1, $2, $3) > "/dev/stderr"
            dropped++
            next
          }
          if (nv != $3) printf("custom strategies: лок %s/%s %s -> %s\n", $1, $2, $3, nv) > "/dev/stderr"
          $3 = nv
          print
          next
        }
        print
        next
      }
      NF == 2 {
        key = $1 "/tls/" $2
        if (($1 "/tls") in maxof && ($2 + 0) > maxof[$1 "/tls"]) {
          printf("custom strategies: лок профиля %s (tls) стратегия %s вне диапазона — сброшен в auto\n", $1, $2) > "/dev/stderr"
          dropped++
          next
        }
        if (key in remap) {
          nv = remap[key]
          if (nv + 0 <= 0) { dropped++; next }
          if (nv != $2) printf("custom strategies: лок %s/tls %s -> %s\n", $1, $2, nv) > "/dev/stderr"
          $2 = nv
          print
          next
        }
        print
        next
      }
      { print }
      END { if (dropped + 0 > 0) exit 42 }
    ' "$f" > "$tmp"
    local rc=$?
    if [ $rc -eq 0 ] || [ $rc -eq 42 ]; then
      mv -f "$tmp" "$f"
    else
      rm -f "$tmp"
    fi
  done

  # auto_locked.tsv: 3 колоночный askey host strat (4 колоночный scoped)
  local af="$ORCH_DIR/auto_locked.tsv"
  [ -f "$af" ] || return 0
  [ -s "$amapfile" ] || return 0
  local tmp="${af}.custom.$$"
  awk -F '\t' -v OFS='\t' -v mapf="$amapfile" '
    BEGIN {
      while ((getline line < mapf) > 0) {
        split(line, m, "\t")
        amap[m[1] "/" m[2]] = m[3]
      }
      close(mapf)
    }
    /^[[:space:]]*#/ { print; next }
    NF >= 3 {
      strat = $NF
      key = $1 "/" strat
      if (key in amap && amap[key] != strat) {
        printf("custom strategies: auto-lock %s %s -> %s\n", $1, strat, amap[key]) > "/dev/stderr"
        $NF = amap[key]
      }
      print
      next
    }
    { print }
  ' "$af" > "$tmp" && mv -f "$tmp" "$af" || rm -f "$tmp"
}

# --- интерактивное применение -------------------------------------------------

custom_strategies_apply_live() {
  local cfg="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  [ -f "$cfg" ] || cfg="${ZAPRET2_ROOT:-/opt/zapret2}/config.default"
  custom_strategies_apply_file "$cfg" || {
    echo -e "${red}Не удалось применить кастомные стратегии к $cfg${plain}" >&2
    return 1
  }
  return 0
}

# --- подменю (п.1 -> 14) ------------------------------------------------------

custom_strategies_submenu() {
  local cfg="${ZAPRET2_ROOT:-/opt/zapret2}/config"
  [ -f "$cfg" ] || cfg="${ZAPRET2_ROOT:-/opt/zapret2}/config.default"
  local ans id block spec comment enabled

  while true; do
    clear -x
    echo -e "${cyan}--- Кастомные стратегии пользователя ---${plain}"
    echo ""
    echo -e "${yellow}Дописываются в конфиг после штатных стратегий блока; номера назначаются${plain}"
    echo -e "${yellow}автоматически и смещаются при обновлениях, локи ремапятся сами.${plain}"
    echo -e "${yellow}Изменения вступают в силу после перезапуска zapret2 (пункт 2 меню).${plain}"
    echo ""
    if [ "$(custom_strategies_count)" = "0" ]; then
      echo -e "${yellow}Записей нет. Добавьте свою первую стратегию (например, QUIC-фейк) или${plain}"
      echo -e "${yellow}импортируйте готовые строки --lua-desync=... :strategy=N — номера срежутся.${plain}"
    else
      printf "${yellow}%-3s %-4s %-4s %-4s %s${plain}\n" "ID" "Блок" "№" "Вкл" "Комментарий / стратегия"
      while IFS="$(printf '\t')" read -r id block spec enabled comment assigned; do
        local onoff="да" no="-"
        [ "$enabled" = "1" ] || onoff="${red}нет${plain}"
        [ -n "$assigned" ] && no="$assigned"
        printf "%-3s %-4s %-4s %-4s %s\n" "$id" "$block" "$no" "$onoff" "$comment"
        printf "      ${cyan}%s${plain}\n" "$spec"
      done < <(custom_strategies_list)
    fi
    echo ""
    submenu_item "1" "Добавить стратегию"
    submenu_item "2" "Изменить (spec/блок/комментарий)"
    submenu_item "3" "Включить/выключить"
    submenu_item "4" "Удалить"
    submenu_item "5" "Импорт готовых строк"
    submenu_item "6" "Применить к конфигу"
    submenu_item "0" "Назад"
    echo ""

    read -re -p "Ваш выбор: " ans || ans=""
    case "$ans" in
      "0"|"") return ;;
      "1") _custom_add_flow ;;
      "2") _custom_edit_flow ;;
      "3")
        read -re -p "ID записи (0 - отмена): " id || id=""
        case "$id" in ""|0|*[!0-9]*) ui_invalid_input; continue ;; esac
        if [ "$(awk -F '\t' -v i="$id" '$1==i {print $4; exit}' < <(custom_strategies_list))" = "1" ]; then
          if custom_strategies_set_enabled "$id" 0; then
            echo -e "${green}Запись $id выключена.${plain}"
          else
            echo -e "${red}Не найдена запись $id.${plain}"
          fi
        else
          if custom_strategies_set_enabled "$id" 1; then
            echo -e "${green}Запись $id включена.${plain}"
          else
            echo -e "${red}Не найдена запись $id.${plain}"
          fi
        fi
        pause_enter
        ;;
      "4")
        read -re -p "ID записи (0 - отмена): " id || id=""
        case "$id" in ""|0|*[!0-9]*) ui_invalid_input; continue ;; esac
        custom_strategies_delete "$id" && echo -e "${green}Удалено (ID уплотнены).${plain}"
        pause_enter
        ;;
      "5") _custom_import_flow ;;
      "6")
        if custom_strategies_apply_live; then
          echo -e "${green}Кастомные стратегии применены к $cfg.${plain}"
          read -re -p "Перезапустить zapret2 сейчас? 1 - да, Enter - нет: " ans || ans=""
          if [ "$ans" = "1" ]; then
            z2r_service_action restart || echo -e "${red}Не удалось перезапустить zapret2 — смотрите /tmp/nfqws2_1.err (п.666).${plain}"
          fi
        fi
        pause_enter
        ;;
      *) ui_invalid_input ;;
    esac
  done
}

# Выбор блока: stdout — ТОЛЬКО имя блока (меню ловит $(...)), весь рендер —
# в stderr. Отмена (0/Enter/EOF) — return 0 с пустым stdout (дом-стиль orch_ask_*).
_custom_pick_block() {
  local choice i b label
  while true; do
    i=1
    clear -x >&2
    echo -e "${cyan}--- Куда дописать стратегию ---${plain}" >&2
    echo "" >&2
    while IFS="$(printf '\t')" read -r b label _rest; do
      submenu_item "$i" "$b — $label" >&2
      i=$((i + 1))
    done < <(custom_strategies_blocks)
    submenu_item "0" "Отмена" >&2
    echo "" >&2
    read -re -p "Ваш выбор: " choice || choice=""
    [ -z "$choice" ] && return 0
    local n=0
    while IFS="$(printf '\t')" read -r b _rest; do
      n=$((n + 1))
      if [ "$n" = "$choice" ]; then echo "$b"; return 0; fi
    done < <(custom_strategies_blocks)
    ui_invalid_input >&2
  done
}

# Ввод spec с экраном-подсказкой и циклом валидации. stdout — ТОЛЬКО
# канонический spec (рендер в stderr), отмена — return 0 с пустым stdout.
# Понимает: одиночную группу; комбо из нескольких групп, разделённых
# « --lua-desync=» (всем группам присвоится один номер); готовую строку из
# конфига — префиксы «--lua-desync=» и хвостовые «:strategy=N» срезаются.
_custom_ask_spec() {
  local def="${1:-}" input spec transport example combo
  transport="$(custom_strategies_block_transport "$_CUSTOM_BLOCK")"
  if [ "$transport" = "udp" ]; then
    example='fake:blob=quic_google:ipfrag:ipfrag_pos_udp=8:ipfrag_disorder:repeats=6:out_range=-d10'
    combo='send:repeats=2:ip_autottl=1,3-20 --lua-desync=fake:blob=0x00:repeats=4:out_range=-d10'
  else
    example='fake:blob=maxru:tcp_md5:pos=2:repeats=2'
    combo='multisplit:blob=maxru:tcp_md5:pos=2:nodrop --lua-desync=fakeddisorder:pos=midsld:tcp_md5:nofake3'
  fi
  while true; do
    clear -x >&2
    echo -e "${cyan}--- Стратегия для блока ${_CUSTOM_BLOCK} ---${plain}" >&2
    echo "" >&2
    if [ -n "$def" ]; then
      echo -e "${yellow}Текущая: ${plain}${cyan}${def}${plain}" >&2
      echo "" >&2
    fi
    echo -e "${yellow}Как вводить:${plain}" >&2
    echo -e "${yellow}  • одна группа desync (см. пример ниже);${plain}" >&2
    echo -e "${yellow}  • комбо — несколько групп через « --lua-desync=», всем им${plain}" >&2
    echo -e "${yellow}    присвоится ОДИН номер стратегии (как строкам 20/21 конфига);${plain}" >&2
    echo -e "${yellow}  • можно вставить готовую строку из конфига целиком —${plain}" >&2
    echo -e "${yellow}    «--lua-desync=» и «:strategy=N» срежутся автоматически.${plain}" >&2
    echo "" >&2
    echo -e "${yellow}Пример (${transport}):${plain}" >&2
    echo -e "${cyan}${example}${plain}" >&2
    echo -e "${yellow}Пример комбо:${plain}" >&2
    echo -e "${cyan}${combo}${plain}" >&2
    echo "" >&2
    read -re -p "Стратегия (Enter - отмена): " input || input=""
    [ -z "$input" ] && return 0
    spec="$(custom_strategies_normalize "$input")" || {
      echo -e "${red}Не удалось разобрать строку: «strategy=» допустим только в конце групп.${plain}" >&2
      continue
    }
    if custom_strategies_validate "$_CUSTOM_BLOCK" "$spec"; then
      echo "$spec"
      return 0
    fi
    echo -e "${red}Стратегия не прошла валидацию — исправьте по сообщениям выше.${plain}" >&2
    read -re -p "Enter — вернуться к вводу: " _retry || _retry=""
  done
}

_custom_add_flow() {
  local block spec comment id
  block="$(_custom_pick_block)" || block=""
  [ -n "$block" ] || { echo "Отменено."; pause_enter; return; }
  _CUSTOM_BLOCK="$block"
  spec="$(_custom_ask_spec)" || spec=""
  [ -n "$spec" ] || { echo "Отменено."; pause_enter; return; }
  read -re -p "Комментарий (Enter - пусто): " comment || comment=""
  if id="$(custom_strategies_add "$block" "$spec" "$comment")"; then
    echo -e "${green}Добавлено: ID $id, блок $block.${plain}"
    echo -e "${yellow}Примените к конфигу (п.6 этого меню) и перезапустите zapret2.${plain}"
  else
    echo -e "${red}Не добавлено (валификация/I/O).${plain}"
  fi
  pause_enter
}

_custom_edit_flow() {
  local id row block spec comment enabled
  read -re -p "ID записи (0 - отмена): " id || id=""
  case "$id" in ""|0|*[!0-9]*) ui_invalid_input; return ;; esac
  row="$(custom_strategies_row "$id")"
  [ -n "$row" ] || { echo -e "${red}Нет записи $id.${plain}"; pause_enter; return; }
  IFS="$(printf '\t')" read -r _id block spec enabled comment _assigned <<<"$row"
  echo -e "${yellow}Текущий блок: ${plain}${green}$block${plain}"
  local nb; nb="$(_custom_pick_block)" || nb=""
  [ -n "$nb" ] || nb="$block"
  _CUSTOM_BLOCK="$nb"
  local ns; ns="$(_custom_ask_spec "$spec")" || ns=""
  [ -n "$ns" ] || ns="$spec"
  read -re -p "Комментарий (Enter - прежний): " comment || comment="$comment"
  [ -z "$comment" ] && comment="$(printf '%s' "$row" | awk -F '\t' '{print $5}')"
  if custom_strategies_replace "$id" "$nb" "$ns" "$enabled" "$comment"; then
    echo -e "${green}Запись $id обновлена. Примените к конфигу (п.6).${plain}"
  else
    echo -e "${red}Не обновлено.${plain}"
  fi
  pause_enter
}

_custom_import_flow() {
  local block line spec ok=0 fail=0 tmpf="/tmp/z2r-custom-import.$$"
  block="$(_custom_pick_block)" || block=""
  [ -n "$block" ] || { echo "Отменено."; pause_enter; return; }
  _CUSTOM_BLOCK="$block"
  echo -e "${yellow}Вставьте строки --lua-desync=..., по одной на запись; номера :strategy=N${plain}"
  echo -e "${yellow}срезутся сами. Комбо из нескольких групп в одной строке (разделитель${plain}"
  echo -e "${yellow}« --lua-desync=») станет одной записью с одним номером. Пустая строка — конец.${plain}"
  : > "$tmpf"
  while IFS= read -re line; do
    [ -z "$line" ] && break
    printf '%s\n' "$line" >> "$tmpf"
  done
  [ -s "$tmpf" ] || { echo "Ничего не введено."; pause_enter; rm -f "$tmpf"; return; }
  while IFS= read -r line; do
    spec="$(custom_strategies_normalize "$line")" || { echo -e "${red}SKIP (разбор): $line${plain}"; fail=$((fail+1)); continue; }
    if custom_strategies_add "$block" "$spec" "импорт" >/dev/null 2>&1; then
      ok=$((ok + 1))
    else
      echo -e "${red}SKIP (валидация): $spec${plain}"
      fail=$((fail + 1))
    fi
  done < "$tmpf"
  rm -f "$tmpf"
  echo -e "${green}Импортировано: $ok, пропущено: $fail (блок $block).${plain}"
  echo -e "${yellow}Примените к конфигу (п.6) и перезапустите zapret2.${plain}"
  pause_enter
}
