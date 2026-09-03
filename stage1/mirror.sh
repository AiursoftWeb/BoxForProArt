set -euo pipefail

mirror_image() {
    local image="$1"
    local source="${MIRROR_SOURCE_PREFIX:-}${image}"
    local target="localhost:8080/public_mirror/${image}"
    local platform="${MIRROR_PLATFORM:-linux/amd64}"
    local platform_digest
    local platform_image

    echo "Mirroring image: $image"
    sudo docker pull --platform "$platform" "$source"
    platform_digest="$(sudo docker image inspect --platform "$platform" --format '{{.Id}}' "$source")"
    case "$platform_digest" in
        sha256:*) ;;
        *) echo "Failed to resolve $platform manifest digest for $image" >&2; return 1 ;;
    esac
    platform_image="${source}@${platform_digest}"
    sudo docker pull "$platform_image"
    sudo docker tag "$platform_image" "$target"
    sudo docker push "$target"
}

echo "Mirroring Ubuntu..."
mirror_image "ubuntu:26.04"

echo "Mirroring Caddy builder..."
mirror_image "caddy:builder"

echo "Mirroring Caddy latest..."
mirror_image "caddy:latest"

echo "Mirroring Postgres..."
mirror_image "postgres:16-alpine"

echo "Mirroring MySQL..."
mirror_image "mysql:9.7.0"

echo "Mirroring Redis..."
mirror_image "redis:alpine"

echo "Mirroring Aiursoft Static..."
mirror_image "aiursoft/static"

echo "Mirroring Aiursoft Baget..."
mirror_image "aiursoft/baget"

# The tag need to be updated regularly.
echo "Mirroring GoAuthentik server..."
mirror_image "ghcr.io/goauthentik/server:2026.5.6"

echo "Mirroring npm Verdaccio..."
mirror_image "verdaccio/verdaccio"
