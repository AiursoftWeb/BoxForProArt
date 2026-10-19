#!/bin/bash
set -euo pipefail
#==========================
# Color
#==========================
export Green="\033[32m"
export Red="\033[31m"
export Yellow="\033[33m"
export Blue="\033[36m"
export Font="\033[0m"
export GreenBG="\033[42;37m"
export RedBG="\033[41;37m"
export INFO="${Blue}[ INFO ]${Font}"
export OK="${Green}[  OK  ]${Font}"
export ERROR="${Red}[FAILED]${Font}"
export WARNING="${Yellow}[ WARN ]${Font}"

#==========================
# Argument Parsing
#==========================
STACK_FILTER=""
TARGET_STAGE=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --filter)
      if [[ -n "${2:-}" ]]; then
        STACK_FILTER="$2"
        echo -e "${Green}[  OK  ]${Font} ${Blue} Running with filter, will only deploy stacks containing: '$STACK_FILTER'${Font}"
        shift 2
      else
         echo -e "${ERROR} ${Red} --filter requires a non-empty argument.${Font}"
         exit 1
      fi
      ;;
    --stage)
      if [[ -n "${2:-}" ]] && [[ "$2" =~ ^[0-4]$ ]]; then
        TARGET_STAGE="$2"
        echo -e "${Green}[  OK  ]${Font} ${Blue} Running starting from stage: $TARGET_STAGE${Font}"
        shift 2
      else
        echo -e "${ERROR} ${Red} --stage requires an integer argument (0-4).${Font}"
        exit 1
      fi
      ;;
    *)
      echo -e "${WARNING} ${Yellow} Unknown argument: $1${Font}"
      shift
      ;;
  esac
done

#==========================
# Print Colorful Text
#==========================
function print_ok() {
  echo -e "${OK} ${Blue} $1 ${Font}"
}

function print_info() {
  echo -e "${INFO} ${Font} $1"
}

function print_error() {
  echo -e "${ERROR} ${Red} $1 ${Font}"
}

function print_warn() {
  echo -e "${WARNING} ${Yellow} $1 ${Font}"
}

function judge() {
  if [[ 0 -eq $? ]]; then
    print_ok "$1 succeeded"
    sleep 0.2
  else
    print_error "$1 failed"
    exit 1
  fi
}

# Determine which env file to use
if [ -f ".env.prod" ]; then
    ENV_FILE=".env.prod"
    print_ok "Using .env.prod for configuration."
elif [ -f ".env" ]; then
    ENV_FILE=".env"
    print_warn "Using .env for configuration."
else
    ENV_FILE=""
    print_ok "No .env or .env.prod file found. Proceeding without variable substitution."
fi

function get_env_value() {
    local key=$1
    local line

    if [ -z "$ENV_FILE" ]; then
        print_error "No environment file found. '$key' is required." >&2
        exit 1
    fi

    line=$(grep -m1 -E "^${key}=" "$ENV_FILE" || true)
    if [ -z "$line" ] || [ -z "${line#*=}" ]; then
        print_error "'$key' is missing or empty in $ENV_FILE." >&2
        exit 1
    fi

    printf '%s' "${line#*=}"
}

function login_to_hub() {
    local registry_host=$1
    local verification_image=$2
    local username_key=${3:-DOCKERHUB_USERNAME}
    local password_key=${4:-DOCKERHUB_PASSWORD}
    local hub_username
    local hub_password

    hub_username=$(get_env_value "$username_key")
    hub_password=$(get_env_value "$password_key")

    print_ok "Logging in to $registry_host..."
    if ! printf '%s' "$hub_password" | sudo docker login "$registry_host" --username "$hub_username" --password-stdin; then
        print_error "Failed to log in to $registry_host."
        exit 1
    fi
    unset hub_password

    print_ok "Verifying access to $registry_host/$verification_image..."
    if ! sudo docker manifest inspect "$registry_host/$verification_image" >/dev/null; then
        print_error "Registry login succeeded, but the configured account cannot read $registry_host/$verification_image."
        exit 1
    fi
}

function install_yq() {
    local download_link="https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64"
    sudo wget -O /usr/bin/yq "$download_link"
    sudo chmod +x /usr/bin/yq
}

