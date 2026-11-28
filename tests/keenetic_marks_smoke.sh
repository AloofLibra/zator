#!/usr/bin/env bash
# Keenetic: служебные метки zapret2 не должны пересекаться с метками политик
# доступа. Keenetic матчит policy-fwmark в ip rule ЦЕЛЫМ словом (без маски), а
# метки политик 28-битные: бит 0x04000000 есть в каждой из них, поэтому профиль
# wssize_ramp с дефолтным Z2R_WSSIZE_MARK получал бы весь TLS policy-устройств,
# а не только googlevideo.
#
# Покрывает:
#   1. config_keenetic_mark_num: 0x-hex и десятичные принимаются, восьмерично
#      выглядящие (04000000) и мусор отклоняются (в bash-арифметике 04000000
#      молча стало бы другим числом);
#   2. config_keenetic_mark_conflicts / config_keenetic_free_wssize_mark;
#   3. config_keenetic_used_marks: разбор `mark: ffffaad` из ndmc + служебные
#      метки конфига;
#   4. config_keenetic_ensure_wssize_mark: перенос метки, идемпотентность,
#      no-op при ENABLE=0 и на не-Keenetic, выключение ramp без свободного бита;
#   5. вызов guard'а из config_keenetic_set_wan_iface (путь установки),
#      платформенный предикат config_is_keenetic (в CGI нет $hardware —
#      платформа берётся из строки ядра, fallback меток на ip rule) и
#      статический wiring всех точек вызова, включая webui/cgi-bin/_lib.sh.
#
# Только во временной директории, без сети и /opt.
#
# Запуск:  bash tests/keenetic_marks_smoke.sh

set -u
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/z2r_keenetic_marks.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
. "$REPO_DIR/lib/config.sh"

hardware=keenetic
yellow= green= red= plain=
CFG="$WORK/config"
fail() { echo "FAIL: $*" >&2; exit 1; }

mkcfg() { # fwtype flowoffload mark enable
  cat > "$CFG" <<EOF
FWTYPE=${1:-iptables}
FLOWOFFLOAD=${2:-donttouch}
DESYNC_MARK=0x40000000
DESYNC_MARK_POSTNAT=0x20000000
CLIENT_SCOPE_MARK_MASK=
Z2R_WSSIZE_MARK=${3:-0x04000000}
Z2R_WSSIZE_RAMP_ENABLE=${4:-1}
IFACE_WAN=
EOF
}

# --- 1. config_keenetic_mark_num -------------------------------------------
[ "$(config_keenetic_mark_num 0x04000000)" = 67108864 ] || fail "0x04000000 не разобран"
[ "$(config_keenetic_mark_num 1073741824)" = 1073741824 ] || fail "десятичная метка не разобрана"
config_keenetic_mark_num 04000000 >/dev/null 2>&1 && fail "восьмерично выглядящее значение принято"
config_keenetic_mark_num 0xzz >/dev/null 2>&1 && fail "мусор принят"
config_keenetic_mark_num '' >/dev/null 2>&1 && fail "пустое значение принято"

# --- 2. битовые проверки ---------------------------------------------------
config_keenetic_mark_conflicts 0x04000000 0xffffaad || fail '0x04000000 должен пересекаться с 0xffffaad'
config_keenetic_mark_conflicts 0x04000000 0xffffaaa || fail '0x04000000 должен пересекаться с 0xffffaaa'
config_keenetic_mark_conflicts 0x00000400 0xffffaad && fail '0x400 не должен пересекаться с 0xffffaad'
config_keenetic_mark_conflicts 0x40000000 0x0 && fail 'нулевая метка не должна давать конфликт'
config_keenetic_mark_conflicts 04000000 0xffffaad && fail 'нечисловая метка не должна давать конфликт'
[ "$(config_keenetic_free_wssize_mark 0xffffaad 0x40000000 0x20000000)" = "0x80000000" ] \
  || fail "свободный бит: $(config_keenetic_free_wssize_mark 0xffffaad 0x40000000 0x20000000)"
config_keenetic_free_wssize_mark 0xffffffff >/dev/null && fail 'при занятых всех битах кандидат не должен находиться'


# --- 3. разбор меток политик из ndmc --------------------------------------
ndmc() {
  case "$*" in
    "-c show ip policy") cat <<'EOF'
           policy, name = Policy2, description = Ростелеком: 
                 mark: ffffaac
               table4: 4100
           policy, name = Policy3, description = ККС: 
                 mark: ffffaad
               table4: 4102
EOF
      ;;
    *) return 1 ;;
  esac
}

mkcfg iptables donttouch 0x04000000 1
config_keenetic_used_marks "$CFG" | grep -qx '0xffffaad' \
  || fail "метки политик не распознаны: $(config_keenetic_used_marks "$CFG" | tr '\n' ' ')"
