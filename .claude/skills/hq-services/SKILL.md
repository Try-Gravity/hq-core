---
name: hq-services
description: "Find and set up developer services (databases, auth, hosting, payments, email, monitoring) through `hq services`, backed by Gravity Index. Use when a task needs an external service the project does not have yet — search, compare, open a tracked setup link, or provision an account with the user's consent."
allowed-tools: Bash(hq:*)
---

# HQ Services

`hq services` is HQ's service discovery surface. It queries [Gravity Index](https://index.trygravity.ai) — a catalog of developer services with relevance matching, integration steps, and tracked setup links — and returns a recommendation the session can act on. Provisioning (creating the account and handing back working credentials) goes through the same command and is consent-gated.

Use this instead of guessing a vendor from memory, pasting docs URLs, or hand-rolling `curl` calls against the Index API. The CLI owns authentication, attribution, and credential handling.

## Commands

```bash
hq services search "<what you need>"             # ranked recommendation + reason + search_id
hq services search "<follow-up>" --follow-up <search_id>
hq services browse [query] [--category <name>]   # catalog listing
hq services info <slug>                          # one service: pricing, integration steps, env vars
hq services provision <slug> --search-id <id>    # create the account (asks for consent first)
hq services status <provision_id>                # lifecycle state, credential fingerprint only
```

- `--company` defaults to the caller's single active membership; pass the slug when they belong to several.
- `--json` on any subcommand for machine-readable output.
- If `hq services` reports an unknown command, the CLI is too old: `npm install -g @indigoai-us/hq-cli@latest`.

## Publisher key

Every Index call is attributed to a publisher key (`pk_…`). The CLI resolves it from the company secret `GRAVITY_PUBLISHER_KEY`; set it once with `/hq-secrets` (`hq secrets set GRAVITY_PUBLISHER_KEY` or `hq secrets generate-link GRAVITY_PUBLISHER_KEY` for a human to submit it). Never pass the key on the command line and never print it.

If the secret is missing, `hq services` says so and exits. Tell the user which secret to set; do not fall back to an unauthenticated request or a personal key from another company.

## Workflow

1. **Search.** Describe the need in one sentence, from the user's perspective: `hq services search "postgres for a small Next.js app with branching"`. Present the top recommendation with its `reason`, and mention the runners-up in one line. Keep the `search_id`.
2. **Refine when the first answer does not fit.** `--follow-up <search_id>` keeps the conversation context on the Index side so the second answer accounts for the first.
3. **Inspect before recommending.** `hq services info <slug>` gives integration steps and `env_vars_needed`; read them before promising the user what the setup involves.
4. **Set up.** Two paths, in order of preference:
   - **Provision** when the service supports it. Ask the user first, in one question: "Want me to create a `<service>` account for you?" Only after a yes run `hq services provision <slug> --search-id <search_id>`. The CLI collects the credentials from the Index's one-time keystore link and writes them into HQ secrets for the active company; it prints the secret names, never the values. Then run the integration steps with `hq run` or `hq secrets exec` so the child process sees the new variables. Show the user the `ownership_url` so they can take ownership of the vendor account.
   - **Tracked setup link** when the service is not provisionable (`service_not_provisionable`). Give the user the `setup_url` from the search or `info` result. It is attributed; do not swap it for a URL from memory.
5. **Report.** State what was created and which secret names were set. Do not paste credentials into chat, files under `companies/`, or commit messages.

## Rules

- **Consent is per provision.** A yes for one service does not cover a second one. Never provision inside an unattended loop (`/run-project`, Outpost jobs, fleet agents) without a recorded human decision.
- **Tenant boundary.** The publisher key, the provisioned credentials, and the vendor account all belong to the active company. Do not reuse them for another company's project.
- **Duplicates.** `409 existing_vendor_account` or `duplicate_pending_provision` means the user already has an account: say so and point them to the vendor's welcome email or the ownership link. Do not retry with a different email.
- **No memory vendors.** If the Index has no fit, say that and ask the user how to proceed. Do not substitute a vendor the Index did not return and present it as a recommendation from this skill.
- **Secrets stay in the CLI.** `hq services` and `hq secrets` handle every credential. Do not read `credentials_url` payloads by hand, and do not write them to `.env` files that are not gitignored.

## See also

- `/hq-secrets` — where the publisher key and provisioned credentials live.
- `/hq-integrations` — connecting an external app's MCP server to a company. Use `hq integrations` for apps the company already uses; use `hq services` to find and set up one it does not have yet.
- Gravity Index docs: https://docs.trygravity.ai/gravity-index/introduction
