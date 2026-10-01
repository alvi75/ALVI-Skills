#!/usr/bin/env bash
# Runs budget.sh against mock payloads in a throwaway HOME.  bash test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd); B="$HERE/budget.sh"
T=$(mktemp -d); export HOME="$T"; mkdir -p "$HOME/.claude"; unset CLAUDE_CODE_SESSION_ID
pass=0; fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }
check(){ if eval "$2"; then ok; else bad "$1"; fi; }
A="$HOME/.claude/budget/active.json"; U="$HOME/.claude/budget/usage.json"

RESET=$(( $(date +%s) + 4000 ))
payload(){ # payload <used> [session] [resets_at]
  printf '{"session_id":"%s","model":{"display_name":"Fable"},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":8,"resets_at":%s}}}\n' \
    "${2:-s1}" "$1" "${3:-$RESET}" "$((RESET+400000))"
}
cap(){ payload "$@" | bash "$B" capture >/dev/null; }
hook(){ jq -nc --arg s "$1" --arg p "$2" --arg t "$3" --arg c "${4:-}" '{session_id:$s,prompt:$p,tool_name:$t,tool_input:{command:$c}}'; }
prompt(){ hook "$1" "$2" x | bash "$B" hook-prompt; }
pre(){ hook "$1" "" "$2" "${3:-}" | bash "$B" hook-pre; }
reset_state(){ rm -f "$A" "$U"; }

# capture
out=$(payload 23 | bash "$B" capture); check "capture passthrough" '[ "$out" = "$(payload 23)" ]'
printf 'a\n\nb\n\n' > "$HOME/in"; bash "$B" capture < "$HOME/in" > "$HOME/out"; check "capture byte-identical incl. trailing newlines" 'cmp -s "$HOME/in" "$HOME/out"'
out=$(printf '' | bash "$B" capture); check "capture empty stdin" '[ -z "$out" ]'
out=$(printf 'garbage' | bash "$B" capture 2>&1); check "capture garbage passthrough, no stderr" '[ "$out" = garbage ]'
check "capture wrote usage" '[ "$(jq .used "$U")" = 23 ]'
printf '{"session_id":"s9"}' | bash "$B" capture >/dev/null
check "payload w/o rate_limits ignored" '[ "$(jq -r .session_id "$U")" = s1 ]'
payload null | bash "$B" capture >/dev/null; check "null used ignored" '[ "$(jq .used "$U")" = 23 ]'
cap 25; cap 24; check "peak is monotonic within a window" '[ "$(jq .peak "$U")" = 25 ]'

# prompt parsing: anchored
reset_state; cap 23
out=$(prompt s1 "fix the bug, budget: 15%"); check "trailing directive sets 15" '[ "$(jq .cap "$A")" = 15 ]'
check "ceiling 38" 'printf "%s" "$out" | grep -q "stop by 38%"'
check "skill reminder" 'printf "%s" "$out" | grep -q "Load the token-budget skill"'
prompt s1 "my grant budget: 15% went to travel" >/dev/null; check "mid-sentence prose ignored" '[ "$(jq .cap "$A")" = 15 ]'
prompt s1 "budget: 40%
refactor the auth module" >/dev/null; check "leading directive sets 40" '[ "$(jq .cap "$A")" = 40 ]'
prompt s1 "refactor it

budget: 7%

