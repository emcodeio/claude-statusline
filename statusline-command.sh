#!/usr/bin/env bash
# Claude Code status line — three rows:
#   1  model · effort │ ⎇ git │ agent │ ctx gauge │ account
#   2  5h gauge + pace projection │ 7d gauge + daily-allowance projection
#      │ per-model weekly gauge(s), via a background-refreshed OAuth cache
#   3  cost (+ extra-usage spend) │ cache │ last seen │ cwd │ session name
#
# settings.json invokes this via `sh`, so it is written to POSIX shell:
# no arrays, no [[ ]], no $'...'. Escapes are built with printf instead.
#
# This redraws constantly, so subprocess count is the performance budget:
# every helper collapses its work into a single awk, git state comes from one
# combined call, and `rep`/`date` avoid re-forking. ~13 spawns per render.
#
# The month-to-date spend figure is Anthropic's own extra-usage meter, read
# from the same OAuth cache that feeds the model-scoped gauge — the number the
# console shows, not a local estimate. It replaces a client-side ledger that
# accumulated `total_cost_usd` deltas behind an inferred billing gate; that
# ledger read ~2.6x high, for two independent reasons. It priced every token
# at list API rates and booked 100% of a session's cost as overflow whenever
# any cap was exhausted, which is a different quantity than credits consumed.
# And its negative-delta clamp double-counted: when total_cost_usd dipped (a
# resumed session re-reporting from a lower baseline) the delta was floored at
# zero but `accum` was kept *and* `last_cost` rewritten downward, so the climb
# back was counted twice. That is observable in the old state files as an
# `accum` larger than the session's own `last_cost`, which a sum of
# non-negative deltas cannot produce.
#
#   budget <n>   set the budget denominator (blank = no denominator shown)
#
# Testing hook: CLAUDE_SL_NOW overrides "now" so the preview harness can
# render deterministic pace projections.
#
# CLAUDE_SL_NO_ACCOUNT=1 hides the account label (screen shares, recordings).

set -f

usage_dir="${CLAUDE_USAGE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/usage}"
config="$usage_dir/.config"          # standing settings (budget)

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
        # Both existed to re-anchor a local estimate against a real console
        # figure. The spend figure now *is* the console figure, so there is
        # nothing to reconcile — and a stale manual anchor would only be able
        # to make it wrong again.
        cat >&2 <<'MSG'
`usage` and `sync` are gone: the spend figure is read from Anthropic's own
extra-usage meter (spend.used in the OAuth usage cache), so there is no local
estimate left to re-anchor. Use `budget <n>` to set the denominator.
MSG
        exit 1
        ;;
esac

input=$(cat)
[ -z "$input" ] && { printf 'Claude'; exit 0; }

if [ -n "${CLAUDE_SL_NOW:-}" ]; then
    now=$CLAUDE_SL_NOW
else
    now=$(date +%s)
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

# ===== Model-specific weekly window (OAuth usage API) =====
# The payload carries only the two shared windows; per-model weekly caps (the
# "Fable" row on the claude.ai usage page) exist only behind the OAuth usage
# endpoint. Renders happen every few seconds, so the network never sits on the
# render path: when the stamp outlives its TTL the render advances it and hands
# the fetch to a detached job, then draws from whatever the cache already
# holds. The stamp moves even when the fetch fails, so a dead endpoint or a
# denied keychain costs one attempt per TTL, not one per render. Inert under
# CLAUDE_SL_NOW (previews must not hit the network against a synthetic clock)
# and under CLAUDE_SL_NO_OAUTH=1 (kill switch). Costs ~3 extra spawns a render.
oauth_cache="$usage_dir/.oauth_usage.json"
oauth_stamp="$usage_dir/.oauth_usage.ts"

