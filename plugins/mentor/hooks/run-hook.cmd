#!/usr/bin/env bash
# Cross-platform hook runner for mentor plugin
# Usage: run-hook.cmd <hook-name>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_NAME="${1:?Hook name required}"
HOOK_SCRIPT="${SCRIPT_DIR}/${HOOK_NAME}"

if [ -f "$HOOK_SCRIPT" ]; then
    exec bash "$HOOK_SCRIPT"
else
    echo "Hook not found: ${HOOK_NAME}" >&2
    exit 1
fi
