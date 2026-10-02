# ALVI Skills

*A Claude Code skill toolchain — collected by Alvi to make the work easier.*

Each skill here earned its place by being used, broken, and fixed. Nothing talks to a network,
nothing needs an account, and nothing runs until you ask for it.

| Skill | What it does | Invoke |
| --- | --- | --- |
| `llm-council` | Sends independent agents to refute a claim before you report it, or scores competing options blind. | `/llm-council` |
| `claude-statusline` | The bar under the prompt: rate-limit meters, context %, git state. | `/claude-statusline` |
| `token-budget` | Caps one task to a share of the 5-hour usage window, enforced by hooks. | `budget: 15%` in a prompt |

## llm-council

A council is **independent agents given an adversarial brief and told to disprove a claim**, before
that claim is reported to anyone. It is not a second opinion, not a code review, and not a vote.
Its job is to fail the work cheaply, before someone else does.

**The rule:** never announce a number, a fix, or a conclusion until a council has tried to break it.
The reason is specific — whoever writes a check writes it against the same mental model that
produced the bug, so their own test inherits the blind spot.

It has overturned the author's own work repeatedly:

| The claim | What the council found |
| --- | --- |
| "Coverage gap is 82%" | 664 of 675 "missing" tables were `_T` twins already indexed. Real gap: 11. |
| "Pruned 217 bad FK edges" | 140 were valid — the prune checked PRIMARY KEY, not enforced UNIQUE indexes. |
| "Fixed the judge card" | The fix used a suffix rule — the exact defect it was fixing. |
| "n-hop went 65% → 98%" | Independent benchmark: 70.7% → 72.4%. The first was built from the graph it scored. |
| "This gold SQL is correct" | 4 of 16 golds were wrong. On one, the system's answer beat the reference. |

None were caught by testing. All were caught by an agent told to assume the author was wrong.

Two modes. **Refute** is the default: one claim, several lenses, each told to break it. **Judge** is
for choosing between candidates — every judge scores every candidate on the same rubric, blind,
then the winner is synthesized with the best parts of the runners-up grafted in.

The council is not an oracle. It has invented defects that measurement then disproved. Re-check
anything it asserts before repeating it, and report what you could not verify as unverified.

## claude-statusline

A status line is a shell command Claude Code runs on every assistant message. It gets session JSON
on stdin and prints text to stdout. Whatever it prints becomes the bar under the prompt.

```
--layout meters   (default)
◆ Opus 5  High  my-project  ⎇ main  ctx 13% · 128k/1M
Session: 16% · resets in 1h 31m  ▕██░░░░░░░░░░▏  ▕█░░░░░░░░░░░▏  Weekly: 8% · resets in 4d 22h

--layout context
◆ Opus 5  High  my-project  ⎇ main
Context: 13% · 128k/1M · 62m34s · 5h 16%  ▕██░░░░░░░░░░▏
```

Meters are blue under 75%, amber to 89%, red at 90%+. Fixed at 12 cells, so one cell always means
8.33 points whatever the window size. Labels step down through three forms as the terminal narrows;
the meter only shrinks when even the shortest labels will not fit.

The meters layout needs `rate_limits`, which is present only for Claude.ai Pro/Max auth and only
after the first API response — it falls back to the context meter rather than printing a blank row.

**No dollar figure.** `cost.total_cost_usd` is a client-side estimate of what the API would have
charged; on a subscription nobody pays it. A test asserts it never appears. Add it back if you are
on API billing.

## token-budget

Put `budget: 15%` at the start or end of a prompt and that task may use at most 15% of the 5-hour
usage window, counted from that moment. At 23% used, it must be done by 38%. It is usage, not time.

The model cannot see the window. Claude Code only passes `rate_limits` to the status line, so the
status-line command runs through `budget.sh capture` first, which caches the numbers and passes the
payload on unchanged. Two hooks read that cache:

| Budget spent | What happens |
| --- | --- |
| 50% | one warning: decide whether the core deliverable still fits |
| 80% | second warning; new subagents and workflows are denied |
| 100% | every tool is blocked except a few light ones for twelve calls, enough to write a handoff |

`budget: off` lifts it, `/token-budget check` shows where it stands. The directive only counts at the
start or end of a prompt or on a line of its own, and pasted blocks are skipped, so text such as "the
grant budget: 15% went to travel" never sets a cap.

It is a ceiling, not a target: a task that needs 6% under a 15% budget just finishes. Each Claude
window keeps its own budget, and subagents share their window's. Usage is reported for the whole
account, though, so other windows running at the same time spend from it too. A budget never
exceeds what the window has left: "budget: 30%" at 88% used becomes 12%, so the warnings still fire.

Needs a Claude.ai Pro/Max login, because that is the only auth that carries `rate_limits`. On API-key
auth it records the cap and says it cannot enforce it. macOS, Linux, or Git Bash, plus `jq`.
`bash token-budget/assets/test.sh` runs 97 checks against mock payloads.

## Install

Clone this repo, open Claude Code in the folder, and tell it to read `INSTALL.md`. It works out the
platform, asks which skills you want, copies them into `<claude-home>/skills/`, and — only if you
say yes — wires up the status line.

```bash
git clone https://github.com/alvi75/ALVI-Skills.git
```

By hand, if you would rather: copy the skill directory into `<claude-home>/skills/` — **the parent,
not a path ending in the skill's own name**. `cp -R src/llm-council dest/skills/llm-council/` nests
it as `skills/llm-council/llm-council/`, which silently leaves the old `SKILL.md` in place and loads
that instead.

```bash
cp -R llm-council ~/.claude/skills/                                    # macOS / Linux
Copy-Item llm-council "$env:USERPROFILE\.claude\skills\" -Recurse      # Windows
```

Skills are picked up without restarting Claude Code.

| | Needs |
| --- | --- |
| `llm-council` | Nothing. One markdown file. |
| `claude-statusline` on Windows | PowerShell 5.1 |
| `token-budget` | `jq`, bash, a Pro/Max login, and the status line plus two hooks wired up (INSTALL.md step 5) |
| `claude-statusline` on macOS / Linux / Git Bash | `jq` |
| Terminal-width fitting | Claude Code 2.1.153+. Below that the bar uses a fixed 100-column layout. |

The status line stays blank in any directory whose workspace-trust dialog has not been accepted —
it runs a shell command, so it needs the same trust as hooks.

## Uninstall

Delete `<claude-home>/skills/<name>/`. For the status line, also remove the `statusLine` key from
`settings.json` and delete the copied script. For `token-budget`, remove its two hook entries, take
`budget.sh capture | ` off the front of the status-line command, and delete `<claude-home>/budget/`.
Nothing else is touched — no registry entries, no PATH changes, no packages.

## Notes for whoever maintains this

One directory per skill. `SKILL.md` at its root with YAML frontmatter carrying at minimum `name` and
`description`. The `description` is what makes the skill discoverable, so it should contain the
words a user would actually type. Bundled files live in `assets/`, referred to inside `SKILL.md` as
`${CLAUDE_SKILL_DIR}/assets/<file>` so they resolve regardless of working directory.

Keep machine-specific absolute paths out of shipped files, including comments. Keep credentials,
internal hostnames and employer identifiers out of them too — a skill that starts as a personal note
tends to end up in a public repo.

Do not use U+0001 as a field delimiter in a shell script. bash 3.2, which macOS still ships as
`/bin/bash`, reserves `0x01` as `CTLESC` internally and silently eats it, so a `0x01`-delimited line
comes back as a single field. `statusline.sh` uses U+001F, emitted as a jq unicode escape rather
than a literal byte so it survives copying and zipping.
