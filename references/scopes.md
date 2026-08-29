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
| Build overlay (this installer) | `app/databricks.prod.yml` → `targets.prod.resources.apps…user_api_scopes` | the 9 tokens below — **appended** to the base by DAB |

DAB **appends** a target-level `user_api_scopes` to the base list (verify with
`databricks bundle validate -t prod -o json`). So the overlay lists only the
*additional* build scopes; the `catalog.*` reads come from the base file.

## The 9 build scopes (verbatim, all documented Databricks Apps scopes)

| Scope | Enables |
|---|---|
| `sql` | SQL warehouses + query execution — dashboards, metric views, data-gen SQL, Genie validation queries |
| `genie` | Genie space create/manage |
| `postgres` | Lakebase (Postgres) objects |
| `workspace.workspace` | Jobs, Lakeflow/SDP pipelines, clusters, notebooks, secrets, repos — **there is no separate jobs/pipelines/clusters scope** |
| `files` | Workspace files / UC volume file IO — data-gen output, RAG source documents |
| `apps` | Create/deploy the generated Databricks App |
| `model-serving` | Serving endpoints for Knowledge Assistant / Multi-Agent Supervisor |
| `vector-search` | Vector indexes for RAG / Knowledge Assistant |
| `catalog.connections` | Lakeflow Connect ingestion connections |

Resolved together with the base, the app declares **12** scopes:
`catalog.catalogs`, `catalog.schemas`, `catalog.tables`, `sql`, `genie`,
`postgres`, `workspace.workspace`, `files`, `apps`, `model-serving`,
`vector-search`, `catalog.connections`.

## After changing scopes: RE-AUTHORIZE

Expanding `user_api_scopes` only changes what the app is *allowed* to request.
A user's already-minted token keeps its old scopes until they **re-consent**:
reload the app URL and accept the authorization prompt. If no prompt appears,
stop + start the app compute and reopen. See `troubleshooting.md`.

## Reference

Databricks Apps user authorization scopes:
<https://docs.databricks.com/aws/en/dev-tools/databricks-apps/auth>
