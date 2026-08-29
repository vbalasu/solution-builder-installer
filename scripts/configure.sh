#!/usr/bin/env bash
# ============================================================================
# configure.sh — generate app/databricks.prod.yml from databricks.prod.yml.example,
# filling in your workspace-specific values AND appending the EXACT explicit
# build-stage OBO scopes (never `all-apis` — see references/scopes.md).
#
# Starts from the upstream .example so it stays faithful to the repo's own
# template; only the placeholder VALUES change and one scopes block is inserted.
#
# Usage (all flags except --app-dir are required for a complete config):
#   configure.sh --app-dir <path/to/solution-builder/app> \
#     --profile <cli-profile> --app-name <name> \
#     --lakebase-project-id <slug> [--lakebase-branch-id production] \
#     [--lakebase-database databricks_postgres] \
#     --anthropic-llm-endpoint <ep> --ai-gateway <ep> \
#     --ai-gateway-mini <ep> --ai-gateway-embedding <ep> \
#     --default-catalog <catalog> [--force]
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/lib.sh"

APP_DIR="$(pwd)"; PROFILE=""; APP_NAME=""; LB_PROJECT=""; LB_BRANCH="production"
LB_DB="databricks_postgres"; LLM=""; GW=""; GW_MINI=""; GW_EMB=""; CATALOG=""; FORCE=0
while [[ $# -gt 0 ]]; do case "$1" in
  --app-dir) APP_DIR="$2"; shift 2 ;;
  --profile) PROFILE="$2"; SB_PROFILE="$2"; shift 2 ;;
  --app-name) APP_NAME="$2"; shift 2 ;;
  --lakebase-project-id) LB_PROJECT="$2"; shift 2 ;;
  --lakebase-branch-id) LB_BRANCH="$2"; shift 2 ;;
  --lakebase-database) LB_DB="$2"; shift 2 ;;
  --anthropic-llm-endpoint) LLM="$2"; shift 2 ;;
  --ai-gateway) GW="$2"; shift 2 ;;
  --ai-gateway-mini) GW_MINI="$2"; shift 2 ;;
  --ai-gateway-embedding) GW_EMB="$2"; shift 2 ;;
  --default-catalog) CATALOG="$2"; shift 2 ;;
  --deployer-sp-client-id) DEPLOYER_SP_CLIENT_ID="$2"; shift 2 ;;
  --deployer-sp-secret-scope) DEPLOYER_SP_SECRET_SCOPE="$2"; shift 2 ;;
  --deployer-sp-secret-key) DEPLOYER_SP_SECRET_KEY="$2"; shift 2 ;;
  --default-target-workspace-host) DEFAULT_TARGET_WS_HOST="$2"; shift 2 ;;
  --force) FORCE=1; shift ;;
  --skip-endpoint-check) SKIP_EP_CHECK=1; shift ;;
  -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "Unknown arg: $1" ;;
esac; done
: "${SKIP_EP_CHECK:=0}"
: "${DEPLOYER_SP_CLIENT_ID:=}"; : "${DEPLOYER_SP_SECRET_SCOPE:=}"
: "${DEPLOYER_SP_SECRET_KEY:=}"; : "${DEFAULT_TARGET_WS_HOST:=}"

EXAMPLE="$APP_DIR/databricks.prod.yml.example"
OUT="$APP_DIR/databricks.prod.yml"
[[ -f "$EXAMPLE" ]] || die "Not found: $EXAMPLE  (is --app-dir pointing at solution-builder/app ?)"
for pair in "profile:$PROFILE" "app-name:$APP_NAME" "lakebase-project-id:$LB_PROJECT" \
            "anthropic-llm-endpoint:$LLM" "ai-gateway:$GW" "ai-gateway-mini:$GW_MINI" \
            "ai-gateway-embedding:$GW_EMB" "default-catalog:$CATALOG"; do
  [[ -n "${pair#*:}" ]] || die "Missing required value: --${pair%%:*}"
done
# --- gate: the chosen endpoints must be CALLABLE, not just listed -----------
# A "rate limit of 0" endpoint deploys fine but fails every build at runtime.
# Catch it here so a broken config is never written. Bypass with
# --skip-endpoint-check (e.g. offline / no model-serving access).
if [[ "$SKIP_EP_CHECK" != "1" ]]; then
  step "Verifying chosen endpoints are callable (not just present)"
  EP_FAIL=0
  probe_or_flag() { # <label> <endpoint> <chat|embedding>
    local st; st="$(sb_probe_endpoint "$2" "$3")"
    case "$st" in
      OK) ok "$1: $2 — callable" ;;
      DISABLED) err "$1: $2 — DISABLED (Databricks rate limit of 0)"; EP_FAIL=1 ;;
      MISSING) err "$1: $2 — not found in this workspace"; EP_FAIL=1 ;;
      *) err "$1: $2 — not callable"; EP_FAIL=1 ;;
    esac
  }
  probe_or_flag "anthropic_llm_endpoint" "$LLM"     chat
  probe_or_flag "ai_gateway"             "$GW"      chat
  probe_or_flag "ai_gateway_mini"        "$GW_MINI" chat
  probe_or_flag "ai_gateway_embedding"   "$GW_EMB"  embedding
  if [[ "$EP_FAIL" -ne 0 ]]; then
    hr
    die "Refusing to write a config with an unusable endpoint. Run check-endpoints.sh to see working alternatives, re-pick, and retry (or pass --skip-endpoint-check to override)."
  fi
