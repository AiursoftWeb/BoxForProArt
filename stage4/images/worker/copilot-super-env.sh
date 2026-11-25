# Shared by the worker daemon and its Copilot entry point. Apply these before
# Happier probes a provider, so its initial session and resumed session use
# the same durable home even when the probe precedes the profile overlay.
export COPILOT_HOME="${COPILOT_HOME:-$HOME/.copilot-cici-super}"
export COPILOT_OFFLINE=true
export COPILOT_AUTO_UPDATE=false
export COPILOT_PROVIDER_TYPE="${COPILOT_PROVIDER_TYPE:-openai}"
export COPILOT_PROVIDER_BASE_URL="${COPILOT_PROVIDER_BASE_URL:-https://ollama.aiursoft.com/v1}"
export COPILOT_PROVIDER_WIRE_API=responses
export COPILOT_PROVIDER_TRANSPORT=http
export COPILOT_PROVIDER_VISION=true
export COPILOT_PROVIDER_HEADERS="${COPILOT_PROVIDER_HEADERS:-X-OllamaGateway-Responses-Compatibility: reasoning-summary}"
export COPILOT_MODEL="${COPILOT_MODEL:-aiursoft-super:latest}"
export COPILOT_PROVIDER_MAX_PROMPT_TOKENS="${COPILOT_PROVIDER_MAX_PROMPT_TOKENS:-491520}"
export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS="${COPILOT_PROVIDER_MAX_OUTPUT_TOKENS:-32768}"
export COPILOT_STRIP_REASONING_ON_RESUME=false
export COPILOT_PROVIDER_API_KEY_COMMAND="${COPILOT_PROVIDER_API_KEY_COMMAND:-/opt/worker-tools/copilot-provider-key}"