# mtime, validated — same BSD-then-GNU probe the transcript segment uses.
mtime_of() {
    _mt=$(stat -f %m "$1" 2>/dev/null)
    case "$_mt" in ''|*[!0-9]*) _mt=$(stat -c %Y "$1" 2>/dev/null) ;; esac
    case "$_mt" in ''|*[!0-9]*) _mt='' ;; esac
    printf '%s' "$_mt"
}

mw=''
spend=''
if [ -z "${CLAUDE_SL_NO_OAUTH:-}" ]; then
    if [ -z "${CLAUDE_SL_NOW:-}" ]; then
        # 5-minute TTL: the endpoint 429s eagerly (anthropics/claude-code
        # #31021), and weekly windows move too slowly to justify pushing it.
        _st=$(mtime_of "$oauth_stamp")
        if [ -z "$_st" ] || [ $((now - _st)) -ge 300 ]; then
            mkdir -p "$usage_dir"
            : > "$oauth_stamp"
            # Detached, every fd closed: Claude Code reads our stdout to EOF,
            # so an inherited pipe would stall the redraw for the whole fetch.
            (
                # Token sources in order: credentials file (silent), keychain
                # by account name, then any keychain item (may pop a one-time
                # consent dialog — "Always Allow" ends them). The -a lookup
                # comes first because the service name alone is ambiguous:
                # old Claude Code versions leave a fossil item on the same
                # service (acct "Claude Code"), and the bare -s lookup returns
                # that one, shadowing the live item keyed by the login name.
                # Every source passes the same expiry gate — the endpoint
                # rate-limits eagerly, so a request that a local timestamp
                # already condemns is a request we cannot afford to burn.
                _cred="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
                # expiresAt is an epoch in ms (tolerate seconds).
                _live='.claudeAiOauth
                    | select(((.expiresAt // 0)
                              | if . > 1e12 then . / 1000 else . end) > $n + 60)
                    | .accessToken // empty'
                for _src in file keychain-user keychain-any; do
                    case "$_src" in
                        file)
                            [ -f "$_cred" ] || continue
                            tok=$(jq -r --argjson n "$now" "$_live" "$_cred" 2>/dev/null)
                            ;;
                        keychain-user)
                            tok=$(security find-generic-password -s 'Claude Code-credentials' \
                                    -a "${USER:-$LOGNAME}" -w 2>/dev/null \
                                | jq -r --argjson n "$now" "$_live" 2>/dev/null)
                            ;;
                        keychain-any)
                            tok=$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null \
                                | jq -r --argjson n "$now" "$_live" 2>/dev/null)
                            ;;
                    esac
                    [ -z "$tok" ] && continue
                    _resp=$(curl -sS --max-time 8 https://api.anthropic.com/api/oauth/usage \
                        -H "Authorization: Bearer $tok" \
                        -H 'anthropic-beta: oauth-2025-04-20' 2>/dev/null)
                    [ -z "$_resp" ] && continue
                    # .raw always lands (debuggability); the cache only accepts
                    # a body that looks like usage data, so an error envelope
                    # cannot clobber the last good figures. Any response ends
                    # the loop: an error body here means a 429 or a revoked
                    # grant, and the next source usually resolves to the same
                    # token — retrying it would burn requests this endpoint
                    # can't spare. One HTTP attempt per interval, literally.
                    printf '%s' "$_resp" > "$oauth_cache.raw"
                    printf '%s' "$_resp" | jq -e 'has("limits") or has("five_hour") or has("seven_day")' >/dev/null 2>&1 \
                        && printf '%s' "$_resp" > "$oauth_cache"
                    break
                done
            ) </dev/null >/dev/null 2>&1 &
        fi
    fi
    if [ -f "$oauth_cache" ]; then
        _cmt=$(mtime_of "$oauth_cache")
        # An hour-old figure is a lie with a gauge on it — hide, don't guess.
        # Under the test clock mtimes are meaningless; previews trust the file.
        if [ -n "${CLAUDE_SL_NOW:-}" ] || { [ -n "$_cmt" ] && [ $((now - _cmt)) -lt 3600 ]; }; then
            # "label|pct|reset" per window — pipes, not tabs: consecutive tabs
            # collapse under IFS splitting, pipes keep empty fields addressable.
            # The canonical source is the limits[] array: model-scoped weekly
            # caps arrive as kind "weekly_scoped" with the model under .scope
            # (the top-level seven_day_<model> keys are null fossils on current
            # accounts). The key scan stays as a fallback for older shapes.
            mw=$(jq -r '
                def ep:
                    if type == "number" then floor
                    elif type == "string" then
                        (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | (try fromdateiso8601 catch ""))
                    else "" end;
                def cap: (.[0:1] | ascii_upcase) + .[1:];
                [ (.limits // [])[]
                  | select(.kind == "weekly_scoped" and .percent != null)
                  | ((.scope.model.display_name // .scope.surface // "scoped") | tostring | cap) + "|"
                      + (.percent | tostring) + "|"
                      + ((.resets_at | ep) | tostring)
                ] as $scoped
                | if ($scoped | length) > 0 then $scoped[]
                  else
                    to_entries[]
                    | select((.key | test("^seven_day_(opus|sonnet|haiku|fable|mythos)")) and ((.value | type) == "object"))
                    | (.key | sub("^seven_day_"; "")) as $m
                    | ($m | cap) + "|"
                        + ((.value.utilization // .value.used_percentage // "") | tostring) + "|"
                        + ((.value.resets_at | ep) | tostring)
                  end
            ' "$oauth_cache" 2>/dev/null)

            # Month-to-date extra-usage spend — Anthropic's own meter, and the
            # figure the console shows. Read as minor units + exponent so no
            # float parsing is involved: 48080 at exponent 2 is $480.80. The
            # older `extra_usage.used_credits` / `decimal_places` pair carries
            # the same number and is kept as a fallback for earlier shapes.
            # Absent on accounts with no extra usage enabled, in which case
            # both branches yield nothing and the figure stays hidden.
            spend=$(jq -r '
                def money($v; $exp):
                    if ($v | type) == "number"
                    then (($v / pow(10; $exp)) | tostring)
                    else empty end;
                (.spend.used | select(. != null)
                    | money(.amount_minor; (.exponent // 2)))
                // (.extra_usage | select(. != null)
                    | money(.used_credits; (.decimal_places // 2)))
                // empty
            ' "$oauth_cache" 2>/dev/null)
        fi
    fi
fi

mw_gate=0
mw_segs=''
if [ -n "$mw" ]; then
    while IFS='|' read -r _lbl _pct _rst; do
        case "$_pct" in ''|*[!0-9.]*) continue ;; esac
        case "$_lbl" in
            Opus*)   _mcol=$c_opus ;;
            Haiku*)  _mcol=$c_haiku ;;
            Sonnet*) _mcol=$c_sonnet ;;
            *)       _mcol=$c_fable ;;
        esac
        _s="${_mcol}${_lbl}${rst} $(mkbar "$_pct")"
        _s="$_s$(pace_7d "$_pct" "$_rst")"
        [ -n "$_rst" ] && [ "$_rst" -gt "$now" ] 2>/dev/null && \
            _s="$_s ${dim}↻$(fmt_day "$_rst")${rst}"
        if [ -z "$mw_segs" ]; then mw_segs=$_s; else mw_segs="$mw_segs
$_s"; fi
        # A model window only opens the billing gate when it caps the model
        # actually in use — Opus at 100% does not gate a Sonnet session.
        case "$model" in
            *"$_lbl"*) [ "$(awk -v p="$_pct" 'BEGIN { print (p >= 100) }')" = 1 ] && mw_gate=1 ;;
        esac
    done <<EOF
$mw
EOF
fi

# ===== Cap-exhaustion indicator =====
# Read straight off the payload's rate-limit percentages: a fact about *now*,
# not an inference about billing. It drives the 🤑 glyph only — the dollar
# figure beside it comes from Anthropic's meter (see `spend`, above), so
# nothing here attributes cost to a window. Keeping the two separate is the
# point: exhaustion is knowable locally, spend is not.
gate=0
if [ -n "$five" ] || [ -n "$seven" ]; then
    gate=$(awk -v f="${five:-0}" -v s="${seven:-0}" 'BEGIN { print (f >= 100 || s >= 100) ? 1 : 0 }')
fi
# A model-scoped window counts only when it caps the model actually in use.
[ "$mw_gate" = 1 ] && gate=1

# Optional denominator on the spend figure ($480.80/200), set via `budget`.
budget=''
# shellcheck disable=SC1090
[ -f "$config" ] && . "$config" 2>/dev/null

# ===== Account =====
# The payload doesn't say who is logged in; Claude Code's own config does, as
# oauthAccount.emailAddress in .claude.json (inside CLAUDE_CONFIG_DIR when set,
# else $HOME). That file is ~200 KB and rewritten often, so the label is cached
# as two lines — source path, then label — and rebuilt only when the source is
# not strictly older than the cache. The usual render is a `read` and a `-nt`
# test, both builtins: no spawn. The source path guards a CLAUDE_USAGE_DIR
# shared across config dirs, where one account's cache would otherwise label
# another's session. Absent oauthAccount (API key, Bedrock, Vertex) hides it.
acct=''
if [ -z "${CLAUDE_SL_NO_ACCOUNT:-}" ]; then
    acct_src="${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}"
    acct_src="${acct_src:-$HOME/.claude.json}"
    # Synthetic-clock renders (previews, the README screenshot) read only a
    # config dir handed to them, never the real home file — a regenerated
    # screenshot must not publish whoever ran it.
    [ -n "${CLAUDE_SL_NOW:-}" ] && [ -z "${CLAUDE_CONFIG_DIR:-}" ] && acct_src=''
    acct_cache="$usage_dir/.account"
    if [ -n "$acct_src" ] && [ -f "$acct_src" ]; then
        _asrc=''
        [ -f "$acct_cache" ] && { IFS= read -r _asrc; IFS= read -r acct; } < "$acct_cache"
        if [ "$_asrc" != "$acct_src" ] || ! [ "$acct_cache" -nt "$acct_src" ]; then
            # Control characters stripped: the label goes straight to a terminal.
            acct=$(jq -r '.oauthAccount.emailAddress // empty | gsub("[[:cntrl:]]"; "")' \
                "$acct_src" 2>/dev/null)
            acct=${acct%%@*}
            [ -d "$usage_dir" ] || mkdir -p "$usage_dir"
            printf '%s\n%s\n' "$acct_src" "$acct" > "$acct_cache" 2>/dev/null
        fi
    fi
    if [ ${#acct} -gt 20 ]; then
        acct="$(printf '%.19s' "$acct")…"
    fi
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
[ -n "$acct" ] && add "${dim}${acct}${rst}"

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
if [ -n "$mw_segs" ]; then
    while IFS= read -r _line; do
        [ -n "$_line" ] && add2 "$_line"
    done <<EOF
$mw_segs
EOF
fi

# ===== Line 3: session vitals =====
l3=''
if [ -n "$cost" ]; then
    # Session cost stays green in every state — it is informational, not an
    # alarm. The spend figure (always red) and 🤑 carry the billing signal,
    # and the contrast makes the two figures readable at a glance.
    s=$(printf '%s$%.2f%s' "$c_good" "$cost" "$rst")
    # Hidden at zero (or absent, when the cache is stale/unreachable or the
    # account has no extra usage) — an empty meter is not news. Matched as a
    # string so the common case costs no extra spawn.
    case "$spend" in
        ''|0|0.0|0.00|0.000) ;;
        *)
            s="$s ${dim}·${rst}$(printf '%s$%.2f%s' "$c_alert" "$spend" "$rst")"
            [ -n "$budget" ] && s="$s${dim}/${budget}${rst}"
            ;;
    esac
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
