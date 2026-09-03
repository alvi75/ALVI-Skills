---
name: claude-statusline
description: "Build, install, customize, or debug a Claude Code status line — the bar under the prompt showing model, context %, rate-limit meters, or git state. Use when asked to make the terminal look better or show usage, add a context or progress bar, change the status line colours or layout, mirror the claude.ai composer footer, or fix a status line that is blank, stale, garbled, or slow. Ships a PowerShell and a Bash renderer with a mutation-tested suite, plus a live usage-credit balance meter (dollars left, spent, monthly limit) for claude.ai logins that buy extra usage. Invoke with /claude-statusline."
---

# Claude Code status line

*ALVI Skills — a Claude Code skill toolchain collected by Alvi to make the work easier.*

A status line is a shell command Claude Code runs on every assistant message. It gets session
JSON on stdin and prints text to stdout. Whatever it prints becomes the bar under the prompt.

The fastest path is `/statusline show model, context percentage and a progress bar` — Claude Code
writes the script and edits settings for you. Use this skill when that is not enough: a specific
layout, a Windows machine, or a bar that is misbehaving.

## What ships here

Two renderers plus three helpers for the credit meter. The Bash renderer is ahead: the credit
and spend-limit rows are Bash-only (see Known limits).

| File | Platform | Needs |
| --- | --- | --- |
| `${CLAUDE_SKILL_DIR}/assets/statusline.ps1` | Windows | PowerShell 5.1, nothing else |
| `${CLAUDE_SKILL_DIR}/assets/statusline.sh` | macOS, Linux, Git Bash | `jq` |
| `${CLAUDE_SKILL_DIR}/assets/test-statusline.ps1` | Windows | runs the suite against either layout |
| `${CLAUDE_SKILL_DIR}/assets/test-statusline.sh` | macOS, Linux | 169 checks: renderer rows, credit fetcher (Keychain and API shimmed), `ccredit` |
| `${CLAUDE_SKILL_DIR}/assets/credit-balance.sh` | macOS, Linux | fetches the **live** usage-credit balance for a claude.ai login; run detached, never on the render path |
| `${CLAUDE_SKILL_DIR}/assets/ccredit` | macOS, Linux | shows the balance, forces or hides the row, sets the bar's reference total |
| `${CLAUDE_SKILL_DIR}/assets/credit-spend.sh` | macOS, Linux | Console API-key billing only: fetches real billed spend for the hand-anchored meter |

```
-Layout meters   (default)   --layout meters
◆ Opus 5  High  my-project  ⎇ main  ctx 13% · 128k/1M
Session: 16% · resets in 1h 31m  ▕██░░░░░░░░░░▏  ▕█░░░░░░░░░░░▏  Weekly: 8% · resets in 4d 22h

-Layout context              --layout context
◆ Opus 5  High  my-project  ⎇ main
Context: 13% · 128k/1M · 62m34s · 5h 16%  ▕██░░░░░░░░░░▏

-Layout meters, claude.ai login, while usage credits are being drawn on — live balance
◆ Opus 5  High  my-project  ⎇ main  ctx 13% · 128k/1M
Credits: $0.35 left of $40.00  ▕████████████▏  $39.65 used · month $39.65/$100.00

-Layout meters, claude.ai login, credits known but the plan quota is carrying the load
◆ Opus 5  High  my-project  ⎇ main  ctx 13% · 128k/1M · credits $0.35
Session: 16% · resets in 1h 31m  ▕██░░░░░░░░░░▏  ▕█░░░░░░░░░░░▏  Weekly: 8% · resets in 4d 22h

-Layout meters, Console API-key billing — no login to ask, so the balance is hand-anchored
◆ Opus 5  High  my-project  ⎇ main  ctx 13% · 128k/1M
Credits: ~$35.41 left  ▕█░░░░░░░░░░░▏  $3.10 this session

-Layout meters, behind a Claude apps gateway that sets a spend limit
◆ Opus 5  High  my-project  ⎇ main  ctx 13% · 128k/1M
Spend limit: 62% · resets in 3d 11h  ▕████████░░░░▏
```

Meters are blue under 75%, amber to 89%, red at 90%+. Fixed at 12 cells, so one cell always means
8.33 points whatever the window size. Labels step down through three forms as the terminal
narrows; the meter only shrinks when even the shortest labels will not fit.

The second row picks the first of these that applies, so it is never blank:

