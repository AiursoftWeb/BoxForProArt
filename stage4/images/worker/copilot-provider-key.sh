#!/usr/bin/env bash
# Invoked by the provider SDK; stdout is consumed as the credential, never logged.
set -euo pipefail
if [ -n "${COPILOT_PROVIDER_BEARER_TOKEN:-}" ]; then
    printf '%s' "$COPILOT_PROVIDER_BEARER_TOKEN"
elif [ -n "${COPILOT_PROVIDER_API_KEY:-}" ]; then
    printf '%s' "$COPILOT_PROVIDER_API_KEY"
else
    exec cat "$HOME/.config/cici/ollama-api-key"
fi
