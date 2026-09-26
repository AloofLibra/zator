# Super auto-sweep (суперавтопрогон): one command picks working strategies
# for profiles 1 (YouTube), 2 (Googlevideo), 4 (Discord) in parallel and
# builds a full coverage map of RKN probe domains (profile 3 strategy space,
# per-domain locks are temporary during the sweep).
#
# Design notes:
# - profile locks live in different locked.tsv rows, so profile workers never
#   conflict: they can flip strategies truly in parallel;
# - only the parent process writes locked.tsv (single writer): workers send
#   lock requests via cmd.<name> files and wait for the applied.<name> marker
#   (parallel awk+mv writes to the same lock file would race);
# - progress is mirrored into plain files under $Z2R_SUPERSWEEP_DIR so a
#   future WebUI can poll them instead of holding a long CGI request;
# - results (including rolled-back previous locks) are archived and can be
#   pushed to a stats endpoint via Z2R_SUPERSWEEP_STATS_URL.

Z2R_SUPERSWEEP_DIR="${Z2R_SUPERSWEEP_DIR:-/tmp/z2r-supersweep}"
# seconds to wait after a lock write: nfqws2 lua re-reads locked.tsv with a
# 2s TTL cache, probes must not start under the previous strategy.
Z2R_SUPERSWEEP_SETTLE="${Z2R_SUPERSWEEP_SETTLE:-2}"
Z2R_SUPERSWEEP_ARCHIVE_DIR="${Z2R_SUPERSWEEP_ARCHIVE_DIR:-${ORCH_DIR:-/opt/zator/extra_strats/cache/orchestra}/supersweep}"
Z2R_SUPERSWEEP_STATS_URL="${Z2R_SUPERSWEEP_STATS_URL:-}"
Z2R_SUPERSWEEP_ARCHIVE_KEEP="${Z2R_SUPERSWEEP_ARCHIVE_KEEP:-10}"
Z2R_SUPERSWEEP_RKN_PAR_DEFAULT="${Z2R_SUPERSWEEP_RKN_PAR_DEFAULT:-2}"
# curated RKN probe set: every domain ships in TCP_RKN_list.txt already,
# per-domain locks apply out of the box (no TCP_Custom changes needed).
Z2R_SUPERSWEEP_RKN_DOMAINS="${Z2R_SUPERSWEEP_RKN_DOMAINS:-meduza.io xhamster.com rutracker.org amnezia.org anidub.com turbobit.net www.chess.com}"

# fallback palette for standalone runs (colors are defined globally in z2r.sh)
[ -z "${plain:-}" ] && plain='\033[0m'
[ -z "${red:-}" ] && red='\033[0;31m'
[ -z "${green:-}" ] && green='\033[0;32m'
[ -z "${yellow:-}" ] && yellow='\033[0;33m'
[ -z "${cyan:-}" ] && cyan='\033[0;36m'
[ -z "${Fgreen:-}" ] && Fgreen='\033[1;32m'
[ -z "${Fcyan:-}" ] && Fcyan='\033[1;36m'
[ -z "${Fyellow:-}" ] && Fyellow='\033[1;33m'

supersweep_dir() {
    printf '%s\n' "$Z2R_SUPERSWEEP_DIR"
}

# external cancel: touch "$Z2R_SUPERSWEEP_DIR/cancel" — running workers stop
# at the next safe point, the parent restores previous locks.
supersweep_cancel_running() {
    [ -d "$Z2R_SUPERSWEEP_DIR" ] || return 1
    : > "$Z2R_SUPERSWEEP_DIR/cancel"
}

_supersweep_cancelled() {
    [ -e "${Z2R_SUPERSWEEP_DIR:?}/cancel" ]
}

_supersweep_settle() {
    local s="${Z2R_SUPERSWEEP_SETTLE:-2}"
    case "$s" in ''|*[!0-9]*) s=2 ;; esac
    [ "$s" -gt 0 ] && sleep "$s"
    return 0
}

# --- worker -> parent lock protocol --------------------------------------
# worker writes cmd.<name> (tmp + mv, first line "r|<round>", then spec lines
# "profile|<prof>|<proto>|<strategy>" / "domain|<dom>|<proto|<strategy>"),
# parent applies every line via orch_locked_set (single writer) and moves the
# file to applied.<name>; the worker waits for its round marker.

_supersweep_request_lock() {
    local name="$1" round="$2" specs="$3" dir="$Z2R_SUPERSWEEP_DIR"
    printf 'r|%s\n%s' "$round" "$specs" > "${dir}/cmd.${name}.tmp.$$" \
        && mv -f "${dir}/cmd.${name}.tmp.$$" "${dir}/cmd.${name}" || return 1
    local t0=$SECONDS
    while [ $((SECONDS - t0)) -lt 15 ]; do
        [ -f "${dir}/applied.${name}" ] \
            && [ "$(sed -n 1p "${dir}/applied.${name}" 2>/dev/null)" = "r|${round}" ] \
            && return 0
        sleep 0.3 2>/dev/null || sleep 1
    done
    echo "supersweep: lock apply timeout (worker $name, round $round)" >&2
    return 1
}

# --- shared per-strategy line rendering (same visual language as the
# single-profile sweep: badges per TLS version + short verdict) ---

_supersweep_badge() {
    local label="$1" raw="$2" badge btxt bst
    badge="$(z2r_tls_version_badge "$label" "$raw")"
    btxt="${badge%%|*}"; bst="${badge#*|}"
    case "$bst" in
        ok) printf '%b%-17s%b' "$green" "$btxt" "$plain" ;;
        http) printf '%b%-17s%b' "$yellow" "$btxt" "$plain" ;;
        fail) printf '%b%-17s%b' "$red" "$btxt" "$plain" ;;
        *) printf '%b%-17s%b' "$plain" "$btxt" "$plain" ;;
    esac
}

