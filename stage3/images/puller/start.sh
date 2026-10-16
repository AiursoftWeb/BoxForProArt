#!/bin/bash
# This script is called by cron to run entry.sh.
# It guards against overlapping runs, logs to stdout, and saves a timestamped physical log.

APP_DIR="${APP_DIR:-/app}"
ENTRY_SCRIPT="${ENTRY_SCRIPT:-$APP_DIR/entry.sh}"

# Guard: if entry.sh is still running from a previous cron trigger, skip this run.
if pgrep -f "$ENTRY_SCRIPT" > /dev/null 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] entry.sh already running, skipping this cron trigger."
    exit 0
fi

# Prepare log directory and timestamped file
LOG_DIR="${RUN_LOGS_DIR:-/app/run_logs}"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOG_FILE="${LOG_DIR}/run_${TIMESTAMP}.log"

# Auto-cleanup: delete logs older than 14 days
find "$LOG_DIR" -name "run_*.log" -type f -mtime +14 -delete

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting entry.sh. Physical log saved to $LOG_FILE"

# Execute entry.sh, merge stderr into stdout, then tee to both the log file and Docker stdout
"$ENTRY_SCRIPT" 2>&1 | tee "$LOG_FILE"

# PIPESTATUS[0] captures entry.sh's exit code (not tee's)
EXIT_CODE=${PIPESTATUS[0]}

echo "[$(date '+%Y-%m-%d %H:%M:%S')] entry.sh finished with exit code ${EXIT_CODE}" | tee -a "$LOG_FILE"

exit "$EXIT_CODE"
