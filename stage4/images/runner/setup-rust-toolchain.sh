#!/usr/bin/env bash
set -euo pipefail

readonly runner_user=gitlab-runner
runner_home="$(getent passwd "$runner_user" | cut -d: -f6)"
readonly runner_home

runuser --user "$runner_user" -- env HOME="$runner_home" bash <<'RUST_SETUP'
set -euo pipefail

retry() {
    local attempt
    for attempt in 1 2 3; do
        if "$@"; then
            return 0
        fi
        if [ "$attempt" -eq 3 ]; then
            return 1
        fi
        sleep "$((attempt * 5))"
    done
}

rustup_init_dir="$(mktemp -d)"
readonly rustup_init_dir
trap 'rm -rf "$rustup_init_dir"' EXIT

aria2c \
    --disable-ipv6=true \
    --continue=true \
    --max-connection-per-server=16 \
    --split=16 \
    --min-split-size=1M \
    --max-tries=20 \
    --retry-wait=5 \
    --connect-timeout=20 \
    --timeout=60 \
    --lowest-speed-limit=1K \
    --auto-file-renaming=false \
    --allow-overwrite=true \
    --dir="$rustup_init_dir" \
    --out=rustup-init \
    https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init

chmod 0755 "$rustup_init_dir/rustup-init"
retry "$rustup_init_dir/rustup-init" \
    -y \
    --profile minimal \
    --default-toolchain stable

rm -rf "$rustup_init_dir"
trap - EXIT

source "$HOME/.cargo/env"

retry rustup target add aarch64-unknown-linux-gnu
retry rustup component add rustfmt clippy

readonly smoke_dir="$(mktemp -d)"
trap 'rm -rf "$smoke_dir"' EXIT

printf 'fn main() {}\n' > "$smoke_dir/main.rs"
rustc \
    --target aarch64-unknown-linux-gnu \
    -C linker=aarch64-linux-gnu-gcc \
    "$smoke_dir/main.rs" \
    -o "$smoke_dir/main"

aarch64-linux-gnu-readelf -h "$smoke_dir/main" |
    grep -q 'Machine:.*AArch64'

cargo --version
rustc --version
cargo fmt --version
cargo clippy --version
RUST_SETUP
