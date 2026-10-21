#!/bin/bash
set -eo pipefail

APP_DIR="${APP_DIR:-/app}"
cd "$APP_DIR"

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
REGCTL_BIN="${REGCTL_BIN:-/usr/local/bin/regctl}"
COPY_TIMEOUT_SECONDS="${COPY_TIMEOUT_SECONDS:-14400}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-8}"
SYNC_RECORDS_DIR="${SYNC_RECORDS_DIR:-/app/sync_records}"
for value in "$COPY_TIMEOUT_SECONDS" "$MAX_ATTEMPTS"; do
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        log_error "Copy timeout and maximum attempts must be positive integers"
        exit 1
    fi
done
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
    local image="$1" digest="$2" record_file temporary_file
    record_file=$(get_sync_record_file "$image")
    temporary_file="${record_file}.tmp.$$"
    printf '%s %s\n' "$(date +%s)" "$digest" > "$temporary_file" &&
        mv "$temporary_file" "$record_file"
}

should_skip_image() {
    local sourceImage="$1" record_file lastSync="" recordedDigest="" target_digest
    record_file=$(get_sync_record_file "$sourceImage")
    [[ -f "$record_file" ]] || return 1
    read -r lastSync recordedDigest < "$record_file" || return 1
    # Old timestamp-only records may come from a falsely successful copy.
    [[ "$lastSync" =~ ^[0-9]+$ && -n "$recordedDigest" ]] || return 1
    if python3 source_updated.py "$sourceImage" "$lastSync" 2>/dev/null; then
        if ! target_digest=$("$REGCTL_BIN" image digest "${MIRROR_TARGET}/${sourceImage}"); then
            return 1
        fi
        [[ "$target_digest" == "$recordedDigest" ]] || return 1
        "$REGCTL_BIN" image manifest "${MIRROR_TARGET}/${sourceImage}" &>/dev/null
    else
        return 1
    fi
}

must_login_local_registry() {
    if [[ -z "$MIRROR_TARGET" ]]; then
        log_error "MIRROR_TARGET is not set. Cannot proceed."
        exit 1
    fi

    log_step "Authenticating to local registry"
    log_detail "Registry: ${MIRROR_TARGET}"
    log_detail "Username: ${DOCKERHUB_USERNAME}"

    if [[ -z "$DOCKERHUB_USERNAME" || -z "$DOCKERHUB_PASSWORD" ]]; then
        log_error "Local Docker credentials are not set. Aborting."
        exit 1
    fi

    "$REGCTL_BIN" registry login "${MIRROR_TARGET}" -u "$DOCKERHUB_USERNAME" -p "$DOCKERHUB_PASSWORD" > /dev/null 2>&1
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
        "$REGCTL_BIN" registry login "${FROM_REGISTRY}" -u "$DOCKER_USERNAME" -p "$DOCKER_PASSWORD" > /dev/null 2>&1
        log_success "Successfully authenticated to ${FROM_REGISTRY}"
    else
        "$REGCTL_BIN" registry login "docker.io" -u "$DOCKER_USERNAME" -p "$DOCKER_PASSWORD" > /dev/null 2>&1
        log_success "Successfully authenticated to Docker Hub"
    fi
}


