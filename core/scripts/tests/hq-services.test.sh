#!/usr/bin/env bash
# hq-core: public
# Regression: core/scripts/hq-services.sh — HQ Pro services proxy client.
#
# Cases:
#   1. search → POST /services/search with bearer token from identity-resolve, search_id kept
#   2. follow-up search carries search_id; browse/info hit the right routes
#   3. login_required → exit 3, no HTTP request
#   4. 401 → one forced refresh, then success
#   5. provision/status are not commands (removed until hq-pro ships the proxy)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SVC="$ROOT/core/scripts/hq-services.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
[ -f "$SVC" ] || { echo "FAIL: missing $SVC" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hq-services-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
LOG="$TMP/curl.log"; : > "$LOG"
FIX="$TMP/fixtures"; mkdir -p "$FIX"

# --- stubs -------------------------------------------------------------------

# curl stub: reads `-K -` config from stdin (where the bearer lives), records
# method/url/body/headers to $LOG, and serves $FIX/<route>.json with the status
# in $FIX/<route>.status (default 200). Route = file named by $CURL_ROUTE_FN.
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
method=GET; url=""; out=""; data=""; cfg=""
args=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -K) [ "$2" = "-" ] && cfg="$(cat)"; shift 2 ;;
    --data-binary) data="$(cat "${2#@}")"; shift 2 ;;
    -H|-m|-w) shift 2 ;;
    -sS|-s) shift ;;
    *) url="$1"; shift ;;
  esac
done
for a in "${args[@]}"; do
  case "$a" in *Bearer*|*Authorization*) echo "TOKEN_ON_ARGV" >> "$CURL_LOG" ;; esac
done
printf '%s %s\n' "$method" "$url" >> "$CURL_LOG"
[ -n "$cfg" ] && printf 'CFG %s\n' "$cfg" >> "$CURL_LOG"
[ -n "$data" ] && printf 'BODY %s\n' "$data" >> "$CURL_LOG"
route="$(printf '%s' "$url" | sed -e 's#^[a-z]*://[^/]*##' -e 's#?.*##' -e 's#^/##' -e 's#/#_#g')"
status=200
[ -f "$CURL_FIX/$route.status" ] && status="$(cat "$CURL_FIX/$route.status")"
# One-shot status override (401-then-200 case).
if [ -f "$CURL_FIX/$route.status.once" ]; then
  status="$(cat "$CURL_FIX/$route.status.once")"; rm -f "$CURL_FIX/$route.status.once"
fi
if [ -f "$CURL_FIX/$route.json" ]; then cp "$CURL_FIX/$route.json" "$out"; else printf '{"detail":"no fixture %s"}' "$route" > "$out"; status=404; fi
printf '%s' "$status"
STUB
chmod +x "$BIN/curl"

# identity-resolve stub: driven by $IDENTITY_MODE; counts --force-refresh calls.
IDRES="$TMP/identity-resolve.sh"
cat > "$IDRES" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "--force-refresh" ] && echo refresh >> "$IDENTITY_CALLS"
case "${IDENTITY_MODE:-ok}" in
  ok) printf '{"status":"ok","jwt":"access-tok","id_token":"id-tok-secret","identity":"person","expires_at":1,"source":"cache"}\n' ;;
  login_required) printf '{"status":"login_required","reason":"no cached token"}\n' ;;
esac
STUB
chmod +x "$IDRES"

export PATH="$BIN:$PATH"
export CURL_LOG="$LOG" CURL_FIX="$FIX"
export IDENTITY_CALLS="$TMP/identity.calls"; : > "$IDENTITY_CALLS"
export HQ_SERVICES_IDENTITY_RESOLVE="$IDRES"
export HQ_PRO_API_URL="https://hqapi.test"
export HQ_ROOT="$TMP/hqroot"; mkdir -p "$HQ_ROOT/core/scripts"   # no hq-session.sh → no session_id

run() { set +e; OUT="$(bash "$SVC" "$@" 2>"$TMP/err")"; RC=$?; set -e; ERR="$(cat "$TMP/err")"; }

# --- fixtures ----------------------------------------------------------------
cat > "$FIX/services_search.json" <<'JSON'
{"search_id":"srch_123","recommendation":{"slug":"supabase","name":"Supabase","category":"database"},
 "reasoning":"Postgres with auth built in.",
 "install":{"steps":[{"step":1,"action":"Install client","command":"npm i @supabase/supabase-js"}],"env_vars":["SUPABASE_URL","SUPABASE_ANON_KEY"]},
 "credential_request":{"setup_url":"https://index.trygravity.ai/c/abc","user_message":"Open the setup link."},
 "click_url":"https://index.trygravity.ai/c/abc"}
