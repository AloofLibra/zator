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
# stats endpoint by the upstream author (redis backend); an explicitly
# exported empty value disables the upload. consent reuses the main
# telemetry switch (tel_enabled) — same uuid, same opt-out
Z2R_SUPERSWEEP_STATS_URL="${Z2R_SUPERSWEEP_STATS_URL-https://alooflibra.fun/z4r/supersweep}"
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

# прерываемый сон: выход раньше при отмене (cancel-файл), шаг 1 сек
_supersweep_sleep() {
    local secs="$1" i=0
    printf '%s' "$secs" | grep -Eq '^[0-9]+$' || return 0
    while [ "$i" -lt "$secs" ]; do
        _supersweep_cancelled && return 1
        sleep 1
        i=$((i + 1))
    done
    return 0
}

# пауза между фазами прогона: канал отдыхает от частых переключений
_supersweep_phase_pause() {
    local secs="${Z2R_SUPERSWEEP_PHASE_PAUSE:-30}"
    printf '%s' "$secs" | grep -Eq '^[0-9]+$' || secs=30
    [ "$secs" -gt 0 ] || return 0
    echo -e "$(date '+%H:%M:%S') ${cyan}Пауза между фазами: ${secs} сек — канал отдыхает от переключений.${plain}"
    _supersweep_sleep "$secs"
    return 0
}

# лучший пер-доменный результат из coverage.tsv: ok важнее warn, дальше
# скорость скачивания, дальше меньший номер стратегии; rank: 0=ok 1=warn
_supersweep_rkn_domain_winners() {
    awk -F'\t' '
        {
            key = $2
            rank = ($4 == "ok") ? 0 : ($4 == "warn") ? 1 : 2
            better = 0
            if (!(key in bs)) better = 1
            else if (rank < br[key]) better = 1
            else if (rank == br[key] && $6 + 0 > bspeed[key] + 0) better = 1
            else if (rank == br[key] && $6 + 0 == bspeed[key] + 0 && $3 + 0 < bs[key] + 0) better = 1
            if (better) { bs[key] = $3; br[key] = rank; bspeed[key] = $6 }
        }
        END {
            for (d in bs) print d "\t" bs[d] "\t" br[d]
        }' "$1" 2>/dev/null
}

# --- worker -> parent lock protocol --------------------------------------
# worker writes cmd.<name> (tmp + mv, first line "r|<round>", then spec lines
# "profile|<prof>|<proto>|<strategy>" / "domain|<dom>|<proto|<strategy>"),
# parent applies every line via orch_locked_set (single writer) and moves the
# file to applied.<name>; the worker waits for its round marker.

_supersweep_request_lock() {
    local name="$1" round="$2" specs="$3" dir="$Z2R_SUPERSWEEP_DIR"
    printf 'r|%s\n%s\n' "$round" "$specs" > "${dir}/cmd.${name}.tmp.$$" \
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
    # traps stay installed until the subshell exits: a second INT from the
    # parent kill must not kill the worker before best.<name> is written

    # "interrupted" = the sweep did not run to completion (signal or the
    # cancel file): partial results must not be applied by the coordinator
    local ss_incomplete=0
    [ "$s" -le "$max" ] && ss_incomplete=1

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
        printf 'interrupted=%s\n' "$ss_incomplete"
    } > "${dir}/best.${name}"
    : > "${dir}/done.${name}"
}

# winners from coverage.tsv: "ok_winner<TAB>ok_cover<TAB>total<TAB>warn_winner<TAB>warn_cover"
# (ok winner = most green domains, ties by summed speed then lower number;
# warn winner = same over partial single-TLS-version results, report-only)
_supersweep_rkn_winners() {
    local total="$1" file="$2"
    awk -F'\t' -v total="$total" '
        $4 == "ok"   { c[$3]++; sp[$3] += $6 }
        $4 == "warn" { w[$3]++; wsp[$3] += $6 }
        END {
            bs = ""; bc = 0; bsp = 0
            for (s in c) {
                if (c[s] > bc || (c[s] == bc && sp[s] > bsp) || (c[s] == bc && sp[s] == bsp && (bs == "" || s+0 < bs+0))) {
                    bs = s; bc = c[s]; bsp = sp[s]
                }
            }
            ws = ""; wc = 0; wspd = 0
            for (s in w) {
                if (w[s] > wc || (w[s] == wc && wsp[s] > wspd) || (w[s] == wc && wsp[s] == wspd && (ws == "" || s+0 < ws+0))) {
                    ws = s; wc = w[s]; wspd = wsp[s]
                }
            }
            print bs "\t" bc "\t" total "\t" ws "\t" wc
        }' "$file" 2>/dev/null
}

# --- rkn worker: full matrix over all selected domains ---------------------
# upstream author's request: every strategy round probes ALL user-selected
# domains — a single reference domain can be dead on its own (rutracker and
# meduza die regularly), so gating on one host loses the whole map. the
# price is more requests, compensated by a larger dedicated rkn pause
# (see supersweep_ask_rkn_pause). strategies are still ordered by the
# youtube worker results when available: a strategy green on youtube tends
# to crack other hosts too, youtube failures go last — nicer live logs and
# an early signal while the map builds.

_supersweep_rkn_record() {
    # $1 domain, $2 strategy, $3 engine out (3 lines), $4 tls_pref
    # prints the console line to stderr and the verdict token (ok|warn|fail)
    # on stdout — callers capture stdout, same contract as the ask_* dialogs
    local d="$1" s="$2" out="$3" tls_pref="$4"
    local v12 v13 dl short token dlsize dltime speed
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
    _supersweep_print_line "RKN" "$d" "$s" "$token" "$v12" "$v13" "$short" >&2
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$d" "$s" "$token" "$dlsize" "$speed" \
        >> "${Z2R_SUPERSWEEP_DIR}/coverage.tsv"
    _supersweep_progress_row "$(date +%s)" "$d" "$s" "$token" "$v12" "$v13" "$dl" "$short" \
        >> "${Z2R_SUPERSWEEP_DIR}/progress.rkn.tsv"
    printf '%s\n' "$token"
}

