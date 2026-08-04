---
name: claude-statusline
description: "Build, install, customize, or debug a Claude Code status line — the bar under the prompt showing model, context %, rate-limit meters, or git state. Use when asked to make the terminal look better or show usage, add a context or progress bar, change the status line colours or layout, mirror the claude.ai composer footer, or fix a status line that is blank, stale, garbled, or slow. Ships one PowerShell script and one Bash script with a mutation-tested suite. Invoke with /claude-statusline."
---

# Claude Code status line

*ALVI Skills — a Claude Code skill toolchain collected by Alvi to make the work easier.*

A status line is a shell command Claude Code runs on every assistant message. It gets session
JSON on stdin and prints text to stdout. Whatever it prints becomes the bar under the prompt.

The fastest path is `/statusline show model, context percentage and a progress bar` — Claude Code
writes the script and edits settings for you. Use this skill when that is not enough: a specific
layout, a Windows machine, or a bar that is misbehaving.

## What ships here

Two scripts, same output, two layouts each.

| File | Platform | Needs |
| --- | --- | --- |
| `${CLAUDE_SKILL_DIR}/assets/statusline.ps1` | Windows | PowerShell 5.1, nothing else |
| `${CLAUDE_SKILL_DIR}/assets/statusline.sh` | macOS, Linux, Git Bash | `jq` |
| `${CLAUDE_SKILL_DIR}/assets/test-statusline.ps1` | Windows | runs the suite against either layout |

```
-Layout meters   (default)   --layout meters
◆ Opus 5  High  my-project  ⎇ main  ctx 13% · 128k/1M
Session: 16% · resets in 1h 31m  ▕██░░░░░░░░░░▏  ▕█░░░░░░░░░░░▏  Weekly: 8% · resets in 4d 22h

-Layout context              --layout context
◆ Opus 5  High  my-project  ⎇ main
Context: 13% · 128k/1M · 62m34s · 5h 16%  ▕██░░░░░░░░░░▏
```

Meters are blue under 75%, amber to 89%, red at 90%+. Fixed at 12 cells, so one cell always means
8.33 points whatever the window size. Labels step down through three forms as the terminal
narrows; the meter only shrinks when even the shortest labels will not fit.

The meters layout needs `rate_limits`, which is present only for Claude.ai Pro/Max auth and only
after the first API response — it falls back to the context meter rather than printing a blank row.

**No dollar figure.** `cost.total_cost_usd` is a client-side estimate of what the API would have
charged; on a subscription nobody pays it. A test asserts it never appears. Add it back if you are
on API billing.

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
   id in the effort slot. Join with `\u0001` and set `IFS` to that.
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
