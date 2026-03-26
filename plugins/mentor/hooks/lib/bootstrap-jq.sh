#!/usr/bin/env bash
# bootstrap-jq.sh — Auto-installs jq on first use if not already present.
# Source this file; it exports JQ pointing to a working jq binary.
# On failure, exits the calling script with 0 (never blocks prompts).
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/bootstrap-jq.sh" || exit 0

COACHING_DIR="${HOME}/.claude/coaching"
_JQ_BIN="${COACHING_DIR}/bin/jq"
_WARNED_FLAG="${COACHING_DIR}/.jq-missing-warned"

mkdir -p "${COACHING_DIR}/bin"

# ─── Already available ────────────────────────────────────────────────────────
JQ=$(command -v jq 2>/dev/null || true)
if [[ -z "$JQ" ]] && [[ -x "$_JQ_BIN" ]]; then
    JQ="$_JQ_BIN"
fi

# ─── Auto-download ────────────────────────────────────────────────────────────
if [[ -z "$JQ" ]] || [[ ! -x "$JQ" ]]; then
    # Detect OS and architecture
    _OS=""
    _ARCH=""
    case "$(uname -s 2>/dev/null)" in
        Linux)  _OS="linux" ;;
        Darwin) _OS="macos" ;;
    esac
    case "$(uname -m 2>/dev/null)" in
        x86_64)        _ARCH="amd64" ;;
        arm64|aarch64) _ARCH="arm64" ;;
    esac

    if [[ -n "$_OS" && -n "$_ARCH" ]]; then
        _JQ_URL="https://github.com/jqlang/jq/releases/latest/download/jq-${_OS}-${_ARCH}"
        _DOWNLOADED=false

        if command -v curl &>/dev/null; then
            curl -fsSL --max-time 15 "$_JQ_URL" -o "$_JQ_BIN" 2>/dev/null && _DOWNLOADED=true
        elif command -v wget &>/dev/null; then
            wget -qO "$_JQ_BIN" --timeout=15 "$_JQ_URL" 2>/dev/null && _DOWNLOADED=true
        fi

        if [[ "$_DOWNLOADED" == true ]] && [[ -s "$_JQ_BIN" ]]; then
            chmod +x "$_JQ_BIN"
            JQ="$_JQ_BIN"
            rm -f "$_WARNED_FLAG"
        fi
    fi
fi

# ─── Final check — warn once and exit if still missing ───────────────────────
if [[ -z "$JQ" ]] || [[ ! -x "$JQ" ]]; then
    if [[ ! -f "$_WARNED_FLAG" ]]; then
        echo "[mentor] Could not install jq automatically. Install curl or wget, or install jq manually." >&2
        touch "$_WARNED_FLAG" 2>/dev/null || true
    fi
    exit 0
fi

rm -f "$_WARNED_FLAG"
export JQ
