#!/usr/bin/env bash
# No root, network, nft or iptables binary required.
set -euo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zator-transport.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -r "$REPO_DIR/lib/supersweep_transport.sh" ]] || fail 'isolated transport module is missing'
. "$REPO_DIR/lib/supersweep_transport.sh"

# Model only the mangle table; built-in production rules must survive.
declare -A MOCK_CHAINS=() rules=()
log=()
iptables() {
  log+=("$*")
  if [[ ${MOCK_FAIL_AT:-0} == "${#log[@]}" ]]; then return 1; fi
  if [[ ${MOCK_NO_WAIT:-0} == 1 && " $* " == *' -w '* ]]; then return 2; fi
  if [[ ${MOCK_BARE_WAIT:-0} == 1 && "$1" == -w && "${2:-}" == 5 ]]; then return 2; fi
  if [[ "$1 $2 $3 $4" == '-w 5 -t mangle' ]]; then
    shift 4
  elif [[ ${MOCK_BARE_WAIT:-0} == 1 && "$1 $2" == '-w -t' && "${3:-}" == mangle ]]; then
    shift 3
  elif [[ ${MOCK_NO_WAIT:-0} == 1 && "$1 $2" == '-t mangle' ]]; then
    shift 2
  else
    fail 'unexpected table or no xtables lock'
  fi
  local op=$1 chain=$2 text key
  shift 2
  text="$*"; key="$chain|$text"
  case "$op" in
    -L) [[ $chain == OUTPUT ]] || fail 'unexpected probe target'; return 0 ;;
    -nL)
      [[ ${MOCK_CHAINS[$chain]+yes} ]] || return 1
      for key in "${!rules[@]}"; do
        [[ $key == "$chain|"* && $key == *' -j Z2R_SS_'* ]] && printf ' %s
' "${key#*|}"
      done
      return 0 ;;
    -N) [[ ! ${MOCK_CHAINS[$chain]+yes} ]] || return 1; MOCK_CHAINS[$chain]=1 ;;
    -A|-I) [[ ${MOCK_CHAINS[$chain]+yes} ]] || return 1; rules[$key]=1 ;;
    -D) [[ ${rules[$key]+yes} ]] || return 1; unset 'rules[$key]' ;;
    -C) [[ ${rules[$key]+yes} ]] ;;
    -F) [[ $chain == Z2R_SS_* ]] || fail 'production flush'; for key in "${!rules[@]}"; do [[ $key != "$chain|"* ]] || unset 'rules[$key]'; done ;;
    -X) [[ ${MOCK_CHAINS[$chain]+yes} ]] || return 1; for key in "${!rules[@]}"; do [[ $key != "$chain|"* && $key != *"-j $chain" ]] || return 1; done; unset 'MOCK_CHAINS[$chain]' ;;
    *) fail "unexpected operation $op" ;;
  esac
}
for chain in OUTPUT POSTROUTING PREROUTING INPUT; do
  MOCK_CHAINS[$chain]=1
  rules["$chain|-j PRODUCTION"]=1