JSON
cat > "$FIX/services.json" <<'JSON'
{"total":2,"services":[{"slug":"supabase","name":"Supabase","category":"database","description":"Postgres"},{"slug":"clerk","name":"Clerk","category":"auth","description":"Auth"}]}
JSON
cat > "$FIX/services_supabase.json" <<'JSON'
{"slug":"supabase","name":"Supabase","category":"database","description":"Postgres","env_vars_needed":["SUPABASE_URL"],"provisioning_mode":"api"}
JSON

# --- 1. search ---------------------------------------------------------------
run search "postgres database with auth"
[ "$RC" = 0 ] || fail "search rc=$RC: $ERR"
grep -q '^POST https://hqapi.test/services/search$' "$LOG" || fail "search route: $(cat "$LOG")"
grep -q '^CFG header = "Authorization: Bearer id-tok-secret"$' "$LOG" || fail "bearer not sent via curl config"
grep -q 'TOKEN_ON_ARGV' "$LOG" && fail "token leaked to curl argv"
grep -q '^BODY {"query":"postgres database with auth"}$' "$LOG" || fail "search body: $(grep BODY "$LOG")"
printf '%s' "$OUT" | grep -q 'Supabase' || fail "search output missing recommendation"
printf '%s' "$OUT" | grep -q 'search_id: srch_123' || fail "search output missing search_id"
printf '%s' "$OUT" | grep -q 'id-tok-secret' && fail "token in stdout"
pass "search → POST /services/search with bearer, search_id surfaced"

# --- 2. follow-up + routes ---------------------------------------------------
: > "$LOG"
run search "cheaper option" --follow-up srch_123 --json
[ "$RC" = 0 ] || fail "follow-up rc=$RC: $ERR"
grep -q '^BODY {"query":"cheaper option","search_id":"srch_123"}$' "$LOG" || fail "follow-up body: $(grep BODY "$LOG")"
printf '%s' "$OUT" | jq -e '.search_id == "srch_123"' >/dev/null || fail "--json not raw"
: > "$LOG"
run browse "auth"
[ "$RC" = 0 ] || fail "browse rc=$RC: $ERR"
grep -q '^GET https://hqapi.test/services?q=auth$' "$LOG" || fail "browse route: $(cat "$LOG")"
printf '%s' "$OUT" | grep -q 'clerk' || fail "browse output"
: > "$LOG"
run info supabase
[ "$RC" = 0 ] || fail "info rc=$RC: $ERR"
grep -q '^GET https://hqapi.test/services/supabase$' "$LOG" || fail "info route"
printf '%s' "$OUT" | grep -q 'Env vars: SUPABASE_URL' || fail "info output"
pass "follow-up search_id, browse/info routes"

# --- 3. not signed in --------------------------------------------------------
: > "$LOG"
IDENTITY_MODE=login_required run search "anything"
[ "$RC" = 3 ] || fail "login_required rc=$RC (want 3): $ERR"
[ ! -s "$LOG" ] || fail "request sent while logged out"
printf '%s' "$ERR" | grep -q '/hq-login' || fail "no login hint: $ERR"
pass "login_required → exit 3, no request"

# --- 4. 401 → forced refresh once --------------------------------------------
: > "$LOG"; : > "$IDENTITY_CALLS"
echo 401 > "$FIX/services_search.status.once"
run search "retry me"
[ "$RC" = 0 ] || fail "401 retry rc=$RC: $ERR"
[ "$(grep -c '^POST https://hqapi.test/services/search$' "$LOG")" = 2 ] || fail "expected 2 requests: $(cat "$LOG")"
[ "$(grep -c refresh "$IDENTITY_CALLS")" = 1 ] || fail "expected one --force-refresh"
pass "401 → one forced refresh → retry"

# --- 5. provision/status removed ---------------------------------------------
: > "$LOG"
run provision supabase --consent
[ "$RC" = 2 ] || fail "provision rc=$RC (want 2 = unknown command): $ERR"
[ ! -s "$LOG" ] || fail "provision sent a request"
run status prov_1
[ "$RC" = 2 ] || fail "status rc=$RC (want 2 = unknown command): $ERR"
[ ! -s "$LOG" ] || fail "status sent a request"
grep -q 'index.trygravity.ai\|GRAVITY_PUBLISHER_KEY\|hq secrets' "$SVC" && fail "client must not call the Index directly, hold a publisher key, or write secrets"
pass "provision/status are not commands; no direct Index calls or secret writes"

echo "PASS: hq-services.test.sh"
