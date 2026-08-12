#!/bin/bash
set -Eeuo pipefail

APP_DIR="${APP_DIR:-/app}"
cd "$APP_DIR"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

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

REGCTL_BIN="${REGCTL_BIN:-/usr/local/bin/regctl}"
SYNC_RECORDS_DIR="${SYNC_RECORDS_DIR:-/app/sync_records}"
COPY_TIMEOUT_SECONDS="${COPY_TIMEOUT_SECONDS:-14400}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"
RETRY_BASE_SECONDS="${RETRY_BASE_SECONDS:-120}"
POST_COPY_SETTLE_SECONDS="${POST_COPY_SETTLE_SECONDS:-3}"
PUBLIC_CHECK_INTERVAL_SECONDS="${PUBLIC_CHECK_INTERVAL_SECONDS:-27000}"
INTERNAL_CHECK_INTERVAL_SECONDS="${INTERNAL_CHECK_INTERVAL_SECONDS:-27000}"

mkdir -p "$SYNC_RECORDS_DIR"

require_non_negative_integer() {
    local name="$1"
    local value="$2"

    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        log_error "$name must be a non-negative integer, got: $value"
        exit 1
    fi
}

require_positive_integer() {
    local name="$1"
    local value="$2"

    require_non_negative_integer "$name" "$value"
    if [ "$value" -eq 0 ]; then
        log_error "$name must be greater than zero"
        exit 1
    fi
}

require_positive_integer "COPY_TIMEOUT_SECONDS" "$COPY_TIMEOUT_SECONDS"
require_positive_integer "MAX_ATTEMPTS" "$MAX_ATTEMPTS"
require_non_negative_integer "RETRY_BASE_SECONDS" "$RETRY_BASE_SECONDS"
require_non_negative_integer "POST_COPY_SETTLE_SECONDS" "$POST_COPY_SETTLE_SECONDS"
require_non_negative_integer "PUBLIC_CHECK_INTERVAL_SECONDS" "$PUBLIC_CHECK_INTERVAL_SECONDS"
require_non_negative_integer "INTERNAL_CHECK_INTERVAL_SECONDS" "$INTERNAL_CHECK_INTERVAL_SECONDS"

normalise_image() {
    local image="$1"

    if [[ "${image##*/}" != *":"* ]]; then
        image="${image}:latest"
    fi

    printf '%s\n' "$image"
}

get_sync_record_file() {
    local image
    image=$(normalise_image "$1")
    printf '%s/%s\n' "$SYNC_RECORDS_DIR" "$(echo "$image" | sed 's|/|__|g; s|:|_|g')"
}

save_sync_record() {
    local image="$1"
    local digest="$2"
    local record_file
    local temporary_file

    record_file=$(get_sync_record_file "$image")
    temporary_file="${record_file}.tmp.$$"
    printf '%s %s\n' "$(date +%s)" "$digest" > "$temporary_file"
    mv "$temporary_file" "$record_file"
}

get_target_reference() {
    local image
    image=$(normalise_image "$1")
    printf '%s/%s\n' "$MIRROR_TARGET" "$image"
}

should_skip_recent_image() {
    local image="$1"
    local check_interval_seconds="$2"
    local record_file
    local last_sync_epoch=""
    local recorded_digest=""
    local age_seconds
    local target_reference
    local target_digest

    if [ "$check_interval_seconds" -eq 0 ]; then
        return 1
    fi

    record_file=$(get_sync_record_file "$image")
    if [ ! -f "$record_file" ]; then
        return 1
    fi

    read -r last_sync_epoch recorded_digest < "$record_file" || true
    if [[ ! "$last_sync_epoch" =~ ^[0-9]+$ ]] || [ -z "$recorded_digest" ]; then
        # Old timestamp-only records are intentionally refreshed once.
        return 1
    fi

    age_seconds=$(( $(date +%s) - last_sync_epoch ))
    if [ "$age_seconds" -ge "$check_interval_seconds" ]; then
        return 1
    fi

    # Even during the public-image quiet period, repair a missing or changed
    # target immediately instead of trusting only the local timestamp.
    target_reference=$(get_target_reference "$image")
    target_digest=$("$REGCTL_BIN" image digest "$target_reference" 2>/dev/null || true)
    if [ "$target_digest" = "$recorded_digest" ]; then
        return 0
    fi

    log_warning "Recorded target digest is missing or changed; forcing a fresh sync check"
    return 1
}

