#!/usr/bin/env bash
# Claude Code status line — three rows:
#   1  model · effort │ ⎇ git │ agent │ ctx gauge
#   2  5h gauge + pace projection │ 7d gauge + daily-allowance projection
#   3  cost (+ API-overflow ledger) │ cache │ last seen │ cwd │ session name
#
# settings.json invokes this via `sh`, so it is written to POSIX shell:
# no arrays, no [[ ]], no $'...'. Escapes are built with printf instead.
#
# This redraws constantly, so subprocess count is the performance budget:
# every helper collapses its work into a single awk, git state comes from one
# combined call, and `rep`/`date` avoid re-forking. ~12 spawns per render.
#
# Reconcile subcommands — the overflow ledger is a client-side estimate, so
# these re-anchor it against a real figure from the Anthropic console:
#   budget <n>   set the budget denominator (blank = no denominator shown)
#   usage  <n>   overwrite initial_usage outright
#   sync   <n>   write negative per-session offsets, then re-anchor
#
# Testing hook: CLAUDE_SL_NOW overrides "now" so the preview harness can
# render deterministic pace projections.

set -f

usage_dir="${CLAUDE_USAGE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/usage}"
config="$usage_dir/.config"          # standing settings (budget) — not month-scoped

# BSD `date` takes -r, GNU takes -d @. Probe once, lazily, then reuse — the
# naive `date -r … || date -d @…` chain pays for a failed exec on every call.
_dmode=''
fmt_at() {
    [ -z "$1" ] && return
    if [ -z "$_dmode" ]; then
        if date -r 0 +%s >/dev/null 2>&1; then _dmode=bsd; else _dmode=gnu; fi
    fi
    if [ "$_dmode" = bsd ]; then
        date -r "$1" +"$2" 2>/dev/null
    else
        date -d "@$1" +"$2" 2>/dev/null
    fi
}

# The overflow ledger is scoped to a calendar month by writing into a
# YYYY-MM subdirectory: the summing glob then only ever sees the current
# month, with no timestamp filtering and no rollover job to forget.
# Past months stay on disk as history.
ym() { fmt_at "${1:-$(date +%s)}" '%Y-%m'; }

# Rewrite one key=value in a file. Deliberately NOT `sed -i` — this machine
# pairs BSD sed with GNU coreutils, and the two disagree on -i's syntax.
kv_set() {
    _f="$1"
    _k="$2"
    _v="$3"
    mkdir -p "${_f%/*}"
    [ -f "$_f" ] || : > "$_f"
    _tmp=$(mktemp "${_f}.XXXXXX") || return 1
    awk -F= -v k="$_k" -v v="$_v" '
        $1 == k { print k "=" v; seen = 1; next }
        { print }
        END { if (!seen) print k "=" v }
    ' "$_f" > "$_tmp" && mv "$_tmp" "$_f"
}

case "${1:-}" in
    budget)
        [ -z "${2:-}" ] && { echo "usage: $0 budget <amount>" >&2; exit 1; }
        kv_set "$config" budget "$2" && cat "$config"
        exit 0
        ;;
    usage|sync)
        [ -z "${2:-}" ] && { echo "usage: $0 $1 <amount>" >&2; exit 1; }
        # Anchoring is per-month because invoices are: the figure you read off
        # the console is this month's, so it belongs in this month's dir.
        _md="$usage_dir/$(ym)"
        if [ "$1" = sync ]; then
            # Cancel every session's accrued total with an equal negative
            # offset, then re-anchor. Live sessions keep accruing from here;
            # dead ones net to zero.
            mkdir -p "$_md"
            set +f
            for f in "$_md"/*; do
                [ -f "$f" ] || continue
                case "${f##*/}" in *_offset) continue ;; esac
                a=$(awk -F= '$1 == "accum" { print $2; exit }' "$f")
                [ -z "$a" ] && continue
                awk -v a="$a" 'BEGIN { printf "accum=%.6f\n", -a }' > "${f}_offset"
            done
            set -f
        fi
        kv_set "$_md/.anchor" initial_usage "$2"
        echo "$_md/.anchor:"; cat "$_md/.anchor"
        [ -f "$config" ] && { echo "$config:"; cat "$config"; }
        exit 0
        ;;
esac

