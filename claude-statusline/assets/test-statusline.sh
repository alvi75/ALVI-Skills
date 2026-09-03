#!/usr/bin/env bash
# Bash renderer + credit fetcher test suite. No network, no Keychain: HOME is a
# temp dir, and `security` / `curl` are shims on PATH that serve fixtures.
#   bash test-statusline.sh            run
#   bash test-statusline.sh -v         also print every rendered line
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SL="$HERE/statusline.sh"
FETCH="$HERE/credit-balance.sh"
V=0; [ "${1:-}" = -v ] && V=1
PASS=0; FAIL=0
T=$(mktemp -d "${TMPDIR:-/tmp}/cc-sl-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.claude"
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
export COLUMNS=120
# The renderer spawns the fetcher only when ~/.claude/credit-balance.sh exists;
# tests that want a spawn copy it in explicitly.
cp "$SL" "$HOME/.claude/statusline.sh"

strip() { sed $'s/\033\\[[0-9;]*m//g'; }
ok()   { PASS=$((PASS+1)); [ "$V" = 1 ] && echo "  ok   $1"; return 0; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
# assert_has NAME OUTPUT NEEDLE
assert_has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "wanted <$3> in: $2" ;; esac; }
assert_not() { case "$2" in *"$3"*) bad "$1" "did not want <$3> in: $2" ;; *) ok "$1" ;; esac; }
assert_eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got <$2> want <$3>"; }

