#!/usr/bin/env bash
# Claude Code status line (macOS / Linux / Git Bash). Requires jq.
#
#   --layout meters    (default)  two rate-limit meters, like the claude.ai composer footer
#   --layout context              one context-window meter with token counts
#
#   ◆ Opus 5  High  my-project  ⎇ main  ctx 13% · 128k/1M
#   Session: 16% · resets in 1h 31m  ▕██░░░░░░░░░░▏  ▕█░░░░░░░░░░░▏  Weekly: 8% · resets in 4d 22h
#
# Install jq:  brew install jq  |  apt install jq  |  winget install --id jqlang.jq
# chmod +x this file, then in settings.json:
#   "statusLine": { "type": "command", "command": "~/.claude/statusline.sh",
#                   "refreshInterval": 60 }
#
# refreshInterval is what keeps the countdowns moving in EVERY open session,
# including ones you are not typing in.
#
# No dollar figure by design: cost.total_cost_usd is a client-side estimate of
# what the API would have charged. On a subscription nobody pays it.
#
# The one dollar figure that IS real: usage credits on a claude.ai login. When
# they are being drawn on, line 2 becomes a live balance meter instead:
#   Credits: $0.35 left of $40.00  ▕████████████▏  $39.65 used · month $39.65
# (fetched by credit-balance.sh, never on the render path - see that file).

LAYOUT=meters
while [ $# -gt 0 ]; do
    case "$1" in
        --layout) LAYOUT="$2"; shift 2 ;;
        --layout=*) LAYOUT="${1#*=}"; shift ;;
        *) shift ;;
    esac
done
case "$LAYOUT" in meters|context) ;; *) LAYOUT=meters ;; esac

# Rule 1: empty stdout blanks the bar just as silently as a non-zero exit, so
# every unparseable-input path prints this instead of nothing.
FALLBACK=$'\342\227\206'" claude"
input=$(cat)
[ -z "$input" ] && { printf '%s\n' "$FALLBACK"; exit 0; }
command -v jq >/dev/null 2>&1 || { printf '%s\n' "status line needs jq - see ~/.claude/statusline.sh"; exit 0; }

