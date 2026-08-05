#!/usr/bin/env bash
# Renders statusline-command.sh against synthetic payloads so every state can be
# eyeballed without waiting for the real conditions to occur.
#
#   bash ~/.claude/statusline-preview.sh          # all states
#   bash ~/.claude/statusline-preview.sh spend    # spend assertions only
#
# The usage dir is redirected to a scratch dir — previewing never touches
# ~/.claude/usage.

SL="${SL:-$HOME/.claude/statusline-command.sh}"
NOW=1785340000                       # fixed clock → deterministic projections
export CLAUDE_SL_NOW=$NOW

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
export CLAUDE_USAGE_DIR="$SCRATCH/usage"

# Two throwaway repos for the git-segment contrast cases: one with a clean
# working tree, one dirty. Both are built here so the harness is hermetic —
# it needs no particular repo to exist on the machine running it.
CLEAN_REPO="$SCRATCH/clean-repo"
mkdir -p "$CLEAN_REPO"
git -C "$CLEAN_REPO" init -q 2>/dev/null
git -C "$CLEAN_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null

DIRTY_REPO="$SCRATCH/dirty-repo"
mkdir -p "$DIRTY_REPO"
git -C "$DIRTY_REPO" init -q 2>/dev/null
git -C "$DIRTY_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
printf 'tracked\n' > "$DIRTY_REPO/tracked.txt"
git -C "$DIRTY_REPO" add tracked.txt 2>/dev/null
git -C "$DIRTY_REPO" -c user.email=t@t -c user.name=t commit -q -m add 2>/dev/null
printf 'modified\n' >> "$DIRTY_REPO/tracked.txt"      # ~1 modified
: > "$DIRTY_REPO/untracked-a.txt"                      # ?2 untracked
: > "$DIRTY_REPO/untracked-b.txt"

FIVE_R=$((NOW + 7800))               # 2h10m left of 5h  → 2h50m elapsed
FIVE_EARLY=$((NOW + 17900))          # 100s into the window
SEVEN_R=$((NOW + 259200))            # 3d left of 7d     → 4d elapsed

show() {
    printf '\n\033[1m── %s\033[0m\n' "$1"
    shift
    # Fresh usage dir per state, so a planted cache never bleeds into the next.
    rm -rf "$CLAUDE_USAGE_DIR"
    printf '%s' "$1" | sh "$SL"
}

# $1 model  $2 effort  $3 ctx  $4 five  $5 five_resets  $6 seven  $7 seven_resets
# $8 cost   $9 cwd     $10 cache_read  $11 cache_create
payload() {
    jq -nc \
        --arg m "$1" --arg ef "$2" --arg cwd "$9" \
        --argjson ctx "${3:-null}" \
        --argjson f "${4:-null}" --argjson fr "${5:-null}" \
        --argjson s "${6:-null}" --argjson sr "${7:-null}" \
        --argjson c "${8:-null}" \
        --argjson cr "${10:-0}" --argjson cc "${11:-0}" \
        --arg sid "${SID:-preview-session}" \
        '{
            model: { display_name: $m },
            effort: (if $ef == "" then null else { level: $ef } end),
            session_id: $sid,
            session_name: "Refactor the auth module",
            workspace: { current_dir: $cwd },
            context_window: (if $ctx == null then null else {
                used_percentage: $ctx,
                current_usage: { cache_read_input_tokens: $cr, cache_creation_input_tokens: $cc }
            } end),
            cost: (if $c == null then null else { total_cost_usd: $c } end),
            rate_limits: (
                (if $f == null then {} else { five_hour: { used_percentage: $f, resets_at: $fr } } end)
                + (if $s == null then {} else { seven_day: { used_percentage: $s, resets_at: $sr } } end)
            )
        } | del(..|nulls)'
}

