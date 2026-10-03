# Суперавтопрогон: профили 1/2/4 по очереди, затем полная карта РКН.
# Локи пишет только родитель (cmd.<name>); прогресс — файлы для WebUI.
# Результаты и прежние локи архивируются, отправка статистики опциональна.

Z2R_SUPERSWEEP_DIR="${Z2R_SUPERSWEEP_DIR:-/tmp/z2r-supersweep}"
# После записи лока ждём TTL кеша Lua (2 с), чтобы не проверить прежнюю стратегию.
Z2R_SUPERSWEEP_SETTLE="${Z2R_SUPERSWEEP_SETTLE:-2}"
Z2R_SUPERSWEEP_ARCHIVE_DIR="${Z2R_SUPERSWEEP_ARCHIVE_DIR:-${ORCH_DIR:-/opt/zator/extra_strats/cache/orchestra}/supersweep}"
# Сервер автора; пустой URL отключает отправку, согласие и UUID общие с телеметрией (tel_enabled).
Z2R_SUPERSWEEP_STATS_URL="${Z2R_SUPERSWEEP_STATS_URL-https://alooflibra.fun/z4r/supersweep}"
Z2R_SUPERSWEEP_ARCHIVE_KEEP="${Z2R_SUPERSWEEP_ARCHIVE_KEEP:-10}"
Z2R_SUPERSWEEP_RKN_PAR_DEFAULT="${Z2R_SUPERSWEEP_RKN_PAR_DEFAULT:-2}"
# Базовые домены уже в TCP_RKN_list.txt; добавление в TCP_Custom не требуется.
Z2R_SUPERSWEEP_RKN_DOMAINS="${Z2R_SUPERSWEEP_RKN_DOMAINS:-xhamster.com anidub.com amnezia.org}"

# Цвета для standalone-запуска; в меню их задаёт z2r.sh.
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

# Отмена: touch "$Z2R_SUPERSWEEP_DIR/cancel"; воркеры остановятся на безопасном шаге, откат — в родителе.
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

# Победитель домена: ok > warn > fail, затем скорость и меньший номер; rank 0=ok, 1=warn.
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

# --- Команды воркер → родитель (единственный писатель локов) ---
# cmd.<name> публикуется через tmp+mv: r|<round>, затем
# profile|<prof>|<proto>|<strategy> или domain|<dom>|<proto>|<strategy>.
# После orch_locked_set родитель переименовывает файл в applied.<name> — ACK раунда.

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

# --- Вывод стратегии: бейджи TLS и краткий вердикт ---

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

# progress.<name>.tsv: epoch, target, strategy, token, tls12, tls13, dl bytes, dl time, short.
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

# --- Профильный воркер: стратегии 1..max ---

_supersweep_worker_profile() {
    local name="$1" tag="$2" profile="$3" proto_list="$4" url="$5" max="$6"
    local dir="$Z2R_SUPERSWEEP_DIR"
    local tls_pref="$7" pause_sec="$8"
    local s p round=0 out v12 v13 dl short token specs
    local ok_list="" warn_list="" full_list="" ok_stats="" warn_stats=""
    local n_ok=0 n_warn=0 n_fail=0
    local ss_interrupted=0 psleep settle_v g
    # Settle входит в паузу; интервал проверок = пауза + время пробы.
    settle_v="${Z2R_SUPERSWEEP_SETTLE:-2}"
    case "$settle_v" in ''|*[!0-9]*) settle_v=2 ;; esac
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

        if [ "$s" -lt "$max" ]; then
            # Обе TLS зелёные → GREEN_PAUSE (0 отключает), в том числе для Discord.
            psleep="$pause_sec"
            if [ "$psleep" -gt "$settle_v" ]; then
                psleep=$((psleep - settle_v))
            else
                psleep=0
            fi
            if [ "$token" = ok ] && [ "$q12" = 1 ] && [ "$q13" = 1 ]; then
                g="${Z2R_SUPERSWEEP_GREEN_PAUSE:-5}"
                case "$g" in ''|*[!0-9]*) g=5 ;; esac
                if [ "$g" -gt 0 ]; then psleep="$g"; fi
            fi
            printf '%s\t%s\t%s\t%s\n' "$name" "$s" "$psleep" >> "${dir}/pacing.tsv"
            [ "$psleep" -gt 0 ] && _supersweep_sleep "$psleep"
        fi
    done
    # До записи best.<name> сохраняем traps против повторного INT.
    # interrupted помечает неполный проход: родитель не должен применять его результат.

    local ss_incomplete=0
    [ "$s" -le "$max" ] && ss_incomplete=1

    # Самая быстрая зелёная; без докачки — первая; без зелёных — жёлтая.
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