# One jq call - each extra process spawn costs ~85ms on Windows, ~5ms elsewhere.
#
# Delimiter is U+001F (unit separator), NOT a tab, and NOT U+0001: bash 3.2
# (macOS /bin/bash) reserves 0x01 as CTLESC internally and silently eats it,
# so a 0x01-delimited line comes back as one field. Emitted as a jq 
# escape rather than a literal byte so it survives copying/zipping. Tab is an IFS *whitespace* character, so with
# IFS=$'\t' bash collapses runs of tabs into one separator and every empty field
# shifts all later fields left - an absent .effort.level would land the session
# id in the effort slot. A non-whitespace IFS preserves empty fields exactly.
SEP=$'\037'
IFS="$SEP" read -r MODEL DIR CTXPCT USED SIZE MS COST EFFORT FAST P5 R5 P7 R7 PS RS SID XUE XUU XUL <<EOF
$(printf '%s' "$input" | jq -j '[
  (.model.display_name // "claude"),
  (.workspace.current_dir // .cwd // ""),
  ((.context_window.used_percentage // 0)),
  (.context_window.total_input_tokens // 0),
  (.context_window.context_window_size // 0),
  (.cost.total_duration_ms // 0),
  (.cost.total_cost_usd // 0),
  (.effort.level // ""),
  (if .fast_mode then "fast" else "" end),
  (.rate_limits.five_hour.used_percentage // ""),
  (.rate_limits.five_hour.resets_at // ""),
  (.rate_limits.seven_day.used_percentage // ""),
  (.rate_limits.seven_day.resets_at // ""),
  (.rate_limits.spend_limit.used_percentage // ""),
  (.rate_limits.spend_limit.resets_at // ""),
  (.session_id // "nosession"),
  (if .rate_limits.extra_usage.is_enabled == true then 1 elif .rate_limits.extra_usage.is_enabled == false then 0 else "" end),
  (.rate_limits.extra_usage.used_credits // ""),
  (.rate_limits.extra_usage.monthly_limit // "")
] | map(tostring) | join("\u001f")' 2>/dev/null)
EOF
[ -z "$MODEL" ] && { printf '%s\n' "$FALLBACK"; exit 0; }

E=$'\033'
R="$E[0m"; DIM="$E[2m"; CYAN="$E[36m"; GREEN="$E[32m"; YEL="$E[33m"; MAG="$E[35m"
case "$(sed -n 's/.*"theme"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HOME/.claude/settings.json" 2>/dev/null)" in
    *light*) FILL="$E[38;5;26m";  TRACK="$E[38;5;252m"; LBL="$E[38;5;240m"
             AMBER="$E[38;5;130m"; RED="$E[38;5;124m"; WHITE="$E[38;5;232m" ;;
    *)       FILL="$E[38;5;39m";  TRACK="$E[38;5;238m"; LBL="$E[38;5;245m"
             AMBER="$E[38;5;214m"; RED="$E[38;5;203m"; WHITE="$E[97m" ;;
esac

METER_W=12
RIGHT_PAD=6
COLS=${COLUMNS:-0}
case "$COLS" in ''|*[!0-9]*) COLS=100 ;; esac
[ "$COLS" -le 0 ] && COLS=100
DOT=$'\302\267'   # U+00B7

# integer part of a possibly-decimal, possibly-garbage field
int() { local v="${1%%.*}"; case "$v" in ''|*[!0-9-]*) echo 0 ;; *) echo "$v" ;; esac; }
clamp() { local n; n=$(int "$1"); [ "$n" -lt 0 ] && n=0; [ "$n" -gt 100 ] && n=100; echo "$n"; }
# Same clamp but keeps the fraction, for the meter. The label floors; the bar
# must not, or 37.5% of 12 cells rounds down and disagrees with the PowerShell twin.
clampf() {
    case "$1" in ''|*[!0-9.-]*) echo 0; return ;; esac
    awk -v v="$1" 'BEGIN{ if(v<0) v=0; if(v>100) v=100; print v }'
}

fmt_tok() { awk -v n="$1" 'BEGIN{ if(n>=1000000){ v=n/1000000; if(v==int(v)) printf "%dM",v; else printf "%.1fM",v } else if(n>=1000) printf "%dk", n/1000; else printf "%d", n }'; }

fmt_reset() {
    case "$1" in ''|*[!0-9]*) return ;; esac
    local secs=$(( $1 - $(date +%s) ))
    if [ "$secs" -le 0 ]; then echo "resetting"; return; fi
    local d=$(( secs / 86400 )) h=$(( (secs % 86400) / 3600 )) m=$(( (secs % 3600) / 60 ))
    if [ "$d" -ge 1 ]; then echo "${d}d ${h}h"
    elif [ "$h" -ge 1 ]; then echo "${h}h ${m}m"
    else echo "${m}m"; fi
}

# $1 pct (may be fractional), $2 width. Away-from-zero rounding done in awk: the
# fraction has to survive to here, or 37.5% of 12 cells rounds 4 instead of 5 and
# the bash and PowerShell versions disagree.
meter() {
    local pct=$1 w=$2 f head='' col pcti
    [ "$w" -lt 1 ] && w=1
    case "$pct" in ''|*[!0-9.]*) pct=0 ;; esac
    f=$(awk -v p="$pct" -v w="$w" 'BEGIN{ f=int(p*w/100+0.5); if(f>w) f=w; if(f<0) f=0; print f }')
    pcti=${pct%%.*}; case "$pcti" in ''|*[!0-9]*) pcti=0 ;; esac
    if [ "$pcti" -ge 90 ]; then col="$RED"
    elif [ "$pcti" -ge 75 ]; then col="$AMBER"
    else col="$FILL"; fi
    # Sub-cell but nonzero: a 1/4 sliver, not a whole block (a 17x overstatement
    # at 12 cells). U+258E deliberately - U+258F is already the closing bracket.
    if [ "$f" -eq 0 ] && [ "$(awk -v p="$pct" 'BEGIN{print (p>0)?1:0}')" = 1 ]; then head=$'\342\226\216'; fi
    local body='' i=0
    while [ $i -lt $f ]; do body="$body"$'\342\226\210'; i=$((i+1)); done
    local rest=$(( w - f )); [ -n "$head" ] && rest=$(( rest - 1 ))
    local pad='' j=0
    while [ $j -lt $rest ]; do pad="$pad"$'\342\226\221'; j=$((j+1)); done
    printf '%s%s%s%s%s%s%s%s%s' "$TRACK" $'\342\226\225' "$R" "$col$body$head" "$TRACK" "$pad" "$R" "$TRACK" $'\342\226\217'"$R"
}

# ---- live usage-credit balance (claude.ai login) ----
# credit-balance.sh keeps ~/.claude/credit-live fresh. This reads ONLY what it
# already cached and spawns it detached when that is older than 60 s, so the
# render path never waits on the network. Fields are documented in that file.
LIVE_F="$HOME/.claude/credit-live"
CRMODE=auto; CRWIN=600; LEGACY=0; CRSRC=live; CRHINT=0
if [ -f "$HOME/.claude/credit-config" ]; then
    # One awk, not sed+sed+grep: this runs on every render. Quotes and CR are
    # tolerated. BALANCE_AT marks the hand-anchored (API-key) meter; MODE/TOTAL
    # alone do not.
    IFS='|' read -r _m _w LEGACY _s CRHINT <<EOF
$(awk -F= '{ sub(/\r$/,""); v=$2; gsub(/^["[:space:]]+|["[:space:]]+$/,"",v) }
    $1=="MODE" && v ~ /^(auto|credits|quota)$/ { m=v }
    $1=="ACTIVE_WINDOW" && v ~ /^[0-9]{1,9}$/ { w=v }
    $1=="SOURCE" && v ~ /^(live|manual)$/ { s=v }
    $1=="HINT" && v ~ /^(on|1|true|yes)$/ { h=1 }
    $1=="BALANCE_AT" { l=1 }
    END { printf "%s|%s|%d|%s|%d", m, w, l, s, h }' "$HOME/.claude/credit-config" 2>/dev/null)
EOF
    [ -n "$_m" ] && CRMODE="$_m"
    [ -n "$_w" ] && CRWIN="$_w"
    [ -n "$_s" ] && CRSRC="$_s"
    case "$LEGACY" in 1) ;; *) LEGACY=0 ;; esac
    case "$CRHINT" in 1) ;; *) CRHINT=0 ;; esac
fi
LIVE_OK=0; LIVE_STALE=1; LIVE_AGE=999999
LST=""; LBAL=""; LUSED=""; LLIM=""; LEN=""; LAR=""; LTOT=""; LDROP=""; LCUR=""; LWHY=""; LDP=""
if [ -f "$LIVE_F" ]; then
    IFS='|' read -r LST lts LBAL LUSED LLIM LEN LAR LTOT LDROP LCUR LWHY LDP < "$LIVE_F" 2>/dev/null
    LIVE_AGE=$(( $(date +%s) - $(int "${lts:-0}") ))
    [ "$LIVE_AGE" -lt 0 ] && LIVE_AGE=0
    # Integers in cents (at most 15 digits - bash arithmetic wraps past 2^63)
    # or nothing. A malformed field must not become "$0 left".
    case "$LBAL"  in ''|*[!0-9]*|????????????????*) LBAL=""  ;; esac
    case "$LUSED" in ''|*[!0-9]*|????????????????*) LUSED="" ;; esac
    case "$LLIM"  in ''|*[!0-9]*|????????????????*) LLIM=""  ;; esac
    case "$LTOT"  in ''|*[!0-9]*|????????????????*) LTOT=""  ;; esac
    case "$LDROP" in ''|*[!0-9]*|????????????????*) LDROP="" ;; esac
    case "$LEN"   in 0|1) ;; *) LEN="" ;; esac
    case "$LDP"   in 0|1|2|3|4) ;; *) LDP=2 ;; esac
    LWHY=$(printf '%s' "$LWHY" | tr -cd 'a-z_' | head -c 32)
    [ -n "$LBAL" ] && LIVE_OK=1
    # Bare (unmarked) only while the last SUCCESSFUL fetch is under 5 minutes old.
    [ "$LST" = ok ] && [ "$LIVE_AGE" -lt 300 ] && LIVE_STALE=0
