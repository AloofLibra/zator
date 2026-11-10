#!/bin/bash

GOOGLEVIDEO_IPS_URL="${Z2R_GOOGLEVIDEO_IPS_URL:-https://alooflibra.fun/z4r/googlevideo-ips.txt}"
GOOGLEVIDEO_IPS_FILE="${Z2R_GOOGLEVIDEO_IPS_FILE:-${ZATOR_ROOT:-/opt/zator}/lists/googlevideo-ipv4.txt}"
GOOGLEVIDEO_IPS_CACHE_TTL="${Z2R_GOOGLEVIDEO_IPS_CACHE_TTL-21600}"

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

googlevideo_ips_update() {
  local stamp now tmp request
  if [ -s "$GOOGLEVIDEO_IPS_FILE" ]; then
    stamp="$(stat -c %Y "$GOOGLEVIDEO_IPS_FILE" 2>/dev/null || stat -f %m "$GOOGLEVIDEO_IPS_FILE" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    case "$stamp:$now" in *[!0-9:]*) stamp=0 ;; esac
    [ $((now - stamp)) -lt "$GOOGLEVIDEO_IPS_CACHE_TTL" ] && return 0
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
    [ "${OSystem:-}" != WRT ] || googlevideo_openwrt_sync_central || true
    return 0
  fi
  rm -f "$tmp"
  printf '%s\nfailed\n' "$(date +%s)" > "$request.tmp.$$"
  mv -f "$request.tmp.$$" "$request"
  return 1
}

googlevideo_openwrt_sync_central() {
  local fwtype ip
  [ "${OSystem:-}" = WRT ] || return 0
  [ -s "$GOOGLEVIDEO_IPS_FILE" ] || return 0
  fwtype="$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" FWTYPE 2>/dev/null || true)"
  if [ "$fwtype" = iptables ] && command -v ipset >/dev/null 2>&1; then
    ipset list z2r_googlevideo4 >/dev/null 2>&1 || return 0
    while IFS= read -r ip; do
      case "$ip" in ''|\#*) continue ;; esac
      ipset add z2r_googlevideo4 "$ip" timeout 604800 -exist >/dev/null 2>&1 || return 1
    done < "$GOOGLEVIDEO_IPS_FILE"
  elif [ "$fwtype" = nftables ] && command -v nft >/dev/null 2>&1; then
    nft list set inet fw4 z2r_googlevideo4 >/dev/null 2>&1 || return 0
    while IFS= read -r ip; do
      case "$ip" in ''|\#*) continue ;; esac
      nft add element inet fw4 z2r_googlevideo4 "{ $ip timeout 7d }" >/dev/null 2>&1 || true
    done < "$GOOGLEVIDEO_IPS_FILE"
  fi
}

googlevideo_openwrt_dnsmasq() {
  local action="${1:-status}" fwtype section_type marker name domain include
  command -v uci >/dev/null 2>&1 || return 1
  section_type="$(uci -q get dhcp.z2r_googlevideo 2>/dev/null || true)"
  marker="$(uci -q get dhcp.z2r_googlevideo.z2r_managed 2>/dev/null || true)"
  fwtype="$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" FWTYPE 2>/dev/null || true)"
  include=/etc/nftables.d/zz-z2r-googlevideo.nft
  case "$action" in
    status)
      [ "$marker" = 1 ] && [ "$section_type" = ipset ] || return 1
      uci -q get dhcp.z2r_googlevideo.domain | grep -Fxq googlevideo.com
      ;;
    setup)
      [ "${OSystem:-}" = WRT ] || { echo "dnsmasq GGC source is OpenWrt-only" >&2; return 1; }
      if [ -n "$section_type" ] && { [ "$section_type" != ipset ] || [ "$marker" != 1 ]; }; then
        echo "Refusing to change unmanaged UCI section dhcp.z2r_googlevideo" >&2
        return 1
      fi
      if [ "$fwtype" = iptables ]; then
        command -v ipset >/dev/null 2>&1 || { echo "Install ipset for dnsmasq GGC capture" >&2; return 1; }
        dnsmasq -v 2>&1 | grep -qi ipset || { echo "Install dnsmasq-full with ipset support" >&2; return 1; }
        ipset create z2r_googlevideo4 hash:ip family inet timeout 604800 -exist || return 1
      elif [ "$fwtype" = nftables ]; then
        dnsmasq -v 2>&1 | grep -qi nftset || { echo "Install dnsmasq-full with nftset support" >&2; return 1; }
        [ ! -e "$include" ] || grep -q '^# z2r-managed-googlevideo$' "$include" || {
          echo "Refusing to overwrite unmanaged $include" >&2; return 1;
        }
        mkdir -p "${include%/*}" || return 1
        cat > "$include" <<'NFT'
# z2r-managed-googlevideo
set z2r_googlevideo4 {
	type ipv4_addr
	flags timeout
	timeout 7d
}
NFT
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
        uci set dhcp.z2r_googlevideo.table=fw4
        uci set dhcp.z2r_googlevideo.table_family=inet
        uci set dhcp.z2r_googlevideo.family=4
      fi
      uci commit dhcp || return 1
      if [ "$fwtype" = nftables ]; then /etc/init.d/firewall reload >/dev/null 2>&1 || return 1; fi
      /etc/init.d/dnsmasq restart >/dev/null 2>&1 || return 1
      ;;
    remove)
      [ "$marker" = 1 ] || return 0
      uci -q delete dhcp.z2r_googlevideo || return 1
      uci commit dhcp || return 1
      if [ -f "$include" ] && grep -q '^# z2r-managed-googlevideo$' "$include"; then rm -f "$include"; /etc/init.d/firewall reload >/dev/null 2>&1 || true; fi
      if [ "$fwtype" = iptables ] && command -v ipset >/dev/null 2>&1; then ipset destroy z2r_googlevideo4 >/dev/null 2>&1 || true; fi
      /etc/init.d/dnsmasq restart >/dev/null 2>&1 || return 1
      ;;
    *) return 2 ;;
  esac
}

googlevideo_openwrt_export_local() {
  local fwtype tmp ip raw
  fwtype="$(config_get_var "${ZAPRET2_ROOT:-/opt/zapret2}/config" FWTYPE 2>/dev/null || true)"
  tmp="${GOOGLEVIDEO_IPS_FILE}.tmp.$$"
  raw="${tmp}.raw"
  {
    [ ! -s "$GOOGLEVIDEO_IPS_FILE" ] || sed -n '2,$p' "$GOOGLEVIDEO_IPS_FILE"
    if [ "$fwtype" = iptables ] && command -v ipset >/dev/null 2>&1; then
      ipset save z2r_googlevideo4 2>/dev/null | awk '$1=="add" && $2=="z2r_googlevideo4" {print $3}'
    elif [ "$fwtype" = nftables ] && command -v nft >/dev/null 2>&1; then
      nft list set inet fw4 z2r_googlevideo4 2>/dev/null | sed -n '/elements = {/,/}/p' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' || true
    fi
  } | awk 'NF==1 && $0 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ {print}' | sort -u > "$raw" || { rm -f "$tmp" "$raw"; return 1; }
  {
    printf '# googlevideo IPv4 local OpenWrt DNS + central; generated=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    while IFS= read -r ip; do googlevideo_ipv4_public "$ip" && printf '%s\n' "$ip"; done < "$raw"
  } > "$tmp"
  rm -f "$raw"
  googlevideo_ips_validate "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$GOOGLEVIDEO_IPS_FILE"
}
