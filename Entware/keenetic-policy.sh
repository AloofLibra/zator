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
    printf '%s|%s|%s|%s|%s' "$1" "$2" "$3" "$4" "$5"
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
        local out_if proto port_flag ports signature policy_args

        out_if="$(keenetic_policy_extract_field "$line" '.* -o \([^[:space:]]\+\).*')"
        proto="$(keenetic_policy_extract_field "$line" '.* -p \([^[:space:]]\+\).*')"
        port_flag="$(printf '%s\n' "$line" | sed -n 's/.* \(-m multiport --\(dports\|sports\)\|--\(dport\|sport\)\) [^[:space:]]\+.*/\1/p' | head -n1)"
        ports="$(printf '%s\n' "$line" | sed -n 's/.* --\(dports\|sports\|dport\|sport\) \([^[:space:]]\+\).*/\2/p' | head -n1)"

        [ -n "$proto" ] || continue
        [ -n "$ports" ] || continue

        signature="$(keenetic_policy_rule_signature "$cmd" "$out_if" "$proto" "$port_flag" "$ports")"
        case "|$seen|" in
            *"|$signature|"*) continue ;;
        esac
        seen="$seen|$signature"

        policy_args="$(keenetic_policy_mark_args "$policy_mark")"

        if [ -n "$out_if" ]; then
            "$cmd" -t mangle -I POSTROUTING 1 -o "$out_if" -p "$proto" $port_flag "$ports" $policy_args -m comment --comment "$KEENETIC_POLICY_COMMENT" -j ACCEPT >/dev/null 2>&1 || true
        else
            "$cmd" -t mangle -I POSTROUTING 1 -p "$proto" $port_flag "$ports" $policy_args -m comment --comment "$KEENETIC_POLICY_COMMENT" -j ACCEPT >/dev/null 2>&1 || true
        fi
    done
}

keenetic_policy_apply_rules() {
    local policy_mark

    keenetic_policy_cleanup_rules
    keenetic_policy_is_enabled || return 0

    policy_mark="$POLICY_MARK"
    if [ -z "$policy_mark" ]; then
        keenetic_policy_log "mark for policy '$POLICY_NAME' is not cached; select the policy again in z2r"
        return 0
    fi

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
