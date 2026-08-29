#!/usr/bin/env bash
# ============================================================================
# lib.sh — shared helpers for the Solution Builder installer scripts.
# Sourced by every other script. No side effects on source.
# ============================================================================

# ---- pretty output ---------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[0;32m'; C_BLUE=$'\033[0;34m'; C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[0;31m'; C_CYAN=$'\033[0;36m'; C_MAGENTA=$'\033[0;35m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""; C_GREEN=""; C_BLUE=""; C_YELLOW=""
  C_RED=""; C_CYAN=""; C_MAGENTA=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s▸ %s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
info() { printf '%s·%s %s\n' "$C_DIM" "$C_RESET" "$*"; }
err()  { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s\n' "${C_DIM}────────────────────────────────────────────────────────────${C_RESET}"; }

# ---- prerequisites ---------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: '$1'. $2"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- platform / package-manager detection ----------------------------------
detect_os() { case "$(uname -s)" in Darwin) echo macos ;; Linux) echo linux ;; *) echo other ;; esac; }
detect_pm() {
  for pm in brew apt-get dnf yum pacman zypper; do
    command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return; }
  done
  echo none
}
# Common install dirs used by the official uv/bun installers, so we can find
# freshly-installed tools within the same run (a new shell won't have them yet).
sb_augment_path() { export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"; }

# ---- profile flag helper ---------------------------------------------------
# Every databricks call takes an optional --profile. If SB_PROFILE is set we
# pass it; otherwise the CLI default / DATABRICKS_CONFIG_PROFILE is used.
: "${SB_PROFILE:=}"
dbx() {
  if [[ -n "$SB_PROFILE" ]]; then
    databricks "$@" --profile "$SB_PROFILE"
  else
    databricks "$@"
  fi
}

# ---- tiny JSON extractor (uses python3, always present on macOS/Linux) -----
# usage: echo "$json" | jget 'a.b.0.c'
# NOTE: JSON is passed via env (SB_JGET_JSON), NOT piped to python's stdin.
# A `python3 - <<'PY'` heredoc makes the heredoc python's stdin (the program),
# so json.load(sys.stdin) would read empty — hence the env-var handoff.
jget() {
  SB_JGET_JSON="$(cat)" SB_JGET_PATH="${1:-}" python3 <<'PY'
import sys, os, json
raw  = os.environ.get("SB_JGET_JSON", "")
_pth = os.environ.get("SB_JGET_PATH", "")
path = _pth.split(".") if _pth else []
try:
    data = json.loads(raw) if raw.strip() else None
except Exception:
    sys.exit(0)
if data is None:
    sys.exit(0)
cur = data
for key in path:
    if isinstance(cur, list):
        try: cur = cur[int(key)]
        except Exception: sys.exit(0)
    elif isinstance(cur, dict):
        cur = cur.get(key)
    else:
        sys.exit(0)
    if cur is None:
        sys.exit(0)
if isinstance(cur, (dict, list)):
    print(json.dumps(cur))
elif isinstance(cur, bool):
    print("true" if cur else "false")
else:
    print(cur)
PY
}

# ---- the canonical explicit OBO scope set ----------------------------------
# These are the EXACT documented Databricks Apps user-authorization scopes the
# Build stage needs — appended to the base catalog.* reads that ship in
# databricks.yml. We deliberately do NOT use `all-apis` (see references/scopes.md).
SB_BUILD_SCOPES=(
  sql                  # SQL warehouses + query execution (dashboards, metric views, data-gen SQL, Genie validation)
  genie                # Genie space create/manage
  postgres             # Lakebase (Postgres) objects
  workspace.workspace  # Jobs, Lakeflow/SDP pipelines, clusters, notebooks, secrets, repos
  files                # Workspace files / UC volume file IO (data-gen output, RAG source docs)
  apps                 # Create/deploy the generated Databricks App
  model-serving        # Serving endpoints for Knowledge Assistant / Multi-Agent Supervisor
  vector-search        # Vector indexes for RAG / Knowledge Assistant
  catalog.connections  # Lakeflow Connect ingestion connections
)