function init_docker_swarm() {
    sudo docker swarm init --advertise-addr $(hostname -I | awk '{print $1}')
}

function ensure_docker_ready() {
    # Init docker swarm if not initialized
    sudo docker info | grep -q "Swarm: active" || init_docker_swarm

    # Add user to docker group
    sudo usermod -aG docker $USER
}

function ensure_packages_needed_ready() {
    sudo DEBIAN_FRONTEND=noninteractive apt install -y wsdd valgrind curl wget jq apt-transport-https ca-certificates docker-compose-v2 docker.io qemu-user-binfmt docker-buildx

    # Install yq. (Run install_yq only if the /usr/bin/yq does not exist.)
    [ -f /usr/bin/yq ] || install_yq

    # Install docker
    ensure_docker_ready
}

function ensure_nvidia_gpu() {
    # ensure /usr/bin/nvidia-smi exists
    if [ ! -f /usr/bin/nvidia-smi ]; then
        local doc_link=https://docs.anduinos.com/Applications/Development/Docker/Docker.html
        print_error "Please install Nvidia driver. See $doc_link for more information."
        exit 1
    fi

    ulimit -n 65535
    valgrind /usr/bin/nvidia-smi -L 2> /dev/null | grep -q "GPU 0" || {
        local doc_link=https://docs.anduinos.com/Applications/Development/Docker/Docker.html
        print_error "Please ensure you have Nvidia GPU. See $doc_link for more information."
        exit 1
    }

    # ensure package: nvidia-container-toolkit and nvidia-docker2
    apt list --installed | grep -q nvidia-container-toolkit || {
        local doc_link=https://docs.anduinos.com/Applications/Development/Docker/Docker.html
        print_error "Please install nvidia-container-toolkit and nvidia-docker2. See $doc_link for more information."
        exit 1
    }
}

better_performance() {
    # Avoid system sleep (If gsettings command exists)
    if command -v gsettings &>/dev/null; then
        print_warn "Disabling sleep via gsettings..."
        gsettings set org.gnome.desktop.session idle-delay 0 || true
        gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' || true
        gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' || true
    fi

    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

    print_ok "Applying runtime sysctl tweaks for performance..."
    sudo sysctl -w net.core.rmem_max=2500000
    sudo sysctl -w net.core.wmem_max=2500000
    sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
    sudo sysctl -w net.core.default_qdisc=fq
    sudo sysctl -w fs.inotify.max_user_instances=524288
    sudo sysctl -w fs.inotify.max_user_watches=524288
    sudo sysctl -w fs.inotify.max_queued_events=524288
    sudo sysctl -w fs.aio-max-nr=2097152

    print_ok "Setting system timezone to UTC..."
    sudo timedatectl set-timezone UTC

}

function setup_docker_auto_clean() {
    echo "Configuring Docker cleanup every 23 hours..."
    local temp_dir
    local unit
    local changed=0
    temp_dir=$(mktemp -d)

    # Keep the existing unit names so upgrades replace the old disk monitor.
    cat > "$temp_dir/docker-disk-monitor.service" <<'EOF'
[Unit]
Description=Prune unused Docker data
After=docker.service

[Service]
Type=oneshot
ExecCondition=/usr/bin/systemctl is-active --quiet docker.service
ExecStart=/usr/bin/docker system prune -a -f
User=root
EOF

    cat > "$temp_dir/docker-disk-monitor.timer" <<'EOF'
[Unit]
Description=Prune unused Docker data every 23 hours

[Timer]
OnActiveSec=23h
OnUnitActiveSec=23h
Unit=docker-disk-monitor.service

[Install]
WantedBy=timers.target
EOF

    for unit in docker-disk-monitor.service docker-disk-monitor.timer; do
        if ! sudo cmp -s "$temp_dir/$unit" "/etc/systemd/system/$unit"; then
            sudo install -m 0644 "$temp_dir/$unit" "/etc/systemd/system/$unit"
            changed=1
        fi
    done
    rm -rf "$temp_dir"
    sudo rm -f /usr/local/bin/docker-disk-monitor.sh

    if [ "$changed" -eq 1 ]; then
        sudo systemctl daemon-reload
        sudo systemctl enable docker-disk-monitor.timer
        sudo systemctl restart docker-disk-monitor.timer
    else
        # Starting an already active timer leaves its schedule unchanged.
        sudo systemctl enable --now docker-disk-monitor.timer
    fi
}

