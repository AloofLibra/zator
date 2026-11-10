#!/bin/bash

GOOGLEVIDEO_IPS_URL="${Z2R_GOOGLEVIDEO_IPS_URL:-https://alooflibra.fun/z4r/googlevideo-ips.txt}"
GOOGLEVIDEO_IPS_FILE="${Z2R_GOOGLEVIDEO_IPS_FILE:-${ZATOR_ROOT:-/opt/zator}/lists/googlevideo-ipv4.txt}"
GOOGLEVIDEO_IPS_CACHE_TTL="${Z2R_GOOGLEVIDEO_IPS_CACHE_TTL-21600}"
GOOGLEVIDEO_INGEST_URL="${Z2R_GOOGLEVIDEO_INGEST_URL:-https://alooflibra.fun/z4r/googlevideo-observations}"
GOOGLEVIDEO_LOCAL_FILE="${GOOGLEVIDEO_LOCAL_FILE:-${Z2R_GOOGLEVIDEO_LOCAL_FILE:-${TMPDIR:-/tmp}/z2r-googlevideo/local.tsv}}"

googlevideo_sniffer_arch() {
  local machine cpu
  machine="$(uname -m 2>/dev/null)"
  case "$machine" in
    aarch64|arm64) echo arm64 ;;
    arm|armv6l|armv7l|armv8l) echo arm ;;
    mips64) echo mips64 ;;
    mipsel*|mipsle*)
      cpu="$(tr '[:upper:]' '[:lower:]' <"${Z2R_GV_CPUINFO:-/proc/cpuinfo}" 2>/dev/null)"
      case "$cpu" in *lexra*|*5281*) echo lexra ;; *) echo mipselsf ;; esac ;;
    mips*) echo mipssf ;;
    powerpc|ppc) echo ppc ;;
    i386|i486|i586|i686) echo x86 ;;
    x86_64|amd64) echo x86_64 ;;
    riscv64) echo riscv64 ;;
    *) return 1 ;;
  esac
}

googlevideo_hostname_valid() {
  local host="${1,,}"
  host="${host%.}"
  case "$host" in
    *[!a-z0-9.-]*|.*|*..*|*.) return 1 ;;
    *.googlevideo.com) [ "$host" != googlevideo.com ] ;;
    *) return 1 ;;
  esac
}

# Event payload is passed as discrete fields by the UBus listener. Local
# observations live on tmpfs and never get merged into the central feed file.
googlevideo_observe_local() {
  local host="${1,,}" ip="$2" ttl="$3" fwtype table now expires tmp
  host="${host%.}"
  googlevideo_hostname_valid "$host" || return 1
  [ "${4:-A}" = A ] || return 1
  googlevideo_ipv4_public "$ip" || return 1
  case "$ttl" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#ttl}" -le 6 ] || ttl=604800
  ttl=$((10#$ttl))
  [ "$ttl" -gt 0 ] || return 1
  [ "$ttl" -le 604800 ] || ttl=604800
  # Kernel set is the union. Do not change the lifetime of a centrally sourced
  # member; the local row below records provenance separately.
  if [ ! -s "$GOOGLEVIDEO_IPS_FILE" ] || ! grep -Fxq "$ip" "$GOOGLEVIDEO_IPS_FILE"; then
    fwtype="${GOOGLEVIDEO_KERNEL_FWTYPE:-$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" FWTYPE 2>/dev/null || true)}"
    if [ "$fwtype" = iptables ] && command -v ipset >/dev/null 2>&1; then
      ipset add z2r_googlevideo4 "$ip" timeout "$ttl" -exist >/dev/null 2>&1 || {
        ipset create z2r_googlevideo4 hash:ip family inet timeout 604800 -exist >/dev/null 2>&1 || return 1
        ipset add z2r_googlevideo4 "$ip" timeout "$ttl" -exist >/dev/null 2>&1 || return 1
      }
    elif [ "$fwtype" = nftables ] && command -v nft >/dev/null 2>&1; then
      table="$(googlevideo_nft_table_name)"
      nft add element inet "$table" z2r_googlevideo4 "{ $ip timeout ${ttl}s }" >/dev/null 2>&1 || {
        # A concurrent answer may have inserted it. Accept only if it is now present.
        nft list set inet "$table" z2r_googlevideo4 2>/dev/null | grep -Fq "$ip" || return 1
      }
    else
      return 1
    fi
  fi
  now="$(date +%s)"; expires=$((now + ttl))
  mkdir -p "${GOOGLEVIDEO_LOCAL_FILE%/*}" || return 1
  tmp="${GOOGLEVIDEO_LOCAL_FILE}.tmp.$$"
  awk -F '\t' -v h="$host" -v ip="$ip" -v now="$now" '$3>now && !($1==h && $2==ip) {print}' "$GOOGLEVIDEO_LOCAL_FILE" 2>/dev/null > "$tmp" || :
  printf '%s\t%s\t%s\n' "$host" "$ip" "$expires" >> "$tmp"
  # Bound tmpfs state; newest rows survive.
  tail -n 8192 "$tmp" > "${tmp}.bounded" && mv -f "${tmp}.bounded" "$tmp" && mv -f "$tmp" "$GOOGLEVIDEO_LOCAL_FILE"
}

