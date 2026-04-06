#!/bin/bash
set -e

cd /app

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ${NC} ${BOLD}$1${NC}"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} ${BOLD}$1${NC}"
}

log_step() {
    echo -e "\n${CYAN}▶${NC} ${BOLD}$1${NC}"
}

log_detail() {
    echo -e "  ${DIM}$1${NC}"
}

# ── Sync-record helpers (used to skip unchanged images) ──────────────
SYNC_RECORDS_DIR="/app/sync_records"
mkdir -p "$SYNC_RECORDS_DIR"

get_sync_record_file() {
    local image="$1"
    # Normalise: append :latest when no tag is specified
    if [[ "$image" != *":"* ]]; then
        image="${image}:latest"
    fi
    # Replace / with __ and : with _ for safe filenames
    echo "${SYNC_RECORDS_DIR}/$(echo "$image" | sed 's|/|__|g; s|:|_|g')"
}

save_sync_record() {
    local image="$1"
    local record_file
    record_file=$(get_sync_record_file "$image")
    date +%s > "$record_file"
}

get_last_sync_time() {
    local image="$1"
    local record_file
    record_file=$(get_sync_record_file "$image")
    if [[ -f "$record_file" ]]; then
        cat "$record_file"
    else
        echo "0"
    fi
}

should_skip_image() {
    local sourceImage="$1"

    if [[ "$sourceImage" != *":"* ]]; then
        sourceImage="${sourceImage}:latest"
    fi

    local imageName imageTag finalMirror lastSync
    imageName=$(echo "$sourceImage" | cut -d: -f1)
    imageTag=$(echo "$sourceImage" | cut -d: -f2)
    finalMirror="${MIRROR_TARGET}/${imageName}:${imageTag}"

    lastSync=$(get_last_sync_time "$sourceImage")

    if [[ "$lastSync" == "0" ]]; then
        # Never synced before – must proceed
        return 1
    fi

    # Ask source_updated.py whether a sync is needed
    #   exit 0 → safe to skip  |  exit 1 → must sync
    if python3 source_updated.py "$sourceImage" "$lastSync" 2>/dev/null; then
        # Double-check: the image must still be present in our mirror
        if /usr/local/bin/regctl image manifest "$finalMirror" &>/dev/null; then
            return 0   # skip
        else
            log_warning "Source unchanged but mirror image missing/invalid – will re-sync"
            return 1
        fi
    fi

    return 1   # proceed with sync
}

must_login_local_registry() {
    if [[ -z "$MIRROR_TARGET" ]]; then
        log_error "MIRROR_TARGET is not set. Cannot proceed."
        exit 1
    fi

    log_step "Authenticating to local registry"
    log_detail "Registry: ${MIRROR_TARGET}"
    log_detail "Username: ${LOCAL_DOCKER_USERNAME}"

    if [[ -z "$LOCAL_DOCKER_USERNAME" || -z "$LOCAL_DOCKER_PASSWORD" ]]; then
        log_error "Local Docker credentials are not set. Aborting."
        exit 1
    fi

    /usr/local/bin/regctl registry login "${MIRROR_TARGET}" -u "$LOCAL_DOCKER_USERNAME" -p "$LOCAL_DOCKER_PASSWORD" > /dev/null 2>&1
    log_success "Successfully authenticated to ${MIRROR_TARGET}"
}

try_docker_login() {
    if [[ -n "$FROM_REGISTRY" ]]; then
        log_step "Authenticating to source registry"
        log_detail "Registry: ${FROM_REGISTRY}"
    else
        log_step "Authenticating to Docker Hub"
    fi
    
    if [[ -z "$DOCKER_USERNAME" || -z "$DOCKER_PASSWORD" ]]; then
        log_warning "Docker credentials not set. Skipping authentication."
        return 0
    fi

    log_detail "Username: ${DOCKER_USERNAME}"
    if [[ -n "$FROM_REGISTRY" ]]; then
        /usr/local/bin/regctl registry login "${FROM_REGISTRY}" -u "$DOCKER_USERNAME" -p "$DOCKER_PASSWORD" > /dev/null 2>&1
        log_success "Successfully authenticated to ${FROM_REGISTRY}"
    else
        /usr/local/bin/regctl registry login "docker.io" -u "$DOCKER_USERNAME" -p "$DOCKER_PASSWORD" > /dev/null 2>&1
        log_success "Successfully authenticated to Docker Hub"
    fi
}