function create_secret() {
    local secret_name=$1
    if ! sudo docker secret ls --format '{{.Name}}' | grep -Fxq "$secret_name"; then
        local secret_value
        if [ -t 0 ]; then
          read -rs -p "Enter value for secret '$secret_name': " secret_value
          echo
        else
          read -rs -p "Enter value for secret '$secret_name': " secret_value < /dev/tty
          echo
        fi

        printf '%s' "$secret_value" | sudo docker secret create "$secret_name" -
    fi
}

function create_network() {
    network_name=$1
    subnet=$2
    known_networks=$(sudo docker network ls --format '{{.Name}}')
    if ! echo "$known_networks" | grep -Fxq "$network_name"; then
        print_warn "Creating network $network_name with subnet $subnet and MTU 1400..."
        networkId=$(sudo docker network create \
            --driver overlay \
            --attachable \
            --subnet $subnet \
            --opt com.docker.network.driver.mtu=1400 \
            --scope swarm $network_name)
        print_ok "Network $network_name created with id $networkId"
    fi
}

function deploy() {
    local original_compose_file=$1
    local stack_name=$2
    local temp_compose_file=$(mktemp)

    # Always copy to a temporary file to avoid modifying the original
    cp "$original_compose_file" "$temp_compose_file"

    # If an environment file is found, perform substitutions
    if [ -n "$ENV_FILE" ]; then
        # Read non-empty, non-comment lines from the env file
        grep -v -e '^#' -e '^$' "$ENV_FILE" | while IFS='=' read -r key value; do
            # Escape slashes and ampersands for sed
            escaped_value=$(printf '%s\n' "$value" | sed -e 's/[\/&]/\\&/g')
            # Use a different delimiter for sed to handle special characters in values
            sed -i "s/{{$key}}/$escaped_value/g" "$temp_compose_file"
        done
    fi

    print_ok "Deploying stack '$stack_name' with compose file '$original_compose_file'..."
    sudo docker stack deploy -c "$temp_compose_file" "$stack_name" --detach --prune --with-registry-auth

    # Clean up the temporary file
    rm "$temp_compose_file"
}

# Zot initializes OIDC during startup; an Authentik rollout can otherwise crash Zot
# and pause its Swarm update (observed on Global on 2026-10-16).
# Keep this guard identical across Boxes; only the persisted config path differs.
function wait_for_zot_oidc() {
    local config=$1 issuer discovery services details remaining
    local deadline=$((SECONDS + 600))
    local reason="OIDC discovery is not ready"

    if ! sudo test -f "$config"; then
        config="stage3/images/zot/default-config.json"
    fi
    if ! issuer=$(sudo jq -er '.http.auth.openid.providers.oidc.issuer | select(type == "string" and startswith("https://"))' "$config"); then
        print_error "Cannot read Zot's OIDC issuer from $config; refusing to update Zot."
        return 1
    fi
    discovery="${issuer%/}/.well-known/openid-configuration"

    while (( SECONDS < deadline )); do
        # A healthy response from the old Authentik task is not rollout completion.
        if [ -f stage3/stacks/authentik/docker-compose.yml ]; then
            if ! services=$(sudo timeout 10 docker stack services authentik --format '{{json .}}') ||
               ! details=$(printf '%s\n' "$services" | jq -ser 'map(.Name) | select(length > 0) | .[]' |
                   xargs sudo timeout 10 docker service inspect); then
                reason="cannot inspect the local Authentik stack"
            elif jq -e 'any(.[]; (.UpdateStatus.State // "") | test("paused|rollback"))' <<< "$details" >/dev/null; then
                print_error "Authentik update paused or rolled back; inspect docker stack ps authentik before retrying. Zot was not updated."
                return 1
            elif jq -e 'all(.[]; (.UpdateStatus.State // "") as $state | $state == "" or $state == "completed")' <<< "$details" >/dev/null &&
                 jq -se 'length > 0 and all(.[]; .Replicas | split("/") | length == 2 and .[0] == .[1] and (.[1] | tonumber) > 0)' <<< "$services" >/dev/null; then
                reason="OIDC discovery is not ready"
            else
                reason="local Authentik services are still converging"
            fi
        fi

        remaining=$((deadline - SECONDS))
        if (( remaining <= 0 )); then
            break
        fi
        if [ "$reason" = "OIDC discovery is not ready" ]; then
            if curl --fail --silent --show-error --connect-timeout 5 --max-time "$((remaining < 10 ? remaining : 10))" "$discovery" |
                jq -e --arg issuer "$issuer" '.issuer == $issuer and
                    ([.authorization_endpoint, .token_endpoint, .jwks_uri] |
                     all(.[]; type == "string" and startswith("https://")))' >/dev/null; then
                print_ok "Zot OIDC discovery is ready: $discovery"
                return 0
            fi
        fi
        print_warn "Waiting before updating Zot: $reason."
        remaining=$((deadline - SECONDS))
        if (( remaining > 0 )); then
            sleep "$((remaining < 5 ? remaining : 5))"
        fi
    done
    print_error "Timed out after 600s: $reason. Check Authentik and $discovery; Zot was not updated."
    return 1
}

