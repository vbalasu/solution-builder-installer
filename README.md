# 🛠️ Solution Builder Installer — a Claude Code skill

A friendly, mostly-automated installer for [**Databricks Solution
Builder**](https://github.com/databricks-solutions/solution-builder) — the tool
that turns a sentence into a working Databricks solution (synthetic data,
Lakeflow pipelines, AI/BI dashboards, Genie spaces, agents, even a deployed
app).

This skill walks you from an **empty workspace** to a **running Solution Builder
app** and your **first built solution** — prompting for every configuration
choice, provisioning Lakebase, applying the exact least-privilege scopes,
deploying, wiring the service principal, and launching. The deterministic parts
are done by scripts so the run is reproducible; the judgment parts (which model
endpoints, new vs. existing Lakebase) are asked of you.

> Invoke it in Claude Code as **`/solution-builder-installer`**.

## What you'll unlock (a taste)

| ⚡ | |
|---|---|
| 🧬 **The Data Weaver** | Realistic synthetic industry data from one line — or grounded on your own UC tables, read-only. |
| 🌊 **The Pipeline Forge** | End-to-end Lakeflow (SDP) medallion pipelines from a spec. |
| 🧞 **The Genie's Lamp** | Ask-your-data Genie spaces, built and validated. |
| 🚀 **The App Launcher** | A full custom Databricks App, previewed live and deployed. |

(Full list in [`references/superpowers.md`](references/superpowers.md).)

## Install the skill

```bash
git clone git@github-vbalasu:vbalasu/solution-builder-installer.git \
  ~/.claude/skills/solution-builder-installer
```

(HTTPS also works: `https://github.com/vbalasu/solution-builder-installer.git`.)

Restart Claude Code (or `/skills`), then run:

```
/solution-builder-installer
```

Claude reads `SKILL.md` and drives the rest.

## Prerequisites

- Databricks CLI, authenticated to the target workspace
  (`databricks auth login --host https://<workspace-url> --profile <name>`)
- [`uv`](https://docs.astral.sh/uv/) · [`bun`](https://bun.sh/) · Python 3.12 · `git` · (`jq` recommended)
- A Databricks workspace **you control** (this is designed for a fresh/sandbox
  workspace), with Lakebase (Postgres) available.

## What it does (the 8 steps)

0. **Clone** the public Solution Builder repo.
1. **Preflight** — check tooling + auth, discover serving endpoints and Lakebase projects (read-only).
2. **Gather config** — you pick app name, Lakebase, model/embedding endpoints, default catalog.
3. **Provision Lakebase** — create (or reuse) a project; discover branch + database.
4. **Configure** — write `databricks.prod.yml` from the upstream `.example` and append the **exact explicit build scopes**.
5. **Deploy** — build the artifact, then `bundle deploy` (creates the app SP).
6. **Grant the SP** — `CAN_MANAGE` on Lakebase + its Postgres role.
7. **Launch & verify** — start the app, wait for `RUNNING`, print the URL + scopes.
8. **Re-authorize & build** — consent to the new scopes, then build your first solution. 🎉

## Scopes: explicit, never `all-apis`

The agent builds resources **as the signed-in user** (OBO). This installer
declares the **exact** documented Databricks Apps scopes the Build stage needs
and appends them to the base `catalog.*` reads — it deliberately does **not**
grant the coarse `all-apis` scope. The resolved set is 12 scopes; the rationale
and the full list are in [`references/scopes.md`](references/scopes.md).

## The scripts

| Script | Does |
|---|---|
| `scripts/preflight.sh` | Read-only readiness check + discovery |
| `scripts/provision-lakebase.sh` | Create/reuse a Lakebase project; print its config values |
| `scripts/configure.sh` | Generate `databricks.prod.yml` from the `.example` + append explicit scopes |
| `scripts/deploy.sh` | Build the artifact, then deploy the bundle |
| `scripts/grant-sp.sh` | Grant the app SP on Lakebase (+ its Postgres role) |
| `scripts/launch.sh` | Start the app, wait for `RUNNING`, report URL + scopes |
| `scripts/lib.sh` | Shared helpers + the canonical scope list |

Each script is idempotent and safe to re-run, takes `--profile`, and prints
`--help`.

## Safety & privacy

- Contains **no** workspace IDs, account IDs, service-principal IDs, emails, or
  profile names — everything workspace-specific is passed in at runtime.
- `databricks.prod.yml` (which holds your values) is **gitignored by the
  Solution Builder repo** — keep it that way; never commit it.
- Least-privilege by design (explicit scopes, not `all-apis`).

## Troubleshooting

See [`references/troubleshooting.md`](references/troubleshooting.md) for the
exact fix for each common failure.

---

*Community helper for Databricks Solution Builder. Provided as-is; not an
official Databricks product.*
