#!/usr/bin/env bash
# ============================================================================
# deploy.sh — build the app artifact, then deploy the bundle.
#
# IMPORTANT ordering: `databricks bundle deploy` validates sync.paths (which
# lists `.build`) BEFORE it runs the artifact build — so on a fresh clone the
# deploy fails with `stat .build: no such file or directory`. Running
# scripts/build.sh FIRST creates .build and breaks that chicken-and-egg.
#
# This step also CREATES the app's service principal (needed by grant-sp.sh).
#
# Usage: deploy.sh --app-dir <path/to/solution-builder/app> [--profile <p>]
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/lib.sh"

APP_DIR="$(pwd)"
while [[ $# -gt 0 ]]; do case "$1" in
  --app-dir) APP_DIR="$2"; shift 2 ;;
  --profile) SB_PROFILE="$2"; shift 2 ;;
  -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "Unknown arg: $1" ;;
esac; done
[[ -f "$APP_DIR/databricks.prod.yml" ]] || die "No databricks.prod.yml in $APP_DIR — run configure.sh first."
[[ -x "$APP_DIR/scripts/build.sh" ]] || die "No scripts/build.sh in $APP_DIR — is --app-dir the solution-builder/app dir?"

step "1/2  Building the app artifact (.build/)"
( cd "$APP_DIR" && ./scripts/build.sh --target prod ) || die "build.sh failed."
ok "Artifact built."

step "2/2  Deploying the bundle (prod target)"
( cd "$APP_DIR" && dbx bundle deploy -t prod ) || die "bundle deploy failed — see the error above."
ok "Deployed."
hr
info "The app is deployed but its compute may still be STOPPED — grant the SP, then launch it."