| # | Condition | Row |
| --- | --- | --- |
| 0 | `SOURCE=manual`, an anchor is set, and `MODE` is not `quota` | the hand-anchored credit meter |
| 1 | usage credits are **in use**: `~/.claude/credit-live` holds a balance, extra usage is not disabled, and either the balance fell within the last 10 min or a plan window is at 100%; or `ccredit mode credits` | the live credit meter |
| 2 | `rate_limits.five_hour` or `.seven_day` present | the two quota meters |
| 3 | only `rate_limits.spend_limit` present (gateway) | one spend-limit meter |
| 4 | no `rate_limits`, and `~/.claude/credit-config` carries a hand anchor (`BALANCE_AT`) | the hand-anchored credit meter (API-key auth, no plan) |
| 5 | otherwise | the context meter |

Row 1 exists because the plan meters say nothing once a window is exhausted and extra usage takes
over — that is exactly when the money starts moving. When credits are known but idle, line 1 shows
the balance as a tail (`· credits $0.35`) so a top-up landing, or the balance running dry, is
still visible.

Row 3 is not cosmetic. Each `rate_limits` window is independently absent, so a gateway payload can
carry `spend_limit` and neither of the other two — without its own branch that payload fell
through to dollars-by-hand while a real first-party spend figure sat unread in the same JSON.

**Dollars only where they are real.** `cost.total_cost_usd` is a client-side estimate of what the
API would have charged; on a subscription nobody pays it, so the subscription row never shows it
and a test asserts that. The live credit row shows the server's balance, not an estimate. The
hand-anchored row (API-key billing) shows the estimate because that is all there is.

## The credit meter

**There are two separate pools, and they hold different amounts.** Getting this wrong is what made
an earlier version of this meter invisible for a whole session.

| Pool | Where you see it | Readable? |
| --- | --- | --- |
| **claude.ai usage credits** — extra usage once a plan window is spent | `/usage-credits`, claude.ai Settings > Usage | Yes, live (below) |
| **Console prepaid credits** — consumed by API keys, Claude Code and the playground | console.anthropic.com > Billing | **No endpoint exposes it.** Hand-anchored |

An account can hold both, and one being empty says nothing about the other. Check which pool the
number you care about lives in before wiring anything up: `ccredit orgs` asks every organization
the login can see and prints what each one reports.

### claude.ai login with usage credits (the normal case)

Claude Code's own `/usage` and `/usage-credits` screens get the balance from two endpoints that
are not documented anywhere but are readable in the CLI binary (v2.1.259):

| Endpoint | Gives | Unit |
| --- | --- | --- |
| `GET /api/oauth/organizations/<org>/prepaid/credits` | `amount` (the balance), `auto_reload_settings.enabled` | cents |
| `GET /api/oauth/usage` | `extra_usage.used_credits`, `.monthly_limit` (null = unlimited), `.is_enabled` | cents |

`credit-balance.sh` calls both with the OAuth token Claude Code already holds for you (macOS
Keychain item `Claude Code-credentials`, else `~/.claude/.credentials.json`) and the org id from
`~/.claude.json`. The token stays in a shell variable, goes only to `api.anthropic.com`, and is
never written or printed — `--print` output and the cache are asserted token-free by the suite.

The cache is one line at `~/.claude/credit-live` (mode 600):

```
status|epoch|balance_c|used_c|limit_c|enabled|autoreload|total_c|drop_epoch|currency|reason|decimals
```

`reason` carries `extra_usage.disabled_reason`. It earns its place because a zero balance and a
failed fetch both render as `$0.00`, and only this tells them apart — `out_of_credits` makes the
row say **out of credits** instead. `decimals` is `extra_usage.decimal_places`: minor units per
unit is `10^decimals`, so a zero-decimal currency is not divided by 100.

The renderer reads only that file and spawns the fetcher **detached** when it is older than 60 s
(10 min after an auth-shaped failure, so a logged-out machine is not polled every render). The
render path never waits on the network. One fetch at a time per machine via a `mkdir` lock.

Two derived values the server does not give:

- **`total_c`** — what the bar fills against: the balance seen right after the most recent
  top-up. The fetcher bumps it whenever the balance *rises*; `ccredit total 40` pins it by hand,
  `ccredit total auto` releases it. A recharge therefore visibly empties the bar.
- **`drop_epoch`** — the last time the balance was seen to *fall*. That is the "credits in use"
  signal that puts the row on line 2 for the next 10 min (`ccredit window <seconds>` changes it).

```bash
ccredit                 # balance, meter total, this month, auto-reload, freshness, row mode
ccredit orgs            # which organization holds a balance, and how much
ccredit refresh         # fetch now and print the raw server answers — run this once after install
ccredit total 40        # meter against $40  |  ccredit total auto
ccredit mode credits    # always show the row  |  quota: never (and stop fetching)  |  auto (default)
```