_supersweep_verdict_color() {
    case "$1" in
        ok) printf '%s' "$green" ;;
        warn) printf '%s' "$yellow" ;;
        *) printf '%s' "$red" ;;
    esac
}

# one progress row for progress.<name>.tsv (webui-friendly plain TSV):
# epoch, target, strategy, token, tls12 state, tls13 state, dl bytes, dl time, short
_supersweep_progress_row() {
    local epoch="$1" target="$2" strat="$3" token="$4" v12="$5" v13="$6" dl="$7" short="$8"
    local st12 st13 dlbytes dltime
    st12="$(z2r_tls_version_state "$(z2r_tls_field "$v12" 1)" "$(z2r_tls_field "$v12" 2)")"
    st13="$(z2r_tls_version_state "$(z2r_tls_field "$v13" 1)" "$(z2r_tls_field "$v13" 2)")"
    dlbytes="-"; dltime="-"
    if [ "$dl" != "skip" ]; then
        dlbytes="$(z2r_tls_field "$dl" 3)"
        dltime="$(z2r_tls_field "$dl" 4)"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$epoch" "$target" "$strat" "$token" "$st12" "$st13" "$dlbytes" "$dltime" "$short"
}

_supersweep_print_line() {
    local tag="$1" domain="$2" strat="$3" token="$4" v12="$5" v13="$6" short="$7"
    local color disp
    color="$(_supersweep_verdict_color "$token")"
    case "$token" in
        ok) disp="OK  " ;;
        warn) disp="WARN" ;;
        *) disp="FAIL"; token="fail" ;;
    esac
    if [ -n "$domain" ]; then
        printf '%s [%-3s] %-18s %3d: %b %b %b %b\n' "$(date '+%H:%M:%S')" "$tag" "$domain" "$strat" \
            "${color}${disp}${plain}" "$(_supersweep_badge tls1.2 "$v12")" \
            "$(_supersweep_badge tls1.3 "$v13")" "${color}${short}${plain}"
    else
        printf '%s [%-3s] %3d: %b %b %b %b\n' "$(date '+%H:%M:%S')" "$tag" "$strat" \
            "${color}${disp}${plain}" "$(_supersweep_badge tls1.2 "$v12")" \
            "$(_supersweep_badge tls1.3 "$v13")" "${color}${short}${plain}"
    fi
}

# --- profile worker: sweeps strategies 1..max for one profile -------------

_supersweep_worker_profile() {
    local name="$1" tag="$2" profile="$3" proto_list="$4" url="$5" max="$6"
    local dir="$Z2R_SUPERSWEEP_DIR"
    local tls_pref="$7" pause_sec="$8"
    local s p round=0 out v12 v13 dl short token specs
    local ok_list="" warn_list="" full_list="" ok_stats="" full_stats="" warn_stats=""
    local n_ok=0 n_warn=0 n_fail=0
    local ss_interrupted=0
    trap 'ss_interrupted=1' INT TERM
    set +e

    for ((s=1; s<=max; s++)); do
        if [ "$ss_interrupted" = 1 ] || _supersweep_cancelled; then break; fi
        round=$((round + 1))
        specs=""
        for p in $proto_list; do
            specs="${specs}profile|${profile}|${p}|${s}
"
        done
        _supersweep_request_lock "$name" "$round" "$specs" || { ss_interrupted=1; break; }
        _supersweep_settle

        out="$(z2r_tls_check_target "$url")"
        v12="$(printf '%s\n' "$out" | sed -n 1p)"
        v13="$(printf '%s\n' "$out" | sed -n 2p)"
        dl="$(printf '%s\n' "$out" | sed -n 3p)"
        short="$(z2r_tls_short_result "$v12" "$v13" "$dl" "$tls_pref")"
        token="${short%%|*}"; short="${short#*|}"

        local q12=0 q13=0 dlsize dltime
        z2r_tls_code_ok "$(z2r_tls_field "$v12" 2)" && q12=1
        z2r_tls_code_ok "$(z2r_tls_field "$v13" 2)" && q13=1
        dlsize="$(z2r_tls_field "$dl" 3)"; dltime="$(z2r_tls_field "$dl" 4)"
        case "$token" in
            ok)
                n_ok=$((n_ok + 1)); ok_list="${ok_list}${ok_list:+ }${s}"
                if [ "$q12" = 1 ] && [ "$q13" = 1 ]; then
                    full_list="${full_list}${full_list:+ }${s}"
                fi
                if [ "$dl" != "skip" ] && printf '%s' "$dltime" | grep -Eq '^[0-9]+\.?[0-9]*$'; then
                    ok_stats="${ok_stats}${s}|${dltime}|${dlsize}|${short}"$'\n'
                    if [ "$q12" = 1 ] && [ "$q13" = 1 ]; then
                        full_stats="${full_stats}${s}|${dltime}|${dlsize}|${short}"$'\n'
                    fi
                fi
                ;;
            warn)
                n_warn=$((n_warn + 1)); warn_list="${warn_list}${warn_list:+ }${s}"
                if [ "$dl" != "skip" ] && printf '%s' "$dltime" | grep -Eq '^[0-9]+\.?[0-9]*$'; then
                    warn_stats="${warn_stats}${s}|${dltime}|${dlsize}|${short}"$'\n'
                fi
                ;;
            *)
                token="fail"; n_fail=$((n_fail + 1))
                ;;
        esac

        _supersweep_print_line "$tag" "" "$s" "$token" "$v12" "$v13" "$short"
        _supersweep_progress_row "$(date +%s)" "$profile" "$s" "$token" "$v12" "$v13" "$dl" "$short" \
            >> "${dir}/progress.${name}.tsv"

        if [ "$s" -lt "$max" ] && [ "$pause_sec" -gt 0 ]; then
            sleep "$pause_sec"
        fi
    done
    trap - INT TERM

    # best selection mirrors orch_auto_sweep: fastest green by bytes/sec,
    # full (both TLS versions) preferred, warn fallback when no green exists
    local best="" best_short="" best_kind="" win
    if [ -n "$ok_stats" ]; then
        win="$(printf '%s' "$ok_stats" | awk -F'|' 'BEGIN{max=-1} {t=$2+0; sz=$3+0; if (t>0 && sz/t>max) {max=sz/t; line=$0}} END{print line}')"
        best="${win%%|*}"; best_kind="best"
        best_short="$(printf '%s' "$win" | cut -d'|' -f4-)"
    fi
    if [ -z "$best" ] && [ -n "$ok_list" ]; then
        best="${ok_list%% *}"; best_kind="best"; best_short="сервер ответил (без докачки)"
    fi
    if [ -z "$best" ] && [ -n "$warn_list" ]; then
        best="${warn_list%% *}"; best_kind="warn"
        best_short="жёлтая (единственная без красных)"
        if [ -n "$warn_stats" ]; then
            win="$(printf '%s' "$warn_stats" | awk -F'|' 'BEGIN{max=-1} {t=$2+0; sz=$3+0; if (t>0 && sz/t>max) {max=sz/t; line=$0}} END{print line}')"
            best="${win%%|*}"; best_short="$(printf '%s' "$win" | cut -d'|' -f4-)"
        fi
    fi

    {
        printf 'best=%s\n' "$best"
        printf 'best_kind=%s\n' "$best_kind"
        printf 'best_short=%s\n' "$best_short"
        printf 'greens=%s\n' "$ok_list"
        printf 'fulls=%s\n' "$full_list"
        printf 'warns=%s\n' "$warn_list"
        printf 'n_ok=%s\n' "$n_ok"
        printf 'n_warn=%s\n' "$n_warn"
        printf 'n_fail=%s\n' "$n_fail"
        printf 'interrupted=%s\n' "$ss_interrupted"
    } > "${dir}/best.${name}"
    : > "${dir}/done.${name}"
}

