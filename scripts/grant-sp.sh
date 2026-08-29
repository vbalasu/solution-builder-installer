#!/usr/bin/env bash
# ============================================================================
# grant-sp.sh — give the app's service principal what it needs on Lakebase.
# Run AFTER deploy.sh (the SP only exists once the app has been created).
#
# Does two idempotent things:
#   1. Workspace grant: CAN_MANAGE on the Lakebase project (lets the app mint
#      OAuth DB credentials for the project).
#   2. Postgres role: a LAKEBASE_OAUTH_V1 role for the SP on the branch, with
#      DATABRICKS_SUPERUSER so the app can create its own database + tables on
#      first boot.
#
# Usage:
#   grant-sp.sh --app-name <deployed-app-name> \
#     --lakebase-project-id <slug> [--lakebase-branch-id production] \
#     [--profile <p>]
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/lib.sh"

APP_NAME=""; LB_PROJECT=""; LB_BRANCH="production"
while [[ $# -gt 0 ]]; do case "$1" in
  --app-name) APP_NAME="$2"; shift 2 ;;
  --lakebase-project-id) LB_PROJECT="$2"; shift 2 ;;
  --lakebase-branch-id) LB_BRANCH="$2"; shift 2 ;;
  --profile) SB_PROFILE="$2"; shift 2 ;;
  -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "Unknown arg: $1" ;;
esac; done
[[ -n "$APP_NAME" && -n "$LB_PROJECT" ]] || die "Need --app-name and --lakebase-project-id."

step "Resolving the app's service principal"
SP="$(dbx apps get "$APP_NAME" -o json 2>/dev/null | jget 'service_principal_client_id')"
[[ -n "$SP" && "$SP" != "None" ]] || die "Could not read service_principal_client_id for app '$APP_NAME'. Did deploy succeed?"
ok "App SP client id: $SP"

step "1/2  Grant CAN_MANAGE on Lakebase project '$LB_PROJECT'"
dbx api patch "/api/2.0/permissions/database-projects/$LB_PROJECT" --json "$(cat <<JSON
{"access_control_list":[{"service_principal_name":"$SP","permission_level":"CAN_MANAGE"}]}
JSON
)" >/dev/null 2>&1 && ok "Workspace grant applied." \
  || warn "Grant call returned non-zero — it may already be granted; verifying next."
GRANTED="$(dbx api get "/api/2.0/permissions/database-projects/$LB_PROJECT" -o json 2>/dev/null \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(any(a.get('service_principal_name')=='$SP' for a in d.get('access_control_list',[])))" 2>/dev/null || echo False)"
[[ "$GRANTED" == "True" ]] && ok "Confirmed: SP is on the project ACL." || warn "Could not confirm SP on ACL — check via the Lakebase UI."

step "2/2  Create/replace the SP's Postgres role on branch '$LB_BRANCH'"
dbx postgres create-role "projects/$LB_PROJECT/branches/$LB_BRANCH" \
  --role-id "$SP" --replace-existing \
  --json "$(cat <<JSON
{"spec":{"identity_type":"SERVICE_PRINCIPAL","postgres_role":"$SP","auth_method":"LAKEBASE_OAUTH_V1","membership_roles":["DATABRICKS_SUPERUSER"]}}
JSON
)" >/dev/null 2>&1 && ok "Postgres role ensured (superuser)." \
  || warn "create-role returned non-zero — the role may already exist, or the grant above already auto-provisioned it. Verify with: databricks postgres list-roles projects/$LB_PROJECT/branches/$LB_BRANCH"
hr
ok "Service principal is wired to Lakebase."
