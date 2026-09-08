#!/bin/bash
set -e

echo "Starting GitLab Runner registration script..."

# The host owns docker.sock. The image is built with the host docker GID, so
# validate access here without mutating the host socket from the container.
if [ -S /var/run/docker.sock ]; then
    echo "Docker socket found, validating runner access..."
    stat -Lc 'Docker socket owner=%u group=%g mode=%a' /var/run/docker.sock
    runuser --user gitlab-runner -- id
    # A Swarm bind-mounted Unix socket can report false for shell test -r/-w
    # even while the runner can use it. Probe the read-only Docker API instead.
    if ! runuser --user gitlab-runner -- \
        /usr/bin/docker version --format '{{.Server.Version}}' > /dev/null; then
        echo "Error: gitlab-runner cannot access /var/run/docker.sock."
        echo "Rebuild the runner image with HOST_DOCKER_GID matching the host docker group."
        exit 1
    fi
else
    echo "Error: Docker socket (/var/run/docker.sock) not found."
    echo "Please ensure you pass '-v /var/run/docker.sock:/var/run/docker.sock' when running this container."
    exit 1
fi

# Load from environment variables
gitlab_endpoint=${GITLAB_ENDPOINT:-http://gitlab}

runner_state="/runner-data/$HOSTNAME"
runner_home="$runner_state/home"
runner_tmp="$runner_state/tmp"
for tmpfs_dir in \
    /tmp \
    /etc/gitlab-runner \
    /data \
    /home/gitlab-runner/.docker; do
    if [ "$(stat -f -c %T "$tmpfs_dir")" != tmpfs ]; then
        echo "Error: $tmpfs_dir is not backed by tmpfs."
        exit 1
    fi
done

# Docker Stack does not consistently preserve Compose tmpfs modes. Set the
# effective permissions only after proving these paths are ephemeral mounts.
chmod 01777 /tmp
chmod 0700 /etc/gitlab-runner
chmod 0777 /data

for writable_dir in \
    /home/gitlab-runner/.docker \
    "$runner_state/builds" \
    "$runner_state/cache" \
    "$runner_home" \
    "$runner_tmp"; do
    mkdir -p "$writable_dir"
    chown gitlab-runner:gitlab-runner "$writable_dir"
    chmod 0700 "$writable_dir"
done

echo "Checking if GitLab server $gitlab_endpoint is reachable"
gitlab_ready=false
for attempt in $(seq 1 120); do
    if curl -fsS --max-time 10 "$gitlab_endpoint" > /dev/null; then
        gitlab_ready=true
        break
    fi

    if [ "$attempt" -eq 1 ] || [ $((attempt % 12)) -eq 0 ]; then
        echo "GitLab server is not reachable yet (attempt $attempt/120); retrying in 5 seconds..."
    fi
    sleep 5
done

if [ "$gitlab_ready" != true ]; then
    echo "GitLab server did not become reachable within 10 minutes. Exiting..."
    exit 1
fi
echo "GitLab server $gitlab_endpoint is reachable"

echo "Reading token from environment variable GITLAB_RUNNER_TOKEN ..."
token=${GITLAB_RUNNER_TOKEN:-}

# If token is empty, exit
if [ -z "$token" ]; then
    echo "No token provided."
    exit 1
fi

if [ -z "${REGISTRY_HOST:-}" ] || [ -z "${REGISTRY_VERIFICATION_IMAGE:-}" ] || \
   [ -z "${DOCKERHUB_USERNAME:-}" ] || [ -z "${DOCKERHUB_PASSWORD:-}" ]; then
    echo "Registry host, verification image, username, or password is missing."
    exit 1
fi

echo "Logging in to $REGISTRY_HOST as gitlab-runner..."
if ! printf '%s' "$DOCKERHUB_PASSWORD" | \
    sudo -H -u gitlab-runner docker login "$REGISTRY_HOST" \
        --username "$DOCKERHUB_USERNAME" \
        --password-stdin > /dev/null; then
    echo "Failed to log in to $REGISTRY_HOST."
    exit 1
fi

echo "Verifying access to $REGISTRY_HOST/$REGISTRY_VERIFICATION_IMAGE..."
if ! sudo -H -u gitlab-runner docker manifest inspect \
    "$REGISTRY_HOST/$REGISTRY_VERIFICATION_IMAGE" > /dev/null; then
    echo "Registry login succeeded, but the runner cannot read the verification image."
    exit 1
fi
echo "Registry access verified."

echo "Registering runner with name $HOSTNAME"
gitlab-runner register \
    --name "$HOSTNAME" \
    --non-interactive \
    --url "$gitlab_endpoint" \
    --token "$token" \
    --executor "shell" \
    --builds-dir "$runner_state/builds" \
    --cache-dir "$runner_state/cache" \
    --custom_build_dir-enabled=true \
    --env "HOME=$runner_home" \
    --env "TMPDIR=$runner_tmp" \
    --env "CARGO_HOME=$runner_home/.cargo" \
    --env "RUSTUP_HOME=/home/gitlab-runner/.rustup" \
    --env "DOCKER_CONFIG=/home/gitlab-runner/.docker" \
    --env "PATH=/home/gitlab-runner/.cargo/bin:$PATH" \
    --env "DOCKER_USERNAME=${DOCKER_USERNAME}" \
    --env "DOCKER_PASSWORD=${DOCKER_PASSWORD}" \
    --env "LOCAL_DOCKER_USERNAME=${DOCKERHUB_USERNAME}" \
    --env "LOCAL_DOCKER_PASSWORD=${DOCKERHUB_PASSWORD}" \
    --env "CN_DOCKER_USERNAME=${CN_DOCKER_USERNAME}" \
    --env "CN_DOCKER_PASSWORD=${CN_DOCKER_PASSWORD}" \
    --env "LOCAL_NUGET_API_KEY=${LOCAL_NUGET_API_KEY}" \
    --env "NUGET_API_KEY=${NUGET_API_KEY}" \
    --env "APKG_DEV_API_KEY=${APKG_DEV_API_KEY}" \
    --env "APKG_PROD_API_KEY=${APKG_PROD_API_KEY}"

echo "Ensuring global buildx builder for CI (as gitlab-runner)..."
BUILDER_NAME="aiur-global-builder"
echo "Current buildx builders visible to gitlab-runner:"
su -s /bin/bash gitlab-runner -c "docker buildx ls"
if ! su -s /bin/bash gitlab-runner -c "docker buildx ls" | grep -qw "$BUILDER_NAME"; then
    echo "Builder '$BUILDER_NAME' not found. Creating with docker-container driver and host networking..."
    su -s /bin/bash gitlab-runner -c "docker buildx create --name \"$BUILDER_NAME\" --driver docker-container --use --bootstrap"
    echo "Builder created and bootstrapped. Supported platforms:"
    su -s /bin/bash gitlab-runner -c "docker buildx inspect \"$BUILDER_NAME\" | grep Platforms"
else
    echo "Builder '$BUILDER_NAME' already exists. Setting as active..."
    su -s /bin/bash gitlab-runner -c "docker buildx use \"$BUILDER_NAME\""
    echo "Builder status:"
    su -s /bin/bash gitlab-runner -c "docker buildx inspect \"$BUILDER_NAME\"" | grep -E 'Status|Platforms'
fi

#gitlab-runner start
gitlab-runner run --user=gitlab-runner --working-directory=/home/gitlab-runner
