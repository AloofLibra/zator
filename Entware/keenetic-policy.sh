#!/bin/sh

KEENETIC_POLICY_COMMENT="z2r-keenetic-policy"
KEENETIC_ZAPRET_CONFIG="/opt/zapret2/config"

keenetic_policy_log() {
    echo "[keenetic-policy] $*"
}

keenetic_policy_load_config() {
    [ -f "$KEENETIC_ZAPRET_CONFIG" ] || return 1
    POLICY_NAME="$(sed -n 's/^POLICY_NAME=//p' "$KEENETIC_ZAPRET_CONFIG" | tail -n1)"
    POLICY_MARK="$(sed -n 's/^POLICY_MARK=//p' "$KEENETIC_ZAPRET_CONFIG" | tail -n1)"
    POLICY_EXCLUDE="$(sed -n 's/^POLICY_EXCLUDE=//p' "$KEENETIC_ZAPRET_CONFIG" | tail -n1)"
    POLICY_NAME="${POLICY_NAME:-}"
    POLICY_MARK="${POLICY_MARK:-}"
    POLICY_EXCLUDE="${POLICY_EXCLUDE:-0}"
}

keenetic_policy_get_mark() {
    local name="$1"
    command -v ndmc >/dev/null 2>&1 || return 1
    ndmc -c "show ip policy" 2>/dev/null | awk -v policy="$name" '
        index($0, "name = " policy ",") || index($0, "description = " policy ":") { found=1; next }
        found && /mark[[:space:]]*[:=][[:space:]]*/ {
            sub(/^.*mark[[:space:]]*[:=][[:space:]]*/, "", $0)
            print ($0 ~ /^0x/ ? $0 : "0x" $0)
            exit
        }
    ' | tr -d ' \r'
}

keenetic_policy_normalize_mark() {
    printf '%s' "$1" | tr 'A-F' 'a-f' | sed 's/^0x//'
}

# Записывает марк в config и проверяет результат чтением обратно.
keenetic_policy_save_mark() {
    local mark="$1" saved

    if grep -q '^POLICY_MARK=' "$KEENETIC_ZAPRET_CONFIG"; then
        sed -i "s#^POLICY_MARK=.*#POLICY_MARK=$mark#" "$KEENETIC_ZAPRET_CONFIG" || return 1
    else
        printf 'POLICY_MARK=%s\n' "$mark" >> "$KEENETIC_ZAPRET_CONFIG" || return 1
    fi

    saved="$(sed -n 's/^POLICY_MARK=//p' "$KEENETIC_ZAPRET_CONFIG" | tail -n1)"
    [ "$saved" = "$mark" ]
}

keenetic_policy_sync_mark() {
    local actual

    KEENETIC_POLICY_LIVE_MARK=""

    keenetic_policy_load_config || return 0
    [ -n "$POLICY_NAME" ] || return 0

    actual="$(keenetic_policy_get_mark "$POLICY_NAME")"
    if [ -z "$actual" ]; then
        keenetic_policy_log "cannot get mark of policy '$POLICY_NAME' from NDMS, keeping cached '${POLICY_MARK:-<empty>}'"
        return 0
    fi

    KEENETIC_POLICY_LIVE_MARK="$actual"

    [ "$(keenetic_policy_normalize_mark "$actual")" = "$(keenetic_policy_normalize_mark "$POLICY_MARK")" ] && return 0

    keenetic_policy_log "mark of policy '$POLICY_NAME' changed: '${POLICY_MARK:-<empty>}' -> '$actual', updating config"
    keenetic_policy_save_mark "$actual" || keenetic_policy_log "failed to save mark '$actual' to $KEENETIC_ZAPRET_CONFIG; using it for this run only"
    return 0
}

keenetic_policy_is_enabled() {
    keenetic_policy_load_config
    [ -n "$POLICY_NAME" ]
}

keenetic_policy_mark_args() {
    keenetic_policy_load_config
    local policy_mark="$1"

    if [ "$POLICY_EXCLUDE" = "1" ]; then
        printf '%s' "-m mark --mark $policy_mark"
    else
        printf '%s' "-m mark ! --mark $policy_mark"
    fi
}

keenetic_policy_cleanup_rules_family() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || return 0

    "$cmd"-save -t mangle 2>/dev/null | sed -n "/$KEENETIC_POLICY_COMMENT/s/^-A /-D /p" | while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        "$cmd" -t mangle $rule >/dev/null 2>&1 || true
    done
}