# --- rkn worker: strategy-major matrix over the probe domains -------------

_supersweep_worker_rkn() {
    local name="$1" max="$2" par="$3" tls_pref="$4" pause_sec="$5"
    shift 5
    local domains="$*"
    local dir="$Z2R_SUPERSWEEP_DIR"
    local tmpd="${dir}/wrkn"
    local s d round=0 specs i j n out v12 v13 dl short token dlsize dltime speed
    local pids pid2
    local ss_interrupted=0
    trap 'ss_interrupted=1' INT TERM
    set +e
    mkdir -p "$tmpd" 2>/dev/null

    for ((s=1; s<=max; s++)); do
        if [ "$ss_interrupted" = 1 ] || _supersweep_cancelled; then break; fi
        round=$((round + 1))
        specs=""
        for d in $domains; do
            specs="${specs}domain|${d}|tls|${s}
"
        done
        _supersweep_request_lock "$name" "$round" "$specs" || { ss_interrupted=1; break; }
        _supersweep_settle

        # probe domains in batches of $par: per-domain locks are independent
        # rows, same strategy this round, so parallel checks do not interfere
        n=0
        pids=""
        for d in $domains; do
            if [ $((n % par)) -eq 0 ] && [ "$n" -gt 0 ]; then
                for pid2 in $pids; do wait "$pid2" 2>/dev/null || true; done
                pids=""
            fi
            z2r_tls_check_target "https://${d}/" > "${tmpd}/r.${n}" 2>/dev/null </dev/null &
            pids="${pids} $!"
            n=$((n + 1))
        done
        # wait for explicit pids: bare wait spams on bash 5.3+ for reaped jobs
        for pid2 in $pids; do wait "$pid2" 2>/dev/null || true; done
        if [ "$ss_interrupted" = 1 ] || _supersweep_cancelled; then break; fi

        n=0
        for d in $domains; do
            out="$(cat "${tmpd}/r.${n}" 2>/dev/null)"
            n=$((n + 1))
            [ -n "$out" ] || out="28|000|-|-|-
28|000|-|-|-
skip"
            v12="$(printf '%s\n' "$out" | sed -n 1p)"
            v13="$(printf '%s\n' "$out" | sed -n 2p)"
            dl="$(printf '%s\n' "$out" | sed -n 3p)"
            short="$(z2r_tls_short_result "$v12" "$v13" "$dl" "$tls_pref")"
            token="${short%%|*}"; short="${short#*|}"
            dlsize="-"; dltime="-"; speed=0
            if [ "$dl" != "skip" ]; then
                dlsize="$(z2r_tls_field "$dl" 3)"
                dltime="$(z2r_tls_field "$dl" 4)"
                speed="$(awk -v sz="$dlsize" -v t="$dltime" 'BEGIN{if (t ~ /^[0-9]+\.?[0-9]*$/ && t+0>0) printf "%.0f", sz/t; else print 0}')"
            fi
            case "$token" in ok|warn) ;; *) token="fail" ;; esac
            _supersweep_print_line "RKN" "$d" "$s" "$token" "$v12" "$v13" "$short"
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$d" "$s" "$token" "$dlsize" "$speed" \
                >> "${dir}/coverage.tsv"
            _supersweep_progress_row "$(date +%s)" "$d" "$s" "$token" "$v12" "$v13" "$dl" "$short" \
                >> "${dir}/progress.${name}.tsv"
        done

        if [ "$s" -lt "$max" ] && [ "$pause_sec" -gt 0 ]; then
            sleep "$pause_sec"
        fi
    done
    trap - INT TERM

    # winner = strategy with the most green domains; ties broken by the sum
    # of download speeds, then by the lower strategy number
    local total=0
    for d in $domains; do total=$((total + 1)); done
    local winner_line
    winner_line="$(awk -F'\t' -v total="$total" '
        $4 == "ok" { c[$3]++; sp[$3] += $6 }
        END {
            bs = ""; bc = 0; bsp = 0
            for (s in c) {
                if (c[s] > bc || (c[s] == bc && sp[s] > bsp) || (c[s] == bc && sp[s] == bsp && (bs == "" || s+0 < bs+0))) {
                    bs = s; bc = c[s]; bsp = sp[s]
                }
            }
            if (bs != "") print bs "\t" bc "\t" total
        }' "${dir}/coverage.tsv" 2>/dev/null)"
    {
        printf 'winner=%s\n' "$(printf '%s' "$winner_line" | cut -f1)"
        printf 'winner_cover=%s\n' "$(printf '%s' "$winner_line" | cut -f2)"
        printf 'winner_total=%s\n' "$(printf '%s' "$winner_line" | cut -f3)"
        printf 'interrupted=%s\n' "$ss_interrupted"
    } > "${dir}/best.${name}"
    : > "${dir}/done.${name}"
}

