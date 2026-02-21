#!/bin/bash

REAL_DOCKER="/usr/bin/docker"

# Determine host gateway IP dynamically; fallback to default bridge IP
HOST_IP=$(ip route show | grep default | awk '{print $3}')
if [ -z "$HOST_IP" ]; then
    HOST_IP="172.17.0.1"
fi

# Target domains to inject
TARGET_DOMAINS=(
    "nuget.aiursoft.com"
    "hub.aiursoft.com"
    "npm.aiursoft.com"
    "mirror.aiursoft.com"
)

# Build arguments array
ADD_HOST_ARGS=()
for domain in "${TARGET_DOMAINS[@]}"; do
    ADD_HOST_ARGS+=(--add-host "$domain:$HOST_IP")
done

if [[ "$1" == "build" ]]; then
    shift
    exec "$REAL_DOCKER" build --network=host "${ADD_HOST_ARGS[@]}" "$@"
elif [[ "$1" == "buildx" && "$2" == "build" ]]; then
    shift 2
    exec "$REAL_DOCKER" buildx build --network=host "${ADD_HOST_ARGS[@]}" "$@"
else
    # Pass through other commands
    exec "$REAL_DOCKER" "$@"
fi
