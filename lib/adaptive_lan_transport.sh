# This repository, including its original source code and implementation, is licensed under GNU GPL v3.0; see LICENSE for the full terms. Redistribution, modification, and reuse must comply with that license and preserve applicable copyright and license notices. Unauthorized copying, including verbatim code copying or presenting this repository implementation or operating logic as your own, may be reported to the relevant hosting platforms.
#!/bin/sh

_adaptive_lan_uint_valid() {
  # ponytail: signed-shell epoch cap; use decimal-string compare before 2038 expansion.
  case "$1" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "${#1}" -le 10 ] || return 1
  [ "$1" -le 2147483647 ] 2>/dev/null
}

_adaptive_lan_recipe_proto() {
  case "${1:-}" in
    googlevideo-quic-h3-media-v1) printf 'udp\n' ;;
    tls-http1-v1|googlevideo-tcp-media-v1) printf 'tcp\n' ;;
    *) return 1 ;;
  esac
}

_adaptive_lan_ipv4_valid() {
  awk -v ip="$1" 'BEGIN {
    n = split(ip, octet, ".")
    if (n != 4) exit 1
    for (i = 1; i <= 4; i++) {
      if (octet[i] !~ /^[0-9]+$/ || length(octet[i]) > 3) exit 1
      if (length(octet[i]) > 1 && substr(octet[i], 1, 1) == "0") exit 1
      if (octet[i] + 0 > 255) exit 1
    }
    exit 0
  }'
}

_adaptive_lan_public_ipv4_valid() {
  _adaptive_lan_ipv4_valid "$1" || return 1
  awk -F. '{
    a=$1+0; b=$2+0; c=$3+0
    if (a==0 || a==10 || a==127 || a>=224 ||
        (a==100 && b>=64 && b<=127) ||
        (a==169 && b==254) ||
        (a==172 && b>=16 && b<=31) ||
        (a==192 && (b==168 || (b==0 && (c==0 || c==2)) || (b==88 && c==99))) ||
        (a==198 && (b==18 || b==19 || (b==51 && c==100))) ||
        (a==203 && b==0 && c==113)) exit 1
  }' <<EOF
$1
EOF
}

# Validate a narrowly scoped IPv4/TCP/443 probe lease and its expiry.
adaptive_lan_lease_valid() {
  [ "$#" -eq 6 ] || return 1
  local source_ip="$1" source_port="$2" destination_ip="$3"
  local destination_port="$4" expires="$5" now="$6"
  _adaptive_lan_ipv4_valid "$source_ip" || return 1
  _adaptive_lan_ipv4_valid "$destination_ip" || return 1
  _adaptive_lan_uint_valid "$source_port" && [ "$source_port" -ge 62000 ] && [ "$source_port" -le 62999 ] || return 1
  [ "$destination_port" = 443 ] || return 1
  _adaptive_lan_uint_valid "$expires" && _adaptive_lan_uint_valid "$now" || return 1
  [ "$expires" -gt "$now" ]
}

# One controller owns the lease directory; temp+rename avoids partial records.
adaptive_lan_lease_write() {
  [ "$#" -ge 8 ] && [ "$#" -le 9 ] || return 1
  local dir="$1" test_id="$2" source_ip="$3" source_port="$4"
  local destination_ip="$5" expires="$6" now="$7" recipe="$8" owner="${9:-}"
  case "$test_id" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  [ "${#test_id}" -le 64 ] || return 1
  _adaptive_lan_recipe_proto "$recipe" >/dev/null || return 1
  [ -z "$owner" ] || [[ "$owner" =~ ^[a-f0-9]{32}$ ]] || return 1
  adaptive_lan_lease_valid "$source_ip" "$source_port" "$destination_ip" 443 "$expires" "$now" || return 1
  mkdir -p "$dir" || return 1
  local tmp="$dir/.$test_id.tmp.$$"
  (umask 077; if [ -n "$owner" ]; then
    printf '%s\t%s\t%s\t%s\t443\t%s\t%s\t%s\n' "$test_id" "$source_ip" "$source_port" "$destination_ip" "$expires" "$recipe" "$owner" > "$tmp"
  else
    printf '%s\t%s\t%s\t%s\t443\t%s\t%s\n' "$test_id" "$source_ip" "$source_port" "$destination_ip" "$expires" "$recipe" > "$tmp"
  fi) || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$dir/$test_id.tsv" || { rm -f "$tmp"; return 1; }
}

adaptive_lan_lease_read() {
  [ "$#" -eq 3 ] || return 1
  local dir="$1" test_id="$2" now="$3" path record
  case "$test_id" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  [ "${#test_id}" -le 64 ] || return 1
  _adaptive_lan_uint_valid "$now" || return 1
  path="$dir/$test_id.tsv"
  [ -f "$path" ] || return 1
  record="$(awk -F '\t' -v id="$test_id" '((NF == 7) || (NF == 8 && $8 ~ /^[a-f0-9]{32}$/)) && $1 == id { n++; if (n == 1) print } END { if (n != 1) exit 1 }' "$path")" || return 1
  local id source_ip source_port destination_ip destination_port expires recipe owner
  IFS="$(printf '\t')" read -r id source_ip source_port destination_ip destination_port expires recipe owner <<EOF
$record
EOF
  _adaptive_lan_recipe_proto "$recipe" >/dev/null || return 1
  adaptive_lan_lease_valid "$source_ip" "$source_port" "$destination_ip" "$destination_port" "$expires" "$now" || return 1
  if [ -n "$owner" ]; then
    printf '%s %s %s %s %s %s %s %s\n' "$id" "$source_ip" "$source_port" "$destination_ip" "$destination_port" "$expires" "$recipe" "$owner"
  else
    printf '%s %s %s %s %s %s %s\n' "$id" "$source_ip" "$source_port" "$destination_ip" "$destination_port" "$expires" "$recipe"
  fi
}

adaptive_lan_lease_remove() {
  [ "$#" -eq 2 ] || return 1
  local dir="$1" test_id="$2"
  case "$test_id" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  [ "${#test_id}" -le 64 ] || return 1
  rm -f "$dir/$test_id.tsv"
}

