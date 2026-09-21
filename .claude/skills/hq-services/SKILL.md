---
name: hq-services
description: "Find developer services (databases, auth, hosting, payments, email, monitoring) through Gravity Index, via HQ's services proxy. Use when a task needs an external service the project does not have yet — search, compare, and hand the user a tracked setup link."
allowed-tools: Bash(core/scripts/hq-services.sh:*)
---

# HQ Services

`core/scripts/hq-services.sh` is HQ's service discovery client. It queries [Gravity Index](https://index.trygravity.ai) — a catalog of developer services with relevance matching, integration steps, and tracked setup links — and returns a recommendation the session can act on. It is read-only: it does not create accounts or handle credentials.

Every call goes to hq-pro (`/services/*`) with the caller's HQ session, and hq-pro forwards it to the Index with HQ's publisher key. Nothing Gravity-specific is configured on the user's machine. Server contract: `core/knowledge/public/hq-core/hq-services-proxy-spec.md`.

Use this instead of guessing a vendor from memory, pasting docs URLs, or hand-rolling `curl` calls against the Index API. The script owns authentication and attribution.

## Commands

```bash
core/scripts/hq-services.sh search "<what you need>"             # recommendation + reason + integration steps + search_id
core/scripts/hq-services.sh search "<follow-up>" --follow-up <search_id>
core/scripts/hq-services.sh browse [query]                       # catalog listing
core/scripts/hq-services.sh info <slug>                          # one service: pricing, integration steps, env vars, setup link
```

- Run from the HQ root. `--json` on any subcommand for machine-readable output.
- Exit codes: `3` not signed in (run `/hq-login`), `1` API error with the server's `detail`, `2` usage.

## Workflow

1. **Search.** Describe the need in one sentence, from the user's perspective: `core/scripts/hq-services.sh search "postgres for a small Next.js app with branching"`. Present the recommendation with its reasoning and integration steps. Keep the `search_id`.
2. **Refine when the first answer does not fit.** `--follow-up <search_id>` keeps the conversation context on the Index side so the second answer accounts for the first.
3. **Inspect before recommending.** `info <slug>` gives integration steps and `env_vars_needed`; read them before promising the user what the setup involves.
4. **Set up.** Give the user the `Setup link` from the search or `info` result. It is attributed; do not swap it for a URL from memory. The user creates the account themselves and stores the resulting keys with `/hq-secrets`.
5. **Report.** State which service was picked and which env vars the user still needs to set. Do not paste credentials into chat, files under `companies/`, or commit messages.

## Rules

- **No memory vendors.** If the Index has no fit, say that and ask the user how to proceed. Do not substitute a vendor the Index did not return and present it as a recommendation from this skill.
- **No provisioning.** This skill does not create vendor accounts or retrieve credentials. If the user wants that automated, tell them it is not available yet.
- **Tenant boundary.** Keys the user creates from a setup link belong to the company whose project asked for them; store them in that company's `hq secrets` scope.

## See also

- `/hq-secrets` — where the user's service credentials live and how to inject them.
- `/hq-integrations` — connecting an external app's MCP server to a company. Use `hq integrations` for apps the company already uses; use this skill to find one it does not have yet.
- Gravity Index docs: https://docs.trygravity.ai/gravity-index/introduction