fi
# The payload may carry extra_usage itself (undocumented, v2.1.259 schema);
# use it only to fill gaps the fetcher left.
[ -z "$LEN" ]   && case "$XUE" in 0|1) LEN="$XUE" ;; esac
[ -z "$LUSED" ] && case "$XUU" in ''|*[!0-9.]*) ;; *) LUSED=$(int "$XUU") ;; esac
[ -z "$LLIM" ]  && case "$XUL" in ''|*[!0-9.]*) ;; *) LLIM=$(int "$XUL") ;; esac
# Refresh cadence: 60 s normally, 10 min after an auth-shaped failure so a
# logged-out machine is not polled every render.
_need=60; case "$LST" in noauth|expired|nocurl|nojq) _need=600 ;; esac
if [ "$LAYOUT" = meters ] && [ "$CRMODE" != quota ] && [ "$CRSRC" != manual ] && [ "$LIVE_AGE" -ge "$_need" ] && [ -x "$HOME/.claude/credit-balance.sh" ]; then
    ( "$HOME/.claude/credit-balance.sh" >/dev/null 2>&1 & ) 2>/dev/null
fi
# "Credits in use" = the balance was seen falling within ACTIVE_WINDOW, or a
# plan window is exhausted (that is exactly when extra usage takes over).
# Disabled extra usage (LEN=0) can never be in use, whatever the balance does.
has5=0; has7=0; hasS=0
case "$P5" in ''|*[!0-9.]*) ;; *) has5=1 ;; esac
case "$P7" in ''|*[!0-9.]*) ;; *) has7=1 ;; esac
case "$PS" in ''|*[!0-9.]*) ;; *) hasS=1 ;; esac
# SOURCE=manual: the balance is hand-anchored (Console prepaid credits, which no
# endpoint exposes). That pool is only ever drawn on when Claude Code is NOT
# running against a plan - and a plan session always carries at least one
# rate_limits window - so the absence of every window is the signal that this
# money is moving. On a subscription the row stays away and the bar is exactly
# the two quota meters it has always been. MODE=credits overrides for testing.
MANUAL=0
if [ "$CRSRC" = manual ] && [ "$LEGACY" = 1 ] && [ "$CRMODE" != quota ]; then
    if [ "$CRMODE" = credits ]; then MANUAL=1
    elif [ "$has5" = 0 ] && [ "$has7" = 0 ] && [ "$hasS" = 0 ]; then MANUAL=1; fi