googlevideo_ips_validate() {
  local file="$1" line count=0 oldifs octet
  [ -s "$file" ] && [ "$(wc -c < "$file")" -le 262144 ] || return 1
  IFS= read -r line < "$file" || return 1
  case "$line" in '# googlevideo IPv4; generated='*) ;; *) return 1 ;; esac
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in *[!0-9.]*|.*|*.|*..*) return 1 ;; esac
    oldifs="$IFS"; IFS=.; set -- $line; IFS="$oldifs"
    [ "$#" -eq 4 ] || return 1
    for octet in "$@"; do
      case "$octet" in 0|[1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]) ;; *) return 1 ;; esac
    done
    googlevideo_ipv4_public "$line" || return 1
    count=$((count + 1))
    [ "$count" -le 8192 ] || return 1
  done < <(tail -n +2 "$file")
  [ "$count" -gt 0 ]
}

googlevideo_ipv4_public() {
  local a b c d oldifs="$IFS"
  case "$1" in ''|*[!0-9.]*|.*|*.|*..*) return 1 ;; esac
  IFS=.; set -- $1; IFS="$oldifs"
  [ "$#" -eq 4 ] || return 1
  a="$1"; b="$2"; c="$3"; d="$4"
  for octet in "$@"; do
    case "$octet" in 0|[1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]) ;; *) return 1 ;; esac
  done
  case "$a" in 0|10|127|224|225|226|227|228|229|230|231|232|233|234|235|236|237|238|239|240|241|242|243|244|245|246|247|248|249|250|251|252|253|254|255) return 1 ;; esac
  [ "$a" -eq 169 ] && [ "$b" -eq 254 ] && return 1
  [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 1
  [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 1
  [ "$a" -eq 192 ] && [ "$b" -eq 0 ] && [ "$c" -le 2 ] && return 1
  [ "$a" -eq 192 ] && [ "$b" -eq 88 ] && [ "$c" -eq 99 ] && return 1
  [ "$a" -eq 192 ] && [ "$b" -eq 31 ] && [ "$c" -eq 196 ] && return 1
  [ "$a" -eq 192 ] && [ "$b" -eq 52 ] && [ "$c" -eq 193 ] && return 1
  [ "$a" -eq 192 ] && [ "$b" -eq 175 ] && [ "$c" -eq 48 ] && return 1
  [ "$a" -eq 198 ] && { [ "$b" -eq 18 ] || [ "$b" -eq 19 ]; } && return 1
  [ "$a" -eq 198 ] && [ "$b" -eq 51 ] && [ "$c" -eq 100 ] && return 1
  [ "$a" -eq 203 ] && [ "$b" -eq 0 ] && [ "$c" -eq 113 ] && return 1
  [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 1
  return 0
}

googlevideo_ips_count() {
  [ -s "$GOOGLEVIDEO_IPS_FILE" ] || { printf '0\n'; return; }
  awk '!/^#/ && NF==1 {n++} END {print n+0}' "$GOOGLEVIDEO_IPS_FILE"
}

googlevideo_nft_table_name() {
  local table="${GOOGLEVIDEO_KERNEL_NFT_TABLE:-${ZAPRET_NFT_TABLE:-}}"
  if [ -z "$table" ]; then
    table="$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" ZAPRET_NFT_TABLE 2>/dev/null || true)"
  fi
  printf '%s\n' "${table:-zapret2}"
}

googlevideo_dnsmasq_has_feature() {
  local feature="$1"
  dnsmasq -v 2>&1 | sed -n 's/^Compile time options:[[:space:]]*//p' | tr ' ' '\n' | grep -Fxq "$feature"
}

googlevideo_dnsmasq_rule_present() {
  local fwtype="$1" table="$2" file="$3" expected
  case "$fwtype" in
    nftables) expected="nftset=/googlevideo.com/4#inet#$table#z2r_googlevideo4" ;;
    iptables) expected="ipset=/googlevideo.com/z2r_googlevideo4" ;;
    *) return 1 ;;
  esac
  grep -Fxq "$expected" "$file"
}