# Ensure packages needed are ready
if [ "$TARGET_STAGE" -le 0 ]; then
print_ok "Ensure packages needed are ready..."
ensure_packages_needed_ready

# Ensure has Nvidia GPU and have installed nvidia-container-toolkit and nvidia-docker2
print_ok "Ensure has Nvidia GPU and have installed..."
if [ -f /usr/bin/nvidia-smi ]; then
    ensure_nvidia_gpu
else
    print_warn "Nvidia GPU not found. Skipping Nvidia GPU configuration. GPU pass-through will not be available."
fi

# Tuning for better performance
print_ok "Tuning for better performance..."
better_performance

# Setup docker auto clean
print_ok "Setting up docker auto clean..."
setup_docker_auto_clean

print_ok "Deleting zombie vxlan interfaces..."
for interface in $(ip -d link show | grep vx | grep DOWN | awk -F': ' '{print $2}'); do
  echo "Deleting zombie interface: $interface"
  sudo ip link delete $interface
done
judge "Deleting zombie vxlan interfaces"

print_ok "Creating secrets..."
while IFS= read -r file; do
  while IFS= read -r secret_name; do
    if [ -n "$secret_name" ]; then
      print_ok "Creating secret $secret_name..."
      create_secret "$secret_name"
    fi
  done < <(yq eval '.secrets | to_entries | .[] | select(.value.external == true) | .key' "$file")
done < <(find ./stage* -name 'docker-compose.yml' -type f)

print_ok "Creating networks..."
subnet_third_octet=233
external_networks=$(find ./stage* -name 'docker-compose.yml' -type f | xargs yq eval '.networks | to_entries | .[] | select(.value.external == true) | .key' 2>/dev/null | sort | uniq)
for network in $external_networks; do
  if [ "$network" == "---" ]; then
    continue
  fi
  print_ok "Ensuring network $network exists..."
  create_network "$network" "10.${subnet_third_octet}.0.0/16"
  subnet_third_octet=$((subnet_third_octet + 1))
done

print_ok "Creating data folders..."
sudo mkdir -p /swarm-vol/docker-data /swarm-vol/containerd-data

find . -name 'docker-compose.yml' | while read file; do
  awk '{if(/device:/) print $2}' "$file" | while read -r path; do
    if [ ! -d "$path" ]; then
        print_info "Creating directory: $path"
        sudo mkdir -p "$path"
    else
        : # no-op
    fi
  done
done

#=============================
# Docker Daemon Configuration
#=============================
print_ok "Configuring docker daemon..."

if [ ! -f /etc/containerd/config.toml ]; then
    sudo mkdir -p /etc/containerd
    sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
fi
old_hash_containerd=$(sha256sum /etc/containerd/config.toml | awk '{print $1}')
sudo sed -i 's|^#\?root = .*|root = "/swarm-vol/containerd-data"|' /etc/containerd/config.toml

if [ -f /etc/docker/daemon.json ]; then
    old_hash_daemon=$(sha256sum /etc/docker/daemon.json | awk '{print $1}')
else
    old_hash_daemon=""
fi

if [ -f /etc/nvidia-container-runtime/config.toml ]; then
    old_hash_nvidia=$(sha256sum /etc/nvidia-container-runtime/config.toml | awk '{print $1}')