config_keenetic_used_marks "$CFG" | grep -qx '0x40000000' \
  || fail "служебная метка DESYNC_MARK не попала в список"
config_keenetic_used_marks "$CFG" | grep -qx '0x08000000' \
  || fail "метка суперсвипа (0x08000000) не зарезервирована"
config_keenetic_used_marks "$CFG" | grep -qx '0xff00' \
  || fail "пространство client scope (0xff00) не зарезервировано"
[ "$(config_keenetic_free_wssize_mark 0x80000000 0x40000000 0x20000000 0xffffaad)" = "0x10000000" ] \
  || fail "после занятого бита 31 должен предлагаться 0x10000000, а не резерв суперсвипа"
config_keenetic_free_wssize_mark 0x80000000 0x10000000 0x00800000 0x00080000 0x08000000 0xff00 \
  >/dev/null && fail 'биты client scope (0xff00) предлагаться не должны'

# --- 4. config_keenetic_ensure_wssize_mark --------------------------------
mkcfg iptables donttouch 0x04000000 1
out="$(config_keenetic_ensure_wssize_mark "$CFG")"
[ "$(config_get_var "$CFG" Z2R_WSSIZE_MARK)" = "0x80000000" ] \
  || fail "ожидался перенос в 0x80000000, получено '$(config_get_var "$CFG" Z2R_WSSIZE_MARK)'"
[ "$(config_get_var "$CFG" Z2R_WSSIZE_RAMP_ENABLE)" = "1" ] || fail 'ramp не должен выключаться, когда бит найден'
printf '%s' "$out" | grep -q 'перенесён' || fail "нет сообщения о переносе: $out"

# Идемпотентность: второй прогон ничего не меняет и молчит.
out="$(config_keenetic_ensure_wssize_mark "$CFG")"
[ -z "$out" ] || fail "повторный прогон напечатал лишнее: $out"
[ "$(config_get_var "$CFG" Z2R_WSSIZE_MARK)" = "0x80000000" ] || fail 'метка изменилась на повторном прогоне'

# ramp выключен: конфиг не трогаем.
mkcfg iptables donttouch 0x04000000 0
config_keenetic_ensure_wssize_mark "$CFG" >/dev/null
[ "$(config_get_var "$CFG" Z2R_WSSIZE_MARK)" = "0x04000000" ] || fail 'при ENABLE=0 метка меняться не должна'

# Свободных битов нет: фичу выключаем.
ndmc() { case "$*" in "-c show ip policy") printf '                 mark: ffffffff\n' ;; *) return 1 ;; esac; }
mkcfg iptables donttouch 0x04000000 1
out="$(config_keenetic_ensure_wssize_mark "$CFG")"
[ "$(config_get_var "$CFG" Z2R_WSSIZE_RAMP_ENABLE)" = "0" ] || fail 'при отсутствии свободного бита ramp должен выключиться'
printf '%s' "$out" | grep -q 'выключен' || fail "нет сообщения о выключении: $out"

# Конфликта нет (политик на устройстве нет): молча и без изменений.
ndmc() { return 1; }
mkcfg iptables donttouch 0x80000000 1
out="$(config_keenetic_ensure_wssize_mark "$CFG")"
[ -z "$out" ] || fail "без конфликта guard должен молчать: $out"
[ "$(config_get_var "$CFG" Z2R_WSSIZE_MARK)" = "0x80000000" ] || fail 'метка изменена без конфликта'

# Восьмерично выглядящее значение метки не должно ломать guard.
ndmc() { case "$*" in "-c show ip policy") printf '                 mark: ffffaad\n' ;; *) return 1 ;; esac; }
mkcfg iptables donttouch 04000000 1
out="$(config_keenetic_ensure_wssize_mark "$CFG")" || fail 'guard упал на восьмерично выглядящей метке'
[ -z "$out" ] || fail "нечисловая метка не должна считаться конфликтом: $out"

# --- 5. вызов из config_keenetic_set_wan_iface (путь установки) -----------
ip() {
  case "$*" in
    '-4 route show default') printf '%s\n' 'default dev ppp0 scope link  metric 1000 ' ;;
    '-4 route show table all') printf '%s\n' 'default dev ppp0 scope link  metric 1000 ' ;;
    '-6 route show default'|'-6 route show table all') return 0 ;;
    '-o link show dev ppp0') printf '%s\n' '39: ppp0: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1492 qdisc fq_codel qlen 1000\    link/ppp ' ;;
    *) return 0 ;;
  esac
}

mkcfg iptables donttouch 0x04000000 1
config_keenetic_set_wan_iface "$CFG" >/dev/null || fail "set_wan_iface вернул ошибку"
[ "$(config_get_var "$CFG" Z2R_WSSIZE_MARK)" = "0x80000000" ] \
  || fail "set_wan_iface не перенёс метку: '$(config_get_var "$CFG" Z2R_WSSIZE_MARK)'"
