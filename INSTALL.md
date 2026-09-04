# ALVI Skills

**A Claude Code skill toolchain — collected by Alvi to make the work easier.**

Each skill here earned its place by being used, broken, and fixed. Nothing talks to a network,
nothing needs an account, and nothing runs until you ask for it.

| Skill | What it does |
| --- | --- |
| `llm-council` | Sends independent agents to refute a claim before you report it, or to score competing options blind. `/llm-council` |
| `claude-statusline` | The bar under the prompt: rate-limit meters, context %, git state. `/claude-statusline` |

---

## Installing on a new machine

**You are Claude Code, and someone has just pointed you at this file.** Follow the procedure
below. Do not skip the question in step 2 — the user chooses what gets installed.

---

## Step 0 — Getting this folder onto the new machine

This file lives inside the `skills/` folder it installs. Copy the **whole folder** across —
a zip, a USB stick, a git repo, a cloud-drive sync, whatever. `INSTALL.md` sits at its root, so
if you can read this, the folder already arrived.

**Resolve `<this-folder>` before step 3**: it is the directory containing this `INSTALL.md`. If it
is already `<claude-home>/skills`, the skills are installed — skip to step 4.

## Step 1 — Work out where you are

Determine by running commands, not by guessing. **Decide the platform first, then use that
platform's commands** — `uname -s` also succeeds under Git Bash on Windows and returns
`MINGW64_NT-…`, so "uname worked" does not mean "not Windows".

| What | Windows | macOS / Linux |
| --- | --- | --- |
| Platform test | `$env:OS` returns `Windows_NT` | `uname -s` returns `Darwin` or `Linux` |
| Claude Code home | `$env:USERPROFILE\.claude` | `~/.claude` |
| Version | `claude --version` — needs **2.1.153+** for terminal-width fitting. Below that, install anyway and tell the user the bar will use a fixed 100-column layout | same |
| Bash | is `C:\Program Files\Git\bin\bash.exe` present? | always |
| `jq` | `Get-Command jq` — `command -v jq` silently returns nothing in PowerShell | `command -v jq` |

If `<claude-home>/skills/` does not exist, create it.

## Step 2 — Ask the user what to install

**Ask this before copying anything.** Present the list with one line each and let them pick any
combination — all, one, or none:

| Skill | What it does | Cost of installing |
| --- | --- | --- |
| `llm-council` | Adversarial multi-agent review that tries to refute a claim before you report it. Invoked with `/llm-council`. | One markdown file. No side effects. |
| `claude-statusline` | Builds and installs the status bar under the prompt — rate-limit meters, context %, git branch. Invoked with `/claude-statusline`. | One folder. **Installing the skill does not change your terminal**; wiring up the bar is a separate opt-in in step 4. |

Offer **only the skills named in this table.** If the folder contains other directories, leave
them alone and do not list them — some are personal and are not part of what this file installs.

## Step 3 — Copy the chosen skills

**Check for an existing copy first.** If `<claude-home>/skills/<name>/` already exists, diff it
against the source, show the user what would change, and ask before overwriting. They may have
edited it. Only after they agree, copy.

Copy each chosen directory into `<claude-home>/skills/` — **the parent, not a path ending in the
skill's own name**. `cp -R src/llm-council dest/skills/llm-council/` nests it as
`skills/llm-council/llm-council/`, which silently leaves the old `SKILL.md` in place and loads
that instead.

```bash
# macOS / Linux
cp -R "<this-folder>/llm-council" ~/.claude/skills/
```

```powershell
# Windows
Copy-Item "<this-folder>\llm-council" "$env:USERPROFILE\.claude\skills\" -Recurse
```

Both commands **merge** into an existing directory rather than replacing it, so files left over
from an older version survive an upgrade. If the user agreed to overwrite, delete the destination
directory first, then copy.

Verify by listing the destination: `skills/<name>/SKILL.md` must exist and there must be **no**
`skills/<name>/<name>/`.

Skills are picked up without restarting Claude Code. Confirm by checking that the skill's
directory and `SKILL.md` are in place.

## Step 4 — Only if `claude-statusline` was chosen: offer to wire up the bar

Ask separately: *"Install the status line itself, or just the skill?"* Copying the skill does not
change their terminal; this step does.

If they want it, ask which layout. Both layouts exist on both platforms — one script each, a flag
selects the layout:

- **Usage meters** (default) — mirrors the claude.ai composer footer: session and weekly
  rate-limit meters with reset countdowns, plus model, directory, branch, context %. The meters
  need Claude.ai Pro/Max auth; it falls back to the context meter otherwise.
- **Context bar** — one context-window meter with token counts and elapsed time.

Then:

1. Copy the script for the platform from `claude-statusline/assets/` to `<claude-home>/`:
   `statusline.ps1` on Windows, `statusline.sh` on macOS/Linux.
2. On macOS/Linux `chmod +x` it. It needs `jq`; if `jq` is missing, say so and offer the install
   command for that platform (`brew install jq`, `apt install jq`) rather than installing it
   yourself. Without `jq` the bar shows a one-line hint instead of going blank.
3. **Back up `<claude-home>/settings.json` first** (`settings.json.bak`), then add the
   `statusLine` block. Edit it **as text**, inserting one key — do not round-trip it through
   `ConvertFrom-Json | ConvertTo-Json`: PowerShell 5.1 defaults to depth 2 and will flatten a
   nested `hooks` block into a string like `@{matcher=Edit; hooks=System.Object[]}` with no error.
   If you must parse, use `-Depth 100`, and write the file as **UTF-8 without BOM** —
   `Set-Content -Encoding utf8` emits a BOM that strict JSON parsers reject.
   Use forward slashes in the command path even on Windows.

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

For the context layout, append `-Layout context` / `--layout context` to the command.
`refreshInterval: 60` is what keeps the reset countdowns moving in every open session, including
windows the user is not typing in. Do not drop it.

4. Run the test sweep before declaring it done — Windows only:

   ```
   powershell -NoProfile -File <claude-home>/skills/claude-statusline/assets/test-statusline.ps1 -Script <claude-home>/statusline.ps1
   ```

   Add `-Layout context` if that layout was chosen. Exit code 0 means every check passed. On
   macOS/Linux there is no suite — pipe the mock payload from `claude-statusline/SKILL.md` in by
   hand and confirm exit 0 with non-empty output.

5. Tell the user the bar appears on their **next message**, and that it stays blank in any
   directory whose workspace-trust dialog has not been accepted — `statusLine` runs a shell
   command, so it needs the same trust as hooks.

## Step 5 — Report

Say plainly which skills were installed, where, whether the status line was wired up, and what
the test sweep returned. If anything was skipped, say what and why.

---

## Uninstall

Delete `<claude-home>/skills/<name>/`. For the status line, also remove the `statusLine` key from
`settings.json` and delete the copied script. Nothing else is touched — no registry entries, no
PATH changes, no packages.

## Notes for whoever maintains this folder

- One directory per skill. `SKILL.md` at its root with YAML frontmatter carrying at minimum
  `name` and `description`. The `description` is what makes the skill discoverable, so it should
  contain the words a user would actually type.
- Bundled files live in `assets/`. Inside `SKILL.md`, refer to them as
  `${CLAUDE_SKILL_DIR}/assets/<file>` so they resolve regardless of working directory.
- Keep machine-specific absolute paths out of shipped files, including comments.