actual_mirror_docker() {
    sourceImage="$1"
    attempt="$2"

    if [[ "$sourceImage" != *":"* ]]; then
        sourceImage="${sourceImage}:latest"
    fi

    imageName=$(echo "$sourceImage" | cut -d: -f1)
    imageTag=$(echo "$sourceImage" | cut -d: -f2)
    finalMirror="${MIRROR_TARGET}/${imageName}:${imageTag}"

    # If FROM_REGISTRY is set, prepend it to the source image
    if [[ -n "$FROM_REGISTRY" ]]; then
        fullSourceImage="${FROM_REGISTRY}/${imageName}:${imageTag}"
    else
        fullSourceImage="${sourceImage}"
    fi

    log_detail "Source: ${fullSourceImage}"
    log_detail "Target: ${finalMirror}"
    
    # Check if already mirrored by comparing digests
    log_info "Checking if image is already up-to-date..."
    src_digest=$(/usr/local/bin/regctl image digest "$fullSourceImage" 2>/dev/null)
    dest_digest=$(/usr/local/bin/regctl image digest "$finalMirror" 2>/dev/null)

    if [[ -n "$src_digest" && "$src_digest" == "$dest_digest" ]]; then
        log_info "Image already mirrored (digests match), verifying integrity..."
        if ! /usr/local/bin/regctl image manifest "$finalMirror" &>/dev/null; then
            log_warning "Integrity check failed, cleaning up..."
            /usr/local/bin/regctl image delete "$finalMirror" 2>/dev/null || true
            return 1
        fi
        log_success "Image is up-to-date and valid"
        save_sync_record "$sourceImage"
        return 0
    fi

    # Perform the copy
    log_info "Copying image (attempt ${attempt})..."
    if [[ $attempt -eq 1 ]]; then
        timeout 1800 /usr/local/bin/regctl image copy "$fullSourceImage" "$finalMirror" --digest-tags 2>&1 | sed 's/^/  /'
    else
        timeout 1800 /usr/local/bin/regctl image copy "$fullSourceImage" "$finalMirror" --force-recursive --digest-tags 2>&1 | sed 's/^/  /'
    fi
    sleep 3

    # Verify the copy
    log_info "Verifying mirrored image..."
    
    if ! /usr/local/bin/regctl image manifest "$finalMirror" &> /dev/null; then
        log_error "Manifest verification failed"
        /usr/local/bin/regctl image delete "$finalMirror" 2>/dev/null || true
        return 1
    fi

    log_success "Image mirrored and verified successfully"
    save_sync_record "$sourceImage"
    return 0
}



mirror_docker() {
    sourceImage="$1"
    max_attempts=8
    
    log_step "Mirroring: ${BOLD}${sourceImage}${NC}"

    # ── Skip images whose source has not changed since last sync ──
    if should_skip_image "$sourceImage"; then
        log_success "Skipped ${BOLD}${sourceImage}${NC} (source unchanged since last sync)"
        echo ""
        return 0
    fi
    
    for attempt in $(seq 1 $max_attempts); do
        log_info "Attempt ${attempt}/${max_attempts}"
        
        if actual_mirror_docker "$sourceImage" "$attempt"; then
            log_success "${BOLD}${sourceImage}${NC} mirrored successfully"
            echo ""
            return 0
        fi
        
        # Calculate backoff time with exponential increase and some randomness
        backoff=$((300 + (attempt * attempt * 15) + (RANDOM % 30)))
        
        if [ $attempt -lt $max_attempts ]; then
            log_warning "Mirror failed, retrying in ${backoff}s..."
            sleep $backoff
        else
            log_error "${BOLD}${sourceImage}${NC} failed after ${max_attempts} attempts"
            echo ""
            return 1
        fi
    done
}