# TSV: ok_winner, ok_cover, total, warn_winner, warn_cover.
# Рейтинг: покрытие → сумма скоростей → меньший номер. Warn только для отчёта.
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

# --- РКН: все стратегии каждого домена; YouTube-зелёные первыми ---
# Один эталонный домен может быть мёртв — остальные нельзя пропускать.

_supersweep_rkn_record() {
    # Аргументы: domain, strategy, engine out (3 строки), tls_pref.
    # stdout: ok|warn|fail; stderr: строка для консоли.
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
    local ref d round=0 token out s
    local ss_interrupted=0
    trap 'ss_interrupted=1' INT TERM
    set +e
    mkdir -p "$tmpd" 2>/dev/null

    ref="${domains%% *}"

    # Порядок по результатам YouTube меняет только очередность, не набор стратегий.
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

    # Полный последовательный проход каждого домена против rate-эвристик ТСПУ.
    local dtot="$(_supersweep_count_list "$domains")" dnum=0 dom_first=1 peff g
    for d in $domains; do
        [ "$ss_interrupted" = 1 ] && break
        _supersweep_cancelled && break
        [ "$dom_first" = 1 ] || _supersweep_sleep "$pause_sec"
        dom_first=0
        dnum=$((dnum + 1))
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
            # Обе TLS зелёные → GREEN_PAUSE (0 отключает), иначе пауза пользователя без эскалации.
            peff="$pause_sec"
            if [ "$token" = ok ] \
                && z2r_tls_code_ok "$(z2r_tls_field "$(printf '%s\n' "$out" | sed -n 1p)" 2)" \
                && z2r_tls_code_ok "$(z2r_tls_field "$(printf '%s\n' "$out" | sed -n 2p)" 2)"; then
                g="${Z2R_SUPERSWEEP_GREEN_PAUSE:-5}"
                case "$g" in ''|*[!0-9]*) g=5 ;; esac
                if [ "$g" -gt 0 ]; then peff="$g"; fi
            fi
            printf '%s\t%s\t%s\t%s\n' "rkn" "$s" "$peff" >> "${dir}/pacing.tsv"
            [ "$peff" -gt 0 ] && _supersweep_sleep "$peff"
        done
    done
    # До best.<name> сохраняем traps против повторного INT; неполную карту не применять.
    # После for s остаётся последним номером; завершение проверяем по coverage.tsv.

    local ss_incomplete=0 probed=0 need=0
    for d in $s_list; do need=$((need + 1)); done
    probed="$(cut -f3 "${dir}/coverage.tsv" 2>/dev/null | sort -u | wc -l | tr -d '[:space:]')"
    [ -n "$probed" ] || probed=0
    [ "$probed" -lt "$need" ] && ss_incomplete=1

    # Warn только для отчёта: сплошной жёлтый может означать деградацию канала.
    local winner_line
    winner_line="$(_supersweep_rkn_winners "$dtot" "${dir}/coverage.tsv")"
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