NOW=$(date +%s)
SUB='{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/tmp/proj"},"context_window":{"used_percentage":13,"total_input_tokens":128000,"context_window_size":1000000},"cost":{"total_cost_usd":1.5,"total_duration_ms":90000},"session_id":"abc","rate_limits":{"five_hour":{"used_percentage":16,"resets_at":'$((NOW+5460))'},"seven_day":{"used_percentage":8,"resets_at":'$((NOW+430000))'}}}'
SUB100=$(printf '%s' "$SUB" | sed 's/"used_percentage":16/"used_percentage":100/')
NORL='{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/tmp/proj"},"context_window":{"used_percentage":13,"total_input_tokens":128000,"context_window_size":1000000},"cost":{"total_cost_usd":1.5,"total_duration_ms":90000},"session_id":"abc"}'
render() { printf '%s' "$1" | /bin/bash "$HOME/.claude/statusline.sh" --layout meters 2>/dev/null | strip; }
line2()  { render "$1" | sed -n 2p; }
line1()  { render "$1" | sed -n 1p; }
# live cache writer: status ts bal used lim en ar tot drop cur [reason] [decimals]
live() { printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$@" "" "" > "$HOME/.claude/credit-live"; }

echo "renderer: row selection"
rm -f "$HOME/.claude/credit-live" "$HOME/.claude/credit-config"
o=$(line2 "$SUB");            assert_has "no cache -> quota row" "$o" "Session: 16%"
o=$(line1 "$SUB");            assert_not "no cache -> no hint" "$o" "credits"

live ok "$NOW" 35 3965 10000 1 0 4000 "$((NOW-30))" USD
o=$(line2 "$SUB");            assert_has "recent drop -> credit row" "$o" 'Credits: $0.35 left of $40.00'
                              assert_has "credit row: used + month" "$o" '$39.65 used · month $39.65/$100.00'
                              assert_has "credit row: bar full (99%)" "$o" '▕████████████▏'
o=$(line1 "$SUB");            assert_not "credit row active -> no line-1 hint" "$o" "credits"

live ok "$NOW" 35 3965 10000 1 0 4000 "$((NOW-3600))" USD
o=$(line2 "$SUB");            assert_has "old drop -> back to quota row" "$o" "Session: 16%"
o=$(line1 "$SUB");            assert_has "old drop -> line-1 hint" "$o" '· credits $0.35'
o=$(line2 "$SUB100");         assert_has "5h at 100% -> credit row" "$o" 'Credits:'

live ok "$NOW" 35 3965 10000 0 0 4000 "$((NOW-30))" USD
o=$(line2 "$SUB");            assert_has "extra usage disabled -> never credit row" "$o" "Session: 16%"
o=$(line2 "$SUB100");         assert_has "disabled + 5h 100% -> still quota row" "$o" "Session: 100%"

live ok "$NOW" 35 3965 10000 1 0 4000 "" USD
o=$(line2 "$SUB");            assert_has "no drop ever -> quota row" "$o" "Session: 16%"

echo "renderer: modes and config"
live ok "$NOW" 35 3965 10000 1 0 4000 "$((NOW-30))" USD
printf 'MODE=quota\n' > "$HOME/.claude/credit-config"
o=$(line2 "$SUB100");         assert_has "MODE=quota overrides 100%" "$o" "Session: 100%"
printf 'MODE=credits\n' > "$HOME/.claude/credit-config"
live ok "$NOW" 35 3965 10000 1 0 4000 "" USD
o=$(line2 "$SUB");            assert_has "MODE=credits forces row" "$o" 'Credits: $0.35'
rm -f "$HOME/.claude/credit-live"
printf '#!/bin/sh\n' > "$HOME/.claude/credit-balance.sh"; chmod +x "$HOME/.claude/credit-balance.sh"
o=$(line2 "$SUB");            assert_has "MODE=credits, no cache -> unavailable" "$o" "Credits: unavailable · fetching"
live http_401 "$NOW" "" "" "" "" "" "" "" ""
o=$(line2 "$SUB");            assert_has "MODE=credits, 401 -> shows status" "$o" "http_401"
rm -f "$HOME/.claude/credit-balance.sh"
printf 'MODE=auto\nACTIVE_WINDOW=10\n' > "$HOME/.claude/credit-config"
live ok "$NOW" 35 3965 10000 1 0 4000 "$((NOW-30))" USD
o=$(line2 "$SUB");            assert_has "ACTIVE_WINDOW=10 expires a 30s drop" "$o" "Session: 16%"
printf 'MODE="credits"\r\n' > "$HOME/.claude/credit-config"
live ok "$NOW" 35 3965 10000 1 0 4000 "" USD
o=$(line2 "$SUB");            assert_has "quoted MODE with CRLF still parses" "$o" 'Credits: $0.35'
printf 'MODE=credits\n' > "$HOME/.claude/credit-config"; rm -f "$HOME/.claude/credit-live"
o=$(line2 "$SUB");            assert_has "MODE=credits, no fetcher installed -> says so" "$o" "no fetcher"
rm -f "$HOME/.claude/credit-config"
live ok "$NOW" 35 3965 10000 1 0 4000 "$((NOW+7200))" USD
o=$(line2 "$SUB");            assert_has "drop stamp in the future -> not in use" "$o" "Session: 16%"

echo "renderer: staleness and carry-forward"
live ok "$((NOW-400))" 35 3965 10000 1 0 4000 "$((NOW-30))" USD
o=$(line2 "$SUB");            assert_has "fetch >5min old -> ~ marker" "$o" 'Credits: ~$0.35'
live http_500 "$NOW" 35 3965 10000 1 0 4000 "$((NOW-30))" USD
o=$(line2 "$SUB");            assert_has "failed refresh, carried numbers -> ~" "$o" 'Credits: ~$0.35 left of $40.00'
live http_500 "$NOW" 35 3965 10000 1 0 4000 "$((NOW-3600))" USD
o=$(line1 "$SUB");            assert_has "line-1 hint carries the ~ too" "$o" '· credits ~$0.35'
live ok "$NOW" 99999999999999999999 0 "" 1 0 99999999999999999999 "$((NOW-30))" USD
o=$(render "$SUB");           assert_not "20-digit cents rejected, no credit row" "$o" 'Credits:'
live ok "$NOW" 35 "" "" 1 1 4000 "$((NOW-30))" USD
o=$(line2 "$SUB");            assert_has "null month figures omitted, reload flag shown" "$o" '$39.65 used · reload on'
                              assert_not "no month segment when null" "$o" "month"
live ok "$NOW" 35 3965 "" 1 0 4000 "$((NOW-30))" USD
o=$(line2 "$SUB");            assert_has "unlimited monthly -> no /limit" "$o" 'month $39.65'
                              assert_not "unlimited monthly -> no slash" "$o" 'month $39.65/'

echo "renderer: recharge and totals"
live ok "$NOW" 4000 3965 10000 1 0 4000 "$((NOW-30))" USD
o=$(line2 "$SUB");            assert_has "full balance -> 0 used, empty bar" "$o" '$40.00 left of $40.00  ▕░░░░░░░░░░░░▏  $0.00 used'
live ok "$NOW" 4500 0 "" 1 0 4000 "$((NOW-30))" USD
o=$(line2 "$SUB");            assert_has "balance above total -> total lifts, not negative" "$o" '$45.00 left of $45.00'
live ok "$NOW" 0 4000 10000 1 0 4000 "$((NOW-30))" USD
o=$(line2 "$SUB");            assert_has "zero balance -> \$0.00 and full bar" "$o" '$0.00 left of $40.00  ▕████████████▏'
live ok "$NOW" 0 0 "" 1 0 0 "$((NOW-30))" USD
o=$(line2 "$SUB");            assert_has "zero total -> no divide by zero, full bar" "$o" '▕████████████▏'

echo "renderer: malformed cache never crashes or invents a balance"
for bad_line in "ok|$NOW|abc|1|2|1|0|4000|$((NOW-30))|USD" "garbage" "" "ok|$NOW|-5|||1||4000|$((NOW-30))|" "ok|notanumber|35|||1||4000|$((NOW-30))|USD"; do
    printf '%s\n' "$bad_line" > "$HOME/.claude/credit-live"
    o=$(render "$SUB"); n=$(printf '%s\n' "$o" | grep -c .)
    [ "$n" -ge 2 ] && ok "malformed <$bad_line>: 2 lines" || bad "malformed <$bad_line>: lines=$n"
    case "$bad_line" in "ok|notanumber"*) ;; *) assert_not "malformed <$bad_line>: no credit row" "$o" 'Credits:' ;; esac
