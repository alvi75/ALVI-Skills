#!/usr/bin/env bash
# Fetches the LIVE usage-credit balance for a claude.ai login and caches it.
# Run detached by statusline.sh; never called on the render path.
#
#   credit-balance.sh            refresh the cache if the lock is free
#   credit-balance.sh --print    refresh, then print the cache line and the raw
#                                responses (for a first-time check / debugging)
#
# Two endpoints, both the ones Claude Code's own /usage and /usage-credits use
# (read out of the CLI binary, v2.1.259 - not documented anywhere):
#   GET /api/oauth/organizations/<org>/prepaid/credits
#       -> { amount: <cents>, currency, auto_reload_settings: { enabled }, ... }
#   GET /api/oauth/usage
#       -> { extra_usage: { is_enabled, monthly_limit: <cents|null>,
#                           used_credits: <cents|null>, utilization, currency } }
#
# Auth is the same OAuth token Claude Code holds for you: macOS Keychain item
# "Claude Code-credentials", or ~/.claude/.credentials.json elsewhere. The token
# is held in a shell variable, sent only to api.anthropic.com, and never written
# anywhere - not to the cache, not to --print output.
#
# Cache: one line, U+007C separated, at ~/.claude/credit-live (mode 600):
#   status|epoch|balance_c|used_c|limit_c|enabled|autoreload|total_c|drop_epoch|
#   currency|reason|decimals
#   status   ok | noauth | expired | nocurl | nojq | http_<code> | badjson
#   *_c      integer MINOR units; empty when the server sent null
#   enabled  1/0 = extra_usage.is_enabled
#   total_c  the bar's reference: balance after the most recent top-up. Bumped
#            automatically when the balance rises; TOTAL in credit-config overrides.
#   drop_epoch  last time the balance was seen to FALL - "credits in use" signal.
#   reason   extra_usage.disabled_reason, e.g. out_of_credits. A zero balance and
#            a failed fetch both print "$0.00"; this is what tells them apart.
#   decimals extra_usage.decimal_places - minor units per unit is 10^decimals.
#            USD is 2; a zero-decimal currency (JPY) is 0, and dividing by 100
#            there would be wrong by 100x.
# On any failure the numeric fields of the previous good line are carried
# forward so the renderer can still show them, marked stale.
set -uo pipefail
# An inherited SHELLOPTS=xtrace would echo every line - token included - to
# stderr, and `ccredit refresh` shows stderr. Switch tracing off unconditionally.
set +x

CACHE="$HOME/.claude/credit-live"
CFG="$HOME/.claude/credit-config"
PRINT=0; [ "${1:-}" = "--print" ] && PRINT=1

# ---- previous state (carried forward on failure; needed for drop/top-up detection)
p_status=""; p_ts=0; p_bal=""; p_used=""; p_lim=""; p_en=""; p_ar=""; p_total=""; p_drop=""; p_cur=""
p_reason=""; p_dp=""
if [ -f "$CACHE" ]; then
    IFS='|' read -r p_status p_ts p_bal p_used p_lim p_en p_ar p_total p_drop p_cur p_reason p_dp < "$CACHE" 2>/dev/null
fi
# Integer of at most 15 digits: bash 3.2 arithmetic wraps silently past 2^63,
# and `[ -gt ]` errors out, so a 20-digit field would be kept forever.
isint() { case "${1:-}" in ''|*[!0-9]*|????????????????*) return 1 ;; *) return 0 ;; esac; }
# Every field is re-validated on load. Anything re-emitted after a FAILED fetch
# comes from here, so a hostile or corrupt line must not survive one.
isint "$p_ts"    || p_ts=0
isint "$p_bal"   || p_bal=""
isint "$p_used"  || p_used=""
isint "$p_lim"   || p_lim=""
isint "$p_total" || p_total=""
isint "$p_drop"  || p_drop=""
case "$p_en" in 0|1) ;; *) p_en="" ;; esac
case "$p_ar" in 0|1) ;; *) p_ar="" ;; esac
p_cur=$(printf '%s' "$p_cur" | tr -cd 'A-Za-z' | head -c 3)
p_reason=$(printf '%s' "$p_reason" | tr -cd 'a-z_' | head -c 32)
case "$p_dp" in 0|1|2|3|4) ;; *) p_dp="" ;; esac