done
FWTYPE=iptables
Z2R_SUPERSWEEP_PORT_RANGE_FILE="$TMP_DIR/range"
printf '32768 60999\n' > "$Z2R_SUPERSWEEP_PORT_RANGE_FILE"
supersweep_transport_start || fail 'start rejected safe range'
[[ $Z2R_SUPERSWEEP_QNUM == 65535 && $Z2R_SUPERSWEEP_PORTS == 62000-62999 ]] || fail 'reserved constants'
[[ ${rules['Z2R_SS_OUT|-p tcp --sport 62000:62999 --dport 443 -m mark ! --mark 0x40000000/0x40000000 -j MARK --set-xmark 0x08000000/0x08000000']+yes} ]] || fail 'outbound-only classification must exclude nfqws fakes'
[[ ${rules['Z2R_SS_POST|-j NFQUEUE --queue-num 65535 --queue-bypass']+yes} ]] || fail 'isolated output queue'
[[ ${rules['Z2R_SS_IN|-j NFQUEUE --queue-num 65535 --queue-bypass']+yes} ]] || fail 'isolated reply queue'
[[ ${rules['Z2R_SS_POST|-j ACCEPT']+yes} && ${rules['Z2R_SS_IN|-j ACCEPT']+yes} ]] || fail 'production fallthrough after queue'
[[ ${rules['Z2R_SS_RAW|-j MARK --or-mark 1207959552']+yes} && ${rules['Z2R_SS_RAW|-j ACCEPT']+yes} ]] || fail 'private raw packets must bypass policy-mark rewriting'
[[ ${rules['OUTPUT|-p tcp --sport 62000:62999 --dport 443 -m owner ! --socket-exists -m mark ! --mark 0x40000000/0x40000000 -j Z2R_SS_OUT']+yes} ]] || fail 'socketless TCP close packets escape the probe route'
for key in "${!rules[@]}"; do
  case "$key" in
    POSTROUTING*Z2R_SS_POST) [[ $key == *'--sport 62000:62999 --dport 443'* && $key == *'--ctdir ORIGINAL'* && $key == *'! --mark 0x40000000/0x40000000'* ]] || fail 'unsafe output selection' ;;
    PREROUTING*Z2R_SS_PRE|INPUT*Z2R_SS_IN) [[ $key == *'--sport 443 --dport 62000:62999'* && $key == *'--ctstate ESTABLISHED --ctdir REPLY'* && $key == *'-m connmark --mark 0x08000000/0x08000000'* ]] || fail 'unsafe reply selection' ;;
  esac