_supersweep_worker_rkn() {
    local name="$1" max="$2" par="$3" tls_pref="$4" pause_sec="$5"
    shift 5
    local domains="$*"
    local dir="$Z2R_SUPERSWEEP_DIR"
    local tmpd="${dir}/wrkn"
    local ref d round=0 specs token out s
    local pids pid2 n
    local ss_interrupted=0
    trap 'ss_interrupted=1' INT TERM
    set +e
    mkdir -p "$tmpd" 2>/dev/null

    ref="${domains%% *}"

    # youtube-correlated strategy order (report-only convenience: every
    # strategy is probed anyway, greens just come first in the live log)
    local s_list=""
    s_list="$(for ((s=1; s<=max; s++)); do printf '%s\n' "$s"; done | awk -v ytfile="${dir}/progress.yt.tsv" '
        BEGIN {
            while ((getline line < ytfile) > 0) {
                split(line, yf, "\t"); yt[yf[3]] = yf[4]
            }
            close(ytfile)
        }
        {
            rank = 1
            if (yt[$1] == "ok") rank = 0
            else if (yt[$1] == "warn") rank = 1
            else if (yt[$1] != "") rank = 2
            printf "%d %d\n", rank, $1
        }' 2>/dev/null | sort -k1,1n -k2,2n | awk '{printf "%s%s", sep, $2; sep = " "} END{printf "\n"}')"
    [ -n "$s_list" ] || s_list="$(for ((s=1; s<=max; s++)); do printf '%s ' "$s"; done)"

    # последовательный пер-доменный проход: каждый домен получает полный
    # круг стратегий до перехода к следующему (доменные локи реально работают
    # в рантайме). Частые переключения на нескольких доменах сразу — типичный
    # триггер rate-эвристики ТСПУ, поэтому по одному.
    local dtot=0 dnum=0 dom_first=1 red_streak=0 peff
    for d in $domains; do dtot=$((dtot + 1)); done
    for d in $domains; do
        [ "$ss_interrupted" = 1 ] && break
        _supersweep_cancelled && break
        [ "$dom_first" = 1 ] || _supersweep_sleep "$pause_sec"
        dom_first=0
        dnum=$((dnum + 1))
        red_streak=0
        echo -e "$(date '+%H:%M:%S') ${cyan}РКН: домен ${d} (${dnum}/${dtot}) — полный проход стратегий${plain}" >&2
        for s in $s_list; do
            [ "$ss_interrupted" = 1 ] && break
            _supersweep_cancelled && break
            round=$((round + 1))
            _supersweep_request_lock "$name" "$round" "domain|${d}|tls|${s}" || { ss_interrupted=1; break; }
            _supersweep_settle
            z2r_tls_check_target "https://${d}/" > "${tmpd}/r.0" 2>/dev/null </dev/null
            [ "$ss_interrupted" = 1 ] && break
            out="$(cat "${tmpd}/r.0" 2>/dev/null)"
            [ -n "$out" ] || out="28|000|-|-|-
28|000|-|-|-
skip"
            token="$(_supersweep_rkn_record "$d" "$s" "$out" "$tls_pref")"
            # gentle: серия сплошных неудач выглядит как реакция ТСПУ на
            # частые переключения — пауза растёт (до 4x), канал остывает
            case "$token" in ok|warn) red_streak=0 ;; *) red_streak=$((red_streak + 1)) ;; esac
            peff="$pause_sec"
            if [ "$red_streak" -ge "${Z2R_SUPERSWEEP_GENTLE_STREAK:-3}" ]; then
                peff=$(( pause_sec * 2 ))
                [ "$peff" -gt "$(( pause_sec * 4 ))" ] && peff=$(( pause_sec * 4 ))
                echo -e "$(date '+%H:%M:%S') ${yellow}РКН: ${red_streak} неудач подряд — пауза увеличена до ${peff} сек (похоже на реакцию ТСПУ).${plain}" >&2
            fi
            [ "$peff" -gt 0 ] && _supersweep_sleep "$peff"
        done
    done
    # traps stay installed until the subshell exits: a second INT from the
    # parent kill must not kill the worker before best.<name> is written

    # "interrupted" = the map did not run to completion (signal or the
    # cancel file): a partial map must not be applied by the coordinator.
    # after a natural for-list completion s equals the last strategy, so
    # count the recorded rounds instead
    local ss_incomplete=0 probed=0 need=0
    for d in $s_list; do need=$((need + 1)); done
    probed="$(cut -f3 "${dir}/coverage.tsv" 2>/dev/null | sort -u | wc -l | tr -d '[:space:]')"
    [ -n "$probed" ] || probed=0
    [ "$probed" -lt "$need" ] && ss_incomplete=1

    # winner = strategy with the most green (ok) domains; ties broken by the
    # sum of download speeds, then by the lower strategy number. warn_winner
    # is the same metric over partial (single TLS version) results — it is
    # reported but never auto-applied: an all-yellow run usually means the
    # channel is degraded (tspu trigger), not that the strategy is good.
    local total=0
    for d in $domains; do total=$((total + 1)); done
    local winner_line
    winner_line="$(_supersweep_rkn_winners "$total" "${dir}/coverage.tsv")"
    {
        printf 'winner=%s\n' "$(printf '%s' "$winner_line" | cut -f1)"
        printf 'winner_cover=%s\n' "$(printf '%s' "$winner_line" | cut -f2)"
        printf 'winner_total=%s\n' "$(printf '%s' "$winner_line" | cut -f3)"
        printf 'warn_winner=%s\n' "$(printf '%s' "$winner_line" | cut -f4)"
        printf 'warn_winner_cover=%s\n' "$(printf '%s' "$winner_line" | cut -f5)"
        printf 'reference=%s\n' "$ref"
        printf 'interrupted=%s\n' "$ss_incomplete"
    } > "${dir}/best.${name}"
    : > "${dir}/done.${name}"
}

# --- parent: coordinator + summary ----------------------------------------