fi

if [[ -f "$OUT" && "$FORCE" != "1" ]]; then
  BAK="$OUT.bak.$(date +%s)"; cp "$OUT" "$BAK"
  warn "databricks.prod.yml already exists — backed up to $(basename "$BAK") and overwriting (use --force to skip this notice)."
fi

step "Writing $OUT from the .example template"
python3 - "$EXAMPLE" "$OUT" "$PROFILE" "$APP_NAME" "$LB_PROJECT" "$LB_BRANCH" "$LB_DB" \
        "$LLM" "$GW" "$GW_MINI" "$GW_EMB" "$CATALOG" "${SB_BUILD_SCOPES[*]}" <<'PY'
import sys, re
(_, ex, out, profile, app_name, lb_proj, lb_branch, lb_db,
 llm, gw, gw_mini, gw_emb, catalog, scopes_joined) = sys.argv
scopes = scopes_joined.split()
lines = open(ex).read().splitlines()

# --- replace values by key (6-space indent inside targets.prod.*) ----------
kv = {
    "profile": profile, "app_name": app_name,
    "lakebase_project_id": lb_proj, "lakebase_branch_id": lb_branch,
    "lakebase_database_name": lb_db, "anthropic_llm_endpoint": llm,
    "ai_gateway": gw, "ai_gateway_mini": gw_mini, "ai_gateway_embedding": gw_emb,
    "default_catalog": catalog,
}
seen = set()
def repl(line):
    m = re.match(r'^(\s{6})([a-z_]+):(\s+)(\S.*)$', line)
    if m and m.group(2) in kv:
        seen.add(m.group(2))
        return f"{m.group(1)}{m.group(2)}: {kv[m.group(2)]}"
    return line
lines = [repl(l) for l in lines]

# --- insert the explicit scopes block right after `workspace:` / `profile:` --
scope_block = [
    "",
    "    # ────────────────────────────────────────────────────────────────────────",
    "    # Build-stage OBO scopes — the EXACT, explicit set (NEVER all-apis).",
    "    # ────────────────────────────────────────────────────────────────────────",
    "    # APPENDED to databricks.yml's base catalog.catalogs/schemas/tables reads.",
    "    # The agent runs against the workspace on the ACTING USER's downscoped",
    "    # token, so it can only do what these scopes allow (bounded by the user's",
    "    # own privileges). Every token below is a documented Databricks Apps scope;",
    "    # there is no jobs/pipelines/clusters scope — those live under",
    "    # workspace.workspace. After changing scopes the acting user must",
    "    # RE-AUTHORIZE the app (reload → accept the consent prompt).",
    "    resources:",
    "      apps:",
    "        demo-prompt-generator-app:",
    "          user_api_scopes:",
]
for s in scopes:
    scope_block.append(f"            - {s}")

out_lines, inserted = [], False
i = 0
while i < len(lines):
    out_lines.append(lines[i])
    # after the `      profile: ...` line that follows `    workspace:`
    if (not inserted and re.match(r'^\s{6}profile:\s', lines[i])
            and i > 0 and re.match(r'^\s{4}workspace:\s*$', lines[i-1])):
        out_lines.extend(scope_block)
        inserted = True
    i += 1

missing = [k for k in kv if k not in seen]
if missing:
    sys.stderr.write("WARNING: did not find these keys in the template to replace: %s\n" % ", ".join(missing))
if not inserted:
    sys.stderr.write("ERROR: could not locate the workspace/profile anchor to insert scopes.\n")
    sys.exit(3)

open(out, "w").write("\n".join(out_lines) + "\n")
print("wrote %d lines; replaced %d keys; inserted %d scopes" % (len(out_lines), len(seen), len(scopes)))
PY
ok "Generated databricks.prod.yml"

