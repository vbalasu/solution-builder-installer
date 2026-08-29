#!/usr/bin/env bash
# ============================================================================
# launch.sh — start the app (deploy its compute) and wait until it's RUNNING,
# then print the URL and the effective OBO scopes.
#
# `bundle run` targets the DAB RESOURCE key (demo-prompt-generator-app), which
# is fixed regardless of your chosen app name. It can take several minutes on a
# cold start (compute provision + package install).
#
# Usage: launch.sh --app-dir <path/to/solution-builder/app> \
#                  --app-name <deployed-app-name> [--profile <p>]
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/lib.sh"

APP_DIR="$(pwd)"; APP_NAME=""; RESOURCE_KEY="demo-prompt-generator-app"
while [[ $# -gt 0 ]]; do case "$1" in
  --app-dir) APP_DIR="$2"; shift 2 ;;
  --app-name) APP_NAME="$2"; shift 2 ;;
  --profile) SB_PROFILE="$2"; shift 2 ;;
  -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "Unknown arg: $1" ;;
esac; done
[[ -n "$APP_NAME" ]] || die "Need --app-name."

step "Starting the app (this can take a few minutes on a cold start)"
( cd "$APP_DIR" && dbx bundle run "$RESOURCE_KEY" -t prod ) || warn "bundle run returned non-zero — polling status anyway."

step "Waiting for RUNNING"
URL=""; STATE=""
for _ in $(seq 1 60); do
  J="$(dbx apps get "$APP_NAME" -o json 2>/dev/null || echo '{}')"
  STATE="$(printf '%s' "$J" | jget 'app_status.state')"
  URL="$(printf '%s' "$J" | jget 'url')"
  printf '\r  app_status: %-14s' "${STATE:-?}"
  [[ "$STATE" == "RUNNING" ]] && break
  sleep 8
done
printf '\n'
[[ "$STATE" == "RUNNING" ]] && ok "App is RUNNING." || warn "App state is '${STATE:-unknown}' — check the deploy logs in the workspace UI."

step "Effective OBO scopes on the app"
dbx apps get "$APP_NAME" -o json 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);[print("    -",s) for s in d.get("user_api_scopes",[])]' 2>/dev/null || true

hr
[[ -n "$URL" ]] && printf '%s\n' "${C_BOLD}${C_GREEN}App URL: ${URL}${C_RESET}"
info "One more step before builds work: open the URL and RE-AUTHORIZE (accept the consent prompt) so your token carries the new scopes."
