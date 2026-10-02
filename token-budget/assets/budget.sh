#!/usr/bin/env bash
# token-budget: cap one task to a slice of the 5-hour usage window.
#
# Claude Code only hands rate_limits to the status line, so `capture` sits in
# front of the status-line script and caches the last snapshot. The hooks read
# that cache. Subcommands:
#   capture        stdin passthrough for the statusLine command; caches usage
#   set <pct>      cap this task at <pct> of the window, counted from now
#   check          print where we stand (run it at phase boundaries)
#   off            drop the budget
#   hook-prompt    UserPromptSubmit: parses "budget: 15%" / "/token-budget 15"
#   hook-pre       PreToolUse: warns at 50/80%, denies subagents at 80%,
#                  denies everything but a few light tools once the cap is hit
set -u
DIR="$HOME/.claude/budget"
USAGE="$DIR/usage.json"
# One budget file per session, so a budget set in one Claude window never
# replaces another's. Session ids are uuids; anything else is squashed.
active_for() { printf '%s/active-%s.json' "$DIR" "$(printf '%s' "${1:-none}" | tr -c 'A-Za-z0-9-' '_')"; }
ACTIVE=$(active_for "${CLAUDE_CODE_SESSION_ID:-}")
WARN_SOFT=50       # % of the cap: first warning
WARN_HARD=80       # % of the cap: second warning, no new subagents/workflows
GRACE_CALLS=12     # tool calls allowed after the cap, light tools only
WINDOW_SLOP=900    # resets_at moves by less than this = same window (jitter)
STALE_AFTER=1800   # snapshot older than this: warn, the status line is not running
LIGHT_TOOLS='Read|Write|Edit|MultiEdit|NotebookEdit|Glob|Grep|LS|TodoWrite'
mkdir -p "$DIR"

if ! command -v jq >/dev/null 2>&1; then
    case "${1:-}" in
        capture) cat ;;
        set|check|off) echo "token-budget needs jq (brew install jq)" ;;
    esac
    exit 0
fi

now() { date +%s; }

write_json() {  # write_json <path> <json>  (atomic, never writes an empty file)
    [ -n "$2" ] || return 1
    local tmp="$1.tmp.$$"
    printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$1"
}

# Parallel tool calls run their hooks at the same time. mkdir is atomic on
# every filesystem, so it serves as the lock; macOS has no flock.
LOCK="$DIR/.lock"
lock() {
    local i=0
    until mkdir "$LOCK" 2>/dev/null; do
        i=$((i+1)); [ "$i" -gt 200 ] && { rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null; break; }
        sleep 0.01
    done
}
unlock() { rmdir "$LOCK" 2>/dev/null; }

# A state file that is not a JSON object is treated as absent.
valid_json() { jq -e 'type == "object"' "$1" >/dev/null 2>&1; }
have_usage()  { [ -s "$USAGE" ] && valid_json "$USAGE"; }
have_active() { [ -s "$ACTIVE" ] && valid_json "$ACTIVE"; }
usage_field()  { jq -r "$1" "$USAGE" 2>/dev/null; }
active_field() { jq -r "$1" "$ACTIVE" 2>/dev/null; }

