# Installing Solution Builder with `workspace-setup.py`

`workspace-setup.py` is a **pure-Python** installer (Databricks SDK — no bash, no
git, no build toolchain). It provisions Lakebase, a deployer service principal,
the app's OBO scopes, and deploys the app — everything needed to go from an empty
workspace to a running Solution Builder app.

**A prebuilt app artifact ships in this repo** (`artifact/solution-builder-build.zip`),
so there is **nothing to build and no toolchain to install**. Clone → configure →
run. That's it.

---

## What you need

1. **This repo** — it already contains the script (`workspace-setup.py`), a
   config template (`config.yaml.example`), and the prebuilt artifact
   (`artifact/…zip`).
2. **`databricks-sdk` ≥ 0.100** — preinstalled in Databricks notebooks;
   `pip install "databricks-sdk>=0.100"` on a laptop.
3. **Auth** to the workspace — automatic in a notebook; `databricks auth login`
   on a laptop; `DATABRICKS_HOST`+`DATABRICKS_TOKEN` in CI.
4. A **catalog you can build in** and **Apps enabled** in the workspace.

---

## Configure (`config.yaml`)

Copy the template, then edit it (the real `config.yaml` is gitignored, so your
workspace details never get committed):

```bash
cp config.yaml.example config.yaml
```

Set these; everything else has a sensible default:

```yaml
databricks:
  workspace_url: https://<your-workspace>.cloud.databricks.com
  profile: <cli-profile>        # laptop; leave "" in a notebook / CI

app:
  default_catalog: <catalog>    # a UC catalog you can CREATE SCHEMA in (see note)

endpoints:                      # EXACT, CALLABLE endpoint names in THIS workspace
  anthropic_llm_endpoint: databricks-claude-sonnet-5
  ai_gateway: databricks-claude-sonnet-5
  ai_gateway_mini: databricks-gpt-5-4-mini
  ai_gateway_embedding: databricks-qwen3-embedding-0-6b
```

You normally **don't** touch `artifact.path` — it already points at the bundled
artifact. `app.name`, `lakebase.project_id`, `deployer_sp`, and `logging` have
working defaults.

Notes:
- **`default_catalog`**: if it doesn't already exist, the app tries to
  `CREATE CATALOG` at boot (metastore-admin only). **Prefer an existing catalog**
  you can build in.
- **Endpoints** must be *callable*, not just present. The installer probes each
  and, on a rate-limited/disabled one, prints a **paste-ready `endpoints:` block**
  of working alternatives — paste it in and re-run.

---

## Run

### Option 1 — Databricks notebook (runs *in* the workspace, no bash)

1. Upload `workspace-setup.py`, `config.yaml` (with `profile: ""`), and
   `artifact/solution-builder-build.zip` to a **UC Volume**, e.g.
   `/Volumes/<cat>/<schema>/<vol>/`. Set `artifact.path` to that uploaded zip.
2. In a notebook:

```python
# cell 1 — the runtime's bundled SDK may be too old; pin a recent one
%pip install -q "databricks-sdk>=0.100" pyyaml
# cell 2
dbutils.library.restartPython()
# cell 3
import importlib.util
VOL = "/Volumes/<cat>/<schema>/<vol>"
spec = importlib.util.spec_from_file_location("ws", f"{VOL}/workspace-setup.py")
ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)
ws.run(f"{VOL}/config.yaml")          # ambient auth — no login needed
```

### Option 2 — laptop / CI

```bash
pip install "databricks-sdk>=0.100" pyyaml
databricks auth login --host https://<workspace-url> --profile <cli-profile>   # laptop
#   (CI instead: export DATABRICKS_HOST + DATABRICKS_TOKEN, set profile "")

./workspace-setup.py --dry-run        # preview the plan, change nothing
./workspace-setup.py                  # do the install
```

The installer is **idempotent** — safe to re-run. `--config <path>` selects a
different config file.

---

## After it finishes (manual, required)

The installer prints the **App URL**. Then:

1. Open the URL (a fresh/incognito window is most reliable).
2. **Accept the authorization/consent prompt** so your token carries the new
   scopes. If no prompt appears, stop then start the app compute and reopen.
3. On the home page, choose **“Describe your story”** and build your first
   solution.

---

## Refreshing the artifact (optional)

The bundled artifact is a pinned snapshot. To rebuild it from newer upstream
source, on **any host with `git` + `uv` + `bun` + the Databricks CLI**:

```bash
git clone https://github.com/databricks-solutions/solution-builder.git
cd solution-builder/app && ./scripts/build.sh --target prod
( cd .build && zip -qr - . ) > <this-repo>/artifact/solution-builder-build.zip
```

Do **not** commit an `app.yml` that contains a real `DEPLOYER_SP_CLIENT_SECRET` —
the installer regenerates `app.yml` at deploy time, and the committed template
omits the `env:` block on purpose so it carries no secrets.

---

## Quick troubleshooting

| Symptom | Fix |
|---|---|
| `endpoint … DISABLED / not callable` | Paste the printed `endpoints:` block into `config.yaml`; re-run. |
| `'WorkspaceClient' has no attribute …` | Runtime SDK too old — `%pip install -U "databricks-sdk>=0.100"` + `restartPython()`. |
| App deploys but crashes: Postgres `password authentication failed` | Re-run — the installer wires the SP’s Postgres role before deploy; a re-run reconciles it. |
| Dashboards fail to build in the app | Ensure `deployer_sp.enabled: true`, then re-authorize the app. |
| Not authenticated | laptop: `databricks auth login …`; CI: `DATABRICKS_HOST`+`DATABRICKS_TOKEN`; notebook: automatic. |
