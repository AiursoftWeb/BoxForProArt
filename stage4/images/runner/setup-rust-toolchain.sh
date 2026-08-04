#!/usr/bin/env bash
set -euo pipefail

readonly runner_user=gitlab-runner
runner_home="$(getent passwd "$runner_user" | cut -d: -f6)"
readonly runner_home

runuser --user "$runner_user" -- env HOME="$runner_home" bash <<'RUST_SETUP'
set -euo pipefail

curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
    https://sh.rustup.rs |
    sh -s -- \
        -y \
        --profile minimal \
        --default-toolchain stable

source "$HOME/.cargo/env"

rustup target add aarch64-unknown-linux-gnu
rustup component add rustfmt clippy

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
