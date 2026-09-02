#!/usr/bin/env bash
# Fetches real billed spend since the credit anchor from the Usage & Cost Admin API
# and caches it. Run detached by statusline.sh; never called on the render path.
#
# Cache format, one line:  <dollars>|<epoch>|<status>
# status: ok | nokey | http_<code> | nocurl
#
# cost_report returns `amount` in LOWEST CURRENCY UNITS (cents) as a decimal
# string - "123.45" means $1.23. Hence the /100.
set -uo pipefail

CFG="$HOME/.claude/credit-config"
CACHE="${TMPDIR:-/tmp}/cc-credit-spend-$(id -u)"
KEYFILE="$HOME/.claude/.cost-api-key"

emit() { printf '%s|%s|%s\n' "$1" "$(date +%s)" "$2" > "$CACHE"; exit 0; }

command -v curl >/dev/null 2>&1 || emit 0 nocurl
[ -f "$CFG" ] || emit 0 nokey
. "$CFG"
: "${BALANCE_AT:=}"
[ -n "$BALANCE_AT" ] || emit 0 nokey

KEY="${ANTHROPIC_ADMIN_KEY:-}"
[ -z "$KEY" ] && [ -f "$KEYFILE" ] && KEY=$(tr -d ' \t\r\n' < "$KEYFILE")
[ -n "$KEY" ] || emit 0 nokey

# Admin API keys go on x-api-key; org:admin OAuth tokens go on Authorization: Bearer.
case "$KEY" in
    sk-ant-*) AUTH_H="x-api-key: $KEY" ;;
    *)        AUTH_H="Authorization: Bearer $KEY" ;;
esac

total=0 page='' status=ok
for _ in 1 2 3 4 5 6 7 8 9 10; do
    url="https://api.anthropic.com/v1/organizations/cost_report?starting_at=${BALANCE_AT}&bucket_width=1d&limit=31"
    [ -n "$page" ] && url="${url}&page=${page}"
    body=$(curl -sS --max-time 20 -w $'\n%{http_code}' "$url" \
             -H 'anthropic-version: 2023-06-01' -H "$AUTH_H" \
             -H 'User-Agent: cc-statusline-credit/1.0' 2>/dev/null)
    code=${body##*$'\n'}
    json=${body%$'\n'*}
    case "$code" in
        200) ;;
        *) status="http_${code:-000}"; break ;;
    esac
    sum=$(printf '%s' "$json" | jq -r '[.data[]?.results[]?.amount | tonumber] | add // 0' 2>/dev/null)
    case "$sum" in ''|*[!0-9.eE+-]*) sum=0 ;; esac
    total=$(awk -v a="$total" -v b="$sum" 'BEGIN{printf "%.6f", a+b}')
    more=$(printf '%s' "$json" | jq -r '.has_more // false' 2>/dev/null)
    page=$(printf '%s' "$json" | jq -r '.next_page // ""' 2>/dev/null)
    [ "$more" = true ] && [ -n "$page" ] || break
done

[ "$status" = ok ] || emit 0 "$status"
emit "$(awk -v c="$total" 'BEGIN{printf "%.4f", c/100}')" ok