input=$(cat)
[ -z "$input" ] && { printf 'Claude'; exit 0; }

# Epoch and YYYY-MM in one call — the ledger always wants both, and this is
# the hot path. Under the test override the month is derived via ym() instead,
# so a fixed CLAUDE_SL_NOW still lands in the right month directory.
if [ -n "${CLAUDE_SL_NOW:-}" ]; then
    now=$CLAUDE_SL_NOW
    _month=''
else
    # shellcheck disable=SC2046
    set -- $(date '+%s %Y-%m')
    now=$1
    _month=$2
fi

# ===== Palette (24-bit truecolor) =====
e=$(printf '\033')
c_opus="${e}[38;2;229;192;123m"    # amber
c_sonnet="${e}[38;2;97;175;239m"   # blue
c_haiku="${e}[38;2;86;182;194m"    # cyan
c_fable="${e}[38;2;224;108;117m"   # crimson — distinct from alert red
c_alert="${e}[38;2;235;87;87m"     # red    — reserved for danger thresholds
c_warn="${e}[38;2;255;176;85m"     # orange
c_pace="${e}[38;2;230;200;0m"      # yellow
c_good="${e}[38;2;80;200;120m"     # green
c_branch="${e}[38;2;198;120;221m"  # magenta
dim="${e}[2m"
rst="${e}[0m"
sep=" ${dim}│${rst} "

# ===== Helpers =====

# Sets REP rather than printing — a $(rep …) would fork a subshell per bar.
rep() {
    REP=''
    _i=0
    while [ "$_i" -lt "$1" ]; do
        REP="$REP$2"
        _i=$((_i + 1))
    done
}

fmt_clock() {                       # → "2:00PM"
    _x=$(fmt_at "$1" '%I:%M%p')
    printf '%s' "${_x#0}"
}

fmt_day() { fmt_at "$1" '%a'; }     # → "Sun"

fmt_daytime() {                     # → "Thu 3PM"
    _x=$(fmt_at "$1" '%a %I%p')
    case "$_x" in *' 0'*) _x="${_x%% 0*} ${_x#* 0}" ;; esac
    printf '%s' "$_x"
}

# Epoch → time-from-now as "1h53m" / "57m". Takes an absolute timestamp like
# the other formatters so pace_render can call it interchangeably, and does the
# subtraction here. Used for the 5h window, where the useful question is "how
# long have I got" — the 7d window keeps weekdays, because at week scale a
# duration forces the reverse conversion ("72h… so Saturday?").
# Spawns nothing, unlike the date-backed formatters.
fmt_dur() {
    _d=$(($1 - now))
    [ "$_d" -lt 0 ] && _d=0
    _m=$(((_d + 30) / 60))          # nearest minute
    if [ "$_m" -ge 1440 ]; then
        printf '%dd%dh' $((_m / 1440)) $(((_m % 1440) / 60))
    elif [ "$_m" -ge 60 ]; then
        printf '%dh%02dm' $((_m / 60)) $((_m % 60))
    else
        printf '%dm' "$_m"
    fi
}

# Sub-cell gauge: 10 cells × 8 eighths = 80 steps, so 1% moves the bar.
# $1 = percent, $2 = "ctx" to use the cool low-range color.
mkbar() {
    _p=$1
    _kind=${2:-}
    # Never hand a non-number to printf %f — it aborts the whole line.
    case "$_p" in ''|*[!0-9.]*) return ;; esac
    # One awk for fill, color tier, and rounding.
    # shellcheck disable=SC2046
    set -- $(awk -v p="$_p" 'BEGIN {
        v = int(p * 80 / 100 + 0.5); if (v > 80) v = 80; if (v < 0) v = 0
        printf "%d %d %.0f", v, (p >= 80) ? 3 : (p >= 50) ? 2 : 1, p
    }')
    _e=$1
    _tier=$2
    _pct=$3
    _full=$((_e / 8))
    case $((_e % 8)) in
        1) _part='▏' ;; 2) _part='▎' ;; 3) _part='▍' ;; 4) _part='▌' ;;
        5) _part='▋' ;; 6) _part='▊' ;; 7) _part='▉' ;; *) _part='' ;;
    esac
    _cells=$_full
    [ -n "$_part" ] && _cells=$((_full + 1))
    _track=$((10 - _cells))
    [ "$_track" -lt 0 ] && _track=0

    case "$_tier" in
        3) _col=$c_alert ;;
        2) _col=$c_warn ;;
        *) if [ "$_kind" = ctx ]; then _col=$c_haiku; else _col=$c_good; fi ;;
    esac

    rep "$_full" '█'; _bar=$REP
    rep "$_track" '░'; _trk=$REP
    printf '%s%s%s%s%s %s%s%%%s' "$_col" "$_bar" "$_part" "$dim" "$_trk" "$_col" "$_pct" "$rst"
}

