#!/bin/bash
set -e

echo "Starting GitLab Runner registration script..."

# Validate access without changing the host-owned Docker socket.
if [ -S /var/run/docker.sock ]; then
    echo "Docker socket found, validating runner access..."
    if ! runuser --user gitlab-runner -- \
        /usr/bin/docker version --format '{{.Server.Version}}' > /dev/null; then
        echo "Error: gitlab-runner cannot access /var/run/docker.sock."
        echo "The runner image's docker group must match the host docker group."
        exit 1
    fi
else
    echo "Error: Docker socket (/var/run/docker.sock) not found."
    echo "Please ensure you pass '-v /var/run/docker.sock:/var/run/docker.sock' when running this container."
    exit 1
fi

# Swarm does not expose cpuset in its service resource specification. Identify
# this exact task, then constrain it before registration or accepting any jobs.
: "${CI_TASK_ID:?Swarm task ID is required}"
: "${CI_CPUSET:?The shared CI CPU set is required}"
ci_cpuset=$(python3 - <<'PYCPU'
import os
import re

value = os.environ["CI_CPUSET"]
if not re.fullmatch(r"[0-9]+(?:-[0-9]+)?(?:,[0-9]+(?:-[0-9]+)?)*", value):
    raise SystemExit("CI_CPUSET must be a CPU list or range")
cpus = set()
for part in value.split(","):
    bounds = [int(cpu) for cpu in part.split("-")]
    first, last = bounds[0], bounds[-1]
    if not 0 <= last - first < 14:
        raise SystemExit("Each CI CPU range must contain between 1 and 14 CPUs")
    cpus.update(range(first, last + 1))
if len(cpus) != 14:
    raise SystemExit("The shared CI CPU set must contain exactly 14 CPUs")
print(",".join(str(cpu) for cpu in sorted(cpus)))
PYCPU
)
runner_ids=$(/usr/bin/docker ps --quiet --no-trunc \
    --filter "label=com.docker.swarm.task.id=$CI_TASK_ID")
mapfile -t runner_containers <<< "$runner_ids"
if [ "${#runner_containers[@]}" -ne 1 ] || [ -z "$runner_ids" ] || \
   [ "$(/usr/bin/docker inspect --format '{{ index .Config.Labels "com.docker.swarm.task.id" }}' "$runner_ids")" != "$CI_TASK_ID" ]; then
    echo "Error: cannot uniquely identify this Swarm task's container."
    exit 1
fi
/usr/bin/docker update --cpuset-cpus "$ci_cpuset" "$runner_ids"
if [ "$(/usr/bin/docker inspect --format '{{.HostConfig.CpusetCpus}} {{.HostConfig.NanoCpus}}' "$runner_ids")" != "$ci_cpuset 6000000000" ]; then
    echo "Error: runner must use the shared CPU set and its six-CPU quota."
    exit 1
fi
python3 - "$ci_cpuset" <<'PYCPU'
import os
import sys

if os.sched_getaffinity(0) != {int(cpu) for cpu in sys.argv[1].split(",")}:
    raise SystemExit("The runner's effective CPU affinity does not match the CI pool")
PYCPU

