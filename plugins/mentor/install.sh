#!/usr/bin/env bash
# install.sh — Mentor plugin setup for Linux and macOS
#
# What this does:
#   1. Creates ~/.claude/coaching/ directory structure
#   2. Locates or downloads a static jq binary
#   3. Seeds default config files if missing
#   4. Clears any stale warning flags
#
# Usage:
#   bash install.sh
#
# Requirements:
#   curl or wget (for jq download if not already installed)

set -euo pipefail

COACHING_DIR="${HOME}/.claude/coaching"
BIN_DIR="${COACHING_DIR}/bin"
JQ_BIN="${BIN_DIR}/jq"
WARNED_FLAG="${COACHING_DIR}/.jq-missing-warned"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULTS_DIR="${SCRIPT_DIR}/defaults"

# ─── Colours (suppressed if not a terminal) ────────────────────────────────
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; RESET=''
fi

info()    { echo -e "${GREEN}[mentor]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[mentor]${RESET} $*"; }
error()   { echo -e "${RED}[mentor]${RESET} $*" >&2; }

# ─── Step 1: Create directory structure ────────────────────────────────────
info "Creating ${COACHING_DIR} ..."
mkdir -p "$BIN_DIR"

# ─── Step 2: Locate or download jq ─────────────────────────────────────────
locate_jq() {
    # Prefer system jq if available
    if command -v jq &>/dev/null; then
        command -v jq
        return 0
    fi
    # Fall back to previously downloaded binary
    if [[ -x "$JQ_BIN" ]]; then
        echo "$JQ_BIN"
        return 0
    fi
    return 1
}

download_jq() {
    # Normalise OS
    local os arch jq_url
    case "$(uname -s)" in
        Linux)  os="linux" ;;
        Darwin) os="macos" ;;
        *)
            error "Unsupported OS: $(uname -s)"
            error "Install jq manually: https://jqlang.github.io/jq/download/"
            return 1
            ;;
    esac

    # Normalise architecture
    case "$(uname -m)" in
        x86_64)        arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
        *)
            error "Unsupported architecture: $(uname -m)"
            error "Install jq manually: https://jqlang.github.io/jq/download/"
            return 1
            ;;
    esac

    jq_url="https://github.com/jqlang/jq/releases/latest/download/jq-${os}-${arch}"
    info "Downloading jq from ${jq_url} ..."

    if command -v curl &>/dev/null; then
        curl -fsSL "$jq_url" -o "$JQ_BIN" || { error "curl download failed"; return 1; }
    elif command -v wget &>/dev/null; then
        wget -qO "$JQ_BIN" "$jq_url" || { error "wget download failed"; return 1; }
    else
        error "Neither curl nor wget found — cannot download jq"
        error "Install one of: curl, wget, jq"
        return 1
    fi

    chmod +x "$JQ_BIN"
}

if JQ_PATH=$(locate_jq); then
    info "Found jq at: ${JQ_PATH}"
else
    warn "jq not found — downloading static binary ..."
    if download_jq; then
        info "jq installed at: ${JQ_BIN}"
    else
        error "Failed to install jq. Coaching hooks will not fire until jq is available."
        error "Install jq manually and re-run install.sh, or place a jq binary at:"
        error "  ${JQ_BIN}"
        exit 1
    fi
fi

# ─── Step 3: Verify jq works ────────────────────────────────────────────────
JQ=$(locate_jq)
if ! echo '{"ok":true}' | "$JQ" -e '.ok' &>/dev/null; then
    error "jq binary at ${JQ} does not work correctly"
    exit 1
fi
info "jq verified OK"

# ─── Step 4: Seed default files if missing ──────────────────────────────────
PHILOSOPHY_FILE="${COACHING_DIR}/philosophy.md"
USER_MODEL_FILE="${COACHING_DIR}/user-model.json"
CONFIG_FILE="${COACHING_DIR}/config.json"

if [[ ! -f "$PHILOSOPHY_FILE" ]] && [[ -f "${DEFAULTS_DIR}/philosophy.md" ]]; then
    cp "${DEFAULTS_DIR}/philosophy.md" "$PHILOSOPHY_FILE"
    info "Seeded philosophy.md from defaults"
fi

if [[ ! -f "$USER_MODEL_FILE" ]]; then
    printf '{"strengths":[],"weaknesses":[],"current_focus":"","recent_progress":"","intervention_history":[]}\n' \
        > "$USER_MODEL_FILE"
    info "Created empty user-model.json"
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    printf '{"enabled":true,"mode":"chill","bootstrap_min":20}\n' > "$CONFIG_FILE"
    info "Created default config.json"
fi

# ─── Step 5: Clear stale warning flags ──────────────────────────────────────
rm -f "$WARNED_FLAG"

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
info "Mentor plugin installed successfully."
info ""
info "Next steps:"
info "  1. Set your API key: export MENTOR_API_KEY=sk-ant-..."
info "     (add to ~/.bashrc or ~/.zshrc to persist)"
info "  2. Reload Claude Code plugins: /reload-plugins"
info "  3. Check status: /mentor status"