# ---- capture ---------------------------------------------------------------
# usage.json keeps `peak`, the highest used% seen in the current window, so a
# late or stale snapshot from another session can never rewind the count. When
# the window rolls, the old peak moves to prev_peak for the budget to settle.
if [ "${1:-}" = capture ]; then
    input=$(cat; printf x); input=${input%x}
    printf '%s' "$input"
    [ -z "$input" ] && exit 0
    prev='{}'; have_usage && prev=$(cat "$USAGE")
    snap=$(printf '%s' "$input" | jq -c --argjson now "$(now)" --argjson prev "$prev" --argjson slop "$WINDOW_SLOP" '
        select((.rate_limits.five_hour.used_percentage|type) == "number") |
        (.rate_limits.five_hour.used_percentage) as $u |
        (.rate_limits.five_hour.resets_at // 0) as $r |
        (if ($prev.resets_at? // null) == null or (($r - $prev.resets_at) | fabs) < $slop
         then { peak: ([$u, ($prev.peak // 0)] | max), prev_peak: ($prev.prev_peak // 0), prev_resets_at: ($prev.prev_resets_at // 0) }
         else { peak: $u, prev_peak: ($prev.peak // 0), prev_resets_at: $prev.resets_at }
         end) as $w |
        (if ($prev.used? // null) == $u and ($prev.resets_at? // null) == $r then ($prev.ts // $now) else $now end) as $ts |
        { session_id: (.session_id // ""), ts: $ts, used: $u, resets_at: $r,
          peak: $w.peak, prev_peak: $w.prev_peak, prev_resets_at: $w.prev_resets_at,
          seven_day: (.rate_limits.seven_day.used_percentage // null) }' 2>/dev/null)
    [ -n "$snap" ] && write_json "$USAGE" "$snap"
    exit 0
fi

# ---- shared state ----------------------------------------------------------
usage_age() { echo $(( $(now) - $(usage_field '.ts // 0') )); }
same_window() { jq -n "(($1) - ($2)) | fabs < $WINDOW_SLOP"; }  # prints true/false

# Settle the budget against the snapshot. spent = carry + (peak - start).
# Returns 1 if the budget is gone (older than a whole window).
sync_active() {
    have_active && have_usage || return 1
    local b_reset reset p_reset
    b_reset=$(active_field '.resets_at'); reset=$(usage_field '.resets_at'); p_reset=$(usage_field '.prev_resets_at')
    if [ "$(active_field '.unenforced // false')" = true ]; then
        # set before a fresh snapshot existed: start counting at the first one after set_at
        [ "$(usage_field '.ts')" -ge "$(active_field '.set_at')" ] && [ "$reset" -gt "$(now)" ] || return 1
        write_json "$ACTIVE" "$(jq -c --argjson s "$(usage_field '.used')" --argjson r "$reset" \
            '.start=$s | .last_seen=$s | .resets_at=$r | .eff=([.cap, 100 - $s, 1] | sort | .[1]) | del(.unenforced)' "$ACTIVE")"
        b_reset=$reset
    fi
    if [ "$(same_window "$reset" "$b_reset")" = true ]; then
        write_json "$ACTIVE" "$(jq -c --argjson p "$(usage_field '.peak')" '.last_seen=$p' "$ACTIVE")"
    elif [ "$(same_window "$p_reset" "$b_reset")" = true ]; then
        # window rolled once since the budget was set
        write_json "$ACTIVE" "$(jq -c --argjson pp "$(usage_field '.prev_peak')" --argjson p "$(usage_field '.peak')" --argjson r "$reset" \
            '.carry += ($pp - .start) | .start=0 | .last_seen=$p | .resets_at=$r' "$ACTIVE")"
    else
        rm -f "$ACTIVE"; return 1
    fi
}

# eff is the cap actually usable: min(cap, what the window had left at the start)
spent()      { jq -r '(.carry + .last_seen - .start) * 10 | round / 10' "$ACTIVE"; }
cap()        { active_field '.cap'; }
eff()        { active_field '(.eff // .cap) * 10 | round / 10'; }
pct_of_cap() { jq -r '((.carry + .last_seen - .start) * 100 / (.eff // .cap) + 1e-9) | floor' "$ACTIVE"; }
remaining()  { jq -r '((.eff // .cap) - (.carry + .last_seen - .start)) * 10 | round / 10' "$ACTIVE"; }
cap_label()  { if [ "$(eff)" = "$(cap)" ]; then printf '%s%%' "$(cap)"; else printf '%s%% (only %s%% was left in the window)' "$(cap)" "$(eff)"; fi; }

fmt_reset() {
    local r secs; r=$(usage_field '.resets_at'); secs=$(( r - $(now) ))
    [ "$secs" -le 0 ] && { echo "now"; return; }
    printf '%dh %02dm' $(( secs / 3600 )) $(( (secs % 3600) / 60 ))
}

status_line() {
    sync_active || { echo "budget expired: the window it was set in has passed"; return; }
    local age stale=""; age=$(usage_age)
    [ "$age" -gt "$STALE_AFTER" ] && stale=" (no new usage data in that time)"
    printf 'budget: %s of window | spent %s%% | left %s%% | window %s%% used, resets in %s | snapshot %ss old%s\n' \
        "$(cap_label)" "$(spent)" "$(remaining)" "$(usage_field '.used')" "$(fmt_reset)" "$age" "$stale"
}

# ---- set / check / off -----------------------------------------------------
do_set() {  # do_set <pct> <session_id>
    local pct="$1" sid="$2"
    case "$pct" in ''|*[!0-9]*) echo "budget not set: '$pct' is not a whole number 1-100"; return 1 ;; esac
    pct=$((10#$pct))
    if [ "$pct" -lt 1 ] || [ "$pct" -gt 100 ]; then echo "budget not set: percent must be 1-100"; return 1; fi
    if ! have_usage || [ "$(usage_age)" -gt "$STALE_AFTER" ] || [ "$(usage_field '.resets_at')" -le "$(now)" ]; then
        write_json "$ACTIVE" "$(jq -nc --argjson p "$pct" --arg s "$sid" \
            '{cap:$p, start:0, last_seen:0, carry:0, resets_at:0, session_id:$s, set_at:now|floor, warned:[], grace_used:0, denied:0, unenforced:true}')"
        echo "budget set: ${pct}% of the 5-hour window. No fresh usage snapshot yet, counting starts at the next status-line refresh."
        return 0
    fi
    local cur reset; cur=$(usage_field '.used'); reset=$(usage_field '.resets_at')
    write_json "$ACTIVE" "$(jq -nc --argjson p "$pct" --argjson c "$cur" --argjson r "$reset" --arg s "$sid" \
        '{cap:$p, eff:([$p, 100 - $c, 1] | sort | .[1]), start:$c, last_seen:$c, carry:0, resets_at:$r, session_id:$s, set_at:now|floor, warned:[], grace_used:0, denied:0}')"
    local e; e=$(eff)
    if [ "$e" = "$pct" ]; then
        echo "budget set: ${pct}% of the 5-hour window for this task. Window is at ${cur}% now, so stop by $(jq -n "$cur + $pct")%. Resets in $(fmt_reset). Usage from other Claude windows counts too."
    else
        echo "budget set: ${pct}% asked, but the window is at ${cur}% and has only ${e}% left, so the budget is ${e}%. Resets in $(fmt_reset). Usage from other Claude windows counts too."
    fi
}

do_check() {
    have_active || { echo "no budget set"; return; }
    if [ "$(active_field '.unenforced // false')" = true ] && ! sync_active; then
        echo "budget $(cap)% set, waiting for a fresh usage snapshot"; return
    fi
    have_usage || { echo "budget $(cap)% set, waiting for a fresh usage snapshot"; return; }
    status_line
}

case "${1:-}" in
    set)   sid="${3:-${CLAUDE_CODE_SESSION_ID:-}}"
           [ -z "$sid" ] && { echo "budget not set: no session id (run it from inside Claude Code)"; exit 0; }
           ACTIVE=$(active_for "$sid"); do_set "${2:-}" "$sid"; exit 0 ;;
    off)   lock; rm -f "$ACTIVE"; unlock; echo "budget cleared"; exit 0 ;;
    check) do_check; exit 0 ;;
esac

# ---- hooks -----------------------------------------------------------------
hook_in=$(cat)
sid=$(printf '%s' "$hook_in" | jq -r '.session_id // ""' 2>/dev/null)
[ -z "$sid" ] && exit 0
ACTIVE=$(active_for "$sid")

if [ "${1:-}" = hook-prompt ]; then
    prompt=$(printf '%s' "$hook_in" | jq -r '.prompt // ""' 2>/dev/null)
    # Subagent reports and pasted blocks arrive through this hook too, so the
    # directive only counts at the start of the prompt, at its end, or on a
    # line of its own. "my grant budget: 15% went to travel" never matches.
    case "$prompt" in *"[Subagent hand-back]"*|*"<task-notification>"*) exit 0 ;; esac
    # Pasted text is quoted material, never a directive.
    case "$prompt" in *"<pasted_content"*)
        prompt=$(printf '%s' "$prompt" | perl -0pe 's/<pasted_content\b[^>]*>.*?<\/pasted_content\b[^>]*>//gs') ;;
    esac
    # budgets from sessions nobody has touched in two windows are dead weight
    find "$DIR" -name 'active-*.json' -mmin +600 -delete 2>/dev/null
    directive=$(printf '%s\n' "$prompt" | tr 'A-Z' 'a-z' | awk -v D='(budget|/token-budget)[ :=]*(of )?(off|check|status|[0-9]+ *(%|percent)?)|[0-9]+ *(%|percent) budget' '
        { gsub(/^[ \t]+|[ \t.!,]+$/, ""); sub(/,?[ \t]+(please|pls|thanks|thank you)$/, "") }
        NR == 1 && match($0, "^(" D ")")      { print substr($0, 1, RLENGTH); exit }
        match($0, "^(" D ")$")                 { print; exit }
        match($0, "[ ,;(]+(" D ")$")           { print substr($0, RSTART, RLENGTH); exit }
    ')
    [ -z "$directive" ] && {
        if have_active && [ "$(active_field '.session_id')" = "$sid" ] && have_usage; then
            echo "[token-budget] still active. $(status_line)"
        fi
        exit 0
    }
    case "$directive" in
        *off)           lock; rm -f "$ACTIVE"; unlock; echo "[token-budget] budget cleared."; exit 0 ;;
        *check|*status) echo "[token-budget] $(do_check)"; exit 0 ;;
    esac
    pct=$(printf '%s' "$directive" | grep -Eo '[0-9]+' | head -1)
    msg=$(do_set "$pct" "$sid")
    echo "[token-budget] $msg"
    case "$msg" in "budget set"*)
        echo "[token-budget] Load the token-budget skill before doing anything else. Run 'bash ~/.claude/skills/token-budget/assets/budget.sh check' at every phase boundary." ;;
    esac
    exit 0
fi

if [ "${1:-}" = hook-pre ]; then
    have_active || exit 0
    [ "$(active_field '.session_id')" = "$sid" ] || exit 0
    have_usage || exit 0
    lock; trap unlock EXIT
    sync_active || exit 0
    tool=$(printf '%s' "$hook_in" | jq -r '.tool_name // ""')
    p=$(pct_of_cap)
    ctx=""
    if [ "$p" -ge 100 ]; then
        # `budget.sh check` stays reachable after the cap; `off` is the user's call
        printf '%s' "$hook_in" | jq -e '.tool_name == "Bash" and (.tool_input.command | tostring | test("budget\\.sh +check"))' >/dev/null 2>&1 && exit 0
        used=$(active_field '.grace_used')
        if printf '%s' "$tool" | grep -Eq "^($LIGHT_TOOLS)$" && [ "$used" -lt "$GRACE_CALLS" ]; then
            write_json "$ACTIVE" "$(jq -c '.grace_used += 1' "$ACTIVE")"
            ctx="[token-budget] CAP REACHED: spent $(spent)% of a $(cap)% budget. $(( GRACE_CALLS - used - 1 )) light tool calls left. Write the handoff now and end the turn."
        else
            write_json "$ACTIVE" "$(jq -c '.denied += 1' "$ACTIVE")"
            echo "[token-budget] CAP REACHED: spent $(spent)% of the $(cap)% budget set for this task. '$tool' is blocked (denial $(active_field '.denied')). Every retry costs a round-trip and will be denied too. End the turn now with the handoff: what is done, what is not, where to resume. Only the user can lift the cap, by writing 'budget: off'." >&2
            exit 2
        fi
    elif [ "$p" -ge "$WARN_HARD" ]; then
        if printf '%s' "$tool" | grep -Eq '^(Agent|Task|Workflow)$'; then
            echo "[token-budget] ${p}% of the budget is spent. No new subagents or workflows past ${WARN_HARD}%: do the rest inline or wrap up." >&2
            exit 2
        fi
        if ! jq -e '.warned | index("hard")' "$ACTIVE" >/dev/null; then
            write_json "$ACTIVE" "$(jq -c '.warned += ["hard"]' "$ACTIVE")"
            ctx="[token-budget] ${p}% of the budget is spent ($(remaining)% of the window left). Finish the current step, verify it, and start the handoff. No new scope."
        fi
    elif [ "$p" -ge "$WARN_SOFT" ]; then
        if ! jq -e '.warned | index("soft")' "$ACTIVE" >/dev/null; then
            write_json "$ACTIVE" "$(jq -c '.warned += ["soft"]' "$ACTIVE")"
            ctx="[token-budget] ${p}% of the budget is spent. Run budget.sh check and decide now: can the core deliverable be done in what is left? If not, cut scope to what can."
        fi
    fi
    [ -n "$ctx" ] && jq -nc --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
    exit 0
fi

exit 0
