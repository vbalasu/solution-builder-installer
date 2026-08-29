# Troubleshooting

Real failure modes seen installing Solution Builder, and the fix for each.

### `Error: stat .build: no such file or directory` on `bundle deploy`
The CLI validates `sync.paths` (which lists `.build`) *before* it runs the
artifact build. On a fresh clone `.build` doesn't exist yet.
**Fix:** build first, then deploy — `deploy.sh` does this
(`./scripts/build.sh --target prod` then `databricks bundle deploy -t prod`).

### App create fails: `Endpoint with name '<x>' does not exist. (404)`
`databricks.prod.yml` names a serving endpoint that isn't in this workspace.
Built-in FMAPI endpoints are prefixed `databricks-` (e.g.
`databricks-claude-sonnet-5`, `databricks-gpt-5-4-mini`,
`databricks-qwen3-embedding-0-6b`). **Fix:** use the exact names from
`databricks serving-endpoints list` (preflight prints them). Re-run
`configure.sh` with the corrected `--ai-gateway*` / `--anthropic-llm-endpoint`
values, then redeploy.

### App build fails: `403 PERMISSION_DENIED: The endpoint is temporarily disabled due to a Databricks-set rate limit of 0.`
A configured serving endpoint exists in `serving-endpoints list` but is
**disabled** in this workspace (rate limit 0), so every query 403s. Deploy
succeeds; the app's builds fail at runtime. Opus and some newer GPT endpoints
are frequently the disabled ones.
**Fix:** run `check-endpoints.sh` (it probes each chosen endpoint with a tiny
real query and prints the ones that DO respond), pick a working endpoint
(`databricks-claude-sonnet-*` / `-haiku-*` and `databricks-*-embedding-*` are
usually enabled), then re-run `configure.sh` → `deploy.sh` → `launch.sh`.
`configure.sh` now runs this probe itself and refuses to write a config that
names an unusable endpoint (override with `--skip-endpoint-check`). Prefer this
over `databricks serving-endpoints list` alone — listing ≠ callable.

### Agent says its token scopes are only `catalog` / `lakeview` (can't build)
The app hasn't been re-authorized after scopes were expanded.
**Fix:** open the app URL in a fresh/incognito window and accept the consent
prompt. If no prompt appears, cycle the compute:
```
databricks apps stop  <app-name> --profile <p>
databricks apps start <app-name> --profile <p>
```
then reopen the URL and start a NEW build/session so a fresh token is minted.
Confirm by asking the agent to report its current token scopes — you want to
see `sql`, `genie`, `postgres`, `workspace`, etc.

### AI/BI dashboard build fails: `Provided OAuth token does not have required scopes: dashboards`
The Lakeview API requires an OAuth scope literally named `dashboards`, but that
scope is **not in the Apps `user_api_scopes` vocabulary** (declaring it fails the
deploy: `The specified scope dashboards is not a valid scope`; the settings API
has no allowlist for it). So the downscoped **OBO token can never create
dashboards** — and every `initial_templates/*` demo builds one. Re-authorizing
does **not** fix this (verified: even a freshly-minted OBO token is rejected).
**Fix:** configure the **deployer service principal** so builds run on
non-downscoped OAuth-M2M creds — `setup-deployer-sp.sh` then `configure.sh
--deployer-sp-*` (see `scopes.md` → "Why a deployer SP" and SKILL.md Step 3.5),
redeploy, and create the project with a **target workspace** set (the
`DEFAULT_TARGET_WORKSPACE_HOST` pre-fill). Confirm the SP creds work with a quick
`databricks api post /api/2.0/lakeview/dashboards` using
`DATABRICKS_AUTH_TYPE=oauth-m2m` + the SP client id/secret. Do **not** try to add
a `dashboards` scope or `all-apis` — neither is accepted.

### A specific capability 403s even after re-auth (e.g. a pipeline or job)
The 12 explicit scopes cover the common Build path, and `workspace.workspace`
is the documented home for jobs/pipelines/clusters. If one specific API still
403s, add the matching documented scope to the overlay's `user_api_scopes` in
`databricks.prod.yml`, redeploy, and re-authorize. Do **not** fall back to
`all-apis` (see `scopes.md`).

### First deploy fails on the Lakebase grant: `Role <client-id> not found`
The app SP's Postgres identity is eventually-consistent right after creation.
**Fix:** wait ~30–60s and re-run the grant (or `deploy.sh` then `grant-sp.sh`).
`grant-sp.sh` is idempotent.

### `error downloading Terraform: ... openpgp: key expired`
Older CLI builds verify HashiCorp's rotated signing key.
**Fix:**
```
brew install hashicorp/tap/terraform
export DATABRICKS_TF_EXEC_PATH="$(which terraform)"
export DATABRICKS_TF_VERSION="$(terraform version -json | jq -r .terraform_version)"
```
then redeploy.

### `create-project` fails / Lakebase quota
Autoscaling Lakebase projects have per-workspace quota. A brand-new workspace
is fine; a shared one may be at its cap. **Fix:** reuse an existing project
(`provision-lakebase.sh --use-existing <slug>`) or free a slot.

### Gallery is empty right after first boot
Template seeding runs fire-and-forget in a background thread; the gallery fills
in a minute or two. Not an error.

### Local dev instead of a deployed app
`cd app && cp .env.example .env` (set `DATABRICKS_CONFIG_PROFILE`), then
`uv sync && bun install && ./scripts/dev.sh`. PGLite auto-provisions a local
Postgres, so no Lakebase is needed for local dev.
