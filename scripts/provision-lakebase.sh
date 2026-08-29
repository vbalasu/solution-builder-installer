#!/usr/bin/env bash
# ============================================================================
# provision-lakebase.sh — ensure a Lakebase (Postgres) project exists and
# print the three config values the app needs. Idempotent.
#
# Creating a project with an empty spec applies sane defaults: a default branch
# named `production` and the always-present `databricks_postgres` maintenance
# database (so NO `CREATE DATABASE` step is needed). We then DISCOVER the real
# branch/database names rather than assuming, so this keeps working if the
# platform defaults ever change.
#
# Usage:
#   provision-lakebase.sh --project-id <slug> [--profile <p>]     # create if missing, else reuse
#   provision-lakebase.sh --use-existing <slug> [--profile <p>]   # reuse only (error if absent)
#
# On success prints (last lines, KEY=VALUE — easy to capture):
#   LAKEBASE_PROJECT_ID=<slug>
#   LAKEBASE_BRANCH_ID=<branch>
#   LAKEBASE_DATABASE_NAME=<db>
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/lib.sh"

PROJECT_ID=""; MODE="ensure"
while [[ $# -gt 0 ]]; do case "$1" in
  --project-id)   PROJECT_ID="$2"; MODE="ensure";   shift 2 ;;
  --use-existing) PROJECT_ID="$2"; MODE="existing"; shift 2 ;;
  --profile)      SB_PROFILE="$2"; shift 2 ;;
  -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "Unknown arg: $1" ;;
esac; done
[[ -n "$PROJECT_ID" ]] || die "Provide --project-id <slug> or --use-existing <slug>."

exists() { dbx postgres get-project "projects/$PROJECT_ID" -o json >/dev/null 2>&1; }

if exists; then
  ok "Lakebase project '$PROJECT_ID' already exists — reusing it."
elif [[ "$MODE" == "existing" ]]; then
  die "Lakebase project '$PROJECT_ID' not found (and --use-existing was set)."
else
  step "Creating Lakebase project '$PROJECT_ID' (defaults: pg17, autoscaling)"
  dbx postgres create-project "$PROJECT_ID" --json '{}' >/dev/null \
    || die "create-project failed. Check Lakebase quota / entitlement in this workspace."
  # Wait for the default branch to resolve.
  for _ in $(seq 1 40); do
    exists && [[ -n "$(dbx postgres get-project "projects/$PROJECT_ID" -o json 2>/dev/null | jget 'status.default_branch')" ]] && break
    sleep 6
  done
  ok "Project created."
fi

step "Discovering branch + database"
BRANCH_ID="$(dbx postgres list-branches "projects/$PROJECT_ID" -o json 2>/dev/null \
  | python3 -c 'import sys,json; b=json.load(sys.stdin); d=[x for x in b if x.get("status",{}).get("default")]; print((d or b)[0]["branch_id"])' 2>/dev/null || true)"
[[ -n "$BRANCH_ID" ]] || die "Could not find a branch on project '$PROJECT_ID'."
ok "Branch: $BRANCH_ID"

DB_NAME="$(dbx postgres list-databases "projects/$PROJECT_ID/branches/$BRANCH_ID" -o json 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); pg=[x.get("status",{}).get("postgres_database") for x in d]; print("databricks_postgres" if "databricks_postgres" in pg else (pg[0] if pg else "databricks_postgres"))' 2>/dev/null || echo databricks_postgres)"
ok "Database: $DB_NAME"

hr
say "LAKEBASE_PROJECT_ID=$PROJECT_ID"
say "LAKEBASE_BRANCH_ID=$BRANCH_ID"
say "LAKEBASE_DATABASE_NAME=$DB_NAME"