# Atomic write: the status line reads this file on every render, and '>'
# truncates before it writes, so a reader could otherwise catch it half-written.
emit() {   # status bal used lim en ar total drop cur reason decimals
    _t="$CACHE.tmp.$$"
    umask 077
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$1" "$(date +%s)" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" > "$_t" 2>/dev/null &&
        mv -f "$_t" "$CACHE" 2>/dev/null
    rm -f "$_t" 2>/dev/null
    if [ "$PRINT" = 1 ]; then
        printf 'cache: %s\n' "$(cat "$CACHE" 2>/dev/null)"
        # Only JSON is echoed, and only the fields this meter reads. An error page
        # (HTML, a gateway banner) is summarised by size - the usage body can
        # carry every plan window, so it is never dumped raw.
        [ -n "${RAW_CREDITS:-}" ] && printf -- '--- prepaid/credits (HTTP %s): %s\n' "${CODE1:-?}" \
            "$(printf '%s' "$RAW_CREDITS" | jq -c '{amount,currency,auto_reload_settings,expiry_policy_months}' 2>/dev/null || printf '(non-JSON body, %s bytes)' "${#RAW_CREDITS}")"
        [ -n "${RAW_USAGE:-}" ]   && printf -- '--- usage (HTTP %s): %s\n' "${CODE2:-?}" \
            "$(printf '%s' "$RAW_USAGE" | jq -c '{extra_usage}' 2>/dev/null || printf '(non-JSON body, %s bytes)' "${#RAW_USAGE}")"
    fi
    exit 0
}
fail() { emit "$1" "$p_bal" "$p_used" "$p_lim" "$p_en" "$p_ar" "$p_total" "$p_drop" "$p_cur" "$p_reason" "$p_dp"; }

# One fetch at a time. Every open session spawns this when the cache goes stale,
# so without a gate N sessions expiring together fire N requests. mkdir is the
# atomic test-and-set; the holder then drops a claim file named <pid>.<epoch>
# inside. A claim older than 90 s (a healthy run measures ~17 s, a Keychain
# prompt is capped at 20 s below) is assumed dead. Reclaiming removes ONLY
# stale claims, then rmdir - which fails if a fresh claim is inside. Earlier
# variants ("rmdir then mkdir", "rename away", "remove what ls showed") all let
# a late reclaimer destroy a brand-new lock: measured 2-4 concurrent fetchers
# from 8 starters. The epoch in the claim name is what makes stale-vs-fresh
# decidable at removal time rather than at observation time. After taking the
# lock the holder re-checks it holds the only claim; two winners in the
# microsecond window both back out and the next render retries.
LOCK="$CACHE.lock"
# The lock is built as a temp dir that already holds the claim, then renamed
# into place: rename is atomic, so the lock never exists empty and a stale
# reclaim's rmdir can never hit a winner between mkdir and claim. If the lock
# already exists, mv puts the temp dir INSIDE it - detectable, and it means we lost.
take_lock() {
    # Pre-check: a losing mv into an existing lock would bump its mtime, and an
    # EMPTY lock dir is aged by mtime - so a loser must not touch a held lock.
    [ -d "$LOCK" ] && return 1
    _tmp="$LOCK.claim.$$"
    rm -rf "$_tmp" 2>/dev/null
    mkdir "$_tmp" 2>/dev/null || return 1
    : > "$_tmp/$$.$(date +%s)" 2>/dev/null
    mv "$_tmp" "$LOCK" 2>/dev/null || { rm -rf "$_tmp" 2>/dev/null; return 1; }
    if [ -d "$LOCK/${_tmp##*/}" ]; then rm -rf "$LOCK/${_tmp##*/}" 2>/dev/null; return 1; fi
    if [ "$(ls -p "$LOCK" 2>/dev/null | grep -vc /)" -ne 1 ]; then
        rm -f "$LOCK/$$".* 2>/dev/null; rmdir "$LOCK" 2>/dev/null; return 1
    fi
}
# Age of the newest claim; an empty lock dir falls back to its own mtime.
lock_age() {
    _n=$(ls "$LOCK" 2>/dev/null | awk -F. '$2 ~ /^[0-9]+$/ { if ($2+0 > m) m=$2+0 } END { print m+0 }')
    if [ "${_n:-0}" -gt 0 ]; then echo $(( $(date +%s) - _n ))
    else echo $(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null || echo 0) )); fi
}
if ! take_lock; then
    if [ "$PRINT" = 1 ]; then
        # Interactive: wait for an in-flight fetch rather than exiting silently.
        _w=0; while [ -d "$LOCK" ] && [ "$_w" -lt 30 ] && [ "$(lock_age)" -lt 90 ]; do sleep 1; _w=$((_w+1)); done
    fi
    if ! take_lock; then
        [ -d "$LOCK" ] && [ "$(lock_age)" -lt 90 ] && exit 0
        _now=$(date +%s)
        for _e in $(ls "$LOCK" 2>/dev/null); do
            _ep=${_e##*.}
            case "$_ep" in
                ''|*[!0-9]*) rm -rf "$LOCK/$_e" 2>/dev/null ;;                   # not a claim: junk
                *) [ $(( _now - _ep )) -ge 90 ] && rm -f "$LOCK/$_e" 2>/dev/null ;;
            esac
        done
        rmdir "$LOCK" 2>/dev/null || exit 0     # a fresh claim is inside: someone else won
        take_lock || exit 0
    fi