[ "$(config_get_iface_wan "$CFG")" = "ppp0" ] || fail "IFACE_WAN не записан"

# Не-Keenetic: ничего не трогаем.
hardware=generic
mkcfg iptables donttouch 0x04000000 1
out="$(config_keenetic_ensure_wssize_mark "$CFG")"
[ -z "$out" ] || fail 'generic: guard должен молчать'
[ "$(config_get_var "$CFG" Z2R_WSSIZE_MARK)" = "0x04000000" ] || fail 'generic: метка изменена'
[ "$(config_get_var "$CFG" Z2R_WSSIZE_RAMP_ENABLE)" = "1" ] || fail 'generic: ramp выключен'
hardware=keenetic

# --- 5b. платформенный предикат и CGI-путь (webui/cgi-bin/_lib.sh) -------
# В CGI переменной hardware нет: платформа берётся из строки ядра тем же
# признаком, что и в z2r_detect_platform. Явно определённая не-Keenetic
# платформа приоритетнее строки ядра.
printf '%s\n' 'Linux version 4.9-ndm-5 (developers@netcraze.ru)' > "$WORK/proc-version-netcraze"
printf '%s\n' 'Linux version 6.1.0-openwrt' > "$WORK/proc-version-openwrt"

hardware=keenetic
config_is_keenetic || fail 'hardware=keenetic должен определяться как Keenetic'
hardware=merlin
Z2R_PROC_VERSION="$WORK/proc-version-netcraze"
config_is_keenetic && fail 'явный hardware=merlin не должен переопределяться строкой ядра'
hardware=
config_is_keenetic || fail 'netcraze в строке ядра должен давать Keenetic (CGI-контекст)'
Z2R_PROC_VERSION="$WORK/proc-version-openwrt"
config_is_keenetic && fail 'openwrt-ядро не должно определяться как Keenetic'
unset Z2R_PROC_VERSION

# Guard в CGI-контексте: hardware пуст, ndmc недоступен (PATH CGI), метки
# берутся из ip rule.
ndmc() { return 127; }
ip() {
  case "$*" in
    '-4 rule show') printf '%s\n' '1152:	from all fwmark 0xffffaad lookup 4102' ;;
    *) return 0 ;;
  esac
}
mkcfg iptables donttouch 0x04000000 1
Z2R_PROC_VERSION="$WORK/proc-version-netcraze"
out="$(config_keenetic_ensure_wssize_mark "$CFG")"
[ "$(config_get_var "$CFG" Z2R_WSSIZE_MARK)" = "0x80000000" ] \
  || fail "CGI-путь: метка не перенесена (fallback на ip rule не сработал): $(config_keenetic_used_marks "$CFG" | tr '\n' ' ')"
printf '%s' "$out" | grep -q 'перенесён' || fail "CGI-путь: нет сообщения о переносе: $out"
unset Z2R_PROC_VERSION
hardware=keenetic

# --- 6. статический wiring ------------------------------------------------
grep -q 'config_keenetic_ensure_wssize_mark "\$cfg"' "$REPO_DIR/lib/config.sh" \
  || fail 'lib/config.sh: нет вызова guard в config_keenetic_set_wan_iface'
grep -q 'config_keenetic_ensure_wssize_mark "\$root/config"' "$REPO_DIR/lib/actions.sh" \
  || fail 'lib/actions.sh: нет вызова guard после preserve_wssize'
grep -q 'config_keenetic_ensure_wssize_mark "\$new_cfg"' "$REPO_DIR/lib/actions.sh" \
  || fail 'lib/actions.sh: нет вызова guard в backup_smart_apply_flags'
grep -q 'config_keenetic_ensure_wssize_mark "\$cfg"' "$REPO_DIR/lib/submenus.sh" \
  || fail 'lib/submenus.sh: нет вызова guard в wssize_ramp_submenu'
grep -q 'config_keenetic_ensure_wssize_mark "\$CONFIG_FILE"' "$REPO_DIR/webui/cgi-bin/_lib.sh" \
  || fail 'webui/cgi-bin/_lib.sh: панель может включить ramp в обход guard'
grep -qx 'Z2R_WSSIZE_MARK=0x04000000' "$REPO_DIR/config.default" \
  || fail 'config.default: изменился дефолтный Z2R_WSSIZE_MARK'
grep -q -- '--filter-mark=${Z2R_WSSIZE_MARK}/${Z2R_WSSIZE_MARK}' "$REPO_DIR/config.default" \
  || fail 'config.default: --filter-mark должен брать метку из переменной'

echo "keenetic marks smoke ok"

