#!/usr/bin/env bash
# Runs install.sh against a throwaway HOME. Ends "failed 0" when everything passes.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

run() { HOME="$H" CLAUDE_CONFIG_DIR= CODEX_HOME= bash "$here/install.sh" "$@" >"$H/out" 2>&1; echo $? >"$H/rc"; }

H=$(mktemp -d)
run
check "fresh install exits 0"            '[ "$(cat $H/rc)" = 0 ]'
check "claude copy"                      '[ -f $H/.claude/skills/llm-council/SKILL.md ]'
check "agents copy"                      '[ -f $H/.agents/skills/llm-council/SKILL.md ]'
check "no nested copy"                   '[ ! -e $H/.claude/skills/llm-council/llm-council ]'
check "copy matches source"              'diff -rq "$here/llm-council" $H/.agents/skills/llm-council >/dev/null'

run
check "second run is up to date"         '[ "$(grep -c "up to date" $H/out)" = 2 ]'

echo edited >> "$H/.claude/skills/llm-council/SKILL.md"
run
check "edited copy is skipped"           'grep -q "skipped .*\.claude" $H/out'
check "skip exits 2"                     '[ "$(cat $H/rc)" = 2 ]'
check "edited copy left alone"           'grep -q edited $H/.claude/skills/llm-council/SKILL.md'

echo stale > "$H/.claude/skills/llm-council/old.txt"
run --force
check "--force exits 0"                  '[ "$(cat $H/rc)" = 0 ]'
check "--force replaces the edit"        '! grep -q edited $H/.claude/skills/llm-council/SKILL.md'
check "--force drops leftover files"     '[ ! -e $H/.claude/skills/llm-council/old.txt ]'
rm -rf "$H"

H=$(mktemp -d); mkdir -p "$H/.cursor" "$H/.codex/skills/llm-council"
run
check "only two folders written"         '[ "$(grep -c installed $H/out)" = 2 ] && [ ! -e $H/.cursor/skills ]'
check "old codex copy is reported"       'grep -q "note: .*\.codex/skills/llm-council" $H/out'
check "old codex copy is not deleted"    '[ -d $H/.codex/skills/llm-council ]'
rm -rf "$H"

H=$(mktemp -d); mkdir -p "$H/.claude/skills"; ln -s "$H/gone" "$H/.claude/skills/llm-council"
run
check "dangling link is skipped"         'grep -q "skipped .*\.claude" $H/out'
check "other folders still installed"    '[ -f $H/.agents/skills/llm-council/SKILL.md ]'
run --force
check "--force replaces dangling link"   '[ -f $H/.claude/skills/llm-council/SKILL.md ]'
rm -rf "$H"

H=$(mktemp -d); mkdir -p "$H/alt"
HOME="$H" CLAUDE_CONFIG_DIR="$H/alt" bash "$here/install.sh" >/dev/null 2>&1
check "CLAUDE_CONFIG_DIR is honoured"    '[ -f $H/alt/skills/llm-council/SKILL.md ]'
rm -rf "$H"

echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
