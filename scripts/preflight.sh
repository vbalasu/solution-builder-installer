#!/usr/bin/env bash
# ============================================================================
# preflight.sh — read-only readiness check for a Solution Builder install.
#
# Verifies local tooling (NON-FATAL — reports what's missing and points at
# install-prereqs.sh), confirms Databricks auth, and DISCOVERS the two
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
  -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "Unknown arg: $1" ;;
esac; done

step "1/4  Local tooling"
MISSING=()
check() { # check <tool> <required|optional>
  if have "$1"; then ok "$1 — present"; else
    if [[ "$2" == "required" ]]; then err "$1 — MISSING (required)"; MISSING+=("$1")
    else warn "$1 — missing (optional)"; fi
  fi
}
check git        required
check databricks required
check uv         required
check bun        required
check python3    required
check jq         optional
check node       optional
if have databricks; then ok "databricks CLI: $(databricks version 2>/dev/null | head -1)"; fi
if [[ ${#MISSING[@]} -gt 0 ]]; then
  warn "Missing required tools: ${MISSING[*]}"
  say  "  Fix it (this skill can do it for you):"
  say  "    $SCRIPT_DIR/install-prereqs.sh --install"
  say  "  Then re-run preflight."
fi

# Discovery needs databricks + python3; skip gracefully if absent.
if ! have databricks || ! have python3; then
  hr
  warn "Skipping auth + workspace discovery until databricks CLI and python3 are installed."
  exit 0
fi

step "2/4  Databricks authentication"
ME_JSON="$(dbx current-user me -o json 2>/dev/null || true)"
if [[ -z "$ME_JSON" ]]; then
  err "Not authenticated. Run:"
  say "    databricks auth login --host https://<workspace-url> --profile <name>"
  hr; warn "Re-run preflight once authenticated."
  exit 0
fi
ME_EMAIL="$(printf '%s' "$ME_JSON" | jget 'userName')"
HOST="$(dbx auth env 2>/dev/null | sed -n 's/.*DATABRICKS_HOST=\([^ ]*\).*/\1/p' | head -1)"
[[ -n "$HOST" ]] || HOST="$(printf '%s' "$ME_JSON" | jget 'active.host')"
ok "Signed in as: ${ME_EMAIL:-unknown}"
[[ -n "${HOST:-}" ]] && ok "Workspace host: $HOST"
info "Profile in use: ${SB_PROFILE:-<CLI default / DATABRICKS_CONFIG_PROFILE>}"

step "3/4  Serving endpoints (candidates for the model/embedding config)"
EP_JSON="$(dbx serving-endpoints list -o json 2>/dev/null || echo '[]')"
EP_JSON="$EP_JSON" python3 <<'PY'
import os, json
eps = json.loads(os.environ.get("EP_JSON", "") or "[]")
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
  info "No Lakebase projects yet — the installer will create one for you (workspace users can create these by default)."
else
  PROJ_JSON="$PROJ_JSON" python3 <<'PY'
import os, json
for p in json.loads(os.environ.get("PROJ_JSON", "") or "[]"):
    st = p.get("status", {})
    print(f"    - {p.get('project_id')}   (default branch: {st.get('default_branch','?').split('/')[-1]}, pg {st.get('pg_version','?')})")
PY
  info "You can reuse one of these OR create a fresh project in the next step."
fi

hr
if [[ ${#MISSING[@]} -gt 0 ]]; then
  warn "Preflight OK, but install the missing tools (above) before deploying."
else
  ok "Preflight complete. Ready to gather your configuration choices."
fi