fi
CR_ACTIVE=0
if [ "$CRSRC" = manual ]; then CR_ACTIVE=0
elif [ "$CRMODE" = credits ]; then CR_ACTIVE=1
elif [ "$CRMODE" = auto ] && [ "$LIVE_OK" = 1 ] && [ "$LEN" != 0 ]; then
    # A drop stamp in the future (clock skew, a cache copied from another
    # machine) is not evidence of anything: age must be 0..window.
    if [ -n "$LDROP" ]; then
        _da=$(( $(date +%s) - LDROP ))
        [ "$_da" -ge 0 ] && [ "$_da" -lt "$CRWIN" ] && CR_ACTIVE=1
    fi
    [ "$has5" = 1 ] && [ "$(int "$P5")" -ge 100 ] && CR_ACTIVE=1
    [ "$has7" = 1 ] && [ "$(int "$P7")" -ge 100 ] && CR_ACTIVE=1
fi
# Minor units -> display units. The server states the scale (USD 2, JPY 0);
# hard-coding /100 would be 100x wrong on a zero-decimal currency.
cents() { awk -v c="$1" -v d="${LDP:-2}" 'BEGIN{ p=1; for(i=0;i<d;i++) p*=10; printf "%." d "f", c/p }'; }
# Out of credits is a state worth naming: "$0.00" alone reads like a failed fetch.
OUT=0; [ "$LWHY" = out_of_credits ] && OUT=1

# ---- line 1 ----
MODEL_SHORT=$(printf '%s' "$MODEL" | sed 's/[[:space:]]*(.*)[[:space:]]*$//')
EFF=""; EFF_P=""
if [ -n "$EFFORT" ]; then
    EFF_P=$(printf '%s' "$EFFORT" | awk '{ print toupper(substr($0,1,1)) substr($0,2) }')
    EFF="  ${LBL}${EFF_P}${R}"; EFF_P="  $EFF_P"
fi
FLAG=""; FLAG_P=""
[ -n "$FAST" ] && { FLAG=" ${DIM}${DOT} fast${R}"; FLAG_P=" ${DOT} fast"; }
BASE="${DIR##*[/\\]}"; [ -z "$BASE" ] && BASE="?"

CACHE="${TMPDIR:-/tmp}/cc-statusline-git-$(printf '%s' "${SID:-nosession}" | tr -c 'A-Za-z0-9-' '_')"
stale=1
if [ -f "$CACHE" ]; then
    # GNU stat -c first: on Linux the BSD form prints a usage report to stdout
    # before failing, and that output would break the arithmetic.
    mtime=$(stat -c %Y "$CACHE" 2>/dev/null || stat -f %m "$CACHE" 2>/dev/null || echo 0)
    [ $(( $(date +%s) - $(int "$mtime") )) -le 5 ] && stale=0
fi
if [ "$stale" = 1 ]; then
    rec=""
    if [ -d "$DIR" ] && ( cd "$DIR" && git rev-parse --git-dir >/dev/null 2>&1 ); then
        br=$(cd "$DIR" && git branch --show-current 2>/dev/null)
        [ -z "$br" ] && br="detached@$(cd "$DIR" && git rev-parse --short HEAD 2>/dev/null)"
        st=$(cd "$DIR" && git diff --cached --name-only 2>/dev/null | grep -c .)
        md=$(cd "$DIR" && git diff --name-only 2>/dev/null | grep -c .)
        rec="$br|$st|$md"
    fi
    printf '%s' "$rec" > "$CACHE"
fi
IFS='|' read -r BR ST MD < "$CACHE"
GIT=""; GIT_P=""
if [ -n "$BR" ]; then
    marks=""; marks_p=""
    [ "$(int "$ST")" -gt 0 ] && { marks="$marks ${GREEN}+${ST}${R}"; marks_p="$marks_p +${ST}"; }
    [ "$(int "$MD")" -gt 0 ] && { marks="$marks ${YEL}~${MD}${R}"; marks_p="$marks_p ~${MD}"; }
    GIT="  ${MAG}"$'\342\216\207'" ${BR}${R}${marks}"
    GIT_P="  "$'\342\216\207'" ${BR}${marks_p}"
fi

CTXI=$(clamp "$CTXPCT"); CTXF=$(clampf "$CTXPCT")
if [ "$(int "$SIZE")" -gt 0 ]; then CTXTOK="$(fmt_tok "$(int "$USED")")/$(fmt_tok "$(int "$SIZE")")"
else CTXTOK="$(fmt_tok "$(int "$USED")") tok"; fi

TAIL=""
if [ "$LAYOUT" = meters ]; then
    tail_txt="ctx ${CTXI}% ${DOT} ${CTXTOK}"
    # A known balance that is NOT being drawn on right now still gets a glance
    # on line 1, so a top-up landing (or running dry) is visible without the
    # meter taking over line 2. Dropped first when the width runs out.
    hint=""
    # Off by default. On a subscription the bar must look exactly as it did
    # before any of this existed, and a balance appended to line 1 is still a
    # credit thing on a screen that should have none. HINT=on in credit-config
    # brings it back for anyone who wants the reserve in view.
    if [ "$CRHINT" = 1 ] && [ "$LIVE_OK" = 1 ] && [ "$CR_ACTIVE" = 0 ] && [ "$CRSRC" != manual ]; then
        _m=""; [ "$LIVE_STALE" = 1 ] && _m="~"
        if [ "$OUT" = 1 ]; then hint=" ${DOT} no credits"
        else hint=" ${DOT} credits ${_m}\$$(cents "$LBAL")"; fi
    fi
    plain1=$'\342\227\206'" ${MODEL_SHORT}${EFF_P}${FLAG_P}  ${BASE}${GIT_P}"
    # printable length in characters, not bytes
    plen=$(printf '%s' "$plain1$tail_txt$hint" | awk '{ print length($0) }')
    if [ -n "$hint" ] && [ $(( plen + 2 + RIGHT_PAD )) -gt "$COLS" ]; then
        hint=""; plen=$(printf '%s' "$plain1$tail_txt" | awk '{ print length($0) }')
    fi
    if [ $(( plen + 2 + RIGHT_PAD )) -le "$COLS" ]; then
        if [ "$CTXI" -ge 90 ]; then tcol="$RED"; elif [ "$CTXI" -ge 70 ]; then tcol="$AMBER"; else tcol="$LBL"; fi
        TAIL="  ${tcol}${tail_txt}${hint}${R}"
    fi