else
    old_hash_nvidia=""
fi

if [ -f /usr/bin/nvidia-smi ]; then
  print_ok "Nvidia GPU detected. Configuring for Nvidia..."
  raw_gpu_output=$(valgrind /usr/bin/nvidia-smi -a 2> /dev/null || true)
  GPU_IDS=$(echo "$raw_gpu_output" | grep "GPU UUID" | awk '{print substr($4,5,36)}' || true)
  print_ok "Detected GPU UUIDs:"
  print_ok "$GPU_IDS"
  JSON_GPU_RESOURCES=""
  for ID in $GPU_IDS; do
      JSON_GPU_RESOURCES+="\"NVIDIA-GPU=$ID\","
  done
  JSON_GPU_RESOURCES=${JSON_GPU_RESOURCES%,}  # Remove trailing comma

  sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "mtu": 1400,
  "data-root": "/swarm-vol/docker-data",
  "insecure-registries": [
    "localhost:8080"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "userland-proxy": false,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    }
  },
  "runtimes": {
    "nvidia": {
      "path": "/usr/bin/nvidia-container-runtime",
      "runtimeArgs": []
    }
  },
  "default-runtime": "nvidia",
  "node-generic-resources": [
    $JSON_GPU_RESOURCES
  ]
}
EOF

  sudo sed -i 's/#swarm-resource = "DOCKER_RESOURCE_GPU"/swarm-resource = "DOCKER_RESOURCE_GPU"/' /etc/nvidia-container-runtime/config.toml

else
  print_warn "Nvidia GPU not found. Configuring standard docker daemon..."
  
  sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "mtu": 1400,
  "data-root": "/swarm-vol/docker-data",
  "insecure-registries": [
    "localhost:8080"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "userland-proxy": false,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    }
  }
}
EOF
fi

new_hash_daemon=$(sha256sum /etc/docker/daemon.json | awk '{print $1}')
if [ -f /etc/nvidia-container-runtime/config.toml ]; then
    new_hash_nvidia=$(sha256sum /etc/nvidia-container-runtime/config.toml | awk '{print $1}')
else
    new_hash_nvidia=""
fi

new_hash_containerd=$(sha256sum /etc/containerd/config.toml | awk '{print $1}')
if [ "$old_hash_containerd" != "$new_hash_containerd" ]; then
    print_warn "Containerd configuration changed. Restarting containerd service..."
    sudo systemctl restart containerd.service
fi

if [ "$old_hash_daemon" != "$new_hash_daemon" ] || [ "$old_hash_nvidia" != "$new_hash_nvidia" ] || [ "$old_hash_containerd" != "$new_hash_containerd" ]; then
    print_warn "Configuration files changed. Restarting docker service..."
    sudo systemctl restart docker.service
else
    print_ok "Configuration files not changed."
fi
#=============================
# Docker Daemon Configuration End
#=============================

print_warn "=============================================================================="
print_warn "   Starting stage 0: Mission is to start a simple registry"
print_warn "=============================================================================="
sleep 3

login_to_hub "docker.io" "registry:3" "PUBLIC_DOCKER_HUB_USERNAME" "PUBLIC_DOCKER_HUB_PASSWORD"
sudo docker compose -f ./stage0/registry/docker-compose.yml up -d --pull always --no-recreate --remove-orphans

#deploy stage0/registry/docker-compose.yml registry # 8080

print_ok "Make sure the registry is ready..."
sleep 5 # Could not trust result in the first few seconds, because the old registry might still be running
while curl -s http://localhost:8080/ > /dev/null; [ $? -ne 0 ]; do
    print_warn "Waiting for registry(http://localhost:8080/) to start..."
    sleep 1
done

print_warn "=============================================================================="
print_warn "   Ending stage 0: Registry is ready at http://localhost:8080/"
print_warn "=============================================================================="
fi

if [ "$TARGET_STAGE" -le 1 ]; then
print_warn "=============================================================================="
print_warn "   Starting stage 1: Mission is to mirror public images to the simple registry"
print_warn "=============================================================================="
sleep 3

login_to_hub "docker.io" "ubuntu:26.04" "PUBLIC_DOCKER_HUB_USERNAME" "PUBLIC_DOCKER_HUB_PASSWORD"
bash ./stage1/mirror.sh

