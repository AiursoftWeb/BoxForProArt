#!/bin/bash
set -e

echo "Starting GitLab Runner registration script..."

# Make sure the docker.sock has correct permissions
if [ -S /var/run/docker.sock ]; then
    echo "Docker socket found, adjusting permissions..."
    # We need that socket to create new job containers
    chown root:docker /var/run/docker.sock || true
    chmod 660 /var/run/docker.sock
else
    echo "Error: Docker socket (/var/run/docker.sock) not found."
    echo "Please ensure you pass '-v /var/run/docker.sock:/var/run/docker.sock' when running this container."
    exit 1
fi

# Load from environment variables
gitlab_endpoint=${GITLAB_ENDPOINT:-http://gitlab}

echo "Checking if GitLab server $gitlab_endpoint is reachable"
if ! curl -s --max-time 10 $gitlab_endpoint > /dev/null; then
    echo "GitLab server is not reachable. Exiting..."
    exit 1
fi
echo "GitLab server: $gitlab_endpoint is reachable"

echo "Reading token from environment variable GITLAB_RUNNER_TOKEN ..."
token=$(echo $GITLAB_RUNNER_TOKEN)

# If token is empty, exit
if [ -z "$token" ]; then
    echo "No token provided."
    exit 1
fi

echo "Registering runner with token $token with name $HOSTNAME"
gitlab-runner register \
    --name "$HOSTNAME" \
    --non-interactive \
    --url "$gitlab_endpoint" \
    --token "$token" \
    --executor "shell" \
    --custom_build_dir-enabled=true \
    --env "DOCKER_USERNAME=${DOCKER_USERNAME}" \
    --env "DOCKER_PASSWORD=${DOCKER_PASSWORD}" \
    --env "LOCAL_DOCKER_USERNAME=${LOCAL_DOCKER_USERNAME}" \
    --env "LOCAL_DOCKER_PASSWORD=${LOCAL_DOCKER_PASSWORD}" \
    --env "CN_DOCKER_USERNAME=${CN_DOCKER_USERNAME}" \
    --env "CN_DOCKER_PASSWORD=${CN_DOCKER_PASSWORD}" \
    --env "LOCAL_NUGET_API_KEY=${LOCAL_NUGET_API_KEY}" \
    --env "NUGET_API_KEY=${NUGET_API_KEY}"

echo "Ensuring global buildx builder for CI (as gitlab-runner)..."
BUILDER_NAME="aiur-global-builder"
echo "Current buildx builders visible to gitlab-runner:"
su -s /bin/bash gitlab-runner -c "docker buildx ls"
if ! su -s /bin/bash gitlab-runner -c "docker buildx ls" | grep -qw "$BUILDER_NAME"; then
    echo "Builder '$BUILDER_NAME' not found. Creating with docker-container driver and host networking..."
    su -s /bin/bash gitlab-runner -c "docker buildx create --name \"$BUILDER_NAME\" --driver docker-container --driver-opt network=host --use --bootstrap"
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