# --- Родитель: применение результатов и сводка ---
# Применяем завершённые профили сразу, не дожидаясь РКН.
# applied.done.<name>: стратегия | none | error; для РКН — domains.

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
    # best/done пишутся и при отмене; interrupted запрещает применение частичного результата.
    if [ "$(_supersweep_kv_read "${dir}/best.${name}" interrupted)" = 1 ]; then
        if [ "$name" != rkn ]; then
            _supersweep_restore_prev profile "$pkey"
        fi
        printf 'none\n' > "${dir}/applied.done.${name}"
        return 0
    fi
    if [ "$name" = rkn ]; then
        # Зелёные доменные победители — сразу; жёлтые — только по согласию в сводке.
        local dwin dstr drank
        _supersweep_rkn_domain_winners "${dir}/coverage.tsv" \
            | while IFS="$(printf '\t')" read -r dwin dstr drank; do
                [ -n "$dwin" ] || continue
                [ "$drank" = 0 ] || continue
                if orch_locked_set "$dwin" tls "$dstr"; then
                    printf 'domain\t%s\t%s\n' "$dwin" "$dstr" >> "${dir}/applied.tsv"
                    echo -e "$(date '+%H:%M:%S') ${Fgreen}РКН: домен ${dwin} — применена стратегия ${dstr}${plain}"
                fi
            done
        marker="domains"
    fi
    # Победитель профиля РКН — дефолт для доменов без персонального лока.
    if [ -n "$best" ]; then
        old_udp_ports="$(config_get_var "$cfg" NFQWS2_PORTS_UDP)"
        if profile_state_set_and_apply "$pkey" "$protos" "$best" "$cfg"; then
            [ "$name" = rkn ] || marker="$best"
            printf 'profile\t%s\t%s\n' "$pkey" "$best" >> "${dir}/applied.tsv"
            if [ "$name" = rkn ]; then
                echo -e "$(date '+%H:%M:%S') ${Fgreen}Профиль ${pkey} (РКН): применена стратегия ${best}${plain} (${best_short})"
            else
                echo -e "$(date '+%H:%M:%S') ${Fgreen}Профиль ${pkey}: воркер завершён — применена лучшая стратегия ${best}${plain} (${best_short})"
            fi
            profile_strategy_restart_if_needed "$pkey" "$cfg" "$old_udp_ports"
            [ "$name" = rkn ] || telemetry_notify
        else
            if [ "$name" = rkn ]; then
                echo -e "$(date '+%H:%M:%S') ${red}Профиль ${pkey} (РКН): не удалось применить стратегию ${best}.${plain}" >&2
            else
                marker="error"
                echo -e "$(date '+%H:%M:%S') ${red}Профиль ${pkey}: не удалось применить стратегию ${best}.${plain}" >&2
            fi
        fi
    elif [ "$name" = rkn ]; then
        echo -e "$(date '+%H:%M:%S') ${yellow}РКН: зелёного покрытия нет — профильная строка не менялась.${plain}" >&2
    else
        # Нет победителя — сразу вернуть прежний профильный лок.
        _supersweep_restore_prev profile "$pkey"
    fi
    if [ "$name" = rkn ]; then telemetry_notify; fi
    printf '%s\n' "$marker" > "${dir}/applied.done.${name}"
    return 0
}

# Вызывать в цикле и после wait: воркер может выйти до обработки done.
# При отмене не вызывать: новые результаты применять нельзя.
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
    # Pipe-subshell наследует orch_locked_set; файлы общие, писатель один.
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
    # file, key → значение (пусто, если отсутствует).
    [ -f "$1" ] || return 0
    sed -n "s/^$2=//p" "$1" | head -n1
}

