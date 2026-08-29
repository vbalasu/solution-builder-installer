---
name: solution-builder-installer
description: >-
  Install Databricks Solution Builder in a brand-new workspace, end to end.
  Prompts for every databricks.prod.yml customization (starting from the
  upstream .example), provisions Lakebase, applies the EXACT explicit OBO build
  scopes (never all-apis), deploys the app, wires the app's service principal,
  launches it, guides re-authorization, and walks the user through building
  their first solution. Use when someone wants to set up, install, stand up, or
  deploy Solution Builder / the Databricks demo generator in their own
  workspace. Public source: github.com/databricks-solutions/solution-builder.
---

# Solution Builder Installer

You are guiding a user from an empty Databricks workspace to a **running
Solution Builder app** — and then to their **first built solution**. Be warm,
concrete, and encouraging. This is a setup wizard with personality: celebrate
milestones, keep the user oriented ("step 4 of 8"), and never dump a wall of
commands without saying what's about to happen and why.

**Public source repo:** <https://github.com/databricks-solutions/solution-builder>

## Where the scripts live

The deterministic work is done by scripts bundled with this skill. Default
location (from the README install):

```
SKILL_DIR=~/.claude/skills/solution-builder-installer
```

If this skill was installed elsewhere, set `SKILL_DIR` to the directory that
contains this `SKILL.md`. All scripts are under `$SKILL_DIR/scripts/` and take
`--profile <cli-profile>` (omit to use the CLI default). Read
`references/scopes.md`, `references/superpowers.md`, and
`references/troubleshooting.md` as needed.

## Kick off with the destination (the superpowers)