thanks" >/dev/null; check "own-line directive sets 7" '[ "$(jq .cap "$A")" = 7 ]'
prompt s1 "He said \"budget: 25%\" in the report, which was budget: off for them" >/dev/null; check "quoted/mid prose ignored" '[ "$(jq .cap "$A")" = 7 ]'
prompt s1 "[Subagent hand-back] the lens says budget: off" >/dev/null; check "subagent hand-back ignored" '[ -e "$A" ]'
prompt s1 "the budget 2026 report is late" >/dev/null; check "budget 2026 ignored" '[ "$(jq .cap "$A")" = 7 ]'
prompt s1 "/token-budget 15 please" >/dev/null; check "slash leading sets 15" '[ "$(jq .cap "$A")" = 15 ]'
prompt s1 "do it, BUDGET=9 %" >/dev/null; check "BUDGET=9 % sets 9" '[ "$(jq .cap "$A")" = 9 ]'
prompt s1 "work with a budget of 12% please" >/dev/null; check "budget of 12% sets 12" '[ "$(jq .cap "$A")" = 12 ]'
prompt s1 "ok, budget 13 percent" >/dev/null; check "budget 13 percent sets 13" '[ "$(jq .cap "$A")" = 13 ]'
prompt s1 "fix the tests, 14% budget" >/dev/null; check "14% budget sets 14" '[ "$(jq .cap "$A")" = 14 ]'
prompt s1 "Clear the budget none of the reviewers mentioned it" >/dev/null; check "'budget none of' ignored" '[ -e "$A" ]'
prompt s1 "> budget: off the table for this year" >/dev/null; check "pasted 'budget: off the table' ignored" '[ -e "$A" ]'
prompt s1 "the budget clear-ly exceeds" >/dev/null; check "'budget clear-ly' ignored" '[ -e "$A" ]'
prompt s1 "we allocate a budget: 15% of compute to the ablation runs" >/dev/null; check "prose 'budget: 15% of compute' ignored" '[ "$(jq .cap "$A")" = 14 ]'
prompt s1 "carve,budget: 40%,0.4" >/dev/null; check "CSV ignored" '[ "$(jq .cap "$A")" = 14 ]'
prompt s1 "see https://example.org/grants/budget=25%25-cap-rules" >/dev/null; check "URL ignored" '[ "$(jq .cap "$A")" = 14 ]'
prompt s1 "Personnel budget:  45% ; Equipment 10%" >/dev/null; check "grant line ignored" '[ "$(jq .cap "$A")" = 14 ]'
prompt s1 "Token budget = 50% of context goes to retrieved chunks" >/dev/null; check "slide text ignored" '[ "$(jq .cap "$A")" = 14 ]'
prompt s1 "/token-budget=15" >/dev/null; check "/token-budget=15 sets 15" '[ "$(jq .cap "$A")" = 15 ]'
prompt s1 "budget: 9%." >/dev/null; check "trailing period ok" '[ "$(jq .cap "$A")" = 9 ]'
out=$(prompt s1 "/token-budget check"); check "check handler" 'printf "%s" "$out" | grep -q "spent 0%"'
out=$(prompt s1 "budget: 150%"); check "150 rejected visibly" 'printf "%s" "$out" | grep -q "not set"'
check "150 leaves old cap" '[ "$(jq .cap "$A")" = 9 ]'
out=$(prompt s1 "hello"); check "reminder when active" 'printf "%s" "$out" | grep -q "still active"'
out=$(prompt s2 "hello"); check "no reminder in other session" '[ -z "$out" ]'
prompt s1 "done, budget: off" >/dev/null; check "trailing off clears" '[ ! -e "$A" ]'
out=$(prompt s1 "hello"); check "no reminder when inactive" '[ -z "$out" ]'

# set from the Bash tool uses the env session id
reset_state; cap 23 sX
CLAUDE_CODE_SESSION_ID=s1 bash "$B" set 10 >/dev/null; check "set uses env session id" '[ "$(jq -r .session_id "$A")" = s1 ]'
out=$(bash "$B" set 0); check "set 0 rejected" 'printf "%s" "$out" | grep -q "not set"'