# Share the existing supersweep mutex so only one probe owns queue 65535.
adaptive_lan_probe_lock_acquire() {
  local lock_dir="${Z2R_ADAPTIVE_LOCK_DIR:-${Z2R_SUPERSWEEP_DIR:-/tmp/z2r-supersweep}.lock}"
  local boot_file="${Z2R_ADAPTIVE_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
  local boot_id owner pid old_boot stale self_pid="${BASHPID:-$$}"
  boot_id="$(cat "$boot_file" 2>/dev/null)"
  [ -n "$boot_id" ] || boot_id=-
  if ! (umask 077; mkdir "$lock_dir") 2>/dev/null; then
    [ -r "$lock_dir/owner" ] || return 1
    IFS="$(printf '\t')" read -r owner pid old_boot < "$lock_dir/owner" || return 1
    if [ "$owner" = adaptive-lan ] && [ "$pid" = "$self_pid" ] && [ "$old_boot" = "$boot_id" ]; then
      _Z2R_ADAPTIVE_LAN_LOCKED=1
      return 0
    fi
    [ "$owner" = adaptive-lan ] || return 1
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null && [ "$old_boot" = "$boot_id" ] && return 1
    local listing
    listing="$(_adaptive_lan_firewall_listing)" || return 1
    printf '%s\n' "$listing" | grep -Eq 'Z2R_ADAPTIVE_LAN|z2r.adaptive.lan' && return 1
    stale="$lock_dir.stale.$$"
    [ ! -e "$stale" ] || return 1
    mv "$lock_dir" "$stale" 2>/dev/null || return 1
    rm -rf "$stale" || return 1
    (umask 077; mkdir "$lock_dir") 2>/dev/null || return 1
  fi
  (umask 077; printf 'adaptive-lan\t%s\t%s\n' "$self_pid" "$boot_id" > "$lock_dir/owner") || {
    rm -f "$lock_dir/owner"
    rmdir "$lock_dir" 2>/dev/null || :
    return 1
  }
  _Z2R_ADAPTIVE_LAN_LOCKED=1
}

adaptive_lan_probe_lock_release() {
  local lock_dir="${Z2R_ADAPTIVE_LOCK_DIR:-${Z2R_SUPERSWEEP_DIR:-/tmp/z2r-supersweep}.lock}"
  local boot_file="${Z2R_ADAPTIVE_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
  local boot_id owner pid lock_boot self_pid="${BASHPID:-$$}"
  boot_id="$(cat "$boot_file" 2>/dev/null)"
  [ -n "$boot_id" ] || boot_id=-
  [ -r "$lock_dir/owner" ] || return 1
  IFS="$(printf '\t')" read -r owner pid lock_boot < "$lock_dir/owner" || return 1
  [ "$owner" = adaptive-lan ] && [ "$pid" = "$self_pid" ] && [ "$lock_boot" = "$boot_id" ] || return 1
  rm -f "$lock_dir/owner" && rmdir "$lock_dir" || return 1
  _Z2R_ADAPTIVE_LAN_LOCKED=0
}

_adaptive_lan_iptables_table() {
  local table="$1"
  shift
  if [ -z "${_Z2R_ADAPTIVE_IPT_WAIT_DONE:-}" ]; then
    if iptables -w -t mangle -L FORWARD -n >/dev/null 2>&1; then _Z2R_ADAPTIVE_IPT_WAIT=-w; else _Z2R_ADAPTIVE_IPT_WAIT=; fi
    _Z2R_ADAPTIVE_IPT_WAIT_DONE=1
  fi
  iptables ${_Z2R_ADAPTIVE_IPT_WAIT:+$_Z2R_ADAPTIVE_IPT_WAIT} -t "$table" "$@"
}

_adaptive_lan_iptables() {
  _adaptive_lan_iptables_table mangle "$@"
}

_adaptive_lan_iptables_delete_if_present() {
  _adaptive_lan_iptables -C "$@" 2>/dev/null || return 0
  _adaptive_lan_iptables -D "$@"
}

_adaptive_lan_firewall_listing() {
  local table
  case "${FWTYPE:-iptables}" in
    iptables)
      for table in raw mangle nat filter; do
        _adaptive_lan_iptables_table "$table" -S || return 1
      done
      _adaptive_lan_iptables_table security -S 2>/dev/null || :
      ;;
    nft|nftables) nft -a list ruleset ;;
    *) return 1 ;;
  esac
}

_adaptive_lan_controller_alive() {
  local pid="$1" arg path="${ZATOR_ROOT:-/opt/zator}/tools/adaptive-controller.sh"
  kill -0 "$pid" 2>/dev/null || return 1
  [ -r "${Z2R_ADAPTIVE_PROC_ROOT:-/proc}/$pid/cmdline" ] || return 0
  while IFS= read -r -d '' arg; do
    [ "$arg" = "$path" ] && return 0
  done < "${Z2R_ADAPTIVE_PROC_ROOT:-/proc}/$pid/cmdline" 2>/dev/null
  return 1
}

# Pick a packet-mark bit that does not overlap current mark assignments. Some
# Keenetic NDM policies use full-width tags (for example 0x4d61676f), so a
# globally hard-coded "reserved" bit can already be set on forwarded traffic.
_adaptive_lan_pick_test_mark() {
  local listing candidate assignment config_mark collision value
  listing="$(_adaptive_lan_firewall_listing)" || return 1
  local -a candidates=(0x10000000 0x01000000 0x02000000 0x04000000 0x08000000 0x00010000 0x00020000 0x00040000 0x00080000 0x00000001 0x00000002 0x00000004 0x00000008)
  local -a config_marks=("${DESYNC_MARK:-0}" "${DESYNC_MARK_POSTNAT:-0}" "${FILTER_MARK:-0}" "${CLIENT_SCOPE_MARK_MASK:-0}")
  local -a assignments=()
  while IFS= read -r assignment; do
    [ -n "$assignment" ] && assignments+=("${assignment%%/*}")
  done < <(printf '%s\n' "$listing" | awk '
    {
      if ($0 ~ /z2r_adaptive_lan|Z2R_ADAPTIVE_LAN/) next
      for (i=1; i<NF; i++) {
        if ($i == "--set-xmark" || $i == "--set-mark" || $i == "--or-mark" || $i == "--and-mark" || $i == "--xor-mark") print $(i+1)
        if (($i == "meta" || $i == "ct") && $(i+1) == "mark" && $(i+2) == "set") {
          for (j=i+3; j<=NF; j++) if ($j ~ /^0[xX][0-9a-fA-F]+$/) print $j
        }
      }
    }
  ')
  for candidate in "${candidates[@]}"; do
    collision=0
    for config_mark in "${config_marks[@]}" "${assignments[@]}"; do
      case "$config_mark" in ''|*[!0-9a-fA-FxX]*) collision=1; break ;; esac
      value=$((config_mark)) 2>/dev/null || { collision=1; break; }
      if (( (value & candidate) != 0 )); then collision=1; break; fi
    done
    if [ "$collision" = 0 ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

_adaptive_lan_has_queue_65535() {
  awk '
    {
      is_queue=0; has_65535=0
      for (i=1; i<NF; i++) {
        if ($i == "-j" && $(i+1) == "NFQUEUE") is_queue=1
        if ($i == "--queue-num" && $(i+1) == 65535) has_65535=1
        if ($i == "--queue-balance") {
          split($(i+1), q, ":")
          if (q[1] <= 65535 && q[2] >= 65535) has_65535=1
        }
      }
      if (is_queue && has_65535) found=1
    }
    END { exit !found }
  '
}

_adaptive_lan_queue_free() {
  local table listing
  case "${FWTYPE:-}" in
    iptables)
      for table in raw mangle nat filter security; do
        listing="$(_adaptive_lan_iptables_table "$table" -S 2>/dev/null)" || {
          [ "$table" = security ] && continue
          return 1
        }
        printf '%s\n' "$listing" | _adaptive_lan_has_queue_65535 && return 1
      done
      ;;
    nft|nftables)
      listing="$(nft -a list ruleset)" || return 1
      printf '%s\n' "$listing" | awk '
        {
          for (i=1; i<=NF; i++) if ($i == "queue") {
            j=i+1
            if ($j == "num") j++
            else {
              while (j<=NF && $j!="to" && $j!="num" && $j!="comment") j++
              if ($j == "to" || $j == "num") j++
              else continue
            }
            split($j, q, "-")
            last=(q[2] == "" ? q[1] : q[2])
            if (q[1] ~ /^[0-9]+$/ && last ~ /^[0-9]+$/ && q[1] <= 65535 && last >= 65535) found=1
          }
        }
        END { exit !found }
      ' && return 1
      ;;
    *) return 1 ;;
  esac
  return 0
}

