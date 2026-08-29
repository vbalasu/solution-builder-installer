#!/usr/bin/env bash
# ============================================================================
# setup-deployer-sp.sh — create (or reuse) the DEPLOYER service principal that
# the Solution Builder app uses to build demo resources.
#
# WHY THIS EXISTS (read references/scopes.md → "Why a deployer SP"):
# The build agent normally acts via the signed-in user's OBO token
# (x-forwarded-access-token), which is downscoped to the app's user_api_scopes.
# That vocabulary has NO way to grant the `dashboards` scope the Lakeview API
# requires — so the OBO path CANNOT create AI/BI dashboards, and every
# initial_templates/* demo builds one. The fix is a deployer SP whose OAuth-M2M
# credentials are NOT downscoped: when configured (+ a target_workspace_host),
# the app runs builds as this SP, so dashboards (and everything else) work.
#
# This script:
#   1. creates the SP (or reuses one with the same display name),
#   2. optionally adds it to the workspace `admins` group (simplest way to give
#      it the broad build privileges every template needs — see --grant),
#   3. mints an OAuth-M2M secret and stores it in a Databricks SECRET SCOPE
#      (the secret VALUE is never printed).
# It prints the CLIENT_ID + scope/key to pass to configure.sh. Idempotent-ish
# (re-running mints a fresh secret; delete stale ones in the UI).
#
# Usage:
#   setup-deployer-sp.sh --profile <p> [--sp-name solution-builder-deployer] \
#     [--secret-scope solution-builder] [--secret-key deployer-sp-client-secret] \
#     [--grant admin|none] [--lifetime 31536000s]
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/lib.sh"

SP_NAME="solution-builder-deployer"
SECRET_SCOPE="solution-builder"
SECRET_KEY="deployer-sp-client-secret"
GRANT="admin"
LIFETIME="31536000s"
while [[ $# -gt 0 ]]; do case "$1" in
  --profile) SB_PROFILE="$2"; shift 2 ;;
  --sp-name) SP_NAME="$2"; shift 2 ;;
  --secret-scope) SECRET_SCOPE="$2"; shift 2 ;;
  --secret-key) SECRET_KEY="$2"; shift 2 ;;
  --grant) GRANT="$2"; shift 2 ;;
  --lifetime) LIFETIME="$2"; shift 2 ;;
  -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "Unknown arg: $1" ;;
esac; done
need databricks "Install the Databricks CLI first."

step "Resolving the deployer service principal '$SP_NAME'"
# Reuse an existing SP with this display name if present, else create one.
SP_JSON="$(dbx service-principals list -o json 2>/dev/null || echo '[]')"
read -r SP_ID CLIENT_ID < <(SP_JSON="$SP_JSON" SP_NAME="$SP_NAME" python3 <<'PY'
import os, json
sps = json.loads(os.environ.get("SP_JSON","") or "[]")
name = os.environ["SP_NAME"]
for s in (sps if isinstance(sps, list) else sps.get("Resources", [])):
    if s.get("displayName") == name:
        print(s.get("id",""), s.get("applicationId",""))
        break
else:
    print("", "")
PY
)
if [[ -z "${SP_ID:-}" ]]; then
  CREATE="$(dbx service-principals create --display-name "$SP_NAME" -o json 2>/dev/null)"
  SP_ID="$(printf '%s' "$CREATE" | jget 'id')"
  CLIENT_ID="$(printf '%s' "$CREATE" | jget 'applicationId')"
  [[ -n "$SP_ID" && -n "$CLIENT_ID" ]] || die "Failed to create service principal '$SP_NAME'."
  ok "Created SP: id=$SP_ID client_id=$CLIENT_ID"
else
  ok "Reusing existing SP: id=$SP_ID client_id=$CLIENT_ID"
fi

if [[ "$GRANT" == "admin" ]]; then
  step "Granting workspace admin (adds SP to the 'admins' group)"
  ADMINS_ID="$(dbx groups list -o json 2>/dev/null | SP_ID="$SP_ID" python3 -c '
import sys, json, os
gs = json.load(sys.stdin)
for g in (gs if isinstance(gs, list) else gs.get("Resources", [])):
    if g.get("displayName") == "admins":
        print(g.get("id","")); break
' 2>/dev/null)"
  if [[ -n "$ADMINS_ID" ]]; then
    dbx groups patch "$ADMINS_ID" --json "{\"schemas\":[\"urn:ietf:params:scim:api:messages:2.0:PatchOp\"],\"Operations\":[{\"op\":\"add\",\"path\":\"members\",\"value\":[{\"value\":\"$SP_ID\"}]}]}" >/dev/null 2>&1 \
      && ok "SP added to admins." || warn "Could not add to admins (may already be a member)."
  else
    warn "Could not find the 'admins' group id — grant build privileges manually."
  fi
else
  warn "Skipping admin grant (--grant none). Ensure the SP has the privileges every template needs (warehouse CAN_USE, UC create, dashboards, genie, pipelines/jobs, serving, vector search, apps, lakebase)."
fi

step "Minting an OAuth-M2M secret + storing it in scope '$SECRET_SCOPE'"
SECRET="$(dbx service-principal-secrets-proxy create "$SP_ID" --lifetime "$LIFETIME" -o json 2>/dev/null | jget 'secret')"
[[ -n "${SECRET:-}" ]] || SECRET="$(dbx service-principal-secrets-proxy create "$SP_ID" -o json 2>/dev/null | jget 'secret')"
[[ -n "${SECRET:-}" ]] || die "Failed to mint an OAuth secret for the SP."
dbx secrets create-scope "$SECRET_SCOPE" >/dev/null 2>&1 || true
# Pass the secret via env (never on the command line / never printed).
SB_SECRET_VALUE="$SECRET" bash -c 'databricks secrets put-secret "$0" "$1" --string-value "$SB_SECRET_VALUE" '"${SB_PROFILE:+--profile $SB_PROFILE}"'' "$SECRET_SCOPE" "$SECRET_KEY" >/dev/null 2>&1 \
  && ok "Secret stored: scope=$SECRET_SCOPE key=$SECRET_KEY (value not shown)" \
  || die "Failed to store the secret in scope '$SECRET_SCOPE'."

hr
ok "Deployer SP ready. Pass these to configure.sh:"
say "    --deployer-sp-client-id $CLIENT_ID"
say "    --deployer-sp-secret-scope $SECRET_SCOPE --deployer-sp-secret-key $SECRET_KEY"
say "    --default-target-workspace-host https://<this-workspace-host>"
info "The secret VALUE stays in the scope. configure.sh reads it from there at"
info "generate time and writes it into the gitignored databricks.prod.yml as the"
info "DEPLOYER_SP_CLIENT_SECRET app env var (Databricks Apps deliver SP creds via"
info "env). It is never committed. Rotate by re-running this script."
