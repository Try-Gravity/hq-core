# HQ services proxy — hq-pro contract for `hq services`

`hq services` (client: `core/scripts/hq-services.sh`, skill: `/hq-services`)
finds developer services through **Gravity Index**
(`https://index.trygravity.ai`). The client never talks to the Index directly.
It calls **hq-pro** with the caller's HQ Cognito token; hq-pro holds HQ's
Gravity publisher key and forwards the request. This document is the
server-side contract hq-pro implements.

Why a proxy: the Index attributes searches and setup clicks to a publisher
key. That key is HQ's (one platform key for all HQ users), so it lives in
hq-pro, not in every user's `hq secrets`.

Scope: read-only discovery. Provisioning (`POST /provision`,
`GET /provision/{id}`, one-time credential links) is not part of this contract
and the client has no command for it.

## Auth

- Header: `Authorization: Bearer <HQ Cognito token>` — the same token the
  client uses for `/membership/me` (`identity-resolve.sh` → `id_token`, else
  `jwt`).
- 401 → client forces one token refresh and retries once, then tells the user
  to `/hq-login`.
- 403 → the caller's company has services disabled (policy). Client surfaces
  the `detail`.
- Server derives the Index `external_user_id` from the token's Cognito `sub`.
  The client never sends it.

Base URL: `HQ_PRO_API_URL` → `HQ_API_URL` → `HQ_VAULT_API_URL` →
`https://hqapi.hq.computer` (same chain as the Outpost jobs client).

## Routes

Each route forwards to one Index route with HQ's publisher key in
`X-API-Key`. Response bodies are the Index response passed through unchanged.
Error bodies keep the Index `{"detail": ...}` shape.

| hq-pro | Index | Notes |
|---|---|---|
| `POST /services/search` | `POST /search` | Body `{query, search_id?, session_id?}`. Server adds `external_user_id` (Cognito sub), `external_session_id` (= `session_id`), `metadata.source = "hq-services"`. Returns the Index body: `search_id`, `recommendation`, `reasoning`, `install`, `credential_request`, `click_url`, `alternatives`. |
| `GET /services?q=` | `GET /services?q=` | Catalog listing. |
| `GET /services/{slug}` | `GET /services/{slug}` | 404 passthrough. |

Not proxied: `/categories`, `POST /integrations/report`, `/provision/*`.

## Rate limits

Per-user rate limit on `/services/search` (a runaway agent loop is HQ's
quota).

## Company policy (optional, v1.1)

A company may disable services for its members. If implemented, return 403
`{"detail": "services_disabled"}`; the client prints `detail` as-is.