if [ "${1:-}" != spend ]; then
    show "1  Fresh session — no rate_limits, no cost" \
        "$(payload 'Opus 5 (1M context)' xhigh 3 '' '' '' '' '' "$DIRTY_REPO" 0 0)"

    show "2  Baseline — real captured payload (75% / 55%)" \
        "$(payload 'Opus 5 (1M context)' xhigh 10 75 $FIVE_R 55 $SEVEN_R 0.96 "$DIRTY_REPO" 92495 385)"

    show "3  5h over-pace — ↑ plus exhaustion clock" \
        "$(payload 'Opus 5 (1M context)' high 42 75 $FIVE_R 30 $SEVEN_R 2.10 "$DIRTY_REPO" 90000 9000)"

    show "4  5h under-pace — ↓, exhaustion clock suppressed" \
        "$(payload 'Sonnet 5' medium 22 20 $FIVE_R 20 $SEVEN_R 0.40 "$DIRTY_REPO" 50000 50000)"

    show "5  5h at 100s elapsed — early-window guard, no arrow" \
        "$(payload 'Opus 5 (1M context)' xhigh 5 4 $FIVE_EARLY 55 $SEVEN_R 0.12 "$DIRTY_REPO" 5000 5000)"

    show "6  7d over-pace — ↑ with exhaustion day" \
        "$(payload 'Opus 5 (1M context)' xhigh 61 40 $FIVE_R 75 $SEVEN_R 3.40 "$DIRTY_REPO" 80000 20000)"

    show "7  5h at 100% — 🤑 on the gauge, cost red" \
        "$(payload 'Opus 5 (1M context)' xhigh 71 100 $FIVE_R 62 $SEVEN_R 4.12 "$DIRTY_REPO" 95000 5000)"

    show "9  Zero usage — no divide-by-zero" \
        "$(payload 'Opus 5 (1M context)' low 0 0 $FIVE_R 0 $SEVEN_R 0 "$DIRTY_REPO" 0 0)"

    show "10a Clean repo — ✓" \
        "$(payload 'Opus 5 (1M context)' xhigh 10 75 $FIVE_R 55 $SEVEN_R 0.96 "$CLEAN_REPO" 92495 385)"

    show "10b Dirty repo — ~1 modified, ?2 untracked" \
        "$(payload 'Opus 5 (1M context)' xhigh 10 75 $FIVE_R 55 $SEVEN_R 0.96 "$DIRTY_REPO" 92495 385)"

    show "11  Fable + max effort — crimson vs alert red side by side" \
        "$(payload 'Fable 5' max 88 92 $FIVE_R 55 $SEVEN_R 1.50 "$CLEAN_REPO" 92495 385)"

    # 12: model-specific weekly window, drawn from a planted OAuth cache. show()
    # wipes the usage dir, so these plant the cache and invoke the script raw.
    # Under CLAUDE_SL_NOW the fetch is inert and cache mtime is ignored — the
    # planted file is trusted as-is, keeping the preview offline-deterministic.
    # 12a/12b use the live API shape (limits[] with fractional +00:00 stamps),
    # 12c the legacy top-level seven_day_<model> keys the parser falls back to.
    ISO_R=$(date -u -d "@$SEVEN_R" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
            || date -u -r "$SEVEN_R" +%Y-%m-%dT%H:%M:%S)
    ISO_R="$ISO_R.715791+00:00"

    printf '\n\033[1m── %s\033[0m\n' "12a Fable weekly window — third gauge from limits[]"
    rm -rf "$CLAUDE_USAGE_DIR"; mkdir -p "$CLAUDE_USAGE_DIR"
    printf '{"limits":[{"kind":"session","group":"session","percent":41},{"kind":"weekly_all","group":"weekly","percent":28},{"kind":"weekly_scoped","group":"weekly","percent":62,"resets_at":"%s","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true}]}' \
        "$ISO_R" > "$CLAUDE_USAGE_DIR/.oauth_usage.json"
    payload 'Fable 5' xhigh 34 41 $FIVE_R 28 $SEVEN_R 0.85 "$CLEAN_REPO" 92495 385 | sh "$SL"

    printf '\n\033[1m── %s\033[0m\n' "12b Fable capped, Opus idle — gate follows the model in use"
    rm -rf "$CLAUDE_USAGE_DIR"; mkdir -p "$CLAUDE_USAGE_DIR"
    printf '{"limits":[{"kind":"weekly_scoped","group":"weekly","percent":100,"resets_at":"%s","scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_scoped","group":"weekly","percent":12,"resets_at":"%s","scope":{"model":{"display_name":"Opus"}}}]}' \
        "$ISO_R" "$ISO_R" > "$CLAUDE_USAGE_DIR/.oauth_usage.json"
    payload 'Fable 5' xhigh 34 41 $FIVE_R 62 $SEVEN_R 1.20 "$CLEAN_REPO" 92495 385 | sh "$SL"

    printf '\n\033[1m── %s\033[0m\n' "12c Legacy shape — top-level seven_day_opus, epoch reset"
    rm -rf "$CLAUDE_USAGE_DIR"; mkdir -p "$CLAUDE_USAGE_DIR"
    printf '{"seven_day_opus":{"utilization":62,"resets_at":%s}}' "$SEVEN_R" \
        > "$CLAUDE_USAGE_DIR/.oauth_usage.json"
    payload 'Opus 5 (1M context)' xhigh 34 41 $FIVE_R 28 $SEVEN_R 0.85 "$CLEAN_REPO" 92495 385 | sh "$SL"

    printf '\n'
fi

# ---- Spend figure: read from Anthropic's meter, never derived locally ----
# These are assertions, not eyeball states: each one names an expected value
# and reports PASS/FAIL, because the claim being tested is a number's
# provenance rather than its appearance.
printf '\n\033[1m══ Spend figure (authoritative meter)\033[0m\n'
FAILED=0