# settle a finished worker's result immediately: the user gets working
# youtube/googlevideo/discord while the long rkn stage is still running.
# writes the applied.done.<name> marker (strategy value | none | error) so
# the summary and the cancel path know what is already settled
_supersweep_settle_worker() {
    local name="$1" pkey="$2" protos="$3" cfg="$4"
    local dir="$Z2R_SUPERSWEEP_DIR"
    local best best_short marker="none" old_udp_ports
    if [ "$name" = rkn ]; then
        best="$(_supersweep_kv_read "${dir}/best.rkn" winner)"
        best_short="покрывает $(_supersweep_kv_read "${dir}/best.rkn" winner_cover)/$(_supersweep_kv_read "${dir}/best.rkn" winner_total) доменов"
    else
        best="$(_supersweep_kv_read "${dir}/best.${name}" best)"
        best_short="$(_supersweep_kv_read "${dir}/best.${name}" best_short)"
    fi
    # an interrupted worker writes best/done too (graceful exit): its partial
    # results must not be applied — a half-swept best is not a verdict
    if [ "$(_supersweep_kv_read "${dir}/best.${name}" interrupted)" = 1 ]; then
        if [ "$name" != rkn ]; then
            _supersweep_restore_prev profile "$pkey"
        fi
        printf 'none\n' > "${dir}/applied.done.${name}"
        return 0
    fi
    if [ "$name" = rkn ]; then
        # пер-доменное применение: доменные строки реально работают в
        # рантайме, каждый домен сразу получает свою зелёную стратегию.
        # Жёлтые (одна версия TLS) — только через явный вопрос в сводке.
        local dw_line dwin dstr drank
        _supersweep_rkn_domain_winners "${dir}/coverage.tsv" \
            | while IFS="$(printf '\t')" read -r dwin dstr drank; do
                [ -n "$dwin" ] || continue
                [ "$drank" = 0 ] || continue
                if orch_locked_set "$dwin" tls "$dstr"; then
                    printf 'domain\t%s\t%s\n' "$dwin" "$dstr" >> "${dir}/applied.tsv"
                    echo -e "$(date '+%H:%M:%S') ${Fgreen}РКН: домен ${dwin} — применена стратегия ${dstr}${plain}"
                fi
            done
        # профильная строка РКН: стратегия максимума покрытия — дефолт для
        # всего списка (домены без персонального лока). Без этого свежая
        # установка остаётся на стартовой стратегии, даже если та никогда
        # не пробивается — список РКН мёртв при живых победителях.
        if [ -n "$best" ]; then
            old_udp_ports="$(config_get_var "$cfg" NFQWS2_PORTS_UDP)"
            if profile_state_set_and_apply "$pkey" "$protos" "$best" "$cfg"; then
                printf 'profile\t%s\t%s\n' "$pkey" "$best" >> "${dir}/applied.tsv"
                echo -e "$(date '+%H:%M:%S') ${Fgreen}Профиль ${pkey} (РКН): применена стратегия ${best}${plain} (${best_short})"
                profile_strategy_restart_if_needed "$pkey" "$cfg" "$old_udp_ports"
            else
                echo -e "$(date '+%H:%M:%S') ${red}Профиль ${pkey} (РКН): не удалось применить стратегию ${best}.${plain}" >&2
            fi
        else
            echo -e "$(date '+%H:%M:%S') ${yellow}РКН: зелёного покрытия нет — профильная строка не менялась.${plain}" >&2
        fi
        marker="domains"
        telemetry_notify
    elif [ -n "$best" ]; then
        old_udp_ports="$(config_get_var "$cfg" NFQWS2_PORTS_UDP)"
        if profile_state_set_and_apply "$pkey" "$protos" "$best" "$cfg"; then
            marker="$best"
            printf 'profile\t%s\t%s\n' "$pkey" "$best" >> "${dir}/applied.tsv"
            echo -e "$(date '+%H:%M:%S') ${Fgreen}Профиль ${pkey}: воркер завершён — применена лучшая стратегия ${best}${plain} (${best_short})"
            profile_strategy_restart_if_needed "$pkey" "$cfg" "$old_udp_ports"
            telemetry_notify
        else
            marker="error"
            echo -e "$(date '+%H:%M:%S') ${red}Профиль ${pkey}: не удалось применить стратегию ${best}.${plain}" >&2
        fi
    else
        # no best: return the profile to its pre-sweep lock right away
        _supersweep_restore_prev profile "$pkey"
    fi
    printf '%s\n' "$marker" > "${dir}/applied.done.${name}"
    return 0
}

# settle every finished-but-unsettled worker (skipped on cancel: an abort
# must not introduce new changes). called from the coordinator loop and once
# after it: the loop breaks the moment the last worker dies, before it could
# process that worker's done marker (typically the rkn winner)
_supersweep_settle_pass() {
    local cfg="$1" dir="$Z2R_SUPERSWEEP_DIR" wname
    for wname in yt gv ds rkn; do
        [ -e "${dir}/done.${wname}" ] || continue
        [ -e "${dir}/applied.done.${wname}" ] && continue
        case "$wname" in
            yt)  _supersweep_settle_worker yt  1 "tls http" "$cfg" ;;
            gv)  _supersweep_settle_worker gv  2 "tls"       "$cfg" ;;
            ds)  _supersweep_settle_worker ds  4 "tls"       "$cfg" ;;
            rkn) _supersweep_settle_worker rkn 3 "tls"       "$cfg" ;;
        esac
    done
    return 0
}

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

# create the results archive the same way backup_create_core does: plain
# uncompressed tar over a stable stage dir (results are final when this
# runs). plain "tar" can still resolve to busybox tar without create mode
# in non-login contexts (entware: /opt/usr/bin/tar shadows the GNU one in
# /opt/bin; login shells and the interactive menu get GNU first), so walk
# the candidates: explicit override first (also used by smoke tests), then
# PATH tar, then known GNU tar locations
_supersweep_tar_create() {
    local tgz="$1" dir="$2" t
    for t in "${Z2R_SUPERSWEEP_TAR:-}" tar /opt/bin/tar /opt/libexec/tar-gnu; do
        [ -n "$t" ] || continue
        "$t" -cf "$tgz" -C "$dir" . >/dev/null 2>&1 && [ -s "$tgz" ] && return 0
        rm -f "$tgz"
    done
    return 1
}

# archive everything the sweep collected (including the rolled-back previous
# locks from prev.tsv) and push it to the stats endpoint when configured

# telemetry identity for the stats upload: same uuid as the main telemetry
# (telemetry.config); empty when telemetry was never initialized
_supersweep_stats_uuid() {
    local cfg="${TELEMETRY_CFG:-/opt/zator/z2r_lib/telemetry.config}"
    [ -f "$cfg" ] || return 0
    sed -n 's/^tel_uuid=//p' "$cfg" | head -n1
}

_supersweep_stats_enabled() {
    local cfg="${TELEMETRY_CFG:-/opt/zator/z2r_lib/telemetry.config}"
    [ -f "$cfg" ] && grep -q '^tel_enabled=1$' "$cfg"
}

