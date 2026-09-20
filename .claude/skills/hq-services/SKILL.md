---
name: hq-services
description: "Find and set up developer services (databases, auth, hosting, payments, email, monitoring) through Gravity Index, via HQ's services proxy. Use when a task needs an external service the project does not have yet — search, compare, open a tracked setup link, or provision an account with the user's consent."
allowed-tools: Bash(core/scripts/hq-services.sh:*), Bash(hq:*)
---

# HQ Services

`core/scripts/hq-services.sh` is HQ's service discovery client. It queries [Gravity Index](https://index.trygravity.ai) — a catalog of developer services with relevance matching, integration steps, and tracked setup links — and returns a recommendation the session can act on. Provisioning (creating the account and handing back working credentials) goes through the same script and is consent-gated.

Every call goes to hq-pro (`/services/*`) with the caller's HQ session, and hq-pro forwards it to the Index with HQ's publisher key. Nothing Gravity-specific is configured on the user's machine. Server contract: `core/knowledge/public/hq-core/hq-services-proxy-spec.md`.

Use this instead of guessing a vendor from memory, pasting docs URLs, or hand-rolling `curl` calls against the Index API. The script owns authentication, attribution, and credential handling.

## Commands

```bash
core/scripts/hq-services.sh search "<what you need>"             # recommendation + reason + integration steps + search_id
core/scripts/hq-services.sh search "<follow-up>" --follow-up <search_id>
core/scripts/hq-services.sh browse [query]                       # catalog listing
core/scripts/hq-services.sh info <slug>                          # one service: pricing, integration steps, env vars
core/scripts/hq-services.sh provision <slug> --search-id <id> --consent   # create the account; --consent only after the user said yes
core/scripts/hq-services.sh status <provision_id>                # lifecycle state, credential fingerprint only
```

- Run from the HQ root. `--json` on any subcommand for machine-readable output.
- `--company <slug>` / `--personal` choose where provisioned credentials are stored (`hq secrets` scope). Default is the CLI's active company.
- Exit codes: `3` not signed in (run `/hq-login`), `4` provision without `--consent`, `5` credentials retrieved but a vault write failed (see Rules), `1` API error with the server's `detail`.

## Workflow

1. **Search.** Describe the need in one sentence, from the user's perspective: `core/scripts/hq-services.sh search "postgres for a small Next.js app with branching"`. Present the recommendation with its reasoning and integration steps. Keep the `search_id`.
2. **Refine when the first answer does not fit.** `--follow-up <search_id>` keeps the conversation context on the Index side so the second answer accounts for the first.
3. **Inspect before recommending.** `info <slug>` gives integration steps, `env_vars_needed`, and whether the service is provisionable (`Provisioning: api|...`); read them before promising the user what the setup involves.
4. **Set up.** Two paths, in order of preference:
   - **Provision** when the service supports it. Ask the user first, in one question: "Want me to create a `<service>` account for you?" Only after a yes run `provision <slug> --search-id <search_id> --consent`. The script collects the credentials from the Index's one-time keystore link, writes them into `hq secrets` for the chosen scope, and prints the secret names, never the values. Then run the integration steps with `hq run` or `hq secrets exec --only <names>` so the child process sees the new variables. Show the user the ownership link so they can take ownership of the vendor account.
   - **Tracked setup link** when the service is not provisionable (`409 service_not_provisionable`). Give the user the `Setup link` from the search or `info` result. It is attributed; do not swap it for a URL from memory.
5. **Report.** State what was created and which secret names were set. Do not paste credentials into chat, files under `companies/`, or commit messages.

## Rules

- **Consent is per provision.** `--consent` asserts that the human said yes to this service in this session. A yes for one service does not cover a second one. Never provision inside an unattended loop (`/run-project`, Outpost jobs, fleet agents) without a recorded human decision.
- **Tenant boundary.** Provisioned credentials and the vendor account belong to the company whose scope you passed. Do not reuse them for another company's project.
- **Duplicates.** `409 existing_vendor_account` or `duplicate_pending_provision` means the user already has an account: say so and point them to the vendor's welcome email or the ownership link. Do not retry.
- **Exit 5.** The one-time link is spent and at least one secret did not land. Tell the user which names failed and that recovery is through the vendor ownership email; do not re-run provision.
- **No memory vendors.** If the Index has no fit, say that and ask the user how to proceed. Do not substitute a vendor the Index did not return and present it as a recommendation from this skill.
- **Secrets stay in the scripts.** `hq-services.sh` and `hq secrets` handle every credential. Do not read `credentials_url` payloads by hand, and do not write them to `.env` files that are not gitignored.

## See also

- `/hq-secrets` — where provisioned credentials live and how to inject them.
- `/hq-integrations` — connecting an external app's MCP server to a company. Use `hq integrations` for apps the company already uses; use this skill to find and set up one it does not have yet.
- Gravity Index docs: https://docs.trygravity.ai/gravity-index/introduction