fi
# %s not %b: the colour constants already hold literal ESC bytes, and %b would
# escape-process any branch name or model string containing a backslash.
printf '%s\n' "${CYAN}"$'\342\227\206'" ${WHITE}${MODEL_SHORT}${R}${EFF}${FLAG}  ${LBL}${BASE}${R}${GIT}${TAIL}"

manual_row() {
    # Console (API-key) billing: rate_limits is absent and there is no claude.ai
# login to ask for a balance, so BALANCE is hand-entered (ccredit set) and
# spend measured since then is subtracted. Kept for that auth mode only; a
# claude.ai login gets the live row above instead.
BALANCE=0; BALANCE_AT=""; CAL=1.0
. "$HOME/.claude/credit-config" 2>/dev/null

# Ledger of session_id -> that session's latest cost estimate. Summing the
# latest value per session gives spend cumulative across sessions, which
# cost.total_cost_usd cannot on its own - it is per-session and resets on
# /clear. Keyed by session_id for exactly that reason.
# ONE FILE PER SESSION, not one shared file. Every open Claude Code session
# re-renders its own status line each refreshInterval, so a shared
# read-modify-write loses updates: measured 9 of 60 rows surviving 60
# concurrent writers, which understates spend and overstates money left.
# Per-session files mean writers never touch the same path; only the summing
# read walks the directory. macOS has no flock(1), so avoiding the shared
# write is the portable fix rather than locking it.
LDIR="$HOME/.claude/credit-ledger.d"
# session_id goes into a filename - keep it to a safe charset, then prefix it.
# The 's-' prefix is load-bearing: without it a session_id of ".." resolves
# LF to the parent directory (mv -f then drops the temp into ~/.claude and
# loses the update), and any dot-leading id creates a file the sum below
# cannot see, so that session's spend would never be counted.
SIDK=$(printf '%s' "${SID:-nosession}" | tr -c 'A-Za-z0-9._-' '_')
COSTN=$(awk -v c="$COST" 'BEGIN{ c=c+0; if(c<0) c=0; printf "%.6f", c }')
mkdir -p "$LDIR" 2>/dev/null
LF="$LDIR/s-$SIDK"

# Fields: accumulated baseline latest.
#  baseline - cost this session had already reached when the balance was
#             anchored; spend before the anchor is already priced into it.
#  accumulated - spend banked from earlier segments of this same session.
# /clear zeroes cost.total_cost_usd, so the curve restarts from a new origin.
# Taking max() would silently discard every post-clear dollar below the old
# peak, so instead a drop is treated as a segment boundary: bank the finished
# segment and re-baseline at 0.
# CBASE, not BASE - BASE already holds the line-1 project basename.
ACC=0; CBASE="$COSTN"; LAST="$COSTN"
if [ -f "$LF" ]; then
    norm=$(awk 'NR==1{printf "%.6f %.6f %.6f", $1+0, $2+0, $3+0}' "$LF" 2>/dev/null)
    if [ -n "$norm" ]; then
        pacc=${norm%% *}; prest=${norm#* }; pbase=${prest%% *}; plast=${prest##* }
        if [ "$(awk -v c="$COSTN" -v l="$plast" 'BEGIN{print (c+0 < l+0)?1:0}')" = 1 ]; then
            ACC=$(awk -v a="$pacc" -v b="$pbase" -v l="$plast" 'BEGIN{ d=l-b; if(d<0) d=0; printf "%.6f", a+d }')
            CBASE=0; LAST="$COSTN"
        else
            ACC="$pacc"; CBASE="$pbase"; LAST="$COSTN"
        fi
    fi
fi
# Temp is dot-leading so the 's-*' sum below cannot see it. A render killed
# between the write and the rename leaves an orphan, and an orphan matched by
# the sum would double-count that session's spend permanently.
LTMP="$LDIR/.tmp.$$"
printf '%s %s %s\n' "$ACC" "$CBASE" "$LAST" > "$LTMP" 2>/dev/null && \
    mv -f "$LTMP" "$LF" 2>/dev/null
rm -f "$LTMP" 2>/dev/null

# find|xargs, not "$LDIR"/* - the glob execs one argument per session and
# blows ARG_MAX past ~12k sessions. That failure is silent (stderr is
# discarded), LSUM comes back empty, and an empty sum reads as "nothing
# spent", i.e. it overstates money left. xargs batches instead, and cat
# rather than awk-per-file keeps the total in one awk process.
LSUM=$(find "$LDIR" -type f -name 's-*' -print0 2>/dev/null \
         | xargs -0 cat 2>/dev/null \
         | awk 'NF==3 { d=$3-$2; if(d<0) d=0; s+=$1+d } END{printf "%.6f", s+0}')
case "$LSUM" in ''|*[!0-9.]*) LSUM=0 ;; esac

# Real billed spend wins when an admin credential is configured. The fetcher
# is spawned detached and we read only what it already cached - the render
# path must never wait on the network.
SPCACHE="${TMPDIR:-/tmp}/cc-credit-spend-$(id -u)"
BILLED=""
if [ -f "$SPCACHE" ]; then
    IFS='|' read -r bamt bts bstat < "$SPCACHE" 2>/dev/null
    BAGE=$(( $(date +%s) - $(int "${bts:-0}") ))
    # Validate before trusting. An unvalidated amount is the worst failure in
    # here: a negative one (cost_report can carry refunds, and credit-spend.sh
    # admits '-' into the sum) prints MORE money than the anchor, and a
    # non-numeric one is promoted to an authoritative "$0 spent" with the '~'
    # estimate marker dropped. Both overstate money left.
    case "$bamt" in ''|*[!0-9.]*) bamt="" ;; esac
    # Only a FRESH billed figure may print bare. Billing data itself lags ~5
    # min, and a cached one can be arbitrarily old if refreshes keep failing
    # - printing that with no marker presents a stale number as authoritative.
    [ -n "$bamt" ] && [ "${bstat:-}" = ok ] && [ "$BAGE" -lt 900 ] && BILLED="$bamt"
    [ "$BAGE" -ge 300 ] && \
        ( "$HOME/.claude/credit-spend.sh" >/dev/null 2>&1 & ) 2>/dev/null