# --- parent: coordinator + summary ----------------------------------------

_supersweep_apply_cmd() {
    local f="$1" dir="$Z2R_SUPERSWEEP_DIR"
    local name="${f##*/cmd.}"
    local target="${dir}/applied.${name}"
    # pipe subshell is fine: orch_locked_set is inherited, writes land in the
    # real lock file (single writer = this parent process)
    tail -n +2 "$f" 2>/dev/null | while IFS='|' read -r kind key proto val; do
        [ -n "$kind" ] || continue
        case "$kind" in
            profile|domain) orch_locked_set "$key" "$proto" "$val" || true ;;
        esac
    done
    mv -f "$f" "$target" 2>/dev/null || rm -f "$f"
    return 0
}

_supersweep_kv_read() {
    # $1 = file, $2 = key; prints value (empty when missing)
    [ -f "$1" ] || return 0
    sed -n "s/^$2=//p" "$1" | head -n1
}

_supersweep_restore_prev() {
    # $1 = kind filter (profile|domain, empty = all), $2 = optional key filter
    local dir="$Z2R_SUPERSWEEP_DIR" want_kind="${1:-}" want_key="${2:-}"
    local kind key proto prev
    [ -f "${dir}/prev.tsv" ] || return 0
    while IFS='|' read -r kind key proto prev; do
        [ -n "$kind" ] || continue
        [ -z "$want_kind" ] || [ "$kind" = "$want_kind" ] || continue
        [ -z "$want_key" ] || [ "$key" = "$want_key" ] || continue
        case "$prev" in
            ''|auto) orch_locked_clear "$key" "$proto" || true ;;
            *) orch_locked_set "$key" "$proto" "$prev" || true ;;
        esac
    done < "${dir}/prev.tsv"
    return 0
}

_supersweep_status_write() {
    local dir="$Z2R_SUPERSWEEP_DIR"
    {
        printf 'state=%s\n' "$1"
        printf 'started=%s\n' "$2"
        printf 'updated=%s\n' "$(date +%s)"
        printf 'tls_pref=%s\n' "$3"
        printf 'pause=%s\n' "$4"
        printf 'settle=%s\n' "${Z2R_SUPERSWEEP_SETTLE:-2}"
        printf 'rkn_par=%s\n' "$5"
        printf 'alive=%s\n' "$6"
        printf 'domains=%s\n' "$7"
    } > "${dir}/status.tmp.$$" && mv -f "${dir}/status.tmp.$$" "${dir}/status"
}

# create the results tgz. plain "tar" can resolve to busybox tar without
# create mode (entware quirk: /opt/usr/bin/tar shadows the installed GNU
# tar in /opt/bin), so walk the candidates: explicit override first (also
# used by smoke tests), then PATH tar, then known GNU tar locations
_supersweep_tar_create() {
    local tgz="$1" dir="$2" t
    for t in "${Z2R_SUPERSWEEP_TAR:-}" tar /opt/bin/tar /opt/libexec/tar-gnu; do
        [ -n "$t" ] || continue
        "$t" -czf "$tgz" -C "$dir" . >/dev/null 2>&1 && [ -s "$tgz" ] && return 0
        rm -f "$tgz"
    done
    return 1
}

# archive everything the sweep collected (including the rolled-back previous
# locks from prev.tsv) and push it to the stats endpoint when configured
supersweep_results_archive() {
    local dir="$Z2R_SUPERSWEEP_DIR" arc tgz sent="no"
    [ -d "$dir" ] || return 1
    mkdir -p "$Z2R_SUPERSWEEP_ARCHIVE_DIR" 2>/dev/null || return 1
    tgz="${Z2R_SUPERSWEEP_ARCHIVE_DIR}/supersweep-$(date +%Y%m%d-%H%M%S).tgz"
    _supersweep_tar_create "$tgz" "$dir" || return 1
    # rotate: keep the newest $Z2R_SUPERSWEEP_ARCHIVE_KEEP archives
    ls -1t "${Z2R_SUPERSWEEP_ARCHIVE_DIR}"/supersweep-*.tgz 2>/dev/null \
        | tail -n +$((Z2R_SUPERSWEEP_ARCHIVE_KEEP + 1)) \
        | while IFS= read -r arc; do rm -f "$arc"; done
    if [ -n "$Z2R_SUPERSWEEP_STATS_URL" ]; then
        if curl -4 -s --connect-timeout 4 --max-time 20 \
            -A "${Z2R_CURL_UA:-Mozilla/5.0}" -F "archive=@${tgz}" \
            "$Z2R_SUPERSWEEP_STATS_URL" >/dev/null 2>&1; then
            sent="yes"
        fi
    fi
    printf '%s\t%s\n' "$tgz" "$sent"
    return 0
}