# meta.tsv inside every results archive: identity and context for the stats
# backend. uuid ties the archive to the main telemetry records (isp/os/webui
# live there — no duplication here); blob_* rows mirror the blob fields of
# send_stats: blob_global = the config-wide blob (config_tls_blob_menu_value,
# "fake_default_tls" or a maxru file name), blob_<profile> = the effective
# blob for profiles that support overrides (blob_override.tsv, falling back
# to the global one)
_supersweep_meta_write() {
    local dir="$Z2R_SUPERSWEEP_DIR"
    local uuid prov blob_cfg blob_global p b_val v
    uuid="$(_supersweep_stats_uuid)"
    prov=""
    if [ -s "${PROVIDER_TXT:-/opt/zator/extra_strats/cache/provider.txt}" ]; then
        prov="$(head -n1 "${PROVIDER_TXT:-/opt/zator/extra_strats/cache/provider.txt}" | head -c 60)"
    fi
    blob_cfg="${ZAPRET2_ROOT:-/opt/zapret2}/config"
    [ -f "$blob_cfg" ] || blob_cfg="${ZAPRET2_ROOT:-/opt/zapret2}/config.default"
    blob_global=""
    if type config_tls_blob_menu_value >/dev/null 2>&1 && [ -f "$blob_cfg" ]; then
        blob_global="$(config_tls_blob_menu_value "$blob_cfg")"
        [ "$blob_global" = "default" ] && blob_global="fake_default_tls"
        [ "$blob_global" = "неизвестно" ] && blob_global=""
    fi
    {
        printf 'uuid\t%s\n' "$uuid"
        printf 'provider\t%s\n' "$prov"
        printf 'created\t%s\n' "$(date +%s)"
        printf 'zapret2\t%s\n' "$(type zapret2_version_short >/dev/null 2>&1 && zapret2_version_short || echo unknown)"
        printf 'blob_global\t%s\n' "$blob_global"
        if type blob_override_supported_profiles >/dev/null 2>&1 && [ -f "$blob_cfg" ]; then
            while read -r p; do
                [ -n "$p" ] || continue
                v="$blob_global"
                b_val="$(blob_override_get "$p" "$blob_cfg")"
                [ -n "$b_val" ] && v="$b_val"
                printf 'blob_%s\t%s\n' "$p" "$v"
            done < <(blob_override_supported_profiles)
        fi
    } > "${dir}/meta.tsv" 2>/dev/null
    return 0
}

supersweep_results_archive() {
    local dir="$Z2R_SUPERSWEEP_DIR" arc tgz sent="no" uuid fname
    [ -d "$dir" ] || return 1
    mkdir -p "$Z2R_SUPERSWEEP_ARCHIVE_DIR" 2>/dev/null || return 1
    _supersweep_meta_write
    # the archive name carries the telemetry uuid so the backend can key
    # the record without unpacking
    uuid="$(_supersweep_stats_uuid)"
    fname="supersweep-$(date +%Y%m%d-%H%M%S)"
    [ -n "$uuid" ] && fname="${fname}-${uuid}"
    tgz="${Z2R_SUPERSWEEP_ARCHIVE_DIR}/${fname}.tar"
    _supersweep_tar_create "$tgz" "$dir" || return 1
    # rotate: keep the newest $Z2R_SUPERSWEEP_ARCHIVE_KEEP archives (any
    # extension — .tgz from older builds rotates out too)
    ls -1t "${Z2R_SUPERSWEEP_ARCHIVE_DIR}"/supersweep-* 2>/dev/null \
        | tail -n +$((Z2R_SUPERSWEEP_ARCHIVE_KEEP + 1)) \
        | while IFS= read -r arc; do rm -f "$arc"; done
    if [ -n "$Z2R_SUPERSWEEP_STATS_URL" ]; then
        if _supersweep_stats_enabled; then
            if curl -4 -s --connect-timeout 4 --max-time 20 \
                -A "${Z2R_CURL_UA:-Mozilla/5.0}" -F "archive=@${tgz}" \
                "$Z2R_SUPERSWEEP_STATS_URL" >/dev/null 2>&1; then
                sent="yes"
            fi
        else
            # consent switch off: keep the local archive, skip the upload
            sent="off"
        fi
    fi
    printf '%s\t%s\n' "$tgz" "$sent"
    return 0
}

# a real probe hostname: at least one dot and one letter — tokens like "1"
# or "bad" survive z2r_normalize_domain but are not hostnames
_supersweep_domain_valid() {
    case "$1" in
        *.*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[a-z]*) return 0 ;;
        *) return 1 ;;
    esac
}

# normalize + dedupe the domain list; garbage tokens (dialog text, typos,
# anything z2r_normalize_domain rejects) are dropped with a warning —
# protects the engine from bad input on any surface (CLI capture, webui)
supersweep_sanitize_domains() {
    local dom clean out="" dropped=0
    for dom in $1; do
        clean="$(z2r_normalize_domain "$dom" 2>/dev/null)" || clean=""
        if [ -n "$clean" ] && _supersweep_domain_valid "$clean"; then
            case " $out " in *" $clean "*) ;; *) out="${out}${out:+ }${clean}" ;; esac
        else
            [ "$dropped" = 0 ] && echo -e "${yellow}Отброшены некорректные домены:${plain}" >&2
            echo -e "  ${dom}" >&2
            dropped=$((dropped + 1))
        fi
    done
    printf '%s\n' "$out"
}