# --- optional: wire the DEPLOYER SERVICE PRINCIPAL into app_env --------------
# Required for AI/BI dashboards + full template builds: the OBO token can't
# carry the `dashboards` scope, so builds must run as a non-downscoped SP.
# See references/scopes.md → "Why a deployer SP". The client SECRET is read
# from the secret scope and written as a plain app env var into this GITIGNORED
# file (Databricks Apps deliver SP creds via env; build.sh has no valueFrom
# path). It is never committed. Skip the whole block if no SP was passed.
if [[ -n "$DEPLOYER_SP_CLIENT_ID" ]]; then
  step "Wiring the deployer service principal into app_env"
  if [[ -z "$DEPLOYER_SP_SECRET_SCOPE" || -z "$DEPLOYER_SP_SECRET_KEY" ]]; then
    die "Need --deployer-sp-secret-scope and --deployer-sp-secret-key with --deployer-sp-client-id."
  fi
  TARGET_HOST="${DEFAULT_TARGET_WS_HOST}"
  if [[ -z "$TARGET_HOST" ]]; then
    TARGET_HOST="$(dbx auth env 2>/dev/null | sed -n 's/.*DATABRICKS_HOST=\([^ ]*\).*/\1/p' | head -1)"
  fi
  OUT="$OUT" SC="$DEPLOYER_SP_SECRET_SCOPE" KY="$DEPLOYER_SP_SECRET_KEY" \
  CID="$DEPLOYER_SP_CLIENT_ID" HOST="$TARGET_HOST" PROFILE="${SB_PROFILE:-}" python3 <<'PY'
import os, subprocess, base64, json, sys
out = os.environ["OUT"]
cmd = ["databricks","secrets","get-secret",os.environ["SC"],os.environ["KY"],"-o","json"]
if os.environ.get("PROFILE"): cmd += ["--profile", os.environ["PROFILE"]]
r = subprocess.run(cmd, capture_output=True, text=True)
try:
    secret = base64.b64decode(json.loads(r.stdout)["value"]).decode()
except Exception:
    sys.stderr.write("ERROR: could not read secret %s/%s from the scope.\n" % (os.environ["SC"], os.environ["KY"]))
    sys.exit(4)
lines = open(out).read().splitlines()
if any(l.startswith("        DEPLOYER_SP_CLIENT_ID:") for l in lines):
    print("· deployer SP env already present"); sys.exit(0)
anchor = next((i for i,l in enumerate(lines) if l.startswith("        DEFAULT_CATALOG:")), None)
if anchor is None:
    sys.stderr.write("ERROR: could not find the app_env anchor (DEFAULT_CATALOG).\n"); sys.exit(4)
inject = [
    "        DEPLOYER_SP_CLIENT_ID: %s" % os.environ["CID"],
    "        DEPLOYER_SP_CLIENT_SECRET: %s" % secret,
]
if os.environ.get("HOST"):
    inject.append("        DEFAULT_TARGET_WORKSPACE_HOST: %s" % os.environ["HOST"])
lines[anchor+1:anchor+1] = inject
open(out,"w").write("\n".join(lines) + "\n")
print("wrote DEPLOYER_SP_CLIENT_ID + DEPLOYER_SP_CLIENT_SECRET (hidden)"
      + (" + DEFAULT_TARGET_WORKSPACE_HOST" if os.environ.get("HOST") else ""))
PY
  ok "Deployer SP wired (secret from scope $DEPLOYER_SP_SECRET_SCOPE/$DEPLOYER_SP_SECRET_KEY; not shown)."
  info "Builds for projects with a target workspace set now run as the SP → dashboards work."
else
  warn "No deployer SP configured. AI/BI DASHBOARDS (and thus every initial_templates/* demo) will FAIL to build via the OBO token. Run setup-deployer-sp.sh, then re-run configure.sh with --deployer-sp-* flags. See references/scopes.md."
fi

step "Validating the bundle + resolved scopes"
( cd "$APP_DIR" && mkdir -p .build && touch .build/app.yml
  RESOLVED="$(dbx bundle validate -t prod -o json 2>/dev/null || true)"
  if [[ -n "$RESOLVED" ]]; then
    printf '%s' "$RESOLVED" | python3 -c 'import sys,json; d=json.load(sys.stdin); s=d["resources"]["apps"]["demo-prompt-generator-app"].get("user_api_scopes",[]); print("  Resolved user_api_scopes ("+str(len(s))+"):"); [print("    -",x) for x in s]' 2>/dev/null \
      || warn "Bundle validated but could not parse scopes — inspect databricks.prod.yml by hand."
    ok "Bundle is valid."
  else
    warn "Could not run bundle validate (that's OK; the deploy step will surface any error)."
  fi
)
hr
ok "Configuration written. Next: deploy."
info "The base catalog.* read scopes come from the committed databricks.yml; the ${#SB_BUILD_SCOPES[@]} build scopes above are appended by this prod overlay."
