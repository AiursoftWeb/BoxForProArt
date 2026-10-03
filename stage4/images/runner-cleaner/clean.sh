#!/bin/sh
set -eu

root=/runner-data
interval=${CHECK_INTERVAL_SECONDS:-1800}
high=${HIGH_WATERMARK_BYTES:-107374182400}
low=${LOW_WATERMARK_BYTES:-85899345920}
request=

for value in "$interval" "$high" "$low"; do
    case "$value" in
        ''|*[!0-9]*) echo "Cleaner settings must be nonnegative integers" >&2; exit 1 ;;
    esac
done
if [ "$interval" -eq 0 ] || [ "$low" -ge "$high" ]; then
    echo "Cleaner interval must be positive and low watermark must be below high watermark" >&2
    exit 1
fi

cleanup_request() {
    if [ -n "$request" ]; then
        rm -f -- "$request"
    fi
}
trap cleanup_request EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A local bind volume needs one cleaner per Swarm node. The lock also prevents
# overlapping cleaners during service replacement or a manual invocation.
exec 7>"$root/.cleaner.lock"
if ! flock -n -x 7; then
    echo "Another runner cleaner owns this node; exiting"
    exit 0
fi

# Recover from an interrupted cleaner. A waiting runner can then accept jobs.
for slot in "$root"/*; do
    [ -f "$slot/.cleanup.ready" ] || continue
    rm -f -- "$slot/.cleanup.request"
done

used_bytes() {
    du -s -B1 -- "$root" | cut -f1
}

while :; do
    used=$(used_bytes)
    if [ "$used" -gt "$high" ]; then
        echo "Runner data uses $used bytes (limit $high); draining one runner at a time"
        for slot in "$root"/*; do
            [ -f "$slot/.cleanup.ready" ] || continue
            [ -d "$slot/builds" ] || continue

            request="$slot/.cleanup.request"
            : > "$request"
            exec 8>"$slot/.cleanup.lock"
            flock -x 8
            echo "Drained $slot; clearing its cache and, if needed, its builds"

            for kind in cache builds; do
                if [ -d "$slot/$kind" ]; then
                    find "$slot/$kind" -xdev -mindepth 1 -delete || \
                        echo "Some entries in $slot/$kind could not be removed" >&2
                fi
                used=$(used_bytes)
                echo "Runner data now uses $used bytes"
                [ "$used" -le "$low" ] && break
            done

            cleanup_request
            request=
            flock -u 8
            exec 8>&-
            [ "$used" -le "$low" ] && break
        done
        if [ "$used" -gt "$low" ]; then
            echo "Runner data remains above target ($used bytes); no more managed directories to clean" >&2
        fi
    fi
    sleep "$interval"
done