# core engine, no interactive input (menu wrapper asks the questions):
#   supersweep_run <tls_pref> <pause_sec> <rkn_par> <domain...>
# returns 0 when results were applied, 1 when cancelled/restored.
supersweep_run() {
    local tls_pref="$1" pause_sec="$2" rkn_par="$3"
    shift 3
    local domains="$*"
    local dir="$Z2R_SUPERSWEEP_DIR"
    local cfg max1 max2 max4 max3
    local started="$(date +%s)"

    case "$pause_sec" in ''|*[!0-9]*) pause_sec="${Z2R_SWEEP_PAUSE:-3}" ;; esac
    case "$rkn_par" in ''|*[!0-9]*) rkn_par="$Z2R_SUPERSWEEP_RKN_PAR_DEFAULT" ;; esac
    [ "$rkn_par" -ge 1 ] 2>/dev/null || rkn_par=1
    case "$tls_pref" in 12|13|both) ;; *) tls_pref="any" ;; esac
    case "${Z2R_SUPERSWEEP_SETTLE:-2}" in ''|*[!0-9]*) Z2R_SUPERSWEEP_SETTLE=2 ;; esac

    cfg="$(get_config_file)" || cfg=""
    max1="$(config_profile_max_strategy 1 "$cfg")"
    max2="$(config_profile_max_strategy 2 "$cfg")"
    max4="$(config_profile_max_strategy 4 "$cfg")"
    max3="$(config_profile_max_strategy 3 "$cfg")"
    for m in "$max1" "$max2" "$max4" "$max3"; do
        printf '%s' "$m" | grep -Eq '^[1-9][0-9]*$' || {
            echo -e "${red}Не удалось определить число стратегий профилей в config.${plain}"
            return 1
        }
    done
    [ -n "$domains" ] || {
        echo -e "${red}Список доменов РКН пуст.${plain}"
        return 1
    }

    rm -rf "$dir"
    mkdir -p "$dir" || { echo -e "${red}Не удалось создать $dir${plain}"; return 1; }

    local gv_domain gv_url
    gv_domain="$(get_yt_cluster_domain 2>/dev/null || echo 'rr2---sn-4g5ednly.googlevideo.com')"
    gv_url="https://${gv_domain}/"

    # worker registry (static info for webui)
    {
        printf 'yt\tyt\tprofile\t1\thttps://www.youtube.com/\t%s\n' "$max1"
        printf 'gv\tgv\tprofile\t2\t%s\t%s\n' "$gv_url" "$max2"
        printf 'ds\tds\tprofile\t4\thttps://discord.com/\t%s\n' "$max4"
        printf 'rkn\tRKN\trkn\t3\t%s\t%s\n' "$(printf '%s' "$domains" | tr ' ' ',')" "$max3"
    } > "${dir}/workers.tsv"

    # remember current locks: restored on cancel, archived with the results
    {
        printf 'profile|1|tls|%s\n' "$(orch_locked_state_get 1 tls)"
        printf 'profile|1|http|%s\n' "$(orch_locked_state_get 1 http)"
        printf 'profile|2|tls|%s\n' "$(orch_locked_state_get 2 tls)"
        printf 'profile|4|tls|%s\n' "$(orch_locked_state_get 4 tls)"
        printf 'profile|3|tls|%s\n' "$(orch_locked_state_get 3 tls)"
        local d
        for d in $domains; do
            printf 'domain|%s|tls|%s\n' "$d" "$(orch_locked_state_get "$d" tls)"
        done
    } > "${dir}/prev.tsv"

    local total_rkn=0
    for d in $domains; do total_rkn=$((total_rkn + 1)); done
    local batches=$(( (total_rkn + rkn_par - 1) / rkn_par ))
    local est1=$(( max1 * (Z2R_SUPERSWEEP_SETTLE + 6 + pause_sec) ))
    local est4=$(( max4 * (Z2R_SUPERSWEEP_SETTLE + 6 + pause_sec) ))
    local estr=$(( max3 * (Z2R_SUPERSWEEP_SETTLE + batches * 6 + pause_sec) ))
    local estmax=$est1
    [ "$est4" -gt "$estmax" ] && estmax=$est4
    [ "$estr" -gt "$estmax" ] && estmax=$estr

    echo -e "${cyan}Суперавтопрогон: профили 1 (YouTube), 2 (Googlevideo), 4 (Discord) параллельно + карта РКН по ${total_rkn} доменам (пакетами по ${rkn_par}).${plain}"
    echo -e "Стратегий: профиль 1 — ${max1}, профиль 2 — ${max2}, профиль 4 — ${max4}, РКН — ${max3}. Пауза ${pause_sec} сек, выдержка после лока ${Z2R_SUPERSWEEP_SETTLE} сек."
    echo -e "Ориентировочно до $(( (estmax + 59) / 60 )) мин. Прогресс: ${dir}. Ctrl+C - прервать (прежние стратегии будут возвращены)."
    echo ""

    _supersweep_status_write running "$started" "$tls_pref" "$pause_sec" "$rkn_par" "yt,gv,ds,rkn" "$domains"

    local had_e=0
    case "$-" in *e*) had_e=1 ;; esac
    set +e
    # both TLS versions must be probed honestly in every worker
    local wait_both_prev="${Z2R_TLS_WAIT_BOTH:-}"
    Z2R_TLS_WAIT_BOTH=1
    export Z2R_TLS_WAIT_BOTH

    local svc_was_running=0
    zapret2_running && svc_was_running=1

    local interrupted=0
    trap 'interrupted=1' INT

    _supersweep_worker_profile yt yt 1 "tls http" "https://www.youtube.com/" "$max1" "$tls_pref" "$pause_sec" &
    local pid_yt=$!
    _supersweep_worker_profile gv gv 2 "tls" "$gv_url" "$max2" "$tls_pref" "$pause_sec" &
    local pid_gv=$!
    _supersweep_worker_profile ds ds 4 "tls" "https://discord.com/" "$max4" "$tls_pref" "$pause_sec" &
    local pid_ds=$!
    _supersweep_worker_rkn rkn "$max3" "$rkn_par" "$tls_pref" "$pause_sec" $domains &
    local pid_rkn=$!

    local wpids="$pid_yt $pid_gv $pid_ds $pid_rkn"
    local pid alive cancelled=0
    while :; do
        alive=""
        for pid in $wpids; do
            kill -0 "$pid" 2>/dev/null && alive="${alive} ${pid}"
        done
        [ -n "$alive" ] || break
        if [ "$interrupted" = 1 ]; then
            if [ ! -e "${dir}/cancel" ]; then
                : > "${dir}/cancel"
                for pid in $alive; do kill -INT "$pid" 2>/dev/null || true; done
            fi
            cancelled=1
        fi
        _supersweep_cancelled && cancelled=1
        local f
        for f in "${dir}"/cmd.*; do
            [ -e "$f" ] || continue
            _supersweep_apply_cmd "$f"
        done
        local alive_names=""
        kill -0 "$pid_yt" 2>/dev/null && alive_names="yt"
        kill -0 "$pid_gv" 2>/dev/null && alive_names="${alive_names} gv"
        kill -0 "$pid_ds" 2>/dev/null && alive_names="${alive_names} ds"
        kill -0 "$pid_rkn" 2>/dev/null && alive_names="${alive_names} rkn"
        _supersweep_status_write running "$started" "$tls_pref" "$pause_sec" "$rkn_par" "${alive_names# }" "$domains"
        sleep 0.3 2>/dev/null || sleep 1
    done
    for pid in $wpids; do
        wait "$pid" 2>/dev/null || true
    done
    trap - INT
    if [ "$had_e" = 1 ]; then set -e; fi

    Z2R_TLS_WAIT_BOTH="$wait_both_prev"
    export Z2R_TLS_WAIT_BOTH

    if [ "$svc_was_running" = 1 ] && ! zapret2_running; then
        echo -e "${red}zapret2 был остановлен: процесс nfqws2 убит (похоже, Ctrl+C). Перезапускаю...${plain}"
        z2r_service_action restart >/dev/null 2>&1 || true
        if zapret2_running; then
            echo -e "${green}zapret2 снова работает.${plain}"
        else
            echo -e "${red}Не удалось перезапустить zapret2. Запустите вручную: пункт 22 главного меню.${plain}"
        fi
    fi

    # read worker results
    local best_yt best_gv best_ds winner applied_any=0
    best_yt="$(_supersweep_kv_read "${dir}/best.yt" best)"
    best_gv="$(_supersweep_kv_read "${dir}/best.gv" best)"
    best_ds="$(_supersweep_kv_read "${dir}/best.ds" best)"
    winner="$(_supersweep_kv_read "${dir}/best.rkn" winner)"

    if [ "$cancelled" = 1 ]; then
        echo ""
        echo -e "${yellow}Прервано пользователем: возвращаю прежние стратегии...${plain}"
        _supersweep_restore_prev
        _supersweep_status_write cancelled "$started" "$tls_pref" "$pause_sec" "$rkn_par" "" "$domains"
    else
        # probe locks are temporary: domain rows always revert, a profile
        # without a best falls back to its previous lock (the apply below
        # overwrites the rows that do get a best)
        _supersweep_restore_prev domain
        [ -n "$best_yt" ] || _supersweep_restore_prev profile 1
        [ -n "$best_gv" ] || _supersweep_restore_prev profile 2
        [ -n "$best_ds" ] || _supersweep_restore_prev profile 4
        _supersweep_status_write applying "$started" "$tls_pref" "$pause_sec" "$rkn_par" "" "$domains"
    fi

    # --- сводка + автоматическое применение лучших стратегий ---
    echo ""
    echo "================================================"
    if [ "$cancelled" = 1 ]; then
        echo -e " Итог (прерван): найденное к моменту прерывания; изменения ${yellow}откатлены${plain}"
    else
        echo -e " Итог суперавтопрогона (цель TLS: ${tls_pref})"
    fi
    echo "================================================"
    {
        printf 'profile\t1\t%s\n' "$best_yt"
        printf 'profile\t2\t%s\n' "$best_gv"
        printf 'profile\t4\t%s\n' "$best_ds"
        printf 'profile\t3\t%s\n' "$winner"
    } > "${dir}/summary.tsv"

    local wname pkey plabel protos greens fulls warns best best_short old_udp_ports
    for spec in "yt:1:YouTube:tls http" "gv:2:Googlevideo:tls" "ds:4:Discord:tls"; do
        wname="${spec%%:*}"; rest="${spec#*:}"
        pkey="${rest%%:*}"; rest="${rest#*:}"
        plabel="${rest%%:*}"; protos="${rest#*:}"
        best="$(_supersweep_kv_read "${dir}/best.${wname}" best)"
        greens="$(_supersweep_kv_read "${dir}/best.${wname}" greens)"
        fulls="$(_supersweep_kv_read "${dir}/best.${wname}" fulls)"
        warns="$(_supersweep_kv_read "${dir}/best.${wname}" warns)"
        best_short="$(_supersweep_kv_read "${dir}/best.${wname}" best_short)"
        echo -e " Профиль ${pkey} (${plabel}): зелёных ${green}$(_supersweep_count_list "$greens")${plain}, жёлтых ${yellow}$(_supersweep_count_list "$warns")${plain}"
        [ -n "$fulls" ] && echo -e "   Полные (TLS 1.2 и 1.3): ${green}${fulls}${plain}"
        [ -n "$greens" ] && echo -e "   Рабочие (зелёные): ${green}${greens}${plain}"
        [ -n "$warns" ] && echo -e "   Жёлтые: ${yellow}${warns}${plain}"
        if [ -n "$best" ] && [ "$cancelled" != 1 ]; then
            old_udp_ports="$(config_get_var "$cfg" NFQWS2_PORTS_UDP)"
            if profile_state_set_and_apply "$pkey" "$protos" "$best" "$cfg"; then
                echo -e "   ${Fgreen}Применена стратегия ${best}${plain} (${best_short})"
                applied_any=1
                profile_strategy_restart_if_needed "$pkey" "$cfg" "$old_udp_ports"
            else
                echo -e "   ${red}Не удалось сохранить стратегию ${best} для профиля ${pkey}.${plain}"
            fi
        elif [ -n "$best" ]; then
            echo -e "   Кандидат был ${best} — не применён (прогон прерван)."
        else
            echo -e "   ${red}Рабочих стратегий не найдено.${plain}"
        fi
    done

    # rkn report: winner applied to profile 3, per-domain shown read-only
    local cover totald
    cover="$(_supersweep_kv_read "${dir}/best.rkn" winner_cover)"
    totald="$(_supersweep_kv_read "${dir}/best.rkn" winner_total)"
    echo -e " РКН (профиль 3, доменов в прогоне: ${totald}):"
    if [ -n "$winner" ]; then
        echo -e "   Покрытие по стратегиям (сколько доменов открыто):"
        awk -F'\t' '$4=="ok" {c[$3]++} END {for (s in c) print s, c[s]}' "${dir}/coverage.tsv" 2>/dev/null \
            | sort -k2,2nr -k1,1n | head -10 \
            | while read -r s cnt; do printf '     стратегия %s: %s\n' "$s" "$cnt"; done
        if [ "$cancelled" != 1 ]; then
            old_udp_ports="$(config_get_var "$cfg" NFQWS2_PORTS_UDP)"
            if profile_state_set_and_apply 3 tls "$winner" "$cfg"; then
                echo -e "   ${Fgreen}Применена стратегия ${winner} для профиля 3${plain} (покрывает ${cover}/${totald} доменов)"
                applied_any=1
                profile_strategy_restart_if_needed 3 "$cfg" "$old_udp_ports"
            else
                echo -e "   ${red}Не удалось сохранить стратегию ${winner} для профиля 3.${plain}"
            fi
        else
            echo -e "   Кандидат был ${winner} (${cover}/${totald}) — не применён (прогон прерван)."
        fi
        echo -e "   Точечные локи доменов (зафиксировать можно в п.6 или пер-доменным автопроном):"
        awk -F'\t' '$4=="ok" {
            spd = $6+0
            if (!($2 in bs) || spd > bsp[$2] || (spd == bsp[$2] && $3+0 < bs[$2]+0)) { bs[$2]=$3; bsp[$2]=spd }
        } END {
            n = 0
            for (d in bs) { keys[n++] = d }
            # sort by domain for stable output
            for (i = 0; i < n; i++) for (j = i+1; j < n; j++) if (keys[j] < keys[i]) { t = keys[i]; keys[i] = keys[j]; keys[j] = t }
            for (i = 0; i < n; i++) print "     " keys[i] ": стратегия " bs[keys[i]]
        }' "${dir}/coverage.tsv" 2>/dev/null
    else
        echo -e "   ${red}Ни одна стратегия не открыла ни один домен РКН.${plain}"
    fi
    echo "================================================"

    [ "$applied_any" = 1 ] && telemetry_notify

    # archive + optional stats push
    local arc_line arc_path arc_sent
    arc_line="$(supersweep_results_archive)" || arc_line=""
    if [ -n "$arc_line" ]; then
        arc_path="$(printf '%s' "$arc_line" | cut -f1)"
        arc_sent="$(printf '%s' "$arc_line" | cut -f2)"
        echo -e " Архив результатов: ${arc_path}"
        if [ -n "$Z2R_SUPERSWEEP_STATS_URL" ]; then
            if [ "$arc_sent" = "yes" ]; then
                echo -e " ${green}Архив отправлен на сервер статистики.${plain}"
            else
                echo -e " ${yellow}Не удалось отправить архив на сервер статистики (сеть/endpoint).${plain}"
            fi
        else
            echo -e " ${yellow}Отправка на сервер статистики не настроена (Z2R_SUPERSWEEP_STATS_URL).${plain}"
        fi
    else
        echo -e " ${yellow}Не удалось упаковать архив результатов.${plain}"
    fi

    _supersweep_status_write "$([ "$cancelled" = 1 ] && echo cancelled || echo done)" \
        "$started" "$tls_pref" "$pause_sec" "$rkn_par" "" "$domains"
    if [ "$cancelled" = 1 ]; then
        return 1
    fi
    return 0
}

