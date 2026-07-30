# claude-statusline

A three-row [Claude Code](https://code.claude.com) status line: context and rate-limit gauges with **pace projection**, and a cost ledger that tracks spend once your subscription caps are exhausted.

![statusline](screenshot.svg)

```
Opus 5 (1M) · xhigh │ ⎇ main ~1 ?12 │ ctx ▉░░░░░░░░░ 9%
5h ███████▌░░ 75% ↑57m ↻2h10m │ 7d █████▌░░░░ 55% → ↻Sat
$12.14 │ cache 99% │ 6:24PM │ ~/…/myproject │ Refactor the auth module
```

POSIX shell, no dependencies beyond `jq` and the usual coreutils. ~19 subprocesses and ~160 ms per render.

## What you're looking at

**Row 1 — identity and workspace.** Model (amber Opus, blue Sonnet, cyan Haiku, crimson Fable) · reasoning effort (dim → cyan → orange → red) │ git branch with `✓` clean or `+N` staged / `~N` modified / `?N` untracked, plus `⇡N` / `⇣N` divergence │ context-window gauge.

**Row 2 — rate limits.** The 5-hour and 7-day windows, each as `gauge · percent · pace verdict · reset`.

**Row 3 — session vitals.** Session cost │ cache hit rate │ last interaction │ working directory │ session name.

Gauges use eighth-block sub-cell fills, so 10 columns give 80 steps of resolution — a 1% change is visible. Threshold colors: green under 50%, orange 50–79%, red 80%+.

## The pace verdict

The gauge tells you how much you've used. The arrow tells you whether that's a problem.

| | Meaning |
|---|---|
| `↓` green | Under pace — you'll finish the window with headroom. No time shown; there's nothing to predict. |
| `→` yellow | On pace to land near 100% at reset. |
| `↑` red | Overspending, **plus the moment you'd hit the cap**. |

So `5h ███████▌░░ 75% ↑57m ↻2h10m` reads: three-quarters spent, and at this rate you're capped in 57 minutes — but the window doesn't reset for 2h10m, leaving you locked out for over an hour.

Two independent colors: the **arrow** is the pace verdict, the **time** is urgency (how early exhaustion lands relative to the window remaining). A yellow `→` with a green time is very different from a red `↑` with a red one.

### The two windows are modelled differently — deliberately

The 5-hour window uses **linear projection**: `used% × window ÷ elapsed`. At session scale that's fair, because a 5-hour block is roughly one work session and burn is continuous while you're in it.

Applying the same math to 7 days is wrong. Wall-clock elapsed over a week includes nights and weekends, when burn is zero. If the window opened Wednesday and it's Friday evening, elapsed reads 31% while you've done essentially all the week's work — the projection screams even though the weekend will flatten it.

So the 7-day window compares **daily rates** instead:

```
actual/day    = used ÷ days_elapsed
allowance/day = (100 − used) ÷ days_left
```

Both sides are averages, so burstiness cancels. Units differ to match: the 5h window reports durations (`↑57m`, `↻2h10m`) because you think in minutes at that scale; the 7d window reports weekdays (`↑Thu 5PM`, `↻Sat`) because at week scale a duration forces the reverse conversion — "72h… so Saturday?"

### When the arrow goes quiet

- **At the cap** — 🤑 replaces the arrow. Projecting exhaustion when you're already exhausted is noise.
- **In the first 2% of a window** — no arrow at all. Early projections divide by a tiny elapsed time and produce nonsense.
- **When exhaustion would land past the reset** — arrow shows, timestamp doesn't. You can be over allowance and still never run out, because the window refills first.

## The API-overflow ledger

If your plan bills API usage once subscription caps are hit, row 3's second figure tracks that spend.

```
$12.14 · $4.37 🤑
└ green   └ red
```

The green figure is `cost.total_cost_usd` — **this session**, every token, subscription-covered or not. The red figure is **company-billed overflow across all sessions this calendar month**, and it only appears once it's non-zero.

Three things worth being honest about:

1. **The gate is an inference.** Nothing in the status-line payload marks a request as API-billed. The script infers it from cap exhaustion (`five_hour ≥ 100 || seven_day ≥ 100`) and accumulates deltas only while that holds. If your plan's overflow triggers on something else, the figure measures the wrong thing.
2. **The dollar amount is an estimate.** Claude Code computes it client-side at list rates; the docs say plainly it "may differ from your actual bill."
3. **A session's first sighting accrues nothing.** It records a baseline instead, because there's no way to know how much of an already-accumulated total was spent behind an open gate. Without this, installing the script mid-session while capped would book the entire session as overflow.

Ledger state lives in `~/.claude/usage/YYYY-MM/<session-id>`. Month scoping is the directory itself — the summing glob only ever sees the current month, so there's no timestamp filter and no rollover job to forget. A session running across midnight on the 1st carries its `last_cost` forward, so the delta straddling the boundary is neither lost nor double-counted.

### Reconciling against a real invoice

```sh
statusline-command.sh budget 200        # show the figure as $X/200
statusline-command.sh usage 41.10       # overwrite this month's anchor
statusline-command.sh sync 45.00        # offset every session, re-anchor to a real number
```

`sync` writes a negative offset per session so live sessions keep accruing from that point without double-counting.

## Install

Requires Claude Code and `jq`.

```sh
git clone https://github.com/emcodeio/claude-statusline.git
cd claude-statusline
ln -s "$PWD/statusline-command.sh" ~/.claude/statusline-command.sh
ln -s "$PWD/statusline-preview.sh" ~/.claude/statusline-preview.sh
```

Then in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "sh \"$HOME/.claude/statusline-command.sh\""
  }
}
```

Symlinking (rather than copying) means every edit you make is already in the working tree — the repo and the live script can't drift apart.

**Optionally** add `"refreshInterval": 3` alongside `"command"`. Status lines are event-driven — they re-run on a new assistant message, `/compact`, permission-mode and vim-mode changes, but **not** on terminal resize and not while idle. Without an interval, the countdowns stop being true the moment rendering stops.

### Preview every state without waiting for it

```sh
bash statusline-preview.sh          # 11 render states
bash statusline-preview.sh ledger   # ledger + month-rollover assertions
```

The harness is hermetic: it builds its own clean and dirty git repos, redirects the ledger to a scratch dir, and pins the clock so pace projections are deterministic. It never touches `~/.claude/usage`.

### Regenerating the screenshot

`screenshot.svg` is rendered from real ANSI output rather than captured, so it stays crisp and diffs as text. The committed demo payload carries a placeholder path; substitute a real repo at render time so the git segment appears:

```sh
jq --arg cwd "$PWD" '.workspace.current_dir = $cwd' tools/demo-payload.json \
  | CLAUDE_SL_NOW=1785355000 CLAUDE_USAGE_DIR=$(mktemp -d) sh statusline-command.sh \
  | python3 tools/ansi-to-svg.py > screenshot.svg