_supersweep_restore_prev() {
    # Фильтры: kind (profile|domain, пусто = все), необязательный key.
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

# Несжатый tar финальных результатов, как backup_create_core.
# Entware: в non-login PATH /opt/usr/bin/tar может быть BusyBox без create.
# Приоритет: Z2R_SUPERSWEEP_TAR → PATH → известные GNU tar.
_supersweep_tar_create() {
    local tgz="$1" dir="$2" t
    for t in "${Z2R_SUPERSWEEP_TAR:-}" tar /opt/bin/tar /opt/libexec/tar-gnu; do
        [ -n "$t" ] || continue
        "$t" -cf "$tgz" -C "$dir" . >/dev/null 2>&1 && [ -s "$tgz" ] && return 0
        rm -f "$tgz"
    done
    return 1
}


# UUID из telemetry.config; пусто, если телеметрия не инициализирована.
_supersweep_stats_uuid() {
    local cfg="${TELEMETRY_CFG:-/opt/zator/z2r_lib/telemetry.config}"
    [ -f "$cfg" ] || return 0
    sed -n 's/^tel_uuid=//p' "$cfg" | head -n1
}

_supersweep_stats_enabled() {
    local cfg="${TELEMETRY_CFG:-/opt/zator/z2r_lib/telemetry.config}"
    [ -f "$cfg" ] && grep -q '^tel_enabled=1$' "$cfg"
}

# meta.tsv: связь с телеметрией; blob_* как в send_stats.
# Глобальный blob: fake_default_tls/maxru; без override профиль наследует его.
_supersweep_meta_write() {
    local dir="$Z2R_SUPERSWEEP_DIR"
    local uuid prov blob_cfg blob_global p b_val v m
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
        # mode_<profile>: clone/classic; без строки в mode_override.tsv — classic.
        if type mode_override_get >/dev/null 2>&1 \
            && type mode_override_supported_profiles >/dev/null 2>&1; then
            while read -r p; do
                [ -n "$p" ] || continue
                m="$(mode_override_get "$p" 2>/dev/null)"
                [ "$m" = "clone" ] || m="classic"
                printf 'mode_%s\t%s\n' "$p" "$m"
            done < <(mode_override_supported_profiles)
        fi
        # size_<profile>: лимит клона; без строки — только общий потолок 1200 Б.
        if type clone_size_get >/dev/null 2>&1 \
            && type clone_size_supported_profiles >/dev/null 2>&1; then
            while read -r p; do
                [ -n "$p" ] || continue
                s="$(clone_size_get "$p" 2>/dev/null)"
                [ -n "$s" ] && printf 'size_%s\t%s\n' "$p" "$s"
            done < <(clone_size_supported_profiles)
        fi
    } > "${dir}/meta.tsv" 2>/dev/null
    return 0
}

supersweep_results_archive() {
    local dir="$Z2R_SUPERSWEEP_DIR" arc tgz sent="no" uuid fname
    [ -d "$dir" ] || return 1
    mkdir -p "$Z2R_SUPERSWEEP_ARCHIVE_DIR" 2>/dev/null || return 1
    _supersweep_meta_write
    # UUID в имени позволяет серверу связать архив с телеметрией без распаковки.
    uuid="$(_supersweep_stats_uuid)"
    fname="supersweep-$(date +%Y%m%d-%H%M%S)"
    [ -n "$uuid" ] && fname="${fname}-${uuid}"
    tgz="${Z2R_SUPERSWEEP_ARCHIVE_DIR}/${fname}.tar"
    _supersweep_tar_create "$tgz" "$dir" || return 1
    # Оставить ARCHIVE_KEEP новых архивов, включая старый формат .tgz.
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
            sent="off"
        fi
    fi
    printf '%s\t%s\n' "$tgz" "$sent"
    return 0
}

# Требуем точку и букву: normalize_domain пропускает также "1" и "bad".
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

# Нормализация и дедупликация; мусор из CLI/WebUI отбрасывается с предупреждением.
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

# Общая оценка меню/прогона: сумма фаз (проба ≈6 с + пауза) и межфазовых пауз.
# РКН — по доменам; settle входит в паузу. GREEN_PAUSE не учитываем (худший случай).
_supersweep_estimate_total() {
    # $1..4: max профилей 1/2/4/3; $5: домены; $6..8: паузы yt/gv, ds, rkn. Выход: секунды.
    local m1="$1" m2="$2" m4="$3" m3="$4" nd="$5" p="$6" pd="$7" pr="$8"
    local phase_pause="${Z2R_SUPERSWEEP_PHASE_PAUSE:-30}"
    case "$phase_pause" in ''|*[!0-9]*) phase_pause=30 ;; esac
    echo $(( m1 * (6 + p) + m2 * (6 + p) + m4 * (6 + pd) + nd * m3 * (6 + pr) + 3 * phase_pause ))
}

