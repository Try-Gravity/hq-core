#!/usr/bin/env bash
# hq-services.sh — find and set up developer services through the HQ Pro
# services proxy (backed by Gravity Index).
#
# Usage:
#   core/scripts/hq-services.sh search "<what you need>" [--follow-up <search_id>] [--json]
#   core/scripts/hq-services.sh browse [query] [--json]
#   core/scripts/hq-services.sh info <slug> [--json]
#   core/scripts/hq-services.sh provision <slug> --consent [--search-id <id>] [--json]
#   core/scripts/hq-services.sh status <provision_id> [--json]
#
# Global flags: --company <slug> | --personal   (secret scope for `hq secrets`)
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
# provision: the human must have said yes for THIS service in THIS session;
# `--consent` records that. Without it the command exits 4 before any request.
# Credentials come back as a one-time `credentials_url` (a Gravity keystore
# link; the token in the URL is the bearer). This script POSTs it once, writes
# each key with `hq secrets set <KEY> --from-stdin`, and prints the key names
# only. Values are never printed or written to disk.
#
# Exit: 0 ok, 1 API/HTTP error, 2 usage, 3 not signed in, 4 consent missing,
#       5 secret write failed (credentials were retrieved and the link is burned;
#       the vendor's ownership email is the recovery path).
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
  sed -n '5,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

# --- args --------------------------------------------------------------------
CMD="${1:-}"
[ -n "$CMD" ] || usage
shift

SCOPE_ARGS=()
JSON=0
FOLLOW_UP=""
SEARCH_ID=""
CONSENT=0
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --company)   [ $# -ge 2 ] || die "--company needs a slug"; SCOPE_ARGS=(--company "$2"); shift 2 ;;
    --personal)  SCOPE_ARGS=(--personal); shift ;;
    --json)      JSON=1; shift ;;
    --follow-up) [ $# -ge 2 ] || die "--follow-up needs a search_id"; FOLLOW_UP="$2"; shift 2 ;;
    --search-id) [ $# -ge 2 ] || die "--search-id needs an id"; SEARCH_ID="$2"; shift 2 ;;
    --consent)   CONSENT=1; shift ;;
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
    (if .recommendation then "\nProvision (only after the user says yes): hq services provision \(.recommendation.slug) --search-id \(.search_id) --consent" else empty end),
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
    (if .provisioning_mode then "\nProvisioning: \(.provisioning_mode)" else empty end),
    (if (.setup_url // .click_url) then "\nSetup link: \(.setup_url // .click_url)" else empty end)
  ' "$BODY_FILE"
}

cmd_provision() {
  [ -n "$ARG1" ] || die "provision needs a service slug"
  [ "$CONSENT" = 1 ] || die "provision requires --consent: ask the user \"Want me to create a $ARG1 account for you?\" and pass --consent only after a yes." 4
  command -v hq >/dev/null 2>&1 || die "hq CLI is required to store provisioned credentials" 5

  local body status
  body="$(jq -nc --arg slug "$ARG1" --arg sidx "$SEARCH_ID" --arg s "$(session_id)" \
    '{service_slug:$slug, user_consent:true}
     + (if $sidx != "" then {search_id:$sidx} else {} end)
     + (if $s != "" then {session_id:$s} else {} end)')"
  status="$(api POST /services/provision "$body")"
  [ "$status" = 201 ] || [ "$status" = 200 ] || fail_http "$status"

  local resp cred_url provision_id
  resp="$(cat "$BODY_FILE")"
  provision_id="$(printf '%s' "$resp" | jq -r '.provision_id // ""')"
  cred_url="$(printf '%s' "$resp" | jq -r '.credentials_url // ""')"

  local stored="[]" failed=0
  if [ -n "$cred_url" ]; then
    # One-time keystore link: the POST burns it. Retrieve, store, forget.
    # The URL carries its own bearer token, so no HQ token goes with it.
    status="$("$CURL_BIN" -sS -m 45 -o "$BODY_FILE" -w '%{http_code}' -X POST \
      -H 'Accept: application/json' "$cred_url")" || die "credentials keystore unreachable" 1
    [ "$status" = 200 ] || fail_http "$status"
    local key
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      if jq -r --arg k "$key" '.credentials[$k] | if type == "string" then . else tojson end' "$BODY_FILE" \
        | hq secrets ${SCOPE_ARGS[@]+"${SCOPE_ARGS[@]}"} set "$key" --from-stdin >/dev/null 2>&1; then
        stored="$(printf '%s' "$stored" | jq -c --arg k "$key" '. + [$k]')"
      else
        failed=1
        echo "hq-services: failed to store secret $key" >&2
      fi
    done < <(jq -r '.credentials // {} | keys[]' "$BODY_FILE")
    : > "$BODY_FILE"
  fi

  if [ "$JSON" = 1 ]; then
    printf '%s' "$resp" | jq --argjson stored "$stored" \
      'del(.credentials_url) | .secrets_stored = $stored'
  else
    printf '%s' "$resp" | jq -r --argjson stored "$stored" '
      "Provisioned \(.service_slug)  (status: \(.status), mode: \(.provisioning_mode // ""))",
      "provision_id: \(.provision_id)",
      (if ($stored|length) > 0 then "Secrets stored in hq secrets: \($stored|join(", "))  — use `hq secrets exec --only \($stored|join(","))` or `hq run`" else empty end),
      (if .ownership_url then "\nTake ownership of the vendor account: \(.ownership_url)" + (if .ownership_expires_at then "  (expires \(.ownership_expires_at))" else "" end) else empty end),
      (if .signup_url then "\nFinish sign-up: \(.signup_url)" else empty end),
      (if (.integration_steps // []) | length > 0 then "\nIntegration steps:\n" + ((.integration_steps) | map("  \(.step // "?"). \(.action // "")" + (if .command then "\n     $ \(.command)" else "" end)) | join("\n")) else empty end),
      (if (.env_vars // []) | length > 0 then "\nEnv vars: \(.env_vars | join(", "))" else empty end)
    '
  fi
  [ "$failed" = 0 ] || die "some credentials were not stored; the one-time link is used up. Recover through the vendor ownership email for provision $provision_id." 5
}

cmd_status() {
  [ -n "$ARG1" ] || die "status needs a provision_id"
  local status
  status="$(api GET "/services/provision/$(uri "$ARG1")")"
  [ "$status" = 200 ] || fail_http "$status"
  [ "$JSON" = 1 ] && { emit_json; return; }
  jq -r '"\(.service_slug)  \(.status)  (mode: \(.provisioning_mode // ""), created: \(.created_at // ""), expires: \(.expires_at // "n/a"), credentials fingerprint: \(.credentials_fingerprint // "n/a"))"' "$BODY_FILE"
}

case "$CMD" in
  search)    cmd_search ;;
  browse)    cmd_browse ;;
  info)      cmd_info ;;
  provision) cmd_provision ;;
  status)    cmd_status ;;
  -h|--help|help) usage ;;
  *) die "unknown command: $CMD (search|browse|info|provision|status)" ;;
esac