_supersweep_count_list() {
    local n=0 item
    for item in $1; do n=$((n + 1)); done
    printf '%s' "$n"
}

# --- menu dialog -----------------------------------------------------------

supersweep_ask_domains() {
    # prints the selected space-separated domain list (empty = cancel)
    local defaults="$Z2R_SUPERSWEEP_RKN_DOMAINS"
    local d i pick answer dom selected=""
    echo -e "${cyan}--- Домены РКН для карты покрытий ---${plain}"
    echo ""
    i=1
    for d in $defaults; do
        echo -e "  ${Fcyan}${i}.${plain} ${green}${d}${plain}"
        i=$((i + 1))
    done
    echo ""
    read -re -p "Номера через пробел (Enter - все, 0 - отмена): " pick
    [ "$pick" = "0" ] && return 1
    if [ -z "$pick" ] || [ "$pick" = "a" ] || [ "$pick" = "A" ] || [ "$pick" = "а" ] || [ "$pick" = "А" ]; then
        printf '%s\n' "$defaults"
        return 0
    fi
    i=1
    for d in $defaults; do
        case " $pick " in *" $i "*) selected="${selected}${selected:+ }${d}" ;; esac
        i=$((i + 1))
    done
    if [ -z "$selected" ]; then
        echo -e "${yellow}Не выбран ни один домен — берём весь список.${plain}"
        printf '%s\n' "$defaults"
        return 0
    fi
    printf '%s\n' "$selected"
}