must_login_target_registry() {
    if [ -z "${MIRROR_TARGET:-}" ]; then
        log_error "MIRROR_TARGET is not set. Cannot proceed."
        exit 1
    fi

    log_step "Authenticating to target registry"
    log_detail "Registry: ${MIRROR_TARGET}"

    if [ -z "${CN_DOCKER_USERNAME:-}" ] || [ -z "${CN_DOCKER_PASSWORD:-}" ]; then
        log_error "Target registry credentials are not set. Aborting."
        exit 1
    fi

    "$REGCTL_BIN" registry login "$MIRROR_TARGET" \
        -u "$CN_DOCKER_USERNAME" \
        -p "$CN_DOCKER_PASSWORD" > /dev/null 2>&1
    log_success "Successfully authenticated to ${MIRROR_TARGET}"
}

must_login_source_registry() {
    if [ -z "${FROM_REGISTRY:-}" ]; then
        log_error "FROM_REGISTRY is not set. puller_cn only mirrors from the home registry."
        exit 1
    fi

    log_step "Authenticating to source registry"
    log_detail "Registry: ${FROM_REGISTRY}"

    if [ -z "${DOCKER_USERNAME:-}" ] || [ -z "${DOCKER_PASSWORD:-}" ]; then
        log_error "Source registry credentials are not set. Aborting."
        exit 1
    fi

    "$REGCTL_BIN" registry login "$FROM_REGISTRY" \
        -u "$DOCKER_USERNAME" \
        -p "$DOCKER_PASSWORD" > /dev/null 2>&1
    log_success "Successfully authenticated to ${FROM_REGISTRY}"
}

copy_image_once() {
    local requested_image="$1"
    local attempt="$2"
    local image
    local image_name
    local image_tag
    local source_reference
    local source_repository
    local pinned_source_reference
    local target_reference
    local source_digest
    local target_digest
    local copied_digest
    local copy_arguments=()

    image=$(normalise_image "$requested_image")
    image_name="${image%:*}"
    image_tag="${image##*:}"
    source_reference="${FROM_REGISTRY}/${image_name}:${image_tag}"
    source_repository="${source_reference%:*}"
    target_reference="${MIRROR_TARGET}/${image_name}:${image_tag}"

    log_detail "Source: ${source_reference}"
    log_detail "Target: ${target_reference}"
    log_info "Comparing source and target digests..."

    source_digest=$("$REGCTL_BIN" image digest "$source_reference" 2>/dev/null || true)
    if [ -z "$source_digest" ]; then
        log_error "Unable to resolve source digest: ${source_reference}"
        return 1
    fi

    target_digest=$("$REGCTL_BIN" image digest "$target_reference" 2>/dev/null || true)
    if [ "$source_digest" = "$target_digest" ]; then
        log_success "Image is already up-to-date (${source_digest})"
        save_sync_record "$image" "$source_digest"
        return 0
    fi

    # Pin the source digest before copying. If CI moves :latest during a long
    # transfer, this run remains deterministic and the next poll picks up the
    # newer digest.
    pinned_source_reference="${source_repository}@${source_digest}"
    copy_arguments=(image copy "$pinned_source_reference" "$target_reference" --digest-tags)
    if [ "$attempt" -gt 1 ]; then
        copy_arguments+=(--force-recursive)
    fi

    log_info "Copying pinned digest ${source_digest} (attempt ${attempt})..."
    if ! timeout --foreground --signal=TERM --kill-after=60s "$COPY_TIMEOUT_SECONDS" \
        "$REGCTL_BIN" "${copy_arguments[@]}" 2>&1 | sed 's/^/  /'; then
        log_error "Copy command failed or exceeded ${COPY_TIMEOUT_SECONDS}s"
        return 1
    fi

    if [ "$POST_COPY_SETTLE_SECONDS" -gt 0 ]; then
        sleep "$POST_COPY_SETTLE_SECONDS"
    fi

    copied_digest=$("$REGCTL_BIN" image digest "$target_reference" 2>/dev/null || true)
    if [ "$copied_digest" != "$source_digest" ]; then
        log_error "Digest verification failed: expected ${source_digest}, got ${copied_digest:-missing}"
        return 1
    fi

    save_sync_record "$image" "$source_digest"
    log_success "Image copied and digest verified successfully"
    return 0
}