done
: > "$HOME/.claude/credit-live"
o=$(render "$SUB"); assert_has "empty cache -> quota row" "$o" "Session: 16%"

echo "renderer: width step-down"
live ok "$NOW" 35 3965 10000 1 0 4000 "$((NOW-30))" USD
o=$(COLUMNS=70 line2 "$SUB");  assert_has "70 cols -> tier 1" "$o" 'Credits $0.35/$40.00'
o=$(COLUMNS=40 line2 "$SUB");  assert_has "40 cols -> tier 2 label" "$o" '$0.35'
                               assert_has "40 cols -> percent on the right" "$o" '99%'
o=$(COLUMNS=20 render "$SUB"); n=$(printf '%s\n' "$o" | grep -c .); [ "$n" -ge 2 ] && ok "20 cols still 2 lines" || bad "20 cols lines=$n"

echo "renderer: SOURCE=manual puts the hand anchor in front of the plan meters"
rm -f "$HOME/.claude/credit-live"
printf 'SOURCE=manual\nBALANCE=0.35\nBALANCE_AT=2026-09-02T00:00:00Z\nCAL=1.0\n' > "$HOME/.claude/credit-config"
o=$(line2 "$SUB");            assert_has "manual row beats the quota row" "$o" 'Credits: ~$0.35 left'
o=$(line1 "$SUB");            assert_not "manual row -> no live hint" "$o" "credits"
live ok "$NOW" 0 0 4000 0 0 0 "" USD
o=$(line2 "$SUB");            assert_has "manual ignores a live cache of \$0" "$o" 'Credits: ~$0.35 left'
o=$(line1 "$SUB");            assert_not "manual -> no 'no credits' hint" "$o" "no credits"
printf 'SOURCE=manual\nMODE=quota\nBALANCE=0.35\nBALANCE_AT=2026-09-02T00:00:00Z\n' > "$HOME/.claude/credit-config"
o=$(line2 "$SUB");            assert_has "MODE=quota still wins over manual" "$o" "Session: 16%"
printf 'SOURCE=manual\nMODE=credits\n' > "$HOME/.claude/credit-config"
o=$(line2 "$SUB");            assert_has "manual with no anchor falls through" "$o" "Session: 16%"
printf 'SOURCE=live\nBALANCE=0.35\nBALANCE_AT=2026-09-02T00:00:00Z\n' > "$HOME/.claude/credit-config"
o=$(line2 "$SUB");            assert_has "SOURCE=live keeps the plan meters in front" "$o" "Session: 16%"
rm -f "$HOME/.claude/credit-config" "$HOME/.claude/credit-live"
rm -f "$T/spawn.log"; cp "$SL" "$HOME/.claude/statusline.sh"
printf '#!/bin/sh\necho spawned >> "$SPAWN_LOG"\n' > "$HOME/.claude/credit-balance.sh"; chmod +x "$HOME/.claude/credit-balance.sh"
printf 'SOURCE=manual\nBALANCE=0.35\nBALANCE_AT=2026-09-02T00:00:00Z\n' > "$HOME/.claude/credit-config"
export SPAWN_LOG="$T/spawn.manual.log"; render "$SUB" >/dev/null; sleep 1
[ ! -f "$SPAWN_LOG" ] && ok "SOURCE=manual never fetches" || bad "SOURCE=manual spawned the fetcher"
rm -f "$HOME/.claude/credit-balance.sh" "$HOME/.claude/credit-config"

