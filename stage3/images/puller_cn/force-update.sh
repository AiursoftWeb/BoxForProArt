#!/bin/bash
set -Eeuo pipefail

# This fixed entry point is called by DMS. Keep the same lock as start.sh so
# scheduled and approved runs cannot overlap, including while copying an image.
image_pattern='^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?$'
if [ "$#" -ne 1 ] || [ "${#1}" -gt 255 ] || [[ ! "$1" =~ $image_pattern ]]; then
    echo 'Supply exactly one concrete image name with an optional tag.' >&2
    exit 78
fi

APP_DIR="${APP_DIR:-/app}"
SYNC_RECORDS_DIR="${SYNC_RECORDS_DIR:-/app/sync_records}"
mkdir -p "$SYNC_RECORDS_DIR"
exec 9>"${SYNC_RECORDS_DIR}/puller_cn.lock"
if ! flock -n 9; then
    echo 'CN Puller is already running. No new sync was started.' >&2
    exit 75
fi

echo "Starting a scoped CN Puller force update: $1"
if PUBLIC_CHECK_INTERVAL_SECONDS=0 INTERNAL_CHECK_INTERVAL_SECONDS=0 "$APP_DIR/entry.sh" "$1"; then
    echo 'CN Puller mirror sync completed. Service deployment must be checked separately.'
else
    result=$?
    echo "CN Puller finished with exit code ${result}." >&2
    exit 70
fi
