#!/usr/bin/env bash
# ============================================================================
# log-install.sh — emit a tiny install-telemetry record AS EARLY AS POSSIBLE.
#
# Gathers the workspace URL, workspace ID, account ID, and signed-in user email
# (each best-effort — "if available"), writes them to a simple YAML file, and
# ships that YAML to the shared logger (github.com/vbalasu/logger): stdin is
# uploaded to the public `default-logger` S3 bucket via curl+bash (no AWS creds),
# under logger/solution-builder-installer/<workspace-slug>-<user>-<date>.yml.
#
# This is INTENTIONALLY non-fatal: any lookup or the upload failing must never
# block an install. It runs right after `databricks auth login`, before
# preflight/config.
#
# Usage: log-install.sh [--profile <cli-profile>] [--out <yaml-path>] [--no-upload]
# ============================================================================
set -uo pipefail   # NOT -e: this script must never abort the install
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/lib.sh"

OUT=""; UPLOAD=1
LOGGER_URL="https://default-logger.s3.us-east-1.amazonaws.com/public/logger.sh"
LOGGER_SUBFOLDER="solution-builder-installer"
while [[ $# -gt 0 ]]; do case "$1" in
  --profile)   SB_PROFILE="$2"; shift 2 ;;
  --out)       OUT="$2"; shift 2 ;;
  --no-upload) UPLOAD=0; shift ;;
  -h|--help)   sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "Unknown arg: $1" ;;
esac; done

have databricks || { warn "databricks CLI not found — skipping install logging."; exit 0; }

step "Logging install context (workspace URL / IDs / user)"

# ---- user email ------------------------------------------------------------
ME_JSON="$(dbx current-user me -o json 2>/dev/null || true)"
USER_EMAIL="$(printf '%s' "$ME_JSON" | jget 'userName')"

# ---- workspace URL (host) --------------------------------------------------
HOST="$(dbx auth env 2>/dev/null | sed -n 's/.*DATABRICKS_HOST=\([^ ]*\).*/\1/p' | head -1)"
[[ -n "$HOST" ]] || HOST="$(printf '%s' "$ME_JSON" | jget 'active.host')"
HOST="${HOST%/}"

# ---- workspace ID (org id) -------------------------------------------------
# The workspace/org id isn't in `current-user me`; it comes back as the
# X-Databricks-Org-Id response header on any workspace API call. Grab a token
# from the CLI and read the header via a cheap GET.
WORKSPACE_ID=""
if [[ -n "$HOST" ]]; then
  TOKEN="$(dbx auth token -o json 2>/dev/null | jget 'access_token')"
  if [[ -n "$TOKEN" ]] && have curl; then
    WORKSPACE_ID="$(curl -sS -o /dev/null -D - \
      -H "Authorization: Bearer $TOKEN" \
      "$HOST/api/2.0/clusters/spark-versions" 2>/dev/null \
      | tr -d '\r' | awk 'tolower($1)=="x-databricks-org-id:"{print $2}' | head -1)"
  fi
fi

# ---- account ID (best-effort) ----------------------------------------------
# Only present for account-level / configured profiles; blank on a plain
# workspace OAuth login. Check the CLI env then the config file.
ACCOUNT_ID="$(dbx auth env 2>/dev/null | sed -n 's/.*DATABRICKS_ACCOUNT_ID=\([^ ]*\).*/\1/p' | head -1)"
if [[ -z "$ACCOUNT_ID" && -f "$HOME/.databrickscfg" && -n "${SB_PROFILE:-}" ]]; then
  ACCOUNT_ID="$(awk -v p="[$SB_PROFILE]" '
    $0==p{f=1;next} /^\[/{f=0}
    f && $1=="account_id"{print $3; exit}' "$HOME/.databrickscfg" 2>/dev/null)"
fi

# ---- write the YAML --------------------------------------------------------
[[ -n "$OUT" ]] || OUT="$(mktemp -t sb-install-XXXXXX).yml"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  echo "solution_builder_install:"
  echo "  timestamp: \"$TS\""
  echo "  workspace_url: \"${HOST:-}\""
  echo "  workspace_id: \"${WORKSPACE_ID:-}\""
  echo "  account_id: \"${ACCOUNT_ID:-}\""
  echo "  user_email: \"${USER_EMAIL:-}\""
} > "$OUT"

ok  "Wrote install context: $OUT"
info "  workspace_url: ${HOST:-<unknown>}"
info "  workspace_id:  ${WORKSPACE_ID:-<unknown>}"
info "  account_id:    ${ACCOUNT_ID:-<unknown>}"
info "  user_email:    ${USER_EMAIL:-<unknown>}"

# ---- ship it to the logger -------------------------------------------------
# The logger stores objects at logger/<subfolder>/<name>. We use the
# "solution-builder-installer" subfolder and a friendly, legible-at-a-glance
# filename: workspace slug + user handle + a short date stamp (not a bare
# timestamp). The full ISO timestamp still lives inside the YAML body.
slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//'; }
WS_SLUG="$(slug "${HOST#https://}")"; WS_SLUG="${WS_SLUG%%-cloud-databricks-com*}"
USER_SLUG="$(slug "${USER_EMAIL%@*}")"
DATE_STAMP="$(date -u +%Y%m%d-%H%M%S)"
OBJ_NAME="${WS_SLUG:-workspace}-${USER_SLUG:-user}-${DATE_STAMP}.yml"
if [[ "$UPLOAD" -eq 1 ]]; then
  if have curl && have bash; then
    if bash <(curl -sS "$LOGGER_URL") -n "$OBJ_NAME" -s "$LOGGER_SUBFOLDER" < "$OUT" >/dev/null 2>&1; then
      ok "Logged install context to the shared logger (logger/$LOGGER_SUBFOLDER/$OBJ_NAME)."
    else
      warn "Logger upload failed (non-fatal) — install continues."
    fi
  else
    warn "curl/bash unavailable — skipped logger upload (non-fatal)."
  fi
fi

exit 0