elif [ -f "$HOME/.claude/.cost-api-key" ] || [ -n "${ANTHROPIC_ADMIN_KEY:-}" ]; then
    ( "$HOME/.claude/credit-spend.sh" >/dev/null 2>&1 & ) 2>/dev/null
fi
# '~' marks any figure that is not a fresh billed number.
#
# CAL corrects the estimate only. The transcript cannot see every billed
# call: the auto-mode classifier fires on each tool use and WebFetch
# summarizes each page with its own model call, and neither is logged.
# Measured over one full session: $34.14 actual against $24.93 visible,
# a 1.37x shortfall. ccredit re-learns CAL at every re-anchor, so it tracks
# a changing tool mix instead of trusting one session's ratio forever.
# A billed figure is already the truth and is never scaled.
if [ -n "$BILLED" ]; then
    SPEND="$BILLED"; MARK=""
else
    SPEND=$(awk -v s="$LSUM" -v c="$CAL" 'BEGIN{ c=c+0; if(c<=0) c=1; printf "%.6f", s*c }')
    MARK="~"
fi

# left = the balance you entered, minus everything spent since you entered it.
LEFT=$(awk -v b="$BALANCE" -v s="$SPEND" 'BEGIN{ v=b-s; if(v<0) v=0; printf "%.2f", v }')
SESS=$(awk -v c="$COSTN" 'BEGIN{ printf "%.2f", c }')
# Meter fills with the share of that balance already burned. A balance of 0 or
# less (or an unparseable one, which awk coerces to 0) means nothing is left,
# so the bar reads full - drawing it empty would say "nothing spent" in
# exactly the case where the label says $0.00 left, and the two must agree.
if [ "$(awk -v b="$BALANCE" 'BEGIN{print (b+0>0)?1:0}')" = 1 ]; then
    UPCT=$(awk -v s="$SPEND" -v b="$BALANCE" 'BEGIN{ v=s*100/b; if(v<0)v=0; if(v>100)v=100; printf "%.4f", v }')
else UPCT=100; fi
UPI=$(clamp "$UPCT")
if [ "$UPI" -ge 90 ]; then ACOL="$RED"; elif [ "$UPI" -ge 75 ]; then ACOL="$AMBER"; else ACOL="$LBL"; fi

# Same three-tier label step-down as the subscription row.
c0l="Credits: ${MARK}\$${LEFT} left"; c0r="\$${SESS} this session"
c1l="Credits ${MARK}\$${LEFT}";       c1r="\$${SESS} sess"
c2l="${MARK}\$${LEFT}";               c2r="${UPI}%"
chrome=$(( 2 + 2 + RIGHT_PAD ))
CL="$c2l"; CR="$c2r"; W=$METER_W
for i in 0 1 2; do
    case $i in 0) a="$c0l"; b="$c0r" ;; 1) a="$c1l"; b="$c1r" ;; 2) a="$c2l"; b="$c2r" ;; esac
    t=$(printf '%s%s' "$a" "$b" | awk '{print length($0)}')
    if [ $(( t + METER_W + chrome )) -le "$COLS" ]; then CL="$a"; CR="$b"; W=$METER_W; break; fi
    if [ $i = 2 ]; then
        W=$(( COLS - t - chrome )); [ "$W" -lt 1 ] && W=1
        [ "$W" -gt "$METER_W" ] && W=$METER_W
    fi