supersweep_ask_own_domains() {
    # $1 = current selection (space separated); appends user domains,
    # adding unknown ones to TCP_Custom.txt so profile 3 picks them up
    local selected="$1" raw dom clean added=0 skipped=0
    read -re -p "Свои домены через пробел (Enter - пропустить): " raw
    [ -z "$raw" ] && { printf '%s\n' "$selected"; return 0; }
    raw="$(printf '%s' "$raw" | tr ',' ' ')"
    local rkn_list custom_file
    rkn_list="${ZATOR_ROOT:-/opt/zator}/extra_strats/TCP_RKN_list.txt"
    custom_file="$(custom_rkn_file)"
    for dom in $raw; do
        if ! clean="$(z2r_normalize_domain "$dom")"; then
            echo -e "${yellow}Не распознан домен: ${dom} — пропущен.${plain}"
            skipped=$((skipped + 1))
            continue
        fi
        case " $selected " in *" $clean "*) continue ;; esac
        selected="${selected} ${clean}"
        if { [ -f "$rkn_list" ] && grep -Fixq "$clean" "$rkn_list" 2>/dev/null; } \
            || { [ -f "$custom_file" ] && grep -Fixq "$clean" "$custom_file" 2>/dev/null; }; then
            :
        else
            domain_list_add "$custom_file" "$clean" "TCP_Custom" "Домен" 1
            echo -e "${green}Домен ${clean} добавлен в TCP_Custom (обрабатывается профилем 3).${plain}"
            added=$((added + 1))
        fi
    done
    [ "$skipped" -gt 0 ] && echo -e "${yellow}Пропущено нераспознанных: ${skipped}.${plain}"
    printf '%s\n' "$selected"
}