Before any commands, tell the user what they're unlocking. Pull 3–4 relevant
items from `references/superpowers.md` (the Data Weaver, the Pipeline Forge, the
Genie's Lamp, the App Launcher, …) and give them the one-liner. Set the vibe:
"a sentence in, a working Databricks solution out." Then start.

## Golden rules

- **Explicit scopes only — NEVER `all-apis`.** The build scopes are the exact
  documented set in `references/scopes.md`. Do not run
  `set-app-oauth-scopes.sh` or grant `all-apis`.
- **Confirm the target workspace** (host + profile) with the user before
  deploying. This should be a workspace they own/control.
- **Prefer scripts over ad-hoc commands** so the run is reproducible. If a
  script fails, read `references/troubleshooting.md` before improvising.
- **No secrets in files.** `databricks.prod.yml` is gitignored by the repo; keep
  it that way. Never commit it or paste tokens anywhere.

---

## The 8 steps

### Step 0 — Prerequisites & clone

Prereqs: `git`, Databricks CLI, `uv`, `bun`, `python3.12` (and `jq` recommended).
The CLI must be authenticated to the target workspace:

```bash
databricks auth login --host https://<workspace-url> --profile <name>
```

If the user needs to run that themselves, suggest they type it with a leading
`!` in the Claude Code prompt. Then clone the public repo (pick a working dir):

```bash
git clone https://github.com/databricks-solutions/solution-builder.git
```

Set `APP_DIR="$(pwd)/solution-builder/app"` — every script that touches the repo
takes `--app-dir "$APP_DIR"`.

### Step 1 — Preflight (read-only)

```bash
"$SKILL_DIR/scripts/preflight.sh" --profile <profile>
```

This checks tooling, confirms who you're signed in as + the host, lists the
**real serving endpoints** in the workspace (candidates for the model config),
and lists any existing **Lakebase projects**. Show the user the signed-in
identity + host and get a thumbs-up that it's the right workspace.

### Step 2 — Gather configuration choices

Ask the user for each value below. Use `AskUserQuestion` for the ones with real
choices (offer the preflight's discovered options as the choices); for free-text
names, just ask. Every value maps 1:1 to `databricks.prod.yml`.

| Config | Ask | Guidance |
|---|---|---|
| **App name** | What to call the deployed app | lowercase-with-hyphens, e.g. `solution-builder`. Becomes the workspace app + its URL. |
| **Lakebase** | New project or reuse an existing one? | New → pick a slug (e.g. `solution-builder`). Reuse → pick from preflight's list. |
| **Agent model** (`anthropic_llm_endpoint`) | Which Claude endpoint | A `databricks-claude-*` chat endpoint from preflight (e.g. `databricks-claude-sonnet-5`). |
| **AI Gateway** (`ai_gateway`) | Primary backend chat endpoint | A capable chat endpoint (e.g. `databricks-claude-opus-5`). |
| **AI Gateway mini** (`ai_gateway_mini`) | Cheap/fast utility endpoint | e.g. `databricks-gpt-5-4-mini`. |
| **Embedding** (`ai_gateway_embedding`) | Embedding endpoint | e.g. `databricks-qwen3-embedding-0-6b`. |
| **Default catalog** | Catalog new projects land in | Created at app boot if missing (e.g. `ai_demo_gen` or a catalog you own). |

Use the **exact** endpoint names preflight printed — built-in FMAPI endpoints
carry a `databricks-` prefix, and a wrong name fails the deploy (see
troubleshooting). Confirm the full set back to the user before proceeding.

### Step 3 — Provision Lakebase

Creating (fresh workspace) — the default branch is `production` and the
`databricks_postgres` maintenance DB is used, so there's **no `CREATE DATABASE`
step**:

```bash
"$SKILL_DIR/scripts/provision-lakebase.sh" --project-id <slug> --profile <profile>
```

Reusing an existing one:

```bash
"$SKILL_DIR/scripts/provision-lakebase.sh" --use-existing <slug> --profile <profile>
```

Capture the three `KEY=VALUE` lines it prints (`LAKEBASE_PROJECT_ID`,
`LAKEBASE_BRANCH_ID`, `LAKEBASE_DATABASE_NAME`) — you'll pass them to configure.

### Step 4 — Write `databricks.prod.yml` (+ the explicit scopes)

```bash
"$SKILL_DIR/scripts/configure.sh" \
  --app-dir "$APP_DIR" --profile <profile> \
  --app-name <name> \
  --lakebase-project-id <slug> --lakebase-branch-id <branch> --lakebase-database <db> \
  --anthropic-llm-endpoint <ep> --ai-gateway <ep> \
  --ai-gateway-mini <ep> --ai-gateway-embedding <ep> \
  --default-catalog <catalog>
```

This starts from `databricks.prod.yml.example`, fills your values, and **appends
the 9 explicit build scopes** to `user_api_scopes` (on top of the base
`catalog.*` reads). It then runs `bundle validate` and prints the resolved
**12-scope** list — show that to the user so they can see exactly what's granted.

### Step 5 — Deploy

```bash
"$SKILL_DIR/scripts/deploy.sh" --app-dir "$APP_DIR" --profile <profile>
```

Builds the artifact **first** (this avoids the `stat .build` chicken-and-egg),
then `bundle deploy`. This also creates the app's service principal. Deploy can
take a couple of minutes.

### Step 6 — Wire the service principal to Lakebase

```bash
"$SKILL_DIR/scripts/grant-sp.sh" \
  --app-name <name> --lakebase-project-id <slug> --lakebase-branch-id <branch> \
  --profile <profile>
```

Grants the app SP `CAN_MANAGE` on the Lakebase project and ensures its Postgres
role (superuser) so the app can create its DB + tables on first boot. Idempotent.

### Step 7 — Launch & verify

```bash
"$SKILL_DIR/scripts/launch.sh" --app-dir "$APP_DIR" --app-name <name> --profile <profile>
```

Starts the app compute, waits for `RUNNING`, prints the **App URL** and the
effective scopes. Hand the user the URL.

### Step 8 — Re-authorize, then build the first solution 🎉

**Re-authorize (required):** expanding scopes only changes what the app is
*allowed* to request — the user's token must re-consent. Tell them to:

1. Open the App URL (a fresh/incognito window is most reliable).
2. Accept the **authorization/consent prompt** for the new permissions.
3. If no prompt appears, cycle the compute and reopen:
   `databricks apps stop <name> --profile <p>` then `... start ...`.

Confirm it worked: in the app, ask the agent to report its current token
scopes — you want to see `sql`, `genie`, `postgres`, `workspace`, etc., not just
`catalog`.

**Build the first solution** — walk them in:

1. On the home page, choose **Describe your story** (the simplest entry).
2. Type a one-line idea (e.g. *"a retail returns analytics demo for a beauty
   brand"*) — or point it at their own UC tables (the Data Weaver grounds on
   real tables, read-only).
3. Watch the agent design → spec → build. Resources land in their workspace and
   in the project's file viewer.
4. Try **Start Preview** to see the generated app live in the browser.

Then take the **victory lap**: re-surface the superpowers from
`references/superpowers.md`, now framed as "here's what to try next" — spin up a
Genie space (the Genie's Lamp), generate an architecture diagram (the
Architect's Eye), or fork a gallery template (the Template Vault).

---

## If something breaks

Go to `references/troubleshooting.md` — it has the exact fix for the common
failures (endpoint-name 404, the `.build` error, scope/re-auth, the Terraform
key-expired error, Lakebase quota, empty gallery). Fix and re-run the specific
script; the scripts are safe to re-run.

## Local-dev alternative (optional)

If the user just wants to try it on their laptop without deploying: in `app/`,
`cp .env.example .env` (set `DATABRICKS_CONFIG_PROFILE`), then `uv sync`,
`bun install`, `./scripts/dev.sh`. PGLite gives a local Postgres — no Lakebase
needed. The deployed-app path above is for a shared, always-on install.