# core engine, no interactive input (menu wrapper asks the questions):
#   supersweep_run <tls_pref> <pause_sec> <ds_pause> <rkn_pause> <rkn_par> <domain...>
# returns 0 when results were applied, 1 when cancelled/restored.
supersweep_run() {
    local tls_pref="$1" pause_sec="$2" ds_pause="$3" rkn_pause="$4" rkn_par="$5"
    shift 5
    local domains="$*"
    local dir="$Z2R_SUPERSWEEP_DIR"
    local cfg max1 max2 max4 max3
    local started="$(date +%s)"

    case "$pause_sec" in ''|*[!0-9]*) pause_sec="${Z2R_SWEEP_PAUSE:-5}" ;; esac
    # дискорд требовательнее: своя увеличенная пауза фазы
    case "$ds_pause" in ''|*[!0-9]*) ds_pause=$(( pause_sec * 3 )) ;; esac
    [ "$ds_pause" -lt "$pause_sec" ] 2>/dev/null && ds_pause="$pause_sec"
    case "$rkn_pause" in ''|*[!0-9]*) rkn_pause=60 ;; esac
    case "$rkn_par" in ''|*[!0-9]*) rkn_par="$Z2R_SUPERSWEEP_RKN_PAR_DEFAULT" ;; esac
    [ "$rkn_par" -ge 1 ] 2>/dev/null || rkn_par=1
    case "$tls_pref" in 12|13|both) ;; *) tls_pref="any" ;; esac
    case "${Z2R_SUPERSWEEP_SETTLE:-2}" in ''|*[!0-9]*) Z2R_SUPERSWEEP_SETTLE=2 ;; esac

    # dialog leftovers / typos / webui input must not reach the workers
    domains="$(supersweep_sanitize_domains "$domains")"
    [ -n "$domains" ] || {
        echo -e "${red}После проверки не осталось ни одного корректного домена РКН.${plain}"
        return 1
    }

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
    [ "$batches" -lt 1 ] && batches=1
    local est1=$(( max1 * (Z2R_SUPERSWEEP_SETTLE + 6 + pause_sec) ))
    local est4=$(( max4 * (Z2R_SUPERSWEEP_SETTLE + 6 + pause_sec) ))
    # full rkn matrix (author's request): every strategy x every domain,
    # compensated by the larger dedicated rkn pause
    local estr=$(( max3 * (Z2R_SUPERSWEEP_SETTLE + batches * 6 + rkn_pause) ))
    local estmax=$est1
    [ "$est4" -gt "$estmax" ] && estmax=$est4
    [ "$estr" -gt "$estmax" ] && estmax=$estr

    echo -e "${cyan}Суперавтопрогон по фазам: YouTube, затем Googlevideo, затем Discord, затем РКН по ${total_rkn} доменам (по одному, полный проход стратегий на каждый).${plain}"
    echo -e "Стратегий: профиль 1 — ${max1}, профиль 2 — ${max2}, профиль 4 — ${max4}, РКН — ${max3}. Пауза ${pause_sec} сек (РКН ${rkn_pause} сек), выдержка после лока ${Z2R_SUPERSWEEP_SETTLE} сек."
    echo -e "РКН: домены по одному, полный проход стратегий на каждый; при серии неудач пауза растёт."
    echo -e "Ориентировочно до $(( (estmax + 59) / 60 )) мин. Прогресс: ${dir}. Ctrl+C - прервать (прежние стратегии будут возвращены)."
    echo ""

    _supersweep_status_write running "$started" "$tls_pref" "$pause_sec" "$rkn_par" "yt,gv,ds,rkn" "$domains"

    local had_e=0
    case "$-" in *e*) had_e=1 ;; esac
    set +e
    # both TLS versions must be probed honestly in every worker; probes of
    # the two versions go with a small gap — simultaneous attempts on one
    # target read as a scanner (tspu rate heuristic)
    local wait_both_prev="${Z2R_TLS_WAIT_BOTH:-}"
    Z2R_TLS_WAIT_BOTH=1
    export Z2R_TLS_WAIT_BOTH
    local probe_gap_prev="${Z2R_TLS_PROBE_GAP:-}"
    Z2R_TLS_PROBE_GAP="${Z2R_SUPERSWEEP_PROBE_GAP:-1}"
    export Z2R_TLS_PROBE_GAP

    local svc_was_running=0
    zapret2_running && svc_was_running=1

    local interrupted=0
    trap 'interrupted=1' INT

    local pid_yt="" pid_gv="" pid_ds="" pid_rkn=""
    # Фазовый режим: профили гоняются строго по очереди (YouTube -> Googlevideo
    # -> Discord -> РКН по одному домену), между фазами пауза. Параллельные
    # переключения стратегий на нескольких целях одновременно — типичный
    # триггер rate-эвристики ТСПУ; последовательные фазы с паузами её не будят.
    local phase cancelled=0 pid_alive
    for phase in yt gv ds rkn; do
        [ "$cancelled" = 1 ] && break
        [ "$interrupted" = 1 ] && cancelled=1 && break
        case "$phase" in
            yt) echo -e "$(date '+%H:%M:%S') ${cyan}=== Фаза 1/4: YouTube (профиль 1) ===${plain}" ;;
            gv) echo -e "$(date '+%H:%M:%S') ${cyan}=== Фаза 2/4: Googlevideo (профиль 2) ===${plain}" ;;
            ds) echo -e "$(date '+%H:%M:%S') ${cyan}=== Фаза 3/4: Discord (профиль 4) ===${plain}" ;;
            rkn) echo -e "$(date '+%H:%M:%S') ${cyan}=== Фаза 4/4: РКН (профиль 3, домены по одному) ===${plain}" ;;
        esac
        case "$phase" in
            yt) _supersweep_worker_profile yt yt 1 "tls http" "https://www.youtube.com/" "$max1" "$tls_pref" "$pause_sec" & local pid_yt=$! ;;
            gv) _supersweep_worker_profile gv gv 2 "tls" "$gv_url" "$max2" "$tls_pref" "$pause_sec" & local pid_gv=$! ;;
            ds) _supersweep_worker_profile ds ds 4 "tls" "https://discord.com/" "$max4" "$tls_pref" "$ds_pause" & local pid_ds=$! ;;
            rkn) _supersweep_worker_rkn rkn "$max3" "$rkn_par" "$tls_pref" "$rkn_pause" $domains & local pid_rkn=$! ;;
        esac
        local wpids pid alive
        case "$phase" in
            yt) wpids="$pid_yt" ;;
            gv) wpids="$pid_gv" ;;
            ds) wpids="$pid_ds" ;;
            rkn) wpids="$pid_rkn" ;;
        esac
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
        # a finished worker goes live immediately (skip on cancel: an abort
        # must not introduce new changes)
        [ "$cancelled" != 1 ] && _supersweep_settle_pass "$cfg"
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
    # the loop breaks the moment the worker dies: settle whatever it did not
    # get to process (for rkn — the per-domain winners)
    [ "$cancelled" != 1 ] && _supersweep_settle_pass "$cfg"
    # пауза между фазами (не после последней и не при отмене)
    if [ "$cancelled" != 1 ] && [ "$phase" != rkn ]; then
        _supersweep_phase_pause
        _supersweep_cancelled && cancelled=1
        [ "$interrupted" = 1 ] && cancelled=1
    fi
    done
    trap - INT
    if [ "$had_e" = 1 ]; then set -e; fi

    Z2R_TLS_WAIT_BOTH="$wait_both_prev"
    export Z2R_TLS_WAIT_BOTH
    Z2R_TLS_PROBE_GAP="$probe_gap_prev"
    export Z2R_TLS_PROBE_GAP

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
    # a worker killed mid-write (double interrupt in older builds) still
    # leaves coverage.tsv — recompute the rkn winners from it so the report
    # and the apply do not silently lose the collected map
    local warn_winner="" rkn_fallback_line=""
    if [ -z "$winner" ] && [ -s "${dir}/coverage.tsv" ] \
        && [ -z "$(_supersweep_kv_read "${dir}/best.rkn" reference)" ]; then
        rkn_fallback_line="$(_supersweep_rkn_winners "$(_supersweep_count_list "$domains")" "${dir}/coverage.tsv")"
        winner="$(printf '%s' "$rkn_fallback_line" | cut -f1)"
    fi

    local settle_spec settle_wname settle_pkey settle_marker
    if [ "$cancelled" = 1 ]; then
        echo ""
        echo -e "${yellow}Прервано пользователем: возвращаю прежние стратегии...${plain}"
        # profiles already settled mid-run keep their applied strategies:
        # the user is already watching youtube / chatting on them
        for settle_spec in "yt:1" "gv:2" "ds:4"; do
            settle_wname="${settle_spec%%:*}"; settle_pkey="${settle_spec#*:}"
            settle_marker=""; [ -f "${dir}/applied.done.${settle_wname}" ] && settle_marker="$(cat "${dir}/applied.done.${settle_wname}")"
            case "$settle_marker" in
                ''|none|error)
                    _supersweep_restore_prev profile "$settle_pkey"
                    ;;
                *)
                    echo -e "Профиль ${settle_pkey}: ${green}оставлена применённая стратегия ${settle_marker}${plain}."
                    ;;
            esac
        done
        # rkn on cancel: probe domain rows revert; a settled rkn worker keeps
        # its winners (per-domain + профильная строка максимума покрытия),
        # an unsettled one reverts the profile row too
        _supersweep_restore_prev domain
        if awk -F'\t' '$1 == "profile" && $2 == 3 { f = 1; exit } END { exit !f }' "${dir}/applied.tsv" 2>/dev/null; then
            echo -e "Профиль 3 (РКН): ${green}оставлена применённая стратегия${plain}."
        else
            _supersweep_restore_prev profile 3
        fi
        _supersweep_status_write cancelled "$started" "$tls_pref" "$pause_sec" "$rkn_par" "" "$domains"
    else
        # probe locks are temporary: пробные доменные строки откатываются,
        # применённые пер-доменные победители остаются; профили были
        # применены координатором по завершении воркеров, упавший воркер
        # (без маркера) возвращается к прежнему локу
        local d_applied d_tab
        d_tab="$(printf '\t')"
        for d in $domains; do
            grep -q "^domain${d_tab}${d}${d_tab}" "${dir}/applied.tsv" 2>/dev/null \
                || _supersweep_restore_prev domain "$d"
        done
        for settle_spec in "yt:1" "gv:2" "ds:4"; do
            settle_wname="${settle_spec%%:*}"; settle_pkey="${settle_spec#*:}"
            [ -e "${dir}/applied.done.${settle_wname}" ] || _supersweep_restore_prev profile "$settle_pkey"
        done
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

    local wname pkey plabel protos greens fulls warns best best_short old_udp_ports marker
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
            marker=""; [ -f "${dir}/applied.done.${wname}" ] && marker="$(cat "${dir}/applied.done.${wname}")"
            case "$marker" in
                "$best")
                    echo -e "   ${Fgreen}Применена стратегия ${best}${plain} (${best_short}) — сразу по завершении воркера"
                    ;;
                error)
                    echo -e "   ${red}Не удалось применить стратегию ${best} для профиля ${pkey}.${plain}"
                    ;;
                *)
                    # worker crashed before settling: apply now as a fallback
                    old_udp_ports="$(config_get_var "$cfg" NFQWS2_PORTS_UDP)"
                    if profile_state_set_and_apply "$pkey" "$protos" "$best" "$cfg"; then
                        echo -e "   ${Fgreen}Применена стратегия ${best}${plain} (${best_short})"
                        applied_any=1
                        profile_strategy_restart_if_needed "$pkey" "$cfg" "$old_udp_ports"
                    else
                        echo -e "   ${red}Не удалось сохранить стратегию ${best} для профиля ${pkey}.${plain}"
                    fi
                    ;;
            esac
        elif [ -n "$best" ]; then
            marker=""; [ -f "${dir}/applied.done.${wname}" ] && marker="$(cat "${dir}/applied.done.${wname}")"
            if [ "$marker" = "$best" ]; then
                echo -e "   ${Fgreen}Оставлена применённая стратегия ${best}${plain} (воркер успел завершиться до прерывания)."
            else
                echo -e "   Кандидат был ${best} — не применён (прогон прерван)."
            fi
        else
            echo -e "   ${red}Рабочих стратегий не найдено.${plain}"
        fi
    done

    # rkn report: per-domain winners applied live, профильная строка 3 —
    # стратегия максимума покрытия (дефолт списка), жёлтые — только опция
    local cover totald warn_cover ref_dom yt_greens corr rkn_ans
    totald=0
    for d in $domains; do totald=$((totald + 1)); done
    ref_dom="${domains%% *}"
    cover="$(_supersweep_kv_read "${dir}/best.rkn" winner_cover)"
    warn_winner="$(_supersweep_kv_read "${dir}/best.rkn" warn_winner)"
    warn_cover="$(_supersweep_kv_read "${dir}/best.rkn" warn_winner_cover)"
    if [ -n "$rkn_fallback_line" ]; then
        [ -n "$cover" ] || cover="$(printf '%s' "$rkn_fallback_line" | cut -f2)"
        [ -n "$warn_winner" ] || warn_winner="$(printf '%s' "$rkn_fallback_line" | cut -f4)"
        [ -n "$warn_cover" ] || warn_cover="$(printf '%s' "$rkn_fallback_line" | cut -f5)"
    fi
    echo -e " РКН (профиль 3, доменов в прогоне: ${totald}):"
    echo -e "   Домены гоняются по одному, полный проход стратегий на каждый."
    # применённые пер-доменные победители (зелёные, применены сразу)
    local applied_dom applied_cnt=0
    applied_dom="$(awk -F'\t' '$1 == "domain" { print "     " $2 ": стратегия " $3 }' "${dir}/applied.tsv" 2>/dev/null || true)"
    if [ -n "$applied_dom" ]; then
        applied_cnt="$(printf '%s\n' "$applied_dom" | grep -c . || true)"
        echo -e "   ${Fgreen}Персональные стратегии применены (${applied_cnt} домен(ов)):${plain}"
        printf '%s\n' "$applied_dom"
    elif [ "$cancelled" != 1 ]; then
        echo -e "   ${red}Зелёных пер-доменных результатов нет.${plain}"
    else
        echo -e "   Прогон прерван — пер-доменные результаты не применялись."
    fi
    # жёлтые (одна версия TLS): показываются, применяются только явным согласием
    local warn_dom
    warn_dom="$(_supersweep_rkn_domain_winners "${dir}/coverage.tsv" | awk -F'\t' '$3 == 1 { print $1 }' || true)"
    if [ -n "$warn_dom" ]; then
        echo -e "   Жёлтые (только одна версия TLS, не применялись): ${yellow}$(printf '%s ' $warn_dom)${plain}"
        echo -e "   ${yellow}Сплошные жёлтые/красные результаты похожи на деградацию канала (возможно, сработала защита от частых переключений). Повторите прогон позже или с большей паузой.${plain}"
        # explicit opt-in: never automatic (an all-yellow map is often the
        # channel, not the strategy), and only in an interactive terminal —
        # a webui run just sees the hint above
        if [ "$cancelled" != 1 ] && [ -t 0 ]; then
            read -re -p "   Применить жёлтые пер-доменные стратегии (одна версия TLS)? 1 - да, Enter - нет: " rkn_ans || rkn_ans=""
            if [ "$rkn_ans" = "1" ]; then
                _supersweep_rkn_domain_winners "${dir}/coverage.tsv" \
                    | awk -F'\t' '$3 == 1 { print $1 "\t" $2 }' \
                    | while IFS="$(printf '\t')" read -r dwin dstr; do
                        [ -n "$dwin" ] || continue
                        if orch_locked_set "$dwin" tls "$dstr"; then
                            printf 'domain\t%s\t%s\n' "$dwin" "$dstr" >> "${dir}/applied.tsv"
                            echo -e "   ${Fgreen}Домен ${dwin}: применена жёлтая стратегия ${dstr}${plain}"
                        fi
                    done
                applied_any=1
                telemetry_notify
            fi
        fi
    fi
    if [ -z "$applied_dom" ] && [ -z "$warn_dom" ]; then
        echo -e "   ${red}Ни одна стратегия не открыла ни один домен.${plain}"
    fi
    # профильная строка РКН (максимум покрытия) — дефолт всего списка
    local rkn_prof no_win="" d_tab2
    d_tab2="$(printf '\t')"
    if [ "$cancelled" = 1 ]; then
        echo -e "   Профильная стратегия РКН (весь список) не применялась — прогон прерван."
    elif [ -n "$winner" ]; then
        rkn_prof="$(awk -F'\t' '$1 == "profile" && $2 == 3 { print $3; exit }' "${dir}/applied.tsv" 2>/dev/null || true)"
        if [ -z "$rkn_prof" ]; then
            # settle не успел (воркер упал после записи best) — применяем сейчас
            old_udp_ports="$(config_get_var "$cfg" NFQWS2_PORTS_UDP)"
            if profile_state_set_and_apply 3 "tls" "$winner" "$cfg"; then
                printf 'profile\t%s\t%s\n' 3 "$winner" >> "${dir}/applied.tsv"
                rkn_prof="$winner"
                applied_any=1
                profile_strategy_restart_if_needed 3 "$cfg" "$old_udp_ports"
            fi
        fi
        if [ -n "$rkn_prof" ]; then
            echo -e "   ${Fgreen}Профильная стратегия РКН (дефолт всего списка): ${rkn_prof}${plain} — зелёная на ${cover} из ${totald} домен(ов)"
        else
            echo -e "   ${red}Не удалось применить профильную стратегию РКН (${winner}).${plain}"
        fi
    else
        echo -e "   Профильная стратегия РКН не менялась: зелёного покрытия нет ни у одной стратегии."
    fi
    # домены без персонального победителя едут на профильной стратегии
    for d in $domains; do
        grep -q "^domain${d_tab2}${d}${d_tab2}" "${dir}/applied.tsv" 2>/dev/null \
            || no_win="${no_win}${no_win:+ }${d}"
    done
    [ -n "$no_win" ] && echo -e "   Без персональной стратегии (едут на профильной): ${no_win}"
    # correlation hint: youtube-green strategies vs the reference passes.
    # an early cancel can leave no coverage.tsv at all — print plain zeros
    yt_greens="$(_supersweep_kv_read "${dir}/best.yt" greens)"
    corr="0 0"
    if [ -s "${dir}/coverage.tsv" ]; then
        corr="$(awk -F'\t' -v ref="$ref_dom" -v g=" $yt_greens " '
            $2 == ref && ($4 == "ok" || $4 == "warn") {
                k++
                if (index(g, " " $3 " ") > 0) m++
            }
            END { print (m+0) " " (k+0) }' "${dir}/coverage.tsv" 2>/dev/null || printf '0 0')"
    fi
    echo -e "   Корреляция с YouTube: из зелёных на YouTube стратегий домен ${ref_dom} пробили ${corr%% *}; всего пробито ${corr##* } стратегией(-ями)."
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
            case "$arc_sent" in
                yes)
                    echo -e " ${green}Архив отправлен на сервер статистики.${plain}"
                    ;;
                off)
                    echo -e " ${yellow}Отправка отключена: анонимная статистика выключена в настройках телеметрии.${plain}"
                    ;;
                *)
                    echo -e " ${yellow}Не удалось отправить архив на сервер статистики (сеть/endpoint).${plain}"
                    ;;
            esac
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