echo "renderer: legacy hand-anchored row is unchanged for API-key auth"
rm -f "$HOME/.claude/credit-live"
printf 'BALANCE=35.30\nBALANCE_AT=2026-09-02T00:00:00Z\nCAL=1.0\n' > "$HOME/.claude/credit-config"
o=$(line2 "$NORL");           assert_has "legacy row" "$o" 'Credits: ~$35.30 left'
printf 'MODE=auto\n' > "$HOME/.claude/credit-config"
o=$(line2 "$NORL");           assert_has "MODE-only config is not a legacy anchor" "$o" 'Context: 13%'
rm -f "$HOME/.claude/credit-config"

echo "renderer: subscription row byte-identical to the committed version when no cache"
if git -C "$HERE" show HEAD:claude-statusline/assets/statusline.sh > "$T/old.sh" 2>/dev/null; then
    for c in 40 60 80 100 120; do
        a=$(printf '%s' "$SUB" | COLUMNS=$c /bin/bash "$T/old.sh" --layout meters 2>/dev/null)
        b=$(printf '%s' "$SUB" | COLUMNS=$c /bin/bash "$HOME/.claude/statusline.sh" --layout meters 2>/dev/null)
        assert_eq "identical at $c cols" "$b" "$a"
    done
else
    echo "  skip (not in a git checkout)"
fi

echo "renderer: fetcher spawn gating"
mkdir -p "$T/bin"
cat > "$HOME/.claude/credit-balance.sh" <<EOF
#!/bin/sh
echo spawned >> "\$SPAWN_LOG"
EOF
chmod +x "$HOME/.claude/credit-balance.sh"
spawn_case() {   # $1 name  $2 expect(1|0)
    export SPAWN_LOG="$T/spawn.$RANDOM.log"
    render "$SUB" >/dev/null; sleep 1
    if [ "$2" = 1 ]; then [ -f "$SPAWN_LOG" ] && ok "$1" || bad "$1: did not spawn"
    else [ ! -f "$SPAWN_LOG" ] && ok "$1" || bad "$1: spawned"; fi
}
rm -f "$HOME/.claude/credit-live";                       spawn_case "no cache -> spawns fetcher" 1
live ok "$NOW" 35 3965 10000 1 0 4000 "" USD;            spawn_case "fresh cache -> no spawn" 0
live ok "$((NOW-90))" 35 3965 10000 1 0 4000 "" USD;     spawn_case "cache 90s old -> spawns" 1
live noauth "$((NOW-120))" "" "" "" "" "" "" "" "";       spawn_case "noauth 2 min old -> backoff, no spawn" 0
live noauth "$((NOW-700))" "" "" "" "" "" "" "" "";       spawn_case "noauth 11 min old -> spawns" 1
printf 'MODE=quota\n' > "$HOME/.claude/credit-config"; rm -f "$HOME/.claude/credit-live"
                                                          spawn_case "MODE=quota -> never spawns" 0
rm -f "$HOME/.claude/credit-config" "$HOME/.claude/credit-balance.sh"
o=$(printf '%s' "$SUB" | COLUMNS=120 /bin/bash "$HOME/.claude/statusline.sh" --layout context 2>/dev/null | strip)
assert_has "--layout context unaffected" "$o" "Context: 13%"

# ---------------------------------------------------------------- fetcher
echo "fetcher: shimmed keychain + API"
cp "$FETCH" "$HOME/.claude/credit-balance.sh"; chmod +x "$HOME/.claude/credit-balance.sh"
printf '{"oauthAccount":{"organizationUuid":"4c48ce7b-e985-4588-a015-06b81a069593"}}' > "$HOME/.claude.json"
# security shim: prints the credentials JSON the real Keychain item holds.
cat > "$T/bin/security" <<EOF
#!/bin/sh
cat "$T/creds.json"
EOF
# curl shim: serves fixtures by URL, records the request (headers included) so
# a test can prove the token never lands anywhere but the Authorization header.
cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
url=""; for a in "$@"; do case "$a" in https://*) url="$a" ;; esac; done
printf '%s\n' "$url" >> "$CURL_LOG"; printf '%s\n' "$*" >> "$CURL_LOG.full"
[ -n "${CURL_DELAY:-}" ] && sleep "$CURL_DELAY"
case "$url" in
  */prepaid/credits) cat "$FIX_CREDITS"; printf '\n%s' "${CODE_CREDITS:-200}" ;;
  */api/oauth/usage) cat "$FIX_USAGE";   printf '\n%s' "${CODE_USAGE:-200}" ;;
  *) printf '{}\n404' ;;
