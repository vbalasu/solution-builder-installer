#!/usr/bin/env bash
# ============================================================================
# check-endpoints.sh — verify the CHOSEN serving endpoints are actually
# CALLABLE, not merely present in `serving-endpoints list`.
#
# Many workspaces expose FMAPI endpoints that are DISABLED (a "rate limit of
# 0"): they show up in discovery but every query 403s. If that endpoint is
# wired into databricks.prod.yml, the deploy succeeds but the app's builds fail
# at runtime with:
#   403 PERMISSION_DENIED: The endpoint is temporarily disabled due to a
#   Databricks-set rate limit of 0.
# This script catches that up front so you can pick a working endpoint BEFORE
# provisioning Lakebase and deploying.
#
# Probes each given endpoint with a tiny real query. Exits non-zero if ANY of
# them is not OK, and prints working alternatives it finds so you can re-pick.
#
# Usage:
#   check-endpoints.sh [--profile <p>] \
#     [--anthropic-llm-endpoint <ep>] [--ai-gateway <ep>] \
#     [--ai-gateway-mini <ep>] [--ai-gateway-embedding <ep>]
#
# Any subset of the four may be passed; only what you pass is probed.
# ============================================================================
set -uo pipefail   # NOTE: no -e; a failed probe must not abort the whole run.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/lib.sh"

LLM=""; GW=""; GW_MINI=""; GW_EMB=""
while [[ $# -gt 0 ]]; do case "$1" in
  --profile) SB_PROFILE="$2"; shift 2 ;;
  --anthropic-llm-endpoint) LLM="$2"; shift 2 ;;
  --ai-gateway) GW="$2"; shift 2 ;;
  --ai-gateway-mini) GW_MINI="$2"; shift 2 ;;
  --ai-gateway-embedding) GW_EMB="$2"; shift 2 ;;
  -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "Unknown arg: $1" ;;
esac; done

need databricks "Install the Databricks CLI first."

FAILED=0
report() { # report <label> <endpoint> <chat|embedding>
  local label="$1" ep="$2" kind="$3" status
  [[ -z "$ep" ]] && return 0
  status="$(sb_probe_endpoint "$ep" "$kind")"
  case "$status" in
    OK)       ok   "$label: $ep — callable" ;;
    DISABLED) err  "$label: $ep — DISABLED (Databricks rate limit of 0 — not usable)"; FAILED=1 ;;
    MISSING)  err  "$label: $ep — NOT FOUND in this workspace"; FAILED=1 ;;
    *)        err  "$label: $ep — not callable (query returned an error)"; FAILED=1 ;;
  esac
}

step "Probing chosen endpoints (a tiny real query each)"
report "anthropic_llm_endpoint" "$LLM"     chat
report "ai_gateway"             "$GW"      chat
report "ai_gateway_mini"        "$GW_MINI" chat
report "ai_gateway_embedding"   "$GW_EMB"  embedding

if [[ "$FAILED" -eq 0 ]]; then
  hr; ok "All chosen endpoints are callable. Safe to configure + deploy."
  exit 0
fi

# ---- On failure: find working alternatives so the user can re-pick ---------
hr
warn "One or more endpoints are not usable. Finding working alternatives in this workspace…"
EP_JSON="$(dbx serving-endpoints list -o json 2>/dev/null || echo '[]')"
CHAT_CANDIDATES="$(EP_JSON="$EP_JSON" python3 <<'PY'
import os, json
eps = json.loads(os.environ.get("EP_JSON","") or "[]")
chat = [e["name"] for e in eps if e.get("task")=="llm/v1/chat"]
# prioritise commonly-enabled, capable, cheap-ish families first
pri = ["claude-sonnet","claude-haiku","claude","gpt-5-4-mini","gpt-5-mini","gpt","gemini","llama"]
def rank(n):
    n=n.lower()
    for i,p in enumerate(pri):
        if p in n: return i
    return len(pri)
print(" ".join(sorted(chat, key=rank)[:8]))
PY
)"
EMB_CANDIDATES="$(EP_JSON="$EP_JSON" python3 <<'PY'
import os, json
eps = json.loads(os.environ.get("EP_JSON","") or "[]")
print(" ".join([e["name"] for e in eps if e.get("task")=="llm/v1/embeddings"][:8]))
PY
)"

say ""
say "  Working CHAT endpoints (probed):"
FOUND_CHAT=0
for ep in $CHAT_CANDIDATES; do
  if [[ "$(sb_probe_endpoint "$ep" chat)" == "OK" ]]; then ok "    $ep"; FOUND_CHAT=1; fi
done
[[ "$FOUND_CHAT" -eq 0 ]] && warn "    (none of the top candidates responded — check workspace model-serving access)"

say ""
say "  Working EMBEDDING endpoints (probed):"
FOUND_EMB=0
for ep in $EMB_CANDIDATES; do
  if [[ "$(sb_probe_endpoint "$ep" embedding)" == "OK" ]]; then ok "    $ep"; FOUND_EMB=1; fi
done
[[ "$FOUND_EMB" -eq 0 ]] && warn "    (none responded — check workspace model-serving access)"

hr
err "Re-pick the failing endpoint(s) from the working list above, then re-run this check (and configure.sh)."
exit 1
