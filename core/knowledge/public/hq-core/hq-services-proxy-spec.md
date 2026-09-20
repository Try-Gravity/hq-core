# HQ services proxy — hq-pro contract for `hq services`

`hq services` (client: `core/scripts/hq-services.sh`, skill: `/hq-services`)
finds and provisions developer services through **Gravity Index**
(`https://index.trygravity.ai`). The client never talks to the Index directly.
It calls **hq-pro** with the caller's HQ Cognito token; hq-pro holds HQ's
Gravity publisher key and forwards the request. This document is the
server-side contract hq-pro implements.

Why a proxy: the Index attributes searches and provisions to a publisher key.
That key is HQ's (one platform key for all HQ users), so it lives in hq-pro,
not in every user's `hq secrets`.

## Auth

- Header: `Authorization: Bearer <HQ Cognito token>` — the same token the
  client uses for `/membership/me` (`identity-resolve.sh` → `id_token`, else
  `jwt`).
- 401 → client forces one token refresh and retries once, then tells the user
  to `/hq-login`.
- 403 → the caller's company has services disabled (policy). Client surfaces
  the `detail`.
- Server derives from the token: Cognito `sub` (used as the Index
  `external_user_id`) and the caller's email (used as the Index `user_email`
  on provision). The client never sends either.

Base URL: `HQ_PRO_API_URL` → `HQ_API_URL` → `HQ_VAULT_API_URL` →
`https://hqapi.hq.computer` (same chain as the Outpost jobs client).

## Routes

Each route forwards to one Index route with HQ's publisher key in
`X-API-Key`. Response bodies are the Index response passed through unchanged
except where noted. Error bodies keep the Index `{"detail": ...}` shape.

| hq-pro | Index | Notes |
|---|---|---|
| `POST /services/search` | `POST /search` | Body `{query, search_id?, session_id?}`. Server adds `external_user_id` (Cognito sub), `external_session_id` (= `session_id`), `metadata.source = "hq-services"`. Returns the Index body: `search_id`, `recommendation`, `reasoning`, `install`, `credential_request`, `click_url`, `alternatives`. |
| `GET /services?q=` | `GET /services?q=` | Catalog listing. |
| `GET /services/{slug}` | `GET /services/{slug}` | 404 passthrough. |
| `POST /services/provision` | `POST /provision` | Body `{service_slug, user_consent: true, search_id?, session_id?}`. Server rejects `user_consent != true` with 400 before forwarding. Server adds `user_email` (from token), `external_user_id` (Cognito sub). Returns the Index body **including `credentials_url`** — see below. 201 on success; 409 `service_not_provisionable` / duplicate passthrough. |
| `GET /services/provision/{id}` | `GET /provision/{id}` | Lifecycle status only. Never returns credentials. |

Not proxied in v1: `/categories`, `POST /integrations/report`.

## Credentials

The Index returns provisioned credentials as a one-time keystore link
(`credentials_url`, `POST` reveals once and burns the token; `GET` is a
non-consuming landing page). hq-pro **passes the URL through and does not
open it.** The client POSTs it once and writes each key into the caller's
`hq secrets` (company or personal scope chosen by the caller), so plaintext
credentials exist only in the vault. hq-pro must not log request or response
bodies for `/services/provision`.

If the vault write fails after the reveal, the link is spent. The client
tells the user to recover through the vendor ownership email
(`ownership_url` in the provision response). hq-pro does not need a retry
path for this.

## Rate limits and abuse

- Per-user rate limit on `/services/search` and `/services/provision` (the
  Index bills HQ per provision; a runaway agent loop is HQ's cost).
- `/services/provision` requires `user_consent: true`; the client only sets it
  after a human said yes in the session. hq-pro may additionally record
  `{sub, service_slug, search_id, ts}` for audit.

## Company policy (optional, v1.1)

A company may disable services or restrict which categories its members can
provision. If implemented, return 403 `{"detail": "services_disabled"}` or
`{"detail": "category_not_allowed"}`; the client prints `detail` as-is.