esac
EOF
chmod +x "$T/bin/security" "$T/bin/curl"
export PATH="$T/bin:$PATH" CURL_LOG="$T/curl.log" FIX_CREDITS="$T/credits.json" FIX_USAGE="$T/usage.json"
export CODE_CREDITS=200 CODE_USAGE=200
future=$(( (NOW + 3600) * 1000 ))
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-SECRETSECRET","refreshToken":"rt-SECRET","expiresAt":%s}}' "$future" > "$T/creds.json"
printf '{"amount":4000,"currency":"USD","auto_reload_settings":{"enabled":false},"expiry_policy_months":12,"promo_tranches":[]}' > "$FIX_CREDITS"
printf '{"five_hour":{"utilization":16},"extra_usage":{"is_enabled":true,"monthly_limit":10000,"used_credits":0,"utilization":0,"currency":"USD"}}' > "$FIX_USAGE"
run_fetch() { rmdir "$HOME/.claude/credit-live.lock" 2>/dev/null; /bin/bash "$HOME/.claude/credit-balance.sh" "$@"; }
rm -f "$HOME/.claude/credit-live" "$HOME/.claude/credit-config"

run_fetch; c=$(cat "$HOME/.claude/credit-live")
assert_has "first fetch: ok + balance 4000c + total 4000c" "$c" "ok|"
IFS='|' read -r st ts bal used lim en ar tot drop cur why dp < "$HOME/.claude/credit-live"
assert_eq "bal" "$bal" 4000; assert_eq "used" "$used" 0; assert_eq "lim" "$lim" 10000
assert_eq "enabled" "$en" 1; assert_eq "autoreload" "$ar" 0; assert_eq "total=bal on first sight" "$tot" 4000
assert_eq "no drop yet" "$drop" ""; assert_eq "currency" "$cur" USD
perm=$(stat -f %Lp "$HOME/.claude/credit-live" 2>/dev/null || stat -c %a "$HOME/.claude/credit-live")
assert_eq "cache mode 600" "$perm" 600
assert_not "token not in cache" "$c" "SECRET"
assert_has "bearer header used" "$(cat "$CURL_LOG.full")" "Authorization: Bearer sk-ant-oat01-SECRETSECRET"
assert_has "oauth beta header" "$(cat "$CURL_LOG.full")" "anthropic-beta: oauth-2025-04-20"
assert_has "org in path" "$(cat "$CURL_LOG")" "/organizations/4c48ce7b-e985-4588-a015-06b81a069593/prepaid/credits"
p=$(run_fetch --print); assert_not "--print never shows the token" "$p" "SECRET"
assert_has "--print shows cache" "$p" "cache: ok|"

echo "fetcher: drop and top-up detection"
printf '{"amount":3965,"currency":"USD","auto_reload_settings":{"enabled":false}}' > "$FIX_CREDITS"
run_fetch; IFS='|' read -r st ts bal used lim en ar tot drop cur why dp < "$HOME/.claude/credit-live"
assert_eq "balance fell -> bal" "$bal" 3965; assert_eq "total kept" "$tot" 4000
[ -n "$drop" ] && [ $(( $(date +%s) - drop )) -le 2 ] && ok "drop stamped now" || bad "drop not stamped: <$drop>"
d1="$drop"; sleep 1
run_fetch; IFS='|' read -r st ts bal used lim en ar tot drop cur why dp < "$HOME/.claude/credit-live"
assert_eq "unchanged balance keeps old drop stamp" "$drop" "$d1"
printf '{"amount":6000,"currency":"USD","auto_reload_settings":{"enabled":true}}' > "$FIX_CREDITS"
run_fetch; IFS='|' read -r st ts bal used lim en ar tot drop cur why dp < "$HOME/.claude/credit-live"
assert_eq "top-up -> total resets to new balance" "$tot" 6000; assert_eq "auto-reload on" "$ar" 1
assert_eq "top-up keeps drop stamp" "$drop" "$d1"
printf 'TOTAL=40\n' > "$HOME/.claude/credit-config"
run_fetch; IFS='|' read -r st ts bal used lim en ar tot drop cur why dp < "$HOME/.claude/credit-live"
assert_eq "TOTAL in config overrides (cents)" "$tot" 4000
rm -f "$HOME/.claude/credit-config"
run_fetch; IFS='|' read -r st ts bal used lim en ar tot drop cur why dp < "$HOME/.claude/credit-live"
assert_eq "override removed -> total lifts back to balance" "$tot" 6000

echo "fetcher: steady state"
d0=$(cut -d'|' -f9 "$HOME/.claude/credit-live")
run_fetch; IFS='|' read -r st ts bal used lim en ar tot drop cur why dp < "$HOME/.claude/credit-live"
assert_eq "unchanged balance keeps total" "$tot" 6000; assert_eq "unchanged balance keeps drop" "$drop" "$d0"