_adaptive_lan_nft_handles() {
  local tag="$1" strict="${2:-0}"
  awk -v tag="$tag" -v strict="$strict" '
    $1 == "table" { next }
    $1 == "chain" { next }
    /^[[:space:]]*}[[:space:]]*$/ { next }
    {
      if (index($0, "comment \"" tag "\"") && match($0, /# handle [0-9]+/)) {
        split(substr($0, RSTART), h, " "); print h[3]; count++
      } else if (strict && $0 ~ /[^[:space:]]/) foreign=1
    }
    END { if ((strict == 1 && foreign) || (strict == 2 && count > 1)) exit 1 }
  '
}

_adaptive_lan_nft_install() {
  local proto="$1"
  shift
  local table="${ZAPRET_NFT_TABLE:-zapret2}" source_ip="$1" source_port="$2"
  local destination_ip="$3" destination_port="$4" mark="$5" hook direction rule_pair listing tag handles
  local post=postnat_hook pre=prenat_hook
  case "$table" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  if [ "${POSTNAT:-1}" = 0 ] && [ "${POSTNAT_ALL:-0}" != 1 ]; then
    post=postrouting_hook
    pre=prerouting_hook
  fi
  for hook in "$post" "$pre"; do
    listing="$(nft -a list chain inet "$table" "$hook")" || return 1
    tag="z2r_adaptive_lan_$([ "$hook" = postnat_hook ] && printf post || printf pre)"
    handles="$(printf '%s\n' "$listing" | _adaptive_lan_nft_handles "$tag")" || return 1
    [ -z "$handles" ] || return 1
  done
  if nft list chain inet "$table" z2r_adaptive_lan >/dev/null 2>&1; then return 1; fi
  _Z2R_ADAPTIVE_LAN_NFT=1
  _Z2R_ADAPTIVE_LAN_NFT_TABLE="$table"
  _Z2R_ADAPTIVE_LAN_NFT_POST_HOOK="$post"
  _Z2R_ADAPTIVE_LAN_NFT_PRE_HOOK="$pre"
  {
    printf 'add chain inet %s z2r_adaptive_lan\n' "$table"
    for rule_pair in "$post:original" "$pre:reply"; do
      hook=${rule_pair%:*}
      direction=${rule_pair#*:}
      printf 'add rule inet %s z2r_adaptive_lan meta l4proto %s ct direction %s ct original ip saddr %s ct original proto-src %s ct original ip daddr %s ct original proto-dst %s meta mark set meta mark | %s comment "z2r_adaptive_lan"\n' \
        "$table" "$proto" "$direction" "$source_ip" "$source_port" "$destination_ip" "$destination_port" "$mark"
      printf 'add rule inet %s z2r_adaptive_lan meta l4proto %s ct direction %s ct original ip saddr %s ct original proto-src %s ct original ip daddr %s ct original proto-dst %s queue flags bypass to 65535 comment "z2r_adaptive_lan"\n' \
        "$table" "$proto" "$direction" "$source_ip" "$source_port" "$destination_ip" "$destination_port"
      printf 'add rule inet %s z2r_adaptive_lan meta l4proto %s ct direction %s ct original ip saddr %s ct original proto-src %s ct original ip daddr %s ct original proto-dst %s accept comment "z2r_adaptive_lan"\n' \
        "$table" "$proto" "$direction" "$source_ip" "$source_port" "$destination_ip" "$destination_port"
    done
    printf 'insert rule inet %s %s jump z2r_adaptive_lan comment "z2r_adaptive_lan_post"\n' "$table" "$post"
    printf 'insert rule inet %s %s jump z2r_adaptive_lan comment "z2r_adaptive_lan_pre"\n' "$table" "$pre"
  } | nft -f - || return 1
}

_adaptive_lan_nft_remove() {
  local table="${_Z2R_ADAPTIVE_LAN_NFT_TABLE:-${ZAPRET_NFT_TABLE:-zapret2}}"
  local hook listing handles plan= tag handle
  local post="${_Z2R_ADAPTIVE_LAN_NFT_POST_HOOK:-postnat_hook}"
  local pre="${_Z2R_ADAPTIVE_LAN_NFT_PRE_HOOK:-prenat_hook}"
  for hook in "$post" "$pre"; do
    listing="$(nft -a list chain inet "$table" "$hook")" || return 1
    tag="z2r_adaptive_lan_$([ "$hook" = "$post" ] && printf post || printf pre)"
    handles="$(printf '%s\n' "$listing" | _adaptive_lan_nft_handles "$tag" 2)" || return 1
    if [ -n "$handles" ]; then plan="${plan}delete rule inet $table $hook handle $handles
"; fi
  done
  listing="$(nft -a list chain inet "$table" z2r_adaptive_lan 2>/dev/null)" || {
    [ -z "$plan" ] || return 1
    _Z2R_ADAPTIVE_LAN_NFT=0
    return 0
  }
  handles="$(printf '%s\n' "$listing" | _adaptive_lan_nft_handles z2r_adaptive_lan 1)" || return 1
  for handle in $handles; do plan="${plan}delete rule inet $table z2r_adaptive_lan handle $handle
"; done
  plan="${plan}delete chain inet $table z2r_adaptive_lan
"
  printf '%s' "$plan" | nft -f - || return 1
  _Z2R_ADAPTIVE_LAN_NFT=0
}

adaptive_lan_transport_stop() {
  [ "${_Z2R_ADAPTIVE_LAN_LOCKED:-0}" = 1 ] || return 0
  if [ "${_Z2R_ADAPTIVE_LAN_NFT:-0}" = 1 ]; then
    _adaptive_lan_nft_remove || return 1
  else
    if [ "${_Z2R_ADAPTIVE_LAN_REPLY_HOOK:-0}" = 1 ]; then
      _adaptive_lan_iptables_delete_if_present FORWARD -m conntrack --ctdir REPLY \
        --ctorigsrc "$_Z2R_ADAPTIVE_LAN_SRC_IP" --ctorigsrcport "$_Z2R_ADAPTIVE_LAN_SRC_PORT" \
        --ctorigdst "$_Z2R_ADAPTIVE_LAN_DST_IP" --ctorigdstport 443 \
        -m comment --comment z2r-adaptive-lan-reply -j Z2R_ADAPTIVE_LAN || return 1
      _Z2R_ADAPTIVE_LAN_REPLY_HOOK=0
    fi
    if [ "${_Z2R_ADAPTIVE_LAN_ORIGINAL_HOOK:-0}" = 1 ]; then
      _adaptive_lan_iptables_delete_if_present FORWARD -m conntrack --ctdir ORIGINAL \
        --ctorigsrc "$_Z2R_ADAPTIVE_LAN_SRC_IP" --ctorigsrcport "$_Z2R_ADAPTIVE_LAN_SRC_PORT" \
        --ctorigdst "$_Z2R_ADAPTIVE_LAN_DST_IP" --ctorigdstport 443 \
        -m comment --comment z2r-adaptive-lan-original -j Z2R_ADAPTIVE_LAN || return 1
      _Z2R_ADAPTIVE_LAN_ORIGINAL_HOOK=0
    fi
    if [ "${_Z2R_ADAPTIVE_LAN_POST_HOOK:-0}" = 1 ]; then
      _adaptive_lan_iptables_delete_if_present POSTROUTING -m comment --comment z2r-adaptive-lan-post -j Z2R_ADAPTIVE_LAN_POST || return 1
      _Z2R_ADAPTIVE_LAN_POST_HOOK=0
    fi
    if [ "${_Z2R_ADAPTIVE_LAN_CHAIN:-0}" = 1 ]; then
      if _adaptive_lan_iptables -S Z2R_ADAPTIVE_LAN >/dev/null 2>&1; then
        _adaptive_lan_iptables -F Z2R_ADAPTIVE_LAN && _adaptive_lan_iptables -X Z2R_ADAPTIVE_LAN || return 1
      fi
      _Z2R_ADAPTIVE_LAN_CHAIN=0
    fi
    if [ "${_Z2R_ADAPTIVE_LAN_POST_CHAIN:-0}" = 1 ]; then
      if _adaptive_lan_iptables -S Z2R_ADAPTIVE_LAN_POST >/dev/null 2>&1; then
        _adaptive_lan_iptables -F Z2R_ADAPTIVE_LAN_POST && _adaptive_lan_iptables -X Z2R_ADAPTIVE_LAN_POST || return 1
      fi
      _Z2R_ADAPTIVE_LAN_POST_CHAIN=0
    fi
  fi
  adaptive_lan_probe_lock_release || return 1
  if [ -n "${_Z2R_ADAPTIVE_LAN_STATE_FILE:-}" ]; then
    rm -f "$_Z2R_ADAPTIVE_LAN_STATE_FILE" || return 1
    _Z2R_ADAPTIVE_LAN_STATE_FILE=""
  fi
  _Z2R_ADAPTIVE_LAN_LOCKED=0
}

_adaptive_lan_write_transport_state() {
  [ "$#" -eq 4 ] || return 1
  local run_dir="$1" test_id="$2" mark="$3" production_mark="$4"
  local state="$run_dir/probe/transport.tsv" tmp now lease
  local lease_id source_ip source_port destination_ip destination_port expires recipe
  [[ "$test_id" =~ ^[a-f0-9]{32}$ ]] || return 1
  [[ "$mark" =~ ^0x[0-9a-fA-F]{1,8}$ && "$production_mark" =~ ^(0x[0-9a-fA-F]{1,8}|[1-9][0-9]{0,9})$ ]] || return 1
  case "$FWTYPE" in iptables|nft|nftables) ;; *) return 1 ;; esac
  [[ -d "$run_dir" && ! -L "$run_dir" && -d "$run_dir/probe" && ! -L "$run_dir/probe" ]] || return 1
  now="$(date +%s)" || return 1
  lease="$(adaptive_lan_lease_read "$run_dir/leases" "$test_id" "$now")" || return 1
  set -- $lease
  lease_id="$1" source_ip="$2" source_port="$3" destination_ip="$4"
  destination_port="$5" expires="$6" recipe="$7"
  tmp="$(mktemp "$run_dir/probe/.transport.XXXXXX")" || return 1
  (umask 077; printf '1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$FWTYPE" "$lease_id" "$mark" "$production_mark" "$source_ip" "$source_port" \
    "$destination_ip" "$destination_port" "$expires" "$recipe" > "$tmp") || {
    rm -f "$tmp"; return 1;
  }
  chmod 600 "$tmp" && mv -f "$tmp" "$state" || { rm -f "$tmp"; return 1; }
  _Z2R_ADAPTIVE_LAN_STATE_FILE="$state"
}

