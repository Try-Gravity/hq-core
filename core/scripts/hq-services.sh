#!/usr/bin/env bash
# hq-services.sh — find developer services through the HQ Pro services proxy
# (backed by Gravity Index). Read-only: search, browse, info.
#
# Usage:
#   core/scripts/hq-services.sh search "<what you need>" [--follow-up <search_id>] [--json]
#   core/scripts/hq-services.sh browse [query] [--json]
#   core/scripts/hq-services.sh info <slug> [--json]
#
# Auth: every call goes to the HQ Pro API (`/services/*`) with the caller's HQ
# Cognito token from .claude/skills/deploy/scripts/identity-resolve.sh. The
# Gravity Index publisher key never leaves HQ Pro; this client never sees it.
# Not signed in → exit 3 (run /hq-login). A 401 is retried once after a forced
# token refresh, then exits 3.
#
# API base: HQ_PRO_API_URL → HQ_API_URL → HQ_VAULT_API_URL → https://hqapi.hq.computer
# Server contract: core/knowledge/public/hq-core/hq-services-proxy-spec.md
#
# Exit: 0 ok, 1 API/HTTP error, 2 usage, 3 not signed in.
set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
API_BASE="${HQ_PRO_API_URL:-${HQ_API_URL:-${HQ_VAULT_API_URL:-https://hqapi.hq.computer}}}"
API_BASE="${API_BASE%/}"
IDENTITY_RESOLVE="${HQ_SERVICES_IDENTITY_RESOLVE:-$HQ_ROOT/.claude/skills/deploy/scripts/identity-resolve.sh}"
CURL_BIN="${HQ_SERVICES_CURL:-curl}"

die() { echo "hq-services: $*" >&2; exit "${2:-2}"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need jq
need "$CURL_BIN"

usage() {
  sed -n '5,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

# --- args --------------------------------------------------------------------
CMD="${1:-}"
[ -n "$CMD" ] || usage
shift

JSON=0
FOLLOW_UP=""
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json)      JSON=1; shift ;;
    --follow-up) [ $# -ge 2 ] || die "--follow-up needs a search_id"; FOLLOW_UP="$2"; shift 2 ;;
    -h|--help)   usage ;;
    --*)         die "unknown flag: $1" ;;
    *)           POS+=("$1"); shift ;;
  esac
done
ARG1="${POS[0]+${POS[0]}}"

# --- auth --------------------------------------------------------------------
TOKEN=""
# resolve_token [--force-refresh]: sets TOKEN from identity-resolve.sh, never prints it.
resolve_token() {
  local out status
  [ -f "$IDENTITY_RESOLVE" ] || die "identity resolver missing: $IDENTITY_RESOLVE" 3
  out="$(bash "$IDENTITY_RESOLVE" "$@" 2>/dev/null || true)"
  status="$(printf '%s' "$out" | jq -r '.status // "error"' 2>/dev/null || echo error)"
  case "$status" in
    ok) TOKEN="$(printf '%s' "$out" | jq -r '.id_token // .jwt // empty')" ;;
    login_required) die "not signed in to HQ ($(printf '%s' "$out" | jq -r '.reason // "login required"')). Run /hq-login and retry." 3 ;;
    missing_dependency) die "$(printf '%s' "$out" | jq -r '"missing dependency \(.dep): \(.install // "")"')" 3 ;;
    *) die "could not resolve HQ identity (identity-resolve.sh returned: ${status})" 3 ;;
  esac
  [ -n "$TOKEN" ] || die "HQ identity resolved without a token; run /hq-login" 3
}

# --- http --------------------------------------------------------------------
BODY_FILE="$(mktemp "${TMPDIR:-/tmp}/hq-services-body.XXXXXX")"
REQ_FILE="$(mktemp "${TMPDIR:-/tmp}/hq-services-req.XXXXXX")"
trap 'rm -f "$BODY_FILE" "$REQ_FILE"' EXIT

# raw_request <method> <url> [json-body] → HTTP status; body in $BODY_FILE.
# The bearer token reaches curl through a config on stdin, never via argv.
raw_request() {
  local method="$1" url="$2" data="${3:-}" status
  local -a extra=()
  if [ -n "$data" ]; then
    printf '%s' "$data" > "$REQ_FILE"
    extra=(-H 'Content-Type: application/json' --data-binary "@$REQ_FILE")
  fi
  status="$( { [ -n "$TOKEN" ] && printf 'header = "Authorization: Bearer %s"\n' "$TOKEN"; true; } \
    | "$CURL_BIN" -sS -m 45 -K - -o "$BODY_FILE" -w '%{http_code}' -X "$method" \
      -H 'Accept: application/json' ${extra[@]+"${extra[@]}"} "$url")" \
    || die "HQ API unreachable ($url)" 1
  printf '%s' "$status"
}