googlevideo_openwrt_dnsmasq_state() {
  local listener="${Z2R_GV_LISTENER:-/opt/zator/tools/googlevideo-dns-listener.sh}" supported=0
  if [ -r /etc/openwrt_release ] && command -v ubus >/dev/null 2>&1 && ubus list 2>/dev/null | grep -Fxq dnsmasq.dns; then
    supported=1
  else
    [ -x "${Z2R_GV_SNIFFER:-/opt/zator/tools/bin/googlevideo-dns-sniffer}" ] && supported=1
  fi
  [ "$supported" = 1 ] || { printf 'unsupported\n'; return 0; }
  if [ -x "$listener" ] && "$listener" status; then
    printf 'enabled\n'
  else
    printf 'disabled\n'
  fi
}

googlevideo_local_kernel_ips() {
  local now="$(date +%s)" ip
  [ -s "$GOOGLEVIDEO_LOCAL_FILE" ] || return 0
  awk -F '\t' -v now="$now" '$3>now {print $2}' "$GOOGLEVIDEO_LOCAL_FILE" | sort -u | head -n 128 | while IFS= read -r ip; do
    googlevideo_ipv4_public "$ip" || continue
    [ ! -s "$GOOGLEVIDEO_IPS_FILE" ] || ! grep -Fxq "$ip" "$GOOGLEVIDEO_IPS_FILE" || continue
    printf '%s\n' "$ip"
  done
}

# Called only from consented telemetry, and at most once every six hours.
googlevideo_upload_local_batch() {
  local uuid="$1" ips stamp now cache
  [ "${tel_enabled:-0}" = 1 ] && [ -n "${STATS_TOKEN:-}" ] || return 0
  cache="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/googlevideo-upload.ts"
  stamp=0; [ ! -f "$cache" ] || read -r stamp < "$cache"
  now="$(date +%s)"; case "$stamp:$now" in *[!0-9:]*) stamp=0 ;; esac
  [ $((now - stamp)) -ge 21600 ] || return 0
  ips="$(googlevideo_local_kernel_ips | paste -sd, -)"
  [ -n "$ips" ] || return 0
  if curl -4 -fsS --connect-timeout 3 --max-time 8 \
      --data-urlencode "token=$STATS_TOKEN" --data-urlencode "uuid=$uuid" \
      --data-urlencode "ips=$ips" "$GOOGLEVIDEO_INGEST_URL" >/dev/null 2>&1; then
    mkdir -p "${cache%/*}" || return 1
    printf '%s\n' "$now" > "$cache.tmp.$$" && mv -f "$cache.tmp.$$" "$cache"
  fi
}