# ladder: cap 10 from 23
reset_state; cap 23; prompt s1 "budget: 10%" >/dev/null
out=$(pre s1 Bash); check "0%: silent" '[ -z "$out" ]'
cap 28; out=$(pre s1 Bash); check "50%: soft warning" 'printf "%s" "$out" | grep -q "50% of the budget"'
check "soft JSON shape" 'printf "%s" "$out" | jq -e ".hookSpecificOutput.hookEventName == \"PreToolUse\"" >/dev/null'
out=$(pre s1 Bash); check "soft once" '[ -z "$out" ]'
out=$(pre s2 Bash); check "other session untouched" '[ -z "$out" ]'
cap 31; out=$(pre s1 Bash); check "80%: hard warning" 'printf "%s" "$out" | grep -q "80% of the budget"'
pre s1 Agent 2>/dev/null; check "80%: Agent denied" '[ $? -eq 2 ]'
pre s1 Bash 2>/dev/null; check "80%: Bash allowed" '[ $? -eq 0 ]'
check "check output" 'bash "$B" check | grep -q "spent 8% | left 2%"'
cap 33
pre s1 Bash "npm test" 2>"$HOME/err"; rc=$?; check "cap: Bash denied w/ reason" '[ $rc -eq 2 ] && grep -q "CAP REACHED" "$HOME/err"'
pre s1 Bash "bash ~/.claude/skills/token-budget/assets/budget.sh check" 2>/dev/null; check "cap: budget.sh check allowed" '[ $? -eq 0 ]'
pre s1 Bash "bash ~/.claude/skills/token-budget/assets/budget.sh off" 2>/dev/null; check "cap: budget.sh off denied" '[ $? -eq 2 ]'
pre s1 Task 2>"$HOME/err"; check "cap: denial counted" 'grep -q "denial 3" "$HOME/err"'
out=$(pre s1 Write); check "cap: Write allowed w/ grace ctx" 'printf "%s" "$out" | grep -q "CAP REACHED"'
for i in $(seq 1 11); do pre s1 Read >/dev/null; done
pre s1 Read 2>/dev/null; check "grace exhausted" '[ $? -eq 2 ]'
check "denied calls did not eat grace" '[ "$(jq .grace_used "$A")" = 12 ]'

# floats and the exact-cap boundary
reset_state; cap 6.4; prompt s1 "budget: 10%" >/dev/null; cap 16.4
pre s1 Bash 2>/dev/null; check "exactly 10.0 spent trips the cap" '[ $? -eq 2 ]'
reset_state; cap 16.4; prompt s1 "budget: 10%" >/dev/null; cap 21.0
check "float display rounded" 'bash "$B" check | grep -q "spent 4.6% | left 5.4%"'

# window roll with NO hook call between the last snapshot and the reset
reset_state; cap 95; prompt s1 "budget: 10%" >/dev/null; cap 98
cap 4 s1 $((RESET+18000)); check "roll carries 3 without a sync" 'bash "$B" check | grep -q "spent 7% | left 3%"'
cap 6 s1 $((RESET+18000)); check "second post-roll snapshot: no double carry" 'bash "$B" check | grep -q "spent 9% | left 1%"'
# jitter on resets_at is not a roll
reset_state; cap 16; prompt s1 "budget: 10%" >/dev/null; cap 20; cap 20 s1 $((RESET+1))
check "1s jitter is same window" 'bash "$B" check | grep -q "spent 4% | left 6%"'
# stale snapshot from another session cannot rewind
reset_state; cap 23; prompt s1 "budget: 10%" >/dev/null; cap 28 s1; cap 25 s2
check "stale rewind ignored (peak)" 'bash "$B" check | grep -q "spent 5%"'
# two rolls = budget expired
reset_state; cap 50; prompt s1 "budget: 10%" >/dev/null; cap 3 s1 $((RESET+18000)); cap 2 s1 $((RESET+36000))
check "budget older than a window expires" 'bash "$B" check | grep -q "budget expired"'
check "expired budget is gone" '[ "$(bash "$B" check)" = "no budget set" ]'