# api <method> <path> [json-body] → HTTP status. One forced token refresh on 401.
api() {
  local method="$1" path="$2" data="${3:-}" status
  [ -n "$TOKEN" ] || resolve_token
  status="$(raw_request "$method" "$API_BASE$path" "$data")"
  if [ "$status" = 401 ]; then
    resolve_token --force-refresh
    status="$(raw_request "$method" "$API_BASE$path" "$data")"
    [ "$status" = 401 ] && die "HQ rejected the session token (401). Run /hq-login and retry." 3
  fi
  printf '%s' "$status"
}

fail_http() {
  local status="$1" detail
  detail="$(jq -r '.detail // .error // .message // empty' "$BODY_FILE" 2>/dev/null || true)"
  [ -n "$detail" ] || detail="$(head -c 300 "$BODY_FILE")"
  case "$status" in
    403) die "HTTP 403: $detail (your HQ company may not have services enabled)" 1 ;;
    404) die "HTTP 404: $detail (is the HQ Pro services proxy deployed at $API_BASE?)" 1 ;;
    *)   die "HTTP $status: $detail" 1 ;;
  esac
}

emit_json() { jq . "$BODY_FILE"; }
uri() { jq -rn --arg v "$1" '$v|@uri'; }
session_id() { bash "$HQ_ROOT/core/scripts/hq-session.sh" current 2>/dev/null || true; }

# --- commands ----------------------------------------------------------------
cmd_search() {
  [ -n "$ARG1" ] || die "search needs a query"
  local body status
  body="$(jq -nc --arg q "$ARG1" --arg f "$FOLLOW_UP" --arg s "$(session_id)" \
    '{query:$q}
     + (if $f != "" then {search_id:$f} else {} end)
     + (if $s != "" then {session_id:$s} else {} end)')"
  status="$(api POST /services/search "$body")"
  [ "$status" = 200 ] || fail_http "$status"
  [ "$JSON" = 1 ] && { emit_json; return; }
  jq -r '
    def steps(xs): xs | map(
      "  \(.step // "?"). \(.action // "")"
      + (if .command then "\n     $ \(.command)" else "" end)
      + (if .user_action then "\n     \(.user_action)" else "" end)) | join("\n");
    (if .recommendation then "\(.recommendation.name)  (\(.recommendation.category // "") · slug: \(.recommendation.slug // ""))"
     else "No matching service in the Index." end),
    (if .reasoning then "\n\(.reasoning)" else empty end),
    (if (.install.steps // []) | length > 0 then "\nIntegration steps:\n" + steps(.install.steps) else empty end),
    (if (.install.env_vars // []) | length > 0 then "\nEnv vars: \(.install.env_vars | join(", "))" else empty end),
    (if (.credential_request.setup_url // .click_url) then "\nSetup link: \(.credential_request.setup_url // .click_url)" else empty end),
    (if .credential_request.user_message then "\(.credential_request.user_message)" else empty end),
    "\nsearch_id: \(.search_id // "")"
  ' "$BODY_FILE"
}

cmd_browse() {
  local qs="" status
  [ -n "$ARG1" ] && qs="?q=$(uri "$ARG1")"
  status="$(api GET "/services$qs")"
  [ "$status" = 200 ] || fail_http "$status"
  [ "$JSON" = 1 ] && { emit_json; return; }
  jq -r '
    "Gravity Index — \(.total // (.services|length)) services",
    (.services[] | "\n\(.slug)  \(.name)  [\(.category // "")]"
      + "\n  \(.description // "" | .[0:120])")
  ' "$BODY_FILE"
}

cmd_info() {
  [ -n "$ARG1" ] || die "info needs a service slug"
  local status
  status="$(api GET "/services/$(uri "$ARG1")")"
  [ "$status" = 200 ] || fail_http "$status"
  [ "$JSON" = 1 ] && { emit_json; return; }
  jq -r '
    "\(.name)  (\(.category // "") · slug: \(.slug // ""))",
    "\n\(.description // "")",
    (if .pricing then "\nPricing: \(.pricing | if type == "string" then . else tojson end)" else empty end),
    (if .install_summary then "\nInstall: \(.install_summary)" else empty end),
    (if (.install_steps // []) | length > 0 then "\nSteps:\n" + ((.install_steps) | map("  \(.step // "?"). \(.action // "")" + (if .command then "\n     $ \(.command)" else "" end)) | join("\n")) else empty end),
    (if (.env_vars_needed // []) | length > 0 then "\nEnv vars: \(.env_vars_needed | join(", "))" else empty end),
    (if (.setup_url // .click_url) then "\nSetup link: \(.setup_url // .click_url)" else empty end)
  ' "$BODY_FILE"
}

case "$CMD" in
  search) cmd_search ;;
  browse) cmd_browse ;;
  info)   cmd_info ;;
  -h|--help|help) usage ;;
  *) die "unknown command: $CMD (search|browse|info)" ;;
esac
