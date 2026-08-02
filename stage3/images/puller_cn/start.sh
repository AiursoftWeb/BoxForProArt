#!/bin/bash
set -uo pipefail

# This script is called by cron to run entry.sh. It serialises all runs using
# an advisory lock stored on the persistent volume, writes physical logs, and
# exposes simple state files for monitoring.
SYNC_RECORDS_DIR="${SYNC_RECORDS_DIR:-/app/sync_records}"
mkdir -p "$SYNC_RECORDS_DIR"

LOCK_FILE="${SYNC_RECORDS_DIR}/puller_cn.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] another puller_cn run is active; skipping this cron trigger."
    exit 0
fi

# Prepare log directory and timestamped file
ENTRY_SCRIPT="${ENTRY_SCRIPT:-/app/entry.sh}"
LOG_DIR="${RUN_LOGS_DIR:-/app/run_logs}"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOG_FILE="${LOG_DIR}/run_${TIMESTAMP}.log"
START_EPOCH=$(date +%s)

printf '%s\n' "$START_EPOCH" > "${SYNC_RECORDS_DIR}/last_run_started"
printf 'running %s\n' "$START_EPOCH" > "${SYNC_RECORDS_DIR}/status"

# Auto-cleanup: delete logs older than 14 days
find "$LOG_DIR" -name "run_*.log" -type f -mtime +14 -delete

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting entry.sh. Physical log saved to $LOG_FILE"

# Execute entry.sh, merge stderr into stdout, then tee to both the log file and Docker stdout
"$ENTRY_SCRIPT" 2>&1 | tee "$LOG_FILE"

# PIPESTATUS[0] captures entry.sh's exit code (not tee's)
EXIT_CODE=${PIPESTATUS[0]}
FINISH_EPOCH=$(date +%s)

echo "[$(date '+%Y-%m-%d %H:%M:%S')] entry.sh finished with exit code ${EXIT_CODE}" | tee -a "$LOG_FILE"
printf '%s\n' "$FINISH_EPOCH" > "${SYNC_RECORDS_DIR}/last_run_finished"
printf '%s\n' "$EXIT_CODE" > "${SYNC_RECORDS_DIR}/last_exit_code"

if [ "$EXIT_CODE" -eq 0 ]; then
    printf '%s\n' "$FINISH_EPOCH" > "${SYNC_RECORDS_DIR}/last_success"
    printf 'success %s\n' "$FINISH_EPOCH" > "${SYNC_RECORDS_DIR}/status"
else
    printf '%s\n' "$FINISH_EPOCH" > "${SYNC_RECORDS_DIR}/last_failure"
    printf 'failed %s exit_code=%s\n' "$FINISH_EPOCH" "$EXIT_CODE" > "${SYNC_RECORDS_DIR}/status"
fi

exit "$EXIT_CODE"
