---
name: token-budget
description: Use when the user caps a task to a share of their 5-hour usage window ("budget: 15%", "/token-budget 15", "use at most 10% of my window", "finish by 33%"), or when a [token-budget] line appears in context.
---

# Token Budget

*ALVI Skills — a Claude Code skill toolchain collected by Alvi to make the work easier.*

A budget caps how much of the 5-hour usage window one task may consume, counted from the moment it is set. "budget: 15%" at 23% used means stop by 38%. It is a ceiling: a task that needs 6% finishes at 6%. It is usage, not time: a council call can take 10% in two minutes.

Two facts shape the number. Usage is measured for the whole account, so other Claude windows running at the same time spend from this budget too. And a budget never exceeds what the window has left: "budget: 30%" at 88% used becomes 12%.

You cannot see the window yourself. The status line caches it and the hooks read that cache. The only measurement is:

```
bash ~/.claude/skills/token-budget/assets/budget.sh check
```

Counting your own reads and edits is a guess, not a measurement.

## Setting the cap

The prompt hook sets the cap when the user writes `budget: 15%` or `/token-budget 15` at the start of the prompt, at its end, or on a line of its own. Text the user pasted is ignored. `budget: off` lifts it. `/token-budget check` prints the status line. Each Claude window has its own budget.

If the user asked for a cap in other words and no `[token-budget] budget set` line appeared in context, set it yourself before any other tool call:

```
bash ~/.claude/skills/token-budget/assets/budget.sh set 15
```

"Finish by 33%" is an absolute target: run `check` to read the window, subtract, and set the difference.

The cap stays active across turns in this session until the user lifts it, re-sets it, or the window it was set in has fully passed. If `check` says it is waiting for a snapshot, the login has no rate-limit data; say so once and still follow the rules below.

## How to work under a cap

1. **Scope first.** Before any tool call, state in one line what the core deliverable is and what gets cut if the cap runs short. Cheap steps first, expensive steps last.
2. **Check at phase boundaries.** Run `check` after planning, after implementation, before verification, and before any extra pass. A check is one cheap Bash call.
3. **Inline, one session.** No subagents, councils, workflows, or parallel reviews under a cap. The hook denies Agent and Workflow once 80% of the cap is spent.
4. **Read what you need, once.** Grep before Read, line ranges over whole files, never re-read a file you already have.
5. **Core before pipeline.** Tests that prove the deliverable works come first. Mutation testing, security review, council, CLAUDE.md updates, and commits run only after the core is verified and only if the hook has not yet issued its 50% warning. Otherwise list them as not done.
6. **At the 80% warning**, finish the step in progress, verify it, and write the handoff. No new scope after it.
7. **At the cap**, the hook blocks every tool except a few light ones (Read, Write, Edit, Glob, Grep and the like) for twelve calls, and `budget.sh check`. Use them for the handoff, not for one more fix. A denied call is a wasted round-trip; retrying it is denied again. Ending the turn is not a tool call and is always possible.

## The handoff

Whenever you stop short, the last message states:
- what is done and verified
- what is not done, in order of value
- the exact command or file to resume from
- the `check` line

## Rationalizations that do not hold

| Thought | Reality |
|---|---|
| "I'll estimate from how many files I touched" | Guess. Run `check`. |
| "10% is about 30 minutes" | Percent is usage, not time. |
| "One more subagent will finish it faster" | Subagents are the biggest spenders and the hook denies them at 80%. |
| "Finishing the feature is worth going over" | The user set the cap so the rest of the window survives. |
| "The snapshot is stale, I probably have more" | Stale means older, never lower. Treat it as the floor. |
| "Skip the handoff, I'm almost done" | Almost done without a handoff is lost work. |