print_warn "=============================================================================="
print_warn "   Ending stage 1: Images are mirrored."
print_warn "=============================================================================="
fi

if [ "$TARGET_STAGE" -le 2 ]; then
print_warn "=============================================================================="
print_warn "   Starting stage 2: Mission is to build and start basic web infrastructure"
print_warn "=============================================================================="
sleep 3

rm -rf ./stage2/images/sites/discovered
mkdir -p ./stage2/images/sites/discovered && \
    cp ./stage2/stacks/**/*.conf ./stage2/images/sites/discovered && \
    cp ./stage3/stacks/**/*.conf ./stage2/images/sites/discovered && \
    cp ./stage4/stacks/**/*.conf ./stage2/images/sites/discovered

print_ok "Building local ubuntu..."
sudo docker build ./stage2/images/ubuntu   -t localhost:8080/box_starting/local_ubuntu:latest
sudo docker push localhost:8080/box_starting/local_ubuntu:latest
print_ok "Building local frp..."
sudo docker build ./stage2/images/frp      -t localhost:8080/box_starting/local_frp:latest
sudo docker push localhost:8080/box_starting/local_frp:latest
print_ok "Building local frp-monitor..."
sudo docker build ./stage2/images/frp-monitor -t localhost:8080/box_starting/local_frp_monitor:latest
sudo docker push localhost:8080/box_starting/local_frp_monitor:latest
print_ok "Building local caddy..."
sudo docker build ./stage2/images/sites    -t localhost:8080/box_starting/local_sites:latest
sudo docker push localhost:8080/box_starting/local_sites:latest
print_ok "Building local pysyncer..."
sudo docker build ./stage2/images/pysyncer    -t localhost:8080/box_starting/local_pysyncer:latest
sudo docker push localhost:8080/box_starting/local_pysyncer:latest

print_ok "Cleaning old docker-compose.yml..."
rm -f ./stage2/stacks/incoming/docker-compose.yml

print_ok "Generating docker-compose.yml with auto-discovered domains..."
bash ./stage2/stacks/incoming/generate_compose.sh
judge "Generate docker-compose.yml"

print_ok "Starting incoming proxy..."
deploy stage2/stacks/incoming/docker-compose.yml incoming # 8080

print_ok "Make sure the caddy is ready..."
sleep 5 # Could not trust result in the first few seconds, because the old registry might still be running
while [ "$(curl -s -o /dev/null -w "%{http_code}" https://test.aiursoft.com)" != "200" ]; do
    print_warn "Waiting for caddy (https://test.aiursoft.com) to start... ETA: 25s"
    sleep 1
done

print_warn "=============================================================================="
print_warn "   Ending stage 2: Basic web infrastructure is ready."
print_warn "=============================================================================="
fi

if [ "$TARGET_STAGE" -le 3 ]; then
print_warn "=============================================================================="
print_warn "   Starting stage 3: Mission is to build and start registries"
print_warn "=============================================================================="
sleep 3

deploy stage3/stacks/nuget/docker-compose.yml nuget
deploy stage3/stacks/npm/docker-compose.yml npm

print_ok "Building local zot..."
sudo docker build ./stage3/images/zot -t localhost:8080/box_starting/local_zot:latest
sudo docker push localhost:8080/box_starting/local_zot:latest

print_ok "Building local puller..."
sudo docker build ./stage3/images/puller -t localhost:8080/box_starting/local_puller:latest
sudo docker push localhost:8080/box_starting/local_puller:latest
print_ok "Building local puller_cn..."
sudo docker build ./stage3/images/puller_cn -t localhost:8080/box_starting/local_puller_cn:latest
sudo docker push localhost:8080/box_starting/local_puller_cn:latest

print_ok "Building local aptmirror..."
sudo docker build ./stage3/images/aptmirror -t localhost:8080/box_starting/local_aptmirror:latest
sudo docker push localhost:8080/box_starting/local_aptmirror:latest

print_ok "Building local ppamirror..."
sudo docker build ./stage3/images/ppamirror -t localhost:8080/box_starting/local_ppamirror:latest
sudo docker push localhost:8080/box_starting/local_ppamirror:latest