done
before=${#log[@]}
supersweep_transport_start || fail 'second start'
[[ ${#log[@]} == "$before" ]] || fail 'duplicate start changed firewall'
supersweep_transport_check || fail 'valid transport rejected'
for key in "${!rules[@]}"; do
  if [[ $key == OUTPUT*Z2R_SS_OUT ]]; then
    unset 'rules[$key]'
    ! supersweep_transport_check || fail 'firewall reload was not detected'
    rules[$key]=1
    break
  fi
done
supersweep_transport_stop || fail 'stop'
supersweep_transport_stop || fail 'idempotent stop'
[[ ${#MOCK_CHAINS[@]} == 4 && ${#rules[@]} == 4 ]] || fail 'cleanup touched production or leaked rules'
# Reject unsafe configuration before the first firewall command.
for range in '32768 62000' '62000 62999' '62999 65535' '0 60999' '60999 32768' '1 65536' 'a b' '32768 60999 extra' '18446744073709584384 18446744073709612615'; do
  printf '%s\n' "$range" > "$Z2R_SUPERSWEEP_PORT_RANGE_FILE"
  before=${#log[@]}
  if supersweep_transport_start 2>"$TMP_DIR/error"; then fail "accepted unsafe range $range"; fi
  [[ ${#log[@]} == "$before" ]] || fail 'unsafe range mutated firewall'
done
printf '32768\t60999\n' > "$Z2R_SUPERSWEEP_PORT_RANGE_FILE"
for FWTYPE in auto ''; do
  before=${#log[@]}
  if supersweep_transport_start 2>"$TMP_DIR/error"; then fail 'accepted unsupported backend'; fi
  [[ -s "$TMP_DIR/error" && ${#log[@]} == "$before" ]] || fail 'backend rejection not explicit/side-effect free'
done
FWTYPE=iptables
for DESYNC_MARK in 0x08000000 0 08 0x invalid 4294967296; do
  before=${#log[@]}
  if supersweep_transport_start 2>"$TMP_DIR/error"; then fail "accepted invalid/colliding mark $DESYNC_MARK"; fi
  [[ ${#log[@]} == "$before" ]] || fail 'invalid mark mutated firewall'
done
unset DESYNC_MARK
for name in DESYNC_MARK_POSTNAT FILTER_MARK; do
  printf -v "$name" '%s' 0x08000000
  before=${#log[@]}
  if supersweep_transport_start 2>"$TMP_DIR/error"; then fail "accepted collision in $name"; fi
  [[ ${#log[@]} == "$before" ]] || fail 'mark collision mutated firewall'
  unset "$name"
done

# A foreign chain is never adopted, flushed or deleted.
MOCK_CHAINS[Z2R_SS_POST]=1
rules['Z2R_SS_POST|-j FOREIGN']=1
if supersweep_transport_start 2>"$TMP_DIR/error"; then fail 'adopted foreign chain'; fi
[[ ${rules['Z2R_SS_POST|-j FOREIGN']+yes} && ${#MOCK_CHAINS[@]} == 5 ]] || fail 'damaged foreign chain'
unset 'MOCK_CHAINS[Z2R_SS_POST]' 'rules[Z2R_SS_POST|-j FOREIGN]'

# Fail each installation command once: all successful partial writes roll back.
log=()
supersweep_transport_start || fail 'setup fault injection'
install_commands=${#log[@]}
supersweep_transport_stop || fail 'setup cleanup'
for ((i=1; i<=install_commands; i++)); do
  log=(); MOCK_FAIL_AT=$i
  if supersweep_transport_start 2>"$TMP_DIR/error"; then fail "ignored installation failure $i"; fi
  [[ ${#MOCK_CHAINS[@]} == 4 && ${#rules[@]} == 4 ]] || fail "partial installation leaked after command $i"
  supersweep_transport_stop || fail 'stop after failed start'
done
MOCK_FAIL_AT=0
# Failed hook removal must not flush live chains or tear down later guards.
log=()
supersweep_transport_start || fail 'setup cleanup fault'
MOCK_FAIL_AT=$((${#log[@]} + 1))
if supersweep_transport_stop 2>"$TMP_DIR/error"; then fail 'ignored cleanup failure'; fi
[[ ${rules['Z2R_SS_OUT|-j ACCEPT']+yes} && ${rules['Z2R_SS_PRE|-j ACCEPT']+yes} ]] || fail 'flushed chains while a hook remained live'
MOCK_FAIL_AT=0
supersweep_transport_stop || fail 'cleanup retry'
[[ ${#MOCK_CHAINS[@]} == 4 && ${#rules[@]} == 4 ]] || fail 'retry leaked rules'
# Native nft rules must return from zapret's own hook, not a separate base
# chain whose ACCEPT still falls through to the production NFQUEUE.
nft() {
  if [ "$1" = -f ]; then
    cat > "$TMP_DIR/nft.batch"
  elif [ "$1" = -a ]; then
    if [ "${NFT_TAGGED:-0}" = 1 ]; then
      printf 'table inet zapret2 {\n chain postnat_hook {\n'
      for ((h=42; h<53; h++)); do printf 'meta mark 1 comment "z2r_supersweep" # handle %s\n' "$h"; done
      printf ' }\n}\n'
    fi
  else
    if [ "$*" = 'list chain inet zapret2 z2r_supersweep_output' ]; then
      [ "${NFT_TAGGED:-0}" = 1 ] || return 1
    fi
    return 0
  fi
}
FWTYPE=nftables
supersweep_transport_start || fail 'native nft start'
grep -q 'insert rule inet zapret2 postnat_hook.*return' "$TMP_DIR/nft.batch" || fail 'missing production bypass'
grep -q 'z2r_supersweep_output.*skuid 0.*62000-62999' "$TMP_DIR/nft.batch" || fail 'nft not local-only'
grep -q 'type route hook output priority -1' "$TMP_DIR/nft.batch" || fail 'classification must survive mangle policy marks and reroute probes'
grep -q 'z2r_supersweep_output.*skuid 65533.*meta mark set meta mark | 0x40000000 | 0x08000000' "$TMP_DIR/nft.batch" || fail 'generated raw segments must follow the private connection, not the VPN'
grep -q 'z2r_supersweep_output.*skuid >= 0.*return' "$TMP_DIR/nft.batch" || fail 'socketless fallback must exclude other users and production nfqws2'
grep -q 'ct direction reply.*queue num 65535' "$TMP_DIR/nft.batch" || fail 'missing nft reply queue'
grep -q 'postnat_hook.*meta mark set meta mark | 0x20000000' "$TMP_DIR/nft.batch" || fail 'missing postnat protection mark'
NFT_TAGGED=1
supersweep_transport_check || fail 'nft ownership check'
NFT_TAGGED=0
! supersweep_transport_check || fail 'nft reload was not detected'
NFT_TAGGED=1
supersweep_transport_stop || fail 'native nft stop'
grep -q '^delete rule inet zapret2 postnat_hook handle 42$' "$TMP_DIR/nft.batch" || fail 'cleanup must delete exact owned handles'
grep -q '^delete chain inet zapret2 z2r_supersweep_output$' "$TMP_DIR/nft.batch" || fail 'owned output chain leaked'

# ndm-style external wipe: reconcile must reclaim stale chains and rebuild.
FWTYPE=iptables
unset _Z2R_SS_IPT_WAIT _Z2R_SS_IPT_WAIT_DONE _Z2R_SS_RECLAIM
log=()
supersweep_transport_start || fail 'setup wipe'
supersweep_transport_stop || fail 'setup wipe stop'
for chain in Z2R_SS_OUT Z2R_SS_POST Z2R_SS_PRE Z2R_SS_IN Z2R_SS_RAW; do
  MOCK_CHAINS[$chain]=1
done
rules['OUTPUT|-p tcp --sport 62000:62999 --dport 443 -m owner --uid-owner 0 -m mark ! --mark 0x40000000/0x40000000 -j Z2R_SS_OUT']=1
rules['Z2R_SS_OUT|-p tcp --sport 62000:62999 --dport 443 -m mark ! --mark 0x40000000/0x40000000 -j MARK --set-xmark 0x08000000/0x08000000']=1
DESYNC_MARK=0x40000000
supersweep_transport_reconcile || fail 'reconcile'
[[ ${rules['OUTPUT|-p tcp --sport 62000:62999 --dport 443 -m owner ! --socket-exists -m mark ! --mark 0x40000000/0x40000000 -j Z2R_SS_OUT']+yes} ]] || fail 'reconcile missed socketless hook'
supersweep_transport_stop || fail 'reconcile stop'
[[ ${#MOCK_CHAINS[@]} == 4 && ${#rules[@]} == 4 ]] || fail 'reconcile leaked'
unset DESYNC_MARK

# A live and correct transport must be a no-op for reconcile.
log=()
supersweep_transport_start || fail 'setup noop'
before=${#log[@]}
DESYNC_MARK=0x40000000
supersweep_transport_reconcile || fail 'reconcile noop'
[[ ${#log[@]} -le $((before + 1)) ]] || fail 'reconcile touched live rules'
supersweep_transport_stop || fail 'reconcile noop stop'
unset DESYNC_MARK

# Keenetic Entware iptables 1.4.21: -w exists only as a bare flag; -w 5 gives
# "Bad argument". The probe must pick the bare form and use it everywhere.
FWTYPE=iptables
unset _Z2R_SS_IPT_WAIT _Z2R_SS_IPT_WAIT_DONE
MOCK_BARE_WAIT=1
log=()
supersweep_transport_start || fail 'bare-w start'
[[ ${rules['Z2R_SS_OUT|-p tcp --sport 62000:62999 --dport 443 -m mark ! --mark 0x40000000/0x40000000 -j MARK --set-xmark 0x08000000/0x08000000']+yes} ]] || fail 'bare-w start missed classification'
supersweep_transport_check || fail 'bare-w check'
supersweep_transport_stop || fail 'bare-w stop'
[[ ${#MOCK_CHAINS[@]} == 4 && ${#rules[@]} == 4 ]] || fail 'bare-w cleanup leaked'
MOCK_BARE_WAIT=0

# Keenetic-style iptables 1.4.21 rejects -w entirely: the probe must disable it
# once and run the whole install/check/stop cycle without it.
FWTYPE=iptables
unset _Z2R_SS_IPT_WAIT _Z2R_SS_IPT_WAIT_DONE
MOCK_NO_WAIT=1
log=()
supersweep_transport_start || fail 'no-w start'
[[ ${rules['Z2R_SS_OUT|-p tcp --sport 62000:62999 --dport 443 -m mark ! --mark 0x40000000/0x40000000 -j MARK --set-xmark 0x08000000/0x08000000']+yes} ]] || fail 'no-w start missed classification'
supersweep_transport_check || fail 'no-w check'
supersweep_transport_stop || fail 'no-w stop'
[[ ${#MOCK_CHAINS[@]} == 4 && ${#rules[@]} == 4 ]] || fail 'no-w cleanup leaked'
MOCK_NO_WAIT=0
printf 'supersweep transport smoke: OK\n'