# dialog helpers contract (same as orch_ask_sweep_pause/orch_ask_sweep_tls_pref):
# ALL explanation text goes to stderr, stdout carries ONLY the answer —
# callers capture stdout and feed it straight into the engine.

supersweep_ask_domains() {
    # prints the selected space-separated domain list (empty = cancel)
    local defaults="$Z2R_SUPERSWEEP_RKN_DOMAINS"
    local d i pick dom selected="" total=0
    echo -e "${cyan}--- Домены РКН для карты покрытий ---" >&2
    echo -e "Базовый набор сообщества; Enter — проверяются все.${plain}" >&2
    echo "" >&2
    i=1
    for d in $defaults; do
        echo -e "  ${Fcyan}${i}.${plain} ${green}${d}${plain}" >&2
        i=$((i + 1))
    done
    echo "" >&2
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
        echo -e "${yellow}Не выбран ни один домен — берём весь список.${plain}" >&2
        printf '%s\n' "$defaults"
        return 0
    fi
    for d in $selected; do total=$((total + 1)); done
    echo -e "Из базового набора выбрано ${green}${total}${plain}: ${green}${selected}${plain}" >&2
    printf '%s\n' "$selected"
}

supersweep_ask_own_domains() {
    # $1 = current selection (space separated); appends user domains,
    # adding unknown ones to TCP_Custom.txt so profile 3 picks them up
    local selected="$1" raw dom clean added=0 skipped=0 total=0
    read -re -p "Свои домены через пробел (Enter - пропустить): " raw
    [ -z "$raw" ] && { printf '%s\n' "$selected"; return 0; }
    raw="$(printf '%s' "$raw" | tr ',' ' ')"
    local rkn_list custom_file
    rkn_list="${ZATOR_ROOT:-/opt/zator}/extra_strats/TCP_RKN_list.txt"
    custom_file="$(custom_rkn_file)"
    for dom in $raw; do
        if ! clean="$(z2r_normalize_domain "$dom")" || ! _supersweep_domain_valid "$clean"; then
            echo -e "${yellow}Не распознан домен: ${dom} — пропущен.${plain}" >&2
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
            echo -e "${green}Домен ${clean} добавлен в TCP_Custom (обрабатывается профилем 3).${plain}" >&2
            added=$((added + 1))
        fi
    done
    [ "$skipped" -gt 0 ] && echo -e "${yellow}Пропущено нераспознанных: ${skipped}.${plain}" >&2
    for dom in $selected; do total=$((total + 1)); done
    echo -e "Всего доменов РКН в прогоне: ${green}${total}${plain}" >&2
    echo -e "${green}${selected}${plain}" >&2
    printf '%s\n' "$selected"
}