_adaptive_lan_reconcile_one() {
  [ "$#" -eq 1 ] || return 1
  local run_dir="$1" run_id="${1##*/}" state="$1/probe/transport.tsv"
  local ver backend state_id state_mark state_prod state_src state_sport state_dst state_dport state_expires state_recipe state_proto
  local owner controller owner_boot boot_id lock_dir
  local lease now queue_file qpid arg private_lua found_binary=0 found_queue=0 found_uid=0 found_lua=0 uid_gid_pending=0
  local selected_mark rule_reply rule_original rule_post nft_post nft_pre nft_chain nft_post_listing nft_pre_listing nft_post_handles nft_pre_handles nft_chain_handles
  [[ "$run_id" =~ ^[a-f0-9]{32}$ && -d "$run_dir" && ! -L "$run_dir" ]] || return 1
  [[ -f "$state" && ! -L "$state" && -r "$state" ]] || return 0
  [[ "$(find "$state" -type f -perm 600 -print 2>/dev/null)" = "$state" ]] || return 1
  awk -F '\t' 'NF == 11 {n++} END {exit n != 1}' "$state" || return 1
  IFS="$(printf '\t')" read -r ver backend state_id state_mark state_prod state_src state_sport state_dst state_dport state_expires state_recipe < "$state" || return 1
  [[ "$ver" = 1 && "$backend" = "${FWTYPE:-}" && "$state_id" = "$run_id" &&
     "$state_mark" =~ ^0x[0-9a-fA-F]{1,8}$ && "$state_prod" =~ ^(0x[0-9a-fA-F]{1,8}|[1-9][0-9]{0,9})$ &&
     "$state_sport" =~ ^[0-9]{5}$ && "$state_dport" = 443 && "$state_expires" =~ ^[0-9]{1,10}$ &&
     ( "$state_recipe" = tls-http1-v1 || "$state_recipe" = googlevideo-tcp-media-v1 || "$state_recipe" = googlevideo-quic-h3-media-v1 ) ]] || return 1
  state_proto="$(_adaptive_lan_recipe_proto "$state_recipe")" || return 1
  [[ "$(cat "$run_dir/state" 2>/dev/null)" != complete && "$(cat "$run_dir/state" 2>/dev/null)" != failed ]] || return 0
  case "$(cat "${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/adaptive/mode" 2>/dev/null)" in TEST_ONLY|AGENT_BETA) ;; *) return 0 ;; esac
  now="$(date +%s)" || return 1
  lease="$(adaptive_lan_lease_read "$run_dir/leases" "$run_id" "$now")" || return 0
  set -- $lease
  [[ "$1" = "$state_id" && "$2" = "$state_src" && "$3" = "$state_sport" &&
     "$4" = "$state_dst" && "$5" = "$state_dport" && "$6" = "$state_expires" && "$7" = "$state_recipe" ]] || return 1
  queue_file="${Z2R_ADAPTIVE_QUEUE_FILE:-/proc/net/netfilter/nfnetlink_queue}"
  qpid="$(awk '$1==65535 {n++; pid=$2} END {if(n==1) print pid; else exit 1}' "$queue_file" 2>/dev/null)" || return 1
  case "$qpid" in ''|*[!0-9]*) return 1 ;; esac
  private_lua="$run_dir/probe/locked.lua"
  [[ -f "$private_lua" && ! -L "$private_lua" ]] || return 1
  while IFS= read -r -d '' arg; do
    case "$arg" in nfqws2|*/nfqws2) found_binary=1 ;; esac
    [[ "$arg" != --qnum=65535 ]] || found_queue=1
    if [ "$uid_gid_pending" = 1 ]; then
      [ "$arg" != 65533 ] || found_uid=1
      uid_gid_pending=0
    fi
    case "$arg" in
      --uid=65533:65533) found_uid=1 ;;
      --uid=65533) uid_gid_pending=1 ;;
    esac
    [[ "$arg" != "--lua-init=@$private_lua" ]] || found_lua=1
  done < "${Z2R_ADAPTIVE_PROC_ROOT:-/proc}/$qpid/cmdline" 2>/dev/null
  [[ "$found_binary" = 1 && "$found_queue" = 1 && "$found_uid" = 1 && "$found_lua" = 1 ]] || return 1
  lock_dir="${Z2R_ADAPTIVE_LOCK_DIR:-${Z2R_SUPERSWEEP_DIR:-/tmp/z2r-supersweep}.lock}"
  [[ -d "$lock_dir" && ! -L "$lock_dir" && -r "$lock_dir/owner" && ! -L "$lock_dir/owner" ]] || return 1
  IFS="$(printf '\t')" read -r owner controller owner_boot < "$lock_dir/owner" || return 1
  [[ "$owner" = adaptive-lan ]] || return 1
  boot_id="$(cat "${Z2R_ADAPTIVE_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" 2>/dev/null)"
  [[ -n "$boot_id" ]] || boot_id=-
  [[ "$owner_boot" = "$boot_id" ]] && _adaptive_lan_controller_alive "$controller" || return 1
  [ -r "${Z2R_ADAPTIVE_PROC_ROOT:-/proc}/$controller/cmdline" ] || return 1
  tr '\000' '\n' < "${Z2R_ADAPTIVE_PROC_ROOT:-/proc}/$controller/cmdline" | grep -Fx "$run_id" >/dev/null || return 1
  [[ "$state_prod" = "$DESYNC_MARK" ]] || return 1
  selected_mark="$(_adaptive_lan_pick_test_mark)" || return 1
  [[ "$selected_mark" = "$state_mark" ]] || return 1
  set -- $lease
  case "$backend" in
    iptables)
      rule_reply="FORWARD -m conntrack --ctdir REPLY --ctorigsrc $2 --ctorigsrcport $3 --ctorigdst $4 --ctorigdstport 443 -m comment --comment z2r-adaptive-lan-reply -j Z2R_ADAPTIVE_LAN"
      rule_original="FORWARD -m conntrack --ctdir ORIGINAL --ctorigsrc $2 --ctorigsrcport $3 --ctorigdst $4 --ctorigdstport 443 -m comment --comment z2r-adaptive-lan-original -j Z2R_ADAPTIVE_LAN"
      rule_post="POSTROUTING -m comment --comment z2r-adaptive-lan-post -j Z2R_ADAPTIVE_LAN_POST"
      if _adaptive_lan_iptables -C $rule_reply 2>/dev/null &&
         _adaptive_lan_iptables -C $rule_original 2>/dev/null &&
         _adaptive_lan_iptables -C $rule_post 2>/dev/null; then return 0; fi
      # A complete NDM rebuild removes all adaptive chains. Partial state is ambiguous.
      if _adaptive_lan_iptables -S Z2R_ADAPTIVE_LAN >/dev/null 2>&1 ||
         _adaptive_lan_iptables -S Z2R_ADAPTIVE_LAN_POST >/dev/null 2>&1; then return 1; fi
      ;;
    nft|nftables)
      nft_post=postnat_hook; nft_pre=prenat_hook
      if [ "${POSTNAT:-1}" = 0 ] && [ "${POSTNAT_ALL:-0}" != 1 ]; then
        nft_post=postrouting_hook; nft_pre=prerouting_hook
      fi
      nft_post_listing="$(nft -a list chain inet "${ZAPRET_NFT_TABLE:-zapret2}" "$nft_post" 2>/dev/null)" || return 1
      nft_pre_listing="$(nft -a list chain inet "${ZAPRET_NFT_TABLE:-zapret2}" "$nft_pre" 2>/dev/null)" || return 1
      nft_chain="$(nft -a list chain inet "${ZAPRET_NFT_TABLE:-zapret2}" z2r_adaptive_lan 2>/dev/null)" || nft_chain=
      nft_post_handles="$(printf '%s\n' "$nft_post_listing" | _adaptive_lan_nft_handles z2r_adaptive_lan_post)" || return 1
      nft_pre_handles="$(printf '%s\n' "$nft_pre_listing" | _adaptive_lan_nft_handles z2r_adaptive_lan_pre)" || return 1
      nft_chain_handles="$(printf '%s\n' "$nft_chain" | _adaptive_lan_nft_handles z2r_adaptive_lan 1)" || return 1
      if [ "$(printf '%s\n' "$nft_post_handles" | awk 'NF {n++} END {print n+0}')" = 1 ] &&
         [ "$(printf '%s\n' "$nft_pre_handles" | awk 'NF {n++} END {print n+0}')" = 1 ] &&
         [ "$(printf '%s\n' "$nft_chain_handles" | awk 'NF {n++} END {print n+0}')" = 6 ] &&
         [ "$(printf '%s\n' "$nft_chain" | grep -Fc "ct original ip saddr $state_src")" = 6 ] &&
         [ "$(printf '%s\n' "$nft_chain" | grep -Fc "ct original proto-src $state_sport")" = 6 ] &&
         [ "$(printf '%s\n' "$nft_chain" | grep -Fc "ct original ip daddr $state_dst")" = 6 ] &&
         [ "$(printf '%s\n' "$nft_chain" | grep -Fc "ct original proto-dst $state_dport")" = 6 ] &&
         [ "$(printf '%s\n' "$nft_chain" | grep -Fc 'ct direction original')" = 3 ] &&
         [ "$(printf '%s\n' "$nft_chain" | grep -Fc 'ct direction reply')" = 3 ] &&
         [ "$(printf '%s\n' "$nft_chain" | grep -Fc "meta l4proto $state_proto")" = 6 ] &&
         [ "$(printf '%s\n' "$nft_chain" | grep -Fc 'queue flags bypass to 65535')" = 2 ] &&
         [ "$(printf '%s\n' "$nft_chain" | grep -Fc "meta mark set meta mark | $state_mark")" = 2 ] &&
         printf '%s\n' "$nft_post_listing" | grep -Fq 'jump z2r_adaptive_lan' &&
         printf '%s\n' "$nft_pre_listing" | grep -Fq 'jump z2r_adaptive_lan'; then return 0; fi
      # Restore only after the complete owned chain and both jumps vanished.
      [ -z "$nft_post_handles$nft_pre_handles$nft_chain" ] || return 1
      ;;
    *) return 1 ;;
  esac
  _adaptive_lan_queue_free || return 1
  export Z2R_ADAPTIVE_TRANSPORT_RECONCILE=1
  export Z2R_ADAPTIVE_RECONCILE_MARK="$state_mark"
  export Z2R_ADAPTIVE_NFQWS2_PID="$qpid"
  export Z2R_SUPERSWEEP_DIR="$run_dir"
  if ! adaptive_lan_transport_start "$run_dir/leases" "$run_id" "$now"; then
    unset Z2R_ADAPTIVE_TRANSPORT_RECONCILE Z2R_ADAPTIVE_RECONCILE_MARK Z2R_ADAPTIVE_NFQWS2_PID Z2R_SUPERSWEEP_DIR
    return 1
  fi
  unset Z2R_ADAPTIVE_TRANSPORT_RECONCILE Z2R_ADAPTIVE_RECONCILE_MARK Z2R_ADAPTIVE_NFQWS2_PID Z2R_SUPERSWEEP_DIR
  return 0
}