# supersweep_run <tls_pref> <pause> <ds_pause> <rkn_pause> <rkn_par> <domain...>
# Без диалогов; rc=0 завершён, rc=1 отменён/откат.
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

    # Статический реестр воркеров для WebUI.
    {
        printf 'yt\tyt\tprofile\t1\thttps://www.youtube.com/\t%s\n' "$max1"
        printf 'gv\tgv\tprofile\t2\t%s\t%s\n' "$gv_url" "$max2"
        printf 'ds\tds\tprofile\t4\thttps://discord.com/\t%s\n' "$max4"
        printf 'rkn\tRKN\trkn\t3\t%s\t%s\n' "$(printf '%s' "$domains" | tr ' ' ',')" "$max3"
    } > "${dir}/workers.tsv"

    # Прежние локи для отката и архива.
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

    local total_rkn="$(_supersweep_count_list "$domains")"
    local est_total
    est_total="$(_supersweep_estimate_total "$max1" "$max2" "$max4" "$max3" "$total_rkn" "$pause_sec" "$ds_pause" "$rkn_pause")"

    echo -e "${cyan}Суперавтопрогон по фазам: YouTube, затем Googlevideo, затем Discord, затем РКН по ${total_rkn} доменам (по одному, полный проход стратегий на каждый).${plain}"
    echo -e "Стратегий: профиль 1 — ${max1}, профиль 2 — ${max2}, профиль 4 — ${max4}, РКН — ${max3}. Пауза между проверками: ${pause_sec} сек (Discord ${ds_pause}, РКН ${rkn_pause} сек); время самой проверки добавляется сверху."
    echo -e "РКН: домены по одному, полный проход стратегий на каждый."
    echo -e "Ориентировочно до $(( (est_total + 59) / 60 )) мин. Прогресс: ${dir}. Ctrl+C - прервать (прежние стратегии будут возвращены)."
    echo ""

    _supersweep_status_write running "$started" "$tls_pref" "$pause_sec" "$rkn_par" "yt,gv,ds,rkn" "$domains"

    local had_e=0
    case "$-" in *e*) had_e=1 ;; esac
    set +e
    # Ждём обе TLS-пробы; небольшой разрыв снижает риск rate-эвристики ТСПУ.
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

    # Один воркер за раз, паузы между фазами против rate-эвристик ТСПУ.
    local phase cancelled=0 pid
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
            yt) _supersweep_worker_profile yt yt 1 "tls http" "https://www.youtube.com/" "$max1" "$tls_pref" "$pause_sec" & ;;
            gv) _supersweep_worker_profile gv gv 2 "tls" "$gv_url" "$max2" "$tls_pref" "$pause_sec" & ;;
            ds) _supersweep_worker_profile ds ds 4 "tls" "https://discord.com/" "$max4" "$tls_pref" "$ds_pause" & ;;
            rkn) _supersweep_worker_rkn rkn "$max3" "$rkn_par" "$tls_pref" "$rkn_pause" $domains & ;;
        esac
        pid=$!
        while kill -0 "$pid" 2>/dev/null; do
            if [ "$interrupted" = 1 ]; then
                if [ ! -e "${dir}/cancel" ]; then
                    : > "${dir}/cancel"
                    kill -INT "$pid" 2>/dev/null || true
                fi
                cancelled=1
            fi
            _supersweep_cancelled && cancelled=1
            local f
            for f in "${dir}"/cmd.*; do
                [ -e "$f" ] || continue
                _supersweep_apply_cmd "$f"
            done
            # Завершённое применяем сразу; при отмене новых изменений не вводим.
            [ "$cancelled" != 1 ] && _supersweep_settle_pass "$cfg"
            local alive_names=""
            kill -0 "$pid" 2>/dev/null && alive_names="$phase"
            _supersweep_status_write running "$started" "$tls_pref" "$pause_sec" "$rkn_par" "$alive_names" "$domains"
            sleep 0.3 2>/dev/null || sleep 1
        done
        wait "$pid" 2>/dev/null || true
        # Обработать done последнего воркера, пропущенный из-за выхода из цикла.
        [ "$cancelled" != 1 ] && _supersweep_settle_pass "$cfg"
        # пауза между фазами (не после последней и не при отмене)
        if [ "$cancelled" != 1 ] && [ "$phase" != rkn ]; then
            _supersweep_phase_pause
            _supersweep_cancelled && cancelled=1
            [ "$interrupted" = 1 ] && cancelled=1
        fi
    done
    # До конца отката/сводки/архива глушим повторный INT, чтобы не оставить полулоки.
    # supersweep_menu вернёт обычный INT после финальной паузы.
    trap ':' INT

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

    local best_yt best_gv best_ds winner applied_any=0
    best_yt="$(_supersweep_kv_read "${dir}/best.yt" best)"
    best_gv="$(_supersweep_kv_read "${dir}/best.gv" best)"
    best_ds="$(_supersweep_kv_read "${dir}/best.ds" best)"
    winner="$(_supersweep_kv_read "${dir}/best.rkn" winner)"
    # Без best.rkn восстановить отчёт из coverage.tsv (воркер мог погибнуть при записи).
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
        # Уже применённые профили при отмене сохраняются.
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
        # РКН: доменные пробы откатить; применённый профиль сохранить, иначе вернуть прежний.
        _supersweep_restore_prev domain
        if awk -F'\t' '$1 == "profile" && $2 == 3 { f = 1; exit } END { exit !f }' "${dir}/applied.tsv" 2>/dev/null; then
            echo -e "Профиль 3 (РКН): ${green}оставлена применённая стратегия${plain}."
        else
            _supersweep_restore_prev profile 3
        fi
        _supersweep_status_write cancelled "$started" "$tls_pref" "$pause_sec" "$rkn_par" "" "$domains"
    else
        # Откатить доменные пробы без применённого победителя и профили без маркера.
        local d_tab
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

    # Архив/отправка ДО интерактивной сводки: она может ждать бесконечно.
    # Включаем красные и частичные прогоны, кроме пустой отмены.
    # Поздние жёлтые opt-in не попадут в applied.tsv архива; пробы уже есть в coverage.tsv.
    local arc_line arc_path arc_sent
    if [ "$cancelled" = 1 ] && [ ! -s "${dir}/applied.tsv" ] && [ ! -s "${dir}/coverage.tsv" ]; then
        echo -e " ${yellow}Прогон прерван до первого результата: архив не создавался, на сервер статистики ничего не отправлено.${plain}"
    else
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
    fi

    # --- Сводка и резервное применение ---
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
                    # Воркер умер до применения — применить здесь.
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
            # Завершённый YouTube весь красный → совет перезагрузить роутер.
            if [ "$wname" = yt ] && [ "$cancelled" != 1 ] \
                && [ "$(_supersweep_kv_read "${dir}/best.yt" n_ok)" = "0" ] \
                && [ "$(_supersweep_kv_read "${dir}/best.yt" n_warn)" = "0" ] \
                && [ -n "$(_supersweep_kv_read "${dir}/best.yt" n_fail)" ]; then
                z2r_youtube_reboot_advice
            fi
        fi
    done

    # РКН: доменные победители, дефолт профиля и опциональные жёлтые.
    local cover totald warn_cover ref_dom yt_greens corr rkn_ans
    totald="$total_rkn"
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
    local warn_dom
    warn_dom="$(_supersweep_rkn_domain_winners "${dir}/coverage.tsv" | awk -F'\t' '$3 == 1 { print $1 }' || true)"
    if [ -n "$warn_dom" ]; then
        echo -e "   Жёлтые (только одна версия TLS, не применялись): ${yellow}$(printf '%s ' $warn_dom)${plain}"
        echo -e "   ${yellow}Сплошные жёлтые/красные результаты похожи на деградацию канала (возможно, сработала защита от частых переключений). Повторите прогон позже или с большей паузой.${plain}"
        # Жёлтые — только явное согласие в терминале; WebUI получает лишь подсказку.
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
    local rkn_prof no_win="" d_tab2
    d_tab2="$(printf '\t')"
    if [ "$cancelled" = 1 ]; then
        echo -e "   Профильная стратегия РКН (весь список) не применялась — прогон прерван."
    elif [ -n "$winner" ]; then
        rkn_prof="$(awk -F'\t' '$1 == "profile" && $2 == 3 { print $3; exit }' "${dir}/applied.tsv" 2>/dev/null || true)"
        if [ -z "$rkn_prof" ]; then
            # Профильный победитель ещё не применён — применить здесь.
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
    # Без персонального победителя домен использует профильную стратегию.
    for d in $domains; do
        grep -q "^domain${d_tab2}${d}${d_tab2}" "${dir}/applied.tsv" 2>/dev/null \
            || no_win="${no_win}${no_win:+ }${d}"
    done
    [ -n "$no_win" ] && echo -e "   Без персональной стратегии (едут на профильной): ${no_win}"
    # Корреляция с YouTube по эталонному домену; без coverage.tsv — нули.
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

    _supersweep_status_write "$([ "$cancelled" = 1 ] && echo cancelled || echo done)" \
        "$started" "$tls_pref" "$pause_sec" "$rkn_par" "" "$domains"
    # set -e вернуть лишь перед выходом: сбой сводки/отката не должен убивать меню.
    # Вызывающее меню обязано обработать rc=1 (отмена).
    if [ "$had_e" = 1 ]; then set -e; fi
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

