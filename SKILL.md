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

## Start here — respond instantly, ask for the workspace URL

**Your very first reply is one quick question: which Databricks workspace URL
should Solution Builder be installed into?** Nothing comes before it — do **not**
read reference files, run any script, or list `databricks auth profiles` first.
That work is slow and makes the skill feel sluggish; it all waits until you have
the URL. Send one warm line of vibe + the question, and stop:

> "Let's stand up Solution Builder — a sentence in, a working Databricks solution
> out. 🛠️ **What's the workspace URL where you'd like it installed?** (something
> like `https://your-workspace.cloud.databricks.com`)"

Once the user gives you the URL: confirm it's a workspace they own/control, then
authenticate the CLI to it —
`databricks auth login --host <url> --profile <name>` (a leading `!` lets the
user run the interactive login themselves). Reach for `databricks auth profiles`
**only if you have to** — e.g. to reuse a profile already signed in to that
host — never as an opening move. Everything else below happens *after* this.

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

## Set the destination (the superpowers)

Right *after* the workspace-URL question — while auth/preflight runs, not
before your first reply — tell the user what they're unlocking. Pull 3–4
relevant items from `references/superpowers.md` (the Data Weaver, the Pipeline
Forge, the Genie's Lamp, the App Launcher, …) and give them the one-liner. Keep
it to the vibe ("a sentence in, a working Databricks solution out"); never let it
delay that opening question.

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

## The steps (0 → 8)

### Step 0 — Prerequisites (tools + access) & clone

You've already asked for the workspace URL and started `databricks auth login`
to it (see **Start here**) — that's the front of this step. What's left is local
tooling, an access sanity-check, and the clone; none of it should precede that
first workspace-URL question.

**Don't assume the tools are installed — help set them up.** Report what's
missing (read-only), show the user the plan, then install with their OK:

```bash
"$SKILL_DIR/scripts/install-prereqs.sh"            # report only — what's missing + exact commands
"$SKILL_DIR/scripts/install-prereqs.sh --install"  # install the missing ones (after user OK)
```

It covers `git`, Databricks CLI, `uv`, `bun`, `python3` (+ `python3.12` for local
data-gen, via `uv python install 3.12`), and `jq`. On macOS it uses Homebrew (no
sudo); elsewhere it uses the official installers + your package manager. **Any
step that needs `sudo` or is interactive (e.g. installing Homebrew itself, or an
`apt`/`dnf` install), hand to the user to run with a leading `!`** rather than
running it yourself. After installing `uv`/`bun` via their official installers,
their bins (`~/.local/bin`, `~/.bun/bin`) may not be on `PATH` in this shell —
tell the user to open a new terminal or add them to `PATH`.

**Access / privileges — the least-privilege picture (state this clearly up front):**

- ✅ **Account admin is NOT required.** Because this installer declares the exact
  per-app OBO scopes (never the account-level `all-apis` integration grant),
  there is no account-admin step at all.
- ✅ **Workspace admin is NOT strictly required** — but it makes everything
  frictionless. If the user is **not** a workspace admin, they need these
  specific capabilities (all normally available to the owner of a sandbox /
  personal / FEVM workspace):
  - **Create a Databricks App** (Apps must be enabled; the user needs app-create
    permission). The app's service principal is created automatically.
  - **Create a Lakebase (Postgres) project** — workspace users hold `CAN_CREATE`
    on database projects **by default**, so this is not admin-gated (or reuse an
    existing project they can manage).
  - **A Unity Catalog they can build in** — point `default_catalog` at a catalog
    where they have `USE CATALOG` + `CREATE SCHEMA` (or that they own).
    ⚠️ Naming a brand-new catalog means the app must `CREATE CATALOG` on the
    metastore (metastore-admin territory) — so **prefer an existing catalog** to
    stay least-privilege.
  - **Query the chosen serving endpoints** — the built-in `databricks-*` FMAPI
    endpoints are callable by all workspace users, so this is normally free.
- ℹ️ **The demo BUILDS run as the signed-in user (OBO), bounded by that user's
  own privileges.** The app can never do more than the user can — so what a demo
  can create is limited by the user's UC/compute grants. On their own workspace
  that's typically everything.

The CLI must be authenticated to the target workspace:

```bash
databricks auth login --host https://<workspace-url> --profile <name>
```

If the user needs to run that themselves, suggest the leading `!`. Then clone the
public repo (pick a working dir):

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
identity + host and get a thumbs-up that it's the right workspace. Note: the
endpoint list shows what *exists*, not what's *callable* — a live probe in step 2
(`check-endpoints.sh`) confirms the chosen ones actually work.

### Step 2 — Gather configuration choices

Ask the user for each value below. Use `AskUserQuestion` for the ones with real
choices (offer the preflight's discovered options as the choices); for free-text
names, just ask. Every value maps 1:1 to `databricks.prod.yml`.

| Config | Ask | Guidance |
|---|---|---|
| **App name** | What to call the deployed app | lowercase-with-hyphens, e.g. `solution-builder`. Becomes the workspace app + its URL. |
| **Lakebase** | New project or reuse an existing one? | New → pick a slug (e.g. `solution-builder`). Reuse → pick from preflight's list. |
| **Agent model** (`anthropic_llm_endpoint`) | Which Claude endpoint | A `databricks-claude-*` chat endpoint from preflight (e.g. `databricks-claude-sonnet-5`). |
| **AI Gateway** (`ai_gateway`) | Primary backend chat endpoint | A capable chat endpoint (e.g. `databricks-claude-sonnet-5`). Opus endpoints are often disabled (rate-limit 0) — the endpoint check below will tell you. |
| **AI Gateway mini** (`ai_gateway_mini`) | Cheap/fast utility endpoint | e.g. `databricks-gpt-5-4-mini`. |
| **Embedding** (`ai_gateway_embedding`) | Embedding endpoint | e.g. `databricks-qwen3-embedding-0-6b`. |
| **Default catalog** | Catalog new projects land in | Created at app boot if missing (e.g. `ai_demo_gen` or a catalog you own). |

Use the **exact** endpoint names preflight printed — built-in FMAPI endpoints
carry a `databricks-` prefix, and a wrong name fails the deploy (see
troubleshooting). Confirm the full set back to the user before proceeding.

**Then verify the chosen endpoints are actually CALLABLE — not just listed.**
Many workspaces expose FMAPI endpoints in discovery that are DISABLED (a
"rate limit of 0"): they pass `serving-endpoints list` but every query 403s, so
the deploy succeeds and then the app's *builds* fail at runtime with
`403 PERMISSION_DENIED: The endpoint is temporarily disabled due to a
Databricks-set rate limit of 0.` Catch it now, before provisioning + deploying:

```bash
"$SKILL_DIR/scripts/check-endpoints.sh" --profile <profile> \
  --anthropic-llm-endpoint <ep> --ai-gateway <ep> \
  --ai-gateway-mini <ep> --ai-gateway-embedding <ep>
```

It sends a tiny real query to each. If any is DISABLED/missing it exits non-zero
and prints the endpoints that **did** respond — re-pick from that working list
(re-ask the user) and re-run the check until it's all green. (Note: Opus / newer
GPT endpoints are often the disabled ones; `databricks-claude-sonnet-*`,
`databricks-claude-haiku-*`, and `databricks-*-embedding-*` are commonly
enabled.) `configure.sh` re-runs this same probe as a backstop and refuses to
write a config with an unusable endpoint.

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