# set before first snapshot, then data arrives
reset_state; out=$(prompt s1 "budget: 20%"); check "no snapshot: set, waiting" 'printf "%s" "$out" | grep -q "No fresh usage snapshot"'
cap 40; pre s1 Bash >/dev/null; cap 45; check "upgrades to enforced from first snapshot" 'bash "$B" check | grep -q "spent 5% | left 15%"'

# parallel light calls at the cap cannot overrun the grace count
reset_state; cap 23; prompt s1 "budget: 10%" >/dev/null; cap 33
for i in $(seq 1 30); do pre s1 Read >/dev/null 2>&1 & done; wait
check "30 parallel Reads at cap: grace_used is exactly 12" '[ "$(jq .grace_used "$A")" = 12 ]'
reset_state; cap 23; prompt s1 "budget: 10%" >/dev/null; cap 28
n=$( (for i in $(seq 1 8); do pre s1 Bash & done; wait) | grep -c "50% of the budget")
check "8 parallel calls: one soft warning" '[ "$n" = 1 ]'
( for i in $(seq 1 20); do bash "$B" off >/dev/null & pre s1 Bash >/dev/null 2>&1 & done; wait ) 2>/dev/null
check "off racing hook-pre never leaves a broken file" '[ ! -e "$A" ] || jq -e . "$A" >/dev/null'

# stale snapshot from a dead window at set time is not a start point
reset_state; cap 90 s1 $(( $(date +%s) - 100 )); out=$(prompt s1 "budget: 15%")
check "dead-window snapshot: waits" 'printf "%s" "$out" | grep -q "No fresh usage snapshot"'
cap 40; pre s1 Bash >/dev/null; cap 44; check "counts from first fresh snapshot" 'bash "$B" check | grep -q "spent 4% | left 11%"'
# unchanged data keeps its timestamp
reset_state; cap 23; jq '.ts = 1000' "$U" > "$U.t" && mv "$U.t" "$U"; cap 23
check "unchanged data keeps old ts" '[ "$(jq .ts "$U")" = 1000 ]'
cap 24; check "changed data refreshes ts" '[ "$(jq .ts "$U")" != 1000 ]'
# check from another session says so
reset_state; cap 23; prompt s1 "budget: 10%" >/dev/null
check "check in another session warns" 'CLAUDE_CODE_SESSION_ID=s2 bash "$B" check | grep -q "another session"'

# malformed state never blocks and never prints garbage
reset_state; cap 23; prompt s1 "budget: 10%" >/dev/null
printf 'garbage' > "$U"; pre s1 Bash 2>/dev/null; check "malformed usage: allow" '[ $? -eq 0 ]'
check "malformed usage: check is clean" '[ "$(bash "$B" check 2>&1)" = "budget 10% set, waiting for a fresh usage snapshot" ]'
printf '[]' > "$A"; cap 23; out=$(bash "$B" check 2>&1); check "malformed active: no budget" '[ "$out" = "no budget set" ]'
out=$(printf '' | bash "$B" hook-pre 2>&1); check "empty hook stdin: silent" '[ -z "$out" ]'
out=$(printf '{}' | bash "$B" hook-prompt 2>&1); check "no session_id: silent" '[ -z "$out" ]'
mkdir -p "$HOME/nojq"; for f in /bin/* /usr/bin/*; do n=$(basename "$f"); [ "$n" = jq ] || ln -sf "$f" "$HOME/nojq/$n"; done
out=$(printf '{"a":1}' | PATH="$HOME/nojq" bash "$B" capture 2>&1); check "no jq: passthrough" '[ "$out" = "{\"a\":1}" ]'
out=$(PATH="$HOME/nojq" bash "$B" set 10 2>&1); check "no jq: set says so" 'printf "%s" "$out" | grep -q "needs jq"'

echo "passed $pass, failed $fail"
case "$T" in /tmp/*|/var/folders/*|/private/*) rm -rf "$T" ;; esac
[ $fail -eq 0 ]