print_ok "Starting Zot, Puller, ppamirror..."
wait_for_zot_oidc /swarm-vol/ssd/zot-data/config/config.json
deploy stage3/stacks/zot/docker-compose.yml zot
deploy stage3/stacks/puller/docker-compose.yml puller
deploy stage3/stacks/aptmirror/docker-compose.yml aptmirror
deploy stage3/stacks/ppamirror/docker-compose.yml ppamirror

print_ok "Making sure the zot is ready..."
sleep 5
registry_host=$(get_env_value "REGISTRY_HOST")
while [ "$(curl -s -o /dev/null -w "%{http_code}" "https://$registry_host")" != "200" ] || \
      [ "$(curl -s -A 'docker/29.1.3' -o /dev/null -w "%{http_code}" "https://$registry_host/v2/")" != "401" ]; do
    print_warn "Waiting for registry (https://$registry_host) to start... ETA: 25s"
    sleep 1
done

print_warn "=============================================================================="
print_warn "   Ending stage 3: Registries are ready."
print_warn "=============================================================================="
fi

if [ "$TARGET_STAGE" -le 4 ]; then
print_warn "=============================================================================="
print_warn "   Starting stage 4: Mission is to deploy business stacks"
print_warn "=============================================================================="
sleep 3

login_to_hub "$(get_env_value "REGISTRY_HOST")" "$(get_env_value "REGISTRY_VERIFICATION_IMAGE")"

print_ok "Building local runner..."
sudo docker build --network=host ./stage4/images/runner -t localhost:8080/box_starting/local_runner:latest
sudo docker push localhost:8080/box_starting/local_runner:latest

print_ok "Building local worker..."
sudo docker build --network=host ./stage4/images/worker -t localhost:8080/box_starting/local_worker:latest
sudo docker push localhost:8080/box_starting/local_worker:latest

print_ok "Building runner cleaner..."
sudo docker build --network=host ./stage4/images/runner-cleaner -t localhost:8080/box_starting/local_runner_cleaner:latest
sudo docker push localhost:8080/box_starting/local_runner_cleaner:latest

print_ok "Building home power collector..."
sudo docker build --network=host ./stage4/images/home-power-collector -t localhost:8080/box_starting/home_power_collector:latest
sudo docker push localhost:8080/box_starting/home_power_collector:latest

print_ok "Ensuring binfmt support for multi-arch builds..."
if [ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    print_ok "QEMU binfmt already registered in kernel. Skipping."
else
    print_warn "QEMU binfmt not found. Registering via tonistiigi/binfmt..."
    login_to_hub "docker.io" "tonistiigi/binfmt" "PUBLIC_DOCKER_HUB_USERNAME" "PUBLIC_DOCKER_HUB_PASSWORD"
    sudo docker run --privileged --rm tonistiigi/binfmt --install all
    print_ok "QEMU binfmt registered. Supported platforms:"
    ls /proc/sys/fs/binfmt_misc/ | grep qemu || true
fi

# /swarm-vol/ssd/click-house/config_override.xml
print_ok "Copying ClickHouse config override file..."
sudo cp ./stage4/stacks/clickhouse/users_override.xml /swarm-vol/ssd/click-house/users_override.xml || true
sudo cp ./stage4/stacks/clickhouse/config_override.xml /swarm-vol/ssd/click-house/config_override.xml || true
judge "Copying ClickHouse config override file"

print_ok "Deploying business stacks..."
serviceCount=$(sudo docker service ls --format '{{.Name}}' | wc -l | awk '{print $1}')

find ./stage4 -name 'docker-compose.yml' -print0 | while IFS= read -r -d '' file; do
    # Extract the stack name from the file path (e.g., ./stage4/gitlab/docker-compose.yml -> gitlab)
    stack_name=$(basename "$(dirname "$file")")

    # Check if a filter is active, and if the stack name matches the filter
    if [ -z "$STACK_FILTER" ] || [[ "$stack_name" == *"$STACK_FILTER"* ]]; then
        print_ok "Deploying stack: $stack_name"
        deploy "$file" "$stack_name"

        # If it's a new cluster, slow down the deployment to avoid overwhelming the system
        if [ $serviceCount -lt 10 ]; then
            sleep 10
        fi
    else
        print_info "Skipping stack '$stack_name' due to filter."
    fi
done
fi