`~` on the figure means the last successful fetch is over 5 minutes old, or the numbers were
carried over from a failed refresh. The numbers themselves are never estimated or invented: a
failed fetch keeps the previous good balance and marks it, it does not print `$0.00`.

`ccredit` lives at `~/.claude/ccredit`; symlink it onto `PATH` (`ln -sf ~/.claude/ccredit
~/.local/bin/ccredit`) or call it by full path — the bare commands above assume the symlink.

### Console prepaid credits (hand-anchored)

No endpoint returns this balance — not the Admin API, not the Usage & Cost API (verified against
both references), and not the OAuth endpoints above, which report the *other* pool. So it is
anchored by hand and measured spend is subtracted from it:

```
left now  =  the balance you typed  −  (spend since you typed it × calibration)
```

```bash
ccredit source manual # track this pool instead of the live one
ccredit set 0.35      # re-anchor to whatever Console shows; also re-learns the calibration
ccredit topup 20      # add a top-up to the anchor
ccredit cal 1.37      # set the calibration by hand
ccredit source live   # back to the fetched balance
```

**`source manual` is what makes the row visible.** The hand-anchored row used to sit *behind* the
plan meters in the selection order, and a claude.ai payload always carries those — so on a
subscription that branch was unreachable and the row never appeared, however carefully the balance
was anchored. On `manual` the row goes in front of them, and nothing is fetched.

Only the balance is manual; the subtraction is continuous. Both derived stores
(`credit-ledger.d/` and the cached billed total) measure spend *since* the anchor, so `ccredit`
deletes both on every re-anchor. Leaving them would re-subtract spend the new balance already
accounts for. The calibration exists because the transcript cannot see every billed call (the
auto-mode classifier fires on each tool use, WebFetch summarizes with its own model call); one full
session measured $34.14 billed against $24.93 visible.

### Known limits

- Two renders of the **same** session that interleave can lose the higher `latest` (measured about
  1 in 2000). The next render corrects it, so it self-heals rather than drifting.
- A session's **first observed** cost is treated as pre-anchor spend, since the two are
  indistinguishable. Up to one refresh interval of spend at session start therefore goes uncounted.
  Re-anchoring with `ccredit set` resets this cleanly.
- `statusline.ps1` has **no credit or spend-limit row** - those are Bash-only. The PowerShell
  renderer still covers the quota and context rows, and its suite asserts no dollar figure appears,
  which remains correct for it.
- The live balance is polled, not pushed: a drop shows up within one fetch interval (60 s), and the
  row stays up for the active window after the last drop it saw. Between the two, the plan meters
  show instead.
- "In use" is inferred from the balance falling. If a model bills to credits while no plan window
  is at 100% and the balance happens not to change between two polls (nothing was sent), the row
  steps back to the quota meters until the next drop. `ccredit mode credits` pins it.
- The two endpoints are undocumented. If a CLI release changes them the fetcher records
  `http_<code>` or `badjson`, keeps the last good numbers marked `~`, and `ccredit refresh` shows
  the raw answer to re-read.
- Reading the Keychain item from a script prompts for access the first time on some macOS setups.
  If that dialog is denied the status is `noauth` and the row never appears.

The hand-anchored row has two spend sources, in precedence order:

| Source | Marker | Needs | Notes |
| --- | --- | --- | --- |
| `cost_report` (real billed) | none | non-workspace API key at `~/.claude/.cost-api-key` | Authoritative. `amount` is in **cents** as a decimal string — `"123.45"` is $1.23 |
| Local ledger (estimate) | `~` prefix | nothing | Accumulates `cost.total_cost_usd` across sessions, which that field alone cannot — it is per-session and resets on `/clear` |

`credit-spend.sh` does the HTTP and is always spawned **detached**, with the render path reading
only what it already cached. A status line must never wait on a network call. Note the docs say the
Admin API is unavailable for individual accounts, so `cost_report` may 401 on a personal org — the
row silently stays on the `~` estimate when it does.

Refresh is triggered at 5 min, but a billed figure only prints **bare** while it is under 15 min
old; past that it is marked `~` like an estimate. Billing data lags ~5 min by itself, and a cache
entry can be arbitrarily stale if refreshes keep failing — printing that unmarked would present a
stale number with the authority of a fresh one.

### The ledger is a directory, one file per session