# Shared tail for both pace functions: arrow, then a colored exhaustion time
# when one is meaningful. $1 verdict  $2 seconds-to-exhaustion  $3 seconds-to-reset
# $4 formatter fn. Prints nothing for cap/early, a bare ↓ when under pace.
pace_render() {
    case "$1" in
        cap|early|skip) return ;;
        under) printf ' %s' "${c_good}↓${rst}"; return ;;
        on)    _arrow="${c_pace}→${rst}" ;;
        *)     _arrow="${c_alert}↑${rst}" ;;
    esac
    # Exhaustion at or past the reset is not exhaustion — the window refills
    # first. A negative value means usage is zero and nothing can be projected.
    if [ "$2" -lt 0 ] || [ "$3" -le 0 ] || [ "$2" -ge "$3" ]; then
        printf ' %s' "$_arrow"
        return
    fi
    _ratio=$(($2 * 100 / $3))
    _col=$c_good
    [ "$_ratio" -lt 66 ] && _col=$c_warn
    [ "$_ratio" -lt 33 ] && _col=$c_alert
    printf ' %s%s%s%s' "$_arrow" "$_col" "$("$4" $((now + $2)))" "$rst"
}

# 5h pace. Linear projection is a fair model at session scale: a 5h window is
# roughly one work session, and burn is continuous while you are in it.
pace_5h() {
    [ -z "$1" ] || [ -z "$2" ] && return
    # shellcheck disable=SC2046
    set -- $(awk -v u="$1" -v r="$2" -v n="$now" 'BEGIN {
        w = 18000
        if (u >= 100)     { print "cap 0";   exit }   # 🤑 already says this
        el = n - (r - w)
        if (el <= w / 50) { print "early 0"; exit }   # first 2% is noise
        proj = u * w / el
        printf "%s %d", (proj > 115) ? "over" : (proj > 85) ? "on" : "under", \
               (u > 0) ? (100 - u) * el / u : -1
    }') "$2"
    pace_render "$1" "$2" "$(($3 - now))" fmt_dur
}

# 7d pace. NOT the 5h logic: wall-clock elapsed over a week counts nights and
# weekends, when burn is zero, so a linear projection is alarmist mid-week and
# falsely calm after a quiet stretch. Compare daily rates instead —
#   actual/day = used / days_elapsed   vs   allowance/day = (100-used)/days_left
pace_7d() {
    [ -z "$1" ] || [ -z "$2" ] && return
    # shellcheck disable=SC2046
    set -- $(awk -v u="$1" -v r="$2" -v n="$now" 'BEGIN {
        w = 604800
        if (u >= 100)     { print "cap 0";   exit }
        el = n - (r - w)
        if (el <= w / 50) { print "early 0"; exit }
        lf = r - n
        de = el / 86400; dl = lf / 86400
        if (de <= 0 || dl <= 0 || u <= 0) { print "skip 0"; exit }
        actual = u / de
        allow  = (100 - u) / dl
        printf "%s %d", (actual > allow * 1.15) ? "over" : \
                        (actual > allow * 0.85) ? "on" : "under", \
               ((100 - u) / actual) * 86400
    }') "$2"
    pace_render "$1" "$2" "$(($3 - now))" fmt_daytime
}

add()  { [ -z "$l1" ] && l1="$1" || l1="$l1$sep$1"; }
add2() { [ -z "$l2" ] && l2="$1" || l2="$l2$sep$1"; }
add3() { [ -z "$l3" ] && l3="$1" || l3="$l3$sep$1"; }

