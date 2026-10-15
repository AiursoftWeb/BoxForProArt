#!/usr/bin/env bash
set -euo pipefail
umask 077

if [ "$(id -u)" = 0 ]; then
    worker_group=$(id -gn anduin)
    install -d -m 0700 -o anduin -g "$worker_group" /home/anduin
    if [ ! -f /home/anduin/.worker-home-initialized ]; then
        # Preserve existing files if an interrupted first boot is retried.
        cp -an /opt/worker-home/. /home/anduin/
        chown -R anduin:"$worker_group" /home/anduin
        touch /home/anduin/.worker-home-initialized
        chown anduin:"$worker_group" /home/anduin/.worker-home-initialized
    fi
    exec setpriv --reuid=anduin --regid="$worker_group" --init-groups "$0" "$@"
fi

export NO_PROXY="127.0.0.1,localhost,::1${NO_PROXY:+,$NO_PROXY}"
export no_proxy="$NO_PROXY"
export TMPDIR="$HOME/.cache/tmp"
mkdir -p "$HOME/Source/Repos" "$TMPDIR"
cd "$HOME/Source/Repos"

# Explicit commands (for maintenance) run with the same home and user as sessions.
if [ "$#" -gt 0 ]; then exec "$@"; fi

# Even auth status may clean stale daemon state: save recovery evidence first.
mkdir -p "$HOME/.worker"
exec 9> "$HOME/.worker/container.lock"
flock -n 9 || { echo 'Another worker owns this home directory.' >&2; exit 1; }
worker-recover prepare
runtime_dir=${WORKER_RUNTIME_DIR:-/tmp/worker}
mkdir -p "$runtime_dir"
touch "$runtime_dir/pairing"
request_file=$(mktemp)
trap 'rm -f "$request_file"' EXIT
while true; do
    # A valid not_authenticated JSON response has exit code 1; inspect it anyway.
    status=$(timeout 60 happier auth status --json \
        --server-url "$HAPPIER_SERVER_URL" --persist) || true
    if jq -e '.ok == true and .data.authenticated == true' <<< "$status" >/dev/null 2>&1; then
        break
    elif jq -e '.error.code == "not_authenticated"' <<< "$status" >/dev/null 2>&1; then
        echo 'Worker needs approval in your existing Happier account.'
        if timeout 60 happier auth request --json > "$request_file"; then
            if public_key=$(jq -er '.publicKey' "$request_file") && \
                link=$(jq -er '.links.webUrl' "$request_file"); then
                printf 'Open this private pairing link to approve proart-worker:\n%s\n' "$link"
                # wait's JSON contains a bearer token; never put it in Docker logs.
                if timeout 3600 happier auth wait --public-key "$public_key" --json >/dev/null; then
                    echo 'Pairing approved; verifying authentication.'
                    continue
                fi
            fi
        fi
        echo 'Pairing failed or expired; retrying in 15 seconds.'
    else
        echo 'Relay unavailable; keeping saved credentials and retrying in 15 seconds.'
    fi
    sleep 15
done
rm -f "$request_file" "$runtime_dir/pairing"
trap - EXIT
echo 'Starting Happier worker daemon in the foreground.'
echo 'Complete Codex authentication on this machine before starting coding tasks.'
happier daemon start-sync &
daemon_pid=$!
setsid worker-recover restore &
recovery_pid=$!
shutdown() {
    local code=$1
    trap - TERM INT
    # Stop restore requests before capturing the sessions that are actually running.
    kill -TERM -- "-$recovery_pid" 2>/dev/null || true
    wait "$recovery_pid" 2>/dev/null || true
    worker-recover snapshot || echo 'Could not checkpoint shutdown; existing recovery records retained.' >&2
    kill -TERM "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    exit "$code"
}
trap 'shutdown 143' TERM
trap 'shutdown 130' INT
daemon_exit=0
wait "$daemon_pid" || daemon_exit=$?
shutdown "$daemon_exit"
