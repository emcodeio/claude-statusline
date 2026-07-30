#!/usr/bin/env bash
# Renders statusline-command.sh against synthetic payloads so every state can be
# eyeballed without waiting for the real conditions to occur.
#
#   bash ~/.claude/statusline-preview.sh          # all states
#   bash ~/.claude/statusline-preview.sh ledger   # ledger sequence only
#
# The ledger is redirected to a scratch dir — previewing never touches
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
    # Fresh ledger per state, or spend from an earlier preview bleeds into later ones.
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

if [ "${1:-}" != ledger ]; then
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

    printf '\n'
fi

# ---- Ledger sequence: only spend behind an open gate may accumulate ----
printf '\n\033[1m══ Ledger correctness\033[0m\n'
rm -rf "$CLAUDE_USAGE_DIR"
SID=ledger-test
MONTH=$(date -d "@$NOW" +%Y-%m 2>/dev/null || date -r "$NOW" +%Y-%m)

step() {
    printf '%s' "$2" | sh "$SL" > /dev/null
    acc=$(awk -F= '$1=="accum"{printf "%.4f", $2}' "$CLAUDE_USAGE_DIR/$MONTH/$SID" 2>/dev/null)
    printf '  %-46s accum=%s\n' "$1" "${acc:-<none>}"
}

step "gate CLOSED, cost 1.00  → expect 0.0000" \
    "$(SID=$SID payload 'Opus 5' xhigh 10 40 $FIVE_R 55 $SEVEN_R 1.00 "$DIRTY_REPO" 100 100)"
step "gate CLOSED, cost 2.00  → expect 0.0000" \
    "$(SID=$SID payload 'Opus 5' xhigh 10 40 $FIVE_R 55 $SEVEN_R 2.00 "$DIRTY_REPO" 100 100)"
step "gate OPEN,   cost 2.50  → expect 0.5000" \
    "$(SID=$SID payload 'Opus 5' xhigh 10 100 $FIVE_R 55 $SEVEN_R 2.50 "$DIRTY_REPO" 100 100)"
step "gate OPEN,   cost 3.25  → expect 1.2500" \
    "$(SID=$SID payload 'Opus 5' xhigh 10 100 $FIVE_R 55 $SEVEN_R 3.25 "$DIRTY_REPO" 100 100)"
step "/clear resets cost to 0 → expect 1.2500 (re-anchor)" \
    "$(SID=$SID payload 'Opus 5' xhigh 10 100 $FIVE_R 55 $SEVEN_R 0 "$DIRTY_REPO" 100 100)"
step "gate OPEN,   cost 0.30  → expect 1.5500" \
    "$(SID=$SID payload 'Opus 5' xhigh 10 100 $FIVE_R 55 $SEVEN_R 0.30 "$DIRTY_REPO" 100 100)"
step "gate CLOSES, cost 9.00  → expect 1.5500 (frozen)" \
    "$(SID=$SID payload 'Opus 5' xhigh 10 40 $FIVE_R 55 $SEVEN_R 9.00 "$DIRTY_REPO" 100 100)"

# ---- Month rollover: the total must reset at the boundary without losing
#      the delta that straddles midnight, and without disturbing last month ----
printf '\n\033[1m══ Month rollover\033[0m\n'
rm -rf "$CLAUDE_USAGE_DIR"
SID=rollover-test
JUL=$(date -d '2026-07-31 23:59:00' +%s 2>/dev/null \
      || date -j -f '%Y-%m-%d %H:%M:%S' '2026-07-31 23:59:00' +%s)
AUG=$((JUL + 180))                                  # 00:02 on the 1st

roll() {   # $1 label  $2 epoch  $3 cost  $4 month-to-read
    CLAUDE_SL_NOW=$2 payload 'Opus 5' xhigh 10 100 $((2 + 18000)) '' '' "$3" "$DIRTY_REPO" 100 100 \
        | CLAUDE_SL_NOW=$2 sh "$SL" > /dev/null
    m=$(date -d "@$4" +%Y-%m 2>/dev/null || date -r "$4" +%Y-%m)
    acc=$(awk -F= '$1=="accum"{printf "%.4f", $2}' "$CLAUDE_USAGE_DIR/$m/$SID" 2>/dev/null)
    printf '  %-46s %s accum=%s\n' "$1" "$m" "${acc:-<none>}"
}

roll "Jul 31 23:59, cost 5.00 → expect 0.0000 (base)" "$JUL" 5.00 "$JUL"
roll "Jul 31 23:59, cost 6.00 → expect 1.0000"        "$JUL" 6.00 "$JUL"
roll "Aug 01 00:02, cost 6.50 → expect 0.5000 (new)"  "$AUG" 6.50 "$AUG"
roll "Aug 01 00:02, cost 7.00 → expect 1.0000"        "$AUG" 7.00 "$AUG"
printf '  %-46s %s accum=%s\n' "…and July is untouched" "$(date -d "@$JUL" +%Y-%m 2>/dev/null || date -r "$JUL" +%Y-%m)" \
    "$(awk -F= '$1=="accum"{printf "%.4f", $2}' "$CLAUDE_USAGE_DIR/$(date -d "@$JUL" +%Y-%m 2>/dev/null || date -r "$JUL" +%Y-%m)/$SID" 2>/dev/null)"
printf '\n'