actual_mirror_docker() {
    local sourceImage="$1" attempt="$2"
    local finalMirror fullSourceImage pinnedSourceImage src_digest dest_digest
    local -a copy_args
    finalMirror="${MIRROR_TARGET}/${sourceImage}"
    fullSourceImage="${FROM_REGISTRY:+${FROM_REGISTRY}/}${sourceImage}"
    log_detail "Source: ${fullSourceImage}"
    log_detail "Target: ${finalMirror}"

    if ! src_digest=$("$REGCTL_BIN" image digest "$fullSourceImage") || [[ -z "$src_digest" ]]; then
        log_error "Unable to resolve source digest: ${fullSourceImage}"
        return 1
    fi
    # Resolve the tag once; a moving latest must not change what we verify.
    pinnedSourceImage="${fullSourceImage%:*}@${src_digest}"
    dest_digest=$("$REGCTL_BIN" image digest "$finalMirror" 2>/dev/null) || dest_digest=""
    if [[ "$src_digest" != "$dest_digest" ]]; then
        copy_args=(image copy "$pinnedSourceImage" "$finalMirror" --digest-tags)
        if [[ "$attempt" -gt 1 ]]; then
            copy_args+=(--force-recursive)
        fi
        log_info "Copying image (attempt ${attempt})..."
        if ! timeout "$COPY_TIMEOUT_SECONDS" "$REGCTL_BIN" "${copy_args[@]}" 2>&1 | sed 's/^/  /'; then
            log_error "Copy command failed or exceeded ${COPY_TIMEOUT_SECONDS}s"
            return 1
        fi
        sleep 3
    fi

    if ! dest_digest=$("$REGCTL_BIN" image digest "$finalMirror") || [[ "$dest_digest" != "$src_digest" ]]; then
        log_error "Target digest does not match the resolved source digest"
        return 1
    fi
    if ! "$REGCTL_BIN" image manifest "$finalMirror" &>/dev/null; then
        log_error "Manifest verification failed; retaining the existing target"
        return 1
    fi
    if ! save_sync_record "$sourceImage" "$src_digest"; then
        log_error "Unable to save verified sync record"
        return 1
    fi
    log_success "Image mirrored and digest verified successfully"
    return 0
}


mirror_docker() {
    local sourceImage="$1"
    local max_attempts="$MAX_ATTEMPTS" attempt backoff
    if [[ "${sourceImage##*/}" != *":"* ]]; then
        sourceImage="${sourceImage}:latest"
    fi
    
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
    "ghcr.io/goauthentik/server:2026.8.4"
    "ghcr.io/goauthentik/proxy:2026.8.4"
    "gitea/gitea"
    "gitlab/gitlab-ce"
    "gitlab/gitlab-ee"
    # Required upgrade stop before GitLab 19.3.x.
    "gitlab/gitlab-ee:19.2.5-ee.0"
    "gitlab/gitlab-ee:19.3.1-ee.0"
    "gitlab/gitlab-ee:19.4.2-ee.0"
    "gitlab/gitlab-ee:19.0.1-ee.0"
    "golang"
    "golang:1.21.5"
    "grafana/grafana"
    "haproxy"
    # Follow the stable relay + embedded WebUI; Shepherd updates the stage4 stack.
    "happierdev/relay-server:stable"
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
    "mongo"
    "mwader/postfix-relay"
    "mysql:9.7.0"
    "mysql"
    "neosmemo/memos:stable"
    "nextcloud"
    "nextcloud:27.1.0"
    "nextcloud:31.0.7"
    "nextcloud:32.0.5"
    "nextcloud:32.0.15-apache"
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
    "nvidia/cuda:13.2.1-devel-ubuntu24.04"
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
    "ubuntu:26.04"
    "valkey/valkey:8-bookworm"
    "vaultwarden/server"
    "vaultwarden/server:testing"
    "verdaccio/verdaccio"
    "vikunja/vikunja"
    "vikunja/vikunja:unstable"
    "vllm/vllm-openai"
    "vminnovations/typescript-sdk:16-latest"
    "wolveix/satisfactory-server:latest"
    "wordpress:php8.3-fpm-alpine"
)

# Optional explicit image list for prefetching a new stack's dependencies:
# /app/entry.sh happierdev/relay-server:stable
if [ "$#" -gt 0 ]; then
    images=("$@")
fi

# Shuffle the list and iterate
shuffled_images=($(printf "%s\n" "${images[@]}" | shuf))

failed_images=()
for image in "${shuffled_images[@]}"; do
    if ! mirror_docker "$image"; then
        failed_images+=("$image")
    fi
done

if [ "${#failed_images[@]}" -gt 0 ]; then
    log_error "${#failed_images[@]} image(s) failed: ${failed_images[*]}"
    exit 1
fi
log_success "All images have been processed successfully"