googlevideo_ips_update() {
  local stamp now tmp request
  if [ -s "$GOOGLEVIDEO_IPS_FILE" ]; then
    stamp="$(stat -c %Y "$GOOGLEVIDEO_IPS_FILE" 2>/dev/null || stat -f %m "$GOOGLEVIDEO_IPS_FILE" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    case "$stamp:$now" in *[!0-9:]*) stamp=0 ;; esac
    if [ $((now - stamp)) -lt "$GOOGLEVIDEO_IPS_CACHE_TTL" ]; then googlevideo_kernel_set_sync || true; return 0; fi
  fi
  mkdir -p "${GOOGLEVIDEO_IPS_FILE%/*}" || return 1
  tmp="${GOOGLEVIDEO_IPS_FILE}.tmp.$$"
  request="${GOOGLEVIDEO_IPS_FILE}.request"
  if curl -4 -fsS --connect-timeout 3 --max-time 10 --max-filesize 262144 \
      "$GOOGLEVIDEO_IPS_URL" -o "$tmp" 2>/dev/null && googlevideo_ips_validate "$tmp"; then
    chmod 644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$GOOGLEVIDEO_IPS_FILE" || { rm -f "$tmp"; return 1; }
    printf '%s\nok\n' "$(date +%s)" > "$request.tmp.$$"
    mv -f "$request.tmp.$$" "$request"
    googlevideo_kernel_set_sync || true
    return 0
  fi
  rm -f "$tmp"
  printf '%s\nfailed\n' "$(date +%s)" > "$request.tmp.$$"
  mv -f "$request.tmp.$$" "$request"
  return 1
}

googlevideo_kernel_set_sync() {
  local fwtype table tmp attempt missing
  fwtype="$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" FWTYPE 2>/dev/null || true)"
  if [ "$fwtype" = iptables ] && command -v ipset >/dev/null 2>&1; then
    ipset create z2r_googlevideo4 hash:ip family inet timeout 604800 -exist || return 1
    [ -s "$GOOGLEVIDEO_IPS_FILE" ] || return 0
    awk '!/^#/ && NF==1 {print "add z2r_googlevideo4 " $1 " -exist"}' "$GOOGLEVIDEO_IPS_FILE" | ipset restore -exist
    return $?
  fi
  if [ "$fwtype" = nftables ] && command -v nft >/dev/null 2>&1; then
    table="$(googlevideo_nft_table_name)"
    if ! nft list set inet "$table" z2r_googlevideo4 >/dev/null 2>&1; then
      nft add set inet "$table" z2r_googlevideo4 '{ type ipv4_addr; flags timeout; timeout 7d; size 8192; }' || return 1
    fi
    [ -s "$GOOGLEVIDEO_IPS_FILE" ] || return 0
    tmp="${TMPDIR:-/tmp}/z2r-googlevideo-nft.$$"
    for attempt in 1 2; do
      missing="$( { nft list set inet "$table" z2r_googlevideo4 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' || :
        printf '%s\n' '#Z2R_IP_END'
        awk '!/^#/ && NF==1 {print $1}' "$GOOGLEVIDEO_IPS_FILE"
      } | awk '$0 == "#Z2R_IP_END" { phase=1; next } !phase { present[$0]=1; next } NF && !present[$1] { print $1 }' | sort -u)" || { rm -f "$tmp"; return 1; }
      [ -n "$missing" ] || { rm -f "$tmp"; return 0; }
      awk -v table="$table" 'BEGIN {printf "add element inet %s z2r_googlevideo4 { ", table; sep=""} NF {printf "%s%s", sep, $1; sep=", "} END {if (sep!="") print " }"}' <<EOF > "$tmp"
$missing
EOF
      nft -f "$tmp" && { rm -f "$tmp"; return 0; }
    done
    rm -f "$tmp"
    return 1
  fi
  return 0
}

googlevideo_openwrt_sync_central() {
  local fwtype ip
  [ "${OSystem:-}" = WRT ] || return 0
  googlevideo_kernel_set_sync
}