must_login_local_registry
try_docker_login
# Define images list
images=(
    "24oi/oi-wiki"
    "alpine"
    "andyzhangx/samba:win-fix"
    "artalk/artalk-go"
    "bitwardenrs/server"
    "busybox"
    "bytemark/webdav"
    "caddy"
    "caddy:builder"
    "chocobozzz/peertube-webserver"
    "chocobozzz/peertube:production-bookworm"
    "clickhouse/clickhouse-server"
    "cloudflare/cloudflared"
    "collabora/code"
    "consul:1.15.4"
    "containrrr/watchtower"
    "containrrr/shepherd"
    "couchdb"
    "couchdb:2.3.0"
    "debian:12"
    "debian:12.4"
    "debian:stable-slim"
    "docker:dind"
    "docker:latest"
    "docker:dind-rootless"
    "dockurr/windows"
    "dperson/samba"
    "edgeneko/neko-image-gallery:edge-cpu"
    "edgeneko/neko-image-gallery:edge-cuda"
    "elasticsearch:8.11.3"
    "elasticsearch:9.0.4"
    "filebrowser/filebrowser"
    "frolvlad/alpine-gxx"
    "gcc"
    "gcc:15.2.0"
    "gcc:4.9.4"
    "ghcr.io/anduin2017/how-to-cook:latest"
    "ghcr.io/caioricciuti/ch-ui:latest"
    "ghcr.io/immich-app/immich-machine-learning:release"
    "ghcr.io/immich-app/immich-server:release"
    "ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0"
    "ghcr.io/nextcloud-releases/aio-talk"
    "ghcr.io/open-webui/mcpo:main"
    "ghcr.io/open-webui/open-webui:main"
    "ghcr.io/open-webui/open-terminal"
    "ghcr.io/thomiceli/opengist"
    "ghcr.io/usememos/memos"
    "ghcr.io/goauthentik/server:2026.2.1"
    "ghcr.io/goauthentik/proxy:2026.2.1"
    "gitea/gitea"
    "gitlab/gitlab-ce"
    "gitlab/gitlab-ee"
    "golang"
    "golang:1.21.5"
    "grafana/grafana"
    "haproxy"
    "haskell"
    "haskell:9.8.1"
    "hello-world"
    "homeassistant/home-assistant"
    "httpd"
    "immybot/remotely"
    "immybot/remotely:69"
    "immybot/remotely:88"
    "imolein/lua:5.4"
    "influxdb"
    "influxdb:1.8"
    "indexyz/mikutap"
    "jammsen/sons-of-the-forest-dedicated-server"
    "jellyfin/jellyfin"
    "jgraph/drawio:24.7.17"
    "joxit/docker-registry-ui"
    "jvmilazz0/kavita"
    "loicsharma/baget"
    "louislam/uptime-kuma"
    "louislam/uptime-kuma:1"
    "mariadb"
    "mcr.microsoft.com/azuredataexplorer/kustainer-linux"
    "mcr.microsoft.com/dotnet/aspnet:10.0"
    "mcr.microsoft.com/dotnet/sdk:10.0"
    "mcr.microsoft.com/mssql/server"
    "mcr.microsoft.com/powershell:7.5-ubuntu-24.04"
    "mcr.microsoft.com/powershell"
    "mediawiki"
    "mediacms/mediacms"
    "memcached"
    "minio/minio"
    "mongo"
    "mwader/postfix-relay"
    "mysql"
    "neosmemo/memos:stable"
    "nextcloud"
    "nextcloud:27.1.0"
    "nextcloud:31.0.7"
    "nextcloud:32.0.5"
    "nextcloud:production"
    "nextcloud:stable"
    "nginx"
    "nginx:alpine"
    "node"
    "node:16-alpine"
    "node:21-alpine"
    "node:22-alpine"
    "node:24-alpine"
    "nvidia/cuda:11.6.2-base-ubuntu20.04"
    "nvidia/cuda:11.8.0-devel-ubuntu22.04"
    "nvidia/cuda:12.6.2-devel-ubuntu24.04"
    "nvidia/cuda:12.8.1-devel-ubuntu24.04"
    "ollama/ollama"
    "oven/bun:slim"
    "owncast/owncast"
    "m986883511/paddleocr:api"
    "passivelemon/terraria-docker"
    "perl:5.39.5"
    "phanan/koel"
    "php:8.3.0-zts"
    "portainer/portainer-ce"
    "postgres"
    "postgres:13-alpine"
    "postgres:14-alpine"
    "postgres:15.2-alpine"
    "postgres:16-alpine"
    "prom/prometheus"
    "pytorch/pytorch:2.3.0-cuda11.8-cudnn8-devel"
    "pytorch/pytorch:2.7.0-cuda12.6-cudnn9-devel"
    "python:3.10"
    "python:3.11"
    "qdrant/qdrant"
    "rabbitmq"
    "redis"
    "redis:7-alpine"
    "redis:6-alpine"
    "redis:alpine"
    "registry:3"
    "registry:2"
    "rigetti/lisp"
    "ruby:3.2.2"
    "rust"
    "rust:1.81-slim"
    "rust:slim"
    "rustdesk/rustdesk-server:latest"
    "sameersbn/apt-cacher-ng"
    "snowdreamtech/frpc"
    "snowdreamtech/frps"
    "swarmpit/agent"
    "swarmpit/swarmpit"
    "swift:5.8.1"
    "teddysun/xray"
    "telegraf"
    "thedaviddelta/lingva-translate"
    "timberio/vector:latest-alpine"
    "traefik"
    "ubuntu:22.04"
    "ubuntu:24.04"
    "ubuntu:24.10"
    "ubuntu:25.04"
    "ubuntu:25.10"
    "valkey/valkey:8-bookworm"
    "vaultwarden/server"
    "vaultwarden/server:testing"
    "verdaccio/verdaccio"
    "vikunja/vikunja"
    "vllm/vllm-openai"
    "vminnovations/typescript-sdk:16-latest"
    "wolveix/satisfactory-server:latest"
    "wordpress:php8.3-fpm-alpine"
)

# Shuffle the list and iterate
shuffled_images=($(printf "%s\n" "${images[@]}" | shuf))

for image in "${shuffled_images[@]}"; do
    mirror_docker "$image"
done

echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
log_success "${BOLD}All images have been processed${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