# ===== Extract (one jq pass — the reference script spends ~20 subprocesses here) =====
# Newline-delimited, NOT @tsv + word splitting: tab counts as IFS *whitespace*,
# so consecutive tabs collapse into one delimiter and any empty field silently
# shifts every field after it. Reading line by line preserves empties.
fields=$(printf '%s' "$input" | jq -r '
    def clean: if . == null then "" else (tostring | gsub("[\r\n\t]"; " ")) end;
    [
        .model.display_name,
        .effort.level,
        .agent.name,
        .context_window.used_percentage,
        .rate_limits.five_hour.used_percentage,
        .rate_limits.five_hour.resets_at,
        .rate_limits.seven_day.used_percentage,
        .rate_limits.seven_day.resets_at,
        .cost.total_cost_usd,
        .context_window.current_usage.cache_read_input_tokens,
        .context_window.current_usage.cache_creation_input_tokens,
        .session_id,
        .session_name,
        (.workspace.current_dir // .cwd),
        .transcript_path
    ] | map(clean) | .[]' 2>/dev/null)

model=''; effort=''; agent=''; ctx=''; five=''; five_r=''; seven=''; seven_r=''
cost=''; cache_r=''; cache_c=''; sess_id=''; sess_name=''; cwd=''; transcript=''
_n=0
# Heredoc (not a pipe) so the loop runs in this shell and the assignments stick.
while IFS= read -r _line; do
    _n=$((_n + 1))
    case $_n in
        1) model=$_line ;;      2) effort=$_line ;;     3) agent=$_line ;;
        4) ctx=$_line ;;        5) five=$_line ;;       6) five_r=$_line ;;
        7) seven=$_line ;;      8) seven_r=$_line ;;    9) cost=$_line ;;
        10) cache_r=$_line ;;   11) cache_c=$_line ;;   12) sess_id=$_line ;;
        13) sess_name=$_line ;; 14) cwd=$_line ;;       15) transcript=$_line ;;
    esac
done <<EOF
$fields
EOF

# "Claude Opus 5 (1M context)" → "Opus 5 (1M)"   (expansion, not a sed spawn)
model=${model#Claude }
case "$model" in
    *" context)") model="${model%" context)"})" ;;
    *" context")  model="${model%" context"}" ;;
esac

# ===== API-overflow gate + ledger =====
# Billing crosses over to the company API account when EITHER cap is hit, and
# nothing in the payload flags which requests were billed that way — so infer
# it from cap exhaustion and accumulate deltas locally.
gate=0
if [ -n "$five" ] || [ -n "$seven" ]; then
    gate=$(awk -v f="${five:-0}" -v s="${seven:-0}" 'BEGIN { print (f >= 100 || s >= 100) ? 1 : 0 }')
fi

