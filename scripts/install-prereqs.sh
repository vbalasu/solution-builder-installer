#!/usr/bin/env bash
# ============================================================================
# install-prereqs.sh — detect and (optionally) install the LOCAL tools the
# installer needs: git, Databricks CLI, uv, bun, python3 (+ 3.12 for local
# data-gen), and jq.
#
# Default = REPORT ONLY (no changes): prints what's missing + the exact command
# it would run. Pass --install to actually install the missing ones.
#
#   install-prereqs.sh                 # report only (safe)
#   install-prereqs.sh --install       # install everything missing
#   install-prereqs.sh --install --only databricks   # just one tool
#
# Strategy: on macOS with Homebrew (and Linuxbrew) everything installs via brew
# — no sudo, already on PATH. Otherwise it uses the official per-tool installers
# (uv/bun → no sudo, into ~/.local/bin and ~/.bun/bin) and the system package
# manager for git/jq/python (may need sudo — those are printed for you to run
# with a leading `!` if non-interactive).
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/lib.sh"

EXECUTE=0; ONLY=""
while [[ $# -gt 0 ]]; do case "$1" in
  --install|-y|--yes) EXECUTE=1; shift ;;
  --only) ONLY="$2"; shift 2 ;;
  -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "Unknown arg: $1" ;;
esac; done

OS="$(detect_os)"; PM="$(detect_pm)"
step "Platform: $OS   package manager: $PM"
if [[ "$OS" == "macos" && "$PM" != "brew" ]]; then
  warn "Homebrew not found. It's the smoothest way to install these on macOS."
  say  "  Install it first (interactive — run yourself):"
  say  '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  say  "  Then re-run this script."
fi

# resolve_cmd <tool> -> echoes the install command for this platform ("" = manual)
resolve_cmd() {
  case "$1:$PM" in
    git:brew)        echo "brew install git" ;;
    git:apt-get)     echo "sudo apt-get update && sudo apt-get install -y git" ;;
    git:dnf|git:yum) echo "sudo ${PM} install -y git" ;;
    git:pacman)      echo "sudo pacman -S --noconfirm git" ;;
    git:zypper)      echo "sudo zypper install -y git" ;;

    jq:brew)         echo "brew install jq" ;;
    jq:apt-get)      echo "sudo apt-get update && sudo apt-get install -y jq" ;;
    jq:dnf|jq:yum)   echo "sudo ${PM} install -y jq" ;;
    jq:pacman)       echo "sudo pacman -S --noconfirm jq" ;;
    jq:zypper)       echo "sudo zypper install -y jq" ;;

    databricks:brew) echo "brew tap databricks/tap && brew install databricks" ;;
    databricks:*)    echo "curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh" ;;

    uv:brew)         echo "brew install uv" ;;
    uv:*)            echo "curl -LsSf https://astral.sh/uv/install.sh | sh" ;;

    bun:brew)        echo "brew install oven-sh/bun/bun" ;;
    bun:*)           echo "curl -fsSL https://bun.sh/install | bash" ;;

    python3:brew)          echo "brew install python@3.12" ;;
    python3:apt-get)       echo "sudo apt-get update && sudo apt-get install -y python3 python3-venv" ;;
    python3:dnf|python3:yum) echo "sudo ${PM} install -y python3" ;;
    python3:pacman)        echo "sudo pacman -S --noconfirm python" ;;
    python3:zypper)        echo "sudo zypper install -y python3" ;;
    *) echo "" ;;
  esac
}

MISSING=0; INSTALLED=0
handle() { # handle <tool> <present?0|1> <manual-url>
  local tool="$1" present="$2" url="${3:-}"
  [[ -n "$ONLY" && "$ONLY" != "$tool" ]] && return 0
  if [[ "$present" == "1" ]]; then ok "$tool — present"; return 0; fi
  MISSING=$((MISSING+1))
  local cmd; cmd="$(resolve_cmd "$tool")"
  if [[ -z "$cmd" ]]; then
    warn "$tool — MISSING. Install manually: ${url:-see its docs}"
    return 0
  fi
  if [[ "$EXECUTE" == "1" ]]; then
    say "  ${C_CYAN}installing $tool:${C_RESET} $cmd"
    if bash -c "$cmd"; then
      sb_augment_path
      ok "$tool — installed"; INSTALLED=$((INSTALLED+1))
    else
      err "$tool — install command failed. Run it yourself (prefix with a bang if sudo is needed):"
      say "    $cmd"
    fi
  else
    warn "$tool — MISSING. Would run:  $cmd"
  fi
}

step "Checking tools"
handle git        "$(have git        && echo 1 || echo 0)" "https://git-scm.com/"
handle databricks "$(have databricks && echo 1 || echo 0)" "https://docs.databricks.com/dev-tools/cli/"
handle uv         "$(have uv         && echo 1 || echo 0)" "https://docs.astral.sh/uv/"
handle bun        "$(have bun        && echo 1 || echo 0)" "https://bun.sh/"
handle python3    "$(have python3    && echo 1 || echo 0)" "https://python.org/"
handle jq         "$(have jq         && echo 1 || echo 0)" "https://jqlang.github.io/jq/"

# Python 3.12 specifically — only needed for LOCAL data-gen (deployed app runs
# 3.12 in its own container). Preferred route: uv can install it, no sudo.
if [[ -z "$ONLY" || "$ONLY" == "python3.12" ]]; then
  if have python3.12 || python3 -c 'import sys; sys.exit(0 if sys.version_info[:2]==(3,12) else 1)' 2>/dev/null; then
    ok "python3.12 — available"
  else
    warn "python3.12 — not the active python. Optional (only for running data-gen locally)."
    if have uv; then
      if [[ "$EXECUTE" == "1" ]]; then
        say "  ${C_CYAN}installing python3.12 via uv:${C_RESET} uv python install 3.12"
        uv python install 3.12 && ok "python3.12 — installed via uv" || warn "uv python install 3.12 failed — install manually if you need local data-gen."
      else
        warn "  Would run:  uv python install 3.12   (via uv, no sudo)"
      fi
    else
      info "Install uv first, then: uv python install 3.12"
    fi
  fi
fi

hr
if [[ "$MISSING" == "0" ]]; then
  ok "All required tools present."
elif [[ "$EXECUTE" == "1" ]]; then
  ok "Installed $INSTALLED tool(s). Re-run preflight.sh to confirm."
  warn "If you installed uv/bun via the official installer, open a NEW terminal (or add \$HOME/.local/bin and \$HOME/.bun/bin to PATH) so they're found."
else
  warn "$MISSING tool(s) missing. Re-run with --install to install them (or run the printed commands yourself)."
fi