fi
# Release only this process's claim; rmdir succeeds only when nobody else holds one.
trap 'rm -f "$LOCK/$$".* 2>/dev/null; rmdir "$LOCK" 2>/dev/null || { [ "$(ls -p "$LOCK" 2>/dev/null | grep -vc /)" -eq 0 ] && rm -rf "$LOCK" 2>/dev/null; }' EXIT INT TERM HUP

command -v curl >/dev/null 2>&1 || fail nocurl
command -v jq   >/dev/null 2>&1 || fail nojq

# ---- credentials: never echoed, never written
CREDS=""
if [ "$(uname -s)" = Darwin ] && command -v security >/dev/null 2>&1; then
    # A locked Keychain (or the first run, before "Always Allow") pops a dialog
    # and blocks; cap it so a detached fetcher cannot hang under the lock.
    if command -v perl >/dev/null 2>&1; then
        CREDS=$(perl -e 'alarm 20; exec @ARGV' -- security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    else
        CREDS=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    fi
fi
[ -z "$CREDS" ] && [ -f "$HOME/.claude/.credentials.json" ] && CREDS=$(cat "$HOME/.claude/.credentials.json" 2>/dev/null)
[ -n "$CREDS" ] || fail noauth
TOKEN=$(printf '%s' "$CREDS" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
EXP=$(printf '%s' "$CREDS" | jq -r '.claudeAiOauth.expiresAt // 0' 2>/dev/null)
unset CREDS
[ -n "$TOKEN" ] || fail noauth
# expiresAt is epoch milliseconds. Claude Code refreshes the token itself while
# it runs; this script only reports, it never refreshes.
isint "$EXP" || EXP=0
[ "$EXP" -gt 0 ] && [ $(( EXP / 1000 )) -le "$(date +%s)" ] && fail expired

ORG=$(jq -r '.oauthAccount.organizationUuid // empty' "$HOME/.claude.json" 2>/dev/null)
case "$ORG" in *[!0-9a-fA-F-]*|'') fail noauth ;; esac

# --orgs: which organization holds the money. An account can carry more than one
# balance - the claude.ai usage-credit pool and a Console prepaid pool are
# different orgs with different amounts - so this asks every org the login can
# see and prints what each one reports. Diagnostic only: writes no cache.
if [ "${1:-}" = "--orgs" ]; then
    get_orgs() {
        curl -sS --max-time 8 "https://api.anthropic.com/api/oauth/organizations" \
            -H "Authorization: Bearer $TOKEN" -H 'anthropic-beta: oauth-2025-04-20' \
            -H 'Content-Type: application/json' -H 'User-Agent: cc-statusline-credit/2.0' 2>/dev/null
    }
    printf 'login org (from ~/.claude.json): %s\n\n' "$ORG"
    _o=$(get_orgs)
    _list=$(printf '%s' "$_o" | jq -r '(if type=="array" then . else (.organizations // .data // []) end)
                    | .[] | [(.uuid // .id // ""), (.name // ""), (.organization_type // .billing_type // "")] | @tsv' 2>/dev/null)
    [ -z "$_list" ] && _list=$(printf '%s\t%s\t%s' "$ORG" "(list unavailable)" "")
    printf '%s\n' "$_list" | while IFS="$(printf '\t')" read -r _u _n _t; do
        case "$_u" in ''|*[!0-9a-fA-F-]*) continue ;; esac
        get "/api/oauth/organizations/$_u/prepaid/credits"
        printf 'org %s  %s %s\n    prepaid/credits HTTP %s -> %s\n' "$_u" "$_n" "$_t" "$CODE" \
            "$(printf '%s' "$BODY" | jq -c '{amount,currency,auto_reload_settings}' 2>/dev/null || printf '(non-JSON, %s bytes)' "${#BODY}")"
    done
    exit 0
fi

get() {   # $1 path -> sets BODY and CODE
    _r=$(curl -sS --max-time 8 -w $'\n%{http_code}' "https://api.anthropic.com$1" \
            -H "Authorization: Bearer $TOKEN" \
            -H 'anthropic-beta: oauth-2025-04-20' \
            -H 'Content-Type: application/json' \
            -H 'User-Agent: cc-statusline-credit/2.0' 2>/dev/null)
    CODE=${_r##*$'\n'}
    BODY=${_r%$'\n'*}
    case "$CODE" in ''|*[!0-9]*) CODE=000 ;; esac
}

get "/api/oauth/organizations/$ORG/prepaid/credits"; CODE1=$CODE; RAW_CREDITS=$BODY
[ "$CODE1" = 200 ] || fail "http_$CODE1"
BAL=$(printf '%s' "$RAW_CREDITS" | jq -r 'if (.amount|type)=="number" then (.amount|floor|tostring) else empty end' 2>/dev/null)
isint "$BAL" || fail badjson
AR=$(printf '%s' "$RAW_CREDITS" | jq -r 'if .auto_reload_settings.enabled==true then 1 else 0 end' 2>/dev/null)
CUR=$(printf '%s' "$RAW_CREDITS" | jq -r '.currency // "USD"' 2>/dev/null | tr -cd 'A-Za-z' | head -c 3)

get "/api/oauth/usage"; CODE2=$CODE; RAW_USAGE=$BODY
USED=""; LIM=""; EN=""; REASON=""; DP=""
if [ "$CODE2" = 200 ]; then
    USED=$(printf '%s' "$RAW_USAGE" | jq -r 'if (.extra_usage.used_credits|type)=="number" then (.extra_usage.used_credits|floor|tostring) else empty end' 2>/dev/null)
    LIM=$(printf '%s'  "$RAW_USAGE" | jq -r 'if (.extra_usage.monthly_limit|type)=="number" then (.extra_usage.monthly_limit|floor|tostring) else empty end' 2>/dev/null)
    EN=$(printf '%s'   "$RAW_USAGE" | jq -r 'if .extra_usage.is_enabled==true then 1 elif .extra_usage.is_enabled==false then 0 else empty end' 2>/dev/null)
    # Why extra usage is off. "out_of_credits" is the one worth showing: a $0.00
    # balance otherwise looks exactly like a fetch that failed.
    REASON=$(printf '%s' "$RAW_USAGE" | jq -r '.extra_usage.disabled_reason // empty' 2>/dev/null | tr -cd 'a-z_' | head -c 32)
    DP=$(printf '%s'     "$RAW_USAGE" | jq -r 'if (.extra_usage.decimal_places|type)=="number" then (.extra_usage.decimal_places|floor|tostring) else empty end' 2>/dev/null)
fi
isint "$USED" || USED=""
isint "$LIM"  || LIM=""
case "$DP" in 0|1|2|3|4) ;; *) DP="$p_dp" ;; esac
unset TOKEN

# ---- top-up / drop detection against the previous good balance
NOW=$(date +%s)
TOTAL="$p_total"; DROP="$p_drop"
if [ -n "$p_bal" ]; then
    if   [ "$BAL" -gt "$p_bal" ]; then TOTAL="$BAL"        # recharge landed: bar restarts from here
    elif [ "$BAL" -lt "$p_bal" ]; then DROP="$NOW"; fi     # credits are being consumed right now
fi
[ -z "$TOTAL" ] || [ "$TOTAL" -lt "$BAL" ] && TOTAL="$BAL"
# A hand-set TOTAL in credit-config wins (e.g. "I bought $40, meter against that").
# Whole line must be a plain decimal: a prefix match turned TOTAL=1e5 into $1.
if [ -f "$CFG" ]; then
    _cfg_total=$(sed -n 's/^TOTAL="\{0,1\}\([0-9]\{1,9\}\(\.[0-9]\{1,2\}\)\{0,1\}\)"\{0,1\}[[:space:]]*$/\1/p' "$CFG" 2>/dev/null | tr -d '\r' | head -1)
    [ -n "$_cfg_total" ] && TOTAL=$(awk -v t="$_cfg_total" 'BEGIN{printf "%d", t*100+0.5}')
fi

emit ok "$BAL" "$USED" "$LIM" "$EN" "$AR" "$TOTAL" "$DROP" "${CUR:-USD}" "$REASON" "$DP"
