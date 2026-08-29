# Scopes: the exact, explicit set (and why never `all-apis`)

Solution Builder's agent builds resources **as the signed-in user** (OBO — the
Apps proxy forwards a downscoped `x-forwarded-access-token`). What that token
can do is the intersection of:

1. the app's declared **`user_api_scopes`** (in the bundle), and
2. what the **user has consented to**, and
3. the user's own workspace privileges.

If `user_api_scopes` is too narrow, the agent can read catalog metadata but
every Build action fails with `Invalid scope` / `PERMISSION_DENIED`.

## The rule: enumerate exact scopes, never `all-apis`

The old app README suggests granting the **account-level OAuth integration** the
coarse `all-apis` scope via `scripts/set-app-oauth-scopes.sh`. This installer
**does not do that.** Reasons:

- `all-apis` is a blanket grant — the app can act as the user against *every*
  API. We prefer least-privilege: enumerate exactly what the Build stage needs.
- It requires **account-admin** access and rotates with each redeploy.
- Some workspaces **reject** `all-apis` (and `iam.*`, bare `unity-catalog`,
  bare `catalog`) as `user_api_scopes` values anyway.

Declarative `user_api_scopes` in the bundle is better: no account admin, it
survives redeploys, and it's auditable.

## The two layers of the config

| Layer | Where | Scopes |
|---|---|---|
| Base (committed) | `app/databricks.yml` → `resources.apps…user_api_scopes` | `catalog.catalogs`, `catalog.schemas`, `catalog.tables` — generic metadata reads for the grounding scan |
| Build overlay (this installer) | `app/databricks.prod.yml` → `targets.prod.resources.apps…user_api_scopes` | the 10 tokens below — **appended** to the base by DAB |

DAB **appends** a target-level `user_api_scopes` to the base list (verify with
`databricks bundle validate -t prod -o json`). So the overlay lists only the
*additional* build scopes; the `catalog.*` reads come from the base file.

## The 10 build scopes (verbatim, all documented Databricks Apps scopes)

| Scope | Enables |
|---|---|
| `sql` | SQL warehouses + query execution — **and AI/BI (Lakeview) DASHBOARDS** (deprecated `sql.dashboards` maps to `sql`), metric views, data-gen SQL, Genie validation queries |
| `genie` | Genie space create/manage |
| `postgres` | Lakebase (Postgres) objects |
| `workspace.workspace` | Jobs, Lakeflow/SDP pipelines, clusters, notebooks, secrets, repos — **there is no separate jobs/pipelines/clusters scope** |
| `files` | Workspace files / UC volume file IO — data-gen output, RAG source documents |
| `apps` | Create/deploy the generated Databricks App |
| `model-serving` | Serving endpoints for Knowledge Assistant / Multi-Agent Supervisor / ML |
| `ai-gateway` | AI Gateway `/serving-endpoints/responses` — the generated full-stack app's agent LLM calls |
| `vector-search` | Vector indexes for RAG / Knowledge Assistant |
| `catalog.connections` | Lakeflow Connect ingestion connections |

Resolved together with the base, the app declares **13** scopes:
`catalog.catalogs`, `catalog.schemas`, `catalog.tables`, `sql`, `genie`,
`postgres`, `workspace.workspace`, `files`, `apps`, `model-serving`,
`ai-gateway`, `vector-search`, `catalog.connections`.

## ⚠️ The valid vocabulary — and what is NOT valid

The whole set of valid Databricks Apps `user_api_scopes`
(<https://docs.databricks.com/dev-tools/databricks-apps/auth>) is: `ai-gateway`,
`apps`, `files`, `genie`, `model-serving`, `postgres`, `sql`, `vector-search`,
`sql:restricted-query`, plus SDK-style `catalog.catalogs`, `catalog.schemas`,
`catalog.tables`, `catalog.connections`, `workspace.workspace` (each with an
optional `:read`). **Nothing outside this list deploys.**

- **There is NO `dashboards` scope.** AI/BI (Lakeview) dashboards ride on `sql`
  (deprecated `sql.dashboards` → `sql`). Declaring `dashboards` fails the deploy
  with `The specified scope dashboards is not a valid scope` (verified on a real
  workspace; the workspace settings API exposes no allowlist to add it). If a
  dashboard build 403s **with `sql` present**, it's a **stale OBO token** —
  RE-AUTHORIZE (below), don't chase a scope.
- **Don't use deprecated aliases:** `serving.serving-endpoints` → `model-serving`;
  `dashboards.genie` → `genie`; `vectorsearch.*` → `vector-search`; `sql.*` →
  `sql`. Mixing one in can make the agent 403 `Invalid scope, required scopes: <current>`.

This set maps every `initial_templates/*` capability — Lakeflow/SDP, AI/BI
dashboards (via `sql`) + Genie, metric views, KA/MAS, ML, Lakebase, the app + its
Responses API (`ai-gateway`) — onto a valid scope, so templates build out of the box.

## Why a deployer SP (the OBO token cannot build dashboards)

The build agent normally acts on the signed-in user's **OBO token**
(`x-forwarded-access-token`), downscoped to the `user_api_scopes` above. But the
**AI/BI (Lakeview) dashboards API requires an OAuth scope literally named
`dashboards`**, and — as the section above shows — `dashboards` is **not in the
Apps `user_api_scopes` vocabulary at all** (declaring it fails the deploy). So no
scope tweak can put `dashboards` on the OBO token, and `POST
/api/2.0/lakeview/dashboards` returns `Provided OAuth token does not have
required scopes: dashboards`. Since **every `initial_templates/*` demo builds a
dashboard**, the pure-OBO install can't build any template end to end.

The fix is the app's built-in **deployer service principal** (`models.py` →
`target_workspace_host`; AUTH.md). When `DEPLOYER_SP_CLIENT_ID` +
`DEPLOYER_SP_CLIENT_SECRET` are set (and a project has a target workspace), the
agent's `.databrickscfg` is written with the **SP's OAuth-M2M creds — which are
NOT scope-downscoped** — so `lakeview create` (and every other resource) works,
bounded only by the SP's own privileges. `setup-deployer-sp.sh` creates the SP,
grants it build privileges (workspace admin, simplest), and stores its secret in
a scope; `configure.sh --deployer-sp-*` wires it into `app_env`. Trade-off:
builds run as a shared SP, not the signed-in user (the app reconciles resource
ownership back to the user afterward). The `user_api_scopes` above still matter
for the agent's identity-attributed metadata reads.

## After changing scopes: RE-AUTHORIZE

Expanding `user_api_scopes` only changes what the app is *allowed* to request.
A user's already-minted token keeps its old scopes until they **re-consent**:
reload the app URL and accept the authorization prompt. If no prompt appears,
stop + start the app compute and reopen. See `troubleshooting.md`.

## Reference

Databricks Apps user authorization scopes:
<https://docs.databricks.com/aws/en/dev-tools/databricks-apps/auth>