adaptive_lan_transport_reconcile() {
  local base="${Z2R_ADAPTIVE_DIR:-/tmp/z2r-adaptive}" run run_id result=0
  case "${FWTYPE:-}" in iptables|nft|nftables) ;; *) return 0 ;; esac
  [[ -d "$base" && ! -L "$base" ]] || return 0
  for run in "$base"/*; do
    [[ -d "$run" && ! -L "$run" ]] || continue
    run_id="${run##*/}"
    [[ "$run_id" =~ ^[a-f0-9]{32}$ ]] || continue
    _adaptive_lan_reconcile_one "$run" || result=1
  done
  return "$result"
}

# Recover only an abandoned adaptive-lan owner after its controller and
# private nfqws2 have exited. A live/unknown queue owner is never signalled.
adaptive_lan_transport_recover_stale() {
  [ "$#" -eq 1 ] || return 1
  local base="$1" lock_dir="${Z2R_ADAPTIVE_LOCK_DIR:-/tmp/z2r-supersweep.lock}"
  local boot_file="${Z2R_ADAPTIVE_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
  local proc_root="${Z2R_ADAPTIVE_PROC_ROOT:-/proc}" queue_file="${Z2R_ADAPTIVE_QUEUE_FILE:-/proc/net/netfilter/nfnetlink_queue}"
  local boot_id owner controller owner_boot state run run_id recovery_run lease_file record id src_ip src_port dst_ip dst_port expiry recipe
  local queue_state queue_pid arg have_binary have_queue have_private_lua recovery_dir self_pid="${BASHPID:-$$}"
  [ -d "$base" ] && [ ! -L "$base" ] && [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ] || return 1
  [ -f "$lock_dir/owner" ] && [ ! -L "$lock_dir/owner" ] || return 0
  [ -r "$lock_dir/owner" ] || return 1
  IFS="$(printf '\t')" read -r owner controller owner_boot < "$lock_dir/owner" || return 1
  [ "$owner" = adaptive-lan ] || return 0
  case "${FWTYPE:-}" in iptables|nft|nftables) ;; *) return 1 ;; esac
  case "$controller" in ''|*[!0-9]*) return 1 ;; esac
  boot_id="$(cat "$boot_file" 2>/dev/null)"; [ -n "$boot_id" ] || boot_id=-
  [ "$owner_boot" != "$boot_id" ] || ! _adaptive_lan_controller_alive "$controller" || return 1
  [ -r "$queue_file" ] || return 1
  run=""; run_id=""; recovery_run=""
  for run in "$base"/*; do
    [ -d "$run" ] && [ ! -L "$run" ] || continue
    run_id="${run##*/}"
    [[ "$run_id" =~ ^[a-f0-9]{32}$ ]] || continue
    [ ! -L "$run/state" ] || return 1
    state="$(cat "$run/state" 2>/dev/null)"
    case "$state" in complete|failed) continue ;; esac
    [ -d "$run/leases" ] && [ ! -L "$run/leases" ] || continue
    [ -f "$run/leases/$run_id.tsv" ] && [ ! -L "$run/leases/$run_id.tsv" ] || continue
    [ -z "${recovery_run:-}" ] || return 1
    recovery_run="$run"
  done
  [ -n "${recovery_run:-}" ] || return 1
  run="$recovery_run"; run_id="${run##*/}"
  recovery_dir="$lock_dir/recovery"
  (umask 077; mkdir "$recovery_dir") 2>/dev/null || return 1
  IFS="$(printf '\t')" read -r owner controller owner_boot < "$lock_dir/owner" || { rmdir "$recovery_dir" 2>/dev/null || :; return 1; }
  [ "$owner" = adaptive-lan ] || { rmdir "$recovery_dir" 2>/dev/null || :; return 1; }
  if [ "$owner_boot" = "$boot_id" ] && _adaptive_lan_controller_alive "$controller"; then
    rmdir "$recovery_dir" 2>/dev/null || :; return 1
  fi
  queue_state="$(awk '$1==65535 {n++; pid=$2} END {if(n==0) print "free"; else if(n==1) print pid; else print "duplicate"}' "$queue_file")"
  case "$queue_state" in
    free) ;;
    duplicate|*[!0-9]*) rmdir "$recovery_dir" 2>/dev/null || :; return 1 ;;
    *)
      queue_pid="$queue_state"
      have_binary=0; have_queue=0; have_private_lua=0
      while IFS= read -r -d '' arg; do
        case "$arg" in nfqws2|*/nfqws2) have_binary=1 ;; esac
        [ "$arg" = --qnum=65535 ] && have_queue=1
        [ "$arg" = "--lua-init=@$run/probe/locked.lua" ] && have_private_lua=1
      done < "$proc_root/$queue_pid/cmdline" 2>/dev/null || :
      [ "$have_binary" = 1 ] && [ "$have_queue" = 1 ] && [ "$have_private_lua" = 1 ] || {
        rmdir "$recovery_dir" 2>/dev/null || :; return 1;
      }
      kill "$queue_pid" 2>/dev/null || { rmdir "$recovery_dir" 2>/dev/null || :; return 1; }
      for _ in 1 2 3 4 5; do
        sleep 1
        queue_state="$(awk '$1==65535 {n++; pid=$2} END {if(n==0) print "free"; else if(n==1) print pid; else print "duplicate"}' "$queue_file")"
        [ "$queue_state" = free ] && break
      done
      [ "$queue_state" = free ] || { rmdir "$recovery_dir" 2>/dev/null || :; return 1; }
      ;;
  esac
  printf 'adaptive-lan\t%s\t%s\n' "$self_pid" "$boot_id" > "$lock_dir/owner.recover.$$" || {
    rmdir "$recovery_dir" 2>/dev/null || :; return 1;
  }
  mv -f "$lock_dir/owner.recover.$$" "$lock_dir/owner" || {
    rm -f "$lock_dir/owner.recover.$$"; rmdir "$recovery_dir" 2>/dev/null || :; return 1;
  }
  if [ "${FWTYPE:-iptables}" = nft ] || [ "${FWTYPE:-}" = nftables ]; then
    _Z2R_ADAPTIVE_LAN_LOCKED=1
    _Z2R_ADAPTIVE_LAN_NFT=1
    _Z2R_ADAPTIVE_LAN_NFT_TABLE="${ZAPRET_NFT_TABLE:-zapret2}"
    if [ "${POSTNAT:-1}" = 0 ] && [ "${POSTNAT_ALL:-0}" != 1 ]; then
      _Z2R_ADAPTIVE_LAN_NFT_POST_HOOK=postrouting_hook
      _Z2R_ADAPTIVE_LAN_NFT_PRE_HOOK=prerouting_hook
    else
      _Z2R_ADAPTIVE_LAN_NFT_POST_HOOK=postnat_hook
      _Z2R_ADAPTIVE_LAN_NFT_PRE_HOOK=prenat_hook
    fi
  else
    lease_file="$run/leases/$run_id.tsv"
    record="$(awk -F '\t' -v expected_id="$run_id" '((NF==7) || (NF==8 && length($8)==32 && $8 !~ /[^a-f0-9]/)) && $1==expected_id {n++; if(n==1) print} END {if(n!=1) exit 1}' "$lease_file")" || return 1
    IFS="$(printf '\t')" read -r id src_ip src_port dst_ip dst_port expiry recipe owner <<EOF