period=''
budget=''
if [ -n "$sess_id" ] && [ -n "$cost" ]; then
    mdir="$usage_dir/${_month:-$(ym "$now")}"
    mkdir -p "$mdir"
    sess_file="$mdir/$sess_id"
    fresh=1
    prev_cost=$cost
    prev_accum=0
    if [ -f "$sess_file" ]; then
        fresh=0
        # shellcheck disable=SC2046
        set -- $(awk -F= '
            $1 == "last_cost" { c = $2 }
            $1 == "accum"     { a = $2 }
            END { printf "%s %s", (c == "" ? 0 : c), (a == "" ? 0 : a) }
        ' "$sess_file")
        prev_cost=$1
        prev_accum=$2
    else
        # A session that was already accruing last month carries its last_cost
        # forward, so the delta straddling midnight on the 1st is neither lost
        # nor double-counted. `accum` still starts at 0 — that is the point of
        # month scoping. On any other day this path resolves to the same
        # directory and finds nothing, so it costs one stat.
        _prev="$usage_dir/$(ym $((now - 86400)))/$sess_id"
        if [ -f "$_prev" ]; then
            _pc=$(awk -F= '$1 == "last_cost" { print $2; exit }' "$_prev")
            [ -n "$_pc" ] && prev_cost=$_pc
        fi
    fi
    # First sighting of a session baselines at the current total and accrues
    # nothing: we cannot know how much of an already-accumulated cost was spent
    # behind an open gate. Starting from 0 would book the whole session as
    # overflow the moment the script first runs while a cap happens to be hit.
    # A negative delta means /clear reset the counter — re-anchor, never subtract.
    new_accum=$(awk -v c="$cost" -v p="$prev_cost" -v a="$prev_accum" -v g="$gate" 'BEGIN {
        d = c - p; if (d < 0) d = 0
        if (g == 1) a = a + d
        printf "%.6f", a
    }')
    # Only touch the disk when something changed — or to lay down the baseline.
    if [ "$fresh" = 1 ] || [ "$cost" != "$prev_cost" ]; then
        printf 'last_cost=%s\naccum=%s\nts=%s\n' "$cost" "$new_accum" "$now" > "$sess_file"
    fi

    initial_usage=''
    # budget is standing; the anchor is this month's, matching how invoices arrive.
    # shellcheck disable=SC1090
    [ -f "$config" ] && . "$config" 2>/dev/null
    # shellcheck disable=SC1090
    [ -f "$mdir/.anchor" ] && . "$mdir/.anchor" 2>/dev/null
    set +f
    # Globbing the month dir IS the month filter. Dotfiles (.anchor) are
    # excluded by the glob, so they never land in the sum.
    period=$(awk -F= -v i="${initial_usage:-0}" '
        $1 == "accum" { s += $2 }
        END { printf "%.2f", s + i }
    ' "$mdir"/* 2>/dev/null)
    set -f
fi

# ===== Line 1: identity =====
l1=''
if [ -n "$model" ]; then
    case "$model" in
        *Opus*)  mcol=$c_opus ;;
        *Haiku*) mcol=$c_haiku ;;
        *Fable*) mcol=$c_fable ;;
        *)       mcol=$c_sonnet ;;
    esac
    seg="${mcol}${model}${rst}"
    if [ -n "$effort" ]; then
        case "$effort" in
            low)       ecol=$dim ;;
            medium)    ecol=$c_haiku ;;
            high)      ecol=$c_warn ;;
            xhigh|max) ecol=$c_alert ;;
            *)         ecol=$dim ;;
        esac
        seg="$seg ${dim}·${rst} ${ecol}${effort}${rst}"
    fi
    add "$seg"
fi

if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    # One git call for branch, upstream divergence, and file states — three
    # separate calls cost ~79ms against this vault, this one costs ~28ms.
    gs=$(git -C "$cwd" --no-optional-locks status --porcelain --branch 2>/dev/null)
    if [ -n "$gs" ]; then
        ginfo=$(printf '%s\n' "$gs" | awk '
            NR == 1 && /^## / {
                l = substr($0, 4)
                # A repo with no commits reports "## No commits yet on <branch>",
                # which would otherwise be used verbatim as the branch name.
                sub(/^No commits yet on /, "", l)
                if (match(l, /\[[^]]*\]/)) {
                    info = substr(l, RSTART, RLENGTH)
                    l = substr(l, 1, RSTART - 1)
                    if (match(info, /ahead [0-9]+/))
                        a = substr(info, RSTART + 6, RLENGTH - 6) + 0
                    if (match(info, /behind [0-9]+/))
                        b = substr(info, RSTART + 7, RLENGTH - 7) + 0
                }
                sub(/\.\.\..*/, "", l)
                sub(/[ \t]+$/, "", l)
                br = l
                next
            }
            /^[MADRC]/ { st++ }
            /^.[MD]/   { md++ }
            /^\?\?/    { un++ }
            END { printf "%s\n%d\n%d\n%d\n%d\n%d\n", br, a+0, b+0, st+0, md+0, un+0 }
        ')
        _n=0
        while IFS= read -r _line; do
            _n=$((_n + 1))
            case $_n in
                1) branch=$_line ;; 2) ahead=$_line ;;    3) behind=$_line ;;
                4) staged=$_line ;; 5) modified=$_line ;; 6) untracked=$_line ;;
            esac
        done <<EOF
$ginfo
EOF
        if [ -n "$branch" ]; then
            case "$branch" in *"(no branch)"*) branch='detached' ;; esac
            g="${dim}⎇${rst} ${c_branch}${branch}${rst}"
            if [ "$staged" = 0 ] && [ "$modified" = 0 ] && [ "$untracked" = 0 ]; then
                g="$g ${c_good}✓${rst}"
            else
                [ "$staged" -gt 0 ]    && g="$g ${c_good}+${staged}${rst}"
                [ "$modified" -gt 0 ]  && g="$g ${c_pace}~${modified}${rst}"
                [ "$untracked" -gt 0 ] && g="$g ${dim}?${untracked}${rst}"
            fi
            [ "$ahead" -gt 0 ]  && g="$g ${c_warn}⇡${ahead}${rst}"
            [ "$behind" -gt 0 ] && g="$g ${c_haiku}⇣${behind}${rst}"
            add "$g"
        fi
    fi
