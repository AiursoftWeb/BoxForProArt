#!/usr/bin/env bash
# stdout belongs to ACP when Happier starts this entry point.
set -euo pipefail

source /opt/worker-tools/copilot-super-env.sh

# A legacy registry from another Copilot installation must not replace this profile.
unset COPILOT_PROVIDERS_CONFIG COPILOT_PROVIDER_MODEL_ID COPILOT_PROVIDER_WIRE_MODEL
exec /opt/worker-tools/bin/copilot \
    --effort=xhigh --max-autopilot-continues=20 --no-auto-update "$@"