$record
EOF
    _adaptive_lan_recipe_proto "$recipe" >/dev/null && [ "$dst_port" = 443 ] && _adaptive_lan_ipv4_valid "$src_ip" && _adaptive_lan_ipv4_valid "$dst_ip" \
      && _adaptive_lan_uint_valid "$src_port" && [ "$src_port" -ge 62000 ] && [ "$src_port" -le 62999 ] || return 1
    _Z2R_ADAPTIVE_LAN_LOCKED=1
    _Z2R_ADAPTIVE_LAN_SRC_IP="$src_ip"; _Z2R_ADAPTIVE_LAN_SRC_PORT="$src_port"; _Z2R_ADAPTIVE_LAN_DST_IP="$dst_ip"
    _Z2R_ADAPTIVE_LAN_REPLY_HOOK=1; _Z2R_ADAPTIVE_LAN_ORIGINAL_HOOK=1
    _Z2R_ADAPTIVE_LAN_POST_HOOK=1; _Z2R_ADAPTIVE_LAN_CHAIN=1; _Z2R_ADAPTIVE_LAN_POST_CHAIN=1
  fi
  rmdir "$recovery_dir" || return 1
  adaptive_lan_transport_stop || return 1
  rm -f "$run/probe/transport.tsv" || return 1
  printf 'failed\n' > "$run/state"
  printf 'controller_crash_recovered\n' > "$run/error"
}