echo "fetcher: failures carry numbers forward, never invent"
CODE_CREDITS=500 run_fetch; c=$(cat "$HOME/.claude/credit-live")
assert_has "500 -> http_500 status" "$c" "http_500|"
IFS='|' read -r st ts bal used lim en ar tot drop cur why dp < "$HOME/.claude/credit-live"
assert_eq "500 carries balance" "$bal" 6000; assert_eq "500 carries total" "$tot" 6000
printf 'not json' > "$FIX_CREDITS"; run_fetch; c=$(cat "$HOME/.claude/credit-live")
assert_has "bad json -> badjson" "$c" "badjson|"
printf '{"amount":"6000"}' > "$FIX_CREDITS"; run_fetch; c=$(cat "$HOME/.claude/credit-live")
assert_has "string amount -> badjson (not coerced)" "$c" "badjson|"
printf '{"amount":6000.7,"currency":"usd!!"}' > "$FIX_CREDITS"
CODE_USAGE=403 run_fetch; IFS='|' read -r st ts bal used lim en ar tot drop cur why dp < "$HOME/.claude/credit-live"
assert_eq "usage 403 -> still ok" "$st" ok; assert_eq "fractional cents floored" "$bal" 6000
assert_eq "usage 403 -> month fields empty" "$used|$lim|$en" "||"; assert_eq "currency sanitised" "$cur" usd
printf '{"amount":6000,"currency":"USD"}' > "$FIX_CREDITS"
printf '{"extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null}}' > "$FIX_USAGE"
run_fetch; IFS='|' read -r st ts bal used lim en ar tot drop cur why dp < "$HOME/.claude/credit-live"
assert_eq "null limit -> empty" "$lim" ""; assert_eq "null used -> empty" "$used" ""; assert_eq "disabled -> 0" "$en" 0

echo "fetcher: the real out-of-credits response"
printf '{"amount":0,"currency":"USD","auto_reload_settings":null,"expiry_policy_months":null}' > "$FIX_CREDITS"
printf '{"extra_usage":{"is_enabled":false,"monthly_limit":4000,"used_credits":0.0,"utilization":0.0,"currency":"USD","decimal_places":2,"disabled_reason":"out_of_credits","user_disabled":false}}' > "$FIX_USAGE"
run_fetch; IFS='|' read -r st ts bal used lim en ar tot drop cur why dp < "$HOME/.claude/credit-live"
assert_eq "real response: ok" "$st" ok; assert_eq "balance 0" "$bal" 0; assert_eq "used 0.0 floored" "$used" 0
assert_eq "limit 4000" "$lim" 4000; assert_eq "disabled" "$en" 0; assert_eq "reason captured" "$why" out_of_credits
assert_eq "decimals captured" "$dp" 2; assert_eq "null auto_reload -> 0" "$ar" 0
o=$(line2 "$SUB");            assert_has "out of credits -> not in use, quota row" "$o" "Session: 16%"
o=$(line1 "$SUB");            assert_has "out of credits -> line-1 says so" "$o" "· no credits"
                              assert_not "out of credits -> no bare \$0.00" "$o" 'credits $0.00'
printf 'MODE=credits\n' > "$HOME/.claude/credit-config"
o=$(line2 "$SUB");            assert_has "forced row names the state" "$o" "Credits: out of credits"
                              assert_has "forced row says what to do" "$o" "top up"
rm -f "$HOME/.claude/credit-config"
echo "fetcher: zero-decimal currency is not divided by 100"
printf '{"amount":5000,"currency":"JPY"}' > "$FIX_CREDITS"
printf '{"extra_usage":{"is_enabled":true,"monthly_limit":null,"used_credits":1000,"decimal_places":0}}' > "$FIX_USAGE"
run_fetch; IFS='|' read -r st ts bal used lim en ar tot drop cur why dp < "$HOME/.claude/credit-live"
assert_eq "decimals 0 captured" "$dp" 0
printf '%s|%s|5000|1000||1|0|6000|%s|JPY||0\n' ok "$NOW" "$((NOW-30))" > "$HOME/.claude/credit-live"
o=$(line2 "$SUB");            assert_has "JPY shown whole, not /100" "$o" '$5000 left of $6000'
printf '{"amount":6000,"currency":"USD"}' > "$FIX_CREDITS"
printf '{"extra_usage":{"is_enabled":true,"monthly_limit":10000,"used_credits":0,"decimal_places":2}}' > "$FIX_USAGE"