googlevideo_openwrt_dnsmasq() {
  local action="${1:-status}" fwtype section_type marker name domain include table file feature
  command -v uci >/dev/null 2>&1 || return 1
  section_type="$(uci -q get dhcp.z2r_googlevideo 2>/dev/null || true)"
  marker="$(uci -q get dhcp.z2r_googlevideo.z2r_managed 2>/dev/null || true)"
  fwtype="$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" FWTYPE 2>/dev/null || true)"
  table="$(googlevideo_nft_table_name)"
  include=/etc/nftables.d/zz-z2r-googlevideo.nft
  case "$action" in
    status)
      [ "$marker" = 1 ] && [ "$section_type" = ipset ] || return 1
      uci -q get dhcp.z2r_googlevideo.domain | grep -Fxq googlevideo.com || return 1
      uci -q get dhcp.z2r_googlevideo.name | grep -Fxq z2r_googlevideo4 || return 1
      case "$fwtype" in nftables) feature=nftset ;; iptables) feature=ipset ;; *) return 1 ;; esac
      googlevideo_dnsmasq_has_feature "$feature" || return 1
      for file in /var/etc/dnsmasq.conf.*; do
        [ -f "$file" ] || continue
        googlevideo_dnsmasq_rule_present "$fwtype" "$table" "$file" && return 0
      done
      return 1
      ;;
    setup)
      [ "${OSystem:-}" = WRT ] || { echo "dnsmasq GGC source is OpenWrt-only" >&2; return 1; }
      if [ -n "$section_type" ] && { [ "$section_type" != ipset ] || [ "$marker" != 1 ]; }; then
        echo "Refusing to change unmanaged UCI section dhcp.z2r_googlevideo" >&2
        return 1
      fi
      if [ "$fwtype" = iptables ]; then
        command -v ipset >/dev/null 2>&1 || { echo "Optional dnsmasq→ipset needs ipset; automatic UBus collection does not" >&2; return 1; }
        googlevideo_dnsmasq_has_feature ipset || { echo "Optional dnsmasq→ipset is unavailable; automatic UBus collection does not need dnsmasq-full" >&2; return 1; }
        ipset create z2r_googlevideo4 hash:ip family inet timeout 604800 -exist || return 1
      elif [ "$fwtype" = nftables ]; then
        googlevideo_dnsmasq_has_feature nftset || { echo "Optional dnsmasq→nftset is unavailable; automatic UBus collection does not need dnsmasq-full" >&2; return 1; }
        googlevideo_kernel_set_sync || return 1
      else
        echo "Unsupported FWTYPE: $fwtype" >&2
        return 1
      fi
      if [ -z "$section_type" ]; then uci set dhcp.z2r_googlevideo=ipset || return 1; fi
      uci set dhcp.z2r_googlevideo.z2r_managed=1 || return 1
      uci -q delete dhcp.z2r_googlevideo.name || true
      uci -q delete dhcp.z2r_googlevideo.domain || true
      uci add_list dhcp.z2r_googlevideo.name=z2r_googlevideo4 || return 1
      uci add_list dhcp.z2r_googlevideo.domain=googlevideo.com || return 1
      if [ "$fwtype" = nftables ]; then
        uci set dhcp.z2r_googlevideo.table="$table"
        uci set dhcp.z2r_googlevideo.table_family=inet
        uci set dhcp.z2r_googlevideo.family=4
      fi
      uci commit dhcp || return 1
      if [ "$fwtype" = nftables ]; then
        if [ -f "$include" ] && grep -q '^# z2r-managed-googlevideo$' "$include"; then rm -f "$include" || return 1; fi
        /etc/init.d/firewall reload >/dev/null 2>&1 || return 1
      fi
      /etc/init.d/dnsmasq restart >/dev/null 2>&1 || return 1
      ;;
    remove)
      [ "$marker" = 1 ] || return 0
      uci -q delete dhcp.z2r_googlevideo || return 1
      uci commit dhcp || return 1
      if [ "$fwtype" = nftables ] && [ -f "$include" ] && grep -q '^# z2r-managed-googlevideo$' "$include"; then
        rm -f "$include" || return 1
        /etc/init.d/firewall reload >/dev/null 2>&1 || true
      fi
      /etc/init.d/dnsmasq restart >/dev/null 2>&1 || return 1
      ;;
    *) return 2 ;;
  esac
}

googlevideo_openwrt_export_local() {
  [ -s "$GOOGLEVIDEO_LOCAL_FILE" ] || return 1
  printf '%s\n' "$GOOGLEVIDEO_LOCAL_FILE"
}