plant() { rm -rf "$CLAUDE_USAGE_DIR"; mkdir -p "$CLAUDE_USAGE_DIR"
          [ -n "$1" ] && printf '%s' "$1" > "$CLAUDE_USAGE_DIR/.oauth_usage.json"; }

# Row 3 joins its segments with │; the middle dot appears only between the
# session cost and the spend figure, so it is an unambiguous anchor. Tolerate
# whitespace around it rather than pinning the exact spacing — this asserts
# which number is shown, not how it is padded.
spend_of() {
    printf '%s' "$1" | sh "$SL" \
        | awk '{ gsub(/\033\[[0-9;]*m/, ""); print }' | tail -1 \
        | grep -o '·[[:space:]]*\$[0-9][0-9.]*' | head -1 \
        | sed 's/^·[[:space:]]*//'
}

expect() {   # $1 label  $2 expected ("-" = hidden)  $3 payload
    got=$(spend_of "$3"); got=${got:--}
    if [ "$got" = "$2" ]; then
        printf '  \033[32mPASS\033[0m  %-44s %s\n' "$1" "$got"
    else
        printf '  \033[31mFAIL\033[0m  %-44s got %s, want %s\n' "$1" "$got" "$2"
        FAILED=$((FAILED + 1))
    fi
}

CAPPED="$(payload 'Opus 5' xhigh 10 100 $FIVE_R 55 $SEVEN_R 12.14 "$DIRTY_REPO" 100 100)"
CALM="$(payload 'Opus 5' xhigh 10 40 $FIVE_R 55 $SEVEN_R 12.14 "$DIRTY_REPO" 100 100)"

plant '{"limits":[],"spend":{"used":{"amount_minor":48080,"currency":"USD","exponent":2}}}'
expect "spend.used minor units → \$480.80" '$480.80' "$CAPPED"

# The behavioural change: the figure is a monthly meter reading, not something
# earned by an open gate, so it must render with every cap well below 100.
expect "…and shows with all caps closed" '$480.80' "$CALM"

plant '{"limits":[],"extra_usage":{"used_credits":48080.0,"decimal_places":2}}'
expect "legacy extra_usage fallback" '$480.80' "$CAPPED"

plant '{"limits":[],"spend":{"used":{"amount_minor":0,"exponent":2}}}'
expect "zero meter → hidden" '-' "$CAPPED"

plant '{"limits":[]}'
expect "no spend field → hidden" '-' "$CAPPED"

plant ''
expect "no cache at all → hidden" '-' "$CAPPED"

# ---- Regression guards for the two bugs this replaced ----
# The old ledger summed total_cost_usd deltas behind an inferred gate. It grew
# on every render, and its negative-delta clamp re-counted the climb back after
# a dip (a resumed session re-reporting from a lower baseline), which is how a
# session's accum came to exceed its own last_cost. Both are now structurally
# impossible: the figure is a file read. Assert that, don't assume it.
printf '\n\033[1m══ Regression guards\033[0m\n'
plant '{"limits":[],"spend":{"used":{"amount_minor":48080,"exponent":2}}}'
SID=regression-test
seq_cost() {   # renders one payload at $1 cost, echoes the spend figure
    spend_of "$(SID=$SID payload 'Opus 5' xhigh 10 100 $FIVE_R 55 $SEVEN_R "$1" "$DIRTY_REPO" 100 100)"
}
PINNED=1
for c in 1.00 2.00 3.25 0 0.30 9.00; do
    v=$(seq_cost "$c")
    [ "$v" = '$480.80' ] || { PINNED=0; printf '  cost=%-6s → %s\n' "$c" "$v"; }
done
if [ "$PINNED" = 1 ]; then
    printf '  \033[32mPASS\033[0m  %-44s %s\n' \
        "pinned across rising cost and a dip to 0" '$480.80 ×6'
else
    printf '  \033[31mFAIL\033[0m  %s\n' "spend figure moved with total_cost_usd"
    FAILED=$((FAILED + 1))
fi

leftover=$(find "$CLAUDE_USAGE_DIR" -type f ! -name '.oauth_usage*' 2>/dev/null)
if [ -z "$leftover" ]; then
    printf '  \033[32mPASS\033[0m  %-44s %s\n' "no per-session state written" "clean"
else
    printf '  \033[31mFAIL\033[0m  %-44s %s\n' "per-session state written" "$leftover"
    FAILED=$((FAILED + 1))
fi

printf '\n'
[ "$FAILED" -eq 0 ] || { printf '\033[31m%s assertion(s) failed\033[0m\n\n' "$FAILED"; exit 1; }
