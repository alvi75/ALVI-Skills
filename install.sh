#!/usr/bin/env bash
# Installs llm-council for every coding agent on this machine.
#   bash install.sh           install, skip copies that differ
#   bash install.sh --force   replace copies that differ
set -euo pipefail

SKILL=llm-council
SRC="$(cd "$(dirname "$0")" && pwd)/$SKILL"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

[ -f "$SRC/SKILL.md" ] || { echo "missing $SRC/SKILL.md" >&2; exit 1; }

# ~/.agents/skills is read by Codex, Gemini CLI, OpenCode, Cursor and Copilot.
targets=("${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills" "$HOME/.agents/skills")

status=0
for dir in "${targets[@]}"; do
  dest="$dir/$SKILL"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if diff -rq "$SRC" "$dest" >/dev/null 2>&1; then
      echo "up to date  $dest"
      continue
    fi
    if [ "$FORCE" -ne 1 ]; then
      echo "skipped     $dest (differs; diff -r it, then rerun with --force)"
      status=2
      continue
    fi
    rm -rf "$dest"
  fi
  mkdir -p "$dir"
  cp -R "$SRC" "$dir/"
  echo "installed   $dest"
done

# An older copy in the Codex folder can show up as a second llm-council.
old="${CODEX_HOME:-$HOME/.codex}/skills/$SKILL"
if [ -e "$old" ]; then
  echo "note: $old also exists. Codex may list llm-council twice; delete that folder to use this copy."
fi

exit "$status"