done
printf '%s\n' "${ACOL}${CL}${R}  $(meter "$UPCT" "$W")  ${LBL}${CR}${R}"
}

# ---- line 2 ----
if [ "$LAYOUT" = meters ] && [ "$MANUAL" = 1 ]; then
    manual_row
elif [ "$LAYOUT" = meters ] && [ "$CR_ACTIVE" = 1 ]; then
    # Live usage-credit meter. Bar = share of the last top-up already burned, so
    # a recharge visibly empties it. '~' marks a figure older than 5 minutes or
    # carried over from a failed refresh; the numbers are never invented.
    if [ "$LIVE_OK" = 0 ]; then
        why="${LST:-fetching}"
        [ -x "$HOME/.claude/credit-balance.sh" ] || why="no fetcher at ~/.claude/credit-balance.sh"
        printf '%s\n' "${RED}Credits: unavailable ${DOT} ${why}${R}"
    else
        MARK=""; [ "$LIVE_STALE" = 1 ] && MARK="~"
        TOTC="$LTOT"; { [ -z "$TOTC" ] || [ "$TOTC" -lt "$LBAL" ]; } && TOTC="$LBAL"
        SPENTC=$(( TOTC - LBAL ))
        if [ "$TOTC" -gt 0 ]; then
            UPCT=$(awk -v s="$SPENTC" -v t="$TOTC" 'BEGIN{ v=s*100/t; if(v<0)v=0; if(v>100)v=100; printf "%.4f", v }')
        else UPCT=100; fi
        UPI=$(clamp "$UPCT")
        if [ "$UPI" -ge 90 ]; then ACOL="$RED"; elif [ "$UPI" -ge 75 ]; then ACOL="$AMBER"; else ACOL="$LBL"; fi
        BALD=$(cents "$LBAL"); TOTD=$(cents "$TOTC"); SPD=$(cents "$SPENTC")
        mon=""
        if [ -n "$LUSED" ]; then
            mon="month \$$(cents "$LUSED")"
            [ -n "$LLIM" ] && [ "$LLIM" -gt 0 ] && mon="$mon/\$$(cents "$LLIM")"
        fi
        arx=""; [ "$LAR" = 1 ] && arx=" ${DOT} reload on"
        c0l="Credits: ${MARK}\$${BALD} left of \$${TOTD}"; c0r="\$${SPD} used${mon:+ ${DOT} $mon}${arx}"
        c1l="Credits ${MARK}\$${BALD}/\$${TOTD}";         c1r="${mon:-\$${SPD} used}"
        c2l="${MARK}\$${BALD}";                            c2r="${UPI}%"
        if [ "$OUT" = 1 ]; then
            c0l="Credits: out of credits"; c0r="top up to keep using them${mon:+ ${DOT} $mon}"
            c1l="Credits: none left";      c1r="${mon:-top up}"
            c2l="no credits";              c2r=""
            ACOL="$RED"
        fi
        chrome=$(( 2 + 2 + RIGHT_PAD ))
        CL="$c2l"; CR="$c2r"; W=$METER_W
        for i in 0 1 2; do
            case $i in 0) a="$c0l"; b="$c0r" ;; 1) a="$c1l"; b="$c1r" ;; 2) a="$c2l"; b="$c2r" ;; esac
            t=$(printf '%s%s' "$a" "$b" | awk '{print length($0)}')
            if [ $(( t + METER_W + chrome )) -le "$COLS" ]; then CL="$a"; CR="$b"; W=$METER_W; break; fi
            if [ $i = 2 ]; then
                W=$(( COLS - t - chrome )); [ "$W" -lt 1 ] && W=1
                [ "$W" -gt "$METER_W" ] && W=$METER_W
            fi
        done
        printf '%s\n' "${ACOL}${CL}${R}  $(meter "$UPCT" "$W")  ${LBL}${CR}${R}"
    fi