supersweep_ask_pause() {
    # фазы YouTube/Googlevideo идут по очереди и щепетильно не переключают
    # много локов сразу: по отзывам достаточно короткой паузы (минимум 5 сек)
    local pause
    while true; do
        read -re -p "Пауза YouTube/Googlevideo между стратегиями. Минимум 5 сек (Enter - 5 сек, 0 - отмена): " pause || pause=""
        if [ "$pause" = "0" ]; then
            return 0
        fi
        [ -n "$pause" ] || pause=5
        case "$pause" in
            *[!0-9]*)
                echo -e "${yellow}Неверный ввод: нужно число секунд (минимум 5).${plain}" >&2
                ;;
            *)
                if [ "$pause" -lt 5 ]; then
                    echo -e "${yellow}Пауза не может быть меньше 5 секунд (введено ${pause}).${plain}" >&2
                else
                    echo "$pause"
                    return 0
                fi
                ;;
        esac
    done
}

supersweep_ask_rkn_par() {
    # how many RKN domains to probe simultaneously per batch; every selected
    # domain is still checked each round — this only sets the batch size
    local par ndom=0 d
    for d in $1; do ndom=$((ndom + 1)); done
    echo -e "Все выбранные домены проверяются на каждой стратегии — пакет лишь" >&2
    echo -e "задаёт, сколько проверок идёт одновременно (больше = быстрее, но" >&2
    echo -e "выше нагрузка на роутер и шумнее замеры скорости)." >&2
    while true; do
        read -re -p "Доменов в одном пакете, 1-${ndom} (Enter - ${Z2R_SUPERSWEEP_RKN_PAR_DEFAULT}): " par || par=""
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

supersweep_ask_ds_pause() {
    # discord требовательнее к частым переключениям (голос/шлюзы): своя
    # увеличенная пауза, минимум 15 секунд
    local pause
    while true; do
        read -re -p "Пауза Discord между стратегиями. Минимум 15 сек (Enter - 15 сек, 0 - отмена): " pause || pause=""
        if [ "$pause" = "0" ]; then
            return 0
        fi
        [ -n "$pause" ] || pause=15
        case "$pause" in
            *[!0-9]*)
                echo -e "${yellow}Неверный ввод: нужно число секунд (минимум 15).${plain}" >&2
                ;;
            *)
                if [ "$pause" -lt 15 ]; then
                    echo -e "${yellow}Пауза Discord не может быть меньше 15 секунд (введено ${pause}).${plain}" >&2
                else
                    echo "$pause"
                    return 0
                fi
                ;;
        esac
    done
}