fi

[ -n "$agent" ] && add "${dim}agent:${rst}${c_haiku}${agent}${rst}"
[ -n "$ctx" ] && add "${dim}ctx${rst} $(mkbar "$ctx" ctx)"

# ===== Line 2: rate-limit windows =====
l2=''
if [ -n "$five" ]; then
    s="${dim}5h${rst} $(mkbar "$five")"
    [ "$gate" = 1 ] && s="$s 🤑"
    s="$s$(pace_5h "$five" "$five_r")"
    [ -n "$five_r" ] && [ "$five_r" -gt "$now" ] 2>/dev/null && \
        s="$s ${dim}↻$(fmt_dur "$five_r")${rst}"
    add2 "$s"
fi
if [ -n "$seven" ]; then
    s="${dim}7d${rst} $(mkbar "$seven")"
    s="$s$(pace_7d "$seven" "$seven_r")"
    [ -n "$seven_r" ] && [ "$seven_r" -gt "$now" ] 2>/dev/null && \
        s="$s ${dim}↻$(fmt_day "$seven_r")${rst}"
    add2 "$s"
fi

# ===== Line 3: session vitals =====
l3=''
if [ -n "$cost" ]; then
    # Session cost stays green in every state — it is informational, not an
    # alarm. The overflow figure (always red) and 🤑 carry the billing signal,
    # and the contrast makes the two figures readable at a glance.
    s=$(printf '%s$%.2f%s' "$c_good" "$cost" "$rst")
    # The ledger only accrues behind the gate, so hide it until it is earned.
    if [ -n "$period" ] && [ "$period" != "0.00" ]; then
        s="$s ${dim}·${rst}$(printf '%s$%.2f%s' "$c_alert" "$period" "$rst")"
        [ -n "$budget" ] && s="$s${dim}/${budget}${rst}"
    fi
    [ "$gate" = 1 ] && s="$s 🤑"
    add3 "$s"
fi

if [ -n "$cache_r" ] || [ -n "$cache_c" ]; then
    hit=$(awk -v r="${cache_r:-0}" -v c="${cache_c:-0}" 'BEGIN {
        t = r + c
        if (t <= 0) exit 1
        printf "%d", r * 100 / t
    }') && {
        if [ "$hit" -ge 80 ]; then
            hcol=$c_good
        elif [ "$hit" -ge 50 ]; then
            hcol=$c_haiku
        else
            hcol=$c_warn
        fi
        add3 "${dim}cache${rst} ${hcol}${hit}%${rst}"
    }
fi

if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    # Validate rather than trust the exit code: GNU `stat -f` means
    # --file-system, so it half-succeeds on BSD syntax and returns garbage
    # instead of failing over. Only a bare integer is a real mtime.
    lt=$(stat -f %m "$transcript" 2>/dev/null)
    case "$lt" in ''|*[!0-9]*) lt=$(stat -c %Y "$transcript" 2>/dev/null) ;; esac
    case "$lt" in ''|*[!0-9]*) lt='' ;; esac
    [ -n "$lt" ] && add3 "${dim}$(fmt_clock "$lt")${rst}"
fi

if [ -n "$cwd" ]; then
    case "$cwd" in
        "$HOME") disp='~' ;;
        "$HOME"/*)
            rest=${cwd#"$HOME"/}
            case "$rest" in
                */*) disp="~/…/${cwd##*/}" ;;
                *)   disp="~/$rest" ;;
            esac
            ;;
        *) disp="…/${cwd##*/}" ;;
    esac
    add3 "${dim}${disp}${rst}"
fi

if [ -n "$sess_name" ]; then
    if [ ${#sess_name} -gt 40 ]; then
        sess_name="$(printf '%.39s' "$sess_name")…"
    fi
    add3 "${dim}${sess_name}${rst}"
fi

printf '%s' "$l1"
[ -n "$l2" ] && printf '\n%s' "$l2"
[ -n "$l3" ] && printf '\n%s' "$l3"
printf '\n'