```

The pinned `CLAUDE_SL_NOW` keeps the rendered durations stable across regenerations.

## Gotchas worth knowing

Each of these cost real debugging time.

**Display width is not `${#var}`, and it is not `awk`'s `length()`.** The block glyphs are 3 bytes and 1 column each. Byte counts overstate a gauge row by ~50, and `${#var}` counts characters, which still misses the double-width emoji. The reliable route: strip ANSI, map wide glyphs to two cells, map every remaining character to one byte, then count bytes.

**Terminal width comes from `$COLUMNS`, never `tput cols`.** Claude Code captures the script's stdout rather than attaching it to the terminal, so `tput` has no tty to query and silently returns 80. Claude Code exports `COLUMNS` and `LINES` before running the script (v2.1.153+).

**`stat -f` half-succeeds on GNU.** `stat -f %m file` is BSD's mtime query; on GNU coreutils `-f` means `--file-system`, so a BSD-first `||` fallback chain never fires and you get garbage instead of a timestamp. Validate that the result is a bare integer rather than trusting the exit code. The same BSD-first pattern *is* correct for `date` (`-r` vs `-d @`), which fails cleanly.

**Don't assume one toolchain.** A machine can pair BSD `sed` with GNU `date`/`stat` (Nix on macOS does). `sed -i` is the classic casualty — its syntax differs. Rewriting via temp file plus `mv` works under either.

**Tab is IFS whitespace.** Splitting `@tsv` output with `IFS=$'\t'` collapses consecutive tabs into one delimiter, so a single empty field silently shifts every field after it. Read newline-delimited instead.

**`## No commits yet on <branch>`.** Git's porcelain branch header on an unborn HEAD isn't a branch name. Strip the prefix or the status line reports the whole sentence as your branch.

**Subprocess count is the performance budget.** This redraws constantly, so each helper collapses its work into a single `awk`, git state comes from one combined `status --porcelain --branch` (28 ms versus 79 ms for three separate calls), and the `date` flavour is probed once rather than per call.

## Credit

The pace-arrow idea — projecting end-of-window usage and surfacing it as a single glyph — comes from [vfmatzkin/claude-statusline](https://github.com/vfmatzkin/claude-statusline). The gauges, the daily-allowance model for the weekly window, and the overflow ledger are this implementation's own.

## License

MIT — see [LICENSE](LICENSE).