supersweep_ask_rkn_pause() {
    # РКН идёт по одному домену с полным проходом стратегий; минутный
    # интервал максимально щадящий к ТСПУ (медленнее, но безопаснее),
    # минимум 30 секунд
    local pause
    while true; do
        read -re -p "Пауза РКН между попытками. Минимум 30 сек, минута - максимально щадяще (Enter - 60 сек, 0 - отмена): " pause || pause=""
        if [ "$pause" = "0" ]; then
            return 0
        fi
        [ -n "$pause" ] || pause=60
        case "$pause" in
            *[!0-9]*)
                echo -e "${yellow}Неверный ввод: нужно число секунд (минимум 30).${plain}" >&2
                ;;
            *)
                if [ "$pause" -lt 30 ]; then
                    echo -e "${yellow}Пауза РКН не может быть меньше 30 секунд (введено ${pause}).${plain}" >&2
                else
                    echo "$pause"
                    return 0
                fi
                ;;
        esac
    done
}

supersweep_menu() {
    local cfg domains tls_pref pause ds_pause rkn_pause answer
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
    echo "Одним запуском: подбор стратегий по фазам — YouTube (профиль 1),"
    echo "затем Googlevideo (профиль 2), затем Discord (профиль 4), затем РКН"
    echo "(профиль 3) по одному домену за раз. Между фазами и доменами —"
    echo "паузы: частые параллельные переключения триггерят ТСПУ."
    echo "Лучшие стратегии применяются автоматически сразу по завершении"
    echo "воркера/домена; РКН получает персональные строки доменов."
    echo "Базовый набор РКН — список сообщества (meduza.io, rutracker.org,"
    echo "xhamster.com и др.); свои домены к нему только добавляются."
    echo "При серии неудач подряд пауза автоматически растёт (gentle-режим)."
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
    ds_pause="$(supersweep_ask_ds_pause)"
    if [ -z "$ds_pause" ]; then
        echo "Отмена."
        return 0
    fi
    rkn_pause="$(supersweep_ask_rkn_pause)"
    if [ -z "$rkn_pause" ]; then
        echo "Отмена."
        return 0
    fi

    local ndom=0 d
    for d in $domains; do ndom=$((ndom + 1)); done
    local max1 max3 batches est estr
    max1="$(config_profile_max_strategy 1 "$cfg")"
    printf '%s' "$max1" | grep -Eq '^[1-9][0-9]*$' || max1=43
    max3="$(config_profile_max_strategy 3 "$cfg")"
    printf '%s' "$max3" | grep -Eq '^[1-9][0-9]*$' || max3=43
    est=$(( max1 * (Z2R_SUPERSWEEP_SETTLE + 6 + pause) ))
    estr=$(( ndom * max3 * (Z2R_SUPERSWEEP_SETTLE + 6 + rkn_pause) ))
    [ "$estr" -gt "$est" ] && est=$estr

    echo ""
    echo -e "Домены РКН в прогоне (${ndom}):"
    echo -e "${green}$(printf '%s\n' $domains | tr '\n' ' ' | sed 's/ $//')${plain}"
    echo -e "РКН: ${ndom} домен(ов) по одному, полный проход стратегий на каждый, пауза РКН ${rkn_pause} сек."
    echo ""
    echo -e "Прогон займёт ориентировочно до $(( (est + 59) / 60 )) мин. Во время прогона"
    echo -e "интернет может подтормаживать (стратегии переключаются на лету)."
    read -re -p "Enter - старт, 0 - отмена: " answer
    [ "$answer" = "0" ] && { echo "Отмена."; return 0; }

    supersweep_run "$tls_pref" "$pause" "$ds_pause" "$rkn_pause" 1 $domains
    pause_enter
}