echo "fetcher: hostile cache lines are sanitised, not re-emitted"
printf 'ok|1|35|$(touch %s/pwned)|1|2|xyz|4000|1|US$D\r|extra|more\n' "$T" > "$HOME/.claude/credit-live"
CODE_CREDITS=500 run_fetch; c=$(cat "$HOME/.claude/credit-live")
assert_eq "hostile line after 500 -> 12 clean fields" "$(printf '%s' "$c" | awk -F'|' '{print NF}')" 12
assert_eq "hostile used field dropped" "$(printf '%s' "$c" | cut -d'|' -f4)" ""
assert_eq "en=2 dropped" "$(printf '%s' "$c" | cut -d'|' -f6)" ""; assert_eq "ar=xyz dropped" "$(printf '%s' "$c" | cut -d'|' -f7)" ""
assert_eq "currency sanitised" "$(printf '%s' "$c" | cut -d'|' -f10)" "USD"
[ ! -f "$T/pwned" ] && ok "nothing executed" || bad "cache content executed"
printf 'ok|1|4000|0|10000|1|0|99999999999999999999|1|USD\n' > "$HOME/.claude/credit-live"
run_fetch; IFS='|' read -r st ts bal used lim en ar tot drop cur why dp < "$HOME/.claude/credit-live"
assert_eq "20-digit total replaced on success" "$tot" 6000
for bad_total in 'TOTAL=1e5' 'TOTAL=40; rm -rf ~' 'TOTAL=40.5.5' ' TOTAL=40' 'TOTAL=99999999999999999999'; do
    printf '%s\n' "$bad_total" > "$HOME/.claude/credit-config"
    run_fetch; assert_eq "<$bad_total> ignored" "$(cut -d'|' -f8 "$HOME/.claude/credit-live")" 6000
done
for good_total in 'TOTAL="40"' $'TOTAL=40\r' 'TOTAL=40.50 '; do
    printf '%s\n' "$good_total" > "$HOME/.claude/credit-config"
    run_fetch; t=$(cut -d'|' -f8 "$HOME/.claude/credit-live")
    case "$good_total" in *40.50*) assert_eq "<$good_total> accepted" "$t" 4050 ;; *) assert_eq "<$good_total> accepted" "$t" 4000 ;; esac
done
rm -f "$HOME/.claude/credit-config"; run_fetch

echo "fetcher: --print never dumps a non-JSON body; xtrace cannot leak"
printf '<html>502 upstream org-fleet-42 five_hour=88%%</html>' > "$FIX_USAGE"
p=$(CODE_USAGE=502 run_fetch --print); assert_not "html usage body not echoed" "$p" "org-fleet"
assert_has "non-JSON summarised by size" "$p" "non-JSON body"
printf '{"five_hour":{"utilization":88},"extra_usage":{"is_enabled":true,"monthly_limit":10000,"used_credits":0}}' > "$FIX_USAGE"
p=$(run_fetch --print); assert_not "plan windows not echoed from usage" "$p" "five_hour"
rmdir "$HOME/.claude/credit-live.lock" 2>/dev/null
e=$(env SHELLOPTS=xtrace /bin/bash "$HOME/.claude/credit-balance.sh" --print 2>&1 >/dev/null)
assert_not "inherited xtrace does not print the token" "$e" "SECRET"
rm -rf "$HOME/.claude/credit-live.lock"

echo "fetcher: auth edge cases"
past=$(( (NOW - 60) * 1000 ))
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-SECRETSECRET","expiresAt":%s}}' "$past" > "$T/creds.json"
: > "$CURL_LOG"; run_fetch; c=$(cat "$HOME/.claude/credit-live")
assert_has "expired token -> expired, no request" "$c" "expired|"; assert_eq "expired -> curl not called" "$(cat "$CURL_LOG")" ""
: > "$T/creds.json"; run_fetch; c=$(cat "$HOME/.claude/credit-live")
assert_has "empty keychain -> noauth" "$c" "noauth|"
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-SECRETSECRET","expiresAt":%s}}' "$future" > "$T/creds.json"
printf '{"oauthAccount":{"organizationUuid":"../../evil"}}' > "$HOME/.claude.json"
: > "$CURL_LOG"; run_fetch; c=$(cat "$HOME/.claude/credit-live")
assert_has "bad org uuid -> noauth" "$c" "noauth|"; assert_eq "bad org -> curl not called" "$(cat "$CURL_LOG")" ""
printf '{"oauthAccount":{"organizationUuid":"4c48ce7b-e985-4588-a015-06b81a069593"}}' > "$HOME/.claude.json"