elif [ "$LAYOUT" = meters ] && { [ "$has5" = 1 ] || [ "$has7" = 1 ]; }; then
    p5=$(clamp "$P5"); p7=$(clamp "$P7")
    p5f=$(clampf "$P5"); p7f=$(clampf "$P7")
    r5=$(fmt_reset "$(int "$R5")"); r7=$(fmt_reset "$(int "$R7")")
    l5=""; s5=""; l7=""; s7=""
    if [ "$r5" = resetting ]; then l5=" ${DOT} resetting"; s5="$l5"
    elif [ -n "$r5" ]; then l5=" ${DOT} resets in $r5"; s5=" ${DOT} $r5"; fi
    if [ "$r7" = resetting ]; then l7=" ${DOT} resetting"; s7="$l7"
    elif [ -n "$r7" ]; then l7=" ${DOT} resets in $r7"; s7=" ${DOT} $r7"; fi

    n=$(( has5 + has7 ))
    chrome=$(( 2*n + 2*(n+1) - 2 + RIGHT_PAD ))
    W=$METER_W; IDX=2
    for i in 0 1 2; do
        case $i in
            0) a="Session: ${p5}%${l5}"; b="Weekly: ${p7}%${l7}" ;;
            1) a="Session ${p5}%${s5}";  b="Weekly ${p7}%${s7}"  ;;
            2) a="S ${p5}%";             b="W ${p7}%"            ;;
        esac
        t=0
        [ "$has5" = 1 ] && t=$(( t + $(printf '%s' "$a" | awk '{print length($0)}') ))
        [ "$has7" = 1 ] && t=$(( t + $(printf '%s' "$b" | awk '{print length($0)}') ))
        if [ $(( t + n*METER_W + chrome )) -le "$COLS" ]; then IDX=$i; W=$METER_W; break; fi
        if [ $i = 2 ]; then
            W=$(( (COLS - t - chrome) / n )); [ "$W" -lt 1 ] && W=1
            [ "$W" -gt "$METER_W" ] && W=$METER_W
        fi
    done
    case $IDX in
        0) A="Session: ${p5}%${l5}"; B="Weekly: ${p7}%${l7}" ;;
        1) A="Session ${p5}%${s5}";  B="Weekly ${p7}%${s7}"  ;;
        2) A="S ${p5}%";             B="W ${p7}%"            ;;
    esac
    OUT=""
    [ "$has5" = 1 ] && OUT="${LBL}${A}${R}  $(meter "$p5f" "$W")"
    [ "$has7" = 1 ] && { [ -n "$OUT" ] && OUT="$OUT  "; OUT="${OUT}$(meter "$p7f" "$W")  ${LBL}${B}${R}"; }
    printf '%s\n' "$OUT"
elif [ "$LAYOUT" = meters ] && [ "$hasS" = 1 ]; then
    # Behind a Claude apps gateway, rate_limits can carry ONLY spend_limit. Before
    # this branch existed such a payload fell through to the credit row, which
    # showed hand-anchored dollars while ignoring the real first-party spend
    # figure sitting in the payload. used_percentage may exceed 100 once the limit
    # is passed, so the label reports the true value while the bar clamps at full.
    psf=$(clampf "$PS")
    psi=$(int "$PS"); [ "$psi" -lt 0 ] && psi=0
    rs=$(fmt_reset "$(int "$RS")")
    sl=""; ss=""
    if [ "$rs" = resetting ]; then sl=" ${DOT} resetting"; ss="$sl"
    elif [ -n "$rs" ]; then sl=" ${DOT} resets in $rs"; ss=" ${DOT} $rs"; fi
    if [ "$psi" -ge 90 ]; then scol="$RED"; elif [ "$psi" -ge 75 ]; then scol="$AMBER"; else scol="$LBL"; fi
    chrome=$(( 2 + RIGHT_PAD ))
    SEL="S ${psi}%"; W=$METER_W
    for f in "Spend limit: ${psi}%${sl}" "Spend ${psi}%${ss}" "S ${psi}%"; do
        t=$(printf '%s' "$f" | awk '{print length($0)}')
        if [ $(( t + METER_W + chrome )) -le "$COLS" ]; then SEL="$f"; W=$METER_W; break; fi
        SEL="S ${psi}%"; t=$(printf '%s' "$SEL" | awk '{print length($0)}')
        W=$(( COLS - t - chrome )); [ "$W" -lt 1 ] && W=1
        [ "$W" -gt "$METER_W" ] && W=$METER_W
    done
    printf '%s\n' "${scol}${SEL}${R}  $(meter "$psf" "$W")"
elif [ "$LAYOUT" = meters ] && [ "$LEGACY" = 1 ] && [ "$CRMODE" != quota ]; then
    # API-key auth with no plan windows at all: dollars are the only meter there
    # is. MODE=quota opts out of that too and falls through to the context bar.
    manual_row
else
    MSI=$(int "$MS"); MINS=$(( MSI / 60000 )); SECS=$(( (MSI % 60000) / 1000 ))
    rl=""
    [ "$has5" = 1 ] && rl=" ${DOT} 5h $(clamp "$P5")%"
    f0="Context: ${CTXI}% ${DOT} ${CTXTOK} ${DOT} ${MINS}m${SECS}s${rl}"
    f1="Context: ${CTXI}% ${DOT} ${CTXTOK}"
    f2="C ${CTXI}%"
    chrome=$(( 2 + 2 + RIGHT_PAD ))
    SEL="$f2"; W=$METER_W
    for f in "$f0" "$f1" "$f2"; do
        t=$(printf '%s' "$f" | awk '{print length($0)}')
        if [ $(( t + METER_W + chrome )) -le "$COLS" ]; then SEL="$f"; W=$METER_W; break; fi
        SEL="$f2"; t=$(printf '%s' "$f2" | awk '{print length($0)}')
        W=$(( COLS - t - chrome )); [ "$W" -lt 1 ] && W=1
        [ "$W" -gt "$METER_W" ] && W=$METER_W
    done
    printf '%s\n' "${LBL}${SEL}${R}  $(meter "$CTXF" "$W")"
fi