adaptive_lan_transport_run() (
  [ "$#" -ge 4 ] || exit 1
  local lease_dir="$1" test_id="$2" now="$3"
  shift 3
  _adaptive_lan_run_cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if ! adaptive_lan_transport_stop; then
      echo 'adaptive LAN firewall cleanup failed; keep lock for recovery' >&2
      rc=1
    fi
    exit "$rc"
  }
  trap '_adaptive_lan_run_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  adaptive_lan_transport_start "$lease_dir" "$test_id" "$now" || exit 1
  "$@"
)

# Start only against the exact nfqws2 child owned by the caller; queue number alone is not ownership.
adaptive_lan_transport_start() {
  [ "$#" -eq 3 ] || return 1
  case "${FWTYPE:-}" in iptables|nft|nftables) ;; *) return 1 ;; esac
  local lease_dir="$1" test_id="$2" now="$3" lease qpid expected_pid proc_file private_lua
  local source_ip source_port destination_ip destination_port expires recipe mark production_mark arg
  local have_binary=0 have_queue=0 have_uid=0 have_private_lua=0 uid_gid_pending=0
  lease="$(adaptive_lan_lease_read "$lease_dir" "$test_id" "$now")" || return 1
  set -- $lease
  test_id="$1" source_ip="$2" source_port="$3" destination_ip="$4"
  destination_port="$5" expires="$6" recipe="$7"
  local proto
  proto="$(_adaptive_lan_recipe_proto "$recipe")" || return 1
  [ -n "${DESYNC_MARK:-}" ] || return 1
  qpid="$(awk '$1 == 65535 { n++; pid=$2 } END { if (n == 1) print pid; else exit 1 }' "${Z2R_ADAPTIVE_QUEUE_FILE:-/proc/net/netfilter/nfnetlink_queue}" 2>/dev/null)" || return 1
  case "$qpid" in ''|*[!0-9]*) return 1 ;; esac
  expected_pid="${Z2R_ADAPTIVE_NFQWS2_PID:-}"
  case "$expected_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$qpid" = "$expected_pid" ] || return 1
  proc_file="${Z2R_ADAPTIVE_PROC_ROOT:-/proc}/$qpid/cmdline"
  private_lua="${Z2R_SUPERSWEEP_DIR:-/tmp/z2r-supersweep}/probe/locked.lua"
  [ -f "$private_lua" ] && [ ! -L "$private_lua" ] || return 1
  while IFS= read -r -d '' arg; do
    case "$arg" in nfqws2|*/nfqws2) have_binary=1 ;; esac
    [ "$arg" != --qnum=65535 ] || have_queue=1
    if [ "$uid_gid_pending" = 1 ]; then
      [ "$arg" != 65533 ] || have_uid=1
      uid_gid_pending=0
    fi
    case "$arg" in
      --uid=65533:65533) have_uid=1 ;;
      --uid=65533) uid_gid_pending=1 ;;
    esac
    [ "$arg" != "--lua-init=@$private_lua" ] || have_private_lua=1
  done < "$proc_file" 2>/dev/null
  [ "$have_binary" = 1 ] && [ "$have_queue" = 1 ] && [ "$have_uid" = 1 ] && [ "$have_private_lua" = 1 ] || return 1
  production_mark="$DESYNC_MARK"
  _supersweep_transport_mark_safe "$production_mark" || return 1
  [ "$((production_mark))" -ne 0 ] || return 1
  # Keep the temporary re-entry mark separate from the production fwmark and
  # from marks already assigned by the active firewall (notably Keenetic NDM).
  # The production bypass mark is applied later in POSTROUTING.
  if [ "${Z2R_ADAPTIVE_TRANSPORT_RECONCILE:-0}" = 1 ]; then
    mark="${Z2R_ADAPTIVE_RECONCILE_MARK:-}"
    [ -n "$mark" ] || return 1
    [ "$mark" = "$(_adaptive_lan_pick_test_mark)" ] || return 1
    _Z2R_ADAPTIVE_LAN_LOCKED=1
  else
    mark="$(_adaptive_lan_pick_test_mark)" || return 1
    adaptive_lan_probe_lock_acquire || return 1
  fi
  _Z2R_ADAPTIVE_LAN_LOCKED=1
  _Z2R_ADAPTIVE_LAN_MARK="$mark"
  _Z2R_ADAPTIVE_LAN_PRODUCTION_MARK="$production_mark"
  if ! _adaptive_lan_queue_free; then
    adaptive_lan_probe_lock_release || :
    _Z2R_ADAPTIVE_LAN_LOCKED=0
    return 1
  fi
  case "$FWTYPE" in
    nft|nftables)
      if _adaptive_lan_nft_install "$proto" "$source_ip" "$source_port" "$destination_ip" "$destination_port" "$mark"; then return 0; fi
      adaptive_lan_transport_stop || :
      return 1 ;;
  esac
  if _adaptive_lan_iptables -S Z2R_ADAPTIVE_LAN >/dev/null 2>&1 ||
     _adaptive_lan_iptables -S Z2R_ADAPTIVE_LAN_POST >/dev/null 2>&1; then
    if adaptive_lan_probe_lock_release; then _Z2R_ADAPTIVE_LAN_LOCKED=0; fi
    return 1
  fi
  _adaptive_lan_iptables -N Z2R_ADAPTIVE_LAN || { adaptive_lan_transport_stop || :; return 1; }
  _Z2R_ADAPTIVE_LAN_CHAIN=1
  _adaptive_lan_iptables -N Z2R_ADAPTIVE_LAN_POST || { adaptive_lan_transport_stop || :; return 1; }
  _Z2R_ADAPTIVE_LAN_POST_CHAIN=1
  _Z2R_ADAPTIVE_LAN_SRC_IP="$source_ip"
  _Z2R_ADAPTIVE_LAN_SRC_PORT="$source_port"
  _Z2R_ADAPTIVE_LAN_DST_IP="$destination_ip"
  local direction
  for direction in ORIGINAL REPLY; do
    local terminal
    terminal=RETURN
    [ "$direction" != REPLY ] || terminal=ACCEPT
    _adaptive_lan_iptables -A Z2R_ADAPTIVE_LAN -p "$proto" -m mark --mark "$mark/$mark" -m conntrack --ctdir "$direction" \
      --ctorigsrc "$source_ip" --ctorigsrcport "$source_port" \
      --ctorigdst "$destination_ip" --ctorigdstport "$destination_port" \
      -j "$terminal" || { adaptive_lan_transport_stop || :; return 1; }
    _adaptive_lan_iptables -A Z2R_ADAPTIVE_LAN -p "$proto" -m mark ! --mark "$production_mark/$production_mark" -m mark ! --mark "$mark/$mark" -m conntrack --ctdir "$direction" \
      --ctorigsrc "$source_ip" --ctorigsrcport "$source_port" \
      --ctorigdst "$destination_ip" --ctorigdstport "$destination_port" \
      -j MARK --set-xmark "$mark/$mark" || { adaptive_lan_transport_stop || :; return 1; }
    _adaptive_lan_iptables -A Z2R_ADAPTIVE_LAN -p "$proto" -m mark --mark "$mark/$mark" -m conntrack --ctdir "$direction" \
      --ctorigsrc "$source_ip" --ctorigsrcport "$source_port" \
      --ctorigdst "$destination_ip" --ctorigdstport "$destination_port" \
      -j NFQUEUE --queue-num 65535 || { adaptive_lan_transport_stop || :; return 1; }
    if [ "$direction" = REPLY ]; then
      _adaptive_lan_iptables -A Z2R_ADAPTIVE_LAN -p "$proto" -m mark --mark "$mark/$mark" -m conntrack --ctdir "$direction" \
        --ctorigsrc "$source_ip" --ctorigsrcport "$source_port" \
        --ctorigdst "$destination_ip" --ctorigdstport "$destination_port" \
        -j ACCEPT || { adaptive_lan_transport_stop || :; return 1; }
    fi
  done
  # Reply packets must precede Keenetic's production queue-300 rule. Original
  # packets enter only after the existing FORWARD rules have applied NDM marks,
  # MSS clamping, and filters; the exact postrouting mark then skips queue 300.
  _adaptive_lan_iptables -I FORWARD 1 -m conntrack --ctdir REPLY \
    --ctorigsrc "$source_ip" --ctorigsrcport "$source_port" \
    --ctorigdst "$destination_ip" --ctorigdstport "$destination_port" \
    -m comment --comment z2r-adaptive-lan-reply -j Z2R_ADAPTIVE_LAN || {
    adaptive_lan_transport_stop || :
    return 1
  }
  _Z2R_ADAPTIVE_LAN_REPLY_HOOK=1
  _adaptive_lan_iptables -A FORWARD -m conntrack --ctdir ORIGINAL \
    --ctorigsrc "$source_ip" --ctorigsrcport "$source_port" \
    --ctorigdst "$destination_ip" --ctorigdstport "$destination_port" \
    -m comment --comment z2r-adaptive-lan-original -j Z2R_ADAPTIVE_LAN || {
    adaptive_lan_transport_stop || :
    return 1
  }
  _Z2R_ADAPTIVE_LAN_ORIGINAL_HOOK=1
  # FORWARD ACCEPT does not stop later POSTROUTING hooks. Mark only this exact
  # original tuple with the production nfqws2 bypass mark after the test queue
  # has processed it, so the production queue skips it and later NDM rules run.
  _adaptive_lan_iptables -A Z2R_ADAPTIVE_LAN_POST -p "$proto" -m conntrack --ctdir ORIGINAL \
    --ctorigsrc "$source_ip" --ctorigsrcport "$source_port" \
    --ctorigdst "$destination_ip" --ctorigdstport "$destination_port" \
    -j MARK --set-xmark "$production_mark/$production_mark" || {
    adaptive_lan_transport_stop || :
    return 1
  }
  _adaptive_lan_iptables -I POSTROUTING 1 -m comment --comment z2r-adaptive-lan-post -j Z2R_ADAPTIVE_LAN_POST || {
    adaptive_lan_transport_stop || :
    return 1
  }
  _Z2R_ADAPTIVE_LAN_POST_HOOK=1
}