`~/.claude/credit-ledger.d/s-<session_id>`, each holding `accumulated baseline latest`. The
`s-` prefix and the dot-leading temp name are both load-bearing - see the bullets below.

- **One file per session, not one shared file.** Every open session re-renders on its own
  interval, so a shared read-modify-write loses updates — measured **9 of 60** rows surviving 60
  concurrent writers, which understates spend and so overstates money left. Per-session paths mean
  writers never contend. macOS has no `flock(1)`, so removing the shared write is the portable fix
  rather than locking it.
- **`baseline`** is what the session had already spent when the balance was anchored; that money is
  already priced into the balance you typed, so only growth past the baseline counts. Without it,
  re-anchoring mid-session instantly re-subtracts the running session's cost.
- **`accumulated`** exists because `/clear` zeroes `cost.total_cost_usd` and the curve restarts from
  a new origin. Taking `max()` looks like it fixes the backward walk but silently discards every
  post-clear dollar below the old peak. A drop is therefore treated as a segment boundary: bank the
  finished segment into `accumulated`, re-baseline at 0.

A meter that overstates money left is the dangerous direction — every rule above exists to stop
that, and each was a real measured defect, not a hypothetical.

## Install

```json
{
  "statusLine": {
    "type": "command",
    "command": "powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/YOU/.claude/statusline.ps1",
    "padding": 0,
    "refreshInterval": 60
  }
}
```

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh --layout meters",
    "padding": 0,
    "refreshInterval": 60
  }
}
```

`refreshInterval: 60` is not optional if you show a countdown. Updates are otherwise event-driven,
so an idle window freezes. With it, **every open Claude Code session re-runs its own status line
every 60 seconds**, including windows you are not typing in — each session has its own process and
its own bar, so they all stay current independently.

## The payload

Read the current field list at <https://code.claude.com/docs/en/statusline>. Do not work from
memory — fields get added.

| Field | Note |
| --- | --- |
| `model.display_name` | May carry a parenthetical, e.g. `Opus 5 (1M context)` |
| `context_window.used_percentage` | Input tokens only; excludes output. May be `null` early in a session. (`current_usage` is the field that also goes `null` right after `/compact`) |
| `context_window.total_input_tokens`, `.context_window_size` | Current context, not session totals — that changed in v2.1.132 |
| `cost.total_cost_usd` | Client-side estimate, not a bill. Resets on `/clear` |
| `rate_limits.five_hour`, `.seven_day` | `used_percentage` and `resets_at` (Unix epoch **seconds**). Only for Claude.ai Pro/Max, only after the first API response |
| `rate_limits.spend_limit` | Same two fields, but only behind a Claude apps gateway that sets a spend limit, and `used_percentage` **can exceed 100** once you pass the limit. Needs Claude Code v2.1.251+. Each window is independently absent, so a payload can carry `spend_limit` and neither of the other two |
| `rate_limits.extra_usage` | **Undocumented.** The v2.1.259 payload schema declares `is_enabled`, `monthly_limit`, `used_credits` (cents), `utilization`, `currency` as optional. No balance. The renderer reads it only to fill month figures the fetcher did not get |
| `session_id` | Stable per session — the right cache key. `$$` / `os.getpid()` change every run and defeat caching |
| `effort.level`, `fast_mode`, `thinking.enabled` | Absent when not applicable |
| `COLUMNS` env var | Terminal width. `tput cols` cannot see it; Claude Code exports this instead (v2.1.153+) |

## Rules that were learned the hard way

Each came from a real defect, most caught by an adversarial review rather than by testing.

1. **Never print an error into the bar.** A non-zero exit or empty stdout blanks the status line
   silently. Wrap parsing in try/catch and `exit 0`. Test with empty stdin, `garbage`, and `{}`.
2. **Windows: forward slashes in the `command` path.** Claude Code routes through Git Bash when
   Git Bash is installed, and Git Bash eats unquoted backslashes. The failure is silent.
3. **PowerShell 5.1 drains stdin into `$input` before the script body runs.**
   `[Console]::In.ReadToEnd()` returns zero characters under `-File`. Read `$input | Out-String`
   first, then fall back.
4. **PowerShell variable names are case-insensitive.** A `$label` holding text silently overwrites
   a `$LABEL` holding an ANSI colour.
5. **Emit LF, not CRLF.** `Write-Output` gives CRLF; CRLF plus ANSI across multiple lines is the
   documented render-glitch profile. Write raw UTF-8 bytes to the standard output stream.
6. **Bash: do not split fields on tab.** Tab is an IFS *whitespace* character, so runs of tabs
   collapse and every empty field shifts the rest left — an absent `effort.level` puts the session
   id in the effort slot. Join with `\u001f` (unit separator) and set `IFS` to
   that - **not** `\u0001`: bash 3.2, the only bash macOS ships, reserves `0x01` as
   `CTLESC` internally and silently eats it, so a `0x01`-delimited line comes back as a
   single field.
7. **`[math]::Round` is banker's rounding.** It draws 30% and 50% identically at 5 cells and drops
   75% from 11 cells to 10. Pass `[MidpointRounding]::AwayFromZero`. In Bash, `(p*w+50)/100`.
8. **Keep the fraction until the bar is drawn.** Floor the *label*, not the input. 37.5% of a
   12-cell meter is exactly 4.5 cells; truncating first loses a cell.
9. **Floor the percentage label, do not round it.** Rounding turns 99.5% into `100%`, which reads
   as an exhausted limit.
10. **Do not force a nonzero value to a full cell.** At 12 cells one block is 8.3 points, so 0.4%
    drawn as a block overstates it 17x next to a label reading `0%`. Use a sliver, and not `▏` —
    that glyph is already the track's closing bracket.
11. **Fit the row to `COLUMNS` and leave slack on the right.** MCP errors, auto-update notices and
    the verbose-mode token counter share the right end of that row.
12. **Cache anything that spawns a process.** On Windows every `git` call costs ~230 ms. Cache to
    a temp file keyed by `session_id` with a ~5 s TTL.
13. **`stat -c` is GNU, `stat -f` is BSD.** Try the GNU form first: on Linux the BSD form prints a
    usage report to stdout before failing, and that output breaks the arithmetic.
14. **`printf '%s'`, not `'%b'`.** `%b` escape-processes the data, mangling any branch name or
    model string containing a backslash.

## Measured latency (Windows 11, warm, 5 runs)

| Approach | Mean |
| --- | --- |
| `powershell -NoProfile` startup, empty script | 563 ms |
| `statusline.ps1`, full render | **832 ms** |
| Git Bash startup, empty script | 263 ms |
| Each extra process spawn under Git Bash | ~85 ms |

Claude Code debounces at 300 ms and cancels an in-flight script when a new update arrives, so an
800 ms script lags under a second and gets cancelled during message bursts. Most of that is
interpreter startup, not the script. On macOS and Linux the Bash version is several times faster.

## When the bar is blank

1. **Workspace trust not accepted for that directory.** `statusLine` runs a shell command, so it
   needs the same trust as hooks. Check `hasTrustDialogAccepted` for the directory in
   `~/.claude.json`. `claude --debug` logs `Status line command skipped: workspace trust not accepted`.
2. `disableAllHooks: true` also disables the status line.
3. Backslashes in the command path on Windows — rule 2.
4. `jq` missing, for the Bash version. It prints a one-line hint rather than going blank.
5. The script exits non-zero or prints nothing. Run it by hand with mock JSON.
6. Not executable (`chmod +x`) on macOS/Linux.

## Test before wiring it up

```powershell
powershell -NoProfile -File ${CLAUDE_SKILL_DIR}/assets/test-statusline.ps1 -Script ~/.claude/statusline.ps1
powershell -NoProfile -File ${CLAUDE_SKILL_DIR}/assets/test-statusline.ps1 -Layout context
```

Exit code 0 means every check passed. It asserts rather than prints: sub-cell slivers,
away-from-zero rounding at the 37.5% midpoint, floored labels, clamping at both ends, absence of
any dollar figure, LF-only output, and exit 0 on degenerate stdin. It sets
`[Console]::OutputEncoding` first — otherwise the default Windows codepage counts each
box-drawing glyph as three characters and every width check fails on a good script.

There is no Bash suite. Test that one by hand:

```bash
echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'$PWD'"},"context_window":{"used_percentage":25,"total_input_tokens":50000,"context_window_size":200000},"session_id":"t","rate_limits":{"five_hour":{"used_percentage":16,"resets_at":'$(( $(date +%s) + 5000 ))'}}}' | ./statusline.sh
```

Then vary it: `used_percentage` null, `rate_limits` absent, empty stdin, malformed JSON, `COLUMNS`
at 40 and 200. Exit code 0 and non-empty stdout every time.

## Related

- Field reference: <https://code.claude.com/docs/en/statusline>
- Themes and terminal appearance: <https://code.claude.com/docs/en/terminal-config>
- Community presets: [ccstatusline](https://github.com/sirmalloc/ccstatusline),
  [starship-claude](https://github.com/martinemde/starship-claude)