# --- Диалоги: stdout только ответ, подсказки в stderr (контракт orch_ask_*) ---


supersweep_ask_domains() {
    # stdout: выбранные домены через пробел; 0 отменяет с rc=1.
    local defaults="$Z2R_SUPERSWEEP_RKN_DOMAINS"
    local d i pick dom selected="" total=0
    echo -e "${cyan}--- Домены РКН для карты покрытий ---" >&2
    echo -e "Базовый набор автора (по умолчанию все три); свои домены" >&2
    echo -e "дописываются на следующем шаге — количество не ограничено.${plain}" >&2
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
    total="$(_supersweep_count_list "$selected")"
    echo -e "Из базового набора выбрано ${green}${total}${plain}: ${green}${selected}${plain}" >&2
    printf '%s\n' "$selected"
}

supersweep_ask_own_domains() {
    # Дополнить $1 своими доменами; неизвестные добавить в TCP_Custom для профиля 3.
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
    total="$(_supersweep_count_list "$selected")"
    echo -e "Всего доменов РКН в прогоне: ${green}${total}${plain}" >&2
    echo -e "${green}${selected}${plain}" >&2
    printf '%s\n' "$selected"
}

# stdout carries only the answer; 0 cancels, EOF uses the default.
_supersweep_ask_pause() {
    local minimum="$1" default="$2" prompt="$3" label="$4" pause
    while true; do
        read -re -p "$prompt" pause || pause=""
        [ "$pause" = "0" ] && return 0
        [ -n "$pause" ] || pause="$default"
        case "$pause" in
            *[!0-9]*)
                echo -e "${yellow}Неверный ввод: нужно число секунд (минимум ${minimum}).${plain}" >&2
                ;;
            *)
                if [ "$pause" -lt "$minimum" ]; then
                    echo -e "${yellow}Пауза${label} не может быть меньше ${minimum} секунд (введено ${pause}).${plain}" >&2
                else
                    echo "$pause"
                    return 0
                fi
                ;;
        esac
    done
}