echo "fetcher: lock"
rm -rf "$HOME/.claude/credit-live.lock"; mkdir "$HOME/.claude/credit-live.lock"; rm -f "$HOME/.claude/credit-live"
/bin/bash "$HOME/.claude/credit-balance.sh"
[ ! -f "$HOME/.claude/credit-live" ] && ok "fresh lock held -> exits without fetching" || bad "fetched despite lock"
[ -d "$HOME/.claude/credit-live.lock" ] && ok "foreign fresh lock left alone" || bad "foreign lock removed"
touch -t "$(date -v-2M +%Y%m%d%H%M.%S 2>/dev/null || date -d '-2 min' +%Y%m%d%H%M.%S)" "$HOME/.claude/credit-live.lock" 2>/dev/null
/bin/bash "$HOME/.claude/credit-balance.sh"
[ -f "$HOME/.claude/credit-live" ] && ok "stale lock reclaimed" || bad "stale lock not reclaimed"
[ ! -d "$HOME/.claude/credit-live.lock" ] && ok "lock released on exit" || bad "lock left behind"
# 8 starters against one stale lock: exactly one may fetch (2 curl calls).
rm -rf "$HOME/.claude/credit-live.lock"; mkdir "$HOME/.claude/credit-live.lock"
touch -t "$(date -v-2M +%Y%m%d%H%M.%S 2>/dev/null || date -d '-2 min' +%Y%m%d%H%M.%S)" "$HOME/.claude/credit-live.lock" 2>/dev/null
: > "$CURL_LOG"
for i in 1 2 3 4 5 6 7 8; do CURL_DELAY=1 /bin/bash "$HOME/.claude/credit-balance.sh" & done; wait
assert_eq "8 starters on a stale lock -> one fetcher" "$(grep -c . "$CURL_LOG")" 2
[ ! -d "$HOME/.claude/credit-live.lock" ] && ok "no lock left after the race" || bad "lock left after the race"
: > "$CURL_LOG"
for i in 1 2 3 4 5 6 7 8; do CURL_DELAY=1 /bin/bash "$HOME/.claude/credit-balance.sh" & done; wait
assert_eq "8 starters, no lock -> one fetcher" "$(grep -c . "$CURL_LOG")" 2

echo "ccredit"
cp "$HERE/ccredit" "$HOME/.claude/ccredit"; chmod +x "$HOME/.claude/ccredit"
o=$(/bin/bash "$HOME/.claude/ccredit" mode credits); assert_has "mode credits" "$o" "row mode: credits"
assert_eq "config has MODE" "$(grep -c '^MODE=credits' "$HOME/.claude/credit-config")" 1
o=$(/bin/bash "$HOME/.claude/ccredit" total 40); assert_has "total 40" "$o" 'meter total set to $40.00'
assert_eq "MODE survives total" "$(grep -c '^MODE=credits' "$HOME/.claude/credit-config")" 1
/bin/bash "$HOME/.claude/ccredit" total auto >/dev/null; assert_eq "total auto removes TOTAL" "$(grep -c '^TOTAL=' "$HOME/.claude/credit-config")" 0
o=$(/bin/bash "$HOME/.claude/ccredit" mode bogus 2>&1); assert_has "mode bogus rejected" "$o" "usage"
o=$(/bin/bash "$HOME/.claude/ccredit" total 'abc' 2>&1); assert_has "total abc rejected" "$o" "usage"
o=$(/bin/bash "$HOME/.claude/ccredit" show); assert_has "show prints balance" "$o" 'balance      $60.00'
assert_has "show prints mode" "$o" "row mode     credits"
o=$(/bin/bash "$HOME/.claude/ccredit" source manual); assert_has "source manual" "$o" "balance source: manual"
o=$(/bin/bash "$HOME/.claude/ccredit" source bogus 2>&1); assert_has "source bogus rejected" "$o" "usage"
o=$(/bin/bash "$HOME/.claude/ccredit" set 35.30); assert_has "legacy set still works" "$o" 'anchored at $35.30'
o=$(/bin/bash "$HOME/.claude/ccredit" show); assert_has "show reports the source" "$o" "source       manual"
assert_has "show reports the anchor" "$o" 'hand anchor  $35.30'
/bin/bash "$HOME/.claude/ccredit" source live >/dev/null
assert_eq "set keeps MODE" "$(grep -c '^MODE=credits' "$HOME/.claude/credit-config")" 1
assert_eq "set writes BALANCE_AT" "$(grep -c '^BALANCE_AT=' "$HOME/.claude/credit-config")" 1

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
