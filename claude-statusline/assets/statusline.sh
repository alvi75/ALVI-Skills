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

LAYOUT=meters
while [ $# -gt 0 ]; do
    case "$1" in
        --layout) LAYOUT="$2"; shift 2 ;;
        --layout=*) LAYOUT="${1#*=}"; shift ;;
        *) shift ;;
    esac
done
case "$LAYOUT" in meters|context) ;; *) LAYOUT=meters ;; esac

input=$(cat)
[ -z "$input" ] && exit 0
command -v jq >/dev/null 2>&1 || { printf '%s\n' "status line needs jq - see ~/.claude/statusline.sh"; exit 0; }

# One jq call - each extra process spawn costs ~85ms on Windows, ~5ms elsewhere.
#
# Delimiter is U+001F (unit separator), NOT a tab, and NOT U+0001: bash 3.2
# (macOS /bin/bash) reserves 0x01 as CTLESC internally and silently eats it,
# so a 0x01-delimited line comes back as one field. Emitted as a jq \u001f
# escape rather than a literal byte so it survives copying/zipping. Tab is an IFS *whitespace* character, so with
# IFS=$'\t' bash collapses runs of tabs into one separator and every empty field
# shifts all later fields left - an absent .effort.level would land the session
# id in the effort slot. A non-whitespace IFS preserves empty fields exactly.
SEP=$'\037'
IFS="$SEP" read -r MODEL DIR CTXPCT USED SIZE MS EFFORT FAST P5 R5 P7 R7 SID <<EOF
$(printf '%s' "$input" | jq -j '[
  (.model.display_name // "claude"),
  (.workspace.current_dir // .cwd // ""),
  ((.context_window.used_percentage // 0)),
  (.context_window.total_input_tokens // 0),
  (.context_window.context_window_size // 0),
  (.cost.total_duration_ms // 0),
  (.effort.level // ""),
  (if .fast_mode then "fast" else "" end),
  (.rate_limits.five_hour.used_percentage // ""),
  (.rate_limits.five_hour.resets_at // ""),
  (.rate_limits.seven_day.used_percentage // ""),
  (.rate_limits.seven_day.resets_at // ""),
  (.session_id // "nosession")
] | map(tostring) | join("\u001f")' 2>/dev/null)
EOF
[ -z "$MODEL" ] && exit 0

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
    plain1=$'\342\227\206'" ${MODEL_SHORT}${EFF_P}${FLAG_P}  ${BASE}${GIT_P}"
    # printable length in characters, not bytes
    plen=$(printf '%s' "$plain1$tail_txt" | awk '{ print length($0) }')
    if [ $(( plen + 2 + RIGHT_PAD )) -le "$COLS" ]; then
        if [ "$CTXI" -ge 90 ]; then tcol="$RED"; elif [ "$CTXI" -ge 70 ]; then tcol="$AMBER"; else tcol="$LBL"; fi
        TAIL="  ${tcol}${tail_txt}${R}"
    fi
fi
# %s not %b: the colour constants already hold literal ESC bytes, and %b would
# escape-process any branch name or model string containing a backslash.
printf '%s\n' "${CYAN}"$'\342\227\206'" ${WHITE}${MODEL_SHORT}${R}${EFF}${FLAG}  ${LBL}${BASE}${R}${GIT}${TAIL}"

# ---- line 2 ----
has5=0; has7=0
case "$P5" in ''|*[!0-9.]*) ;; *) has5=1 ;; esac
case "$P7" in ''|*[!0-9.]*) ;; *) has7=1 ;; esac

if [ "$LAYOUT" = meters ] && { [ "$has5" = 1 ] || [ "$has7" = 1 ]; }; then
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