supersweep_ask_pause() {
    # same contract as orch_ask_sweep_pause, but the default is higher:
    # the supersweep flips several locks in parallel, extra margin against
    # tspu rate blocks is welcome
    local pause
    while true; do
        read -re -p "Пауза между стратегиями. Минимум 3 сек (Enter - 5 сек, 0 - отмена): " pause || pause=""
        if [ "$pause" = "0" ]; then
            return 0
        fi
        [ -n "$pause" ] || pause=5
        case "$pause" in
            *[!0-9]*)
                echo -e "${yellow}Неверный ввод: нужно число секунд (минимум 3).${plain}" >&2
                ;;
            *)
                if [ "$pause" -lt 3 ]; then
                    echo -e "${yellow}Пауза не может быть меньше 3 секунд (введено ${pause}).${plain}" >&2
                else
                    echo "$pause"
                    return 0
                fi
                ;;
        esac
    done
}

supersweep_ask_rkn_par() {
    # how many RKN domains to probe simultaneously
    local par ndom=0 d
    for d in $1; do ndom=$((ndom + 1)); done
    while true; do
        read -re -p "Доменов РКН проверять одновременно, 1-${ndom} (Enter - ${Z2R_SUPERSWEEP_RKN_PAR_DEFAULT}): " par || par=""
        [ -n "$par" ] || par="$Z2R_SUPERSWEEP_RKN_PAR_DEFAULT"
        case "$par" in
            0) return 1 ;;
            *[!0-9]*)
                echo -e "${yellow}Неверный ввод: нужно число 1-${ndom}.${plain}" >&2
                ;;
            *)
                if [ "$par" -ge 1 ] && [ "$par" -le "$ndom" ]; then
                    echo "$par"
                    return 0
                fi
                echo -e "${yellow}Число должно быть в диапазоне 1-${ndom}.${plain}" >&2
                ;;
        esac
    done
}

supersweep_menu() {
    local cfg domains tls_pref pause par answer estr est
    cfg="$(config_get_file 2>/dev/null)" || cfg=""
    menu_config_snapshot "$cfg" 2>/dev/null || true
    if [ "${MENU_AUTO_MODE:-}" = "включен" ]; then
        echo -e "${yellow}Суперавтопрогон недоступен при включённой авторотации TCP/HTTP.${plain}"
        echo -e "Выключите авторотацию (п.11 этого подменю) и повторите."
        pause_enter
        return 0
    fi
    if ! zapret2_running; then
        echo -e "${yellow}zapret2 не запущен — проверки бессмысленны.${plain}"
        echo -e "Запустите zapret2 (п.2 главного меню) и повторите."
        pause_enter
        return 0
    fi

    clear -x
    echo -e "${cyan}--- Суперавтопрогон ---${plain}"
    echo "Одним запуском: подбор стратегий для YouTube (профиль 1), Googlevideo"
    echo "(профиль 2) и Discord (профиль 4) параллельно + полная карта покрытий"
    echo "доменов РКН (профиль 3). Лучшие стратегии применяются автоматически,"
    echo "персональные локи доменов РКН только показываются."
    echo ""

    domains="$(supersweep_ask_domains)" || { echo "Отмена."; return 0; }
    domains="$(supersweep_ask_own_domains "$domains")"

    tls_pref="$(orch_ask_sweep_tls_pref)"
    if [ -z "$tls_pref" ]; then
        echo "Отмена."
        return 0
    fi
    pause="$(supersweep_ask_pause)"
    if [ -z "$pause" ]; then
        echo "Отмена."
        return 0
    fi
    par="$(supersweep_ask_rkn_par "$domains")" || { echo "Отмена."; return 0; }

    local ndom=0 d
    for d in $domains; do ndom=$((ndom + 1)); done
    local max1 batches est
    max1="$(config_profile_max_strategy 1 "$cfg")"
    printf '%s' "$max1" | grep -Eq '^[1-9][0-9]*$' || max1=43
    batches=$(( (ndom + par - 1) / par ))
    est=$(( max1 * (Z2R_SUPERSWEEP_SETTLE + 6 + pause) ))
    estr=$(( max1 * (Z2R_SUPERSWEEP_SETTLE + batches * 6 + pause) ))
    [ "$estr" -gt "$est" ] && est=$estr

    echo ""
    echo -e "Прогон займёт ориентировочно до $(( (est + 59) / 60 )) мин. Во время прогона"
    echo -e "интернет может подтормаживать (стратегии переключаются на лету)."
    read -re -p "Enter - старт, 0 - отмена: " answer
    [ "$answer" = "0" ] && { echo "Отмена."; return 0; }

    supersweep_run "$tls_pref" "$pause" "$par" $domains
    pause_enter
}