mirror_image() {
    local image="$1"
    local check_interval_seconds="$2"
    local attempt
    local backoff_seconds

    log_step "Mirroring: ${BOLD}${image}${NC}"

    if should_skip_recent_image "$image" "$check_interval_seconds"; then
        log_success "Skipped ${BOLD}${image}${NC} (checked recently; target digest still matches)"
        return 0
    fi

    for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
        log_info "Attempt ${attempt}/${MAX_ATTEMPTS}"

        if copy_image_once "$image" "$attempt"; then
            log_success "${BOLD}${image}${NC} mirrored successfully"
            return 0
        fi

        if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
            backoff_seconds=$(( RETRY_BASE_SECONDS * attempt + RANDOM % 30 ))
            log_warning "Mirror failed, retrying in ${backoff_seconds}s..."
            sleep "$backoff_seconds"
        fi
    done

    log_error "${BOLD}${image}${NC} failed after ${MAX_ATTEMPTS} attempts"
    return 1
}

must_login_target_registry
must_login_source_registry

# BoxForChina public runtime dependencies. They are checked every eight hours
# because their home-registry copies are maintained by the public puller.
public_images=(
    "clickhouse/clickhouse-server:latest"
    "containrrr/shepherd:latest"
    "ghcr.io/goauthentik/proxy:2026.5.6"
    "ghcr.io/nextcloud-releases/aio-talk:latest"
    "grafana/grafana:latest"
    "immybot/remotely:88"
    "mysql:9.7.0"
)

# Aiursoft images actually consumed by BoxForChina. They use the same relaxed
# eight-hour schedule as public images; GitLab CI no longer pushes them to CN.
internal_images=(
    "aiursoft/employeecenter:latest"
    "aiursoft/folderagent:latest"
    "aiursoft/musicexam:latest"
    "aiursoft/tracer:latest"
    "aiursoft/wechatexam:latest"
)

image_specs=()
for image in "${public_images[@]}"; do
    image_specs+=("${PUBLIC_CHECK_INTERVAL_SECONDS}|${image}")
done
for image in "${internal_images[@]}"; do
    image_specs+=("${INTERNAL_CHECK_INTERVAL_SECONDS}|${image}")
done

# Use one sequential worker to protect the constrained home-to-China uplink.
# Shuffling prevents a repeatedly failing large image from always being first.
mapfile -t shuffled_specs < <(printf '%s\n' "${image_specs[@]}" | shuf)

failed_images=()
for image_spec in "${shuffled_specs[@]}"; do
    check_interval_seconds="${image_spec%%|*}"
    image="${image_spec#*|}"

    if ! mirror_image "$image" "$check_interval_seconds"; then
        failed_images+=("$image")
    fi
done

if [ "${#failed_images[@]}" -gt 0 ]; then
    echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log_error "${#failed_images[@]} image(s) failed: ${failed_images[*]}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    exit 1
fi

echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
log_success "${BOLD}All required BoxForChina images are synchronized${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
