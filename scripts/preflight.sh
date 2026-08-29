#!/usr/bin/env bash
# ============================================================================
# preflight.sh — read-only readiness check for a Solution Builder install.
#
# Verifies local tooling, confirms Databricks auth, and DISCOVERS the two
# workspace-specific things the installer needs choices for:
#   • serving endpoints available (so we pick real model/embedding endpoints)
#   • existing Lakebase (Postgres) projects (so we reuse vs. create)
#
# Makes NO changes. Safe to run repeatedly.
#
# Usage: preflight.sh [--profile <cli-profile>]
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/lib.sh"

while [[ $# -gt 0 ]]; do case "$1" in
  --profile) SB_PROFILE="$2"; shift 2 ;;
  -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "Unknown arg: $1" ;;
esac; done

step "1/4  Local tooling"
need git      "Install: https://git-scm.com/"
need databricks "Install the Databricks CLI: https://docs.databricks.com/dev-tools/cli/"
need uv       "Install uv: https://docs.astral.sh/uv/"
need bun      "Install bun: https://bun.sh/"
need python3  "Python 3.12 is required for local data-gen; install from https://python.org/"
have jq   || warn "jq not found — optional, but recommended (brew install jq)."
have node || warn "node not found — only needed if you also run the app locally."
DBX_VER="$(databricks version 2>/dev/null | head -1 || echo unknown)"
ok "databricks CLI: $DBX_VER"
ok "uv: $(uv --version 2>/dev/null || echo '?')   bun: $(bun --version 2>/dev/null || echo '?')   python3: $(python3 --version 2>/dev/null | awk '{print $2}')"

step "2/4  Databricks authentication"
ME_JSON="$(dbx current-user me -o json 2>/dev/null || true)"
[[ -n "$ME_JSON" ]] || die "Not authenticated. Run:  databricks auth login --host https://<workspace-url> --profile <name>"
ME_EMAIL="$(printf '%s' "$ME_JSON" | jget 'userName')"
HOST="$(dbx auth env 2>/dev/null | sed -n 's/.*DATABRICKS_HOST=\([^ ]*\).*/\1/p' | head -1)"
[[ -n "$HOST" ]] || HOST="$(printf '%s' "$ME_JSON" | jget 'active.host')"
ok "Signed in as: ${ME_EMAIL:-unknown}"
[[ -n "${HOST:-}" ]] && ok "Workspace host: $HOST"
info "Profile in use: ${SB_PROFILE:-<CLI default / DATABRICKS_CONFIG_PROFILE>}"

step "3/4  Serving endpoints (candidates for the model/embedding config)"
EP_JSON="$(dbx serving-endpoints list -o json 2>/dev/null || echo '[]')"
printf '%s' "$EP_JSON" | python3 - <<'PY'
import sys, json
eps = json.load(sys.stdin)
chat  = [e["name"] for e in eps if e.get("task")=="llm/v1/chat"]
embed = [e["name"] for e in eps if e.get("task")=="llm/v1/embeddings"]
def suggest(names, needles):
    for n in needles:
        m = [x for x in names if n in x.lower()]
        if m: return m[0]
    return names[0] if names else "<none>"
print("  Claude / agent (anthropic bridge):")
for n in [x for x in chat if "claude" in x.lower()][:6] or chat[:4]: print("    -", n)
print("  Embeddings:")
for n in embed[:6]: print("    -", n)
print()
print("  Suggested defaults (edit to taste):")
print("    anthropic_llm_endpoint :", suggest(chat, ["claude-sonnet","claude"]))
print("    ai_gateway             :", suggest(chat, ["claude-opus","claude","gpt"]))
print("    ai_gateway_mini        :", suggest(chat, ["mini","nano","flash","gpt"]))
print("    ai_gateway_embedding   :", suggest(embed, ["embedding","embed","bge","gte"]))
if not chat:  print("  ! No chat endpoints visible — check workspace / permissions.")
PY
info "All the above are real endpoint names in THIS workspace — the config step uses them verbatim (they already carry any 'databricks-' prefix)."

step "4/4  Existing Lakebase (Postgres) projects"
PROJ_JSON="$(dbx postgres list-projects -o json 2>/dev/null || echo '[]')"
COUNT="$(printf '%s' "$PROJ_JSON" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"
if [[ "$COUNT" == "0" ]]; then
  info "No Lakebase projects yet — the installer will create one for you."
else
  printf '%s' "$PROJ_JSON" | python3 - <<'PY'
import sys, json
for p in json.load(sys.stdin):
    st = p.get("status", {})
    print(f"    - {p.get('project_id')}   (default branch: {st.get('default_branch','?').split('/')[-1]}, pg {st.get('pg_version','?')})")
PY
  info "You can reuse one of these OR create a fresh project in the next step."
fi

hr
ok "Preflight complete. Ready to gather your configuration choices."