keenetic_policy_cleanup_rules() {
    keenetic_policy_cleanup_rules_family iptables
    keenetic_policy_cleanup_rules_family ip6tables
}

keenetic_policy_rule_signature() {
    printf '%s|%s|%s|%s' "$1" "$2" "$3" "$4"
}

keenetic_policy_extract_field() {
    local line="$1"
    local regex="$2"
    printf '%s\n' "$line" | sed -n "s/.*$regex.*/\\1/p" | head -n1
}

keenetic_policy_insert_rules_family() {
    local cmd="$1"
    local policy_mark="$2"
    local seen=""

    command -v "$cmd" >/dev/null 2>&1 || return 0

    "$cmd"-save -t mangle 2>/dev/null | grep -- "-j NFQUEUE" | grep "^-A POSTROUTING " | while IFS= read -r line; do
        local out_if proto port_flag ports port_args signature policy_args

        out_if="$(keenetic_policy_extract_field "$line" '.* -o \([^[:space:]]\+\).*')"
        proto="$(keenetic_policy_extract_field "$line" '.* -p \([^[:space:]]\+\).*')"
        port_flag="$(printf '%s\n' "$line" | sed -n 's/.* \(-m multiport --\(dports\|sports\)\|--\(dport\|sport\)\) [^[:space:]]\+.*/\1/p' | head -n1)"
        ports="$(printf '%s\n' "$line" | sed -n 's/.* --\(dports\|sports\|dport\|sport\) \([^[:space:]]\+\).*/\2/p' | head -n1)"

        [ -n "$proto" ] || continue
        if [ -n "$ports" ]; then
            port_args="$port_flag $ports"
        else
            port_args="$(printf '%s\n' "$line" | sed -n 's/.*\(-m set --match-set zport_[^[:space:]]* dst\).*/\1/p' | head -n1)"
            [ -n "$port_args" ] || continue
        fi

        signature="$(keenetic_policy_rule_signature "$cmd" "$out_if" "$proto" "$port_args")"
        case "|$seen|" in
            *"|$signature|"*) continue ;;
        esac
        seen="$seen|$signature"

        policy_args="$(keenetic_policy_mark_args "$policy_mark")"

        if [ -n "$out_if" ]; then
            "$cmd" -t mangle -I POSTROUTING 1 -o "$out_if" -p "$proto" $port_args $policy_args -m comment --comment "$KEENETIC_POLICY_COMMENT" -j ACCEPT || keenetic_policy_log "failed to add $cmd rule for $proto/$port_args"
        else
            "$cmd" -t mangle -I POSTROUTING 1 -p "$proto" $port_args $policy_args -m comment --comment "$KEENETIC_POLICY_COMMENT" -j ACCEPT || keenetic_policy_log "failed to add $cmd rule for $proto/$port_args"
        fi
    done
}

keenetic_policy_apply_rules() {
    local policy_mark

    keenetic_policy_cleanup_rules
    keenetic_policy_sync_mark
    keenetic_policy_is_enabled || return 0

    # актуальный марк из NDMS важнее кэша в config (is_enabled перечитал config)
    policy_mark="${KEENETIC_POLICY_LIVE_MARK:-$POLICY_MARK}"
    if [ -z "$policy_mark" ]; then
        keenetic_policy_log "mark for policy '$POLICY_NAME' is not cached; select the policy again in z2r"
        return 0
    fi
    case "$policy_mark" in 0x*) ;; *) policy_mark="0x$policy_mark" ;; esac

    keenetic_policy_insert_rules_family iptables "$policy_mark"
    keenetic_policy_insert_rules_family ip6tables "$policy_mark"

    if [ "$POLICY_EXCLUDE" = "1" ]; then
        keenetic_policy_log "excluding Keenetic policy '$POLICY_NAME' (mark $policy_mark) from nfqws2"
    else
        keenetic_policy_log "limiting nfqws2 to Keenetic policy '$POLICY_NAME' (mark $policy_mark)"
    fi
}

case "$1" in
    up|post-up|apply|"")
        keenetic_policy_apply_rules
        ;;
    down|pre-down|cleanup)
        keenetic_policy_cleanup_rules
        ;;
    *)
        keenetic_policy_log "unknown action '$1'"
        exit 1
        ;;
esac

exit 0