# Load from environment variables
gitlab_endpoint=${GITLAB_ENDPOINT:-http://gitlab}

mkdir -p "/runner-data/$HOSTNAME/builds" "/runner-data/$HOSTNAME/cache"
chown gitlab-runner:gitlab-runner \
    "/runner-data/$HOSTNAME" \
    "/runner-data/$HOSTNAME/builds" \
    "/runner-data/$HOSTNAME/cache"

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

cleanup_dir="/runner-data/$HOSTNAME"
cleanup_request="$cleanup_dir/.cleanup.request"
exec 9>"$cleanup_dir/.cleanup.lock"
flock -s 9
touch "$cleanup_dir/.cleanup.ready"

echo "Registering runner with name $HOSTNAME"
gitlab-runner register \
    --name "$HOSTNAME" \
    --non-interactive \
    --url "$gitlab_endpoint" \
    --token "$token" \
    --executor "shell" \
    --builds-dir "/runner-data/$HOSTNAME/builds" \
    --cache-dir "/runner-data/$HOSTNAME/cache" \
    --custom_build_dir-enabled=true \
    --env "DOCKER_USERNAME=${DOCKER_USERNAME}" \
    --env "DOCKER_PASSWORD=${DOCKER_PASSWORD}" \
    --env "LOCAL_DOCKER_USERNAME=${DOCKERHUB_USERNAME}" \
    --env "LOCAL_DOCKER_PASSWORD=${DOCKERHUB_PASSWORD}" \
    --env "CN_DOCKER_USERNAME=${CN_DOCKER_USERNAME}" \
    --env "CN_DOCKER_PASSWORD=${CN_DOCKER_PASSWORD}" \
    --env "LOCAL_NUGET_API_KEY=${LOCAL_NUGET_API_KEY}" \
    --env "NUGET_API_KEY=${NUGET_API_KEY}" \
    --env "APKG_DEV_API_KEY=${APKG_DEV_API_KEY}" \
    --env "APKG_PROD_API_KEY=${APKG_PROD_API_KEY}" \
    --env "S360_SERVER=${S360_SERVER}" \
    --env "S360_BASELINE_KEY=${S360_BASELINE_KEY}"

# All runner replicas share one builder. Serialize node configuration and live
# resource updates, preserving its existing container, state volume and caches.
echo "Ensuring global buildx builder for CI (as gitlab-runner)..."
BUILDER_NAME="aiur-global-builder"
builder_node="${BUILDER_NAME}0"
builder_container="buildx_buildkit_$builder_node"
exec 8>"/runner-data/.builder.lock"
flock -x 8
if builder_info=$(sudo -H -u gitlab-runner /usr/local/bin/docker buildx inspect "$BUILDER_NAME" 2>/dev/null); then
    builder_layout=$(printf '%s\n' "$builder_info" | awk '
        $1 == "Driver:" { driver = $2 }
        $1 == "Name:" { names = names " " $2 }
        END { print driver names }')
    if [ "$builder_layout" != "docker-container $BUILDER_NAME $builder_node" ]; then
        echo "Error: the shared builder must have exactly its expected docker-container node."
        exit 1
    fi
fi
# Supplying the existing node updates its durable driver options. The Docker
# wrapper retains network=host; no builder removal or cache pruning is needed.
sudo -H -u gitlab-runner /usr/local/bin/docker buildx create \
    --name "$BUILDER_NAME" --node "$builder_node" \
    --driver docker-container --use \
    --driver-opt "\"cpuset-cpus=$ci_cpuset\"" \
    --driver-opt cpu-period=100000 --driver-opt cpu-quota=1400000
# Bootstrap does not update an already-created container's resource limits.
if /usr/bin/docker container inspect "$builder_container" > /dev/null 2>&1; then
    /usr/bin/docker update --cpuset-cpus "$ci_cpuset" \
        --cpu-period 100000 --cpu-quota 1400000 "$builder_container"
fi
sudo -H -u gitlab-runner /usr/local/bin/docker buildx inspect --bootstrap "$BUILDER_NAME"
if [ "$(/usr/bin/docker inspect --format '{{.HostConfig.CpusetCpus}} {{.HostConfig.CpuPeriod}} {{.HostConfig.CpuQuota}}' "$builder_container")" != "$ci_cpuset 100000 1400000" ]; then
    echo "Error: BuildKit must use the shared CPU set and its fourteen-CPU quota."
    exit 1
fi
flock -u 8
exec 8>&-

# Keep the shared lock while this runner can accept jobs. The cleaner requests a
# graceful drain with .cleanup.request, then waits for the exclusive lock.
trap 'kill -TERM "${runner_pid:-}" 2>/dev/null || true; exit 143' TERM INT
while true; do
    if [ -e "$cleanup_request" ]; then
        flock -u 9
        while [ -e "$cleanup_request" ]; do sleep 5; done
        flock -s 9
        continue
    fi

    gitlab-runner run --user=gitlab-runner --working-directory=/home/gitlab-runner 9>&- &
    runner_pid=$!
    (
        exec 9>&-
        while kill -0 "$runner_pid" 2>/dev/null; do
            if [ -e "$cleanup_request" ]; then
                kill -QUIT "$runner_pid" 2>/dev/null || true
                exit 0
            fi
            sleep 5
        done
    ) &
    monitor_pid=$!

    if wait "$runner_pid"; then
        runner_status=0
    else
        runner_status=$?
    fi
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true

    if [ ! -e "$cleanup_request" ]; then
        exit "$runner_status"
    fi
done