supersweep_ask_pause() {
    _supersweep_ask_pause 5 5 "Пауза YouTube/Googlevideo между стратегиями. Минимум 5 сек (Enter - 5 сек, 0 - отмена): " ""
}

supersweep_ask_ds_pause() {
    _supersweep_ask_pause 15 15 "Пауза Discord между стратегиями. Минимум 15 сек (Enter - 15 сек, 0 - отмена): " " Discord"
}

supersweep_ask_rkn_pause() {
    _supersweep_ask_pause 30 60 "Пауза РКН между попытками. Минимум 30 сек, минута - максимально щадяще (Enter - 60 сек, 0 - отмена): " " РКН"
}

supersweep_menu() {
    local cfg domains tls_pref pause ds_pause rkn_pause answer ss_run_rc=0
    cfg="$(config_get_file 2>/dev/null)" || cfg=""
    menu_config_snapshot "$cfg" 2>/dev/null || true
    if [ "${MENU_AUTO_MODE:-}" = "включен" ]; then
        echo -e "${yellow}Суперавтопрогон недоступен при включённой авторотации TCP/HTTP.${plain}"
        echo -e "Выключите авторотацию (п.11 этого подменю) и повторите."
        pause_enter || true
        return 0
    fi
    if ! zapret2_running; then
        echo -e "${yellow}zapret2 не запущен — проверки бессмысленны.${plain}"
        echo -e "Запустите zapret2 (п.2 главного меню) и повторите."
        pause_enter || true
        return 0
    fi

    clear -x
    echo -e "${cyan}--- Суперавтопрогон ---${plain}"
    echo "Одним запуском: подбор стратегий по фазам — YouTube (профиль 1),"
    echo "затем Googlevideo (профиль 2), затем Discord (профиль 4), затем РКН"
    echo "(профиль 3) по одному домену за раз. Между фазами и доменами —"
    echo "паузы: частые параллельные переключения триггерят ТСПУ."
    echo "Лучшие стратегии применяются автоматически сразу по завершении"
    echo "воркера/домена; РКН получает персональные строки доменов и профильную"
    echo "стратегию максимума покрытия."
    echo "Базовый набор РКН автора — xhamster.com, anidub.com, amnezia.org"
    echo "(meduza.io и так стоит дефолтом у ручного подбора профиля 3); свои"
    echo "домены дописываются без ограничений. Если обе версии TLS отвечают"
    echo "зелёным, следующая проверка идёт уже через 5 секунд."
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

    local ndom="$(_supersweep_count_list "$domains")"
    local max1 max2 max4 max3 est_total
    max1="$(config_profile_max_strategy 1 "$cfg")"
    printf '%s' "$max1" | grep -Eq '^[1-9][0-9]*$' || max1=43
    max2="$(config_profile_max_strategy 2 "$cfg")"
    printf '%s' "$max2" | grep -Eq '^[1-9][0-9]*$' || max2=43
    max4="$(config_profile_max_strategy 4 "$cfg")"
    printf '%s' "$max4" | grep -Eq '^[1-9][0-9]*$' || max4=43
    max3="$(config_profile_max_strategy 3 "$cfg")"
    printf '%s' "$max3" | grep -Eq '^[1-9][0-9]*$' || max3=43
    est_total="$(_supersweep_estimate_total "$max1" "$max2" "$max4" "$max3" "$ndom" "$pause" "$ds_pause" "$rkn_pause")"

    echo ""
    echo -e "Домены РКН в прогоне (${ndom}):"
    echo -e "${green}$(printf '%s\n' $domains | tr '\n' ' ' | sed 's/ $//')${plain}"
    echo -e "РКН: ${ndom} домен(ов) по одному, полный проход стратегий на каждый, пауза РКН ${rkn_pause} сек."
    echo ""
    echo -e "Прогон займёт ориентировочно до $(( (est_total + 59) / 60 )) мин. Во время прогона"
    echo -e "интернет может подтормаживать (стратегии переключаются на лету)."
    # Ctrl+C на старте отменяет диалог, а не скрипт.
    answer=""
    read -re -p "Enter - старт, 0 - отмена: " answer || answer="0"
    [ "$answer" = "0" ] && { echo "Отмена."; return 0; }

    # DNS-gate всегда по эталону rutracker.org, а не пользовательскому домену.
    # Только подтверждённый спуф останавливает; тихий DNS/недоступный DoH — предупреждение.
    gate_rc=0
    z2r_dns_spoof_gate "${Z2R_DNS_REF_DOMAIN:-rutracker.org}" || gate_rc=$?
    if [ "$gate_rc" = 2 ]; then
        pause_enter || true
        return 0
    fi

    # Обработать rc=1 отмены, чтобы глобальный set -e не закрыл меню.
    ss_run_rc=0
    supersweep_run "$tls_pref" "$pause" "$ds_pause" "$rkn_pause" 1 $domains || ss_run_rc=$?
    # Повторный Ctrl+C в сводке/паузе игнорируем; затем вернуть обычный INT.
    trap ':' INT
    pause_enter || true
    trap - INT
    return 0
}
